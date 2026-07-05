const std = @import("std");
const image = @import("image.zig");

pub const TileGridError = error{
    InvalidTileGrid,
    InvalidImage,
    ImageTooLarge,
};

pub const Rect = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    pub fn width(self: Rect) u32 {
        return self.x1 - self.x0;
    }

    pub fn height(self: Rect) u32 {
        return self.y1 - self.y0;
    }
};

pub const Parameters = struct {
    xsiz: u32,
    ysiz: u32,
    xosiz: u32 = 0,
    yosiz: u32 = 0,
    xtsiz: u32,
    ytsiz: u32,
    xtosiz: u32 = 0,
    ytosiz: u32 = 0,
};

pub const Tile = struct {
    index: u64,
    column: u32,
    row: u32,
    rect: Rect,

    pub fn isEdge(self: Tile, grid: Grid) bool {
        return self.column == 0 or
            self.row == 0 or
            self.column + 1 == grid.columns or
            self.row + 1 == grid.rows;
    }
};

pub const Iterator = struct {
    grid: Grid,
    next_index: u64 = 0,

    pub fn next(self: *Iterator) TileGridError!?Tile {
        if (self.next_index >= self.grid.tileCount()) return null;
        const tile = try self.grid.tile(self.next_index);
        self.next_index += 1;
        return tile;
    }
};

pub const Grid = struct {
    params: Parameters,
    first_tile_x: u32,
    first_tile_y: u32,
    columns: u32,
    rows: u32,

    pub fn init(params: Parameters) TileGridError!Grid {
        try validateAxis(params.xsiz, params.xosiz, params.xtsiz, params.xtosiz);
        try validateAxis(params.ysiz, params.yosiz, params.ytsiz, params.ytosiz);

        const first_tile_x = firstTileIndex(params.xosiz, params.xtosiz, params.xtsiz);
        const first_tile_y = firstTileIndex(params.yosiz, params.ytosiz, params.ytsiz);
        const end_tile_x = endTileIndex(params.xsiz, params.xtosiz, params.xtsiz);
        const end_tile_y = endTileIndex(params.ysiz, params.ytosiz, params.ytsiz);
        if (end_tile_x <= first_tile_x or end_tile_y <= first_tile_y) return TileGridError.InvalidTileGrid;

        return .{
            .params = params,
            .first_tile_x = first_tile_x,
            .first_tile_y = first_tile_y,
            .columns = end_tile_x - first_tile_x,
            .rows = end_tile_y - first_tile_y,
        };
    }

    pub fn fromImageSize(width: usize, height: usize, tile_width: u32, tile_height: u32) TileGridError!Grid {
        if (width == 0 or height == 0) return TileGridError.InvalidTileGrid;
        if (width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) return TileGridError.ImageTooLarge;
        return init(.{
            .xsiz = @intCast(width),
            .ysiz = @intCast(height),
            .xtsiz = tile_width,
            .ytsiz = tile_height,
        });
    }

    pub fn tileCount(self: Grid) u64 {
        return @as(u64, self.columns) * @as(u64, self.rows);
    }

    pub fn isSingleTile(self: Grid) bool {
        return self.columns == 1 and self.rows == 1;
    }

    pub fn iterator(self: Grid) Iterator {
        return .{ .grid = self };
    }

    pub fn tile(self: Grid, tile_index: u64) TileGridError!Tile {
        if (tile_index >= self.tileCount()) return TileGridError.InvalidTileGrid;
        const column: u32 = @intCast(tile_index % self.columns);
        const row: u32 = @intCast(tile_index / self.columns);
        return .{
            .index = tile_index,
            .column = column,
            .row = row,
            .rect = try self.tileRectAt(column, row),
        };
    }

    pub fn tileRect(self: Grid, tile_index: u64) TileGridError!Rect {
        return (try self.tile(tile_index)).rect;
    }

    pub fn tileRectAt(self: Grid, column: u32, row: u32) TileGridError!Rect {
        if (column >= self.columns or row >= self.rows) return TileGridError.InvalidTileGrid;
        const tile_x = self.first_tile_x + column;
        const tile_y = self.first_tile_y + row;

        const x0 = @max(self.params.xosiz, axisStart(self.params.xtosiz, self.params.xtsiz, tile_x));
        const y0 = @max(self.params.yosiz, axisStart(self.params.ytosiz, self.params.ytsiz, tile_y));
        const x1 = @min(self.params.xsiz, axisStart(self.params.xtosiz, self.params.xtsiz, tile_x + 1));
        const y1 = @min(self.params.ysiz, axisStart(self.params.ytosiz, self.params.ytsiz, tile_y + 1));
        if (x1 <= x0 or y1 <= y0) return TileGridError.InvalidTileGrid;
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
    }
};

