#!/usr/bin/env python3
"""Generates candidate notification sounds into assets/sounds/samples. Needs numpy.

Everything is synthesized here, so Tala owns the result outright: additive
partials with exponential decay, soft attack, 48 kHz mono 16-bit WAV.
"""
import pathlib
import wave

import numpy as np

RATE = 48000
OUT = pathlib.Path(__file__).resolve().parent.parent / "assets/sounds/samples"
PEAK = 0.45  # Notifications shouldn't startle; -7 dBFS.


def note(freq, length, partials, attack=0.004):
    """partials: (frequency ratio, level, decay time in seconds)."""
    t = np.arange(int(length * RATE)) / RATE
    out = np.zeros_like(t)
    for ratio, level, decay in partials:
        out += level * np.sin(2 * np.pi * freq * ratio * t) * np.exp(-t / decay)
    fade_in = np.minimum(t / attack, 1.0)
    fade_out = np.minimum((length - t) / 0.03, 1.0)
    return out * fade_in * fade_out


def mix(events, length):
    """events: (start time, samples)."""
    out = np.zeros(int(length * RATE))
    for start, samples in events:
        i = int(start * RATE)
        end = min(i + len(samples), len(out))
        out[i:end] += samples[: end - i]
    return out


def echo(signal, delay, level):
    out = signal.copy()
    d = int(delay * RATE)
    for n in (1, 2):
        out[d * n :] += signal[: -d * n] * level**n
    return out


def write(name, signal):
    signal = signal / np.max(np.abs(signal)) * PEAK
    OUT.mkdir(parents=True, exist_ok=True)
    with wave.open(str(OUT / f"{name}.wav"), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes((signal * 32767).astype(np.int16).tobytes())


# Struck metal: inharmonic partials that die off faster as they rise.
BELL = [(1, 1.0, 0.45), (2.0, 0.5, 0.30), (2.76, 0.35, 0.20), (5.4, 0.15, 0.09)]
# A glass or kalimba tone: nearly pure, quick.
GLASS = [(1, 1.0, 0.22), (3.0, 0.18, 0.08), (6.2, 0.05, 0.03)]
# Marimba: a warm wooden knock with a strong octave-and-a-bit partial.
WOOD = [(1, 1.0, 0.16), (3.9, 0.3, 0.035), (9.2, 0.08, 0.012)]
# A singing bowl: two close partials beat slowly against each other.
BOWL = [(1, 1.0, 1.1), (1.006, 0.8, 1.0), (2.71, 0.25, 0.5), (5.1, 0.07, 0.18)]
# A plain soft sine for the quietest option.
SOFT = [(1, 1.0, 0.28), (2, 0.08, 0.1)]

# Two rising bell notes, a major third apart.
write("1-bell-duet", mix([(0, note(880, 1.1, BELL)), (0.14, note(1108.73, 1.2, BELL))], 1.4))

# Three quick glass notes rising up a major triad.
write("2-glass-steps", echo(mix([
    (0.00, note(1046.5, 0.5, GLASS)),
    (0.09, note(1318.5, 0.5, GLASS)),
    (0.18, note(1568.0, 0.7, GLASS)),
], 1.0), 0.11, 0.18))

# Two warm wooden notes, falling a fourth then back: friendly and low.
write("3-marimba-knock", mix([
    (0.00, note(523.25, 0.5, WOOD)),
    (0.12, note(392.0, 0.6, WOOD)),
], 0.8))

# One long, calm strike that hums away. Unmissable without being loud.
write("4-singing-bowl", note(622.25, 1.8, BOWL, attack=0.012))

# Barely there: a single soft drop in pitch, for people who hate alerts.
write("5-soft-drop", mix([
    (0.00, note(987.77, 0.45, SOFT, attack=0.012)),
    (0.10, note(739.99, 0.55, SOFT, attack=0.012) * 0.8),
], 0.75))
