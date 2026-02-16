param(
    [string]$LuaVersion = "",
    [string]$LuaExePath = ""
)

function Test-Command($name) {
    return [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

if (-not (Test-Command "lua")) {
    Write-Host "Lua is not available in PATH."
    Write-Host "Install Lua first, then re-run this script."
    exit 1
}

if (-not (Test-Command "luarocks")) {
    Write-Host "LuaRocks is not available in PATH."
    Write-Host "Install LuaRocks first, then re-run this script."
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($LuaExePath)) {
    if ([string]::IsNullOrWhiteSpace($LuaVersion)) {
        Write-Host "When -LuaExePath is set, also pass -LuaVersion (for example -LuaVersion 5.3)."
        exit 1
    }

    Write-Host "Configuring LuaRocks Lua interpreter for $LuaVersion -> $LuaExePath"
    & luarocks --lua-version=$LuaVersion --local config variables.LUA $LuaExePath
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Failed to configure Lua interpreter path in LuaRocks."
        exit 1
    }
}

function Install-Rock($rockName, $luaVersion) {
    if ([string]::IsNullOrWhiteSpace($luaVersion)) {
        Write-Host "Installing rock: $rockName"
        & luarocks install $rockName
    }
    else {
        Write-Host "Installing rock: $rockName (Lua $luaVersion)"
        & luarocks --lua-version=$luaVersion install $rockName
    }

    return ($LASTEXITCODE -eq 0)
}

$installed = Install-Rock "lua-websockets" $LuaVersion
if (-not $installed) {
    Write-Host "Install of 'lua-websockets' failed; trying websocket backend..."
    $installed = Install-Rock "websocket" $LuaVersion
}

if (-not $installed) {
    Write-Host "Could not install a websocket backend with LuaRocks."
    Write-Host "Try: luarocks install lua-websockets --check-lua-versions"
    Write-Host "If websocket fails with Git repository errors, prefer lua-websockets."
    if ([string]::IsNullOrWhiteSpace($LuaVersion)) {
        Write-Host "Then re-run this script with -LuaVersion matching your installed Lua."
    }
    exit 1
}


$sslInstalled = Install-Rock "luasec" $LuaVersion
if (-not $sslInstalled) {
    Write-Host "Install of 'luasec' failed; wss:// connections may not work."
}

Write-Host "Verifying SSL module for wss:// support..."
& lua -e "local ok,ssl=pcall(require,'ssl'); if ok and ssl then os.exit(0) else os.exit(2) end"
$hasSsl = ($LASTEXITCODE -eq 0)
if (-not $hasSsl) {
    Write-Host "SSL module verification failed (require('ssl'))."
    Write-Host "wss:// relay URLs require LuaSec."
    if ([string]::IsNullOrWhiteSpace($LuaVersion)) {
        Write-Host "Try: luarocks install luasec"
    }
    else {
        Write-Host "Try: luarocks --lua-version=$LuaVersion install luasec"
    }
}

Write-Host "Verifying client websocket module..."
& lua -e "local ok = pcall(require, 'websocket'); if ok then os.exit(0) else os.exit(2) end"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Client websocket module verification failed (require('websocket'))."
    exit 1
}

Write-Host "Verifying host websocket backend..."
& lua -e "local ok1,m1=pcall(require,'websocket.server.sync'); local ok2,m2=pcall(require,'websocket.server_copas'); local ok3=pcall(require,'copas'); local pass=(ok1 and m1 and type(m1.listen)=='function') or (ok2 and m2 and type(m2.listen)=='function' and ok3); if pass then os.exit(0) else os.exit(2) end"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Host websocket backend verification failed."
    Write-Host "Expected either websocket.server.sync or websocket.server_copas + copas."
    exit 1
}

if ($hasSsl) {
    Write-Host "Multiplayer websocket dependencies installed and verified (including wss:// support)."
}
else {
    Write-Host "Multiplayer websocket dependencies installed for ws://."
    Write-Host "Install LuaSec to enable wss:// connections."
}
Write-Host "You can now run: .\\run_websocket_host.ps1 -Host 0.0.0.0 -Port 8080 -MatchId \"match1\""
