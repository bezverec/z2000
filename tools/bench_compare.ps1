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
    [switch]$IncludeLossy,
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

$cmdZ1 = "$z tiff-to-jp2 $inputTool $outTool/z2000-t1.jp2 --tile 8192,8192 --progression RPCL --resolutions 6 --precincts `"$precincts`" --block 64 --layers 1 --tile-parts R --sop --eph --tlm --bypass --threads 1"
$cmdZN = "$z tiff-to-jp2 $inputTool $outTool/z2000-t$threadsResolved.jp2 --tile 8192,8192 --progression RPCL --resolutions 6 --precincts `"$precincts`" --block 64 --layers 1 --tile-parts R --sop --eph --tlm --bypass --threads $threadsResolved"
$cmdGrk1 = "$(Quote-Arg $grokCompress) -i $inputTool -o $outTool/grok-t1.jp2 -t 8192,8192 -p RPCL -n 6 -c `"$precincts`" -b 64,64 -Y 1 -X -M 1 -S -E -u R -H 1 -G -2"
$cmdGrkN = "$(Quote-Arg $grokCompress) -i $inputTool -o $outTool/grok-t$threadsResolved.jp2 -t 8192,8192 -p RPCL -n 6 -c `"$precincts`" -b 64,64 -Y 1 -X -M 1 -S -E -u R -H $threadsResolved -G -2"
$cmdOpj1 = "$(Quote-Arg $opjCompress) -i $inputTool -o $outTool/openjpeg-t1.jp2 -t 8192,8192 -p RPCL -n 6 -c `"$precincts`" -b 64,64 -mct 1 -TLM -PLT -M 1 -SOP -EPH -TP R -threads 1"
$cmdOpjN = "$(Quote-Arg $opjCompress) -i $inputTool -o $outTool/openjpeg-t$threadsResolved.jp2 -t 8192,8192 -p RPCL -n 6 -c `"$precincts`" -b 64,64 -mct 1 -TLM -PLT -M 1 -SOP -EPH -TP R -threads $threadsResolved"
$cmdKdu1 = "$(Quote-Arg $kduCompressTool) -i $inputTool -o $outTool/kakadu-t1.jp2 Creversible=yes Cycc=yes Clevels=5 Corder=RPCL Cprecincts='$kduPrecincts' Cblk='{64,64}' Stiles='{8192,8192}' Cuse_sop=yes Cuse_eph=yes Cmodes=BYPASS ORGtparts=R ORGgen_plt=yes ORGgen_tlm=6 -num_threads 0 -quiet"
$cmdKduN = "$(Quote-Arg $kduCompressTool) -i $inputTool -o $outTool/kakadu-t$threadsResolved.jp2 Creversible=yes Cycc=yes Clevels=5 Corder=RPCL Cprecincts='$kduPrecincts' Cblk='{64,64}' Stiles='{8192,8192}' Cuse_sop=yes Cuse_eph=yes Cmodes=BYPASS ORGtparts=R ORGgen_plt=yes ORGgen_tlm=6 -num_threads $threadsResolved -quiet"

$encodeArgs = @(
    "--shell=none", "--warmup", "$Warmup", "--runs", "$Runs", "--export-json", "$outTool/encode.json",
    "--command-name", "z2000 t1 encode", $cmdZ1,
    "--command-name", "z2000 t$threadsResolved encode", $cmdZN,
    "--command-name", "Grok t1 encode", $cmdGrk1,
    "--command-name", "Grok t$threadsResolved encode", $cmdGrkN,
    "--command-name", "OpenJPEG t1 encode", $cmdOpj1,
    "--command-name", "OpenJPEG t$threadsResolved encode", $cmdOpjN
)
if ($haveKakadu) {
    $encodeArgs += @(
        "--command-name", "Kakadu t1 encode", $cmdKdu1,
        "--command-name", "Kakadu t$threadsResolved encode", $cmdKduN
    )
}

Write-Host "== ENCODE =="
& hyperfine @encodeArgs

