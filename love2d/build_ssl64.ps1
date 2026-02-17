# build_ssl64.ps1 - Compile 64-bit LuaSec ssl.dll for LOVE
# Run from an x64 Developer Command Prompt (or x64 Native Tools Command Prompt)
#
# Prerequisites:
#   - Visual Studio Build Tools (cl.exe on PATH via vcvarsall x64)
#   - LOVE installed at "C:\Program Files\LOVE\" (provides lua51.dll + headers)
#   - OpenSSL 64-bit at "C:\Program Files\OpenSSL-Win64\"
#   - LuaSec source at "$env:TEMP\luasec-1.3.2\"

param(
    [string]$LuaSecSrc    = "$env:TEMP\luasec-1.3.2",
    [string]$LoveDir      = "C:\Program Files\LOVE",
    [string]$LuaInclude   = "C:\Program Files (x86)\Lua\5.1\include",
    [string]$OpenSSLDir   = "C:\Program Files\OpenSSL-Win64",
    [string]$OutputDir    = "$PSScriptRoot\build\ssl64"
)

$ErrorActionPreference = "Stop"

# Verify cl.exe is available
if (-not (Get-Command cl -ErrorAction SilentlyContinue)) {
    Write-Error "cl.exe not found. Run this script from an x64 Developer Command Prompt."
    exit 1
}

# Verify paths
foreach ($p in @($LuaSecSrc, $LoveDir, $LuaInclude, $OpenSSLDir)) {
    if (-not (Test-Path $p)) {
        Write-Error "Required path not found: $p"
        exit 1
    }
}

# Create output directory
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

# Step 1: Generate lua51.lib from lua51.dll (LOVE doesn't ship a .lib)
$lua51Dll = Join-Path $LoveDir "lua51.dll"
$lua51Lib = Join-Path $OutputDir "lua51.lib"
$lua51Def = Join-Path $OutputDir "lua51.def"

Write-Host "Generating lua51.lib from lua51.dll..."

# Use dumpbin to extract exports, then create .def file
$exports = & dumpbin /exports $lua51Dll 2>&1
$defLines = @("LIBRARY lua51", "EXPORTS")
foreach ($line in $exports) {
    # Match lines like "   1    0 00001234 luaL_addlstring"
    if ($line -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)') {
        $defLines += "  $($Matches[1])"
    }
}
$defLines | Out-File -Encoding ASCII $lua51Def
& lib /nologo /def:$lua51Def /out:$lua51Lib /machine:x64
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create lua51.lib"; exit 1 }

# Step 2: Compile LuaSec
$srcDir = Join-Path $LuaSecSrc "src"
$socketDir = Join-Path $srcDir "luasocket"

$cFiles = @(
    (Join-Path $srcDir "ssl.c"),
    (Join-Path $srcDir "context.c"),
    (Join-Path $srcDir "x509.c"),
    (Join-Path $srcDir "config.c"),
    (Join-Path $srcDir "ec.c"),
    (Join-Path $srcDir "options.c"),
    (Join-Path $socketDir "buffer.c"),
    (Join-Path $socketDir "io.c"),
    (Join-Path $socketDir "timeout.c"),
    (Join-Path $socketDir "wsocket.c")
)

$sslDll = Join-Path $OutputDir "ssl.dll"

Write-Host "Compiling LuaSec (x64)..."
$objFiles = @()
foreach ($c in $cFiles) {
    $baseName = [IO.Path]::GetFileNameWithoutExtension($c)
    $obj = Join-Path $OutputDir "$baseName.obj"
    $objFiles += $obj
    Write-Host "  Compiling $c ..."
    & cl /nologo /c /MD /O2 `
        /DWIN32 /D_WIN32 /DNDEBUG /D_WINDOWS /D_USRDLL /DLUASOCKET_DEBUG /DWITH_LUASOCKET `
        /I"$srcDir" /I"$LuaInclude" /I"$OpenSSLDir\include" `
        /Fo"$obj" "$c"
    if ($LASTEXITCODE -ne 0) { Write-Error "Compilation failed: $c"; exit 1 }
}

Write-Host "Linking ssl.dll..."
$defFile = Join-Path $LuaSecSrc "ssl.def"
$linkArgs = @(
    "/nologo", "/DLL",
    "/OUT:$sslDll",
    "/DEF:$defFile",
    "/LIBPATH:$OutputDir",
    "/LIBPATH:$OpenSSLDir\lib\VC\x64\MD",
    "lua51.lib", "libssl.lib", "libcrypto.lib", "ws2_32.lib"
) + $objFiles
& link @linkArgs
if ($LASTEXITCODE -ne 0) { Write-Error "Linking failed"; exit 1 }

Write-Host ""
Write-Host "SUCCESS: 64-bit ssl.dll built at: $sslDll"
Write-Host ""
Write-Host "To verify architecture:"
Write-Host "  dumpbin /headers ""$sslDll"" | findstr machine"
