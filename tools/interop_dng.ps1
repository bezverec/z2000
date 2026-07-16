param(
    [string]$OutDir = "zig-out\interop-dng",
    [string]$Magick = "magick",
    [string]$OpenJpeg = "opj_decompress.exe",
    [string]$Grok = "grk_decompress.exe",
    [switch]$SkipBuild,
    [switch]$SkipExternalDecoders
)

$ErrorActionPreference = "Stop"

function Invoke-NativeChecked([string]$Label, [string]$Exe, [string[]]$ArgList) {
    Write-Host "== $Label =="
    & $Exe @ArgList | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Label failed with exit code $LASTEXITCODE" }
}

function Assert-AeZero([string]$Reference, [string]$Actual, [string]$Label) {
    $metric = (& $Magick compare -metric AE $Reference $Actual null: 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $metric -notmatch '^0(?:\s|$|\()') {
        throw "$Label pixel mismatch: $metric"
    }
    Write-Host "$Label AE=$metric"
}

function Assert-AeNear([string]$Reference, [string]$Actual, [string]$Label) {
    # OpenJPEG applies the restricted ICC profile while writing TIFF. Its
    # LittleCMS rounding differs from z2000's direct matrix/TRC path by at most
    # two 16-bit sample values on this vector (0.005% is 3.28 values).
    $metric = (& $Magick compare -fuzz 0.005% -metric AE $Reference $Actual null: 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $metric -notmatch '^0(?:\s|$|\()') {
        throw "$Label pixel mismatch beyond tolerance: $metric"
    }
    Write-Host "$Label bounded AE=$metric"
}

function Write-IfdEntry(
    [IO.BinaryWriter]$Writer,
    [UInt16]$Tag,
    [UInt16]$Type,
    [UInt32]$Count,
    [UInt32]$Value
) {
    $Writer.Write($Tag)
    $Writer.Write($Type)
    $Writer.Write($Count)
    $Writer.Write($Value)
}

