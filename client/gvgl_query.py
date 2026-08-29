#!/usr/bin/env python3
"""
gvgl_query — reference client for the GVGL virtual desktop daemon.

Talks to the daemon over a Unix Domain Socket (NDJSON protocol) and performs
local multi-dimensional scoring queries per the GVGL design doc (DESIGN.md
§6.1/§6.2). The daemon is never involved in execution; this client only reads
frames and prints pixel coordinates / optional cliclick commands.

Usage:
  gvgl_query.py status
  gvgl_query.py frame [--app pid:123] [--pretty]
  gvgl_query.py list [--verbose] [--json]
  gvgl_query.py map [--json]                       # V5: coarse quadrant map
  gvgl_query.py query [--role AXButton] [--label 登录] [--region q1]
                      [--app pid:123] [--display N] [--right-of ID] [--below ID]
                      [--near ID] [--top N] [--pixels] [--cliclick] [--execute] [--json]
  gvgl_query.py watch [--interval 0.5] [--max 10]
  gvgl_query.py subscribe [--since N] [--pull] [--max 10]

Examples:
  gvgl_query.py map                                # agent first fetch: minimap
  gvgl_query.py query --role AXButton --label 登录 --top 3 --pixels
  gvgl_query.py query --display 2 --region q2      # right-top of display 2
  gvgl_query.py query --role AXButton --right-of pid:123:0-1 --cliclick
  gvgl_query.py subscribe --pull          # push events + incremental pulls
"""

import argparse
import json
import os
import socket
import sys
import time
from collections import Counter
from typing import Iterator

DEFAULT_SOCKET = os.environ.get("GVGL_SOCKET") or os.path.expanduser("~/.gvgl/gvgl.sock")

# ---------------------------------------------------------------------------
# Transport

class GVGLClient:
    def __init__(self, socket_path: str = DEFAULT_SOCKET, timeout: float = 30.0):
        self.socket_path = socket_path
        self.timeout = timeout
        self._frame = None       # cached frame

    def call(self, method: str, app: str | None = None) -> dict:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        try:
            s.connect(self.socket_path)
            req = {"method": method}
            if app:
                req["app"] = app
            s.sendall((json.dumps(req) + "\n").encode())
            resp = b""
            while True:
                chunk = s.recv(1048576)
                if not chunk:
                    break
                resp += chunk
                if b"\n" in resp:
                    break
            payload = json.loads(resp.decode())
        finally:
            s.close()
        if "error" in payload:
            raise RuntimeError(f"daemon error {payload['error'].get('code')}: {payload['error'].get('message')}")
        return payload["result"]

    # -- frame access with version-aware cache ------------------------------

    def get_frame(self, app: str | None = None, force: bool = False) -> dict:
        if force or self._frame is None or app is not None:
            self._frame = self.call("get_frame", app=app)
        return self._frame

    def get_frame_since(self, since: int, app: str | None = None) -> dict | None:
        """Incremental pull: returns the 'changed' payload, or None if no
        change since `since`."""
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(self.timeout)
        try:
            s.connect(self.socket_path)
            req = {"method": "get_frame", "since": since}
            if app:
                req["app"] = app
            s.sendall((json.dumps(req) + "\n").encode())
            resp = b""
            while True:
                chunk = s.recv(1048576)
                if not chunk:
                    break
                resp += chunk
                if b"\n" in resp:
                    break
            payload = json.loads(resp.decode())
        finally:
            s.close()
        if "error" in payload:
            raise RuntimeError(f"daemon error {payload['error'].get('code')}: {payload['error'].get('message')}")
        result = payload["result"]
        if result.get("event") == "no_change":
            return None
        # Cache the incremental frame so later queries are consistent.
        if "frame" in result:
            self._frame = result["frame"]
        return result

    def subscribe(self, since: int | None = None,
                  regions: list[str] | None = None) -> Iterator[dict]:
        """Long-lived subscription: yields one event dict per line from the
        daemon until the connection closes. `regions` (V5.1) is a server-side
        bucket mask ("d<displayID>q<region>", e.g. "d1q2"; "sys" for frontmost
        changes) — only bumps touching a masked bucket are pushed."""
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(None)
        try:
            s.connect(self.socket_path)
        except OSError as exc:
            raise ConnectionError(f"cannot reach daemon at {self.socket_path}: {exc}")
        req = {"method": "subscribe"}
        if since is not None:
            req["since"] = since
        if regions:
            req["regions"] = regions
        s.sendall((json.dumps(req) + "\n").encode())
        buf = b""
        while True:
            chunk = s.recv(1048576)
            if not chunk:
                break
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                if not line.strip():
                    continue
                try:
                    yield json.loads(line)
                except json.JSONDecodeError:
                    continue
        s.close()

    def entities(self) -> list[dict]:
        """V4: flatten the scene tree (depth-first, document order)."""
        out = []

        def visit(node: dict):
            out.append(node)
            for child in node.get("children") or []:
                visit(child)

        for app in self.get_frame().get("scene", []):
            for root in app.get("children", []):
                visit(root)
        return out

    def entity_map(self) -> dict[str, dict]:
        return {e["id"]: e for e in self.entities()}

    def screen(self) -> tuple[float, float]:
        s = self.get_frame()["screen"]
        return s["width"], s["height"]

