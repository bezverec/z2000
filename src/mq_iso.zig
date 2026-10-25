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

/// An adaptive context with its MPS folded into the state index
/// (2 * state + mps). Every transition copies one precomputed context, the
/// MPS switch of Table C.2 already applied, instead of updating its fields
/// one by one.
const Context = extern struct {
    qe: u16,
    mps: bool,
    /// Folded index after an MPS decision that renormalizes.
    nmps: u8,
    /// Folded index after an LPS decision.
    nlps: u8,
    padding: [3]u8 = .{ 0, 0, 0 },

    inline fn reset(self: *Context) void {
        self.* = folded_contexts[0];
    }

    /// Initial state for a context whose MPS is 0.
    inline fn setState(self: *Context, state_index: u8) void {
        self.* = folded_contexts[2 * @as(usize, state_index)];
    }

    inline fn takeMps(self: *Context) void {
        self.* = folded_contexts[self.nmps];
    }

    inline fn takeLps(self: *Context) void {
        self.* = folded_contexts[self.nlps];
    }
};

const folded_contexts = makeFoldedContexts();

fn makeFoldedContexts() [2 * mq.state_table.len]Context {
    var table: [2 * mq.state_table.len]Context = undefined;
    for (mq.state_table, 0..) |row, state| {
        for (0..2) |mps| {
            const lps_mps = if (row.switch_mps) 1 - mps else mps;
            table[2 * state + mps] = .{
                .qe = row.qe,
                .mps = mps == 1,
                .nmps = @intCast(2 * @as(usize, row.nmps) + mps),
                .nlps = @intCast(2 * @as(usize, row.nlps) + lps_mps),
            };
        }
    }
    return table;
}

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

    /// The coder state at a truncation point of a continuous codeword; see
    /// truncationLength.
    pub fn passEnd(self: *const Encoder) PassEnd {
        const bytes = self.output orelse &self.bytes;
        return .{
            .emitted = bytes.items.len - self.output_start,
            .previous_byte = self.previousByteFrom(bytes),
            .c = self.c,
            .a = self.a,
            .ct = self.ct,
        };
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
                context.takeMps();
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
            context.takeLps();
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
};

/// Encoder registers at a coding-pass boundary of a continuous codeword: the
/// bytes emitted so far (a carry can still increment the last of them) and
/// the interval [C, C + A) below them (C.2).
pub const PassEnd = struct {
    emitted: usize,
    previous_byte: u8,
    c: u32,
    a: u32,
    ct: u8,
};

/// The truncation length of the coding pass ending at `pass_end`: the
/// shortest prefix of the finished codeword `codeword` (coded from a
/// resetStream state) from which a decoder recovers every decision coded
/// before that boundary. The emitted byte count is not one: the decisions
/// still in the C register are missing from it, so a decoder reading only
/// those bytes misdecodes the end of the pass.
///
/// A decoder reads past the end of a codeword as 0xFF bytes, i.e. one bits
/// (C.3.4), so a prefix of length L stands for the value
/// prefix(L) + ulp(L), and the decisions before the boundary decode
/// correctly exactly when that value lies above the low end of the
/// boundary's interval [low, low + A) and at most at its high end. The value
/// usually exceeds the finished codeword's own, which is in the interval,
/// but not when the first byte left out is a 0xFF whose successor carries
/// into its stuffed msb (0xFF 0x85 adds up to more than one ulp), so both
/// ends are checked. Values are compared relative to the bytes before index
/// emitted - 1, which no later carry changes, and the search starts there:
/// no shorter prefix stays below the high end. It ends within a few bytes
/// of the emitted ones, once ulp(L) is below the weight of the C register's
/// lsb and no carry follows. A prefix never ends on 0xFF: dropping a final
/// 0xFF leaves the padded value unchanged, and such a contribution could
/// form a marker with the bytes after it.
pub fn truncationLength(pass_end: PassEnd, codeword: []const u8) usize {
    std.debug.assert(pass_end.emitted <= codeword.len);
    std.debug.assert(pass_end.ct >= 1 and pass_end.ct <= 12);
    // Scales weights so the bytes searched past the emitted ones keep a
    // positive exponent: weight 2^frame is the C register's lsb.
    const frame: u8 = 64;
    const one: u128 = 1;
    const emitted = pass_end.emitted;
    // Exponent of the lsb weight of byte emitted - 1 (the C register's carry
    // bit lands on it after ct more shifts).
    var lsb: u8 = 27 - pass_end.ct + frame;
    const low = (@as(u128, pass_end.previous_byte) << @intCast(lsb)) + (@as(u128, pass_end.c) << frame);
    const high = low + (@as(u128, pass_end.a) << frame);

    if (emitted > 0) {
        const before: u8 = if (emitted > 1) codeword[emitted - 2] else 0;
        const padded = one << @intCast(lsb + @as(u8, if (before == 0xff) 7 else 8));
        if (padded > low and padded <= high) return withoutFinalFf(codeword, emitted - 1);
    }

    var previous = if (emitted > 0) codeword[emitted - 1] else pass_end.previous_byte;
    var value = @as(u128, previous) << @intCast(lsb);
    var length = emitted;
    while (true) {
        const padded = value + (one << @intCast(lsb));
        if (padded > low and padded <= high) return withoutFinalFf(codeword, length);
        // The whole codeword always decodes; the lsb bound only guards the
        // weights (the search ends far above it).
        if (length == codeword.len or lsb < 16) return codeword.len;
        // Bit stuffing: the byte after 0xFF carries seven bits, its msb
        // overlapping the 0xFF's lsb.
        lsb -= if (previous == 0xff) 7 else 8;
        previous = codeword[length];
        value += @as(u128, previous) << @intCast(lsb);
        length += 1;
    }
}

