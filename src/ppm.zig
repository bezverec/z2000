const std = @import("std");

pub const PpmError = error{
    InvalidSegment,
    TooManySegments,
    TruncatedGroup,
    GroupTooLarge,
};

/// Collects ordered PPM marker payloads. The payload includes Zppm but excludes
/// the marker and Lppm fields. ISO permits Nppm and Ippm to cross marker
/// boundaries, so framing is validated only after all segments are joined.
pub const SegmentCollector = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    expected_index: u16 = 0,

    pub fn init(allocator: std.mem.Allocator) SegmentCollector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SegmentCollector) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *SegmentCollector, payload: []const u8) !void {
        if (payload.len < 2) return PpmError.InvalidSegment;
        if (self.expected_index > std.math.maxInt(u8)) return PpmError.TooManySegments;
        if (payload[0] != @as(u8, @intCast(self.expected_index))) {
            return PpmError.InvalidSegment;
        }
        try self.bytes.appendSlice(self.allocator, payload[1..]);
        self.expected_index += 1;
    }

    pub fn finish(self: *SegmentCollector) !PackedHeaders {
        if (self.expected_index == 0) return PpmError.InvalidSegment;
        const bytes = try self.bytes.toOwnedSlice(self.allocator);
        self.expected_index = 0;
        return .{ .allocator = self.allocator, .bytes = bytes };
    }
};

pub const PackedHeaders = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,

    pub fn deinit(self: *PackedHeaders) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn iterator(self: PackedHeaders) GroupIterator {
        return .{ .bytes = self.bytes };
    }

    pub fn validate(self: PackedHeaders) !usize {
        var groups = self.iterator();
        var count: usize = 0;
        while (try groups.next()) |_| count += 1;
        return count;
    }

    pub fn groupAt(self: PackedHeaders, wanted: usize) !?[]const u8 {
        var groups = self.iterator();
        var index: usize = 0;
        while (try groups.next()) |group| : (index += 1) {
            if (index == wanted) return group;
        }
        return null;
    }
};

pub const GroupIterator = struct {
    bytes: []const u8,
    cursor: usize = 0,

    pub fn next(self: *GroupIterator) !?[]const u8 {
        if (self.cursor == self.bytes.len) return null;
        if (self.bytes.len - self.cursor < 4) return PpmError.TruncatedGroup;

        const length = readU32Be(self.bytes, self.cursor);
        self.cursor += 4;
        const length_usize = std.math.cast(usize, length) orelse return PpmError.GroupTooLarge;
        const end = std.math.add(usize, self.cursor, length_usize) catch return PpmError.GroupTooLarge;
        if (end > self.bytes.len) return PpmError.TruncatedGroup;
        const group = self.bytes[self.cursor..end];
        self.cursor = end;
        return group;
    }
};

/// Owned PPM marker payloads, each beginning with its Zppm byte. This helper
/// deliberately emits only payloads; codestream marker placement remains the
/// caller's responsibility.
pub const MarkerPayloads = struct {
    allocator: std.mem.Allocator,
    items: [][]u8,

    pub fn deinit(self: *MarkerPayloads) void {
        for (self.items) |item| self.allocator.free(item);
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn buildMarkerPayloads(
    allocator: std.mem.Allocator,
    groups: []const []const u8,
    max_payload_bytes: usize,
) !MarkerPayloads {
    // Lppm is a u16 and includes its own two bytes, leaving at most 65533
    // bytes for Zppm plus packed-header data.
    if (groups.len == 0 or max_payload_bytes < 2 or max_payload_bytes > 65533) {
        return PpmError.InvalidSegment;
    }

    var framed: std.ArrayList(u8) = .empty;
    defer framed.deinit(allocator);
    for (groups) |group| {
        const length = std.math.cast(u32, group.len) orelse return PpmError.GroupTooLarge;
        try appendU32Be(allocator, &framed, length);
        try framed.appendSlice(allocator, group);
    }

    const data_capacity = max_payload_bytes - 1;
    const segment_count = try std.math.divCeil(usize, framed.items.len, data_capacity);
    if (segment_count == 0 or segment_count > 256) return PpmError.TooManySegments;

    const items = try allocator.alloc([]u8, segment_count);
    errdefer allocator.free(items);
    var initialized: usize = 0;
    errdefer for (items[0..initialized]) |item| allocator.free(item);

    for (items, 0..) |*item, index| {
        const start = index * data_capacity;
        const end = @min(framed.items.len, start + data_capacity);
        item.* = try allocator.alloc(u8, 1 + end - start);
        initialized += 1;
        item.*[0] = @intCast(index);
        @memcpy(item.*[1..], framed.items[start..end]);
    }
    return .{ .allocator = allocator, .items = items };
}

fn appendU32Be(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    try out.append(allocator, @intCast(value >> 24));
    try out.append(allocator, @intCast(value >> 16));
    try out.append(allocator, @intCast(value >> 8));
    try out.append(allocator, @truncate(value));
}

fn readU32Be(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}
