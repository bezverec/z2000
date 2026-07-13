const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options.zig");
const mq = @import("mq.zig");
const mq_iso = @import("mq_iso.zig");
const simd = @import("simd.zig");
const subband = @import("subband.zig");

pub const EbcotError = error{
    InvalidBlock,
};

const max_codeblock_area = 4096;
pub const mq_context_count = @typeInfo(Context).@"enum".fields.len;

pub const PassKind = enum(u8) {
    significance = 0,
    refinement = 1,
    cleanup = 2,
};

pub const DecodePassStats = struct {
    mq_passes: [3]u64 = .{0} ** 3,
    mq_symbols: [3]u64 = .{0} ** 3,
    mq_ns: [3]u64 = .{0} ** 3,
    mq_fast_mps: [3]u64 = .{0} ** 3,
    mq_lps: [3]u64 = .{0} ** 3,
    mq_renorm_mps: [3]u64 = .{0} ** 3,
    mq_renorm_shifts: [3]u64 = .{0} ** 3,
    mq_byte_in: [3]u64 = .{0} ** 3,
    raw_passes: [3]u64 = .{0} ** 3,
    raw_symbols: [3]u64 = .{0} ** 3,
    raw_ns: [3]u64 = .{0} ** 3,

    pub fn addMq(self: *DecodePassStats, kind: PassKind, symbols: usize, ns: u64) void {
        const index = passKindIndex(kind);
        self.mq_passes[index] += 1;
        self.mq_symbols[index] += symbols;
        self.mq_ns[index] += ns;
    }

    pub fn addMqBranches(self: *DecodePassStats, kind: PassKind, branches: mq_iso.DecodeBranchStats) void {
        const index = passKindIndex(kind);
        self.mq_fast_mps[index] += branches.fast_mps;
        self.mq_lps[index] += branches.lps;
        self.mq_renorm_mps[index] += branches.renorm_mps;
        self.mq_renorm_shifts[index] += branches.renorm_shifts;
        self.mq_byte_in[index] += branches.byte_in;
    }

    pub fn addRaw(self: *DecodePassStats, kind: PassKind, symbols: usize, ns: u64) void {
        const index = passKindIndex(kind);
        self.raw_passes[index] += 1;
        self.raw_symbols[index] += symbols;
        self.raw_ns[index] += ns;
    }

    pub fn merge(self: *DecodePassStats, other: DecodePassStats) void {
        inline for (0..3) |index| {
            self.mq_passes[index] += other.mq_passes[index];
            self.mq_symbols[index] += other.mq_symbols[index];
            self.mq_ns[index] += other.mq_ns[index];
            self.mq_fast_mps[index] += other.mq_fast_mps[index];
            self.mq_lps[index] += other.mq_lps[index];
            self.mq_renorm_mps[index] += other.mq_renorm_mps[index];
            self.mq_renorm_shifts[index] += other.mq_renorm_shifts[index];
            self.mq_byte_in[index] += other.mq_byte_in[index];
            self.raw_passes[index] += other.raw_passes[index];
            self.raw_symbols[index] += other.raw_symbols[index];
            self.raw_ns[index] += other.raw_ns[index];
        }
    }
};

fn passKindIndex(kind: PassKind) usize {
    return @intFromEnum(kind);
}

pub const Context = enum(u8) {
    zero0 = 0,
    zero1 = 1,
    zero2 = 2,
    zero3 = 3,
    zero4 = 4,
    zero5 = 5,
    zero6 = 6,
    zero7 = 7,
    zero8 = 8,
    sign0 = 9,
    sign1 = 10,
    sign2 = 11,
    sign3 = 12,
    sign4 = 13,
    refinement = 14,
    refinement_neighbor = 15,
    refinement_later = 16,
    cleanup_aggregation = 17,
    cleanup_run = 18,
    segmentation_symbol = 19,
};

pub const SymbolKind = enum(u8) {
    zero_coding,
    sign,
    magnitude_refinement,
    cleanup_aggregation,
    cleanup_run_length,
    segmentation_symbol,
};

pub const Symbol = struct {
    pass_index: u16,
    kind: SymbolKind,
    context: Context,
    bit: bool,
    x: usize,
    y: usize,
    magnitude_bitplane: u8,
};

pub const MqEncoded = mq.Encoded;

pub const TruncationPoint = struct {
    cumulative_passes: u16,
    cumulative_bytes: u64,
};

pub const Pass = struct {
    kind: PassKind,
    magnitude_bitplane: u8,
    first_symbol: usize,
    symbol_count: usize,
};

pub const CodeBlockPassPayload = struct {
    kind: PassKind,
    magnitude_bitplane: u8,
    symbol_count: usize,
    byte_offset: usize,
    byte_length: usize,
    cumulative_bytes: u64,
};

pub const EncodedBlock = struct {
    bitplanes: u8,
    non_zero_count: u32,
    passes: []Pass,
    symbols: []Symbol,

    pub fn deinit(self: *EncodedBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.passes);
        allocator.free(self.symbols);
        self.* = undefined;
    }
};

pub const SegmentSpan = struct {
    pass_count: u16,
    byte_length: u64,
};

pub const CodeBlockSegment = struct {
    bitplanes: u8,
    non_zero_count: u32,
    pass_count: u16,
    byte_length: u64,
    passes: []CodeBlockPassPayload,
    bytes: []u8,
    /// Terminated codeword segment table for BYPASS-style multi-segment
    /// payloads; null means one continuous segment.
    segments: ?[]SegmentSpan = null,

    pub fn deinit(self: *CodeBlockSegment, allocator: std.mem.Allocator) void {
        allocator.free(self.passes);
        allocator.free(self.bytes);
        if (self.segments) |segments| allocator.free(segments);
        self.* = undefined;
    }

    pub fn truncationPointForPasses(self: CodeBlockSegment, pass_count: u16) !TruncationPoint {
        if (pass_count > self.pass_count) return EbcotError.InvalidBlock;
        if (pass_count == 0) return .{ .cumulative_passes = 0, .cumulative_bytes = 0 };
        return .{
            .cumulative_passes = pass_count,
            .cumulative_bytes = self.passes[pass_count - 1].cumulative_bytes,
        };
    }
};

pub const CodeBlockStyle = struct {
    band_kind: subband.Kind = .ll,
    bypass: bool = false,
    reset_context: bool = false,
    terminate_all: bool = false,
    vertical_causal: bool = false,
    predictable_termination: bool = false,
    segmentation_symbols: bool = false,

    pub fn fromCodByte(byte: u8) ?CodeBlockStyle {
        if ((byte & ~@as(u8, 0x3f)) != 0) return null;
        return .{
            .bypass = (byte & 0x01) != 0,
            .reset_context = (byte & 0x02) != 0,
            .terminate_all = (byte & 0x04) != 0,
            .vertical_causal = (byte & 0x08) != 0,
            .predictable_termination = (byte & 0x10) != 0,
            .segmentation_symbols = (byte & 0x20) != 0,
        };
    }

    pub fn toCodByte(self: CodeBlockStyle) u8 {
        var byte: u8 = 0;
        if (self.bypass) byte |= 0x01;
        if (self.reset_context) byte |= 0x02;
        if (self.terminate_all) byte |= 0x04;
        if (self.vertical_causal) byte |= 0x08;
        if (self.predictable_termination) byte |= 0x10;
        if (self.segmentation_symbols) byte |= 0x20;
        return byte;
    }

    pub fn hasUnsupportedPayloadMode(self: CodeBlockStyle) bool {
        // Every Part 1 style-bit combination has an implemented ISO-MQ
        // payload model now: RESET restarts the MQ contexts at coding-pass
        // boundaries in the continuous, BYPASS, TERMALL, and BYPASS+TERMALL
        // segment models, and ER-TERM flushes every termination point
        // predictably (ER-TERM MQ flush, alternating-bit raw padding).
        // Backend-specific limits (legacy MQ) are enforced by the public
        // codestream gates, not here.
        _ = self;
        return false;
    }
};

/// Legacy single-segment coders do not understand BYPASS payload layout or the
/// ISO ER-TERM flush, so they keep rejecting both; only the ISO-MQ segment
/// coders accept them.
fn validateImplementedStyle(style: CodeBlockStyle) !void {
    if (style.predictable_termination or style.bypass) return EbcotError.InvalidBlock;
}

fn validateImplementedStyleAllowBypass(style: CodeBlockStyle) !void {
    if (style.hasUnsupportedPayloadMode()) return EbcotError.InvalidBlock;
}

/// ISO/IEC 15444-1 D.6 (arithmetic coder bypass): significance and
/// refinement passes below the fourth most significant bitplane are raw.
pub fn passIsRaw(style: CodeBlockStyle, bitplanes: u8, bitplane: u8, kind: PassKind) bool {
    if (!style.bypass or kind == .cleanup) return false;
    return @as(u16, bitplane) + 4 < bitplanes;
}

/// Codeword segment termination points in BYPASS mode (without predictable
/// termination / termall): the cleanup pass of the fourth most significant
/// bitplane ends the initial MQ segment, afterwards every refinement pass
/// ends a raw segment and every cleanup pass ends an MQ segment.
fn passEndsBypassSegment(style: CodeBlockStyle, bitplanes: u8, bitplane: u8, kind: PassKind) bool {
    if (!style.bypass) return false;
    if (kind == .cleanup and @as(u16, bitplane) + 4 == bitplanes) return true;
    if (@as(u16, bitplane) + 4 < bitplanes) {
        return kind == .refinement or kind == .cleanup;
    }
    return false;
}

pub const EncodedBlockView = struct {
    bitplanes: u8,
    non_zero_count: u32,
    passes: []const Pass,
    symbols: []const Symbol,
};

pub const BlockScratch = struct {
    allocator: std.mem.Allocator,
    significant: std.ArrayList(bool) = .empty,
    visited: std.ArrayList(bool) = .empty,
    became_significant: std.ArrayList(bool) = .empty,
    refined: std.ArrayList(bool) = .empty,
    passes: std.ArrayList(Pass) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,

    pub fn init(allocator: std.mem.Allocator) BlockScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BlockScratch) void {
        self.significant.deinit(self.allocator);
        self.visited.deinit(self.allocator);
        self.became_significant.deinit(self.allocator);
        self.refined.deinit(self.allocator);
        self.passes.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.* = undefined;
    }

    fn reset(self: *BlockScratch) void {
        self.passes.clearRetainingCapacity();
        self.symbols.clearRetainingCapacity();
    }

    fn ensureBlockState(self: *BlockScratch, area: usize) !void {
        try self.significant.resize(self.allocator, area);
        try self.visited.resize(self.allocator, area);
        try self.became_significant.resize(self.allocator, area);
        try self.refined.resize(self.allocator, area);
    }
};

const FlagKind = enum {
    significant,
    visited,
    became_significant,
    refined,
};

const flag_significant: u8 = 1 << 0;
const flag_visited: u8 = 1 << 1;
const flag_became_significant: u8 = 1 << 2;
const flag_refined: u8 = 1 << 3;

const NeighborCounts = struct {
    horizontal: u4 = 0,
    vertical: u4 = 0,
    diagonal: u4 = 0,

    fn total(self: NeighborCounts) u4 {
        return self.horizontal + self.vertical + self.diagonal;
    }
};

const zero_context_lut = makeZeroContextLut();
const sign_context_lut = makeSignContextLut();

// ---------------------------------------------------------------------------
// Incremental neighborhood flag words (openjpeg-style): one u16 per sample in
// a (width + 2) x (height + 2) grid whose border absorbs edge updates. When a
// sample becomes significant it pushes its significance (and sign for the
// four direct neighbors) into the neighbors' words, so context selection in
// the hot T1 loops is a table lookup instead of a neighborhood recomputation.
// ---------------------------------------------------------------------------
const nbf_sig_n: u16 = 1 << 0;
const nbf_sig_s: u16 = 1 << 1;
const nbf_sig_e: u16 = 1 << 2;
const nbf_sig_w: u16 = 1 << 3;
const nbf_sig_ne: u16 = 1 << 4;
const nbf_sig_nw: u16 = 1 << 5;
const nbf_sig_se: u16 = 1 << 6;
const nbf_sig_sw: u16 = 1 << 7;
const nbf_sgn_n: u16 = 1 << 8;
const nbf_sgn_s: u16 = 1 << 9;
const nbf_sgn_e: u16 = 1 << 10;
const nbf_sgn_w: u16 = 1 << 11;
const nbf_sig_self: u16 = 1 << 12;
const nbf_visit: u16 = 1 << 13;
const nbf_refine: u16 = 1 << 14;
const nbf_sig8: u16 = 0x00ff;
const nbf_cleanup_run_blockers: u16 = nbf_sig8 | nbf_sig_self | nbf_visit;
/// Vertical causal mode hides the row below the current stripe: mask the
/// south / south-east / south-west significance and the south sign.
const nbf_causal_mask: u16 = ~(nbf_sig_s | nbf_sig_se | nbf_sig_sw | nbf_sgn_s);

inline fn nbfStride(width: usize) usize {
    return width + 2;
}

inline fn nbfIndex(stride: usize, x: usize, y: usize) usize {
    return (y + 1) * stride + (x + 1);
}

/// Push a newly significant sample's state into its neighbors' flag words.
fn nbfMarkSignificant(flags: []u16, stride: usize, x: usize, y: usize, negative: bool) void {
    const p = nbfIndex(stride, x, y);
    flags[p] |= nbf_sig_self;
    flags[p - stride] |= nbf_sig_s;
    flags[p + stride] |= nbf_sig_n;
    flags[p - 1] |= nbf_sig_e;
    flags[p + 1] |= nbf_sig_w;
    flags[p - stride - 1] |= nbf_sig_se;
    flags[p - stride + 1] |= nbf_sig_sw;
    flags[p + stride - 1] |= nbf_sig_ne;
    flags[p + stride + 1] |= nbf_sig_nw;
    if (negative) {
        flags[p - stride] |= nbf_sgn_s;
        flags[p + stride] |= nbf_sgn_n;
        flags[p - 1] |= nbf_sgn_e;
        flags[p + 1] |= nbf_sgn_w;
    }
}

fn nbfClearVisit(flags: []u16) void {
    const mask_vec: NbfClearVector = @splat(~nbf_visit);
    var index: usize = 0;
    while (index + nbf_clear_lanes <= flags.len) : (index += nbf_clear_lanes) {
        nbfClearVisitChunk(flags[index..][0..nbf_clear_lanes], mask_vec);
    }
    while (index < flags.len) : (index += 1) {
        flags[index] &= ~nbf_visit;
    }
}

fn nbfClearVisitChunk(values: *[nbf_clear_lanes]u16, mask: NbfClearVector) void {
    const chunk: NbfClearVector = values.*;
    values.* = chunk & mask;
}

fn nbfBit(pattern: usize, comptime mask: u16) u4 {
    return @intFromBool((pattern & mask) != 0);
}

/// Zero-coding contexts per band orientation indexed by the eight neighbor
/// significance bits; generated from the reference zeroContextFromCounts.
const nbf_zc_lut = makeNbfZcLut();

fn makeNbfZcLut() [4][256]Context {
    @setEvalBranchQuota(100000);
    var lut: [4][256]Context = undefined;
    for (0..4) |band| {
        const kind: subband.Kind = @enumFromInt(band);
        for (0..256) |pattern| {
            const counts = NeighborCounts{
                .horizontal = nbfBit(pattern, nbf_sig_e) + nbfBit(pattern, nbf_sig_w),
                .vertical = nbfBit(pattern, nbf_sig_n) + nbfBit(pattern, nbf_sig_s),
                .diagonal = nbfBit(pattern, nbf_sig_ne) + nbfBit(pattern, nbf_sig_nw) +
                    nbfBit(pattern, nbf_sig_se) + nbfBit(pattern, nbf_sig_sw),
            };
            lut[band][pattern] = zeroContextFromCounts(counts, kind);
        }
    }
    return lut;
}

/// Sign-coding context and prediction indexed by the four direct neighbors'
/// significance and sign bits; generated from signCodingFromContributions.
const nbf_sc_lut = makeNbfScLut();

fn makeNbfScLut() [256]SignCoding {
    @setEvalBranchQuota(100000);
    var lut: [256]SignCoding = undefined;
    for (0..256) |pattern| {
        const n: i8 = if ((pattern & 0x01) != 0) (if ((pattern & 0x10) != 0) -1 else 1) else 0;
        const s: i8 = if ((pattern & 0x02) != 0) (if ((pattern & 0x20) != 0) -1 else 1) else 0;
        const e: i8 = if ((pattern & 0x04) != 0) (if ((pattern & 0x40) != 0) -1 else 1) else 0;
        const w: i8 = if ((pattern & 0x08) != 0) (if ((pattern & 0x80) != 0) -1 else 1) else 0;
        lut[pattern] = signCodingFromContributions(e + w, n + s);
    }
    return lut;
}

/// Low nibble: significance of N, S, E, W; high nibble: their signs.
fn nbfScIndex(word: u16) u8 {
    return @intCast((word & 0x0f) | ((word >> 4) & 0xf0));
}

// Full packed T1 context-word scaffold: one OpenJPEG-style u32 per code-block
// column and four-row stripe. The active hot path still uses u16 neighborhood
// words; Debug and ReleaseSafe maintain this buffer as shadow state and assert
// parity at T1 loop boundaries.
const use_packed_t1_context_flags = build_options.packed_t1_context_flags;
const debug_check_packed_t1_context_flags = builtin.mode == .Debug or builtin.mode == .ReleaseSafe;
const maintain_packed_t1_context_flags = use_packed_t1_context_flags or debug_check_packed_t1_context_flags;

fn pcfStripeCount(height: usize) usize {
    return (height + 3) / 4;
}

fn pcfIndex(width: usize, x: usize, y: usize) usize {
    return (y / 4) * width + x;
}

fn directCanUseRunStripeFast(scratch: *const DirectBlockScratch, x: usize, stripe_y: usize, style: CodeBlockStyle) bool {
    const expected = nbfCanUseRunStripe(scratch.nb_flags.items, scratch.nb_stride, x, stripe_y, style);
    if (comptime use_packed_t1_context_flags) {
        return packedT1CanUseRunStripeChecked(
            scratch.packed_t1_flags.items,
            scratch.width,
            scratch.nb_flags.items,
            scratch.nb_stride,
            x,
            stripe_y,
            style,
        );
    }
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedT1CanUseRunStripeChecked(
            scratch.packed_t1_flags.items,
            scratch.width,
            scratch.nb_flags.items,
            scratch.nb_stride,
            x,
            stripe_y,
            style,
        );
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) std.debug.assert(expected == actual);
    }
    return expected;
}

fn decodeCanUseRunStripeFast(scratch: *const DecodeBlockScratch, x: usize, stripe_y: usize, style: CodeBlockStyle) bool {
    const expected = nbfCanUseRunStripe(scratch.nb_flags.items, scratch.nb_stride, x, stripe_y, style);
    if (comptime use_packed_t1_context_flags) {
        return packedT1CanUseRunStripeChecked(
            scratch.packed_t1_flags.items,
            scratch.width,
            scratch.nb_flags.items,
            scratch.nb_stride,
            x,
            stripe_y,
            style,
        );
    }
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedT1CanUseRunStripeChecked(
            scratch.packed_t1_flags.items,
            scratch.width,
            scratch.nb_flags.items,
            scratch.nb_stride,
            x,
            stripe_y,
            style,
        );
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) std.debug.assert(expected == actual);
    }
    return expected;
}

const packed_sigma_nw: u32 = 1 << 0;
const packed_sigma_n: u32 = 1 << 1;
const packed_sigma_ne: u32 = 1 << 2;
const packed_sigma_w: u32 = 1 << 3;
const packed_sigma_this: u32 = 1 << 4;
const packed_sigma_e: u32 = 1 << 5;
const packed_sigma_sw: u32 = 1 << 6;
const packed_sigma_s: u32 = 1 << 7;
const packed_sigma_se: u32 = 1 << 8;
const packed_sigma_neighbors: u32 = packed_sigma_nw | packed_sigma_n | packed_sigma_ne |
    packed_sigma_w | packed_sigma_e | packed_sigma_sw | packed_sigma_s | packed_sigma_se;
const packed_sigma_causal_neighbors: u32 = packed_sigma_neighbors & ~(packed_sigma_sw | packed_sigma_s | packed_sigma_se);
const packed_chi_0: u32 = 1 << 18;
const packed_chi_1: u32 = 1 << 19;
const packed_chi_2: u32 = 1 << 22;
const packed_chi_3: u32 = 1 << 25;
const packed_chi_4: u32 = 1 << 28;
const packed_chi_5: u32 = 1 << 31;
const packed_chi_bits = [_]u32{
    packed_chi_0,
    packed_chi_1,
    packed_chi_2,
    packed_chi_3,
    packed_chi_4,
    packed_chi_5,
};
const packed_mu_0: u32 = 1 << 20;
const packed_pi_0: u32 = 1 << 21;
const packed_mu_bits = [_]u32{
    packed_mu_0,
    1 << 23,
    1 << 26,
    1 << 29,
};
const packed_pi_bits = [_]u32{
    packed_pi_0,
    1 << 24,
    1 << 27,
    1 << 30,
};
const packed_pi_mask: u32 = packed_pi_bits[0] | packed_pi_bits[1] | packed_pi_bits[2] | packed_pi_bits[3];

fn packedSigmaWindowFromNbf(word: u16) u32 {
    var out: u32 = 0;
    if ((word & nbf_sig_nw) != 0) out |= packed_sigma_nw;
    if ((word & nbf_sig_n) != 0) out |= packed_sigma_n;
    if ((word & nbf_sig_ne) != 0) out |= packed_sigma_ne;
    if ((word & nbf_sig_w) != 0) out |= packed_sigma_w;
    if ((word & nbf_sig_self) != 0) out |= packed_sigma_this;
    if ((word & nbf_sig_e) != 0) out |= packed_sigma_e;
    if ((word & nbf_sig_sw) != 0) out |= packed_sigma_sw;
    if ((word & nbf_sig_s) != 0) out |= packed_sigma_s;
    if ((word & nbf_sig_se) != 0) out |= packed_sigma_se;
    return out;
}

fn packedSigmaColumnFromNbf(nb_flags: []const u16, nb_stride: usize, x: usize, stripe_y: usize, height: usize) u32 {
    const stripe_height = @min(@as(usize, 4), height - stripe_y);
    var word: u32 = 0;
    var ci: usize = 0;
    while (ci < stripe_height) : (ci += 1) {
        const y = stripe_y + ci;
        word |= packedSigmaWindowFromNbf(nb_flags[nbfIndex(nb_stride, x, y)]) << @as(u5, @intCast(3 * ci));
    }
    return word;
}

fn packedSigmaNbfPattern(word: u32, ci: usize) u16 {
    const window = (word >> @as(u5, @intCast(3 * ci))) & packed_sigma_neighbors;
    return packedSigmaWindowToNbfPattern(window);
}

fn packedSigmaNbfPatternCausal(word: u32, ci: usize, causal_row: bool) u16 {
    const shifted = word >> @as(u5, @intCast(3 * ci));
    const window = shifted & if (causal_row) packed_sigma_causal_neighbors else packed_sigma_neighbors;
    return packedSigmaWindowToNbfPattern(window);
}

fn packedSigmaWindowToNbfPattern(window: u32) u16 {
    var out: u16 = 0;
    if ((window & packed_sigma_nw) != 0) out |= nbf_sig_nw;
    if ((window & packed_sigma_n) != 0) out |= nbf_sig_n;
    if ((window & packed_sigma_ne) != 0) out |= nbf_sig_ne;
    if ((window & packed_sigma_w) != 0) out |= nbf_sig_w;
    if ((window & packed_sigma_e) != 0) out |= nbf_sig_e;
    if ((window & packed_sigma_sw) != 0) out |= nbf_sig_sw;
    if ((window & packed_sigma_s) != 0) out |= nbf_sig_s;
    if ((window & packed_sigma_se) != 0) out |= nbf_sig_se;
    return out;
}

fn nbfSelfNegative(nb_flags: []const u16, nb_stride: usize, width: usize, height: usize, x: usize, y: usize) bool {
    if (x > 0 and (nb_flags[nbfIndex(nb_stride, x - 1, y)] & nbf_sgn_e) != 0) return true;
    if (x + 1 < width and (nb_flags[nbfIndex(nb_stride, x + 1, y)] & nbf_sgn_w) != 0) return true;
    if (y > 0 and (nb_flags[nbfIndex(nb_stride, x, y - 1)] & nbf_sgn_s) != 0) return true;
    if (y + 1 < height and (nb_flags[nbfIndex(nb_stride, x, y + 1)] & nbf_sgn_n) != 0) return true;
    return false;
}

fn packedChiColumnFromNbf(nb_flags: []const u16, nb_stride: usize, width: usize, height: usize, x: usize, stripe_y: usize) u32 {
    var word: u32 = 0;
    var row: usize = 0;
    while (row < packed_chi_bits.len) : (row += 1) {
        if (stripe_y + row == 0) continue;
        const y = stripe_y + row - 1;
        if (y >= height) continue;
        if (nbfSelfNegative(nb_flags, nb_stride, width, height, x, y)) {
            word |= packed_chi_bits[row];
        }
    }
    return word;
}

fn packedMuPiColumnFromNbf(nb_flags: []const u16, nb_stride: usize, x: usize, stripe_y: usize, height: usize) u32 {
    const stripe_height = @min(@as(usize, 4), height - stripe_y);
    var word: u32 = 0;
    var ci: usize = 0;
    while (ci < stripe_height) : (ci += 1) {
        const sample = nb_flags[nbfIndex(nb_stride, x, stripe_y + ci)];
        if ((sample & nbf_refine) != 0) word |= packed_mu_bits[ci];
        if ((sample & nbf_visit) != 0) word |= packed_pi_bits[ci];
    }
    return word;
}

fn packedColumnFromNbf(nb_flags: []const u16, nb_stride: usize, width: usize, height: usize, x: usize, stripe_y: usize) u32 {
    return packedSigmaColumnFromNbf(nb_flags, nb_stride, x, stripe_y, height) |
        packedChiColumnFromNbf(nb_flags, nb_stride, width, height, x, stripe_y) |
        packedMuPiColumnFromNbf(nb_flags, nb_stride, x, stripe_y, height);
}

fn packedT1RebuildFromNbf(out: []u32, nb_flags: []const u16, nb_stride: usize, width: usize, height: usize) void {
    var stripe_y: usize = 0;
    while (stripe_y < height) : (stripe_y += 4) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            out[pcfIndex(width, x, stripe_y)] = packedColumnFromNbf(nb_flags, nb_stride, width, height, x, stripe_y);
        }
    }
}

fn packedSigmaBitForSource(target_x: usize, target_y: usize, source_x: usize, source_y: usize) u32 {
    if (source_y < target_y) {
        if (source_x < target_x) return packed_sigma_nw;
        if (source_x == target_x) return packed_sigma_n;
        return packed_sigma_ne;
    }
    if (source_y == target_y) {
        if (source_x < target_x) return packed_sigma_w;
        if (source_x == target_x) return packed_sigma_this;
        return packed_sigma_e;
    }
    if (source_x < target_x) return packed_sigma_sw;
    if (source_x == target_x) return packed_sigma_s;
    return packed_sigma_se;
}

fn packedT1SetSigma(flags: []u32, width: usize, target_x: usize, target_y: usize, sigma_bit: u32) void {
    const shift: u5 = @intCast(3 * (target_y & 3));
    flags[pcfIndex(width, target_x, target_y)] |= sigma_bit << shift;
}

fn packedT1SetChiInStripe(flags: []u32, width: usize, x: usize, y: usize, stripe_y: usize) void {
    const row = if (stripe_y > y) 0 else y - stripe_y + 1;
    std.debug.assert(row < packed_chi_bits.len);
    flags[pcfIndex(width, x, stripe_y)] |= packed_chi_bits[row];
}

fn packedT1SetChiForSample(flags: []u32, width: usize, height: usize, x: usize, y: usize) void {
    const base_stripe_y = y & ~@as(usize, 3);
    packedT1SetChiInStripe(flags, width, x, y, base_stripe_y);
    if ((y & 3) == 0 and base_stripe_y >= 4) {
        packedT1SetChiInStripe(flags, width, x, y, base_stripe_y - 4);
    }
    if ((y & 3) == 3 and base_stripe_y + 4 < height) {
        packedT1SetChiInStripe(flags, width, x, y, base_stripe_y + 4);
    }
}

fn packedT1MarkSignificant(flags: []u32, width: usize, height: usize, x: usize, y: usize, negative: bool) void {
    const min_y = if (y == 0) 0 else y - 1;
    const max_y = @min(height - 1, y + 1);
    const min_x = if (x == 0) 0 else x - 1;
    const max_x = @min(width - 1, x + 1);

    var yy = min_y;
    while (yy <= max_y) : (yy += 1) {
        var xx = min_x;
        while (xx <= max_x) : (xx += 1) {
            packedT1SetSigma(flags, width, xx, yy, packedSigmaBitForSource(xx, yy, x, y));
        }
    }

    if (!negative) return;
    if (x > 0 or x + 1 < width or y > 0 or y + 1 < height) {
        packedT1SetChiForSample(flags, width, height, x, y);
    }
}

fn packedT1MarkVisited(flags: []u32, width: usize, x: usize, y: usize) void {
    flags[pcfIndex(width, x, y)] |= packed_pi_bits[y & 3];
}

fn packedT1MarkRefined(flags: []u32, width: usize, x: usize, y: usize) void {
    flags[pcfIndex(width, x, y)] |= packed_mu_bits[y & 3];
}

fn packedT1ClearVisited(flags: []u32) void {
    for (flags) |*word| {
        word.* &= ~packed_pi_mask;
    }
}

fn directClearNbfVisit(scratch: *DirectBlockScratch) void {
    nbfClearVisit(scratch.nb_flags.items);
    if (comptime maintain_packed_t1_context_flags) packedT1ClearVisited(scratch.packed_t1_flags.items);
}

fn decodeClearNbfVisit(scratch: *DecodeBlockScratch) void {
    nbfClearVisit(scratch.nb_flags.items);
    if (comptime maintain_packed_t1_context_flags) packedT1ClearVisited(scratch.packed_t1_flags.items);
}

fn directMarkPackedT1Visited(scratch: *DirectBlockScratch, x: usize, y: usize) void {
    if (comptime maintain_packed_t1_context_flags) packedT1MarkVisited(scratch.packed_t1_flags.items, scratch.width, x, y);
}

fn decodeMarkPackedT1Visited(scratch: *DecodeBlockScratch, x: usize, y: usize) void {
    if (comptime maintain_packed_t1_context_flags) packedT1MarkVisited(scratch.packed_t1_flags.items, scratch.width, x, y);
}

fn directMarkPackedT1Refined(scratch: *DirectBlockScratch, x: usize, y: usize) void {
    if (comptime maintain_packed_t1_context_flags) packedT1MarkRefined(scratch.packed_t1_flags.items, scratch.width, x, y);
}

fn decodeMarkPackedT1Refined(scratch: *DecodeBlockScratch, x: usize, y: usize) void {
    if (comptime maintain_packed_t1_context_flags) packedT1MarkRefined(scratch.packed_t1_flags.items, scratch.width, x, y);
}

fn directMarkPackedT1Significant(scratch: *DirectBlockScratch, x: usize, y: usize, negative: bool) void {
    if (comptime maintain_packed_t1_context_flags) packedT1MarkSignificant(scratch.packed_t1_flags.items, scratch.width, scratch.height, x, y, negative);
}

fn decodeMarkPackedT1Significant(scratch: *DecodeBlockScratch, x: usize, y: usize, negative: bool) void {
    if (comptime maintain_packed_t1_context_flags) packedT1MarkSignificant(scratch.packed_t1_flags.items, scratch.width, scratch.height, x, y, negative);
}

fn packedScOpenJpegIndex(fx: u32, prev_fx: u32, next_fx: u32, ci: usize) u8 {
    const shift: u5 = @intCast(3 * ci);
    var lu: u32 = (fx >> shift) & (packed_sigma_n | packed_sigma_w | packed_sigma_e | packed_sigma_s);
    lu |= (prev_fx >> @as(u5, @intCast(19 + 3 * ci))) & (1 << 0);
    lu |= (next_fx >> @as(u5, @intCast(17 + 3 * ci))) & (1 << 2);
    if (ci == 0) {
        lu |= (fx >> 14) & (1 << 4);
    } else {
        lu |= (fx >> @as(u5, @intCast(15 + 3 * (ci - 1)))) & (1 << 4);
    }
    lu |= (fx >> @as(u5, @intCast(16 + 3 * ci))) & (1 << 6);
    return @intCast(lu);
}

fn packedScNbfIndex(fx: u32, prev_fx: u32, next_fx: u32, ci: usize) u8 {
    const lu = packedScOpenJpegIndex(fx, prev_fx, next_fx, ci);
    var out: u8 = 0;
    if ((lu & (1 << 1)) != 0) out |= 1 << 0; // significant north
    if ((lu & (1 << 7)) != 0) out |= 1 << 1; // significant south
    if ((lu & (1 << 5)) != 0) out |= 1 << 2; // significant east
    if ((lu & (1 << 3)) != 0) out |= 1 << 3; // significant west
    if ((lu & (1 << 4)) != 0) out |= 1 << 4; // negative north
    if ((lu & (1 << 6)) != 0) out |= 1 << 5; // negative south
    if ((lu & (1 << 2)) != 0) out |= 1 << 6; // negative east
    if ((lu & (1 << 0)) != 0) out |= 1 << 7; // negative west
    return out;
}

