const std = @import("std");
const packet_plan = @import("packet_plan.zig");
const subband = @import("subband.zig");
const ebcot = @import("ebcot.zig");

pub const PacketHeaderError = error{
    InvalidPacketHeader,
    InvalidTagTree,
    InvalidMarkerStuffing,
    TruncatedHeader,
};

pub const SegmentSpan = ebcot.SegmentSpan;
pub const max_block_segments = ebcot.max_block_segments;

/// Split the coding passes a packet contributes to one code-block into
/// terminated codeword segments for BYPASS mode. Absolute pass positions
/// determine the boundaries: passes 0..9 form the first MQ segment, then raw
/// (significance + refinement) pairs alternate with single MQ cleanup passes
/// (ISO B.10.7.2 / opj_t2_init_seg).
pub fn bypassSegmentPassCounts(first_pass: u16, new_passes: u16, out: *[max_block_segments]u16) !u8 {
    var count: u8 = 0;
    var pass = first_pass;
    var remaining = new_passes;
    while (remaining > 0) {
        if (count >= max_block_segments) return PacketHeaderError.InvalidPacketHeader;
        const capacity: u16 = if (pass < 10)
            10 - pass
        else switch ((pass - 10) % 3) {
            0 => 2,
            else => 1,
        };
        const take = @min(remaining, capacity);
        out[count] = take;
        count += 1;
        pass += take;
        remaining -= take;
    }
    return count;
}

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
        if (self.bits_remaining == 7) {
            try self.out.append(self.allocator, 0);
            self.bits_remaining = 8;
        }
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
        var remaining = bit_count;
        while (remaining > 0) {
            if (self.bits_remaining == 0) try self.loadByte();
            const take = @min(remaining, self.bits_remaining);
            const shift: u3 = @intCast(self.bits_remaining - take);
            const mask = (@as(u16, 1) << take) - 1;
            value = (value << take) | ((@as(u64, self.current >> shift)) & mask);
            self.bits_remaining -= take;
            remaining -= take;
        }
        return value;
    }

    pub fn byteAlign(self: *PacketHeaderReader) PacketHeaderError!void {
        if (self.bits_remaining == 0) {
            if (self.previous == 0xff) {
                try self.loadByte();
            } else {
                return;
            }
        }
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
    known: []bool,

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
        const known = try allocator.alloc(bool, layout.node_count);
        errdefer allocator.free(known);
        @memset(lows, 0);
        @memset(known, false);
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
            .known = known,
        };
    }

    pub fn deinit(self: *TagTreeEncoder) void {
        self.allocator.free(self.levels);
        self.allocator.free(self.values);
        self.allocator.free(self.lows);
        self.allocator.free(self.known);
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
            if (self.known[index]) {
                low = self.lows[index];
                continue;
            } else if (low > self.lows[index]) {
                self.lows[index] = low;
            } else {
                low = self.lows[index];
            }
            while (low < threshold) {
                if (low >= self.values[index]) {
                    try writer.writeBit(true);
                    self.known[index] = true;
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
    known: []bool,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !TagTreeDecoder {
        const layout = try makeTagTreeLayout(allocator, width, height);
        errdefer allocator.free(layout.levels);
        const lows = try allocator.alloc(u32, layout.node_count);
        errdefer allocator.free(lows);
        const known = try allocator.alloc(bool, layout.node_count);
        errdefer allocator.free(known);
        @memset(lows, 0);
        @memset(known, false);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .levels = layout.levels,
            .lows = lows,
            .known = known,
        };
    }

    pub fn deinit(self: *TagTreeDecoder) void {
        self.allocator.free(self.levels);
        self.allocator.free(self.lows);
        self.allocator.free(self.known);
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
            if (self.known[index]) {
                low = self.lows[index];
                continue;
            } else if (low > self.lows[index]) {
                self.lows[index] = low;
            } else {
                low = self.lows[index];
            }
            while (low < threshold) {
                if (try reader.readBit()) {
                    self.known[index] = true;
                    break;
                }
                low += 1;
            }
            self.lows[index] = low;
        }

        return self.known[path[0]] and self.lows[path[0]] < threshold;
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
        try writer.writeBits(0b11, 2);
        try writer.writeBits(pass_count - 3, 2);
    } else if (pass_count <= 36) {
        try writer.writeBits(0b1111, 4);
        try writer.writeBits(pass_count - 6, 5);
    } else {
        try writer.writeBits(0b111111111, 9);
        try writer.writeBits(pass_count - 37, 7);
    }
}

pub fn readCodingPassCount(reader: *PacketHeaderReader) !u16 {
    if (!try reader.readBit()) return 1;
    if (!try reader.readBit()) return 2;
    const small = try reader.readBits(2);
    if (small != 3) return @as(u16, 3) + @as(u16, @intCast(small));
    const medium = try reader.readBits(5);
    if (medium != 31) return @as(u16, 6) + @as(u16, @intCast(medium));
    return @as(u16, 37) + @as(u16, @intCast(try reader.readBits(7)));
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

    /// Multi-segment length signalling (ISO B.10.7.2): one shared Lblock
    /// increment comma code, then one length per terminated segment coded
    /// with lblock + floor(log2(segment passes)) bits.
    pub fn writeSegments(
        self: *SegmentLengthState,
        writer: *PacketHeaderWriter,
        segments: []const SegmentSpan,
    ) !void {
        if (segments.len == 0) return PacketHeaderError.InvalidPacketHeader;
        var increment: u16 = 0;
        for (segments) |segment| {
            const extra_bits = try passCountLengthBits(segment.pass_count);
            const available = @as(u16, self.lblock) + @as(u16, extra_bits);
            const needed = bitsToRepresent(segment.byte_length);
            if (needed > available) increment = @max(increment, needed - available);
        }
        if (@as(u16, self.lblock) + increment > 63) return PacketHeaderError.InvalidPacketHeader;
        var written: u16 = 0;
        while (written < increment) : (written += 1) {
            try writer.writeBit(true);
        }
        try writer.writeBit(false);
        self.lblock += @intCast(increment);
        for (segments) |segment| {
            const extra_bits = try passCountLengthBits(segment.pass_count);
            try writer.writeBits(segment.byte_length, try self.lengthBitCount(extra_bits));
        }
    }

    /// Multi-segment read mirror of writeSegments; span_pass_counts carries
    /// the per-segment pass counts derived from the coding mode.
    pub fn readSegments(
        self: *SegmentLengthState,
        reader: *PacketHeaderReader,
        span_pass_counts: []const u16,
        out_lengths: []u64,
    ) !u64 {
        if (span_pass_counts.len == 0 or out_lengths.len < span_pass_counts.len) {
            return PacketHeaderError.InvalidPacketHeader;
        }
        while (try reader.readBit()) {
            if (self.lblock == 63) return PacketHeaderError.InvalidPacketHeader;
            self.lblock += 1;
        }
        var total: u64 = 0;
        for (span_pass_counts, 0..) |pass_count, index| {
            const extra_bits = try passCountLengthBits(pass_count);
            const length = try reader.readBits(try self.lengthBitCount(extra_bits));
            out_lengths[index] = length;
            total = try std.math.add(u64, total, length);
        }
        return total;
    }
};

