<#
.SYNOPSIS
    Unified diagnostics script for the combined macOS + iOS/iPadOS compliance runbook.

.DESCRIPTION
    Tests each component for both platforms in a single run:
    1. Load Azure Automation variables
    2. Test Microsoft Graph authentication
    3. Test API permissions
    4. Test access to enabled compliance policies
    5. Test SOFA feed access for each enabled platform

.NOTES
    Author: Niklas Bruhn (SSMacAdmin.com)
    Version: 4.1.0
#>

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

Write-Output "========================================="
Write-Output "Unified Compliance Runbook Diagnostics"
Write-Output "========================================="
Write-Output ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Load Variables
# ─────────────────────────────────────────────────────────────────────────────
Write-Output "[STEP 1] Loading Azure Automation Variables..."
try {
    # Auth method
    $useManagedIdentity = $false
    try {
        $miVar = Get-AutomationVariable -Name "USE_MANAGED_IDENTITY" -ErrorAction SilentlyContinue
        if ($null -ne $miVar) { $useManagedIdentity = ConvertTo-RunbookBoolean -Value $miVar }
    } catch { }

    # Platform toggles
    $enableMacOS = $false
    $enableIOS   = $false
    try {
        $enMac = Get-AutomationVariable -Name "ENABLE_MACOS" -ErrorAction SilentlyContinue
        if ($null -ne $enMac) { $enableMacOS = ConvertTo-RunbookBoolean -Value $enMac }
    } catch { }
    try {
        $enIOS = Get-AutomationVariable -Name "ENABLE_IOS" -ErrorAction SilentlyContinue
        if ($null -ne $enIOS) { $enableIOS = ConvertTo-RunbookBoolean -Value $enIOS }
    } catch { }

    Write-Output "  USE_MANAGED_IDENTITY: $useManagedIdentity"
    Write-Output "  ENABLE_MACOS:         $enableMacOS"
    Write-Output "  ENABLE_IOS:           $enableIOS"
    Write-Output ""

    if ($useManagedIdentity) {
        Write-Output "  Authentication: Managed Identity"
    }
    else {
        Write-Output "  Authentication: Service Principal"
        $tenantId     = Get-AutomationVariable -Name "INTUNE_TENANT_ID"
        $clientId     = Get-AutomationVariable -Name "INTUNE_CLIENT_ID"
        $clientSecret = Get-AutomationVariable -Name "INTUNE_CLIENT_SECRET"
        Write-Output "  INTUNE_TENANT_ID:     $($tenantId.Substring(0,8))..."
        Write-Output "  INTUNE_CLIENT_ID:     $($clientId.Substring(0,8))..."
        Write-Output "  INTUNE_CLIENT_SECRET: $($clientSecret.Length) chars"
    }

    Write-Output ""

    if ($enableMacOS) {
        $macosPolicyId = Get-AutomationVariable -Name "MACOS_POLICY_ID"
        Write-Output "  macOS Settings:"
        Write-Output "  MACOS_POLICY_ID: $($macosPolicyId.Substring(0,8))..."

        try {
            $p = Get-AutomationVariable -Name "MACOS_PIN_TO_MAJOR_VERSION" -ErrorAction SilentlyContinue
            if ($p) { Write-Output "  MACOS_PIN_TO_MAJOR_VERSION: $p" }
        } catch { }
        try {
            $v = Get-AutomationVariable -Name "MACOS_VERSIONS_BELOW" -ErrorAction SilentlyContinue
            if ($v) { Write-Output "  MACOS_VERSIONS_BELOW: $v" }
        } catch { }
        try {
            $u = Get-AutomationVariable -Name "MACOS_USE_MINOR_VERSIONS" -ErrorAction SilentlyContinue
            if ($null -ne $u) { Write-Output "  MACOS_USE_MINOR_VERSIONS: $u" }
        } catch { }
        Write-Output ""
    }

    if ($enableIOS) {
        $iosPolicyId = Get-AutomationVariable -Name "IOS_POLICY_ID"
        Write-Output "  iOS/iPadOS Settings:"
        Write-Output "  IOS_POLICY_ID: $($iosPolicyId.Substring(0,8))..."

        try {
            $p = Get-AutomationVariable -Name "IOS_PIN_TO_MAJOR_VERSION" -ErrorAction SilentlyContinue
            if ($p) { Write-Output "  IOS_PIN_TO_MAJOR_VERSION: $p" }
        } catch { }
        try {
            $v = Get-AutomationVariable -Name "IOS_VERSIONS_BELOW" -ErrorAction SilentlyContinue
            if ($v) { Write-Output "  IOS_VERSIONS_BELOW: $v" }
        } catch { }
        try {
            $u = Get-AutomationVariable -Name "IOS_USE_MINOR_VERSIONS" -ErrorAction SilentlyContinue
            if ($null -ne $u) { Write-Output "  IOS_USE_MINOR_VERSIONS: $u" }
        } catch { }
        Write-Output ""
    }

    if (-not $enableMacOS -and -not $enableIOS) {
        Write-Output "  WARNING: Both ENABLE_MACOS and ENABLE_IOS are false."
        Write-Output "  At least one platform must be enabled for the runbook to do anything."
        Write-Output ""
    }

    Write-Output "  RESULT: Variables loaded successfully"
    Write-Output ""
}
catch {
    Write-Output "  FAIL: Could not load variables - $($_.Exception.Message)"
    Write-Output ""
    Write-Output "  FIX:"
    Write-Output "  - Ensure USE_MANAGED_IDENTITY, ENABLE_MACOS, ENABLE_IOS exist"
    Write-Output "  - If ENABLE_MACOS=True: ensure MACOS_POLICY_ID exists"
    Write-Output "  - If ENABLE_IOS=True:   ensure IOS_POLICY_ID exists"
    Write-Output "  - Service Principal: ensure INTUNE_TENANT_ID, INTUNE_CLIENT_ID, INTUNE_CLIENT_SECRET"
    Write-Output ""
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Authentication
# ─────────────────────────────────────────────────────────────────────────────
Write-Output "[STEP 2] Testing Microsoft Graph Authentication..."
try {
    if ($useManagedIdentity) {
        $resourceUri   = "https://graph.microsoft.com"
        $tokenAuthUri  = $env:IDENTITY_ENDPOINT + "?resource=$resourceUri&api-version=2019-08-01"
        $tokenResponse = Invoke-RestMethod -Method Get -Headers @{"X-IDENTITY-HEADER" = $env:IDENTITY_HEADER} -Uri $tokenAuthUri -ErrorAction Stop
        $accessToken   = $tokenResponse.access_token

        Write-Output "  Method: Managed Identity"
        Write-Output "  Token length: $($accessToken.Length) chars"
        Write-Output "  RESULT: Authentication successful"
    }
    else {
        $body = @{
            grant_type    = "client_credentials"
            client_id     = $clientId
            client_secret = $clientSecret
            scope         = "https://graph.microsoft.com/.default"
        }
        $tokenResponse = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Method Post -Body $body -ErrorAction Stop
        $accessToken   = [string]$tokenResponse.access_token

        Write-Output "  Method: Service Principal"
        Write-Output "  Token type: $($tokenResponse.token_type)"
        Write-Output "  Token length: $($accessToken.Length) chars"
        Write-Output "  Expires in: $($tokenResponse.expires_in)s"
        Write-Output "  RESULT: Authentication successful"
    }

    Write-Output ""
}
catch {
    Write-Output "  FAIL: Authentication failed - $($_.Exception.Message)"
    Write-Output ""
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 3: API Permissions
# ─────────────────────────────────────────────────────────────────────────────
Write-Output "[STEP 3] Testing Microsoft Graph API Permissions..."
try {
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type"  = "application/json"
    }

    $policies = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies" -Headers $headers -Method Get -ErrorAction Stop

    $macPolicies = $policies.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.macOSCompliancePolicy' }
    $iosPolicies = $policies.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.iosCompliancePolicy' }

    Write-Output "  Total policies: $($policies.value.Count)"
    Write-Output "  macOS policies: $($macPolicies.Count)"
    Write-Output "  iOS policies:   $($iosPolicies.Count)"
    Write-Output ""
    Write-Output "  All policies:"
    foreach ($p in $policies.value) {
        $markers = @()
        if ($enableMacOS -and $p.id -eq $macosPolicyId) { $markers += "<-- macOS TARGET" }
        if ($enableIOS   -and $p.id -eq $iosPolicyId)   { $markers += "<-- iOS TARGET" }
        $markerStr = if ($markers.Count -gt 0) { "  " + ($markers -join " / ") } else { "" }
        $type = switch ($p.'@odata.type') {
            '#microsoft.graph.macOSCompliancePolicy' { '[macOS]' }
            '#microsoft.graph.iosCompliancePolicy'   { '[iOS]  ' }
            default                                  { '[Other]' }
        }
        Write-Output "  $type $($p.displayName) (ID: $($p.id))$markerStr"
    }

    Write-Output ""
    Write-Output "  RESULT: API access successful"
    Write-Output ""
}
catch {
    Write-Output "  FAIL: $($_.Exception.Message)"

    if ($_.Exception.Response.StatusCode.value__ -eq 403) {
        Write-Output ""
        Write-Output "  FIX (403 Forbidden):"
        Write-Output "  - Grant DeviceManagementConfiguration.ReadWrite.All"
        Write-Output "  - This single permission covers both macOS and iOS policies"
        Write-Output "  - For Managed Identity: re-run permission grant command"
        Write-Output "  - For Service Principal: grant admin consent in API permissions"
        Write-Output "  - Wait 5-10 minutes for permissions to propagate"
    }

    Write-Output ""
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Target Policy Access
# ─────────────────────────────────────────────────────────────────────────────
Write-Output "[STEP 4] Testing Access to Target Policies..."

$step4Passed = $true

if ($enableMacOS) {
    Write-Output ""
    Write-Output "  macOS Policy..."
    try {
        $headers = @{ "Authorization" = "Bearer $accessToken"; "Content-Type" = "application/json" }
        $policy  = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$macosPolicyId" -Headers $headers -Method Get -ErrorAction Stop

        $isMacOSPolicy = $policy.'@odata.type' -eq '#microsoft.graph.macOSCompliancePolicy'
        Write-Output "    Name:        $($policy.displayName)"
        Write-Output "    Type:        $($policy.'@odata.type')"
        Write-Output "    Min OS:      $($policy.osMinimumVersion)"
        Write-Output "    Is macOS:    $isMacOSPolicy"

        if (-not $isMacOSPolicy) {
            Write-Output "    WARNING: MACOS_POLICY_ID points to a non-macOS policy!"
            $step4Passed = $false
        }
        else {
            Write-Output "    RESULT: OK"
        }
    }
    catch {
        Write-Output "    FAIL: $($_.Exception.Message)"
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            Write-Output "    FIX: Update MACOS_POLICY_ID with the correct macOS policy GUID from Intune"
        }
        $step4Passed = $false
    }
}


if ($enableIOS) {
    Write-Output ""
    Write-Output "  iOS/iPadOS Policy..."
    try {
        $headers = @{ "Authorization" = "Bearer $accessToken"; "Content-Type" = "application/json" }
        $policy  = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$iosPolicyId" -Headers $headers -Method Get -ErrorAction Stop

        $isIOS = $policy.'@odata.type' -eq '#microsoft.graph.iosCompliancePolicy'
        Write-Output "    Name:            $($policy.displayName)"
        Write-Output "    Type:            $($policy.'@odata.type')"
        Write-Output "    Min OS:          $($policy.osMinimumVersion)"
        Write-Output "    Is iOS/iPadOS:   $isIOS"

        if (-not $isIOS) {
            Write-Output "    WARNING: IOS_POLICY_ID points to a non-iOS policy!"
            $step4Passed = $false
        }
        else {
            Write-Output "    RESULT: OK"
        }
    }
    catch {
        Write-Output "    FAIL: $($_.Exception.Message)"
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            Write-Output "    FIX: Update IOS_POLICY_ID with the correct iOS/iPadOS policy GUID from Intune"
        }
        $step4Passed = $false
    }
}

