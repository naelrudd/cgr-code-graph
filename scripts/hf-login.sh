#!/usr/bin/env bash
# Store a Hugging Face token so the local embedding model downloads without the
# "You are sending unauthenticated requests to the HF Hub" warning.
#
#   bash scripts/hf-login.sh            # prompts (input hidden), verifies, saves
#   bash scripts/hf-login.sh --status   # show whether a token is stored, and who it is
#   bash scripts/hf-login.sh --logout   # delete the stored token
#
# The token is READ-ONLY and optional: it only raises HF download rate limits. No
# source code is ever sent to Hugging Face — the request carries a model id, not
# your files. Never commit a token, and never paste it into a chat.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

PY="$(cgr_tool_python || true)"
[ -n "$PY" ] || { echo "error: tool venv python not found (run scripts/install.sh, or set CGR_TOOL_NAME)" >&2; exit 1; }

TOKEN_FILE="$("$PY" - <<'PY'
import os
print(os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "token"))
PY
)"
TOKEN_FILE="${TOKEN_FILE%$'\r'}"

case "${1:-login}" in
  --where|where)
    echo "HOME (bash)        : $HOME"
    echo "profile resolved   : $(cgr_home)"
    echo "uv                 : $(cgr_uv 2>/dev/null || echo 'not found')"
    echo "tool python        : $(cgr_tool_python 2>/dev/null || echo 'NOT FOUND')"
    echo "shim dir           : $(cgr_shim_dir)"
    echo "searched roots     :"
    cgr_tool_roots | sed 's/^/  - /'
    ;;

  --status|status)
    "$PY" - <<'PY'
import os, sys
try:
    from huggingface_hub import whoami
except Exception as exc:
    print("huggingface_hub unavailable:", exc); sys.exit(1)
tok = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
src = "HF_TOKEN environment variable" if tok else None
if not tok:
    p = os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "token")
    if os.path.exists(p):
        src = p
try:
    who = whoami()
    print(f"token: present ({src})")
    print(f"account: {who.get('name')}  type: {who.get('type')}")
except Exception as exc:
    print(f"token: {'present but rejected' if src else 'not set'} ({src}) - {type(exc).__name__}")
PY
    ;;

  --logout|logout)
    if [ -f "$TOKEN_FILE" ]; then rm -f "$TOKEN_FILE" && echo "removed $TOKEN_FILE"; else echo "no stored token at $TOKEN_FILE"; fi
    echo "note: HF_TOKEN in your environment is untouched — unset it yourself if you set it there."
    ;;

  login)
    echo "Paste a Hugging Face READ token (starts with hf_). Input is hidden."
    echo "Create one at https://huggingface.co/settings/tokens -> New token -> Read."
    printf 'token: '
    stty -echo 2>/dev/null || true
    IFS= read -r TOK
    stty echo 2>/dev/null || true
    printf '\n'
    if [ -z "${TOK:-}" ]; then echo "aborted: empty token" >&2; exit 1; fi
    case "$TOK" in hf_*) ;; *) echo "warning: token does not start with hf_ — saving anyway" >&2 ;; esac

    mkdir -p "$(dirname "$TOKEN_FILE")"
    umask 077
    printf '%s' "$TOK" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true
    unset TOK
    echo "saved to $TOKEN_FILE (mode 600)"

    HF_TOKEN_FROM_FILE=1; export HF_TOKEN_FROM_FILE
    "$PY" - <<'PY'
from huggingface_hub import whoami
try:
    who = whoami()
    print(f"verified: {who.get('name')} ({who.get('type')})")
except Exception as exc:
    print(f"verification failed: {type(exc).__name__}: {exc}")
    print("the file is saved, but huggingface_hub did not accept it - re-issue the token as 'Read'.")
PY
    "$PY" - <<'PY'
import os
p = os.path.join(os.path.expanduser("~"), ".cache", "huggingface", "hub")
n = 0
for _, dirs, files in os.walk(p):
    n += len(files); dirs[:] = dirs
print(f"model cache: {p} ({n} cached files)")
PY
    echo
    echo "Done. Nothing else to configure — huggingface_hub reads this file automatically."
    ;;
  *)
    echo "usage: hf-login.sh [login|--status|--logout]" >&2; exit 2 ;;
esac
