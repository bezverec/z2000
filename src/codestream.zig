const std = @import("std");
const bitplane = @import("bitplane.zig");
const color = @import("color.zig");
const entropy = @import("entropy.zig");
const image = @import("image.zig");
const subband = @import("subband.zig");
const wavelet_int = @import("wavelet_int.zig");

pub const CodestreamError = error{
    ImageTooLarge,
    TooManyLevels,
    InvalidCodestream,
    UnsupportedPayload,
    TruncatedData,
};

const Marker = enum(u16) {
    soc = 0xff4f,
    siz = 0xff51,
    cod = 0xff52,
    tlm = 0xff55,
    qcd = 0xff5c,
    sot = 0xff90,
    sod = 0xff93,
    eoc = 0xffd9,
};

const temporary_magic_v0 = "ZJ2K-CBLK-BP0";
const temporary_magic_v1 = "ZJ2K-CBLK-BP1";

pub const PassKind = enum(u8) {
    significance = 0,
    refinement = 1,
    cleanup = 2,
};

pub const EntropyStreamStats = struct {
    streams: u64 = 0,
    raw_bytes: u64 = 0,
    encoded_bytes: u64 = 0,

    fn add(self: *EntropyStreamStats, info: EntropyStreamInfo) void {
        self.streams += 1;
        self.raw_bytes += info.raw_len;
        self.encoded_bytes += info.encoded_len;
    }
};

pub const ComponentStats = struct {
    blocks: u64 = 0,
    active_blocks: u64 = 0,
    empty_blocks: u64 = 0,
    coeffs: u64 = 0,
    active_coeffs: u64 = 0,
    non_zero_coeffs: u64 = 0,
    max_bitplanes: u8 = 0,
    pass_streams: [3]EntropyStreamStats = [_]EntropyStreamStats{.{}} ** 3,
    method_streams: [4]EntropyStreamStats = [_]EntropyStreamStats{.{}} ** 4,

    fn addStream(self: *ComponentStats, pass: PassKind, info: EntropyStreamInfo) void {
        self.pass_streams[@intFromEnum(pass)].add(info);
        self.method_streams[@intFromEnum(info.method)].add(info);
    }
};

pub const TemporaryStats = struct {
    width: usize,
    height: usize,
    bit_depth: u8,
    levels: u8,
    block_width: u16,
    block_height: u16,
    tile_part_divisions: ?u8,
    payload_bytes: usize,
    codestream_bytes: usize,
    components: [3]ComponentStats,
};

pub const ProgressionOrder = enum(u8) {
    lrcp = 0,
    rlcp = 1,
    rpcl = 2,
    pcrl = 3,
    cprl = 4,

    pub fn label(self: ProgressionOrder) []const u8 {
        return switch (self) {
            .lrcp => "LRCP",
            .rlcp => "RLCP",
            .rpcl => "RPCL",
            .pcrl => "PCRL",
            .cprl => "CPRL",
        };
    }
};

pub const PrecinctSize = struct {
    width: u16,
    height: u16,
};

pub const LosslessOptions = struct {
    levels: u8 = 5,
    layers: u16 = 1,
    progression: ProgressionOrder = .rpcl,
    tile_width: u32 = 4096,
    tile_height: u32 = 4096,
    block_width: u16 = 64,
    block_height: u16 = 64,
    precincts: [33]PrecinctSize = defaultPrecincts(),
    precinct_count: u8 = 3,
    bypass: bool = true,
    reset_context: bool = false,
    terminate_all: bool = false,
    vertical_causal: bool = false,
    predictable_termination: bool = false,
    segmentation_symbols: bool = false,
    sop: bool = true,
    eph: bool = true,
    tlm: bool = true,
    tile_part_divisions: ?u8 = 'R',

    pub fn precinctForResolution(self: LosslessOptions, resolution: usize) PrecinctSize {
        const count = @as(usize, self.precinct_count);
        if (resolution < count) return self.precincts[resolution];
        return self.precincts[count - 1];
    }
};

