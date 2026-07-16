# OpenEXR fixture provenance

The unit tests construct a minimal 2x2, single-part, uncompressed scanline
OpenEXR file in memory. It contains exactly full-resolution HALF channels
`B`, `G`, and `R`, normalized finite samples, matching data/display windows,
and explicit Rec. 709/D65 chromaticities. Expected unsigned 16-bit samples are
computed directly from the exact HALF values.

`tools/interop_openexr.ps1` asks ImageMagick's OpenEXR delegate to produce the
raster and standard header, then reproducibly inserts the explicit
`chromaticities` attribute required by z2000's fail-closed profile and adjusts
the scanline offset table. The pixel chunks remain producer-authored. The
script exercises z2000, OpenJPEG, Grok, explicit ICC rendering, and the
case-insensitive unquoted batch path.
