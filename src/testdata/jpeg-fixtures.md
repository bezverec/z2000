# JPEG adapter fixtures

The `imagemagick-jpeg-*.jpg` files were produced with ImageMagick 7.1.2-10
from one 19x17 synthetic gradient/shape image at quality 92. The matching raw
files are ImageMagick's own 8-bit GRAY or RGB decodes and serve as independent
pixel oracles.

- `gray`: one-component baseline sequential DCT;
- `444`, `422`, `420`: JFIF YCbCr at the named sampling ratio;
- `restart`: 4:2:0 with a DRI interval of one MCU and RST0/RST1/RST2.

The decoder uses a direct floating-point reference IDCT and centered chroma
interpolation. Compared with ImageMagick/libjpeg, the fixture maxima are 1
(gray), 2 (4:4:4), 3 (4:2:2), and 2 (4:2:0/restart) sample values; mean error
is below one sample in every case. The subsequent JP2 encode is reversible, so
z2000, OpenJPEG, and Grok reconstruct that chosen raster exactly.

The fixtures are stripped of EXIF, ICC, and IPTC. Metadata preservation is a
separate planned mapping and metadata-bearing JPEG currently fails closed.
