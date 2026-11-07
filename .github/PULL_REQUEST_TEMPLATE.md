## What this changes

<!-- One paragraph. The failure it fixes, or the gap it closes. -->

## Evidence

<!-- How you verified it. Pick what applies and keep the real output. -->

- [ ] `bash tests/smoke.sh` → `N passed, 0 failed`
- [ ] `uvx --from shellcheck-py shellcheck -S warning -x scripts/*.sh tests/*.sh` → clean
- [ ] `bash scripts/doctor.sh` → no new FAIL/WARN
- [ ] Reproduced the failure before the fix, and it no longer occurs

Measured numbers, exact error strings, or a command transcript:

```

```

## Checklist

- [ ] No hardcoded user name or absolute home path in `scripts/` (resolved via `scripts/_common.sh`)
- [ ] Paths handed to a native binary are converted (`cgr_native_path` / `cgr_posix_path`)
- [ ] Any new check fails closed (WARN/SKIP when it cannot run, never PASS)
- [ ] No secret written by shell redirection, echoed to the terminal, or left in a temp file
- [ ] If operating guidance changed in `docs/`, `skills/cgr-code-graph/SKILL.md` mirrors it
- [ ] `CHANGELOG.md` updated under `[Unreleased]`

## Related

<!-- Issues, upstream reports, or the error text this addresses. -->
