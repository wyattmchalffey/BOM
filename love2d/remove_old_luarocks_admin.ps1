# Run this script as Administrator to remove the old LuaRocks and make 3.13.0 the only version.
# Right-click PowerShell -> Run as Administrator, then: .\remove_old_luarocks_admin.ps1

$oldLuaRocks = "C:\Program Files (x86)\LuaRocks"
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$entries = $machinePath -split ';' | Where-Object { $_ -and $_ -ne $oldLuaRocks -and $_ -notlike "*LuaRocks*" }
$newMachinePath = ($entries -join ';')
if ($newMachinePath -ne $machinePath) {
  [Environment]::SetEnvironmentVariable("Path", $newMachinePath, "Machine")
  Write-Host "Removed old LuaRocks from system PATH."
} else {
  Write-Host "Old LuaRocks was not in system PATH."
}

if (Test-Path $oldLuaRocks) {
  Remove-Item $oldLuaRocks -Recurse -Force
  Write-Host "Deleted folder: $oldLuaRocks"
} else {
  Write-Host "Folder already gone: $oldLuaRocks"
}

Write-Host "Done. Close and reopen terminals; 'luarocks' will be the 3.13.0 version only."
