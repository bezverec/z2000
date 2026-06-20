const std = @import("std");

pub const MqError = error{
    InvalidContext,
    InvalidData,
    TruncatedData,
};

pub const Symbol = struct {
    context: usize,
    bit: bool,
};

pub const Encoded = struct {
    symbol_count: usize,
    bytes: []u8,

    pub fn deinit(self: *Encoded, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const State = struct {
    qe: u16,
    nmps: u8,
    nlps: u8,
    switch_mps: bool,
};

pub const state_table = [_]State{
    .{ .qe = 0x5601, .nmps = 1, .nlps = 1, .switch_mps = true },
    .{ .qe = 0x3401, .nmps = 2, .nlps = 6, .switch_mps = false },
    .{ .qe = 0x1801, .nmps = 3, .nlps = 9, .switch_mps = false },
    .{ .qe = 0x0ac1, .nmps = 4, .nlps = 12, .switch_mps = false },
    .{ .qe = 0x0521, .nmps = 5, .nlps = 29, .switch_mps = false },
    .{ .qe = 0x0221, .nmps = 38, .nlps = 33, .switch_mps = false },
    .{ .qe = 0x5601, .nmps = 7, .nlps = 6, .switch_mps = true },
    .{ .qe = 0x5401, .nmps = 8, .nlps = 14, .switch_mps = false },
    .{ .qe = 0x4801, .nmps = 9, .nlps = 14, .switch_mps = false },
    .{ .qe = 0x3801, .nmps = 10, .nlps = 14, .switch_mps = false },
    .{ .qe = 0x3001, .nmps = 11, .nlps = 17, .switch_mps = false },
    .{ .qe = 0x2401, .nmps = 12, .nlps = 18, .switch_mps = false },
    .{ .qe = 0x1c01, .nmps = 13, .nlps = 20, .switch_mps = false },
    .{ .qe = 0x1601, .nmps = 29, .nlps = 21, .switch_mps = false },
    .{ .qe = 0x5601, .nmps = 15, .nlps = 14, .switch_mps = true },
    .{ .qe = 0x5401, .nmps = 16, .nlps = 14, .switch_mps = false },
    .{ .qe = 0x5101, .nmps = 17, .nlps = 15, .switch_mps = false },
    .{ .qe = 0x4801, .nmps = 18, .nlps = 16, .switch_mps = false },
    .{ .qe = 0x3801, .nmps = 19, .nlps = 17, .switch_mps = false },
    .{ .qe = 0x3401, .nmps = 20, .nlps = 18, .switch_mps = false },
    .{ .qe = 0x3001, .nmps = 21, .nlps = 19, .switch_mps = false },
    .{ .qe = 0x2801, .nmps = 22, .nlps = 19, .switch_mps = false },
    .{ .qe = 0x2401, .nmps = 23, .nlps = 20, .switch_mps = false },
    .{ .qe = 0x2201, .nmps = 24, .nlps = 21, .switch_mps = false },
    .{ .qe = 0x1c01, .nmps = 25, .nlps = 22, .switch_mps = false },
    .{ .qe = 0x1801, .nmps = 26, .nlps = 23, .switch_mps = false },
    .{ .qe = 0x1601, .nmps = 27, .nlps = 24, .switch_mps = false },
    .{ .qe = 0x1401, .nmps = 28, .nlps = 25, .switch_mps = false },
    .{ .qe = 0x1201, .nmps = 29, .nlps = 26, .switch_mps = false },
    .{ .qe = 0x1101, .nmps = 30, .nlps = 27, .switch_mps = false },
    .{ .qe = 0x0ac1, .nmps = 31, .nlps = 28, .switch_mps = false },
    .{ .qe = 0x09c1, .nmps = 32, .nlps = 29, .switch_mps = false },
    .{ .qe = 0x08a1, .nmps = 33, .nlps = 30, .switch_mps = false },
    .{ .qe = 0x0521, .nmps = 34, .nlps = 31, .switch_mps = false },
    .{ .qe = 0x0441, .nmps = 35, .nlps = 32, .switch_mps = false },
    .{ .qe = 0x02a1, .nmps = 36, .nlps = 33, .switch_mps = false },
    .{ .qe = 0x0221, .nmps = 37, .nlps = 34, .switch_mps = false },
    .{ .qe = 0x0141, .nmps = 38, .nlps = 35, .switch_mps = false },
    .{ .qe = 0x0111, .nmps = 39, .nlps = 36, .switch_mps = false },
    .{ .qe = 0x0085, .nmps = 40, .nlps = 37, .switch_mps = false },
    .{ .qe = 0x0049, .nmps = 41, .nlps = 38, .switch_mps = false },
    .{ .qe = 0x0025, .nmps = 42, .nlps = 39, .switch_mps = false },
    .{ .qe = 0x0015, .nmps = 43, .nlps = 40, .switch_mps = false },
    .{ .qe = 0x0009, .nmps = 44, .nlps = 41, .switch_mps = false },
    .{ .qe = 0x0005, .nmps = 45, .nlps = 42, .switch_mps = false },
    .{ .qe = 0x0001, .nmps = 45, .nlps = 43, .switch_mps = false },
    .{ .qe = 0x5601, .nmps = 46, .nlps = 46, .switch_mps = false },
};

const Context = struct {
    state: u8 = 0,
    mps: bool = false,

    fn reset(self: *Context) void {
        self.* = .{};
    }

    fn update(self: *Context, bit: bool) void {
        const state = state_table[self.state];
        if (bit == self.mps) {
            self.state = state.nmps;
        } else {
            if (state.switch_mps) self.mps = !self.mps;
            self.state = state.nlps;
        }
    }
};

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    contexts: []Context,
    writer: MarkerStuffedBitWriter,
    low: u64 = 0,
    high: u64 = max_code,
    pending: usize = 0,
    symbol_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, context_count: usize) !Encoder {
        if (context_count == 0) return MqError.InvalidContext;
        const contexts = try allocator.alloc(Context, context_count);
        @memset(contexts, .{});
        return .{
            .allocator = allocator,
            .contexts = contexts,
            .writer = MarkerStuffedBitWriter.init(allocator),
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.allocator.free(self.contexts);
        self.writer.deinit();
        self.* = undefined;
    }

    pub fn resetContext(self: *Encoder, context: usize) !void {
        if (context >= self.contexts.len) return MqError.InvalidContext;
        self.contexts[context].reset();
    }

    pub fn resetAll(self: *Encoder) void {
        @memset(self.contexts, .{});
        self.writer.resetRetainingCapacity();
        self.low = 0;
        self.high = max_code;
        self.pending = 0;
        self.symbol_count = 0;
    }

    pub fn write(self: *Encoder, context: usize, bit: bool) !void {
        if (context >= self.contexts.len) return MqError.InvalidContext;
        const split = splitFor(self.low, self.high, self.contexts[context]);
        if (bit == self.contexts[context].mps) {
            self.high = split;
        } else {
            self.low = split + 1;
        }

        try self.renormalize();
        self.contexts[context].update(bit);
        self.symbol_count += 1;
    }

    pub fn finish(self: *Encoder) !Encoded {
        try self.finalize();

        return .{
            .symbol_count = self.symbol_count,
            .bytes = try self.writer.finish(),
        };
    }

    pub fn finishInto(self: *Encoder, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !usize {
        try self.finalize();
        if (self.writer.used != 0) try self.writer.flushByte();
        const start = out.items.len;
        try out.appendSlice(allocator, self.writer.bytes.items);
        return out.items.len - start;
    }

    fn finalize(self: *Encoder) !void {
        self.pending += 1;
        if (self.low < quarter) {
            try self.emitBit(false);
            while (self.pending > 0) : (self.pending -= 1) try self.writer.writeBit(true);
        } else {
            try self.emitBit(true);
            while (self.pending > 0) : (self.pending -= 1) try self.writer.writeBit(false);
        }
    }

    fn renormalize(self: *Encoder) !void {
        while (true) {
            if (self.high < half) {
                try self.emitBit(false);
            } else if (self.low >= half) {
                try self.emitBit(true);
                self.low -= half;
                self.high -= half;
            } else if (self.low >= quarter and self.high < three_quarter) {
                self.pending += 1;
                self.low -= quarter;
                self.high -= quarter;
            } else {
                break;
            }
            self.low *= 2;
            self.high = self.high * 2 + 1;
        }
    }

    fn emitBit(self: *Encoder, bit: bool) !void {
        try self.writer.writeBit(bit);
        while (self.pending > 0) : (self.pending -= 1) {
            try self.writer.writeBit(!bit);
        }
    }
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    contexts: []Context,
    reader: MarkerStuffedBitReader,
    low: u64 = 0,
    high: u64 = max_code,
    code: u64 = 0,
    remaining: usize,

    pub fn init(allocator: std.mem.Allocator, context_count: usize, bytes: []const u8, symbol_count: usize) !Decoder {
        if (context_count == 0) return MqError.InvalidContext;
        const contexts = try allocator.alloc(Context, context_count);
        errdefer allocator.free(contexts);
        @memset(contexts, .{});

        var reader = MarkerStuffedBitReader.init(bytes);
        var code: u64 = 0;
        for (0..code_bits) |_| {
            code = code * 2 + @intFromBool(try reader.readBitPadded());
        }

        return .{
            .allocator = allocator,
            .contexts = contexts,
            .reader = reader,
            .code = code,
            .remaining = symbol_count,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.allocator.free(self.contexts);
        self.* = undefined;
    }

    pub fn resetContext(self: *Decoder, context: usize) !void {
        if (context >= self.contexts.len) return MqError.InvalidContext;
        self.contexts[context].reset();
    }

    pub fn read(self: *Decoder, context: usize) !bool {
        if (context >= self.contexts.len) return MqError.InvalidContext;
        if (self.remaining == 0) return MqError.InvalidData;

        const split = splitFor(self.low, self.high, self.contexts[context]);
        const bit = if (self.code <= split) self.contexts[context].mps else !self.contexts[context].mps;
        if (bit == self.contexts[context].mps) {
            self.high = split;
        } else {
            self.low = split + 1;
        }

        try self.renormalize();
        self.contexts[context].update(bit);
        self.remaining -= 1;
        return bit;
    }

    fn renormalize(self: *Decoder) !void {
        while (true) {
            if (self.high < half) {
                // already in lower half
            } else if (self.low >= half) {
                self.low -= half;
                self.high -= half;
                self.code -= half;
            } else if (self.low >= quarter and self.high < three_quarter) {
                self.low -= quarter;
                self.high -= quarter;
                self.code -= quarter;
            } else {
                break;
            }
            self.low *= 2;
            self.high = self.high * 2 + 1;
            self.code = self.code * 2 + @intFromBool(try self.reader.readBitPadded());
        }
    }
};

pub fn encode(allocator: std.mem.Allocator, context_count: usize, symbols: []const Symbol) !Encoded {
    var encoder = try Encoder.init(allocator, context_count);
    defer encoder.deinit();

    for (symbols) |symbol| {
        try encoder.write(symbol.context, symbol.bit);
    }

    return encoder.finish();
}

pub fn decode(allocator: std.mem.Allocator, context_count: usize, bytes: []const u8, symbol_count: usize, contexts: []const usize) ![]bool {
    if (contexts.len != symbol_count) return MqError.InvalidData;
    var decoder = try Decoder.init(allocator, context_count, bytes, symbol_count);
    defer decoder.deinit();

    const out = try allocator.alloc(bool, symbol_count);
    errdefer allocator.free(out);
    for (contexts, 0..) |context, index| {
        out[index] = try decoder.read(context);
    }
    return out;
}

fn splitFor(low: u64, high: u64, context: Context) u64 {
    const range = high - low + 1;
    const state = state_table[context.state];
    const lps_range = @max(@as(u64, 1), (range * @as(u64, state.qe)) / mq_probability_scale);
    const mps_range = range - lps_range;
    if (context.mps) {
        return low + lps_range - 1;
    }
    return low + mps_range - 1;
}

const code_bits = 48;
const max_code: u64 = (@as(u64, 1) << code_bits) - 1;
const half: u64 = @as(u64, 1) << (code_bits - 1);
const quarter: u64 = @as(u64, 1) << (code_bits - 2);
const three_quarter: u64 = quarter * 3;
const mq_probability_scale: u64 = 0x8000;

const MarkerStuffedBitWriter = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    current: u8 = 0,
    used: u4 = 0,
    bits_per_byte: u4 = 8,

    fn init(allocator: std.mem.Allocator) MarkerStuffedBitWriter {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *MarkerStuffedBitWriter) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    fn resetRetainingCapacity(self: *MarkerStuffedBitWriter) void {
        self.bytes.clearRetainingCapacity();
        self.current = 0;
        self.used = 0;
        self.bits_per_byte = 8;
    }

    fn writeBit(self: *MarkerStuffedBitWriter, bit: bool) !void {
        const shift = self.bits_per_byte - 1 - self.used;
        if (bit) self.current |= @as(u8, 1) << @as(u3, @intCast(shift));
        self.used += 1;
        if (self.used == self.bits_per_byte) {
            try self.flushByte();
        }
    }

    fn flushByte(self: *MarkerStuffedBitWriter) !void {
        const flushed = self.current;
        try self.bytes.append(self.allocator, flushed);
        self.current = 0;
        self.used = 0;
        self.bits_per_byte = if (flushed == 0xff) 7 else 8;
    }

    fn finish(self: *MarkerStuffedBitWriter) ![]u8 {
        if (self.used != 0) try self.flushByte();
        return self.bytes.toOwnedSlice(self.allocator);
    }
};

const MarkerStuffedBitReader = struct {
    bytes: []const u8,
    index: usize = 0,
    current: u8 = 0,
    remaining: u4 = 0,
    previous: ?u8 = null,

    fn init(bytes: []const u8) MarkerStuffedBitReader {
        return .{ .bytes = bytes };
    }

    fn readBitPadded(self: *MarkerStuffedBitReader) !bool {
        if (self.remaining == 0) {
            if (self.index >= self.bytes.len) return false;
            try self.loadByte();
        }

        self.remaining -= 1;
        return ((self.current >> @as(u3, @intCast(self.remaining))) & 1) != 0;
    }

    fn loadByte(self: *MarkerStuffedBitReader) !void {
        const byte = self.bytes[self.index];
        self.index += 1;
        if (self.previous == 0xff) {
            if ((byte & 0x80) != 0) return MqError.InvalidData;
            self.remaining = 7;
        } else {
            self.remaining = 8;
        }
        self.current = byte;
        self.previous = byte;
    }
};

test "MQ marker-stuffed bit IO inserts stuff bit after 0xff" {
    const allocator = std.testing.allocator;
    var writer = MarkerStuffedBitWriter.init(allocator);
    defer writer.deinit();

    for (0..8) |_| try writer.writeBit(true);
    try writer.writeBit(true);
    const bytes = try writer.finish();
    defer allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x40 }, bytes);

    var reader = MarkerStuffedBitReader.init(bytes);
    for (0..9) |_| {
        try std.testing.expect(try reader.readBitPadded());
    }
}
