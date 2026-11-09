#!/usr/bin/env python3
"""Is every repo in a workspace really in the graph?

Counts, per declared repo, the nodes and edges the graph holds for it. A repo
whose sync was interrupted, or whose language cgr cannot parse, still has a hash
cache under `<graph home>/state/` — so the cache proves a sync was attempted, not
that anything usable landed. This reads the graph itself.

    python3 scripts/audit-workspace.py money
    CGR_HOME=D:/cgr-real python3 scripts/audit-workspace.py realalg

Two key shapes exist, so they are counted differently:
  * code nodes -> key is "<project>.<module>.<name>", the prefix names the project
  * File nodes -> key is the absolute path, so they are matched against repo paths

Exit 0 when every declared repo has definitions, 1 when one is missing or thin
and 2 on a usage error.
"""
import os
import re
import sqlite3
import sys

DECLARED_ONLY_DEFS = ("Function", "Method", "Class", "Enum", "Type", "Interface", "Union")
# Extensions cgr has a parser for. A repo whose files are all in these but holds no
# definitions is a real failure; one whose code is only in UNPARSED is a cgr gap.
PARSED_EXTS = {
    ".py", ".pyi", ".js", ".mjs", ".cjs", ".jsx", ".ts", ".tsx", ".cs", ".rs", ".go",
    ".java", ".kt", ".rb", ".php", ".c", ".h", ".cc", ".cpp", ".hpp", ".swift", ".lua",
    ".sh", ".bash", ".zsh", ".nix", ".scala", ".ex", ".exs", ".sol",
}
UNPARSED_EXTS = {".astro", ".vue", ".svelte", ".elm", ".dart", ".m", ".mm", ".jl"}


def graph_home() -> str:
    return os.environ.get("CGR_HOME") or os.path.join(os.path.expanduser("~"), ".cgr")


