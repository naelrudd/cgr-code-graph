#!/usr/bin/env bash
# Unit tests for the parts of this kit that do not need cgr installed.
#
#   bash tests/smoke.sh
#
# Everything here is a pure shell check: path conversion, identity-bound profile
# resolution, fail-closed behaviour, and the portability rules the kit promises.
# It runs on Linux, macOS and git-bash on Windows, and needs no network, no uv
# and no cgr — which is exactly why it can gate every pull request.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../scripts/_common.sh
. "$KIT/scripts/_common.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
yes()  { if [ "$2" = "0" ]; then ok "$1"; else bad "$1" "${3:-expected success}"; fi; }
no()   { if [ "$2" != "0" ]; then ok "$1"; else bad "$1" "${3:-expected failure}"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output does not contain '$3'" ;; esac; }

echo "== path conversion"

is "posix: drive path -> shell path"      "$(cgr_posix_path 'D:\work\x')" "/d/work/x"
is "posix: forward slashes"               "$(cgr_posix_path 'D:/work/x')" "/d/work/x"
is "posix: already-posix passes through"  "$(cgr_posix_path '/opt/src')" "/opt/src"
is "posix: relative path untouched"       "$(cgr_posix_path 'src/app')" "src/app"

# The fallback branch runs when neither cygpath nor wslpath exists (plain Linux,
# a container). Shadow both with failing functions instead of editing PATH.
noconv() { ( cygpath() { return 1; }; wslpath() { return 1; }; cgr_posix_path "$1" ); }
is "posix fallback: single backslash separators" "$(noconv 'D:\work\x')" "/d/work/x"
is "posix fallback: doubled backslashes"          "$(noconv 'D:\\work\\x')" "/d/work/x"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    is "native: shell path -> drive path" "$(cgr_native_path '/d/work/x')" 'D:\work\x'
    ;;
  Linux)
    # WSL keeps Windows paths reachable under /mnt/<drive>; plain Linux does not.
    if [ -d /mnt/c ]; then
      is "native: /mnt/c path -> drive path" "$(cgr_native_path '/mnt/c/Users/you')" 'C:\Users\you'
    fi
    ;;
esac

echo "== identity-bound profile resolution"

ME="$(cgr_self_user || true)"
[ -n "$ME" ] && ok "cgr_self_user resolves an account name ($ME)" \
              || bad "cgr_self_user resolves an account name" "returned empty"

H="$(cgr_home)"
[ -d "$H" ] && ok "cgr_home points at an existing directory" \
            || bad "cgr_home points at an existing directory" "got '$H'"
