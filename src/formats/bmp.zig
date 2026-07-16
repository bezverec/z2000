const std = @import("std");
const image = @import("../image.zig");

const file_header_size: usize = 14;
const info_header_size: usize = 40;
const max_file_size: usize = 1024 * 1024 * 1024;

pub const BmpError = error{
    InvalidSignature,
    InvalidFileSize,
    InvalidReservedField,
    UnsupportedDibHeader,
    InvalidDimensions,
    InvalidPlanes,
    UnsupportedBitDepth,
    UnsupportedCompression,
    UnsupportedPalette,
    InvalidPixelOffset,
    InvalidImageSize,
    TruncatedImage,
};

/// Reads the bounded BMP input profile: Windows BITMAPINFOHEADER, BI_RGB,
/// 24- or 32-bit BGR pixels. Both bottom-up and top-down row order are
/// accepted. The fourth byte of a 32-bit BI_RGB pixel is reserved and ignored.
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
    if (bytes.len < file_header_size + info_header_size) return BmpError.TruncatedImage;
    if (bytes[0] != 'B' or bytes[1] != 'M') return BmpError.InvalidSignature;
    if (readU32(bytes, 2) != bytes.len) return BmpError.InvalidFileSize;
    if (readU16(bytes, 6) != 0 or readU16(bytes, 8) != 0) return BmpError.InvalidReservedField;

    const pixel_offset: usize = readU32(bytes, 10);
    if (readU32(bytes, 14) != info_header_size) return BmpError.UnsupportedDibHeader;

    const width_signed = readI32(bytes, 18);
    const height_signed = readI32(bytes, 22);
    if (width_signed <= 0 or height_signed == 0 or height_signed == std.math.minInt(i32)) {
        return BmpError.InvalidDimensions;
    }
    if (readU16(bytes, 26) != 1) return BmpError.InvalidPlanes;

    const bit_depth = readU16(bytes, 28);
    if (bit_depth != 24 and bit_depth != 32) return BmpError.UnsupportedBitDepth;
    if (readU32(bytes, 30) != 0) return BmpError.UnsupportedCompression;
    if (readU32(bytes, 46) != 0) return BmpError.UnsupportedPalette;

    const width: usize = @intCast(width_signed);
    const height: usize = @intCast(if (height_signed < 0) -height_signed else height_signed);
    const bytes_per_pixel: usize = bit_depth / 8;
    const packed_row_bytes = std.math.mul(usize, width, bytes_per_pixel) catch
        return BmpError.InvalidDimensions;
    const padded = std.math.add(usize, packed_row_bytes, 3) catch
        return BmpError.InvalidDimensions;
    const row_stride = padded & ~@as(usize, 3);
    const raster_bytes = std.math.mul(usize, row_stride, height) catch
        return BmpError.InvalidDimensions;

    if (pixel_offset < file_header_size + info_header_size or pixel_offset > bytes.len) {
        return BmpError.InvalidPixelOffset;
    }
    const raster_end = std.math.add(usize, pixel_offset, raster_bytes) catch
        return BmpError.InvalidImageSize;
    if (raster_end > bytes.len) return BmpError.TruncatedImage;
    if (raster_end != bytes.len) return BmpError.InvalidImageSize;
    const declared_image_size: usize = readU32(bytes, 34);
    if (declared_image_size != 0 and declared_image_size != raster_bytes) {
        return BmpError.InvalidImageSize;
    }

    const pixel_count = std.math.mul(usize, width, height) catch
        return BmpError.InvalidDimensions;
    const sample_count = std.math.mul(usize, pixel_count, 3) catch
        return BmpError.InvalidDimensions;
    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);

    for (0..height) |output_y| {
        const storage_y = if (height_signed < 0) output_y else height - 1 - output_y;
        const row_start = pixel_offset + storage_y * row_stride;
        for (0..width) |x| {
            const source = row_start + x * bytes_per_pixel;
            const target = (output_y * width + x) * 3;
            samples[target] = bytes[source + 2];
            samples[target + 1] = bytes[source + 1];
            samples[target + 2] = bytes[source];
        }
    }

    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .bit_depth = 8,
        .samples = samples,
    };
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn readI32(bytes: []const u8, offset: usize) i32 {
    return @bitCast(readU32(bytes, offset));
}
