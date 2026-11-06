# Export-PurviewConfig.ps1
# Exports the current Purview configuration from a tenant to a JSON config file
# Useful for onboarding existing tenants or creating a baseline

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [Parameter(Mandatory = $true)]
    [string]$ClientName,

    [Parameter(Mandatory = $true)]
    [string]$TenantDomain,

    [Parameter(Mandatory = $false)]
    [string]$AdminUpn,

    [Parameter(Mandatory = $false)]
    [switch]$SkipConnection
)

$ErrorActionPreference = "Stop"

# Import connection module
$modulePath = Join-Path $PSScriptRoot "..\modules"
Import-Module (Join-Path $modulePath "PurviewConnection.psm1") -Force

if (-not $SkipConnection) {
    $connectParams = @{ TenantDomain = $TenantDomain }
    if ($AdminUpn) { $connectParams.AdminUpn = $AdminUpn }
    Connect-PurviewTenant @connectParams
}

try {
    $config = @{
        ClientName   = $ClientName
        TenantDomain = $TenantDomain
        ExportedAt   = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }

    # Export sensitivity labels
    Write-Host "Exporting sensitivity labels..." -ForegroundColor Cyan
    $labels = Get-Label | ForEach-Object {
        $label = @{
            Name        = $_.Name
            DisplayName = $_.DisplayName
            Tooltip     = $_.Tooltip
            Comment     = $_.Comment
            Priority    = $_.Priority
            ParentId    = $_.ParentId
        }

        if ($_.EncryptionEnabled) {
            $label.Encryption = @{
                ProtectionType = $_.EncryptionProtectionType
            }
        }

        if ($_.HeaderEnabled) {
            $label.ContentMarking = @{}
            $label.ContentMarking.Header = @{
                Text      = $_.HeaderText
                FontSize  = $_.HeaderFontSize
                FontColor = $_.HeaderFontColor
                Alignment = $_.HeaderAlignment
            }
        }

        $label
    }
    $config.SensitivityLabels = @($labels)

    # Export label policies
    Write-Host "Exporting label policies..." -ForegroundColor Cyan
    $policies = Get-LabelPolicy | ForEach-Object {
        @{
            Name   = $_.Name
            Labels = @($_.Labels)
        }
    }
    $config.LabelPolicies = @($policies)

    # Export DLP policies
    Write-Host "Exporting DLP policies..." -ForegroundColor Cyan
    $dlpPolicies = Get-DlpCompliancePolicy | ForEach-Object {
        $policy = @{
            Name              = $_.Name
            Mode              = $_.Mode
            ExchangeLocation  = @($_.ExchangeLocation)
            SharePointLocation = @($_.SharePointLocation)
            OneDriveLocation  = @($_.OneDriveLocation)
            TeamsLocation     = @($_.TeamsLocation)
        }

        # Get rules for this policy
        $rules = Get-DlpComplianceRule -Policy $_.Name -ErrorAction SilentlyContinue | ForEach-Object {
            @{
                Name            = $_.Name
                BlockAccess     = $_.BlockAccess
                NotifyUser      = $_.NotifyUser
                ReportSeverityLevel = $_.ReportSeverityLevel
            }
        }
        $policy.Rules = @($rules)
        $policy
    }
    $config.DlpPolicies = @($dlpPolicies)

    # Export retention policies
    Write-Host "Exporting retention policies..." -ForegroundColor Cyan
    $retPolicies = Get-RetentionCompliancePolicy | ForEach-Object {
        @{
            Name                 = $_.Name
            ExchangeLocation     = @($_.ExchangeLocation)
            SharePointLocation   = @($_.SharePointLocation)
            OneDriveLocation     = @($_.OneDriveLocation)
        }
    }
    $config.RetentionPolicies = @($retPolicies)

    # Write to file
    $config | ConvertTo-Json -Depth 10 | Set-Content $OutputFile -Encoding UTF8
    Write-Host "`nExported configuration to: $OutputFile" -ForegroundColor Green
}
catch {
    Write-Error "Export failed: $_"
}
finally {
    if (-not $SkipConnection) {
        Disconnect-PurviewTenant
    }
}