pub const EncodeTimings = struct {
    total_ns: u64 = 0,
    color_transform_ns: u64 = 0,
    wavelet_ns: u64 = 0,
    payload_ns: u64 = 0,
    marker_ns: u64 = 0,
};

pub fn encodeLosslessSkeleton(
    allocator: std.mem.Allocator,
    rgb: image.RgbImage,
    requested_levels: u8,
) ![]u8 {
    return encodeLosslessWithOptions(allocator, rgb, .{ .levels = requested_levels });
}

pub fn encodeLosslessWithOptions(
    allocator: std.mem.Allocator,
    rgb: image.RgbImage,
    options: LosslessOptions,
) ![]u8 {
    return encodeLosslessWithOptionsMeasured(allocator, rgb, options, null);
}

pub fn encodeLosslessWithOptionsProfiled(
    allocator: std.mem.Allocator,
    rgb: image.RgbImage,
    options: LosslessOptions,
    timings: *EncodeTimings,
) ![]u8 {
    timings.* = .{};
    return encodeLosslessWithOptionsMeasured(allocator, rgb, options, timings);
}

fn encodeLosslessWithOptionsMeasured(
    allocator: std.mem.Allocator,
    rgb: image.RgbImage,
    options: LosslessOptions,
    timings: ?*EncodeTimings,
) ![]u8 {
    const total_start = monotonicNs();

    if (rgb.width > std.math.maxInt(u32) or rgb.height > std.math.maxInt(u32)) {
        return CodestreamError.ImageTooLarge;
    }
    if (options.levels > 32) return CodestreamError.TooManyLevels;
    try validateBlockSize(options.block_width, options.block_height);
    try validateTileSize(options.tile_width, options.tile_height);
    try validatePrecincts(options);
    try validateTilePartDivisions(options.tile_part_divisions);
    if (options.layers == 0) return CodestreamError.InvalidCodestream;

    const color_start = monotonicNs();
    var planes = try color.forwardRct(allocator, rgb);
    defer planes.deinit();
    if (timings) |t| t.color_transform_ns = elapsedNs(color_start);

    const wavelet_start = monotonicNs();
    var wavelet_workspace = try wavelet_int.Workspace.init(allocator, @max(rgb.width, rgb.height));
    defer wavelet_workspace.deinit();
    const levels = try wavelet_int.forward53WithWorkspace(
        &wavelet_workspace,
        planes.y,
        rgb.width,
        rgb.height,
        options.levels,
    );
    _ = try wavelet_int.forward53WithWorkspace(&wavelet_workspace, planes.cb, rgb.width, rgb.height, levels);
    _ = try wavelet_int.forward53WithWorkspace(&wavelet_workspace, planes.cr, rgb.width, rgb.height, levels);
    if (timings) |t| t.wavelet_ns = elapsedNs(wavelet_start);

    var tile_payload: std.ArrayList(u8) = .empty;
    defer tile_payload.deinit(allocator);
    const payload_start = monotonicNs();
    try appendTemporaryPayload(allocator, &tile_payload, planes, levels, options);
    if (timings) |t| t.payload_ns = elapsedNs(payload_start);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const marker_start = monotonicNs();
    try appendMarker(allocator, &out, .soc);
    try appendSiz(allocator, &out, rgb, options);
    try appendCod(allocator, &out, levels, options);
    try appendQcd(allocator, &out, levels);
    const psot = try std.math.add(u32, 14, @as(u32, @intCast(tile_payload.items.len)));
    if (options.tlm) try appendTlm(allocator, &out, psot);
    try appendSot(allocator, &out, psot);
    try appendMarker(allocator, &out, .sod);
    try out.appendSlice(allocator, tile_payload.items);
    try appendMarker(allocator, &out, .eoc);
    if (timings) |t| {
        t.marker_ns = elapsedNs(marker_start);
        t.total_ns = elapsedNs(total_start);
    }

    return out.toOwnedSlice(allocator);
}

