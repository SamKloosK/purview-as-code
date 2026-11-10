# DLP policies and rules.
#
# Set-DlpCompliancePolicy has no -ExchangeLocation or -SharePointLocation: an existing policy only
# takes AddXxxLocation and RemoveXxxLocation. New-DlpCompliancePolicy does take the plain ones.

$script:DlpLocations = 'Exchange', 'SharePoint', 'OneDrive', 'Teams'

function ConvertTo-PlainTable {
    param($Item)
    $h = @{}
    if ($Item -is [System.Collections.IDictionary]) { foreach ($k in $Item.Keys) { $h["$k".ToLowerInvariant()] = $Item[$k] } }
    else { foreach ($p in $Item.PSObject.Properties) { $h[$p.Name.ToLowerInvariant()] = $p.Value } }
    $h
}

# True when the sensitive information types differ. Only the keys you set in the config are
# compared, because the tenant fills in defaults (confidence level, max count) you didn't ask for.
function Test-SitListChanged {
    param($Current, $Desired)
    $cur = @{}
    foreach ($c in @($Current)) { if ($c) { $t = ConvertTo-PlainTable $c; $cur["$($t.name)".ToLowerInvariant()] = $t } }
    $des = @(@($Desired) | Where-Object { $_ } | ForEach-Object { ConvertTo-PlainTable $_ })
    if ($cur.Count -ne $des.Count) { return $true }
    foreach ($d in $des) {
        $c = $cur["$($d.name)".ToLowerInvariant()]
        if (-not $c) { return $true }
        foreach ($k in $d.Keys) {
            if ((ConvertTo-Comparable $c[$k]) -ne (ConvertTo-Comparable $d[$k])) { return $true }
        }
    }
    $false
}

function Sync-DlpPolicies {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][array]$Policies, [switch]$AllowRemoval)

    Write-Host "`nDLP policies" -ForegroundColor Cyan
    foreach ($policy in $Policies) {
        $name = $policy.Name
        $existing = Get-DlpCompliancePolicy -Identity $name -ErrorAction SilentlyContinue

        if (-not $existing) {
            $locations = $script:DlpLocations | Where-Object { $policy["${_}Location"] } | ForEach-Object { "${_}: $($policy["${_}Location"] -join ', ')" }
            $item = Add-PlanItem -Area 'DLP policy' -Name $name -Action Create -Details (@("mode: $($policy.Mode)") + $locations)
            $null = Invoke-PlanItem -Item $item -Change {
                $new = @{ Name = $name }
                foreach ($w in $script:DlpLocations) { if ($policy["${w}Location"]) { $new["${w}Location"] = $policy["${w}Location"] } }
                if ($policy.Mode) { $new.Mode = $policy.Mode }
                if ($policy.Comment) { $new.Comment = $policy.Comment }
                $null = New-DlpCompliancePolicy @new -ErrorAction Stop
            }
        }
        else {
            $details = @(); $drift = @(); $set = @{}
            foreach ($w in $script:DlpLocations) {
                if (-not $policy["${w}Location"]) { continue }
                $diff = Compare-NameSet -Current (Get-LocationName $existing."${w}Location") -Desired $policy["${w}Location"]
                if ($diff.Add.Count) { $set["Add${w}Location"] = $diff.Add; $details += "add $w location: $($diff.Add -join ', ')" }
                if ($diff.Remove.Count) {
                    if ($AllowRemoval) { $set["Remove${w}Location"] = $diff.Remove; $details += "remove $w location: $($diff.Remove -join ', ')" }
                    else { $drift += "$w location not in the config: $($diff.Remove -join ', ') (use -AllowRemoval to remove)" }
                }
            }
            if ($policy.Mode -and "$($existing.Mode)" -ne $policy.Mode) {
                $set.Mode = $policy.Mode; $details += "mode: $(Format-Value $existing.Mode) -> '$($policy.Mode)'"
            }
            if ($null -ne $policy.Comment -and (ConvertTo-Comparable $existing.Comment) -ne (ConvertTo-Comparable $policy.Comment)) {
                $set.Comment = $policy.Comment; $details += "comment updated"
            }

            if ($set.Count) {
                $item = Add-PlanItem -Area 'DLP policy' -Name $name -Action Update -Details $details
                $null = Invoke-PlanItem -Item $item -Change { Set-DlpCompliancePolicy -Identity $name @set -ErrorAction Stop }
            }
            else { $null = Add-PlanItem -Area 'DLP policy' -Name $name -Action NoChange }
            if ($drift) { $null = Add-PlanItem -Area 'DLP policy' -Name $name -Action Drift -Details $drift }
        }

        foreach ($rule in @($policy.Rules)) {
            if ($rule) { Sync-DlpRule -PolicyName $name -Rule $rule }
        }
    }
}

