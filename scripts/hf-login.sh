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

  --status|status) "$PY" "$HF_PY" status ;;
  --logout|logout) "$PY" "$HF_PY" logout ;;

  login|"")
    TOK_PATH="$("$PY" "$HF_PY" path | tr -d '\r')"
    cat <<EOF
Hugging Face token setup
========================

Why: the local embedding model is downloaded from huggingface.co. Without a
token the download is anonymous - it still works, just slower and rate-limited
(that is the "unauthenticated requests" warning). A token changes nothing about
privacy: the request carries a model id, never your code.

Steps
  1. Open https://huggingface.co/settings/tokens
  2. Click "New token", name it anything (e.g. cgr-local)
  3. Choose role "Read" - Read is enough; Write would be pointless here
  4. Click "Create token" and copy the string starting with hf_
     (it is shown once - if you lose it, delete it and make another)

Where it is stored
  portable   : ~/.cache/huggingface/token
  on this PC : $TOK_PATH

  Nothing here is written into the repo - that absolute path is computed at run
  time from your profile, so the same script prints a different one on every
  machine and user account. It also moves if you set HF_TOKEN_PATH, HF_HOME or
  XDG_CACHE_HOME; "bash scripts/hf-login.sh --where" shows how it was resolved.
  Per-OS defaults: docs/huggingface-token.md.

Paste the token below and press Enter.
  >> NOTHING will appear as you paste - no dots, no asterisks, no echo. <<
  That is deliberate: the terminal hides input so the token never lands in your
  screen, your scrollback, or a screen recording. Paste and press Enter blind.
  (In Windows Terminal / PowerShell, right-click pastes.)

EOF
    printf 'token: '
    stty -echo 2>/dev/null || true
    IFS= read -r TOK
    stty echo 2>/dev/null || true
    printf '\n'
    if [ -z "${TOK:-}" ]; then echo "aborted: nothing was pasted (empty input)" >&2; exit 1; fi

    TMPD="$(cgr_temp_dir)"
    TF="$TMPD/cgr-hf-token-$$"
    ( umask 077; printf '%s' "$TOK" > "$TF" ) || { echo "error: cannot write $TF" >&2; exit 1; }
    TOK=""

    "$PY" "$HF_PY" login --quiet --token-file "$(cgr_native_path "$TF")"
    RC=$?
    rm -f "$TF"
    exit $RC
    ;;

  *)
    echo "usage: hf-login.sh [login|--status|--logout|--where]" >&2
    exit 2
    ;;
esac
