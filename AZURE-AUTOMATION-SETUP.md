# Azure Automation Setup Guide

Complete step-by-step guide to set up automated macOS and iOS/iPadOS compliance policy management in Azure Automation.

---

## Overview

This guide covers the shared setup that applies to **both deployment options**:

- Creating the Azure Automation Account
- Choosing and configuring authentication (Managed Identity or Service Principal)
- Configuring variables and uploading runbooks
- Testing and scheduling

**Two deployment options are available — choose one:**

| | Separate Runbooks | Unified Runbook |
|---|---|---|
| Runbooks | One per platform | One for both platforms |
| Schedules | Independent per platform | Single shared schedule |
| Variables | `MACOS_*` and `IOS_*` sets | Same, plus `ENABLE_MACOS` / `ENABLE_IOS` |
| Best for | Independent platform management | Simpler, single-job setup |
| Setup guide | [`Separate-runbooks/SETUP-GUIDE.md`](Separate-runbooks/SETUP-GUIDE.md) | [`Unified-runbook/SETUP-GUIDE.md`](Unified-runbook/SETUP-GUIDE.md) |

**Time required:** 15–20 minutes

---

## Choose Your Authentication Method

The same authentication method is used for both platforms. One setup covers everything.

### Option A: Managed Identity — Recommended

- No credentials stored anywhere
- Nothing expires — zero rotation required
- Azure best practice

### Option B: Service Principal

- Works standalone (local machine, CI/CD) in addition to Azure Automation
- Client secret expires (max 24 months) — requires periodic rotation

**Recommendation:** Use Managed Identity for production. Both are fully supported and you can migrate later (see [`MANAGED-IDENTITY-MIGRATION.md`](MANAGED-IDENTITY-MIGRATION.md)).

---

## Part 1: Create Azure Automation Account