pub fn decodeLosslessTemporary(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !image.RgbImage {
    const payload = try temporaryPayload(bytes);
    var cursor = Cursor.initWithAllocator(allocator, payload);

    const header = try readTemporaryHeader(&cursor);
    const width = header.width;
    const height = header.height;
    const bit_depth = header.bit_depth;
    const levels = header.levels;

    if (width == 0 or height == 0) return CodestreamError.InvalidCodestream;
    const pixels = try std.math.mul(usize, width, height);

    const y = try allocator.alloc(i32, pixels);
    errdefer allocator.free(y);
    const cb = try allocator.alloc(i32, pixels);
    errdefer allocator.free(cb);
    const cr = try allocator.alloc(i32, pixels);
    errdefer allocator.free(cr);
    @memset(y, 0);
    @memset(cb, 0);
    @memset(cr, 0);

    try readComponentPayload(&cursor, y, width, 0);
    try readComponentPayload(&cursor, cb, width, 1);
    try readComponentPayload(&cursor, cr, width, 2);
    if (!cursor.finished()) return CodestreamError.InvalidCodestream;

    var wavelet_workspace = try wavelet_int.Workspace.init(allocator, @max(width, height));
    defer wavelet_workspace.deinit();
    try wavelet_int.inverse53WithWorkspace(&wavelet_workspace, y, width, height, levels);
    try wavelet_int.inverse53WithWorkspace(&wavelet_workspace, cb, width, height, levels);
    try wavelet_int.inverse53WithWorkspace(&wavelet_workspace, cr, width, height, levels);

    var planes = color.RctPlanes{
        .allocator = allocator,
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .y = y,
        .cb = cb,
        .cr = cr,
    };
    defer planes.deinit();

    return color.inverseRct(allocator, planes);
}

pub fn analyzeLosslessTemporary(bytes: []const u8) !TemporaryStats {
    const payload = try temporaryPayload(bytes);
    var cursor = Cursor.initWithAllocator(std.heap.page_allocator, payload);

    const header = try readTemporaryHeader(&cursor);
    const width = header.width;
    const height = header.height;
    const bit_depth = header.bit_depth;
    const levels = header.levels;

    if (width == 0 or height == 0) return CodestreamError.InvalidCodestream;

    var stats = TemporaryStats{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .levels = levels,
        .block_width = header.block_width,
        .block_height = header.block_height,
        .tile_part_divisions = header.tile_part_divisions,
        .payload_bytes = payload.len,
        .codestream_bytes = bytes.len,
        .components = [_]ComponentStats{.{}} ** 3,
    };

    try readComponentStats(&cursor, &stats.components[0], 0);
    try readComponentStats(&cursor, &stats.components[1], 1);
    try readComponentStats(&cursor, &stats.components[2], 2);
    if (!cursor.finished()) return CodestreamError.InvalidCodestream;

    return stats;
}

pub fn hasMarker(bytes: []const u8, marker: u16) bool {
    if (bytes.len < 2) return false;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        const value = (@as(u16, bytes[i]) << 8) | bytes[i + 1];
        if (value == marker) return true;
    }
    return false;
}

pub fn markerValue(comptime name: []const u8) u16 {
    return @intFromEnum(@field(Marker, name));
}

pub fn firstSotPsot(bytes: []const u8) !u32 {
    if (bytes.len < 2 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    var cursor: usize = 2;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 4) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        cursor += 2;
        if (marker == @intFromEnum(Marker.sot)) {
            const segment_length = readU16Be(bytes, cursor);
            if (segment_length != 10 or bytes.len - cursor < segment_length) {
                return CodestreamError.InvalidCodestream;
            }
            return readU32Be(bytes, cursor + 4);
        }
        if (marker == @intFromEnum(Marker.sod) or marker == @intFromEnum(Marker.eoc)) {
            return CodestreamError.InvalidCodestream;
        }

        const segment_length = readU16Be(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) {
            return CodestreamError.TruncatedData;
        }
        cursor += segment_length;
    }

    return CodestreamError.InvalidCodestream;
}

