"""Ephemeral PCM chunks on stdin; local mixed-language ASR; no audio files/network."""
import base64, contextlib, json, sys
import numpy as np
import dictation

with contextlib.redirect_stdout(sys.stderr):
    dictation.warm()
print(json.dumps({'ready':True}), flush=True)
for line in sys.stdin:
    request = {}
    try:
        request = json.loads(line)
        samples = np.frombuffer(base64.b64decode(request['pcm'], validate=True), dtype='<i2').astype(np.float32) / 32768
        text = ''
        if len(samples) >= 1600 and float(np.sqrt(np.mean(samples ** 2))) >= .002:
            with contextlib.redirect_stdout(sys.stderr):
                result = dictation._model.generate(samples, language=None, temperature=0., max_tokens=2048,
                    hotwords=['Telos','Zoom Slides','PowerPoint','Copilot'])
                text = result.text.strip()
        print(json.dumps({'id':request['id'], 'text':text}, ensure_ascii=False), flush=True)
    except Exception:
        print(json.dumps({'id':request.get('id'), 'error':'Local mixed-language recognition failed. This interval could not be transcribed.'}), flush=True)