fn packedScNbfIndexCausal(fx: u32, prev_fx: u32, next_fx: u32, ci: usize, causal_row: bool) u8 {
    var index = packedScNbfIndex(fx, prev_fx, next_fx, ci);
    if (causal_row) {
        index &= ~@as(u8, (1 << 1) | (1 << 5));
    }
    return index;
}

fn packedZeroContext(word: u32, ci: usize, band_kind: subband.Kind, causal_row: bool) Context {
    return nbf_zc_lut[@intFromEnum(band_kind)][packedSigmaNbfPatternCausal(word, ci, causal_row)];
}

fn packedSignCoding(fx: u32, prev_fx: u32, next_fx: u32, ci: usize, causal_row: bool) SignCoding {
    return nbf_sc_lut[packedScNbfIndexCausal(fx, prev_fx, next_fx, ci, causal_row)];
}

const PackedT1Decision = struct {
    zero_context: Context,
    sign: SignCoding,
    significance_candidate: bool,
    refinement_candidate: bool,
    refinement_context: Context,
};

const T1RefinementDecision = struct {
    candidate: bool,
    context: Context,
};

const T1SignificanceDecision = struct {
    candidate: bool,
    zero_context: Context,
};

fn packedT1DecisionFromColumns(
    flags: []const u32,
    width: usize,
    x: usize,
    stripe_y: usize,
    ci: usize,
    style: CodeBlockStyle,
) PackedT1Decision {
    const fx = flags[pcfIndex(width, x, stripe_y)];
    const prev_fx = if (x == 0) 0 else flags[pcfIndex(width, x - 1, stripe_y)];
    const next_fx = if (x + 1 == width) 0 else flags[pcfIndex(width, x + 1, stripe_y)];
    const causal_row = style.vertical_causal and ci == 3;
    return .{
        .zero_context = packedZeroContext(fx, ci, style.band_kind, causal_row),
        .sign = packedSignCoding(fx, prev_fx, next_fx, ci, causal_row),
        .significance_candidate = packedSignificanceCandidateCausal(fx, ci, causal_row),
        .refinement_candidate = packedRefinementCandidate(fx, ci),
        .refinement_context = packedRefinementContextCausal(fx, ci, causal_row),
    };
}

fn packedT1SignificanceDecisionFromColumns(flags: []const u32, width: usize, x: usize, y: usize, style: CodeBlockStyle) T1SignificanceDecision {
    const ci = y & 3;
    const word = flags[pcfIndex(width, x, y)];
    const causal_row = style.vertical_causal and ci == 3;
    return .{
        .candidate = packedSignificanceCandidateCausal(word, ci, causal_row),
        .zero_context = packedZeroContext(word, ci, style.band_kind, causal_row),
    };
}

fn packedT1RefinementDecisionFromColumns(flags: []const u32, width: usize, x: usize, y: usize, style: CodeBlockStyle) T1RefinementDecision {
    const ci = y & 3;
    const word = flags[pcfIndex(width, x, y)];
    const causal_row = style.vertical_causal and ci == 3;
    return .{
        .candidate = packedRefinementCandidate(word, ci),
        .context = packedRefinementContextCausal(word, ci, causal_row),
    };
}

fn nbfT1DecisionFromWord(word: u16, style: CodeBlockStyle, causal_row: bool) PackedT1Decision {
    const f = if (causal_row) word & nbf_causal_mask else word;
    const pattern = f & nbf_sig8;
    return .{
        .zero_context = nbf_zc_lut[@intFromEnum(style.band_kind)][pattern],
        .sign = nbf_sc_lut[nbfScIndex(f)],
        .significance_candidate = (f & nbf_sig_self) == 0 and (f & nbf_visit) == 0 and pattern != 0,
        .refinement_candidate = (f & nbf_sig_self) != 0 and (f & nbf_visit) == 0,
        .refinement_context = refinementContext((f & nbf_refine) != 0, @intCast(@popCount(pattern))),
    };
}

fn nbfT1SignificanceDecisionFromWord(word: u16, style: CodeBlockStyle, causal_row: bool) T1SignificanceDecision {
    const f = if (causal_row) word & nbf_causal_mask else word;
    const pattern = f & nbf_sig8;
    return .{
        .candidate = (f & nbf_sig_self) == 0 and (f & nbf_visit) == 0 and pattern != 0,
        .zero_context = nbf_zc_lut[@intFromEnum(style.band_kind)][pattern],
    };
}

inline fn nbfT1ZeroContextFromWord(word: u16, style: CodeBlockStyle, causal_row: bool) Context {
    const f = if (causal_row) word & nbf_causal_mask else word;
    return nbf_zc_lut[@intFromEnum(style.band_kind)][f & nbf_sig8];
}

inline fn nbfT1SignificanceCandidateFromWord(word: u16, causal_row: bool) bool {
    const f = if (causal_row) word & nbf_causal_mask else word;
    return (f & nbf_sig_self) == 0 and (f & nbf_visit) == 0 and (f & nbf_sig8) != 0;
}

fn nbfT1RefinementDecisionFromWord(word: u16, causal_row: bool) T1RefinementDecision {
    const f = if (causal_row) word & nbf_causal_mask else word;
    return .{
        .candidate = (f & nbf_sig_self) != 0 and (f & nbf_visit) == 0,
        .context = refinementContext((f & nbf_refine) != 0, @intCast(@popCount(f & nbf_sig8))),
    };
}

fn packedT1DecisionEquals(a: PackedT1Decision, b: PackedT1Decision) bool {
    return a.zero_context == b.zero_context and
        std.meta.eql(a.sign, b.sign) and
        a.significance_candidate == b.significance_candidate and
        a.refinement_candidate == b.refinement_candidate and
        a.refinement_context == b.refinement_context;
}

fn directT1Decision(scratch: *const DirectBlockScratch, x: usize, y: usize, style: CodeBlockStyle) PackedT1Decision {
    const ci = y & 3;
    const stripe_y = y & ~@as(usize, 3);
    const causal_row = style.vertical_causal and ci == 3;
    const expected = nbfT1DecisionFromWord(scratch.nb_flags.items[nbfIndex(scratch.nb_stride, x, y)], style, causal_row);
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedT1DecisionFromColumns(scratch.packed_t1_flags.items, scratch.width, x, stripe_y, ci, style);
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(packedT1DecisionEquals(expected, actual));
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

inline fn directT1SignificanceCandidate(scratch: *const DirectBlockScratch, x: usize, y: usize, sample_flags: u16, style: CodeBlockStyle) bool {
    const ci = y & 3;
    const causal_row = style.vertical_causal and ci == 3;
    const expected = nbfT1SignificanceCandidateFromWord(sample_flags, causal_row);
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedSignificanceCandidateCausal(scratch.packed_t1_flags.items[pcfIndex(scratch.width, x, y)], ci, causal_row);
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(expected == actual);
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

inline fn directT1SignificanceDecision(scratch: *const DirectBlockScratch, x: usize, y: usize, sample_flags: u16, style: CodeBlockStyle) T1SignificanceDecision {
    const ci = y & 3;
    const causal_row = style.vertical_causal and ci == 3;
    const expected = nbfT1SignificanceDecisionFromWord(sample_flags, style, causal_row);
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedT1SignificanceDecisionFromColumns(scratch.packed_t1_flags.items, scratch.width, x, y, style);
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(expected.candidate == actual.candidate);
            std.debug.assert(expected.zero_context == actual.zero_context);
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

inline fn directT1ZeroContext(scratch: *const DirectBlockScratch, x: usize, y: usize, sample_flags: u16, style: CodeBlockStyle) Context {
    const ci = y & 3;
    const causal_row = style.vertical_causal and ci == 3;
    const expected = nbfT1ZeroContextFromWord(sample_flags, style, causal_row);
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedZeroContext(
            scratch.packed_t1_flags.items[pcfIndex(scratch.width, x, y)],
            ci,
            style.band_kind,
            causal_row,
        );
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(expected == actual);
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

inline fn directT1SignCoding(scratch: *const DirectBlockScratch, x: usize, y: usize, sample_flags: u16, style: CodeBlockStyle) SignCoding {
    const ci = y & 3;
    const causal_row = style.vertical_causal and ci == 3;
    const f = if (causal_row) sample_flags & nbf_causal_mask else sample_flags;
    const expected = nbf_sc_lut[nbfScIndex(f)];
    if (comptime maintain_packed_t1_context_flags) {
        const actual = blk: {
            const fx = scratch.packed_t1_flags.items[pcfIndex(scratch.width, x, y)];
            const prev_fx = if (x == 0) 0 else scratch.packed_t1_flags.items[pcfIndex(scratch.width, x - 1, y)];
            const next_fx = if (x + 1 == scratch.width) 0 else scratch.packed_t1_flags.items[pcfIndex(scratch.width, x + 1, y)];
            break :blk packedSignCoding(fx, prev_fx, next_fx, ci, causal_row);
        };
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(std.meta.eql(expected, actual));
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

inline fn directT1RefinementDecision(scratch: *const DirectBlockScratch, x: usize, y: usize, sample_flags: u16, style: CodeBlockStyle) T1RefinementDecision {
    const ci = y & 3;
    const causal_row = style.vertical_causal and ci == 3;
    const expected = nbfT1RefinementDecisionFromWord(sample_flags, causal_row);
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedT1RefinementDecisionFromColumns(scratch.packed_t1_flags.items, scratch.width, x, y, style);
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(expected.candidate == actual.candidate);
            std.debug.assert(expected.context == actual.context);
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

fn decodeT1Decision(scratch: *const DecodeBlockScratch, x: usize, y: usize, style: CodeBlockStyle) PackedT1Decision {
    const ci = y & 3;
    const stripe_y = y & ~@as(usize, 3);
    const causal_row = style.vertical_causal and ci == 3;
    const expected = nbfT1DecisionFromWord(scratch.nb_flags.items[nbfIndex(scratch.nb_stride, x, y)], style, causal_row);
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedT1DecisionFromColumns(scratch.packed_t1_flags.items, scratch.width, x, stripe_y, ci, style);
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(packedT1DecisionEquals(expected, actual));
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

inline fn decodeT1SignificanceCandidate(scratch: *const DecodeBlockScratch, x: usize, y: usize, sample_flags: u16, style: CodeBlockStyle) bool {
    const ci = y & 3;
    const causal_row = style.vertical_causal and ci == 3;
    const expected = nbfT1SignificanceCandidateFromWord(sample_flags, causal_row);
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedSignificanceCandidateCausal(scratch.packed_t1_flags.items[pcfIndex(scratch.width, x, y)], ci, causal_row);
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(expected == actual);
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

inline fn decodeT1SignificanceDecision(scratch: *const DecodeBlockScratch, x: usize, y: usize, sample_flags: u16, style: CodeBlockStyle) T1SignificanceDecision {
    const ci = y & 3;
    const causal_row = style.vertical_causal and ci == 3;
    const expected = nbfT1SignificanceDecisionFromWord(sample_flags, style, causal_row);
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedT1SignificanceDecisionFromColumns(scratch.packed_t1_flags.items, scratch.width, x, y, style);
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(expected.candidate == actual.candidate);
            std.debug.assert(expected.zero_context == actual.zero_context);
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

inline fn decodeT1ZeroContext(scratch: *const DecodeBlockScratch, x: usize, y: usize, sample_flags: u16, style: CodeBlockStyle) Context {
    const ci = y & 3;
    const causal_row = style.vertical_causal and ci == 3;
    const expected = nbfT1ZeroContextFromWord(sample_flags, style, causal_row);
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedZeroContext(
            scratch.packed_t1_flags.items[pcfIndex(scratch.width, x, y)],
            ci,
            style.band_kind,
            causal_row,
        );
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(expected == actual);
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

inline fn decodeT1SignCoding(scratch: *const DecodeBlockScratch, x: usize, y: usize, sample_flags: u16, style: CodeBlockStyle) SignCoding {
    const ci = y & 3;
    const causal_row = style.vertical_causal and ci == 3;
    const f = if (causal_row) sample_flags & nbf_causal_mask else sample_flags;
    const expected = nbf_sc_lut[nbfScIndex(f)];
    if (comptime maintain_packed_t1_context_flags) {
        const actual = blk: {
            const fx = scratch.packed_t1_flags.items[pcfIndex(scratch.width, x, y)];
            const prev_fx = if (x == 0) 0 else scratch.packed_t1_flags.items[pcfIndex(scratch.width, x - 1, y)];
            const next_fx = if (x + 1 == scratch.width) 0 else scratch.packed_t1_flags.items[pcfIndex(scratch.width, x + 1, y)];
            break :blk packedSignCoding(fx, prev_fx, next_fx, ci, causal_row);
        };
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(std.meta.eql(expected, actual));
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

inline fn decodeT1RefinementDecision(scratch: *const DecodeBlockScratch, x: usize, y: usize, sample_flags: u16, style: CodeBlockStyle) T1RefinementDecision {
    const ci = y & 3;
    const causal_row = style.vertical_causal and ci == 3;
    const expected = nbfT1RefinementDecisionFromWord(sample_flags, causal_row);
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedT1RefinementDecisionFromColumns(scratch.packed_t1_flags.items, scratch.width, x, y, style);
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(expected.candidate == actual.candidate);
            std.debug.assert(expected.context == actual.context);
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

inline fn decodeT1RefinementCandidate(scratch: *const DecodeBlockScratch, x: usize, y: usize, sample_flags: u16) bool {
    const expected = (sample_flags & nbf_sig_self) != 0 and (sample_flags & nbf_visit) == 0;
    if (comptime maintain_packed_t1_context_flags) {
        const actual = packedRefinementCandidate(scratch.packed_t1_flags.items[pcfIndex(scratch.width, x, y)], y & 3);
        if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
            std.debug.assert(expected == actual);
        }
        if (comptime use_packed_t1_context_flags) return actual;
    }
    return expected;
}

fn expectPackedT1DecisionMatchesNbf(
    packed_flags: []const u32,
    nb_flags: []const u16,
    nb_stride: usize,
    width: usize,
    x: usize,
    y: usize,
    style: CodeBlockStyle,
) !void {
    const ci = y & 3;
    const causal_row = style.vertical_causal and ci == 3;
    const expected = nbfT1DecisionFromWord(nb_flags[nbfIndex(nb_stride, x, y)], style, causal_row);
    const actual = packedT1DecisionFromColumns(packed_flags, width, x, y & ~@as(usize, 3), ci, style);
    try std.testing.expectEqual(expected.zero_context, actual.zero_context);
    try std.testing.expectEqual(expected.sign, actual.sign);
    try std.testing.expectEqual(expected.significance_candidate, actual.significance_candidate);
    try std.testing.expectEqual(expected.refinement_candidate, actual.refinement_candidate);
    try std.testing.expectEqual(expected.refinement_context, actual.refinement_context);
}

fn packedT1CanUseRunStripe(flags: []const u32, width: usize, x: usize, stripe_y: usize, style: CodeBlockStyle) bool {
    const word = flags[pcfIndex(width, x, stripe_y)];
    var ci: usize = 0;
    while (ci < 4) : (ci += 1) {
        const shifted = word >> @as(u5, @intCast(3 * ci));
        const neighbors = shifted & if (style.vertical_causal and ci == 3)
            packed_sigma_causal_neighbors
        else
            packed_sigma_neighbors;
        if ((shifted & (packed_sigma_this | packed_pi_0)) != 0 or neighbors != 0) return false;
    }
    return true;
}

fn packedT1CanUseRunStripeChecked(
    packed_flags: []const u32,
    width: usize,
    nb_flags: []const u16,
    nb_stride: usize,
    x: usize,
    stripe_y: usize,
    style: CodeBlockStyle,
) bool {
    const packed_clean = packedT1CanUseRunStripe(packed_flags, width, x, stripe_y, style);
    if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        std.debug.assert(packed_clean == nbfCanUseRunStripe(nb_flags, nb_stride, x, stripe_y, style));
    }
    return packed_clean;
}

fn packedSignificanceCandidate(word: u32, ci: usize) bool {
    return packedSignificanceCandidateCausal(word, ci, false);
}

fn packedSignificanceCandidateCausal(word: u32, ci: usize, causal_row: bool) bool {
    const shifted = word >> @as(u5, @intCast(3 * ci));
    const neighbors = shifted & if (causal_row) packed_sigma_causal_neighbors else packed_sigma_neighbors;
    return (shifted & (packed_sigma_this | packed_pi_0)) == 0 and
        neighbors != 0;
}

fn packedRefinementCandidate(word: u32, ci: usize) bool {
    const shifted = word >> @as(u5, @intCast(3 * ci));
    return (shifted & (packed_sigma_this | packed_pi_0)) == packed_sigma_this;
}

fn packedRefinementContext(word: u32, ci: usize) Context {
    return packedRefinementContextCausal(word, ci, false);
}

fn packedRefinementContextCausal(word: u32, ci: usize, causal_row: bool) Context {
    const shifted = word >> @as(u5, @intCast(3 * ci));
    if ((shifted & packed_mu_0) != 0) return .refinement_later;
    const neighbors = shifted & if (causal_row) packed_sigma_causal_neighbors else packed_sigma_neighbors;
    return if (neighbors != 0) .refinement_neighbor else .refinement;
}

test "EBCOT OpenJPEG-style packed sigma windows match zero-coding contexts" {
    const allocator = std.testing.allocator;
    const width = 6;
    const height = 8;
    const nb_stride = nbfStride(width);
    const nb_flags = try allocator.alloc(u16, nb_stride * (height + 2));
    defer allocator.free(nb_flags);
    @memset(nb_flags, 0);

    nbfMarkSignificant(nb_flags, nb_stride, 1, 1, false);
    nbfMarkSignificant(nb_flags, nb_stride, 3, 2, true);
    nbfMarkSignificant(nb_flags, nb_stride, 4, 6, false);

    var stripe_y: usize = 0;
    while (stripe_y < height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), height - stripe_y);
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const packed_word = packedSigmaColumnFromNbf(nb_flags, nb_stride, x, stripe_y, height);
            var ci: usize = 0;
            while (ci < stripe_height) : (ci += 1) {
                const y = stripe_y + ci;
                const nbf_pattern = nb_flags[nbfIndex(nb_stride, x, y)] & nbf_sig8;
                const packed_pattern = packedSigmaNbfPattern(packed_word, ci);
                try std.testing.expectEqual(nbf_pattern, packed_pattern);
                for (0..4) |band| {
                    try std.testing.expectEqual(nbf_zc_lut[band][nbf_pattern], nbf_zc_lut[band][packed_pattern]);
                }
            }
        }
    }
}

test "EBCOT OpenJPEG-style packed sign windows match sign-coding contexts" {
    const allocator = std.testing.allocator;
    const width = 7;
    const height = 8;
    const nb_stride = nbfStride(width);
    const nb_flags = try allocator.alloc(u16, nb_stride * (height + 2));
    defer allocator.free(nb_flags);
    @memset(nb_flags, 0);

    nbfMarkSignificant(nb_flags, nb_stride, 1, 1, false);
    nbfMarkSignificant(nb_flags, nb_stride, 3, 2, true);
    nbfMarkSignificant(nb_flags, nb_stride, 4, 3, false);
    nbfMarkSignificant(nb_flags, nb_stride, 5, 6, true);

    var stripe_y: usize = 0;
    while (stripe_y < height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), height - stripe_y);
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const fx = packedColumnFromNbf(nb_flags, nb_stride, width, height, x, stripe_y);
            const prev_fx = if (x == 0) 0 else packedColumnFromNbf(nb_flags, nb_stride, width, height, x - 1, stripe_y);
            const next_fx = if (x + 1 == width) 0 else packedColumnFromNbf(nb_flags, nb_stride, width, height, x + 1, stripe_y);
            var ci: usize = 0;
            while (ci < stripe_height) : (ci += 1) {
                const y = stripe_y + ci;
                const nbf_index = nbfScIndex(nb_flags[nbfIndex(nb_stride, x, y)]);
                const packed_index = packedScNbfIndex(fx, prev_fx, next_fx, ci);
                try std.testing.expectEqual(nbf_index, packed_index);
                try std.testing.expectEqual(nbf_sc_lut[nbf_index], nbf_sc_lut[packed_index]);
            }
        }
    }
}

test "EBCOT OpenJPEG-style packed PI MU bits match pass membership" {
    const allocator = std.testing.allocator;
    const width = 7;
    const height = 8;
    const nb_stride = nbfStride(width);
    const nb_flags = try allocator.alloc(u16, nb_stride * (height + 2));
    defer allocator.free(nb_flags);
    @memset(nb_flags, 0);

    nbfMarkSignificant(nb_flags, nb_stride, 1, 1, false);
    nbfMarkSignificant(nb_flags, nb_stride, 3, 2, true);
    nbfMarkSignificant(nb_flags, nb_stride, 4, 3, false);
    nbfMarkSignificant(nb_flags, nb_stride, 5, 6, true);
    nb_flags[nbfIndex(nb_stride, 2, 1)] |= nbf_visit;
    nb_flags[nbfIndex(nb_stride, 3, 2)] |= nbf_refine;
    nb_flags[nbfIndex(nb_stride, 5, 6)] |= nbf_refine | nbf_visit;

    var stripe_y: usize = 0;
    while (stripe_y < height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), height - stripe_y);
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const packed_word = packedColumnFromNbf(nb_flags, nb_stride, width, height, x, stripe_y);
            var ci: usize = 0;
            while (ci < stripe_height) : (ci += 1) {
                const y = stripe_y + ci;
                const sample = nb_flags[nbfIndex(nb_stride, x, y)];
                const sig_candidate = (sample & nbf_sig_self) == 0 and
                    (sample & nbf_visit) == 0 and
                    (sample & nbf_sig8) != 0;
                const ref_candidate = (sample & nbf_sig_self) != 0 and
                    (sample & nbf_visit) == 0;
                try std.testing.expectEqual(sig_candidate, packedSignificanceCandidate(packed_word, ci));
                try std.testing.expectEqual(ref_candidate, packedRefinementCandidate(packed_word, ci));
                try std.testing.expectEqual(
                    refinementContext((sample & nbf_refine) != 0, @intCast(@popCount(sample & nbf_sig8))),
                    packedRefinementContext(packed_word, ci),
                );
            }
        }
    }
}

test "EBCOT OpenJPEG-style packed incremental updates match rebuild" {
    const allocator = std.testing.allocator;
    const width = 7;
    const height = 9;
    const nb_stride = nbfStride(width);
    const nb_flags = try allocator.alloc(u16, nb_stride * (height + 2));
    defer allocator.free(nb_flags);
    @memset(nb_flags, 0);

    const packed_flags = try allocator.alloc(u32, width * pcfStripeCount(height));
    defer allocator.free(packed_flags);
    @memset(packed_flags, 0);

    const rebuilt_flags = try allocator.alloc(u32, width * pcfStripeCount(height));
    defer allocator.free(rebuilt_flags);

    const SigOp = struct {
        x: usize,
        y: usize,
        negative: bool,
    };
    const sig_ops = [_]SigOp{
        .{ .x = 0, .y = 0, .negative = false },
        .{ .x = 2, .y = 3, .negative = true },
        .{ .x = 4, .y = 4, .negative = true },
        .{ .x = 6, .y = 8, .negative = true },
        .{ .x = 3, .y = 6, .negative = false },
    };

    for (sig_ops) |op| {
        nbfMarkSignificant(nb_flags, nb_stride, op.x, op.y, op.negative);
        packedT1MarkSignificant(packed_flags, width, height, op.x, op.y, op.negative);
        packedT1RebuildFromNbf(rebuilt_flags, nb_flags, nb_stride, width, height);
        try std.testing.expectEqualSlices(u32, rebuilt_flags, packed_flags);
    }

    nb_flags[nbfIndex(nb_stride, 2, 3)] |= nbf_visit;
    packedT1MarkVisited(packed_flags, width, 2, 3);
    packedT1RebuildFromNbf(rebuilt_flags, nb_flags, nb_stride, width, height);
    try std.testing.expectEqualSlices(u32, rebuilt_flags, packed_flags);

    nb_flags[nbfIndex(nb_stride, 4, 4)] |= nbf_refine;
    packedT1MarkRefined(packed_flags, width, 4, 4);
    packedT1RebuildFromNbf(rebuilt_flags, nb_flags, nb_stride, width, height);
    try std.testing.expectEqualSlices(u32, rebuilt_flags, packed_flags);

    nb_flags[nbfIndex(nb_stride, 6, 8)] |= nbf_visit | nbf_refine;
    packedT1MarkVisited(packed_flags, width, 6, 8);
    packedT1MarkRefined(packed_flags, width, 6, 8);
    packedT1RebuildFromNbf(rebuilt_flags, nb_flags, nb_stride, width, height);
    try std.testing.expectEqualSlices(u32, rebuilt_flags, packed_flags);
}

test "EBCOT OpenJPEG-style packed context helpers match u16 flags" {
    const allocator = std.testing.allocator;
    const width = 7;
    const height = 9;
    const nb_stride = nbfStride(width);
    const nb_flags = try allocator.alloc(u16, nb_stride * (height + 2));
    defer allocator.free(nb_flags);
    @memset(nb_flags, 0);

    const packed_flags = try allocator.alloc(u32, width * pcfStripeCount(height));
    defer allocator.free(packed_flags);
    @memset(packed_flags, 0);

    const SigOp = struct {
        x: usize,
        y: usize,
        negative: bool,
    };
    const sig_ops = [_]SigOp{
        .{ .x = 0, .y = 0, .negative = true },
        .{ .x = 2, .y = 2, .negative = false },
        .{ .x = 3, .y = 3, .negative = true },
        .{ .x = 4, .y = 4, .negative = true },
        .{ .x = 6, .y = 8, .negative = false },
    };
    for (sig_ops) |op| {
        nbfMarkSignificant(nb_flags, nb_stride, op.x, op.y, op.negative);
        packedT1MarkSignificant(packed_flags, width, height, op.x, op.y, op.negative);
    }

    nb_flags[nbfIndex(nb_stride, 1, 1)] |= nbf_visit;
    packedT1MarkVisited(packed_flags, width, 1, 1);
    nb_flags[nbfIndex(nb_stride, 4, 4)] |= nbf_refine;
    packedT1MarkRefined(packed_flags, width, 4, 4);
    nb_flags[nbfIndex(nb_stride, 6, 8)] |= nbf_visit | nbf_refine;
    packedT1MarkVisited(packed_flags, width, 6, 8);
    packedT1MarkRefined(packed_flags, width, 6, 8);

    const styles = [_]CodeBlockStyle{
        .{ .band_kind = .ll },
        .{ .band_kind = .lh },
        .{ .band_kind = .hl },
        .{ .band_kind = .hh },
        .{ .band_kind = .ll, .vertical_causal = true },
        .{ .band_kind = .lh, .vertical_causal = true },
        .{ .band_kind = .hl, .vertical_causal = true },
        .{ .band_kind = .hh, .vertical_causal = true },
    };

    for (styles) |style| {
        var stripe_y: usize = 0;
        while (stripe_y < height) : (stripe_y += 4) {
            const stripe_height = @min(@as(usize, 4), height - stripe_y);
            var x: usize = 0;
            while (x < width) : (x += 1) {
                var ci: usize = 0;
                while (ci < stripe_height) : (ci += 1) {
                    const y = stripe_y + ci;
                    try expectPackedT1DecisionMatchesNbf(packed_flags, nb_flags, nb_stride, width, x, y, style);
                }
            }
        }
    }
}

test "EBCOT packed T1 decision helpers survive dense edge state" {
    const allocator = std.testing.allocator;
    const width = 9;
    const height = 10;
    const nb_stride = nbfStride(width);
    const nb_flags = try allocator.alloc(u16, nb_stride * (height + 2));
    defer allocator.free(nb_flags);
    @memset(nb_flags, 0);

    const packed_flags = try allocator.alloc(u32, width * pcfStripeCount(height));
    defer allocator.free(packed_flags);
    @memset(packed_flags, 0);

    const SigOp = struct {
        x: usize,
        y: usize,
        negative: bool,
    };
    const sig_ops = [_]SigOp{
        .{ .x = 0, .y = 1, .negative = true },
        .{ .x = 1, .y = 3, .negative = false },
        .{ .x = 2, .y = 4, .negative = true },
        .{ .x = 4, .y = 3, .negative = true },
        .{ .x = 5, .y = 5, .negative = false },
        .{ .x = 7, .y = 7, .negative = true },
        .{ .x = 8, .y = 8, .negative = false },
    };
    for (sig_ops) |op| {
        nbfMarkSignificant(nb_flags, nb_stride, op.x, op.y, op.negative);
        packedT1MarkSignificant(packed_flags, width, height, op.x, op.y, op.negative);
    }

    const FlagOp = struct {
        x: usize,
        y: usize,
        visit: bool = false,
        refine: bool = false,
    };
    const flag_ops = [_]FlagOp{
        .{ .x = 0, .y = 0, .visit = true },
        .{ .x = 1, .y = 3, .refine = true },
        .{ .x = 2, .y = 4, .visit = true, .refine = true },
        .{ .x = 4, .y = 3, .visit = true },
        .{ .x = 7, .y = 7, .refine = true },
        .{ .x = 8, .y = 9, .visit = true, .refine = true },
    };
    for (flag_ops) |op| {
        const p = nbfIndex(nb_stride, op.x, op.y);
        if (op.visit) {
            nb_flags[p] |= nbf_visit;
            packedT1MarkVisited(packed_flags, width, op.x, op.y);
        }
        if (op.refine) {
            nb_flags[p] |= nbf_refine;
            packedT1MarkRefined(packed_flags, width, op.x, op.y);
        }
    }

    const rebuilt_flags = try allocator.alloc(u32, width * pcfStripeCount(height));
    defer allocator.free(rebuilt_flags);
    packedT1RebuildFromNbf(rebuilt_flags, nb_flags, nb_stride, width, height);
    try std.testing.expectEqualSlices(u32, rebuilt_flags, packed_flags);

    const styles = [_]CodeBlockStyle{
        .{ .band_kind = .ll },
        .{ .band_kind = .lh },
        .{ .band_kind = .hl },
        .{ .band_kind = .hh },
        .{ .band_kind = .ll, .vertical_causal = true },
        .{ .band_kind = .lh, .vertical_causal = true },
        .{ .band_kind = .hl, .vertical_causal = true },
        .{ .band_kind = .hh, .vertical_causal = true },
    };

    for (styles) |style| {
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                try expectPackedT1DecisionMatchesNbf(packed_flags, nb_flags, nb_stride, width, x, y, style);
            }
        }
    }
}

test "EBCOT packed T1 cleanup-run candidates match u16 flags" {
    const allocator = std.testing.allocator;
    const width = 7;
    const height = 8;
    const nb_stride = nbfStride(width);
    const nb_flags = try allocator.alloc(u16, nb_stride * (height + 2));
    defer allocator.free(nb_flags);
    @memset(nb_flags, 0);

    const packed_flags = try allocator.alloc(u32, width * pcfStripeCount(height));
    defer allocator.free(packed_flags);
    @memset(packed_flags, 0);

    var stripe_y: usize = 0;
    while (stripe_y < height) : (stripe_y += 4) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            try std.testing.expect(packedT1CanUseRunStripeChecked(packed_flags, width, nb_flags, nb_stride, x, stripe_y, .{}));
        }
    }

    nbfMarkSignificant(nb_flags, nb_stride, 1, 1, false);
    packedT1MarkSignificant(packed_flags, width, height, 1, 1, false);
    nbfMarkSignificant(nb_flags, nb_stride, 4, 5, true);
    packedT1MarkSignificant(packed_flags, width, height, 4, 5, true);
    nb_flags[nbfIndex(nb_stride, 6, 7)] |= nbf_visit;
    packedT1MarkVisited(packed_flags, width, 6, 7);

    stripe_y = 0;
    while (stripe_y < height) : (stripe_y += 4) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const expected = nbfCanUseRunStripe(nb_flags, nb_stride, x, stripe_y, .{});
            const actual = packedT1CanUseRunStripeChecked(packed_flags, width, nb_flags, nb_stride, x, stripe_y, .{});
            try std.testing.expectEqual(expected, actual);
        }
    }

    @memset(nb_flags, 0);
    @memset(packed_flags, 0);
    nbfMarkSignificant(nb_flags, nb_stride, 3, 4, false);
    packedT1MarkSignificant(packed_flags, width, height, 3, 4, false);
    try std.testing.expect(!packedT1CanUseRunStripeChecked(packed_flags, width, nb_flags, nb_stride, 3, 0, .{}));
    try std.testing.expect(packedT1CanUseRunStripeChecked(
        packed_flags,
        width,
        nb_flags,
        nb_stride,
        3,
        0,
        .{ .vertical_causal = true },
    ));
}

