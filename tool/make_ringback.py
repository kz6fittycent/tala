#!/usr/bin/env python3
"""Generates assets/sounds/ringback.wav, what a caller hears while waiting.

Synthesized here, so Tala owns the result: the North American ringback pair
(440 and 480 Hz) for the 2 seconds Ringback plays before its 4 second gap. Kept
quiet because it plays beside a call.
"""
import math
import pathlib
import struct
import wave

RATE = 48000
SECONDS = 2.0
PEAK = 0.18
FADE = 0.02  # Avoids a click at each end.

OUT = pathlib.Path(__file__).resolve().parent.parent / "assets/sounds/ringback.wav"

frames = bytearray()
count = int(SECONDS * RATE)
for i in range(count):
    t = i / RATE
    edge = min(t, SECONDS - t, FADE) / FADE
    tone = (math.sin(2 * math.pi * 440 * t) + math.sin(2 * math.pi * 480 * t)) / 2
    frames += struct.pack("<h", int(tone * edge * PEAK * 32767))

with wave.open(str(OUT), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(RATE)
    w.writeframes(bytes(frames))
