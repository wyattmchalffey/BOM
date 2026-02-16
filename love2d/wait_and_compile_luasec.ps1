# Wait for Visual Studio Build Tools installation to complete, then compile LuaSec

Write-Host "Waiting for Visual Studio Build Tools installation to complete..."
$maxWait = 1800 # 30 minutes max
$elapsed = 0
$checkInterval = 30 # Check every 30 seconds

while ($elapsed -lt $maxWait) {
    $process = Get-Process -Name "vs_buildtools" -ErrorAction SilentlyContinue
    if (-not $process) {
        Write-Host "Installation completed!"
        break
    }
    Write-Host "Still installing... ($elapsed seconds elapsed)"
    Start-Sleep -Seconds $checkInterval
    $elapsed += $checkInterval
}

if ($elapsed -ge $maxWait) {
    Write-Host "WARNING: Installation may still be running. Proceeding anyway..."
}

# Check if Build Tools are installed
$buildToolsPath = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
if (-not (Test-Path $buildToolsPath)) {
    Write-Host "ERROR: Build Tools not found at $buildToolsPath"
    exit 1
}

Write-Host "`nSetting up build environment..."

# Find and run vcvars64.bat to set up the build environment
$vcvarsPath = Join-Path $buildToolsPath "VC\Auxiliary\Build\vcvars64.bat"
if (-not (Test-Path $vcvarsPath)) {
    Write-Host "ERROR: vcvars64.bat not found at $vcvarsPath"
    exit 1
}

# Set up environment variables for MSVC
$vsPath = $buildToolsPath
$vcPath = Join-Path $vsPath "VC"
$msvcPath = Get-ChildItem (Join-Path $vcPath "Tools\MSVC") -Directory | Sort-Object Name -Descending | Select-Object -First 1

if ($msvcPath) {
    $binPath = Join-Path $msvcPath.FullName "bin\Hostx64\x64"
    $env:PATH = "$binPath;$env:PATH"
    Write-Host "Added MSVC to PATH: $binPath"
} else {
    Write-Host "WARNING: Could not find MSVC compiler path"
}

# Also try to find cl.exe directly
$clPath = Get-ChildItem -Path "$buildToolsPath\VC\Tools\MSVC" -Recurse -Filter "cl.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if ($clPath) {
    Write-Host "Found cl.exe at: $($clPath.FullName)"
    $clDir = Split-Path $clPath.FullName -Parent
    $env:PATH = "$clDir;$env:PATH"
}

# Verify cl.exe is available
$clCheck = & where.exe cl 2>$null
if ($clCheck) {
    Write-Host "SUCCESS: cl.exe is available at: $clCheck"
} else {
    Write-Host "ERROR: cl.exe not found in PATH"
    Write-Host "Current PATH includes:"
    $env:PATH -split ';' | Where-Object { $_ -like '*Visual Studio*' -or $_ -like '*MSVC*' } | ForEach-Object { Write-Host "  $_" }
    exit 1
}

Write-Host "`nCompiling LuaSec from source..."
Write-Host "This may take a few minutes..."

$luaDir = "C:\Program Files (x86)\Lua\5.1"
$opensslDir = "C:\Program Files\OpenSSL-Win64"

# Compile LuaSec
$luarocksArgs = @(
    "--lua-version=5.1",
    "--lua-dir=$luaDir",
    "install",
    "luasec",
    "OPENSSL_DIR=$opensslDir",
    "OPENSSL_INCDIR=$opensslDir\include",
    "OPENSSL_LIBDIR=$opensslDir\lib\VC\x64\MD"
)

& luarocks @luarocksArgs

if ($LASTEXITCODE -eq 0) {
    Write-Host "`nSUCCESS: LuaSec compiled and installed!"
    
    Write-Host "`nVerifying SSL module..."
    & "$luaDir\lua.exe" -e "require('ssl'); print('ssl ok')"
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nSSL module is working correctly!"
    } else {
        Write-Host "`nWARNING: SSL module test failed"
    }
} else {
    Write-Host "`nERROR: LuaSec compilation failed (exit code: $LASTEXITCODE)"
    exit 1
}
