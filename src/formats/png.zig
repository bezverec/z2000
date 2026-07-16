const std = @import("std");
const tiff = @import("../tiff.zig");

const signature = [_]u8{ 137, 80, 78, 71, 13, 10, 26, 10 };
const max_file_size: usize = 1024 * 1024 * 1024;
const max_pixels: usize = 268_435_456;

pub const PngError = error{
    InvalidSignature,
    TruncatedChunk,
    InvalidChunkType,
    InvalidChunkCrc,
    InvalidChunkOrder,
    InvalidHeader,
    InvalidDimensions,
    UnsupportedColorType,
    UnsupportedBitDepth,
    UnsupportedCompression,
    UnsupportedFilterMethod,
    UnsupportedInterlace,
    UnsupportedColorProfile,
    UnsupportedAnimation,
    UnknownCriticalChunk,
    InvalidPalette,
    InvalidTransparency,
    MissingImageData,
    InvalidCompressedData,
    InvalidFilter,
    InvalidPaletteIndex,
};

const Header = struct {
    width: usize,
    height: usize,
    bit_depth: u8,
    color_type: u8,

    fn channels(self: Header) usize {
        return switch (self.color_type) {
            0, 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            else => unreachable,
        };
    }
};

pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !tiff.DecodedImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

/// Parses the bounded PNG input profile. All standard color types and legal
/// bit depths are accepted without Adam7 interlace. Critical chunk ordering,
/// every chunk CRC, zlib length/checksum, and all five PNG filters are checked.
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !tiff.DecodedImage {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], &signature)) {
        return PngError.InvalidSignature;
    }

    var header: ?Header = null;
    var palette: ?[]const u8 = null;
    var transparency: ?[]const u8 = null;
    var seen_idat = false;
    var ended_idat = false;
    var seen_iend = false;
    var seen_srgb = false;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(allocator);

    var cursor: usize = signature.len;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 12) return PngError.TruncatedChunk;
        const length_u32 = readU32(bytes, cursor);
        if (length_u32 > std.math.maxInt(i31)) return PngError.TruncatedChunk;
        const length: usize = length_u32;
        const type_start = cursor + 4;
        const data_start = cursor + 8;
        const data_end = std.math.add(usize, data_start, length) catch return PngError.TruncatedChunk;
        const chunk_end = std.math.add(usize, data_end, 4) catch return PngError.TruncatedChunk;
        if (chunk_end > bytes.len) return PngError.TruncatedChunk;
        const chunk_type = bytes[type_start .. type_start + 4];
        if (!validChunkType(chunk_type)) return PngError.InvalidChunkType;
        const data = bytes[data_start..data_end];
        if (std.hash.Crc32.hash(bytes[type_start..data_end]) != readU32(bytes, data_end)) {
            return PngError.InvalidChunkCrc;
        }

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (header != null or cursor != signature.len) return PngError.InvalidChunkOrder;
            header = try parseHeader(data);
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            const h = header orelse return PngError.InvalidChunkOrder;
            if (palette != null or transparency != null or seen_idat) return PngError.InvalidChunkOrder;
            if (h.color_type == 0 or h.color_type == 4) return PngError.InvalidPalette;
            if (data.len == 0 or data.len > 768 or data.len % 3 != 0) return PngError.InvalidPalette;
            if (h.color_type == 3 and data.len / 3 > (@as(usize, 1) << @intCast(h.bit_depth))) {
                return PngError.InvalidPalette;
            }
            palette = data;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            if (header == null or ended_idat or seen_iend) return PngError.InvalidChunkOrder;
            seen_idat = true;
            try idat.appendSlice(allocator, data);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            if (header == null or !seen_idat or seen_iend or data.len != 0) return PngError.InvalidChunkOrder;
            seen_iend = true;
            cursor = chunk_end;
            if (cursor != bytes.len) return PngError.InvalidChunkOrder;
            break;
        } else {
            if (seen_idat) ended_idat = true;
            if (std.mem.eql(u8, chunk_type, "tRNS")) {
                const h = header orelse return PngError.InvalidChunkOrder;
                if (transparency != null or seen_idat) return PngError.InvalidChunkOrder;
                try validateTransparency(h, palette, data);
                transparency = data;
            } else if (std.mem.eql(u8, chunk_type, "sRGB")) {
                if (header == null or palette != null or transparency != null or seen_idat or
                    seen_srgb or data.len != 1 or data[0] > 3)
                {
                    return PngError.InvalidChunkOrder;
                }
                seen_srgb = true;
            } else if (std.mem.eql(u8, chunk_type, "iCCP") or
                std.mem.eql(u8, chunk_type, "cICP") or
                std.mem.eql(u8, chunk_type, "cHRM") or
                std.mem.eql(u8, chunk_type, "gAMA"))
            {
                return PngError.UnsupportedColorProfile;
            } else if (std.mem.eql(u8, chunk_type, "acTL") or
                std.mem.eql(u8, chunk_type, "fcTL") or
                std.mem.eql(u8, chunk_type, "fdAT"))
            {
                return PngError.UnsupportedAnimation;
            } else if (chunk_type[0] & 0x20 == 0) {
                return PngError.UnknownCriticalChunk;
            }
        }
        cursor = chunk_end;
    }

    const h = header orelse return PngError.InvalidHeader;
    if (!seen_iend or !seen_idat or idat.items.len == 0) return PngError.MissingImageData;
    if (h.color_type == 3 and palette == null) return PngError.InvalidPalette;
    return decodeImage(allocator, h, palette, transparency, idat.items);
}

