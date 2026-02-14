param(
    [string]$GameName = "BattlesOfMasadoria",
    [string]$OutputDir = ".\build\windows"
)

$lovePaths = @(
    "C:\Program Files\LOVE\love.exe",
    "C:\Program Files (x86)\LOVE\love.exe",
    "$env:LOCALAPPDATA\Programs\love\love.exe"
)
$love = $null
foreach ($p in $lovePaths) {
    if (Test-Path $p) { $love = $p; break }
}
if (-not $love) {
    $love = (Get-Command love -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
}
if (-not $love) {
    Write-Host "LÖVE not found. Install from https://love2d.org/ and rerun this script."
    exit 1
}

$projectRoot = $PSScriptRoot
$outRoot = Resolve-Path -Path (New-Item -ItemType Directory -Force -Path $OutputDir)
$tempDir = Join-Path $outRoot "_pack"
$loveFile = Join-Path $outRoot "$GameName.love"
$exeFile = Join-Path $outRoot "$GameName.exe"

if (Test-Path $tempDir) { Remove-Item -Recurse -Force $tempDir }
New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

Get-ChildItem -Path $projectRoot -Force |
    Where-Object { $_.Name -notin @("build", ".git", ".github") } |
    ForEach-Object {
        Copy-Item $_.FullName -Destination (Join-Path $tempDir $_.Name) -Recurse -Force
    }

$zipTmp = Join-Path $outRoot "$GameName.zip"
if (Test-Path $zipTmp) { Remove-Item -Force $zipTmp }
if (Test-Path $loveFile) { Remove-Item -Force $loveFile }
Compress-Archive -Path (Join-Path $tempDir "*") -DestinationPath $zipTmp -Force
Move-Item $zipTmp $loveFile -Force

$loveDir = Split-Path -Path $love -Parent
if (Test-Path $exeFile) { Remove-Item -Force $exeFile }
cmd /c copy /b "${love}"+"${loveFile}" "${exeFile}" | Out-Null

Copy-Item (Join-Path $loveDir "*.dll") $outRoot -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $loveDir "license.txt") $outRoot -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $loveDir "changes.txt") $outRoot -Force -ErrorAction SilentlyContinue

Remove-Item -Recurse -Force $tempDir
Write-Host "Windows build output created in: $outRoot"
Write-Host "- $loveFile"
Write-Host "- $exeFile"
