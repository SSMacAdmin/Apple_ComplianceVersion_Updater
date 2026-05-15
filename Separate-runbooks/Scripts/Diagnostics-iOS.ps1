<#
.SYNOPSIS
    Diagnostics script for the iOS/iPadOS Intune Compliance Policy runbook.

.DESCRIPTION
    Tests each component separately to identify configuration issues:
    1. Load Azure Automation variables (iOS-specific)
    2. Test Microsoft Graph authentication
    3. Test API permissions
    4. Test access to the iOS/iPadOS compliance policy
    5. Test SOFA iOS feed access

.NOTES
    Author: Niklas Bruhn (SSMacAdmin.com)
    Version: 4.1.0
    Platform: iOS/iPadOS
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
Write-Output "iOS/iPadOS Compliance Runbook Diagnostics"
Write-Output "========================================="
Write-Output ""

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Load Variables
# ─────────────────────────────────────────────────────────────────────────────
Write-Output "[STEP 1] Loading Azure Automation Variables (iOS)..."
try {
    $useManagedIdentity = $false
    try {
        $miEnabled = Get-AutomationVariable -Name "USE_MANAGED_IDENTITY" -ErrorAction SilentlyContinue
        if ($null -ne $miEnabled) { $useManagedIdentity = ConvertTo-RunbookBoolean -Value $miEnabled }
    } catch { }

    if ($useManagedIdentity) {
        Write-Output "  Authentication: Managed Identity (system-assigned)"
        Write-Output "  No stored credentials required"
        Write-Output "  NOTE: Same identity used for both macOS and iOS runbooks"

        $iosPolicyId = Get-AutomationVariable -Name "IOS_POLICY_ID"
        Write-Output "  IOS_POLICY_ID: $($iosPolicyId.Substring(0,8))..."
    }
    else {
        Write-Output "  Authentication: Service Principal"
        Write-Output "  NOTE: Same credentials used for both macOS and iOS runbooks"

        $tenantId     = Get-AutomationVariable -Name "INTUNE_TENANT_ID"
        $clientId     = Get-AutomationVariable -Name "INTUNE_CLIENT_ID"
        $clientSecret = Get-AutomationVariable -Name "INTUNE_CLIENT_SECRET"
        $iosPolicyId  = Get-AutomationVariable -Name "IOS_POLICY_ID"

        Write-Output "  INTUNE_TENANT_ID:     $($tenantId.Substring(0,8))..."
        Write-Output "  INTUNE_CLIENT_ID:     $($clientId.Substring(0,8))..."
        Write-Output "  INTUNE_CLIENT_SECRET: $($clientSecret.Length) chars"
        Write-Output "  IOS_POLICY_ID:        $($iosPolicyId.Substring(0,8))..."
    }

    # iOS-specific optional variables
    try {
        $pin = Get-AutomationVariable -Name "IOS_PIN_TO_MAJOR_VERSION" -ErrorAction SilentlyContinue
        if ($pin) { Write-Output "  IOS_PIN_TO_MAJOR_VERSION: $pin" }
    } catch { }

    try {
        $vb = Get-AutomationVariable -Name "IOS_VERSIONS_BELOW" -ErrorAction SilentlyContinue
        if ($vb) { Write-Output "  IOS_VERSIONS_BELOW: $vb" }
    } catch { }

    try {
        $umv = Get-AutomationVariable -Name "IOS_USE_MINOR_VERSIONS" -ErrorAction SilentlyContinue
        if ($null -ne $umv) { Write-Output "  IOS_USE_MINOR_VERSIONS: $umv" }
    } catch { }

    Write-Output "  RESULT: Variables loaded successfully"
    Write-Output ""
}
catch {
    Write-Output "  FAIL: Could not load variables - $($_.Exception.Message)"
    Write-Output ""
    Write-Output "  FIX:"
    Write-Output "  - Ensure IOS_POLICY_ID exists in Automation Variables"
    Write-Output "  - Ensure USE_MANAGED_IDENTITY exists in Automation Variables"
    Write-Output "  - For Service Principal: also ensure INTUNE_TENANT_ID, INTUNE_CLIENT_ID, INTUNE_CLIENT_SECRET"
    Write-Output "  - Variable names are case-sensitive"
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

    if ($useManagedIdentity) {
        Write-Output ""
        Write-Output "  FIX (Managed Identity):"
        Write-Output "  - Verify System-assigned identity is enabled on the Automation Account"
        Write-Output "  - Verify the managed identity has DeviceManagementConfiguration.ReadWrite.All"
        Write-Output "  - The same identity covers both macOS and iOS policies"
    }
    else {
        Write-Output ""
        Write-Output "  FIX (Service Principal):"
        Write-Output "  - Check client secret has not expired"
        Write-Output "  - Verify Client ID and Tenant ID are correct"
        Write-Output "  - Ensure admin consent was granted for DeviceManagementConfiguration.ReadWrite.All"
    }

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

    Write-Output "  Total compliance policies found: $($policies.value.Count)"
    Write-Output ""

    $macPolicies = $policies.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.macOSCompliancePolicy' }
    $iosPolicies = $policies.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.iosCompliancePolicy' }

    Write-Output "  macOS policies: $($macPolicies.Count)"
    Write-Output "  iOS/iPadOS policies: $($iosPolicies.Count)"
    Write-Output ""

    Write-Output "  All policies:"
    foreach ($p in $policies.value) {
        $marker = if ($p.id -eq $iosPolicyId) { " <-- TARGET (iOS)" } else { "" }
        $type   = switch ($p.'@odata.type') {
            '#microsoft.graph.macOSCompliancePolicy' { '[macOS]' }
            '#microsoft.graph.iosCompliancePolicy'   { '[iOS]  ' }
            default                                  { '[Other]' }
        }
        Write-Output "  $type $($p.displayName) (ID: $($p.id))$marker"
    }

    Write-Output ""
    Write-Output "  RESULT: API access successful"
    Write-Output ""
}
catch {
    Write-Output "  FAIL: API access failed - $($_.Exception.Message)"

    if ($_.Exception.Response.StatusCode.value__ -eq 403) {
        Write-Output ""
        Write-Output "  FIX (403 Forbidden):"
        Write-Output "  - Grant DeviceManagementConfiguration.ReadWrite.All permission"
        Write-Output "  - This single permission covers both macOS and iOS policies"
        Write-Output "  - For App Registration: API permissions -> Grant admin consent"
        Write-Output "  - For Managed Identity: Re-run the permission grant script"
        Write-Output "  - Wait 5-10 minutes for permissions to propagate"
    }

    Write-Output ""
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 4: Target iOS Policy Access
# ─────────────────────────────────────────────────────────────────────────────
Write-Output "[STEP 4] Testing Access to Target iOS/iPadOS Policy..."
try {
    $headers = @{
        "Authorization" = "Bearer $accessToken"
        "Content-Type"  = "application/json"
    }

    $policy = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/deviceManagement/deviceCompliancePolicies/$iosPolicyId" -Headers $headers -Method Get -ErrorAction Stop

    $isIOS = $policy.'@odata.type' -eq '#microsoft.graph.iosCompliancePolicy'

    Write-Output "  Policy Name:          $($policy.displayName)"
    Write-Output "  Policy Type:          $($policy.'@odata.type')"
    Write-Output "  Current Min OS:       $($policy.osMinimumVersion)"
    Write-Output "  Is iOS/iPadOS policy: $isIOS"

    if (-not $isIOS) {
        Write-Output ""
        Write-Output "  WARNING: This policy is NOT an iOS/iPadOS policy!"
        Write-Output "  Expected: #microsoft.graph.iosCompliancePolicy"
        Write-Output "  Got:      $($policy.'@odata.type')"
        Write-Output "  Update IOS_POLICY_ID with the correct iOS/iPadOS policy ID."
    }
    else {
        Write-Output "  RESULT: Policy access successful"
    }

    Write-Output ""
}
catch {
    Write-Output "  FAIL: Policy access failed - $($_.Exception.Message)"

    if ($_.Exception.Response.StatusCode.value__ -eq 404) {
        Write-Output ""
        Write-Output "  FIX (404 Not Found):"
        Write-Output "  - The IOS_POLICY_ID value does not match any policy"
        Write-Output "  - Go to Intune -> Devices -> Compliance -> Policies"
        Write-Output "  - Click your iOS/iPadOS policy and copy the GUID from the URL"
        Write-Output "  - Update IOS_POLICY_ID variable"
    }

    Write-Output ""
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# STEP 5: SOFA iOS Feed
# ─────────────────────────────────────────────────────────────────────────────
Write-Output "[STEP 5] Testing SOFA iOS Feed Access..."
try {
    $sofaUrl  = "https://sofa.macadmins.io/v2/ios_data_feed.json"
    $sofaData = Invoke-RestMethod -Uri $sofaUrl -Method Get -TimeoutSec 30 -ErrorAction Stop

    if ($null -eq $sofaData -or $null -eq $sofaData.OSVersions) {
        Write-Output "  FAIL: SOFA iOS returned no OS versions"
    }
    else {
        $totalVersions = 0
        foreach ($mv in $sofaData.OSVersions) {
            if ($mv.Latest)           { $totalVersions++ }
            if ($mv.SecurityReleases) { $totalVersions += $mv.SecurityReleases.Count }
        }

        Write-Output "  URL: $sofaUrl"
        Write-Output "  Major versions: $($sofaData.OSVersions.Count)"
        Write-Output "  Total version entries: $totalVersions"
        Write-Output ""
        Write-Output "  Latest by major release:"
        foreach ($mv in $sofaData.OSVersions | Select-Object -First 4) {
            if ($mv.Latest) {
                Write-Output "  - iOS $($mv.Latest.ProductVersion) (Build: $($mv.Latest.Build), Released: $($mv.Latest.ReleaseDate))"
            }
        }
        Write-Output ""
        Write-Output "  RESULT: SOFA iOS feed accessible"
    }

    Write-Output ""
}
catch {
    Write-Output "  FAIL: $($_.Exception.Message)"
    Write-Output "  - This may be a transient network issue"
    Write-Output "  - SOFA is updated every 6 hours; brief downtime is possible"
    Write-Output "  - Verify connectivity to sofa.macadmins.io"
    Write-Output ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
Write-Output "========================================="
Write-Output "DIAGNOSTICS COMPLETE"
Write-Output "========================================="
Write-Output ""
Write-Output "If all steps passed, the iOS/iPadOS runbook is ready."
Write-Output "Run Update-IntuneIOSCompliance as a test to verify end-to-end."
Write-Output ""
