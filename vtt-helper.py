"""
vtt-helper.py - Voice-to-Text helper (Windows-native, no WSL needed)
Usage:
  python vtt-helper.py daemon      - Run as daemon: record + transcribe with model pre-loaded
  python vtt-helper.py test-mic    - Test all microphones
"""
import sys
import os
import time
import socket
import collections
import configparser
import threading
import winsound
import numpy as np
import sounddevice as sd
import scipy.io.wavfile as wav

VTT_DIR = os.path.join(os.environ.get("TEMP", r"C:\Temp"), "vtt")
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, "config.ini")
WAV_PATH = os.path.join(VTT_DIR, "recording.wav")
PORT_FILE = os.path.join(VTT_DIR, "port.txt")
LOG_FILE = os.path.join(VTT_DIR, "helper.log")
RATE = 16000
CHANNELS = 1
PRE_BUFFER_SECS = 2
MAX_RECORDING_SECS = 300  # 5 minute safety cap
LOG_MAX_BYTES = 2 * 1024 * 1024  # 2 MB log rotation threshold

# Audio feedback sounds (played async so they don't block recording)
SND_START = r"C:\Windows\Media\Speech On.wav"
SND_STOP  = r"C:\Windows\Media\Speech Off.wav"

def play_sound(path):
    """Play a WAV file asynchronously (non-blocking)."""
    try:
        # SND_NODEFAULT: don't play any fallback system sound if the file is missing
        winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)
    except Exception as e:
        log(f"WARNING: failed to play sound '{path}': {e}")

os.makedirs(VTT_DIR, exist_ok=True)


def log(msg):
    ts = time.strftime("%H:%M:%S")
    line = f"{ts} {msg}"
    # Rotate log if it exceeds threshold
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX_BYTES:
            old = LOG_FILE + ".old"
            if os.path.exists(old):
                os.remove(old)
            os.rename(LOG_FILE, old)
    except Exception:
        pass
    try:
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except Exception:
        pass


def load_config():
    """Load all settings from config.ini. Returns a dict with keys:
    model (str), language (str or None), sound (bool).
    """
    defaults = {"model": "base", "language": None, "sound": True}

    if not os.path.exists(CONFIG_FILE):
        log(f"No config.ini found at {CONFIG_FILE}, using defaults")
        return defaults

    cfg = configparser.ConfigParser()
    cfg.read(CONFIG_FILE, encoding="utf-8")

    if not cfg.has_section("vtt"):
        log("config.ini has no [vtt] section, using defaults")
        return defaults

    result = dict(defaults)

    # Model
    val = cfg.get("vtt", "model", fallback="base").strip().lower()
    if val:
        result["model"] = val
    log(f"Config: model={result['model']}")

    # Language
    val = cfg.get("vtt", "language", fallback="auto").strip().lower()
    if val and val != "auto":
        result["language"] = val
        log(f"Config: language={val}")
    else:
        result["language"] = None
        log("Config: language=auto-detect")

    # Sound
    val = cfg.get("vtt", "sound", fallback="on").strip().lower()
    result["sound"] = val in ("on", "true", "yes", "1")
    log(f"Config: sound={'on' if result['sound'] else 'off'}")

    return result


