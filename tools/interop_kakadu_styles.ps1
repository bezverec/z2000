param(
    [Alias("Input")]
    [string]$InputPath = "C:\temp\tools\images\0004.tif",
    [string]$OutDir = "zig-out\interop-kakadu-styles",
    [string]$Threads = "all",
    [string]$KduCompress = "kdu_compress.exe",
    [string]$KduExpand = "kdu_expand.exe",
    [string]$Python = $env:Z2000_BENCH_PYTHON,
    [switch]$SkipBuild
)

$ErrorActionPreference = "Stop"

function Resolve-LogicalThreads {
    if ($Threads -ne "" -and $Threads -ne "all" -and $Threads -ne "auto") {
        return [int]$Threads
    }
    $count = [Environment]::ProcessorCount
    if ($count -gt 0) { return $count }
    return 4
}

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "missing required command: $Name"
    }
}

function Require-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "missing required file: $Path"
    }
}

function Find-Python {
    if ($Python -and (Test-Path -LiteralPath $Python)) { return $Python }
    foreach ($candidate in @("python.exe", "python3.exe", "py.exe")) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Test-PixelComparePython([string]$Exe) {
    if (-not $Exe) { return $false }
    & $Exe -c "import numpy, PIL" *> $null
    return $LASTEXITCODE -eq 0
}

function Invoke-NativeChecked([string]$Label, [string]$Exe, [string[]]$ArgList) {
    Write-Host "== $Label =="
    $nativePref = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    if ($nativePref) {
        $oldNativePref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        & $Exe @ArgList | Out-Host
        $code = $LASTEXITCODE
    } finally {
        if ($nativePref) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePref
        }
    }
    if ($code -ne 0) {
        throw "$Label failed with exit code $code"
    }
}

function Compare-Pixels([string]$PythonExe, [string]$Reference, [string]$Actual, [string]$Label) {
    Invoke-NativeChecked $Label $PythonExe @("tools\compare_tiff.py", $Reference, $Actual, $Label)
}

function Invoke-NativeExpectUnsupported([string]$Label, [string]$Exe, [string[]]$ArgList) {
    Write-Host "== $Label =="
    $nativePref = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    if ($nativePref) {
        $oldNativePref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        $output = & $Exe @ArgList 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        if ($nativePref) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePref
        }
    }
    if ($output.Trim()) { Write-Host $output.Trim() }
    if ($code -eq 0 -or $output -notmatch "Unsupported(Profile|Payload)") {
        throw "$Label did not fail closed with an unsupported-profile error"
    }
}

function Invoke-Z2000ForwardCase(
    [string]$Name,
    [string[]]$StyleArgs,
    [string[]]$GeometryArgs,
    [string]$CaseDir,
    [string]$Source,
    [string]$Z2000,
    [string]$PythonExe,
    [int]$ThreadCount
) {
    $jp2 = Join-Path $CaseDir "z2000-$Name.jp2"
    $decoded = Join-Path $CaseDir "z2000-$Name-kakadu.tif"
    $args = @(
        "tiff-to-jp2", $Source, $jp2,
        "--progression", "RPCL",
        "--block", "64",
        "--layers", "1",
        "--threads", "$ThreadCount"
    ) + $GeometryArgs + $StyleArgs
    Invoke-NativeChecked "z2000 encode $Name" $Z2000 $args
    Invoke-NativeChecked "Kakadu decode $Name" $KduExpand @("-i", $jp2, "-o", $decoded, "-quiet")
    Compare-Pixels $PythonExe $Source $decoded "Kakadu decode of z2000 $Name"
    return [pscustomobject]@{
        Direction = "z2000 -> Kakadu"
        Profile = $Name
        Bytes = (Get-Item -LiteralPath $jp2).Length
        Result = "LOSSLESS"
    }
}

function Invoke-KakaduReverseCase(
    [string]$Name,
    [string]$Mode,
    [string]$CaseDir,
    [string]$Source,
    [string]$Z2000,
    [string]$PythonExe,
    [int]$ThreadCount
) {
    $jp2 = Join-Path $CaseDir "kakadu-$Name.jp2"
    $decoded = Join-Path $CaseDir "kakadu-$Name-z2000.tif"
    $args = @(
        "-i", $Source,
        "-o", $jp2,
        "Creversible=yes",
        "Cycc=yes",
        "Clevels=5",
        "Corder=RPCL",
        "Cprecincts={256,256},{256,256},{128,128},{128,128},{128,128},{128,128}",
        "Cblk={64,64}",
        "Cmodes:C0=$Mode", "Cmodes:C1=$Mode", "Cmodes:C2=$Mode",
        "Qguard:C0=2", "Qguard:C1=2", "Qguard:C2=2",
        "ORGgen_plt=yes",
        "Cuse_sop=no",
        "Cuse_eph=no",
        "-quiet"
    )
    Invoke-NativeChecked "Kakadu encode $Name" $KduCompress $args
    Invoke-NativeChecked "z2000 decode $Name" $Z2000 @(
        "decode-temp-jp2", $jp2, $decoded,
        "--threads", "$ThreadCount",
        "--t1-backend", "iso-mq"
    )
    Compare-Pixels $PythonExe $Source $decoded "z2000 decode of Kakadu $Name"
    return [pscustomobject]@{
        Direction = "Kakadu -> z2000"
        Profile = $Name
        Bytes = (Get-Item -LiteralPath $jp2).Length
        Result = "LOSSLESS"
    }
}