test "EBCOT packed T1 clear visited matches u16 visit clear" {
    const allocator = std.testing.allocator;
    const width = 6;
    const height = 8;
    const nb_stride = nbfStride(width);
    const nb_flags = try allocator.alloc(u16, nb_stride * (height + 2));
    defer allocator.free(nb_flags);
    @memset(nb_flags, 0);

    const packed_flags = try allocator.alloc(u32, width * pcfStripeCount(height));
    defer allocator.free(packed_flags);
    @memset(packed_flags, 0);

    nbfMarkSignificant(nb_flags, nb_stride, 1, 1, true);
    nbfMarkSignificant(nb_flags, nb_stride, 4, 6, false);
    packedT1MarkSignificant(packed_flags, width, height, 1, 1, true);
    packedT1MarkSignificant(packed_flags, width, height, 4, 6, false);

    const visited = [_]struct { x: usize, y: usize }{
        .{ .x = 0, .y = 0 },
        .{ .x = 1, .y = 1 },
        .{ .x = 3, .y = 4 },
        .{ .x = 5, .y = 7 },
    };
    for (visited) |sample| {
        nb_flags[nbfIndex(nb_stride, sample.x, sample.y)] |= nbf_visit;
        packedT1MarkVisited(packed_flags, width, sample.x, sample.y);
    }

    nbfClearVisit(nb_flags);
    packedT1ClearVisited(packed_flags);

    const rebuilt_flags = try allocator.alloc(u32, width * pcfStripeCount(height));
    defer allocator.free(rebuilt_flags);
    packedT1RebuildFromNbf(rebuilt_flags, nb_flags, nb_stride, width, height);
    try std.testing.expectEqualSlices(u32, rebuilt_flags, packed_flags);
}

const stats_lanes = simd.i32_lanes;
const StatsVector = @Vector(stats_lanes, i32);
const StatsMaskVector = @Vector(stats_lanes, u32);
const stats_lane_masks = makeStatsLaneMasks();
const flag_clear_lanes = simd.i32_lanes * @sizeOf(i32);
const FlagClearVector = @Vector(flag_clear_lanes, u8);
const nbf_clear_lanes = simd.i32_lanes * (@sizeOf(i32) / @sizeOf(u16));
const NbfClearVector = @Vector(nbf_clear_lanes, u16);
const significant_word_bits = 64;

pub const DirectBlockScratch = struct {
    allocator: std.mem.Allocator,
    flags: std.ArrayList(u8) = .empty,
    significant_words: std.ArrayList(u64) = .empty,
    row_words: usize = 0,
    width: usize = 0,
    height: usize = 0,
    pass_payloads: std.ArrayList(CodeBlockPassPayload) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    segments: std.ArrayList(SegmentSpan) = .empty,
    nb_flags: std.ArrayList(u16) = .empty,
    nb_stride: usize = 0,
    packed_t1_flags: std.ArrayList(u32) = .empty,
    encoder: ?mq.Encoder = null,
    iso_encoder: ?mq_iso.Encoder = null,
    raw_writer: ?RawBitWriter = null,
    current_pass_distortion: ?*f64 = null,

    pub fn init(allocator: std.mem.Allocator) DirectBlockScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DirectBlockScratch) void {
        if (self.encoder) |*encoder| encoder.deinit();
        if (self.iso_encoder) |*encoder| encoder.deinit();
        if (self.raw_writer) |*writer| writer.deinit();
        self.flags.deinit(self.allocator);
        self.significant_words.deinit(self.allocator);
        self.pass_payloads.deinit(self.allocator);
        self.bytes.deinit(self.allocator);
        self.segments.deinit(self.allocator);
        self.nb_flags.deinit(self.allocator);
        self.packed_t1_flags.deinit(self.allocator);
        self.* = undefined;
    }

    fn reset(self: *DirectBlockScratch) void {
        self.pass_payloads.clearRetainingCapacity();
        self.bytes.clearRetainingCapacity();
        self.segments.clearRetainingCapacity();
        self.current_pass_distortion = null;
    }

    fn isoMqEncoder(self: *DirectBlockScratch) !*mq_iso.Encoder {
        if (self.iso_encoder) |*encoder| return encoder;
        self.iso_encoder = try mq_iso.Encoder.init(self.allocator, mq_context_count);
        return &self.iso_encoder.?;
    }

    fn rawBitWriter(self: *DirectBlockScratch) *RawBitWriter {
        if (self.raw_writer == null) self.raw_writer = RawBitWriter.init(self.allocator);
        return &self.raw_writer.?;
    }

    fn ensureBlockState(self: *DirectBlockScratch, width: usize, height: usize, area: usize) !void {
        try self.flags.resize(self.allocator, area);
        const row_words = rowWordCount(width);
        try self.significant_words.resize(self.allocator, try std.math.mul(usize, row_words, height));
        self.row_words = row_words;
        self.width = width;
        self.height = height;
        self.nb_stride = nbfStride(width);
        try self.nb_flags.resize(self.allocator, try std.math.mul(usize, self.nb_stride, height + 2));
        if (comptime maintain_packed_t1_context_flags) {
            try self.packed_t1_flags.resize(self.allocator, try std.math.mul(usize, width, pcfStripeCount(height)));
        }
    }

    fn mqEncoder(self: *DirectBlockScratch) !*mq.Encoder {
        if (self.encoder) |*encoder| return encoder;
        self.encoder = try mq.Encoder.init(self.allocator, mq_context_count);
        return &self.encoder.?;
    }
};

pub const DecodeBlockScratch = struct {
    allocator: std.mem.Allocator,
    flags: std.ArrayList(u8) = .empty,
    significant_words: std.ArrayList(u64) = .empty,
    coeffs: std.ArrayList(i32) = .empty,
    row_words: usize = 0,
    width: usize = 0,
    height: usize = 0,
    nb_flags: std.ArrayList(u16) = .empty,
    nb_stride: usize = 0,
    packed_t1_flags: std.ArrayList(u32) = .empty,
    iso_decoder: ?mq_iso.Decoder = null,

    pub fn init(allocator: std.mem.Allocator) DecodeBlockScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DecodeBlockScratch) void {
        if (self.iso_decoder) |*decoder| decoder.deinit();
        self.flags.deinit(self.allocator);
        self.significant_words.deinit(self.allocator);
        self.coeffs.deinit(self.allocator);
        self.nb_flags.deinit(self.allocator);
        self.packed_t1_flags.deinit(self.allocator);
        self.* = undefined;
    }

    /// Reusable ISO MQ decoder: INITDEC on the given segment and reset the
    /// JPEG2000 context states, without reallocating the context array.
    fn isoMqDecoder(self: *DecodeBlockScratch, bytes: []const u8) !*mq_iso.Decoder {
        if (self.iso_decoder) |*decoder| {
            decoder.reinitStream(bytes);
            try decoder.resetJpeg2000Contexts();
            return decoder;
        }
        self.iso_decoder = try mq_iso.Decoder.init(self.allocator, mq_context_count, bytes);
        try self.iso_decoder.?.resetJpeg2000Contexts();
        return &self.iso_decoder.?;
    }

    fn ensureBlockState(self: *DecodeBlockScratch, width: usize, height: usize, area: usize) !void {
        try self.flags.resize(self.allocator, area);
        try self.coeffs.resize(self.allocator, area);
        const row_words = rowWordCount(width);
        try self.significant_words.resize(self.allocator, try std.math.mul(usize, row_words, height));
        self.row_words = row_words;
        self.width = width;
        self.height = height;
        self.nb_stride = nbfStride(width);
        try self.nb_flags.resize(self.allocator, try std.math.mul(usize, self.nb_stride, height + 2));
        if (comptime maintain_packed_t1_context_flags) {
            try self.packed_t1_flags.resize(self.allocator, try std.math.mul(usize, width, pcfStripeCount(height)));
        }
    }
};

const SignCoding = struct {
    context: Context,
    predicted_negative: bool,
};

const segmentation_symbol_bits = [_]bool{ true, false, true, false };

pub fn encodeBlock(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !EncodedBlock {
    return encodeBlockWithStyle(allocator, plane, stride, rect, .{});
}

pub fn encodeBlockWithStyle(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    style: CodeBlockStyle,
) !EncodedBlock {
    var scratch = BlockScratch.init(allocator);
    defer scratch.deinit();

    const view = try encodeBlockScratchWithStyle(&scratch, plane, stride, rect, style);
    const pass_slice = try allocator.dupe(Pass, view.passes);
    errdefer allocator.free(pass_slice);
    const symbol_slice = try allocator.dupe(Symbol, view.symbols);

    return .{
        .bitplanes = view.bitplanes,
        .non_zero_count = view.non_zero_count,
        .passes = pass_slice,
        .symbols = symbol_slice,
    };
}

pub fn encodeBlockScratch(
    scratch: *BlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !EncodedBlockView {
    return encodeBlockScratchWithStyle(scratch, plane, stride, rect, .{});
}

/// Squared reconstruction error of a magnitude when the decoder knows the
/// bits down to (and including) plane `p`: midpoint reconstruction
/// ((m >> p) + 0.5) << p for p > 0, exact once every plane is coded.
fn midpointSquaredError(sample_magnitude: u64, p: u8) f64 {
    if (p == 0) return 0;
    const quotient = sample_magnitude >> @intCast(p);
    const reconstruction = (@as(f64, @floatFromInt(quotient)) + 0.5) *
        @as(f64, @floatFromInt(@as(u64, 1) << @intCast(p)));
    const err = @as(f64, @floatFromInt(sample_magnitude)) - reconstruction;
    return err * err;
}

/// Per-pass squared-error reductions in the coefficient domain (unweighted)
/// for PCRD rate allocation (ISO 15444-1 J.14). Pass membership comes from
/// the symbol-based reference coder: each sample's `sign` symbol marks its
/// significance event and each `magnitude_refinement` symbol marks one
/// refinement, both tagged with the pass they were coded in. The error model
/// is the decoder's midpoint reconstruction. Fills `out[0..pass_count]` and
/// returns the pass count.
pub fn passDistortions(
    scratch: *BlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    style: CodeBlockStyle,
    out: []f64,
) !u16 {
    const view = try encodeBlockScratchWithStyle(scratch, plane, stride, rect, style);
    const pass_count: u16 = @intCast(view.passes.len);
    if (out.len < pass_count) return EbcotError.InvalidBlock;
    @memset(out[0..pass_count], 0);

    for (view.symbols) |symbol| {
        const is_significance = symbol.kind == .sign;
        if (!is_significance and symbol.kind != .magnitude_refinement) continue;
        if (symbol.pass_index >= pass_count) return EbcotError.InvalidBlock;

        const value = plane[(rect.y + symbol.y) * stride + rect.x + symbol.x];
        const sample_magnitude: u64 = @abs(value);
        const p = symbol.magnitude_bitplane;
        const before = if (is_significance)
            @as(f64, @floatFromInt(sample_magnitude)) * @as(f64, @floatFromInt(sample_magnitude))
        else
            midpointSquaredError(sample_magnitude, p + 1);
        const after = midpointSquaredError(sample_magnitude, p);
        out[symbol.pass_index] += before - after;
    }
    return pass_count;
}

pub fn encodeBlockScratchWithStyle(
    scratch: *BlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    style: CodeBlockStyle,
) !EncodedBlockView {
    try validateImplementedStyleAllowBypass(style);
    scratch.reset();
    try validateBlock(plane, stride, rect);

    const stats = blockStats(plane, stride, rect);
    const bitplanes = stats.bitplanes;
    if (bitplanes == 0) {
        return .{
            .bitplanes = 0,
            .non_zero_count = 0,
            .passes = scratch.passes.items,
            .symbols = scratch.symbols.items,
        };
    }

    const area = try blockArea(rect);
    try scratch.ensureBlockState(area);
    const significant = scratch.significant.items;
    const visited = scratch.visited.items;
    const became_significant = scratch.became_significant.items;
    const refined = scratch.refined.items;
    @memset(significant, false);
    @memset(refined, false);

    var pass_index: u16 = 0;
    var bitplane_index = bitplanes;
    while (bitplane_index > 0) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        @memset(became_significant, false);

        if (bitplane == bitplanes - 1) {
            @memset(visited, false);
            try emitCleanupPass(
                scratch.allocator,
                &scratch.passes,
                &scratch.symbols,
                plane,
                stride,
                rect,
                bitplane,
                pass_index,
                significant,
                visited,
                became_significant,
                style,
            );
            pass_index += 1;
            continue;
        }

        @memset(visited, false);
        try emitSignificancePass(
            scratch.allocator,
            &scratch.passes,
            &scratch.symbols,
            plane,
            stride,
            rect,
            bitplane,
            pass_index,
            significant,
            visited,
            became_significant,
            style,
            passIsRaw(style, bitplanes, bitplane, .significance),
        );
        pass_index += 1;

        try emitRefinementPass(
            scratch.allocator,
            &scratch.passes,
            &scratch.symbols,
            plane,
            stride,
            rect,
            bitplane,
            pass_index,
            significant,
            became_significant,
            refined,
            style,
        );
        pass_index += 1;

        try emitCleanupPass(
            scratch.allocator,
            &scratch.passes,
            &scratch.symbols,
            plane,
            stride,
            rect,
            bitplane,
            pass_index,
            significant,
            visited,
            became_significant,
            style,
        );
        pass_index += 1;
    }

    return .{
        .bitplanes = bitplanes,
        .non_zero_count = stats.non_zero_count,
        .passes = scratch.passes.items,
        .symbols = scratch.symbols.items,
    };
}

pub fn mqContextIndex(context: Context) usize {
    return @intFromEnum(context);
}

pub fn encodeSymbolsMq(allocator: std.mem.Allocator, symbols: []const Symbol) !MqEncoded {
    var encoder = try mq.Encoder.init(allocator, mq_context_count);
    defer encoder.deinit();

    for (symbols) |symbol| {
        try encoder.write(mqContextIndex(symbol.context), symbol.bit);
    }

    return encoder.finish();
}

pub fn decodeSymbolBitsMq(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    symbol_count: usize,
    templates: []const Symbol,
) ![]bool {
    if (templates.len != symbol_count) return mq.MqError.InvalidData;

    var decoder = try mq.Decoder.init(allocator, mq_context_count, bytes, symbol_count);
    defer decoder.deinit();

    const bits = try allocator.alloc(bool, symbol_count);
    errdefer allocator.free(bits);
    for (templates, 0..) |symbol, index| {
        bits[index] = try mqRead(&decoder, mqContextIndex(symbol.context));
    }
    return bits;
}

pub fn decodeSymbolBitsIsoMq(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    symbol_count: usize,
    templates: []const Symbol,
) ![]bool {
    return decodeSymbolBitsIsoMqAfterPreviousByte(allocator, bytes, symbol_count, templates, 0);
}

pub fn decodeSymbolBitsIsoMqAfterPreviousByte(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    symbol_count: usize,
    templates: []const Symbol,
    previous_byte: u8,
) ![]bool {
    if (templates.len != symbol_count) return mq.MqError.InvalidData;

    var decoder = try mq_iso.Decoder.initAfterPreviousByte(allocator, mq_context_count, bytes, previous_byte);
    defer decoder.deinit();
    try decoder.resetJpeg2000Contexts();

    const bits = try allocator.alloc(bool, symbol_count);
    errdefer allocator.free(bits);
    for (templates, 0..) |symbol, index| {
        bits[index] = try mqRead(&decoder, mqContextIndex(symbol.context));
    }
    return bits;
}

pub fn encodeCodeBlockSegment(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !CodeBlockSegment {
    return encodeCodeBlockSegmentWithStyle(allocator, plane, stride, rect, .{});
}

pub fn encodeCodeBlockSegmentWithStyle(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    style: CodeBlockStyle,
) !CodeBlockSegment {
    var block = try encodeBlockWithStyle(allocator, plane, stride, rect, style);
    defer block.deinit(allocator);
    return encodeBlockSymbolsSegment(allocator, .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .passes = block.passes,
        .symbols = block.symbols,
    });
}

pub fn encodeCodeBlockSegmentContinuous(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !CodeBlockSegment {
    return encodeCodeBlockSegmentContinuousWithStyle(allocator, plane, stride, rect, .{});
}

pub fn encodeCodeBlockSegmentContinuousWithStyle(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    style: CodeBlockStyle,
) !CodeBlockSegment {
    var block = try encodeBlockWithStyle(allocator, plane, stride, rect, style);
    defer block.deinit(allocator);
    return encodeBlockSymbolsSegmentContinuousWithStyle(allocator, .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .passes = block.passes,
        .symbols = block.symbols,
    }, style);
}

pub fn encodeCodeBlockSegmentDirect(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !CodeBlockSegment {
    return encodeCodeBlockSegmentDirectWithStyle(allocator, plane, stride, rect, .{});
}

pub fn encodeCodeBlockSegmentDirectWithStyle(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    style: CodeBlockStyle,
) !CodeBlockSegment {
    var scratch = DirectBlockScratch.init(allocator);
    defer scratch.deinit();
    return encodeCodeBlockSegmentDirectScratchWithStyle(&scratch, plane, stride, rect, style);
}

pub fn encodeCodeBlockSegmentDirectScratch(
    scratch: *DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !CodeBlockSegment {
    return encodeCodeBlockSegmentDirectScratchWithStyle(scratch, plane, stride, rect, .{});
}

pub fn encodeCodeBlockSegmentDirectScratchWithStyle(
    scratch: *DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    style: CodeBlockStyle,
) !CodeBlockSegment {
    try validateImplementedStyle(style);
    scratch.reset();
    try validateBlock(plane, stride, rect);

    const stats = blockStats(plane, stride, rect);
    if (stats.bitplanes == 0) {
        return ownedSegmentFromDirectScratch(scratch, 0, 0);
    }

    const area = try blockArea(rect);
    try scratch.ensureBlockState(rect.width, rect.height, area);
    @memset(scratch.flags.items, 0);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
    if (comptime maintain_packed_t1_context_flags) @memset(scratch.packed_t1_flags.items, 0);

    var pass_index: u16 = 0;
    var bitplane_index = stats.bitplanes;
    while (bitplane_index > 0) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        clearFlag(scratch.flags.items, .became_significant);

        if (bitplane == stats.bitplanes - 1) {
            clearFlag(scratch.flags.items, .visited);
            try emitDirectCleanupPass(scratch, plane, stride, rect, bitplane, pass_index, style);
            pass_index += 1;
            continue;
        }

        clearFlag(scratch.flags.items, .visited);
        try emitDirectSignificancePass(scratch, plane, stride, rect, bitplane, pass_index, style);
        pass_index += 1;

        try emitDirectRefinementPass(scratch, plane, stride, rect, bitplane, pass_index, style);
        pass_index += 1;

        try emitDirectCleanupPass(scratch, plane, stride, rect, bitplane, pass_index, style);
        pass_index += 1;
    }

    return ownedSegmentFromDirectScratch(scratch, stats.bitplanes, stats.non_zero_count);
}

pub fn encodeBlockSymbolsSegment(allocator: std.mem.Allocator, block: EncodedBlockView) !CodeBlockSegment {
    var pass_payloads: std.ArrayList(CodeBlockPassPayload) = .empty;
    errdefer pass_payloads.deinit(allocator);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var encoder = try mq.Encoder.init(allocator, mq_context_count);
    defer encoder.deinit();

    for (block.passes) |pass| {
        const pass_symbols = block.symbols[pass.first_symbol..][0..pass.symbol_count];
        const byte_offset = bytes.items.len;
        encoder.resetAll();
        for (pass_symbols) |symbol| {
            try encoder.write(mqContextIndex(symbol.context), symbol.bit);
        }
        const encoded_len = try encoder.finishInto(allocator, &bytes);

        try pass_payloads.append(allocator, .{
            .kind = pass.kind,
            .magnitude_bitplane = pass.magnitude_bitplane,
            .symbol_count = pass.symbol_count,
            .byte_offset = byte_offset,
            .byte_length = encoded_len,
            .cumulative_bytes = @intCast(bytes.items.len),
        });
    }

    const pass_slice = try pass_payloads.toOwnedSlice(allocator);
    errdefer allocator.free(pass_slice);
    const byte_slice = try bytes.toOwnedSlice(allocator);

    return .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .pass_count = @intCast(pass_slice.len),
        .byte_length = @intCast(byte_slice.len),
        .passes = pass_slice,
        .bytes = byte_slice,
    };
}

pub fn encodeBlockSymbolsSegmentIsoMq(allocator: std.mem.Allocator, block: EncodedBlockView) !CodeBlockSegment {
    var pass_payloads: std.ArrayList(CodeBlockPassPayload) = .empty;
    errdefer pass_payloads.deinit(allocator);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var encoder = try mq_iso.Encoder.init(allocator, mq_context_count);
    defer encoder.deinit();

    for (block.passes) |pass| {
        if (pass.first_symbol + pass.symbol_count > block.symbols.len) return EbcotError.InvalidBlock;
        const pass_symbols = block.symbols[pass.first_symbol..][0..pass.symbol_count];
        const byte_offset = bytes.items.len;
        const previous_byte = if (bytes.items.len == 0) 0 else bytes.items[bytes.items.len - 1];
        encoder.resetStreamAfterPreviousByte(previous_byte);
        try encoder.resetJpeg2000Contexts();
        for (pass_symbols) |symbol| {
            try encoder.write(mqContextIndex(symbol.context), symbol.bit);
        }
        const encoded = try encoder.finish();
        defer allocator.free(encoded);
        try bytes.appendSlice(allocator, encoded);

        try pass_payloads.append(allocator, .{
            .kind = pass.kind,
            .magnitude_bitplane = pass.magnitude_bitplane,
            .symbol_count = pass.symbol_count,
            .byte_offset = byte_offset,
            .byte_length = encoded.len,
            .cumulative_bytes = @intCast(bytes.items.len),
        });
    }

    const pass_slice = try pass_payloads.toOwnedSlice(allocator);
    errdefer allocator.free(pass_slice);
    const byte_slice = try bytes.toOwnedSlice(allocator);

    return .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .pass_count = @intCast(pass_slice.len),
        .byte_length = @intCast(byte_slice.len),
        .passes = pass_slice,
        .bytes = byte_slice,
    };
}

pub fn encodeBlockSymbolsSegmentIsoMqContinuous(allocator: std.mem.Allocator, block: EncodedBlockView) !CodeBlockSegment {
    return encodeBlockSymbolsSegmentIsoMqContinuousWithStyle(allocator, block, .{});
}

pub fn encodeBlockSymbolsSegmentIsoMqContinuousWithStyle(
    allocator: std.mem.Allocator,
    block: EncodedBlockView,
    style: CodeBlockStyle,
) !CodeBlockSegment {
    if (block.passes.len == 0) {
        const passes = try allocator.dupe(CodeBlockPassPayload, &.{});
        errdefer allocator.free(passes);
        const bytes = try allocator.dupe(u8, &.{});
        return .{
            .bitplanes = block.bitplanes,
            .non_zero_count = block.non_zero_count,
            .pass_count = 0,
            .byte_length = 0,
            .passes = passes,
            .bytes = bytes,
        };
    }

    var pass_payloads: std.ArrayList(CodeBlockPassPayload) = .empty;
    errdefer pass_payloads.deinit(allocator);
    var encoder = try mq_iso.Encoder.init(allocator, mq_context_count);
    defer encoder.deinit();
    try encoder.resetJpeg2000Contexts();

    var symbol_offset: usize = 0;
    var previous_bytes: u64 = 0;
    for (block.passes, 0..) |pass, pass_ordinal| {
        if (symbol_offset + pass.symbol_count > block.symbols.len) return EbcotError.InvalidBlock;
        if (style.reset_context and pass_ordinal != 0) try encoder.resetJpeg2000Contexts();
        const pass_symbols = block.symbols[symbol_offset..][0..pass.symbol_count];
        for (pass_symbols) |symbol| {
            try encoder.write(mqContextIndex(symbol.context), symbol.bit);
        }
        const cumulative_bytes: u64 = @intCast(encoder.emittedByteCount());
        try pass_payloads.append(allocator, .{
            .kind = pass.kind,
            .magnitude_bitplane = pass.magnitude_bitplane,
            .symbol_count = pass.symbol_count,
            .byte_offset = @intCast(previous_bytes),
            .byte_length = @intCast(cumulative_bytes - previous_bytes),
            .cumulative_bytes = cumulative_bytes,
        });
        previous_bytes = cumulative_bytes;
        symbol_offset += pass.symbol_count;
    }
    if (symbol_offset != block.symbols.len) return EbcotError.InvalidBlock;

    // Standalone ERTERM (D.4.2 without TERMALL): the only termination point
    // in the continuous stream is the final flush, which must use the
    // predictable ER-TERM procedure instead of the standard flush.
    const encoded = if (style.predictable_termination)
        try encoder.finishErterm()
    else
        try encoder.finish();
    errdefer allocator.free(encoded);
    if (pass_payloads.items.len > 0) {
        const last = &pass_payloads.items[pass_payloads.items.len - 1];
        if (encoded.len < last.byte_offset) return EbcotError.InvalidBlock;
        last.byte_length = encoded.len - last.byte_offset;
        last.cumulative_bytes = @intCast(encoded.len);
    } else if (encoded.len != 0) {
        return EbcotError.InvalidBlock;
    }

    const pass_slice = try pass_payloads.toOwnedSlice(allocator);
    errdefer allocator.free(pass_slice);

    return .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .pass_count = @intCast(pass_slice.len),
        .byte_length = @intCast(encoded.len),
        .passes = pass_slice,
        .bytes = encoded,
    };
}

/// ISO/IEC 15444-1 D.6 raw (bypass) bit writer: bits are packed MSB first,
/// and a byte following 0xff only carries seven payload bits (its msb is a
/// stuffed zero).
const RawBitWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    output: ?*std.ArrayList(u8) = null,
    output_start: usize = 0,
    byte: u8 = 0,
    remaining: u8 = 8,

    fn init(allocator: std.mem.Allocator) RawBitWriter {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *RawBitWriter) void {
        self.buffer.deinit(self.allocator);
        self.* = undefined;
    }

    fn reset(self: *RawBitWriter) void {
        self.output = null;
        self.output_start = 0;
        self.buffer.clearRetainingCapacity();
        self.resetState();
    }

    fn resetInto(self: *RawBitWriter, output: *std.ArrayList(u8)) void {
        self.output = output;
        self.output_start = output.items.len;
        self.resetState();
    }

    fn resetState(self: *RawBitWriter) void {
        self.byte = 0;
        self.remaining = 8;
    }

    fn writeBit(self: *RawBitWriter, bit: bool) !void {
        self.remaining -= 1;
        if (bit) self.byte |= @as(u8, 1) << @intCast(self.remaining);
        if (self.remaining == 0) {
            try self.appendByte(self.byte);
            self.remaining = if (self.byte == 0xff) 7 else 8;
            self.byte = 0;
        }
    }

    /// Segment termination mirroring opj_mqc_bypass_flush_enc without
    /// predictable termination: pad pending bits with an alternating 0,1
    /// sequence; a pending stuffed-only byte after 0xff drops the 0xff.
    fn finish(self: *RawBitWriter) ![]u8 {
        std.debug.assert(self.output == null);
        try self.finishActiveStream();
        return self.buffer.toOwnedSlice(self.allocator);
    }

    fn finishInto(self: *RawBitWriter, output: *std.ArrayList(u8)) !usize {
        std.debug.assert(self.output == output);
        const start = self.output_start;
        try self.finishActiveStream();
        return output.items.len - start;
    }

    fn finishActiveStream(self: *RawBitWriter) !void {
        if (self.remaining < 7 or (self.remaining == 7 and self.lastActiveByteIsNotFf())) {
            var bit_value: u8 = 0;
            while (self.remaining > 0) {
                self.remaining -= 1;
                self.byte |= bit_value << @intCast(self.remaining);
                bit_value = 1 - bit_value;
            }
            try self.appendByte(self.byte);
        } else if (self.remaining == 7 and self.activeByteCount() > 0 and
            !self.lastActiveByteIsNotFf())
        {
            _ = self.activeBytes().pop();
        }
    }

    /// Predictable termination of a raw segment (ERTERM with BYPASS),
    /// mirroring opj_mqc_bypass_flush_enc with erterm set: any pending
    /// partial byte is completed with the alternating 0,1,... sequence, and
    /// the empty 7-bit byte after a stuffed 0xff — which the plain flush
    /// discards together with the 0xff — is emitted as 0x2a instead, so a
    /// resilient decoder can verify the termination (Kakadu checks this in
    /// fussy mode).
    fn finishErterm(self: *RawBitWriter) ![]u8 {
        std.debug.assert(self.output == null);
        try self.finishActiveStreamErterm();
        return self.buffer.toOwnedSlice(self.allocator);
    }

    fn finishErtermInto(self: *RawBitWriter, output: *std.ArrayList(u8)) !usize {
        std.debug.assert(self.output == output);
        const start = self.output_start;
        try self.finishActiveStreamErterm();
        return output.items.len - start;
    }

    fn finishActiveStreamErterm(self: *RawBitWriter) !void {
        if (self.remaining < 8) {
            var bit_value: u8 = 0;
            while (self.remaining > 0) {
                self.remaining -= 1;
                self.byte |= bit_value << @intCast(self.remaining);
                bit_value = 1 - bit_value;
            }
            try self.appendByte(self.byte);
        }
    }

    fn emittedByteCount(self: RawBitWriter) usize {
        return self.activeByteCount();
    }

    fn appendByte(self: *RawBitWriter, value: u8) !void {
        const bytes = self.activeBytes();
        if (bytes.items.len < bytes.capacity) {
            bytes.appendAssumeCapacity(value);
        } else {
            try bytes.append(self.allocator, value);
        }
    }

    fn activeBytes(self: *RawBitWriter) *std.ArrayList(u8) {
        return self.output orelse &self.buffer;
    }

    fn activeBytesConst(self: RawBitWriter) *const std.ArrayList(u8) {
        return self.output orelse &self.buffer;
    }

    fn activeByteCount(self: RawBitWriter) usize {
        const bytes = self.activeBytesConst();
        return bytes.items.len - self.output_start;
    }

    fn lastActiveByteIsNotFf(self: RawBitWriter) bool {
        const bytes = self.activeBytesConst().items;
        return bytes.len == self.output_start or bytes[bytes.len - 1] != 0xff;
    }
};

/// Raw (bypass) segment bit reader; bytes past the segment read as 0xff,
/// matching opj_mqc_raw_decode.
const RawBitReader = struct {
    bytes: []const u8,
    pos: usize = 0,
    byte: u8 = 0,
    remaining: u8 = 0,

    fn init(bytes: []const u8) RawBitReader {
        return .{ .bytes = bytes };
    }

    inline fn byteAt(self: RawBitReader, index: usize) u8 {
        if (index < self.bytes.len) return self.bytes[index];
        return 0xff;
    }

    inline fn readBit(self: *RawBitReader) bool {
        if (self.remaining == 0) {
            if (self.byte == 0xff) {
                const next = self.byteAt(self.pos);
                if (next > 0x8f) {
                    self.byte = 0xff;
                    self.remaining = 8;
                } else {
                    self.byte = next;
                    self.pos += 1;
                    self.remaining = 7;
                }
            } else {
                self.byte = self.byteAt(self.pos);
                self.pos += 1;
                self.remaining = 8;
            }
        }
        self.remaining -= 1;
        return ((self.byte >> @intCast(self.remaining)) & 1) != 0;
    }
};