fn bitsToRepresent(value: u64) u16 {
    if (value == 0) return 1;
    return @intCast(64 - @clz(value));
}

pub const PacketBlock = struct {
    leaf_x: usize,
    leaf_y: usize,
    included: bool,
    previously_included: bool = false,
    zero_bitplanes: u8 = 0,
    pass_count: u16 = 0,
    byte_length: u64 = 0,
    /// Terminated codeword segments contributed by this packet (BYPASS);
    /// empty means one continuous segment.
    segments: []const SegmentSpan = &.{},
};

pub const PacketBlockLocation = struct {
    leaf_x: usize,
    leaf_y: usize,
};

pub const CodeBlockRect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,
};

pub const CodeBlockGrid = struct {
    origin_x: usize,
    origin_y: usize,
    width: usize,
    height: usize,
    block_width: usize,
    block_height: usize,
    partition_offset_x: usize,
    partition_offset_y: usize,
    leaves_x: usize,
    leaves_y: usize,

    pub fn init(origin_x: usize, origin_y: usize, width: usize, height: usize, block_width: usize, block_height: usize) !CodeBlockGrid {
        return initAnchored(origin_x, origin_y, width, height, block_width, block_height, 0, 0);
    }

    pub fn initAnchored(
        origin_x: usize,
        origin_y: usize,
        width: usize,
        height: usize,
        block_width: usize,
        block_height: usize,
        partition_offset_x: usize,
        partition_offset_y: usize,
    ) !CodeBlockGrid {
        if (width == 0 or height == 0 or block_width == 0 or block_height == 0) return PacketHeaderError.InvalidPacketHeader;
        if (partition_offset_x >= block_width or partition_offset_y >= block_height) return PacketHeaderError.InvalidPacketHeader;
        const partition_width = std.math.add(usize, partition_offset_x, width) catch return PacketHeaderError.InvalidPacketHeader;
        const partition_height = std.math.add(usize, partition_offset_y, height) catch return PacketHeaderError.InvalidPacketHeader;
        return .{
            .origin_x = origin_x,
            .origin_y = origin_y,
            .width = width,
            .height = height,
            .block_width = block_width,
            .block_height = block_height,
            .partition_offset_x = partition_offset_x,
            .partition_offset_y = partition_offset_y,
            .leaves_x = ceilDiv(partition_width, block_width),
            .leaves_y = ceilDiv(partition_height, block_height),
        };
    }

    pub fn locationForRect(self: CodeBlockGrid, rect: CodeBlockRect) !PacketBlockLocation {
        if (rect.width == 0 or rect.height == 0) return PacketHeaderError.InvalidPacketHeader;
        if (rect.x < self.origin_x or rect.y < self.origin_y) return PacketHeaderError.InvalidPacketHeader;
        const rel_x = rect.x - self.origin_x;
        const rel_y = rect.y - self.origin_y;
        if (rel_x >= self.width or rel_y >= self.height) return PacketHeaderError.InvalidPacketHeader;
        const partition_x = std.math.add(usize, self.partition_offset_x, rel_x) catch return PacketHeaderError.InvalidPacketHeader;
        const partition_y = std.math.add(usize, self.partition_offset_y, rel_y) catch return PacketHeaderError.InvalidPacketHeader;
        if ((rel_x != 0 and partition_x % self.block_width != 0) or
            (rel_y != 0 and partition_y % self.block_height != 0))
        {
            return PacketHeaderError.InvalidPacketHeader;
        }
        if (rect.width > self.block_width or rect.height > self.block_height) return PacketHeaderError.InvalidPacketHeader;
        const rect_right = std.math.add(usize, rel_x, rect.width) catch return PacketHeaderError.InvalidPacketHeader;
        const rect_bottom = std.math.add(usize, rel_y, rect.height) catch return PacketHeaderError.InvalidPacketHeader;
        if (rect_right > self.width or rect_bottom > self.height) return PacketHeaderError.InvalidPacketHeader;
        const partition_right = std.math.add(usize, partition_x, rect.width) catch return PacketHeaderError.InvalidPacketHeader;
        const partition_bottom = std.math.add(usize, partition_y, rect.height) catch return PacketHeaderError.InvalidPacketHeader;
        if (rect_right != self.width and partition_right % self.block_width != 0) {
            return PacketHeaderError.InvalidPacketHeader;
        }
        if (rect_bottom != self.height and partition_bottom % self.block_height != 0) {
            return PacketHeaderError.InvalidPacketHeader;
        }
        const leaf_x = partition_x / self.block_width;
        const leaf_y = partition_y / self.block_height;
        if (leaf_x >= self.leaves_x or leaf_y >= self.leaves_y) return PacketHeaderError.InvalidPacketHeader;
        return .{ .leaf_x = leaf_x, .leaf_y = leaf_y };
    }
};

pub const CodeBlockPacketState = struct {
    included: bool = false,
    length_state: SegmentLengthState = .{},
    cumulative_passes: u16 = 0,
    cumulative_bytes: u64 = 0,
    zero_bitplanes: u8 = 0,

    pub fn truncation(self: CodeBlockPacketState) LayerTruncation {
        return .{
            .cumulative_passes = self.cumulative_passes,
            .cumulative_bytes = self.cumulative_bytes,
        };
    }

    pub fn numLenBits(self: CodeBlockPacketState) u8 {
        return self.length_state.lblock;
    }
};

pub const DecodedPacketBlock = struct {
    included: bool,
    first_inclusion: bool,
    zero_bitplanes: u8,
    pass_count: u16,
    byte_length: u64,
    /// Per-segment byte lengths when the code-block uses BYPASS-style
    /// terminated segments; segment_count == 0 means one continuous segment.
    segment_count: u8 = 0,
    segment_lengths: [max_block_segments]u64 = [_]u64{0} ** max_block_segments,
};

