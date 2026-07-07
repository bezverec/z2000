param(
    [Alias("Input")]
    [string[]]$InputPath = @("C:\temp\tools\images\0002.tif"),
    [string]$OutDir = "zig-out\interop-erterm",
    [string]$Threads = "all",
    [string]$GrokBin = "C:\temp\tools\grok-windows-latest\grok-windows-latest\bin",
    [string]$OpenJpegBin = "C:\temp\tools\openjpeg-v2.5.4-windows-x64\openjpeg-v2.5.4-windows-x64\bin",
    [ValidateSet("none", "R")]
    [string]$TileParts = "none",
    [string]$KduExpand = "kdu_expand.exe",
    [string]$Python = $env:Z2000_BENCH_PYTHON,
    [switch]$SkipBuild,
    [switch]$SkipKakadu,
    [switch]$SkipZ2000Strict
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
        & $Exe @ArgList
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

function Assert-NoDebugSidecar([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
    $needle = [System.Text.Encoding]::ASCII.GetBytes("ZJ2K-CBLK-BP8")
    for ($i = 0; $i -le $bytes.Length - $needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($bytes[$i + $j] -ne $needle[$j]) {
                $match = $false
                break
            }
        }
        if ($match) {
            throw "debug BP8 sidecar unexpectedly present in $Path"
        }
    }
}

Require-Command "zig"
foreach ($path in $InputPath) {
    Require-File $path
}

$threadsResolved = Resolve-LogicalThreads
$outDirNative = $OutDir
New-Item -ItemType Directory -Force -Path $outDirNative | Out-Null

if (-not $SkipBuild) {
    Invoke-NativeChecked "ReleaseFast native build" "zig" @("build", "-Doptimize=ReleaseFast", "-Dtarget=native")
}

$z2000 = ".\zig-out\bin\z2000.exe"
Require-File $z2000

$grokDecompress = Join-Path $GrokBin "grk_decompress.exe"
$opjDecompress = Join-Path $OpenJpegBin "opj_decompress.exe"
Require-File $grokDecompress
Require-File $opjDecompress

$haveKakadu = -not $SkipKakadu -and (Get-Command $KduExpand -ErrorAction SilentlyContinue)

$pythonExe = Find-Python
if (-not (Test-PixelComparePython $pythonExe)) {
    throw "missing Python with numpy and Pillow; set Z2000_BENCH_PYTHON"
}

$precincts = "[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]"
$results = @()

foreach ($input in $InputPath) {
    $inputFull = (Resolve-Path -LiteralPath $input).Path
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($inputFull)
    $caseDir = Join-Path $outDirNative $stem
    New-Item -ItemType Directory -Force -Path $caseDir | Out-Null

    $jp2 = Join-Path $caseDir "z2000-erterm.jp2"
    $decZ2000 = Join-Path $caseDir "dec-z2000.tif"
    $decOpenJpeg = Join-Path $caseDir "dec-openjpeg.tif"
    $decGrok = Join-Path $caseDir "dec-grok.tif"
    $decKakadu = Join-Path $caseDir "dec-kakadu.tif"

    Invoke-NativeChecked "z2000 ERTERM encode $stem" $z2000 @(
        "tiff-to-jp2", $inputFull, $jp2,
        "--tile", "8192,8192",
        "--progression", "RPCL",
        "--resolutions", "6",
        "--precincts", $precincts,
        "--block", "64",
        "--layers", "1",
        "--tile-parts", $TileParts,
        "--sop",
        "--no-eph",
        "--tlm",
        "--terminate-all",
        "--predictable-termination",
        "--threads", "$threadsResolved"
    )
    Assert-NoDebugSidecar $jp2

    Invoke-NativeChecked "OpenJPEG decode $stem" $opjDecompress @("-i", $jp2, "-o", $decOpenJpeg, "-quiet")
    Invoke-NativeChecked "Grok decode $stem" $grokDecompress @("-i", $jp2, "-o", $decGrok)
    if ($haveKakadu) {
        Invoke-NativeChecked "Kakadu decode $stem" $KduExpand @("-i", $jp2, "-o", $decKakadu, "-quiet")
    }
    if (-not $SkipZ2000Strict) {
        Invoke-NativeChecked "z2000 strict decode $stem" $z2000 @("decode-temp-jp2", $jp2, $decZ2000, "--threads", "$threadsResolved", "--t1-backend", "iso-mq")
    }

    Compare-Pixels $pythonExe $inputFull $decOpenJpeg "OpenJPEG ERTERM $stem"
    Compare-Pixels $pythonExe $inputFull $decGrok "Grok ERTERM $stem"
    if ($haveKakadu) {
        Compare-Pixels $pythonExe $inputFull $decKakadu "Kakadu ERTERM $stem"
    }
    if (-not $SkipZ2000Strict) {
        Compare-Pixels $pythonExe $inputFull $decZ2000 "z2000 strict ERTERM $stem"
    }

    $results += [pscustomobject]@{
        Input = $stem
        Bytes = (Get-Item -LiteralPath $jp2).Length
        Z2000 = if ($SkipZ2000Strict) { "SKIPPED" } else { "LOSSLESS" }
        OpenJPEG = "LOSSLESS"
        Grok = "LOSSLESS"
        Kakadu = if ($haveKakadu) { "LOSSLESS" } else { "SKIPPED" }
    }
}

Write-Host ""
Write-Host "== ERTERM INTEROP SUMMARY =="
$results | Format-Table -AutoSize
