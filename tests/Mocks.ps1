# Stand-ins for the Security & Compliance cmdlets, so the module can run without a tenant.
# Parameter sets follow the real cmdlets (Set-DlpCompliancePolicy has no -SharePointLocation, for
# example), so calling a parameter that doesn't exist fails here the same way it would for real.
# State is kept in $global:MockTenant and every write is logged in $global:MockWrites.
#
# How Get-Label returns LabelActions is modelled on what I've seen in tenants; it is not a
# guarantee of the real format. The tests check that the module is consistent with itself and
# never writes in -WhatIf, not that Microsoft stores a setting under a particular key.

function global:Reset-MockTenant {
    $global:MockTenant = @{ Labels = [ordered]@{}; LabelPolicies = @{}; Dlp = @{}; DlpRules = @{}; Tags = @{}; RetPolicies = @{}; RetRules = @{} }
    $global:MockWrites = [System.Collections.Generic.List[string]]::new()
    $global:MockTenantId = '11111111-2222-3333-4444-555555555555'
    $global:MockFail = @()
}
Reset-MockTenant

function global:Write-MockCall { param($Name, $Target) $global:MockWrites.Add("$Name $Target"); if ($Name -in $global:MockFail) { throw "simulated failure in $Name" } }

function global:Get-ConnectionInformation { [pscustomobject]@{ IsEopSession = $true; State = 'Connected'; TenantID = $global:MockTenantId } }
function global:Connect-IPPSSession { param($ShowBanner, $UserPrincipalName, $AppId, $CertificateThumbprint, $Organization) }
function global:Disconnect-ExchangeOnline { param($Confirm) }

function global:New-MockAction { param($Type, $SubType, [hashtable]$Settings)
    $list = @($Settings.GetEnumerator() | ForEach-Object { @{ Key = $_.Key; Value = "$($_.Value)" } })
    @{ Type = $Type; SubType = $SubType; Settings = $list } | ConvertTo-Json -Depth 5 -Compress
}

