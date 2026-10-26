// Copyright 2026 Super David Universe LLC
// SPDX-License-Identifier: AGPL-3.0-only
import assert from "node:assert/strict";
import fs from "node:fs";
import vm from "node:vm";

const [bundleFile, version] = process.argv.slice(2);
const bundle = fs.readFileSync(bundleFile, "utf8");
const ownLoop = bundle.slice(0, bundle.indexOf("\n}\n", bundle.indexOf("function antintwrkPlayToneLoop")) + 3);
const play = vm.runInNewContext(ownLoop + "\nantintwrkPlayToneLoop");

function context() {
  const sources = [], gains = [], pans = [];
  const node = () => ({ disconnected: 0, connect(other) { return other; }, disconnect() { this.disconnected++; } });
  return { state: "running", currentTime: 100, destination: {}, sources, gains, pans,
    createGain() { const n = Object.assign(node(), { gain: { setValueAtTime(v) { n.volume = v; } } }); gains.push(n); return n; },
    createStereoPanner() { const n = Object.assign(node(), { pan: { setValueAtTime(v) { n.panValue = v; } } }); pans.push(n); return n; },
    createBufferSource() { const n = Object.assign(node(), { starts: [], stops: 0, start(at) { this.starts.push(at); }, stop() { this.stops++; } }); sources.push(n); return n; },
  };
}
const buffer = { duration: 5, sampleRate: 48000, length: 240000, numberOfChannels: 1 };
const ctx = context(); let playbackSignals = 0;
const stop = play(ctx, buffer, 0.3, -1, 5, () => playbackSignals++);
assert.equal(ctx.sources.length, 1);
assert.equal(ctx.sources[0].loop, true);
assert.deepEqual(ctx.sources[0].starts, [100], "First tone must start immediately, without a five-second delay");
assert.equal(ctx.gains[0].volume, 0.3);
assert.equal(ctx.pans[0].panValue, -1);
assert.equal(playbackSignals, 1);
ctx.state = "suspended";
await stop(); await stop();
assert.equal(ctx.sources[0].stops, 1, "Cancellation must be idempotent and not await an ended callback");
assert.equal(ctx.sources[0].disconnected, 1);
assert.equal(ctx.gains[0].disconnected, 1);
assert.equal(ctx.pans[0].disconnected, 1);
const closed = context(); closed.state = "closed";
await play(closed, buffer, 1, 0, 5, () => {})();
assert.equal(closed.sources.length, 0);
assert.throws(() => play(context(), buffer, 1, 0, 0, () => {}));

const [renderer, read, react, error] = version === "0.26.0" ? ["eHe", "W", "I", "nHe"] : ["Hne", "L", "R", "Wne"];
const body = bundle.match(new RegExp(`${renderer}=\\(\\{vm:e,audio:t\\}\\)=>\\{.*?,null\\}`))?.[0];
assert.ok(body, "Actual packaged ringing renderer must be tested");
let previous = [], cleanup, starts = 0, stops = 0;
const React = { useEffect(effect, deps) {
  if (deps.some((value, i) => value !== previous[i])) { cleanup?.(); previous = deps; cleanup = effect(); }
} };
const render = new Function(read, react, error, `return ${body.slice(renderer.length + 1)};`)((b) => b.value, React, (e) => { throw e; });
const state = { pickupState$: { value: "ringing" } };
const audio = { soundDuration: { ringtone: 5 }, playSoundLooping() { starts++; return async () => { stops++; }; } };
render({ vm: state, audio: null });
render({ vm: state, audio });
assert.equal(starts, 1, "Late audio readiness must start ringback");
render({ vm: state, audio });
assert.equal(starts, 1, "An unchanged render must not restart the loop");
render({ vm: state, audio: null });
assert.equal(stops, 1, "Muting must stop ringback");
render({ vm: state, audio });
for (const outcome of ["accept", "busy", "decline", "timeout"]) {
  state.pickupState$.value = outcome;
  render({ vm: state, audio });
  assert.equal(cleanup, undefined, "A terminal outcome must leave no playing ringback");
  state.pickupState$.value = "ringing";
  render({ vm: state, audio });
}
cleanup?.();
assert.equal(starts, stops, "Unmount must stop the last loop");
console.log(`Embedded ${version}: immediate single-source tone, routing, cancellation and actual renderer readiness/terminal cleanup passed`);
