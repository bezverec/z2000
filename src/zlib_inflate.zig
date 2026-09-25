//! Bounded zlib inflate for PNG IDAT and TIFF Deflate strips.
//!
//! Zig 0.16's `std.compress.flate.Decompress` can step past the end of its
//! input on a truncated or corrupted stream: `tossBitsShort` checks
//! `bufferedLen() * 8 + consumed_bits < n` where the bits already consumed
//! should be subtracted, so a Huffman code that runs off the end tosses more
//! than is buffered. On a fixed reader that trips `Reader.toss`'s assertion
//! in safe builds and reads past the buffer in ReleaseFast.
//!
//! The decompressor here reads the input through a reader that never ends:
//! after the real bytes it supplies zeros, so every toss stays inside
//! buffered data. Whatever the decompressor then does with the zeros, it
//! stops within the requested output plus one byte, and any stream that
//! consumed even one bit of the zero tail is rejected as truncated.

const std = @import("std");

pub const Error = error{InvalidCompressedData};

const input_buffer_len = 16 * 1024;

const ZeroTailReader = struct {
    source: []const u8,
    delivered_source: usize = 0,
    delivered_zeros: usize = 0,
    reader: std.Io.Reader,

    const vtable: std.Io.Reader.VTable = .{
        .stream = stream,
        .readVec = readVec,
    };

    fn init(source: []const u8, buffer: []u8) ZeroTailReader {
        return .{
            .source = source,
            .reader = .{ .vtable = &vtable, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    /// Bytes the consumer has moved past, real or zero.
    fn consumed(self: *const ZeroTailReader) usize {
        return self.delivered_source + self.delivered_zeros - (self.reader.end - self.reader.seek);
    }

    fn fill(r: *std.Io.Reader) void {
        const self: *ZeroTailReader = @alignCast(@fieldParentPtr("reader", r));
        if (r.end == r.buffer.len) {
            if (r.seek == 0) return;
            const unread = r.end - r.seek;
            std.mem.copyForwards(u8, r.buffer[0..unread], r.buffer[r.seek..r.end]);
            r.seek = 0;
            r.end = unread;
        }
        const free = r.buffer[r.end..];
        const take = @min(free.len, self.source.len - self.delivered_source);
        @memcpy(free[0..take], self.source[self.delivered_source..][0..take]);
        @memset(free[take..], 0);
        self.delivered_source += take;
        self.delivered_zeros += free.len - take;
        r.end = r.buffer.len;
    }

    // Both entry points store into `buffer` and report zero bytes written,
    // which the Reader interface allows; the stream never signals its end.
    fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        _ = w;
        _ = limit;
        fill(r);
        return 0;
    }

    fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        _ = data;
        fill(r);
        return 0;
    }
};

/// Inflates one zlib stream into exactly `out` and checks its Adler-32.
/// Returns how many input bytes the stream occupied, so a caller can reject
/// trailing data; the stream itself must end within `input`.
pub fn inflateExact(input: []const u8, out: []u8) Error!usize {
    var input_buffer: [input_buffer_len]u8 = undefined;
    var source = ZeroTailReader.init(input, &input_buffer);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&source.reader, .zlib, &window);

    const complete = blk: {
        decompress.reader.readSliceAll(out) catch break :blk false;
        var extra: [1]u8 = undefined;
        const extra_len = decompress.reader.readSliceShort(&extra) catch break :blk false;
        break :blk extra_len == 0 and decompress.err == null;
    };
    const used = source.consumed();
    if (!complete or used > input.len or (used == input.len and decompress.consumed_bits != 0)) {
        return Error.InvalidCompressedData;
    }
    return used;
}
