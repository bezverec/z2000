const std = @import("std");

pub const Image = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    pixels: []u8,

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const RgbImage = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    bit_depth: u8,
    samples: []u16,
    icc_profile: ?[]u8 = null,

    pub fn deinit(self: *RgbImage) void {
        if (self.icc_profile) |profile| self.allocator.free(profile);
        self.allocator.free(self.samples);
        self.* = undefined;
    }
};

pub const ImageError = error{
    InvalidPgm,
    UnsupportedMaxValue,
    TruncatedImage,
};

pub fn readPgm(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Image {
    const max_file_size = 512 * 1024 * 1024;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);

    const header = try parsePgmHeader(bytes);
    const count = try std.math.mul(usize, header.width, header.height);
    if (bytes.len - header.raster_offset < count) return ImageError.TruncatedImage;

    const pixels = try allocator.alloc(u8, count);
    @memcpy(pixels, bytes[header.raster_offset .. header.raster_offset + count]);

    return .{
        .allocator = allocator,
        .width = header.width,
        .height = header.height,
        .pixels = pixels,
    };
}

pub fn writePgm(io: std.Io, image: Image, path: []const u8) !void {
    var header: [64]u8 = undefined;
    const header_bytes = try std.fmt.bufPrint(&header, "P5\n{} {}\n255\n", .{
        image.width,
        image.height,
    });

    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, header_bytes);
    try file.writeStreamingAll(io, image.pixels);
}

const PgmHeader = struct {
    width: usize,
    height: usize,
    raster_offset: usize,
};

fn parsePgmHeader(bytes: []const u8) !PgmHeader {
    var cursor: usize = 0;
    const magic = try nextToken(bytes, &cursor);
    if (!std.mem.eql(u8, magic, "P5")) return ImageError.InvalidPgm;

    const width_token = try nextToken(bytes, &cursor);
    const height_token = try nextToken(bytes, &cursor);
    const max_token = try nextToken(bytes, &cursor);

    const width = try std.fmt.parseInt(usize, width_token, 10);
    const height = try std.fmt.parseInt(usize, height_token, 10);
    const max_value = try std.fmt.parseInt(u16, max_token, 10);
    if (width == 0 or height == 0) return ImageError.InvalidPgm;
    if (max_value != 255) return ImageError.UnsupportedMaxValue;

    if (cursor >= bytes.len or !std.ascii.isWhitespace(bytes[cursor])) {
        return ImageError.InvalidPgm;
    }
    cursor += 1;

    return .{
        .width = width,
        .height = height,
        .raster_offset = cursor,
    };
}

fn nextToken(bytes: []const u8, cursor: *usize) ![]const u8 {
    skipWhitespaceAndComments(bytes, cursor);
    if (cursor.* >= bytes.len) return ImageError.InvalidPgm;

    const start = cursor.*;
    while (cursor.* < bytes.len and !std.ascii.isWhitespace(bytes[cursor.*])) {
        cursor.* += 1;
    }
    return bytes[start..cursor.*];
}

fn skipWhitespaceAndComments(bytes: []const u8, cursor: *usize) void {
    while (cursor.* < bytes.len) {
        if (std.ascii.isWhitespace(bytes[cursor.*])) {
            cursor.* += 1;
            continue;
        }

        if (bytes[cursor.*] == '#') {
            while (cursor.* < bytes.len and bytes[cursor.*] != '\n') {
                cursor.* += 1;
            }
            continue;
        }

        break;
    }
}
