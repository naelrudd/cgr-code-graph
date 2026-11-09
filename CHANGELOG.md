# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version tracks this kit's own scripts and docs, not the `code-graph-rag`
release it installs.

## [Unreleased]

### Added

- `scripts/register-mcp.sh ... --with-writer` registers a second MCP server,
  `cgr-write`, with `--read-only` (and `MCP_READ_ONLY`) removed. `--read-only`
  advertises 26 of 37 tools, and the eleven it hides include `annotate` — the only
  way an agent can write a note. Opt-in, because `rename`, `write_file` and
  `wipe_database` come with it.
- A gloss is the durable half of "why": a `Gloss` node with `kind`
  (`invariant` | `mirrors` | `platform-conditional` | `safety-precondition`), a
  `target_hash` fingerprint and an `ANNOTATES` edge to the definition. Anchors are
  re-graded on every sync (`EXACT` / `STALE` / `MOVED` / `AMBIGUOUS` / `LOST`), so
  a note follows a renamed function instead of pointing at a stale line number.
  Verified against a real definition: `gloss:712af35dc16004482b12e2cf`,
  `anchor_state: EXACT`. Read back per target with `glosses <qualified name>`;
  there is no "search all notes", which is the boundary with a markdown vault.

- `scripts/init-workspace.sh <workspace> <root> --root` indexes the root itself as
  a single project instead of registering one project per repo. Imports and calls
  resolve by path against the indexed root, so a directory holding several
  packages needs this for a sibling import to land on a real `Module` and a real
  `CALLS` edge. Measured on a two-package corpus: as one root,
  `IMPORTS -> [Module] xone.pkg_b.core` and
  `CALLS xone.pkg_a.app.run -> xone.pkg_b.core.helper`; registered as two
  projects, the same import becomes `IMPORTS -> [ExternalModule] pkg_b.core` and
  the call edge is absent (18 edges as one root, 14 as two).
  `tests/smoke.sh` drives the script against a stub `cgr` and asserts the argv it
  builds, so the mode is covered without running a real index.
- `scripts/audit-workspace.py`: reads the graph (not the hash cache) and reports,
  per declared repo, how many nodes, definitions, files and edges it holds. A repo
  that never synced, a repo whose sync died after writing files, and a repo in a
  language cgr has no grammar for (`.astro`, `.vue`, …) look identical on disk —
  all three leave a `state/<project>/` folder — so the cache is not evidence.
  Exit 1 only for a declared repo with no nodes at all. Covered by `tests/smoke.sh`
  against a synthetic graph, no cgr needed.
- `init-workspace.sh` now refuses to re-lay an existing workspace unless `--force`
  is passed, and names the repos already registered instead of overwriting them
  silently. `cgr workspace create --force` only replaces the definition: the
  projects the previous layout indexed stay in the graph, so the same files would
  answer twice under two namespaces. `--root` also lets cgr derive the project
  name from the folder now (no `-p`), so the workspace file, the graph project and
  `~/.cgr/state/<project>/` agree — a custom name desynced them.

### Fixed

- `scripts/index.sh` no longer ends in a traceback. It used
  `cgr start --workspace <ws> --update-graph`, which syncs every repo and *then
  starts the assistant* — only repo mode "exits without starting the assistant",
  per that flag's own help. A background build finished its sync and then died at
  `ValueError: Ollama server not responding at http://localhost:11434`, non-zero
  exit, graph fully written. It now reads the workspace file and syncs each repo
  with `--repo-path ... --project-name <recorded name> --update-graph`, names the
  repo that failed, exits non-zero when any did, and says which file is missing
  when the workspace does not exist. `tests/smoke.sh` asserts the argv against a
  stub `cgr`.

- `--exclude` globs are expanded by cgr against the **current directory**, not the
  repo being indexed, so any pattern matching a real path under `cwd` was injected
  as extra argv and killed the run with `Got unexpected extra argument(s)`.
  `--exclude '**/.git/**'` failed on every run started from inside a git repo —
  quoting the pattern did not help. Never exclude `.git` (cgr skips it natively);
  the trap is documented in `skills/cgr-code-graph/SKILL.md`.
- `cgr_posix_path`'s no-converter fallback (plain Linux, containers) left a
  single-backslash Windows path half-converted — `D:\work\x` became `/d/\work\x`.
  The old sed pattern was written as four escaped backslashes, so it only matched
  a doubled separator. Conversion is now a parameter expansion plus a slash
  squeeze, and `tests/smoke.sh` covers both shapes with the converters shadowed.
