# Separate Runbooks — Setup Guide

Two independent runbooks, one per platform. Each has its own schedule, variables, and diagnostics. Run and troubleshoot macOS and iOS independently.

---

## Overview

| Runbook | Script | Diagnostics | SOFA Feed |
|---|---|---|---|
| macOS | `Update-IntuneMacOSCompliance.ps1` | `Diagnostics-macOS.ps1` | `macos_data_feed.json` |
| iOS/iPadOS | `Update-IntuneIOSCompliance.ps1` | `Diagnostics-iOS.ps1` | `ios_data_feed.json` |

**Shared:** Authentication (Managed Identity or Service Principal), Graph API permission, Automation Account.

**Separate:** Policy IDs, version pinning settings, schedules, diagnostics.

---

## Prerequisites

- Azure Automation Account
- Intune macOS compliance policy (at least one)
- Intune iOS/iPadOS compliance policy (at least one)
- `DeviceManagementConfiguration.ReadWrite.All` Graph API permission

---

## Part 1: Authentication Setup

Choose **one** method. The same credential is used by both runbooks.

### Option A: Managed Identity (Recommended)

**1. Enable System-Assigned Identity**

1. Open your Automation Account
2. Go to **Identity** → **System assigned**
3. Toggle **Status** to **On** → **Save**
4. Copy the **Object (principal) ID**

**2. Grant Graph Permission (Azure Cloud Shell)**

```powershell
# Connect to Graph
Connect-MgGraph -Scopes "Application.Read.All","AppRoleAssignment.ReadWrite.All"

$managedIdentityId = "PASTE-YOUR-OBJECT-ID-HERE"
$graphAppId        = "00000003-0000-0000-c000-000000000000"

$graphSP    = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
$permission = $graphSP.AppRoles | Where-Object { $_.Value -eq "DeviceManagementConfiguration.ReadWrite.All" }

New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $managedIdentityId `
    -PrincipalId        $managedIdentityId `
    -ResourceId         $graphSP.Id `
    -AppRoleId          $permission.Id

