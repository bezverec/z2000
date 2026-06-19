const std = @import("std");

pub const PacketHeaderError = error{
    InvalidTagTree,
    InvalidMarkerStuffing,
    TruncatedHeader,
};

const TagTreeLevel = struct {
    start: usize,
    width: usize,
    height: usize,
};

pub const PacketHeaderWriter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    current: u8 = 0,
    bits_remaining: u4 = 8,
    has_bits: bool = false,

    pub fn init(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) PacketHeaderWriter {
        return .{ .allocator = allocator, .out = out };
    }

    pub fn writeBit(self: *PacketHeaderWriter, bit: bool) !void {
        if (bit) {
            self.current |= @as(u8, 1) << @intCast(self.bits_remaining - 1);
        }
        self.bits_remaining -= 1;
        self.has_bits = true;

        if (self.bits_remaining == 0) {
            try self.flushByte();
        }
    }

    pub fn writeBits(self: *PacketHeaderWriter, value: u64, bit_count: u6) !void {
        var index: u6 = bit_count;
        while (index > 0) {
            index -= 1;
            try self.writeBit(((value >> index) & 1) != 0);
        }
    }

    pub fn finish(self: *PacketHeaderWriter) !void {
        if (self.has_bits) try self.flushByte();
    }

    fn flushByte(self: *PacketHeaderWriter) !void {
        const flushed = self.current;
        try self.out.append(self.allocator, flushed);
        self.current = 0;
        self.bits_remaining = if (flushed == 0xff) 7 else 8;
        self.has_bits = false;
    }
};

pub const PacketHeaderReader = struct {
    bytes: []const u8,
    index: usize = 0,
    current: u8 = 0,
    bits_remaining: u4 = 0,
    previous: ?u8 = null,

    pub fn init(bytes: []const u8) PacketHeaderReader {
        return .{ .bytes = bytes };
    }

    pub fn readBit(self: *PacketHeaderReader) PacketHeaderError!bool {
        if (self.bits_remaining == 0) try self.loadByte();
        self.bits_remaining -= 1;
        return ((self.current >> @intCast(self.bits_remaining)) & 1) != 0;
    }

    pub fn byteAlign(self: *PacketHeaderReader) PacketHeaderError!void {
        if (self.bits_remaining == 0) return;
        const padding_mask = (@as(u16, 1) << self.bits_remaining) - 1;
        if ((@as(u16, self.current) & padding_mask) != 0) return PacketHeaderError.InvalidMarkerStuffing;
        self.bits_remaining = 0;
    }

    pub fn bytesConsumed(self: PacketHeaderReader) usize {
        return self.index;
    }

    fn loadByte(self: *PacketHeaderReader) PacketHeaderError!void {
        if (self.index >= self.bytes.len) return PacketHeaderError.TruncatedHeader;
        const byte = self.bytes[self.index];
        self.index += 1;

        if (self.previous == 0xff) {
            if ((byte & 0x80) != 0) return PacketHeaderError.InvalidMarkerStuffing;
            self.bits_remaining = 7;
        } else {
            self.bits_remaining = 8;
        }

        self.current = byte;
        self.previous = byte;
    }
};

pub const TagTreeEncoder = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    levels: []TagTreeLevel,
    values: []u32,
    lows: []u32,

    pub fn init(
        allocator: std.mem.Allocator,
        width: usize,
        height: usize,
        leaf_values: []const u32,
    ) !TagTreeEncoder {
        const layout = try makeTagTreeLayout(allocator, width, height);
        errdefer allocator.free(layout.levels);
        if (leaf_values.len != layout.levels[0].width * layout.levels[0].height) {
            return PacketHeaderError.InvalidTagTree;
        }

        const values = try allocator.alloc(u32, layout.node_count);
        errdefer allocator.free(values);
        const lows = try allocator.alloc(u32, layout.node_count);
        errdefer allocator.free(lows);
        @memset(lows, 0);
        @memcpy(values[0..leaf_values.len], leaf_values);

        var level: usize = 1;
        while (level < layout.levels.len) : (level += 1) {
            const child = layout.levels[level - 1];
            const parent = layout.levels[level];
            var y: usize = 0;
            while (y < parent.height) : (y += 1) {
                var x: usize = 0;
                while (x < parent.width) : (x += 1) {
                    var min_value: u32 = std.math.maxInt(u32);
                    var dy: usize = 0;
                    while (dy < 2) : (dy += 1) {
                        const child_y = y * 2 + dy;
                        if (child_y >= child.height) continue;
                        var dx: usize = 0;
                        while (dx < 2) : (dx += 1) {
                            const child_x = x * 2 + dx;
                            if (child_x >= child.width) continue;
                            min_value = @min(min_value, values[levelIndex(child, child_x, child_y)]);
                        }
                    }
                    values[levelIndex(parent, x, y)] = min_value;
                }
            }
        }

        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .levels = layout.levels,
            .values = values,
            .lows = lows,
        };
    }

    pub fn deinit(self: *TagTreeEncoder) void {
        self.allocator.free(self.levels);
        self.allocator.free(self.values);
        self.allocator.free(self.lows);
        self.* = undefined;
    }

    pub fn encode(
        self: *TagTreeEncoder,
        leaf_x: usize,
        leaf_y: usize,
        threshold: u32,
        writer: *PacketHeaderWriter,
    ) !void {
        if (leaf_x >= self.width or leaf_y >= self.height) return PacketHeaderError.InvalidTagTree;
        var path: [64]usize = undefined;
        if (self.levels.len > path.len) return PacketHeaderError.InvalidTagTree;
        fillPath(self.levels, leaf_x, leaf_y, path[0..self.levels.len]);

        var low: u32 = 0;
        var level = self.levels.len;
        while (level > 0) {
            level -= 1;
            const index = path[level];
            if (low > self.lows[index]) {
                self.lows[index] = low;
            } else {
                low = self.lows[index];
            }
            while (low < threshold) {
                if (low >= self.values[index]) {
                    try writer.writeBit(true);
                    break;
                }
                try writer.writeBit(false);
                low += 1;
            }
            self.lows[index] = low;
        }
    }
};

