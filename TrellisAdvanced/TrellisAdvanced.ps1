#requires -Version 5.1
[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Quote-Arg([string]$s) {
    if ($s.Contains('"')) { throw 'Unexpected quotation mark in path.' }
    return '"' + $s + '"'
}
function Build-Args([string]$image, [string]$output, [string]$models, [hashtable]$p) {
    $a = @((Quote-Arg $image), (Quote-Arg $output), '--models', (Quote-Arg $models),
           '--model', 'trellis', '--res', [string]$p.Resolution,
           '--seed', [string]$p.Seed, '--steps', [string]$p.Steps)
    if ($p.Tokens)  { $a += @('--max-tokens', '98304') }
    if ($p.Faces)   { $a += @('--faces', '600000') }
    if ($p.Atlas)   { $a += @('--atlas', '4096') }
    if ($p.TexRes)  { $a += @('--tex-res', '1024') }
    if ($p.Normal)  { $a += @('--normal-map', 'on') }
    if ($p.Png)     { $a += @('--webp', 'off') }
    if ($p.Matte)   { $a += @('--bg-removal', 'birefnet') }
    if ($p.Cutout)  { $a += '--dump-bg' }
    if ($p.GpuOnly) { $a += '--require-gpu' }
    if ($p.Verbose) { $a += '--verbose' }
    return ,($a -join ' ')
}

if ($SelfTest) {
    $flags = @{ Resolution=1536; Seed=42; Steps=12; Tokens=$true; Faces=$true; Atlas=$true;
                TexRes=$true; Normal=$true; Png=$true; Matte=$true; Cutout=$true;
                GpuOnly=$true; Verbose=$true }
    $argsLine = Build-Args 'D:\some path\in.png' 'D:\out.glb' 'D:\models' $flags
    foreach ($expected in @('--res 1536','--max-tokens 98304','--faces 600000',
              '--atlas 4096','--tex-res 1024','--normal-map on','--webp off',
              '--bg-removal birefnet','--dump-bg','--require-gpu','--verbose')) {
        if (-not $argsLine.Contains($expected)) { throw "Self-test failed: $expected" }
    }
    Write-Host 'SELFTEST OK'
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$repoRoot = Split-Path $PSScriptRoot -Parent
$trellis = Join-Path (Split-Path $repoRoot -Parent) 'Trellis2'
$cli = Join-Path $trellis 'runtime\trellis-cli.exe'
$models = $null
foreach ($m in @((Join-Path $trellis 'models'), (Join-Path $trellis 'models\q8'), (Join-Path $trellis 'models\q4'))) {
    if (Test-Path -LiteralPath (Join-Path $m 'shape_flow_1024.gguf')) { $models = $m; break }
}
if (-not (Test-Path -LiteralPath $cli)) {
    [System.Windows.Forms.MessageBox]::Show("Executable introuvable : $cli", 'Trellis Advanced') | Out-Null
    exit 2
}
if (-not $models) {
    [System.Windows.Forms.MessageBox]::Show("Poids GGUF introuvables dans $trellis\models", 'Trellis Advanced') | Out-Null
    exit 2
}

$outDir = Join-Path $trellis 'data\advanced'
$logsDir = Join-Path $outDir 'logs'
$tempDir = Join-Path $trellis 'temp'
foreach ($dir in @($outDir, $logsDir, $tempDir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}
$env:TEMP = $tempDir
$env:TMP = $tempDir

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Trellis Advanced - CUDA / 5060 Ti 16GB'
$form.Size = New-Object System.Drawing.Size(860,760)
$form.MinimumSize = New-Object System.Drawing.Size(860,760)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI',10)

function Label([string]$t, [int]$x, [int]$y, [int]$w=790) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $t; $l.Location = New-Object System.Drawing.Point($x,$y)
    $l.Size = New-Object System.Drawing.Size($w,23)
    $form.Controls.Add($l)
    return $l
}
function Check([string]$t, [int]$x, [int]$y, [bool]$checked=$false) {
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $t; $c.Location = New-Object System.Drawing.Point($x,$y)
    $c.Size = New-Object System.Drawing.Size(385,27)
    $c.Checked = $checked
    $form.Controls.Add($c)
    return $c
}
function Button([string]$t, [int]$x, [int]$y, [int]$w=130) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $t; $b.Location = New-Object System.Drawing.Point($x,$y)
    $b.Size = New-Object System.Drawing.Size($w,32)
    $form.Controls.Add($b)
    return $b
}
Label 'Image source (glisser-deposer possible)' 20 15 | Out-Null
$script:imagePath = New-Object System.Windows.Forms.TextBox
$script:imagePath.Location = New-Object System.Drawing.Point(20,40)
$script:imagePath.Size = New-Object System.Drawing.Size(670,28)
$script:imagePath.AllowDrop = $true
$script:imagePath.Add_DragEnter({
    param($sender,$e)
    if ($e.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {
        $e.Effect = [System.Windows.Forms.DragDropEffects]::Copy
    }
})
$script:imagePath.Add_DragDrop({
    param($sender,$e)
    $files = @($e.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop))
    if ($files.Count -gt 0) { $script:imagePath.Text = [string]$files[0] }
})
$form.Controls.Add($script:imagePath)
$pick = Button 'Parcourir' 702 38 124
$pick.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Images|*.png;*.jpg;*.jpeg;*.webp;*.bmp|Tous|*.*'
    if ($dlg.ShowDialog() -eq 'OK') { $script:imagePath.Text = $dlg.FileName }
})
Label 'Resolution' 20 88 100 | Out-Null
$res = New-Object System.Windows.Forms.ComboBox
$res.DropDownStyle = 'DropDownList'
[void]$res.Items.AddRange([object[]]@('512','1024','1536'))
$res.SelectedItem = '1024'
$res.Location = New-Object System.Drawing.Point(130,86)
$res.Size = New-Object System.Drawing.Size(100,27)
$form.Controls.Add($res)
Label 'Seed' 270 88 55 | Out-Null
$seed = New-Object System.Windows.Forms.NumericUpDown
$seed.Minimum = 0; $seed.Maximum = 2147483647; $seed.Value = 42
$seed.Location = New-Object System.Drawing.Point(325,86)
$seed.Size = New-Object System.Drawing.Size(115,27)
$form.Controls.Add($seed)
Label 'Steps' 476 88 60 | Out-Null
$steps = New-Object System.Windows.Forms.NumericUpDown
$steps.Minimum = 4; $steps.Maximum = 32; $steps.Value = 12
$steps.Location = New-Object System.Drawing.Point(535,86)
$steps.Size = New-Object System.Drawing.Size(95,27)
$form.Controls.Add($steps)

