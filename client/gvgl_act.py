#!/usr/bin/env python3
"""gvglact 的 Python 封装：让 Python agent 也能执行 computer-use 动作。

逻辑全部在 gvglact（Swift）里——解析、校验、命中测试、回读验证、安全护栏
都是同一份实现；这里只做参数拼装、NDJSON 解析和错误码翻译，避免第二份
评分/动作实现（评分那一份已经用 Tests/Fixtures/query_vectors.json 钉住，
动作不应再造第二个）。

感知仍在 gvgl_query.py（帧/地图/查询）；本模块只负责"做"。

用法（与 gvglact 动词一一对应）：

    python3 client/gvgl_act.py status
    python3 client/gvgl_act.py transcript --app pid:123
    python3 client/gvgl_act.py press   --id pid:123:0-2
    python3 client/gvgl_act.py click   --id pid:123:0-2 [--button right] [--count 2]
    python3 client/gvgl_act.py type    --id pid:123:0-1 --text "你好"
    python3 client/gvgl_act.py key     --chord "cmd+s" [--app pid:123]
    python3 client/gvgl_act.py scroll  --id pid:123:0-5 --down 5
    python3 client/gvgl_act.py drag    --from pid:1:0-2 --to pid:1:0-3
    python3 client/gvgl_act.py menu    --app pid:123 --path "文件/新建窗口"
    python3 client/gvgl_act.py focus   --id pid:123:0-1
    python3 client/gvgl_act.py set     --id pid:123:0-1 --value "文本"
    python3 client/gvgl_act.py app     activate com.apple.finder
    python3 client/gvgl_act.py wait    --since 120 --timeout 3
    python3 client/gvgl_act.py clipboard get|set --text ...

库用法：

    from gvgl_act import ActClient
    client = ActClient(socket="/tmp/gvgl.sock")
    result = client.press("pid:123:0-2")          # dict，含 method/changed/verified
    result = client.type(text="登录", target="pid:123:0-1")
    result = client.press(role="AXButton", label="登录")   # 先查后按

输出恒为单行 JSON；失败抛 ActError（含稳定 error code），退出码 1。
"""
import argparse
import json
import os
import shutil
import subprocess
import sys

DEFAULT_SOCKET = os.environ.get("GVGL_SOCKET", os.path.expanduser("~/.gvgl/gvgl.sock"))


class ActError(RuntimeError):
    """gvglact 返回 ok=false。code 是稳定契约（见 DESIGN.md V6-5）。"""

    def __init__(self, payload):
        err = payload.get("error") or {}
        self.code = err.get("code", "unknown")
        self.message = err.get("message", "")
        self.action = payload.get("action", "?")
        super().__init__(f"{self.action}: {self.code} — {self.message}")


def find_executable() -> str:
    exe = os.environ.get("GVGLACT")
    if exe and os.access(exe, os.X_OK):
        return exe
    here = os.path.dirname(os.path.abspath(__file__))
    for candidate in (
        os.path.join(here, "..", ".build", "release", "gvglact"),
        shutil.which("gvglact"),
    ):
        if candidate and os.access(candidate, os.X_OK):
            return candidate
    raise FileNotFoundError("gvglact 未找到：先 `swift build -c release`，或用 GVGLACT 指定路径")


