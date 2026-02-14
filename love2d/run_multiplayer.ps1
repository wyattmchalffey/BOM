param(
    [ValidateSet("off", "headless", "websocket")]
    [string]$Mode = "off",
    [string]$Url = "",
    [string]$PlayerName = "",
    [string]$MatchId = ""
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
    Write-Host "LÖVE not found. Install from https://love2d.org/ and run this from the love2d folder."
    Write-Host "Or add LÖVE to your PATH and use: love ."
    exit 1
}

if ($Mode -eq "websocket" -and [string]::IsNullOrWhiteSpace($Url)) {
    Write-Host "Websocket mode requires -Url (for example ws://127.0.0.1:8080)."
    exit 1
}

$env:BOM_MULTIPLAYER_MODE = $Mode
if (-not [string]::IsNullOrWhiteSpace($Url)) { $env:BOM_MULTIPLAYER_URL = $Url }
if (-not [string]::IsNullOrWhiteSpace($PlayerName)) { $env:BOM_PLAYER_NAME = $PlayerName }
if (-not [string]::IsNullOrWhiteSpace($MatchId)) { $env:BOM_MATCH_ID = $MatchId }

Write-Host "Launching with BOM_MULTIPLAYER_MODE=$Mode"
if ($env:BOM_MULTIPLAYER_URL) { Write-Host "BOM_MULTIPLAYER_URL=$($env:BOM_MULTIPLAYER_URL)" }
if ($env:BOM_PLAYER_NAME) { Write-Host "BOM_PLAYER_NAME=$($env:BOM_PLAYER_NAME)" }
if ($env:BOM_MATCH_ID) { Write-Host "BOM_MATCH_ID=$($env:BOM_MATCH_ID)" }

& $love $PSScriptRoot
