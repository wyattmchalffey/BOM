# Run Siegecraft with LÖVE. Use this if "love" is not in your PATH.
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
    Write-Host "LÖVE not found. Install from https://love2d.org/ and run this from the love2d folder."
    Write-Host "Or add LÖVE to your PATH and use: love ."
    exit 1
}
& $love $PSScriptRoot