if ($step4Passed) {
    Write-Output ""
    Write-Output "  RESULT: All target policies accessible"
}
else {
    Write-Output ""
    Write-Output "  RESULT: One or more policy checks failed"
}

Write-Output ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: SOFA Feed Access
# ─────────────────────────────────────────────────────────────────────────────
Write-Output "[STEP 5] Testing SOFA Feed Access..."

if ($enableMacOS) {
    Write-Output ""
    Write-Output "  macOS Feed..."
    try {
        $sofaUrl  = "https://sofa.macadmins.io/v2/macos_data_feed.json"
        $sofaData = Invoke-RestMethod -Uri $sofaUrl -Method Get -TimeoutSec 30 -ErrorAction Stop

        $totalVersions = 0
        foreach ($mv in $sofaData.OSVersions) {
            if ($mv.Latest)           { $totalVersions++ }
            if ($mv.SecurityReleases) { $totalVersions += $mv.SecurityReleases.Count }
        }

        Write-Output "    Major versions:  $($sofaData.OSVersions.Count)"
        Write-Output "    Total entries:   $totalVersions"
        Write-Output "    Latest versions:"
        foreach ($mv in $sofaData.OSVersions | Select-Object -First 3) {
            if ($mv.Latest) {
                Write-Output "    - macOS $($mv.Latest.ProductVersion) (Build: $($mv.Latest.Build))"
            }
        }
        Write-Output "    RESULT: OK"
    }
    catch {
        Write-Output "    FAIL: $($_.Exception.Message)"
    }
}

