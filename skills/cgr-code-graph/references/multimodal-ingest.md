# Bringing non-code files into a cgr graph

cgr parses code and markdown. PDF, DOCX, images, audio and video are invisible to it. The way to widen coverage without forking cgr is to **normalise everything to markdown in a shadow tree**, because markdown is already a first-class node type (`document_tier.py`: one `Section` node per heading, nested by heading level, front-matter parsed, relative links tracked).

Never convert in place. The user's originals stay byte-identical; the graph points at `~/.cgr-kit/shadow/<project>/<path>.md`.

## What each file type actually costs

| input | route | cost | notes |
| --- | --- | --- | --- |
| code | tree-sitter | free | already the default |
| `.md` / `.markdown` | `document_tier` | free | already the default; headings become `Section` nodes |
| HTML, EPUB, RTF, ODT | pandoc / markitdown | free, local | pandoc covers all four in one binary |
| text PDF | `pdftotext -layout` or markitdown | free, local | keep `-layout` so tables survive as readable text |
| DOCX | pandoc / markitdown | free, local | images inside are dropped; text is what matters for retrieval |
| scanned PDF, screenshot, photo | vision model, one image at a time | paid, per image | needs OCR *and* interpretation; ~1 request per page |
| video | local Whisper transcript + N sampled frames → vision | transcript free, frames paid | never upload the video itself; 6–12 frames plus the transcript is the whole signal |
| audio | local Whisper | free | transcript only |

Rule of thumb: if the text layer exists, it is free. If the meaning lives in pixels, it costs money per image, so it must be opt-in.

## Shadow-tree layout

```
~/.cgr-kit/shadow/<project>/<relative/path>.md
~/.cgr-kit/manifest.json      # source path → shadow path, source sha256, converter, timestamp
~/.cgr-kit/consent.log        # append-only record of every outbound send
```

The manifest is what makes the shadow tree incremental: re-convert only when the source sha256 changes, and delete shadow files whose source disappeared (otherwise the graph keeps answering from deleted documents).

## Consent gate for anything that leaves the machine

Only the paid rows send data out. Gate them with all of the following, not a subset:

1. **Off by default.** `[network] enabled = false` in the kit's TOML. A key present in the environment must not be enough to activate it — configuration and credential are separate switches.
2. **Dry run that prints the bill before sending.** Count files, bytes, requests and an estimated cost per category, list what will be skipped, and require a typed confirmation phrase:

```
Will send to https://api.example/v1 :
  images    47 files   38.2 MB   ~$0.11  (47 requests)
  scanned   3 files    12.4 MB   ~$0.09
  video     2 files   410.0 MB   6 frames each + local transcript → ~$0.03
  SKIPPED   .env, *.key, *.pem, node_modules, .git, <redacted folders>
Estimated total: ~$0.23
Type CONFIRM to proceed:
```

3. **Redaction before counting**, so the bill reflects what would really be sent: skip `.env*`, `*.pem`, `*.key`, `*.p12`, anything whose content matches a key pattern, and any folder the user listed under `[redact]`. Report the skipped list — a silent skip looks like coverage.
4. **Audit log.** Append one line per request: timestamp, endpoint, source path, sha256, bytes, model. The user must be able to answer "what exactly left my machine last Tuesday" without trusting the tool.
5. **Keys by name, not value.** Store `key_env = "MY_VISION_KEY"` and read the value at run time; never write the secret into a config the repo might publish.

## Sizing before promising

`doctor.sh`-style counting should separate code / markdown / other, because "other" is the number that decides whether multimodal is worth building at all. A corpus with 13k pdf/office/image/video files against 20k code files is a different product decision than one with 40 PDFs.

Watch the estimator: walking an `_archive` or `node_modules` leftover inflates both file count and the hours estimate by an order of magnitude. Exclude the same list the indexer excludes, or the number is worthless.
