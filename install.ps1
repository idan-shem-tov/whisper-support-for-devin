# install.ps1 - One-time setup for Voice-to-Text
# Handles everything: checks Python, installs deps, configures paths,
# sets up auto-start, downloads model, creates default config, and starts VTT.
#
# Run: powershell -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host ""
Write-Host "  VTT - Voice-to-Text Installer" -ForegroundColor Cyan
Write-Host "  ==============================" -ForegroundColor Cyan
Write-Host ""

# --- 1. Check Python ---
Write-Host "[1/6] Checking Python..." -ForegroundColor Yellow
$pythonPath = (Get-Command python -ErrorAction SilentlyContinue).Source
if (-not $pythonPath) {
    Write-Host "  ERROR: Python not found in PATH." -ForegroundColor Red
    Write-Host "  Install Python 3.10+ from https://www.python.org/downloads/" -ForegroundColor Red
    Write-Host "  Make sure to check 'Add Python to PATH' during installation." -ForegroundColor Red
    exit 1
}
$pythonVersion = & python --version 2>&1
Write-Host "  $pythonVersion" -ForegroundColor Green

# --- 2. Install dependencies ---
Write-Host "[2/6] Installing Python packages..." -ForegroundColor Yellow
& python -m pip install --quiet --upgrade pip 2>$null
& python -m pip install --quiet faster-whisper sounddevice scipy numpy
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ERROR: pip install failed. Try running as administrator." -ForegroundColor Red
    exit 1
}
Write-Host "  Dependencies installed" -ForegroundColor Green

# --- 3. Configure paths in vtt-hotkey.ps1 ---
Write-Host "[3/6] Configuring paths..." -ForegroundColor Yellow
$helperPath = Join-Path $scriptDir "vtt-helper.py"
$hotkeyPath = Join-Path $scriptDir "vtt-hotkey.ps1"
$vttPath = Join-Path $scriptDir "vtt.ps1"

# Detect the best python path (prefer Program Files over pyenv/store)
$allPythons = (& where.exe python 2>$null) -split "`n" | ForEach-Object { $_.Trim() }
$bestPython = $allPythons | Where-Object { $_ -like "*Program Files*" } | Select-Object -First 1
if (-not $bestPython) { $bestPython = $allPythons | Select-Object -First 1 }

$content = Get-Content $hotkeyPath -Raw
$content = $content -replace '(?m)^\$PYTHON = .*$', "`$PYTHON = `"$bestPython`""
$content = $content -replace '(?m)^\$HELPER = .*$', "`$HELPER = `"$helperPath`""
Set-Content -Path $hotkeyPath -Value $content -NoNewline
Write-Host "  Python: $bestPython" -ForegroundColor Green

# --- 4. Create default config.ini if missing ---
Write-Host "[4/6] Checking configuration..." -ForegroundColor Yellow
$configPath = Join-Path $scriptDir "config.ini"
if (!(Test-Path $configPath)) {
    @"
[vtt]
# Whisper model: tiny, base, small, medium
model = base

# Language: auto (auto-detect), en, he, es, fr, de, etc.
language = en

# Sound feedback on start/stop recording: on or off
sound = on
"@ | Set-Content -Path $configPath
    Write-Host "  Created default config.ini" -ForegroundColor Green
} else {
    Write-Host "  config.ini already exists" -ForegroundColor Green
}

# --- 5. Set up auto-start on login ---
Write-Host "[5/6] Setting up auto-start on login..." -ForegroundColor Yellow

# Use Registry Run key — same mechanism as Teams, OneDrive, Edge.
# The Startup folder is ignored on many corporate machines (Group Policy),
# and VBScript (.vbs) is deprecated in Windows 11 24H2+.
$runKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$launcherPath = Join-Path $scriptDir "vtt-startup.ps1"
$runValue = "conhost.exe --headless -- powershell.exe -ExecutionPolicy Bypass -NoProfile -File `"$launcherPath`""
Set-ItemProperty -Path $runKey -Name "VTT-VoiceToText" -Value $runValue
Write-Host "  Auto-start enabled (Registry Run key)" -ForegroundColor Green

# --- 6. Pre-download model + start VTT ---
Write-Host "[6/6] Downloading Whisper model and starting VTT..." -ForegroundColor Yellow
& python -c "from faster_whisper import WhisperModel; WhisperModel('base', device='cpu', compute_type='int8'); print('  Model cached')"
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Model will download on first use" -ForegroundColor Yellow
}

# Start VTT now
& powershell -ExecutionPolicy Bypass -File $vttPath start

Write-Host ""
Write-Host "  Installation complete!" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Hotkey:    Ctrl+Shift+Enter (toggle recording)" -ForegroundColor White
Write-Host "  Config:    $configPath" -ForegroundColor Gray
Write-Host "  Manage:    powershell -ExecutionPolicy Bypass -File $vttPath [start|stop|restart|status|logs]" -ForegroundColor Gray
Write-Host "  Auto-start is enabled (runs on Windows login)" -ForegroundColor Gray
Write-Host ""
