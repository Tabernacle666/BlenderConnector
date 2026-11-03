#requires -Version 5.1
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$blender = Join-Path $root 'vendor\blender\blender.exe'
if (-not (Test-Path -LiteralPath $blender)) { throw 'Executer Install.bat.' }
$latest = Get-ChildItem -Path (Join-Path $root 'outputs') -Filter '*.blend' -File -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) { throw 'Aucun projet .blend disponible: executer Test-Fan.bat.' }
Start-Process -FilePath $blender -ArgumentList ('"' + $latest.FullName + '"')
Write-Host "Ouverture: $($latest.FullName)"
