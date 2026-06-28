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
    com = 0xff64,
    tlm = 0xff55,
    plt = 0xff58,
    qcd = 0xff5c,
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
    block_width: u16,
    block_height: u16,
    tile_part_divisions: ?u8,
    tile_part_plan_count: u8,
    tile_part_plan: [33]u8,
    packet_plan_count: u8,
    packet_plan: [33]packet_plan.Resolution,
    packet_count: u64,
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
    threads: u8 = 1,
    emit_temporary_payload_sidecar: bool = false,

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

pub const DecodeOptions = struct {
    threads: u8 = 1,
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
    blocks: []const subband.CodeBlock,
    catalog_blocks: []RpclShadowBlock,
    nominal_bitplanes: u8,
    options: LosslessOptions,
    include_bitplane_payload: bool,
    initialized: usize = 0,
    result: anyerror!void = {},

    fn deinit(self: *ComponentCatalogBlockJob) void {
        for (self.catalog_blocks[0..self.initialized]) |*block| block.deinit(self.allocator);
        self.initialized = 0;
    }

    fn release(self: *ComponentCatalogBlockJob) void {
        self.initialized = 0;
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

const RpclShadowStreamInfo = struct {
    packets: u64 = 0,
    bytes: u64 = 0,
};

const RpclPacketStream = struct {
    allocator: std.mem.Allocator = undefined,
    packet_lengths: []u32 = &.{},
    packet_bytes: []u8 = &.{},

    fn deinit(self: *RpclPacketStream) void {
        if (self.packet_lengths.len > 0) self.allocator.free(self.packet_lengths);
        if (self.packet_bytes.len > 0) self.allocator.free(self.packet_bytes);
        self.* = .{};
    }
};

const TemporaryRpclBlock = struct {
    nominal_bitplanes: u8,
    encoded_bitplanes: u8,
    layers: [max_quality_layers]t2.LayerTruncation,
    payload: []const u8,
};

const TemporaryComponentRpclCatalog = struct {
    allocator: std.mem.Allocator,
    blocks: []TemporaryRpclBlock,

    fn deinit(self: *TemporaryComponentRpclCatalog) void {
        self.allocator.free(self.blocks);
        self.* = undefined;
    }
};

const RpclBlockIndexCell = struct {
    indexes: std.ArrayList(usize) = .empty,
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

    for (job.blocks, 0..) |block, index| {
        job.catalog_blocks[index] = buildRpclShadowBlock(
            job.allocator,
            &bitplane_scratch,
            &ebcot_scratch,
            job.plane,
            job.stride,
            block.rect,
            job.nominal_bitplanes,
            job.options,
            job.include_bitplane_payload,
        ) catch |err| {
            job.result = err;
            return;
        };
        const layer_count: usize = @intCast(job.options.layers);
        job.catalog_blocks[index].encoded.layers = job.catalog_blocks[index].layers[0..layer_count];
        job.initialized += 1;
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
    try validateTileSize(options.tile_width, options.tile_height, rgb.width, rgb.height);
    try validatePrecincts(options);
    try validateTilePartDivisions(options.tile_part_divisions);
    try validateCodingPath(options);
    if (options.layers == 0) return CodestreamError.InvalidCodestream;
    if (options.layers > max_quality_layers) return CodestreamError.InvalidCodestream;
    if (options.rate_count > options.layers) return CodestreamError.InvalidCodestream;
    try validateRates(options);
    if (options.threads == 0) return CodestreamError.InvalidCodestream;

    const color_start = monotonicNs();
    var planes = try color.forwardRct(allocator, rgb);
    defer planes.deinit();
    if (timings) |t| t.color_transform_ns = elapsedNs(color_start);

    const wavelet_start = monotonicNs();
    const levels = try forwardComponents53(allocator, &planes, options);
    if (timings) |t| t.wavelet_ns = elapsedNs(wavelet_start);

    var tile_payload: std.ArrayList(u8) = .empty;
    defer tile_payload.deinit(allocator);
    var rpcl_stream: RpclPacketStream = .{};
    defer rpcl_stream.deinit();
    const payload_start = monotonicNs();
    try appendTemporaryPayload(allocator, &tile_payload, planes, levels, options, &rpcl_stream);
    if (timings) |t| t.payload_ns = elapsedNs(payload_start);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const marker_start = monotonicNs();
    try appendMarker(allocator, &out, .soc);
    try appendSiz(allocator, &out, rgb, options);
    try appendCod(allocator, &out, levels, options);
    try appendQcd(allocator, &out, levels, options);
    if (options.emit_temporary_payload_sidecar) {
        try appendTemporaryPayloadComments(allocator, &out, tile_payload.items);
    }
    const packets = try makePacketPlan(rgb.width, rgb.height, levels, options);
    if (rpcl_stream.packet_lengths.len != packets.packets) return CodestreamError.InvalidCodestream;
    const tile_parts = tilePartCountForOptions(levels, options);
    var psots: [33]u32 = undefined;
    var tile_part_payload_bytes: [33]usize = undefined;
    var tile_part_index: usize = 0;
    while (tile_part_index < tile_parts) : (tile_part_index += 1) {
        const packet_range = tilePartPacketRange(packets, tile_part_index, tile_parts, options);
        const packet_lengths = rpcl_stream.packet_lengths[packet_range.start..][0..packet_range.count];
        tile_part_payload_bytes[tile_part_index] = try rpclPacketPayloadByteCount(options, packet_lengths);
        const plt_bytes = try pltBytesForRpclPacketLengths(options, packet_lengths);
        const tile_part_bytes = try std.math.add(usize, plt_bytes, tile_part_payload_bytes[tile_part_index]);
        psots[tile_part_index] = try std.math.add(u32, 14, @as(u32, @intCast(tile_part_bytes)));
    }

    if (options.tlm) try appendTlm(allocator, &out, psots[0..tile_parts]);
    var packet_sequence: u16 = 0;
    tile_part_index = 0;
    while (tile_part_index < tile_parts) : (tile_part_index += 1) {
        const packet_range = tilePartPacketRange(packets, tile_part_index, tile_parts, options);
        const packet_lengths = rpcl_stream.packet_lengths[packet_range.start..][0..packet_range.count];
        const packet_bytes_start = try rpclPacketByteOffset(rpcl_stream.packet_lengths, packet_range.start);
        const packet_bytes_end = try rpclPacketByteOffset(rpcl_stream.packet_lengths, packet_range.start + packet_range.count);
        try appendSot(allocator, &out, psots[tile_part_index], @intCast(tile_part_index), @intCast(tile_parts));
        try appendPltFromRpclPacketLengths(allocator, &out, options, packet_lengths);
        try appendMarker(allocator, &out, .sod);
        try appendRpclPackets(
            allocator,
            &out,
            options,
            packet_lengths,
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
    const payload = try temporaryPayload(allocator, bytes);
    defer allocator.free(payload);
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

    try inverseComponents53(allocator, .{ .y = y, .cb = cb, .cr = cr }, width, height, levels, options);

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
    const allocator = std.heap.page_allocator;
    if (try temporaryPayloadFromComments(allocator, bytes)) |payload| {
        defer allocator.free(payload);
        try validateStrictRpclPacketsMatchTemporary(allocator, bytes, payload);
        return analyzeTemporaryPayloadBytes(allocator, bytes, payload);
    }
    return analyzeStrictPacketStats(allocator, bytes);
}

fn analyzeTemporaryPayloadBytes(allocator: std.mem.Allocator, codestream_bytes: []const u8, payload: []const u8) !TemporaryStats {
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
    const header = try readStrictCodestreamMetadata(bytes);
    var stream = try readStrictSodRpclPacketStream(allocator, bytes);
    defer stream.deinit();
    if (stream.packet_lengths.len != header.packet_count) return CodestreamError.InvalidCodestream;

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
        .rpcl_shadow_packets = @intCast(stream.packet_lengths.len),
        .rpcl_shadow_bytes = @intCast(stream.packet_bytes.len),
        .payload_bytes = 0,
        .codestream_bytes = bytes.len,
        .components = [_]ComponentStats{.{}} ** 3,
    };
}

fn readStrictCodestreamMetadata(bytes: []const u8) !TemporaryHeader {
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
    var precincts = defaultPrecincts();
    var precinct_count: u8 = 0;
    var saw_siz = false;
    var saw_cod = false;
    var tile_part_count: usize = 0;

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
        if (marker == @intFromEnum(Marker.siz)) {
            if (segment.len < 36) return CodestreamError.InvalidCodestream;
            const xsiz = readU32Be(segment, 2);
            const ysiz = readU32Be(segment, 6);
            const xosiz = readU32Be(segment, 10);
            const yosiz = readU32Be(segment, 14);
            if (xsiz <= xosiz or ysiz <= yosiz) return CodestreamError.InvalidCodestream;
            const components = readU16Be(segment, 34);
            if (components != 3 or segment.len < 36 + @as(usize, components) * 3) return CodestreamError.InvalidCodestream;
            width = xsiz - xosiz;
            height = ysiz - yosiz;
            bit_depth = (segment[36] & 0x7f) + 1;
            saw_siz = true;
        } else if (marker == @intFromEnum(Marker.cod)) {
            if (segment.len < 10) return CodestreamError.InvalidCodestream;
            const scod = segment[0];
            if (segment[1] != @intFromEnum(ProgressionOrder.rpcl)) return CodestreamError.UnsupportedPayload;
            layers = readU16Be(segment, 2);
            levels = segment[5];
            block_width = @as(u16, 1) << @as(u4, @intCast(segment[6] + 2));
            block_height = @as(u16, 1) << @as(u4, @intCast(segment[7] + 2));
            precinct_count = if ((scod & 0x01) != 0) levels + 1 else 0;
            if (precinct_count > precincts.len or segment.len < 10 + @as(usize, precinct_count)) {
                return CodestreamError.InvalidCodestream;
            }
            if (precinct_count > 0) {
                for (segment[10..][0..precinct_count], 0..) |byte, index| {
                    precincts[index] = .{
                        .width = @as(u16, 1) << @as(u4, @intCast(byte & 0x0f)),
                        .height = @as(u16, 1) << @as(u4, @intCast(byte >> 4)),
                    };
                }
            }
            saw_cod = true;
        }
        cursor += segment_length;
    }
    if (!saw_siz or !saw_cod or width == 0 or height == 0 or layers == 0) {
        return CodestreamError.InvalidCodestream;
    }

    var scan = cursor;
    while (scan < bytes.len) {
        if (bytes.len - scan < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, scan);
        if (marker == @intFromEnum(Marker.eoc)) break;
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;
        if (bytes.len - scan < 12) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, scan + 2);
        if (segment_length != 10) return CodestreamError.InvalidCodestream;
        const psot = readU32Be(bytes, scan + 6);
        if (psot == 0) return CodestreamError.UnsupportedPayload;
        const tile_part_end = try std.math.add(usize, scan, psot);
        if (tile_part_end > bytes.len) return CodestreamError.TruncatedData;
        tile_part_count += 1;
        scan = tile_part_end;
    }

    const options = LosslessOptions{
        .levels = levels,
        .layers = layers,
        .block_width = block_width,
        .block_height = block_height,
        .precincts = precincts,
        .precinct_count = if (precinct_count == 0) 1 else precinct_count,
    };
    const plan = try makePacketPlan(width, height, levels, options);
    const tile_part_plan = if (tile_part_count == @as(usize, levels) + 1)
        resolutionTilePartPlan(levels)
    else
        emptyTilePartPlan();

    return .{
        .version = 8,
        .width = width,
        .height = height,
        .bit_depth = bit_depth,
        .levels = levels,
        .layers = layers,
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
    if (bytes.len < 4 or readU16Be(bytes, 0) != @intFromEnum(Marker.soc)) {
        return CodestreamError.InvalidCodestream;
    }

    if (try temporaryPayloadFromComments(allocator, bytes)) |payload| {
        errdefer allocator.free(payload);
        try validateStrictRpclPacketsMatchTemporary(allocator, bytes, payload);
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

    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(Marker.eoc)) {
            cursor += 2;
            if (cursor != bytes.len) return CodestreamError.InvalidCodestream;
            return out.toOwnedSlice(allocator);
        }
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;

        const marker_start = cursor;
        cursor += 2;
        if (bytes.len - cursor < 10) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, cursor);
        if (segment_length != 10) return CodestreamError.InvalidCodestream;
        const psot = readU32Be(bytes, cursor + 4);
        if (psot == 0) return CodestreamError.UnsupportedPayload;
        const tile_part_end = try std.math.add(usize, marker_start, psot);
        if (tile_part_end > bytes.len or tile_part_end < cursor + segment_length + 2) {
            return CodestreamError.TruncatedData;
        }

        cursor += segment_length;
        var packet_lengths: std.ArrayList(usize) = .empty;
        defer packet_lengths.deinit(allocator);
        cursor = try readTilePartHeaderMarkers(allocator, bytes, cursor, tile_part_end, &packet_lengths);
        cursor += 2;

        if (packet_lengths.items.len > 0) {
            cursor = try appendTemporaryPacketPayloads(allocator, &out, bytes, cursor, tile_part_end, packet_lengths.items);
        } else {
            const payload_start = try skipPacketBoundaryMarkers(bytes, cursor, tile_part_end);
            try out.appendSlice(allocator, bytes[payload_start..tile_part_end]);
        }
        cursor = tile_part_end;
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

    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(Marker.eoc)) {
            cursor += 2;
            if (cursor != bytes.len) return CodestreamError.InvalidCodestream;
            return;
        }
        if (marker != @intFromEnum(Marker.sot)) return CodestreamError.InvalidCodestream;

        const marker_start = cursor;
        cursor += 2;
        if (bytes.len - cursor < 10) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, cursor);
        if (segment_length != 10) return CodestreamError.InvalidCodestream;
        const psot = readU32Be(bytes, cursor + 4);
        if (psot == 0) return CodestreamError.UnsupportedPayload;
        const tile_part_end = try std.math.add(usize, marker_start, psot);
        if (tile_part_end > bytes.len or tile_part_end < cursor + segment_length + 2) {
            return CodestreamError.TruncatedData;
        }

        cursor += segment_length;
        var packet_lengths: std.ArrayList(usize) = .empty;
        defer packet_lengths.deinit(allocator);
        cursor = try readTilePartHeaderMarkers(allocator, bytes, cursor, tile_part_end, &packet_lengths);
        cursor += 2;
        if (packet_lengths.items.len > 0) {
            var payload_bytes: usize = 0;
            for (packet_lengths.items) |packet_length| {
                payload_bytes = try std.math.add(usize, payload_bytes, packet_length);
            }
            if (payload_bytes != tile_part_end - cursor) return CodestreamError.InvalidCodestream;
        }
        cursor = tile_part_end;
    }

    return CodestreamError.InvalidCodestream;
}

