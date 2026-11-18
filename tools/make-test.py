"""Writes the speaker-walk test audio for spatial-test.mov: raw f32le, 12 channels in Apple
Atmos 7.1.4 order (L R C LFE Ls Rs Lrs Rrs Ltf Rtf Ltr Rtr), to stdout. Prints the label
schedule (start second, label) to stderr so the video can show matching text.
usage: python3 make-test.py > audio.f32 2> schedule.txt"""
import random
import struct
import sys

SR = 48000
# (output channel, label) in walk order: around the ear level, then around the ceiling
WALK = [
    (0, "Front Left"), (2, "Center"), (1, "Front Right"),
    (5, "Side Right"), (7, "Rear Right"), (6, "Rear Left"), (4, "Side Left"),
    (8, "Top Front Left"), (9, "Top Front Right"), (11, "Top Rear Right"), (10, "Top Rear Left"),
]
SLOT, ON = 2.0, 1.5  # seconds per speaker, seconds of noise within it

rng = random.Random(1)
out = sys.stdout.buffer
b = [0.0] * 7  # Paul Kellet pink-noise filter state
for k, (ch, label) in enumerate(WALK):
    sys.stderr.write(f"{k * SLOT:g} {label}\n")
    frame = [0.0] * 12
    chunk = bytearray()
    for n in range(int(SLOT * SR)):
        w = rng.uniform(-1, 1)
        b[0] = 0.99886 * b[0] + w * 0.0555179; b[1] = 0.99332 * b[1] + w * 0.0750759
        b[2] = 0.96900 * b[2] + w * 0.1538520; b[3] = 0.86650 * b[3] + w * 0.3104856
        b[4] = 0.55000 * b[4] + w * 0.5329522; b[5] = -0.7616 * b[5] - w * 0.0168980
        pink = (sum(b[:6]) + b[6] + w * 0.5362) * 0.05
        b[6] = w * 0.115926
        t = n / SR
        fade = min(1.0, t / 0.02, max(0.0, (ON - t) / 0.02)) if t < ON else 0.0
        frame[ch] = pink * fade
        chunk += struct.pack("<12f", *frame)
    out.write(chunk)
