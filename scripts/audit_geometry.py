#!/usr/bin/env python3
"""Geometric consistency audit for a live GVGL frame.

Pulls get_frame from the daemon and checks invariants that the daemon's own
tests assert on synthetic fixtures, but against the real desktop:

  - non-finite / zero-size normalized rects        (must be 0 — math bugs)
  - duplicate entity ids across the scene          (must be 0 — merge bugs)
  - window roots outside main-screen [0,1]±tol     (info — off-screen Spaces)
  - window-space coords outside [-0.3,1.3]         (info — AX truth, see below)
  - child screen rect <50% inside its scene parent (info — AX truth, see below)

The last two categories are NOT daemon bugs in general: the AX hierarchy is a
structural containment, not a geometric one. Known real-world producers:
  - Terminal's AXTextArea frame covers the whole scrollback buffer (y ≈ -179);
  - input-method candidate panels inject into the host app's menu-bar subtree;
  - MenuBarAgent nests menu bars of one display inside windows of another.
The audit prints them so regressions in OUR math can be told apart from
AX-reported weirdness by spot-checking the producers.

Usage: python3 scripts/audit_geometry.py [--socket ~/.gvgl/gvgl.sock]
"""
import json
import math
import socket
import sys

DEFAULT_SOCKET = f"{__import__('os').path.expanduser('~')}/.gvgl/gvgl.sock"


def fetch_frame(sock_path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(sock_path)
    s.sendall(b'{"method":"get_frame"}\n')
    buf = b""
    while True:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
        if buf.endswith(b"\n"):
            break
    s.close()
    return json.loads(buf)["result"]


def area(r):
    return max(r["w"] * r["h"], 1e-12)


def intersection(a, b):
    x1, y1 = max(a["x"], b["x"]), max(a["y"], b["y"])
    x2 = min(a["x"] + a["w"], b["x"] + b["w"])
    y2 = min(a["y"] + a["h"], b["y"] + b["h"])
    if x2 <= x1 or y2 <= y1:
        return 0.0
    return (x2 - x1) * (y2 - y1)


def main():
    sock = DEFAULT_SOCKET
    if "--socket" in sys.argv:
        sock = sys.argv[sys.argv.index("--socket") + 1]
    frame = fetch_frame(sock)

    stats = {
        "entities": 0,
        "contain": [],
        "win_space": [],
        "nonfinite": [],
        "zero_size": [],
        "offscreen": [],
        "ids": {},
    }

    def brief(r):
        return "{" + ", ".join(f"{k}={r[k]:.3f}" for k in "xywh") + "}"

    def walk(node, parent, win_node):
        eid = node["id"]
        stats["entities"] += 1
        g = node["geometry"]
        s, w = g["screen"], g["window"]

        for name, r in (("screen", s), ("window", w), ("local", g["local"])):
            for k in "xywh":
                if not math.isfinite(r[k]):
                    stats["nonfinite"].append((eid, name, k))
        if s["w"] <= 0 or s["h"] <= 0:
            stats["zero_size"].append((eid, node.get("role")))

        if parent is not None:
            ps = parent["geometry"]["screen"]
            if intersection(s, ps) / area(s) < 0.5:
                stats["contain"].append((eid[:60], node.get("role"), brief(s), brief(ps)))

        if node.get("role") == "AXWindow" and win_node is None:
            if not (-0.05 <= s["x"] <= 1.05 and -0.05 <= s["y"] <= 1.05):
                stats["offscreen"].append((eid[:60], brief(s)))

        if node.get("windowID") and node.get("windowID") != eid:
            if any(not (-0.3 <= w[k] <= 1.3) for k in "xywh"):
                stats["win_space"].append((eid[:60], node.get("role"), brief(w)))

        stats["ids"][eid] = stats["ids"].get(eid, 0) + 1
        for c in node.get("children") or []:
            walk(c, node, node if node.get("role") == "AXWindow" else win_node)

    for app in frame["scene"]:
        for root in app["children"]:
            walk(root, None, root if root.get("role") == "AXWindow" else None)

    dups = {k: v for k, v in stats["ids"].items() if v > 1}
    scr = frame["screen"]
    print(f"frame v{frame['version']} status={frame['status']} "
          f"entities={stats['entities']} apps={len(frame['scene'])}")
    print(f"screen={scr['width']}x{scr['height']} displays={len(scr.get('displays', []))}")
    print(f"non-finite coords: {len(stats['nonfinite'])} (must be 0)")
    print(f"zero/negative screen size: {len(stats['zero_size'])} (must be 0)")
    print(f"duplicate ids across scene: {len(dups)} (must be 0)")
    for k in list(dups)[:10]:
        print("   ", k, dups[k])
    print(f"containment violations (child<50% inside parent): {len(stats['contain'])} (info — AX truth)")
    for v in stats["contain"][:10]:
        print("   ", v)
    print(f"window-space out of [-0.3,1.3]: {len(stats['win_space'])} (info — AX truth)")
    for v in stats["win_space"][:10]:
        print("   ", v)
    print(f"window roots outside [0,1]±0.05: {len(stats['offscreen'])} (info — other Spaces)")

    hard_fail = stats["nonfinite"] or stats["zero_size"] or dups
    sys.exit(1 if hard_fail else 0)


if __name__ == "__main__":
    main()
