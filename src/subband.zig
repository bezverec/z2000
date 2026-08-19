const std = @import("std");

pub const SubbandError = error{
    InvalidDimensions,
    TooManyLevels,
};

pub const Kind = enum(u8) {
    ll = 0,
    hl = 1,
    lh = 2,
    hh = 3,
};

pub const Rect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const Band = struct {
    kind: Kind,
    level: u8,
    rect: Rect,
    origin_x: u32 = 0,
    origin_y: u32 = 0,
};

pub const CodeBlock = struct {
    band_index: usize,
    rect: Rect,
};

pub fn makeBands(allocator: std.mem.Allocator, width: usize, height: usize, levels: u8) ![]Band {
    if (width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return SubbandError.InvalidDimensions;
    return makeBandsForRegion(allocator, 0, 0, @intCast(width), @intCast(height), levels);
}

pub fn makeBandsForRegion(
    allocator: std.mem.Allocator,
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    levels: u8,
) ![]Band {
    if (x1 <= x0 or y1 <= y0) return SubbandError.InvalidDimensions;
    if (levels > 32) return SubbandError.TooManyLevels;

    var list: std.ArrayList(Band) = .empty;
    errdefer list.deinit(allocator);

    const Shape = struct {
        width: usize,
        height: usize,
        x0: u32,
        y0: u32,
        x1: u32,
        y1: u32,
    };
    var shapes: [32]Shape = undefined;
    var cur_x0 = x0;
    var cur_y0 = y0;
    var cur_x1 = x1;
    var cur_y1 = y1;
    var cur_width: usize = x1 - x0;
    var cur_height: usize = y1 - y0;
    // Every requested decomposition is performed, even when the region has
    // already collapsed in one axis. ISO B.5 defines the subband coordinates of
    // such a level as an empty span rather than as absent, and the resulting
    // list is always `1 + 3 * levels` bands, so band position maps directly
    // onto the `QCD`/`QCC` band order and onto the resolutions the codestream
    // signals.
    var actual: u8 = 0;
    while (actual < levels) : (actual += 1) {
        shapes[actual] = .{ .width = cur_width, .height = cur_height, .x0 = cur_x0, .y0 = cur_y0, .x1 = cur_x1, .y1 = cur_y1 };
        cur_x0 = ceilDiv2(cur_x0);
        cur_y0 = ceilDiv2(cur_y0);
        cur_x1 = ceilDiv2(cur_x1);
        cur_y1 = ceilDiv2(cur_y1);
        cur_width = spanOf(cur_x0, cur_x1);
        cur_height = spanOf(cur_y0, cur_y1);
    }

    try list.append(allocator, .{
        .kind = .ll,
        .level = actual,
        .rect = .{ .x = 0, .y = 0, .width = cur_width, .height = cur_height },
        .origin_x = cur_x0,
        .origin_y = cur_y0,
    });

    var level = actual;
    while (level > 0) {
        const shape = shapes[level - 1];
        const low_x0 = ceilDiv2(shape.x0);
        const low_y0 = ceilDiv2(shape.y0);
        const low_x1 = ceilDiv2(shape.x1);
        const low_y1 = ceilDiv2(shape.y1);
        const high_x0 = shape.x0 / 2;
        const high_y0 = shape.y0 / 2;
        const high_x1 = shape.x1 / 2;
        const high_y1 = shape.y1 / 2;
        const low_w = spanOf(low_x0, low_x1);
        const low_h = spanOf(low_y0, low_y1);
        if (low_w > shape.width or low_h > shape.height) return SubbandError.InvalidDimensions;
        const high_w = shape.width - low_w;
        const high_h = shape.height - low_h;

        try appendBand(allocator, &list, .hl, level, .{
            .x = low_w,
            .y = 0,
            .width = high_w,
            .height = low_h,
        }, high_x0, low_y0);
        try appendBand(allocator, &list, .lh, level, .{
            .x = 0,
            .y = low_h,
            .width = low_w,
            .height = high_h,
        }, low_x0, high_y0);
        try appendBand(allocator, &list, .hh, level, .{
            .x = low_w,
            .y = low_h,
            .width = high_w,
            .height = high_h,
        }, high_x0, high_y0);

        if (spanOf(high_x0, high_x1) != high_w or spanOf(high_y0, high_y1) != high_h) {
            return SubbandError.InvalidDimensions;
        }

        level -= 1;
    }

    return list.toOwnedSlice(allocator);
}

pub fn makeCodeBlocks(
    allocator: std.mem.Allocator,
    bands: []const Band,
    block_width: usize,
    block_height: usize,
) ![]CodeBlock {
    if (block_width == 0 or block_height == 0) return SubbandError.InvalidDimensions;

    var widths: [97]usize = undefined;
    var heights: [97]usize = undefined;
    if (bands.len > widths.len) return SubbandError.TooManyLevels;
    @memset(widths[0..bands.len], block_width);
    @memset(heights[0..bands.len], block_height);
    return makeCodeBlocksForBandDimensions(
        allocator,
        bands,
        widths[0..bands.len],
        heights[0..bands.len],
    );
}

/// Partitions each subband with its own effective code-block dimensions.
/// JPEG 2000 Part 1 uses this when a nominal COD/COC code-block dimension is
/// larger than the precinct-induced span at a particular resolution.
pub fn makeCodeBlocksForBandDimensions(
    allocator: std.mem.Allocator,
    bands: []const Band,
    block_widths: []const usize,
    block_heights: []const usize,
) ![]CodeBlock {
    if (block_widths.len != bands.len or block_heights.len != bands.len) {
        return SubbandError.InvalidDimensions;
    }

    var list: std.ArrayList(CodeBlock) = .empty;
    errdefer list.deinit(allocator);

    for (bands, 0..) |band, band_index| {
        const block_width = block_widths[band_index];
        const block_height = block_heights[band_index];
        if (block_width == 0 or block_height == 0) return SubbandError.InvalidDimensions;
        const band_x0: u64 = band.origin_x;
        const band_y0: u64 = band.origin_y;
        var y: usize = 0;
        while (y < band.rect.height) {
            const h = anchoredBlockSpan(band_y0 + y, band.rect.height - y, block_height);
            var x: usize = 0;
            while (x < band.rect.width) {
                const w = anchoredBlockSpan(band_x0 + x, band.rect.width - x, block_width);
                try list.append(allocator, .{
                    .band_index = band_index,
                    .rect = .{
                        .x = band.rect.x + x,
                        .y = band.rect.y + y,
                        .width = w,
                        .height = h,
                    },
                });
                x += w;
            }
            y += h;
        }
    }

    return list.toOwnedSlice(allocator);
}

/// Partitions each packed subband on the component reference grid. The tile
/// origin must already satisfy the transform-parity policy of the caller;
/// `band.level` maps it into that subband's coordinate system.
pub fn makeCodeBlocksAnchored(
    allocator: std.mem.Allocator,
    bands: []const Band,
    block_width: usize,
    block_height: usize,
    tile_x0: u32,
    tile_y0: u32,
) ![]CodeBlock {
    _ = tile_x0;
    _ = tile_y0;
    return makeCodeBlocks(allocator, bands, block_width, block_height);
}

fn anchoredBlockSpan(global_start: u64, remaining: usize, block_size: usize) usize {
    const offset: usize = @intCast(global_start % block_size);
    const to_boundary = if (offset == 0) block_size else block_size - offset;
    return @min(remaining, to_boundary);
}

fn appendBand(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Band),
    kind: Kind,
    level: u8,
    rect: Rect,
    origin_x: u32,
    origin_y: u32,
) !void {
    // Empty bands stay in the list: dropping one shifts every later band's
    // index, which decides both the `QCD`/`QCC` entry a band reads and the
    // decomposition count derived from the list length.
    try list.append(allocator, .{ .kind = kind, .level = level, .rect = rect, .origin_x = origin_x, .origin_y = origin_y });
}

/// Subband spans are empty rather than negative when a region has collapsed.
fn spanOf(low: u32, high: u32) usize {
    return if (high > low) high - low else 0;
}

fn ceilDiv2(value: u32) u32 {
    return (value / 2) + @intFromBool((value & 1) != 0);
}
