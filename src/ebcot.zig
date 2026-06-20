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
    sign = 9,
    refinement = 10,
};

pub const SymbolKind = enum(u8) {
    zero_coding,
    sign,
    magnitude_refinement,
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
    passes: std.ArrayList(Pass) = .empty,
    symbols: std.ArrayList(Symbol) = .empty,

    pub fn init(allocator: std.mem.Allocator) BlockScratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BlockScratch) void {
        self.significant.deinit(self.allocator);
        self.visited.deinit(self.allocator);
        self.became_significant.deinit(self.allocator);
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
    }
};

const FlagKind = enum {
    significant,
    visited,
    became_significant,
};

const flag_significant: u8 = 1 << 0;
const flag_visited: u8 = 1 << 1;
const flag_became_significant: u8 = 1 << 2;
const zero_context_lut = makeZeroContextLut();
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

pub fn encodeBlock(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !EncodedBlock {
    var scratch = BlockScratch.init(allocator);
    defer scratch.deinit();

    const view = try encodeBlockScratch(&scratch, plane, stride, rect);
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
    scratch.reset();
    try validateBlock(plane, stride, rect);

    var max_mag: u32 = 0;
    var non_zero_count: u32 = 0;
    var y: usize = 0;
    while (y < rect.height) : (y += 1) {
        const row = (rect.y + y) * stride + rect.x;
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            const mag = magnitude(plane[row + x]);
            max_mag = @max(max_mag, mag);
            if (mag != 0) non_zero_count += 1;
        }
    }

    const bitplanes = bitPlaneCount(max_mag);
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
    @memset(significant, false);

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
        );
        pass_index += 1;
    }

    return .{
        .bitplanes = bitplanes,
        .non_zero_count = non_zero_count,
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
    var block = try encodeBlock(allocator, plane, stride, rect);
    defer block.deinit(allocator);
    return encodeBlockSymbolsSegment(allocator, .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .passes = block.passes,
        .symbols = block.symbols,
    });
}

