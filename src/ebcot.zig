const std = @import("std");
const subband = @import("subband.zig");

pub const EbcotError = error{
    InvalidBlock,
};

const max_codeblock_area = 4096;

pub const PassKind = enum(u8) {
    significance = 0,
    refinement = 1,
    cleanup = 2,
};

pub const Context = enum(u8) {
    zero0 = 0,
    zero1 = 1,
    zero2 = 2,
    zero3 = 3,
    zero4 = 4,
    zero5 = 5,
    zero6 = 6,
    zero7 = 7,
    zero8 = 8,
    sign = 9,
    refinement = 10,
};

pub const SymbolKind = enum(u8) {
    zero_coding,
    sign,
    magnitude_refinement,
};

pub const Symbol = struct {
    pass_index: u16,
    kind: SymbolKind,
    context: Context,
    bit: bool,
    x: usize,
    y: usize,
    magnitude_bitplane: u8,
};

pub const Pass = struct {
    kind: PassKind,
    magnitude_bitplane: u8,
    first_symbol: usize,
    symbol_count: usize,
};

pub const EncodedBlock = struct {
    bitplanes: u8,
    non_zero_count: u32,
    passes: []Pass,
    symbols: []Symbol,

    pub fn deinit(self: *EncodedBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.passes);
        allocator.free(self.symbols);
        self.* = undefined;
    }
};

pub const EncodedBlockView = struct {
    bitplanes: u8,
    non_zero_count: u32,
    passes: []const Pass,
    symbols: []const Symbol,
};

pub const BlockScratch = struct {
    allocator: std.mem.Allocator,
    significant: std.ArrayList(bool) = .empty,
    visited: std.ArrayList(bool) = .empty,
    became_significant: std.ArrayList(bool) = .empty,
    passes: std.ArrayList(Pass) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,

    pub fn init(allocator: std.mem.Allocator) BlockScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BlockScratch) void {
        self.significant.deinit(self.allocator);
        self.visited.deinit(self.allocator);
        self.became_significant.deinit(self.allocator);
        self.passes.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.* = undefined;
    }

    fn reset(self: *BlockScratch) void {
        self.passes.clearRetainingCapacity();
        self.symbols.clearRetainingCapacity();
    }

    fn ensureBlockState(self: *BlockScratch, area: usize) !void {
        try self.significant.resize(self.allocator, area);
        try self.visited.resize(self.allocator, area);
        try self.became_significant.resize(self.allocator, area);
    }
};

pub fn encodeBlock(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !EncodedBlock {
    var scratch = BlockScratch.init(allocator);
    defer scratch.deinit();

    const view = try encodeBlockScratch(&scratch, plane, stride, rect);
    const pass_slice = try allocator.dupe(Pass, view.passes);
    errdefer allocator.free(pass_slice);
    const symbol_slice = try allocator.dupe(Symbol, view.symbols);

    return .{
        .bitplanes = view.bitplanes,
        .non_zero_count = view.non_zero_count,
        .passes = pass_slice,
        .symbols = symbol_slice,
    };
}

pub fn encodeBlockScratch(
    scratch: *BlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !EncodedBlockView {
    scratch.reset();
    try validateBlock(plane, stride, rect);

    var max_mag: u32 = 0;
    var non_zero_count: u32 = 0;
    var y: usize = 0;
    while (y < rect.height) : (y += 1) {
        const row = (rect.y + y) * stride + rect.x;
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            const mag = magnitude(plane[row + x]);
            max_mag = @max(max_mag, mag);
            if (mag != 0) non_zero_count += 1;
        }
    }

    const bitplanes = bitPlaneCount(max_mag);
    if (bitplanes == 0) {
        return .{
            .bitplanes = 0,
            .non_zero_count = 0,
            .passes = scratch.passes.items,
            .symbols = scratch.symbols.items,
        };
    }

    const area = try blockArea(rect);
    try scratch.ensureBlockState(area);
    const significant = scratch.significant.items;
    const visited = scratch.visited.items;
    const became_significant = scratch.became_significant.items;
    @memset(significant, false);

    var pass_index: u16 = 0;
    var bitplane_index = bitplanes;
    while (bitplane_index > 0) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        @memset(became_significant, false);

        if (bitplane == bitplanes - 1) {
            @memset(visited, false);
            try emitCleanupPass(
                scratch.allocator,
                &scratch.passes,
                &scratch.symbols,
                plane,
                stride,
                rect,
                bitplane,
                pass_index,
                significant,
                visited,
                became_significant,
            );
            pass_index += 1;
            continue;
        }

        @memset(visited, false);
        try emitSignificancePass(
            scratch.allocator,
            &scratch.passes,
            &scratch.symbols,
            plane,
            stride,
            rect,
            bitplane,
            pass_index,
            significant,
            visited,
            became_significant,
        );
        pass_index += 1;

        try emitRefinementPass(
            scratch.allocator,
            &scratch.passes,
            &scratch.symbols,
            plane,
            stride,
            rect,
            bitplane,
            pass_index,
            significant,
            became_significant,
        );
        pass_index += 1;

        try emitCleanupPass(
            scratch.allocator,
            &scratch.passes,
            &scratch.symbols,
            plane,
            stride,
            rect,
            bitplane,
            pass_index,
            significant,
            visited,
            became_significant,
        );
        pass_index += 1;
    }

    return .{
        .bitplanes = bitplanes,
        .non_zero_count = non_zero_count,
        .passes = scratch.passes.items,
        .symbols = scratch.symbols.items,
    };
}

