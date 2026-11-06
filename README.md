# Purview-as-Code

PowerShell modules that deploy a Microsoft Purview configuration from a JSON file. You describe the sensitivity labels, label policies, DLP policies, retention labels and retention policies you want, and the deploy script creates what's missing in the tenant.

A config file is easier to review and repeat than clicking through the Purview portal, and git shows you what changed and when.

Smaller single-purpose scripts live in [purview-scripts](https://github.com/SamKloosK/purview-scripts).

## What it covers

| Area | Create | Update existing |
| --- | --- | --- |
| Sensitivity labels and sublabels (encryption, header, footer, watermark) | Yes | Settings are re-applied from the config on every run |
| Container labels for sites and Microsoft 365 groups | Yes | Settings are re-applied |
| Label policies | Yes | Labels added and removed, advanced settings re-applied |
| DLP policies and rules | Yes | Locations, mode and rule settings |
| Retention labels | Yes | No |
| Retention label policies (publishing labels to locations) | Yes | Missing labels are published, locations are not changed |
| Retention policies | Yes | No |

Two helper scripts handle the steps around a deploy that you can't do with Security & Compliance PowerShell alone:

- `scripts/Set-SharePointAppEnforcedRestrictions.ps1` creates the Conditional Access policy that makes the "unmanaged devices" setting of a container label actually do something.
- `scripts/Set-SiteLabelDefaults.ps1` turns on sensitivity labels for groups and sites in Entra ID, starts the label sync, and later sets default retention labels per document library.

## Repository layout

```
purview-as-code/
├── modules/
│   ├── PurviewConnection.psm1     # Connect to Security & Compliance PowerShell
│   ├── PurviewLabels.psm1         # Sensitivity labels and label policies
│   ├── PurviewDLP.psm1            # DLP policies and rules
│   └── PurviewRetention.psm1      # Retention labels, label policies and retention policies
├── scripts/
│   ├── Deploy-PurviewConfig.ps1   # Apply a config to a tenant
│   ├── Export-PurviewConfig.ps1   # Export a starting point from an existing tenant
│   ├── Set-SharePointAppEnforcedRestrictions.ps1
│   └── Set-SiteLabelDefaults.ps1
├── examples/
│   ├── baseline.json              # Four-level label taxonomy, credit card DLP, 7-year mail retention
│   └── nl-smb.json                # Baseline plus BSN DLP, a container label and Dutch fiscal retention labels
└── tests/
    └── Test-PurviewConfig.ps1     # Validate a config before you deploy it
```

## Prerequisites

- PowerShell 7
- `Install-Module ExchangeOnlineManagement`
- For the helper scripts: `Microsoft.Graph.Authentication`, and `PnP.PowerShell` with your own app registration
- A Purview role that can manage labels, DLP and retention (for example Compliance Administrator)

## Usage

```powershell
# 1. Copy an example and make it yours
Copy-Item .\examples\baseline.json .\configs\mytenant.json

# 2. Validate it
.\tests\Test-PurviewConfig.ps1 -ConfigFile .\configs\mytenant.json

# 3. See what would happen
.\scripts\Deploy-PurviewConfig.ps1 -ConfigFile .\configs\mytenant.json -WhatIf

# 4. Deploy
.\scripts\Deploy-PurviewConfig.ps1 -ConfigFile .\configs\mytenant.json
```

Things to change in the examples before you deploy:

- `TenantDomain`
- `EncryptionRightsDefinitions`: the syntax is `identity:RIGHTS`, where the identity is a user, a group or a domain. A domain grants the rights to the organization that owns that domain.
- `defaultlabelid` in the baseline label policy: the GUID of the label you want as default. It exists only after the first deploy, so run once, look it up with `Get-Label`, then set it.
- SharePoint URLs in `RetentionLabelPolicies`

`configs/` is in `.gitignore`, so your own tenant files stay out of the repository.

### Optional: watermarks

The examples set headers and footers only. The labels module also supports a watermark. To add one, put a `Watermark` block in the label's `ContentMarking`:

```json
"ContentMarking": {
  "Header": { "Text": "Classification: Confidential", "FontSize": 10, "FontColor": "#FF0000", "Alignment": "Center" },
  "Watermark": { "Text": "CONFIDENTIAL", "FontSize": 48, "FontColor": "#FF0000", "Layout": "Diagonal" }
}
```

`Layout` is `Horizontal` or `Diagonal`. `FontColor` takes a `#xxxxxx` hex value.

## Things to know

- **-WhatIf is handled by these scripts, not by Microsoft.** Security & Compliance PowerShell ignores `-WhatIf`. The modules check `ShouldProcess` before every change instead, and the deploy script passes `-WhatIf` explicitly to every module function.
- **Publish parent labels too.** If a label policy contains sublabels, list the parent labels in the policy as well.
- **Changes take time.** Label policies can take up to 24 hours to reach clients, and published retention labels can take up to 7 days to show up on a site.
- **Delete is not supported.** Removing something from the config doesn't remove it from the tenant. That's on purpose.
- **The export is a starting point, not a round trip.** `Export-PurviewConfig.ps1` writes a flat label list with parent IDs and only header markings. Clean it up before you feed it to the deploy script.

## License

MIT, see [LICENSE](LICENSE). Use it, change it, and test it in a demo tenant before you point it at production.
