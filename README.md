# Purview-as-Code

[![CI](https://github.com/SamKloosK/purview-as-code/actions/workflows/ci.yml/badge.svg)](https://github.com/SamKloosK/purview-as-code/actions/workflows/ci.yml)

A PowerShell module that deploys a Microsoft Purview configuration from a JSON file: sensitivity labels, label groups, label policies, DLP policies and rules, retention labels and retention policies.

It reads the tenant first and shows you a plan: what it will create, what it will change (old value, new value), what already matches, and what's in the tenant but not in your config. Only then does it apply anything, and only the differences. Security & Compliance PowerShell ignores `-WhatIf`; here `-WhatIf` gives you the plan and stops.

```
PS> Invoke-PurviewDeployment -ConfigFile .\configs\contoso.json -WhatIf

Tenant verified: contoso.onmicrosoft.com (11111111-2222-3333-4444-555555555555)
Contoso: plan only (WhatIf)

Sensitivity labels
  = Sensitivity label      Public
  = Sensitivity label      Internal
  ! Sensitivity label      Internal
      Footer is on in the tenant but not in the config (left as is)
  = Label group            HighlyConfidential
  ~ Sensitivity label      HighlyConfidential-AllEmployees
      EncryptionOfflineAccessDays: '7' -> '3'

DLP policies
  ~ DLP policy             DLP-FinancialData
      mode: 'TestWithNotifications' -> 'Enable'
  = DLP rule               DLP-FinancialData-HighVolume

Retention labels
  = Retention label        Retain-7Years
  + Retention label        Retain-3Years
      Delete after 1095 days

1 to create, 2 to update, 14 unchanged, 1 drift, 0 failed
WhatIf: nothing was changed.
```

Run it twice without changing the config and the second run changes nothing.

The background is in the blog post [Purview as code: why -WhatIf deployed everything anyway](https://www.argusit.nl/en/blog/purview-as-code-whatif). Smaller single-purpose scripts live in [purview-scripts](https://github.com/SamKloosK/purview-scripts).

## Why not Microsoft365DSC?

If you want your whole Microsoft 365 tenant as code, use [Microsoft365DSC](https://microsoft365dsc.com). It covers far more workloads and has export and drift reports built in.

This is for a narrower job: the Purview baseline you roll out at a client, kept in a JSON file you can read in one sitting and review in a pull request. No DSC, no LCM, one module with one dependency. It never deletes anything, and it shows you a plan before it changes anything.

## Quick start

```powershell
Install-Module ExchangeOnlineManagement
git clone https://github.com/SamKloosK/purview-as-code
cd purview-as-code
Import-Module ./PurviewAsCode

New-Item -ItemType Directory ./configs -Force | Out-Null   # configs/ is in .gitignore
Copy-Item ./examples/baseline.json ./configs/contoso.json
Test-PurviewConfig -ConfigFile ./configs/contoso.json

Invoke-PurviewDeployment -ConfigFile ./configs/contoso.json -WhatIf
Invoke-PurviewDeployment -ConfigFile ./configs/contoso.json
```

`Invoke-PurviewDeployment` connects with `Connect-IPPSSession` (add `-UserPrincipalName` to pick the account), or uses the session you already have with `-UseExistingSession`.

Change these in the examples before you deploy: `TenantDomain`, the identities in `EncryptionRightsDefinitions` (`identity:RIGHTS`, where the identity is a user, group or domain) and the SharePoint URLs in `RetentionLabelPolicies`. `defaultlabelid` in a label policy can be a label name; it's turned into the GUID at deploy time.

## Safety

- **Tenant check.** Before anything changes, the session's tenant ID is compared with the `TenantDomain` in the config (looked up through the public OpenID Connect discovery document, or taken from `TenantId` if you set it). A config for one client doesn't land in another client's tenant because you were still signed in there.
- **Validation first.** The deploy runs `Test-PurviewConfig` and stops on errors: duplicate label names, a label group in a label policy, a sublabel published without its parent (classic scheme), placeholders left in from the examples.
- **Nothing is deleted.** Labels, policies and rules that aren't in the config stay in the tenant and show up as drift. Labels published in a label policy but not in the config, and locations that aren't in the config, are also reported and left alone, unless you add `-AllowRemoval`.
- **Failures don't hide.** A failed change doesn't stop the run, but the run ends with an error listing what failed, so a pipeline sees it.

## What it covers

| Area | Create | Compared and updated |
| --- | --- | --- |
| Sensitivity labels and sublabels | Yes | Display name, tooltip, comment, scope, encryption, header, footer, watermark |
| Label groups (modern label scheme) | Yes | Display name, tooltip, comment |
| Container labels (sites and groups) | Yes | Privacy, guest access, external sharing, unmanaged devices |
| Label policies | Yes | Labels, Exchange locations, advanced settings |
| DLP policies and rules | Yes | Locations, mode, comment; rule sensitive info types, BlockAccess, notifications, severity |
| Retention labels | Yes | Duration and comment. Action, type and record status can't change on an existing label, so differences are reported |
| Retention label policies | Yes | Locations and published labels |
| Retention policies and rules | Yes | Locations; rule duration, action and expiration option |

Two helper scripts cover what Security & Compliance PowerShell can't do on its own:

- `scripts/Set-SharePointAppEnforcedRestrictions.ps1` creates the Conditional Access policy without which the "unmanaged devices" setting of a container label does nothing.
- `scripts/Set-SiteLabelDefaults.ps1` turns on sensitivity labels for groups and sites in Entra ID and later sets default retention labels per document library.

## Config

`schema/purview-config.schema.json` describes every setting. The examples reference it, so VS Code completes keys and flags wrong values while you type.

- `examples/baseline.json`: modern label scheme with label groups, credit card DLP, seven-year mail retention.
- `examples/nl-smb.json`: classic label scheme, BSN DLP, a container label and Dutch fiscal retention labels.

### Classic or modern label scheme

Tenants created from 1 October 2025 use the modern scheme, where sublabels sit in a label group instead of under a parent label. The Purview portal shows a green bar under Information Protection > Sensitivity labels when you're on it.

- Modern: set `"IsLabelGroup": true` on the top-level label and publish only the labels inside the group.
- Classic: leave `IsLabelGroup` out and publish the parent labels along with their sublabels.

## Running it from a pipeline

```powershell
Invoke-PurviewDeployment -ConfigFile ./configs/contoso.json `
    -AppId $env:APP_ID -CertificateThumbprint $env:CERT_THUMBPRINT `
    -PlanFile ./plan.md -WhatIf
```

App-only connections use certificate-based authentication: an app registration with the `Exchange.ManageAsApp` application permission from **Microsoft Exchange Online Protection** (not the similarly named Office 365 Exchange Online one), admin consent, and an Entra role that covers what you deploy. Compliance Administrator covers labels, DLP and retention. `TenantDomain` has to be the primary `.onmicrosoft.com` domain, because it's passed as `-Organization`. See [App-only authentication](https://learn.microsoft.com/powershell/exchange/app-only-auth-powershell-v2).

`-PlanFile` writes the plan as a Markdown table, for a change request or a pipeline summary. A sensible split: run with `-WhatIf -PlanFile` on a pull request, and apply after approval.

## Other commands

- `Get-PurviewLabelState` shows how Purview stores your labels: one line per setting from `LabelActions`, which is where encryption and marking live and what the plan compares against.
- `Export-PurviewConfig` writes an existing tenant's labels, policies and DLP to a config file as a starting point. Not exported yet: encryption rights, container settings, DLP rule conditions and retention. Run the deploy with `-WhatIf` on the result to see what still differs.

## Known gaps

- Label order (priority) isn't managed. On a new tenant the creation order wins.
- Label policies only take Exchange locations and advanced settings, not scoped policies or exceptions.
- DLP rules cover sensitive info types and the main actions, not advanced rules.
- Purview stores label settings in `LabelActions` as key/value pairs. Not every key name has been confirmed in a tenant yet; where one isn't found, the plan says "current value not readable" and sets the value again, so a wrong guess costs a write, not a wrong setting.

See [CHANGELOG.md](CHANGELOG.md) for what changed per version.

## Tests

```powershell
Invoke-Pester ./tests
```

The tests run against stand-ins for the Security & Compliance cmdlets with the same parameter sets as the real ones. They check that `-WhatIf` never writes, that a second run writes nothing, that DLP locations go through `AddXxxLocation`, and that failures and wrong tenants stop the run. They don't replace a test in a demo tenant.

## License

MIT, see [LICENSE](LICENSE). Test it in a demo tenant before you point it at production.
