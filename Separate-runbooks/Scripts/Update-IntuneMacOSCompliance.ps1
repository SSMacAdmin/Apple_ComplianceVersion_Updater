<#
.SYNOPSIS
    Automatically updates Intune macOS Compliance Policy based on the SOFA feed.

.DESCRIPTION
    Fetches the latest macOS versions from the MacAdmins SOFA feed, calculates the version
    N releases behind the latest, and updates the specified Intune macOS compliance policy.

    Works in two modes:
    1. Standalone: Pass parameters directly or use environment variables
    2. Azure Automation: Automatically loads credentials from Azure Automation variables

.PARAMETER TenantId
    Azure AD Tenant ID (not needed in Azure Automation when using Managed Identity)

.PARAMETER ClientId
    Azure App Registration Client ID (not needed when using Managed Identity)

.PARAMETER ClientSecret
    Azure App Registration Client Secret (not needed when using Managed Identity)

.PARAMETER CompliancePolicyId
    The ID of the Intune macOS compliance policy to update

.PARAMETER VersionsBelow
    Number of major versions below latest to set as minimum (default: 2)

.PARAMETER UseMinorVersions
    If specified, calculates based on minor versions instead of major versions

.PARAMETER PinToMajorVersion
    Pin to a specific major version and track minor versions within that version.
    Example: -PinToMajorVersion 15 -VersionsBelow 2
    If latest is 15.7, sets minimum to 15.5 (ignoring macOS 16.x)

.PARAMETER UseManagedIdentity
    Force Managed Identity authentication (overrides variable setting)

.PARAMETER WhatIf
    Shows what changes would be made without actually making them

.PARAMETER RunTests
    Run prerequisite tests before executing the main script

.EXAMPLE
    # Standalone execution with parameters
    .\Update-IntuneMacOSCompliance.ps1 -TenantId "xxx" -ClientId "xxx" -ClientSecret "xxx" -CompliancePolicyId "xxx"

.EXAMPLE
    # Standalone with environment variables
    $env:INTUNE_TENANT_ID = "xxx"
    $env:INTUNE_CLIENT_ID = "xxx"
    $env:INTUNE_CLIENT_SECRET = "xxx"
    $env:INTUNE_POLICY_ID = "xxx"
    .\Update-IntuneMacOSCompliance.ps1

.EXAMPLE
    # Pin to macOS 15, stay 2 minor versions behind latest
    .\Update-IntuneMacOSCompliance.ps1 -PinToMajorVersion 15 -VersionsBelow 2

.NOTES
    Author: Niklas Bruhn (SSMacAdmin.com)
    Version: 4.0
    Platform: macOS

    Azure Automation Variables:
    - MACOS_POLICY_ID               (required)
    - USE_MANAGED_IDENTITY          (required, Boolean)
    - INTUNE_TENANT_ID              (required if not using Managed Identity)
    - INTUNE_CLIENT_ID              (required if not using Managed Identity)
    - INTUNE_CLIENT_SECRET          (required if not using Managed Identity, encrypted)
    - MACOS_PIN_TO_MAJOR_VERSION    (optional, Integer)
    - MACOS_VERSIONS_BELOW          (optional, Integer, default: 2)
    - MACOS_USE_MINOR_VERSIONS      (optional, Boolean, default: false)

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
    [string]$CompliancePolicyId,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 10)]
    [int]$VersionsBelow = 2,

    [Parameter(Mandatory = $false)]
    [switch]$UseMinorVersions,

    [Parameter(Mandatory = $false)]
    [int]$PinToMajorVersion,

    [Parameter(Mandatory = $false)]
    [switch]$UseManagedIdentity,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [switch]$RunTests
)

#Requires -Version 5.1

