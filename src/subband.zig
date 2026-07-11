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
    var actual: u8 = 0;
    while (actual < levels and (cur_width > 1 or cur_height > 1)) : (actual += 1) {
        const next_x0 = ceilDiv2(cur_x0);
        const next_y0 = ceilDiv2(cur_y0);
        const next_x1 = ceilDiv2(cur_x1);
        const next_y1 = ceilDiv2(cur_y1);
        if (next_x1 <= next_x0 or next_y1 <= next_y0) break;
        shapes[actual] = .{ .width = cur_width, .height = cur_height, .x0 = cur_x0, .y0 = cur_y0, .x1 = cur_x1, .y1 = cur_y1 };
        cur_x0 = next_x0;
        cur_y0 = next_y0;
        cur_x1 = next_x1;
        cur_y1 = next_y1;
        cur_width = cur_x1 - cur_x0;
        cur_height = cur_y1 - cur_y0;
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
        const low_w: usize = low_x1 - low_x0;
        const low_h: usize = low_y1 - low_y0;
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

        if (high_x1 - high_x0 != high_w or high_y1 - high_y0 != high_h) {
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

    var list: std.ArrayList(CodeBlock) = .empty;
    errdefer list.deinit(allocator);

    for (bands, 0..) |band, band_index| {
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
    if (rect.width == 0 or rect.height == 0) return;
    try list.append(allocator, .{ .kind = kind, .level = level, .rect = rect, .origin_x = origin_x, .origin_y = origin_y });
}

fn ceilDiv2(value: u32) u32 {
    return (value / 2) + @intFromBool((value & 1) != 0);
}
