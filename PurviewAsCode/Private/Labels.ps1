# Sensitivity labels and label policies.
#
# Get-Label doesn't return encryption and marking settings as properties. They're in LabelActions,
# a list of JSON strings like {"Type":"applywatermarking","Settings":[{"Key":"text","Value":"..."}]}.
# The map below says where each config setting lives in there. Key names that I haven't been able
# to confirm in a tenant have more than one candidate; when none of them is found, the plan says
# "not readable" and the setting is sent again, so a wrong guess costs a write, not a wrong state.
# Get-PurviewLabelState shows the raw LabelActions of your own labels if you need to check.

$script:LabelSettingMap = @(
    # Block, config key, Set-Label parameter, action, candidate keys in LabelActions
    ,@('Encryption', 'ProtectionType',                              'EncryptionProtectionType',                    'encrypt',   @('protectiontype'))
    ,@('Encryption', 'EncryptionRightsDefinitions',                 'EncryptionRightsDefinitions',                 'encrypt',   @('rightsdefinitions'))
    ,@('Encryption', 'EncryptionOfflineAccessDays',                 'EncryptionOfflineAccessDays',                 'encrypt',   @('offlineaccessdays', 'offline'))
    ,@('Encryption', 'EncryptionContentExpiredOnDateInDaysOrNever', 'EncryptionContentExpiredOnDateInDaysOrNever', 'encrypt',   @('contentexpiredondateindaysornever'))
    ,@('Encryption', 'PromptUser',                                  'EncryptionPromptUser',                        'encrypt',   @('promptuser'))
    ,@('Encryption', 'DoNotForward',                                'EncryptionDoNotForward',                      'encrypt',   @('donotforward'))
    ,@('Encryption', 'EncryptOnly',                                 'EncryptionEncryptOnly',                       'encrypt',   @('encryptonly'))
    ,@('Header',     'Text',      'ApplyContentMarkingHeaderText',      'header',    @('text'))
    ,@('Header',     'FontSize',  'ApplyContentMarkingHeaderFontSize',  'header',    @('fontsize'))
    ,@('Header',     'FontColor', 'ApplyContentMarkingHeaderFontColor', 'header',    @('fontcolor'))
    ,@('Header',     'Alignment', 'ApplyContentMarkingHeaderAlignment', 'header',    @('alignment'))
    ,@('Footer',     'Text',      'ApplyContentMarkingFooterText',      'footer',    @('text'))
    ,@('Footer',     'FontSize',  'ApplyContentMarkingFooterFontSize',  'footer',    @('fontsize'))
    ,@('Footer',     'FontColor', 'ApplyContentMarkingFooterFontColor', 'footer',    @('fontcolor'))
    ,@('Footer',     'Alignment', 'ApplyContentMarkingFooterAlignment', 'footer',    @('alignment'))
    ,@('Watermark',  'Text',      'ApplyWaterMarkingText',              'watermark', @('text'))
    ,@('Watermark',  'FontSize',  'ApplyWaterMarkingFontSize',          'watermark', @('fontsize'))
    ,@('Watermark',  'FontColor', 'ApplyWaterMarkingFontColor',         'watermark', @('fontcolor'))
    ,@('Watermark',  'Layout',    'ApplyWaterMarkingLayout',            'watermark', @('layout'))
    ,@('SiteAndGroupProtection', 'Privacy',                 'SiteAndGroupProtectionPrivacy',                 'group', @('privacy'))
    ,@('SiteAndGroupProtection', 'AllowAccessToGuestUsers', 'SiteAndGroupProtectionAllowAccessToGuestUsers', 'group', @('allowaccesstoguestusers'))
    ,@('SiteAndGroupProtection', 'ExternalSharing',         'SiteExternalSharingControlType',                'site',  @('externalsharingcontroltype'))
) | ForEach-Object { [pscustomobject]@{ Block = $_[0]; ConfigKey = $_[1]; Param = $_[2]; Action = $_[3]; Keys = $_[4] } }

# The switch that turns each block on in Set-Label.
$script:BlockEnableParam = @{
    Encryption             = 'EncryptionEnabled'
    Header                 = 'ApplyContentMarkingHeaderEnabled'
    Footer                 = 'ApplyContentMarkingFooterEnabled'
    Watermark              = 'ApplyWaterMarkingEnabled'
    SiteAndGroupProtection = 'SiteAndGroupProtectionEnabled'
}

