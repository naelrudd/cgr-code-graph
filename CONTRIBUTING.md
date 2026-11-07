# Contributing

Thanks for taking the time. This kit has one job: make `cgr` survive contact with
a real machine, and write down what that cost. Contributions that fit that shape
are welcome.

## Before you open a PR

```bash
bash tests/smoke.sh          # unit tests, no network, no cgr needed
uvx --from shellcheck-py shellcheck -S warning -x scripts/*.sh tests/*.sh
bash scripts/doctor.sh       # the preflight the docs tell users to run
```

CI runs the same three (shellcheck on Linux, tests on Linux and Windows, plus a
PowerShell parse and a markdown-link check). All four must be green.

## What makes a good contribution here

**A pitfall with the exact error string.** The value of this repo is the failure
list, not the happy path. If something cost you an hour, the fix is worth more
than a feature:

- the exact error text, verbatim, so it is searchable
- the platform and version it happened on
- why it happens (one or two lines of mechanism, ideally with the upstream file
  or function named)
- the smallest fix or workaround

Add it to the matching doc under [`docs/`](docs/) and, if it changes what a user
should do, to the README's troubleshooting entry points.

**A measured number.** Claims in this repo are measurements, not adjectives:
`449 s for 2,321 nodes`, `~1.1 embeddings/s on CPU`, `13 MB SQLite`. If you
re-measure on different hardware, say what the hardware was and keep the old
number visible rather than replacing it silently.

**A script fix that stays portable.** Non-negotiable rules:

- no hardcoded user name or absolute home path in `scripts/` — resolve at run
  time through `scripts/_common.sh` (`cgr_home`, `cgr_uv`, `cgr_tool_python`,
  `cgr_native_path`, `cgr_posix_path`)
- convert paths before handing them to a native binary (`cgr.exe`, `python.exe`)
- a check that cannot run reports WARN or SKIP, never PASS
- secrets go through a file created with `mktemp` at mode 600, or on stdin —
  never a `>` redirect to a Windows path, and never echoed back
- quote every glob; keep `--exclude` patterns inside a script file

`tests/smoke.sh` enforces the path, artifact and line-ending rules. If you add a
helper to `_common.sh`, add its assertion there too.

## Style

- Shell: `set -euo pipefail` (or `set -uo pipefail` when you deliberately handle
  exit codes), POSIX-friendly, no bash 4-only features where avoidable, `local`
  in functions.
- Comments explain *why*, especially for a workaround — what breaks without it.
  The code says what it does.
- Docs: second person, present tense, no marketing. Show the command, then the
  reason.
- One logical change per commit; the subject line names the area
  (`doctor:`, `install:`, `docs:`, `skill:`).

## Keeping the skill in sync

[`skills/cgr-code-graph/SKILL.md`](skills/cgr-code-graph/SKILL.md) is the same
knowledge packaged for an agent, and the README promises parity. If you change
operating guidance in `docs/`, mirror the durable part there in the same PR.

## Reporting a bug

Use the issue template — it asks for the two things that make these reports
actionable: the output of `bash scripts/doctor.sh` and the exact error text. For
a suspected security problem, follow [`SECURITY.md`](SECURITY.md) instead.

## Code of conduct

Participation is covered by [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). Reports go
to the maintainer privately, not into a thread.
