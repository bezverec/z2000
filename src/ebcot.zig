const std = @import("std");
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
        return self.predictable_termination;
    }
};

/// Legacy single-segment coders do not understand BYPASS payload layout, so
/// they keep rejecting it; only the bypass-aware segment coders accept it.
fn validateImplementedStyle(style: CodeBlockStyle) !void {
    if (style.hasUnsupportedPayloadMode() or style.bypass) return EbcotError.InvalidBlock;
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
/// Vertical causal mode hides the row below the current stripe: mask the
/// south / south-east / south-west significance and the south sign.
const nbf_causal_mask: u16 = ~(nbf_sig_s | nbf_sig_se | nbf_sig_sw | nbf_sgn_s);

fn nbfStride(width: usize) usize {
    return width + 2;
}

fn nbfIndex(stride: usize, x: usize, y: usize) usize {
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
    encoder: ?mq.Encoder = null,
    iso_encoder: ?mq_iso.Encoder = null,
    raw_writer: ?RawBitWriter = null,

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
        self.* = undefined;
    }

    fn reset(self: *DirectBlockScratch) void {
        self.pass_payloads.clearRetainingCapacity();
        self.bytes.clearRetainingCapacity();
        self.segments.clearRetainingCapacity();
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
        bits[index] = try decoder.read(mqContextIndex(symbol.context));
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
        bits[index] = try decoder.read(mqContextIndex(symbol.context));
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
    for (block.passes) |pass| {
        if (symbol_offset + pass.symbol_count > block.symbols.len) return EbcotError.InvalidBlock;
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

    const encoded = try encoder.finish();
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

    fn byteAt(self: RawBitReader, index: usize) u8 {
        if (index < self.bytes.len) return self.bytes[index];
        return 0xff;
    }

    fn readBit(self: *RawBitReader) bool {
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
    if (!style.bypass or style.terminate_all or style.reset_context) return EbcotError.InvalidBlock;
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
            const encoded = if (segment_is_raw) try raw.finish() else try encoder.finish();
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
    var pass_payloads: std.ArrayList(CodeBlockPassPayload) = .empty;
    errdefer pass_payloads.deinit(allocator);
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
        symbol_offset += pass.symbol_count;
        encoder.resetSegmentRetainingContexts();
    }
    if (symbol_offset != block.symbols.len) return EbcotError.InvalidBlock;

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

    const expected_passes = expectedCodingPasses(segment.bitplanes);
    if (segment.pass_count != expected_passes) return EbcotError.InvalidBlock;

    try scratch.ensureBlockState(width, height, area);
    @memset(scratch.flags.items, 0);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
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
    if (pass_count != expected_passes) return EbcotError.InvalidBlock;

    try scratch.ensureBlockState(width, height, area);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
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
        nbfClearVisit(scratch.nb_flags.items);

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
    if (pass_count != expected_passes) return EbcotError.InvalidBlock;

    try scratch.ensureBlockState(width, height, area);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);
    @memset(scratch.coeffs.items, 0);

    const decoder = try scratch.isoMqDecoder(bytes);

    var decoded_symbols: usize = 0;
    var pass_index: u16 = 0;
    var bitplane_index = bitplanes;
    while (bitplane_index > 0 and pass_index < pass_count) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        nbfClearVisit(scratch.nb_flags.items);

        if (bitplane == bitplanes - 1) {
            resetInferredContinuousPassContexts(style, decoder, pass_index);
            decoded_symbols = try std.math.add(usize, decoded_symbols, try decodeCleanupPassInferred(scratch, decoder, bitplane, style));
            pass_index += 1;
            continue;
        }

        resetInferredContinuousPassContexts(style, decoder, pass_index);
        decoded_symbols = try std.math.add(usize, decoded_symbols, try decodeSignificancePassInferred(scratch, decoder, bitplane, style));
        pass_index += 1;
        if (pass_index >= pass_count) break;

        resetInferredContinuousPassContexts(style, decoder, pass_index);
        decoded_symbols = try std.math.add(usize, decoded_symbols, try decodeRefinementPassInferred(scratch, decoder, bitplane, style));
        pass_index += 1;
        if (pass_index >= pass_count) break;

        resetInferredContinuousPassContexts(style, decoder, pass_index);
        decoded_symbols = try std.math.add(usize, decoded_symbols, try decodeCleanupPassInferred(scratch, decoder, bitplane, style));
        pass_index += 1;
    }
    if (pass_index != pass_count or decoded_symbols == 0) return EbcotError.InvalidBlock;

    return scratch.allocator.dupe(i32, scratch.coeffs.items);
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
    try validateImplementedStyleAllowBypass(style);
    if (!style.bypass or style.terminate_all or style.reset_context) return EbcotError.InvalidBlock;
    if (width == 0 or height == 0) return EbcotError.InvalidBlock;
    const area = std.math.mul(usize, width, height) catch return EbcotError.InvalidBlock;
    if (area > max_codeblock_area) return EbcotError.InvalidBlock;
    if (bitplanes == 0) {
        if (pass_count != 0 or bytes.len != 0 or segment_lengths.len != 0) return EbcotError.InvalidBlock;
        const out = try scratch.allocator.alloc(i32, area);
        @memset(out, 0);
        return out;
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
    @memset(scratch.coeffs.items, 0);

    var mq_decoder: ?*mq_iso.Decoder = null;
    var raw_reader = RawBitReader.init(&.{});

    var seg_index: usize = 0;
    var seg_offset: usize = 0;
    var seg_passes_left: u16 = 0;
    var seg_is_raw = false;

    var pass_index: u16 = 0;
    var bitplane_index = bitplanes;
    while (bitplane_index > 0 and pass_index < pass_count) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        nbfClearVisit(scratch.nb_flags.items);

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

            switch (kind) {
                .significance => {
                    if (is_raw) {
                        try decodeSignificancePassRaw(scratch, &raw_reader, bitplane, style);
                    } else {
                        _ = try decodeSignificancePassInferred(scratch, mq_decoder.?, bitplane, style);
                    }
                },
                .refinement => {
                    if (is_raw) {
                        try decodeRefinementPassRaw(scratch, &raw_reader, bitplane, style);
                    } else {
                        _ = try decodeRefinementPassInferred(scratch, mq_decoder.?, bitplane, style);
                    }
                },
                .cleanup => {
                    if (is_raw) return EbcotError.InvalidBlock;
                    _ = try decodeCleanupPassInferred(scratch, mq_decoder.?, bitplane, style);
                },
            }
            pass_index += 1;
            seg_passes_left -= 1;
        }
    }
    if (pass_index != pass_count or seg_index != seg_count or seg_passes_left != 0) {
        return EbcotError.InvalidBlock;
    }

    return scratch.allocator.dupe(i32, scratch.coeffs.items);
}

