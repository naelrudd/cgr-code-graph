# Windows gotchas

Five things that cost real hours, none of them obvious from the upstream docs. Every one of these was hit on Windows 11 + git-bash (MSYS) with `uv`-managed Python 3.14.

## 1. The published wheel is missing `httpx`

`uv tool install "code-graph-rag[treesitter-full,sqlite-vec]"` succeeds, then **every** command fails:

```
ModuleNotFoundError: No module named 'httpx'
```

`codebase_rag/tools/health_checker.py` imports it; neither `pyproject.toml` nor the extra pulls it in. Inject it into the tool's own venv — not your project:

```bash
uv pip install --python "$(uv tool dir)/code-graph-rag/Scripts/python.exe" httpx
```

`scripts/install.sh` does this idempotently.

## 2. The MCP server refuses to start from your home directory

MCP clients launch stdio servers with `cwd` = the user's home. `cgr mcp-server` rejects that:

```
Configuration error: The MCP server was started in C:\Users\<you>, which looks like a
home directory or drive root. Point it at a real repository, or set TARGET_REPO_PATH.
```

The symptom is a generic, misleading `Connection closed` from the client — the real message is only in the MCP stderr log. Fix: pass `TARGET_REPO_PATH=<root of your corpus>`, which is not home. `scripts/register-mcp.sh` always does.

Related: `cgr` spawns with a minimal environment in some clients, so put the absolute path to `cgr.exe` in `--command` rather than relying on `PATH`.

## 3. `ORCHESTRATOR_PROVIDER=openai` rejects custom model ids

```
Unknown openai model 'my-model'. Alternatively set OPENAI_MODEL to one of: ...
```

The `openai` provider validates the model name against a hardcoded list, so it cannot talk to a local gateway, a router, or an OpenAI-compatible proxy. Use the generic proxy provider instead — it validates by hitting `<endpoint>/health`, then `/v1/models`:

```bash
export ORCHESTRATOR_PROVIDER=litellm_proxy ORCHESTRATOR_MODEL=<model-id>
export ORCHESTRATOR_ENDPOINT=http://127.0.0.1:<port>/v1 ORCHESTRATOR_API_KEY=<key>
export CYPHER_PROVIDER=litellm_proxy     CYPHER_MODEL=<model-id>
export CYPHER_ENDPOINT=http://127.0.0.1:<port>/v1 CYPHER_API_KEY=<key>
```

Graph building and the deterministic tools (semantic search, callers, duplicates, endpoints) need **none** of this. Only `ask_agent` and NL→Cypher do.

## 4. Hosted embedders are the wrong default for bulk ingest

For ingest specifically, a hosted embedder loses to the local one on every axis that matters:

| option | why it fails at scale |
| --- | --- |
| free tier of a hosted API | `429 ... limit: 30000 tokens/min`, `100 requests/min` — dies mid-ingest |
| same, through an OpenAI-compatible local router | router omitted `index` on the first item → `response is malformed: 'index'` |
| NVIDIA-hosted embed models | batch rejected with `500 service inference failed`; one input per request only |
| **local UniXcoder (default)** | ~1.1 chunk/s on CPU, no quota, no cost, works offline |

Keep a hosted embedder for *query* embedding and reranking if you like; use local for the ingest. Only set `CGR_EMBEDDING_PROVIDER=openai` for a small pilot against a paid endpoint.

If you previously exported OpenAI-ish variables for something else, unset them before indexing or cgr will prefer them:

```bash
unset CGR_EMBEDDING_PROVIDER OPENAI_EMBEDDING_BASE_URL OPENAI_EMBEDDING_MODEL   OPENAI_EMBEDDING_API_KEY OPENAI_BASE_URL OPENAI_API_KEY
```

## 5. `hermes mcp add` silently cancels registration

The command connects, lists the tools, then asks:

```
Enable all 25 tools? [Y/n/select]
```

With stdin closed or piped empty (the normal case in a script, CI, or an agent shell) it gets EOF, defaults to cancel, and prints a cheerful summary — **nothing is saved**. Feed it explicitly:

```bash
printf 'y\n' | hermes mcp add cgr ...
```

Then `hermes mcp test cgr` to confirm. And note: an *already running* agent session will not see new MCP tools — reload it (`/reload-mcp`) or start a new session. This is true of every MCP client, and it is the most common "the tools don't exist" report.

## 6. One dead local server blocks `/reload-mcp` for all of them

Hermes reconciles MCP servers atomically. If any **enabled** server is unreachable — a local app that you closed, e.g. a `http://127.0.0.1:<port>/mcp` entry — the reload aborts with one opaque line:

```
❌ MCP reload failed: mcp_servers_unavailable
```

It names nothing, and the new server's tools never appear, which looks like the new server's fault. Diagnose by probing each configured endpoint, then disable the dead one:

```bash
curl -s -o /dev/null -w "%{http_code}\n" --max-time 4 http://127.0.0.1:4519/mcp   # 000 = nothing listening
hermes config set mcp_servers.<name>.enabled false
```

There is no `hermes mcp disable`, and agents cannot edit `config.yaml` directly (`Refusing to write to Hermes config file ... security-sensitive`), so `hermes config set` is the only path. Re-enable with `enabled true` once the app is running again.

## 7. A launcher that re-parses your command line expands the globs

`--exclude '**/node_modules/**'` is correct and works when you type it. Pass the same command through a wrapper that re-splits the string — a background job runner, a `sh -c` layer, a CI step, some agent shells — and the quotes die: the shell expands the pattern instead, and cgr receives hundreds of file paths as positional arguments:

