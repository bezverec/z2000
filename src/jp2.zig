const std = @import("std");
const image = @import("image.zig");

pub const Jp2Error = error{
    ImageTooLarge,
    CodestreamTooLarge,
    InvalidBox,
    MissingRequiredBox,
    UnsupportedColorSpace,
    UnsupportedProfile,
};

pub const Info = struct {
    width: u32,
    height: u32,
    components: u16,
    bits_per_component: u8,
    codestream_bytes: usize,
};

const BoxType = enum(u32) {
    signature = fourcc("jP  "),
    file_type = fourcc("ftyp"),
    jp2_header = fourcc("jp2h"),
    image_header = fourcc("ihdr"),
    color = fourcc("colr"),
    contiguous_codestream = fourcc("jp2c"),
};

const signature_payload = [_]u8{ 0x0d, 0x0a, 0x87, 0x0a };
const brand_jp2 = fourcc("jp2 ");

pub fn wrapRgbCodestream(
    allocator: std.mem.Allocator,
    input: image.RgbImage,
    codestream: []const u8,
) ![]u8 {
    if (input.width == 0 or input.height == 0) return Jp2Error.InvalidBox;
    if (input.width > std.math.maxInt(u32) or input.height > std.math.maxInt(u32)) {
        return Jp2Error.ImageTooLarge;
    }
    if (codestream.len > std.math.maxInt(u32) - 8) return Jp2Error.CodestreamTooLarge;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendBox(allocator, &out, .signature, signature_payload[0..]);

    var ftyp: std.ArrayList(u8) = .empty;
    defer ftyp.deinit(allocator);
    try appendFourcc(allocator, &ftyp, "jp2 ");
    try appendU32Be(allocator, &ftyp, 0);
    try appendFourcc(allocator, &ftyp, "jp2 ");
    try appendBox(allocator, &out, .file_type, ftyp.items);

    var jp2h: std.ArrayList(u8) = .empty;
    defer jp2h.deinit(allocator);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(allocator);
    try appendU32Be(allocator, &ihdr, @as(u32, @intCast(input.height)));
    try appendU32Be(allocator, &ihdr, @as(u32, @intCast(input.width)));
    try appendU16Be(allocator, &ihdr, 3);
    try ihdr.append(allocator, input.bit_depth - 1);
    try ihdr.append(allocator, 7);
    try ihdr.append(allocator, 0);
    try ihdr.append(allocator, 0);
    try appendBox(allocator, &jp2h, .image_header, ihdr.items);

    var colr: std.ArrayList(u8) = .empty;
    defer colr.deinit(allocator);
    try colr.append(allocator, 1);
    try colr.append(allocator, 0);
    try colr.append(allocator, 0);
    try appendU32Be(allocator, &colr, 16);
    try appendBox(allocator, &jp2h, .color, colr.items);
    try appendBox(allocator, &out, .jp2_header, jp2h.items);

    try appendBox(allocator, &out, .contiguous_codestream, codestream);
    return out.toOwnedSlice(allocator);
}

pub fn parseInfo(bytes: []const u8) !Info {
    var cursor: usize = 0;
    var saw_signature = false;
    var saw_ftyp = false;
    var saw_jp2h = false;
    var saw_jp2c = false;
    var box_index: usize = 0;
    var info: Info = .{
        .width = 0,
        .height = 0,
        .components = 0,
        .bits_per_component = 0,
        .codestream_bytes = 0,
    };

    while (cursor < bytes.len) {
        const box = try nextBox(bytes, &cursor);
        if (box_index == 0 and box.kind != @intFromEnum(BoxType.signature)) return Jp2Error.InvalidBox;
        if (box_index == 1 and box.kind != @intFromEnum(BoxType.file_type)) return Jp2Error.InvalidBox;
        switch (box.kind) {
            @intFromEnum(BoxType.signature) => {
                if (box_index != 0 or saw_signature) return Jp2Error.InvalidBox;
                if (box.payload.len != signature_payload.len or
                    !std.mem.eql(u8, box.payload, signature_payload[0..]))
                {
                    return Jp2Error.InvalidBox;
                }
                saw_signature = true;
            },
            @intFromEnum(BoxType.file_type) => {
                if (box_index != 1 or saw_ftyp) return Jp2Error.InvalidBox;
                try validateFileTypeBox(box.payload);
                saw_ftyp = true;
            },
            @intFromEnum(BoxType.jp2_header) => {
                if (!saw_ftyp or saw_jp2h or saw_jp2c) return Jp2Error.InvalidBox;
                try parseJp2Header(box.payload, &info);
                saw_jp2h = true;
            },
            @intFromEnum(BoxType.contiguous_codestream) => {
                if (!saw_jp2h or saw_jp2c) return Jp2Error.InvalidBox;
                info.codestream_bytes = box.payload.len;
                saw_jp2c = true;
            },
            else => {},
        }
        box_index += 1;
    }

    if (!saw_signature or !saw_ftyp or !saw_jp2h or !saw_jp2c) {
        return Jp2Error.MissingRequiredBox;
    }
    return info;
}

