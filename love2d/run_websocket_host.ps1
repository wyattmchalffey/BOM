param(
    [string]$Host = "0.0.0.0",
    [int]$Port = 8080,
    [string]$MatchId = ""
)

$lua = (Get-Command lua -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
if (-not $lua) {
    Write-Host "Lua not found in PATH. Install Lua 5.4+ and ensure 'lua' is available."
    exit 1
}

$env:BOM_HOST = $Host
$env:BOM_PORT = "$Port"
if (-not [string]::IsNullOrWhiteSpace($MatchId)) { $env:BOM_MATCH_ID = $MatchId }

Write-Host "Starting websocket host on $Host`:$Port"
if ($env:BOM_MATCH_ID) { Write-Host "BOM_MATCH_ID=$($env:BOM_MATCH_ID)" }

& $lua "$PSScriptRoot\scripts\run_websocket_host.lua"
