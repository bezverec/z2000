[CmdletBinding()]
param(
    [string]$Destination = ".zig-cache/part4/htj2k-codestreams"
)

$ErrorActionPreference = "Stop"
$repository = "https://gitlab.com/wg1/htj2k-codestreams.git"
$commit = "f6b9ede094a0bd6e1e0427e12721e3f3ee1b704b"
$root = Split-Path -Parent $PSScriptRoot
$target = [System.IO.Path]::GetFullPath((Join-Path $root $Destination))
$safeTarget = $target.Replace('\', '/')

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git is required"
}

if (-not (Test-Path $target)) {
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    & git clone --filter=blob:none --no-checkout $repository $target
    if ($LASTEXITCODE -ne 0) { throw "cannot clone the official WG1 corpus" }
} elseif (-not (Test-Path (Join-Path $target ".git"))) {
    throw "destination exists but is not a Git checkout: $target"
}

& git -c "safe.directory=$safeTarget" -C $target fetch --depth 1 origin $commit
if ($LASTEXITCODE -ne 0) { throw "cannot fetch pinned corpus commit $commit" }
& git -c "safe.directory=$safeTarget" -C $target checkout --detach $commit
if ($LASTEXITCODE -ne 0) { throw "cannot check out pinned corpus commit $commit" }
$actual = (& git -c "safe.directory=$safeTarget" -C $target rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $actual -ne $commit) {
    throw "corpus revision mismatch: expected $commit, got $actual"
}

Write-Host "Pinned T.803 corpus ready at $target"
Write-Host "For this PowerShell session run:"
Write-Host ('$env:Z2000_PART4_ROOT = "{0}"' -f $target)
Write-Host "zig build part1-corpus -- --require-optional"
