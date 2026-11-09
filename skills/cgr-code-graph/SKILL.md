---
name: cgr-code-graph
description: "Use when indexing or querying code with cgr."
---

# code-graph-rag (cgr) — code knowledge graph + local embeddings

Use when the task is "embed the whole repo", "ask questions across projects", dead-code/duplicate detection, or wiring an MCP that answers codebase questions. Windows host, uv-managed.

## Install (Windows)

```bash
uv tool install "code-graph-rag[treesitter-full,sqlite-vec,ast-grep]"
uv pip install --python "$(uv tool dir)/code-graph-rag/Scripts/python.exe" httpx
```

Resolve the interpreter with `uv tool dir`, never `$APPDATA/uv/tools/...`: under git-bash launched from
PowerShell `APPDATA` is often unset or points at an MSYS shadow path, so that literal path installs into
a venv nothing ever runs. Keep the extra set identical everywhere (`install.sh`, docs, skill) — a
different set per document means the effective dependency set depends on which one was followed.

The `httpx` injection is required: v0.5.0 crashes on every command with `ModuleNotFoundError: No module named 'httpx'` because `tools/health_checker.py` imports it but the wheel omits it. Same venv takes `torch` + `transformers` for local embeddings (~1 GB, no GPU needed).

Include the `ast-grep` extra or shell/nix files are indexed as bare `File` nodes with no functions and no call edges — invisible to `semantic_search` and to every caller query, which is exactly where people expect shell scripts to show up. The sync says so only in passing: `N file(s) (bash: N, nix: N) were indexed as plain File nodes ... needs the ast-grep extra`. Add it later with `uv pip install --python <tool python> ast-grep-py`, then re-sync once.

Tools live in `~/.local/bin` (not on PATH by default); graph is `~/.cgr/graph.sqlite`, vectors `~/.cgr/vectors.sqlite`, workspace defs `~/.cgr/workspaces/<name>.toml`. Making that permanent for a
Windows user whose shell is cmd.exe (rc files are not read there) — registry User PATH recipe in the
`windows-msys-dev` skill.

Reach those paths through the kit's `scripts/_common.sh` (`cgr_home`, `cgr_uv`, `cgr_tool_python`,
`cgr_tool_roots`, `cgr_shim_dir`) instead of `$HOME`: under git-bash launched from PowerShell, `$HOME`
is `/home/<user>` while uv, `~/.cgr` and the model cache live under the Windows profile, and
`USERPROFILE`/`APPDATA` may be absent altogether — so a `$HOME`-rooted lookup reports "tool venv not
found" on a healthy install. `uv tool dir` is not reliable either (uv may not even be on PATH): fall
back to `$APPDATA/uv/tools`, `<real home>/AppData/Roaming/uv/tools`, then `~/.local/share/uv/tools`.

When a user pastes `error: tool venv python not found`, the install is almost always fine and the path
lookup is wrong — never answer with "reinstall cgr". Ask for `bash scripts/hf-login.sh --where` (or
add the equivalent `--paths` flag): it prints `$HOME`, the resolved profile, the uv binary, the tool
python and every root searched, which is the whole diagnosis. Test helpers with the hostile
environment, not just a wrong home: `env -u USERPROFILE -u APPDATA -u LOCALAPPDATA HOME=/home/nobody
bash scripts/<x>.sh`. Mechanism: `windows-msys-dev` skill.

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

## What cgr can and cannot read