```
Usage: cgr start [OPTIONS]
Try 'cgr start --help' for help.
┌─ Error ─────────────────────────────────────────────────────────────────────┐
│ Got unexpected extra argument(s)                                            │
│ (archive/experiments/.../node_modules/@puppeteer/browsers/lib/browser-data ...
```

It reads like a cgr bug. It is argv mangling. Keep every glob inside a script file (`scripts/index.sh`) and invoke the script, never a long quoted one-liner.

## 8. A sync never calls the LLM — so indexing can be fully offline

Correcting a very natural assumption (and an earlier version of this doc): `cgr start --update-graph` involves **no** LLM at all. Verified against 0.5.0 — `graph_updater.py` has no orchestrator reference, and `ORCHESTRATOR_PROVIDER` is read only in `cli.py` / `main.py`, i.e. the assistant and `ask_agent` paths. Graph building is tree-sitter + ast-grep parsing plus the local embedding model.

Consequences worth knowing:

- A full graph build leaks nothing. No API key, no network, no quota.
- Do not bother configuring `ORCHESTRATOR_*` / `CYPHER_*` before an overnight build — they matter only for `ask_agent` and NL→Cypher.
- If a sync looks like it is "waiting on a model", it is not. Look instead at concurrent syncs sharing `graph.sqlite` (§9) or at stray processes.

## 9. Never run two syncs at once

Every project shares one `graph.sqlite` and one `vectors.sqlite` under `~/.cgr/`. Two concurrent `cgr start --update-graph` runs contend on the SQLite write lock and **both** crawl to a halt — the visible symptom is a sync that sits for 10+ minutes on a two-file repo, or node counts that barely move.

Check for strays before starting, and kill them (Windows, from git-bash, since `ps` lies about dead processes here):

```bash
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { \$_.CommandLine -like '*cgr*' } | ForEach-Object { \$_.ProcessId }"
```

Watch real progress by reading the counters, not the log: `cgr_nodes` in `graph.sqlite` should climb by thousands per minute during a healthy sync.

## 10. Without the `ast-grep` extra, shell scripts become dead nodes

The default extras parse the big languages but not shell/nix. A sync finishes and quietly reports:

```
22 file(s) (bash: 20, nix: 2) were indexed as plain File nodes, with no modules,
functions, classes or imports: the ast-grep tier parses these languages and needs
the ast-grep extra. Install it, e.g. uv tool install "code-graph-rag[treesitter-full,ast-grep,semantic]"
```

A shell script in the graph as a bare `File` node is invisible to `semantic_search` and to every call/import query — exactly the scripts people ask about ("where do we run the deploy?"). Install `ast-grep` up front (`scripts/install.sh` includes it), or inject it into an existing tool venv:

```bash
uv pip install --python "$(uv tool dir)/code-graph-rag/Scripts/python.exe" ast-grep-py
```

Existing nodes are not retro-fixed: run one more `--update-graph` (the hash cache will re-parse only what changed... which is nothing, so use `cgr workspace remove-repo` + `add-repo` for that project, or `--clean` on a small corpus).

## 11. Shell redirection to a Windows path creates junk files (and leaks secrets)

`bash` on Windows is either MSYS (git-bash) or WSL, and neither understands `C:\...` as a path. This does not fail — it succeeds and creates a file whose **name** is the path:

```bash
# in WSL, this wrote a file named "C:Users<you>.cachehuggingfacetoken" into the repo root
echo "$TOKEN" > "C:\Users\me\.cache\huggingface\token"
```

If the payload is a credential, you now have a plaintext token sitting inside the working tree (`git status` shows it as `??`, and a careless `git add -A` commits it). Two rules:

- Write user-level files with Python, not with shell redirection: `python -c "import pathlib,os; p=pathlib.Path(os.path.expanduser('~/.cache/huggingface/token')); p.parent.mkdir(parents=True,exist_ok=True); p.write_text(tok)"` — Python resolves `~` for the platform it actually runs on.
- `scripts/doctor.sh` flags any file in the cwd that looks like a Windows path used as a name, and tells you to delete it.

Also note: `huggingface_hub.login(token=...)` **validates the token against the Hub before saving**, so a wrong or expired token never reaches the disk. If you see `HfHubHTTPError: Invalid user token`, the token itself is bad — nothing was stored.

## 12. POSIX paths passed to a native program are not translated

`python.exe`, `git`, `rg`, `node` are native binaries; MSYS path conversion is off in scripts, so `/d/work/x.py` reaches them as `D:\d\work\x.py`:

```
python.exe: can't open file 'D:\\d\\money\\x.py': [Errno 2] No such file or directory
```

Convert explicitly, and do it for every file argument:

```bash
native() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
python.exe "$(native ./scripts/helper.py)"
```

`scripts/_common.sh` exposes this as `cgr_native_path`.

## Bonus: `cgr doctor` / `cgr status` noise

- `cgr doctor` reports `orchestrator: ollama:llama3.2` and `:11434 connection refused` by default. Harmless if you never call `ask_agent`.
- `cgr status` reports `stack: stopped (memgraph=..., qdrant=...)` and `syncs: unknown`. The default backend is embedded SQLite, so both are expected — it is reading state that only exists on the Neo4j backend. To check real progress, look at the size of the graph file and the vector table:

```bash
python -c "import sqlite3,os;c=sqlite3.connect(os.path.expandvars(r'%USERPROFILE%\.cgr\graph.sqlite'));print(c.execute('select count(*) from cgr_nodes').fetchone()[0])"
```