# ============================================================================
# GLOBAL VARIABLES
# ============================================================================
$script:testMode = $RunTests
$script:isAzureAutomation = $false
$script:logEntries = @()

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR', 'SUCCESS', 'DEBUG')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
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
    Write-Log "Loading configuration..." -Level INFO

    $config = @{
        TenantId           = $null
        ClientId           = $null
        ClientSecret       = $null
        CompliancePolicyId = $null
        VersionsBelow      = $VersionsBelow
        UseMinorVersions   = $UseMinorVersions
        PinToMajorVersion  = $PinToMajorVersion
        WhatIf             = $WhatIf
    }

    # Detect Azure Automation environment.
    # Probe with MACOS_POLICY_ID (always required regardless of auth method).
    try {
        $null = Get-AutomationVariable -Name "MACOS_POLICY_ID" -ErrorAction Stop
        $script:isAzureAutomation = $true
        Write-Log "Detected Azure Automation environment" -Level INFO
    }
    catch {
        $script:isAzureAutomation = $false
        Write-Log "Running in standalone mode" -Level INFO
    }

    if ($script:isAzureAutomation) {
        Write-Log "Loading credentials from Azure Automation variables..." -Level INFO
        try {
            $useManagedIdentity = $false
            try {
                $miEnabled = Get-AutomationVariable -Name "USE_MANAGED_IDENTITY" -ErrorAction SilentlyContinue
                if ($null -ne $miEnabled) {
                    $useManagedIdentity = [bool]$miEnabled
                    if ($useManagedIdentity) { Write-Log "Managed Identity mode enabled" -Level INFO }
                }
            } catch { }

            $config.UseManagedIdentity = $useManagedIdentity

            if (-not $useManagedIdentity) {
                $config.TenantId     = Get-AutomationVariable -Name "INTUNE_TENANT_ID"
                $config.ClientId     = Get-AutomationVariable -Name "INTUNE_CLIENT_ID"
                $config.ClientSecret = Get-AutomationVariable -Name "INTUNE_CLIENT_SECRET"
            }

            $config.CompliancePolicyId = Get-AutomationVariable -Name "MACOS_POLICY_ID"

            try {
                $vb = Get-AutomationVariable -Name "MACOS_VERSIONS_BELOW" -ErrorAction SilentlyContinue
                if ($vb) { $config.VersionsBelow = [int]$vb }
            } catch { }

            try {
                $umv = Get-AutomationVariable -Name "MACOS_USE_MINOR_VERSIONS" -ErrorAction SilentlyContinue
                if ($null -ne $umv) { $config.UseMinorVersions = [bool]$umv }
            } catch { }

            try {
                $pin = Get-AutomationVariable -Name "MACOS_PIN_TO_MAJOR_VERSION" -ErrorAction SilentlyContinue
                if ($pin -and $pin -gt 0) { $config.PinToMajorVersion = [int]$pin }
            } catch { }

            # Parameter overrides
            if ($CompliancePolicyId)  { $config.CompliancePolicyId = $CompliancePolicyId }
            if ($PinToMajorVersion)   { $config.PinToMajorVersion  = $PinToMajorVersion }
            if ($UseManagedIdentity)  { $config.UseManagedIdentity = $true }

            Write-Log "Successfully loaded credentials from Azure Automation" -Level SUCCESS
        }
        catch {
            Write-Log "Failed to load Azure Automation variables: $($_.Exception.Message)" -Level ERROR
            Write-Log "Required variables: MACOS_POLICY_ID, USE_MANAGED_IDENTITY" -Level ERROR
            Write-Log "Service Principal also requires: INTUNE_TENANT_ID, INTUNE_CLIENT_ID, INTUNE_CLIENT_SECRET" -Level ERROR
            throw
        }
    }
    else {
        $config.TenantId           = if ($TenantId)           { $TenantId }           else { $env:INTUNE_TENANT_ID }
        $config.ClientId           = if ($ClientId)           { $ClientId }           else { $env:INTUNE_CLIENT_ID }
        $config.ClientSecret       = if ($ClientSecret)       { $ClientSecret }       else { $env:INTUNE_CLIENT_SECRET }
        $config.CompliancePolicyId = if ($CompliancePolicyId) { $CompliancePolicyId } else { $env:MACOS_POLICY_ID }
    }

    # Validate
    $missing = @()
    if ($config.UseManagedIdentity) {
        if ([string]::IsNullOrWhiteSpace($config.CompliancePolicyId)) { $missing += "CompliancePolicyId" }
    }
    else {
        if ([string]::IsNullOrWhiteSpace($config.TenantId))           { $missing += "TenantId" }
        if ([string]::IsNullOrWhiteSpace($config.ClientId))           { $missing += "ClientId" }
        if ([string]::IsNullOrWhiteSpace($config.ClientSecret))       { $missing += "ClientSecret" }
        if ([string]::IsNullOrWhiteSpace($config.CompliancePolicyId)) { $missing += "CompliancePolicyId" }
    }

    if ($missing.Count -gt 0) {
        Write-Log "Missing required configuration: $($missing -join ', ')" -Level ERROR
        throw "Configuration incomplete"
    }

    Write-Log "Configuration loaded successfully" -Level SUCCESS
    Write-Log "  Authentication: $(if ($config.UseManagedIdentity) { 'Managed Identity' } else { 'Service Principal' })" -Level DEBUG
    Write-Log "  Policy ID: $($config.CompliancePolicyId.Substring(0,8))..." -Level DEBUG
    Write-Log "  Versions Below: $($config.VersionsBelow)" -Level DEBUG
    Write-Log "  Use Minor Versions: $($config.UseMinorVersions)" -Level DEBUG
    if ($config.PinToMajorVersion) {
        Write-Log "  Pin to Major Version: $($config.PinToMajorVersion)" -Level DEBUG
    }

    return $config
}

