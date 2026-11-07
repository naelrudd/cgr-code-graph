#!/usr/bin/env bash
# Shared helpers. Source this, do not execute it.
#
# Why this exists: on Windows, git-bash may set HOME=/home/<user> (an MSYS
# shadow dir) and may leave USERPROFILE/APPDATA pointing elsewhere, while uv,
# ~/.cgr and the model cache all live under the real Windows profile. Scripts
# that trust $HOME report "tool venv not found" on a perfectly good install, so
# the profile is resolved by asking Windows, not by trusting the environment.

# Convert a path for a NATIVE (non-MSYS) program. MSYS path conversion is off in
# scripts, so /d/money/x reaches python.exe as D:\d\money\x and the file is not
# found. Always pass file arguments through this.
cgr_native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$1" 2>/dev/null || printf '%s' "$1"
  else
    printf '%s' "$1"
  fi
}

# Value of a Windows path env var, verbatim; empty when unknown.
cgr_win_var() {
  local name="$1" v=""
  v="$(eval "printf '%s' \"\${$name:-}\"")"
  case "$v" in ""|*%*) v="" ;; esac
  if [ -z "$v" ] && command -v cmd >/dev/null 2>&1; then
    v="$(cmd //c "echo %$name%" 2>/dev/null | tr -d '\r')"
    case "$v" in ""|*%*) v="" ;; esac
  fi
  if [ -z "$v" ] && command -v powershell.exe >/dev/null 2>&1; then
    v="$(powershell.exe -NoProfile -Command "\$env:$name" 2>/dev/null | tr -d '\r')"
    case "$v" in ""|*%*) v="" ;; esac
  fi
  [ -n "$v" ] && printf '%s' "$v"
}

# The real user profile in POSIX form (/c/Users/you).
cgr_home() {
  local v raw u
  for v in USERPROFILE LOCALAPPDATA APPDATA; do
    raw="$(cgr_win_var "$v")"
    [ -n "$raw" ] || continue
    if command -v cygpath >/dev/null 2>&1; then
      u="$(cygpath -u "$raw" 2>/dev/null)"
    else
      u="$raw"
    fi
    case "$u" in
      */AppData/*|*/appdata/*) u="${u%%/AppData/*}"; u="${u%%/appdata/*}" ;;
    esac
    [ -n "$u" ] && [ -d "$u" ] && { printf '%s' "$u"; return 0; }
  done
  # $HOME is right on Linux/macOS and wrong only when it is an MSYS shadow dir.
  case "$HOME" in
    /home/*|/root) ;;
    *) [ -d "${HOME:-/nonexistent}" ] && { printf '%s' "$HOME"; return 0; } ;;
  esac
  # Last resort: the mounted Windows user directory that actually owns a uv
  # install or an existing graph. Skip the system profiles (All Users, Public,
  # Default) which match the glob too and would poison every later path.
  local best=""
  for u in /c/Users/* /mnt/c/Users/*; do
    [ -d "$u" ] || continue
    case "${u##*/}" in All\ Users|Default|Default\ User|defaultuser0|Public|WDAGUtilityAccount) continue ;; esac
    if [ -d "$u/AppData/Roaming/uv" ] || [ -d "$u/.cgr" ] || [ -d "$u/.local/bin" ]; then
      best="$u"; break
    fi
    [ -z "$best" ] && best="$u"
  done
  [ -n "$best" ] && { printf '%s' "$best"; return 0; }
  printf '%s' "$HOME"
}

# Find the uv executable even when it is not on PATH (common in git-bash).
cgr_uv() {
  if command -v uv >/dev/null 2>&1; then printf 'uv'; return 0; fi
  local h w; h="$(cgr_home)"
  for w in "$h/.local/bin/uv.exe" "$h/.local/bin/uv" "$h/.cargo/bin/uv.exe" "$h/.cargo/bin/uv" \
           "$h/AppData/Local/Programs/uv/uv.exe"; do
    [ -x "$w" ] && { printf '%s' "$w"; return 0; }
  done
  if command -v cmd >/dev/null 2>&1; then
    w="$(cmd //c "where uv" 2>/dev/null | tr -d '\r' | head -1)"
    if [ -n "$w" ]; then
      command -v cygpath >/dev/null 2>&1 && w="$(cygpath -u "$w" 2>/dev/null)"
      [ -x "$w" ] && { printf '%s' "$w"; return 0; }
    fi
  fi
  return 1
}

# Every place a uv tool venv may plausibly live, one per line.
cgr_tool_roots() {
  local h u r
  h="$(cgr_home)"
  u="$(cgr_uv 2>/dev/null || true)"
  if [ -n "$u" ]; then
    r="$("$u" tool dir 2>/dev/null | tr -d '\r')"
    [ -n "$r" ] && printf '%s\n' "$r"
  fi
  for r in \
    "${APPDATA:-}/uv/tools" \
    "${LOCALAPPDATA:-}/uv/tools" \
    "$h/AppData/Roaming/uv/tools" \
    "$h/AppData/Local/uv/tools" \
    "$h/.local/share/uv/tools" \
    "$h/Library/Application Support/uv/tools" \
    /c/Users/*/AppData/Roaming/uv/tools \
    /mnt/c/Users/*/AppData/Roaming/uv/tools \
    /usr/local/share/uv/tools \
    /root/.local/share/uv/tools
  do
    case "$r" in /uv/tools|"") continue ;; esac
    printf '%s\n' "$r"
  done | awk '!seen[$0]++'
}

# Path to the tool venv python; exits non-zero when it cannot be found.
cgr_tool_python() {
  local name="${CGR_TOOL_NAME:-code-graph-rag}" root p
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    for p in "$root/$name/Scripts/python.exe" "$root/$name/bin/python"; do
      [ -x "$p" ] && { printf '%s' "$p"; return 0; }
    done
  done < <(cgr_tool_roots)
  return 1
}

# Directory holding the tool's console scripts.
cgr_tool_bin_dir() {
  local name="${CGR_TOOL_NAME:-code-graph-rag}" root cand
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    for cand in "$root/$name/Scripts" "$root/$name/bin"; do
      [ -d "$cand" ] && { printf '%s' "$cand"; return 0; }
    done
  done < <(cgr_tool_roots)
  printf '%s/.local/bin' "$(cgr_home)"
}

# Directory holding the uv tool shims (where `cgr` normally lives).
cgr_shim_dir() {
  local u cand h
  u="$(cgr_uv 2>/dev/null || true)"
  if [ -n "$u" ]; then
    cand="$("$u" tool dir --bin 2>/dev/null | tr -d '\r')"
    [ -n "$cand" ] && [ -d "$cand" ] && { printf '%s' "$cand"; return 0; }
  fi
  h="$(cgr_home)"
  for cand in "$h/.local/bin" "$h/bin" "$(cgr_tool_bin_dir)"; do
    [ -d "$cand" ] && { printf '%s' "$cand"; return 0; }
  done
  printf '%s/.local/bin' "$h"
}
