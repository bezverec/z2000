param(
    [string]$OutDir = "zig-out\interop-bmp",
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
    if ($LASTEXITCODE -ne 0) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
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
$source = Join-Path $output "source.bmp"
Copy-Item -LiteralPath (Join-Path $root "src\testdata\imagemagick-bmp24-3x2.bmp") -Destination $source -Force

$z2k = Join-Path $root "zig-out\bin\z2k.exe"
$jp2 = Join-Path $output "z2k.jp2"
$roundtrip = Join-Path $output "z2k-roundtrip.tif"
Invoke-NativeChecked "BMP to JP2" $z2k @($source, $jp2, "--levels", "1", "--threads", "1")
Invoke-NativeChecked "z2000 JP2 to TIFF" $z2k @($jp2, $roundtrip, "--threads", "1")
Assert-AeZero $source $roundtrip "z2000 roundtrip"

if (-not $SkipExternalDecoders) {
    $openJpegTiff = Join-Path $output "openjpeg.tif"
    $grokTiff = Join-Path $output "grok.tif"
    Invoke-NativeChecked "OpenJPEG decode" $OpenJpeg @("-i", $jp2, "-o", $openJpegTiff)
    Invoke-NativeChecked "Grok decode" $Grok @("-i", $jp2, "-o", $grokTiff)
    Assert-AeZero $source $openJpegTiff "OpenJPEG decode"
    Assert-AeZero $source $grokTiff "Grok decode"
}

Copy-Item -LiteralPath $source -Destination (Join-Path $output "second.BMP") -Force
Push-Location $output
try {
    Invoke-NativeChecked "BMP batch" $z2k @("*.bmp", ".jp2", "--levels", "1", "--threads", "1")
} finally {
    Pop-Location
}
if (-not (Test-Path -LiteralPath (Join-Path $output "source.jp2")) -or
    -not (Test-Path -LiteralPath (Join-Path $output "second.jp2"))) {
    throw "BMP batch did not create both expected JP2 files"
}

Write-Host "BMP interop PASS"