# ============================================================================
# PREREQUISITE TESTS
# ============================================================================
function Test-Prerequisites {
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

    Write-Log "Testing SOFA API access..." -Level INFO
    try {
        $test = Invoke-RestMethod -Uri "https://sofa.macadmins.io/v2/macos_data_feed.json" -Method Get -TimeoutSec 10 -ErrorAction Stop
        if ($test -and $test.OSVersions) {
            Write-Log "  SOFA API accessible ($($test.OSVersions.Count) major versions)" -Level SUCCESS
        }
        else {
            Write-Log "  SOFA API returned no data" -Level ERROR
            $allPassed = $false
        }
    }
    catch {
        Write-Log "  Cannot reach SOFA API: $($_.Exception.Message)" -Level ERROR
        $allPassed = $false
    }

    Write-Log "" -Level INFO
    return $allPassed
}

# ============================================================================
# FETCH macOS VERSIONS FROM SOFA
# ============================================================================
function Get-MacOSVersionsFromSOFA {
    Write-Log "Fetching macOS versions from SOFA (MacAdmins feed)..." -Level INFO

    try {
        $sofaUrl = "https://sofa.macadmins.io/v2/macos_data_feed.json"
        Write-Log "Querying: $sofaUrl" -Level DEBUG

        $response = Invoke-RestMethod -Uri $sofaUrl -Method Get -TimeoutSec 30 -ErrorAction Stop

        if ($null -eq $response -or $null -eq $response.OSVersions) {
            throw "No OS versions returned from SOFA API"
        }

        Write-Log "Successfully retrieved SOFA data" -Level SUCCESS

        $allVersions = @()
        foreach ($majorVersion in $response.OSVersions) {
            if ($majorVersion.Latest) {
                $allVersions += @{
                    version     = $majorVersion.Latest.ProductVersion
                    build       = $majorVersion.Latest.Build
                    released    = $true
                    releaseDate = $majorVersion.Latest.ReleaseDate
                }
            }
            if ($majorVersion.SecurityReleases) {
                foreach ($sec in $majorVersion.SecurityReleases) {
                    $allVersions += @{
                        version     = $sec.ProductVersion
                        build       = $sec.Build
                        released    = $true
                        releaseDate = $sec.ReleaseDate
                    }
                }
            }
        }

        Write-Log "Parsed $($allVersions.Count) macOS versions from SOFA feed" -Level SUCCESS
        return $allVersions
    }
    catch [System.OutOfMemoryException] {
        Write-Log "Out of memory when fetching SOFA data." -Level ERROR
        throw "Memory error fetching version data."
    }
    catch {
        Write-Log "Failed to fetch macOS versions from SOFA: $($_.Exception.Message)" -Level ERROR
        throw "Failed to retrieve macOS version data: $($_.Exception.Message)"
    }
}

