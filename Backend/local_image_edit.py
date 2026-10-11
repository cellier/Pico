"""Local screenshot -> instruction -> PNG. JSON-lines worker or command-line tool.

The setup script downloads weights separately. Inference always runs offline.
"""
import argparse
import contextlib
import json
import math
import os
from pathlib import Path
import resource
import sys
import tempfile
import time

MODEL_ID = "Runpod/FLUX.2-klein-4B-mflux-4bit"
REVISION = "7ee1b3aa8178a1240050490072196a57da2bf2a9"


def working_size(width, height):
    if width < 16 or height < 16:
        raise ValueError("Please use an image at least 16 pixels wide and tall.")
    scale = min(1.0, math.sqrt(1024 * 1024 / (width * height)), 1536 / max(width, height))
    w, h = max(16, round(width * scale)), max(16, round(height * scale))
    return (w, h), (math.ceil(w / 16) * 16, math.ceil(h / 16) * 16)


def emit(event):
    print(json.dumps(event, ensure_ascii=False), flush=True)


class Editor:
    def __init__(self, model_path):
        self.path = Path(model_path).expanduser().resolve()
        self.model = None

    def edit(self, request, report=emit):
        from PIL import Image, ImageOps
        instruction = request.get("instruction", "").strip()
        if not instruction or len(instruction) > 4000:
            raise ValueError("Enter an edit instruction between 1 and 4000 characters.")
        source = Path(request["image"]).expanduser().resolve(strict=True)
        output = Path(request["output"]).expanduser().resolve()
        if source == output:
            raise ValueError("Output must be a new file; the original is preserved.")
        with Image.open(source) as opened:
            original = ImageOps.exif_transpose(opened).convert("RGB")
        content_size, canvas_size = working_size(*original.size)
        required = ["transformer/0.safetensors", "text_encoder/0.safetensors", "vae/0.safetensors", "tokenizer/tokenizer.json"]
        if not all((self.path / name).is_file() for name in required):
            raise ValueError("Local image model is missing. Run scripts/setup-image-edit.sh first.")
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
        started = time.perf_counter()
        import mlx.core as mx
        # MLX's default cache can retain tens of GB between edits on a busy Mac.
        # Keep model weights resident while bounding reusable temporary buffers.
        mx.set_cache_limit(256 * 1024 * 1024)
        mx.set_memory_limit(24 * 1024**3)
        mx.clear_cache()
        cold = self.model is None
        load_seconds = 0.0
        mx.reset_peak_memory()
        # Keep third-party progress/log output away from the JSON protocol.
        with contextlib.redirect_stdout(sys.stderr):
            if cold:
                report({"stage": "loading"})
                from mflux.models.common.config import ModelConfig
                from mflux.models.flux2.variants import Flux2KleinEdit
                t = time.perf_counter()
                self.model = Flux2KleinEdit(model_config=ModelConfig.flux2_klein_4b(), model_path=str(self.path), quantize=4)
                load_seconds = time.perf_counter() - t
            report({"stage": "editing"})
            with tempfile.TemporaryDirectory(prefix="TelosLocalEdit-") as scratch:
                resized = original.resize(content_size, Image.Resampling.LANCZOS)
                # Pad, then crop back: never stretch the screenshot to model dimensions.
                canvas = Image.new("RGB", canvas_size, "white")
                canvas.paste(resized, (0, 0))
                ref = Path(scratch) / "reference.png"
                canvas.save(ref)
                t = time.perf_counter()
                generated = self.model.generate_image(
                    seed=int(request.get("seed", 42)), prompt=instruction,
                    image_paths=[str(ref)], num_inference_steps=4,
                    width=canvas_size[0], height=canvas_size[1], guidance=1.0,
                )
                raw = Path(scratch) / "generated.png"
                generated.save(str(raw))
                mx.synchronize()
                edit_seconds = time.perf_counter() - t
                with Image.open(raw) as result:
                    final = result.crop((0, 0, *content_size)).resize(original.size, Image.Resampling.LANCZOS)
                    output.parent.mkdir(parents=True, exist_ok=True)
                    # Only publish a completed PNG.
                    fd, temporary = tempfile.mkstemp(prefix=".telos-", suffix=".png", dir=output.parent)
                    os.close(fd)
                    try:
                        final.save(temporary, format="PNG")
                        os.replace(temporary, output)
                    finally:
                        Path(temporary).unlink(missing_ok=True)
        peak_bytes = mx.get_peak_memory()
        mx.clear_cache()
        return {"output": str(output), "metrics": {
            "cold": cold, "load_seconds": load_seconds, "edit_seconds": edit_seconds,
            "total_seconds": time.perf_counter() - started,
            "mlx_peak_bytes": peak_bytes,
            "process_lifetime_peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            "input_size": list(original.size), "model_size": list(canvas_size),
            "model": MODEL_ID, "revision": REVISION, "steps": 4, "quantize": 4,
        }}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-path", required=True)
    parser.add_argument("--input")
    parser.add_argument("--instruction")
    parser.add_argument("--output")
    parser.add_argument("--repeat", type=int, default=1)
    args = parser.parse_args()
    editor = Editor(args.model_path)
    protocol = sys.stdout
    def report(event):
        protocol.write(json.dumps(event, ensure_ascii=False) + "\n")
        protocol.flush()
    if args.input:
        if not args.output or not args.instruction:
            parser.error("--input requires --instruction and --output")
        for i in range(args.repeat):
            out = Path(args.output)
            if i:
                out = out.with_name(f"{out.stem}-{i + 1}{out.suffix}")
            report(editor.edit({"image": args.input, "instruction": args.instruction, "output": str(out)}, report))
    else:
        for line in sys.stdin:
            try:
                report(editor.edit(json.loads(line), report))
            except Exception as exc:
                report({"error": str(exc)})


if __name__ == "__main__":
    main()
