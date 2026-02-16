# Install LuaSec DLL and dependencies with admin rights
# Run this script as Administrator

$luaDir = "C:\Program Files (x86)\Lua\5.1"
$clibsDir = Join-Path $luaDir "clibs"
$opensslBin = "C:\Program Files (x86)\OpenSSL-Win32\bin"
$luasecSrc = "C:\Users\Wyatt\AppData\Local\Temp\luasec-1.3.2"

Write-Host "Installing LuaSec for wss:// support..."
Write-Host "Lua directory: $luaDir"
Write-Host "CLibs directory: $clibsDir"

# Ensure clibs directory exists
if (-not (Test-Path $clibsDir)) {
    New-Item -ItemType Directory -Path $clibsDir -Force | Out-Null
    Write-Host "Created clibs directory"
}

# Copy SSL DLL
$dllSource = Join-Path $luasecSrc "ssl.dll"
$dllDest = Join-Path $clibsDir "ssl51.dll"
if (Test-Path $dllSource) {
    Copy-Item $dllSource -Destination $dllDest -Force
    Write-Host "✓ Copied ssl51.dll"
} else {
    Write-Host "✗ ERROR: ssl.dll not found at $dllSource"
    exit 1
}

# Copy OpenSSL DLLs (required dependencies)
Write-Host "`nCopying OpenSSL DLLs..."
Get-ChildItem $opensslBin -Filter "libssl*.dll" | ForEach-Object {
    Copy-Item $_.FullName -Destination $clibsDir -Force
    Write-Host "  ✓ Copied $($_.Name)"
}
Get-ChildItem $opensslBin -Filter "libcrypto*.dll" | ForEach-Object {
    Copy-Item $_.FullName -Destination $clibsDir -Force
    Write-Host "  ✓ Copied $($_.Name)"
}

# Copy Lua files
Write-Host "`nCopying Lua files..."
$luaFiles = @(
    @{Source = "src\ssl.lua"; Dest = "ssl.lua"},
    @{Source = "src\https.lua"; Dest = "https.lua"}
)

foreach ($file in $luaFiles) {
    $src = Join-Path $luasecSrc $file.Source
    $dest = Join-Path $luaDir $file.Dest
    if (Test-Path $src) {
        Copy-Item $src -Destination $dest -Force
        Write-Host "  ✓ Copied $($file.Dest)"
    }
}

Write-Host "`n=== Verification ==="
if (Test-Path $dllDest) {
    $dll = Get-Item $dllDest
    Write-Host "✓ ssl51.dll installed ($([math]::Round($dll.Length/1KB, 2)) KB)"
} else {
    Write-Host "✗ ssl51.dll not found"
}

Write-Host "`nTesting SSL module..."
$luaExe = Join-Path $luaDir "lua.exe"
& $luaExe -e "local ok,m=pcall(require,'ssl'); if ok and m then print('✓ SSL module loaded successfully!') else print('✗ SSL module failed:', m) end"

Write-Host "`nDone! wss:// support should now be available."
