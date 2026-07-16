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

function Add-Bytes([System.Collections.Generic.List[byte]]$Output, [byte[]]$Bytes) {
    $Output.AddRange($Bytes)
}

function New-JpegSegment([byte]$Marker, [byte[]]$Payload) {
    $length = $Payload.Length + 2
    return [byte[]](@(0xff, $Marker, [byte]($length -shr 8), [byte]($length -band 0xff)) + $Payload)
}

function Assert-ContainsBytes([byte[]]$Haystack, [byte[]]$Needle, [string]$Label) {
    for ($start = 0; $start -le $Haystack.Length - $Needle.Length; $start++) {
        $matches = $true
        for ($offset = 0; $offset -lt $Needle.Length; $offset++) {
            if ($Haystack[$start + $offset] -ne $Needle[$offset]) {
                $matches = $false
                break
            }
        }
        if ($matches) {
            Write-Host "$Label exact payload found"
            return
        }
    }
    throw "$Label exact payload missing"
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

# Inject the bounded metadata forms into the independent 4:4:4 JPEG fixture.
# The byte-exact carrier assertions also pin the canonical UUID identifiers.
$metadataSource = Join-Path $output "metadata.jpg"
$sourceBytes = [IO.File]::ReadAllBytes((Join-Path $root "src\testdata\imagemagick-jpeg-444.jpg"))
$exif = [byte[]](73, 73, 42, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0)
$xmp = [Text.Encoding]::UTF8.GetBytes("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>")
$iptc = [byte[]](0x1c, 2, 5, 0, 4, 0x74, 0x65, 0x73, 0x74)
$app1Exif = [byte[]]([Text.Encoding]::ASCII.GetBytes("Exif`0`0") + $exif)
$app1Xmp = [byte[]]([Text.Encoding]::ASCII.GetBytes("http://ns.adobe.com/xap/1.0/`0") + $xmp)
$app13 = New-Object System.Collections.Generic.List[byte]
Add-Bytes $app13 ([Text.Encoding]::ASCII.GetBytes("Photoshop 3.0`08BIM"))
Add-Bytes $app13 ([byte[]](0x04, 0x04, 0, 0, 0, 0, 0, $iptc.Length))
Add-Bytes $app13 $iptc
$app13.Add(0)
$metadataJpeg = New-Object System.Collections.Generic.List[byte]
Add-Bytes $metadataJpeg ([byte[]]$sourceBytes[0..1])
Add-Bytes $metadataJpeg (New-JpegSegment 0xe1 $app1Exif)
Add-Bytes $metadataJpeg (New-JpegSegment 0xe1 $app1Xmp)
Add-Bytes $metadataJpeg (New-JpegSegment 0xed $app13.ToArray())
Add-Bytes $metadataJpeg ([byte[]]$sourceBytes[2..($sourceBytes.Length - 1)])
[IO.File]::WriteAllBytes($metadataSource, $metadataJpeg.ToArray())

$metadataJp2 = Join-Path $output "metadata.jp2"
$metadataTiff = Join-Path $output "metadata-z2k.tif"
Invoke-NativeChecked "metadata JPEG to JP2" $z2k @($metadataSource, $metadataJp2, "--levels", "1", "--threads", "1")
Invoke-NativeChecked "metadata JP2 to TIFF" $z2k @($metadataJp2, $metadataTiff, "--threads", "1")
$metadataPsnr = Get-Psnr $metadataSource $metadataTiff
if ($metadataPsnr -lt 54.0) { throw "metadata decoder agreement too low: $metadataPsnr dB" }
$jp2Bytes = [IO.File]::ReadAllBytes($metadataJp2)
Assert-ContainsBytes $jp2Bytes ([byte[]]([Text.Encoding]::ASCII.GetBytes("JpgTiffExif->JP2") + $exif)) "EXIF UUID"
Assert-ContainsBytes $jp2Bytes ([byte[]]([byte[]](0xbe,0x7a,0xcf,0xcb,0x97,0xa9,0x42,0xe8,0x9c,0x71,0x99,0x94,0x91,0xe3,0xaf,0xac) + $xmp)) "XMP UUID"
Assert-ContainsBytes $jp2Bytes ([byte[]]([byte[]](0x33,0xc7,0xa4,0xd2,0xb8,0x1d,0x47,0x23,0xa0,0xba,0xf1,0xa3,0xe0,0x97,0xad,0x38) + $iptc)) "IPTC UUID"

if (-not $SkipExternalDecoders) {
    foreach ($name in @("444", "420", "restart", "metadata")) {
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
