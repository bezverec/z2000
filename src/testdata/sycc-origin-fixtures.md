# Odd-Origin sYCC Fixture Provenance

`kakadu-sycc420-origin.jp2` is the existing independently produced Kakadu
8.4.1 native 4:2:0 fixture `kakadu-rpcl-420-origin-multi-precinct-pltless.jp2`
with only the JP2 `colr` enumerated colour-space value changed from sRGB (16)
to sYCC (18). Its codestream is unchanged and has `XOsiz=5`, `YOsiz=3`, a
32x32 luma plane, and 16x16 chroma planes.

`openjpeg-sycc420-origin.tif` was produced from that JP2 with the official
OpenJPEG 2.5.4 Windows x64 `opj_decompress` binary. It pins the decoder's
odd-origin 4:2:0 edge phase as the independent RGB reference used by the test
suite. Grok 20.3.4 writes the fixture as YCbCr rather than converting it to
RGB, so it is not used as a second RGB reference for this edge case.

SHA-256:

- `kakadu-sycc420-origin.jp2`:
  `3bd24ce448b7a12a3913a1ad300dff81bd01515c4fbef61039aee7accd0cd37e`
- `openjpeg-sycc420-origin.tif`:
  `4d2206642c56dc9a72a41a4b9ba58f6daa97747f99fa8c39887c8c271ba33925`