pub const LayerTruncation = struct {
    cumulative_passes: u16,
    cumulative_bytes: u64,
};

pub const LayerContribution = struct {
    included: bool,
    pass_count: u16,
    byte_offset: u64,
    byte_length: u64,
};

pub const LayerPacketBlock = struct {
    location: PacketBlockLocation,
    nominal_bitplanes: u8,
    encoded_bitplanes: u8,
    previous: LayerTruncation,
    current: LayerTruncation,
    payload: []const u8,
    segments: []const SegmentSpan = &.{},
};

pub const EncodedLayerBlock = struct {
    location: PacketBlockLocation,
    nominal_bitplanes: u8,
    encoded_bitplanes: u8,
    layers: []const LayerTruncation,
    payload: []const u8,
    segments: []const SegmentSpan = &.{},
    bypass: bool = false,
};

pub const WrittenPacket = struct {
    header_offset: usize,
    header_length: usize,
    payload_offset: usize,
    payload_length: usize,
    included_blocks: usize,

    pub fn packet_length(self: WrittenPacket) usize {
        return self.header_length + self.payload_length;
    }
};

pub const ReadPacket = struct {
    header_length: usize,
    payload_offset: usize,
    payload_length: usize,
    packet_length: usize,
    included_blocks: usize,
};

pub const PrecinctPacketWriterState = struct {
    allocator: std.mem.Allocator,
    inclusion: TagTreeEncoder,
    zero_bitplanes: TagTreeEncoder,
    states: []CodeBlockPacketState,
    layer_count: ?u16 = null,
    next_layer: u16 = 0,
    next_sequence: ?u64 = null,
    precinct_x: ?u32 = null,
    precinct_y: ?u32 = null,

    pub fn init(
        allocator: std.mem.Allocator,
        leaves_x: usize,
        leaves_y: usize,
        first_inclusion_layers: []const u32,
        zero_bitplane_values: []const u32,
    ) !PrecinctPacketWriterState {
        var inclusion = try TagTreeEncoder.init(allocator, leaves_x, leaves_y, first_inclusion_layers);
        errdefer inclusion.deinit();
        var zero_bitplanes = try TagTreeEncoder.init(allocator, leaves_x, leaves_y, zero_bitplane_values);
        errdefer zero_bitplanes.deinit();
        const states = try allocator.alloc(CodeBlockPacketState, first_inclusion_layers.len);
        @memset(states, .{});
        return .{
            .allocator = allocator,
            .inclusion = inclusion,
            .zero_bitplanes = zero_bitplanes,
            .states = states,
        };
    }

    pub fn initWithLayerCount(
        allocator: std.mem.Allocator,
        leaves_x: usize,
        leaves_y: usize,
        first_inclusion_layers: []const u32,
        zero_bitplane_values: []const u32,
        layer_count: u16,
    ) !PrecinctPacketWriterState {
        if (layer_count == 0) return PacketHeaderError.InvalidPacketHeader;
        var state = try init(allocator, leaves_x, leaves_y, first_inclusion_layers, zero_bitplane_values);
        state.layer_count = layer_count;
        return state;
    }

    pub fn initForEncodedBlocks(allocator: std.mem.Allocator, blocks: []const EncodedLayerBlock) !PrecinctPacketWriterState {
        if (blocks.len == 0) return PacketHeaderError.InvalidPacketHeader;

        var leaves_x: usize = 0;
        var leaves_y: usize = 0;
        const layer_count = blocks[0].layers.len;
        for (blocks) |block| {
            if (block.layers.len == 0 or block.layers.len != layer_count) return PacketHeaderError.InvalidPacketHeader;
            leaves_x = @max(leaves_x, block.location.leaf_x + 1);
            leaves_y = @max(leaves_y, block.location.leaf_y + 1);
        }
        const layer_count_u16 = std.math.cast(u16, layer_count) orelse return PacketHeaderError.InvalidPacketHeader;
        const leaf_count = try std.math.mul(usize, leaves_x, leaves_y);
        if (leaf_count != blocks.len) return PacketHeaderError.InvalidPacketHeader;

        const first_inclusion_layers = try allocator.alloc(u32, leaf_count);
        defer allocator.free(first_inclusion_layers);
        const zero_bitplane_values = try allocator.alloc(u32, leaf_count);
        defer allocator.free(zero_bitplane_values);

        for (blocks, 0..) |block, index| {
            const expected_location = PacketBlockLocation{
                .leaf_x = index % leaves_x,
                .leaf_y = index / leaves_x,
            };
            if (!std.meta.eql(block.location, expected_location)) {
                return PacketHeaderError.InvalidPacketHeader;
            }
            first_inclusion_layers[index] = firstInclusionLayer(block);
            zero_bitplane_values[index] = try zeroBitPlaneCount(block.nominal_bitplanes, block.encoded_bitplanes);
        }

        return initWithLayerCount(allocator, leaves_x, leaves_y, first_inclusion_layers, zero_bitplane_values, layer_count_u16);
    }

    pub fn deinit(self: *PrecinctPacketWriterState) void {
        self.allocator.free(self.states);
        self.inclusion.deinit();
        self.zero_bitplanes.deinit();
        self.* = undefined;
    }

    pub fn appendRpclPacket(
        self: *PrecinctPacketWriterState,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        packet: packet_plan.Packet,
        expected_resolution: u8,
        expected_component: u16,
        expected_precinct: u64,
        blocks: []const LayerPacketBlock,
    ) !WrittenPacket {
        try validateRpclPacketCursor(self.layer_count, self.next_sequence, self.precinct_x, self.precinct_y, self.next_layer, packet, expected_resolution, expected_component, expected_precinct);
        const written = try appendPrecinctLayerPacket(
            allocator,
            out,
            &self.inclusion,
            &self.zero_bitplanes,
            self.states,
            packet.layer,
            blocks,
        );
        self.next_layer = std.math.add(u16, self.next_layer, 1) catch return PacketHeaderError.InvalidPacketHeader;
        try advanceRpclPacketCursor(&self.next_sequence, &self.precinct_x, &self.precinct_y, packet);
        return written;
    }
};

