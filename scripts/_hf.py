"""Hugging Face token helper for cgr-code-graph.

Kept as a real file (not a heredoc) on purpose: `python - <<EOF` consumes stdin
for the program itself, so a piped token could never be read, and every
diagnostic the shell printed ended up interleaved with Python's.

Usage: python _hf.py {login|status|logout}
"""

import getpass
import os
import sys

try:
    from huggingface_hub import login, whoami
    from huggingface_hub.constants import HF_HOME, HF_HUB_CACHE, HF_TOKEN_PATH
except Exception as exc:  # pragma: no cover - dependency missing
    print(f"error: huggingface_hub unavailable in this python: {exc}", file=sys.stderr)
    sys.exit(1)


def read_token() -> str:
    if sys.stdin.isatty():
        return getpass.getpass("token: ").strip()
    # stdin may be a pipe (token piped in) - prefer it over touching the console,
    # because opening the Windows console device blocks forever on a pipe.
    data = sys.stdin.readline().strip()
    if data:
        return data
    try:  # a real terminal is still reachable on POSIX shells
        with open("/dev/tty") as tty:
            return tty.readline().strip()
    except OSError:
        return ""


def cmd_login() -> int:
    print(f"token file: {HF_TOKEN_PATH}", flush=True)
    print("Create a READ token at https://huggingface.co/settings/tokens -> New token -> Read.", flush=True)
    tok = read_token()
    if not tok:
        print("aborted: empty token", file=sys.stderr)
        return 1
    if not tok.startswith("hf_"):
        print("warning: token does not start with hf_ - trying anyway", file=sys.stderr)

    # login() validates against the Hub before saving, so a bad or wrong-role
    # token never reaches the disk. It also does the writing: shell redirection
    # to a Windows path from WSL/MSYS bash creates junk files in the cwd.
    try:
        login(token=tok, add_to_git_credential=False)
    except Exception as exc:
        print(f"error: the Hub rejected the token - {type(exc).__name__}: {exc}", file=sys.stderr)
        print("check that the token exists, is not expired, and has the 'Read' role", file=sys.stderr)
        return 1
    del tok

    print(f"saved to {HF_TOKEN_PATH}")
    try:
        who = whoami()
        print(f"verified: {who.get('name')} ({who.get('type')})")
    except Exception as exc:
        print(f"note: verification call failed ({type(exc).__name__}); the token is stored", file=sys.stderr)

    n = sum(len(f) for _, _, f in os.walk(HF_HUB_CACHE)) if os.path.isdir(HF_HUB_CACHE) else 0
    print(f"model cache: {HF_HUB_CACHE} ({n} cached files)")
    return 0


def cmd_status() -> int:
    src = None
    if os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN"):
        src = "environment (HF_TOKEN)"
    elif os.path.exists(HF_TOKEN_PATH):
        src = HF_TOKEN_PATH
    if not src:
        print(f"token: not set (expected at {HF_TOKEN_PATH})")
        print(f"hf home: {HF_HOME}")
        return 0
    print(f"token: present ({src})")
    try:
        who = whoami()
        print(f"account: {who.get('name')}  type: {who.get('type')}")
    except Exception as exc:
        print(f"account: unknown - {type(exc).__name__}")
        print("fix: issue a new token with the 'Read' role and run login again")
    return 0


def cmd_logout() -> int:
    if os.path.exists(HF_TOKEN_PATH):
        os.remove(HF_TOKEN_PATH)
        print(f"removed {HF_TOKEN_PATH}")
    else:
        print(f"no stored token at {HF_TOKEN_PATH}")
    if os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN"):
        print("note: HF_TOKEN is also set in this environment - unset it yourself if you set it there.")
    return 0


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else "login"
    return {"login": cmd_login, "status": cmd_status, "logout": cmd_logout}.get(cmd, lambda: 2)()


if __name__ == "__main__":
    sys.exit(main())