class ActClient:
    """Thin wrapper: builds argv, runs gvglact, parses the one JSON line."""

    def __init__(self, executable: str | None = None, socket: str | None = None,
                 timeout: float = 30.0):
        self.executable = executable or find_executable()
        self.socket = socket or DEFAULT_SOCKET
        self.timeout = timeout

    def run(self, *args) -> dict:
        argv = [self.executable, "--socket", self.socket, *args]
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=self.timeout)
        out = proc.stdout.strip()
        if not out:
            raise ActError({
                "action": "run",
                "error": {"code": "internal_error",
                          "message": proc.stderr.strip() or "gvglact produced no output"},
            })
        try:
            payload = json.loads(out.splitlines()[-1])
        except json.JSONDecodeError as exc:
            raise ActError({
                "action": "run",
                "error": {"code": "malformed_response",
                          "message": f"gvglact output is not JSON: {out[:200]}"},
            }) from exc
        if not payload.get("ok"):
            raise ActError(payload)
        return payload

    # -- helpers ------------------------------------------------------------

    @staticmethod
    def _query(q: dict) -> list[str]:
        args = []
        for key, flag in (("role", "--role"), ("label", "--label"), ("region", "--region"),
                          ("app", "--app"), ("display", "--display"),
                          ("reference", "--reference"), ("relation", "--relation"),
                          ("top", "--top")):
            if q.get(key) is not None:
                args += [flag, str(q[key])]
        return args

    def _act(self, verb: str, target: str | None, q: dict, extra: tuple = ()) -> dict:
        args = [verb]
        if target:
            args += ["--id", target]
        else:
            args += self._query(q)
        return self.run(*args, *extra)

    # -- perception (read-only; no accessibility permission needed) ---------

    def status(self) -> dict:
        return self.run("status")

    def find(self, **q) -> dict:
        return self.run("find", *self._query(q))

    def transcript(self, app: str | None = None, window: str | None = None,
                   max_chars: int = 20000) -> dict:
        args = ["transcript", "--max", str(max_chars)]
        if app:
            args += ["--app", str(app)]
        if window:
            args += ["--window", str(window)]
        return self.run(*args)

    def read_text(self, target: str, max_chars: int = 8000) -> dict:
        return self.run("text", "--id", target, "--max", str(max_chars))

    # -- actions (need accessibility permission in THIS process) ------------

    def press(self, target: str | None = None, **q) -> dict:
        return self._act("press", target, q)

    def click(self, target: str | None = None, button: str = "left", count: int = 1,
              **q) -> dict:
        return self._act("click", target, q, ("--button", button, "--count", str(count)))

    def type(self, text: str, target: str | None = None, method: str = "auto",
             submit: bool = False, **q) -> dict:
        extra = ("--text", text, "--method", method)
        if submit:
            extra += ("--submit",)
        return self._act("type", target, q, extra)

    def key(self, chord: str, target: str | None = None, app: str | None = None) -> dict:
        args = ["key", "--chord", chord]
        if target:
            args += ["--id", target]
        if app:
            args += ["--app", app]
        return self.run(*args)

    def scroll(self, target: str | None = None, lines: int | None = None,
               to: str | None = None, **q) -> dict:
        extra = []
        if lines is not None:
            extra += ("--down" if lines < 0 else "--up", str(abs(lines)))
        if to:
            extra += ("--to", to)
        return self._act("scroll", target, q, extra)

    def drag(self, from_id: str, to_id: str) -> dict:
        return self.run("drag", "--from", from_id, "--to", to_id)

    def menu(self, app_key: str, path: str) -> dict:
        return self.run("menu", "--app", app_key, "--path", path)

    def focus(self, target: str | None = None, **q) -> dict:
        return self._act("focus", target, q)

    def set_value(self, target: str, value: str) -> dict:
        return self.run("set", "--id", target, "--value", value)

    def wait(self, since: int | None = None, timeout: float = 5.0) -> dict:
        args = ["wait", "--timeout", str(timeout)]
        if since is not None:
            args += ["--since", str(since)]
        return self.run(*args)

    def set_value(self, target: str, value: str) -> dict:
        return self.run("set", "--id", target, "--value", value)

    def app_action(self, verb: str, target: str | None = None) -> dict:
        args = ["app", verb]
        if target:
            args.append(target)
        return self.run(*args)

    def clipboard(self, verb: str, text: str | None = None) -> dict:
        args = ["clipboard", verb]
        if text is not None:
            args += ["--text", text]
        return self.run(*args)