$cmdDz1 = "$z decode-temp-jp2 $outTool/z2000-t$threadsResolved.jp2 $outTool/dec-z2000-t1.tif --threads 1"
$cmdDzN = "$z decode-temp-jp2 $outTool/z2000-t$threadsResolved.jp2 $outTool/dec-z2000-t$threadsResolved.tif --threads $threadsResolved"
$cmdDgrk1 = "$(Quote-Arg $grokDecompress) -i $outTool/grok-t$threadsResolved.jp2 -o $outTool/dec-grok-t1.tif -H 1 -G -2"
$cmdDgrkN = "$(Quote-Arg $grokDecompress) -i $outTool/grok-t$threadsResolved.jp2 -o $outTool/dec-grok-t$threadsResolved.tif -H $threadsResolved -G -2"
$cmdDopj1 = "$(Quote-Arg $opjDecompress) -i $outTool/openjpeg-t$threadsResolved.jp2 -o $outTool/dec-openjpeg-t1.tif -quiet -threads 1"
$cmdDopjN = "$(Quote-Arg $opjDecompress) -i $outTool/openjpeg-t$threadsResolved.jp2 -o $outTool/dec-openjpeg-t$threadsResolved.tif -quiet -threads $threadsResolved"
$cmdDkdu1 = "$(Quote-Arg $kduExpandTool) -i $outTool/kakadu-t$threadsResolved.jp2 -o $outTool/dec-kakadu-t1.tif -num_threads 0 -quiet"
$cmdDkduN = "$(Quote-Arg $kduExpandTool) -i $outTool/kakadu-t$threadsResolved.jp2 -o $outTool/dec-kakadu-t$threadsResolved.tif -num_threads $threadsResolved -quiet"

$decodeArgs = @(
    "--shell=none", "--warmup", "$Warmup", "--runs", "$Runs", "--export-json", "$outTool/decode.json",
    "--command-name", "z2000 t1 decode", $cmdDz1,
    "--command-name", "z2000 t$threadsResolved decode", $cmdDzN,
    "--command-name", "Grok t1 decode", $cmdDgrk1,
    "--command-name", "Grok t$threadsResolved decode", $cmdDgrkN,
    "--command-name", "OpenJPEG t1 decode", $cmdDopj1,
    "--command-name", "OpenJPEG t$threadsResolved decode", $cmdDopjN
)
if ($haveKakadu) {
    $decodeArgs += @(
        "--command-name", "Kakadu t1 decode", $cmdDkdu1,
        "--command-name", "Kakadu t$threadsResolved decode", $cmdDkduN
    )
}

Write-Host ""
Write-Host "== DECODE OWN FILES =="
& hyperfine @decodeArgs

Write-Host ""
Write-Host "== SIZES =="
Get-ChildItem -LiteralPath $outDirNative -Filter "*.jp2" |
    Where-Object { $_.Name -in @("z2000-t1.jp2", "z2000-t$threadsResolved.jp2", "grok-t$threadsResolved.jp2", "openjpeg-t$threadsResolved.jp2", "kakadu-t$threadsResolved.jp2") } |
    Sort-Object Name |
    Select-Object Name, Length |
    Format-Table -AutoSize

$pythonExe = Find-Python
if (Test-PixelComparePython $pythonExe) {
    Write-Host "== LOSSLESS VERIFICATION =="
    Run-PixelCompare $pythonExe $InputPath (Join-Path $outDirNative "dec-z2000-t$threadsResolved.tif") "z2000 self-decode"
    Run-PixelCompare $pythonExe $InputPath (Join-Path $outDirNative "dec-grok-t$threadsResolved.tif") "Grok self-decode"
    Run-PixelCompare $pythonExe $InputPath (Join-Path $outDirNative "dec-openjpeg-t$threadsResolved.tif") "OpenJPEG self-decode"
    if ($haveKakadu) {
        Run-PixelCompare $pythonExe $InputPath (Join-Path $outDirNative "dec-kakadu-t$threadsResolved.tif") "Kakadu self-decode"
    }
} else {
    Write-Host "pixel check skipped: set Z2000_BENCH_PYTHON to a Python with numpy and Pillow"
}

