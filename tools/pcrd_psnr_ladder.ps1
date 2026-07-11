param(
    [string]$OutDir = "zig-out\pcrd-psnr-ladder",
    [string]$Z2000 = ".\zig-out\bin\z2000.exe",
    [string]$OpjCompress = "opj_compress.exe",
    [string]$OpjDecompress = "opj_decompress.exe",
    [switch]$SkipBuild
)

# PCRD PSNR ladder: measures z2000's rate-targeted quality-layer allocator
# against OpenJPEG's at MATCHED payload byte sizes.
#
# z2000 encodes one 5-layer 9/7 stream (rates reference the total compressed
# payload; the final layer is always complete). Each intermediate layer
# prefix is decoded with opj_decompress -l L and its exact packet byte size
# is read from the PLT (LRCP order: layer is the outermost loop, so the
# per-layer PLT prefix sums are the layer sizes). OpenJPEG then encodes the
# same corpus at the compression ratio that reproduces each layer's byte
# size (opj -r references the uncompressed size, 196608 B), and both
# reconstructions are scored as PSNR against the source.
#
# Result 2026-07-11 (256x256 mixed corpus below, this repo at 85/100):
#   layer 1: z2000  637 B -> 15.17 dB | opj -r 309 ( 644 B) -> 16.95 dB | delta 1.78 dB
#   layer 2: z2000 1333 B -> 19.32 dB | opj -r 147 (1317 B) -> 20.00 dB | delta 0.69 dB
#   layer 3: z2000 2693 B -> 21.86 dB | opj -r  73 (2707 B) -> 23.08 dB | delta 1.21 dB
#   layer 4: z2000 5383 B -> 24.91 dB | opj -r  37 (5329 B) -> 26.69 dB | delta 1.78 dB
# i.e. the current global PCRD allocation trails OpenJPEG by ~0.7-1.8 dB at
# matched payload sizes on this corpus. Track improvements against these.

$ErrorActionPreference = 'Stop'

function Require-Command([string]$Name) {
    if (Test-Path -LiteralPath $Name) {
        return (Resolve-Path -LiteralPath $Name).Path
    }
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "missing required command: $Name"
    }
    return (Get-Command $Name).Source
}

