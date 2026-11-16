#!/usr/bin/env python3
"""End-to-end proof of GVGL's computer-use loop — with zero screenshots.

The claim under test is not "the daemon exposes geometry". It is:

    perceive (AX only) → act (AX action, not a coordinate guess) → verify
    (read the element back) → observe the app actually respond

This script spawns a disposable `display dialog`, and drives it entirely
through `gvglact`:

  1. transcript       read the dialog as text (no OCR, no image)
  2. find             locate the text field by role (role is a hard filter)
  3. type             write text, verified by reading AXValue back
  4. text             read the full value directly from AX
  5. press            AXPress on the Cancel button (assert: *not* a click)
  6. observe          the osascript process exits because the dialog closed

Safety: only a dialog this script spawned is touched; only "取消" (cancel) is
pressed; the reported text is read back from AX, never from an image.

Usage:
  .build/release/gvgl --socket /tmp/gvgl-act-smoke.sock &
  python3 scripts/act_smoke.py --socket /tmp/gvgl-act-smoke.sock

Exit 0 = every step passed.
"""
import argparse
import json
import os
import subprocess
import sys
import time

PROMPT = "GVGL ACT SMOKE 动作层端到端"
TYPED = "hello GVGL 你好 42"


def call(gvglact, socket, *args, timeout=20):
    env = dict(os.environ)
    env["GVGL_SOCKET"] = socket
    proc = subprocess.run(
        [gvglact, *args], env=env, capture_output=True, text=True, timeout=timeout
    )
    out = proc.stdout.strip()
    if not out:
        raise RuntimeError(
            f"{' '.join(args)} produced no output (exit {proc.returncode}): {proc.stderr.strip()}"
        )
    try:
        payload = json.loads(out.splitlines()[-1])
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{' '.join(args)} returned non-JSON: {out[:400]}") from exc
    return proc.returncode, payload


def step(name, fn):
    started = time.time()
    detail = fn()
    elapsed = int((time.time() - started) * 1000)
    print(f"  ✓ {name} ({elapsed}ms)")
    return {"step": name, "ok": True, "latency_ms": elapsed, "detail": detail}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default="/tmp/gvgl-act-smoke.sock")
    parser.add_argument("--gvglact", default=".build/release/gvglact")
    parser.add_argument("--timeout", type=float, default=12.0)
    args = parser.parse_args()

    gvglact = args.gvglact
    if not os.path.isabs(gvglact):
        gvglact = os.path.join(os.getcwd(), gvglact)
    if not os.access(gvglact, os.X_OK):
        sys.exit(f"gvglact not executable: {gvglact} (run scripts/build first)")
    if not os.path.exists(args.socket):
        sys.exit(f"no daemon socket at {args.socket}; start gvgl on that socket first")

    script = (
        f'display dialog "{PROMPT}" default answer "" '
        f'buttons {{"取消","好"}} default button "好" with title "GVGL ACT SMOKE"'
    )
    dialog = subprocess.Popen(
        ["osascript", "-e", script],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    pid = f"pid:{dialog.pid}"
    evidence = {"dialog_pid": dialog.pid, "steps": []}

    try:
        # 1. Wait until the daemon has captured the dialog. Discovery is a
        #    CGWindowList pass each reconcile tick, so this is not instant.
        def wait_for_capture():
            deadline = time.time() + args.timeout
            last = None
            while time.time() < deadline:
                _, payload = call(gvglact, args.socket, "find", "--app", pid,
                                  "--role", "AXTextField")
                if payload.get("data"):
                    return {"entities": len(payload["data"])}
                last = payload
                time.sleep(0.2)
            raise AssertionError(f"dialog never appeared in the model: {last}")

        evidence["steps"].append(step("perceive: dialog captured", wait_for_capture))

        # 2. Locate the text field and the cancel button by role/label.
        def find_targets():
            _, fields = call(gvglact, args.socket, "find", "--app", pid,
                             "--role", "AXTextField")
            field = fields["data"][0]
            _, buttons = call(gvglact, args.socket, "find", "--app", pid,
                              "--role", "AXButton", "--label", "取消")
            button = buttons["data"][0]
            assert field["role"] == "AXTextField", field
            assert button["title"] == "取消", button
            return {
                "field": field["id"],
                "window": field.get("window"),
                "button": button["id"],
            }

        found = find_targets()
        evidence["steps"].append(step("locate: field + cancel button", lambda: found))

        # 3. Read the dialog as text — the screenshot-free replacement.
        def read_transcript():
            argv = [gvglact, args.socket, "transcript", "--app", pid]
            if found.get("window"):
                argv += ["--window", found["window"]]
            _, payload = call(*argv)
            data = payload["data"]
            text = data["text"]
            assert PROMPT in text, f"prompt missing from transcript: {text[:300]}"
            assert "取消" in text and "好" in text, "buttons missing from transcript"
            return {"characters": data["characters"], "preview": text[:120]}

        evidence["steps"].append(step("read: transcript without a screenshot", read_transcript))

        # 4. Type text; the method must be verified by reading the value back.
        def type_text():
            code, payload = call(gvglact, args.socket, "type", "--id", found["field"],
                                 "--text", TYPED, "--timeout", "3")
            assert code == 0 and payload["ok"], payload
            assert payload["verified"], f"typing was not verified: {payload}"
            assert payload["after"]["element"]["value"] == TYPED, payload
            return {"method": payload["method"], "value": payload["after"]["element"]["value"]}

        evidence["steps"].append(step("act: type into the field", type_text))

        # 5. Read the value back through the independent `text` path.
        def read_value():
            _, payload = call(gvglact, args.socket, "text", "--id", found["field"])
            assert payload["data"] == TYPED, payload
            return {"value": payload["data"]}

        evidence["steps"].append(step("verify: full AXValue read-back", read_value))

        # 6. Press Cancel semantically. The assertion that matters: the method
        #    is an AX action, not a coordinate click.
        def press_cancel():
            code, payload = call(gvglact, args.socket, "press", "--id", found["button"],
                                 "--timeout", "3")
            assert code == 0 and payload["ok"], payload
            assert payload["method"] == "ax_press", f"expected AX action, got {payload['method']}"
            assert payload["after"]["element"]["exists"] is False, "button still exists"
            assert payload["changed"] and payload["verified"], payload
            return {"method": payload["method"], "changed": payload["changed"]}

        evidence["steps"].append(step("act: AXPress cancel (no click)", press_cancel))

        # 7. The app itself must have reacted: osascript exits when the dialog
        #    is dismissed. `display dialog` reports -128 for cancel.
        def dialog_closed():
            deadline = time.time() + 5
            while time.time() < deadline:
                if dialog.poll() is not None:
                    return {"exit_code": dialog.returncode}
                time.sleep(0.1)
            raise AssertionError("dialog process is still alive after the press")

        evidence["steps"].append(step("observe: dialog closed", dialog_closed))

        evidence["ok"] = True
        print(json.dumps(evidence, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001 - this is a gate, report everything
        evidence["ok"] = False
        evidence["error"] = f"{type(exc).__name__}: {exc}"
        print(json.dumps(evidence, ensure_ascii=False, indent=2), file=sys.stderr)
        return 1
    finally:
        if dialog.poll() is None:
            dialog.terminate()
            try:
                dialog.wait(timeout=2)
            except subprocess.TimeoutExpired:
                dialog.kill()


if __name__ == "__main__":
    sys.exit(main())