Require-Command "zig"
Require-Command $KduCompress
Require-Command $KduExpand
Require-File $InputPath

$pythonExe = Find-Python
if (-not (Test-PixelComparePython $pythonExe)) {
    throw "missing Python with numpy and Pillow; set Z2000_BENCH_PYTHON"
}

if (-not $SkipBuild) {
    Invoke-NativeChecked "ReleaseFast native build" "zig" @("build", "-Doptimize=ReleaseFast", "-Dtarget=native")
}

$z2000 = ".\zig-out\bin\z2000.exe"
Require-File $z2000
$source = (Resolve-Path -LiteralPath $InputPath).Path
$threadCount = Resolve-LogicalThreads
$caseDir = $OutDir
New-Item -ItemType Directory -Force -Path $caseDir | Out-Null

$singleGeometry = @(
    "--tile", "8192,8192",
    "--levels", "5",
    "--precincts", "[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]"
)
$multiGeometry = @(
    "--tile", "2048,3072",
    "--levels", "2",
    "--precincts", "[128,128],[128,128],[128,128]",
    "--tile-parts", "none"
)

$results = @()
$forwardSingle = @(
    @{ Name = "reset"; Args = @("--reset-context") },
    @{ Name = "termall"; Args = @("--terminate-all") },
    @{ Name = "reset-termall"; Args = @("--reset-context", "--terminate-all") },
    @{ Name = "erterm"; Args = @("--terminate-all", "--predictable-termination") },
    @{ Name = "erterm-standalone"; Args = @("--predictable-termination") },
    @{ Name = "erterm-reset-standalone"; Args = @("--predictable-termination", "--reset-context") },
    @{ Name = "bypass-termall"; Args = @("--bypass", "--terminate-all") },
    @{ Name = "causal-segmark"; Args = @("--vertical-causal", "--segmentation-symbols") }
)
foreach ($case in $forwardSingle) {
    $results += Invoke-Z2000ForwardCase $case.Name $case.Args $singleGeometry $caseDir $source $z2000 $pythonExe $threadCount
}

$forwardMulti = @(
    @{ Name = "multitile-causal-segmark"; Args = @("--vertical-causal", "--segmentation-symbols") },
    @{ Name = "multitile-reset-termall"; Args = @("--reset-context", "--terminate-all") },
    @{ Name = "multitile-erterm"; Args = @("--terminate-all", "--predictable-termination") },
    @{ Name = "multitile-bypass-termall"; Args = @("--bypass", "--terminate-all") }
)
foreach ($case in $forwardMulti) {
    $results += Invoke-Z2000ForwardCase $case.Name $case.Args $multiGeometry $caseDir $source $z2000 $pythonExe $threadCount
}

$reverse = @(
    @{ Name = "reset-qguard2"; Mode = "RESET" },
    @{ Name = "restart"; Mode = "RESTART" },
    @{ Name = "reset-restart"; Mode = "RESET|RESTART" },
    @{ Name = "erterm-restart"; Mode = "ERTERM|RESTART" },
    @{ Name = "erterm-standalone"; Mode = "ERTERM" },
    @{ Name = "erterm-reset"; Mode = "ERTERM|RESET" },
    @{ Name = "erterm-causal-segmark"; Mode = "ERTERM|CAUSAL|SEGMARK" },
    @{ Name = "bypass-restart"; Mode = "BYPASS|RESTART" },
    @{ Name = "causal-segmark"; Mode = "CAUSAL|SEGMARK" }
)
foreach ($case in $reverse) {
    $results += Invoke-KakaduReverseCase $case.Name $case.Mode $caseDir $source $z2000 $pythonExe $threadCount
}

# BYPASS+ERTERM needs predictable raw-segment termination, which z2000 has no
# writer or reader model for yet — the decode must fail closed.
$bypassErterm = Join-Path $caseDir "kakadu-bypass-erterm.jp2"
Invoke-NativeChecked "Kakadu encode BYPASS+ERTERM" $KduCompress @(
    "-i", $source,
    "-o", $bypassErterm,
    "Creversible=yes",
    "Cycc=yes",
    "Clevels=5",
    "Corder=RPCL",
    "Cprecincts={256,256},{256,256},{128,128},{128,128},{128,128},{128,128}",
    "Cblk={64,64}",
    "Cmodes:C0=BYPASS|ERTERM", "Cmodes:C1=BYPASS|ERTERM", "Cmodes:C2=BYPASS|ERTERM",
    "Qguard:C0=2", "Qguard:C1=2", "Qguard:C2=2",
    "ORGgen_plt=yes",
    "-quiet"
)
Invoke-NativeExpectUnsupported "z2000 reject Kakadu BYPASS+ERTERM" $z2000 @(
    "decode-temp-jp2", $bypassErterm, (Join-Path $caseDir "unexpected-bypass-erterm.tif"),
    "--threads", "$threadCount"
)
$results += [pscustomobject]@{
    Direction = "Kakadu -> z2000"
    Profile = "bypass-erterm"
    Bytes = (Get-Item -LiteralPath $bypassErterm).Length
    Result = "FAIL-CLOSED"
}

Write-Host ""
Write-Host "== KAKADU STYLE INTEROP SUMMARY =="
$results | Format-Table -AutoSize