pub fn extractCodestream(bytes: []const u8) ![]const u8 {
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const box = try nextBox(bytes, &cursor);
        if (box.kind == @intFromEnum(BoxType.contiguous_codestream)) {
            return box.payload;
        }
    }
    return Jp2Error.MissingRequiredBox;
}

const Box = struct {
    kind: u32,
    payload: []const u8,
};

fn parseJp2Header(bytes: []const u8, info: *Info) !void {
    var cursor: usize = 0;
    var saw_ihdr = false;
    var saw_colr = false;
    var box_index: usize = 0;
    while (cursor < bytes.len) {
        const box = try nextBox(bytes, &cursor);
        if (box_index == 0 and box.kind != @intFromEnum(BoxType.image_header)) return Jp2Error.InvalidBox;
        switch (box.kind) {
            @intFromEnum(BoxType.image_header) => {
                if (box_index != 0 or saw_ihdr) return Jp2Error.InvalidBox;
                if (box.payload.len != 14) return Jp2Error.InvalidBox;
                info.height = readU32Be(box.payload, 0);
                info.width = readU32Be(box.payload, 4);
                info.components = readU16Be(box.payload, 8);
                const bpc = box.payload[10];
                const compression_type = box.payload[11];
                const colorspace_unknown = box.payload[12];
                const intellectual_property = box.payload[13];
                if (info.width == 0 or info.height == 0) return Jp2Error.InvalidBox;
                if (compression_type != 7 or colorspace_unknown != 0 or intellectual_property != 0) {
                    return Jp2Error.UnsupportedProfile;
                }
                if ((bpc & 0x80) != 0) return Jp2Error.UnsupportedProfile;
                info.bits_per_component = bpc + 1;
                if (info.components != 3 or (info.bits_per_component != 8 and info.bits_per_component != 16)) {
                    return Jp2Error.UnsupportedColorSpace;
                }
                saw_ihdr = true;
            },
            @intFromEnum(BoxType.color) => {
                if (!saw_ihdr or saw_colr) return Jp2Error.InvalidBox;
                if (box.payload.len < 7) return Jp2Error.InvalidBox;
                const method = box.payload[0];
                const precedence = box.payload[1];
                const approximation = box.payload[2];
                const enum_cs = readU32Be(box.payload, 3);
                if (precedence != 0 or approximation != 0) return Jp2Error.UnsupportedProfile;
                if (method != 1 or enum_cs != 16) return Jp2Error.UnsupportedColorSpace;
                if (box.payload.len != 7) return Jp2Error.UnsupportedProfile;
                saw_colr = true;
            },
            else => {},
        }
        box_index += 1;
    }
    if (!saw_ihdr or !saw_colr) return Jp2Error.MissingRequiredBox;
}

fn validateFileTypeBox(payload: []const u8) !void {
    if (payload.len < 8 or (payload.len - 8) % 4 != 0) return Jp2Error.InvalidBox;
    if (readU32Be(payload, 0) != brand_jp2) return Jp2Error.UnsupportedProfile;

    var compatible = false;
    var cursor: usize = 8;
    while (cursor < payload.len) : (cursor += 4) {
        if (readU32Be(payload, cursor) == brand_jp2) compatible = true;
    }
    if (!compatible) return Jp2Error.UnsupportedProfile;
}

fn nextBox(bytes: []const u8, cursor: *usize) !Box {
    if (bytes.len - cursor.* < 8) return Jp2Error.InvalidBox;
    const start = cursor.*;
    const length = readU32Be(bytes, start);
    const kind = readU32Be(bytes, start + 4);
    if (length == 0 or length == 1) return Jp2Error.UnsupportedProfile;
    if (length < 8) return Jp2Error.InvalidBox;
    const end = try std.math.add(usize, start, length);
    if (end > bytes.len) return Jp2Error.InvalidBox;
    cursor.* = end;
    return .{
        .kind = kind,
        .payload = bytes[start + 8 .. end],
    };
}

fn appendBox(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    box_type: BoxType,
    payload: []const u8,
) !void {
    const length = try std.math.add(u32, 8, @as(u32, @intCast(payload.len)));
    try appendU32Be(allocator, out, length);
    try appendU32Be(allocator, out, @intFromEnum(box_type));
    try out.appendSlice(allocator, payload);
}

fn appendFourcc(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: *const [4]u8) !void {
    try out.appendSlice(allocator, value);
}

fn appendU16Be(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value)));
}

fn appendU32Be(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    try out.append(allocator, @as(u8, @truncate(value >> 24)));
    try out.append(allocator, @as(u8, @truncate(value >> 16)));
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value)));
}

fn readU16Be(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | @as(u16, bytes[offset + 1]);
}

fn readU32Be(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        @as(u32, bytes[offset + 3]);
}

fn fourcc(comptime value: *const [4]u8) u32 {
    return (@as(u32, value[0]) << 24) |
        (@as(u32, value[1]) << 16) |
        (@as(u32, value[2]) << 8) |
        @as(u32, value[3]);
}