- **Code** (TS/JS/Python/Go/Rust/Java/C#/Ruby/PHP/C-family/Kotlin/Swift/Dart/Scala/Lua) via tree-sitter, plus shell and nix once the `ast-grep` extra is installed.
- **Markdown** (`.md`, `.markdown`) via `document_tier.py` — each heading becomes a `Section` node nested by heading level, YAML front-matter is parsed, relative links between files are tracked. Free, local, no LLM. Verify with `select label, count(*) from cgr_nodes group by 1` — a corpus with docs shows `Section` rows.
- **Not** PDF, DOCX, images, audio, video. No vision, no OCR. If a corpus has them, cgr silently ignores the files; only `doctor.sh`-style counting makes that visible.

To bring documents in, convert them to markdown in a *shadow* directory and index that — never rewrite the user's originals, never hand binaries to cgr. Local converters (pandoc / markitdown / pdftotext) cover text PDF, DOCX, EPUB, HTML for free; scanned PDF, images and video need a vision API and therefore an explicit consent gate. The full decision table, shadow-tree layout, cost-estimate format and consent-log design are in `references/multimodal-ingest.md`.

## First run: check the Hugging Face warning is harmless

A first sync prints:

```
Warning: You are sending unauthenticated requests to the HF Hub. Please set a HF_TOKEN to enable higher rate limits and faster downloads.
```

This is not an auth failure and not data leaving the machine beyond the model download itself: it means the 199 model shards are being fetched anonymously from `huggingface.co`. Say so plainly when asked — users read "unauthenticated" as "unauthorized". Setting `HF_TOKEN` only raises rate limits, and the weights stay cached under `~/.cache/huggingface/hub` so later syncs download nothing.

Store the token in the canonical file, not in the user's shell config: `~/.cache/huggingface/token`
(mode 600). Every `huggingface_hub` consumer, cgr included, picks that up with no config edit and no
restart — the environment variable is only needed for a one-off session and tends to leak into shell
history. Create it read-scoped at `https://huggingface.co/settings/tokens` (New token → Read). Repo
helper `scripts/hf-login.sh` delegates the write to `scripts/_hf.py`, which calls
`huggingface_hub.login(token=...)`: that validates against the Hub **before** saving, so a wrong or
expired token never reaches the disk and the failure reads `HfHubHTTPError: Invalid user token`
instead of appearing mid-sync. `--status` reports the stored identity, `--logout` removes the file,
`--where` prints the resolved paths. **Never accept a token in chat and never echo one back** — have
the user run the prompt themselves; a file on their own disk is the only safe destination, and state
that a read token is revocable from the same page.

Never write that file with shell redirection (`echo $TOK > C:\Users\...`). On Windows `bash` this
silently creates a file named `C:Users<you>.cachehuggingfacetoken` in the *current directory* — a
plaintext token inside the repo, one `git add -A` from being committed. Write user-level files from
Python, and have the helper flag such filenames (doctor.sh does). Mechanism and the WSL variant:
`windows-msys-dev` skill.

Docs and helpers must treat the token as optional: cgr runs fine without it, slower and noisier.

Two things the prompt itself must say, because every user hits them:

- **Show the portable form first, then the resolved path.** Print
  `portable: ~/.cache/huggingface/token` above `on this PC: <absolute>`, and state that the absolute path
  is computed at run time from the profile and never written into the repo. A prompt that shows only
  `C:\Users\<their-name>\.cache\...` reads as "this was hardcoded for you" — users do ask. The path
  varies by OS, user account, and `HF_TOKEN_PATH` / `HF_HOME` / `XDG_CACHE_HOME`; `_hf.py path` (or
  `python -c "from huggingface_hub.constants import HF_TOKEN_PATH; print(HF_TOKEN_PATH)"` run with the
  tool venv's python) is the only correct source. Per-OS defaults and override order belong in docs.
- **Warn before reading that nothing will appear while pasting.** `stty -echo` shows no dots, no
  asterisks, no length; users assume the terminal is broken and paste again or Ctrl-C. Say it is
  deliberate (keeps the secret out of scrollback, screenshots, session logs) and that Enter is the
  only confirmation. Also state that `login()` validates before writing, so a bad paste stores
  nothing. Environment `HF_TOKEN` overrides the file, so a stale export in a shell profile shadows a
  freshly saved token — first thing to check when `--status` shows the wrong account.

## Before a long sync: preflight, not guesswork

Run `bash scripts/doctor.sh [corpus-root]` (exit 1 = a FAIL) before starting anything multi-hour, and
again when a sync "hangs". It reports, each with the exact fix, the failures that otherwise surface
hours in: `httpx` missing from the tool venv, no `torch`/`transformers`, no ast-grep extra, low disk
on the graph volume, a second concurrent sync, an MCP entry without `TARGET_REPO_PATH`, a dead local
MCP endpoint, workspace repo paths that no longer exist, a file in the cwd named like a Windows path
(shell redirection leaked a secret there), and a corpus root that is a drive root or the
home dir.

Pass the corpus root and it also prints the file mix and a runtime estimate. Calibration from a
measured run: **~6.7 functions per code file** (196 code files → 1,313 functions) and embeddings at
**~1.1/s on CPU**; only functions and methods get an embedding, so estimate from that count, never
from total tokens or bytes. Quote the result as ±50% rather than a promise.

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

### Writing notes: `--read-only` hides `annotate`

`--read-only` advertises **26 of 37** tools. The eleven it hides include `annotate`
(attach a note to one definition) plus `rename`, `write_file`, `wipe_database`.
So a read-only server can *read* notes and never *write* one — check the count in
`hermes mcp test` before promising a user that agents can leave notes behind.

To enable: register a second entry, same command, `--read-only` and
`MCP_READ_ONLY` both removed (`scripts/register-mcp.sh <ws> <root> --with-writer`
does it). The env var re-arms the gate on its own, so dropping only the flag is not
enough. Expect 37 tools and `annotate` in the list.

What a gloss can hold (verified on a real definition): `kind` is one of
`invariant` | `mirrors` | `platform-conditional` | `safety-precondition`, plus
`target_hash` (`ah1:...`), `commit_sha` and an `ANNOTATES` edge. Anchors are
re-graded each sync as `EXACT` / `STALE` / `MOVED` / `AMBIGUOUS` / `LOST` — `MOVED`
means the note survived a rename, which a markdown link to a line number cannot do.
Read them back per target with `glosses <qualified name>`; there is no
search-all-notes call, and four `kind` values are not free prose. Code-shaped "why"
belongs here; everything else belongs in the markdown vault.

`annotate` takes `project` when the corpus root is not itself an indexed project —
omit it and you get `Project ... not found`.

## Sync operations (where runs go wrong)

- **`--update-graph` with `--workspace` is not a headless build.** Repo mode
  (`--repo-path ... --update-graph`) syncs and exits; workspace mode syncs every
  repo and *then starts the assistant*, which validates an LLM provider before
  reading any input and dies with `ValueError: Ollama server not responding at
  http://localhost:11434`. A background job therefore reports failure after a
  perfectly good sync — check `select count(*) from cgr_nodes` before believing
  the traceback. Sync per repo instead (`--repo-path <p> --project-name <name from
  the workspace toml> --update-graph`), which is what the kit's `scripts/index.sh`
  does; it also reports which repo failed and exits non-zero on that.
- **Never run two syncs at once.** Every project shares `graph.sqlite` + `vectors.sqlite`; two concurrent `cgr start --update-graph` contend on the SQLite write lock and both crawl — the symptom is a sync stuck 10+ minutes on a two-file repo. List strays with `powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='python.exe'\" | Where-Object { $_.CommandLine -like '*cgr*' }"`; MSYS `ps -W` reports killed processes as alive, so trust the PowerShell listing.
- **A sync never calls the LLM.** `graph_updater.py` has no orchestrator reference; `ORCHESTRATOR_PROVIDER` is read only in `cli.py` / `main.py` (assistant + `ask_agent`). A full build is tree-sitter/ast-grep parsing plus the local embedding model — no key, no network, no quota. So do not bother configuring `ORCHESTRATOR_*` before an overnight build, and if a sync looks like it waits on a model, it is really contending on `graph.sqlite` (next bullet).
- **Keep exclude globs inside a script file.** `--exclude '**/node_modules/**'` typed by hand works; passed through a launcher that re-splits the command line (background job runner, `sh -c`, CI) the quotes die, the shell expands the pattern, and cgr dies with `Got unexpected extra argument(s)` listing hundreds of paths. Repo `scripts/index.sh` exists for exactly this.
- **Quoting is not enough: cgr expands `--exclude` against the CURRENT DIRECTORY, not
  against the repo being indexed.** A pattern that matches real paths under `cwd` is
  expanded and the matches arrive as extra argv, so the run dies with the same
  `Got unexpected extra argument(s)` even from a script with every glob quoted. Measured:
  `--exclude '**/.git/**'` fails every time it is run from inside a git repo, because
  `.git/**` matches the *kit's own* `.git` — paths from the cwd, not from the corpus.
  Rules: never exclude `.git` (cgr skips it natively), never add a pattern for a
  directory that exists in the directory you run from, and when a run dies with that
  error, reproduce it from a neutral cwd (`cd /tmp`) before blaming your quoting.
- **Convert paths before handing them to `cgr.exe`.** It is a native binary: `/d/work` and `/tmp/x` do not resolve, and under WSL `/mnt/d/work` resolves as `D:\mnt\d\work` — either way `workspace add-repo` fails silently per project. Use `scripts/_common.sh`'s `cgr_native_path` (branches on `cygpath -w` vs `wslpath -w`) and surface stderr instead of `>/dev/null 2>&1`. Same in reverse when reading `~/.cgr/workspaces/*.toml`, which stores `D:\\...` — convert with `wslpath -u` / `cygpath -u` before any `[ -d ]` test, or every repo reads as missing.
- Progress check is a counter, not the log: `cgr_nodes` in `~/.cgr/graph.sqlite` climbs by thousands per minute when healthy.
- **A `state/<project>/` folder is not proof of indexing.** A killed sync, a sync
  that wrote files but never parsed them, and a repo in a language cgr has no
  grammar for all leave that folder behind. Read the graph:
  `python3 scripts/audit-workspace.py <workspace>` prints nodes/defs/files/edges per
  declared repo and only exits 1 when a repo has no nodes at all. Measured on a
  21-repo workspace: `.astro` (peeler) lands as File nodes with zero definitions —
  cgr has no grammar for Astro, Vue or Svelte, so those repos are unqueryable no
  matter how often they sync. Do not "fix" that with a re-sync.
- **`cgr status` cannot report sync times on the embedded (SQLite) backend** — it
  reads Memgraph at `localhost:7687`, so it prints `syncs: unknown … could not be
  read`. Use `cgr stats` (per-project nodes/relationships) or the audit script.
- `cgr delete-project --project <name>` is the only clean way to remove one project
  from the graph; `cgr workspace delete <name>` removes the definition but keeps
  indexed graph rows.
- **A stale `:IncompleteRun` marker can outlive its process.** cgr clears it only
  when the marker's `owner_pid` is provably dead — and Windows recycles PIDs, so a
  killed sync's pid can come back as an unrelated live process (measured: pid 22036
  was `OpenConsole`), and then `delete-project` keeps the marker forever. The row is
  bookkeeping with no edges; deleting it from `cgr_nodes` by hand is safe once you
  back up `graph.sqlite`.
- `cgr workspace remove-repo` drops a single repo from a workspace definition.

## Querying a workspace's graph

The MCP tools are scoped by a `project` argument, not by the server's cwd — see
`references/querying-the-graph.md` for the full recipe and the exact error strings.
The short version:

- Pass `project` explicitly (`<name>__<hash>`, e.g. `work__6dbff338`). Without it, a
  workspace whose repos are not rooted at the server directory refuses every search.
- Only projects that finished their first sync are queryable; a project still syncing or
  never added answers `Unknown project`. `list_projects` prints what is available right now —
  never promise cross-project coverage before every repo appears there.
- **The indexing root is the resolution boundary.** Imports and calls resolve by path
  against the root you index. Indexed as one root (a monorepo, or a parent directory that
  holds several packages), a sibling import lands on a real `Module` and its call on the
  real `Function`. Indexed as separate projects, the same import becomes an
  `ExternalModule` stub and the call edge does not exist. So "no cross-project edges" is a
  consequence of how you indexed, not a limitation to report as fixed. Measure before
  claiming either way:
  `select count(*) from cgr_edges e join cgr_nodes s on s.id=e.src join cgr_nodes d on d.id=e.dst where s.key not like d.key and d.label <> 'ExternalModule'`
  gives zero when every edge stays inside one project.
  Measured on a two-package corpus, `--no-embeddings`: indexed as one root,
  `IMPORTS -> [Module] xone.pkg_b.core` and `CALLS xone.pkg_a.app.run -> xone.pkg_b.core.helper`;
  indexed as two projects, the same import is `IMPORTS -> [ExternalModule] pkg_b.core` and
  there is no CALLS edge at all — same result for a Python absolute import and a JS relative
  one. Pick the mode with the kit's script: `init-workspace.sh <ws> <root>` registers one
  project per repo, `init-workspace.sh <ws> <root> --root` indexes the root as one project.
- Merging everything into one root is not free: one namespace, one hash cache, `--clean`
  wipes the whole thing, and `--projects` filtering collapses to a single value. It only
  pays when the repos genuinely reference each other by an importable path; two projects
  that each depend on `lucide-react` gain nothing. `prune`/project-level state is also
  lost per repo — no per-repo listing of file counts.
  Recipe: `init-workspace.sh <ws> <root> --root`. It registers the root under the
  name cgr derives from the folder (`<dirname>__<hash>`), so the workspace toml, the
  graph project and `~/.cgr/state/<project>/` all agree — do not pass `-p`.
  Re-laying an existing workspace is refused without `--force`: `workspace create
  --force` swaps the definition but leaves the old project's rows in the graph, so
  every file then answers twice. Switching one workspace between the two layouts is
  therefore a delete-your-own-data move, not a refresh.
- Answer a "where is X" question with three hops: `semantic_search` (purpose, in the project
  that owns the feature) → `get_code_snippet` (confirm the body) → `callers` (who reaches it).
  Then search the action verb *again* to catch parallel entry points that never call the
  shared helper — those divergences are the finding, not the helper itself.
- Quote `path:line` and the real source, and state which projects the answer covered.

### Which route: MCP tools first, CLI second

When the user asks "can you use cgr?" they mean "search the code now" — answer by running a
search, not with an install/PATH story. Both routes work; prefer this order:

- **MCP tools are already loaded** (`mcp__cgr__semantic_search`, `get_function_source`, `context`,
  `list_projects`, `callers`, …) as soon as cgr is registered in the client config — no PATH entry
  required, so "cgr is not on PATH" never blocks a query. Call them with EXACTLY their documented
  arguments: the MCP wrapper forwards your argument object verbatim and rejects any extra key
  (`... got an unexpected keyword argument 'reason'`), so no convenience fields.
- **CLI fallback** is the full path `~/.local/bin/cgr.exe` (`cgr` works once `~/.local/bin` is on
  PATH). Graph-only commands — `context`, `port`, `check`, `rename`, `change-signature` — exist only
  on the CLI, so an MCP-only session cannot answer "what breaks if I change this" for them.

Coverage without spending a call: `list_projects` (MCP) prints what is queryable right now; on disk
the same split is `~/.cgr/state/<project>/` (finished a sync) versus the repo list in
`~/.cgr/workspaces/<name>.toml` (merely declared). A repo present in the toml but absent from
`state/` answers `Unknown project` — say which projects an answer covered, never promise the rest.

### Third route: `cgrq`, when the client cannot register MCP at all

Some hosts serve no MCP client (an ACP/JSON-RPC harness, a chat UI with no `/reload-mcp`), so the
`mcp__cgr__*` tools never appear even though `hermes mcp test cgr` passes and a manual spawn lists
all 26 tools. Do not answer "reload the client" twice — hand over a warm client instead:
`scripts/cgrq.py` (+ a `cgrq` bash shim in `~/.local/bin` that prefers the kit copy and falls back
to a local one) keeps one `cgr mcp-server --workspace <ws>` child alive
and proxies `tools/call` over loopback TCP `127.0.0.1:20140`.

```
cgrq status                          # pid, workspace, answering?
cgrq tools                           # 26 names, autostarts the daemon
cgrq find "where are bookings created" -p <project>__<hash>   # hits + head of each body
cgrq search "where are bookings created" -p <project>__<hash>  # names + scores only
cgrq ctx "booking status transition" -p <project>__<hash> --budget 900
cgrq tool callers '{"qualified_name":"...","project":"..."}'
cgrq stale                           # which repos moved since their last sync
cgrq serve --workspace money         # explicit start; --with-writer to enable annotate
cgrq stop
```

`find` exists because `semantic_search` alone returns five qualified names and no source, so ruling a
hit in or out costs one more call each. `find` prints `path:span score` plus the first `-l` lines of
every hit in a single round trip: two hits with 4 lines each measured ~700 bytes / 1.2 s warm, where
the same judgement by file reads is 14 KB+. `stale` answers the question a stale graph makes
unanswerable — "is this hit still true?" — by comparing each repo's last commit with its hash cache;
it exits 1 when anything is behind, so a shell can gate on it.

Measured on a 21-project graph: cold daemon start 8 s (`tools` total), first
`semantic_search` 32 s (embedding model load), every call after that **0.3–1.9 s** —
`ctx` returned 166 tokens of `convex/bookings.ts:66-86` plus the callee's signature in 1.9 s, where
opening the file costs 14 KB. Deterministic CLI graph queries are already ~1.8 s cold, so the daemon
only buys the embedding-model load. Model load happens per server process, so the same daemon must
stay up across turns; it is cwd-independent and survives the shell that started it.

### Markdown corpora: sections are searchable, after one patch

Stock cgr indexes every markdown heading as a `Section` with `path` / `start_line` / `end_line`, then
never embeds it: `EMBEDDED_NODE_LABELS` and `CYPHER_QUERY_EMBEDDINGS` are `Function` + `Method` only,
and `definition` / `get_code_snippet` / `context` refuse a `Section` label. A docs-only corpus
therefore answers `No semantic matches` however often it is synced. `scripts/patch-sections.py` edits
the installed package in five places (three label sets, the embedding query, `_DEFINITION_LABELS` in
`graph_query.py` and `context_slice.py`), is idempotent, and has `--check` / `--revert`:

```
python scripts/patch-sections.py --backup   # *.cgr-stock next to each edited file
python scripts/patch-sections.py            # apply / re-apply after uv tool upgrade
python scripts/patch-sections.py --check    # exit 1 when stock again; doctor.sh runs this
bash scripts/index.sh money                 # re-sync: sections are embedded on the next pass
```

The section branch scopes on `n.qualified_name STARTS WITH $project_name` rather than walking
`(m:Module)-[:CONTAINS_SECTION]->(n:Section)`: the embedded engine returned 14 rows for 97 sections
through that edge (one per file), and returns all 97 when scoped on the section itself. A `Section`
has its own `path`, so it needs its own RETURN block instead of the shared `m.path` one. Verified on a
97-section docs project: 97 points stored, `find` returns `MARKETING-ARCHIVE-2026-11-03.md:67-73`
with its body. Anything under `uv tool upgrade` is lost — the doctor check is the tripwire.

The patch is a local build, not an upstream fix: a package upgrade restores stock silently, so treat
"no semantic matches" on a docs project as this first, not as an indexing failure.

## What surface to build around it

When asked "should this be a GUI / a VS Code extension / an MCP?", the answer is MCP plus two shell
scripts, and say why: anyone who indexes a codebase already lives in a terminal and an agent CLI, so an
MCP server is the whole integration and a desktop GUI is weeks of work exposing five buttons. The
third artefact that earns its place is a **static HTML report** generated from the graph — projects,
function counts, cross-project duplicates, dead code, endpoints — because it is one file the user can
open and forward without a server, and it is the closest thing to a GUI that costs nothing to
maintain. Order of value: `doctor.sh` (preflight) → `report.sh` (static artefact) → optional ingest.

## Incremental sync: two caches, and what a refresh actually costs

"Do I have to re-embed everything after a repo update?" — no, and the answer is mechanism, not
reassurance. Two independent caches, both on by default:

- **File hash cache** (`~/.cgr/state/<project>__<hash>/`, `_load_hash_cache` in `graph_updater.py`):
  keyed by path + content hash. An unchanged file is not re-parsed, so it emits no nodes and no
  edges — a no-op sync is a crawl plus a hash compare.
- **Embedding cache** (`~/.cgr/.embedding_cache.json`, `EmbeddingCache` in `embedder.py`): keyed by
  `sha256(f"{_cache_namespace()}\x00{content}")`, i.e. **per snippet, not per file**. `embed_code_batch`
  asks `get_many` first and only misses reach the model, so editing one function re-embeds one
  function. The namespace is the embedder identity (model + dimension), so switching embedders
  correctly invalidates everything instead of mixing 768-d and 4096-d vectors.

Cost per change: one edited function → that file re-parsed, its functions re-embedded; one new file →
that file only; one deleted file → nodes pruned and its vector points dropped
(`delete_stale_embeddings`); nothing changed → seconds to a couple of minutes over 20k files.

**Caveat worth stating up front: the embedding cache is saved once, at the end of pass 5**
(`get_embedding_cache().save()`), not per batch. Interrupt a long first sync and the vector store keeps
whatever points were already flushed, but the JSON cache is only as fresh as the last completed pass —
the next run re-embeds the difference. So the first full index is the only expensive one; budget it
(`doctor.sh <root>` prints an estimate) and then refresh freely with `scripts/refresh.sh <workspace>`.

Verify instead of trusting: `select count(*) from cgr_vector_points` in `~/.cgr/vectors.sqlite` for
stored vectors, `len(json.load(open('~/.cgr/.embedding_cache.json')))` for cache entries — then touch
one file and sync again; the cache count grows by roughly that file's function count, not by corpus
size. Deeper write-up lives in the repo's `docs/incremental-sync.md`.

Never `--clean` unless the graph itself is corrupt.

## Portability: keep the author's machine out of the repo

Before publishing a kit, scan for the author's own paths and names, and keep scanning — they creep back in
through comments and examples:

```bash
git grep -n -i '<username>' -- .          # LICENSE/README credit lines are fine; scripts are not
git grep -nE '/c/Users/[a-z0-9._-]+|[Cc]:\\\\+Users\\\\+' -- scripts/
```

Rules that hold up:

- Scripts resolve everything at run time (`cgr_home`, `cgr_uv`, `cgr_tool_python`, `cgr_shim_dir`). No
  literal `C:\Users\<name>` in a script, ever — including inside comments, which is where it usually hides.
- Docs and examples use placeholders (`C:\Users\you`, `D:/work`, `~/`) — a reader must be able to
  substitute their own path without guessing which parts are literal.
- Credit lines in `LICENSE` / `README` (`Copyright (c) <year> <author>`) are intentional; do not scrub them.
- `doctor.sh` carries a portability section that greps `scripts/` for the current user name and for
  absolute home paths, so a regression fails the preflight instead of the next user. Grep hits inside
  comments need `grep -vE ':[0-9]+:[[:space:]]*#'` or the check cries wolf on its own documentation.

`.gitignore` must cover the secret-adjacent accidents, not just build output: `token`, `stored_tokens`,
`.env*`, `*.pem`/`*.key`, and the Windows junk-file patterns `C:*` / `CUsers*` (a token written by shell
redirection). Verify with `git check-ignore -q <path>` for each pattern rather than eyeballing the file.

A scan of the working tree is not the answer to "is this portable?". Four surfaces, and the kit has
been caught on each: the tracked file list (`git ls-files` — a `__pycache__/*.pyc` committed before the
ignore rule existed), the ignore rules themselves (asked per path with `git check-ignore`), the commit
author identity (`git log --format='%an <%ae>' | sort -u` — a personal address ships with the history
even when the forge profile is private), and every commit rather than just HEAD. Full procedure,
mailmap format and the post-rewrite proof commands: the `public-release-prep` skill and its
`references/history-scrub.md`. Do this while `git remote -v` is still empty — a rewrite after the first
push costs a force-push and a re-clone for everyone.


## Scripts that touch the user's machine: the classes that keep coming back

An audit of this kit found the same four mistakes a shell installer usually makes. Check every new helper
against them before shipping:

- **Secret handed to a child through a temp file.** `TF="$TMPD/name-$$"` + plain `>` is guessable and
  non-exclusive: another local user pre-creates the path or plants a symlink and receives the token, and
  `umask 077` only constrains inodes the shell creates. Use `TF="$(umask 077; mktemp "$TMPD/name.XXXXXXXX")"`
  and `trap 'rm -f "$TF"' EXIT INT TERM HUP`, or avoid the file entirely and pipe the secret on stdin.
- **Profile fallback that is not identity-bound.** `for u in /c/Users/*; do ... done` accepts another
  account's home as this user's, and every later path — `uv.exe`, the tool venv python, the graph store —
  is built from it and executed. Resolve the account name (`USERPROFILE`/`USERNAME`, then `USER`/`LOGNAME`,
  strip any directory part) and consult only `/c/Users/$me`; when the identity cannot be established fall
  back to `$HOME`, never to a directory listing. Same rule for tool-venv search roots: no cross-user
  wildcard, because the first `-x` match gets executed.
- **Filenames echoed to the terminal.** A cloned repo can carry a name with ESC/CSI/OSC/BEL, and the
  terminal executes what it is handed. Pipe any name that came from the filesystem through
  `LC_ALL=C tr -cd '[:print:]'` before `printf`/`warn`.
- **A check that cannot run reporting PASS.** An empty `"$TOOL_PY"` exits 127, stderr is discarded by
  `2>/dev/null || true`, the result is empty, and the check prints "nothing found". Guard with
  `[ -x "$TOOL_PY" ]` and emit WARN/SKIP — an unrun check is not a passing check.

Two installer-specific ones: bind the interpreter to the venv the install was asked to create
(`uv tool dir` + `<tool>/Scripts/python.exe`) instead of trusting a multi-root search, and in PowerShell
never wrap `uv`/other native commands in `try/catch` — `$ErrorActionPreference='Stop'` governs cmdlets, a
nonzero exit is not a terminating error, so the `catch` is dead code and the script proceeds against a
stale venv while reporting success. Check `$LASTEXITCODE` explicitly.

Prove each fix instead of reading it: `stat -c '%a'` on the temp file (600 from `mktemp` vs 644 from `>`),
override the resolver in a subshell (`cgr_self_user() { return 1; }`) to see which home is chosen, set
`CGR_TOOL_NAME=nope` to reach the fail-closed branch, and create a file named `C:$'\e]0;x\a'` to watch the
sanitizer strip it. Run the escape test under WSL: MSYS mangles such names to private-use code points
(`U+F03A`), so on git-bash the file never matches and the check looks fine when it is untested.

## Operating notes

- `cgr status` reports Memgraph/Qdrant state and says `syncs: unknown` on the sqlite backend — not an error; read `~/.cgr/graph.sqlite` size and the vectors table instead.
- `cgr start --ask-agent "..."` works without the assistant TUI and prints the answer to stdout — the cheapest end-to-end proof that graph + vectors are live.
- Tell the consuming agent to prefer these tools over grep: put a short "use cgr before grep" block in the repo's `CLAUDE.md` / `AGENTS.md`, since MCP tools are only self-describing once the client reloads them.