function Get-LabelActionTable {
    param($Label)
    $table = @{}
    foreach ($raw in @($Label.LabelActions)) {
        if (-not $raw) { continue }
        try { $a = $raw | ConvertFrom-Json } catch { continue }
        $settings = @{}
        foreach ($s in @($a.Settings)) { if ($s.Key) { $settings[$s.Key.ToLowerInvariant()] = $s.Value } }
        $type = "$($a.Type)".ToLowerInvariant()
        $sub = "$($a.SubType)".ToLowerInvariant()
        $kind = switch -Regex ($type) {
            '^encrypt'            { 'encrypt' }
            '^applywatermarking'  { 'watermark' }
            '^applycontentmarking' {
                if ($sub -eq 'footer' -or $settings['placement'] -eq 'footer') { 'footer' } else { 'header' }
            }
            '^protectgroup'       { 'group' }
            '^protectsite'        { 'site' }
            default               { $type }
        }
        $table[$kind] = $settings
    }
    $table
}

function Test-ActionEnabled {
    param([hashtable]$Settings)
    $Settings -and "$($Settings['disabled'])" -ne 'true'
}

# "contoso.com:VIEW,EDIT;bob@contoso.com:VIEW" and the JSON form Purview stores become the same string.
function ConvertTo-RightsKey {
    param($Value)
    if (-not $Value) { return '' }
    $pairs = if ("$Value".TrimStart().StartsWith('[')) {
        @("$Value" | ConvertFrom-Json) | ForEach-Object { "$($_.Identity):$($_.Rights)" }
    }
    else { "$Value" -split ';' }
    @($pairs | Where-Object { $_ } | ForEach-Object {
        $id, $rights = $_ -split ':', 2
        "{0}:{1}" -f $id.Trim().ToLowerInvariant(), ((($rights -split ',') | ForEach-Object { $_.Trim().ToUpperInvariant() } | Sort-Object) -join ',')
    } | Sort-Object) -join ';'
}

# Desired Set-Label parameters per block, from the config.
function Get-DesiredLabelBlocks {
    param([hashtable]$LabelConfig)
    $blocks = [ordered]@{}
    if ($LabelConfig.Encryption) { $blocks.Encryption = $LabelConfig.Encryption }
    if ($LabelConfig.ContentMarking) {
        foreach ($b in 'Header', 'Footer', 'Watermark') {
            if ($LabelConfig.ContentMarking[$b]) { $blocks[$b] = $LabelConfig.ContentMarking[$b] }
        }
    }
    if ($LabelConfig.SiteAndGroupProtection) { $blocks.SiteAndGroupProtection = $LabelConfig.SiteAndGroupProtection }
    $blocks
}

function Get-BlockSetLabelParams {
    param([string]$Block, [hashtable]$Values)
    $p = @{ $script:BlockEnableParam[$Block] = $true }
    foreach ($m in $script:LabelSettingMap | Where-Object Block -eq $Block) {
        if ($null -ne $Values[$m.ConfigKey]) { $p[$m.Param] = $Values[$m.ConfigKey] }
    }
    if ($Block -eq 'SiteAndGroupProtection' -and $Values.UnmanagedDevices) {
        # Send all three, otherwise switching from one to another leaves the old one set.
        $p.SiteAndGroupProtectionAllowFullAccess    = $Values.UnmanagedDevices -eq 'FullAccess'
        $p.SiteAndGroupProtectionAllowLimitedAccess = $Values.UnmanagedDevices -eq 'LimitedAccess'
        $p.SiteAndGroupProtectionBlockAccess        = $Values.UnmanagedDevices -eq 'BlockAccess'
    }
    $p
}