pub const TagTreeDecoder = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    levels: []TagTreeLevel,
    lows: []u32,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !TagTreeDecoder {
        const layout = try makeTagTreeLayout(allocator, width, height);
        errdefer allocator.free(layout.levels);
        const lows = try allocator.alloc(u32, layout.node_count);
        errdefer allocator.free(lows);
        @memset(lows, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .levels = layout.levels,
            .lows = lows,
        };
    }

    pub fn deinit(self: *TagTreeDecoder) void {
        self.allocator.free(self.levels);
        self.allocator.free(self.lows);
        self.* = undefined;
    }

    pub fn decode(
        self: *TagTreeDecoder,
        leaf_x: usize,
        leaf_y: usize,
        threshold: u32,
        reader: *PacketHeaderReader,
    ) !bool {
        if (leaf_x >= self.width or leaf_y >= self.height) return PacketHeaderError.InvalidTagTree;
        var path: [64]usize = undefined;
        if (self.levels.len > path.len) return PacketHeaderError.InvalidTagTree;
        fillPath(self.levels, leaf_x, leaf_y, path[0..self.levels.len]);

        var low: u32 = 0;
        var level = self.levels.len;
        while (level > 0) {
            level -= 1;
            const index = path[level];
            if (low > self.lows[index]) {
                self.lows[index] = low;
            } else {
                low = self.lows[index];
            }
            while (low < threshold) {
                if (try reader.readBit()) break;
                low += 1;
            }
            self.lows[index] = low;
        }

        return self.lows[path[0]] < threshold;
    }
};

const TagTreeLayout = struct {
    levels: []TagTreeLevel,
    node_count: usize,
};

fn makeTagTreeLayout(allocator: std.mem.Allocator, width: usize, height: usize) !TagTreeLayout {
    if (width == 0 or height == 0) return PacketHeaderError.InvalidTagTree;

    var level_count: usize = 1;
    var w = width;
    var h = height;
    while (w > 1 or h > 1) {
        w = parentCount(w);
        h = parentCount(h);
        level_count += 1;
    }
    if (level_count > 64) return PacketHeaderError.InvalidTagTree;

    const levels = try allocator.alloc(TagTreeLevel, level_count);
    errdefer allocator.free(levels);

    w = width;
    h = height;
    var start: usize = 0;
    var level: usize = 0;
    while (level < level_count) : (level += 1) {
        const area = try std.math.mul(usize, w, h);
        levels[level] = .{ .start = start, .width = w, .height = h };
        start = try std.math.add(usize, start, area);
        w = parentCount(w);
        h = parentCount(h);
    }

    return .{ .levels = levels, .node_count = start };
}

fn fillPath(levels: []const TagTreeLevel, leaf_x: usize, leaf_y: usize, out: []usize) void {
    var x = leaf_x;
    var y = leaf_y;
    var level: usize = 0;
    while (level < levels.len) : (level += 1) {
        out[level] = levelIndex(levels[level], x, y);
        x /= 2;
        y /= 2;
    }
}

fn levelIndex(level: TagTreeLevel, x: usize, y: usize) usize {
    return level.start + y * level.width + x;
}

fn parentCount(value: usize) usize {
    return (value + 1) / 2;
}

pub fn appendPacketPresenceHeader(allocator: std.mem.Allocator, out: *std.ArrayList(u8), present: bool) !void {
    var writer = PacketHeaderWriter.init(allocator, out);
    try writer.writeBit(present);
    try writer.finish();
}

pub fn readPacketPresenceHeader(bytes: []const u8, cursor: *usize, end: usize) !bool {
    if (cursor.* > end) return PacketHeaderError.TruncatedHeader;
    var reader = PacketHeaderReader.init(bytes[cursor.*..end]);
    const present = try reader.readBit();
    try reader.byteAlign();
    cursor.* += reader.bytesConsumed();
    return present;
}

pub fn zeroBitPlaneCount(nominal_bitplanes: u8, encoded_bitplanes: u8) !u8 {
    if (encoded_bitplanes > nominal_bitplanes) return PacketHeaderError.InvalidTagTree;
    return nominal_bitplanes - encoded_bitplanes;
}
