param(
    [string]$OutDir = "zig-out\interop-jpeg",
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

function Get-Psnr([string]$Reference, [string]$Actual) {
    $metric = (& $Magick compare -metric PSNR $Reference $Actual null: 2>&1 | Out-String).Trim()
    $value = 0.0
    if (-not [double]::TryParse(($metric -replace '\s.*$', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        throw "PSNR comparison failed: $metric"
    }
    return $value
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
$fixtures = @("gray", "444", "422", "420", "restart")

foreach ($name in $fixtures) {
    $source = Join-Path $root "src\testdata\imagemagick-jpeg-$name.jpg"
    $jp2 = Join-Path $output "$name.jp2"
    $roundtrip = Join-Path $output "$name-z2k.tif"
    Invoke-NativeChecked "$name JPEG to JP2" $z2k @($source, $jp2, "--levels", "1", "--threads", "1")
    Invoke-NativeChecked "$name JP2 to TIFF" $z2k @($jp2, $roundtrip, "--threads", "1")
    $psnr = Get-Psnr $source $roundtrip
    if ($psnr -lt 54.0) { throw "$name decoder agreement too low: $psnr dB" }
    Write-Host "$name source-decoder agreement $psnr dB"
}

if (-not $SkipExternalDecoders) {
    foreach ($name in @("444", "420", "restart")) {
        $jp2 = Join-Path $output "$name.jp2"
        $reference = Join-Path $output "$name-z2k.tif"
        $openJpegTiff = Join-Path $output "$name-openjpeg.tif"
        $grokTiff = Join-Path $output "$name-grok.tif"
        Invoke-NativeChecked "$name OpenJPEG decode" $OpenJpeg @("-i", $jp2, "-o", $openJpegTiff)
        Invoke-NativeChecked "$name Grok decode" $Grok @("-i", $jp2, "-o", $grokTiff)
        Assert-AeZero $reference $openJpegTiff "$name OpenJPEG decode"
        Assert-AeZero $reference $grokTiff "$name Grok decode"
    }
}

$batch = Join-Path $output "batch"
New-Item -ItemType Directory -Force -Path $batch | Out-Null
Copy-Item -LiteralPath (Join-Path $root "src\testdata\imagemagick-jpeg-444.jpg") -Destination (Join-Path $batch "first.jpg") -Force
Copy-Item -LiteralPath (Join-Path $root "src\testdata\imagemagick-jpeg-420.jpg") -Destination (Join-Path $batch "second.JPG") -Force
Push-Location $batch
try {
    Invoke-NativeChecked "JPEG batch" $z2k @("*.jpg", ".jp2", "--levels", "1", "--threads", "1")
} finally {
    Pop-Location
}
if (-not (Test-Path -LiteralPath (Join-Path $batch "first.jp2")) -or
    -not (Test-Path -LiteralPath (Join-Path $batch "second.jp2"))) {
    throw "JPEG batch did not create both expected JP2 files"
}

Write-Host "JPEG interop PASS"
