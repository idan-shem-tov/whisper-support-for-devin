"""
Unit test for GPU transcription with CUDA libraries.
"""
import os
import sys
import tempfile
import numpy as np
import scipy.io.wavfile as wav

# Add CUDA libraries to path (same as vtt-helper.py)
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

print("=" * 60)
print("GPU Transcription Test")
print("=" * 60)

# Add CUDA to path
cuda_added = add_cuda_to_path()
print(f"CUDA libraries added to path: {cuda_added}")

# Test GPU detection
try:
    import ctranslate2
    cuda_count = ctranslate2.get_cuda_device_count()
    print(f"CUDA devices detected: {cuda_count}")
    
    if cuda_count > 0:
        supported = ctranslate2.get_supported_compute_types("cuda")
        print(f"Supported compute types: {supported}")
        
        # Load model on GPU
        print("\nLoading Whisper model on GPU...")
        from faster_whisper import WhisperModel
        model = WhisperModel("tiny", device="cuda", compute_type="float16")
        print("[OK] Model loaded on CUDA")
        
        # Create test audio
        print("\nCreating test audio...")
        rate = 16000
        duration = 1
        audio = np.zeros(rate * duration, dtype=np.int16)
        
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            wav.write(f.name, rate, audio)
            temp_path = f.name
        
        print(f"Test audio created: {temp_path}")
        
        # Test transcription on GPU
        print("\nAttempting transcription on GPU...")
        try:
            segments, info = model.transcribe(temp_path, beam_size=1)
            result = " ".join(s.text for s in segments)
            print(f"[OK] GPU transcription succeeded!")
            print(f"Result: '{result}' (empty is expected for silent audio)")
            print(f"Language detected: {info.language}")
            print("\n" + "=" * 60)
            print("SUCCESS: GPU transcription is working!")
            print("=" * 60)
        except Exception as e:
            print(f"[FAIL] GPU transcription failed: {e}")
            print("\nThis means CUDA libraries are still not accessible.")
            sys.exit(1)
        finally:
            os.remove(temp_path)
    else:
        print("[SKIP] No CUDA devices found")
        sys.exit(0)
        
except Exception as e:
    print(f"[ERROR] Test failed: {e}")
    import traceback
    traceback.print_exc()
    sys.exit(1)
