# VTT System Architecture & Flow

## 📋 Table of Contents
- [System Overview](#system-overview)
- [Component Architecture](#component-architecture)
- [Data Flow](#data-flow)
- [Hotkey Workflow](#hotkey-workflow)
- [Model & Framework](#model--framework)
- [Logging System](#logging-system)
- [Auto-Start Mechanism](#auto-start-mechanism)
- [GPU Acceleration](#gpu-acceleration)

---

## System Overview

VTT (Voice-to-Text) is a **fully offline**, **Windows-native** voice transcription system that provides global hotkey-triggered speech-to-text in any application.

```
┌─────────────────────────────────────────────────────────────────┐
│                         VTT ECOSYSTEM                           │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐         │
│  │   Hotkey     │  │   Python     │  │  System      │         │
│  │   Listener   │◄─┤   Daemon     │  │  Tray UI     │         │
│  │ (PowerShell) │  │ (Whisper AI) │  │ (PowerShell) │         │
│  └──────────────┘  └──────────────┘  └──────────────┘         │
│         │                 │                   │                │
│         └─────────────────┴───────────────────┘                │
│                           │                                    │
│                    ┌──────▼──────┐                             │
│                    │  Logs & IPC │                             │
│                    │  %TEMP%\vtt │                             │
│                    └─────────────┘                             │
└─────────────────────────────────────────────────────────────────┘
```

### Key Features
- **Framework**: [faster-whisper](https://github.com/SYSTRAN/faster-whisper) (CTranslate2-based)
- **Hotkey**: `Ctrl+Shift+Enter` (global, works in any app)
- **Privacy**: Microphone only active during recording
- **Performance**: GPU acceleration with automatic CPU fallback
- **Offline**: No cloud, no API keys, fully local

---

## Component Architecture

### 1️⃣ Hotkey Listener (`vtt-hotkey.ps1`)

**Technology**: PowerShell + WinForms + WM_HOTKEY API

```
┌────────────────────────────────────────────────────┐
│         HOTKEY LISTENER ARCHITECTURE               │
├────────────────────────────────────────────────────┤
│                                                    │
│  ┌──────────────────────────────────────────┐     │
│  │  Windows Message Loop (WinForms)         │     │
│  │  • Registers WM_HOTKEY (Ctrl+Shift+Enter)│     │
│  │  • Event-driven, non-blocking UI thread  │     │
│  └──────────────┬───────────────────────────┘     │
│                 │                                  │
│                 ▼                                  │
│  ┌──────────────────────────────────────────┐     │
│  │  State Machine                           │     │
│  │  • recording = false/true                │     │
│  │  • busy = false/true (transcribing)      │     │
│  └──────────────┬───────────────────────────┘     │
│                 │                                  │
│                 ▼                                  │
│  ┌──────────────────────────────────────────┐     │
│  │  TCP Client (IPC to daemon)              │     │
│  │  • Commands: start, stop, result, ping   │     │
│  │  • Port read from %TEMP%\vtt\port.txt    │     │
│  └──────────────┬───────────────────────────┘     │
│                 │                                  │
│                 ▼                                  │
│  ┌──────────────────────────────────────────┐     │
│  │  Result Polling Timer (200ms)            │     │
│  │  • Non-blocking result retrieval         │     │
│  │  • Timeout: 120s safety cap              │     │
│  └──────────────┬───────────────────────────┘     │
│                 │                                  │
│                 ▼                                  │
│  ┌──────────────────────────────────────────┐     │
│  │  Clipboard + keybd_event Paste           │     │
│  │  • Ctrl+V simulation (works in terminals)│     │
│  └──────────────────────────────────────────┘     │
│                                                    │
└────────────────────────────────────────────────────┘
```

**Key Responsibilities**:
- Register global hotkey via Win32 API
- Manage recording state (start/stop toggle)
- Communicate with Python daemon via TCP
- Poll for transcription results
- Paste transcribed text at cursor position

**Process Management**:
- Kills previous instances on startup (via PID file)
- Auto-restarts daemon if it crashes
- Single-instance enforcement

---

### 2️⃣ Python Daemon (`vtt-helper.py`)

**Technology**: Python 3.10+ + faster-whisper + sounddevice

```
┌─────────────────────────────────────────────────────────────┐
│              PYTHON DAEMON ARCHITECTURE                     │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌───────────────────────────────────────────────────┐     │
│  │  Initialization Phase                             │     │
│  │  1. Load config.ini (model, language, sound)      │     │
│  │  2. Detect device (CUDA GPU or CPU)               │     │
│  │  3. Pre-load Whisper model into memory            │     │
│  │  4. Select microphone device (smart auto-detect)  │     │
│  │  5. Start TCP server on random port               │     │
│  │  6. Write port to %TEMP%\vtt\port.txt (signal)    │     │
│  └───────────────────────────────────────────────────┘     │
│                           │                                 │
│                           ▼                                 │
│  ┌───────────────────────────────────────────────────┐     │
│  │  TCP Command Server (localhost:random_port)       │     │
│  │  ┌─────────────────────────────────────────┐      │     │
│  │  │ Commands:                               │      │     │
│  │  │ • ping   → pong                         │      │     │
│  │  │ • start  → open audio stream, record    │      │     │
│  │  │ • stop   → close stream, transcribe     │      │     │
│  │  │ • result → return text or "pending"     │      │     │
│  │  └─────────────────────────────────────────┘      │     │
│  └───────────────────────────────────────────────────┘     │
│                           │                                 │
│                           ▼                                 │
│  ┌───────────────────────────────────────────────────┐     │
│  │  Audio Recording Pipeline                         │     │
│  │  ┌─────────────────────────────────────────┐      │     │
│  │  │ 1. Open InputStream (on "start")        │      │     │
│  │  │ 2. Capture audio chunks (callback)      │      │     │
│  │  │ 3. Close stream (on "stop")             │      │     │
│  │  │ 4. Concatenate chunks → NumPy array     │      │     │
│  │  │ 5. Auto-gain normalization              │      │     │
│  │  │ 6. Save as WAV (16kHz, mono, int16)     │      │     │
│  │  └─────────────────────────────────────────┘      │     │
│  └───────────────────────────────────────────────────┘     │
│                           │                                 │
│                           ▼                                 │
│  ┌───────────────────────────────────────────────────┐     │
│  │  Transcription Engine (Background Thread)         │     │
│  │  ┌─────────────────────────────────────────┐      │     │
│  │  │ 1. Load WAV file                        │      │     │
│  │  │ 2. Run Whisper model.transcribe()       │      │     │
│  │  │ 3. Join segments into text              │      │     │
│  │  │ 4. Store result (thread-safe)           │      │     │
│  │  │ 5. Delete WAV file                      │      │     │
│  │  └─────────────────────────────────────────┘      │     │
│  │                                                    │     │
│  │  Fallback: GPU error → reload on CPU, retry       │     │
│  └───────────────────────────────────────────────────┘     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Key Responsibilities**:
- Pre-load Whisper model (eliminates cold-start delay)
- On-demand microphone activation (privacy)
- Audio normalization and preprocessing
- Asynchronous transcription (non-blocking)
- Runtime GPU→CPU fallback on errors

**Privacy Design**:
```
Microphone Lifecycle:
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│   IDLE      │────▶│  RECORDING   │────▶│   IDLE      │
│ (mic OFF)   │     │  (mic ON)    │     │ (mic OFF)   │
└─────────────┘     └──────────────┘     └─────────────┘
     ▲                                          │
     └──────────────────────────────────────────┘
```

---

### 3️⃣ System Tray UI (`vtt-tray.ps1`)

**Technology**: PowerShell + WinForms + NotifyIcon

```
┌────────────────────────────────────────────────────┐
│           SYSTEM TRAY ARCHITECTURE                 │
├────────────────────────────────────────────────────┤
│                                                    │
│  ┌──────────────────────────────────────────┐     │
│  │  Single-Instance Mutex                   │     │
│  │  • Named mutex: "Local\VTT-Tray-v1"      │     │
│  │  • Prevents duplicate tray icons         │     │
│  └──────────────────────────────────────────┘     │
│                 │                                  │
│                 ▼                                  │
│  ┌──────────────────────────────────────────┐     │
│  │  NotifyIcon (Tray Icon)                  │     │
│  │  • Color-coded status:                   │     │
│  │    - Green  = Running                    │     │
│  │    - Amber  = Starting                   │     │
│  │    - Red    = Stopped                    │     │
│  │  • Double-click → Open Dashboard         │     │
│  │  • Right-click → Context Menu            │     │
│  └──────────────────────────────────────────┘     │
│                 │                                  │
│                 ▼                                  │
│  ┌──────────────────────────────────────────┐     │
│  │  Master Timer (3 seconds)                │     │
│  │  • Refresh status cache (Get-Process)    │     │
│  │  • Update tray icon color                │     │
│  │  • Update dashboard (if open)            │     │
│  │  • Refresh logs (file mtime check)       │     │
│  └──────────────────────────────────────────┘     │
│                 │                                  │
│                 ▼                                  │
│  ┌──────────────────────────────────────────┐     │
│  │  Dashboard Window (on-demand)            │     │
│  │  ┌────────────────────────────────┐      │     │
│  │  │ Status Panel                   │      │     │
│  │  │ • Live status + PID            │      │     │
│  │  │ • Color-coded accent stripe    │      │     │
│  │  ├────────────────────────────────┤      │     │
│  │  │ Action Buttons                 │      │     │
│  │  │ • Start / Stop / Restart       │      │     │
│  │  │ • Open Config (Notepad)        │      │     │
│  │  ├────────────────────────────────┤      │     │
│  │  │ Log Viewer                     │      │     │
│  │  │ • Combined hotkey + daemon logs│      │     │
│  │  │ • Auto-refresh (3s, mtime-aware)│     │     │
│  │  │ • Adjustable line count        │      │     │
│  │  └────────────────────────────────┘      │     │
│  └──────────────────────────────────────────┘     │
│                                                    │
└────────────────────────────────────────────────────┘
```

**Performance Optimizations**:
- **Status caching**: Single `Get-Process` call per 3s (shared by tray + dashboard)
- **Log mtime tracking**: Only re-read files when `LastWriteTime` changes
- **Single-instance**: Mutex prevents duplicate tray icons

---

## Data Flow

### Complete Recording → Transcription → Paste Flow

```
┌──────────────────────────────────────────────────────────────────────┐
│                    FULL SYSTEM DATA FLOW                             │
└──────────────────────────────────────────────────────────────────────┘

USER PRESSES Ctrl+Shift+Enter (START)
    │
    ▼
┌─────────────────────────────────────────┐
│ vtt-hotkey.ps1                          │
│ • Receives WM_HOTKEY message            │
│ • Sets recording = true                 │
│ • Sends TCP command: "start"            │
└─────────────┬───────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│ vtt-helper.py (daemon)                  │
│ • Opens audio stream (mic activated)    │
│ • Starts audio callback (capture chunks)│
│ • Plays start sound (async)             │
│ • Returns: "ok"                         │
└─────────────┬───────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│ Audio Capture Loop                      │
│ • Callback fires at ~16kHz sample rate  │
│ • Chunks stored in memory (list)        │
│ • Safety cap: 5 minutes max             │
└─────────────┬───────────────────────────┘
              │
              │ USER PRESSES Ctrl+Shift+Enter (STOP)
              ▼
┌─────────────────────────────────────────┐
│ vtt-hotkey.ps1                          │
│ • Sets recording = false, busy = true   │
│ • Sends TCP command: "stop"             │
│ • Starts result polling timer (200ms)   │
└─────────────┬───────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│ vtt-helper.py (daemon)                  │
│ • Stops & closes audio stream (mic OFF) │
│ • Concatenates chunks → NumPy array     │
│ • Applies auto-gain normalization       │
│ • Saves WAV: %TEMP%\vtt\recording.wav   │
│ • Plays stop sound (async)              │
│ • Spawns background transcription thread│
│ • Returns: "ok" (immediately)           │
└─────────────┬───────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│ Background Transcription Thread         │
│ ┌─────────────────────────────────────┐ │
│ │ 1. Load WAV file                    │ │
│ │ 2. Call model.transcribe()          │ │
│ │    • Uses pre-loaded Whisper model  │ │
│ │    • GPU or CPU (auto-detected)     │ │
│ │    • Language: from config.ini      │ │
│ │    • Beam size: 5                   │ │
│ │ 3. Join segments → text string      │ │
│ │ 4. Store in transcription_result[0] │ │
│ │ 5. Delete WAV file                  │ │
│ └─────────────────────────────────────┘ │
└─────────────┬───────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│ vtt-hotkey.ps1 (polling timer)          │
│ • Every 200ms: send "result" command    │
│ • Response: "pending" → keep polling    │
│ • Response: "text" → transcription done │
└─────────────┬───────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│ Clipboard & Paste                       │
│ • Set clipboard text: transcription     │
│ • Simulate Ctrl+V via keybd_event       │
│ • Text appears at cursor position       │
│ • Set busy = false                      │
└─────────────────────────────────────────┘
```

---

## Hotkey Workflow

### State Machine Diagram

```
┌────────────────────────────────────────────────────────────┐
│              HOTKEY STATE MACHINE                          │
└────────────────────────────────────────────────────────────┘

                    ┌──────────────┐
                    │   IDLE       │
                    │ recording=F  │
                    │ busy=F       │
                    └──────┬───────┘
                           │
              Ctrl+Shift+Enter pressed
                           │
                           ▼
                    ┌──────────────┐
                    │  RECORDING   │
                    │ recording=T  │
                    │ busy=F       │
                    │ (mic ON)     │
                    └──────┬───────┘
                           │
              Ctrl+Shift+Enter pressed
                           │
                           ▼
                    ┌──────────────┐
                    │ TRANSCRIBING │
                    │ recording=F  │
                    │ busy=T       │
                    │ (mic OFF)    │
                    └──────┬───────┘
                           │
                  Result received
                           │
                           ▼
                    ┌──────────────┐
                    │   PASTING    │
                    │ (Ctrl+V)     │
                    └──────┬───────┘
                           │
                           ▼
                    ┌──────────────┐
                    │   IDLE       │
                    └──────────────┘

Note: Hotkey is IGNORED while busy=true (prevents interruption)
```

---

## Model & Framework

### Whisper Model Architecture

```
┌────────────────────────────────────────────────────────────┐
│           FASTER-WHISPER FRAMEWORK STACK                   │
└────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  Application Layer (vtt-helper.py)                          │
│  • Config: model size, language, device                     │
│  • Audio preprocessing: normalization, WAV format           │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  faster-whisper Library                                     │
│  • Python wrapper for CTranslate2                           │
│  • WhisperModel class (pre-loaded in memory)                │
│  • Beam search decoding (beam_size=5)                       │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  CTranslate2 Inference Engine                               │
│  • Optimized Transformer inference                          │
│  • Quantization support (int8, float16)                     │
│  • Multi-device support (CUDA, CPU)                         │
└─────────────────────────┬───────────────────────────────────┘
                          │
                          ▼
┌─────────────────────────────────────────────────────────────┐
│  Hardware Layer                                             │
│  ┌──────────────────────┐  ┌──────────────────────┐         │
│  │  NVIDIA GPU (CUDA)   │  │  CPU (x86_64)        │         │
│  │  • cuBLAS library    │  │  • AVX2 optimized    │         │
│  │  • cuDNN library     │  │  • int8 quantization │         │
│  │  • float16 precision │  │                      │         │
│  │  • 3-10x faster      │  │  Fallback mode       │         │
│  └──────────────────────┘  └──────────────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

### Model Selection

| Model    | Size    | Speed   | Accuracy | Use Case                  |
|----------|---------|---------|----------|---------------------------|
| `tiny`   | ~75MB   | Fastest | Lower    | Quick notes, low-end PCs  |
| `base`   | ~150MB  | Fast    | Good     | **Default** (balanced)    |
| `small`  | ~500MB  | Medium  | Better   | Longer recordings         |
| `medium` | ~1.5GB  | Slow    | High     | Professional transcription|

**Configuration** (`config.ini`):
```ini
[vtt]
model = base          # Model size
language = en         # Language code (or "auto")
sound = on            # Audio feedback
mic_device = auto     # Microphone selection
```

---

## GPU Acceleration

### Device Detection & Fallback Strategy

```
┌────────────────────────────────────────────────────────────┐
│          GPU ACCELERATION FLOW                             │
└────────────────────────────────────────────────────────────┘

STARTUP PHASE
    │
    ▼
┌─────────────────────────────────────────┐
│ 1. Add CUDA libraries to DLL path       │
│    • nvidia.cublas → cublas/bin         │
│    • nvidia.cudnn → cudnn/bin           │
│    • os.add_dll_directory() (Win10+)    │
└─────────────┬───────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│ 2. Detect device via CTranslate2        │
│    • ctranslate2.get_cuda_device_count()│
│    • Check supported compute types      │
└─────────────┬───────────────────────────┘
              │
              ▼
        ┌─────┴─────┐
        │ GPU found?│
        └─────┬─────┘
              │
      ┌───────┴───────┐
      │               │
     YES             NO
      │               │
      ▼               ▼
┌──────────────┐  ┌──────────────┐
│ Use GPU      │  │ Use CPU      │
│ device=cuda  │  │ device=cpu   │
│ compute=f16  │  │ compute=int8 │
└──────┬───────┘  └──────┬───────┘
       │                 │
       └────────┬────────┘
                │
                ▼
┌─────────────────────────────────────────┐
│ 3. Load Whisper model                   │
│    WhisperModel(model, device, compute) │
└─────────────┬───────────────────────────┘
              │
              ▼
        ┌─────┴─────┐
        │ Success?  │
        └─────┬─────┘
              │
      ┌───────┴───────┐
      │               │
     YES             NO
      │               │
      ▼               ▼
┌──────────────┐  ┌──────────────┐
│ Ready        │  │ Fallback     │
│              │  │ Reload on CPU│
└──────────────┘  └──────┬───────┘
                         │
                         ▼
              ┌──────────────────┐
              │ Model loaded     │
              │ (guaranteed)     │
              └──────────────────┘

RUNTIME PHASE (per transcription)
    │
    ▼
┌─────────────────────────────────────────┐
│ Transcribe audio with current device    │
└─────────────┬───────────────────────────┘
              │
              ▼
        ┌─────┴─────┐
        │ Success?  │
        └─────┬─────┘
              │
      ┌───────┴───────┐
      │               │
     YES             NO
      │               │
      ▼               ▼
┌──────────────┐  ┌──────────────────────┐
│ Return text  │  │ GPU error detected?  │
└──────────────┘  │ (cublas/cudnn/cuda)  │
                  └─────────┬────────────┘
                            │
                    ┌───────┴───────┐
                    │               │
                   YES             NO
                    │               │
                    ▼               ▼
          ┌──────────────────┐  ┌──────────┐
          │ Reload on CPU    │  │ Log error│
          │ Retry transcribe │  │ Return "" │
          └────────┬─────────┘  └──────────┘
                   │
                   ▼
          ┌──────────────────┐
          │ Return text      │
          │ (CPU fallback)   │
          └──────────────────┘
```

**CUDA Library Setup** (automatic via `install.ps1`):
```powershell
python -m pip install nvidia-cublas-cu12 nvidia-cudnn-cu12
```

**No manual CUDA Toolkit installation required** — libraries are bundled with pip packages.

---

## Logging System

### Log Files & Locations

```
┌────────────────────────────────────────────────────────────┐
│              LOGGING ARCHITECTURE                          │
└────────────────────────────────────────────────────────────┘

%TEMP%\vtt\
├── debug.log          ← Hotkey listener events
│   • Hotkey presses
│   • Recording start/stop
│   • Paste actions
│   • Daemon restarts
│
├── helper.log         ← Python daemon events
│   • Model loading
│   • Device detection (GPU/CPU)
│   • Audio capture (peak, RMS, duration)
│   • Transcription results
│   • Errors & fallbacks
│
├── tray.log           ← System tray events
│   • Tray startup/shutdown
│   • Dashboard open/close
│   • Single-instance checks
│
├── port.txt           ← IPC coordination
│   • TCP port number (written by daemon)
│   • Signals "daemon ready" to hotkey script
│
├── hotkey.pid         ← Process tracking
│   • Hotkey listener PID
│   • Used for single-instance enforcement
│
└── recording.wav      ← Temporary audio file
    • Created on stop, deleted after transcription
    • 16kHz, mono, int16 PCM
```

### Log Rotation

**Automatic rotation** at 2MB threshold:
```python
if os.path.getsize(LOG_FILE) > 2MB:
    os.rename(LOG_FILE, LOG_FILE + ".old")  # Keep 1 backup
```

### Dashboard Log Viewer

**Efficiency features**:
- **File mtime tracking**: Only re-read when `LastWriteTime` changes
- **Tail mode**: Configurable line count (50, 100, 200, All)
- **Auto-refresh**: 3-second timer (only if files modified)
- **Combined view**: Hotkey + Daemon logs in single pane

---

## Auto-Start Mechanism

### Windows Registry Run Key

```
┌────────────────────────────────────────────────────────────┐
│           AUTO-START ARCHITECTURE                          │
└────────────────────────────────────────────────────────────┘

Windows Login
    │
    ▼
┌─────────────────────────────────────────┐
│ Registry Run Key Executor               │
│ HKCU\SOFTWARE\Microsoft\Windows\        │
│      CurrentVersion\Run                 │
│                                         │
│ Key: "VTT-VoiceToText"                  │
│ Value: conhost.exe --headless --        │
│        powershell.exe -File             │
│        vtt-startup.ps1                  │
└─────────────┬───────────────────────────┘
              │
              ▼
┌─────────────────────────────────────────┐
│ vtt-startup.ps1                         │
│ • Launches vtt-hotkey.ps1 (hidden)      │
│ • Launches vtt-tray.ps1 (hidden)        │
│ • Silent execution (no console window)  │
└─────────────┬───────────────────────────┘
              │
              ├──────────────┬─────────────┐
              │              │             │
              ▼              ▼             ▼
    ┌──────────────┐  ┌──────────┐  ┌──────────┐
    │ vtt-hotkey   │  │ vtt-tray │  │ daemon   │
    │ (PowerShell) │  │ (PS+GUI) │  │ (Python) │
    └──────────────┘  └──────────┘  └──────────┘
```

**Why Registry Run Key?**
- ✅ Works on corporate machines (Group Policy resistant)
- ✅ Same mechanism as Teams, OneDrive, Edge
- ✅ More reliable than Startup folder
- ✅ VBScript-free (deprecated in Win11 24H2+)

**Installation** (`install.ps1`):
```powershell
$runKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$runValue = "conhost.exe --headless -- powershell.exe -File vtt-startup.ps1"
Set-ItemProperty -Path $runKey -Name "VTT-VoiceToText" -Value $runValue
```

---

## IPC (Inter-Process Communication)

### TCP Socket Protocol

```
┌────────────────────────────────────────────────────────────┐
│              TCP IPC PROTOCOL                              │
└────────────────────────────────────────────────────────────┘

┌─────────────────────┐         ┌─────────────────────┐
│  vtt-hotkey.ps1     │         │  vtt-helper.py      │
│  (TCP Client)       │◄───────►│  (TCP Server)       │
└─────────────────────┘         └─────────────────────┘
         │                               │
         │  1. Read port from file       │
         │     %TEMP%\vtt\port.txt       │
         │◄──────────────────────────────┤
         │                               │
         │  2. Connect to 127.0.0.1:port │
         ├──────────────────────────────►│
         │                               │
         │  3. Send command (line-based) │
         │     "start\n"                 │
         ├──────────────────────────────►│
         │                               │
         │  4. Receive response          │
         │     "ok\n"                    │
         │◄──────────────────────────────┤
         │                               │
         │  5. Close connection          │
         └───────────────────────────────┘

COMMAND PROTOCOL:
┌──────────┬─────────────────────────────────────────┐
│ Command  │ Response                                │
├──────────┼─────────────────────────────────────────┤
│ ping     │ "pong"                                  │
│ start    │ "ok" or "already_recording" or "error"  │
│ stop     │ "ok"                                    │
│ result   │ "" (idle) | "pending" | "transcribed text" │
└──────────┴─────────────────────────────────────────┘
```

**Port Discovery**:
1. Daemon binds to random available port (OS-assigned)
2. Daemon writes port number to `%TEMP%\vtt\port.txt`
3. Hotkey script reads port file before each connection
4. Port file existence signals "daemon ready"

**Timeout Handling**:
- Client timeout: 5s (commands), 130s (result polling)
- Server accept timeout: 1s (allows clean shutdown)
- Result polling: 200ms interval, 120s max (600 attempts)

---

## System Requirements

### Prerequisites
- **OS**: Windows 10/11 (64-bit)
- **Python**: 3.10+ (with PATH configured)
- **Microphone**: Any Windows-compatible audio input device
- **Optional**: NVIDIA GPU with CUDA support (for acceleration)

### Dependencies

**Python Packages** (installed via `install.ps1`):
```
faster-whisper    # Whisper model inference
sounddevice       # Audio capture
scipy             # WAV file I/O
numpy             # Audio processing
nvidia-cublas-cu12   # GPU support (optional)
nvidia-cudnn-cu12    # GPU support (optional)
```

**PowerShell Modules** (built-in):
```
System.Windows.Forms  # GUI, hotkey, tray
System.Drawing        # Icon rendering
System.Net.Sockets    # TCP client
```

---

## Performance Characteristics

### Latency Breakdown

```
┌────────────────────────────────────────────────────────────┐
│         TYPICAL LATENCY (5-second recording)               │
└────────────────────────────────────────────────────────────┘

Event                          Time        Notes
─────────────────────────────────────────────────────────────
Hotkey press → start           ~10ms       WM_HOTKEY + TCP
Audio capture (5s)             5000ms      Real-time recording
Hotkey press → stop            ~10ms       WM_HOTKEY + TCP
Audio processing               ~50ms       Concat + normalize
Transcription (base, GPU)      ~500ms      Whisper inference
Transcription (base, CPU)      ~2000ms     4x slower than GPU
Result polling                 ~200ms      First poll after done
Clipboard + paste              ~50ms       Ctrl+V simulation
─────────────────────────────────────────────────────────────
TOTAL (GPU):                   ~5.8s       (5s recording + 0.8s)
TOTAL (CPU):                   ~7.3s       (5s recording + 2.3s)
```

### Memory Usage

```
Component              Resident Memory    Notes
──────────────────────────────────────────────────────────
Python daemon (idle)   ~500MB             Model loaded
Python daemon (GPU)    +200MB             CUDA overhead
Hotkey listener        ~50MB              PowerShell + .NET
System tray            ~40MB              PowerShell + WinForms
──────────────────────────────────────────────────────────
TOTAL (typical):       ~600MB             Idle state
TOTAL (recording):     ~800MB             GPU active
```

---

## Troubleshooting Guide

### Common Issues

#### 1. Hotkey Not Working
```
Symptom: Ctrl+Shift+Enter does nothing
Diagnosis:
  1. Check if VTT is running: vtt.ps1 status
  2. Check logs: vtt.ps1 logs
  3. Look for "Failed to register hotkey" in debug.log
Solution:
  • Kill stale instances: vtt.ps1 restart
  • Check for conflicting software (AutoHotkey, etc.)
```

#### 2. Wrong Language / Garbled Output
```
Symptom: Transcription in wrong language or nonsense
Diagnosis:
  • Check config.ini: language setting
  • Check helper.log: detected language
Solution:
  • Set explicit language: language = en
  • Restart VTT: vtt.ps1 restart
```

#### 3. GPU Not Detected
```
Symptom: "Using device=cpu" in helper.log
Diagnosis:
  1. Check CUDA libraries: pip list | grep nvidia
  2. Check GPU: nvidia-smi (if available)
Solution:
  • Reinstall CUDA libs: pip install --force-reinstall nvidia-cublas-cu12 nvidia-cudnn-cu12
  • CPU fallback is automatic (system still works)
```

#### 4. No Audio Captured
```
Symptom: "peak=0, no audio signal" in helper.log
Diagnosis:
  • Wrong microphone selected
  • Microphone muted in Windows
Solution:
  • Set mic_device in config.ini (device name substring)
  • Check Windows Sound settings (Recording devices)
  • Test mic: python vtt-helper.py test-mic
```

---

## Configuration Reference

### `config.ini` Options

```ini
[vtt]
# ── Model Selection ──
# Options: tiny, base, small, medium
# Trade-off: size vs accuracy vs speed
model = base

# ── Language Detection ──
# Options: auto (auto-detect), en, he, es, fr, de, it, pt, ru, zh, ja, ko, etc.
# Recommendation: Set explicit language for better accuracy
language = en

# ── Microphone Selection ──
# Options: auto (smart detection), or device name substring
# Examples: "Headset", "USB", "Jabra", "Realtek"
# Smart auto-detection prefers headsets over built-in mics
mic_device = auto

# ── Audio Feedback ──
# Options: on, off
# Plays system sounds on recording start/stop
sound = on
```

### Management Commands

```powershell
# Start VTT (kills existing instance first)
powershell -ExecutionPolicy Bypass -File vtt.ps1 start

# Stop VTT
powershell -ExecutionPolicy Bypass -File vtt.ps1 stop

# Restart VTT (apply config changes)
powershell -ExecutionPolicy Bypass -File vtt.ps1 restart

# Check status (running/stopped + daemon health)
powershell -ExecutionPolicy Bypass -File vtt.ps1 status

# View recent logs (hotkey + daemon + tray)
powershell -ExecutionPolicy Bypass -File vtt.ps1 logs

# Start system tray UI
powershell -ExecutionPolicy Bypass -File vtt.ps1 tray

# Stop system tray UI
powershell -ExecutionPolicy Bypass -File vtt.ps1 tray-stop
```

---

## Security & Privacy

### Privacy Guarantees

```
┌────────────────────────────────────────────────────────────┐
│              PRIVACY ARCHITECTURE                          │
└────────────────────────────────────────────────────────────┘

✅ Microphone only active during recording
   • Opened on "start" command
   • Closed on "stop" command
   • Windows shows mic indicator only when recording

✅ Fully offline operation
   • No network requests
   • No cloud API calls
   • No telemetry

✅ Local data storage
   • Audio: %TEMP%\vtt\recording.wav (deleted after transcription)
   • Logs: %TEMP%\vtt\*.log (local only)
   • Model: ~/.cache/huggingface/ (local cache)

✅ No persistent audio storage
   • WAV file deleted immediately after transcription
   • No audio history or recordings kept

✅ Process isolation
   • TCP server: localhost only (127.0.0.1)
   • No external network access
```

### Security Best Practices

**Logs contain transcribed text** — if handling sensitive data:
```powershell
# Clear logs manually
Remove-Item $env:TEMP\vtt\*.log -Force

# Or disable logging (edit vtt-helper.py, vtt-hotkey.ps1)
# Comment out all Log() and log() calls
```

**Model cache location**:
```
%USERPROFILE%\.cache\huggingface\hub\
```

---

## Future Enhancements

### Potential Improvements

1. **Multi-language mixing**: Auto-detect language per recording (not per session)
2. **Custom vocabulary**: Boost recognition of domain-specific terms
3. **Punctuation model**: Add automatic punctuation (currently minimal)
4. **Speaker diarization**: Identify multiple speakers in recordings
5. **Real-time streaming**: Live transcription during recording (vs post-recording)
6. **Hotkey customization**: User-configurable hotkey (currently hardcoded)
7. **Cloud sync**: Optional cloud backup of transcriptions (opt-in)
8. **Mobile companion**: Android/iOS app for remote transcription

---

## Credits & License

**VTT (Voice-to-Text)** is built on:
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper) by SYSTRAN
- [OpenAI Whisper](https://github.com/openai/whisper) (original model)
- [CTranslate2](https://github.com/OpenNMT/CTranslate2) (inference engine)

**Author**: Idan Shemtov  
**Repository**: https://github.com/idan-shem-tov/whisper-support-for-devin  
**License**: MIT (check repository for details)

---

## Quick Reference Card

```
┌────────────────────────────────────────────────────────────┐
│                  VTT QUICK REFERENCE                       │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  HOTKEY                                                    │
│  ───────                                                   │
│  Ctrl+Shift+Enter  →  Toggle recording (start/stop)       │
│                                                            │
│  TRAY ICON COLORS                                          │
│  ────────────────                                          │
│  🟢 Green   →  Running (ready)                             │
│  🟠 Amber   →  Starting (loading model)                    │
│  🔴 Red     →  Stopped                                     │
│                                                            │
│  COMMANDS                                                  │
│  ────────                                                  │
│  vtt.ps1 start    →  Start VTT                             │
│  vtt.ps1 stop     →  Stop VTT                              │
│  vtt.ps1 restart  →  Restart (apply config changes)        │
│  vtt.ps1 status   →  Check running status                  │
│  vtt.ps1 logs     →  View recent logs                      │
│  vtt.ps1 tray     →  Start system tray                     │
│                                                            │
│  CONFIG FILE                                               │
│  ───────────                                               │
│  config.ini  →  Model, language, sound, mic settings       │
│                                                            │
│  LOGS                                                      │
│  ────                                                      │
│  %TEMP%\vtt\debug.log   →  Hotkey events                  │
│  %TEMP%\vtt\helper.log  →  Transcription logs             │
│  %TEMP%\vtt\tray.log    →  Tray UI logs                   │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

---

**End of Architecture Documentation**