fn emitSignificancePass(
    allocator: std.mem.Allocator,
    passes: *std.ArrayList(Pass),
    symbols: *std.ArrayList(Symbol),
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    pass_index: u16,
    significant: []bool,
    visited: []bool,
    became_significant: []bool,
) !void {
    const first_symbol = symbols.items.len;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (significant[index] or neighborSignificance(significant, rect.width, rect.height, pos.x, pos.y) == 0) continue;
        visited[index] = true;
        try emitZeroCoding(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index, significant);
        if (isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane)) {
            try emitSign(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index);
            significant[index] = true;
            became_significant[index] = true;
        }
    }

    try appendPass(allocator, passes, .significance, bitplane, first_symbol, symbols.items.len);
}

fn emitRefinementPass(
    allocator: std.mem.Allocator,
    passes: *std.ArrayList(Pass),
    symbols: *std.ArrayList(Symbol),
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    pass_index: u16,
    significant: []const bool,
    became_significant: []const bool,
) !void {
    const first_symbol = symbols.items.len;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (!significant[index] or became_significant[index]) continue;
        try symbols.append(allocator, .{
            .pass_index = pass_index,
            .kind = .magnitude_refinement,
            .context = .refinement,
            .bit = isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane),
            .x = pos.x,
            .y = pos.y,
            .magnitude_bitplane = bitplane,
        });
    }

    try appendPass(allocator, passes, .refinement, bitplane, first_symbol, symbols.items.len);
}

fn emitCleanupPass(
    allocator: std.mem.Allocator,
    passes: *std.ArrayList(Pass),
    symbols: *std.ArrayList(Symbol),
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    pass_index: u16,
    significant: []bool,
    visited: []const bool,
    became_significant: []bool,
) !void {
    const first_symbol = symbols.items.len;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (significant[index] or visited[index]) continue;
        try emitZeroCoding(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index, significant);
        if (isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane)) {
            try emitSign(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index);
            significant[index] = true;
            became_significant[index] = true;
        }
    }

    try appendPass(allocator, passes, .cleanup, bitplane, first_symbol, symbols.items.len);
}

fn emitZeroCoding(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayList(Symbol),
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    pos: ScanPos,
    bitplane: u8,
    pass_index: u16,
    significant: []const bool,
) !void {
    try symbols.append(allocator, .{
        .pass_index = pass_index,
        .kind = .zero_coding,
        .context = zeroContext(neighborSignificance(significant, rect.width, rect.height, pos.x, pos.y)),
        .bit = isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane),
        .x = pos.x,
        .y = pos.y,
        .magnitude_bitplane = bitplane,
    });
}

