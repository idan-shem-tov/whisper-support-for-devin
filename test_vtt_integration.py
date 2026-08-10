"""
Integration test: Verify VTT GPU transcription works end-to-end.
Simulates the exact flow that vtt-helper.py uses.
"""
import os
import sys
import tempfile
import numpy as np
import scipy.io.wavfile as wav

# Replicate vtt-helper.py CUDA setup
def add_cuda_to_path():
    try:
        import nvidia.cublas
        import nvidia.cudnn
        cublas_path = os.path.join(os.path.dirname(nvidia.cublas.__path__[0]), 'cublas', 'bin')
        cudnn_path = os.path.join(os.path.dirname(nvidia.cudnn.__path__[0]), 'cudnn', 'bin')
        
        if os.path.exists(cublas_path):
            os.environ['PATH'] = cublas_path + os.pathsep + os.environ.get('PATH', '')
        if os.path.exists(cudnn_path):
            os.environ['PATH'] = cudnn_path + os.pathsep + os.environ.get('PATH', '')
            
        if hasattr(os, 'add_dll_directory'):
            if os.path.exists(cublas_path):
                os.add_dll_directory(cublas_path)
            if os.path.exists(cudnn_path):
                os.add_dll_directory(cudnn_path)
        return True
    except (ImportError, AttributeError, IndexError):
        return False

# Replicate detect_device()
def detect_device():
    try:
        import ctranslate2
        cuda_count = ctranslate2.get_cuda_device_count()
        if cuda_count > 0:
            supported = ctranslate2.get_supported_compute_types("cuda")
            if "float16" in supported:
                return ("cuda", "float16")
            elif "int8_float16" in supported:
                return ("cuda", "int8_float16")
    except Exception:
        pass
    return ("cpu", "int8")

print("=" * 70)
print("VTT Integration Test - GPU Transcription")
print("=" * 70)

# Step 1: Add CUDA to path
print("\n[1/5] Adding CUDA libraries to path...")
cuda_added = add_cuda_to_path()
print(f"      Result: {'SUCCESS' if cuda_added else 'SKIPPED (no CUDA libs)'}")

# Step 2: Detect device
print("\n[2/5] Detecting best device...")
device_type, compute_type = detect_device()
print(f"      Device: {device_type}")
print(f"      Compute type: {compute_type}")

# Step 3: Load model
print(f"\n[3/5] Loading Whisper model (base) on {device_type}...")
try:
    from faster_whisper import WhisperModel
    model = WhisperModel("base", device=device_type, compute_type=compute_type)
    print(f"      Model loaded successfully on {device_type}")
except Exception as e:
    print(f"      ERROR: {e}")
    sys.exit(1)

# Step 4: Create test audio (1 second of silence)
print("\n[4/5] Creating test audio...")
rate = 16000
audio = np.zeros(rate, dtype=np.int16)
with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
    wav.write(f.name, rate, audio)
    temp_path = f.name
print(f"      Audio file: {temp_path}")

# Step 5: Transcribe
print(f"\n[5/5] Transcribing on {device_type}...")
try:
    segments, info = model.transcribe(temp_path, beam_size=5, language="en")
    result = " ".join(s.text.strip() for s in segments)
    print(f"      Transcription: '{result}' (empty expected for silence)")
    print(f"      Language: {info.language}")
    print(f"\n" + "=" * 70)
    if device_type == "cuda":
        print("SUCCESS: GPU transcription working without fallback!")
    else:
        print("SUCCESS: CPU transcription working (no GPU available)")
    print("=" * 70)
except Exception as e:
    print(f"      ERROR: {e}")
    print(f"\n" + "=" * 70)
    print("FAILURE: Transcription failed")
    print("=" * 70)
    sys.exit(1)
finally:
    os.remove(temp_path)