Write-Host "Permission granted"
```

### Option B: Service Principal

1. **Azure AD → App Registrations → New registration**
   - Name: `Intune-Compliance-Automation`
   - Supported account types: This directory only
2. **API permissions → Add → Microsoft Graph → Application**
   - Add: `DeviceManagementConfiguration.ReadWrite.All`
   - Click **Grant admin consent**
3. **Certificates & secrets → New client secret**
   - Copy the **Value** immediately (shown only once)
4. Collect: **Tenant ID**, **Client ID**, **Client Secret**

---

## Part 2: Create Automation Variables

Navigate to your **Automation Account → Variables**.

### Shared Variables (both runbooks use these)

| Variable | Type | Value | Encrypted |
|---|---|---|---|
| `USE_MANAGED_IDENTITY` | Boolean | `True` / `False` | No |
| `INTUNE_TENANT_ID` | String | Your tenant GUID | No |
| `INTUNE_CLIENT_ID` | String | App registration client ID | No |
| `INTUNE_CLIENT_SECRET` | String | App registration secret | **Yes** |

> `INTUNE_TENANT_ID`, `INTUNE_CLIENT_ID`, `INTUNE_CLIENT_SECRET` are only needed when `USE_MANAGED_IDENTITY = False`.

---

### macOS Variables

| Variable | Type | Value | Required |
|---|---|---|---|
| `INTUNE_POLICY_ID` | String | macOS compliance policy GUID | Required |
| `PIN_TO_MAJOR_VERSION` | Integer | e.g. `26` | Recommended |
| `VERSIONS_BELOW` | Integer | `2` | Optional |
| `USE_MINOR_VERSIONS` | Boolean | `False` | Optional |

**How to get your macOS Policy ID:**
1. Go to [Intune](https://intune.microsoft.com) → Devices → Compliance → Policies
2. Click your macOS policy
3. Copy the GUID from the URL: `…/policyId/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`

---

### iOS/iPadOS Variables

| Variable | Type | Value | Required |
|---|---|---|---|
| `IOS_POLICY_ID` | String | iOS/iPadOS compliance policy GUID | Required |
| `IOS_PIN_TO_MAJOR_VERSION` | Integer | e.g. `18` | Recommended |
| `IOS_VERSIONS_BELOW` | Integer | `2` | Optional |
| `IOS_USE_MINOR_VERSIONS` | Boolean | `False` | Optional |

**How to get your iOS Policy ID:**
1. Go to [Intune](https://intune.microsoft.com) → Devices → Compliance → Policies
2. Click your iOS/iPadOS policy
3. Copy the GUID from the URL

> **iOS-specific variables are prefixed with `IOS_`** to clearly distinguish them from macOS variables in the same Automation Account.

---

## Part 3: Create Runbooks

Create four runbooks in your Automation Account → **Runbooks**.

### Runbook 1: Update-macOS-Compliance-Policy

| Field | Value |
|---|---|
| Name | `Update-macOS-Compliance-Policy` |
| Type | PowerShell |
| Runtime | 7.2 |
| Description | Updates Intune macOS compliance policy from SOFA feed |

Content: paste `Scripts/Update-IntuneMacOSCompliance.ps1`

### Runbook 2: Update-iOS-Compliance-Policy

| Field | Value |
|---|---|
| Name | `Update-iOS-Compliance-Policy` |
| Type | PowerShell |
| Runtime | 7.2 |
| Description | Updates Intune iOS/iPadOS compliance policy from SOFA feed |

Content: paste `Scripts/Update-IntuneIOSCompliance.ps1`

### Runbook 3: Diagnostics-macOS

| Field | Value |
|---|---|
| Name | `Diagnostics-macOS` |
| Type | PowerShell |
| Runtime | 7.2 |
| Description | Pre-flight diagnostics for macOS compliance runbook |

Content: paste `Scripts/Diagnostics-macOS.ps1`

### Runbook 4: Diagnostics-iOS

| Field | Value |
|---|---|
| Name | `Diagnostics-iOS` |
| Type | PowerShell |
| Runtime | 7.2 |
| Description | Pre-flight diagnostics for iOS/iPadOS compliance runbook |

Content: paste `Scripts/Diagnostics-iOS.ps1`

After pasting each script: **Save** → **Publish**.

---

## Part 4: Test

### Run macOS Diagnostics

1. Open `Diagnostics-macOS` → **Start**
2. All 5 steps should pass:

```
[STEP 1] Loading Azure Automation Variables...
  RESULT: Variables loaded successfully

[STEP 2] Testing Microsoft Graph Authentication...
  RESULT: Authentication successful

[STEP 3] Testing Microsoft Graph API Permissions...
  RESULT: API access successful

[STEP 4] Testing Access to Target macOS Policy...
  Is macOS policy: True
  RESULT: Policy access successful

[STEP 5] Testing SOFA macOS Feed Access...
  RESULT: SOFA macOS feed accessible
```

### Run iOS Diagnostics

1. Open `Diagnostics-iOS` → **Start**
2. All 5 steps should pass:

```
[STEP 1] Loading Azure Automation Variables (iOS)...
  IOS_POLICY_ID: xxxxxxxx...
  RESULT: Variables loaded successfully

[STEP 2] Testing Microsoft Graph Authentication...
  RESULT: Authentication successful

[STEP 3] Testing Microsoft Graph API Permissions...
  RESULT: API access successful

[STEP 4] Testing Access to Target iOS/iPadOS Policy...
  Is iOS/iPadOS policy: True
  RESULT: Policy access successful

[STEP 5] Testing SOFA iOS Feed Access...
  RESULT: SOFA iOS feed accessible
