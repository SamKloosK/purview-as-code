# The plan is the list of everything a run found: what it creates, what it updates and why,
# what already matches, and what is in the tenant but not in the config. Security & Compliance
# PowerShell ignores -WhatIf, so this list is the only dry run you get.

$script:Plan = [System.Collections.Generic.List[object]]::new()

function Reset-Plan {
    $script:Plan.Clear()
}

function Get-Plan {
    , $script:Plan.ToArray()
}

function Add-PlanItem {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Create', 'Update', 'NoChange', 'Drift', 'Error')][string]$Action,
        [string[]]$Details = @()
    )

    $item = [pscustomobject]@{
        PSTypeName = 'PurviewAsCode.PlanItem'
        Area       = $Area
        Name       = $Name
        Action     = $Action
        Details    = $Details
        Status     = if ($Action -in 'Create', 'Update') { 'Pending' } elseif ($Action -eq 'Error') { 'Failed' } else { '' }
        Message    = ''
    }
    $script:Plan.Add($item)
    Write-PlanLine $item
    $item
}

function Write-PlanLine {
    param($Item)

    $symbol, $color = switch ($Item.Action) {
        'Create'   { '+', 'Green' }
        'Update'   { '~', 'Yellow' }
        'NoChange' { '=', 'DarkGray' }
        'Drift'    { '!', 'Magenta' }
        'Error'    { 'x', 'Red' }
    }
    Write-Host ("  {0} {1,-22} {2}" -f $symbol, $Item.Area, $Item.Name) -ForegroundColor $color
    foreach ($line in $Item.Details) {
        Write-Host "      $line" -ForegroundColor $color
    }
}

# Runs the change for a plan item, unless -WhatIf or -Confirm says no. Failures are recorded on
# the item and don't stop the run; Invoke-PurviewDeployment reports them at the end.
function Invoke-PlanItem {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Item,
        [Parameter(Mandatory)][scriptblock]$Change
    )

    if (-not $PSCmdlet.ShouldProcess("$($Item.Area) '$($Item.Name)'", $Item.Action)) {
        $Item.Status = if ($WhatIfPreference) { 'WhatIf' } else { 'Skipped' }
        return $false
    }
    try {
        & $Change
        $Item.Status = 'Applied'
        return $true
    }
    catch {
        $Item.Status = 'Failed'
        $Item.Message = $_.Exception.Message
        Write-Host "      failed: $($Item.Message)" -ForegroundColor Red
        return $false
    }
}

function Write-PlanSummary {
    param([object[]]$Items, [bool]$WhatIf)

    $count = { param($a) @($Items | Where-Object Action -eq $a).Count }
    $failed = @($Items | Where-Object Status -eq 'Failed').Count
    Write-Host ""
    Write-Host ("{0} to create, {1} to update, {2} unchanged, {3} drift, {4} failed" -f `
        (& $count 'Create'), (& $count 'Update'), (& $count 'NoChange'), (& $count 'Drift'), $failed)
    if ($WhatIf) {
        Write-Host "WhatIf: nothing was changed." -ForegroundColor Cyan
    }
}

function Export-PlanMarkdown {
    param([object[]]$Items, [string]$Path, [string]$Title)

    $lines = @("# $Title", "", "| Action | Area | Name | Details | Status |", "| --- | --- | --- | --- | --- |")
    foreach ($i in $Items | Where-Object Action -ne 'NoChange') {
        $details = ($i.Details -join '<br>') -replace '\|', '\|'
        if ($i.Message) { $details = ($details, "failed: $($i.Message)" | Where-Object { $_ }) -join '<br>' }
        $lines += "| $($i.Action) | $($i.Area) | $($i.Name) | $details | $($i.Status) |"
    }
    $unchanged = @($Items | Where-Object Action -eq 'NoChange').Count
    $lines += "", "$unchanged objects already match the config."
    # -WhatIf:$false, or the plan file itself would be skipped in a WhatIf run.
    Set-Content -Path $Path -Value $lines -Encoding utf8 -WhatIf:$false
}

# Comparison helpers

function ConvertTo-Comparable {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [bool]) { return $Value.ToString().ToLowerInvariant() }
    "$Value".Trim().ToLowerInvariant()
}

function Format-Value {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '(empty)' }
    if ($Value -is [array]) { return ($Value -join ', ') }
    "'$Value'"
}

# Location values come back as strings in some cmdlets and as objects in others.
function Get-LocationName {
    param($Locations)
    @(foreach ($l in @($Locations)) {
        if ($null -eq $l) { continue }
        if ($l -is [string]) { $l }
        elseif ($l.PSObject.Properties['Name'] -and $l.Name) { $l.Name }
        elseif ($l.PSObject.Properties['DisplayName'] -and $l.DisplayName) { $l.DisplayName }
        else { "$l" }
    })
}

# Returns @{ Add = ...; Remove = ... } for two lists, case-insensitive and order-insensitive.
function Compare-NameSet {
    param([string[]]$Current, [string[]]$Desired)
    $cur = @($Current | Where-Object { $_ })
    $des = @($Desired | Where-Object { $_ })
    @{
        Add    = @($des | Where-Object { $_ -notin $cur })
        Remove = @($cur | Where-Object { $_ -notin $des })
    }
}