pub const PrecinctPacketReaderState = struct {
    allocator: std.mem.Allocator,
    inclusion: TagTreeDecoder,
    zero_bitplanes: TagTreeDecoder,
    states: []CodeBlockPacketState,
    layer_count: ?u16 = null,
    next_layer: u16 = 0,
    next_sequence: ?u64 = null,
    precinct_x: ?u32 = null,
    precinct_y: ?u32 = null,
    bypass: bool = false,
    terminate_all: bool = false,

    pub fn init(allocator: std.mem.Allocator, leaves_x: usize, leaves_y: usize, block_count: usize) !PrecinctPacketReaderState {
        var inclusion = try TagTreeDecoder.init(allocator, leaves_x, leaves_y);
        errdefer inclusion.deinit();
        var zero_bitplanes = try TagTreeDecoder.init(allocator, leaves_x, leaves_y);
        errdefer zero_bitplanes.deinit();
        const states = try allocator.alloc(CodeBlockPacketState, block_count);
        @memset(states, .{});
        return .{
            .allocator = allocator,
            .inclusion = inclusion,
            .zero_bitplanes = zero_bitplanes,
            .states = states,
        };
    }

    pub fn initWithLayerCount(allocator: std.mem.Allocator, leaves_x: usize, leaves_y: usize, block_count: usize, layer_count: u16) !PrecinctPacketReaderState {
        if (layer_count == 0) return PacketHeaderError.InvalidPacketHeader;
        var state = try init(allocator, leaves_x, leaves_y, block_count);
        state.layer_count = layer_count;
        return state;
    }

    pub fn deinit(self: *PrecinctPacketReaderState) void {
        self.allocator.free(self.states);
        self.inclusion.deinit();
        self.zero_bitplanes.deinit();
        self.* = undefined;
    }

    pub fn readRpclPacket(
        self: *PrecinctPacketReaderState,
        allocator: std.mem.Allocator,
        bytes: []const u8,
        packet: packet_plan.Packet,
        expected_resolution: u8,
        expected_component: u16,
        expected_precinct: u64,
        locations: []const PacketBlockLocation,
        max_zero_bitplanes: u8,
        decoded: []DecodedPacketBlock,
        payloads: []?[]const u8,
    ) !ReadPacket {
        try validateRpclPacketCursor(self.layer_count, self.next_sequence, self.precinct_x, self.precinct_y, self.next_layer, packet, expected_resolution, expected_component, expected_precinct);
        const saved_next_layer = self.next_layer;
        const saved_next_sequence = self.next_sequence;
        const saved_precinct_x = self.precinct_x;
        const saved_precinct_y = self.precinct_y;
        const saved_states = try allocator.dupe(CodeBlockPacketState, self.states);
        defer allocator.free(saved_states);
        const saved_inclusion_lows = try allocator.dupe(u32, self.inclusion.lows);
        defer allocator.free(saved_inclusion_lows);
        const saved_zero_lows = try allocator.dupe(u32, self.zero_bitplanes.lows);
        defer allocator.free(saved_zero_lows);
        const saved_inclusion_known = try allocator.dupe(bool, self.inclusion.known);
        defer allocator.free(saved_inclusion_known);
        const saved_zero_known = try allocator.dupe(bool, self.zero_bitplanes.known);
        defer allocator.free(saved_zero_known);
        errdefer {
            self.next_layer = saved_next_layer;
            self.next_sequence = saved_next_sequence;
            self.precinct_x = saved_precinct_x;
            self.precinct_y = saved_precinct_y;
            @memcpy(self.states, saved_states);
            @memcpy(self.inclusion.lows, saved_inclusion_lows);
            @memcpy(self.zero_bitplanes.lows, saved_zero_lows);
            @memcpy(self.inclusion.known, saved_inclusion_known);
            @memcpy(self.zero_bitplanes.known, saved_zero_known);
        }
        const read = try readPrecinctLayerPacket(
            allocator,
            bytes,
            &self.inclusion,
            &self.zero_bitplanes,
            self.states,
            packet.layer,
            locations,
            max_zero_bitplanes,
            self.bypass,
            self.terminate_all,
            decoded,
            payloads,
        );
        if (read.packet_length != bytes.len) return PacketHeaderError.InvalidPacketHeader;
        self.next_layer = std.math.add(u16, self.next_layer, 1) catch return PacketHeaderError.InvalidPacketHeader;
        try advanceRpclPacketCursor(&self.next_sequence, &self.precinct_x, &self.precinct_y, packet);
        return read;
    }
};

fn validateRpclPacketCursor(
    layer_count: ?u16,
    next_sequence: ?u64,
    precinct_x: ?u32,
    precinct_y: ?u32,
    next_layer: u16,
    packet: packet_plan.Packet,
    expected_resolution: u8,
    expected_component: u16,
    expected_precinct: u64,
) !void {
    if (packet.resolution != expected_resolution or
        packet.component != expected_component or
        packet.precinct_index != expected_precinct or
        packet.layer != next_layer)
    {
        return PacketHeaderError.InvalidPacketHeader;
    }
    if (layer_count) |count| {
        if (packet.layer >= count) return PacketHeaderError.InvalidPacketHeader;
    }
    if (next_sequence) |sequence| {
        if (packet.sequence != sequence) return PacketHeaderError.InvalidPacketHeader;
    }
    if (precinct_x) |x| {
        if (packet.precinct_x != x) return PacketHeaderError.InvalidPacketHeader;
    }
    if (precinct_y) |y| {
        if (packet.precinct_y != y) return PacketHeaderError.InvalidPacketHeader;
    }
}

fn advanceRpclPacketCursor(
    next_sequence: *?u64,
    precinct_x: *?u32,
    precinct_y: *?u32,
    packet: packet_plan.Packet,
) !void {
    if (precinct_x.* == null) precinct_x.* = packet.precinct_x;
    if (precinct_y.* == null) precinct_y.* = packet.precinct_y;
    next_sequence.* = std.math.add(u64, packet.sequence, 1) catch return PacketHeaderError.InvalidPacketHeader;
}

pub fn layerContribution(previous: LayerTruncation, current: LayerTruncation) !LayerContribution {
    if (current.cumulative_passes < previous.cumulative_passes) return PacketHeaderError.InvalidPacketHeader;
    if (current.cumulative_bytes < previous.cumulative_bytes) return PacketHeaderError.InvalidPacketHeader;

    const pass_count = current.cumulative_passes - previous.cumulative_passes;
    const byte_length = current.cumulative_bytes - previous.cumulative_bytes;
    if (pass_count == 0 and byte_length != 0) return PacketHeaderError.InvalidPacketHeader;
    if (pass_count != 0 and byte_length == 0) return PacketHeaderError.InvalidPacketHeader;
    if (pass_count > 164) return PacketHeaderError.InvalidPacketHeader;

    return .{
        .included = pass_count != 0,
        .pass_count = pass_count,
        .byte_offset = previous.cumulative_bytes,
        .byte_length = byte_length,
    };
}

