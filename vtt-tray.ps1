# vtt-tray.ps1 - System Tray UI for VTT Voice-to-Text
# Single-instance: launching a second copy silently exits.
# Dashboard: double-click the tray icon, or choose "Open Dashboard" from the menu.
# Resource-efficient: status cached, logs only re-read when files change.
# Run: powershell -ExecutionPolicy Bypass -WindowStyle Hidden -File vtt-tray.ps1

param()

$VTT_DIR     = Join-Path $env:TEMP "vtt"
$PID_FILE    = Join-Path $VTT_DIR "hotkey.pid"
$PORT_FILE   = Join-Path $VTT_DIR "port.txt"
$LOG_FILE    = Join-Path $VTT_DIR "debug.log"
$HELPER_LOG  = Join-Path $VTT_DIR "helper.log"
$VTT_SCRIPT  = Join-Path $PSScriptRoot "vtt.ps1"
$CONFIG_FILE = Join-Path $PSScriptRoot "config.ini"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# WinApi helpers: DestroyIcon + named-Mutex for single-instance enforcement
Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class WinApi {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);

    private static Mutex _mutex;
    public static bool AcquireSingleInstance(string name) {
        bool created;
        _mutex = new Mutex(true, name, out created);
        if (!created) _mutex.Dispose();
        return created;   // false = another copy already owns the mutex
    }
    public static void ReleaseSingleInstance() {
        if (_mutex != null) {
            try { _mutex.ReleaseMutex(); } catch {}
            _mutex.Dispose();
            _mutex = null;
        }
    }
}
"@

# ── Single-instance guard ─────────────────────────────────────────────────────
if (-not [WinApi]::AcquireSingleInstance("Local\VTT-Tray-v1")) {
    # Another tray is already running – exit silently
    exit 0
}

# ── Status detection ──────────────────────────────────────────────────────────

function Get-VttStatus {
    if (-not (Test-Path $PID_FILE)) { return "stopped" }
    $raw = Get-Content $PID_FILE -ErrorAction SilentlyContinue
    if (-not $raw) { return "stopped" }
    $pidVal = $raw.Trim()
    $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
    if (-not $proc -or $proc.ProcessName -notlike "powershell*") { return "stopped" }
    if (Test-Path $PORT_FILE) { return "running" }
    return "starting"
}

function Get-VttPid {
    if (Test-Path $PID_FILE) {
        $raw = Get-Content $PID_FILE -ErrorAction SilentlyContinue
        if ($raw) { return $raw.Trim() }
    }
    return $null
}