pub fn extractRgbTile(allocator: std.mem.Allocator, source: image.RgbImage, rect: Rect) TileGridError!image.RgbImage {
    try validateRgbRect(source, rect);
    const width: usize = rect.width();
    const height: usize = rect.height();
    const pixels = try checkedArea(@intCast(width), @intCast(height));
    const sample_count = try checkedSampleCount(pixels);
    const samples = allocator.alloc(u16, sample_count) catch return TileGridError.ImageTooLarge;
    errdefer allocator.free(samples);

    const tile_width: usize = width;
    const source_width: usize = source.width;
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const src_y = @as(usize, rect.y0) + row;
        const src_x = @as(usize, rect.x0);
        const src_start = (src_y * source_width + src_x) * 3;
        const dst_start = row * tile_width * 3;
        @memcpy(samples[dst_start..][0 .. tile_width * 3], source.samples[src_start..][0 .. tile_width * 3]);
    }

    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .bit_depth = source.bit_depth,
        .samples = samples,
        .icc_profile = null,
    };
}

pub fn copyRgbTileInto(destination: image.RgbImage, rect: Rect, tile: image.RgbImage) TileGridError!void {
    try validateRgbRect(destination, rect);
    if (tile.bit_depth != destination.bit_depth) return TileGridError.InvalidImage;
    if (tile.width != @as(usize, rect.width()) or tile.height != @as(usize, rect.height())) return TileGridError.InvalidImage;
    const tile_pixels = try checkedArea(@intCast(tile.width), @intCast(tile.height));
    if (tile.samples.len != try checkedSampleCount(tile_pixels)) return TileGridError.InvalidImage;

    const tile_width: usize = tile.width;
    const destination_width: usize = destination.width;
    var row: usize = 0;
    while (row < tile.height) : (row += 1) {
        const dst_y = @as(usize, rect.y0) + row;
        const dst_x = @as(usize, rect.x0);
        const dst_start = (dst_y * destination_width + dst_x) * 3;
        const src_start = row * tile_width * 3;
        @memcpy(destination.samples[dst_start..][0 .. tile_width * 3], tile.samples[src_start..][0 .. tile_width * 3]);
    }
}

fn validateAxis(end: u32, image_origin: u32, tile_size: u32, tile_origin: u32) TileGridError!void {
    if (end <= image_origin) return TileGridError.InvalidTileGrid;
    if (tile_size == 0) return TileGridError.InvalidTileGrid;
    if (tile_origin > image_origin) return TileGridError.InvalidTileGrid;
}

fn firstTileIndex(image_origin: u32, tile_origin: u32, tile_size: u32) u32 {
    return (image_origin - tile_origin) / tile_size;
}

fn endTileIndex(image_end: u32, tile_origin: u32, tile_size: u32) u32 {
    return ceilDivU32(image_end - tile_origin, tile_size);
}

fn axisStart(tile_origin: u32, tile_size: u32, tile_index: u32) u32 {
    const start = @as(u64, tile_origin) + @as(u64, tile_size) * @as(u64, tile_index);
    return @intCast(start);
}

fn ceilDivU32(numerator: u32, denominator: u32) u32 {
    return @intCast((@as(u64, numerator) + @as(u64, denominator) - 1) / @as(u64, denominator));
}

fn validateRgbRect(rgb: image.RgbImage, rect: Rect) TileGridError!void {
    if (rgb.width == 0 or rgb.height == 0) return TileGridError.InvalidImage;
    if (rgb.width > std.math.maxInt(u32) or rgb.height > std.math.maxInt(u32)) return TileGridError.ImageTooLarge;
    if (rect.x0 >= rect.x1 or rect.y0 >= rect.y1) return TileGridError.InvalidTileGrid;
    if (rect.x1 > rgb.width or rect.y1 > rgb.height) return TileGridError.InvalidTileGrid;
    const pixels = try checkedArea(@intCast(rgb.width), @intCast(rgb.height));
    if (rgb.samples.len != try checkedSampleCount(pixels)) return TileGridError.InvalidImage;
}

fn checkedArea(width: u32, height: u32) TileGridError!usize {
    const area = std.math.mul(u64, width, height) catch return TileGridError.ImageTooLarge;
    if (area > std.math.maxInt(usize)) return TileGridError.ImageTooLarge;
    return @intCast(area);
}

fn checkedSampleCount(pixels: usize) TileGridError!usize {
    return std.math.mul(usize, pixels, 3) catch TileGridError.ImageTooLarge;
}
