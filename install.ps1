# install.ps1 - One-time setup for Voice-to-Text
# Run: powershell -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "=== VTT Install ===" -ForegroundColor Cyan
Write-Host ""

# --- Check Python ---
$pythonPath = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $pythonPath) {
    Write-Host "ERROR: Python not found in PATH. Install Python 3.10+ first." -ForegroundColor Red
    exit 1
}
$pythonVersion = & python --version 2>&1
Write-Host "Found: $pythonVersion at $pythonPath" -ForegroundColor Green

# --- Install dependencies ---
Write-Host ""
Write-Host "Installing Python dependencies..." -ForegroundColor Yellow
& python -m pip install --quiet faster-whisper sounddevice scipy numpy
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: pip install failed" -ForegroundColor Red
    exit 1
}
Write-Host "Dependencies installed" -ForegroundColor Green

# --- Update paths in vtt-hotkey.ps1 ---
$helperPath = Join-Path $scriptDir "vtt-helper.py"
$hotkeyPath = Join-Path $scriptDir "vtt-hotkey.ps1"

# Detect the full python path (prefer Program Files over pyenv/store)
$allPythons = (& where.exe python 2>$null) -split "`n" | ForEach-Object { $_.Trim() }
$bestPython = $allPythons | Where-Object { $_ -like "*Program Files*" } | Select-Object -First 1
if (-not $bestPython) { $bestPython = $allPythons | Select-Object -First 1 }

Write-Host ""
Write-Host "Configuring paths..." -ForegroundColor Yellow
Write-Host "  Python: $bestPython"
Write-Host "  Helper: $helperPath"

$content = Get-Content $hotkeyPath -Raw
$content = $content -replace '(?m)^\$PYTHON = .*$', "`$PYTHON = `"$bestPython`""
$content = $content -replace '(?m)^\$HELPER = .*$', "`$HELPER = `"$helperPath`""
Set-Content -Path $hotkeyPath -Value $content -NoNewline
Write-Host "  Updated vtt-hotkey.ps1" -ForegroundColor Green

# --- Create startup shortcut ---
Write-Host ""
Write-Host "Setting up auto-start on login..." -ForegroundColor Yellow
$startupDir = [Environment]::GetFolderPath("Startup")
$vbsPath = Join-Path $startupDir "vtt-hotkey-startup.vbs"
$vbsContent = @"
' Silent launcher for vtt-hotkey.ps1
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File $hotkeyPath", 0, False
"@
Set-Content -Path $vbsPath -Value $vbsContent
Write-Host "  Created: $vbsPath" -ForegroundColor Green

# --- Pre-download the Whisper model ---
Write-Host ""
Write-Host "Pre-downloading Whisper model (base)..." -ForegroundColor Yellow
& python -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8'); print('Model cached')"
if ($LASTEXITCODE -eq 0) {
    Write-Host "Model downloaded" -ForegroundColor Green
} else {
    Write-Host "WARNING: Model download failed, will retry on first use" -ForegroundColor Yellow
}

# --- Done ---
Write-Host ""
Write-Host "=== Installation complete! ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "To start now:"
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$hotkeyPath`""
Write-Host ""
Write-Host "It will auto-start on next Windows login."
Write-Host "Hotkey: Ctrl+Shift+Enter (toggle recording)"
