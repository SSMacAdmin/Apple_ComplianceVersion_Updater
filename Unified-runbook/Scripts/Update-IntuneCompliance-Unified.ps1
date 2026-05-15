<#
.SYNOPSIS
    Unified runbook that updates both macOS and iOS/iPadOS Intune compliance policies in a
    single execution.

.DESCRIPTION
    Fetches the latest versions for each enabled platform from the MacAdmins SOFA feed and
    updates the corresponding Intune compliance policies. Platforms are independently
    enabled/disabled via Azure Automation variables.

    Works in two modes:
    1. Standalone: Pass parameters directly or use environment variables
    2. Azure Automation: Automatically loads credentials from Azure Automation variables

.PARAMETER TenantId
    Azure AD Tenant ID (not needed when using Managed Identity)

.PARAMETER ClientId
    Azure App Registration Client ID (not needed when using Managed Identity)

.PARAMETER ClientSecret
    Azure App Registration Client Secret (not needed when using Managed Identity)

.PARAMETER MacOSPolicyId
    Override the macOS compliance policy ID (uses MACOS_POLICY_ID variable by default)

.PARAMETER IOSPolicyId
    Override the iOS/iPadOS compliance policy ID (uses IOS_POLICY_ID variable by default)

.PARAMETER EnableMacOS
    Force-enable macOS processing (overrides ENABLE_MACOS variable)

.PARAMETER EnableIOS
    Force-enable iOS/iPadOS processing (overrides ENABLE_IOS variable)

.PARAMETER UseManagedIdentity
    Force Managed Identity authentication

.PARAMETER WhatIf
    Show what changes would be made without actually making them

.PARAMETER RunTests
    Run prerequisite tests before the main script

.EXAMPLE
    # Azure Automation (uses all variables)
    .\Update-IntuneCompliance-Unified.ps1

