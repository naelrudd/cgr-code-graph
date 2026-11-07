# The Hugging Face token: what it is, where it lives, why the paste looks broken

## What it is, and what it is not

The embedding model (UniXcoder, 483 MB) is downloaded once from `huggingface.co`
and then cached locally. A token is an **optional** credential that identifies
you to the Hub during that download.

- **Without a token:** the download is anonymous. It works. You get
  `Warning: You are sending unauthenticated requests to the HF Hub. Please set a
  HF_TOKEN to enable higher rate limits and faster downloads.` and a slower,
  rate-limited transfer.
- **With a token:** no warning, higher limits, resumable downloads.
- **What leaves your machine either way:** a request containing a model id. Your
  source code is never uploaded. There is no telemetry, no indexing service, no
  "share your repo" step.

So this is a convenience setting, not a requirement. If you would rather not have
an account, skip it — indexing still works, entirely offline after the first
download.

## Where the token is stored

The path is **not fixed**. It depends on the operating system, the user account,
and any cache-redirecting environment variables. Never hardcode it — ask the
library:

```bash
bash scripts/hf-login.sh --where        # how the script resolved everything
bash scripts/hf-login.sh --status       # which file is in use, and whose account
```

Defaults, when no environment variable overrides them:

| OS | Default token path |
| --- | --- |
| Linux | `~/.cache/huggingface/token` |
| macOS | `~/.cache/huggingface/token` |
| Windows | `%USERPROFILE%\.cache\huggingface\token` |
| anywhere, `XDG_CACHE_HOME` set | `$XDG_CACHE_HOME/huggingface/token` |

Resolution order, highest priority first:

1. `HF_TOKEN_PATH` — an explicit path to the token file
2. `HF_HOME` — a directory; the token becomes `$HF_HOME/token`
3. `XDG_CACHE_HOME` — a directory; the token becomes `$XDG_CACHE_HOME/huggingface/token`
4. the OS default above

Environment variables can also supply the token **instead of** the file, which is
what CI systems do:

```bash
export HF_TOKEN=hf_xxx              # also accepted: HUGGING_FACE_HUB_TOKEN
```

The environment wins over the file, so a stale token in `~/.bashrc` will shadow a
new one you just saved. If `--status` reports an account you do not expect, that
is the first thing to check.

### Printing the path on your machine

```bash
python -c "from huggingface_hub.constants import HF_TOKEN_PATH; print(HF_TOKEN_PATH)"
```

Use the **same python** that cgr runs with, or you are reading a different
install's config. `bash scripts/hf-login.sh --where` prints it for you.

## Why nothing appears when you paste

```
token:                  <- cursor sits here
                        <- you paste hf_abc123... and nothing shows up
```

**This is correct behaviour, not a broken terminal.** `stty -echo` (and
`getpass.getpass` in Python) disables echoing for that one line so the secret
never lands in:

- your terminal scrollback, which outlives the session
- a screenshot or a screen recording
- a shell-session log (`script`, tmux logging, some IDE terminals)
- the paste buffer history of tools that record what was sent

No dots, no asterisks, no length indicator — those would leak the token's length
and, with a partial display, its prefix. The input is still being read: paste,
press Enter, and the script tells you immediately whether the Hub accepted it.

If you pasted the wrong thing, the script says so and stores nothing:
`huggingface_hub.login()` validates against the Hub **before** writing the file.
Nothing is left half-written.

Practical notes:

- Right-click pastes in Windows Terminal and PowerShell; `Ctrl+Shift+V` in most
  Linux terminals; `Cmd+V` on macOS.
- If you paste a token with a trailing newline or spaces, they are stripped.
- If your terminal ever hangs after pasting, press Enter — a bracketed-paste
  sequence may be waiting.

## Verifying, then forgetting about it

```bash
bash scripts/hf-login.sh --status
# token: present (C:\Users\you\.cache\huggingface\token)
# account: yourname  type: user
```

Expected result after a successful login:

```
saved to <path>
verified: yourname (user)
model cache: <hub dir> (15 cached files)
```

## Revoking

Delete the local file, then delete the token on the website (deleting the file
alone leaves the token valid server-side):

```bash
bash scripts/hf-login.sh --logout          # removes the local file
```

then https://huggingface.co/settings/tokens -> the token -> **Delete**.

If you exported `HF_TOKEN` in a shell profile, remove that line too — `--logout`
cannot touch your environment.

## Never do this

```bash
# WRONG on Windows: creates a file NAMED "C:Usersyou.cachehuggingfacetoken"
# in the current directory - a plaintext token inside your repo
echo "$TOKEN" > "C:\Users\me\.cache\huggingface\token"
```

`scripts/hf-login.sh` writes the file through Python precisely to avoid this, and
`scripts/doctor.sh` flags any such file in the working directory. See
[windows-gotchas.md](windows-gotchas.md) §11.
