const std = @import("std");

pub const EntropyError = error{
    InvalidMethod,
    InvalidData,
    TruncatedData,
};

pub const Method = enum(u8) {
    raw = 0,
    rle = 1,
    bit_rle = 2,
    arith = 3,
};

pub const Encoded = struct {
    method: Method,
    raw_len: u32,
    bytes: []u8,

    pub fn deinit(self: *Encoded, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const EncodedView = struct {
    method: Method,
    raw_len: u32,
    bytes: []const u8,
    owned_bytes: ?[]u8 = null,

    pub fn deinit(self: *EncodedView, allocator: std.mem.Allocator) void {
        if (self.owned_bytes) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};

pub const Scratch = struct {
    allocator: std.mem.Allocator,
    rle: std.ArrayList(u8) = .empty,
    bit_rle: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Scratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scratch) void {
        self.rle.deinit(self.allocator);
        self.bit_rle.deinit(self.allocator);
        self.* = undefined;
    }
};

pub fn encodeWithMethod(allocator: std.mem.Allocator, method: Method, input: []const u8) !Encoded {
    return switch (method) {
        .raw => .{
            .method = .raw,
            .raw_len = @as(u32, @intCast(input.len)),
            .bytes = try allocator.dupe(u8, input),
        },
        .rle => encodeRle(allocator, input),
        .bit_rle => encodeBitRle(allocator, input),
        .arith => encodeArithmetic(allocator, input),
    };
}

pub fn encodeAuto(allocator: std.mem.Allocator, input: []const u8) !Encoded {
    var view = try encodeAutoBorrowingRaw(allocator, input);
    defer view.deinit(allocator);

    return .{
        .method = view.method,
        .raw_len = view.raw_len,
        .bytes = try allocator.dupe(u8, view.bytes),
    };
}

pub fn encodeAutoBorrowingRaw(allocator: std.mem.Allocator, input: []const u8) !EncodedView {
    var scratch = Scratch.init(allocator);
    defer scratch.deinit();

    const view = try encodeAutoBorrowingRawScratch(&scratch, input);
    if (view.method == .raw) {
        return view;
    }

    const owned = try allocator.dupe(u8, view.bytes);
    return .{
        .method = view.method,
        .raw_len = view.raw_len,
        .bytes = owned,
        .owned_bytes = owned,
    };
}

pub fn encodeAutoBorrowingRawScratch(scratch: *Scratch, input: []const u8) !EncodedView {
    const rle = try encodeRleInto(scratch, input);
    const bit_rle = if (shouldTryBitRle(input))
        try encodeBitRleInto(scratch, input)
    else
        null;

    if (bit_rle) |view| {
        if (view.bytes.len < input.len and view.bytes.len <= rle.bytes.len) {
            return view;
        }
    }

    if (rle.bytes.len < input.len) {
        return rle;
    }

    return .{
        .method = .raw,
        .raw_len = @as(u32, @intCast(input.len)),
        .bytes = input,
        .owned_bytes = null,
    };
}

pub fn decode(
    allocator: std.mem.Allocator,
    method: Method,
    raw_len: u32,
    encoded: []const u8,
) ![]u8 {
    return switch (method) {
        .raw => decodeRaw(allocator, raw_len, encoded),
        .rle => decodeRle(allocator, raw_len, encoded),
        .bit_rle => decodeBitRle(allocator, raw_len, encoded),
        .arith => decodeArithmetic(allocator, raw_len, encoded),
    };
}

pub fn parseMethod(value: u8) !Method {
    return switch (value) {
        0 => .raw,
        1 => .rle,
        2 => .bit_rle,
        3 => .arith,
        else => EntropyError.InvalidMethod,
    };
}

fn decodeRaw(allocator: std.mem.Allocator, raw_len: u32, encoded: []const u8) ![]u8 {
    if (encoded.len != raw_len) return EntropyError.InvalidData;
    return allocator.dupe(u8, encoded);
}

fn encodeRle(allocator: std.mem.Allocator, input: []const u8) !Encoded {
    var scratch = Scratch.init(allocator);
    defer scratch.deinit();

    const view = try encodeRleInto(&scratch, input);
    return .{
        .method = view.method,
        .raw_len = view.raw_len,
        .bytes = try allocator.dupe(u8, view.bytes),
    };
}

fn encodeRleInto(scratch: *Scratch, input: []const u8) !EncodedView {
    scratch.rle.clearRetainingCapacity();
    var literal_start: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        const run_len = repeatedRun(input, i);
        if (run_len >= 4) {
            try flushLiteral(scratch.allocator, &scratch.rle, input[literal_start..i]);
            var remaining = run_len;
            while (remaining > 0) {
                const chunk = @min(remaining, 255);
                try scratch.rle.append(scratch.allocator, 1);
                try scratch.rle.append(scratch.allocator, @as(u8, @intCast(chunk)));
                try scratch.rle.append(scratch.allocator, input[i]);
                remaining -= chunk;
            }
            i += run_len;
            literal_start = i;
        } else {
            i += 1;
        }
    }

    try flushLiteral(scratch.allocator, &scratch.rle, input[literal_start..]);
    return .{
        .method = .rle,
        .raw_len = @as(u32, @intCast(input.len)),
        .bytes = scratch.rle.items,
    };
}

fn decodeRle(allocator: std.mem.Allocator, raw_len: u32, encoded: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, raw_len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded.len - i < 2) return EntropyError.TruncatedData;
        const tag = encoded[i];
        const len = encoded[i + 1];
        i += 2;
        if (len == 0) return EntropyError.InvalidData;

        switch (tag) {
            0 => {
                if (encoded.len - i < len) return EntropyError.TruncatedData;
                try out.appendSlice(allocator, encoded[i .. i + len]);
                i += len;
            },
            1 => {
                if (encoded.len - i < 1) return EntropyError.TruncatedData;
                try out.ensureUnusedCapacity(allocator, len);
                for (0..len) |_| out.appendAssumeCapacity(encoded[i]);
                i += 1;
            },
            else => return EntropyError.InvalidData,
        }
        if (out.items.len > raw_len) return EntropyError.InvalidData;
    }

    if (out.items.len != raw_len) return EntropyError.InvalidData;
    return out.toOwnedSlice(allocator);
}

