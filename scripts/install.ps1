# PowerShell equivalent of scripts/install.sh
#   pwsh -File scripts/install.ps1
$ErrorActionPreference = 'Stop'

$tool = 'code-graph-rag'

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    Write-Error "uv is required (https://docs.astral.sh/uv/). Install it, then re-run."
    exit 1
}

Write-Host "==> installing $tool"
# ast-grep extra is what lets the bash/shell/nix tier parse; without it those files
# land in the graph as bare File nodes.
try { uv tool install "$tool[treesitter-full,sqlite-vec,ast-grep]" }
catch { uv tool upgrade $tool }

$toolRoot = uv tool dir
$toolPy = Join-Path $toolRoot "$tool\Scripts\python.exe"
if (-not (Test-Path $toolPy)) {
    $toolPy = Join-Path $toolRoot "$tool/bin/python"
}
if (-not (Test-Path $toolPy)) { Write-Error "could not locate the tool venv python under $toolRoot"; exit 1 }
Write-Host "==> tool python: $toolPy"

# The wheel imports httpx without depending on it; every command fails until it exists.
& $toolPy -c "import httpx" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "==> injecting httpx (missing from the wheel)"
    uv pip install --python $toolPy httpx
}

# Local embeddings: no API key, no quota, offline.
& $toolPy -c "import torch, transformers" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "==> installing torch + transformers for local UniXcoder embeddings (~1 GB, one time)"
    uv pip install --python $toolPy "torch>=2.6.0" "transformers>=5.0.0"
}

$binDir = try { uv tool dir --bin } catch { Join-Path $HOME ".local\bin" }
Write-Host ""
Write-Host "==> done"
Write-Host "    binary: $(Join-Path $binDir 'cgr.exe')"
if ($env:PATH -notlike "*$binDir*") { Write-Host "    NOTE: $binDir is not on PATH. Add it, or call cgr.exe by absolute path." }
Write-Host "    verify: cgr --version ; cgr doctor"