function global:Get-Label { [CmdletBinding()] param($Identity)
    if ($Identity) { $global:MockTenant.Labels[$Identity] } else { @($global:MockTenant.Labels.Values) }
}
function global:New-Label { [CmdletBinding()] param($Name, $DisplayName, $Tooltip, $Comment, $ParentId, $ContentType, [switch]$IsLabelGroup)
    Write-MockCall 'New-Label' $Name
    $global:MockTenant.Labels[$Name] = [pscustomobject]@{
        Name = $Name; DisplayName = $DisplayName; Tooltip = $Tooltip; Comment = $Comment; ContentType = $ContentType
        Guid = [guid]::NewGuid(); ParentId = $ParentId; Priority = $global:MockTenant.Labels.Count; Actions = @{}; LabelActions = @()
    }
}
function global:Set-Label { [CmdletBinding()] param(
        $Identity, $DisplayName, $Tooltip, $Comment, $ContentType,
        $EncryptionEnabled, $EncryptionProtectionType, $EncryptionRightsDefinitions, $EncryptionOfflineAccessDays, $EncryptionContentExpiredOnDateInDaysOrNever,
        $EncryptionPromptUser, $EncryptionDoNotForward, $EncryptionEncryptOnly,
        $ApplyContentMarkingHeaderEnabled, $ApplyContentMarkingHeaderText, $ApplyContentMarkingHeaderFontSize, $ApplyContentMarkingHeaderFontColor, $ApplyContentMarkingHeaderAlignment,
        $ApplyContentMarkingFooterEnabled, $ApplyContentMarkingFooterText, $ApplyContentMarkingFooterFontSize, $ApplyContentMarkingFooterFontColor, $ApplyContentMarkingFooterAlignment,
        $ApplyWaterMarkingEnabled, $ApplyWaterMarkingText, $ApplyWaterMarkingFontSize, $ApplyWaterMarkingFontColor, $ApplyWaterMarkingLayout,
        $SiteAndGroupProtectionEnabled, $SiteAndGroupProtectionPrivacy, $SiteAndGroupProtectionAllowAccessToGuestUsers, $SiteExternalSharingControlType,
        $SiteAndGroupProtectionAllowFullAccess, $SiteAndGroupProtectionAllowLimitedAccess, $SiteAndGroupProtectionBlockAccess)
    Write-MockCall 'Set-Label' $Identity
    $l = $global:MockTenant.Labels[$Identity]
    foreach ($p in 'DisplayName', 'Tooltip', 'Comment', 'ContentType') { if ($PSBoundParameters.ContainsKey($p)) { $l.$p = $PSBoundParameters[$p] } }
    if ($EncryptionEnabled) {
        $rights = if ($EncryptionRightsDefinitions) {
            @("$EncryptionRightsDefinitions" -split ';' | ForEach-Object { $i, $r = $_ -split ':', 2; @{ Identity = $i; Rights = $r } }) | ConvertTo-Json -Compress -AsArray
        }
        $s = @{ disabled = 'false'; protectiontype = "$EncryptionProtectionType".ToLower() }
        if ($rights) { $s.rightsdefinitions = $rights }
        if ($null -ne $EncryptionOfflineAccessDays) { $s.offlineaccessdays = $EncryptionOfflineAccessDays }
        if ($EncryptionContentExpiredOnDateInDaysOrNever) { $s.contentexpiredondateindaysornever = $EncryptionContentExpiredOnDateInDaysOrNever }
        foreach ($k in 'PromptUser', 'DoNotForward', 'EncryptOnly') { if ($PSBoundParameters["Encryption$k"]) { $s[$k.ToLower()] = 'true' } }
        $l.Actions.encrypt = New-MockAction 'encrypt' $null $s
    }
    foreach ($b in 'Header', 'Footer') {
        if ($PSBoundParameters["ApplyContentMarking${b}Enabled"]) {
            $l.Actions[$b] = New-MockAction 'applycontentmarking' $b.ToLower() @{
                disabled = 'false'; text = $PSBoundParameters["ApplyContentMarking${b}Text"]; fontsize = $PSBoundParameters["ApplyContentMarking${b}FontSize"]
                fontcolor = $PSBoundParameters["ApplyContentMarking${b}FontColor"]; alignment = $PSBoundParameters["ApplyContentMarking${b}Alignment"]; placement = $b
            }
        }
    }
    if ($ApplyWaterMarkingEnabled) {
        $l.Actions.watermark = New-MockAction 'applywatermarking' $null @{ disabled = 'false'; text = $ApplyWaterMarkingText; fontsize = $ApplyWaterMarkingFontSize; fontcolor = $ApplyWaterMarkingFontColor; layout = $ApplyWaterMarkingLayout }
    }
    if ($SiteAndGroupProtectionEnabled) {
        $l.Actions.group = New-MockAction 'protectgroup' $null @{ disabled = 'false'; privacy = $SiteAndGroupProtectionPrivacy; allowaccesstoguestusers = "$SiteAndGroupProtectionAllowAccessToGuestUsers".ToLower() }
        $l.Actions.site = New-MockAction 'protectsite' $null @{ disabled = 'false'; externalsharingcontroltype = $SiteExternalSharingControlType
            allowfullaccess = "$SiteAndGroupProtectionAllowFullAccess".ToLower(); allowlimitedaccess = "$SiteAndGroupProtectionAllowLimitedAccess".ToLower(); blockaccess = "$SiteAndGroupProtectionBlockAccess".ToLower() }
    }
    $l.LabelActions = @($l.Actions.Values)
}

function global:Get-LabelPolicy { [CmdletBinding()] param($Identity) $global:MockTenant.LabelPolicies[$Identity] }
function global:New-LabelPolicy { [CmdletBinding()] param($Name, $Labels, $ExchangeLocation)
    Write-MockCall 'New-LabelPolicy' $Name
    $global:MockTenant.LabelPolicies[$Name] = [pscustomobject]@{ Name = $Name; Labels = @($Labels); ExchangeLocation = @($ExchangeLocation | ForEach-Object { [pscustomobject]@{ Name = $_ } }); Settings = @() }
}
function global:Set-LabelPolicy { [CmdletBinding()] param($Identity, $AddLabels, $RemoveLabels, $AdvancedSettings, $AddExchangeLocation, $RemoveExchangeLocation)
    Write-MockCall 'Set-LabelPolicy' $Identity
    $p = $global:MockTenant.LabelPolicies[$Identity]
    if ($AddLabels) { $p.Labels = @($p.Labels) + $AddLabels }
    if ($RemoveLabels) { $p.Labels = @($p.Labels | Where-Object { $_ -notin $RemoveLabels }) }
    if ($AddExchangeLocation) { $p.ExchangeLocation = @($p.ExchangeLocation) + @($AddExchangeLocation | ForEach-Object { [pscustomobject]@{ Name = $_ } }) }
    if ($AdvancedSettings) {
        $t = @{}; foreach ($s in $p.Settings) { if ($s -match '^\[(.+?), (.*)\]$') { $t[$Matches[1]] = $Matches[2] } }
        foreach ($k in $AdvancedSettings.Keys) { $t[$k] = $AdvancedSettings[$k] }
        $p.Settings = @($t.GetEnumerator() | ForEach-Object { "[$($_.Key), $($_.Value)]" })
    }
}

