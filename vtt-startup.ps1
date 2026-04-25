# vtt-startup.ps1 - Silent launcher for VTT (no visible window)
# Called from Registry Run key at login.
# Starts the hotkey listener and the system tray UI.
$hotkey = Join-Path $PSScriptRoot "vtt-hotkey.ps1"
$tray   = Join-Path $PSScriptRoot "vtt-tray.ps1"
Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$hotkey`"" -WindowStyle Hidden
Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$tray`""   -WindowStyle Hidden