$tokens = Check 'Plafond tokens 98 304 (au lieu de 49 152)' 20 142
$faces = Check 'Maillage 600 000 faces (au lieu de 300 000)' 435 142
$atlas = Check 'Atlas UV 4096 px' 20 179
$texRes = Check 'Volume PBR 1024 (plus de VRAM)' 435 179
$normal = Check 'Generer normal map' 20 216
$png = Check 'PNG sans pertes au lieu de WebP' 435 216
$matte = Check 'Forcer BiRefNet (detourage)' 20 253
$cutout = Check 'Sauvegarder le detourage PNG' 435 253
$gpu = Check 'GPU requis (aucun repli CPU)' 20 290 $true
$verbose = Check 'Journal GPU et etapes detaille' 435 290 $true

$warning = Label '1536 + tokens eleves peut saturer 16 Go. Chaque option est independante.' 20 332
$warning.ForeColor = [System.Drawing.Color]::DarkOrange
$generate = Button 'Generer GLB' 20 365 165
$cancel = Button 'Annuler' 195 365 125
$cancel.Enabled = $false
$openFolder = Button 'Ouvrir resultats' 335 365 158
$preview = Button 'Ouvrir dans Blender' 505 365 170
$preview.Enabled = $false
$progress = New-Object System.Windows.Forms.ProgressBar
$progress.Location = New-Object System.Drawing.Point(20,418)
$progress.Size = New-Object System.Drawing.Size(805,19)
$progress.Style = 'Blocks'
$form.Controls.Add($progress)
$status = Label 'Pret. Les modeles Q8 existants restent inchanges.' 20 447
$log = New-Object System.Windows.Forms.TextBox
$log.Location = New-Object System.Drawing.Point(20,479)
$log.Size = New-Object System.Drawing.Size(805,212)
$log.Multiline = $true; $log.ScrollBars = 'Vertical'
$log.ReadOnly = $true; $log.Font = New-Object System.Drawing.Font('Consolas',9)
$form.Controls.Add($log)
$script:proc = $null
$script:result = $null
$script:stdout = $null
$script:stderr = $null

