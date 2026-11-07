#!/usr/bin/env bash
# Store a Hugging Face token so the local embedding model downloads without the
# "You are sending unauthenticated requests to the HF Hub" warning.
#
#   bash scripts/hf-login.sh            # prompts (input hidden), verifies, saves
#   bash scripts/hf-login.sh --status   # is a token stored, and whose is it?
#   bash scripts/hf-login.sh --logout   # delete the stored token
#   bash scripts/hf-login.sh --where    # what did the script find, and where did it look?
#
# The token is READ-ONLY and optional: it only raises HF download rate limits. No
# source code is ever sent to Hugging Face - the request carries a model id, not
# your files. Never commit a token, and never paste it into a chat.
#
# The token is written by Python (scripts/_hf.py), never by shell redirection:
# under WSL or MSYS bash, "$HOME/.cache/huggingface/token" is not the path the
# Windows Python uses, and `> C:\Users\you\...` silently creates a file named
# "C:Usersyou..." in the current directory - a plaintext token in the repo.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

PY="$(cgr_tool_python || true)"
[ -n "$PY" ] || { echo "error: tool venv python not found (run scripts/install.sh, or set CGR_TOOL_NAME)" >&2; exit 1; }
HF_PY="$(cgr_native_path "$SCRIPT_DIR/_hf.py")"

case "${1:-login}" in
  --where|where)
    echo "HOME (bash)        : $HOME"
    echo "profile resolved   : $(cgr_home)"
    echo "uv                 : $(cgr_uv 2>/dev/null || echo 'not found')"
    echo "tool python        : $PY"
    echo "shim dir           : $(cgr_shim_dir)"
    echo "searched roots     :"
    cgr_tool_roots | sed 's/^/  - /'
    ;;

  --status|status) exec "$PY" "$HF_PY" status ;;
  --logout|logout) exec "$PY" "$HF_PY" logout ;;
  login|"")        exec "$PY" "$HF_PY" login ;;

  *)
    echo "usage: hf-login.sh [login|--status|--logout|--where]" >&2
    exit 2
    ;;
esac