pub fn firstTlmPtlm(bytes: []const u8) !u32 {
    if (bytes.len < 2 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    var cursor: usize = 2;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 4) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        cursor += 2;
        if (marker == @intFromEnum(Marker.tlm)) {
            const segment_length = readU16Be(bytes, cursor);
            if (segment_length < 6 or bytes.len - cursor < segment_length) {
                return CodestreamError.InvalidCodestream;
            }
            const data_start = cursor + 2;
            const stlm = bytes[data_start + 1];
            const tile_index_size = (stlm >> 4) & 0x03;
            if (tile_index_size == 3) return CodestreamError.InvalidCodestream;
            const length_size: usize = if (((stlm >> 6) & 0x01) == 0) 2 else 4;
            const entry_size = @as(usize, tile_index_size) + length_size;
            const entry_start = data_start + 2;
            if (entry_size == 0 or segment_length - 4 < entry_size) {
                return CodestreamError.InvalidCodestream;
            }
            const ptlm_start = entry_start + @as(usize, tile_index_size);
            return switch (length_size) {
                2 => @as(u32, readU16Be(bytes, ptlm_start)),
                4 => readU32Be(bytes, ptlm_start),
                else => unreachable,
            };
        }
        if (marker == @intFromEnum(Marker.sod) or marker == @intFromEnum(Marker.eoc)) {
            return CodestreamError.InvalidCodestream;
        }

        const segment_length = readU16Be(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) {
            return CodestreamError.TruncatedData;
        }
        cursor += segment_length;
    }

    return CodestreamError.InvalidCodestream;
}

fn temporaryPayload(bytes: []const u8) ![]const u8 {
    if (bytes.len < 4 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    var cursor: usize = 2;
    var tile_part_end: ?usize = null;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        const marker_start = cursor;
        cursor += 2;
        if (marker == @intFromEnum(Marker.sod)) break;
        if (marker == @intFromEnum(Marker.eoc)) return CodestreamError.InvalidCodestream;
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) {
            return CodestreamError.TruncatedData;
        }
        if (marker == @intFromEnum(Marker.sot)) {
            if (segment_length != 10) return CodestreamError.InvalidCodestream;
            const psot = readU32Be(bytes, cursor + 4);
            if (psot != 0) {
                const end = try std.math.add(usize, marker_start, psot);
                if (end > bytes.len) return CodestreamError.TruncatedData;
                tile_part_end = end;
            }
        }
        cursor += segment_length;
    } else {
        return CodestreamError.InvalidCodestream;
    }

    const end = tile_part_end orelse bytes.len - 2;
    if (end < cursor or bytes.len - end < 2) return CodestreamError.TruncatedData;
    if (readU16Be(bytes, end) != @intFromEnum(Marker.eoc)) {
        return CodestreamError.InvalidCodestream;
    }
    return bytes[cursor..end];
}

fn readComponentPayload(cursor: *Cursor, plane: []i32, stride: usize, expected_component: u8) !void {
    const component_index = try cursor.readU8();
    if (component_index != expected_component) return CodestreamError.InvalidCodestream;

    const band_count = try cursor.readU16();
    const block_count = try cursor.readU32();

    var band_index: usize = 0;
    while (band_index < band_count) : (band_index += 1) {
        _ = try cursor.readU8();
        _ = try cursor.readU8();
        _ = try cursor.readRect();
    }

    var block_index: usize = 0;
    while (block_index < block_count) : (block_index += 1) {
        const block_band = try cursor.readU16();
        if (block_band >= band_count) return CodestreamError.InvalidCodestream;
        _ = try cursor.readRect();
        const active_rect = try cursor.readRect();
        const bitplanes = try cursor.readU8();
        const non_zero_count = try cursor.readU32();
        var significance = try readEntropyStream(cursor);
        defer significance.deinit(cursor.allocator);
        var refinement = try readEntropyStream(cursor);
        defer refinement.deinit(cursor.allocator);
        var cleanup = try readEntropyStream(cursor);
        defer cleanup.deinit(cursor.allocator);
        try bitplane.decodeBlockPasses(
            plane,
            stride,
            active_rect,
            bitplanes,
            non_zero_count,
            significance.bytes,
            refinement.bytes,
        );
    }
}