fn parseHeader(data: []const u8) !Header {
    if (data.len != 13) return PngError.InvalidHeader;
    const width_u32 = readU32(data, 0);
    const height_u32 = readU32(data, 4);
    if (width_u32 == 0 or height_u32 == 0 or
        width_u32 > std.math.maxInt(i31) or height_u32 > std.math.maxInt(i31))
    {
        return PngError.InvalidDimensions;
    }
    const color_type = data[9];
    const bit_depth = data[8];
    const valid_depth = switch (color_type) {
        0 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8 or bit_depth == 16,
        2, 4, 6 => bit_depth == 8 or bit_depth == 16,
        3 => bit_depth == 1 or bit_depth == 2 or bit_depth == 4 or bit_depth == 8,
        else => return PngError.UnsupportedColorType,
    };
    if (!valid_depth) return PngError.UnsupportedBitDepth;
    if (data[10] != 0) return PngError.UnsupportedCompression;
    if (data[11] != 0) return PngError.UnsupportedFilterMethod;
    if (data[12] != 0) return PngError.UnsupportedInterlace;

    const width: usize = width_u32;
    const height: usize = height_u32;
    const pixels = std.math.mul(usize, width, height) catch return PngError.InvalidDimensions;
    if (pixels > max_pixels) return PngError.InvalidDimensions;
    return .{ .width = width, .height = height, .bit_depth = bit_depth, .color_type = color_type };
}

fn validateTransparency(header: Header, palette: ?[]const u8, data: []const u8) !void {
    switch (header.color_type) {
        0 => {
            if (data.len != 2) return PngError.InvalidTransparency;
            const max_sample: u16 = if (header.bit_depth == 16)
                std.math.maxInt(u16)
            else
                (@as(u16, 1) << @intCast(header.bit_depth)) - 1;
            if (readU16(data, 0) > max_sample) return PngError.InvalidTransparency;
        },
        2 => {
            if (data.len != 6) return PngError.InvalidTransparency;
            const max_sample: u16 = if (header.bit_depth == 16) std.math.maxInt(u16) else 255;
            if (readU16(data, 0) > max_sample or readU16(data, 2) > max_sample or
                readU16(data, 4) > max_sample) return PngError.InvalidTransparency;
        },
        3 => {
            const entries = if (palette) |value| value.len / 3 else return PngError.InvalidChunkOrder;
            if (data.len == 0 or data.len > entries) return PngError.InvalidTransparency;
        },
        4, 6 => return PngError.InvalidTransparency,
        else => unreachable,
    }
}

fn decodeImage(
    allocator: std.mem.Allocator,
    header: Header,
    palette: ?[]const u8,
    transparency: ?[]const u8,
    compressed: []const u8,
) !tiff.DecodedImage {
    const bits_per_pixel = std.math.mul(usize, header.channels(), header.bit_depth) catch
        return PngError.InvalidDimensions;
    const row_bits = std.math.mul(usize, header.width, bits_per_pixel) catch
        return PngError.InvalidDimensions;
    const row_bytes = std.math.add(usize, row_bits, 7) catch return PngError.InvalidDimensions;
    const packed_row_bytes = row_bytes / 8;
    const filtered_row_bytes = std.math.add(usize, packed_row_bytes, 1) catch
        return PngError.InvalidDimensions;
    const filtered_len = std.math.mul(usize, filtered_row_bytes, header.height) catch
        return PngError.InvalidDimensions;
    const raw_len = std.math.mul(usize, packed_row_bytes, header.height) catch
        return PngError.InvalidDimensions;

    const filtered = try allocator.alloc(u8, filtered_len);
    defer allocator.free(filtered);
    var input: std.Io.Reader = .fixed(compressed);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    decompress.reader.readSliceAll(filtered) catch return PngError.InvalidCompressedData;
    var extra: [1]u8 = undefined;
    const extra_len = decompress.reader.readSliceShort(&extra) catch return PngError.InvalidCompressedData;
    if (extra_len != 0 or decompress.err != null) return PngError.InvalidCompressedData;
    if ((input.readSliceShort(&extra) catch return PngError.InvalidCompressedData) != 0) {
        return PngError.InvalidCompressedData;
    }

    const raw = try allocator.alloc(u8, raw_len);
    defer allocator.free(raw);
    const bytes_per_pixel = @max(@as(usize, 1), (bits_per_pixel + 7) / 8);
    try unfilter(raw, filtered, packed_row_bytes, header.height, bytes_per_pixel);
    return expandSamples(allocator, header, palette, transparency, raw, packed_row_bytes);
}

