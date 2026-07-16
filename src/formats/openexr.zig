const std = @import("std");
const icc = @import("../icc.zig");
const image = @import("../image.zig");

pub const OpenExrError = error{
    InvalidHeader,
    InvalidRaster,
    SampleOutOfRange,
    TruncatedData,
    UnsupportedOpenExr,
};

const magic: u32 = 20_000_630;
const max_file_size = 1024 * 1024 * 1024;
const required_attribute_count = 9;

const Box2i = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,

    fn eql(a: Box2i, b: Box2i) bool {
        return a.min_x == b.min_x and a.min_y == b.min_y and
            a.max_x == b.max_x and a.max_y == b.max_y;
    }
};

const Chromaticities = struct {
    red: [2]f64,
    green: [2]f64,
    blue: [2]f64,
    white: [2]f64,
};

const Header = struct {
    data_window: Box2i,
    line_order: u8,
    chromaticities: Chromaticities,
    raster_offset: usize,
};

const Span = struct {
    start: usize,
    end: usize,
};

/// Reads the bounded normalized-linear OpenEXR profile documented in
/// `docs/api.md`: single-part, uncompressed scan lines, exactly HALF B/G/R
/// storage channels at full sampling, explicit chromaticities, and samples in
/// the finite [0, 1] range. HDR/negative values fail closed because the current
/// owned image carrier is unsigned 16-bit.
pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !image.RgbImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !image.RgbImage {
    const header = try parseHeader(bytes);
    const width_i64 = @as(i64, header.data_window.max_x) - header.data_window.min_x + 1;
    const height_i64 = @as(i64, header.data_window.max_y) - header.data_window.min_y + 1;
    if (width_i64 <= 0 or height_i64 <= 0) return OpenExrError.InvalidHeader;
    const width: usize = @intCast(width_i64);
    const height: usize = @intCast(height_i64);
    const pixel_count = std.math.mul(usize, width, height) catch
        return OpenExrError.InvalidRaster;
    const sample_count = std.math.mul(usize, pixel_count, 3) catch
        return OpenExrError.InvalidRaster;
    const row_bytes = std.math.mul(usize, width, 6) catch
        return OpenExrError.InvalidRaster;
    const table_bytes = std.math.mul(usize, height, 8) catch
        return OpenExrError.InvalidRaster;
    if (header.raster_offset > bytes.len or bytes.len - header.raster_offset < table_bytes) {
        return OpenExrError.TruncatedData;
    }
    const chunk_bytes = std.math.add(usize, 8, row_bytes) catch
        return OpenExrError.InvalidRaster;
    const all_chunk_bytes = std.math.mul(usize, height, chunk_bytes) catch
        return OpenExrError.InvalidRaster;
    const expected_remaining = std.math.add(usize, table_bytes, all_chunk_bytes) catch
        return OpenExrError.InvalidRaster;
    if (bytes.len - header.raster_offset != expected_remaining) return OpenExrError.InvalidRaster;
    const chunks_start = header.raster_offset + table_bytes;

    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);
    const seen = try allocator.alloc(bool, height);
    defer allocator.free(seen);
    @memset(seen, false);
    const spans = try allocator.alloc(Span, height);
    defer allocator.free(spans);

    for (0..height) |table_index| {
        const offset_u64 = try readU64(bytes, header.raster_offset + table_index * 8);
        if (offset_u64 > std.math.maxInt(usize)) return OpenExrError.InvalidRaster;
        const offset: usize = @intCast(offset_u64);
        if (offset < chunks_start or offset > bytes.len or bytes.len - offset < 8) {
            return OpenExrError.InvalidRaster;
        }
        const y = try readI32(bytes, offset);
        const row_index_i64 = @as(i64, y) - header.data_window.min_y;
        if (row_index_i64 < 0 or row_index_i64 >= height_i64) return OpenExrError.InvalidRaster;
        const row_index: usize = @intCast(row_index_i64);
        if (seen[row_index]) return OpenExrError.InvalidRaster;
        seen[row_index] = true;
        const packed_size_i32 = try readI32(bytes, offset + 4);
        if (packed_size_i32 < 0 or @as(usize, @intCast(packed_size_i32)) != row_bytes) {
            return OpenExrError.InvalidRaster;
        }
        const chunk_end = std.math.add(usize, offset + 8, row_bytes) catch
            return OpenExrError.InvalidRaster;
        if (chunk_end > bytes.len) return OpenExrError.TruncatedData;
        spans[table_index] = .{ .start = offset, .end = chunk_end };

        // OpenEXR stores channels alphabetically: B plane, G plane, R plane.
        const payload = bytes[offset + 8 .. chunk_end];
        for (0..width) |x| {
            const output = (row_index * width + x) * 3;
            samples[output] = try decodeHalf(payload, row_bytes, width, 2, x);
            samples[output + 1] = try decodeHalf(payload, row_bytes, width, 1, x);
            samples[output + 2] = try decodeHalf(payload, row_bytes, width, 0, x);
        }
    }
    for (seen) |present| if (!present) return OpenExrError.InvalidRaster;
    std.mem.sort(Span, spans, {}, spanLessThan);
    var expected_start = chunks_start;
    for (spans) |span| {
        if (span.start != expected_start) return OpenExrError.InvalidRaster;
        expected_start = span.end;
    }
    if (expected_start != bytes.len) return OpenExrError.InvalidRaster;

    const matrix = try chromaticitiesToD50(header.chromaticities);
    const profile = try icc.buildLinearRgbProfile(allocator, matrix);
    errdefer allocator.free(profile);
    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .bit_depth = 16,
        .samples = samples,
        .icc_profile = profile,
    };
}

