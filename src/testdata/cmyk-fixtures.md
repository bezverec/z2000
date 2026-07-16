# CMYK Fixture Provenance

`imagemagick-cmyk-8x8.raw` contains 8-bit pixel-interleaved CMYK samples for an
8x8 red-to-blue gradient generated with ImageMagick 7.1.2-10 Q16-HDRI. The
same image was written as a separated CMYK TIFF and encoded losslessly by Grok
20.3.4 with two resolutions, one layer, and no MCT:

```text
grk_compress -i source-cmyk.tif -o grok-cmyk-8x8.jp2 -n 2 -r 1
```

Grok writes four unsigned 8-bit components and a method-1 `colr` box with
EnumCS 12 (CMYK). The test suite decodes its codestream to native planes and
compares every sample against the interleaved ImageMagick source; no colour
conversion participates in the comparison.

SHA-256:

- `grok-cmyk-8x8.jp2`:
  `6f73981dd6855e10ec50d9a17dde296c1e825aec0c800917d6e8476e70c6db05`
- `imagemagick-cmyk-8x8.raw`:
  `0bea257d62a5f8ba544228b5bd22f9ae4c4115cca9776dd7ba16479e463ea5e4`