# ---------------------------------------------------------------------------
# Scoring (§6.2)

COMPATIBLE_ROLES = {
    "AXButton": {"AXButton", "AXMenuItem"},
    "AXMenuItem": {"AXMenuItem", "AXButton"},
    "AXCheckBox": {"AXCheckBox", "AXRadioButton"},
    "AXRadioButton": {"AXRadioButton", "AXCheckBox"},
    "AXTextField": {"AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox"},
    "AXTextArea": {"AXTextArea", "AXTextField"},
    "AXSecureTextField": {"AXSecureTextField", "AXTextField"},
    "AXComboBox": {"AXComboBox", "AXTextField", "AXPopUpButton"},
    "AXPopUpButton": {"AXPopUpButton", "AXComboBox"},
}

NEAR_THRESHOLD = 0.05

def _is_ancestor(ancestor_id: str, descendant: dict, by_id: dict[str, dict]) -> bool:
    """Walk entityParentID links (present on every node, flat or tree)."""
    current = descendant.get("entityParentID")
    hops = 0
    while current and hops < 64:
        if current == ancestor_id:
            return True
        current = (by_id.get(current) or {}).get("entityParentID")
        hops += 1
    return False

def _spatial_score(e: dict, ref: dict, ref_dir: str, by_id: dict[str, dict]) -> float:
    """V4: spatial relation scoring computed geometrically on demand — same
    rules as the old stored relations (direction 1.0 / near 0.7 / same
    quadrant as the reference 0.5), but with no O(N²) frame payload and no
    truncation caps. Cross-window pairs are judged in screen space."""
    same_window = e.get("windowID") and e.get("windowID") == ref.get("windowID")
    a = e["geometry"]["window"] if same_window else e["geometry"]["screen"]
    b = ref["geometry"]["window"] if same_window else ref["geometry"]["screen"]
    norm = ref_dir.replace("-", "").lower()

    acx, acy = a["x"] + a["w"] / 2, a["y"] + a["h"] / 2
    bcx, bcy = b["x"] + b["w"] / 2, b["y"] + b["h"] / 2
    is_near = ((acx - bcx) ** 2 + (acy - bcy) ** 2) ** 0.5 < NEAR_THRESHOLD
    same_region = e["geometry"].get("region") == ref["geometry"].get("region")

    if norm == "near":
        if is_near:
            return 1.0
        return 0.5 if same_region else 0.0

    # R12: containment prunes the direction tier (near stays reachable).
    contained = (_is_ancestor(e["id"], ref, by_id)
                 or _is_ancestor(ref["id"], e, by_id))
    if not contained:
        satisfied = False
        if norm == "rightof":
            satisfied = a["x"] > b["x"] + b["w"]
        elif norm == "leftof":
            satisfied = a["x"] + a["w"] < b["x"]
        elif norm == "above":
            satisfied = a["y"] + a["h"] < b["y"]
        elif norm == "below":
            satisfied = a["y"] > b["y"] + b["h"]
        if satisfied:
            return 1.0
    if is_near:
        return 0.7
    return 0.5 if same_region else 0.0

