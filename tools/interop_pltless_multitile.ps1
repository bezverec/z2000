param(
    [string]$OutDir = "zig-out\interop-pltless-multitile",
    [string]$OpenJpegBin = "C:\temp\tools\openjpeg-v2.5.4-windows-x64\openjpeg-v2.5.4-windows-x64\bin",
    [string]$GrokBin = "C:\temp\tools\grok-windows-latest\grok-windows-latest\bin",
    [string]$KduCompress = "kdu_compress.exe",
    [string]$KduExpand = "kdu_expand.exe",
    [switch]$SkipBuild,
    [switch]$SkipKakadu
)

$ErrorActionPreference = "Stop"

function Require-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "missing required file: $Path"
    }
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

function New-RgbTiffFixture([string]$Path, [int]$Width, [int]$Height) {
    $entryCount = 10
    $bitsOffset = 8 + 2 + $entryCount * 12 + 4
    $rasterOffset = $bitsOffset + 6
    $rasterBytes = $Width * $Height * 3
    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($stream)

    function Write-U16Le([int]$Value) {
        $writer.Write([byte]($Value -band 0xff))
        $writer.Write([byte](($Value -shr 8) -band 0xff))
    }

    function Write-U32Le([int64]$Value) {
        $writer.Write([byte]($Value -band 0xff))
        $writer.Write([byte](($Value -shr 8) -band 0xff))
        $writer.Write([byte](($Value -shr 16) -band 0xff))
        $writer.Write([byte](($Value -shr 24) -band 0xff))
    }

    function Write-IfdEntry([int]$Tag, [int]$Type, [int]$Count, [int64]$Value) {
        Write-U16Le $Tag
        Write-U16Le $Type
        Write-U32Le $Count
        Write-U32Le $Value
    }

    $writer.Write([byte[]](0x49, 0x49))
    Write-U16Le 42
    Write-U32Le 8
    Write-U16Le $entryCount
    Write-IfdEntry 256 4 1 $Width
    Write-IfdEntry 257 4 1 $Height
    Write-IfdEntry 258 3 3 $bitsOffset
    Write-IfdEntry 259 3 1 1
    Write-IfdEntry 262 3 1 2
    Write-IfdEntry 273 4 1 $rasterOffset
    Write-IfdEntry 277 3 1 3
    Write-IfdEntry 278 4 1 $Height
    Write-IfdEntry 279 4 1 $rasterBytes
    Write-IfdEntry 284 3 1 1
    Write-U32Le 0
    Write-U16Le 8
    Write-U16Le 8
    Write-U16Le 8

    for ($y = 0; $y -lt $Height; $y++) {
        for ($x = 0; $x -lt $Width; $x++) {
            $red = [int](($x * 255) / [Math]::Max($Width - 1, 1))
            $green = [int](($y * 255) / [Math]::Max($Height - 1, 1))
            $writer.Write([byte]$red)
            $writer.Write([byte]($green -bxor (($x * 17 + $y * 31) -band 0x3f)))
            $writer.Write([byte](255 - $red))
        }
    }

    [System.IO.File]::WriteAllBytes((Resolve-Path -LiteralPath (Split-Path $Path)).Path + "\" + (Split-Path $Path -Leaf), $stream.ToArray())
}

function Read-U16Le([byte[]]$Bytes, [int]$Offset) {
    return [int]$Bytes[$Offset] -bor ([int]$Bytes[$Offset + 1] -shl 8)
}

function Read-U32Le([byte[]]$Bytes, [int]$Offset) {
    return [uint32]([int]$Bytes[$Offset] -bor ([int]$Bytes[$Offset + 1] -shl 8) -bor ([int]$Bytes[$Offset + 2] -shl 16) -bor ([int]$Bytes[$Offset + 3] -shl 24))
}

function Read-U16Tiff([byte[]]$Bytes, [int]$Offset, [bool]$Little) {
    if ($Little) { return Read-U16Le $Bytes $Offset }
    return ([int]$Bytes[$Offset] -shl 8) -bor [int]$Bytes[$Offset + 1]
}

function Read-U32Tiff([byte[]]$Bytes, [int]$Offset, [bool]$Little) {
    if ($Little) { return Read-U32Le $Bytes $Offset }
    return [uint32](([int]$Bytes[$Offset] -shl 24) -bor ([int]$Bytes[$Offset + 1] -shl 16) -bor ([int]$Bytes[$Offset + 2] -shl 8) -bor [int]$Bytes[$Offset + 3])
}

function Get-TiffRaster([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
    $little = $false
    if ($bytes[0] -eq 0x49 -and $bytes[1] -eq 0x49) {
        $little = $true
    } elseif ($bytes[0] -eq 0x4d -and $bytes[1] -eq 0x4d) {
        $little = $false
    } else {
        throw "not a TIFF file: $Path"
    }
    $ifd = [int](Read-U32Tiff $bytes 4 $little)
    $entries = Read-U16Tiff $bytes $ifd $little
    $offsets = @()
    $counts = @()
    function Read-TiffValueArray([byte[]]$Data, [int]$Entry, [bool]$LittleEndian) {
        $type = Read-U16Tiff $Data ($Entry + 2) $LittleEndian
        $count = [int](Read-U32Tiff $Data ($Entry + 4) $LittleEndian)
        $valueOrOffset = [int](Read-U32Tiff $Data ($Entry + 8) $LittleEndian)
        $typeBytes = if ($type -eq 3) { 2 } elseif ($type -eq 4) { 4 } else { throw "unsupported TIFF array type $type in $Path" }
        $start = if ($count * $typeBytes -le 4) { $Entry + 8 } else { $valueOrOffset }
        $values = @()
        for ($i = 0; $i -lt $count; $i++) {
            if ($type -eq 3) {
                $values += [int](Read-U16Tiff $Data ($start + $i * 2) $LittleEndian)
            } else {
                $values += [int](Read-U32Tiff $Data ($start + $i * 4) $LittleEndian)
            }
        }
        return $values
    }
    for ($index = 0; $index -lt $entries; $index++) {
        $entry = $ifd + 2 + $index * 12
        $tag = Read-U16Tiff $bytes $entry $little
        if ($tag -eq 273) { $offsets = Read-TiffValueArray $bytes $entry $little }
        if ($tag -eq 279) { $counts = Read-TiffValueArray $bytes $entry $little }
    }
    if ($offsets.Count -eq 0 -or $counts.Count -eq 0 -or $offsets.Count -ne $counts.Count) {
        throw "missing strip tags in $Path"
    }
    $stream = [System.IO.MemoryStream]::new()
    for ($i = 0; $i -lt $offsets.Count; $i++) {
        if ($offsets[$i] -lt 0 -or $counts[$i] -lt 0 -or $offsets[$i] + $counts[$i] -gt $bytes.Length) {
            throw "invalid strip span in $Path"
        }
        $stream.Write($bytes, $offsets[$i], $counts[$i])
    }
    return $stream.ToArray()
}

function Compare-TiffRaster([string]$Reference, [string]$Actual, [string]$Label) {
    $a = Get-TiffRaster $Reference
    $b = Get-TiffRaster $Actual
    if ($a.Length -ne $b.Length) {
        throw "$Label length mismatch: $($a.Length) vs $($b.Length)"
    }
    for ($index = 0; $index -lt $a.Length; $index++) {
        if ($a[$index] -ne $b[$index]) {
            throw "$Label differs at raster byte $index ref=$($a[$index]) actual=$($b[$index])"
        }
    }
    Write-Host "$Label LOSSLESS OK ($($a.Length) raster bytes)"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if (-not $SkipBuild) {
    Invoke-NativeChecked "ReleaseFast native build" "zig" @("build", "-Doptimize=ReleaseFast", "-Dtarget=native")
}

$z2000 = ".\zig-out\bin\z2000.exe"
$opjCompress = Join-Path $OpenJpegBin "opj_compress.exe"
$opjDecompress = Join-Path $OpenJpegBin "opj_decompress.exe"
$grokCompress = Join-Path $GrokBin "grk_compress.exe"
$grokDecompress = Join-Path $GrokBin "grk_decompress.exe"
Require-File $z2000
Require-File $opjCompress
Require-File $opjDecompress
Require-File $grokCompress
Require-File $grokDecompress
if (-not $SkipKakadu -and -not (Get-Command $KduCompress -ErrorAction SilentlyContinue)) {
    throw "missing Kakadu compressor: $KduCompress"
}
if (-not $SkipKakadu -and -not (Get-Command $KduExpand -ErrorAction SilentlyContinue)) {
    throw "missing Kakadu decoder: $KduExpand"
}

$fixture = Join-Path $OutDir "fixture.tif"
New-RgbTiffFixture $fixture 128 128

$cases = @(
    @{
        Name = "openjpeg"
        Jp2 = Join-Path $OutDir "opj-mt-pltless.jp2"
        Dec = Join-Path $OutDir "opj-dec-z2000.tif"
        Exe = $opjCompress
        Args = @("-i", $fixture, "-o", (Join-Path $OutDir "opj-mt-pltless.jp2"), "-t", "64,64", "-n", "3", "-b", "8,8", "-c", "[16,16],[16,16],[16,16]", "-p", "RPCL")
    },
    @{
        Name = "grok"
        Jp2 = Join-Path $OutDir "grok-mt-pltless.jp2"
        Dec = Join-Path $OutDir "grok-dec-z2000.tif"
        Exe = $grokCompress
        Args = @("-i", $fixture, "-o", (Join-Path $OutDir "grok-mt-pltless.jp2"), "-t", "64,64", "-n", "3", "-b", "8,8", "-c", "[16,16],[16,16],[16,16]", "-p", "RPCL")
    },
    @{
        Name = "openjpeg-default-precinct"
        Jp2 = Join-Path $OutDir "opj-mt-default-precinct.jp2"
        Dec = Join-Path $OutDir "opj-default-precinct-dec-z2000.tif"
        Exe = $opjCompress
        Args = @("-i", $fixture, "-o", (Join-Path $OutDir "opj-mt-default-precinct.jp2"), "-t", "64,64", "-n", "3", "-p", "RPCL")
    },
    @{
        Name = "grok-default-precinct"
        Jp2 = Join-Path $OutDir "grok-mt-default-precinct.jp2"
        Dec = Join-Path $OutDir "grok-default-precinct-dec-z2000.tif"
        Exe = $grokCompress
        Args = @("-i", $fixture, "-o", (Join-Path $OutDir "grok-mt-default-precinct.jp2"), "-t", "64,64", "-n", "3", "-p", "RPCL")
    },
    @{
        Name = "openjpeg-odd-origin"
        Jp2 = Join-Path $OutDir "opj-mt-odd-origin.jp2"
        Dec = Join-Path $OutDir "opj-odd-origin-dec-z2000.tif"
        Exe = $opjCompress
        Args = @("-i", $fixture, "-o", (Join-Path $OutDir "opj-mt-odd-origin.jp2"), "-t", "17,17", "-n", "3", "-b", "4,4", "-c", "[8,8],[8,8],[8,8]", "-p", "RPCL")
    },
    @{
        Name = "grok-odd-origin"
        Jp2 = Join-Path $OutDir "grok-mt-odd-origin.jp2"
        Dec = Join-Path $OutDir "grok-odd-origin-dec-z2000.tif"
        Exe = $grokCompress
        Args = @("-i", $fixture, "-o", (Join-Path $OutDir "grok-mt-odd-origin.jp2"), "-t", "17,17", "-n", "3", "-b", "4,4", "-c", "[8,8],[8,8],[8,8]", "-p", "RPCL")
    }
)

if (-not $SkipKakadu) {
    $cases += @{
        Name = "kakadu"
        Jp2 = Join-Path $OutDir "kdu-mt-pltless.jp2"
        Dec = Join-Path $OutDir "kdu-dec-z2000.tif"
        Exe = $KduCompress
        Args = @("-i", $fixture, "-o", (Join-Path $OutDir "kdu-mt-pltless.jp2"), "Creversible=yes", "Clevels=2", "Corder=RPCL", "Cblk={8,8}", "Cprecincts={16,16},{16,16},{16,16}", "Stiles={64,64}", "-no_weights", "-quiet")
    }
    $cases += @{
        Name = "kakadu-default-precinct"
        Jp2 = Join-Path $OutDir "kdu-mt-default-precinct.jp2"
        Dec = Join-Path $OutDir "kdu-default-precinct-dec-z2000.tif"
        Exe = $KduCompress
        Args = @("-i", $fixture, "-o", (Join-Path $OutDir "kdu-mt-default-precinct.jp2"), "Creversible=yes", "Clevels=2", "Corder=RPCL", "Stiles={64,64}", "-no_weights", "-quiet")
    }
    $cases += @{
        Name = "kakadu-odd-origin"
        Jp2 = Join-Path $OutDir "kdu-mt-odd-origin.jp2"
        Dec = Join-Path $OutDir "kdu-odd-origin-dec-z2000.tif"
        Exe = $KduCompress
        Args = @("-i", $fixture, "-o", (Join-Path $OutDir "kdu-mt-odd-origin.jp2"), "Creversible=yes", "Clevels=2", "Corder=RPCL", "Cblk={4,4}", "Cprecincts={8,8},{8,8},{8,8}", "Stiles={17,17}", "-no_weights", "-quiet")
    }
}

foreach ($case in $cases) {
    Invoke-NativeChecked "$($case.Name) PLT-less multi-tile encode" $case.Exe $case.Args
    Invoke-NativeChecked "$($case.Name) z2000 strict stats" $z2000 @("jp2-stats", $case.Jp2)
    Invoke-NativeChecked "$($case.Name) z2000 strict decode" $z2000 @("decode-temp-jp2", $case.Jp2, $case.Dec)
    Compare-TiffRaster $fixture $case.Dec "$($case.Name) -> z2000"
}

$anchoredJp2 = Join-Path $OutDir "z2000-reference-grid-multitile.jp2"
$anchoredZ2000 = Join-Path $OutDir "z2000-reference-grid-z2000.tif"
$anchoredOpj = Join-Path $OutDir "z2000-reference-grid-openjpeg.tif"
$anchoredGrok = Join-Path $OutDir "z2000-reference-grid-grok.tif"
$anchoredKdu = Join-Path $OutDir "z2000-reference-grid-kakadu.tif"
$anchoredArgs = @(
    "tiff-to-jp2", $fixture, $anchoredJp2,
    "--tile", "17,17",
    "--levels", "2",
    "--block", "4",
    "--precincts", "[8,8],[8,8],[8,8]",
    "--progression", "RPCL",
    "--layers", "2",
    "--tile-parts", "R",
    "--threads", "4"
)
Invoke-NativeChecked "z2000 reference-grid multi-tile encode" $z2000 $anchoredArgs
Invoke-NativeChecked "z2000 reference-grid strict stats" $z2000 @("jp2-stats", $anchoredJp2)
Invoke-NativeChecked "z2000 reference-grid strict decode" $z2000 @("decode-temp-jp2", $anchoredJp2, $anchoredZ2000, "--threads", "4")
Compare-TiffRaster $fixture $anchoredZ2000 "z2000 reference-grid strict decode"

Invoke-NativeChecked "OpenJPEG decode z2000 reference-grid multi-tile" $opjDecompress @("-i", $anchoredJp2, "-o", $anchoredOpj, "-quiet")
Compare-TiffRaster $fixture $anchoredOpj "OpenJPEG reference-grid decode"
Invoke-NativeChecked "Grok decode z2000 reference-grid multi-tile" $grokDecompress @("-i", $anchoredJp2, "-o", $anchoredGrok)
Compare-TiffRaster $fixture $anchoredGrok "Grok reference-grid decode"
if (-not $SkipKakadu) {
    Invoke-NativeChecked "Kakadu decode z2000 reference-grid multi-tile" $KduExpand @("-i", $anchoredJp2, "-o", $anchoredKdu, "-quiet")
    Compare-TiffRaster $fixture $anchoredKdu "Kakadu reference-grid decode"
}

Write-Host "PLT-less multi-tile interop smoke passed."