fn parseHeader(bytes: []const u8) !Header {
    if (bytes.len < 9 or try readU32(bytes, 0) != magic) return OpenExrError.InvalidHeader;
    const version_field = try readU32(bytes, 4);
    if ((version_field & 0xff) != 2 or (version_field & ~@as(u32, 0x4ff)) != 0 or
        (version_field & (0x200 | 0x800 | 0x1000)) != 0)
    {
        return OpenExrError.UnsupportedOpenExr;
    }
    const max_name: usize = if ((version_field & 0x400) != 0) 255 else 31;
    var cursor: usize = 8;
    var seen: u16 = 0;
    var data_window: ?Box2i = null;
    var display_window: ?Box2i = null;
    var line_order: ?u8 = null;
    var chromaticities: ?Chromaticities = null;

    while (true) {
        const name = try readCString(bytes, &cursor, max_name);
        if (name.len == 0) break;
        const attribute_type = try readCString(bytes, &cursor, max_name);
        if (attribute_type.len == 0) return OpenExrError.InvalidHeader;
        const size_i32 = try readI32(bytes, cursor);
        cursor += 4;
        if (size_i32 < 0) return OpenExrError.InvalidHeader;
        const size: usize = @intCast(size_i32);
        if (cursor > bytes.len or bytes.len - cursor < size) return OpenExrError.TruncatedData;
        const value = bytes[cursor .. cursor + size];
        cursor += size;

        if (std.mem.eql(u8, name, "channels")) {
            try markAttribute(&seen, 0);
            if (!std.mem.eql(u8, attribute_type, "chlist")) return OpenExrError.InvalidHeader;
            try parseChannels(value, max_name);
        } else if (std.mem.eql(u8, name, "compression")) {
            try markAttribute(&seen, 1);
            if (!std.mem.eql(u8, attribute_type, "compression") or value.len != 1 or value[0] != 0) {
                return OpenExrError.UnsupportedOpenExr;
            }
        } else if (std.mem.eql(u8, name, "dataWindow")) {
            try markAttribute(&seen, 2);
            if (!std.mem.eql(u8, attribute_type, "box2i")) return OpenExrError.InvalidHeader;
            data_window = try parseBox(value);
        } else if (std.mem.eql(u8, name, "displayWindow")) {
            try markAttribute(&seen, 3);
            if (!std.mem.eql(u8, attribute_type, "box2i")) return OpenExrError.InvalidHeader;
            display_window = try parseBox(value);
        } else if (std.mem.eql(u8, name, "lineOrder")) {
            try markAttribute(&seen, 4);
            if (!std.mem.eql(u8, attribute_type, "lineOrder") or value.len != 1 or value[0] > 1) {
                return OpenExrError.UnsupportedOpenExr;
            }
            line_order = value[0];
        } else if (std.mem.eql(u8, name, "pixelAspectRatio")) {
            try markAttribute(&seen, 5);
            if (!std.mem.eql(u8, attribute_type, "float") or value.len != 4 or
                try readF32(value, 0) != 1.0)
            {
                return OpenExrError.UnsupportedOpenExr;
            }
        } else if (std.mem.eql(u8, name, "screenWindowCenter")) {
            try markAttribute(&seen, 6);
            if (!std.mem.eql(u8, attribute_type, "v2f") or value.len != 8 or
                !std.math.isFinite(try readF32(value, 0)) or
                !std.math.isFinite(try readF32(value, 4)))
            {
                return OpenExrError.InvalidHeader;
            }
        } else if (std.mem.eql(u8, name, "screenWindowWidth")) {
            try markAttribute(&seen, 7);
            const width = try readF32(value, 0);
            if (!std.mem.eql(u8, attribute_type, "float") or value.len != 4 or
                !std.math.isFinite(width) or width <= 0.0)
            {
                return OpenExrError.InvalidHeader;
            }
        } else if (std.mem.eql(u8, name, "chromaticities")) {
            try markAttribute(&seen, 8);
            if (!std.mem.eql(u8, attribute_type, "chromaticities")) return OpenExrError.InvalidHeader;
            chromaticities = try parseChromaticities(value);
        } else {
            // Unknown attributes may carry metadata that z2000 cannot yet map
            // into JP2, so the bounded adapter refuses to drop them.
            return OpenExrError.UnsupportedOpenExr;
        }
    }
    if (@popCount(seen) != required_attribute_count) return OpenExrError.InvalidHeader;
    if (!Box2i.eql(data_window.?, display_window.?)) return OpenExrError.UnsupportedOpenExr;
    return .{
        .data_window = data_window.?,
        .line_order = line_order.?,
        .chromaticities = chromaticities.?,
        .raster_offset = cursor,
    };
}

