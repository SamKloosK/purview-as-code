function Export-PurviewConfig {
    <#
    .SYNOPSIS
    Writes the tenant's labels, policies and retention settings to a config file as a starting point.

    .DESCRIPTION
    Reads the current Security & Compliance session. Labels are nested under their parent, and
    header, footer, watermark and the encryption protection type are read from LabelActions.
    Not exported yet: encryption rights, container settings, DLP rule conditions and retention
    rules. Run Invoke-PurviewDeployment -WhatIf on the result to see what still differs.

    .EXAMPLE
    Connect-IPPSSession
    Export-PurviewConfig -Path .\exports\contoso.json -ClientName Contoso -TenantDomain contoso.onmicrosoft.com
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ClientName,
        [Parameter(Mandatory)][string]$TenantDomain
    )

    $all = @(Get-Label)
    $byGuid = @{}
    foreach ($l in $all) { $byGuid["$($l.Guid)"] = $l }

    $toConfig = {
        param($l)
        $c = [ordered]@{ Name = $l.Name; DisplayName = $l.DisplayName }
        if ($l.Tooltip) { $c.Tooltip = $l.Tooltip }
        if ($l.Comment) { $c.Comment = $l.Comment }
        if ($l.ContentType) { $c.Scope = "$($l.ContentType)" }

        $actions = Get-LabelActionTable $l
        if (Test-ActionEnabled $actions['encrypt']) {
            $pt = $actions['encrypt']['protectiontype']
            $c.Encryption = [ordered]@{ ProtectionType = if ($pt -match 'user') { 'UserDefined' } else { 'Template' } }
        }
        $marking = [ordered]@{}
        foreach ($b in 'Header', 'Footer', 'Watermark') {
            $s = $actions[$b.ToLowerInvariant()]
            if (-not (Test-ActionEnabled $s)) { continue }
            $block = [ordered]@{}
            foreach ($m in $script:LabelSettingMap | Where-Object Block -eq $b) {
                $key = $m.Keys | Where-Object { $s.ContainsKey($_) } | Select-Object -First 1
                if ($key) { $block[$m.ConfigKey] = $s[$key] }
            }
            $marking[$b] = $block
        }
        if ($marking.Count) { $c.ContentMarking = $marking }
        $c
    }

    $children = @{}
    foreach ($l in $all) {
        $p = "$($l.ParentId)"
        if ($p -and $byGuid[$p]) { if (-not $children[$p]) { $children[$p] = @() }; $children[$p] += $l }
    }
    $top = $all | Where-Object { -not ("$($_.ParentId)" -and $byGuid["$($_.ParentId)"]) } | Sort-Object Priority
    $labels = foreach ($l in $top) {
        $c = & $toConfig $l
        $subs = @($children["$($l.Guid)"] | Sort-Object Priority | ForEach-Object { & $toConfig $_ })
        if ($subs) { $c.SubLabels = $subs }
        $c
    }

    $policies = foreach ($p in @(Get-LabelPolicy)) {
        $c = [ordered]@{
            Name   = $p.Name
            Labels = @($p.Labels | ForEach-Object { if ($byGuid["$_"]) { $byGuid["$_"].Name } else { "$_" } })
        }
        $loc = Get-LocationName $p.ExchangeLocation
        if ($loc) { $c.ExchangeLocation = $loc }
        $settings = ConvertFrom-PolicySettings $p.Settings
        if ($settings.Count) { $c.Settings = $settings }
        $c
    }

    $dlp = foreach ($p in @(Get-DlpCompliancePolicy)) {
        $c = [ordered]@{ Name = $p.Name; Mode = "$($p.Mode)" }
        foreach ($w in 'Exchange', 'SharePoint', 'OneDrive', 'Teams') {
            $loc = Get-LocationName $p."${w}Location"
            if ($loc) { $c["${w}Location"] = $loc }
        }
        $c.Rules = @(Get-DlpComplianceRule -Policy $p.Name -ErrorAction SilentlyContinue | ForEach-Object {
            [ordered]@{ Name = $_.Name; BlockAccess = [bool]$_.BlockAccess; ReportSeverityLevel = "$($_.ReportSeverityLevel)" }
        })
        $c
    }

    $config = [ordered]@{
        '$schema'         = '../schema/purview-config.schema.json'
        ClientName        = $ClientName
        TenantDomain      = $TenantDomain
        SensitivityLabels = @($labels)
        LabelPolicies     = @($policies)
        DlpPolicies       = @($dlp)
    }
    $config | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding utf8
    Write-Host "Exported to $Path. Review it, then run Invoke-PurviewDeployment -WhatIf to see what still differs."
}
