function Connect-PurviewSession {
    param(
        [Parameter(Mandatory)][string]$TenantDomain,
        [string]$UserPrincipalName,
        [string]$AppId,
        [string]$CertificateThumbprint
    )

    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw "ExchangeOnlineManagement isn't installed. Run: Install-Module ExchangeOnlineManagement"
    }

    $params = @{ ShowBanner = $false }
    if ($AppId) {
        # App-only (certificate) connections need the primary .onmicrosoft.com domain as -Organization.
        $params.AppId = $AppId
        $params.CertificateThumbprint = $CertificateThumbprint
        $params.Organization = $TenantDomain
    }
    elseif ($UserPrincipalName) {
        $params.UserPrincipalName = $UserPrincipalName
    }
    Connect-IPPSSession @params
}

# Looks up the tenant ID for a domain through the public OpenID Connect discovery document,
# the same endpoint every sign-in uses. No authentication needed.
function Resolve-TenantId {
    param([Parameter(Mandatory)][string]$Domain)
    $doc = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$Domain/v2.0/.well-known/openid-configuration" -ErrorAction Stop
    if ($doc.issuer -match '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}') { return $Matches[0] }
    throw "Couldn't read a tenant ID for '$Domain' from the discovery document."
}

# Stops the run when the Security & Compliance session belongs to a different tenant than the
# config. Without this, a config for one client lands in whatever tenant you happen to be signed
# in to, with the right tenant name printed above it.
function Assert-PurviewTenant {
    param([Parameter(Mandatory)][string]$TenantDomain, [string]$TenantId)

    $session = @(Get-ConnectionInformation | Where-Object { $_.IsEopSession -and $_.State -eq 'Connected' }) | Select-Object -First 1
    if (-not $session) {
        throw "No Security & Compliance PowerShell session found. Connect first, or leave out -SkipConnection."
    }
    $expected = if ($TenantId) { $TenantId } else { Resolve-TenantId -Domain $TenantDomain }
    if ("$($session.TenantID)" -ne $expected) {
        throw "The session is connected to tenant $($session.TenantID), but the config is for $TenantDomain ($expected). Nothing was changed."
    }
    Write-Host "Tenant verified: $TenantDomain ($expected)" -ForegroundColor Cyan
}