pub fn encodeCodeBlockSegmentDirect(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !CodeBlockSegment {
    var scratch = DirectBlockScratch.init(allocator);
    defer scratch.deinit();
    return encodeCodeBlockSegmentDirectScratch(&scratch, plane, stride, rect);
}

pub fn encodeCodeBlockSegmentDirectScratch(
    scratch: *DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
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
            try emitDirectCleanupPass(scratch, plane, stride, rect, bitplane, pass_index);
            pass_index += 1;
            continue;
        }

        clearFlag(scratch.flags.items, .visited);
        try emitDirectSignificancePass(scratch, plane, stride, rect, bitplane, pass_index);
        pass_index += 1;

        try emitDirectRefinementPass(scratch, plane, stride, rect, bitplane, pass_index);
        pass_index += 1;

        try emitDirectCleanupPass(scratch, plane, stride, rect, bitplane, pass_index);
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
) !void {
    const first_symbol = symbols.items.len;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (significant[index] or neighborSignificance(significant, rect.width, rect.height, pos.x, pos.y) == 0) continue;
        visited[index] = true;
        try emitZeroCoding(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index, significant);
        if (isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane)) {
            try emitSign(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index);
            significant[index] = true;
            became_significant[index] = true;
        }
    }

    try appendPass(allocator, passes, .significance, bitplane, first_symbol, symbols.items.len);
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
) !void {
    const first_symbol = symbols.items.len;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (!significant[index] or became_significant[index]) continue;
        try symbols.append(allocator, .{
            .pass_index = pass_index,
            .kind = .magnitude_refinement,
            .context = .refinement,
            .bit = isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane),
            .x = pos.x,
            .y = pos.y,
            .magnitude_bitplane = bitplane,
        });
    }

    try appendPass(allocator, passes, .refinement, bitplane, first_symbol, symbols.items.len);
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
) !void {
    const first_symbol = symbols.items.len;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (significant[index] or visited[index]) continue;
        try emitZeroCoding(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index, significant);
        if (isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane)) {
            try emitSign(allocator, symbols, plane, stride, rect, pos, bitplane, pass_index);
            significant[index] = true;
            became_significant[index] = true;
        }
    }

    try appendPass(allocator, passes, .cleanup, bitplane, first_symbol, symbols.items.len);
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
) !void {
    try symbols.append(allocator, .{
        .pass_index = pass_index,
        .kind = .zero_coding,
        .context = zeroContext(neighborSignificance(significant, rect.width, rect.height, pos.x, pos.y)),
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
) !void {
    try symbols.append(allocator, .{
        .pass_index = pass_index,
        .kind = .sign,
        .context = .sign,
        .bit = plane[(rect.y + pos.y) * stride + rect.x + pos.x] < 0,
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
) !void {
    const byte_offset = scratch.bytes.items.len;
    const encoder = try scratch.mqEncoder();
    encoder.resetAll();
    var symbol_count: usize = 0;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        const neighbor_count = neighborSignificanceRows(scratch, pos.x, pos.y);
        if (hasSignificantRow(scratch, pos.x, pos.y) or neighbor_count == 0) continue;
        setFlag(scratch.flags.items, index, .visited);
        const bit = isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane);
        try encoder.write(mqContextIndex(zeroContext(neighbor_count)), bit);
        symbol_count += 1;
        if (bit) {
            try encoder.write(mqContextIndex(.sign), plane[(rect.y + pos.y) * stride + rect.x + pos.x] < 0);
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
) !void {
    const byte_offset = scratch.bytes.items.len;
    const encoder = try scratch.mqEncoder();
    encoder.resetAll();
    var symbol_count: usize = 0;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (!hasSignificantRow(scratch, pos.x, pos.y) or hasFlag(scratch.flags.items, index, .became_significant)) continue;
        try encoder.write(mqContextIndex(.refinement), isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane));
        symbol_count += 1;
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
) !void {
    const byte_offset = scratch.bytes.items.len;
    const encoder = try scratch.mqEncoder();
    encoder.resetAll();
    var symbol_count: usize = 0;

    var it = ScanIterator.init(rect.width, rect.height);
    while (it.next()) |pos| {
        const index = localIndex(rect.width, pos.x, pos.y);
        if (hasSignificantRow(scratch, pos.x, pos.y) or hasFlag(scratch.flags.items, index, .visited)) continue;
        const bit = isMagnitudeBitSet(plane[(rect.y + pos.y) * stride + rect.x + pos.x], bitplane);
        try encoder.write(mqContextIndex(zeroContext(neighborSignificanceRows(scratch, pos.x, pos.y))), bit);
        symbol_count += 1;
        if (bit) {
            try encoder.write(mqContextIndex(.sign), plane[(rect.y + pos.y) * stride + rect.x + pos.x] < 0);
            symbol_count += 1;
            setFlag(scratch.flags.items, index, .significant);
            setSignificantRow(scratch, pos.x, pos.y);
            setFlag(scratch.flags.items, index, .became_significant);
        }
    }

    try appendDirectPass(scratch, .cleanup, bitplane, symbol_count, byte_offset);
    _ = pass_index;
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

fn neighborSignificance(significant: []const bool, width: usize, height: usize, x: usize, y: usize) u4 {
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
            if (significant[localIndex(width, xx, yy)]) count += 1;
        }
    }
    return count;
}

fn zeroContext(neighbors: u4) Context {
    return zero_context_lut[@min(neighbors, 8)];
}

fn makeZeroContextLut() [9]Context {
    var lut: [9]Context = undefined;
    for (&lut, 0..) |*context, index| {
        context.* = @enumFromInt(index);
    }
    return lut;
}

fn flagMask(kind: FlagKind) u8 {
    return switch (kind) {
        .significant => flag_significant,
        .visited => flag_visited,
        .became_significant => flag_became_significant,
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

fn neighborSignificanceRows(scratch: *const DirectBlockScratch, x: usize, y: usize) u4 {
    var count: u4 = 0;
    const min_y = if (y == 0) 0 else y - 1;
    const max_y = @min(scratch.height - 1, y + 1);
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