# Compares one label with the tenant. Returns the blocks that differ and readable change lines.
function Compare-LabelSettings {
    param([hashtable]$LabelConfig, $ExistingLabel)

    $details = [System.Collections.Generic.List[string]]::new()
    $changedBlocks = [System.Collections.Generic.List[string]]::new()
    $basic = @{}

    foreach ($prop in 'DisplayName', 'Tooltip', 'Comment') {
        if ($null -ne $LabelConfig[$prop] -and (ConvertTo-Comparable $LabelConfig[$prop]) -ne (ConvertTo-Comparable $ExistingLabel.$prop)) {
            $basic[$prop] = $LabelConfig[$prop]
            $details.Add("${prop}: $(Format-Value $ExistingLabel.$prop) -> $(Format-Value $LabelConfig[$prop])")
        }
    }
    if ($LabelConfig.Scope -and -not $LabelConfig.IsLabelGroup) {
        $cur = Compare-NameSet -Current ("$($ExistingLabel.ContentType)" -split ',\s*') -Desired ("$($LabelConfig.Scope)" -split ',\s*')
        if ($cur.Add.Count -or $cur.Remove.Count) {
            $basic.ContentType = $LabelConfig.Scope
            $details.Add("Scope: $(Format-Value $ExistingLabel.ContentType) -> $(Format-Value $LabelConfig.Scope)")
        }
    }

    $actions = Get-LabelActionTable $ExistingLabel
    $desired = Get-DesiredLabelBlocks $LabelConfig
    $drift = [System.Collections.Generic.List[string]]::new()

    foreach ($block in $desired.Keys) {
        $values = $desired[$block]
        $entries = @($script:LabelSettingMap | Where-Object { $_.Block -eq $block -and $null -ne $values[$_.ConfigKey] })
        $actionKind = if ($entries) { $entries[0].Action } else { @{ Encryption = 'encrypt'; Header = 'header'; Footer = 'footer'; Watermark = 'watermark'; SiteAndGroupProtection = 'group' }[$block] }
        $blockChanged = $false

        if (-not (Test-ActionEnabled $actions[$actionKind])) {
            $details.Add("${block}: off -> on")
            $blockChanged = $true
        }
        else {
            foreach ($m in $entries) {
                $current = $actions[$m.Action]
                $key = $m.Keys | Where-Object { $current -and $current.ContainsKey($_) } | Select-Object -First 1
                $label = if ($m.ConfigKey -like "$block*" -or $m.ConfigKey -like 'Encryption*') { $m.ConfigKey } else { "$block $($m.ConfigKey)" }
                if (-not $key) {
                    $details.Add("${label}: current value not readable, setting $(Format-Value $values[$m.ConfigKey])")
                    $blockChanged = $true
                    continue
                }
                $isRights = $m.ConfigKey -eq 'EncryptionRightsDefinitions'
                $a = if ($isRights) { ConvertTo-RightsKey $current[$key] } else { ConvertTo-Comparable $current[$key] }
                $b = if ($isRights) { ConvertTo-RightsKey $values[$m.ConfigKey] } else { ConvertTo-Comparable $values[$m.ConfigKey] }
                if ($a -ne $b) {
                    $details.Add("${label}: $(Format-Value $current[$key]) -> $(Format-Value $values[$m.ConfigKey])")
                    $blockChanged = $true
                }
            }
            if ($block -eq 'SiteAndGroupProtection' -and $values.UnmanagedDevices) {
                $site = $actions['site']
                $currentMode = if (-not $site) { '' }
                    elseif ("$($site['blockaccess'])" -eq 'true') { 'BlockAccess' }
                    elseif ("$($site['allowlimitedaccess'])" -eq 'true') { 'LimitedAccess' }
                    elseif ("$($site['allowfullaccess'])" -eq 'true') { 'FullAccess' }
                    else { '' }
                if ($currentMode -ne $values.UnmanagedDevices) {
                    $details.Add("UnmanagedDevices: $(Format-Value $currentMode) -> '$($values.UnmanagedDevices)'")
                    $blockChanged = $true
                }
            }
        }
        if ($blockChanged) { $changedBlocks.Add($block) }
    }

    # Settings that are on in the tenant but not in the config. Left alone: this project doesn't
    # remove things, but it does tell you.
    $kindToBlock = @{ encrypt = 'Encryption'; header = 'Header'; footer = 'Footer'; watermark = 'Watermark'; group = 'SiteAndGroupProtection' }
    foreach ($kind in $kindToBlock.Keys) {
        if ((Test-ActionEnabled $actions[$kind]) -and -not $desired.Contains($kindToBlock[$kind])) {
            $drift.Add("$($kindToBlock[$kind]) is on in the tenant but not in the config (left as is)")
        }
    }

    @{ Basic = $basic; ChangedBlocks = $changedBlocks; Details = $details; Drift = $drift }
}