fn encodeBitRle(allocator: std.mem.Allocator, input: []const u8) !Encoded {
    var scratch = Scratch.init(allocator);
    defer scratch.deinit();

    const view = try encodeBitRleInto(&scratch, input);
    return .{
        .method = view.method,
        .raw_len = view.raw_len,
        .bytes = try allocator.dupe(u8, view.bytes),
    };
}

fn encodeBitRleInto(scratch: *Scratch, input: []const u8) !EncodedView {
    scratch.bit_rle.clearRetainingCapacity();
    if (input.len == 0) {
        return .{
            .method = .bit_rle,
            .raw_len = 0,
            .bytes = scratch.bit_rle.items,
        };
    }

    const bit_count = input.len * 8;
    var bit_index: usize = 0;
    var current = bitAt(input, 0);
    var run_len: usize = 0;
    while (bit_index < bit_count) : (bit_index += 1) {
        const bit = bitAt(input, bit_index);
        if (bit == current and run_len < 127) {
            run_len += 1;
        } else {
            try appendBitRun(scratch.allocator, &scratch.bit_rle, current, run_len);
            current = bit;
            run_len = 1;
        }
    }
    try appendBitRun(scratch.allocator, &scratch.bit_rle, current, run_len);

    return .{
        .method = .bit_rle,
        .raw_len = @as(u32, @intCast(input.len)),
        .bytes = scratch.bit_rle.items,
    };
}

