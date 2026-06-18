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
};

pub const CodeBlock = struct {
    band_index: usize,
    rect: Rect,
};

pub fn makeBands(allocator: std.mem.Allocator, width: usize, height: usize, levels: u8) ![]Band {
    if (width == 0 or height == 0) return SubbandError.InvalidDimensions;
    if (levels > 32) return SubbandError.TooManyLevels;

    var list: std.ArrayList(Band) = .empty;
    errdefer list.deinit(allocator);

    var shapes: [32]Rect = undefined;
    var cur_width = width;
    var cur_height = height;
    var actual: u8 = 0;
    while (actual < levels and (cur_width > 1 or cur_height > 1)) : (actual += 1) {
        shapes[actual] = .{ .x = 0, .y = 0, .width = cur_width, .height = cur_height };
        cur_width = lowCount(cur_width);
        cur_height = lowCount(cur_height);
    }

    try list.append(allocator, .{
        .kind = .ll,
        .level = actual,
        .rect = .{ .x = 0, .y = 0, .width = cur_width, .height = cur_height },
    });

    var level = actual;
    while (level > 0) {
        const shape = shapes[level - 1];
        const low_w = lowCount(shape.width);
        const low_h = lowCount(shape.height);
        const high_w = shape.width - low_w;
        const high_h = shape.height - low_h;

        try appendBand(allocator, &list, .hl, level, .{
            .x = low_w,
            .y = 0,
            .width = high_w,
            .height = low_h,
        });
        try appendBand(allocator, &list, .lh, level, .{
            .x = 0,
            .y = low_h,
            .width = low_w,
            .height = high_h,
        });
        try appendBand(allocator, &list, .hh, level, .{
            .x = low_w,
            .y = low_h,
            .width = high_w,
            .height = high_h,
        });

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
        var y: usize = 0;
        while (y < band.rect.height) : (y += block_height) {
            const h = @min(block_height, band.rect.height - y);
            var x: usize = 0;
            while (x < band.rect.width) : (x += block_width) {
                const w = @min(block_width, band.rect.width - x);
                try list.append(allocator, .{
                    .band_index = band_index,
                    .rect = .{
                        .x = band.rect.x + x,
                        .y = band.rect.y + y,
                        .width = w,
                        .height = h,
                    },
                });
            }
        }
    }

    return list.toOwnedSlice(allocator);
}

fn appendBand(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Band),
    kind: Kind,
    level: u8,
    rect: Rect,
) !void {
    if (rect.width == 0 or rect.height == 0) return;
    try list.append(allocator, .{ .kind = kind, .level = level, .rect = rect });
}

fn lowCount(n: usize) usize {
    return (n + 1) / 2;
}
