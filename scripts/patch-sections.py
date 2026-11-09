#!/usr/bin/env python3
"""Embed and read markdown sections, so a docs corpus is queryable too.

cgr indexes markdown: every heading becomes a `Section` node carrying
`path`/`start_line`/`end_line`, hung off the file's `Module` by
`CONTAINS_SECTION`. What it never does is *embed* those sections --
`EMBEDDED_NODE_LABELS` and the embeddings query are both hard-coded to
`Function` + `Method`, and `definition` / `context` refuse to return a
`Section` body. So a docs-heavy corpus answers "No semantic matches" no matter
how often it is synced, which is the one thing an agent needs to avoid reading
whole files.

This patches four places in the *installed* package:

  constants/graph.py   EMBEDDED_NODE_LABELS  += Section
  constants/graph.py   CYPHER_QUERY_EMBEDDINGS += CONTAINS_SECTION branch
  graph_query.py       _DEFINITION_LABELS    += Section
  context_slice.py     _DEFINITION_LABELS    += Section

Idempotent: a second run reports "already patched" and writes nothing. It edits
site-packages, so it is lost on `uv tool upgrade` -- re-run it afterwards, and
`doctor.sh` warns when the package is back to stock.

    python scripts/patch-sections.py            # apply
    python scripts/patch-sections.py --check    # exit 1 when unpatched
    python scripts/patch-sections.py --revert   # back to stock
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

MARK = "# patched by cgr-code-graph scripts/patch-sections.py"

EDITS: list[tuple[str, str, str, str]] = [
    (
        "constants/graph.py",
        "EMBEDDED_NODE_LABELS",
        """EMBEDDED_NODE_LABELS: frozenset[NodeLabel] = frozenset(
    {NodeLabel.FUNCTION, NodeLabel.METHOD}
)""",
        """EMBEDDED_NODE_LABELS: frozenset[NodeLabel] = frozenset(
    {NodeLabel.FUNCTION, NodeLabel.METHOD, NodeLabel.SECTION}  """ + MARK + """
)""",
    ),
    (
        "constants/graph.py",
        "CYPHER_QUERY_EMBEDDINGS",
        """CYPHER_QUERY_EMBEDDINGS = (
    _CYPHER_EMBEDDING_DIRECT
    + _CYPHER_EMBEDDING_COLUMNS
    + "UNION\\n"
    + _CYPHER_EMBEDDING_CONTAINER_METHOD
    + _CYPHER_EMBEDDING_COLUMNS
)""",
        '''# ''' + "'" + '''Markdown sections are hung off their file's Module by CONTAINS_SECTION,
# but traversing that edge from the embedded engine returns one row per file
# (14 of 97 sections in a probe), so this scopes on the section's own qualified
# name instead. A Section carries its own `path`, which is why it needs its own
# RETURN block rather than the `m.path` one the two code branches share.''' + "'" + '''
_CYPHER_EMBEDDING_SECTION = """
MATCH (n:Section)
WHERE n.qualified_name STARTS WITH ($project_name + '.')
"""

_CYPHER_EMBEDDING_SECTION_COLUMNS = """RETURN id(n) AS node_id,
       n.qualified_name AS qualified_name, head(labels(n)) AS label,
       n.start_line AS start_line, n.end_line AS end_line,
       n.path AS path