/// Multi-segment BYPASS encoder: one MQ segment for the first ten passes,
/// then alternating raw (significance + refinement) and MQ (cleanup)
/// segments, each independently terminated (ISO D.6 / opj_t1_enc_is_term_pass
/// without termall or predictable termination).
pub fn encodeBlockSymbolsSegmentIsoMqBypass(
    allocator: std.mem.Allocator,
    block: EncodedBlockView,
    style: CodeBlockStyle,
) !CodeBlockSegment {
    try validateImplementedStyleAllowBypass(style);
    if (!style.bypass or style.terminate_all) return EbcotError.InvalidBlock;
    if (block.passes.len == 0) {
        const passes = try allocator.dupe(CodeBlockPassPayload, &.{});
        errdefer allocator.free(passes);
        const bytes = try allocator.dupe(u8, &.{});
        return .{
            .bitplanes = block.bitplanes,
            .non_zero_count = block.non_zero_count,
            .pass_count = 0,
            .byte_length = 0,
            .passes = passes,
            .bytes = bytes,
        };
    }

    var pass_payloads: std.ArrayList(CodeBlockPassPayload) = .empty;
    errdefer pass_payloads.deinit(allocator);
    var segments: std.ArrayList(SegmentSpan) = .empty;
    errdefer segments.deinit(allocator);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    var encoder = try mq_iso.Encoder.init(allocator, mq_context_count);
    defer encoder.deinit();
    try encoder.resetJpeg2000Contexts();
    var raw = RawBitWriter.init(allocator);
    defer raw.deinit();

    var symbol_offset: usize = 0;
    var segment_start_bytes: u64 = 0;
    var segment_pass_count: u16 = 0;
    var segment_is_raw = false;
    for (block.passes, 0..) |pass, ordinal| {
        if (symbol_offset + pass.symbol_count > block.symbols.len) return EbcotError.InvalidBlock;
        const is_raw = passIsRaw(style, block.bitplanes, pass.magnitude_bitplane, pass.kind);
        if (segment_pass_count == 0) {
            segment_is_raw = is_raw;
        } else if (is_raw != segment_is_raw) {
            return EbcotError.InvalidBlock;
        }
        // RESET (D.4) restarts the MQ contexts at every coding-pass
        // boundary; raw passes carry no contexts, so the reset before them
        // is a no-op that keeps the pass accounting uniform.
        if (style.reset_context and ordinal != 0) try encoder.resetJpeg2000Contexts();
        const pass_symbols = block.symbols[symbol_offset..][0..pass.symbol_count];
        if (is_raw) {
            for (pass_symbols) |symbol| try raw.writeBit(symbol.bit);
        } else {
            for (pass_symbols) |symbol| {
                try encoder.write(mqContextIndex(symbol.context), symbol.bit);
            }
        }
        symbol_offset += pass.symbol_count;
        segment_pass_count += 1;

        const running: u64 = segment_start_bytes +
            (if (is_raw) @as(u64, raw.buffer.items.len) else @as(u64, encoder.emittedByteCount()));
        try pass_payloads.append(allocator, .{
            .kind = pass.kind,
            .magnitude_bitplane = pass.magnitude_bitplane,
            .symbol_count = pass.symbol_count,
            .byte_offset = @intCast(segment_start_bytes),
            .byte_length = @intCast(running - segment_start_bytes),
            .cumulative_bytes = running,
        });

        const last_pass = ordinal + 1 == block.passes.len;
        if (last_pass or passEndsBypassSegment(style, block.bitplanes, pass.magnitude_bitplane, pass.kind)) {
            // ERTERM (D.4.2 with BYPASS): every codeword segment terminates
            // predictably — MQ segments with the ER-TERM flush, raw segments
            // with the alternating-bit padding.
            const encoded = if (segment_is_raw)
                (if (style.predictable_termination) try raw.finishErterm() else try raw.finish())
            else
                (if (style.predictable_termination) try encoder.finishErterm() else try encoder.finish());
            defer allocator.free(encoded);
            try bytes.appendSlice(allocator, encoded);
            try segments.append(allocator, .{
                .pass_count = segment_pass_count,
                .byte_length = @intCast(encoded.len),
            });
            const cumulative: u64 = @intCast(bytes.items.len);
            const fixup = &pass_payloads.items[pass_payloads.items.len - 1];
            fixup.byte_length = cumulative - fixup.byte_offset;
            fixup.cumulative_bytes = cumulative;
            segment_start_bytes = cumulative;
            segment_pass_count = 0;
            if (!last_pass) {
                if (segment_is_raw) raw.reset() else encoder.resetStream();
            }
        }
    }
    if (symbol_offset != block.symbols.len) return EbcotError.InvalidBlock;

    const pass_slice = try pass_payloads.toOwnedSlice(allocator);
    errdefer allocator.free(pass_slice);
    const segment_slice = try segments.toOwnedSlice(allocator);
    errdefer allocator.free(segment_slice);
    const byte_slice = try bytes.toOwnedSlice(allocator);

    return .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .pass_count = @intCast(pass_slice.len),
        .byte_length = @intCast(byte_slice.len),
        .passes = pass_slice,
        .bytes = byte_slice,
        .segments = segment_slice,
    };
}

/// BYPASS+TERMALL encoder: every coding pass is its own terminated codeword
/// segment, but D.6 raw bypass still applies to significance/refinement passes
/// below the bypass threshold. MQ contexts persist across MQ segments; raw
/// segments carry no MQ state.
pub fn encodeBlockSymbolsSegmentIsoMqBypassTerminated(
    allocator: std.mem.Allocator,
    block: EncodedBlockView,
    style: CodeBlockStyle,
) !CodeBlockSegment {
    try validateImplementedStyleAllowBypass(style);
    if (!style.bypass or !style.terminate_all) return EbcotError.InvalidBlock;
    if (block.passes.len == 0) {
        const passes = try allocator.dupe(CodeBlockPassPayload, &.{});
        errdefer allocator.free(passes);
        const bytes = try allocator.dupe(u8, &.{});
        return .{
            .bitplanes = block.bitplanes,
            .non_zero_count = block.non_zero_count,
            .pass_count = 0,
            .byte_length = 0,
            .passes = passes,
            .bytes = bytes,
        };
    }
    if (block.passes.len > max_block_segments) return EbcotError.InvalidBlock;

    var pass_payloads: std.ArrayList(CodeBlockPassPayload) = .empty;
    errdefer pass_payloads.deinit(allocator);
    var segments: std.ArrayList(SegmentSpan) = .empty;
    errdefer segments.deinit(allocator);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    var encoder = try mq_iso.Encoder.init(allocator, mq_context_count);
    defer encoder.deinit();
    try encoder.resetJpeg2000Contexts();
    var raw = RawBitWriter.init(allocator);
    defer raw.deinit();

    var symbol_offset: usize = 0;
    for (block.passes, 0..) |pass, ordinal| {
        if (symbol_offset + pass.symbol_count > block.symbols.len) return EbcotError.InvalidBlock;
        const is_raw = passIsRaw(style, block.bitplanes, pass.magnitude_bitplane, pass.kind);
        // RESET restarts the MQ contexts at every coding-pass boundary; raw
        // passes carry no contexts, so resetting before them is a no-op.
        if (style.reset_context and ordinal != 0) try encoder.resetJpeg2000Contexts();
        const pass_symbols = block.symbols[symbol_offset..][0..pass.symbol_count];
        if (is_raw) {
            for (pass_symbols) |symbol| try raw.writeBit(symbol.bit);
        } else {
            for (pass_symbols) |symbol| {
                try encoder.write(mqContextIndex(symbol.context), symbol.bit);
            }
        }

        // ERTERM: every per-pass segment terminates predictably.
        const encoded = if (is_raw)
            (if (style.predictable_termination) try raw.finishErterm() else try raw.finish())
        else
            (if (style.predictable_termination) try encoder.finishErterm() else try encoder.finish());
        defer allocator.free(encoded);
        const byte_offset = bytes.items.len;
        try bytes.appendSlice(allocator, encoded);
        try pass_payloads.append(allocator, .{
            .kind = pass.kind,
            .magnitude_bitplane = pass.magnitude_bitplane,
            .symbol_count = pass.symbol_count,
            .byte_offset = byte_offset,
            .byte_length = @intCast(encoded.len),
            .cumulative_bytes = @intCast(bytes.items.len),
        });
        try segments.append(allocator, .{ .pass_count = 1, .byte_length = @intCast(encoded.len) });
        symbol_offset += pass.symbol_count;

        if (is_raw) {
            raw.reset();
        } else {
            const previous_byte = if (bytes.items.len == 0) @as(u8, 0) else bytes.items[bytes.items.len - 1];
            encoder.resetStreamAfterPreviousByte(previous_byte);
        }
    }
    if (symbol_offset != block.symbols.len) return EbcotError.InvalidBlock;

    const pass_slice = try pass_payloads.toOwnedSlice(allocator);
    errdefer allocator.free(pass_slice);
    const segment_slice = try segments.toOwnedSlice(allocator);
    errdefer allocator.free(segment_slice);
    const byte_slice = try bytes.toOwnedSlice(allocator);

    return .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .pass_count = @intCast(pass_slice.len),
        .byte_length = @intCast(byte_slice.len),
        .passes = pass_slice,
        .bytes = byte_slice,
        .segments = segment_slice,
    };
}

/// ISO MQ terminate_all encoder: every coding pass is flushed into its own
/// independently-terminated MQ codeword segment (ISO 15444-1 D.4.5). The
/// adaptive contexts persist across passes (resetStream keeps them and only
/// restarts the coder register), matching the strict decoder's per-segment
/// `reinitStream`. Unlike encodeBlockSymbolsSegmentTerminated (which uses the
/// internal arithmetic coder for oracle tests) this emits ISO MQ bytes suitable
/// for the public codestream.
pub fn encodeBlockSymbolsSegmentIsoMqTerminated(
    allocator: std.mem.Allocator,
    block: EncodedBlockView,
    style: CodeBlockStyle,
) !CodeBlockSegment {
    // predictable_termination is supported here (and only here), layered on
    // terminate_all: every pass segment is flushed with the ER-TERM procedure
    // (D.4.2) instead of the standard setbits flush. RESET (D.4.3) is safe in
    // this per-pass segment path because every pass has an explicit byte
    // boundary. BYPASS+TERMALL has a separate raw/MQ per-pass segment model.
    if (style.bypass) return encodeBlockSymbolsSegmentIsoMqBypassTerminated(allocator, block, style);
    if (!style.terminate_all or style.bypass) return EbcotError.InvalidBlock;
    if (block.passes.len == 0) {
        const passes = try allocator.dupe(CodeBlockPassPayload, &.{});
        errdefer allocator.free(passes);
        const bytes = try allocator.dupe(u8, &.{});
        return .{
            .bitplanes = block.bitplanes,
            .non_zero_count = block.non_zero_count,
            .pass_count = 0,
            .byte_length = 0,
            .passes = passes,
            .bytes = bytes,
        };
    }
    if (block.passes.len > max_block_segments) return EbcotError.InvalidBlock;

    var pass_payloads: std.ArrayList(CodeBlockPassPayload) = .empty;
    errdefer pass_payloads.deinit(allocator);
    var segments: std.ArrayList(SegmentSpan) = .empty;
    errdefer segments.deinit(allocator);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);

    var encoder = try mq_iso.Encoder.init(allocator, mq_context_count);
    defer encoder.deinit();
    try encoder.resetJpeg2000Contexts();

    var symbol_offset: usize = 0;
    for (block.passes, 0..) |pass, ordinal| {
        if (symbol_offset + pass.symbol_count > block.symbols.len) return EbcotError.InvalidBlock;
        if (style.reset_context and ordinal != 0) try encoder.resetJpeg2000Contexts();
        const pass_symbols = block.symbols[symbol_offset..][0..pass.symbol_count];
        for (pass_symbols) |symbol| {
            try encoder.write(mqContextIndex(symbol.context), symbol.bit);
        }
        const encoded = if (style.predictable_termination)
            try encoder.finishErterm()
        else
            try encoder.finish();
        defer allocator.free(encoded);
        const byte_offset = bytes.items.len;
        try bytes.appendSlice(allocator, encoded);
        try pass_payloads.append(allocator, .{
            .kind = pass.kind,
            .magnitude_bitplane = pass.magnitude_bitplane,
            .symbol_count = pass.symbol_count,
            .byte_offset = byte_offset,
            .byte_length = @intCast(encoded.len),
            .cumulative_bytes = @intCast(bytes.items.len),
        });
        try segments.append(allocator, .{ .pass_count = 1, .byte_length = @intCast(encoded.len) });
        symbol_offset += pass.symbol_count;
        const last_pass = ordinal + 1 == block.passes.len;
        if (!last_pass) {
            const previous_byte = if (bytes.items.len == 0) @as(u8, 0) else bytes.items[bytes.items.len - 1];
            encoder.resetStreamAfterPreviousByte(previous_byte);
        }
    }
    if (symbol_offset != block.symbols.len) return EbcotError.InvalidBlock;

    const pass_slice = try pass_payloads.toOwnedSlice(allocator);
    errdefer allocator.free(pass_slice);
    const segment_slice = try segments.toOwnedSlice(allocator);
    errdefer allocator.free(segment_slice);
    const byte_slice = try bytes.toOwnedSlice(allocator);

    return .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .pass_count = @intCast(pass_slice.len),
        .byte_length = @intCast(byte_slice.len),
        .passes = pass_slice,
        .bytes = byte_slice,
        .segments = segment_slice,
    };
}

/// Plane-in wrapper for the ISO MQ terminate_all segment encoder.
pub fn encodeCodeBlockSegmentIsoMqTerminatedWithStyle(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    style: CodeBlockStyle,
) !CodeBlockSegment {
    // Symbol generation is termination-independent — predictable_termination
    // only changes how each per-pass segment is flushed.
    var block = try encodeBlockWithStyle(allocator, plane, stride, rect, style);
    defer block.deinit(allocator);
    return encodeBlockSymbolsSegmentIsoMqTerminated(allocator, .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .passes = block.passes,
        .symbols = block.symbols,
    }, style);
}

pub fn encodeBlockSymbolsSegmentContinuous(allocator: std.mem.Allocator, block: EncodedBlockView) !CodeBlockSegment {
    return encodeBlockSymbolsSegmentContinuousWithStyle(allocator, block, .{});
}

pub fn encodeBlockSymbolsSegmentContinuousWithStyle(allocator: std.mem.Allocator, block: EncodedBlockView, style: CodeBlockStyle) !CodeBlockSegment {
    try validateImplementedStyle(style);
    if (block.passes.len == 0) {
        const passes = try allocator.dupe(CodeBlockPassPayload, &.{});
        errdefer allocator.free(passes);
        const bytes = try allocator.dupe(u8, &.{});
        return .{
            .bitplanes = block.bitplanes,
            .non_zero_count = block.non_zero_count,
            .pass_count = 0,
            .byte_length = 0,
            .passes = passes,
            .bytes = bytes,
        };
    }
    if (style.terminate_all) return encodeBlockSymbolsSegmentTerminated(allocator, block, style);

    var pass_payloads: std.ArrayList(CodeBlockPassPayload) = .empty;
    errdefer pass_payloads.deinit(allocator);
    var encoder = try mq.Encoder.init(allocator, mq_context_count);
    defer encoder.deinit();

    var symbol_offset: usize = 0;
    var previous_bytes: u64 = 0;
    for (block.passes, 0..) |pass, pass_ordinal| {
        if (symbol_offset + pass.symbol_count > block.symbols.len) return EbcotError.InvalidBlock;
        if (style.reset_context and pass_ordinal != 0) encoder.resetContexts();
        const pass_symbols = block.symbols[symbol_offset..][0..pass.symbol_count];
        for (pass_symbols) |symbol| {
            try encoder.write(mqContextIndex(symbol.context), symbol.bit);
        }

        const cumulative_bytes = encoderBufferedByteCount(&encoder);
        try pass_payloads.append(allocator, .{
            .kind = pass.kind,
            .magnitude_bitplane = pass.magnitude_bitplane,
            .symbol_count = pass.symbol_count,
            .byte_offset = @intCast(previous_bytes),
            .byte_length = @intCast(cumulative_bytes - previous_bytes),
            .cumulative_bytes = cumulative_bytes,
        });
        previous_bytes = cumulative_bytes;
        symbol_offset += pass.symbol_count;
    }
    if (symbol_offset != block.symbols.len) return EbcotError.InvalidBlock;

    const encoded = try encoder.finish();
    errdefer allocator.free(encoded.bytes);
    if (pass_payloads.items.len > 0) {
        const last = &pass_payloads.items[pass_payloads.items.len - 1];
        if (encoded.bytes.len < last.byte_offset) return EbcotError.InvalidBlock;
        last.byte_length = encoded.bytes.len - last.byte_offset;
        last.cumulative_bytes = @intCast(encoded.bytes.len);
    } else if (encoded.bytes.len != 0) {
        return EbcotError.InvalidBlock;
    }

    const pass_slice = try pass_payloads.toOwnedSlice(allocator);
    errdefer allocator.free(pass_slice);

    return .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .pass_count = @intCast(pass_slice.len),
        .byte_length = @intCast(encoded.bytes.len),
        .passes = pass_slice,
        .bytes = encoded.bytes,
    };
}

fn encodeBlockSymbolsSegmentTerminated(allocator: std.mem.Allocator, block: EncodedBlockView, style: CodeBlockStyle) !CodeBlockSegment {
    // terminate_all: every coding pass is independently terminated, so each pass
    // forms its own codeword segment (ISO 15444-1 D.4.5). Emit a per-pass
    // segment table so the packet writer records one length per pass and the
    // strict decoder can restart the MQ codeword register at each boundary.
    if (block.passes.len > max_block_segments) return EbcotError.InvalidBlock;
    var pass_payloads: std.ArrayList(CodeBlockPassPayload) = .empty;
    errdefer pass_payloads.deinit(allocator);
    var segments: std.ArrayList(SegmentSpan) = .empty;
    errdefer segments.deinit(allocator);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var encoder = try mq.Encoder.init(allocator, mq_context_count);
    defer encoder.deinit();

    var symbol_offset: usize = 0;
    for (block.passes, 0..) |pass, pass_ordinal| {
        if (symbol_offset + pass.symbol_count > block.symbols.len) return EbcotError.InvalidBlock;
        if (style.reset_context and pass_ordinal != 0) encoder.resetContexts();
        const pass_symbols = block.symbols[symbol_offset..][0..pass.symbol_count];
        const byte_offset = bytes.items.len;
        for (pass_symbols) |symbol| {
            try encoder.write(mqContextIndex(symbol.context), symbol.bit);
        }
        const encoded_len = try encoder.finishInto(allocator, &bytes);

        try pass_payloads.append(allocator, .{
            .kind = pass.kind,
            .magnitude_bitplane = pass.magnitude_bitplane,
            .symbol_count = pass.symbol_count,
            .byte_offset = byte_offset,
            .byte_length = encoded_len,
            .cumulative_bytes = @intCast(bytes.items.len),
        });
        try segments.append(allocator, .{ .pass_count = 1, .byte_length = encoded_len });
        symbol_offset += pass.symbol_count;
        encoder.resetSegmentRetainingContexts();
    }
    if (symbol_offset != block.symbols.len) return EbcotError.InvalidBlock;

    const pass_slice = try pass_payloads.toOwnedSlice(allocator);
    errdefer allocator.free(pass_slice);
    const segment_slice = try segments.toOwnedSlice(allocator);
    errdefer allocator.free(segment_slice);
    const byte_slice = try bytes.toOwnedSlice(allocator);

    return .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .pass_count = @intCast(pass_slice.len),
        .byte_length = @intCast(byte_slice.len),
        .passes = pass_slice,
        .bytes = byte_slice,
        .segments = segment_slice,
    };
}

fn encoderBufferedByteCount(encoder: *const mq.Encoder) u64 {
    return @as(u64, @intCast(encoder.writer.bytes.items.len)) + @intFromBool(encoder.writer.used != 0);
}

fn ownedSegmentFromDirectScratch(
    scratch: *DirectBlockScratch,
    bitplanes: u8,
    non_zero_count: u32,
) !CodeBlockSegment {
    const pass_slice = try scratch.allocator.dupe(CodeBlockPassPayload, scratch.pass_payloads.items);
    errdefer scratch.allocator.free(pass_slice);
    const byte_slice = try scratch.allocator.dupe(u8, scratch.bytes.items);

    return .{
        .bitplanes = bitplanes,
        .non_zero_count = non_zero_count,
        .pass_count = @intCast(pass_slice.len),
        .byte_length = @intCast(byte_slice.len),
        .passes = pass_slice,
        .bytes = byte_slice,
    };
}

pub fn decodeCodeBlockSegmentBits(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    templates: []const Symbol,
) ![]bool {
    var total_symbols: usize = 0;
    for (segment.passes) |pass| total_symbols += pass.symbol_count;
    if (total_symbols != templates.len) return mq.MqError.InvalidData;

    const bits = try allocator.alloc(bool, templates.len);
    errdefer allocator.free(bits);

    var symbol_offset: usize = 0;
    for (segment.passes) |pass| {
        const byte_end = try std.math.add(usize, pass.byte_offset, pass.byte_length);
        if (byte_end > segment.bytes.len) return mq.MqError.InvalidData;

        const pass_templates = templates[symbol_offset..][0..pass.symbol_count];
        const pass_bits = try decodeSymbolBitsMq(
            allocator,
            segment.bytes[pass.byte_offset..byte_end],
            pass.symbol_count,
            pass_templates,
        );
        defer allocator.free(pass_bits);
        @memcpy(bits[symbol_offset..][0..pass.symbol_count], pass_bits);
        symbol_offset += pass.symbol_count;
    }

    return bits;
}

pub fn decodeCodeBlockSegmentBitsIsoMq(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    templates: []const Symbol,
) ![]bool {
    var total_symbols: usize = 0;
    for (segment.passes) |pass| total_symbols += pass.symbol_count;
    if (total_symbols != templates.len) return mq.MqError.InvalidData;

    const bits = try allocator.alloc(bool, templates.len);
    errdefer allocator.free(bits);

    var symbol_offset: usize = 0;
    for (segment.passes) |pass| {
        const byte_end = try std.math.add(usize, pass.byte_offset, pass.byte_length);
        if (byte_end > segment.bytes.len) return mq.MqError.InvalidData;

        const pass_templates = templates[symbol_offset..][0..pass.symbol_count];
        const previous_byte = if (pass.byte_offset == 0) 0 else segment.bytes[pass.byte_offset - 1];
        const pass_bits = try decodeSymbolBitsIsoMqAfterPreviousByte(
            allocator,
            segment.bytes[pass.byte_offset..byte_end],
            pass.symbol_count,
            pass_templates,
            previous_byte,
        );
        defer allocator.free(pass_bits);
        @memcpy(bits[symbol_offset..][0..pass.symbol_count], pass_bits);
        symbol_offset += pass.symbol_count;
    }

    return bits;
}

pub fn decodeCodeBlockSegmentBitsContinuous(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    templates: []const Symbol,
) ![]bool {
    var total_symbols: usize = 0;
    for (segment.passes) |pass| total_symbols += pass.symbol_count;
    if (total_symbols != templates.len) return mq.MqError.InvalidData;
    return decodeSymbolBitsMq(allocator, segment.bytes, templates.len, templates);
}

pub fn decodeCodeBlockSegmentCoefficients(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
) ![]i32 {
    return decodeCodeBlockSegmentCoefficientsWithStyle(allocator, segment, width, height, .{});
}

pub fn decodeCodeBlockSegmentCoefficientsWithStyle(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    var scratch = DecodeBlockScratch.init(allocator);
    defer scratch.deinit();
    return decodeCodeBlockSegmentCoefficientsBoundedScratch(&scratch, segment, width, height, .direct, true, style);
}

pub fn decodeCodeBlockSegmentCoefficientsContinuous(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
) ![]i32 {
    return decodeCodeBlockSegmentCoefficientsContinuousWithStyle(allocator, segment, width, height, .{});
}

pub fn decodeCodeBlockSegmentCoefficientsContinuousWithStyle(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    var scratch = DecodeBlockScratch.init(allocator);
    defer scratch.deinit();
    return decodeCodeBlockSegmentCoefficientsBoundedScratch(&scratch, segment, width, height, .continuous, true, style);
}

pub fn decodeCodeBlockPayloadContinuousInferred(
    allocator: std.mem.Allocator,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    width: usize,
    height: usize,
) ![]i32 {
    return decodeCodeBlockPayloadContinuousInferredWithStyle(allocator, bitplanes, pass_count, bytes, width, height, .{});
}

pub fn decodeCodeBlockPayloadContinuousInferredWithStyle(
    allocator: std.mem.Allocator,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    var scratch = DecodeBlockScratch.init(allocator);
    defer scratch.deinit();
    return decodeCodeBlockPayloadContinuousInferredScratchWithStyle(&scratch, bitplanes, pass_count, bytes, width, height, style);
}

pub fn decodeCodeBlockPayloadContinuousInferredIsoMqWithStyle(
    allocator: std.mem.Allocator,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    var scratch = DecodeBlockScratch.init(allocator);
    defer scratch.deinit();
    return decodeCodeBlockPayloadContinuousInferredIsoMqScratchWithStyle(&scratch, bitplanes, pass_count, bytes, width, height, style);
}

pub fn decodeCodeBlockSegmentCoefficientsPartial(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
) ![]i32 {
    return decodeCodeBlockSegmentCoefficientsPartialWithStyle(allocator, segment, width, height, .{});
}

pub fn decodeCodeBlockSegmentCoefficientsPartialWithStyle(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    var scratch = DecodeBlockScratch.init(allocator);
    defer scratch.deinit();
    return decodeCodeBlockSegmentCoefficientsBoundedScratch(&scratch, segment, width, height, .direct, false, style);
}

pub fn decodeCodeBlockSegmentCoefficientsContinuousPartial(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
) ![]i32 {
    return decodeCodeBlockSegmentCoefficientsContinuousPartialWithStyle(allocator, segment, width, height, .{});
}

pub fn decodeCodeBlockSegmentCoefficientsContinuousPartialWithStyle(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    var scratch = DecodeBlockScratch.init(allocator);
    defer scratch.deinit();
    return decodeCodeBlockSegmentCoefficientsBoundedScratch(&scratch, segment, width, height, .continuous, false, style);
}

pub fn decodeCodeBlockSegmentCoefficientsScratch(
    scratch: *DecodeBlockScratch,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
) ![]i32 {
    return decodeCodeBlockSegmentCoefficientsBoundedScratch(scratch, segment, width, height, .direct, true, .{});
}

pub fn decodeCodeBlockSegmentCoefficientsContinuousScratch(
    scratch: *DecodeBlockScratch,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
) ![]i32 {
    return decodeCodeBlockSegmentCoefficientsBoundedScratch(scratch, segment, width, height, .continuous, true, .{});
}

pub fn decodeCodeBlockSegmentCoefficientsIsoMq(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
) ![]i32 {
    return decodeCodeBlockSegmentCoefficientsIsoMqWithStyle(allocator, segment, width, height, .{});
}

pub fn decodeCodeBlockSegmentCoefficientsIsoMqWithStyle(
    allocator: std.mem.Allocator,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    var scratch = DecodeBlockScratch.init(allocator);
    defer scratch.deinit();
    return decodeCodeBlockSegmentCoefficientsIsoMqScratchWithStyle(&scratch, segment, width, height, style);
}

pub fn decodeCodeBlockSegmentCoefficientsIsoMqScratchWithStyle(
    scratch: *DecodeBlockScratch,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    // Continuous MQ decode is flush-independent: an ER-TERM tail decodes with
    // the standard byte-in padding, so standalone ERTERM is accepted here.
    // BYPASS payloads need the segment-aware readers.
    if (style.bypass) return EbcotError.InvalidBlock;
    if (width == 0 or height == 0) return EbcotError.InvalidBlock;
    const area = std.math.mul(usize, width, height) catch return EbcotError.InvalidBlock;
    if (area > max_codeblock_area) return EbcotError.InvalidBlock;
    if (segment.pass_count != segment.passes.len) return EbcotError.InvalidBlock;
    if (segment.byte_length != segment.bytes.len) return EbcotError.InvalidBlock;
    if (segment.bitplanes == 0) {
        if (segment.pass_count != 0 or segment.bytes.len != 0) return EbcotError.InvalidBlock;
        const out = try scratch.allocator.alloc(i32, area);
        @memset(out, 0);
        return out;
    }

    const expected_passes = expectedCodingPasses(segment.bitplanes);
    if (segment.pass_count != expected_passes) return EbcotError.InvalidBlock;

    try scratch.ensureBlockState(width, height, area);
    @memset(scratch.flags.items, 0);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
    if (comptime maintain_packed_t1_context_flags) @memset(scratch.packed_t1_flags.items, 0);
    @memset(scratch.coeffs.items, 0);

    var pass_index: u16 = 0;
    var bitplane_index = segment.bitplanes;
    while (bitplane_index > 0 and pass_index < segment.pass_count) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        clearFlag(scratch.flags.items, .became_significant);

        if (bitplane == segment.bitplanes - 1) {
            clearFlag(scratch.flags.items, .visited);
            try decodeCleanupPassIsoMq(scratch, segment.passes[pass_index], segment.bytes, bitplane, style);
            pass_index += 1;
            continue;
        }

        clearFlag(scratch.flags.items, .visited);
        try decodeSignificancePassIsoMq(scratch, segment.passes[pass_index], segment.bytes, bitplane, style);
        pass_index += 1;
        if (pass_index >= segment.pass_count) break;

        try decodeRefinementPassIsoMq(scratch, segment.passes[pass_index], segment.bytes, bitplane, style);
        pass_index += 1;
        if (pass_index >= segment.pass_count) break;

        try decodeCleanupPassIsoMq(scratch, segment.passes[pass_index], segment.bytes, bitplane, style);
        pass_index += 1;
    }
    if (pass_index != segment.pass_count) return EbcotError.InvalidBlock;

    return scratch.allocator.dupe(i32, scratch.coeffs.items);
}

pub fn decodeCodeBlockPayloadContinuousInferredScratch(
    scratch: *DecodeBlockScratch,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    width: usize,
    height: usize,
) ![]i32 {
    return decodeCodeBlockPayloadContinuousInferredScratchWithStyle(scratch, bitplanes, pass_count, bytes, width, height, .{});
}

pub fn decodeCodeBlockPayloadContinuousInferredScratchWithStyle(
    scratch: *DecodeBlockScratch,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    try validateImplementedStyle(style);
    if (style.terminate_all) return EbcotError.InvalidBlock;
    if (width == 0 or height == 0) return EbcotError.InvalidBlock;
    const area = std.math.mul(usize, width, height) catch return EbcotError.InvalidBlock;
    if (area > max_codeblock_area) return EbcotError.InvalidBlock;
    if (bitplanes == 0) {
        if (pass_count != 0 or bytes.len != 0) return EbcotError.InvalidBlock;
        const out = try scratch.allocator.alloc(i32, area);
        @memset(out, 0);
        return out;
    }

    const expected_passes = expectedCodingPasses(bitplanes);
    if (pass_count > expected_passes) return EbcotError.InvalidBlock;

    try scratch.ensureBlockState(width, height, area);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
    if (comptime maintain_packed_t1_context_flags) @memset(scratch.packed_t1_flags.items, 0);
    @memset(scratch.coeffs.items, 0);

    const max_symbols = try inferredMaxSymbols(area, pass_count, bitplanes, style);
    var decoder = try mq.Decoder.init(scratch.allocator, mq_context_count, bytes, max_symbols);
    defer decoder.deinit();

    var decoded_symbols: usize = 0;
    var pass_index: u16 = 0;
    var bitplane_index = bitplanes;
    while (bitplane_index > 0 and pass_index < pass_count) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        decodeClearNbfVisit(scratch);

        if (bitplane == bitplanes - 1) {
            resetInferredContinuousPassContexts(style, &decoder, pass_index);
            decoded_symbols = try std.math.add(usize, decoded_symbols, try decodeCleanupPassInferred(scratch, &decoder, bitplane, style));
            pass_index += 1;
            continue;
        }

        resetInferredContinuousPassContexts(style, &decoder, pass_index);
        decoded_symbols = try std.math.add(usize, decoded_symbols, try decodeSignificancePassInferred(scratch, &decoder, bitplane, style));
        pass_index += 1;
        if (pass_index >= pass_count) break;

        resetInferredContinuousPassContexts(style, &decoder, pass_index);
        decoded_symbols = try std.math.add(usize, decoded_symbols, try decodeRefinementPassInferred(scratch, &decoder, bitplane, style));
        pass_index += 1;
        if (pass_index >= pass_count) break;

        resetInferredContinuousPassContexts(style, &decoder, pass_index);
        decoded_symbols = try std.math.add(usize, decoded_symbols, try decodeCleanupPassInferred(scratch, &decoder, bitplane, style));
        pass_index += 1;
    }
    if (pass_index != pass_count or decoded_symbols == 0) return EbcotError.InvalidBlock;

    return scratch.allocator.dupe(i32, scratch.coeffs.items);
}

pub fn decodeCodeBlockPayloadContinuousInferredIsoMqScratchWithStyle(
    scratch: *DecodeBlockScratch,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    return decodeCodeBlockPayloadContinuousInferredIsoMqScratchWithStyleProfiled(scratch, bitplanes, pass_count, bytes, width, height, style, null);
}

pub fn decodeCodeBlockPayloadContinuousInferredIsoMqScratchWithStyleProfiled(
    scratch: *DecodeBlockScratch,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
    stats: ?*DecodePassStats,
) ![]i32 {
    const decoded = try decodeCodeBlockPayloadContinuousInferredIsoMqScratchWithStyleProfiledBorrowed(scratch, bitplanes, pass_count, bytes, width, height, style, stats);
    return scratch.allocator.dupe(i32, decoded);
}