# ============================================================================
# PARSE AND SORT VERSIONS
# ============================================================================
function Get-SortedMacOSVersions {
    param(
        [Parameter(Mandatory = $true)]
        [array]$Builds,

        [Parameter(Mandatory = $false)]
        [switch]$UseMinorVersions,

        [Parameter(Mandatory = $false)]
        [int]$PinToMajorVersion
    )

    Write-Log "Parsing macOS versions..." -Level INFO

    $released = $Builds | Where-Object { $_.version -notmatch 'beta|rc|preview|seed' }
    Write-Log "Found $($released.Count) released versions" -Level INFO

    $parsed = [System.Collections.Generic.List[PSObject]]::new()
    foreach ($build in $released) {
        if ($build.version -match '^(\d+)\.(\d+)(?:\.(\d+))?') {
            $major = [int]$Matches[1]
            if ($PinToMajorVersion -and $major -ne $PinToMajorVersion) { continue }

            $minor = [int]$Matches[2]
            $patch = if ($Matches[3]) { [int]$Matches[3] } else { 0 }

            $parsed.Add([PSCustomObject]@{
                Version      = $build.version
                Build        = $build.build
                MajorVersion = $major
                MinorVersion = $minor
                PatchVersion = $patch
                ReleaseDate  = if ($build.releaseDate) { $build.releaseDate } else { "Unknown" }
                FullVersion  = "$major.$minor.$patch"
            })
        }
    }

    $released = $null
    $Builds   = $null
    [System.GC]::Collect()

    $sorted = $parsed | Sort-Object MajorVersion, MinorVersion, PatchVersion -Descending

    if ($PinToMajorVersion) {
        Write-Log "Filtering to macOS $PinToMajorVersion.x only..." -Level INFO
        $sorted = $sorted | Where-Object { $_.MajorVersion -eq $PinToMajorVersion }
        if ($sorted.Count -eq 0) {
            throw "No versions found for macOS $PinToMajorVersion"
        }
        Write-Log "Found $($sorted.Count) versions for macOS $PinToMajorVersion" -Level INFO
    }

    if ($UseMinorVersions -or $PinToMajorVersion) {
        $unique = $sorted | Group-Object { "$($_.MajorVersion).$($_.MinorVersion)" } |
                  ForEach-Object { $_.Group | Select-Object -First 1 }
    }
    else {
        $unique = $sorted | Group-Object MajorVersion |
                  ForEach-Object { $_.Group | Select-Object -First 1 }
    }

    $unique = $unique | Sort-Object MajorVersion, MinorVersion, PatchVersion -Descending
    Write-Log "Unique version slots: $($unique.Count)" -Level INFO
    return $unique
}

# ============================================================================
# CALCULATE TARGET VERSION
# ============================================================================
function Get-TargetVersion {
    param(
        [Parameter(Mandatory = $true)]
        [array]$SortedVersions,

        [Parameter(Mandatory = $true)]
        [int]$VersionsBelow
    )

    if ($SortedVersions.Count -eq 0) { throw "No versions available" }

    $latest = $SortedVersions[0]
    Write-Log "Latest macOS version: $($latest.Version) (Build: $($latest.Build))" -Level INFO

    Write-Log "Top available versions:" -Level DEBUG
    $SortedVersions | Select-Object -First ([Math]::Min(5, $SortedVersions.Count)) | ForEach-Object {
        Write-Log "  - macOS $($_.Version) (Build: $($_.Build))" -Level DEBUG
    }

    if ($SortedVersions.Count -le $VersionsBelow) {
        Write-Log "Not enough version history - using oldest available" -Level WARNING
        $target = $SortedVersions[-1]
    }
    else {
        $target = $SortedVersions[$VersionsBelow]
    }

    Write-Log "Target minimum version ($VersionsBelow below latest): $($target.Version)" -Level SUCCESS
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
            $tokenResponse = Invoke-RestMethod -Method Get -Headers @{"X-IDENTITY-HEADER" = $env:IDENTITY_HEADER} -Uri $tokenAuthUri
            Write-Log "Managed Identity authentication successful" -Level SUCCESS
            return $tokenResponse.access_token
        }
        catch {
            Write-Log "Managed Identity authentication failed: $($_.Exception.Message)" -Level ERROR
            Write-Log "Ensure System-assigned identity is enabled and has DeviceManagementConfiguration.ReadWrite.All" -Level ERROR
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
            $response = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Method Post -Body $body -ErrorAction Stop
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
        [string]$PolicyId
    )

    Write-Log "Retrieving macOS compliance policy..." -Level INFO

    try {
        $headers = @{
            "Authorization" = "Bearer $AccessToken"
            "Content-Type"  = "application/json"
        }
        $policy = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$PolicyId" -Headers $headers -Method Get -ErrorAction Stop

        Write-Log "Retrieved policy: $($policy.displayName)" -Level SUCCESS
        Write-Log "Current OS minimum version: $($policy.osMinimumVersion)" -Level INFO
        return $policy
    }
    catch {
        Write-Log "Failed to retrieve compliance policy: $($_.Exception.Message)" -Level ERROR
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
        [switch]$WhatIf
    )

    if ($WhatIf) {
        Write-Log "[WHATIF] Would update macOS policy to minimum version: $NewMinimumVersion" -Level WARNING
        return $true
    }

    Write-Log "Updating macOS compliance policy to minimum version: $NewMinimumVersion..." -Level INFO

    try {
        $headers = @{
            "Authorization" = "Bearer $AccessToken"
            "Content-Type"  = "application/json"
        }

        $body = @{
            "@odata.type"    = "#microsoft.graph.macOSCompliancePolicy"
            osMinimumVersion = $NewMinimumVersion
        } | ConvertTo-Json

        $null = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$PolicyId" -Headers $headers -Method Patch -Body $body -ErrorAction Stop

        Write-Log "Successfully updated macOS compliance policy" -Level SUCCESS
        Write-Log "New minimum OS version: $NewMinimumVersion" -Level SUCCESS
        return $true
    }
    catch {
        Write-Log "Failed to update compliance policy: $($_.Exception.Message)" -Level ERROR

        if ($_.Exception.Response) {
            try {
                $reader       = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $responseBody = $reader.ReadToEnd()
                Write-Log "Response details: $responseBody" -Level ERROR
            } catch { }
        }
        throw
    }
}

