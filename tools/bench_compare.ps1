param(
    [Alias("Input")]
    [string]$InputPath = "C:\temp\tools\images\0004.tif",
    [string]$OutDir = "zig-out\bench-compare-windows",
    [int]$Runs = 5,
    [int]$Warmup = 1,
    [string]$Threads = "all",
    [string]$GrokBin = "C:\temp\tools\grok-windows-latest\grok-windows-latest\bin",
    [string]$OpenJpegBin = "C:\temp\tools\openjpeg-v2.5.4-windows-x64\openjpeg-v2.5.4-windows-x64\bin",
    [string]$KduCompress = "kdu_compress.exe",
    [string]$KduExpand = "kdu_expand.exe",
    [string]$Python = $env:Z2000_BENCH_PYTHON,
    [switch]$SkipBuild,
    [switch]$SkipCrossDecode
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

function Convert-ToToolPath([string]$Path) {
    return $Path.Replace("\", "/")
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

function Quote-Arg([string]$Value) {
    if ($Value -match "\s") { return '"' + $Value + '"' }
    return $Value
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

function Run-PixelCompare([string]$PythonExe, [string]$Reference, [string]$Actual, [string]$Label) {
    if (-not $PythonExe) { return }
    $nativePref = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    if ($nativePref) {
        $oldNativePref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    try {
        & $PythonExe tools\compare_tiff.py $Reference $Actual $Label
        $code = $LASTEXITCODE
    } finally {
        if ($nativePref) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePref
        }
    }
    if ($code -ne 0) {
        Write-Warning "$Label compare exited with code $code"
    }
}

Require-Command "zig"
Require-Command "hyperfine"
Require-File $InputPath

$threadsResolved = Resolve-LogicalThreads
$outDirNative = $OutDir
New-Item -ItemType Directory -Force -Path $outDirNative | Out-Null

if (-not $SkipBuild) {
    & zig build -Doptimize=ReleaseFast -Dtarget=native
}

$z = Convert-ToToolPath ".\zig-out\bin\z2000.exe"
$inputTool = Convert-ToToolPath (Resolve-Path -LiteralPath $InputPath).Path
$outTool = Convert-ToToolPath (Resolve-Path -LiteralPath $outDirNative).Path
$grokCompress = Convert-ToToolPath (Join-Path $GrokBin "grk_compress.exe")
$grokDecompress = Convert-ToToolPath (Join-Path $GrokBin "grk_decompress.exe")
$opjCompress = Convert-ToToolPath (Join-Path $OpenJpegBin "opj_compress.exe")
$opjDecompress = Convert-ToToolPath (Join-Path $OpenJpegBin "opj_decompress.exe")
$kduCompressTool = Convert-ToToolPath $KduCompress
$kduExpandTool = Convert-ToToolPath $KduExpand

foreach ($tool in @($grokCompress, $grokDecompress, $opjCompress, $opjDecompress)) {
    Require-File $tool
}

$haveKakadu = (Get-Command $KduCompress -ErrorAction SilentlyContinue) -and (Get-Command $KduExpand -ErrorAction SilentlyContinue)

$precincts = "[256,256],[256,256],[128,128],[128,128],[128,128],[128,128]"
$kduPrecincts = "{256,256},{256,256},{128,128},{128,128},{128,128},{128,128}"

Write-Host "== z2000 comparative benchmark =="
Write-Host "input:   $InputPath"
Write-Host "outdir:  $outDirNative"
Write-Host "threads: $threadsResolved"
Write-Host "runs:    $Runs (warmup $Warmup)"
Write-Host ""

$cmdZ1 = "$z tiff-to-jp2 $inputTool $outTool/z2000-t1.jp2 --tile 8192,8192 --progression RPCL --resolutions 6 --precincts `"$precincts`" --block 64 --layers 1 --tlm --threads 1"
$cmdZN = "$z tiff-to-jp2 $inputTool $outTool/z2000-t$threadsResolved.jp2 --tile 8192,8192 --progression RPCL --resolutions 6 --precincts `"$precincts`" --block 64 --layers 1 --tlm --threads $threadsResolved"
$cmdGrk = "$(Quote-Arg $grokCompress) -i $inputTool -o $outTool/grok.jp2 -t 8192,8192 -p RPCL -n 6 -c `"$precincts`" -b 64,64 -Y 1 -L"
$cmdOpj = "$(Quote-Arg $opjCompress) -i $inputTool -o $outTool/openjpeg.jp2 -t 8192,8192 -p RPCL -n 6 -c `"$precincts`" -b 64,64 -mct 1 -TLM -PLT"
$cmdKdu = "$(Quote-Arg $kduCompressTool) -i $inputTool -o $outTool/kakadu.jp2 Creversible=yes Cycc=yes Clevels=5 Corder=RPCL Cprecincts='$kduPrecincts' Cblk='{64,64}' Stiles='{8192,8192}' Cuse_sop=no Cuse_eph=no -quiet"

$encodeArgs = @(
    "--shell=none", "--warmup", "$Warmup", "--runs", "$Runs", "--export-json", "$outTool/encode.json",
    "--command-name", "z2000 t1 encode", $cmdZ1,
    "--command-name", "z2000 t$threadsResolved encode", $cmdZN,
    "--command-name", "Grok encode", $cmdGrk,
    "--command-name", "OpenJPEG encode", $cmdOpj
)
if ($haveKakadu) {
    $encodeArgs += @("--command-name", "Kakadu encode", $cmdKdu)
}

Write-Host "== ENCODE =="
& hyperfine @encodeArgs

$cmdDz1 = "$z decode-temp-jp2 $outTool/z2000-t$threadsResolved.jp2 $outTool/dec-z2000-t1.tif --threads 1"
$cmdDzN = "$z decode-temp-jp2 $outTool/z2000-t$threadsResolved.jp2 $outTool/dec-z2000-t$threadsResolved.tif --threads $threadsResolved"
$cmdDgrk = "$(Quote-Arg $grokDecompress) -i $outTool/grok.jp2 -o $outTool/dec-grok.tif"
$cmdDopj = "$(Quote-Arg $opjDecompress) -i $outTool/openjpeg.jp2 -o $outTool/dec-openjpeg.tif -quiet"
$cmdDkdu = "$(Quote-Arg $kduExpandTool) -i $outTool/kakadu.jp2 -o $outTool/dec-kakadu.tif -quiet"

$decodeArgs = @(
    "--shell=none", "--warmup", "$Warmup", "--runs", "$Runs", "--export-json", "$outTool/decode.json",
    "--command-name", "z2000 t1 decode", $cmdDz1,
    "--command-name", "z2000 t$threadsResolved decode", $cmdDzN,
    "--command-name", "Grok decode", $cmdDgrk,
    "--command-name", "OpenJPEG decode", $cmdDopj
)
if ($haveKakadu) {
    $decodeArgs += @("--command-name", "Kakadu decode", $cmdDkdu)
}

Write-Host ""
Write-Host "== DECODE OWN FILES =="
& hyperfine @decodeArgs

Write-Host ""
Write-Host "== SIZES =="
Get-ChildItem -LiteralPath $outDirNative -Filter "*.jp2" |
    Where-Object { $_.Name -in @("z2000-t1.jp2", "z2000-t$threadsResolved.jp2", "grok.jp2", "openjpeg.jp2", "kakadu.jp2") } |
    Sort-Object Name |
    Select-Object Name, Length |
    Format-Table -AutoSize

$pythonExe = Find-Python
if (Test-PixelComparePython $pythonExe) {
    Write-Host "== LOSSLESS VERIFICATION =="
    Run-PixelCompare $pythonExe $InputPath (Join-Path $outDirNative "dec-z2000-t$threadsResolved.tif") "z2000 self-decode"
    Run-PixelCompare $pythonExe $InputPath (Join-Path $outDirNative "dec-grok.tif") "Grok self-decode"
    Run-PixelCompare $pythonExe $InputPath (Join-Path $outDirNative "dec-openjpeg.tif") "OpenJPEG self-decode"
    if ($haveKakadu) {
        Run-PixelCompare $pythonExe $InputPath (Join-Path $outDirNative "dec-kakadu.tif") "Kakadu self-decode"
    }
} else {
    Write-Host "pixel check skipped: set Z2000_BENCH_PYTHON to a Python with numpy and Pillow"
}

if (-not $SkipCrossDecode) {
    Write-Host ""
    Write-Host "== CROSS-DECODE z2000 OUTPUT =="
    $grokDecompressNative = $grokDecompress.Replace("/", "\")
    $opjDecompressNative = $opjDecompress.Replace("/", "\")
    & $grokDecompressNative -i (Join-Path $outDirNative "z2000-t$threadsResolved.jp2") -o (Join-Path $outDirNative "cross-z2000-grok.tif")
    & $opjDecompressNative -i (Join-Path $outDirNative "z2000-t$threadsResolved.jp2") -o (Join-Path $outDirNative "cross-z2000-openjpeg.tif") -quiet
    if ($haveKakadu) {
        & $KduExpand -i (Join-Path $outDirNative "z2000-t$threadsResolved.jp2") -o (Join-Path $outDirNative "cross-z2000-kakadu.tif") -quiet
    }
    if (Test-PixelComparePython $pythonExe) {
        Run-PixelCompare $pythonExe $InputPath (Join-Path $outDirNative "cross-z2000-grok.tif") "Grok decode of z2000"
        Run-PixelCompare $pythonExe $InputPath (Join-Path $outDirNative "cross-z2000-openjpeg.tif") "OpenJPEG decode of z2000"
        if ($haveKakadu) {
            Run-PixelCompare $pythonExe $InputPath (Join-Path $outDirNative "cross-z2000-kakadu.tif") "Kakadu decode of z2000"
        }
    }
}
