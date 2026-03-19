# VTT Improvement Plan

Tracked improvements for the VTT (Voice-to-Text) project.

---

## Completed

### #2 — Audio feedback for recording state
- **Status:** Done
- **Problem:** User had no indication when recording starts or stops.
- **Solution:** Python daemon plays Windows WAV sounds via `winsound` — "Speech On.wav" on start, "Speech Off.wav" on stop. Configurable via `sound = on/off` in `config.ini`.
- **Files changed:** `vtt-helper.py`
- **Note:** Sounds must come from the daemon (Python) process, not the hidden PowerShell process, because hidden windows cannot play audio.

### #5 — Unified config file
- **Status:** Done
- **Problem:** Config was scattered across individual text files (`device.txt`, `language.txt`, `model.txt`) in `%TEMP%\vtt\`, which could be deleted by disk cleanup.
- **Solution:** Single `config.ini` in the VTT folder using Python's `configparser`. Settings: `model`, `language`, `sound`. Old individual text files removed.
- **Files changed:** `vtt-helper.py`, `README.md`, new `config.ini`

### #8 — Safer process cleanup on hotkey registration failure
- **Status:** Done
- **Problem:** When hotkey registration failed, the script killed *all* PowerShell processes in the session.
- **Solution:** Only kills PowerShell processes whose command line contains `vtt-hotkey.ps1`.
- **Files changed:** `vtt-hotkey.ps1`

### Daemon resilience (bug fix)
- **Status:** Done
- **Problem:** If the daemon died silently (e.g., audio device disconnect), the hotkey script would hang for 125 seconds waiting for a result that would never come.
- **Solution:** (1) Stop branch checks if daemon is alive before waiting. (2) Wait loop checks daemon health every 2s and bails if dead. (3) Daemon main loop has try/except to log fatal errors and clean up signal files before exit.
- **Files changed:** `vtt-hotkey.ps1`, `vtt-helper.py`

### Reliable paste via keybd_event
- **Status:** Done
- **Problem:** `SendKeys("^v")` didn't work in some apps (typed literal "v" instead of Ctrl+V).
- **Solution:** Replaced `SendKeys` with `keybd_event` P/Invoke — simulates hardware-level Ctrl+V keypresses. Works across all apps including shells and command lines.
- **Files changed:** `vtt-hotkey.ps1`

---

## Pending

### #1 — Replace file-based IPC with localhost sockets
- **Status:** Not started
- **Problem:** Polling `%TEMP%\vtt\` every 50ms is slow, fragile, and can race.
- **Solution:** Use a localhost TCP socket. The daemon listens on a port, the hotkey script connects and sends commands. Communication becomes instant and atomic.
- **Files changed:** `vtt-helper.py`, `vtt-hotkey.ps1`, `vtt.ps1`

---

## Future ideas (not yet planned)

- #3 — Stop clobbering the clipboard (save/restore)
- #4 — Voice Activity Detection (VAD) for auto-stop
- #6 — GPU acceleration (auto-detect CUDA)
- #7 — Log rotation
- #9 — Cancel gesture (abort recording without transcribing)
- #10 — Streaming/partial transcription
