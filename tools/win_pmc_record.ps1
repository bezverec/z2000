# Records hardware counters for z2000 and Kakadu decodes of one stream under
# several processor masks, for comparing them per core type. Needs an
# elevated PowerShell (the NT Kernel Logger). The counters are read at every
# context switch, so each thread's share is exact rather than sampled; the
# .etl files go to -OutDir and tools/win_pmc_summary.py reads them without
# elevation.
#
#   zig build-exe tools/win_affinity_run.zig -O ReleaseFast
#   powershell -ExecutionPolicy Bypass -File tools/win_pmc_record.ps1 -Stream in.jp2 -OutDir C:\temp\pmc
#
# With Hyper-V running (WSL2 needs it) the fixed counters are refused with
# error 0x54F; the general-purpose ones work, hence the fallback list.
param(
    [Parameter(Mandatory = $true)][string]$Stream,
    [Parameter(Mandatory = $true)][string]$OutDir,
    [string]$Z2000 = (Join-Path $PSScriptRoot '..\zig-out\bin\z2000.exe'),
    [string]$Kakadu = 'C:\Program Files\Kakadu\Kakadu Demo-Apps\kdu_expand.exe',
    [string]$Launcher = (Join-Path (Get-Location) 'win_affinity_run.exe'),
    [string]$Xperf = 'C:\Program Files (x86)\Windows Kits\10\Windows Performance Toolkit\xperf.exe',
    [int]$Runs = 3
)
# xperf -stop prints an error when no logger runs; check exit codes instead.
$ErrorActionPreference = 'Continue'

# Name, mask, threads; the masks are for an i5-14500 (0-11 P-core
# hyper-thread pairs, 12-19 E-cores).
$cases = @(
    @('P1', '1', 1),
    @('E1', '10000', 1),
    @('P6', '555', 6),
    @('P12HT', 'FFF', 12),
    @('E8', 'FF000', 8)
)
# The summary expects instructions, cycles, mispredictions, LLC misses in
# this order.
$candidates = @(
    'InstructionsRetiredFixed,UnhaltedCoreCyclesFixed,BranchMispredictsRetired,LLCMisses',
    'InstructionRetired,UnhaltedCoreCycles,BranchMispredictions,LLCMisses'
)

New-Item -ItemType Directory -Force $OutDir | Out-Null
cmd /c "`"$Xperf`" -stop >nul 2>&1"
$probe = Join-Path $OutDir 'probe.etl'
$counters = $null
foreach ($set in $candidates) {
    $message = & $Xperf -on PROC_THREAD+LOADER+CSWITCH -Pmc $set CSWITCH strict -f $probe 2>&1
    $code = $LASTEXITCODE
    cmd /c "`"$Xperf`" -stop >nul 2>&1"
    if ($code -eq 0) { $counters = $set; break }
    Write-Host ("counters {0} refused: {1}" -f $set, ($message -join ' '))
}
Remove-Item -ErrorAction SilentlyContinue $probe
if (-not $counters) { throw 'no counter set accepted' }
Write-Host "counters: $counters"

foreach ($case in $cases) {
    $name, $mask, $threads = $case
    foreach ($decoder in @('z2000', 'kakadu')) {
        $etl = Join-Path $OutDir "$decoder-$name.etl"
        $out = Join-Path $OutDir "$decoder-$name.tif"
        Write-Host "== $decoder $name (mask $mask, $threads threads)"
        & $Xperf -on PROC_THREAD+LOADER+CSWITCH -Pmc $counters CSWITCH strict -f $etl
        if ($LASTEXITCODE -ne 0) { throw "xperf -on failed ($LASTEXITCODE)" }
        try {
            for ($i = 0; $i -lt $Runs; $i++) {
                if ($decoder -eq 'z2000') {
                    & $Launcher $mask $Z2000 decode-temp-jp2 $Stream $out --threads $threads | Out-Null
                } else {
                    & $Launcher $mask $Kakadu -i $Stream -o $out -num_threads $threads -quiet
                }
                if ($LASTEXITCODE -ne 0) { throw "$decoder failed ($LASTEXITCODE)" }
            }
        } finally {
            & $Xperf -stop 2>&1 | Out-Null
        }
    }
}
Write-Host 'done'
