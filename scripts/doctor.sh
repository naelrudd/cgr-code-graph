#!/usr/bin/env bash
# Preflight check for cgr-code-graph. Run this BEFORE a multi-hour index: every
# check below corresponds to a failure that costs hours to diagnose mid-run.
#
#   bash scripts/doctor.sh                 # environment only
#   bash scripts/doctor.sh D:/work         # also inspect a corpus root
#   bash scripts/doctor.sh --quiet D:/work # only problems
#
# Exit 0 = no failures. Exit 1 = at least one FAIL (a WARN never fails the run).
set -uo pipefail

QUIET=0
if [ "${1:-}" = "--quiet" ]; then QUIET=1; shift; fi
ROOT="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
. "$SCRIPT_DIR/_common.sh"
HOME_U="$(cgr_home)"

TOOL_NAME="${CGR_TOOL_NAME:-code-graph-rag}"
PASS=0; WARN=0; FAIL=0

if [ -t 1 ] && [ "$QUIET" = 0 ]; then
  C_PASS=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_PASS=''; C_WARN=''; C_FAIL=''; C_DIM=''; C_OFF=''
fi

hdr()  { [ "$QUIET" = 1 ] || printf '\n%s== %s%s\n' "$C_DIM" "$1" "$C_OFF"; }
pass() { PASS=$((PASS+1)); [ "$QUIET" = 1 ] || printf '  %sPASS%s %s\n' "$C_PASS" "$C_OFF" "$1"; }
warn() { WARN=$((WARN+1)); printf '  %sWARN%s %s\n' "$C_WARN" "$C_OFF" "$1"; [ -n "${2:-}" ] && printf '       fix: %s\n' "$2"; return 0; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s %s\n' "$C_FAIL" "$C_OFF" "$1"; [ -n "${2:-}" ] && printf '       fix: %s\n' "$2"; return 0; }

native_path() {
  if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

hdr "platform"

OS_KIND="linux"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) OS_KIND="windows-msys" ;;
  Darwin)               OS_KIND="darwin" ;;
  Linux)                OS_KIND="linux" ;;
esac
case "$OS_KIND" in
  windows-msys) pass "git-bash on Windows (paths must be converted with cygpath for cgr.exe)" ;;
  *)            pass "platform: $OS_KIND" ;;
esac

if [ "$OS_KIND" = "windows-msys" ] && ! command -v cygpath >/dev/null 2>&1; then
  fail "cygpath missing — cannot convert MSYS paths for the native binary" \
       "cgr.exe cannot resolve /d/work style paths; set CGR_BIN to a POSIX-aware build or use native paths everywhere"
fi

hdr "prerequisites"

if command -v uv >/dev/null 2>&1; then
  pass "uv $(uv --version 2>/dev/null | awk '{print $2}')"
else
  # uv is only needed to install or repair; an existing tool venv (common when
  # the Windows install is being driven from WSL) makes it non-fatal.
  if cgr_tool_python >/dev/null 2>&1; then
    warn "uv not on PATH here, but an installed cgr tool venv was found — installing/repairing needs uv" \
         "install uv: https://docs.astral.sh/uv/"
  else
    fail "uv not found — nothing else can be installed" "install uv: https://docs.astral.sh/uv/"
  fi
fi

CGR="${CGR_BIN:-cgr}"
CGR_ABS=""
if command -v "$CGR" >/dev/null 2>&1; then
  CGR_ABS="$(command -v "$CGR")"
else
  # uv puts tool shims in a dir that is often not on PATH in scripts/CI.
  for cand in "$(cgr_shim_dir)/$CGR" "$(cgr_shim_dir)/$CGR.exe" \
              "$HOME_U/.local/bin/$CGR" "$HOME_U/.local/bin/$CGR.exe"; do
    [ -x "$cand" ] && { CGR_ABS="$cand"; break; }
  done
fi
if [ -n "$CGR_ABS" ]; then
  pass "cgr at $CGR_ABS ($("$CGR_ABS" --version 2>/dev/null | head -1 | tr -d '\r'))"
  case ":$PATH:" in
    *":$(dirname "$CGR_ABS"):"*) ;;
    *) warn "cgr's directory is not on PATH — bare 'cgr' will fail in a fresh shell" \
            "add $(dirname "$CGR_ABS") to PATH, or keep using CGR_BIN=$CGR_ABS" ;;
  esac
