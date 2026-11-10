function Test-PurviewConfig {
    <#
    .SYNOPSIS
    Checks a config file without connecting to a tenant.

    .DESCRIPTION
    Validates the JSON against the schema in schema/ when Test-Json is available, then checks what
    a schema can't: duplicate label names, label groups in policies, sublabels published without
    their parent, references to labels that aren't defined, and placeholders left in from the
    examples. Invoke-PurviewDeployment runs the same checks and stops on errors.

    .EXAMPLE
    Test-PurviewConfig -ConfigFile .\examples\baseline.json
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$ConfigFile)

    $schemaErrors = @()
    $schemaPath = Join-Path $PSScriptRoot '../../schema/purview-config.schema.json'
    if (Test-Path $schemaPath) {
        $json = Get-Content $ConfigFile -Raw
        $null = Test-Json -Json $json -SchemaFile $schemaPath -ErrorVariable schemaErrors -ErrorAction SilentlyContinue
    }

    $config = Read-PurviewConfig -Path $ConfigFile
    $result = Get-ConfigProblems -Config $config

    $all = @($schemaErrors | ForEach-Object { "schema: $($_.Exception.Message)" }) + @($result.Errors)
    foreach ($e in $all) { Write-Host "  error:   $e" -ForegroundColor Red }
    foreach ($w in $result.Warnings) { Write-Host "  warning: $w" -ForegroundColor Yellow }
    if (-not $all -and -not $result.Warnings) { Write-Host "  $ConfigFile is fine." -ForegroundColor Green }

    -not $all
}
