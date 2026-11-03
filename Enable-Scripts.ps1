#requires -Version 5.1
$ErrorActionPreference='Stop'
$root=$PSScriptRoot
$path=Join-Path $root 'local\settings.json'
New-Item -ItemType Directory -Force -Path (Join-Path $root 'local') | Out-Null
if (Test-Path -LiteralPath $path) {
    $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
} else {
    $settings = [pscustomobject]@{ sync_github=$true; allow_repository_scripts=$false; poll_seconds=15 }
}
Write-Host 'ATTENTION: scripts Python provenant de main pourront executer du code local avec vos permissions Windows.'
Write-Host 'Activez uniquement si vous controlez les acces en ecriture a ce depot GitHub.'
$confirmation=Read-Host 'Taper AUTORISER pour activer'
if ($confirmation -cne 'AUTORISER') { Write-Host 'Aucune modification.'; exit 1 }
$settings.allow_repository_scripts = $true
$settings | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host 'Scripts autorises pour CE PC uniquement. Configuration ignoree par Git.' -ForegroundColor Yellow
