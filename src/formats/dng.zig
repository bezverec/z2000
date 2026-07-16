const std = @import("std");
const image = @import("../image.zig");
const icc = @import("../icc.zig");
const tiff_ifd = @import("tiff_ifd.zig");

const max_ifds = 32;

pub const DngError = error{
    InvalidDng,
    InvalidRaster,
    UnsupportedDng,
    TooManyIfds,
};

// This product includes DNG technology under license by Adobe.
const linear_raw = 34892;
const max_file_size = 1024 * 1024 * 1024;

pub const Version = struct { bytes: [4]u8 };

pub const IfdSummary = struct {
    offset: usize,
    is_subifd: bool = false,
    width: ?u32 = null,
    height: ?u32 = null,
    bits_per_sample: ?u16 = null,
    bits_per_sample_count: usize = 0,
    samples_per_pixel: ?u16 = null,
    compression: ?u16 = null,
    photometric: ?u16 = null,
    sample_format: ?u16 = null,
    subfile_type: ?u32 = null,
    subifd_count: usize = 0,
};

pub const Info = struct {
    endian: tiff_ifd.Endian,
    ifd_count: usize,
    ifds: [max_ifds]IfdSummary,
    dng_version: ?Version = null,
    dng_backward_version: ?Version = null,
    make: ?[]const u8 = null,
    model: ?[]const u8 = null,
    unique_camera_model: ?[]const u8 = null,
    cfa_repeat: ?[2]u16 = null,
    cfa_pattern: ?[4]u8 = null,
    cfa_pattern_count: usize = 0,

    pub fn primary(self: Info) ?IfdSummary {
        if (self.ifd_count == 0) return null;
        return self.ifds[0];
    }
};

pub fn parseInfo(bytes: []const u8) !Info {
    const document = try tiff_ifd.Document.parse(bytes);
    var info = Info{
        .endian = document.endian,
        .ifd_count = 0,
        .ifds = [_]IfdSummary{.{ .offset = 0 }} ** max_ifds,
    };

    var ifd_offset = document.first_ifd_offset;
    var chain_count: usize = 0;
    while (ifd_offset != 0) {
        if (chain_count == max_ifds) return DngError.TooManyIfds;
        const ifd = try document.readIfd(ifd_offset);
        try appendSummary(document, ifd, false, &info);
        if (chain_count == 0) try readPrimaryDngTags(document, ifd, &info);
        chain_count += 1;
        ifd_offset = ifd.next_ifd_offset;
    }

    var index: usize = 0;
    while (index < info.ifd_count) : (index += 1) {
        const ifd = try document.readIfd(info.ifds[index].offset);
        const subifds_entry = try document.findEntry(ifd, 330) orelse continue;
        const subifds_ref = try subifds_entry.ref(document);
        info.ifds[index].subifd_count = subifds_ref.count;
        var sub_index: usize = 0;
        while (sub_index < subifds_ref.count) : (sub_index += 1) {
            if (info.ifd_count == max_ifds) return DngError.TooManyIfds;
            const subifd_offset = @as(usize, try subifds_ref.u32At(document, sub_index));
            const subifd = try document.readIfd(subifd_offset);
            try appendSummary(document, subifd, true, &info);
        }
    }

    return info;
}