fn withoutFinalFf(codeword: []const u8, length: usize) usize {
    var trimmed = length;
    while (trimmed > 0 and codeword[trimmed - 1] == 0xff) trimmed -= 1;
    return trimmed;
}

pub const Decoder = struct {
    allocator: std.mem.Allocator,
    contexts: []Context,
    bytes: []const u8,
    pos: usize = 0,
    current_byte: u8 = 0xff,
    a: u32 = 0x8000,
    /// The C register of C.3.1 in bits 32..63; the bits below buffer the
    /// following code bytes, so renormalization is one shift and BYTEIN
    /// runs in batches. `ct` counts the buffered bits (C.3's CT plus every
    /// byte read ahead).
    c: u64 = 0,
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
            .c = @as(u64, first) << (@as(u6, first_byte_shift) + 32),
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
            .c = @as(u64, 0xff) << 48,
        };
        if (first > 0x8f) {
            decoder.c += @as(u64, 0xff00) << 32;
            decoder.ct = 8;
        } else {
            decoder.c += @as(u64, first) << 41;
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
        self.c = @as(u64, self.current_byte) << 48;
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
        const c_high = self.c >> 48;
        self.a = next_a;
        if (c_high >= qe) {
            self.c -= @as(u64, qe) << 48;
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
        const c_high = self.c >> 48;
        self.a = next_a;
        if (c_high >= qe) {
            self.c -= @as(u64, qe) << 48;
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
            const bit = context.mps;
            context.takeMps();
            return bit;
        }

        const bit = !context.mps;
        context.takeLps();
        return bit;
    }

    inline fn exchangeMps(self: *Decoder, context: *Context, qe: u16) bool {
        if (self.a < qe) {
            const bit = !context.mps;
            context.takeLps();
            return bit;
        }
        const bit = context.mps;
        context.takeMps();
        return bit;
    }

    /// RENORMD as one shift: A doubles until it reaches 0x8000, and C takes
    /// as many buffered bits, refilled first when too few are left.
    inline fn renormalize(self: *Decoder) void {
        const shift = renormalizeShift(self.a);
        if (self.ct < shift) _ = self.fill();
        self.a <<= shift;
        self.c <<= shift;
        self.ct -= shift;
    }

    inline fn renormalizeProfiled(self: *Decoder, stats: *DecodeBranchStats) void {
        const shift = renormalizeShift(self.a);
        if (self.ct < shift) stats.byte_in += self.fill();
        stats.renorm_shifts += shift;
        self.a <<= shift;
        self.c <<= shift;
        self.ct -= shift;
    }

    inline fn renormalizeShift(a: u32) u5 {
        std.debug.assert(a != 0 and a < 0x8000);
        return @intCast(@clz(a) - 16);
    }

    /// Buffers code bytes until more than 32 bits wait below C, which covers
    /// any single renormalization (at most 15 bits); returns the BYTEIN count.
    fn fill(self: *Decoder) u64 {
        var count: u64 = 0;
        while (self.ct <= 32) : (count += 1) self.byteIn();
        return count;
    }

    /// BYTEIN of C.3.4, appending the next byte below the buffered bits
    /// (bit 40 - ct is where C.3's `C + (B << 8)` lands when CT is 0).
    inline fn byteIn(self: *Decoder) void {
        const current = self.current_byte;
        const next_index = self.pos + 1;
        const next = if (next_index < self.bytes.len) self.bytes[next_index] else 0xff;
        const position: u6 = @intCast(40 - @as(u8, self.ct));
        if (current == 0xff) {
            if (next > 0x8f) {
                self.c += @as(u64, 0xff) << position;
                self.ct += 8;
            } else {
                self.pos += 1;
                self.current_byte = next;
                self.c += @as(u64, next) << (position + 1);
                self.ct += 7;
            }
            return;
        }

        self.pos += 1;
        self.current_byte = next;
        self.c += @as(u64, next) << position;
        self.ct += 8;
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
