#!/usr/bin/env bash
# Incremental refresh — thin wrapper over scripts/index.sh so exactly one file knows
# the excludes and the LLM env handling.
#
#   bash scripts/refresh.sh <workspace>
set -euo pipefail
WS="${1:?usage: refresh.sh <workspace>}"
exec bash "$(dirname "$0")/index.sh" "$WS"