def score_entity(e: dict, role: str | None, label: str | None,
                 ref: dict | None, ref_dir: str | None,
                 by_id: dict[str, dict]) -> tuple[float, dict]:
    sem, role_s, spatial, size, topo = 0.0, 0.0, 0.0, 0.0, 0.0

    # SemanticScore
    if label:
        title = (e.get("title") or "")
        if title == label:
            sem = 1.0
        elif label in title:
            sem = 0.7
        elif label in (e.get("placeholder") or ""):
            sem = 0.65
        elif label in (e.get("detail") or ""):
            sem = 0.6
        elif label in (e.get("value") or ""):
            sem = 0.55
        elif label in (e.get("identifier") or ""):
            sem = 0.5

    # RoleScore
    if role:
        if e["role"] == role:
            role_s = 1.0
        elif role in COMPATIBLE_ROLES.get(e["role"], set()):
            role_s = 0.6

    # SpatialRelationScore (§4.2 tiers, V4 geometric on-demand)
    if ref is not None and ref_dir:
        spatial = _spatial_score(e, ref, ref_dir, by_id)
    elif ref is not None and not ref_dir and e["id"] == ref["id"]:
        spatial = 1.0

    # SizeScore
    area = e["geometry"]["area"]
    if 0.001 <= area <= 0.05:
        size = 1.0
    elif 0.0005 <= area <= 0.1:
        size = 0.6
    else:
        size = 0.2

    # TopologyScore
    if e.get("windowID"):
        topo += 0.3
    if e.get("enabled", True):
        topo += 0.3
    if e.get("actions"):
        topo += 0.4

    total = sem * 0.35 + role_s * 0.20 + spatial * 0.25 + size * 0.10 + topo * 0.10
    breakdown = dict(semantic=sem, role=role_s, spatial=spatial, size=size, topology=topo)
    return total, breakdown

# ---------------------------------------------------------------------------
# Query (§6.1)

def query(client: GVGLClient, role: str | None = None, label: str | None = None,
          region: str | None = None, cell: str | None = None,
          app: str | None = None, display: int | None = None,
          ref_id: str | None = None, ref_dir: str | None = None,
          top: int = 5) -> list[dict]:
    frame = client.get_frame(app=app)
    entities = client.entities()
    by_id = {e["id"]: e for e in entities}

    # Reference entity for the spatial term (V4: geometric, no relation table).
    ref_entity = by_id.get(ref_id) if ref_id else None

    candidates = entities
    if region:
        region_ids = frame["index"]["byRegion"].get(region, [])
        region_set = set(region_ids)
        candidates = [e for e in candidates if e["id"] in region_set]
    elif cell:
        # V2-1 grid pre-filter: index.byGrid[cell] (spatial hash).
        grid_ids = set(frame["index"].get("byGrid", {}).get(cell, []))
        candidates = [e for e in candidates if e["id"] in grid_ids]
    if display is not None:
        # V5: physical-display filter (CGDirectDisplayID, see `map` output) —
        # pairs with --region to target one screen's quadrant.
        candidates = [e for e in candidates if e.get("displayID") == display]

    scored = []
    for e in candidates:
        total, breakdown = score_entity(e, role, label, ref_entity, ref_dir, by_id)
        scored.append({"id": e["id"], "entity": e, "score": total, "breakdown": breakdown})

    scored.sort(key=lambda s: -s["score"])
    return scored[:top]