```

### Run Main Scripts

Once diagnostics pass:

1. Open `Update-macOS-Compliance-Policy` → **Start** → **OK**
2. Open `Update-iOS-Compliance-Policy` → **Start** → **OK**

Expected output (JSON summary):
```json
{
  "Success": true,
  "Platform": "macOS",
  "PolicyId": "xxxxxxxx-...",
  "PreviousVersion": "26.3.0",
  "NewVersion": "26.4.0",
  "Updated": true,
  "AuthMethod": "Managed Identity",
  "Duration": 4.2,
  "Timestamp": "2026-04-14T..."
}
```

---

## Part 5: Schedule

Each runbook gets its own independent schedule. You can run them on the same or different cadence.

### Create a schedule

1. Automation Account → **Schedules** → **+ Add a schedule**
2. Example: `Weekly-Tuesday-2AM`
   - Recurrence: Weekly, Tuesday, 02:00
3. **Create**

### Link schedules to runbooks

1. Open `Update-macOS-Compliance-Policy` → **Schedules** → **+ Add a schedule**
2. Select `Weekly-Tuesday-2AM` → **OK**
3. Repeat for `Update-iOS-Compliance-Policy`

Both runbooks can share one schedule, or each can have its own.

---

## Variable Reference

Complete list of all variables for this option:

| Variable | Used By | Purpose |
|---|---|---|
| `USE_MANAGED_IDENTITY` | Both | Auth method selector |
| `INTUNE_TENANT_ID` | Both | Tenant ID (SP mode only) |
| `INTUNE_CLIENT_ID` | Both | Client ID (SP mode only) |
| `INTUNE_CLIENT_SECRET` | Both | Client secret (SP mode only, encrypted) |
| `INTUNE_POLICY_ID` | macOS | macOS policy GUID |
| `PIN_TO_MAJOR_VERSION` | macOS | Pin to macOS major version |
| `VERSIONS_BELOW` | macOS | Versions behind latest (default: 2) |
| `USE_MINOR_VERSIONS` | macOS | Track minor versions (default: false) |
| `IOS_POLICY_ID` | iOS | iOS/iPadOS policy GUID |
| `IOS_PIN_TO_MAJOR_VERSION` | iOS | Pin to iOS major version |
| `IOS_VERSIONS_BELOW` | iOS | Versions behind latest (default: 2) |
| `IOS_USE_MINOR_VERSIONS` | iOS | Track minor versions (default: false) |

---

## Troubleshooting

### "Could not load variables" on iOS diagnostics

The iOS runbook uses `IOS_POLICY_ID` (not `INTUNE_POLICY_ID`). Verify the variable name exactly.

### Policy type mismatch warning

Step 4 of each diagnostics script warns if the policy ID points to the wrong platform. Make sure `INTUNE_POLICY_ID` points to a macOS policy and `IOS_POLICY_ID` points to an iOS/iPadOS policy.

### Authentication fails on one runbook but not the other

Both runbooks use identical authentication code. If one passes and the other fails, it is likely a timing issue — wait a few minutes and retry.

### SOFA API fails

SOFA is maintained by the MacAdmins community and updated every 6 hours. Brief downtime is possible. The scheduled runbook will simply retry on its next execution.

---

## Ongoing Maintenance

**Managed Identity:** No maintenance required — no credentials to rotate.

**Service Principal:** When the client secret nears expiry:
1. Create a new secret in the App Registration
2. Update `INTUNE_CLIENT_SECRET` in Automation Variables
3. Test both runbooks
4. Delete the old secret

**Adding new policies:** Create additional variables (`IOS_POLICY_ID_2`, etc.) and run a second instance of the runbook with a parameter override, or adapt the script to loop over multiple policy IDs.

---

## Comparison: When to choose Separate vs Unified Runbooks

| | Separate Runbooks | Unified Runbook |
|---|---|---|
| Independent schedules | Yes | No (single schedule for both) |
| Independent failure handling | Yes | No (one failure can affect the other) |
| Variable count | Higher | Lower |
| Runbook count | 4 (2 main + 2 diag) | 2 (1 main + 1 diag) |
| Best for | Teams managing platforms separately | Simpler management, single execution |
