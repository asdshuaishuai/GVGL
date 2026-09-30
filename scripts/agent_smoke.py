#!/usr/bin/env python3
"""End-to-end proof of GVGL's core promise.

The product is: *read-only geometric model + query*, so that an agent can ask
"where is the 登录 button" and get a trustworthy answer **with pixel
coordinates**, which the caller then clicks. Every prior check verified a piece
of that chain in isolation. None of them closed the loop: nobody ever took a
coordinate GVGL produced and actually clicked it.

This does. It spawns a disposable, non-destructive `display dialog`, asks the
daemon to locate a named button, clicks the reported pixel, and checks that the
dialog actually closed.

SAFETY — this runs on a real desktop, so the guard is fail-closed:
  * the target must be a dialog we spawned ourselves;
  * the reported pixel centre must fall strictly inside the dialog's own
    rect, as reported by the daemon. A coordinate that lands anywhere else is
    REFUSED, not clicked. A miss is therefore at worst a miss on the dialog
    itself (harmless), never a stray click on the user's work.
  * only the "取消" (cancel) button is ever clicked. Nothing is confirmed,
    saved, or submitted.

Usage:
  .build/release/gvgl --socket /tmp/gvgl-smoke.sock &
  python3 scripts/agent_smoke.py --socket /tmp/gvgl-smoke.sock

Exit 0 = the loop closed: found, guarded, clicked, effect observed.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time

CLICK_BUTTON = "取消"          # never anything that confirms or saves
DIALOG_TITLE = "GVGL smoke"


def call(sock_path, req, timeout=60):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    s.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    s.close()
    if not buf:
        raise SystemExit("empty response")
    return json.loads(buf.decode().split("\n")[0])["result"]


def walk(node, out):
    if "role" in node:
        out.append(node)
    for child in node.get("children") or []:
        walk(child, out)


def spawn_dialog():
    script = (f'display dialog "GVGL 端到端" buttons {{"取消", "登录"}} '
              f'default button "登录" with title "{DIALOG_TITLE}" '
              f'giving up after 180')
    p = subprocess.Popen(["osascript", "-e", script],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2.5)
    return p


def dialog_is_open():
    r = subprocess.run(
        ["osascript", "-e",
         f'tell application "System Events" to get name of windows of '
         f'(first process whose name is "osascript")'],
        capture_output=True, text=True, timeout=15)
    return DIALOG_TITLE in r.stdout


def click(x, y):
    if subprocess.run(["which", "cliclick"], capture_output=True).returncode == 0:
        subprocess.run(["cliclick", f"c:{int(x)},{int(y)}"], timeout=15)
    else:
        subprocess.run(["osascript", "-e",
                        f'tell application "System Events" to click at '
                        f'{{{int(x)}, {int(y)}}}'], timeout=15)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--socket", default=os.path.expanduser("~/.gvgl/gvgl.sock"))
    ap.add_argument("--label", default=CLICK_BUTTON)
    ap.add_argument("--dry-run", action="store_true",
                    help="locate and guard, but do not click")
    args = ap.parse_args()

    failures = []

    def check(name, cond, detail=""):
        print(f"{'PASS' if cond else 'FAIL'}  {name}" + (f"  [{detail}]" if detail else ""))
        if not cond:
            failures.append(name)

    print("spawning a disposable dialog…")
    proc = spawn_dialog()
    try:
        check("dialog is on screen", dialog_is_open())

        # Give the daemon a reconcile tick or two to discover the new process.
        deadline = time.time() + 20
        found = None
        while time.time() < deadline:
            frame = call(args.socket, {"method": "get_frame"})
            ents = []
            for app in frame["scene"]:
                walk(app, ents)
            hits = [e for e in ents
                    if e.get("title") == args.label and e.get("role") == "AXButton"]
            if hits:
                found = hits[0]
                break
            time.sleep(1.5)
        check("daemon sees the target button", found is not None,
              args.label if found else f"not found within 20s")

        if not found:
            return 1

        # ---- the containment guard: fail closed -----------------------------
        screen = frame["screen"]
        ent = found["geometry"]["screen"]
        cx = (ent["x"] + ent["w"] / 2) * screen["width"]
        cy = (ent["y"] + ent["h"] / 2) * screen["height"]

        # The dialog window's own rect, straight from the daemon.
        wins = [e for e in ents if e.get("role") == "AXWindow"
                and e.get("title") == DIALOG_TITLE]
        check("daemon reports the dialog window", len(wins) == 1)
        if not wins:
            return 1
        w = wins[0]["geometry"]["screen"]
        wx0, wy0 = w["x"] * screen["width"], w["y"] * screen["height"]
        wx1 = (w["x"] + w["w"]) * screen["width"]
        wy1 = (w["y"] + w["h"]) * screen["height"]

        inside = (wx0 <= cx <= wx1) and (wy0 <= cy <= wy1)
        print(f"      dialog rect px: ({wx0:.0f},{wy0:.0f})-({wx1:.0f},{wy1:.0f})")
        print(f"      target  px    : ({cx:.0f},{cy:.0f})")
        check("target pixel lies inside the dialog (guard)", inside,
              "refusing to click otherwise — a miss must never land outside")

        check("target exposes an action", bool(found.get("actions")),
              str(found.get("actions")))

        if not inside:
            print("\nGUARD TRIPPED — refusing to click.")
            return 1

        if args.dry_run:
            print("\ndry run: not clicking.")
            return 0

        print(f"clicking ({cx:.0f}, {cy:.0f})…")
        click(cx, cy)
        time.sleep(2.5)
        check("dialog closed after the click", not dialog_is_open(),
              "the click landed and activated the control")
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()

    print()
    if failures:
        print(f"{len(failures)} FAILED: {', '.join(failures)}")
        return 1
    print("end-to-end loop closed: located -> guarded -> clicked -> effect observed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
