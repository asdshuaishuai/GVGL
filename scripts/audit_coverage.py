#!/usr/bin/env python3
"""Data-completeness audit for a live GVGL frame.

`audit_geometry.py` checks whether the coordinates are *correct*. This one
checks whether the fields are *populated at all* — the failure mode that has
produced the worst bugs in this codebase, because it is invisible:

  - a client stuck on a stale view while the daemon says "no change"
  - an idle desktop manufacturing 6-7 version bumps per second
  - `Entity.actions` empty for all 4612 entities, because the code read the
    `AXActions` *attribute* (unsupported, -25205) instead of the Action API.
    The field existed, typed correctly, round-tripped through JSON, scored
    against in the query engine, and was always empty.

None of those produced a compile error, a test failure, or a log line. A field
that is structurally empty looks exactly like a field that is legitimately
empty until someone asks.

Usage: python3 scripts/audit_coverage.py [--socket ~/.gvgl/gvgl.sock]

Exit 0 when every hard invariant holds. Coverage gaps are reported as
warnings: they are the signal, not automatically the verdict.
"""
import json
import socket
import sys
from collections import Counter

DEFAULT_SOCKET = f"{__import__('os').path.expanduser('~')}/.gvgl/gvgl.sock"

# Roles a user can *press*. These must carry actions — a button with no
# action cannot be operated, and that is the defect this script exists for.
PRESS_ROLES = {
    "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton",
    "AXPopUpButton", "AXLink", "AXSwitch", "AXDisclosureTriangle",
    "AXTabButton", "AXSlider", "AXStepper", "AXIncrementor",
}

# Text-entry roles usually carry actions but are allowed not to: verified at
# the AX level — Terminal's AXTextArea returns success with an EMPTY action
# list. Treating these as a hard invariant produced a false alarm, which is how
# an audit gets ignored. Reported as coverage instead.
TEXT_ENTRY_ROLES = {
    "AXTextField", "AXTextArea", "AXSecureTextField", "AXComboBox",
}

# Fields that are legitimately sparse and would only add noise to the
# "0% populated" warning: they are set on a small, meaningful minority.
EXPECTED_SPARSE = {
    "focused",     # at most one element in the frame
    "selected",    # only inside selected lists
    "detail",      # accessibility help text
    "identifier",  # programmatic ids are uncommon
    "placeholder",
    "subrole",
    "windowID",    # only window-scoped elements
    "value",
    "title",
    "axParentID",
    "entityParentID",
    "zIndex",      # only window roots carry a z rank
}