/// Reads a deliberately bounded LinearRaw DNG raster. The accepted profile is
/// one uncompressed, chunky, unsigned 8/16-bit three-channel IFD (IFD0 or one
/// direct SubIFD), orientation 1, with the one-illuminant matrix metadata
/// needed to construct a linear RGB ICC profile. CFA data and implicit colour
/// guesses fail closed.
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
    const document = try tiff_ifd.Document.parse(bytes);
    const ifd0 = try document.readIfd(document.first_ifd_offset);
    try validatePrimaryMetadata(document, ifd0);
    const raw_ifd = try findLinearRawIfd(document, ifd0);
    try rejectAdditionalLinearRawIfds(document, ifd0);
    try rejectUnsupportedMetadata(document, ifd0, raw_ifd);

    const width = try requiredU32(document, raw_ifd, 256);
    const height = try requiredU32(document, raw_ifd, 257);
    if (width == 0 or height == 0) return DngError.InvalidRaster;
    const width_usize: usize = width;
    const height_usize: usize = height;

    const bits_ref = try (try requiredEntry(document, raw_ifd, 258)).ref(document);
    if (bits_ref.count != 3) return DngError.UnsupportedDng;
    const bit_depth = try bits_ref.u16At(document, 0);
    if (bit_depth != 8 and bit_depth != 16) return DngError.UnsupportedDng;
    for (1..3) |channel| if (try bits_ref.u16At(document, channel) != bit_depth) {
        return DngError.UnsupportedDng;
    };
    if (try requiredU16(document, raw_ifd, 259) != 1 or
        try requiredU16(document, raw_ifd, 262) != linear_raw or
        try requiredU16(document, raw_ifd, 277) != 3 or
        try optionalU32(document, raw_ifd, 254, 0) != 0)
    {
        return DngError.UnsupportedDng;
    }
    if (try optionalU16(document, raw_ifd, 266, 1) != 1 or
        try optionalU16(document, raw_ifd, 274, 1) != 1 or
        try optionalU16(document, raw_ifd, 284, 1) != 1 or
        try optionalU16(document, raw_ifd, 317, 1) != 1 or
        try optionalU16(document, raw_ifd, 339, 1) != 1)
    {
        return DngError.UnsupportedDng;
    }

    const sample_count = std.math.mul(usize, width_usize, height_usize) catch
        return DngError.InvalidRaster;
    const rgb_count = std.math.mul(usize, sample_count, 3) catch
        return DngError.InvalidRaster;
    const expected_raster_bytes = std.math.mul(usize, rgb_count, bit_depth / 8) catch
        return DngError.InvalidRaster;
    if (expected_raster_bytes > document.bytes.len) return DngError.InvalidRaster;
    const samples = try allocator.alloc(u16, rgb_count);
    errdefer allocator.free(samples);

    try readStrips(document, raw_ifd, width_usize, height_usize, @intCast(bit_depth), samples);
    try normalizeSamples(document, raw_ifd, bit_depth, samples);

    const matrix = try cameraToXyzMatrix(document, ifd0);
    const profile = try icc.buildLinearRgbProfile(allocator, matrix);
    errdefer allocator.free(profile);
    return .{
        .allocator = allocator,
        .width = width_usize,
        .height = height_usize,
        .bit_depth = @intCast(bit_depth),
        .samples = samples,
        .icc_profile = profile,
    };
}

fn validatePrimaryMetadata(document: tiff_ifd.Document, ifd0: tiff_ifd.Ifd) !void {
    const version_entry = try requiredEntry(document, ifd0, 50706);
    const version = try readVersion(document, version_entry);
    if (!versionAtLeast(version.bytes, .{ 1, 2, 0, 0 }) or
        !versionAtMost(version.bytes, .{ 1, 7, 1, 0 }))
    {
        return DngError.UnsupportedDng;
    }
    if (try findUniqueEntry(document, ifd0, 50707)) |entry| {
        const backward = try readVersion(document, entry);
        if (!versionAtLeast(backward.bytes, .{ 1, 2, 0, 0 }) or
            !versionAtMost(backward.bytes, version.bytes))
        {
            return DngError.UnsupportedDng;
        }
    }
    const model_ref = try (try requiredEntry(document, ifd0, 50708)).ref(document);
    if ((try model_ref.ascii(document)).len == 0) return DngError.InvalidDng;
    if (try optionalU16(document, ifd0, 274, 1) != 1) return DngError.UnsupportedDng;
    if (try optionalU16(document, ifd0, 50879, 0) != 0) return DngError.UnsupportedDng;
}