fn decodeSignificancePassRaw(
    scratch: *DecodeBlockScratch,
    reader: *RawBitReader,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
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
                    const causal = style.vertical_causal and dy == 3;
                    const f = if (causal) flags[sample_flags_index] & nbf_causal_mask else flags[sample_flags_index];
                    if ((f & nbf_sig_self) != 0 or (f & nbf_sig8) == 0) continue;
                    flags[sample_flags_index] |= nbf_visit;
                    if (reader.readBit()) {
                        const negative = reader.readBit();
                        markDecodedSignificantNbf(scratch, x, y, bitplane, negative);
                    }
                }
            }
        }
    }
}

fn decodeRefinementPassRaw(
    scratch: *DecodeBlockScratch,
    reader: *RawBitReader,
    bitplane: u8,
    style: CodeBlockStyle,
) !void {
    _ = style;
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
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
                    const f = flags[sample_flags_index];
                    if ((f & nbf_sig_self) == 0 or (f & nbf_visit) != 0) continue;
                    const bit = reader.readBit();
                    flags[sample_flags_index] |= nbf_refine;
                    if (bit) addMagnitudeBit(scratch, sample_coeff_index, bitplane);
                }
            }
        }
    }
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
    if (style.reset_context and pass_index != 0) decoder.resetContexts();
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
        const bit = try decoder.read(mqContextIndex(zeroContextRowsDecode(scratch, pos.x, pos.y, style)));
        symbol_count += 1;
        if (bit) {
            const sign = signCodingRowsDecode(scratch, pos.x, pos.y, style);
            const sign_bit = try decoder.read(mqContextIndex(sign.context));
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
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    const band: usize = @intFromEnum(style.band_kind);
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
                    const causal = style.vertical_causal and dy == 3;
                    const f = if (causal) flags[p] & nbf_causal_mask else flags[p];
                    if ((f & nbf_sig_self) != 0 or (f & nbf_sig8) == 0) continue;
                    flags[p] |= nbf_visit;
                    const bit = try decoder.read(mqContextIndex(nbf_zc_lut[band][f & nbf_sig8]));
                    symbol_count += 1;
                    if (bit) {
                        const sign = nbf_sc_lut[nbfScIndex(f)];
                        const sign_bit = try decoder.read(mqContextIndex(sign.context));
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
        const bit = try decoder.read(mqContextIndex(refinementContext(hasFlag(scratch.flags.items, index, .refined), neighborSignificanceRowsDecode(scratch, pos.x, pos.y, style))));
        symbol_count += 1;
        setFlag(scratch.flags.items, index, .refined);
        if (bit) addMagnitudeBit(scratch, index, bitplane);
    }

    if (symbol_count != pass.symbol_count) return EbcotError.InvalidBlock;
}

