#!/usr/bin/env bash
# Sync (or refresh) a workspace's graph — non-interactively, one repo at a time.
#
#   bash scripts/index.sh <workspace>
#
# Why this does not use `cgr start --workspace <ws> --update-graph`: with a
# workspace that command syncs every repo and then STARTS THE ASSISTANT (its own
# help says so; only repo mode "exits without starting the assistant"). For a
# background build that is fatal — the assistant validates an LLM provider before
# reading any input and dies with `ValueError: Ollama server not responding`,
# leaving a fully synced graph behind a non-zero exit. Repo mode exits on its own,
# so this script walks the workspace file and syncs each repo under the exact
# project_name recorded there.
#
# Every glob stays inside this file: a launcher that re-parses the command line
# expands `**/node_modules/**` into hundreds of argv entries and cgr dies with
# "Got unexpected extra argument(s)".
#
# LLM env (optional — a sync never calls an LLM):
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

# shellcheck source=scripts/_common.sh
. "$(dirname "$0")/_common.sh"
CGR_DIR="${CGR_HOME:-$(cgr_home)/.cgr}"
TOML="$CGR_DIR/workspaces/$WS.toml"
[ -f "$TOML" ] || { echo "error: no workspace '$WS' at $TOML — run scripts/init-workspace.sh first" >&2; exit 1; }

# One "path<TAB>project_name" line per repo, in file order. TOML escapes each
# Windows separator as a doubled backslash; the unescape happens at use.
repos() {
  awk -F'"' '
    /^\[\[workspace\.repos\]\]/ { p = ""; next }
    /^path[ \t]*=/              { p = $2; next }
    /^project_name[ \t]*=/      { if (p != "") printf "%s\t%s\n", p, $2; p = "" }
  ' "$TOML"
}

# No --clean: that discards the whole graph. Unchanged files are skipped via the
# per-project hash cache in ~/.cgr/state/<project>/, so re-runs are seconds.
count=0
failed=0
while IFS=$'\t' read -r repo_path project_name; do
  [ -n "$repo_path" ] || continue
  repo_path="${repo_path//\\\\//}"
  count=$((count + 1))
  name_args=()
  [ -z "$project_name" ] || name_args=(--project-name "$project_name")
  echo "==> [$count] syncing '${project_name:-derived}' <- $repo_path"
  if "$CGR" start --repo-path "$repo_path" ${name_args[@]+"${name_args[@]}"} \
        --update-graph "${excludes[@]}"; then
    :
  else
    echo "    ! sync failed for '$repo_path'" >&2
    failed=$((failed + 1))
  fi
done < <(repos)

[ "$count" -gt 0 ] || { echo "error: workspace '$WS' declares no repos in $TOML" >&2; exit 1; }
[ "$failed" -eq 0 ] || { echo "error: $failed repo(s) failed to sync" >&2; exit 1; }
echo "==> workspace '$WS' synced ($count repos)"
