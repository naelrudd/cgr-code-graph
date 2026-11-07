# cgr-code-graph

Turn a multi-project drive or monorepo into a queryable code graph — **local embeddings, no API key, no Docker, no Java, no GPU**.

A skill pack + installer for [code-graph-rag](https://github.com/vitali87/code-graph-rag) (`cgr`) tuned for the case the upstream docs don't cover: one workspace spanning ~20 unrelated projects on one machine, indexed overnight, queried by agents through MCP.

Measured on the reference corpus (21 projects, 9,386 files, 89 MB, ~22M tokens):

| step | result |
| --- | --- |
| first full graph pass | 449 s for 2,321 nodes (1,313 functions, 196 files, 379 folders, 172 modules) |
| semantic embeddings | 420 vectors, local UniXcoder 768d, ~1.1 chunk/s CPU |
| cost / quota | zero — no hosted embedding API touched |
| re-sync after edits | seconds (per-project hash cache) |
| storage | one 13 MB SQLite file + one vectors SQLite file |

The upstream README assumes a single repo, a hosted embedder, and a working `ollama`/Neo4j stack. This pack is the shape that survives contact with a real Windows box.

## Quick start

```bash
git clone https://github.com/naelrudd/cgr-code-graph
cd cgr-code-graph
bash scripts/install.sh                      # uv tool + missing httpx + torch/transformers
bash scripts/init-workspace.sh money D:/work # detect projects, register, start indexing
bash scripts/register-mcp.sh money D:/work   # make it automatic (Hermes example)
bash scripts/refresh.sh money                # later: incremental re-sync, seconds
bash scripts/ask.sh money "where is X built?"  # CLI query, no agent needed
```

PowerShell users: `pwsh -File scripts/install.ps1` (same steps).

## What you get

The MCP server exposes 25 read-only tools. The ones that change how agents work:

- `semantic_search` — natural-language query over every function in every project
- `get_code_snippet` / `get_function_source` — exact source for a hit, by qualified name
- `callers` / `importers` — who calls this, what this imports, across project boundaries
- `find_duplicate_code` — structural duplicates, the thing grep cannot find
- `endpoints` — HTTP surface inventory
- `ask_agent` — the whole graph as a chat target
- `explain_traceback` / `rank_root_causes` — traceback → graph correlation
- `flow_verdict` — source-to-sink reachability for a sanitizer question

## Three usage layers

1. **Automatic (recommended).** Register `cgr mcp-server --read-only` with your agent. Tools then appear next to the built-in ones.
2. **Contextual.** Drop a short "use cgr before grep" block into the repo's `CLAUDE.md` / `AGENTS.md` — see [`examples/CLAUDE.md`](examples/CLAUDE.md). This is what makes a *non*-`cgr`-aware agent reach for graph tools first.
3. **Manual.** `bash scripts/ask.sh money "where is the listing search index built?"`

## Requirements

- `uv` (installs everything else)
- ~1.1 GB disk for torch + transformers + the embedding model
- Python 3.11+ via uv; Windows, macOS, or Linux
- An OpenAI-compatible endpoint **only** if you want `ask_agent` / NL→Cypher. Graph building and the deterministic tools need no LLM at all.

## When *not* to use this

- **Docs, papers, images, video** → use [graphify](https://github.com/naelrudd/graphify). cgr is code-only; it parses with tree-sitter.
- **One small repo** → `cgr` works, but a plain grep is faster than a 7-minute ingest. The break-even is somewhere around "more than one project" or "I can't remember which repo has that function".
- **You need graph traversal and vector search in a single query** → Neo4j/Memgraph backend; this pack deliberately stays on embedded SQLite+sqlite-vec.

## Docs

- [`docs/windows-gotchas.md`](docs/windows-gotchas.md) — the five traps that cost real hours: the missing `httpx` in the wheel, the home-directory MCP guard, the `openai` provider rejecting custom model ids, the hosted-embedding dead ends, and the interactive prompt that silently cancels registration.
- [`docs/benchmark.md`](docs/benchmark.md) — full measurements and the throughput math for sizing your own corpus.
- [`docs/incremental-sync.md`](docs/incremental-sync.md) — why a second sync does not re-embed the corpus: the file hash cache and the content-hash embedding cache, what each change costs, and the one caveat (the cache is saved at the end of the pass).
- [`skills/cgr-code-graph/SKILL.md`](skills/cgr-code-graph/SKILL.md) — the same content as an agent skill.

## Credit

Built entirely on [vitali87/code-graph-rag](https://github.com/vitali87/code-graph-rag) — go star that. This repo is packaging, measured configuration, and bug reports, not a fork.

MIT © Natan (naelrudd)
