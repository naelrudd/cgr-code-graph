---
name: cgr-code-graph
description: "Use when indexing or querying code with cgr."
---

# code-graph-rag (cgr) — code knowledge graph + local embeddings

Use when the task is "embed the whole repo", "ask questions across projects", dead-code/duplicate detection, or wiring an MCP that answers codebase questions. Windows host, uv-managed.

## Install (Windows)

```bash
uv tool install "code-graph-rag[treesitter-full,sqlite-vec]"
uv pip install --python "$APPDATA/uv/tools/code-graph-rag/Scripts/python.exe" httpx
```

The `httpx` injection is required: v0.5.0 crashes on every command with `ModuleNotFoundError: No module named 'httpx'` because `tools/health_checker.py` imports it but the wheel omits it. Same venv takes `torch` + `transformers` for local embeddings (~1 GB, no GPU needed).

Tools live in `~/.local/bin` (not on PATH by default); graph is `~/.cgr/graph.sqlite`, vectors `~/.cgr/vectors.sqlite`, workspace defs `~/.cgr/workspaces/<name>.toml`.

## Embeddings: use local, not hosted

- Default local UniXcoder (768d) is the only path that survives a full corpus: ~1.1 chunk/s on CPU, zero cost, zero quota. Expect ~7 min per 400 embeddings.
- `gemini/gemini-embedding-001` via a local OpenAI-compatible router fails two ways — free tier returns `429 ... limit: 30000 tokens/min` / `100 requests/min`, and the router omits `index` on the first item, which cgr rejects as `response is malformed: 'index'`.
- NVIDIA-hosted embed models accept one input per request (batch → `500 service inference failed`), so they are query-side only.

Only set `CGR_EMBEDDING_PROVIDER=openai` for a small pilot against a paid endpoint.

## LLM provider for ask_agent / NL→Cypher

`ORCHESTRATOR_PROVIDER=openai` rejects any model id outside its hardcoded list (`Unknown openai model 'free-coding'`). For a custom OpenAI-compatible endpoint use the proxy provider:

```bash
export ORCHESTRATOR_PROVIDER=litellm_proxy ORCHESTRATOR_MODEL=<model-id>
export ORCHESTRATOR_ENDPOINT=http://127.0.0.1:<port>/v1 ORCHESTRATOR_API_KEY=<key>
export CYPHER_PROVIDER=litellm_proxy CYPHER_MODEL=<model-id>
export CYPHER_ENDPOINT=http://127.0.0.1:<port>/v1 CYPHER_API_KEY=<key>
```

It validates by hitting `<endpoint>/health` then `/v1/models`, so any live proxy passes. Graph-only work (`--update-graph`, deterministic tools) needs none of this.

## Index a multi-project drive

```bash
cgr workspace create <name> -d "..." --force
for r in proj1 proj2; do cgr workspace add-repo <name> "D:/root/$r"; done
cgr start --workspace <name> --update-graph \
  --exclude "**/node_modules/**" --exclude "**/.venv/**" --exclude "**/venv*/**" \
  --exclude "**/Library/**" --exclude "**/.next/**" --exclude "**/dist/**" --exclude "**/build/**"
```

Run it as a tracked background job (hours for a large corpus), never `nohup`.

## MCP registration (what makes it automatic)

```bash
hermes mcp add cgr --command "C:/Users/<u>/.local/bin/cgr.exe" --connect-timeout 120 \
  --env TARGET_REPO_PATH=D:/root ... --args mcp-server --read-only --workspace <name>
```

Two traps:
- The client spawns the server with cwd = the user's home, and cgr refuses to serve from a home dir or disk root (`Configuration error: The MCP server was started in C:\Users\<u>...`). Always pass `TARGET_REPO_PATH=<corpus root>`, which is not home.
- `hermes mcp add` ends with an interactive `Enable all N tools? [Y/n/select]` prompt; piped stdin gives it EOF and cancels after a successful connect. Feed it `printf 'y\n' |`.

Verify with `hermes mcp test cgr`. New tools only appear after `/reload-mcp` or a new session — a running session does not pick them up.

## Sync operations (where runs go wrong)

- **Never run two syncs at once.** Every project shares `graph.sqlite` + `vectors.sqlite`; two concurrent `cgr start --update-graph` contend on the SQLite write lock and both crawl — the symptom is a sync stuck 10+ minutes on a two-file repo. List strays with `powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { $_.CommandLine -like '*cgr*' }"`; MSYS `ps -W` reports killed processes as alive, so trust the PowerShell listing.
- **A sync never calls the LLM.** `graph_updater.py` has no orchestrator reference; `ORCHESTRATOR_PROVIDER` is read only in `cli.py` / `main.py` (assistant + `ask_agent`). A full build is tree-sitter/ast-grep parsing plus the local embedding model — no key, no network, no quota. So do not bother configuring `ORCHESTRATOR_*` before an overnight build, and if a sync looks like it waits on a model, it is really contending on `graph.sqlite` (next bullet).
- **Keep exclude globs inside a script file.** `--exclude '**/node_modules/**'` typed by hand works; passed through a launcher that re-splits the command line (background job runner, `sh -c`, CI) the quotes die, the shell expands the pattern, and cgr dies with `Got unexpected extra argument(s)` listing hundreds of paths. Repo `scripts/index.sh` exists for exactly this.
- **MSYS paths must be converted.** `cgr.exe` cannot resolve `/d/work` or `/tmp/x`, and `workspace add-repo` fails silently per project; wrap with `cygpath -w` and surface stderr instead of `>/dev/null 2>&1`.
- Progress check is a counter, not the log: `cgr_nodes` in `~/.cgr/graph.sqlite` climbs by thousands per minute when healthy.
- `cgr workspace delete <name>` removes the definition but keeps indexed graph rows; `cgr workspace remove-repo` drops a single repo.

## Operating notes

- `cgr status` reports Memgraph/Qdrant state and says `syncs: unknown` on the sqlite backend — not an error; read `~/.cgr/graph.sqlite` size and the vectors table instead.
- Refresh is incremental via per-project hash caches in `~/.cgr/state/<project>/`; re-sync of unchanged code takes seconds. Never `--clean` unless the graph itself is corrupt.
- `cgr start --ask-agent "..."` works without the assistant TUI and prints the answer to stdout — the cheapest end-to-end proof that graph + vectors are live.
- Tell the consuming agent to prefer these tools over grep: put a short "use cgr before grep" block in the repo's `CLAUDE.md` / `AGENTS.md`, since MCP tools are only self-describing once the client reloads them.
