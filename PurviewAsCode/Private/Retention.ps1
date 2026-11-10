# Retention labels, retention label policies (publishing) and retention policies.

$script:RetentionLocations = 'Exchange', 'SharePoint', 'OneDrive', 'ModernGroup', 'TeamsChannel', 'TeamsChat'

function Sync-RetentionLabels {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][array]$Labels)

    Write-Host "`nRetention labels" -ForegroundColor Cyan
    foreach ($label in $Labels) {
        $name = $label.Name
        $existing = Get-ComplianceTag -Identity $name -ErrorAction SilentlyContinue

        if (-not $existing) {
            $item = Add-PlanItem -Area 'Retention label' -Name $name -Action Create -Details "$($label.RetentionAction) after $($label.RetentionDuration) days"
            $null = Invoke-PlanItem -Item $item -Change {
                $new = @{ Name = $name }
                foreach ($k in 'Comment', 'RetentionDuration', 'RetentionAction', 'RetentionType') { if ($null -ne $label[$k]) { $new[$k] = $label[$k] } }
                if ($label.IsRecordLabel) { $new.IsRecordLabel = $true }
                $null = New-ComplianceTag @new -ErrorAction Stop
            }
            continue
        }

        # Set-ComplianceTag can change the duration and the comment. Action, type and record
        # status are fixed once the label exists, so a difference there is reported, not applied.
        $details = @(); $drift = @(); $set = @{}
        if ($null -ne $label.RetentionDuration -and "$($existing.RetentionDuration)" -ne "$($label.RetentionDuration)") {
            $set.RetentionDuration = $label.RetentionDuration; $details += "RetentionDuration: $(Format-Value $existing.RetentionDuration) -> $($label.RetentionDuration)"
        }
        if ($null -ne $label.Comment -and (ConvertTo-Comparable $existing.Comment) -ne (ConvertTo-Comparable $label.Comment)) {
            $set.Comment = $label.Comment; $details += "comment updated"
        }
        foreach ($k in 'RetentionAction', 'RetentionType') {
            if ($label[$k] -and "$($existing.$k)" -and "$($existing.$k)" -ne $label[$k]) {
                $drift += "${k} is $(Format-Value $existing.$k) in the tenant, '$($label[$k])' in the config. Can't be changed on an existing label."
            }
        }
        if ($null -ne $label.IsRecordLabel -and $null -ne $existing.IsRecordLabel -and [bool]$existing.IsRecordLabel -ne [bool]$label.IsRecordLabel) {
            $drift += "IsRecordLabel is $([bool]$existing.IsRecordLabel) in the tenant, $([bool]$label.IsRecordLabel) in the config. Can't be changed on an existing label."
        }

        if ($set.Count) {
            $item = Add-PlanItem -Area 'Retention label' -Name $name -Action Update -Details $details
            $null = Invoke-PlanItem -Item $item -Change { Set-ComplianceTag -Identity $name @set -ErrorAction Stop }
        }
        else { $null = Add-PlanItem -Area 'Retention label' -Name $name -Action NoChange }
        if ($drift) { $null = Add-PlanItem -Area 'Retention label' -Name $name -Action Drift -Details $drift }
    }
}

# Shared by retention policies and retention label policies: create the policy or bring its
# locations in line.
function Sync-RetentionPolicyObject {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Policy, [string]$Area, [switch]$AllowRemoval)

    $name = $Policy.Name
    # Without -DistributionDetail the *Location properties aren't reliable (per the cmdlet docs).
    $existing = Get-RetentionCompliancePolicy -Identity $name -DistributionDetail -ErrorAction SilentlyContinue

    if (-not $existing) {
        $locations = $script:RetentionLocations | Where-Object { $Policy["${_}Location"] } | ForEach-Object { "${_}: $($Policy["${_}Location"] -join ', ')" }
        $item = Add-PlanItem -Area $Area -Name $name -Action Create -Details $locations
        $null = Invoke-PlanItem -Item $item -Change {
            $new = @{ Name = $name }
            foreach ($w in $script:RetentionLocations) { if ($Policy["${w}Location"]) { $new["${w}Location"] = $Policy["${w}Location"] } }
            if ($Policy.Comment) { $new.Comment = $Policy.Comment }
            $null = New-RetentionCompliancePolicy @new -ErrorAction Stop
        }
        return $item
    }

    $details = @(); $drift = @(); $set = @{}
    foreach ($w in $script:RetentionLocations) {
        if (-not $Policy["${w}Location"]) { continue }
        $diff = Compare-NameSet -Current (Get-LocationName $existing."${w}Location") -Desired $Policy["${w}Location"]
        if ($diff.Add.Count) { $set["Add${w}Location"] = $diff.Add; $details += "add $w location: $($diff.Add -join ', ')" }
        if ($diff.Remove.Count) {
            if ($AllowRemoval) { $set["Remove${w}Location"] = $diff.Remove; $details += "remove $w location: $($diff.Remove -join ', ')" }
            else { $drift += "$w location not in the config: $($diff.Remove -join ', ') (use -AllowRemoval to remove)" }
        }
    }
    $item = if ($set.Count) {
        $i = Add-PlanItem -Area $Area -Name $name -Action Update -Details $details
        $null = Invoke-PlanItem -Item $i -Change { Set-RetentionCompliancePolicy -Identity $name @set -ErrorAction Stop }
        $i
    }
    else { Add-PlanItem -Area $Area -Name $name -Action NoChange }
    if ($drift) { $null = Add-PlanItem -Area $Area -Name $name -Action Drift -Details $drift }
    $item
}

