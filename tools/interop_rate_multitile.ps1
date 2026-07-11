param(
    [string]$OutDir = "zig-out\interop-rate-multitile",
    [string]$OpenJpegBin = "C:\temp\tools\openjpeg-v2.5.4-windows-x64\openjpeg-v2.5.4-windows-x64\bin",
    [string]$GrokBin = "C:\temp\tools\grok-windows-latest\grok-windows-latest\bin",
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

function Require-Command([string]$Name) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "missing required command: $Name"
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
            $hash = (($x * 73856093) -bxor ($y * 19349663)) -band 0xff
            $writer.Write([byte](($x * 5 + $y * 3 + $hash) -band 0xff))
            $writer.Write([byte](($x * 11 + $y * 7 + ($hash -shr 1)) -band 0xff))
            $writer.Write([byte](($x * 17 + $y * 13 + ($hash -shr 2)) -band 0xff))
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
$opjDecompress = Join-Path $OpenJpegBin "opj_decompress.exe"
$grokDecompress = Join-Path $GrokBin "grk_decompress.exe"
Require-File $z2000
Require-File $opjDecompress
Require-File $grokDecompress
if (-not $SkipKakadu) {
    Require-Command $KduExpand
}

$fixture = Join-Path $OutDir "fixture.tif"
$jp2 = Join-Path $OutDir "z2000-rate-multitile.jp2"
$z2000Decoded = Join-Path $OutDir "z2000-decoded.tif"
$opjDecoded = Join-Path $OutDir "openjpeg-decoded.tif"
$grokDecoded = Join-Path $OutDir "grok-decoded.tif"
$kduDecoded = Join-Path $OutDir "kakadu-decoded.tif"

New-RgbTiffFixture $fixture 128 128

$encodeArgs = @(
    "tiff-to-jp2", $fixture, $jp2,
    "--tile", "64,64",
    "--levels", "2",
    "--block", "8",
    "--precincts", "[16,16],[16,16],[16,16]",
    "--progression", "LRCP",
    "--layers", "3",
    "--rates", "16,4,1",
    "--tile-parts", "none",
    "--threads", "4"
)
Invoke-NativeChecked "z2000 rate-targeted multi-tile encode" $z2000 $encodeArgs
Invoke-NativeChecked "z2000 strict stats" $z2000 @("jp2-stats", $jp2)
Invoke-NativeChecked "z2000 strict decode" $z2000 @("decode-temp-jp2", $jp2, $z2000Decoded, "--threads", "4")
Compare-TiffRaster $fixture $z2000Decoded "z2000 strict decode"

Invoke-NativeChecked "OpenJPEG decode z2000 rate-targeted multi-tile" $opjDecompress @("-i", $jp2, "-o", $opjDecoded, "-quiet")
Compare-TiffRaster $fixture $opjDecoded "OpenJPEG decode"

Invoke-NativeChecked "Grok decode z2000 rate-targeted multi-tile" $grokDecompress @("-i", $jp2, "-o", $grokDecoded)
Compare-TiffRaster $fixture $grokDecoded "Grok decode"

if (-not $SkipKakadu) {
    Invoke-NativeChecked "Kakadu decode z2000 rate-targeted multi-tile" $KduExpand @("-i", $jp2, "-o", $kduDecoded, "-quiet")
    Compare-TiffRaster $fixture $kduDecoded "Kakadu decode"
}

Write-Host "rate-targeted multi-tile interop smoke passed."