fn findLinearRawIfd(document: tiff_ifd.Document, ifd0: tiff_ifd.Ifd) !tiff_ifd.Ifd {
    var found: ?tiff_ifd.Ifd = null;
    if (try isLinearRaw(document, ifd0)) found = ifd0;
    if (try findUniqueEntry(document, ifd0, 330)) |entry| {
        const refs = try entry.ref(document);
        for (0..refs.count) |index| {
            const offset: usize = try refs.u32At(document, index);
            const subifd = try document.readIfd(offset);
            if (!try isLinearRaw(document, subifd)) continue;
            if (found != null) return DngError.UnsupportedDng;
            found = subifd;
        }
    }
    return found orelse DngError.UnsupportedDng;
}

fn isLinearRaw(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd) !bool {
    const entry = try findUniqueEntry(document, ifd, 262) orelse return false;
    return try entry.singleU16(document) == linear_raw;
}

fn rejectAdditionalLinearRawIfds(document: tiff_ifd.Document, ifd0: tiff_ifd.Ifd) !void {
    var offset = ifd0.next_ifd_offset;
    var count: usize = 0;
    while (offset != 0) {
        if (count == max_ifds) return DngError.TooManyIfds;
        const ifd = try document.readIfd(offset);
        if (try isLinearRaw(document, ifd)) return DngError.UnsupportedDng;
        if (try findUniqueEntry(document, ifd, 330)) |entry| {
            const refs = try entry.ref(document);
            for (0..refs.count) |index| {
                const subifd = try document.readIfd(try refs.u32At(document, index));
                if (try isLinearRaw(document, subifd)) return DngError.UnsupportedDng;
            }
        }
        count += 1;
        offset = ifd.next_ifd_offset;
    }
}

fn rejectUnsupportedMetadata(
    document: tiff_ifd.Document,
    ifd0: tiff_ifd.Ifd,
    raw_ifd: tiff_ifd.Ifd,
) !void {
    const raw_tags = [_]u16{
        700, 33723, 34377, 34665, 34675, 34853, // XMP / IPTC / Photoshop / EXIF / ICC / GPS
        322, 323, 324, 325, 338, // tiles / extra samples
        50715, 50716, // BlackLevelDeltaH/V
        50718, 50719, 50720, 50780, 50829, 50830, // scale / crop / active/masked area
        50974, 50975, 52547, // sub-tile / row / column interleave
        52525, // ProfileGainTableMap
        51008, 51009, 51022, // opcode lists
    };
    for (raw_tags) |tag| if (try findUniqueEntry(document, raw_ifd, tag) != null) {
        return DngError.UnsupportedDng;
    };
    const primary_tags = [_]u16{
        700, 33723, 34377, 34665, 34675, 34853, // XMP / IPTC / Photoshop / EXIF / ICC / GPS
        50722, 50723, 50724, 50725, 50726, 50727, 50779, // second calibration / analog balance
        50729, // AsShotWhiteXY (the bounded profile requires AsShotNeutral)
        50740, // DNGPrivateData
        50831, 50832, 50833, 50834, // embedded/current ICC profile paths
        50931, 50932, 50933, // profile signatures / extra camera profiles
        50934, 50935, 50936, 50937, 50938, 50939, 50940, 50941, 50942, // profile metadata/maps
        50965, // ForwardMatrix2
        50981, 50982, // profile look table
        51107, 51108, 51109, 51110, 51125, // profile encodings/render/crop
        52529, 52530, 52531, 52532, 52533, 52534, 52535, 52536, 52537, 52538, // third/custom calibration
        52525, 52543, 52544, // gain/RGB/profile rendering tables
    };
    for (primary_tags) |tag| if (try findUniqueEntry(document, ifd0, tag) != null) {
        return DngError.UnsupportedDng;
    };
}

