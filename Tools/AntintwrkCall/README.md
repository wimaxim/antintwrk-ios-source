# Embedded telephone tones and call pickup

Own synthesized call progress tones, identical on Android and iOS:
- ringback:425Hz,1 second on/4 seconds off, immediate start;
- busy:425Hz,0.5 second on/0.5 second off,3 cycles then close;
- mono48kHz16-bit PCM WAV,8ms fades,peak−20dBFS. No external recording.

`generate_call_tones.py` is the corresponding deterministic audio source.
`call-tone-loop.js` uses one WebAudio looping source instead of the overlapping
promise scheduler. Stop is immediate/idempotent even on a suspended AudioContext.
Gain, earpiece pan, output routing and playback-start control remain in place.
The React effect observes audio readiness as well as pickup: late decoding starts
ringback; accept/decline/busy/timeout/mute/unmount stop it.

The owner's policy is account-wide busy: an ongoing call on one device declines
another personal call for the same actor, with authenticated RTC decline content
`io.antintwrk.call.reason: busy`. The native clients recheck current call, actor,
freshness and authoritative DM metadata before sending. Existing account-device
decline observers cancel ringing on the other devices. The caller checks sender,
reference relation and original notification before interpreting busy. Ordinary
rejection/network failure/expiry never imply busy. Groups are excluded. Older
clients interpret the event as ordinary decline. This is delivered signalling,
not an atomic server account lock; an offline device cannot report busy.

`call-pickup.patch` retains the first ring outcome for independent auto-leave/UI
subscribers. No recipient, encryption, media transport or recovery checks change.

## Corresponding source and reproduction

Upstream:https://github.com/element-hq/element-call
- Android v0.26.0:71593f1a245b1afa971e3940596e1c500edf9548.
- iOS v0.25.0:efde51b8c1e136fca17d38ec408b0a7dbb2f17e9.

Apply `call-pickup.patch` with `git apply`. Then apply the version's tone patch
with `git apply --unidiff-zero`: `call-tones.patch` for0.26.0 or
`call-tones-ios-0.25.patch` for0.25.0. Copy `call-tone-loop.js` to `src/`.
Generate the two `src/sound/antintwrk-*-v1.wav` files with `ringback_bytes()` and
`busy_bytes()` from the generator. The patch supplies its TypeScript declaration.
The0.26 patch includes the real React late-audio regression. Optionally apply
`call-pickup-tests.patch` with `--unidiff-zero` before the tone patch for the two
synchronous-consumer regressions. Preserve upstream AGPL/commercial notices;
these own modifications are AGPL-3.0-only.

Builds do not mutate dependency caches or need a new Node web build. The overlay
checks original JS SHA-256 and exact single matches; unknown inputs fail closed.
Android packages the complete pinned asset-only AAR in generated namespace
`element-call-antintwrk-tones-v1`; iOS copies original package resources to
`AntintwrkTelephoneCall` before signing. These fresh paths avoid old cached chunks.
The stale modified-main source map is removed; use pinned source and patches.
Other original source maps/imports/assets remain. JSON marker records hashes and
cadence. Upstream AAR has empty classes.jar and is build input, not runtime copy.

## Verification

`python3 test_call_tones.py` checks PCM/cadence/fades/silence/frequency/amplitude.
`test_tone_loop.mjs <patched-full-JS> <embedded-version>` executes the actual
packaged loop and renderer with WebAudio/React-effect harnesses. It checks start,
cleanup,late readiness,mute,and every pickup outcome.
`test_packaged_pickup.mjs <compiled-scope.mjs> <original-JS> <patched-JS> <version>`
executes the actual original/patched lifecycle with its version's ObservableScope
and RxJS. Original lost pickup is reproduced;8 outcome/order cases plus4 invalid
sender/reference/relation/late-busy guards pass per version.

Native tests cover account busy production and current-call preservation. iOS
also decodes actual signed-app WAV resources in WKWebView. Automated fixtures are
not physical media-call acceptance. See shared telephone-call-tones-2026-10-14.md.
