# PurviewLabels.psm1
# Idempotent deployment of sensitivity labels and label policies
#
# Important: Content marking (headers, footers, watermarks) is applied via
# Set-Label after label creation, using the ApplyContentMarking* and
# ApplyWaterMarking* parameters. These are NOT available on New-Label.

function Deploy-SensitivityLabels {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Labels
    )

    Write-Host "`n=== Deploying Sensitivity Labels ===" -ForegroundColor Cyan

    foreach ($labelConfig in $Labels) {
        Deploy-SingleLabel -LabelConfig $labelConfig -ParentName $null
    }
}

function Deploy-SingleLabel {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$LabelConfig,

        [Parameter(Mandatory = $false)]
        [string]$ParentName
    )

    $labelName = $LabelConfig.Name
    $displayName = $LabelConfig.DisplayName
    $existingLabel = Get-Label -Identity $labelName -ErrorAction SilentlyContinue

    if ($existingLabel) {
        Write-Host "  Already exists: $labelName (re-applying settings from config)" -ForegroundColor Gray
        Set-PurviewLabelSettings -LabelName $labelName -LabelConfig $LabelConfig
    }
    else {
        if ($PSCmdlet.ShouldProcess($labelName, "Create sensitivity label")) {
            Write-Host "  Creating label: $labelName" -ForegroundColor Yellow

            # New-Label only takes basic parameters
            $newParams = @{
                Name        = $labelName
                DisplayName = $displayName
                Tooltip     = $LabelConfig.Tooltip
                Comment     = $LabelConfig.Comment
            }

            # Scope: e.g. "File, Email" or "Site, UnifiedGroup" for container labels
            if ($LabelConfig.Scope) {
                $newParams.ContentType = $LabelConfig.Scope
            }

            # Parent label for sublabels
            if ($ParentName) {
                $parentLabel = Get-Label -Identity $ParentName
                $newParams.ParentId = $parentLabel.Guid
            }

            $createdLabel = New-Label @newParams
            Write-Host "  Created: $labelName" -ForegroundColor Green

            # Apply encryption and content marking via Set-Label
            Set-PurviewLabelSettings -LabelName $labelName -LabelConfig $LabelConfig
        }
    }

    # Process sublabels recursively
    if ($LabelConfig.SubLabels) {
        foreach ($subLabel in $LabelConfig.SubLabels) {
            Deploy-SingleLabel -LabelConfig $subLabel -ParentName $labelName
        }
    }
}

function Set-PurviewLabelSettings {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$LabelName,

        [Parameter(Mandatory = $true)]
        [hashtable]$LabelConfig
    )

    $setParams = @{}
    $hasChanges = $false

    # Encryption settings
    if ($LabelConfig.Encryption) {
        $enc = $LabelConfig.Encryption
        $setParams.EncryptionEnabled = $true
        $setParams.EncryptionProtectionType = $enc.ProtectionType

        if ($enc.ProtectionType -eq "Template") {
            if ($enc.EncryptionRightsDefinitions) {
                $setParams.EncryptionRightsDefinitions = $enc.EncryptionRightsDefinitions
            }
            if ($null -ne $enc.EncryptionOfflineAccessDays) {
                $setParams.EncryptionOfflineAccessDays = $enc.EncryptionOfflineAccessDays
            }
            if ($null -ne $enc.EncryptionContentExpiredOnDateInDaysOrNever) {
                $setParams.EncryptionContentExpiredOnDateInDaysOrNever = $enc.EncryptionContentExpiredOnDateInDaysOrNever
            }
        }
        $hasChanges = $true
    }

    # Content marking: Header
    if ($LabelConfig.ContentMarking -and $LabelConfig.ContentMarking.Header) {
        $h = $LabelConfig.ContentMarking.Header
        $setParams.ApplyContentMarkingHeaderEnabled    = $true
        $setParams.ApplyContentMarkingHeaderText       = $h.Text
        $setParams.ApplyContentMarkingHeaderFontSize   = $h.FontSize
        $setParams.ApplyContentMarkingHeaderFontColor  = $h.FontColor
        $setParams.ApplyContentMarkingHeaderAlignment  = $h.Alignment
        $hasChanges = $true
    }

    # Content marking: Footer
    if ($LabelConfig.ContentMarking -and $LabelConfig.ContentMarking.Footer) {
        $f = $LabelConfig.ContentMarking.Footer
        $setParams.ApplyContentMarkingFooterEnabled    = $true
        $setParams.ApplyContentMarkingFooterText       = $f.Text
        $setParams.ApplyContentMarkingFooterFontSize   = $f.FontSize
        $setParams.ApplyContentMarkingFooterFontColor  = $f.FontColor
        $setParams.ApplyContentMarkingFooterAlignment  = $f.Alignment
        $hasChanges = $true
    }

    # Content marking: Watermark
    if ($LabelConfig.ContentMarking -and $LabelConfig.ContentMarking.Watermark) {
        $w = $LabelConfig.ContentMarking.Watermark
        $setParams.ApplyWaterMarkingEnabled   = $true
        $setParams.ApplyWaterMarkingText      = $w.Text
        $setParams.ApplyWaterMarkingFontSize  = $w.FontSize
        $setParams.ApplyWaterMarkingFontColor = $w.FontColor
        $setParams.ApplyWaterMarkingLayout    = $w.Layout
        $hasChanges = $true
    }

    # Container settings for SharePoint sites and Microsoft 365 groups
    # Requires the label Scope to include Site and/or UnifiedGroup, and container labels enabled in Entra ID
    if ($LabelConfig.SiteAndGroupProtection) {
        $sg = $LabelConfig.SiteAndGroupProtection
        $setParams.SiteAndGroupProtectionEnabled = $true
        if ($sg.Privacy) { $setParams.SiteAndGroupProtectionPrivacy = $sg.Privacy }
        if ($null -ne $sg.AllowAccessToGuestUsers) {
            $setParams.SiteAndGroupProtectionAllowAccessToGuestUsers = [bool]$sg.AllowAccessToGuestUsers
        }
        if ($sg.ExternalSharing) { $setParams.SiteExternalSharingControlType = $sg.ExternalSharing }
        switch ($sg.UnmanagedDevices) {
            "FullAccess"    { $setParams.SiteAndGroupProtectionAllowFullAccess = $true }
            "LimitedAccess" { $setParams.SiteAndGroupProtectionAllowLimitedAccess = $true }
            "BlockAccess"   { $setParams.SiteAndGroupProtectionBlockAccess = $true }
        }
        $hasChanges = $true
    }

    if ($hasChanges) {
        if ($PSCmdlet.ShouldProcess($LabelName, "Apply label settings (encryption/content marking/container)")) {
            Write-Host "    Applying settings to: $LabelName" -ForegroundColor DarkCyan
            Set-Label -Identity $LabelName @setParams
            Write-Host "    Settings applied: $LabelName" -ForegroundColor Green
        }
    }
}