const TemporaryHeader = struct {
    width: usize,
    height: usize,
    bit_depth: u8,
    levels: u8,
    block_width: u16,
    block_height: u16,
    tile_part_divisions: ?u8,
};

fn readTemporaryHeader(cursor: *Cursor) !TemporaryHeader {
    const magic = try cursor.readBytes(temporary_magic_v0.len);
    const version: u8 = if (std.mem.eql(u8, magic, temporary_magic_v0))
        0
    else if (std.mem.eql(u8, magic, temporary_magic_v1))
        1
    else
        return CodestreamError.UnsupportedPayload;

    const width = @as(usize, try cursor.readU32());
    const height = @as(usize, try cursor.readU32());
    const bit_depth = try cursor.readU8();
    const levels = try cursor.readU8();
    const block_width = try cursor.readU16();
    const block_height = try cursor.readU16();
    const tile_part_divisions = if (version >= 1) try readTilePartDivisions(cursor) else null;

    return .{
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .levels = levels,
        .block_width = block_width,
        .block_height = block_height,
        .tile_part_divisions = tile_part_divisions,
    };
}

fn readTilePartDivisions(cursor: *Cursor) !?u8 {
    const value = try cursor.readU8();
    return if (value == 0) null else value;
}

fn readComponentStats(cursor: *Cursor, stats: *ComponentStats, expected_component: u8) !void {
    const component_index = try cursor.readU8();
    if (component_index != expected_component) return CodestreamError.InvalidCodestream;

    const band_count = try cursor.readU16();
    const block_count = try cursor.readU32();
    stats.blocks += block_count;

    var band_index: usize = 0;
    while (band_index < band_count) : (band_index += 1) {
        _ = try cursor.readU8();
        _ = try cursor.readU8();
        _ = try cursor.readRect();
    }

    var block_index: usize = 0;
    while (block_index < block_count) : (block_index += 1) {
        const block_band = try cursor.readU16();
        if (block_band >= band_count) return CodestreamError.InvalidCodestream;
        const block_rect = try cursor.readRect();
        const active_rect = try cursor.readRect();
        const bitplanes = try cursor.readU8();
        const non_zero_count = try cursor.readU32();

        stats.coeffs += rectArea(block_rect);
        stats.active_coeffs += rectArea(active_rect);
        stats.non_zero_coeffs += non_zero_count;
        stats.max_bitplanes = @max(stats.max_bitplanes, bitplanes);
        if (active_rect.width == 0 or active_rect.height == 0) {
            stats.empty_blocks += 1;
        } else {
            stats.active_blocks += 1;
        }

        const significance = try readEntropyStreamInfo(cursor);
        const refinement = try readEntropyStreamInfo(cursor);
        const cleanup = try readEntropyStreamInfo(cursor);
        stats.addStream(.significance, significance);
        stats.addStream(.refinement, refinement);
        stats.addStream(.cleanup, cleanup);
    }
}

fn appendSiz(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rgb: image.RgbImage,
    options: LosslessOptions,
) !void {
    const components: u16 = 3;
    const lsiz = 38 + 3 * components;
    try appendMarker(allocator, out, .siz);
    try appendU16Be(allocator, out, lsiz);
    try appendU16Be(allocator, out, 0);
    try appendU32Be(allocator, out, @as(u32, @intCast(rgb.width)));
    try appendU32Be(allocator, out, @as(u32, @intCast(rgb.height)));
    try appendU32Be(allocator, out, 0);
    try appendU32Be(allocator, out, 0);
    try appendU32Be(allocator, out, options.tile_width);
    try appendU32Be(allocator, out, options.tile_height);
    try appendU32Be(allocator, out, 0);
    try appendU32Be(allocator, out, 0);
    try appendU16Be(allocator, out, components);
    for (0..components) |_| {
        try out.append(allocator, rgb.bit_depth - 1);
        try out.append(allocator, 1);
        try out.append(allocator, 1);
    }
}

