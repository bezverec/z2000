const std = @import("std");
const image = @import("image.zig");

pub const TiffError = error{
    InvalidHeader,
    InvalidIfd,
    InvalidTagValue,
    MissingRequiredTag,
    UnsupportedCompression,
    UnsupportedPhotometric,
    UnsupportedBitsPerSample,
    UnsupportedPlanarConfiguration,
    UnsupportedSampleFormat,
    TruncatedData,
    ImageTooLarge,
};

const max_file_size = 1024 * 1024 * 1024;
const max_pixels = 268_435_456;
const max_icc_profile_bytes = 16 * 1024 * 1024;

const Endian = enum {
    little,
    big,
};

const IfdEntry = struct {
    tag: u16,
    field_type: u16,
    count: u32,
    value_or_offset: u32,
};

pub fn readRgb(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !image.RgbImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);

    return parseRgb(allocator, bytes);
}

pub fn writeRgb(io: std.Io, allocator: std.mem.Allocator, rgb: image.RgbImage, path: []const u8) !void {
    if (rgb.width == 0 or rgb.height == 0 or (rgb.bit_depth != 8 and rgb.bit_depth != 16)) {
        return TiffError.InvalidTagValue;
    }
    const pixels = try std.math.mul(usize, rgb.width, rgb.height);
    const sample_count = try std.math.mul(usize, pixels, 3);
    if (rgb.samples.len != sample_count) return TiffError.InvalidTagValue;

    const bytes_per_sample: usize = if (rgb.bit_depth == 8) 1 else 2;
    const raster_bytes = try std.math.mul(usize, sample_count, bytes_per_sample);
    if (rgb.width > std.math.maxInt(u32) or
        rgb.height > std.math.maxInt(u32) or
        raster_bytes > std.math.maxInt(u32))
    {
        return TiffError.ImageTooLarge;
    }

    const icc_profile = rgb.icc_profile;
    if (icc_profile) |profile| {
        if (profile.len == 0 or profile.len > max_icc_profile_bytes) return TiffError.InvalidTagValue;
        if (profile.len > std.math.maxInt(u32)) return TiffError.ImageTooLarge;
    }

    const entry_count: u16 = if (icc_profile != null) 11 else 10;
    const bits_offset: u32 = 8 + 2 + @as(u32, entry_count) * 12 + 4;
    const raster_offset: u32 = bits_offset + 6;
    const icc_offset: u32 = try std.math.add(u32, raster_offset, @as(u32, @intCast(raster_bytes)));

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "II");
    try appendU16Le(allocator, &out, 42);
    try appendU32Le(allocator, &out, 8);
    try appendU16Le(allocator, &out, entry_count);
    try appendIfdEntryLe(allocator, &out, 256, 4, 1, @as(u32, @intCast(rgb.width)));
    try appendIfdEntryLe(allocator, &out, 257, 4, 1, @as(u32, @intCast(rgb.height)));
    try appendIfdEntryLe(allocator, &out, 258, 3, 3, bits_offset);
    try appendIfdEntryLe(allocator, &out, 259, 3, 1, 1);
    try appendIfdEntryLe(allocator, &out, 262, 3, 1, 2);
    try appendIfdEntryLe(allocator, &out, 273, 4, 1, raster_offset);
    try appendIfdEntryLe(allocator, &out, 277, 3, 1, 3);
    try appendIfdEntryLe(allocator, &out, 278, 4, 1, @as(u32, @intCast(rgb.height)));
    try appendIfdEntryLe(allocator, &out, 279, 4, 1, @as(u32, @intCast(raster_bytes)));
    try appendIfdEntryLe(allocator, &out, 284, 3, 1, 1);
    if (icc_profile) |profile| {
        try appendIfdEntryLe(allocator, &out, 34675, 7, @as(u32, @intCast(profile.len)), icc_offset);
    }
    try appendU32Le(allocator, &out, 0);
    try appendU16Le(allocator, &out, rgb.bit_depth);
    try appendU16Le(allocator, &out, rgb.bit_depth);
    try appendU16Le(allocator, &out, rgb.bit_depth);

    if (rgb.bit_depth == 8) {
        for (rgb.samples) |sample| {
            if (sample > 255) return TiffError.InvalidTagValue;
            try out.append(allocator, @as(u8, @intCast(sample)));
        }
    } else {
        for (rgb.samples) |sample| {
            try appendU16Le(allocator, &out, sample);
        }
    }
    if (icc_profile) |profile| try out.appendSlice(allocator, profile);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

