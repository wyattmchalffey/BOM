# Fix wss:// support - Run as Administrator
# This script ensures all dependencies are correctly installed

$luaDir = "C:\Program Files (x86)\Lua\5.1"
$clibsDir = Join-Path $luaDir "clibs"
$opensslBin = "C:\Program Files (x86)\OpenSSL-Win32\bin"
$luasecSrc = "C:\Users\Wyatt\AppData\Local\Temp\luasec-1.3.2"

Write-Host "=== Fixing wss:// Support ===" -ForegroundColor Cyan
Write-Host ""

# 1. Copy SSL DLL
Write-Host "1. Installing ssl51.dll..." -ForegroundColor Yellow
$dllSource = Join-Path $luasecSrc "ssl.dll"
$dllDest = Join-Path $clibsDir "ssl51.dll"
if (Test-Path $dllSource) {
    Copy-Item $dllSource -Destination $dllDest -Force
    Write-Host "   ✓ ssl51.dll installed" -ForegroundColor Green
} else {
    Write-Host "   ✗ ERROR: ssl.dll not found" -ForegroundColor Red
    exit 1
}

# 2. Copy OpenSSL DLLs
Write-Host "`n2. Installing OpenSSL DLLs..." -ForegroundColor Yellow
$opensslDlls = @("libssl-3.dll", "libcrypto-3.dll")
foreach ($dllName in $opensslDlls) {
    $src = Join-Path $opensslBin $dllName
    $dest = Join-Path $clibsDir $dllName
    if (Test-Path $src) {
        Copy-Item $src -Destination $dest -Force
        Write-Host "   ✓ $dllName installed" -ForegroundColor Green
    } else {
        Write-Host "   ✗ $dllName not found" -ForegroundColor Red
    }
}

# 3. Create lua51.dll (SSL DLL expects this name)
Write-Host "`n3. Creating lua51.dll link..." -ForegroundColor Yellow
$lua51Src = Join-Path $luaDir "lua5.1.dll"
$lua51Dest = Join-Path $clibsDir "lua51.dll"
if (Test-Path $lua51Src) {
    Copy-Item $lua51Src -Destination $lua51Dest -Force
    Write-Host "   ✓ lua51.dll created" -ForegroundColor Green
} else {
    Write-Host "   ✗ lua5.1.dll not found" -ForegroundColor Red
}

# 4. Copy Lua files
Write-Host "`n4. Installing Lua files..." -ForegroundColor Yellow
$luaFiles = @(
    @{Source = "src\ssl.lua"; Dest = "ssl.lua"},
    @{Source = "src\https.lua"; Dest = "https.lua"}
)
foreach ($file in $luaFiles) {
    $src = Join-Path $luasecSrc $file.Source
    $dest = Join-Path $luaDir $file.Dest
    if (Test-Path $src) {
        Copy-Item $src -Destination $dest -Force
        Write-Host "   ✓ $($file.Dest) installed" -ForegroundColor Green
    }
}

# 5. Test
Write-Host "`n5. Testing SSL module..." -ForegroundColor Yellow
$luaExe = Join-Path $luaDir "lua.exe"
$env:Path = "$opensslBin;$env:Path"
$testResult = & $luaExe -e "local ok,m=pcall(require,'ssl'); if ok and m then print('SUCCESS') else print('FAILED:', m) end" 2>&1

if ($testResult -match "SUCCESS") {
    Write-Host "   ✓ SSL module loaded successfully!" -ForegroundColor Green
    Write-Host "`n=== wss:// Support is Ready! ===" -ForegroundColor Green
} else {
    Write-Host "   ✗ SSL module failed" -ForegroundColor Red
    Write-Host "   Error: $testResult" -ForegroundColor Red
}

Write-Host "`nDone!" -ForegroundColor Cyan