function Sync-SensitivityLabels {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][array]$Labels)

    Write-Host "`nSensitivity labels" -ForegroundColor Cyan
    $tenantLabels = @{}
    foreach ($l in @(Get-Label -ErrorAction SilentlyContinue)) { if ($l) { $tenantLabels[$l.Name] = $l } }
    $configured = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($label in $Labels) {
        Sync-SingleLabel -LabelConfig $label -ParentName $null -TenantLabels $tenantLabels -Configured $configured
    }

    foreach ($name in $tenantLabels.Keys | Sort-Object) {
        if (-not $configured.Contains($name)) {
            $null = Add-PlanItem -Area 'Sensitivity label' -Name $name -Action Drift -Details 'in the tenant, not in the config (left as is)'
        }
    }
}

function Sync-SingleLabel {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$LabelConfig, [string]$ParentName, [hashtable]$TenantLabels, $Configured)

    $name = $LabelConfig.Name
    $null = $Configured.Add($name)
    $isGroup = [bool]$LabelConfig.IsLabelGroup
    $area = if ($isGroup) { 'Label group' } else { 'Sensitivity label' }
    $existing = $TenantLabels[$name]

    if (-not $existing) {
        $details = @()
        if ($ParentName) { $details += "in: $ParentName" }
        $details += @((Get-DesiredLabelBlocks $LabelConfig).Keys)
        $item = Add-PlanItem -Area $area -Name $name -Action Create -Details $details
        $null = Invoke-PlanItem -Item $item -Change {
            $new = @{ Name = $name; DisplayName = $LabelConfig.DisplayName; Tooltip = $LabelConfig.Tooltip }
            if ($LabelConfig.Comment) { $new.Comment = $LabelConfig.Comment }
            if ($isGroup) { $new.IsLabelGroup = $true }
            elseif ($LabelConfig.Scope) { $new.ContentType = $LabelConfig.Scope }
            if ($ParentName) { $new.ParentId = (Get-Label -Identity $ParentName -ErrorAction Stop).Guid }
            $null = New-Label @new -ErrorAction Stop

            # Settings go in a second step with Set-Label. New-Label takes them too, but this way
            # create and update use the same code path.
            $set = @{}
            $blocks = Get-DesiredLabelBlocks $LabelConfig
            foreach ($b in $blocks.Keys) { $set += Get-BlockSetLabelParams -Block $b -Values $blocks[$b] }
            if ($set.Count) { Set-Label -Identity $name @set -ErrorAction Stop }
        }
    }
    else {
        $cmp = Compare-LabelSettings -LabelConfig $LabelConfig -ExistingLabel $existing
        if ($cmp.Details.Count) {
            $item = Add-PlanItem -Area $area -Name $name -Action Update -Details $cmp.Details
            $null = Invoke-PlanItem -Item $item -Change {
                $set = $cmp.Basic.Clone()
                $blocks = Get-DesiredLabelBlocks $LabelConfig
                foreach ($b in $cmp.ChangedBlocks) { $set += Get-BlockSetLabelParams -Block $b -Values $blocks[$b] }
                Set-Label -Identity $name @set -ErrorAction Stop
            }
        }
        else {
            $null = Add-PlanItem -Area $area -Name $name -Action NoChange
        }
        if ($cmp.Drift.Count) {
            $null = Add-PlanItem -Area $area -Name $name -Action Drift -Details $cmp.Drift
        }
    }

    foreach ($sub in @($LabelConfig.SubLabels)) {
        if ($sub) { Sync-SingleLabel -LabelConfig $sub -ParentName $name -TenantLabels $TenantLabels -Configured $Configured }
    }
}

# Label policy settings come back as strings like "[defaultlabelid, 1b2c...]".
function ConvertFrom-PolicySettings {
    param($Settings)
    $table = @{}
    foreach ($s in @($Settings)) {
        if ("$s" -match '^\[\s*([^,]+?)\s*,\s*(.*?)\s*\]$') { $table[$Matches[1].ToLowerInvariant()] = $Matches[2] }
    }
    $table
}

function Resolve-LabelReference {
    param([string]$Value)
    if ($Value -match '^[0-9a-fA-F-]{36}$') { return $Value }
    $label = Get-Label -Identity $Value -ErrorAction SilentlyContinue
    if ($label) { return "$($label.Guid)" }
    $null
}