/// Decode into `scratch.coeffs` and return a view that remains valid only until
/// the next call that reuses the same `DecodeBlockScratch`.
pub fn decodeCodeBlockPayloadContinuousInferredIsoMqScratchWithStyleProfiledBorrowed(
    scratch: *DecodeBlockScratch,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
    stats: ?*DecodePassStats,
) ![]const i32 {
    // Continuous MQ decode is flush-independent: an ER-TERM tail decodes with
    // the standard byte-in padding, so standalone ERTERM is accepted here.
    // BYPASS payloads need the segment-aware readers.
    if (style.bypass) return EbcotError.InvalidBlock;
    if (style.terminate_all) return EbcotError.InvalidBlock;
    if (width == 0 or height == 0) return EbcotError.InvalidBlock;
    const area = std.math.mul(usize, width, height) catch return EbcotError.InvalidBlock;
    if (area > max_codeblock_area) return EbcotError.InvalidBlock;
    if (bitplanes == 0) {
        if (pass_count != 0 or bytes.len != 0) return EbcotError.InvalidBlock;
        try scratch.ensureBlockState(width, height, area);
        @memset(scratch.coeffs.items, 0);
        return scratch.coeffs.items;
    }

    const expected_passes = expectedCodingPasses(bitplanes);
    if (pass_count > expected_passes) return EbcotError.InvalidBlock;

    try scratch.ensureBlockState(width, height, area);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
    if (comptime maintain_packed_t1_context_flags) @memset(scratch.packed_t1_flags.items, 0);
    @memset(scratch.coeffs.items, 0);

    const decoder = try scratch.isoMqDecoder(bytes);
    const profiling = stats != null;

    var decoded_symbols: usize = 0;
    var pass_index: u16 = 0;
    var bitplane_index = bitplanes;
    while (bitplane_index > 0 and pass_index < pass_count) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        decodeClearNbfVisit(scratch);

        if (bitplane == bitplanes - 1) {
            resetInferredContinuousPassContexts(style, decoder, pass_index);
            var pass_profile = profileMqStart(stats);
            const symbols = try decodeCleanupPassInferredProfiled(scratch, decoder, bitplane, style, &pass_profile, profiling);
            profileMqPass(stats, .cleanup, symbols, pass_profile);
            decoded_symbols = try std.math.add(usize, decoded_symbols, symbols);
            pass_index += 1;
            continue;
        }

        resetInferredContinuousPassContexts(style, decoder, pass_index);
        {
            var pass_profile = profileMqStart(stats);
            const symbols = try decodeSignificancePassInferredProfiled(scratch, decoder, bitplane, style, &pass_profile, profiling);
            profileMqPass(stats, .significance, symbols, pass_profile);
            decoded_symbols = try std.math.add(usize, decoded_symbols, symbols);
        }
        pass_index += 1;
        if (pass_index >= pass_count) break;

        resetInferredContinuousPassContexts(style, decoder, pass_index);
        {
            var pass_profile = profileMqStart(stats);
            const symbols = try decodeRefinementPassInferredProfiled(scratch, decoder, bitplane, style, &pass_profile, profiling);
            profileMqPass(stats, .refinement, symbols, pass_profile);
            decoded_symbols = try std.math.add(usize, decoded_symbols, symbols);
        }
        pass_index += 1;
        if (pass_index >= pass_count) break;

        resetInferredContinuousPassContexts(style, decoder, pass_index);
        {
            var pass_profile = profileMqStart(stats);
            const symbols = try decodeCleanupPassInferredProfiled(scratch, decoder, bitplane, style, &pass_profile, profiling);
            profileMqPass(stats, .cleanup, symbols, pass_profile);
            decoded_symbols = try std.math.add(usize, decoded_symbols, symbols);
        }
        pass_index += 1;
    }
    if (pass_index != pass_count or decoded_symbols == 0) return EbcotError.InvalidBlock;

    return scratch.coeffs.items;
}

pub const max_block_segments = 64;

/// Expected pass counts per terminated codeword segment in BYPASS mode:
/// ten MQ passes first, then raw (significance + refinement) pairs
/// alternating with single MQ cleanup passes.
pub fn bypassSegmentPassCounts(bitplanes: u8, pass_count: u16, out: *[max_block_segments]u16) !u8 {
    if (pass_count == 0) return 0;
    if (bitplanes < 5) {
        out[0] = pass_count;
        return 1;
    }
    var count: u8 = 0;
    var remaining = pass_count;
    out[count] = @min(remaining, 10);
    remaining -= out[count];
    count += 1;
    var next_raw = true;
    while (remaining > 0) {
        if (count >= max_block_segments) return EbcotError.InvalidBlock;
        const span: u16 = if (next_raw) @min(remaining, 2) else 1;
        out[count] = span;
        remaining -= span;
        count += 1;
        next_raw = !next_raw;
    }
    return count;
}

/// Strict decoder for BYPASS multi-segment code-block payloads. MQ contexts
/// persist across MQ segments; every segment is independently terminated and
/// its byte length comes from the packet header.
pub fn decodeCodeBlockPayloadBypassIsoMqScratchWithStyle(
    scratch: *DecodeBlockScratch,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    segment_lengths: []const u64,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    return decodeCodeBlockPayloadBypassIsoMqScratchWithStyleProfiled(scratch, bitplanes, pass_count, bytes, segment_lengths, width, height, style, null);
}

pub fn decodeCodeBlockPayloadBypassIsoMqScratchWithStyleProfiled(
    scratch: *DecodeBlockScratch,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    segment_lengths: []const u64,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
    stats: ?*DecodePassStats,
) ![]i32 {
    const decoded = try decodeCodeBlockPayloadBypassIsoMqScratchWithStyleProfiledBorrowed(scratch, bitplanes, pass_count, bytes, segment_lengths, width, height, style, stats);
    return scratch.allocator.dupe(i32, decoded);
}

/// Decode into `scratch.coeffs` and return a view that remains valid only until
/// the next call that reuses the same `DecodeBlockScratch`.
pub fn decodeCodeBlockPayloadBypassIsoMqScratchWithStyleProfiledBorrowed(
    scratch: *DecodeBlockScratch,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    segment_lengths: []const u64,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
    stats: ?*DecodePassStats,
) ![]const i32 {
    try validateImplementedStyleAllowBypass(style);
    if (style.bypass and style.terminate_all) {
        return decodeCodeBlockPayloadBypassTerminatedIsoMqScratchWithStyleProfiledBorrowed(scratch, bitplanes, pass_count, bytes, segment_lengths, width, height, style, stats);
    }
    if (!style.bypass or style.terminate_all) return EbcotError.InvalidBlock;
    if (width == 0 or height == 0) return EbcotError.InvalidBlock;
    const area = std.math.mul(usize, width, height) catch return EbcotError.InvalidBlock;
    if (area > max_codeblock_area) return EbcotError.InvalidBlock;
    if (bitplanes == 0) {
        if (pass_count != 0 or bytes.len != 0 or segment_lengths.len != 0) return EbcotError.InvalidBlock;
        try scratch.ensureBlockState(width, height, area);
        @memset(scratch.coeffs.items, 0);
        return scratch.coeffs.items;
    }

    const expected_passes = expectedCodingPasses(bitplanes);
    if (pass_count != expected_passes) return EbcotError.InvalidBlock;

    var seg_passes: [max_block_segments]u16 = undefined;
    const seg_count = try bypassSegmentPassCounts(bitplanes, pass_count, &seg_passes);
    if (segment_lengths.len != seg_count) return EbcotError.InvalidBlock;
    var total_bytes: u64 = 0;
    for (segment_lengths) |len| total_bytes = try std.math.add(u64, total_bytes, len);
    if (total_bytes != bytes.len) return EbcotError.InvalidBlock;

    try scratch.ensureBlockState(width, height, area);
    @memset(scratch.flags.items, 0);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
    if (comptime maintain_packed_t1_context_flags) @memset(scratch.packed_t1_flags.items, 0);
    @memset(scratch.coeffs.items, 0);

    var mq_decoder: ?*mq_iso.Decoder = null;
    var raw_reader = RawBitReader.init(&.{});
    const profiling = stats != null;

    var seg_index: usize = 0;
    var seg_offset: usize = 0;
    var seg_passes_left: u16 = 0;
    var seg_is_raw = false;

    var pass_index: u16 = 0;
    var bitplane_index = bitplanes;
    while (bitplane_index > 0 and pass_index < pass_count) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        decodeClearNbfVisit(scratch);

        const kinds: [3]PassKind = if (bitplane == bitplanes - 1)
            .{ .cleanup, .cleanup, .cleanup }
        else
            .{ .significance, .refinement, .cleanup };
        const passes_this_bitplane: u16 = if (bitplane == bitplanes - 1) 1 else 3;

        var kind_index: u16 = 0;
        while (kind_index < passes_this_bitplane and pass_index < pass_count) : (kind_index += 1) {
            const kind = kinds[kind_index];
            const is_raw = passIsRaw(style, bitplanes, bitplane, kind);

            if (seg_passes_left == 0) {
                if (seg_index >= seg_count) return EbcotError.InvalidBlock;
                const len = std.math.cast(usize, segment_lengths[seg_index]) orelse return EbcotError.InvalidBlock;
                const seg_end = try std.math.add(usize, seg_offset, len);
                if (seg_end > bytes.len) return EbcotError.InvalidBlock;
                const slice = bytes[seg_offset..seg_end];
                seg_is_raw = is_raw;
                if (is_raw) {
                    raw_reader = RawBitReader.init(slice);
                } else if (mq_decoder) |d| {
                    // Later MQ segments keep the adaptive contexts and only
                    // restart the codeword register.
                    d.reinitStream(slice);
                } else {
                    mq_decoder = try scratch.isoMqDecoder(slice);
                }
                seg_passes_left = seg_passes[seg_index];
                seg_offset = seg_end;
                seg_index += 1;
            }
            if (is_raw != seg_is_raw) return EbcotError.InvalidBlock;
            // RESET restarts the MQ contexts at every coding-pass boundary;
            // raw passes carry no contexts.
            if (!is_raw) resetInferredContinuousPassContexts(style, mq_decoder.?, pass_index);

            switch (kind) {
                .significance => {
                    if (is_raw) {
                        const pass_start = profileStart(stats);
                        const symbols = try decodeSignificancePassRaw(scratch, &raw_reader, bitplane, style);
                        profileRawPass(stats, .significance, symbols, pass_start);
                    } else {
                        var pass_profile = profileMqStart(stats);
                        const symbols = try decodeSignificancePassInferredProfiled(scratch, mq_decoder.?, bitplane, style, &pass_profile, profiling);
                        profileMqPass(stats, .significance, symbols, pass_profile);
                    }
                },
                .refinement => {
                    if (is_raw) {
                        const pass_start = profileStart(stats);
                        const symbols = try decodeRefinementPassRaw(scratch, &raw_reader, bitplane);
                        profileRawPass(stats, .refinement, symbols, pass_start);
                    } else {
                        var pass_profile = profileMqStart(stats);
                        const symbols = try decodeRefinementPassInferredProfiled(scratch, mq_decoder.?, bitplane, style, &pass_profile, profiling);
                        profileMqPass(stats, .refinement, symbols, pass_profile);
                    }
                },
                .cleanup => {
                    if (is_raw) return EbcotError.InvalidBlock;
                    var pass_profile = profileMqStart(stats);
                    const symbols = try decodeCleanupPassInferredProfiled(scratch, mq_decoder.?, bitplane, style, &pass_profile, profiling);
                    profileMqPass(stats, .cleanup, symbols, pass_profile);
                },
            }
            pass_index += 1;
            seg_passes_left -= 1;
        }
    }
    if (pass_index != pass_count or seg_index != seg_count or seg_passes_left != 0) {
        return EbcotError.InvalidBlock;
    }

    return scratch.coeffs.items;
}

/// BYPASS+TERMALL decode: packet headers provide one terminated segment length
/// per pass; each pass is decoded through the BYPASS raw/MQ choice.
pub fn decodeCodeBlockPayloadBypassTerminatedIsoMqScratchWithStyleProfiledBorrowed(
    scratch: *DecodeBlockScratch,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    segment_lengths: []const u64,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
    stats: ?*DecodePassStats,
) ![]const i32 {
    try validateImplementedStyleAllowBypass(style);
    if (!style.bypass or !style.terminate_all) return EbcotError.InvalidBlock;
    if (width == 0 or height == 0) return EbcotError.InvalidBlock;
    const area = std.math.mul(usize, width, height) catch return EbcotError.InvalidBlock;
    if (area > max_codeblock_area) return EbcotError.InvalidBlock;
    if (bitplanes == 0) {
        if (pass_count != 0 or bytes.len != 0 or segment_lengths.len != 0) return EbcotError.InvalidBlock;
        try scratch.ensureBlockState(width, height, area);
        @memset(scratch.coeffs.items, 0);
        return scratch.coeffs.items;
    }

    const expected_passes = expectedCodingPasses(bitplanes);
    if (pass_count != expected_passes) return EbcotError.InvalidBlock;
    if (segment_lengths.len != pass_count) return EbcotError.InvalidBlock;
    var total_bytes: u64 = 0;
    for (segment_lengths) |len| total_bytes = try std.math.add(u64, total_bytes, len);
    if (total_bytes != bytes.len) return EbcotError.InvalidBlock;

    try scratch.ensureBlockState(width, height, area);
    @memset(scratch.flags.items, 0);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
    if (comptime maintain_packed_t1_context_flags) @memset(scratch.packed_t1_flags.items, 0);
    @memset(scratch.coeffs.items, 0);

    var mq_decoder: ?*mq_iso.Decoder = null;
    var raw_reader = RawBitReader.init(&.{});
    const profiling = stats != null;

    var seg_offset: usize = 0;
    var seg_index: usize = 0;
    var pass_index: u16 = 0;
    var bitplane_index = bitplanes;
    while (bitplane_index > 0 and pass_index < pass_count) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        decodeClearNbfVisit(scratch);

        const kinds: [3]PassKind = if (bitplane == bitplanes - 1)
            .{ .cleanup, .cleanup, .cleanup }
        else
            .{ .significance, .refinement, .cleanup };
        const passes_this_bitplane: u16 = if (bitplane == bitplanes - 1) 1 else 3;

        var kind_index: u16 = 0;
        while (kind_index < passes_this_bitplane and pass_index < pass_count) : (kind_index += 1) {
            const kind = kinds[kind_index];
            const is_raw = passIsRaw(style, bitplanes, bitplane, kind);
            const len = std.math.cast(usize, segment_lengths[seg_index]) orelse return EbcotError.InvalidBlock;
            const seg_end = try std.math.add(usize, seg_offset, len);
            if (seg_end > bytes.len) return EbcotError.InvalidBlock;
            const slice = bytes[seg_offset..seg_end];
            if (is_raw) {
                raw_reader = RawBitReader.init(slice);
            } else if (mq_decoder) |d| {
                d.reinitStream(slice);
            } else {
                mq_decoder = try scratch.isoMqDecoder(slice);
            }
            seg_offset = seg_end;
            seg_index += 1;
            // RESET restarts the MQ contexts at every coding-pass boundary;
            // raw passes carry no contexts.
            if (!is_raw) resetInferredContinuousPassContexts(style, mq_decoder.?, pass_index);

            switch (kind) {
                .significance => {
                    if (is_raw) {
                        const pass_start = profileStart(stats);
                        const symbols = try decodeSignificancePassRaw(scratch, &raw_reader, bitplane, style);
                        profileRawPass(stats, .significance, symbols, pass_start);
                    } else {
                        var pass_profile = profileMqStart(stats);
                        const symbols = try decodeSignificancePassInferredProfiled(scratch, mq_decoder.?, bitplane, style, &pass_profile, profiling);
                        profileMqPass(stats, .significance, symbols, pass_profile);
                    }
                },
                .refinement => {
                    if (is_raw) {
                        const pass_start = profileStart(stats);
                        const symbols = try decodeRefinementPassRaw(scratch, &raw_reader, bitplane);
                        profileRawPass(stats, .refinement, symbols, pass_start);
                    } else {
                        var pass_profile = profileMqStart(stats);
                        const symbols = try decodeRefinementPassInferredProfiled(scratch, mq_decoder.?, bitplane, style, &pass_profile, profiling);
                        profileMqPass(stats, .refinement, symbols, pass_profile);
                    }
                },
                .cleanup => {
                    if (is_raw) return EbcotError.InvalidBlock;
                    var pass_profile = profileMqStart(stats);
                    const symbols = try decodeCleanupPassInferredProfiled(scratch, mq_decoder.?, bitplane, style, &pass_profile, profiling);
                    profileMqPass(stats, .cleanup, symbols, pass_profile);
                },
            }
            pass_index += 1;
        }
    }
    if (pass_index != pass_count or seg_index != segment_lengths.len) {
        return EbcotError.InvalidBlock;
    }

    return scratch.coeffs.items;
}

/// terminate_all decode (ISO 15444-1 D.4.5): every coding pass is its own
/// independently-terminated MQ codeword segment. Structurally this is the
/// bypass decoder with all segments MQ (never raw) and exactly one pass per
/// segment; the adaptive contexts carry across segments while each segment
/// restarts the codeword register. Inferred (re-derives symbols from geometry),
/// so it needs no per-pass symbol counts — only the packet-coded per-pass
/// lengths, which the terminate_all encoder records via its segment table.
pub fn decodeCodeBlockPayloadTerminatedIsoMqScratchWithStyleProfiledBorrowed(
    scratch: *DecodeBlockScratch,
    bitplanes: u8,
    pass_count: u16,
    bytes: []const u8,
    segment_lengths: []const u64,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
    stats: ?*DecodePassStats,
) ![]const i32 {
    // predictable_termination (ER-TERM flush) is permitted here with
    // terminate_all: each per-pass segment is a self-contained MQ stream that
    // the standard decoder reads back. RESET is also safe in this path because
    // the segment table gives every pass an explicit boundary where the
    // adaptive MQ contexts can be reset.
    if (style.bypass) return decodeCodeBlockPayloadBypassTerminatedIsoMqScratchWithStyleProfiledBorrowed(scratch, bitplanes, pass_count, bytes, segment_lengths, width, height, style, stats);
    if (!style.terminate_all or style.bypass) return EbcotError.InvalidBlock;
    if (width == 0 or height == 0) return EbcotError.InvalidBlock;
    const area = std.math.mul(usize, width, height) catch return EbcotError.InvalidBlock;
    if (area > max_codeblock_area) return EbcotError.InvalidBlock;
    if (bitplanes == 0) {
        if (pass_count != 0 or bytes.len != 0 or segment_lengths.len != 0) return EbcotError.InvalidBlock;
        try scratch.ensureBlockState(width, height, area);
        @memset(scratch.coeffs.items, 0);
        return scratch.coeffs.items;
    }

    const expected_passes = expectedCodingPasses(bitplanes);
    if (pass_count != expected_passes) return EbcotError.InvalidBlock;
    // One terminated segment per pass.
    if (segment_lengths.len != pass_count) return EbcotError.InvalidBlock;
    var total_bytes: u64 = 0;
    for (segment_lengths) |len| total_bytes = try std.math.add(u64, total_bytes, len);
    if (total_bytes != bytes.len) return EbcotError.InvalidBlock;

    try scratch.ensureBlockState(width, height, area);
    @memset(scratch.flags.items, 0);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
    if (comptime maintain_packed_t1_context_flags) @memset(scratch.packed_t1_flags.items, 0);
    @memset(scratch.coeffs.items, 0);

    var mq_decoder: ?*mq_iso.Decoder = null;
    const profiling = stats != null;

    var seg_offset: usize = 0;
    var seg_index: usize = 0;
    var pass_index: u16 = 0;
    var bitplane_index = bitplanes;
    while (bitplane_index > 0 and pass_index < pass_count) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        decodeClearNbfVisit(scratch);

        const kinds: [3]PassKind = if (bitplane == bitplanes - 1)
            .{ .cleanup, .cleanup, .cleanup }
        else
            .{ .significance, .refinement, .cleanup };
        const passes_this_bitplane: u16 = if (bitplane == bitplanes - 1) 1 else 3;

        var kind_index: u16 = 0;
        while (kind_index < passes_this_bitplane and pass_index < pass_count) : (kind_index += 1) {
            const kind = kinds[kind_index];

            const len = std.math.cast(usize, segment_lengths[seg_index]) orelse return EbcotError.InvalidBlock;
            const seg_end = try std.math.add(usize, seg_offset, len);
            if (seg_end > bytes.len) return EbcotError.InvalidBlock;
            const slice = bytes[seg_offset..seg_end];
            if (mq_decoder) |d| {
                // Keep the adaptive contexts, restart the codeword register.
                d.reinitStream(slice);
            } else {
                mq_decoder = try scratch.isoMqDecoder(slice);
            }
            if (style.reset_context and pass_index != 0) try mq_decoder.?.resetJpeg2000Contexts();
            seg_offset = seg_end;
            seg_index += 1;

            switch (kind) {
                .significance => {
                    var pass_profile = profileMqStart(stats);
                    const symbols = try decodeSignificancePassInferredProfiled(scratch, mq_decoder.?, bitplane, style, &pass_profile, profiling);
                    profileMqPass(stats, .significance, symbols, pass_profile);
                },
                .refinement => {
                    var pass_profile = profileMqStart(stats);
                    const symbols = try decodeRefinementPassInferredProfiled(scratch, mq_decoder.?, bitplane, style, &pass_profile, profiling);
                    profileMqPass(stats, .refinement, symbols, pass_profile);
                },
                .cleanup => {
                    var pass_profile = profileMqStart(stats);
                    const symbols = try decodeCleanupPassInferredProfiled(scratch, mq_decoder.?, bitplane, style, &pass_profile, profiling);
                    profileMqPass(stats, .cleanup, symbols, pass_profile);
                },
            }
            pass_index += 1;
        }
    }
    if (pass_index != pass_count or seg_index != segment_lengths.len) {
        return EbcotError.InvalidBlock;
    }

    return scratch.coeffs.items;
}

fn decodeSignificancePassRaw(
    scratch: *DecodeBlockScratch,
    reader: *RawBitReader,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;
    var stripe_y: usize = 0;
    while (stripe_y < scratch.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), scratch.height - stripe_y);
        var x: usize = 0;
        while (x < scratch.width) {
            const x_end = @min(x + significant_word_bits, scratch.width);
            if (!stripeHasSignificanceDecodeRange(scratch, stripe_y, stripe_height, x, x_end)) {
                x = x_end;
                continue;
            }
            while (x < x_end) : (x += 1) {
                var p = nbfIndex(nbs, x, stripe_y);
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    const y = stripe_y + dy;
                    const sample_flags_index = p;
                    p += nbs;
                    if (!decodeT1SignificanceCandidate(scratch, x, y, flags[sample_flags_index], style)) continue;
                    flags[sample_flags_index] |= nbf_visit;
                    decodeMarkPackedT1Visited(scratch, x, y);
                    symbol_count += 1;
                    if (reader.readBit()) {
                        symbol_count += 1;
                        const negative = reader.readBit();
                        markDecodedSignificantNbf(scratch, x, y, bitplane, negative);
                    }
                }
            }
        }
    }
    return symbol_count;
}

fn decodeRefinementPassRaw(
    scratch: *DecodeBlockScratch,
    reader: *RawBitReader,
    bitplane: u8,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;
    var stripe_y: usize = 0;
    while (stripe_y < scratch.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), scratch.height - stripe_y);
        var x: usize = 0;
        while (x < scratch.width) {
            const x_end = @min(x + significant_word_bits, scratch.width);
            if (!stripeRowsSignificantDecodeRange(scratch, stripe_y, stripe_height, x, x_end)) {
                x = x_end;
                continue;
            }
            while (x < x_end) : (x += 1) {
                var p = nbfIndex(nbs, x, stripe_y);
                var coeff_index = localIndex(scratch.width, x, stripe_y);
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    const sample_flags_index = p;
                    const sample_coeff_index = coeff_index;
                    p += nbs;
                    coeff_index += scratch.width;
                    if (!decodeT1RefinementCandidate(scratch, x, stripe_y + dy, flags[sample_flags_index])) continue;
                    const bit = reader.readBit();
                    symbol_count += 1;
                    flags[sample_flags_index] |= nbf_refine;
                    decodeMarkPackedT1Refined(scratch, x, stripe_y + dy);
                    refineMagnitude(scratch, sample_coeff_index, bitplane, bit);
                }
            }
        }
    }
    return symbol_count;
}

pub fn decodeCodeBlockSegmentCoefficientsPartialScratch(
    scratch: *DecodeBlockScratch,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
) ![]i32 {
    return decodeCodeBlockSegmentCoefficientsPartialScratchWithStyle(scratch, segment, width, height, .{});
}

pub fn decodeCodeBlockSegmentCoefficientsPartialScratchWithStyle(
    scratch: *DecodeBlockScratch,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    return decodeCodeBlockSegmentCoefficientsBoundedScratch(scratch, segment, width, height, .direct, false, style);
}

pub fn decodeCodeBlockSegmentCoefficientsContinuousPartialScratch(
    scratch: *DecodeBlockScratch,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
) ![]i32 {
    return decodeCodeBlockSegmentCoefficientsContinuousPartialScratchWithStyle(scratch, segment, width, height, .{});
}

pub fn decodeCodeBlockSegmentCoefficientsContinuousPartialScratchWithStyle(
    scratch: *DecodeBlockScratch,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
    style: CodeBlockStyle,
) ![]i32 {
    return decodeCodeBlockSegmentCoefficientsBoundedScratch(scratch, segment, width, height, .continuous, false, style);
}

const SegmentMqMode = enum {
    direct,
    continuous,
};

fn decodeCodeBlockSegmentCoefficientsBoundedScratch(
    scratch: *DecodeBlockScratch,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
    mode: SegmentMqMode,
    require_complete: bool,
    style: CodeBlockStyle,
) ![]i32 {
    try validateImplementedStyle(style);
    if (width == 0 or height == 0) return EbcotError.InvalidBlock;
    const area = std.math.mul(usize, width, height) catch return EbcotError.InvalidBlock;
    if (area > max_codeblock_area) return EbcotError.InvalidBlock;
    if (segment.pass_count != segment.passes.len) return EbcotError.InvalidBlock;
    if (segment.byte_length != segment.bytes.len) return EbcotError.InvalidBlock;
    if (segment.bitplanes == 0) {
        if (segment.pass_count != 0 or segment.bytes.len != 0) return EbcotError.InvalidBlock;
        const out = try scratch.allocator.alloc(i32, area);
        @memset(out, 0);
        return out;
    }

    try scratch.ensureBlockState(width, height, area);
    @memset(scratch.flags.items, 0);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
    if (comptime maintain_packed_t1_context_flags) @memset(scratch.packed_t1_flags.items, 0);
    @memset(scratch.coeffs.items, 0);

    const expected_passes = expectedCodingPasses(segment.bitplanes);
    if (require_complete) {
        if (segment.pass_count != expected_passes) return EbcotError.InvalidBlock;
    } else if (segment.pass_count > expected_passes) {
        return EbcotError.InvalidBlock;
    }

    if (segment.pass_count == 0) {
        const out = try scratch.allocator.dupe(i32, scratch.coeffs.items);
        return out;
    }

    var total_symbols: usize = 0;
    for (segment.passes) |pass| total_symbols += pass.symbol_count;
    const effective_mode: SegmentMqMode = if (mode == .continuous and style.terminate_all) .direct else mode;
    const carry_direct_contexts = style.terminate_all;
    var continuous_decoder: mq.Decoder = undefined;
    var continuous_decoder_active = false;
    defer if (continuous_decoder_active) continuous_decoder.deinit();
    if (effective_mode == .continuous) {
        continuous_decoder = try mq.Decoder.init(scratch.allocator, mq_context_count, segment.bytes, total_symbols);
        continuous_decoder_active = true;
    }
    var terminated_contexts: [mq_context_count]mq.ContextSnapshot = [_]mq.ContextSnapshot{.{}} ** mq_context_count;

    var pass_index: u16 = 0;
    var bitplane_index = segment.bitplanes;
    while (bitplane_index > 0 and pass_index < segment.pass_count) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        clearFlag(scratch.flags.items, .became_significant);

        if (bitplane == segment.bitplanes - 1) {
            clearFlag(scratch.flags.items, .visited);
            resetContinuousPassContexts(effective_mode, style, &continuous_decoder, pass_index);
            switch (effective_mode) {
                .direct => if (carry_direct_contexts)
                    try decodeCleanupPassWithContexts(scratch, segment.passes[pass_index], segment.bytes, bitplane, style, &terminated_contexts, pass_index)
                else
                    try decodeCleanupPass(scratch, segment.passes[pass_index], segment.bytes, bitplane, style),
                .continuous => try decodeCleanupPassContinuous(scratch, segment.passes[pass_index], segment.bytes, &continuous_decoder, bitplane, style),
            }
            pass_index += 1;
            continue;
        }

        clearFlag(scratch.flags.items, .visited);
        resetContinuousPassContexts(effective_mode, style, &continuous_decoder, pass_index);
        switch (effective_mode) {
            .direct => if (carry_direct_contexts)
                try decodeSignificancePassWithContexts(scratch, segment.passes[pass_index], segment.bytes, bitplane, style, &terminated_contexts, pass_index)
            else
                try decodeSignificancePass(scratch, segment.passes[pass_index], segment.bytes, bitplane, style),
            .continuous => try decodeSignificancePassContinuous(scratch, segment.passes[pass_index], segment.bytes, &continuous_decoder, bitplane, style),
        }
        pass_index += 1;
        if (pass_index >= segment.pass_count) break;

        resetContinuousPassContexts(effective_mode, style, &continuous_decoder, pass_index);
        switch (effective_mode) {
            .direct => if (carry_direct_contexts)
                try decodeRefinementPassWithContexts(scratch, segment.passes[pass_index], segment.bytes, bitplane, style, &terminated_contexts, pass_index)
            else
                try decodeRefinementPass(scratch, segment.passes[pass_index], segment.bytes, bitplane, style),
            .continuous => try decodeRefinementPassContinuous(scratch, segment.passes[pass_index], segment.bytes, &continuous_decoder, bitplane, style),
        }
        pass_index += 1;
        if (pass_index >= segment.pass_count) break;

        resetContinuousPassContexts(effective_mode, style, &continuous_decoder, pass_index);
        switch (effective_mode) {
            .direct => if (carry_direct_contexts)
                try decodeCleanupPassWithContexts(scratch, segment.passes[pass_index], segment.bytes, bitplane, style, &terminated_contexts, pass_index)
            else
                try decodeCleanupPass(scratch, segment.passes[pass_index], segment.bytes, bitplane, style),
            .continuous => try decodeCleanupPassContinuous(scratch, segment.passes[pass_index], segment.bytes, &continuous_decoder, bitplane, style),
        }
        pass_index += 1;
    }
    if (pass_index != segment.pass_count) return EbcotError.InvalidBlock;
    if (effective_mode == .continuous and continuous_decoder.remaining != 0) return EbcotError.InvalidBlock;

    const out = try scratch.allocator.dupe(i32, scratch.coeffs.items);
    return out;
}

fn resetContinuousPassContexts(
    mode: SegmentMqMode,
    style: CodeBlockStyle,
    decoder: *mq.Decoder,
    pass_index: u16,
) void {
    if (mode == .continuous and style.reset_context and pass_index != 0) decoder.resetContexts();
}

fn resetInferredContinuousPassContexts(style: CodeBlockStyle, decoder: anytype, pass_index: u16) void {
    // D.4 RESET restores the default JPEG2000 initial states (Table D.7:
    // UNIFORM=46, RUN-LENGTH=3, first significance context=4), matching the
    // ISO encoder's per-pass resetJpeg2000Contexts and OpenJPEG's resetstates.
    // The legacy decoder pairs the legacy encoder's all-default resetContexts.
    if (style.reset_context and pass_index != 0) {
        const DecoderType = @typeInfo(@TypeOf(decoder)).pointer.child;
        if (@hasDecl(DecoderType, "resetJpeg2000Contexts"))
            decoder.resetJpeg2000Contexts() catch unreachable
        else
            decoder.resetContexts();
    }
}

fn expectedCodingPasses(bitplanes: u8) u16 {
    if (bitplanes == 0) return 0;
    var expected_passes: u16 = 1;
    if (bitplanes > 1) expected_passes += @as(u16, bitplanes - 1) * 3;
    return expected_passes;
}

fn inferredMaxSymbols(area: usize, pass_count: u16, bitplanes: u8, style: CodeBlockStyle) !usize {
    const pass_symbols = try std.math.mul(usize, area, 2);
    var max_symbols = try std.math.mul(usize, pass_symbols, @intCast(pass_count));
    if (style.segmentation_symbols) {
        max_symbols = try std.math.add(usize, max_symbols, @as(usize, bitplanes) * segmentation_symbol_bits.len);
    }
    return max_symbols;
}

fn emitSignificancePass(
    allocator: std.mem.Allocator,
    passes: *std.ArrayList(Pass),
    symbols: *std.ArrayList(Symbol),
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    pass_index: u16,
    significant: []bool,
    visited: []bool,
    became_significant: []bool,
    style: CodeBlockStyle,
    raw_signs: bool,
) !void {
    const first_symbol = symbols.items.len;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (significant[index] or neighborSignificance(significant, rect.width, rect.height, pos.x, pos.y, style) == 0) continue;
        visited[index] = true;
        try emitZeroCoding(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index, significant, style);
        if (isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane)) {
            try emitSign(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index, significant, style, raw_signs);
            significant[index] = true;
            became_significant[index] = true;
        }
    }

    try appendPass(allocator, passes, .significance, bitplane, first_symbol, symbols.items.len);
}

fn decodeSignificancePass(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    try validatePassPayload(pass, bytes, .significance, bitplane);
    var decoder = try mq.Decoder.init(scratch.allocator, mq_context_count, bytes[pass.byte_offset..][0..pass.byte_length], pass.symbol_count);
    defer decoder.deinit();
    try decodeSignificancePassSymbols(scratch, pass, &decoder, bitplane, style);
}

fn decodeSignificancePassIsoMq(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    try validatePassPayload(pass, bytes, .significance, bitplane);
    var decoder = try isoPassDecoder(scratch, pass, bytes);
    defer decoder.deinit();
    try decodeSignificancePassSymbols(scratch, pass, &decoder, bitplane, style);
}

fn decodeSignificancePassWithContexts(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    bitplane: u8,
    style: CodeBlockStyle,
    contexts: []mq.ContextSnapshot,
    pass_index: u16,
) !void {
    var decoder = try passDecoderWithContexts(scratch, pass, bytes, contexts, style, pass_index);
    defer decoder.deinit();
    try decodeSignificancePassSymbols(scratch, pass, &decoder, bitplane, style);
    try decoder.exportContexts(contexts);
}

