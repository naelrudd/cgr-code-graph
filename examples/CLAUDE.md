# Paste this block into a repo's CLAUDE.md / AGENTS.md so the agent reaches
# for the code graph instead of grep. Adjust the workspace name.

## Code Graph (cgr) — use BEFORE grep

A cross-project code graph lives in `~/.cgr/` (SQLite + sqlite-vec, no server required).

- The `cgr` MCP server exposes 25 read-only tools. For any "where is X", "who calls Y",
  "is this duplicated", "what endpoints exist" question across projects, use
  `semantic_search`, `get_function_source` / `get_code_snippet`, `callers` / `importers`,
  `find_duplicate_code`, or `endpoints` before falling back to grep.
- CLI alternative:
  `cgr start --workspace <workspace> --ask-agent "<question>"`
- Re-index after large edits: `cgr start --workspace <workspace> --update-graph`
  (incremental via hash cache — seconds when little changed). Never pass `--clean`
  unless the graph itself is corrupt; it discards the whole graph.
- Embeddings are local (UniXcoder 768-dim) — no API key, no quota, no cost.
