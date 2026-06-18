const std = @import("std");
const image = @import("image.zig");
const wavelet = @import("wavelet.zig");

pub const Options = struct {
    wavelet: wavelet.Wavelet = .reversible_5_3,
    levels: u8 = 3,
    quant_step: f32 = 1.0,
};

pub const Decoded = struct {
    image: image.Image,
    options: Options,

    pub fn deinit(self: *Decoded) void {
        self.image.deinit();
        self.* = undefined;
    }
};

pub const CodecError = error{
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeader,
    InvalidQuantStep,
    InvalidPayload,
};

const magic = "ZJ2K";
const version: u8 = 1;
const header_len = 4 + 1 + 1 + 1 + 1 + 4 + 4 + 4;

pub fn encodeImage(allocator: std.mem.Allocator, input: image.Image, options: Options) ![]u8 {
    if (options.quant_step <= 0.0 or !std.math.isFinite(options.quant_step)) {
        return CodecError.InvalidQuantStep;
    }

    const count = try std.math.mul(usize, input.width, input.height);
    if (count != input.pixels.len) return CodecError.InvalidPayload;

    var coeffs = try allocator.alloc(f32, count);
    defer allocator.free(coeffs);

    for (input.pixels, 0..) |pixel, i| {
        coeffs[i] = @as(f32, @floatFromInt(pixel)) - 128.0;
    }

    const levels_written = try wavelet.forward2D(
        allocator,
        coeffs,
        input.width,
        input.height,
        options.levels,
        options.wavelet,
    );

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, magic);
    try out.append(allocator, version);
    try out.append(allocator, @intFromEnum(options.wavelet));
    try out.append(allocator, levels_written);
    try out.append(allocator, 0);
    try appendU32Le(allocator, &out, @as(u32, @intCast(input.width)));
    try appendU32Le(allocator, &out, @as(u32, @intCast(input.height)));
    try appendU32Le(allocator, &out, @as(u32, @bitCast(options.quant_step)));

    for (coeffs) |value| {
        const quantized = @round(value / options.quant_step);
        const clamped = std.math.clamp(quantized, -32768.0, 32767.0);
        try appendU16Le(allocator, &out, @as(u16, @bitCast(@as(i16, @intFromFloat(clamped)))));
    }

    return out.toOwnedSlice(allocator);
}

pub fn decodeImage(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    if (bytes.len < header_len) return CodecError.InvalidHeader;
    if (!std.mem.eql(u8, bytes[0..4], magic)) return CodecError.InvalidMagic;
    if (bytes[4] != version) return CodecError.UnsupportedVersion;

    const transform = try parseWavelet(bytes[5]);
    const levels = bytes[6];

    var cursor: usize = 8;
    const width = @as(usize, try readU32Le(bytes, &cursor));
    const height = @as(usize, try readU32Le(bytes, &cursor));
    const quant_step = @as(f32, @bitCast(try readU32Le(bytes, &cursor)));
    if (width == 0 or height == 0) return CodecError.InvalidHeader;
    if (quant_step <= 0.0 or !std.math.isFinite(quant_step)) return CodecError.InvalidQuantStep;

    const count = try std.math.mul(usize, width, height);
    if (bytes.len - cursor != count * 2) return CodecError.InvalidPayload;

    var coeffs = try allocator.alloc(f32, count);
    defer allocator.free(coeffs);

    for (0..count) |i| {
        const raw = try readU16Le(bytes, &cursor);
        const signed = @as(i16, @bitCast(raw));
        coeffs[i] = @as(f32, @floatFromInt(signed)) * quant_step;
    }

    try wavelet.inverse2D(allocator, coeffs, width, height, levels, transform);

    const pixels = try allocator.alloc(u8, count);
    errdefer allocator.free(pixels);

    for (coeffs, 0..) |value, i| {
        const reconstructed = @round(value + 128.0);
        pixels[i] = @intFromFloat(std.math.clamp(reconstructed, 0.0, 255.0));
    }

    return .{
        .image = .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        },
        .options = .{
            .wavelet = transform,
            .levels = levels,
            .quant_step = quant_step,
        },
    };
}

fn parseWavelet(byte: u8) !wavelet.Wavelet {
    return switch (byte) {
        0 => .reversible_5_3,
        1 => .irreversible_9_7,
        else => CodecError.InvalidHeader,
    };
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

fn readU16Le(bytes: []const u8, cursor: *usize) !u16 {
    if (bytes.len - cursor.* < 2) return CodecError.InvalidPayload;
    const value = @as(u16, bytes[cursor.*]) |
        (@as(u16, bytes[cursor.* + 1]) << 8);
    cursor.* += 2;
    return value;
}

fn readU32Le(bytes: []const u8, cursor: *usize) !u32 {
    if (bytes.len - cursor.* < 4) return CodecError.InvalidPayload;
    const value = @as(u32, bytes[cursor.*]) |
        (@as(u32, bytes[cursor.* + 1]) << 8) |
        (@as(u32, bytes[cursor.* + 2]) << 16) |
        (@as(u32, bytes[cursor.* + 3]) << 24);
    cursor.* += 4;
    return value;
}