if ($enableIOS) {
    Write-Output ""
    Write-Output "  iOS/iPadOS Feed..."
    try {
        $sofaUrl  = "https://sofa.macadmins.io/v2/ios_data_feed.json"
        $sofaData = Invoke-RestMethod -Uri $sofaUrl -Method Get -TimeoutSec 30 -ErrorAction Stop

        $totalVersions = 0
        foreach ($mv in $sofaData.OSVersions) {
            if ($mv.Latest)           { $totalVersions++ }
            if ($mv.SecurityReleases) { $totalVersions += $mv.SecurityReleases.Count }
        }

        Write-Output "    Major versions:  $($sofaData.OSVersions.Count)"
        Write-Output "    Total entries:   $totalVersions"
        Write-Output "    Latest versions:"
        foreach ($mv in $sofaData.OSVersions | Select-Object -First 3) {
            if ($mv.Latest) {
                Write-Output "    - iOS $($mv.Latest.ProductVersion) (Build: $($mv.Latest.Build))"
            }
        }
        Write-Output "    RESULT: OK"
    }
    catch {
        Write-Output "    FAIL: $($_.Exception.Message)"
    }
}

Write-Output ""

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Output "========================================="
Write-Output "DIAGNOSTICS COMPLETE"
Write-Output "========================================="
Write-Output ""
Write-Output "Platforms enabled:"
Write-Output "  macOS:      $enableMacOS"
Write-Output "  iOS/iPadOS: $enableIOS"
Write-Output ""
Write-Output "If all steps passed, the unified runbook is ready."
Write-Output "Run Update-IntuneCompliance-Unified as a test to verify end-to-end."
Write-Output ""
