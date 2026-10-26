#!/usr/bin/env python3
# Copyright 2026 Super David Universe LLC
# SPDX-License-Identifier: AGPL-3.0-only
import array
import io
import math
import unittest
import wave

from generate_call_tones import busy_bytes, ringback_bytes


class TelephoneTonesTest(unittest.TestCase):
    def test_durations_cadence_frequency_and_soft_level(self):
        for generate, on, off, cycles in [(ringback_bytes, 1, 4, 1), (busy_bytes, 0.5, 0.5, 3)]:
            with self.subTest(signal=generate.__name__):
                with wave.open(io.BytesIO(generate()), "rb") as wav:
                    self.assertEqual((wav.getnchannels(), wav.getsampwidth(), wav.getframerate()), (1, 2, 48000))
                    self.assertEqual(wav.getnframes(), round((on + off) * cycles * 48000))
                    samples = array.array("h", wav.readframes(wav.getnframes()))
                self.assertLessEqual(max(abs(n) for n in samples), 3277)
                for cycle in range(cycles):
                    start = round(cycle * (on + off) * 48000)
                    end = start + round(on * 48000)
                    self.assertEqual(samples[start], 0)
                    self.assertEqual(samples[end - 1], 0)
                    self.assertTrue(all(n == 0 for n in samples[end:start + round((on + off) * 48000)]))
                # Measure the tone itself, independently of its generation constants.
                signal = samples[4800:14400]
                def energy(frequency):
                    real = sum(v * math.cos(2 * math.pi * frequency * k / 48000) for k, v in enumerate(signal))
                    imag = sum(v * math.sin(2 * math.pi * frequency * k / 48000) for k, v in enumerate(signal))
                    return math.hypot(real, imag)
                self.assertGreater(energy(425), 50 * energy(400))
                self.assertGreater(energy(425), 50 * energy(450))


if __name__ == "__main__":
    unittest.main()
