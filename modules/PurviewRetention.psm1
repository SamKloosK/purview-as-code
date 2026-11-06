# PurviewRetention.psm1
# Idempotent deployment of retention policies and retention labels

function Deploy-RetentionPolicies {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Policies
    )

    Write-Host "`n=== Deploying Retention Policies ===" -ForegroundColor Cyan

    foreach ($policyConfig in $Policies) {
        $policyName = $policyConfig.Name
        $existingPolicy = Get-RetentionCompliancePolicy -Identity $policyName -ErrorAction SilentlyContinue

        if ($existingPolicy) {
            Write-Host "  No changes needed: $policyName" -ForegroundColor Gray
            # TODO: Implement change detection for retention policies
        }
        else {
            if ($PSCmdlet.ShouldProcess($policyName, "Create retention policy")) {
                Write-Host "  Creating policy: $policyName" -ForegroundColor Yellow

                $newParams = @{
                    Name = $policyName
                }

                if ($policyConfig.ExchangeLocation) { $newParams.ExchangeLocation = $policyConfig.ExchangeLocation }
                if ($policyConfig.SharePointLocation) { $newParams.SharePointLocation = $policyConfig.SharePointLocation }
                if ($policyConfig.OneDriveLocation) { $newParams.OneDriveLocation = $policyConfig.OneDriveLocation }
                if ($policyConfig.TeamsChannelLocation) { $newParams.TeamsChannelLocation = $policyConfig.TeamsChannelLocation }
                if ($policyConfig.TeamsChatLocation) { $newParams.TeamsChatLocation = $policyConfig.TeamsChatLocation }
                if ($policyConfig.Comment) { $newParams.Comment = $policyConfig.Comment }

                New-RetentionCompliancePolicy @newParams
                Write-Host "  Created: $policyName" -ForegroundColor Green

                # Deploy rules for this policy
                if ($policyConfig.Rules) {
                    Deploy-RetentionRules -PolicyName $policyName -Rules $policyConfig.Rules
                }
            }
        }
    }
}

function Deploy-RetentionRules {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyName,

        [Parameter(Mandatory = $true)]
        [array]$Rules
    )

    foreach ($ruleConfig in $Rules) {
        $ruleName = $ruleConfig.Name
        $existingRule = Get-RetentionComplianceRule -Identity $ruleName -ErrorAction SilentlyContinue

        if (-not $existingRule) {
            if ($PSCmdlet.ShouldProcess($ruleName, "Create retention rule")) {
                Write-Host "    Creating rule: $ruleName" -ForegroundColor Yellow

                $ruleParams = @{
                    Name   = $ruleName
                    Policy = $PolicyName
                }

                if ($ruleConfig.RetentionDuration) { $ruleParams.RetentionDuration = $ruleConfig.RetentionDuration }
                if ($ruleConfig.RetentionDurationDisplayHint) { $ruleParams.RetentionDurationDisplayHint = $ruleConfig.RetentionDurationDisplayHint }
                if ($ruleConfig.RetentionComplianceAction) { $ruleParams.RetentionComplianceAction = $ruleConfig.RetentionComplianceAction }
                if ($ruleConfig.ExpirationDateOption) { $ruleParams.ExpirationDateOption = $ruleConfig.ExpirationDateOption }

                New-RetentionComplianceRule @ruleParams
                Write-Host "    Created: $ruleName" -ForegroundColor Green
            }
        }
        else {
            Write-Host "    No changes needed: $ruleName" -ForegroundColor Gray
        }
    }
}