.EXAMPLE
    # Standalone with parameters
    .\Update-IntuneCompliance-Unified.ps1 -TenantId "xxx" -ClientId "xxx" -ClientSecret "xxx" `
        -MacOSPolicyId "xxx" -IOSPolicyId "xxx" -EnableMacOS -EnableIOS

.EXAMPLE
    # Only process iOS, skip macOS
    .\Update-IntuneCompliance-Unified.ps1 -EnableIOS -MacOSPolicyId "skip"

.NOTES
    Author: Niklas Bruhn (SSMacAdmin.com)
    Version: 4.1.0

    Azure Automation Variables:

    Authentication (shared):
    - USE_MANAGED_IDENTITY          Boolean  required
    - INTUNE_TENANT_ID              String   required (SP mode only)
    - INTUNE_CLIENT_ID              String   required (SP mode only)
    - INTUNE_CLIENT_SECRET          String   required (SP mode only, encrypted)

    Platform enable/disable:
    - ENABLE_MACOS                  Boolean  required  (True to process macOS)
    - ENABLE_IOS                    Boolean  required  (True to process iOS/iPadOS)

    macOS settings (used when ENABLE_MACOS = True):
    - MACOS_POLICY_ID               String   required
    - MACOS_PIN_TO_MAJOR_VERSION    Integer  optional
    - MACOS_VERSIONS_BELOW          Integer  optional (default: 2)
    - MACOS_USE_MINOR_VERSIONS      Boolean  optional (default: false)

    iOS/iPadOS settings (used when ENABLE_IOS = True):
    - IOS_POLICY_ID                 String   required
    - IOS_PIN_TO_MAJOR_VERSION      Integer  optional
    - IOS_VERSIONS_BELOW            Integer  optional (default: 2)
    - IOS_USE_MINOR_VERSIONS        Boolean  optional (default: false)

    Required Graph API Permissions:
    - DeviceManagementConfiguration.ReadWrite.All
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$ClientId,

    [Parameter(Mandatory = $false)]
    [string]$ClientSecret,

    [Parameter(Mandatory = $false)]
    [string]$MacOSPolicyId,

    [Parameter(Mandatory = $false)]
    [string]$IOSPolicyId,

    [Parameter(Mandatory = $false)]
    [switch]$EnableMacOS,

    [Parameter(Mandatory = $false)]
    [switch]$EnableIOS,

    [Parameter(Mandatory = $false)]
    [switch]$UseManagedIdentity,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [switch]$RunTests
)



# ============================================================================
# GLOBAL VARIABLES
# ============================================================================
$script:testMode          = $RunTests
$script:isAzureAutomation = $false
$script:logEntries        = @()

# ============================================================================
# HELPERS
# ============================================================================
function ConvertTo-RunbookBoolean {
    param(
        [Parameter(Mandatory = $false)]
        $Value,

        [Parameter(Mandatory = $false)]
        [bool]$Default = $false
    )

    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }

    $stringValue = $Value.ToString().Trim()
    if ([string]::IsNullOrWhiteSpace($stringValue)) { return $Default }

    switch -Regex ($stringValue) {
        '^(true|1|yes|y)$'  { return $true }
        '^(false|0|no|n)$'  { return $false }
        default             { return $Default }
    }
}

function Test-TransientRestError {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $response = $ErrorRecord.Exception.Response
    if ($response -and $response.StatusCode) {
        $statusCode = [int]$response.StatusCode
        if ($statusCode -eq 429 -or $statusCode -ge 500) { return $true }
    }

    if ($ErrorRecord.Exception -is [System.Net.WebException]) {
        return $ErrorRecord.Exception.Status -in @(
            [System.Net.WebExceptionStatus]::Timeout,
            [System.Net.WebExceptionStatus]::ConnectFailure,
            [System.Net.WebExceptionStatus]::ConnectionClosed,
            [System.Net.WebExceptionStatus]::NameResolutionFailure,
            [System.Net.WebExceptionStatus]::ReceiveFailure,
            [System.Net.WebExceptionStatus]::SendFailure
        )
    }

    return ($ErrorRecord.Exception.Message -match 'timed out|timeout|temporarily unavailable')
}

function Get-RetryAfterSeconds {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    try {
        $retryAfter = $ErrorRecord.Exception.Response.Headers['Retry-After']
        if ($retryAfter) {
            $seconds = 0
            if ([int]::TryParse($retryAfter.ToString(), [ref]$seconds) -and $seconds -gt 0) {
                return [Math]::Min($seconds, 60)
            }
        }
    } catch { }

    return $null
}

function Invoke-RestMethodWithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [Parameter(Mandatory = $false)]
        [string]$Method = 'Get',

        [Parameter(Mandatory = $false)]
        [hashtable]$Headers,

        [Parameter(Mandatory = $false)]
        $Body,

        [Parameter(Mandatory = $false)]
        [int]$TimeoutSec,

        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3
    )

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $params = @{
                Uri         = $Uri
                Method      = $Method
                ErrorAction = 'Stop'
            }
            if ($Headers) { $params.Headers = $Headers }
            if ($null -ne $Body) { $params.Body = $Body }
            if ($TimeoutSec -gt 0) { $params.TimeoutSec = $TimeoutSec }

            return Invoke-RestMethod @params
        }
        catch {
            $isTransient = Test-TransientRestError -ErrorRecord $_
            if (-not $isTransient -or $attempt -ge $MaxRetries) { throw }

            $delay = Get-RetryAfterSeconds -ErrorRecord $_
            if ($null -eq $delay) { $delay = [Math]::Min([Math]::Pow(2, $attempt), 30) }

            Write-Log "Transient REST failure on attempt $attempt/$MaxRetries. Retrying in $delay seconds. Error: $($_.Exception.Message)" -Level WARNING
            Start-Sleep -Seconds $delay
        }
    }
}

function Assert-VersionsBelow {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Value -lt 1 -or $Value -gt 10) {
        throw "$Name must be between 1 and 10. Current value: $Value"
    }
}

# ============================================================================
# LOGGING
# ============================================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    $script:logEntries += $logMessage

    if (-not $script:isAzureAutomation) {
        switch ($Level) {
            'INFO'    { Write-Host $logMessage -ForegroundColor Cyan }
            'WARNING' { Write-Host $logMessage -ForegroundColor Yellow }
            'ERROR'   { Write-Host $logMessage -ForegroundColor Red }
            'SUCCESS' { Write-Host $logMessage -ForegroundColor Green }
            'DEBUG'   { Write-Host $logMessage -ForegroundColor Gray }
        }
    }
    else {
        Write-Verbose $logMessage
    }
}

# ============================================================================
# CONFIGURATION LOADING
# ============================================================================
function Get-Configuration {
    Write-Log "Loading unified configuration..." -Level INFO

    $config = @{
        # Authentication
        TenantId           = $null
        ClientId           = $null
        ClientSecret       = $null
        UseManagedIdentity = $false

        # Platform toggles
        EnableMacOS        = $false
        EnableIOS          = $false

        # macOS settings
        MacOS = @{
            PolicyId          = $null
            VersionsBelow     = 2
            UseMinorVersions  = $false
            PinToMajorVersion = 0
        }

        # iOS settings
        IOS = @{
            PolicyId          = $null
            VersionsBelow     = 2
            UseMinorVersions  = $false
            PinToMajorVersion = 0
        }

        WhatIf             = $WhatIf
    }

    # Detect Azure Automation
    try {
        $null = Get-AutomationVariable -Name "ENABLE_MACOS" -ErrorAction Stop
        $script:isAzureAutomation = $true
        Write-Log "Detected Azure Automation environment" -Level INFO
    }
    catch {
        # Try alternate detection
        try {
            $null = Get-AutomationVariable -Name "USE_MANAGED_IDENTITY" -ErrorAction Stop
            $script:isAzureAutomation = $true
            Write-Log "Detected Azure Automation environment" -Level INFO
        }
        catch {
            $script:isAzureAutomation = $false
            Write-Log "Running in standalone mode" -Level INFO
        }
    }

    if ($script:isAzureAutomation) {
        Write-Log "Loading variables from Azure Automation..." -Level INFO

        try {
            # Auth method
            $useMI = $false
            try {
                $miVar = Get-AutomationVariable -Name "USE_MANAGED_IDENTITY" -ErrorAction SilentlyContinue
                if ($null -ne $miVar) { $useMI = ConvertTo-RunbookBoolean -Value $miVar }
            } catch { }

            $config.UseManagedIdentity = $useMI

            if (-not $useMI) {
                $config.TenantId     = Get-AutomationVariable -Name "INTUNE_TENANT_ID"
                $config.ClientId     = Get-AutomationVariable -Name "INTUNE_CLIENT_ID"
                $config.ClientSecret = Get-AutomationVariable -Name "INTUNE_CLIENT_SECRET"
            }

            # Platform toggles
            try {
                $enMac = Get-AutomationVariable -Name "ENABLE_MACOS" -ErrorAction SilentlyContinue
                if ($null -ne $enMac) { $config.EnableMacOS = ConvertTo-RunbookBoolean -Value $enMac }
            } catch { }

            try {
                $enIOS = Get-AutomationVariable -Name "ENABLE_IOS" -ErrorAction SilentlyContinue
                if ($null -ne $enIOS) { $config.EnableIOS = ConvertTo-RunbookBoolean -Value $enIOS }
            } catch { }

            # macOS settings
            if ($config.EnableMacOS) {
                $config.MacOS.PolicyId = Get-AutomationVariable -Name "MACOS_POLICY_ID"

                try {
                    $v = Get-AutomationVariable -Name "MACOS_VERSIONS_BELOW" -ErrorAction SilentlyContinue
                    if ($v) { $config.MacOS.VersionsBelow = [int]$v }
                } catch { }

                try {
                    $u = Get-AutomationVariable -Name "MACOS_USE_MINOR_VERSIONS" -ErrorAction SilentlyContinue
                    if ($null -ne $u) { $config.MacOS.UseMinorVersions = ConvertTo-RunbookBoolean -Value $u }
                } catch { }

                try {
                    $p = Get-AutomationVariable -Name "MACOS_PIN_TO_MAJOR_VERSION" -ErrorAction SilentlyContinue
                    if ($p -and $p -gt 0) { $config.MacOS.PinToMajorVersion = [int]$p }
                } catch { }
            }

            # iOS settings
            if ($config.EnableIOS) {
                $config.IOS.PolicyId = Get-AutomationVariable -Name "IOS_POLICY_ID"

                try {
                    $v = Get-AutomationVariable -Name "IOS_VERSIONS_BELOW" -ErrorAction SilentlyContinue
                    if ($v) { $config.IOS.VersionsBelow = [int]$v }
                } catch { }

                try {
                    $u = Get-AutomationVariable -Name "IOS_USE_MINOR_VERSIONS" -ErrorAction SilentlyContinue
                    if ($null -ne $u) { $config.IOS.UseMinorVersions = ConvertTo-RunbookBoolean -Value $u }
                } catch { }

                try {
                    $p = Get-AutomationVariable -Name "IOS_PIN_TO_MAJOR_VERSION" -ErrorAction SilentlyContinue
                    if ($p -and $p -gt 0) { $config.IOS.PinToMajorVersion = [int]$p }
                } catch { }
            }

            # Parameter overrides
            if ($EnableMacOS)       { $config.EnableMacOS        = $true }
            if ($EnableIOS)         { $config.EnableIOS           = $true }
            if ($MacOSPolicyId)     { $config.MacOS.PolicyId      = $MacOSPolicyId }
            if ($IOSPolicyId)       { $config.IOS.PolicyId        = $IOSPolicyId }
            if ($UseManagedIdentity){ $config.UseManagedIdentity  = $true }

            Write-Log "Successfully loaded Azure Automation variables" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to load Azure Automation variables: $($_.Exception.Message)" -Level ERROR
            Write-Log "Required: ENABLE_MACOS, ENABLE_IOS, USE_MANAGED_IDENTITY" -Level ERROR
            Write-Log "When ENABLE_MACOS=True: MACOS_POLICY_ID" -Level ERROR
            Write-Log "When ENABLE_IOS=True:   IOS_POLICY_ID" -Level ERROR
            throw
        }
    }
    else {
        # Standalone mode
        $config.TenantId           = if ($TenantId)     { $TenantId }     else { $env:INTUNE_TENANT_ID }
        $config.ClientId           = if ($ClientId)     { $ClientId }     else { $env:INTUNE_CLIENT_ID }
        $config.ClientSecret       = if ($ClientSecret) { $ClientSecret } else { $env:INTUNE_CLIENT_SECRET }
        $config.EnableMacOS        = $EnableMacOS.IsPresent -or ($env:ENABLE_MACOS -eq "true")
        $config.EnableIOS          = $EnableIOS.IsPresent  -or ($env:ENABLE_IOS  -eq "true")
        $config.MacOS.PolicyId     = if ($MacOSPolicyId) { $MacOSPolicyId } else { $env:MACOS_POLICY_ID }
        $config.IOS.PolicyId       = if ($IOSPolicyId)   { $IOSPolicyId }   else { $env:IOS_POLICY_ID }
        $config.UseManagedIdentity = $UseManagedIdentity.IsPresent
    }

    # Validate
    if (-not $config.EnableMacOS -and -not $config.EnableIOS) {
        Write-Log "Neither macOS nor iOS is enabled. Set ENABLE_MACOS=True and/or ENABLE_IOS=True." -Level ERROR
        throw "No platforms enabled"
    }

    $missing = @()

    if (-not $config.UseManagedIdentity) {
        if ([string]::IsNullOrWhiteSpace($config.TenantId))     { $missing += "TenantId (INTUNE_TENANT_ID)" }
        if ([string]::IsNullOrWhiteSpace($config.ClientId))     { $missing += "ClientId (INTUNE_CLIENT_ID)" }
        if ([string]::IsNullOrWhiteSpace($config.ClientSecret)) { $missing += "ClientSecret (INTUNE_CLIENT_SECRET)" }
    }

    if ($config.EnableMacOS -and [string]::IsNullOrWhiteSpace($config.MacOS.PolicyId)) {
        $missing += "MacOS PolicyId (MACOS_POLICY_ID)"
    }
    if ($config.EnableIOS -and [string]::IsNullOrWhiteSpace($config.IOS.PolicyId)) {
        $missing += "IOS PolicyId (IOS_POLICY_ID)"
    }

    if ($missing.Count -gt 0) {
        Write-Log "Missing required configuration: $($missing -join ', ')" -Level ERROR
        throw "Configuration incomplete"
    }

    if ($config.EnableMacOS) {
        Assert-VersionsBelow -Value $config.MacOS.VersionsBelow -Name "MACOS_VERSIONS_BELOW"
    }
    if ($config.EnableIOS) {
        Assert-VersionsBelow -Value $config.IOS.VersionsBelow -Name "IOS_VERSIONS_BELOW"
    }

    # Log summary
    Write-Log "Configuration loaded successfully" -Level SUCCESS
    Write-Log "  Auth: $(if ($config.UseManagedIdentity) { 'Managed Identity' } else { 'Service Principal' })" -Level DEBUG
    Write-Log "  Enable macOS: $($config.EnableMacOS)" -Level DEBUG
    Write-Log "  Enable iOS:   $($config.EnableIOS)" -Level DEBUG

    if ($config.EnableMacOS) {
        Write-Log "  macOS Policy ID:    $($config.MacOS.PolicyId.Substring(0,8))..." -Level DEBUG
        Write-Log "  macOS Versions Below: $($config.MacOS.VersionsBelow)" -Level DEBUG
        if ($config.MacOS.PinToMajorVersion -gt 0) {
            Write-Log "  macOS Pin to Major: $($config.MacOS.PinToMajorVersion)" -Level DEBUG
        }
    }

    if ($config.EnableIOS) {
        Write-Log "  iOS Policy ID:    $($config.IOS.PolicyId.Substring(0,8))..." -Level DEBUG
        Write-Log "  iOS Versions Below: $($config.IOS.VersionsBelow)" -Level DEBUG
        if ($config.IOS.PinToMajorVersion -gt 0) {
            Write-Log "  iOS Pin to Major: $($config.IOS.PinToMajorVersion)" -Level DEBUG
        }
    }

    return $config
}

# ============================================================================
# PREREQUISITE TESTS
# ============================================================================
function Test-Prerequisites {
    param([hashtable]$Config)

    Write-Log "========================================" -Level INFO
    Write-Log "Running Prerequisite Tests" -Level INFO
    Write-Log "========================================" -Level INFO

    $allPassed = $true

    Write-Log "Testing PowerShell version..." -Level INFO
    if ($PSVersionTable.PSVersion.Major -ge 5) {
        Write-Log "  PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) - OK" -Level SUCCESS
    }
    else {
        Write-Log "  PowerShell version too old (need 5.1+)" -Level ERROR
        $allPassed = $false
    }

    if ($Config.EnableMacOS) {
        Write-Log "Testing SOFA macOS feed..." -Level INFO
        try {
            $test = Invoke-RestMethodWithRetry -Uri "https://sofa.macadmins.io/v2/macos_data_feed.json" -Method Get -TimeoutSec 10
            if ($test -and $test.OSVersions) {
                Write-Log "  SOFA macOS accessible ($($test.OSVersions.Count) major versions)" -Level SUCCESS
            }
            else {
                Write-Log "  SOFA macOS returned no data" -Level ERROR
                $allPassed = $false
            }
        }
        catch {
            Write-Log "  Cannot reach SOFA macOS feed: $($_.Exception.Message)" -Level ERROR
            $allPassed = $false
        }
    }

    if ($Config.EnableIOS) {
        Write-Log "Testing SOFA iOS feed..." -Level INFO
        try {
            $test = Invoke-RestMethodWithRetry -Uri "https://sofa.macadmins.io/v2/ios_data_feed.json" -Method Get -TimeoutSec 10
            if ($test -and $test.OSVersions) {
                Write-Log "  SOFA iOS accessible ($($test.OSVersions.Count) major versions)" -Level SUCCESS
            }
            else {
                Write-Log "  SOFA iOS returned no data" -Level ERROR
                $allPassed = $false
            }
        }
        catch {
            Write-Log "  Cannot reach SOFA iOS feed: $($_.Exception.Message)" -Level ERROR
            $allPassed = $false
        }
    }

    Write-Log "" -Level INFO
    return $allPassed
}

# ============================================================================
# FETCH VERSIONS FROM SOFA
# ============================================================================
function Get-SOFAVersions {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('macos', 'ios')]
        [string]$Platform
    )

    $feedUrl = "https://sofa.macadmins.io/v2/$($Platform)_data_feed.json"
    $label   = if ($Platform -eq 'macos') { 'macOS' } else { 'iOS/iPadOS' }

    Write-Log "Fetching $label versions from SOFA..." -Level INFO
    Write-Log "  URL: $feedUrl" -Level DEBUG

    try {
        $response = Invoke-RestMethodWithRetry -Uri $feedUrl -Method Get -TimeoutSec 30

        if ($null -eq $response -or $null -eq $response.OSVersions) {
            throw "No OS versions returned from SOFA $label feed"
        }

        $allVersions = @()
        foreach ($majorVersion in $response.OSVersions) {
            if ($majorVersion.Latest) {
                $allVersions += @{
                    version     = $majorVersion.Latest.ProductVersion
                    build       = $majorVersion.Latest.Build
                    released    = $true
                    releaseDate = $majorVersion.Latest.ReleaseDate
                    deviceScope = $majorVersion.Latest.DeviceScope
                }
            }
            if ($majorVersion.SecurityReleases) {
                foreach ($sec in $majorVersion.SecurityReleases) {
                    $allVersions += @{
                        version     = $sec.ProductVersion
                        build       = $sec.Build
                        released    = $true
                        releaseDate = $sec.ReleaseDate
                        deviceScope = $sec.DeviceScope
                    }
                }
            }
        }

        Write-Log "Parsed $($allVersions.Count) $label versions" -Level SUCCESS
        return $allVersions
    }
    catch [System.OutOfMemoryException] {
        throw "Memory error fetching $label version data"
    }
    catch {
        throw "Failed to retrieve $label version data: $($_.Exception.Message)"
    }
}

# ============================================================================
# PARSE AND SORT VERSIONS (shared for both platforms)
# ============================================================================
function Get-SortedVersions {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Builds,

        [Parameter(Mandatory = $true)]
        [string]$Platform,

        [Parameter(Mandatory = $false)]
        [bool]$UseMinorVersions = $false,

        [Parameter(Mandatory = $false)]
        [int]$PinToMajorVersion = 0
    )

    $label = if ($Platform -eq 'macos') { 'macOS' } else { 'iOS/iPadOS' }
    Write-Log "Parsing $label versions..." -Level INFO

    $released = $Builds | Where-Object {
        $_.version -notmatch 'beta|rc|preview|seed' -and
        ([string]::IsNullOrWhiteSpace($_.deviceScope) -or $_.deviceScope -eq 'universal')
    }
    Write-Log "  Released versions: $($released.Count)" -Level INFO
    Write-Log "  Device-specific releases are excluded from compliance minimum calculations" -Level DEBUG

    $parsed = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($build in $released) {
        if ($build.version -match '^(\d+)\.(\d+)(?:\.(\d+))?') {
            $major = [int]$Matches[1]
            if ($PinToMajorVersion -gt 0 -and $major -ne $PinToMajorVersion) { continue }

            $minor = [int]$Matches[2]
            $patch = if ($Matches[3]) { [int]$Matches[3] } else { 0 }

            $parsed.Add([PSCustomObject]@{
                Version      = $build.version
                Build        = $build.build
                MajorVersion = $major
                MinorVersion = $minor
                PatchVersion = $patch
                ReleaseDate  = if ($build.releaseDate) { $build.releaseDate } else { "Unknown" }
                DeviceScope  = if ($build.deviceScope) { $build.deviceScope } else { "Unknown" }
                FullVersion  = "$major.$minor.$patch"
            })
        }
    }

    $released = $null
    $Builds   = $null
    [System.GC]::Collect()

    $sorted = $parsed | Sort-Object MajorVersion, MinorVersion, PatchVersion -Descending

    if ($PinToMajorVersion -gt 0) {
        Write-Log "  Filtering to $label $PinToMajorVersion.x..." -Level INFO
        $sorted = $sorted | Where-Object { $_.MajorVersion -eq $PinToMajorVersion }
        if ($sorted.Count -eq 0) {
            throw "No versions found for $label $PinToMajorVersion"
        }
    }

    if ($UseMinorVersions -or $PinToMajorVersion -gt 0) {
        $unique = $sorted | Group-Object { "$($_.MajorVersion).$($_.MinorVersion)" } |
                  ForEach-Object { $_.Group | Select-Object -First 1 }
    }
    else {
        $unique = $sorted | Group-Object MajorVersion |
                  ForEach-Object { $_.Group | Select-Object -First 1 }
    }

    $unique = $unique | Sort-Object MajorVersion, MinorVersion, PatchVersion -Descending
    Write-Log "  $label version slots: $($unique.Count)" -Level INFO
    return $unique
}

# ============================================================================
# CALCULATE TARGET VERSION
# ============================================================================
function Get-TargetVersion {
    param(
        [array]$SortedVersions,
        [int]$VersionsBelow,
        [string]$Platform
    )

    $label = if ($Platform -eq 'macos') { 'macOS' } else { 'iOS/iPadOS' }

    if ($SortedVersions.Count -eq 0) { throw "No $label versions available" }

    $latest = $SortedVersions[0]
    Write-Log "  Latest ${label}: $($latest.Version) (Build: $($latest.Build))" -Level INFO

    Write-Log "  Top $label versions:" -Level DEBUG
    $SortedVersions | Select-Object -First ([Math]::Min(5, $SortedVersions.Count)) | ForEach-Object {
        Write-Log "    - $($_.Version) (Build: $($_.Build))" -Level DEBUG
    }

    if ($SortedVersions.Count -le $VersionsBelow) {
        Write-Log "  Not enough version history - using oldest available" -Level WARNING
        $target = $SortedVersions[-1]
    }
    else {
        $target = $SortedVersions[$VersionsBelow]
    }

    Write-Log "  Target $label minimum ($VersionsBelow below latest): $($target.Version)" -Level SUCCESS
    return $target
}

# ============================================================================
# AUTHENTICATION
# ============================================================================
function Get-GraphAccessToken {
    param(
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret,
        [switch]$UseManagedIdentity
    )

    if ($UseManagedIdentity) {
        Write-Log "Authenticating using Managed Identity..." -Level INFO
        try {
            $resourceUri   = "https://graph.microsoft.com"
            $tokenAuthUri  = $env:IDENTITY_ENDPOINT + "?resource=$resourceUri&api-version=2019-08-01"
            $tokenResponse = Invoke-RestMethodWithRetry -Method Get -Headers @{"X-IDENTITY-HEADER" = $env:IDENTITY_HEADER} -Uri $tokenAuthUri
            Write-Log "Managed Identity authentication successful" -Level SUCCESS
            return $tokenResponse.access_token
        }
        catch {
            Write-Log "Managed Identity authentication failed: $($_.Exception.Message)" -Level ERROR
            throw
        }
    }
    else {
        Write-Log "Authenticating using Service Principal..." -Level INFO
        try {
            $body = @{
                grant_type    = "client_credentials"
                client_id     = $ClientId
                client_secret = $ClientSecret
                scope         = "https://graph.microsoft.com/.default"
            }
            $response = Invoke-RestMethodWithRetry -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method Post -Body $body
            Write-Log "Service Principal authentication successful" -Level SUCCESS
            return $response.access_token
        }
        catch {
            Write-Log "Service Principal authentication failed: $($_.Exception.Message)" -Level ERROR
            throw
        }
    }
}

# ============================================================================
# GET COMPLIANCE POLICY
# ============================================================================
function Get-IntuneCompliancePolicy {
    param(
        $AccessToken,
        [string]$PolicyId,
        [string]$Platform
    )

    $label = if ($Platform -eq 'macos') { 'macOS' } else { 'iOS/iPadOS' }
    Write-Log "Retrieving $label compliance policy..." -Level INFO

    try {
        $headers = @{
            "Authorization" = "Bearer $AccessToken"
            "Content-Type"  = "application/json"
        }
        $policy = Invoke-RestMethodWithRetry -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$PolicyId" -Headers $headers -Method Get
        $expectedType = if ($Platform -eq 'macos') {
            "#microsoft.graph.macOSCompliancePolicy"
        }
        else {
            "#microsoft.graph.iosCompliancePolicy"
        }

        if ($policy.'@odata.type' -ne $expectedType) {
            throw "Policy type mismatch. Expected $expectedType, got $($policy.'@odata.type')"
        }

        Write-Log "  Policy: $($policy.displayName)" -Level SUCCESS
        Write-Log "  Current OS minimum: $($policy.osMinimumVersion)" -Level INFO
        return $policy
    }
    catch {
        Write-Log "Failed to retrieve $label compliance policy: $($_.Exception.Message)" -Level ERROR
        throw
    }
}

# ============================================================================
# UPDATE COMPLIANCE POLICY
# ============================================================================
function Update-IntuneCompliancePolicy {
    param(
        $AccessToken,
        [string]$PolicyId,
        [string]$NewMinimumVersion,
        [string]$Platform,
        [bool]$WhatIf = $false
    )

    $label   = if ($Platform -eq 'macos') { 'macOS' } else { 'iOS/iPadOS' }
    $odataType = if ($Platform -eq 'macos') {
        "#microsoft.graph.macOSCompliancePolicy"
    }
    else {
        "#microsoft.graph.iosCompliancePolicy"
    }

    if ($WhatIf) {
        Write-Log "[WHATIF] Would update $label policy to: $NewMinimumVersion" -Level WARNING
        return $true
    }

    Write-Log "Updating $label policy to minimum: $NewMinimumVersion..." -Level INFO

    try {
        $headers = @{
            "Authorization" = "Bearer $AccessToken"
            "Content-Type"  = "application/json"
        }

        $body = @{
            "@odata.type"    = $odataType
            osMinimumVersion = $NewMinimumVersion
        } | ConvertTo-Json

        $policyUrl = "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$PolicyId"
        $null = Invoke-RestMethodWithRetry -Uri $policyUrl -Headers $headers -Method Patch -Body $body

        $verifiedPolicy = Invoke-RestMethodWithRetry -Uri $policyUrl -Headers $headers -Method Get
        if ($verifiedPolicy.osMinimumVersion -ne $NewMinimumVersion) {
            throw "Post-update verification failed. Expected osMinimumVersion '$NewMinimumVersion', got '$($verifiedPolicy.osMinimumVersion)'"
        }

        Write-Log "$label policy updated successfully" -Level SUCCESS
        Write-Log "Verified minimum: $($verifiedPolicy.osMinimumVersion)" -Level SUCCESS
        Write-Log "New minimum: $NewMinimumVersion" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Failed to update $label policy: $($_.Exception.Message)" -Level ERROR

        if ($_.Exception.Response) {
            try {
                $reader       = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                Write-Log "Response: $responseBody" -Level ERROR
            } catch { }
        }
        throw
    }
}

# ============================================================================
# PROCESS A SINGLE PLATFORM
# Returns a result hashtable; does not throw — errors are captured in result.
# ============================================================================
function Invoke-PlatformUpdate {
    param(
        [hashtable]$PlatformConfig,
        [string]$Platform,
        $AccessToken,
        [bool]$WhatIf
    )

    $label = if ($Platform -eq 'macos') { 'macOS' } else { 'iOS/iPadOS' }

    try {
        Write-Log "" -Level INFO
        Write-Log "──────────────────────────────────────" -Level INFO
        Write-Log "Processing: $label" -Level INFO
        Write-Log "──────────────────────────────────────" -Level INFO

        # Fetch versions
        $builds = Get-SOFAVersions -Platform $Platform

        # Sort and filter
        $sorted = Get-SortedVersions `
            -Builds             $builds `
            -Platform           $Platform `
            -UseMinorVersions   $PlatformConfig.UseMinorVersions `
            -PinToMajorVersion  $PlatformConfig.PinToMajorVersion

        # Target version
        $target = Get-TargetVersion -SortedVersions $sorted -VersionsBelow $PlatformConfig.VersionsBelow -Platform $Platform

        # Get current policy
        $policy = Get-IntuneCompliancePolicy -AccessToken $AccessToken -PolicyId $PlatformConfig.PolicyId -Platform $Platform

        # Compare and update
        if ($policy.osMinimumVersion -eq $target.Version) {
            Write-Log "$label policy is up to date ($($policy.osMinimumVersion))" -Level SUCCESS
            return @{
                Success         = $true
                Platform        = $label
                PolicyId        = $PlatformConfig.PolicyId
                PolicyName      = $policy.displayName
                PreviousVersion = $policy.osMinimumVersion
                NewVersion      = $target.Version
                Updated         = $false
            }
        }
        else {
            Write-Log "$label update required: $($policy.osMinimumVersion) -> $($target.Version)" -Level WARNING

            $success = Update-IntuneCompliancePolicy `
                -AccessToken       $AccessToken `
                -PolicyId          $PlatformConfig.PolicyId `
                -NewMinimumVersion $target.Version `
                -Platform          $Platform `
                -WhatIf            $WhatIf

            return @{
                Success         = $success
                Platform        = $label
                PolicyId        = $PlatformConfig.PolicyId
                PolicyName      = $policy.displayName
                PreviousVersion = $policy.osMinimumVersion
                NewVersion      = $target.Version
                Updated         = $true
            }
        }
    }
    catch {
        Write-Log "$label processing failed: $($_.Exception.Message)" -Level ERROR
        return @{
            Success   = $false
            Platform  = $label
            Error     = $_.Exception.Message
        }
    }
}