fn appendCod(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    levels: u8,
    options: LosslessOptions,
) !void {
    try appendMarker(allocator, out, .cod);
    const uses_precincts = options.precinct_count > 0;
    const lcod = 12 + if (uses_precincts) @as(u16, levels) + 1 else 0;
    try appendU16Be(allocator, out, lcod);
    try out.append(allocator, codingStyleFlags(options));
    try out.append(allocator, @intFromEnum(options.progression));
    try appendU16Be(allocator, out, options.layers);
    try out.append(allocator, 1);
    try out.append(allocator, levels);
    try out.append(allocator, codeBlockExponent(options.block_width));
    try out.append(allocator, codeBlockExponent(options.block_height));
    try out.append(allocator, codeBlockStyle(options));
    try out.append(allocator, 1);
    if (uses_precincts) {
        var resolution: usize = 0;
        while (resolution <= levels) : (resolution += 1) {
            try out.append(allocator, precinctByte(options.precinctForResolution(resolution)));
        }
    }
}

fn appendQcd(allocator: std.mem.Allocator, out: *std.ArrayList(u8), levels: u8) !void {
    const bands = 1 + 3 * @as(u16, levels);
    try appendMarker(allocator, out, .qcd);
    try appendU16Be(allocator, out, 3 + bands);
    try out.append(allocator, 2 << 5);
    for (0..bands) |_| {
        try out.append(allocator, 8 << 3);
    }
}

fn appendTlm(allocator: std.mem.Allocator, out: *std.ArrayList(u8), psot: u32) !void {
    try appendMarker(allocator, out, .tlm);
    try appendU16Be(allocator, out, 8);
    try out.append(allocator, 0);
    try out.append(allocator, 0x40);
    try appendU32Be(allocator, out, psot);
}

fn appendSot(allocator: std.mem.Allocator, out: *std.ArrayList(u8), psot: u32) !void {
    try appendMarker(allocator, out, .sot);
    try appendU16Be(allocator, out, 10);
    try appendU16Be(allocator, out, 0);
    try appendU32Be(allocator, out, psot);
    try out.append(allocator, 0);
    try out.append(allocator, 1);
}

fn appendTemporaryPayload(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    planes: color.RctPlanes,
    levels: u8,
    options: LosslessOptions,
) !void {
    try out.appendSlice(allocator, temporary_magic_v1);
    try appendU32Be(allocator, out, @as(u32, @intCast(planes.width)));
    try appendU32Be(allocator, out, @as(u32, @intCast(planes.height)));
    try out.append(allocator, planes.bit_depth);
    try out.append(allocator, levels);
    try appendU16Be(allocator, out, options.block_width);
    try appendU16Be(allocator, out, options.block_height);
    try out.append(allocator, options.tile_part_divisions orelse 0);

    const bands = try subband.makeBands(allocator, planes.width, planes.height, levels);
    defer allocator.free(bands);
    const blocks = try subband.makeCodeBlocks(allocator, bands, options.block_width, options.block_height);
    defer allocator.free(blocks);

    try appendComponentPayload(allocator, out, 0, planes.y, planes.width, bands, blocks);
    try appendComponentPayload(allocator, out, 1, planes.cb, planes.width, bands, blocks);
    try appendComponentPayload(allocator, out, 2, planes.cr, planes.width, bands, blocks);
}

fn appendMarker(allocator: std.mem.Allocator, out: *std.ArrayList(u8), marker: Marker) !void {
    try appendU16Be(allocator, out, @intFromEnum(marker));
}