else
  fail "cgr not found (neither on PATH nor in \$(uv tool dir --bin))" \
       "run scripts/install.sh, then add \$(uv tool dir --bin) to PATH"
  CGR="cgr"
fi

TOOL_PY="$(cgr_tool_python || true)"
if [ -n "$TOOL_PY" ]; then
  pass "tool venv python: $TOOL_PY"
  TOOL_ROOT="$(dirname "$(dirname "$TOOL_PY")")"
  TOOL_DIR="$TOOL_ROOT/$TOOL_NAME"
else
  TOOL_ROOT="$(cgr_tool_roots | head -1)"
  TOOL_DIR="$TOOL_ROOT/$TOOL_NAME"
  fail "tool venv not found (searched $(cgr_tool_roots | tr '\n' ' '))" \
       "uv tool install \"$TOOL_NAME[treesitter-full,sqlite-vec,ast-grep]\""
fi

py_has() { [ -x "$TOOL_PY" ] && "$TOOL_PY" -c "import $1" >/dev/null 2>&1; }
py_ver() { "$TOOL_PY" -c "import importlib.metadata as m; print(m.version('$1'))" 2>/dev/null | tr -d '\r'; }
py_fix() { uv pip install --python "$TOOL_PY" "$1"; }

if [ -x "$TOOL_PY" ]; then
  if py_has httpx; then pass "httpx present (the wheel omits it; a missing one breaks every command)"
  else fail "httpx missing from the tool venv — every cgr command will die with ModuleNotFoundError" \
            "uv pip install --python \"$TOOL_PY\" httpx"; fi

  if py_has torch && py_has transformers; then
    pass "torch $(py_ver torch) + transformers $(py_ver transformers) present (local embeddings)"
  else
    warn "torch/transformers missing — only hosted embeddings would work, and those die on quota mid-ingest" \
         "uv pip install --python \"$TOOL_PY\" 'torch>=2.6.0' 'transformers>=5.0.0' (~1 GB)"
  fi

  if py_has ast_grep_py; then pass "ast-grep extra present (shell/nix files parse as real nodes)"
  else warn "ast-grep extra missing — bash/nix files land in the graph as bare File nodes" \
            "uv pip install --python \"$TOOL_PY\" ast-grep-py"; fi
fi

hdr "resources"

CGR_HOME="${CGR_HOME:-$HOME_U/.cgr}"
if [ -d "$CGR_HOME" ]; then
  pass "graph home: $CGR_HOME"
else
  warn "graph home $CGR_HOME does not exist yet (created on first sync)"
fi
mkdir -p "$CGR_HOME" 2>/dev/null
if [ -w "$CGR_HOME" ]; then pass "$CGR_HOME writable"; else fail "$CGR_HOME not writable" "chown/chmod it, or set CGR_HOME elsewhere"; fi

# Disk: the graph itself stays small, but the graph + vectors + WAL for tens of
# thousands of nodes wants ~1 GB of headroom; torch and the model want ~1.5 GB.
if command -v df >/dev/null 2>&1; then
  AVAIL_KB="$(df -Pk "$CGR_HOME" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ -n "${AVAIL_KB:-}" ]; then
    AVAIL_GB=$((AVAIL_KB / 1048576))
    if   [ "$AVAIL_GB" -ge 3 ]; then pass "${AVAIL_GB} GB free on the graph volume"
    elif [ "$AVAIL_GB" -ge 1 ]; then warn "only ${AVAIL_GB} GB free on the graph volume — a large corpus plus SQLite WAL can fill that" \
                                         "free space before starting a multi-hour sync"
    else fail "only ${AVAIL_GB} GB free on the graph volume" "free space first; a mid-run disk-full leaves a partial graph"; fi
  fi
fi

# Embedding is CPU-bound; the model wants ~1.5 GB RAM while it runs.
# /proc/meminfo inside WSL reports the VM's limit, not the machine's RAM, so ask
# Windows first whenever a Windows powershell is reachable.
MEM_GB=""
if command -v powershell.exe >/dev/null 2>&1; then
  MEM_GB="$(powershell.exe -NoProfile -Command "[math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory/1GB,0)" 2>/dev/null < /dev/null | tr -cd '0-9')"
fi
if [ -z "${MEM_GB:-}" ] && [ -r /proc/meminfo ]; then
  MEM_GB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1048576 ))
