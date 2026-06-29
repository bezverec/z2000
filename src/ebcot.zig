const std = @import("std");
const mq = @import("mq.zig");
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

pub const CodeBlockSegment = struct {
    bitplanes: u8,
    non_zero_count: u32,
    pass_count: u16,
    byte_length: u64,
    passes: []CodeBlockPassPayload,
    bytes: []u8,

    pub fn deinit(self: *CodeBlockSegment, allocator: std.mem.Allocator) void {
        allocator.free(self.passes);
        allocator.free(self.bytes);
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
    reset_context: bool = false,
    terminate_all: bool = false,
    vertical_causal: bool = false,
    segmentation_symbols: bool = false,
};

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
const zero_context_lut = makeZeroContextLut();
const sign_context_lut = makeSignContextLut();
const stats_lanes = simd.i32_lanes;
const StatsVector = @Vector(stats_lanes, i32);
const StatsMaskVector = @Vector(stats_lanes, u32);
const stats_lane_masks = makeStatsLaneMasks();
const flag_clear_lanes = simd.i32_lanes * @sizeOf(i32);
const FlagClearVector = @Vector(flag_clear_lanes, u8);

pub const DirectBlockScratch = struct {
    allocator: std.mem.Allocator,
    flags: std.ArrayList(u8) = .empty,
    significant_words: std.ArrayList(u64) = .empty,
    row_words: usize = 0,
    width: usize = 0,
    height: usize = 0,
    pass_payloads: std.ArrayList(CodeBlockPassPayload) = .empty,
    bytes: std.ArrayList(u8) = .empty,
    encoder: ?mq.Encoder = null,

    pub fn init(allocator: std.mem.Allocator) DirectBlockScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DirectBlockScratch) void {
        if (self.encoder) |*encoder| encoder.deinit();
        self.flags.deinit(self.allocator);
        self.significant_words.deinit(self.allocator);
        self.pass_payloads.deinit(self.allocator);
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    fn reset(self: *DirectBlockScratch) void {
        self.pass_payloads.clearRetainingCapacity();
        self.bytes.clearRetainingCapacity();
    }

    fn ensureBlockState(self: *DirectBlockScratch, width: usize, height: usize, area: usize) !void {
        try self.flags.resize(self.allocator, area);
        const row_words = rowWordCount(width);
        try self.significant_words.resize(self.allocator, try std.math.mul(usize, row_words, height));
        self.row_words = row_words;
        self.width = width;
        self.height = height;
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

    pub fn init(allocator: std.mem.Allocator) DecodeBlockScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DecodeBlockScratch) void {
        self.flags.deinit(self.allocator);
        self.significant_words.deinit(self.allocator);
        self.coeffs.deinit(self.allocator);
        self.* = undefined;
    }

    fn ensureBlockState(self: *DecodeBlockScratch, width: usize, height: usize, area: usize) !void {
        try self.flags.resize(self.allocator, area);
        try self.coeffs.resize(self.allocator, area);
        const row_words = rowWordCount(width);
        try self.significant_words.resize(self.allocator, try std.math.mul(usize, row_words, height));
        self.row_words = row_words;
        self.width = width;
        self.height = height;
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

pub fn encodeBlockSymbolsSegmentContinuous(allocator: std.mem.Allocator, block: EncodedBlockView) !CodeBlockSegment {
    return encodeBlockSymbolsSegmentContinuousWithStyle(allocator, block, .{});
}

pub fn encodeBlockSymbolsSegmentContinuousWithStyle(allocator: std.mem.Allocator, block: EncodedBlockView, style: CodeBlockStyle) !CodeBlockSegment {
    if (style.terminate_all) return encodeBlockSymbolsSegment(allocator, block);
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
    @memset(scratch.flags.items, 0);
    @memset(scratch.significant_words.items, 0);
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
        clearFlag(scratch.flags.items, .became_significant);

        if (bitplane == bitplanes - 1) {
            clearFlag(scratch.flags.items, .visited);
            resetInferredContinuousPassContexts(style, &decoder, pass_index);
            decoded_symbols = try std.math.add(usize, decoded_symbols, try decodeCleanupPassInferred(scratch, &decoder, bitplane, style));
            pass_index += 1;
            continue;
        }

        clearFlag(scratch.flags.items, .visited);
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

fn effectiveSegmentMqMode(mode: SegmentMqMode, style: CodeBlockStyle) SegmentMqMode {
    if (mode == .continuous and style.terminate_all) return .direct;
    return mode;
}

fn decodeCodeBlockSegmentCoefficientsBoundedScratch(
    scratch: *DecodeBlockScratch,
    segment: CodeBlockSegment,
    width: usize,
    height: usize,
    mode: SegmentMqMode,
    require_complete: bool,
    style: CodeBlockStyle,
) ![]i32 {
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
    const effective_mode = effectiveSegmentMqMode(mode, style);
    var continuous_decoder: mq.Decoder = undefined;
    var continuous_decoder_active = false;
    defer if (continuous_decoder_active) continuous_decoder.deinit();
    if (effective_mode == .continuous) {
        continuous_decoder = try mq.Decoder.init(scratch.allocator, mq_context_count, segment.bytes, total_symbols);
        continuous_decoder_active = true;
    }

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
                .direct => try decodeCleanupPass(scratch, segment.passes[pass_index], segment.bytes, bitplane, style),
                .continuous => try decodeCleanupPassContinuous(scratch, segment.passes[pass_index], segment.bytes, &continuous_decoder, bitplane, style),
            }
            pass_index += 1;
            continue;
        }

        clearFlag(scratch.flags.items, .visited);
        resetContinuousPassContexts(effective_mode, style, &continuous_decoder, pass_index);
        switch (effective_mode) {
            .direct => try decodeSignificancePass(scratch, segment.passes[pass_index], segment.bytes, bitplane, style),
            .continuous => try decodeSignificancePassContinuous(scratch, segment.passes[pass_index], segment.bytes, &continuous_decoder, bitplane, style),
        }
        pass_index += 1;
        if (pass_index >= segment.pass_count) break;

        resetContinuousPassContexts(effective_mode, style, &continuous_decoder, pass_index);
        switch (effective_mode) {
            .direct => try decodeRefinementPass(scratch, segment.passes[pass_index], segment.bytes, bitplane, style),
            .continuous => try decodeRefinementPassContinuous(scratch, segment.passes[pass_index], segment.bytes, &continuous_decoder, bitplane, style),
        }
        pass_index += 1;
        if (pass_index >= segment.pass_count) break;

        resetContinuousPassContexts(effective_mode, style, &continuous_decoder, pass_index);
        switch (effective_mode) {
            .direct => try decodeCleanupPass(scratch, segment.passes[pass_index], segment.bytes, bitplane, style),
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

fn resetInferredContinuousPassContexts(style: CodeBlockStyle, decoder: *mq.Decoder, pass_index: u16) void {
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
) !void {
    const first_symbol = symbols.items.len;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (significant[index] or neighborSignificance(significant, rect.width, rect.height, pos.x, pos.y, style) == 0) continue;
        visited[index] = true;
        try emitZeroCoding(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index, significant, style);
        if (isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane)) {
            try emitSign(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index, significant, style);
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
    decoder: *mq.Decoder,
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
        const bit = try decoder.read(mqContextIndex(zeroContext(neighbor_count)));
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

fn decodeSignificancePassInferred(
    scratch: *DecodeBlockScratch,
    decoder: *mq.Decoder,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    var symbol_count: usize = 0;

    var it = ScanIterator.init(scratch.width, scratch.height);
    while (it.next()) |pos| {
        const index = localIndex(scratch.width, pos.x, pos.y);
        const neighbor_count = neighborSignificanceRowsDecode(scratch, pos.x, pos.y, style);
        if (hasSignificantRowDecode(scratch, pos.x, pos.y) or neighbor_count == 0) continue;
        setFlag(scratch.flags.items, index, .visited);
        const bit = try decoder.read(mqContextIndex(zeroContext(neighbor_count)));
        symbol_count += 1;
        if (bit) {
            const sign = signCodingRowsDecode(scratch, pos.x, pos.y, style);
            const sign_bit = try decoder.read(mqContextIndex(sign.context));
            symbol_count += 1;
            const negative = sign_bit != sign.predicted_negative;
            markDecodedSignificant(scratch, pos.x, pos.y, bitplane, negative);
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
    decoder: *mq.Decoder,
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
    decoder: *mq.Decoder,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
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
                try emitSign(allocator, symbols, plane, stride, rect, .{ .x = x, .y = y }, bitplane, pass_index, significant, style);
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
    decoder: *mq.Decoder,
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
    decoder: *mq.Decoder,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
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
        try emitSign(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index, significant, style);
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
            .context = .segmentation_symbol,
            .bit = bit,
            .x = index,
            .y = 0,
            .magnitude_bitplane = bitplane,
        });
    }
}

fn writeSegmentationSymbols(encoder: *mq.Encoder) !void {
    for (segmentation_symbol_bits) |bit| {
        try encoder.write(mqContextIndex(.segmentation_symbol), bit);
    }
}

fn readSegmentationSymbols(decoder: *mq.Decoder) !usize {
    for (segmentation_symbol_bits) |expected| {
        if (try decoder.read(mqContextIndex(.segmentation_symbol)) != expected) return EbcotError.InvalidBlock;
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

fn readCleanupRunLength(decoder: *mq.Decoder) !usize {
    const hi = try decoder.read(mqContextIndex(.cleanup_run));
    const lo = try decoder.read(mqContextIndex(.cleanup_run));
    return (@as(usize, @intFromBool(hi)) << 1) | @intFromBool(lo);
}

fn decodeCleanupSample(
    scratch: *DecodeBlockScratch,
    decoder: *mq.Decoder,
    x: usize,
    y: usize,
    bitplane: u8,
    style: CodeBlockStyle,
) !usize {
    const index = localIndex(scratch.width, x, y);
    if (hasSignificantRowDecode(scratch, x, y) or hasFlag(scratch.flags.items, index, .visited)) return 0;
    const bit = try decoder.read(mqContextIndex(zeroContext(neighborSignificanceRowsDecode(scratch, x, y, style))));
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
        .context = zeroContext(neighborSignificance(significant, rect.width, rect.height, pos.x, pos.y, style)),
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
) !void {
    const coding = signCoding(plane, stride, rect, pos.x, pos.y, significant, style);
    const negative = plane[(rect.y + pos.y) * stride + rect.x + pos.x] < 0;
    try symbols.append(allocator, .{
        .pass_index = pass_index,
        .kind = .sign,
        .context = coding.context,
        .bit = negative != coding.predicted_negative,
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
        try encoder.write(mqContextIndex(zeroContext(neighbor_count)), bit);
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

fn writeCleanupRunLength(encoder: *mq.Encoder, runlen: usize) !void {
    try encoder.write(mqContextIndex(.cleanup_run), ((runlen >> 1) & 1) != 0);
    try encoder.write(mqContextIndex(.cleanup_run), (runlen & 1) != 0);
}

fn emitDirectSignOnly(
    scratch: *DirectBlockScratch,
    encoder: *mq.Encoder,
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
    encoder: *mq.Encoder,
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
    try encoder.write(mqContextIndex(zeroContext(neighborSignificanceRows(scratch, x, y, style))), bit);
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

fn zeroContext(neighbors: u4) Context {
    return zero_context_lut[@min(neighbors, 8)];
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
    return (width + 63) / 64;
}

fn significantWordIndex(scratch: *const DirectBlockScratch, x: usize, y: usize) usize {
    return y * scratch.row_words + x / 64;
}

fn significantBit(x: usize) u64 {
    return @as(u64, 1) << @as(u6, @intCast(x & 63));
}

fn hasSignificantRow(scratch: *const DirectBlockScratch, x: usize, y: usize) bool {
    return (scratch.significant_words.items[significantWordIndex(scratch, x, y)] & significantBit(x)) != 0;
}

fn setSignificantRow(scratch: *DirectBlockScratch, x: usize, y: usize) void {
    scratch.significant_words.items[significantWordIndex(scratch, x, y)] |= significantBit(x);
}

fn significantWordIndexDecode(scratch: *const DecodeBlockScratch, x: usize, y: usize) usize {
    return y * scratch.row_words + x / 64;
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
    const first_word = min_x / 64;
    const last_word = max_x / 64;

    var yy = min_y;
    while (yy <= max_y) : (yy += 1) {
        const row_start = yy * scratch.row_words;
        var word = first_word;
        while (word <= last_word) : (word += 1) {
            const word_min_x = word * 64;
            const lo = if (min_x > word_min_x) min_x - word_min_x else 0;
            const hi = @min(max_x - word_min_x, 63);
            var mask = bitRangeMask(lo, hi);
            if (yy == y and word == x / 64) mask &= ~significantBit(x);
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
    const first_word = min_x / 64;
    const last_word = max_x / 64;

    var yy = min_y;
    while (yy <= max_y) : (yy += 1) {
        const row_start = yy * scratch.row_words;
        var word = first_word;
        while (word <= last_word) : (word += 1) {
            const word_min_x = word * 64;
            const lo = if (min_x > word_min_x) min_x - word_min_x else 0;
            const hi = @min(max_x - word_min_x, 63);
            var mask = bitRangeMask(lo, hi);
            if (yy == y and word == x / 64) mask &= ~significantBit(x);
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
