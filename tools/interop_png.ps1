param(
    [string]$OutDir = "zig-out\interop-png",
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

if (-not $SkipBuild) {
    Invoke-NativeChecked "ReleaseFast build" "zig" @("build", "-Doptimize=ReleaseFast", "-Dtarget=native")
}

$root = (Resolve-Path -LiteralPath ".").Path
$output = Join-Path $root $OutDir
New-Item -ItemType Directory -Force -Path $output | Out-Null
$z2k = Join-Path $root "zig-out\bin\z2k.exe"
$fixtures = @("gray2", "gray8", "graya8", "gray-trns", "palette-trns", "rgb8", "rgb16", "rgb-trns", "rgba8", "rgba16")

foreach ($name in $fixtures) {
    $source = Join-Path $root "src\testdata\imagemagick-png-$name.png"
    $jp2 = Join-Path $output "$name.jp2"
    $roundtrip = Join-Path $output "$name.tif"
    Invoke-NativeChecked "$name PNG to JP2" $z2k @($source, $jp2, "--levels", "1", "--threads", "1")
    Invoke-NativeChecked "$name JP2 to TIFF" $z2k @($jp2, $roundtrip, "--threads", "1")
    Assert-AeZero $source $roundtrip "$name z2000 roundtrip"
}

if (-not $SkipExternalDecoders) {
    foreach ($name in @("rgb8", "rgb16")) {
        $source = Join-Path $root "src\testdata\imagemagick-png-$name.png"
        $jp2 = Join-Path $output "$name.jp2"
        $openJpegTiff = Join-Path $output "$name-openjpeg.tif"
        $grokTiff = Join-Path $output "$name-grok.tif"
        Invoke-NativeChecked "$name OpenJPEG decode" $OpenJpeg @("-i", $jp2, "-o", $openJpegTiff)
        Invoke-NativeChecked "$name Grok decode" $Grok @("-i", $jp2, "-o", $grokTiff)
        Assert-AeZero $source $openJpegTiff "$name OpenJPEG decode"
        Assert-AeZero $source $grokTiff "$name Grok decode"
    }
}

$batch = Join-Path $output "batch"
New-Item -ItemType Directory -Force -Path $batch | Out-Null
Copy-Item -LiteralPath (Join-Path $root "src\testdata\imagemagick-png-rgb8.png") -Destination (Join-Path $batch "first.png") -Force
Copy-Item -LiteralPath (Join-Path $root "src\testdata\imagemagick-png-rgb8.png") -Destination (Join-Path $batch "second.PNG") -Force
Push-Location $batch
try {
    Invoke-NativeChecked "PNG batch" $z2k @("*.png", ".jp2", "--levels", "1", "--threads", "1")
} finally {
    Pop-Location
}
if (-not (Test-Path -LiteralPath (Join-Path $batch "first.jp2")) -or
    -not (Test-Path -LiteralPath (Join-Path $batch "second.jp2"))) {
    throw "PNG batch did not create both expected JP2 files"
}

Write-Host "PNG interop PASS"
