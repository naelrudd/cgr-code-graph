# cgr-code-graph

[![CI](https://github.com/naelrudd/cgr-code-graph/actions/workflows/ci.yml/badge.svg)](https://github.com/naelrudd/cgr-code-graph/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platforms](https://img.shields.io/badge/platform-Windows%20%7C%20macOS%20%7C%20Linux-lightgrey.svg)](#requirements)
[![cgr](https://img.shields.io/badge/code--graph--rag-0.5.0-informational.svg)](https://github.com/vitali87/code-graph-rag)

Turn a multi-project drive or monorepo into a queryable code graph — **local
embeddings, no API key, no Docker, no Java, no GPU**.

An installer, a preflight check and a skill pack for
[`code-graph-rag`](https://github.com/vitali87/code-graph-rag) (`cgr`), tuned for
the case upstream does not cover: one workspace spanning ~20 unrelated projects
on one machine, indexed overnight, queried by agents through MCP.

```text
  your drive                    cgr, entirely local                your agent
  ──────────                    ───────────────────                ──────────
  20 projects   ──parse──▶  graph.sqlite   (nodes + edges)
               tree-sitter  vectors.sqlite (sqlite-vec)  ──MCP──▶  semantic_search
               + UniXcoder                                  stdio   callers · importers
               (768-d, CPU)                                         find_duplicate_code
                                                                    endpoints · ask_agent
```

Nothing leaves the machine: a sync is local parsing plus a local embedding model.
An LLM endpoint is optional and only used by `ask_agent`.

## Contents

- [Quick start](#quick-start)
- [What you get](#what-you-get)
- [Measured, not promised](#measured-not-promised)
- [Three usage layers](#three-usage-layers)
- [Requirements](#requirements)
- [When not to use this](#when-not-to-use-this)
- [Troubleshooting](#troubleshooting)
- [Docs](#docs)
- [Security](#security)
- [Contributing](#contributing)
- [Credit](#credit)

## Quick start

```bash
git clone https://github.com/naelrudd/cgr-code-graph
cd cgr-code-graph

bash scripts/install.sh                       # uv tool + the httpx the wheel omits + torch/transformers
bash scripts/doctor.sh D:/work                # preflight: fail here, not 40 minutes into a sync
bash scripts/init-workspace.sh work D:/work   # detect projects, register them, start indexing
bash scripts/register-mcp.sh work D:/work     # make it automatic (Hermes shown; any MCP client works)
bash scripts/refresh.sh work                  # later: incremental re-sync, seconds
bash scripts/ask.sh work "where is X built?"  # one question, no agent session
```

PowerShell: `pwsh -File scripts/install.ps1` covers the install half; the other
scripts run under git-bash or WSL.

Two things the first run will show, both expected:

- `Warning: You are sending unauthenticated requests to the HF Hub` — the model is
  being downloaded anonymously. It still works; a read token only raises rate
  limits. `bash scripts/hf-login.sh` handles that safely, or ignore it.
- A first full pass takes hours on a large corpus: it is CPU-bound on the
  embedding model (~1.1 functions/s measured). Run it as a tracked background
  job, and check progress with `select count(*) from cgr_nodes` in
  `~/.cgr/graph.sqlite` rather than by watching the log.

## What you get

The MCP server exposes **26 read-only tools** (cgr 0.5.0). The ones that change
how an agent works:

| tool | why it matters |
| --- | --- |
| `semantic_search` | natural-language query over every function in every project |
| `get_code_snippet` / `get_function_source` | exact source for a hit, by qualified name |
| `callers` / `importers` | who calls this, what this imports — across project boundaries |
| `find_duplicate_code` | structural duplicates; the thing `grep` cannot find |
| `endpoints` | HTTP surface inventory |
| `ask_agent` | the whole graph as a chat target (needs an LLM endpoint) |
| `explain_traceback` / `rank_root_causes` | traceback → graph correlation |
| `flow_verdict` | source-to-sink reachability for a sanitizer question |

## Measured, not promised

Reference corpus: 21 projects, 9,386 files, 89 MB, ~22M tokens, on one Windows 11
machine with no GPU.

| step | result |
| --- | --- |
| first full graph pass | 449 s for 2,321 nodes (1,313 functions, 196 files, 379 folders, 172 modules) |
| semantic embeddings | 420 vectors, local UniXcoder 768d, ~1.1 chunk/s on CPU |
| cost / quota | zero — no hosted embedding API touched |
| re-sync after edits | seconds (per-project hash cache, per-snippet embedding cache) |
| storage | one 13 MB `graph.sqlite` + one vectors SQLite file |

Full measurements, including the throughput math for sizing your own corpus:
[`docs/benchmark.md`](docs/benchmark.md).

## Three usage layers

1. **Automatic (recommended).** Register `cgr mcp-server --read-only` with your
   agent, and the tools appear next to the built-in ones.
2. **Contextual.** Drop the short "use cgr before grep" block from
   [`examples/CLAUDE.md`](examples/CLAUDE.md) into a repo's `CLAUDE.md` /
   `AGENTS.md`. This is what makes a *non*-`cgr`-aware agent reach for graph tools
   first.
3. **Manual.** `bash scripts/ask.sh work "where is the listing search index built?"`

## Requirements

- `uv` — it installs everything else
- ~1.1 GB disk for `torch` + `transformers` + the embedding model
- Python 3.11+ (managed by `uv`); Windows, macOS or Linux
- An OpenAI-compatible endpoint **only** for `ask_agent` / NL→Cypher. Graph building
  and the deterministic tools need no LLM at all.

## When not to use this

- **Docs, papers, images, video** → cgr is code-only; it parses with tree-sitter.
  Markdown is indexed as `Section` nodes, everything else is skipped.
- **One small repo** → plain `grep` is faster than a multi-minute ingest. The
  break-even is roughly "more than one project" or "I can't remember which repo
  has that function".
- **Graph traversal and vector search in one query** → use the Neo4j/Memgraph
  backend. This kit deliberately stays on embedded SQLite + `sqlite-vec`.

## Troubleshooting

Run the preflight first — it turns each known failure into a fix line:

```bash
bash scripts/doctor.sh            # environment
bash scripts/doctor.sh D:/work    # environment + corpus size and a runtime estimate
```

| symptom | cause | fix |
| --- | --- | --- |
| `ModuleNotFoundError: No module named 'httpx'` | the wheel omits a module it imports | `bash scripts/install.sh` |
| `tool venv python not found` on a healthy install | `$HOME` is an MSYS shadow dir | `bash scripts/hf-login.sh --where` prints every path searched |
| `Configuration error: The MCP server was started in C:\Users\...` | clients spawn servers from the home dir, and cgr refuses to serve there | pass `TARGET_REPO_PATH`, as `register-mcp.sh` does |
| a sync stuck 10+ minutes on a two-file repo | two syncs contending on `graph.sqlite` | let one finish; `doctor.sh` lists strays |
| `Got unexpected extra argument(s)` | the exclude globs were re-split by a launcher | run `scripts/index.sh`, which keeps them quoted |
| `Unknown openai model '<id>'` | `ORCHESTRATOR_PROVIDER=openai` only accepts its own model list | use `litellm_proxy` for a custom endpoint |

The mechanism behind each: [`docs/windows-gotchas.md`](docs/windows-gotchas.md).

## Docs

- [`docs/windows-gotchas.md`](docs/windows-gotchas.md) — the five traps that cost
  real hours: the missing `httpx` in the wheel, the home-directory MCP guard, the
  `openai` provider rejecting custom model ids, the hosted-embedding dead ends,
  and the interactive prompt that silently cancels registration.
- [`docs/benchmark.md`](docs/benchmark.md) — full measurements and the throughput
  math for sizing your own corpus.
- [`docs/incremental-sync.md`](docs/incremental-sync.md) — why a second sync does
  not re-embed the corpus: the file hash cache and the content-hash embedding
  cache, what each change costs, and the one caveat.
- [`docs/huggingface-token.md`](docs/huggingface-token.md) — the optional HF token:
  per-OS paths, why the paste shows nothing, how to verify and revoke.
- [`skills/cgr-code-graph/SKILL.md`](skills/cgr-code-graph/SKILL.md) — the same
  knowledge packaged as an agent skill.
- [`CHANGELOG.md`](CHANGELOG.md) — what changed, and which upstream defects this
  kit works around.

## Security

The kit writes to your user profile (`~/.cgr`, the `uv` tool venv, optionally
`~/.cache/huggingface`), so it is written to be auditable rather than clever:
secrets never travel through shell redirection or get echoed, temp files are
created exclusively at mode 600, paths are resolved from your account instead of a
directory listing, and every preflight check fails closed.

The complete threat model, and what is in scope: [`SECURITY.md`](SECURITY.md).
Report a vulnerability through GitHub's private advisory flow, not a public issue.

## Contributing

The most valuable contribution here is a pitfall with its exact error string, or a
measured number. See [`CONTRIBUTING.md`](CONTRIBUTING.md) — it lists the commands
CI runs and the portability rules that are not negotiable. Participation is
covered by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md).

## Credit

Built entirely on [vitali87/code-graph-rag](https://github.com/vitali87/code-graph-rag)
— go star that. This repo is packaging, measured configuration and bug reports,
not a fork. Defects in the dependency are reported upstream rather than patched in
a private copy.

MIT © Natan (naelrudd)
