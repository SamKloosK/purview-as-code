# Set-SiteLabelDefaults.ps1
# Follow-up steps after a deploy that includes a container label and published retention labels.
#
#   Step Prepare     Run once, right after the deploy. Enables sensitivity labels for
#                    Microsoft 365 groups and sites in Entra ID (EnableMIPLabels) and
#                    starts the label sync. Container labels show up within about 24 hours.
#
#   Step Libraries   Run 1 to 7 days later, once the published retention labels are visible
#                    on the site. Sets a default retention label per document library and
#                    applies it to existing items as well.
#
#   .\Set-SiteLabelDefaults.ps1 -Step Prepare
#   .\Set-SiteLabelDefaults.ps1 -Step Libraries -SiteUrl https://contoso.sharepoint.com/sites/Finance `
#       -PnPClientId <your PnP app registration> -LibraryLabels @{ "Invoices" = "Bewaren-Fiscaal-8Jaar"; "Legal" = "Bewaren-Permanent" }
#
# Requires: Microsoft.Graph.Authentication, ExchangeOnlineManagement and (for Libraries) PnP.PowerShell
# with your own Entra app registration for PnP interactive sign-in.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Prepare", "Libraries")]
    [string]$Step,

    [string]$SiteUrl,

    [string]$PnPClientId,

    [hashtable]$LibraryLabels
)

if ($Step -eq "Prepare") {
    # 1. Enable container labels in Entra ID (EnableMIPLabels in the Group.Unified settings)
    #    Uses Invoke-MgGraphRequest so Graph module version differences don't get in the way
    Connect-MgGraph -Scopes "Directory.ReadWrite.All" -NoWelcome

    $settings = (Invoke-MgGraphRequest GET "v1.0/groupSettings").value
    $unified  = $settings | Where-Object { $_.displayName -eq "Group.Unified" }

    if (-not $unified) {
        $body = @{
            templateId = "62375ab9-6b52-47ed-826b-58e47e0e304b"   # Group.Unified template
            values     = @(@{ name = "EnableMIPLabels"; value = "True" })
        }
        Invoke-MgGraphRequest POST "v1.0/groupSettings" -Body ($body | ConvertTo-Json -Depth 5) -ContentType "application/json" | Out-Null
        Write-Host "OK     Group.Unified created with EnableMIPLabels = True" -ForegroundColor Green
    }
    else {
        $current = ($unified.values | Where-Object { $_.name -eq "EnableMIPLabels" }).value
        if ($current -eq "True") {
            Write-Host "OK     EnableMIPLabels was already on" -ForegroundColor Green
        }
        else {
            # PATCH replaces the whole list, so send all existing values along
            $values = foreach ($v in $unified.values) {
                @{ name = $v.name; value = $(if ($v.name -eq "EnableMIPLabels") { "True" } else { $v.value }) }
            }
            Invoke-MgGraphRequest PATCH "v1.0/groupSettings/$($unified.id)" -Body (@{ values = @($values) } | ConvertTo-Json -Depth 5) -ContentType "application/json" | Out-Null
            Write-Host "OK     EnableMIPLabels turned on" -ForegroundColor Green
        }
    }
    Disconnect-MgGraph | Out-Null

    # 2. Sync labels to Entra ID
    Connect-IPPSSession -ShowBanner:$false
    Execute-AzureADLabelSync
    Write-Host "OK     Label sync started. Container labels can be selected on sites within about 24 hours." -ForegroundColor Green
    Disconnect-ExchangeOnline -Confirm:$false
}

if ($Step -eq "Libraries") {
    if (-not $SiteUrl -or -not $PnPClientId -or -not $LibraryLabels) {
        throw "Step Libraries needs -SiteUrl, -PnPClientId and -LibraryLabels"
    }

    Connect-PnPOnline -Url $SiteUrl -Interactive -ClientId $PnPClientId

    foreach ($library in $LibraryLabels.Keys) {
        try {
            Set-PnPRetentionLabel -List $library -Label $LibraryLabels[$library] -SyncToItems $true -ErrorAction Stop
            Write-Host "OK     $library -> $($LibraryLabels[$library]) (existing items included)" -ForegroundColor Green
        }
        catch {
            Write-Host "ERROR  $library : $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "       Label not on the site yet? Publishing can take up to 7 days." -ForegroundColor Yellow
        }
    }
}
