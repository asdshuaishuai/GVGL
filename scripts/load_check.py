#!/usr/bin/env python3
"""Load / robustness check for a live GVGL daemon.

Unit tests pin behaviour, but they never opened more than a handful of
connections at once. That is how a daemon can ship a real availability bug
with a fully green suite: the push loop used to block on the same concurrent
queue that served requests, so ~63 long-lived subscriptions silently starved
the whole server (no error, no log, no longer answering anything). This
script reproduces that class of failure against a running daemon.

Checks:
  1. baseline       — one-shot request latency
  2. many subscribers— N concurrent subscriptions must NOT stop the server
  3. admission cap  — past the cap the daemon must refuse LOUDLY, not wedge
  4. slot release   — closing subscribers must return their slots
  5. churn          — repeated connect/disconnect must not leak fds or threads
  6. abandoned      — half-sent requests must not wedge or leak

Usage:
  .build/debug/gvgl --socket /tmp/gvgl-load.sock &
  python3 scripts/load_check.py --socket /tmp/gvgl-load.sock [--subscribers 100]

Exit code 0 = all checks passed.
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time

DEFAULT_SOCKET = f"{os.path.expanduser('~')}/.gvgl/gvgl.sock"
CONNECT_ATTEMPTS = 200
CONNECT_BACKOFF_S = 0.01
# The server notices a vanished subscriber when it next writes to that socket.
# On a quiet desktop that is the ~60s ping cadence, so resource checks have to
# wait at least that long or they measure a snapshot taken mid-reap.
REAP_WAIT_S = 75


class Failure(Exception):
    pass


class Client:
    def __init__(self, path, timeout=25.0):
        self.path = path
        self.timeout = timeout

    def connect(self):
        """`listen()` backlog is small (16), so a burst of connects can
        transiently exceed it. Retry briefly: the accept loop drains it, and a
        load test that dies on EAGAIN would misreport the server."""
        for _ in range(CONNECT_ATTEMPTS):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(self.timeout)
            try:
                s.connect(self.path)
                return s
            except socket.timeout:
                # The daemon accepted the connection but never answered — the
                # signature of a starved server, not a backlog hiccup.
                s.close()
                raise Failure("connect timed out: server is not accepting "
                              "(this is what starvation looks like)")
            except OSError:
                s.close()
                time.sleep(CONNECT_BACKOFF_S)
        raise Failure("cannot connect to daemon")

    def _read_line(self, s, what):
        buf = b""
        try:
            while b"\n" not in buf:
                chunk = s.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        except socket.timeout:
            raise Failure(f"timed out waiting for {what}")
        if not buf:
            raise Failure(f"connection closed before {what}")
        return buf.decode(errors="replace")

    def request(self, req):
        s = self.connect()
        try:
            s.sendall((json.dumps(req) + "\n").encode())
            return json.loads(self._read_line(s, req.get("method", "response")))
        finally:
            s.close()

    def subscribe(self, since=None, regions=None):
        """Returns (socket, ack_text). The socket is left open — the caller
        owns the subscription and must close it."""
        s = self.connect()
        req = {"method": "subscribe"}
        if since is not None:
            req["since"] = since
        if regions:
            req["regions"] = regions
        s.sendall((json.dumps(req) + "\n").encode())
        s.settimeout(self.timeout)
        try:
            return s, self._read_line(s, "subscribe ack")
        except Failure:
            s.close()   # never leak the socket when the ack never arrives
            raise


def daemon_pid(socket_path):
    try:
        out = subprocess.run(["pgrep", "-f", f"gvgl --socket {socket_path}"],
                             capture_output=True, text=True, timeout=5)
        return out.stdout.strip().split("\n")[0] or None
    except Exception:  # noqa: BLE001
        return None


def resources(pid):
    if not pid:
        return None
    try:
        fds = int(subprocess.run(["lsof", "-p", pid], capture_output=True,
                                text=True, timeout=20).stdout.count("\n"))
        rss = int(subprocess.run(["ps", "-o", "rss=", "-p", pid],
                                 capture_output=True, text=True,
                                 timeout=10).stdout.strip() or 0)
        threads = int(subprocess.run(["ps", "-M", pid], capture_output=True,
                                     text=True, timeout=10).stdout.count("\n"))
        return {"fds": fds, "rss_kb": rss, "threads": threads}
    except Exception:  # noqa: BLE001
        return None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--socket", default=DEFAULT_SOCKET)
    ap.add_argument("--subscribers", type=int, default=100,
                    help="concurrent subscriptions for the starvation check")
    ap.add_argument("--cap", type=int, default=256,
                    help="expected admission cap; the daemon must refuse at or below this")
    ap.add_argument("--churn", type=int, default=300,
                    help="connect/disconnect cycles for the leak check")
    args = ap.parse_args()

    c = Client(args.socket)
    pid = daemon_pid(args.socket)
    failures = []

    def check(name, fn):
        try:
            detail = fn()
            print(f"PASS  {name}" + (f"  [{detail}]" if detail else ""))
        except Failure as exc:
            print(f"FAIL  {name}: {exc}")
            failures.append(name)

    def alive():
        r = c.request({"method": "get_status"})["result"]
        if "monitoredApps" not in r:
            raise Failure(f"unexpected status payload: {r}")
        return f"{r['monitoredApps']} apps, v{r['version']}"

    def baseline():
        t = time.time()
        alive()
        return f"{time.time() - t:.3f}s"

    def many_subscribers():
        held = []
        try:
            for _ in range(args.subscribers):
                s, ack = c.subscribe()
                if "subscribed" not in ack:
                    raise Failure(f"no ack: {ack.strip()[:120]}")
                held.append(s)
            # The real assertion: the daemon is alive and serving, with every
            # subscription parked. A starved daemon is still "running".
            t = time.time()
            alive()
            return f"{len(held)} subscriptions, still answering in {time.time() - t:.3f}s"
        finally:
            for s in held:
                s.close()

    def admission_cap():
        held, refused = [], 0
        try:
            for _ in range(args.cap + 40):
                try:
                    s, ack = c.subscribe()
                except Failure:
                    break
                if "too_many_subscriptions" in ack:
                    refused += 1
                    s.close()
                    if refused >= 1 and len(held) >= args.cap:
                        break
                else:
                    held.append(s)
            if refused == 0:
                raise Failure(f"no refusal after {len(held)} subscriptions")
            alive()  # must still serve
            return f"accepted {len(held)}, refused {refused} loudly, still serving"
        finally:
            for s in held:
                s.close()

    def slot_release():
        held = []
        for _ in range(args.cap):
            s, ack = c.subscribe()
            if "too_many_subscriptions" in ack:
                s.close()
                break
            held.append(s)
        for s in held:
            s.close()
        time.sleep(7)  # push loops notice the drop on their next tick
        again, refused = 0, 0
        for _ in range(args.cap):
            s, ack = c.subscribe()
            if "too_many_subscriptions" in ack:
                refused += 1
                s.close()
            else:
                again += 1
                s.close()
        if again < args.cap:
            raise Failure(f"slots leaked: only {again}/{args.cap} re-accepted "
                          f"({refused} refused after full release)")
        return f"full capacity re-accepted ({again}) after release"

    def churn():
        before = resources(pid)
        for i in range(args.churn):
            s, _ack = c.subscribe()
            s.close()  # disconnect immediately after ack
            if i % 50 == 0:
                alive()
        # Must outlast the dead-client reaping path, or this measures a
        # mid-reap snapshot and would pass even with a real fd leak. A dead
        # subscriber is only noticed when the server next writes to it, and on
        # a quiet desktop that is the ~60s ping cadence — not version churn,
        # which the daemon no longer manufactures on an idle desktop.
        time.sleep(REAP_WAIT_S)
        after = resources(pid)
        if not before or not after:
            return "pid unknown, skipped resource check"
        dfd = after["fds"] - before["fds"]
        dthr = after["threads"] - before["threads"]
        if dfd > 8:
            raise Failure(f"fd leak: {before['fds']} -> {after['fds']} over {args.churn} cycles "
                          f"(waited {REAP_WAIT_S}s for reaping)")
        if dthr > 8:
            raise Failure(f"thread leak: {before['threads']} -> {after['threads']}")
        return (f"{args.churn} cycles, fds {before['fds']}->{after['fds']}, "
                f"threads {before['threads']}->{after['threads']}")

    def abandoned():
        held = []
        try:
            for _ in range(50):
                s = c.connect()
                s.sendall(b'{"method":"get_sta')  # never terminated
                held.append(s)
            time.sleep(8)  # server read timeout is 5s
            alive()
            return "50 half-sent requests, still serving"
        finally:
            for s in held:
                s.close()

    print(f"daemon pid={pid or 'unknown'} socket={args.socket}\n")
    check("baseline", baseline)
    check("many concurrent subscribers do not starve server", many_subscribers)
    check("overload is refused loudly", admission_cap)
    check("slots released on disconnect", slot_release)
    check("churn leaks nothing", churn)
    check("abandoned requests are survivable", abandoned)

    print()
    if failures:
        print(f"{len(failures)} FAILED: {', '.join(failures)}")
        return 1
    print("all load checks passed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Failure as exc:
        print(f"FAIL  {exc}")
        sys.exit(1)
