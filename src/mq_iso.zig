const std = @import("std");
const mq = @import("mq.zig");

pub const IsoMqError = error{
    InvalidContext,
};

pub const DecodeBranchStats = struct {
    fast_mps: u64 = 0,
    lps: u64 = 0,
    renorm_mps: u64 = 0,
    renorm_shifts: u64 = 0,
    byte_in: u64 = 0,
};

const Context = struct {
    state: u8 = 0,
    mps: bool = false,
    qe: u16 = mq.state_table[0].qe,
    nmps: u8 = mq.state_table[0].nmps,
    nlps: u8 = mq.state_table[0].nlps,
    switch_mps: bool = mq.state_table[0].switch_mps,

    inline fn reset(self: *Context) void {
        self.* = .{};
    }

    inline fn setState(self: *Context, state_index: u8) void {
        const row = mq.state_table[state_index];
        self.state = state_index;
        self.qe = row.qe;
        self.nmps = row.nmps;
        self.nlps = row.nlps;
        self.switch_mps = row.switch_mps;
    }
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
        resetContextSlice(contexts);
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
        resetContextSlice(self.contexts);
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
        const qe = context.qe;

        const next_a = self.a - qe;
        if (bit == context.mps and (next_a & 0x8000) != 0) {
            self.a = next_a;
            self.c += qe;
            return;
        }

        self.a = next_a;
        if (bit == context.mps) {
            if ((self.a & 0x8000) == 0) {
                if (self.a < qe) {
                    self.a = qe;
                } else {
                    self.c += qe;
                }
                context.setState(context.nmps);
                try self.renormalize();
            } else {
                self.c += qe;
            }
        } else {
            if (self.a < qe) {
                self.c += qe;
            } else {
                self.a = qe;
            }
            if (context.switch_mps) context.mps = !context.mps;
            context.setState(context.nlps);
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

    /// Predictable (error-resilient) MQ termination — ISO 15444-1 D.4.2's
    /// ERTERM procedure, ported from OpenJPEG's opj_mqc_erterm_enc: flush
    /// the minimal deterministic byte pattern (no setbits), so a resilient
    /// decoder can verify the segment terminated where expected. The
    /// emitted segment still decodes with the standard MQ decoder because
    /// the spilled register bits are exactly what byte-in padding supplies.
    ///
    /// The exact output bytes are normative (kdu_expand/OpenJPEG/Grok decode
    /// the full-image ERTERM stream pixel-exactly). The test "ISO MQ ER-TERM
    /// flush matches interop-verified byte vectors" pins them, so any change to
    /// finishActiveStreamErterm that alters the flush fails in CI — re-run
    /// tools/interop_erterm.ps1 and refresh the golden vectors if it does.
    pub fn finishErterm(self: *Encoder) ![]u8 {
        std.debug.assert(self.output == null);
        try self.finishActiveStreamErterm();
        return self.bytes.toOwnedSlice(self.allocator);
    }

    pub fn finishErtermInto(self: *Encoder, output: *std.ArrayList(u8)) !usize {
        std.debug.assert(self.output == output);
        const start = self.output_start;
        try self.finishActiveStreamErterm();
        return output.items.len - start;
    }

    fn finishActiveStreamErterm(self: *Encoder) !void {
        var k: i32 = 11 - @as(i32, @intCast(self.ct)) + 1;
        while (k > 0) {
            self.c <<= @as(u5, @intCast(self.ct));
            self.ct = 0;
            try self.byteOut();
            k -= @as(i32, @intCast(self.ct));
        }
        const bytes = self.activeBytes();
        if (self.previousByteFrom(bytes) != 0xff) {
            const len_before_guard = bytes.items.len;
            try self.byteOut();
            if (bytes.items.len > len_before_guard) {
                _ = bytes.pop();
            }
        } else if (bytes.items.len > self.output_start) {
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
        const bytes = self.activeBytes();
        if (self.previousByteFrom(bytes) == 0xff) {
            try self.appendByteTo(bytes, @truncate(self.c >> 20));
            self.c &= 0x000f_ffff;
            self.ct = 7;
            return;
        }

        if ((self.c & 0x0800_0000) == 0) {
            try self.appendByteTo(bytes, @truncate(self.c >> 19));
            self.c &= 0x0007_ffff;
            self.ct = 8;
            return;
        }

        self.incrementPreviousByteIn(bytes);
        if (self.previousByteFrom(bytes) == 0xff) {
            self.c &= 0x07ff_ffff;
            try self.appendByteTo(bytes, @truncate(self.c >> 20));
            self.c &= 0x000f_ffff;
            self.ct = 7;
        } else {
            try self.appendByteTo(bytes, @truncate(self.c >> 19));
            self.c &= 0x0007_ffff;
            self.ct = 8;
        }
    }

    fn previousByteFrom(self: Encoder, bytes: *const std.ArrayList(u8)) u8 {
        if (bytes.items.len == self.output_start) return self.fake_previous;
        return bytes.items[bytes.items.len - 1];
    }

    fn incrementPreviousByteIn(self: *Encoder, bytes: *std.ArrayList(u8)) void {
        if (bytes.items.len == self.output_start) {
            self.fake_previous +%= 1;
        } else {
            bytes.items[bytes.items.len - 1] +%= 1;
        }
    }

    fn appendByte(self: *Encoder, byte: u8) !void {
        try self.appendByteTo(self.activeBytes(), byte);
    }

    fn appendByteTo(self: *Encoder, bytes: *std.ArrayList(u8), byte: u8) !void {
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
    current_byte: u8 = 0xff,
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
        resetContextSlice(contexts);
        const first = firstByte(bytes);

        var decoder = Decoder{
            .allocator = allocator,
            .contexts = contexts,
            .bytes = bytes,
            .current_byte = first,
            .c = @as(u32, first) << first_byte_shift,
        };
        decoder.byteIn();
        decoder.c <<= 7;
        decoder.ct -= 7;
        return decoder;
    }

    fn initAfterStuffedPreviousByte(allocator: std.mem.Allocator, context_count: usize, bytes: []const u8) !Decoder {
        if (context_count == 0) return IsoMqError.InvalidContext;
        const contexts = try allocator.alloc(Context, context_count);
        resetContextSlice(contexts);

        const first = if (bytes.len == 0) 0xff else bytes[0];
        var decoder = Decoder{
            .allocator = allocator,
            .contexts = contexts,
            .bytes = bytes,
            .current_byte = first,
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
        self.current_byte = firstByte(bytes);
        self.a = 0x8000;
        self.ct = 0;
        self.c = @as(u32, self.current_byte) << 16;
        self.byteIn();
        self.c <<= 7;
        self.ct -= 7;
    }

    pub fn resetContexts(self: *Decoder) void {
        resetContextSlice(self.contexts);
    }

    pub fn resetJpeg2000Contexts(self: *Decoder) !void {
        resetJpeg2000ContextSlice(self.contexts);
    }

    pub inline fn read(self: *Decoder, context_index: usize) !bool {
        return self.readUnchecked(context_index);
    }

    // Keep this branch layout in sync with readProfiled. The profiled variant
    // only adds counters around the same ISO MQ decode transitions.
    pub inline fn readUnchecked(self: *Decoder, context_index: usize) bool {
        std.debug.assert(context_index < self.contexts.len);
        const context = &self.contexts.ptr[context_index];
        const qe = context.qe;

        const next_a = self.a - qe;
        const c_high = self.c >> 16;
        self.a = next_a;
        if (c_high >= qe) {
            self.c -= @as(u32, qe) << 16;
            if ((next_a & 0x8000) != 0) return context.mps;
            const bit = self.exchangeMps(context, qe);
            self.renormalize();
            return bit;
        }

        const bit = self.exchangeLps(context, qe);
        self.renormalize();
        return bit;
    }

    // Keep this branch layout in sync with readUnchecked. Once the MPS side
    // misses its high-A fast return, that transition necessarily renormalizes.
    pub inline fn readProfiled(self: *Decoder, context_index: usize, stats: *DecodeBranchStats) bool {
        std.debug.assert(context_index < self.contexts.len);
        const context = &self.contexts.ptr[context_index];
        const qe = context.qe;

        const next_a = self.a - qe;
        const c_high = self.c >> 16;
        self.a = next_a;
        if (c_high >= qe) {
            self.c -= @as(u32, qe) << 16;
            if ((next_a & 0x8000) != 0) {
                stats.fast_mps += 1;
                return context.mps;
            }
            stats.renorm_mps += 1;
            const bit = self.exchangeMps(context, qe);
            self.renormalizeProfiled(stats);
            return bit;
        }

        stats.lps += 1;
        const bit = self.exchangeLps(context, qe);
        self.renormalizeProfiled(stats);
        return bit;
    }

    inline fn exchangeLps(self: *Decoder, context: *Context, qe: u16) bool {
        const lps_is_current_mps = self.a < qe;
        self.a = qe;
        if (lps_is_current_mps) {
            context.setState(context.nmps);
            return context.mps;
        }

        const bit = !context.mps;
        if (context.switch_mps) context.mps = !context.mps;
        context.setState(context.nlps);
        return bit;
    }

    inline fn exchangeMps(self: *Decoder, context: *Context, qe: u16) bool {
        if (self.a < qe) {
            const bit = !context.mps;
            if (context.switch_mps) context.mps = !context.mps;
            context.setState(context.nlps);
            return bit;
        }
        context.setState(context.nmps);
        return context.mps;
    }

    inline fn renormalize(self: *Decoder) void {
        while (self.a < 0x8000) {
            if (self.ct == 0) self.byteIn();
            const shift = self.renormalizeShift();
            self.a <<= shift;
            self.c <<= shift;
            self.ct -= shift;
        }
    }

    inline fn renormalizeProfiled(self: *Decoder, stats: *DecodeBranchStats) void {
        while (self.a < 0x8000) {
            if (self.ct == 0) {
                stats.byte_in += 1;
                self.byteIn();
            }
            const shift = self.renormalizeShift();
            stats.renorm_shifts += shift;
            self.a <<= shift;
            self.c <<= shift;
            self.ct -= shift;
        }
    }

    inline fn renormalizeShift(self: Decoder) u5 {
        std.debug.assert(self.a != 0);
        const needed: u8 = @intCast(@clz(self.a) - 16);
        return @intCast(@min(needed, self.ct));
    }

    inline fn byteIn(self: *Decoder) void {
        const current = self.current_byte;
        const next_index = self.pos + 1;
        const next = if (next_index < self.bytes.len) self.bytes[next_index] else 0xff;
        if (current == 0xff) {
            if (next > 0x8f) {
                self.c += 0xff00;
                self.ct = 8;
            } else {
                self.pos += 1;
                self.current_byte = next;
                self.c += @as(u32, next) << 9;
                self.ct = 7;
            }
            return;
        }

        self.pos += 1;
        self.current_byte = next;
        self.c += @as(u32, next) << 8;
        self.ct = 8;
    }
};

inline fn firstByte(bytes: []const u8) u8 {
    return if (bytes.len == 0) 0xff else bytes[0];
}

fn resetContextSlice(contexts: []Context) void {
    for (contexts) |*context| context.reset();
}

fn resetJpeg2000ContextSlice(contexts: []Context) void {
    resetContextSlice(contexts);
    if (contexts.len > 0) contexts[0].setState(4);
    if (contexts.len > 17) contexts[17].setState(3);
    if (contexts.len > 18) contexts[18].setState(46);
    if (contexts.len > 19) contexts[19].setState(46);
}