function Sync-LabelPolicies {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][array]$Policies, [switch]$AllowRemoval)

    Write-Host "`nLabel policies" -ForegroundColor Cyan
    $nameByGuid = @{}
    foreach ($l in @(Get-Label -ErrorAction SilentlyContinue)) { if ($l) { $nameByGuid["$($l.Guid)"] = $l.Name } }

    foreach ($policy in $Policies) {
        $name = $policy.Name
        $existing = Get-LabelPolicy -Identity $name -ErrorAction SilentlyContinue

        # defaultlabelid can be a label name in the config; it's resolved to the GUID here.
        $desiredSettings = @{}
        $unresolved = @()
        foreach ($k in @($policy.Settings.Keys)) {
            $v = "$($policy.Settings[$k])"
            if ($k -eq 'defaultlabelid') {
                $resolved = Resolve-LabelReference $v
                if ($resolved) { $v = $resolved } else { $unresolved += $k; continue }
            }
            $desiredSettings[$k.ToLowerInvariant()] = $v
        }

        if (-not $existing) {
            $details = @("labels: $($policy.Labels -join ', ')")
            if ($unresolved) { $details += "defaultlabelid: label '$($policy.Settings.defaultlabelid)' doesn't exist yet, run again after it's created" }
            $item = Add-PlanItem -Area 'Label policy' -Name $name -Action Create -Details $details
            $null = Invoke-PlanItem -Item $item -Change {
                $new = @{ Name = $name; Labels = $policy.Labels }
                if ($policy.ExchangeLocation) { $new.ExchangeLocation = $policy.ExchangeLocation }
                $null = New-LabelPolicy @new -ErrorAction Stop
                if ($desiredSettings.Count) { Set-LabelPolicy -Identity $name -AdvancedSettings $desiredSettings -ErrorAction Stop }
            }
            continue
        }

        $details = @(); $drift = @(); $set = @{}

        $currentLabels = @($existing.Labels | ForEach-Object { if ($nameByGuid["$_"]) { $nameByGuid["$_"] } else { "$_" } })
        $diff = Compare-NameSet -Current $currentLabels -Desired $policy.Labels
        if ($diff.Add.Count) { $set.AddLabels = $diff.Add; $details += "add labels: $($diff.Add -join ', ')" }
        if ($diff.Remove.Count) {
            if ($AllowRemoval) { $set.RemoveLabels = $diff.Remove; $details += "remove labels: $($diff.Remove -join ', ')" }
            else { $drift += "published but not in the config: $($diff.Remove -join ', ') (use -AllowRemoval to remove)" }
        }

        if ($policy.ExchangeLocation) {
            $loc = Compare-NameSet -Current (Get-LocationName $existing.ExchangeLocation) -Desired $policy.ExchangeLocation
            if ($loc.Add.Count) { $set.AddExchangeLocation = $loc.Add; $details += "add Exchange location: $($loc.Add -join ', ')" }
            if ($loc.Remove.Count) {
                if ($AllowRemoval) { $set.RemoveExchangeLocation = $loc.Remove; $details += "remove Exchange location: $($loc.Remove -join ', ')" }
                else { $drift += "Exchange location not in the config: $($loc.Remove -join ', ')" }
            }
        }

        $current = ConvertFrom-PolicySettings $existing.Settings
        $changedSettings = @{}
        foreach ($k in $desiredSettings.Keys) {
            if ((ConvertTo-Comparable $current[$k]) -ne (ConvertTo-Comparable $desiredSettings[$k])) {
                $changedSettings[$k] = $desiredSettings[$k]
                $details += "${k}: $(Format-Value $current[$k]) -> $(Format-Value $desiredSettings[$k])"
            }
        }
        foreach ($k in $unresolved) { $details += "${k}: label '$($policy.Settings[$k])' not found, setting skipped" }

        if ($set.Count -or $changedSettings.Count) {
            $item = Add-PlanItem -Area 'Label policy' -Name $name -Action Update -Details $details
            $null = Invoke-PlanItem -Item $item -Change {
                if ($set.Count) { Set-LabelPolicy -Identity $name @set -ErrorAction Stop }
                if ($changedSettings.Count) { Set-LabelPolicy -Identity $name -AdvancedSettings $changedSettings -ErrorAction Stop }
            }
        }
        else {
            $null = Add-PlanItem -Area 'Label policy' -Name $name -Action NoChange -Details $details
        }
        if ($drift) { $null = Add-PlanItem -Area 'Label policy' -Name $name -Action Drift -Details $drift }
    }
}