fn unfilter(raw: []u8, filtered: []const u8, row_bytes: usize, height: usize, bpp: usize) !void {
    for (0..height) |y| {
        const source = filtered[y * (row_bytes + 1) ..][0 .. row_bytes + 1];
        const target = raw[y * row_bytes ..][0..row_bytes];
        const prior = if (y == 0) null else raw[(y - 1) * row_bytes ..][0..row_bytes];
        for (target, source[1..], 0..) |*out, value, x| {
            const left: u8 = if (x >= bpp) target[x - bpp] else 0;
            const up: u8 = if (prior) |row| row[x] else 0;
            const upper_left: u8 = if (prior != null and x >= bpp) prior.?[x - bpp] else 0;
            out.* = switch (source[0]) {
                0 => value,
                1 => value +% left,
                2 => value +% up,
                3 => value +% @as(u8, @intCast((@as(u16, left) + up) / 2)),
                4 => value +% paeth(left, up, upper_left),
                else => return PngError.InvalidFilter,
            };
        }
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const ai: i32 = a;
    const bi: i32 = b;
    const ci: i32 = c;
    const p = ai + bi - ci;
    const pa = @abs(p - ai);
    const pb = @abs(p - bi);
    const pc = @abs(p - ci);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn expandSamples(
    allocator: std.mem.Allocator,
    header: Header,
    palette: ?[]const u8,
    transparency: ?[]const u8,
    raw: []const u8,
    row_bytes: usize,
) !tiff.DecodedImage {
    const pixels = try std.math.mul(usize, header.width, header.height);
    const output_depth: u8 = if (header.bit_depth < 8 or header.color_type == 3) 8 else header.bit_depth;
    const has_alpha = header.color_type == 4 or header.color_type == 6 or transparency != null;
    const color_components: usize = if (header.color_type == 0 or header.color_type == 4) 1 else 3;
    const output_components = color_components + @intFromBool(has_alpha);
    const samples = try allocator.alloc(u16, try std.math.mul(usize, pixels, output_components));
    errdefer allocator.free(samples);
    const max_output: u16 = if (output_depth == 8) 255 else std.math.maxInt(u16);

    for (0..header.height) |y| {
        const row = raw[y * row_bytes ..][0..row_bytes];
        for (0..header.width) |x| {
            const pixel = y * header.width + x;
            const target = pixel * output_components;
            switch (header.color_type) {
                0 => {
                    const original = readSingleSample(row, x, header.bit_depth);
                    samples[target] = scaleSample(original, header.bit_depth);
                    if (has_alpha) {
                        const transparent = readU16(transparency.?, 0);
                        samples[target + 1] = if (original == transparent) 0 else max_output;
                    }
                },
                2 => {
                    const source = x * 3 * (header.bit_depth / 8);
                    var original: [3]u16 = undefined;
                    for (0..3) |component| {
                        original[component] = readByteSample(row, source, component, header.bit_depth);
                        samples[target + component] = original[component];
                    }
                    if (has_alpha) {
                        const trns = transparency.?;
                        samples[target + 3] = if (original[0] == readU16(trns, 0) and
                            original[1] == readU16(trns, 2) and original[2] == readU16(trns, 4)) 0 else max_output;
                    }
                },
                3 => {
                    const index = readSingleSample(row, x, header.bit_depth);
                    const table = palette.?;
                    if (index >= table.len / 3) return PngError.InvalidPaletteIndex;
                    samples[target] = table[index * 3];
                    samples[target + 1] = table[index * 3 + 1];
                    samples[target + 2] = table[index * 3 + 2];
                    if (has_alpha) samples[target + 3] = if (index < transparency.?.len) transparency.?[index] else 255;
                },
                4 => {
                    const source = x * 2 * (header.bit_depth / 8);
                    samples[target] = readByteSample(row, source, 0, header.bit_depth);
                    samples[target + 1] = readByteSample(row, source, 1, header.bit_depth);
                },
                6 => {
                    const source = x * 4 * (header.bit_depth / 8);
                    for (0..4) |component| {
                        samples[target + component] = readByteSample(row, source, component, header.bit_depth);
                    }
                },
                else => unreachable,
            }
        }
    }

    if (has_alpha) {
        return .{ .alpha = .{
            .allocator = allocator,
            .width = header.width,
            .height = header.height,
            .bit_depth = output_depth,
            .color_space = if (color_components == 1) .grayscale else .rgb,
            .alpha_mode = .unassociated,
            .samples = samples,
        } };
    }
    if (color_components == 1) {
        return .{ .grayscale = .{
            .allocator = allocator,
            .width = header.width,
            .height = header.height,
            .bit_depth = output_depth,
            .samples = samples,
        } };
    }
    return .{ .rgb = .{
        .allocator = allocator,
        .width = header.width,
        .height = header.height,
        .bit_depth = output_depth,
        .samples = samples,
    } };
}

fn readSingleSample(row: []const u8, index: usize, bit_depth: u8) u16 {
    if (bit_depth == 8) return row[index];
    if (bit_depth == 16) return readU16(row, index * 2);
    const samples_per_byte = 8 / bit_depth;
    const shift: u3 = @intCast(8 - bit_depth - (index % samples_per_byte) * bit_depth);
    return (row[index / samples_per_byte] >> shift) & ((@as(u8, 1) << @intCast(bit_depth)) - 1);
}

fn readByteSample(row: []const u8, pixel_offset: usize, component: usize, bit_depth: u8) u16 {
    if (bit_depth == 8) return row[pixel_offset + component];
    return readU16(row, pixel_offset + component * 2);
}

fn scaleSample(sample: u16, bit_depth: u8) u16 {
    if (bit_depth >= 8) return sample;
    const max_source: u16 = (@as(u16, 1) << @intCast(bit_depth)) - 1;
    return (sample * 255) / max_source;
}

fn validChunkType(chunk_type: []const u8) bool {
    if (chunk_type.len != 4) return false;
    for (chunk_type) |byte| {
        if (!std.ascii.isAlphabetic(byte)) return false;
    }
    return chunk_type[2] & 0x20 == 0;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}

test "all five PNG scanline filters reconstruct byte-exactly" {
    const expected = [_]u8{
        10, 20, 30, 40, 50, 60,
        15, 25, 35, 45, 55, 65,
    };
    const previous = expected[0..6];
    const current = expected[6..12];
    var filtered: [14]u8 = undefined;
    var raw: [12]u8 = undefined;

    for (0..5) |filter| {
        filtered[0] = 0;
        @memcpy(filtered[1..7], previous);
        filtered[7] = @intCast(filter);
        for (current, 0..) |value, x| {
            const left: u8 = if (x >= 3) current[x - 3] else 0;
            const up = previous[x];
            const upper_left: u8 = if (x >= 3) previous[x - 3] else 0;
            const predictor: u8 = switch (filter) {
                0 => 0,
                1 => left,
                2 => up,
                3 => @intCast((@as(u16, left) + up) / 2),
                4 => paeth(left, up, upper_left),
                else => unreachable,
            };
            filtered[8 + x] = value -% predictor;
        }
        try unfilter(&raw, &filtered, 6, 2, 3);
        try std.testing.expectEqualSlices(u8, &expected, &raw);
    }
}

test "PNG unfilter rejects reserved filter type" {
    var raw: [1]u8 = undefined;
    try std.testing.expectError(PngError.InvalidFilter, unfilter(&raw, &.{ 5, 0 }, 1, 1, 1));
}

test "PNG packed sample extraction is MSB-first for 1 2 and 4 bits" {
    const one = [_]u8{0b10110010};
    try std.testing.expectEqual(@as(u16, 1), readSingleSample(&one, 0, 1));
    try std.testing.expectEqual(@as(u16, 0), readSingleSample(&one, 1, 1));
    try std.testing.expectEqual(@as(u16, 2), readSingleSample(&one, 0, 2));
    try std.testing.expectEqual(@as(u16, 3), readSingleSample(&one, 1, 2));
    try std.testing.expectEqual(@as(u16, 11), readSingleSample(&one, 0, 4));
    try std.testing.expectEqual(@as(u16, 2), readSingleSample(&one, 1, 4));
}
