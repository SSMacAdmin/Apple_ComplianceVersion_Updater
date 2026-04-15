# macOS & iOS/iPadOS Compliance Updater

Automatically updates the `osMinimumVersion` in macOS and iOS/iPadOS version compliance policies in Microsoft Intune based on the latest releases from the SOFA feed.

## Features

- **Zero maintenance** with Azure Managed Identity — no secrets to rotate, ever
- **Multi-platform** — manages macOS and iOS/iPadOS policies from a single solution
- **Accurate version data** from [SOFA](https://sofa.macadmins.io) (MacAdmins community feed)
- **Flexible versioning** — pin to major version, track minor releases, N-versions-behind
- **Azure Automation ready** — serverless, fully scheduled
- **Per-platform control** — enable, disable, or configure each platform independently
- **Comprehensive diagnostics** — 5-step pre-flight check for each platform

---

## Deployment Options

Choose the approach that fits your team:

### Separate Runbooks

Two independent runbooks — one for macOS, one for iOS/iPadOS.

- Each platform has its own runbook, diagnostics, schedule, and variables
- A failure in one platform does not affect the other
- Best for teams that manage platforms independently or need separate schedules

See [`Separate-runbooks/SETUP-GUIDE.md`](Separate-runbooks/SETUP-GUIDE.md)

### Unified Runbook

A single runbook that handles both platforms in one execution.

- One job, one schedule, one set of shared credentials
- Platforms are independently enabled/disabled via `ENABLE_MACOS` and `ENABLE_IOS` variables
- Fewer runbooks and variables to manage
- Best for teams that want a single automated job covering all platforms

See [`Unified-runbook/SETUP-GUIDE.md`](Unified-runbook/SETUP-GUIDE.md)

---

## How It Works

Each enabled platform follows the same steps per execution:

1. Fetches the latest versions from the **SOFA** feed
   - macOS: `https://sofa.macadmins.io/v2/macos_data_feed.json`
   - iOS/iPadOS: `https://sofa.macadmins.io/v2/ios_data_feed.json`
2. Calculates the target minimum version based on your strategy
3. Authenticates to Microsoft Graph (one token covers both platforms)
4. Reads the current Intune compliance policy
5. Updates the policy only if the version has changed

---

## Version Strategies

All strategies apply per-platform independently.

**Track Major Versions** (conservative)
Stay N major versions behind the latest.
```
MACOS_VERSIONS_BELOW = 2
# Latest: macOS 26 → requires macOS 24
```

**Pin to Major Version**
Lock to a specific major version and track minor releases within it.
```
MACOS_PIN_TO_MAJOR_VERSION = 26
MACOS_VERSIONS_BELOW       = 2
# Latest 26.x is 26.7 → requires 26.5, ignores macOS 27.x
```

**Track Minor Versions** (granular)
Stay N minor versions behind within all major versions.
```
MACOS_USE_MINOR_VERSIONS = True
MACOS_VERSIONS_BELOW     = 2
# Latest 26.7 → requires 26.5
```

The same settings are available for iOS/iPadOS using the `IOS_` prefix.

---

## Authentication

Both runbook options use the same authentication methods. One credential setup covers all platforms.

### Managed Identity (Recommended)

- No secrets stored anywhere
- Nothing expires, zero rotation required
- Azure best practice

### Service Principal

- Works standalone (local, CI/CD) as well as in Azure Automation
- Client secret must be rotated before expiry (max 24 months)

See [`AZURE-AUTOMATION-SETUP.md`](AZURE-AUTOMATION-SETUP.md) for setup instructions for both methods.

---

## Variable Reference

### Shared (both options)

| Variable | Purpose |
|---|---|
| `USE_MANAGED_IDENTITY` | `True` for Managed Identity, `False` for Service Principal |
| `INTUNE_TENANT_ID` | Tenant ID (Service Principal only) |
| `INTUNE_CLIENT_ID` | Client ID (Service Principal only) |
| `INTUNE_CLIENT_SECRET` | Client secret (Service Principal only, encrypted) |

### Separate Runbooks

| Variable | Platform | Purpose |
|---|---|---|
| `MACOS_POLICY_ID` | macOS | Compliance policy GUID |
| `MACOS_PIN_TO_MAJOR_VERSION` | macOS | Pin to major version (e.g. `26`) |
| `MACOS_VERSIONS_BELOW` | macOS | Versions behind latest (default: `2`) |
| `MACOS_USE_MINOR_VERSIONS` | macOS | Track minor versions (default: `False`) |
| `IOS_POLICY_ID` | iOS | Compliance policy GUID |
| `IOS_PIN_TO_MAJOR_VERSION` | iOS | Pin to major version (e.g. `18`) |
| `IOS_VERSIONS_BELOW` | iOS | Versions behind latest (default: `2`) |
| `IOS_USE_MINOR_VERSIONS` | iOS | Track minor versions (default: `False`) |

### Unified Runbook

All of the above, plus:

| Variable | Purpose |
|---|---|
| `ENABLE_MACOS` | Enable macOS policy updates (`True`/`False`) |
| `ENABLE_IOS` | Enable iOS/iPadOS policy updates (`True`/`False`) |

---

## Required Graph API Permission

`DeviceManagementConfiguration.ReadWrite.All`

This single permission covers both macOS and iOS/iPadOS compliance policies.

---

## What's Included

```
Scripts/                              Original macOS-only script (v3.0)
│
Separate-runbooks/
│   SETUP-GUIDE.md                    Setup guide for Separate Runbooks
│   Scripts/
│       Update-IntuneMacOSCompliance.ps1
│       Update-IntuneIOSCompliance.ps1
│       Diagnostics-macOS.ps1
│       Diagnostics-iOS.ps1
│
Unified-runbook/
│   SETUP-GUIDE.md                    Setup guide for Unified Runbook
│   Scripts/
│       Update-IntuneCompliance-Unified.ps1
│       Diagnostics-Unified.ps1
│
AZURE-AUTOMATION-SETUP.md            Authentication setup guide
STANDALONE-USAGE.md                  Local execution guide
MANAGED-IDENTITY-MIGRATION.md        Migrate from service principal to managed identity
```

---

## Cost

Azure Automation Free tier includes 500 job minutes/month.

Each runbook execution takes ~4–8 seconds. Running weekly costs approximately **25–50 seconds/month** — well within the free tier regardless of which option you choose.

---

## Changelog

**v4.0** (April 2026)
- Added iOS/iPadOS compliance policy support
- Separate Runbooks option — independent macOS and iOS runbooks
- Unified Runbook option — single runbook for both platforms
- Per-platform variable naming (`MACOS_*`, `IOS_*`)
- Platform enable/disable via `ENABLE_MACOS` / `ENABLE_IOS` variables
- Platform-specific diagnostics

**v3.0** (April 2026)
- Added Managed Identity support (zero maintenance)
- Switched to SOFA feed (MacAdmins community standard)
- Fixed Azure Automation memory constraints
- Added `AuthMethod` to execution output

**v2.0**
- All-in-one script (standalone + Azure Automation)
- Pin to major version support
- Comprehensive diagnostics
- Improved error handling

---

## Resources

- [SOFA MacAdmins Feed](https://sofa.macadmins.io)
- [Azure Automation Documentation](https://docs.microsoft.com/azure/automation/)
- [Microsoft Graph API Reference](https://docs.microsoft.com/graph/)
- [Intune Compliance Policies](https://docs.microsoft.com/mem/intune/)
- [Managed Identity Documentation](https://docs.microsoft.com/azure/active-directory/managed-identities-azure-resources/)

---
