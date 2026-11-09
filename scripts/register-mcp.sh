#!/usr/bin/env bash
# Register the cgr MCP server with an agent CLI so its 25 tools load automatically.
#
#   bash scripts/register-mcp.sh <workspace> <root> [extra repo path]
#
# <root> matters: the MCP client spawns servers with cwd = your home directory, and
# cgr refuses to serve from a home dir or a disk root. TARGET_REPO_PATH is what makes
# it accept the launch.
#
# The <extra repo path> argument (or TARGET_REPO_PATH in the environment) is optional
# and only used by tools that need a concrete repo to walk.
set -euo pipefail

WS="${1:?usage: register-mcp.sh <workspace> <root> [repo path] [--with-writer]}"
ROOT="${2:?usage: register-mcp.sh <workspace> <root> [repo path] [--with-writer]}"
REPO="${3:-$ROOT}"

# --read-only is the safe default, but it also hides every writer: 26 of 37 tools
# stay, and `annotate` -- the only way an agent can record *why* -- is among the
# missing ones. --with-writer adds a second server without that flag. Its writes are
# notes and graph syncs; the destructive ones (rename, write_file, wipe_database)
# come along too, which is why this stays opt-in.
WITH_WRITER=0
for arg in "$@"; do
  [ "$arg" = "--with-writer" ] && WITH_WRITER=1
done

CGR="${CGR_BIN:-cgr}"
CGR_ABS="$(command -v "$CGR" || true)"
[ -n "$CGR_ABS" ] || { echo "error: cgr not found. Run scripts/install.sh first" >&2; exit 1; }

if ! command -v hermes >/dev/null 2>&1; then
  cat >&2 <<EOF
hermes CLI not found. Any MCP client works — this is the stdio command to point it at:

  command: $CGR_ABS
  args:    mcp-server --read-only --workspace $WS
  env:     TARGET_REPO_PATH=$REPO
           (plus ORCHESTRATOR_*/CYPHER_* only if you want ask_agent)

Add a second entry without --read-only if agents should be able to write notes
(the 'annotate' tool) — that flag hides it along with 10 other writers.

Claude Code / other clients: add the same entry to their MCP config JSON.
EOF
  exit 1
fi

# LLM settings are exportable so a user with a custom OpenAI-compatible gateway can
# enable ask_agent without editing this script. Graph-only use needs none of them.
ENV_ARGS=(TARGET_REPO_PATH="$REPO" MCP_READ_ONLY=true)
if [ -n "${LLM_ENDPOINT:-}" ]; then
  for pair in "ORCHESTRATOR:${LLM_MODEL:-}" "CYPHER:${LLM_MODEL:-}"; do
    prefix="${pair%%:*}"
    ENV_ARGS+=("${prefix}_PROVIDER=litellm_proxy" "${prefix}_MODEL=${LLM_MODEL}"
               "${prefix}_ENDPOINT=${LLM_ENDPOINT}" "${prefix}_API_KEY=${LLM_API_KEY:-}")
  done
fi

echo "==> registering MCP server 'cgr' (workspace: $WS, read-only)"
# hermes mcp add ends with an interactive "Enable all N tools?" prompt; piped stdin
# gives it EOF and cancels registration even though the connection succeeded.
printf 'y\n' | hermes mcp add cgr \
  --command "$CGR_ABS" \
  --connect-timeout 120 \
  --env "${ENV_ARGS[@]}" \
  --args mcp-server --read-only --workspace "$WS"

if [ "$WITH_WRITER" -eq 1 ]; then
  # Same server, same graph, minus the flag. MCP_READ_ONLY must not be inherited:
  # the env var alone re-arms the read-only gate even without --read-only.
  ENV_WRITE=()
  for pair in "${ENV_ARGS[@]}"; do
    [ "${pair%%=*}" = "MCP_READ_ONLY" ] && continue
    ENV_WRITE+=("$pair")
  done
  echo
  echo "==> registering MCP server 'cgr-write' (workspace: $WS, writers on)"
  printf 'y\n' | hermes mcp add cgr-write \
    --command "$CGR_ABS" \
    --connect-timeout 120 \
    --env "${ENV_WRITE[@]}" \
    --args mcp-server --workspace "$WS"
fi

echo
echo "==> verify:  hermes mcp test cgr"
if [ "$WITH_WRITER" -eq 1 ]; then
  echo "              hermes mcp test cgr-write   (expects 37 tools, incl. annotate)"
fi
echo "    A running agent session does NOT pick up new MCP tools — reload it (/reload-mcp) or start a new session."