# ============================================================================
# MAIN
# ============================================================================
function Main {
    $startTime = Get-Date

    try {
        Write-Log "========================================" -Level INFO
        Write-Log "Intune macOS Compliance Policy Updater" -Level INFO
        Write-Log "Separate Runbooks" -Level INFO
        Write-Log "========================================" -Level INFO
        Write-Log "Start time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Level INFO
        Write-Log "" -Level INFO

        $config = Get-Configuration

        if ($script:testMode) {
            $testsPass = Test-Prerequisites
            if (-not $testsPass) {
                throw "Prerequisite tests failed"
            }
            Write-Log "All prerequisite tests passed!" -Level SUCCESS
            Write-Log "" -Level INFO
        }

        # Step 1: Fetch macOS versions
        $builds = Get-MacOSVersionsFromSOFA

        # Step 2: Parse and sort
        $sorted = Get-SortedMacOSVersions -Builds $builds -UseMinorVersions:$config.UseMinorVersions -PinToMajorVersion $config.PinToMajorVersion

        # Step 3: Determine target version
        $target = Get-TargetVersion -SortedVersions $sorted -VersionsBelow $config.VersionsBelow

        Write-Log "" -Level INFO

        # Step 4: Authenticate
        if ($config.UseManagedIdentity) {
            $token = Get-GraphAccessToken -UseManagedIdentity
        }
        else {
            $token = Get-GraphAccessToken -TenantId $config.TenantId -ClientId $config.ClientId -ClientSecret $config.ClientSecret
        }

        # Step 5: Get current policy
        $policy = Get-IntuneCompliancePolicy -AccessToken $token -PolicyId $config.CompliancePolicyId

        # Step 6: Compare and update
        Write-Log "" -Level INFO
        if ($policy.osMinimumVersion -eq $target.FullVersion) {
            Write-Log "========================================" -Level SUCCESS
            Write-Log "macOS POLICY IS UP TO DATE" -Level SUCCESS
            Write-Log "========================================" -Level SUCCESS
            Write-Log "Policy: $($policy.displayName)" -Level INFO
            Write-Log "Current minimum: $($policy.osMinimumVersion)" -Level INFO
            Write-Log "No update needed" -Level SUCCESS
        }
        else {
            Write-Log "========================================" -Level WARNING
            Write-Log "UPDATE REQUIRED" -Level WARNING
            Write-Log "========================================" -Level WARNING
            Write-Log "Policy: $($policy.displayName)" -Level INFO
            Write-Log "Current: $($policy.osMinimumVersion)" -Level WARNING
            Write-Log "New:     $($target.FullVersion)" -Level WARNING
            Write-Log "" -Level INFO

            $success = Update-IntuneCompliancePolicy -AccessToken $token -PolicyId $config.CompliancePolicyId -NewMinimumVersion $target.FullVersion -WhatIf:$config.WhatIf

            if ($success) {
                Write-Log "" -Level INFO
                Write-Log "========================================" -Level SUCCESS
                Write-Log "UPDATE COMPLETE" -Level SUCCESS
                Write-Log "========================================" -Level SUCCESS
            }
        }

        $duration = (Get-Date) - $startTime
        Write-Log "" -Level INFO
        Write-Log "Completed successfully in $($duration.TotalSeconds) seconds" -Level SUCCESS

        return @{
            Success         = $true
            Platform        = "macOS"
            PolicyId        = $config.CompliancePolicyId
            PreviousVersion = $policy.osMinimumVersion
            NewVersion      = $target.FullVersion
            Updated         = ($policy.osMinimumVersion -ne $target.FullVersion)
            AuthMethod      = if ($config.UseManagedIdentity) { "Managed Identity" } else { "Service Principal" }
            Duration        = $duration.TotalSeconds
            Timestamp       = Get-Date -Format 'o'
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
            Platform  = "macOS"
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
    Write-Output ($result | ConvertTo-Json -Depth 3)
}

if ($result.Success) { exit 0 } else { exit 1 }