fn validateStrictRpclPacketsMatchTemporary(allocator: std.mem.Allocator, bytes: []const u8, payload: []const u8) !void {
    var expected = try readRpclPacketStreamFromTemporary(allocator, payload);
    defer expected.deinit();
    if (expected.packet_lengths.len == 0) {
        try validateTilePartPayloads(allocator, bytes);
        return;
    }

    var actual = try readStrictSodRpclPacketStream(allocator, bytes);
    defer actual.deinit();

    if (!std.mem.eql(u32, expected.packet_lengths, actual.packet_lengths)) {
        return CodestreamError.InvalidCodestream;
    }
    if (!std.mem.eql(u8, expected.packet_bytes, actual.packet_bytes)) {
        return CodestreamError.InvalidCodestream;
    }
    validateStrictRpclT2Packets(allocator, payload, actual) catch |err| switch (err) {
        CodestreamError.ImageTooLarge,
        CodestreamError.TooManyLevels,
        CodestreamError.InvalidCodestream,
        CodestreamError.UnsupportedPayload,
        CodestreamError.TruncatedData,
        => return err,
        else => return CodestreamError.InvalidCodestream,
    };
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

fn validateStrictRpclT2Packets(allocator: std.mem.Allocator, payload: []const u8, actual: RpclPacketStream) !void {
    var cursor = Cursor.initWithAllocator(allocator, payload);
    const header = try readTemporaryHeader(&cursor);
    if (header.version < 8) return;

    var catalogs: [3]TemporaryComponentRpclCatalog = undefined;
    var initialized_catalogs: usize = 0;
    defer {
        for (catalogs[0..initialized_catalogs]) |*catalog| catalog.deinit();
    }
    inline for (0..3) |component| {
        catalogs[component] = try readTemporaryComponentRpclCatalog(allocator, &cursor, component, header.version, header.layers, header.bit_depth);
        initialized_catalogs += 1;
    }

    _ = try readRpclShadowStreamInfo(&cursor, header.version, header.packet_count);
    if (!cursor.finished()) return CodestreamError.InvalidCodestream;

    const plan = temporaryPacketPlan(header);
    const bands = try subband.makeBands(allocator, header.width, header.height, header.levels);
    defer allocator.free(bands);
    const blocks = try subband.makeCodeBlocks(allocator, bands, header.block_width, header.block_height);
    defer allocator.free(blocks);
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

                var state = try t2.PrecinctPacketReaderState.initWithLayerCount(allocator, selected.len, 1, selected.len, header.layers);
                defer state.deinit();
                const locations = try sequentialPacketLocations(allocator, selected.len);
                defer allocator.free(locations);
                const decoded = try allocator.alloc(t2.DecodedPacketBlock, selected.len);
                defer allocator.free(decoded);
                const payloads = try allocator.alloc(?[]const u8, selected.len);
                defer allocator.free(payloads);
                const max_zero_bitplanes = maxZeroBitplanes(catalogs[component].blocks, selected);

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
                    const read = try state.readRpclPacket(
                        allocator,
                        packet_bytes.bytes,
                        packet,
                        @intCast(resolution_index),
                        component,
                        precinct_index,
                        locations,
                        max_zero_bitplanes,
                        decoded,
                        payloads,
                    );
                    if (read.packet_length != packet_bytes.bytes.len) return CodestreamError.InvalidCodestream;
                    try validateDecodedRpclPacketBlocks(catalogs[component].blocks, selected, layer, decoded, payloads);
                    packet_byte_offset = packet_bytes.next_offset;
                    sequence += 1;
                }
            }
        }
    }
    if (sequence != header.packet_count or packet_byte_offset != actual.packet_bytes.len) return CodestreamError.InvalidCodestream;
}