fn decodeRefinementPassInferred(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
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
                    const causal = style.vertical_causal and dy == 3;
                    const f = if (causal) flags[p] & nbf_causal_mask else flags[p];
                    if ((f & nbf_sig_self) == 0 or (f & nbf_visit) != 0) continue;
                    const context: Context = if ((f & nbf_refine) != 0)
                        .refinement_later
                    else if ((f & nbf_sig8) != 0)
                        .refinement_neighbor
                    else
                        .refinement;
                    const bit = try decoder.read(mqContextIndex(context));
                    symbol_count += 1;
                    flags[p] |= nbf_refine;
                    if (bit) addMagnitudeBit(scratch, localIndex(scratch.width, x, y), bitplane);
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
                const agg = try decoder.read(mqContextIndex(.cleanup_aggregation));
                symbol_count += 1;
                if (!agg) continue;

                const runlen = try readCleanupRunLength(decoder);
                symbol_count += 2;
                if (runlen >= 4) return EbcotError.InvalidBlock;

                const y = stripe_y + runlen;
                const sign = signCodingRowsDecode(scratch, x, y, style);
                const sign_bit = try decoder.read(mqContextIndex(sign.context));
                symbol_count += 1;
                const negative = sign_bit != sign.predicted_negative;
                markDecodedSignificant(scratch, x, y, bitplane, negative);

                var dy = runlen + 1;
                while (dy < 4) : (dy += 1) {
                    symbol_count += try decodeCleanupSample(scratch, decoder, x, stripe_y + dy, bitplane, style);
                }
            } else {
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    symbol_count += try decodeCleanupSample(scratch, decoder, x, stripe_y + dy, bitplane, style);
                }
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
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;

    var stripe_y: usize = 0;
    while (stripe_y < scratch.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), scratch.height - stripe_y);
        var x: usize = 0;
        while (x < scratch.width) : (x += 1) {
            if (stripe_height == 4 and nbfCanUseRunStripe(flags, nbs, x, stripe_y, style)) {
                const agg = try decoder.read(mqContextIndex(.cleanup_aggregation));
                symbol_count += 1;
                if (!agg) continue;

                const runlen = try readCleanupRunLength(decoder);
                symbol_count += 2;
                if (runlen >= 4) return EbcotError.InvalidBlock;

                {
                    const y = stripe_y + runlen;
                    const p = nbfIndex(nbs, x, y);
                    const causal = style.vertical_causal and runlen == 3;
                    const f = if (causal) flags[p] & nbf_causal_mask else flags[p];
                    const sign = nbf_sc_lut[nbfScIndex(f)];
                    const sign_bit = try decoder.read(mqContextIndex(sign.context));
                    symbol_count += 1;
                    const negative = sign_bit != sign.predicted_negative;
                    markDecodedSignificantNbf(scratch, x, y, bitplane, negative);
                }

                var dy = runlen + 1;
                while (dy < 4) : (dy += 1) {
                    symbol_count += try nbfDecodeCleanupSample(scratch, decoder, x, stripe_y + dy, bitplane, style, dy == 3);
                }
            } else {
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    symbol_count += try nbfDecodeCleanupSample(scratch, decoder, x, stripe_y + dy, bitplane, style, dy == 3);
                }
            }
        }
    }

    if (style.segmentation_symbols) {
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
        if (try decoder.read(mqContextIndex(.cleanup_run)) != expected) return EbcotError.InvalidBlock;
    }
    return segmentation_symbol_bits.len;
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
    const hi = try decoder.read(mqContextIndex(.cleanup_run));
    const lo = try decoder.read(mqContextIndex(.cleanup_run));
    return (@as(usize, @intFromBool(hi)) << 1) | @intFromBool(lo);
}

