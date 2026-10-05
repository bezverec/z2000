# Toolchain Notes

Defects in the Zig compiler or standard library that z2000 works around,
and what changed when the pinned Zig version moved. Each defect entry
records how it shows, why it happens, what z2000 does about it, and how to
tell when the workaround can go. Recheck every entry when the pinned Zig
version changes.

## Moving From Zig 0.16 To 0.17

z2000 builds with Zig 0.17.0 only; the release workflows pin it with the
checksums from ziglang.org's `download/index.json`. What had to change:

- **Build script.** The build runs in a configure phase whose result Zig
  caches, then a make phase. `b.args` is gone; run steps take the
  arguments after `--` with `addPassthruArgs()`. `b.build_root` became
  `b.root` (a `Cache.Path`) and `b.pathFromRoot` went with it;
  `runAllowFail` is deprecated in favour of `runFallible`. Reading
  `VERSION` is declared with `dependOnFileContents`, so editing it re-runs
  configure. The Git revision, commit count, and dirty state cannot be
  watched as files, so querying Git calls `graph.poisonCache()`, which
  re-runs configure on every build; without it a cached configuration
  would embed a stale version.
- **Array repetition.** `[_]T{x} ** n` and `.{x} ** n` no longer parse.
  All 181 uses became `@splat(x)` with the array type in the declaration,
  or `@as([n]T, @splat(x))` where the context does not name it.
- **Type information.** `@typeInfo(E).@"enum".fields` is now
  `field_names` (and `field_values`).
- **Optimize modes.** `builtin.mode` is `.debug`, `.safe`, `.fast`, or
  `.small`. The `-Doptimize` option lists those names but still accepts
  `ReleaseFast` and the other old spellings, so scripts did not change.
- **Enum casts.** `@intFromEnum` and `@enumFromInt` are deprecated for
  `@backingInt` and `@fromBackingInt`; `zig fmt` rewrites them (adding an
  `@intCast` where the integer type differs), and the tree was formatted
  with 0.17.

Measured after the move: Debug and ReleaseFast tests (607 each) and the
Part 1 corpus pass; x86_64-linux-musl, riscv64-linux-musl, and
aarch64-macos cross-builds succeed; and every output compared between
0.16 and 0.17 builds is byte-identical (lossless and 9/7 TIFF, RGBA, PNG,
JPEG, JPEG-TIFF, multi-page TIFF, and two decodes), with encode and decode
times within 2%.

## Truncated zlib Input Overruns `std.compress.flate.Decompress` (Zig 0.16.0)

**Status:** fixed upstream in Zig 0.17.0, whose `tossBitsShort` subtracts
the consumed bits. With 0.17.0 the reproduction returns an error in Debug
and ReleaseFast, and every truncation of a 1423-byte zlib stream, plus the
14-byte `integer overflow` case below, ends in an error in Debug and
ReleaseSafe. The workaround in `src/zlib_inflate.zig` is still in place: it
costs nothing measurable and keeps a truncated stream from being read past
its end should a similar defect return. It can now be removed (see the
last section).

### Symptom

Decompressing a zlib or raw Deflate stream that ends early, through a
`std.Io.Reader.fixed` input, does not return `error.EndOfStream`. It moves
the reader past the end of its buffer instead. What happens next depends on
the build mode (measured with the 11-byte stream in the reproduction, Zig
0.16.0, x86_64-windows):

| Build mode | Result |
|---|---|
| Debug | panic: `reached unreachable code`, the `assert(r.seek <= r.end)` in `std.Io.Reader.toss` |
| ReleaseSafe | panic: `reached unreachable code` in `Decompress.streamInner` |
| ReleaseFast | access violation (reads outside the input buffer) |

Other truncations panic with `integer overflow` in `peekBitsEnding` instead
(for example the 14-byte prefix `78da1d8e81090051084267d5d4ef`): the
miscounted toss leaves no byte buffered while `consumed_bits` is still
nonzero, and `left.len * 8 - d.consumed_bits` underflows.

Reproduce with:

```sh
zig run tools/zig_flate_truncation_repro.zig
```

A correct decoder reports an error for that input.

### Cause

`lib/std/compress/flate/Decompress.zig`:

```zig
fn tossBitsShort(d: *Decompress, n: u4) !void {
    if (d.input.bufferedLen() * 8 + d.consumed_bits < n) return error.EndOfStream;
    d.tossBits(n);
}
```

`consumed_bits` counts bits of the current byte that were already used, so
the bits still available are `bufferedLen() * 8 - consumed_bits`. The check
adds them instead. Near the end of the input it lets through a Huffman code
longer than what is left, and `tossBits` then tosses more bytes than are
buffered. The subtraction is what `peekBitsEnding` in the same file already
does.

### Where it reached z2000

- **PNG input.** A PNG whose IDAT is cut short but carries a valid chunk CRC
  panicked `png-to-jp2`. The PNG truncation sweep never reached it: cutting
  the file breaks a CRC before inflate runs, so only a crafted or damaged
  file with a recomputed CRC gets there.
- **TIFF Deflate strips** (compression 8 and 32946). The first fuzz run over
  the new decoder found it within 1350 mutated files.

### Workaround

`src/zlib_inflate.zig` feeds the decompressor through its own reader. After
the real input, that reader supplies zeros and never reports the end of the
stream, so every toss stays inside buffered data. Once decoding is done, any
stream that consumed even one bit of the zero tail is rejected as
truncated. The zeros cannot run away: decoding stops after the requested
output plus one byte, and zeros in a block header decode as a stored block
whose `NLEN` does not complement `LEN`.

PNG and TIFF Deflate both use `inflateExact`. Nothing else in z2000 calls
`std.compress.flate`; any new caller should use `zlib_inflate` too.

Cost: none measurable. PNG read time on a 24 MP image is unchanged, and the
output is byte-identical.

### Regression Coverage

The test `truncated zlib streams fail closed in PNG and TIFF` cuts a
1458-byte IDAT (`python-zlib-png-gray8-long-idat.png`) and a Pillow Deflate
TIFF strip at every length and expects `InvalidCompressedData`. With the
workaround removed, the PNG half panics.

### When To Remove The Workaround

After a Zig upgrade, run the reproduction in Debug and ReleaseFast. If both
return an error instead of crashing, `inflateExact` may go back to a plain
`std.Io.Reader.fixed` input. Keep the regression test either way.