fn readTemporaryComponentRpclCatalog(
    allocator: std.mem.Allocator,
    cursor: *Cursor,
    comptime expected_component: u8,
    payload_version: u8,
    layer_count: u16,
    nominal_bitplanes: u8,
) !TemporaryComponentRpclCatalog {
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

    const blocks = try allocator.alloc(TemporaryRpclBlock, block_count);
    errdefer allocator.free(blocks);
    for (blocks) |*block| block.* = undefined;

    var block_index: usize = 0;
    while (block_index < block_count) : (block_index += 1) {
        const block_band = try cursor.readU16();
        if (block_band >= band_count) return CodestreamError.InvalidCodestream;
        _ = try cursor.readRect();
        _ = try cursor.readRect();
        const bitplanes = try cursor.readU8();
        const non_zero_count = try cursor.readU32();
        const coding_passes = try readStoredCodingPasses(cursor, payload_version, bitplanes, non_zero_count);
        const layers = try readLayerAllocation(cursor, payload_version, layer_count, coding_passes);
        _ = try readEntropyStreamInfo(cursor);
        _ = try readEntropyStreamInfo(cursor);
        _ = try readEntropyStreamInfo(cursor);
        const ebcot_segment = try readEbcotSegmentInfo(cursor, payload_version, coding_passes);
        if (payload_version < 7 and ebcot_segment.mq_bytes != 0) return CodestreamError.InvalidCodestream;
        const payload_len = std.math.cast(usize, ebcot_segment.mq_bytes) orelse return CodestreamError.InvalidCodestream;
        const payload = if (payload_version >= 7) try cursor.readBytes(payload_len) else &.{};

        var converted_layers = [_]t2.LayerTruncation{.{ .cumulative_passes = 0, .cumulative_bytes = 0 }} ** max_quality_layers;
        for (layers[0..@as(usize, @intCast(layer_count))], 0..) |layer, index| {
            converted_layers[index] = .{
                .cumulative_passes = layer.cumulative_passes,
                .cumulative_bytes = layer.cumulative_bytes,
            };
        }
        blocks[block_index] = .{
            .nominal_bitplanes = @max(nominal_bitplanes, bitplanes),
            .encoded_bitplanes = bitplanes,
            .layers = converted_layers,
            .payload = payload,
        };
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

fn sequentialPacketLocations(allocator: std.mem.Allocator, count: usize) ![]t2.PacketBlockLocation {
    const locations = try allocator.alloc(t2.PacketBlockLocation, count);
    for (locations, 0..) |*location, index| {
        location.* = .{ .leaf_x = index, .leaf_y = 0 };
    }
    return locations;
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

    var cursor: usize = 2;
    cursor = try skipMainHeaderToFirstSot(bytes, cursor);
    var packet_sequence: u16 = 0;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(Marker.eoc)) {
            cursor += 2;
            if (cursor != bytes.len) return CodestreamError.InvalidCodestream;
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

        const marker_start = cursor;
        cursor += 2;
        if (bytes.len - cursor < 10) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, cursor);
        if (segment_length != 10) return CodestreamError.InvalidCodestream;
        const psot = readU32Be(bytes, cursor + 4);
        if (psot == 0) return CodestreamError.UnsupportedPayload;
        const tile_part_end = try std.math.add(usize, marker_start, psot);
        if (tile_part_end > bytes.len or tile_part_end < cursor + segment_length + 2) {
            return CodestreamError.TruncatedData;
        }

        cursor += segment_length;
        var tile_packet_lengths: std.ArrayList(usize) = .empty;
        defer tile_packet_lengths.deinit(allocator);
        const sod = try readTilePartHeaderMarkers(allocator, bytes, cursor, tile_part_end, &tile_packet_lengths);
        if (tile_packet_lengths.items.len == 0) return CodestreamError.UnsupportedPayload;
        cursor = sod + 2;
        try appendStrictSodPackets(
            allocator,
            &lengths,
            &packet_bytes,
            bytes,
            cursor,
            tile_part_end,
            tile_packet_lengths.items,
            &packet_sequence,
        );
        cursor = tile_part_end;
    }

    return CodestreamError.InvalidCodestream;
}

