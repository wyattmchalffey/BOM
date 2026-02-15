param(
    [Alias("Host")]
    [string]$BindHost = "0.0.0.0",
    [int]$Port = 8080,
    [string]$MatchId = ""
)

$lua = (Get-Command lua -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
if (-not $lua) {
    Write-Host "Lua not found in PATH. Install Lua and ensure 'lua' is available."
    exit 1
}

$wsCheck = "local ok1,m1=pcall(require,'websocket.server.sync'); if ok1 and m1 and type(m1.listen)=='function' then os.exit(0) end; local ok2,m2=pcall(require,'websocket.server_copas'); local ok3=pcall(require,'copas'); if ok2 and m2 and type(m2.listen)=='function' and ok3 then os.exit(0) end; os.exit(3)"
& $lua -e $wsCheck
if ($LASTEXITCODE -ne 0) {
    Write-Host "Missing supported websocket server backend."
    Write-Host "Install it for the same Lua runtime used by this script (for example via LuaRocks)."
    Write-Host "Try: luarocks install websocket"
    Write-Host "If LuaRocks reports no results for your current Lua version, run:"
    Write-Host "  luarocks install websocket --check-lua-versions"
    Write-Host "Then install for a Lua version you actually have installed (example uses 5.3):"
    Write-Host "  luarocks --lua-version=5.3 install websocket"
    Write-Host "If LuaRocks says 'Could not find Lua <version> in PATH', set the interpreter path first:"
    Write-Host "  luarocks --lua-version=5.3 --local config variables.LUA C:\path\to\lua.exe"
    Write-Host 'Verify one backend with: lua -e "require(""websocket.server.sync"")"'
    Write-Host 'Or (lua-websockets): lua -e "require(""websocket.server_copas""); require(""copas"")"'
    exit 1
}

$env:BOM_HOST = $BindHost
$env:BOM_PORT = "$Port"
if (-not [string]::IsNullOrWhiteSpace($MatchId)) { $env:BOM_MATCH_ID = $MatchId }

Write-Host "Starting websocket host on $BindHost`:$Port"
if ($env:BOM_MATCH_ID) { Write-Host "BOM_MATCH_ID=$($env:BOM_MATCH_ID)" }

& $lua "$PSScriptRoot\scripts\run_websocket_host.lua"
