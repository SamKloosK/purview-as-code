function Invoke-PurviewDeployment {
    <#
    .SYNOPSIS
    Compares a Purview config with the tenant and applies the differences.

    .DESCRIPTION
    Reads the tenant, compares every object in the config with what's there, and prints a plan:
    create, update (with the old and new value), no change, or drift (in the tenant but not in the
    config). Without -WhatIf it then applies the creates and updates. Nothing is ever deleted.

    Security & Compliance PowerShell ignores -WhatIf. Here -WhatIf stops before every change, so
    the plan is all that happens.

    .EXAMPLE
    Invoke-PurviewDeployment -ConfigFile .\configs\contoso.json -WhatIf

    .EXAMPLE
    Invoke-PurviewDeployment -ConfigFile .\configs\contoso.json -PlanFile .\plan.md -PassThru

    .EXAMPLE
    Invoke-PurviewDeployment -ConfigFile .\configs\contoso.json -AppId $appId -CertificateThumbprint $thumb
    #>
    [CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Interactive')]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigFile,

        [Parameter(ParameterSetName = 'Interactive')]
        [string]$UserPrincipalName,

        [Parameter(Mandatory, ParameterSetName = 'AppOnly')]
        [string]$AppId,

        [Parameter(Mandatory, ParameterSetName = 'AppOnly')]
        [string]$CertificateThumbprint,

        # Use the Security & Compliance session you already have instead of connecting.
        [Parameter(Mandatory, ParameterSetName = 'ExistingSession')]
        [switch]$UseExistingSession,

        # Remove labels from label policies and locations from policies when they're not in the
        # config. Without it, those show up as drift and are left alone.
        [switch]$AllowRemoval,

        # Write the plan as a Markdown table, for a change request or a pipeline summary.
        [string]$PlanFile,

        [switch]$PassThru,

        # Only for testing without a tenant.
        [Parameter(DontShow)]
        [switch]$SkipTenantCheck
    )

    $config = Read-PurviewConfig -Path $ConfigFile
    $check = Get-ConfigProblems -Config $config
    foreach ($w in $check.Warnings) { Write-Warning $w }
    if ($check.Errors) {
        $check.Errors | ForEach-Object { Write-Host "  config error: $_" -ForegroundColor Red }
        throw "The config has $($check.Errors.Count) error(s). Nothing was changed."
    }

    $connected = $false
    if ($PSCmdlet.ParameterSetName -ne 'ExistingSession') {
        Connect-PurviewSession -TenantDomain $config.TenantDomain -UserPrincipalName $UserPrincipalName -AppId $AppId -CertificateThumbprint $CertificateThumbprint
        $connected = $true
    }

    try {
        if (-not $SkipTenantCheck) { Assert-PurviewTenant -TenantDomain $config.TenantDomain -TenantId $config.TenantId }

        Reset-Plan
        $mode = if ($WhatIfPreference) { 'plan only (WhatIf)' } else { 'plan and apply' }
        Write-Host "$($config.ClientName): $mode"

        if ($config.SensitivityLabels)      { Sync-SensitivityLabels -Labels $config.SensitivityLabels }
        if ($config.LabelPolicies)          { Sync-LabelPolicies -Policies $config.LabelPolicies -AllowRemoval:$AllowRemoval }
        if ($config.DlpPolicies)            { Sync-DlpPolicies -Policies $config.DlpPolicies -AllowRemoval:$AllowRemoval }
        if ($config.RetentionLabels)        { Sync-RetentionLabels -Labels $config.RetentionLabels }
        if ($config.RetentionLabelPolicies) { Sync-RetentionLabelPolicies -Policies $config.RetentionLabelPolicies -AllowRemoval:$AllowRemoval }
        if ($config.RetentionPolicies)      { Sync-RetentionPolicies -Policies $config.RetentionPolicies -AllowRemoval:$AllowRemoval }

        $plan = Get-Plan
        Write-PlanSummary -Items $plan -WhatIf $WhatIfPreference
        if ($PlanFile) {
            $title = "Purview plan for $($config.ClientName), $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
            Export-PlanMarkdown -Items $plan -Path $PlanFile -Title $title
        }
        if ($PassThru) { $plan }

        $failed = @($plan | Where-Object Status -eq 'Failed')
        if ($failed) {
            throw "$($failed.Count) change(s) failed: $(($failed | ForEach-Object { "$($_.Area) '$($_.Name)'" }) -join ', ')"
        }
    }
    finally {
        if ($connected) { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue }
    }
}