fi
if [ -n "${MEM_GB:-}" ] && [ "$MEM_GB" -gt 0 ] 2>/dev/null; then
  if [ "$MEM_GB" -ge 8 ]; then pass "${MEM_GB} GB RAM (embedding runs on CPU)"
  elif [ "$MEM_GB" -ge 4 ]; then warn "${MEM_GB} GB RAM — local embeddings will work but swap is likely on a large corpus"
  else warn "${MEM_GB} GB RAM is tight for local embeddings"; fi
fi

hdr "state"

# Shell redirection to a Windows path from WSL/MSYS bash does not fail: it
# creates a file whose NAME is "C:Usersyou.cachehuggingfacetoken" in the current
# directory. That is how a plaintext token ends up sitting inside a repo.
STRAYF="$("$TOOL_PY" - "$(cgr_native_path "$(pwd)")" <<'PY' 2>/dev/null || true
import os, sys
try:
    names = os.listdir(sys.argv[1])
except OSError:
    raise SystemExit(0)
bad = [n for n in names if n.startswith("C:") or (n.startswith("C") and "Users" in n)]
print("\n".join(bad))
PY
)"
if [ -n "${STRAYF//[$'\r\n ']/}" ]; then
  warn "file(s) in $(pwd) look like a Windows path used as a filename: $(printf '%s' "$STRAYF" | tr '\n' ' ')" \
       "shell redirection to C:\\... from this shell creates junk files here - they may hold secrets; delete them"
else
  pass "no stray Windows-path filenames in $(pwd)"
fi

# Stray syncs are the single most common cause of a "hung" build.
STRAY=""
if [ "$OS_KIND" = "windows-msys" ]; then
  PS="$(command -v powershell.exe || echo /c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe)"
  STRAY="$("$PS" -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { \$_.CommandLine -like '*cgr*' } | ForEach-Object { \$_.ProcessId }" 2>/dev/null | tr -d '\r')"
elif command -v pgrep >/dev/null 2>&1; then
  STRAY="$(pgrep -f 'cgr.*start' 2>/dev/null)"
fi
STRAY_N="$(printf '%s' "$STRAY" | tr -s '[:space:]' '\n' | grep -c '[0-9]' || true)"
if [ "${STRAY_N:-0}" -eq 0 ]; then
  pass "no cgr processes running"
else
  warn "$STRAY_N cgr process(es) running (pids: $(printf '%s' "$STRAY" | tr -s '[:space:]' ' ')) — two syncs sharing graph.sqlite make both crawl" \
       "let a single sync finish, or kill the strays before starting another"
fi

if [ -f "$CGR_HOME/graph.sqlite-wal" ]; then
  WAL_MB=$(( $(wc -c < "$CGR_HOME/graph.sqlite-wal") / 1048576 ))
  if [ "$WAL_MB" -ge 200 ]; then
    warn "graph.sqlite-wal is ${WAL_MB} MB — a sync was interrupted; the next one replays it" \
         "safe to continue; a checkpoint happens on the next clean sync"
  else
    pass "graph.sqlite-wal is ${WAL_MB} MB (normal)"
  fi
fi