fn appendComponentPayload(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    component_index: u8,
    plane: []const i32,
    stride: usize,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
) !void {
    try out.append(allocator, component_index);
    try appendU16Be(allocator, out, @as(u16, @intCast(bands.len)));
    try appendU32Be(allocator, out, @as(u32, @intCast(blocks.len)));

    for (bands) |band| {
        try out.append(allocator, @intFromEnum(band.kind));
        try out.append(allocator, band.level);
        try appendRect(allocator, out, band.rect);
    }

    var scratch = bitplane.BlockScratch.init(allocator);
    defer scratch.deinit();

    for (blocks) |block| {
        try appendU16Be(allocator, out, @as(u16, @intCast(block.band_index)));
        try appendRect(allocator, out, block.rect);

        const encoded = try bitplane.encodeBlockPassesScratch(&scratch, plane, stride, block.rect);

        try appendRect(allocator, out, encoded.active_rect);
        try out.append(allocator, encoded.bitplanes);
        try appendU32Be(allocator, out, encoded.non_zero_count);
        try appendEntropyStream(allocator, out, encoded.significance_bytes);
        try appendEntropyStream(allocator, out, encoded.refinement_bytes);
        try appendEntropyStream(allocator, out, encoded.cleanup_bytes);
    }
}

fn appendRect(allocator: std.mem.Allocator, out: *std.ArrayList(u8), rect: subband.Rect) !void {
    try appendU32Be(allocator, out, @as(u32, @intCast(rect.x)));
    try appendU32Be(allocator, out, @as(u32, @intCast(rect.y)));
    try appendU32Be(allocator, out, @as(u32, @intCast(rect.width)));
    try appendU32Be(allocator, out, @as(u32, @intCast(rect.height)));
}

fn appendU16Be(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value)));
}

fn appendU32Be(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    try out.append(allocator, @as(u8, @truncate(value >> 24)));
    try out.append(allocator, @as(u8, @truncate(value >> 16)));
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value)));
}

fn readU16Be(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | @as(u16, bytes[offset + 1]);
}

fn readU32Be(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}