pub fn packetBlockForLayer(
    location: PacketBlockLocation,
    nominal_bitplanes: u8,
    encoded_bitplanes: u8,
    previous: LayerTruncation,
    current: LayerTruncation,
) !PacketBlock {
    const contribution = try layerContribution(previous, current);
    return .{
        .leaf_x = location.leaf_x,
        .leaf_y = location.leaf_y,
        .included = contribution.included,
        .zero_bitplanes = try zeroBitPlaneCount(nominal_bitplanes, encoded_bitplanes),
        .pass_count = contribution.pass_count,
        .byte_length = contribution.byte_length,
    };
}

pub fn layerPayloadSlice(bytes: []const u8, previous: LayerTruncation, current: LayerTruncation) ![]const u8 {
    const contribution = try layerContribution(previous, current);
    const payload_len: u64 = @intCast(bytes.len);
    const end = try std.math.add(u64, contribution.byte_offset, contribution.byte_length);
    if (end > payload_len) return PacketHeaderError.InvalidPacketHeader;
    const start_index: usize = @intCast(contribution.byte_offset);
    const end_index: usize = @intCast(end);
    return bytes[start_index..end_index];
}

fn packetBlockForLayerPacketBlock(block: LayerPacketBlock) !PacketBlock {
    if (block.segments.len > 0) {
        if (block.current.cumulative_passes < block.previous.cumulative_passes) return PacketHeaderError.InvalidPacketHeader;
        if (block.current.cumulative_bytes < block.previous.cumulative_bytes) return PacketHeaderError.InvalidPacketHeader;
        const pass_count = block.current.cumulative_passes - block.previous.cumulative_passes;
        const byte_length = block.current.cumulative_bytes - block.previous.cumulative_bytes;
        if (pass_count == 0 and byte_length != 0) return PacketHeaderError.InvalidPacketHeader;
        if (pass_count > 164) return PacketHeaderError.InvalidPacketHeader;

        var packet_block = PacketBlock{
            .leaf_x = block.location.leaf_x,
            .leaf_y = block.location.leaf_y,
            .included = pass_count != 0,
            .zero_bitplanes = try zeroBitPlaneCount(block.nominal_bitplanes, block.encoded_bitplanes),
            .pass_count = pass_count,
            .byte_length = byte_length,
        };
        if (packet_block.included) {
            var segment_passes: u16 = 0;
            var segment_bytes: u64 = 0;
            for (block.segments) |segment| {
                segment_passes = std.math.add(u16, segment_passes, segment.pass_count) catch
                    return PacketHeaderError.InvalidPacketHeader;
                segment_bytes = try std.math.add(u64, segment_bytes, segment.byte_length);
            }
            if (segment_passes != packet_block.pass_count or
                segment_bytes != packet_block.byte_length)
            {
                return PacketHeaderError.InvalidPacketHeader;
            }
            packet_block.segments = block.segments;
        }
        return packet_block;
    }

    var packet_block = try packetBlockForLayer(
        block.location,
        block.nominal_bitplanes,
        block.encoded_bitplanes,
        block.previous,
        block.current,
    );
    if (block.segments.len > 0 and packet_block.included) {
        var segment_passes: u16 = 0;
        var segment_bytes: u64 = 0;
        for (block.segments) |segment| {
            segment_passes = std.math.add(u16, segment_passes, segment.pass_count) catch
                return PacketHeaderError.InvalidPacketHeader;
            segment_bytes = try std.math.add(u64, segment_bytes, segment.byte_length);
        }
        if (segment_passes != packet_block.pass_count or
            segment_bytes != packet_block.byte_length)
        {
            return PacketHeaderError.InvalidPacketHeader;
        }
        packet_block.segments = block.segments;
    }
    return packet_block;
}

fn firstInclusionLayer(block: EncodedLayerBlock) u32 {
    for (block.layers, 0..) |layer, index| {
        if (layer.cumulative_passes != 0 or layer.cumulative_bytes != 0) return @intCast(index);
    }
    return @intCast(block.layers.len);
}

pub fn bandResolutionIndex(levels: u8, band: subband.Band) !u8 {
    if (band.kind == .ll) {
        if (band.level > levels) return PacketHeaderError.InvalidPacketHeader;
        return 0;
    }
    if (band.level == 0 or band.level > levels) return PacketHeaderError.InvalidPacketHeader;
    return levels - band.level + 1;
}

pub fn codeBlockPacketRect(block: subband.CodeBlock) !packet_plan.Rect {
    return .{
        .x = std.math.cast(u32, block.rect.x) orelse return PacketHeaderError.InvalidPacketHeader,
        .y = std.math.cast(u32, block.rect.y) orelse return PacketHeaderError.InvalidPacketHeader,
        .width = std.math.cast(u32, block.rect.width) orelse return PacketHeaderError.InvalidPacketHeader,
        .height = std.math.cast(u32, block.rect.height) orelse return PacketHeaderError.InvalidPacketHeader,
    };
}

fn codeBlockSubbandPacketRect(band: subband.Band, block: subband.CodeBlock) !packet_plan.Rect {
    if (block.rect.x < band.rect.x or block.rect.y < band.rect.y) return PacketHeaderError.InvalidPacketHeader;
    const local_x = block.rect.x - band.rect.x;
    const local_y = block.rect.y - band.rect.y;
    if (local_x + block.rect.width > band.rect.width or local_y + block.rect.height > band.rect.height) {
        return PacketHeaderError.InvalidPacketHeader;
    }
    return .{
        .x = std.math.cast(u32, local_x) orelse return PacketHeaderError.InvalidPacketHeader,
        .y = std.math.cast(u32, local_y) orelse return PacketHeaderError.InvalidPacketHeader,
        .width = std.math.cast(u32, block.rect.width) orelse return PacketHeaderError.InvalidPacketHeader,
        .height = std.math.cast(u32, block.rect.height) orelse return PacketHeaderError.InvalidPacketHeader,
    };
}