def describe_result(scored: list[dict], top_n: int = 3) -> tuple[str, dict | None]:
    """Confidence gates per §6.3: <0.4 not_found, <0.7 ambiguous."""
    if not scored or scored[0]["score"] < 0.4:
        return "not_found", None
    if scored[0]["score"] < 0.7:
        return "ambiguous", scored[0]
    return "hit", scored[0]

# ---------------------------------------------------------------------------
# Execution helpers (GVGL never executes; the caller does)

def to_pixels(client: GVGLClient, entity: dict) -> tuple[float, float]:
    """Quartz pixel center per the original design doc 转换3:
    pixelX = centerX * screenW (main-display normalization; secondary-display
    elements carry negative/out-of-range centers that resolve correctly in
    global Quartz coordinates)."""
    w, h = client.screen()
    g = entity["geometry"]
    return g["centerX"] * w, g["centerY"] * h

def cliclick_command(x: float, y: float) -> str:
    return f"cliclick c:{x:.0f},{y:.0f}"

def check_cliclick() -> bool:
    import shutil
    return shutil.which("cliclick") is not None

# ---------------------------------------------------------------------------
# CLI

def cmd_status(args):
    client = GVGLClient(args.socket)
    try:
        st = client.call("get_status")
        print(json.dumps(st, indent=2, ensure_ascii=False))
        return 0
    except (ConnectionError, OSError) as exc:
        print(f"cannot reach daemon at {args.socket}: {exc}", file=sys.stderr)
        print("start it with: .build/debug/gvgl", file=sys.stderr)
        return 1

def cmd_frame(args):
    client = GVGLClient(args.socket)
    try:
        frame = client.call("get_frame", app=args.app)
    except (ConnectionError, OSError) as exc:
        print(f"cannot reach daemon at {args.socket}: {exc}", file=sys.stderr)
        return 1
    if args.pretty:
        print(json.dumps(frame, indent=2, ensure_ascii=False))
    else:
        print(json.dumps(frame, ensure_ascii=False))
    return 0

def weak_ax_summary(scored: list[dict]) -> list[dict]:
    """Original doc §4.3 `ax_weak`: role-matched elements exist but carry no
    usable titles — return structured summaries for the upper layer to decide.
    A non-empty value/placeholder counts as usable text (V3): web static text
    often carries its content in AXValue while the title stays empty."""
    out = []
    for s in scored:
        e = s["entity"]
        if not (e.get("title") or e.get("detail") or e.get("identifier")
                or e.get("value") or e.get("placeholder")):
            out.append({
                "id": e["id"],
                "role": e["role"],
                "rect": e["geometry"]["screen"],
                "region": e["geometry"].get("region"),
            })
    return out