function global:ConvertTo-MockLocation { param($Values) @($Values | ForEach-Object { [pscustomobject]@{ Name = $_; DisplayName = $_ } }) }
function global:Get-DlpCompliancePolicy { [CmdletBinding()] param($Identity) $global:MockTenant.Dlp[$Identity] }
function global:New-DlpCompliancePolicy { [CmdletBinding()] param($Name, $ExchangeLocation, $SharePointLocation, $OneDriveLocation, $TeamsLocation, $Mode, $Comment)
    Write-MockCall 'New-DlpCompliancePolicy' $Name
    $global:MockTenant.Dlp[$Name] = [pscustomobject]@{ Name = $Name; Mode = $Mode; Comment = $Comment
        ExchangeLocation = (ConvertTo-MockLocation $ExchangeLocation); SharePointLocation = (ConvertTo-MockLocation $SharePointLocation)
        OneDriveLocation = (ConvertTo-MockLocation $OneDriveLocation); TeamsLocation = (ConvertTo-MockLocation $TeamsLocation) }
}
function global:Set-DlpCompliancePolicy { [CmdletBinding()] param($Identity, $Mode, $Comment,
        $AddExchangeLocation, $RemoveExchangeLocation, $AddSharePointLocation, $RemoveSharePointLocation,
        $AddOneDriveLocation, $RemoveOneDriveLocation, $AddTeamsLocation, $RemoveTeamsLocation)
    Write-MockCall 'Set-DlpCompliancePolicy' $Identity
    $p = $global:MockTenant.Dlp[$Identity]
    if ($Mode) { $p.Mode = $Mode }
    if ($PSBoundParameters.ContainsKey('Comment')) { $p.Comment = $Comment }
    foreach ($w in 'Exchange', 'SharePoint', 'OneDrive', 'Teams') {
        $cur = @($p."${w}Location" | ForEach-Object Name)
        if ($PSBoundParameters["Add${w}Location"]) { $cur += $PSBoundParameters["Add${w}Location"] }
        if ($PSBoundParameters["Remove${w}Location"]) { $cur = @($cur | Where-Object { $_ -notin $PSBoundParameters["Remove${w}Location"] }) }
        $p."${w}Location" = ConvertTo-MockLocation $cur
    }
}
function global:Get-DlpComplianceRule { [CmdletBinding()] param($Identity, $Policy)
    if ($Identity) { $global:MockTenant.DlpRules[$Identity] } else { @($global:MockTenant.DlpRules.Values | Where-Object ParentPolicyName -eq $Policy) }
}
function global:ConvertTo-MockSit { param($Items)
    # The service fills in defaults you didn't set.
    @($Items | ForEach-Object { $h = @{ confidencelevel = 'Medium'; maxcount = '-1' }; foreach ($k in $_.Keys) { $h[$k.ToLower()] = "$($_[$k])" }; $h })
}
function global:New-DlpComplianceRule { [CmdletBinding()] param($Name, $Policy, $ContentContainsSensitiveInformation, $BlockAccess, $NotifyUser, $GenerateIncidentReport, $ReportSeverityLevel)
    Write-MockCall 'New-DlpComplianceRule' $Name
    $global:MockTenant.DlpRules[$Name] = [pscustomobject]@{ Name = $Name; ParentPolicyName = $Policy; BlockAccess = [bool]$BlockAccess
        NotifyUser = @($NotifyUser); GenerateIncidentReport = @($GenerateIncidentReport); ReportSeverityLevel = $ReportSeverityLevel
        ContentContainsSensitiveInformation = (ConvertTo-MockSit $ContentContainsSensitiveInformation) }
}
function global:Set-DlpComplianceRule { [CmdletBinding()] param($Identity, $ContentContainsSensitiveInformation, $BlockAccess, $NotifyUser, $GenerateIncidentReport, $ReportSeverityLevel)
    Write-MockCall 'Set-DlpComplianceRule' $Identity
    $r = $global:MockTenant.DlpRules[$Identity]
    if ($PSBoundParameters.ContainsKey('BlockAccess')) { $r.BlockAccess = [bool]$BlockAccess }
    if ($NotifyUser) { $r.NotifyUser = @($NotifyUser) }
    if ($GenerateIncidentReport) { $r.GenerateIncidentReport = @($GenerateIncidentReport) }
    if ($ReportSeverityLevel) { $r.ReportSeverityLevel = $ReportSeverityLevel }
    if ($ContentContainsSensitiveInformation) { $r.ContentContainsSensitiveInformation = ConvertTo-MockSit $ContentContainsSensitiveInformation }
}

