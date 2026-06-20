const std = @import("std");

pub const PacketHeaderError = error{
    InvalidPacketHeader,
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

    pub fn readBits(self: *PacketHeaderReader, bit_count: u6) PacketHeaderError!u64 {
        var value: u64 = 0;
        var index: u6 = 0;
        while (index < bit_count) : (index += 1) {
            value = (value << 1) | @intFromBool(try self.readBit());
        }
        return value;
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

pub fn writeCodingPassCount(writer: *PacketHeaderWriter, pass_count: u16) !void {
    if (pass_count == 0 or pass_count > 164) return PacketHeaderError.InvalidPacketHeader;
    if (pass_count == 1) {
        try writer.writeBit(false);
    } else if (pass_count == 2) {
        try writer.writeBits(0b10, 2);
    } else if (pass_count <= 5) {
        try writer.writeBits(0b110, 3);
        try writer.writeBits(pass_count - 3, 2);
    } else if (pass_count <= 36) {
        try writer.writeBits(0b1110, 4);
        try writer.writeBits(pass_count - 6, 5);
    } else {
        try writer.writeBits(0b11110, 5);
        try writer.writeBits(pass_count - 37, 7);
    }
}

pub fn readCodingPassCount(reader: *PacketHeaderReader) !u16 {
    if (!try reader.readBit()) return 1;
    if (!try reader.readBit()) return 2;
    if (!try reader.readBit()) return @as(u16, 3) + @as(u16, @intCast(try reader.readBits(2)));
    if (!try reader.readBit()) return @as(u16, 6) + @as(u16, @intCast(try reader.readBits(5)));
    if (!try reader.readBit()) return @as(u16, 37) + @as(u16, @intCast(try reader.readBits(7)));
    return PacketHeaderError.InvalidPacketHeader;
}

pub const SegmentLengthState = struct {
    lblock: u8 = 3,

    pub fn write(
        self: *SegmentLengthState,
        writer: *PacketHeaderWriter,
        pass_count: u16,
        byte_length: u64,
    ) !void {
        const extra_bits = try passCountLengthBits(pass_count);
        while (true) {
            const bit_count = try self.lengthBitCount(extra_bits);
            if (fitsInBits(byte_length, bit_count)) break;
            if (self.lblock == 63) return PacketHeaderError.InvalidPacketHeader;
            try writer.writeBit(true);
            self.lblock += 1;
        }
        try writer.writeBit(false);
        try writer.writeBits(byte_length, try self.lengthBitCount(extra_bits));
    }

    pub fn read(
        self: *SegmentLengthState,
        reader: *PacketHeaderReader,
        pass_count: u16,
    ) !u64 {
        const extra_bits = try passCountLengthBits(pass_count);
        while (try reader.readBit()) {
            if (self.lblock == 63) return PacketHeaderError.InvalidPacketHeader;
            self.lblock += 1;
        }
        return reader.readBits(try self.lengthBitCount(extra_bits));
    }

    fn lengthBitCount(self: SegmentLengthState, extra_bits: u6) !u6 {
        const bits = @as(u16, self.lblock) + @as(u16, extra_bits);
        if (bits > 63) return PacketHeaderError.InvalidPacketHeader;
        return @intCast(bits);
    }
};

pub const PacketBlock = struct {
    leaf_x: usize,
    leaf_y: usize,
    included: bool,
    previously_included: bool = false,
    zero_bitplanes: u8 = 0,
    pass_count: u16 = 0,
    byte_length: u64 = 0,
};

pub const PacketBlockLocation = struct {
    leaf_x: usize,
    leaf_y: usize,
};

pub const CodeBlockPacketState = struct {
    included: bool = false,
    length_state: SegmentLengthState = .{},
};

pub const DecodedPacketBlock = struct {
    included: bool,
    first_inclusion: bool,
    zero_bitplanes: u8,
    pass_count: u16,
    byte_length: u64,
};

pub fn writeCodeBlockPacketHeader(
    writer: *PacketHeaderWriter,
    inclusion: *TagTreeEncoder,
    zero_bitplanes: *TagTreeEncoder,
    length_state: *SegmentLengthState,
    layer: u32,
    block: PacketBlock,
) !void {
    if (block.previously_included) {
        try writer.writeBit(block.included);
        if (!block.included) return;
    } else {
        try inclusion.encode(block.leaf_x, block.leaf_y, layer + 1, writer);
        if (!block.included) return;
        try writeZeroBitPlaneValue(zero_bitplanes, block.leaf_x, block.leaf_y, block.zero_bitplanes, writer);
    }

    try writeCodingPassCount(writer, block.pass_count);
    try length_state.write(writer, block.pass_count, block.byte_length);
}

pub fn writePrecinctPacketHeader(
    writer: *PacketHeaderWriter,
    inclusion: *TagTreeEncoder,
    zero_bitplanes: *TagTreeEncoder,
    states: []CodeBlockPacketState,
    layer: u32,
    blocks: []const PacketBlock,
) !void {
    if (states.len != blocks.len) return PacketHeaderError.InvalidPacketHeader;

    var packet_included = false;
    for (blocks) |block| {
        packet_included = packet_included or block.included;
    }

    try writer.writeBit(packet_included);
    if (!packet_included) return;

    for (blocks, 0..) |block, index| {
        var actual = block;
        actual.previously_included = states[index].included;
        try writeCodeBlockPacketHeader(
            writer,
            inclusion,
            zero_bitplanes,
            &states[index].length_state,
            layer,
            actual,
        );
        if (block.included) states[index].included = true;
    }
}

pub fn readCodeBlockPacketHeader(
    reader: *PacketHeaderReader,
    inclusion: *TagTreeDecoder,
    zero_bitplanes: *TagTreeDecoder,
    length_state: *SegmentLengthState,
    layer: u32,
    leaf_x: usize,
    leaf_y: usize,
    previously_included: bool,
    max_zero_bitplanes: u8,
) !DecodedPacketBlock {
    const included = if (previously_included)
        try reader.readBit()
    else
        try inclusion.decode(leaf_x, leaf_y, layer + 1, reader);

    if (!included) {
        return .{
            .included = false,
            .first_inclusion = false,
            .zero_bitplanes = 0,
            .pass_count = 0,
            .byte_length = 0,
        };
    }

    const first_inclusion = !previously_included;
    const zeros = if (first_inclusion)
        try readZeroBitPlaneValue(zero_bitplanes, leaf_x, leaf_y, max_zero_bitplanes, reader)
    else
        0;
    const pass_count = try readCodingPassCount(reader);
    const byte_length = try length_state.read(reader, pass_count);

    return .{
        .included = true,
        .first_inclusion = first_inclusion,
        .zero_bitplanes = zeros,
        .pass_count = pass_count,
        .byte_length = byte_length,
    };
}

pub fn readPrecinctPacketHeader(
    reader: *PacketHeaderReader,
    inclusion: *TagTreeDecoder,
    zero_bitplanes: *TagTreeDecoder,
    states: []CodeBlockPacketState,
    layer: u32,
    locations: []const PacketBlockLocation,
    max_zero_bitplanes: u8,
    decoded: []DecodedPacketBlock,
) !bool {
    if (states.len != locations.len or decoded.len != locations.len) {
        return PacketHeaderError.InvalidPacketHeader;
    }

    const packet_included = try reader.readBit();
    if (!packet_included) {
        for (decoded) |*block| {
            block.* = .{
                .included = false,
                .first_inclusion = false,
                .zero_bitplanes = 0,
                .pass_count = 0,
                .byte_length = 0,
            };
        }
        return false;
    }

    for (locations, 0..) |location, index| {
        decoded[index] = try readCodeBlockPacketHeader(
            reader,
            inclusion,
            zero_bitplanes,
            &states[index].length_state,
            layer,
            location.leaf_x,
            location.leaf_y,
            states[index].included,
            max_zero_bitplanes,
        );
        if (decoded[index].included) states[index].included = true;
    }

    return true;
}

pub fn zeroBitPlaneCount(nominal_bitplanes: u8, encoded_bitplanes: u8) !u8 {
    if (encoded_bitplanes > nominal_bitplanes) return PacketHeaderError.InvalidPacketHeader;
    return nominal_bitplanes - encoded_bitplanes;
}

fn writeZeroBitPlaneValue(
    zero_bitplanes: *TagTreeEncoder,
    leaf_x: usize,
    leaf_y: usize,
    value: u8,
    writer: *PacketHeaderWriter,
) !void {
    var threshold: u32 = 1;
    while (threshold <= @as(u32, value) + 1) : (threshold += 1) {
        try zero_bitplanes.encode(leaf_x, leaf_y, threshold, writer);
    }
}

fn readZeroBitPlaneValue(
    zero_bitplanes: *TagTreeDecoder,
    leaf_x: usize,
    leaf_y: usize,
    max_zero_bitplanes: u8,
    reader: *PacketHeaderReader,
) !u8 {
    var threshold: u32 = 1;
    while (threshold <= @as(u32, max_zero_bitplanes) + 1) : (threshold += 1) {
        if (try zero_bitplanes.decode(leaf_x, leaf_y, threshold, reader)) {
            return @intCast(threshold - 1);
        }
    }
    return PacketHeaderError.InvalidPacketHeader;
}

fn passCountLengthBits(pass_count: u16) !u6 {
    if (pass_count == 0 or pass_count > 164) return PacketHeaderError.InvalidPacketHeader;
    return @intCast(15 - @clz(pass_count));
}

fn fitsInBits(value: u64, bit_count: u6) bool {
    return value < (@as(u64, 1) << bit_count);
}
