const std = @import("std");
const subband = @import("subband.zig");

pub const BitplaneError = error{
    InvalidBlock,
    TruncatedData,
    TrailingData,
};

pub const EncodedBlock = struct {
    active_rect: subband.Rect,
    bitplanes: u8,
    non_zero_count: u32,
    significance_bytes: []u8,
    refinement_bytes: []u8,
    cleanup_bytes: []u8,
    bytes: []u8,

    pub fn deinit(self: *EncodedBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.significance_bytes);
        allocator.free(self.refinement_bytes);
        allocator.free(self.cleanup_bytes);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub fn encodeBlock(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !EncodedBlock {
    if (stride == 0 or rect.width == 0 or rect.height == 0) return BitplaneError.InvalidBlock;
    if (rect.y >= plane.len / stride or rect.x >= stride) return BitplaneError.InvalidBlock;
    const last_row = rect.y + rect.height - 1;
    const last_col = rect.x + rect.width - 1;
    if (last_col >= stride or last_row >= plane.len / stride) return BitplaneError.InvalidBlock;

    var active_min_x = rect.width;
    var active_min_y = rect.height;
    var active_max_x: usize = 0;
    var active_max_y: usize = 0;
    var non_zero_count: u32 = 0;
    var y: usize = 0;
    while (y < rect.height) : (y += 1) {
        const row = (rect.y + y) * stride;
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            if (plane[row + rect.x + x] != 0) {
                active_min_x = @min(active_min_x, x);
                active_min_y = @min(active_min_y, y);
                active_max_x = @max(active_max_x, x);
                active_max_y = @max(active_max_y, y);
                non_zero_count += 1;
            }
        }
    }

    if (non_zero_count == 0) {
        return .{
            .active_rect = .{ .x = rect.x, .y = rect.y, .width = 0, .height = 0 },
            .bitplanes = 0,
            .non_zero_count = 0,
            .significance_bytes = try allocator.alloc(u8, 0),
            .refinement_bytes = try allocator.alloc(u8, 0),
            .cleanup_bytes = try allocator.alloc(u8, 0),
            .bytes = try allocator.alloc(u8, 0),
        };
    }

    const active_rect = subband.Rect{
        .x = rect.x + active_min_x,
        .y = rect.y + active_min_y,
        .width = active_max_x - active_min_x + 1,
        .height = active_max_y - active_min_y + 1,
    };

    var max_mag: u32 = 0;
    y = 0;
    while (y < active_rect.height) : (y += 1) {
        const row = (active_rect.y + y) * stride;
        var x: usize = 0;
        while (x < active_rect.width) : (x += 1) {
            max_mag = @max(max_mag, magnitude(plane[row + active_rect.x + x]));
        }
    }

    const bitplanes = bitPlaneCount(max_mag);
    var significance = BitWriter.init(allocator);
    errdefer significance.deinit();
    var refinement = BitWriter.init(allocator);
    errdefer refinement.deinit();

    y = 0;
    while (y < active_rect.height) : (y += 1) {
        const row = (active_rect.y + y) * stride;
        var x: usize = 0;
        while (x < active_rect.width) : (x += 1) {
            const coeff = plane[row + active_rect.x + x];
            const mag = magnitude(coeff);
            const is_significant = mag != 0;
            try significance.writeBit(is_significant);
            if (is_significant) {
                try significance.writeBit(coeff < 0);
            }
        }
    }

    var bitplane_index = bitplanes;
    while (bitplane_index > 0) {
        bitplane_index -= 1;
        y = 0;
        while (y < active_rect.height) : (y += 1) {
            const row = (active_rect.y + y) * stride;
            var x: usize = 0;
            while (x < active_rect.width) : (x += 1) {
                const mag = magnitude(plane[row + active_rect.x + x]);
                if (mag != 0) {
                    try refinement.writeBit(((mag >> @as(u5, @intCast(bitplane_index))) & 1) != 0);
                }
            }
        }
    }

    const significance_bytes = try significance.finish();
    errdefer allocator.free(significance_bytes);
    const refinement_bytes = try refinement.finish();
    errdefer allocator.free(refinement_bytes);
    const cleanup_bytes = try allocator.alloc(u8, 0);
    errdefer allocator.free(cleanup_bytes);

    var combined: std.ArrayList(u8) = .empty;
    errdefer combined.deinit(allocator);
    try appendU32Be(allocator, &combined, @as(u32, @intCast(significance_bytes.len)));
    try combined.appendSlice(allocator, significance_bytes);
    try appendU32Be(allocator, &combined, @as(u32, @intCast(refinement_bytes.len)));
    try combined.appendSlice(allocator, refinement_bytes);
    try appendU32Be(allocator, &combined, @as(u32, @intCast(cleanup_bytes.len)));
    try combined.appendSlice(allocator, cleanup_bytes);

    return .{
        .active_rect = active_rect,
        .bitplanes = bitplanes,
        .non_zero_count = non_zero_count,
        .significance_bytes = significance_bytes,
        .refinement_bytes = refinement_bytes,
        .cleanup_bytes = cleanup_bytes,
        .bytes = try combined.toOwnedSlice(allocator),
    };
}

pub fn decodeBlockPasses(
    plane: []i32,
    stride: usize,
    rect: subband.Rect,
    bitplanes: u8,
    non_zero_count: u32,
    significance_bytes: []const u8,
    refinement_bytes: []const u8,
) !void {
    if (bitplanes == 0 and non_zero_count == 0 and rect.width == 0 and rect.height == 0) return;
    if (stride == 0 or rect.width == 0 or rect.height == 0) return BitplaneError.InvalidBlock;
    if (rect.y >= plane.len / stride or rect.x >= stride) return BitplaneError.InvalidBlock;
    const last_row = rect.y + rect.height - 1;
    const last_col = rect.x + rect.width - 1;
    if (last_col >= stride or last_row >= plane.len / stride) return BitplaneError.InvalidBlock;

    var sig_reader = BitReader.init(significance_bytes);
    var ref_reader = BitReader.init(refinement_bytes);

    var signs_read: u32 = 0;
    var y: usize = 0;
    while (y < rect.height) : (y += 1) {
        const row = (rect.y + y) * stride;
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            if (try sig_reader.readBit()) {
                const negative = try sig_reader.readBit();
                plane[row + rect.x + x] = if (negative) -1 else 1;
                signs_read += 1;
            }
        }
    }

    if (signs_read != non_zero_count) return BitplaneError.InvalidBlock;

    var bitplane_index = bitplanes;
    while (bitplane_index > 0) {
        bitplane_index -= 1;
        y = 0;
        while (y < rect.height) : (y += 1) {
            const row = (rect.y + y) * stride;
            var x: usize = 0;
            while (x < rect.width) : (x += 1) {
                const index = row + rect.x + x;
                if (plane[index] == 0) continue;
                if (try ref_reader.readBit()) {
                    const bit = @as(i32, 1) << @as(u5, @intCast(bitplane_index));
                    if (plane[index] > 0) {
                        plane[index] += bit;
                    } else {
                        plane[index] -= bit;
                    }
                }
            }
        }
    }

    y = 0;
    while (y < rect.height) : (y += 1) {
        const row = (rect.y + y) * stride;
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            const index = row + rect.x + x;
            if (plane[index] > 0) {
                plane[index] -= 1;
            } else if (plane[index] < 0) {
                plane[index] += 1;
            }
        }
    }
}