fn bandPrecinctRect(plan: packet_plan.Plan, packet: packet_plan.Packet, band: subband.Band) !packet_plan.Rect {
    const precinct = try packet_plan.precinctRect(plan, packet.resolution, packet.precinct_index);
    if (band.kind == .ll) return precinct;
    if (packet.resolution >= plan.resolution_count) return PacketHeaderError.InvalidPacketHeader;
    const resolution = plan.resolutions[packet.resolution];
    const global_x0 = std.math.add(u32, resolution.x0, precinct.x) catch return PacketHeaderError.InvalidPacketHeader;
    const global_y0 = std.math.add(u32, resolution.y0, precinct.y) catch return PacketHeaderError.InvalidPacketHeader;
    const global_x1 = std.math.add(u32, global_x0, precinct.width) catch return PacketHeaderError.InvalidPacketHeader;
    const global_y1 = std.math.add(u32, global_y0, precinct.height) catch return PacketHeaderError.InvalidPacketHeader;
    const global_x_range = subbandAxisRange(global_x0, global_x1, bandUsesHighX(band.kind));
    const global_y_range = subbandAxisRange(global_y0, global_y1, bandUsesHighY(band.kind));
    const width = std.math.cast(u32, band.rect.width) orelse return PacketHeaderError.InvalidPacketHeader;
    const height = std.math.cast(u32, band.rect.height) orelse return PacketHeaderError.InvalidPacketHeader;
    const band_x1 = std.math.add(u32, band.origin_x, width) catch return PacketHeaderError.InvalidPacketHeader;
    const band_y1 = std.math.add(u32, band.origin_y, height) catch return PacketHeaderError.InvalidPacketHeader;
    const clipped_x0 = @max(global_x_range.start, band.origin_x);
    const clipped_y0 = @max(global_y_range.start, band.origin_y);
    const clipped_x1 = @min(global_x_range.end, band_x1);
    const clipped_y1 = @min(global_y_range.end, band_y1);
    if (clipped_x1 < clipped_x0 or clipped_y1 < clipped_y0) return PacketHeaderError.InvalidPacketHeader;
    const start_x = clipped_x0 - band.origin_x;
    const end_x = clipped_x1 - band.origin_x;
    const start_y = clipped_y0 - band.origin_y;
    const end_y = clipped_y1 - band.origin_y;
    if (end_x < start_x or end_y < start_y) return PacketHeaderError.InvalidPacketHeader;
    return .{
        .x = start_x,
        .y = start_y,
        .width = end_x - start_x,
        .height = end_y - start_y,
    };
}

const AxisRange = struct {
    start: u32,
    end: u32,
};

fn subbandAxisRange(start: u32, end: u32, high: bool) AxisRange {
    return if (high)
        .{ .start = start / 2, .end = end / 2 }
    else
        .{ .start = (start + 1) / 2, .end = (end + 1) / 2 };
}

fn bandUsesHighX(kind: subband.Kind) bool {
    return switch (kind) {
        .ll, .lh => false,
        .hl, .hh => true,
    };
}

fn bandUsesHighY(kind: subband.Kind) bool {
    return switch (kind) {
        .ll, .hl => false,
        .lh, .hh => true,
    };
}

pub fn codeBlockIntersectsRpclPacket(
    plan: packet_plan.Plan,
    packet: packet_plan.Packet,
    levels: u8,
    bands: []const subband.Band,
    block: subband.CodeBlock,
) !bool {
    if (block.band_index >= bands.len) return PacketHeaderError.InvalidPacketHeader;
    const band = bands[block.band_index];
    if (try bandResolutionIndex(levels, band) != packet.resolution) return false;
    const precinct = try bandPrecinctRect(plan, packet, band);
    if (precinct.width == 0 or precinct.height == 0) return false;
    return packet_plan.rectsIntersect(precinct, try codeBlockSubbandPacketRect(band, block));
}

pub fn collectRpclCodeBlockIndexes(
    allocator: std.mem.Allocator,
    plan: packet_plan.Plan,
    packet: packet_plan.Packet,
    levels: u8,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
) ![]usize {
    var indexes: std.ArrayList(usize) = .empty;
    errdefer indexes.deinit(allocator);

    for (blocks, 0..) |block, index| {
        if (try codeBlockIntersectsRpclPacket(plan, packet, levels, bands, block)) {
            try indexes.append(allocator, index);
        }
    }

    return indexes.toOwnedSlice(allocator);
}

pub fn layerPacketBlockFor(encoded: EncodedLayerBlock, layer_index: usize) !LayerPacketBlock {
    if (layer_index >= encoded.layers.len) return PacketHeaderError.InvalidPacketHeader;
    const previous: LayerTruncation = if (layer_index == 0)
        .{ .cumulative_passes = 0, .cumulative_bytes = 0 }
    else
        encoded.layers[layer_index - 1];
    const current = encoded.layers[layer_index];
    return .{
        .location = encoded.location,
        .nominal_bitplanes = encoded.nominal_bitplanes,
        .encoded_bitplanes = encoded.encoded_bitplanes,
        .previous = previous,
        .current = current,
        .payload = encoded.payload,
        .segments = if (encoded.segments.len > 0)
            try sliceSegmentsForLayer(encoded.segments, previous, current)
        else
            &.{},
    };
}

/// Slice a block's terminated-segment table down to the segments a layer
/// contributes. Both layer boundaries must sit exactly on segment
/// boundaries (guaranteed by the segment-snapping rate allocation).
fn sliceSegmentsForLayer(
    segments: []const SegmentSpan,
    previous: LayerTruncation,
    current: LayerTruncation,
) ![]const SegmentSpan {
    var cumulative_passes: u16 = 0;
    var cumulative_bytes: u64 = 0;
    var start: usize = 0;
    while (start < segments.len and cumulative_passes < previous.cumulative_passes) : (start += 1) {
        cumulative_passes = std.math.add(u16, cumulative_passes, segments[start].pass_count) catch
            return PacketHeaderError.InvalidPacketHeader;
        cumulative_bytes = try std.math.add(u64, cumulative_bytes, segments[start].byte_length);
    }
    if (cumulative_passes != previous.cumulative_passes or cumulative_bytes != previous.cumulative_bytes) {
        return PacketHeaderError.InvalidPacketHeader;
    }
    var end = start;
    while (end < segments.len and cumulative_passes < current.cumulative_passes) : (end += 1) {
        cumulative_passes = std.math.add(u16, cumulative_passes, segments[end].pass_count) catch
            return PacketHeaderError.InvalidPacketHeader;
        cumulative_bytes = try std.math.add(u64, cumulative_bytes, segments[end].byte_length);
    }
    if (cumulative_passes != current.cumulative_passes or cumulative_bytes != current.cumulative_bytes) {
        return PacketHeaderError.InvalidPacketHeader;
    }
    return segments[start..end];
}

