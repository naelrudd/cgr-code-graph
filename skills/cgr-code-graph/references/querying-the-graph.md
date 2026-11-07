# Querying a cgr workspace's graph over MCP

Everything here is deterministic — no LLM. `semantic_search` embeds the query locally with UniXcoder and matches `vectors.sqlite`; the rest are fixed graph queries. `ask_agent` is the only LLM-backed tool.

## Always pass `project`

A workspace server is not scoped to one repo, so a query without `project` is ambiguous and gets refused:

```
Workspace 'work' holds 21 projects and none is rooted at this server's directory;
pass `project` (one of: api__6dbff338, web__b0abda8d, ...)
```

Project names are `<dirname>__<hash>`. Two ways to get them: read `~/.cgr/workspaces/<name>.toml` (`project_name = "..."` per repo), or call `list_projects`.

## `list_projects` shows only what is queryable NOW

It lists *indexed* projects, not workspace members. During a long sync the list grows project by project, so a project present in the TOML can still answer:

```
Unknown project 'web__b0abda8d'. Indexed projects of workspace 'work':
cli__55d78db8, svc__d90b2af3, agent__ded7fc12, api__6dbff338
```

Never claim cross-project coverage before every repo appears in that list. Say which projects the answer actually covered.

## The three-hop answer for "where is X"

1. `semantic_search(natural_language_query="<the purpose in words>", project="<owner>", top_k=8)`
   Describe *purpose*, not identifiers — that is the whole point versus grep. "function that writes an audit or moderation log entry when an admin approves a template" finds a helper whose name never contains the word "log".
   Scores are cosine-ish; treat >0.5 as strong, 0.3–0.5 as worth opening, below 0.3 as noise.
2. `get_code_snippet(qualified_name="<hit>")` — returns `source_code`, `file_path`, `line_start`, `line_end`. Confirm the body matches what the user means before quoting anything.
3. `callers(qualified_name="<hit>", project="<owner>")` — one row per call site with `path`, `line`, `through`, `arg_count`. `depth=2..5` follows the callers' callers.

## The finding is usually a second door

After locating the shared helper, search the *action verb* again ("approve template", "set approval") and inspect every hit. Parallel entry points that never call the shared helper are the actual answer — a duplicate mutation that skips the audit log, the notification, or the timestamp. Report it as a divergence with both `path:line` references, not as "the helper is here".

That is the class of defect keyword search cannot produce: the two paths have different names, so nothing co-locates them but the meaning.

## Reading results honestly

- Quote `path:line` and real source. Never paraphrase a body you have not opened with `get_code_snippet`.
- `get_code_snippet` on a handler defined inline returns a synthetic qualified name like `convex.admin.handler@198` — the `@<line>` suffix is the only disambiguator between sibling handlers in one file.
- A `semantic_search` hit can be a UI component or config helper that merely shares vocabulary. Check `label` (Function / Method / Class / Module / Section) before believing it.
- `Section` nodes mean markdown, not code — useful for docs questions, wrong for "who calls this".

## Other deterministic tools worth reaching for

- `find_duplicate_code` — structural duplicates across projects; the reason a multi-repo graph beats per-repo tooling.
- `importers` / `endpoints` — module dependency edges and HTTP surface inventory.
- `explain_traceback` / `rank_root_causes` — map a Python traceback's frames onto graph nodes.
- `flow_verdict` — source-to-sink reachability, for "does user input reach this query".
- `get_function_source`, `definition`, `implementors`, `overrides`, `callees`, `tests_reaching`, `remote_dependencies` — name-based lookups when the exact symbol is already known.