fn skipMainHeaderToFirstSot(bytes: []const u8, start: usize) !usize {
    var cursor = start;
    while (cursor < bytes.len) {
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const marker = readU16Be(bytes, cursor);
        cursor += 2;
        if (marker == @intFromEnum(Marker.sot)) return cursor - 2;
        if (marker == @intFromEnum(Marker.sod) or marker == @intFromEnum(Marker.eoc)) {
            return CodestreamError.InvalidCodestream;
        }
        if (bytes.len - cursor < 2) return CodestreamError.TruncatedData;
        const segment_length = readU16Be(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) {
            return CodestreamError.TruncatedData;
        }
        cursor += segment_length;
    }
    return CodestreamError.InvalidCodestream;
}

fn appendStrictSodPackets(
    allocator: std.mem.Allocator,
    lengths: *std.ArrayList(u32),
    packet_bytes: *std.ArrayList(u8),
    bytes: []const u8,
    start: usize,
    end: usize,
    packet_lengths: []const usize,
    packet_sequence: *u16,
) !void {
    var cursor = start;
    for (packet_lengths) |packet_length| {
        const packet_end = try std.math.add(usize, cursor, packet_length);
        if (packet_end > end) return CodestreamError.TruncatedData;
        var packet_start = cursor;

        if (packet_end - packet_start >= 2 and readU16Be(bytes, packet_start) == @intFromEnum(Marker.sop)) {
            if (packet_end - packet_start < 6) return CodestreamError.TruncatedData;
            const segment_length = readU16Be(bytes, packet_start + 2);
            if (segment_length != 4) return CodestreamError.InvalidCodestream;
            const sequence = readU16Be(bytes, packet_start + 4);
            if (sequence != packet_sequence.*) return CodestreamError.InvalidCodestream;
            packet_sequence.* +%= 1;
            packet_start += 6;
        }

        var packet_payload_end = packet_end;
        if (packet_payload_end - packet_start >= 2 and readU16Be(bytes, packet_payload_end - 2) == @intFromEnum(Marker.eph)) {
            packet_payload_end -= 2;
        }
        if (packet_payload_end < packet_start) return CodestreamError.InvalidCodestream;
        const payload_len = packet_payload_end - packet_start;
        const payload_len_u32 = std.math.cast(u32, payload_len) orelse return CodestreamError.InvalidCodestream;
        try lengths.append(allocator, payload_len_u32);
        try packet_bytes.appendSlice(allocator, bytes[packet_start..packet_payload_end]);
        cursor = packet_end;
    }
    if (cursor != end) return CodestreamError.InvalidCodestream;
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
    block_width: u16,
    block_height: u16,
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
    if (payload_version < 6) return .{};

    const pass_count = try cursor.readU16();
    if (pass_count != coding_passes) return CodestreamError.InvalidCodestream;
    const byte_length = try cursor.readU64();

    var stats = EbcotSegmentStats{};
    stats.blocks = if (pass_count == 0 and byte_length == 0) 0 else 1;
    stats.passes = @as(u64, pass_count);
    stats.mq_bytes = byte_length;

    var previous_end: u64 = 0;
    var pass_index: usize = 0;
    while (pass_index < @as(usize, pass_count)) : (pass_index += 1) {
        const kind = try cursor.readU8();
        if (kind > 2) return CodestreamError.InvalidCodestream;
        _ = try cursor.readU8();
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
    }
    if (previous_end != byte_length) return CodestreamError.InvalidCodestream;

    return stats;
}

