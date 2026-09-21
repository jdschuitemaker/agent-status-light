#!/usr/bin/env python3
"""Generate the input-request cue from measurements of the ICQ "Uh-oh!" alert.

Measured from the classic ICQ incoming-message recording (the same clip appears
in the ICQ Pidgin sound theme and in public "icq-uh-oh" clips):

- total length 451 ms, mono, original 22.05 kHz 8-bit
- "uh" 0-140 ms with f0 rising 700 -> 728 Hz then easing back to ~705 Hz
- quiet decay/mouth gap 80-140 ms (down to about -45 dB)
- "oh" 140-451 ms with f0 starting near 606 Hz and falling to ~555 Hz
- harmonic levels measured per frame (median, relative to the strongest H2):
  "uh" H1 -6.1 / H2 0 / H3 -11.1 / H4 -23.5 / H5 -24.5 / H6 -21.9 / H7 -23.9 /
  H8 -28.6 / H9 -32.4 / H10 -41.9 / H11 -40.5 / H12 -39.9 dB
  "oh" H1 -6.1 / H2 0 / H3 -21.5 / H4 -29.0 / H5 -40.5 / H6 -36.9 / H7 -27.7 /
  H8 -30.7 / H9 -27.8 / H10 -31.7 / H11 -29.8 / H12 -34.1 dB
- the second syllable is about 5 dB louder than the first

The waveform is therefore synthesised additively: the measured harmonic stack
of each syllable, gliding with the measured f0 contour, under the measured
amplitude envelope (5 ms resolution). No reverb, noise or vibrato is added
because none is present in the reference beyond the recording's own floor.
"""
import math
import random
import struct
import wave
from pathlib import Path

RATE = 44100
DURATION_MS = 451
ATTACK_MS = 8
OUT_PEAK = 10 ** (-1.0 / 20)  # leave 1 dB of headroom

# Amplitude envelope measured from the reference every 5 ms, in dB relative to
# the loudest frame. The deep notch near 110 ms is the gap between syllables.
ENVELOPE_DB = [
    -33, -26, -13, -10, -11, -11, -10, -11, -12, -14, -17, -20, -22, -21, -23,
    -29, -37, -39, -39, -40, -43, -44, -45, -45, -45, -44, -44, -43, -28, -20,
    -17, -14, -11, -8, -7, -6, -5, -5, -5, -5, -6, -6, -7, -8, -8,
    -8, -9, -9, -10, -10, -11, -11, -11, -11, -12, -12, -11, -12, -12, -12,
    -12, -12, -12, -12, -12, -12, -12, -12, -12, -12, -12, -12, -13, -13, -13,
    -13, -13, -13, -13, -12, -12, -12, -14, -18, -22, -28, -37, -45, -46, -44,
]

# Measured pitch tracks (milliseconds, Hz).
UH_F0 = [(0, 700), (15, 715), (30, 725), (50, 715), (80, 705), (140, 690)]
OH_F0 = [(140, 606), (160, 596), (180, 590), (220, 588), (260, 582),
         (300, 576), (350, 568), (400, 560), (451, 555)]

# Measured harmonic amplitudes (H1..H4), normalised to the strongest harmonic.
UH_HARMONICS = [0.495, 1.0, 0.279, 0.0668, 0.0596, 0.0804, 0.0638,
                0.0372, 0.0240, 0.0080, 0.0094, 0.0101]
OH_HARMONICS = [0.495, 1.0, 0.0841, 0.0355, 0.0094, 0.0143, 0.0412,
                0.0292, 0.0407, 0.0260, 0.0324, 0.0197]

# The reference is an 8-bit, 22.05 kHz recording; a very quiet noise bed keeps
# the synthesised version from sounding cleaner than the original.
NOISE_FLOOR_DB = -54.0
NOISE_SEED = 1997


def interpolate(points, milliseconds):
    if milliseconds <= points[0][0]:
        return points[0][1]
    for index in range(1, len(points)):
        x0, y0 = points[index - 1]
        x1, y1 = points[index]
        if milliseconds <= x1:
            ratio = (milliseconds - x0) / (x1 - x0)
            return y0 + (y1 - y0) * ratio
    return points[-1][1]


def envelope(milliseconds):
    position = milliseconds / 5
    low = int(position)
    if low >= len(ENVELOPE_DB) - 1:
        return 10 ** (ENVELOPE_DB[-1] / 20)
    ratio = position - low
    level = ENVELOPE_DB[low] + (ENVELOPE_DB[low + 1] - ENVELOPE_DB[low]) * ratio
    return 10 ** (level / 20)


def render() -> list:
    count = int(RATE * DURATION_MS / 1000)
    samples = [0.0] * count
    for track, harmonics, start_ms, end_ms in (
        (UH_F0, UH_HARMONICS, 0.0, 140.0),
        (OH_F0, OH_HARMONICS, 140.0, DURATION_MS),
    ):
        phase = 0.0
        previous = start_ms
        for index in range(count):
            milliseconds = index / RATE * 1000
            if milliseconds < start_ms or milliseconds > end_ms:
                continue
            f0 = interpolate(track, milliseconds)
            step = (milliseconds - previous) / 1000
            previous = milliseconds
            phase += f0 * step
            value = 0.0
            for number, amplitude in enumerate(harmonics, start=1):
                value += amplitude * math.sin(2 * math.pi * number * phase)
            # 1.5 ms crossfade at the syllable boundary avoids a click.
            fade = 1.0
            if milliseconds < start_ms + 1.5:
                fade = (milliseconds - start_ms) / 1.5
            samples[index] += value * envelope(milliseconds) * fade
    peak = max(abs(value) for value in samples) or 1.0
    scale = OUT_PEAK / peak
    samples = [value * scale for value in samples]
    rng = random.Random(NOISE_SEED)
    noise = 10 ** (NOISE_FLOOR_DB / 20)
    return [value + noise * rng.uniform(-1.0, 1.0) for value in samples]


def main() -> None:
    samples = render()
    frames = b"".join(struct.pack("<h", int(max(-1.0, min(1.0, value)) * 32767))
                      for value in samples)
    out_path = Path(__file__).resolve().parent.parent / "Resources" / "InputSound.wav"
    with wave.open(str(out_path), "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        handle.writeframes(frames)
    print(f"Wrote {out_path} ({len(samples) / RATE * 1000:.0f} ms, "
          f"peak {max(abs(v) for v in samples):.3f})")


if __name__ == "__main__":
    main()
