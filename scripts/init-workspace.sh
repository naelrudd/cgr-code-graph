#!/usr/bin/env bash
# Register a workspace spanning every project under a root directory, then index it.
#
#   bash scripts/init-workspace.sh <workspace> <root> [project ...]     one project per repo
#   bash scripts/init-workspace.sh <workspace> <root> --root            one project for the whole root
#
# --root changes what the graph can see. Imports and calls resolve by path against
# the indexed root, so a directory that holds several packages must be indexed as
# ONE repo for a sibling import to land on a real Module and a real CALLS edge —
# e.g. Python `from pkg_b.core import helper`, or JS `from "../pkg_b/lib.js"`.
# Registered as separate projects the same import becomes an ExternalModule stub
# with no call edge. Measured with `tests/`-style probe corpora, not assumed.
#
# What it costs: one namespace. One hash cache instead of one per repo, `--clean`
# wipes everything, no per-repo refresh, and `--projects` filtering collapses to a
# single value. Merge only where the repos really import each other by path; two
# projects that both depend on lodash gain nothing from sharing a root.
#
# With no project args, every direct child of <root> that looks like code is added
# (has .git, package.json, pyproject.toml, requirements.txt, Cargo.toml, go.mod, or convex/).
#
# Re-running this for an existing workspace is refused unless --force is given:
# `workspace create --force` would replace the definition, but the projects the old
# layout indexed stay in the graph, so every file would then answer twice under two
# namespaces. --force says "replace the layout and accept that".
set -euo pipefail

MODE=projects
FORCE=0
args=()
for a in "$@"; do
  case "$a" in
    --root) MODE=root ;;
    --force) FORCE=1 ;;
    # Print the comment header only: stop at the first non-comment line so the
    # usage text can never leak `set -euo pipefail` the way a fixed line range did.
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    *) args+=("$a") ;;
  esac
done
set -- ${args[@]+"${args[@]}"}

WS="${1:?usage: init-workspace.sh <workspace> <root> [--root] [--force] [project ...]}"
ROOT="${2:?usage: init-workspace.sh <workspace> <root> [--root] [--force] [project ...]}"
shift 2

CGR="${CGR_BIN:-cgr}"
command -v "$CGR" >/dev/null 2>&1 || { echo "error: cgr not found. Run scripts/install.sh first" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "error: root '$ROOT' is not a directory" >&2; exit 1; }

# Refuse to silently re-lay an existing workspace. This runs before anything is
# written, and names what is already registered so the choice is informed.
if existing="$("$CGR" workspace show "$WS" 2>/dev/null)" && [ -n "${existing//[$'\r\n ']/}" ]; then
  if [ "$FORCE" -ne 1 ]; then
    echo "error: workspace '$WS' already exists:" >&2
    printf '%s\n' "$existing" | sed 's/^/    /' >&2
    echo >&2
    echo "  Re-laying it would index the same files a second time under new project" >&2
    echo "  names — the old rows stay in the graph and every query answers twice." >&2
    echo "  Pass --force to replace the layout anyway, or use another workspace name," >&2
    echo "  or 'cgr workspace remove-repo $WS <path>' to drop one repo." >&2
    exit 1
  fi
  echo "==> replacing the existing workspace '$WS' (--force)"
fi

# cgr is a native binary and cannot resolve MSYS/POSIX paths (/d/work, /tmp/x),
# so paths must be converted or every add-repo silently fails.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}
ROOT_NATIVE="$(native_path "$ROOT")"

if [ "$MODE" = root ]; then
  [ "$#" -eq 0 ] || { echo "error: --root indexes the whole root as one project; drop the project list ($*)" >&2; exit 1; }
  PROJECTS=("$WS")
elif [ "$#" -gt 0 ]; then
  PROJECTS=("$@")
else
  PROJECTS=()
  for d in "$ROOT"/*/; do
    n="$(basename "$d")"
    case "$n" in _*|.|node_modules) continue ;; esac
    if [ -d "$d/.git" ] || [ -f "$d/package.json" ] || [ -f "$d/pyproject.toml" ] \
       || [ -f "$d/requirements.txt" ] || [ -f "$d/Cargo.toml" ] || [ -f "$d/go.mod" ] \
       || [ -d "$d/convex" ]; then
      PROJECTS+=("$n")
    fi
  done
fi

[ "${#PROJECTS[@]}" -gt 0 ] || { echo "error: found no projects under $ROOT" >&2; exit 1; }

if [ "$MODE" = root ]; then
  WHAT="one project for the whole root (sibling imports resolve)"
else
  WHAT="${#PROJECTS[@]} projects, one per repo"
fi

echo "==> workspace '$WS' over $ROOT — $WHAT"
"$CGR" workspace create "$WS" -d "code graph over $ROOT" --force

if [ "$MODE" = root ]; then
  # One repo entry for the whole root: the root becomes the project namespace, which
  # is what lets a sibling import resolve instead of degrading to an external stub.
  # No -p here: let cgr derive `<dirname>__<hash>` exactly as it does for a child
  # repo, so the graph project name, the workspace file and the hash-cache directory
  # (~/.cgr/state/<dirname>__<hash>/) all agree. A custom name would desync them.
  if err="$("$CGR" workspace add-repo "$WS" "$ROOT_NATIVE" 2>&1 >/dev/null)"; then
    echo "    + $WS <- $ROOT (single root)"
  else
    echo "    ! add-repo failed for $ROOT — $(printf '%s' "$err" | tail -1)" >&2
    exit 1
  fi
else
  for p in "${PROJECTS[@]}"; do
    if err="$("$CGR" workspace add-repo "$WS" "$ROOT_NATIVE/$p" 2>&1 >/dev/null)"; then
      echo "    + $p"
    else
      echo "    ! $p — add-repo failed: $(printf '%s' "$err" | tail -1)"
    fi
  done
fi

echo
echo "==> indexing via scripts/index.sh (first pass on a large corpus runs for hours)."
echo "    Launch it as a tracked background job:"
echo "      bash $(dirname "$0")/index.sh $WS"
exec bash "$(dirname "$0")/index.sh" "$WS"