"""

CYPHER_QUERY_EMBEDDINGS = (
    _CYPHER_EMBEDDING_DIRECT
    + _CYPHER_EMBEDDING_COLUMNS
    + "UNION\\n"
    + _CYPHER_EMBEDDING_CONTAINER_METHOD
    + _CYPHER_EMBEDDING_COLUMNS
    + "UNION\\n"
    + _CYPHER_EMBEDDING_SECTION
    + _CYPHER_EMBEDDING_SECTION_COLUMNS
)''',
    ),
    (
        "constants/graph.py",
        "DEFINITION_NODE_LABELS",
        """        NodeLabel.UNION,
        NodeLabel.MODULE,
    }
)""",
        """        NodeLabel.UNION,
        NodeLabel.MODULE,
        NodeLabel.SECTION,  """ + MARK + """
    }
)""",
    ),
]

DEFINITION_OLD = """_DEFINITION_LABELS = frozenset(
    {
        cs.NodeLabel.FUNCTION.value,
        cs.NodeLabel.METHOD.value,
        cs.NodeLabel.CLASS.value,"""

DEFINITION_NEW = """_DEFINITION_LABELS = frozenset(
    {
        cs.NodeLabel.FUNCTION.value,
        cs.NodeLabel.METHOD.value,
        cs.NodeLabel.SECTION.value,  """ + MARK + """
        cs.NodeLabel.CLASS.value,"""


def tool_site_packages() -> Path:
    """Resolve the installed codebase_rag without trusting $HOME or $APPDATA."""
    try:
        out = subprocess.run(
            ["uv", "tool", "dir"], capture_output=True, text=True, timeout=60
        ).stdout.strip()
        if out:
            cand = Path(out) / "code-graph-rag" / "Lib" / "site-packages" / "codebase_rag"
            if cand.is_dir():
                return cand
    except Exception:
        pass
    try:
        import codebase_rag  # type: ignore[import-not-found]

        return Path(codebase_rag.__file__).resolve().parent
    except Exception:
        raise SystemExit("patch-sections: cannot find the installed codebase_rag package")


def apply(root: Path, revert: bool, check: bool) -> int:
    targets = list(EDITS)
    for rel in ("graph_query.py", "context_slice.py"):
        targets.append((rel, "_DEFINITION_LABELS", DEFINITION_OLD, DEFINITION_NEW))

    changed = unpatched = 0
    for rel, label, old, new in targets:
        path = root / rel
        if not path.exists():
            if check:
                print(f"  MISSING {rel} — is code-graph-rag installed?")
                unpatched += 1
            continue
        src = path.read_text(encoding="utf-8")
        stock = path.with_suffix(path.suffix + ".cgr-stock")
        already = new in src or (
            MARK in src and rel.startswith("graph_query") and "SECTION.value" in src
        )
        if revert:
            if stock.exists():
                shutil.copy2(stock, path)
                print(f"  restored {rel} from .cgr-stock")
                changed += 1
            elif already:
                path.write_text(src.replace(new, old), encoding="utf-8")
                print(f"  reverted {rel} :: {label}")
                changed += 1
            continue
        if already:
            if check:
                print(f"  ok       {rel} :: {label}")
            continue
        if check:
            print(f"  UNPATCHED {rel} :: {label}")
            unpatched += 1
            continue
        if old not in src:
            print(f"  SKIP     {rel} :: {label} — source did not match; upstream changed")
            unpatched += 1
            continue
        path.write_text(src.replace(old, new, 1), encoding="utf-8")
        print(f"  patched  {rel} :: {label}")
        changed += 1

    if check:
        print(f"\n{'patched' if not unpatched else f'{unpatched} edit(s) missing'}")
        return 0 if not unpatched else 1
    if changed:
        print(f"\n{changed} file edit(s) written. Re-sync a docs project to embed its sections:")
        print("  bash scripts/index.sh <workspace>")
    else:
        print("\nnothing to do")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="report only; exit 1 when unpatched")
    ap.add_argument("--revert", action="store_true", help="restore the stock package")
    ap.add_argument("--backup", action="store_true", help="copy the four files to *.cgr-stock first")
    a = ap.parse_args()

    root = tool_site_packages()
    print(f"codebase_rag: {root}")
    if a.backup and not a.check and not a.revert:
        for rel in ("constants/graph.py", "graph_query.py", "context_slice.py"):
            src = root / rel
            if src.exists():
                shutil.copy2(src, src.with_suffix(src.suffix + ".cgr-stock"))
                print(f"  backup   {rel}.cgr-stock")
    return apply(root, a.revert, a.check)


if __name__ == "__main__":
    sys.exit(main())