fn skipEbcotSegmentPayload(cursor: *Cursor, payload_version: u8, byte_length: u64) !void {
    if (payload_version < 7) return;
    const len = std.math.cast(usize, byte_length) orelse return CodestreamError.InvalidCodestream;
    _ = try cursor.readBytes(len);
}

fn readRpclShadowStreamInfo(cursor: *Cursor, payload_version: u8, expected_packet_count: u64) !RpclShadowStreamInfo {
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
    try out.append(allocator, @intFromEnum(options.mct));
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
    options: LosslessOptions,
) !void {
    const bands = 1 + 3 * @as(u16, levels);
    try appendMarker(allocator, out, .qcd);
    try appendU16Be(allocator, out, 3 + bands);
    try out.append(allocator, qcdStyleByte(options));
    for (0..bands) |_| {
        try out.append(allocator, 8 << 3);
    }
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
            try appendPltSegmentLengths(allocator, bytes[cursor + 2 .. cursor + segment_length], packet_lengths);
        }
        cursor += segment_length;
    }
    return CodestreamError.InvalidCodestream;
}

fn appendPltSegmentLengths(
    allocator: std.mem.Allocator,
    segment: []const u8,
    packet_lengths: *std.ArrayList(usize),
) !void {
    if (segment.len == 0) return CodestreamError.InvalidCodestream;
    _ = segment[0];
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
        const adjusted_length = rpclPacketLengthWithMarkers(options, packet_length);
        const encoded_len = pltLengthByteCount(adjusted_length);
        if (segment.items.len + encoded_len > 65532) {
            try flushPltSegment(allocator, out, marker_index, segment.items);
            if (marker_index == std.math.maxInt(u8)) return CodestreamError.InvalidCodestream;
            marker_index += 1;
            segment.clearRetainingCapacity();
        }
        try appendPltLength(allocator, &segment, adjusted_length);
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
    packet_bytes: []const u8,
    packet_sequence: *u16,
) !void {
    var cursor: usize = 0;
    for (packet_lengths) |packet_length| {
        const end = try std.math.add(usize, cursor, packet_length);
        if (end > packet_bytes.len) return CodestreamError.InvalidCodestream;
        if (options.sop) {
            try appendSop(allocator, out, packet_sequence.*);
            packet_sequence.* +%= 1;
        }
        try out.appendSlice(allocator, packet_bytes[cursor..end]);
        if (options.eph) try appendMarker(allocator, out, .eph);
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

    var catalogs = try buildComponentRpclShadowCatalogs(allocator, planes, blocks, options, options.emit_temporary_payload_sidecar);
    defer {
        for (&catalogs) |*catalog| catalog.deinit();
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
    if (sequence != plan.packets or packet_lengths.items.len != plan.packets) {
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
        const owned_bytes = try packet_bytes.toOwnedSlice(allocator);
        stream.* = .{
            .allocator = allocator,
            .packet_lengths = owned_lengths,
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

    for (blocks, 0..) |block, block_index| {
        if (block.band_index >= bands.len) return CodestreamError.InvalidCodestream;
        const resolution_index = try t2.bandResolutionIndex(levels, bands[block.band_index]);
        const block_rect = try t2.codeBlockPacketRect(block);
        const resolution = plan.resolutions[resolution_index];
        if (block_rect.width == 0 or block_rect.height == 0) continue;

        const first_precinct_x = block_rect.x / resolution.precinct_width;
        const first_precinct_y = block_rect.y / resolution.precinct_height;
        const right = @as(u64, block_rect.x) + @as(u64, block_rect.width);
        const bottom = @as(u64, block_rect.y) + @as(u64, block_rect.height);
        const last_precinct_x: u32 = @intCast(@min(
            @as(u64, resolution.precincts_x - 1),
            (right - 1) / resolution.precinct_width,
        ));
        const last_precinct_y: u32 = @intCast(@min(
            @as(u64, resolution.precincts_y - 1),
            (bottom - 1) / resolution.precinct_height,
        ));
        if (first_precinct_x >= resolution.precincts_x or first_precinct_y >= resolution.precincts_y) {
            return CodestreamError.InvalidCodestream;
        }

        var precinct_y = first_precinct_y;
        while (precinct_y <= last_precinct_y) : (precinct_y += 1) {
            var precinct_x = first_precinct_x;
            while (precinct_x <= last_precinct_x) : (precinct_x += 1) {
                const precinct_index = @as(u64, precinct_y) * resolution.precincts_x + precinct_x;
                const precinct = try packet_plan.precinctRect(plan, resolution_index, precinct_index);
                if (!packet_plan.rectsIntersect(precinct, block_rect)) continue;

                var component: u16 = 0;
                while (component < 3) : (component += 1) {
                    const cell = try index.cell(resolution_index, precinct_index, component);
                    try cell.indexes.append(allocator, block_index);
                }
            }
        }
    }

    return index;
}

fn buildComponentRpclShadowCatalogs(
    allocator: std.mem.Allocator,
    planes: color.RctPlanes,
    blocks: []const subband.CodeBlock,
    options: LosslessOptions,
    include_bitplane_payload: bool,
) ![3]ComponentRpclShadowCatalog {
    if (payloadBlockThreadCount(options, blocks.len) > 1 or componentThreadCount(options) < 2) {
        var catalogs: [3]ComponentRpclShadowCatalog = undefined;
        var initialized: usize = 0;
        errdefer {
            for (catalogs[0..initialized]) |*catalog| catalog.deinit();
        }
        catalogs[0] = try buildComponentRpclShadowCatalog(allocator, planes.y, planes.width, blocks, planes.bit_depth, options, include_bitplane_payload);
        initialized += 1;
        catalogs[1] = try buildComponentRpclShadowCatalog(allocator, planes.cb, planes.width, blocks, planes.bit_depth, options, include_bitplane_payload);
        initialized += 1;
        catalogs[2] = try buildComponentRpclShadowCatalog(allocator, planes.cr, planes.width, blocks, planes.bit_depth, options, include_bitplane_payload);
        return catalogs;
    }

    var jobs = [_]ComponentCatalogJob{
        .{ .plane = planes.y, .stride = planes.width, .blocks = blocks, .nominal_bitplanes = planes.bit_depth, .options = options, .include_bitplane_payload = include_bitplane_payload },
        .{ .plane = planes.cb, .stride = planes.width, .blocks = blocks, .nominal_bitplanes = planes.bit_depth, .options = options, .include_bitplane_payload = include_bitplane_payload },
        .{ .plane = planes.cr, .stride = planes.width, .blocks = blocks, .nominal_bitplanes = planes.bit_depth, .options = options, .include_bitplane_payload = include_bitplane_payload },
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

fn buildComponentRpclShadowCatalog(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
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
        catalog_blocks[index] = try buildRpclShadowBlock(
            allocator,
            &bitplane_scratch,
            &ebcot_scratch,
            plane,
            stride,
            block.rect,
            nominal_bitplanes,
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
    blocks: []const subband.CodeBlock,
    catalog_blocks: []RpclShadowBlock,
    nominal_bitplanes: u8,
    options: LosslessOptions,
    include_bitplane_payload: bool,
    worker_count: usize,
) !void {
    if (blocks.len != catalog_blocks.len) return CodestreamError.InvalidCodestream;

    var jobs = try allocator.alloc(ComponentCatalogBlockJob, worker_count);
    defer allocator.free(jobs);
    for (jobs, 0..) |*job, index| {
        const start = blockRangeBoundary(blocks.len, worker_count, index);
        const end = blockRangeBoundary(blocks.len, worker_count, index + 1);
        job.* = .{
            .allocator = allocator,
            .plane = plane,
            .stride = stride,
            .blocks = blocks[start..end],
            .catalog_blocks = catalog_blocks[start..end],
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

fn buildRpclShadowBlock(
    allocator: std.mem.Allocator,
    bitplane_scratch: *bitplane.BlockScratch,
    ebcot_scratch: *ebcot.DirectBlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
    nominal_bitplanes: u8,
    options: LosslessOptions,
    include_bitplane_payload: bool,
) !RpclShadowBlock {
    var segment = try ebcot.encodeCodeBlockSegmentDirectScratch(ebcot_scratch, plane, stride, rect);
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
    try computeLayerTruncations(&layers, options, .{
        .pass_count = segment.pass_count,
        .byte_length = segment.byte_length,
    });

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
    block: rate_alloc.Block,
) !void {
    var layers: [max_quality_layers]rate_alloc.Truncation = undefined;
    const layer_count: usize = @intCast(options.layers);
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
    for (layers[0..layer_count], 0..) |layer, index| {
        out[index] = .{
            .cumulative_passes = layer.cumulative_passes,
            .cumulative_bytes = layer.cumulative_bytes,
        };
    }
}

fn appendRpclShadowPacketsForSelection(
    allocator: std.mem.Allocator,
    packet_bytes: *std.ArrayList(u8),
    packet_lengths: *std.ArrayList(u32),
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
            sequence.* += 1;
        }
        return;
    }

    const encoded = try allocator.alloc(t2.EncodedLayerBlock, selected.len);
    defer allocator.free(encoded);
    const sequential_indexes = try allocator.alloc(usize, selected.len);
    defer allocator.free(sequential_indexes);
    for (selected, 0..) |source_index, index| {
        if (source_index >= catalog.blocks.len) return CodestreamError.InvalidCodestream;
        encoded[index] = catalog.blocks[source_index].encoded;
        encoded[index].location = .{ .leaf_x = index, .leaf_y = 0 };
        sequential_indexes[index] = index;
    }

    var writer_state = try t2.PrecinctPacketWriterState.initForEncodedBlocks(allocator, encoded);
    defer writer_state.deinit();

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
        _ = try t2.appendRpclPacketForIndexes(
            &writer_state,
            allocator,
            packet_bytes,
            packet,
            expected_resolution,
            expected_component,
            expected_precinct,
            encoded,
            sequential_indexes,
        );
        try appendShadowPacketLength(allocator, packet_lengths, packet_bytes.items.len - start);
        sequence.* += 1;
    }
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
        try appendLayerAllocation(allocator, out, options, .{
            .pass_count = ebcot_segment.pass_count,
            .byte_length = ebcot_segment.byte_length,
        });
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
    block: rate_alloc.Block,
) !void {
    var layers: [max_quality_layers]rate_alloc.Truncation = undefined;
    const layer_count: usize = @intCast(options.layers);
    if (options.rate_count > 0) {
        try rate_alloc.allocateFromCompressionRatios(
            layers[0..layer_count],
            block,
            options.rates[0..options.rate_count],
        );
    } else {
        try rate_alloc.allocateEven(layers[0..layer_count], block);
    }

    try appendU16Be(allocator, out, options.layers);
    for (layers[0..layer_count]) |layer| {
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

fn validateTileSize(width: u32, height: u32, image_width: usize, image_height: usize) !void {
    if (width == 0 or height == 0) return CodestreamError.InvalidCodestream;
    if (width < image_width or height < image_height) return CodestreamError.UnsupportedPayload;
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
    if (options.progression != .rpcl) return CodestreamError.UnsupportedPayload;
    if (options.mct != .rct) return CodestreamError.UnsupportedPayload;
    if (options.transform != .reversible_5_3) return CodestreamError.UnsupportedPayload;
    if (options.quantization != .none) return CodestreamError.UnsupportedPayload;
    if (options.guard_bits > 7) return CodestreamError.InvalidCodestream;
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

fn qcdStyleByte(options: LosslessOptions) u8 {
    return (options.guard_bits << 5) | @intFromEnum(options.quantization);
}
