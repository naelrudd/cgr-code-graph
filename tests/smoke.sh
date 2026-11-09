#!/usr/bin/env bash
# Unit tests for the parts of this kit that do not need cgr installed.
#
#   bash tests/smoke.sh
#
# Everything here is a pure shell check: path conversion, identity-bound profile
# resolution, fail-closed behaviour, and the portability rules the kit promises.
# It runs on Linux, macOS and git-bash on Windows, and needs no network, no uv
# and no cgr — which is exactly why it can gate every pull request.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KIT="$(cd "$HERE/.." && pwd)"
# shellcheck source=../scripts/_common.sh
. "$KIT/scripts/_common.sh"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
yes()  { if [ "$2" = "0" ]; then ok "$1"; else bad "$1" "${3:-expected success}"; fi; }
no()   { if [ "$2" != "0" ]; then ok "$1"; else bad "$1" "${3:-expected failure}"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output does not contain '$3'" ;; esac; }
# `grep -c` prints 0 AND exits 1 on no match, so `|| printf 0` would emit "0\n0".
count() { grep -c "$1" "$2" 2>/dev/null || true; }

echo "== path conversion"

is "posix: drive path -> shell path"      "$(cgr_posix_path 'D:\work\x')" "/d/work/x"
is "posix: forward slashes"               "$(cgr_posix_path 'D:/work/x')" "/d/work/x"
is "posix: already-posix passes through"  "$(cgr_posix_path '/opt/src')" "/opt/src"
is "posix: relative path untouched"       "$(cgr_posix_path 'src/app')" "src/app"

# The fallback branch runs when neither cygpath nor wslpath exists (plain Linux,
# a container). Shadow both with failing functions instead of editing PATH.
noconv() { ( cygpath() { return 1; }; wslpath() { return 1; }; cgr_posix_path "$1" ); }
is "posix fallback: single backslash separators" "$(noconv 'D:\work\x')" "/d/work/x"
is "posix fallback: doubled backslashes"          "$(noconv 'D:\\work\\x')" "/d/work/x"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    is "native: shell path -> drive path" "$(cgr_native_path '/d/work/x')" 'D:\work\x'
    ;;
  Linux)
    # WSL keeps Windows paths reachable under /mnt/<drive>; plain Linux does not.
    if [ -d /mnt/c ]; then
      is "native: /mnt/c path -> drive path" "$(cgr_native_path '/mnt/c/Users/you')" 'C:\Users\you'
    fi
    ;;
esac

echo "== identity-bound profile resolution"

ME="$(cgr_self_user || true)"
[ -n "$ME" ] && ok "cgr_self_user resolves an account name ($ME)" \
              || bad "cgr_self_user resolves an account name" "returned empty"

H="$(cgr_home)"
[ -d "$H" ] && ok "cgr_home points at an existing directory" \
            || bad "cgr_home points at an existing directory" "got '$H'"
