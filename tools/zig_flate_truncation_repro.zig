//! Standalone reproduction of the Zig 0.16 `std.compress.flate.Decompress`
//! input overrun described in docs/toolchain_notes.md. Uses only `std`.
//!
//!     zig run tools/zig_flate_truncation_repro.zig
//!
//! Measured on Zig 0.16.0 (x86_64-windows): Debug panics on the assertion in
//! `std.Io.Reader.toss`, ReleaseSafe panics on an `unreachable` in
//! `Decompress.streamInner`, and ReleaseFast dies with an access violation.
//! A correct decoder returns an error for this input, as Zig 0.17.0 does.

const std = @import("std");

/// The first 11 bytes of a zlib stream Python's `zlib.compress(..., 9)` wrote
/// for 40 random letters. Many valid streams cut short reach the same path;
/// this is the shortest one a search over 40 such streams found.
const truncated = [_]u8{ 0x78, 0xda, 0x0d, 0xc1, 0x81, 0x01, 0x00, 0x30, 0x08, 0xc2, 0xb0 };

pub fn main() void {
    var input: std.Io.Reader = .fixed(&truncated);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    var out: [64]u8 = undefined;
    // Expected: error.EndOfStream or error.ReadFailed with decompress.err set.
    const result = decompress.reader.readSliceShort(&out);
    std.debug.print("result: {any}, input seek {d} of end {d}\n", .{ result, input.seek, input.end });
}