pub fn layerPacketBlocksForIndexes(
    allocator: std.mem.Allocator,
    encoded_blocks: []const EncodedLayerBlock,
    indexes: []const usize,
    layer_index: usize,
) ![]LayerPacketBlock {
    const blocks = try allocator.alloc(LayerPacketBlock, indexes.len);
    errdefer allocator.free(blocks);

    for (indexes, 0..) |index, out_index| {
        if (index >= encoded_blocks.len) return PacketHeaderError.InvalidPacketHeader;
        blocks[out_index] = try layerPacketBlockFor(encoded_blocks[index], layer_index);
    }

    return blocks;
}

pub fn appendRpclPacketForIndexes(
    state: *PrecinctPacketWriterState,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    packet: packet_plan.Packet,
    expected_resolution: u8,
    expected_component: u16,
    expected_precinct: u64,
    encoded_blocks: []const EncodedLayerBlock,
    indexes: []const usize,
) !WrittenPacket {
    try validateRpclPacketCursor(state.layer_count, state.next_sequence, state.precinct_x, state.precinct_y, state.next_layer, packet, expected_resolution, expected_component, expected_precinct);
    if (state.states.len != indexes.len) return PacketHeaderError.InvalidPacketHeader;

    const layer_index: usize = @intCast(packet.layer);
    const packet_blocks = try allocator.alloc(PacketBlock, indexes.len);
    defer allocator.free(packet_blocks);

    var payload_length: usize = 0;
    var included_blocks: usize = 0;
    for (indexes, 0..) |encoded_index, packet_index| {
        if (encoded_index >= encoded_blocks.len) return PacketHeaderError.InvalidPacketHeader;
        const block = try layerPacketBlockFor(encoded_blocks[encoded_index], layer_index);
        if (block.previous.cumulative_passes != state.states[packet_index].cumulative_passes or
            block.previous.cumulative_bytes != state.states[packet_index].cumulative_bytes)
        {
            return PacketHeaderError.InvalidPacketHeader;
        }

        packet_blocks[packet_index] = try packetBlockForLayerPacketBlock(block);

        const payload = try layerPayloadSlice(block.payload, block.previous, block.current);
        if (packet_blocks[packet_index].included) {
            if (payload.len != packet_blocks[packet_index].byte_length) return PacketHeaderError.InvalidPacketHeader;
            payload_length = try std.math.add(usize, payload_length, packet_blocks[packet_index].byte_length);
            included_blocks += 1;
        } else if (payload.len != 0) {
            return PacketHeaderError.InvalidPacketHeader;
        }
    }

    const header_offset = out.items.len;
    var writer = PacketHeaderWriter.init(allocator, out);
    try writePrecinctPacketHeader(
        &writer,
        &state.inclusion,
        &state.zero_bitplanes,
        state.states,
        packet.layer,
        packet_blocks,
    );
    try writer.finish();
    const header_length = out.items.len - header_offset;
    const payload_offset = out.items.len;

    for (indexes, packet_blocks) |encoded_index, packet_block| {
        if (!packet_block.included) continue;
        const block = try layerPacketBlockFor(encoded_blocks[encoded_index], layer_index);
        const payload = try layerPayloadSlice(block.payload, block.previous, block.current);
        if (payload.len != packet_block.byte_length) return PacketHeaderError.InvalidPacketHeader;
        try out.appendSlice(allocator, payload);
    }

    state.next_layer = std.math.add(u16, state.next_layer, 1) catch return PacketHeaderError.InvalidPacketHeader;
    try advanceRpclPacketCursor(&state.next_sequence, &state.precinct_x, &state.precinct_y, packet);
    return .{
        .header_offset = header_offset,
        .header_length = header_length,
        .payload_offset = payload_offset,
        .payload_length = payload_length,
        .included_blocks = included_blocks,
    };
}

pub fn appendPrecinctLayerPacket(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    inclusion: *TagTreeEncoder,
    zero_bitplanes: *TagTreeEncoder,
    states: []CodeBlockPacketState,
    layer: u32,
    blocks: []const LayerPacketBlock,
) !WrittenPacket {
    if (states.len != blocks.len) return PacketHeaderError.InvalidPacketHeader;

    const packet_blocks = try allocator.alloc(PacketBlock, blocks.len);
    defer allocator.free(packet_blocks);

    var payload_length: usize = 0;
    var included_blocks: usize = 0;
    for (blocks, 0..) |block, index| {
        if (block.previous.cumulative_passes != states[index].cumulative_passes or
            block.previous.cumulative_bytes != states[index].cumulative_bytes)
        {
            return PacketHeaderError.InvalidPacketHeader;
        }
        packet_blocks[index] = try packetBlockForLayerPacketBlock(block);
        const payload = try layerPayloadSlice(block.payload, block.previous, block.current);
        if (packet_blocks[index].included) {
            if (payload.len != packet_blocks[index].byte_length) {
                return PacketHeaderError.InvalidPacketHeader;
            }
            payload_length = try std.math.add(usize, payload_length, packet_blocks[index].byte_length);
            included_blocks += 1;
        } else if (payload.len != 0) {
            return PacketHeaderError.InvalidPacketHeader;
        }
    }

    const header_offset = out.items.len;
    var writer = PacketHeaderWriter.init(allocator, out);
    try writePrecinctPacketHeader(
        &writer,
        inclusion,
        zero_bitplanes,
        states,
        layer,
        packet_blocks,
    );
    try writer.finish();
    const header_length = out.items.len - header_offset;
    const payload_offset = out.items.len;

    for (blocks, packet_blocks) |layer_block, packet_block| {
        if (!packet_block.included) continue;
        const payload = try layerPayloadSlice(layer_block.payload, layer_block.previous, layer_block.current);
        if (payload.len != packet_block.byte_length) return PacketHeaderError.InvalidPacketHeader;
        try out.appendSlice(allocator, payload);
    }

    return .{
        .header_offset = header_offset,
        .header_length = header_length,
        .payload_offset = payload_offset,
        .payload_length = payload_length,
        .included_blocks = included_blocks,
    };
}

