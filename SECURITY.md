# Security policy

## What this repository is

A shell/PowerShell/Python **installer and preflight kit** around
[`code-graph-rag`](https://github.com/vitali87/code-graph-rag). It is not a
service, it ships no binaries, and it has no runtime of its own: it runs `uv`,
writes a few files under your user profile, and starts an MCP server that is
read-only by default.

That shapes what is in scope. A bug in `cgr` itself belongs upstream; a bug in
how this kit invokes it, resolves paths, or handles a secret belongs here.

## Reporting a vulnerability

Use **GitHub private vulnerability reporting**: repository → *Security* →
*Report a vulnerability*. Do not open a public issue for a suspected
vulnerability.

Please include the affected script and line, the platform (Windows git-bash,
WSL, Linux, macOS), what an attacker gains, and the smallest reproduction you
have. If the finding needs a sandbox you do not have, say so — an unverified but
source-grounded report is still useful.

Expect an acknowledgement within a few days. This is a volunteer project, so
there is no paid bounty and no formal SLA.

## Scope

In scope — anything in `scripts/`, `tests/`, or the MCP registration path:

| area | example class |
| --- | --- |
| secret handling | a token reaching disk with world-readable permissions, a temp file another local user can pre-create or symlink, a token echoed to the terminal or a log |
| path and identity resolution | executing a binary from another account's profile, accepting a directory listing as an identity, failing open when the account cannot be determined |
| terminal safety | relaying filesystem-controlled names (ESC/CSI/OSC/BEL) to the terminal |
| fail-open logic | a check that reports PASS because it could not run |
| supply chain | installing an unpinned package, trusting a `where uv` hit inside the working tree |
| MCP surface | a registration that silently grants write tools, a server reachable beyond loopback without auth |

Out of scope:

- Vulnerabilities in `code-graph-rag`, `uv`, `torch`, or the Hugging Face Hub —
  report those to their maintainers. This kit can document the workaround.
- Anything that requires an attacker who already controls your shell account,
  your `PATH`, or your user profile: at that point they can read the same files
  directly.
- Missing hardening with no demonstrated effect (no secret exposed, no boundary
  crossed). Say what an attacker gains or it is a note, not a finding.

## What the kit touches

Useful when judging a report — the complete list:

- the `uv` tool venv for `code-graph-rag` (`uv tool dir`) — installed, upgraded,
  and given extra packages (`httpx`, `torch`, `transformers`)
- `~/.cgr/` — `graph.sqlite`, `vectors.sqlite`, workspace definitions, per-project
  hash caches
- `~/.cache/huggingface/` — the optional read-scoped token and the model cache
- your agent's MCP configuration (`hermes mcp add`, or the JSON/TOML you point
  another client at)

It never asks for a password, never writes to system directories, never opens a
port by default (`cgr mcp-server` is stdio; the HTTP mode is opt-in and refuses
non-loopback binds without a bearer token), and never sends your source code
anywhere — a sync is local parsing plus local embeddings.

## Handling a leaked token

If a Hugging Face token was committed or pasted somewhere public: revoke it at
<https://huggingface.co/settings/tokens> first, then clean up. A read-scoped
token only grants model downloads, but revoke-then-clean is the correct order.
