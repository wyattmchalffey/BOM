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

# Copy 64-bit SSL DLLs for wss:// support
$ssl64Dir = Join-Path $projectRoot "build\ssl64"
$sslDll = Join-Path $ssl64Dir "ssl.dll"
if (Test-Path $sslDll) {
    Copy-Item $sslDll $outRoot -Force
    Write-Host "Copied ssl.dll (64-bit LuaSec)"
} else {
    Write-Warning "ssl.dll not found at $sslDll — run build_ssl64.ps1 first for wss:// support"
}

$openSSLBin = "C:\Program Files\OpenSSL-Win64\bin"
foreach ($dll in @("libssl-3-x64.dll", "libcrypto-3-x64.dll")) {
    $src = Join-Path $openSSLBin $dll
    if (Test-Path $src) {
        Copy-Item $src $outRoot -Force
        Write-Host "Copied $dll"
    } else {
        Write-Warning "$dll not found at $src"
    }
}

Remove-Item -Recurse -Force $tempDir
Write-Host "Windows build output created in: $outRoot"
Write-Host "- $loveFile"
Write-Host "- $exeFile"