fn decodeSignificancePassContinuous(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    decoder: *mq.Decoder,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    try validatePassPayload(pass, bytes, .significance, bitplane);
    try decodeSignificancePassSymbols(scratch, pass, decoder, bitplane, style);
}

fn decodeSignificancePassSymbols(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    decoder: anytype,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    var symbol_count: usize = 0;

    var it = ScanIterator.init(scratch.width, scratch.height);
    while (it.next()) |pos| {
        const index = localIndex(scratch.width, pos.x, pos.y);
        const neighbor_count = neighborSignificanceRowsDecode(scratch, pos.x, pos.y, style);
        if (hasSignificantRowDecode(scratch, pos.x, pos.y) or neighbor_count == 0) continue;
        setFlag(scratch.flags.items, index, .visited);
        const bit = try mqRead(decoder, mqContextIndex(zeroContextRowsDecode(scratch, pos.x, pos.y, style)));
        symbol_count += 1;
        if (bit) {
            const sign = signCodingRowsDecode(scratch, pos.x, pos.y, style);
            const sign_bit = try mqRead(decoder, mqContextIndex(sign.context));
            symbol_count += 1;
            const negative = sign_bit != sign.predicted_negative;
            markDecodedSignificant(scratch, pos.x, pos.y, bitplane, negative);
        }
    }

    if (symbol_count != pass.symbol_count) return EbcotError.InvalidBlock;
}

fn stripeHasSignificanceDecode(scratch: *const DecodeBlockScratch, stripe_y: usize, stripe_height: usize) bool {
    const first_row = if (stripe_y == 0) 0 else stripe_y - 1;
    const last_row = @min(scratch.height - 1, stripe_y + stripe_height);
    var acc: u64 = 0;
    var row = first_row;
    while (row <= last_row) : (row += 1) {
        const base = row * scratch.row_words;
        for (scratch.significant_words.items[base..][0..scratch.row_words]) |word| acc |= word;
    }
    return acc != 0;
}

fn stripeHasSignificanceDecodeRange(
    scratch: *const DecodeBlockScratch,
    stripe_y: usize,
    stripe_height: usize,
    x_begin: usize,
    x_end: usize,
) bool {
    return stripeHasSignificanceRange(
        scratch.significant_words.items,
        scratch.row_words,
        scratch.width,
        scratch.height,
        stripe_y,
        stripe_height,
        x_begin,
        x_end,
    );
}

fn stripeRowsSignificantDecode(scratch: *const DecodeBlockScratch, stripe_y: usize, stripe_height: usize) bool {
    var acc: u64 = 0;
    var row = stripe_y;
    while (row < stripe_y + stripe_height) : (row += 1) {
        const base = row * scratch.row_words;
        for (scratch.significant_words.items[base..][0..scratch.row_words]) |word| acc |= word;
    }
    return acc != 0;
}

fn stripeRowsSignificantDecodeRange(
    scratch: *const DecodeBlockScratch,
    stripe_y: usize,
    stripe_height: usize,
    x_begin: usize,
    x_end: usize,
) bool {
    return stripeRowsSignificantRange(
        scratch.significant_words.items,
        scratch.row_words,
        scratch.width,
        stripe_y,
        stripe_height,
        x_begin,
        x_end,
    );
}

fn decodeSignificancePassInferred(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    if (comptime !maintain_packed_t1_context_flags) {
        if (!style.vertical_causal) {
            return decodeSignificancePassInferredPlain(scratch, decoder, bitplane, style.band_kind);
        }
    }

    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;

    var stripe_y: usize = 0;
    while (stripe_y < scratch.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), scratch.height - stripe_y);
        // Mirrors the encoder stripe skip: an all-zero neighborhood window
        // means the significance pass cannot code anything in this stripe.
        if (!stripeHasSignificanceDecode(scratch, stripe_y, stripe_height)) continue;
        var x: usize = 0;
        while (x < scratch.width) {
            const x_end = @min(x + significant_word_bits, scratch.width);
            if (!stripeHasSignificanceDecodeRange(scratch, stripe_y, stripe_height, x, x_end)) {
                x = x_end;
                continue;
            }
            while (x < x_end) : (x += 1) {
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    const y = stripe_y + dy;
                    const p = nbfIndex(nbs, x, y);
                    const sample_flags = flags[p];
                    if (!decodeT1SignificanceCandidate(scratch, x, y, sample_flags, style)) continue;
                    flags[p] |= nbf_visit;
                    decodeMarkPackedT1Visited(scratch, x, y);
                    const zero_context = decodeT1ZeroContext(scratch, x, y, sample_flags, style);
                    const bit = try mqRead(decoder, mqContextIndex(zero_context));
                    symbol_count += 1;
                    if (bit) {
                        const sign = decodeT1SignCoding(scratch, x, y, sample_flags, style);
                        const sign_bit = try mqRead(decoder, mqContextIndex(sign.context));
                        symbol_count += 1;
                        const negative = sign_bit != sign.predicted_negative;
                        markDecodedSignificantNbf(scratch, x, y, bitplane, negative);
                    }
                }
            }
        }
    }

    return symbol_count;
}

fn decodeSignificancePassInferredPlain(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    bitplane: u8,
    band_kind: subband.Kind,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;

    var stripe_y: usize = 0;
    while (stripe_y < scratch.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), scratch.height - stripe_y);
        if (!stripeHasSignificanceDecode(scratch, stripe_y, stripe_height)) continue;
        var x: usize = 0;
        while (x < scratch.width) {
            const x_end = @min(x + significant_word_bits, scratch.width);
            if (!stripeHasSignificanceDecodeRange(scratch, stripe_y, stripe_height, x, x_end)) {
                x = x_end;
                continue;
            }
            const band_index = @intFromEnum(band_kind);
            while (x < x_end) : (x += 1) {
                // Strength-reduce the per-sample nbf index down the stripe
                // column (mirrors decodeRefinementPassRaw): p advances by nbs.
                var p = nbfIndex(nbs, x, stripe_y);
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    const sample_flags_index = p;
                    p += nbs;
                    const sample_flags = flags[sample_flags_index];
                    if ((sample_flags & (nbf_sig_self | nbf_visit)) != 0) continue;
                    const pattern = sample_flags & nbf_sig8;
                    if (pattern == 0) continue;
                    flags[sample_flags_index] |= nbf_visit;
                    const zero_context = nbf_zc_lut[band_index][pattern];
                    const bit = try mqRead(decoder, mqContextIndex(zero_context));
                    symbol_count += 1;
                    if (bit) {
                        const sign = nbf_sc_lut[nbfScIndex(sample_flags)];
                        const sign_bit = try mqRead(decoder, mqContextIndex(sign.context));
                        symbol_count += 1;
                        const negative = sign_bit != sign.predicted_negative;
                        markDecodedSignificantNbf(scratch, x, stripe_y + dy, bitplane, negative);
                    }
                }
            }
        }
    }

    return symbol_count;
}

fn emitRefinementPass(
    allocator: std.mem.Allocator,
    passes: *std.ArrayList(Pass),
    symbols: *std.ArrayList(Symbol),
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    pass_index: u16,
    significant: []const bool,
    became_significant: []const bool,
    refined: []bool,
    style: CodeBlockStyle,
) !void {
    const first_symbol = symbols.items.len;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (!significant[index] or became_significant[index]) continue;
        try symbols.append(allocator, .{
            .pass_index = pass_index,
            .kind = .magnitude_refinement,
            .context = refinementContext(refined[index], neighborSignificance(significant, rect.width, rect.height, pos.x, pos.y, style)),
            .bit = isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane),
            .x = pos.x,
            .y = pos.y,
            .magnitude_bitplane = bitplane,
        });
        refined[index] = true;
    }

    try appendPass(allocator, passes, .refinement, bitplane, first_symbol, symbols.items.len);
}

fn decodeRefinementPass(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    try validatePassPayload(pass, bytes, .refinement, bitplane);
    var decoder = try mq.Decoder.init(scratch.allocator, mq_context_count, bytes[pass.byte_offset..][0..pass.byte_length], pass.symbol_count);
    defer decoder.deinit();
    try decodeRefinementPassSymbols(scratch, pass, &decoder, bitplane, style);
}

fn decodeRefinementPassIsoMq(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    try validatePassPayload(pass, bytes, .refinement, bitplane);
    var decoder = try isoPassDecoder(scratch, pass, bytes);
    defer decoder.deinit();
    try decodeRefinementPassSymbols(scratch, pass, &decoder, bitplane, style);
}

fn decodeRefinementPassWithContexts(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    bitplane: u8,
    style: CodeBlockStyle,
    contexts: []mq.ContextSnapshot,
    pass_index: u16,
) !void {
    var decoder = try passDecoderWithContexts(scratch, pass, bytes, contexts, style, pass_index);
    defer decoder.deinit();
    try decodeRefinementPassSymbols(scratch, pass, &decoder, bitplane, style);
    try decoder.exportContexts(contexts);
}

fn decodeRefinementPassContinuous(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    decoder: *mq.Decoder,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    try validatePassPayload(pass, bytes, .refinement, bitplane);
    try decodeRefinementPassSymbols(scratch, pass, decoder, bitplane, style);
}

fn decodeRefinementPassSymbols(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    decoder: anytype,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    var symbol_count: usize = 0;

    var it = ScanIterator.init(scratch.width, scratch.height);
    while (it.next()) |pos| {
        const index = localIndex(scratch.width, pos.x, pos.y);
        if (!hasSignificantRowDecode(scratch, pos.x, pos.y) or hasFlag(scratch.flags.items, index, .became_significant)) continue;
        const bit = try mqRead(decoder, mqContextIndex(refinementContext(hasFlag(scratch.flags.items, index, .refined), neighborSignificanceRowsDecode(scratch, pos.x, pos.y, style))));
        symbol_count += 1;
        setFlag(scratch.flags.items, index, .refined);
        refineMagnitude(scratch, index, bitplane, bit);
    }

    if (symbol_count != pass.symbol_count) return EbcotError.InvalidBlock;
}

fn decodeRefinementPassInferred(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    if (comptime !maintain_packed_t1_context_flags) {
        if (!style.vertical_causal) {
            return decodeRefinementPassInferredPlain(scratch, decoder, bitplane);
        }
    }

    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;

    var stripe_y: usize = 0;
    while (stripe_y < scratch.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), scratch.height - stripe_y);
        // Nothing significant inside the stripe rows means nothing refines.
        if (!stripeRowsSignificantDecode(scratch, stripe_y, stripe_height)) continue;
        var x: usize = 0;
        while (x < scratch.width) {
            const x_end = @min(x + significant_word_bits, scratch.width);
            if (!stripeRowsSignificantDecodeRange(scratch, stripe_y, stripe_height, x, x_end)) {
                x = x_end;
                continue;
            }
            while (x < x_end) : (x += 1) {
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    const y = stripe_y + dy;
                    const p = nbfIndex(nbs, x, y);
                    const decision = decodeT1RefinementDecision(scratch, x, y, flags[p], style);
                    if (!decision.candidate) continue;
                    const bit = try mqRead(decoder, mqContextIndex(decision.context));
                    symbol_count += 1;
                    flags[p] |= nbf_refine;
                    decodeMarkPackedT1Refined(scratch, x, y);
                    refineMagnitude(scratch, localIndex(scratch.width, x, y), bitplane, bit);
                }
            }
        }
    }

    return symbol_count;
}

fn decodeRefinementPassInferredPlain(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    bitplane: u8,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;

    var stripe_y: usize = 0;
    while (stripe_y < scratch.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), scratch.height - stripe_y);
        if (!stripeRowsSignificantDecode(scratch, stripe_y, stripe_height)) continue;
        var x: usize = 0;
        while (x < scratch.width) {
            const x_end = @min(x + significant_word_bits, scratch.width);
            if (!stripeRowsSignificantDecodeRange(scratch, stripe_y, stripe_height, x, x_end)) {
                x = x_end;
                continue;
            }
            while (x < x_end) : (x += 1) {
                // Strength-reduce both index streams down the stripe column.
                var p = nbfIndex(nbs, x, stripe_y);
                var coeff_index = localIndex(scratch.width, x, stripe_y);
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    const sample_flags_index = p;
                    const sample_coeff_index = coeff_index;
                    p += nbs;
                    coeff_index += scratch.width;
                    const sample_flags = flags[sample_flags_index];
                    if ((sample_flags & nbf_sig_self) == 0 or (sample_flags & nbf_visit) != 0) continue;
                    const context = refinementContext((sample_flags & nbf_refine) != 0, @intCast(@popCount(sample_flags & nbf_sig8)));
                    const bit = try mqRead(decoder, mqContextIndex(context));
                    symbol_count += 1;
                    flags[sample_flags_index] |= nbf_refine;
                    refineMagnitude(scratch, sample_coeff_index, bitplane, bit);
                }
            }
        }
    }

    return symbol_count;
}

fn emitCleanupPass(
    allocator: std.mem.Allocator,
    passes: *std.ArrayList(Pass),
    symbols: *std.ArrayList(Symbol),
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    pass_index: u16,
    significant: []bool,
    visited: []const bool,
    became_significant: []bool,
    style: CodeBlockStyle,
) !void {
    const first_symbol = symbols.items.len;

    var stripe_y: usize = 0;
    while (stripe_y < rect.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), rect.height - stripe_y);
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            if (stripe_height == 4 and canUseCleanupRunStripe(significant, visited, rect.width, rect.height, x, stripe_y, style)) {
                const runlen = cleanupRunLength(plane, stride, rect, x, stripe_y, bitplane);
                try emitCleanupRunSymbols(allocator, symbols, pass_index, bitplane, x, stripe_y, runlen);
                if (runlen == 4) continue;

                const y = stripe_y + runlen;
                try emitSign(allocator, symbols, plane, stride, rect, .{ .x = x, .y = y }, bitplane, pass_index, significant, style, false);
                significant[localIndex(rect.width, x, y)] = true;
                became_significant[localIndex(rect.width, x, y)] = true;

                var dy = runlen + 1;
                while (dy < 4) : (dy += 1) {
                    try emitCleanupSample(allocator, symbols, plane, stride, rect, .{ .x = x, .y = stripe_y + dy }, bitplane, pass_index, significant, visited, became_significant, style);
                }
            } else {
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    try emitCleanupSample(allocator, symbols, plane, stride, rect, .{ .x = x, .y = stripe_y + dy }, bitplane, pass_index, significant, visited, became_significant, style);
                }
            }
        }
    }

    if (style.segmentation_symbols) {
        try emitSegmentationSymbols(allocator, symbols, pass_index, bitplane);
    }

    try appendPass(allocator, passes, .cleanup, bitplane, first_symbol, symbols.items.len);
}

fn decodeCleanupPass(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    try validatePassPayload(pass, bytes, .cleanup, bitplane);
    var decoder = try mq.Decoder.init(scratch.allocator, mq_context_count, bytes[pass.byte_offset..][0..pass.byte_length], pass.symbol_count);
    defer decoder.deinit();
    try decodeCleanupPassSymbols(scratch, pass, &decoder, bitplane, style);
}

fn decodeCleanupPassIsoMq(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    try validatePassPayload(pass, bytes, .cleanup, bitplane);
    var decoder = try isoPassDecoder(scratch, pass, bytes);
    defer decoder.deinit();
    try decodeCleanupPassSymbols(scratch, pass, &decoder, bitplane, style);
}

fn decodeCleanupPassWithContexts(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    bitplane: u8,
    style: CodeBlockStyle,
    contexts: []mq.ContextSnapshot,
    pass_index: u16,
) !void {
    var decoder = try passDecoderWithContexts(scratch, pass, bytes, contexts, style, pass_index);
    defer decoder.deinit();
    try decodeCleanupPassSymbols(scratch, pass, &decoder, bitplane, style);
    try decoder.exportContexts(contexts);
}

fn decodeCleanupPassContinuous(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    decoder: *mq.Decoder,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    try validatePassPayload(pass, bytes, .cleanup, bitplane);
    try decodeCleanupPassSymbols(scratch, pass, decoder, bitplane, style);
}

fn decodeCleanupPassSymbols(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    decoder: anytype,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    var symbol_count: usize = 0;

    var stripe_y: usize = 0;
    while (stripe_y < scratch.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), scratch.height - stripe_y);
        var x: usize = 0;
        while (x < scratch.width) : (x += 1) {
            if (stripe_height == 4 and canUseCleanupRunStripeDecode(scratch, x, stripe_y, style)) {
                const agg = try mqRead(decoder, mqContextIndex(.cleanup_aggregation));
                symbol_count += 1;
                if (!agg) continue;

                const runlen = try readCleanupRunLength(decoder);
                symbol_count += 2;
                if (runlen >= 4) return EbcotError.InvalidBlock;

                const y = stripe_y + runlen;
                const sign = signCodingRowsDecode(scratch, x, y, style);
                const sign_bit = try mqRead(decoder, mqContextIndex(sign.context));
                symbol_count += 1;
                const negative = sign_bit != sign.predicted_negative;
                markDecodedSignificant(scratch, x, y, bitplane, negative);

                symbol_count += try decodeCleanupSampleRange(scratch, decoder, x, stripe_y, runlen + 1, 4, bitplane, style);
            } else {
                symbol_count += try decodeCleanupSampleRange(scratch, decoder, x, stripe_y, 0, stripe_height, bitplane, style);
            }
        }
    }

    if (style.segmentation_symbols) {
        symbol_count += try readSegmentationSymbols(decoder);
    }

    if (symbol_count != pass.symbol_count) return EbcotError.InvalidBlock;
}

fn decodeCleanupPassInferred(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    if (comptime !maintain_packed_t1_context_flags) {
        if (!style.vertical_causal) {
            return decodeCleanupPassInferredPlain(scratch, decoder, bitplane, style.band_kind, style.segmentation_symbols);
        }
    }

    var symbol_count: usize = 0;

    var stripe_y: usize = 0;
    while (stripe_y < scratch.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), scratch.height - stripe_y);
        var x: usize = 0;
        while (x < scratch.width) : (x += 1) {
            if (stripe_height == 4 and decodeCanUseRunStripeFast(scratch, x, stripe_y, style)) {
                const agg = try mqRead(decoder, mqContextIndex(.cleanup_aggregation));
                symbol_count += 1;
                if (!agg) continue;

                const runlen = try readCleanupRunLength(decoder);
                symbol_count += 2;
                if (runlen >= 4) return EbcotError.InvalidBlock;

                {
                    const y = stripe_y + runlen;
                    const decision = decodeT1Decision(scratch, x, y, style);
                    const sign_bit = try mqRead(decoder, mqContextIndex(decision.sign.context));
                    symbol_count += 1;
                    const negative = sign_bit != decision.sign.predicted_negative;
                    markDecodedSignificantNbf(scratch, x, y, bitplane, negative);
                }

                symbol_count += try nbfDecodeCleanupSampleRange(scratch, decoder, x, stripe_y, runlen + 1, 4, bitplane, style);
            } else {
                symbol_count += try nbfDecodeCleanupSampleRange(scratch, decoder, x, stripe_y, 0, stripe_height, bitplane, style);
            }
        }
    }

    if (style.segmentation_symbols) {
        symbol_count += try readSegmentationSymbols(decoder);
    }

    return symbol_count;
}

fn decodeCleanupPassInferredPlain(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    bitplane: u8,
    band_kind: subband.Kind,
    segmentation_symbols: bool,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    const band_index = @intFromEnum(band_kind);
    var symbol_count: usize = 0;

    var stripe_y: usize = 0;
    while (stripe_y < scratch.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), scratch.height - stripe_y);
        var x: usize = 0;
        while (x < scratch.width) : (x += 1) {
            if (stripe_height == 4 and nbfCanUseRunStripePlain(flags, nbs, x, stripe_y)) {
                const agg = try mqRead(decoder, mqContextIndex(.cleanup_aggregation));
                symbol_count += 1;
                if (!agg) continue;

                const runlen = try readCleanupRunLength(decoder);
                symbol_count += 2;
                if (runlen >= 4) return EbcotError.InvalidBlock;

                {
                    const y = stripe_y + runlen;
                    const sample_flags = flags[nbfIndex(nbs, x, y)];
                    try decodeCleanupSignPlainKnown(scratch, decoder, flags, nbs, x, y, bitplane, sample_flags);
                    symbol_count += 1;
                }

                symbol_count += try decodeCleanupSampleRangePlainKnown(scratch, decoder, flags, nbs, x, stripe_y, runlen + 1, 4, bitplane, band_index);
            } else {
                symbol_count += try decodeCleanupSampleRangePlainKnown(scratch, decoder, flags, nbs, x, stripe_y, 0, stripe_height, bitplane, band_index);
            }
        }
    }

    if (segmentation_symbols) {
        symbol_count += try readSegmentationSymbols(decoder);
    }

    return symbol_count;
}

fn emitCleanupSample(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayList(Symbol),
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    pos: ScanPos,
    bitplane: u8,
    pass_index: u16,
    significant: []bool,
    visited: []const bool,
    became_significant: []bool,
    style: CodeBlockStyle,
) !void {
    const index = localIndex(rect.width, pos.x, pos.y);
    if (significant[index] or visited[index]) return;
    try emitZeroCoding(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index, significant, style);
    if (isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane)) {
        try emitSign(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index, significant, style, false);
        significant[index] = true;
        became_significant[index] = true;
    }
}

fn emitCleanupRunSymbols(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayList(Symbol),
    pass_index: u16,
    bitplane: u8,
    x: usize,
    stripe_y: usize,
    runlen: usize,
) !void {
    try symbols.append(allocator, .{
        .pass_index = pass_index,
        .kind = .cleanup_aggregation,
        .context = .cleanup_aggregation,
        .bit = runlen != 4,
        .x = x,
        .y = stripe_y,
        .magnitude_bitplane = bitplane,
    });
    if (runlen == 4) return;
    try appendCleanupRunBit(allocator, symbols, pass_index, bitplane, x, stripe_y, runlen >> 1);
    try appendCleanupRunBit(allocator, symbols, pass_index, bitplane, x, stripe_y, runlen & 1);
}

fn appendCleanupRunBit(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayList(Symbol),
    pass_index: u16,
    bitplane: u8,
    x: usize,
    stripe_y: usize,
    value: usize,
) !void {
    try symbols.append(allocator, .{
        .pass_index = pass_index,
        .kind = .cleanup_run_length,
        .context = .cleanup_run,
        .bit = value != 0,
        .x = x,
        .y = stripe_y,
        .magnitude_bitplane = bitplane,
    });
}

fn emitSegmentationSymbols(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayList(Symbol),
    pass_index: u16,
    bitplane: u8,
) !void {
    for (segmentation_symbol_bits, 0..) |bit, index| {
        try symbols.append(allocator, .{
            .pass_index = pass_index,
            .kind = .segmentation_symbol,
            .context = .cleanup_run,
            .bit = bit,
            .x = index,
            .y = 0,
            .magnitude_bitplane = bitplane,
        });
    }
}

fn writeSegmentationSymbols(encoder: anytype) !void {
    for (segmentation_symbol_bits) |bit| {
        try encoder.write(mqContextIndex(.cleanup_run), bit);
    }
}

fn readSegmentationSymbols(decoder: anytype) !usize {
    for (segmentation_symbol_bits) |expected| {
        if (try mqRead(decoder, mqContextIndex(.cleanup_run)) != expected) return EbcotError.InvalidBlock;
    }
    return segmentation_symbol_bits.len;
}

inline fn mqRead(decoder: anytype, context_index: usize) !bool {
    if (comptime @TypeOf(decoder) == *mq_iso.Decoder) {
        return decoder.readUnchecked(context_index);
    }
    return try decoder.read(context_index);
}

fn canUseCleanupRunStripe(
    significant: []const bool,
    visited: []const bool,
    width: usize,
    height: usize,
    x: usize,
    stripe_y: usize,
    style: CodeBlockStyle,
) bool {
    var dy: usize = 0;
    while (dy < 4) : (dy += 1) {
        const y = stripe_y + dy;
        const index = localIndex(width, x, y);
        if (significant[index] or visited[index]) return false;
        if (neighborSignificance(significant, width, height, x, y, style) != 0) return false;
    }
    return true;
}

fn cleanupRunLength(
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    x: usize,
    stripe_y: usize,
    bitplane: u8,
) usize {
    var dy: usize = 0;
    while (dy < 4) : (dy += 1) {
        if (isMagnitudeBitSet(plane[(rect.y + stripe_y + dy) * stride + rect.x + x], bitplane)) return dy;
    }
    return 4;
}

fn canUseCleanupRunStripeDecode(scratch: *const DecodeBlockScratch, x: usize, stripe_y: usize, style: CodeBlockStyle) bool {
    var dy: usize = 0;
    while (dy < 4) : (dy += 1) {
        const y = stripe_y + dy;
        const index = localIndex(scratch.width, x, y);
        if (hasSignificantRowDecode(scratch, x, y) or hasFlag(scratch.flags.items, index, .visited)) return false;
        if (neighborSignificanceRowsDecode(scratch, x, y, style) != 0) return false;
    }
    return true;
}

fn readCleanupRunLength(decoder: anytype) !usize {
    const hi = try mqRead(decoder, mqContextIndex(.cleanup_run));
    const lo = try mqRead(decoder, mqContextIndex(.cleanup_run));
    return (@as(usize, @intFromBool(hi)) << 1) | @intFromBool(lo);
}

const MqPassProfile = struct {
    start_ns: u64 = 0,
    branches: mq_iso.DecodeBranchStats = .{},
};

const ProfiledIsoMqDecoder = struct {
    decoder: *mq_iso.Decoder,
    branches: *mq_iso.DecodeBranchStats,

    pub inline fn read(self: *ProfiledIsoMqDecoder, context_index: usize) !bool {
        return self.decoder.readProfiled(context_index, self.branches);
    }
};

fn profileRawPass(stats: ?*DecodePassStats, kind: PassKind, symbols: usize, start_ns: u64) void {
    if (stats) |s| s.addRaw(kind, symbols, profileElapsedNs(start_ns));
}

fn profileStart(stats: ?*DecodePassStats) u64 {
    if (stats == null) return 0;
    return profileNs();
}

fn profileMqStart(stats: ?*DecodePassStats) MqPassProfile {
    if (stats == null) return .{};
    const profile = MqPassProfile{ .start_ns = profileNs() };
    return profile;
}

fn profileMqPass(stats: ?*DecodePassStats, kind: PassKind, symbols: usize, profile: MqPassProfile) void {
    if (stats) |s| {
        s.addMq(kind, symbols, profileElapsedNs(profile.start_ns));
        s.addMqBranches(kind, profile.branches);
    }
}

fn decodeSignificancePassInferredProfiled(
    scratch: *DecodeBlockScratch,
    decoder: *mq_iso.Decoder,
    bitplane: u8,
    style: CodeBlockStyle,
    profile: *MqPassProfile,
    enabled: bool,
) !usize {
    if (!enabled) return decodeSignificancePassInferred(scratch, decoder, bitplane, style);
    var profiled = ProfiledIsoMqDecoder{ .decoder = decoder, .branches = &profile.branches };
    return decodeSignificancePassInferred(scratch, &profiled, bitplane, style);
}

fn decodeRefinementPassInferredProfiled(
    scratch: *DecodeBlockScratch,
    decoder: *mq_iso.Decoder,
    bitplane: u8,
    style: CodeBlockStyle,
    profile: *MqPassProfile,
    enabled: bool,
) !usize {
    if (!enabled) return decodeRefinementPassInferred(scratch, decoder, bitplane, style);
    var profiled = ProfiledIsoMqDecoder{ .decoder = decoder, .branches = &profile.branches };
    return decodeRefinementPassInferred(scratch, &profiled, bitplane, style);
}

fn decodeCleanupPassInferredProfiled(
    scratch: *DecodeBlockScratch,
    decoder: *mq_iso.Decoder,
    bitplane: u8,
    style: CodeBlockStyle,
    profile: *MqPassProfile,
    enabled: bool,
) !usize {
    if (!enabled) return decodeCleanupPassInferred(scratch, decoder, bitplane, style);
    var profiled = ProfiledIsoMqDecoder{ .decoder = decoder, .branches = &profile.branches };
    return decodeCleanupPassInferred(scratch, &profiled, bitplane, style);
}

fn profileElapsedNs(start_ns: u64) u64 {
    const now = profileNs();
    return if (now >= start_ns) now - start_ns else 0;
}

fn profileNs() u64 {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var frequency: windows.LARGE_INTEGER = undefined;
        var counter: windows.LARGE_INTEGER = undefined;
        if (!windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool()) return 0;
        if (!windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool()) return 0;
        if (frequency <= 0 or counter < 0) return 0;
        return @intCast((@as(u128, @intCast(counter)) * std.time.ns_per_s) / @as(u128, @intCast(frequency)));
    }

    const posix = std.posix;
    var ts: posix.timespec = undefined;
    return switch (posix.errno(posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec)),
        else => 0,
    };
}

fn nbfDecodeCleanupSample(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    x: usize,
    y: usize,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    const sample = scratch.nb_flags.items[nbfIndex(scratch.nb_stride, x, y)];
    if ((sample & (nbf_sig_self | nbf_visit)) != 0) return 0;
    // Cleanup codes every insignificant, unvisited sample; zero0 is valid.
    const decision = decodeT1SignificanceDecision(scratch, x, y, sample, style);
    const bit = try mqRead(decoder, mqContextIndex(decision.zero_context));
    var symbol_count: usize = 1;
    if (bit) {
        const sign = decodeT1SignCoding(scratch, x, y, sample, style);
        const sign_bit = try mqRead(decoder, mqContextIndex(sign.context));
        symbol_count += 1;
        const negative = sign_bit != sign.predicted_negative;
        markDecodedSignificantNbf(scratch, x, y, bitplane, negative);
    }
    return symbol_count;
}

inline fn nbfDecodeCleanupSampleRange(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    x: usize,
    stripe_y: usize,
    first_dy: usize,
    end_dy: usize,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    var symbol_count: usize = 0;
    var dy = first_dy;
    while (dy < end_dy) : (dy += 1) {
        symbol_count += try nbfDecodeCleanupSample(scratch, decoder, x, stripe_y + dy, bitplane, style);
    }
    return symbol_count;
}

fn nbfDecodeCleanupSamplePlain(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    x: usize,
    y: usize,
    bitplane: u8,
    band_kind: subband.Kind,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    return nbfDecodeCleanupSamplePlainKnown(scratch, decoder, flags, nbs, x, y, bitplane, @intFromEnum(band_kind));
}

inline fn nbfDecodeCleanupSamplePlainKnown(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    flags: []u16,
    nbs: usize,
    x: usize,
    y: usize,
    bitplane: u8,
    band_index: usize,
) !usize {
    const sample = flags[nbfIndex(nbs, x, y)];
    if ((sample & (nbf_sig_self | nbf_visit)) != 0) return 0;
    const zero_context = nbf_zc_lut[band_index][sample & nbf_sig8];
    const bit = try mqRead(decoder, mqContextIndex(zero_context));
    var symbol_count: usize = 1;
    if (bit) {
        try decodeCleanupSignPlainKnown(scratch, decoder, flags, nbs, x, y, bitplane, sample);
        symbol_count += 1;
    }
    return symbol_count;
}

inline fn decodeCleanupSampleRangePlainKnown(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    flags: []u16,
    nbs: usize,
    x: usize,
    stripe_y: usize,
    first_dy: usize,
    end_dy: usize,
    bitplane: u8,
    band_index: usize,
) !usize {
    var symbol_count: usize = 0;
    var dy = first_dy;
    while (dy < end_dy) : (dy += 1) {
        symbol_count += try nbfDecodeCleanupSamplePlainKnown(scratch, decoder, flags, nbs, x, stripe_y + dy, bitplane, band_index);
    }
    return symbol_count;
}

inline fn decodeCleanupSignPlainKnown(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    flags: []u16,
    nbs: usize,
    x: usize,
    y: usize,
    bitplane: u8,
    sample_flags: u16,
) !void {
    const sign = nbf_sc_lut[nbfScIndex(sample_flags)];
    const sign_bit = try mqRead(decoder, mqContextIndex(sign.context));
    const negative = sign_bit != sign.predicted_negative;
    markDecodedSignificantNbfKnown(scratch, flags, nbs, x, y, bitplane, negative);
}

fn decodeCleanupSample(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    x: usize,
    y: usize,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    const index = localIndex(scratch.width, x, y);
    if (hasSignificantRowDecode(scratch, x, y) or hasFlag(scratch.flags.items, index, .visited)) return 0;
    const bit = try mqRead(decoder, mqContextIndex(zeroContextRowsDecode(scratch, x, y, style)));
    var symbol_count: usize = 1;
    if (bit) {
        const sign = signCodingRowsDecode(scratch, x, y, style);
        const sign_bit = try mqRead(decoder, mqContextIndex(sign.context));
        symbol_count += 1;
        const negative = sign_bit != sign.predicted_negative;
        markDecodedSignificant(scratch, x, y, bitplane, negative);
    }
    return symbol_count;
}

fn decodeCleanupSampleRange(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    x: usize,
    stripe_y: usize,
    first_dy: usize,
    end_dy: usize,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    var symbol_count: usize = 0;
    var dy = first_dy;
    while (dy < end_dy) : (dy += 1) {
        symbol_count += try decodeCleanupSample(scratch, decoder, x, stripe_y + dy, bitplane, style);
    }
    return symbol_count;
}

