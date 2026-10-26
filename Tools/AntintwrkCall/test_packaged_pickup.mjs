// Copyright 2026 Super David Universe LLC
// SPDX-License-Identifier: AGPL-3.0-only
// Execute the actual packaged function, not a duplicate of its implementation.
import assert from "node:assert/strict";
import fs from "node:fs";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const [scopeFile, originalFile, patchedFile, version] = process.argv.slice(2);
const { ObservableScope } = await import(pathToFileURL(scopeFile));
const require = createRequire(pathToFileURL(scopeFile));
const rx = require("rxjs");
const names = version === "0.26.0"
  ? ["ZRe", "F", "rO", "iO", "fO", "UD", "tO", "B", "XD", "$pe", "oO", "cO", "nO"]
  : ["e5", "f", "AS", "NS", "U", "Dx", "OS", "H", "Zx", "PS", "zS", "JS", "kS"];
const logger = { getChild: () => ({ warn() {} }) };
const values = [logger, rx.NEVER, rx.filter, rx.switchMap, rx.EMPTY, rx.timer,
  rx.map, rx.of, rx.race, rx.take, rx.pairwise, rx.merge];

function load(file) {
  const code = fs.readFileSync(file, "utf8");
  const match = code.match(new RegExp(`function ${names[0]}\\([\\s\\S]+?return\\{ringAttempts\\$:[^{}]+}}`));
  assert.ok(match, "Pinned lifecycle function must be present exactly once");
  return new Function(...names.slice(1), `${match[0]}; return ${names[0]};`)(...values);
}

async function scenario(factory, outcome, firstConsumer) {
  const scope = new ObservableScope();
  const recipient = "@recipient:test.invalid";
  const memberships$ = new rx.BehaviorSubject({ value: outcome === "accept" ? [{ userId: recipient }] : [] });
  const notifications = new rx.Subject();
  const receivedDecline$ = outcome === "decline" || outcome === "busy" ? rx.of([{
    getRelation: () => ({ rel_type: "m.reference", event_id: "$notification" }),
    getSender: () => recipient,
    getContent: () => outcome === "busy" ? { "io.antintwrk.call.reason": "busy" } : {},
  }]) : rx.NEVER;
  const lifecycle = factory({ scope, memberships$,
    matrixRoomMembers$: { value: new Map([[recipient, {}]]) },
    sentCallNotification$: notifications, receivedDecline$,
    options: { waitForCallPickup: true, autoLeaveWhenOthersLeft: false },
    localUser: { userId: "@caller:test.invalid", deviceId: "CALLER" },
  });
  const ui = [], leave = [], late = [];
  let attempt;
  const subscribeUI = () => lifecycle.ringAttempts$.subscribe((value) => {
    attempt = value;
    value.outcome$.subscribe((result) => ui.push(result));
  });
  const subscribeLeave = () => lifecycle.autoLeave$.subscribe((result) => leave.push(result));
  if (firstConsumer === "leave") { subscribeLeave(); subscribeUI(); }
  else { subscribeUI(); subscribeLeave(); }
  notifications.next({ event_id: "$notification", notification_type: "ring", lifetime: 5 });
  await new Promise((resolve) => setTimeout(resolve, 15));
  attempt.outcome$.subscribe((result) => late.push(result));
  scope.end();
  return { ui, leave, late };
}

const original = load(originalFile), patched = load(patchedFile);
const broken = await scenario(original, "accept", "leave");
assert.deepEqual(broken.ui, [], "Original must reproduce the lost pickup");
assert.deepEqual(broken.late, [], "Original must lose the completed outcome");
for (const outcome of ["accept", "decline", "timeout", "busy"]) {
  for (const first of ["leave", "ui"]) {
    const result = await scenario(patched, outcome, first);
    assert.deepEqual(result.ui, [outcome]);
    assert.deepEqual(result.late, [outcome]);
    assert.deepEqual(result.leave, outcome === "accept" ? [] : [outcome]);
  }
}
// A reason is trusted only after matching both recipient and original notification.
for (const invalid of ["sender", "event", "relation", "late"]) {
  const scope = new ObservableScope(), recipient = "@recipient:test.invalid";
  const notifications = new rx.Subject(), receivedDecline$ = new rx.Subject();
  const memberships$ = new rx.BehaviorSubject({ value: invalid === "late" ? [{ userId: recipient }] : [] });
  const lifecycle = patched({ scope, memberships$, sentCallNotification$: notifications, receivedDecline$,
    matrixRoomMembers$: { value: new Map([[recipient, {}]]) },
    options: { waitForCallPickup: true, autoLeaveWhenOthersLeft: false }, localUser: { userId: "@caller:test.invalid" },
  });
  const ui = [], leave = [];
  lifecycle.autoLeave$.subscribe((v) => leave.push(v));
  lifecycle.ringAttempts$.subscribe((v) => v.outcome$.subscribe((r) => ui.push(r)));
  notifications.next({ event_id: "$notification", notification_type: "ring", lifetime: 5 });
  receivedDecline$.next([{
    getRelation: () => ({ rel_type: invalid === "relation" ? "m.annotation" : "m.reference", event_id: invalid === "event" ? "$other" : "$notification" }),
    getSender: () => invalid === "sender" ? "@stranger:test.invalid" : recipient,
    getContent: () => ({ "io.antintwrk.call.reason": "busy" }),
  }]);
  await new Promise((resolve) => setTimeout(resolve, 15));
  assert.deepEqual(ui, [invalid === "late" ? "accept" : "timeout"]);
  assert.deepEqual(leave, invalid === "late" ? [] : ["timeout"]);
  scope.end();
}
console.log(`Embedded ${version}: eight outcome/order cases and four authenticated/late-busy guards passed; original lost pickup reproduced`);
