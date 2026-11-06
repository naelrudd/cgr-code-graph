#!/usr/bin/env bash
# Shared helpers. Source this, do not execute it.
#
# Why this exists: under git-bash on Windows, `$HOME` is often /home/<user> (an
# MSYS shadow dir), while uv, the graph and the model cache all live under the
# real Windows profile. A script that trusts $HOME looks for the tool venv in
# the wrong place and reports "tool venv not found" on a perfectly good install.

# The real user profile, in POSIX form (/c/Users/you), falling back to $HOME.
cgr_home() {
  if [ -n "${USERPROFILE:-}" ] && command -v cygpath >/dev/null 2>&1; then
    local u; u="$(cygpath -u "$USERPROFILE" 2>/dev/null)"
    [ -n "$u" ] && { printf '%s' "$u"; return 0; }
  fi
  printf '%s' "$HOME"
}

# Every place a uv tool venv may plausibly live, one per line.
cgr_tool_roots() {
  local h; h="$(cgr_home)"
  if command -v uv >/dev/null 2>&1; then
    local r; r="$(uv tool dir 2>/dev/null | tr -d '\r')"
    [ -n "$r" ] && printf '%s\n' "$r"
  fi
  for r in \
    "${APPDATA:-}/uv/tools" \
    "${LOCALAPPDATA:-}/uv/tools" \
    "$h/AppData/Roaming/uv/tools" \
    "$h/AppData/Local/uv/tools" \
    "$h/.local/share/uv/tools" \
    "$h/Library/Application Support/uv/tools" \
    "/usr/local/share/uv/tools" \
    "/root/.local/share/uv/tools"
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
  if command -v uv >/dev/null 2>&1; then
    cand="$(uv tool dir --bin 2>/dev/null | tr -d '\r')"
    [ -n "$cand" ] && [ -d "$cand" ] && { printf '%s' "$cand"; return 0; }
  fi
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
  local cand
  if command -v uv >/dev/null 2>&1; then
    cand="$(uv tool dir --bin 2>/dev/null | tr -d '\r')"
    [ -n "$cand" ] && { printf '%s' "$cand"; return 0; }
  fi
  printf '%s/.local/bin' "$(cgr_home)"
}
