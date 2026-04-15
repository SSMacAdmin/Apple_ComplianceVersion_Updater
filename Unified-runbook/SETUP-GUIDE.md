# Unified Runbook — Setup Guide

A single runbook handles both macOS and iOS/iPadOS in one execution. Each platform is independently enabled or disabled via variables, so you can manage both platforms with a minimal variable set and a single scheduled job.

---

## Overview

| Runbook | Script | Handles |
|---|---|---|
| `Update-IntuneCompliance-Unified` | `Update-IntuneCompliance-Unified.ps1` | macOS + iOS/iPadOS |
| `Diagnostics-Unified` | `Diagnostics-Unified.ps1` | Both platforms |

**One token, one job, one schedule — processes whichever platforms are enabled.**

---

## Prerequisites

- Azure Automation Account
- At least one Intune compliance policy (macOS and/or iOS/iPadOS)
- `DeviceManagementConfiguration.ReadWrite.All` Graph API permission (covers both platforms)

---

## Part 1: Authentication Setup

Choose **one** method. It is shared by both platforms.

### Option A: Managed Identity (Recommended)

**1. Enable System-Assigned Identity**

1. Open your Automation Account
2. Go to **Identity** → **System assigned**
3. Toggle **Status** to **On** → **Save**
4. Copy the **Object (principal) ID**

**2. Grant Graph Permission (Azure Cloud Shell)**

```powershell
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

This single permission grant covers both macOS and iOS policy updates.

### Option B: Service Principal

1. **Azure AD → App Registrations → New registration**
   - Name: `Intune-Compliance-Automation`
2. **API permissions → Microsoft Graph → Application permissions**
   - Add: `DeviceManagementConfiguration.ReadWrite.All`
   - **Grant admin consent**
3. **Certificates & secrets → New client secret** — copy the value immediately
4. Collect: **Tenant ID**, **Client ID**, **Client Secret**

---

## Part 2: Create Automation Variables

Navigate to your **Automation Account → Variables**.

### Authentication Variables

| Variable | Type | Value | Encrypted |
|---|---|---|---|
| `USE_MANAGED_IDENTITY` | Boolean | `True` / `False` | No |
| `INTUNE_TENANT_ID` | String | Your tenant GUID | No |
| `INTUNE_CLIENT_ID` | String | App registration client ID | No |
| `INTUNE_CLIENT_SECRET` | String | App registration secret | **Yes** |

> Tenant/Client variables only needed when `USE_MANAGED_IDENTITY = False`.

---

### Platform Enable/Disable

| Variable | Type | Value | Purpose |
|---|---|---|---|
| `ENABLE_MACOS` | Boolean | `True` / `False` | Enable macOS policy updates |
| `ENABLE_IOS` | Boolean | `True` / `False` | Enable iOS/iPadOS policy updates |

Set to `True` for each platform you want to manage. You can start with just one and enable the other later — just set the variable and the next run picks it up automatically.

---

### macOS Variables (when `ENABLE_MACOS = True`)

| Variable | Type | Value | Required |
|---|---|---|---|
| `MACOS_POLICY_ID` | String | macOS compliance policy GUID | Required |
| `MACOS_PIN_TO_MAJOR_VERSION` | Integer | e.g. `26` | Recommended |
| `MACOS_VERSIONS_BELOW` | Integer | `2` | Optional |
| `MACOS_USE_MINOR_VERSIONS` | Boolean | `False` | Optional |

**How to get your macOS Policy ID:**
1. Go to [Intune](https://intune.microsoft.com) → Devices → Compliance → Policies
2. Click your macOS policy
3. Copy the GUID from the URL: `…/policyId/XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX`

---

### iOS/iPadOS Variables (when `ENABLE_IOS = True`)

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

---

### Minimal Variable Set (Managed Identity, both platforms)

```
USE_MANAGED_IDENTITY   = True
ENABLE_MACOS           = True
ENABLE_IOS             = True
MACOS_POLICY_ID        = <your-macos-policy-guid>
IOS_POLICY_ID          = <your-ios-policy-guid>
MACOS_PIN_TO_MAJOR_VERSION = 26
IOS_PIN_TO_MAJOR_VERSION   = 18
```

That is 7 variables to manage both platforms with no stored credentials.

---

## Part 3: Create Runbooks

Create two runbooks in **Automation Account → Runbooks**.

### Runbook 1: Update-IntuneCompliance-Unified

| Field | Value |
|---|---|
| Name | `Update-IntuneCompliance-Unified` |
| Type | PowerShell |
| Runtime | 7.2 |
| Description | Updates Intune macOS and iOS compliance policies from SOFA feeds |

Content: paste `Scripts/Update-IntuneCompliance-Unified.ps1` → **Save** → **Publish**

### Runbook 2: Diagnostics-Unified

| Field | Value |
|---|---|
| Name | `Diagnostics-Unified` |
| Type | PowerShell |
| Runtime | 7.2 |
| Description | Pre-flight diagnostics for unified compliance runbook |

Content: paste `Scripts/Diagnostics-Unified.ps1` → **Save** → **Publish**

---

## Part 4: Test

### Run Diagnostics

1. Open `Diagnostics-Unified` → **Start**
2. Expected output (both platforms enabled):

```
=========================================
Unified Compliance Runbook Diagnostics
=========================================