def cmd_query(args):
    client = GVGLClient(args.socket)
    try:
        scored = query(
            client, role=args.role, label=args.label, region=args.region,
            cell=args.cell, app=args.app, display=args.display,
            ref_id=args.reference, ref_dir=args.relation, top=args.top,
        )
    except (ConnectionError, OSError, RuntimeError) as exc:
        print(f"query failed: {exc}", file=sys.stderr)
        return 1

    status, best = describe_result(scored)

    # Original doc §4.3: weak AX (elements exist but no usable titles) returns
    # structured element summaries instead of a bare not_found.
    if status == "not_found" and scored:
        weak = weak_ax_summary(scored)
        if weak and all(s["breakdown"]["semantic"] == 0.0 for s in scored):
            status = "ax_weak"

    if args.json:
        result = {
            "status": status,
            "hits": [
                {
                    "id": s["id"],
                    "score": round(s["score"], 4),
                    "role": s["entity"]["role"],
                    "title": s["entity"].get("title"),
                    "geometry": s["entity"]["geometry"],
                    "breakdown": s["breakdown"],
                    "pixels": list(to_pixels(client, s["entity"])),
                    "cliclick": cliclick_command(*to_pixels(client, s["entity"])),
                }
                for s in scored
            ],
        }
        # Original doc §4.3 ambiguous: { status, best: {id, score}, candidates }.
        if best is not None:
            result["best"] = {"id": best["id"], "score": round(best["score"], 4)}
        if status == "ax_weak":
            result["elements"] = weak_ax_summary(scored)
        print(json.dumps(result, ensure_ascii=False))
        return 0

    print(f"status: {status}")
    if status == "ax_weak":
        for e in weak_ax_summary(scored)[: args.top]:
            print(f"  {e['id']} role={e['role']} rect={e['rect']} region={e['region']}")
        return 0
    for i, s in enumerate(scored[: args.top]):
        e = s["entity"]
        x, y = to_pixels(client, e) if args.pixels else (None, None)
        line = (f"  #{i + 1} {e['id']} role={e['role']} score={s['score']:.2f} "
                f"title={e.get('title')!r} rect={e['geometry']['screen']}")
        if args.pixels:
            line += f" pixels=({x:.0f},{y:.0f})"
        if args.cliclick or args.execute:
            line += "  " + cliclick_command(x, y)
        print(line)
        print(f"      breakdown={s['breakdown']}")
    if status == "hit" and args.execute and best is not None:
        if not check_cliclick():
            print("cliclick not found in PATH (install via `brew install cliclick`)",
                  file=sys.stderr)
            return 1
        x, y = to_pixels(client, best["entity"])
        import subprocess
        subprocess.run(["cliclick", f"c:{x:.0f},{y:.0f}"], check=True)
        print(f"      executed click at ({x:.0f},{y:.0f})")
    return 0

def cmd_list(args):
    """Desktop overview: windows per app, entity counts, top roles."""
    client = GVGLClient(args.socket)
    try:
        frame = client.get_frame()
    except (ConnectionError, OSError) as exc:
        print(f"cannot reach daemon at {args.socket}: {exc}", file=sys.stderr)
        return 1

    entities = client.entities()
    windows = [e for e in entities if e["role"] == "AXWindow"]

    if args.json:
        out = {
            "status": frame["status"],
            "version": frame["version"],
            "synced_at": frame.get("syncedAt"),
            "frontmost_app": frame.get("frontmostApp"),
            "apps": [
                {
                    "app": app["appKey"],
                    "name": app.get("name"),
                    "status": app.get("status"),
                    "entities": app.get("entityCount"),
                    "windows": [e.get("title") for e in app.get("children", [])
                                if e["role"] == "AXWindow"],
                }
                for app in frame.get("scene", [])
            ],
        }
        print(json.dumps(out, ensure_ascii=False))
        return 0

    print(f"frame status={frame['status']} version={frame['version']} "
          f"entities={len(entities)} windows={len(windows)} "
          f"frontmost={frame.get('frontmostApp')}")
    for app in frame.get("scene", []):
        win_titles = [e["title"] for e in app.get("children", [])
                      if e["role"] == "AXWindow" and e.get("title")]
        extra = ""
        cg_w = app.get("cgWindowCount")
        if cg_w:  # only shown with --cg-check diagnostics
            ax_w = app.get("axWindowCount") or 0
            extra = f" [ax:{ax_w}/cg:{cg_w}]"
            missing = app.get("missingWindowTitles") or []
            if missing:
                extra += f" missing:{missing}"
        print(f"  {app['appKey']} {app.get('name') or '?'}: "
              f"{app.get('entityCount', 0)} entities [{app.get('status')}]  "
              f"windows={win_titles}{extra}")
        if args.verbose:
            app_entities = [e for e in entities if e["appID"] == app["appKey"]]
            roles = Counter(e["role"] for e in app_entities)
            for role, count in roles.most_common(5):
                print(f"      {role}: {count}")
    return 0