fn nbfDecodeCleanupSample(
    scratch: *DecodeBlockScratch,
    decoder: anytype,
    x: usize,
    y: usize,
    bitplane: u8,
    style: CodeBlockStyle,
    causal_row: bool,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    const p = nbfIndex(nbs, x, y);
    const causal = style.vertical_causal and causal_row;
    const f = if (causal) flags[p] & nbf_causal_mask else flags[p];
    if ((f & (nbf_sig_self | nbf_visit)) != 0) return 0;
    const bit = try decoder.read(mqContextIndex(nbf_zc_lut[@intFromEnum(style.band_kind)][f & nbf_sig8]));
    var symbol_count: usize = 1;
    if (bit) {
        const sign = nbf_sc_lut[nbfScIndex(f)];
        const sign_bit = try decoder.read(mqContextIndex(sign.context));
        symbol_count += 1;
        const negative = sign_bit != sign.predicted_negative;
        markDecodedSignificantNbf(scratch, x, y, bitplane, negative);
    }
    return symbol_count;
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
    const bit = try decoder.read(mqContextIndex(zeroContextRowsDecode(scratch, x, y, style)));
    var symbol_count: usize = 1;
    if (bit) {
        const sign = signCodingRowsDecode(scratch, x, y, style);
        const sign_bit = try decoder.read(mqContextIndex(sign.context));
        symbol_count += 1;
        const negative = sign_bit != sign.predicted_negative;
        markDecodedSignificant(scratch, x, y, bitplane, negative);
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

                var dy = runlen + 1;
                while (dy < 4) : (dy += 1) {
                    symbol_count += try emitDirectCleanupSample(scratch, encoder, plane, stride, rect, x, stripe_y + dy, bitplane, style);
                }
            } else {
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    symbol_count += try emitDirectCleanupSample(scratch, encoder, plane, stride, rect, x, stripe_y + dy, bitplane, style);
                }
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
    try validateImplementedStyleAllowBypass(style);
    if (style.terminate_all or style.reset_context) return EbcotError.InvalidBlock;
    scratch.reset();
    try validateBlock(plane, stride, rect);

    const stats = blockStats(plane, stride, rect);
    if (stats.bitplanes == 0) {
        return ownedSegmentFromDirectIsoScratch(scratch, 0, 0, style.bypass);
    }
    const bitplanes = stats.bitplanes;

    const area = try blockArea(rect);
    try scratch.ensureBlockState(rect.width, rect.height, area);
    @memset(scratch.significant_words.items, 0);
    @memset(scratch.nb_flags.items, 0);

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
    const total_passes = expectedCodingPasses(bitplanes);

    var bitplane_index = bitplanes;
    while (bitplane_index > 0) {
        bitplane_index -= 1;
        const bitplane: u8 = @intCast(bitplane_index);
        nbfClearVisit(scratch.nb_flags.items);

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

            const symbol_count: usize = switch (kind) {
                .significance => if (is_raw)
                    try emitDirectIsoSignificancePass(scratch, raw, plane, stride, rect, bitplane, style, true)
                else
                    try emitDirectIsoSignificancePass(scratch, iso, plane, stride, rect, bitplane, style, false),
                .refinement => if (is_raw)
                    try emitDirectIsoRefinementPass(scratch, raw, plane, stride, rect, bitplane, style)
                else
                    try emitDirectIsoRefinementPass(scratch, iso, plane, stride, rect, bitplane, style),
                .cleanup => try emitDirectIsoCleanupPass(scratch, iso, plane, stride, rect, bitplane, style),
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
                const encoded_len = if (segment_is_raw)
                    try raw.finishInto(&scratch.bytes)
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

    return ownedSegmentFromDirectIsoScratch(scratch, bitplanes, stats.non_zero_count, style.bypass);
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
    scratch: *DirectBlockScratch,
    encoder: anytype,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    style: CodeBlockStyle,
    comptime raw: bool,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    const band: usize = @intFromEnum(style.band_kind);
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
                    const causal = style.vertical_causal and dy == 3;
                    const f = if (causal) flags[p] & nbf_causal_mask else flags[p];
                    if ((f & nbf_sig_self) != 0 or (f & nbf_sig8) == 0) continue;
                    flags[p] |= nbf_visit;
                    const bit = isMagnitudeBitSet(plane[(rect.y + y) * stride + rect.x + x], bitplane);
                    if (raw) {
                        try encoder.writeBit(bit);
                    } else {
                        try encoder.write(mqContextIndex(nbf_zc_lut[band][f & nbf_sig8]), bit);
                    }
                    symbol_count += 1;
                    if (bit) {
                        const negative = plane[(rect.y + y) * stride + rect.x + x] < 0;
                        if (raw) {
                            try encoder.writeBit(negative);
                        } else {
                            const sign = nbf_sc_lut[nbfScIndex(f)];
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
    scratch: *DirectBlockScratch,
    encoder: anytype,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
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
                    const causal = style.vertical_causal and dy == 3;
                    const f = if (causal) flags[p] & nbf_causal_mask else flags[p];
                    if ((f & nbf_sig_self) == 0 or (f & nbf_visit) != 0) continue;
                    const bit = isMagnitudeBitSet(plane[(rect.y + y) * stride + rect.x + x], bitplane);
                    if (raw) {
                        try encoder.writeBit(bit);
                    } else {
                        const context: Context = if ((f & nbf_refine) != 0)
                            .refinement_later
                        else if ((f & nbf_sig8) != 0)
                            .refinement_neighbor
                        else
                            .refinement;
                        try encoder.write(mqContextIndex(context), bit);
                    }
                    symbol_count += 1;
                    flags[p] |= nbf_refine;
                }
            }
        }
    }
    return symbol_count;
}

