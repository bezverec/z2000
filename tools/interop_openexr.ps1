param(
    [string]$OutDir = "zig-out\interop-openexr",
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
    $metric = (& $Magick compare -fuzz 0.01% -metric AE $Reference $Actual null: 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $metric -notmatch '^0(?:\s|$|\()') {
        throw "$Label pixel mismatch beyond tolerance: $metric"
    }
    Write-Host "$Label bounded AE=$metric"
}

function Read-CString([byte[]]$Bytes, [ref]$Cursor) {
    $start = $Cursor.Value
    while ($Cursor.Value -lt $Bytes.Length -and $Bytes[$Cursor.Value] -ne 0) {
        $Cursor.Value++
    }
    if ($Cursor.Value -ge $Bytes.Length) { throw "truncated EXR header" }
    $value = [Text.Encoding]::ASCII.GetString($Bytes, $start, $Cursor.Value - $start)
    $Cursor.Value++
    return $value
}

function Add-Chromaticities([string]$InputPath, [string]$OutputPath) {
    [byte[]]$source = [IO.File]::ReadAllBytes($InputPath)
    $cursor = 8
    $height = 0
    while ($true) {
        $attributeStart = $cursor
        $name = Read-CString $source ([ref]$cursor)
        if ($name.Length -eq 0) {
            $terminator = $attributeStart
            break
        }
        $type = Read-CString $source ([ref]$cursor)
        if ($cursor + 4 -gt $source.Length) { throw "truncated EXR attribute size" }
        $size = [BitConverter]::ToInt32($source, $cursor)
        $cursor += 4
        if ($size -lt 0 -or $cursor + $size -gt $source.Length) { throw "invalid EXR attribute size" }
        if ($name -eq "dataWindow" -and $type -eq "box2i" -and $size -eq 16) {
            $minY = [BitConverter]::ToInt32($source, $cursor + 4)
            $maxY = [BitConverter]::ToInt32($source, $cursor + 12)
            $height = $maxY - $minY + 1
        }
        $cursor += $size
    }
    if ($height -le 0) { throw "missing/invalid EXR dataWindow" }

    $attributeStream = [IO.MemoryStream]::new()
    try {
        $writer = [IO.BinaryWriter]::new($attributeStream)
        try {
            $writer.Write([Text.Encoding]::ASCII.GetBytes("chromaticities"))
            $writer.Write([byte]0)
            $writer.Write([Text.Encoding]::ASCII.GetBytes("chromaticities"))
            $writer.Write([byte]0)
            $writer.Write([Int32]32)
            foreach ($value in @([single]0.64, [single]0.33, [single]0.30, [single]0.60, [single]0.15, [single]0.06, [single]0.3127, [single]0.3290)) {
                $writer.Write($value)
            }
        } finally {
            $writer.Dispose()
        }
        [byte[]]$attribute = $attributeStream.ToArray()
    } finally {
        $attributeStream.Dispose()
    }

    [byte[]]$output = [byte[]]::new($source.Length + $attribute.Length)
    [Array]::Copy($source, 0, $output, 0, $terminator)
    [Array]::Copy($attribute, 0, $output, $terminator, $attribute.Length)
    [Array]::Copy($source, $terminator, $output, $terminator + $attribute.Length, $source.Length - $terminator)
    $tableStart = $terminator + $attribute.Length + 1
    for ($index = 0; $index -lt $height; $index++) {
        $entry = $tableStart + $index * 8
        $offset = [BitConverter]::ToUInt64($output, $entry)
        [Array]::Copy([BitConverter]::GetBytes([UInt64]($offset + $attribute.Length)), 0, $output, $entry, 8)
    }
    [IO.File]::WriteAllBytes($OutputPath, $output)
}

if (-not $SkipBuild) {
    Invoke-NativeChecked "ReleaseFast build" "zig" @("build", "-Doptimize=ReleaseFast", "-Dtarget=native")
}

$root = (Resolve-Path -LiteralPath ".").Path
$output = Join-Path $root $OutDir
New-Item -ItemType Directory -Force -Path $output | Out-Null
$z2k = Join-Path $root "zig-out\bin\z2k.exe"
$producerExr = Join-Path $output "imagemagick-source.exr"
$source = Join-Path $output "imagemagick-rgb-half.exr"
$jp2 = Join-Path $output "imagemagick-rgb-half.jp2"
$reference = Join-Path $output "imagemagick-rgb-half-z2k.tif"
$srgbReference = Join-Path $output "imagemagick-rgb-half-z2k-srgb.tif"

Invoke-NativeChecked "ImageMagick EXR fixture" $Magick @(
    "-size", "3x2", "gradient:black-white", "-colorspace", "RGB",
    "-define", "exr:compression=none", "-define", "exr:color-type=RGB", $producerExr
)
Add-Chromaticities $producerExr $source
Invoke-NativeChecked "OpenEXR to JP2" $z2k @($source, $jp2, "--levels", "0", "--threads", "1")
Invoke-NativeChecked "z2000 JP2 decode" $z2k @($jp2, $reference, "--threads", "1")
Invoke-NativeChecked "z2000 explicit sRGB decode" $z2k @($jp2, $srgbReference, "--threads", "1", "--convert-to-srgb")

if (-not $SkipExternalDecoders) {
    $openJpegTiff = Join-Path $output "imagemagick-rgb-half-openjpeg.tif"
    $grokTiff = Join-Path $output "imagemagick-rgb-half-grok.tif"
    Invoke-NativeChecked "OpenJPEG decode" $OpenJpeg @("-i", $jp2, "-o", $openJpegTiff)
    Invoke-NativeChecked "Grok decode" $Grok @("-i", $jp2, "-o", $grokTiff)
    Assert-AeNear $srgbReference $openJpegTiff "OpenJPEG ICC conversion"
    Assert-AeZero $reference $grokTiff "Grok linear decode"
}

$batch = Join-Path $output "batch"
New-Item -ItemType Directory -Force -Path $batch | Out-Null
Copy-Item -LiteralPath $source -Destination (Join-Path $batch "first.exr") -Force
Copy-Item -LiteralPath $source -Destination (Join-Path $batch "second.EXR") -Force
Push-Location $batch
try {
    Invoke-NativeChecked "OpenEXR batch" $z2k @("*.exr", ".jp2", "--levels", "0", "--threads", "1")
} finally {
    Pop-Location
}
if (-not (Test-Path -LiteralPath (Join-Path $batch "first.jp2")) -or
    -not (Test-Path -LiteralPath (Join-Path $batch "second.jp2"))) {
    throw "OpenEXR batch did not create both expected JP2 files"
}

Write-Host "OpenEXR interop PASS"
