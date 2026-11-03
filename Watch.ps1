#requires -Version 5.1
[CmdletBinding()]
param([switch]$Once)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$exe = Join-Path $root 'vendor\blender\blender.exe'
$dispatcher = Join-Path $root 'src\dispatch.py'
$settingsPath = Join-Path $root 'local\settings.json'
$lockPath = Join-Path $root 'local\watch.lock'
$logDir = Join-Path $root 'local\logs'
$tempDir = Join-Path $root 'local\temp'
foreach ($p in @($logDir,$tempDir,(Join-Path $root 'feedback'),(Join-Path $root 'outputs'))) {
    New-Item -ItemType Directory -Force -Path $p | Out-Null
}
if (-not (Test-Path -LiteralPath $exe)) { throw 'Blender absent: executer Install.bat.' }
if (-not (Test-Path -LiteralPath $settingsPath)) {
    '{"sync_github":true,"allow_repository_scripts":false,"poll_seconds":15}' | Set-Content -LiteralPath $settingsPath -Encoding ASCII
}
$env:TEMP = $tempDir; $env:TMP = $tempDir
# One watcher per worktree; file handle is kept open (deleted in finally).
try {
    $lock = [System.IO.File]::Open($lockPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
} catch { throw "Connecteur deja lance, ou verrou restant: $lockPath (verifier avant de supprimer)" }
try {
    $pidBytes = [System.Text.Encoding]::ASCII.GetBytes([string]$PID)
    $lock.Write($pidBytes,0,$pidBytes.Length); $lock.Flush()
    $git = Get-Command git -ErrorAction SilentlyContinue
    $isRepo = $false
    if ($git) {
        $gitRoot = (& git -C $root rev-parse --show-toplevel 2>$null)
        if ($LASTEXITCODE -eq 0 -and $gitRoot) {
            $isRepo = ([IO.Path]::GetFullPath($gitRoot.TrimEnd('/','\')) -ieq [IO.Path]::GetFullPath($root))
        }
    }
    Write-Host 'BlenderConnector: Ctrl+C pour quitter, aucune tache de fond apres arret.'
    if (-not $isRepo) { Write-Host 'Mode local: initialiser GitHub plus tard pour la synchronisation.' }
    do {
        $settings = Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json
        $pollSeconds = 15
        if ($settings.poll_seconds -and [int]$settings.poll_seconds -ge 3 -and [int]$settings.poll_seconds -le 3600) { $pollSeconds = [int]$settings.poll_seconds }
        $sync = ($isRepo -and ($settings.sync_github -eq $true))
        $branchOk = $false
        if ($sync) {
            $branch = (& git -C $root branch --show-current 2>$null)
            $branchOk = ($LASTEXITCODE -eq 0 -and $branch -eq 'main')
            if (-not $branchOk) { Write-Warning 'Git: branche differente de main; synchronisation desactivee.' }
        }
        if ($sync -and $branchOk) {
            & git -C $root pull --ff-only origin main
            if ($LASTEXITCODE -ne 0) { Write-Warning 'git pull a echoue; traitement des taches deja presentes.' }
        }
        $jobs = Get-ChildItem -LiteralPath (Join-Path $root 'jobs') -Filter '*.json' -File | Sort-Object Name
        foreach ($jobFile in $jobs) {
            $jobId = [IO.Path]::GetFileNameWithoutExtension($jobFile.Name)
            if ($jobId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') {
                Write-Warning "Nom de job invalide: $($jobFile.Name)"; continue
            }
            $feedbackDir = Join-Path $root ("feedback\$jobId")
            $reportDst = Join-Path $feedbackDir 'report.json'
            if (Test-Path -LiteralPath $reportDst) { continue }
            Write-Host "Traitement: $jobId"
            New-Item -ItemType Directory -Force -Path $feedbackDir | Out-Null
            $outputDir = Join-Path $root ("outputs\$jobId")
            New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
            $logPath = Join-Path $logDir "$jobId.log"
            $outputReport = Join-Path $outputDir 'report.json'
            $exitCode = 1
            try {
                if ($jobFile.Length -gt 65536) { throw 'Job refuse: JSON > 64 Kio.' }
                # Untrusted JSON can only select built-in ops; scripts need local opt-in.
                $jobData = Get-Content -LiteralPath $jobFile.FullName -Raw | ConvertFrom-Json
                if ($jobData.id -cne $jobId) { throw 'id JSON different du nom de fichier.' }
                & $exe --background --factory-startup --python-exit-code 1 --python $dispatcher -- $jobFile.FullName $outputDir $root $settingsPath *> $logPath
                $exitCode = $LASTEXITCODE
                if ($null -eq $exitCode) { $exitCode = 1 }
                if (-not (Test-Path -LiteralPath $outputReport)) { throw "Blender a termine sans rapport (exit $exitCode)." }
                Copy-Item -LiteralPath $outputReport -Destination $reportDst -Force
                Get-ChildItem -LiteralPath $outputDir -Filter '*.jpg' -File | Where-Object { $_.Length -lt 2000000 } | ForEach-Object {
                    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $feedbackDir $_.Name) -Force
                }
            } catch {
                $errMessage = [string]$_
                Write-Warning "Echec $jobId : $errMessage"
                if (-not (Test-Path -LiteralPath $reportDst)) {
                    $failure = [ordered]@{ schema=1; id=$jobId; status='error'; message=$errMessage; exit_code=$exitCode }
                    $failure | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $reportDst -Encoding UTF8
                }
            }
            if ($exitCode -ne 0) { Write-Warning "Exit Blender: $exitCode ; voir local\logs\$jobId.log" }
            Write-Host "Retour: $reportDst"
            if ($sync -and $branchOk) {
                & git -C $root add -- ("feedback/$jobId")
                if ($LASTEXITCODE -eq 0) {
                    & git -C $root diff --cached --quiet
                    if ($LASTEXITCODE -ne 0) {
                        & git -C $root commit -m "BlenderConnector result: $jobId"
                        if ($LASTEXITCODE -eq 0) {
                            & git -C $root push origin main
                            if ($LASTEXITCODE -ne 0) { Write-Warning 'git push a echoue: le retour reste dans le depot local.' }
                        }
                    }
                }
            }
        }
        if (-not $Once) { Start-Sleep -Seconds $pollSeconds }
    } while (-not $Once)
} finally {
    $lock.Close()
    Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
}