fn readStrips(
    document: tiff_ifd.Document,
    ifd: tiff_ifd.Ifd,
    width: usize,
    height: usize,
    bit_depth: u8,
    samples: []u16,
) !void {
    const rows_per_strip_u32 = try requiredU32(document, ifd, 278);
    if (rows_per_strip_u32 == 0) return DngError.InvalidRaster;
    const rows_per_strip: usize = rows_per_strip_u32;
    const strip_count = (height + rows_per_strip - 1) / rows_per_strip;
    const offsets = try (try requiredEntry(document, ifd, 273)).ref(document);
    const byte_counts = try (try requiredEntry(document, ifd, 279)).ref(document);
    if (offsets.count != strip_count or byte_counts.count != strip_count) {
        return DngError.InvalidRaster;
    }
    const bytes_per_sample: usize = bit_depth / 8;
    const row_samples = std.math.mul(usize, width, 3) catch return DngError.InvalidRaster;
    const row_bytes = std.math.mul(usize, row_samples, bytes_per_sample) catch
        return DngError.InvalidRaster;
    var output_index: usize = 0;
    for (0..strip_count) |strip| {
        const first_row = std.math.mul(usize, strip, rows_per_strip) catch
            return DngError.InvalidRaster;
        const rows = @min(rows_per_strip, height - first_row);
        const expected_bytes = std.math.mul(usize, rows, row_bytes) catch
            return DngError.InvalidRaster;
        const offset: usize = try offsets.u32At(document, strip);
        const byte_count: usize = try byte_counts.u32At(document, strip);
        if (byte_count != expected_bytes or offset > document.bytes.len or
            document.bytes.len - offset < byte_count)
        {
            return DngError.InvalidRaster;
        }
        const raster = document.bytes[offset .. offset + byte_count];
        var cursor: usize = 0;
        while (cursor < raster.len) {
            samples[output_index] = if (bit_depth == 8)
                raster[cursor]
            else
                try tiff_ifd.readU16(raster, cursor, document.endian);
            output_index += 1;
            cursor += bytes_per_sample;
        }
    }
    if (output_index != samples.len) return DngError.InvalidRaster;
}

fn normalizeSamples(
    document: tiff_ifd.Document,
    ifd: tiff_ifd.Ifd,
    bit_depth: u16,
    samples: []u16,
) !void {
    if (try findUniqueEntry(document, ifd, 50713)) |entry| {
        const repeat = try entry.ref(document);
        if (repeat.count != 2 or try repeat.u16At(document, 0) != 1 or
            try repeat.u16At(document, 1) != 1)
        {
            return DngError.UnsupportedDng;
        }
    }

    var black = [_]f64{0.0} ** 3;
    if (try findUniqueEntry(document, ifd, 50714)) |entry| {
        const values = try entry.ref(document);
        if (values.count != 1 and values.count != 3) return DngError.UnsupportedDng;
        for (0..3) |channel| {
            black[channel] = try unsignedNumberAt(values, document, if (values.count == 1) 0 else channel);
        }
    }

    const native_max: u32 = (@as(u32, 1) << @intCast(bit_depth)) - 1;
    var white = [_]f64{@floatFromInt(native_max)} ** 3;
    if (try findUniqueEntry(document, ifd, 50717)) |entry| {
        const values = try entry.ref(document);
        if (values.count != 1 and values.count != 3) return DngError.UnsupportedDng;
        for (0..3) |channel| {
            white[channel] = @floatFromInt(try values.u32At(document, if (values.count == 1) 0 else channel));
        }
    }
    for (0..3) |channel| if (!std.math.isFinite(black[channel]) or
        !std.math.isFinite(white[channel]) or white[channel] <= black[channel])
    {
        return DngError.InvalidDng;
    };

    var linearization: ?tiff_ifd.ValueRef = null;
    if (try findUniqueEntry(document, ifd, 50712)) |entry| {
        const table = try entry.ref(document);
        if (table.count == 0 or table.field_type != @intFromEnum(tiff_ifd.FieldType.short)) {
            return DngError.UnsupportedDng;
        }
        linearization = table;
    }
    const output_max: f64 = @floatFromInt(native_max);
    for (samples, 0..) |sample, index| {
        const linearized: u16 = if (linearization) |table|
            try table.u16At(document, @min(@as(usize, sample), table.count - 1))
        else
            sample;
        const channel = index % 3;
        const normalized = std.math.clamp(
            (@as(f64, @floatFromInt(linearized)) - black[channel]) /
                (white[channel] - black[channel]),
            0.0,
            1.0,
        );
        samples[index] = @intFromFloat(@round(normalized * output_max));
    }
}

