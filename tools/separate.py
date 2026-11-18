"""Splits a song into vocals, drums, bass and other with Demucs (htdemucs), on the Mac's GPU when
it can. Writes OUTDIR/{vocals,drums,bass,other}.wav (float, the model's 44.1 kHz stereo).

usage: python separate.py SONG OUTDIR [--progress]
Progress lines on stdout ("@progress stems 0.42") when --progress is given.
"""
import os
import sys

song, outdir = sys.argv[1], sys.argv[2]
progress = "--progress" in sys.argv

import torch  # noqa: E402
from demucs.apply import apply_model  # noqa: E402
from demucs.audio import AudioFile, save_audio  # noqa: E402
from demucs.pretrained import get_model  # noqa: E402


def say(line):
    if progress:
        print(line, flush=True)


say("@stage stems Loading the separation model")
model = get_model("htdemucs")
model.eval()
device = "mps" if torch.backends.mps.is_available() else "cpu"

say("@stage stems Reading the song")
wav = AudioFile(song).read(streams=0, samplerate=model.samplerate, channels=model.audio_channels)
ref = wav.mean(0)
wav = (wav - ref.mean()) / (ref.std() + 1e-8)

# Demucs reports progress through tqdm; turn its counter into progress lines.
if progress:
    import demucs.apply as _apply
    from tqdm import tqdm as _tqdm

    class Reporter(_tqdm):
        def update(self, n=1):
            super().update(n)
            if self.total:
                print(f"@progress stems {min(1.0, self.n / self.total):.3f}", flush=True)

    _apply.tqdm.tqdm = Reporter

say(f"@stage stems Separating vocals, drums, bass and the rest ({'GPU' if device == 'mps' else 'CPU'})")
with torch.no_grad():
    try:
        sources = apply_model(model, wav[None], device=device, shifts=1, split=True, overlap=0.25, progress=progress)[0]
    except Exception as e:  # some operations aren't on the GPU yet: do it on the CPU
        if device == "cpu":
            raise
        print(f"GPU separation failed ({e}); using the CPU", file=sys.stderr)
        sources = apply_model(model, wav[None], device="cpu", shifts=1, split=True, overlap=0.25, progress=progress)[0]
sources = sources * ref.std() + ref.mean()

os.makedirs(outdir, exist_ok=True)
for name, src in zip(model.sources, sources):
    save_audio(src.cpu(), os.path.join(outdir, f"{name}.wav"), samplerate=model.samplerate, as_float=True)
say("@progress stems 1")
print("stems:", ", ".join(model.sources), file=sys.stderr)
