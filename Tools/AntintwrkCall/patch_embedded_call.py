#!/usr/bin/env python3
"""Apply corresponding pickup, telephone-tone and busy patches to pinned call JS.

Copyright 2026 Super David Universe LLC
SPDX-License-Identifier: AGPL-3.0-only
"""
import argparse
import hashlib
import json
import re
import shutil
import zipfile
from pathlib import Path

from generate_call_tones import busy_bytes, ringback_bytes


SPECS = {
    "0.26.0": (
        "index-Bz16m3ir.js",
        "afed02c82fc563f4c0ee2673b33195b8128da1f79fd25e9badc613efe42b9e92",
        "outcome$:$pe(c,l,u).pipe(oO(1),e.share)",
        "outcome$:$pe(c,l,u).pipe(oO(1),s=>e.behavior(s,null).pipe(iO(v=>v!==null),oO(1)))",
    ),
    "0.25.0": (
        "index-DPkEeOAp.js",
        "d430e06908dcf717538fb91a8f6bc85f36f0fb90a2924f429b6848a81477665b",
        "outcome$:PS(c,l,u).pipe(zS(1),e.share)",
        "outcome$:PS(c,l,u).pipe(zS(1),s=>e.behavior(s,null).pipe(NS(v=>v!==null),zS(1)))",
    ),
}

TONE_SPECS = {
    "0.26.0": ("_Ve", "gVe", "sY", "eHe", "W", "I", "nHe"),
    "0.25.0": ("une", "g9", "kL", "Hne", "L", "R", "Wne"),
}


def patch(content, version):
    name, digest, old, new = SPECS[version]
    if hashlib.sha256(content).hexdigest() != digest:
        raise ValueError(f"Unexpected embedded call artifact: {name}; revalidate the source patch")
    text = content.decode("utf-8")
    if text.count(old) != 1:
        raise ValueError("Expected exactly one pickup outcome; refusing a broad replacement")
    text = text.replace(old, new)
    mapper = "B" if version == "0.26.0" else "H"
    decline_mapper = f"getSender()===a),{mapper}(()=>`decline`)"
    busy_mapper = f"getSender()===a),{mapper}(([e])=>e.getContent()?.[`io.antintwrk.call.reason`]===`busy`?`busy`:`decline`)"
    replacements = {
        decline_mapper: busy_mapper,
        "e===`timeout`||e===`decline`": "e===`timeout`||e===`decline`||e===`busy`",
        "case`timeout`:case`decline`:": "case`timeout`:case`decline`:case`busy`:",
        "screenshareStarted:{": (
            "busy:{mp3:new URL(`antintwrk-busy-v1.wav`,import.meta.url).href,"
            "ogg:new URL(`antintwrk-busy-v1.wav`,import.meta.url).href},screenshareStarted:{"
        ),
    }
    for before, after in replacements.items():
        if text.count(before) != 1:
            raise ValueError("Unexpected confirmed-busy lifecycle or sound binding")
        text = text.replace(before, after)
    loop, play, started, renderer, behavior, react, log_error = TONE_SPECS[version]
    old_loop = (
        f"function {loop}(e,t,n,r,i){{if(i===0)throw Error(`Looping sounds must have a delay`);"
        f"let a,o,s;return(async()=>{{s=new AbortController,a=Promise.resolve();do o={play}(e,t,n,r,i,s),"
        "await a,a=o;while(!s.signal.aborted)})(),async()=>{s?.abort(),await a,await o}}"
    )
    new_loop = f"function {loop}(e,t,n,r,i){{return antintwrkPlayToneLoop(e,t,n,r,i,{started})}}"
    if text.count(old_loop) != 1:
        raise ValueError("Expected exactly one original ring loop")
    text = text.replace(old_loop, new_loop)
    # Audio readiness must trigger the effect even if the pickup state stays ringing.
    new_renderer = (
        f"{renderer}=({{vm:e,audio:t}})=>{{let n={behavior}(e.pickupState$);"
        f"return(0,{react}.useEffect)(()=>{{if(n===`ringing`&&t){{let e=t.playSoundLooping(`ringtone`,"
        f"t.soundDuration.ringtone??1);return()=>{{e().catch({log_error})}}}}}},[n,t]),null}}"
    )
    text, count = re.subn(re.escape(renderer) + r"=e=>\{.*?,null\}", lambda _: new_renderer, text, count=1)
    if count != 1:
        raise ValueError("Expected exactly one ringing renderer")
    for asset in ("ringtone-B2csBdU4.mp3", "ringtone-B-nJXbbw.ogg"):
        if text.count(asset) != 1:
            raise ValueError("Unexpected ringback asset references")
        text = text.replace(asset, "antintwrk-ringback-v1.wav")
    own_loop = Path(__file__).with_name("call-tone-loop.js").read_text().replace("export function ", "function ", 1)
    # Never ship a source-map reference with stale generated offsets.
    return (own_loop + "\n" + re.sub(r"(?m)^//# sourceMappingURL=[^\n]*$", "", text)).encode("utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", choices=SPECS, required=True)
    parser.add_argument("--aar", type=Path)
    parser.add_argument("--dist", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if (args.aar is None) == (args.dist is None):
        parser.error("Choose exactly one pinned input: --aar or --dist")
    if args.dist and args.output.resolve() == args.dist.resolve():
        parser.error("The pinned dependency must remain unchanged")
    name = SPECS[args.version][0]
    relative = Path("assets") / name
    if args.aar:
        with zipfile.ZipFile(args.aar) as archive:
            original = archive.read("assets/element-call/" + relative.as_posix())
        destination = args.output / "element-call-antintwrk-tones-v1"
    else:
        original = (args.dist / relative).read_bytes()
        destination = args.output
    updated = patch(original, args.version)
    if args.output.exists():
        shutil.rmtree(args.output)
    if args.aar:
        with zipfile.ZipFile(args.aar) as archive:
            for entry in archive.infolist():
                if not entry.filename.startswith("assets/element-call/") or entry.is_dir():
                    continue
                asset = Path(entry.filename[len("assets/element-call/"):])
                if asset.is_absolute() or ".." in asset.parts:
                    raise ValueError("Unsafe dependency asset path")
                target = destination / asset
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(archive.read(entry))
    else:
        shutil.copytree(args.dist, destination)
    (destination / (relative.as_posix() + ".map")).unlink(missing_ok=True)
    target = destination / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.chmod(0o644)
    target.write_bytes(updated)
    (destination / "assets/antintwrk-ringback-v1.wav").write_bytes(ringback_bytes())
    (destination / "assets/antintwrk-busy-v1.wav").write_bytes(busy_bytes())
    (destination / "antintwrk-call-patch.json").write_text(json.dumps({
        "patch": "call-pickup-replay-and-telephone-tones-v1",
        "ringback": {"frequency_hz": 425, "on_seconds": 1, "off_seconds": 4, "peak_dbfs": -20},
        "busy": {"frequency_hz": 425, "on_seconds": 0.5, "off_seconds": 0.5, "cycles": 3, "peak_dbfs": -20},
        "upstream": args.version,
        "input_sha256": hashlib.sha256(original).hexdigest(),
        "output_sha256": hashlib.sha256(updated).hexdigest(),
    }, indent=2) + "\n")
    print(f"Verified telephone tones and pickup overlay for embedded {args.version}")


if __name__ == "__main__":
    main()
