//! Strip decompressors for TIFF input: LZW (TIFF 6.0 section 13), Adobe
//! Deflate (zlib streams, compression 8 and 32946), and PackBits (section 9),
//! plus horizontal-differencing predictor reversal (section 14). Each
//! decoder fills exactly one strip buffer; a stream that ends short of it,
//! runs past it, or is malformed fails closed.

const std = @import("std");
const zlib_inflate = @import("zlib_inflate.zig");

pub const Error = error{InvalidCompressedData};

pub const Compression = enum(u16) {
    none = 1,
    lzw = 5,
    deflate = 8,
    packbits = 32773,
    adobe_deflate = 32946,

    pub fn fromTag(value: u16) ?Compression {
        return switch (value) {
            1 => .none,
            5 => .lzw,
            8 => .deflate,
            32773 => .packbits,
            32946 => .adobe_deflate,
            else => null,
        };
    }

    /// libtiff applies the Predictor tag only through the LZW and Deflate
    /// codecs; an uncompressed or PackBits strip is stored as is.
    pub fn usesPredictor(self: Compression) bool {
        return self == .lzw or self == .deflate or self == .adobe_deflate;
    }
};

pub fn decompressStrip(compression: Compression, input: []const u8, out: []u8) Error!void {
    switch (compression) {
        .none => {
            if (input.len != out.len) return Error.InvalidCompressedData;
            @memcpy(out, input);
        },
        .lzw => try decodeLzw(input, out),
        .deflate, .adobe_deflate => try inflateZlib(input, out),
        .packbits => try decodePackBits(input, out),
    }
}

const lzw_clear: u16 = 256;
const lzw_end: u16 = 257;
const lzw_first_free: u16 = 258;
const lzw_table_size = 4096;

/// TIFF LZW: MSB-first codes from 9 to 12 bits, Clear 256, EndOfInformation
/// 257, and the code width growing one code early (when the next free entry
/// reaches 2^width - 1), as libtiff reads and writes it. The pre-6.0
/// LSB-first variant starts with bytes 00 01 instead of a Clear code in the
/// high bits, so it fails the first-code check.
pub fn decodeLzw(input: []const u8, out: []u8) Error!void {
    var prefix: [lzw_table_size]u16 = undefined;
    var suffix: [lzw_table_size]u8 = undefined;
    var length: [lzw_table_size]u16 = undefined;
    for (0..256) |code| {
        suffix[code] = @intCast(code);
        length[code] = 1;
        prefix[code] = 0;
    }

    var bit_buffer: u32 = 0;
    var bit_count: u5 = 0;
    var cursor: usize = 0;
    var width: u5 = 9;
    var next_free: u16 = lzw_first_free;
    var previous: ?u16 = null;
    var written: usize = 0;
    var first_code = true;

    while (true) {
        while (bit_count < width) {
            if (cursor == input.len) {
                // libtiff tolerates a stream that stops without EOI once
                // the strip is complete.
                if (written == out.len) return;
                return Error.InvalidCompressedData;
            }
            bit_buffer = (bit_buffer << 8) | input[cursor];
            cursor += 1;
            bit_count += 8;
        }
        bit_count -= width;
        const code: u16 = @intCast((bit_buffer >> bit_count) & ((@as(u32, 1) << width) - 1));
        bit_buffer &= (@as(u32, 1) << bit_count) - 1;

        if (first_code and code != lzw_clear) return Error.InvalidCompressedData;
        first_code = false;
        if (code == lzw_end) break;
        if (code == lzw_clear) {
            width = 9;
            next_free = lzw_first_free;
            previous = null;
            continue;
        }

        const prior = previous orelse {
            if (code >= 256) return Error.InvalidCompressedData;
            if (written == out.len) return Error.InvalidCompressedData;
            out[written] = @intCast(code);
            written += 1;
            previous = code;
            continue;
        };

        var first_byte: u8 = undefined;
        if (code < next_free) {
            first_byte = try emitLzwString(code, &prefix, &suffix, &length, out, &written);
        } else if (code == next_free) {
            // KwKwK: the new string is the previous one plus its own first
            // byte.
            const prior_first = try emitLzwString(prior, &prefix, &suffix, &length, out, &written);
            if (written == out.len) return Error.InvalidCompressedData;
            out[written] = prior_first;
            written += 1;
            first_byte = prior_first;
        } else {
            return Error.InvalidCompressedData;
        }

        if (next_free >= lzw_table_size) return Error.InvalidCompressedData;
        prefix[next_free] = prior;
        suffix[next_free] = first_byte;
        length[next_free] = length[prior] + 1;
        next_free += 1;
        if (next_free >= (@as(u32, 1) << width) - 1 and width < 12) width += 1;
        previous = code;
    }
    if (written != out.len) return Error.InvalidCompressedData;
}

