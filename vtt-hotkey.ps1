# Voice-to-Text Global Hotkey (Ctrl+Shift+Enter)
# All Windows-native: no WSL dependency.
# Uses WM_HOTKEY messages for instant hotkey response.
# Python daemon handles recording + transcription with model pre-loaded.
# Run: powershell -ExecutionPolicy Bypass -File C:\Users\Idan_Shemtov\vtt\vtt-hotkey.ps1

$PYTHON = "C:\Program Files\Python312\python.exe"
$HELPER = "C:\Users\Idan_Shemtov\vtt\vtt-helper.py"
$VTT_DIR = Join-Path $env:TEMP "vtt"
$START_FILE = Join-Path $VTT_DIR "start"
$STOP_FILE = Join-Path $VTT_DIR "stop"
$READY_FILE = Join-Path $VTT_DIR "ready"
$RESULT_FILE = Join-Path $VTT_DIR "result.txt"
$LOG_FILE = Join-Path $VTT_DIR "debug.log"
$PID_FILE = Join-Path $VTT_DIR "hotkey.pid"

if (!(Test-Path $VTT_DIR)) { New-Item -ItemType Directory -Path $VTT_DIR -Force | Out-Null }

function Log($msg) {
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "$ts $msg"
    Write-Host $line
    Add-Content -Path $LOG_FILE -Value $line
}

# --- Kill any previous VTT instance ---
function KillPreviousInstance {
    # Kill by PID file
    if (Test-Path $PID_FILE) {
        $oldPid = (Get-Content $PID_FILE).Trim()
        if ($oldPid) {
            try {
                $proc = Get-Process -Id $oldPid -ErrorAction SilentlyContinue
                if ($proc -and $proc.ProcessName -like "powershell*") {
                    Log "Killing previous VTT instance (PID $oldPid)..."
                    # Also kill its child python processes
                    Get-CimInstance Win32_Process -Filter "ParentProcessId=$oldPid" -ErrorAction SilentlyContinue |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                    Stop-Process -Id $oldPid -Force -ErrorAction SilentlyContinue
                    Start-Sleep -Milliseconds 500
                }
            } catch {}
        }
        Remove-Item $PID_FILE -Force -ErrorAction SilentlyContinue
    }

    # Also kill any orphaned vtt-helper daemon processes
    Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%vtt-helper.py%daemon%'" -ErrorAction SilentlyContinue |
        ForEach-Object {
            Log "Killing orphaned daemon (PID $($_.ProcessId))..."
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
        }
}

KillPreviousInstance

# Write our PID so future instances can kill us
Set-Content -Path $PID_FILE -Value $PID

Add-Type -AssemblyName System.Windows.Forms

# WM_HOTKEY-aware form
Add-Type -ReferencedAssemblies System.Windows.Forms @"
using System;
using System.Windows.Forms;
using System.Runtime.InteropServices;

public class HotkeyForm : Form {
    public event EventHandler HotkeyPressed;
    private const int WM_HOTKEY = 0x0312;

    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            if (HotkeyPressed != null) HotkeyPressed(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }
}
"@

function StartDaemon {
    # Clean signal files
    foreach ($f in @($START_FILE, $STOP_FILE, $READY_FILE, $RESULT_FILE)) {
        if (Test-Path $f) { Remove-Item $f -Force }
    }

    Log "Starting daemon (loading whisper model)..."
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PYTHON
    $psi.Arguments = "`"$HELPER`" daemon"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $script:daemonProc = [System.Diagnostics.Process]::Start($psi)
    Log "  daemon PID=$($script:daemonProc.Id)"

    # Wait for ready (max 30s)
    $waited = 0
    while (!(Test-Path $READY_FILE) -and $waited -lt 300) {
        Start-Sleep -Milliseconds 100
        $waited++
    }
    if (Test-Path $READY_FILE) {
        Log "Daemon ready"
    } else {
        Log "WARNING: daemon did not become ready"
    }
}

function EnsureDaemon {
    if ($script:daemonProc -eq $null -or $script:daemonProc.HasExited) {
        Log "Daemon died, restarting..."
        StartDaemon
    }
}

# --- Initial launch ---
StartDaemon

# --- Setup hotkey ---
$script:recording = $false
$script:busy = $false

$form = New-Object HotkeyForm
$form.WindowState = 'Minimized'
$form.ShowInTaskbar = $false

# Ctrl+Shift = 0x0006, Enter = 0x0D
$registered = [HotkeyForm]::RegisterHotKey($form.Handle, 1, 0x0006, 0x0D)
if (-not $registered) {
    Log "ERROR: Failed to register Ctrl+Shift+Enter hotkey"
    Log "Attempting to kill stale instances and retry..."
    # Brute-force: kill all console powershell except us
    Get-Process powershell -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq (Get-Process -Id $PID).SessionId -and $_.Id -ne $PID } |
        ForEach-Object {
            Log "  Killing PowerShell PID $($_.Id)..."
            Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
        }
    Start-Sleep -Milliseconds 1000

    $registered = [HotkeyForm]::RegisterHotKey($form.Handle, 1, 0x0006, 0x0D)
    if (-not $registered) {
        Log "FATAL: Still cannot register hotkey. Exiting."
        if ($script:daemonProc -and -not $script:daemonProc.HasExited) { $script:daemonProc.Kill() }
        exit 1
    }
    Log "Hotkey registered on retry"
}

$form.Add_HotkeyPressed({
    # Ignore hotkey while busy processing a transcription
    if ($script:busy) {
        Log "(ignored, busy transcribing)"
        return
    }

    if (-not $script:recording) {
        # --- START RECORDING ---
        EnsureDaemon
        Log "Recording..."
        New-Item -ItemType File -Path $START_FILE -Force | Out-Null
        $script:recording = $true
    } else {
        # --- STOP RECORDING + TRANSCRIBE ---
        Log "Stopping..."
        $script:recording = $false
        $script:busy = $true

        # Signal stop
        New-Item -ItemType File -Path $STOP_FILE -Force | Out-Null

        # Wait for result.txt (daemon writes it after transcription)
        $attempts = 0
        while (!(Test-Path $RESULT_FILE) -and $attempts -lt 1250) {
            Start-Sleep -Milliseconds 100
            $attempts++
        }

        if (Test-Path $RESULT_FILE) {
            $raw = Get-Content -Path $RESULT_FILE -Encoding UTF8 -Raw
            if ($raw) {
                $text = $raw.Trim()
            } else {
                $text = ""
            }
            Log "  result: [$text]  (waited $($attempts * 100)ms)"

            if ($text -and $text.Length -gt 0) {
                [System.Windows.Forms.Clipboard]::SetText($text)
                Log ">>> $text"
                Start-Sleep -Milliseconds 200
                [System.Windows.Forms.SendKeys]::SendWait("^v")
                Log "(pasted)"
            } else {
                Log "Empty transcription."
            }
        } else {
            Log "WARNING: no result after 125s"
        }

        $script:busy = $false
    }
})

# Cleanup on exit
$form.Add_FormClosed({
    [HotkeyForm]::UnregisterHotKey($form.Handle, 1)
    if ($script:daemonProc -and -not $script:daemonProc.HasExited) {
        $script:daemonProc.Kill()
        Log "Daemon stopped"
    }
    Remove-Item $PID_FILE -Force -ErrorAction SilentlyContinue
})

Log "=== Voice-to-Text Hotkey (Windows-native) ==="
Log "Ctrl+Shift+Enter: toggle recording"
Log "Listening..."

[System.Windows.Forms.Application]::Run($form)