function Invoke-VttCommand([string]$cmd) {
    if (-not (Test-Path $VTT_SCRIPT)) {
        [System.Windows.Forms.MessageBox]::Show(
            "vtt.ps1 not found:`n$VTT_SCRIPT", "VTT Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    Start-Process powershell `
        -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$VTT_SCRIPT`" $cmd" `
        -WindowStyle Hidden
}

# ── Shared status cache (one Get-Process call per 3 s, shared by tray + window)
$script:cachedStatus = "stopped"
$script:cachedPid    = $null

function Refresh-StatusCache {
    $script:cachedStatus = Get-VttStatus
    $script:cachedPid    = Get-VttPid
}

# ── Tray icon factory ─────────────────────────────────────────────────────────

$script:activeHIcon = [IntPtr]::Zero

# Color palette (used by both icon factory and dashboard)
$COLOR_RUNNING  = [System.Drawing.Color]::FromArgb(39, 174, 96)
$COLOR_STARTING = [System.Drawing.Color]::FromArgb(230, 126, 34)
$COLOR_STOPPED  = [System.Drawing.Color]::FromArgb(231, 76,  60)
$COLOR_DARK     = [System.Drawing.Color]::FromArgb(44,  62,  80)
$COLOR_DARKER   = [System.Drawing.Color]::FromArgb(18,  24,  36)
$COLOR_BG       = [System.Drawing.Color]::FromArgb(245, 246, 250)
$COLOR_SUBTEXT  = [System.Drawing.Color]::FromArgb(127, 140, 141)

function Get-StatusColor([string]$status) {
    switch ($status) {
        "running"  { return $COLOR_RUNNING  }
        "starting" { return $COLOR_STARTING }
        default    { return $COLOR_STOPPED  }
    }
}

function New-VttIcon([string]$state) {
    $size = 32
    $bmp  = New-Object System.Drawing.Bitmap($size, $size)
    $g    = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $brush = New-Object System.Drawing.SolidBrush((Get-StatusColor $state))
    $g.FillEllipse($brush, 1, 1, $size - 2, $size - 2)

    $font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $sf   = New-Object System.Drawing.StringFormat
    $sf.Alignment     = [System.Drawing.StringAlignment]::Center
    $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
    $g.DrawString("V", $font, [System.Drawing.Brushes]::White,
                  (New-Object System.Drawing.RectangleF(0, 0, $size, $size)), $sf)

    $g.Dispose(); $font.Dispose(); $sf.Dispose(); $brush.Dispose()
    $hIcon = $bmp.GetHicon()
    $bmp.Dispose()
    return @{ Icon = [System.Drawing.Icon]::FromHandle($hIcon); HIcon = $hIcon }
}

# ── Log refresh (file-change aware) ──────────────────────────────────────────
# Controls stored in $script: so timer/button callbacks can always reach them.

$script:mainForm    = $null
$script:logTxt      = $null
$script:cboLines    = $null
$script:chkAuto     = $null
$script:lblStatus   = $null
$script:lblMeta     = $null
$script:btnStart    = $null
$script:btnStop     = $null
$script:btnRestart  = $null
$script:accentPanel = $null   # 4-px coloured stripe at window top

$script:logMtime    = [datetime]::MinValue
$script:helperMtime = [datetime]::MinValue
$script:forceRefresh = $false  # set to $true to bypass mtime check once

function Refresh-Logs {
    if (-not $script:logTxt -or $script:logTxt.IsDisposed) { return }

    # Read file modification times
    $lm = if (Test-Path $LOG_FILE)   { (Get-Item $LOG_FILE   -ErrorAction SilentlyContinue).LastWriteTime } else { [datetime]::MinValue }
    $hm = if (Test-Path $HELPER_LOG) { (Get-Item $HELPER_LOG -ErrorAction SilentlyContinue).LastWriteTime } else { [datetime]::MinValue }

    # Skip rebuild if nothing changed and no force-refresh requested
    if (-not $script:forceRefresh -and $lm -eq $script:logMtime -and $hm -eq $script:helperMtime) { return }
    $script:logMtime    = $lm
    $script:helperMtime = $hm
    $script:forceRefresh = $false

    $n    = if ($script:cboLines -and -not $script:cboLines.IsDisposed) { $script:cboLines.SelectedItem } else { "50" }
    $tail = if ($n -eq "All") { [int]::MaxValue } else { [int]$n }

    $sb = New-Object System.Text.StringBuilder
    $sb.AppendLine("=== Hotkey Log ===") | Out-Null
    if (Test-Path $LOG_FILE) {
        (Get-Content $LOG_FILE -Tail $tail -ErrorAction SilentlyContinue) |
            ForEach-Object { $sb.AppendLine($_) | Out-Null }
    } else { $sb.AppendLine("(no log file yet)") | Out-Null }

    $sb.AppendLine("") | Out-Null
    $sb.AppendLine("=== Daemon Log ===") | Out-Null
    if (Test-Path $HELPER_LOG) {
        (Get-Content $HELPER_LOG -Tail $tail -ErrorAction SilentlyContinue) |
            ForEach-Object { $sb.AppendLine($_) | Out-Null }
    } else { $sb.AppendLine("(no log file yet)") | Out-Null }

    $script:logTxt.Text = $sb.ToString()
    $script:logTxt.SelectionStart = $script:logTxt.Text.Length
    $script:logTxt.ScrollToCaret()
}

function Update-WindowStatus {
    if (-not $script:mainForm -or $script:mainForm.IsDisposed) { return }
    $status = $script:cachedStatus
    $pidVal = $script:cachedPid
    $color  = Get-StatusColor $status

    $statusText = switch ($status) {
        "running"  { "  Running"     }
        "starting" { "  Starting..." }
        default    { "  Stopped"     }
    }
    $metaText = if ($pidVal) { "PID $pidVal  |  Ctrl+Shift+Enter to toggle recording" } `
                             else { "Ctrl+Shift+Enter to toggle recording" }

    if ($script:lblStatus.Text      -ne $statusText) { $script:lblStatus.Text      = $statusText }
    if ($script:lblStatus.ForeColor -ne $color)      { $script:lblStatus.ForeColor = $color      }
    if ($script:lblMeta.Text        -ne $metaText)   { $script:lblMeta.Text        = $metaText   }
    if ($script:accentPanel.BackColor -ne $color)    { $script:accentPanel.BackColor = $color     }

    $script:btnStart.Enabled   = ($status -eq "stopped")
    $script:btnStop.Enabled    = ($status -eq "running")
    $script:btnRestart.Enabled = ($status -ne "starting")
}

# ── Dashboard window ──────────────────────────────────────────────────────────

function Show-Dashboard {
    if ($script:mainForm -and -not $script:mainForm.IsDisposed) {
        $script:mainForm.BringToFront(); return
    }

    # ── Form ──
    $form = New-Object System.Windows.Forms.Form
    $form.Text          = "VTT Voice-to-Text"
    $form.Size          = New-Object System.Drawing.Size(820, 680)
    $form.StartPosition = "CenterScreen"
    $form.MinimumSize   = New-Object System.Drawing.Size(580, 420)
    $form.BackColor     = $COLOR_BG
    $script:mainForm    = $form

    # ── 4-px accent stripe (changes color with status) ──
    $script:accentPanel           = New-Object System.Windows.Forms.Panel
    $script:accentPanel.Dock      = "Top"
    $script:accentPanel.Height    = 4
    $script:accentPanel.BackColor = Get-StatusColor $script:cachedStatus
    $form.Controls.Add($script:accentPanel)

    # ── Status section ──
    $statusPanel           = New-Object System.Windows.Forms.Panel
    $statusPanel.Dock      = "Top"
    $statusPanel.Height    = 84
    $statusPanel.BackColor = [System.Drawing.Color]::White

    $script:lblStatus           = New-Object System.Windows.Forms.Label
    $script:lblStatus.Text      = "  Checking..."
    $script:lblStatus.Font      = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
    $script:lblStatus.ForeColor = $COLOR_SUBTEXT
    $script:lblStatus.AutoSize  = $true
    $script:lblStatus.Location  = New-Object System.Drawing.Point(14, 10)
    $statusPanel.Controls.Add($script:lblStatus)

    $script:lblMeta           = New-Object System.Windows.Forms.Label
    $script:lblMeta.Text      = "..."
    $script:lblMeta.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
    $script:lblMeta.ForeColor = $COLOR_SUBTEXT
    $script:lblMeta.AutoSize  = $true
    $script:lblMeta.Location  = New-Object System.Drawing.Point(18, 54)
    $statusPanel.Controls.Add($script:lblMeta)

    $form.Controls.Add($statusPanel)

    # ── Thin separator ──
    $sep1           = New-Object System.Windows.Forms.Panel
    $sep1.Dock      = "Top"
    $sep1.Height    = 1
    $sep1.BackColor = [System.Drawing.Color]::FromArgb(220, 220, 230)
    $form.Controls.Add($sep1)

    # ── Button bar ──
    $btnBar           = New-Object System.Windows.Forms.Panel
    $btnBar.Dock      = "Top"
    $btnBar.Height    = 52
    $btnBar.BackColor = [System.Drawing.Color]::FromArgb(250, 251, 253)

    function New-ActionButton([string]$label, [System.Drawing.Color]$bg, [int]$x) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text      = $label
        $b.Width     = 102; $b.Height = 32
        $b.Location  = New-Object System.Drawing.Point($x, 10)
        $b.FlatStyle = "Flat"
        $b.BackColor = $bg
        $b.ForeColor = [System.Drawing.Color]::White
        $b.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
        $b.FlatAppearance.BorderSize = 0
        $b.Cursor    = [System.Windows.Forms.Cursors]::Hand
        return $b
    }

    $script:btnStart   = New-ActionButton "  Start"   ([System.Drawing.Color]::FromArgb(39, 174, 96))  12
    $script:btnStop    = New-ActionButton "  Stop"    ([System.Drawing.Color]::FromArgb(231, 76,  60)) 122
    $script:btnRestart = New-ActionButton "  Restart" ([System.Drawing.Color]::FromArgb(52, 152, 219)) 232
    $btnConfig         = New-ActionButton "  Config"  ([System.Drawing.Color]::FromArgb(100,110,120))  342

    $script:btnStart.Add_Click({
        Invoke-VttCommand "start"; Start-Sleep -Milliseconds 700
        Refresh-StatusCache; Update-WindowStatus
    })
    $script:btnStop.Add_Click({
        Invoke-VttCommand "stop"; Start-Sleep -Milliseconds 700
        Refresh-StatusCache; Update-WindowStatus
    })
    $script:btnRestart.Add_Click({
        Invoke-VttCommand "restart"; Start-Sleep -Milliseconds 1200
        Refresh-StatusCache; Update-WindowStatus
    })
    $btnConfig.Add_Click({ Start-Process notepad -ArgumentList "`"$CONFIG_FILE`"" })

    $btnBar.Controls.AddRange(@($script:btnStart, $script:btnStop, $script:btnRestart, $btnConfig))
    $form.Controls.Add($btnBar)

    # ── Log header strip ──
    $logHeader           = New-Object System.Windows.Forms.Panel
    $logHeader.Dock      = "Top"
    $logHeader.Height    = 38
    $logHeader.BackColor = $COLOR_DARK
    $logHeader.Padding   = New-Object System.Windows.Forms.Padding(12, 0, 10, 0)

    $logFlow               = New-Object System.Windows.Forms.FlowLayoutPanel
    $logFlow.Dock          = "Fill"
    $logFlow.FlowDirection = "LeftToRight"
    $logFlow.WrapContents  = $false
    $logFlow.BackColor     = $COLOR_DARK
    $logFlow.Padding       = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)

    $lblLogsTitle           = New-Object System.Windows.Forms.Label
    $lblLogsTitle.Text      = "LOGS"
    $lblLogsTitle.Font      = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $lblLogsTitle.ForeColor = [System.Drawing.Color]::FromArgb(150, 170, 190)
    $lblLogsTitle.Width     = 44; $lblLogsTitle.Height = 28
    $lblLogsTitle.TextAlign = "MiddleLeft"
    $logFlow.Controls.Add($lblLogsTitle)

    $script:cboLines = New-Object System.Windows.Forms.ComboBox
    $script:cboLines.Items.AddRange(@("50", "100", "200", "All"))
    $script:cboLines.SelectedIndex = 0
    $script:cboLines.Width         = 62; $script:cboLines.Height = 26
    $script:cboLines.DropDownStyle = "DropDownList"
    $script:cboLines.Margin        = New-Object System.Windows.Forms.Padding(0, 1, 0, 0)
    $script:cboLines.Add_SelectedIndexChanged({ $script:forceRefresh = $true; Refresh-Logs })
    $logFlow.Controls.Add($script:cboLines)

    $spLog = New-Object System.Windows.Forms.Label; $spLog.Width = 6
    $logFlow.Controls.Add($spLog)

    $btnRefreshLog           = New-Object System.Windows.Forms.Button
    $btnRefreshLog.Text      = "Refresh"
    $btnRefreshLog.Width     = 68; $btnRefreshLog.Height = 26
    $btnRefreshLog.FlatStyle = "Flat"
    $btnRefreshLog.BackColor = [System.Drawing.Color]::FromArgb(60, 78, 96)
    $btnRefreshLog.ForeColor = [System.Drawing.Color]::White
    $btnRefreshLog.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $btnRefreshLog.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(80, 100, 120)
    $btnRefreshLog.Cursor    = [System.Windows.Forms.Cursors]::Hand
    $btnRefreshLog.Margin    = New-Object System.Windows.Forms.Padding(0, 1, 0, 0)
    $btnRefreshLog.Add_Click({ $script:forceRefresh = $true; Refresh-Logs })
    $logFlow.Controls.Add($btnRefreshLog)

    $spLog2 = New-Object System.Windows.Forms.Label; $spLog2.Width = 6
    $logFlow.Controls.Add($spLog2)

    $script:chkAuto           = New-Object System.Windows.Forms.CheckBox
    $script:chkAuto.Text      = "Auto (3s)"
    $script:chkAuto.Checked   = $true
    $script:chkAuto.ForeColor = [System.Drawing.Color]::FromArgb(170, 185, 200)
    $script:chkAuto.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $script:chkAuto.Width     = 88; $script:chkAuto.Height = 28
    $script:chkAuto.Margin    = New-Object System.Windows.Forms.Padding(0, 1, 0, 0)
    $logFlow.Controls.Add($script:chkAuto)

    $logHeader.Controls.Add($logFlow)
    $form.Controls.Add($logHeader)

    # ── Log text area ──
    $script:logTxt           = New-Object System.Windows.Forms.RichTextBox
    $script:logTxt.Dock      = "Fill"
    $script:logTxt.ReadOnly  = $true
    $script:logTxt.Font      = New-Object System.Drawing.Font("Consolas", 8.5)
    $script:logTxt.BackColor = $COLOR_DARKER
    $script:logTxt.ForeColor = [System.Drawing.Color]::FromArgb(190, 200, 215)
    $script:logTxt.ScrollBars = "Vertical"
    $script:logTxt.WordWrap  = $false
    $script:logTxt.BorderStyle = "None"
    $form.Controls.Add($script:logTxt)

    # Force an initial full load and status draw
    $script:forceRefresh = $true
    $form.Add_Shown({ Update-WindowStatus; Refresh-Logs })
    $form.Add_FormClosed({
        # Null out script refs so timer callbacks are no-ops after close
        $script:mainForm   = $null
        $script:logTxt     = $null
        $script:cboLines   = $null
        $script:chkAuto    = $null
        $script:lblStatus  = $null
        $script:lblMeta    = $null
        $script:btnStart   = $null
        $script:btnStop    = $null
        $script:btnRestart = $null
        $script:accentPanel = $null
    })

    $form.Show()
}

# ── Tray icon + context menu ──────────────────────────────────────────────────

$tray         = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miTitle          = New-Object System.Windows.Forms.ToolStripMenuItem "VTT Voice-to-Text"
$miTitle.Enabled  = $false
$miTitle.Font     = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$menu.Items.Add($miTitle) | Out-Null

$miStatus         = New-Object System.Windows.Forms.ToolStripMenuItem "  Status: checking..."
$miStatus.Enabled = $false
$menu.Items.Add($miStatus) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miOpen      = New-Object System.Windows.Forms.ToolStripMenuItem "  Open Dashboard"
$miOpen.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$miOpen.Add_Click({ Show-Dashboard })
$menu.Items.Add($miOpen) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miStart   = New-Object System.Windows.Forms.ToolStripMenuItem "  Start"
$miStop    = New-Object System.Windows.Forms.ToolStripMenuItem "  Stop"
$miRestart = New-Object System.Windows.Forms.ToolStripMenuItem "  Restart"
$miStart.Add_Click({   Invoke-VttCommand "start"   })
$miStop.Add_Click({    Invoke-VttCommand "stop"    })
$miRestart.Add_Click({ Invoke-VttCommand "restart" })
$menu.Items.Add($miStart)   | Out-Null
$menu.Items.Add($miStop)    | Out-Null
$menu.Items.Add($miRestart) | Out-Null

$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$miExit = New-Object System.Windows.Forms.ToolStripMenuItem "  Exit Tray"
$miExit.Add_Click({
    $masterTimer.Stop()
    $tray.Visible = $false
    $tray.Dispose()
    if ($script:activeHIcon -ne [IntPtr]::Zero) {
        [WinApi]::DestroyIcon($script:activeHIcon) | Out-Null
    }
    [WinApi]::ReleaseSingleInstance()
    [System.Windows.Forms.Application]::Exit()
})
$menu.Items.Add($miExit) | Out-Null

$tray.ContextMenuStrip = $menu
$tray.Add_DoubleClick({ Show-Dashboard })

# ── Single master timer (3 s) ─────────────────────────────────────────────────
# Replaces the two separate timers from before.
# Per tick: refresh status cache once, then update tray + window from cache.

$script:lastTrayStatus = ""

function Update-TrayFromCache {
    $status = $script:cachedStatus
    $pidVal = $script:cachedPid

    if ($status -ne $script:lastTrayStatus) {
        $script:lastTrayStatus = $status
        $result = New-VttIcon $status
        $tray.Icon = $result.Icon
        if ($script:activeHIcon -ne [IntPtr]::Zero) {
            [WinApi]::DestroyIcon($script:activeHIcon) | Out-Null
        }
        $script:activeHIcon = $result.HIcon
    }

    $tip = switch ($status) {
        "running"  { "VTT: Running (PID $pidVal) - Ctrl+Shift+Enter" }
        "starting" { "VTT: Starting - loading whisper model..." }
        default    { "VTT: Stopped - right-click to start" }
    }
    $tray.Text = $tip.Substring(0, [Math]::Min($tip.Length, 63))

    $miStatus.Text = switch ($status) {
        "running"  { "  Running  (PID $pidVal)" }
        "starting" { "  Starting - loading model..." }
        default    { "  Stopped" }
    }
    $miStart.Enabled   = ($status -eq "stopped")
    $miStop.Enabled    = ($status -eq "running")
    $miRestart.Enabled = ($status -ne "starting")
}

$masterTimer          = New-Object System.Windows.Forms.Timer
$masterTimer.Interval = 3000
$masterTimer.Add_Tick({
    Refresh-StatusCache       # one Get-Process call per tick
    Update-TrayFromCache      # update tray icon/menu from cache
    Update-WindowStatus       # update dashboard status panel (no-op if closed)
    if ($script:chkAuto -and -not $script:chkAuto.IsDisposed -and $script:chkAuto.Checked) {
        Refresh-Logs          # re-reads files only if mtime changed
    }
})
$masterTimer.Start()

# Initial tick (immediate)
Refresh-StatusCache
Update-TrayFromCache

$tray.ShowBalloonTip(
    3000, "VTT Voice-to-Text",
    "Tray active. Double-click for dashboard. Ctrl+Shift+Enter to record.",
    [System.Windows.Forms.ToolTipIcon]::Info)

# ── Message loop ──────────────────────────────────────────────────────────────
[System.Windows.Forms.Application]::Run()