function Deploy-LabelPolicy {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Policies
    )

    Write-Host "`n=== Deploying Label Policies ===" -ForegroundColor Cyan

    foreach ($policyConfig in $Policies) {
        $policyName = $policyConfig.Name
        $existingPolicy = Get-LabelPolicy -Identity $policyName -ErrorAction SilentlyContinue

        # Resolve label names to the flat list (including sublabels)
        $labelNames = $policyConfig.Labels

        if ($existingPolicy) {
            # Check if labels need updating
            $existingLabels = ($existingPolicy.Labels | Sort-Object) -join ","
            $desiredLabels = ($labelNames | Sort-Object) -join ","

            if ($existingLabels -ne $desiredLabels) {
                if ($PSCmdlet.ShouldProcess($policyName, "Update label policy")) {
                    Write-Host "  Updating policy: $policyName" -ForegroundColor Yellow

                    $toAdd = $labelNames | Where-Object { $_ -notin $existingPolicy.Labels }
                    $toRemove = $existingPolicy.Labels | Where-Object { $_ -notin $labelNames }

                    $updateParams = @{}
                    if ($toAdd) { $updateParams.AddLabels = $toAdd }
                    if ($toRemove) { $updateParams.RemoveLabels = $toRemove }

                    try {
                        Set-LabelPolicy -Identity $policyName @updateParams -ErrorAction Stop
                        Write-Host "  Updated: $policyName" -ForegroundColor Green
                    }
                    catch {
                        Write-Host "  FAILED: $policyName : $($_.Exception.Message)" -ForegroundColor Red
                    }
                }
            }
            else {
                Write-Host "  No label changes needed: $policyName" -ForegroundColor Gray
            }

            if ($policyConfig.Settings -and $PSCmdlet.ShouldProcess($policyName, "Apply label policy settings")) {
                $advancedSettings = @{}
                foreach ($key in $policyConfig.Settings.Keys) { $advancedSettings[$key] = $policyConfig.Settings[$key] }
                Set-LabelPolicy -Identity $policyName -AdvancedSettings $advancedSettings
                Write-Host "    Policy settings applied." -ForegroundColor Green
            }
        }
        else {
            if ($PSCmdlet.ShouldProcess($policyName, "Create label policy")) {
                Write-Host "  Creating policy: $policyName" -ForegroundColor Yellow

                $newParams = @{
                    Name   = $policyName
                    Labels = $labelNames
                }

                if ($policyConfig.ExchangeLocation) {
                    $newParams.ExchangeLocation = $policyConfig.ExchangeLocation
                }

                New-LabelPolicy @newParams
                Write-Host "  Created: $policyName" -ForegroundColor Green

                # Apply advanced settings separately
                if ($policyConfig.Settings) {
                    Write-Host "    Applying policy settings..." -ForegroundColor DarkCyan
                    $advancedSettings = @{}
                    foreach ($key in $policyConfig.Settings.Keys) {
                        $advancedSettings[$key] = $policyConfig.Settings[$key]
                    }
                    Set-LabelPolicy -Identity $policyName -AdvancedSettings $advancedSettings
                    Write-Host "    Policy settings applied." -ForegroundColor Green
                }
            }
        }
    }
}

Export-ModuleMember -Function Deploy-SensitivityLabels, Deploy-LabelPolicy