fn decodeBitRle(allocator: std.mem.Allocator, raw_len: u32, encoded: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, raw_len);
    errdefer allocator.free(out);
    @memset(out, 0);

    const total_bits = @as(usize, raw_len) * 8;
    var bit_index: usize = 0;
    for (encoded) |run| {
        const bit = (run & 0x80) != 0;
        const len = run & 0x7f;
        if (len == 0) return EntropyError.InvalidData;
        if (total_bits - bit_index < len) return EntropyError.InvalidData;
        if (bit) setBitRange(out, bit_index, len);
        bit_index += len;
    }

    if (bit_index != total_bits) return EntropyError.InvalidData;
    return out;
}

fn encodeArithmetic(allocator: std.mem.Allocator, input: []const u8) !Encoded {
    var writer = BitSink.init(allocator);
    errdefer writer.deinit();

    var model = BinaryModel{};
    var low: u64 = 0;
    var high: u64 = max_code;
    var pending: usize = 0;

    const bit_count = input.len * 8;
    for (0..bit_count) |i| {
        const bit = bitAt(input, i);
        const split = model.split(low, high);
        if (bit) {
            low = split + 1;
        } else {
            high = split;
        }

        while (true) {
            if (high < half) {
                try writer.writeBit(false);
                while (pending > 0) : (pending -= 1) try writer.writeBit(true);
            } else if (low >= half) {
                try writer.writeBit(true);
                while (pending > 0) : (pending -= 1) try writer.writeBit(false);
                low -= half;
                high -= half;
            } else if (low >= quarter and high < three_quarter) {
                pending += 1;
                low -= quarter;
                high -= quarter;
            } else {
                break;
            }
            low *= 2;
            high = high * 2 + 1;
        }

        model.update(bit);
    }

    pending += 1;
    if (low < quarter) {
        try writer.writeBit(false);
        while (pending > 0) : (pending -= 1) try writer.writeBit(true);
    } else {
        try writer.writeBit(true);
        while (pending > 0) : (pending -= 1) try writer.writeBit(false);
    }

    return .{
        .method = .arith,
        .raw_len = @as(u32, @intCast(input.len)),
        .bytes = try writer.finish(),
    };
}

fn decodeArithmetic(allocator: std.mem.Allocator, raw_len: u32, encoded: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, raw_len);
    errdefer allocator.free(out);
    @memset(out, 0);

    var reader = BitSource.init(encoded);
    var code: u64 = 0;
    for (0..code_bits) |_| {
        code = code * 2 + @intFromBool(reader.readBit());
    }

    var model = BinaryModel{};
    var low: u64 = 0;
    var high: u64 = max_code;
    const bit_count = @as(usize, raw_len) * 8;

    for (0..bit_count) |i| {
        const split = model.split(low, high);
        const bit = code > split;
        if (bit) {
            low = split + 1;
            setBit(out, i);
        } else {
            high = split;
        }

        while (true) {
            if (high < half) {
                // interval is already in the lower half
            } else if (low >= half) {
                code -= half;
                low -= half;
                high -= half;
            } else if (low >= quarter and high < three_quarter) {
                code -= quarter;
                low -= quarter;
                high -= quarter;
            } else {
                break;
            }
            low *= 2;
            high = high * 2 + 1;
            code = code * 2 + @intFromBool(reader.readBit());
        }

        model.update(bit);
    }

    return out;
}

const code_bits = 32;
const max_code: u64 = (@as(u64, 1) << code_bits) - 1;
const half: u64 = @as(u64, 1) << (code_bits - 1);
const quarter: u64 = @as(u64, 1) << (code_bits - 2);
const three_quarter: u64 = quarter * 3;