function global:Get-ComplianceTag { [CmdletBinding()] param($Identity) $global:MockTenant.Tags[$Identity] }
function global:New-ComplianceTag { [CmdletBinding()] param($Name, $Comment, $RetentionDuration, $RetentionAction, $RetentionType, [switch]$IsRecordLabel)
    Write-MockCall 'New-ComplianceTag' $Name
    $global:MockTenant.Tags[$Name] = [pscustomobject]@{ Name = $Name; Comment = $Comment; RetentionDuration = $RetentionDuration; RetentionAction = $RetentionAction; RetentionType = $RetentionType; IsRecordLabel = [bool]$IsRecordLabel }
}
function global:Set-ComplianceTag { [CmdletBinding()] param($Identity, $Comment, $RetentionDuration)
    Write-MockCall 'Set-ComplianceTag' $Identity
    $t = $global:MockTenant.Tags[$Identity]
    if ($PSBoundParameters.ContainsKey('Comment')) { $t.Comment = $Comment }
    if ($RetentionDuration) { $t.RetentionDuration = $RetentionDuration }
}

function global:Get-RetentionCompliancePolicy { [CmdletBinding()] param($Identity) $global:MockTenant.RetPolicies[$Identity] }
function global:New-RetentionCompliancePolicy { [CmdletBinding()] param($Name, $Comment, $ExchangeLocation, $SharePointLocation, $OneDriveLocation, $ModernGroupLocation, $TeamsChannelLocation, $TeamsChatLocation)
    Write-MockCall 'New-RetentionCompliancePolicy' $Name
    $global:MockTenant.RetPolicies[$Name] = [pscustomobject]@{ Name = $Name; ExchangeLocation = (ConvertTo-MockLocation $ExchangeLocation); SharePointLocation = (ConvertTo-MockLocation $SharePointLocation)
        OneDriveLocation = (ConvertTo-MockLocation $OneDriveLocation); ModernGroupLocation = (ConvertTo-MockLocation $ModernGroupLocation)
        TeamsChannelLocation = (ConvertTo-MockLocation $TeamsChannelLocation); TeamsChatLocation = (ConvertTo-MockLocation $TeamsChatLocation) }
}
function global:Set-RetentionCompliancePolicy { [CmdletBinding()] param($Identity, $AddExchangeLocation, $RemoveExchangeLocation, $AddSharePointLocation, $RemoveSharePointLocation,
        $AddOneDriveLocation, $RemoveOneDriveLocation, $AddModernGroupLocation, $RemoveModernGroupLocation, $AddTeamsChannelLocation, $RemoveTeamsChannelLocation, $AddTeamsChatLocation, $RemoveTeamsChatLocation)
    Write-MockCall 'Set-RetentionCompliancePolicy' $Identity
}
function global:Get-RetentionComplianceRule { [CmdletBinding()] param($Identity, $Policy)
    if ($Identity) { $global:MockTenant.RetRules[$Identity] } else { @($global:MockTenant.RetRules.Values | Where-Object Policy -eq $Policy) }
}
function global:New-RetentionComplianceRule { [CmdletBinding()] param($Name, $Policy, $PublishComplianceTag, $RetentionDuration, $RetentionDurationDisplayHint, $RetentionComplianceAction, $ExpirationDateOption)
    Write-MockCall 'New-RetentionComplianceRule' "$Name$PublishComplianceTag"
    $key = if ($Name) { $Name } else { "$Policy-$PublishComplianceTag" }
    $global:MockTenant.RetRules[$key] = [pscustomobject]@{ Name = $key; Policy = $Policy; PublishComplianceTag = if ($PublishComplianceTag) { "00000000-0000-0000-0000-000000000000,$PublishComplianceTag" }
        RetentionDuration = $RetentionDuration; RetentionComplianceAction = $RetentionComplianceAction; ExpirationDateOption = $ExpirationDateOption }
}
function global:Set-RetentionComplianceRule { [CmdletBinding()] param($Identity, $RetentionDuration, $RetentionComplianceAction, $ExpirationDateOption)
    Write-MockCall 'Set-RetentionComplianceRule' $Identity
}
