#!/usr/bin/env python3
"""Gates for client/gvgl_act.py (the Python wrapper around gvglact).

1. A fake gvglact proves the wrapper forwards argv verbatim (socket first),
   parses the one-JSON-line result, and translates ok=false into ActError
   carrying the stable error code — including the malformed-output case.
2. If the real binary exists, `status` runs for real (needs no daemon: it
   reports AX trust and daemon availability).

Exit 0 = all gates pass.
"""
import json
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "client"))
from gvgl_act import ActClient, ActError  # noqa: E402

failures: list[str] = []


def check(name: str, cond: bool, detail: str = "") -> None:
    print(f"  {'✓' if cond else '✗'} {name}" + (f" — {detail}" if detail and not cond else ""))
    if not cond:
        failures.append(name)


def fake_executable(directory: pathlib.Path, name: str, body: str) -> pathlib.Path:
    fake = directory / name
    fake.write_text(body)
    fake.chmod(0o755)
    return fake


with tempfile.TemporaryDirectory() as td:
    td = pathlib.Path(td)
    argv_file = td / "argv.txt"

    ok_fake = fake_executable(
        td, "ok-fake",
        "#!/bin/sh\n"
        f'printf \'%s\\n\' "$@" > "{argv_file}"\n'
        "echo '{\"ok\":true,\"action\":\"press\",\"method\":\"ax_press\","
        "\"changed\":true,\"verified\":true,\"latencyMS\":12}'\n",
    )
    err_fake = fake_executable(
        td, "err-fake",
        "#!/bin/sh\necho '{\"ok\":false,\"error\":{\"code\":\"target_obscured\","
        "\"message\":\"另一元素覆盖落点\"}}'\n",
    )
    junk_fake = fake_executable(td, "junk-fake", "#!/bin/sh\necho 'this is not json'\n")

    client = ActClient(executable=str(ok_fake), socket="/tmp/fake.sock")
    result = client.press("pid:1:0-2")
    check("parses an ok result", result["ok"] is True and result["method"] == "ax_press")

    forwarded = argv_file.read_text().split()
    check(
        "forwards socket, isolation mode and verb verbatim",
        forwarded == ["--socket", "/tmp/fake.sock", "--mode", "background",
                      "press", "--id", "pid:1:0-2"],
        str(forwarded),
    )

    try:
        ActClient(executable=str(err_fake)).press("pid:1:0-2")
        check("ok=false raises ActError", False, "no exception")
    except ActError as exc:
        check(
            "ok=false raises ActError with the stable code",
            exc.code == "target_obscured" and "覆盖" in exc.message,
            f"{exc.code} {exc.message}",
        )

    try:
        ActClient(executable=str(junk_fake)).press("pid:1:0-2")
        check("non-JSON output raises ActError", False, "no exception")
    except ActError as exc:
        check("non-JSON output maps to malformed_response", exc.code == "malformed_response",
              exc.code)

# Real binary: status needs neither daemon nor a desktop change.
real = ROOT / ".build" / "release" / "gvglact"
if real.exists():
    status = ActClient(executable=str(real), socket="/tmp/definitely-not-a-socket.sock").status()
    check(
        "real gvglact status reports AX trust",
        status["ok"] is True and status["data"]["ax_trusted"] is True,
        str(status),
    )
    try:
        ActClient(executable=str(real)).press()
        check("press without a target fails loudly", False, "no exception")
    except ActError as exc:
        check(
            "press without a target surfaces gvglact's usage error",
            "gvglact" in exc.message,
            exc.message,
        )
else:
    print("  (real binary not built — skipped real-binary gates)")

if failures:
    print(f"\n{failures} gate(s) failed")
    sys.exit(1)
print("\n✓ gvgl_act.py wrapper gates passed")
