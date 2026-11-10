function Read-PurviewConfig {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path $Path)) { throw "Config file not found: $Path" }
    try { $config = Get-Content $Path -Raw | ConvertFrom-Json -AsHashtable }
    catch { throw "$Path isn't valid JSON: $($_.Exception.Message)" }
    $config.Remove('$schema')
    $config
}