function Deploy-RetentionLabels {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Labels
    )

    Write-Host "`n=== Deploying Retention Labels ===" -ForegroundColor Cyan

    foreach ($labelConfig in $Labels) {
        $labelName = $labelConfig.Name
        $existingLabel = Get-ComplianceTag -Identity $labelName -ErrorAction SilentlyContinue

        if (-not $existingLabel) {
            if ($PSCmdlet.ShouldProcess($labelName, "Create retention label")) {
                Write-Host "  Creating retention label: $labelName" -ForegroundColor Yellow

                $labelParams = @{
                    Name = $labelName
                }

                if ($labelConfig.Comment) { $labelParams.Comment = $labelConfig.Comment }
                if ($labelConfig.RetentionDuration) { $labelParams.RetentionDuration = $labelConfig.RetentionDuration }
                if ($labelConfig.RetentionAction) { $labelParams.RetentionAction = $labelConfig.RetentionAction }
                if ($labelConfig.RetentionType) { $labelParams.RetentionType = $labelConfig.RetentionType }
                if ($labelConfig.IsRecordLabel) { $labelParams.IsRecordLabel = $labelConfig.IsRecordLabel }

                try {
                    New-ComplianceTag @labelParams -ErrorAction Stop | Out-Null
                    Write-Host "  Created: $labelName" -ForegroundColor Green
                }
                catch {
                    Write-Host "  FAILED: $labelName : $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
        else {
            Write-Host "  No changes needed: $labelName" -ForegroundColor Gray
        }
    }
}

function Deploy-RetentionLabelPolicies {
    # Publishes retention labels to locations, so they can be applied manually
    # or set as default label on a SharePoint document library.
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Policies
    )

    Write-Host "`n=== Deploying Retention Label Policies (publish) ===" -ForegroundColor Cyan

    foreach ($policyConfig in $Policies) {
        $policyName = $policyConfig.Name
        $existingPolicy = Get-RetentionCompliancePolicy -Identity $policyName -ErrorAction SilentlyContinue

        if ($existingPolicy) {
            Write-Host "  Already exists: $policyName" -ForegroundColor Gray
            # TODO: Implement change detection for locations
        }
        else {
            if ($PSCmdlet.ShouldProcess($policyName, "Create retention label policy")) {
                Write-Host "  Creating label policy: $policyName" -ForegroundColor Yellow

                $newParams = @{ Name = $policyName }
                if ($policyConfig.Comment) { $newParams.Comment = $policyConfig.Comment }
                if ($policyConfig.ExchangeLocation) { $newParams.ExchangeLocation = $policyConfig.ExchangeLocation }
                if ($policyConfig.SharePointLocation) { $newParams.SharePointLocation = $policyConfig.SharePointLocation }
                if ($policyConfig.OneDriveLocation) { $newParams.OneDriveLocation = $policyConfig.OneDriveLocation }
                if ($policyConfig.ModernGroupLocation) { $newParams.ModernGroupLocation = $policyConfig.ModernGroupLocation }

                New-RetentionCompliancePolicy @newParams | Out-Null
                Write-Host "  Created: $policyName" -ForegroundColor Green
            }
        }

        # PublishComplianceTag takes ONE label. A policy that publishes several labels
        # has one rule per label (Purview stores each as "<guid>,<name>").
        $existingRules = @(Get-RetentionComplianceRule -Policy $policyName -ErrorAction SilentlyContinue)
        $published = @($existingRules | ForEach-Object { ($_.PublishComplianceTag -split ",")[-1] })

        foreach ($label in $policyConfig.Labels) {
            if ($published -contains $label) {
                Write-Host "    Already published: $label" -ForegroundColor Gray
            }
            elseif ($PSCmdlet.ShouldProcess($policyName, "Publish retention label '$label'")) {
                try {
                    New-RetentionComplianceRule -Policy $policyName -PublishComplianceTag $label -ErrorAction Stop | Out-Null
                    Write-Host "    Published: $label" -ForegroundColor Green
                }
                catch {
                    Write-Host "    FAILED to publish $label on $policyName : $($_.Exception.Message)" -ForegroundColor Red
                }
            }
        }
    }
}

Export-ModuleMember -Function Deploy-RetentionPolicies, Deploy-RetentionLabels, Deploy-RetentionLabelPolicies
