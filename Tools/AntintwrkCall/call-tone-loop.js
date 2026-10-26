// Copyright 2026 Super David Universe LLC
// SPDX-License-Identifier: AGPL-3.0-only

export function antintwrkPlayToneLoop(ctx, buffer, volume, stereoPan, periodS, playbackStarted) {
  const period = periodS ?? buffer.duration;
  if (!Number.isFinite(period) || period <= 0) {
    throw new RangeError("Call tone period must be positive");
  }
  if (ctx.state === "closed") return async () => {};

  let loopBuffer = buffer;
  const frames = Math.ceil(Math.max(buffer.duration, period) * buffer.sampleRate);
  if (frames > buffer.length) {
    loopBuffer = ctx.createBuffer(buffer.numberOfChannels, frames, buffer.sampleRate);
    for (let channel = 0; channel < buffer.numberOfChannels; channel++) {
      loopBuffer.copyToChannel(buffer.getChannelData(channel), channel);
    }
  }
  const gain = ctx.createGain();
  gain.gain.setValueAtTime(volume, ctx.currentTime);
  const pan = ctx.createStereoPanner();
  pan.pan.setValueAtTime(stereoPan, ctx.currentTime);
  const source = ctx.createBufferSource();
  source.buffer = loopBuffer;
  source.loop = true;
  source.connect(gain).connect(pan).connect(ctx.destination);
  playbackStarted();
  source.start(ctx.currentTime);

  let stopped = false;
  return async () => {
    if (stopped) return;
    stopped = true;
    try {
      source.stop();
    } finally {
      source.disconnect();
      gain.disconnect();
      pan.disconnect();
    }
  };
}