fn parseChannels(bytes: []const u8, max_name: usize) !void {
    var cursor: usize = 0;
    var seen: u8 = 0;
    var previous: ?[]const u8 = null;
    while (true) {
        const name = try readCString(bytes, &cursor, max_name);
        if (name.len == 0) break;
        if (previous) |value| if (std.mem.order(u8, value, name) != .lt) {
            return OpenExrError.InvalidHeader;
        };
        previous = name;
        if (cursor > bytes.len or bytes.len - cursor < 16) return OpenExrError.TruncatedData;
        if (try readI32(bytes, cursor) != 1 or bytes[cursor + 5] != 0 or
            bytes[cursor + 6] != 0 or bytes[cursor + 7] != 0 or
            try readI32(bytes, cursor + 8) != 1 or try readI32(bytes, cursor + 12) != 1)
        {
            return OpenExrError.UnsupportedOpenExr;
        }
        cursor += 16;
        const bit: u8 = if (std.mem.eql(u8, name, "B"))
            1
        else if (std.mem.eql(u8, name, "G"))
            2
        else if (std.mem.eql(u8, name, "R"))
            4
        else
            return OpenExrError.UnsupportedOpenExr;
        if ((seen & bit) != 0) return OpenExrError.InvalidHeader;
        seen |= bit;
    }
    if (cursor != bytes.len or seen != 7) return OpenExrError.UnsupportedOpenExr;
}