fn cameraToXyzMatrix(document: tiff_ifd.Document, ifd0: tiff_ifd.Ifd) !icc.Matrix {
    // ColorMatrix1 and CalibrationIlluminant1 are required by the bounded
    // one-calibration profile even though ForwardMatrix1 supplies the direct
    // white-balanced camera-to-PCS transform used below.
    _ = try readMatrix(document, try requiredEntry(document, ifd0, 50721));
    const illuminant = try requiredU16(document, ifd0, 50778);
    if (illuminant == 0 or illuminant == 255) return DngError.UnsupportedDng;
    const forward = try readMatrix(document, try requiredEntry(document, ifd0, 50964));
    const neutral_ref = try (try requiredEntry(document, ifd0, 50728)).ref(document);
    if (neutral_ref.count != 3) return DngError.InvalidDng;
    var neutral: [3]f64 = undefined;
    for (0..3) |channel| {
        neutral[channel] = try unsignedNumberAt(neutral_ref, document, channel);
        if (!std.math.isFinite(neutral[channel]) or neutral[channel] <= 0.0) {
            return DngError.InvalidDng;
        }
    }
    var result: icc.Matrix = undefined;
    for (0..3) |row| for (0..3) |column| {
        result[row][column] = forward[row][column] / neutral[column];
    };
    return result;
}

fn unsignedNumberAt(values: tiff_ifd.ValueRef, document: tiff_ifd.Document, index: usize) !f64 {
    return switch (values.field_type) {
        @intFromEnum(tiff_ifd.FieldType.short), @intFromEnum(tiff_ifd.FieldType.long) => @floatFromInt(try values.u32At(document, index)),
        @intFromEnum(tiff_ifd.FieldType.rational) => try values.rationalAt(document, index),
        else => DngError.InvalidDng,
    };
}

fn readMatrix(document: tiff_ifd.Document, entry: tiff_ifd.Entry) !icc.Matrix {
    const values = try entry.ref(document);
    if (values.count != 9) return DngError.InvalidDng;
    var matrix: icc.Matrix = undefined;
    for (0..3) |row| for (0..3) |column| {
        const value = try values.srationalAt(document, row * 3 + column);
        if (!std.math.isFinite(value)) return DngError.InvalidDng;
        matrix[row][column] = value;
    };
    return matrix;
}

fn requiredEntry(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, tag: u16) !tiff_ifd.Entry {
    return try findUniqueEntry(document, ifd, tag) orelse DngError.InvalidDng;
}

fn requiredU16(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, tag: u16) !u16 {
    return (try requiredEntry(document, ifd, tag)).singleU16(document);
}

fn requiredU32(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, tag: u16) !u32 {
    return (try requiredEntry(document, ifd, tag)).singleU32(document);
}

fn optionalU16(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, tag: u16, default: u16) !u16 {
    const entry = try findUniqueEntry(document, ifd, tag) orelse return default;
    return entry.singleU16(document);
}

fn optionalU32(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, tag: u16, default: u32) !u32 {
    const entry = try findUniqueEntry(document, ifd, tag) orelse return default;
    return entry.singleU32(document);
}

