const std = @import("std");
const builtin = @import("builtin");
const bitplane = @import("bitplane.zig");
const color = @import("color.zig");
const ebcot = @import("ebcot.zig");
const entropy = @import("entropy.zig");
const image = @import("image.zig");
const packet_plan = @import("packet_plan.zig");
const poc = @import("poc.zig");
const ppm = @import("ppm.zig");
const rate_alloc = @import("rate_alloc.zig");
const subband = @import("subband.zig");
const t2 = @import("t2.zig");
const tile_grid = @import("tile_grid.zig");
const tile_pipeline = @import("tile_pipeline.zig");
const wavelet_int = @import("wavelet_int.zig");
const wavelet = @import("wavelet.zig");

pub const CodestreamError = error{
    ImageTooLarge,
    TooManyLevels,
    InvalidCodestream,
    UnsupportedPayload,
    TruncatedData,
};

const Marker = enum(u16) {
    soc = 0xff4f,
    cap = 0xff50,
    siz = 0xff51,
    cod = 0xff52,
    coc = 0xff53,
    com = 0xff64,
    tlm = 0xff55,
    plm = 0xff57,
    plt = 0xff58,
    qcd = 0xff5c,
    qcc = 0xff5d,
    rgn = 0xff5e,
    poc = 0xff5f,
    ppm = 0xff60,
    ppt = 0xff61,
    crg = 0xff63,
    sot = 0xff90,
    sop = 0xff91,
    eph = 0xff92,
    sod = 0xff93,
    eoc = 0xffd9,
};

/// F1 component-layout bound: SIZ Csiz values 1..4 are the implemented
/// envelope (grayscale=1, RGB=3 as MCT-capable specials; 2 and 4 ride the
/// no-MCT planar path). Mirrors color.max_components.
pub const max_codestream_components = color.max_components;

const temporary_magic_v0 = "ZJ2K-CBLK-BP0";
const temporary_magic_v1 = "ZJ2K-CBLK-BP1";
const temporary_magic_v2 = "ZJ2K-CBLK-BP2";
const temporary_magic_v3 = "ZJ2K-CBLK-BP3";
const temporary_magic_v4 = "ZJ2K-CBLK-BP4";
const temporary_magic_v5 = "ZJ2K-CBLK-BP5";
const temporary_magic_v6 = "ZJ2K-CBLK-BP6";
const temporary_magic_v7 = "ZJ2K-CBLK-BP7";
const temporary_magic_v8 = "ZJ2K-CBLK-BP8";
const temporary_comment_magic = "ZJ2K-TEMP-PAYLOAD1";
const temporary_packet_header_empty: u8 = 0x00;
const temporary_packet_header_non_empty: u8 = 0x80;
const max_quality_layers = rate_alloc.max_layers;

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

pub const QualityLayerStats = struct {
    blocks: u64 = 0,
    cumulative_passes: u64 = 0,
    cumulative_bytes: u64 = 0,
};

pub const EbcotSegmentStats = struct {
    blocks: u64 = 0,
    passes: u64 = 0,
    symbols: u64 = 0,
    mq_bytes: u64 = 0,
};

const EbcotSegmentInfo = struct {
    stats: EbcotSegmentStats = .{},
    passes: []ebcot.CodeBlockPassPayload = &.{},

    fn deinit(self: *EbcotSegmentInfo, allocator: std.mem.Allocator) void {
        if (self.passes.len > 0) allocator.free(self.passes);
        self.* = .{};
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
    coding_passes: u64 = 0,
    ebcot_segments: EbcotSegmentStats = .{},
    quality_layers: [max_quality_layers]QualityLayerStats = [_]QualityLayerStats{.{}} ** max_quality_layers,
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
    component_count: u16 = 3,
    levels: u8,
    layers: u16,
    code_block_style: ebcot.CodeBlockStyle = .{},
    block_width: u16,
    block_height: u16,
    tile_part_divisions: ?u8,
    tile_part_plan_count: u8,
    tile_part_plan: [33]u8,
    packet_plan_count: u8,
    packet_plan: [33]packet_plan.Resolution,
    packet_count: u64,
    sod_packets: u64,
    sod_packet_bytes: u64,
    t2_audited_packets: u64,
    t2_present_packets: u64,
    t2_absent_packets: u64,
    t2_geometry_empty_packets: u64,
    t2_header_decoded_packets: u64,
    t2_header_bytes: u64,
    t2_payload_bytes: u64,
    t2_included_blocks: u64,
    t2_assembled_blocks: u64,
    t2_assembled_bytes: u64,
    t2_assembled_passes: u64,
    t2_t1_ready_blocks: u64,
    rpcl_shadow_packets: u64,
    rpcl_shadow_bytes: u64,
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

pub const PocProgression = poc.Progression;
pub const PocRecord = poc.Record;

pub const PrecinctSize = struct {
    width: u16,
    height: u16,
};

pub const MultipleComponentTransform = enum(u8) {
    none = 0,
    rct = 1,
    ict = 2,

    pub fn label(self: MultipleComponentTransform) []const u8 {
        return switch (self) {
            .none => "none",
            .rct => "RCT",
            .ict => "ICT",
        };
    }
};

pub const WaveletTransform = enum(u8) {
    irreversible_9_7 = 0,
    reversible_5_3 = 1,

    pub fn label(self: WaveletTransform) []const u8 {
        return switch (self) {
            .irreversible_9_7 => "9-7",
            .reversible_5_3 => "5-3",
        };
    }
};

pub const QuantizationStyle = enum(u5) {
    none = 0,
    scalar_derived = 1,
    scalar_expounded = 2,

    pub fn label(self: QuantizationStyle) []const u8 {
        return switch (self) {
            .none => "none",
            .scalar_derived => "scalar-derived",
            .scalar_expounded => "scalar-expounded",
        };
    }
};

pub const T1Backend = enum {
    legacy_mq,
    iso_mq,
};

/// Default QCD guard bit count for z2000-written streams. Strict decode follows
/// the signalled value when a codestream carries legal guard bits in 1..7.
const strict_guard_bits: u8 = 2;

pub const LosslessOptions = struct {
    levels: u8 = 5,
    layers: u16 = 1,
    rates: [max_quality_layers]f64 = [_]f64{0} ** max_quality_layers,
    rate_count: u8 = 0,
    progression: ProgressionOrder = .rpcl,
    poc_records: []const PocRecord = &.{},
    poc_in_tile_header: bool = false,
    mct: MultipleComponentTransform = .rct,
    transform: WaveletTransform = .reversible_5_3,
    quantization: QuantizationStyle = .none,
    guard_bits: u8 = 2,
    tile_width: u32 = 4096,
    tile_height: u32 = 4096,
    block_width: u16 = 64,
    block_height: u16 = 64,
    precincts: [33]PrecinctSize = defaultPrecincts(),
    precinct_count: u8 = 3,
    bypass: bool = false,
    reset_context: bool = false,
    terminate_all: bool = false,
    vertical_causal: bool = false,
    predictable_termination: bool = false,
    segmentation_symbols: bool = false,
    sop: bool = true,
    eph: bool = false,
    tlm: bool = true,
    ppm: bool = false,
    ppt: bool = false,
    tile_part_divisions: ?u8 = 'R',
    threads: u8 = 1,
    emit_temporary_payload_sidecar: bool = false,
    t1_backend: T1Backend = .iso_mq,

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
    t1_pass_stats: ebcot.EncodePassStats = .{},
};

fn normalizedEncodePrecinctOptions(options: LosslessOptions, levels: u8) LosslessOptions {
    var normalized = options;
    if (options.precinct_count == 0) return normalized;

    const resolution_count = @as(usize, levels) + 1;
    const option_count = @as(usize, options.precinct_count);
    var resolution: usize = 0;
    while (resolution < resolution_count) : (resolution += 1) {
        const cli_resolution = @as(usize, levels) - resolution;
        const source = if (cli_resolution < option_count)
            cli_resolution
        else
            option_count - 1;
        normalized.precincts[resolution] = options.precincts[source];
    }
    normalized.precinct_count = @intCast(resolution_count);
    return normalized;
}

pub const DecodeOptions = struct {
    threads: u8 = 1,
    t1_backend: T1Backend = .iso_mq,
};

pub const DecodeTimings = struct {
    total_ns: u64 = 0,
    sidecar_or_legacy_ns: u64 = 0,
    metadata_ns: u64 = 0,
    packet_catalog_ns: u64 = 0,
    packet_catalog_scan_ns: u64 = 0,
    packet_catalog_header_ns: u64 = 0,
    packet_catalog_finalize_ns: u64 = 0,
    block_payload_ns: u64 = 0,
    block_worker_jobs: u64 = 0,
    block_worker_ns_sum: u64 = 0,
    block_worker_ns_max: u64 = 0,
    block_worker_blocks_sum: u64 = 0,
    block_worker_blocks_max: u64 = 0,
    block_worker_payload_sum: u64 = 0,
    block_worker_payload_max: u64 = 0,
    wavelet_ns: u64 = 0,
    color_transform_ns: u64 = 0,
    t1_pass_stats: ebcot.DecodePassStats = .{},

    fn addStrictBlockWorker(self: *DecodeTimings, stats: StrictBlockWorkerStats) void {
        self.block_worker_jobs += 1;
        self.block_worker_ns_sum += stats.ns;
        self.block_worker_ns_max = @max(self.block_worker_ns_max, stats.ns);
        self.block_worker_blocks_sum += stats.blocks;
        self.block_worker_blocks_max = @max(self.block_worker_blocks_max, stats.blocks);
        self.block_worker_payload_sum += stats.payload_bytes;
        self.block_worker_payload_max = @max(self.block_worker_payload_max, stats.payload_bytes);
    }
};

const StrictBlockWorkerStats = struct {
    ns: u64 = 0,
    blocks: u64 = 0,
    payload_bytes: u64 = 0,
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

/// Encodes the narrow ISO/IEC 15444-1 grayscale profile currently supported
/// by z2000: one unsigned component, one tile, reversible 5/3, ISO MQ, RPCL,
/// in-band packet headers, PLT, and optional TLM/SOP/EPH markers. This is
/// the one-plane special case of the planar encoder below.
pub fn encodeLosslessGrayWithOptions(
    allocator: std.mem.Allocator,
    gray: image.GrayImage,
    options: LosslessOptions,
) ![]u8 {
    if (gray.white_is_zero) return CodestreamError.UnsupportedPayload;
    const pixels = std.math.mul(usize, gray.width, gray.height) catch return CodestreamError.ImageTooLarge;
    if (gray.samples.len != pixels) return CodestreamError.InvalidCodestream;
    var plane_slices = [1][]u16{gray.samples};
    return encodeLosslessPlanarWithOptions(allocator, .{
        .allocator = allocator,
        .width = gray.width,
        .height = gray.height,
        .bit_depth = gray.bit_depth,
        .planes = &plane_slices,
    }, options);
}

/// Bounded 1..4-plane reversible profile. Independent layouts use MCT none;
/// four-plane RGBA may use MCT=1, which applies RCT to RGB only and leaves the
/// final alpha plane independent. The current planar surface remains
/// single-tile RPCL with in-band headers and optional R tile-parts/TLM/SOP/EPH.
pub fn encodeLosslessPlanarWithOptions(
    allocator: std.mem.Allocator,
    planar: color.SamplePlanes,
    options: LosslessOptions,
) ![]u8 {
    if (planar.width == 0 or planar.height == 0 or
        planar.width > std.math.maxInt(u32) or planar.height > std.math.maxInt(u32))
    {
        return CodestreamError.ImageTooLarge;
    }
    if (planar.planes.len == 0 or planar.planes.len > max_codestream_components) {
        return CodestreamError.UnsupportedPayload;
    }
    var component_bit_depths = [_]u8{0} ** max_codestream_components;
    var mixed_component_precision = false;
    for (0..planar.planes.len) |component| {
        const component_depth = planar.componentBitDepth(component) orelse return CodestreamError.UnsupportedPayload;
        if (component_depth != 8 and component_depth != 16) return CodestreamError.UnsupportedPayload;
        component_bit_depths[component] = component_depth;
        if (component != 0 and component_depth != component_bit_depths[0]) mixed_component_precision = true;
    }
    if (mixed_component_precision != (planar.bit_depth == 0)) return CodestreamError.UnsupportedPayload;
    if (!mixed_component_precision and planar.bit_depth != component_bit_depths[0]) {
        return CodestreamError.UnsupportedPayload;
    }
    const pixels = std.math.mul(usize, planar.width, planar.height) catch return CodestreamError.ImageTooLarge;
    for (planar.planes) |plane| {
        if (plane.len != pixels) return CodestreamError.InvalidCodestream;
    }
    if (options.levels > 32) return CodestreamError.TooManyLevels;
    if (options.layers == 0 or options.layers > max_quality_layers or
        options.rate_count > options.layers or options.threads == 0)
    {
        return CodestreamError.InvalidCodestream;
    }
    try validateBlockSize(options.block_width, options.block_height);
    try validatePrecincts(options);
    try validateRates(options);
    try validateTilePartDivisions(options.tile_part_divisions);
    try validateCodingPath(options);

    const rct_alpha = options.mct == .rct and planar.planes.len == 4 and !mixed_component_precision;
    if (options.transform != .reversible_5_3 or options.quantization != .none or
        (options.mct != .none and !rct_alpha) or options.progression != .rpcl or
        options.poc_records.len != 0 or options.poc_in_tile_header or
        options.ppm or options.ppt or options.emit_temporary_payload_sidecar or
        options.t1_backend != .iso_mq)
    {
        return CodestreamError.UnsupportedPayload;
    }
    if (options.tile_part_divisions != null and options.tile_part_divisions != 'R') {
        return CodestreamError.UnsupportedPayload;
    }

    const grid = tile_grid.Grid.fromImageSize(
        planar.width,
        planar.height,
        options.tile_width,
        options.tile_height,
    ) catch |err| switch (err) {
        tile_grid.TileGridError.ImageTooLarge => return CodestreamError.ImageTooLarge,
        tile_grid.TileGridError.InvalidImage, tile_grid.TileGridError.InvalidTileGrid => return CodestreamError.InvalidCodestream,
    };
    if (!grid.isSingleTile()) return CodestreamError.UnsupportedPayload;

    const levels = actualDwtLevels(planar.width, planar.height, options.levels);
    const encode_options = normalizedEncodePrecinctOptions(options, levels);
    try validatePrecinctBlockSpans(encode_options);

    var scaffold_precincts: [33]packet_plan.Precinct = undefined;
    for (encode_options.precincts[0..encode_options.precinct_count], 0..) |precinct, index| {
        scaffold_precincts[index] = .{ .width = precinct.width, .height = precinct.height };
    }
    const block_style = ebcot.CodeBlockStyle{
        .bypass = encode_options.bypass,
        .reset_context = encode_options.reset_context,
        .terminate_all = encode_options.terminate_all,
        .vertical_causal = encode_options.vertical_causal,
        .predictable_termination = encode_options.predictable_termination,
        .segmentation_symbols = encode_options.segmentation_symbols,
    };
    const scaffold_options = tile_pipeline.PacketScaffoldOptions{
        .layers = encode_options.layers,
        .block_width = encode_options.block_width,
        .block_height = encode_options.block_height,
        .precincts = scaffold_precincts[0..encode_options.precinct_count],
        .rates = encode_options.rates,
        .rate_count = encode_options.rate_count,
    };
    var artifacts = if (rct_alpha)
        try tile_pipeline.buildPlanarRctAlphaRpclEncodeArtifactsIsoMq(
            allocator,
            planar,
            levels,
            scaffold_options,
            block_style,
        )
    else
        try tile_pipeline.buildPlanarRpclEncodeArtifactsIsoMq(
            allocator,
            planar,
            levels,
            scaffold_options,
            block_style,
        );
    defer artifacts.deinit();
    const component_count: u16 = @intCast(planar.planes.len);
    if (artifacts.levels != levels or artifacts.scaffold.components != component_count or
        artifacts.catalog.components != component_count)
    {
        return CodestreamError.InvalidCodestream;
    }

    return assembleSingleTileCodestream(allocator, .{
        .width = planar.width,
        .height = planar.height,
        .bit_depth = planar.bit_depth,
        .component_bit_depths = component_bit_depths,
        .components = component_count,
        .levels = levels,
        .packet_lengths = artifacts.stream.packet_lengths,
        .packet_header_lengths = artifacts.stream.packet_header_lengths,
        .packet_bytes = artifacts.stream.bytes,
    }, encode_options);
}

const ComponentSlices = struct {
    slices: [3][]i32,

    fn get(self: ComponentSlices, index: usize) []i32 {
        return self.slices[index];
    }
};

fn forwardComponents53(
    allocator: std.mem.Allocator,
    planes: *color.RctPlanes,
    options: LosslessOptions,
) !u8 {
    const levels = actualDwtLevels(planes.width, planes.height, options.levels);
    const slices = ComponentSlices{ .slices = .{ planes.planes[0], planes.planes[1], planes.planes[2] } };
    if (componentThreadCount(options) < 2) {
        var wavelet_workspace = try wavelet_int.Workspace.init(allocator, @max(planes.width, planes.height));
        defer wavelet_workspace.deinit();
        inline for (0..3) |component| {
            _ = try wavelet_int.forward53WithWorkspace(
                &wavelet_workspace,
                slices.get(component),
                planes.width,
                planes.height,
                levels,
            );
        }
        return levels;
    }

    // Multi-thread: distribute the three components' row/column bands across
    // all requested workers instead of capping at 3 component threads. On
    // >4-core machines the DWT is up to ~30% of a threaded encode and the
    // 3-way cap left most cores idle.
    _ = try wavelet_int.forward53Parallel(
        allocator,
        .{ slices.get(0), slices.get(1), slices.get(2) },
        planes.width,
        planes.height,
        levels,
        options.threads,
    );
    return levels;
}

/// Irreversible path front end: ICT, float 9/7 DWT, then deadzone scalar
/// quantization into the i32 coefficient planes shared with the reversible
/// pipeline.
fn forwardIrreversibleQuantizedPlanes(
    allocator: std.mem.Allocator,
    rgb: image.RgbImage,
    levels: u8,
    options: LosslessOptions,
    timings: ?*EncodeTimings,
) !color.RctPlanes {
    return forwardIrreversibleQuantizedPlanesForRegionMeasured(
        allocator,
        rgb,
        levels,
        options.quantization,
        0,
        0,
        options.threads,
        timings,
    );
}

const IrreversibleForwardPlaneJob = struct {
    plane: []f32,
    quantized: []i32,
    width: usize,
    height: usize,
    levels: u8,
    x0: u32,
    y0: u32,
    bands: []const subband.Band,
    deltas: []const f64,
    result: anyerror!void = {},
};

fn irreversibleForwardPlaneWorker(job: *IrreversibleForwardPlaneJob) void {
    job.result = irreversibleForwardPlane(job);
}

fn irreversibleForwardPlane(job: *IrreversibleForwardPlaneJob) anyerror!void {
    const done = try wavelet.forward2DOrigin(
        std.heap.smp_allocator,
        job.plane,
        job.width,
        job.height,
        job.levels,
        .irreversible_9_7,
        job.x0,
        job.y0,
    );
    if (done != job.levels) return CodestreamError.InvalidCodestream;
    for (job.bands, job.deltas) |band, delta| {
        quantizeBandRegion(job.plane, job.quantized, job.width, band.rect, delta);
    }
}

/// Quantize-only plane job for the intra-plane parallel DWT path, where the
/// 9/7 transform already ran jointly across all planes.
const IrreversibleQuantizePlaneJob = struct {
    plane: []const f32,
    quantized: []i32,
    width: usize,
    bands: []const subband.Band,
    deltas: []const f64,
    result: anyerror!void = {},
};

fn irreversibleQuantizePlaneWorker(job: *IrreversibleQuantizePlaneJob) void {
    for (job.bands, job.deltas) |band, delta| {
        quantizeBandRegion(job.plane, job.quantized, job.width, band.rect, delta);
    }
}

fn forwardIrreversibleQuantizedPlanesForRegion(
    allocator: std.mem.Allocator,
    rgb: image.RgbImage,
    levels: u8,
    quantization: QuantizationStyle,
    x0: u32,
    y0: u32,
    thread_count: u8,
) !color.RctPlanes {
    return forwardIrreversibleQuantizedPlanesForRegionMeasured(allocator, rgb, levels, quantization, x0, y0, thread_count, null);
}

/// Measured variant of the irreversible front end: the ICT stage accounts to
/// `color_transform_ns` and the fused per-plane 9/7 DWT + deadzone
/// quantization jobs account to `wavelet_ns`, so `--timings` no longer
/// reports the whole front end as MCT with an empty DWT row.
fn forwardIrreversibleQuantizedPlanesForRegionMeasured(
    allocator: std.mem.Allocator,
    rgb: image.RgbImage,
    levels: u8,
    quantization: QuantizationStyle,
    x0: u32,
    y0: u32,
    thread_count: u8,
    timings: ?*EncodeTimings,
) !color.RctPlanes {
    const color_start = monotonicNs();
    var ict = try color.forwardIct(allocator, rgb);
    defer ict.deinit();
    if (timings) |t| t.color_transform_ns += elapsedNs(color_start);

    const x1 = std.math.add(u32, x0, std.math.cast(u32, ict.width) orelse return CodestreamError.ImageTooLarge) catch
        return CodestreamError.ImageTooLarge;
    const y1 = std.math.add(u32, y0, std.math.cast(u32, ict.height) orelse return CodestreamError.ImageTooLarge) catch
        return CodestreamError.ImageTooLarge;
    const bands = try subband.makeBandsForRegion(allocator, x0, y0, x1, y1, levels);
    defer allocator.free(bands);
    const deltas = try allocator.alloc(f64, bands.len);
    defer allocator.free(deltas);
    for (bands, deltas) |band, *delta| {
        delta.* = irreversibleBandDelta(
            rgb.bit_depth,
            band.kind,
            try irreversibleBandStepSizeFor(quantization, rgb.bit_depth, band.kind, band.level, levels),
        );
    }

    var out = try color.RctPlanes.init(allocator, ict.width, ict.height, rgb.bit_depth, 3);
    errdefer out.deinit();
    const y = out.planes[0];
    const cb = out.planes[1];
    const cr = out.planes[2];

    const wavelet_start = monotonicNs();
    if (thread_count > 1) {
        // Intra-plane parallel DWT: one joint 9/7 transform over the three
        // planes with row/column bands spread across all `thread_count`
        // workers, then 3-way quantize jobs. The per-plane job path below
        // caps the DWT at three threads and starves wider machines. The
        // per-column/per-row arithmetic is unchanged, so streams stay
        // bit-identical.
        const done = try wavelet.forward97Parallel(
            std.heap.smp_allocator,
            .{ ict.planes[0], ict.planes[1], ict.planes[2] },
            ict.width,
            ict.height,
            levels,
            x0,
            y0,
            thread_count,
        );
        if (done != levels) return CodestreamError.InvalidCodestream;
        var jobs = [3]IrreversibleQuantizePlaneJob{
            .{ .plane = ict.planes[0], .quantized = y, .width = ict.width, .bands = bands, .deltas = deltas },
            .{ .plane = ict.planes[1], .quantized = cb, .width = ict.width, .bands = bands, .deltas = deltas },
            .{ .plane = ict.planes[2], .quantized = cr, .width = ict.width, .bands = bands, .deltas = deltas },
        };
        try runComponentJobs(IrreversibleQuantizePlaneJob, &jobs, componentThreadCountFor(thread_count), irreversibleQuantizePlaneWorker);
    } else {
        // Serial/tile-worker path: each component's 9/7 DWT and deadzone
        // quantization is independent, so the three planes run as fused
        // component jobs (same pattern as the 5/3 path).
        var jobs = [3]IrreversibleForwardPlaneJob{
            .{ .plane = ict.planes[0], .quantized = y, .width = ict.width, .height = ict.height, .levels = levels, .x0 = x0, .y0 = y0, .bands = bands, .deltas = deltas },
            .{ .plane = ict.planes[1], .quantized = cb, .width = ict.width, .height = ict.height, .levels = levels, .x0 = x0, .y0 = y0, .bands = bands, .deltas = deltas },
            .{ .plane = ict.planes[2], .quantized = cr, .width = ict.width, .height = ict.height, .levels = levels, .x0 = x0, .y0 = y0, .bands = bands, .deltas = deltas },
        };
        try runComponentJobs(IrreversibleForwardPlaneJob, &jobs, thread_count, irreversibleForwardPlaneWorker);
    }
    if (timings) |t| t.wavelet_ns += elapsedNs(wavelet_start);

    return out;
}

/// Tile front end for the irreversible multi-tile path: extracts the tile
/// region, then runs the same ICT + 9/7 + deadzone quantization the
/// single-tile path uses, retaining the tile's reference-grid lifting parity.
const IrreversibleTileFrontEndContext = struct {
    quantization: QuantizationStyle,
};

fn buildIrreversibleQuantizedTile(
    context: *const anyopaque,
    allocator: std.mem.Allocator,
    source: image.RgbImage,
    tile: tile_grid.Tile,
    levels: u8,
) anyerror!tile_pipeline.RctTile {
    const ctx: *const IrreversibleTileFrontEndContext = @ptrCast(@alignCast(context));
    var rgb_tile = try tile_grid.extractRgbTile(allocator, source, tile.rect);
    defer rgb_tile.deinit();
    // Tiles already run on parallel tile workers; keep the per-plane stage
    // serial here to avoid oversubscription.
    const planes = try forwardIrreversibleQuantizedPlanesForRegion(
        allocator,
        rgb_tile,
        levels,
        ctx.quantization,
        tile.rect.x0,
        tile.rect.y0,
        1,
    );
    return .{ .tile = tile, .planes = planes };
}

/// Per-band nominal bitplane (Mb) table for irreversible tiles, indexed
/// [band_level][kind]: Mb derives from the signalled epsilon_b (E-2), which
/// is identical for every tile because the step tables depend only on the
/// global bit depth, quantization style, and level count.
fn irreversibleNominalBitplaneTable(
    bit_depth: u8,
    levels: u8,
    guard_bits: u8,
    quantization: QuantizationStyle,
) ![33][4]u8 {
    var table = [_][4]u8{.{ 0, 0, 0, 0 }} ** 33;
    if (levels > 32) return CodestreamError.UnsupportedPayload;
    var level: u8 = 1;
    while (level <= levels) : (level += 1) {
        inline for (.{ subband.Kind.hl, subband.Kind.lh, subband.Kind.hh }) |kind| {
            table[level][@intFromEnum(kind)] = try bandNominalBitplanesForTransform(
                bit_depth,
                kind,
                level,
                .irreversible_9_7,
                guard_bits,
                quantization,
                levels,
            );
        }
    }
    table[levels][@intFromEnum(subband.Kind.ll)] = try bandNominalBitplanesForTransform(
        bit_depth,
        .ll,
        levels,
        .irreversible_9_7,
        guard_bits,
        quantization,
        levels,
    );
    return table;
}

/// Per-band PCRD distortion weight table for irreversible tiles, indexed
/// [band_level][kind]: `(reconstruction step delta x 9/7 synthesis norm)^2`
/// converts quantized-coefficient squared error into weighted reconstruction
/// squared error (ISO 15444-1 J.14). Identical for every tile because the
/// step tables and norms depend only on the global bit depth, quantization
/// style, and level count. Mirrors the single-tile pcrdBandWeight.
fn irreversibleBandWeightTable(
    bit_depth: u8,
    levels: u8,
    quantization: QuantizationStyle,
) ![33][4]f64 {
    var table = [_][4]f64{.{ 0, 0, 0, 0 }} ** 33;
    if (levels > 32) return CodestreamError.UnsupportedPayload;
    const kinds = [_]subband.Kind{ .ll, .hl, .lh, .hh };
    var level: u8 = 1;
    while (level <= levels) : (level += 1) {
        for (kinds) |kind| {
            if (kind == .ll and level != levels) continue;
            const opj_level: usize = if (kind == .ll) level else @as(usize, level) - 1;
            const orient: usize = @intFromEnum(kind);
            const step = try irreversibleBandStepSizeFor(quantization, bit_depth, kind, level, levels);
            const weighted = irreversiblePcrdDelta(bit_depth, kind, step) * dwt97Norm(opj_level, orient);
            table[level][orient] = weighted * weighted;
        }
    }
    return table;
}

fn quantizeBandRegion(src: []const f32, dst: []i32, stride: usize, rect: subband.Rect, delta: f64) void {
    var row: usize = 0;
    while (row < rect.height) : (row += 1) {
        const base = (rect.y + row) * stride + rect.x;
        var col: usize = 0;
        while (col < rect.width) : (col += 1) {
            const value: f64 = src[base + col];
            const magnitude = @floor(@abs(value) / delta);
            const quantized: i32 = @intFromFloat(@min(magnitude, 2147483647.0));
            dst[base + col] = if (value < 0) -quantized else quantized;
        }
    }
}

fn dequantizeBandRegion(src: []const i32, dst: []f32, stride: usize, rect: subband.Rect, delta: f64) void {
    var row: usize = 0;
    while (row < rect.height) : (row += 1) {
        const base = (rect.y + row) * stride + rect.x;
        var col: usize = 0;
        while (col < rect.width) : (col += 1) {
            const q = src[base + col];
            if (q == 0) {
                dst[base + col] = 0;
                continue;
            }
            const magnitude = @as(f64, @floatFromInt(@abs(q))) + 0.5;
            const value = magnitude * delta;
            dst[base + col] = @floatCast(if (q < 0) -value else value);
        }
    }
}

fn inverseComponents53(
    allocator: std.mem.Allocator,
    slices: ComponentSlices,
    width: usize,
    height: usize,
    levels: u8,
    x0: u32,
    y0: u32,
    options: DecodeOptions,
) !void {
    if (x0 != 0 or y0 != 0) {
        var wavelet_workspace = try wavelet_int.Workspace.init(allocator, @max(width, height));
        defer wavelet_workspace.deinit();
        inline for (0..3) |component| {
            try wavelet_int.inverse53WithWorkspaceOrigin(
                &wavelet_workspace,
                slices.get(component),
                width,
                height,
                levels,
                x0,
                y0,
            );
        }
        return;
    }
    if (componentThreadCountFor(options.threads) < 2) {
        var wavelet_workspace = try wavelet_int.Workspace.init(allocator, @max(width, height));
        defer wavelet_workspace.deinit();
        inline for (0..3) |component| {
            try wavelet_int.inverse53WithWorkspace(
                &wavelet_workspace,
                slices.get(component),
                width,
                height,
                levels,
            );
        }
        return;
    }

    // Multi-thread: full-core parallel inverse DWT (see forwardComponents53).
    try wavelet_int.inverse53Parallel(
        allocator,
        .{ slices.get(0), slices.get(1), slices.get(2) },
        width,
        height,
        levels,
        options.threads,
    );
}

fn runComponentJobs(
    comptime Job: type,
    jobs: *[3]Job,
    thread_count: u8,
    comptime worker: fn (*Job) void,
) !void {
    const active_threads: usize = @intCast(@min(thread_count, 3));
    const spawn_count = active_threads - 1;
    var threads: [2]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < spawn_count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, worker, .{&jobs[spawned]}) catch |err| {
            for (threads[0..spawned]) |thread| thread.join();
            return err;
        };
    }

    var component = spawned;
    while (component < jobs.len) : (component += 1) {
        worker(&jobs[component]);
    }

    for (threads[0..spawned]) |thread| thread.join();
    for (jobs) |job| try job.result;
}

fn actualDwtLevels(width: usize, height: usize, requested_levels: u8) u8 {
    var cur_width = width;
    var cur_height = height;
    var done: u8 = 0;
    while (done < requested_levels and (cur_width > 1 or cur_height > 1)) : (done += 1) {
        cur_width = (cur_width + 1) / 2;
        cur_height = (cur_height + 1) / 2;
    }
    return done;
}

fn componentThreadCount(options: LosslessOptions) u8 {
    return componentThreadCountFor(options.threads);
}

fn componentThreadCountFor(thread_count: u8) u8 {
    return @min(thread_count, 3);
}

const ComponentPayloadJob = struct {
    component_index: u8,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    catalog: []const RpclShadowBlock,
    options: LosslessOptions,
    bytes: []u8 = &.{},
    result: anyerror!void = {},

    fn deinit(self: *ComponentPayloadJob) void {
        std.heap.smp_allocator.free(self.bytes);
        self.bytes = &.{};
    }
};

const ComponentCatalogJob = struct {
    plane: []const i32,
    stride: usize,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    nominal_bitplanes: u8,
    options: LosslessOptions,
    include_bitplane_payload: bool,
    catalog: ComponentRpclShadowCatalog = undefined,
    initialized: bool = false,
    result: anyerror!void = {},

    fn deinit(self: *ComponentCatalogJob) void {
        if (self.initialized) {
            self.catalog.deinit();
            self.initialized = false;
        }
    }
};

const ComponentCatalogBlockJob = struct {
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    catalog_blocks: []RpclShadowBlock,
    next_block: *std.atomic.Value(usize),
    block_order: []const usize,
    nominal_bitplanes: u8,
    options: LosslessOptions,
    include_bitplane_payload: bool,
    initialized: std.ArrayList(usize) = .empty,
    result: anyerror!void = {},

    fn deinit(self: *ComponentCatalogBlockJob) void {
        for (self.initialized.items) |block_index| {
            self.catalog_blocks[block_index].deinit(self.allocator);
        }
        self.initialized.deinit(self.allocator);
        self.initialized = .empty;
    }

    fn release(self: *ComponentCatalogBlockJob) void {
        self.initialized.clearRetainingCapacity();
    }
};

const ComponentCatalogBlockRef = struct {
    component: u8,
    block_index: usize,
};

const ComponentCatalogBlockInit = struct {
    component: u8,
    block_index: usize,
};

const ComponentCatalogAllBlockJob = struct {
    allocator: std.mem.Allocator,
    planes: [3][]const i32,
    stride: usize,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    catalog_blocks: [3][]RpclShadowBlock,
    next_block: *std.atomic.Value(usize),
    block_order: []const ComponentCatalogBlockRef,
    nominal_bitplanes: u8,
    options: LosslessOptions,
    include_bitplane_payload: bool,
    initialized: std.ArrayList(ComponentCatalogBlockInit) = .empty,
    result: anyerror!void = {},

    fn deinit(self: *ComponentCatalogAllBlockJob) void {
        for (self.initialized.items) |record| {
            self.catalog_blocks[record.component][record.block_index].deinit(self.allocator);
        }
        self.initialized.deinit(self.allocator);
        self.initialized = .empty;
    }

    fn release(self: *ComponentCatalogAllBlockJob) void {
        self.initialized.clearRetainingCapacity();
    }
};

const ComponentBlockPayloadJob = struct {
    blocks: []const subband.CodeBlock,
    catalog: []const RpclShadowBlock,
    options: LosslessOptions,
    bytes: []u8 = &.{},
    result: anyerror!void = {},

    fn deinit(self: *ComponentBlockPayloadJob) void {
        std.heap.smp_allocator.free(self.bytes);
        self.bytes = &.{};
    }
};

const RpclShadowBlock = struct {
    bitplane: ?bitplane.EncodedBlockPasses,
    segment: ebcot.CodeBlockSegment,
    pass_distortions: []f64 = &.{},
    layers: [max_quality_layers]t2.LayerTruncation,
    encoded: t2.EncodedLayerBlock,

    fn deinit(self: *RpclShadowBlock, allocator: std.mem.Allocator) void {
        if (self.bitplane) |*passes| passes.deinit(allocator);
        self.segment.deinit(allocator);
        if (self.pass_distortions.len > 0) allocator.free(self.pass_distortions);
        self.* = undefined;
    }
};

const ComponentRpclShadowCatalog = struct {
    allocator: std.mem.Allocator,
    blocks: []RpclShadowBlock,

    fn deinit(self: *ComponentRpclShadowCatalog) void {
        for (self.blocks) |*block| block.deinit(self.allocator);
        self.allocator.free(self.blocks);
        self.* = undefined;
    }
};

const PacketStreamInfo = struct {
    packets: u64 = 0,
    bytes: u64 = 0,
};

const RpclPacketStream = struct {
    allocator: std.mem.Allocator = undefined,
    packet_lengths: []u32 = &.{},
    packet_header_lengths: []u32 = &.{},
    packet_bytes: []u8 = &.{},

    fn deinit(self: *RpclPacketStream) void {
        if (self.packet_lengths.len > 0) self.allocator.free(self.packet_lengths);
        if (self.packet_header_lengths.len > 0) self.allocator.free(self.packet_header_lengths);
        if (self.packet_bytes.len > 0) self.allocator.free(self.packet_bytes);
        self.* = .{};
    }
};

pub const StrictPacketEntry = struct {
    packet: packet_plan.Packet,
    tile_index: u16,
    tile_part_index: u8,
    byte_offset: usize,
    byte_length: u32,
};

pub const StrictPacketCatalog = struct {
    allocator: std.mem.Allocator = undefined,
    entries: []StrictPacketEntry = &.{},
    packet_bytes: []u8 = &.{},

    pub fn deinit(self: *StrictPacketCatalog) void {
        if (self.entries.len > 0) self.allocator.free(self.entries);
        if (self.packet_bytes.len > 0) self.allocator.free(self.packet_bytes);
        self.* = .{};
    }

    pub fn packetBytes(self: StrictPacketCatalog, entry: StrictPacketEntry) []const u8 {
        const byte_length: usize = @intCast(entry.byte_length);
        return self.packet_bytes[entry.byte_offset..][0..byte_length];
    }
};

pub const StrictPacketHeaderAudit = struct {
    packets: u64 = 0,
    present_packets: u64 = 0,
    absent_packets: u64 = 0,
    geometry_empty_packets: u64 = 0,
    header_decoded_packets: u64 = 0,
    header_bytes: u64 = 0,
    payload_bytes: u64 = 0,
    included_blocks: u64 = 0,
    assembled_blocks: u64 = 0,
    assembled_bytes: u64 = 0,
    assembled_passes: u64 = 0,
    t1_ready_blocks: u64 = 0,
};

pub const StrictPacketBlock = struct {
    metadata_ready: bool,
    band_index: usize,
    rect: subband.Rect,
    nominal_bitplanes: u8,
    encoded_bitplanes: u8,
    code_block_style: ebcot.CodeBlockStyle = .{},
    cumulative_passes: u16,
    cumulative_bytes: u64,
    payload_offset: usize,
    payload_length: usize,
    segment_count: u8 = 0,
    segment_lengths: [ebcot.max_block_segments]u64 = [_]u64{0} ** ebcot.max_block_segments,
};

pub const StrictPacketBlockCatalog = struct {
    allocator: std.mem.Allocator = undefined,
    component_count: u16 = 3,
    component_widths: [max_codestream_components]usize = [_]usize{0} ** max_codestream_components,
    component_heights: [max_codestream_components]usize = [_]usize{0} ** max_codestream_components,
    component_x0: [max_codestream_components]u32 = [_]u32{0} ** max_codestream_components,
    component_y0: [max_codestream_components]u32 = [_]u32{0} ** max_codestream_components,
    components: [max_codestream_components][]StrictPacketBlock = [_][]StrictPacketBlock{&.{}} ** max_codestream_components,
    payloads: [max_codestream_components][]u8 = [_][]u8{&.{}} ** max_codestream_components,

    pub fn deinit(self: *StrictPacketBlockCatalog) void {
        for (0..self.component_count) |component| {
            if (self.components[component].len > 0) self.allocator.free(self.components[component]);
            if (self.payloads[component].len > 0) self.allocator.free(self.payloads[component]);
        }
        self.* = .{};
    }

    pub fn blockPayload(self: StrictPacketBlockCatalog, component: usize, block_index: usize) []const u8 {
        const block = self.components[component][block_index];
        return self.payloads[component][block.payload_offset..][0..block.payload_length];
    }
};

const TlmEntry = struct {
    tile_index: u16,
    psot: u32,
};

const MainHeaderPacketMarkers = struct {
    sop: bool,
    eph: bool,
};

const StrictSotInfo = struct {
    tile_index: u16,
    tile_part_index: u8,
    tile_part_count: u8,
    psot: u32,
};

const StrictTilePartPacketPlan = struct {
    count: usize = 0,
    packet_counts: [256]usize = [_]usize{0} ** 256,
    /// True when any tile-part carried no PLT: per-part packet counts are then
    /// unknown until the catalog stage decodes headers in stream order
    /// (foreign-stream Stage B), so the R-division plan validation is skipped.
    missing_plt: bool = false,
};

const StrictTilePartHeader = struct {
    sot: StrictSotInfo,
    sod: usize,
    end: usize,
    packet_payload_bytes: usize,
    packet_lengths: std.ArrayList(usize),
    packed_headers: std.ArrayList(u8),
    poc_records: std.ArrayList(poc.Record),

    fn deinit(self: *StrictTilePartHeader, allocator: std.mem.Allocator) void {
        self.packet_lengths.deinit(allocator);
        self.packed_headers.deinit(allocator);
        self.poc_records.deinit(allocator);
        self.* = undefined;
    }
};

const TilePartPocLimits = struct {
    component_count: u16,
    resolution_count: u8,
    layer_count: u16,
};

const TilePartPocTarget = struct {
    records: *std.ArrayList(poc.Record),
    limits: TilePartPocLimits,
    allowed: bool,
};

const StrictMainHeaderIndex = struct {
    allocator: std.mem.Allocator,
    first_sot: usize,
    packet_markers: MainHeaderPacketMarkers,
    tlm_entries: ?[]TlmEntry = null,
    ppm_headers: ?ppm.PackedHeaders = null,
    poc_records: ?[]poc.Record = null,

    fn deinit(self: *StrictMainHeaderIndex) void {
        if (self.tlm_entries) |entries| self.allocator.free(entries);
        if (self.ppm_headers) |*headers| headers.deinit();
        if (self.poc_records) |records| self.allocator.free(records);
        self.* = undefined;
    }
};

const TemporaryRpclBlock = struct {
    band_index: usize,
    rect: subband.Rect,
    nominal_bitplanes: u8,
    encoded_bitplanes: u8,
    non_zero_count: u32,
    layers: [max_quality_layers]t2.LayerTruncation,
    passes: []ebcot.CodeBlockPassPayload,
    payload: []const u8,
};

const TemporaryComponentRpclCatalog = struct {
    allocator: std.mem.Allocator,
    blocks: []TemporaryRpclBlock,

    fn deinit(self: *TemporaryComponentRpclCatalog) void {
        for (self.blocks) |block| {
            if (block.passes.len > 0) self.allocator.free(block.passes);
        }
        self.allocator.free(self.blocks);
        self.* = undefined;
    }
};

const RpclBlockIndexCell = struct {
    indexes: std.ArrayList(usize) = .empty,
};

const RpclPacketBandGroup = struct {
    band_index: usize,
    encoded: []t2.EncodedLayerBlock,
    writer_state: t2.PrecinctPacketWriterState,

    fn deinit(self: *RpclPacketBandGroup, allocator: std.mem.Allocator) void {
        self.writer_state.deinit();
        allocator.free(self.encoded);
        self.* = undefined;
    }
};

/// One RPCL packet targets the LL band at resolution 0, or the HL/LH/HH
/// trio at higher resolutions.
const max_rpcl_packet_band_groups = 3;
const missing_packet_source_index = std.math.maxInt(usize);

const PreparedRpclPacketGroup = struct {
    packet_blocks: []t2.PacketBlock,

    fn deinit(self: *PreparedRpclPacketGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.packet_blocks);
        self.* = undefined;
    }
};

const RpclPacketReaderBandGroup = struct {
    band_index: usize,
    source_indexes: []usize,
    locations: []t2.PacketBlockLocation,
    reader_state: t2.PrecinctPacketReaderState,
    decoded: []t2.DecodedPacketBlock,
    payloads: []?[]const u8,
    max_zero_bitplanes: u8,

    fn deinit(self: *RpclPacketReaderBandGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.payloads);
        allocator.free(self.decoded);
        self.reader_state.deinit();
        allocator.free(self.locations);
        allocator.free(self.source_indexes);
        self.* = undefined;
    }
};

const StrictPacketAuditBandGroup = struct {
    source_indexes: []usize,
    locations: []t2.PacketBlockLocation,
    reader_state: t2.PrecinctPacketReaderState,
    decoded: []t2.DecodedPacketBlock,
    max_zero_bitplanes: u8,

    fn deinit(self: *StrictPacketAuditBandGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.decoded);
        self.reader_state.deinit();
        allocator.free(self.locations);
        allocator.free(self.source_indexes);
        self.* = undefined;
    }
};

const StrictRpclBlockAssembly = struct {
    payload: std.ArrayList(u8) = .empty,
    payload_offset: usize = 0,
    payload_length: usize = 0,
    cumulative_passes: u16 = 0,
    cumulative_bytes: u64 = 0,
    metadata_ready: bool = false,
    band_index: usize = 0,
    rect: subband.Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    nominal_bitplanes: u8 = 0,
    encoded_bitplanes: u8 = 0,
    code_block_style: ebcot.CodeBlockStyle = .{},
    segment_count: u8 = 0,
    segment_lengths: [ebcot.max_block_segments]u64 = [_]u64{0} ** ebcot.max_block_segments,

    fn appendSegmentLengths(self: *StrictRpclBlockAssembly, decoded: t2.DecodedPacketBlock) !void {
        var index: u8 = 0;
        while (index < decoded.segment_count) : (index += 1) {
            if (self.segment_count >= ebcot.max_block_segments) return CodestreamError.InvalidCodestream;
            self.segment_lengths[self.segment_count] = decoded.segment_lengths[index];
            self.segment_count += 1;
        }
    }

    fn deinit(self: *StrictRpclBlockAssembly, allocator: std.mem.Allocator) void {
        self.payload.deinit(allocator);
        self.* = .{};
    }
};

const StrictComponentAssembly = struct {
    allocator: std.mem.Allocator,
    blocks: []StrictRpclBlockAssembly,
    width: usize = 0,
    height: usize = 0,
    x0: u32 = 0,
    y0: u32 = 0,
    payloads: std.ArrayList(u8) = .empty,
    use_component_payloads: bool = false,

    fn init(allocator: std.mem.Allocator, block_count: usize, use_component_payloads: bool) !StrictComponentAssembly {
        const blocks = try allocator.alloc(StrictRpclBlockAssembly, block_count);
        for (blocks) |*block| block.* = .{};
        return .{
            .allocator = allocator,
            .blocks = blocks,
            .use_component_payloads = use_component_payloads,
        };
    }

    fn deinit(self: *StrictComponentAssembly) void {
        for (self.blocks) |*block| block.deinit(self.allocator);
        self.payloads.deinit(self.allocator);
        self.allocator.free(self.blocks);
        self.* = undefined;
    }
};

const StrictComponentAssemblySet = struct {
    assemblies: [max_codestream_components]StrictComponentAssembly = undefined,
    initialized: usize = 0,

    fn init(
        allocator: std.mem.Allocator,
        component_count: u16,
        block_counts: []const usize,
        use_component_payloads: bool,
    ) !StrictComponentAssemblySet {
        if (component_count < 1 or component_count > max_codestream_components or block_counts.len != component_count) {
            return CodestreamError.UnsupportedPayload;
        }
        var set = StrictComponentAssemblySet{};
        errdefer set.deinit();
        for (0..component_count) |component| {
            set.assemblies[component] = try StrictComponentAssembly.init(allocator, block_counts[component], use_component_payloads);
            set.initialized += 1;
        }
        return set;
    }

    fn deinit(self: *StrictComponentAssemblySet) void {
        for (self.assemblies[0..self.initialized]) |*assembly| assembly.deinit();
        self.* = .{};
    }
};

const StrictRpclImage = struct {
    image: image.RgbImage,
    complete: bool,
};

const RpclBlockIndex = struct {
    allocator: std.mem.Allocator,
    component_count: u16,
    resolution_offsets: [33]usize,
    resolution_count: u8,
    cells: []RpclBlockIndexCell,

    fn init(allocator: std.mem.Allocator, plan: packet_plan.Plan, component_count: u16) !RpclBlockIndex {
        if (component_count < 1 or component_count > max_codestream_components) return CodestreamError.UnsupportedPayload;
        var resolution_offsets: [33]usize = [_]usize{0} ** 33;
        var cell_count: usize = 0;
        var resolution_index: usize = 0;
        while (resolution_index < plan.resolution_count) : (resolution_index += 1) {
            resolution_offsets[resolution_index] = cell_count;
            const resolution_cells = try std.math.mul(
                usize,
                @as(usize, @intCast(plan.resolutions[resolution_index].precincts)),
                component_count,
            );
            cell_count = try std.math.add(usize, cell_count, resolution_cells);
        }

        const cells = try allocator.alloc(RpclBlockIndexCell, cell_count);
        for (cells) |*entry| entry.* = .{};
        return .{
            .allocator = allocator,
            .component_count = component_count,
            .resolution_offsets = resolution_offsets,
            .resolution_count = plan.resolution_count,
            .cells = cells,
        };
    }

    fn deinit(self: *RpclBlockIndex) void {
        for (self.cells) |*entry| entry.indexes.deinit(self.allocator);
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    fn cell(self: *RpclBlockIndex, resolution: u8, precinct_index: u64, component: u16) !*RpclBlockIndexCell {
        if (resolution >= self.resolution_count or component >= self.component_count) return CodestreamError.InvalidCodestream;
        const offset = try std.math.add(usize, self.resolution_offsets[resolution], try std.math.mul(usize, @as(usize, @intCast(precinct_index)), self.component_count));
        const index = try std.math.add(usize, offset, @as(usize, @intCast(component)));
        if (index >= self.cells.len) return CodestreamError.InvalidCodestream;
        return &self.cells[index];
    }

    fn indexesFor(self: *const RpclBlockIndex, resolution: u8, precinct_index: u64, component: u16) ![]const usize {
        if (resolution >= self.resolution_count or component >= self.component_count) return CodestreamError.InvalidCodestream;
        const offset = try std.math.add(usize, self.resolution_offsets[resolution], try std.math.mul(usize, @as(usize, @intCast(precinct_index)), self.component_count));
        const index = try std.math.add(usize, offset, @as(usize, @intCast(component)));
        if (index >= self.cells.len) return CodestreamError.InvalidCodestream;
        return self.cells[index].indexes.items;
    }
};

const StrictComponentGeometry = struct {
    allocator: std.mem.Allocator,
    plan: packet_plan.Plan,
    bands: []subband.Band,
    blocks: []subband.CodeBlock,
    rpcl_index: RpclBlockIndex,
    width: usize,
    height: usize,
    x0: u32,
    y0: u32,
    xrsiz: u8,
    yrsiz: u8,

    fn deinit(self: *StrictComponentGeometry) void {
        self.rpcl_index.deinit();
        self.allocator.free(self.blocks);
        self.allocator.free(self.bands);
        self.* = undefined;
    }

    fn localPacket(self: StrictComponentGeometry, packet: packet_plan.Packet) !packet_plan.Packet {
        if (packet.resolution >= self.plan.resolution_count) return CodestreamError.InvalidCodestream;
        const resolution = self.plan.resolutions[packet.resolution];
        if (packet.precinct_index >= resolution.precincts) return CodestreamError.InvalidCodestream;
        return .{
            .sequence = packet.sequence,
            .resolution = packet.resolution,
            .precinct_x = resolution.precinct_x0 + @as(u32, @intCast(packet.precinct_index % resolution.precincts_x)),
            .precinct_y = resolution.precinct_y0 + @as(u32, @intCast(packet.precinct_index / resolution.precincts_x)),
            .precinct_index = packet.precinct_index,
            .component = 0,
            .layer = packet.layer,
        };
    }
};

const StrictComponentGeometrySet = struct {
    geometries: [max_codestream_components]StrictComponentGeometry = undefined,
    component_geometry_indexes: [max_codestream_components]u8 = [_]u8{0} ** max_codestream_components,
    component_count: u16 = 0,
    initialized: usize = 0,

    fn init(allocator: std.mem.Allocator, header: TemporaryHeader) !StrictComponentGeometrySet {
        if (header.component_count < 1 or header.component_count > max_codestream_components) {
            return CodestreamError.UnsupportedPayload;
        }
        const reference_plan = temporaryPacketPlan(header);
        if (reference_plan.resolution_count != @as(u8, header.levels) + 1) {
            return CodestreamError.InvalidCodestream;
        }
        const component_plans = try StrictComponentPacketPlans.init(
            reference_plan,
            header.component_count,
            header.layers,
            header.component_xrsiz,
            header.component_yrsiz,
        );

        var set = StrictComponentGeometrySet{ .component_count = header.component_count };
        errdefer set.deinit();
        for (0..header.component_count) |component| {
            const component_plan = component_plans.components[component];
            const xrsiz = component_plan.xrsiz;
            const yrsiz = component_plan.yrsiz;

            var existing_index: ?u8 = null;
            for (set.geometries[0..set.initialized], 0..) |geometry, geometry_index| {
                if (geometry.xrsiz == xrsiz and geometry.yrsiz == yrsiz) {
                    existing_index = @intCast(geometry_index);
                    break;
                }
            }
            if (existing_index) |geometry_index| {
                set.component_geometry_indexes[component] = geometry_index;
                continue;
            }

            const plan = component_plan.plan;
            const full = plan.resolutions[plan.resolution_count - 1];

            const bands = try makeBandsForPacketPlan(allocator, plan, header.levels);
            errdefer allocator.free(bands);
            const blocks = try makeCodeBlocksForPacketPlan(allocator, bands, header.block_width, header.block_height, plan);
            errdefer allocator.free(blocks);
            var rpcl_index = try buildRpclBlockIndex(allocator, plan, 1, header.levels, bands, blocks);
            errdefer rpcl_index.deinit();

            const geometry_index = set.initialized;
            set.geometries[geometry_index] = .{
                .allocator = allocator,
                .plan = plan,
                .bands = bands,
                .blocks = blocks,
                .rpcl_index = rpcl_index,
                .width = full.width,
                .height = full.height,
                .x0 = full.x0,
                .y0 = full.y0,
                .xrsiz = xrsiz,
                .yrsiz = yrsiz,
            };
            set.component_geometry_indexes[component] = @intCast(geometry_index);
            set.initialized += 1;
        }
        return set;
    }

    fn geometryFor(self: *const StrictComponentGeometrySet, component: usize) !*const StrictComponentGeometry {
        if (component >= self.component_count) return CodestreamError.InvalidCodestream;
        const geometry_index = self.component_geometry_indexes[component];
        if (geometry_index >= self.initialized) return CodestreamError.InvalidCodestream;
        return &self.geometries[geometry_index];
    }

    fn deinit(self: *StrictComponentGeometrySet) void {
        for (self.geometries[0..self.initialized]) |*geometry| geometry.deinit();
        self.* = .{};
    }
};

fn ceilDivU32(value: u32, divisor: u8) u32 {
    return @intCast((@as(u64, value) + divisor - 1) / divisor);
}

const StrictComponentPacketPlans = struct {
    components: [max_codestream_components]packet_plan.SampledComponentPlan = undefined,
    component_count: u16,
    packet_count: u64,
    resolution_packets: [33]u64 = [_]u64{0} ** 33,

    fn init(
        reference: packet_plan.Plan,
        component_count: u16,
        layers: u16,
        component_xrsiz: [max_codestream_components]u8,
        component_yrsiz: [max_codestream_components]u8,
    ) !StrictComponentPacketPlans {
        if (component_count < 1 or component_count > max_codestream_components or
            reference.resolution_count == 0 or layers == 0)
        {
            return CodestreamError.InvalidCodestream;
        }
        const reference_full = reference.resolutions[reference.resolution_count - 1];
        const reference_x1 = std.math.add(u32, reference_full.x0, reference_full.width) catch
            return CodestreamError.InvalidCodestream;
        const reference_y1 = std.math.add(u32, reference_full.y0, reference_full.height) catch
            return CodestreamError.InvalidCodestream;
        var precincts: [33]packet_plan.Precinct = undefined;
        for (reference.resolutions[0..reference.resolution_count], 0..) |resolution, index| {
            precincts[index] = .{ .width = resolution.precinct_width, .height = resolution.precinct_height };
        }

        var result = StrictComponentPacketPlans{
            .component_count = component_count,
            .packet_count = 0,
        };
        for (0..component_count) |component| {
            const xrsiz = component_xrsiz[component];
            const yrsiz = component_yrsiz[component];
            if (xrsiz == 0 or yrsiz == 0) return CodestreamError.InvalidCodestream;
            const component_x0 = ceilDivU32(reference_full.x0, xrsiz);
            const component_y0 = ceilDivU32(reference_full.y0, yrsiz);
            const component_x1 = ceilDivU32(reference_x1, xrsiz);
            const component_y1 = ceilDivU32(reference_y1, yrsiz);
            if (component_x1 <= component_x0 or component_y1 <= component_y0) {
                return CodestreamError.InvalidCodestream;
            }
            const plan = packet_plan.rpclTileRegion(
                component_x0,
                component_y0,
                component_x1,
                component_y1,
                reference.resolution_count - 1,
                1,
                layers,
                precincts[0..reference.resolution_count],
            ) catch return CodestreamError.InvalidCodestream;
            try validateComponentPacketTopology(reference, plan, xrsiz != 1 or yrsiz != 1);
            result.components[component] = .{ .plan = plan, .xrsiz = xrsiz, .yrsiz = yrsiz };
            result.packet_count = std.math.add(u64, result.packet_count, plan.packets) catch
                return CodestreamError.InvalidCodestream;
            for (plan.resolutions[0..plan.resolution_count], 0..) |resolution, index| {
                result.resolution_packets[index] = std.math.add(
                    u64,
                    result.resolution_packets[index],
                    resolution.packets,
                ) catch return CodestreamError.InvalidCodestream;
            }
        }
        return result;
    }
};

fn validateComponentPacketTopology(
    reference: packet_plan.Plan,
    component: packet_plan.Plan,
    subsampled: bool,
) !void {
    if (component.resolution_count != reference.resolution_count) return CodestreamError.InvalidCodestream;
    for (reference.resolutions[0..reference.resolution_count], component.resolutions[0..component.resolution_count]) |reference_resolution, component_resolution| {
        if (!subsampled) {
            if (component_resolution.x0 != reference_resolution.x0 or
                component_resolution.y0 != reference_resolution.y0 or
                component_resolution.width != reference_resolution.width or
                component_resolution.height != reference_resolution.height or
                component_resolution.precinct_x0 != reference_resolution.precinct_x0 or
                component_resolution.precinct_y0 != reference_resolution.precinct_y0 or
                component_resolution.precincts_x != reference_resolution.precincts_x or
                component_resolution.precincts_y != reference_resolution.precincts_y)
            {
                return CodestreamError.InvalidCodestream;
            }
            continue;
        }
        if (component_resolution.precincts == 0) return CodestreamError.InvalidCodestream;
    }
}

fn componentPayloadWorker(job: *ComponentPayloadJob) void {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.heap.smp_allocator);
    appendComponentPayload(
        std.heap.smp_allocator,
        &out,
        job.component_index,
        job.bands,
        job.blocks,
        job.catalog,
        job.options,
    ) catch |err| {
        job.result = err;
        return;
    };
    job.bytes = out.toOwnedSlice(std.heap.smp_allocator) catch |err| {
        job.result = err;
        return;
    };
    job.result = {};
}

fn componentCatalogWorker(job: *ComponentCatalogJob) void {
    job.catalog = buildComponentRpclShadowCatalog(
        std.heap.smp_allocator,
        job.plane,
        job.stride,
        job.bands,
        job.blocks,
        job.nominal_bitplanes,
        job.options,
        job.include_bitplane_payload,
        null,
    ) catch |err| {
        job.result = err;
        return;
    };
    job.initialized = true;
    job.result = {};
}

fn componentCatalogBlockWorker(job: *ComponentCatalogBlockJob) void {
    if (job.blocks.len != job.catalog_blocks.len) {
        job.result = CodestreamError.InvalidCodestream;
        return;
    }

    var bitplane_scratch = bitplane.BlockScratch.init(job.allocator);
    defer bitplane_scratch.deinit();
    var ebcot_scratch = ebcot.DirectBlockScratch.init(job.allocator);
    defer ebcot_scratch.deinit();

    while (true) {
        const order_index = job.next_block.fetchAdd(1, .monotonic);
        if (order_index >= job.block_order.len) break;
        const index = job.block_order[order_index];
        const block = job.blocks[index];
        if (block.band_index >= job.bands.len) {
            job.result = CodestreamError.InvalidCodestream;
            return;
        }
        const block_nominal_bitplanes = bandNominalBitplanesForTransform(
            job.nominal_bitplanes,
            job.bands[block.band_index].kind,
            job.bands[block.band_index].level,
            job.options.transform,
            job.options.guard_bits,
            job.options.quantization,
            dwtLevelsFromBands(job.bands),
        ) catch |err| {
            job.result = err;
            return;
        };
        job.catalog_blocks[index] = buildRpclShadowBlock(
            job.allocator,
            &bitplane_scratch,
            &ebcot_scratch,
            job.plane,
            job.stride,
            block.rect,
            job.bands[block.band_index].kind,
            block_nominal_bitplanes,
            job.options,
            job.include_bitplane_payload,
        ) catch |err| {
            job.result = err;
            return;
        };
        const layer_count: usize = @intCast(job.options.layers);
        job.catalog_blocks[index].encoded.layers = job.catalog_blocks[index].layers[0..layer_count];
        job.initialized.append(job.allocator, index) catch |err| {
            job.catalog_blocks[index].deinit(job.allocator);
            job.result = err;
            return;
        };
    }
    job.result = {};
}

fn componentCatalogAllBlockWorker(job: *ComponentCatalogAllBlockJob) void {
    inline for (0..3) |component| {
        if (job.blocks.len != job.catalog_blocks[component].len) {
            job.result = CodestreamError.InvalidCodestream;
            return;
        }
    }

    var bitplane_scratch = bitplane.BlockScratch.init(job.allocator);
    defer bitplane_scratch.deinit();
    var ebcot_scratch = ebcot.DirectBlockScratch.init(job.allocator);
    defer ebcot_scratch.deinit();

    while (true) {
        const order_index = job.next_block.fetchAdd(1, .monotonic);
        if (order_index >= job.block_order.len) break;
        const entry = job.block_order[order_index];
        if (entry.component >= 3) {
            job.result = CodestreamError.InvalidCodestream;
            return;
        }
        const block = job.blocks[entry.block_index];
        if (block.band_index >= job.bands.len) {
            job.result = CodestreamError.InvalidCodestream;
            return;
        }
        const block_nominal_bitplanes = bandNominalBitplanesForTransform(
            job.nominal_bitplanes,
            job.bands[block.band_index].kind,
            job.bands[block.band_index].level,
            job.options.transform,
            job.options.guard_bits,
            job.options.quantization,
            dwtLevelsFromBands(job.bands),
        ) catch |err| {
            job.result = err;
            return;
        };
        const component: usize = entry.component;
        job.catalog_blocks[component][entry.block_index] = buildRpclShadowBlock(
            job.allocator,
            &bitplane_scratch,
            &ebcot_scratch,
            job.planes[component],
            job.stride,
            block.rect,
            job.bands[block.band_index].kind,
            block_nominal_bitplanes,
            job.options,
            job.include_bitplane_payload,
        ) catch |err| {
            job.result = err;
            return;
        };
        const layer_count: usize = @intCast(job.options.layers);
        job.catalog_blocks[component][entry.block_index].encoded.layers = job.catalog_blocks[component][entry.block_index].layers[0..layer_count];
        job.initialized.append(job.allocator, .{ .component = entry.component, .block_index = entry.block_index }) catch |err| {
            job.catalog_blocks[component][entry.block_index].deinit(job.allocator);
            job.result = err;
            return;
        };
    }
    job.result = {};
}

fn componentBlockPayloadWorker(job: *ComponentBlockPayloadJob) void {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.heap.smp_allocator);

    var entropy_scratch = entropy.Scratch.init(std.heap.smp_allocator);
    defer entropy_scratch.deinit();

    appendComponentBlockPayloads(
        std.heap.smp_allocator,
        &out,
        job.blocks,
        job.catalog,
        job.options,
        &entropy_scratch,
    ) catch |err| {
        job.result = err;
        return;
    };
    job.bytes = out.toOwnedSlice(std.heap.smp_allocator) catch |err| {
        job.result = err;
        return;
    };
    job.result = {};
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
    const grid = tile_grid.Grid.fromImageSize(rgb.width, rgb.height, options.tile_width, options.tile_height) catch |err| switch (err) {
        tile_grid.TileGridError.ImageTooLarge => return CodestreamError.ImageTooLarge,
        tile_grid.TileGridError.InvalidImage, tile_grid.TileGridError.InvalidTileGrid => return CodestreamError.InvalidCodestream,
    };
    if (options.ppm and options.ppt) return CodestreamError.UnsupportedPayload;
    if (options.poc_in_tile_header and options.poc_records.len == 0) {
        return CodestreamError.InvalidCodestream;
    }
    if (options.poc_records.len != 0) {
        if (options.ppm or options.ppt or options.emit_temporary_payload_sidecar) {
            return CodestreamError.UnsupportedPayload;
        }
        if (grid.isSingleTile()) {
            if (options.tile_part_divisions != null) return CodestreamError.UnsupportedPayload;
        } else if (options.tile_part_divisions != null and
            options.tile_part_divisions != 'R' and options.tile_part_divisions != 'L' and
            options.tile_part_divisions != 'C' and options.tile_part_divisions != 'P')
        {
            return CodestreamError.UnsupportedPayload;
        }
    }
    if (options.ppm or options.ppt) {
        if (options.progression != .rpcl or options.emit_temporary_payload_sidecar) {
            return CodestreamError.UnsupportedPayload;
        }
        if (grid.isSingleTile()) {
            if (options.tile_part_divisions != null and options.tile_part_divisions != 'R') {
                return CodestreamError.UnsupportedPayload;
            }
        } else if (options.tile_part_divisions != 'R') {
            return CodestreamError.UnsupportedPayload;
        }
    }
    try validatePrecincts(options);
    try validateTilePartDivisions(options.tile_part_divisions);
    try validateCodingPath(options);
    if (options.layers == 0) return CodestreamError.InvalidCodestream;
    if (options.layers > max_quality_layers) return CodestreamError.InvalidCodestream;
    if (options.rate_count > options.layers) return CodestreamError.InvalidCodestream;
    try validateRates(options);
    if (options.threads == 0) return CodestreamError.InvalidCodestream;

    if (!grid.isSingleTile()) {
        return encodeLosslessMultiTileMeasured(allocator, rgb, grid, options, timings, total_start);
    }

    const levels = actualDwtLevels(rgb.width, rgb.height, options.levels);
    const color_start = monotonicNs();
    var planes = switch (options.transform) {
        .reversible_5_3 => if (options.mct == .none)
            try color.forwardNoTransform(allocator, rgb)
        else
            try color.forwardRctThreaded(allocator, rgb, options.threads),
        // The irreversible front end accounts its own ICT (color) and fused
        // 9/7 DWT + quantization (wavelet) phases.
        .irreversible_9_7 => try forwardIrreversibleQuantizedPlanes(allocator, rgb, levels, options, timings),
    };
    defer planes.deinit();
    if (options.transform == .reversible_5_3) {
        if (timings) |t| t.color_transform_ns = elapsedNs(color_start);
    }

    if (options.transform == .reversible_5_3) {
        const wavelet_start = monotonicNs();
        const dwt_levels = try forwardComponents53(allocator, &planes, options);
        if (dwt_levels != levels) return CodestreamError.InvalidCodestream;
        if (timings) |t| t.wavelet_ns = elapsedNs(wavelet_start);
    }

    var encode_options = normalizedEncodePrecinctOptions(options, levels);
    try validatePrecinctBlockSpans(encode_options);
    // Per-resolution tile-parts require resolution-contiguous packet ranges.
    // Multi-layer LRCP interleaves resolutions across layers, and the
    // position-major orders (PCRL/CPRL) interleave them across precinct
    // positions, so those emit one tile-part. Single-layer LRCP and RLCP
    // keep resolution outermost and R-divisions stay valid.
    if ((encode_options.progression == .lrcp and encode_options.layers > 1) or
        encode_options.progression == .pcrl or encode_options.progression == .cprl)
    {
        encode_options.tile_part_divisions = null;
    }
    // Per-layer divisions are wired for the multi-tile path; the single-tile
    // assembler emits one part for them (mirroring the normalization above).
    if (encode_options.tile_part_divisions == 'L') {
        encode_options.tile_part_divisions = null;
    }

    var tile_payload: std.ArrayList(u8) = .empty;
    defer tile_payload.deinit(allocator);
    var rpcl_stream: RpclPacketStream = .{};
    defer rpcl_stream.deinit();
    const payload_start = monotonicNs();
    try appendTemporaryPayload(allocator, &tile_payload, planes, levels, encode_options, &rpcl_stream, timings);
    if (timings) |t| t.payload_ns = elapsedNs(payload_start);
    const packets = try makePacketPlan(rgb.width, rgb.height, levels, encode_options);
    if (encode_options.poc_records.len != 0) {
        const sequence = poc.buildSequence(allocator, packets, 3, encode_options.layers, encode_options.poc_records) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return CodestreamError.InvalidCodestream,
        };
        defer allocator.free(sequence);
        try reorderPacketStreamFromRpclSequence(allocator, &rpcl_stream, packets, encode_options.layers, sequence);
    } else if (encode_options.progression != .rpcl) {
        try reorderPacketStreamFromRpcl(allocator, &rpcl_stream, rgb.width, rgb.height, levels, encode_options);
    }

    const marker_start = monotonicNs();
    const encoded = try assembleSingleTileCodestream(allocator, .{
        .width = rgb.width,
        .height = rgb.height,
        .bit_depth = rgb.bit_depth,
        .components = 3,
        .levels = levels,
        .packet_lengths = rpcl_stream.packet_lengths,
        .packet_header_lengths = rpcl_stream.packet_header_lengths,
        .packet_bytes = rpcl_stream.packet_bytes,
        .sidecar_payload = tile_payload.items,
    }, encode_options);
    if (timings) |t| {
        t.marker_ns = elapsedNs(marker_start);
        t.total_ns = elapsedNs(total_start);
    }
    return encoded;
}

/// Component-count-generic single-tile codestream assembly shared by the RGB
/// and grayscale encoders: main header (SIZ/COD/QCD, optional POC, sidecar
/// comments, TLM, PPM), then the tile-part loop (SOT, optional tile POC,
/// PLT/PPT, SOD, packet bodies), then EOC. Options whose branches a caller's
/// gate rejects (POC/PPM/PPT for grayscale) simply never fire, so both
/// callers keep their previous byte-exact output.
const SingleTileAssemblyInput = struct {
    width: usize,
    height: usize,
    bit_depth: u8,
    component_bit_depths: [max_codestream_components]u8 = [_]u8{0} ** max_codestream_components,
    components: u16,
    levels: u8,
    packet_lengths: []const u32,
    packet_header_lengths: []const u32,
    packet_bytes: []const u8,
    sidecar_payload: []const u8 = &.{},
};

fn componentBitDepthForAssembly(input: SingleTileAssemblyInput, component: usize) u8 {
    const depth = input.component_bit_depths[component];
    return if (depth != 0) depth else input.bit_depth;
}

fn assembleSingleTileCodestream(
    allocator: std.mem.Allocator,
    input: SingleTileAssemblyInput,
    encode_options: LosslessOptions,
) ![]u8 {
    const levels = input.levels;
    const packets = try makePacketPlanForComponents(input.width, input.height, levels, input.components, encode_options);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendMarker(allocator, &out, .soc);
    try appendSizForComponents(allocator, &out, .{
        .width = @intCast(input.width),
        .height = @intCast(input.height),
        .bit_depth = input.bit_depth,
        .component_bit_depths = input.component_bit_depths,
        .components = input.components,
        .tile_width = encode_options.tile_width,
        .tile_height = encode_options.tile_height,
    });
    try appendCod(allocator, &out, levels, encode_options);
    const primary_bit_depth = componentBitDepthForAssembly(input, 0);
    try appendQcd(allocator, &out, levels, primary_bit_depth, encode_options);
    for (1..input.components) |component| {
        const component_depth = componentBitDepthForAssembly(input, component);
        if (component_depth != primary_bit_depth) {
            try appendQccReversible(allocator, &out, levels, @intCast(component), component_depth, encode_options);
        }
    }
    if (encode_options.poc_records.len != 0 and !encode_options.poc_in_tile_header) {
        try appendPoc(allocator, &out, levels, encode_options);
    }
    if (encode_options.emit_temporary_payload_sidecar) {
        try appendTemporaryPayloadComments(allocator, &out, input.sidecar_payload);
    }
    if (input.packet_lengths.len != packets.packets) return CodestreamError.InvalidCodestream;
    if (input.packet_header_lengths.len != packets.packets) return CodestreamError.InvalidCodestream;
    const tile_parts = tilePartCountForOptions(levels, encode_options);
    const uses_packed_headers = encode_options.ppm or encode_options.ppt;
    var psots: [33]u32 = undefined;
    var tile_part_payload_bytes: [33]usize = undefined;
    var tile_part_index: usize = 0;
    while (tile_part_index < tile_parts) : (tile_part_index += 1) {
        const packet_range = tilePartPacketRange(packets, tile_part_index, tile_parts, encode_options);
        const packet_lengths = input.packet_lengths[packet_range.start..][0..packet_range.count];
        const packet_header_lengths = input.packet_header_lengths[packet_range.start..][0..packet_range.count];
        tile_part_payload_bytes[tile_part_index] = if (uses_packed_headers)
            try packedPacketBodyByteCount(encode_options, packet_lengths, packet_header_lengths)
        else
            try rpclPacketPayloadByteCount(encode_options, packet_lengths);
        const plt_bytes = if (encode_options.ppm)
            0
        else if (uses_packed_headers)
            try pltBytesForPackedPacketLengths(encode_options, packet_lengths, packet_header_lengths)
        else
            try pltBytesForRpclPacketLengths(encode_options, packet_lengths);
        const ppt_bytes = if (encode_options.ppt)
            try pptMarkerByteCount(encode_options, packet_header_lengths)
        else
            0;
        const tile_part_bytes = try std.math.add(usize, try std.math.add(usize, plt_bytes, ppt_bytes), tile_part_payload_bytes[tile_part_index]);
        psots[tile_part_index] = std.math.cast(u32, try std.math.add(usize, 14, tile_part_bytes)) orelse
            return CodestreamError.ImageTooLarge;
        if (encode_options.poc_in_tile_header and tile_part_index == 0) {
            psots[tile_part_index] = try std.math.add(u32, psots[tile_part_index], try pocMarkerByteCount(encode_options));
        }
    }

    if (encode_options.tlm) try appendTlm(allocator, &out, psots[0..tile_parts]);
    var ppm_groups: [33][]u8 = [_][]u8{&.{}} ** 33;
    defer for (ppm_groups[0..tile_parts]) |group| if (group.len != 0) allocator.free(group);
    if (encode_options.ppm) {
        tile_part_index = 0;
        while (tile_part_index < tile_parts) : (tile_part_index += 1) {
            const packet_range = tilePartPacketRange(packets, tile_part_index, tile_parts, encode_options);
            const packet_lengths = input.packet_lengths[packet_range.start..][0..packet_range.count];
            const packet_header_lengths = input.packet_header_lengths[packet_range.start..][0..packet_range.count];
            const packet_bytes_start = try rpclPacketByteOffset(input.packet_lengths, packet_range.start);
            const packet_bytes_end = try rpclPacketByteOffset(input.packet_lengths, packet_range.start + packet_range.count);
            ppm_groups[tile_part_index] = try collectPackedPacketHeaders(
                allocator,
                encode_options,
                packet_lengths,
                packet_header_lengths,
                input.packet_bytes[packet_bytes_start..packet_bytes_end],
            );
        }
        var marker_payloads = ppm.buildMarkerPayloads(allocator, ppm_groups[0..tile_parts], 65533) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return CodestreamError.UnsupportedPayload,
        };
        defer marker_payloads.deinit();
        for (marker_payloads.items) |payload| {
            try appendMarker(allocator, &out, .ppm);
            try appendU16Be(allocator, &out, @intCast(payload.len + 2));
            try out.appendSlice(allocator, payload);
        }
    }
    var packet_sequence: u16 = 0;
    var ppt_marker_index: u16 = 0;
    tile_part_index = 0;
    while (tile_part_index < tile_parts) : (tile_part_index += 1) {
        const packet_range = tilePartPacketRange(packets, tile_part_index, tile_parts, encode_options);
        const packet_lengths = input.packet_lengths[packet_range.start..][0..packet_range.count];
        const packet_header_lengths = input.packet_header_lengths[packet_range.start..][0..packet_range.count];
        const packet_bytes_start = try rpclPacketByteOffset(input.packet_lengths, packet_range.start);
        const packet_bytes_end = try rpclPacketByteOffset(input.packet_lengths, packet_range.start + packet_range.count);
        try appendSot(allocator, &out, 0, psots[tile_part_index], @intCast(tile_part_index), @intCast(tile_parts));
        if (encode_options.poc_in_tile_header and tile_part_index == 0) {
            try appendPoc(allocator, &out, levels, encode_options);
        }
        if (uses_packed_headers) {
            if (!encode_options.ppm) {
                try appendPltFromPackedPacketLengths(allocator, &out, encode_options, packet_lengths, packet_header_lengths);
            }
            if (encode_options.ppt) {
                try appendPptPacketHeaders(
                    allocator,
                    &out,
                    encode_options,
                    packet_lengths,
                    packet_header_lengths,
                    input.packet_bytes[packet_bytes_start..packet_bytes_end],
                    &ppt_marker_index,
                );
            }
        } else {
            try appendPltFromRpclPacketLengths(allocator, &out, encode_options, packet_lengths);
        }
        try appendMarker(allocator, &out, .sod);
        if (uses_packed_headers) {
            try appendPackedPacketBodies(
                allocator,
                &out,
                encode_options,
                packet_lengths,
                packet_header_lengths,
                input.packet_bytes[packet_bytes_start..packet_bytes_end],
                &packet_sequence,
            );
        } else {
            try appendRpclPackets(
                allocator,
                &out,
                encode_options,
                packet_lengths,
                packet_header_lengths,
                input.packet_bytes[packet_bytes_start..packet_bytes_end],
                &packet_sequence,
            );
        }
    }
    try appendMarker(allocator, &out, .eoc);

    return out.toOwnedSlice(allocator);
}

pub fn decodeLosslessTemporary(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !image.RgbImage {
    return decodeLosslessTemporaryWithOptions(allocator, bytes, .{});
}

pub fn decodeLosslessTemporaryWithOptions(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
) !image.RgbImage {
    return decodeLosslessTemporaryWithOptionsMeasured(allocator, bytes, options, null);
}

pub fn decodeLosslessTemporaryWithOptionsProfiled(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
    timings: *DecodeTimings,
) !image.RgbImage {
    timings.* = .{};
    return decodeLosslessTemporaryWithOptionsMeasured(allocator, bytes, options, timings);
}

pub fn decodeLosslessGray(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !image.GrayImage {
    return decodeLosslessGrayWithOptions(allocator, bytes, .{});
}

pub fn decodeLosslessGrayWithOptions(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
) !image.GrayImage {
    return decodeLosslessGrayWithOptionsMeasured(allocator, bytes, options, null);
}

pub fn decodeLosslessGrayWithOptionsProfiled(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
    timings: *DecodeTimings,
) !image.GrayImage {
    timings.* = .{};
    return decodeLosslessGrayWithOptionsMeasured(allocator, bytes, options, timings);
}

fn decodeLosslessGrayWithOptionsMeasured(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
    timings: ?*DecodeTimings,
) !image.GrayImage {
    // Cheap pre-check so a multi-component stream fails closed before any
    // block decoding happens; the planar decoder re-reads the metadata.
    const header = try readStrictCodestreamMetadata(allocator, bytes);
    if (header.component_count != 1) return CodestreamError.UnsupportedPayload;
    if (headerHasComponentSubsampling(header)) return CodestreamError.UnsupportedPayload;

    var planar = try decodeLosslessPlanarWithOptionsMeasured(allocator, bytes, options, timings);
    const samples = planar.planes[0];
    planar.allocator.free(planar.planes);
    return .{
        .allocator = allocator,
        .width = planar.width,
        .height = planar.height,
        .bit_depth = planar.bit_depth,
        .samples = samples,
    };
}

/// Planar strict decode for bounded single-tile reversible 5/3 streams. MCT
/// none supports 1..4 independent components; MCT=1 supports four-component
/// RGB+alpha by applying inverse RCT to the first three planes only.
pub fn decodeLosslessPlanar(allocator: std.mem.Allocator, bytes: []const u8) !color.SamplePlanes {
    return decodeLosslessPlanarWithOptions(allocator, bytes, .{});
}

pub fn decodeLosslessPlanarWithOptions(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
) !color.SamplePlanes {
    return decodeLosslessPlanarWithOptionsMeasured(allocator, bytes, options, null);
}

/// Expands component-local decoded planes onto the SIZ reference grid without
/// applying a colour transform. Nearest-neighbour replication is anchored to
/// the absolute reference-grid origin, so cropped images whose XOsiz/YOsiz are
/// not sampling-factor multiples retain the component registration signalled
/// by XRsiz/YRsiz. Use `decodeLosslessPlanar` when native component dimensions
/// are required instead.
pub fn decodeLosslessPlanarUpsampled(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !color.SamplePlanes {
    return decodeLosslessPlanarUpsampledWithOptions(allocator, bytes, .{});
}

pub fn decodeLosslessPlanarUpsampledWithOptions(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
) !color.SamplePlanes {
    return decodeLosslessPlanarUpsampledWithOptionsMeasured(allocator, bytes, options, null);
}

pub fn decodeLosslessPlanarUpsampledWithOptionsProfiled(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
    timings: *DecodeTimings,
) !color.SamplePlanes {
    timings.* = .{};
    return decodeLosslessPlanarUpsampledWithOptionsMeasured(allocator, bytes, options, timings);
}

fn decodeLosslessPlanarUpsampledWithOptionsMeasured(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
    timings: ?*DecodeTimings,
) !color.SamplePlanes {
    const total_start = monotonicNs();
    defer {
        if (timings) |value| value.total_ns = elapsedNs(total_start);
    }
    const header = try readStrictCodestreamMetadata(allocator, bytes);
    var native = try decodeLosslessPlanarWithOptionsMeasured(allocator, bytes, options, timings);
    defer native.deinit();
    return upsamplePlanarNearestToReferenceGrid(allocator, header, native);
}

fn upsamplePlanarNearestToReferenceGrid(
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    native: color.SamplePlanes,
) !color.SamplePlanes {
    if (native.planes.len != header.component_count or
        native.width != header.width or native.height != header.height)
    {
        return CodestreamError.InvalidCodestream;
    }

    const reference_width = std.math.cast(u32, header.width) orelse return CodestreamError.InvalidCodestream;
    const reference_height = std.math.cast(u32, header.height) orelse return CodestreamError.InvalidCodestream;
    const reference_x1 = std.math.add(u32, header.reference_x0, reference_width) catch return CodestreamError.InvalidCodestream;
    const reference_y1 = std.math.add(u32, header.reference_y0, reference_height) catch return CodestreamError.InvalidCodestream;
    var component_depths = [_]u8{0} ** max_codestream_components;
    var output_widths = [_]usize{0} ** max_codestream_components;
    var output_heights = [_]usize{0} ** max_codestream_components;
    @memset(output_widths[0..header.component_count], header.width);
    @memset(output_heights[0..header.component_count], header.height);
    for (0..header.component_count) |component| {
        component_depths[component] = native.componentBitDepth(component) orelse
            return CodestreamError.InvalidCodestream;
    }

    var output = try color.SamplePlanes.initWithComponentLayouts(
        allocator,
        header.width,
        header.height,
        component_depths[0..header.component_count],
        output_widths[0..header.component_count],
        output_heights[0..header.component_count],
    );
    errdefer output.deinit();
    const source_x_by_destination = try allocator.alloc(usize, header.width);
    defer allocator.free(source_x_by_destination);

    for (0..header.component_count) |component| {
        const xrsiz = header.component_xrsiz[component];
        const yrsiz = header.component_yrsiz[component];
        if (xrsiz == 0 or yrsiz == 0) return CodestreamError.InvalidCodestream;
        const component_x0 = ceilDivU32(header.reference_x0, xrsiz);
        const component_y0 = ceilDivU32(header.reference_y0, yrsiz);
        const component_x1 = ceilDivU32(reference_x1, xrsiz);
        const component_y1 = ceilDivU32(reference_y1, yrsiz);
        const source_width = @as(usize, component_x1 - component_x0);
        const source_height = @as(usize, component_y1 - component_y0);
        if (source_width == 0 or source_height == 0) return CodestreamError.InvalidCodestream;
        const dimensions = native.componentDimensions(component) orelse
            return CodestreamError.InvalidCodestream;
        if (dimensions[0] != source_width or dimensions[1] != source_height or
            native.planes[component].len != try std.math.mul(usize, source_width, source_height))
        {
            return CodestreamError.InvalidCodestream;
        }

        const source = native.planes[component];
        const destination = output.planes[component];
        if (xrsiz == 1 and yrsiz == 1) {
            @memcpy(destination, source);
            continue;
        }
        for (source_x_by_destination, 0..) |*source_x, x| {
            const reference_x = @as(u64, header.reference_x0) + @as(u64, @intCast(x));
            const absolute_component_x = reference_x / xrsiz;
            source_x.* = if (absolute_component_x <= component_x0)
                0
            else
                @min(@as(usize, @intCast(absolute_component_x - component_x0)), source_width - 1);
        }
        for (0..header.height) |y| {
            const reference_y = @as(u64, header.reference_y0) + @as(u64, @intCast(y));
            const absolute_component_y = reference_y / yrsiz;
            const source_y = if (absolute_component_y <= component_y0)
                0
            else
                @min(@as(usize, @intCast(absolute_component_y - component_y0)), source_height - 1);
            const source_row = source[source_y * source_width ..][0..source_width];
            const destination_row = destination[y * header.width ..][0..header.width];
            for (destination_row, source_x_by_destination) |*sample, source_x| {
                sample.* = source_row[source_x];
            }
        }
    }
    return output;
}

fn decodeLosslessPlanarWithOptionsMeasured(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
    timings: ?*DecodeTimings,
) !color.SamplePlanes {
    const total_start = monotonicNs();
    defer {
        if (timings) |t| t.total_ns = elapsedNs(total_start);
    }
    if (options.threads == 0) return CodestreamError.InvalidCodestream;

    const metadata_start = monotonicNs();
    const header = try readStrictCodestreamMetadata(allocator, bytes);
    if (timings) |t| t.metadata_ns += elapsedNs(metadata_start);
    const rct_alpha = header.component_count == 4 and header.mct == .rct;
    if (header.component_count < 1 or header.component_count > max_codestream_components or
        (header.mct != .none and !rct_alpha) or
        header.transform != .reversible_5_3 or header.quantization != .none)
    {
        return CodestreamError.UnsupportedPayload;
    }
    if (header.tile_width != 0 or header.tile_height != 0) {
        if (!headerHasComponentSubsampling(header)) return CodestreamError.UnsupportedPayload;
        return decodeStrictMultiTilePlanarMeasured(allocator, bytes, header, options, timings);
    }

    const catalog_start = monotonicNs();
    var catalog = try readStrictPacketBlockCatalogWithHeaderProfiled(allocator, bytes, header, timings);
    defer catalog.deinit();
    if (timings) |t| t.packet_catalog_ns += elapsedNs(catalog_start);
    return decodeStrictPlanarFromBlockCatalogMeasured(allocator, header, catalog, options, timings);
}

fn decodeStrictPlanarFromBlockCatalogMeasured(
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    catalog: StrictPacketBlockCatalog,
    options: DecodeOptions,
    timings: ?*DecodeTimings,
) !color.SamplePlanes {
    const rct_alpha = header.component_count == 4 and header.mct == .rct;
    if (catalog.component_count != header.component_count) return CodestreamError.InvalidCodestream;

    var max_component_dimension: usize = 0;
    for (0..header.component_count) |component| {
        max_component_dimension = @max(max_component_dimension, catalog.component_widths[component]);
        max_component_dimension = @max(max_component_dimension, catalog.component_heights[component]);
    }
    if (max_component_dimension == 0) return CodestreamError.InvalidCodestream;
    var workspace = try wavelet_int.Workspace.init(allocator, max_component_dimension);
    defer workspace.deinit();
    const coefficient_planes = try allocator.alloc([]i32, header.component_count);
    var initialized: usize = 0;
    errdefer {
        for (coefficient_planes[0..initialized]) |plane| allocator.free(plane);
        allocator.free(coefficient_planes);
    }
    while (initialized < header.component_count) {
        const component = initialized;
        const payload_start = monotonicNs();
        coefficient_planes[component] = try reconstructStrictComponentCoefficientsFromBlockCatalog(
            allocator,
            catalog.component_widths[component],
            catalog.component_heights[component],
            catalog,
            component,
            options,
            timings,
        );
        initialized += 1;
        if (timings) |t| t.block_payload_ns += elapsedNs(payload_start);

        const wavelet_start = monotonicNs();
        try wavelet_int.inverse53WithWorkspaceOrigin(
            &workspace,
            coefficient_planes[component],
            catalog.component_widths[component],
            catalog.component_heights[component],
            header.levels,
            catalog.component_x0[component],
            catalog.component_y0[component],
        );
        if (timings) |t| t.wavelet_ns += elapsedNs(wavelet_start);
    }

    var transformed = color.RctPlanes{
        .allocator = allocator,
        .width = header.width,
        .height = header.height,
        .bit_depth = header.bit_depth,
        .planes = coefficient_planes,
    };
    defer transformed.deinit();

    const color_start = monotonicNs();
    defer {
        if (timings) |t| t.color_transform_ns += elapsedNs(color_start);
    }
    if (rct_alpha) return color.inverseRctAlpha(allocator, transformed);

    var output_bit_depths = [_]u8{0} ** max_codestream_components;
    var output_widths = [_]usize{0} ** max_codestream_components;
    var output_heights = [_]usize{0} ** max_codestream_components;
    for (output_bit_depths[0..header.component_count], 0..) |*component_depth, component| {
        component_depth.* = componentBitDepthForHeader(header, component);
        output_widths[component] = catalog.component_widths[component];
        output_heights[component] = catalog.component_heights[component];
    }
    var out = try color.SamplePlanes.initWithComponentLayouts(
        allocator,
        header.width,
        header.height,
        output_bit_depths[0..header.component_count],
        output_widths[0..header.component_count],
        output_heights[0..header.component_count],
    );
    errdefer out.deinit();

    for (transformed.planes, out.planes, 0..) |coefficients, samples, component| {
        const component_depth = output_bit_depths[component];
        const max_sample = (@as(i32, 1) << @as(u5, @intCast(component_depth))) - 1;
        const level_shift = @as(i32, 1) << @as(u5, @intCast(component_depth - 1));
        for (coefficients, samples) |coefficient, *sample| {
            const value = coefficient + level_shift;
            if (value < 0 or value > max_sample) return CodestreamError.InvalidCodestream;
            sample.* = @intCast(value);
        }
    }
    return out;
}

fn decodeLosslessTemporaryWithOptionsMeasured(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
    timings: ?*DecodeTimings,
) !image.RgbImage {
    const total_start = monotonicNs();
    defer {
        if (timings) |t| t.total_ns = elapsedNs(total_start);
    }

    if (options.threads == 0) return CodestreamError.InvalidCodestream;
    if (try temporaryPayloadFromComments(allocator, bytes)) |payload| {
        defer allocator.free(payload);
        const sidecar_start = monotonicNs();
        if (try decodeStrictRpclImageWithTemporaryMetadata(allocator, bytes, payload, options)) |strict| {
            if (timings) |t| t.sidecar_or_legacy_ns += elapsedNs(sidecar_start);
            return strict;
        }
        _ = try validateStrictRpclPacketsMatchTemporary(allocator, bytes, payload, options);
        if (timings) |t| t.sidecar_or_legacy_ns += elapsedNs(sidecar_start);
        return decodeTemporaryPayloadWithOptionsMeasured(allocator, payload, options, timings);
    }

    const metadata_start = monotonicNs();
    const header = try readStrictCodestreamMetadata(allocator, bytes);
    if (timings) |t| t.metadata_ns += elapsedNs(metadata_start);
    if (header.component_count != 3) return CodestreamError.UnsupportedPayload;
    if (headerHasMixedComponentPrecision(header)) return CodestreamError.UnsupportedPayload;
    if (headerHasComponentSubsampling(header)) return CodestreamError.UnsupportedPayload;

    // Multi-tile headers carry the real SIZ tile dimensions (single-tile
    // metadata leaves them zero); route them through the per-tile decode.
    if (header.tile_width != 0 or header.tile_height != 0) {
        return decodeStrictMultiTileImageMeasured(allocator, bytes, header, options, timings);
    }

    const catalog_start = monotonicNs();
    var strict_catalog = try readStrictPacketBlockCatalogWithHeaderProfiled(allocator, bytes, header, timings);
    defer strict_catalog.deinit();
    if (timings) |t| t.packet_catalog_ns += elapsedNs(catalog_start);

    return decodeStrictRpclImageFromBlockCatalogMeasured(allocator, header, strict_catalog, options, timings);
}

fn decodeTemporaryPayloadWithOptions(
    allocator: std.mem.Allocator,
    payload: []const u8,
    options: DecodeOptions,
) !image.RgbImage {
    return decodeTemporaryPayloadWithOptionsMeasured(allocator, payload, options, null);
}

fn decodeTemporaryPayloadWithOptionsMeasured(
    allocator: std.mem.Allocator,
    payload: []const u8,
    options: DecodeOptions,
    timings: ?*DecodeTimings,
) !image.RgbImage {
    const legacy_start = monotonicNs();
    var cursor = Cursor.initWithAllocator(allocator, payload);

    const header = try readTemporaryHeader(&cursor);
    const width = header.width;
    const height = header.height;
    const bit_depth = header.bit_depth;
    const levels = header.levels;

    if (width == 0 or height == 0) return CodestreamError.InvalidCodestream;
    if (options.threads == 0) return CodestreamError.InvalidCodestream;

    var planes = try color.RctPlanes.init(allocator, width, height, bit_depth, 3);
    defer planes.deinit();
    const y = planes.planes[0];
    const cb = planes.planes[1];
    const cr = planes.planes[2];
    @memset(y, 0);
    @memset(cb, 0);
    @memset(cr, 0);

    try readComponentPayloads(&cursor, y, cb, cr, width, header.version, header.layers, options);
    _ = try readRpclShadowStreamInfo(&cursor, header.version, header.packet_count);
    if (!cursor.finished()) return CodestreamError.InvalidCodestream;
    if (timings) |t| t.sidecar_or_legacy_ns += elapsedNs(legacy_start);

    const wavelet_start = monotonicNs();
    try inverseComponents53(allocator, .{ .slices = .{ y, cb, cr } }, width, height, levels, 0, 0, options);
    if (timings) |t| t.wavelet_ns += elapsedNs(wavelet_start);

    const color_start = monotonicNs();
    defer {
        if (timings) |t| t.color_transform_ns += elapsedNs(color_start);
    }
    return if (header.mct == .none)
        color.inverseNoTransform(allocator, planes)
    else
        color.inverseRct(allocator, planes);
}

pub fn analyzeLosslessTemporary(bytes: []const u8) !TemporaryStats {
    return analyzeLosslessTemporaryWithOptions(bytes, .{});
}

pub fn analyzeLosslessTemporaryWithOptions(bytes: []const u8, options: DecodeOptions) !TemporaryStats {
    const allocator = std.heap.page_allocator;
    if (try temporaryPayloadFromComments(allocator, bytes)) |payload| {
        defer allocator.free(payload);
        const sod = try validateStrictRpclPacketsMatchTemporary(allocator, bytes, payload, options);
        return analyzeTemporaryPayloadBytes(allocator, bytes, payload, sod);
    }
    return analyzeStrictPacketStats(allocator, bytes);
}

fn analyzeTemporaryPayloadBytes(
    allocator: std.mem.Allocator,
    codestream_bytes: []const u8,
    payload: []const u8,
    sod: PacketStreamInfo,
) !TemporaryStats {
    var cursor = Cursor.initWithAllocator(allocator, payload);

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
        .layers = header.layers,
        .block_width = header.block_width,
        .block_height = header.block_height,
        .tile_part_divisions = header.tile_part_divisions,
        .tile_part_plan_count = header.tile_part_plan_count,
        .tile_part_plan = header.tile_part_plan,
        .packet_plan_count = header.packet_plan_count,
        .packet_plan = header.packet_plan,
        .packet_count = header.packet_count,
        .sod_packets = sod.packets,
        .sod_packet_bytes = sod.bytes,
        .t2_audited_packets = 0,
        .t2_present_packets = 0,
        .t2_absent_packets = 0,
        .t2_geometry_empty_packets = 0,
        .t2_header_decoded_packets = 0,
        .t2_header_bytes = 0,
        .t2_payload_bytes = 0,
        .t2_included_blocks = 0,
        .t2_assembled_blocks = 0,
        .t2_assembled_bytes = 0,
        .t2_assembled_passes = 0,
        .t2_t1_ready_blocks = 0,
        .rpcl_shadow_packets = 0,
        .rpcl_shadow_bytes = 0,
        .payload_bytes = payload.len,
        .codestream_bytes = codestream_bytes.len,
        .components = [_]ComponentStats{.{}} ** 3,
    };

    try readComponentStats(&cursor, &stats.components[0], 0, header.version, header.layers);
    try readComponentStats(&cursor, &stats.components[1], 1, header.version, header.layers);
    try readComponentStats(&cursor, &stats.components[2], 2, header.version, header.layers);
    const rpcl_shadow = try readRpclShadowStreamInfo(&cursor, header.version, header.packet_count);
    stats.rpcl_shadow_packets = rpcl_shadow.packets;
    stats.rpcl_shadow_bytes = rpcl_shadow.bytes;
    if (!cursor.finished()) return CodestreamError.InvalidCodestream;

    return stats;
}

fn analyzeStrictPacketStats(allocator: std.mem.Allocator, bytes: []const u8) !TemporaryStats {
    const header = try readStrictCodestreamMetadata(allocator, bytes);
    if (header.tile_width != 0 or header.tile_height != 0) {
        return analyzeStrictMultiTilePacketStats(allocator, bytes, header);
    }
    var catalog = try readStrictPacketCatalog(allocator, bytes);
    defer catalog.deinit();
    if (catalog.entries.len != header.packet_count) return CodestreamError.InvalidCodestream;
    const audit = try auditStrictPacketCatalogHeaders(allocator, header, catalog);

    return .{
        .width = header.width,
        .height = header.height,
        .bit_depth = header.bit_depth,
        .component_count = header.component_count,
        .levels = header.levels,
        .layers = header.layers,
        .block_width = header.block_width,
        .block_height = header.block_height,
        .tile_part_divisions = header.tile_part_divisions,
        .tile_part_plan_count = header.tile_part_plan_count,
        .tile_part_plan = header.tile_part_plan,
        .packet_plan_count = header.packet_plan_count,
        .packet_plan = header.packet_plan,
        .packet_count = header.packet_count,
        .sod_packets = @intCast(catalog.entries.len),
        .sod_packet_bytes = @intCast(catalog.packet_bytes.len),
        .t2_audited_packets = audit.packets,
        .t2_present_packets = audit.present_packets,
        .t2_absent_packets = audit.absent_packets,
        .t2_geometry_empty_packets = audit.geometry_empty_packets,
        .t2_header_decoded_packets = audit.header_decoded_packets,
        .t2_header_bytes = audit.header_bytes,
        .t2_payload_bytes = audit.payload_bytes,
        .t2_included_blocks = audit.included_blocks,
        .t2_assembled_blocks = audit.assembled_blocks,
        .t2_assembled_bytes = audit.assembled_bytes,
        .t2_assembled_passes = audit.assembled_passes,
        .t2_t1_ready_blocks = audit.t1_ready_blocks,
        .rpcl_shadow_packets = 0,
        .rpcl_shadow_bytes = 0,
        .payload_bytes = 0,
        .codestream_bytes = bytes.len,
        .components = [_]ComponentStats{.{}} ** 3,
    };
}

fn analyzeStrictMultiTilePacketStats(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: TemporaryHeader,
) !TemporaryStats {
    var sod_packets: u64 = 0;
    var sod_packet_bytes: u64 = 0;
    const audit = try auditStrictMultiTilePacketHeaders(allocator, bytes, header, &sod_packets, &sod_packet_bytes);
    if (audit.packets != header.packet_count) return CodestreamError.InvalidCodestream;

    return .{
        .width = header.width,
        .height = header.height,
        .bit_depth = header.bit_depth,
        .component_count = header.component_count,
        .levels = header.levels,
        .layers = header.layers,
        .block_width = header.block_width,
        .block_height = header.block_height,
        .tile_part_divisions = header.tile_part_divisions,
        .tile_part_plan_count = header.tile_part_plan_count,
        .tile_part_plan = header.tile_part_plan,
        .packet_plan_count = header.packet_plan_count,
        .packet_plan = header.packet_plan,
        .packet_count = header.packet_count,
        .sod_packets = sod_packets,
        .sod_packet_bytes = sod_packet_bytes,
        .t2_audited_packets = audit.packets,
        .t2_present_packets = audit.present_packets,
        .t2_absent_packets = audit.absent_packets,
        .t2_geometry_empty_packets = audit.geometry_empty_packets,
        .t2_header_decoded_packets = audit.header_decoded_packets,
        .t2_header_bytes = audit.header_bytes,
        .t2_payload_bytes = audit.payload_bytes,
        .t2_included_blocks = audit.included_blocks,
        .t2_assembled_blocks = audit.assembled_blocks,
        .t2_assembled_bytes = audit.assembled_bytes,
        .t2_assembled_passes = audit.assembled_passes,
        .t2_t1_ready_blocks = audit.t1_ready_blocks,
        .rpcl_shadow_packets = 0,
        .rpcl_shadow_bytes = 0,
        .payload_bytes = 0,
        .codestream_bytes = bytes.len,
        .components = [_]ComponentStats{.{}} ** 3,
    };
}

pub fn readStrictPacketCatalog(allocator: std.mem.Allocator, bytes: []const u8) !StrictPacketCatalog {
    const header = try readStrictCodestreamMetadata(allocator, bytes);
    return readStrictPacketCatalogWithHeader(allocator, bytes, header);
}

fn readStrictPacketCatalogWithHeader(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: TemporaryHeader,
) !StrictPacketCatalog {
    const plan = temporaryPacketPlan(header);
    return readStrictSodPacketCatalog(allocator, bytes, header, plan, header.layers, header.progression);
}

pub fn auditStrictPacketHeaders(allocator: std.mem.Allocator, bytes: []const u8) !StrictPacketHeaderAudit {
    const header = try readStrictCodestreamMetadata(allocator, bytes);
    if (header.tile_width != 0 or header.tile_height != 0) {
        return auditStrictMultiTilePacketHeaders(allocator, bytes, header, null, null);
    }
    var catalog = try readStrictPacketCatalogWithHeader(allocator, bytes, header);
    defer catalog.deinit();
    return auditStrictPacketCatalogHeaders(allocator, header, catalog);
}

pub fn readStrictPacketBlockCatalog(allocator: std.mem.Allocator, bytes: []const u8) !StrictPacketBlockCatalog {
    const header = try readStrictCodestreamMetadata(allocator, bytes);
    return readStrictPacketBlockCatalogWithHeader(allocator, bytes, header);
}

fn readStrictPacketBlockCatalogWithHeader(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: TemporaryHeader,
) !StrictPacketBlockCatalog {
    return readStrictPacketBlockCatalogWithHeaderProfiled(allocator, bytes, header, null);
}

fn readStrictPacketBlockCatalogWithHeaderProfiled(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: TemporaryHeader,
    timings: ?*DecodeTimings,
) !StrictPacketBlockCatalog {
    const scan_start = monotonicNs();
    var catalog = try readStrictPacketCatalogWithHeader(allocator, bytes, header);
    defer catalog.deinit();
    if (timings) |t| t.packet_catalog_scan_ns += elapsedNs(scan_start);

    const header_start = monotonicNs();
    var audit = StrictPacketHeaderAudit{};
    var assemblies = try assembleStrictPacketCatalogHeaders(allocator, header, catalog, &audit);
    defer assemblies.deinit();
    if (timings) |t| t.packet_catalog_header_ns += elapsedNs(header_start);

    const finalize_start = monotonicNs();
    var build = try strictPacketBlockCatalogFromAssembliesChecked(
        allocator,
        assemblies.assemblies[0..assemblies.initialized],
    );
    errdefer build.catalog.deinit();
    if (build.stats.bytes != audit.payload_bytes) return CodestreamError.InvalidCodestream;
    if (timings) |t| t.packet_catalog_finalize_ns += elapsedNs(finalize_start);
    return build.catalog;
}

fn readStrictCodestreamMetadata(allocator: std.mem.Allocator, bytes: []const u8) !TemporaryHeader {
    if (bytes.len < 4 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    var width: usize = 0;
    var height: usize = 0;
    var bit_depth: u8 = 0;
    var component_bit_depths = [_]u8{0} ** max_codestream_components;
    var component_xrsiz = [_]u8{1} ** max_codestream_components;
    var component_yrsiz = [_]u8{1} ** max_codestream_components;
    var mixed_component_precision = false;
    var subsampled_components = false;
    var component_count: u16 = 0;
    var levels: u8 = 0;
    var layers: u16 = 0;
    var block_width: u16 = 0;
    var block_height: u16 = 0;
    var parsed_code_block_style = ebcot.CodeBlockStyle{};
    var parsed_transform: WaveletTransform = .reversible_5_3;
    var parsed_mct: MultipleComponentTransform = .rct;
    var parsed_progression: ProgressionOrder = .rpcl;
    var parsed_quantization: QuantizationStyle = .none;
    var parsed_guard_bits: u8 = strict_guard_bits;
    var parsed_qcd_exponents: [max_qcd_bands]u8 = [_]u8{0} ** max_qcd_bands;
    var parsed_qcd_exponent_count: u8 = 0;
    var parsed_qcd_steps: [max_qcd_bands]BandStepSize = [_]BandStepSize{.{ .exponent = 0, .mantissa = 0 }} ** max_qcd_bands;
    var parsed_qcd_step_count: u8 = 0;
    var precincts = defaultPrecincts();
    var precinct_count: u8 = 0;
    var parsed_grid: ?tile_grid.Grid = null;
    var saw_siz = false;
    var saw_cod = false;
    var saw_qcd = false;
    // Captured COD/QCD payload slices (into `bytes`) so a redundant COC/QCC
    // can be accepted only when it byte-replicates the main marker.
    var cod_scod: u8 = 0;
    var cod_coding: []const u8 = &.{};
    var qcd_payload: []const u8 = &.{};
    var coc_component_seen = [_]bool{false} ** max_codestream_components;
    var coc_payload_first: []const u8 = &.{};
    var qcc_component_seen = [_]bool{false} ** max_codestream_components;
    var qcc_payload_first: []const u8 = &.{};
    var qcc_override_info: StrictQcdInfo = undefined;
    var component_qcd = [_]StrictQcdInfo{.{
        .bands = 0,
        .quantization = .none,
    }} ** max_codestream_components;
    var qcd_band_count: usize = 0;
    var tlm_entries: std.ArrayList(TlmEntry) = .empty;
    defer tlm_entries.deinit(allocator);
    var saw_tlm = false;
    var next_tlm_index: usize = 0;
    var ppm_collector = ppm.SegmentCollector.init(allocator);
    defer ppm_collector.deinit();
    var poc_records: std.ArrayList(poc.Record) = .empty;
    defer poc_records.deinit(allocator);

    var cursor: usize = 2;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(Marker.sot)) break;
        if (marker == @intFromEnum(Marker.eoc) or marker == @intFromEnum(Marker.sod)) {
            return CodestreamError.InvalidCodestream;
        }
        cursor += 2;
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) {
            return CodestreamError.TruncatedData;
        }
        const segment = bytes[cursor + 2 .. cursor + segment_length];
        if (!saw_siz and marker != @intFromEnum(Marker.siz)) return CodestreamError.InvalidCodestream;
        if (marker == @intFromEnum(Marker.siz)) {
            if (saw_siz) return CodestreamError.InvalidCodestream;
            if (segment.len < 36) return CodestreamError.InvalidCodestream;
            const xsiz = readU32Be(segment, 2);
            const ysiz = readU32Be(segment, 6);
            const xosiz = readU32Be(segment, 10);
            const yosiz = readU32Be(segment, 14);
            const xtsiz = readU32Be(segment, 18);
            const ytsiz = readU32Be(segment, 22);
            const xtosiz = readU32Be(segment, 26);
            const ytosiz = readU32Be(segment, 30);
            if (xsiz <= xosiz or ysiz <= yosiz) return CodestreamError.InvalidCodestream;
            component_count = readU16Be(segment, 34);
            if (component_count < 1 or component_count > max_codestream_components) return CodestreamError.UnsupportedPayload;
            if (segment.len != 36 + @as(usize, component_count) * 3) return CodestreamError.InvalidCodestream;
            width = xsiz - xosiz;
            height = ysiz - yosiz;
            if (xtsiz == 0 or ytsiz == 0) return CodestreamError.InvalidCodestream;
            if (xtosiz != xosiz or ytosiz != yosiz) return CodestreamError.UnsupportedPayload;
            parsed_grid = tile_grid.Grid.init(.{
                .xsiz = xsiz,
                .ysiz = ysiz,
                .xosiz = xosiz,
                .yosiz = yosiz,
                .xtsiz = xtsiz,
                .ytsiz = ytsiz,
                .xtosiz = xtosiz,
                .ytosiz = ytosiz,
            }) catch |err| switch (err) {
                tile_grid.TileGridError.ImageTooLarge => return CodestreamError.ImageTooLarge,
                tile_grid.TileGridError.InvalidImage, tile_grid.TileGridError.InvalidTileGrid => return CodestreamError.InvalidCodestream,
            };
            bit_depth = (segment[36] & 0x7f) + 1;
            if (bit_depth != 8 and bit_depth != 16) return CodestreamError.UnsupportedPayload;
            var component_index: usize = 0;
            while (component_index < component_count) : (component_index += 1) {
                const component_offset = 36 + component_index * 3;
                const ssiz = segment[component_offset];
                if ((ssiz & 0x80) != 0) return CodestreamError.UnsupportedPayload;
                const component_bit_depth = (ssiz & 0x7f) + 1;
                if (component_bit_depth != 8 and component_bit_depth != 16) {
                    return CodestreamError.UnsupportedPayload;
                }
                component_bit_depths[component_index] = component_bit_depth;
                mixed_component_precision = mixed_component_precision or component_bit_depth != bit_depth;
                const xrsiz = segment[component_offset + 1];
                const yrsiz = segment[component_offset + 2];
                if (xrsiz == 0 or yrsiz == 0) return CodestreamError.InvalidCodestream;
                component_xrsiz[component_index] = xrsiz;
                component_yrsiz[component_index] = yrsiz;
                subsampled_components = subsampled_components or xrsiz != 1 or yrsiz != 1;
            }
            saw_siz = true;
        } else if (marker == @intFromEnum(Marker.cod)) {
            if (!saw_siz or saw_cod) return CodestreamError.InvalidCodestream;
            if (segment.len < 10) return CodestreamError.InvalidCodestream;
            const scod = segment[0];
            if ((scod & ~@as(u8, 0x07)) != 0) return CodestreamError.InvalidCodestream;
            parsed_progression = switch (segment[1]) {
                @intFromEnum(ProgressionOrder.rpcl) => .rpcl,
                @intFromEnum(ProgressionOrder.lrcp) => .lrcp,
                @intFromEnum(ProgressionOrder.rlcp) => .rlcp,
                @intFromEnum(ProgressionOrder.pcrl) => .pcrl,
                @intFromEnum(ProgressionOrder.cprl) => .cprl,
                else => return CodestreamError.UnsupportedPayload,
            };
            layers = readU16Be(segment, 2);
            if (layers == 0 or layers > max_quality_layers) return CodestreamError.InvalidCodestream;
            parsed_mct = switch (segment[4]) {
                @intFromEnum(MultipleComponentTransform.rct) => .rct,
                @intFromEnum(MultipleComponentTransform.none) => .none,
                else => return CodestreamError.UnsupportedPayload,
            };
            levels = segment[5];
            if (levels > 32) return CodestreamError.TooManyLevels;
            block_width = try codeBlockSizeFromCodExponent(segment[6]);
            block_height = try codeBlockSizeFromCodExponent(segment[7]);
            try validateBlockSize(block_width, block_height);
            parsed_code_block_style = try parseCodeBlockStyleByte(segment[8]);
            parsed_transform = switch (segment[9]) {
                @intFromEnum(WaveletTransform.irreversible_9_7) => .irreversible_9_7,
                @intFromEnum(WaveletTransform.reversible_5_3) => .reversible_5_3,
                else => return CodestreamError.InvalidCodestream,
            };
            const wire_precinct_count: usize = if ((scod & 0x01) != 0) @as(usize, levels) + 1 else 0;
            if (wire_precinct_count > precincts.len or segment.len < 10 + wire_precinct_count) {
                return CodestreamError.InvalidCodestream;
            }
            if (segment.len != 10 + wire_precinct_count) return CodestreamError.InvalidCodestream;
            if (@as(usize, levels) + 1 > precincts.len) return CodestreamError.InvalidCodestream;
            if (wire_precinct_count > 0) {
                for (segment[10..][0..wire_precinct_count], 0..) |byte, index| {
                    const precinct = PrecinctSize{
                        .width = @as(u16, 1) << @as(u4, @intCast(byte & 0x0f)),
                        .height = @as(u16, 1) << @as(u4, @intCast(byte >> 4)),
                    };
                    if (!isValidPrecinctEdge(precinct.width) or !isValidPrecinctEdge(precinct.height)) {
                        return CodestreamError.InvalidCodestream;
                    }
                    precincts[index] = .{
                        .width = precinct.width,
                        .height = precinct.height,
                    };
                }
            } else {
                // Scod bit 0 unset means no precinct partition (ISO B.6):
                // every resolution uses the maximal 2^15 precinct, i.e. one
                // precinct per resolution. OpenJPEG and Grok emit this by
                // default, so map it explicitly instead of failing closed.
                for (precincts[0 .. @as(usize, levels) + 1]) |*precinct| {
                    precinct.* = .{ .width = 32768, .height = 32768 };
                }
            }
            precinct_count = levels + 1;
            cod_scod = scod;
            cod_coding = segment[5..];
            saw_cod = true;
        } else if (marker == @intFromEnum(Marker.qcd)) {
            if (!saw_cod or saw_qcd) return CodestreamError.InvalidCodestream;
            const qcd_info = try validateStrictQcdSegment(segment, bit_depth, levels, parsed_transform);
            qcd_band_count = qcd_info.bands;
            parsed_quantization = qcd_info.quantization;
            parsed_guard_bits = qcd_info.guard_bits;
            parsed_qcd_exponents = qcd_info.exponents;
            parsed_qcd_exponent_count = qcd_info.exponent_count;
            parsed_qcd_steps = qcd_info.steps;
            parsed_qcd_step_count = qcd_info.step_count;
            for (component_qcd[0..component_count]) |*component_info| component_info.* = qcd_info;
            qcd_payload = segment;
            saw_qcd = true;
        } else if (marker == @intFromEnum(Marker.coc)) {
            // ISO 15444-1 A.6.2: component-specific coding style. z2000 has no
            // per-component coding path, so a COC is accepted only when it
            // byte-replicates the main COD, or as a *uniform override*: every
            // RGB component carries an identical COC whose SPcoc differs from
            // the COD only in the code-block style byte (Kakadu signals
            // per-component Cmodes this way even when the request is uniform).
            // Genuinely per-component divergence fails closed. Layout:
            // Ccoc(1) Scoc(1) SPcoc(NL,xcb,ycb,cblk,transform,precincts).
            if (!saw_cod) return CodestreamError.InvalidCodestream;
            if (segment.len < 3) return CodestreamError.InvalidCodestream;
            if (segment[0] >= component_count) return CodestreamError.UnsupportedPayload;
            if ((segment[1] & ~@as(u8, 0x01)) != 0) return CodestreamError.InvalidCodestream;
            if ((segment[1] & 0x01) != (cod_scod & 0x01)) return CodestreamError.UnsupportedPayload;
            try validateStrictCocCodingPayload(segment[2..], segment[1]);
            const coc_component = segment[0];
            if (coc_component_seen[coc_component]) return CodestreamError.InvalidCodestream;
            coc_component_seen[coc_component] = true;
            if (coc_payload_first.len == 0) {
                coc_payload_first = segment[1..];
            } else if (!std.mem.eql(u8, segment[1..], coc_payload_first)) {
                // Components disagree with each other: genuine per-component
                // coding, which z2000 cannot decode.
                return CodestreamError.UnsupportedPayload;
            }
        } else if (marker == @intFromEnum(Marker.qcc)) {
            // ISO 15444-1 A.6.5: component-specific quantization. Same policy
            // as COC: byte-replication of the main QCD, or a uniform override
            // where all components carry identical QCC data — Kakadu writes
            // per-component Qguard this way, leaving the QCD at its default
            // (the signalled-Mb decode path consumes whichever values win).
            if (!saw_qcd) return CodestreamError.InvalidCodestream;
            if (segment.len < 1) return CodestreamError.InvalidCodestream;
            if (segment[0] >= component_count) return CodestreamError.UnsupportedPayload;
            const qcc_component = segment[0];
            const qcc_info = try validateStrictQcdSegment(
                segment[1..],
                component_bit_depths[qcc_component],
                levels,
                parsed_transform,
            );
            if (qcc_component_seen[qcc_component]) return CodestreamError.InvalidCodestream;
            qcc_component_seen[qcc_component] = true;
            component_qcd[qcc_component] = qcc_info;
            if (mixed_component_precision) {
                // Mixed reversible components legitimately carry different
                // QCC exponents. Keep each override instead of collapsing it
                // into the historical uniform-QCC policy below.
            } else if (qcc_payload_first.len == 0) {
                qcc_payload_first = segment[1..];
                qcc_override_info = qcc_info;
            } else if (!std.mem.eql(u8, segment[1..], qcc_payload_first)) {
                return CodestreamError.UnsupportedPayload;
            }
        } else if (marker == @intFromEnum(Marker.tlm)) {
            if (!saw_cod or !saw_qcd) return CodestreamError.InvalidCodestream;
            try appendStrictTlmEntries(allocator, &tlm_entries, segment, next_tlm_index);
            saw_tlm = true;
            next_tlm_index += 1;
        } else if (marker == @intFromEnum(Marker.ppm)) {
            if (!saw_qcd) return CodestreamError.InvalidCodestream;
            ppm_collector.append(segment) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return CodestreamError.InvalidCodestream,
            };
        } else if (marker == @intFromEnum(Marker.poc)) {
            if (!saw_qcd) return CodestreamError.InvalidCodestream;
            poc.appendSegment(allocator, &poc_records, segment, component_count, levels + 1, layers) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return CodestreamError.InvalidCodestream,
            };
        } else if (marker == @intFromEnum(Marker.com)) {
            // COM is ignored by the restricted decoder profile.
        } else if (isUnsupportedMainHeaderMarker(marker)) {
            return CodestreamError.UnsupportedPayload;
        } else {
            return CodestreamError.InvalidCodestream;
        }
        cursor += segment_length;
    }
    if (!saw_siz or !saw_cod or !saw_qcd or width == 0 or height == 0 or layers == 0) {
        return CodestreamError.InvalidCodestream;
    }
    if (parsed_mct != .none and component_count != 3 and
        !(component_count == 4 and parsed_transform == .reversible_5_3))
    {
        return CodestreamError.UnsupportedPayload;
    }
    const parsed_grid_value = parsed_grid orelse return CodestreamError.InvalidCodestream;
    if (mixed_component_precision and
        (parsed_mct != .none or parsed_transform != .reversible_5_3 or
            parsed_quantization != .none or !parsed_grid_value.isSingleTile()))
    {
        return CodestreamError.UnsupportedPayload;
    }
    if (subsampled_components and
        (parsed_mct != .none or parsed_transform != .reversible_5_3 or
            parsed_quantization != .none or
            parsed_progression != .rpcl or
            ppm_collector.expected_index != 0))
    {
        return CodestreamError.UnsupportedPayload;
    }
    if (qcd_band_count != 1 + 3 * @as(usize, levels)) return CodestreamError.InvalidCodestream;

    if (coc_payload_first.len != 0) {
        // A COC that byte-replicates the COD is redundant and fine on its own.
        // A *uniform override* — SPcoc differing from the COD only in the
        // code-block style byte — requires every component to carry the
        // identical COC, and the style then becomes effective for all of them
        // (Kakadu's uniform per-component Cmodes signalling).
        const spcoc = coc_payload_first[1..];
        if (!std.mem.eql(u8, spcoc, cod_coding)) {
            for (coc_component_seen[0..component_count]) |seen| {
                if (!seen) return CodestreamError.UnsupportedPayload;
            }
            if (spcoc.len != cod_coding.len or spcoc.len < 5) return CodestreamError.UnsupportedPayload;
            for (spcoc, cod_coding, 0..) |coc_byte, cod_byte, index| {
                if (index == 3) continue;
                if (coc_byte != cod_byte) return CodestreamError.UnsupportedPayload;
            }
            parsed_code_block_style = try parseCodeBlockStyleByte(spcoc[3]);
        }
    }
    if (!mixed_component_precision and qcc_payload_first.len != 0) {
        // A QCC that byte-replicates the QCD is redundant and fine on its own.
        // A uniform divergence requires all components and swaps in the QCC
        // quantization wholesale — the signalled-Mb/step decode path already
        // consumes arbitrary legal values (Kakadu's per-component Qguard
        // signalling leaves the QCD at its default).
        if (!std.mem.eql(u8, qcc_payload_first, qcd_payload)) {
            for (qcc_component_seen[0..component_count]) |seen| {
                if (!seen) return CodestreamError.UnsupportedPayload;
            }
            qcd_band_count = qcc_override_info.bands;
            parsed_quantization = qcc_override_info.quantization;
            parsed_guard_bits = qcc_override_info.guard_bits;
            parsed_qcd_exponents = qcc_override_info.exponents;
            parsed_qcd_exponent_count = qcc_override_info.exponent_count;
            parsed_qcd_steps = qcc_override_info.steps;
            parsed_qcd_step_count = qcc_override_info.step_count;
            if (qcd_band_count != 1 + 3 * @as(usize, levels)) return CodestreamError.InvalidCodestream;
        }
    }
    if (mixed_component_precision) {
        for (component_qcd[0..component_count]) |component_info| {
            if (component_info.bands != qcd_band_count or component_info.quantization != .none or
                component_info.exponent_count != qcd_band_count)
            {
                return CodestreamError.InvalidCodestream;
            }
        }
    }

    const options = LosslessOptions{
        .levels = levels,
        .layers = layers,
        .block_width = block_width,
        .block_height = block_height,
        .precincts = precincts,
        .precinct_count = if (precinct_count == 0) 1 else precinct_count,
    };
    // A COD whose blocks cross precinct boundaries would need the B.7 size
    // clamping z2000 does not implement; misreading it silently corrupts the
    // block layout, so fail closed here for single- and multi-tile alike.
    try validatePrecinctBlockSpans(options);
    const grid = parsed_grid orelse return CodestreamError.InvalidCodestream;
    var ppm_headers: ?ppm.PackedHeaders = if (ppm_collector.expected_index != 0)
        ppm_collector.finish() catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return CodestreamError.InvalidCodestream,
        }
    else
        null;
    defer if (ppm_headers) |*headers| headers.deinit();
    if (!grid.isSingleTile()) {
        if (component_count != 3) return CodestreamError.UnsupportedPayload;
        // Multi-tile: validate one-part tiles or PLT-backed RPCL resolution
        // divisions, per-tile packet plans, TLM cross-check, and the same
        // geometry envelope the encoder enforces. The per-tile
        // spans this produces feed the Stage C decode. The multi-tile envelope
        // currently covers RPCL plus the single-layer LRCP/RLCP permutations.
        try validateMultiTileProgression(parsed_progression, layers);
        try validateMultiTileDecodeGeometry(grid, levels, options);
        const tile_count = std.math.cast(usize, grid.tileCount()) orelse return CodestreamError.UnsupportedPayload;
        const tile_poc_records = try allocator.alloc(std.ArrayList(poc.Record), tile_count);
        defer allocator.free(tile_poc_records);
        for (tile_poc_records) |*records| records.* = .empty;
        defer for (tile_poc_records) |*records| records.deinit(allocator);
        var spans = try readStrictMultiTileTilePartSpans(
            allocator,
            bytes,
            cursor,
            grid,
            levels,
            options,
            component_count,
            component_xrsiz,
            component_yrsiz,
            if (saw_tlm) tlm_entries.items else null,
            if (ppm_headers) |headers| headers else null,
            tile_poc_records,
        );
        defer spans.deinit(allocator);
        var total_packets: u64 = 0;
        var has_multiple_tile_parts = false;
        for (spans.items) |span| {
            total_packets = try std.math.add(u64, total_packets, span.packet_count);
            has_multiple_tile_parts = has_multiple_tile_parts or span.tile_part_count > 1;
        }
        var has_tile_poc = false;
        for (tile_poc_records) |records| has_tile_poc = has_tile_poc or records.items.len != 0;
        if (poc_records.items.len != 0 or has_tile_poc) {
            if (ppm_headers != null) return CodestreamError.UnsupportedPayload;
            if (subsampled_components and has_multiple_tile_parts) {
                return CodestreamError.UnsupportedPayload;
            }
            if (has_multiple_tile_parts) {
                switch (parsed_progression) {
                    .rpcl, .lrcp, .pcrl, .cprl => {},
                    else => return CodestreamError.UnsupportedPayload,
                }
            }
            var tile_index: u32 = 0;
            while (tile_index < grid.tileCount()) : (tile_index += 1) {
                const tile = grid.tile(tile_index) catch return CodestreamError.InvalidCodestream;
                const tile_plan = if (subsampled_components)
                    try makeAggregatePacketPlanForTile(
                        tile,
                        levels,
                        component_count,
                        options,
                        component_xrsiz,
                        component_yrsiz,
                    )
                else
                    try makePacketPlanForTile(tile, levels, options);
                const sequence = if (subsampled_components)
                    try buildSampledStrictPacketSequence(
                        allocator,
                        tile_plan,
                        component_count,
                        layers,
                        component_xrsiz,
                        component_yrsiz,
                        if (poc_records.items.len == 0) null else poc_records.items,
                        tile_poc_records[tile_index].items,
                    )
                else
                    try buildStrictPacketSequence(
                        allocator,
                        parsed_progression,
                        tile_plan,
                        component_count,
                        layers,
                        if (poc_records.items.len == 0) null else poc_records.items,
                        tile_poc_records[tile_index].items,
                    );
                if (has_multiple_tile_parts) {
                    switch (parsed_progression) {
                        .rpcl => {
                            try validatePocResolutionTilePartSequence(sequence, tile_plan);
                            try validatePocResolutionTilePartSpans(spans.items, @intCast(tile_index), tile_plan);
                        },
                        .lrcp => {
                            try validatePocLayerTilePartSequence(sequence, layers);
                            try validatePocLayerTilePartSpans(spans.items, @intCast(tile_index), sequence.len, layers);
                        },
                        .cprl => {
                            try validatePocComponentTilePartSequence(sequence);
                            try validatePocComponentTilePartSpans(spans.items, @intCast(tile_index), sequence.len);
                        },
                        .pcrl => try validatePocPositionTileParts(
                            allocator,
                            sequence,
                            spans.items,
                            @intCast(tile_index),
                            tile_plan,
                            layers,
                        ),
                        else => unreachable,
                    }
                }
                allocator.free(sequence);
            }
        }
        var plan = try makePacketPlan(width, height, levels, options);
        plan.packets = 0;
        for (plan.resolutions[0..plan.resolution_count]) |*resolution| resolution.packets = 0;
        var tile_index: u32 = 0;
        while (tile_index < grid.tileCount()) : (tile_index += 1) {
            const tile = grid.tile(tile_index) catch return CodestreamError.InvalidCodestream;
            const tile_plan = try makeAggregatePacketPlanForTile(
                tile,
                levels,
                component_count,
                options,
                component_xrsiz,
                component_yrsiz,
            );
            plan.packets = std.math.add(u64, plan.packets, tile_plan.packets) catch
                return CodestreamError.InvalidCodestream;
            for (plan.resolutions[0..plan.resolution_count], tile_plan.resolutions[0..tile_plan.resolution_count]) |*resolution, tile_resolution| {
                resolution.packets = std.math.add(u64, resolution.packets, tile_resolution.packets) catch
                    return CodestreamError.InvalidCodestream;
            }
        }
        if (plan.packets != total_packets) return CodestreamError.InvalidCodestream;
        return .{
            .version = 8,
            .width = width,
            .height = height,
            .reference_x0 = grid.params.xosiz,
            .reference_y0 = grid.params.yosiz,
            .bit_depth = bit_depth,
            .component_bit_depths = component_bit_depths,
            .component_xrsiz = component_xrsiz,
            .component_yrsiz = component_yrsiz,
            .component_qcd = component_qcd,
            .component_count = component_count,
            .levels = levels,
            .layers = layers,
            .progression = parsed_progression,
            .mct = parsed_mct,
            .transform = parsed_transform,
            .quantization = parsed_quantization,
            .code_block_style = parsed_code_block_style,
            .block_width = block_width,
            .block_height = block_height,
            .tile_width = grid.params.xtsiz,
            .tile_height = grid.params.ytsiz,
            .guard_bits = parsed_guard_bits,
            .qcd_exponents = parsed_qcd_exponents,
            .qcd_exponent_count = parsed_qcd_exponent_count,
            .qcd_steps = parsed_qcd_steps,
            .qcd_step_count = parsed_qcd_step_count,
            .tile_part_divisions = if (has_multiple_tile_parts) switch (parsed_progression) {
                .rpcl => 'R',
                .lrcp => 'L',
                .pcrl => 'P',
                .cprl => 'C',
                // RLCP has no matching public direct tile-part division.
                .rlcp => null,
            } else null,
            .tile_part_plan_count = 0,
            .tile_part_plan = [_]u8{0} ** 33,
            .packet_plan_count = plan.resolution_count,
            .packet_plan = plan.resolutions,
            .packet_count = total_packets,
        };
    }
    const single_tile = grid.tile(0) catch return CodestreamError.InvalidCodestream;
    var plan = try makePacketPlanForTileComponents(single_tile, levels, component_count, options);
    const component_plans = try StrictComponentPacketPlans.init(
        plan,
        component_count,
        layers,
        component_xrsiz,
        component_yrsiz,
    );
    plan.packets = component_plans.packet_count;
    for (plan.resolutions[0..plan.resolution_count], 0..) |*resolution, index| {
        resolution.packets = component_plans.resolution_packets[index];
    }
    const tile_part_packets = try readStrictTilePartPacketPlan(
        allocator,
        bytes,
        cursor,
        if (saw_tlm) tlm_entries.items else null,
        if (ppm_headers) |headers| headers else null,
        .{
            .component_count = component_count,
            .resolution_count = levels + 1,
            .layer_count = layers,
        },
    );
    const tile_part_plan = try validateStrictTilePartPacketPlan(tile_part_packets, plan, levels);

    return .{
        .version = 8,
        .width = width,
        .height = height,
        .reference_x0 = grid.params.xosiz,
        .reference_y0 = grid.params.yosiz,
        .bit_depth = bit_depth,
        .component_bit_depths = component_bit_depths,
        .component_xrsiz = component_xrsiz,
        .component_yrsiz = component_yrsiz,
        .component_qcd = component_qcd,
        .component_count = component_count,
        .levels = levels,
        .layers = layers,
        .progression = parsed_progression,
        .mct = parsed_mct,
        .transform = parsed_transform,
        .quantization = parsed_quantization,
        .code_block_style = parsed_code_block_style,
        .block_width = block_width,
        .block_height = block_height,
        .guard_bits = parsed_guard_bits,
        .qcd_exponents = parsed_qcd_exponents,
        .qcd_exponent_count = parsed_qcd_exponent_count,
        .qcd_steps = parsed_qcd_steps,
        .qcd_step_count = parsed_qcd_step_count,
        .tile_part_divisions = if (tile_part_plan.count > 0) 'R' else null,
        .tile_part_plan_count = tile_part_plan.count,
        .tile_part_plan = tile_part_plan.entries,
        .packet_plan_count = plan.resolution_count,
        .packet_plan = plan.resolutions,
        .packet_count = plan.packets,
    };
}

fn isUnsupportedMainHeaderMarker(marker: u16) bool {
    return switch (marker) {
        @intFromEnum(Marker.cap),
        @intFromEnum(Marker.plm),
        @intFromEnum(Marker.rgn),
        @intFromEnum(Marker.crg),
        => true,
        else => false,
    };
}

fn isUnsupportedTilePartHeaderMarker(marker: u16) bool {
    return switch (marker) {
        @intFromEnum(Marker.cod),
        @intFromEnum(Marker.coc),
        @intFromEnum(Marker.qcd),
        @intFromEnum(Marker.qcc),
        @intFromEnum(Marker.rgn),
        => true,
        else => false,
    };
}

fn codeBlockSizeFromCodExponent(exponent: u8) !u16 {
    if (exponent > 8) return CodestreamError.InvalidCodestream;
    return @as(u16, 1) << @as(u4, @intCast(exponent + 2));
}

fn validateStrictCocCodingPayload(segment: []const u8, scoc: u8) !void {
    if (segment.len < 5) return CodestreamError.InvalidCodestream;
    const levels = segment[0];
    if (levels > 32) return CodestreamError.TooManyLevels;
    const block_width = try codeBlockSizeFromCodExponent(segment[1]);
    const block_height = try codeBlockSizeFromCodExponent(segment[2]);
    try validateBlockSize(block_width, block_height);
    _ = try parseCodeBlockStyleByte(segment[3]);
    switch (segment[4]) {
        @intFromEnum(WaveletTransform.irreversible_9_7),
        @intFromEnum(WaveletTransform.reversible_5_3),
        => {},
        else => return CodestreamError.InvalidCodestream,
    }
    const precinct_count: usize = if ((scoc & 0x01) != 0) @as(usize, levels) + 1 else 0;
    if (segment.len != 5 + precinct_count) return CodestreamError.InvalidCodestream;
    for (segment[5..][0..precinct_count]) |byte| {
        const precinct = .{
            .width = @as(u16, 1) << @as(u4, @intCast(byte & 0x0f)),
            .height = @as(u16, 1) << @as(u4, @intCast(byte >> 4)),
        };
        if (!isValidPrecinctEdge(precinct.width) or !isValidPrecinctEdge(precinct.height)) {
            return CodestreamError.InvalidCodestream;
        }
    }
}

/// Upper bound on QCD subband entries: 1 LL + 3 per decomposition level,
/// with levels capped at 32 by the COD validation.
const max_qcd_bands = 1 + 3 * 32;

const StrictQcdInfo = struct {
    /// Logical subband count covered by the segment (1 + 3 * levels); the
    /// scalar-derived style covers all bands with a single signalled value.
    bands: usize,
    quantization: QuantizationStyle,
    /// Signalled guard bit count G (E-2). z2000 writes 2 by default; foreign
    /// reversible and irreversible streams may use any legal value in 1..7.
    guard_bits: u8 = strict_guard_bits,
    /// Signalled epsilon_b values from QCD. Scalar-expounded and reversible
    /// no-quantization store one value per band in QCD order: LL, then
    /// HL/LH/HH per decomposition level from `levels` down to 1.
    /// Scalar-derived stores the single LL value and derives the rest via E-5.
    /// Zero count means "derive from the z2000 formula" (sidecar path).
    exponents: [max_qcd_bands]u8 = [_]u8{0} ** max_qcd_bands,
    exponent_count: u8 = 0,
    /// Signalled irreversible (epsilon_b, mu_b) QCD step sizes. Scalar-
    /// expounded stores one value per band; scalar-derived stores the single
    /// LL value and derives the other bands via E-5. Reversible streams leave
    /// this empty.
    steps: [max_qcd_bands]BandStepSize = [_]BandStepSize{.{ .exponent = 0, .mantissa = 0 }} ** max_qcd_bands,
    step_count: u8 = 0,
};

fn validateStrictQcdSegment(segment: []const u8, bit_depth: u8, levels: u8, transform: WaveletTransform) !StrictQcdInfo {
    _ = bit_depth;
    if (segment.len < 2) return CodestreamError.InvalidCodestream;
    const bands = 1 + 3 * @as(usize, levels);
    if (bands > max_qcd_bands) return CodestreamError.InvalidCodestream;
    const style = segment[0];
    const quantization_value = style & 0x1f;
    if (quantization_value > @intFromEnum(QuantizationStyle.scalar_expounded)) return CodestreamError.InvalidCodestream;
    const quantization: QuantizationStyle = @enumFromInt(quantization_value);
    const guard_bits = style >> 5;

    if (transform == .irreversible_9_7) {
        // Irreversible streams may carry foreign but legal step mantissas;
        // follow the signalled guard bits and (epsilon_b, mu_b) pairs for Mb
        // sizing and dequantization.
        if (guard_bits == 0 or guard_bits > 7) return CodestreamError.InvalidCodestream;
        var info = StrictQcdInfo{
            .bands = bands,
            .quantization = quantization,
            .guard_bits = guard_bits,
        };
        if (quantization == .scalar_derived) {
            if (segment.len != 1 + 2) return CodestreamError.InvalidCodestream;
            var cursor: usize = 1;
            const step = try readStrictQcdScalarStep(segment, &cursor, guard_bits);
            info.exponents[0] = step.exponent;
            info.steps[0] = step;
            info.exponent_count = 1;
            info.step_count = 1;
            return info;
        }
        if (quantization != .scalar_expounded) return CodestreamError.UnsupportedPayload;
        if (segment.len != 1 + 2 * bands) return CodestreamError.InvalidCodestream;
        var cursor: usize = 1;
        var band_index: usize = 0;
        var step = try readStrictQcdScalarStep(segment, &cursor, guard_bits);
        info.exponents[band_index] = step.exponent;
        info.steps[band_index] = step;
        band_index += 1;
        var level: u8 = levels;
        while (level > 0) : (level -= 1) {
            inline for (.{ subband.Kind.hl, subband.Kind.lh, subband.Kind.hh }) |_| {
                step = try readStrictQcdScalarStep(segment, &cursor, guard_bits);
                info.exponents[band_index] = step.exponent;
                info.steps[band_index] = step;
                band_index += 1;
            }
        }
        info.exponent_count = @intCast(band_index);
        info.step_count = @intCast(band_index);
        return info;
    }

    if (quantization != .none) return CodestreamError.UnsupportedPayload;
    if (segment.len != 1 + bands) return CodestreamError.InvalidCodestream;
    // Reversible no-quantization: follow the *signalled* epsilon_b and guard
    // bits instead of requiring z2000's exact profile — foreign encoders
    // choose different legal values (Kakadu: 1 guard bit, RCT-widened
    // exponents), and E-2 obliges the decoder to derive Mb from what the
    // stream says. Bounds keep Mb in 1..31.
    if (guard_bits == 0 or guard_bits > 7) return CodestreamError.InvalidCodestream;

    var info = StrictQcdInfo{
        .bands = bands,
        .quantization = quantization,
        .guard_bits = guard_bits,
    };
    var cursor: usize = 1;
    var band_index: usize = 0;
    while (band_index < bands) : (band_index += 1) {
        const value = segment[cursor];
        // SPqcd for the no-quantization style carries epsilon_b in bits 7..3;
        // the low bits are not defined for this style and must be zero.
        if ((value & 0x07) != 0) return CodestreamError.UnsupportedPayload;
        const epsilon = value >> 3;
        if (epsilon == 0) return CodestreamError.InvalidCodestream;
        const nominal = @as(u16, epsilon) + guard_bits - 1;
        if (nominal == 0 or nominal > 31) return CodestreamError.InvalidCodestream;
        info.exponents[band_index] = epsilon;
        cursor += 1;
    }
    info.exponent_count = @intCast(bands);
    return info;
}

/// Signalled epsilon_b for a band, from the QCD exponent list stored in the
/// header (order: LL, then HL/LH/HH per decomposition level from `levels`
/// down to 1). Null when the header carries no parsed exponents.
fn signalledBandEpsilon(
    exponents: []const u8,
    levels: u8,
    kind: subband.Kind,
    band_level: u8,
) ?u8 {
    const index = signalledBandIndex(exponents.len, levels, kind, band_level) orelse return null;
    return exponents[index];
}

fn signalledBandIndex(
    count: usize,
    levels: u8,
    kind: subband.Kind,
    band_level: u8,
) ?usize {
    if (count == 0) return null;
    if (kind == .ll) return 0;
    if (band_level == 0 or band_level > levels) return null;
    const level_offset = @as(usize, levels - band_level);
    const kind_offset: usize = switch (kind) {
        .ll => unreachable,
        .hl => 0,
        .lh => 1,
        .hh => 2,
    };
    const index = 1 + 3 * level_offset + kind_offset;
    if (index >= count) return null;
    return index;
}

fn signalledHeaderBandEpsilon(
    header: TemporaryHeader,
    kind: subband.Kind,
    band_level: u8,
) ?u8 {
    const exponents = header.qcd_exponents[0..header.qcd_exponent_count];
    return switch (header.quantization) {
        .none, .scalar_expounded => signalledBandEpsilon(exponents, header.levels, kind, band_level),
        .scalar_derived => {
            if (exponents.len != 1) return null;
            const base = exponents[0];
            if (kind == .ll) return base;
            if (band_level == 0 or band_level > header.levels) return null;
            const drop = header.levels - band_level;
            if (base <= drop) return null;
            return base - drop;
        },
    };
}

fn signalledHeaderBandStep(
    header: TemporaryHeader,
    kind: subband.Kind,
    band_level: u8,
) ?BandStepSize {
    const steps = header.qcd_steps[0..header.qcd_step_count];
    return switch (header.quantization) {
        .none => null,
        .scalar_expounded => {
            const index = signalledBandIndex(steps.len, header.levels, kind, band_level) orelse return null;
            return steps[index];
        },
        .scalar_derived => {
            if (steps.len != 1) return null;
            const base = steps[0];
            if (kind == .ll) return base;
            if (band_level == 0 or band_level > header.levels) return null;
            const drop = header.levels - band_level;
            if (base.exponent <= drop) return null;
            return .{
                .exponent = base.exponent - drop,
                .mantissa = base.mantissa,
            };
        },
    };
}

/// Mb for a band on the strict decode path: reversible streams follow the
/// signalled QCD epsilon_b and guard bits (E-2) whenever the main header
/// captured QCD exponents; the sidecar path falls back to the z2000 formula.
fn bandNominalBitplanesForHeader(
    header: TemporaryHeader,
    component: usize,
    kind: subband.Kind,
    band_level: u8,
    levels: u8,
) !u8 {
    if (component >= header.component_count) return CodestreamError.InvalidCodestream;
    const component_info = header.component_qcd[component];
    // Per-component QCC state is currently promoted only for the bounded
    // mixed reversible profile. Uniform irreversible streams retain the
    // established scalar-derived/expounded mapping below.
    if (component_info.quantization == .none and component_info.exponent_count != 0) {
        const epsilon = signalledBandEpsilon(
            component_info.exponents[0..component_info.exponent_count],
            header.levels,
            kind,
            band_level,
        ) orelse return CodestreamError.InvalidCodestream;
        if (component_info.guard_bits == 0) return CodestreamError.InvalidCodestream;
        const total = @as(u16, epsilon) + component_info.guard_bits - 1;
        if (total == 0 or total > 31) return CodestreamError.InvalidCodestream;
        return @intCast(total);
    }
    if (header.qcd_exponent_count != 0) {
        // The QCD entry count follows the signalled NL (header.levels); the
        // caller-derived level count can be smaller when empty subbands were
        // skipped by the band builder, so the mapping must use the NL.
        const epsilon = signalledHeaderBandEpsilon(header, kind, band_level) orelse
            return CodestreamError.InvalidCodestream;
        if (header.guard_bits == 0) return CodestreamError.InvalidCodestream;
        const total = @as(u16, epsilon) + header.guard_bits - 1;
        if (total == 0 or total > 31) return CodestreamError.InvalidCodestream;
        return @intCast(total);
    }
    return bandNominalBitplanesForTransform(
        componentBitDepthForHeader(header, component),
        kind,
        band_level,
        header.transform,
        header.guard_bits,
        header.quantization,
        levels,
    );
}

fn componentBitDepthForHeader(header: TemporaryHeader, component: usize) u8 {
    if (component < header.component_count and header.component_bit_depths[component] != 0) {
        return header.component_bit_depths[component];
    }
    return header.bit_depth;
}

fn headerHasMixedComponentPrecision(header: TemporaryHeader) bool {
    if (header.component_count < 2) return false;
    const first = componentBitDepthForHeader(header, 0);
    for (1..header.component_count) |component| {
        if (componentBitDepthForHeader(header, component) != first) return true;
    }
    return false;
}

fn headerHasComponentSubsampling(header: TemporaryHeader) bool {
    for (0..header.component_count) |component| {
        if (header.component_xrsiz[component] != 1 or header.component_yrsiz[component] != 1) return true;
    }
    return false;
}

fn readStrictQcdScalarStep(
    segment: []const u8,
    cursor: *usize,
    guard_bits: u8,
) !BandStepSize {
    const actual = readU16Be(segment, cursor.*);
    cursor.* += 2;
    const exponent: u8 = @intCast(actual >> 11);
    const mantissa = actual & 0x07ff;
    if (exponent == 0) return CodestreamError.InvalidCodestream;
    const nominal = @as(u16, exponent) + guard_bits - 1;
    if (nominal == 0 or nominal > 31) return CodestreamError.InvalidCodestream;
    return .{ .exponent = exponent, .mantissa = mantissa };
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

fn temporaryPayload(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const payload = try temporaryPayloadRaw(allocator, bytes);
    errdefer allocator.free(payload);
    _ = try validateStrictRpclPacketsMatchTemporary(allocator, bytes, payload, .{});
    return payload;
}

fn temporaryPayloadRaw(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (bytes.len < 4 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    if (try temporaryPayloadFromComments(allocator, bytes)) |payload| {
        return payload;
    }

    var cursor: usize = 2;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        cursor += 2;
        if (marker == @intFromEnum(Marker.sot)) {
            cursor -= 2;
            break;
        }
        if (marker == @intFromEnum(Marker.eoc)) return CodestreamError.InvalidCodestream;
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) {
            return CodestreamError.TruncatedData;
        }
        cursor += segment_length;
    } else {
        return CodestreamError.InvalidCodestream;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var tile_part_index: usize = 0;
    var expected_tile_part_count: ?u8 = null;
    var expected_ppt_index: u16 = 0;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(Marker.eoc)) {
            cursor += 2;
            if (cursor != bytes.len) return CodestreamError.InvalidCodestream;
            try validateStrictTilePartSequenceFinished(tile_part_index, expected_tile_part_count);
            return out.toOwnedSlice(allocator);
        }
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;

        {
            var tile_part = try readStrictTilePartHeader(allocator, bytes, cursor, tile_part_index, &expected_tile_part_count, null, &expected_ppt_index, null, null);
            defer tile_part.deinit(allocator);
            cursor = tile_part.sod + 2;

            if (tile_part.packet_lengths.items.len > 0) {
                cursor = try appendTemporaryPacketPayloads(allocator, &out, bytes, cursor, tile_part.end, tile_part.packet_lengths.items);
            } else {
                const payload_start = try skipPacketBoundaryMarkers(bytes, cursor, tile_part.end);
                try out.appendSlice(allocator, bytes[payload_start..tile_part.end]);
            }
            cursor = tile_part.end;
        }
        tile_part_index += 1;
    }

    return CodestreamError.InvalidCodestream;
}

fn temporaryPayloadFromComments(allocator: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    if (bytes.len < 4 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var saw_payload = false;
    var expected_total: ?u32 = null;
    var next_chunk: u32 = 0;

    var cursor: usize = 2;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        cursor += 2;
        if (marker == @intFromEnum(Marker.sot)) break;
        if (marker == @intFromEnum(Marker.sod) or marker == @intFromEnum(Marker.eoc)) {
            return CodestreamError.InvalidCodestream;
        }
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) {
            return CodestreamError.TruncatedData;
        }
        const segment = bytes[cursor + 2 .. cursor + segment_length];
        if (marker == @intFromEnum(Marker.com)) {
            try appendTemporaryPayloadCommentChunk(allocator, &out, segment, &saw_payload, &expected_total, &next_chunk);
        }
        cursor += segment_length;
    }

    if (!saw_payload) return null;
    if (expected_total == null or next_chunk != expected_total.?) return CodestreamError.InvalidCodestream;
    return try out.toOwnedSlice(allocator);
}

fn appendTemporaryPayloadCommentChunk(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    segment: []const u8,
    saw_payload: *bool,
    expected_total: *?u32,
    next_chunk: *u32,
) !void {
    if (segment.len < 2 + temporary_comment_magic.len + 8) return;
    if (readU16Be(segment, 0) != 0) return;
    const comment = segment[2..];
    if (!std.mem.eql(u8, comment[0..temporary_comment_magic.len], temporary_comment_magic)) return;

    const header = temporary_comment_magic.len;
    const chunk_index = readU32Be(comment, header);
    const chunk_count = readU32Be(comment, header + 4);
    if (chunk_count == 0) return CodestreamError.InvalidCodestream;
    if (expected_total.*) |total| {
        if (chunk_count != total) return CodestreamError.InvalidCodestream;
    } else {
        expected_total.* = chunk_count;
    }
    if (chunk_index != next_chunk.* or chunk_index >= chunk_count) return CodestreamError.InvalidCodestream;

    saw_payload.* = true;
    next_chunk.* += 1;
    try out.appendSlice(allocator, comment[header + 8 ..]);
}

fn validateTilePartPayloads(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var cursor: usize = 2;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        cursor += 2;
        if (marker == @intFromEnum(Marker.sot)) {
            cursor -= 2;
            break;
        }
        if (marker == @intFromEnum(Marker.eoc)) return CodestreamError.InvalidCodestream;
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) {
            return CodestreamError.TruncatedData;
        }
        cursor += segment_length;
    } else {
        return CodestreamError.InvalidCodestream;
    }

    var tile_part_index: usize = 0;
    var expected_tile_part_count: ?u8 = null;
    var expected_ppt_index: u16 = 0;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(Marker.eoc)) {
            cursor += 2;
            if (cursor != bytes.len) return CodestreamError.InvalidCodestream;
            try validateStrictTilePartSequenceFinished(tile_part_index, expected_tile_part_count);
            return;
        }
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;

        {
            var tile_part = try readStrictTilePartHeader(allocator, bytes, cursor, tile_part_index, &expected_tile_part_count, null, &expected_ppt_index, null, null);
            defer tile_part.deinit(allocator);
            cursor = tile_part.sod + 2;
            if (tile_part.packet_lengths.items.len > 0) {
                if (tile_part.packet_payload_bytes != tile_part.end - cursor) return CodestreamError.InvalidCodestream;
            }
            cursor = tile_part.end;
        }
        tile_part_index += 1;
    }

    return CodestreamError.InvalidCodestream;
}

fn validateStrictRpclPacketsMatchTemporary(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    payload: []const u8,
    options: DecodeOptions,
) !PacketStreamInfo {
    try validateStrictMetadataMatchesTemporary(bytes, payload);
    var expected = try readRpclPacketStreamFromTemporary(allocator, payload);
    defer expected.deinit();
    if (expected.packet_lengths.len == 0) {
        try validateTilePartPayloads(allocator, bytes);
        return .{};
    }

    var actual = try readStrictSodRpclPacketStream(allocator, bytes, 3);
    defer actual.deinit();
    const sod = PacketStreamInfo{
        .packets = @intCast(actual.packet_lengths.len),
        .bytes = @intCast(actual.packet_bytes.len),
    };

    if (!std.mem.eql(u32, expected.packet_lengths, actual.packet_lengths)) {
        return CodestreamError.InvalidCodestream;
    }
    if (!std.mem.eql(u8, expected.packet_bytes, actual.packet_bytes)) {
        return CodestreamError.InvalidCodestream;
    }
    try validateStrictPacketBlockCatalogMatchesTemporary(allocator, bytes, payload);
    if (options.t1_backend == .iso_mq) {
        var strict = decodeStrictRpclImageFromCodestream(allocator, bytes, options) catch |err| switch (err) {
            CodestreamError.ImageTooLarge,
            CodestreamError.TooManyLevels,
            CodestreamError.InvalidCodestream,
            CodestreamError.UnsupportedPayload,
            CodestreamError.TruncatedData,
            => return err,
            else => return CodestreamError.InvalidCodestream,
        };
        defer strict.deinit();
        return sod;
    }

    var strict = decodeStrictRpclImageFromPackets(allocator, payload, actual, options) catch |err| switch (err) {
        CodestreamError.ImageTooLarge,
        CodestreamError.TooManyLevels,
        CodestreamError.InvalidCodestream,
        CodestreamError.UnsupportedPayload,
        CodestreamError.TruncatedData,
        => return err,
        else => return CodestreamError.InvalidCodestream,
    };
    defer strict.image.deinit();

    if (strict.complete) {
        var temporary_image = try decodeTemporaryPayloadWithOptions(allocator, payload, options);
        defer temporary_image.deinit();
        try validateRgbImagesEqual(temporary_image, strict.image);
    }
    return sod;
}

fn decodeStrictRpclImageWithTemporaryMetadata(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    payload: []const u8,
    options: DecodeOptions,
) !?image.RgbImage {
    try validateStrictMetadataMatchesTemporary(bytes, payload);
    var expected = try readRpclPacketStreamFromTemporary(allocator, payload);
    defer expected.deinit();
    if (expected.packet_lengths.len == 0) return null;

    var actual = try readStrictSodRpclPacketStream(allocator, bytes, 3);
    defer actual.deinit();
    if (!std.mem.eql(u32, expected.packet_lengths, actual.packet_lengths)) {
        return CodestreamError.InvalidCodestream;
    }
    if (!std.mem.eql(u8, expected.packet_bytes, actual.packet_bytes)) {
        return CodestreamError.InvalidCodestream;
    }

    try validateStrictPacketBlockCatalogMatchesTemporary(allocator, bytes, payload);
    if (options.t1_backend == .iso_mq) {
        return try decodeStrictRpclImageFromCodestream(allocator, bytes, options);
    }

    var strict = try decodeStrictRpclImageFromPackets(allocator, payload, actual, options);
    if (!strict.complete) {
        strict.image.deinit();
        return null;
    }
    return strict.image;
}

fn decodeStrictRpclImageFromCodestream(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    options: DecodeOptions,
) !image.RgbImage {
    const header = try readStrictCodestreamMetadata(allocator, bytes);
    var strict_catalog = try readStrictPacketBlockCatalog(allocator, bytes);
    defer strict_catalog.deinit();
    return decodeStrictRpclImageFromBlockCatalog(allocator, header, strict_catalog, options);
}

fn validateStrictPacketBlockCatalogMatchesTemporary(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    payload: []const u8,
) !void {
    var cursor = Cursor.initWithAllocator(allocator, payload);
    const header = try readTemporaryHeader(&cursor);
    if (header.version < 8) return CodestreamError.UnsupportedPayload;

    const bands = try subband.makeBands(allocator, header.width, header.height, header.levels);
    defer allocator.free(bands);

    var expected: [3]TemporaryComponentRpclCatalog = undefined;
    var initialized_expected: usize = 0;
    defer {
        for (expected[0..initialized_expected]) |*catalog| catalog.deinit();
    }
    inline for (0..3) |component| {
        expected[component] = try readTemporaryComponentRpclCatalog(allocator, &cursor, component, header.version, header.layers, header.bit_depth, bands);
        initialized_expected += 1;
    }
    _ = try readRpclShadowStreamInfo(&cursor, header.version, header.packet_count);
    if (!cursor.finished()) return CodestreamError.InvalidCodestream;

    const blocks = try subband.makeCodeBlocks(allocator, bands, header.block_width, header.block_height);
    defer allocator.free(blocks);
    try validateTemporaryCatalogsMatchCodeBlocks(expected, blocks);

    var actual = try readStrictPacketBlockCatalog(allocator, bytes);
    defer actual.deinit();
    inline for (0..3) |component| {
        try validateStrictPacketBlockComponentCatalog(expected[component].blocks, actual, component, header.layers);
    }
}

fn validateStrictPacketBlockComponentCatalog(
    expected: []const TemporaryRpclBlock,
    actual: StrictPacketBlockCatalog,
    component: usize,
    layer_count: u16,
) !void {
    if (layer_count == 0 or layer_count > max_quality_layers) return CodestreamError.InvalidCodestream;
    if (component >= 3 or actual.components[component].len != expected.len) return CodestreamError.InvalidCodestream;
    const final_layer: usize = @intCast(layer_count - 1);
    for (expected, actual.components[component], 0..) |expected_block, actual_block, block_index| {
        const final = expected_block.layers[final_layer];
        if (actual_block.cumulative_passes != final.cumulative_passes or
            actual_block.cumulative_bytes != final.cumulative_bytes)
        {
            return CodestreamError.InvalidCodestream;
        }
        const payload = actual.blockPayload(component, block_index);
        const expected_len = std.math.cast(usize, final.cumulative_bytes) orelse return CodestreamError.InvalidCodestream;
        if (payload.len != expected_len or expected_len > expected_block.payload.len) {
            return CodestreamError.InvalidCodestream;
        }
        if (final.cumulative_passes == 0 and final.cumulative_bytes == 0) {
            if (payload.len != 0) return CodestreamError.InvalidCodestream;
            continue;
        }
        if (!actual_block.metadata_ready) return CodestreamError.InvalidCodestream;
        if (actual_block.band_index != expected_block.band_index) return CodestreamError.InvalidCodestream;
        if (!rectsEqual(actual_block.rect, expected_block.rect)) return CodestreamError.InvalidCodestream;
        if (actual_block.encoded_bitplanes > actual_block.nominal_bitplanes) return CodestreamError.InvalidCodestream;
        if (!std.mem.eql(u8, payload, expected_block.payload[0..expected_len])) {
            return CodestreamError.InvalidCodestream;
        }
    }
}

fn validateStrictMetadataMatchesTemporary(bytes: []const u8, payload: []const u8) !void {
    var cursor = Cursor.initWithAllocator(std.heap.page_allocator, payload);
    const temporary = try readTemporaryHeader(&cursor);
    const strict = try readStrictCodestreamMetadata(std.heap.page_allocator, bytes);

    if (strict.width != temporary.width or
        strict.height != temporary.height or
        strict.reference_x0 != temporary.reference_x0 or
        strict.reference_y0 != temporary.reference_y0 or
        strict.bit_depth != temporary.bit_depth or
        strict.levels != temporary.levels or
        strict.layers != temporary.layers or
        strict.block_width != temporary.block_width or
        strict.block_height != temporary.block_height or
        strict.tile_part_divisions != temporary.tile_part_divisions or
        strict.tile_part_plan_count != temporary.tile_part_plan_count or
        strict.packet_plan_count != temporary.packet_plan_count or
        strict.packet_count != temporary.packet_count)
    {
        return CodestreamError.InvalidCodestream;
    }
    if (!std.mem.eql(u8, strict.tile_part_plan[0..strict.tile_part_plan_count], temporary.tile_part_plan[0..temporary.tile_part_plan_count])) {
        return CodestreamError.InvalidCodestream;
    }
    var resolution_index: usize = 0;
    while (resolution_index < strict.packet_plan_count) : (resolution_index += 1) {
        if (!resolutionMetadataEqual(strict.packet_plan[resolution_index], temporary.packet_plan[resolution_index])) {
            return CodestreamError.InvalidCodestream;
        }
    }
}

fn resolutionMetadataEqual(a: packet_plan.Resolution, b: packet_plan.Resolution) bool {
    return a.width == b.width and
        a.height == b.height and
        a.precinct_width == b.precinct_width and
        a.precinct_height == b.precinct_height and
        a.precincts_x == b.precincts_x and
        a.precincts_y == b.precincts_y and
        a.precincts == b.precincts and
        a.packets == b.packets;
}

fn readRpclPacketStreamFromTemporary(allocator: std.mem.Allocator, payload: []const u8) !RpclPacketStream {
    var cursor = Cursor.initWithAllocator(allocator, payload);
    const header = try readTemporaryHeader(&cursor);
    if (header.version < 8) return .{};

    try skipComponentPayload(&cursor, 0, header.version, header.layers);
    try skipComponentPayload(&cursor, 1, header.version, header.layers);
    try skipComponentPayload(&cursor, 2, header.version, header.layers);

    const packet_count = try cursor.readU64();
    if (packet_count != header.packet_count) return CodestreamError.InvalidCodestream;
    const byte_count = try cursor.readU64();
    const packet_count_usize = std.math.cast(usize, packet_count) orelse return CodestreamError.InvalidCodestream;
    const lengths = try allocator.alloc(u32, packet_count_usize);
    errdefer allocator.free(lengths);
    var packet_bytes: std.ArrayList(u8) = .empty;
    errdefer packet_bytes.deinit(allocator);

    var actual_bytes: u64 = 0;
    for (lengths) |*length| {
        const packet_len = try cursor.readU32();
        length.* = packet_len;
        actual_bytes = try std.math.add(u64, actual_bytes, packet_len);
        const packet = try cursor.readBytes(@as(usize, @intCast(packet_len)));
        try packet_bytes.appendSlice(allocator, packet);
    }
    if (actual_bytes != byte_count) return CodestreamError.InvalidCodestream;
    if (!cursor.finished()) return CodestreamError.InvalidCodestream;

    return .{
        .allocator = allocator,
        .packet_lengths = lengths,
        .packet_bytes = try packet_bytes.toOwnedSlice(allocator),
    };
}

fn decodeStrictRpclImageFromPackets(
    allocator: std.mem.Allocator,
    payload: []const u8,
    actual: RpclPacketStream,
    options: DecodeOptions,
) !StrictRpclImage {
    var cursor = Cursor.initWithAllocator(allocator, payload);
    const header = try readTemporaryHeader(&cursor);
    if (header.version < 8) return CodestreamError.UnsupportedPayload;

    const plan = temporaryPacketPlan(header);
    const bands = try subband.makeBands(allocator, header.width, header.height, header.levels);
    defer allocator.free(bands);
    const blocks = try subband.makeCodeBlocks(allocator, bands, header.block_width, header.block_height);
    defer allocator.free(blocks);

    var catalogs: [3]TemporaryComponentRpclCatalog = undefined;
    var initialized_catalogs: usize = 0;
    defer {
        for (catalogs[0..initialized_catalogs]) |*catalog| catalog.deinit();
    }
    inline for (0..3) |component| {
        catalogs[component] = try readTemporaryComponentRpclCatalog(allocator, &cursor, component, header.version, header.layers, header.bit_depth, bands);
        initialized_catalogs += 1;
    }

    var assemblies: [3]StrictComponentAssembly = undefined;
    var initialized_assemblies: usize = 0;
    defer {
        for (assemblies[0..initialized_assemblies]) |*assembly| assembly.deinit();
    }
    inline for (0..3) |component| {
        assemblies[component] = try StrictComponentAssembly.init(allocator, catalogs[component].blocks.len, false);
        initialized_assemblies += 1;
    }

    _ = try readRpclShadowStreamInfo(&cursor, header.version, header.packet_count);
    if (!cursor.finished()) return CodestreamError.InvalidCodestream;

    try validateTemporaryCatalogsMatchCodeBlocks(catalogs, blocks);
    var rpcl_index = try buildRpclBlockIndex(allocator, plan, header.component_count, header.levels, bands, blocks);
    defer rpcl_index.deinit();

    if (actual.packet_lengths.len != header.packet_count) return CodestreamError.InvalidCodestream;
    var sequence: u64 = 0;
    var packet_byte_offset: usize = 0;
    var resolution_index: usize = 0;
    while (resolution_index < header.packet_plan_count) : (resolution_index += 1) {
        const resolution = plan.resolutions[resolution_index];
        var precinct_index: u64 = 0;
        while (precinct_index < resolution.precincts) : (precinct_index += 1) {
            var component: u16 = 0;
            while (component < 3) : (component += 1) {
                const selected = try rpcl_index.indexesFor(@intCast(resolution_index), precinct_index, component);
                if (selected.len == 0) {
                    var layer: u16 = 0;
                    while (layer < header.layers) : (layer += 1) {
                        const packet = packetSliceForSequence(actual, sequence, packet_byte_offset);
                        try validateEmptyRpclPacket(packet.bytes);
                        packet_byte_offset = packet.next_offset;
                        sequence += 1;
                    }
                    continue;
                }

                const groups = try buildRpclPacketReaderBandGroups(
                    allocator,
                    bands,
                    blocks,
                    header.block_width,
                    header.block_height,
                    catalogs[component].blocks,
                    selected,
                    header.layers,
                );
                defer {
                    for (groups) |*group| group.deinit(allocator);
                    allocator.free(groups);
                }

                var layer: u16 = 0;
                while (layer < header.layers) : (layer += 1) {
                    const packet_bytes = packetSliceForSequence(actual, sequence, packet_byte_offset);
                    const packet = packet_plan.Packet{
                        .sequence = sequence,
                        .resolution = @intCast(resolution_index),
                        .precinct_x = @intCast(precinct_index % resolution.precincts_x),
                        .precinct_y = @intCast(precinct_index / resolution.precincts_x),
                        .precinct_index = precinct_index,
                        .component = component,
                        .layer = layer,
                    };
                    const read = try readRpclPacketForBandGroups(
                        allocator,
                        packet_bytes.bytes,
                        packet,
                        @intCast(resolution_index),
                        component,
                        precinct_index,
                        catalogs[component].blocks,
                        groups,
                    );
                    if (read.packet_length != packet_bytes.bytes.len) return CodestreamError.InvalidCodestream;
                    try collectStrictRpclPacketBlocks(
                        &assemblies[component],
                        groups,
                    );
                    packet_byte_offset = packet_bytes.next_offset;
                    sequence += 1;
                }
            }
        }
    }
    if (sequence != header.packet_count or packet_byte_offset != actual.packet_bytes.len) return CodestreamError.InvalidCodestream;
    inline for (0..3) |component| {
        try validateStrictComponentAssembly(catalogs[component].blocks, assemblies[component], header.layers);
    }
    var strict_planes = try reconstructStrictComponentCoefficientPlanes(allocator, header, catalogs, assemblies, options);
    defer strict_planes.deinit();
    if (plan.resolution_count == 0) return CodestreamError.InvalidCodestream;
    const full_resolution = plan.resolutions[plan.resolution_count - 1];
    try inverseComponents53(
        allocator,
        .{ .slices = .{ strict_planes.planes[0], strict_planes.planes[1], strict_planes.planes[2] } },
        header.width,
        header.height,
        header.levels,
        full_resolution.x0,
        full_resolution.y0,
        options,
    );
    var strict_image = if (header.mct == .none)
        try color.inverseNoTransform(allocator, strict_planes)
    else
        try color.inverseRctThreaded(allocator, strict_planes, options.threads);
    errdefer strict_image.deinit();

    return .{
        .image = strict_image,
        .complete = strictAssembliesComplete(catalogs, assemblies),
    };
}

fn readTemporaryComponentRpclCatalog(
    allocator: std.mem.Allocator,
    cursor: *Cursor,
    comptime expected_component: u8,
    payload_version: u8,
    layer_count: u16,
    nominal_bitplanes: u8,
    expected_bands: []const subband.Band,
) !TemporaryComponentRpclCatalog {
    const component_index = try cursor.readU8();
    if (component_index != expected_component) return CodestreamError.InvalidCodestream;

    const band_count = try cursor.readU16();
    const block_count = try cursor.readU32();
    if (band_count != expected_bands.len) return CodestreamError.InvalidCodestream;

    var band_index: usize = 0;
    while (band_index < band_count) : (band_index += 1) {
        const kind_value = try cursor.readU8();
        if (kind_value > @intFromEnum(subband.Kind.hh)) return CodestreamError.InvalidCodestream;
        const kind: subband.Kind = @enumFromInt(kind_value);
        const level = try cursor.readU8();
        const rect = try cursor.readRect();
        const expected = expected_bands[band_index];
        if (kind != expected.kind or level != expected.level or !rectsEqual(rect, expected.rect)) {
            return CodestreamError.InvalidCodestream;
        }
    }

    const blocks = try allocator.alloc(TemporaryRpclBlock, block_count);
    var initialized_blocks: usize = 0;
    errdefer {
        for (blocks[0..initialized_blocks]) |block| {
            if (block.passes.len > 0) allocator.free(block.passes);
        }
        allocator.free(blocks);
    }
    for (blocks) |*block| block.* = undefined;

    var block_index: usize = 0;
    while (block_index < block_count) : (block_index += 1) {
        const block_band = try cursor.readU16();
        if (block_band >= band_count) return CodestreamError.InvalidCodestream;
        const block_rect = try cursor.readRect();
        _ = try cursor.readRect();
        const bitplanes = try cursor.readU8();
        const block_nominal_bitplanes = try subbandNominalBitplanes(nominal_bitplanes, expected_bands[block_band].kind, strict_guard_bits);
        const non_zero_count = try cursor.readU32();
        const coding_passes = try readStoredCodingPasses(cursor, payload_version, bitplanes, non_zero_count);
        const layers = try readLayerAllocation(cursor, payload_version, layer_count, coding_passes);
        _ = try readEntropyStreamInfo(cursor);
        _ = try readEntropyStreamInfo(cursor);
        _ = try readEntropyStreamInfo(cursor);
        var ebcot_segment = try readEbcotSegmentInfoWithPasses(allocator, cursor, payload_version, coding_passes);
        errdefer ebcot_segment.deinit(allocator);
        if (payload_version < 7 and ebcot_segment.stats.mq_bytes != 0) return CodestreamError.InvalidCodestream;
        const payload_len = std.math.cast(usize, ebcot_segment.stats.mq_bytes) orelse return CodestreamError.InvalidCodestream;
        const payload = if (payload_version >= 7) try cursor.readBytes(payload_len) else &.{};

        var converted_layers = [_]t2.LayerTruncation{.{ .cumulative_passes = 0, .cumulative_bytes = 0 }} ** max_quality_layers;
        for (layers[0..@as(usize, @intCast(layer_count))], 0..) |layer, index| {
            converted_layers[index] = .{
                .cumulative_passes = layer.cumulative_passes,
                .cumulative_bytes = layer.cumulative_bytes,
            };
        }
        blocks[block_index] = .{
            .band_index = block_band,
            .rect = block_rect,
            .nominal_bitplanes = @max(block_nominal_bitplanes, bitplanes),
            .encoded_bitplanes = bitplanes,
            .non_zero_count = non_zero_count,
            .layers = converted_layers,
            .passes = ebcot_segment.passes,
            .payload = payload,
        };
        ebcot_segment.passes = &.{};
        initialized_blocks += 1;
    }

    return .{
        .allocator = allocator,
        .blocks = blocks,
    };
}

fn temporaryPacketPlan(header: TemporaryHeader) packet_plan.Plan {
    return .{
        .resolution_count = header.packet_plan_count,
        .resolutions = header.packet_plan,
        .packets = header.packet_count,
    };
}

const PacketSlice = struct {
    bytes: []const u8,
    next_offset: usize,
};

fn packetSliceForSequence(stream: RpclPacketStream, sequence: u64, byte_offset: usize) PacketSlice {
    const index: usize = @intCast(sequence);
    const length: usize = @intCast(stream.packet_lengths[index]);
    return .{
        .bytes = stream.packet_bytes[byte_offset..][0..length],
        .next_offset = byte_offset + length,
    };
}

fn validateEmptyRpclPacket(bytes: []const u8) !void {
    var cursor: usize = 0;
    const present = try t2.readPacketPresenceHeader(bytes, &cursor, bytes.len);
    if (present or cursor != bytes.len) return CodestreamError.InvalidCodestream;
}

fn auditStrictPacketCatalogHeaders(
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    catalog: StrictPacketCatalog,
) !StrictPacketHeaderAudit {
    var audit = StrictPacketHeaderAudit{};
    var assemblies = try assembleStrictPacketCatalogHeaders(allocator, header, catalog, &audit);
    defer assemblies.deinit();

    const assembly_stats = try strictAssemblyStats(assemblies.assemblies[0..assemblies.initialized]);
    if (assembly_stats.bytes != audit.payload_bytes) return CodestreamError.InvalidCodestream;
    audit.assembled_blocks = assembly_stats.blocks;
    audit.assembled_bytes = assembly_stats.bytes;
    audit.assembled_passes = assembly_stats.passes;
    audit.t1_ready_blocks = assembly_stats.t1_ready_blocks;
    return audit;
}

fn assembleStrictPacketCatalogHeaders(
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    catalog: StrictPacketCatalog,
    audit: *StrictPacketHeaderAudit,
) !StrictComponentAssemblySet {
    var geometries = try StrictComponentGeometrySet.init(allocator, header);
    defer geometries.deinit();

    var block_counts: [max_codestream_components]usize = [_]usize{0} ** max_codestream_components;
    for (0..header.component_count) |component| {
        const geometry = try geometries.geometryFor(component);
        block_counts[component] = geometry.blocks.len;
    }

    var assemblies = try StrictComponentAssemblySet.init(
        allocator,
        header.component_count,
        block_counts[0..header.component_count],
        header.layers == 1,
    );
    errdefer assemblies.deinit();
    for (0..header.component_count) |component| {
        const geometry = try geometries.geometryFor(component);
        try initializeStrictAssemblyGeometry(
            &assemblies.assemblies[component],
            geometry.bands,
            geometry.blocks,
            geometry.width,
            geometry.height,
            geometry.x0,
            geometry.y0,
            header,
            component,
        );
    }

    const use_packet_group_arena = header.layers == 1;
    var packet_group_arena = std.heap.ArenaAllocator.init(allocator);
    defer packet_group_arena.deinit();
    const group_allocator = if (use_packet_group_arena) packet_group_arena.allocator() else allocator;

    var active_group_storage: [max_rpcl_packet_band_groups]StrictPacketAuditBandGroup = undefined;
    var active_group_count: usize = 0;
    defer {
        if (!use_packet_group_arena) {
            deinitStrictPacketAuditBandGroups(group_allocator, active_group_storage[0..active_group_count]);
        }
    }
    for (catalog.entries) |entry| {
        const geometry = try geometries.geometryFor(entry.packet.component);
        const local_packet = try geometry.localPacket(entry.packet);
        const selected = try geometry.rpcl_index.indexesFor(local_packet.resolution, local_packet.precinct_index, 0);
        const packet_bytes = catalog.packetBytes(entry);
        audit.packets += 1;
        if (entry.packet.layer == 0) {
            if (use_packet_group_arena) {
                _ = packet_group_arena.reset(.retain_capacity);
            } else {
                deinitStrictPacketAuditBandGroups(group_allocator, active_group_storage[0..active_group_count]);
            }
            active_group_count = 0;
            if (selected.len > 0) {
                active_group_count = try buildStrictPacketAuditBandGroups(
                    group_allocator,
                    geometry.bands,
                    geometry.blocks,
                    selected,
                    header,
                    entry.packet.component,
                    &active_group_storage,
                );
            }
        } else if (selected.len > 0 and active_group_count == 0) {
            return CodestreamError.InvalidCodestream;
        }
        const active_groups = active_group_storage[0..active_group_count];

        if (selected.len == 0) {
            const read = try readStrictPacketHeaderForAudit(packet_bytes, entry.packet, &.{}, null, &.{});
            if (read.included_blocks != 0 or read.payload_length != 0) {
                return CodestreamError.InvalidCodestream;
            }
            audit.geometry_empty_packets += 1;
            if (read.present) {
                audit.present_packets += 1;
            } else {
                audit.absent_packets += 1;
            }
            audit.header_decoded_packets += 1;
            audit.header_bytes += read.header_length;
            continue;
        }

        const read = try readStrictPacketHeaderForAudit(
            packet_bytes,
            entry.packet,
            active_groups,
            &assemblies.assemblies[entry.packet.component],
            geometry.blocks,
        );
        audit.header_decoded_packets += 1;
        audit.header_bytes += read.header_length;
        audit.payload_bytes += read.payload_length;
        audit.included_blocks += read.included_blocks;
        if (read.present) {
            audit.present_packets += 1;
        } else {
            audit.absent_packets += 1;
        }
    }
    if (audit.packets != header.packet_count) return CodestreamError.InvalidCodestream;
    if (audit.present_packets + audit.absent_packets != audit.packets) return CodestreamError.InvalidCodestream;
    if (audit.header_decoded_packets != audit.packets) return CodestreamError.InvalidCodestream;
    return assemblies;
}

const StrictPacketHeaderRead = struct {
    present: bool,
    header_length: u64,
    payload_length: u64,
    included_blocks: u64,
};

fn readStrictPacketHeaderForAudit(
    bytes: []const u8,
    packet: packet_plan.Packet,
    groups: []StrictPacketAuditBandGroup,
    assembly: ?*StrictComponentAssembly,
    source_blocks: []const subband.CodeBlock,
) !StrictPacketHeaderRead {
    var reader = t2.PacketHeaderReader.init(bytes);
    const packet_included = reader.readBit() catch return CodestreamError.InvalidCodestream;
    if (packet_included) {
        for (groups) |*group| {
            t2.readPrecinctPacketHeaderBody(
                &reader,
                &group.reader_state.inclusion,
                &group.reader_state.zero_bitplanes,
                group.reader_state.states,
                packet.layer,
                group.locations,
                group.max_zero_bitplanes,
                group.reader_state.bypass,
                group.reader_state.terminate_all,
                group.decoded,
            ) catch return CodestreamError.InvalidCodestream;
        }
    }
    reader.byteAlign() catch return CodestreamError.InvalidCodestream;

    const header_length = reader.bytesConsumed();
    if (!packet_included) {
        if (header_length != bytes.len) return CodestreamError.InvalidCodestream;
        return .{
            .present = false,
            .header_length = @intCast(header_length),
            .payload_length = 0,
            .included_blocks = 0,
        };
    }

    var payload_length: u64 = 0;
    var included_blocks: u64 = 0;
    var cursor = header_length;
    for (groups) |group| {
        if (group.source_indexes.len != group.decoded.len) return CodestreamError.InvalidCodestream;
        for (group.source_indexes, group.decoded) |block_index, decoded| {
            if (!decoded.included) continue;
            const byte_length = std.math.cast(usize, decoded.byte_length) orelse return CodestreamError.InvalidCodestream;
            const end = try std.math.add(usize, cursor, byte_length);
            if (end > bytes.len) return CodestreamError.TruncatedData;
            const payload = bytes[cursor..end];
            if (assembly) |target| {
                try appendStrictPacketAuditBlock(target, source_blocks, block_index, decoded, payload);
            }
            cursor = end;
            payload_length = try std.math.add(u64, payload_length, decoded.byte_length);
            included_blocks += 1;
        }
    }
    if (cursor != bytes.len) return CodestreamError.InvalidCodestream;

    return .{
        .present = packet_included,
        .header_length = @intCast(header_length),
        .payload_length = payload_length,
        .included_blocks = included_blocks,
    };
}

fn appendStrictPacketAuditBlock(
    assembly: *StrictComponentAssembly,
    source_blocks: []const subband.CodeBlock,
    block_index: usize,
    decoded: t2.DecodedPacketBlock,
    payload: []const u8,
) !void {
    if (block_index >= assembly.blocks.len or block_index >= source_blocks.len) {
        return CodestreamError.InvalidCodestream;
    }
    if (!decoded.included or payload.len != decoded.byte_length) return CodestreamError.InvalidCodestream;

    var block = &assembly.blocks[block_index];
    if (!block.metadata_ready) {
        if (!decoded.first_inclusion) return CodestreamError.InvalidCodestream;
        if (decoded.zero_bitplanes > block.nominal_bitplanes) return CodestreamError.InvalidCodestream;
        const source = source_blocks[block_index];
        block.metadata_ready = true;
        block.band_index = source.band_index;
        block.rect = source.rect;
        block.encoded_bitplanes = block.nominal_bitplanes - decoded.zero_bitplanes;
    } else if (decoded.first_inclusion) {
        return CodestreamError.InvalidCodestream;
    }
    block.cumulative_passes = std.math.add(u16, block.cumulative_passes, decoded.pass_count) catch return CodestreamError.InvalidCodestream;
    block.cumulative_bytes = try std.math.add(u64, block.cumulative_bytes, decoded.byte_length);
    const inferred_bitplanes = inferredBitplanesForCodingPassPrefix(block.cumulative_passes);
    if (inferred_bitplanes > block.encoded_bitplanes) {
        block.encoded_bitplanes = inferred_bitplanes;
        block.nominal_bitplanes = @max(block.nominal_bitplanes, block.encoded_bitplanes);
    }
    try block.appendSegmentLengths(decoded);
    if (assembly.use_component_payloads) {
        if (block.payload_length != 0) return CodestreamError.InvalidCodestream;
        block.payload_offset = assembly.payloads.items.len;
        try assembly.payloads.appendSlice(assembly.allocator, payload);
        block.payload_length = payload.len;
        if (block.payload_length != block.cumulative_bytes) return CodestreamError.InvalidCodestream;
    } else {
        try block.payload.appendSlice(assembly.allocator, payload);
        if (block.payload.items.len != block.cumulative_bytes) return CodestreamError.InvalidCodestream;
    }
}

fn initializeStrictAssemblyGeometry(
    assembly: *StrictComponentAssembly,
    bands: []const subband.Band,
    source_blocks: []const subband.CodeBlock,
    width: usize,
    height: usize,
    x0: u32,
    y0: u32,
    header: TemporaryHeader,
    component: usize,
) !void {
    if (assembly.blocks.len != source_blocks.len) return CodestreamError.InvalidCodestream;
    if (width == 0 or height == 0) return CodestreamError.InvalidCodestream;
    assembly.width = width;
    assembly.height = height;
    assembly.x0 = x0;
    assembly.y0 = y0;
    for (assembly.blocks, source_blocks) |*block, source| {
        if (source.band_index >= bands.len) return CodestreamError.InvalidCodestream;
        block.band_index = source.band_index;
        block.rect = source.rect;
        block.nominal_bitplanes = try bandNominalBitplanesForHeader(
            header,
            component,
            bands[source.band_index].kind,
            bands[source.band_index].level,
            dwtLevelsFromBands(bands),
        );
        block.encoded_bitplanes = 0;
        block.code_block_style = codeBlockStyleForBand(header.code_block_style, bands[source.band_index].kind);
    }
}

const StrictAssemblyStats = struct {
    blocks: u64 = 0,
    bytes: u64 = 0,
    passes: u64 = 0,
    t1_ready_blocks: u64 = 0,
};

const StrictPacketBlockCatalogBuild = struct {
    catalog: StrictPacketBlockCatalog,
    stats: StrictAssemblyStats,
};

fn strictAssemblyStats(assemblies: []const StrictComponentAssembly) !StrictAssemblyStats {
    var stats = StrictAssemblyStats{};
    for (assemblies) |assembly| {
        for (assembly.blocks) |block| {
            if (block.cumulative_bytes == 0 and block.cumulative_passes == 0) continue;
            const payload_length = strictAssemblyBlockPayloadLength(assembly, block);
            if (payload_length != block.cumulative_bytes) return CodestreamError.InvalidCodestream;
            if (!block.metadata_ready or block.rect.width == 0 or block.rect.height == 0) {
                return CodestreamError.InvalidCodestream;
            }
            if (block.encoded_bitplanes > block.nominal_bitplanes) return CodestreamError.InvalidCodestream;
            stats.blocks += 1;
            stats.bytes = try std.math.add(u64, stats.bytes, block.cumulative_bytes);
            stats.passes = try std.math.add(u64, stats.passes, block.cumulative_passes);
            stats.t1_ready_blocks += 1;
        }
    }
    return stats;
}

fn strictAssemblyBlockPayloadLength(assembly: StrictComponentAssembly, block: StrictRpclBlockAssembly) usize {
    return if (assembly.use_component_payloads) block.payload_length else block.payload.items.len;
}

fn inferredBitplanesForCodingPassPrefix(pass_count: u16) u8 {
    if (pass_count == 0) return 0;
    return @intCast(1 + (@as(u16, pass_count - 1) + 2) / 3);
}

fn codeBlockStyleForBand(style: ebcot.CodeBlockStyle, band_kind: subband.Kind) ebcot.CodeBlockStyle {
    var out = style;
    out.band_kind = band_kind;
    return out;
}

fn strictPacketBlockCatalogFromAssemblies(
    allocator: std.mem.Allocator,
    assemblies: []StrictComponentAssembly,
) !StrictPacketBlockCatalog {
    const build = try strictPacketBlockCatalogFromAssembliesChecked(allocator, assemblies);
    return build.catalog;
}

fn strictPacketBlockCatalogFromAssembliesChecked(
    allocator: std.mem.Allocator,
    assemblies: []StrictComponentAssembly,
) !StrictPacketBlockCatalogBuild {
    if (assemblies.len < 1 or assemblies.len > max_codestream_components) return CodestreamError.UnsupportedPayload;
    var catalog = StrictPacketBlockCatalog{
        .allocator = allocator,
        .component_count = @intCast(assemblies.len),
    };
    errdefer catalog.deinit();
    var stats = StrictAssemblyStats{};

    for (0..assemblies.len) |component| {
        const assembly = &assemblies[component];
        if (assembly.width == 0 or assembly.height == 0) return CodestreamError.InvalidCodestream;
        catalog.component_widths[component] = assembly.width;
        catalog.component_heights[component] = assembly.height;
        catalog.component_x0[component] = assembly.x0;
        catalog.component_y0[component] = assembly.y0;
        var payload_total: usize = 0;
        for (assembly.blocks) |block| {
            const payload_length = strictAssemblyBlockPayloadLength(assembly.*, block);
            payload_total = try std.math.add(usize, payload_total, payload_length);
            if (block.cumulative_bytes == 0 and block.cumulative_passes == 0) continue;
            if (payload_length != block.cumulative_bytes) return CodestreamError.InvalidCodestream;
            if (!block.metadata_ready or block.rect.width == 0 or block.rect.height == 0) {
                return CodestreamError.InvalidCodestream;
            }
            if (block.encoded_bitplanes > block.nominal_bitplanes) return CodestreamError.InvalidCodestream;
            stats.blocks += 1;
            stats.bytes = try std.math.add(u64, stats.bytes, block.cumulative_bytes);
            stats.passes = try std.math.add(u64, stats.passes, block.cumulative_passes);
            stats.t1_ready_blocks += 1;
        }

        catalog.components[component] = try allocator.alloc(StrictPacketBlock, assembly.blocks.len);
        catalog.payloads[component] = if (assembly.use_component_payloads)
            try assembly.payloads.toOwnedSlice(allocator)
        else if (payload_total > 0)
            try allocator.alloc(u8, payload_total)
        else
            &.{};

        var payload_offset: usize = 0;
        if (assembly.use_component_payloads) {
            if (catalog.payloads[component].len != payload_total) return CodestreamError.InvalidCodestream;
        }
        for (assembly.blocks, catalog.components[component]) |source, *dest| {
            const payload_length = strictAssemblyBlockPayloadLength(assembly.*, source);
            const source_payload_offset = if (assembly.use_component_payloads) source.payload_offset else payload_offset;
            if (assembly.use_component_payloads) {
                const source_payload_end = try std.math.add(usize, source_payload_offset, payload_length);
                if (source_payload_end > catalog.payloads[component].len) return CodestreamError.InvalidCodestream;
            }
            if (!assembly.use_component_payloads and payload_length > 0) {
                @memcpy(catalog.payloads[component][payload_offset..][0..payload_length], source.payload.items);
            }
            dest.* = .{
                .metadata_ready = source.metadata_ready,
                .band_index = source.band_index,
                .rect = source.rect,
                .nominal_bitplanes = source.nominal_bitplanes,
                .encoded_bitplanes = source.encoded_bitplanes,
                .code_block_style = source.code_block_style,
                .cumulative_passes = source.cumulative_passes,
                .cumulative_bytes = source.cumulative_bytes,
                .payload_offset = source_payload_offset,
                .payload_length = payload_length,
                .segment_count = source.segment_count,
                .segment_lengths = source.segment_lengths,
            };
            if (!assembly.use_component_payloads) payload_offset += payload_length;
        }
        if (!assembly.use_component_payloads and payload_offset != payload_total) return CodestreamError.InvalidCodestream;
    }

    return .{
        .catalog = catalog,
        .stats = stats,
    };
}

fn deinitStrictPacketAuditBandGroups(
    allocator: std.mem.Allocator,
    groups: []StrictPacketAuditBandGroup,
) void {
    for (groups) |*group| group.deinit(allocator);
}

fn buildStrictPacketAuditBandGroups(
    allocator: std.mem.Allocator,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    selected: []const usize,
    header: TemporaryHeader,
    component: usize,
    groups: *[max_rpcl_packet_band_groups]StrictPacketAuditBandGroup,
) !usize {
    var group_count: usize = 0;
    errdefer deinitStrictPacketAuditBandGroups(allocator, groups[0..group_count]);
    var cursor: usize = 0;
    while (cursor < selected.len) {
        const first_source = selected[cursor];
        if (first_source >= blocks.len) return CodestreamError.InvalidCodestream;
        const band_index = blocks[first_source].band_index;
        if (band_index >= bands.len) return CodestreamError.InvalidCodestream;

        var end = cursor + 1;
        while (end < selected.len and blocks[selected[end]].band_index == band_index) : (end += 1) {
            if (selected[end] >= blocks.len) return CodestreamError.InvalidCodestream;
        }

        if (group_count == max_rpcl_packet_band_groups) return CodestreamError.InvalidCodestream;
        groups[group_count] = try buildStrictPacketAuditBandGroup(
            allocator,
            bands[band_index],
            blocks,
            selected[cursor..end],
            band_index,
            dwtLevelsFromBands(bands),
            header,
            component,
        );
        group_count += 1;
        cursor = end;
    }

    return group_count;
}

fn buildStrictPacketAuditBandGroup(
    allocator: std.mem.Allocator,
    band: subband.Band,
    blocks: []const subband.CodeBlock,
    selected: []const usize,
    band_index: usize,
    levels: u8,
    header: TemporaryHeader,
    component: usize,
) !StrictPacketAuditBandGroup {
    if (selected.len == 0) return CodestreamError.InvalidCodestream;
    const grid = try t2.CodeBlockGrid.initAnchored(
        band.rect.x,
        band.rect.y,
        band.rect.width,
        band.rect.height,
        header.block_width,
        header.block_height,
        @as(usize, band.origin_x) % header.block_width,
        @as(usize, band.origin_y) % header.block_height,
    );

    var min_x: usize = std.math.maxInt(usize);
    var min_y: usize = std.math.maxInt(usize);
    var max_x: usize = 0;
    var max_y: usize = 0;
    for (selected) |source_index| {
        if (source_index >= blocks.len) return CodestreamError.InvalidCodestream;
        const block = blocks[source_index];
        if (block.band_index != band_index) return CodestreamError.InvalidCodestream;
        const location = try grid.locationForRect(.{
            .x = block.rect.x,
            .y = block.rect.y,
            .width = block.rect.width,
            .height = block.rect.height,
        });
        min_x = @min(min_x, location.leaf_x);
        min_y = @min(min_y, location.leaf_y);
        max_x = @max(max_x, location.leaf_x);
        max_y = @max(max_y, location.leaf_y);
    }

    const leaves_x = max_x - min_x + 1;
    const leaves_y = max_y - min_y + 1;
    const leaf_count = try std.math.mul(usize, leaves_x, leaves_y);
    if (leaf_count != selected.len) return CodestreamError.InvalidCodestream;

    const source_indexes = try allocator.alloc(usize, leaf_count);
    errdefer allocator.free(source_indexes);
    @memset(source_indexes, missing_packet_source_index);
    const locations = try allocator.alloc(t2.PacketBlockLocation, leaf_count);
    errdefer allocator.free(locations);

    for (selected) |source_index| {
        const block = blocks[source_index];
        const location = try grid.locationForRect(.{
            .x = block.rect.x,
            .y = block.rect.y,
            .width = block.rect.width,
            .height = block.rect.height,
        });
        try fillPacketBandGroupSlot(source_indexes, locations, source_index, location, min_x, min_y, leaves_x, leaves_y);
    }
    try validatePacketBandGroupFilled(source_indexes);

    var reader_state = try t2.PrecinctPacketReaderState.initWithLayerCount(allocator, leaves_x, leaves_y, leaf_count, header.layers);
    errdefer reader_state.deinit();
    reader_state.bypass = header.code_block_style.bypass;
    reader_state.terminate_all = header.code_block_style.terminate_all;
    const decoded = try allocator.alloc(t2.DecodedPacketBlock, leaf_count);
    errdefer allocator.free(decoded);

    return .{
        .source_indexes = source_indexes,
        .locations = locations,
        .reader_state = reader_state,
        .decoded = decoded,
        .max_zero_bitplanes = try bandNominalBitplanesForHeader(header, component, band.kind, band.level, levels),
    };
}

fn buildRpclPacketReaderBandGroups(
    allocator: std.mem.Allocator,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    block_width: u16,
    block_height: u16,
    catalog: []const TemporaryRpclBlock,
    selected: []const usize,
    layer_count: u16,
) ![]RpclPacketReaderBandGroup {
    var groups: std.ArrayList(RpclPacketReaderBandGroup) = .empty;
    errdefer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }
    try groups.ensureTotalCapacity(allocator, max_rpcl_packet_band_groups);

    var cursor: usize = 0;
    while (cursor < selected.len) {
        const first_source = selected[cursor];
        if (first_source >= blocks.len or first_source >= catalog.len) return CodestreamError.InvalidCodestream;
        const band_index = blocks[first_source].band_index;
        if (band_index >= bands.len) return CodestreamError.InvalidCodestream;

        var end = cursor + 1;
        while (end < selected.len and blocks[selected[end]].band_index == band_index) : (end += 1) {
            if (selected[end] >= blocks.len or selected[end] >= catalog.len) return CodestreamError.InvalidCodestream;
        }

        if (groups.items.len == max_rpcl_packet_band_groups) return CodestreamError.InvalidCodestream;
        try groups.append(allocator, try buildRpclPacketReaderBandGroup(
            allocator,
            bands[band_index],
            blocks,
            block_width,
            block_height,
            catalog,
            selected[cursor..end],
            band_index,
            layer_count,
        ));
        cursor = end;
    }

    return groups.toOwnedSlice(allocator);
}

fn buildRpclPacketReaderBandGroup(
    allocator: std.mem.Allocator,
    band: subband.Band,
    blocks: []const subband.CodeBlock,
    block_width: u16,
    block_height: u16,
    catalog: []const TemporaryRpclBlock,
    selected: []const usize,
    band_index: usize,
    layer_count: u16,
) !RpclPacketReaderBandGroup {
    if (selected.len == 0) return CodestreamError.InvalidCodestream;
    const grid = try t2.CodeBlockGrid.init(
        band.rect.x,
        band.rect.y,
        band.rect.width,
        band.rect.height,
        block_width,
        block_height,
    );

    var min_x: usize = std.math.maxInt(usize);
    var min_y: usize = std.math.maxInt(usize);
    var max_x: usize = 0;
    var max_y: usize = 0;
    for (selected) |source_index| {
        if (source_index >= blocks.len or source_index >= catalog.len) return CodestreamError.InvalidCodestream;
        const block = blocks[source_index];
        if (block.band_index != band_index) return CodestreamError.InvalidCodestream;
        const location = try grid.locationForRect(.{
            .x = block.rect.x,
            .y = block.rect.y,
            .width = block.rect.width,
            .height = block.rect.height,
        });
        min_x = @min(min_x, location.leaf_x);
        min_y = @min(min_y, location.leaf_y);
        max_x = @max(max_x, location.leaf_x);
        max_y = @max(max_y, location.leaf_y);
    }

    const leaves_x = max_x - min_x + 1;
    const leaves_y = max_y - min_y + 1;
    const leaf_count = try std.math.mul(usize, leaves_x, leaves_y);
    if (leaf_count != selected.len) return CodestreamError.InvalidCodestream;

    const source_indexes = try allocator.alloc(usize, leaf_count);
    errdefer allocator.free(source_indexes);
    @memset(source_indexes, missing_packet_source_index);
    const locations = try allocator.alloc(t2.PacketBlockLocation, leaf_count);
    errdefer allocator.free(locations);

    for (selected) |source_index| {
        const block = blocks[source_index];
        const location = try grid.locationForRect(.{
            .x = block.rect.x,
            .y = block.rect.y,
            .width = block.rect.width,
            .height = block.rect.height,
        });
        try fillPacketBandGroupSlot(source_indexes, locations, source_index, location, min_x, min_y, leaves_x, leaves_y);
    }
    try validatePacketBandGroupFilled(source_indexes);

    var reader_state = try t2.PrecinctPacketReaderState.initWithLayerCount(allocator, leaves_x, leaves_y, leaf_count, layer_count);
    errdefer reader_state.deinit();
    const decoded = try allocator.alloc(t2.DecodedPacketBlock, leaf_count);
    errdefer allocator.free(decoded);
    const payloads = try allocator.alloc(?[]const u8, leaf_count);
    errdefer allocator.free(payloads);

    return .{
        .band_index = band_index,
        .source_indexes = source_indexes,
        .locations = locations,
        .reader_state = reader_state,
        .decoded = decoded,
        .payloads = payloads,
        .max_zero_bitplanes = maxZeroBitplanes(catalog, source_indexes),
    };
}

fn fillPacketBandGroupSlot(
    source_indexes: []usize,
    locations: []t2.PacketBlockLocation,
    source_index: usize,
    location: t2.PacketBlockLocation,
    min_x: usize,
    min_y: usize,
    leaves_x: usize,
    leaves_y: usize,
) !void {
    if (source_indexes.len != locations.len) return CodestreamError.InvalidCodestream;
    if (location.leaf_x < min_x or location.leaf_y < min_y) return CodestreamError.InvalidCodestream;
    const local_x = location.leaf_x - min_x;
    const local_y = location.leaf_y - min_y;
    if (local_x >= leaves_x or local_y >= leaves_y) return CodestreamError.InvalidCodestream;
    const row_offset = try std.math.mul(usize, local_y, leaves_x);
    const local_index = try std.math.add(usize, row_offset, local_x);
    if (local_index >= source_indexes.len or source_indexes[local_index] != missing_packet_source_index) {
        return CodestreamError.InvalidCodestream;
    }
    source_indexes[local_index] = source_index;
    locations[local_index] = .{ .leaf_x = local_x, .leaf_y = local_y };
}

fn validatePacketBandGroupFilled(source_indexes: []const usize) !void {
    for (source_indexes) |source_index| {
        if (source_index == missing_packet_source_index) return CodestreamError.InvalidCodestream;
    }
}

fn readRpclPacketForBandGroups(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    packet: packet_plan.Packet,
    expected_resolution: u8,
    expected_component: u16,
    expected_precinct: u64,
    catalog: []const TemporaryRpclBlock,
    groups: []RpclPacketReaderBandGroup,
) !t2.ReadPacket {
    _ = allocator;
    if (packet.resolution != expected_resolution or
        packet.component != expected_component or
        packet.precinct_index != expected_precinct)
    {
        return CodestreamError.InvalidCodestream;
    }

    var reader = t2.PacketHeaderReader.init(bytes);
    const packet_included = try reader.readBit();
    if (packet_included) {
        for (groups) |*group| {
            try t2.readPrecinctPacketHeaderBody(
                &reader,
                &group.reader_state.inclusion,
                &group.reader_state.zero_bitplanes,
                group.reader_state.states,
                packet.layer,
                group.locations,
                group.max_zero_bitplanes,
                group.reader_state.bypass,
                group.reader_state.terminate_all,
                group.decoded,
            );
        }
    } else {
        for (groups) |*group| {
            for (group.decoded) |*decoded| {
                decoded.* = .{
                    .included = false,
                    .first_inclusion = false,
                    .zero_bitplanes = 0,
                    .pass_count = 0,
                    .byte_length = 0,
                };
            }
        }
    }
    try reader.byteAlign();

    const payload_offset = reader.bytesConsumed();
    var cursor = payload_offset;
    var payload_length: usize = 0;
    var included_blocks: usize = 0;
    for (groups) |*group| {
        for (group.decoded, group.payloads) |decoded, *payload| {
            payload.* = null;
            if (!decoded.included) continue;
            const byte_length = std.math.cast(usize, decoded.byte_length) orelse return CodestreamError.InvalidCodestream;
            const end = try std.math.add(usize, cursor, byte_length);
            if (end > bytes.len) return CodestreamError.TruncatedData;
            payload.* = bytes[cursor..end];
            cursor = end;
            payload_length += byte_length;
            included_blocks += 1;
        }
        try validateDecodedRpclPacketBlocks(catalog, group.source_indexes, @intCast(packet.layer), group.decoded, group.payloads);
    }
    if (cursor != bytes.len) return CodestreamError.InvalidCodestream;

    return .{
        .header_length = payload_offset,
        .payload_offset = payload_offset,
        .payload_length = payload_length,
        .packet_length = cursor,
        .included_blocks = included_blocks,
    };
}

fn collectStrictRpclPacketBlocks(
    assembly: *StrictComponentAssembly,
    groups: []const RpclPacketReaderBandGroup,
) !void {
    for (groups) |group| {
        if (group.source_indexes.len != group.decoded.len or group.source_indexes.len != group.payloads.len) {
            return CodestreamError.InvalidCodestream;
        }
        for (group.source_indexes, 0..) |block_index, index| {
            if (block_index >= assembly.blocks.len) return CodestreamError.InvalidCodestream;
            const decoded = group.decoded[index];
            if (!decoded.included) {
                if (group.payloads[index] != null) return CodestreamError.InvalidCodestream;
                continue;
            }

            const payload = group.payloads[index] orelse return CodestreamError.InvalidCodestream;
            if (payload.len != decoded.byte_length) return CodestreamError.InvalidCodestream;
            var block = &assembly.blocks[block_index];
            block.cumulative_passes = std.math.add(u16, block.cumulative_passes, decoded.pass_count) catch return CodestreamError.InvalidCodestream;
            block.cumulative_bytes = try std.math.add(u64, block.cumulative_bytes, decoded.byte_length);
            try block.appendSegmentLengths(decoded);
            try block.payload.appendSlice(assembly.allocator, payload);
            if (block.payload.items.len != block.cumulative_bytes) return CodestreamError.InvalidCodestream;
        }
    }
}

fn validateStrictComponentAssembly(
    catalog: []const TemporaryRpclBlock,
    assembly: StrictComponentAssembly,
    layer_count: u16,
) !void {
    if (catalog.len != assembly.blocks.len) return CodestreamError.InvalidCodestream;
    if (layer_count == 0 or layer_count > max_quality_layers) return CodestreamError.InvalidCodestream;
    const final_layer: usize = @intCast(layer_count - 1);
    for (catalog, assembly.blocks) |expected, actual| {
        const final = expected.layers[final_layer];
        if (actual.cumulative_passes != final.cumulative_passes) return CodestreamError.InvalidCodestream;
        if (actual.cumulative_bytes != final.cumulative_bytes) return CodestreamError.InvalidCodestream;
        const expected_len = std.math.cast(usize, final.cumulative_bytes) orelse return CodestreamError.InvalidCodestream;
        if (expected_len > expected.payload.len) return CodestreamError.InvalidCodestream;
        if (!std.mem.eql(u8, expected.payload[0..expected_len], actual.payload.items)) {
            return CodestreamError.InvalidCodestream;
        }
    }
}

fn validateTemporaryCatalogsMatchCodeBlocks(
    catalogs: [3]TemporaryComponentRpclCatalog,
    blocks: []const subband.CodeBlock,
) !void {
    inline for (0..3) |component| {
        try validateTemporaryCatalogMatchesCodeBlocks(catalogs[component].blocks, blocks);
    }
}

fn validateTemporaryCatalogMatchesCodeBlocks(
    catalog: []const TemporaryRpclBlock,
    blocks: []const subband.CodeBlock,
) !void {
    if (catalog.len != blocks.len) return CodestreamError.InvalidCodestream;
    for (catalog, blocks) |entry, block| {
        if (entry.band_index != block.band_index or !rectsEqual(entry.rect, block.rect)) {
            return CodestreamError.InvalidCodestream;
        }
    }
}

fn rectsEqual(a: subband.Rect, b: subband.Rect) bool {
    return a.x == b.x and
        a.y == b.y and
        a.width == b.width and
        a.height == b.height;
}

fn validateStrictDecodedBlock(
    expected: TemporaryRpclBlock,
    decoded: []const i32,
) !void {
    if (@as(u64, @intCast(decoded.len)) != rectArea(expected.rect)) return CodestreamError.InvalidCodestream;
}

fn reconstructStrictComponentCoefficientPlanes(
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    catalogs: [3]TemporaryComponentRpclCatalog,
    assemblies: [3]StrictComponentAssembly,
    options: DecodeOptions,
) !color.RctPlanes {
    const plane_slices = try allocator.alloc([]i32, 3);
    var reconstructed: usize = 0;
    errdefer {
        for (plane_slices[0..reconstructed]) |plane_slice| allocator.free(plane_slice);
        allocator.free(plane_slices);
    }
    while (reconstructed < 3) : (reconstructed += 1) {
        plane_slices[reconstructed] = try reconstructStrictComponentCoefficients(
            allocator,
            header.width,
            header.height,
            catalogs[reconstructed].blocks,
            assemblies[reconstructed],
            header.layers,
            options,
        );
    }

    return .{
        .allocator = allocator,
        .width = header.width,
        .height = header.height,
        .bit_depth = header.bit_depth,
        .planes = plane_slices,
    };
}

fn strictAssembliesComplete(
    catalogs: [3]TemporaryComponentRpclCatalog,
    assemblies: [3]StrictComponentAssembly,
) bool {
    inline for (0..3) |component| {
        if (catalogs[component].blocks.len != assemblies[component].blocks.len) return false;
        for (catalogs[component].blocks, assemblies[component].blocks) |expected, actual| {
            if (actual.cumulative_passes != expected.passes.len) return false;
            if (actual.cumulative_bytes != expected.payload.len) return false;
        }
    }
    return true;
}

fn validateRgbImagesEqual(expected: image.RgbImage, actual: image.RgbImage) !void {
    if (expected.width != actual.width or
        expected.height != actual.height or
        expected.bit_depth != actual.bit_depth or
        !std.mem.eql(u16, expected.samples, actual.samples))
    {
        return CodestreamError.InvalidCodestream;
    }
}

fn decodeStrictRpclImageFromBlockCatalog(
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    catalog: StrictPacketBlockCatalog,
    options: DecodeOptions,
) !image.RgbImage {
    return decodeStrictRpclImageFromBlockCatalogMeasured(allocator, header, catalog, options, null);
}

fn decodeStrictRpclImageFromBlockCatalogMeasured(
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    catalog: StrictPacketBlockCatalog,
    options: DecodeOptions,
    timings: ?*DecodeTimings,
) !image.RgbImage {
    const payload_start = monotonicNs();
    var strict_planes = try reconstructStrictComponentCoefficientPlanesFromBlockCatalog(allocator, header, catalog, options, timings);
    defer strict_planes.deinit();
    if (timings) |t| t.block_payload_ns += elapsedNs(payload_start);

    if (header.transform == .irreversible_9_7) {
        return decodeIrreversibleImageFromQuantizedPlanesMeasured(
            allocator,
            header,
            strict_planes,
            options.threads,
            timings,
        );
    }

    const wavelet_start = monotonicNs();
    const plan = temporaryPacketPlan(header);
    if (plan.resolution_count == 0) return CodestreamError.InvalidCodestream;
    const full_resolution = plan.resolutions[plan.resolution_count - 1];
    try inverseComponents53(
        allocator,
        .{ .slices = .{ strict_planes.planes[0], strict_planes.planes[1], strict_planes.planes[2] } },
        header.width,
        header.height,
        header.levels,
        full_resolution.x0,
        full_resolution.y0,
        options,
    );
    if (timings) |t| t.wavelet_ns += elapsedNs(wavelet_start);

    const color_start = monotonicNs();
    defer {
        if (timings) |t| t.color_transform_ns += elapsedNs(color_start);
    }
    return if (header.mct == .none)
        color.inverseNoTransform(allocator, strict_planes)
    else
        color.inverseRctThreaded(allocator, strict_planes, options.threads);
}

/// Builds a per-tile packet catalog from one Stage B tile-part span: the
/// tile's PLT packet lengths drive the tile-local packet iterator, and each
/// framed packet (SOP/EPH per the COD policy, Nsop restarting at 0 for the
/// tile) is stripped into the catalog's raw packet bytes.
fn readStrictMultiTileTilePartPacketCatalog(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    span: StrictMultiTileTilePartSpan,
    tile_plan: packet_plan.Plan,
    tile_header: TemporaryHeader,
    layers: u16,
    progression: ProgressionOrder,
    poc_records: ?[]const poc.Record,
    marker_policy: MainHeaderPacketMarkers,
    expected_ppt_index: *u16,
    stateful: *StrictStatefulPrecinctGroups,
    external_packed_headers: ?[]const u8,
) !StrictPacketCatalog {
    var entries: std.ArrayList(StrictPacketEntry) = .empty;
    errdefer entries.deinit(allocator);
    const packet_capacity = span.packet_count;
    try entries.ensureTotalCapacity(allocator, packet_capacity);
    var packet_bytes: std.ArrayList(u8) = .empty;
    errdefer packet_bytes.deinit(allocator);
    try packet_bytes.ensureTotalCapacity(allocator, span.packet_payload_bytes);

    var packet_lengths: std.ArrayList(usize) = .empty;
    defer packet_lengths.deinit(allocator);
    var packed_headers: std.ArrayList(u8) = .empty;
    defer packed_headers.deinit(allocator);
    const sod = try readTilePartHeaderMarkers(
        allocator,
        bytes,
        span.sot_start + 12,
        span.end,
        &packet_lengths,
        &packed_headers,
        expected_ppt_index,
        null,
    );
    if (sod != span.sod) return CodestreamError.InvalidCodestream;
    if (external_packed_headers) |headers| {
        if (packed_headers.items.len != 0 or headers.len == 0) return CodestreamError.InvalidCodestream;
        try packed_headers.appendSlice(allocator, headers);
    }
    if (span.missing_plt) {
        if (packet_lengths.items.len != 0) return CodestreamError.InvalidCodestream;
    } else if (packet_lengths.items.len != packet_capacity) return CodestreamError.InvalidCodestream;

    const sampled_components = headerHasComponentSubsampling(tile_header);
    if (sampled_components and
        (progression != .rpcl or external_packed_headers != null))
    {
        return CodestreamError.UnsupportedPayload;
    }
    const full_sequence = if (sampled_components)
        try buildSampledStrictPacketSequence(
            allocator,
            tile_plan,
            tile_header.component_count,
            layers,
            tile_header.component_xrsiz,
            tile_header.component_yrsiz,
            poc_records,
            &.{},
        )
    else if (poc_records) |records|
        poc.buildSequence(allocator, tile_plan, tile_header.component_count, layers, records) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return CodestreamError.InvalidCodestream,
        }
    else
        try buildStreamPacketSequence(allocator, progression, tile_plan, tile_header.component_count, layers);
    defer allocator.free(full_sequence);
    const sequence_end = try std.math.add(usize, span.first_packet, packet_capacity);
    if (sequence_end > full_sequence.len) return CodestreamError.InvalidCodestream;
    const sequence = full_sequence[span.first_packet..sequence_end];

    var cursor = span.sod + 2;
    var packet_sequence: u16 = @truncate(span.first_packet);
    if (span.missing_plt) {
        if (packed_headers.items.len != 0) {
            var packed_header_cursor: usize = 0;
            for (sequence) |packet| {
                const groups = try stateful.groupsFor(packet);
                const byte_offset = packet_bytes.items.len;
                const byte_length = try appendStrictPackedPacketPayload(
                    allocator,
                    &packet_bytes,
                    bytes,
                    &cursor,
                    span.end,
                    null,
                    packed_headers.items,
                    &packed_header_cursor,
                    packet,
                    groups,
                    marker_policy,
                    &packet_sequence,
                );
                try entries.append(allocator, .{
                    .packet = packet,
                    .tile_index = span.tile_index,
                    .tile_part_index = span.tile_part_index,
                    .byte_offset = byte_offset,
                    .byte_length = byte_length,
                });
            }
            if (packed_header_cursor != packed_headers.items.len) return CodestreamError.InvalidCodestream;
        } else {
            for (sequence) |packet| {
                var packet_start = cursor;
                if (marker_policy.sop) {
                    if (span.end - packet_start < 6) return CodestreamError.TruncatedData;
                    if (readU16Be(bytes, packet_start) != @intFromEnum(Marker.sop)) return CodestreamError.InvalidCodestream;
                    if (readU16Be(bytes, packet_start + 2) != 4) return CodestreamError.InvalidCodestream;
                    if (readU16Be(bytes, packet_start + 4) != packet_sequence) return CodestreamError.InvalidCodestream;
                    packet_sequence +%= 1;
                    packet_start += 6;
                }

                const groups = try stateful.groupsFor(packet);
                const packet_span = try readStrictPacketHeaderSpan(bytes[packet_start..span.end], packet, groups);
                const header_end = try std.math.add(usize, packet_start, packet_span.header_length);
                var body_start = header_end;
                if (marker_policy.eph) {
                    if (span.end - body_start < 2) return CodestreamError.TruncatedData;
                    if (readU16Be(bytes, body_start) != @intFromEnum(Marker.eph)) return CodestreamError.InvalidCodestream;
                    body_start += 2;
                }
                const packet_end = try std.math.add(usize, body_start, packet_span.payload_length);
                if (packet_end > span.end) return CodestreamError.TruncatedData;

                const byte_offset = packet_bytes.items.len;
                try packet_bytes.appendSlice(allocator, bytes[packet_start..header_end]);
                try packet_bytes.appendSlice(allocator, bytes[body_start..packet_end]);
                const byte_length = std.math.cast(u32, packet_span.header_length + packet_span.payload_length) orelse return CodestreamError.InvalidCodestream;
                try entries.append(allocator, .{
                    .packet = packet,
                    .tile_index = span.tile_index,
                    .tile_part_index = span.tile_part_index,
                    .byte_offset = byte_offset,
                    .byte_length = byte_length,
                });
                cursor = packet_end;
            }
        }
    } else {
        var packed_header_cursor: usize = 0;
        for (packet_lengths.items, sequence) |packet_length, packet| {
            const byte_offset = packet_bytes.items.len;
            const byte_length = if (packed_headers.items.len != 0) blk: {
                const groups = try stateful.groupsFor(packet);
                break :blk try appendStrictPackedPacketPayload(
                    allocator,
                    &packet_bytes,
                    bytes,
                    &cursor,
                    span.end,
                    packet_length,
                    packed_headers.items,
                    &packed_header_cursor,
                    packet,
                    groups,
                    marker_policy,
                    &packet_sequence,
                );
            } else try appendStrictSodPacketPayload(
                allocator,
                &packet_bytes,
                bytes,
                &cursor,
                span.end,
                packet_length,
                marker_policy,
                &packet_sequence,
            );
            try entries.append(allocator, .{
                .packet = packet,
                .tile_index = span.tile_index,
                .tile_part_index = span.tile_part_index,
                .byte_offset = byte_offset,
                .byte_length = byte_length,
            });
        }
        if (packed_header_cursor != packed_headers.items.len) return CodestreamError.InvalidCodestream;
    }
    if (cursor != span.end) return CodestreamError.InvalidCodestream;

    const owned_entries = try entries.toOwnedSlice(allocator);
    errdefer allocator.free(owned_entries);
    if (!sampled_components and (progression != .rpcl or poc_records != null) and span.tile_part_count == 1) {
        try reorderStrictEntriesToRpcl(allocator, owned_entries, tile_plan, tile_header.component_count, layers);
    }
    const owned_packet_bytes = try packet_bytes.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .entries = owned_entries,
        .packet_bytes = owned_packet_bytes,
    };
}

fn readStrictMultiTilePacketCatalogForTile(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    spans: []const StrictMultiTileTilePartSpan,
    tile_index: u16,
    tile_header: TemporaryHeader,
    tile_plan: packet_plan.Plan,
    layers: u16,
    progression: ProgressionOrder,
    poc_records: ?[]const poc.Record,
    marker_policy: MainHeaderPacketMarkers,
    ppm_headers: ?ppm.PackedHeaders,
) !StrictPacketCatalog {
    var entries: std.ArrayList(StrictPacketEntry) = .empty;
    errdefer entries.deinit(allocator);
    var packet_bytes: std.ArrayList(u8) = .empty;
    errdefer packet_bytes.deinit(allocator);

    var expected_first_packet: usize = 0;
    var part_count: usize = 0;
    var expected_ppt_index: u16 = 0;
    var stateful = try StrictStatefulPrecinctGroups.init(allocator, tile_header);
    defer stateful.deinit();
    for (spans) |span| {
        if (span.tile_index != tile_index) continue;
        if (span.first_packet != expected_first_packet) return CodestreamError.InvalidCodestream;
        const external_headers = if (ppm_headers) |headers|
            try strictPpmGroupAt(headers, span.stream_index)
        else
            null;
        var part = try readStrictMultiTileTilePartPacketCatalog(
            allocator,
            bytes,
            span,
            tile_plan,
            tile_header,
            layers,
            progression,
            poc_records,
            marker_policy,
            &expected_ppt_index,
            &stateful,
            external_headers,
        );
        defer part.deinit();

        const byte_base = packet_bytes.items.len;
        try packet_bytes.appendSlice(allocator, part.packet_bytes);
        for (part.entries) |entry| {
            var joined = entry;
            joined.byte_offset = try std.math.add(usize, byte_base, entry.byte_offset);
            try entries.append(allocator, joined);
        }
        expected_first_packet = try std.math.add(usize, expected_first_packet, span.packet_count);
        part_count += 1;
    }

    if (part_count == 0 or expected_first_packet != tile_plan.packets) {
        return CodestreamError.InvalidCodestream;
    }
    const owned_entries = try entries.toOwnedSlice(allocator);
    errdefer allocator.free(owned_entries);
    // Single-part tiles were already reordered per part; multi-part tiles
    // join their parts in stream (progression) order first, so non-RPCL
    // sequences reorder here once the whole tile is assembled.
    if (!headerHasComponentSubsampling(tile_header) and
        (progression != .rpcl or poc_records != null) and part_count > 1)
    {
        try reorderStrictEntriesToRpcl(allocator, owned_entries, tile_plan, tile_header.component_count, layers);
    }
    const owned_packet_bytes = try packet_bytes.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .entries = owned_entries,
        .packet_bytes = owned_packet_bytes,
    };
}

/// Shared setup for the multi-tile strict stages: the SIZ grid, the decode
/// options reconstructed from the whole-image plan (precinct dims per
/// resolution are geometry independent), the main-header index (packet
/// marker policy + TLM), and the validated Stage B tile-part spans.
const StrictMultiTileContext = struct {
    allocator: std.mem.Allocator,
    grid: tile_grid.Grid,
    plan_options: LosslessOptions,
    main_header: StrictMainHeaderIndex,
    spans: std.ArrayList(StrictMultiTileTilePartSpan),
    tile_poc_records: []std.ArrayList(poc.Record),

    fn deinit(self: *StrictMultiTileContext) void {
        self.spans.deinit(self.allocator);
        for (self.tile_poc_records) |*records| records.deinit(self.allocator);
        self.allocator.free(self.tile_poc_records);
        self.main_header.deinit();
        self.* = undefined;
    }

    fn appendEffectivePocRecords(
        self: StrictMultiTileContext,
        allocator: std.mem.Allocator,
        tile_index: usize,
        records: *std.ArrayList(poc.Record),
    ) !?[]const poc.Record {
        if (tile_index >= self.tile_poc_records.len) return CodestreamError.InvalidCodestream;
        if (self.main_header.poc_records) |main| try records.appendSlice(allocator, main);
        try records.appendSlice(allocator, self.tile_poc_records[tile_index].items);
        return if (records.items.len == 0) null else records.items;
    }

    /// The per-tile header view that lets the unchanged single-tile strict
    /// chain decode one tile: tile dims plus the tile's own packet plan.
    fn tileHeader(self: StrictMultiTileContext, header: TemporaryHeader, tile: tile_grid.Tile) !TemporaryHeader {
        const tile_width = @as(usize, tile.rect.width());
        const tile_height = @as(usize, tile.rect.height());
        const tile_plan = try makeAggregatePacketPlanForTile(
            tile,
            header.levels,
            header.component_count,
            self.plan_options,
            header.component_xrsiz,
            header.component_yrsiz,
        );
        var tile_header = header;
        tile_header.width = tile_width;
        tile_header.height = tile_height;
        tile_header.tile_width = 0;
        tile_header.tile_height = 0;
        tile_header.tile_part_divisions = null;
        tile_header.tile_part_plan_count = 0;
        tile_header.tile_part_plan = [_]u8{0} ** 33;
        tile_header.packet_plan_count = tile_plan.resolution_count;
        tile_header.packet_plan = tile_plan.resolutions;
        tile_header.packet_count = tile_plan.packets;
        return tile_header;
    }
};

fn readStrictMultiTileContext(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: TemporaryHeader,
) !StrictMultiTileContext {
    const image_width = std.math.cast(u32, header.width) orelse return CodestreamError.InvalidCodestream;
    const image_height = std.math.cast(u32, header.height) orelse return CodestreamError.InvalidCodestream;
    const xsiz = std.math.add(u32, header.reference_x0, image_width) catch return CodestreamError.InvalidCodestream;
    const ysiz = std.math.add(u32, header.reference_y0, image_height) catch return CodestreamError.InvalidCodestream;
    const grid = tile_grid.Grid.init(.{
        .xsiz = xsiz,
        .ysiz = ysiz,
        .xosiz = header.reference_x0,
        .yosiz = header.reference_y0,
        .xtsiz = header.tile_width,
        .ytsiz = header.tile_height,
        .xtosiz = header.reference_x0,
        .ytosiz = header.reference_y0,
    }) catch return CodestreamError.InvalidCodestream;
    if (grid.isSingleTile()) return CodestreamError.InvalidCodestream;
    if (header.packet_plan_count == 0) return CodestreamError.InvalidCodestream;

    var precincts = defaultPrecincts();
    for (header.packet_plan[0..header.packet_plan_count], 0..) |resolution, index| {
        const precinct_width = std.math.cast(u16, resolution.precinct_width) orelse return CodestreamError.InvalidCodestream;
        const precinct_height = std.math.cast(u16, resolution.precinct_height) orelse return CodestreamError.InvalidCodestream;
        precincts[index] = .{ .width = precinct_width, .height = precinct_height };
    }
    const plan_options = LosslessOptions{
        .levels = header.levels,
        .layers = header.layers,
        .block_width = header.block_width,
        .block_height = header.block_height,
        .precincts = precincts,
        .precinct_count = header.packet_plan_count,
        .progression = header.progression,
    };

    var main_header = try readStrictMainHeaderIndex(allocator, bytes, header.component_count);
    errdefer main_header.deinit();

    const tile_count = std.math.cast(usize, grid.tileCount()) orelse return CodestreamError.UnsupportedPayload;
    const tile_poc_records = try allocator.alloc(std.ArrayList(poc.Record), tile_count);
    for (tile_poc_records) |*records| records.* = .empty;
    errdefer {
        for (tile_poc_records) |*records| records.deinit(allocator);
        allocator.free(tile_poc_records);
    }

    const spans = try readStrictMultiTileTilePartSpans(
        allocator,
        bytes,
        main_header.first_sot,
        grid,
        header.levels,
        plan_options,
        header.component_count,
        header.component_xrsiz,
        header.component_yrsiz,
        if (main_header.tlm_entries) |tlm_slice| tlm_slice else null,
        if (main_header.ppm_headers) |headers| headers else null,
        tile_poc_records,
    );

    return .{
        .allocator = allocator,
        .grid = grid,
        .plan_options = plan_options,
        .main_header = main_header,
        .spans = spans,
        .tile_poc_records = tile_poc_records,
    };
}

fn decodeStrictMultiTilePlanarMeasured(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: TemporaryHeader,
    options: DecodeOptions,
    timings: ?*DecodeTimings,
) !color.SamplePlanes {
    if (header.mct != .none or header.progression != .rpcl or
        header.transform != .reversible_5_3 or header.quantization != .none or
        !headerHasComponentSubsampling(header))
    {
        return CodestreamError.UnsupportedPayload;
    }

    var context = try readStrictMultiTileContext(allocator, bytes, header);
    defer context.deinit();
    if (context.main_header.ppm_headers != null) {
        return CodestreamError.UnsupportedPayload;
    }

    const reference_width = std.math.cast(u32, header.width) orelse return CodestreamError.InvalidCodestream;
    const reference_height = std.math.cast(u32, header.height) orelse return CodestreamError.InvalidCodestream;
    const reference_x1 = std.math.add(u32, header.reference_x0, reference_width) catch return CodestreamError.InvalidCodestream;
    const reference_y1 = std.math.add(u32, header.reference_y0, reference_height) catch return CodestreamError.InvalidCodestream;
    var component_depths = [_]u8{0} ** max_codestream_components;
    var component_widths = [_]usize{0} ** max_codestream_components;
    var component_heights = [_]usize{0} ** max_codestream_components;
    for (0..header.component_count) |component| {
        component_depths[component] = componentBitDepthForHeader(header, component);
        component_widths[component] = ceilDivU32(reference_x1, header.component_xrsiz[component]) -
            ceilDivU32(header.reference_x0, header.component_xrsiz[component]);
        component_heights[component] = ceilDivU32(reference_y1, header.component_yrsiz[component]) -
            ceilDivU32(header.reference_y0, header.component_yrsiz[component]);
    }
    var assembled = try color.SamplePlanes.initWithComponentLayouts(
        allocator,
        header.width,
        header.height,
        component_depths[0..header.component_count],
        component_widths[0..header.component_count],
        component_heights[0..header.component_count],
    );
    errdefer assembled.deinit();

    var tile_index: u32 = 0;
    while (tile_index < context.grid.tileCount()) : (tile_index += 1) {
        const tile = context.grid.tile(tile_index) catch return CodestreamError.InvalidCodestream;
        const tile_header = try context.tileHeader(header, tile);
        const tile_plan = temporaryPacketPlan(tile_header);
        var effective_poc_records: std.ArrayList(poc.Record) = .empty;
        defer effective_poc_records.deinit(allocator);
        const tile_poc_records = try context.appendEffectivePocRecords(
            allocator,
            tile_index,
            &effective_poc_records,
        );

        const catalog_start = monotonicNs();
        var catalog = try readStrictMultiTilePacketCatalogForTile(
            allocator,
            bytes,
            context.spans.items,
            @intCast(tile_index),
            tile_header,
            tile_plan,
            header.layers,
            header.progression,
            tile_poc_records,
            context.main_header.packet_markers,
            null,
        );
        defer catalog.deinit();

        var audit = StrictPacketHeaderAudit{};
        var assemblies = try assembleStrictPacketCatalogHeaders(allocator, tile_header, catalog, &audit);
        defer assemblies.deinit();
        const build = try strictPacketBlockCatalogFromAssembliesChecked(
            allocator,
            assemblies.assemblies[0..assemblies.initialized],
        );
        var block_catalog = build.catalog;
        defer block_catalog.deinit();
        if (build.stats.bytes != audit.payload_bytes) return CodestreamError.InvalidCodestream;
        if (timings) |t| t.packet_catalog_ns += elapsedNs(catalog_start);

        var tile_planes = try decodeStrictPlanarFromBlockCatalogMeasured(
            allocator,
            tile_header,
            block_catalog,
            options,
            timings,
        );
        defer tile_planes.deinit();

        for (0..header.component_count) |component| {
            const xrsiz = header.component_xrsiz[component];
            const yrsiz = header.component_yrsiz[component];
            const component_x0 = ceilDivU32(tile.rect.x0, xrsiz);
            const component_y0 = ceilDivU32(tile.rect.y0, yrsiz);
            const component_x1 = ceilDivU32(tile.rect.x1, xrsiz);
            const component_y1 = ceilDivU32(tile.rect.y1, yrsiz);
            const image_component_x0 = ceilDivU32(header.reference_x0, xrsiz);
            const image_component_y0 = ceilDivU32(header.reference_y0, yrsiz);
            const tile_width = @as(usize, component_x1 - component_x0);
            const tile_height = @as(usize, component_y1 - component_y0);
            if (tile_planes.component_widths[component] != tile_width or
                tile_planes.component_heights[component] != tile_height)
            {
                return CodestreamError.InvalidCodestream;
            }

            const destination_stride = component_widths[component];
            if (component_x0 < image_component_x0 or component_y0 < image_component_y0) {
                return CodestreamError.InvalidCodestream;
            }
            const destination_x = @as(usize, component_x0 - image_component_x0);
            const destination_y = @as(usize, component_y0 - image_component_y0);
            if (destination_x + tile_width > component_widths[component] or
                destination_y + tile_height > component_heights[component])
            {
                return CodestreamError.InvalidCodestream;
            }
            var row: usize = 0;
            while (row < tile_height) : (row += 1) {
                const source_start = row * tile_width;
                const destination_start = (destination_y + row) * destination_stride + destination_x;
                @memcpy(
                    assembled.planes[component][destination_start .. destination_start + tile_width],
                    tile_planes.planes[component][source_start .. source_start + tile_width],
                );
            }
        }
    }
    return assembled;
}

/// Stage C multi-tile decode (docs/multi_tile_plan.md): every tile decodes as
/// its own single-tile image. A per-tile header (tile dims + the tile's own
/// packet plan) drives the unchanged strict chain — packet catalog → T2 header
/// assembly → block catalog → T1 → inverse DWT → inverse MCT — and the tile
/// image is blitted into the assembled output at the tile's grid rect. Tiles
/// decode serially; the existing per-block threading applies within each tile.
fn decodeStrictMultiTileImageMeasured(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: TemporaryHeader,
    options: DecodeOptions,
    timings: ?*DecodeTimings,
) !image.RgbImage {
    var context = try readStrictMultiTileContext(allocator, bytes, header);
    defer context.deinit();

    const pixels = try std.math.mul(usize, header.width, header.height);
    const samples = try allocator.alloc(u16, try std.math.mul(usize, pixels, 3));
    errdefer allocator.free(samples);
    const assembled = image.RgbImage{
        .allocator = allocator,
        .width = header.width,
        .height = header.height,
        .bit_depth = header.bit_depth,
        .samples = samples,
    };

    var tile_index: u32 = 0;
    while (tile_index < context.grid.tileCount()) : (tile_index += 1) {
        const tile = context.grid.tile(tile_index) catch return CodestreamError.InvalidCodestream;
        const tile_header = try context.tileHeader(header, tile);
        const tile_plan = temporaryPacketPlan(tile_header);
        var effective_poc_records: std.ArrayList(poc.Record) = .empty;
        defer effective_poc_records.deinit(allocator);
        const tile_poc_records = try context.appendEffectivePocRecords(
            allocator,
            tile_index,
            &effective_poc_records,
        );

        const catalog_start = monotonicNs();
        var catalog = try readStrictMultiTilePacketCatalogForTile(
            allocator,
            bytes,
            context.spans.items,
            @intCast(tile_index),
            tile_header,
            tile_plan,
            header.layers,
            header.progression,
            tile_poc_records,
            context.main_header.packet_markers,
            if (context.main_header.ppm_headers) |headers| headers else null,
        );
        defer catalog.deinit();

        var audit = StrictPacketHeaderAudit{};
        var assemblies = try assembleStrictPacketCatalogHeaders(allocator, tile_header, catalog, &audit);
        defer assemblies.deinit();
        const build = try strictPacketBlockCatalogFromAssembliesChecked(
            allocator,
            assemblies.assemblies[0..assemblies.initialized],
        );
        var block_catalog = build.catalog;
        defer block_catalog.deinit();
        if (build.stats.bytes != audit.payload_bytes) return CodestreamError.InvalidCodestream;
        if (timings) |t| t.packet_catalog_ns += elapsedNs(catalog_start);

        var tile_image = try decodeStrictRpclImageFromBlockCatalogMeasured(allocator, tile_header, block_catalog, options, timings);
        defer tile_image.deinit();
        if (tile.rect.x0 < header.reference_x0 or tile.rect.y0 < header.reference_y0) {
            return CodestreamError.InvalidCodestream;
        }
        const local_rect = tile_grid.Rect{
            .x0 = tile.rect.x0 - header.reference_x0,
            .y0 = tile.rect.y0 - header.reference_y0,
            .x1 = tile.rect.x1 - header.reference_x0,
            .y1 = tile.rect.y1 - header.reference_y0,
        };
        tile_grid.copyRgbTileInto(assembled, local_rect, tile_image) catch return CodestreamError.InvalidCodestream;
    }

    return assembled;
}

/// Aggregated multi-tile packet/header audit for `jp2 stats`: the per-tile
/// catalogs and audits are summed across tiles.
fn auditStrictMultiTilePacketHeaders(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: TemporaryHeader,
    sod_packets: ?*u64,
    sod_packet_bytes: ?*u64,
) !StrictPacketHeaderAudit {
    var context = try readStrictMultiTileContext(allocator, bytes, header);
    defer context.deinit();

    var total = StrictPacketHeaderAudit{};
    var tile_index: u32 = 0;
    while (tile_index < context.grid.tileCount()) : (tile_index += 1) {
        const tile = context.grid.tile(tile_index) catch return CodestreamError.InvalidCodestream;
        const tile_header = try context.tileHeader(header, tile);
        const tile_plan = temporaryPacketPlan(tile_header);
        var effective_poc_records: std.ArrayList(poc.Record) = .empty;
        defer effective_poc_records.deinit(allocator);
        const tile_poc_records = try context.appendEffectivePocRecords(
            allocator,
            tile_index,
            &effective_poc_records,
        );
        var catalog = try readStrictMultiTilePacketCatalogForTile(
            allocator,
            bytes,
            context.spans.items,
            @intCast(tile_index),
            tile_header,
            tile_plan,
            header.layers,
            header.progression,
            tile_poc_records,
            context.main_header.packet_markers,
            if (context.main_header.ppm_headers) |headers| headers else null,
        );
        defer catalog.deinit();
        if (sod_packets) |out| out.* += @intCast(catalog.entries.len);
        if (sod_packet_bytes) |out| out.* += @intCast(catalog.packet_bytes.len);

        const audit = try auditStrictPacketCatalogHeaders(allocator, tile_header, catalog);
        total.packets += audit.packets;
        total.present_packets += audit.present_packets;
        total.absent_packets += audit.absent_packets;
        total.geometry_empty_packets += audit.geometry_empty_packets;
        total.header_decoded_packets += audit.header_decoded_packets;
        total.header_bytes += audit.header_bytes;
        total.payload_bytes += audit.payload_bytes;
        total.included_blocks += audit.included_blocks;
        total.assembled_blocks += audit.assembled_blocks;
        total.assembled_bytes += audit.assembled_bytes;
        total.assembled_passes += audit.assembled_passes;
        total.t1_ready_blocks += audit.t1_ready_blocks;
    }
    return total;
}

/// Irreversible path back end: dequantize the assembled i32 coefficient
/// planes, run the float 9/7 inverse DWT, and undo the ICT.
fn decodeIrreversibleImageFromQuantizedPlanes(
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    quantized: color.RctPlanes,
) !image.RgbImage {
    return decodeIrreversibleImageFromQuantizedPlanesMeasured(allocator, header, quantized, 1, null);
}

const IrreversibleInversePlaneJob = struct {
    quantized: []const i32,
    plane: []f32,
    width: usize,
    height: usize,
    levels: u8,
    x0: u32,
    y0: u32,
    bands: []const subband.Band,
    deltas: []const f64,
    result: anyerror!void = {},
};

fn irreversibleInversePlaneWorker(job: *IrreversibleInversePlaneJob) void {
    job.result = irreversibleInversePlane(job);
}

fn irreversibleInversePlane(job: *IrreversibleInversePlaneJob) anyerror!void {
    for (job.bands, job.deltas) |band, delta| {
        dequantizeBandRegion(job.quantized, job.plane, job.width, band.rect, delta);
    }
    try wavelet.inverse2DOrigin(
        std.heap.smp_allocator,
        job.plane,
        job.width,
        job.height,
        job.levels,
        .irreversible_9_7,
        job.x0,
        job.y0,
    );
}

fn decodeIrreversibleImageFromQuantizedPlanesMeasured(
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    quantized: color.RctPlanes,
    thread_count: u8,
    timings: ?*DecodeTimings,
) !image.RgbImage {
    const pixels = try std.math.mul(usize, header.width, header.height);
    if (quantized.planes.len != 3) return CodestreamError.InvalidCodestream;
    for (quantized.planes) |plane_slice| {
        if (plane_slice.len != pixels) return CodestreamError.InvalidCodestream;
    }

    const plan = temporaryPacketPlan(header);
    if (plan.resolution_count == 0) return CodestreamError.InvalidCodestream;
    const full_resolution = plan.resolutions[plan.resolution_count - 1];
    const x1 = std.math.add(u32, full_resolution.x0, std.math.cast(u32, header.width) orelse return CodestreamError.InvalidCodestream) catch
        return CodestreamError.InvalidCodestream;
    const y1 = std.math.add(u32, full_resolution.y0, std.math.cast(u32, header.height) orelse return CodestreamError.InvalidCodestream) catch
        return CodestreamError.InvalidCodestream;
    const bands = try subband.makeBandsForRegion(
        allocator,
        full_resolution.x0,
        full_resolution.y0,
        x1,
        y1,
        header.levels,
    );
    defer allocator.free(bands);

    const y_f = try allocator.alloc(f32, pixels);
    defer allocator.free(y_f);
    const cb_f = try allocator.alloc(f32, pixels);
    defer allocator.free(cb_f);
    const cr_f = try allocator.alloc(f32, pixels);
    defer allocator.free(cr_f);

    const deltas = try allocator.alloc(f64, bands.len);
    defer allocator.free(deltas);
    for (bands, deltas) |band, *delta| {
        const step = signalledHeaderBandStep(header, band.kind, band.level) orelse
            try irreversibleBandStepSizeFor(header.quantization, header.bit_depth, band.kind, band.level, header.levels);
        delta.* = irreversibleBandDelta(
            header.bit_depth,
            band.kind,
            step,
        );
    }

    const wavelet_start = monotonicNs();
    // Dequantization and the inverse 9/7 DWT are independent per component,
    // so three fused plane jobs avoid extra full-plane traffic. A wider
    // intra-plane inverse was bit-exact but regressed the maintained t16 gate.
    var jobs = [3]IrreversibleInversePlaneJob{
        .{ .quantized = quantized.planes[0], .plane = y_f, .width = header.width, .height = header.height, .levels = header.levels, .x0 = full_resolution.x0, .y0 = full_resolution.y0, .bands = bands, .deltas = deltas },
        .{ .quantized = quantized.planes[1], .plane = cb_f, .width = header.width, .height = header.height, .levels = header.levels, .x0 = full_resolution.x0, .y0 = full_resolution.y0, .bands = bands, .deltas = deltas },
        .{ .quantized = quantized.planes[2], .plane = cr_f, .width = header.width, .height = header.height, .levels = header.levels, .x0 = full_resolution.x0, .y0 = full_resolution.y0, .bands = bands, .deltas = deltas },
    };
    try runComponentJobs(IrreversibleInversePlaneJob, &jobs, componentThreadCountFor(thread_count), irreversibleInversePlaneWorker);
    if (timings) |t| t.wavelet_ns += elapsedNs(wavelet_start);

    // Borrowed carrier: the planes stay owned by the y_f/cb_f/cr_f defers
    // above, so no deinit is called on this instance.
    var ict_plane_slices = [3][]f32{ y_f, cb_f, cr_f };
    const ict = color.IctPlanes{
        .allocator = allocator,
        .width = header.width,
        .height = header.height,
        .bit_depth = header.bit_depth,
        .planes = &ict_plane_slices,
    };
    const color_start = monotonicNs();
    defer {
        if (timings) |t| t.color_transform_ns += elapsedNs(color_start);
    }
    return color.inverseIctThreaded(allocator, ict, thread_count);
}

const StrictBlockDecodeJob = struct {
    width: usize,
    height: usize,
    catalog: *const StrictPacketBlockCatalog,
    component: usize,
    next_block: *std.atomic.Value(usize),
    blocks: []const StrictPacketBlock,
    block_order: []const usize,
    options: DecodeOptions,
    plane: []i32,
    profile_worker: bool = false,
    collect_t1_stats: bool = false,
    t1_stats: ebcot.DecodePassStats = .{},
    worker_stats: StrictBlockWorkerStats = .{},
    result: anyerror!void = {},
};

fn strictBlockDecodeWorker(job: *StrictBlockDecodeJob) void {
    const worker_start = if (job.profile_worker) monotonicNs() else 0;
    var scratch = ebcot.DecodeBlockScratch.init(std.heap.smp_allocator);
    defer scratch.deinit();
    defer if (job.profile_worker) {
        job.worker_stats.ns = elapsedNs(worker_start);
    };

    while (true) {
        const order_index = job.next_block.fetchAdd(1, .monotonic);
        if (order_index >= job.block_order.len) break;
        const block_index = job.block_order[order_index];
        const block = job.blocks[block_index];
        if (block.cumulative_passes == 0 and block.cumulative_bytes == 0) continue;
        if (!block.metadata_ready) {
            job.result = CodestreamError.InvalidCodestream;
            return;
        }
        if (block.encoded_bitplanes > block.nominal_bitplanes) {
            job.result = CodestreamError.InvalidCodestream;
            return;
        }
        const payload = job.catalog.blockPayload(job.component, block_index);
        if (payload.len != block.payload_length or payload.len != block.cumulative_bytes) {
            job.result = CodestreamError.InvalidCodestream;
            return;
        }
        if (job.profile_worker) {
            job.worker_stats.blocks += 1;
            job.worker_stats.payload_bytes += @intCast(payload.len);
        }
        if (block.code_block_style.bypass) {
            if (job.options.t1_backend != .iso_mq) {
                job.result = CodestreamError.UnsupportedPayload;
                return;
            }
            const decoded = ebcot.decodeCodeBlockPayloadBypassIsoMqScratchWithStyleProfiledBorrowed(
                &scratch,
                block.encoded_bitplanes,
                block.cumulative_passes,
                payload,
                block.segment_lengths[0..block.segment_count],
                block.rect.width,
                block.rect.height,
                block.code_block_style,
                if (job.collect_t1_stats) &job.t1_stats else null,
            ) catch |err| {
                job.result = err;
                return;
            };
            scatterStrictDecodedBlockUnchecked(job.plane, job.width, job.height, block.rect, decoded) catch |err| {
                job.result = err;
                return;
            };
            continue;
        }
        if (block.code_block_style.terminate_all) {
            if (job.options.t1_backend != .iso_mq) {
                job.result = CodestreamError.UnsupportedPayload;
                return;
            }
            const decoded = ebcot.decodeCodeBlockPayloadTerminatedIsoMqScratchWithStyleProfiledBorrowed(
                &scratch,
                block.encoded_bitplanes,
                block.cumulative_passes,
                payload,
                block.segment_lengths[0..block.segment_count],
                block.rect.width,
                block.rect.height,
                block.code_block_style,
                if (job.collect_t1_stats) &job.t1_stats else null,
            ) catch |err| {
                job.result = err;
                return;
            };
            scatterStrictDecodedBlockUnchecked(job.plane, job.width, job.height, block.rect, decoded) catch |err| {
                job.result = err;
                return;
            };
            continue;
        }

        switch (job.options.t1_backend) {
            .legacy_mq => {
                const decoded = ebcot.decodeCodeBlockPayloadContinuousInferredWithStyle(
                    std.heap.smp_allocator,
                    block.encoded_bitplanes,
                    block.cumulative_passes,
                    payload,
                    block.rect.width,
                    block.rect.height,
                    block.code_block_style,
                ) catch |err| {
                    job.result = err;
                    return;
                };
                scatterStrictDecodedBlockUnchecked(job.plane, job.width, job.height, block.rect, decoded) catch |err| {
                    std.heap.smp_allocator.free(decoded);
                    job.result = err;
                    return;
                };
                std.heap.smp_allocator.free(decoded);
            },
            .iso_mq => {
                const decoded = ebcot.decodeCodeBlockPayloadContinuousInferredIsoMqScratchWithStyleProfiledBorrowed(
                    &scratch,
                    block.encoded_bitplanes,
                    block.cumulative_passes,
                    payload,
                    block.rect.width,
                    block.rect.height,
                    block.code_block_style,
                    if (job.collect_t1_stats) &job.t1_stats else null,
                ) catch |err| {
                    job.result = err;
                    return;
                };
                scatterStrictDecodedBlockUnchecked(job.plane, job.width, job.height, block.rect, decoded) catch |err| {
                    job.result = err;
                    return;
                };
            },
        }
    }
    job.result = {};
}

fn reconstructStrictComponentCoefficientPlanesFromBlockCatalog(
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    catalog: StrictPacketBlockCatalog,
    options: DecodeOptions,
    timings: ?*DecodeTimings,
) !color.RctPlanes {
    // All multi-thread decode goes through the per-component block-level
    // atomic scheduler (sequential components, balanced within each). The
    // former component-parallel path (one thread per component) was only
    // load-balanced at exactly 3 threads and left a 2:1 imbalance at 2
    // threads (~1.31x); block-level balancing raises 2 threads to ~1.66x and
    // keeps scaling monotone across thread counts.
    const plane_slices = try allocator.alloc([]i32, 3);
    var reconstructed: usize = 0;
    errdefer {
        for (plane_slices[0..reconstructed]) |plane_slice| allocator.free(plane_slice);
        allocator.free(plane_slices);
    }
    while (reconstructed < 3) : (reconstructed += 1) {
        plane_slices[reconstructed] = try reconstructStrictComponentCoefficientsFromBlockCatalog(
            allocator,
            header.width,
            header.height,
            catalog,
            reconstructed,
            options,
            timings,
        );
    }

    return .{
        .allocator = allocator,
        .width = header.width,
        .height = header.height,
        .bit_depth = header.bit_depth,
        .planes = plane_slices,
    };
}

fn reconstructStrictComponentCoefficientsFromBlockCatalog(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    catalog: StrictPacketBlockCatalog,
    component: usize,
    options: DecodeOptions,
    timings: ?*DecodeTimings,
) ![]i32 {
    if (component >= catalog.component_count) return CodestreamError.InvalidCodestream;
    const pixels = try std.math.mul(usize, width, height);
    const plane = try allocator.alloc(i32, pixels);
    errdefer allocator.free(plane);
    try fillStrictComponentCoefficientsFromBlockCatalog(
        allocator,
        width,
        height,
        catalog,
        component,
        options,
        plane,
        if (timings) |t| &t.t1_pass_stats else null,
        timings,
    );
    return plane;
}

fn fillStrictComponentCoefficientsFromBlockCatalog(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    catalog: StrictPacketBlockCatalog,
    component: usize,
    options: DecodeOptions,
    plane: []i32,
    t1_stats: ?*ebcot.DecodePassStats,
    timings: ?*DecodeTimings,
) !void {
    if (component >= catalog.component_count) return CodestreamError.InvalidCodestream;
    const pixels = try std.math.mul(usize, width, height);
    if (plane.len != pixels) return CodestreamError.InvalidCodestream;

    const blocks = catalog.components[component];
    if (strictBlocksRequireZeroInitializedPlane(blocks)) {
        @memset(plane, 0);
    }
    const worker_count = strictDecodeBlockThreadCount(options, blocks.len);
    if (worker_count > 1) {
        try validateStrictBlockCatalogCoverageBits(allocator, width, height, blocks);
        try reconstructStrictComponentBlocksParallel(
            allocator,
            width,
            height,
            catalog,
            component,
            blocks,
            options,
            plane,
            worker_count,
            t1_stats,
            timings,
        );
        return;
    }

    const covered = try allocator.alloc(bool, pixels);
    defer allocator.free(covered);
    @memset(covered, false);

    // One reusable T1 scratch per component keeps the hot decode loop free
    // of per-block allocations.
    var scratch = ebcot.DecodeBlockScratch.init(allocator);
    defer scratch.deinit();

    for (blocks, 0..) |block, block_index| {
        if (block.rect.width == 0 or block.rect.height == 0) return CodestreamError.InvalidCodestream;
        if (block.cumulative_passes == 0 and block.cumulative_bytes == 0) {
            try markStrictZeroBlockCovered(covered, width, height, block.rect);
            continue;
        }
        if (!block.metadata_ready) return CodestreamError.InvalidCodestream;
        if (block.encoded_bitplanes > block.nominal_bitplanes) return CodestreamError.InvalidCodestream;
        const payload = catalog.blockPayload(component, block_index);
        if (payload.len != block.payload_length or payload.len != block.cumulative_bytes) {
            return CodestreamError.InvalidCodestream;
        }
        if (block.code_block_style.bypass) {
            if (options.t1_backend != .iso_mq) return CodestreamError.UnsupportedPayload;
            const decoded = try ebcot.decodeCodeBlockPayloadBypassIsoMqScratchWithStyleProfiledBorrowed(
                &scratch,
                block.encoded_bitplanes,
                block.cumulative_passes,
                payload,
                block.segment_lengths[0..block.segment_count],
                block.rect.width,
                block.rect.height,
                block.code_block_style,
                t1_stats,
            );
            try scatterStrictDecodedBlock(plane, covered, width, height, block.rect, decoded);
            continue;
        }
        if (block.code_block_style.terminate_all) {
            // Each coding pass is an independently terminated MQ segment; decode
            // from the per-pass segment lengths recovered from the packet header.
            if (options.t1_backend != .iso_mq) return CodestreamError.UnsupportedPayload;
            const decoded = try ebcot.decodeCodeBlockPayloadTerminatedIsoMqScratchWithStyleProfiledBorrowed(
                &scratch,
                block.encoded_bitplanes,
                block.cumulative_passes,
                payload,
                block.segment_lengths[0..block.segment_count],
                block.rect.width,
                block.rect.height,
                block.code_block_style,
                t1_stats,
            );
            try scatterStrictDecodedBlock(plane, covered, width, height, block.rect, decoded);
            continue;
        }

        switch (options.t1_backend) {
            .legacy_mq => {
                const decoded = try ebcot.decodeCodeBlockPayloadContinuousInferredWithStyle(
                    allocator,
                    block.encoded_bitplanes,
                    block.cumulative_passes,
                    payload,
                    block.rect.width,
                    block.rect.height,
                    block.code_block_style,
                );
                errdefer allocator.free(decoded);
                try scatterStrictDecodedBlock(plane, covered, width, height, block.rect, decoded);
                allocator.free(decoded);
            },
            .iso_mq => {
                const decoded = try ebcot.decodeCodeBlockPayloadContinuousInferredIsoMqScratchWithStyleProfiledBorrowed(
                    &scratch,
                    block.encoded_bitplanes,
                    block.cumulative_passes,
                    payload,
                    block.rect.width,
                    block.rect.height,
                    block.code_block_style,
                    t1_stats,
                );
                try scatterStrictDecodedBlock(plane, covered, width, height, block.rect, decoded);
            },
        }
    }
    for (covered) |is_covered| {
        if (!is_covered) return CodestreamError.InvalidCodestream;
    }
}

fn strictBlocksRequireZeroInitializedPlane(blocks: []const StrictPacketBlock) bool {
    for (blocks) |block| {
        if (block.cumulative_passes == 0 and block.cumulative_bytes == 0) return true;
    }
    return false;
}

fn strictDecodeBlockThreadCount(options: DecodeOptions, block_count: usize) usize {
    if (options.threads < 2 or block_count < 2) return 1;
    return @min(@as(usize, options.threads), block_count);
}

fn validateStrictBlockCatalogCoverageBits(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    blocks: []const StrictPacketBlock,
) !void {
    if (width == 0 or height == 0) return CodestreamError.InvalidCodestream;
    const row_words = strictCoverageRowWords(width);
    const word_count = try std.math.mul(usize, row_words, height);
    const covered = try allocator.alloc(u64, word_count);
    defer allocator.free(covered);
    @memset(covered, 0);

    for (blocks) |block| {
        if (block.rect.width == 0 or block.rect.height == 0) return CodestreamError.InvalidCodestream;
        try markStrictRectCoveredBits(covered, row_words, width, height, block.rect);
    }

    const full_word = std.math.maxInt(u64);
    const last_word_mask = strictCoverageBitRangeMask(0, (width - 1) & 63);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_start = try std.math.mul(usize, y, row_words);
        var word: usize = 0;
        while (word < row_words) : (word += 1) {
            const expected = if (word + 1 == row_words) last_word_mask else full_word;
            if (covered[row_start + word] != expected) return CodestreamError.InvalidCodestream;
        }
    }
}

fn strictCoverageRowWords(width: usize) usize {
    return (width + 63) / 64;
}

fn markStrictRectCoveredBits(
    covered: []u64,
    row_words: usize,
    plane_width: usize,
    plane_height: usize,
    rect: subband.Rect,
) !void {
    const end_x = try std.math.add(usize, rect.x, rect.width);
    const end_y = try std.math.add(usize, rect.y, rect.height);
    if (end_x > plane_width or end_y > plane_height) return CodestreamError.InvalidCodestream;

    const first_word = rect.x / 64;
    const last_word = (end_x - 1) / 64;
    var y = rect.y;
    while (y < end_y) : (y += 1) {
        const row_start = try std.math.mul(usize, y, row_words);
        var word = first_word;
        while (word <= last_word) : (word += 1) {
            const word_min_x = word * 64;
            const lo = if (rect.x > word_min_x) rect.x - word_min_x else 0;
            const hi = @min(end_x - 1 - word_min_x, 63);
            const mask = strictCoverageBitRangeMask(lo, hi);
            const index = try std.math.add(usize, row_start, word);
            if (index >= covered.len or (covered[index] & mask) != 0) return CodestreamError.InvalidCodestream;
            covered[index] |= mask;
        }
    }
}

fn strictCoverageBitRangeMask(lo: usize, hi: usize) u64 {
    const all: u64 = std.math.maxInt(u64);
    const lower = all << @as(u6, @intCast(lo));
    const upper = if (hi == 63)
        all
    else
        (@as(u64, 1) << @as(u6, @intCast(hi + 1))) - 1;
    return lower & upper;
}

fn reconstructStrictComponentBlocksParallel(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    catalog: StrictPacketBlockCatalog,
    component: usize,
    blocks: []const StrictPacketBlock,
    options: DecodeOptions,
    plane: []i32,
    worker_count: usize,
    t1_stats: ?*ebcot.DecodePassStats,
    timings: ?*DecodeTimings,
) !void {
    const block_order = try allocator.alloc(usize, blocks.len);
    defer allocator.free(block_order);
    for (block_order, 0..) |*entry, index| entry.* = index;
    std.mem.sort(usize, block_order, blocks, strictDecodeBlockHeavierThan);

    var jobs = try allocator.alloc(StrictBlockDecodeJob, worker_count);
    defer allocator.free(jobs);
    var next_block = std.atomic.Value(usize).init(0);
    for (jobs) |*job| {
        job.* = .{
            .width = width,
            .height = height,
            .catalog = &catalog,
            .component = component,
            .next_block = &next_block,
            .blocks = blocks,
            .block_order = block_order,
            .options = options,
            .plane = plane,
            .profile_worker = timings != null,
            .collect_t1_stats = t1_stats != null,
        };
    }

    const spawn_count = worker_count - 1;
    var threads = try allocator.alloc(std.Thread, spawn_count);
    defer allocator.free(threads);
    var spawned: usize = 0;
    while (spawned < spawn_count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, strictBlockDecodeWorker, .{&jobs[spawned]}) catch |err| {
            for (threads[0..spawned]) |thread| thread.join();
            return err;
        };
    }

    strictBlockDecodeWorker(&jobs[spawn_count]);
    for (threads[0..spawned]) |thread| thread.join();

    for (jobs) |job| try job.result;
    if (t1_stats) |stats| {
        for (jobs) |job| stats.merge(job.t1_stats);
    }
    if (timings) |t| {
        for (jobs) |job| t.addStrictBlockWorker(job.worker_stats);
    }
}

fn strictDecodeBlockHeavierThan(blocks: []const StrictPacketBlock, lhs: usize, rhs: usize) bool {
    const a = blocks[lhs];
    const b = blocks[rhs];
    if (a.payload_length != b.payload_length) return a.payload_length > b.payload_length;
    if (a.cumulative_passes != b.cumulative_passes) return a.cumulative_passes > b.cumulative_passes;
    const a_area = a.rect.width * a.rect.height;
    const b_area = b.rect.width * b.rect.height;
    if (a_area != b_area) return a_area > b_area;
    return lhs < rhs;
}

fn reconstructStrictComponentCoefficients(
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    catalog: []const TemporaryRpclBlock,
    assembly: StrictComponentAssembly,
    layer_count: u16,
    options: DecodeOptions,
) ![]i32 {
    if (catalog.len != assembly.blocks.len) return CodestreamError.InvalidCodestream;
    const pixels = try std.math.mul(usize, width, height);
    const plane = try allocator.alloc(i32, pixels);
    errdefer allocator.free(plane);
    @memset(plane, 0);

    const covered = try allocator.alloc(bool, pixels);
    defer allocator.free(covered);
    @memset(covered, false);

    for (catalog, assembly.blocks) |expected, actual| {
        if (actual.cumulative_passes == 0 and actual.cumulative_bytes == 0) {
            try markStrictZeroBlockCovered(covered, width, height, expected.rect);
            continue;
        }
        const decoded = try decodeStrictBlockCoefficients(allocator, expected, actual, layer_count, options);
        defer allocator.free(decoded);
        try validateStrictDecodedBlock(expected, decoded);
        try scatterStrictDecodedBlock(plane, covered, width, height, expected.rect, decoded);
    }
    for (covered) |is_covered| {
        if (!is_covered) return CodestreamError.InvalidCodestream;
    }

    return plane;
}

fn decodeStrictBlockCoefficients(
    allocator: std.mem.Allocator,
    expected: TemporaryRpclBlock,
    actual: StrictRpclBlockAssembly,
    layer_count: u16,
    options: DecodeOptions,
) ![]i32 {
    const pass_count: usize = @intCast(actual.cumulative_passes);
    if (pass_count > expected.passes.len) return CodestreamError.InvalidCodestream;
    const decode_bitplanes = @max(actual.encoded_bitplanes, expected.encoded_bitplanes);

    const segment = ebcot.CodeBlockSegment{
        .bitplanes = decode_bitplanes,
        .non_zero_count = expected.non_zero_count,
        .pass_count = actual.cumulative_passes,
        .byte_length = actual.cumulative_bytes,
        .passes = expected.passes[0..pass_count],
        .bytes = actual.payload.items,
    };
    const complete_block = pass_count == expected.passes.len;
    _ = layer_count;
    if (actual.code_block_style.bypass) return CodestreamError.UnsupportedPayload;
    if (complete_block and !actual.code_block_style.terminate_all) {
        return switch (options.t1_backend) {
            .legacy_mq => ebcot.decodeCodeBlockPayloadContinuousInferredWithStyle(
                allocator,
                decode_bitplanes,
                actual.cumulative_passes,
                actual.payload.items,
                expected.rect.width,
                expected.rect.height,
                actual.code_block_style,
            ),
            .iso_mq => ebcot.decodeCodeBlockPayloadContinuousInferredIsoMqWithStyle(
                allocator,
                decode_bitplanes,
                actual.cumulative_passes,
                actual.payload.items,
                expected.rect.width,
                expected.rect.height,
                actual.code_block_style,
            ),
        };
    }
    return if (complete_block)
        ebcot.decodeCodeBlockSegmentCoefficientsContinuousWithStyle(allocator, segment, expected.rect.width, expected.rect.height, actual.code_block_style)
    else
        ebcot.decodeCodeBlockSegmentCoefficientsContinuousPartialWithStyle(allocator, segment, expected.rect.width, expected.rect.height, actual.code_block_style);
}

fn markStrictZeroBlockCovered(
    covered: []bool,
    plane_width: usize,
    plane_height: usize,
    rect: subband.Rect,
) !void {
    const end_x = try std.math.add(usize, rect.x, rect.width);
    const end_y = try std.math.add(usize, rect.y, rect.height);
    if (end_x > plane_width or end_y > plane_height) return CodestreamError.InvalidCodestream;

    var y = rect.y;
    while (y < end_y) : (y += 1) {
        const row_offset = try std.math.mul(usize, y, plane_width);
        const row_start = try std.math.add(usize, row_offset, rect.x);
        const row_end = try std.math.add(usize, row_offset, end_x);
        if (row_end > covered.len) return CodestreamError.InvalidCodestream;
        for (covered[row_start..row_end]) |is_covered| {
            if (is_covered) return CodestreamError.InvalidCodestream;
        }
        @memset(covered[row_start..row_end], true);
    }
}

fn scatterStrictDecodedBlock(
    plane: []i32,
    covered: []bool,
    plane_width: usize,
    plane_height: usize,
    rect: subband.Rect,
    decoded: []const i32,
) !void {
    if (plane.len != covered.len) return CodestreamError.InvalidCodestream;
    if (decoded.len != rectArea(rect)) return CodestreamError.InvalidCodestream;
    const end_x = try std.math.add(usize, rect.x, rect.width);
    const end_y = try std.math.add(usize, rect.y, rect.height);
    if (end_x > plane_width or end_y > plane_height) return CodestreamError.InvalidCodestream;

    var source: usize = 0;
    var y = rect.y;
    while (y < end_y) : (y += 1) {
        const row_offset = try std.math.mul(usize, y, plane_width);
        const row_start = try std.math.add(usize, row_offset, rect.x);
        const row_end = try std.math.add(usize, row_offset, end_x);
        if (row_end > plane.len or row_end > covered.len) return CodestreamError.InvalidCodestream;
        const source_end = try std.math.add(usize, source, rect.width);
        if (source_end > decoded.len) return CodestreamError.InvalidCodestream;
        for (covered[row_start..row_end]) |is_covered| {
            if (is_covered) return CodestreamError.InvalidCodestream;
        }
        @memcpy(plane[row_start..row_end], decoded[source..source_end]);
        @memset(covered[row_start..row_end], true);
        source = source_end;
    }
    if (source != decoded.len) return CodestreamError.InvalidCodestream;
}

fn scatterStrictDecodedBlockUnchecked(
    plane: []i32,
    plane_width: usize,
    plane_height: usize,
    rect: subband.Rect,
    decoded: []const i32,
) !void {
    if (decoded.len != rectArea(rect)) return CodestreamError.InvalidCodestream;
    const end_x = try std.math.add(usize, rect.x, rect.width);
    const end_y = try std.math.add(usize, rect.y, rect.height);
    if (end_x > plane_width or end_y > plane_height) return CodestreamError.InvalidCodestream;

    var source: usize = 0;
    var y = rect.y;
    while (y < end_y) : (y += 1) {
        const row_offset = try std.math.mul(usize, y, plane_width);
        const row_start = try std.math.add(usize, row_offset, rect.x);
        const row_end = try std.math.add(usize, row_offset, end_x);
        if (row_end > plane.len) return CodestreamError.InvalidCodestream;
        const source_end = try std.math.add(usize, source, rect.width);
        if (source_end > decoded.len) return CodestreamError.InvalidCodestream;
        @memcpy(plane[row_start..row_end], decoded[source..source_end]);
        source = source_end;
    }
    if (source != decoded.len) return CodestreamError.InvalidCodestream;
}

fn countNonZeroI32(values: []const i32) u32 {
    var count: u32 = 0;
    for (values) |value| {
        if (value != 0) count += 1;
    }
    return count;
}

fn maxZeroBitplanes(blocks: []const TemporaryRpclBlock, selected: []const usize) u8 {
    var max_zero: u8 = 0;
    for (selected) |block_index| {
        const block = blocks[block_index];
        max_zero = @max(max_zero, block.nominal_bitplanes);
    }
    return max_zero;
}

fn validateDecodedRpclPacketBlocks(
    blocks: []const TemporaryRpclBlock,
    selected: []const usize,
    layer: u16,
    decoded: []const t2.DecodedPacketBlock,
    payloads: []const ?[]const u8,
) !void {
    if (selected.len != decoded.len or selected.len != payloads.len) return CodestreamError.InvalidCodestream;
    for (selected, 0..) |block_index, index| {
        if (block_index >= blocks.len) return CodestreamError.InvalidCodestream;
        const block = blocks[block_index];
        const previous = if (layer == 0)
            t2.LayerTruncation{ .cumulative_passes = 0, .cumulative_bytes = 0 }
        else
            block.layers[layer - 1];
        const current = block.layers[layer];
        const contribution = try t2.layerContribution(previous, current);
        const actual = decoded[index];
        if (actual.included != contribution.included) return CodestreamError.InvalidCodestream;
        if (!contribution.included) {
            if (actual.first_inclusion or actual.zero_bitplanes != 0 or actual.pass_count != 0 or actual.byte_length != 0) {
                return CodestreamError.InvalidCodestream;
            }
            if (payloads[index] != null) return CodestreamError.InvalidCodestream;
            continue;
        }

        const first_inclusion = previous.cumulative_passes == 0 and previous.cumulative_bytes == 0;
        if (actual.first_inclusion != first_inclusion) return CodestreamError.InvalidCodestream;
        const expected_zero = if (first_inclusion)
            try t2.zeroBitPlaneCount(block.nominal_bitplanes, block.encoded_bitplanes)
        else
            0;
        if (actual.zero_bitplanes != expected_zero) return CodestreamError.InvalidCodestream;
        if (actual.pass_count != contribution.pass_count or actual.byte_length != contribution.byte_length) {
            return CodestreamError.InvalidCodestream;
        }
        const expected_payload = try t2.layerPayloadSlice(block.payload, previous, current);
        const actual_payload = payloads[index] orelse return CodestreamError.InvalidCodestream;
        if (!std.mem.eql(u8, expected_payload, actual_payload)) return CodestreamError.InvalidCodestream;
    }
}

fn readStrictSodRpclPacketStream(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    component_count: u16,
) !RpclPacketStream {
    if (bytes.len < 4 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    var lengths: std.ArrayList(u32) = .empty;
    errdefer lengths.deinit(allocator);
    var packet_bytes: std.ArrayList(u8) = .empty;
    errdefer packet_bytes.deinit(allocator);

    var main_header = try readStrictMainHeaderIndex(allocator, bytes, component_count);
    defer main_header.deinit();
    var cursor = main_header.first_sot;
    var packet_sequence: u16 = 0;
    var tile_part_index: usize = 0;
    var expected_tile_part_count: ?u8 = null;
    var expected_ppt_index: u16 = 0;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(Marker.eoc)) {
            cursor += 2;
            if (cursor != bytes.len) return CodestreamError.InvalidCodestream;
            if (expected_tile_part_count) |count| {
                if (tile_part_index != count) return CodestreamError.InvalidCodestream;
            }
            if (main_header.tlm_entries) |tlm_slice| {
                if (tile_part_index != tlm_slice.len) return CodestreamError.InvalidCodestream;
            }
            const owned_lengths = try lengths.toOwnedSlice(allocator);
            errdefer allocator.free(owned_lengths);
            const owned_packet_bytes = try packet_bytes.toOwnedSlice(allocator);
            return .{
                .allocator = allocator,
                .packet_lengths = owned_lengths,
                .packet_bytes = owned_packet_bytes,
            };
        }
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;

        const entries = if (main_header.tlm_entries) |tlm_slice| tlm_slice else null;
        {
            const external_headers = if (main_header.ppm_headers) |headers|
                try strictPpmGroupAt(headers, tile_part_index)
            else
                null;
            var tile_part = try readStrictTilePartHeader(allocator, bytes, cursor, tile_part_index, &expected_tile_part_count, entries, &expected_ppt_index, external_headers, null);
            defer tile_part.deinit(allocator);
            if (tile_part.packet_lengths.items.len == 0) return CodestreamError.UnsupportedPayload;
            if (tile_part.packed_headers.items.len != 0) return CodestreamError.UnsupportedPayload;
            cursor = tile_part.sod + 2;
            try appendStrictSodPackets(
                allocator,
                &lengths,
                &packet_bytes,
                bytes,
                cursor,
                tile_part.end,
                tile_part.packet_lengths.items,
                main_header.packet_markers,
                &packet_sequence,
            );
            cursor = tile_part.end;
        }
        tile_part_index += 1;
    }

    return CodestreamError.InvalidCodestream;
}

/// Sequential packet-slot iterator over the stream order implied by the COD
/// progression. Both orders emit each packet identity exactly once; only the
/// interleaving differs.
const StreamPacketIterator = union(enum) {
    rpcl: packet_plan.RpclIterator,
    lrcp: packet_plan.LrcpIterator,
    rlcp: packet_plan.RlcpIterator,

    fn init(progression: ProgressionOrder, plan: packet_plan.Plan, components: u16, layers: u16) !StreamPacketIterator {
        return switch (progression) {
            .rpcl => .{ .rpcl = try packet_plan.RpclIterator.init(plan, components, layers) },
            .lrcp => .{ .lrcp = try packet_plan.LrcpIterator.init(plan, components, layers) },
            .rlcp => .{ .rlcp = try packet_plan.RlcpIterator.init(plan, components, layers) },
            else => CodestreamError.UnsupportedPayload,
        };
    }

    fn next(self: *StreamPacketIterator) ?packet_plan.Packet {
        return switch (self.*) {
            .rpcl => |*it| it.next(),
            .lrcp => |*it| it.next(),
            .rlcp => |*it| it.next(),
        };
    }
};

/// Full packet sequence in the stream order of any supported progression.
/// The iterator-backed orders stream directly; the position-major orders
/// (PCRL/CPRL) sort by reference-grid precinct position. Caller frees.
fn buildStreamPacketSequence(
    allocator: std.mem.Allocator,
    progression: ProgressionOrder,
    plan: packet_plan.Plan,
    component_count: u16,
    layers: u16,
) ![]packet_plan.Packet {
    switch (progression) {
        .rpcl, .lrcp, .rlcp => {
            const total = std.math.cast(usize, plan.packets) orelse return CodestreamError.InvalidCodestream;
            const packets = try allocator.alloc(packet_plan.Packet, total);
            errdefer allocator.free(packets);
            var iterator = try StreamPacketIterator.init(progression, plan, component_count, layers);
            var count: usize = 0;
            while (iterator.next()) |packet| {
                if (count >= total) return CodestreamError.InvalidCodestream;
                packets[count] = packet;
                count += 1;
            }
            if (count != total) return CodestreamError.InvalidCodestream;
            return packets;
        },
        .pcrl => return packet_plan.positionOrderedPackets(allocator, plan, component_count, layers, .pcrl) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => CodestreamError.InvalidCodestream,
        },
        .cprl => return packet_plan.positionOrderedPackets(allocator, plan, component_count, layers, .cprl) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => CodestreamError.InvalidCodestream,
        },
    }
}

/// The downstream catalog consumers (packet-header audit/assembly) walk
/// entries assuming RPCL grouping: each precinct's layers arrive as one
/// consecutive run. LRCP preserves per-precinct layer order but interleaves
/// precincts across layers, so permute the cataloged entries back into RPCL
/// order — packet bytes are order-independent, only the stream slots move.
fn reorderStrictEntriesToRpcl(
    allocator: std.mem.Allocator,
    entries: []StrictPacketEntry,
    plan: packet_plan.Plan,
    component_count: u16,
    layers: u16,
) !void {
    const scratch = try allocator.alloc(StrictPacketEntry, entries.len);
    defer allocator.free(scratch);
    const seen = try allocator.alloc(bool, entries.len);
    defer allocator.free(seen);
    @memset(seen, false);
    for (entries) |entry| {
        const sequence = packet_plan.rpclSequenceForPacket(plan, component_count, layers, entry.packet) catch
            return CodestreamError.InvalidCodestream;
        const slot = std.math.cast(usize, sequence) orelse return CodestreamError.InvalidCodestream;
        if (slot >= entries.len or seen[slot]) return CodestreamError.InvalidCodestream;
        seen[slot] = true;
        var updated = entry;
        updated.packet.sequence = sequence;
        scratch[slot] = updated;
    }
    @memcpy(entries, scratch);
}

/// Persistent per-precinct packet-header reader states for the PLT-less
/// decode path (foreign-stream Stage B, docs/next_steps.md): without PLT the
/// packet spans come from decoding each packet header in stream order, and
/// non-RPCL progressions revisit a precinct's later layers after other
/// precincts, so the tag-tree / lblock / inclusion states must survive across
/// the whole stream. Slots mirror the RpclBlockIndex cell layout
/// (resolution-major, precinct x component).
const StrictStatefulPrecinctGroups = struct {
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    geometries: StrictComponentGeometrySet,
    component_slots: [max_codestream_components][]?Slot = [_][]?Slot{&.{}} ** max_codestream_components,
    initialized_components: usize = 0,

    const Slot = struct {
        groups: [max_rpcl_packet_band_groups]StrictPacketAuditBandGroup,
        count: usize,
    };

    fn init(allocator: std.mem.Allocator, header: TemporaryHeader) !StrictStatefulPrecinctGroups {
        const geometries = try StrictComponentGeometrySet.init(allocator, header);
        var result = StrictStatefulPrecinctGroups{
            .allocator = allocator,
            .header = header,
            .geometries = geometries,
        };
        errdefer result.deinit();
        for (0..header.component_count) |component| {
            const geometry = try result.geometries.geometryFor(component);
            const slots = try allocator.alloc(?Slot, geometry.rpcl_index.cells.len);
            @memset(slots, null);
            result.component_slots[component] = slots;
            result.initialized_components += 1;
        }
        return result;
    }

    fn deinit(self: *StrictStatefulPrecinctGroups) void {
        for (self.component_slots[0..self.initialized_components]) |slots| {
            for (slots) |*slot| {
                if (slot.*) |*active| {
                    deinitStrictPacketAuditBandGroups(self.allocator, active.groups[0..active.count]);
                }
            }
            self.allocator.free(slots);
        }
        self.geometries.deinit();
        self.* = undefined;
    }

    fn slotIndex(geometry: *const StrictComponentGeometry, packet: packet_plan.Packet) !usize {
        if (packet.resolution >= geometry.rpcl_index.resolution_count) {
            return CodestreamError.InvalidCodestream;
        }
        const base = geometry.rpcl_index.resolution_offsets[packet.resolution];
        const precinct = std.math.cast(usize, packet.precinct_index) orelse return CodestreamError.InvalidCodestream;
        const index = try std.math.add(usize, base, precinct);
        if (index >= geometry.rpcl_index.cells.len) return CodestreamError.InvalidCodestream;
        return index;
    }

    fn groupsFor(self: *StrictStatefulPrecinctGroups, packet: packet_plan.Packet) ![]StrictPacketAuditBandGroup {
        if (packet.component >= self.initialized_components) return CodestreamError.InvalidCodestream;
        const geometry = try self.geometries.geometryFor(packet.component);
        const slots = self.component_slots[packet.component];
        const index = try slotIndex(geometry, packet);
        if (slots[index] == null) {
            const selected = try geometry.rpcl_index.indexesFor(packet.resolution, packet.precinct_index, 0);
            var slot = Slot{ .groups = undefined, .count = 0 };
            if (selected.len > 0) {
                slot.count = try buildStrictPacketAuditBandGroups(
                    self.allocator,
                    geometry.bands,
                    geometry.blocks,
                    selected,
                    self.header,
                    packet.component,
                    &slot.groups,
                );
            }
            slots[index] = slot;
        }
        const active = &slots[index].?;
        return active.groups[0..active.count];
    }
};

const StrictPacketSpanRead = struct {
    header_length: usize,
    payload_length: usize,
};

/// Open-ended variant of readStrictPacketHeaderForAudit for the PLT-less
/// path: decodes one packet header from the remaining tile-part bytes
/// (mutating the persistent per-precinct states) and reports the header and
/// payload byte lengths so the caller can locate the packet's end without a
/// PLT entry. A present geometry-empty packet is valid and has no body.
fn readStrictPacketHeaderSpan(
    bytes: []const u8,
    packet: packet_plan.Packet,
    groups: []StrictPacketAuditBandGroup,
) !StrictPacketSpanRead {
    var reader = t2.PacketHeaderReader.init(bytes);
    const packet_included = reader.readBit() catch return CodestreamError.InvalidCodestream;
    if (packet_included) {
        for (groups) |*group| {
            t2.readPrecinctPacketHeaderBody(
                &reader,
                &group.reader_state.inclusion,
                &group.reader_state.zero_bitplanes,
                group.reader_state.states,
                packet.layer,
                group.locations,
                group.max_zero_bitplanes,
                group.reader_state.bypass,
                group.reader_state.terminate_all,
                group.decoded,
            ) catch return CodestreamError.InvalidCodestream;
        }
    }
    reader.byteAlign() catch return CodestreamError.InvalidCodestream;
    const header_length = reader.bytesConsumed();

    var payload_length: usize = 0;
    if (packet_included) {
        for (groups) |group| {
            for (group.decoded) |decoded| {
                if (!decoded.included) continue;
                const byte_length = std.math.cast(usize, decoded.byte_length) orelse return CodestreamError.InvalidCodestream;
                payload_length = try std.math.add(usize, payload_length, byte_length);
            }
        }
    }
    return .{ .header_length = header_length, .payload_length = payload_length };
}

fn buildStrictPacketSequence(
    allocator: std.mem.Allocator,
    progression: ProgressionOrder,
    plan: packet_plan.Plan,
    component_count: u16,
    layers: u16,
    main_records: ?[]const poc.Record,
    tile_records: []const poc.Record,
) ![]packet_plan.Packet {
    if (main_records == null and tile_records.len == 0) {
        return buildStreamPacketSequence(allocator, progression, plan, component_count, layers);
    }

    var records: std.ArrayList(poc.Record) = .empty;
    defer records.deinit(allocator);
    if (main_records) |main| try records.appendSlice(allocator, main);
    try records.appendSlice(allocator, tile_records);
    return poc.buildSequence(allocator, plan, component_count, layers, records.items) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return CodestreamError.InvalidCodestream,
    };
}

fn buildSampledStrictPacketSequence(
    allocator: std.mem.Allocator,
    plan: packet_plan.Plan,
    component_count: u16,
    layers: u16,
    component_xrsiz: [max_codestream_components]u8,
    component_yrsiz: [max_codestream_components]u8,
    main_records: ?[]const poc.Record,
    tile_records: []const poc.Record,
) ![]packet_plan.Packet {
    const component_plans = try StrictComponentPacketPlans.init(
        plan,
        component_count,
        layers,
        component_xrsiz,
        component_yrsiz,
    );
    const full = plan.resolutions[plan.resolution_count - 1];
    const canonical = packet_plan.sampledRpclPackets(
        allocator,
        component_plans.components[0..component_count],
        layers,
        full.x0,
        full.y0,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return CodestreamError.InvalidCodestream,
    };
    errdefer allocator.free(canonical);
    if (main_records == null and tile_records.len == 0) return canonical;

    const seen = try allocator.alloc(bool, canonical.len);
    defer allocator.free(seen);
    @memset(seen, false);
    var output_count: usize = 0;
    var reordered = false;
    const RecordSet = struct {
        fn append(
            records: []const poc.Record,
            packets: []const packet_plan.Packet,
            visited: []bool,
            count: *usize,
            changed_order: *bool,
        ) !void {
            for (records) |record| {
                if (record.progression != .rpcl) return CodestreamError.UnsupportedPayload;
                for (packets) |packet| {
                    if (packet.resolution < record.resolution_start or packet.resolution >= record.resolution_end or
                        packet.component < record.component_start or packet.component >= record.component_end or
                        packet.layer >= record.layer_end)
                    {
                        continue;
                    }
                    const identity = std.math.cast(usize, packet.sequence) orelse return CodestreamError.InvalidCodestream;
                    if (identity >= visited.len) return CodestreamError.InvalidCodestream;
                    if (visited[identity]) continue;
                    // This bounded slice accepts explicit POC signalling only
                    // when it preserves canonical sampled RPCL stream order.
                    if (identity != count.*) changed_order.* = true;
                    visited[identity] = true;
                    count.* += 1;
                }
            }
        }
    };
    if (main_records) |records| try RecordSet.append(records, canonical, seen, &output_count, &reordered);
    try RecordSet.append(tile_records, canonical, seen, &output_count, &reordered);
    if (output_count != canonical.len) return CodestreamError.InvalidCodestream;
    if (reordered) return CodestreamError.UnsupportedPayload;
    return canonical;
}

fn readStrictFirstTilePartPocRecords(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    first_sot: usize,
    limits: TilePartPocLimits,
) !std.ArrayList(poc.Record) {
    var expected_tile_part_count: ?u8 = null;
    var expected_ppt_index: u16 = 0;
    var tile_part = try readStrictTilePartHeader(
        allocator,
        bytes,
        first_sot,
        0,
        &expected_tile_part_count,
        null,
        &expected_ppt_index,
        null,
        limits,
    );
    defer tile_part.deinit(allocator);
    const records = tile_part.poc_records;
    tile_part.poc_records = .empty;
    return records;
}

pub const StrictInlinePacketSpan = struct {
    tile_part_index: u8,
    header_offset: usize,
    header_length: usize,
    body_offset: usize,
    body_length: usize,
};

pub const StrictInlineTilePartSpan = struct {
    sot_offset: usize,
    sod_offset: usize,
    end: usize,
};

pub const StrictInlineSpanReport = struct {
    allocator: std.mem.Allocator,
    spans: []StrictInlinePacketSpan,
    tile_parts: []StrictInlineTilePartSpan,
    first_sot: usize,
    eoc_offset: usize,

    pub fn deinit(self: *StrictInlineSpanReport) void {
        self.allocator.free(self.spans);
        self.allocator.free(self.tile_parts);
        self.* = undefined;
    }
};

/// Diagnostic/test-support walk of a strict single-tile codestream with
/// inline packet headers and no PLT/PPT/PPM/SOP/EPH: reports every packet's
/// header and body byte spans in stream order plus the tile-part frame
/// offsets. This is the splitting oracle used to repack inline headers into
/// packed (PPT) form for layouts the encoder cannot produce yet, e.g.
/// subsampled components. Streams outside that envelope fail closed.
pub fn collectStrictInlinePacketSpans(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !StrictInlineSpanReport {
    const header = try readStrictCodestreamMetadata(allocator, bytes);
    if (header.tile_width != 0 or header.tile_height != 0) {
        return collectStrictInlineMultiTileSpans(allocator, bytes, header);
    }
    const plan = temporaryPacketPlan(header);
    const packet_capacity = std.math.cast(usize, header.packet_count) orelse return CodestreamError.InvalidCodestream;

    var main_header = try readStrictMainHeaderIndex(allocator, bytes, header.component_count);
    defer main_header.deinit();
    if (main_header.packet_markers.sop or main_header.packet_markers.eph) {
        return CodestreamError.UnsupportedPayload;
    }
    const poc_limits = TilePartPocLimits{
        .component_count = header.component_count,
        .resolution_count = header.levels + 1,
        .layer_count = header.layers,
    };
    var tile_poc_records = try readStrictFirstTilePartPocRecords(
        allocator,
        bytes,
        main_header.first_sot,
        poc_limits,
    );
    defer tile_poc_records.deinit(allocator);

    const subsampled = headerHasComponentSubsampling(header);
    const sequence = if (subsampled) blk: {
        if (header.progression != .rpcl) return CodestreamError.UnsupportedPayload;
        break :blk try buildSampledStrictPacketSequence(
            allocator,
            plan,
            header.component_count,
            header.layers,
            header.component_xrsiz,
            header.component_yrsiz,
            main_header.poc_records,
            tile_poc_records.items,
        );
    } else try buildStrictPacketSequence(
        allocator,
        header.progression,
        plan,
        header.component_count,
        header.layers,
        main_header.poc_records,
        tile_poc_records.items,
    );
    defer allocator.free(sequence);
    if (sequence.len != packet_capacity) return CodestreamError.InvalidCodestream;

    var spans: std.ArrayList(StrictInlinePacketSpan) = .empty;
    errdefer spans.deinit(allocator);
    var tile_parts: std.ArrayList(StrictInlineTilePartSpan) = .empty;
    errdefer tile_parts.deinit(allocator);

    var stateful = try StrictStatefulPrecinctGroups.init(allocator, header);
    defer stateful.deinit();
    var sequence_index: usize = 0;
    var cursor = main_header.first_sot;
    var eoc_offset: usize = 0;
    var tile_part_index: usize = 0;
    var expected_tile_part_count: ?u8 = null;
    var expected_ppt_index: u16 = 0;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(Marker.eoc)) {
            eoc_offset = cursor;
            cursor += 2;
            if (cursor != bytes.len) return CodestreamError.InvalidCodestream;
            break;
        }
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;

        const sot_offset = cursor;
        var tile_part = try readStrictTilePartHeader(
            allocator,
            bytes,
            cursor,
            tile_part_index,
            &expected_tile_part_count,
            null,
            &expected_ppt_index,
            null,
            poc_limits,
        );
        defer tile_part.deinit(allocator);
        cursor = tile_part.sod + 2;
        if (tile_part.packet_lengths.items.len != 0 or tile_part.packed_headers.items.len != 0) {
            return CodestreamError.UnsupportedPayload;
        }
        try tile_parts.append(allocator, .{
            .sot_offset = sot_offset,
            .sod_offset = tile_part.sod,
            .end = tile_part.end,
        });

        while (cursor < tile_part.end) {
            if (sequence_index >= sequence.len) return CodestreamError.InvalidCodestream;
            const packet = sequence[sequence_index];
            sequence_index += 1;

            const groups = try stateful.groupsFor(packet);
            const span = try readStrictPacketHeaderSpan(bytes[cursor..tile_part.end], packet, groups);
            const header_end = try std.math.add(usize, cursor, span.header_length);
            const packet_end = try std.math.add(usize, header_end, span.payload_length);
            if (packet_end > tile_part.end) return CodestreamError.TruncatedData;
            try spans.append(allocator, .{
                .tile_part_index = @intCast(tile_part_index),
                .header_offset = cursor,
                .header_length = span.header_length,
                .body_offset = header_end,
                .body_length = span.payload_length,
            });
            cursor = packet_end;
        }
        if (cursor != tile_part.end) return CodestreamError.InvalidCodestream;
        tile_part_index += 1;
    }
    if (sequence_index != sequence.len) return CodestreamError.InvalidCodestream;
    if (eoc_offset == 0) return CodestreamError.InvalidCodestream;

    const spans_owned = try spans.toOwnedSlice(allocator);
    errdefer allocator.free(spans_owned);
    const parts_owned = try tile_parts.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .spans = spans_owned,
        .tile_parts = parts_owned,
        .first_sot = main_header.first_sot,
        .eoc_offset = eoc_offset,
    };
}

const StrictInlineTileState = struct {
    header: TemporaryHeader,
    sequence: []packet_plan.Packet,
    stateful: StrictStatefulPrecinctGroups,
};

/// Multi-tile variant of collectStrictInlinePacketSpans: walks the Stage B
/// tile-part spans in stream order with per-tile sequences and stateful
/// precinct groups. The same inline PLT-less SOP/EPH-free envelope applies
/// per tile-part.
fn collectStrictInlineMultiTileSpans(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: TemporaryHeader,
) !StrictInlineSpanReport {
    var context = try readStrictMultiTileContext(allocator, bytes, header);
    defer context.deinit();
    if (context.main_header.packet_markers.sop or context.main_header.packet_markers.eph) {
        return CodestreamError.UnsupportedPayload;
    }

    const tile_count = std.math.cast(usize, context.grid.tileCount()) orelse
        return CodestreamError.InvalidCodestream;
    const states = try allocator.alloc(?StrictInlineTileState, tile_count);
    defer {
        for (states) |*state| {
            if (state.*) |*active| {
                allocator.free(active.sequence);
                active.stateful.deinit();
            }
        }
        allocator.free(states);
    }
    @memset(states, null);

    var spans: std.ArrayList(StrictInlinePacketSpan) = .empty;
    errdefer spans.deinit(allocator);
    var tile_parts: std.ArrayList(StrictInlineTilePartSpan) = .empty;
    errdefer tile_parts.deinit(allocator);

    var stream_end: usize = context.main_header.first_sot;
    for (context.spans.items, 0..) |span, stream_index| {
        const tile_index = std.math.cast(usize, span.tile_index) orelse
            return CodestreamError.InvalidCodestream;
        if (tile_index >= states.len) return CodestreamError.InvalidCodestream;
        if (states[tile_index] == null) {
            const tile = context.grid.tile(span.tile_index) catch return CodestreamError.InvalidCodestream;
            const tile_header = try context.tileHeader(header, tile);
            const tile_plan = temporaryPacketPlan(tile_header);
            var effective_records: std.ArrayList(poc.Record) = .empty;
            defer effective_records.deinit(allocator);
            if (context.main_header.poc_records) |main| {
                try effective_records.appendSlice(allocator, main);
            }
            const main_records: ?[]const poc.Record = if (effective_records.items.len == 0)
                null
            else
                effective_records.items;
            const sequence = if (headerHasComponentSubsampling(tile_header)) blk: {
                if (header.progression != .rpcl) return CodestreamError.UnsupportedPayload;
                break :blk try buildSampledStrictPacketSequence(
                    allocator,
                    tile_plan,
                    tile_header.component_count,
                    header.layers,
                    tile_header.component_xrsiz,
                    tile_header.component_yrsiz,
                    main_records,
                    context.tile_poc_records[tile_index].items,
                );
            } else try buildStrictPacketSequence(
                allocator,
                header.progression,
                tile_plan,
                tile_header.component_count,
                header.layers,
                main_records,
                context.tile_poc_records[tile_index].items,
            );
            errdefer allocator.free(sequence);
            const stateful = try StrictStatefulPrecinctGroups.init(allocator, tile_header);
            states[tile_index] = .{
                .header = tile_header,
                .sequence = sequence,
                .stateful = stateful,
            };
        }
        const state = &states[tile_index].?;

        // The envelope is inline headers only: no PLT, no packed headers.
        if (!span.missing_plt) return CodestreamError.UnsupportedPayload;
        var packet_lengths: std.ArrayList(usize) = .empty;
        defer packet_lengths.deinit(allocator);
        var packed_headers: std.ArrayList(u8) = .empty;
        defer packed_headers.deinit(allocator);
        var expected_ppt_index: u16 = 0;
        const sod = try readTilePartHeaderMarkers(
            allocator,
            bytes,
            span.sot_start + 12,
            span.end,
            &packet_lengths,
            &packed_headers,
            &expected_ppt_index,
            null,
        );
        if (sod != span.sod) return CodestreamError.InvalidCodestream;
        if (packet_lengths.items.len != 0 or packed_headers.items.len != 0) {
            return CodestreamError.UnsupportedPayload;
        }

        try tile_parts.append(allocator, .{
            .sot_offset = span.sot_start,
            .sod_offset = span.sod,
            .end = span.end,
        });

        const sequence_end = try std.math.add(usize, span.first_packet, span.packet_count);
        if (sequence_end > state.sequence.len) return CodestreamError.InvalidCodestream;
        var cursor = span.sod + 2;
        for (state.sequence[span.first_packet..sequence_end]) |packet| {
            const groups = try state.stateful.groupsFor(packet);
            const span_read = try readStrictPacketHeaderSpan(bytes[cursor..span.end], packet, groups);
            const header_end = try std.math.add(usize, cursor, span_read.header_length);
            const packet_end = try std.math.add(usize, header_end, span_read.payload_length);
            if (packet_end > span.end) return CodestreamError.TruncatedData;
            try spans.append(allocator, .{
                .tile_part_index = std.math.cast(u8, stream_index) orelse return CodestreamError.InvalidCodestream,
                .header_offset = cursor,
                .header_length = span_read.header_length,
                .body_offset = header_end,
                .body_length = span_read.payload_length,
            });
            cursor = packet_end;
        }
        if (cursor != span.end) return CodestreamError.InvalidCodestream;
        stream_end = @max(stream_end, span.end);
    }

    if (bytes.len < stream_end + 2 or readU16Be(bytes, stream_end) != @intFromEnum(Marker.eoc)) {
        return CodestreamError.InvalidCodestream;
    }

    const spans_owned = try spans.toOwnedSlice(allocator);
    errdefer allocator.free(spans_owned);
    const parts_owned = try tile_parts.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .spans = spans_owned,
        .tile_parts = parts_owned,
        .first_sot = context.main_header.first_sot,
        .eoc_offset = stream_end,
    };
}

fn readStrictSodPacketCatalog(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    header: TemporaryHeader,
    plan: packet_plan.Plan,
    layers: u16,
    progression: ProgressionOrder,
) !StrictPacketCatalog {
    if (bytes.len < 4 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    var entries: std.ArrayList(StrictPacketEntry) = .empty;
    errdefer entries.deinit(allocator);
    const packet_capacity = std.math.cast(usize, header.packet_count) orelse return CodestreamError.InvalidCodestream;
    try entries.ensureTotalCapacity(allocator, packet_capacity);
    var packet_bytes: std.ArrayList(u8) = .empty;
    errdefer packet_bytes.deinit(allocator);

    var main_header = try readStrictMainHeaderIndex(allocator, bytes, header.component_count);
    defer main_header.deinit();
    const poc_limits = TilePartPocLimits{
        .component_count = header.component_count,
        .resolution_count = header.levels + 1,
        .layer_count = layers,
    };
    var tile_poc_records = try readStrictFirstTilePartPocRecords(
        allocator,
        bytes,
        main_header.first_sot,
        poc_limits,
    );
    defer tile_poc_records.deinit(allocator);
    const subsampled = headerHasComponentSubsampling(header);
    const sequence = if (subsampled) blk: {
        if (progression != .rpcl) {
            return CodestreamError.UnsupportedPayload;
        }
        break :blk try buildSampledStrictPacketSequence(
            allocator,
            plan,
            header.component_count,
            layers,
            header.component_xrsiz,
            header.component_yrsiz,
            main_header.poc_records,
            tile_poc_records.items,
        );
    } else try buildStrictPacketSequence(
        allocator,
        progression,
        plan,
        header.component_count,
        layers,
        main_header.poc_records,
        tile_poc_records.items,
    );
    defer allocator.free(sequence);
    if (sequence.len != packet_capacity) return CodestreamError.InvalidCodestream;
    var sequence_index: usize = 0;
    var stateful: ?StrictStatefulPrecinctGroups = null;
    defer if (stateful) |*groups| groups.deinit();
    var cursor = main_header.first_sot;
    var packet_sequence: u16 = 0;
    var tile_part_index: usize = 0;
    var expected_tile_part_count: ?u8 = null;
    var expected_ppt_index: u16 = 0;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(Marker.eoc)) {
            cursor += 2;
            if (cursor != bytes.len) return CodestreamError.InvalidCodestream;
            if (expected_tile_part_count) |count| {
                if (tile_part_index != count) return CodestreamError.InvalidCodestream;
            }
            if (main_header.tlm_entries) |tlm_slice| {
                if (tile_part_index != tlm_slice.len) return CodestreamError.InvalidCodestream;
            }
            if (entries.items.len != sequence.len or sequence_index != sequence.len) return CodestreamError.InvalidCodestream;

            const owned_entries = try entries.toOwnedSlice(allocator);
            errdefer allocator.free(owned_entries);
            if (!subsampled and (progression != .rpcl or main_header.poc_records != null or tile_poc_records.items.len != 0)) {
                try reorderStrictEntriesToRpcl(allocator, owned_entries, plan, header.component_count, layers);
            }
            const owned_packet_bytes = try packet_bytes.toOwnedSlice(allocator);
            return .{
                .allocator = allocator,
                .entries = owned_entries,
                .packet_bytes = owned_packet_bytes,
            };
        }
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;

        const tlm_entries = if (main_header.tlm_entries) |tlm_slice| tlm_slice else null;
        {
            const external_headers = if (main_header.ppm_headers) |headers|
                try strictPpmGroupAt(headers, tile_part_index)
            else
                null;
            var tile_part = try readStrictTilePartHeader(allocator, bytes, cursor, tile_part_index, &expected_tile_part_count, tlm_entries, &expected_ppt_index, external_headers, poc_limits);
            defer tile_part.deinit(allocator);
            cursor = tile_part.sod + 2;
            if (tile_part.packet_lengths.items.len == 0) {
                if (tile_part.packed_headers.items.len != 0) {
                    if (stateful == null) stateful = try StrictStatefulPrecinctGroups.init(allocator, header);
                    var packed_header_cursor: usize = 0;
                    while (packed_header_cursor < tile_part.packed_headers.items.len) {
                        if (sequence_index >= sequence.len) return CodestreamError.InvalidCodestream;
                        const packet = sequence[sequence_index];
                        sequence_index += 1;
                        const groups = try stateful.?.groupsFor(packet);
                        const byte_offset = packet_bytes.items.len;
                        const byte_length = try appendStrictPackedPacketPayload(
                            allocator,
                            &packet_bytes,
                            bytes,
                            &cursor,
                            tile_part.end,
                            null,
                            tile_part.packed_headers.items,
                            &packed_header_cursor,
                            packet,
                            groups,
                            main_header.packet_markers,
                            &packet_sequence,
                        );
                        try entries.append(allocator, .{
                            .packet = packet,
                            .tile_index = tile_part.sot.tile_index,
                            .tile_part_index = @intCast(tile_part_index),
                            .byte_offset = byte_offset,
                            .byte_length = byte_length,
                        });
                    }
                    if (cursor != tile_part.end) return CodestreamError.InvalidCodestream;
                } else {
                    // Foreign-stream Stage B: no PLT, so each packet's span comes
                    // from decoding its header in stream order with persistent
                    // per-precinct states (non-RPCL progressions revisit precincts
                    // across layers). Tile-part boundaries fall on packet
                    // boundaries, so the walk continues seamlessly across parts.
                    if (stateful == null) {
                        stateful = try StrictStatefulPrecinctGroups.init(allocator, header);
                    }
                    while (cursor < tile_part.end) {
                        if (sequence_index >= sequence.len) return CodestreamError.InvalidCodestream;
                        const packet = sequence[sequence_index];
                        sequence_index += 1;

                        var packet_start = cursor;
                        if (main_header.packet_markers.sop) {
                            if (tile_part.end - packet_start < 6) return CodestreamError.TruncatedData;
                            if (readU16Be(bytes, packet_start) != @intFromEnum(Marker.sop)) return CodestreamError.InvalidCodestream;
                            if (readU16Be(bytes, packet_start + 2) != 4) return CodestreamError.InvalidCodestream;
                            if (readU16Be(bytes, packet_start + 4) != packet_sequence) return CodestreamError.InvalidCodestream;
                            packet_sequence +%= 1;
                            packet_start += 6;
                        }

                        const groups = try stateful.?.groupsFor(packet);
                        const span = try readStrictPacketHeaderSpan(bytes[packet_start..tile_part.end], packet, groups);
                        const header_end = try std.math.add(usize, packet_start, span.header_length);
                        var body_start = header_end;
                        if (main_header.packet_markers.eph) {
                            if (tile_part.end - body_start < 2) return CodestreamError.TruncatedData;
                            if (readU16Be(bytes, body_start) != @intFromEnum(Marker.eph)) return CodestreamError.InvalidCodestream;
                            body_start += 2;
                        }
                        const packet_end = try std.math.add(usize, body_start, span.payload_length);
                        if (packet_end > tile_part.end) return CodestreamError.TruncatedData;

                        const byte_offset = packet_bytes.items.len;
                        try packet_bytes.appendSlice(allocator, bytes[packet_start..header_end]);
                        try packet_bytes.appendSlice(allocator, bytes[body_start..packet_end]);
                        const byte_length = std.math.cast(u32, span.header_length + span.payload_length) orelse return CodestreamError.InvalidCodestream;
                        try entries.append(allocator, .{
                            .packet = packet,
                            .tile_index = tile_part.sot.tile_index,
                            .tile_part_index = @intCast(tile_part_index),
                            .byte_offset = byte_offset,
                            .byte_length = byte_length,
                        });
                        cursor = packet_end;
                    }
                    if (cursor != tile_part.end) return CodestreamError.InvalidCodestream;
                }
            } else {
                try packet_bytes.ensureTotalCapacity(allocator, try std.math.add(usize, packet_bytes.items.len, tile_part.packet_payload_bytes));
                var packed_header_cursor: usize = 0;
                if (tile_part.packed_headers.items.len != 0) {
                    if (stateful == null) stateful = try StrictStatefulPrecinctGroups.init(allocator, header);
                }
                for (tile_part.packet_lengths.items) |packet_length| {
                    if (sequence_index >= sequence.len) return CodestreamError.InvalidCodestream;
                    const packet = sequence[sequence_index];
                    sequence_index += 1;
                    const byte_offset = packet_bytes.items.len;
                    const byte_length = if (tile_part.packed_headers.items.len != 0) blk: {
                        const groups = try stateful.?.groupsFor(packet);
                        break :blk try appendStrictPackedPacketPayload(
                            allocator,
                            &packet_bytes,
                            bytes,
                            &cursor,
                            tile_part.end,
                            packet_length,
                            tile_part.packed_headers.items,
                            &packed_header_cursor,
                            packet,
                            groups,
                            main_header.packet_markers,
                            &packet_sequence,
                        );
                    } else try appendStrictSodPacketPayload(
                        allocator,
                        &packet_bytes,
                        bytes,
                        &cursor,
                        tile_part.end,
                        packet_length,
                        main_header.packet_markers,
                        &packet_sequence,
                    );
                    try entries.append(allocator, .{
                        .packet = packet,
                        .tile_index = tile_part.sot.tile_index,
                        .tile_part_index = @intCast(tile_part_index),
                        .byte_offset = byte_offset,
                        .byte_length = byte_length,
                    });
                }
                if (packed_header_cursor != tile_part.packed_headers.items.len) return CodestreamError.InvalidCodestream;
                if (cursor != tile_part.end) return CodestreamError.InvalidCodestream;
            }
            cursor = tile_part.end;
        }
        tile_part_index += 1;
    }

    return CodestreamError.InvalidCodestream;
}

fn readStrictTilePartPacketPlan(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    first_sot: usize,
    tlm_entries: ?[]const TlmEntry,
    ppm_headers: ?ppm.PackedHeaders,
    poc_limits: TilePartPocLimits,
) !StrictTilePartPacketPlan {
    var result = StrictTilePartPacketPlan{};
    var expected_tile_part_count: ?u8 = null;
    var expected_ppt_index: u16 = 0;
    var scan = first_sot;
    while (scan < bytes.len) {
        if (bytes.len - scan < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, scan);
        if (marker == @intFromEnum(Marker.eoc)) {
            scan += 2;
            if (scan != bytes.len) return CodestreamError.InvalidCodestream;
            if (expected_tile_part_count) |count| {
                if (result.count != @as(usize, count)) return CodestreamError.InvalidCodestream;
            }
            if (tlm_entries) |entries| {
                if (result.count != entries.len) return CodestreamError.InvalidCodestream;
            }
            if (ppm_headers) |headers| {
                const group_count = headers.validate() catch return CodestreamError.InvalidCodestream;
                if (group_count != result.count) return CodestreamError.InvalidCodestream;
            }
            return result;
        }
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;
        if (result.count == result.packet_counts.len) return CodestreamError.InvalidCodestream;

        {
            const external_headers = if (ppm_headers) |headers|
                try strictPpmGroupAt(headers, result.count)
            else
                null;
            var tile_part = try readStrictTilePartHeader(
                allocator,
                bytes,
                scan,
                result.count,
                &expected_tile_part_count,
                tlm_entries,
                &expected_ppt_index,
                external_headers,
                poc_limits,
            );
            defer tile_part.deinit(allocator);
            if (tile_part.packet_lengths.items.len == 0) {
                result.missing_plt = true;
            }
            result.packet_counts[result.count] = tile_part.packet_lengths.items.len;
            result.count += 1;
            scan = tile_part.end;
        }
    }

    return CodestreamError.InvalidCodestream;
}

fn strictPpmGroupAt(headers: ppm.PackedHeaders, index: usize) ![]const u8 {
    return (headers.groupAt(index) catch return CodestreamError.InvalidCodestream) orelse
        return CodestreamError.InvalidCodestream;
}

/// One tile-part of a multi-tile stream, located by the Stage B SOT walk
/// (docs/multi_tile_plan.md): byte spans for the SOT segment, the packet
/// payload behind SOD, and the PLT-counted packet count validated against the
/// tile's own packet plan. PPM-backed spans derive their packet counts from
/// RPCL resolution parts and their body lengths from decoded packed headers.
/// Stage C consumes these spans for per-tile decode.
const StrictMultiTileTilePartSpan = struct {
    stream_index: usize,
    tile_index: u16,
    tile_part_index: u8,
    tile_part_count: u8,
    first_packet: usize,
    sot_start: usize,
    sod: usize,
    end: usize,
    packet_payload_bytes: usize,
    packet_count: usize,
    missing_plt: bool = false,
};

/// Walks a multi-tile tile-part sequence. One-part tiles remain accepted in
/// any unique tile order. RPCL resolution divisions additionally accept
/// `levels + 1` consecutive parts per tile and validate each part against the
/// corresponding resolution packet range. PLT-less multi-part streams remain
/// fail-closed until cross-part open-ended T2 span derivation is implemented.
fn readStrictMultiTileTilePartSpans(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    first_sot: usize,
    grid: tile_grid.Grid,
    levels: u8,
    options: LosslessOptions,
    component_count: u16,
    component_xrsiz: [max_codestream_components]u8,
    component_yrsiz: [max_codestream_components]u8,
    tlm_entries: ?[]const TlmEntry,
    ppm_headers: ?ppm.PackedHeaders,
    tile_poc_records: []std.ArrayList(poc.Record),
) !std.ArrayList(StrictMultiTileTilePartSpan) {
    const tile_count = grid.tileCount();
    if (tile_count > std.math.maxInt(u16)) return CodestreamError.UnsupportedPayload;
    const tile_count_usize = std.math.cast(usize, tile_count) orelse return CodestreamError.UnsupportedPayload;
    const next_parts = try allocator.alloc(u8, tile_count_usize);
    defer allocator.free(next_parts);
    @memset(next_parts, 0);
    const expected_parts = try allocator.alloc(u8, tile_count_usize);
    defer allocator.free(expected_parts);
    @memset(expected_parts, 0);
    const completed_tiles = try allocator.alloc(bool, tile_count_usize);
    defer allocator.free(completed_tiles);
    @memset(completed_tiles, false);
    // Running packet cursor per tile: multi-part tiles consume their packet
    // sequence across parts in TPsot order, each part's packet count coming
    // from its own PLT.
    const tile_next_packet = try allocator.alloc(usize, tile_count_usize);
    defer allocator.free(tile_next_packet);
    @memset(tile_next_packet, 0);
    // Tile plan packet totals recorded on first sight, so tiles whose part
    // count is never signalled (TNsot stays 0) can be completed by packet
    // accounting at EOC.
    const tile_plan_totals = try allocator.alloc(usize, tile_count_usize);
    defer allocator.free(tile_plan_totals);
    @memset(tile_plan_totals, 0);
    const expected_ppt_indices = try allocator.alloc(u16, tile_count_usize);
    defer allocator.free(expected_ppt_indices);
    @memset(expected_ppt_indices, 0);

    var spans: std.ArrayList(StrictMultiTileTilePartSpan) = .empty;
    errdefer spans.deinit(allocator);

    var scan = first_sot;
    var tile_part_index: usize = 0;
    while (scan < bytes.len) {
        if (bytes.len - scan < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, scan);
        if (marker == @intFromEnum(Marker.eoc)) {
            scan += 2;
            if (scan != bytes.len) return CodestreamError.InvalidCodestream;
            for (completed_tiles, 0..) |completed, index| {
                if (completed) continue;
                // A tile whose part count was never signalled (TNsot 0 in
                // every part, ISO A.4.2) is complete once its parts consumed
                // the whole tile packet plan.
                if (expected_parts[index] == 0 and next_parts[index] > 0 and
                    tile_next_packet[index] == tile_plan_totals[index])
                {
                    continue;
                }
                return CodestreamError.InvalidCodestream;
            }
            if (tlm_entries) |entries| {
                if (entries.len != tile_part_index) return CodestreamError.InvalidCodestream;
            }
            if (ppm_headers) |headers| {
                const group_count = headers.validate() catch return CodestreamError.InvalidCodestream;
                if (group_count != tile_part_index) return CodestreamError.InvalidCodestream;
            }
            return spans;
        }
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;
        const sot = try readStrictSotInfo(bytes, scan);
        if (tlm_entries) |entries| {
            try validateStrictTlmEntry(entries, tile_part_index, sot.tile_index, sot.psot);
        }
        if (sot.tile_index >= tile_count) return CodestreamError.InvalidCodestream;
        const tile_index = @as(usize, sot.tile_index);
        if (tile_index >= tile_poc_records.len) return CodestreamError.InvalidCodestream;
        if (completed_tiles[tile_index]) return CodestreamError.InvalidCodestream;
        // TNsot == 0 means "part count not signalled in this part"
        // (ISO A.4.2); a later part of the tile may carry the real count.
        // Once any part signals a nonzero count, every later nonzero value
        // must agree and must exceed the current part index.
        if (sot.tile_part_count != 0) {
            if (sot.tile_part_count <= sot.tile_part_index) return CodestreamError.InvalidCodestream;
            if (expected_parts[tile_index] == 0) {
                expected_parts[tile_index] = sot.tile_part_count;
            } else if (expected_parts[tile_index] != sot.tile_part_count) {
                return CodestreamError.InvalidCodestream;
            }
        }
        if (sot.tile_part_index != next_parts[tile_index]) return CodestreamError.InvalidCodestream;

        const tile_part_end = try std.math.add(usize, scan, sot.psot);
        if (tile_part_end > bytes.len or tile_part_end < scan + 12) {
            return CodestreamError.TruncatedData;
        }

        var packet_lengths: std.ArrayList(usize) = .empty;
        defer packet_lengths.deinit(allocator);
        var packed_headers: std.ArrayList(u8) = .empty;
        defer packed_headers.deinit(allocator);
        const sod = try readTilePartHeaderMarkers(
            allocator,
            bytes,
            scan + 12,
            tile_part_end,
            &packet_lengths,
            &packed_headers,
            &expected_ppt_indices[tile_index],
            .{
                .records = &tile_poc_records[tile_index],
                .limits = .{
                    .component_count = component_count,
                    .resolution_count = levels + 1,
                    .layer_count = options.layers,
                },
                .allowed = sot.tile_part_index == 0,
            },
        );
        const external_headers = if (ppm_headers) |headers|
            try strictPpmGroupAt(headers, tile_part_index)
        else
            null;
        if (external_headers != null and packed_headers.items.len != 0) {
            return CodestreamError.InvalidCodestream;
        }

        const tile = grid.tile(sot.tile_index) catch return CodestreamError.InvalidCodestream;
        const tile_plan = try makeAggregatePacketPlanForTile(
            tile,
            levels,
            component_count,
            options,
            component_xrsiz,
            component_yrsiz,
        );
        const plan_packets = std.math.cast(usize, tile_plan.packets) orelse return CodestreamError.InvalidCodestream;
        tile_plan_totals[tile_index] = plan_packets;
        const missing_plt = packet_lengths.items.len == 0;
        // Multi-part tiles are accepted in any progression when every
        // non-empty part carries PLT: each part's packet count comes from
        // its own PLT, the parts consume the tile's packet sequence in TPsot
        // order, and the completed tile must land exactly on the tile plan
        // total (z2000's own per-resolution `R` divisions are one instance
        // of this rule). Empty padding parts (SOT+SOD only, zero packets —
        // Kakadu pads tiles to a fixed TNsot this way) need no PLT.
        // Non-empty PLT-less multi-part tiles stay fail-closed unless PPM
        // supplies the headers and RPCL/R supplies an exact packet count.
        if (missing_plt and sot.tile_part_count != 1 and external_headers == null) {
            const payload_start = try std.math.add(usize, sod, 2);
            if (payload_start != tile_part_end) return CodestreamError.UnsupportedPayload;
        }
        var first_packet: usize = 0;
        var expected_packet_count = plan_packets;
        if (sot.tile_part_count != 1) {
            first_packet = tile_next_packet[tile_index];
            expected_packet_count = if (missing_plt and external_headers != null) blk: {
                if (options.progression != .rpcl or sot.tile_part_count != @as(u8, @intCast(levels + 1))) {
                    return CodestreamError.UnsupportedPayload;
                }
                if (sot.tile_part_index >= tile_plan.resolution_count) return CodestreamError.InvalidCodestream;
                break :blk std.math.cast(usize, tile_plan.resolutions[sot.tile_part_index].packets) orelse
                    return CodestreamError.InvalidCodestream;
            } else packet_lengths.items.len;
            const end_packet = try std.math.add(usize, first_packet, expected_packet_count);
            if (end_packet > plan_packets) return CodestreamError.InvalidCodestream;
            const is_last_part = next_parts[tile_index] + 1 == expected_parts[tile_index];
            if (is_last_part and end_packet != plan_packets) return CodestreamError.InvalidCodestream;
        }
        const packet_payload_bytes = if (missing_plt) blk: {
            const payload_start = try std.math.add(usize, sod, 2);
            if (payload_start > tile_part_end) return CodestreamError.TruncatedData;
            break :blk tile_part_end - payload_start;
        } else try validateStrictTilePartPacketSpan(
            sod,
            tile_part_end,
            packet_lengths.items,
            external_headers != null or packed_headers.items.len != 0,
        );
        const packet_count = if (missing_plt)
            expected_packet_count
        else blk: {
            if (packet_lengths.items.len != expected_packet_count) return CodestreamError.InvalidCodestream;
            break :blk packet_lengths.items.len;
        };

        try spans.append(allocator, .{
            .stream_index = tile_part_index,
            .tile_index = sot.tile_index,
            .tile_part_index = sot.tile_part_index,
            .tile_part_count = sot.tile_part_count,
            .first_packet = first_packet,
            .sot_start = scan,
            .sod = sod,
            .end = tile_part_end,
            .packet_payload_bytes = packet_payload_bytes,
            .packet_count = packet_count,
            .missing_plt = missing_plt,
        });
        tile_next_packet[tile_index] = try std.math.add(usize, first_packet, packet_count);
        next_parts[tile_index] = std.math.add(u8, next_parts[tile_index], 1) catch return CodestreamError.InvalidCodestream;
        if (expected_parts[tile_index] != 0 and next_parts[tile_index] == expected_parts[tile_index]) {
            completed_tiles[tile_index] = true;
        }
        tile_part_index += 1;
        scan = tile_part_end;
    }

    return CodestreamError.InvalidCodestream;
}

fn readStrictTilePartHeader(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    marker_start: usize,
    tile_part_index: usize,
    expected_tile_part_count: *?u8,
    tlm_entries: ?[]const TlmEntry,
    expected_ppt_index: *u16,
    external_packed_headers: ?[]const u8,
    poc_limits: ?TilePartPocLimits,
) !StrictTilePartHeader {
    const sot = try readStrictSotInfo(bytes, marker_start);
    try validateStrictSotSequence(sot, tile_part_index, expected_tile_part_count);
    if (tlm_entries) |entries| {
        try validateStrictTlmEntry(entries, tile_part_index, sot.tile_index, sot.psot);
    }

    const tile_part_end = try std.math.add(usize, marker_start, sot.psot);
    if (tile_part_end > bytes.len or tile_part_end < marker_start + 12) {
        return CodestreamError.TruncatedData;
    }

    var packet_lengths: std.ArrayList(usize) = .empty;
    errdefer packet_lengths.deinit(allocator);
    var packed_headers: std.ArrayList(u8) = .empty;
    errdefer packed_headers.deinit(allocator);
    var poc_records: std.ArrayList(poc.Record) = .empty;
    errdefer poc_records.deinit(allocator);
    const sod = try readTilePartHeaderMarkers(
        allocator,
        bytes,
        marker_start + 12,
        tile_part_end,
        &packet_lengths,
        &packed_headers,
        expected_ppt_index,
        if (poc_limits) |limits| .{
            .records = &poc_records,
            .limits = limits,
            .allowed = sot.tile_part_index == 0,
        } else null,
    );
    if (external_packed_headers) |headers| {
        if (packed_headers.items.len != 0 or headers.len == 0) return CodestreamError.InvalidCodestream;
        try packed_headers.appendSlice(allocator, headers);
    }
    const packet_payload_bytes = try validateStrictTilePartPacketSpan(
        sod,
        tile_part_end,
        packet_lengths.items,
        external_packed_headers != null or packed_headers.items.len != 0,
    );

    return .{
        .sot = sot,
        .sod = sod,
        .end = tile_part_end,
        .packet_payload_bytes = packet_payload_bytes,
        .packet_lengths = packet_lengths,
        .packed_headers = packed_headers,
        .poc_records = poc_records,
    };
}

fn validateStrictTilePartPacketSpan(
    sod: usize,
    tile_part_end: usize,
    packet_lengths: []const usize,
    allow_zero_lengths: bool,
) !usize {
    if (packet_lengths.len == 0) return 0;
    const payload_start = try std.math.add(usize, sod, 2);
    if (payload_start > tile_part_end) return CodestreamError.TruncatedData;

    var payload_bytes: usize = 0;
    for (packet_lengths) |packet_length| {
        if (packet_length == 0 and !allow_zero_lengths) return CodestreamError.InvalidCodestream;
        payload_bytes = try std.math.add(usize, payload_bytes, packet_length);
    }
    if (payload_bytes != tile_part_end - payload_start) return CodestreamError.InvalidCodestream;
    return payload_bytes;
}

fn validateStrictTilePartSequenceFinished(tile_part_count: usize, expected_tile_part_count: ?u8) !void {
    if (expected_tile_part_count) |count| {
        if (tile_part_count != @as(usize, count)) return CodestreamError.InvalidCodestream;
    }
}

fn validateStrictTilePartPacketPlan(
    tile_parts: StrictTilePartPacketPlan,
    plan: packet_plan.Plan,
    levels: u8,
) !TilePartPlan {
    if (tile_parts.count == 0) return CodestreamError.InvalidCodestream;
    if (tile_parts.missing_plt) {
        // PLT-less stream: per-part packet counts are unknown here; the
        // catalog stage validates the total against the plan when it decodes
        // the headers in stream order.
        return emptyTilePartPlan();
    }
    if (tile_parts.count == plan.resolution_count) {
        var resolution: usize = 0;
        while (resolution < plan.resolution_count) : (resolution += 1) {
            if (@as(u64, @intCast(tile_parts.packet_counts[resolution])) != plan.resolutions[resolution].packets) {
                return CodestreamError.InvalidCodestream;
            }
        }
        return resolutionTilePartPlan(levels);
    }
    if (tile_parts.count == 1) {
        if (@as(u64, @intCast(tile_parts.packet_counts[0])) != plan.packets) return CodestreamError.InvalidCodestream;
        return emptyTilePartPlan();
    }
    return CodestreamError.UnsupportedPayload;
}

fn readStrictSotInfo(bytes: []const u8, marker_start: usize) !StrictSotInfo {
    if (bytes.len - marker_start < 12) return CodestreamError.TruncatedData;
    if (readU16Be(bytes, marker_start) != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;
    const segment_length = readU16Be(bytes, marker_start + 2);
    if (segment_length != 10) return CodestreamError.InvalidCodestream;
    const psot = readU32Be(bytes, marker_start + 6);
    if (psot == 0) return CodestreamError.UnsupportedPayload;
    return .{
        .tile_index = readU16Be(bytes, marker_start + 4),
        .psot = psot,
        .tile_part_index = bytes[marker_start + 10],
        .tile_part_count = bytes[marker_start + 11],
    };
}

fn validateStrictSotSequence(
    sot: StrictSotInfo,
    tile_part_index: usize,
    expected_tile_part_count: *?u8,
) !void {
    if (sot.tile_index != 0) return CodestreamError.UnsupportedPayload;
    if (tile_part_index > std.math.maxInt(u8)) return CodestreamError.InvalidCodestream;
    if (sot.tile_part_index != @as(u8, @intCast(tile_part_index))) return CodestreamError.InvalidCodestream;
    if (sot.tile_part_count == 0) return CodestreamError.UnsupportedPayload;
    if (sot.tile_part_count <= sot.tile_part_index) return CodestreamError.InvalidCodestream;
    if (expected_tile_part_count.*) |count| {
        if (sot.tile_part_count != count) return CodestreamError.InvalidCodestream;
    } else {
        expected_tile_part_count.* = sot.tile_part_count;
    }
}

fn readStrictMainHeaderIndex(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    component_count: u16,
) !StrictMainHeaderIndex {
    if (component_count < 1 or component_count > max_codestream_components) return CodestreamError.UnsupportedPayload;
    if (bytes.len < 4 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    var entries: std.ArrayList(TlmEntry) = .empty;
    errdefer entries.deinit(allocator);
    var saw_tlm = false;
    var next_tlm_index: usize = 0;
    var packet_markers: ?MainHeaderPacketMarkers = null;
    var cod_levels: ?u8 = null;
    var cod_layers: ?u16 = null;
    var ppm_collector = ppm.SegmentCollector.init(allocator);
    defer ppm_collector.deinit();
    var poc_records: std.ArrayList(poc.Record) = .empty;
    defer poc_records.deinit(allocator);

    var cursor: usize = 2;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 4) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        cursor += 2;
        if (marker == @intFromEnum(Marker.sot)) {
            const markers = packet_markers orelse return CodestreamError.InvalidCodestream;
            const owned_entries = if (saw_tlm) try entries.toOwnedSlice(allocator) else null;
            errdefer if (owned_entries) |owned| allocator.free(owned);
            const owned_poc = if (poc_records.items.len != 0) try poc_records.toOwnedSlice(allocator) else null;
            errdefer if (owned_poc) |owned| allocator.free(owned);
            const ppm_headers = if (ppm_collector.expected_index != 0)
                ppm_collector.finish() catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return CodestreamError.InvalidCodestream,
                }
            else
                null;
            return .{
                .allocator = allocator,
                .first_sot = cursor - 2,
                .packet_markers = markers,
                .tlm_entries = owned_entries,
                .ppm_headers = ppm_headers,
                .poc_records = owned_poc,
            };
        }
        if (marker == @intFromEnum(Marker.sod) or marker == @intFromEnum(Marker.eoc)) {
            return CodestreamError.InvalidCodestream;
        }

        const segment_length = readU16Be(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) {
            return CodestreamError.TruncatedData;
        }
        const segment = bytes[cursor + 2 .. cursor + segment_length];
        if (marker == @intFromEnum(Marker.cod)) {
            if (packet_markers != null or segment.len < 10) return CodestreamError.InvalidCodestream;
            packet_markers = .{
                .sop = (segment[0] & 0x02) != 0,
                .eph = (segment[0] & 0x04) != 0,
            };
            cod_layers = readU16Be(segment, 2);
            cod_levels = segment[5];
        } else if (marker == @intFromEnum(Marker.tlm)) {
            try appendStrictTlmEntries(allocator, &entries, segment, next_tlm_index);
            saw_tlm = true;
            next_tlm_index += 1;
        } else if (marker == @intFromEnum(Marker.ppm)) {
            ppm_collector.append(segment) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return CodestreamError.InvalidCodestream,
            };
        } else if (marker == @intFromEnum(Marker.poc)) {
            const levels = cod_levels orelse return CodestreamError.InvalidCodestream;
            const layers = cod_layers orelse return CodestreamError.InvalidCodestream;
            poc.appendSegment(allocator, &poc_records, segment, component_count, levels + 1, layers) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return CodestreamError.InvalidCodestream,
            };
        }
        cursor += segment_length;
    }
    return CodestreamError.InvalidCodestream;
}

fn appendStrictTlmEntries(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(TlmEntry),
    segment: []const u8,
    expected_index: usize,
) !void {
    if (segment.len < 2) return CodestreamError.InvalidCodestream;
    const ztlm = segment[0];
    if (expected_index > std.math.maxInt(u8) or ztlm != @as(u8, @intCast(expected_index))) {
        return CodestreamError.InvalidCodestream;
    }
    const stlm = segment[1];
    if ((stlm & 0x0f) != 0) return CodestreamError.InvalidCodestream;
    const tile_index_size = (stlm >> 4) & 0x03;
    if (tile_index_size == 3) return CodestreamError.InvalidCodestream;
    const length_size: usize = if (((stlm >> 6) & 0x01) == 0) 2 else 4;
    const entry_size = @as(usize, tile_index_size) + length_size;
    const payload = segment[2..];
    if (entry_size == 0 or payload.len == 0 or payload.len % entry_size != 0) {
        return CodestreamError.InvalidCodestream;
    }

    var cursor: usize = 0;
    while (cursor < payload.len) : (cursor += entry_size) {
        const tile_index: u16 = switch (tile_index_size) {
            0 => 0,
            1 => payload[cursor],
            2 => readU16Be(payload, cursor),
            else => unreachable,
        };
        const ptlm_offset = cursor + @as(usize, tile_index_size);
        const psot: u32 = switch (length_size) {
            2 => readU16Be(payload, ptlm_offset),
            4 => readU32Be(payload, ptlm_offset),
            else => unreachable,
        };
        if (psot == 0) return CodestreamError.UnsupportedPayload;
        try entries.append(allocator, .{ .tile_index = tile_index, .psot = psot });
    }
}

fn validateStrictTlmEntry(entries: []const TlmEntry, tile_part_index: usize, tile_index: u16, psot: u32) !void {
    if (tile_part_index >= entries.len) return CodestreamError.InvalidCodestream;
    const entry = entries[tile_part_index];
    if (entry.tile_index != tile_index or entry.psot != psot) return CodestreamError.InvalidCodestream;
}

fn packetEphOffsetRejectingSop(bytes: []const u8, start: usize, end: usize) !?usize {
    var eph_offset: ?usize = null;
    var cursor = start;
    while (cursor + 1 < end) {
        const searchable = bytes[cursor .. end - 1];
        const relative = std.mem.indexOfScalar(u8, searchable, 0xff) orelse break;
        const offset = cursor + relative;
        const marker = readU16Be(bytes, offset);
        if (marker == @intFromEnum(Marker.sop)) return CodestreamError.InvalidCodestream;
        if (marker == @intFromEnum(Marker.eph)) {
            if (eph_offset != null) return CodestreamError.InvalidCodestream;
            eph_offset = offset;
        }
        cursor = offset + 1;
    }
    return eph_offset;
}

fn appendStrictSodPackets(
    allocator: std.mem.Allocator,
    lengths: *std.ArrayList(u32),
    packet_bytes: *std.ArrayList(u8),
    bytes: []const u8,
    start: usize,
    end: usize,
    packet_lengths: []const usize,
    marker_policy: MainHeaderPacketMarkers,
    packet_sequence: *u16,
) !void {
    var cursor = start;
    for (packet_lengths) |packet_length| {
        const payload_len_u32 = try appendStrictSodPacketPayload(
            allocator,
            packet_bytes,
            bytes,
            &cursor,
            end,
            packet_length,
            marker_policy,
            packet_sequence,
        );
        try lengths.append(allocator, payload_len_u32);
    }
    if (cursor != end) return CodestreamError.InvalidCodestream;
}

fn appendStrictSodPacketPayload(
    allocator: std.mem.Allocator,
    packet_bytes: *std.ArrayList(u8),
    bytes: []const u8,
    cursor: *usize,
    end: usize,
    framed_packet_length: usize,
    marker_policy: MainHeaderPacketMarkers,
    packet_sequence: *u16,
) !u32 {
    const frame_start = cursor.*;
    if (frame_start > end) return CodestreamError.TruncatedData;
    const packet_end = try std.math.add(usize, frame_start, framed_packet_length);
    if (packet_end > end) return CodestreamError.TruncatedData;

    var packet_start = frame_start;
    if (marker_policy.sop) {
        if (packet_end - frame_start < 6) return CodestreamError.TruncatedData;
        if (readU16Be(bytes, frame_start) != @intFromEnum(Marker.sop)) return CodestreamError.InvalidCodestream;
        const segment_length = readU16Be(bytes, packet_start + 2);
        if (segment_length != 4) return CodestreamError.InvalidCodestream;
        const sequence = readU16Be(bytes, packet_start + 4);
        if (sequence != packet_sequence.*) return CodestreamError.InvalidCodestream;
        packet_sequence.* +%= 1;
        packet_start += 6;
    }

    const eph_offset = try packetEphOffsetRejectingSop(bytes, packet_start, packet_end);
    if (marker_policy.eph != (eph_offset != null)) return CodestreamError.InvalidCodestream;

    const payload_len = packet_end - packet_start - (if (eph_offset != null) @as(usize, 2) else 0);
    const payload_len_u32 = std.math.cast(u32, payload_len) orelse return CodestreamError.InvalidCodestream;
    if (eph_offset) |offset| {
        try packet_bytes.appendSlice(allocator, bytes[packet_start..offset]);
        try packet_bytes.appendSlice(allocator, bytes[offset + 2 .. packet_end]);
    } else {
        try packet_bytes.appendSlice(allocator, bytes[packet_start..packet_end]);
    }
    cursor.* = packet_end;
    return payload_len_u32;
}

fn appendStrictPackedPacketPayload(
    allocator: std.mem.Allocator,
    packet_bytes: *std.ArrayList(u8),
    bytes: []const u8,
    body_cursor: *usize,
    body_end: usize,
    signalled_body_length: ?usize,
    packed_headers: []const u8,
    header_cursor: *usize,
    packet: packet_plan.Packet,
    groups: []StrictPacketAuditBandGroup,
    marker_policy: MainHeaderPacketMarkers,
    packet_sequence: *u16,
) !u32 {
    if (header_cursor.* >= packed_headers.len) return CodestreamError.TruncatedData;
    const span = try readStrictPacketHeaderSpan(packed_headers[header_cursor.*..], packet, groups);
    const header_end = try std.math.add(usize, header_cursor.*, span.header_length);
    if (header_end > packed_headers.len) return CodestreamError.TruncatedData;
    var next_header = header_end;
    if (marker_policy.eph) {
        if (packed_headers.len - next_header < 2) return CodestreamError.TruncatedData;
        if (readU16Be(packed_headers, next_header) != @intFromEnum(Marker.eph)) {
            return CodestreamError.InvalidCodestream;
        }
        next_header += 2;
    } else if (packed_headers.len - next_header >= 2 and
        readU16Be(packed_headers, next_header) == @intFromEnum(Marker.eph))
    {
        return CodestreamError.InvalidCodestream;
    }

    var body_start = body_cursor.*;
    if (marker_policy.sop) {
        if (body_end - body_start < 6) return CodestreamError.TruncatedData;
        if (readU16Be(bytes, body_start) != @intFromEnum(Marker.sop) or
            readU16Be(bytes, body_start + 2) != 4 or
            readU16Be(bytes, body_start + 4) != packet_sequence.*)
        {
            return CodestreamError.InvalidCodestream;
        }
        packet_sequence.* +%= 1;
        body_start += 6;
    } else if (body_end - body_start >= 2 and
        readU16Be(bytes, body_start) == @intFromEnum(Marker.sop))
    {
        return CodestreamError.InvalidCodestream;
    }
    if (signalled_body_length) |length| {
        const expected_length = try std.math.add(usize, span.payload_length, if (marker_policy.sop) 6 else 0);
        if (length != expected_length) return CodestreamError.InvalidCodestream;
    }
    const packet_end = try std.math.add(usize, body_start, span.payload_length);
    if (packet_end > body_end) return CodestreamError.TruncatedData;

    try packet_bytes.appendSlice(allocator, packed_headers[header_cursor.*..header_end]);
    try packet_bytes.appendSlice(allocator, bytes[body_start..packet_end]);
    header_cursor.* = next_header;
    body_cursor.* = packet_end;
    return std.math.cast(u32, span.header_length + span.payload_length) orelse return CodestreamError.InvalidCodestream;
}

fn readComponentPayload(cursor: *Cursor, plane: []i32, stride: usize, expected_component: u8, payload_version: u8, layer_count: u16) !void {
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
        const coding_passes = try readStoredCodingPasses(cursor, payload_version, bitplanes, non_zero_count);
        _ = try readLayerAllocation(cursor, payload_version, layer_count, coding_passes);
        var significance = try readEntropyStream(cursor);
        defer significance.deinit(cursor.allocator);
        var refinement = try readEntropyStream(cursor);
        defer refinement.deinit(cursor.allocator);
        var cleanup = try readEntropyStream(cursor);
        defer cleanup.deinit(cursor.allocator);
        const ebcot_segment = try readEbcotSegmentInfo(cursor, payload_version, coding_passes);
        try skipEbcotSegmentPayload(cursor, payload_version, ebcot_segment.mq_bytes);
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

const DecodeComponentPayloadJob = struct {
    bytes: []const u8,
    plane: []i32,
    stride: usize,
    component_index: u8,
    payload_version: u8,
    layer_count: u16,
    result: anyerror!void = {},
};

fn readComponentPayloads(
    cursor: *Cursor,
    y: []i32,
    cb: []i32,
    cr: []i32,
    stride: usize,
    payload_version: u8,
    layer_count: u16,
    options: DecodeOptions,
) !void {
    if (componentThreadCountFor(options.threads) < 2) {
        try readComponentPayload(cursor, y, stride, 0, payload_version, layer_count);
        try readComponentPayload(cursor, cb, stride, 1, payload_version, layer_count);
        try readComponentPayload(cursor, cr, stride, 2, payload_version, layer_count);
        return;
    }

    const slices = try readComponentPayloadSlices(cursor, payload_version, layer_count);
    var jobs = [_]DecodeComponentPayloadJob{
        .{ .bytes = slices[0], .plane = y, .stride = stride, .component_index = 0, .payload_version = payload_version, .layer_count = layer_count },
        .{ .bytes = slices[1], .plane = cb, .stride = stride, .component_index = 1, .payload_version = payload_version, .layer_count = layer_count },
        .{ .bytes = slices[2], .plane = cr, .stride = stride, .component_index = 2, .payload_version = payload_version, .layer_count = layer_count },
    };
    try runComponentJobs(DecodeComponentPayloadJob, &jobs, componentThreadCountFor(options.threads), decodeComponentPayloadWorker);
}

fn readComponentPayloadSlices(cursor: *Cursor, payload_version: u8, layer_count: u16) ![3][]const u8 {
    var slices: [3][]const u8 = undefined;
    inline for (0..3) |component| {
        const start = cursor.index;
        try skipComponentPayload(cursor, component, payload_version, layer_count);
        slices[component] = cursor.bytes[start..cursor.index];
    }
    return slices;
}

fn skipComponentPayload(cursor: *Cursor, comptime expected_component: u8, payload_version: u8, layer_count: u16) !void {
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
        _ = try cursor.readRect();
        const bitplanes = try cursor.readU8();
        const non_zero_count = try cursor.readU32();
        const coding_passes = try readStoredCodingPasses(cursor, payload_version, bitplanes, non_zero_count);
        _ = try readLayerAllocation(cursor, payload_version, layer_count, coding_passes);
        _ = try readEntropyStreamInfo(cursor);
        _ = try readEntropyStreamInfo(cursor);
        _ = try readEntropyStreamInfo(cursor);
        const ebcot_segment = try readEbcotSegmentInfo(cursor, payload_version, coding_passes);
        try skipEbcotSegmentPayload(cursor, payload_version, ebcot_segment.mq_bytes);
    }
}

fn decodeComponentPayloadWorker(job: *DecodeComponentPayloadJob) void {
    var cursor = Cursor.initWithAllocator(std.heap.smp_allocator, job.bytes);
    readComponentPayload(&cursor, job.plane, job.stride, job.component_index, job.payload_version, job.layer_count) catch |err| {
        job.result = err;
        return;
    };
    if (!cursor.finished()) {
        job.result = CodestreamError.InvalidCodestream;
        return;
    }
    job.result = {};
}

const TemporaryHeader = struct {
    version: u8,
    width: usize,
    height: usize,
    /// SIZ image origin in the reference grid. Width/height remain the image
    /// extent (`Xsiz-XOsiz`, `Ysiz-YOsiz`).
    reference_x0: u32 = 0,
    reference_y0: u32 = 0,
    bit_depth: u8,
    component_bit_depths: [max_codestream_components]u8 = [_]u8{0} ** max_codestream_components,
    component_xrsiz: [max_codestream_components]u8 = [_]u8{1} ** max_codestream_components,
    component_yrsiz: [max_codestream_components]u8 = [_]u8{1} ** max_codestream_components,
    component_qcd: [max_codestream_components]StrictQcdInfo = [_]StrictQcdInfo{.{
        .bands = 0,
        .quantization = .none,
    }} ** max_codestream_components,
    component_count: u16 = 3,
    levels: u8,
    layers: u16,
    progression: ProgressionOrder = .rpcl,
    mct: MultipleComponentTransform = .rct,
    transform: WaveletTransform = .reversible_5_3,
    quantization: QuantizationStyle = .none,
    code_block_style: ebcot.CodeBlockStyle = .{},
    block_width: u16,
    block_height: u16,
    /// SIZ tile dimensions; 0 means image-sized (single tile). Multi-tile
    /// streams carry the real XTSiz/YTSiz so the decode stages can rebuild
    /// the tile grid.
    tile_width: u32 = 0,
    tile_height: u32 = 0,
    /// Signalled QCD guard bits and per-band epsilon_b for strict streams;
    /// zero exponent count means "derive Mb from the z2000 formula" (sidecar
    /// and legacy paths). Irreversible streams also carry step mantissas below
    /// so dequantization follows the wire values instead of z2000 defaults.
    guard_bits: u8 = strict_guard_bits,
    qcd_exponents: [max_qcd_bands]u8 = [_]u8{0} ** max_qcd_bands,
    qcd_exponent_count: u8 = 0,
    qcd_steps: [max_qcd_bands]BandStepSize = [_]BandStepSize{.{ .exponent = 0, .mantissa = 0 }} ** max_qcd_bands,
    qcd_step_count: u8 = 0,
    tile_part_divisions: ?u8,
    tile_part_plan_count: u8,
    tile_part_plan: [33]u8,
    packet_plan_count: u8,
    packet_plan: [33]packet_plan.Resolution,
    packet_count: u64,
};

fn readTemporaryHeader(cursor: *Cursor) !TemporaryHeader {
    const magic = try cursor.readBytes(temporary_magic_v0.len);
    const version: u8 = if (std.mem.eql(u8, magic, temporary_magic_v0))
        0
    else if (std.mem.eql(u8, magic, temporary_magic_v1))
        1
    else if (std.mem.eql(u8, magic, temporary_magic_v2))
        2
    else if (std.mem.eql(u8, magic, temporary_magic_v3))
        3
    else if (std.mem.eql(u8, magic, temporary_magic_v4))
        4
    else if (std.mem.eql(u8, magic, temporary_magic_v5))
        5
    else if (std.mem.eql(u8, magic, temporary_magic_v6))
        6
    else if (std.mem.eql(u8, magic, temporary_magic_v7))
        7
    else if (std.mem.eql(u8, magic, temporary_magic_v8))
        8
    else
        return CodestreamError.UnsupportedPayload;

    const width = @as(usize, try cursor.readU32());
    const height = @as(usize, try cursor.readU32());
    const bit_depth = try cursor.readU8();
    const levels = try cursor.readU8();
    const block_width = try cursor.readU16();
    const block_height = try cursor.readU16();
    const tile_part_divisions = if (version >= 1) try readTilePartDivisions(cursor) else null;
    const tile_part_plan = if (version >= 2) try readTilePartPlan(cursor) else emptyTilePartPlan();
    const packets = if (version >= 3) try readPacketPlan(cursor) else emptyPacketPlan();
    const layers = if (version >= 5) try cursor.readU16() else inferLayerCount(packets);
    if (layers == 0 or layers > max_quality_layers) return CodestreamError.InvalidCodestream;

    return .{
        .version = version,
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .levels = levels,
        .layers = layers,
        .block_width = block_width,
        .block_height = block_height,
        .tile_part_divisions = tile_part_divisions,
        .tile_part_plan_count = tile_part_plan.count,
        .tile_part_plan = tile_part_plan.entries,
        .packet_plan_count = packets.resolution_count,
        .packet_plan = packets.resolutions,
        .packet_count = packets.packets,
    };
}

fn inferLayerCount(plan: packet_plan.Plan) u16 {
    if (plan.resolution_count == 0) return 1;
    for (plan.resolutions[0..plan.resolution_count]) |resolution| {
        if (resolution.precincts == 0) continue;
        if (resolution.packets % (resolution.precincts * 3) == 0) {
            return @intCast(resolution.packets / (resolution.precincts * 3));
        }
    }
    return 1;
}

fn readTilePartDivisions(cursor: *Cursor) !?u8 {
    const value = try cursor.readU8();
    return if (value == 0) null else value;
}

const TilePartPlan = struct {
    count: u8,
    entries: [33]u8,
};

fn emptyTilePartPlan() TilePartPlan {
    return .{
        .count = 0,
        .entries = [_]u8{0} ** 33,
    };
}

fn resolutionTilePartPlan(levels: u8) TilePartPlan {
    var plan = emptyTilePartPlan();
    plan.count = levels + 1;
    var resolution: u8 = 0;
    while (resolution < plan.count) : (resolution += 1) {
        plan.entries[resolution] = resolution;
    }
    return plan;
}

fn readTilePartPlan(cursor: *Cursor) !TilePartPlan {
    var plan = emptyTilePartPlan();
    const count = try cursor.readU8();
    if (count > plan.entries.len) return CodestreamError.InvalidCodestream;
    plan.count = count;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        plan.entries[index] = try cursor.readU8();
    }

    return plan;
}

fn emptyPacketPlan() packet_plan.Plan {
    return .{
        .resolution_count = 0,
        .resolutions = [_]packet_plan.Resolution{.{
            .width = 0,
            .height = 0,
            .precinct_width = 0,
            .precinct_height = 0,
            .precincts_x = 0,
            .precincts_y = 0,
            .precincts = 0,
            .packets = 0,
        }} ** 33,
        .packets = 0,
    };
}

fn readPacketPlan(cursor: *Cursor) !packet_plan.Plan {
    var plan = emptyPacketPlan();
    const count = try cursor.readU8();
    if (count > plan.resolutions.len) return CodestreamError.InvalidCodestream;
    plan.resolution_count = count;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        const res = packet_plan.Resolution{
            .width = try cursor.readU32(),
            .height = try cursor.readU32(),
            .precinct_width = try cursor.readU32(),
            .precinct_height = try cursor.readU32(),
            .precincts_x = try cursor.readU32(),
            .precincts_y = try cursor.readU32(),
            .precincts = try cursor.readU64(),
            .packets = try cursor.readU64(),
        };
        plan.resolutions[index] = res;
        plan.packets += res.packets;
    }

    return plan;
}

fn readStoredCodingPasses(cursor: *Cursor, payload_version: u8, bitplanes: u8, non_zero_count: u32) !u16 {
    const expected = bitplane.isoCodingPassCount(bitplanes, non_zero_count);
    if (payload_version < 4) return expected;

    const stored = try cursor.readU16();
    if (stored != expected) return CodestreamError.InvalidCodestream;
    return stored;
}

fn readLayerAllocation(
    cursor: *Cursor,
    payload_version: u8,
    expected_layers: u16,
    coding_passes: u16,
) ![max_quality_layers]rate_alloc.Truncation {
    var layers = [_]rate_alloc.Truncation{.{ .cumulative_passes = 0, .cumulative_bytes = 0 }} ** max_quality_layers;
    if (payload_version < 5) return layers;

    const layer_count = try cursor.readU16();
    if (layer_count == 0 or layer_count > max_quality_layers) return CodestreamError.InvalidCodestream;
    if (expected_layers != 0 and layer_count != expected_layers) return CodestreamError.InvalidCodestream;

    var previous_passes: u16 = 0;
    var previous_bytes: u64 = 0;
    var layer_index: usize = 0;
    while (layer_index < layer_count) : (layer_index += 1) {
        const passes = try cursor.readU16();
        const bytes = try cursor.readU64();
        if (passes < previous_passes or passes > coding_passes) return CodestreamError.InvalidCodestream;
        if (bytes < previous_bytes) return CodestreamError.InvalidCodestream;
        layers[layer_index] = .{ .cumulative_passes = passes, .cumulative_bytes = bytes };
        previous_passes = passes;
        previous_bytes = bytes;
    }

    return layers;
}

fn readEbcotSegmentInfo(cursor: *Cursor, payload_version: u8, coding_passes: u16) !EbcotSegmentStats {
    const info = try readEbcotSegmentInfoWithPasses(null, cursor, payload_version, coding_passes);
    return info.stats;
}

fn readEbcotSegmentInfoWithPasses(
    allocator: ?std.mem.Allocator,
    cursor: *Cursor,
    payload_version: u8,
    coding_passes: u16,
) !EbcotSegmentInfo {
    if (payload_version < 6) return .{};

    const pass_count = try cursor.readU16();
    if (pass_count != coding_passes) return CodestreamError.InvalidCodestream;
    const byte_length = try cursor.readU64();

    var stats = EbcotSegmentStats{};
    stats.blocks = if (pass_count == 0 and byte_length == 0) 0 else 1;
    stats.passes = @as(u64, pass_count);
    stats.mq_bytes = byte_length;

    var passes: []ebcot.CodeBlockPassPayload = &.{};
    if (allocator) |alloc| {
        passes = try alloc.alloc(ebcot.CodeBlockPassPayload, pass_count);
    }
    errdefer if (allocator) |alloc| {
        if (passes.len > 0) alloc.free(passes);
    };

    var previous_end: u64 = 0;
    var pass_index: usize = 0;
    while (pass_index < @as(usize, pass_count)) : (pass_index += 1) {
        const kind = try cursor.readU8();
        if (kind > 2) return CodestreamError.InvalidCodestream;
        const magnitude_bitplane = try cursor.readU8();
        const symbol_count = try cursor.readU32();
        const byte_offset = try cursor.readU64();
        const pass_bytes = try cursor.readU64();
        const cumulative_bytes = try cursor.readU64();
        if (byte_offset != previous_end) return CodestreamError.InvalidCodestream;
        if (cumulative_bytes < byte_offset or cumulative_bytes - byte_offset != pass_bytes) {
            return CodestreamError.InvalidCodestream;
        }
        if (cumulative_bytes > byte_length) return CodestreamError.InvalidCodestream;
        previous_end = cumulative_bytes;
        stats.symbols += @as(u64, symbol_count);
        if (passes.len > 0) {
            passes[pass_index] = .{
                .kind = @enumFromInt(kind),
                .magnitude_bitplane = magnitude_bitplane,
                .symbol_count = symbol_count,
                .byte_offset = @intCast(byte_offset),
                .byte_length = @intCast(pass_bytes),
                .cumulative_bytes = cumulative_bytes,
            };
        }
    }
    if (previous_end != byte_length) return CodestreamError.InvalidCodestream;

    return .{
        .stats = stats,
        .passes = passes,
    };
}

fn skipEbcotSegmentPayload(cursor: *Cursor, payload_version: u8, byte_length: u64) !void {
    if (payload_version < 7) return;
    const len = std.math.cast(usize, byte_length) orelse return CodestreamError.InvalidCodestream;
    _ = try cursor.readBytes(len);
}

fn readRpclShadowStreamInfo(cursor: *Cursor, payload_version: u8, expected_packet_count: u64) !PacketStreamInfo {
    if (payload_version < 8) return .{};

    const packet_count = try cursor.readU64();
    if (packet_count != expected_packet_count) return CodestreamError.InvalidCodestream;
    const byte_count = try cursor.readU64();
    var actual_bytes: u64 = 0;
    var packet_index: u64 = 0;
    while (packet_index < packet_count) : (packet_index += 1) {
        const packet_len = try cursor.readU32();
        actual_bytes = try std.math.add(u64, actual_bytes, packet_len);
        _ = try cursor.readBytes(@intCast(packet_len));
    }
    if (actual_bytes != byte_count) return CodestreamError.InvalidCodestream;

    return .{
        .packets = packet_count,
        .bytes = byte_count,
    };
}

fn readComponentStats(cursor: *Cursor, stats: *ComponentStats, expected_component: u8, payload_version: u8, layer_count: u16) !void {
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
        const coding_passes = try readStoredCodingPasses(cursor, payload_version, bitplanes, non_zero_count);
        const layer_allocation = try readLayerAllocation(cursor, payload_version, layer_count, coding_passes);

        stats.coeffs += rectArea(block_rect);
        stats.active_coeffs += rectArea(active_rect);
        stats.non_zero_coeffs += non_zero_count;
        stats.max_bitplanes = @max(stats.max_bitplanes, bitplanes);
        stats.coding_passes += coding_passes;
        if (active_rect.width == 0 or active_rect.height == 0) {
            stats.empty_blocks += 1;
        } else {
            stats.active_blocks += 1;
        }
        if (payload_version >= 5) {
            for (layer_allocation[0..@as(usize, @intCast(@min(max_quality_layers, stats.quality_layers.len)))], 0..) |layer, index| {
                if (layer.cumulative_passes == 0 and layer.cumulative_bytes == 0) continue;
                stats.quality_layers[index].blocks += 1;
                stats.quality_layers[index].cumulative_passes += layer.cumulative_passes;
                stats.quality_layers[index].cumulative_bytes += layer.cumulative_bytes;
            }
        }

        const significance = try readEntropyStreamInfo(cursor);
        const refinement = try readEntropyStreamInfo(cursor);
        const cleanup = try readEntropyStreamInfo(cursor);
        stats.addStream(.significance, significance);
        stats.addStream(.refinement, refinement);
        stats.addStream(.cleanup, cleanup);
        const ebcot_segment = try readEbcotSegmentInfo(cursor, payload_version, coding_passes);
        try skipEbcotSegmentPayload(cursor, payload_version, ebcot_segment.mq_bytes);
        stats.ebcot_segments.blocks += ebcot_segment.blocks;
        stats.ebcot_segments.passes += ebcot_segment.passes;
        stats.ebcot_segments.symbols += ebcot_segment.symbols;
        stats.ebcot_segments.mq_bytes += ebcot_segment.mq_bytes;
    }
}

fn appendSiz(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    rgb: image.RgbImage,
    options: LosslessOptions,
) !void {
    return appendSizForComponents(allocator, out, .{
        .width = @intCast(rgb.width),
        .height = @intCast(rgb.height),
        .bit_depth = rgb.bit_depth,
        .components = 3,
        .tile_width = options.tile_width,
        .tile_height = options.tile_height,
    });
}

const SizProfile = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    component_bit_depths: [max_codestream_components]u8 = [_]u8{0} ** max_codestream_components,
    components: u16,
    tile_width: u32,
    tile_height: u32,
};

fn appendSizForComponents(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    profile: SizProfile,
) !void {
    if (profile.width == 0 or profile.height == 0 or profile.components == 0) {
        return CodestreamError.InvalidCodestream;
    }
    if (profile.components > max_codestream_components) return CodestreamError.UnsupportedPayload;
    const component_bytes = try std.math.mul(u32, 3, profile.components);
    const lsiz_u32 = try std.math.add(u32, 38, component_bytes);
    if (lsiz_u32 > std.math.maxInt(u16)) return CodestreamError.ImageTooLarge;

    try appendMarker(allocator, out, .siz);
    try appendU16Be(allocator, out, @intCast(lsiz_u32));
    try appendU16Be(allocator, out, 0);
    try appendU32Be(allocator, out, profile.width);
    try appendU32Be(allocator, out, profile.height);
    try appendU32Be(allocator, out, 0);
    try appendU32Be(allocator, out, 0);
    try appendU32Be(allocator, out, profile.tile_width);
    try appendU32Be(allocator, out, profile.tile_height);
    try appendU32Be(allocator, out, 0);
    try appendU32Be(allocator, out, 0);
    try appendU16Be(allocator, out, profile.components);
    for (0..profile.components) |component| {
        const explicit_depth = profile.component_bit_depths[component];
        const component_depth = if (explicit_depth != 0) explicit_depth else profile.bit_depth;
        if (component_depth == 0 or component_depth > 38) return CodestreamError.UnsupportedPayload;
        try out.append(allocator, component_depth - 1);
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
    // ISO A.6.1 SGcod: the MCT field is 0 (none) or 1 (transform used); RCT
    // vs ICT follows from the wavelet transform byte.
    try out.append(allocator, if (options.mct == .none) @as(u8, 0) else 1);
    try out.append(allocator, levels);
    try out.append(allocator, codeBlockExponent(options.block_width));
    try out.append(allocator, codeBlockExponent(options.block_height));
    try out.append(allocator, codeBlockStyle(options));
    try out.append(allocator, @intFromEnum(options.transform));
    if (uses_precincts) {
        var resolution: usize = 0;
        while (resolution <= levels) : (resolution += 1) {
            try out.append(allocator, precinctByte(options.precinctForResolution(resolution)));
        }
    }
}

fn appendQcd(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    levels: u8,
    bit_depth: u8,
    options: LosslessOptions,
) !void {
    const bands = 1 + 3 * @as(u16, levels);
    try appendMarker(allocator, out, .qcd);
    if (options.transform == .irreversible_9_7) {
        if (options.quantization == .scalar_derived) {
            // A.6.4: derived quantization signals a single step size for the
            // NL LL band; decoders derive every other subband via E-5.
            try appendU16Be(allocator, out, 3 + 2);
            try out.append(allocator, qcdStyleByte(options));
            try appendQcdScalarValue(allocator, out, bit_depth, .ll, levels);
            return;
        }
        try appendU16Be(allocator, out, 3 + 2 * bands);
        try out.append(allocator, qcdStyleByte(options));
        try appendQcdScalarValue(allocator, out, bit_depth, .ll, levels);
        var level: u8 = levels;
        while (level > 0) : (level -= 1) {
            inline for (.{ subband.Kind.hl, subband.Kind.lh, subband.Kind.hh }) |kind| {
                try appendQcdScalarValue(allocator, out, bit_depth, kind, level);
            }
        }
        return;
    }
    try appendU16Be(allocator, out, 3 + bands);
    try out.append(allocator, qcdStyleByte(options));
    try out.append(allocator, try qcdReversibleExponentByteForBand(bit_depth, .ll));
    var level: u8 = 0;
    while (level < levels) : (level += 1) {
        inline for (.{ subband.Kind.hl, subband.Kind.lh, subband.Kind.hh }) |kind| {
            try out.append(allocator, try qcdReversibleExponentByteForBand(bit_depth, kind));
        }
    }
}

fn appendQccReversible(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    levels: u8,
    component: u8,
    bit_depth: u8,
    options: LosslessOptions,
) !void {
    if (options.transform != .reversible_5_3 or options.quantization != .none) {
        return CodestreamError.UnsupportedPayload;
    }
    const bands = 1 + 3 * @as(u16, levels);
    try appendMarker(allocator, out, .qcc);
    try appendU16Be(allocator, out, 4 + bands);
    try out.append(allocator, component);
    try out.append(allocator, qcdStyleByte(options));
    try out.append(allocator, try qcdReversibleExponentByteForBand(bit_depth, .ll));
    var level: u8 = 0;
    while (level < levels) : (level += 1) {
        inline for (.{ subband.Kind.hl, subband.Kind.lh, subband.Kind.hh }) |kind| {
            try out.append(allocator, try qcdReversibleExponentByteForBand(bit_depth, kind));
        }
    }
}

fn appendPoc(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    levels: u8,
    options: LosslessOptions,
) !void {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    poc.appendSegmentPayload(
        allocator,
        &payload,
        options.poc_records,
        3,
        levels + 1,
        options.layers,
    ) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return CodestreamError.InvalidCodestream,
    };
    try appendMarker(allocator, out, .poc);
    try appendU16Be(allocator, out, @intCast(payload.items.len + 2));
    try out.appendSlice(allocator, payload.items);
}

fn pocMarkerByteCount(options: LosslessOptions) !u32 {
    if (options.poc_records.len == 0) return CodestreamError.InvalidCodestream;
    const payload_bytes = std.math.mul(usize, options.poc_records.len, 7) catch
        return CodestreamError.UnsupportedPayload;
    if (payload_bytes > std.math.maxInt(u16) - 2) return CodestreamError.UnsupportedPayload;
    return std.math.cast(u32, payload_bytes + 4) orelse return CodestreamError.UnsupportedPayload;
}

fn appendQcdScalarValue(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bit_depth: u8,
    kind: subband.Kind,
    band_level: u8,
) !void {
    const step = try irreversibleBandStepSize(bit_depth, kind, band_level);
    const value = (@as(u16, step.exponent) << 11) | step.mantissa;
    try appendU16Be(allocator, out, value);
}

fn skipPacketBoundaryMarkers(bytes: []const u8, start: usize, end: usize) !usize {
    var cursor = start;
    while (end - cursor >= 2 and readU16Be(bytes, cursor) == @intFromEnum(Marker.sop)) {
        if (end - cursor < 6) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, cursor + 2);
        if (segment_length != 4) return CodestreamError.InvalidCodestream;
        cursor += 6;
        if (end - cursor >= 2 and readU16Be(bytes, cursor) == @intFromEnum(Marker.eph)) {
            cursor += 2;
        }
    }
    return cursor;
}

fn appendTlm(allocator: std.mem.Allocator, out: *std.ArrayList(u8), psots: []const u32) !void {
    if (psots.len == 0 or psots.len > 255) return CodestreamError.InvalidCodestream;
    try appendMarker(allocator, out, .tlm);
    const ltlm = try std.math.add(u16, 4, @as(u16, @intCast(psots.len * 5)));
    try appendU16Be(allocator, out, ltlm);
    try out.append(allocator, 0);
    try out.append(allocator, 0x50);
    for (psots) |psot| {
        try out.append(allocator, 0);
        try appendU32Be(allocator, out, psot);
    }
}

fn appendTemporaryPayloadComments(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    payload: []const u8,
) !void {
    const header_len = temporary_comment_magic.len + 8;
    const max_comment_bytes = 65531;
    if (header_len >= max_comment_bytes) return CodestreamError.InvalidCodestream;
    const max_payload_bytes = max_comment_bytes - header_len;
    const chunk_count = try std.math.divCeil(usize, payload.len, max_payload_bytes);
    if (chunk_count == 0 or chunk_count > std.math.maxInt(u32)) return CodestreamError.InvalidCodestream;

    var chunk_index: usize = 0;
    while (chunk_index < chunk_count) : (chunk_index += 1) {
        const start = chunk_index * max_payload_bytes;
        const end = @min(payload.len, start + max_payload_bytes);
        const comment_len = header_len + (end - start);
        const segment_length = try std.math.add(u16, 4, @as(u16, @intCast(comment_len)));

        try appendMarker(allocator, out, .com);
        try appendU16Be(allocator, out, segment_length);
        try appendU16Be(allocator, out, 0);
        try out.appendSlice(allocator, temporary_comment_magic);
        try appendU32Be(allocator, out, @intCast(chunk_index));
        try appendU32Be(allocator, out, @intCast(chunk_count));
        try out.appendSlice(allocator, payload[start..end]);
    }
}

fn readTilePartHeaderMarkers(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    start: usize,
    end: usize,
    packet_lengths: *std.ArrayList(usize),
    packed_headers: *std.ArrayList(u8),
    expected_ppt_index: *u16,
    poc_target: ?TilePartPocTarget,
) !usize {
    var cursor = start;
    var expected_plt_index: u8 = 0;
    var saw_ppt = false;
    while (cursor + 1 < end) {
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(Marker.sod)) {
            if (saw_ppt and packed_headers.items.len == 0) return CodestreamError.InvalidCodestream;
            return cursor;
        }
        if (marker == @intFromEnum(Marker.sot) or marker == @intFromEnum(Marker.eoc)) {
            return CodestreamError.InvalidCodestream;
        }
        cursor += 2;
        if (end - cursor < 2) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, cursor);
        if (segment_length < 2 or end - cursor < segment_length) {
            return CodestreamError.TruncatedData;
        }
        if (marker == @intFromEnum(Marker.plt)) {
            try appendPltSegmentLengths(allocator, bytes[cursor + 2 .. cursor + segment_length], expected_plt_index, packet_lengths);
            if (expected_plt_index == std.math.maxInt(u8)) return CodestreamError.InvalidCodestream;
            expected_plt_index += 1;
        } else if (marker == @intFromEnum(Marker.ppt)) {
            const segment = bytes[cursor + 2 .. cursor + segment_length];
            if (expected_ppt_index.* > std.math.maxInt(u8) or
                segment.len < 2 or segment[0] != @as(u8, @intCast(expected_ppt_index.*)))
            {
                return CodestreamError.InvalidCodestream;
            }
            try packed_headers.appendSlice(allocator, segment[1..]);
            saw_ppt = true;
            expected_ppt_index.* += 1;
        } else if (marker == @intFromEnum(Marker.com)) {
            // Tile-part comments are metadata only and do not affect packet spans.
        } else if (marker == @intFromEnum(Marker.poc)) {
            if (poc_target) |target| {
                if (!target.allowed) return CodestreamError.InvalidCodestream;
                const limits = target.limits;
                poc.appendSegment(
                    allocator,
                    target.records,
                    bytes[cursor + 2 .. cursor + segment_length],
                    limits.component_count,
                    limits.resolution_count,
                    limits.layer_count,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return CodestreamError.InvalidCodestream,
                };
            }
        } else if (isUnsupportedTilePartHeaderMarker(marker)) {
            return CodestreamError.UnsupportedPayload;
        } else {
            return CodestreamError.InvalidCodestream;
        }
        cursor += segment_length;
    }
    return CodestreamError.InvalidCodestream;
}

fn appendPltSegmentLengths(
    allocator: std.mem.Allocator,
    segment: []const u8,
    expected_index: u8,
    packet_lengths: *std.ArrayList(usize),
) !void {
    if (segment.len < 2) return CodestreamError.InvalidCodestream;
    if (segment[0] != expected_index) return CodestreamError.InvalidCodestream;
    var length: usize = 0;
    var pending_length = false;
    for (segment[1..]) |byte| {
        length = (length << 7) | (byte & 0x7f);
        pending_length = true;
        if ((byte & 0x80) == 0) {
            try packet_lengths.append(allocator, length);
            length = 0;
            pending_length = false;
        }
    }
    if (pending_length) return CodestreamError.InvalidCodestream;
}

fn appendTemporaryPacketPayloads(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bytes: []const u8,
    start: usize,
    end: usize,
    packet_lengths: []const usize,
) !usize {
    var cursor = start;
    for (packet_lengths) |packet_length| {
        const packet_end = try std.math.add(usize, cursor, packet_length);
        if (packet_end > end) return CodestreamError.TruncatedData;

        var packet_cursor = cursor;
        if (packet_end - packet_cursor >= 2 and readU16Be(bytes, packet_cursor) == @intFromEnum(Marker.sop)) {
            if (packet_end - packet_cursor < 6) return CodestreamError.TruncatedData;
            const segment_length = readU16Be(bytes, packet_cursor + 2);
            if (segment_length != 4) return CodestreamError.InvalidCodestream;
            packet_cursor += 6;
        }

        if (packet_cursor >= packet_end) return CodestreamError.TruncatedData;
        const present = t2.readPacketPresenceHeader(bytes, &packet_cursor, packet_end) catch |err| switch (err) {
            t2.PacketHeaderError.TruncatedHeader => return CodestreamError.TruncatedData,
            t2.PacketHeaderError.InvalidPacketHeader => return CodestreamError.InvalidCodestream,
            t2.PacketHeaderError.InvalidMarkerStuffing => return CodestreamError.InvalidCodestream,
            t2.PacketHeaderError.InvalidTagTree => return CodestreamError.InvalidCodestream,
        };
        const header = if (present) temporary_packet_header_non_empty else temporary_packet_header_empty;
        const header_body_start = packet_cursor;
        const body_len = readVariableLength(bytes, &packet_cursor, packet_end) catch {
            try appendLegacyTemporaryPacketPayload(allocator, out, bytes, header_body_start, packet_end, header);
            cursor = packet_end;
            continue;
        };

        if (packet_end - packet_cursor >= 2 and readU16Be(bytes, packet_cursor) == @intFromEnum(Marker.eph)) {
            packet_cursor += 2;
        }

        const new_header_ok = body_len <= std.math.maxInt(usize) and
            packet_end - packet_cursor == @as(usize, @intCast(body_len)) and
            ((header == temporary_packet_header_empty) == (body_len == 0));
        if (!new_header_ok) {
            try appendLegacyTemporaryPacketPayload(allocator, out, bytes, header_body_start, packet_end, header);
            cursor = packet_end;
            continue;
        }
        try out.appendSlice(allocator, bytes[packet_cursor..packet_end]);
        cursor = packet_end;
    }

    if (cursor != end) return CodestreamError.InvalidCodestream;
    return cursor;
}

fn appendLegacyTemporaryPacketPayload(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bytes: []const u8,
    start: usize,
    end: usize,
    header: u8,
) !void {
    var cursor = start;
    if (end - cursor >= 2 and readU16Be(bytes, cursor) == @intFromEnum(Marker.eph)) {
        cursor += 2;
    } else if (header != temporary_packet_header_empty) {
        return CodestreamError.InvalidCodestream;
    }

    if (header == temporary_packet_header_empty and cursor != end) {
        return CodestreamError.InvalidCodestream;
    }
    try out.appendSlice(allocator, bytes[cursor..end]);
}

fn appendSot(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tile_index: u16,
    psot: u32,
    tile_part_index: u8,
    tile_part_count: u8,
) !void {
    try appendMarker(allocator, out, .sot);
    try appendU16Be(allocator, out, 10);
    try appendU16Be(allocator, out, tile_index);
    try appendU32Be(allocator, out, psot);
    try out.append(allocator, tile_part_index);
    try out.append(allocator, tile_part_count);
}

fn appendPltFromRpclPacketLengths(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    options: LosslessOptions,
    packet_lengths: []const u32,
) !void {
    if (packet_lengths.len == 0) return;

    var marker_index: u8 = 0;
    var segment = std.ArrayList(u8).empty;
    defer segment.deinit(allocator);

    for (packet_lengths) |packet_length| {
        const framed_packet_length = rpclPacketLengthWithMarkers(options, packet_length);
        const encoded_len = pltLengthByteCount(framed_packet_length);
        if (segment.items.len + encoded_len > 65532) {
            try flushPltSegment(allocator, out, marker_index, segment.items);
            if (marker_index == std.math.maxInt(u8)) return CodestreamError.InvalidCodestream;
            marker_index += 1;
            segment.clearRetainingCapacity();
        }
        try appendPltLength(allocator, &segment, framed_packet_length);
    }

    if (segment.items.len > 0) {
        try flushPltSegment(allocator, out, marker_index, segment.items);
    }
}

fn appendPltFromPackedPacketLengths(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    options: LosslessOptions,
    packet_lengths: []const u32,
    header_lengths: []const u32,
) !void {
    if (packet_lengths.len == 0 or packet_lengths.len != header_lengths.len) {
        return CodestreamError.InvalidCodestream;
    }
    var marker_index: u8 = 0;
    var segment: std.ArrayList(u8) = .empty;
    defer segment.deinit(allocator);
    for (packet_lengths, header_lengths) |packet_length, header_length| {
        if (header_length > packet_length) return CodestreamError.InvalidCodestream;
        const body_length = try packedPacketBodyLength(options, packet_length, header_length);
        const encoded_len = pltLengthByteCount(body_length);
        if (segment.items.len + encoded_len > 65532) {
            try flushPltSegment(allocator, out, marker_index, segment.items);
            if (marker_index == std.math.maxInt(u8)) return CodestreamError.InvalidCodestream;
            marker_index += 1;
            segment.clearRetainingCapacity();
        }
        try appendPltLength(allocator, &segment, body_length);
    }
    if (segment.items.len > 0) try flushPltSegment(allocator, out, marker_index, segment.items);
}

fn packedPacketBodyLength(options: LosslessOptions, packet_length: u32, header_length: u32) !usize {
    if (header_length > packet_length) return CodestreamError.InvalidCodestream;
    return std.math.add(usize, packet_length - header_length, if (options.sop) 6 else 0);
}

fn packedPacketBodyByteCount(
    options: LosslessOptions,
    packet_lengths: []const u32,
    header_lengths: []const u32,
) !usize {
    if (packet_lengths.len != header_lengths.len) return CodestreamError.InvalidCodestream;
    var total: usize = 0;
    for (packet_lengths, header_lengths) |packet_length, header_length| {
        total = try std.math.add(usize, total, try packedPacketBodyLength(options, packet_length, header_length));
    }
    return total;
}

fn pltBytesForPackedPacketLengths(
    options: LosslessOptions,
    packet_lengths: []const u32,
    header_lengths: []const u32,
) !usize {
    if (packet_lengths.len == 0 or packet_lengths.len != header_lengths.len) {
        return CodestreamError.InvalidCodestream;
    }
    var bytes: usize = 5;
    var segment_payload_bytes: usize = 0;
    var marker_count: usize = 1;
    for (packet_lengths, header_lengths) |packet_length, header_length| {
        const encoded_len = pltLengthByteCount(try packedPacketBodyLength(options, packet_length, header_length));
        if (segment_payload_bytes + encoded_len > 65532) {
            marker_count += 1;
            if (marker_count > 256) return CodestreamError.InvalidCodestream;
            bytes = try std.math.add(usize, bytes, 5);
            segment_payload_bytes = 0;
        }
        segment_payload_bytes += encoded_len;
        bytes = try std.math.add(usize, bytes, encoded_len);
    }
    return bytes;
}

fn pptMarkerByteCount(options: LosslessOptions, header_lengths: []const u32) !usize {
    var header_bytes: usize = 0;
    for (header_lengths) |length| {
        header_bytes = try std.math.add(usize, header_bytes, length);
        if (options.eph) header_bytes = try std.math.add(usize, header_bytes, 2);
    }
    if (header_bytes == 0) return CodestreamError.InvalidCodestream;
    const marker_count = try std.math.divCeil(usize, header_bytes, 65532);
    if (marker_count > 256) return CodestreamError.UnsupportedPayload;
    return try std.math.add(usize, header_bytes, try std.math.mul(usize, marker_count, 5));
}

fn appendPptPacketHeaders(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    options: LosslessOptions,
    packet_lengths: []const u32,
    header_lengths: []const u32,
    packet_bytes: []const u8,
    marker_index: *u16,
) !void {
    const headers = try collectPackedPacketHeaders(
        allocator,
        options,
        packet_lengths,
        header_lengths,
        packet_bytes,
    );
    defer allocator.free(headers);

    var offset: usize = 0;
    while (offset < headers.len) {
        if (marker_index.* > std.math.maxInt(u8)) return CodestreamError.UnsupportedPayload;
        const count = @min(@as(usize, 65532), headers.len - offset);
        try appendMarker(allocator, out, .ppt);
        try appendU16Be(allocator, out, @intCast(count + 3));
        try out.append(allocator, @intCast(marker_index.*));
        try out.appendSlice(allocator, headers[offset..][0..count]);
        offset += count;
        marker_index.* += 1;
    }
}

fn collectPackedPacketHeaders(
    allocator: std.mem.Allocator,
    options: LosslessOptions,
    packet_lengths: []const u32,
    header_lengths: []const u32,
    packet_bytes: []const u8,
) ![]u8 {
    if (packet_lengths.len != header_lengths.len) return CodestreamError.InvalidCodestream;
    var headers: std.ArrayList(u8) = .empty;
    errdefer headers.deinit(allocator);
    var cursor: usize = 0;
    for (packet_lengths, header_lengths) |packet_length, header_length| {
        const packet_end = try std.math.add(usize, cursor, packet_length);
        const header_end = try std.math.add(usize, cursor, header_length);
        if (header_end > packet_end or packet_end > packet_bytes.len) return CodestreamError.InvalidCodestream;
        try headers.appendSlice(allocator, packet_bytes[cursor..header_end]);
        if (options.eph) try appendMarker(allocator, &headers, .eph);
        cursor = packet_end;
    }
    if (cursor != packet_bytes.len or headers.items.len == 0) return CodestreamError.InvalidCodestream;
    return headers.toOwnedSlice(allocator);
}

fn appendPackedPacketBodies(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    options: LosslessOptions,
    packet_lengths: []const u32,
    header_lengths: []const u32,
    packet_bytes: []const u8,
    packet_sequence: *u16,
) !void {
    if (packet_lengths.len != header_lengths.len) return CodestreamError.InvalidCodestream;
    var cursor: usize = 0;
    for (packet_lengths, header_lengths) |packet_length, header_length| {
        const packet_end = try std.math.add(usize, cursor, packet_length);
        const body_start = try std.math.add(usize, cursor, header_length);
        if (body_start > packet_end or packet_end > packet_bytes.len) return CodestreamError.InvalidCodestream;
        if (options.sop) {
            try appendMarker(allocator, out, .sop);
            try appendU16Be(allocator, out, 4);
            try appendU16Be(allocator, out, packet_sequence.*);
            packet_sequence.* +%= 1;
        }
        try out.appendSlice(allocator, packet_bytes[body_start..packet_end]);
        cursor = packet_end;
    }
    if (cursor != packet_bytes.len) return CodestreamError.InvalidCodestream;
}

fn flushPltSegment(allocator: std.mem.Allocator, out: *std.ArrayList(u8), marker_index: u8, lengths: []const u8) !void {
    try appendMarker(allocator, out, .plt);
    const lplt = try std.math.add(u16, 3, @as(u16, @intCast(lengths.len)));
    try appendU16Be(allocator, out, lplt);
    try out.append(allocator, marker_index);
    try out.appendSlice(allocator, lengths);
}

fn pltBytesForRpclPacketLengths(options: LosslessOptions, packet_lengths: []const u32) !usize {
    if (packet_lengths.len == 0) return 0;
    var bytes: usize = 5;
    var segment_payload_bytes: usize = 0;
    var marker_count: usize = 1;

    for (packet_lengths) |packet_length| {
        const encoded_len = pltLengthByteCount(rpclPacketLengthWithMarkers(options, packet_length));
        if (segment_payload_bytes + encoded_len > 65532) {
            marker_count += 1;
            if (marker_count > 256) return CodestreamError.InvalidCodestream;
            bytes = try std.math.add(usize, bytes, 5);
            segment_payload_bytes = 0;
        }
        segment_payload_bytes += encoded_len;
        bytes = try std.math.add(usize, bytes, encoded_len);
    }

    return bytes;
}

fn rpclPacketPayloadByteCount(options: LosslessOptions, packet_lengths: []const u32) !usize {
    var total: usize = 0;
    for (packet_lengths) |packet_length| {
        total = try std.math.add(usize, total, @as(usize, @intCast(rpclPacketLengthWithMarkers(options, packet_length))));
    }
    return total;
}

fn rpclPacketLengthWithMarkers(options: LosslessOptions, packet_length: u32) u64 {
    return @as(u64, packet_length) +
        (if (options.sop) @as(u64, 6) else 0) +
        (if (options.eph) @as(u64, 2) else 0);
}

fn pltLengthByteCount(length: u64) usize {
    var value = length >> 7;
    var count: usize = 1;
    while (value > 0) : (value >>= 7) count += 1;
    return count;
}

fn appendPltLength(allocator: std.mem.Allocator, out: *std.ArrayList(u8), length: u64) !void {
    var bytes: [10]u8 = undefined;
    var count: usize = 0;
    var value = length;
    bytes[count] = @as(u8, @intCast(value & 0x7f));
    count += 1;
    value >>= 7;
    while (value > 0) {
        bytes[count] = @as(u8, @intCast(value & 0x7f)) | 0x80;
        count += 1;
        value >>= 7;
    }

    while (count > 0) {
        count -= 1;
        try out.append(allocator, bytes[count]);
    }
}

fn readVariableLength(bytes: []const u8, cursor: *usize, end: usize) !u64 {
    var length: u64 = 0;
    var byte_count: usize = 0;
    while (cursor.* < end) {
        if (byte_count == 10) return CodestreamError.InvalidCodestream;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (length > (std.math.maxInt(u64) >> 7)) return CodestreamError.InvalidCodestream;
        length = (length << 7) | @as(u64, byte & 0x7f);
        byte_count += 1;
        if ((byte & 0x80) == 0) return length;
    }
    return CodestreamError.TruncatedData;
}

fn appendSop(allocator: std.mem.Allocator, out: *std.ArrayList(u8), sequence: u16) !void {
    try appendMarker(allocator, out, .sop);
    try appendU16Be(allocator, out, 4);
    try appendU16Be(allocator, out, sequence);
}

fn appendRpclPackets(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    options: LosslessOptions,
    packet_lengths: []const u32,
    packet_header_lengths: []const u32,
    packet_bytes: []const u8,
    packet_sequence: *u16,
) !void {
    if (packet_lengths.len != packet_header_lengths.len) return CodestreamError.InvalidCodestream;
    var cursor: usize = 0;
    for (packet_lengths, packet_header_lengths) |packet_length, packet_header_length| {
        const end = try std.math.add(usize, cursor, packet_length);
        if (end > packet_bytes.len) return CodestreamError.InvalidCodestream;
        if (packet_header_length > packet_length) return CodestreamError.InvalidCodestream;
        const header_end = try std.math.add(usize, cursor, packet_header_length);
        if (options.sop) {
            try appendSop(allocator, out, packet_sequence.*);
            packet_sequence.* +%= 1;
        }
        try out.appendSlice(allocator, packet_bytes[cursor..header_end]);
        if (options.eph) try appendMarker(allocator, out, .eph);
        try out.appendSlice(allocator, packet_bytes[header_end..end]);
        cursor = end;
    }
    if (cursor != packet_bytes.len) return CodestreamError.InvalidCodestream;
}

fn tilePartCountForOptions(levels: u8, options: LosslessOptions) usize {
    if (options.tile_part_divisions == 'R') return @as(usize, levels) + 1;
    return 1;
}

fn appendTemporaryPayload(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    planes: color.RctPlanes,
    levels: u8,
    options: LosslessOptions,
    rpcl_stream: ?*RpclPacketStream,
    timings: ?*EncodeTimings,
) !void {
    if (options.emit_temporary_payload_sidecar) {
        try out.appendSlice(allocator, temporary_magic_v8);
        try appendU32Be(allocator, out, @as(u32, @intCast(planes.width)));
        try appendU32Be(allocator, out, @as(u32, @intCast(planes.height)));
        try out.append(allocator, planes.bit_depth);
        try out.append(allocator, levels);
        try appendU16Be(allocator, out, options.block_width);
        try appendU16Be(allocator, out, options.block_height);
        try out.append(allocator, options.tile_part_divisions orelse 0);
        try appendTilePartPlan(allocator, out, levels, options);
        try appendPacketPlan(allocator, out, planes.width, planes.height, levels, options);
        try appendU16Be(allocator, out, options.layers);
    }

    const bands = try subband.makeBands(allocator, planes.width, planes.height, levels);
    defer allocator.free(bands);
    const blocks = try subband.makeCodeBlocks(allocator, bands, options.block_width, options.block_height);
    defer allocator.free(blocks);

    const pass_stats = if (options.threads == 1)
        if (timings) |value| &value.t1_pass_stats else null
    else
        null;
    var catalogs = try buildComponentRpclShadowCatalogs(
        allocator,
        planes,
        bands,
        blocks,
        options,
        options.emit_temporary_payload_sidecar,
        pass_stats,
    );
    defer {
        for (&catalogs) |*catalog| catalog.deinit();
    }

    // Rate-targeted layers get a global PCRD allocation over the finished
    // block catalogs, replacing the per-block proportional split the
    // catalog builder installed. A probe assembly measures the real packet
    // header bytes per layer, then one refinement round charges them
    // against the byte targets so assembled layer sizes land on the ladder.
    if (options.rate_count > 0 and options.layers > 1) {
        var pcrd_data = try buildPcrdData(allocator, &catalogs, planes, bands, blocks, options);
        defer pcrd_data.deinit();
        try applyPcrdTargets(allocator, pcrd_data, &catalogs, blocks.len, options, &.{});

        var probe_stream: RpclPacketStream = .{};
        defer probe_stream.deinit();
        try appendRpclShadowStream(allocator, null, planes, bands, blocks, catalogs, levels, options, &probe_stream);
        var header_overhead = [_]u64{0} ** max_quality_layers;
        // The probe stream is in RPCL order (layer innermost), so packet k
        // belongs to layer k % layers.
        for (probe_stream.packet_header_lengths, 0..) |header_length, packet_index| {
            header_overhead[packet_index % options.layers] += header_length;
        }
        var cumulative: u64 = 0;
        for (header_overhead[0..options.layers]) |*value| {
            cumulative += value.*;
            value.* = cumulative;
        }
        try applyPcrdTargets(allocator, pcrd_data, &catalogs, blocks.len, options, header_overhead[0..options.layers]);
    }

    if (options.emit_temporary_payload_sidecar) {
        if (payloadBlockThreadCount(options, blocks.len) > 1) {
            try appendComponentPayload(allocator, out, 0, bands, blocks, catalogs[0].blocks, options);
            try appendComponentPayload(allocator, out, 1, bands, blocks, catalogs[1].blocks, options);
            try appendComponentPayload(allocator, out, 2, bands, blocks, catalogs[2].blocks, options);
        } else if (componentThreadCount(options) < 2) {
            try appendComponentPayload(allocator, out, 0, bands, blocks, catalogs[0].blocks, options);
            try appendComponentPayload(allocator, out, 1, bands, blocks, catalogs[1].blocks, options);
            try appendComponentPayload(allocator, out, 2, bands, blocks, catalogs[2].blocks, options);
        } else {
            try appendComponentPayloadsParallel(allocator, out, bands, blocks, catalogs, options);
        }
    }
    const shadow_out: ?*std.ArrayList(u8) = if (options.emit_temporary_payload_sidecar) out else null;
    try appendRpclShadowStream(allocator, shadow_out, planes, bands, blocks, catalogs, levels, options, rpcl_stream);
}

fn appendComponentPayloadsParallel(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    catalogs: [3]ComponentRpclShadowCatalog,
    options: LosslessOptions,
) !void {
    var jobs = [_]ComponentPayloadJob{
        .{ .component_index = 0, .bands = bands, .blocks = blocks, .catalog = catalogs[0].blocks, .options = options },
        .{ .component_index = 1, .bands = bands, .blocks = blocks, .catalog = catalogs[1].blocks, .options = options },
        .{ .component_index = 2, .bands = bands, .blocks = blocks, .catalog = catalogs[2].blocks, .options = options },
    };
    defer for (&jobs) |*job| job.deinit();

    try runComponentJobs(ComponentPayloadJob, &jobs, componentThreadCount(options), componentPayloadWorker);
    for (jobs) |job| try out.appendSlice(allocator, job.bytes);
}

fn appendRpclShadowStream(
    allocator: std.mem.Allocator,
    out: ?*std.ArrayList(u8),
    planes: color.RctPlanes,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    catalogs: [3]ComponentRpclShadowCatalog,
    levels: u8,
    options: LosslessOptions,
    rpcl_stream: ?*RpclPacketStream,
) !void {
    const plan = try makePacketPlan(planes.width, planes.height, levels, options);
    var rpcl_index = try buildRpclBlockIndex(allocator, plan, 3, levels, bands, blocks);
    defer rpcl_index.deinit();

    var packet_bytes: std.ArrayList(u8) = .empty;
    defer packet_bytes.deinit(allocator);
    var packet_lengths: std.ArrayList(u32) = .empty;
    defer packet_lengths.deinit(allocator);
    var packet_header_lengths: std.ArrayList(u32) = .empty;
    defer packet_header_lengths.deinit(allocator);

    var sequence: u64 = 0;
    var resolution_index: u8 = 0;
    while (resolution_index < plan.resolution_count) : (resolution_index += 1) {
        const resolution = plan.resolutions[resolution_index];
        var precinct_index: u64 = 0;
        while (precinct_index < resolution.precincts) : (precinct_index += 1) {
            var component: u16 = 0;
            while (component < 3) : (component += 1) {
                {
                    const first_layer_packet = packet_plan.Packet{
                        .sequence = sequence,
                        .resolution = resolution_index,
                        .precinct_x = @intCast(precinct_index % resolution.precincts_x),
                        .precinct_y = @intCast(precinct_index / resolution.precincts_x),
                        .precinct_index = precinct_index,
                        .component = component,
                        .layer = 0,
                    };
                    const selected = try rpcl_index.indexesFor(resolution_index, precinct_index, component);

                    try appendRpclShadowPacketsForSelection(
                        allocator,
                        &packet_bytes,
                        &packet_lengths,
                        &packet_header_lengths,
                        bands,
                        blocks,
                        options,
                        &catalogs[@intCast(component)],
                        selected,
                        first_layer_packet,
                        resolution_index,
                        component,
                        precinct_index,
                        options.layers,
                        &sequence,
                    );
                }
            }
        }
    }
    if (sequence != plan.packets or
        packet_lengths.items.len != plan.packets or
        packet_header_lengths.items.len != plan.packets)
    {
        return CodestreamError.InvalidCodestream;
    }

    if (out) |sidecar| {
        try appendU64Be(allocator, sidecar, @intCast(packet_lengths.items.len));
        try appendU64Be(allocator, sidecar, @intCast(packet_bytes.items.len));
        var cursor: usize = 0;
        for (packet_lengths.items) |packet_len| {
            try appendU32Be(allocator, sidecar, packet_len);
            const end = try std.math.add(usize, cursor, packet_len);
            try sidecar.appendSlice(allocator, packet_bytes.items[cursor..end]);
            cursor = end;
        }
        if (cursor != packet_bytes.items.len) return CodestreamError.InvalidCodestream;
    }

    if (rpcl_stream) |stream| {
        stream.deinit();
        const owned_lengths = try packet_lengths.toOwnedSlice(allocator);
        errdefer allocator.free(owned_lengths);
        const owned_header_lengths = try packet_header_lengths.toOwnedSlice(allocator);
        errdefer allocator.free(owned_header_lengths);
        const owned_bytes = try packet_bytes.toOwnedSlice(allocator);
        stream.* = .{
            .allocator = allocator,
            .packet_lengths = owned_lengths,
            .packet_header_lengths = owned_header_lengths,
            .packet_bytes = owned_bytes,
        };
    }
}

fn buildRpclBlockIndex(
    allocator: std.mem.Allocator,
    plan: packet_plan.Plan,
    component_count: u16,
    levels: u8,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
) !RpclBlockIndex {
    var index = try RpclBlockIndex.init(allocator, plan, component_count);
    errdefer index.deinit();

    var resolution_index: u8 = 0;
    while (resolution_index < plan.resolution_count) : (resolution_index += 1) {
        const resolution = plan.resolutions[resolution_index];
        var precinct_index: u64 = 0;
        while (precinct_index < resolution.precincts) : (precinct_index += 1) {
            const packet = packet_plan.Packet{
                .sequence = 0,
                .resolution = resolution_index,
                .precinct_x = @intCast(precinct_index % resolution.precincts_x),
                .precinct_y = @intCast(precinct_index / resolution.precincts_x),
                .precinct_index = precinct_index,
                .component = 0,
                .layer = 0,
            };
            const selected = try t2.collectRpclCodeBlockIndexes(allocator, plan, packet, levels, bands, blocks);
            defer allocator.free(selected);

            var component: u16 = 0;
            while (component < component_count) : (component += 1) {
                const cell = try index.cell(resolution_index, precinct_index, component);
                try cell.indexes.appendSlice(allocator, selected);
            }
        }
    }

    return index;
}

/// Rate-distortion data for global PCRD (ISO 15444-1 J.14): per-block
/// cumulative pass bytes plus band-weighted per-pass distortion reductions,
/// reused for every target refinement. Normal direct-MQ encode captures the
/// reductions during its real coding pass; style/backend fallbacks retain the
/// parallel symbol-coder extraction.
const PcrdData = struct {
    allocator: std.mem.Allocator,
    blocks: []rate_alloc.PcrdBlock,
    pass_bytes: []u64,
    distortions: []f64,
    total_full_bytes: u64,

    fn deinit(self: *PcrdData) void {
        self.allocator.free(self.blocks);
        self.allocator.free(self.pass_bytes);
        self.allocator.free(self.distortions);
        self.* = undefined;
    }
};

const PcrdDistortionJob = struct {
    catalogs: *const [3]ComponentRpclShadowCatalog,
    component_planes: [3][]const i32,
    stride: usize,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    band_weights: []const f64,
    base_style: ebcot.CodeBlockStyle,
    spans: []const PcrdSpan,
    distortions: []f64,
    allocator: std.mem.Allocator,
    first_slot: usize,
    slot_count: usize,
    result: anyerror!void = {},
};

const PcrdSpan = struct { start: usize, count: usize };

fn pcrdDistortionWorker(job: *PcrdDistortionJob) void {
    var scratch = ebcot.BlockScratch.init(job.allocator);
    defer scratch.deinit();
    var distortion_scratch: [164]f64 = undefined;

    var offset: usize = 0;
    while (offset < job.slot_count) : (offset += 1) {
        const slot = job.first_slot + offset;
        const component = slot / job.blocks.len;
        const block_index = slot % job.blocks.len;
        const span = job.spans[slot];
        if (span.count == 0) continue;

        const block = job.blocks[block_index];
        const band = job.bands[block.band_index];
        const style = codeBlockStyleForBand(job.base_style, band.kind);
        const distortion_passes = ebcot.passDistortions(
            &scratch,
            job.component_planes[component],
            job.stride,
            block.rect,
            style,
            distortion_scratch[0..],
        ) catch |err| {
            job.result = err;
            return;
        };
        if (distortion_passes != span.count) {
            job.result = CodestreamError.InvalidCodestream;
            return;
        }
        const weight = job.band_weights[block.band_index];
        for (0..span.count) |pass_index| {
            job.distortions[span.start + pass_index] = distortion_scratch[pass_index] * weight;
        }
    }
    job.result = {};
}

/// Extracts the PCRD rate-distortion tables from the finished block
/// catalogs. Direct-MQ blocks already carry per-pass distortion; any style or
/// backend fallback missing that metadata uses the parallel symbol oracle.
fn buildPcrdData(
    allocator: std.mem.Allocator,
    catalogs: *const [3]ComponentRpclShadowCatalog,
    planes: color.RctPlanes,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    options: LosslessOptions,
) !PcrdData {
    const levels = dwtLevelsFromBands(bands);
    const total_blocks = blocks.len * 3;
    const component_planes = [3][]const i32{ planes.planes[0], planes.planes[1], planes.planes[2] };

    const base_style = ebcot.CodeBlockStyle{
        .bypass = options.bypass,
        .reset_context = options.reset_context,
        .terminate_all = options.terminate_all,
        .vertical_causal = options.vertical_causal,
        .predictable_termination = options.predictable_termination,
        .segmentation_symbols = options.segmentation_symbols,
    };

    const band_weights = try allocator.alloc(f64, bands.len);
    defer allocator.free(band_weights);
    for (bands, 0..) |band, index| {
        band_weights[index] = try pcrdBandWeight(band, options, planes.bit_depth, levels);
    }

    const spans = try allocator.alloc(PcrdSpan, total_blocks);
    defer allocator.free(spans);

    var total_passes: usize = 0;
    var total_full_bytes: u64 = 0;
    for (0..3) |component| {
        for (blocks, 0..) |block, block_index| {
            if (block.band_index >= bands.len) return CodestreamError.InvalidCodestream;
            const segment = catalogs[component].blocks[block_index].segment;
            total_full_bytes = try std.math.add(u64, total_full_bytes, segment.byte_length);
            spans[component * blocks.len + block_index] = .{ .start = total_passes, .count = segment.pass_count };
            total_passes += segment.pass_count;
        }
    }

    const pass_bytes = try allocator.alloc(u64, total_passes);
    errdefer allocator.free(pass_bytes);
    const distortions = try allocator.alloc(f64, total_passes);
    errdefer allocator.free(distortions);
    var direct_distortions_complete = true;
    for (0..3) |component| {
        for (blocks, 0..) |_, block_index| {
            const slot = component * blocks.len + block_index;
            const shadow = catalogs[component].blocks[block_index];
            const segment = shadow.segment;
            const span = spans[slot];
            for (0..span.count) |pass_index| {
                pass_bytes[span.start + pass_index] = segment.passes[pass_index].cumulative_bytes;
            }
            if (shadow.pass_distortions.len != span.count) {
                direct_distortions_complete = false;
            } else {
                const weight = band_weights[blocks[block_index].band_index];
                for (shadow.pass_distortions, 0..) |value, pass_index| {
                    distortions[span.start + pass_index] = value * weight;
                }
            }
        }
    }

    const worker_count = payloadBlockThreadCount(options, total_blocks);
    if (!direct_distortions_complete and worker_count <= 1) {
        var job = PcrdDistortionJob{
            .catalogs = catalogs,
            .component_planes = component_planes,
            .stride = planes.width,
            .bands = bands,
            .blocks = blocks,
            .band_weights = band_weights,
            .base_style = base_style,
            .spans = spans,
            .distortions = distortions,
            .allocator = allocator,
            .first_slot = 0,
            .slot_count = total_blocks,
        };
        pcrdDistortionWorker(&job);
        try job.result;
    } else if (!direct_distortions_complete) {
        const jobs = try allocator.alloc(PcrdDistortionJob, worker_count);
        defer allocator.free(jobs);
        const chunk = (total_blocks + worker_count - 1) / worker_count;
        var job_count: usize = 0;
        var first: usize = 0;
        while (first < total_blocks) : (first += chunk) {
            jobs[job_count] = .{
                .catalogs = catalogs,
                .component_planes = component_planes,
                .stride = planes.width,
                .bands = bands,
                .blocks = blocks,
                .band_weights = band_weights,
                .base_style = base_style,
                .spans = spans,
                .distortions = distortions,
                .allocator = allocator,
                .first_slot = first,
                .slot_count = @min(chunk, total_blocks - first),
            };
            job_count += 1;
        }

        const threads = try allocator.alloc(std.Thread, job_count - 1);
        defer allocator.free(threads);
        var spawned: usize = 0;
        while (spawned + 1 < job_count) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, pcrdDistortionWorker, .{&jobs[spawned]}) catch |err| {
                for (threads[0..spawned]) |thread| thread.join();
                return err;
            };
        }
        pcrdDistortionWorker(&jobs[job_count - 1]);
        for (threads[0..spawned]) |thread| thread.join();
        for (jobs[0..job_count]) |job| try job.result;
    }

    const pcrd_blocks = try allocator.alloc(rate_alloc.PcrdBlock, total_blocks);
    errdefer allocator.free(pcrd_blocks);
    for (spans, 0..) |span, slot| {
        pcrd_blocks[slot] = .{
            .pass_bytes = pass_bytes[span.start..][0..span.count],
            .pass_distortion = distortions[span.start..][0..span.count],
        };
    }

    return .{
        .allocator = allocator,
        .blocks = pcrd_blocks,
        .pass_bytes = pass_bytes,
        .distortions = distortions,
        .total_full_bytes = total_full_bytes,
    };
}

/// Applies one global PCRD allocation round: layer byte targets from the
/// compression ratios minus the (cumulative) packet-header overhead measured
/// on a previous assembly, then a slope-threshold allocation and an in-place
/// rewrite of every catalog block's layer truncations (BYPASS segment
/// snapping preserved via normalizedLayerTruncation).
fn applyPcrdTargets(
    allocator: std.mem.Allocator,
    data: PcrdData,
    catalogs: *[3]ComponentRpclShadowCatalog,
    blocks_len: usize,
    options: LosslessOptions,
    header_overhead: []const u64,
) !void {
    const layer_count: usize = options.layers;
    const total_blocks = blocks_len * 3;

    var targets: [max_quality_layers]u64 = undefined;
    rate_alloc.layerTargetsFromRates(
        targets[0..layer_count],
        data.total_full_bytes,
        options.rates[0..options.rate_count],
    ) catch return CodestreamError.InvalidCodestream;
    // Non-final targets are payload budgets; charge the measured packet
    // header bytes against them so the assembled layer sizes land on the
    // requested ladder. Keep the sequence monotone.
    var previous_target: u64 = 0;
    for (0..layer_count - 1) |layer| {
        const overhead = if (layer < header_overhead.len) header_overhead[layer] else 0;
        targets[layer] = @max(previous_target, targets[layer] -| overhead);
        previous_target = targets[layer];
    }

    const out_passes = try allocator.alloc(u16, total_blocks * layer_count);
    defer allocator.free(out_passes);
    rate_alloc.allocatePcrdPasses(allocator, data.blocks, targets[0..layer_count], out_passes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return CodestreamError.InvalidCodestream,
    };

    for (0..3) |component| {
        for (0..blocks_len) |block_index| {
            const slot = component * blocks_len + block_index;
            const shadow = &catalogs[component].blocks[block_index];
            var previous = t2.LayerTruncation{ .cumulative_passes = 0, .cumulative_bytes = 0 };
            for (0..layer_count) |layer| {
                const is_final = layer == layer_count - 1;
                const requested = out_passes[slot * layer_count + layer];
                const truncation = try normalizedLayerTruncation(shadow.segment, requested, previous, is_final);
                shadow.layers[layer] = .{
                    .cumulative_passes = truncation.cumulative_passes,
                    .cumulative_bytes = truncation.cumulative_bytes,
                };
                previous = shadow.layers[layer];
            }
        }
    }
}

fn buildComponentRpclShadowCatalogs(
    allocator: std.mem.Allocator,
    planes: color.RctPlanes,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    options: LosslessOptions,
    include_bitplane_payload: bool,
    pass_stats: ?*ebcot.EncodePassStats,
) ![3]ComponentRpclShadowCatalog {
    const block_worker_count = payloadBlockThreadCount(options, blocks.len);
    if (block_worker_count > 1 or componentThreadCount(options) < 2) {
        if (block_worker_count > 1) {
            return buildComponentRpclShadowCatalogsBlocksParallel(
                allocator,
                planes,
                bands,
                blocks,
                options,
                include_bitplane_payload,
                block_worker_count,
            );
        }
        var catalogs: [3]ComponentRpclShadowCatalog = undefined;
        var initialized: usize = 0;
        errdefer {
            for (catalogs[0..initialized]) |*catalog| catalog.deinit();
        }
        catalogs[0] = try buildComponentRpclShadowCatalog(allocator, planes.planes[0], planes.width, bands, blocks, planes.bit_depth, options, include_bitplane_payload, pass_stats);
        initialized += 1;
        catalogs[1] = try buildComponentRpclShadowCatalog(allocator, planes.planes[1], planes.width, bands, blocks, planes.bit_depth, options, include_bitplane_payload, pass_stats);
        initialized += 1;
        catalogs[2] = try buildComponentRpclShadowCatalog(allocator, planes.planes[2], planes.width, bands, blocks, planes.bit_depth, options, include_bitplane_payload, pass_stats);
        return catalogs;
    }

    var jobs = [_]ComponentCatalogJob{
        .{ .plane = planes.planes[0], .stride = planes.width, .bands = bands, .blocks = blocks, .nominal_bitplanes = planes.bit_depth, .options = options, .include_bitplane_payload = include_bitplane_payload },
        .{ .plane = planes.planes[1], .stride = planes.width, .bands = bands, .blocks = blocks, .nominal_bitplanes = planes.bit_depth, .options = options, .include_bitplane_payload = include_bitplane_payload },
        .{ .plane = planes.planes[2], .stride = planes.width, .bands = bands, .blocks = blocks, .nominal_bitplanes = planes.bit_depth, .options = options, .include_bitplane_payload = include_bitplane_payload },
    };
    defer for (&jobs) |*job| job.deinit();

    try runComponentJobs(ComponentCatalogJob, &jobs, componentThreadCount(options), componentCatalogWorker);

    var catalogs: [3]ComponentRpclShadowCatalog = undefined;
    for (&jobs, 0..) |*job, index| {
        catalogs[index] = job.catalog;
        job.initialized = false;
    }
    return catalogs;
}

fn buildComponentRpclShadowCatalogsBlocksParallel(
    allocator: std.mem.Allocator,
    planes: color.RctPlanes,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    options: LosslessOptions,
    include_bitplane_payload: bool,
    worker_count: usize,
) ![3]ComponentRpclShadowCatalog {
    var catalog_blocks: [3][]RpclShadowBlock = undefined;
    var initialized_catalogs: usize = 0;
    errdefer {
        for (catalog_blocks[0..initialized_catalogs]) |component_blocks| {
            allocator.free(component_blocks);
        }
    }
    inline for (0..3) |component| {
        catalog_blocks[component] = try allocator.alloc(RpclShadowBlock, blocks.len);
        initialized_catalogs += 1;
    }

    const sorted_blocks = try allocator.alloc(usize, blocks.len);
    defer allocator.free(sorted_blocks);
    for (sorted_blocks, 0..) |*entry, index| entry.* = index;
    std.mem.sort(usize, sorted_blocks, EncodeBlockOrderContext{ .bands = bands, .blocks = blocks }, encodeBlockHeavierThan);

    const block_order_len = std.math.mul(usize, blocks.len, 3) catch return CodestreamError.ImageTooLarge;
    const block_order = try allocator.alloc(ComponentCatalogBlockRef, block_order_len);
    defer allocator.free(block_order);
    var order_index: usize = 0;
    for (sorted_blocks) |block_index| {
        inline for (0..3) |component| {
            block_order[order_index] = .{ .component = component, .block_index = block_index };
            order_index += 1;
        }
    }

    var jobs = try allocator.alloc(ComponentCatalogAllBlockJob, worker_count);
    defer allocator.free(jobs);
    var next_block = std.atomic.Value(usize).init(0);
    for (jobs) |*job| {
        job.* = .{
            .allocator = allocator,
            .planes = .{ planes.planes[0], planes.planes[1], planes.planes[2] },
            .stride = planes.width,
            .bands = bands,
            .blocks = blocks,
            .catalog_blocks = catalog_blocks,
            .next_block = &next_block,
            .block_order = block_order,
            .nominal_bitplanes = planes.bit_depth,
            .options = options,
            .include_bitplane_payload = include_bitplane_payload,
        };
    }
    defer for (jobs) |*job| job.deinit();

    const spawn_count = worker_count - 1;
    var threads = try allocator.alloc(std.Thread, spawn_count);
    defer allocator.free(threads);
    var spawned: usize = 0;
    while (spawned < spawn_count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, componentCatalogAllBlockWorker, .{&jobs[spawned]}) catch |err| {
            for (threads[0..spawned]) |thread| thread.join();
            return err;
        };
    }

    componentCatalogAllBlockWorker(&jobs[spawn_count]);
    for (threads[0..spawned]) |thread| thread.join();

    for (jobs) |job| try job.result;
    for (jobs) |*job| job.release();

    return .{
        .{ .allocator = allocator, .blocks = catalog_blocks[0] },
        .{ .allocator = allocator, .blocks = catalog_blocks[1] },
        .{ .allocator = allocator, .blocks = catalog_blocks[2] },
    };
}

fn buildComponentRpclShadowCatalog(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    nominal_bitplanes: u8,
    options: LosslessOptions,
    include_bitplane_payload: bool,
    pass_stats: ?*ebcot.EncodePassStats,
) !ComponentRpclShadowCatalog {
    const catalog_blocks = try allocator.alloc(RpclShadowBlock, blocks.len);
    errdefer allocator.free(catalog_blocks);

    var initialized: usize = 0;
    errdefer {
        for (catalog_blocks[0..initialized]) |*block| block.deinit(allocator);
    }

    const worker_count = payloadBlockThreadCount(options, blocks.len);
    if (worker_count > 1) {
        try buildComponentRpclShadowCatalogBlocksParallel(
            allocator,
            plane,
            stride,
            bands,
            blocks,
            catalog_blocks,
            nominal_bitplanes,
            options,
            include_bitplane_payload,
            worker_count,
        );
        return .{
            .allocator = allocator,
            .blocks = catalog_blocks,
        };
    }

    var bitplane_scratch = bitplane.BlockScratch.init(allocator);
    defer bitplane_scratch.deinit();
    var ebcot_scratch = ebcot.DirectBlockScratch.init(allocator);
    defer ebcot_scratch.deinit();
    ebcot_scratch.encode_pass_stats = pass_stats;
    for (blocks, 0..) |block, index| {
        if (block.band_index >= bands.len) return CodestreamError.InvalidCodestream;
        const block_nominal_bitplanes = try bandNominalBitplanesForTransform(
            nominal_bitplanes,
            bands[block.band_index].kind,
            bands[block.band_index].level,
            options.transform,
            options.guard_bits,
            options.quantization,
            dwtLevelsFromBands(bands),
        );
        catalog_blocks[index] = try buildRpclShadowBlock(
            allocator,
            &bitplane_scratch,
            &ebcot_scratch,
            plane,
            stride,
            block.rect,
            bands[block.band_index].kind,
            block_nominal_bitplanes,
            options,
            include_bitplane_payload,
        );
        const layer_count: usize = @intCast(options.layers);
        catalog_blocks[index].encoded.layers = catalog_blocks[index].layers[0..layer_count];
        initialized += 1;
    }

    return .{
        .allocator = allocator,
        .blocks = catalog_blocks,
    };
}

fn buildComponentRpclShadowCatalogBlocksParallel(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    catalog_blocks: []RpclShadowBlock,
    nominal_bitplanes: u8,
    options: LosslessOptions,
    include_bitplane_payload: bool,
    worker_count: usize,
) !void {
    if (blocks.len != catalog_blocks.len) return CodestreamError.InvalidCodestream;

    const block_order = try allocator.alloc(usize, blocks.len);
    defer allocator.free(block_order);
    for (block_order, 0..) |*entry, index| entry.* = index;
    std.mem.sort(usize, block_order, EncodeBlockOrderContext{ .bands = bands, .blocks = blocks }, encodeBlockHeavierThan);

    var jobs = try allocator.alloc(ComponentCatalogBlockJob, worker_count);
    defer allocator.free(jobs);
    var next_block = std.atomic.Value(usize).init(0);
    for (jobs, 0..) |*job, index| {
        _ = index;
        job.* = .{
            .allocator = allocator,
            .plane = plane,
            .stride = stride,
            .bands = bands,
            .blocks = blocks,
            .catalog_blocks = catalog_blocks,
            .next_block = &next_block,
            .block_order = block_order,
            .nominal_bitplanes = nominal_bitplanes,
            .options = options,
            .include_bitplane_payload = include_bitplane_payload,
        };
    }
    defer for (jobs) |*job| job.deinit();

    const spawn_count = worker_count - 1;
    var threads = try allocator.alloc(std.Thread, spawn_count);
    defer allocator.free(threads);
    var spawned: usize = 0;
    while (spawned < spawn_count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, componentCatalogBlockWorker, .{&jobs[spawned]}) catch |err| {
            for (threads[0..spawned]) |thread| thread.join();
            return err;
        };
    }

    componentCatalogBlockWorker(&jobs[spawn_count]);
    for (threads[0..spawned]) |thread| thread.join();

    for (jobs) |job| try job.result;
    for (jobs) |*job| job.release();
}

const EncodeBlockOrderContext = struct {
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
};

fn encodeBlockHeavierThan(context: EncodeBlockOrderContext, lhs: usize, rhs: usize) bool {
    const a = context.blocks[lhs];
    const b = context.blocks[rhs];
    const a_area = a.rect.width * a.rect.height;
    const b_area = b.rect.width * b.rect.height;
    if (a_area != b_area) return a_area > b_area;
    const a_level = if (a.band_index < context.bands.len) context.bands[a.band_index].level else 0;
    const b_level = if (b.band_index < context.bands.len) context.bands[b.band_index].level else 0;
    if (a_level != b_level) return a_level < b_level;
    return lhs < rhs;
}

fn buildRpclShadowBlock(
    allocator: std.mem.Allocator,
    bitplane_scratch: *bitplane.BlockScratch,
    ebcot_scratch: *ebcot.DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    band_kind: subband.Kind,
    nominal_bitplanes: u8,
    options: LosslessOptions,
    include_bitplane_payload: bool,
) !RpclShadowBlock {
    const block_style = codeBlockStyleForBand(.{
        .bypass = options.bypass,
        .reset_context = options.reset_context,
        .terminate_all = options.terminate_all,
        .vertical_causal = options.vertical_causal,
        .predictable_termination = options.predictable_termination,
        .segmentation_symbols = options.segmentation_symbols,
    }, band_kind);
    var direct_distortions: [164]f64 = undefined;
    const capture_direct_distortions = options.rate_count > 0 and
        options.layers > 1 and
        options.t1_backend == .iso_mq and
        !block_style.terminate_all;
    var segment = switch (options.t1_backend) {
        .legacy_mq => try ebcot.encodeCodeBlockSegmentContinuous(allocator, plane, stride, rect),
        // terminate_all flushes an independently terminated ISO MQ segment per
        // coding pass (ISO 15444-1 D.4.5). The direct ISO scratch encoder emits
        // one continuous segment, so route terminate_all through the dedicated
        // ISO MQ per-pass terminated encoder. Everything else takes the hot
        // direct path with per-worker scratch reuse; it produces the same bytes
        // as the symbol-based encoder pair.
        .iso_mq => if (block_style.terminate_all)
            try ebcot.encodeCodeBlockSegmentIsoMqTerminatedWithStyle(allocator, plane, stride, rect, block_style)
        else if (capture_direct_distortions)
            try ebcot.encodeCodeBlockSegmentDirectIsoScratchWithStyleAndDistortions(
                ebcot_scratch,
                plane,
                stride,
                rect,
                block_style,
                direct_distortions[0..],
            )
        else
            try ebcot.encodeCodeBlockSegmentDirectIsoScratchWithStyle(ebcot_scratch, plane, stride, rect, block_style),
    };
    errdefer segment.deinit(allocator);

    var pass_distortions: []f64 = &.{};
    if (capture_direct_distortions) {
        pass_distortions = try allocator.dupe(f64, direct_distortions[0..segment.pass_count]);
    }
    errdefer if (pass_distortions.len > 0) allocator.free(pass_distortions);

    var bitplane_passes: ?bitplane.EncodedBlockPasses = null;
    errdefer if (bitplane_passes) |*passes| passes.deinit(allocator);
    if (include_bitplane_payload) {
        const bitplane_view = try bitplane.encodeBlockPassesScratch(bitplane_scratch, plane, stride, rect);
        bitplane_passes = try cloneBitplanePasses(allocator, bitplane_view);
        const coding_passes = bitplane.isoCodingPassCount(bitplane_passes.?.bitplanes, bitplane_passes.?.non_zero_count);
        if (segment.pass_count != coding_passes) return CodestreamError.InvalidCodestream;
    }

    var layers = [_]t2.LayerTruncation{.{ .cumulative_passes = 0, .cumulative_bytes = 0 }} ** max_quality_layers;
    try computeLayerTruncations(&layers, options, segment);

    return .{
        .bitplane = bitplane_passes,
        .segment = segment,
        .pass_distortions = pass_distortions,
        .layers = layers,
        .encoded = .{
            .location = .{ .leaf_x = 0, .leaf_y = 0 },
            .nominal_bitplanes = @max(nominal_bitplanes, segment.bitplanes),
            .encoded_bitplanes = segment.bitplanes,
            .layers = &.{},
            .payload = segment.bytes,
            .segments = segment.segments orelse &.{},
        },
    };
}

fn encodeCodeBlockSegmentForOptions(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    band_kind: subband.Kind,
    options: LosslessOptions,
) !ebcot.CodeBlockSegment {
    return switch (options.t1_backend) {
        .legacy_mq => ebcot.encodeCodeBlockSegmentContinuous(allocator, plane, stride, rect),
        .iso_mq => blk: {
            const style = ebcot.CodeBlockStyle{
                .band_kind = band_kind,
                .bypass = options.bypass,
                .reset_context = options.reset_context,
                .terminate_all = options.terminate_all,
                .vertical_causal = options.vertical_causal,
                .predictable_termination = options.predictable_termination,
                .segmentation_symbols = options.segmentation_symbols,
            };
            var block = try ebcot.encodeBlockWithStyle(allocator, plane, stride, rect, style);
            defer block.deinit(allocator);
            const view = ebcot.EncodedBlockView{
                .bitplanes = block.bitplanes,
                .non_zero_count = block.non_zero_count,
                .passes = block.passes,
                .symbols = block.symbols,
            };
            break :blk if (style.terminate_all)
                ebcot.encodeBlockSymbolsSegmentIsoMqTerminated(allocator, view, style)
            else if (style.bypass)
                ebcot.encodeBlockSymbolsSegmentIsoMqBypass(allocator, view, style)
            else
                ebcot.encodeBlockSymbolsSegmentIsoMqContinuousWithStyle(allocator, view, style);
        },
    };
}

fn cloneBitplanePasses(
    allocator: std.mem.Allocator,
    view: bitplane.EncodedBlockPassView,
) !bitplane.EncodedBlockPasses {
    const significance_bytes = try allocator.dupe(u8, view.significance_bytes);
    errdefer allocator.free(significance_bytes);
    const refinement_bytes = try allocator.dupe(u8, view.refinement_bytes);
    errdefer allocator.free(refinement_bytes);
    const cleanup_bytes = try allocator.dupe(u8, view.cleanup_bytes);
    errdefer allocator.free(cleanup_bytes);

    return .{
        .active_rect = view.active_rect,
        .bitplanes = view.bitplanes,
        .non_zero_count = view.non_zero_count,
        .significance_bytes = significance_bytes,
        .refinement_bytes = refinement_bytes,
        .cleanup_bytes = cleanup_bytes,
    };
}

fn computeLayerTruncations(
    out: *[max_quality_layers]t2.LayerTruncation,
    options: LosslessOptions,
    segment: ebcot.CodeBlockSegment,
) !void {
    var layers: [max_quality_layers]rate_alloc.Truncation = undefined;
    const layer_count: usize = @intCast(options.layers);
    const block = rate_alloc.Block{
        .pass_count = segment.pass_count,
        .byte_length = segment.byte_length,
    };
    if (options.rate_count > 0) {
        try rate_alloc.allocateFromCompressionRatios(
            layers[0..layer_count],
            block,
            options.rates[0..options.rate_count],
        );
    } else {
        try rate_alloc.allocateEven(layers[0..layer_count], block);
    }

    @memset(out, .{ .cumulative_passes = 0, .cumulative_bytes = 0 });
    var previous = t2.LayerTruncation{ .cumulative_passes = 0, .cumulative_bytes = 0 };
    for (layers[0..layer_count], 0..) |layer, index| {
        const is_final = index == layer_count - 1;
        const truncation = try normalizedLayerTruncation(segment, layer.cumulative_passes, previous, is_final);
        out[index] = .{
            .cumulative_passes = truncation.cumulative_passes,
            .cumulative_bytes = truncation.cumulative_bytes,
        };
        previous = out[index];
    }
}

fn normalizedLayerTruncation(
    segment: ebcot.CodeBlockSegment,
    requested_passes: u16,
    previous: t2.LayerTruncation,
    is_final: bool,
) !t2.LayerTruncation {
    if (is_final) {
        return .{
            .cumulative_passes = segment.pass_count,
            .cumulative_bytes = segment.byte_length,
        };
    }

    if (segment.segments) |segments| {
        // BYPASS payloads consist of independently terminated codeword
        // segments; quality layers may only truncate on segment boundaries,
        // so snap the requested pass count down to the nearest boundary.
        var cumulative_passes: u16 = 0;
        var cumulative_bytes: u64 = 0;
        var best = previous;
        for (segments) |span| {
            cumulative_passes = std.math.add(u16, cumulative_passes, span.pass_count) catch
                return CodestreamError.InvalidCodestream;
            cumulative_bytes = try std.math.add(u64, cumulative_bytes, span.byte_length);
            if (cumulative_passes > requested_passes) break;
            if (cumulative_passes > previous.cumulative_passes and
                cumulative_bytes > previous.cumulative_bytes and
                cumulative_bytes < segment.byte_length)
            {
                best = .{
                    .cumulative_passes = cumulative_passes,
                    .cumulative_bytes = cumulative_bytes,
                };
            }
        }
        return best;
    }

    var passes = @min(requested_passes, segment.pass_count);
    while (passes > previous.cumulative_passes) {
        const truncation = try segment.truncationPointForPasses(passes);
        if (truncation.cumulative_bytes > previous.cumulative_bytes and
            truncation.cumulative_bytes < segment.byte_length)
        {
            return .{
                .cumulative_passes = truncation.cumulative_passes,
                .cumulative_bytes = truncation.cumulative_bytes,
            };
        }
        passes -= 1;
    }

    return previous;
}

fn appendRpclShadowPacketsForSelection(
    allocator: std.mem.Allocator,
    packet_bytes: *std.ArrayList(u8),
    packet_lengths: *std.ArrayList(u32),
    packet_header_lengths: *std.ArrayList(u32),
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    options: LosslessOptions,
    catalog: *const ComponentRpclShadowCatalog,
    selected: []const usize,
    first_layer_packet: packet_plan.Packet,
    expected_resolution: u8,
    expected_component: u16,
    expected_precinct: u64,
    layer_count: u16,
    sequence: *u64,
) !void {
    if (selected.len == 0) {
        var layer: u16 = 0;
        while (layer < layer_count) : (layer += 1) {
            const start = packet_bytes.items.len;
            try t2.appendPacketPresenceHeader(allocator, packet_bytes, false);
            try appendShadowPacketLength(allocator, packet_lengths, packet_bytes.items.len - start);
            try appendShadowPacketLength(allocator, packet_header_lengths, packet_bytes.items.len - start);
            sequence.* += 1;
        }
        return;
    }

    const groups = try buildRpclPacketBandGroups(allocator, bands, blocks, options, catalog, selected, layer_count);
    defer {
        for (groups) |*group| group.deinit(allocator);
        allocator.free(groups);
    }

    var layer: u16 = 0;
    while (layer < layer_count) : (layer += 1) {
        const packet = packet_plan.Packet{
            .sequence = sequence.*,
            .resolution = first_layer_packet.resolution,
            .precinct_x = first_layer_packet.precinct_x,
            .precinct_y = first_layer_packet.precinct_y,
            .precinct_index = first_layer_packet.precinct_index,
            .component = first_layer_packet.component,
            .layer = layer,
        };
        const start = packet_bytes.items.len;
        const written = try appendRpclPacketForBandGroups(
            allocator,
            packet_bytes,
            groups,
            packet,
            expected_resolution,
            expected_component,
            expected_precinct,
        );
        try appendShadowPacketLength(allocator, packet_lengths, packet_bytes.items.len - start);
        try appendShadowPacketLength(allocator, packet_header_lengths, written.header_length);
        sequence.* += 1;
    }
}

fn buildRpclPacketBandGroups(
    allocator: std.mem.Allocator,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    options: LosslessOptions,
    catalog: *const ComponentRpclShadowCatalog,
    selected: []const usize,
    layer_count: u16,
) ![]RpclPacketBandGroup {
    var groups: std.ArrayList(RpclPacketBandGroup) = .empty;
    errdefer {
        for (groups.items) |*group| group.deinit(allocator);
        groups.deinit(allocator);
    }

    var cursor: usize = 0;
    while (cursor < selected.len) {
        const first_source = selected[cursor];
        if (first_source >= blocks.len or first_source >= catalog.blocks.len) return CodestreamError.InvalidCodestream;
        const band_index = blocks[first_source].band_index;
        if (band_index >= bands.len) return CodestreamError.InvalidCodestream;

        var end = cursor + 1;
        while (end < selected.len and blocks[selected[end]].band_index == band_index) : (end += 1) {
            if (selected[end] >= blocks.len or selected[end] >= catalog.blocks.len) return CodestreamError.InvalidCodestream;
        }

        try groups.append(allocator, try buildRpclPacketBandGroup(
            allocator,
            bands[band_index],
            blocks,
            options,
            catalog,
            selected[cursor..end],
            band_index,
            layer_count,
        ));
        cursor = end;
    }

    return groups.toOwnedSlice(allocator);
}

fn buildRpclPacketBandGroup(
    allocator: std.mem.Allocator,
    band: subband.Band,
    blocks: []const subband.CodeBlock,
    options: LosslessOptions,
    catalog: *const ComponentRpclShadowCatalog,
    selected: []const usize,
    band_index: usize,
    layer_count: u16,
) !RpclPacketBandGroup {
    if (selected.len == 0) return CodestreamError.InvalidCodestream;
    const grid = try t2.CodeBlockGrid.init(
        band.rect.x,
        band.rect.y,
        band.rect.width,
        band.rect.height,
        options.block_width,
        options.block_height,
    );

    var min_x: usize = std.math.maxInt(usize);
    var min_y: usize = std.math.maxInt(usize);
    var max_x: usize = 0;
    var max_y: usize = 0;
    const locations = try allocator.alloc(t2.PacketBlockLocation, selected.len);
    defer allocator.free(locations);
    for (selected, 0..) |source_index, index| {
        if (source_index >= blocks.len or source_index >= catalog.blocks.len) return CodestreamError.InvalidCodestream;
        const block = blocks[source_index];
        if (block.band_index != band_index) return CodestreamError.InvalidCodestream;
        const location = try grid.locationForRect(.{
            .x = block.rect.x,
            .y = block.rect.y,
            .width = block.rect.width,
            .height = block.rect.height,
        });
        locations[index] = location;
        min_x = @min(min_x, location.leaf_x);
        min_y = @min(min_y, location.leaf_y);
        max_x = @max(max_x, location.leaf_x);
        max_y = @max(max_y, location.leaf_y);
    }

    const leaves_x = max_x - min_x + 1;
    const leaves_y = max_y - min_y + 1;
    const leaf_count = try std.math.mul(usize, leaves_x, leaves_y);
    if (leaf_count != selected.len) return CodestreamError.InvalidCodestream;

    const encoded = try allocator.alloc(t2.EncodedLayerBlock, leaf_count);
    errdefer allocator.free(encoded);
    const filled = try allocator.alloc(bool, leaf_count);
    defer allocator.free(filled);
    @memset(filled, false);

    for (selected, 0..) |source_index, source_offset| {
        const location = locations[source_offset];
        const local_x = location.leaf_x - min_x;
        const local_y = location.leaf_y - min_y;
        const local_index = local_y * leaves_x + local_x;
        if (local_index >= leaf_count or filled[local_index]) return CodestreamError.InvalidCodestream;
        filled[local_index] = true;
        encoded[local_index] = catalog.blocks[source_index].encoded;
        encoded[local_index].location = .{ .leaf_x = local_x, .leaf_y = local_y };
    }

    for (filled) |is_filled| {
        if (!is_filled) return CodestreamError.InvalidCodestream;
    }

    var writer_state = try t2.PrecinctPacketWriterState.initForEncodedBlocks(allocator, encoded);
    errdefer writer_state.deinit();
    if (writer_state.layer_count == null or writer_state.layer_count.? != layer_count) {
        return CodestreamError.InvalidCodestream;
    }

    return .{
        .band_index = band_index,
        .encoded = encoded,
        .writer_state = writer_state,
    };
}

fn appendRpclPacketForBandGroups(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    groups: []RpclPacketBandGroup,
    packet: packet_plan.Packet,
    expected_resolution: u8,
    expected_component: u16,
    expected_precinct: u64,
) !t2.WrittenPacket {
    if (packet.resolution != expected_resolution or
        packet.component != expected_component or
        packet.precinct_index != expected_precinct)
    {
        return CodestreamError.InvalidCodestream;
    }
    if (groups.len > max_rpcl_packet_band_groups) return CodestreamError.InvalidCodestream;

    var prepared_storage: [max_rpcl_packet_band_groups]PreparedRpclPacketGroup = undefined;
    const prepared = prepared_storage[0..groups.len];
    var initialized: usize = 0;
    defer {
        for (prepared[0..initialized]) |*group| group.deinit(allocator);
    }

    var packet_included = false;
    var payload_length: usize = 0;
    var included_blocks: usize = 0;
    for (groups, 0..) |*group, group_index| {
        prepared[group_index] = try prepareRpclPacketGroup(allocator, group, packet.layer);
        initialized += 1;
        packet_included = packet_included or t2.packetBlocksIncluded(prepared[group_index].packet_blocks);
        for (prepared[group_index].packet_blocks) |packet_block| {
            if (packet_block.included) {
                payload_length = try std.math.add(usize, payload_length, packet_block.byte_length);
                included_blocks += 1;
            }
        }
    }

    const header_offset = out.items.len;
    var writer = t2.PacketHeaderWriter.init(allocator, out);
    try writer.writeBit(packet_included);
    if (packet_included) {
        for (groups, prepared[0..initialized]) |*group, prepared_group| {
            try t2.writePrecinctPacketHeaderBody(
                &writer,
                &group.writer_state.inclusion,
                &group.writer_state.zero_bitplanes,
                group.writer_state.states,
                packet.layer,
                prepared_group.packet_blocks,
            );
        }
    }
    try writer.finish();
    const header_length = out.items.len - header_offset;
    const payload_offset = out.items.len;

    if (packet_included) {
        const layer_index: usize = @intCast(packet.layer);
        for (groups, prepared[0..initialized]) |group, prepared_group| {
            for (prepared_group.packet_blocks, group.encoded) |packet_block, encoded| {
                if (!packet_block.included) continue;
                const payload = try rpclEncodedLayerPayload(encoded, layer_index);
                if (payload.len != packet_block.byte_length) return CodestreamError.InvalidCodestream;
                try out.appendSlice(allocator, payload);
            }
        }
    }

    return .{
        .header_offset = header_offset,
        .header_length = header_length,
        .payload_offset = payload_offset,
        .payload_length = payload_length,
        .included_blocks = included_blocks,
    };
}

fn prepareRpclPacketGroup(
    allocator: std.mem.Allocator,
    group: *RpclPacketBandGroup,
    layer: u32,
) !PreparedRpclPacketGroup {
    const layer_index: usize = @intCast(layer);
    const packet_blocks = try allocator.alloc(t2.PacketBlock, group.encoded.len);
    errdefer allocator.free(packet_blocks);

    for (group.encoded, 0..) |encoded, index| {
        const block = try t2.layerPacketBlockFor(encoded, layer_index);
        if (block.previous.cumulative_passes != group.writer_state.states[index].cumulative_passes or
            block.previous.cumulative_bytes != group.writer_state.states[index].cumulative_bytes)
        {
            return CodestreamError.InvalidCodestream;
        }
        packet_blocks[index] = try t2.packetBlockForLayer(
            block.location,
            block.nominal_bitplanes,
            block.encoded_bitplanes,
            block.previous,
            block.current,
        );
        if (block.segments.len > 0 and packet_blocks[index].included) {
            var segment_passes: u16 = 0;
            var segment_bytes: u64 = 0;
            for (block.segments) |segment| {
                segment_passes = std.math.add(u16, segment_passes, segment.pass_count) catch
                    return CodestreamError.InvalidCodestream;
                segment_bytes = try std.math.add(u64, segment_bytes, segment.byte_length);
            }
            if (segment_passes != packet_blocks[index].pass_count or
                segment_bytes != packet_blocks[index].byte_length)
            {
                return CodestreamError.InvalidCodestream;
            }
            packet_blocks[index].segments = block.segments;
        }
        const payload = try t2.layerPayloadSlice(block.payload, block.previous, block.current);
        if (packet_blocks[index].included) {
            if (payload.len != packet_blocks[index].byte_length) return CodestreamError.InvalidCodestream;
        } else if (payload.len != 0) {
            return CodestreamError.InvalidCodestream;
        }
    }

    return .{
        .packet_blocks = packet_blocks,
    };
}

fn rpclEncodedLayerPayload(encoded: t2.EncodedLayerBlock, layer_index: usize) ![]const u8 {
    if (layer_index >= encoded.layers.len) return CodestreamError.InvalidCodestream;
    const previous: t2.LayerTruncation = if (layer_index == 0)
        .{ .cumulative_passes = 0, .cumulative_bytes = 0 }
    else
        encoded.layers[layer_index - 1];
    return t2.layerPayloadSlice(encoded.payload, previous, encoded.layers[layer_index]);
}

fn appendShadowPacketLength(allocator: std.mem.Allocator, lengths: *std.ArrayList(u32), length: usize) !void {
    if (length > std.math.maxInt(u32)) return CodestreamError.ImageTooLarge;
    try lengths.append(allocator, @intCast(length));
}

fn payloadBlockThreadCount(options: LosslessOptions, block_count: usize) usize {
    if (options.threads <= 3 or block_count < 2) return 1;
    return @min(@as(usize, options.threads), block_count);
}

fn appendPacketPlan(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    width: usize,
    height: usize,
    levels: u8,
    options: LosslessOptions,
) !void {
    const plan = try makePacketPlan(width, height, levels, options);

    try out.append(allocator, plan.resolution_count);
    for (plan.resolutions[0..plan.resolution_count]) |resolution| {
        try appendU32Be(allocator, out, resolution.width);
        try appendU32Be(allocator, out, resolution.height);
        try appendU32Be(allocator, out, resolution.precinct_width);
        try appendU32Be(allocator, out, resolution.precinct_height);
        try appendU32Be(allocator, out, resolution.precincts_x);
        try appendU32Be(allocator, out, resolution.precincts_y);
        try appendU64Be(allocator, out, resolution.precincts);
        try appendU64Be(allocator, out, resolution.packets);
    }
}

fn makePacketPlan(width: usize, height: usize, levels: u8, options: LosslessOptions) !packet_plan.Plan {
    return makePacketPlanForComponents(width, height, levels, 3, options);
}

fn makePacketPlanForComponents(
    width: usize,
    height: usize,
    levels: u8,
    components: u16,
    options: LosslessOptions,
) !packet_plan.Plan {
    var precincts: [33]packet_plan.Precinct = undefined;
    var index: usize = 0;
    while (index < options.precinct_count) : (index += 1) {
        precincts[index] = .{
            .width = options.precincts[index].width,
            .height = options.precincts[index].height,
        };
    }

    return packet_plan.rpclSingleTile(
        width,
        height,
        levels,
        components,
        options.layers,
        precincts[0..options.precinct_count],
    );
}

fn makePacketPlanForTile(tile: tile_grid.Tile, levels: u8, options: LosslessOptions) !packet_plan.Plan {
    return makePacketPlanForTileComponents(tile, levels, 3, options);
}

fn makePacketPlanForTileComponents(
    tile: tile_grid.Tile,
    levels: u8,
    components: u16,
    options: LosslessOptions,
) !packet_plan.Plan {
    var precincts: [33]packet_plan.Precinct = undefined;
    var index: usize = 0;
    while (index < options.precinct_count) : (index += 1) {
        precincts[index] = .{
            .width = options.precincts[index].width,
            .height = options.precincts[index].height,
        };
    }
    return packet_plan.rpclTileRegion(
        tile.rect.x0,
        tile.rect.y0,
        tile.rect.x1,
        tile.rect.y1,
        levels,
        components,
        options.layers,
        precincts[0..options.precinct_count],
    );
}

fn makeAggregatePacketPlanForTile(
    tile: tile_grid.Tile,
    levels: u8,
    component_count: u16,
    options: LosslessOptions,
    component_xrsiz: [max_codestream_components]u8,
    component_yrsiz: [max_codestream_components]u8,
) !packet_plan.Plan {
    var plan = try makePacketPlanForTileComponents(tile, levels, component_count, options);
    const component_plans = try StrictComponentPacketPlans.init(
        plan,
        component_count,
        options.layers,
        component_xrsiz,
        component_yrsiz,
    );
    plan.packets = component_plans.packet_count;
    for (plan.resolutions[0..plan.resolution_count], 0..) |*resolution, index| {
        resolution.packets = component_plans.resolution_packets[index];
    }
    return plan;
}

fn makeCodeBlocksForPacketPlan(
    allocator: std.mem.Allocator,
    bands: []const subband.Band,
    block_width: usize,
    block_height: usize,
    plan: packet_plan.Plan,
) ![]subband.CodeBlock {
    if (plan.resolution_count == 0) return CodestreamError.InvalidCodestream;
    return subband.makeCodeBlocks(allocator, bands, block_width, block_height);
}

fn makeBandsForPacketPlan(
    allocator: std.mem.Allocator,
    plan: packet_plan.Plan,
    levels: u8,
) ![]subband.Band {
    if (plan.resolution_count == 0 or plan.resolution_count != @as(u8, levels) + 1) {
        return CodestreamError.InvalidCodestream;
    }
    const full = plan.resolutions[plan.resolution_count - 1];
    const x1 = std.math.add(u32, full.x0, full.width) catch return CodestreamError.InvalidCodestream;
    const y1 = std.math.add(u32, full.y0, full.height) catch return CodestreamError.InvalidCodestream;
    return subband.makeBandsForRegion(allocator, full.x0, full.y0, x1, y1, levels);
}

const PacketRange = struct {
    start: usize,
    count: usize,
};

fn tilePartPacketRange(
    plan: packet_plan.Plan,
    tile_part_index: usize,
    tile_parts: usize,
    options: LosslessOptions,
) PacketRange {
    if (options.tile_part_divisions == 'R' and tile_parts == plan.resolution_count) {
        var start: usize = 0;
        var resolution: usize = 0;
        while (resolution < tile_part_index) : (resolution += 1) {
            start += @intCast(plan.resolutions[resolution].packets);
        }
        return .{
            .start = start,
            .count = @intCast(plan.resolutions[tile_part_index].packets),
        };
    }
    return .{
        .start = 0,
        .count = @intCast(plan.packets),
    };
}

/// Packet bodies do not depend on the progression order: T2 coder state is
/// per-precinct, and each precinct's layers appear in increasing order in
/// every supported stream order. The target stream is therefore a
/// byte-preserving permutation of the RPCL packets. Rewrites the stream in
/// place from RPCL emission order into `options.progression` stream order.
fn reorderPacketStreamFromRpcl(
    allocator: std.mem.Allocator,
    stream: *RpclPacketStream,
    width: usize,
    height: usize,
    levels: u8,
    options: LosslessOptions,
) !void {
    const plan = try makePacketPlan(width, height, levels, options);
    const sequence = try buildStreamPacketSequence(allocator, options.progression, plan, 3, options.layers);
    defer allocator.free(sequence);
    try reorderPacketStreamFromRpclSequence(allocator, stream, plan, options.layers, sequence);
}

fn reorderPacketStreamFromRpclSequence(
    allocator: std.mem.Allocator,
    stream: *RpclPacketStream,
    plan: packet_plan.Plan,
    layers: u16,
    sequence: []const packet_plan.Packet,
) !void {
    const packet_count = std.math.cast(usize, plan.packets) orelse return CodestreamError.InvalidCodestream;
    if (stream.packet_lengths.len != packet_count or
        stream.packet_header_lengths.len != packet_count)
    {
        return CodestreamError.InvalidCodestream;
    }

    const offsets = try allocator.alloc(usize, packet_count + 1);
    defer allocator.free(offsets);
    offsets[0] = 0;
    for (stream.packet_lengths, 0..) |packet_length, index| {
        offsets[index + 1] = try std.math.add(usize, offsets[index], packet_length);
    }
    if (offsets[packet_count] != stream.packet_bytes.len) return CodestreamError.InvalidCodestream;

    const lengths = try allocator.alloc(u32, packet_count);
    errdefer allocator.free(lengths);
    const header_lengths = try allocator.alloc(u32, packet_count);
    errdefer allocator.free(header_lengths);
    const bytes = try allocator.alloc(u8, stream.packet_bytes.len);
    errdefer allocator.free(bytes);

    if (sequence.len != packet_count) return CodestreamError.InvalidCodestream;
    var out_offset: usize = 0;
    for (sequence, 0..) |packet, out_index| {
        const source_sequence = packet_plan.rpclSequenceForPacket(plan, 3, layers, packet) catch
            return CodestreamError.InvalidCodestream;
        const source = std.math.cast(usize, source_sequence) orelse return CodestreamError.InvalidCodestream;
        if (source >= packet_count) return CodestreamError.InvalidCodestream;
        const source_length = stream.packet_lengths[source];
        lengths[out_index] = source_length;
        header_lengths[out_index] = stream.packet_header_lengths[source];
        @memcpy(bytes[out_offset..][0..source_length], stream.packet_bytes[offsets[source]..][0..source_length]);
        out_offset += source_length;
    }
    if (out_offset != bytes.len) return CodestreamError.InvalidCodestream;

    stream.deinit();
    stream.* = .{
        .allocator = allocator,
        .packet_lengths = lengths,
        .packet_header_lengths = header_lengths,
        .packet_bytes = bytes,
    };
}

fn reorderTilePacketStreamFromRpclSequence(
    allocator: std.mem.Allocator,
    stream: *tile_pipeline.TileRpclPacketStream,
    plan: packet_plan.Plan,
    layers: u16,
    sequence: []const packet_plan.Packet,
) !void {
    const packet_count = std.math.cast(usize, plan.packets) orelse return CodestreamError.InvalidCodestream;
    if (sequence.len != packet_count or stream.packet_lengths.len != packet_count or
        stream.packet_header_lengths.len != packet_count)
    {
        return CodestreamError.InvalidCodestream;
    }

    const offsets = try allocator.alloc(usize, packet_count + 1);
    defer allocator.free(offsets);
    offsets[0] = 0;
    for (stream.packet_lengths, 0..) |packet_length, index| {
        offsets[index + 1] = try std.math.add(usize, offsets[index], packet_length);
    }
    if (offsets[packet_count] != stream.bytes.len) return CodestreamError.InvalidCodestream;

    const lengths = try allocator.alloc(u32, packet_count);
    errdefer allocator.free(lengths);
    const header_lengths = try allocator.alloc(u32, packet_count);
    errdefer allocator.free(header_lengths);
    const bytes = try allocator.alloc(u8, stream.bytes.len);
    errdefer allocator.free(bytes);

    var out_offset: usize = 0;
    for (sequence, 0..) |packet, out_index| {
        const source_sequence = packet_plan.rpclSequenceForPacket(plan, 3, layers, packet) catch
            return CodestreamError.InvalidCodestream;
        const source = std.math.cast(usize, source_sequence) orelse return CodestreamError.InvalidCodestream;
        if (source >= packet_count) return CodestreamError.InvalidCodestream;
        const source_length: usize = stream.packet_lengths[source];
        const source_end = try std.math.add(usize, offsets[source], source_length);
        if (source_end > stream.bytes.len) return CodestreamError.InvalidCodestream;
        lengths[out_index] = stream.packet_lengths[source];
        header_lengths[out_index] = stream.packet_header_lengths[source];
        @memcpy(bytes[out_offset..][0..source_length], stream.bytes[offsets[source]..source_end]);
        out_offset += source_length;
    }
    if (out_offset != bytes.len) return CodestreamError.InvalidCodestream;

    stream.deinit();
    stream.* = .{
        .allocator = allocator,
        .bytes = bytes,
        .packet_lengths = lengths,
        .packet_header_lengths = header_lengths,
    };
}

fn rpclPacketByteOffset(packet_lengths: []const u32, packet_index: usize) !usize {
    if (packet_index > packet_lengths.len) return CodestreamError.InvalidCodestream;
    var offset: usize = 0;
    for (packet_lengths[0..packet_index]) |packet_length| {
        offset = try std.math.add(usize, offset, packet_length);
    }
    return offset;
}

fn appendTilePartPlan(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    levels: u8,
    options: LosslessOptions,
) !void {
    if (options.tile_part_divisions != 'R') {
        try out.append(allocator, 0);
        return;
    }

    const resolution_count = try std.math.add(u8, levels, 1);
    try out.append(allocator, resolution_count);
    var resolution: u8 = 0;
    while (resolution < resolution_count) : (resolution += 1) {
        try out.append(allocator, resolution);
    }
}

fn appendMarker(allocator: std.mem.Allocator, out: *std.ArrayList(u8), marker: Marker) !void {
    try appendU16Be(allocator, out, @intFromEnum(marker));
}

fn appendComponentPayload(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    component_index: u8,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    catalog: []const RpclShadowBlock,
    options: LosslessOptions,
) !void {
    if (catalog.len != blocks.len) return CodestreamError.InvalidCodestream;
    try out.append(allocator, component_index);
    try appendU16Be(allocator, out, @as(u16, @intCast(bands.len)));
    try appendU32Be(allocator, out, @as(u32, @intCast(blocks.len)));

    for (bands) |band| {
        try out.append(allocator, @intFromEnum(band.kind));
        try out.append(allocator, band.level);
        try appendRect(allocator, out, band.rect);
    }

    const block_threads = payloadBlockThreadCount(options, blocks.len);
    if (block_threads > 1) {
        try appendComponentBlocksParallel(allocator, out, blocks, catalog, options, block_threads);
    } else {
        var entropy_scratch = entropy.Scratch.init(allocator);
        defer entropy_scratch.deinit();
        try appendComponentBlockPayloads(
            allocator,
            out,
            blocks,
            catalog,
            options,
            &entropy_scratch,
        );
    }
}

fn appendComponentBlockPayloads(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    blocks: []const subband.CodeBlock,
    catalog: []const RpclShadowBlock,
    options: LosslessOptions,
    entropy_scratch: *entropy.Scratch,
) !void {
    if (catalog.len != blocks.len) return CodestreamError.InvalidCodestream;
    for (blocks, catalog) |block, catalog_block| {
        try appendComponentBlockPayload(
            allocator,
            out,
            block,
            catalog_block,
            options,
            entropy_scratch,
        );
    }
}

fn appendComponentBlockPayload(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    block: subband.CodeBlock,
    catalog_block: RpclShadowBlock,
    options: LosslessOptions,
    entropy_scratch: *entropy.Scratch,
) !void {
    try appendU16Be(allocator, out, @as(u16, @intCast(block.band_index)));
    try appendRect(allocator, out, block.rect);

    const encoded = catalog_block.bitplane orelse return CodestreamError.InvalidCodestream;
    const ebcot_segment = catalog_block.segment;
    {
        try appendRect(allocator, out, encoded.active_rect);
        try out.append(allocator, encoded.bitplanes);
        try appendU32Be(allocator, out, encoded.non_zero_count);
        const coding_passes = bitplane.isoCodingPassCount(encoded.bitplanes, encoded.non_zero_count);
        if (ebcot_segment.pass_count != coding_passes) return CodestreamError.InvalidCodestream;
        try appendU16Be(allocator, out, coding_passes);
        try appendLayerAllocation(allocator, out, options, ebcot_segment);
        try appendEntropyStream(allocator, out, entropy_scratch, encoded.significance_bytes);
        try appendEntropyStream(allocator, out, entropy_scratch, encoded.refinement_bytes);
        try appendEntropyStream(allocator, out, entropy_scratch, encoded.cleanup_bytes);
        try appendEbcotSegmentInfo(allocator, out, ebcot_segment);
        try appendEbcotSegmentPayload(allocator, out, ebcot_segment);
    }
}

fn appendComponentBlocksParallel(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    blocks: []const subband.CodeBlock,
    catalog: []const RpclShadowBlock,
    options: LosslessOptions,
    worker_count: usize,
) !void {
    if (catalog.len != blocks.len) return CodestreamError.InvalidCodestream;
    if (worker_count <= 1) {
        var entropy_scratch = entropy.Scratch.init(allocator);
        defer entropy_scratch.deinit();
        return appendComponentBlockPayloads(
            allocator,
            out,
            blocks,
            catalog,
            options,
            &entropy_scratch,
        );
    }

    var jobs = try allocator.alloc(ComponentBlockPayloadJob, worker_count);
    defer allocator.free(jobs);
    defer for (jobs) |*job| job.deinit();

    for (jobs, 0..) |*job, index| {
        const start = blockRangeBoundary(blocks.len, worker_count, index);
        const end = blockRangeBoundary(blocks.len, worker_count, index + 1);
        job.* = .{
            .blocks = blocks[start..end],
            .catalog = catalog[start..end],
            .options = options,
        };
    }

    const spawn_count = worker_count - 1;
    var threads = try allocator.alloc(std.Thread, spawn_count);
    defer allocator.free(threads);
    var spawned: usize = 0;
    while (spawned < spawn_count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, componentBlockPayloadWorker, .{&jobs[spawned]}) catch |err| {
            for (threads[0..spawned]) |thread| thread.join();
            return err;
        };
    }

    componentBlockPayloadWorker(&jobs[spawn_count]);
    for (threads[0..spawned]) |thread| thread.join();

    for (jobs) |job| try job.result;
    for (jobs) |job| try out.appendSlice(allocator, job.bytes);
}

fn blockRangeBoundary(block_count: usize, worker_count: usize, index: usize) usize {
    return (block_count * index) / worker_count;
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

fn appendU64Be(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u64) !void {
    try out.append(allocator, @as(u8, @truncate(value >> 56)));
    try out.append(allocator, @as(u8, @truncate(value >> 48)));
    try out.append(allocator, @as(u8, @truncate(value >> 40)));
    try out.append(allocator, @as(u8, @truncate(value >> 32)));
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

    fn readU64(self: *Cursor) !u64 {
        const bytes = try self.readBytes(8);
        return (@as(u64, bytes[0]) << 56) |
            (@as(u64, bytes[1]) << 48) |
            (@as(u64, bytes[2]) << 40) |
            (@as(u64, bytes[3]) << 32) |
            (@as(u64, bytes[4]) << 24) |
            (@as(u64, bytes[5]) << 16) |
            (@as(u64, bytes[6]) << 8) |
            bytes[7];
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
    scratch: *entropy.Scratch,
    bytes: []const u8,
) !void {
    if (bytes.len == 0) {
        try out.append(allocator, @intFromEnum(entropy.Method.raw));
        try appendU32Be(allocator, out, 0);
        try appendU32Be(allocator, out, 0);
        return;
    }

    const encoded = try entropy.encodeAutoBorrowingRawScratch(scratch, bytes);

    try out.append(allocator, @intFromEnum(encoded.method));
    try appendU32Be(allocator, out, encoded.raw_len);
    try appendU32Be(allocator, out, @as(u32, @intCast(encoded.bytes.len)));
    try out.appendSlice(allocator, encoded.bytes);
}

fn appendEbcotSegmentInfo(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    segment: ebcot.CodeBlockSegment,
) !void {
    try appendU16Be(allocator, out, segment.pass_count);
    try appendU64Be(allocator, out, segment.byte_length);
    for (segment.passes) |pass| {
        try out.append(allocator, @intFromEnum(pass.kind));
        try out.append(allocator, pass.magnitude_bitplane);
        try appendU32Be(allocator, out, @intCast(pass.symbol_count));
        try appendU64Be(allocator, out, @intCast(pass.byte_offset));
        try appendU64Be(allocator, out, @intCast(pass.byte_length));
        try appendU64Be(allocator, out, pass.cumulative_bytes);
    }
}

fn appendEbcotSegmentPayload(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    segment: ebcot.CodeBlockSegment,
) !void {
    if (@as(u64, @intCast(segment.bytes.len)) != segment.byte_length) return CodestreamError.InvalidCodestream;
    try out.appendSlice(allocator, segment.bytes);
}

fn appendLayerAllocation(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    options: LosslessOptions,
    segment: ebcot.CodeBlockSegment,
) !void {
    var layers = [_]t2.LayerTruncation{.{ .cumulative_passes = 0, .cumulative_bytes = 0 }} ** max_quality_layers;
    try computeLayerTruncations(&layers, options, segment);

    try appendU16Be(allocator, out, options.layers);
    for (layers[0..@as(usize, @intCast(options.layers))]) |layer| {
        try appendU16Be(allocator, out, layer.cumulative_passes);
        try appendU64Be(allocator, out, layer.cumulative_bytes);
    }
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

/// Multi-tile constraints (docs/multi_tile_plan.md §3): the tile pipeline
/// currently covers reversible 5/3 + RCT and irreversible 9/7 + ICT, quality
/// layers across all five Part 1 packet orders, the supported resilience style
/// combinations, and PLT-backed R/L/C/P tile-part divisions on matching packet
/// orders. Everything outside that fails closed so COD/SIZ never advertise
/// behavior the tile encoder does not implement.
fn validateMultiTileCodingPath(options: LosslessOptions) !void {
    try validateMultiTileProgression(options.progression, options.layers);
    try validateTilePartDivisions(options.tile_part_divisions);
    if (options.tile_part_divisions == 'R' and options.progression != .rpcl) {
        return CodestreamError.UnsupportedPayload;
    }
    // Per-layer divisions need layer-contiguous packet ranges inside each
    // tile, which only LRCP provides (layer is the outermost loop).
    if (options.tile_part_divisions == 'L' and options.progression != .lrcp) {
        return CodestreamError.UnsupportedPayload;
    }
    // Per-component divisions need component-contiguous packet ranges; CPRL
    // is the Part 1 order with component as the outermost loop.
    if (options.tile_part_divisions == 'C' and options.progression != .cprl) {
        return CodestreamError.UnsupportedPayload;
    }
    // Precinct-position divisions need position-contiguous packet ranges;
    // PCRL is the Part 1 order with reference-grid position outermost.
    if (options.tile_part_divisions == 'P' and options.progression != .pcrl) {
        return CodestreamError.UnsupportedPayload;
    }
    switch (options.transform) {
        .reversible_5_3 => {
            if (options.mct != .rct) return CodestreamError.UnsupportedPayload;
        },
        .irreversible_9_7 => {
            if (options.mct != .ict) return CodestreamError.UnsupportedPayload;
            if (options.quantization != .scalar_expounded and
                options.quantization != .scalar_derived)
            {
                return CodestreamError.UnsupportedPayload;
            }
        },
    }
    if (options.t1_backend != .iso_mq) return CodestreamError.UnsupportedPayload;
    if (options.bypass and !options.terminate_all) return CodestreamError.UnsupportedPayload;
    // Standalone RESET and standalone ERTERM ride the same continuous ISO-MQ
    // block encoder/decoder pair as the single-tile path
    // (encodeComponentBlockIsoMq routes non-TERMALL styles through the direct
    // scratch encoder), so they are open here with their own multi-tile
    // roundtrip and Kakadu interop coverage. The global validateCodingPath
    // gates (legacy backend, BYPASS combinations) run before this validator.
    if (options.emit_temporary_payload_sidecar) return CodestreamError.UnsupportedPayload;
}

fn validateMultiTileProgression(progression: ProgressionOrder, layers: u16) !void {
    if (layers == 0) return CodestreamError.InvalidCodestream;
    switch (progression) {
        .rpcl, .lrcp, .rlcp, .pcrl, .cprl => {},
    }
}

/// ISO 15444-1 B.7: the effective code-block size is bounded by the precinct
/// span in band coordinates — the full precinct at resolution 0, half of it
/// at higher resolutions. z2000 does not implement the block-size clamping
/// the standard prescribes, so code blocks that would cross precinct
/// boundaries fail closed on both encode and strict decode instead of
/// producing (or misreading) an ambiguous packet/block layout. Expects the
/// precinct list normalized to cover the coded resolutions.
fn validatePrecinctBlockSpans(options: LosslessOptions) !void {
    for (options.precincts[0..options.precinct_count], 0..) |precinct, resolution| {
        const band_span_width = if (resolution == 0) precinct.width else precinct.width / 2;
        const band_span_height = if (resolution == 0) precinct.height else precinct.height / 2;
        if (band_span_width < options.block_width or band_span_height < options.block_height) {
            return CodestreamError.UnsupportedPayload;
        }
    }
}

fn validateMultiTileGeometry(grid: tile_grid.Grid, levels: u8, options: LosslessOptions) !void {
    try validatePrecinctBlockSpans(options);
    if (levels > 32) return CodestreamError.UnsupportedPayload;

    var iterator = grid.iterator();
    while (iterator.next() catch return CodestreamError.InvalidCodestream) |tile| {
        if (!wavelet_int.canDecompose53Region(tile.rect.x0, tile.rect.y0, tile.rect.x1, tile.rect.y1, levels)) {
            return CodestreamError.UnsupportedPayload;
        }
    }
}

/// Strict decode uses reference-grid-anchored packet plans, so foreign tile
/// origins do not need the encoder's temporary partition-alignment rule.
/// Keep the profile bounds that are independent of that implementation
/// detail: legal precinct/block spans and one global DWT level count.
fn validateMultiTileDecodeGeometry(grid: tile_grid.Grid, levels: u8, options: LosslessOptions) !void {
    try validatePrecinctBlockSpans(options);
    if (levels > 32) return CodestreamError.UnsupportedPayload;

    var iterator = grid.iterator();
    while (iterator.next() catch return CodestreamError.InvalidCodestream) |tile| {
        if (!wavelet_int.canDecompose53Region(tile.rect.x0, tile.rect.y0, tile.rect.x1, tile.rect.y1, levels)) {
            return CodestreamError.UnsupportedPayload;
        }
    }
}

fn validatePocLayerTilePartSequence(sequence: []const packet_plan.Packet, layers: u16) !void {
    const layer_count = @as(usize, layers);
    if (layer_count == 0 or layer_count > std.math.maxInt(u8) or sequence.len == 0 or
        sequence.len % layer_count != 0)
    {
        return CodestreamError.UnsupportedPayload;
    }
    const packets_per_layer = sequence.len / layer_count;
    for (0..layer_count) |layer| {
        const start = layer * packets_per_layer;
        for (sequence[start..][0..packets_per_layer]) |packet| {
            if (packet.layer != @as(u16, @intCast(layer))) return CodestreamError.UnsupportedPayload;
        }
    }
}

fn validatePocResolutionTilePartSequence(
    sequence: []const packet_plan.Packet,
    plan: packet_plan.Plan,
) !void {
    if (plan.resolution_count == 0 or sequence.len == 0) return CodestreamError.UnsupportedPayload;
    var packet_index: usize = 0;
    for (plan.resolutions[0..plan.resolution_count], 0..) |resolution, resolution_index| {
        const packet_count = std.math.cast(usize, resolution.packets) orelse
            return CodestreamError.UnsupportedPayload;
        const end = std.math.add(usize, packet_index, packet_count) catch
            return CodestreamError.UnsupportedPayload;
        if (packet_count == 0 or end > sequence.len) return CodestreamError.UnsupportedPayload;
        for (sequence[packet_index..end]) |packet| {
            if (packet.resolution != @as(u8, @intCast(resolution_index))) {
                return CodestreamError.UnsupportedPayload;
            }
        }
        packet_index = end;
    }
    if (packet_index != sequence.len) return CodestreamError.UnsupportedPayload;
}

fn validatePocResolutionTilePartSpans(
    spans: []const StrictMultiTileTilePartSpan,
    tile_index: u16,
    plan: packet_plan.Plan,
) !void {
    const part_count = @as(usize, plan.resolution_count);
    if (part_count == 0 or part_count > std.math.maxInt(u8)) return CodestreamError.InvalidCodestream;
    var part_index: usize = 0;
    var first_packet: usize = 0;
    for (spans) |span| {
        if (span.tile_index != tile_index) continue;
        if (part_index >= part_count) return CodestreamError.InvalidCodestream;
        const packet_count = std.math.cast(usize, plan.resolutions[part_index].packets) orelse
            return CodestreamError.InvalidCodestream;
        if (span.tile_part_count != @as(u8, @intCast(part_count)) or
            span.tile_part_index != @as(u8, @intCast(part_index)) or
            span.first_packet != first_packet or span.packet_count != packet_count)
        {
            return CodestreamError.InvalidCodestream;
        }
        first_packet = try std.math.add(usize, first_packet, packet_count);
        part_index += 1;
    }
    if (part_index != part_count or first_packet != plan.packets) {
        return CodestreamError.InvalidCodestream;
    }
}

fn validatePocLayerTilePartSpans(
    spans: []const StrictMultiTileTilePartSpan,
    tile_index: u16,
    packet_count: usize,
    layers: u16,
) !void {
    const layer_count = @as(usize, layers);
    if (layer_count == 0 or layer_count > std.math.maxInt(u8) or packet_count % layer_count != 0) {
        return CodestreamError.InvalidCodestream;
    }
    const packets_per_layer = packet_count / layer_count;
    var part_index: usize = 0;
    for (spans) |span| {
        if (span.tile_index != tile_index) continue;
        if (part_index >= layer_count or span.tile_part_count != @as(u8, @intCast(layers)) or
            span.tile_part_index != @as(u8, @intCast(part_index)) or
            span.first_packet != part_index * packets_per_layer or
            span.packet_count != packets_per_layer)
        {
            return CodestreamError.InvalidCodestream;
        }
        part_index += 1;
    }
    if (part_index != layer_count) return CodestreamError.InvalidCodestream;
}

fn validatePocComponentTilePartSequence(sequence: []const packet_plan.Packet) !void {
    if (sequence.len == 0 or sequence.len % 3 != 0) return CodestreamError.UnsupportedPayload;
    const packets_per_component = sequence.len / 3;
    for (0..3) |component| {
        const start = component * packets_per_component;
        for (sequence[start..][0..packets_per_component]) |packet| {
            if (packet.component != @as(u16, @intCast(component))) return CodestreamError.UnsupportedPayload;
        }
    }
}

fn validatePocComponentTilePartSpans(
    spans: []const StrictMultiTileTilePartSpan,
    tile_index: u16,
    packet_count: usize,
) !void {
    if (packet_count == 0 or packet_count % 3 != 0) return CodestreamError.InvalidCodestream;
    const packets_per_component = packet_count / 3;
    var part_index: usize = 0;
    for (spans) |span| {
        if (span.tile_index != tile_index) continue;
        if (part_index >= 3 or span.tile_part_count != 3 or
            span.tile_part_index != @as(u8, @intCast(part_index)) or
            span.first_packet != part_index * packets_per_component or
            span.packet_count != packets_per_component)
        {
            return CodestreamError.InvalidCodestream;
        }
        part_index += 1;
    }
    if (part_index != 3) return CodestreamError.InvalidCodestream;
}

fn validatePocPositionTilePartSequence(
    allocator: std.mem.Allocator,
    sequence: []const packet_plan.Packet,
    plan: packet_plan.Plan,
    layers: u16,
) !void {
    const canonical = packet_plan.positionOrderedPackets(allocator, plan, 3, layers, .pcrl) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return CodestreamError.InvalidCodestream,
    };
    defer allocator.free(canonical);
    if (sequence.len == 0 or sequence.len != canonical.len) return CodestreamError.UnsupportedPayload;
    for (sequence, canonical) |actual, expected| {
        const actual_position = packet_plan.packetPosition(plan, actual) catch
            return CodestreamError.InvalidCodestream;
        const expected_position = packet_plan.packetPosition(plan, expected) catch
            return CodestreamError.InvalidCodestream;
        if (actual_position.x_ref != expected_position.x_ref or actual_position.y_ref != expected_position.y_ref) {
            return CodestreamError.UnsupportedPayload;
        }
    }
}

fn validatePocPositionTileParts(
    allocator: std.mem.Allocator,
    sequence: []const packet_plan.Packet,
    spans: []const StrictMultiTileTilePartSpan,
    tile_index: u16,
    plan: packet_plan.Plan,
    layers: u16,
) !void {
    try validatePocPositionTilePartSequence(allocator, sequence, plan, layers);
    var part_count: usize = 0;
    var packet_index: usize = 0;
    while (packet_index < sequence.len) : (part_count += 1) {
        const position = packet_plan.packetPosition(plan, sequence[packet_index]) catch
            return CodestreamError.InvalidCodestream;
        packet_index += 1;
        while (packet_index < sequence.len) : (packet_index += 1) {
            const next = packet_plan.packetPosition(plan, sequence[packet_index]) catch
                return CodestreamError.InvalidCodestream;
            if (next.x_ref != position.x_ref or next.y_ref != position.y_ref) break;
        }
    }
    if (part_count == 0 or part_count > std.math.maxInt(u8)) return CodestreamError.UnsupportedPayload;

    var part_index: usize = 0;
    packet_index = 0;
    for (spans) |span| {
        if (span.tile_index != tile_index) continue;
        if (part_index >= part_count or packet_index >= sequence.len) return CodestreamError.InvalidCodestream;
        const first_packet = packet_index;
        const position = packet_plan.packetPosition(plan, sequence[packet_index]) catch
            return CodestreamError.InvalidCodestream;
        packet_index += 1;
        while (packet_index < sequence.len) : (packet_index += 1) {
            const next = packet_plan.packetPosition(plan, sequence[packet_index]) catch
                return CodestreamError.InvalidCodestream;
            if (next.x_ref != position.x_ref or next.y_ref != position.y_ref) break;
        }
        if (span.tile_part_count != @as(u8, @intCast(part_count)) or
            span.tile_part_index != @as(u8, @intCast(part_index)) or
            span.first_packet != first_packet or span.packet_count != packet_index - first_packet)
        {
            return CodestreamError.InvalidCodestream;
        }
        part_index += 1;
    }
    if (part_index != part_count or packet_index != sequence.len) return CodestreamError.InvalidCodestream;
}

const MultiTilePacketPart = struct {
    tile_index: u16,
    tile_part_index: u8,
    tile_part_count: u8,
    first_packet: usize,
    packet_count: usize,
    psot: u32,
};

fn packetPartPsot(
    options: LosslessOptions,
    packet_lengths: []const u32,
    packet_header_lengths: []const u32,
) !usize {
    if (packet_lengths.len != packet_header_lengths.len) return CodestreamError.InvalidCodestream;
    const uses_packed_headers = options.ppm or options.ppt;
    const payload_bytes = if (uses_packed_headers)
        try packedPacketBodyByteCount(options, packet_lengths, packet_header_lengths)
    else
        try rpclPacketPayloadByteCount(options, packet_lengths);
    const plt_bytes = if (options.ppm)
        0
    else if (uses_packed_headers)
        try pltBytesForPackedPacketLengths(options, packet_lengths, packet_header_lengths)
    else
        try pltBytesForRpclPacketLengths(options, packet_lengths);
    const ppt_bytes = if (options.ppt) try pptMarkerByteCount(options, packet_header_lengths) else 0;
    return std.math.add(usize, 14, try std.math.add(usize, payload_bytes, try std.math.add(usize, plt_bytes, ppt_bytes)));
}

fn buildMultiTileSingleParts(
    allocator: std.mem.Allocator,
    artifacts: tile_pipeline.TileRpclEncodeGridArtifacts,
    options: LosslessOptions,
) ![]MultiTilePacketPart {
    const parts = try allocator.alloc(MultiTilePacketPart, artifacts.tiles.len);
    errdefer allocator.free(parts);
    for (artifacts.tiles, parts) |tile_artifacts, *part| {
        if (tile_artifacts.tile.index > std.math.maxInt(u16)) return CodestreamError.UnsupportedPayload;
        const psot = try packetPartPsot(
            options,
            tile_artifacts.stream.packet_lengths,
            tile_artifacts.stream.packet_header_lengths,
        );
        part.* = .{
            .tile_index = @intCast(tile_artifacts.tile.index),
            .tile_part_index = 0,
            .tile_part_count = 1,
            .first_packet = 0,
            .packet_count = tile_artifacts.stream.packet_lengths.len,
            .psot = std.math.cast(u32, psot) orelse return CodestreamError.UnsupportedPayload,
        };
    }
    return parts;
}

fn addMultiTilePocHeaderBytes(parts: []MultiTilePacketPart, options: LosslessOptions) !void {
    if (!options.poc_in_tile_header) return;
    const marker_bytes = try pocMarkerByteCount(options);
    for (parts) |*part| {
        if (part.tile_part_index == 0) {
            part.psot = try std.math.add(u32, part.psot, marker_bytes);
        }
    }
}

fn buildMultiTileResolutionParts(
    allocator: std.mem.Allocator,
    artifacts: tile_pipeline.TileRpclEncodeGridArtifacts,
    levels: u8,
    options: LosslessOptions,
) ![]MultiTilePacketPart {
    const parts_per_tile = try std.math.add(usize, levels, 1);
    if (parts_per_tile > std.math.maxInt(u8)) return CodestreamError.UnsupportedPayload;
    const total_parts = try std.math.mul(usize, artifacts.tiles.len, parts_per_tile);
    const parts = try allocator.alloc(MultiTilePacketPart, total_parts);
    errdefer allocator.free(parts);

    var out_index: usize = 0;
    for (artifacts.tiles) |tile_artifacts| {
        if (tile_artifacts.tile.index > std.math.maxInt(u16)) return CodestreamError.UnsupportedPayload;
        if (tile_artifacts.scaffold.plan.resolution_count != parts_per_tile) return CodestreamError.InvalidCodestream;
        var first_packet: usize = 0;
        for (tile_artifacts.scaffold.plan.resolutions[0..parts_per_tile], 0..) |resolution, resolution_index| {
            const packet_count = std.math.cast(usize, resolution.packets) orelse return CodestreamError.InvalidCodestream;
            if (packet_count == 0) return CodestreamError.InvalidCodestream;
            const packet_end = try std.math.add(usize, first_packet, packet_count);
            if (packet_end > tile_artifacts.stream.packet_lengths.len) return CodestreamError.InvalidCodestream;
            const packet_lengths = tile_artifacts.stream.packet_lengths[first_packet..packet_end];
            const packet_header_lengths = tile_artifacts.stream.packet_header_lengths[first_packet..packet_end];
            const psot_usize = try packetPartPsot(options, packet_lengths, packet_header_lengths);
            const psot = std.math.cast(u32, psot_usize) orelse return CodestreamError.UnsupportedPayload;
            parts[out_index] = .{
                .tile_index = @intCast(tile_artifacts.tile.index),
                .tile_part_index = @intCast(resolution_index),
                .tile_part_count = @intCast(parts_per_tile),
                .first_packet = first_packet,
                .packet_count = packet_count,
                .psot = psot,
            };
            out_index += 1;
            first_packet = packet_end;
        }
        if (first_packet != tile_artifacts.stream.packet_lengths.len) return CodestreamError.InvalidCodestream;
    }
    if (out_index != parts.len) return CodestreamError.InvalidCodestream;
    return parts;
}

/// Per-layer tile-part division (`L`): LRCP keeps the layer as the outermost
/// loop inside every tile, so each of the tile's `layers` equal packet
/// ranges is one layer's worth of packets and becomes its own tile-part.
fn buildMultiTileLayerParts(
    allocator: std.mem.Allocator,
    artifacts: tile_pipeline.TileRpclEncodeGridArtifacts,
    options: LosslessOptions,
) ![]MultiTilePacketPart {
    const parts_per_tile: usize = options.layers;
    if (parts_per_tile == 0 or parts_per_tile > std.math.maxInt(u8)) return CodestreamError.UnsupportedPayload;
    const total_parts = try std.math.mul(usize, artifacts.tiles.len, parts_per_tile);
    const parts = try allocator.alloc(MultiTilePacketPart, total_parts);
    errdefer allocator.free(parts);

    var out_index: usize = 0;
    for (artifacts.tiles) |tile_artifacts| {
        if (tile_artifacts.tile.index > std.math.maxInt(u16)) return CodestreamError.UnsupportedPayload;
        const total_packets = tile_artifacts.stream.packet_lengths.len;
        if (total_packets == 0 or total_packets % parts_per_tile != 0) return CodestreamError.InvalidCodestream;
        const packet_count = total_packets / parts_per_tile;
        var first_packet: usize = 0;
        for (0..parts_per_tile) |layer_index| {
            const packet_end = first_packet + packet_count;
            const packet_lengths = tile_artifacts.stream.packet_lengths[first_packet..packet_end];
            const framed_bytes = try rpclPacketPayloadByteCount(options, packet_lengths);
            const plt_bytes = try pltBytesForRpclPacketLengths(options, packet_lengths);
            const psot_usize = try std.math.add(usize, 14, try std.math.add(usize, plt_bytes, framed_bytes));
            const psot = std.math.cast(u32, psot_usize) orelse return CodestreamError.UnsupportedPayload;
            parts[out_index] = .{
                .tile_index = @intCast(tile_artifacts.tile.index),
                .tile_part_index = @intCast(layer_index),
                .tile_part_count = @intCast(parts_per_tile),
                .first_packet = first_packet,
                .packet_count = packet_count,
                .psot = psot,
            };
            out_index += 1;
            first_packet = packet_end;
        }
        if (first_packet != total_packets) return CodestreamError.InvalidCodestream;
    }
    if (out_index != parts.len) return CodestreamError.InvalidCodestream;
    return parts;
}

/// Per-component tile-part division (`C`): CPRL keeps the component as the
/// outermost packet loop, so each RGB component occupies one contiguous third
/// of the tile packet stream and becomes its own tile-part.
fn buildMultiTileComponentParts(
    allocator: std.mem.Allocator,
    artifacts: tile_pipeline.TileRpclEncodeGridArtifacts,
    options: LosslessOptions,
) ![]MultiTilePacketPart {
    const parts_per_tile: usize = 3;
    const total_parts = try std.math.mul(usize, artifacts.tiles.len, parts_per_tile);
    const parts = try allocator.alloc(MultiTilePacketPart, total_parts);
    errdefer allocator.free(parts);

    var out_index: usize = 0;
    for (artifacts.tiles) |tile_artifacts| {
        if (tile_artifacts.tile.index > std.math.maxInt(u16)) return CodestreamError.UnsupportedPayload;
        const total_packets = tile_artifacts.stream.packet_lengths.len;
        if (total_packets == 0 or total_packets % parts_per_tile != 0) return CodestreamError.InvalidCodestream;
        const packet_count = total_packets / parts_per_tile;
        var first_packet: usize = 0;
        for (0..parts_per_tile) |component_index| {
            const packet_end = first_packet + packet_count;
            const packet_lengths = tile_artifacts.stream.packet_lengths[first_packet..packet_end];
            const framed_bytes = try rpclPacketPayloadByteCount(options, packet_lengths);
            const plt_bytes = try pltBytesForRpclPacketLengths(options, packet_lengths);
            const psot_usize = try std.math.add(usize, 14, try std.math.add(usize, plt_bytes, framed_bytes));
            const psot = std.math.cast(u32, psot_usize) orelse return CodestreamError.UnsupportedPayload;
            parts[out_index] = .{
                .tile_index = @intCast(tile_artifacts.tile.index),
                .tile_part_index = @intCast(component_index),
                .tile_part_count = parts_per_tile,
                .first_packet = first_packet,
                .packet_count = packet_count,
                .psot = psot,
            };
            out_index += 1;
            first_packet = packet_end;
        }
        if (first_packet != total_packets) return CodestreamError.InvalidCodestream;
    }
    if (out_index != parts.len) return CodestreamError.InvalidCodestream;
    return parts;
}

/// Per-position tile-part division (`P`): PCRL packets are grouped by their
/// upper-left precinct position on the image reference grid. Different edge
/// tiles may have different group counts, so TNsot is derived per tile.
fn buildMultiTilePositionParts(
    allocator: std.mem.Allocator,
    artifacts: tile_pipeline.TileRpclEncodeGridArtifacts,
    options: LosslessOptions,
) ![]MultiTilePacketPart {
    var parts: std.ArrayList(MultiTilePacketPart) = .empty;
    errdefer parts.deinit(allocator);

    for (artifacts.tiles) |tile_artifacts| {
        if (tile_artifacts.tile.index > std.math.maxInt(u16)) return CodestreamError.UnsupportedPayload;
        const packets = packet_plan.positionOrderedPackets(
            allocator,
            tile_artifacts.scaffold.plan,
            3,
            options.layers,
            .pcrl,
        ) catch return CodestreamError.InvalidCodestream;
        defer allocator.free(packets);
        if (packets.len == 0 or packets.len != tile_artifacts.stream.packet_lengths.len) {
            return CodestreamError.InvalidCodestream;
        }

        var part_count: usize = 0;
        var packet_index: usize = 0;
        while (packet_index < packets.len) : (part_count += 1) {
            const position = packet_plan.packetPosition(tile_artifacts.scaffold.plan, packets[packet_index]) catch
                return CodestreamError.InvalidCodestream;
            packet_index += 1;
            while (packet_index < packets.len) : (packet_index += 1) {
                const next = packet_plan.packetPosition(tile_artifacts.scaffold.plan, packets[packet_index]) catch
                    return CodestreamError.InvalidCodestream;
                if (next.x_ref != position.x_ref or next.y_ref != position.y_ref) break;
            }
        }
        if (part_count == 0 or part_count > std.math.maxInt(u8)) return CodestreamError.UnsupportedPayload;

        packet_index = 0;
        var local_part: usize = 0;
        while (packet_index < packets.len) : (local_part += 1) {
            const first_packet = packet_index;
            const position = packet_plan.packetPosition(tile_artifacts.scaffold.plan, packets[packet_index]) catch
                return CodestreamError.InvalidCodestream;
            packet_index += 1;
            while (packet_index < packets.len) : (packet_index += 1) {
                const next = packet_plan.packetPosition(tile_artifacts.scaffold.plan, packets[packet_index]) catch
                    return CodestreamError.InvalidCodestream;
                if (next.x_ref != position.x_ref or next.y_ref != position.y_ref) break;
            }
            const packet_lengths = tile_artifacts.stream.packet_lengths[first_packet..packet_index];
            const framed_bytes = try rpclPacketPayloadByteCount(options, packet_lengths);
            const plt_bytes = try pltBytesForRpclPacketLengths(options, packet_lengths);
            const psot_usize = try std.math.add(usize, 14, try std.math.add(usize, plt_bytes, framed_bytes));
            const psot = std.math.cast(u32, psot_usize) orelse return CodestreamError.UnsupportedPayload;
            try parts.append(allocator, .{
                .tile_index = @intCast(tile_artifacts.tile.index),
                .tile_part_index = @intCast(local_part),
                .tile_part_count = @intCast(part_count),
                .first_packet = first_packet,
                .packet_count = packet_index - first_packet,
                .psot = psot,
            });
        }
        if (local_part != part_count) return CodestreamError.InvalidCodestream;
    }
    return parts.toOwnedSlice(allocator);
}

fn appendMultiTileTlm(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    parts: []const MultiTilePacketPart,
) !void {
    if (parts.len == 0) return CodestreamError.InvalidCodestream;
    if (parts.len > 256) return CodestreamError.UnsupportedPayload;
    const payload_bytes = try std.math.mul(usize, parts.len, 6);
    const ltlm_usize = try std.math.add(usize, 4, payload_bytes);
    const ltlm = std.math.cast(u16, ltlm_usize) orelse return CodestreamError.UnsupportedPayload;
    try appendMarker(allocator, out, .tlm);
    try appendU16Be(allocator, out, ltlm);
    try out.append(allocator, 0);
    try out.append(allocator, 0x60);
    for (parts) |part| {
        try appendU16Be(allocator, out, part.tile_index);
        try appendU32Be(allocator, out, part.psot);
    }
}

fn appendMultiTilePpm(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    artifacts: tile_pipeline.TileRpclEncodeGridArtifacts,
    parts: []const MultiTilePacketPart,
    options: LosslessOptions,
) !void {
    const groups = try allocator.alloc([]u8, parts.len);
    defer allocator.free(groups);
    var initialized: usize = 0;
    defer for (groups[0..initialized]) |group| allocator.free(group);

    for (parts, 0..) |part, part_index| {
        const tile_index = @as(usize, part.tile_index);
        if (tile_index >= artifacts.tiles.len) return CodestreamError.InvalidCodestream;
        const tile_artifacts = artifacts.tiles[tile_index];
        if (tile_artifacts.tile.index != part.tile_index) return CodestreamError.InvalidCodestream;
        const packet_end = try std.math.add(usize, part.first_packet, part.packet_count);
        if (packet_end > tile_artifacts.stream.packet_lengths.len or
            packet_end > tile_artifacts.stream.packet_header_lengths.len)
        {
            return CodestreamError.InvalidCodestream;
        }
        const bytes_start = try rpclPacketByteOffset(tile_artifacts.stream.packet_lengths, part.first_packet);
        const bytes_end = try rpclPacketByteOffset(tile_artifacts.stream.packet_lengths, packet_end);
        groups[part_index] = try collectPackedPacketHeaders(
            allocator,
            options,
            tile_artifacts.stream.packet_lengths[part.first_packet..packet_end],
            tile_artifacts.stream.packet_header_lengths[part.first_packet..packet_end],
            tile_artifacts.stream.bytes[bytes_start..bytes_end],
        );
        initialized += 1;
    }

    var marker_payloads = ppm.buildMarkerPayloads(allocator, groups, 65533) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return CodestreamError.UnsupportedPayload,
    };
    defer marker_payloads.deinit();
    for (marker_payloads.items) |payload| {
        try appendMarker(allocator, out, .ppm);
        try appendU16Be(allocator, out, @intCast(payload.len + 2));
        try out.appendSlice(allocator, payload);
    }
}

fn appendMultiTilePacketPartSequence(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    artifacts: tile_pipeline.TileRpclEncodeGridArtifacts,
    parts: []const MultiTilePacketPart,
    options: LosslessOptions,
) !void {
    const uses_packed_headers = options.ppm or options.ppt;
    if (options.ppm) {
        for (parts) |part| {
            const tile_index = @as(usize, part.tile_index);
            if (tile_index >= artifacts.tiles.len) return CodestreamError.InvalidCodestream;
            const tile_artifacts = artifacts.tiles[tile_index];
            if (tile_artifacts.tile.index != part.tile_index) return CodestreamError.InvalidCodestream;
            const packet_end = try std.math.add(usize, part.first_packet, part.packet_count);
            if (packet_end > tile_artifacts.stream.packet_lengths.len or
                packet_end > tile_artifacts.stream.packet_header_lengths.len)
            {
                return CodestreamError.InvalidCodestream;
            }
            const packet_lengths = tile_artifacts.stream.packet_lengths[part.first_packet..packet_end];
            const packet_header_lengths = tile_artifacts.stream.packet_header_lengths[part.first_packet..packet_end];
            const bytes_start = try rpclPacketByteOffset(tile_artifacts.stream.packet_lengths, part.first_packet);
            const bytes_end = try rpclPacketByteOffset(tile_artifacts.stream.packet_lengths, packet_end);
            try appendSot(allocator, out, part.tile_index, part.psot, part.tile_part_index, part.tile_part_count);
            if (options.poc_in_tile_header and part.tile_part_index == 0) {
                try appendPoc(allocator, out, tile_artifacts.levels, options);
            }
            try appendMarker(allocator, out, .sod);
            var packet_sequence: u16 = @truncate(part.first_packet);
            try appendPackedPacketBodies(
                allocator,
                out,
                options,
                packet_lengths,
                packet_header_lengths,
                tile_artifacts.stream.bytes[bytes_start..bytes_end],
                &packet_sequence,
            );
        }
        return;
    }
    var part_index: usize = 0;
    for (artifacts.tiles) |tile_artifacts| {
        if (part_index >= parts.len) return CodestreamError.InvalidCodestream;
        const parts_per_tile = @as(usize, parts[part_index].tile_part_count);
        if (parts_per_tile == 0) return CodestreamError.InvalidCodestream;
        var packet_sequence: u16 = 0;
        var ppt_marker_index: u16 = 0;
        var local_part: usize = 0;
        while (local_part < parts_per_tile) : (local_part += 1) {
            if (part_index >= parts.len) return CodestreamError.InvalidCodestream;
            const part = parts[part_index];
            if (part.tile_index != tile_artifacts.tile.index or part.tile_part_index != local_part) {
                return CodestreamError.InvalidCodestream;
            }
            const packet_end = try std.math.add(usize, part.first_packet, part.packet_count);
            if (packet_end > tile_artifacts.stream.packet_lengths.len or
                packet_end > tile_artifacts.stream.packet_header_lengths.len)
            {
                return CodestreamError.InvalidCodestream;
            }
            const packet_lengths = tile_artifacts.stream.packet_lengths[part.first_packet..packet_end];
            const packet_header_lengths = tile_artifacts.stream.packet_header_lengths[part.first_packet..packet_end];
            const bytes_start = try rpclPacketByteOffset(tile_artifacts.stream.packet_lengths, part.first_packet);
            const bytes_end = try rpclPacketByteOffset(tile_artifacts.stream.packet_lengths, packet_end);
            try appendSot(allocator, out, part.tile_index, part.psot, part.tile_part_index, part.tile_part_count);
            if (options.poc_in_tile_header and part.tile_part_index == 0) {
                try appendPoc(allocator, out, tile_artifacts.levels, options);
            }
            if (uses_packed_headers) {
                try appendPltFromPackedPacketLengths(allocator, out, options, packet_lengths, packet_header_lengths);
                if (options.ppt) {
                    try appendPptPacketHeaders(
                        allocator,
                        out,
                        options,
                        packet_lengths,
                        packet_header_lengths,
                        tile_artifacts.stream.bytes[bytes_start..bytes_end],
                        &ppt_marker_index,
                    );
                }
            } else {
                try appendPltFromRpclPacketLengths(allocator, out, options, packet_lengths);
            }
            try appendMarker(allocator, out, .sod);
            if (uses_packed_headers) {
                try appendPackedPacketBodies(
                    allocator,
                    out,
                    options,
                    packet_lengths,
                    packet_header_lengths,
                    tile_artifacts.stream.bytes[bytes_start..bytes_end],
                    &packet_sequence,
                );
            } else {
                try appendRpclPackets(
                    allocator,
                    out,
                    options,
                    packet_lengths,
                    packet_header_lengths,
                    tile_artifacts.stream.bytes[bytes_start..bytes_end],
                    &packet_sequence,
                );
            }
            part_index += 1;
        }
    }
    if (part_index != parts.len) return CodestreamError.InvalidCodestream;
}

fn encodeLosslessMultiTileMeasured(
    allocator: std.mem.Allocator,
    rgb: image.RgbImage,
    grid: tile_grid.Grid,
    options: LosslessOptions,
    timings: ?*EncodeTimings,
    total_start: u64,
) ![]u8 {
    try validateMultiTileCodingPath(options);

    const levels = actualDwtLevels(rgb.width, rgb.height, options.levels);
    const encode_options = normalizedEncodePrecinctOptions(options, levels);
    try validateMultiTileGeometry(grid, levels, encode_options);

    var scaffold_precincts: [33]packet_plan.Precinct = undefined;
    for (encode_options.precincts[0..encode_options.precinct_count], 0..) |precinct, index| {
        scaffold_precincts[index] = .{ .width = precinct.width, .height = precinct.height };
    }

    const payload_start = monotonicNs();
    const block_style = ebcot.CodeBlockStyle{
        .bypass = encode_options.bypass,
        .reset_context = encode_options.reset_context,
        .terminate_all = encode_options.terminate_all,
        .vertical_causal = encode_options.vertical_causal,
        .predictable_termination = encode_options.predictable_termination,
        .segmentation_symbols = encode_options.segmentation_symbols,
    };
    const packet_order: tile_pipeline.PacketOrder = if (encode_options.poc_records.len != 0)
        .rpcl
    else switch (encode_options.progression) {
        .rpcl => .rpcl,
        .lrcp => .lrcp,
        .rlcp => .rlcp,
        .pcrl => .pcrl,
        .cprl => .cprl,
    };
    var irreversible_context = IrreversibleTileFrontEndContext{
        .quantization = encode_options.quantization,
    };
    const front_end: ?tile_pipeline.TileFrontEnd = if (encode_options.transform == .irreversible_9_7) .{
        .context = @ptrCast(&irreversible_context),
        .build = buildIrreversibleQuantizedTile,
    } else null;
    const nominal_bitplanes: ?[33][4]u8 = if (encode_options.transform == .irreversible_9_7)
        try irreversibleNominalBitplaneTable(rgb.bit_depth, levels, encode_options.guard_bits, encode_options.quantization)
    else
        null;
    const band_weights: ?[33][4]f64 = if (encode_options.transform == .irreversible_9_7 and encode_options.rate_count != 0)
        try irreversibleBandWeightTable(rgb.bit_depth, levels, encode_options.quantization)
    else
        null;
    var artifacts = try tile_pipeline.buildTileGridRpclEncodeArtifactsIsoMqParallel(
        allocator,
        rgb,
        grid,
        levels,
        .{
            .layers = encode_options.layers,
            .block_width = encode_options.block_width,
            .block_height = encode_options.block_height,
            .precincts = scaffold_precincts[0..encode_options.precinct_count],
            .packet_order = packet_order,
            .rates = encode_options.rates,
            .rate_count = encode_options.rate_count,
            .nominal_bitplanes = nominal_bitplanes,
            .band_weights = band_weights,
            .front_end = front_end,
        },
        block_style,
        encode_options.threads,
    );
    defer artifacts.deinit();
    // COD advertises one global NL; the geometry guard above should make
    // per-tile clamping impossible, but verify what the pipeline achieved.
    for (artifacts.tiles) |tile_artifacts| {
        if (tile_artifacts.levels != levels) return CodestreamError.InvalidCodestream;
    }
    if (encode_options.poc_records.len != 0) {
        for (artifacts.tiles) |*tile_artifacts| {
            const sequence = poc.buildSequence(
                allocator,
                tile_artifacts.scaffold.plan,
                3,
                encode_options.layers,
                encode_options.poc_records,
            ) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return CodestreamError.InvalidCodestream,
            };
            defer allocator.free(sequence);
            switch (encode_options.tile_part_divisions orelse 0) {
                'R' => try validatePocResolutionTilePartSequence(sequence, tile_artifacts.scaffold.plan),
                'L' => try validatePocLayerTilePartSequence(sequence, encode_options.layers),
                'C' => try validatePocComponentTilePartSequence(sequence),
                'P' => try validatePocPositionTilePartSequence(
                    allocator,
                    sequence,
                    tile_artifacts.scaffold.plan,
                    encode_options.layers,
                ),
                else => {},
            }
            try reorderTilePacketStreamFromRpclSequence(
                allocator,
                &tile_artifacts.stream,
                tile_artifacts.scaffold.plan,
                encode_options.layers,
                sequence,
            );
        }
    }
    if (timings) |t| t.payload_ns = elapsedNs(payload_start);

    const marker_start = monotonicNs();
    const division = encode_options.tile_part_divisions;
    if (division == 'R' or division == 'L' or division == 'C' or division == 'P' or
        (division == null and encode_options.poc_in_tile_header))
    {
        const parts = if (division == null)
            try buildMultiTileSingleParts(allocator, artifacts, encode_options)
        else switch (division.?) {
            'R' => try buildMultiTileResolutionParts(allocator, artifacts, levels, encode_options),
            'L' => try buildMultiTileLayerParts(allocator, artifacts, encode_options),
            'C' => try buildMultiTileComponentParts(allocator, artifacts, encode_options),
            'P' => try buildMultiTilePositionParts(allocator, artifacts, encode_options),
            else => unreachable,
        };
        defer allocator.free(parts);
        try addMultiTilePocHeaderBytes(parts, encode_options);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try appendMarker(allocator, &out, .soc);
        try appendSiz(allocator, &out, rgb, encode_options);
        try appendCod(allocator, &out, levels, encode_options);
        try appendQcd(allocator, &out, levels, rgb.bit_depth, encode_options);
        if (encode_options.poc_records.len != 0 and !encode_options.poc_in_tile_header) {
            try appendPoc(allocator, &out, levels, encode_options);
        }
        if (encode_options.tlm) try appendMultiTileTlm(allocator, &out, parts);
        if (encode_options.ppm) try appendMultiTilePpm(allocator, &out, artifacts, parts, encode_options);
        try appendMultiTilePacketPartSequence(allocator, &out, artifacts, parts, encode_options);
        try appendMarker(allocator, &out, .eoc);
        if (timings) |t| {
            t.marker_ns = elapsedNs(marker_start);
            t.total_ns = elapsedNs(total_start);
        }
        return out.toOwnedSlice(allocator);
    }

    // The default multi-tile layout remains one tile-part per tile.
    const layout_options = tile_pipeline.TilePartLayoutOptions{
        .sop = encode_options.sop,
        .eph = encode_options.eph,
        .plt = true,
    };
    var layout = try tile_pipeline.buildTilePartLayoutForGridArtifacts(allocator, artifacts, layout_options);
    defer layout.deinit();
    var tlm_plan: ?tile_pipeline.TilePartTlmPlan = if (encode_options.tlm)
        try tile_pipeline.buildTilePartTlmPlan(allocator, layout)
    else
        null;
    defer if (tlm_plan) |*plan| plan.deinit();
    var plt_plan = try tile_pipeline.buildTilePartPltPlan(allocator, artifacts, layout, layout_options);
    defer plt_plan.deinit();
    var sequence = try tile_pipeline.buildTilePartSequence(
        allocator,
        artifacts,
        layout,
        tlm_plan,
        plt_plan,
        .{ .tlm = encode_options.tlm, .tile_part = layout_options },
    );
    defer sequence.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendMarker(allocator, &out, .soc);
    try appendSiz(allocator, &out, rgb, encode_options);
    try appendCod(allocator, &out, levels, encode_options);
    try appendQcd(allocator, &out, levels, rgb.bit_depth, encode_options);
    if (encode_options.poc_records.len != 0 and !encode_options.poc_in_tile_header) {
        try appendPoc(allocator, &out, levels, encode_options);
    }
    try out.appendSlice(allocator, sequence.bytes);
    try appendMarker(allocator, &out, .eoc);
    if (timings) |t| {
        t.marker_ns = elapsedNs(marker_start);
        t.total_ns = elapsedNs(total_start);
    }

    return out.toOwnedSlice(allocator);
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

fn validateRates(options: LosslessOptions) !void {
    if (options.rate_count > max_quality_layers) return CodestreamError.InvalidCodestream;
    for (options.rates[0..options.rate_count]) |rate| {
        if (!std.math.isFinite(rate) or rate <= 0) return CodestreamError.InvalidCodestream;
    }
}

fn validateTilePartDivisions(value: ?u8) !void {
    const actual = value orelse return;
    switch (actual) {
        'R', 'L', 'C', 'P' => {},
        else => return CodestreamError.InvalidCodestream,
    }
}

fn validateCodingPath(options: LosslessOptions) !void {
    switch (options.progression) {
        .rpcl => {},
        // LRCP (B.12.1.1), RLCP (B.12.1.2), PCRL (B.12.1.4), and CPRL
        // (B.12.1.5) ride the same per-precinct packet bodies as RPCL; only
        // the stream order differs. The debug sidecar frames packets in RPCL
        // order and its cross-checks assume it, so it stays fail-closed for
        // the permuted orders.
        .lrcp, .rlcp, .pcrl, .cprl => if (options.emit_temporary_payload_sidecar) return CodestreamError.UnsupportedPayload,
    }
    switch (options.transform) {
        .reversible_5_3 => {
            // RCT (component-decorrelating) and none (independent components,
            // ISO A.3.1) are both wired for the reversible path.
            if (options.mct != .rct and options.mct != .none) return CodestreamError.UnsupportedPayload;
            if (options.quantization != .none) return CodestreamError.UnsupportedPayload;
            // The debug temporary-payload sidecar header does not carry the MCT
            // choice, so it would misdecode a no-transform stream; fail closed.
            if (options.mct == .none and options.emit_temporary_payload_sidecar) return CodestreamError.UnsupportedPayload;
        },
        .irreversible_9_7 => {
            if (options.mct != .ict) return CodestreamError.UnsupportedPayload;
            // Scalar-expounded signals every band step; scalar-derived
            // signals only the NL LL step and derives the rest (A.6.4/E-5).
            if (options.quantization != .scalar_expounded and
                options.quantization != .scalar_derived)
            {
                return CodestreamError.UnsupportedPayload;
            }
            if (options.emit_temporary_payload_sidecar) return CodestreamError.UnsupportedPayload;
        },
    }
    // vertical_causal (0x08), segmentation_symbols (0x20), reset_context
    // (0x02), and terminate_all (0x04) are wired end-to-end. vertical_causal
    // forms stripe-causal contexts (ISO 15444-1 D.7); segmentation_symbols
    // emits the 0xA UNIFORM-context symbol after each cleanup pass and the
    // decoder validates it (D.5); terminate_all independently terminates the
    // MQ coder on every coding pass (D.4.5); reset_context restarts the MQ
    // contexts at every coding-pass boundary (D.4) either inside the
    // continuous stream (standalone RESET) or across TERMALL segments.
    // predictable_termination (0x10) is an opt-in ER-TERM encode path (D.4.2):
    // standalone it replaces the final continuous MQ flush, with TERMALL it
    // flushes every per-pass segment; both are accepted by the strict reader
    // and verified against Kakadu.
    // The default profile sets no style bits, so the narrow path is unaffected.
    if (options.reset_context) {
        // The per-pass context reset is only wired for the ISO MQ backend;
        // the legacy backend keeps it fail-closed on the public encode path.
        if (options.t1_backend != .iso_mq) return CodestreamError.UnsupportedPayload;
    }
    if (options.predictable_termination) {
        // ER-TERM (D.4.2) is wired for the ISO MQ coder only: standalone it
        // replaces the final continuous flush, with terminate_all it flushes
        // every per-pass segment, and with BYPASS every raw/MQ segment
        // boundary terminates predictably (alternating-bit raw padding).
        if (options.t1_backend != .iso_mq) return CodestreamError.UnsupportedPayload;
    }
    if (options.terminate_all) {
        // The per-pass terminated encoder is only wired for the ISO MQ backend;
        // the legacy backend would silently drop the flag while the COD marker
        // still advertised it, so fail closed instead of emitting a stream the
        // strict decoder cannot read back.
        if (options.t1_backend != .iso_mq) return CodestreamError.UnsupportedPayload;
        // Multi-layer terminate_all (a layer including only part of a block's
        // per-pass segments) is not yet wired; keep it fail-closed until proven.
        if (options.layers != 1) return CodestreamError.UnsupportedPayload;
    }
    if (options.bypass) {
        // BYPASS requires the ISO MQ backend; quality layers and rates are
        // supported with truncation points snapped to segment boundaries.
        // RESET and ERTERM ride both the non-TERMALL and the per-pass
        // TERMALL BYPASS segment models.
        if (options.t1_backend != .iso_mq) return CodestreamError.UnsupportedPayload;
        if (options.emit_temporary_payload_sidecar) return CodestreamError.UnsupportedPayload;
    }
    if (options.guard_bits == 0 or options.guard_bits > 7) return CodestreamError.InvalidCodestream;
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
    const style = ebcot.CodeBlockStyle{
        .bypass = options.bypass,
        .reset_context = options.reset_context,
        .terminate_all = options.terminate_all,
        .vertical_causal = options.vertical_causal,
        .predictable_termination = options.predictable_termination,
        .segmentation_symbols = options.segmentation_symbols,
    };
    return style.toCodByte();
}

fn parseCodeBlockStyleByte(style: u8) !ebcot.CodeBlockStyle {
    const parsed = ebcot.CodeBlockStyle.fromCodByte(style) orelse return CodestreamError.InvalidCodestream;
    // BYPASS (0x01), reset_context (0x02), terminate_all (0x04),
    // vertical_causal (0x08), predictable_termination (0x10, TERMALL-only), and
    // segmentation_symbols (0x20) are accepted by the strict metadata layer
    // only for combinations whose payload model is implemented.
    const supported_style_bits: u8 = 0x01 | 0x02 | 0x04 | 0x08 | 0x10 | 0x20;
    if ((parsed.toCodByte() & ~supported_style_bits) != 0) return CodestreamError.UnsupportedPayload;
    // Every combination of the six Part 1 style bits decodes now: RESET
    // restarts contexts at MQ pass boundaries in all four segment models
    // (continuous, BYPASS, TERMALL, BYPASS+TERMALL), and ER-TERM only
    // changes flush bytes, which the MQ/raw readers consume
    // padding-independently.
    return parsed;
}

fn qcdStyleByte(options: LosslessOptions) u8 {
    return (options.guard_bits << 5) | @intFromEnum(options.quantization);
}

fn qcdReversibleExponentByteForBand(bit_depth: u8, kind: subband.Kind) !u8 {
    return (try subbandExponent(bit_depth, kind)) << 3;
}

/// QCD subband exponent epsilon_b for the reversible no-quantization path.
fn subbandExponent(bit_depth: u8, kind: subband.Kind) !u8 {
    const gain = subbandGain(kind);
    if (bit_depth == 0 or bit_depth > 31 - gain) return CodestreamError.InvalidCodestream;
    return bit_depth + gain;
}

/// ISO/IEC 15444-1 E-2: Mb = G + epsilon_b - 1, where epsilon_b is the QCD
/// subband exponent (bit_depth + gain for the reversible no-quantization
/// path) and G is the guard bit count. Zero-bitplane tag-tree values must be
/// relative to this Mb, or independent decoders reconstruct shifted
/// magnitudes.
fn subbandNominalBitplanes(bit_depth: u8, kind: subband.Kind, guard_bits: u8) !u8 {
    if (guard_bits == 0) return CodestreamError.InvalidCodestream;
    const total = @as(u16, try subbandExponent(bit_depth, kind)) + guard_bits - 1;
    if (total > 31) return CodestreamError.InvalidCodestream;
    return @intCast(total);
}

fn subbandGain(kind: subband.Kind) u8 {
    return switch (kind) {
        .ll => 0,
        .hl, .lh => 1,
        .hh => 2,
    };
}

/// L2 norms of the 9/7 synthesis basis per orientation and decomposition
/// level, matching OpenJPEG's opj_dwt_norms_real so default quantization step
/// sizes line up with the reference encoder.
const dwt97_norms = [4][10]f64{
    .{ 1.000, 1.965, 4.177, 8.403, 16.90, 33.84, 67.69, 135.3, 270.6, 540.9 },
    .{ 2.022, 3.989, 8.355, 17.04, 34.27, 68.63, 137.3, 274.6, 549.0, 549.0 },
    .{ 2.022, 3.989, 8.355, 17.04, 34.27, 68.63, 137.3, 274.6, 549.0, 549.0 },
    .{ 2.080, 3.865, 8.307, 17.18, 34.71, 69.59, 139.3, 278.6, 557.2, 557.2 },
};

pub const BandStepSize = struct {
    exponent: u8,
    mantissa: u16,
};

fn dwt97Norm(level: usize, orient: usize) f64 {
    const clamped = if (orient == 0) @min(level, 9) else @min(level, 8);
    return dwt97_norms[orient][clamped];
}

/// L2 norms of the 5/3 synthesis basis per orientation and decomposition
/// level, matching OpenJPEG's opj_dwt_norms (qmfbid == 1). Used only to
/// weight PCRD distortion estimates on the reversible path; never signalled.
const dwt53_norms = [4][10]f64{
    .{ 1.000, 1.500, 2.750, 5.375, 10.68, 21.34, 42.67, 85.33, 170.7, 341.3 },
    .{ 1.038, 1.592, 2.919, 5.703, 11.33, 22.64, 45.25, 90.48, 180.9, 362.0 },
    .{ 1.038, 1.592, 2.919, 5.703, 11.33, 22.64, 45.25, 90.48, 180.9, 362.0 },
    .{ 0.7186, 0.9218, 1.586, 3.043, 6.019, 12.01, 24.00, 47.97, 95.93, 191.9 },
};

fn dwt53Norm(level: usize, orient: usize) f64 {
    const clamped = if (orient == 0) @min(level, 9) else @min(level, 8);
    return dwt53_norms[orient][clamped];
}

/// PCRD distortion weight for one band: (synthesis-basis L2 norm x
/// quantization step)^2 converts coefficient-domain squared error into its
/// image-domain contribution (J.14 weighting).
fn pcrdBandWeight(band: subband.Band, options: LosslessOptions, bit_depth: u8, levels: u8) !f64 {
    const opj_level: usize = if (band.kind == .ll) band.level else @as(usize, band.level) - 1;
    const orient: usize = switch (band.kind) {
        .ll => 0,
        .hl => 1,
        .lh => 2,
        .hh => 3,
    };
    switch (options.transform) {
        .reversible_5_3 => {
            const norm = dwt53Norm(opj_level, orient);
            return norm * norm;
        },
        .irreversible_9_7 => {
            const step = try irreversibleBandStepSizeFor(options.quantization, bit_depth, band.kind, band.level, levels);
            const weighted = irreversiblePcrdDelta(bit_depth, band.kind, step) * dwt97Norm(opj_level, orient);
            return weighted * weighted;
        },
    }
}

/// Default scalar-expounded step size for the irreversible 9/7 path,
/// mirroring OpenJPEG's opj_dwt_calc_explicit_stepsizes with qmfbid == 0
/// (gain 0 for every band).
fn irreversibleBandStepSize(bit_depth: u8, kind: subband.Kind, band_level: u8) !BandStepSize {
    // z2000 band levels count down from the total level count; OpenJPEG's
    // "level" is the decomposition depth of the band.
    const opj_level: usize = if (kind == .ll) band_level else @as(usize, band_level) - 1;
    const orient: usize = switch (kind) {
        .ll => 0,
        .hl => 1,
        .lh => 2,
        .hh => 3,
    };
    const stepsize = 1.0 / dwt97Norm(opj_level, orient);
    const fixed: i32 = @intFromFloat(@floor(stepsize * 8192.0));
    if (fixed <= 0) return CodestreamError.InvalidCodestream;
    const log2_fixed: i32 = @as(i32, std.math.log2_int(u32, @intCast(fixed)));
    const p = log2_fixed - 13;
    const n = 11 - log2_fixed;
    const mant: u16 = @intCast((if (n < 0)
        fixed >> @intCast(-n)
    else
        fixed << @intCast(n)) & 0x7ff);
    const expn = @as(i32, bit_depth) - p;
    if (expn <= 0 or expn > 31) return CodestreamError.InvalidCodestream;
    return .{ .exponent = @intCast(expn), .mantissa = mant };
}

/// Scalar-derived step size (ISO 15444-1 A.6.4, E-5): the QCD signals one
/// (exponent, mantissa) pair for the NL LL band and every other subband
/// derives epsilon_b = epsilon_0 - (NL - n_b) with the mantissa shared,
/// where n_b is the band's decomposition depth (z2000 `band_level`, counting
/// down from the total level count so the deepest triple keeps epsilon_0).
fn derivedBandStepSize(bit_depth: u8, kind: subband.Kind, band_level: u8, levels: u8) !BandStepSize {
    const base = try irreversibleBandStepSize(bit_depth, .ll, levels);
    if (kind == .ll) return base;
    if (band_level == 0 or band_level > levels) return CodestreamError.InvalidCodestream;
    const exponent = @as(i32, base.exponent) - (@as(i32, levels) - @as(i32, band_level));
    if (exponent <= 0 or exponent > 31) return CodestreamError.InvalidCodestream;
    return .{ .exponent = @intCast(exponent), .mantissa = base.mantissa };
}

/// Step size for one band of the irreversible path under the signalled
/// quantization style. `.none` is the reversible style and never quantizes.
fn irreversibleBandStepSizeFor(
    quantization: QuantizationStyle,
    bit_depth: u8,
    kind: subband.Kind,
    band_level: u8,
    levels: u8,
) !BandStepSize {
    return switch (quantization) {
        .scalar_expounded => try irreversibleBandStepSize(bit_depth, kind, band_level),
        .scalar_derived => try derivedBandStepSize(bit_depth, kind, band_level, levels),
        .none => CodestreamError.InvalidCodestream,
    };
}

/// Reconstruction step size delta_b from an (exponent, mantissa) pair per
/// ISO/IEC 15444-1 E-3 with R_b = bit_depth + Table E-1 subband gain (E-4).
/// The encoder-side (epsilon, mu) derivation folds the gain out again, so the
/// wire values match OpenJPEG while the effective step includes the gain.
fn irreversibleBandDelta(bit_depth: u8, kind: subband.Kind, step: BandStepSize) f64 {
    const rb = @as(i32, bit_depth) + @as(i32, subbandGain(kind));
    const exponent_diff = rb - @as(i32, step.exponent);
    const base = std.math.pow(f64, 2.0, @floatFromInt(exponent_diff));
    return base * (1.0 + @as(f64, @floatFromInt(step.mantissa)) / 2048.0);
}

/// OpenJPEG-compatible Tier-1 distortion step. The irreversible coder's
/// coefficient normalization already carries the subband gain, so PCRD
/// removes it before applying the 9/7 synthesis norm (opj_t1_getwmsedec).
fn irreversiblePcrdDelta(bit_depth: u8, kind: subband.Kind, step: BandStepSize) f64 {
    const gain_scale: u8 = @as(u8, 1) << @intCast(subbandGain(kind));
    return irreversibleBandDelta(bit_depth, kind, step) /
        @as(f64, @floatFromInt(gain_scale));
}

/// Mb for a band under either coding path: guard + epsilon_b - 1.
/// makeBands always yields 1 + 3 * levels bands, so the decomposition level
/// count can be recovered from the band table where it is not threaded.
fn dwtLevelsFromBands(bands: []const subband.Band) u8 {
    return @intCast((bands.len - 1) / 3);
}

fn bandNominalBitplanesForTransform(
    bit_depth: u8,
    kind: subband.Kind,
    band_level: u8,
    transform: WaveletTransform,
    guard_bits: u8,
    quantization: QuantizationStyle,
    levels: u8,
) !u8 {
    if (guard_bits == 0) return CodestreamError.InvalidCodestream;
    // Mb derives from the *signalled* epsilon_b (E-2): under scalar-derived
    // quantization every decoder reconstructs epsilon_b from the single QCD
    // value via E-5, so the encoder must size bitplanes from the same table.
    const epsilon: u16 = switch (transform) {
        .reversible_5_3 => try subbandExponent(bit_depth, kind),
        .irreversible_9_7 => (try irreversibleBandStepSizeFor(quantization, bit_depth, kind, band_level, levels)).exponent,
    };
    const total = epsilon + @as(u16, guard_bits) - 1;
    if (total == 0 or total > 31) return CodestreamError.InvalidCodestream;
    return @intCast(total);
}