fn emitSign(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayList(Symbol),
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    pos: ScanPos,
    bitplane: u8,
    pass_index: u16,
) !void {
    try symbols.append(allocator, .{
        .pass_index = pass_index,
        .kind = .sign,
        .context = .sign,
        .bit = plane[(rect.y + pos.y) * stride + rect.x + pos.x] < 0,
        .x = pos.x,
        .y = pos.y,
        .magnitude_bitplane = bitplane,
    });
}

fn appendPass(
    allocator: std.mem.Allocator,
    passes: *std.ArrayList(Pass),
    kind: PassKind,
    bitplane: u8,
    first_symbol: usize,
    end_symbol: usize,
) !void {
    try passes.append(allocator, .{
        .kind = kind,
        .magnitude_bitplane = bitplane,
        .first_symbol = first_symbol,
        .symbol_count = end_symbol - first_symbol,
    });
}

const ScanPos = struct {
    x: usize,
    y: usize,
};

const ScanIterator = struct {
    width: usize,
    height: usize,
    stripe_y: usize = 0,
    x: usize = 0,
    dy: usize = 0,

    fn init(width: usize, height: usize) ScanIterator {
        return .{ .width = width, .height = height };
    }

    fn next(self: *ScanIterator) ?ScanPos {
        while (self.stripe_y < self.height) {
            const stripe_height = @min(@as(usize, 4), self.height - self.stripe_y);
            if (self.x < self.width and self.dy < stripe_height) {
                const pos = ScanPos{ .x = self.x, .y = self.stripe_y + self.dy };
                self.dy += 1;
                if (self.dy == stripe_height) {
                    self.dy = 0;
                    self.x += 1;
                }
                return pos;
            }

            self.stripe_y += 4;
            self.x = 0;
            self.dy = 0;
        }
        return null;
    }
};

fn validateBlock(plane: []const i32, stride: usize, rect: subband.Rect) !void {
    if (stride == 0 or rect.width == 0 or rect.height == 0) return EbcotError.InvalidBlock;
    if (try blockArea(rect) > max_codeblock_area) return EbcotError.InvalidBlock;
    if (rect.y >= plane.len / stride or rect.x >= stride) return EbcotError.InvalidBlock;
    const last_row = rect.y + rect.height - 1;
    const last_col = rect.x + rect.width - 1;
    if (last_col >= stride or last_row >= plane.len / stride) return EbcotError.InvalidBlock;
}

fn blockArea(rect: subband.Rect) !usize {
    return std.math.mul(usize, rect.width, rect.height) catch EbcotError.InvalidBlock;
}

fn neighborSignificance(significant: []const bool, width: usize, height: usize, x: usize, y: usize) u4 {
    var count: u4 = 0;
    const min_y = if (y == 0) 0 else y - 1;
    const max_y = @min(height - 1, y + 1);
    const min_x = if (x == 0) 0 else x - 1;
    const max_x = @min(width - 1, x + 1);

    var yy = min_y;
    while (yy <= max_y) : (yy += 1) {
        var xx = min_x;
        while (xx <= max_x) : (xx += 1) {
            if (xx == x and yy == y) continue;
            if (significant[localIndex(width, xx, yy)]) count += 1;
        }
    }
    return count;
}

fn zeroContext(neighbors: u4) Context {
    return @enumFromInt(@min(neighbors, 8));
}

fn localIndex(width: usize, x: usize, y: usize) usize {
    return y * width + x;
}

fn bitPlaneCount(max_mag: u32) u8 {
    if (max_mag == 0) return 0;
    return @as(u8, @intCast(32 - @clz(max_mag)));
}

fn magnitude(value: i32) u32 {
    const wide = @as(i64, value);
    const abs = if (wide < 0) -wide else wide;
    return @as(u32, @intCast(abs));
}

fn isMagnitudeBitSet(value: i32, bitplane: u8) bool {
    return ((magnitude(value) >> @as(u5, @intCast(bitplane))) & 1) != 0;
}
