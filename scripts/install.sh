#!/usr/bin/env bash
# Install code-graph-rag (cgr) with the bits the published wheel omits.
# Verified on Windows 11 + git-bash (MSYS) and Linux. macOS should be identical to Linux.
set -euo pipefail

# CGR_TOOL_NAME is the override every other script in the kit honours; without it
# install.sh alone was untestable against a bogus name and could not be pointed at
# a renamed tool env.
UV_TOOL_NAME="${CGR_TOOL_NAME:-code-graph-rag}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"

if ! command -v uv >/dev/null 2>&1; then
  echo "error: uv is required (https://docs.astral.sh/uv/). Install it, then re-run." >&2
  exit 1
fi

echo "==> installing ${UV_TOOL_NAME}"
# ast-grep extra is what lets the bash/shell/nix tier parse; without it those files
# land in the graph as bare File nodes ("...were indexed as plain File nodes").
uv tool install "${UV_TOOL_NAME}[treesitter-full,sqlite-vec,ast-grep]" || uv tool upgrade "${UV_TOOL_NAME}"

# The wheel imports httpx from tools/health_checker.py but does not depend on it,
# so every command dies with ModuleNotFoundError until it is present in the tool venv.
# Bind the interpreter to the venv this run just installed. `cgr_tool_python`
# searches several roots (including, historically, other profiles) and returns
# the first executable it finds, so it must not be trusted to identify the venv
# that `uv tool install` above was supposed to create.
TOOL_PY=""
TOOL_ROOT="$(uv tool dir 2>/dev/null | tr -d '\r')"
for cand in "$TOOL_ROOT/${UV_TOOL_NAME}/Scripts/python.exe" "$TOOL_ROOT/${UV_TOOL_NAME}/bin/python"; do
  [ -x "$cand" ] && { TOOL_PY="$cand"; break; }
done
if [ -z "$TOOL_PY" ]; then
  TOOL_PY="$(cgr_tool_python || true)"
  echo "warn: ${UV_TOOL_NAME} not found under '${TOOL_ROOT}' — falling back to ${TOOL_PY:-nothing}" >&2
fi
if [ -z "$TOOL_PY" ] || [ ! -x "$TOOL_PY" ]; then
  echo "error: could not locate the tool venv python (searched $(cgr_tool_roots | tr '\n' ' '))" >&2
  exit 1
fi
echo "==> tool python: $TOOL_PY"

if ! "$TOOL_PY" -c 'import httpx' 2>/dev/null; then
  echo "==> injecting httpx (missing from the wheel)"
  uv pip install --python "$TOOL_PY" httpx
fi

# Local embeddings only: no API key, no quota, works offline.
if ! "$TOOL_PY" -c 'import torch, transformers' 2>/dev/null; then
  echo "==> installing torch + transformers for local UniXcoder embeddings (~1 GB, one time)"
  uv pip install --python "$TOOL_PY" 'torch>=2.6.0' 'transformers>=5.0.0'
fi

BIN_DIR="$(cgr_shim_dir)"
# $PATH is in shell form (/c/Users/...) but cgr_shim_dir returns a native path
# (C:\Users\...), so the old comparison never matched on MSYS and the script told
# every Windows user to add a directory that was already on PATH. Compare posix.
BIN_DIR_POSIX="$(cgr_posix_path "$BIN_DIR")"
echo
echo "==> done"
echo "    binary: ${BIN_DIR}/cgr (Windows: ${BIN_DIR}/cgr.exe)"
case ":$PATH:" in
  *":${BIN_DIR_POSIX}:"*) ;;
  *) echo "    NOTE: ${BIN_DIR} is not on PATH. Add it, or call cgr by absolute path." ;;
esac
echo "    verify: cgr --version && cgr doctor"