if ($IncludeLossy) {
    Write-Host ""
    Write-Host "== LOSSY 9/7 ENCODE (ICT, scalar quantization, 2 layers, complete final layer) =="
    $lossyCommon = "--tile 8192,8192 --progression RPCL --resolutions 6 --precincts `"$precincts`" --block 64 --rates 8,1 --tile-parts R --sop --eph --tlm --transform 9-7 --mct ict --qstyle scalar-expounded"
    $lossyZ1 = "$z tiff-to-jp2 $inputTool $outTool/lossy-z2000-t1.jp2 $lossyCommon --threads 1"
    $lossyZN = "$z tiff-to-jp2 $inputTool $outTool/lossy-z2000-t$threadsResolved.jp2 $lossyCommon --threads $threadsResolved"
    $lossyGrk1 = "$(Quote-Arg $grokCompress) -i $inputTool -o $outTool/lossy-grok-t1.jp2 -I -r 8,1 -t 8192,8192 -p RPCL -n 6 -c `"$precincts`" -b 64,64 -Y 1 -X -S -E -u R -H 1 -G -2"
    $lossyGrkN = "$(Quote-Arg $grokCompress) -i $inputTool -o $outTool/lossy-grok-t$threadsResolved.jp2 -I -r 8,1 -t 8192,8192 -p RPCL -n 6 -c `"$precincts`" -b 64,64 -Y 1 -X -S -E -u R -H $threadsResolved -G -2"
    $lossyOpj1 = "$(Quote-Arg $opjCompress) -i $inputTool -o $outTool/lossy-openjpeg-t1.jp2 -I -r 8,1 -t 8192,8192 -p RPCL -n 6 -c `"$precincts`" -b 64,64 -mct 1 -TLM -PLT -SOP -EPH -TP R -threads 1"
    $lossyOpjN = "$(Quote-Arg $opjCompress) -i $inputTool -o $outTool/lossy-openjpeg-t$threadsResolved.jp2 -I -r 8,1 -t 8192,8192 -p RPCL -n 6 -c `"$precincts`" -b 64,64 -mct 1 -TLM -PLT -SOP -EPH -TP R -threads $threadsResolved"
    $lossyKdu1 = "$(Quote-Arg $kduCompressTool) -i $inputTool -o $outTool/lossy-kakadu-t1.jp2 Creversible=no Cycc=yes Clevels=5 Clayers=2 Corder=RPCL Cprecincts='$kduPrecincts' Cblk='{64,64}' Stiles='{8192,8192}' Cuse_sop=yes Cuse_eph=yes ORGtparts=R ORGgen_plt=yes ORGgen_tlm=6 -rate -,3 -num_threads 0 -quiet"
    $lossyKduN = "$(Quote-Arg $kduCompressTool) -i $inputTool -o $outTool/lossy-kakadu-t$threadsResolved.jp2 Creversible=no Cycc=yes Clevels=5 Clayers=2 Corder=RPCL Cprecincts='$kduPrecincts' Cblk='{64,64}' Stiles='{8192,8192}' Cuse_sop=yes Cuse_eph=yes ORGtparts=R ORGgen_plt=yes ORGgen_tlm=6 -rate -,3 -num_threads $threadsResolved -quiet"
    $lossyEncodeArgs = @(
        "--shell=none", "--warmup", "$Warmup", "--runs", "$Runs", "--export-json", "$outTool/encode-lossy.json",
        "--command-name", "z2000 t1 lossy encode", $lossyZ1,
        "--command-name", "z2000 t$threadsResolved lossy encode", $lossyZN,
        "--command-name", "Grok t1 lossy encode", $lossyGrk1,
        "--command-name", "Grok t$threadsResolved lossy encode", $lossyGrkN,
        "--command-name", "OpenJPEG t1 lossy encode", $lossyOpj1,
        "--command-name", "OpenJPEG t$threadsResolved lossy encode", $lossyOpjN
    )
    if ($haveKakadu) {
        $lossyEncodeArgs += @(
            "--command-name", "Kakadu t1 lossy encode", $lossyKdu1,
            "--command-name", "Kakadu t$threadsResolved lossy encode", $lossyKduN
        )
    }
    & hyperfine @lossyEncodeArgs

    Write-Host ""
    Write-Host "== LOSSY 9/7 DECODE OWN FILES =="
    $lossyDecodeArgs = @(
        "--shell=none", "--warmup", "$Warmup", "--runs", "$Runs", "--export-json", "$outTool/decode-lossy.json",
        "--command-name", "z2000 t1 lossy decode", "$z decode-temp-jp2 $outTool/lossy-z2000-t$threadsResolved.jp2 $outTool/lossy-dec-z2000-t1.tif --threads 1",
        "--command-name", "z2000 t$threadsResolved lossy decode", "$z decode-temp-jp2 $outTool/lossy-z2000-t$threadsResolved.jp2 $outTool/lossy-dec-z2000-t$threadsResolved.tif --threads $threadsResolved",
        "--command-name", "Grok t1 lossy decode", "$(Quote-Arg $grokDecompress) -i $outTool/lossy-grok-t$threadsResolved.jp2 -o $outTool/lossy-dec-grok-t1.tif -H 1 -G -2",
        "--command-name", "Grok t$threadsResolved lossy decode", "$(Quote-Arg $grokDecompress) -i $outTool/lossy-grok-t$threadsResolved.jp2 -o $outTool/lossy-dec-grok-t$threadsResolved.tif -H $threadsResolved -G -2",
        "--command-name", "OpenJPEG t1 lossy decode", "$(Quote-Arg $opjDecompress) -i $outTool/lossy-openjpeg-t$threadsResolved.jp2 -o $outTool/lossy-dec-openjpeg-t1.tif -quiet -threads 1",
        "--command-name", "OpenJPEG t$threadsResolved lossy decode", "$(Quote-Arg $opjDecompress) -i $outTool/lossy-openjpeg-t$threadsResolved.jp2 -o $outTool/lossy-dec-openjpeg-t$threadsResolved.tif -quiet -threads $threadsResolved"
    )
    if ($haveKakadu) {
        $lossyDecodeArgs += @(
            "--command-name", "Kakadu t1 lossy decode", "$(Quote-Arg $kduExpandTool) -i $outTool/lossy-kakadu-t$threadsResolved.jp2 -o $outTool/lossy-dec-kakadu-t1.tif -num_threads 0 -quiet",
            "--command-name", "Kakadu t$threadsResolved lossy decode", "$(Quote-Arg $kduExpandTool) -i $outTool/lossy-kakadu-t$threadsResolved.jp2 -o $outTool/lossy-dec-kakadu-t$threadsResolved.tif -num_threads $threadsResolved -quiet"
        )
    }
    & hyperfine @lossyDecodeArgs

    Write-Host ""
    Write-Host "== LOSSY SIZES =="
    Get-ChildItem -LiteralPath $outDirNative -Filter "lossy-*.jp2" |
        Where-Object { $_.Name -match "-t$threadsResolved\.jp2$" } |
        Sort-Object Name |
        Select-Object Name, Length |
        Format-Table -AutoSize

    $lossyT1Hash = (Get-FileHash -Algorithm SHA256 (Join-Path $outDirNative "lossy-z2000-t1.jp2")).Hash
    $lossyTNHash = (Get-FileHash -Algorithm SHA256 (Join-Path $outDirNative "lossy-z2000-t$threadsResolved.jp2")).Hash
    if ($lossyT1Hash -ne $lossyTNHash) { throw "lossy z2000 output is not cross-thread deterministic" }
    Write-Host "z2000 lossy t1 == t$threadsResolved codestream: OK"
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