# -- CLI --------------------------------------------------------------------

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="gvgl_act.py",
        description="gvglact 的 Python 封装：感知 + 动作，全程零截图。")
    p.add_argument("--socket", default=DEFAULT_SOCKET)
    p.add_argument("--executable", default=None, help="gvglact 路径（默认自动查找）")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("status")

    p_transcript = sub.add_parser("transcript")
    p_transcript.add_argument("--app")
    p_transcript.add_argument("--window")
    p_transcript.add_argument("--max", type=int, default=20000)

    p_find = sub.add_parser("find")
    for sp in (p_find,):
        sp.add_argument("--role")
        sp.add_argument("--label")
        sp.add_argument("--region")
        sp.add_argument("--app")
        sp.add_argument("--display", type=int)
        sp.add_argument("--reference")
        sp.add_argument("--relation")
        sp.add_argument("--top", type=int)

    p_text = sub.add_parser("text")
    p_text.add_argument("--id", required=True)
    p_text.add_argument("--max", type=int, default=8000)

    def action_parser(name):
        sp = sub.add_parser(name)
        sp.add_argument("--id")
        sp.add_argument("--role")
        sp.add_argument("--label")
        sp.add_argument("--app")
        return sp

    action_parser("press")
    p_click = action_parser("click")
    p_click.add_argument("--button", default="left")
    p_click.add_argument("--count", type=int, default=1)
    p_scroll = action_parser("scroll")
    p_scroll.add_argument("--up", type=int)
    p_scroll.add_argument("--down", type=int)
    p_scroll.add_argument("--to")
    action_parser("focus")

    p_type = action_parser("type")
    p_type.add_argument("--text", required=True)
    p_type.add_argument("--method", default=None)
    p_type.add_argument("--submit", action="store_true")

    p_key = sub.add_parser("key")
    p_key.add_argument("--chord", required=True)
    p_key.add_argument("--id")
    p_key.add_argument("--app")

    p_drag = sub.add_parser("drag")
    p_drag.add_argument("--from", dest="from_id", required=True)
    p_drag.add_argument("--to", dest="to_id", required=True)

    p_menu = sub.add_parser("menu")
    p_menu.add_argument("--app", required=True)
    p_menu.add_argument("--path", required=True)

    p_set = action_parser("set")
    p_set.add_argument("--value", required=True)

    p_app = sub.add_parser("app")
    p_app.add_argument("verb", choices=["activate", "launch", "list"])
    p_app.add_argument("target", nargs="?")

    p_wait = sub.add_parser("wait")
    p_wait.add_argument("--since", type=int)
    p_wait.add_argument("--timeout", type=float, default=5.0)

    p_clip = sub.add_parser("clipboard")
    p_clip.add_argument("verb", choices=["get", "set"])
    p_clip.add_argument("--text")
    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    client = ActClient(executable=args.executable, socket=args.socket)
    try:
        if args.command == "status":
            payload = client.status()
        elif args.command == "find":
            payload = client.find(
                role=args.role, label=args.label, region=args.region, app=args.app,
                display=args.display, reference=args.reference, relation=args.relation,
                top=args.top)
        elif args.command == "transcript":
            payload = client.transcript(app=args.app, window=args.window,
                                        max_chars=args.max)
        elif args.command == "text":
            payload = client.read_text(args.id, max_chars=args.max)
        elif args.command == "press":
            payload = client.press(args.id, role=args.role, label=args.label, app=args.app)
        elif args.command == "click":
            payload = client.click(args.id, button=args.button, count=int(args.count or 1),
                                   role=args.role, label=args.label, app=args.app)
        elif args.command == "type":
            payload = client.type(args.text, target=args.id, method=args.method or "auto",
                                  submit=args.submit, role=args.role, label=args.label,
                                  app=args.app)
        elif args.command == "key":
            payload = client.key(args.chord, target=args.id, app=args.app)
        elif args.command == "scroll":
            lines = None
            if args.up is not None:
                lines = int(args.up)
            elif args.down is not None:
                lines = -int(args.down)
            payload = client.scroll(args.id, lines=lines, to=args.to,
                                    role=args.role, label=args.label, app=args.app)
        elif args.command == "focus":
            payload = client.focus(args.id, role=args.role, label=args.label, app=args.app)
        elif args.command == "drag":
            payload = client.drag(args.from_id, args.to_id)
        elif args.command == "menu":
            payload = client.menu(args.app, args.path)
        elif args.command == "set":
            payload = client.set_value(args.id, args.value)
        elif args.command == "app":
            payload = client.app_action(args.verb, args.target)
        elif args.command == "wait":
            payload = client.wait(since=args.since, timeout=args.timeout or 5.0)
        elif args.command == "clipboard":
            payload = client.clipboard(args.verb, text=args.text)
        else:  # pragma: no cover - argparse enforces subcommands
            raise SystemExit(2)
    except ActError as exc:
        print(json.dumps({"ok": False, "error": {"code": exc.code, "message": exc.message}}),
              file=sys.stderr)
        return 1
    print(json.dumps(payload, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