const BinaryModel = struct {
    zeros: u32 = 1,
    ones: u32 = 1,

    fn split(self: BinaryModel, low: u64, high: u64) u64 {
        const range = high - low + 1;
        const total = @as(u64, self.zeros) + self.ones;
        return low + (range * self.zeros) / total - 1;
    }

    fn update(self: *BinaryModel, bit: bool) void {
        if (bit) {
            self.ones += 1;
        } else {
            self.zeros += 1;
        }
        if (self.zeros + self.ones > 4096) {
            self.zeros = @max(1, (self.zeros + 1) / 2);
            self.ones = @max(1, (self.ones + 1) / 2);
        }
    }
};

fn flushLiteral(allocator: std.mem.Allocator, out: *std.ArrayList(u8), literal: []const u8) !void {
    var offset: usize = 0;
    while (offset < literal.len) {
        const chunk = @min(literal.len - offset, 255);
        try out.append(allocator, 0);
        try out.append(allocator, @as(u8, @intCast(chunk)));
        try out.appendSlice(allocator, literal[offset .. offset + chunk]);
        offset += chunk;
    }
}

fn repeatedRun(input: []const u8, start: usize) usize {
    var len: usize = 1;
    while (start + len < input.len and input[start + len] == input[start] and len < 255) {
        len += 1;
    }
    return len;
}

fn shouldTryBitRle(input: []const u8) bool {
    if (input.len <= 64) return true;

    var simple: usize = 0;
    for (input) |byte| {
        if (byte == 0x00 or byte == 0xff or byte == 0x80 or byte == 0x01) {
            simple += 1;
        }
    }
    return simple * 4 >= input.len * 3;
}

fn appendBitRun(allocator: std.mem.Allocator, out: *std.ArrayList(u8), bit: bool, len: usize) !void {
    if (len == 0 or len > 127) return EntropyError.InvalidData;
    const tag = (if (bit) @as(u8, 0x80) else @as(u8, 0)) | @as(u8, @intCast(len));
    try out.append(allocator, tag);
}

fn bitAt(bytes: []const u8, bit_index: usize) bool {
    const byte = bytes[bit_index / 8];
    const shift = @as(u3, @intCast(7 - (bit_index % 8)));
    return (byte & (@as(u8, 1) << shift)) != 0;
}

fn setBit(bytes: []u8, bit_index: usize) void {
    const shift = @as(u3, @intCast(7 - (bit_index % 8)));
    bytes[bit_index / 8] |= @as(u8, 1) << shift;
}

fn setBitRange(bytes: []u8, start: usize, len: usize) void {
    var bit_index = start;
    var remaining = len;

    while (remaining > 0 and bit_index % 8 != 0) {
        setBit(bytes, bit_index);
        bit_index += 1;
        remaining -= 1;
    }

    while (remaining >= 8) {
        bytes[bit_index / 8] = 0xff;
        bit_index += 8;
        remaining -= 8;
    }

    while (remaining > 0) {
        setBit(bytes, bit_index);
        bit_index += 1;
        remaining -= 1;
    }
}

const BitSink = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    current: u8 = 0,
    used: u4 = 0,

    fn init(allocator: std.mem.Allocator) BitSink {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *BitSink) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    fn writeBit(self: *BitSink, bit: bool) !void {
        if (bit) self.current |= @as(u8, 1) << @as(u3, @intCast(7 - self.used));
        self.used += 1;
        if (self.used == 8) {
            try self.bytes.append(self.allocator, self.current);
            self.current = 0;
            self.used = 0;
        }
    }

    fn finish(self: *BitSink) ![]u8 {
        if (self.used != 0) try self.bytes.append(self.allocator, self.current);
        self.current = 0;
        self.used = 0;
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

const BitSource = struct {
    bytes: []const u8,
    bit_index: usize = 0,

    fn init(bytes: []const u8) BitSource {
        return .{ .bytes = bytes };
    }

    fn readBit(self: *BitSource) bool {
        if (self.bit_index >= self.bytes.len * 8) {
            self.bit_index += 1;
            return false;
        }
        const bit = bitAt(self.bytes, self.bit_index);
        self.bit_index += 1;
        return bit;
    }
};