function Sync-DlpRule {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$PolicyName, [hashtable]$Rule)

    $name = $Rule.Name
    $desired = @{}
    foreach ($k in 'ContentContainsSensitiveInformation', 'NotifyUser', 'GenerateIncidentReport', 'ReportSeverityLevel') {
        if ($Rule[$k]) { $desired[$k] = $Rule[$k] }
    }
    # BlockAccess false is a real setting, not "not set".
    if ($null -ne $Rule.BlockAccess) { $desired.BlockAccess = [bool]$Rule.BlockAccess }

    $existing = Get-DlpComplianceRule -Identity $name -ErrorAction SilentlyContinue
    if (-not $existing) {
        $item = Add-PlanItem -Area 'DLP rule' -Name $name -Action Create -Details "in: $PolicyName"
        $null = Invoke-PlanItem -Item $item -Change { $null = New-DlpComplianceRule -Name $name -Policy $PolicyName @desired -ErrorAction Stop }
        return
    }

    # Rule names are unique per tenant, so a rule with this name under another policy is a conflict,
    # not something to update.
    if ($existing.ParentPolicyName -and $existing.ParentPolicyName -ne $PolicyName) {
        $null = Add-PlanItem -Area 'DLP rule' -Name $name -Action Error -Details "exists under policy '$($existing.ParentPolicyName)', not '$PolicyName'"
        return
    }

    $details = @(); $set = @{}
    if ($desired.ContainsKey('ContentContainsSensitiveInformation')) {
        if (Test-SitListChanged -Current $existing.ContentContainsSensitiveInformation -Desired $desired.ContentContainsSensitiveInformation) { $set.ContentContainsSensitiveInformation = $desired.ContentContainsSensitiveInformation; $details += "sensitive info types changed" }
    }
    if ($desired.ContainsKey('BlockAccess') -and [bool]$existing.BlockAccess -ne $desired.BlockAccess) {
        $set.BlockAccess = $desired.BlockAccess; $details += "BlockAccess: $([bool]$existing.BlockAccess) -> $($desired.BlockAccess)"
    }
    foreach ($k in 'NotifyUser', 'GenerateIncidentReport') {
        if (-not $desired.ContainsKey($k)) { continue }
        $diff = Compare-NameSet -Current @($existing.$k) -Desired @($desired[$k])
        if ($diff.Add.Count -or $diff.Remove.Count) { $set[$k] = $desired[$k]; $details += "${k}: $(Format-Value @($existing.$k)) -> $(Format-Value @($desired[$k]))" }
    }
    if ($desired.ReportSeverityLevel -and "$($existing.ReportSeverityLevel)" -ne $desired.ReportSeverityLevel) {
        $set.ReportSeverityLevel = $desired.ReportSeverityLevel; $details += "ReportSeverityLevel: $(Format-Value $existing.ReportSeverityLevel) -> '$($desired.ReportSeverityLevel)'"
    }

    if ($set.Count) {
        $item = Add-PlanItem -Area 'DLP rule' -Name $name -Action Update -Details $details
        $null = Invoke-PlanItem -Item $item -Change { Set-DlpComplianceRule -Identity $name @set -ErrorAction Stop }
    }
    else { $null = Add-PlanItem -Area 'DLP rule' -Name $name -Action NoChange }
}
