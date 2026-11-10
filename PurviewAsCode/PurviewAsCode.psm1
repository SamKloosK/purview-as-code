foreach ($folder in 'Private', 'Public') {
    foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter *.ps1) {
        . $file.FullName
    }
}

Export-ModuleMember -Function (Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public') -Filter *.ps1).BaseName
