# Toolchain Notes

Defects in the Zig compiler or standard library that z2000 works around.
Each entry records how the defect shows, why it happens, what z2000 does
about it, and how to tell when the workaround can go. Recheck every entry
when the pinned Zig version changes.

## Truncated zlib Input Overruns `std.compress.flate.Decompress` (Zig 0.16.0)

**Status:** worked around in `src/zlib_inflate.zig`. Not yet reported
upstream; `tools/zig_flate_truncation_repro.zig` is a self-contained
reproduction to attach to a report.

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