# ============================================================================
# MAIN
# ============================================================================
function Main {
    $startTime = Get-Date

    try {
        Write-Log "========================================" -Level INFO
        Write-Log "Intune Compliance Policy Updater" -Level INFO
        Write-Log "Unified Runbook" -Level INFO
        Write-Log "========================================" -Level INFO
        Write-Log "Start time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level INFO
        Write-Log "" -Level INFO

        $config = Get-Configuration

        if ($script:testMode) {
            $testsPass = Test-Prerequisites -Config $config
            if (-not $testsPass) { throw "Prerequisite tests failed" }
            Write-Log "All prerequisite tests passed!" -Level SUCCESS
        }

        # Single authentication for both platforms
        Write-Log "" -Level INFO
        Write-Log "Authenticating to Microsoft Graph..." -Level INFO
        if ($config.UseManagedIdentity) {
            $token = Get-GraphAccessToken -UseManagedIdentity
        }
        else {
            $token = Get-GraphAccessToken -TenantId $config.TenantId -ClientId $config.ClientId -ClientSecret $config.ClientSecret
        }
        Write-Log "Authentication: $(if ($config.UseManagedIdentity) { 'Managed Identity' } else { 'Service Principal' })" -Level DEBUG

        # Process enabled platforms
        $results = @{}

        if ($config.EnableMacOS) {
            $results.macOS = Invoke-PlatformUpdate `
                -PlatformConfig $config.MacOS `
                -Platform       'macos' `
                -AccessToken    $token `
                -WhatIf         $config.WhatIf
        }
        else {
            Write-Log "" -Level INFO
            Write-Log "macOS: Skipped (ENABLE_MACOS = false)" -Level INFO
        }

        if ($config.EnableIOS) {
            $results.iOS = Invoke-PlatformUpdate `
                -PlatformConfig $config.IOS `
                -Platform       'ios' `
                -AccessToken    $token `
                -WhatIf         $config.WhatIf
        }
        else {
            Write-Log "" -Level INFO
            Write-Log "iOS/iPadOS: Skipped (ENABLE_IOS = false)" -Level INFO
        }

        # Overall success: true only if all enabled platforms succeeded
        $overallSuccess = $true
        foreach ($key in $results.Keys) {
            if (-not $results[$key].Success) { $overallSuccess = $false }
        }

        $duration = (Get-Date) - $startTime

        Write-Log "" -Level INFO
        Write-Log "========================================" -Level INFO
        if ($overallSuccess) {
            Write-Log "ALL PLATFORMS COMPLETE" -Level SUCCESS
        }
        else {
            Write-Log "COMPLETED WITH ERRORS" -Level WARNING
        }
        Write-Log "========================================" -Level INFO
        Write-Log "Duration: $($duration.TotalSeconds) seconds" -Level INFO

        return @{
            Success    = $overallSuccess
            AuthMethod = if ($config.UseManagedIdentity) { "Managed Identity" } else { "Service Principal" }
            Results    = $results
            Duration   = $duration.TotalSeconds
            Timestamp  = Get-Date -Format 'o'
        }
    }
    catch {
        Write-Log "" -Level ERROR
        Write-Log "========================================" -Level ERROR
        Write-Log "SCRIPT FAILED" -Level ERROR
        Write-Log "========================================" -Level ERROR
        Write-Log "Error: $($_.Exception.Message)" -Level ERROR
        Write-Log "Stack: $($_.ScriptStackTrace)" -Level ERROR

        return @{
            Success   = $false
            Error     = $_.Exception.Message
            Timestamp = Get-Date -Format 'o'
        }
    }
}

# ============================================================================
# EXECUTE
# ============================================================================
$result = Main

if ($script:isAzureAutomation) {
    Write-Output ""
    Write-Output "========================================="
    Write-Output "EXECUTION SUMMARY"
    Write-Output "========================================="
    Write-Output ($result | ConvertTo-Json -Depth 5)
}

if ($result.Success) { exit 0 } else { exit 1 }
