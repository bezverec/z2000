# BMP adapter fixtures

`imagemagick-bmp24-3x2.bmp` was produced with ImageMagick 7.1.2-10 as a
Windows BMP3/24-bit image. Its six pixels, in display order, are red, green,
blue, yellow, cyan, and magenta. `imagemagick-bmp24-3x2.raw` is ImageMagick's
8-bit interleaved RGB decode of the same file and is the independent pixel
oracle used by the unit test.

Reproduction:

```powershell
magick -size 3x2 xc:black `
  -fill '#ff0000' -draw 'point 0,0' `
  -fill '#00ff00' -draw 'point 1,0' `
  -fill '#0000ff' -draw 'point 2,0' `
  -fill '#ffff00' -draw 'point 0,1' `
  -fill '#00ffff' -draw 'point 1,1' `
  -fill '#ff00ff' -draw 'point 2,1' `
  -type TrueColor BMP3:imagemagick-bmp24-3x2.bmp
magick imagemagick-bmp24-3x2.bmp -depth 8 RGB:imagemagick-bmp24-3x2.raw
```
