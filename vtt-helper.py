"""
vtt-helper.py - Voice-to-Text helper (Windows-native, no WSL needed)
Usage:
  python vtt-helper.py daemon      - Run as daemon: record + transcribe with model pre-loaded
  python vtt-helper.py test-mic    - Test all microphones
"""
import sys
import os
import time
import collections
import threading
import numpy as np
import sounddevice as sd
import scipy.io.wavfile as wav

VTT_DIR = os.path.join(os.environ.get("TEMP", r"C:\Temp"), "vtt")
WAV_PATH = os.path.join(VTT_DIR, "recording.wav")
START_FILE = os.path.join(VTT_DIR, "start")
STOP_FILE = os.path.join(VTT_DIR, "stop")
READY_FILE = os.path.join(VTT_DIR, "ready")
RESULT_FILE = os.path.join(VTT_DIR, "result.txt")
LOG_FILE = os.path.join(VTT_DIR, "helper.log")
RATE = 16000
CHANNELS = 1
PRE_BUFFER_SECS = 2
TRANSCRIBE_TIMEOUT_SECS = 120

os.makedirs(VTT_DIR, exist_ok=True)


def log(msg):
    ts = time.strftime("%H:%M:%S")
    line = f"{ts} {msg}"
    print(line, file=sys.stderr, flush=True)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


def pick_device():
    """Pick the best input device."""
    config_file = os.path.join(VTT_DIR, "device.txt")
    if os.path.exists(config_file):
        try:
            device = int(open(config_file).read().strip())
            log(f"Using saved device {device}")
            return device
        except Exception:
            pass

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
    Flow:
      1. Loads whisper model at startup (one-time cost)
      2. Listens with a 2s ring buffer
      3. START_FILE -> begin capturing (includes pre-buffer)
      4. STOP_FILE -> stop, normalize, transcribe, write RESULT_FILE
    """
    # Cleanup
    for f in [START_FILE, STOP_FILE, READY_FILE, WAV_PATH, RESULT_FILE]:
        if os.path.exists(f):
            os.remove(f)

    # Pre-load the whisper model
    log("Loading whisper model...")
    from faster_whisper import WhisperModel
    model = WhisperModel("base", device="cpu", compute_type="int8")
    log("Model loaded")

    device = pick_device()
    pre_buffer_frames = PRE_BUFFER_SECS * RATE
    ring = collections.deque(maxlen=pre_buffer_frames)
    recording_chunks = []
    is_recording = False

    def callback(indata, frames, time_info, status):
        nonlocal is_recording
        samples = indata[:, 0].copy()
        if is_recording:
            recording_chunks.append(samples)
        else:
            ring.extend(samples)

    log(f"Daemon starting, device={device}, pre-buffer={PRE_BUFFER_SECS}s")

    # Transcription state (non-blocking)
    transcribe_thread = None
    transcribe_start_time = None
    transcribe_result = [None, None]  # [text, info]
    transcribe_error = [None]
    transcribe_duration = 0.0

    def start_transcribe_thread(wav_path, audio_duration):
        nonlocal transcribe_thread, transcribe_start_time, transcribe_duration
        transcribe_result[0] = None
        transcribe_result[1] = None
        transcribe_error[0] = None
        transcribe_duration = audio_duration

        def do_transcribe():
            try:
                segments, info = model.transcribe(wav_path, beam_size=5)
                text = " ".join(s.text.strip() for s in segments)
                transcribe_result[0] = text
                transcribe_result[1] = info
            except Exception as e:
                transcribe_error[0] = e

        transcribe_thread = threading.Thread(target=do_transcribe, daemon=True)
        transcribe_start_time = time.time()
        transcribe_thread.start()

    def check_transcribe_done():
        """Check if background transcription finished. Returns True if done/timed out."""
        nonlocal transcribe_thread, transcribe_start_time
        if transcribe_thread is None:
            return True
        if not transcribe_thread.is_alive():
            elapsed = time.time() - transcribe_start_time
            if transcribe_error[0]:
                log(f"ERROR: Transcription failed: {transcribe_error[0]}")
                with open(RESULT_FILE, "w", encoding="utf-8") as f:
                    f.write("")
            else:
                text = transcribe_result[0] or ""
                info = transcribe_result[1]
                lang = info.language if info else "?"
                log(f"Transcribed in {elapsed:.1f}s, lang={lang}: [{text}]")
                with open(RESULT_FILE, "w", encoding="utf-8") as f:
                    f.write(text)
            cleanup_after_transcribe()
            return True
        # Check timeout
        if time.time() - transcribe_start_time > TRANSCRIBE_TIMEOUT_SECS:
            log(f"ERROR: Transcription timed out after {TRANSCRIBE_TIMEOUT_SECS}s ({transcribe_duration:.1f}s audio). Writing empty result.")
            with open(RESULT_FILE, "w", encoding="utf-8") as f:
                f.write("")
            cleanup_after_transcribe()
            return True
        return False

    def cleanup_after_transcribe():
        nonlocal transcribe_thread, transcribe_start_time
        transcribe_thread = None
        transcribe_start_time = None
        for cleanup_file in [WAV_PATH, START_FILE, STOP_FILE]:
            if os.path.exists(cleanup_file):
                try:
                    os.remove(cleanup_file)
                except Exception:
                    pass

    with sd.InputStream(samplerate=RATE, channels=CHANNELS, dtype="int16",
                        callback=callback, device=device):
        # Signal that we're ready
        open(READY_FILE, "w").close()
        log("Daemon ready, waiting for signals...")

        while True:
            # Check if a background transcription finished
            is_transcribing = not check_transcribe_done()

            if is_transcribing:
                # Drain any signal files created while we're busy
                for f in [START_FILE, STOP_FILE]:
                    if os.path.exists(f):
                        try:
                            os.remove(f)
                        except Exception:
                            pass

            elif not is_recording and os.path.exists(START_FILE):
                os.remove(START_FILE)
                if os.path.exists(RESULT_FILE):
                    os.remove(RESULT_FILE)
                recording_chunks.clear()
                recording_chunks.append(np.array(list(ring), dtype=np.int16))
                is_recording = True
                log(f"Recording started (pre-buffer={len(ring)} samples)")

            elif is_recording and os.path.exists(STOP_FILE):
                os.remove(STOP_FILE)
                is_recording = False

                if recording_chunks:
                    audio = np.concatenate(recording_chunks)
                    peak = int(np.max(np.abs(audio)))
                    rms = float(np.sqrt(np.mean(audio.astype(float)**2)))
                    duration = len(audio) / RATE
                    log(f"Recording stopped: {duration:.1f}s, peak={peak}, rms={rms:.0f}")
                    recording_chunks.clear()

                    # Normalize audio
                    if peak > 10:
                        target = 26000
                        gain = min(target / peak, 200)
                        audio_float = audio.astype(np.float64) * gain
                        audio = np.clip(audio_float, -32767, 32767).astype(np.int16)
                        log(f"Applied {gain:.1f}x gain")

                    # Save wav (needed by faster_whisper)
                    wav.write(WAV_PATH, RATE, audio)

                    # Start non-blocking transcription
                    log("Transcribing...")
                    start_transcribe_thread(WAV_PATH, duration)
                else:
                    log("No audio captured")
                    with open(RESULT_FILE, "w") as f:
                        f.write("")

            time.sleep(0.05)


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
    print(f"\nTo set a specific device, write its number to: {VTT_DIR}\\device.txt")


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
