const std = @import("std");
const mq = @import("mq.zig");

pub const IsoMqError = error{
    InvalidContext,
};

const Context = struct {
    state: u8 = 0,
    mps: bool = false,
};

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    contexts: []Context,
    bytes: std.ArrayList(u8) = .empty,
    output: ?*std.ArrayList(u8) = null,
    output_start: usize = 0,
    a: u32 = 0x8000,
    c: u32 = 0,
    ct: u8 = 12,
    fake_previous: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, context_count: usize) !Encoder {
        if (context_count == 0) return IsoMqError.InvalidContext;
        const contexts = try allocator.alloc(Context, context_count);
        @memset(contexts, .{});
        return .{
            .allocator = allocator,
            .contexts = contexts,
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.allocator.free(self.contexts);
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn resetContexts(self: *Encoder) void {
        @memset(self.contexts, .{});
    }

    pub fn resetJpeg2000Contexts(self: *Encoder) !void {
        resetJpeg2000ContextSlice(self.contexts);
    }

    pub fn resetStream(self: *Encoder) void {
        self.output = null;
        self.output_start = 0;
        self.bytes.clearRetainingCapacity();
        self.resetCoderState();
    }

    pub fn resetStreamInto(self: *Encoder, output: *std.ArrayList(u8)) void {
        self.output = output;
        self.output_start = output.items.len;
        self.resetCoderState();
    }

    fn resetCoderState(self: *Encoder) void {
        self.a = 0x8000;
        self.c = 0;
        self.ct = 12;
        self.fake_previous = 0;
    }

    pub fn resetStreamAfterPreviousByte(self: *Encoder, previous_byte: u8) void {
        self.resetStream();
        self.fake_previous = previous_byte;
    }

    pub fn emittedByteCount(self: Encoder) usize {
        return self.activeByteCount();
    }

    pub fn write(self: *Encoder, context_index: usize, bit: bool) !void {
        std.debug.assert(context_index < self.contexts.len);
        const context = &self.contexts.ptr[context_index];
        const state = mq.state_table[context.state];

        const next_a = self.a - state.qe;
        if (bit == context.mps and (next_a & 0x8000) != 0) {
            self.a = next_a;
            self.c += state.qe;
            return;
        }

        self.a = next_a;
        if (bit == context.mps) {
            if ((self.a & 0x8000) == 0) {
                if (self.a < state.qe) {
                    self.a = state.qe;
                } else {
                    self.c += state.qe;
                }
                context.state = state.nmps;
                try self.renormalize();
            } else {
                self.c += state.qe;
            }
        } else {
            if (self.a < state.qe) {
                self.c += state.qe;
            } else {
                self.a = state.qe;
            }
            if (state.switch_mps) context.mps = !context.mps;
            context.state = state.nlps;
            try self.renormalize();
        }
    }

    pub fn finish(self: *Encoder) ![]u8 {
        std.debug.assert(self.output == null);
        try self.finishActiveStream();
        return self.bytes.toOwnedSlice(self.allocator);
    }

    pub fn finishInto(self: *Encoder, output: *std.ArrayList(u8)) !usize {
        std.debug.assert(self.output == output);
        const start = self.output_start;
        try self.finishActiveStream();
        return output.items.len - start;
    }

    fn finishActiveStream(self: *Encoder) !void {
        self.setBits();
        self.c <<= @intCast(self.ct);
        try self.byteOut();
        self.c <<= @intCast(self.ct);
        try self.byteOut();
        const bytes = self.activeBytes();
        if (bytes.items.len > self.output_start and bytes.items[bytes.items.len - 1] == 0xff) {
            _ = bytes.pop();
        }
    }

    fn renormalize(self: *Encoder) !void {
        while ((self.a & 0x8000) == 0) {
            self.a <<= 1;
            self.c <<= 1;
            self.ct -= 1;
            if (self.ct == 0) try self.byteOut();
        }
    }

    fn setBits(self: *Encoder) void {
        const temp = self.c + self.a;
        self.c |= 0xffff;
        if (self.c >= temp) self.c -= 0x8000;
    }

    fn byteOut(self: *Encoder) !void {
        if (self.previousByte() == 0xff) {
            try self.appendByte(@truncate(self.c >> 20));
            self.c &= 0x000f_ffff;
            self.ct = 7;
            return;
        }

        if ((self.c & 0x0800_0000) == 0) {
            try self.appendByte(@truncate(self.c >> 19));
            self.c &= 0x0007_ffff;
            self.ct = 8;
            return;
        }

        self.incrementPreviousByte();
        if (self.previousByte() == 0xff) {
            self.c &= 0x07ff_ffff;
            try self.appendByte(@truncate(self.c >> 20));
            self.c &= 0x000f_ffff;
            self.ct = 7;
        } else {
            try self.appendByte(@truncate(self.c >> 19));
            self.c &= 0x0007_ffff;
            self.ct = 8;
        }
    }

    fn previousByte(self: Encoder) u8 {
        const bytes = self.activeBytesConst();
        if (bytes.items.len == self.output_start) return self.fake_previous;
        return bytes.items[bytes.items.len - 1];
    }

    fn incrementPreviousByte(self: *Encoder) void {
        const bytes = self.activeBytes();
        if (bytes.items.len == self.output_start) {
            self.fake_previous +%= 1;
        } else {
            bytes.items[bytes.items.len - 1] +%= 1;
        }
    }

    fn appendByte(self: *Encoder, byte: u8) !void {
        const bytes = self.activeBytes();
        if (bytes.items.len < bytes.capacity) {
            bytes.appendAssumeCapacity(byte);
        } else {
            try bytes.append(self.allocator, byte);
        }
    }

    fn activeBytes(self: *Encoder) *std.ArrayList(u8) {
        return self.output orelse &self.bytes;
    }

    fn activeBytesConst(self: Encoder) *const std.ArrayList(u8) {
        return self.output orelse &self.bytes;
    }

    fn activeByteCount(self: Encoder) usize {
        const bytes = self.activeBytesConst();
        return bytes.items.len - self.output_start;
    }
};

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    contexts: []Context,
    bytes: []const u8,
    pos: usize = 0,
    a: u32 = 0x8000,
    c: u32 = 0,
    ct: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, context_count: usize, bytes: []const u8) !Decoder {
        return initWithFirstByteShift(allocator, context_count, bytes, 16);
    }

    pub fn initAfterPreviousByte(allocator: std.mem.Allocator, context_count: usize, bytes: []const u8, previous_byte: u8) !Decoder {
        if (previous_byte != 0xff) return init(allocator, context_count, bytes);
        return initAfterStuffedPreviousByte(allocator, context_count, bytes);
    }

    fn initWithFirstByteShift(allocator: std.mem.Allocator, context_count: usize, bytes: []const u8, first_byte_shift: u5) !Decoder {
        if (context_count == 0) return IsoMqError.InvalidContext;
        const contexts = try allocator.alloc(Context, context_count);
        @memset(contexts, .{});

        var decoder = Decoder{
            .allocator = allocator,
            .contexts = contexts,
            .bytes = bytes,
            .c = @as(u32, if (bytes.len == 0) 0xff else bytes[0]) << first_byte_shift,
        };
        decoder.byteIn();
        decoder.c <<= 7;
        decoder.ct -= 7;
        return decoder;
    }

    fn initAfterStuffedPreviousByte(allocator: std.mem.Allocator, context_count: usize, bytes: []const u8) !Decoder {
        if (context_count == 0) return IsoMqError.InvalidContext;
        const contexts = try allocator.alloc(Context, context_count);
        @memset(contexts, .{});

        const first = if (bytes.len == 0) 0xff else bytes[0];
        var decoder = Decoder{
            .allocator = allocator,
            .contexts = contexts,
            .bytes = bytes,
            .c = @as(u32, 0xff) << 16,
        };
        if (first > 0x8f) {
            decoder.c += 0xff00;
            decoder.ct = 8;
        } else {
            decoder.c += @as(u32, first) << 9;
            decoder.ct = 7;
        }
        decoder.c <<= 7;
        decoder.ct -= 7;
        return decoder;
    }

    pub fn deinit(self: *Decoder) void {
        self.allocator.free(self.contexts);
        self.* = undefined;
    }

    /// Re-run INITDEC on a new terminated codeword segment while keeping the
    /// adaptive context states (BYPASS-style segment restart).
    pub fn reinitStream(self: *Decoder, bytes: []const u8) void {
        self.bytes = bytes;
        self.pos = 0;
        self.a = 0x8000;
        self.ct = 0;
        self.c = @as(u32, if (bytes.len == 0) 0xff else bytes[0]) << 16;
        self.byteIn();
        self.c <<= 7;
        self.ct -= 7;
    }

    pub fn resetContexts(self: *Decoder) void {
        @memset(self.contexts, .{});
    }

    pub fn resetJpeg2000Contexts(self: *Decoder) !void {
        resetJpeg2000ContextSlice(self.contexts);
    }

    pub fn read(self: *Decoder, context_index: usize) !bool {
        std.debug.assert(context_index < self.contexts.len);
        const context = &self.contexts.ptr[context_index];
        const state = mq.state_table[context.state];

        const next_a = self.a - state.qe;
        if ((self.c >> 16) >= state.qe and (next_a & 0x8000) != 0) {
            self.a = next_a;
            self.c -= @as(u32, state.qe) << 16;
            return context.mps;
        }

        self.a = next_a;
        if ((self.c >> 16) < state.qe) {
            const bit = self.exchangeLps(context, state);
            self.renormalize();
            return bit;
        }

        self.c -= @as(u32, state.qe) << 16;
        if ((self.a & 0x8000) == 0) {
            const bit = self.exchangeMps(context, state);
            self.renormalize();
            return bit;
        }
        return context.mps;
    }

    fn exchangeLps(self: *Decoder, context: *Context, state: mq.State) bool {
        const lps_is_current_mps = self.a < state.qe;
        self.a = state.qe;
        if (lps_is_current_mps) {
            context.state = state.nmps;
            return context.mps;
        }

        const bit = !context.mps;
        if (state.switch_mps) context.mps = !context.mps;
        context.state = state.nlps;
        return bit;
    }

    fn exchangeMps(self: *Decoder, context: *Context, state: mq.State) bool {
        if (self.a < state.qe) {
            const bit = !context.mps;
            if (state.switch_mps) context.mps = !context.mps;
            context.state = state.nlps;
            return bit;
        }
        context.state = state.nmps;
        return context.mps;
    }

    fn renormalize(self: *Decoder) void {
        while (self.a < 0x8000) {
            if (self.ct == 0) self.byteIn();
            self.a <<= 1;
            self.c <<= 1;
            self.ct -= 1;
        }
    }

    fn byteIn(self: *Decoder) void {
        const current = self.byteAt(self.pos);
        const next = self.byteAt(self.pos + 1);
        if (current == 0xff) {
            if (next > 0x8f) {
                self.c += 0xff00;
                self.ct = 8;
            } else {
                self.pos += 1;
                self.c += @as(u32, next) << 9;
                self.ct = 7;
            }
            return;
        }

        self.pos += 1;
        self.c += @as(u32, next) << 8;
        self.ct = 8;
    }

    fn byteAt(self: Decoder, index: usize) u8 {
        if (index < self.bytes.len) return self.bytes[index];
        return 0xff;
    }
};

fn resetJpeg2000ContextSlice(contexts: []Context) void {
    @memset(contexts, .{});
    if (contexts.len > 0) contexts[0].state = 4;
    if (contexts.len > 17) contexts[17].state = 3;
    if (contexts.len > 18) contexts[18].state = 46;
    if (contexts.len > 19) contexts[19].state = 46;
}