fn emitZeroCoding(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayList(Symbol),
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    pos: ScanPos,
    bitplane: u8,
    pass_index: u16,
    significant: []const bool,
    style: CodeBlockStyle,
) !void {
    try symbols.append(allocator, .{
        .pass_index = pass_index,
        .kind = .zero_coding,
        .context = zeroContextFromSlice(significant, rect.width, rect.height, pos.x, pos.y, style),
        .bit = isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane),
        .x = pos.x,
        .y = pos.y,
        .magnitude_bitplane = bitplane,
    });
}

fn emitSign(
    allocator: std.mem.Allocator,
    symbols: *std.ArrayList(Symbol),
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    pos: ScanPos,
    bitplane: u8,
    pass_index: u16,
    significant: []const bool,
    style: CodeBlockStyle,
    raw: bool,
) !void {
    const coding = signCoding(plane, stride, rect, pos.x, pos.y, significant, style);
    const negative = plane[(rect.y + pos.y) * stride + rect.x + pos.x] < 0;
    // In raw (bypass) passes the sign is coded directly with no prediction:
    // 1 means negative (ISO D.6, opj_t1_dec_sigpass_step_raw).
    try symbols.append(allocator, .{
        .pass_index = pass_index,
        .kind = .sign,
        .context = coding.context,
        .bit = if (raw) negative else negative != coding.predicted_negative,
        .x = pos.x,
        .y = pos.y,
        .magnitude_bitplane = bitplane,
    });
}

fn emitDirectSignificancePass(
    scratch: *DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    pass_index: u16,
    style: CodeBlockStyle,
) !void {
    const byte_offset = scratch.bytes.items.len;
    const encoder = try scratch.mqEncoder();
    encoder.resetAll();
    var symbol_count: usize = 0;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        const neighbor_count = neighborSignificanceRows(scratch, pos.x, pos.y, style);
        if (hasSignificantRow(scratch, pos.x, pos.y) or neighbor_count == 0) continue;
        setFlag(scratch.flags.items, index, .visited);
        const bit = isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane);
        try encoder.write(mqContextIndex(zeroContextRows(scratch, pos.x, pos.y, style)), bit);
        symbol_count += 1;
        if (bit) {
            const sign = signCodingRows(scratch, plane, stride, rect, pos.x, pos.y, style);
            const negative = plane[(rect.y + pos.y) * stride + rect.x + pos.x] < 0;
            try encoder.write(mqContextIndex(sign.context), negative != sign.predicted_negative);
            symbol_count += 1;
            setFlag(scratch.flags.items, index, .significant);
            setSignificantRow(scratch, pos.x, pos.y);
            setFlag(scratch.flags.items, index, .became_significant);
        }
    }

    try appendDirectPass(scratch, .significance, bitplane, symbol_count, byte_offset);
    _ = pass_index;
}

fn emitDirectRefinementPass(
    scratch: *DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    pass_index: u16,
    style: CodeBlockStyle,
) !void {
    const byte_offset = scratch.bytes.items.len;
    const encoder = try scratch.mqEncoder();
    encoder.resetAll();
    var symbol_count: usize = 0;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (!hasSignificantRow(scratch, pos.x, pos.y) or hasFlag(scratch.flags.items, index, .became_significant)) continue;
        try encoder.write(
            mqContextIndex(refinementContext(hasFlag(scratch.flags.items, index, .refined), neighborSignificanceRows(scratch, pos.x, pos.y, style))),
            isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane),
        );
        symbol_count += 1;
        setFlag(scratch.flags.items, index, .refined);
    }

    try appendDirectPass(scratch, .refinement, bitplane, symbol_count, byte_offset);
    _ = pass_index;
}

fn emitDirectCleanupPass(
    scratch: *DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    pass_index: u16,
    style: CodeBlockStyle,
) !void {
    const byte_offset = scratch.bytes.items.len;
    const encoder = try scratch.mqEncoder();
    encoder.resetAll();
    var symbol_count: usize = 0;

    var stripe_y: usize = 0;
    while (stripe_y < rect.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), rect.height - stripe_y);
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            if (stripe_height == 4 and canUseDirectCleanupRunStripe(scratch, x, stripe_y, style)) {
                const runlen = cleanupRunLength(plane, stride, rect, x, stripe_y, bitplane);
                try encoder.write(mqContextIndex(.cleanup_aggregation), runlen != 4);
                symbol_count += 1;
                if (runlen == 4) continue;

                try writeCleanupRunLength(encoder, runlen);
                symbol_count += 2;

                const y = stripe_y + runlen;
                try emitDirectSignOnly(scratch, encoder, plane, stride, rect, x, y, bitplane, style);
                symbol_count += 1;

                symbol_count += try emitDirectCleanupSampleRange(scratch, encoder, plane, stride, rect, x, stripe_y, runlen + 1, 4, bitplane, style);
            } else {
                symbol_count += try emitDirectCleanupSampleRange(scratch, encoder, plane, stride, rect, x, stripe_y, 0, stripe_height, bitplane, style);
            }
        }
    }

    if (style.segmentation_symbols) {
        try writeSegmentationSymbols(encoder);
        symbol_count += 4;
    }

    try appendDirectPass(scratch, .cleanup, bitplane, symbol_count, byte_offset);
    _ = pass_index;
}

fn canUseDirectCleanupRunStripe(scratch: *const DirectBlockScratch, x: usize, stripe_y: usize, style: CodeBlockStyle) bool {
    var dy: usize = 0;
    while (dy < 4) : (dy += 1) {
        const y = stripe_y + dy;
        const index = localIndex(scratch.width, x, y);
        if (hasSignificantRow(scratch, x, y) or hasFlag(scratch.flags.items, index, .visited)) return false;
        if (neighborSignificanceRows(scratch, x, y, style) != 0) return false;
    }
    return true;
}

fn writeCleanupRunLength(encoder: anytype, runlen: usize) !void {
    try encoder.write(mqContextIndex(.cleanup_run), ((runlen >> 1) & 1) != 0);
    try encoder.write(mqContextIndex(.cleanup_run), (runlen & 1) != 0);
}

fn emitDirectSignOnly(
    scratch: *DirectBlockScratch,
    encoder: anytype,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    x: usize,
    y: usize,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    const index = localIndex(rect.width, x, y);
    const sign = signCodingRows(scratch, plane, stride, rect, x, y, style);
    const negative = plane[(rect.y + y) * stride + rect.x + x] < 0;
    try encoder.write(mqContextIndex(sign.context), negative != sign.predicted_negative);
    setFlag(scratch.flags.items, index, .significant);
    setSignificantRow(scratch, x, y);
    setFlag(scratch.flags.items, index, .became_significant);
    _ = bitplane;
}

fn emitDirectCleanupSample(
    scratch: *DirectBlockScratch,
    encoder: anytype,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    x: usize,
    y: usize,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    const index = localIndex(rect.width, x, y);
    if (hasSignificantRow(scratch, x, y) or hasFlag(scratch.flags.items, index, .visited)) return 0;
    const bit = isMagnitudeBitSet(plane[(rect.y + y) * stride + rect.x + x], bitplane);
    try encoder.write(mqContextIndex(zeroContextRows(scratch, x, y, style)), bit);
    var symbol_count: usize = 1;
    if (bit) {
        try emitDirectSignOnly(scratch, encoder, plane, stride, rect, x, y, bitplane, style);
        symbol_count += 1;
    }
    return symbol_count;
}

fn emitDirectCleanupSampleRange(
    scratch: *DirectBlockScratch,
    encoder: anytype,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    x: usize,
    stripe_y: usize,
    first_dy: usize,
    end_dy: usize,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    var symbol_count: usize = 0;
    var dy = first_dy;
    while (dy < end_dy) : (dy += 1) {
        symbol_count += try emitDirectCleanupSample(scratch, encoder, plane, stride, rect, x, stripe_y + dy, bitplane, style);
    }
    return symbol_count;
}

fn appendDirectPass(
    scratch: *DirectBlockScratch,
    kind: PassKind,
    bitplane: u8,
    symbol_count: usize,
    byte_offset: usize,
) !void {
    const encoder = try scratch.mqEncoder();
    const encoded_len = try encoder.finishInto(scratch.allocator, &scratch.bytes);
    try scratch.pass_payloads.append(scratch.allocator, .{
        .kind = kind,
        .magnitude_bitplane = bitplane,
        .symbol_count = symbol_count,
        .byte_offset = byte_offset,
        .byte_length = encoded_len,
        .cumulative_bytes = @intCast(scratch.bytes.items.len),
    });
}

/// Hot-path ISO MQ block encoder: writes coefficients straight into the ISO
/// MQ coder (plus raw BYPASS segments) using the reusable direct scratch, so
/// no per-block Symbol list or allocator churn is left on the default
/// encoding path. Produces the same codeword segments as the symbol-based
/// encodeBlockSymbolsSegmentIsoMqContinuous / ...IsoMqBypass pair.
pub fn encodeCodeBlockSegmentDirectIsoScratchWithStyle(
    scratch: *DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    style: CodeBlockStyle,
) !CodeBlockSegment {
    return encodeCodeBlockSegmentDirectIsoScratchInternal(
        false,
        scratch,
        plane,
        stride,
        rect,
        style,
        &.{},
    );
}

/// Rate-allocation variant of the direct ISO-MQ encoder. Distortion is
/// accumulated while the real coding passes are emitted, avoiding a second
/// symbol-coder traversal of the block solely for PCRD metadata.
pub fn encodeCodeBlockSegmentDirectIsoScratchWithStyleAndDistortions(
    scratch: *DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    style: CodeBlockStyle,
    pass_distortions: []f64,
) !CodeBlockSegment {
    return encodeCodeBlockSegmentDirectIsoScratchInternal(
        true,
        scratch,
        plane,
        stride,
        rect,
        style,
        pass_distortions,
    );
}

fn encodeCodeBlockSegmentDirectIsoScratchInternal(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    style: CodeBlockStyle,
    pass_distortions: []f64,
) !CodeBlockSegment {
    try validateImplementedStyleAllowBypass(style);
    if (style.terminate_all) return EbcotError.InvalidBlock;
    scratch.reset();
    try validateBlock(plane, stride, rect);

    const stats = blockStats(plane, stride, rect);
    if (stats.bitplanes == 0) {
        return ownedSegmentFromDirectIsoScratch(scratch, 0, 0, style.bypass);
    }
    const bitplanes = stats.bitplanes;
    const total_passes = expectedCodingPasses(bitplanes);
    if (comptime track_distortion) {
        if (pass_distortions.len < total_passes) return EbcotError.InvalidBlock;
        @memset(pass_distortions[0..total_passes], 0);
    }

    const area = try blockArea(rect);
    try scratch.ensureBlockState(rect.width, rect.height, area);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
    if (comptime maintain_packed_t1_context_flags) @memset(scratch.packed_t1_flags.items, 0);

    try scratch.bytes.ensureUnusedCapacity(scratch.allocator, estimatedIsoMqByteCapacity(area, bitplanes));
    const iso = try scratch.isoMqEncoder();
    iso.resetStreamInto(&scratch.bytes);
    try iso.resetJpeg2000Contexts();
    const raw = scratch.rawBitWriter();
    raw.resetInto(&scratch.bytes);

    var segment_start_bytes: u64 = 0;
    var previous_running: u64 = 0;
    var segment_pass_count: u16 = 0;
    var segment_is_raw = false;
    var pass_index: u16 = 0;
    var bitplane_index = bitplanes;
    while (bitplane_index > 0) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        directClearNbfVisit(scratch);

        const kinds: [3]PassKind = if (bitplane == bitplanes - 1)
            .{ .cleanup, .cleanup, .cleanup }
        else
            .{ .significance, .refinement, .cleanup };
        const passes_this_bitplane: u16 = if (bitplane == bitplanes - 1) 1 else 3;

        var kind_index: u16 = 0;
        while (kind_index < passes_this_bitplane) : (kind_index += 1) {
            const kind = kinds[kind_index];
            const is_raw = passIsRaw(style, bitplanes, bitplane, kind);
            if (segment_pass_count == 0) segment_is_raw = is_raw;
            if (is_raw != segment_is_raw) return EbcotError.InvalidBlock;
            // Standalone RESET (D.4, COD 0x02 without TERMALL): the MQ
            // contexts restart at every coding-pass boundary while the
            // codeword stream stays continuous.
            if (style.reset_context and pass_index != 0) try iso.resetJpeg2000Contexts();
            if (comptime track_distortion) {
                scratch.current_pass_distortion = &pass_distortions[pass_index];
            }

            const symbol_count: usize = switch (kind) {
                .significance => if (is_raw)
                    try emitDirectIsoSignificancePass(track_distortion, scratch, raw, plane, stride, rect, bitplane, style, true)
                else
                    try emitDirectIsoSignificancePass(track_distortion, scratch, iso, plane, stride, rect, bitplane, style, false),
                .refinement => if (is_raw)
                    try emitDirectIsoRefinementPass(track_distortion, scratch, raw, plane, stride, rect, bitplane, style)
                else
                    try emitDirectIsoRefinementPass(track_distortion, scratch, iso, plane, stride, rect, bitplane, style),
                .cleanup => try emitDirectIsoCleanupPass(track_distortion, scratch, iso, plane, stride, rect, bitplane, style),
            };

            segment_pass_count += 1;
            pass_index += 1;
            const running: u64 = segment_start_bytes +
                (if (is_raw) @as(u64, raw.emittedByteCount()) else @as(u64, iso.emittedByteCount()));
            try scratch.pass_payloads.append(scratch.allocator, .{
                .kind = kind,
                .magnitude_bitplane = bitplane,
                .symbol_count = symbol_count,
                .byte_offset = @intCast(previous_running),
                .byte_length = @intCast(running - previous_running),
                .cumulative_bytes = running,
            });
            previous_running = running;

            const last_pass = pass_index == total_passes;
            if (last_pass or passEndsBypassSegment(style, bitplanes, bitplane, kind)) {
                // ERTERM (D.4.2): every termination point flushes
                // predictably — the ER-TERM procedure for MQ segments, the
                // alternating-bit padding for raw BYPASS segments. Without
                // BYPASS the final MQ flush is the only termination point.
                const encoded_len = if (segment_is_raw)
                    (if (style.predictable_termination)
                        try raw.finishErtermInto(&scratch.bytes)
                    else
                        try raw.finishInto(&scratch.bytes))
                else if (style.predictable_termination)
                    try iso.finishErtermInto(&scratch.bytes)
                else
                    try iso.finishInto(&scratch.bytes);
                try scratch.segments.append(scratch.allocator, .{
                    .pass_count = segment_pass_count,
                    .byte_length = @intCast(encoded_len),
                });
                const cumulative: u64 = @intCast(scratch.bytes.items.len);
                const fixup = &scratch.pass_payloads.items[scratch.pass_payloads.items.len - 1];
                fixup.byte_length = cumulative - fixup.byte_offset;
                fixup.cumulative_bytes = cumulative;
                segment_start_bytes = cumulative;
                previous_running = cumulative;
                segment_pass_count = 0;
                if (!last_pass) {
                    raw.resetInto(&scratch.bytes);
                    iso.resetStreamInto(&scratch.bytes);
                }
            }
        }
    }
    if (pass_index != total_passes or segment_pass_count != 0) return EbcotError.InvalidBlock;
    scratch.current_pass_distortion = null;

    return ownedSegmentFromDirectIsoScratch(scratch, bitplanes, stats.non_zero_count, style.bypass);
}

inline fn recordSignificanceDistortion(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    coeff: i32,
    bitplane: u8,
) void {
    if (comptime track_distortion) {
        const magnitude_value: u64 = @abs(coeff);
        const before = @as(f64, @floatFromInt(magnitude_value)) * @as(f64, @floatFromInt(magnitude_value));
        scratch.current_pass_distortion.?.* += before - midpointSquaredError(magnitude_value, bitplane);
    }
}

inline fn recordRefinementDistortion(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    coeff: i32,
    bitplane: u8,
) void {
    if (comptime track_distortion) {
        const magnitude_value: u64 = @abs(coeff);
        scratch.current_pass_distortion.?.* += midpointSquaredError(magnitude_value, bitplane + 1) -
            midpointSquaredError(magnitude_value, bitplane);
    }
}

fn estimatedIsoMqByteCapacity(area: usize, bitplanes: u8) usize {
    const symbol_bound = area * @as(usize, bitplanes) * 4;
    return symbol_bound + 64;
}

fn ownedSegmentFromDirectIsoScratch(
    scratch: *DirectBlockScratch,
    bitplanes: u8,
    non_zero_count: u32,
    keep_segments: bool,
) !CodeBlockSegment {
    const pass_slice = try scratch.allocator.dupe(CodeBlockPassPayload, scratch.pass_payloads.items);
    errdefer scratch.allocator.free(pass_slice);
    const byte_slice = try scratch.allocator.dupe(u8, scratch.bytes.items);
    errdefer scratch.allocator.free(byte_slice);
    const segment_slice: ?[]SegmentSpan = if (keep_segments)
        try scratch.allocator.dupe(SegmentSpan, scratch.segments.items)
    else
        null;

    return .{
        .bitplanes = bitplanes,
        .non_zero_count = non_zero_count,
        .pass_count = @intCast(pass_slice.len),
        .byte_length = @intCast(byte_slice.len),
        .passes = pass_slice,
        .bytes = byte_slice,
        .segments = segment_slice,
    };
}

/// True when any sample in rows [stripe_y - 1, stripe_y + stripe_height] is
/// significant; a stripe with an all-zero neighborhood window can be skipped
/// entirely by the significance pass.
fn stripeHasSignificance(scratch: *const DirectBlockScratch, stripe_y: usize, stripe_height: usize) bool {
    const first_row = if (stripe_y == 0) 0 else stripe_y - 1;
    const last_row = @min(scratch.height - 1, stripe_y + stripe_height);
    var acc: u64 = 0;
    var row = first_row;
    while (row <= last_row) : (row += 1) {
        const base = row * scratch.row_words;
        for (scratch.significant_words.items[base..][0..scratch.row_words]) |word| acc |= word;
    }
    return acc != 0;
}

fn stripeHasSignificanceRange(
    words: []const u64,
    row_words: usize,
    width: usize,
    height: usize,
    stripe_y: usize,
    stripe_height: usize,
    x_begin: usize,
    x_end: usize,
) bool {
    if (x_begin >= x_end or width == 0) return false;
    const first_row = if (stripe_y == 0) 0 else stripe_y - 1;
    const last_row = @min(height - 1, stripe_y + stripe_height);
    const first_x = if (x_begin == 0) 0 else x_begin - 1;
    const last_x = @min(width - 1, x_end);
    return significantRowsHaveRange(words, row_words, first_row, last_row, first_x, last_x);
}

fn stripeHasSignificanceRangeDirect(
    scratch: *const DirectBlockScratch,
    stripe_y: usize,
    stripe_height: usize,
    x_begin: usize,
    x_end: usize,
) bool {
    return stripeHasSignificanceRange(
        scratch.significant_words.items,
        scratch.row_words,
        scratch.width,
        scratch.height,
        stripe_y,
        stripe_height,
        x_begin,
        x_end,
    );
}

/// True when any sample inside the stripe rows themselves is significant.
fn stripeRowsSignificant(scratch: *const DirectBlockScratch, stripe_y: usize, stripe_height: usize) bool {
    var acc: u64 = 0;
    var row = stripe_y;
    while (row < stripe_y + stripe_height) : (row += 1) {
        const base = row * scratch.row_words;
        for (scratch.significant_words.items[base..][0..scratch.row_words]) |word| acc |= word;
    }
    return acc != 0;
}

fn stripeRowsSignificantRange(
    words: []const u64,
    row_words: usize,
    width: usize,
    stripe_y: usize,
    stripe_height: usize,
    x_begin: usize,
    x_end: usize,
) bool {
    if (x_begin >= x_end or width == 0) return false;
    return significantRowsHaveRange(
        words,
        row_words,
        stripe_y,
        stripe_y + stripe_height - 1,
        x_begin,
        x_end - 1,
    );
}

fn stripeRowsSignificantRangeDirect(
    scratch: *const DirectBlockScratch,
    stripe_y: usize,
    stripe_height: usize,
    x_begin: usize,
    x_end: usize,
) bool {
    return stripeRowsSignificantRange(
        scratch.significant_words.items,
        scratch.row_words,
        scratch.width,
        stripe_y,
        stripe_height,
        x_begin,
        x_end,
    );
}

fn significantRowsHaveRange(
    words: []const u64,
    row_words: usize,
    first_row: usize,
    last_row: usize,
    first_x: usize,
    last_x: usize,
) bool {
    const first_word = first_x / significant_word_bits;
    const last_word = last_x / significant_word_bits;
    var row = first_row;
    while (row <= last_row) : (row += 1) {
        const row_start = row * row_words;
        var word = first_word;
        while (word <= last_word) : (word += 1) {
            const word_min_x = word * significant_word_bits;
            const lo = if (first_x > word_min_x) first_x - word_min_x else 0;
            const hi = @min(last_x - word_min_x, significant_word_bits - 1);
            if ((words[row_start + word] & bitRangeMask(lo, hi)) != 0) return true;
        }
    }
    return false;
}

fn emitDirectIsoSignificancePass(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    encoder: anytype,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    style: CodeBlockStyle,
    comptime raw: bool,
) !usize {
    if (comptime !maintain_packed_t1_context_flags) {
        if (!style.vertical_causal) {
            return emitDirectIsoSignificancePassPlain(track_distortion, scratch, encoder, plane, stride, rect, bitplane, style.band_kind, raw);
        }
    }

    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;
    var stripe_y: usize = 0;
    while (stripe_y < rect.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), rect.height - stripe_y);
        // No significance anywhere near this stripe means no sample can have
        // a significant neighborhood, so the whole stripe is skipped.
        if (!stripeHasSignificance(scratch, stripe_y, stripe_height)) continue;
        var x: usize = 0;
        while (x < rect.width) {
            const x_end = @min(x + significant_word_bits, rect.width);
            if (!stripeHasSignificanceRangeDirect(scratch, stripe_y, stripe_height, x, x_end)) {
                x = x_end;
                continue;
            }
            while (x < x_end) : (x += 1) {
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    const y = stripe_y + dy;
                    const p = nbfIndex(nbs, x, y);
                    const sample_flags = flags[p];
                    if (raw) {
                        if (!directT1SignificanceCandidate(scratch, x, y, sample_flags, style)) continue;
                        flags[p] |= nbf_visit;
                        directMarkPackedT1Visited(scratch, x, y);
                        const coeff = plane[(rect.y + y) * stride + rect.x + x];
                        const bit = isMagnitudeBitSet(coeff, bitplane);
                        try encoder.writeBit(bit);
                        symbol_count += 1;
                        if (bit) {
                            recordSignificanceDistortion(track_distortion, scratch, coeff, bitplane);
                            const negative = coeff < 0;
                            try encoder.writeBit(negative);
                            symbol_count += 1;
                            nbfMarkSignificant(flags, nbs, x, y, negative);
                            directMarkPackedT1Significant(scratch, x, y, negative);
                            setSignificantRow(scratch, x, y);
                        }
                    } else {
                        if (!directT1SignificanceCandidate(scratch, x, y, sample_flags, style)) continue;
                        flags[p] |= nbf_visit;
                        directMarkPackedT1Visited(scratch, x, y);
                        const coeff = plane[(rect.y + y) * stride + rect.x + x];
                        const bit = isMagnitudeBitSet(coeff, bitplane);
                        const zero_context = directT1ZeroContext(scratch, x, y, sample_flags, style);
                        try encoder.write(mqContextIndex(zero_context), bit);
                        symbol_count += 1;
                        if (bit) {
                            recordSignificanceDistortion(track_distortion, scratch, coeff, bitplane);
                            const negative = coeff < 0;
                            const sign = directT1SignCoding(scratch, x, y, sample_flags, style);
                            try encoder.write(mqContextIndex(sign.context), negative != sign.predicted_negative);
                            symbol_count += 1;
                            nbfMarkSignificant(flags, nbs, x, y, negative);
                            directMarkPackedT1Significant(scratch, x, y, negative);
                            setSignificantRow(scratch, x, y);
                        }
                    }
                }
            }
        }
    }
    return symbol_count;
}

fn emitDirectIsoSignificancePassPlain(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    encoder: anytype,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    band_kind: subband.Kind,
    comptime raw: bool,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;
    var stripe_y: usize = 0;
    while (stripe_y < rect.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), rect.height - stripe_y);
        if (!stripeHasSignificance(scratch, stripe_y, stripe_height)) continue;
        var x: usize = 0;
        while (x < rect.width) {
            const x_end = @min(x + significant_word_bits, rect.width);
            if (!stripeHasSignificanceRangeDirect(scratch, stripe_y, stripe_height, x, x_end)) {
                x = x_end;
                continue;
            }
            while (x < x_end) : (x += 1) {
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    const y = stripe_y + dy;
                    const p = nbfIndex(nbs, x, y);
                    const sample_flags = flags[p];
                    if ((sample_flags & (nbf_sig_self | nbf_visit)) != 0) continue;
                    const pattern = sample_flags & nbf_sig8;
                    if (pattern == 0) continue;
                    flags[p] |= nbf_visit;
                    const coeff = plane[(rect.y + y) * stride + rect.x + x];
                    const bit = isMagnitudeBitSet(coeff, bitplane);
                    if (raw) {
                        try encoder.writeBit(bit);
                    } else {
                        const zero_context = nbf_zc_lut[@intFromEnum(band_kind)][pattern];
                        try encoder.write(mqContextIndex(zero_context), bit);
                    }
                    symbol_count += 1;
                    if (bit) {
                        recordSignificanceDistortion(track_distortion, scratch, coeff, bitplane);
                        const negative = coeff < 0;
                        if (raw) {
                            try encoder.writeBit(negative);
                        } else {
                            const sign = nbf_sc_lut[nbfScIndex(sample_flags)];
                            try encoder.write(mqContextIndex(sign.context), negative != sign.predicted_negative);
                        }
                        symbol_count += 1;
                        nbfMarkSignificant(flags, nbs, x, y, negative);
                        setSignificantRow(scratch, x, y);
                    }
                }
            }
        }
    }
    return symbol_count;
}

fn emitDirectIsoRefinementPass(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    encoder: anytype,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    if (comptime !maintain_packed_t1_context_flags) {
        if (!style.vertical_causal) {
            return emitDirectIsoRefinementPassPlain(track_distortion, scratch, encoder, plane, stride, rect, bitplane);
        }
    }

    const raw = comptime @TypeOf(encoder) == *RawBitWriter;
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;
    var stripe_y: usize = 0;
    while (stripe_y < rect.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), rect.height - stripe_y);
        // Nothing significant inside the stripe rows means nothing to refine.
        if (!stripeRowsSignificant(scratch, stripe_y, stripe_height)) continue;
        var x: usize = 0;
        while (x < rect.width) {
            const x_end = @min(x + significant_word_bits, rect.width);
            if (!stripeRowsSignificantRangeDirect(scratch, stripe_y, stripe_height, x, x_end)) {
                x = x_end;
                continue;
            }
            while (x < x_end) : (x += 1) {
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    const y = stripe_y + dy;
                    const p = nbfIndex(nbs, x, y);
                    const decision = directT1RefinementDecision(scratch, x, y, flags[p], style);
                    if (!decision.candidate) continue;
                    const coeff = plane[(rect.y + y) * stride + rect.x + x];
                    const bit = isMagnitudeBitSet(coeff, bitplane);
                    if (raw) {
                        try encoder.writeBit(bit);
                    } else {
                        try encoder.write(mqContextIndex(decision.context), bit);
                    }
                    symbol_count += 1;
                    recordRefinementDistortion(track_distortion, scratch, coeff, bitplane);
                    flags[p] |= nbf_refine;
                    directMarkPackedT1Refined(scratch, x, y);
                }
            }
        }
    }
    return symbol_count;
}

fn emitDirectIsoRefinementPassPlain(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    encoder: anytype,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
) !usize {
    const raw = comptime @TypeOf(encoder) == *RawBitWriter;
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;
    var stripe_y: usize = 0;
    while (stripe_y < rect.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), rect.height - stripe_y);
        if (!stripeRowsSignificant(scratch, stripe_y, stripe_height)) continue;
        var x: usize = 0;
        while (x < rect.width) {
            const x_end = @min(x + significant_word_bits, rect.width);
            if (!stripeRowsSignificantRangeDirect(scratch, stripe_y, stripe_height, x, x_end)) {
                x = x_end;
                continue;
            }
            while (x < x_end) : (x += 1) {
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    const y = stripe_y + dy;
                    const p = nbfIndex(nbs, x, y);
                    const sample_flags = flags[p];
                    if ((sample_flags & nbf_sig_self) == 0 or (sample_flags & nbf_visit) != 0) continue;
                    const coeff = plane[(rect.y + y) * stride + rect.x + x];
                    const bit = isMagnitudeBitSet(coeff, bitplane);
                    if (raw) {
                        try encoder.writeBit(bit);
                    } else {
                        const context = refinementContext((sample_flags & nbf_refine) != 0, @intCast(@popCount(sample_flags & nbf_sig8)));
                        try encoder.write(mqContextIndex(context), bit);
                    }
                    symbol_count += 1;
                    recordRefinementDistortion(track_distortion, scratch, coeff, bitplane);
                    flags[p] |= nbf_refine;
                }
            }
        }
    }
    return symbol_count;
}

fn emitDirectIsoCleanupPass(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    encoder: *mq_iso.Encoder,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    if (comptime !maintain_packed_t1_context_flags) {
        if (!style.vertical_causal) {
            return emitDirectIsoCleanupPassPlain(track_distortion, scratch, encoder, plane, stride, rect, bitplane, style.band_kind, style.segmentation_symbols);
        }
    }

    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;
    var stripe_y: usize = 0;
    while (stripe_y < rect.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), rect.height - stripe_y);
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            if (stripe_height == 4 and directCanUseRunStripeFast(scratch, x, stripe_y, style)) {
                const runlen = cleanupRunLength(plane, stride, rect, x, stripe_y, bitplane);
                try encoder.write(mqContextIndex(.cleanup_aggregation), runlen != 4);
                symbol_count += 1;
                if (runlen == 4) continue;

                try writeCleanupRunLength(encoder, runlen);
                symbol_count += 2;

                {
                    const y = stripe_y + runlen;
                    const sample_flags = flags[nbfIndex(nbs, x, y)];
                    const sign = directT1SignCoding(scratch, x, y, sample_flags, style);
                    const coeff = plane[(rect.y + y) * stride + rect.x + x];
                    recordSignificanceDistortion(track_distortion, scratch, coeff, bitplane);
                    const negative = coeff < 0;
                    try encoder.write(mqContextIndex(sign.context), negative != sign.predicted_negative);
                    symbol_count += 1;
                    nbfMarkSignificant(flags, nbs, x, y, negative);
                    directMarkPackedT1Significant(scratch, x, y, negative);
                    setSignificantRow(scratch, x, y);
                }

                symbol_count += try nbfEmitCleanupSampleRange(track_distortion, scratch, encoder, plane, stride, rect, x, stripe_y, runlen + 1, 4, bitplane, style);
            } else {
                symbol_count += try nbfEmitCleanupSampleRange(track_distortion, scratch, encoder, plane, stride, rect, x, stripe_y, 0, stripe_height, bitplane, style);
            }
        }
    }

    if (style.segmentation_symbols) {
        try writeSegmentationSymbols(encoder);
        symbol_count += 4;
    }
    return symbol_count;
}

fn emitDirectIsoCleanupPassPlain(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    encoder: *mq_iso.Encoder,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    band_kind: subband.Kind,
    segmentation_symbols: bool,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    const band_index = @intFromEnum(band_kind);
    var symbol_count: usize = 0;
    var stripe_y: usize = 0;
    while (stripe_y < rect.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), rect.height - stripe_y);
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            if (stripe_height == 4 and nbfCanUseRunStripePlain(flags, nbs, x, stripe_y)) {
                const runlen = cleanupRunLength(plane, stride, rect, x, stripe_y, bitplane);
                try encoder.write(mqContextIndex(.cleanup_aggregation), runlen != 4);
                symbol_count += 1;
                if (runlen == 4) continue;

                try writeCleanupRunLength(encoder, runlen);
                symbol_count += 2;

                {
                    const y = stripe_y + runlen;
                    const sample_flags = flags[nbfIndex(nbs, x, y)];
                    const coeff = plane[(rect.y + y) * stride + rect.x + x];
                    recordSignificanceDistortion(track_distortion, scratch, coeff, bitplane);
                    try emitDirectCleanupSignPlain(scratch, encoder, plane, stride, rect, flags, nbs, x, y, sample_flags);
                    symbol_count += 1;
                }

                symbol_count += try emitDirectCleanupSampleRangePlainKnown(track_distortion, scratch, encoder, plane, stride, rect, flags, nbs, x, stripe_y, runlen + 1, 4, bitplane, band_index);
            } else {
                symbol_count += try emitDirectCleanupSampleRangePlainKnown(track_distortion, scratch, encoder, plane, stride, rect, flags, nbs, x, stripe_y, 0, stripe_height, bitplane, band_index);
            }
        }
    }

    if (segmentation_symbols) {
        try writeSegmentationSymbols(encoder);
        symbol_count += 4;
    }
    return symbol_count;
}

