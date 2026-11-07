#!/usr/bin/env bash
# Ask the code graph a question from the terminal, without an agent session.
#
#   bash scripts/ask.sh <workspace> "where is the search index built?"
#
# Requires an LLM endpoint (ORCHESTRATOR_*/CYPHER_* env, see docs/windows-gotchas.md#provider).
set -euo pipefail
WS="${1:?usage: ask.sh <workspace> <question>}"
shift
Q="${*:?usage: ask.sh <workspace> <question>}"
exec "${CGR_BIN:-cgr}" start --workspace "$WS" --no-sync --ask-agent "$Q"
