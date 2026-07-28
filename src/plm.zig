const std = @import("std");

pub const PlmError = error{
    InvalidSegment,
    TooManySegments,
    LengthTooLarge,
    TruncatedGroup,
};

/// Collects ordered PLM marker payloads. Payloads include Zplm but exclude the
/// marker and Lplm fields. Nplm/Iplm groups may cross marker boundaries, while
/// each marker segment must finish on a complete Iplm packet-length value.
pub const SegmentCollector = struct {
    allocator: std.mem.Allocator,
    lengths: std.ArrayList(usize) = .empty,
    group_ends: std.ArrayList(usize) = .empty,
    expected_index: u16 = 0,
    remaining_group_bytes: u16 = 0,
    pending_length: bool = false,
    current_length: usize = 0,

    pub fn init(allocator: std.mem.Allocator) SegmentCollector {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SegmentCollector) void {
        self.lengths.deinit(self.allocator);
        self.group_ends.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn append(self: *SegmentCollector, payload: []const u8) !void {
        if (payload.len < 2) return PlmError.InvalidSegment;
        if (self.expected_index > std.math.maxInt(u8)) return PlmError.TooManySegments;
        if (payload[0] != @as(u8, @intCast(self.expected_index))) {
            return PlmError.InvalidSegment;
        }

        var completed_length = false;
        for (payload[1..]) |byte| {
            if (self.remaining_group_bytes == 0) {
                self.remaining_group_bytes = byte;
                completed_length = false;
                if (self.remaining_group_bytes == 0) {
                    try self.group_ends.append(self.allocator, self.lengths.items.len);
                    completed_length = true;
                }
                continue;
            }

            self.current_length = std.math.mul(usize, self.current_length, 128) catch
                return PlmError.LengthTooLarge;
            self.current_length = std.math.add(usize, self.current_length, byte & 0x7f) catch
                return PlmError.LengthTooLarge;
            self.remaining_group_bytes -= 1;
            self.pending_length = (byte & 0x80) != 0;
            completed_length = !self.pending_length;
            if (completed_length) {
                try self.lengths.append(self.allocator, self.current_length);
                self.current_length = 0;
            }
            if (self.remaining_group_bytes == 0) {
                if (self.pending_length) return PlmError.InvalidSegment;
                try self.group_ends.append(self.allocator, self.lengths.items.len);
            }
        }
        if (!completed_length or self.pending_length) return PlmError.InvalidSegment;
        self.expected_index += 1;
    }

    pub fn finish(self: *SegmentCollector) !PacketLengths {
        if (self.expected_index == 0) return PlmError.InvalidSegment;
        if (self.remaining_group_bytes != 0 or self.pending_length) return PlmError.TruncatedGroup;
        const lengths = try self.lengths.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(lengths);
        const group_ends = try self.group_ends.toOwnedSlice(self.allocator);
        self.expected_index = 0;
        return .{
            .allocator = self.allocator,
            .lengths = lengths,
            .group_ends = group_ends,
        };
    }
};

pub const PacketLengths = struct {
    allocator: std.mem.Allocator,
    lengths: []usize,
    group_ends: []usize,

    pub fn deinit(self: *PacketLengths) void {
        self.allocator.free(self.lengths);
        self.allocator.free(self.group_ends);
        self.* = undefined;
    }

    pub fn groupAt(self: PacketLengths, index: usize) ?[]const usize {
        if (index >= self.group_ends.len) return null;
        const start = if (index == 0) 0 else self.group_ends[index - 1];
        return self.lengths[start..self.group_ends[index]];
    }
};

test "PLM collector preserves tile-part packet groups across segments" {
    var collector = SegmentCollector.init(std.testing.allocator);
    defer collector.deinit();
    // Group 0 has three Iplm bytes (lengths 130 and 5), then group 1 begins
    // with four bytes and continues in the next marker segment.
    try collector.append(&.{ 0, 3, 0x81, 0x02, 0x05, 4, 0x01 });
    try collector.append(&.{ 1, 0x82, 0x00, 0x07, 0, 1, 0, 0 });
    var lengths = try collector.finish();
    defer lengths.deinit();

    try std.testing.expectEqualSlices(usize, &.{ 130, 5 }, lengths.groupAt(0).?);
    try std.testing.expectEqualSlices(usize, &.{ 1, 256, 7 }, lengths.groupAt(1).?);
    try std.testing.expectEqualSlices(usize, &.{}, lengths.groupAt(2).?);
    try std.testing.expectEqualSlices(usize, &.{0}, lengths.groupAt(3).?);
    try std.testing.expectEqualSlices(usize, &.{}, lengths.groupAt(4).?);
    try std.testing.expect(lengths.groupAt(5) == null);
}

test "PLM collector rejects malformed ordering and incomplete lengths" {
    var wrong_index = SegmentCollector.init(std.testing.allocator);
    defer wrong_index.deinit();
    try std.testing.expectError(PlmError.InvalidSegment, wrong_index.append(&.{ 1, 1, 0 }));

    var split_varint = SegmentCollector.init(std.testing.allocator);
    defer split_varint.deinit();
    try std.testing.expectError(PlmError.InvalidSegment, split_varint.append(&.{ 0, 2, 0x81 }));

    var truncated_group = SegmentCollector.init(std.testing.allocator);
    defer truncated_group.deinit();
    try truncated_group.append(&.{ 0, 2, 1 });
    try std.testing.expectError(PlmError.TruncatedGroup, truncated_group.finish());
}
