#!/usr/bin/env bash
# Register a workspace spanning every project under a root directory, then index it.
#
#   bash scripts/init-workspace.sh <workspace> <root> [project ...]
#
# With no project args, every direct child of <root> that looks like code is added
# (has .git, package.json, pyproject.toml, requirements.txt, Cargo.toml, go.mod, or convex/).
set -euo pipefail

WS="${1:?usage: init-workspace.sh <workspace> <root> [project ...]}"
ROOT="${2:?usage: init-workspace.sh <workspace> <root> [project ...]}"
shift 2

CGR="${CGR_BIN:-cgr}"
command -v "$CGR" >/dev/null 2>&1 || { echo "error: cgr not found. Run scripts/install.sh first" >&2; exit 1; }
[ -d "$ROOT" ] || { echo "error: root '$ROOT' is not a directory" >&2; exit 1; }

# cgr is a native binary and cannot resolve MSYS/POSIX paths (/d/work, /tmp/x),
# so paths must be converted or every add-repo silently fails.
native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}
ROOT_NATIVE="$(native_path "$ROOT")"

if [ "$#" -gt 0 ]; then
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

echo "==> workspace '$WS' over $ROOT: ${#PROJECTS[@]} projects"
"$CGR" workspace create "$WS" -d "code graph over $ROOT" --force

for p in "${PROJECTS[@]}"; do
  if err="$("$CGR" workspace add-repo "$WS" "$ROOT_NATIVE/$p" 2>&1 >/dev/null)"; then
    echo "    + $p"
  else
    echo "    ! $p — add-repo failed: $(printf '%s' "$err" | tail -1)"
  fi
done

echo
echo "==> indexing via scripts/index.sh (first pass on a large corpus runs for hours)."
echo "    Launch it as a tracked background job:"
echo "      bash $(dirname "$0")/index.sh $WS"
exec bash "$(dirname "$0")/index.sh" "$WS"