def cmd_map(args):
    """V5 coarse desktop map: displays + top-level windows in Display Space,
    rendered as a per-display quadrant grid. The agent's first fetch — drill
    down with `query --display N --region qK` or `frame --app pid:NNN`."""
    client = GVGLClient(args.socket)
    try:
        m = client.call("get_map")
    except (ConnectionError, OSError) as exc:
        print(f"cannot reach daemon at {args.socket}: {exc}", file=sys.stderr)
        return 1

    if args.json:
        print(json.dumps(m, indent=2, ensure_ascii=False))
        return 0

    quadrants = {"q1": [], "q2": [], "q3": [], "q4": []}
    for d in m.get("displays", []):
        quadrants.setdefault(f"d{d['index']}", {"q1": [], "q2": [], "q3": [], "q4": []})

    def label(w):
        name = w.get("appName") or w.get("appKey")
        title = w.get("title") or ""
        star = "*" if w.get("frontmost") else " "
        z = w.get("zIndex")
        zt = f" z{z}" if z is not None else " z?"
        return f"{star}{name}{zt}: {title}"[:60]

    for w in m.get("windows", []):
        quadrants.setdefault(f"d{w['display']}", {"q1": [], "q2": [], "q3": [], "q4": []})
        quadrants[f"d{w['display']}"][w["region"]].append(label(w))

    print(f"desktop map v{m.get('version')} status={m.get('status')} "
          f"displays={len(m.get('displays', []))} "
          f"windows={len(m.get('windows', []))} "
          f"frontmost={m.get('frontmostApp')}")
    for d in m.get("displays", []):
        cells = quadrants.get(f"d{d['index']}", {"q1": [], "q2": [], "q3": [], "q4": []})
        print(f"\ndisplay {d['index']} (id={d['id']}) {int(d['width'])}x{int(d['height'])}"
              f" @({int(d['x'])},{int(d['y'])})"
              f"{' [main]' if d['index'] == 0 else ''}")
        for row, names in (("q1 左上 | q2 右上", ("q1", "q2")),
                           ("q3 左下 | q4 右下", ("q3", "q4"))):
            left = cells[names[0]] or ["(空)"]
            right = cells[names[1]] or ["(空)"]
            for i in range(max(len(left), len(right))):
                l = left[i] if i < len(left) else ""
                r = right[i] if i < len(right) else ""
                print(f"  {l:<38} | {r}")
            print("  " + "-" * 78)
    print("\n* = 前台 App 窗口；z0 = 最前（CG 全局 Z 序）；矩形/象限均为所在屏归一化（Display Space）")
    return 0

def cmd_watch(args):
    client = GVGLClient(args.socket)
    last_version = None
    seen = 0
    while args.max is None or seen < args.max:
        try:
            frame = client.get_frame(force=True)
        except (ConnectionError, OSError) as exc:
            print(f"daemon unreachable: {exc}", file=sys.stderr)
            return 1
        if last_version is not None and frame["version"] != last_version:
            print(f"version {last_version} -> {frame['version']} "
                  f"entities={len(client.entities())} status={frame['status']}")
            seen += 1
        last_version = frame["version"]
        time.sleep(args.interval)
    return 0

def cmd_subscribe(args):
    """Push subscription: daemon pushes version-change events over the long
    connection; with --pull, each event triggers an incremental frame fetch.
    With --regions, the daemon only pushes bumps touching those buckets."""
    client = GVGLClient(args.socket)
    seen = 0
    try:
        for event in client.subscribe(since=args.since, regions=args.regions):
            if event.get("event") == "ping":
                continue
            if event.get("event") == "frame":
                version = event.get("version")
                apps = event.get("changed_apps", [])
                regions = event.get("changed_regions", [])
                line = f"event=frame version={version} changed_apps={apps} changed_regions={regions}"
                if args.pull:
                    try:
                        result = client.get_frame_since(since=version)
                        if result:
                            line += f" entities={len(client.entities())} status={result['frame']['status']}"
                        else:
                            line += " (no_change)"
                    except (ConnectionError, OSError, RuntimeError) as exc:
                        line += f" pull_failed={exc}"
                print(line, flush=True)
                seen += 1
                if args.max is not None and seen >= args.max:
                    break
            elif args.verbose:
                print(json.dumps(event, ensure_ascii=False), flush=True)
    except KeyboardInterrupt:
        pass
    except (ConnectionError, OSError) as exc:
        print(f"subscription ended: {exc}", file=sys.stderr)
        return 1
    return 0

