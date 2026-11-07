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
# $ErrorActionPreference='Stop' governs cmdlets, not native executables: a nonzero
# exit from uv is not a terminating error, so try/catch never fires. Check
# $LASTEXITCODE explicitly, otherwise a failed install silently proceeds against
# an older venv and still reports success.
uv tool install "$tool[treesitter-full,sqlite-vec,ast-grep]"
if ($LASTEXITCODE -ne 0) {
    Write-Host "==> install failed (exit $LASTEXITCODE); trying upgrade of the existing tool venv"
    uv tool upgrade $tool
    if ($LASTEXITCODE -ne 0) { Write-Error "uv tool install/upgrade failed (exit $LASTEXITCODE)"; exit 1 }
}

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

$binDir = $null
$binDir = uv tool dir --bin
if ($LASTEXITCODE -ne 0 -or -not $binDir) { $binDir = Join-Path $HOME ".local\bin" }
Write-Host ""
Write-Host "==> done"
Write-Host "    binary: $(Join-Path $binDir 'cgr.exe')"
$onPath = @($env:PATH -split ';' | Where-Object { $_ -and ($_.TrimEnd('\') -ieq "$binDir".TrimEnd('\')) })
if ($onPath.Count -eq 0) { Write-Host "    NOTE: $binDir is not on PATH. Add it, or call cgr.exe by absolute path." }
Write-Host "    verify: cgr --version ; cgr doctor"
