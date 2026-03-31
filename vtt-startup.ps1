# vtt-startup.ps1 - Silent launcher for VTT (no visible window)
# Called from Registry Run key at login.
# Uses Start-Process -WindowStyle Hidden to create a fully detached,
# windowless process — same mechanism as 'vtt.ps1 start'.
$hotkey = Join-Path $PSScriptRoot "vtt-hotkey.ps1"
Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$hotkey`"" -WindowStyle Hidden