pub fn parseRgb(allocator: std.mem.Allocator, bytes: []const u8) !image.RgbImage {
    if (bytes.len < 8) return TiffError.InvalidHeader;

    const endian: Endian = if (std.mem.eql(u8, bytes[0..2], "II"))
        .little
    else if (std.mem.eql(u8, bytes[0..2], "MM"))
        .big
    else
        return TiffError.InvalidHeader;

    if (readU16(bytes, 2, endian) != 42) return TiffError.InvalidHeader;

    const ifd_offset = @as(usize, readU32(bytes, 4, endian));
    if (ifd_offset > bytes.len - 2) return TiffError.InvalidIfd;

    const entry_count = readU16(bytes, ifd_offset, endian);
    const entries_offset = ifd_offset + 2;
    const entries_bytes = try std.math.mul(usize, entry_count, 12);
    if (entries_offset > bytes.len or bytes.len - entries_offset < entries_bytes) {
        return TiffError.InvalidIfd;
    }

    var width: ?u32 = null;
    var height: ?u32 = null;
    var compression: u16 = 1;
    var photometric: ?u16 = null;
    var bits: [3]u16 = .{ 0, 0, 0 };
    var bits_count: usize = 0;
    var strip_offsets_ref: ?ValueRef = null;
    var strip_counts_ref: ?ValueRef = null;
    var samples_per_pixel: u16 = 1;
    var planar_config: u16 = 1;
    var sample_format: u16 = 1;
    var icc_profile_ref: ?ValueRef = null;

    for (0..entry_count) |i| {
        const entry = readEntry(bytes, entries_offset + i * 12, endian);
        switch (entry.tag) {
            256 => width = try readSingleU32(bytes, endian, entry),
            257 => height = try readSingleU32(bytes, endian, entry),
            258 => {
                bits_count = @as(usize, @intCast(entry.count));
                if (bits_count != 3) return TiffError.UnsupportedBitsPerSample;
                const ref = try valueRef(bytes, entry);
                for (0..3) |channel| {
                    bits[channel] = try readU16Value(bytes, endian, ref, channel);
                }
            },
            259 => compression = try readSingleU16(bytes, endian, entry),
            262 => photometric = try readSingleU16(bytes, endian, entry),
            273 => strip_offsets_ref = try valueRef(bytes, entry),
            277 => samples_per_pixel = try readSingleU16(bytes, endian, entry),
            278 => {},
            279 => strip_counts_ref = try valueRef(bytes, entry),
            284 => planar_config = try readSingleU16(bytes, endian, entry),
            339 => sample_format = try readSampleFormat(bytes, endian, entry),
            34675 => icc_profile_ref = try valueRef(bytes, entry),
            else => {},
        }
    }

    const w = width orelse return TiffError.MissingRequiredTag;
    const h = height orelse return TiffError.MissingRequiredTag;
    const photo = photometric orelse return TiffError.MissingRequiredTag;
    const offsets_ref = strip_offsets_ref orelse return TiffError.MissingRequiredTag;
    const counts_ref = strip_counts_ref orelse return TiffError.MissingRequiredTag;

    if (w == 0 or h == 0) return TiffError.InvalidTagValue;
    if (compression != 1) return TiffError.UnsupportedCompression;
    if (photo != 2) return TiffError.UnsupportedPhotometric;
    if (samples_per_pixel != 3) return TiffError.InvalidTagValue;
    if (planar_config != 1) return TiffError.UnsupportedPlanarConfiguration;
    if (sample_format != 1) return TiffError.UnsupportedSampleFormat;
    if (bits_count != 3 or bits[0] != bits[1] or bits[1] != bits[2]) {
        return TiffError.UnsupportedBitsPerSample;
    }
    if (bits[0] != 8 and bits[0] != 16) return TiffError.UnsupportedBitsPerSample;

    const width_usize = @as(usize, w);
    const height_usize = @as(usize, h);
    const pixels = try std.math.mul(usize, width_usize, height_usize);
    if (pixels > max_pixels) return TiffError.ImageTooLarge;
    const sample_count = try std.math.mul(usize, pixels, 3);
    const bytes_per_sample: usize = if (bits[0] == 8) 1 else 2;
    const expected_raster_bytes = try std.math.mul(usize, sample_count, bytes_per_sample);

    if (offsets_ref.count != counts_ref.count or offsets_ref.count == 0) {
        return TiffError.InvalidTagValue;
    }

    var total_strip_bytes: usize = 0;
    for (0..offsets_ref.count) |i| {
        const strip_count = try readU32Value(bytes, endian, counts_ref, i);
        total_strip_bytes = try std.math.add(usize, total_strip_bytes, strip_count);
    }
    if (total_strip_bytes != expected_raster_bytes) return TiffError.InvalidTagValue;

    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);

    var sample_index: usize = 0;
    for (0..offsets_ref.count) |strip| {
        const strip_offset = @as(usize, try readU32Value(bytes, endian, offsets_ref, strip));
        const strip_count = @as(usize, try readU32Value(bytes, endian, counts_ref, strip));
        if (strip_offset > bytes.len or bytes.len - strip_offset < strip_count) {
            return TiffError.TruncatedData;
        }
        const strip_bytes = bytes[strip_offset .. strip_offset + strip_count];
        if (strip_bytes.len % bytes_per_sample != 0) return TiffError.InvalidTagValue;

        if (bits[0] == 8) {
            for (strip_bytes) |value| {
                samples[sample_index] = value;
                sample_index += 1;
            }
        } else {
            var cursor: usize = 0;
            while (cursor < strip_bytes.len) : (cursor += 2) {
                samples[sample_index] = readU16(strip_bytes, cursor, endian);
                sample_index += 1;
            }
        }
    }

    if (sample_index != sample_count) return TiffError.InvalidTagValue;

    const icc_profile = if (icc_profile_ref) |ref| try readIccProfile(allocator, bytes, endian, ref) else null;
    errdefer if (icc_profile) |profile| allocator.free(profile);

    return .{
        .allocator = allocator,
        .width = width_usize,
        .height = height_usize,
        .bit_depth = @as(u8, @intCast(bits[0])),
        .samples = samples,
        .icc_profile = icc_profile,
    };
}

