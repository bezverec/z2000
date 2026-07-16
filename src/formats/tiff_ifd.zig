const std = @import("std");

pub const Error = error{
    InvalidHeader,
    InvalidIfd,
    InvalidTagValue,
    UnsupportedTiffVariant,
    TruncatedData,
};

pub const Endian = enum {
    little,
    big,

    pub fn label(self: Endian) []const u8 {
        return switch (self) {
            .little => "little",
            .big => "big",
        };
    }
};

pub const FieldType = enum(u16) {
    byte = 1,
    ascii = 2,
    short = 3,
    long = 4,
    rational = 5,
    sbyte = 6,
    undefined = 7,
    sshort = 8,
    slong = 9,
    srational = 10,
    float = 11,
    double = 12,
};

pub const Document = struct {
    bytes: []const u8,
    endian: Endian,
    first_ifd_offset: usize,

    pub fn parse(bytes: []const u8) Error!Document {
        if (bytes.len < 8) return Error.InvalidHeader;
        const endian: Endian = if (std.mem.eql(u8, bytes[0..2], "II"))
            .little
        else if (std.mem.eql(u8, bytes[0..2], "MM"))
            .big
        else
            return Error.InvalidHeader;

        const magic = try readU16(bytes, 2, endian);
        if (magic != 42) return Error.UnsupportedTiffVariant;

        const first_ifd_offset = @as(usize, try readU32(bytes, 4, endian));
        const document = Document{
            .bytes = bytes,
            .endian = endian,
            .first_ifd_offset = first_ifd_offset,
        };
        _ = try document.readIfd(first_ifd_offset);
        return document;
    }

    pub fn readIfd(self: Document, offset: usize) Error!Ifd {
        if (offset < 8 or offset > self.bytes.len - 2) return Error.InvalidIfd;
        const entry_count = try readU16(self.bytes, offset, self.endian);
        const entries_offset = offset + 2;
        const entries_bytes = std.math.mul(usize, entry_count, 12) catch return Error.InvalidIfd;
        if (entries_offset > self.bytes.len or self.bytes.len - entries_offset < entries_bytes + 4) {
            return Error.InvalidIfd;
        }
        const next_ifd_offset = @as(usize, try readU32(self.bytes, entries_offset + entries_bytes, self.endian));
        return .{
            .offset = offset,
            .entry_count = entry_count,
            .entries_offset = entries_offset,
            .next_ifd_offset = next_ifd_offset,
        };
    }

    pub fn entryAt(self: Document, ifd: Ifd, index: usize) Error!Entry {
        if (index >= ifd.entry_count) return Error.InvalidIfd;
        const offset = ifd.entries_offset + index * 12;
        return .{
            .tag = try readU16(self.bytes, offset, self.endian),
            .field_type = try readU16(self.bytes, offset + 2, self.endian),
            .count = try readU32(self.bytes, offset + 4, self.endian),
            .value_or_offset = try readU32(self.bytes, offset + 8, self.endian),
            .value_field_offset = offset + 8,
        };
    }

    pub fn findEntry(self: Document, ifd: Ifd, tag: u16) Error!?Entry {
        var index: usize = 0;
        while (index < ifd.entry_count) : (index += 1) {
            const entry = try self.entryAt(ifd, index);
            if (entry.tag == tag) return entry;
        }
        return null;
    }
};

pub const Ifd = struct {
    offset: usize,
    entry_count: u16,
    entries_offset: usize,
    next_ifd_offset: usize,
};

pub const Entry = struct {
    tag: u16,
    field_type: u16,
    count: u32,
    value_or_offset: u32,
    value_field_offset: usize,

    pub fn ref(self: Entry, document: Document) Error!ValueRef {
        const elem_size = typeSize(self.field_type) orelse return Error.InvalidTagValue;
        const count = @as(usize, self.count);
        const byte_count = std.math.mul(usize, count, elem_size) catch return Error.InvalidTagValue;
        const offset: ?usize = if (byte_count <= 4) null else @as(usize, self.value_or_offset);
        if (offset) |start| {
            if (start > document.bytes.len or document.bytes.len - start < byte_count) return Error.TruncatedData;
        } else if (self.value_field_offset > document.bytes.len or document.bytes.len - self.value_field_offset < byte_count) {
            return Error.TruncatedData;
        }
        return .{
            .field_type = self.field_type,
            .count = count,
            .byte_count = byte_count,
            .inline_offset = self.value_field_offset,
            .offset = offset,
        };
    }

    pub fn singleU16(self: Entry, document: Document) Error!u16 {
        const value_ref = try self.ref(document);
        if (value_ref.count != 1) return Error.InvalidTagValue;
        return value_ref.u16At(document, 0);
    }

    pub fn singleU32(self: Entry, document: Document) Error!u32 {
        const value_ref = try self.ref(document);
        if (value_ref.count != 1) return Error.InvalidTagValue;
        return value_ref.u32At(document, 0);
    }
};

