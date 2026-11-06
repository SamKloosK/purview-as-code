# Deploy-PurviewConfig.ps1
# Main deployment script: reads a tenant config and applies it to the target tenant
#
# -WhatIf is handled by this project (ShouldProcess), not by Security & Compliance PowerShell,
# which ignores -WhatIf. It is passed explicitly to every module function, because preference
# variables like $WhatIfPreference do not flow from a script into script modules.

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigFile,

    [Parameter(Mandatory = $false)]
    [string]$AdminUpn,

    [Parameter(Mandatory = $false)]
    [switch]$SkipConnection
)

$ErrorActionPreference = "Stop"

# Import modules
$modulePath = Join-Path $PSScriptRoot "..\modules"
Import-Module (Join-Path $modulePath "PurviewConnection.psm1") -Force
Import-Module (Join-Path $modulePath "PurviewLabels.psm1") -Force
Import-Module (Join-Path $modulePath "PurviewDLP.psm1") -Force
Import-Module (Join-Path $modulePath "PurviewRetention.psm1") -Force

# Load and validate config
if (-not (Test-Path $ConfigFile)) {
    throw "Config file not found: $ConfigFile"
}

Write-Host "Loading configuration from: $ConfigFile" -ForegroundColor Cyan
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json -AsHashtable

# Validate required fields
if (-not $config.TenantDomain) {
    throw "Config is missing required field: TenantDomain"
}

Write-Host "Target tenant: $($config.TenantDomain)" -ForegroundColor Cyan
Write-Host "Client: $($config.ClientName)" -ForegroundColor Cyan

if ($WhatIfPreference) {
    Write-Host "`n>>> RUNNING IN WHATIF MODE - NO CHANGES WILL BE MADE <<<`n" -ForegroundColor Magenta
}

# Connect to tenant
if (-not $SkipConnection) {
    $connectParams = @{
        TenantDomain = $config.TenantDomain
    }
    if ($AdminUpn) {
        $connectParams.AdminUpn = $AdminUpn
    }
    Connect-PurviewTenant @connectParams
}

try {
    # Deploy sensitivity labels
    if ($config.SensitivityLabels) {
        Deploy-SensitivityLabels -Labels $config.SensitivityLabels -WhatIf:$WhatIfPreference
    }

    # Deploy label policies
    if ($config.LabelPolicies) {
        Deploy-LabelPolicy -Policies $config.LabelPolicies -WhatIf:$WhatIfPreference
    }

    # Deploy DLP policies
    if ($config.DlpPolicies) {
        Deploy-DlpPolicies -Policies $config.DlpPolicies -WhatIf:$WhatIfPreference
    }

    # Deploy retention labels
    if ($config.RetentionLabels) {
        Deploy-RetentionLabels -Labels $config.RetentionLabels -WhatIf:$WhatIfPreference
    }

    # Publish retention labels to locations
    if ($config.RetentionLabelPolicies) {
        Deploy-RetentionLabelPolicies -Policies $config.RetentionLabelPolicies -WhatIf:$WhatIfPreference
    }

    # Deploy retention policies
    if ($config.RetentionPolicies) {
        Deploy-RetentionPolicies -Policies $config.RetentionPolicies -WhatIf:$WhatIfPreference
    }

    Write-Host "`n=== Deployment Complete ===" -ForegroundColor Green
}
catch {
    Write-Host "`n=== Deployment Failed ===" -ForegroundColor Red
    Write-Error $_
}
finally {
    if (-not $SkipConnection) {
        Disconnect-PurviewTenant
    }
}
