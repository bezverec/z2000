# ICC Fixtures

The ICC conversion tests use real matrix/TRC profiles and independent
LittleCMS reference vectors.

- `eciRGB_v2.icc` and `eciRGB_v2_ICCv4.icc` are the official ICC v2/v4
  variants from the [European Color Initiative](https://eci.org/lib/exe/ecirgbv20.zip).
  Redistribution terms are in `eciRGB_v2-LICENSE.rtf`.
- `AdobeCompat-v2.icc` and `AdobeCompat-v4.icc` are Adobe RGB
  (1998)-compatible profiles from
  [Compact ICC Profiles](https://github.com/saucecontrol/Compact-ICC-Profiles).
  They are CC0; the license is in `Compact-ICC-Profiles-LICENSE`.

SHA-256:

```text
362761d7c9d7b3ae4323d03cb80993b4eb56b70a6bbdc463fa2f42556b8653b6  eciRGB_v2.icc
4fbf68ac8c8e767d1013294aa811e2b4052f861b87e0f44c2fd51e9653f2bee1  eciRGB_v2_ICCv4.icc
60fb2adecacf82132db0b1c09b303316f3bbd9e2823e7ba096d01627d12d57c9  AdobeCompat-v2.icc
1e35b53d118eba6835a7bac06137ea87cd5ad6eee97b20a88b29ab6356b00e43  AdobeCompat-v4.icc
```

The expected 8/16-bit vectors were generated with ImageMagick 7.1.2 using
LittleCMS, relative-colorimetric intent, and the CC0 `sRGB-v4.icc` target from
the same Compact ICC Profiles collection. Tests allow only the small integer
quantization difference between that reference path and z2000's direct f64
matrix/TRC evaluation.