def pick_device():
    """Auto-detect the active microphone by sampling real audio signal.

    Works like Teams/Zoom: briefly records from every candidate input device
    and picks the one with the highest RMS signal level.

    Strategy:
      1. Enumerate all input devices, skipping known loopback/virtual ones.
      2. Prefer MME API (most compatible with Whisper/sounddevice on Windows);
         deduplicate by name so each physical mic is only tested once.
      3. Record SAMPLE_SECS of audio from each candidate in parallel threads.
      4. Pick the device with the highest RMS. If all are silent (rms==0),
         fall back to the OS default input device.
    """
    SAMPLE_SECS = 0.3          # how long to record from each device (seconds)
    SAMPLE_RATE = 16000
    # Known loopback / virtual device name fragments — never real mics
    LOOPBACK_NAMES = [
        "stereo mix", "what u hear", "wave out", "loopback",
        "virtual", "vb-", "voicemeeter", "output",
    ]
    # Preferred API order for deduplication (index = priority, lower = better)
    API_PREF = ["MME", "Windows DirectSound", "Windows WASAPI"]

    devices = sd.query_devices()
    default_in = sd.default.device[0]

    # --- Build candidate list ---
    # Key by lowercase name so each physical mic appears once (best API wins).
    candidates = {}  # name_key -> (device_index, api_name, display_name)
    for i, d in enumerate(devices):
        if d['max_input_channels'] < 1:
            continue
        api_name = sd.query_hostapis(d['hostapi'])['name']
        name = d['name']
        name_lower = name.lower()

        # Skip loopback/virtual
        if any(bad in name_lower for bad in LOOPBACK_NAMES):
            continue

        # Deduplicate: keep entry with best (lowest index) API preference
        pref = API_PREF.index(api_name) if api_name in API_PREF else len(API_PREF)
        key = name_lower
        if key not in candidates or pref < candidates[key][3]:
            candidates[key] = (i, api_name, name, pref)

    candidate_list = [(idx, api, name) for (idx, api, name, _) in candidates.values()]

    log(f"Sampling {len(candidate_list)} input device(s) to find the active mic...")

    # --- Sample each device in parallel ---
    results = {}  # device_index -> rms

    def sample_device(idx, name):
        try:
            frames = int(SAMPLE_RATE * SAMPLE_SECS)
            audio = sd.rec(frames, samplerate=SAMPLE_RATE, channels=1,
                           dtype="int16", device=idx)
            sd.wait()
            rms = float(np.sqrt(np.mean(audio.astype(np.float64) ** 2)))
            results[idx] = rms
        except Exception as e:
            results[idx] = 0.0
            log(f"  [{idx}] {name}: sample error — {e}")

    threads = []
    for idx, api, name in candidate_list:
        t = threading.Thread(target=sample_device, args=(idx, name), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join(timeout=SAMPLE_SECS + 2)

    # --- Log results and pick winner ---
    log("Input device signal levels:")
    for idx, api, name in sorted(candidate_list, key=lambda x: x[0]):
        rms = results.get(idx, 0.0)
        log(f"  [{idx:2d}] rms={rms:7.1f}  {api}: {name}")

    if not results:
        log(f"WARNING: Could not sample any device, falling back to OS default ({default_in})")
        return default_in

    best_idx = max(results, key=results.get)
    best_rms = results[best_idx]
    best_name = devices[best_idx]['name']
    best_api  = sd.query_hostapis(devices[best_idx]['hostapi'])['name']

    if best_rms == 0.0:
        # All devices returned silence — could be a quiet room; still pick the
        # highest-ranked candidate by API preference rather than a random default.
        log("WARNING: All devices returned silence during sampling (quiet room or mic muted?). "
            "Picking best candidate by API preference.")
        # Sort by API preference then by device index
        candidate_list.sort(key=lambda x: (API_PREF.index(x[1]) if x[1] in API_PREF else 99, x[0]))
        best_idx = candidate_list[0][0]
        best_name = devices[best_idx]['name']
        best_api  = sd.query_hostapis(devices[best_idx]['hostapi'])['name']

    log(f"Auto-selected device {best_idx}: {best_name} ({best_api}, rms={results.get(best_idx, 0):.1f})")
    return best_idx


def daemon():
    """Run as daemon: record with pre-buffer, transcribe with pre-loaded model.
    Uses a TCP server on localhost for IPC with the hotkey script.
    Commands: start, stop, result, ping
    """
    # Load config
    config = load_config()
    sound_enabled = config["sound"]

    # Pre-load the whisper model
    model_name = config["model"]
    log(f"Loading whisper model ({model_name})...")
    from faster_whisper import WhisperModel
    model = WhisperModel(model_name, device="cpu", compute_type="int8")
    log("Model loaded")

    language = config["language"]
    device = pick_device()
    recording_chunks = []
    recording_start_time = [0.0]  # track when recording started
    lock = threading.Lock()  # protects recording state and chunks
    
    # Audio stream state (only active when recording)
    audio_stream = [None]  # holds the active InputStream or None
    stream_lock = threading.Lock()  # protects audio_stream

    # Transcription state (background thread writes result here)
    transcription_result = [None]  # None=idle, "pending"=working, str=done
    transcription_lock = threading.Lock()

    def callback(indata, frames, time_info, status):
        """Audio callback - only called when stream is active (during recording)."""
        samples = indata[:, 0].copy()
        with lock:
            # Safety cap: auto-stop after MAX_RECORDING_SECS
            if time.time() - recording_start_time[0] > MAX_RECORDING_SECS:
                log(f"Recording auto-stopped after {MAX_RECORDING_SECS}s safety cap")
                # Stop will be handled by the next command
            else:
                recording_chunks.append(samples)

    log(f"Daemon starting, device={device} (mic will activate only when recording)")

    def do_transcribe_bg(wav_path):
        """Transcribe in background thread, store result."""
        text = ""
        try:
            kwargs = {"beam_size": 5}
            if language:
                kwargs["language"] = language
            segments, info = model.transcribe(wav_path, **kwargs)
            text = " ".join(s.text.strip() for s in segments)
            lang = info.language if info else "?"
            log(f"Transcribed ({lang}): [{text}]")
        except Exception as e:
            try:
                log(f"ERROR: Transcription failed: {e}")
            except Exception:
                pass  # log() itself failed, but we still have text if it was set
        finally:
            # ALWAYS set the result so PS side never gets stuck on "pending"
            with transcription_lock:
                transcription_result[0] = text
            try:
                os.remove(wav_path)
            except Exception:
                pass

    def handle_start():
        """Handle 'start' command: open audio stream and begin recording."""
        with stream_lock:
            if audio_stream[0] is not None:
                # Already recording
                if sound_enabled:
                    play_sound(SND_START)
                log("Start requested but already recording")
                return "already_recording"
            
            # Open the audio stream
            try:
                audio_stream[0] = sd.InputStream(
                    samplerate=RATE, 
                    channels=CHANNELS, 
                    dtype="int16",
                    callback=callback, 
                    device=device
                )
                audio_stream[0].start()
            except Exception as e:
                log(f"ERROR: Failed to open audio stream: {e}")
                audio_stream[0] = None
                return "error"
        
        with lock:
            recording_chunks.clear()
            recording_start_time[0] = time.time()
        
        if sound_enabled:
            play_sound(SND_START)
        log("Recording started (microphone activated)")
        return "ok"

    def handle_stop():
        """Handle 'stop' command: stop recording, close audio stream, start transcription in background."""
        # Stop and close the audio stream
        with stream_lock:
            if audio_stream[0] is None:
                # Not recording
                return "ok"
            try:
                audio_stream[0].stop()
                audio_stream[0].close()
            except Exception as e:
                log(f"WARNING: Error closing audio stream: {e}")
            finally:
                audio_stream[0] = None
        
        with lock:
            chunks = list(recording_chunks)
            recording_chunks.clear()

        if sound_enabled:
            play_sound(SND_STOP)
        
        log("Recording stopped (microphone deactivated)")

        if not chunks:
            log("No audio captured")
            with transcription_lock:
                transcription_result[0] = ""
            return "ok"

        audio = np.concatenate(chunks)
        peak = int(np.max(np.abs(audio)))
        rms = float(np.sqrt(np.mean(audio.astype(float)**2)))
        duration = len(audio) / RATE
        log(f"Audio captured: {duration:.1f}s, peak={peak}, rms={rms:.0f}")

        # Normalize audio (apply gain if signal is present but quiet)
        if peak > 0:
            target = 26000
            gain = min(target / peak, 200)
            audio_float = audio.astype(np.float64) * gain
            audio = np.clip(audio_float, -32767, 32767).astype(np.int16)
            log(f"Applied {gain:.1f}x gain (peak was {peak})")
        else:
            log("WARNING: peak=0, no audio signal at all — check microphone device")

        # Save wav and start background transcription
        wav.write(WAV_PATH, RATE, audio)
        with transcription_lock:
            transcription_result[0] = "pending"
        log("Transcribing...")
        t = threading.Thread(target=do_transcribe_bg, args=(WAV_PATH,), daemon=True)
        t.start()
        return "ok"

    def handle_result():
        """Handle 'result' command: return transcription result or 'pending'."""
        with transcription_lock:
            val = transcription_result[0]
        if val is None:
            return ""
        if val == "pending":
            return "pending"
        # Got a result — reset state and return it
        with transcription_lock:
            transcription_result[0] = None
        # Sanitize: replace newlines so TCP line-based protocol isn't broken
        return val.replace("\n", " ").replace("\r", "")

    def handle_client(conn):
        """Handle a single client connection."""
        try:
            conn.settimeout(5.0)  # prevent hung clients from blocking the server
            data = conn.recv(1024).decode("utf-8").strip()
            if not data:
                return

            if data == "ping":
                conn.sendall(b"pong\n")
            elif data == "start":
                result = handle_start()
                conn.sendall(f"{result}\n".encode("utf-8"))
            elif data == "stop":
                result = handle_stop()
                conn.sendall(f"{result}\n".encode("utf-8"))
            elif data == "result":
                result = handle_result()
                conn.sendall(f"{result}\n".encode("utf-8"))
            else:
                conn.sendall(b"error: unknown command\n")
        except Exception as e:
            log(f"Client handler error: {e}")
        finally:
            conn.close()

    # Start TCP server on a free port
    # Note: Audio stream is now opened on-demand when recording starts
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", 0))
    port = srv.getsockname()[1]
    srv.listen(1)
    srv.settimeout(1.0)  # accept timeout for clean shutdown

    # Write port file (signals "ready" to the hotkey script)
    with open(PORT_FILE, "w") as f:
        f.write(str(port))
    log(f"Daemon ready, listening on 127.0.0.1:{port}")

    try:
        while True:
            try:
                conn, addr = srv.accept()
                handle_client(conn)
            except socket.timeout:
                continue
            except Exception as e:
                log(f"Accept error: {e}")
                time.sleep(0.1)
    except Exception as e:
        log(f"FATAL: Server error: {e}")
        raise
    finally:
        # Clean up: close any open audio stream
        with stream_lock:
            if audio_stream[0] is not None:
                try:
                    audio_stream[0].stop()
                    audio_stream[0].close()
                except Exception:
                    pass
                audio_stream[0] = None
        
        srv.close()
        try:
            os.remove(PORT_FILE)
        except Exception:
            pass


def test_mic():
    """Test all input devices and report signal levels."""
    print("Testing all input devices (speak continuously!)...\n")
    devices = sd.query_devices()
    for i, d in enumerate(devices):
        if d['max_input_channels'] < 1:
            continue
        api_name = sd.query_hostapis(d['hostapi'])['name']
        try:
            audio = sd.rec(RATE * 2, samplerate=RATE, channels=1, dtype='int16', device=i)
            sd.wait()
            peak = int(np.max(np.abs(audio)))
            rms = float(np.sqrt(np.mean(audio.astype(float)**2)))
            status = "GOOD" if peak > 500 else "LOW" if peak > 50 else "SILENT"
            name = d['name'][:50]
            print(f"  [{i:2d}] {status:6s} Peak={peak:5d} RMS={rms:6.0f}  {api_name}: {name}")
        except Exception as e:
            name = d['name'][:40]
            print(f"  [{i:2d}] ERROR  {name}: {e}")
    print(f"\nDefault device is auto-detected. Edit config.ini to change other settings.")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python vtt-helper.py [daemon|test-mic]")
        sys.exit(1)

    cmd = sys.argv[1]
    if cmd == "daemon":
        daemon()
    elif cmd == "test-mic":
        test_mic()
    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)
