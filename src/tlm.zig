const std = @import("std");

pub const Error = error{InvalidCodestream};

pub const Entry = struct {
    tile_index: u16,
    psot: u32,
};

/// A validated view of one TLM marker payload excluding Ltlm. Entries can be
/// decoded without allocation; callers concatenate segments in increasing
/// Ztlm order and pass the number of entries already collected as
/// `implicit_base` for ST=0 tile numbering.
pub const Segment = struct {
    entries: []const u8,
    tile_index_bytes: u8,
    length_bytes: u8,
    implicit_base: usize,
    count: usize,

    pub fn entry(self: Segment, index: usize) Error!Entry {
        if (index >= self.count) return Error.InvalidCodestream;
        const entry_bytes = @as(usize, self.tile_index_bytes) + self.length_bytes;
        const offset = index * entry_bytes;
        const tile_index: u16 = switch (self.tile_index_bytes) {
            0 => @intCast(self.implicit_base + index),
            1 => self.entries[offset],
            2 => readU16Be(self.entries, offset),
            else => unreachable,
        };
        const length_offset = offset + self.tile_index_bytes;
        const psot: u32 = switch (self.length_bytes) {
            2 => readU16Be(self.entries, length_offset),
            4 => readU32Be(self.entries, length_offset),
            else => unreachable,
        };
        return .{ .tile_index = tile_index, .psot = psot };
    }
};

/// ISO/IEC 15444-1 A.7.1 TLM syntax. Supports ST=0/1/2 and SP=0/1, rejects
/// reserved ST=3 and malformed lengths, and assigns ST=0 tile indices from the
/// concatenated TLM entry position. ST=0 is later reconciled with the SOT walk,
/// which enforces one tile-part per tile in 0..N-1 order.
pub fn parse(segment: []const u8, expected_index: usize, implicit_base: usize) Error!Segment {
    if (segment.len < 4 or expected_index > std.math.maxInt(u8) or
        segment[0] != @as(u8, @intCast(expected_index)))
    {
        return Error.InvalidCodestream;
    }
    const stlm = segment[1];
    if ((stlm & 0x0f) != 0) return Error.InvalidCodestream;
    const tile_index_bytes: u8 = (stlm >> 4) & 0x03;
    if (tile_index_bytes == 3) return Error.InvalidCodestream;
    const length_bytes: u8 = if (((stlm >> 6) & 0x01) == 0) 2 else 4;
    const entry_bytes = @as(usize, tile_index_bytes) + length_bytes;
    const entries = segment[2..];
    if (entries.len == 0 or entries.len % entry_bytes != 0) {
        return Error.InvalidCodestream;
    }
    const count = entries.len / entry_bytes;
    if (tile_index_bytes == 0) {
        const end = std.math.add(usize, implicit_base, count) catch
            return Error.InvalidCodestream;
        // Part 1 Isot is 0..65534, so at most 65535 implicit tiles exist.
        if (end > @as(usize, std.math.maxInt(u16))) return Error.InvalidCodestream;
    }

    const result = Segment{
        .entries = entries,
        .tile_index_bytes = tile_index_bytes,
        .length_bytes = length_bytes,
        .implicit_base = implicit_base,
        .count = count,
    };
    for (0..count) |index| {
        const parsed = try result.entry(index);
        if ((tile_index_bytes == 1 and parsed.tile_index == std.math.maxInt(u8)) or
            (tile_index_bytes == 2 and parsed.tile_index == std.math.maxInt(u16)) or
            parsed.psot < 14)
        {
            return Error.InvalidCodestream;
        }
    }
    return result;
}

fn readU16Be(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readU32Be(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}

test "all six legal ST and SP layouts decode identically" {
    const cases = [_]struct {
        bytes: []const u8,
        explicit_tile: bool,
    }{
        .{ .bytes = &.{ 0, 0x00, 0, 14 }, .explicit_tile = false },
        .{ .bytes = &.{ 0, 0x40, 0, 0, 0, 14 }, .explicit_tile = false },
        .{ .bytes = &.{ 0, 0x10, 7, 0, 14 }, .explicit_tile = true },
        .{ .bytes = &.{ 0, 0x50, 7, 0, 0, 0, 14 }, .explicit_tile = true },
        .{ .bytes = &.{ 0, 0x20, 0, 7, 0, 14 }, .explicit_tile = true },
        .{ .bytes = &.{ 0, 0x60, 0, 7, 0, 0, 0, 14 }, .explicit_tile = true },
    };
    for (cases) |case| {
        const segment = try parse(case.bytes, 0, 3);
        try std.testing.expectEqual(@as(usize, 1), segment.count);
        const entry = try segment.entry(0);
        try std.testing.expectEqual(@as(u16, if (case.explicit_tile) 7 else 3), entry.tile_index);
        try std.testing.expectEqual(@as(u32, 14), entry.psot);
    }
}

test "implicit ST zero continues across marker segments" {
    const first = try parse(&.{ 0, 0x00, 0, 14, 0, 15 }, 0, 0);
    try std.testing.expectEqual(@as(u16, 0), (try first.entry(0)).tile_index);
    try std.testing.expectEqual(@as(u16, 1), (try first.entry(1)).tile_index);
    const second = try parse(&.{ 1, 0x40, 0, 0, 0, 16 }, 1, first.count);
    try std.testing.expectEqual(@as(u16, 2), (try second.entry(0)).tile_index);
}

test "TLM parser rejects malformed or reserved layouts" {
    const malformed = [_][]const u8{
        &.{},
        &.{ 0, 0 },
        &.{ 1, 0x00, 0, 14 },
        &.{ 0, 0x01, 0, 14 },
        &.{ 0, 0x30, 0, 0, 14 },
        &.{ 0, 0x00, 0 },
        &.{ 0, 0x00, 0, 13 },
        &.{ 0, 0x10, 0xff, 0, 14 },
        &.{ 0, 0x20, 0xff, 0xff, 0, 14 },
    };
    for (malformed) |bytes| {
        try std.testing.expectError(Error.InvalidCodestream, parse(bytes, 0, 0));
    }
    try std.testing.expectError(Error.InvalidCodestream, parse(&.{ 0, 0x00, 0, 14 }, 0, std.math.maxInt(u16)));
    try std.testing.expectError(Error.InvalidCodestream, parse(&.{ 0, 0x00, 0, 14 }, 256, 0));
}
