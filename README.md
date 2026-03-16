# VTT - Voice-to-Text (Windows-native)

Global hotkey-triggered voice-to-text using [faster-whisper](https://github.com/SYSTRAN/faster-whisper). Press **Ctrl+Shift+Enter** to start recording, speak, press again to stop — transcribed text is pasted at your cursor.

## How It Works

- **Python daemon** (`vtt-helper.py`) runs in the background with:
  - Whisper model pre-loaded in memory (no startup delay per transcription)
  - Continuous audio listening with a 2-second ring buffer (no clipped beginnings)
  - Auto-normalization of quiet microphone input
  - Auto language detection (English, Hebrew, etc.) or forced language via config
- **PowerShell hotkey listener** (`vtt-hotkey.ps1`) handles:
  - Global Ctrl+Shift+Enter hotkey via Windows `WM_HOTKEY` messages (instant response)
  - Daemon lifecycle (auto-restart if it crashes)
  - Clipboard + paste of transcription result
- **VBS launcher** (`vtt-hotkey-startup.vbs`) runs everything silently on Windows login

## Requirements

- **Windows 10/11**
- **Python 3.10+** (tested with 3.12) — must be installed system-wide, not just Windows Store
- **A working microphone**

## Installation

### 1. Clone this repo

```powershell
git clone <repo-url> C:\Users\<YourUsername>\vtt
cd C:\Users\<YourUsername>\vtt
```

### 2. Install Python dependencies

```powershell
pip install faster-whisper sounddevice scipy numpy
```

The first run will download the Whisper `base` model (~150MB) from Hugging Face.

### 3. Update paths in the scripts

Edit `vtt-hotkey.ps1` — update these two lines with your username:

```powershell
$PYTHON = "C:\Program Files\Python312\python.exe"   # adjust to your Python path
$HELPER = "C:\Users\<YourUsername>\vtt\vtt-helper.py"
```

To find your Python path, run: `where python` in cmd.

### 4. Test it manually

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\<YourUsername>\vtt\vtt-hotkey.ps1
```

Wait for "Listening..." to appear, then try Ctrl+Shift+Enter.

### 5. Set up auto-start on login

Create the file `vtt-hotkey-startup.vbs` in your Windows Startup folder:

```
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\
```

With this content (update the path):

```vbs
' Silent launcher for vtt-hotkey.ps1
Set objShell = CreateObject("WScript.Shell")
objShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\<YourUsername>\vtt\vtt-hotkey.ps1", 0, False
```

Or run the included install script:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

## Microphone Configuration

The daemon auto-selects the "Microphone Array" device (built-in laptop mic). If you want a specific device:

1. Run: `python vtt-helper.py test-mic` (speak while it tests)
2. Note the device number that shows "GOOD"
3. Write that number to `%TEMP%\vtt\device.txt`:
   ```
   echo 2 > %TEMP%\vtt\device.txt
   ```

If your mic is very quiet, the daemon applies automatic gain normalization.

To boost your Windows mic volume to 100%, go to:
**Settings > System > Sound > Input > Volume slider**

## Language Configuration

By default, the daemon auto-detects the spoken language. This can misfire on quiet microphones or short recordings, producing garbled output (e.g., detecting Norwegian instead of English).

**Recommended:** Force a language to avoid misdetection:

```
echo en > %TEMP%\vtt\language.txt
```

Common language codes: `en` (English), `he` (Hebrew), `es` (Spanish), `fr` (French), `de` (German).

To go back to auto-detection, delete the file or write `auto`:
```
del %TEMP%\vtt\language.txt
```

After changing, restart VTT: `vtt.ps1 restart`

## Model Configuration

The default model is `base` (~150MB, fast). For better accuracy on longer recordings or quiet mics, you can use a larger model:

```
echo small > %TEMP%\vtt\model.txt
```

| Model | Size | Speed | Accuracy |
|-------|------|-------|----------|
| `tiny` | ~75MB | Fastest | Lower |
| `base` | ~150MB | Fast | Good (default) |
| `small` | ~500MB | Medium | Better |
| `medium` | ~1.5GB | Slow | High |

After changing, restart VTT: `vtt.ps1 restart` (first run will download the new model).

## Changing the Hotkey

Edit `vtt-hotkey.ps1`, line with `RegisterHotKey`. The modifier and key codes:

| Combo | Modifier | Key |
|-------|----------|-----|
| Ctrl+Shift+Enter | `0x0006` | `0x0D` |
| Ctrl+Shift+R | `0x0006` | `0x52` |
| Ctrl+Alt+R | `0x0003` | `0x52` |

Modifier flags: Ctrl=`0x0002`, Alt=`0x0001`, Shift=`0x0004` (combine by adding).
Key codes: [Virtual-Key Codes](https://learn.microsoft.com/en-us/windows/win32/inputdev/virtual-key-codes)

## Logs & Debugging

Logs are written to `%TEMP%\vtt\`:
- `debug.log` — PowerShell hotkey events
- `helper.log` — Python daemon (recording, transcription, errors)

## Management Commands

Use `vtt.ps1` to manage the VTT service:

```powershell
powershell -ExecutionPolicy Bypass -File C:\Users\<YourUsername>\vtt\vtt.ps1 <command>
```

| Command | Description |
|---------|-------------|
| `start` | Start VTT (kills any existing instance first) |
| `stop` | Stop VTT and all daemon processes |
| `restart` | Stop and start VTT (use this if it gets stuck) |
| `status` | Show if VTT and its daemon are running |
| `logs` | Show recent hotkey and daemon logs |

**Tip:** If VTT stops responding to the hotkey, run `vtt.ps1 restart` to fix it.

## Troubleshooting

- **Hotkey not responding / "no result"**: The daemon may be stuck on a long transcription. Run `vtt.ps1 restart`.
- **Garbled output / wrong language detected**: The `base` model can misdetect language on quiet mics. Fix: `echo en > %TEMP%\vtt\language.txt` and restart. See [Language Configuration](#language-configuration).
- **Transcription timeout**: The daemon has a 120-second transcription timeout to support recordings up to ~1 minute. If exceeded, it returns an empty result and recovers automatically.
- **Hotkey registration fails**: Another instance may be holding the hotkey. `vtt.ps1 restart` will kill stale instances first.

## Files

| File | Purpose |
|------|---------|
| `vtt-helper.py` | Python daemon: audio recording + Whisper transcription |
| `vtt-hotkey.ps1` | PowerShell: global hotkey + daemon management |
| `vtt.ps1` | CLI management tool: start, stop, restart, status, logs |
| `install.ps1` | One-time setup: installs deps + creates startup shortcut |