fn elapsedNs(start: u64) u64 {
    const now = monotonicNs();
    return if (now >= start) now - start else 0;
}

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.MONOTONIC, &ts);
    if (rc != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Cursor = struct {
    allocator: std.mem.Allocator,
    bytes: []const u8,
    index: usize = 0,

    fn initWithAllocator(allocator: std.mem.Allocator, bytes: []const u8) Cursor {
        return .{ .allocator = allocator, .bytes = bytes };
    }

    fn finished(self: Cursor) bool {
        return self.index == self.bytes.len;
    }

    fn expectBytes(self: *Cursor, expected: []const u8) !void {
        const actual = try self.readBytes(expected.len);
        if (!std.mem.eql(u8, actual, expected)) return CodestreamError.UnsupportedPayload;
    }

    fn readBytes(self: *Cursor, count: usize) ![]const u8 {
        if (self.index > self.bytes.len or self.bytes.len - self.index < count) {
            return CodestreamError.TruncatedData;
        }
        const start = self.index;
        self.index += count;
        return self.bytes[start..self.index];
    }

    fn readU8(self: *Cursor) !u8 {
        return (try self.readBytes(1))[0];
    }

    fn readU16(self: *Cursor) !u16 {
        const bytes = try self.readBytes(2);
        return (@as(u16, bytes[0]) << 8) | bytes[1];
    }

    fn readU32(self: *Cursor) !u32 {
        const bytes = try self.readBytes(4);
        return (@as(u32, bytes[0]) << 24) |
            (@as(u32, bytes[1]) << 16) |
            (@as(u32, bytes[2]) << 8) |
            bytes[3];
    }

    fn readRect(self: *Cursor) !subband.Rect {
        return .{
            .x = @as(usize, try self.readU32()),
            .y = @as(usize, try self.readU32()),
            .width = @as(usize, try self.readU32()),
            .height = @as(usize, try self.readU32()),
        };
    }
};

const DecodedEntropyStream = struct {
    bytes: []u8,

    fn deinit(self: *DecodedEntropyStream, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const EntropyStreamInfo = struct {
    method: entropy.Method,
    raw_len: u32,
    encoded_len: u32,
};

fn readEntropyStream(cursor: *Cursor) !DecodedEntropyStream {
    const method = try entropy.parseMethod(try cursor.readU8());
    const raw_len = try cursor.readU32();
    const encoded_len = @as(usize, try cursor.readU32());
    const encoded = try cursor.readBytes(encoded_len);
    return .{ .bytes = try entropy.decode(cursor.allocator, method, raw_len, encoded) };
}

fn readEntropyStreamInfo(cursor: *Cursor) !EntropyStreamInfo {
    const method = try entropy.parseMethod(try cursor.readU8());
    const raw_len = try cursor.readU32();
    const encoded_len = try cursor.readU32();
    _ = try cursor.readBytes(@as(usize, encoded_len));
    return .{
        .method = method,
        .raw_len = raw_len,
        .encoded_len = encoded_len,
    };
}

fn appendEntropyStream(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bytes: []const u8,
) !void {
    var encoded = try entropy.encodeAutoBorrowingRaw(allocator, bytes);
    defer encoded.deinit(allocator);

    try out.append(allocator, @intFromEnum(encoded.method));
    try appendU32Be(allocator, out, encoded.raw_len);
    try appendU32Be(allocator, out, @as(u32, @intCast(encoded.bytes.len)));
    try out.appendSlice(allocator, encoded.bytes);
}

fn rectArea(rect: subband.Rect) u64 {
    return @as(u64, @intCast(rect.width)) * @as(u64, @intCast(rect.height));
}

fn defaultPrecincts() [33]PrecinctSize {
    var precincts = [_]PrecinctSize{.{ .width = 128, .height = 128 }} ** 33;
    precincts[0] = .{ .width = 256, .height = 256 };
    precincts[1] = .{ .width = 256, .height = 256 };
    return precincts;
}

fn validateBlockSize(width: u16, height: u16) !void {
    if (!isValidBlockEdge(width) or !isValidBlockEdge(height)) return CodestreamError.InvalidCodestream;
    if (@as(u32, width) * @as(u32, height) > 4096) return CodestreamError.InvalidCodestream;
}

fn validateTileSize(width: u32, height: u32) !void {
    if (width == 0 or height == 0) return CodestreamError.InvalidCodestream;
}

fn validatePrecincts(options: LosslessOptions) !void {
    if (options.precinct_count == 0 or options.precinct_count > options.precincts.len) {
        return CodestreamError.InvalidCodestream;
    }
    for (options.precincts[0..options.precinct_count]) |precinct| {
        if (!isValidPrecinctEdge(precinct.width) or !isValidPrecinctEdge(precinct.height)) {
            return CodestreamError.InvalidCodestream;
        }
    }
}

fn validateTilePartDivisions(value: ?u8) !void {
    const actual = value orelse return;
    switch (actual) {
        'R', 'L', 'C', 'P' => {},
        else => return CodestreamError.InvalidCodestream,
    }
}

fn isValidBlockEdge(value: u16) bool {
    return value >= 4 and value <= 1024 and value & (value - 1) == 0;
}

fn isValidPrecinctEdge(value: u16) bool {
    return value >= 1 and value <= 32768 and value & (value - 1) == 0;
}

fn codeBlockExponent(value: u16) u8 {
    var exponent: u8 = 0;
    var current = value;
    while (current > 1) : (current >>= 1) exponent += 1;
    return exponent - 2;
}

fn precinctByte(precinct: PrecinctSize) u8 {
    return log2U16(precinct.width) | (log2U16(precinct.height) << 4);
}

fn log2U16(value: u16) u8 {
    var exponent: u8 = 0;
    var current = value;
    while (current > 1) : (current >>= 1) exponent += 1;
    return exponent;
}

fn codingStyleFlags(options: LosslessOptions) u8 {
    var flags: u8 = 0x01;
    if (options.sop) flags |= 0x02;
    if (options.eph) flags |= 0x04;
    return flags;
}

fn codeBlockStyle(options: LosslessOptions) u8 {
    var style: u8 = 0;
    if (options.bypass) style |= 0x01;
    if (options.reset_context) style |= 0x02;
    if (options.terminate_all) style |= 0x04;
    if (options.vertical_causal) style |= 0x08;
    if (options.predictable_termination) style |= 0x10;
    if (options.segmentation_symbols) style |= 0x20;
    return style;
}