pub fn readPrecinctLayerPacket(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    inclusion: *TagTreeDecoder,
    zero_bitplanes: *TagTreeDecoder,
    states: []CodeBlockPacketState,
    layer: u32,
    locations: []const PacketBlockLocation,
    max_zero_bitplanes: u8,
    bypass: bool,
    terminate_all: bool,
    decoded: []DecodedPacketBlock,
    payloads: []?[]const u8,
) !ReadPacket {
    if (payloads.len != locations.len) return PacketHeaderError.InvalidPacketHeader;

    const saved_states = try allocator.dupe(CodeBlockPacketState, states);
    defer allocator.free(saved_states);
    const saved_inclusion_lows = try allocator.dupe(u32, inclusion.lows);
    defer allocator.free(saved_inclusion_lows);
    const saved_zero_lows = try allocator.dupe(u32, zero_bitplanes.lows);
    defer allocator.free(saved_zero_lows);
    const saved_inclusion_known = try allocator.dupe(bool, inclusion.known);
    defer allocator.free(saved_inclusion_known);
    const saved_zero_known = try allocator.dupe(bool, zero_bitplanes.known);
    defer allocator.free(saved_zero_known);
    errdefer {
        @memcpy(states, saved_states);
        @memcpy(inclusion.lows, saved_inclusion_lows);
        @memcpy(zero_bitplanes.lows, saved_zero_lows);
        @memcpy(inclusion.known, saved_inclusion_known);
        @memcpy(zero_bitplanes.known, saved_zero_known);
    }

    var reader = PacketHeaderReader.init(bytes);
    _ = try readPrecinctPacketHeader(
        &reader,
        inclusion,
        zero_bitplanes,
        states,
        layer,
        locations,
        max_zero_bitplanes,
        bypass,
        terminate_all,
        decoded,
    );
    try reader.byteAlign();

    const payload_offset = reader.bytesConsumed();
    var cursor = payload_offset;
    var payload_length: usize = 0;
    var included_blocks: usize = 0;
    for (decoded, payloads) |block, *payload| {
        payload.* = null;
        if (!block.included) continue;
        const byte_length = std.math.cast(usize, block.byte_length) orelse return PacketHeaderError.InvalidPacketHeader;
        const end = try std.math.add(usize, cursor, byte_length);
        if (end > bytes.len) return PacketHeaderError.TruncatedHeader;
        payload.* = bytes[cursor..end];
        cursor = end;
        payload_length += byte_length;
        included_blocks += 1;
    }

    return .{
        .header_length = payload_offset,
        .payload_offset = payload_offset,
        .payload_length = payload_length,
        .packet_length = cursor,
        .included_blocks = included_blocks,
    };
}

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
    if (block.segments.len > 1) {
        try length_state.writeSegments(writer, block.segments);
    } else {
        try length_state.write(writer, block.pass_count, block.byte_length);
    }
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

    try writePrecinctPacketHeaderBody(
        writer,
        inclusion,
        zero_bitplanes,
        states,
        layer,
        blocks,
    );
}

pub fn packetBlocksIncluded(blocks: []const PacketBlock) bool {
    for (blocks) |block| {
        if (block.included) return true;
    }
    return false;
}

pub fn writePrecinctPacketHeaderBody(
    writer: *PacketHeaderWriter,
    inclusion: *TagTreeEncoder,
    zero_bitplanes: *TagTreeEncoder,
    states: []CodeBlockPacketState,
    layer: u32,
    blocks: []const PacketBlock,
) !void {
    if (states.len != blocks.len) return PacketHeaderError.InvalidPacketHeader;

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
        if (block.included) {
            if (!states[index].included) {
                states[index].zero_bitplanes = block.zero_bitplanes;
            }
            states[index].included = true;
            states[index].cumulative_passes = std.math.add(u16, states[index].cumulative_passes, block.pass_count) catch
                return PacketHeaderError.InvalidPacketHeader;
            states[index].cumulative_bytes = std.math.add(u64, states[index].cumulative_bytes, block.byte_length) catch
                return PacketHeaderError.InvalidPacketHeader;
        }
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
    bypass: bool,
    terminate_all: bool,
    first_pass: u16,
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

    if (bypass or terminate_all) {
        var span_passes: [max_block_segments]u16 = undefined;
        const segment_count = if (terminate_all) blk: {
            // terminate_all: each coding pass is its own terminated segment.
            if (pass_count > max_block_segments) return PacketHeaderError.InvalidPacketHeader;
            for (0..pass_count) |i| span_passes[i] = 1;
            break :blk @as(u8, @intCast(pass_count));
        } else try bypassSegmentPassCounts(first_pass, pass_count, &span_passes);
        var block = DecodedPacketBlock{
            .included = true,
            .first_inclusion = first_inclusion,
            .zero_bitplanes = zeros,
            .pass_count = pass_count,
            .byte_length = 0,
            .segment_count = segment_count,
        };
        block.byte_length = try length_state.readSegments(
            reader,
            span_passes[0..segment_count],
            block.segment_lengths[0..segment_count],
        );
        return block;
    }

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
    bypass: bool,
    terminate_all: bool,
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

    try readPrecinctPacketHeaderBody(
        reader,
        inclusion,
        zero_bitplanes,
        states,
        layer,
        locations,
        max_zero_bitplanes,
        bypass,
        terminate_all,
        decoded,
    );

    return true;
}

pub fn readPrecinctPacketHeaderBody(
    reader: *PacketHeaderReader,
    inclusion: *TagTreeDecoder,
    zero_bitplanes: *TagTreeDecoder,
    states: []CodeBlockPacketState,
    layer: u32,
    locations: []const PacketBlockLocation,
    max_zero_bitplanes: u8,
    bypass: bool,
    terminate_all: bool,
    decoded: []DecodedPacketBlock,
) !void {
    if (states.len != locations.len or decoded.len != locations.len) {
        return PacketHeaderError.InvalidPacketHeader;
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
            bypass,
            terminate_all,
            states[index].cumulative_passes,
        );
        if (decoded[index].included) {
            if (!states[index].included) {
                states[index].zero_bitplanes = decoded[index].zero_bitplanes;
            }
            states[index].included = true;
            states[index].cumulative_passes = std.math.add(u16, states[index].cumulative_passes, decoded[index].pass_count) catch
                return PacketHeaderError.InvalidPacketHeader;
            states[index].cumulative_bytes = std.math.add(u64, states[index].cumulative_bytes, decoded[index].byte_length) catch
                return PacketHeaderError.InvalidPacketHeader;
        }
    }
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

fn ceilDiv(numerator: usize, denominator: usize) usize {
    return (numerator / denominator) + @intFromBool(numerator % denominator != 0);
}

fn fitsInBits(value: u64, bit_count: u6) bool {
    return value < (@as(u64, 1) << bit_count);
}