fn parseBox(bytes: []const u8) !Box2i {
    if (bytes.len != 16) return OpenExrError.InvalidHeader;
    return .{
        .min_x = try readI32(bytes, 0),
        .min_y = try readI32(bytes, 4),
        .max_x = try readI32(bytes, 8),
        .max_y = try readI32(bytes, 12),
    };
}

fn parseChromaticities(bytes: []const u8) !Chromaticities {
    if (bytes.len != 32) return OpenExrError.InvalidHeader;
    var values: [8]f64 = undefined;
    for (0..8) |index| {
        values[index] = try readF32(bytes, index * 4);
        if (!validChromaticity(values[index])) return OpenExrError.InvalidHeader;
    }
    const result = Chromaticities{
        .red = .{ values[0], values[1] },
        .green = .{ values[2], values[3] },
        .blue = .{ values[4], values[5] },
        .white = .{ values[6], values[7] },
    };
    for ([_][2]f64{ result.red, result.green, result.blue, result.white }) |xy| {
        if (xy[1] <= 0.0 or xy[0] + xy[1] > 1.000001) return OpenExrError.InvalidHeader;
    }
    return result;
}

fn validChromaticity(value: f64) bool {
    return std.math.isFinite(value) and value >= 0.0 and value <= 1.0;
}

fn decodeHalf(bytes: []const u8, row_bytes: usize, width: usize, channel: usize, x: usize) !u16 {
    _ = row_bytes;
    const offset = (channel * width + x) * 2;
    const bits = try readU16(bytes, offset);
    const half: f16 = @bitCast(bits);
    const value: f64 = @floatCast(half);
    if (!std.math.isFinite(value) or value < 0.0 or value > 1.0) {
        return OpenExrError.SampleOutOfRange;
    }
    return @intFromFloat(@round(value * 65535.0));
}

fn chromaticitiesToD50(chroma: Chromaticities) !icc.Matrix {
    const primaries: icc.Matrix = .{
        .{ chroma.red[0] / chroma.red[1], chroma.green[0] / chroma.green[1], chroma.blue[0] / chroma.blue[1] },
        .{ 1.0, 1.0, 1.0 },
        .{
            (1.0 - chroma.red[0] - chroma.red[1]) / chroma.red[1],
            (1.0 - chroma.green[0] - chroma.green[1]) / chroma.green[1],
            (1.0 - chroma.blue[0] - chroma.blue[1]) / chroma.blue[1],
        },
    };
    const primary_inverse = invertMatrix(primaries) orelse return OpenExrError.InvalidHeader;
    const source_white = xyToXyz(chroma.white);
    const scale = multiplyMatrixVector(primary_inverse, source_white);
    var source_matrix: icc.Matrix = undefined;
    for (0..3) |row| for (0..3) |column| {
        source_matrix[row][column] = primaries[row][column] * scale[column];
    };

    const bradford: icc.Matrix = .{
        .{ 0.8951, 0.2664, -0.1614 },
        .{ -0.7502, 1.7135, 0.0367 },
        .{ 0.0389, -0.0685, 1.0296 },
    };
    const bradford_inverse = invertMatrix(bradford) orelse unreachable;
    const d50: [3]f64 = .{ 0.9642, 1.0, 0.8249 };
    const source_cone = multiplyMatrixVector(bradford, source_white);
    const d50_cone = multiplyMatrixVector(bradford, d50);
    var diagonal: icc.Matrix = [_][3]f64{[_]f64{0.0} ** 3} ** 3;
    for (0..3) |index| {
        if (!std.math.isFinite(source_cone[index]) or @abs(source_cone[index]) < 0.000000001) {
            return OpenExrError.InvalidHeader;
        }
        diagonal[index][index] = d50_cone[index] / source_cone[index];
    }
    return multiplyMatrices(multiplyMatrices(bradford_inverse, diagonal), multiplyMatrices(bradford, source_matrix));
}

