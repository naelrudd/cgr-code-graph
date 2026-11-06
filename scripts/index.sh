#!/usr/bin/env bash
# Sync (or refresh) a workspace's graph. This is the one command to run in the
# background on a big corpus — it keeps every glob quoted inside a file, because a
# launcher that re-parses the command line will expand `**/node_modules/**` into
# hundreds of argv entries and cgr will die with "Got unexpected extra argument(s)".
#
#   bash scripts/index.sh <workspace>
#
# LLM env (strongly recommended — see below):
#   export LLM_ENDPOINT=http://127.0.0.1:<port>/v1 LLM_MODEL=<model-id> LLM_API_KEY=<key>
set -euo pipefail

WS="${1:?usage: index.sh <workspace>}"

CGR="${CGR_BIN:-cgr}"
command -v "$CGR" >/dev/null 2>&1 || { echo "error: cgr not found. Run scripts/install.sh first" >&2; exit 1; }

# No LLM here. A sync is parsing (tree-sitter + ast-grep) plus local embeddings;
# ORCHESTRATOR_*/CYPHER_* are only read by ask_agent and NL->Cypher, so an overnight
# build needs no API key and no network. Exported anyway when the caller set them,
# so a follow-up `ask.sh` in the same shell inherits them.
if [ -n "${LLM_ENDPOINT:-}" ]; then
  for prefix in ORCHESTRATOR CYPHER; do
    export "${prefix}_PROVIDER=litellm_proxy" "${prefix}_MODEL=${LLM_MODEL}" \
           "${prefix}_ENDPOINT=${LLM_ENDPOINT}" "${prefix}_API_KEY=${LLM_API_KEY:-}"
  done
fi

excludes=(
  --exclude '**/node_modules/**' --exclude '**/.venv/**'   --exclude '**/venv*/**'
  --exclude '**/Library/**'      --exclude '**/.next/**'   --exclude '**/dist/**'
  --exclude '**/build/**'        --exclude '**/target/**'  --exclude '**/__pycache__/**'
  --exclude '**/site-packages/**' --exclude '**/*.pyc'
)

# No --clean: that discards the whole graph. Unchanged files are skipped via the
# per-project hash cache in ~/.cgr/state/<project>/, so re-runs are seconds.
exec "$CGR" start --workspace "$WS" --update-graph "${excludes[@]}"
