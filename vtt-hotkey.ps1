# Voice-to-Text Global Hotkey (Ctrl+Shift+Enter)
# All Windows-native: no WSL dependency.
# Uses WM_HOTKEY messages for instant hotkey response.
# Python daemon handles recording + transcription with model pre-loaded.
# IPC via TCP socket on localhost (daemon writes port to %TEMP%\vtt\port.txt).
# Run: powershell -ExecutionPolicy Bypass -File C:\Users\Idan_Shemtov\vtt\vtt-hotkey.ps1

$PYTHON = "C:\Program Files\Python312\python.exe"
$HELPER = "C:\Users\Idan_Shemtov\vtt\vtt-helper.py"
$VTT_DIR = Join-Path $env:TEMP "vtt"
$PORT_FILE = Join-Path $VTT_DIR "port.txt"
$LOG_FILE = Join-Path $VTT_DIR "debug.log"
$PID_FILE = Join-Path $VTT_DIR "hotkey.pid"

if (!(Test-Path $VTT_DIR)) { New-Item -ItemType Directory -Path $VTT_DIR -Force | Out-Null }

function Log($msg) {
    $ts = Get-Date -Format "HH:mm:ss"
    $line = "$ts $msg"
    Write-Host $line
    Add-Content -Path $LOG_FILE -Value $line
}

# --- TCP client: send a command to the daemon, return the response ---
function Send-DaemonCommand($cmd, $timeoutMs = 130000) {
    try {
        if (!(Test-Path $PORT_FILE)) { return $null }
        $port = [int](Get-Content $PORT_FILE).Trim()
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect("127.0.0.1", $port)
        $client.ReceiveTimeout = $timeoutMs
        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
        $writer.WriteLine($cmd)
        $writer.Flush()
        $response = $reader.ReadLine()
        $client.Close()
        return $response
    } catch {
        return $null
    }
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

    # Clean up stale port file
    Remove-Item $PORT_FILE -Force -ErrorAction SilentlyContinue
}

KillPreviousInstance

# Write our PID so future instances can kill us
Set-Content -Path $PID_FILE -Value $PID

Add-Type -AssemblyName System.Windows.Forms

# WM_HOTKEY-aware form with keybd_event paste (works in terminals unlike SendKeys)
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

    [DllImport("user32.dll")]
    private static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    private const byte VK_CONTROL = 0x11;
    private const byte VK_V = 0x56;
    private const uint KEYEVENTF_KEYUP = 0x0002;

    public static void PasteFromClipboard() {
        keybd_event(VK_CONTROL, 0, 0, UIntPtr.Zero);
        keybd_event(VK_V, 0, 0, UIntPtr.Zero);
        keybd_event(VK_V, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(VK_CONTROL, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
    }

    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) {
            if (HotkeyPressed != null) HotkeyPressed(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }
}
"@

function StartDaemon {
    # Clean up stale port file
    Remove-Item $PORT_FILE -Force -ErrorAction SilentlyContinue

    Log "Starting daemon (loading whisper model)..."
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $PYTHON
    $psi.Arguments = "`"$HELPER`" daemon"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardError = $true
    $script:daemonProc = [System.Diagnostics.Process]::Start($psi)
    Log "  daemon PID=$($script:daemonProc.Id)"

    # Wait for port file (means daemon is ready and listening)
    $waited = 0
    while (!(Test-Path $PORT_FILE) -and $waited -lt 300) {
        Start-Sleep -Milliseconds 100
        $waited++
    }
    if (Test-Path $PORT_FILE) {
        $port = (Get-Content $PORT_FILE).Trim()
        Log "Daemon ready on port $port"
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
    Log "Attempting to kill stale VTT instances and retry..."
    # Targeted: only kill PowerShell processes running vtt-hotkey.ps1 (not unrelated PS sessions)
    Get-CimInstance Win32_Process -Filter "Name LIKE 'powershell%'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*vtt-hotkey.ps1*" } |
        ForEach-Object {
            Log "  Killing stale VTT instance PID $($_.ProcessId)..."
            # Kill its child processes (daemon) first
            Get-CimInstance Win32_Process -Filter "ParentProcessId=$($_.ProcessId)" -ErrorAction SilentlyContinue |
                ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
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
        $result = Send-DaemonCommand "start" 5000
        if ($result -eq $null) {
            Log "WARNING: daemon not responding, restarting..."
            StartDaemon
            $result = Send-DaemonCommand "start" 5000
        }
        if ($result -eq "ok" -or $result -eq "already_recording") {
            $script:recording = $true
        } else {
            Log "WARNING: start failed: $result"
        }
    } else {
        # --- STOP RECORDING + TRANSCRIBE ---
        Log "Stopping..."
        $script:recording = $false
        $script:busy = $true

        # Send stop command — blocks until transcription is done (up to 130s)
        $text = Send-DaemonCommand "stop"

        if ($text -eq $null) {
            # Connection failed = daemon died
            Log "WARNING: daemon died during transcription, restarting..."
            StartDaemon
        } elseif ($text.Length -gt 0) {
            Log "  result: [$text]"
            [System.Windows.Forms.Clipboard]::SetText($text)
            Log ">>> $text"
            Start-Sleep -Milliseconds 200
            [HotkeyForm]::PasteFromClipboard()
            Log "(pasted)"
        } else {
            Log "Empty transcription."
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