fn emitDirectIsoCleanupPass(
    scratch: *DirectBlockScratch,
    encoder: *mq_iso.Encoder,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    var symbol_count: usize = 0;
    var stripe_y: usize = 0;
    while (stripe_y < rect.height) : (stripe_y += 4) {
        const stripe_height = @min(@as(usize, 4), rect.height - stripe_y);
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            if (stripe_height == 4 and nbfCanUseRunStripe(flags, nbs, x, stripe_y, style)) {
                const runlen = cleanupRunLength(plane, stride, rect, x, stripe_y, bitplane);
                try encoder.write(mqContextIndex(.cleanup_aggregation), runlen != 4);
                symbol_count += 1;
                if (runlen == 4) continue;

                try writeCleanupRunLength(encoder, runlen);
                symbol_count += 2;

                {
                    const y = stripe_y + runlen;
                    const p = nbfIndex(nbs, x, y);
                    const causal = style.vertical_causal and runlen == 3;
                    const f = if (causal) flags[p] & nbf_causal_mask else flags[p];
                    const negative = plane[(rect.y + y) * stride + rect.x + x] < 0;
                    const sign = nbf_sc_lut[nbfScIndex(f)];
                    try encoder.write(mqContextIndex(sign.context), negative != sign.predicted_negative);
                    symbol_count += 1;
                    nbfMarkSignificant(flags, nbs, x, y, negative);
                    setSignificantRow(scratch, x, y);
                }

                var dy = runlen + 1;
                while (dy < 4) : (dy += 1) {
                    symbol_count += try nbfEmitCleanupSample(scratch, encoder, plane, stride, rect, x, stripe_y + dy, bitplane, style, dy == 3);
                }
            } else {
                var dy: usize = 0;
                while (dy < stripe_height) : (dy += 1) {
                    symbol_count += try nbfEmitCleanupSample(scratch, encoder, plane, stride, rect, x, stripe_y + dy, bitplane, style, dy == 3);
                }
            }
        }
    }

    if (style.segmentation_symbols) {
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
        if ((f & (nbf_sig8 | nbf_sig_self | nbf_visit)) != 0) return false;
    }
    return true;
}

