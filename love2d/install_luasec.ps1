# Install LuaSec DLL and Lua files
$luaDir = "C:\Program Files (x86)\Lua\5.1"
$clibsDir = Join-Path $luaDir "clibs"
$tempDir = "$env:TEMP\luasec"

Write-Host "Installing LuaSec files..."
Write-Host "Lua directory: $luaDir"
Write-Host "CLibs directory: $clibsDir"

# Ensure clibs directory exists
if (-not (Test-Path $clibsDir)) {
    New-Item -ItemType Directory -Path $clibsDir -Force | Out-Null
    Write-Host "Created clibs directory"
}

# Copy DLL (use ssl51.dll for Lua 5.1)
$dllSource = Join-Path $tempDir "lib32\ssl.dll"
$dllDest = Join-Path $clibsDir "ssl51.dll"
if (Test-Path $dllSource) {
    Copy-Item $dllSource -Destination $dllDest -Force
    Write-Host "Copied: ssl51.dll"
} else {
    Write-Host "ERROR: DLL not found at $dllSource"
}

# Copy Lua files
$luaSource = Join-Path $tempDir "modules\ssl.lua"
$luaDest = Join-Path $luaDir "ssl.lua"
if (Test-Path $luaSource) {
    Copy-Item $luaSource -Destination $luaDest -Force
    Write-Host "Copied: ssl.lua"
}

$httpsSource = Join-Path $tempDir "modules\ssl\https.lua"
$httpsDest = Join-Path $luaDir "https.lua"
if (Test-Path $httpsSource) {
    Copy-Item $httpsSource -Destination $httpsDest -Force
    Write-Host "Copied: https.lua"
}

# Copy OpenSSL DLLs (needed by LuaSec) - use 32-bit version for 32-bit Lua
# LuaSec was compiled against OpenSSL 3.3.1, so prefer that version
$opensslBin331 = "C:\Program Files (x86)\OpenSSL-Win32\bin"
$opensslBin361 = "C:\Program Files (x86)\OpenSSL-Win32\bin"
$opensslBin64 = "C:\Program Files\OpenSSL-Win64\bin"
$clibsDir = Join-Path $luaDir "clibs"

# Try OpenSSL 3.3.1 first (matches LuaSec binary), then fallback
$opensslBin = if (Test-Path $opensslBin331) { $opensslBin331 } 
              elseif (Test-Path $opensslBin361) { $opensslBin361 }
              else { $opensslBin64 }

Write-Host "`nCopying OpenSSL DLLs..."
Get-ChildItem $opensslBin -Filter "libssl*.dll" | ForEach-Object {
    Copy-Item $_.FullName -Destination $clibsDir -Force
    Write-Host "Copied: $($_.Name)"
}
Get-ChildItem $opensslBin -Filter "libcrypto*.dll" | ForEach-Object {
    Copy-Item $_.FullName -Destination $clibsDir -Force
    Write-Host "Copied: $($_.Name)"
}

Write-Host "`nVerifying installation..."
if (Test-Path $dllDest) {
    Write-Host "SUCCESS: ssl51.dll installed"
} else {
    Write-Host "ERROR: ssl51.dll not found"
}

Write-Host "`nTesting SSL module..."
& "$luaDir\lua.exe" -e "require('ssl'); print('ssl ok')"
