# Changelog

All notable changes to this project are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version tracks this kit's own scripts and docs, not the `code-graph-rag`
release it installs.

## [Unreleased]

### Fixed

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