pub fn decodeBlock(
    plane: []i32,
    stride: usize,
    rect: subband.Rect,
    bitplanes: u8,
    non_zero_count: u32,
    bytes: []const u8,
) !void {
    if (bitplanes == 0 and non_zero_count == 0 and rect.width == 0 and rect.height == 0) {
        if (bytes.len != 0) return BitplaneError.TrailingData;
        return;
    }

    var cursor = ByteCursor.init(bytes);
    const significance_bytes = try cursor.readLengthPrefixed();
    const refinement_bytes = try cursor.readLengthPrefixed();
    _ = try cursor.readLengthPrefixed();
    if (!cursor.finished()) return BitplaneError.TrailingData;
    try decodeBlockPasses(
        plane,
        stride,
        rect,
        bitplanes,
        non_zero_count,
        significance_bytes,
        refinement_bytes,
    );
}

pub fn decodeBlockLegacy(
    plane: []i32,
    stride: usize,
    rect: subband.Rect,
    bitplanes: u8,
    non_zero_count: u32,
    bytes: []const u8,
) !void {
    if (bitplanes == 0 and non_zero_count == 0 and rect.width == 0 and rect.height == 0) {
        if (bytes.len != 0) return BitplaneError.TrailingData;
        return;
    }

    if (stride == 0 or rect.width == 0 or rect.height == 0) return BitplaneError.InvalidBlock;
    if (rect.y >= plane.len / stride or rect.x >= stride) return BitplaneError.InvalidBlock;
    const last_row = rect.y + rect.height - 1;
    const last_col = rect.x + rect.width - 1;
    if (last_col >= stride or last_row >= plane.len / stride) return BitplaneError.InvalidBlock;

    var reader = BitReader.init(bytes);

    var bitplane_index = bitplanes;
    while (bitplane_index > 0) {
        bitplane_index -= 1;
        var y: usize = 0;
        while (y < rect.height) : (y += 1) {
            const row = (rect.y + y) * stride;
            var x: usize = 0;
            while (x < rect.width) : (x += 1) {
                if (try reader.readBit()) {
                    plane[row + rect.x + x] |= @as(i32, 1) << @as(u5, @intCast(bitplane_index));
                }
            }
        }
    }

    var signs_read: u32 = 0;
    var y: usize = 0;
    while (y < rect.height) : (y += 1) {
        const row = (rect.y + y) * stride;
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            const index = row + rect.x + x;
            if (plane[index] != 0) {
                signs_read += 1;
                if (try reader.readBit()) plane[index] = -plane[index];
            }
        }
    }

    if (signs_read != non_zero_count) return BitplaneError.InvalidBlock;
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