fn nbfCanUseRunStripe(flags: []const u16, nbs: usize, x: usize, stripe_y: usize, style: CodeBlockStyle) bool {
    var dy: usize = 0;
    while (dy < 4) : (dy += 1) {
        const p = nbfIndex(nbs, x, stripe_y + dy);
        const causal = style.vertical_causal and dy == 3;
        const f = if (causal) flags[p] & nbf_causal_mask else flags[p];
        if ((f & nbf_cleanup_run_blockers) != 0) return false;
    }
    return true;
}

inline fn nbfCanUseRunStripePlain(flags: []const u16, nbs: usize, x: usize, stripe_y: usize) bool {
    const p = nbfIndex(nbs, x, stripe_y);
    const combined = flags[p] | flags[p + nbs] | flags[p + nbs * 2] | flags[p + nbs * 3];
    return (combined & nbf_cleanup_run_blockers) == 0;
}

fn nbfEmitCleanupSample(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    encoder: *mq_iso.Encoder,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    x: usize,
    y: usize,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    const p = nbfIndex(nbs, x, y);
    if ((flags[p] & (nbf_sig_self | nbf_visit)) != 0) return 0;
    const sample_flags = flags[p];
    // Cleanup codes every insignificant, unvisited sample; zero0 is valid.
    const decision = directT1SignificanceDecision(scratch, x, y, sample_flags, style);
    const coeff = plane[(rect.y + y) * stride + rect.x + x];
    const bit = isMagnitudeBitSet(coeff, bitplane);
    try encoder.write(mqContextIndex(decision.zero_context), bit);
    var symbol_count: usize = 1;
    if (bit) {
        recordSignificanceDistortion(track_distortion, scratch, coeff, bitplane);
        const negative = coeff < 0;
        const sign = directT1SignCoding(scratch, x, y, sample_flags, style);
        try encoder.write(mqContextIndex(sign.context), negative != sign.predicted_negative);
        symbol_count += 1;
        nbfMarkSignificant(flags, nbs, x, y, negative);
        directMarkPackedT1Significant(scratch, x, y, negative);
        setSignificantRow(scratch, x, y);
    }
    return symbol_count;
}

inline fn nbfEmitCleanupSampleRange(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    encoder: *mq_iso.Encoder,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    x: usize,
    stripe_y: usize,
    first_dy: usize,
    end_dy: usize,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    var symbol_count: usize = 0;
    var dy = first_dy;
    while (dy < end_dy) : (dy += 1) {
        symbol_count += try nbfEmitCleanupSample(track_distortion, scratch, encoder, plane, stride, rect, x, stripe_y + dy, bitplane, style);
    }
    return symbol_count;
}

fn nbfEmitCleanupSamplePlain(
    scratch: *DirectBlockScratch,
    encoder: *mq_iso.Encoder,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    x: usize,
    y: usize,
    bitplane: u8,
    band_kind: subband.Kind,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    return nbfEmitCleanupSamplePlainKnown(scratch, encoder, plane, stride, rect, flags, nbs, x, y, bitplane, @intFromEnum(band_kind));
}

inline fn nbfEmitCleanupSamplePlainKnown(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    encoder: *mq_iso.Encoder,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    flags: []u16,
    nbs: usize,
    x: usize,
    y: usize,
    bitplane: u8,
    band_index: usize,
) !usize {
    const sample_flags = flags[nbfIndex(nbs, x, y)];
    if ((sample_flags & (nbf_sig_self | nbf_visit)) != 0) return 0;
    const coeff = plane[(rect.y + y) * stride + rect.x + x];
    const bit = isMagnitudeBitSet(coeff, bitplane);
    const zero_context = nbf_zc_lut[band_index][sample_flags & nbf_sig8];
    try encoder.write(mqContextIndex(zero_context), bit);
    var symbol_count: usize = 1;
    if (bit) {
        recordSignificanceDistortion(track_distortion, scratch, coeff, bitplane);
        try emitDirectCleanupSignPlain(scratch, encoder, plane, stride, rect, flags, nbs, x, y, sample_flags);
        symbol_count += 1;
    }
    return symbol_count;
}

inline fn emitDirectCleanupSampleRangePlainKnown(
    comptime track_distortion: bool,
    scratch: *DirectBlockScratch,
    encoder: *mq_iso.Encoder,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    flags: []u16,
    nbs: usize,
    x: usize,
    stripe_y: usize,
    first_dy: usize,
    end_dy: usize,
    bitplane: u8,
    band_index: usize,
) !usize {
    var symbol_count: usize = 0;
    var dy = first_dy;
    while (dy < end_dy) : (dy += 1) {
        symbol_count += try nbfEmitCleanupSamplePlainKnown(track_distortion, scratch, encoder, plane, stride, rect, flags, nbs, x, stripe_y + dy, bitplane, band_index);
    }
    return symbol_count;
}

inline fn emitDirectCleanupSignPlain(
    scratch: *DirectBlockScratch,
    encoder: *mq_iso.Encoder,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    flags: []u16,
    nbs: usize,
    x: usize,
    y: usize,
    sample_flags: u16,
) !void {
    const sign = nbf_sc_lut[nbfScIndex(sample_flags)];
    const negative = plane[(rect.y + y) * stride + rect.x + x] < 0;
    try encoder.write(mqContextIndex(sign.context), negative != sign.predicted_negative);
    nbfMarkSignificant(flags, nbs, x, y, negative);
    setSignificantRow(scratch, x, y);
}

fn appendPass(
    allocator: std.mem.Allocator,
    passes: *std.ArrayList(Pass),
    kind: PassKind,
    bitplane: u8,
    first_symbol: usize,
    end_symbol: usize,
) !void {
    try passes.append(allocator, .{
        .kind = kind,
        .magnitude_bitplane = bitplane,
        .first_symbol = first_symbol,
        .symbol_count = end_symbol - first_symbol,
    });
}

const ScanPos = struct {
    x: usize,
    y: usize,
};

const ScanIterator = struct {
    width: usize,
    height: usize,
    stripe_y: usize = 0,
    x: usize = 0,
    dy: usize = 0,

    fn init(width: usize, height: usize) ScanIterator {
        return .{ .width = width, .height = height };
    }

    fn next(self: *ScanIterator) ?ScanPos {
        while (self.stripe_y < self.height) {
            const stripe_height = @min(@as(usize, 4), self.height - self.stripe_y);
            if (self.x < self.width and self.dy < stripe_height) {
                const pos = ScanPos{ .x = self.x, .y = self.stripe_y + self.dy };
                self.dy += 1;
                if (self.dy == stripe_height) {
                    self.dy = 0;
                    self.x += 1;
                }
                return pos;
            }

            self.stripe_y += 4;
            self.x = 0;
            self.dy = 0;
        }
        return null;
    }
};

fn validateBlock(plane: []const i32, stride: usize, rect: subband.Rect) !void {
    if (stride == 0 or rect.width == 0 or rect.height == 0) return EbcotError.InvalidBlock;
    if (try blockArea(rect) > max_codeblock_area) return EbcotError.InvalidBlock;
    if (rect.y >= plane.len / stride or rect.x >= stride) return EbcotError.InvalidBlock;
    const last_row = rect.y + rect.height - 1;
    const last_col = rect.x + rect.width - 1;
    if (last_col >= stride or last_row >= plane.len / stride) return EbcotError.InvalidBlock;
}

const BlockStats = struct {
    bitplanes: u8,
    non_zero_count: u32,
};

fn blockStats(plane: []const i32, stride: usize, rect: subband.Rect) BlockStats {
    var max_mag: u32 = 0;
    var non_zero_count: u32 = 0;
    var y: usize = 0;
    while (y < rect.height) : (y += 1) {
        const row = (rect.y + y) * stride + rect.x;
        var x: usize = 0;
        while (x + stats_lanes <= rect.width) : (x += stats_lanes) {
            const chunk = blockStatsChunk(plane[row + x ..][0..stats_lanes]);
            max_mag = @max(max_mag, chunk.max_mag);
            non_zero_count += @popCount(chunk.mask);
        }
        while (x < rect.width) : (x += 1) {
            const mag = magnitude(plane[row + x]);
            max_mag = @max(max_mag, mag);
            if (mag != 0) non_zero_count += 1;
        }
    }
    return .{
        .bitplanes = bitPlaneCount(max_mag),
        .non_zero_count = non_zero_count,
    };
}

const BlockStatsChunk = struct {
    mask: u32,
    max_mag: u32,
};

fn blockStatsChunk(values: *const [stats_lanes]i32) BlockStatsChunk {
    const coeffs: StatsVector = values.*;
    const zero: StatsVector = @splat(0);
    const abs_values = @select(i32, coeffs < zero, -coeffs, coeffs);
    const max_mag = @as(u32, @intCast(@reduce(.Max, abs_values)));
    const non_zero = coeffs != zero;
    const mask = @reduce(.Or, @select(u32, non_zero, stats_lane_masks, @as(StatsMaskVector, @splat(0))));
    return .{ .mask = mask, .max_mag = max_mag };
}

fn makeStatsLaneMasks() StatsMaskVector {
    var masks: [stats_lanes]u32 = undefined;
    inline for (0..stats_lanes) |lane| {
        masks[lane] = @as(u32, 1) << @as(u5, @intCast(lane));
    }
    return masks;
}

fn blockArea(rect: subband.Rect) !usize {
    return std.math.mul(usize, rect.width, rect.height) catch EbcotError.InvalidBlock;
}

fn neighborMaxY(height: usize, y: usize, style: CodeBlockStyle) usize {
    if (style.vertical_causal and (y & 3) == 3) return y;
    return @min(height - 1, y + 1);
}

fn neighborSignificance(significant: []const bool, width: usize, height: usize, x: usize, y: usize, style: CodeBlockStyle) u4 {
    var count: u4 = 0;
    const min_y = if (y == 0) 0 else y - 1;
    const max_y = neighborMaxY(height, y, style);
    const min_x = if (x == 0) 0 else x - 1;
    const max_x = @min(width - 1, x + 1);

    var yy = min_y;
    while (yy <= max_y) : (yy += 1) {
        var xx = min_x;
        while (xx <= max_x) : (xx += 1) {
            if (xx == x and yy == y) continue;
            if (significant[localIndex(width, xx, yy)]) count += 1;
        }
    }
    return count;
}

fn zeroContextFromSlice(significant: []const bool, width: usize, height: usize, x: usize, y: usize, style: CodeBlockStyle) Context {
    return zeroContextFromCounts(neighborCountsFromSlice(significant, width, height, x, y, style), style.band_kind);
}

fn zeroContextRows(scratch: *const DirectBlockScratch, x: usize, y: usize, style: CodeBlockStyle) Context {
    return zeroContextFromCounts(neighborCountsRows(scratch, x, y, style), style.band_kind);
}

fn zeroContextRowsDecode(scratch: *const DecodeBlockScratch, x: usize, y: usize, style: CodeBlockStyle) Context {
    return zeroContextFromCounts(neighborCountsRowsDecode(scratch, x, y, style), style.band_kind);
}

fn zeroContextFromCounts(counts: NeighborCounts, band_kind: subband.Kind) Context {
    var h = counts.horizontal;
    var v = counts.vertical;
    const d = counts.diagonal;

    switch (band_kind) {
        // ISO/IEC 15444-1 Table D.1: the HL (horizontally high-pass) subband
        // swaps the roles of horizontal and vertical neighbor sums; LL and LH
        // share the plain table.
        .hl => {
            const tmp = h;
            h = v;
            v = tmp;
        },
        .hh => {
            const hv = h + v;
            const index: usize = if (d == 0)
                if (hv == 0) 0 else if (hv == 1) 1 else 2
            else if (d == 1)
                if (hv == 0) 3 else if (hv == 1) 4 else 5
            else if (d == 2)
                if (hv == 0) 6 else 7
            else
                8;
            return zero_context_lut[index];
        },
        .ll, .lh => {},
    }

    const index: usize = if (h == 0)
        if (v == 0)
            if (d == 0) 0 else if (d == 1) 1 else 2
        else if (v == 1)
            3
        else
            4
    else if (h == 1)
        if (v == 0)
            if (d == 0) 5 else 6
        else
            7
    else
        8;
    return zero_context_lut[index];
}

fn neighborCountsFromSlice(significant: []const bool, width: usize, height: usize, x: usize, y: usize, style: CodeBlockStyle) NeighborCounts {
    var counts = NeighborCounts{};
    if (x > 0 and significant[localIndex(width, x - 1, y)]) counts.horizontal += 1;
    if (x + 1 < width and significant[localIndex(width, x + 1, y)]) counts.horizontal += 1;
    if (y > 0 and significant[localIndex(width, x, y - 1)]) counts.vertical += 1;
    if (y + 1 <= neighborMaxY(height, y, style) and significant[localIndex(width, x, y + 1)]) counts.vertical += 1;
    const min_y = if (y == 0) 0 else y - 1;
    const max_y = neighborMaxY(height, y, style);
    const min_x = if (x == 0) 0 else x - 1;
    const max_x = @min(width - 1, x + 1);
    var yy = min_y;
    while (yy <= max_y) : (yy += 1) {
        var xx = min_x;
        while (xx <= max_x) : (xx += 1) {
            if (xx == x or yy == y) continue;
            if (significant[localIndex(width, xx, yy)]) counts.diagonal += 1;
        }
    }
    return counts;
}

fn neighborCountsRows(scratch: *const DirectBlockScratch, x: usize, y: usize, style: CodeBlockStyle) NeighborCounts {
    var counts = NeighborCounts{};
    if (x > 0 and hasSignificantRow(scratch, x - 1, y)) counts.horizontal += 1;
    if (x + 1 < scratch.width and hasSignificantRow(scratch, x + 1, y)) counts.horizontal += 1;
    if (y > 0 and hasSignificantRow(scratch, x, y - 1)) counts.vertical += 1;
    if (y + 1 <= neighborMaxY(scratch.height, y, style) and hasSignificantRow(scratch, x, y + 1)) counts.vertical += 1;
    const min_y = if (y == 0) 0 else y - 1;
    const max_y = neighborMaxY(scratch.height, y, style);
    const min_x = if (x == 0) 0 else x - 1;
    const max_x = @min(scratch.width - 1, x + 1);
    var yy = min_y;
    while (yy <= max_y) : (yy += 1) {
        var xx = min_x;
        while (xx <= max_x) : (xx += 1) {
            if (xx == x or yy == y) continue;
            if (hasSignificantRow(scratch, xx, yy)) counts.diagonal += 1;
        }
    }
    return counts;
}

fn neighborCountsRowsDecode(scratch: *const DecodeBlockScratch, x: usize, y: usize, style: CodeBlockStyle) NeighborCounts {
    var counts = NeighborCounts{};
    if (x > 0 and hasSignificantRowDecode(scratch, x - 1, y)) counts.horizontal += 1;
    if (x + 1 < scratch.width and hasSignificantRowDecode(scratch, x + 1, y)) counts.horizontal += 1;
    if (y > 0 and hasSignificantRowDecode(scratch, x, y - 1)) counts.vertical += 1;
    if (y + 1 <= neighborMaxY(scratch.height, y, style) and hasSignificantRowDecode(scratch, x, y + 1)) counts.vertical += 1;
    const min_y = if (y == 0) 0 else y - 1;
    const max_y = neighborMaxY(scratch.height, y, style);
    const min_x = if (x == 0) 0 else x - 1;
    const max_x = @min(scratch.width - 1, x + 1);
    var yy = min_y;
    while (yy <= max_y) : (yy += 1) {
        var xx = min_x;
        while (xx <= max_x) : (xx += 1) {
            if (xx == x or yy == y) continue;
            if (hasSignificantRowDecode(scratch, xx, yy)) counts.diagonal += 1;
        }
    }
    return counts;
}

fn refinementContext(already_refined: bool, neighbors: u4) Context {
    if (already_refined) return .refinement_later;
    return if (neighbors == 0) .refinement else .refinement_neighbor;
}

fn makeZeroContextLut() [9]Context {
    var lut: [9]Context = undefined;
    for (&lut, 0..) |*context, index| {
        context.* = @enumFromInt(index);
    }
    return lut;
}

fn makeSignContextLut() [5]Context {
    return .{ .sign0, .sign1, .sign2, .sign3, .sign4 };
}

fn signCoding(
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    x: usize,
    y: usize,
    significant: []const bool,
    style: CodeBlockStyle,
) SignCoding {
    var horizontal: i8 = 0;
    var vertical: i8 = 0;
    if (x > 0 and significant[localIndex(rect.width, x - 1, y)]) {
        horizontal += signContribution(plane[(rect.y + y) * stride + rect.x + x - 1]);
    }
    if (x + 1 < rect.width and significant[localIndex(rect.width, x + 1, y)]) {
        horizontal += signContribution(plane[(rect.y + y) * stride + rect.x + x + 1]);
    }
    if (y > 0 and significant[localIndex(rect.width, x, y - 1)]) {
        vertical += signContribution(plane[(rect.y + y - 1) * stride + rect.x + x]);
    }
    if (y + 1 <= neighborMaxY(rect.height, y, style) and significant[localIndex(rect.width, x, y + 1)]) {
        vertical += signContribution(plane[(rect.y + y + 1) * stride + rect.x + x]);
    }
    return signCodingFromContributions(horizontal, vertical);
}

fn signCodingRows(
    scratch: *const DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    x: usize,
    y: usize,
    style: CodeBlockStyle,
) SignCoding {
    var horizontal: i8 = 0;
    var vertical: i8 = 0;
    if (x > 0 and hasSignificantRow(scratch, x - 1, y)) {
        horizontal += signContribution(plane[(rect.y + y) * stride + rect.x + x - 1]);
    }
    if (x + 1 < rect.width and hasSignificantRow(scratch, x + 1, y)) {
        horizontal += signContribution(plane[(rect.y + y) * stride + rect.x + x + 1]);
    }
    if (y > 0 and hasSignificantRow(scratch, x, y - 1)) {
        vertical += signContribution(plane[(rect.y + y - 1) * stride + rect.x + x]);
    }
    if (y + 1 <= neighborMaxY(rect.height, y, style) and hasSignificantRow(scratch, x, y + 1)) {
        vertical += signContribution(plane[(rect.y + y + 1) * stride + rect.x + x]);
    }
    return signCodingFromContributions(horizontal, vertical);
}

fn signCodingFromContributions(horizontal_score: i8, vertical_score: i8) SignCoding {
    var horizontal = clampSignContribution(horizontal_score);
    var vertical = clampSignContribution(vertical_score);
    const predicted_negative = if (horizontal == 0 and vertical == 0)
        false
    else
        !(horizontal > 0 or (horizontal == 0 and vertical > 0));

    if (horizontal < 0) {
        horizontal = -horizontal;
        vertical = -vertical;
    }

    const context_index: usize = if (horizontal == 0)
        if (vertical == 0) 0 else 1
    else if (vertical < 0)
        2
    else if (vertical == 0)
        3
    else
        4;

    return .{
        .context = sign_context_lut[context_index],
        .predicted_negative = predicted_negative,
    };
}

fn clampSignContribution(score: i8) i8 {
    if (score < 0) return -1;
    if (score > 0) return 1;
    return 0;
}

fn signContribution(value: i32) i8 {
    return if (value < 0) -1 else 1;
}

fn signCodingRowsDecode(scratch: *const DecodeBlockScratch, x: usize, y: usize, style: CodeBlockStyle) SignCoding {
    var horizontal: i8 = 0;
    var vertical: i8 = 0;
    if (x > 0 and hasSignificantRowDecode(scratch, x - 1, y)) {
        horizontal += signContribution(scratch.coeffs.items[localIndex(scratch.width, x - 1, y)]);
    }
    if (x + 1 < scratch.width and hasSignificantRowDecode(scratch, x + 1, y)) {
        horizontal += signContribution(scratch.coeffs.items[localIndex(scratch.width, x + 1, y)]);
    }
    if (y > 0 and hasSignificantRowDecode(scratch, x, y - 1)) {
        vertical += signContribution(scratch.coeffs.items[localIndex(scratch.width, x, y - 1)]);
    }
    if (y + 1 <= neighborMaxY(scratch.height, y, style) and hasSignificantRowDecode(scratch, x, y + 1)) {
        vertical += signContribution(scratch.coeffs.items[localIndex(scratch.width, x, y + 1)]);
    }
    return signCodingFromContributions(horizontal, vertical);
}

fn flagMask(kind: FlagKind) u8 {
    return switch (kind) {
        .significant => flag_significant,
        .visited => flag_visited,
        .became_significant => flag_became_significant,
        .refined => flag_refined,
    };
}

inline fn hasFlag(flags: []const u8, index: usize, kind: FlagKind) bool {
    return (flags[index] & flagMask(kind)) != 0;
}

inline fn setFlag(flags: []u8, index: usize, kind: FlagKind) void {
    flags[index] |= flagMask(kind);
}

fn clearFlag(flags: []u8, kind: FlagKind) void {
    const mask = ~flagMask(kind);
    const mask_vec: FlagClearVector = @splat(mask);
    var index: usize = 0;
    while (index + flag_clear_lanes <= flags.len) : (index += flag_clear_lanes) {
        clearFlagChunk(flags[index..][0..flag_clear_lanes], mask_vec);
    }
    while (index < flags.len) : (index += 1) {
        flags[index] &= mask;
    }
}

fn clearFlagChunk(values: *[flag_clear_lanes]u8, mask: FlagClearVector) void {
    const chunk: FlagClearVector = values.*;
    values.* = chunk & mask;
}

inline fn rowWordCount(width: usize) usize {
    return (width + significant_word_bits - 1) / significant_word_bits;
}

inline fn significantWordIndex(scratch: *const DirectBlockScratch, x: usize, y: usize) usize {
    return y * scratch.row_words + x / significant_word_bits;
}

inline fn significantBit(x: usize) u64 {
    return @as(u64, 1) << @as(u6, @intCast(x & (significant_word_bits - 1)));
}

inline fn hasSignificantRow(scratch: *const DirectBlockScratch, x: usize, y: usize) bool {
    return (scratch.significant_words.items[significantWordIndex(scratch, x, y)] & significantBit(x)) != 0;
}

inline fn setSignificantRow(scratch: *DirectBlockScratch, x: usize, y: usize) void {
    scratch.significant_words.items[significantWordIndex(scratch, x, y)] |= significantBit(x);
}

inline fn significantWordIndexDecode(scratch: *const DecodeBlockScratch, x: usize, y: usize) usize {
    return y * scratch.row_words + x / significant_word_bits;
}

inline fn hasSignificantRowDecode(scratch: *const DecodeBlockScratch, x: usize, y: usize) bool {
    return (scratch.significant_words.items[significantWordIndexDecode(scratch, x, y)] & significantBit(x)) != 0;
}

inline fn setSignificantRowDecode(scratch: *DecodeBlockScratch, x: usize, y: usize) void {
    scratch.significant_words.items[significantWordIndexDecode(scratch, x, y)] |= significantBit(x);
}

fn neighborSignificanceRows(scratch: *const DirectBlockScratch, x: usize, y: usize, style: CodeBlockStyle) u4 {
    var count: u4 = 0;
    const min_y = if (y == 0) 0 else y - 1;
    const max_y = neighborMaxY(scratch.height, y, style);
    const min_x = if (x == 0) 0 else x - 1;
    const max_x = @min(scratch.width - 1, x + 1);
    const first_word = min_x / significant_word_bits;
    const last_word = max_x / significant_word_bits;

    var yy = min_y;
    while (yy <= max_y) : (yy += 1) {
        const row_start = yy * scratch.row_words;
        var word = first_word;
        while (word <= last_word) : (word += 1) {
            const word_min_x = word * significant_word_bits;
            const lo = if (min_x > word_min_x) min_x - word_min_x else 0;
            const hi = @min(max_x - word_min_x, significant_word_bits - 1);
            var mask = bitRangeMask(lo, hi);
            if (yy == y and word == x / significant_word_bits) mask &= ~significantBit(x);
            count += @intCast(@popCount(scratch.significant_words.items[row_start + word] & mask));
        }
    }
    return count;
}

fn neighborSignificanceRowsDecode(scratch: *const DecodeBlockScratch, x: usize, y: usize, style: CodeBlockStyle) u4 {
    var count: u4 = 0;
    const min_y = if (y == 0) 0 else y - 1;
    const max_y = neighborMaxY(scratch.height, y, style);
    const min_x = if (x == 0) 0 else x - 1;
    const max_x = @min(scratch.width - 1, x + 1);
    const first_word = min_x / significant_word_bits;
    const last_word = max_x / significant_word_bits;

    var yy = min_y;
    while (yy <= max_y) : (yy += 1) {
        const row_start = yy * scratch.row_words;
        var word = first_word;
        while (word <= last_word) : (word += 1) {
            const word_min_x = word * significant_word_bits;
            const lo = if (min_x > word_min_x) min_x - word_min_x else 0;
            const hi = @min(max_x - word_min_x, significant_word_bits - 1);
            var mask = bitRangeMask(lo, hi);
            if (yy == y and word == x / significant_word_bits) mask &= ~significantBit(x);
            count += @intCast(@popCount(scratch.significant_words.items[row_start + word] & mask));
        }
    }
    return count;
}

fn markDecodedSignificant(scratch: *DecodeBlockScratch, x: usize, y: usize, bitplane: u8, negative: bool) void {
    const index = localIndex(scratch.width, x, y);
    // ISO-conventional midpoint reconstruction (matches OpenJPEG): a newly
    // significant sample at plane p is reconstructed at 1.5 * 2^p, the
    // midpoint of its uncertainty interval [2^p, 2^(p+1)). Each refinement
    // re-centers the half at the new plane, so a fully decoded sample ends
    // exact (half = 0 at plane 0) and a truncated one carries m + 2^(p-1).
    const one = @as(i32, 1) << @as(u5, @intCast(bitplane));
    const half = if (bitplane > 0) @as(i32, 1) << @as(u5, @intCast(bitplane - 1)) else 0;
    const magnitude_bit = one | half;
    scratch.coeffs.items[index] = if (negative) -magnitude_bit else magnitude_bit;
    setFlag(scratch.flags.items, index, .significant);
    setFlag(scratch.flags.items, index, .became_significant);
    setSignificantRowDecode(scratch, x, y);
    nbfMarkSignificant(scratch.nb_flags.items, scratch.nb_stride, x, y, negative);
    decodeMarkPackedT1Significant(scratch, x, y, negative);
}

fn markDecodedSignificantNbf(scratch: *DecodeBlockScratch, x: usize, y: usize, bitplane: u8, negative: bool) void {
    const index = localIndex(scratch.width, x, y);
    // ISO-conventional midpoint reconstruction (matches OpenJPEG): a newly
    // significant sample at plane p is reconstructed at 1.5 * 2^p, the
    // midpoint of its uncertainty interval [2^p, 2^(p+1)). Each refinement
    // re-centers the half at the new plane, so a fully decoded sample ends
    // exact (half = 0 at plane 0) and a truncated one carries m + 2^(p-1).
    const one = @as(i32, 1) << @as(u5, @intCast(bitplane));
    const half = if (bitplane > 0) @as(i32, 1) << @as(u5, @intCast(bitplane - 1)) else 0;
    const magnitude_bit = one | half;
    scratch.coeffs.items[index] = if (negative) -magnitude_bit else magnitude_bit;
    setSignificantRowDecode(scratch, x, y);
    nbfMarkSignificant(scratch.nb_flags.items, scratch.nb_stride, x, y, negative);
    decodeMarkPackedT1Significant(scratch, x, y, negative);
}

inline fn markDecodedSignificantNbfKnown(
    scratch: *DecodeBlockScratch,
    flags: []u16,
    nbs: usize,
    x: usize,
    y: usize,
    bitplane: u8,
    negative: bool,
) void {
    const index = localIndex(scratch.width, x, y);
    // ISO-conventional midpoint reconstruction (matches OpenJPEG): a newly
    // significant sample at plane p is reconstructed at 1.5 * 2^p, the
    // midpoint of its uncertainty interval [2^p, 2^(p+1)). Each refinement
    // re-centers the half at the new plane, so a fully decoded sample ends
    // exact (half = 0 at plane 0) and a truncated one carries m + 2^(p-1).
    const one = @as(i32, 1) << @as(u5, @intCast(bitplane));
    const half = if (bitplane > 0) @as(i32, 1) << @as(u5, @intCast(bitplane - 1)) else 0;
    const magnitude_bit = one | half;
    scratch.coeffs.items[index] = if (negative) -magnitude_bit else magnitude_bit;
    setSignificantRowDecode(scratch, x, y);
    nbfMarkSignificant(flags, nbs, x, y, negative);
    decodeMarkPackedT1Significant(scratch, x, y, negative);
}

/// Refinement update with midpoint re-centering (matches OpenJPEG): before
/// this pass the sample sits at the plane-(p+1) midpoint m_hi + 2^p; after
/// reading bit b at plane p the new midpoint is m_hi + b*2^p + 2^(p-1), a
/// delta of +2^(p-1) for b = 1 and -2^(p-1) for b = 0. At plane 0 the value
/// becomes exact: +0 for b = 1, -1 for b = 0.
inline fn refineMagnitude(scratch: *DecodeBlockScratch, index: usize, bitplane: u8, bit: bool) void {
    const delta: i32 = if (bitplane > 0)
        (if (bit) @as(i32, 1) << @as(u5, @intCast(bitplane - 1)) else -(@as(i32, 1) << @as(u5, @intCast(bitplane - 1))))
    else
        (if (bit) 0 else -1);
    if (scratch.coeffs.items[index] < 0) {
        scratch.coeffs.items[index] -= delta;
    } else {
        scratch.coeffs.items[index] += delta;
    }
}

fn validatePassPayload(
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    expected_kind: PassKind,
    expected_bitplane: u8,
) !void {
    if (pass.kind != expected_kind or pass.magnitude_bitplane != expected_bitplane) return EbcotError.InvalidBlock;
    const byte_end = std.math.add(usize, pass.byte_offset, pass.byte_length) catch return EbcotError.InvalidBlock;
    if (byte_end > bytes.len) return EbcotError.InvalidBlock;
    if (pass.cumulative_bytes != byte_end) return EbcotError.InvalidBlock;
}

fn isoPassDecoder(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
) !mq_iso.Decoder {
    const byte_end = std.math.add(usize, pass.byte_offset, pass.byte_length) catch return EbcotError.InvalidBlock;
    if (byte_end > bytes.len) return EbcotError.InvalidBlock;
    const previous_byte = if (pass.byte_offset == 0) 0 else bytes[pass.byte_offset - 1];
    var decoder = try mq_iso.Decoder.initAfterPreviousByte(scratch.allocator, mq_context_count, bytes[pass.byte_offset..byte_end], previous_byte);
    errdefer decoder.deinit();
    try decoder.resetJpeg2000Contexts();
    return decoder;
}

fn passDecoderWithContexts(
    scratch: *DecodeBlockScratch,
    pass: CodeBlockPassPayload,
    bytes: []const u8,
    contexts: []mq.ContextSnapshot,
    style: CodeBlockStyle,
    pass_index: u16,
) !mq.Decoder {
    const byte_end = std.math.add(usize, pass.byte_offset, pass.byte_length) catch return EbcotError.InvalidBlock;
    if (byte_end > bytes.len) return EbcotError.InvalidBlock;
    if (contexts.len != mq_context_count) return EbcotError.InvalidBlock;
    if (style.reset_context and pass_index != 0) @memset(contexts, .{});

    var decoder = try mq.Decoder.init(scratch.allocator, mq_context_count, bytes[pass.byte_offset..byte_end], pass.symbol_count);
    errdefer decoder.deinit();
    try decoder.importContexts(contexts);
    return decoder;
}

inline fn bitRangeMask(lo: usize, hi: usize) u64 {
    const all: u64 = std.math.maxInt(u64);
    const lower = all << @as(u6, @intCast(lo));
    const upper = if (hi == 63)
        all
    else
        (@as(u64, 1) << @as(u6, @intCast(hi + 1))) - 1;
    return lower & upper;
}

fn neighborSignificanceFlags(flags: []const u8, width: usize, height: usize, x: usize, y: usize) u4 {
    var count: u4 = 0;
    const min_y = if (y == 0) 0 else y - 1;
    const max_y = @min(height - 1, y + 1);
    const min_x = if (x == 0) 0 else x - 1;
    const max_x = @min(width - 1, x + 1);

    var yy = min_y;
    while (yy <= max_y) : (yy += 1) {
        var xx = min_x;
        while (xx <= max_x) : (xx += 1) {
            if (xx == x and yy == y) continue;
            if (hasFlag(flags, localIndex(width, xx, yy), .significant)) count += 1;
        }
    }
    return count;
}

inline fn localIndex(width: usize, x: usize, y: usize) usize {
    return y * width + x;
}

fn bitPlaneCount(max_mag: u32) u8 {
    if (max_mag == 0) return 0;
    return @as(u8, @intCast(32 - @clz(max_mag)));
}

inline fn magnitude(value: i32) u32 {
    const wide = @as(i64, value);
    const abs = if (wide < 0) -wide else wide;
    return @as(u32, @intCast(abs));
}

inline fn isMagnitudeBitSet(value: i32, bitplane: u8) bool {
    return ((magnitude(value) >> @as(u5, @intCast(bitplane))) & 1) != 0;
}