$opjRoot = "C:\temp\tools\openjpeg-v2.5.4-windows-x64\openjpeg-v2.5.4-windows-x64\bin"
if ($OpjCompress -eq "opj_compress.exe" -and -not (Get-Command $OpjCompress -ErrorAction SilentlyContinue)) {
    $candidate = Join-Path $opjRoot "opj_compress.exe"
    if (Test-Path -LiteralPath $candidate) { $OpjCompress = $candidate }
}
if ($OpjDecompress -eq "opj_decompress.exe" -and -not (Get-Command $OpjDecompress -ErrorAction SilentlyContinue)) {
    $candidate = Join-Path $opjRoot "opj_decompress.exe"
    if (Test-Path -LiteralPath $candidate) { $OpjDecompress = $candidate }
}
$OpjCompress = Require-Command $OpjCompress
$OpjDecompress = Require-Command $OpjDecompress
if (-not $SkipBuild) {
    & zig build -Doptimize=ReleaseFast -Dtarget=native
    if ($LASTEXITCODE -ne 0) { throw "zig build failed" }
}
if (-not (Test-Path -LiteralPath $Z2000)) { throw "missing z2000 binary: $Z2000" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# --- 256x256 mixed-content corpus (integer-only; mirrored by the in-tree
# test "rate-targeted layer byte accounting stays pinned on the PCRD corpus").
$w = 256; $h = 256
$pix = New-Object byte[] ($w * $h * 3)
for ($y = 0; $y -lt $h; $y++) {
    for ($x = 0; $x -lt $w; $x++) {
        $p = ($y * $w + $x) * 3
        $pix[$p] = ($x + $y) -shr 1
        $pix[$p + 1] = ((($x % 64) * 4 + ($y % 32) * 2)) -band 0xff
        $checker = if (((([math]::Floor($x / 32)) + ([math]::Floor($y / 32))) % 2) -eq 0) { 200 } else { 56 }
        $noise = ((($x * 73856093) -bxor ($y * 19349663)) -shr 13) -band 15
        $pix[$p + 2] = [byte](($checker + $noise) -band 0xff)
    }
}
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([byte[]]@(0x49, 0x49, 42, 0))
$dataOffset = 8
$ifdOffset = $dataOffset + $pix.Length
$bw.Write([uint32]$ifdOffset)
$bw.Write($pix)
$nTags = 10
$bpsOffset = $ifdOffset + 2 + $nTags * 12 + 4
$bw.Write([uint16]$nTags)
function WT($bw, $tag, $type, $count, $value) { $bw.Write([uint16]$tag); $bw.Write([uint16]$type); $bw.Write([uint32]$count); $bw.Write([uint32]$value) }
WT $bw 256 3 1 $w
WT $bw 257 3 1 $h
WT $bw 258 3 3 $bpsOffset
WT $bw 259 3 1 1
WT $bw 262 3 1 2
WT $bw 273 4 1 $dataOffset
WT $bw 277 3 1 3
WT $bw 278 3 1 $h
WT $bw 279 4 1 $pix.Length
WT $bw 284 3 1 1
$bw.Write([uint32]0)
$bw.Write([uint16]8); $bw.Write([uint16]8); $bw.Write([uint16]8)
$bw.Flush()
$srcTif = Join-Path $OutDir 'pcrd-corpus-256.tif'
[System.IO.File]::WriteAllBytes($srcTif, $ms.ToArray())

Add-Type -TypeDefinition @'
public static class PcrdPsnr {
    public static double Psnr(byte[] a, byte[] b) {
        long sse = 0;
        for (int i = 0; i < a.Length; i++) { int d = a[i] - b[i]; sse += (long)d * d; }
        double mse = (double)sse / a.Length;
        return mse == 0 ? double.PositiveInfinity : 10.0 * System.Math.Log10(255.0 * 255.0 / mse);
    }
}
'@

function Read-TiffRaster([string]$path) {
    $b = [System.IO.File]::ReadAllBytes($path)
    $le = $b[0] -eq 0x49
    if (-not $le -and $b[0] -ne 0x4d) { throw "not a TIFF: $path" }
    function RdU16([byte[]]$buf, [int]$at, [bool]$little) { if ($little) { return [BitConverter]::ToUInt16($buf, $at) } else { return ([uint16]$buf[$at] -shl 8) + $buf[$at + 1] } }
    function RdU32([byte[]]$buf, [int]$at, [bool]$little) { if ($little) { return [BitConverter]::ToUInt32($buf, $at) } else { return ([uint32]$buf[$at] -shl 24) + ([uint32]$buf[$at + 1] -shl 16) + ([uint32]$buf[$at + 2] -shl 8) + $buf[$at + 3] } }
    $ifd = RdU32 $b 4 $le
    $n = RdU16 $b $ifd $le
    $offsets = @(); $counts = @()
    for ($i = 0; $i -lt $n; $i++) {
        $e = $ifd + 2 + $i * 12
        $tag = RdU16 $b $e $le; $type = RdU16 $b ($e + 2) $le
        $cnt = RdU32 $b ($e + 4) $le
        if ($tag -eq 273 -or $tag -eq 279) {
            $arr = @()
            if ($cnt -eq 1) { if ($type -eq 3) { $arr = @((RdU16 $b ($e + 8) $le)) } else { $arr = @((RdU32 $b ($e + 8) $le)) } }
            else { $val = RdU32 $b ($e + 8) $le; for ($j = 0; $j -lt $cnt; $j++) { if ($type -eq 3) { $arr += [uint32](RdU16 $b ($val + $j * 2) $le) } else { $arr += (RdU32 $b ($val + $j * 4) $le) } } }
            if ($tag -eq 273) { $offsets = $arr } else { $counts = $arr }
        }
    }
    $ms2 = New-Object System.IO.MemoryStream
    for ($i = 0; $i -lt $offsets.Count; $i++) { $ms2.Write($b, $offsets[$i], $counts[$i]) }
    return $ms2.ToArray()
}

# --- z2000 layered encode (no SOP/TLM so packet bytes are pure payload).
$zjp2 = Join-Path $OutDir 'z2000-layers.jp2'
& $Z2000 tiff-to-jp2 $srcTif $zjp2 --transform 9-7 --mct ict --qstyle scalar-expounded --progression LRCP --rates "80,40,20,10,5" --no-sop --no-tlm --threads 1
if ($LASTEXITCODE -ne 0) { throw "z2000 encode failed" }

# --- per-layer cumulative packet bytes from the PLT (LRCP: layer outermost).
$b = [System.IO.File]::ReadAllBytes($zjp2)
$lengths = New-Object System.Collections.Generic.List[long]
for ($i = 0; $i -lt $b.Length - 3; $i++) {
    if ($b[$i] -eq 0xff -and $b[$i + 1] -eq 0x58) {
        $seglen = ($b[$i + 2] -shl 8) + $b[$i + 3]
        $p = $i + 5; $end = $i + 2 + $seglen; $val = [long]0
        while ($p -lt $end) { $byte = $b[$p]; $val = ($val -shl 7) -bor ($byte -band 0x7f); if (($byte -band 0x80) -eq 0) { $lengths.Add($val); $val = 0 }; $p++ }
        $i = $end - 1
    }
}
if ($lengths.Count % 5 -ne 0) { throw "packet count $($lengths.Count) not divisible by 5 layers" }
$per = $lengths.Count / 5
$cums = @(); $cum = [long]0
for ($l = 0; $l -lt 5; $l++) { $sum = [long]0; for ($k = 0; $k -lt $per; $k++) { $sum += $lengths[$l * $per + $k] }; $cum += $sum; $cums += $cum }

[byte[]]$src = Read-TiffRaster $srcTif
Write-Host ""
Write-Host "== PCRD PSNR LADDER: z2000 layer prefixes vs OpenJPEG at matched bytes =="
$worst = 0.0
for ($l = 1; $l -le 4; $l++) {
    $ztif = Join-Path $OutDir "z2000-l$l.tif"
    & $OpjDecompress -i $zjp2 -o $ztif -l $l *> $null
    if ($LASTEXITCODE -ne 0) { throw "opj_decompress -l $l failed on the z2000 stream" }
    [byte[]]$zr = Read-TiffRaster $ztif
    $zpsnr = [PcrdPsnr]::Psnr($zr, $src)

    $r = [math]::Max(1, [math]::Round(196608.0 / $cums[$l - 1]))
    $ojp2 = Join-Path $OutDir "opj-l$l.jp2"
    $otif = Join-Path $OutDir "opj-l$l.tif"
    & $OpjCompress -i $srcTif -o $ojp2 -I -r $r *> $null
    if ($LASTEXITCODE -ne 0) { throw "opj_compress -r $r failed" }
    & $OpjDecompress -i $ojp2 -o $otif *> $null
    if ($LASTEXITCODE -ne 0) { throw "opj_decompress failed" }
    [byte[]]$or = Read-TiffRaster $otif
    $opsnr = [PcrdPsnr]::Psnr($or, $src)
    $delta = $opsnr - $zpsnr
    if ($delta -gt $worst) { $worst = $delta }
    Write-Host ("layer {0}: z2000 {1,6} B -> {2,6:F2} dB | opj -r {3,3} ({4,6} B file) -> {5,6:F2} dB | delta {6,5:F2} dB" -f `
        $l, $cums[$l - 1], $zpsnr, $r, (Get-Item $ojp2).Length, $opsnr, $delta)
}
Write-Host ""
Write-Host ("worst allocator deficit vs OpenJPEG at matched bytes: {0:F2} dB" -f $worst)
Write-Host "(2026-07-11 baseline: 1.78 / 0.69 / 1.21 / 1.78 dB per layer; improvements should shrink these)"