function New-LinearDng([string]$Path) {
    $entryCount = [UInt16]21
    $dataOffset = [UInt32](8 + 2 + $entryCount * 12 + 4)
    $bitsOffset = $dataOffset
    $modelOffset = [UInt32]($bitsOffset + 6)
    $blackOffset = [UInt32]($modelOffset + 10)
    $whiteOffset = [UInt32]($blackOffset + 24)
    $colorOffset = [UInt32]($whiteOffset + 12)
    $neutralOffset = [UInt32]($colorOffset + 72)
    $forwardOffset = [UInt32]($neutralOffset + 24)
    $rasterOffset = [UInt32]($forwardOffset + 72)

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    try {
        $writer = [IO.BinaryWriter]::new($stream)
        try {
            $writer.Write([byte[]](0x49, 0x49))
            $writer.Write([UInt16]42)
            $writer.Write([UInt32]8)
            $writer.Write($entryCount)
            Write-IfdEntry $writer 256 4 1 2
            Write-IfdEntry $writer 257 4 1 1
            Write-IfdEntry $writer 258 3 3 $bitsOffset
            Write-IfdEntry $writer 259 3 1 1
            Write-IfdEntry $writer 262 3 1 34892
            Write-IfdEntry $writer 273 4 1 $rasterOffset
            Write-IfdEntry $writer 274 3 1 1
            Write-IfdEntry $writer 277 3 1 3
            Write-IfdEntry $writer 278 4 1 1
            Write-IfdEntry $writer 279 4 1 12
            Write-IfdEntry $writer 284 3 1 1
            Write-IfdEntry $writer 339 3 1 1
            Write-IfdEntry $writer 50706 1 4 ([UInt32](1 -bor (4 -shl 8)))
            Write-IfdEntry $writer 50708 2 10 $modelOffset
            Write-IfdEntry $writer 50713 3 2 ([UInt32](1 -bor (1 -shl 16)))
            Write-IfdEntry $writer 50714 5 3 $blackOffset
            Write-IfdEntry $writer 50717 4 3 $whiteOffset
            Write-IfdEntry $writer 50721 10 9 $colorOffset
            Write-IfdEntry $writer 50728 5 3 $neutralOffset
            Write-IfdEntry $writer 50778 3 1 21
            Write-IfdEntry $writer 50964 10 9 $forwardOffset
            $writer.Write([UInt32]0)

            1..3 | ForEach-Object { $writer.Write([UInt16]16) }
            $writer.Write([Text.Encoding]::ASCII.GetBytes("Synthetic`0"))
            1..3 | ForEach-Object {
                $writer.Write([UInt32]0)
                $writer.Write([UInt32]1)
            }
            1..3 | ForEach-Object { $writer.Write([UInt32]1000) }
            foreach ($row in 0..2) {
                foreach ($column in 0..2) {
                    $writer.Write([Int32]$(if ($row -eq $column) { 1 } else { 0 }))
                    $writer.Write([Int32]1)
                }
            }
            1..3 | ForEach-Object {
                $writer.Write([UInt32]1)
                $writer.Write([UInt32]1)
            }
            foreach ($value in @(436035, 385101, 143066, 222443, 716934, 60623, 13901, 97077, 713928)) {
                $writer.Write([Int32]$value)
                $writer.Write([Int32]1000000)
            }
            foreach ($value in @(0, 500, 1000, 250, 750, 1000)) {
                $writer.Write([UInt16]$value)
            }
        } finally {
            $writer.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

if (-not $SkipBuild) {
    Invoke-NativeChecked "ReleaseFast build" "zig" @("build", "-Doptimize=ReleaseFast", "-Dtarget=native")
}

$root = (Resolve-Path -LiteralPath ".").Path
$output = Join-Path $root $OutDir
New-Item -ItemType Directory -Force -Path $output | Out-Null
$z2k = Join-Path $root "zig-out\bin\z2k.exe"
$source = Join-Path $output "linear-rgb16.dng"
$jp2 = Join-Path $output "linear-rgb16.jp2"
$reference = Join-Path $output "linear-rgb16-z2k.tif"
$srgbReference = Join-Path $output "linear-rgb16-z2k-srgb.tif"
New-LinearDng $source
Invoke-NativeChecked "DNG to JP2" $z2k @($source, $jp2, "--levels", "0", "--threads", "1")
Invoke-NativeChecked "z2000 JP2 decode" $z2k @($jp2, $reference, "--threads", "1")
Invoke-NativeChecked "z2000 explicit sRGB decode" $z2k @($jp2, $srgbReference, "--threads", "1", "--convert-to-srgb")

if (-not $SkipExternalDecoders) {
    $openJpegTiff = Join-Path $output "linear-rgb16-openjpeg.tif"
    $grokTiff = Join-Path $output "linear-rgb16-grok.tif"
    Invoke-NativeChecked "OpenJPEG decode" $OpenJpeg @("-i", $jp2, "-o", $openJpegTiff)
    Invoke-NativeChecked "Grok decode" $Grok @("-i", $jp2, "-o", $grokTiff)
    Assert-AeNear $srgbReference $openJpegTiff "OpenJPEG ICC conversion"
    Assert-AeZero $reference $grokTiff "Grok decode"
}

$batch = Join-Path $output "batch"
New-Item -ItemType Directory -Force -Path $batch | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $batch "first.dng") -Force
Copy-Item -LiteralPath $source -Destination (Join-Path $batch "second.DNG") -Force
Push-Location $batch
try {
    Invoke-NativeChecked "DNG batch" $z2k @("*.dng", ".jp2", "--levels", "0", "--threads", "1")
} finally {
    Pop-Location
}
if (-not (Test-Path -LiteralPath (Join-Path $batch "first.jp2")) -or
    -not (Test-Path -LiteralPath (Join-Path $batch "second.jp2"))) {
    throw "DNG batch did not create both expected JP2 files"
}

Write-Host "DNG interop PASS"