fn xyToXyz(xy: [2]f64) [3]f64 {
    return .{ xy[0] / xy[1], 1.0, (1.0 - xy[0] - xy[1]) / xy[1] };
}

fn multiplyMatrixVector(matrix: icc.Matrix, vector: [3]f64) [3]f64 {
    return .{
        matrix[0][0] * vector[0] + matrix[0][1] * vector[1] + matrix[0][2] * vector[2],
        matrix[1][0] * vector[0] + matrix[1][1] * vector[1] + matrix[1][2] * vector[2],
        matrix[2][0] * vector[0] + matrix[2][1] * vector[1] + matrix[2][2] * vector[2],
    };
}

fn multiplyMatrices(a: icc.Matrix, b: icc.Matrix) icc.Matrix {
    var result: icc.Matrix = undefined;
    for (0..3) |row| for (0..3) |column| {
        result[row][column] = a[row][0] * b[0][column] +
            a[row][1] * b[1][column] + a[row][2] * b[2][column];
    };
    return result;
}

fn invertMatrix(matrix: icc.Matrix) ?icc.Matrix {
    const determinant =
        matrix[0][0] * (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) -
        matrix[0][1] * (matrix[1][0] * matrix[2][2] - matrix[1][2] * matrix[2][0]) +
        matrix[0][2] * (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]);
    if (!std.math.isFinite(determinant) or @abs(determinant) < 0.000000000001) return null;
    const inverse = 1.0 / determinant;
    return .{
        .{
            (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) * inverse,
            (matrix[0][2] * matrix[2][1] - matrix[0][1] * matrix[2][2]) * inverse,
            (matrix[0][1] * matrix[1][2] - matrix[0][2] * matrix[1][1]) * inverse,
        },
        .{
            (matrix[1][2] * matrix[2][0] - matrix[1][0] * matrix[2][2]) * inverse,
            (matrix[0][0] * matrix[2][2] - matrix[0][2] * matrix[2][0]) * inverse,
            (matrix[0][2] * matrix[1][0] - matrix[0][0] * matrix[1][2]) * inverse,
        },
        .{
            (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]) * inverse,
            (matrix[0][1] * matrix[2][0] - matrix[0][0] * matrix[2][1]) * inverse,
            (matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]) * inverse,
        },
    };
}

fn markAttribute(seen: *u16, index: u4) !void {
    const bit = @as(u16, 1) << index;
    if ((seen.* & bit) != 0) return OpenExrError.InvalidHeader;
    seen.* |= bit;
}

fn spanLessThan(_: void, a: Span, b: Span) bool {
    return a.start < b.start;
}

fn readCString(bytes: []const u8, cursor: *usize, max_len: usize) ![]const u8 {
    if (cursor.* >= bytes.len) return OpenExrError.TruncatedData;
    const start = cursor.*;
    while (cursor.* < bytes.len and bytes[cursor.*] != 0) : (cursor.* += 1) {
        if (cursor.* - start == max_len) return OpenExrError.InvalidHeader;
    }
    if (cursor.* >= bytes.len) return OpenExrError.TruncatedData;
    const result = bytes[start..cursor.*];
    cursor.* += 1;
    return result;
}

fn readU16(bytes: []const u8, offset: usize) !u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return OpenExrError.TruncatedData;
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: usize) !u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return OpenExrError.TruncatedData;
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn readI32(bytes: []const u8, offset: usize) !i32 {
    return @bitCast(try readU32(bytes, offset));
}

fn readU64(bytes: []const u8, offset: usize) !u64 {
    if (offset > bytes.len or bytes.len - offset < 8) return OpenExrError.TruncatedData;
    return @as(u64, try readU32(bytes, offset)) |
        (@as(u64, try readU32(bytes, offset + 4)) << 32);
}

fn readF32(bytes: []const u8, offset: usize) !f32 {
    return @bitCast(try readU32(bytes, offset));
}
