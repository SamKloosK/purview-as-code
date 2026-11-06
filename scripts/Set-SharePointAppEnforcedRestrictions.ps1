# Set-SharePointAppEnforcedRestrictions.ps1
# Conditional Access policy that turns on app enforced restrictions for SharePoint Online.
#
# Without this policy, the "access from unmanaged devices" setting in a container
# sensitivity label (for example LimitedAccess) does nothing. The policy itself blocks
# nothing: it passes the device state to SharePoint, and each site then decides what
# that means. Sites without their own setting follow the tenant setting.
#
#   .\Set-SharePointAppEnforcedRestrictions.ps1 -ExcludeUsers breakglass@contoso.onmicrosoft.com
#   .\Set-SharePointAppEnforcedRestrictions.ps1 -ExcludeUsers bg1@contoso.com, bg2@contoso.com -State enabledForReportingButNotEnforced
#
# Requires: Conditional Access Administrator, PowerShell 7 and Microsoft.Graph.Authentication

param(
    [Parameter(Mandatory = $true)]
    [string[]]$ExcludeUsers,        # UPNs of break-glass accounts

    [ValidateSet("enabled", "enabledForReportingButNotEnforced", "disabled")]
    [string]$State = "enabled",

    [string]$PolicyName = "CA-SharePoint-AppEnforcedRestrictions"
)

$sharePointApp = "00000003-0000-0ff1-ce00-000000000000"   # Office 365 SharePoint Online

# 1. Your own device: if it isn't Entra joined (or compliant), a site with LimitedAccess
#    gives you browser-only access and OneDrive sync for that site stops.
if ($IsWindows) {
    $joined = (dsregcmd /status | Select-String "AzureAdJoined") -match "YES"
    if (-not $joined) {
        Write-Host "WARNING  This device is not Entra joined. On sites with LimitedAccess you will only get" -ForegroundColor Yellow
        Write-Host "         browser access here and OneDrive sync for those sites stops." -ForegroundColor Yellow
        if ((Read-Host "Continue anyway? (y/n)") -ne "y") { return }
    }
}

Connect-MgGraph -Scopes "Policy.Read.All", "Policy.ReadWrite.ConditionalAccess", "User.Read.All" -NoWelcome

# 2. Resolve break-glass accounts
$excludeIds = foreach ($upn in $ExcludeUsers) {
    try {
        (Invoke-MgGraphRequest GET "v1.0/users/$($upn)?`$select=id" -ErrorAction Stop).id
    }
    catch {
        Write-Host "ERROR  $upn not found, stopping" -ForegroundColor Red
        Disconnect-MgGraph | Out-Null
        return
    }
}
if (@($excludeIds).Count -ne @($ExcludeUsers).Count) { return }

# 3. Build the policy
$body = @{
    displayName     = $PolicyName
    state           = $State
    conditions      = @{
        users          = @{ includeUsers = @("All"); excludeUsers = @($excludeIds) }
        applications   = @{ includeApplications = @($sharePointApp) }
        clientAppTypes = @("all")
    }
    sessionControls = @{
        applicationEnforcedRestrictions = @{ isEnabled = $true }
    }
} | ConvertTo-Json -Depth 6

# 4. Create or update
$existing = (Invoke-MgGraphRequest GET "v1.0/identity/conditionalAccess/policies?`$filter=displayName eq '$PolicyName'").value

try {
    if ($existing) {
        Invoke-MgGraphRequest PATCH "v1.0/identity/conditionalAccess/policies/$($existing[0].id)" -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
        Write-Host "OK     $PolicyName updated ($State)" -ForegroundColor Green
    }
    else {
        Invoke-MgGraphRequest POST "v1.0/identity/conditionalAccess/policies" -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
        Write-Host "OK     $PolicyName created ($State)" -ForegroundColor Green
    }
}
catch {
    Write-Host "ERROR  $($_.Exception.Message)" -ForegroundColor Red
}

Disconnect-MgGraph | Out-Null
