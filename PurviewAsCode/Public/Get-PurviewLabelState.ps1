function Get-PurviewLabelState {
    <#
    .SYNOPSIS
    Shows how Purview stores your labels: the raw LabelActions and policy settings.

    .DESCRIPTION
    Get-Label doesn't expose encryption or marking settings as properties; they sit in LabelActions
    as JSON. This flattens them to one line per setting, which is what the plan compares against.
    Useful when a plan says "current value not readable", or just to see what's really configured.

    .EXAMPLE
    Get-PurviewLabelState | Format-Table

    .EXAMPLE
    Get-PurviewLabelState -Name Confidential-AllEmployees
    #>
    [CmdletBinding()]
    param([string[]]$Name)

    $labels = if ($Name) { $Name | ForEach-Object { Get-Label -Identity $_ } } else { Get-Label }
    foreach ($label in $labels) {
        foreach ($raw in @($label.LabelActions)) {
            if (-not $raw) { continue }
            $a = $raw | ConvertFrom-Json
            foreach ($s in @($a.Settings)) {
                [pscustomobject]@{
                    Label   = $label.Name
                    Type    = $a.Type
                    SubType = $a.SubType
                    Key     = $s.Key
                    Value   = $s.Value
                }
            }
        }
    }
}
