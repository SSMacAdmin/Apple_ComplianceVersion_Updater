# Migrating to Managed Identity

Step-by-step guide to migrate from Service Principal (client secret) authentication to Managed Identity — for both deployment options and both platforms.

---

## Why Migrate?

**Service Principal — current setup:**
- Client secrets expire (max 24 months) — requires periodic rotation
- Secret stored in Automation variables
- Calendar reminders needed for expiration
- Risk of forgotten expiration = broken automation

**Managed Identity — after migration:**
- No secrets stored anywhere
- Nothing expires — zero rotation required
- Azure best practice
- One credential setup covers both macOS and iOS/iPadOS

---

## Migration Steps

### Step 1: Enable Managed Identity on Automation Account

1. Go to **Azure Portal** → your Automation Account
2. Click **Identity** (under Account Settings)
3. Switch to **System assigned** tab
4. Toggle **Status** to **On** → **Save** → **Yes**
5. Copy the **Object (principal) ID** — needed in Step 2

### Step 2: Grant Microsoft Graph Permission

Open **Azure Cloud Shell** (PowerShell) and run:

```powershell
# Connect to Microsoft Graph
Connect-MgGraph -Scopes "Application.Read.All","AppRoleAssignment.ReadWrite.All"

# Replace with your managed identity Object ID from Step 1
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

This single permission covers both macOS and iOS/iPadOS compliance policies. No additional steps are needed per platform.

### Step 3: Verify the Permission

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

### Step 4: Update Automation Variables

1. Go to **Automation Account** → **Variables**
2. Create or update the `USE_MANAGED_IDENTITY` variable:
   - Type: Boolean
   - Value: `True`
   - Encrypted: No

You can leave the existing `INTUNE_TENANT_ID`, `INTUNE_CLIENT_ID`, and `INTUNE_CLIENT_SECRET` variables in place as a fallback. They will be ignored while `USE_MANAGED_IDENTITY` is `True`.

### Step 5: Test the Migration

**Run diagnostics first** to confirm authentication works before the next scheduled run.

**Separate Runbooks:**
```
Run: Diagnostics-macOS
Run: Diagnostics-iOS
```

**Unified Runbook:**
```
Run: Diagnostics-Unified
```

Step 2 should show:
```
[STEP 2] Testing Microsoft Graph Authentication...
  Method: Managed Identity
  Token length: ... chars
  RESULT: Authentication successful
```

Then run the main runbook manually and confirm the expected output.

---

## Rollback

If something goes wrong, revert instantly:

1. Go to **Automation Account** → **Variables**
2. Set `USE_MANAGED_IDENTITY` to `False` (or delete the variable)

The script falls back to Service Principal immediately on the next run. Your credential variables are unchanged.

---

## Cleanup (After Successful Migration)

Once the managed identity setup has been running reliably for at least one scheduled cycle:

**Remove old credential variables** (no longer needed):
- `INTUNE_TENANT_ID`
- `INTUNE_CLIENT_ID`
- `INTUNE_CLIENT_SECRET`

**Keep these variables** (still required):
- `USE_MANAGED_IDENTITY` — must remain `True`
- `MACOS_POLICY_ID` — required for macOS runbook
- `IOS_POLICY_ID` — required for iOS runbook (if used)
- `MACOS_PIN_TO_MAJOR_VERSION`, `MACOS_VERSIONS_BELOW`, etc. — optional, keep as configured
- `IOS_PIN_TO_MAJOR_VERSION`, `IOS_VERSIONS_BELOW`, etc. — optional, keep as configured
- `ENABLE_MACOS`, `ENABLE_IOS` — required for Unified Runbook

**Optionally delete the App Registration:**
1. Go to **Azure Active Directory** → **App registrations**
2. Find `Intune-Compliance-Automation` (or whatever you named it)
3. Delete it

---

## Troubleshooting

### "Failed to authenticate" — Managed Identity

1. Verify **Identity → System assigned** is **On** in the Automation Account
2. Re-run the permission grant command from Step 2
3. Wait 5–10 minutes for Azure to propagate the permission
4. Retry the diagnostics runbook

### "The identity of the calling application could not be established"

Managed Identity is set to `True` in variables but not enabled on the Automation Account.

1. Go to Automation Account → **Identity**
2. Enable **System assigned** identity
3. Re-run Step 2 to grant the permission

### Script still using Service Principal after migration

`USE_MANAGED_IDENTITY` is not set or is not `True`.

1. Check the variable exists and is type Boolean set to `True` (not the string `"True"`)
2. Variable name is case-sensitive: must be exactly `USE_MANAGED_IDENTITY`

### Runbook completes with no output

The script ran in standalone mode instead of Azure Automation mode. This usually means the detection probe variable was not found.

- **Separate Runbooks (macOS):** ensure `MACOS_POLICY_ID` exists in Automation Variables
- **Separate Runbooks (iOS):** ensure `IOS_POLICY_ID` exists in Automation Variables
- **Unified Runbook:** ensure `ENABLE_MACOS` exists in Automation Variables
- Check for typos or extra spaces in variable names (names are case-sensitive)

---