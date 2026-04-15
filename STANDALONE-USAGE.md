# Standalone Usage Guide

Run the compliance updater scripts locally or in any PowerShell environment outside of Azure Automation — useful for testing, one-off updates, or CI/CD pipeline integration.

---

## Prerequisites

### Required

1. **PowerShell 5.1 or later**
   - Windows: Built-in
   - macOS/Linux: [Install PowerShell](https://docs.microsoft.com/powershell/scripting/install/installing-powershell)

2. **Azure App Registration** with:
   - Permission: `DeviceManagementConfiguration.ReadWrite.All` (Application permission, not Delegated)
   - Admin consent granted
   - Active client secret

3. **Configuration values:**
   - Tenant ID — Azure Active Directory → Overview
   - Client ID — App Registration → Overview → Application (client) ID
   - Client Secret — App Registration → Certificates & secrets → Value
   - Compliance Policy ID(s) — from the Intune portal URL

### How to get a Policy ID

1. Go to [Intune](https://intune.microsoft.com) → **Devices** → **Compliance** → **Policies**
2. Click the policy you want to manage
3. Copy the GUID from the URL:
   ```
   …/policyId/36b9b86c-2297-4c2c-9b25-8c023f9d4d57
              ↑ this is your Policy ID
   ```

---

## Scripts

| Platform | Script |
|---|---|
| macOS | `Separate-runbooks/Scripts/Update-IntuneMacOSCompliance.ps1` |
| iOS/iPadOS | `Separate-runbooks/Scripts/Update-IntuneIOSCompliance.ps1` |
| Both (unified) | `Unified-runbook/Scripts/Update-IntuneCompliance-Unified.ps1` |

All scripts accept parameters directly or read from environment variables. Environment variables are recommended to avoid exposing secrets in command history.

---

## Quick Start

### Method 1: Parameters

```powershell
# macOS
.\Separate-runbooks\Scripts\Update-IntuneMacOSCompliance.ps1 `
    -TenantId     "00000000-0000-0000-0000-000000000000" `
    -ClientId     "11111111-1111-1111-1111-111111111111" `
    -ClientSecret "your-secret-value" `
    -CompliancePolicyId "22222222-2222-2222-2222-222222222222"

# iOS/iPadOS
.\Separate-runbooks\Scripts\Update-IntuneIOSCompliance.ps1 `
    -TenantId     "00000000-0000-0000-0000-000000000000" `
    -ClientId     "11111111-1111-1111-1111-111111111111" `
    -ClientSecret "your-secret-value" `
    -CompliancePolicyId "33333333-3333-3333-3333-333333333333"
```

> Passing secrets as inline parameters may expose them in shell history. Use environment variables for better security.

### Method 2: Environment Variables (Recommended)

**Set variables for the current session:**

```powershell
# Shared credentials
$env:INTUNE_TENANT_ID     = "00000000-0000-0000-0000-000000000000"
$env:INTUNE_CLIENT_ID     = "11111111-1111-1111-1111-111111111111"
$env:INTUNE_CLIENT_SECRET = "your-secret-value"

# Per-platform policy IDs
$env:MACOS_POLICY_ID = "22222222-2222-2222-2222-222222222222"
$env:IOS_POLICY_ID   = "33333333-3333-3333-3333-333333333333"

# Run the scripts
.\Separate-runbooks\Scripts\Update-IntuneMacOSCompliance.ps1
.\Separate-runbooks\Scripts\Update-IntuneIOSCompliance.ps1
```

### Method 3: Persistent Environment Variables

**Windows (PowerShell):**

```powershell
[System.Environment]::SetEnvironmentVariable('INTUNE_TENANT_ID',     'your-tenant-id', 'User')
[System.Environment]::SetEnvironmentVariable('INTUNE_CLIENT_ID',     'your-client-id', 'User')
[System.Environment]::SetEnvironmentVariable('INTUNE_CLIENT_SECRET', 'your-secret',    'User')
[System.Environment]::SetEnvironmentVariable('MACOS_POLICY_ID',      'your-macos-policy-id', 'User')
[System.Environment]::SetEnvironmentVariable('IOS_POLICY_ID',        'your-ios-policy-id',   'User')

# Restart PowerShell, then run
.\Separate-runbooks\Scripts\Update-IntuneMacOSCompliance.ps1
.\Separate-runbooks\Scripts\Update-IntuneIOSCompliance.ps1
```

**macOS/Linux (bash/zsh):**

```bash
# Add to ~/.zshrc or ~/.bashrc
export INTUNE_TENANT_ID="00000000-0000-0000-0000-000000000000"
export INTUNE_CLIENT_ID="11111111-1111-1111-1111-111111111111"
export INTUNE_CLIENT_SECRET="your-secret-value"
export MACOS_POLICY_ID="22222222-2222-2222-2222-222222222222"
export IOS_POLICY_ID="33333333-3333-3333-3333-333333333333"

# Reload shell, then run
pwsh -File ./Separate-runbooks/Scripts/Update-IntuneMacOSCompliance.ps1
pwsh -File ./Separate-runbooks/Scripts/Update-IntuneIOSCompliance.ps1
```

---

## Version Strategies

All version strategies are available for both platforms via parameters or environment variables. The examples below use macOS — substitute the iOS script and `IOS_*` variable names as needed.

### Pin to Major Version (Recommended for phased rollouts)

```powershell
# macOS: stay on 26.x, track minor versions, ignore macOS 27.x
.\Update-IntuneMacOSCompliance.ps1 -PinToMajorVersion 26 -VersionsBelow 2
# Latest 26.x is 26.7 → requires 26.5

# iOS: stay on iOS 18.x
.\Update-IntuneIOSCompliance.ps1 -PinToMajorVersion 18 -VersionsBelow 2
# Latest 18.x is 18.5 → requires 18.3
```

**Use case:** Test macOS 27 on a pilot group while keeping production pinned to macOS 26.

### Track Major Versions (Conservative)

```powershell
# Stay N major versions behind the latest
.\Update-IntuneMacOSCompliance.ps1 -VersionsBelow 2
# Latest is macOS 26 → requires macOS 24
```

### Track Minor Versions (Granular)

```powershell
# Stay N minor versions behind within the same major version
.\Update-IntuneMacOSCompliance.ps1 -UseMinorVersions -VersionsBelow 2
# Latest 26.7 → requires 26.5
```

---

## Testing

### WhatIf — Preview Changes Without Applying

```powershell
.\Update-IntuneMacOSCompliance.ps1 -WhatIf
```

```
========================================
UPDATE REQUIRED
========================================
Policy: macOS - Separate - Minimum Version
Current: 26.3.0
New:     26.5.0

[WHATIF] Would update macOS policy to minimum version: 26.5.0
```

No changes are made. Remove `-WhatIf` to apply.

### RunTests — Validate Setup Before Execution

```powershell
.\Update-IntuneMacOSCompliance.ps1 -RunTests
.\Update-IntuneIOSCompliance.ps1   -RunTests
```

Tests PowerShell version and SOFA API connectivity before the script proceeds.

### Combined

```powershell
.\Update-IntuneMacOSCompliance.ps1 -RunTests -WhatIf
```

---

## Output Examples

### Up to date — no change needed

```
========================================
Intune macOS Compliance Policy Updater
Separate Runbooks
========================================
Running in standalone mode
...
Latest macOS version: 26.5.0 (Build: 26E...)
Target minimum version (2 below latest): 26.3.0

========================================
macOS POLICY IS UP TO DATE
========================================
Policy: macOS - Separate - Minimum Version
Current minimum: 26.3.0
No update needed
```

### Update applied

```
========================================
UPDATE REQUIRED
========================================
Policy: macOS - Separate - Minimum Version
Current: 26.1.0
New:     26.5.0

Successfully updated macOS compliance policy
New minimum OS version: 26.5.0

========================================
UPDATE COMPLETE
========================================
Completed successfully in 5.8 seconds

{
  "Success": true,
  "Platform": "macOS",
  "PreviousVersion": "26.1.0",
  "NewVersion": "26.5.0",
  "Updated": true,
  "AuthMethod": "Service Principal",
  "Duration": 5.8
}
```

---

## Parameter Reference

All parameters apply to both the macOS and iOS scripts.

| Parameter | Type | Description |
|---|---|---|
| `-TenantId` | String | Azure AD Tenant ID |
| `-ClientId` | String | App Registration Client ID |
| `-ClientSecret` | String | App Registration secret |
| `-CompliancePolicyId` | String | Intune compliance policy GUID |
| `-VersionsBelow` | Integer (1–10) | Versions behind latest (default: `2`) |
| `-PinToMajorVersion` | Integer | Pin to a specific major version |
| `-UseMinorVersions` | Switch | Track minor versions instead of major |
| `-WhatIf` | Switch | Preview changes without applying |
| `-RunTests` | Switch | Run prerequisite tests before execution |

### Environment Variables

| Variable | Purpose |
|---|---|
| `INTUNE_TENANT_ID` | Azure AD Tenant ID (shared) |
| `INTUNE_CLIENT_ID` | App Registration Client ID (shared) |
| `INTUNE_CLIENT_SECRET` | App Registration secret (shared) |
| `MACOS_POLICY_ID` | macOS compliance policy GUID |
| `IOS_POLICY_ID` | iOS/iPadOS compliance policy GUID |

---

## Troubleshooting

### "Configuration incomplete" or missing values

```powershell
# Check which variables are set
Write-Host "Tenant ID:     $([bool]$env:INTUNE_TENANT_ID)"
Write-Host "Client ID:     $([bool]$env:INTUNE_CLIENT_ID)"
Write-Host "Secret:        $([bool]$env:INTUNE_CLIENT_SECRET)"
Write-Host "macOS Policy:  $([bool]$env:MACOS_POLICY_ID)"
Write-Host "iOS Policy:    $([bool]$env:IOS_POLICY_ID)"
```

### "Authentication failed"

1. Verify Tenant ID and Client ID are correct
2. Check the client secret has not expired (App Registration → Certificates & secrets)
3. Confirm admin consent has been granted (green checkmark in API permissions)

### "Failed to retrieve versions from SOFA"

```powershell
# Test connectivity manually
Invoke-RestMethod -Uri "https://sofa.macadmins.io/v2/macos_data_feed.json"
Invoke-RestMethod -Uri "https://sofa.macadmins.io/v2/ios_data_feed.json"
```

SOFA is updated every 6 hours. If it is temporarily unavailable, wait a few minutes and retry.

### "No versions found for [platform] [X]"

The major version you pinned to does not exist in the SOFA feed yet. Check current available versions at [sofa.macadmins.io](https://sofa.macadmins.io) and adjust `PinToMajorVersion` accordingly.

### Policy not updating despite no errors

Run with `-WhatIf` to see what the script believes should happen:

```powershell
.\Update-IntuneMacOSCompliance.ps1 -WhatIf
```

If the output says "policy is up to date", the current policy version already matches the calculated target — no update is needed.

---

## Common Scenarios

### Scenario 1: Phased OS Rollout

Manage two separate policies from the same machine — production pinned to the current OS, pilot tracking the latest.

```powershell
# Production — pinned to macOS 26
.\Update-IntuneMacOSCompliance.ps1 `
    -CompliancePolicyId "prod-policy-guid" `
    -PinToMajorVersion 26 `
    -VersionsBelow 2
# Latest 26.x is 26.7 → requires 26.5

# Pilot — tracking macOS 27
.\Update-IntuneMacOSCompliance.ps1 `
    -CompliancePolicyId "pilot-policy-guid" `
    -PinToMajorVersion 27 `
    -VersionsBelow 1
# Latest 27.x is 27.3 → requires 27.2
```

### Scenario 2: Update Both Platforms in One Session

```powershell
$env:INTUNE_TENANT_ID     = "your-tenant-id"
$env:INTUNE_CLIENT_ID     = "your-client-id"
$env:INTUNE_CLIENT_SECRET = "your-secret"
$env:MACOS_POLICY_ID      = "your-macos-policy-id"
$env:IOS_POLICY_ID        = "your-ios-policy-id"

.\Separate-runbooks\Scripts\Update-IntuneMacOSCompliance.ps1 -PinToMajorVersion 26 -VersionsBelow 2
.\Separate-runbooks\Scripts\Update-IntuneIOSCompliance.ps1   -PinToMajorVersion 18 -VersionsBelow 2
```

### Scenario 3: Scheduled Local Execution

**Windows Task Scheduler:**

1. Open Task Scheduler → Create Task
2. Trigger: Weekly, Tuesday, 02:00
3. Action: Start a program
   - Program: `powershell.exe`
   - Arguments: `-File "C:\Scripts\Update-IntuneMacOSCompliance.ps1" -PinToMajorVersion 26 -VersionsBelow 2`
4. Set environment variables at User scope (Method 3 above)

**macOS/Linux cron:**

```bash
crontab -e

# Tuesdays at 2 AM — macOS policy
0 2 * * 2 /usr/local/bin/pwsh -File /path/to/Update-IntuneMacOSCompliance.ps1 -PinToMajorVersion 26

# Tuesdays at 2:05 AM — iOS policy
5 2 * * 2 /usr/local/bin/pwsh -File /path/to/Update-IntuneIOSCompliance.ps1 -PinToMajorVersion 18
```

### Scenario 4: CI/CD Pipeline

**Azure DevOps:**

```yaml
trigger:
  schedules:
  - cron: "0 2 * * 2"
    branches:
      include:
      - main

pool:
  vmImage: 'windows-latest'

steps:
- task: PowerShell@2
  displayName: 'Update macOS Compliance Policy'
  inputs:
    filePath: 'Separate-runbooks/Scripts/Update-IntuneMacOSCompliance.ps1'
    arguments: '-PinToMajorVersion 26 -VersionsBelow 2'
  env:
    INTUNE_TENANT_ID:     $(IntuneTenatId)
    INTUNE_CLIENT_ID:     $(IntuneClientId)
    INTUNE_CLIENT_SECRET: $(IntuneClientSecret)
    MACOS_POLICY_ID:      $(MacOSPolicyId)

- task: PowerShell@2
  displayName: 'Update iOS Compliance Policy'
  inputs:
    filePath: 'Separate-runbooks/Scripts/Update-IntuneIOSCompliance.ps1'
    arguments: '-PinToMajorVersion 18 -VersionsBelow 2'
  env:
    INTUNE_TENANT_ID:     $(IntuneTenatId)
    INTUNE_CLIENT_ID:     $(IntuneClientId)
    INTUNE_CLIENT_SECRET: $(IntuneClientSecret)
    IOS_POLICY_ID:        $(IOSPolicyId)
```

**GitHub Actions:**

```yaml
name: Update Intune Compliance Policies
on:
  schedule:
    - cron: '0 2 * * 2'  # Tuesdays at 2 AM UTC

jobs:
  update-compliance:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4

      - name: Update macOS Compliance Policy
        shell: pwsh
        run: ./Separate-runbooks/Scripts/Update-IntuneMacOSCompliance.ps1 -PinToMajorVersion 26 -VersionsBelow 2
        env:
          INTUNE_TENANT_ID:     ${{ secrets.INTUNE_TENANT_ID }}
          INTUNE_CLIENT_ID:     ${{ secrets.INTUNE_CLIENT_ID }}
          INTUNE_CLIENT_SECRET: ${{ secrets.INTUNE_CLIENT_SECRET }}
          MACOS_POLICY_ID:      ${{ secrets.MACOS_POLICY_ID }}

      - name: Update iOS/iPadOS Compliance Policy
        shell: pwsh
        run: ./Separate-runbooks/Scripts/Update-IntuneIOSCompliance.ps1 -PinToMajorVersion 18 -VersionsBelow 2
        env:
          INTUNE_TENANT_ID:     ${{ secrets.INTUNE_TENANT_ID }}
          INTUNE_CLIENT_ID:     ${{ secrets.INTUNE_CLIENT_ID }}
          INTUNE_CLIENT_SECRET: ${{ secrets.INTUNE_CLIENT_SECRET }}
          IOS_POLICY_ID:        ${{ secrets.IOS_POLICY_ID }}
```

---

## Security Best Practices

- Use environment variables instead of inline parameters (avoids shell history exposure)
- Never commit credentials to source control — use pipeline secrets or a vault
- Rotate client secrets before expiry (24 months max); set a calendar reminder 30 days ahead
- Use Azure Key Vault for production deployments with elevated security requirements
- Consider migrating to Azure Automation with Managed Identity to eliminate credentials entirely

---

## Migrate to Azure Automation

For zero-maintenance deployment with no stored credentials, Azure Automation with Managed Identity is the recommended approach:

- No credentials to manage or rotate
- Fully scheduled — no local machine required
- Built-in job history and alerting

See [AZURE-AUTOMATION-SETUP.md](AZURE-AUTOMATION-SETUP.md) for complete instructions.
