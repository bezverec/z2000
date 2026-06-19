const std = @import("std");

pub const PacketHeaderError = error{
    InvalidMarkerStuffing,
    TruncatedHeader,
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