1. Go to [Azure Portal](https://portal.azure.com)
2. Search for **Automation Accounts** → **+ Create**
3. Configure:
   - **Subscription**: Your subscription
   - **Resource group**: New or existing (e.g. `rg-automation`)
   - **Name**: `intune-compliance-automation`
   - **Region**: Closest to you
4. Click **Review + Create** → **Create**
5. Wait ~1 minute for deployment

---

## Part 2A: Set Up Managed Identity (Recommended)

### Step 2A.1: Enable System-Assigned Managed Identity

1. Open your Automation Account
2. Go to **Identity** → **System assigned**
3. Toggle **Status** to **On** → **Save** → **Yes**
4. Copy the **Object (principal) ID** — needed in the next step

### Step 2A.2: Grant Microsoft Graph Permission

Open **Azure Cloud Shell** (PowerShell) and run:

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.Read.All","AppRoleAssignment.ReadWrite.All"

# Replace with your managed identity Object ID from Step 2A.1
$managedIdentityId = "PASTE-YOUR-OBJECT-ID-HERE"

$graphAppId = "00000003-0000-0000-c000-000000000000"
$graphSP    = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
$permission = $graphSP.AppRoles | Where-Object {
    $_.Value -eq "DeviceManagementConfiguration.ReadWrite.All"
}

New-MgServicePrincipalAppRoleAssignment `
    -ServicePrincipalId $managedIdentityId `
    -PrincipalId        $managedIdentityId `
    -ResourceId         $graphSP.Id `
    -AppRoleId          $permission.Id

Write-Host "Permission granted"
```

This single permission covers both macOS and iOS/iPadOS compliance policies.

### Step 2A.3: Verify the Permission

```powershell
$assignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $managedIdentityId
$assignments | ForEach-Object {
    $role = (Get-MgServicePrincipal -ServicePrincipalId $_.ResourceId).AppRoles |
            Where-Object Id -eq $_.AppRoleId
    [PSCustomObject]@{
        Permission   = $role.Value
        ResourceName = (Get-MgServicePrincipal -ServicePrincipalId $_.ResourceId).DisplayName
    }
}
```

Expected output:
```
Permission                                      ResourceName
----------                                      ------------
DeviceManagementConfiguration.ReadWrite.All     Microsoft Graph
```

**Skip to Part 3.**

---

## Part 2B: Set Up Service Principal (Alternative)

### Step 2B.1: Create App Registration

1. Go to **Azure Active Directory** → **App registrations** → **New registration**
2. Configure:
   - **Name**: `Intune-Compliance-Automation`
   - **Supported account types**: This directory only
3. Click **Register**

### Step 2B.2: Grant API Permission

1. Go to **API permissions** → **Add a permission** → **Microsoft Graph** → **Application permissions**
2. Search for and add: `DeviceManagementConfiguration.ReadWrite.All`
3. Click **Grant admin consent for [Your Organization]** → **Yes**

### Step 2B.3: Create Client Secret

1. Go to **Certificates & secrets** → **Client secrets** → **New client secret**
2. Set expiry (24 months recommended)
3. Click **Add**
4. **Copy the Value immediately** — it is shown only once

### Step 2B.4: Collect Required Values

You will need:
- **Tenant ID**: Azure Active Directory → Overview → Tenant ID
- **Client ID**: App Registration → Overview → Application (client) ID
- **Client Secret**: Value copied in Step 2B.3

---

## Part 3: Get Your Compliance Policy IDs

Before creating variables, collect the policy GUIDs from Intune.

1. Go to [Intune](https://intune.microsoft.com) → **Devices** → **Compliance** → **Policies**
2. Click each policy you want to manage
3. Copy the GUID from the URL:

```
…/policyId/36b9b86c-2297-4c2c-9b25-8c023f9d4d57
           ↑ this is your Policy ID
```

You will need one GUID per platform (macOS and/or iOS/iPadOS).

---

## Part 4: Configure Automation Variables

Navigate to your **Automation Account** → **Variables** (under Shared Resources).

### Shared Variables — Required for All

These apply regardless of which deployment option you choose.

**`USE_MANAGED_IDENTITY`**
- Type: Boolean
- Value: `True` (Managed Identity) or `False` (Service Principal)
- Encrypted: No

**Service Principal only — skip if using Managed Identity:**

**`INTUNE_TENANT_ID`** — Type: String, Encrypted: No

**`INTUNE_CLIENT_ID`** — Type: String, Encrypted: No

**`INTUNE_CLIENT_SECRET`** — Type: String, **Encrypted: Yes**

---

### Separate Runbooks — Platform Variables

#### macOS Variables

**`MACOS_POLICY_ID`** — Required
- Type: String
- Value: Your macOS compliance policy GUID
- Encrypted: No

**`MACOS_PIN_TO_MAJOR_VERSION`** — Recommended
- Type: Integer
- Value: e.g. `26`
- Purpose: Pin to a specific macOS major version; ignores newer major versions

**`MACOS_VERSIONS_BELOW`** — Optional (default: `2`)
- Type: Integer
- Value: How many versions behind the latest to require

**`MACOS_USE_MINOR_VERSIONS`** — Optional (default: `False`)
- Type: Boolean
- Value: `True` to track minor versions instead of major versions

#### iOS/iPadOS Variables

**`IOS_POLICY_ID`** — Required
- Type: String
- Value: Your iOS/iPadOS compliance policy GUID
- Encrypted: No

**`IOS_PIN_TO_MAJOR_VERSION`** — Recommended
- Type: Integer
- Value: e.g. `18`

**`IOS_VERSIONS_BELOW`** — Optional (default: `2`)
- Type: Integer

**`IOS_USE_MINOR_VERSIONS`** — Optional (default: `False`)
- Type: Boolean

---

### Unified Runbook — All Variables

All variables from Separate Runbooks above, plus:

**`ENABLE_MACOS`** — Required
- Type: Boolean
- Value: `True` to process macOS, `False` to skip

**`ENABLE_IOS`** — Required
- Type: Boolean
- Value: `True` to process iOS/iPadOS, `False` to skip

**Minimum variable set (Managed Identity, both platforms):**
```
USE_MANAGED_IDENTITY         = True
ENABLE_MACOS                 = True
ENABLE_IOS                   = True
MACOS_POLICY_ID              = <your-macos-policy-guid>
IOS_POLICY_ID                = <your-ios-policy-guid>
MACOS_PIN_TO_MAJOR_VERSION   = 26
IOS_PIN_TO_MAJOR_VERSION     = 18
```

---

## Part 5: Upload the Runbooks

Navigate to your **Automation Account** → **Runbooks** → **+ Create a runbook**.

Use **PowerShell** type and **Runtime version 7.2** for all runbooks.

### Separate Runbooks

| Runbook Name | Script File | Description |
|---|---|---|
| `Update-macOS-Compliance` | `Separate-runbooks/Scripts/Update-IntuneMacOSCompliance.ps1` | Updates macOS compliance policy |
| `Update-iOS-Compliance` | `Separate-runbooks/Scripts/Update-IntuneIOSCompliance.ps1` | Updates iOS/iPadOS compliance policy |
| `Diagnostics-macOS` | `Separate-runbooks/Scripts/Diagnostics-macOS.ps1` | Pre-flight checks for macOS |
| `Diagnostics-iOS` | `Separate-runbooks/Scripts/Diagnostics-iOS.ps1` | Pre-flight checks for iOS |

### Unified Runbook

| Runbook Name | Script File | Description |
|---|---|---|
| `Update-IntuneCompliance-Unified` | `Unified-runbook/Scripts/Update-IntuneCompliance-Unified.ps1` | Updates both platforms |
| `Diagnostics-Unified` | `Unified-runbook/Scripts/Diagnostics-Unified.ps1` | Pre-flight checks for both platforms |

For each runbook: paste the script content → **Save** → **Publish**.

---

## Part 6: Test the Setup

### Run Diagnostics First

Always run diagnostics before the main script to verify each component.

**Separate Runbooks:** Run `Diagnostics-macOS` and/or `Diagnostics-iOS`.

**Unified Runbook:** Run `Diagnostics-Unified`.

All 5 steps should pass. Example output (Unified, Managed Identity):

```
[STEP 1] Loading Azure Automation Variables...
  USE_MANAGED_IDENTITY: True
  ENABLE_MACOS:         True
  ENABLE_IOS:           True
  Authentication: Managed Identity
  MACOS_POLICY_ID: 2ede6410...
  IOS_POLICY_ID:   c595dd05...
  RESULT: Variables loaded successfully

[STEP 2] Testing Microsoft Graph Authentication...
  Method: Managed Identity
  RESULT: Authentication successful

[STEP 3] Testing Microsoft Graph API Permissions...
  macOS policies: 3
  iOS policies:   2
  RESULT: API access successful

[STEP 4] Testing Access to Target Policies...
  macOS Policy... Is macOS: True   RESULT: OK
  iOS/iPadOS Policy... Is iOS/iPadOS: True   RESULT: OK

[STEP 5] Testing SOFA Feed Access...
  macOS Feed... RESULT: OK
  iOS/iPadOS Feed... RESULT: OK
```

### Run the Main Script

Once diagnostics pass, run the main runbook. Expected JSON summary output:

```json
{
  "Success": true,
  "AuthMethod": "Managed Identity",
  "Results": {
    "macOS": {
      "Success": true,
      "PreviousVersion": "26.3.0",
      "NewVersion": "26.4.0",
      "Updated": true
    },
    "iOS": {
      "Success": true,
      "PreviousVersion": "18.3.0",
      "NewVersion": "18.3.2",
      "Updated": true
    }
  }
}
```

---

## Part 7: Schedule Automated Execution

### Create a Schedule

1. Automation Account → **Schedules** → **+ Add a schedule**
2. Example: `Weekly-Tuesday-2AM`
   - Recurrence: Weekly, Tuesday, 02:00
   - Time zone: your local zone
3. **Create**

### Link to Runbooks

- **Separate Runbooks:** Link the schedule to both `Update-macOS-Compliance` and `Update-iOS-Compliance` (or just the ones you are using)
- **Unified Runbook:** Link to `Update-IntuneCompliance-Unified` once

Open each runbook → **Schedules** → **+ Add a schedule** → select your schedule → **OK**.

---

## Part 8: Monitoring (Optional)

### Failure Alerts

1. Automation Account → **Alerts** → **+ New alert rule**
2. Condition: **Job failed**
3. Action group: email or Teams webhook notification
4. Name: `Compliance Update Failed`

### View Job History

Automation Account → **Jobs** — all runs with status, duration, and full output logs.

### Log Analytics Query

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.AUTOMATION"
| where Category == "JobLogs"
| where RunbookName_s in ("Update-macOS-Compliance", "Update-iOS-Compliance", "Update-IntuneCompliance-Unified")
| project TimeGenerated, ResultType, RunbookName_s
| order by TimeGenerated desc
| take 20
```

---

## Troubleshooting

### "Failed to load variables"

- Check variable names are spelled correctly (case-sensitive)
- **Separate Runbooks:** `MACOS_POLICY_ID` and `IOS_POLICY_ID` must exist separately
- **Unified Runbook:** `ENABLE_MACOS`, `ENABLE_IOS` must also exist
- Service Principal mode requires `INTUNE_TENANT_ID`, `INTUNE_CLIENT_ID`, `INTUNE_CLIENT_SECRET`

### "Authentication failed" — Managed Identity

1. Verify **Identity → System assigned** is **On**
2. Re-run the permission grant command from Part 2A.2
3. Wait 5–10 minutes for Azure to propagate permissions
4. Retry

### "Authentication failed" — Service Principal

1. Check the client secret has not expired (App Registration → Certificates & secrets)
2. Verify `INTUNE_TENANT_ID` and `INTUNE_CLIENT_ID` are correct
3. Verify admin consent was granted (green checkmark in API permissions)
4. Wait 5 minutes after granting consent

### "403 Forbidden" on API call

- The identity does not have `DeviceManagementConfiguration.ReadWrite.All`
- **Managed Identity:** re-run the grant command from Part 2A.2
- **Service Principal:** click Grant admin consent in API permissions
- Wait 5–10 minutes

### "404 Not Found" on policy access

- The policy GUID in `MACOS_POLICY_ID` or `IOS_POLICY_ID` is incorrect
- Go to Intune → Devices → Compliance → Policies → click the policy → copy GUID from URL

### Policy type mismatch warning

The diagnostics script checks that each policy ID points to the correct platform type.
- `MACOS_POLICY_ID` must point to a `#microsoft.graph.macOSCompliancePolicy`
- `IOS_POLICY_ID` must point to a `#microsoft.graph.iosCompliancePolicy`

### Runbook completes with no output

This usually means Azure Automation was not detected and the script ran in standalone mode, failing silently. Verify:
- The probe variable exists (`MACOS_POLICY_ID` for the macOS runbook, `IOS_POLICY_ID` for iOS, `ENABLE_MACOS` for Unified)
- Variable names have no typos or extra spaces

### "SOFA API failed"

SOFA is maintained by the MacAdmins community and updated every 6 hours. Transient outages are possible. The scheduled runbook retries automatically on its next execution. Verify: `https://sofa.macadmins.io`

---

## Ongoing Maintenance

### Managed Identity: Zero Maintenance

Nothing to rotate. Monitor job history periodically.

### Service Principal: Secret Rotation

When the client secret nears expiry:
1. App Registration → **Certificates & secrets** → create new secret
2. Copy the new value
3. Update `INTUNE_CLIENT_SECRET` in Automation Variables
4. Test a runbook manually
5. Once confirmed working, delete the old secret

One rotation covers all platforms — both runbooks share the same credential variables.

### Change Version Strategy

Update the relevant variable (e.g. `MACOS_PIN_TO_MAJOR_VERSION`) in Automation Variables. No runbook re-publishing required — takes effect on the next execution.

### Enable or Disable a Platform

- **Separate Runbooks:** Disable or delete the individual runbook's schedule
- **Unified Runbook:** Set `ENABLE_MACOS` or `ENABLE_IOS` to `False` — takes effect immediately on the next run

---

## Additional Resources

**Setup Guides:**
- [`Separate-runbooks/SETUP-GUIDE.md`](Separate-runbooks/SETUP-GUIDE.md) — Separate Runbooks
- [`Unified-runbook/SETUP-GUIDE.md`](Unified-runbook/SETUP-GUIDE.md) — Unified Runbook
- [`STANDALONE-USAGE.md`](STANDALONE-USAGE.md) — Local/standalone execution
- [`MANAGED-IDENTITY-MIGRATION.md`](MANAGED-IDENTITY-MIGRATION.md) — Migrate from service principal

**Microsoft Documentation:**
- [Azure Automation](https://docs.microsoft.com/azure/automation/)
- [Managed Identities](https://docs.microsoft.com/azure/active-directory/managed-identities-azure-resources/)
- [Microsoft Graph API](https://docs.microsoft.com/graph/)
- [Intune Compliance Policies](https://docs.microsoft.com/mem/intune/protect/device-compliance-get-started)

**Community:**
- [SOFA Feed](https://sofa.macadmins.io)