case "$H" in
  */AppData|*/AppData/*) bad "cgr_home is a profile, not an AppData subdir" "got '$H'" ;;
  *) ok "cgr_home is a profile, not an AppData subdir" ;;
esac

# A wildcard over other accounts' homes is the bug this kit was audited for:
# the first interpreter found gets executed as this user.
ROOTS="$(cgr_tool_roots)"
case "$ROOTS" in
  *'Users/*'*) bad "tool roots contain no cross-user wildcard" "got: $ROOTS" ;;
  *) ok "tool roots contain no cross-user wildcard" ;;
esac

if [ -n "$ME" ]; then
  case "$ROOTS" in
    *"/Users/"*) # every Users path present must be this account's
      STRANGERS="$(printf '%s\n' "$ROOTS" | grep '/Users/' | grep -v "/Users/$ME/" | head -3)"
      [ -z "$STRANGERS" ] && ok "no other account's uv root is searched" \
                          || bad "no other account's uv root is searched" "got: $STRANGERS"
      ;;
    *) ok "no other account's uv root is searched" ;;
  esac
fi

echo "== fail-closed behaviour"

CGR_TOOL_NAME=cgr-does-not-exist cgr_tool_python >/dev/null 2>&1
no "cgr_tool_python fails when the tool venv is absent" "$?" "it returned success without a venv"

OUT="$(CGR_TOOL_NAME=cgr-does-not-exist bash "$KIT/scripts/hf-login.sh" 2>&1)"
RC=$?
no "hf-login.sh exits non-zero without a tool venv" "$RC"
has "hf-login.sh explains the failure" "$OUT" "tool venv python not found"

OUT="$(CGR_TOOL_NAME=cgr-does-not-exist bash "$KIT/scripts/install.sh" 2>&1)"
RC=$?
case "$RC" in
  0) bad "install.sh does not claim success without a tool venv" "exit 0" ;;
  *) ok "install.sh does not claim success without a tool venv" ;;
esac

echo "== python helper"

PY="$(command -v python3 || command -v python || true)"
if [ -n "$PY" ]; then
  # python is a NATIVE binary: /d/... is not a path it can open.
  HF_PY="$(cgr_native_path "$KIT/scripts/_hf.py")"
  # Compile to a scratch .pyc so a test run never leaves __pycache__ in the repo.
  PYC="$(cgr_native_path "${TMPDIR:-/tmp}")/cgr-hf-check.pyc"
  "$PY" -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
      "$HF_PY" "$PYC" && ok "scripts/_hf.py compiles" \
    || bad "scripts/_hf.py compiles" "py_compile failed"
  OUT="$("$PY" "$HF_PY" path 2>&1 | tr -d '\r')"
  case "$OUT" in
    *huggingface*) ok "_hf.py path prints the token path" ;;
    *) bad "_hf.py path prints the token path" "got: $OUT" ;;
  esac
else
  printf '  skip python checks (no python3 on PATH)\n'
fi

echo "== install PATH comparison"

# install.sh compares cgr_shim_dir against $PATH. On MSYS the shim dir comes back
# native (C:\Users\...) while $PATH holds /c/Users/..., so the raw comparison told
# every Windows user to add a directory that was already on PATH. Guard the
# conversion, not the machine-specific value.
SHIM="$(cgr_shim_dir)"
SHIM_POSIX="$(cgr_posix_path "$SHIM")"
case "$SHIM_POSIX" in
  *\*) bad "shim dir converts to shell form for the PATH check" "still native: $SHIM_POSIX" ;;
  *)    ok  "shim dir converts to shell form for the PATH check" ;;
esac
is "shim dir conversion is stable" "$(cgr_posix_path "$SHIM_POSIX")" "$SHIM_POSIX"

echo "== portability rules"

# The author's own machine must not be in the scripts. Comments are excluded:
# this check documents itself and would otherwise flag its own examples.
ABSHITS="$(grep -rInE '(/c/Users/[A-Za-z0-9._-]+|/mnt/c/Users/[A-Za-z0-9._-]+|[Cc]:\\\\+Users\\\\+[A-Za-z0-9._-]+)' \
             "$KIT/scripts" 2>/dev/null \
           | grep -vE ':[0-9]+:[[:space:]]*#' \
           | grep -vE 'cgr_home|USERPROFILE|/c/Users/\$|/c/Users/you|/mnt/c/Users/\$' \
           | head -3)"
[ -z "$ABSHITS" ] && ok "no hardcoded home path in scripts/" \
                  || bad "no hardcoded home path in scripts/" "got: $ABSHITS"

if [ -d "$KIT/.git" ] && command -v git >/dev/null 2>&1; then
  TRACKED="$(cd "$KIT" && git ls-files 2>/dev/null)"
  JUNK="$(printf '%s\n' "$TRACKED" | grep -E '(^|/)__pycache__/|\.pyc$|\.sqlite$|(^|/)\.env' | head -3)"
  [ -z "$JUNK" ] && ok "no build artifacts or env files tracked" \
                 || bad "no build artifacts or env files tracked" "got: $JUNK"
  SH_CRLF="$(cd "$KIT" && git ls-files --eol -- '*.sh' 2>/dev/null | grep -v 'w/lf' | head -3)"
  [ -z "$SH_CRLF" ] && ok "tracked shell scripts are LF" \
                    || bad "tracked shell scripts are LF" "got: $SH_CRLF"
fi

echo
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