def fetch(socket_path, method="get_frame", timeout=90):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(socket_path)
    s.sendall((json.dumps({"method": method}) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        buf += chunk
    s.close()
    if not buf:
        raise SystemExit("empty response from daemon")
    return json.loads(buf.decode().split("\n")[0])


def walk(node, out):
    if "role" in node:
        out.append(node)
    for child in node.get("children") or []:
        walk(child, out)


def populated(entity, key):
    """True when the key is present AND carries information. `false` for
    enabled/selected/focused is a real value, not a missing one."""
    if key not in entity:
        return False
    value = entity[key]
    if value is None:
        return False
    if isinstance(value, bool):
        return True          # a legitimate false is still a value
    if isinstance(value, str):
        return value != ""
    if isinstance(value, (list, dict)):
        return len(value) > 0
    return True


def main():
    socket_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SOCKET
    frame = fetch(socket_path)["result"]

    apps = frame["scene"]
    entities = []
    for app in apps:
        walk(app, entities)

    print(f"frame v{frame['version']} status={frame['status']} "
          f"apps={len(apps)} entities={len(entities)}")
    if not entities:
        print("\nno entities in frame — is the daemon still warming up, or is "
              "accessibility permission missing?")
        return 1

    failures = []
    warnings = []

    def must(cond, label, detail=""):
        if cond:
            print(f"  ok    {label}")
        else:
            print(f"  FAIL  {label}" + (f"  {detail}" if detail else ""))
            failures.append(label)

    # ---------------------------------------------------------------- hard
    print("\n[hard] pressable elements must be operable")

    pressable = [e for e in entities if e.get("role") in PRESS_ROLES]
    with_actions = [e for e in pressable if e.get("actions")]
    must(
        bool(pressable) and len(with_actions) == len(pressable),
        "every pressable entity has actions",
        f"{len(with_actions)}/{len(pressable)}",
    )
    if pressable and len(with_actions) < len(pressable):
        for e in [e for e in pressable if not e.get("actions")][:5]:
            print(f"          no actions: {e.get('role')} title={e.get('title')!r} "
                  f"app={e.get('appID')}")

    with_enabled = [e for e in pressable if "enabled" in e]
    must(len(with_enabled) == len(pressable),
         "every pressable entity reports enabled",
         f"{len(with_enabled)}/{len(pressable)}")

    print("\n[hard] capture completeness")
    # Non-zero means AX action calls errored: `actions` is incomplete for a
    # reason nobody can see from the frame alone. Omitted when zero, so this
    # is also a check that the diagnostic itself is not silently stuck.
    broken = [(a.get("appKey"), a["actionProbeFailures"]) for a in apps
              if (a.get("actionProbeFailures") or 0) > 0]
    must(not broken, "no app reported AX action-probe failures",
         f"{broken[:5]}")

    print("\n[hard] frame integrity")
    ids = Counter(e["id"] for e in entities)
    dupes = [i for i, n in ids.items() if n > 1]
    must(not dupes, "entity ids are unique", f"{len(dupes)} duplicates")

    missing_geom = [e for e in entities if "screen" not in (e.get("geometry") or {})]
    must(not missing_geom, "every entity has screen geometry",
         f"{len(missing_geom)} without")

    statuses = Counter(a.get("status") for a in apps)
    must(statuses.get("synced", 0) > 0,
         "at least one app is synced",
         f"statuses={dict(statuses)}")

    front = frame.get("frontmostApp")
    if front:
        must(front in {a.get("appKey") for a in apps},
             "frontmostApp is present in the scene", f"{front}")

    # ------------------------------------------------------------ coverage
    print("\n[coverage] field population (a 0% field is usually a bug, not a fact)")
    keys = sorted({k for e in entities for k in e})
    for key in keys:
        n = sum(1 for e in entities if populated(e, key))
        pct = 100.0 * n / len(entities)
        flag = ""
        if n == 0:
            if key in EXPECTED_SPARSE:
                flag = "  (expected sparse)"
            else:
                flag = "  <-- SUSPICIOUS: never populated"
                warnings.append(key)
        elif pct < 5 and key not in EXPECTED_SPARSE:
            flag = "  <-- very low"
        print(f"  {key:16s} {n:5d}/{len(entities):<5d} {pct:5.1f}%{flag}")

    # ------------------------------------------------------------- info
    print("\n[info] role distribution (top 12)")
    for role, n in Counter(e.get("role") for e in entities).most_common(12):
        print(f"  {role:22s} {n}")

    print("\n[info] text-entry roles (actions are a bonus, not required)")
    for role in sorted(TEXT_ENTRY_ROLES):
        group = [e for e in entities if e.get("role") == role]
        if not group:
            continue
        n = sum(1 for e in group if e.get("actions"))
        print(f"  {role:18s} {n}/{len(group)} have actions")

    print("\n[info] app status")
    for status, n in statuses.most_common():
        print(f"  {str(status):16s} {n}")

    print("\n[info] display distribution")
    for display, n in Counter(e.get("displayID") for e in entities).most_common():
        print(f"  displayID={display}: {n}")

    print()
    if failures:
        print(f"{len(failures)} HARD FAILURE(S): {', '.join(failures)}")
        return 1
    if warnings:
        print(f"all hard invariants hold, but {len(warnings)} field(s) never populated: "
              f"{', '.join(warnings)}")
        return 0
    print("all hard invariants hold; no unexplained empty fields")
    return 0


if __name__ == "__main__":
    sys.exit(main())
