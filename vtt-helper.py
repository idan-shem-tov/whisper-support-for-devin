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
        winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC)
    except Exception:
        pass

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
    """Auto-detect the best input device."""
    devices = sd.query_devices()
    for i, d in enumerate(devices):
        api_name = sd.query_hostapis(d['hostapi'])['name']
        if 'Microphone Array' in d['name'] and 'MME' in api_name:
            log(f"Auto-selected device {i}: {d['name']}")
            return i

    device = sd.default.device[0]
    log(f"Using default input device {device}")
    return device


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
    pre_buffer_frames = PRE_BUFFER_SECS * RATE
    ring = collections.deque(maxlen=pre_buffer_frames)
    recording_chunks = []
    is_recording = False
    recording_start_time = [0.0]  # track when recording started
    lock = threading.Lock()  # protects is_recording and recording_chunks

    # Transcription state (background thread writes result here)
    transcription_result = [None]  # None=idle, "pending"=working, str=done
    transcription_lock = threading.Lock()

    def callback(indata, frames, time_info, status):
        nonlocal is_recording
        samples = indata[:, 0].copy()
        with lock:
            if is_recording:
                # Safety cap: auto-stop after MAX_RECORDING_SECS
                if time.time() - recording_start_time[0] > MAX_RECORDING_SECS:
                    is_recording = False
                    log(f"Recording auto-stopped after {MAX_RECORDING_SECS}s safety cap")
                else:
                    recording_chunks.append(samples)
            else:
                ring.extend(samples)

    log(f"Daemon starting, device={device}, pre-buffer={PRE_BUFFER_SECS}s")

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
        """Handle 'start' command: begin recording."""
        nonlocal is_recording
        with lock:
            if is_recording:
                return "already_recording"
            recording_chunks.clear()
            recording_chunks.append(np.array(list(ring), dtype=np.int16))
            is_recording = True
            recording_start_time[0] = time.time()
        if sound_enabled:
            play_sound(SND_START)
        log(f"Recording started (pre-buffer={len(ring)} samples)")
        return "ok"

    def handle_stop():
        """Handle 'stop' command: stop recording, start transcription in background."""
        nonlocal is_recording
        with lock:
            if not is_recording:
                return "ok"
            is_recording = False
            chunks = list(recording_chunks)
            recording_chunks.clear()

        if sound_enabled:
            play_sound(SND_STOP)

        if not chunks:
            log("No audio captured")
            with transcription_lock:
                transcription_result[0] = ""
            return "ok"

        audio = np.concatenate(chunks)
        peak = int(np.max(np.abs(audio)))
        rms = float(np.sqrt(np.mean(audio.astype(float)**2)))
        duration = len(audio) / RATE
        log(f"Recording stopped: {duration:.1f}s, peak={peak}, rms={rms:.0f}")

        # Normalize audio
        if peak > 10:
            target = 26000
            gain = min(target / peak, 200)
            audio_float = audio.astype(np.float64) * gain
            audio = np.clip(audio_float, -32767, 32767).astype(np.int16)
            log(f"Applied {gain:.1f}x gain")

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

    # Start audio stream
    with sd.InputStream(samplerate=RATE, channels=CHANNELS, dtype="int16",
                        callback=callback, device=device):

        # Start TCP server on a free port
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
