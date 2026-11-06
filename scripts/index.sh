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

# cgr uses the orchestrator LLM during a sync (summaries), not just for ask_agent.
# Unset, it defaults to ollama:llama3.2 on :11434 and a sync against a dead Ollama
# stalls for minutes per node instead of failing. Measured on the reference corpus:
# 15 s with a live endpoint vs. >3 min (timeout) without.
if [ -n "${LLM_ENDPOINT:-}" ]; then
  for prefix in ORCHESTRATOR CYPHER; do
    export "${prefix}_PROVIDER=litellm_proxy" "${prefix}_MODEL=${LLM_MODEL}" \
           "${prefix}_ENDPOINT=${LLM_ENDPOINT}" "${prefix}_API_KEY=${LLM_API_KEY:-}"
  done
else
  cat >&2 <<'EOF'
warning: LLM_ENDPOINT is not set. cgr will use its default orchestrator
         (ollama:llama3.2 on 127.0.0.1:11434) during the sync. If Ollama is not
         running, the sync stalls for minutes per node instead of failing fast.
         Set LLM_ENDPOINT/LLM_MODEL/LLM_API_KEY, or start Ollama.
EOF
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