function Sync-RetentionPolicies {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][array]$Policies, [switch]$AllowRemoval)

    Write-Host "`nRetention policies" -ForegroundColor Cyan
    foreach ($policy in $Policies) {
        $policyItem = Sync-RetentionPolicyObject -Policy $policy -Area 'Retention policy' -AllowRemoval:$AllowRemoval
        # Rules are checked for existing policies too, so a rule that failed last time is created now.
        foreach ($rule in @($policy.Rules)) {
            if ($rule) { Sync-RetentionRule -PolicyName $policy.Name -Rule $rule -PolicyPending:($policyItem.Action -eq 'Create' -and $policyItem.Status -ne 'Applied') }
        }
    }
}

function Sync-RetentionRule {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$PolicyName, [hashtable]$Rule, [switch]$PolicyPending)

    $name = $Rule.Name
    $existing = if ($PolicyPending) { $null } else { Get-RetentionComplianceRule -Identity $name -ErrorAction SilentlyContinue }

    if (-not $existing) {
        $item = Add-PlanItem -Area 'Retention rule' -Name $name -Action Create -Details "$($Rule.RetentionComplianceAction) for $($Rule.RetentionDuration) days, in: $PolicyName"
        if ($PolicyPending -and -not $WhatIfPreference) {
            $item.Status = 'Failed'; $item.Message = "policy $PolicyName wasn't created"
            return
        }
        $null = Invoke-PlanItem -Item $item -Change {
            $new = @{ Name = $name; Policy = $PolicyName }
            foreach ($k in 'RetentionDuration', 'RetentionDurationDisplayHint', 'RetentionComplianceAction', 'ExpirationDateOption') { if ($Rule[$k]) { $new[$k] = $Rule[$k] } }
            $null = New-RetentionComplianceRule @new -ErrorAction Stop
        }
        return
    }

    $details = @(); $set = @{}
    foreach ($k in 'RetentionDuration', 'RetentionComplianceAction', 'ExpirationDateOption') {
        if ($Rule[$k] -and "$($existing.$k)" -ne "$($Rule[$k])") { $set[$k] = $Rule[$k]; $details += "${k}: $(Format-Value $existing.$k) -> $($Rule[$k])" }
    }
    if ($set.Count) {
        $item = Add-PlanItem -Area 'Retention rule' -Name $name -Action Update -Details $details
        $null = Invoke-PlanItem -Item $item -Change { Set-RetentionComplianceRule -Identity $name @set -ErrorAction Stop }
    }
    else { $null = Add-PlanItem -Area 'Retention rule' -Name $name -Action NoChange }
}

function Sync-RetentionLabelPolicies {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][array]$Policies, [switch]$AllowRemoval)

    Write-Host "`nRetention label policies" -ForegroundColor Cyan
    foreach ($policy in $Policies) {
        $policyItem = Sync-RetentionPolicyObject -Policy $policy -Area 'Retention label policy' -AllowRemoval:$AllowRemoval
        $pending = $policyItem.Action -eq 'Create' -and $policyItem.Status -ne 'Applied'

        # PublishComplianceTag takes one label, so a policy that publishes several labels has one
        # rule per label. Purview stores the value as "<guid>,<name>".
        $published = if ($pending) { @() } else {
            @(Get-RetentionComplianceRule -Policy $policy.Name -ErrorAction SilentlyContinue | ForEach-Object { ("$($_.PublishComplianceTag)" -split ',')[-1] })
        }
        foreach ($label in @($policy.Labels)) {
            if ($published -contains $label) { continue }
            $item = Add-PlanItem -Area 'Retention label policy' -Name $policy.Name -Action Create -Details "publish: $label"
            if ($pending -and -not $WhatIfPreference) { $item.Status = 'Failed'; $item.Message = "policy wasn't created"; continue }
            $null = Invoke-PlanItem -Item $item -Change { $null = New-RetentionComplianceRule -Policy $policy.Name -PublishComplianceTag $label -ErrorAction Stop }
        }
    }
}
