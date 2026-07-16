# LinearRaw DNG fixture provenance

The LinearRaw tests construct a minimal classic-TIFF DNG in memory. It is a
2x1, 16-bit, uncompressed chunky three-channel raster with explicit black and
white levels, an identity `ColorMatrix1`, neutral `AsShotNeutral`, and an
sRGB-compatible D50 `ForwardMatrix1`. The expected raster is computed from
the DNG black/white normalization formula.

`tools/interop_dng.ps1` writes the same synthetic DNG reproducibly, converts
it with z2000, compares z2000/OpenJPEG/Grok reconstruction, and exercises the
case-insensitive unquoted batch path. The fixture is synthetic because the
bounded profile deliberately excludes CFA/demosaicing and vendor-specific
raw metadata; it is not presented as independent producer evidence.

This product includes DNG technology under license by Adobe.
