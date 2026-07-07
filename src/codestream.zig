const std = @import("std");
const builtin = @import("builtin");
const bitplane = @import("bitplane.zig");
const color = @import("color.zig");
const ebcot = @import("ebcot.zig");
const entropy = @import("entropy.zig");
const image = @import("image.zig");
const packet_plan = @import("packet_plan.zig");
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

/// The strict decode path fail-closes on any other QCD guard bit count, so
/// decode-side Mb derivation can rely on this value.
const strict_guard_bits: u8 = 2;

pub const LosslessOptions = struct {
    levels: u8 = 5,
    layers: u16 = 1,
    rates: [max_quality_layers]f64 = [_]f64{0} ** max_quality_layers,
    rate_count: u8 = 0,
    progression: ProgressionOrder = .rpcl,
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

const ComponentSlices = struct {
    y: []i32,
    cb: []i32,
    cr: []i32,

    fn get(self: ComponentSlices, index: usize) []i32 {
        return switch (index) {
            0 => self.y,
            1 => self.cb,
            2 => self.cr,
            else => unreachable,
        };
    }
};

const DwtJob = struct {
    plane: []i32,
    width: usize,
    height: usize,
    levels: u8,
    result: anyerror!void = {},
};

fn forwardComponents53(
    allocator: std.mem.Allocator,
    planes: *color.RctPlanes,
    options: LosslessOptions,
) !u8 {
    const levels = actualDwtLevels(planes.width, planes.height, options.levels);
    const slices = ComponentSlices{ .y = planes.y, .cb = planes.cb, .cr = planes.cr };
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

    var jobs: [3]DwtJob = undefined;
    for (&jobs, 0..) |*job, component| {
        job.* = .{
            .plane = slices.get(component),
            .width = planes.width,
            .height = planes.height,
            .levels = levels,
        };
    }

    try runComponentJobs(DwtJob, &jobs, componentThreadCount(options), dwtWorker);
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
) !color.RctPlanes {
    var ict = try color.forwardIct(allocator, rgb);
    defer ict.deinit();

    inline for (.{ ict.y, ict.cb, ict.cr }) |plane| {
        const done = try wavelet.forward2D(allocator, plane, ict.width, ict.height, levels, .irreversible_9_7);
        if (done != levels) return CodestreamError.InvalidCodestream;
    }

    const bands = try subband.makeBands(allocator, ict.width, ict.height, levels);
    defer allocator.free(bands);

    const pixels = try std.math.mul(usize, ict.width, ict.height);
    const y = try allocator.alloc(i32, pixels);
    errdefer allocator.free(y);
    const cb = try allocator.alloc(i32, pixels);
    errdefer allocator.free(cb);
    const cr = try allocator.alloc(i32, pixels);
    errdefer allocator.free(cr);

    for (bands) |band| {
        const delta = irreversibleBandDelta(
            rgb.bit_depth,
            band.kind,
            try irreversibleBandStepSizeFor(options.quantization, rgb.bit_depth, band.kind, band.level, levels),
        );
        quantizeBandRegion(ict.y, y, ict.width, band.rect, delta);
        quantizeBandRegion(ict.cb, cb, ict.width, band.rect, delta);
        quantizeBandRegion(ict.cr, cr, ict.width, band.rect, delta);
    }

    return .{
        .allocator = allocator,
        .width = ict.width,
        .height = ict.height,
        .bit_depth = rgb.bit_depth,
        .y = y,
        .cb = cb,
        .cr = cr,
    };
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

fn dwtWorker(job: *DwtJob) void {
    var workspace = wavelet_int.Workspace.init(std.heap.smp_allocator, @max(job.width, job.height)) catch |err| {
        job.result = err;
        return;
    };
    defer workspace.deinit();
    _ = wavelet_int.forward53WithWorkspace(&workspace, job.plane, job.width, job.height, job.levels) catch |err| {
        job.result = err;
        return;
    };
    job.result = {};
}

fn inverseDwtWorker(job: *DwtJob) void {
    var workspace = wavelet_int.Workspace.init(std.heap.smp_allocator, @max(job.width, job.height)) catch |err| {
        job.result = err;
        return;
    };
    defer workspace.deinit();
    wavelet_int.inverse53WithWorkspace(&workspace, job.plane, job.width, job.height, job.levels) catch |err| {
        job.result = err;
        return;
    };
    job.result = {};
}

fn inverseComponents53(
    allocator: std.mem.Allocator,
    slices: ComponentSlices,
    width: usize,
    height: usize,
    levels: u8,
    options: DecodeOptions,
) !void {
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

    var jobs: [3]DwtJob = undefined;
    for (&jobs, 0..) |*job, component| {
        job.* = .{
            .plane = slices.get(component),
            .width = width,
            .height = height,
            .levels = levels,
        };
    }

    try runComponentJobs(DwtJob, &jobs, componentThreadCountFor(options.threads), inverseDwtWorker);
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
    layers: [max_quality_layers]t2.LayerTruncation,
    encoded: t2.EncodedLayerBlock,

    fn deinit(self: *RpclShadowBlock, allocator: std.mem.Allocator) void {
        if (self.bitplane) |*passes| passes.deinit(allocator);
        self.segment.deinit(allocator);
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
    components: [3][]StrictPacketBlock = [_][]StrictPacketBlock{&.{}} ** 3,
    payloads: [3][]u8 = [_][]u8{&.{}} ** 3,

    pub fn deinit(self: *StrictPacketBlockCatalog) void {
        for (0..3) |component| {
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
};

const StrictTilePartHeader = struct {
    sot: StrictSotInfo,
    sod: usize,
    end: usize,
    packet_payload_bytes: usize,
    packet_lengths: std.ArrayList(usize),

    fn deinit(self: *StrictTilePartHeader, allocator: std.mem.Allocator) void {
        self.packet_lengths.deinit(allocator);
        self.* = undefined;
    }
};

const StrictMainHeaderIndex = struct {
    allocator: std.mem.Allocator,
    first_sot: usize,
    packet_markers: MainHeaderPacketMarkers,
    tlm_entries: ?[]TlmEntry = null,

    fn deinit(self: *StrictMainHeaderIndex) void {
        if (self.tlm_entries) |entries| self.allocator.free(entries);
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
    assemblies: [3]StrictComponentAssembly = undefined,
    initialized: usize = 0,

    fn init(allocator: std.mem.Allocator, block_count: usize, use_component_payloads: bool) !StrictComponentAssemblySet {
        var set = StrictComponentAssemblySet{};
        errdefer set.deinit();
        inline for (0..3) |component| {
            set.assemblies[component] = try StrictComponentAssembly.init(allocator, block_count, use_component_payloads);
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
    resolution_offsets: [33]usize,
    resolution_count: u8,
    cells: []RpclBlockIndexCell,

    fn init(allocator: std.mem.Allocator, plan: packet_plan.Plan) !RpclBlockIndex {
        var resolution_offsets: [33]usize = [_]usize{0} ** 33;
        var cell_count: usize = 0;
        var resolution_index: usize = 0;
        while (resolution_index < plan.resolution_count) : (resolution_index += 1) {
            resolution_offsets[resolution_index] = cell_count;
            const resolution_cells = try std.math.mul(usize, @as(usize, @intCast(plan.resolutions[resolution_index].precincts)), 3);
            cell_count = try std.math.add(usize, cell_count, resolution_cells);
        }

        const cells = try allocator.alloc(RpclBlockIndexCell, cell_count);
        for (cells) |*entry| entry.* = .{};
        return .{
            .allocator = allocator,
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
        if (resolution >= self.resolution_count or component >= 3) return CodestreamError.InvalidCodestream;
        const offset = try std.math.add(usize, self.resolution_offsets[resolution], try std.math.mul(usize, @as(usize, @intCast(precinct_index)), 3));
        const index = try std.math.add(usize, offset, @as(usize, @intCast(component)));
        if (index >= self.cells.len) return CodestreamError.InvalidCodestream;
        return &self.cells[index];
    }

    fn indexesFor(self: *const RpclBlockIndex, resolution: u8, precinct_index: u64, component: u16) ![]const usize {
        if (resolution >= self.resolution_count or component >= 3) return CodestreamError.InvalidCodestream;
        const offset = try std.math.add(usize, self.resolution_offsets[resolution], try std.math.mul(usize, @as(usize, @intCast(precinct_index)), 3));
        const index = try std.math.add(usize, offset, @as(usize, @intCast(component)));
        if (index >= self.cells.len) return CodestreamError.InvalidCodestream;
        return self.cells[index].indexes.items;
    }
};

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
            try color.forwardRct(allocator, rgb),
        .irreversible_9_7 => try forwardIrreversibleQuantizedPlanes(allocator, rgb, levels, options),
    };
    defer planes.deinit();
    if (timings) |t| t.color_transform_ns = elapsedNs(color_start);

    const wavelet_start = monotonicNs();
    if (options.transform == .reversible_5_3) {
        const dwt_levels = try forwardComponents53(allocator, &planes, options);
        if (dwt_levels != levels) return CodestreamError.InvalidCodestream;
    }
    if (timings) |t| t.wavelet_ns = elapsedNs(wavelet_start);

    var encode_options = normalizedEncodePrecinctOptions(options, levels);
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

    var tile_payload: std.ArrayList(u8) = .empty;
    defer tile_payload.deinit(allocator);
    var rpcl_stream: RpclPacketStream = .{};
    defer rpcl_stream.deinit();
    const payload_start = monotonicNs();
    try appendTemporaryPayload(allocator, &tile_payload, planes, levels, encode_options, &rpcl_stream);
    if (timings) |t| t.payload_ns = elapsedNs(payload_start);
    if (encode_options.progression != .rpcl) {
        try reorderPacketStreamFromRpcl(allocator, &rpcl_stream, rgb.width, rgb.height, levels, encode_options);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const marker_start = monotonicNs();
    try appendMarker(allocator, &out, .soc);
    try appendSiz(allocator, &out, rgb, encode_options);
    try appendCod(allocator, &out, levels, encode_options);
    try appendQcd(allocator, &out, levels, rgb.bit_depth, encode_options);
    if (encode_options.emit_temporary_payload_sidecar) {
        try appendTemporaryPayloadComments(allocator, &out, tile_payload.items);
    }
    const packets = try makePacketPlan(rgb.width, rgb.height, levels, encode_options);
    if (rpcl_stream.packet_lengths.len != packets.packets) return CodestreamError.InvalidCodestream;
    if (rpcl_stream.packet_header_lengths.len != packets.packets) return CodestreamError.InvalidCodestream;
    const tile_parts = tilePartCountForOptions(levels, encode_options);
    var psots: [33]u32 = undefined;
    var tile_part_payload_bytes: [33]usize = undefined;
    var tile_part_index: usize = 0;
    while (tile_part_index < tile_parts) : (tile_part_index += 1) {
        const packet_range = tilePartPacketRange(packets, tile_part_index, tile_parts, encode_options);
        const packet_lengths = rpcl_stream.packet_lengths[packet_range.start..][0..packet_range.count];
        tile_part_payload_bytes[tile_part_index] = try rpclPacketPayloadByteCount(encode_options, packet_lengths);
        const plt_bytes = try pltBytesForRpclPacketLengths(encode_options, packet_lengths);
        const tile_part_bytes = try std.math.add(usize, plt_bytes, tile_part_payload_bytes[tile_part_index]);
        psots[tile_part_index] = try std.math.add(u32, 14, @as(u32, @intCast(tile_part_bytes)));
    }

    if (encode_options.tlm) try appendTlm(allocator, &out, psots[0..tile_parts]);
    var packet_sequence: u16 = 0;
    tile_part_index = 0;
    while (tile_part_index < tile_parts) : (tile_part_index += 1) {
        const packet_range = tilePartPacketRange(packets, tile_part_index, tile_parts, encode_options);
        const packet_lengths = rpcl_stream.packet_lengths[packet_range.start..][0..packet_range.count];
        const packet_header_lengths = rpcl_stream.packet_header_lengths[packet_range.start..][0..packet_range.count];
        const packet_bytes_start = try rpclPacketByteOffset(rpcl_stream.packet_lengths, packet_range.start);
        const packet_bytes_end = try rpclPacketByteOffset(rpcl_stream.packet_lengths, packet_range.start + packet_range.count);
        try appendSot(allocator, &out, psots[tile_part_index], @intCast(tile_part_index), @intCast(tile_parts));
        try appendPltFromRpclPacketLengths(allocator, &out, encode_options, packet_lengths);
        try appendMarker(allocator, &out, .sod);
        try appendRpclPackets(
            allocator,
            &out,
            encode_options,
            packet_lengths,
            packet_header_lengths,
            rpcl_stream.packet_bytes[packet_bytes_start..packet_bytes_end],
            &packet_sequence,
        );
    }
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

    try readComponentPayloads(&cursor, y, cb, cr, width, header.version, header.layers, options);
    _ = try readRpclShadowStreamInfo(&cursor, header.version, header.packet_count);
    if (!cursor.finished()) return CodestreamError.InvalidCodestream;
    if (timings) |t| t.sidecar_or_legacy_ns += elapsedNs(legacy_start);

    const wavelet_start = monotonicNs();
    try inverseComponents53(allocator, .{ .y = y, .cb = cb, .cr = cr }, width, height, levels, options);
    if (timings) |t| t.wavelet_ns += elapsedNs(wavelet_start);

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
    return readStrictSodPacketCatalog(allocator, bytes, plan, header.layers, header.progression);
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
    var build = try strictPacketBlockCatalogFromAssembliesChecked(allocator, &assemblies.assemblies);
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
    var levels: u8 = 0;
    var layers: u16 = 0;
    var block_width: u16 = 0;
    var block_height: u16 = 0;
    var parsed_code_block_style = ebcot.CodeBlockStyle{};
    var parsed_transform: WaveletTransform = .reversible_5_3;
    var parsed_mct: MultipleComponentTransform = .rct;
    var parsed_progression: ProgressionOrder = .rpcl;
    var parsed_quantization: QuantizationStyle = .none;
    var precincts = defaultPrecincts();
    var precinct_count: u8 = 0;
    var parsed_grid: ?tile_grid.Grid = null;
    var saw_siz = false;
    var saw_cod = false;
    var saw_qcd = false;
    var qcd_band_count: usize = 0;
    var tlm_entries: std.ArrayList(TlmEntry) = .empty;
    defer tlm_entries.deinit(allocator);
    var saw_tlm = false;
    var next_tlm_index: usize = 0;

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
            const components = readU16Be(segment, 34);
            if (components != 3) return CodestreamError.UnsupportedPayload;
            if (segment.len != 36 + @as(usize, components) * 3) return CodestreamError.InvalidCodestream;
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
            while (component_index < components) : (component_index += 1) {
                const component_offset = 36 + component_index * 3;
                const ssiz = segment[component_offset];
                if ((ssiz & 0x80) != 0) return CodestreamError.UnsupportedPayload;
                const component_bit_depth = (ssiz & 0x7f) + 1;
                if (component_bit_depth != bit_depth) return CodestreamError.UnsupportedPayload;
                if (segment[component_offset + 1] != 1 or segment[component_offset + 2] != 1) {
                    return CodestreamError.UnsupportedPayload;
                }
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
            precinct_count = if ((scod & 0x01) != 0) levels + 1 else 0;
            if (precinct_count > precincts.len or segment.len < 10 + @as(usize, precinct_count)) {
                return CodestreamError.InvalidCodestream;
            }
            if (segment.len != 10 + @as(usize, precinct_count)) return CodestreamError.InvalidCodestream;
            if (precinct_count > 0) {
                for (segment[10..][0..precinct_count], 0..) |byte, index| {
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
            }
            saw_cod = true;
        } else if (marker == @intFromEnum(Marker.qcd)) {
            if (!saw_cod or saw_qcd) return CodestreamError.InvalidCodestream;
            const qcd_info = try validateStrictQcdSegment(segment, bit_depth, levels, parsed_transform);
            qcd_band_count = qcd_info.bands;
            parsed_quantization = qcd_info.quantization;
            saw_qcd = true;
        } else if (marker == @intFromEnum(Marker.tlm)) {
            try appendStrictTlmEntries(allocator, &tlm_entries, segment, next_tlm_index);
            saw_tlm = true;
            next_tlm_index += 1;
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
    if (qcd_band_count != 1 + 3 * @as(usize, levels)) return CodestreamError.InvalidCodestream;

    const options = LosslessOptions{
        .levels = levels,
        .layers = layers,
        .block_width = block_width,
        .block_height = block_height,
        .precincts = precincts,
        .precinct_count = if (precinct_count == 0) 1 else precinct_count,
    };
    const grid = parsed_grid orelse return CodestreamError.InvalidCodestream;
    if (!grid.isSingleTile()) {
        // Multi-tile: validate the v1 tile-part discipline (one part per tile,
        // row-major, TPsot=0/TNsot=1, per-tile packet plans, TLM cross-check)
        // and the same geometry envelope the encoder enforces. The per-tile
        // spans this produces feed the Stage C decode; the block-catalog stage
        // still fails closed until then. The multi-tile envelope is RPCL-only.
        if (parsed_progression != .rpcl) return CodestreamError.UnsupportedPayload;
        try validateMultiTileGeometry(grid, levels, options);
        var spans = try readStrictMultiTileTilePartSpans(
            allocator,
            bytes,
            cursor,
            grid,
            levels,
            options,
            if (saw_tlm) tlm_entries.items else null,
        );
        defer spans.deinit(allocator);
        var total_packets: u64 = 0;
        for (spans.items) |span| {
            total_packets = try std.math.add(u64, total_packets, span.packet_count);
        }
        const plan = try makePacketPlan(width, height, levels, options);
        return .{
            .version = 8,
            .width = width,
            .height = height,
            .bit_depth = bit_depth,
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
            .tile_part_divisions = null,
            .tile_part_plan_count = 0,
            .tile_part_plan = [_]u8{0} ** 33,
            .packet_plan_count = plan.resolution_count,
            .packet_plan = plan.resolutions,
            .packet_count = total_packets,
        };
    }
    const plan = try makePacketPlan(width, height, levels, options);
    const tile_part_packets = try readStrictTilePartPacketPlan(
        allocator,
        bytes,
        cursor,
        if (saw_tlm) tlm_entries.items else null,
    );
    const tile_part_plan = try validateStrictTilePartPacketPlan(tile_part_packets, plan, levels);

    return .{
        .version = 8,
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .levels = levels,
        .layers = layers,
        .progression = parsed_progression,
        .mct = parsed_mct,
        .transform = parsed_transform,
        .quantization = parsed_quantization,
        .code_block_style = parsed_code_block_style,
        .block_width = block_width,
        .block_height = block_height,
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
        @intFromEnum(Marker.coc),
        @intFromEnum(Marker.plm),
        @intFromEnum(Marker.qcc),
        @intFromEnum(Marker.rgn),
        @intFromEnum(Marker.poc),
        @intFromEnum(Marker.ppm),
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
        @intFromEnum(Marker.poc),
        @intFromEnum(Marker.ppt),
        => true,
        else => false,
    };
}

fn codeBlockSizeFromCodExponent(exponent: u8) !u16 {
    if (exponent > 8) return CodestreamError.InvalidCodestream;
    return @as(u16, 1) << @as(u4, @intCast(exponent + 2));
}

const StrictQcdInfo = struct {
    /// Logical subband count covered by the segment (1 + 3 * levels); the
    /// scalar-derived style covers all bands with a single signalled value.
    bands: usize,
    quantization: QuantizationStyle,
};

fn validateStrictQcdSegment(segment: []const u8, bit_depth: u8, levels: u8, transform: WaveletTransform) !StrictQcdInfo {
    if (segment.len < 2) return CodestreamError.InvalidCodestream;
    if (bit_depth == 0) return CodestreamError.InvalidCodestream;
    const bands = 1 + 3 * @as(usize, levels);
    const style = segment[0];
    const quantization_value = style & 0x1f;
    if (quantization_value > @intFromEnum(QuantizationStyle.scalar_expounded)) return CodestreamError.InvalidCodestream;
    const quantization: QuantizationStyle = @enumFromInt(quantization_value);
    const guard_bits = style >> 5;
    if (guard_bits != strict_guard_bits) return CodestreamError.UnsupportedPayload;

    if (transform == .irreversible_9_7) {
        if (quantization == .scalar_derived) {
            if (segment.len != 1 + 2) return CodestreamError.InvalidCodestream;
            var cursor: usize = 1;
            try validateStrictQcdScalarValue(segment, &cursor, bit_depth, .ll, levels);
            return .{ .bands = bands, .quantization = quantization };
        }
        if (quantization != .scalar_expounded) return CodestreamError.UnsupportedPayload;
        if (segment.len != 1 + 2 * bands) return CodestreamError.InvalidCodestream;
        var cursor: usize = 1;
        try validateStrictQcdScalarValue(segment, &cursor, bit_depth, .ll, levels);
        var level: u8 = levels;
        while (level > 0) : (level -= 1) {
            inline for (.{ subband.Kind.hl, subband.Kind.lh, subband.Kind.hh }) |kind| {
                try validateStrictQcdScalarValue(segment, &cursor, bit_depth, kind, level);
            }
        }
        return .{ .bands = bands, .quantization = quantization };
    }

    if (quantization != .none) return CodestreamError.UnsupportedPayload;
    if (segment.len != 1 + bands) return CodestreamError.InvalidCodestream;

    var cursor: usize = 1;
    if (segment[cursor] != try qcdReversibleExponentByteForBand(bit_depth, .ll)) {
        return CodestreamError.UnsupportedPayload;
    }
    cursor += 1;
    var level: u8 = 0;
    while (level < levels) : (level += 1) {
        inline for (.{ subband.Kind.hl, subband.Kind.lh, subband.Kind.hh }) |kind| {
            if (segment[cursor] != try qcdReversibleExponentByteForBand(bit_depth, kind)) {
                return CodestreamError.UnsupportedPayload;
            }
            cursor += 1;
        }
    }
    return .{ .bands = bands, .quantization = quantization };
}

fn validateStrictQcdScalarValue(
    segment: []const u8,
    cursor: *usize,
    bit_depth: u8,
    kind: subband.Kind,
    band_level: u8,
) !void {
    const step = try irreversibleBandStepSize(bit_depth, kind, band_level);
    const expected = (@as(u16, step.exponent) << 11) | step.mantissa;
    if (readU16Be(segment, cursor.*) != expected) return CodestreamError.UnsupportedPayload;
    cursor.* += 2;
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
            var tile_part = try readStrictTilePartHeader(allocator, bytes, cursor, tile_part_index, &expected_tile_part_count, null);
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
            var tile_part = try readStrictTilePartHeader(allocator, bytes, cursor, tile_part_index, &expected_tile_part_count, null);
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

    var actual = try readStrictSodRpclPacketStream(allocator, bytes);
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

    var actual = try readStrictSodRpclPacketStream(allocator, bytes);
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
    var rpcl_index = try buildRpclBlockIndex(allocator, plan, header.levels, bands, blocks);
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
    try inverseComponents53(allocator, .{ .y = strict_planes.y, .cb = strict_planes.cb, .cr = strict_planes.cr }, header.width, header.height, header.levels, options);
    var strict_image = if (header.mct == .none)
        try color.inverseNoTransform(allocator, strict_planes)
    else
        try color.inverseRct(allocator, strict_planes);
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

    const assembly_stats = try strictAssemblyStats(assemblies.assemblies);
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
    const plan = temporaryPacketPlan(header);
    const bands = try subband.makeBands(allocator, header.width, header.height, header.levels);
    defer allocator.free(bands);
    const blocks = try subband.makeCodeBlocks(allocator, bands, header.block_width, header.block_height);
    defer allocator.free(blocks);

    var rpcl_index = try buildRpclBlockIndex(allocator, plan, header.levels, bands, blocks);
    defer rpcl_index.deinit();

    var assemblies = try StrictComponentAssemblySet.init(allocator, blocks.len, header.layers == 1);
    errdefer assemblies.deinit();
    inline for (0..3) |component| {
        try initializeStrictAssemblyGeometry(&assemblies.assemblies[component], bands, blocks, header.bit_depth, header.transform, header.quantization, header.code_block_style);
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
        const selected = try rpcl_index.indexesFor(entry.packet.resolution, entry.packet.precinct_index, entry.packet.component);
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
                    bands,
                    blocks,
                    header.block_width,
                    header.block_height,
                    selected,
                    header.layers,
                    header.bit_depth,
                    header.transform,
                    header.quantization,
                    header.code_block_style.bypass,
                    header.code_block_style.terminate_all,
                    &active_group_storage,
                );
            }
        } else if (selected.len > 0 and active_group_count == 0) {
            return CodestreamError.InvalidCodestream;
        }
        const active_groups = active_group_storage[0..active_group_count];

        if (selected.len == 0) {
            const read = try readStrictPacketHeaderForAudit(packet_bytes, entry.packet, &.{}, null, &.{});
            if (read.present or read.included_blocks != 0 or read.payload_length != 0) {
                return CodestreamError.InvalidCodestream;
            }
            audit.geometry_empty_packets += 1;
            audit.absent_packets += 1;
            audit.header_decoded_packets += 1;
            audit.header_bytes += read.header_length;
            continue;
        }

        const read = try readStrictPacketHeaderForAudit(
            packet_bytes,
            entry.packet,
            active_groups,
            &assemblies.assemblies[entry.packet.component],
            blocks,
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
        if (groups.len == 0) return CodestreamError.InvalidCodestream;
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
    bit_depth: u8,
    transform: WaveletTransform,
    quantization: QuantizationStyle,
    code_block_style: ebcot.CodeBlockStyle,
) !void {
    if (assembly.blocks.len != source_blocks.len) return CodestreamError.InvalidCodestream;
    for (assembly.blocks, source_blocks) |*block, source| {
        if (source.band_index >= bands.len) return CodestreamError.InvalidCodestream;
        block.band_index = source.band_index;
        block.rect = source.rect;
        block.nominal_bitplanes = try bandNominalBitplanesForTransform(
            bit_depth,
            bands[source.band_index].kind,
            bands[source.band_index].level,
            transform,
            strict_guard_bits,
            quantization,
            dwtLevelsFromBands(bands),
        );
        block.encoded_bitplanes = 0;
        block.code_block_style = codeBlockStyleForBand(code_block_style, bands[source.band_index].kind);
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

fn strictAssemblyStats(assemblies: [3]StrictComponentAssembly) !StrictAssemblyStats {
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
    assemblies: *[3]StrictComponentAssembly,
) !StrictPacketBlockCatalog {
    const build = try strictPacketBlockCatalogFromAssembliesChecked(allocator, assemblies);
    return build.catalog;
}

fn strictPacketBlockCatalogFromAssembliesChecked(
    allocator: std.mem.Allocator,
    assemblies: *[3]StrictComponentAssembly,
) !StrictPacketBlockCatalogBuild {
    var catalog = StrictPacketBlockCatalog{ .allocator = allocator };
    errdefer catalog.deinit();
    var stats = StrictAssemblyStats{};

    inline for (0..3) |component| {
        const assembly = &assemblies[component];
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
    block_width: u16,
    block_height: u16,
    selected: []const usize,
    layer_count: u16,
    bit_depth: u8,
    transform: WaveletTransform,
    quantization: QuantizationStyle,
    bypass: bool,
    terminate_all: bool,
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
            block_width,
            block_height,
            selected[cursor..end],
            band_index,
            layer_count,
            bit_depth,
            transform,
            quantization,
            dwtLevelsFromBands(bands),
            bypass,
            terminate_all,
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
    block_width: u16,
    block_height: u16,
    selected: []const usize,
    band_index: usize,
    layer_count: u16,
    bit_depth: u8,
    transform: WaveletTransform,
    quantization: QuantizationStyle,
    levels: u8,
    bypass: bool,
    terminate_all: bool,
) !StrictPacketAuditBandGroup {
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

    var reader_state = try t2.PrecinctPacketReaderState.initWithLayerCount(allocator, leaves_x, leaves_y, leaf_count, layer_count);
    errdefer reader_state.deinit();
    reader_state.bypass = bypass;
    reader_state.terminate_all = terminate_all;
    const decoded = try allocator.alloc(t2.DecodedPacketBlock, leaf_count);
    errdefer allocator.free(decoded);

    return .{
        .source_indexes = source_indexes,
        .locations = locations,
        .reader_state = reader_state,
        .decoded = decoded,
        .max_zero_bitplanes = try bandNominalBitplanesForTransform(bit_depth, band.kind, band.level, transform, strict_guard_bits, quantization, levels),
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
    const y = try reconstructStrictComponentCoefficients(
        allocator,
        header.width,
        header.height,
        catalogs[0].blocks,
        assemblies[0],
        header.layers,
        options,
    );
    errdefer allocator.free(y);
    const cb = try reconstructStrictComponentCoefficients(
        allocator,
        header.width,
        header.height,
        catalogs[1].blocks,
        assemblies[1],
        header.layers,
        options,
    );
    errdefer allocator.free(cb);
    const cr = try reconstructStrictComponentCoefficients(
        allocator,
        header.width,
        header.height,
        catalogs[2].blocks,
        assemblies[2],
        header.layers,
        options,
    );
    errdefer allocator.free(cr);

    return .{
        .allocator = allocator,
        .width = header.width,
        .height = header.height,
        .bit_depth = header.bit_depth,
        .y = y,
        .cb = cb,
        .cr = cr,
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
        return decodeIrreversibleImageFromQuantizedPlanesMeasured(allocator, header, strict_planes, timings);
    }

    const wavelet_start = monotonicNs();
    try inverseComponents53(allocator, .{ .y = strict_planes.y, .cb = strict_planes.cb, .cr = strict_planes.cr }, header.width, header.height, header.levels, options);
    if (timings) |t| t.wavelet_ns += elapsedNs(wavelet_start);

    const color_start = monotonicNs();
    defer {
        if (timings) |t| t.color_transform_ns += elapsedNs(color_start);
    }
    return if (header.mct == .none)
        color.inverseNoTransform(allocator, strict_planes)
    else
        color.inverseRct(allocator, strict_planes);
}

/// Builds a per-tile packet catalog from one Stage B tile-part span: the
/// tile's PLT packet lengths drive the tile-local RPCL iterator, and each
/// framed packet (SOP/EPH per the COD policy, Nsop restarting at 0 for the
/// tile) is stripped into the catalog's raw packet bytes.
fn readStrictMultiTileTilePartPacketCatalog(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    span: StrictMultiTileTilePartSpan,
    tile_plan: packet_plan.Plan,
    layers: u16,
    marker_policy: MainHeaderPacketMarkers,
) !StrictPacketCatalog {
    var entries: std.ArrayList(StrictPacketEntry) = .empty;
    errdefer entries.deinit(allocator);
    const packet_capacity = std.math.cast(usize, tile_plan.packets) orelse return CodestreamError.InvalidCodestream;
    try entries.ensureTotalCapacity(allocator, packet_capacity);
    var packet_bytes: std.ArrayList(u8) = .empty;
    errdefer packet_bytes.deinit(allocator);
    try packet_bytes.ensureTotalCapacity(allocator, span.packet_payload_bytes);

    var packet_lengths: std.ArrayList(usize) = .empty;
    defer packet_lengths.deinit(allocator);
    const sod = try readTilePartHeaderMarkers(allocator, bytes, span.sot_start + 12, span.end, &packet_lengths);
    if (sod != span.sod) return CodestreamError.InvalidCodestream;
    if (packet_lengths.items.len != packet_capacity) return CodestreamError.InvalidCodestream;

    var iterator = try packet_plan.RpclIterator.init(tile_plan, 3, layers);
    var cursor = span.sod + 2;
    var packet_sequence: u16 = 0;
    for (packet_lengths.items) |packet_length| {
        const packet = iterator.next() orelse return CodestreamError.InvalidCodestream;
        const byte_offset = packet_bytes.items.len;
        const byte_length = try appendStrictSodPacketPayload(
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
            .tile_part_index = 0,
            .byte_offset = byte_offset,
            .byte_length = byte_length,
        });
    }
    if (iterator.next() != null) return CodestreamError.InvalidCodestream;
    if (cursor != span.end) return CodestreamError.InvalidCodestream;

    const owned_entries = try entries.toOwnedSlice(allocator);
    errdefer allocator.free(owned_entries);
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

    fn deinit(self: *StrictMultiTileContext) void {
        self.spans.deinit(self.allocator);
        self.main_header.deinit();
        self.* = undefined;
    }

    /// The per-tile header view that lets the unchanged single-tile strict
    /// chain decode one tile: tile dims plus the tile's own packet plan.
    fn tileHeader(self: StrictMultiTileContext, header: TemporaryHeader, tile: tile_grid.Tile) !TemporaryHeader {
        const tile_width = @as(usize, tile.rect.width());
        const tile_height = @as(usize, tile.rect.height());
        const tile_plan = try makePacketPlan(tile_width, tile_height, header.levels, self.plan_options);
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
    const grid = tile_grid.Grid.fromImageSize(header.width, header.height, header.tile_width, header.tile_height) catch return CodestreamError.InvalidCodestream;
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
    };

    var main_header = try readStrictMainHeaderIndex(allocator, bytes);
    errdefer main_header.deinit();

    const spans = try readStrictMultiTileTilePartSpans(
        allocator,
        bytes,
        main_header.first_sot,
        grid,
        header.levels,
        plan_options,
        if (main_header.tlm_entries) |tlm_slice| tlm_slice else null,
    );

    return .{
        .allocator = allocator,
        .grid = grid,
        .plan_options = plan_options,
        .main_header = main_header,
        .spans = spans,
    };
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

    for (context.spans.items) |span| {
        const tile = context.grid.tile(span.tile_index) catch return CodestreamError.InvalidCodestream;
        const tile_header = try context.tileHeader(header, tile);

        const catalog_start = monotonicNs();
        var catalog = try readStrictMultiTileTilePartPacketCatalog(
            allocator,
            bytes,
            span,
            temporaryPacketPlan(tile_header),
            header.layers,
            context.main_header.packet_markers,
        );
        defer catalog.deinit();

        var audit = StrictPacketHeaderAudit{};
        var assemblies = try assembleStrictPacketCatalogHeaders(allocator, tile_header, catalog, &audit);
        defer assemblies.deinit();
        const build = try strictPacketBlockCatalogFromAssembliesChecked(allocator, &assemblies.assemblies);
        var block_catalog = build.catalog;
        defer block_catalog.deinit();
        if (build.stats.bytes != audit.payload_bytes) return CodestreamError.InvalidCodestream;
        if (timings) |t| t.packet_catalog_ns += elapsedNs(catalog_start);

        var tile_image = try decodeStrictRpclImageFromBlockCatalogMeasured(allocator, tile_header, block_catalog, options, timings);
        defer tile_image.deinit();
        tile_grid.copyRgbTileInto(assembled, tile.rect, tile_image) catch return CodestreamError.InvalidCodestream;
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
    for (context.spans.items) |span| {
        const tile = context.grid.tile(span.tile_index) catch return CodestreamError.InvalidCodestream;
        const tile_header = try context.tileHeader(header, tile);
        var catalog = try readStrictMultiTileTilePartPacketCatalog(
            allocator,
            bytes,
            span,
            temporaryPacketPlan(tile_header),
            header.layers,
            context.main_header.packet_markers,
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
    return decodeIrreversibleImageFromQuantizedPlanesMeasured(allocator, header, quantized, null);
}

fn decodeIrreversibleImageFromQuantizedPlanesMeasured(
    allocator: std.mem.Allocator,
    header: TemporaryHeader,
    quantized: color.RctPlanes,
    timings: ?*DecodeTimings,
) !image.RgbImage {
    const pixels = try std.math.mul(usize, header.width, header.height);
    if (quantized.y.len != pixels or quantized.cb.len != pixels or quantized.cr.len != pixels) {
        return CodestreamError.InvalidCodestream;
    }

    const bands = try subband.makeBands(allocator, header.width, header.height, header.levels);
    defer allocator.free(bands);

    const y_f = try allocator.alloc(f32, pixels);
    defer allocator.free(y_f);
    const cb_f = try allocator.alloc(f32, pixels);
    defer allocator.free(cb_f);
    const cr_f = try allocator.alloc(f32, pixels);
    defer allocator.free(cr_f);

    const wavelet_start = monotonicNs();
    for (bands) |band| {
        const delta = irreversibleBandDelta(
            header.bit_depth,
            band.kind,
            try irreversibleBandStepSizeFor(header.quantization, header.bit_depth, band.kind, band.level, header.levels),
        );
        dequantizeBandRegion(quantized.y, y_f, header.width, band.rect, delta);
        dequantizeBandRegion(quantized.cb, cb_f, header.width, band.rect, delta);
        dequantizeBandRegion(quantized.cr, cr_f, header.width, band.rect, delta);
    }

    inline for (.{ y_f, cb_f, cr_f }) |plane| {
        try wavelet.inverse2D(allocator, plane, header.width, header.height, header.levels, .irreversible_9_7);
    }
    if (timings) |t| t.wavelet_ns += elapsedNs(wavelet_start);

    const ict = color.IctPlanes{
        .allocator = allocator,
        .width = header.width,
        .height = header.height,
        .bit_depth = header.bit_depth,
        .y = y_f,
        .cb = cb_f,
        .cr = cr_f,
    };
    const color_start = monotonicNs();
    defer {
        if (timings) |t| t.color_transform_ns += elapsedNs(color_start);
    }
    return color.inverseIct(allocator, ict);
}

const StrictComponentDecodeJob = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    catalog: *const StrictPacketBlockCatalog,
    component: usize,
    options: DecodeOptions,
    plane: []i32,
    collect_t1_stats: bool = false,
    t1_stats: ebcot.DecodePassStats = .{},
    result: anyerror!void = {},
};

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

fn strictComponentDecodeWorker(job: *StrictComponentDecodeJob) void {
    fillStrictComponentCoefficientsFromBlockCatalog(
        job.allocator,
        job.width,
        job.height,
        job.catalog.*,
        job.component,
        job.options,
        job.plane,
        if (job.collect_t1_stats) &job.t1_stats else null,
        null,
    ) catch |err| {
        job.result = err;
        return;
    };
    job.result = {};
}

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
    if (options.threads <= 3 and componentThreadCountFor(options.threads) >= 2) {
        const pixels = try std.math.mul(usize, header.width, header.height);
        const y = try allocator.alloc(i32, pixels);
        errdefer allocator.free(y);
        const cb = try allocator.alloc(i32, pixels);
        errdefer allocator.free(cb);
        const cr = try allocator.alloc(i32, pixels);
        errdefer allocator.free(cr);
        const targets = [3][]i32{ y, cb, cr };

        var jobs: [3]StrictComponentDecodeJob = undefined;
        for (&jobs, 0..) |*job, component| {
            job.* = .{
                .allocator = std.heap.smp_allocator,
                .width = header.width,
                .height = header.height,
                .catalog = &catalog,
                .component = component,
                .options = options,
                .plane = targets[component],
                .collect_t1_stats = timings != null,
            };
        }
        try runComponentJobs(StrictComponentDecodeJob, &jobs, componentThreadCountFor(options.threads), strictComponentDecodeWorker);
        if (timings) |t| {
            const stats = &t.t1_pass_stats;
            for (jobs) |job| stats.merge(job.t1_stats);
        }

        return .{
            .allocator = allocator,
            .width = header.width,
            .height = header.height,
            .bit_depth = header.bit_depth,
            .y = y,
            .cb = cb,
            .cr = cr,
        };
    }

    const y = try reconstructStrictComponentCoefficientsFromBlockCatalog(
        allocator,
        header.width,
        header.height,
        catalog,
        0,
        options,
        timings,
    );
    errdefer allocator.free(y);
    const cb = try reconstructStrictComponentCoefficientsFromBlockCatalog(
        allocator,
        header.width,
        header.height,
        catalog,
        1,
        options,
        timings,
    );
    errdefer allocator.free(cb);
    const cr = try reconstructStrictComponentCoefficientsFromBlockCatalog(
        allocator,
        header.width,
        header.height,
        catalog,
        2,
        options,
        timings,
    );
    errdefer allocator.free(cr);

    return .{
        .allocator = allocator,
        .width = header.width,
        .height = header.height,
        .bit_depth = header.bit_depth,
        .y = y,
        .cb = cb,
        .cr = cr,
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
    if (component >= 3) return CodestreamError.InvalidCodestream;
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
    if (component >= 3) return CodestreamError.InvalidCodestream;
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
    if (options.threads <= 3 or block_count < 2) return 1;
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

fn readStrictSodRpclPacketStream(allocator: std.mem.Allocator, bytes: []const u8) !RpclPacketStream {
    if (bytes.len < 4 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    var lengths: std.ArrayList(u32) = .empty;
    errdefer lengths.deinit(allocator);
    var packet_bytes: std.ArrayList(u8) = .empty;
    errdefer packet_bytes.deinit(allocator);

    var main_header = try readStrictMainHeaderIndex(allocator, bytes);
    defer main_header.deinit();
    var cursor = main_header.first_sot;
    var packet_sequence: u16 = 0;
    var tile_part_index: usize = 0;
    var expected_tile_part_count: ?u8 = null;
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
            var tile_part = try readStrictTilePartHeader(allocator, bytes, cursor, tile_part_index, &expected_tile_part_count, entries);
            defer tile_part.deinit(allocator);
            if (tile_part.packet_lengths.items.len == 0) return CodestreamError.UnsupportedPayload;
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
    layers: u16,
) ![]packet_plan.Packet {
    switch (progression) {
        .rpcl, .lrcp, .rlcp => {
            const total = std.math.cast(usize, plan.packets) orelse return CodestreamError.InvalidCodestream;
            const packets = try allocator.alloc(packet_plan.Packet, total);
            errdefer allocator.free(packets);
            var iterator = try StreamPacketIterator.init(progression, plan, 3, layers);
            var count: usize = 0;
            while (iterator.next()) |packet| {
                if (count >= total) return CodestreamError.InvalidCodestream;
                packets[count] = packet;
                count += 1;
            }
            if (count != total) return CodestreamError.InvalidCodestream;
            return packets;
        },
        .pcrl => return packet_plan.positionOrderedPackets(allocator, plan, 3, layers, .pcrl) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => CodestreamError.InvalidCodestream,
        },
        .cprl => return packet_plan.positionOrderedPackets(allocator, plan, 3, layers, .cprl) catch |err| switch (err) {
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
    layers: u16,
) !void {
    const scratch = try allocator.alloc(StrictPacketEntry, entries.len);
    defer allocator.free(scratch);
    const seen = try allocator.alloc(bool, entries.len);
    defer allocator.free(seen);
    @memset(seen, false);
    for (entries) |entry| {
        const sequence = packet_plan.rpclSequenceForPacket(plan, 3, layers, entry.packet) catch
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

fn readStrictSodPacketCatalog(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    plan: packet_plan.Plan,
    layers: u16,
    progression: ProgressionOrder,
) !StrictPacketCatalog {
    if (bytes.len < 4 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    var entries: std.ArrayList(StrictPacketEntry) = .empty;
    errdefer entries.deinit(allocator);
    const packet_capacity = std.math.cast(usize, plan.packets) orelse return CodestreamError.InvalidCodestream;
    try entries.ensureTotalCapacity(allocator, packet_capacity);
    var packet_bytes: std.ArrayList(u8) = .empty;
    errdefer packet_bytes.deinit(allocator);

    const sequence = try buildStreamPacketSequence(allocator, progression, plan, layers);
    defer allocator.free(sequence);
    var sequence_index: usize = 0;
    var main_header = try readStrictMainHeaderIndex(allocator, bytes);
    defer main_header.deinit();
    var cursor = main_header.first_sot;
    var packet_sequence: u16 = 0;
    var tile_part_index: usize = 0;
    var expected_tile_part_count: ?u8 = null;
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
            if (@as(u64, @intCast(entries.items.len)) != plan.packets) return CodestreamError.InvalidCodestream;

            const owned_entries = try entries.toOwnedSlice(allocator);
            errdefer allocator.free(owned_entries);
            if (progression != .rpcl) {
                try reorderStrictEntriesToRpcl(allocator, owned_entries, plan, layers);
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
            var tile_part = try readStrictTilePartHeader(allocator, bytes, cursor, tile_part_index, &expected_tile_part_count, tlm_entries);
            defer tile_part.deinit(allocator);
            if (tile_part.packet_lengths.items.len == 0) return CodestreamError.UnsupportedPayload;
            cursor = tile_part.sod + 2;
            try packet_bytes.ensureTotalCapacity(allocator, try std.math.add(usize, packet_bytes.items.len, tile_part.packet_payload_bytes));
            for (tile_part.packet_lengths.items) |packet_length| {
                if (sequence_index >= sequence.len) return CodestreamError.InvalidCodestream;
                const packet = sequence[sequence_index];
                sequence_index += 1;
                const byte_offset = packet_bytes.items.len;
                const byte_length = try appendStrictSodPacketPayload(
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
            if (cursor != tile_part.end) return CodestreamError.InvalidCodestream;
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
) !StrictTilePartPacketPlan {
    var result = StrictTilePartPacketPlan{};
    var expected_tile_part_count: ?u8 = null;
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
            return result;
        }
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;
        if (result.count == result.packet_counts.len) return CodestreamError.InvalidCodestream;

        {
            var tile_part = try readStrictTilePartHeader(allocator, bytes, scan, result.count, &expected_tile_part_count, tlm_entries);
            defer tile_part.deinit(allocator);
            if (tile_part.packet_lengths.items.len == 0) return CodestreamError.UnsupportedPayload;
            result.packet_counts[result.count] = tile_part.packet_lengths.items.len;
            result.count += 1;
            scan = tile_part.end;
        }
    }

    return CodestreamError.InvalidCodestream;
}

/// One tile-part of a multi-tile stream, located by the Stage B SOT walk
/// (docs/multi_tile_plan.md): byte spans for the SOT segment, the packet
/// payload behind SOD, and the PLT-counted packet count validated against the
/// tile's own packet plan. Stage C consumes these spans for per-tile decode.
const StrictMultiTileTilePartSpan = struct {
    tile_index: u16,
    sot_start: usize,
    sod: usize,
    end: usize,
    packet_payload_bytes: usize,
    packet_count: usize,
};

/// Walks the tile-part sequence of a multi-tile stream and enforces the v1
/// discipline: exactly one tile-part per tile in row-major order (Isot counts
/// up from 0, TPsot = 0, TNsot = 1), Psot chaining ending exactly at EOC,
/// PLT present, per-tile packet counts matching the tile's own packet plan,
/// and TLM entries (when present) matching Isot/Psot per tile. Streams that
/// are legal ISO but outside the v1 discipline (reordered tiles, multiple
/// parts per tile) fail closed as UnsupportedPayload; structural damage is
/// InvalidCodestream/TruncatedData.
fn readStrictMultiTileTilePartSpans(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    first_sot: usize,
    grid: tile_grid.Grid,
    levels: u8,
    options: LosslessOptions,
    tlm_entries: ?[]const TlmEntry,
) !std.ArrayList(StrictMultiTileTilePartSpan) {
    const tile_count = grid.tileCount();
    if (tile_count > std.math.maxInt(u16)) return CodestreamError.UnsupportedPayload;

    var spans: std.ArrayList(StrictMultiTileTilePartSpan) = .empty;
    errdefer spans.deinit(allocator);

    var scan = first_sot;
    var tile_index: u64 = 0;
    while (scan < bytes.len) {
        if (bytes.len - scan < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, scan);
        if (marker == @intFromEnum(Marker.eoc)) {
            scan += 2;
            if (scan != bytes.len) return CodestreamError.InvalidCodestream;
            if (tile_index != tile_count) return CodestreamError.InvalidCodestream;
            if (tlm_entries) |entries| {
                if (entries.len != tile_count) return CodestreamError.InvalidCodestream;
            }
            return spans;
        }
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;
        if (tile_index >= tile_count) return CodestreamError.InvalidCodestream;

        const sot = try readStrictSotInfo(bytes, scan);
        // TLM cross-check first: a SOT that contradicts the stream's own index
        // is corruption (InvalidCodestream); a self-consistent stream that is
        // merely outside the v1 row-major discipline fails closed below as
        // UnsupportedPayload.
        if (tlm_entries) |entries| {
            try validateStrictTlmEntry(entries, @intCast(tile_index), sot.tile_index, sot.psot);
        }
        if (sot.tile_index != tile_index) return CodestreamError.UnsupportedPayload;
        if (sot.tile_part_index != 0 or sot.tile_part_count != 1) return CodestreamError.UnsupportedPayload;

        const tile_part_end = try std.math.add(usize, scan, sot.psot);
        if (tile_part_end > bytes.len or tile_part_end < scan + 12) {
            return CodestreamError.TruncatedData;
        }

        var packet_lengths: std.ArrayList(usize) = .empty;
        defer packet_lengths.deinit(allocator);
        const sod = try readTilePartHeaderMarkers(allocator, bytes, scan + 12, tile_part_end, &packet_lengths);
        const packet_payload_bytes = try validateStrictTilePartPacketSpan(sod, tile_part_end, packet_lengths.items);
        if (packet_lengths.items.len == 0) return CodestreamError.UnsupportedPayload;

        const tile = grid.tile(tile_index) catch return CodestreamError.InvalidCodestream;
        const tile_plan = try makePacketPlan(
            @as(usize, tile.rect.width()),
            @as(usize, tile.rect.height()),
            levels,
            options,
        );
        if (@as(u64, @intCast(packet_lengths.items.len)) != tile_plan.packets) {
            return CodestreamError.InvalidCodestream;
        }

        try spans.append(allocator, .{
            .tile_index = sot.tile_index,
            .sot_start = scan,
            .sod = sod,
            .end = tile_part_end,
            .packet_payload_bytes = packet_payload_bytes,
            .packet_count = packet_lengths.items.len,
        });
        tile_index += 1;
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
    const sod = try readTilePartHeaderMarkers(allocator, bytes, marker_start + 12, tile_part_end, &packet_lengths);
    const packet_payload_bytes = try validateStrictTilePartPacketSpan(sod, tile_part_end, packet_lengths.items);

    return .{
        .sot = sot,
        .sod = sod,
        .end = tile_part_end,
        .packet_payload_bytes = packet_payload_bytes,
        .packet_lengths = packet_lengths,
    };
}

fn validateStrictTilePartPacketSpan(sod: usize, tile_part_end: usize, packet_lengths: []const usize) !usize {
    if (packet_lengths.len == 0) return 0;
    const payload_start = try std.math.add(usize, sod, 2);
    if (payload_start > tile_part_end) return CodestreamError.TruncatedData;

    var payload_bytes: usize = 0;
    for (packet_lengths) |packet_length| {
        if (packet_length == 0) return CodestreamError.InvalidCodestream;
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

fn readStrictMainHeaderIndex(allocator: std.mem.Allocator, bytes: []const u8) !StrictMainHeaderIndex {
    if (bytes.len < 4 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    var entries: std.ArrayList(TlmEntry) = .empty;
    errdefer entries.deinit(allocator);
    var saw_tlm = false;
    var next_tlm_index: usize = 0;
    var packet_markers: ?MainHeaderPacketMarkers = null;

    var cursor: usize = 2;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 4) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        cursor += 2;
        if (marker == @intFromEnum(Marker.sot)) {
            const markers = packet_markers orelse return CodestreamError.InvalidCodestream;
            const owned_entries = if (saw_tlm) try entries.toOwnedSlice(allocator) else null;
            return .{
                .allocator = allocator,
                .first_sot = cursor - 2,
                .packet_markers = markers,
                .tlm_entries = owned_entries,
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
            if (packet_markers != null or segment.len < 1) return CodestreamError.InvalidCodestream;
            packet_markers = .{
                .sop = (segment[0] & 0x02) != 0,
                .eph = (segment[0] & 0x04) != 0,
            };
        } else if (marker == @intFromEnum(Marker.tlm)) {
            try appendStrictTlmEntries(allocator, &entries, segment, next_tlm_index);
            saw_tlm = true;
            next_tlm_index += 1;
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
    bit_depth: u8,
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
) !usize {
    var cursor = start;
    var expected_plt_index: u8 = 0;
    while (cursor + 1 < end) {
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(Marker.sod)) return cursor;
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
        } else if (marker == @intFromEnum(Marker.com)) {
            // Tile-part comments are metadata only and do not affect packet spans.
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
    psot: u32,
    tile_part_index: u8,
    tile_part_count: u8,
) !void {
    try appendMarker(allocator, out, .sot);
    try appendU16Be(allocator, out, 10);
    try appendU16Be(allocator, out, 0);
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

    var catalogs = try buildComponentRpclShadowCatalogs(allocator, planes, bands, blocks, options, options.emit_temporary_payload_sidecar);
    defer {
        for (&catalogs) |*catalog| catalog.deinit();
    }

    // Rate-targeted layers get a global PCRD allocation over the finished
    // block catalogs, replacing the per-block proportional split the
    // catalog builder installed.
    if (options.rate_count > 0 and options.layers > 1) {
        try applyPcrdLayerAllocation(allocator, &catalogs, planes, bands, blocks, options);
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
    var rpcl_index = try buildRpclBlockIndex(allocator, plan, levels, bands, blocks);
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
    levels: u8,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
) !RpclBlockIndex {
    var index = try RpclBlockIndex.init(allocator, plan);
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
            while (component < 3) : (component += 1) {
                const cell = try index.cell(resolution_index, precinct_index, component);
                try cell.indexes.appendSlice(allocator, selected);
            }
        }
    }

    return index;
}

/// Global PCRD (ISO 15444-1 J.14) layer allocation across every code block
/// of the three components. Exact per-pass distortion comes from the
/// symbol-based reference coder, band-weighted into image-domain units,
/// then rate_alloc picks a global slope threshold per layer byte target and
/// each catalog block's layer truncations are rewritten in place (BYPASS
/// segment snapping preserved via normalizedLayerTruncation). Runs
/// single-threaded after the parallel block encode, so the allocation is
/// independent of the encode thread count.
fn applyPcrdLayerAllocation(
    allocator: std.mem.Allocator,
    catalogs: *[3]ComponentRpclShadowCatalog,
    planes: color.RctPlanes,
    bands: []const subband.Band,
    blocks: []const subband.CodeBlock,
    options: LosslessOptions,
) !void {
    const layer_count: usize = options.layers;
    const levels = dwtLevelsFromBands(bands);
    const total_blocks = blocks.len * 3;
    const component_planes = [3][]const i32{ planes.y, planes.cb, planes.cr };

    const base_style = ebcot.CodeBlockStyle{
        .bypass = options.bypass,
        .reset_context = options.reset_context,
        .terminate_all = options.terminate_all,
        .vertical_causal = options.vertical_causal,
        .predictable_termination = options.predictable_termination,
        .segmentation_symbols = options.segmentation_symbols,
    };

    var scratch = ebcot.BlockScratch.init(allocator);
    defer scratch.deinit();

    const Span = struct { start: usize, count: usize };
    var pass_bytes_storage: std.ArrayList(u64) = .empty;
    defer pass_bytes_storage.deinit(allocator);
    var distortion_storage: std.ArrayList(f64) = .empty;
    defer distortion_storage.deinit(allocator);
    const spans = try allocator.alloc(Span, total_blocks);
    defer allocator.free(spans);

    var distortion_scratch: [164]f64 = undefined;
    var total_full_bytes: u64 = 0;
    for (0..3) |component| {
        for (blocks, 0..) |block, block_index| {
            if (block.band_index >= bands.len) return CodestreamError.InvalidCodestream;
            const band = bands[block.band_index];
            const shadow = &catalogs[component].blocks[block_index];
            const segment = shadow.segment;
            total_full_bytes = try std.math.add(u64, total_full_bytes, segment.byte_length);

            const slot = component * blocks.len + block_index;
            spans[slot] = .{ .start = pass_bytes_storage.items.len, .count = segment.pass_count };
            if (segment.pass_count == 0) continue;

            const style = codeBlockStyleForBand(base_style, band.kind);
            const distortion_passes = ebcot.passDistortions(
                &scratch,
                component_planes[component],
                planes.width,
                block.rect,
                style,
                distortion_scratch[0..],
            ) catch return CodestreamError.InvalidCodestream;
            if (distortion_passes != segment.pass_count) return CodestreamError.InvalidCodestream;

            const weight = try pcrdBandWeight(band, options, planes.bit_depth, levels);
            var pass_index: u16 = 0;
            while (pass_index < segment.pass_count) : (pass_index += 1) {
                try pass_bytes_storage.append(allocator, segment.passes[pass_index].cumulative_bytes);
                try distortion_storage.append(allocator, distortion_scratch[pass_index] * weight);
            }
        }
    }

    const pcrd_blocks = try allocator.alloc(rate_alloc.PcrdBlock, total_blocks);
    defer allocator.free(pcrd_blocks);
    for (spans, 0..) |span, slot| {
        pcrd_blocks[slot] = .{
            .pass_bytes = pass_bytes_storage.items[span.start..][0..span.count],
            .pass_distortion = distortion_storage.items[span.start..][0..span.count],
        };
    }

    var targets: [max_quality_layers]u64 = undefined;
    rate_alloc.layerTargetsFromRates(
        targets[0..layer_count],
        total_full_bytes,
        options.rates[0..options.rate_count],
    ) catch return CodestreamError.InvalidCodestream;

    const out_passes = try allocator.alloc(u16, total_blocks * layer_count);
    defer allocator.free(out_passes);
    rate_alloc.allocatePcrdPasses(allocator, pcrd_blocks, targets[0..layer_count], out_passes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return CodestreamError.InvalidCodestream,
    };

    for (0..3) |component| {
        for (blocks, 0..) |_, block_index| {
            const slot = component * blocks.len + block_index;
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
        catalogs[0] = try buildComponentRpclShadowCatalog(allocator, planes.y, planes.width, bands, blocks, planes.bit_depth, options, include_bitplane_payload);
        initialized += 1;
        catalogs[1] = try buildComponentRpclShadowCatalog(allocator, planes.cb, planes.width, bands, blocks, planes.bit_depth, options, include_bitplane_payload);
        initialized += 1;
        catalogs[2] = try buildComponentRpclShadowCatalog(allocator, planes.cr, planes.width, bands, blocks, planes.bit_depth, options, include_bitplane_payload);
        return catalogs;
    }

    var jobs = [_]ComponentCatalogJob{
        .{ .plane = planes.y, .stride = planes.width, .bands = bands, .blocks = blocks, .nominal_bitplanes = planes.bit_depth, .options = options, .include_bitplane_payload = include_bitplane_payload },
        .{ .plane = planes.cb, .stride = planes.width, .bands = bands, .blocks = blocks, .nominal_bitplanes = planes.bit_depth, .options = options, .include_bitplane_payload = include_bitplane_payload },
        .{ .plane = planes.cr, .stride = planes.width, .bands = bands, .blocks = blocks, .nominal_bitplanes = planes.bit_depth, .options = options, .include_bitplane_payload = include_bitplane_payload },
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
            .planes = .{ planes.y, planes.cb, planes.cr },
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
        else
            try ebcot.encodeCodeBlockSegmentDirectIsoScratchWithStyle(ebcot_scratch, plane, stride, rect, block_style),
    };
    errdefer segment.deinit(allocator);

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
            break :blk if (style.bypass)
                ebcot.encodeBlockSymbolsSegmentIsoMqBypass(allocator, view, style)
            else
                ebcot.encodeBlockSymbolsSegmentIsoMqContinuous(allocator, view);
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
        3,
        options.layers,
        precincts[0..options.precinct_count],
    );
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

    const sequence = try buildStreamPacketSequence(allocator, options.progression, plan, options.layers);
    defer allocator.free(sequence);
    if (sequence.len != packet_count) return CodestreamError.InvalidCodestream;
    var out_offset: usize = 0;
    for (sequence, 0..) |packet, out_index| {
        const source_sequence = packet_plan.rpclSequenceForPacket(plan, 3, options.layers, packet) catch
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

/// Multi-tile v1 constraints (docs/multi_tile_plan.md §3): the tile pipeline
/// currently covers reversible 5/3 + RCT, a single quality layer, the plain
/// code-block style, and one tile-part per tile in row-major order. Everything
/// outside that fails closed so the COD/SIZ markers never advertise behavior
/// the tile encoder does not implement.
fn validateMultiTileCodingPath(options: LosslessOptions) !void {
    if (options.progression != .rpcl) return CodestreamError.UnsupportedPayload;
    if (options.transform != .reversible_5_3) return CodestreamError.UnsupportedPayload;
    if (options.mct != .rct) return CodestreamError.UnsupportedPayload;
    if (options.layers != 1 or options.rate_count != 0) return CodestreamError.UnsupportedPayload;
    if (options.t1_backend != .iso_mq) return CodestreamError.UnsupportedPayload;
    if (options.bypass or options.reset_context or options.terminate_all or
        options.vertical_causal or options.predictable_termination or
        options.segmentation_symbols)
    {
        return CodestreamError.UnsupportedPayload;
    }
    if (options.emit_temporary_payload_sidecar) return CodestreamError.UnsupportedPayload;
}

/// Multi-tile v1 conformance guards (docs/multi_tile_plan.md §2.3 and risk #2):
///
/// (a) COD's NL is global, so every tile must achieve exactly the image-level
/// decomposition count — tiles small enough to clamp are rejected.
///
/// (b) The tile pipeline anchors precinct and code-block partitions at the
/// tile-local origin, while ISO B.6/B.7 anchor them to the reference grid.
/// Both derivations coincide when every tile origin lands on a partition
/// boundary at every resolution. With XTOSiz = 0 and power-of-two precincts,
/// a sufficient condition (expects `options` pre-normalized so the precinct
/// list covers all resolutions): every precinct is at least the code-block
/// size, and XTSiz/YTSiz are multiples of 2^levels x the largest precinct —
/// then tile origins are multiples of every partition step at every
/// resolution. Misaligned grids fail closed until reference-grid anchoring
/// is implemented.
fn validateMultiTileGeometry(grid: tile_grid.Grid, levels: u8, options: LosslessOptions) !void {
    var max_precinct_width: u32 = 1;
    var max_precinct_height: u32 = 1;
    for (options.precincts[0..options.precinct_count], 0..) |precinct, resolution| {
        // ISO 15444-1 B.7: the effective code-block size is bounded by the
        // precinct span in band coordinates — the full precinct at resolution
        // 0, half of it at higher resolutions. Code blocks that would cross
        // precinct boundaries make the packet/block index derivation ambiguous,
        // so such configurations fail closed in the multi-tile v1 envelope.
        const band_span_width = if (resolution == 0) precinct.width else precinct.width / 2;
        const band_span_height = if (resolution == 0) precinct.height else precinct.height / 2;
        if (band_span_width < options.block_width or band_span_height < options.block_height) {
            return CodestreamError.UnsupportedPayload;
        }
        max_precinct_width = @max(max_precinct_width, precinct.width);
        max_precinct_height = @max(max_precinct_height, precinct.height);
    }
    if (levels > 32) return CodestreamError.UnsupportedPayload;
    const level_scale = @as(u64, 1) << @as(u6, @intCast(levels));
    const x_step = level_scale * max_precinct_width;
    const y_step = level_scale * max_precinct_height;
    if (grid.params.xtsiz % x_step != 0 or grid.params.ytsiz % y_step != 0) {
        return CodestreamError.UnsupportedPayload;
    }

    var iterator = grid.iterator();
    while (iterator.next() catch return CodestreamError.InvalidCodestream) |tile| {
        const tile_width = @as(usize, tile.rect.width());
        const tile_height = @as(usize, tile.rect.height());
        if (actualDwtLevels(tile_width, tile_height, levels) != levels) {
            return CodestreamError.UnsupportedPayload;
        }
    }
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
        },
        .{},
        encode_options.threads,
    );
    defer artifacts.deinit();
    // COD advertises one global NL; the geometry guard above should make
    // per-tile clamping impossible, but verify what the pipeline achieved.
    for (artifacts.tiles) |tile_artifacts| {
        if (tile_artifacts.levels != levels) return CodestreamError.InvalidCodestream;
    }
    if (timings) |t| t.payload_ns = elapsedNs(payload_start);

    const marker_start = monotonicNs();
    // Multi-tile v1 emits exactly one tile-part per tile in row-major order
    // (TPsot = 0, TNsot = 1); resolution tile-part divisions compose with the
    // tile grid in a later slice, so options.tile_part_divisions is ignored.
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
        'R' => {},
        'L', 'C', 'P' => return CodestreamError.UnsupportedPayload,
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
    // vertical_causal (0x08), segmentation_symbols (0x20), and terminate_all
    // (0x04) are wired end-to-end. vertical_causal forms stripe-causal contexts
    // (ISO 15444-1 D.7); segmentation_symbols emits the 0xA UNIFORM-context
    // symbol after each cleanup pass and the decoder validates it (D.5);
    // terminate_all independently terminates the MQ coder on every coding pass
    // (D.4.5), and strict decode consumes the per-pass segments. All three ride
    // through encode + strict decode and stay opt-in behind their CLI flags; the
    // default profile sets none, so the narrow path is unaffected. reset_context
    // and predictable_termination stay fail-closed until their payload is wired.
    if (options.reset_context or
        options.predictable_termination)
    {
        return CodestreamError.UnsupportedPayload;
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
    // BYPASS (0x01), terminate_all (0x04), vertical_causal (0x08), and
    // segmentation_symbols (0x20) are implemented end-to-end; the remaining
    // style bits stay fail-closed until their payload behavior is wired.
    const supported_style_bits: u8 = 0x01 | 0x04 | 0x08 | 0x20;
    if ((parsed.toCodByte() & ~supported_style_bits) != 0) return CodestreamError.UnsupportedPayload;
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
            const weighted = irreversibleBandDelta(bit_depth, band.kind, step) * dwt97Norm(opj_level, orient);
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
