param(
    [string]$OutDir = "zig-out\interop-pltless-multitile",
    [string]$OpenJpegBin = "C:\temp\tools\openjpeg-v2.5.4-windows-x64\openjpeg-v2.5.4-windows-x64\bin",
    [string]$GrokBin = "C:\temp\tools\grok-windows-latest\grok-windows-latest\bin",
    [string]$KduCompress = "kdu_compress.exe",
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

function Get-TiffRaster([string]$Path) {
    $bytes = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Path).Path)
    if ($bytes[0] -ne 0x49 -or $bytes[1] -ne 0x49) {
        throw "only little-endian TIFF is supported by this smoke compare: $Path"
    }
    $ifd = [int](Read-U32Le $bytes 4)
    $entries = Read-U16Le $bytes $ifd
    $strip = 0
    $count = 0
    for ($index = 0; $index -lt $entries; $index++) {
        $entry = $ifd + 2 + $index * 12
        $tag = Read-U16Le $bytes $entry
        if ($tag -eq 273) { $strip = [int](Read-U32Le $bytes ($entry + 8)) }
        if ($tag -eq 279) { $count = [int](Read-U32Le $bytes ($entry + 8)) }
    }
    if ($strip -le 0 -or $count -le 0) {
        throw "missing strip tags in $Path"
    }
    return $bytes[$strip..($strip + $count - 1)]
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
$grokCompress = Join-Path $GrokBin "grk_compress.exe"
Require-File $z2000
Require-File $opjCompress
Require-File $grokCompress
if (-not $SkipKakadu -and -not (Get-Command $KduCompress -ErrorAction SilentlyContinue)) {
    throw "missing Kakadu compressor: $KduCompress"
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
}

foreach ($case in $cases) {
    Invoke-NativeChecked "$($case.Name) PLT-less multi-tile encode" $case.Exe $case.Args
    Invoke-NativeChecked "$($case.Name) z2000 strict stats" $z2000 @("jp2-stats", $case.Jp2)
    Invoke-NativeChecked "$($case.Name) z2000 strict decode" $z2000 @("decode-temp-jp2", $case.Jp2, $case.Dec)
    Compare-TiffRaster $fixture $case.Dec "$($case.Name) -> z2000"
}

Write-Host "PLT-less multi-tile interop smoke passed."
