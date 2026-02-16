param(
    [string]$LuaVersion = "",
    [string]$LuaExePath = "",
    [string]$OpenSSLDir = "",
    [string]$OpenSSLIncDir = "",
    [string]$OpenSSLLibDir = ""
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


$LuaCmd = "lua"
$LuaDir = ""
if (-not [string]::IsNullOrWhiteSpace($LuaExePath)) {
    if (-not (Test-Path $LuaExePath)) {
        Write-Host "Lua executable not found at: $LuaExePath"
        exit 1
    }
    $LuaCmd = $LuaExePath
    $LuaDir = Split-Path -Parent $LuaExePath
    $env:LUA = $LuaExePath
    Write-Host "Using Lua executable: $LuaExePath"
}


if (-not [string]::IsNullOrWhiteSpace($OpenSSLDir)) {
    $env:OPENSSL_DIR = $OpenSSLDir
    Write-Host "Using OPENSSL_DIR=$OpenSSLDir"
}

if (-not [string]::IsNullOrWhiteSpace($OpenSSLIncDir)) {
    $env:OPENSSL_INCDIR = $OpenSSLIncDir
    Write-Host "Using OPENSSL_INCDIR=$OpenSSLIncDir"
}

if (-not [string]::IsNullOrWhiteSpace($OpenSSLLibDir)) {
    $env:OPENSSL_LIBDIR = $OpenSSLLibDir
    Write-Host "Using OPENSSL_LIBDIR=$OpenSSLLibDir"
}

if ([string]::IsNullOrWhiteSpace($env:OPENSSL_INCDIR) -and -not [string]::IsNullOrWhiteSpace($env:OPENSSL_DIR)) {
    $env:OPENSSL_INCDIR = Join-Path $env:OPENSSL_DIR "include"
}

if ([string]::IsNullOrWhiteSpace($env:OPENSSL_LIBDIR) -and -not [string]::IsNullOrWhiteSpace($env:OPENSSL_DIR)) {
    $libCandidates = @(
        (Join-Path $env:OPENSSL_DIR "lib\VC\x64\MD"),
        (Join-Path $env:OPENSSL_DIR "lib\VC\x86\MD"),
        (Join-Path $env:OPENSSL_DIR "lib")
    )
    foreach ($candidate in $libCandidates) {
        if (Test-Path $candidate) {
            $env:OPENSSL_LIBDIR = $candidate
            break
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($LuaExePath) -and [string]::IsNullOrWhiteSpace($LuaVersion)) {
    Write-Host "When -LuaExePath is set, also pass -LuaVersion (for example -LuaVersion 5.3)."
    exit 1
}


function Get-LuaRocksBaseArgs($luaVersion) {
    $args = @()
    if (-not [string]::IsNullOrWhiteSpace($luaVersion)) {
        $args += "--lua-version=$luaVersion"
    }
    if (-not [string]::IsNullOrWhiteSpace($LuaDir)) {
        $args += "--lua-dir=$LuaDir"
    }
    return $args
}

if (-not [string]::IsNullOrWhiteSpace($LuaExePath) -and [string]::IsNullOrWhiteSpace($LuaVersion)) {
    Write-Host "When -LuaExePath is set, also pass -LuaVersion (for example -LuaVersion 5.3)."
    exit 1
}


function Get-LuaRocksBaseArgs($luaVersion) {
    $args = @()
    if (-not [string]::IsNullOrWhiteSpace($luaVersion)) {
        $args += "--lua-version=$luaVersion"
    }
    if (-not [string]::IsNullOrWhiteSpace($LuaDir)) {
        $args += "--lua-dir=$LuaDir"
    }
    return $args
}

function Install-Rock($rockName, $luaVersion) {
    $args = Get-LuaRocksBaseArgs $luaVersion
    $args += "install"
    $args += $rockName

    if ([string]::IsNullOrWhiteSpace($luaVersion)) {
        Write-Host "Installing rock: $rockName"
    }
    else {
        Write-Host "Installing rock: $rockName (Lua $luaVersion)"
    }

    & luarocks @args
    return ($LASTEXITCODE -eq 0)
}

function Install-LuaSec($luaVersion) {
    $args = Get-LuaRocksBaseArgs $luaVersion
    $args += "install"
    $args += "luasec"

    if (-not [string]::IsNullOrWhiteSpace($env:OPENSSL_DIR)) {
        $args += "OPENSSL_DIR=$($env:OPENSSL_DIR)"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:OPENSSL_INCDIR)) {
        $args += "OPENSSL_INCDIR=$($env:OPENSSL_INCDIR)"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:OPENSSL_LIBDIR)) {
        $args += "OPENSSL_LIBDIR=$($env:OPENSSL_LIBDIR)"
    }

    Write-Host "Installing rock: luasec"
    if (-not [string]::IsNullOrWhiteSpace($env:OPENSSL_INCDIR)) {
        Write-Host "  with OPENSSL_INCDIR=$($env:OPENSSL_INCDIR)"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:OPENSSL_LIBDIR)) {
        Write-Host "  with OPENSSL_LIBDIR=$($env:OPENSSL_LIBDIR)"
    }
    & luarocks @args
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


$canBuildLuaSec = Test-Command "cl"
if (-not $canBuildLuaSec) {
    Write-Host "MSVC compiler 'cl' was not found in this shell."
    Write-Host "Open 'x86 Native Tools Command Prompt for VS' (or run vcvarsall.bat x86) before installing LuaSec for Lua 5.1 x86."
}

if ($canBuildLuaSec) {
    $sslInstalled = Install-LuaSec $LuaVersion
}
else {
    $sslInstalled = $false
}
if (-not $sslInstalled) {
    Write-Host "Install of 'luasec' failed; wss:// connections may not work."
    Write-Host "LuaSec builds require OpenSSL headers/libs (for example openssl/ssl.h)."
    Write-Host "If you see OPENSSL errors, install OpenSSL matching your Lua bitness and re-run with:"
    Write-Host '  .\install_multiplayer_dependencies.ps1 -OpenSSLDir "C:\Program Files\OpenSSL-Win32"'
    Write-Host '  (or Win64 path if your Lua is 64-bit)'
}

Write-Host "Verifying SSL module for wss:// support..."
& $LuaCmd -e "local ok,ssl=pcall(require,'ssl'); if ok and ssl then os.exit(0) else os.exit(2) end"
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
    Write-Host "If you get OPENSSL_DIR/openssl/ssl.h errors, install OpenSSL and pass -OpenSSLDir."
    Write-Host "If you get 'The specified procedure could not be found' from ssl51.dll, ensure OpenSSL DLL bitness/version matches LuaSec build and remove stale ssl51.dll before reinstalling."
}

Write-Host "Verifying client websocket module..."
& $LuaCmd -e "local ok = pcall(require, 'websocket'); if ok then os.exit(0) else os.exit(2) end"
if ($LASTEXITCODE -ne 0) {
    Write-Host "Client websocket module verification failed (require('websocket'))."
    exit 1
}

Write-Host "Verifying host websocket backend..."
& $LuaCmd -e "local ok1,m1=pcall(require,'websocket.server.sync'); local ok2,m2=pcall(require,'websocket.server_copas'); local ok3=pcall(require,'copas'); local pass=(ok1 and m1 and type(m1.listen)=='function') or (ok2 and m2 and type(m2.listen)=='function' and ok3); if pass then os.exit(0) else os.exit(2) end"
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
