# Test-PurviewConfig.ps1
# Validates a config file before deployment

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile
)

$script:errors = @()
$script:warnings = @()

# Check file exists
if (-not (Test-Path $ConfigFile)) {
    Write-Error "Config file not found: $ConfigFile"
    exit 1
}

Write-Host "Validating: $ConfigFile" -ForegroundColor Cyan

try {
    $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable
}
catch {
    Write-Error "Invalid JSON: $_"
    exit 1
}

# Required fields
if (-not $config.ClientName) { $script:errors += "Missing required field: ClientName" }
if (-not $config.TenantDomain) { $script:errors += "Missing required field: TenantDomain" }
if ($config.TenantDomain -and $config.TenantDomain -notmatch '\.onmicrosoft\.com$') {
    $script:warnings += "TenantDomain '$($config.TenantDomain)' does not end with .onmicrosoft.com. Verify this is correct."
}

# Validate sensitivity labels
if ($config.SensitivityLabels) {
    $script:allLabelNames = @()
    $script:labelGroupNames = @()

    function Test-LabelConfig {
        param([array]$Labels, [string]$ParentPath)

        foreach ($label in $Labels) {
            $path = if ($ParentPath) { "$ParentPath/$($label.Name)" } else { $label.Name }

            if (-not $label.Name) { $script:errors += "Label at '$path' is missing Name" }
            if (-not $label.DisplayName) { $script:errors += "Label '$path' is missing DisplayName" }
            if ($label.Name -match '\s') { $script:warnings += "Label name '$($label.Name)' contains spaces. Consider using hyphens." }

            if ($label.Name -in $script:allLabelNames) {
                $script:errors += "Duplicate label name: $($label.Name)"
            }
            $script:allLabelNames += $label.Name

            # Label groups (modern label scheme) only take a name, display name and description
            if ($label.IsLabelGroup) {
                if ($ParentPath) { $script:errors += "Label '$path' is a label group but isn't a top-level label" }
                foreach ($setting in 'Scope', 'Encryption', 'ContentMarking', 'SiteAndGroupProtection') {
                    if ($label.$setting) { $script:errors += "Label group '$path' has $setting, which label groups don't support" }
                }
                if (-not $label.SubLabels) { $script:warnings += "Label group '$path' has no sublabels" }
                $script:labelGroupNames += $label.Name
            }

            # Check encryption config
            if ($label.Encryption) {
                if (-not $label.Encryption.ProtectionType) {
                    $script:errors += "Label '$path' has Encryption but missing ProtectionType"
                }
                if ($label.Encryption.ProtectionType -eq "Template" -and -not $label.Encryption.EncryptionRightsDefinitions) {
                    $script:errors += "Label '$path' has Template encryption but missing EncryptionRightsDefinitions"
                }
                if ($label.Encryption.EncryptionRightsDefinitions -match "REPLACE") {
                    $script:warnings += "Label '$path' still has REPLACE placeholder in EncryptionRightsDefinitions"
                }
            }

            # Recurse into sublabels
            if ($label.SubLabels) {
                Test-LabelConfig -Labels $label.SubLabels -ParentPath $path
            }
        }
    }

    Test-LabelConfig -Labels $config.SensitivityLabels
}

# Validate label policies
if ($config.LabelPolicies) {
    foreach ($policy in $config.LabelPolicies) {
        if (-not $policy.Name) { $script:errors += "Label policy missing Name" }
        if (-not $policy.Labels -or $policy.Labels.Count -eq 0) {
            $script:warnings += "Label policy '$($policy.Name)' has no labels assigned"
        }

        foreach ($group in @($script:labelGroupNames)) {
            if ($group -and $policy.Labels -contains $group) {
                $script:errors += "Label policy '$($policy.Name)' publishes label group '$group'. Publish the labels in the group instead."
            }
        }

        if ($policy.Settings -and $policy.Settings.defaultlabelid -match "REPLACE") {
            $script:warnings += "Label policy '$($policy.Name)' still has REPLACE placeholder for defaultlabelid"
        }
    }
}

# Validate DLP policies
if ($config.DlpPolicies) {
    foreach ($policy in $config.DlpPolicies) {
        if (-not $policy.Name) { $script:errors += "DLP policy missing Name" }
        if (-not $policy.Rules -or $policy.Rules.Count -eq 0) {
            $script:warnings += "DLP policy '$($policy.Name)' has no rules"
        }
    }
}

# Report results
Write-Host ""
if ($script:errors.Count -gt 0) {
    Write-Host "ERRORS ($($script:errors.Count)):" -ForegroundColor Red
    foreach ($e in $script:errors) { Write-Host "  [ERROR] $e" -ForegroundColor Red }
}

if ($script:warnings.Count -gt 0) {
    Write-Host "WARNINGS ($($script:warnings.Count)):" -ForegroundColor Yellow
    foreach ($w in $script:warnings) { Write-Host "  [WARN]  $w" -ForegroundColor Yellow }
}

if ($script:errors.Count -eq 0 -and $script:warnings.Count -eq 0) {
    Write-Host "PASSED - No errors or warnings." -ForegroundColor Green
}
elseif ($script:errors.Count -eq 0) {
    Write-Host "`nPASSED with $($script:warnings.Count) warning(s)." -ForegroundColor Yellow
}
else {
    Write-Host "`nFAILED - $($script:errors.Count) error(s) found." -ForegroundColor Red
    exit 1
}
