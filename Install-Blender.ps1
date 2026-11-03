#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$root = $PSScriptRoot
$version = '4.5.15'
$package = "blender-$version-windows-x64"
$archiveName = "$package.zip"
$url = "https://download.blender.org/release/Blender4.5/$archiveName"
$checksumUrl = "https://download.blender.org/release/Blender4.5/blender-$version.sha256"
$downloadDir = Join-Path $root 'local\downloads'
$tempDir = Join-Path $root 'local\temp'
$vendorDir = Join-Path $root 'vendor'
$destination = Join-Path $vendorDir 'blender'
$zip = Join-Path $downloadDir $archiveName
$checksumFile = Join-Path $downloadDir "blender-$version.sha256"
@($downloadDir,$tempDir,$vendorDir,(Join-Path $root 'input'),(Join-Path $root 'outputs'),(Join-Path $root 'feedback'),(Join-Path $root 'jobs')) | ForEach-Object { New-Item -ItemType Directory -Path $_ -Force | Out-Null }
if (-not (Test-Path -LiteralPath (Join-Path $root 'local\settings.json'))) {
    '{"sync_github":true,"allow_repository_scripts":false,"poll_seconds":15}' | Set-Content -LiteralPath (Join-Path $root 'local\settings.json') -Encoding ASCII
}
$env:TEMP = $tempDir
$env:TMP = $tempDir
if (Test-Path -LiteralPath (Join-Path $destination 'blender.exe')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $destination 'portable') | Out-Null
    Write-Host "Blender deja present: $destination" -ForegroundColor Green
    & (Join-Path $destination 'blender.exe') --version | Select-Object -First 2
    exit 0
}
Write-Host "Blender $version LTS portable, installation dans $destination"
$web = New-Object System.Net.WebClient
$web.Headers.Add('User-Agent','BlenderConnector/0.1')
try {
    Write-Host "Recuperation du SHA-256 officiel: $checksumUrl"
    $web.DownloadFile($checksumUrl,$checksumFile)
    $checksumText = [System.IO.File]::ReadAllText($checksumFile)
    $officialSha = $null
    foreach ($line in ($checksumText -split "`r?`n")) {
        if ($line -match '^\s*([a-fA-F0-9]{64})\s+\*?(.+?)\s*$') {
            if ([IO.Path]::GetFileName($matches[2].Trim()) -ieq $archiveName) { $officialSha = $matches[1].ToUpperInvariant(); break }
        }
        if ($line -match '^\s*SHA256\s*\((.+?)\)\s*=\s*([a-fA-F0-9]{64})') {
            if ([IO.Path]::GetFileName($matches[1].Trim()) -ieq $archiveName) { $officialSha = $matches[2].ToUpperInvariant(); break }
        }
    }
    if (-not $officialSha) { throw "Empreinte de $archiveName introuvable dans le manifeste officiel: $checksumFile" }
    $valid = $false
    if (Test-Path -LiteralPath $zip) {
        $existingHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
        $valid = ($existingHash -eq $officialSha)
        if (-not $valid) { Write-Warning 'Archive existante invalide; nouveau telechargement' }
    }
    if (-not $valid) {
        $partial = "$zip.part"
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
        Write-Host "Telechargement officiel (~380 Mio): $url"
        $web.DownloadFile($url,$partial)
        $hash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
        if ($hash -ne $officialSha) { throw "ECHEC SHA256: attendu $officialSha, recu $hash" }
        Move-Item -LiteralPath $partial -Destination $zip -Force
    }
    Write-Host 'Archive SHA256 valide.' -ForegroundColor Green
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $staging = Join-Path $tempDir ('extract-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($zip,$staging)
        $exe = Join-Path $staging "$package\blender.exe"
        if (-not (Test-Path -LiteralPath $exe)) { throw "blender.exe absent dans $package" }
        Move-Item -LiteralPath (Join-Path $staging $package) -Destination $destination
        New-Item -ItemType Directory -Force -Path (Join-Path $destination 'portable') | Out-Null
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
} finally {
    $web.Dispose()
}
Write-Host "Blender portable installe: $destination" -ForegroundColor Green
& (Join-Path $destination 'blender.exe') --version | Select-Object -First 2
if ($LASTEXITCODE -ne 0) { throw 'Le binaire existe mais son lancement a echoue.' }
Write-Host 'Commande suivante: Test-Fan.bat (ou Run-Blender.bat / Watch.bat)'
