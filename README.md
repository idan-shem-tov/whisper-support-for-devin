# VTT - Voice-to-Text

Global voice-to-text for Windows. Press **Ctrl+Shift+Enter** to start recording, speak, press again to stop — transcribed text is pasted at your cursor. Works in any app.

Powered by [faster-whisper](https://github.com/SYSTRAN/faster-whisper) running locally on your machine. No cloud, no API keys, fully offline.

## Quick Start

**Prerequisites:** Windows 10/11, [Python 3.10+](https://www.python.org/downloads/) (check "Add to PATH" during install), a microphone.

```powershell
# 1. Clone the repo
git clone https://github.com/idan-shem-tov/whisper-support-for-devin.git vtt
cd vtt

# 2. Run the installer (installs deps, configures paths, starts VTT)
powershell -ExecutionPolicy Bypass -File install.ps1
```

That's it. After install completes, press **Ctrl+Shift+Enter** to try it.

VTT will auto-start on every Windows login, including the system tray icon.

## Usage

| Action | Hotkey |
|--------|--------|
| Start recording | Ctrl+Shift+Enter |
| Stop + transcribe + paste | Ctrl+Shift+Enter |

You'll hear a sound when recording starts and stops. The transcribed text is automatically pasted at your cursor.

## System Tray

VTT includes a lightweight system tray UI that starts automatically on login alongside the hotkey listener.

**To start the tray manually:**
```powershell
powershell -ExecutionPolicy Bypass -File vtt.ps1 tray
```

The tray icon sits in your notification area (bottom-right). Its color reflects the current state:

| Icon color | Meaning |
|------------|---------|
| Green | VTT is running and ready |
| Amber | Starting — whisper model loading |
| Gray | Stopped |

**Right-click the icon** for quick actions: Start, Stop, Restart, Open Dashboard.

**Double-click the icon** (or choose "Open Dashboard") to open the VTT dashboard:

- **Status panel** — live running/stopped indicator with PID
- **Action buttons** — Start, Stop, Restart, open Config in Notepad
- **Log viewer** — combined tail of both log files, auto-refreshes every 3 seconds (only re-reads when files change), adjustable line count

The tray is single-instance: launching a second copy exits silently so you never get duplicate icons.

## Configuration

Edit **`config.ini`** and restart VTT for changes to take effect.

```ini
[vtt]
# Whisper model: tiny, base, small, medium
model = base

# Language: auto, en, he, es, fr, de, etc.
language = en

# Sound feedback on start/stop: on or off
sound = on
```

### Models

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| `tiny` | ~75MB | Fastest | Lower |
| `base` | ~150MB | Fast | Good (default) |
| `small` | ~500MB | Medium | Better |
| `medium` | ~1.5GB | Slow | High |

### Language

Set a specific language (e.g., `language = en`) for better accuracy. Auto-detect can misfire on short recordings or quiet mics.

## Management

```powershell
powershell -ExecutionPolicy Bypass -File vtt.ps1 <command>
```

| Command | Description |
|---------|-------------|
| `start` | Start VTT |
| `stop` | Stop VTT |
| `restart` | Restart VTT (use after config changes) |
| `status` | Check if VTT is running |
| `logs` | Show recent logs in the terminal |
| `tray` | Start the system tray UI |

## How It Works

- **Python daemon** (`vtt-helper.py`): Whisper model pre-loaded in memory, TCP server on localhost for instant IPC, 2-second audio pre-buffer (no clipped beginnings), auto-gain normalization, audio feedback sounds.
- **PowerShell hotkey listener** (`vtt-hotkey.ps1`): Global hotkey via `WM_HOTKEY`, TCP client for daemon commands, auto-restart on daemon crash, clipboard paste via `keybd_event`.
- **System tray UI** (`vtt-tray.ps1`): WinForms `NotifyIcon` with a single 3-second master timer. Status is cached to avoid redundant `Get-Process` calls; logs are only re-read when file modification times change. Single-instance enforced via a named Windows Mutex.
- **Auto-start**: Registry `Run` key launches both the hotkey listener and the tray UI silently on login.

## Troubleshooting

- **Hotkey not working after restart**: Wait for "VTT started" message before pressing the hotkey.
- **Wrong language / garbled output**: Set `language = en` (or your language) in `config.ini` and restart.
- **No sound feedback**: Ensure your audio output device is working. Sound plays through the Python daemon.
- **VTT seems stuck**: Run `vtt.ps1 restart`.
- **Tray icon missing**: Run `vtt.ps1 tray`. It starts automatically on next login.
- **Duplicate tray icons from a previous session**: Right-click each stale icon and choose "Exit Tray". Only one instance can run at a time going forward.

## Logs

Logs are in `%TEMP%\vtt\`:
- `debug.log` — hotkey events, paste actions
- `helper.log` — recording, transcription, errors

Both are viewable live in the dashboard (double-click the tray icon).
