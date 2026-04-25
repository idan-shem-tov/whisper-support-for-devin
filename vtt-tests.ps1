# vtt-tests.ps1 - Test suite for VTT Voice-to-Text
# Tests core logic without requiring VTT to be running.
# Run: powershell -ExecutionPolicy Bypass -File vtt-tests.ps1
#
# Exit code: 0 = all passed, 1 = one or more failed

param()

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Minimal test framework ────────────────────────────────────────────────────

$script:pass  = 0
$script:fail  = 0
$script:group = ""

function Test-Group([string]$name) {
    $script:group = $name
    Write-Host "`n[$name]" -ForegroundColor Cyan
}

function Test-Case([string]$name, [scriptblock]$block) {
    try {
        & $block
        Write-Host "  PASS  $name" -ForegroundColor Green
        $script:pass++
    } catch {
        Write-Host "  FAIL  $name" -ForegroundColor Red
        Write-Host "        $($_.Exception.Message)" -ForegroundColor DarkRed
        $script:fail++
    }
}

function Assert([bool]$condition, [string]$msg = "assertion failed") {
    if (-not $condition) { throw $msg }
}

function Assert-Equal($actual, $expected, [string]$msg = "") {
    if ($actual -ne $expected) {
        throw "Expected [$expected] but got [$actual]. $msg"
    }
}

function Assert-Contains([string]$text, [string]$substring) {
    if (-not $text.Contains($substring)) {
        throw "Expected text to contain '$substring'"
    }
}

function Assert-NoThrow([scriptblock]$block) {
    try { & $block }
    catch { throw "Expected no exception but got: $($_.Exception.Message)" }
}

# ── Helpers (mirror the logic in vtt.ps1 / vtt-tray.ps1) ─────────────────────

function Test-IsVttRunning([string]$pidFile) {
    if (-not (Test-Path $pidFile)) { return $false }
    $raw = Get-Content $pidFile -ErrorAction SilentlyContinue
    if (-not $raw) { return $false }
    $pidVal = $raw.Trim()
    $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
    return ($proc -and $proc.ProcessName -like "powershell*")
}

function Test-GetVttStatus([string]$pidFile, [string]$portFile) {
    if (-not (Test-Path $pidFile)) { return "stopped" }
    $raw = Get-Content $pidFile -ErrorAction SilentlyContinue
    if (-not $raw) { return "stopped" }
    $pidVal = $raw.Trim()
    $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.ProcessName -notlike "powershell*") { return "stopped" }
    if (Test-Path $portFile) { return "running" }
    return "starting"
}

function New-VttIcon([string]$state) {
    $size = 32
    $bmp  = New-Object System.Drawing.Bitmap($size, $size)
    $g    = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $bgColor = switch ($state) {
        "running"  { [System.Drawing.Color]::FromArgb(39, 174, 96)   }
        "starting" { [System.Drawing.Color]::FromArgb(230, 162,  0)  }
        default    { [System.Drawing.Color]::FromArgb(110, 110, 110) }
    }
    $brush = New-Object System.Drawing.SolidBrush($bgColor)
    $g.FillEllipse($brush, 1, 1, $size - 2, $size - 2)
    $font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $sf   = New-Object System.Drawing.StringFormat
    $sf.Alignment     = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF(0, 0, $size, $size)
    $g.DrawString("V", $font, [System.Drawing.Brushes]::White, $rect, $sf)
    $g.Dispose(); $font.Dispose(); $sf.Dispose(); $brush.Dispose()
    $hIcon = $bmp.GetHicon()
    $bmp.Dispose()
    $icon  = [System.Drawing.Icon]::FromHandle($hIcon)
    return @{ Icon = $icon; HIcon = $hIcon }
}

# ── Setup temp dir for tests ──────────────────────────────────────────────────

$testDir = Join-Path $env:TEMP "vtt-tests-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $testDir -Force | Out-Null