pub const ValueRef = struct {
    field_type: u16,
    count: usize,
    byte_count: usize,
    inline_offset: usize,
    offset: ?usize,

    pub fn bytes(self: ValueRef, document: Document) []const u8 {
        const start = self.offset orelse self.inline_offset;
        return document.bytes[start .. start + self.byte_count];
    }

    pub fn byteAt(self: ValueRef, document: Document, index: usize) Error!u8 {
        if (index >= self.count) return Error.InvalidTagValue;
        return switch (self.field_type) {
            @intFromEnum(FieldType.byte), @intFromEnum(FieldType.ascii), @intFromEnum(FieldType.undefined) => self.bytes(document)[index],
            else => Error.InvalidTagValue,
        };
    }

    pub fn u16At(self: ValueRef, document: Document, index: usize) Error!u16 {
        if (index >= self.count) return Error.InvalidTagValue;
        return switch (self.field_type) {
            @intFromEnum(FieldType.short) => try readU16(self.bytes(document), index * 2, document.endian),
            else => Error.InvalidTagValue,
        };
    }

    pub fn u32At(self: ValueRef, document: Document, index: usize) Error!u32 {
        if (index >= self.count) return Error.InvalidTagValue;
        return switch (self.field_type) {
            @intFromEnum(FieldType.short) => try self.u16At(document, index),
            @intFromEnum(FieldType.long) => try readU32(self.bytes(document), index * 4, document.endian),
            else => Error.InvalidTagValue,
        };
    }

    pub fn rationalAt(self: ValueRef, document: Document, index: usize) Error!f64 {
        if (index >= self.count or self.field_type != @intFromEnum(FieldType.rational)) {
            return Error.InvalidTagValue;
        }
        const value_bytes = self.bytes(document);
        const numerator = try readU32(value_bytes, index * 8, document.endian);
        const denominator = try readU32(value_bytes, index * 8 + 4, document.endian);
        if (denominator == 0) return Error.InvalidTagValue;
        return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
    }

    pub fn srationalAt(self: ValueRef, document: Document, index: usize) Error!f64 {
        if (index >= self.count or self.field_type != @intFromEnum(FieldType.srational)) {
            return Error.InvalidTagValue;
        }
        const value_bytes = self.bytes(document);
        const numerator: i32 = @bitCast(try readU32(value_bytes, index * 8, document.endian));
        const denominator: i32 = @bitCast(try readU32(value_bytes, index * 8 + 4, document.endian));
        if (denominator == 0) return Error.InvalidTagValue;
        return @as(f64, @floatFromInt(numerator)) / @as(f64, @floatFromInt(denominator));
    }

    pub fn ascii(self: ValueRef, document: Document) Error![]const u8 {
        if (self.field_type != @intFromEnum(FieldType.ascii)) return Error.InvalidTagValue;
        return std.mem.sliceTo(self.bytes(document), 0);
    }
};

pub fn typeSize(field_type: u16) ?usize {
    return switch (field_type) {
        @intFromEnum(FieldType.byte),
        @intFromEnum(FieldType.ascii),
        @intFromEnum(FieldType.sbyte),
        @intFromEnum(FieldType.undefined),
        => 1,
        @intFromEnum(FieldType.short),
        @intFromEnum(FieldType.sshort),
        => 2,
        @intFromEnum(FieldType.long),
        @intFromEnum(FieldType.slong),
        @intFromEnum(FieldType.float),
        => 4,
        @intFromEnum(FieldType.rational),
        @intFromEnum(FieldType.srational),
        @intFromEnum(FieldType.double),
        => 8,
        else => null,
    };
}

pub fn readU16(bytes: []const u8, offset: usize, endian: Endian) Error!u16 {
    const end = std.math.add(usize, offset, 2) catch return Error.TruncatedData;
    if (end > bytes.len) return Error.TruncatedData;
    return switch (endian) {
        .little => @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8),
        .big => (@as(u16, bytes[offset]) << 8) | @as(u16, bytes[offset + 1]),
    };
}

pub fn readU32(bytes: []const u8, offset: usize, endian: Endian) Error!u32 {
    const end = std.math.add(usize, offset, 4) catch return Error.TruncatedData;
    if (end > bytes.len) return Error.TruncatedData;
    return switch (endian) {
        .little => @as(u32, bytes[offset]) |
            (@as(u32, bytes[offset + 1]) << 8) |
            (@as(u32, bytes[offset + 2]) << 16) |
            (@as(u32, bytes[offset + 3]) << 24),
        .big => (@as(u32, bytes[offset]) << 24) |
            (@as(u32, bytes[offset + 1]) << 16) |
            (@as(u32, bytes[offset + 2]) << 8) |
            @as(u32, bytes[offset + 3]),
    };
}
