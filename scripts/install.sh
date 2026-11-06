#!/usr/bin/env bash
# Install code-graph-rag (cgr) with the bits the published wheel omits.
# Verified on Windows 11 + git-bash (MSYS) and Linux. macOS should be identical to Linux.
set -euo pipefail

UV_TOOL_NAME="code-graph-rag"

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
TOOL_PY="$(uv tool dir)/${UV_TOOL_NAME}/Scripts/python.exe"
[ -x "$TOOL_PY" ] || TOOL_PY="$(uv tool dir)/${UV_TOOL_NAME}/bin/python"
if [ ! -x "$TOOL_PY" ]; then
  echo "error: could not locate the tool venv python under $(uv tool dir)/${UV_TOOL_NAME}" >&2
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

BIN_DIR="$(uv tool dir --bin 2>/dev/null || echo "$HOME/.local/bin")"
echo
echo "==> done"
echo "    binary: ${BIN_DIR}/cgr (Windows: ${BIN_DIR}/cgr.exe)"
case ":$PATH:" in
  *":${BIN_DIR}:"*) ;;
  *) echo "    NOTE: ${BIN_DIR} is not on PATH. Add it, or call cgr by absolute path." ;;
esac
echo "    verify: cgr --version && cgr doctor"