fn nbfEmitCleanupSample(
    scratch: *DirectBlockScratch,
    encoder: *mq_iso.Encoder,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    x: usize,
    y: usize,
    bitplane: u8,
    style: CodeBlockStyle,
    causal_row: bool,
) !usize {
    const flags = scratch.nb_flags.items;
    const nbs = scratch.nb_stride;
    const p = nbfIndex(nbs, x, y);
    const causal = style.vertical_causal and causal_row;
    const f = if (causal) flags[p] & nbf_causal_mask else flags[p];
    if ((f & (nbf_sig_self | nbf_visit)) != 0) return 0;
    const bit = isMagnitudeBitSet(plane[(rect.y + y) * stride + rect.x + x], bitplane);
    try encoder.write(mqContextIndex(nbf_zc_lut[@intFromEnum(style.band_kind)][f & nbf_sig8]), bit);
    var symbol_count: usize = 1;
    if (bit) {
        const negative = plane[(rect.y + y) * stride + rect.x + x] < 0;
        const sign = nbf_sc_lut[nbfScIndex(f)];
        try encoder.write(mqContextIndex(sign.context), negative != sign.predicted_negative);
        symbol_count += 1;
        nbfMarkSignificant(flags, nbs, x, y, negative);
        setSignificantRow(scratch, x, y);
    }
    return symbol_count;
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

fn hasFlag(flags: []const u8, index: usize, kind: FlagKind) bool {
    return (flags[index] & flagMask(kind)) != 0;
}

fn setFlag(flags: []u8, index: usize, kind: FlagKind) void {
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

fn rowWordCount(width: usize) usize {
    return (width + significant_word_bits - 1) / significant_word_bits;
}

fn significantWordIndex(scratch: *const DirectBlockScratch, x: usize, y: usize) usize {
    return y * scratch.row_words + x / significant_word_bits;
}

fn significantBit(x: usize) u64 {
    return @as(u64, 1) << @as(u6, @intCast(x & (significant_word_bits - 1)));
}

fn hasSignificantRow(scratch: *const DirectBlockScratch, x: usize, y: usize) bool {
    return (scratch.significant_words.items[significantWordIndex(scratch, x, y)] & significantBit(x)) != 0;
}

fn setSignificantRow(scratch: *DirectBlockScratch, x: usize, y: usize) void {
    scratch.significant_words.items[significantWordIndex(scratch, x, y)] |= significantBit(x);
}

fn significantWordIndexDecode(scratch: *const DecodeBlockScratch, x: usize, y: usize) usize {
    return y * scratch.row_words + x / significant_word_bits;
}

fn hasSignificantRowDecode(scratch: *const DecodeBlockScratch, x: usize, y: usize) bool {
    return (scratch.significant_words.items[significantWordIndexDecode(scratch, x, y)] & significantBit(x)) != 0;
}

fn setSignificantRowDecode(scratch: *DecodeBlockScratch, x: usize, y: usize) void {
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
    const magnitude_bit = @as(i32, 1) << @as(u5, @intCast(bitplane));
    scratch.coeffs.items[index] = if (negative) -magnitude_bit else magnitude_bit;
    setFlag(scratch.flags.items, index, .significant);
    setFlag(scratch.flags.items, index, .became_significant);
    setSignificantRowDecode(scratch, x, y);
    nbfMarkSignificant(scratch.nb_flags.items, scratch.nb_stride, x, y, negative);
}

fn markDecodedSignificantNbf(scratch: *DecodeBlockScratch, x: usize, y: usize, bitplane: u8, negative: bool) void {
    const index = localIndex(scratch.width, x, y);
    const magnitude_bit = @as(i32, 1) << @as(u5, @intCast(bitplane));
    scratch.coeffs.items[index] = if (negative) -magnitude_bit else magnitude_bit;
    setSignificantRowDecode(scratch, x, y);
    nbfMarkSignificant(scratch.nb_flags.items, scratch.nb_stride, x, y, negative);
}

fn addMagnitudeBit(scratch: *DecodeBlockScratch, index: usize, bitplane: u8) void {
    const magnitude_bit = @as(i32, 1) << @as(u5, @intCast(bitplane));
    if (scratch.coeffs.items[index] < 0) {
        scratch.coeffs.items[index] -= magnitude_bit;
    } else {
        scratch.coeffs.items[index] += magnitude_bit;
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

fn bitRangeMask(lo: usize, hi: usize) u64 {
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

fn localIndex(width: usize, x: usize, y: usize) usize {
    return y * width + x;
}

fn bitPlaneCount(max_mag: u32) u8 {
    if (max_mag == 0) return 0;
    return @as(u8, @intCast(32 - @clz(max_mag)));
}

fn magnitude(value: i32) u32 {
    const wide = @as(i64, value);
    const abs = if (wide < 0) -wide else wide;
    return @as(u32, @intCast(abs));
}

fn isMagnitudeBitSet(value: i32, bitplane: u8) bool {
    return ((magnitude(value) >> @as(u5, @intCast(bitplane))) & 1) != 0;
}