fn emitLzwString(
    code: u16,
    prefix: *const [lzw_table_size]u16,
    suffix: *const [lzw_table_size]u8,
    length: *const [lzw_table_size]u16,
    out: []u8,
    written: *usize,
) Error!u8 {
    const string_length: usize = length[code];
    if (out.len - written.* < string_length) return Error.InvalidCompressedData;
    var index = written.* + string_length;
    var current = code;
    while (true) {
        index -= 1;
        out[index] = suffix[current];
        if (current < 256) break;
        current = prefix[current];
    }
    std.debug.assert(index == written.*);
    written.* += string_length;
    return out[index];
}

/// Bytes after the zlib stream inside the strip are ignored, as libtiff
/// ignores them.
fn inflateZlib(input: []const u8, out: []u8) Error!void {
    _ = zlib_inflate.inflateExact(input, out) catch return Error.InvalidCompressedData;
}

/// PackBits: a header byte n in 0..127 copies n + 1 literal bytes, -127..-1
/// repeats the next byte 1 - n times, and -128 is a no-op.
pub fn decodePackBits(input: []const u8, out: []u8) Error!void {
    var cursor: usize = 0;
    var written: usize = 0;
    while (written < out.len) {
        if (cursor == input.len) return Error.InvalidCompressedData;
        const header: i8 = @bitCast(input[cursor]);
        cursor += 1;
        if (header >= 0) {
            const count: usize = @as(usize, @intCast(header)) + 1;
            if (input.len - cursor < count or out.len - written < count) return Error.InvalidCompressedData;
            @memcpy(out[written..][0..count], input[cursor..][0..count]);
            cursor += count;
            written += count;
        } else if (header != -128) {
            const count: usize = @as(usize, @intCast(-@as(i16, header))) + 1;
            if (cursor == input.len or out.len - written < count) return Error.InvalidCompressedData;
            @memset(out[written..][0..count], input[cursor]);
            cursor += 1;
            written += count;
        }
    }
}

/// Reverses Predictor 2 over whole rows of `raster`: every sample adds the
/// same component of the previous pixel, modulo 2^bits. 16-bit samples are
/// read and written in the file's byte order.
pub fn undoHorizontalDifferencing(
    raster: []u8,
    row_bytes: usize,
    samples_per_pixel: usize,
    bit_depth: u8,
    big_endian: bool,
) void {
    std.debug.assert(bit_depth == 8 or bit_depth == 16);
    std.debug.assert(row_bytes != 0 and raster.len % row_bytes == 0);
    var row_start: usize = 0;
    while (row_start < raster.len) : (row_start += row_bytes) {
        const row = raster[row_start..][0..row_bytes];
        if (bit_depth == 8) {
            for (samples_per_pixel..row.len) |index| row[index] +%= row[index - samples_per_pixel];
        } else {
            const endian: std.builtin.Endian = if (big_endian) .big else .little;
            const stride = samples_per_pixel * 2;
            var index = stride;
            while (index + 2 <= row.len) : (index += 2) {
                const left = std.mem.readInt(u16, row[index - stride ..][0..2], endian);
                const delta = std.mem.readInt(u16, row[index..][0..2], endian);
                std.mem.writeInt(u16, row[index..][0..2], left +% delta, endian);
            }
        }
    }
}
