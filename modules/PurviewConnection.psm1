# PurviewConnection.psm1
# Handles connection to Security & Compliance PowerShell

function Connect-PurviewTenant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantDomain,

        [Parameter(Mandatory = $false)]
        [string]$AdminUpn
    )

    Write-Host "Connecting to Security & Compliance PowerShell for $TenantDomain..." -ForegroundColor Cyan

    # Check if ExchangeOnlineManagement module is installed
    if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
        throw "ExchangeOnlineManagement module is not installed. Run: Install-Module ExchangeOnlineManagement"
    }

    try {
        # Connect to Security & Compliance PowerShell
        $connectParams = @{
            ShowBanner = $false
        }

        if ($AdminUpn) {
            $connectParams.UserPrincipalName = $AdminUpn
        }

        Connect-IPPSSession @connectParams
        Write-Host "Connected to Security & Compliance PowerShell." -ForegroundColor Green
    }
    catch {
        throw "Failed to connect to Security & Compliance PowerShell: $_"
    }
}

function Disconnect-PurviewTenant {
    [CmdletBinding()]
    param()

    try {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Disconnected from Security & Compliance PowerShell." -ForegroundColor Yellow
    }
    catch {
        Write-Warning "Error during disconnect: $_"
    }
}

Export-ModuleMember -Function Connect-PurviewTenant, Disconnect-PurviewTenant