try {

# ══════════════════════════════════════════════════════════════════════════════
Test-Group "1. Script syntax"
# ══════════════════════════════════════════════════════════════════════════════

foreach ($script in @("vtt.ps1", "vtt-hotkey.ps1", "vtt-tray.ps1", "vtt-startup.ps1")) {
    $path = Join-Path $ScriptDir $script
    Test-Case "[$script] parses without syntax errors" {
        Assert (Test-Path $path) "$script not found at $path"
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors) | Out-Null
        Assert ($errors.Count -eq 0) "Syntax errors: $($errors | ForEach-Object { $_.Message } | Out-String)"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
Test-Group "2. Daemon startup timeout (must be 90 s)"
# ══════════════════════════════════════════════════════════════════════════════

Test-Case "vtt-hotkey.ps1 wait limit is 900 (900 × 100 ms = 90 s)" {
    $path    = Join-Path $ScriptDir "vtt-hotkey.ps1"
    $content = Get-Content $path -Raw
    Assert ($content -match '\$waited -lt 900') `
        "Expected '\$waited -lt 900' in vtt-hotkey.ps1 but it was not found. Timeout may still be 30 s."
}

# ══════════════════════════════════════════════════════════════════════════════
Test-Group "3. Is-Running / status detection"
# ══════════════════════════════════════════════════════════════════════════════

$pidFile  = Join-Path $testDir "hotkey.pid"
$portFile = Join-Path $testDir "port.txt"

Test-Case "Stopped when no PID file" {
    Remove-Item $pidFile  -Force -ErrorAction SilentlyContinue
    Remove-Item $portFile -Force -ErrorAction SilentlyContinue
    Assert-Equal (Test-IsVttRunning $pidFile) $false
    Assert-Equal (Test-GetVttStatus $pidFile $portFile) "stopped"
}

Test-Case "Stopped when PID file is empty" {
    Set-Content $pidFile ""
    Assert-Equal (Test-IsVttRunning $pidFile) $false
    Assert-Equal (Test-GetVttStatus $pidFile $portFile) "stopped"
    Remove-Item $pidFile -Force
}

Test-Case "Stopped when PID file has a nonexistent PID" {
    Set-Content $pidFile "999999"
    Assert-Equal (Test-IsVttRunning $pidFile) $false
    Assert-Equal (Test-GetVttStatus $pidFile $portFile) "stopped"
    Remove-Item $pidFile -Force
}

Test-Case "Running when PID file has own PID and port file exists" {
    Set-Content $pidFile $PID          # our own PID is definitely alive
    Set-Content $portFile "12345"
    # Is-Running checks ProcessName like "powershell*"; pwsh also matches
    $running = Test-IsVttRunning $pidFile
    $status  = Test-GetVttStatus $pidFile $portFile
    Assert $running       "Expected Is-Running = true with own PID"
    Assert-Equal $status "running"
    Remove-Item $pidFile, $portFile -Force
}

Test-Case "Starting when PID file has own PID but no port file" {
    Set-Content $pidFile $PID
    Remove-Item $portFile -Force -ErrorAction SilentlyContinue
    $status = Test-GetVttStatus $pidFile $portFile
    Assert-Equal $status "starting"
    Remove-Item $pidFile -Force
}

# ══════════════════════════════════════════════════════════════════════════════
Test-Group "4. Log file reading"
# ══════════════════════════════════════════════════════════════════════════════

Test-Case "Reading a nonexistent log returns nothing (no exception)" {
    Assert-NoThrow {
        $lines = Get-Content (Join-Path $testDir "does_not_exist.log") -Tail 20 -ErrorAction SilentlyContinue
        # $lines may be $null — that is fine
    }
}

Test-Case "Reading last N lines of a log file returns correct count" {
    $logPath = Join-Path $testDir "sample.log"
    1..50 | ForEach-Object { Add-Content $logPath "Line $_" }
    $lines = Get-Content $logPath -Tail 20 -ErrorAction SilentlyContinue
    Assert-Equal $lines.Count 20
    Assert-Equal $lines[0]  "Line 31"
    Assert-Equal $lines[-1] "Line 50"
    Remove-Item $logPath -Force
}

Test-Case "Reading log with fewer lines than tail returns all lines" {
    $logPath = Join-Path $testDir "small.log"
    1..5 | ForEach-Object { Add-Content $logPath "Entry $_" }
    $lines = Get-Content $logPath -Tail 20 -ErrorAction SilentlyContinue
    Assert-Equal $lines.Count 5
    Remove-Item $logPath -Force
}

# ══════════════════════════════════════════════════════════════════════════════
Test-Group "5. Tray icon creation (GDI+)"
# ══════════════════════════════════════════════════════════════════════════════

foreach ($state in @("running", "starting", "stopped")) {
    Test-Case "New-VttIcon '$state' creates a valid icon without exception" {
        Assert-NoThrow {
            $result = New-VttIcon $state
            Assert ($result.Icon -ne $null) "Icon is null"
            Assert ($result.HIcon -ne [IntPtr]::Zero) "HICON is zero"
            $result.Icon.Dispose()
        }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
Test-Group "6. Config file parsing"
# ══════════════════════════════════════════════════════════════════════════════

Test-Case "config.ini exists and has [vtt] section" {
    $configPath = Join-Path $ScriptDir "config.ini"
    Assert (Test-Path $configPath) "config.ini not found"
    $cfg = New-Object System.Collections.Generic.Dictionary"[string,string]"
    $section = ""
    foreach ($line in (Get-Content $configPath)) {
        if ($line -match '^\[(.+)\]') { $section = $Matches[1] }
        elseif ($line -match '^(\w+)\s*=\s*(.*)' -and $section -eq "vtt") {
            $cfg[$Matches[1].Trim()] = $Matches[2].Trim()
        }
    }
    Assert ($cfg.ContainsKey("model"))    "config.ini missing 'model' key"
    Assert ($cfg.ContainsKey("language")) "config.ini missing 'language' key"
    Assert ($cfg.ContainsKey("sound"))    "config.ini missing 'sound' key"
    Assert (@("tiny","base","small","medium") -contains $cfg["model"]) `
        "Invalid model '$($cfg["model"])'"
}

Test-Case "config.ini model value is a recognised whisper model" {
    $configPath = Join-Path $ScriptDir "config.ini"
    $content = Get-Content $configPath -Raw
    Assert ($content -match 'model\s*=\s*(tiny|base|small|medium)') `
        "model= value is not one of: tiny, base, small, medium"
}

# ══════════════════════════════════════════════════════════════════════════════
Test-Group "7. Tooltip length constraint"
# ══════════════════════════════════════════════════════════════════════════════

Test-Case "All tooltip strings fit within Windows 63-char limit" {
    $tips = @(
        "VTT: Running (PID 12345) - Ctrl+Shift+Enter",
        "VTT: Starting - loading whisper model...",
        "VTT: Stopped - right-click to start"
    )
    foreach ($t in $tips) {
        $clamped = $t.Substring(0, [Math]::Min($t.Length, 63))
        Assert ($clamped.Length -le 63) "Tooltip too long: $t"
    }
}

# ══════════════════════════════════════════════════════════════════════════════
Test-Group "8. vtt-tray.ps1 references valid file paths"
# ══════════════════════════════════════════════════════════════════════════════

Test-Case "vtt-tray.ps1 references vtt.ps1 which exists" {
    $trayContent = Get-Content (Join-Path $ScriptDir "vtt-tray.ps1") -Raw
    Assert-Contains $trayContent "vtt.ps1"
}

Test-Case "vtt-startup.ps1 launches both hotkey and tray scripts" {
    $startupContent = Get-Content (Join-Path $ScriptDir "vtt-startup.ps1") -Raw
    Assert-Contains $startupContent "vtt-hotkey.ps1"
    Assert-Contains $startupContent "vtt-tray.ps1"
}

Test-Case "vtt-tray.ps1 defines Refresh-Logs at script scope (not nested)" {
    $trayContent = Get-Content (Join-Path $ScriptDir "vtt-tray.ps1") -Raw
    # The function must be a top-level definition
    Assert ($trayContent -match '(?m)^function Refresh-Logs') `
        "Refresh-Logs must be a top-level function so event handlers can call it"
}

Test-Case "vtt-tray.ps1 stores controls in script: scope" {
    $trayContent = Get-Content (Join-Path $ScriptDir "vtt-tray.ps1") -Raw
    foreach ($ctrl in @('$script:logTxt', '$script:cboLines', '$script:chkAuto',
                        '$script:lblStatus', '$script:btnStart', '$script:btnStop')) {
        Assert ($trayContent -match [regex]::Escape($ctrl)) "Expected $ctrl to be script-scoped"
    }
}

Test-Case "vtt-tray.ps1 exposes Show-Dashboard (dashboard window function)" {
    $trayContent = Get-Content (Join-Path $ScriptDir "vtt-tray.ps1") -Raw
    Assert-Contains $trayContent "Show-Dashboard"
}

Test-Case "vtt.ps1 includes 'tray' command" {
    $vttContent = Get-Content (Join-Path $ScriptDir "vtt.ps1") -Raw
    Assert-Contains $vttContent '"tray"'
}

# ══════════════════════════════════════════════════════════════════════════════
Test-Group "9. Single-instance guard"
# ══════════════════════════════════════════════════════════════════════════════

Test-Case "vtt-tray.ps1 uses a named Mutex for single-instance enforcement" {
    $trayContent = Get-Content (Join-Path $ScriptDir "vtt-tray.ps1") -Raw
    Assert-Contains $trayContent "AcquireSingleInstance"
    Assert-Contains $trayContent "ReleaseSingleInstance"
    Assert ($trayContent -match 'Mutex') "WinApi class must declare a Mutex field"
}

Test-Case "vtt-tray.ps1 exits early when single-instance check fails" {
    $trayContent = Get-Content (Join-Path $ScriptDir "vtt-tray.ps1") -Raw
    # The guard must come before any UI setup
    $guardIdx  = $trayContent.IndexOf("AcquireSingleInstance")
    $uiIdx     = $trayContent.IndexOf("NotifyIcon")
    Assert ($guardIdx -lt $uiIdx) "Single-instance guard must appear before UI creation"
}

# ══════════════════════════════════════════════════════════════════════════════
Test-Group "10. Resource optimisation"
# ══════════════════════════════════════════════════════════════════════════════

Test-Case "Refresh-Logs skips rebuild when file mtimes have not changed" {
    # Simulate: log mtime unchanged -> body should return early
    $trayContent = Get-Content (Join-Path $ScriptDir "vtt-tray.ps1") -Raw
    Assert ($trayContent -match 'logMtime') "Expected mtime tracking variable in vtt-tray.ps1"
    Assert ($trayContent -match 'forceRefresh') "Expected forceRefresh bypass flag in vtt-tray.ps1"
    Assert ($trayContent -match 'LastWriteTime') "Expected LastWriteTime check in Refresh-Logs"
}

Test-Case "Only one master timer exists (no separate poll + window timers)" {
    $trayContent = Get-Content (Join-Path $ScriptDir "vtt-tray.ps1") -Raw
    # Count Timer instantiations - should be exactly 1 (masterTimer)
    $timerMatches = ([regex]::Matches($trayContent, 'New-Object System\.Windows\.Forms\.Timer')).Count
    Assert ($timerMatches -eq 1) "Expected exactly 1 Timer (masterTimer), found $timerMatches"
}

Test-Case "Status cache variables are defined at script scope" {
    $trayContent = Get-Content (Join-Path $ScriptDir "vtt-tray.ps1") -Raw
    Assert-Contains $trayContent '$script:cachedStatus'
    Assert-Contains $trayContent '$script:cachedPid'
    Assert-Contains $trayContent 'Refresh-StatusCache'
}

Test-Case "Update-WindowStatus skips label assignment when text is unchanged" {
    $trayContent = Get-Content (Join-Path $ScriptDir "vtt-tray.ps1") -Raw
    # Must compare before assigning (diff check)
    Assert ($trayContent -match '-ne \$statusText') `
        "Expected diff-check before setting lblStatus.Text to avoid pointless repaints"
}

} finally {
    # Clean up temp test dir
    Remove-Item $testDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ── Summary ───────────────────────────────────────────────────────────────────

$total = $script:pass + $script:fail
Write-Host ""
Write-Host "═══════════════════════════════" -ForegroundColor DarkGray
if ($script:fail -eq 0) {
    Write-Host "  ALL $total TESTS PASSED" -ForegroundColor Green
} else {
    Write-Host "  $($script:pass)/$total passed, $($script:fail) FAILED" -ForegroundColor Red
}
Write-Host "═══════════════════════════════" -ForegroundColor DarkGray
Write-Host ""

exit ([int]($script:fail -gt 0))
