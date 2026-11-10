# Checks a config before anything talks to the tenant. Returns errors and warnings; the deploy
# stops on errors.

function Get-ConfigProblems {
    param([Parameter(Mandatory)][hashtable]$Config)

    $errors = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()
    $labelNames = [System.Collections.Generic.List[string]]::new()
    $groupNames = [System.Collections.Generic.List[string]]::new()
    $parentOf = @{}

    if (-not $Config.ClientName) { $errors.Add("ClientName is missing") }
    if (-not $Config.TenantDomain) { $errors.Add("TenantDomain is missing") }
    elseif ($Config.TenantDomain -notmatch '\.onmicrosoft\.com$') {
        $warnings.Add("TenantDomain '$($Config.TenantDomain)' isn't an .onmicrosoft.com domain. App-only connections need the .onmicrosoft.com one.")
    }

    $walk = {
        param([array]$Labels, [string]$Parent)
        foreach ($l in $Labels) {
            $path = if ($Parent) { "$Parent/$($l.Name)" } else { "$($l.Name)" }
            if (-not $l.Name) { $errors.Add("Label at '$path' has no Name"); continue }
            if (-not $l.DisplayName) { $errors.Add("Label '$path' has no DisplayName") }
            if ($l.Name -in $labelNames) { $errors.Add("Label name '$($l.Name)' is used twice") }
            $labelNames.Add($l.Name)
            if ($Parent) { $parentOf[$l.Name] = $Parent }

            if ($l.IsLabelGroup) {
                $groupNames.Add($l.Name)
                if ($Parent) { $errors.Add("Label group '$path' isn't a top-level label") }
                foreach ($s in 'Scope', 'Encryption', 'ContentMarking', 'SiteAndGroupProtection') {
                    if ($l[$s]) { $errors.Add("Label group '$path' has $s, which label groups don't support") }
                }
                if (-not $l.SubLabels) { $warnings.Add("Label group '$path' has no labels in it") }
            }
            if ($l.Encryption) {
                $e = $l.Encryption
                switch ($e.ProtectionType) {
                    'Template' {
                        if (-not $e.EncryptionRightsDefinitions) { $errors.Add("Label '$path' uses Template encryption without EncryptionRightsDefinitions") }
                    }
                    'UserDefined' {
                        if (-not ($e.PromptUser -or $e.DoNotForward -or $e.EncryptOnly)) {
                            $warnings.Add("Label '$path' uses UserDefined encryption without PromptUser, DoNotForward or EncryptOnly. The portal requires at least one.")
                        }
                    }
                    $null { $errors.Add("Label '$path' has Encryption without ProtectionType") }
                    default { $errors.Add("Label '$path' has ProtectionType '$($e.ProtectionType)'; use Template or UserDefined") }
                }
            }
            if ($l.SubLabels) { & $walk $l.SubLabels $l.Name }
        }
    }
    if ($Config.SensitivityLabels) { & $walk $Config.SensitivityLabels $null }

    foreach ($p in @($Config.LabelPolicies)) {
        if (-not $p) { continue }
        if (-not $p.Name) { $errors.Add("A label policy has no Name"); continue }
        if (-not $p.Labels) { $warnings.Add("Label policy '$($p.Name)' publishes no labels") }
        foreach ($label in @($p.Labels)) {
            if ($label -in $groupNames) { $errors.Add("Label policy '$($p.Name)' publishes label group '$label'. Publish the labels in the group instead.") }
            elseif ($labelNames.Count -and $label -notin $labelNames) { $warnings.Add("Label policy '$($p.Name)' publishes '$label', which isn't in this config. Fine if it already exists in the tenant.") }
            # Classic scheme: a sublabel needs its parent label in the same policy.
            $parent = $parentOf[$label]
            if ($parent -and $parent -notin $groupNames -and $parent -notin @($p.Labels)) {
                $errors.Add("Label policy '$($p.Name)' publishes '$label' without its parent label '$parent'")
            }
        }
        if ($p.Settings -and $p.Settings.defaultlabelid) {
            $d = "$($p.Settings.defaultlabelid)"
            if ($d -notmatch '^[0-9a-fA-F-]{36}$' -and $d -notin @($p.Labels)) {
                $errors.Add("Label policy '$($p.Name)' has defaultlabelid '$d', which isn't a GUID or one of the labels it publishes")
            }
        }
    }

    foreach ($p in @($Config.DlpPolicies)) {
        if (-not $p) { continue }
        if (-not $p.Name) { $errors.Add("A DLP policy has no Name"); continue }
        if ($p.Mode -and $p.Mode -notin 'Enable', 'TestWithNotifications', 'TestWithoutNotifications', 'Disable') {
            $errors.Add("DLP policy '$($p.Name)' has Mode '$($p.Mode)'")
        }
        if (-not $p.Rules) { $warnings.Add("DLP policy '$($p.Name)' has no rules") }
        foreach ($r in @($p.Rules)) { if ($r -and -not $r.Name) { $errors.Add("A rule in DLP policy '$($p.Name)' has no Name") } }
    }

    $retentionLabelNames = @($Config.RetentionLabels | Where-Object { $_ } | ForEach-Object { $_.Name })
    foreach ($l in @($Config.RetentionLabels)) {
        if (-not $l) { continue }
        if (-not $l.Name) { $errors.Add("A retention label has no Name"); continue }
        if ($null -eq $l.RetentionDuration) { $warnings.Add("Retention label '$($l.Name)' has no RetentionDuration") }
    }
    foreach ($p in @($Config.RetentionLabelPolicies)) {
        if (-not $p) { continue }
        if (-not $p.Name) { $errors.Add("A retention label policy has no Name"); continue }
        foreach ($label in @($p.Labels)) {
            if ($retentionLabelNames -and $label -notin $retentionLabelNames) {
                $warnings.Add("Retention label policy '$($p.Name)' publishes '$label', which isn't in this config")
            }
        }
    }
    foreach ($p in @($Config.RetentionPolicies)) {
        if (-not $p) { continue }
        if (-not $p.Name) { $errors.Add("A retention policy has no Name"); continue }
        if (-not $p.Rules) { $warnings.Add("Retention policy '$($p.Name)' has no rule, so it retains nothing") }
    }

    # Placeholders from the examples shouldn't reach a tenant.
    $json = $Config | ConvertTo-Json -Depth 20
    foreach ($m in [regex]::Matches($json, 'REPLACE[-_A-Z0-9]*')) { $errors.Add("Placeholder '$($m.Value)' is still in the config") }

    [pscustomobject]@{ Errors = $errors.ToArray(); Warnings = $warnings.ToArray() }
}