def main():
    parser = argparse.ArgumentParser(description="GVGL reference query client")
    parser.add_argument("--socket", default=DEFAULT_SOCKET, help="daemon socket path")
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="daemon status")

    p_frame = sub.add_parser("frame", help="fetch a frame")
    p_frame.add_argument("--app", help="filter to one app (pid:NNN)")
    p_frame.add_argument("--pretty", action="store_true")

    p_query = sub.add_parser("query", help="scored spatial query")
    p_query.add_argument("--role", help="AX role, e.g. AXButton")
    p_query.add_argument("--label", help="title/description/identifier keyword")
    p_query.add_argument("--region", help="q1/q2/q3/q4 (of the element's own display, V5)")
    p_query.add_argument("--cell", help="grid cell pre-filter (e.g. r1c2, grid size from frame)")
    p_query.add_argument("--app", help="filter to one app (pid:NNN)")
    p_query.add_argument("--display", type=int, default=None,
                         help="CG display id filter (see `map`), e.g. 1 main / 2 secondary")
    p_query.add_argument("--reference", help="reference entity id")
    p_query.add_argument("--relation", help="above/below/left-of/right-of/near",
                         choices=["above", "below", "left-of", "right-of", "near"])
    p_query.add_argument("--top", type=int, default=5)
    p_query.add_argument("--pixels", action="store_true", help="print pixel coords")
    p_query.add_argument("--cliclick", action="store_true", help="print cliclick command")
    p_query.add_argument("--execute", action="store_true", help="actually run cliclick")
    p_query.add_argument("--json", action="store_true", help="machine-readable output")
    p_query.set_defaults(func=cmd_query)

    p_list = sub.add_parser("list", help="desktop overview (apps/windows)")
    p_list.add_argument("--verbose", action="store_true", help="include role counts")
    p_list.add_argument("--json", action="store_true", help="machine-readable output")
    p_list.set_defaults(func=cmd_list)

    p_watch = sub.add_parser("watch", help="poll for version changes")
    p_watch.add_argument("--interval", type=float, default=0.5)
    p_watch.add_argument("--max", type=int, default=None)
    p_watch.set_defaults(func=cmd_watch)

    p_map = sub.add_parser("map", help="coarse desktop map (displays + windows in quadrants, V5)")
    p_map.add_argument("--json", action="store_true", help="machine-readable output")
    p_map.set_defaults(func=cmd_map)

    p_sub = sub.add_parser("subscribe", help="push subscription (long connection)")
    p_sub.add_argument("--since", type=int, default=None, help="initial version (skip older changes)")
    p_sub.add_argument("--regions", nargs="+", default=None,
                       help="bucket mask, e.g. --regions d1q2 d2q4 sys (V5.1); "
                            "only bumps touching these buckets are pushed")
    p_sub.add_argument("--pull", action="store_true", help="incremental frame pull per event")
    p_sub.add_argument("--max", type=int, default=None, help="stop after N events")
    p_sub.add_argument("--verbose", action="store_true")
    p_sub.set_defaults(func=cmd_subscribe)

    args = parser.parse_args()
    if args.command == "status":
        return cmd_status(args)
    if args.command == "frame":
        return cmd_frame(args)
    if args.command == "list":
        return cmd_list(args)
    if args.command == "subscribe":
        return cmd_subscribe(args)
    return args.func(args)

if __name__ == "__main__":
    sys.exit(main())