const ValueRef = struct {
    field_type: u16,
    count: usize,
    inline_value: u32,
    offset: ?usize,
};

fn readEntry(bytes: []const u8, offset: usize, endian: Endian) IfdEntry {
    return .{
        .tag = readU16(bytes, offset, endian),
        .field_type = readU16(bytes, offset + 2, endian),
        .count = readU32(bytes, offset + 4, endian),
        .value_or_offset = readU32(bytes, offset + 8, endian),
    };
}

fn valueRef(bytes: []const u8, entry: IfdEntry) !ValueRef {
    const elem_size = typeSize(entry.field_type) orelse return TiffError.InvalidTagValue;
    const count = @as(usize, @intCast(entry.count));
    const byte_count = try std.math.mul(usize, count, elem_size);
    const offset: ?usize = if (byte_count <= 4) null else @as(usize, entry.value_or_offset);
    if (offset) |start| {
        if (start > bytes.len or bytes.len - start < byte_count) return TiffError.TruncatedData;
    }
    return .{
        .field_type = entry.field_type,
        .count = count,
        .inline_value = entry.value_or_offset,
        .offset = offset,
    };
}

fn typeSize(field_type: u16) ?usize {
    return switch (field_type) {
        1, 2, 7 => 1,
        3 => 2,
        4 => 4,
        else => null,
    };
}

fn readIccProfile(allocator: std.mem.Allocator, bytes: []const u8, endian: Endian, ref: ValueRef) ![]u8 {
    if (ref.count == 0 or ref.count > max_icc_profile_bytes) return TiffError.InvalidTagValue;
    if (ref.field_type != 1 and ref.field_type != 7) return TiffError.InvalidTagValue;
    const out = try allocator.alloc(u8, ref.count);
    errdefer allocator.free(out);
    if (ref.offset) |offset| {
        @memcpy(out, bytes[offset..][0..ref.count]);
    } else {
        var inline_bytes: [4]u8 = undefined;
        switch (endian) {
            .little => {
                inline_bytes[0] = @as(u8, @truncate(ref.inline_value));
                inline_bytes[1] = @as(u8, @truncate(ref.inline_value >> 8));
                inline_bytes[2] = @as(u8, @truncate(ref.inline_value >> 16));
                inline_bytes[3] = @as(u8, @truncate(ref.inline_value >> 24));
            },
            .big => {
                inline_bytes[0] = @as(u8, @truncate(ref.inline_value >> 24));
                inline_bytes[1] = @as(u8, @truncate(ref.inline_value >> 16));
                inline_bytes[2] = @as(u8, @truncate(ref.inline_value >> 8));
                inline_bytes[3] = @as(u8, @truncate(ref.inline_value));
            },
        }
        @memcpy(out, inline_bytes[0..ref.count]);
    }
    return out;
}

