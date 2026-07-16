# PNG adapter fixtures

The `imagemagick-png-*.png` files were produced with ImageMagick 7.1.2-10
using stripped PNG output. The matching `.raw` files are ImageMagick's own
pixel decodes and serve as independent oracles:

- `gray2`, `gray8`: packed 2-bit and ordinary 8-bit grayscale;
- `graya8`: grayscale plus unassociated alpha;
- `gray-trns`: grayscale with `tRNS` expansion;
- `palette-trns`: indexed color plus `PLTE` and `tRNS`;
- `rgb8`, `rgb16`: 8- and 16-bit truecolor;
- `rgb-trns`: truecolor with `tRNS` expansion;
- `rgba8`, `rgba16`: 8- and 16-bit truecolor plus unassociated alpha.

The raw files use interleaved GRAY, GRAYA, RGB, or RGBA order. Sixteen-bit
oracles are stored most-significant byte first. The fixture set exercises PNG
filters None, Sub, Up, and Paeth; a private module test constructs all five
filters explicitly, including Average.

All files intentionally omit color-profile and general metadata chunks. Those
remain outside the bounded adapter until their JP2 preservation mapping is
implemented.