function Current-Flags {
    return @{
        Resolution=[int]$res.SelectedItem; Seed=[int]$seed.Value; Steps=[int]$steps.Value
        Tokens=$tokens.Checked; Faces=$faces.Checked; Atlas=$atlas.Checked
        TexRes=$texRes.Checked; Normal=$normal.Checked; Png=$png.Checked
        Matte=$matte.Checked; Cutout=$cutout.Checked; GpuOnly=$gpu.Checked
        Verbose=$verbose.Checked
    }
}
$generate.Add_Click({
    $source = $script:imagePath.Text.Trim()
    if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
        [IO.Path]::GetExtension($source).ToLowerInvariant() -notin @('.png','.jpg','.jpeg','.webp','.bmp')) {
        [System.Windows.Forms.MessageBox]::Show('Choisis une image PNG/JPG/WebP/BMP valide.') | Out-Null
        return
    }
    if ($script:proc -and -not $script:proc.HasExited) { return }
    $p = Current-Flags
    if ($p.Resolution -eq 1536 -and $p.Tokens) {
        $choice = [System.Windows.Forms.MessageBox]::Show(
          '1536 avec 98 304 tokens : risque de depassement VRAM. Continuer ?', 'Mode avance',
          [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($choice -ne 'Yes') { return }
    }
    $stem = [IO.Path]::GetFileNameWithoutExtension($source) -replace '[^\w-]', '_'
    if ($stem.Length -gt 60) { $stem = $stem.Substring(0,60) }
    $id = '{0}_r{1}_{2}' -f $stem,$p.Resolution,(Get-Date -Format 'yyyyMMdd_HHmmss_fff')
    $script:result = Join-Path $outDir ($id + '.glb')
    $script:stdout = Join-Path $logsDir ($id + '.out.log')
    $script:stderr = Join-Path $logsDir ($id + '.err.log')
    $argsLine = Build-Args $source $script:result $models $p
    $meta = [ordered]@{ image=$source; output=$script:result; binary=$cli; models=$models;
                        arguments=$argsLine; parameters=$p; created=(Get-Date).ToString('o') }
    ($meta | ConvertTo-Json -Depth 7) | Set-Content -LiteralPath (Join-Path $logsDir ($id+'.json')) -Encoding UTF8
    try {
        $script:proc = Start-Process -FilePath $cli -ArgumentList $argsLine -PassThru -NoNewWindow -RedirectStandardOutput $script:stdout -RedirectStandardError $script:stderr -WorkingDirectory $trellis
        $generate.Enabled = $false; $cancel.Enabled = $true; $preview.Enabled = $false
        $progress.Style = 'Marquee'
        $status.Text = 'Generation active (progression sans pourcentage invente)'
        $log.Text = "$cli $argsLine"
    } catch {
        $status.Text = 'Echec au demarrage : ' + $_.Exception.Message
        $script:proc = $null
    }
})
$cancel.Add_Click({
    if ($script:proc -and -not $script:proc.HasExited) {
        & taskkill.exe /PID $script:proc.Id /T /F | Out-Null
        $status.Text = 'Annulation demandee'
    }
})
$openFolder.Add_Click({ Start-Process explorer.exe -ArgumentList (Quote-Arg $outDir) })
$preview.Add_Click({
    if (-not $script:result -or -not (Test-Path -LiteralPath $script:result)) { return }
    $blender = Join-Path $repoRoot 'vendor\blender\blender.exe'
    $opener = Join-Path $PSScriptRoot 'open_glb.py'
    if (Test-Path -LiteralPath $blender) {
        Start-Process -FilePath $blender -ArgumentList ((Quote-Arg '--python')+' '+(Quote-Arg $opener)+' -- '+(Quote-Arg $script:result))
    } else {
        Start-Process explorer.exe -ArgumentList ('/select,'+(Quote-Arg $script:result))
    }
})
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1500
$timer.Add_Tick({
    if (-not $script:proc) { return }
    $lines = @()
    foreach ($file in @($script:stdout, $script:stderr)) {
        if ($file -and (Test-Path -LiteralPath $file)) {
            try { $lines += @(Get-Content -LiteralPath $file -Tail 18 -ErrorAction Stop) } catch {}
        }
    }
    if ($lines.Count) {
        $log.Lines = [string[]]$lines
        $log.SelectionStart = $log.TextLength
        $log.ScrollToCaret()
    }
    if ($script:proc.HasExited) {
        $code = $script:proc.ExitCode
        $script:proc = $null
        $progress.Style = 'Blocks'
        $generate.Enabled = $true; $cancel.Enabled = $false
        if ($code -eq 0 -and (Test-Path -LiteralPath $script:result) -and
            (Get-Item -LiteralPath $script:result).Length -gt 1024) {
            $status.Text = "GLB OK : $script:result"
            $preview.Enabled = $true
        } else {
            $status.Text = "Echec (code $code) - logs sur D:\GITLINK\Trellis2\data\advanced\logs"
        }
    }
})
$timer.Start()
$form.Add_FormClosing({
    param($sender,$e)
    if ($script:proc -and -not $script:proc.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            'Arreter la generation et fermer ?', 'Quitter',
            [System.Windows.Forms.MessageBoxButtons]::YesNo)
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        & taskkill.exe /PID $script:proc.Id /T /F | Out-Null
    }
    $timer.Stop()
})
[void]$form.ShowDialog()