def read_repos(toml: str) -> list[tuple[str, str]]:
    text = open(toml, encoding="utf-8").read()
    repos = re.findall(r'path = "([^"]+)"\s*\nproject_name = "([^"]+)"', text)
    # TOML escapes Windows separators; the graph stores both, so normalise to /
    return [(p.replace("\\\\", "\\").replace("\\", "/").rstrip("/"), n) for p, n in repos]


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: audit-workspace.py <workspace>\n"
              "       CGR_HOME=/path/to/graph home python3 scripts/audit-workspace.py <workspace>",
              file=sys.stderr)
        return 2
    ws = argv[1]
    home = graph_home()
    toml = os.path.join(home, "workspaces", f"{ws}.toml")
    db = os.path.join(home, "graph.sqlite")
    for path in (toml, db):
        if not os.path.exists(path):
            print(f"error: {path} not found", file=sys.stderr)
            return 2

    repos = read_repos(toml)
    declared = {name for _, name in repos}
    print(f"workspace {ws}: {len(repos)} declared repo(s) in {home}")

    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    nodes = {}
    for label, key in con.execute("select label, key from cgr_nodes"):
        if not key:
            continue  # IncompleteRun markers carry no key; counted below
        if label == "File":
            # longest path first, so a repo never claims a nested repo's files
            norm = key.replace("\\", "/")
            for path, name in sorted(repos, key=lambda r: -len(r[0])):
                if norm.startswith(path + "/"):
                    d = nodes.setdefault(name, {})
                    d["File"] = d.get("File", 0) + 1
                    ext = os.path.splitext(norm)[1].lower()
                    exts = d.setdefault("_exts", {})
                    if ext:
                        exts[ext] = exts.get(ext, 0) + 1
                    break
            continue
        if key.split(".", 1)[0] in declared:
            nodes.setdefault(key.split(".", 1)[0], {})
            d = nodes[key.split(".", 1)[0]]
            d[label] = d.get(label, 0) + 1

    owner = {}  # node id -> project, to attribute edges to the node that starts them
    for node_id, label, key in con.execute("select id, label, key from cgr_nodes"):
        if key and label != "File":
            owner[node_id] = key.split(".", 1)[0]
    edges = {}
    for (src,) in con.execute("select src from cgr_edges"):
        proj = owner.get(src)
        if proj in declared:
            edges[proj] = edges.get(proj, 0) + 1

    rows, missing = [], []
    for path, name in repos:
        counts = nodes.get(name, {})
        if not counts:
            missing.append((name, path, os.path.isdir(path)))
            continue
        defs = sum(counts.get(label, 0) for label in DECLARED_ONLY_DEFS)
        total = sum(v for k, v in counts.items() if not k.startswith("_"))
        rows.append((name, total, defs, counts.get("File", 0), edges.get(name, 0), path))

    rows.sort(key=lambda r: (r[2], r[0]))
    width = max([len(r[0]) for r in rows] + [7])
    print(f"\n{'project':{width}} {'nodes':>7} {'defs':>6} {'files':>6} {'edges':>7}")
    for name, n, defs, files, e, _ in rows:
        print(f"{name:{width}} {n:7} {defs:6} {files:6} {e:7}")

    if missing:
        print("\nNO NODES AT ALL (the sync either never ran or wrote nothing):")
        for name, path, exists in missing:
            state = "path present" if exists else "PATH GONE"
            print(f"  {name:{width}} {state:12} {path}")

    # A repo with no definitions is one of three things: docs (nothing to parse), a
    # language cgr has no grammar for (files land, code does not), or a sync that
    # wrote files without their contents. Only a repo with no nodes at all fails.
    docs, unparsed, broken = [], [], []
    for name, n, defs, files, e, path in rows:
        if defs:
            continue
        exts = nodes.get(name, {}).get("_exts", {})
        parsed = {x: c for x, c in exts.items() if x in PARSED_EXTS}
        gap = {x: c for x, c in exts.items() if x in UNPARSED_EXTS}
        # one script with no functions is normal; several parsed files and no
        # definitions at all is a sync that lost the code
        if sum(parsed.values()) >= 3 and (not gap or sum(parsed.values()) > sum(gap.values())):
            broken.append((name, files, {x: c for x, c in parsed.items()}))
        elif gap:
            unparsed.append((name, files, sorted(gap)))
        else:
            docs.append((name, files, sorted(exts)))

    if broken:
        print("\nCODE BUT NO DEFINITIONS — the sync wrote files without their contents:")
        for name, files, exts in broken:
            print(f"  {name:{width}} {files} files ({', '.join(exts)}): re-run its sync")
    if unparsed:
        print("\nA LANGUAGE cgr HAS NO PARSER FOR (indexed as files only, no code graph):")
        for name, files, exts in unparsed:
            print(f"  {name:{width}} {files} files ({', '.join(exts)}): nothing to query here")
    if docs:
        print("\nNOTHING TO PARSE (docs/config only) — expected:")
        for name, files, exts in docs:
            print(f"  {name:{width}} {files} files ({', '.join(exts) or 'no extension'})")

    # leftovers: project-prefixed nodes whose name no workspace declares
    pat = re.compile(r"^([A-Za-z0-9._-]+__[0-9a-f]{8})\.")
    stray = {}
    for (key,) in con.execute("select key from cgr_nodes"):
        m = pat.match(key or "")
        if m and m.group(1) not in declared:
            stray[m.group(1)] = stray.get(m.group(1), 0) + 1
    if stray:
        print("\nIN THE GRAPH BUT NOT DECLARED (leftover from an older layout):")
        for name, n in sorted(stray.items()):
            print(f"  {name:{width}} {n} nodes")

    markers = con.execute("select count(*) from cgr_nodes where label='IncompleteRun'").fetchone()[0]
    if markers:
        print(f"\n{markers} interrupted sync marker(s): a run was killed mid-write. "
              f"The next sync of that project clears it.")

    print(f"\ndeclared: {len(repos)}  with nodes: {len(rows)}  missing: {len(missing)}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