if [ -d "$CGR_HOME/workspaces" ]; then
  WS_LIST="$(ls "$CGR_HOME/workspaces"/*.toml 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$WS_LIST" -gt 0 ]; then
    pass "$WS_LIST workspace definition(s) in $CGR_HOME/workspaces"
    for f in "$CGR_HOME/workspaces"/*.toml; do
      [ -f "$f" ] || continue
      MISSING=0; TOTAL=0
      while IFS= read -r p; do
        case "$p" in
          *path*=*)
            P="${p#*\"}"; P="${P%\"*}"
            [ -n "$P" ] || continue
            TOTAL=$((TOTAL+1))
            # The workspace file stores native paths (D:\\work\\myrepo); this shell
            # may be git-bash (/d/work/myrepo) or WSL (/mnt/d/work/myrepo).
            PB="$(cgr_posix_path "$P")"
            [ -d "$PB" ] || [ -d "$P" ] || MISSING=$((MISSING+1))
            ;;
        esac
      done < "$f"
      if [ "$MISSING" -gt 0 ]; then
        warn "$(basename "$f"): $MISSING of $TOTAL repo path(s) no longer exist — a moved or renamed project leaves a silently empty part of the graph" \
             "cgr workspace add-repo <name> <new path>  (or remove-repo the dead one)"
      else
        pass "$(basename "$f"): all $TOTAL repo path(s) present"
      fi
    done
  fi
fi

if [ -f "$CGR_HOME/graph.sqlite" ]; then
  CN="$("$TOOL_PY" - <<'PY' 2>/dev/null || true
import os, sqlite3
p = os.path.join(os.path.expanduser("~"), ".cgr", "graph.sqlite")
try:
    c = sqlite3.connect("file:" + p + "?mode=ro", uri=True)
    print(c.execute("select count(*) from cgr_nodes").fetchone()[0])
except Exception:
    print("")
PY
)"
  if [ -n "${CN//[$'\r\n ']/}" ]; then pass "graph.sqlite holds $CN nodes"; fi
fi

hdr "kit portability"

# A kit that only works on the machine it was written on is not a kit. Catch the
# usual regressions: a hardcoded user name or an absolute home path in a script.
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ME="$(basename "$HOME_U")"
if [ -d "$KIT_DIR/scripts" ] && [ -n "$ME" ]; then
  HITS="$(grep -rIn --include='*.sh' --include='*.py' -F "$ME" "$KIT_DIR/scripts" 2>/dev/null | grep -v '^\s*#' | head -3)"
  if [ -n "$HITS" ]; then
    warn "scripts/ hardcodes the current user name '$ME' — it will break on another machine" \
         "resolve paths from \$HOME / \$USERPROFILE (see scripts/_common.sh)"
  else
    pass "no hardcoded user name in scripts/"
  fi
  ABSHITS="$(grep -rIn --include='*.sh' --include='*.py' -E '(/c/Users/[A-Za-z0-9._-]+|/mnt/c/Users/[A-Za-z0-9._-]+|[Cc]:\\+Users\\+[A-Za-z0-9._-]+)' "$KIT_DIR/scripts" 2>/dev/null \
            | grep -vE ':[0-9]+:[[:space:]]*#' \
            | grep -v 'cgr_home\|USERPROFILE\|/c/Users/\*\|/c/Users/you' | head -3)"
  if [ -n "$ABSHITS" ]; then
    warn "scripts/ contains an absolute home path — hardcoded to one machine" \
         "use \$HOME / \$USERPROFILE and cgr_native_path / cgr_posix_path"
  else
    pass "no absolute home path in scripts/"
  fi
fi


if command -v hermes >/dev/null 2>&1; then
  pass "hermes CLI present"
  CFG="${LOCALAPPDATA:-}/hermes/config.yaml"
  for CFG in "$CFG" "$HOME_U/AppData/Local/hermes/config.yaml" "$HOME_U/.hermes/config.yaml" "$HOME_U/.config/hermes/config.yaml"; do
    [ -f "$CFG" ] && break
  done
  if [ -f "$CFG" ]; then
    if grep -q "TARGET_REPO_PATH" "$CFG" 2>/dev/null; then
      pass "an MCP entry sets TARGET_REPO_PATH (required: clients spawn servers from the home dir)"
    else
      warn "no TARGET_REPO_PATH in $CFG — cgr's MCP server refuses to start from a home directory, and the client only reports 'Connection closed'" \
           "bash scripts/register-mcp.sh <workspace> <root>"
    fi
    # An unreachable enabled MCP server makes /reload-mcp fail atomically for all of them.
    DEAD=""
    while IFS= read -r url; do
      [ -n "$url" ] || continue
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$url" 2>/dev/null || echo 000)"
      [ "$code" = "000" ] && DEAD="$DEAD $url"
    done < <(grep -oE 'https?://(127\.0\.0\.1|localhost):[0-9]+[^ ]*' "$CFG" 2>/dev/null | sort -u)
    if [ -n "$DEAD" ]; then
      warn "local MCP endpoint(s) not reachable:$DEAD — reload is atomic, so one dead server blocks every server's tools" \
           "hermes config set mcp_servers.<name>.enabled false"
    else
      pass "all local MCP endpoints in the config respond"
    fi
  fi
else
  warn "hermes CLI not found — any MCP client works, see scripts/register-mcp.sh for the raw stdio command"
fi

if [ -n "$ROOT" ]; then
  hdr "corpus: $ROOT"
  if [ -d "$ROOT" ]; then
    pass "root exists"
    ROOT_N="$(native_path "$ROOT")"
    if [ "$OS_KIND" = "windows-msys" ] && ! printf '%s' "$ROOT_N" | grep -qE '^[A-Za-z]:'; then
      warn "native path conversion looks wrong ($ROOT_N) — cgr silently fails to add such a repo"
    else
      pass "native path for cgr: $ROOT_N"
    fi
    if printf '%s' "$ROOT_N" | grep -qiE '^[A-Za-z]:\\\\?$|^[A-Za-z]:/$|^\$HOME$'; then
      fail "root is a drive root or home directory — cgr rejects that for MCP and the graph would span unrelated files" \
           "point at a real project folder, e.g. D:/work"
    fi

    STATS="$("$TOOL_PY" - "$ROOT_N" <<'PY' 2>/dev/null || true
import os, sys
root = sys.argv[1]
skip = {"node_modules", ".venv", "venv", ".git", "Library", "Temp", "obj", ".next",
        "dist", "build", "target", "__pycache__", "site-packages", ".cache"}
CODE = {".ts", ".tsx", ".js", ".jsx", ".py", ".go", ".rs", ".java", ".cs", ".rb", ".php",
        ".c", ".h", ".cpp", ".hpp", ".kt", ".swift", ".dart", ".scala", ".lua", ".sh"}
DOC = {".md", ".markdown"}
OTHER = {".pdf", ".docx", ".doc", ".png", ".jpg", ".jpeg", ".webp", ".mp4", ".mov", ".mkv", ".mp3", ".wav"}
n_code = n_doc = n_other = 0
token_bytes = 0
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d.lower() not in skip]
    for fn in filenames:
        ext = os.path.splitext(fn)[1].lower()
        try:
            sz = os.path.getsize(os.path.join(dirpath, fn))
        except OSError:
            continue
        if ext in CODE:
            n_code += 1; token_bytes += sz
        elif ext in DOC:
            n_doc += 1; token_bytes += sz
        elif ext in OTHER:
            n_other += 1
print(f"{n_code} {n_doc} {n_other} {token_bytes}")
PY
)"
    if [ -n "${STATS//[$'\r\n ']/}" ]; then
      set -- $STATS
      N_CODE="${1:-0}"; N_DOC="${2:-0}"; N_OTHER="${3:-0}"; BYTES="${4:-0}"
      pass "files: $N_CODE code, $N_DOC markdown, $N_OTHER other (pdf/office/image/video)"
      MB=$(awk -v b="${BYTES:-0}" 'BEGIN{ printf "%d", b/1048576 }')
      # Calibration from a measured reference run: 196 code files yielded 1,313
      # functions (6.7/file), and embeddings settle at ~1.1/s on CPU. Only
      # functions and methods get an embedding, so estimate from those.
      EST_FN=$(awk -v f="$N_CODE" 'BEGIN{ printf "%d", f*6.7 }')
      HOURS=$(awk -v n="$EST_FN" 'BEGIN{ h=n/1.1/3600; printf (h<1?"%.0f min":"%.1f h"), (h<1? h*60 : h) }')
      pass "estimated parse+embed: ~$EST_FN functions, $MB MB of source, roughly $HOURS of CPU (measured 1.1 embeddings/s, ±50%)"
      if [ "$N_OTHER" -gt 0 ]; then
        printf '  %sINFO%s %s pdf/office/image/video file(s) — cgr cannot read these; see the optional multimodal step\n' "$C_DIM" "$C_OFF" "$N_OTHER"
      fi
      if [ "$N_DOC" -gt 0 ]; then
        printf '  %sINFO%s %s markdown file(s) are indexed free as Section nodes (headings, nested)\n' "$C_DIM" "$C_OFF" "$N_DOC"
      fi
    fi
  else
    fail "root '$ROOT' is not a directory" "pass a real path, e.g. bash scripts/doctor.sh D:/work"
  fi
fi

hdr "summary"
printf '  %s%d pass%s  %s%d warn%s  %s%d fail%s\n' \
  "$C_PASS" "$PASS" "$C_OFF" "$C_WARN" "$WARN" "$C_OFF" "$C_FAIL" "$FAIL" "$C_OFF"

if [ "$FAIL" -gt 0 ]; then
  printf '  %sFix the FAIL lines above before starting a long sync.%s\n' "$C_FAIL" "$C_OFF"
  exit 1
fi
[ "$WARN" -gt 0 ] && printf '  %sWarnings are safe to continue with, but read them first.%s\n' "$C_WARN" "$C_OFF"
printf '  Ready: bash scripts/index.sh <workspace>\n'
exit 0
