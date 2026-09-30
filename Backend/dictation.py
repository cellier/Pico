"""Local bilingual transcription. No audio leaves this process or machine."""
import contextlib, json, sys, wave
from pathlib import Path
MODEL = 'mlx-community/Qwen3-ASR-0.6B-4bit'
_model = None
_warmed = False

def transcribe(path):
    import numpy as np
    with wave.open(str(path), 'rb') as audio:
        if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (16000, 1, 2):
            raise ValueError('Expected mono 16 kHz PCM audio')
        samples = np.frombuffer(audio.readframes(audio.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    if len(samples) < 4000 or float(np.sqrt(np.mean(samples ** 2))) < 0.002:
        return ''
    from huggingface_hub import snapshot_download
    global _model
    if _model is None:
        from mlx_audio.stt import load
        model_path = snapshot_download(MODEL, local_files_only=True)
        _model = load(model_path)
    result = _model.generate(samples, language=None, temperature=0.0, max_tokens=2048,
                             hotwords=['Telos', 'Zoom Slides', 'PowerPoint', 'Copilot'])
    return result.text.strip()

def warm():
    global _model, _warmed
    if _model is None:
        from huggingface_hub import snapshot_download
        from mlx_audio.stt import load
        _model = load(snapshot_download(MODEL, local_files_only=True))
    if not _warmed:
        # Loading weights does not compile/evaluate the audio + decode path.
        # Exercise it before the user releases their first recording.
        import numpy as np
        _model.generate(np.zeros(16000, dtype=np.float32), language=None,
                        temperature=0.0, max_tokens=1,
                        hotwords=['Telos', 'Zoom Slides', 'PowerPoint', 'Copilot'])
        _warmed = True

def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)

def serve():
    with contextlib.redirect_stdout(sys.stderr): warm()
    emit({'ready': True})
    for line in sys.stdin:
        request = {}
        try:
            request = json.loads(line)
            with contextlib.redirect_stdout(sys.stderr): text = transcribe(Path(request['path']))
            polished = False
            if text and request.get('polish', True):
                emit({'id':request['id'], 'stage':'polishing'})
                from dictation_polish import polish
                text, polished = polish(text)
            emit({'id':request['id'], 'text':text, 'polished':polished})
        except Exception:
            emit({'id':request.get('id'), 'error':'Local speech recognition failed. Please try again.'})

if __name__ == '__main__':
    try:
        if sys.argv[1] == '--serve': serve()
        else:
            with contextlib.redirect_stdout(sys.stderr): text = transcribe(Path(sys.argv[1]))
            emit({'text':text})
    except Exception:
        emit({'error':'Local speech recognition failed. Check the speech model installation and try again.'})
        sys.exit(1)
