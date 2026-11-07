# Benchmark

Measurements from the reference run. Machine: Windows 11, CPU-only (no GPU), `uv`-managed Python 3.14, `code-graph-rag` 0.5.0, local UniXcoder (768-dim) embeddings.

## Corpus sizing

Whole-drive workspace, 21 unrelated projects, measured with case-insensitive exclusions (`node_modules`, `.venv`, `venv*`, `Library`, `.next`, `dist`, `build`, `__pycache__`, `.git`):

| metric | value |
| --- | --- |
| files | 9,386 |
| size | 89.1 MB |
| tokens (approx) | 22.3M |
| chunks @ ~900 tokens | ~25,000 |

**Exclusion is where the errors come from.** A case-sensitive filter that excluded only `Library/` still matched `Library/` correctly on Windows, but missed `library/`, `venv-*`, and `lib/`; the same corpus then measured 49,000 files / 558 MB. On a Unity or Python corpus, use case-insensitive matching or you will over-size by 5x and promise a run time that is wrong by the same factor.

## Single-project pass (measured)

One mid-size web application, 1,313 functions (schema-driven backend plus a typed frontend):

| stage | result |
| --- | --- |
| full `--update-graph` | 449.17 s |
| graph output | 2,321 nodes — 1,313 function, 196 file, 379 folder, 172 module |
| semantic embeddings | 420, reconciled ("all 420 expected embeddings found") |
| embedding throughput | ~1.1 chunk/s, CPU-only |
| hash cache | 196 entries written to `~/.cgr/state/<project>/` |
| artifacts | `graph.sqlite` + `vectors.sqlite`, 13 MB total |

## Extrapolation to a full drive

At ~1.1 chunk/s, ~25,000 chunks is **roughly 6-7 hours** for the first complete pass on this corpus. Things worth knowing before you start:

- It is CPU-bound on embedding, not on parsing. Parsing 9,386 files is minutes; embedding is the wall-clock.
- It is resumable in effect: the per-project hash cache means a re-run skips everything already embedded, so an interrupted first pass does not restart from zero.
- Later passes are **seconds**, because an unchanged file is never re-embedded.
- Do not run it in the foreground of an interactive session. Launch it as a tracked background job and check the graph file size to watch progress.
- Disk: the graph stays in the tens of MB even for tens of thousands of nodes. The 1.1 GB cost is `torch` + `transformers` + the model weights, one time.

## Hosted embedders, measured

Probed against live endpoints, same corpus, before settling on local:

| backend | finding |
| --- | --- |
| hosted embedding API, free tier | 3072-dim, 100 inputs in 6.45 s — but `429 ... 30000 tokens/min`, `100 requests/min`; dies mid-ingest |
| same via an OpenAI-compatible local router | response omitted `index` on the first item → `response is malformed: 'index'`; unusable for ingest |
| NVIDIA-hosted embed models (4096-dim, 2048-dim) | single input works; 2+ inputs → `500 service inference failed`. Query-side only |
| **local UniXcoder 768-dim** | ~1.1 chunk/s, zero cost, zero quota, offline — the only one that finished |

Full detail and the exact error strings: [`windows-gotchas.md`](windows-gotchas.md#4-hosted-embedders-are-the-wrong-default-for-bulk-ingest).

## Query quality

Cheap end-to-end proof that graph + vectors are live, with no agent in the loop:

```bash
cgr start --workspace <ws> --no-sync --ask-agent "Where does the record search index get built, and which file defines its validator arguments?"
```

On the reference project this returned the right file and the right line range for both
halves of the question. More useful than the answer, it surfaced a real inconsistency:
one mutation in a family of three skipped the audit-log write its two siblings
performed. That is the class of finding keyword search does not produce.