case "$H" in
  */AppData|*/AppData/*) bad "cgr_home is a profile, not an AppData subdir" "got '$H'" ;;
  *) ok "cgr_home is a profile, not an AppData subdir" ;;
esac

# A wildcard over other accounts' homes is the bug this kit was audited for:
# the first interpreter found gets executed as this user.
ROOTS="$(cgr_tool_roots)"
case "$ROOTS" in
  *'Users/*'*) bad "tool roots contain no cross-user wildcard" "got: $ROOTS" ;;
  *) ok "tool roots contain no cross-user wildcard" ;;
esac

if [ -n "$ME" ]; then
  case "$ROOTS" in
    *"/Users/"*) # every Users path present must be this account's
      STRANGERS="$(printf '%s\n' "$ROOTS" | grep '/Users/' | grep -v "/Users/$ME/" | head -3)"
      [ -z "$STRANGERS" ] && ok "no other account's uv root is searched" \
                          || bad "no other account's uv root is searched" "got: $STRANGERS"
      ;;
    *) ok "no other account's uv root is searched" ;;
  esac
fi

echo "== fail-closed behaviour"

CGR_TOOL_NAME=cgr-does-not-exist cgr_tool_python >/dev/null 2>&1
no "cgr_tool_python fails when the tool venv is absent" "$?" "it returned success without a venv"

OUT="$(CGR_TOOL_NAME=cgr-does-not-exist bash "$KIT/scripts/hf-login.sh" 2>&1)"
RC=$?
no "hf-login.sh exits non-zero without a tool venv" "$RC"
has "hf-login.sh explains the failure" "$OUT" "tool venv python not found"

OUT="$(CGR_TOOL_NAME=cgr-does-not-exist bash "$KIT/scripts/install.sh" 2>&1)"
RC=$?
case "$RC" in
  0) bad "install.sh does not claim success without a tool venv" "exit 0" ;;
  *) ok "install.sh does not claim success without a tool venv" ;;
esac

echo "== python helper"

PY="$(command -v python3 || command -v python || true)"
if [ -n "$PY" ]; then
  # python is a NATIVE binary: /d/... is not a path it can open.
  HF_PY="$(cgr_native_path "$KIT/scripts/_hf.py")"
  # Compile to a scratch .pyc so a test run never leaves __pycache__ in the repo.
  PYC="$(cgr_native_path "${TMPDIR:-/tmp}")/cgr-hf-check.pyc"
  "$PY" -c 'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
      "$HF_PY" "$PYC" && ok "scripts/_hf.py compiles" \
    || bad "scripts/_hf.py compiles" "py_compile failed"
  OUT="$("$PY" "$HF_PY" path 2>&1 | tr -d '\r')"
  case "$OUT" in
    *huggingface*) ok "_hf.py path prints the token path" ;;
    *) bad "_hf.py path prints the token path" "got: $OUT" ;;
  esac
else
  printf '  skip python checks (no python3 on PATH)\n'
fi

echo "== install PATH comparison"

# install.sh compares cgr_shim_dir against $PATH. On MSYS the shim dir comes back
# native (C:\Users\...) while $PATH holds /c/Users/..., so the raw comparison told
# every Windows user to add a directory that was already on PATH. Guard the
# conversion, not the machine-specific value.
SHIM="$(cgr_shim_dir)"
SHIM_POSIX="$(cgr_posix_path "$SHIM")"
case "$SHIM_POSIX" in
  *\*) bad "shim dir converts to shell form for the PATH check" "still native: $SHIM_POSIX" ;;
  *)    ok  "shim dir converts to shell form for the PATH check" ;;
esac
is "shim dir conversion is stable" "$(cgr_posix_path "$SHIM_POSIX")" "$SHIM_POSIX"

echo "== workspace mode"

# init-workspace.sh decides what the graph can see: one project per repo, or the
# whole root as one project. Drive it against a stub cgr that records argv, so the
# assertion is about the command it builds, not about a 25-project index.
WSROOT="$(cgr_posix_path "${TMPDIR:-/tmp}")/cgr-ws-mode"
rm -rf "$WSROOT"; mkdir -p "$WSROOT/corpus/proj_a/.git" "$WSROOT/corpus/proj_b" "$WSROOT/bin"
: > "$WSROOT/corpus/proj_b/package.json"
: > "$WSROOT/calls.log"
cat > "$WSROOT/bin/cgr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CGR_CALLS"
# `workspace show` is the existence probe: exit non-zero and print nothing when
# CGR_SHOW names no file, so a fresh workspace looks fresh.
if [ "${1:-}" = workspace ] && [ "${2:-}" = show ]; then
  [ -n "${CGR_SHOW:-}" ] && [ -f "$CGR_SHOW" ] || exit 1
  cat "$CGR_SHOW"
fi
exit 0
STUB
chmod +x "$WSROOT/bin/cgr"
export CGR_CALLS="$WSROOT/calls.log"

CGR_BIN="$WSROOT/bin/cgr" bash "$KIT/scripts/init-workspace.sh" wsproj "$WSROOT/corpus" >/dev/null 2>&1
ADDS="$(count 'workspace add-repo' "$WSROOT/calls.log")"
is "default mode adds one repo per project" "$ADDS" "2"

: > "$WSROOT/calls.log"
CGR_BIN="$WSROOT/bin/cgr" bash "$KIT/scripts/init-workspace.sh" wsroot "$WSROOT/corpus" --root >/dev/null 2>&1
ADDS="$(count 'workspace add-repo' "$WSROOT/calls.log")"
is "--root adds exactly one repo" "$ADDS" "1"
has "--root registers the root itself, not a child" "$(grep 'workspace add-repo' "$WSROOT/calls.log" || true)" "corpus"
case "$(grep 'workspace add-repo' "$WSROOT/calls.log" || true)" in
  *proj_a*|*proj_b*) bad "--root does not fall back to per-project entries" "got a child path" ;;
  *)                 ok  "--root does not fall back to per-project entries" ;;
esac
# A custom -p would desync the graph project name from the hash-cache directory,
# which cgr always derives from the path.
case "$(grep 'workspace add-repo' "$WSROOT/calls.log" || true)" in
  *' -p '*) bad "--root lets cgr derive the project name" "passed -p" ;;
  *)        ok  "--root lets cgr derive the project name" ;;
esac

OUT="$(CGR_BIN="$WSROOT/bin/cgr" bash "$KIT/scripts/init-workspace.sh" wsbad "$WSROOT/corpus" --root proj_a 2>&1)"
no "--root with an explicit project list is rejected" "$?" "$OUT"

# Re-laying an existing workspace would index every file twice under two namespaces
# (the old project rows stay in the graph), so it must be refused, not overwritten.
printf '%s\n' 'proj_a' 'proj_b' > "$WSROOT/existing.txt"
: > "$WSROOT/calls.log"
OUT="$(CGR_SHOW="$WSROOT/existing.txt" CGR_BIN="$WSROOT/bin/cgr" \
       bash "$KIT/scripts/init-workspace.sh" wsroot "$WSROOT/corpus" --root 2>&1)"
no "an existing workspace is refused without --force" "$?" "$OUT"
is "the refusal writes nothing" "$(count 'workspace add-repo' "$WSROOT/calls.log")" "0"
has "the refusal names the existing repos" "$OUT" "proj_b"

: > "$WSROOT/calls.log"
CGR_SHOW="$WSROOT/existing.txt" CGR_BIN="$WSROOT/bin/cgr" \
  bash "$KIT/scripts/init-workspace.sh" wsroot "$WSROOT/corpus" --root --force >/dev/null 2>&1
is "--force replaces the layout" "$(count 'workspace add-repo' "$WSROOT/calls.log")" "1"

rm -rf "$WSROOT"

echo "== index.sh stays non-interactive"

# cgr 0.5.0 syncs a workspace with `start --workspace X --update-graph` and then
# STARTS THE ASSISTANT, which is fatal for a background job (the assistant
# validates an LLM provider and exits non-zero after a good sync). index.sh must
# therefore sync per repo with --repo-path, under the project_name the workspace
# file recorded. Stub cgr again, so the assertion is about the argv it builds.
IDXROOT="$(cgr_posix_path "${TMPDIR:-/tmp}")/cgr-index-mode"
rm -rf "$IDXROOT"; mkdir -p "$IDXROOT/home/workspaces" "$IDXROOT/bin"
: > "$IDXROOT/calls.log"
printf '%s\n' \
  '[workspace]' 'name = "wsidx"' '' \
  '[[workspace.repos]]' 'path = "C:\\work\\api"' 'project_name = "api__1a2b3c4d"' 'project_named = false' '' \
  '[[workspace.repos]]' 'path = "C:\\work\\web"' 'project_name = "web__5e6f7a8b"' 'project_named = false' \
  > "$IDXROOT/home/workspaces/wsidx.toml"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$CGR_CALLS"\nexit "${STUB_EXIT:-0}"\n' > "$IDXROOT/bin/cgr"
chmod +x "$IDXROOT/bin/cgr"
export CGR_CALLS="$IDXROOT/calls.log"

CGR_HOME="$IDXROOT/home" CGR_BIN="$IDXROOT/bin/cgr" bash "$KIT/scripts/index.sh" wsidx >/dev/null 2>&1
yes "index.sh exits 0 on a stubbed sync" "$?"
is "one cgr start per repo" "$(count '^start ' "$IDXROOT/calls.log")" "2"
CALLS="$(cat "$IDXROOT/calls.log")"
case "$CALLS" in
  *--workspace*) bad "no workspace-mode sync (it starts the assistant)" ;;
  *)             ok  "no workspace-mode sync (it starts the assistant)" ;;
esac
has "each repo is synced in repo mode under its recorded name" "$CALLS" \
    "--repo-path C:/work/api --project-name api__1a2b3c4d"
case "$CALLS" in
  *'C:\work'*) bad "toml backslashes are unescaped before use" "got doubled separators" ;;
  *)           ok  "toml backslashes are unescaped before use" ;;
esac
is "every repo is asked to update the graph" \
   "$(printf '%s\n' "$CALLS" | grep -c -- '--update-graph')" "2"

: > "$IDXROOT/calls.log"
STUB_EXIT=1 CGR_HOME="$IDXROOT/home" CGR_BIN="$IDXROOT/bin/cgr" bash "$KIT/scripts/index.sh" wsidx >/dev/null 2>&1
no "a failed repo makes index.sh fail" "$?"

OUT="$(CGR_HOME="$IDXROOT/home" CGR_BIN="$IDXROOT/bin/cgr" bash "$KIT/scripts/index.sh" nope 2>&1)"
no "unknown workspace is an error, not a silent no-op" "$?"
has "the error names the workspace file" "$OUT" "nope.toml"

rm -rf "$IDXROOT"

echo "== audit-workspace.py reads the graph, not the hash cache"

# A sync that dies after writing its hash cache leaves state/<project>/ behind but
# no nodes, so "the folder exists" is not proof of anything. The audit builds a
# tiny graph with the same schema and checks each verdict: parsed code, a language
# cgr has no parser for, and a repo with nothing at all.
AUROOT="$(cgr_posix_path "${TMPDIR:-/tmp}")/cgr-audit"
AUNATIVE="$(cgr_native_path "$AUROOT")"
AUTOML="${AUNATIVE//\\//}"   # python and sqlite need the native form; TOML reads /
rm -rf "$AUROOT"; mkdir -p "$AUROOT/home/workspaces" "$AUROOT/good" "$AUROOT/site/docs"
printf 'def f():\n    pass\n' > "$AUROOT/good/a.py"
printf -- '---\ntitle: x\n---\nbody\n' > "$AUROOT/site/p.astro"
printf 'notes\n' > "$AUROOT/site/docs/n.md"
printf '%s\n' \
  '[workspace]' 'name = "wsau"' '' \
  '[[workspace.repos]]' "path = \"$AUTOML/good\"" 'project_name = "good__aaaa1111"' 'project_named = false' '' \
  '[[workspace.repos]]' "path = \"$AUTOML/site\"" 'project_name = "site__bbbb2222"' 'project_named = false' '' \
  '[[workspace.repos]]' "path = \"$AUTOML/ghost\"" 'project_name = "ghost__cccc3333"' 'project_named = false' \
  > "$AUROOT/home/workspaces/wsau.toml"

PY=""
for cand in python3 python; do
  command -v "$cand" >/dev/null 2>&1 && { PY="$cand"; break; }
done
if [ -n "$PY" ]; then
  "$PY" - "$AUNATIVE" <<'PYEOF'
import sqlite3, sys
root = sys.argv[1]
con = sqlite3.connect(f"{root}/home/graph.sqlite")
con.execute("create table cgr_nodes (id integer primary key, label text, key text, props text)")
con.execute("create table cgr_edges (id integer primary key, src integer, dst integer, type text, props text)")
nodes = [
    ("Project", "good__aaaa1111"),
    ("File", f"{root}/good/a.py"),
    ("Function", "good__aaaa1111.a.f"),
    ("Module", "site__bbbb2222.astro.config"),
    ("File", f"{root}/site/p.astro"),
    ("File", f"{root}/site/docs/n.md"),
]
con.executemany("insert into cgr_nodes (label, key) values (?,?)", nodes)
con.executemany("insert into cgr_edges (src, dst, type) values (?,?,?)", [(3, 2, "DEFINES")])
con.commit()
PYEOF
  AUOUT="$(cd "$KIT" && CGR_HOME="$AUNATIVE/home" "$PY" scripts/audit-workspace.py wsau 2>&1)"
  no "audit exits 1 when a declared repo has no nodes" "$?" "$AUOUT"
  has "audit counts the parsed repo" "$AUOUT" "good__aaaa1111"
  has "audit names the repo with no nodes" "$AUOUT" "ghost__cccc3333"
  has "audit recognises a language cgr cannot parse" "$AUOUT" "HAS NO PARSER"
  has "audit reports totals" "$AUOUT" "declared: 3  with nodes: 2  missing: 1"
else
  bad "audit-workspace.py needs python3" "no python on PATH"
fi

rm -rf "$AUROOT"

echo "== register-mcp.sh gives the writer entry only when asked"

# --read-only hides annotate (26 of 37 tools), so a note can never be written through
# that server. --with-writer adds cgr-write without the flag; the stub hermes records
# the argv so the assertion is about what the script builds, not about hermes.
RMROOT="$(cgr_posix_path "${TMPDIR:-/tmp}")/cgr-regmcp"
rm -rf "$RMROOT"; mkdir -p "$RMROOT/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "$HERMES_CALLS"\nexit 0\n' > "$RMROOT/bin/hermes"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RMROOT/bin/cgr"
chmod +x "$RMROOT/bin/hermes" "$RMROOT/bin/cgr"
export HERMES_CALLS="$RMROOT/calls.log"

: > "$HERMES_CALLS"
PATH="$RMROOT/bin:$PATH" LLM_ENDPOINT=http://gw/v1 LLM_MODEL=m LLM_API_KEY=k \
  bash "$KIT/scripts/register-mcp.sh" wsread /repo >/dev/null 2>&1
CALLS="$(cat "$HERMES_CALLS")"
is "one registration without --with-writer" "$(count 'mcp add' "$HERMES_CALLS")" "1"
case "$CALLS" in
  *'--read-only'*) ok "the default registration is read-only" ;;
  *)               bad "the default registration is read-only" "no --read-only in argv" ;;
esac
case "$CALLS" in
  *cgr-write*) bad "no writer entry unless asked" "saw cgr-write" ;;
  *)           ok  "no writer entry unless asked" ;;
esac

: > "$HERMES_CALLS"
PATH="$RMROOT/bin:$PATH" LLM_ENDPOINT=http://gw/v1 LLM_MODEL=m LLM_API_KEY=k \
  bash "$KIT/scripts/register-mcp.sh" wsread /repo --with-writer >/dev/null 2>&1
is "--with-writer registers a second server" "$(count 'mcp add' "$HERMES_CALLS")" "2"
has "the writer entry is named cgr-write" "$(grep 'cgr-write' "$HERMES_CALLS" || true)" "mcp add cgr-write"
case "$(grep 'cgr-write' "$HERMES_CALLS" || true)" in
  *'--read-only'*) bad "the writer entry drops --read-only" "flag still present" ;;
  *)               ok  "the writer entry drops --read-only" ;;
esac
case "$(grep 'cgr-write' "$HERMES_CALLS" || true)" in
  *MCP_READ_ONLY*) bad "the writer entry drops MCP_READ_ONLY" "env var still present" ;;
  *)               ok  "the writer entry drops MCP_READ_ONLY" ;;
esac

rm -rf "$RMROOT"

echo "== portability rules"

# The author's own machine must not be in the scripts. Comments are excluded:
# this check documents itself and would otherwise flag its own examples.
ABSHITS="$(grep -rInE '(/c/Users/[A-Za-z0-9._-]+|/mnt/c/Users/[A-Za-z0-9._-]+|[Cc]:\\\\+Users\\\\+[A-Za-z0-9._-]+)' \
             "$KIT/scripts" 2>/dev/null \
           | grep -vE ':[0-9]+:[[:space:]]*#' \
           | grep -vE 'cgr_home|USERPROFILE|/c/Users/\$|/c/Users/you|/mnt/c/Users/\$' \
           | head -3)"
[ -z "$ABSHITS" ] && ok "no hardcoded home path in scripts/" \
                  || bad "no hardcoded home path in scripts/" "got: $ABSHITS"

if [ -d "$KIT/.git" ] && command -v git >/dev/null 2>&1; then
  TRACKED="$(cd "$KIT" && git ls-files 2>/dev/null)"
  JUNK="$(printf '%s\n' "$TRACKED" | grep -E '(^|/)__pycache__/|\.pyc$|\.sqlite$|(^|/)\.env' | head -3)"
  [ -z "$JUNK" ] && ok "no build artifacts or env files tracked" \
                 || bad "no build artifacts or env files tracked" "got: $JUNK"
  SH_CRLF="$(cd "$KIT" && git ls-files --eol -- '*.sh' 2>/dev/null | grep -v 'w/lf' | head -3)"
  [ -z "$SH_CRLF" ] && ok "tracked shell scripts are LF" \
                    || bad "tracked shell scripts are LF" "got: $SH_CRLF"
fi

echo "== warm client and section patch"

# Both are pure Python, so they must compile and answer without a graph present:
# a smoke test that needs a 25-project index is a test nobody runs.
if command -v python >/dev/null 2>&1; then
  # A Windows python cannot open an MSYS path: /d/x becomes C:/Program Files/Git/d/x.
  nat() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
  if python -m py_compile "$(nat "$KIT/scripts/cgrq.py")" "$(nat "$KIT/scripts/patch-sections.py")" 2>/dev/null; then
    ok "cgrq.py and patch-sections.py compile"
  else
    bad "cgrq.py and patch-sections.py compile" "py_compile failed"
  fi
  # 0 = patched, 1 = stock, 2 = package missing. Anything above 1 is a crash.
  python "$(nat "$KIT/scripts/patch-sections.py")" --check >/dev/null 2>&1
  CHECK_CODE=$?
  if [ "$CHECK_CODE" -le 1 ]; then
    ok "patch-sections.py --check answers without a graph"
  else
    bad "patch-sections.py --check answers without a graph" "exit $CHECK_CODE"
  fi
  for CMD in 'if a.command == "find":' 'cmd_stale()' 'if a.command in ("stale", "fresh"):'; do
    grep -qF "$CMD" "$KIT/scripts/cgrq.py" \
      && ok "cgrq wires: $CMD" || bad "cgrq wires: $CMD" "missing from cgrq.py"
  done
  # `project_named = false` follows `project_name` in the workspace toml; a naive
  # startswith() read it as the name and reported every repo as "false".
  grep -qF '.split("=", 1)[0].strip() == "project_name"' "$KIT/scripts/cgrq.py" \
    && ok "cgrq reads project_name exactly, not project_named" \
    || bad "cgrq reads project_name exactly, not project_named" "prefix match regressed"
else
  bad "python present for the warm client and section patch" "python not on PATH"
fi

echo
printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