fn findUniqueEntry(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, tag: u16) !?tiff_ifd.Entry {
    var found: ?tiff_ifd.Entry = null;
    for (0..ifd.entry_count) |index| {
        const entry = try document.entryAt(ifd, index);
        if (entry.tag != tag) continue;
        if (found != null) return DngError.InvalidDng;
        found = entry;
    }
    return found;
}

fn versionAtLeast(actual: [4]u8, minimum: [4]u8) bool {
    return std.mem.order(u8, &actual, &minimum) != .lt;
}

fn versionAtMost(actual: [4]u8, maximum: [4]u8) bool {
    return std.mem.order(u8, &actual, &maximum) != .gt;
}

fn appendSummary(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, is_subifd: bool, info: *Info) !void {
    if (info.ifd_count == max_ifds) return DngError.TooManyIfds;
    info.ifds[info.ifd_count] = try summarizeIfd(document, ifd, is_subifd);
    info.ifd_count += 1;
}

fn summarizeIfd(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, is_subifd: bool) !IfdSummary {
    var summary = IfdSummary{ .offset = ifd.offset, .is_subifd = is_subifd };
    if (try document.findEntry(ifd, 254)) |entry| summary.subfile_type = try entry.singleU32(document);
    if (try document.findEntry(ifd, 256)) |entry| summary.width = try entry.singleU32(document);
    if (try document.findEntry(ifd, 257)) |entry| summary.height = try entry.singleU32(document);
    if (try document.findEntry(ifd, 258)) |entry| {
        const value_ref = try entry.ref(document);
        if (value_ref.count > 0) summary.bits_per_sample = try value_ref.u16At(document, 0);
        summary.bits_per_sample_count = value_ref.count;
    }
    if (try document.findEntry(ifd, 259)) |entry| summary.compression = try entry.singleU16(document);
    if (try document.findEntry(ifd, 262)) |entry| summary.photometric = try entry.singleU16(document);
    if (try document.findEntry(ifd, 277)) |entry| summary.samples_per_pixel = try entry.singleU16(document);
    if (try document.findEntry(ifd, 339)) |entry| summary.sample_format = try entry.singleU16(document);
    return summary;
}

fn readPrimaryDngTags(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, info: *Info) !void {
    if (try document.findEntry(ifd, 271)) |entry| info.make = try (try entry.ref(document)).ascii(document);
    if (try document.findEntry(ifd, 272)) |entry| info.model = try (try entry.ref(document)).ascii(document);
    if (try document.findEntry(ifd, 50706)) |entry| info.dng_version = try readVersion(document, entry);
    if (try document.findEntry(ifd, 50707)) |entry| info.dng_backward_version = try readVersion(document, entry);
    if (try document.findEntry(ifd, 50708)) |entry| info.unique_camera_model = try (try entry.ref(document)).ascii(document);
    if (try document.findEntry(ifd, 33421)) |entry| {
        const value_ref = try entry.ref(document);
        if (value_ref.count == 2) {
            info.cfa_repeat = .{
                try value_ref.u16At(document, 0),
                try value_ref.u16At(document, 1),
            };
        }
    }
    if (try document.findEntry(ifd, 33422)) |entry| {
        const value_ref = try entry.ref(document);
        const count = @min(value_ref.count, 4);
        if (count > 0) {
            var pattern = [_]u8{0} ** 4;
            var index: usize = 0;
            while (index < count) : (index += 1) {
                pattern[index] = try value_ref.byteAt(document, index);
            }
            info.cfa_pattern = pattern;
            info.cfa_pattern_count = count;
        }
    }
}

fn readVersion(document: tiff_ifd.Document, entry: tiff_ifd.Entry) !Version {
    const value_ref = try entry.ref(document);
    if (value_ref.count != 4) return tiff_ifd.Error.InvalidTagValue;
    return .{ .bytes = .{
        try value_ref.byteAt(document, 0),
        try value_ref.byteAt(document, 1),
        try value_ref.byteAt(document, 2),
        try value_ref.byteAt(document, 3),
    } };
}
