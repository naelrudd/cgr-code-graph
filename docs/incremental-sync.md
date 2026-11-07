# Incremental sync — what gets re-computed, and what does not

Short answer: yes. A second `cgr start --update-graph` over an already-indexed
tree does **not** re-parse or re-embed the whole corpus. Two independent caches
decide that, and both are on by default.

```
D:\work\myrepo
   │
   ├─ 1. file hash cache ──── changed?  no → file is skipped entirely
   │                                       (no parse, no nodes, no embedding)
   │
   └─ 2. embedding cache ──── sha256(snippet) already known?  yes → vector reused
                                                        no  → embed only this one
```

## 1. File hash cache (skips parsing)

`_load_hash_cache` / `_save_hash_cache` in `graph_updater.py`, stored under
`~/.cgr/state/<project>__<hash>/`. Keyed by file path + content hash. An
unchanged file is not re-parsed, so it emits no nodes and no relationships —
the pass is I/O bound instead of CPU bound.

## 2. Embedding cache (skips the model)

`EmbeddingCache` in `embedder.py`:

```python
def _content_hash(content: str) -> str:
    return hashlib.sha256(f"{_cache_namespace()}\x00{content}".encode()).hexdigest()
```

`embed_code_batch` first asks the cache for every snippet in the batch
(`get_many`); only the misses reach the model (`_unixcoder_embed_batch`), and the
results are written back. Stored at `~/.cgr/.embedding_cache.json`.

The namespace is the embedder identity (model + dimension). Switching embedders
therefore invalidates every entry instead of silently mixing 768-d and 4096-d
vectors — which is the correct behaviour, and the reason the file is not shared
between providers.

## What a refresh actually costs

| change | work |
| --- | --- |
| one function edited | that file re-parsed; its functions re-embedded |
| one file added | that file parsed; its functions embedded |
| one file deleted | nodes pruned (`_prune_orphan_nodes`), stale vector points deleted (`delete_stale_embeddings`) |
| nothing changed | crawl + hash compare only, seconds to a couple of minutes on 20k files |
| embedder changed | everything re-embedded (namespace miss) — expected |

## The one caveat: the embedding cache is saved at the end of the pass

`get_embedding_cache().save()` is called once, after pass 5 finishes
(`graph_updater.py`, end of `_generate_semantic_embeddings`), plus once in the
exception handler. So:

- **Interrupt a long first sync** → the vector store keeps whatever points were
  already flushed (they are written in batches), but the JSON cache is only as
  fresh as the last completed pass. The next run re-embeds the difference.
- **Let it finish once** → every later sync is cheap.

Practical rule: the first full index is the only expensive one. Budget it
accordingly (`scripts/doctor.sh <root>` prints an estimate), then refresh freely.

## Verifying it, instead of trusting it

```bash
# how many vectors are stored right now
python -c "import sqlite3,os;c=sqlite3.connect('file:'+os.path.expanduser('~/.cgr/vectors.sqlite')+'?mode=ro',uri=True);print(c.execute('select count(*) from cgr_vector_points').fetchone()[0])"

# how many snippets the cache can answer without the model
python -c "import json,os;print(len(json.load(open(os.path.expanduser('~/.cgr/.embedding_cache.json')))))"
```

Then touch one file and sync again — the cache count grows by roughly the
number of functions in that file, not by the size of the corpus.

## Watching, instead of syncing on a timer

`cgr watch` re-syncs on file change. For a multi-project workspace the cheaper
habit is a refresh before a work session:

```bash
bash scripts/refresh.sh work
```
