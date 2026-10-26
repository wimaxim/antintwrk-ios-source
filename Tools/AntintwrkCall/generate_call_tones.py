#!/usr/bin/env python3
"""Own 425 Hz call progress sounds; no operator recordings or encoders.

Copyright 2026 Super David Universe LLC
SPDX-License-Identifier: AGPL-3.0-only
"""
import array
import io
import math
import sys
import wave

SAMPLE_RATE = 48000
FREQUENCY = 425
AMPLITUDE = 10 ** (-20 / 20)
FADE_FRAMES = 384


def tone_bytes(on_seconds, off_seconds, cycles):
    on_frames = round(on_seconds * SAMPLE_RATE)
    off_frames = round(off_seconds * SAMPLE_RATE)
    data = array.array("h")
    for _ in range(cycles):
        for frame in range(on_frames):
            fade = min(1, frame / FADE_FRAMES, (on_frames - 1 - frame) / FADE_FRAMES)
            value = AMPLITUDE * fade * math.sin(2 * math.pi * FREQUENCY * frame / SAMPLE_RATE)
            data.append(round(value * 32767))
        data.extend([0] * off_frames)
    if sys.byteorder != "little":
        data.byteswap()
    output = io.BytesIO()
    with wave.open(output, "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SAMPLE_RATE)
        wav.writeframes(data.tobytes())
    return output.getvalue()


def ringback_bytes():
    return tone_bytes(1, 4, 1)


def busy_bytes():
    return tone_bytes(0.5, 0.5, 3)