const BitWriter = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    current: u8 = 0,
    used: u4 = 0,

    fn init(allocator: std.mem.Allocator) BitWriter {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *BitWriter) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    fn writeBit(self: *BitWriter, bit: bool) !void {
        if (bit) {
            self.current |= @as(u8, 1) << @as(u3, @intCast(7 - self.used));
        }
        self.used += 1;
        if (self.used == 8) {
            try self.bytes.append(self.allocator, self.current);
            self.current = 0;
            self.used = 0;
        }
    }

    fn writeUnary(self: *BitWriter, count: u32) !void {
        var i: u32 = 0;
        while (i < count) : (i += 1) try self.writeBit(false);
        try self.writeBit(true);
    }

    fn finish(self: *BitWriter) ![]u8 {
        if (self.used != 0) {
            try self.bytes.append(self.allocator, self.current);
            self.current = 0;
            self.used = 0;
        }
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

const ByteCursor = struct {
    bytes: []const u8,
    index: usize = 0,

    fn init(bytes: []const u8) ByteCursor {
        return .{ .bytes = bytes };
    }

    fn finished(self: ByteCursor) bool {
        return self.index == self.bytes.len;
    }

    fn readLengthPrefixed(self: *ByteCursor) ![]const u8 {
        if (self.bytes.len - self.index < 4) return BitplaneError.TruncatedData;
        const len = (@as(u32, self.bytes[self.index]) << 24) |
            (@as(u32, self.bytes[self.index + 1]) << 16) |
            (@as(u32, self.bytes[self.index + 2]) << 8) |
            self.bytes[self.index + 3];
        self.index += 4;
        if (self.bytes.len - self.index < len) return BitplaneError.TruncatedData;
        const start = self.index;
        self.index += @as(usize, len);
        return self.bytes[start..self.index];
    }
};

fn appendU32Be(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    try out.append(allocator, @as(u8, @truncate(value >> 24)));
    try out.append(allocator, @as(u8, @truncate(value >> 16)));
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value)));
}

const BitReader = struct {
    bytes: []const u8,
    byte_index: usize = 0,
    bit_index: u4 = 0,

    fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes };
    }

    fn readBit(self: *BitReader) !bool {
        if (self.byte_index >= self.bytes.len) return BitplaneError.TruncatedData;
        const value = (self.bytes[self.byte_index] & (@as(u8, 0x80) >> @as(u3, @intCast(self.bit_index)))) != 0;
        self.bit_index += 1;
        if (self.bit_index == 8) {
            self.byte_index += 1;
            self.bit_index = 0;
        }
        return value;
    }
};
