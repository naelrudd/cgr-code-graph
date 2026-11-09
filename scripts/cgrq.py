#!/usr/bin/env python3
"""cgrq - warm client for cgr's MCP tools, for sessions where the MCP server
is not registered as tools (no /reload-mcp available).

The expensive part of `semantic_search` is loading the local embedding model
(30-70 s cold). Deterministic graph queries cost ~2 s cold because the CLI
already starts fast. So:

  cgrq.py serve            # keep one cgr mcp-server warm, proxy it over TCP
  cgrq.py stop             # shut it down
  cgrq.py status           # is it up, and which workspace
  cgrq.py tool NAME JSON   # call any MCP tool, print its text result
  cgrq.py search "query" -p PROJECT
  cgrq.py find "query" -p PROJECT [-k 3] [-l 3]   # hits + head of each body
  cgrq.py stale            # which projects moved since their last sync
  cgrq.py ctx "target" -p PROJECT [--budget N]

Daemon state lives in %LOCALAPPDATA%\\cgrq\\. Client and daemon speak
line-delimited JSON-RPC 2.0 over 127.0.0.1, bound to loopback only.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

HOST = "127.0.0.1"
PORT = int(os.environ.get("CGRQ_PORT", "20140"))
STATE = Path(os.environ.get("LOCALAPPDATA", str(Path.home()))) / "cgrq"
PIDFILE = STATE / "daemon.json"
LOG = STATE / "daemon.log"
CGR = os.environ.get("CGR_EXE") or str(Path.home() / ".local" / "bin" / "cgr.exe")
if not Path(CGR).exists():
    CGR = "cgr"


def _log(msg: str) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    with LOG.open("a", encoding="utf-8") as fh:
        fh.write(f"{time.strftime('%H:%M:%S')} {msg}\n")


# ---------------------------------------------------------------- daemon side
class Upstream:
    """One long-lived `cgr mcp-server` child, JSON-RPC over its stdin/stdout."""

    def __init__(self, workspace: str, read_only: bool) -> None:
        args = [CGR, "mcp-server", "--workspace", workspace]
        if read_only:
            args.insert(2, "--read-only")
        env = dict(os.environ)
        env.setdefault("TARGET_REPO_PATH", os.environ.get("CGR_TARGET", "D:/money"))
        self.proc = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            text=True,
            bufsize=1,
            encoding="utf-8",
            errors="replace",
        )
        self.lock = threading.Lock()
        self.waiters: dict[str, "queue.Queue"] = {}
        self.next_id = 0
        threading.Thread(target=self._reader, daemon=True).start()
        self.call("initialize", {
            "protocolVersion": "2024-11-05",
            "capabilities": {},
            "clientInfo": {"name": "cgrq", "version": "1"},
        }, timeout=180)
        self._notify("notifications/initialized", {})

    def _reader(self) -> None:
        for line in self.proc.stdout:  # type: ignore[union-attr]
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            key = msg.get("id")
            if key is None:
                continue
            q = self.waiters.get(str(key))
            if q is not None:
                q.put(msg)

    def _write(self, payload: dict) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(payload) + "\n")
        self.proc.stdin.flush()

    def _notify(self, method: str, params: dict) -> None:
        with self.lock:
            self._write({"jsonrpc": "2.0", "method": method, "params": params})

    def call(self, method: str, params: dict, timeout: float = 600.0) -> dict:
        import queue as _q

        box: _q.Queue = _q.Queue()
        with self.lock:
            self.next_id += 1
            rid = str(self.next_id)
            self.waiters[rid] = box
            self._write({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        try:
            return box.get(timeout=timeout)
        except _q.Empty:
            return {"error": {"message": f"upstream timeout after {timeout}s"}}


def serve(workspace: str, read_only: bool) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    up = Upstream(workspace, read_only)
    _log(f"upstream ready workspace={workspace} read_only={read_only}")
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(8)
    PIDFILE.write_text(json.dumps({
        "pid": os.getpid(), "port": PORT, "workspace": workspace,
        "read_only": read_only, "started": time.time(),
    }), encoding="utf-8")

    def handle(conn: socket.socket) -> None:
        with conn:
            conn.settimeout(900)
            buf = b""
            while True:
                try:
                    chunk = conn.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                buf += chunk
                while b"\n" in buf:
                    raw, buf = buf.split(b"\n", 1)
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        req = json.loads(raw)
                    except Exception:
                        conn.sendall(b'{"error":"bad json"}\n')
                        continue
                    t0 = time.time()
                    resp = up.call(
                        req.get("method", "tools/call"),
                        req.get("params", {}),
                        timeout=float(req.get("timeout", 600)),
                    )
                    resp["id"] = req.get("id", 1)
                    conn.sendall((json.dumps(resp) + "\n").encode("utf-8"))
                    _log(f"{req.get('params', {}).get('name', req.get('method'))} "
                         f"{time.time() - t0:.1f}s")

    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


def stop() -> int:
    if not PIDFILE.exists():
        print("cgrq: not running")
        return 1
    info = json.loads(PIDFILE.read_text(encoding="utf-8"))
    pid = int(info.get("pid", 0))
    try:
        os.kill(pid, 15)
        print(f"cgrq: stopped pid {pid}")
    except Exception as exc:
        print(f"cgrq: pid {pid} already gone ({exc})")
    PIDFILE.unlink(missing_ok=True)
    return 0


def status() -> int:
    if not PIDFILE.exists():
        print("cgrq: not running")
        return 1
    info = json.loads(PIDFILE.read_text(encoding="utf-8"))
    up = _probe()
    print(json.dumps({**info, "answering": up}, indent=2))
    return 0 if up else 1


# ---------------------------------------------------------------- client side
def _probe(timeout: float = 3.0) -> bool:
    try:
        with socket.create_connection((HOST, PORT), timeout=timeout):
            return True
    except OSError:
        return False


def _ensure_daemon(workspace: str, read_only: bool) -> None:
    if _probe():
        info = json.loads(PIDFILE.read_text(encoding="utf-8")) if PIDFILE.exists() else {}
        if info.get("workspace") != workspace:
            raise SystemExit(
                f"cgrq: daemon serves workspace '{info.get('workspace')}', "
                f"not '{workspace}'. Run: cgrq.py stop && cgrq.py serve --workspace {workspace}"
            )
        return
    starter = [sys.executable, str(Path(__file__).resolve())]
    with open(os.devnull, "wb") as null:
        subprocess.Popen(
            starter + ["serve", "--workspace", workspace] + (["--read-only"] if read_only else []),
            stdout=null, stderr=null, stdin=subprocess.DEVNULL,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
    for _ in range(180):
        if _probe():
            return
        time.sleep(1)
    raise SystemExit("cgrq: daemon did not answer within 180 s; see " + str(LOG))


def _rpc(method: str, params: dict, timeout: float = 600) -> dict:
    req = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params, "timeout": timeout}
    with socket.create_connection((HOST, PORT), timeout=timeout + 30) as sock:
        sock.sendall((json.dumps(req) + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = sock.recv(65536)
            if not chunk:
                break
            buf += chunk
    if not buf.strip():
        return {"error": {"message": "empty response from daemon"}}
    return json.loads(buf.split(b"\n", 1)[0])


def _emit(resp: dict) -> int:
    if "error" in resp:
        print(f"ERROR: {json.dumps(resp['error'])[:600]}", file=sys.stderr)
        return 2
    result = resp.get("result", {})
    for item in result.get("content", []):
        text = item.get("text", "")
        try:
            print(json.dumps(json.loads(text), indent=2, ensure_ascii=False))
        except Exception:
            print(text)
    if result.get("isError"):
        return 2
    return 0


_HIT = re.compile(r"^\s*\d+\.\s+(?P<qn>\S.*?)\s+\(type:\s*(?P<label>[^,]+),\s*score:\s*(?P<score>[0-9.]+)\)\s*$")


def _text_of(resp: dict) -> str:
    out = []
    for item in resp.get("result", {}).get("content", []):
        out.append(item.get("text", ""))
    return "\n".join(out)


def _parse_hits(text: str, limit: int) -> list[tuple[str, str, float]]:
    hits = []
    for line in text.splitlines():
        m = _HIT.match(line)
        if m:
            hits.append((m.group("qn"), m.group("label"), float(m.group("score"))))
        if len(hits) >= limit:
            break
    return hits


def cmd_find(query: str, project: str | None, limit: int, lines: int) -> int:
    """One round trip replaced by one: search, then the head of each body.

    `semantic_search` alone returns 5 qualified names and no source, so an agent
    pays a second call per hit before it can rule anything out. This prints
    `path:span score` plus the first `lines` source lines, which is enough to
    accept or reject a hit without another call.
    """
    args: dict = {"natural_language_query": query}
    if project:
        args["project"] = project
    hits = _parse_hits(_text_of(_rpc("tools/call", {"name": "semantic_search", "arguments": args})), limit)
    if not hits:
        print(f"no semantic matches for: {query}")
        return 1
    for i, (qn, label, score) in enumerate(hits, 1):
        d_args: dict = {"qualified_name": qn}
        if project:
            d_args["project"] = project
        resp = _rpc("tools/call", {"name": "definition", "arguments": d_args})
        try:
            d = json.loads(_text_of(resp))
        except Exception:
            d = {}
        path, start, end = d.get("path"), d.get("start_line"), d.get("end_line")
        source = d.get("source") or ""
        span = f"{path}:{start}-{end}" if path and start else (path or "?")
        print(f"{i}. {qn}")
        print(f"   {span}  [{label} {score:.3f}]")
        head = source.splitlines()[:lines]
        for ln in head:
            print(f"   | {ln.rstrip()}")
    return 0


def cmd_stale() -> int:
    """Which repos moved since their last sync — the graph's honest expiry date.

    A semantic hit from a two-day-old graph is indistinguishable from a fresh one,
    so an agent cannot tell when to distrust it and falls back to grep. This reads
    each repo's last commit and compares it with the per-project hash-cache mtime.
    Exit 1 when anything is stale, so a shell can gate on it.
    """
    home = Path(os.environ.get("CGR_HOME", str(Path.home() / ".cgr")))
    ws_files = sorted((home / "workspaces").glob("*.toml"))
    if not ws_files:
        print(f"cgrq: no workspace under {home / 'workspaces'}")
        return 2
    stale = 0
    total = 0
    for toml in ws_files:
        print(f"workspace {toml.stem}")
        path = name = None
        for line in toml.read_text(encoding="utf-8").splitlines():
            s = line.strip()
            if s == "[[workspace.repos]]":
                path = name = None
            elif s.startswith("path"):
                path = s.split("=", 1)[1].strip().strip('"').replace("\\\\", "/")
            elif s.split("=", 1)[0].strip() == "project_name":
                name = s.split("=", 1)[1].strip().strip('"')
                if not path or not name:
                    continue
                total += 1
                cache = home / "state" / name / ".cgr-hash-cache.json"
                if not cache.exists():
                    print(f"  {name:<30} never synced")
                    stale += 1
                    continue
                synced = cache.stat().st_mtime
                try:
                    out = subprocess.run(
                        ["git", "-C", path, "log", "-1", "--format=%ct"],
                        capture_output=True, text=True, timeout=20,
                    )
                    commit = float(out.stdout.strip() or 0)
                except Exception:
                    commit = 0.0
                if commit > synced:
                    when = time.strftime("%m-%d %H:%M", time.localtime(commit))
                    print(f"  {name:<30} STALE (commit {when} > sync "
                          f"{time.strftime('%m-%d %H:%M', time.localtime(synced))})")
                    stale += 1
                elif os.environ.get("CGRQ_VERBOSE"):
                    print(f"  {name:<30} fresh")
    print(f"\n{stale}/{total} project(s) behind their repo; "
          f"refresh with: bash scripts/index.sh <workspace>")
    return 1 if stale else 0


def main() -> int:
    ap = argparse.ArgumentParser(prog="cgrq")
    ap.add_argument("command")
    ap.add_argument("payload", nargs="?")
    ap.add_argument("jsonargs", nargs="?")
    ap.add_argument("-p", "--project")
    ap.add_argument("-w", "--workspace", default=os.environ.get("CGR_WORKSPACE", "money"))
    ap.add_argument("--budget", type=int, default=1500)
    ap.add_argument("-k", "--limit", type=int, default=3)
    ap.add_argument("-l", "--lines", type=int, default=3)
    ap.add_argument("--read-only", action="store_true", default=True)
    ap.add_argument("--with-writer", dest="read_only", action="store_false")
    ap.add_argument("--timeout", type=float, default=600)
    a = ap.parse_args()

    if a.command == "serve":
        serve(a.workspace, a.read_only)
        return 0
    if a.command == "stop":
        return stop()
    if a.command == "status":
        return status()
    if a.command in ("stale", "fresh"):
        return cmd_stale()
    if a.command == "find":
        if not a.payload:
            raise SystemExit("usage: cgrq.py find \"query\" -p <project> [-k 3] [-l 3]")
        _ensure_daemon(a.workspace, a.read_only)
        return cmd_find(a.payload, a.project, a.limit, a.lines)
    if a.command == "tools":
        _ensure_daemon(a.workspace, a.read_only)
        resp = _rpc("tools/list", {}, timeout=60)
        names = [t["name"] for t in resp.get("result", {}).get("tools", [])]
        print(json.dumps({"count": len(names), "tools": sorted(names)}, indent=2))
        return 0

    _ensure_daemon(a.workspace, a.read_only)
    if a.command == "search":
        args = {"natural_language_query": a.payload}
        tool = "semantic_search"
    elif a.command == "ctx":
        args = {"target": a.payload, "budget_tokens": a.budget}
        tool = "context"
    elif a.command == "tool":
        if not a.payload:
            raise SystemExit("usage: cgrq.py tool NAME '{\"json\":1}'")
        tool = a.payload
        args = json.loads(a.jsonargs) if a.jsonargs else {}
    else:
        raise SystemExit(f"cgrq: unknown command {a.command!r}")
    if a.project:
        args["project"] = a.project
    return _emit(_rpc("tools/call", {"name": tool, "arguments": args}, timeout=a.timeout))


if __name__ == "__main__":
    sys.exit(main())
