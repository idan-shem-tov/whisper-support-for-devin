# vtt.ps1 - Voice-to-Text management
# Usage:
#   vtt start    - Start VTT (kills any existing instance first)
#   vtt stop     - Stop VTT
#   vtt restart  - Restart VTT
#   vtt status   - Show if VTT is running
#   vtt logs     - Show recent logs
#   vtt tray     - Start the system tray UI

param([string]$Command = "status")

$VTT_DIR = Join-Path $env:TEMP "vtt"
$PID_FILE = Join-Path $VTT_DIR "hotkey.pid"
$PORT_FILE = Join-Path $VTT_DIR "port.txt"
$LOG_FILE = Join-Path $VTT_DIR "debug.log"
$HELPER_LOG = Join-Path $VTT_DIR "helper.log"
$HOTKEY_SCRIPT = Join-Path $PSScriptRoot "vtt-hotkey.ps1"
$TRAY_SCRIPT = Join-Path $PSScriptRoot "vtt-tray.ps1"

function Is-Running {
    if (Test-Path $PID_FILE) {
        $pidVal = (Get-Content $PID_FILE -ErrorAction SilentlyContinue)
        if ($pidVal) {
            $proc = Get-Process -Id $pidVal.Trim() -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -like "powershell*") {
                return $true
            }
        }
    }
    return $false
}

function Get-VttPid {
    if (Test-Path $PID_FILE) {
        return (Get-Content $PID_FILE).Trim()
    }
    return $null
}

function Stop-Vtt {
    if (Is-Running) {
        $vpid = Get-VttPid
        Write-Host "Stopping VTT (PID $vpid)..." -ForegroundColor Yellow

        # Kill child python processes
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$vpid" -ErrorAction SilentlyContinue |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $vpid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
        Write-Host "Stopped" -ForegroundColor Green
    } else {
        # Kill orphaned daemons
        Get-CimInstance Win32_Process -Filter "CommandLine LIKE '%vtt-helper.py%daemon%'" -ErrorAction SilentlyContinue |
            ForEach-Object {
                Write-Host "Killing orphaned daemon (PID $($_.ProcessId))..." -ForegroundColor Yellow
                Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            }
        Write-Host "VTT is not running" -ForegroundColor Gray
    }
    if (Test-Path $PID_FILE) { Remove-Item $PID_FILE -Force }
    Remove-Item $PORT_FILE -Force -ErrorAction SilentlyContinue
}

function Ping-Daemon {
    # Try to send a TCP ping to the daemon. Returns $true if it responds.
    try {
        if (!(Test-Path $PORT_FILE)) { return $false }
        $port = [int](Get-Content $PORT_FILE).Trim()
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect("127.0.0.1", $port)
        $client.ReceiveTimeout = 3000
        $stream = $client.GetStream()
        $writer = New-Object System.IO.StreamWriter($stream)
        $reader = New-Object System.IO.StreamReader($stream)
        $writer.WriteLine("ping")
        $writer.Flush()
        $response = $reader.ReadLine()
        $client.Close()
        return ($response -eq "pong")
    } catch {
        return $false
    }
}

function Start-Vtt {
    if (Is-Running) {
        Write-Host "VTT is already running (PID $(Get-VttPid)). Use 'vtt restart' instead." -ForegroundColor Yellow
        return
    }
    Write-Host "Starting VTT..." -ForegroundColor Cyan
    Start-Process powershell -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$HOTKEY_SCRIPT`"" -WindowStyle Hidden

    # Wait for port file (means daemon is loaded and hotkey is registered)
    # Model loading can take 30-40s + a few seconds for .NET/C# JIT overhead
    $maxWait = 180  # 90 seconds (180 * 500ms)
    $waited = 0
    while (!(Test-Path $PORT_FILE) -and $waited -lt $maxWait) {
        Start-Sleep -Milliseconds 500
        $waited++
        # Show progress every 5 seconds
        if ($waited % 10 -eq 0) {
            $elapsed = [math]::Round($waited * 0.5)
            Write-Host "  Loading whisper model... (${elapsed}s)" -ForegroundColor Gray
        }
    }

    if ((Test-Path $PORT_FILE) -and (Is-Running)) {
        $elapsed = [math]::Round($waited * 0.5)
        Write-Host "VTT started (PID $(Get-VttPid)) in ${elapsed}s" -ForegroundColor Green
        Write-Host "Hotkey: Ctrl+Shift+Enter" -ForegroundColor Cyan
    } else {
        # Check if process is still alive but just slow
        if (Test-Path $PID_FILE) {
            $vpid = (Get-Content $PID_FILE -ErrorAction SilentlyContinue)
            if ($vpid) {
                $proc = Get-Process -Id $vpid.Trim() -ErrorAction SilentlyContinue
                if ($proc) {
                    Write-Host "VTT process is still loading (PID $($vpid.Trim())). It may start shortly." -ForegroundColor Yellow
                    Write-Host "Check status with: vtt status" -ForegroundColor Gray
                    return
                }
            }
        }
        Write-Host "Failed to start. Check logs: vtt logs" -ForegroundColor Red
    }
}

switch ($Command.ToLower()) {
    "start" {
        Start-Vtt
    }
    "stop" {
        Stop-Vtt
    }
    "restart" {
        Stop-Vtt
        Start-Sleep -Milliseconds 500
        Start-Vtt
    }
    "status" {
        if (Is-Running) {
            $vpid = Get-VttPid
            Write-Host "VTT is running (PID $vpid)" -ForegroundColor Green
            Write-Host "Hotkey: Ctrl+Shift+Enter"
            # Check daemon via TCP ping
            if (Ping-Daemon) {
                $port = (Get-Content $PORT_FILE).Trim()
                Write-Host "Daemon: running (port $port)" -ForegroundColor Green
            } else {
                Write-Host "Daemon: NOT responding (will restart on next hotkey)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "VTT is not running" -ForegroundColor Red
            Write-Host "Start with: vtt start"
        }
    }
    "logs" {
        Write-Host "=== Hotkey Log ===" -ForegroundColor Cyan
        if (Test-Path $LOG_FILE) {
            Get-Content $LOG_FILE -Tail 20
        } else {
            Write-Host "(no logs)"
        }
        Write-Host ""
        Write-Host "=== Daemon Log ===" -ForegroundColor Cyan
        if (Test-Path $HELPER_LOG) {
            Get-Content $HELPER_LOG -Tail 20
        } else {
            Write-Host "(no logs)"
        }
    }
    "tray" {
        Write-Host "Starting VTT tray..." -ForegroundColor Cyan
        Start-Process powershell `
            -ArgumentList "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$TRAY_SCRIPT`"" `
            -WindowStyle Hidden
        Write-Host "Tray icon started (check the notification area)" -ForegroundColor Green
    }
    default {
        Write-Host "Usage: vtt [start|stop|restart|status|logs|tray]" -ForegroundColor Yellow
    }
}
