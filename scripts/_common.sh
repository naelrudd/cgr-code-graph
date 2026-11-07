#!/usr/bin/env bash
# Shared helpers. Source this, do not execute it.
#
# Why this exists: on Windows, git-bash may set HOME=/home/<user> (an MSYS
# shadow dir) and may leave USERPROFILE/APPDATA pointing elsewhere, while uv,
# ~/.cgr and the model cache all live under the real Windows profile. Scripts
# that trust $HOME report "tool venv not found" on a perfectly good install, so
# the profile is resolved by asking Windows, not by trusting the environment.

# Convert a Windows path (D:\work\x) into this shell's form (/mnt/d/work/x or
# /d/work/x). Used to test paths that came out of a config file written by a
# Windows program.
cgr_posix_path() {
  local p="$1" out="" d
  case "$p" in
    [A-Za-z]:*|\\\\*)
      if command -v wslpath >/dev/null 2>&1; then
        out="$(wslpath -u "$p" 2>/dev/null)"
      elif command -v cygpath >/dev/null 2>&1; then
        out="$(cygpath -u "$p" 2>/dev/null)"
      fi
      if [ -z "$out" ]; then
        d="$(printf '%s' "$p" | cut -c1 | tr '[:upper:]' '[:lower:]')"
        out="/$d/$(printf '%s' "$p" | sed 's|^[A-Za-z]:||; s|\\\\|/|g; s|^/||')"
      fi
      ;;
    *) out="$p" ;;
  esac
  printf '%s' "$out"
}

# A directory visible to BOTH this shell and a Windows program. WSL's /tmp is
# not visible to python.exe, so secrets handed over via a file must live in the
# Windows profile tree.
cgr_temp_dir() {
  local h d; h="$(cgr_home)"
  for d in "$h/AppData/Local/Temp" "${TMPDIR:-}" /tmp; do
    [ -n "$d" ] || continue
    [ -d "$d" ] && [ -w "$d" ] && { printf '%s' "$d"; return 0; }
  done
  printf '%s' "${h:-/tmp}"
}

# Convert a path for a NATIVE (non-MSYS, non-Linux) program. Two different
# bash-on-Windows exist and they need different converters:
#   git-bash / MSYS  -> cygpath -w
#   WSL              -> wslpath -w   (/mnt/d/x  ->  D:\x)
# Passing an unconverted /mnt/d/x to python.exe makes Windows read it as
# D:\mnt\d\x, because it resolves a leading "/" against the current drive.
cgr_native_path() {
  local p="$1" out="" d
  if command -v cygpath >/dev/null 2>&1; then
    out="$(cygpath -w "$p" 2>/dev/null)"
  elif command -v wslpath >/dev/null 2>&1; then
    out="$(wslpath -w "$p" 2>/dev/null)"
  fi
  if [ -z "$out" ]; then
    case "$p" in
      /mnt/[A-Za-z]/*)
        d="$(printf '%s' "${p#/mnt/}" | cut -c1 | tr '[:lower:]' '[:upper:]')"
        out="$d:\\$(printf '%s' "${p#/mnt/?/}" | tr '/' '\\')"
        ;;
      /[A-Za-z]/*)
        d="$(printf '%s' "${p#/}" | cut -c1 | tr '[:lower:]' '[:upper:]')"
        out="$d:\\$(printf '%s' "${p#/?/}" | tr '/' '\\')"
        ;;
      *) out="$p" ;;
    esac
  fi
  printf '%s' "$out"
}

# Value of a Windows path env var, verbatim; empty when unknown.
cgr_win_var() {
  local name="$1" v=""
  v="$(eval "printf '%s' \"\${$name:-}\"")"
  case "$v" in ""|*%*) v="" ;; esac
  if [ -z "$v" ] && command -v cmd >/dev/null 2>&1; then
    v="$(cmd //c "echo %$name%" 2>/dev/null < /dev/null | tr -d '\r')"
    case "$v" in ""|*%*) v="" ;; esac
  fi
  if [ -z "$v" ] && command -v powershell.exe >/dev/null 2>&1; then
    v="$(powershell.exe -NoProfile -Command "\$env:$name" 2>/dev/null < /dev/null | tr -d '\r')"
    case "$v" in ""|*%*) v="" ;; esac
  fi
  [ -n "$v" ] && printf '%s' "$v"
}

# Name of the account running this shell; empty when it cannot be determined.
# Every path this kit builds is derived from a profile directory, so the profile
# must be tied to an identity. A directory listing is not an identity: on a
# shared host the first /c/Users/* that happens to contain a uv install may
# belong to a different local user, and the kit would then run that account's
# executables and write this user's graph into a directory it can read.
cgr_self_user() {
  local v
  for v in USERPROFILE USERNAME USER LOGNAME; do
    case "$v" in
      USERPROFILE|USERNAME) v="$(cgr_win_var "$v")" ;;
      *) v="$(eval "printf '%s' \"\${$v:-}\"")" ;;
    esac
    v="${v##*[\\/]}"
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  done
  return 1
}

# The real user profile in POSIX form (/c/Users/you).
cgr_home() {
  local v raw u me
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
  # Last resort: THIS user's mounted Windows profile, and only that one. The name
  # comes from the account, never from a directory listing: accepting the first
  # /c/Users/* that merely looks plausible would hand a second local account the
  # ability to have its home, and its executables, treated as this user's.
  me="$(cgr_self_user || true)"
  if [ -n "$me" ]; then
    for u in "/c/Users/$me" "/mnt/c/Users/$me"; do
      [ -d "$u" ] || continue
      [ -d "$u/AppData/Roaming/uv" ] || [ -d "$u/.cgr" ] || [ -d "$u/.local/bin" ] || continue
      printf '%s' "$u"; return 0
    done
  fi
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
    w="$(cmd //c "where uv" 2>/dev/null < /dev/null | tr -d '\r' | head -1)"
    # `where` searches the current directory before PATH, so a cloned repository
    # that ships its own uv.exe would win. Only trust an absolute hit, and never
    # one inside the tree we happen to be standing in.
    case "$w" in /*|[A-Za-z]:*) ;; *) w="" ;; esac
    if [ -n "$w" ]; then
      command -v cygpath >/dev/null 2>&1 && w="$(cygpath -u "$w" 2>/dev/null)"
      case "$w" in "$(pwd)"/*) w="" ;; esac
      [ -n "$w" ] && [ -x "$w" ] && { printf '%s' "$w"; return 0; }
    fi
  fi
  return 1
}

# Every place a uv tool venv may plausibly live, one per line.
# Deliberately NOT a wildcard over /c/Users/*: cgr_tool_python executes the first
# interpreter it finds, so a foreign profile's venv would run as this user.
cgr_tool_roots() {
  local h u r me
  h="$(cgr_home)"
  me="$(cgr_self_user || true)"
  {
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
      /usr/local/share/uv/tools \
      /root/.local/share/uv/tools
    do
      case "$r" in /uv/tools|"") continue ;; esac
      printf '%s\n' "$r"
    done
    if [ -n "$me" ]; then
      for r in "/c/Users/$me/AppData/Roaming/uv/tools" "/mnt/c/Users/$me/AppData/Roaming/uv/tools"; do
        [ -d "$r" ] && printf '%s\n' "$r"
      done
    fi
  } | awk '!seen[$0]++'
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