fn readSingleU16(bytes: []const u8, endian: Endian, entry: IfdEntry) !u16 {
    const ref = try valueRef(bytes, entry);
    if (ref.count != 1) return TiffError.InvalidTagValue;
    return readU16Value(bytes, endian, ref, 0);
}

fn readSingleU32(bytes: []const u8, endian: Endian, entry: IfdEntry) !u32 {
    const ref = try valueRef(bytes, entry);
    if (ref.count != 1) return TiffError.InvalidTagValue;
    return readU32Value(bytes, endian, ref, 0);
}

fn readSampleFormat(bytes: []const u8, endian: Endian, entry: IfdEntry) !u16 {
    const ref = try valueRef(bytes, entry);
    if (ref.count == 0) return TiffError.InvalidTagValue;
    const first = try readU16Value(bytes, endian, ref, 0);
    var index: usize = 1;
    while (index < ref.count) : (index += 1) {
        if (try readU16Value(bytes, endian, ref, index) != first) {
            return TiffError.UnsupportedSampleFormat;
        }
    }
    return first;
}

fn readU16Value(bytes: []const u8, endian: Endian, ref: ValueRef, index: usize) !u16 {
    if (index >= ref.count) return TiffError.InvalidTagValue;
    return switch (ref.field_type) {
        3 => if (ref.offset) |offset|
            readU16(bytes, offset + index * 2, endian)
        else
            inlineU16(ref.inline_value, endian, index),
        else => TiffError.InvalidTagValue,
    };
}

fn readU32Value(bytes: []const u8, endian: Endian, ref: ValueRef, index: usize) !u32 {
    if (index >= ref.count) return TiffError.InvalidTagValue;
    return switch (ref.field_type) {
        3 => try readU16Value(bytes, endian, ref, index),
        4 => if (ref.offset) |offset| readU32(bytes, offset + index * 4, endian) else ref.inline_value,
        else => TiffError.InvalidTagValue,
    };
}

fn inlineU16(value: u32, endian: Endian, index: usize) u16 {
    return switch (endian) {
        .little => @as(u16, @truncate(value >> @as(u5, @intCast(index * 16)))),
        .big => @as(u16, @truncate(value >> @as(u5, @intCast((1 - index) * 16)))),
    };
}

fn readU16(bytes: []const u8, offset: usize, endian: Endian) u16 {
    return switch (endian) {
        .little => @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8),
        .big => (@as(u16, bytes[offset]) << 8) | @as(u16, bytes[offset + 1]),
    };
}

fn readU32(bytes: []const u8, offset: usize, endian: Endian) u32 {
    return switch (endian) {
        .little => @as(u32, bytes[offset]) |
            (@as(u32, bytes[offset + 1]) << 8) |
            (@as(u32, bytes[offset + 2]) << 16) |
            (@as(u32, bytes[offset + 3]) << 24),
        .big => (@as(u32, bytes[offset]) << 24) |
            (@as(u32, bytes[offset + 1]) << 16) |
            (@as(u32, bytes[offset + 2]) << 8) |
            @as(u32, bytes[offset + 3]),
    };
}

fn appendIfdEntryLe(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: u16,
    field_type: u16,
    count: u32,
    value: u32,
) !void {
    try appendU16Le(allocator, out, tag);
    try appendU16Le(allocator, out, field_type);
    try appendU32Le(allocator, out, count);
    try appendU32Le(allocator, out, value);
}

fn appendU16Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    try out.append(allocator, @as(u8, @truncate(value)));
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
}

fn appendU32Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    try out.append(allocator, @as(u8, @truncate(value)));
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value >> 16)));
    try out.append(allocator, @as(u8, @truncate(value >> 24)));
}
