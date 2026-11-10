# Changelog

## 0.2.0 (10 November 2026)

Rebuilt as a PowerShell module with a plan before every change.

- `Invoke-PurviewDeployment` reads the tenant, compares every object with the config and prints create, update (old and new value), no change and drift. Without `-WhatIf` it applies only the differences; a second run on an unchanged tenant changes nothing.
- The session's tenant is checked against `TenantDomain` (or `TenantId`) before anything changes.
- The config is validated before the deploy starts, against a JSON schema and a set of checks the schema can't do. Placeholders from the examples are errors now.
- `defaultlabelid` can be a label name.
- `-AllowRemoval` to remove labels from label policies and locations from policies. Without it these are reported as drift.
- `-PlanFile` writes the plan as Markdown. `-PassThru` returns the plan items.
- App-only connections with `-AppId` and `-CertificateThumbprint`.
- `Get-PurviewLabelState` shows the raw label settings from `LabelActions`.
- `Export-PurviewConfig` moved into the module, nests sublabels and reads markings from `LabelActions`.
- Pester tests and a GitHub Actions workflow (PSScriptAnalyzer, schema check, tests).

Fixed:

- Changing a DLP policy location failed, because `Set-DlpCompliancePolicy` only takes `AddXxxLocation` and `RemoveXxxLocation`. Location lists are now compared as sets.
- A retention policy whose rule failed to create was never repaired on later runs.
- Failures in retention and label policy steps were printed and then reported as a successful deployment.
- Display name, tooltip and comment of existing labels weren't updated.
- Switching the unmanaged devices setting of a container label left the previous setting on.
- User-defined encryption couldn't set `PromptUser`, `DoNotForward` or `EncryptOnly`.
- Retention policy locations are read with `-DistributionDetail`. Without it an existing policy with Exchange set to All showed up as a change.
- UserDefined encryption on a label that covers files and email needs `PromptUser` and either `DoNotForward` or `EncryptOnly`, or `Set-Label` rejects it. This is a validation error now, and the examples set `DoNotForward`.

Breaking: `scripts/Deploy-PurviewConfig.ps1` and `tests/Test-PurviewConfig.ps1` are replaced by `Invoke-PurviewDeployment` and `Test-PurviewConfig` in the module.

## 0.1.0 (6 November 2026)

First public version: deploy labels, label groups, label policies, DLP and retention from JSON.