- `.gitattributes` pins `eol=lf` for every text file instead of only `*.sh`, so a
  Windows checkout no longer produces CRLF diffs for docs and workflows.

## [0.1.0] — 2026-11-07

First public release. Packaging, measured configuration and the failure list for
running `code-graph-rag` on a multi-project drive, indexed overnight and queried
through MCP.

### Added

- `scripts/install.sh` / `scripts/install.ps1` — `uv tool install` with the
  `treesitter-full`, `sqlite-vec` and `ast-grep` extras, plus the `httpx`
  injection the published wheel needs and local `torch` + `transformers` for
  offline embeddings.
- `scripts/init-workspace.sh` — detect every project under a root, register them
  as one workspace, start the first index.
- `scripts/index.sh` / `scripts/refresh.sh` — the sync command with all exclude
  globs kept inside the file, and an incremental re-sync on top of it.
- `scripts/ask.sh` — one question against the graph from a terminal, no agent
  session.
- `scripts/register-mcp.sh` — register the read-only MCP server, including the
  `TARGET_REPO_PATH` the server requires and the non-interactive answer to the
  `Enable all N tools?` prompt.
- `scripts/doctor.sh` — preflight covering the failures that otherwise surface
  hours into a sync: missing `httpx`, missing `torch`/`transformers`, missing
  `ast-grep`, low disk, concurrent syncs, a dead MCP endpoint, workspace repos
  that no longer exist, stray Windows-path filenames, and hardcoded user paths.
- `scripts/hf-login.sh` + `scripts/_hf.py` — optional Hugging Face token stored
  through `huggingface_hub.login()` (which validates before writing), with the
  temp-file race, the invisible paste and the per-machine path all handled.
- `scripts/_common.sh` — shared resolvers (`cgr_home`, `cgr_uv`,
  `cgr_tool_roots`, `cgr_tool_python`, `cgr_shim_dir`, `cgr_native_path`,
  `cgr_posix_path`) so no script has to trust `$HOME` or hardcode a path.
- `skills/cgr-code-graph/SKILL.md` — the same knowledge as an agent skill.
- `examples/CLAUDE.md` — a paste-in block that makes a non-`cgr`-aware agent
  reach for graph tools before `grep`.
- Docs: `windows-gotchas.md` (the five traps that cost real hours),
  `benchmark.md` (full measurements), `incremental-sync.md` (why a re-sync is
  seconds), `huggingface-token.md` (optional token, per-OS paths, revocation).
- `tests/smoke.sh` — dependency-free tests for path conversion, identity-bound
  profile resolution, fail-closed behaviour and the portability rules.
- CI: shellcheck, bash syntax, unit tests on Linux and Windows, PowerShell parse
  plus PSScriptAnalyzer, markdown-link and hardcoded-path checks.
- `SECURITY.md` with the threat model and the complete list of files the kit
  touches; `CONTRIBUTING.md`; issue and pull-request templates.

### Fixed

- The wheel omits `httpx` although `tools/health_checker.py` imports it, so
  every `cgr` command died with `ModuleNotFoundError: No module named 'httpx'`.
  Both installers inject it.
- Shell and nix files were indexed as bare `File` nodes — invisible to
  `semantic_search` and every caller query — until the `ast-grep` extra was
  installed.
- `$HOME` under git-bash launched from PowerShell is an MSYS shadow directory,
  which made a healthy install report `tool venv python not found`. The profile
  is now resolved from `USERPROFILE`/`LOCALAPPDATA`/`APPDATA` first, and every
  fallback is bound to the current account instead of a `/c/Users/*` wildcard.
- A secret handed to a child process through a PID-named temp file was guessable
  and non-exclusive; it is now created with `mktemp` at mode 600 and removed by
  an `EXIT`/`INT`/`TERM` trap.
- Filesystem-derived filenames were echoed to the terminal verbatim, so a cloned
  repo could carry an ESC/CSI/OSC sequence. They are stripped to printable
  characters before printing.
- A portability check that could not run (empty tool python, stderr discarded)
  reported PASS. It now reports WARN.
- Documentation claimed a sync calls the LLM. It does not: `graph_updater.py` has
  no orchestrator reference, so an overnight build needs no key and no network.

[Unreleased]: https://github.com/naelrudd/cgr-code-graph/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/naelrudd/cgr-code-graph/releases/tag/v0.1.0
