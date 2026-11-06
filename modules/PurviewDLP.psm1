# PurviewDLP.psm1
# Idempotent deployment of DLP policies and rules

function Deploy-DlpPolicies {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Policies
    )

    Write-Host "`n=== Deploying DLP Policies ===" -ForegroundColor Cyan

    foreach ($policyConfig in $Policies) {
        $policyName = $policyConfig.Name
        $existingPolicy = Get-DlpCompliancePolicy -Identity $policyName -ErrorAction SilentlyContinue

        if ($existingPolicy) {
            # Update existing policy locations if changed
            $updateParams = @{}
            $needsUpdate = $false

            if ($policyConfig.ExchangeLocation -and ($existingPolicy.ExchangeLocation -join ",") -ne ($policyConfig.ExchangeLocation -join ",")) {
                $updateParams.ExchangeLocation = $policyConfig.ExchangeLocation
                $needsUpdate = $true
            }
            if ($policyConfig.SharePointLocation -and ($existingPolicy.SharePointLocation -join ",") -ne ($policyConfig.SharePointLocation -join ",")) {
                $updateParams.SharePointLocation = $policyConfig.SharePointLocation
                $needsUpdate = $true
            }
            if ($policyConfig.OneDriveLocation -and ($existingPolicy.OneDriveLocation -join ",") -ne ($policyConfig.OneDriveLocation -join ",")) {
                $updateParams.OneDriveLocation = $policyConfig.OneDriveLocation
                $needsUpdate = $true
            }
            if ($policyConfig.TeamsLocation -and ($existingPolicy.TeamsLocation -join ",") -ne ($policyConfig.TeamsLocation -join ",")) {
                $updateParams.TeamsLocation = $policyConfig.TeamsLocation
                $needsUpdate = $true
            }

            if ($policyConfig.Mode -and $existingPolicy.Mode -ne $policyConfig.Mode) {
                $updateParams.Mode = $policyConfig.Mode
                $needsUpdate = $true
            }

            if ($needsUpdate) {
                if ($PSCmdlet.ShouldProcess($policyName, "Update DLP policy")) {
                    Write-Host "  Updating policy: $policyName" -ForegroundColor Yellow
                    Set-DlpCompliancePolicy -Identity $policyName @updateParams
                    Write-Host "  Updated: $policyName" -ForegroundColor Green
                }
            }
            else {
                Write-Host "  No changes needed for policy: $policyName" -ForegroundColor Gray
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($policyName, "Create DLP policy")) {
                Write-Host "  Creating policy: $policyName" -ForegroundColor Yellow

                $newParams = @{
                    Name = $policyName
                }

                if ($policyConfig.ExchangeLocation) { $newParams.ExchangeLocation = $policyConfig.ExchangeLocation }
                if ($policyConfig.SharePointLocation) { $newParams.SharePointLocation = $policyConfig.SharePointLocation }
                if ($policyConfig.OneDriveLocation) { $newParams.OneDriveLocation = $policyConfig.OneDriveLocation }
                if ($policyConfig.TeamsLocation) { $newParams.TeamsLocation = $policyConfig.TeamsLocation }
                if ($policyConfig.Mode) { $newParams.Mode = $policyConfig.Mode }
                if ($policyConfig.Comment) { $newParams.Comment = $policyConfig.Comment }

                New-DlpCompliancePolicy @newParams
                Write-Host "  Created: $policyName" -ForegroundColor Green
            }
        }

        # Deploy rules for this policy
        if ($policyConfig.Rules) {
            Deploy-DlpRules -PolicyName $policyName -Rules $policyConfig.Rules
        }
    }
}

function Deploy-DlpRules {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PolicyName,

        [Parameter(Mandatory = $true)]
        [array]$Rules
    )

    foreach ($ruleConfig in $Rules) {
        $ruleName = $ruleConfig.Name
        $existingRule = Get-DlpComplianceRule -Identity $ruleName -ErrorAction SilentlyContinue

        $ruleParams = @{}

        if ($ruleConfig.ContentContainsSensitiveInformation) {
            $ruleParams.ContentContainsSensitiveInformation = $ruleConfig.ContentContainsSensitiveInformation
        }
        if ($null -ne $ruleConfig.BlockAccess) { $ruleParams.BlockAccess = [bool]$ruleConfig.BlockAccess }
        if ($ruleConfig.NotifyUser) { $ruleParams.NotifyUser = $ruleConfig.NotifyUser }
        if ($ruleConfig.GenerateIncidentReport) { $ruleParams.GenerateIncidentReport = $ruleConfig.GenerateIncidentReport }
        if ($ruleConfig.ReportSeverityLevel) { $ruleParams.ReportSeverityLevel = $ruleConfig.ReportSeverityLevel }

        if ($existingRule) {
            if ($PSCmdlet.ShouldProcess($ruleName, "Update DLP rule")) {
                Write-Host "    Updating rule: $ruleName" -ForegroundColor Yellow
                Set-DlpComplianceRule -Identity $ruleName @ruleParams
                Write-Host "    Updated: $ruleName" -ForegroundColor Green
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($ruleName, "Create DLP rule")) {
                Write-Host "    Creating rule: $ruleName" -ForegroundColor Yellow
                New-DlpComplianceRule -Name $ruleName -Policy $PolicyName @ruleParams
                Write-Host "    Created: $ruleName" -ForegroundColor Green
            }
        }
    }
}

Export-ModuleMember -Function Deploy-DlpPolicies