[STEP 1] Loading Azure Automation Variables...
  USE_MANAGED_IDENTITY: True
  ENABLE_MACOS:         True
  ENABLE_IOS:           True

  Authentication: Managed Identity
  MACOS_POLICY_ID: xxxxxxxx...
  IOS_POLICY_ID:   yyyyyyyy...
  RESULT: Variables loaded successfully

[STEP 2] Testing Microsoft Graph Authentication...
  Method: Managed Identity
  RESULT: Authentication successful

[STEP 3] Testing Microsoft Graph API Permissions...
  Total policies: 5
  macOS policies: 2
  iOS policies:   1
  RESULT: API access successful

[STEP 4] Testing Access to Target Policies...
  macOS Policy...
    Is macOS: True
    RESULT: OK

  iOS/iPadOS Policy...
    Is iOS/iPadOS: True
    RESULT: OK

  RESULT: All target policies accessible

[STEP 5] Testing SOFA Feed Access...
  macOS Feed...
    RESULT: OK

  iOS/iPadOS Feed...
    RESULT: OK

=========================================
DIAGNOSTICS COMPLETE
=========================================
```

### Run Main Script

1. Open `Update-IntuneCompliance-Unified` → **Start** → **OK**
2. Expected JSON output:

```json
{
  "Success": true,
  "AuthMethod": "Managed Identity",
  "Duration": 6.8,
  "Timestamp": "2026-04-14T...",
  "Results": {
    "macOS": {
      "Success": true,
      "Platform": "macOS",
      "PolicyId": "xxxxxxxx-...",
      "PolicyName": "macOS Compliance OS Version",
      "PreviousVersion": "26.3.0",
      "NewVersion": "26.4.0",
      "Updated": true
    },
    "iOS": {
      "Success": true,
      "Platform": "iOS/iPadOS",
      "PolicyId": "yyyyyyyy-...",
      "PolicyName": "iOS Compliance OS Version",
      "PreviousVersion": "18.3.0",
      "NewVersion": "18.3.2",
      "Updated": true
    }
  }
}
```

---

## Part 5: Schedule

A single schedule drives both platforms.

1. Automation Account → **Schedules** → **+ Add a schedule**
2. Example: `Weekly-Tuesday-2AM`
   - Recurrence: Weekly, Tuesday, 02:00
3. Open `Update-IntuneCompliance-Unified` → **Schedules** → **+ Add a schedule** → select your schedule

---

## Platform Management

### Enable/disable a platform

Change the variable value — takes effect on the next scheduled run:

- `ENABLE_MACOS = False` → macOS updates are skipped, iOS continues
- `ENABLE_IOS = False` → iOS updates are skipped, macOS continues
- Both `True` → both platforms updated each run

No runbook changes or re-publishing needed.

### Change version pinning

Update `MACOS_PIN_TO_MAJOR_VERSION` or `IOS_PIN_TO_MAJOR_VERSION` in Variables.
The change takes effect on the next run automatically.

---

## Variable Reference

Complete list:

| Variable | Platform | Purpose | Required |
|---|---|---|---|
| `USE_MANAGED_IDENTITY` | Shared | Auth method | Yes |
| `INTUNE_TENANT_ID` | Shared | Tenant ID (SP mode) | SP only |
| `INTUNE_CLIENT_ID` | Shared | Client ID (SP mode) | SP only |
| `INTUNE_CLIENT_SECRET` | Shared | Client secret (SP mode, encrypted) | SP only |
| `ENABLE_MACOS` | macOS | Enable macOS updates | Yes |
| `ENABLE_IOS` | iOS | Enable iOS updates | Yes |
| `MACOS_POLICY_ID` | macOS | macOS policy GUID | If macOS enabled |
| `MACOS_PIN_TO_MAJOR_VERSION` | macOS | Pin to macOS major version | Optional |
| `MACOS_VERSIONS_BELOW` | macOS | Versions behind latest | Optional (default: 2) |
| `MACOS_USE_MINOR_VERSIONS` | macOS | Track minor versions | Optional (default: false) |
| `IOS_POLICY_ID` | iOS | iOS/iPadOS policy GUID | If iOS enabled |
| `IOS_PIN_TO_MAJOR_VERSION` | iOS | Pin to iOS major version | Optional |
| `IOS_VERSIONS_BELOW` | iOS | Versions behind latest | Optional (default: 2) |
| `IOS_USE_MINOR_VERSIONS` | iOS | Track minor versions | Optional (default: false) |

---

## Troubleshooting

### "No platforms enabled"

Set `ENABLE_MACOS = True` and/or `ENABLE_IOS = True`.

### iOS update succeeds but macOS fails (or vice versa)

Each platform is processed independently. The script captures errors per-platform and continues. Check the `Results` section of the JSON output for the specific platform's error. The `Success` field at the top level is `false` if either platform fails.

### Policy type mismatch

Step 4 of Diagnostics validates that each policy ID points to the correct platform type. Verify `MACOS_POLICY_ID` points to a `#microsoft.graph.macOSCompliancePolicy` and `IOS_POLICY_ID` points to a `#microsoft.graph.iosCompliancePolicy`.

### SOFA API fails for one platform

SOFA maintains separate feeds for macOS and iOS. If one feed is temporarily unavailable, only that platform's update will fail. The other platform's update proceeds normally.

---

## Ongoing Maintenance

**Managed Identity:** Zero maintenance — no credentials to rotate.

**Service Principal:** Rotate `INTUNE_CLIENT_SECRET` before expiry. Both platforms benefit from a single rotation.

**Adding more policies:** The current unified script processes one policy per platform. To support multiple policies per platform, adapt the script to loop over a comma-separated list in `MACOS_POLICY_ID` / `IOS_POLICY_ID`, or run multiple instances of the runbook with parameter overrides.

---

## Comparison: When to choose Separate vs Unified Runbooks

| | Separate Runbooks | Unified Runbook |
|---|---|---|
| Independent schedules | Yes | No (single schedule for both) |
| Independent failure handling | Yes | Partial (errors captured per-platform) |
| Variable count | Higher | Lower |
| Runbook count | 4 (2 main + 2 diag) | 2 (1 main + 1 diag) |
| Enable/disable a platform | Delete or disable runbook | Set ENABLE_MACOS/IOS variable |
| Best for | Teams managing platforms separately | Simpler management, single execution |
