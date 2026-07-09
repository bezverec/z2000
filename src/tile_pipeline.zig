const std = @import("std");
const color = @import("color.zig");
const ebcot = @import("ebcot.zig");
const image = @import("image.zig");
const packet_plan = @import("packet_plan.zig");
const rate_alloc = @import("rate_alloc.zig");
const subband = @import("subband.zig");
const t2 = @import("t2.zig");
const tile_grid = @import("tile_grid.zig");
const wavelet_int = @import("wavelet_int.zig");

pub const RctTile = struct {
    tile: tile_grid.Tile,
    planes: color.RctPlanes,

    pub fn deinit(self: *RctTile) void {
        self.planes.deinit();
        self.* = undefined;
    }
};

pub const PacketScaffoldOptions = struct {
    layers: u16 = 1,
    block_width: usize = 64,
    block_height: usize = 64,
    precincts: []const packet_plan.Precinct,
};

pub const PacketScaffold = struct {
    allocator: std.mem.Allocator,
    tile: tile_grid.Tile,
    levels: u8,
    layers: u16,
    block_width: usize,
    block_height: usize,
    plan: packet_plan.Plan,
    bands: []subband.Band,
    blocks: []subband.CodeBlock,

    pub fn deinit(self: *PacketScaffold) void {
        self.allocator.free(self.blocks);
        self.allocator.free(self.bands);
        self.* = undefined;
    }

    pub fn componentBlockCount(self: PacketScaffold) !usize {
        return std.math.mul(usize, self.blocks.len, component_count);
    }

    pub fn componentBlock(self: PacketScaffold, index: usize) !ComponentBlock {
        const count = try self.componentBlockCount();
        if (index >= count) return PacketScaffoldError.InvalidComponentBlock;
        const component = index / self.blocks.len;
        const block_index = index % self.blocks.len;
        return self.componentBlockAt(@intCast(component), block_index);
    }

    pub fn componentBlockAt(self: PacketScaffold, component: u8, block_index: usize) !ComponentBlock {
        if (component >= component_count or block_index >= self.blocks.len) return PacketScaffoldError.InvalidComponentBlock;
        const block = self.blocks[block_index];
        if (block.band_index >= self.bands.len) return PacketScaffoldError.InvalidComponentBlock;
        const band = self.bands[block.band_index];
        return .{
            .tile = self.tile,
            .component = component,
            .block_index = block_index,
            .band_index = block.band_index,
            .band = band,
            .rect = block.rect,
        };
    }

    pub fn componentBlockIterator(self: PacketScaffold) ComponentBlockIterator {
        return .{ .scaffold = self };
    }
};

pub const PacketScaffoldError = error{
    InvalidComponentBlock,
    InvalidLayer,
    InvalidPacket,
    InvalidPlane,
};

pub const ComponentBlock = struct {
    tile: tile_grid.Tile,
    component: u8,
    block_index: usize,
    band_index: usize,
    band: subband.Band,
    rect: subband.Rect,

    pub fn view(self: ComponentBlock, rct_tile: RctTile) !ComponentBlockView {
        if (self.tile.index != rct_tile.tile.index) return PacketScaffoldError.InvalidComponentBlock;
        const plane = componentPlane(rct_tile, self.component) orelse return PacketScaffoldError.InvalidComponentBlock;
        try validateRectInPlane(self.rect, rct_tile.planes.width, rct_tile.planes.height);
        return .{
            .job = self,
            .plane = plane,
            .stride = rct_tile.planes.width,
            .rect = self.rect,
        };
    }
};

pub const ComponentBlockView = struct {
    job: ComponentBlock,
    plane: []i32,
    stride: usize,
    rect: subband.Rect,

    pub fn sample(self: ComponentBlockView, x: usize, y: usize) !i32 {
        if (x >= self.rect.width or y >= self.rect.height) return PacketScaffoldError.InvalidComponentBlock;
        return self.plane[(self.rect.y + y) * self.stride + self.rect.x + x];
    }
};

pub const EncodedComponentBlock = struct {
    job: ComponentBlock,
    segment: ebcot.CodeBlockSegment,
    layers: []t2.LayerTruncation = &.{},

    pub fn deinit(self: *EncodedComponentBlock, allocator: std.mem.Allocator) void {
        self.segment.deinit(allocator);
        if (self.layers.len > 0) allocator.free(self.layers);
        self.* = undefined;
    }

    pub fn asEncodedLayerBlock(
        self: EncodedComponentBlock,
        scaffold: PacketScaffold,
        nominal_bitplanes: u8,
    ) !t2.EncodedLayerBlock {
        if (self.job.tile.index != scaffold.tile.index) return PacketScaffoldError.InvalidComponentBlock;
        if (self.layers.len != @as(usize, @intCast(scaffold.layers))) return PacketScaffoldError.InvalidLayer;
        if (self.segment.bitplanes > nominal_bitplanes) return PacketScaffoldError.InvalidLayer;

        const grid = try t2.CodeBlockGrid.init(
            self.job.band.rect.x,
            self.job.band.rect.y,
            self.job.band.rect.width,
            self.job.band.rect.height,
            scaffold.block_width,
            scaffold.block_height,
        );
        const location = try grid.locationForRect(.{
            .x = self.job.rect.x,
            .y = self.job.rect.y,
            .width = self.job.rect.width,
            .height = self.job.rect.height,
        });

        return .{
            .location = location,
            .nominal_bitplanes = nominal_bitplanes,
            .encoded_bitplanes = self.segment.bitplanes,
            .layers = self.layers,
            .payload = self.segment.bytes,
            .segments = if (self.segment.segments) |segments| segments else &.{},
        };
    }
};

pub const EncodedBlockCatalog = struct {
    allocator: std.mem.Allocator,
    tile: tile_grid.Tile,
    component_block_count: usize,
    blocks: []EncodedComponentBlock,

    pub fn deinit(self: *EncodedBlockCatalog) void {
        for (self.blocks) |*block| block.deinit(self.allocator);
        self.allocator.free(self.blocks);
        self.* = undefined;
    }

    pub fn componentBlocks(self: EncodedBlockCatalog, component: u8) ![]EncodedComponentBlock {
        if (component >= component_count) return PacketScaffoldError.InvalidComponentBlock;
        const start = @as(usize, component) * self.component_block_count;
        return self.blocks[start..][0..self.component_block_count];
    }

    pub fn totalPasses(self: EncodedBlockCatalog) u64 {
        var total: u64 = 0;
        for (self.blocks) |block| total += block.segment.pass_count;
        return total;
    }

    pub fn totalBytes(self: EncodedBlockCatalog) u64 {
        var total: u64 = 0;
        for (self.blocks) |block| total += block.segment.byte_length;
        return total;
    }
};

pub const RpclPacketIndexEntry = struct {
    packet: packet_plan.Packet,
    first_index: usize,
    index_count: usize,
};

pub const RpclPacketBandGroupEntry = struct {
    band_index: usize,
    first_index: usize,
    index_count: usize,
};

const TilePacketWriterBandGroup = struct {
    encoded: []t2.EncodedLayerBlock,
    writer_state: t2.PrecinctPacketWriterState,

    fn deinit(self: *TilePacketWriterBandGroup, allocator: std.mem.Allocator) void {
        self.writer_state.deinit();
        allocator.free(self.encoded);
        self.* = undefined;
    }
};

const TilePacketReaderBandGroup = struct {
    encoded: []t2.EncodedLayerBlock,
    reader_state: t2.PrecinctPacketReaderState,
    locations: []t2.PacketBlockLocation,
    decoded: []t2.DecodedPacketBlock,
    payloads: []?[]const u8,
    max_zero_bitplanes: u8,

    fn deinit(self: *TilePacketReaderBandGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.payloads);
        allocator.free(self.decoded);
        allocator.free(self.locations);
        self.reader_state.deinit();
        allocator.free(self.encoded);
        self.* = undefined;
    }
};

const PreparedTilePacketGroup = struct {
    packet_blocks: []t2.PacketBlock,

    fn deinit(self: *PreparedTilePacketGroup, allocator: std.mem.Allocator) void {
        allocator.free(self.packet_blocks);
        self.* = undefined;
    }
};

pub const TileRpclPacketStream = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    packet_lengths: []u32,
    packet_header_lengths: []u32,

    pub fn deinit(self: *TileRpclPacketStream) void {
        self.allocator.free(self.packet_header_lengths);
        self.allocator.free(self.packet_lengths);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn totalPacketBytes(self: TileRpclPacketStream) !usize {
        var total: usize = 0;
        for (self.packet_lengths) |length| {
            total = try std.math.add(usize, total, length);
        }
        return total;
    }
};

pub const TileRpclEncodeArtifacts = struct {
    allocator: std.mem.Allocator,
    tile: tile_grid.Tile,
    bit_depth: u8,
    levels: u8,
    scaffold: PacketScaffold,
    catalog: EncodedBlockCatalog,
    index: RpclPacketIndex,
    stream: TileRpclPacketStream,

    pub fn deinit(self: *TileRpclEncodeArtifacts) void {
        self.stream.deinit();
        self.index.deinit();
        self.catalog.deinit();
        self.scaffold.deinit();
        self.* = undefined;
    }

    pub fn packetCount(self: TileRpclEncodeArtifacts) usize {
        return self.stream.packet_lengths.len;
    }

    pub fn totalPacketBytes(self: TileRpclEncodeArtifacts) !usize {
        return self.stream.totalPacketBytes();
    }

    pub fn totalPayloadBytes(self: TileRpclEncodeArtifacts) !usize {
        if (self.stream.packet_lengths.len != self.stream.packet_header_lengths.len) {
            return PacketScaffoldError.InvalidPacket;
        }
        var total: usize = 0;
        for (self.stream.packet_lengths, self.stream.packet_header_lengths) |packet_length, header_length| {
            if (packet_length < header_length) return PacketScaffoldError.InvalidPacket;
            total = try std.math.add(usize, total, packet_length - header_length);
        }
        return total;
    }
};

pub const TileRpclEncodeGridArtifacts = struct {
    allocator: std.mem.Allocator,
    grid: tile_grid.Grid,
    tiles: []TileRpclEncodeArtifacts,

    pub fn deinit(self: *TileRpclEncodeGridArtifacts) void {
        for (self.tiles) |*tile| tile.deinit();
        self.allocator.free(self.tiles);
        self.* = undefined;
    }

    pub fn tileCount(self: TileRpclEncodeGridArtifacts) usize {
        return self.tiles.len;
    }

    pub fn totalPackets(self: TileRpclEncodeGridArtifacts) !usize {
        var total: usize = 0;
        for (self.tiles) |tile| {
            total = try std.math.add(usize, total, tile.packetCount());
        }
        return total;
    }

    pub fn totalPacketBytes(self: TileRpclEncodeGridArtifacts) !usize {
        var total: usize = 0;
        for (self.tiles) |tile| {
            total = try std.math.add(usize, total, try tile.totalPacketBytes());
        }
        return total;
    }

    pub fn totalPayloadBytes(self: TileRpclEncodeGridArtifacts) !usize {
        var total: usize = 0;
        for (self.tiles) |tile| {
            total = try std.math.add(usize, total, try tile.totalPayloadBytes());
        }
        return total;
    }
};

pub const TilePartLayoutOptions = struct {
    sop: bool = false,
    eph: bool = false,
    plt: bool = true,
};

pub const TilePartSequenceOptions = struct {
    tlm: bool = true,
    tile_part: TilePartLayoutOptions = .{},
};

pub const TilePartSequence = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    tile_part_offsets: []usize,
    tlm_bytes: usize,

    pub fn deinit(self: *TilePartSequence) void {
        self.allocator.free(self.tile_part_offsets);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn tilePartSlice(self: TilePartSequence, index: usize) ![]const u8 {
        if (index >= self.tile_part_offsets.len) return PacketScaffoldError.InvalidPacket;
        const start = self.tile_part_offsets[index];
        const end = if (index + 1 < self.tile_part_offsets.len)
            self.tile_part_offsets[index + 1]
        else
            self.bytes.len;
        if (start < self.tlm_bytes or start > end or end > self.bytes.len) {
            return PacketScaffoldError.InvalidPacket;
        }
        return self.bytes[start..end];
    }

    pub fn tlmSlice(self: TilePartSequence) ![]const u8 {
        if (self.tlm_bytes > self.bytes.len) return PacketScaffoldError.InvalidPacket;
        return self.bytes[0..self.tlm_bytes];
    }

    pub fn totalTilePartBytes(self: TilePartSequence) !usize {
        if (self.tlm_bytes > self.bytes.len) return PacketScaffoldError.InvalidPacket;
        return self.bytes.len - self.tlm_bytes;
    }
};

pub const TilePartCodestreamFragment = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    tile_part_offsets: []usize,
    tile_part_sequence_offset: usize,
    tlm_bytes: usize,

    pub fn deinit(self: *TilePartCodestreamFragment) void {
        self.allocator.free(self.tile_part_offsets);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn tilePartSlice(self: TilePartCodestreamFragment, index: usize) ![]const u8 {
        if (index >= self.tile_part_offsets.len) return PacketScaffoldError.InvalidPacket;
        const start = self.tile_part_offsets[index];
        const end = if (index + 1 < self.tile_part_offsets.len)
            self.tile_part_offsets[index + 1]
        else if (self.bytes.len >= 2)
            self.bytes.len - 2
        else
            return PacketScaffoldError.InvalidPacket;
        if (start < self.tile_part_sequence_offset + self.tlm_bytes or start > end or end > self.bytes.len) {
            return PacketScaffoldError.InvalidPacket;
        }
        return self.bytes[start..end];
    }

    pub fn tlmSlice(self: TilePartCodestreamFragment) ![]const u8 {
        const start = self.tile_part_sequence_offset;
        const end = try std.math.add(usize, start, self.tlm_bytes);
        if (end > self.bytes.len) return PacketScaffoldError.InvalidPacket;
        return self.bytes[start..end];
    }

    pub fn tilePartSequenceSlice(self: TilePartCodestreamFragment) ![]const u8 {
        if (self.tile_part_sequence_offset > self.bytes.len or self.bytes.len < 2) {
            return PacketScaffoldError.InvalidPacket;
        }
        return self.bytes[self.tile_part_sequence_offset .. self.bytes.len - 2];
    }

    pub fn parseTlmEntries(self: TilePartCodestreamFragment, allocator: std.mem.Allocator) ![]ParsedTilePartTlmEntry {
        return parseTilePartTlmEntries(allocator, try self.tlmSlice());
    }

    pub fn validateTlmMatchesTileParts(self: TilePartCodestreamFragment, allocator: std.mem.Allocator) !void {
        const entries = try self.parseTlmEntries(allocator);
        defer allocator.free(entries);
        if (entries.len != self.tile_part_offsets.len) return PacketScaffoldError.InvalidPacket;

        for (entries, 0..) |entry, index| {
            const tile_part = try self.tilePartSlice(index);
            if (tile_part.len < 12) return PacketScaffoldError.InvalidPacket;
            if (entry.tile_index != readU16Be(tile_part, 4)) return PacketScaffoldError.InvalidPacket;
            if (entry.psot != readU32Be(tile_part, 6)) return PacketScaffoldError.InvalidPacket;
        }
    }

    pub fn parseTilePartPltLengths(self: TilePartCodestreamFragment, allocator: std.mem.Allocator, index: usize) ![]u32 {
        return parseTilePartPltLengthsFromBytes(allocator, try self.tilePartSlice(index));
    }

    pub fn validatePltMatchesTilePartPayload(self: TilePartCodestreamFragment, allocator: std.mem.Allocator, index: usize) !void {
        const lengths = try self.parseTilePartPltLengths(allocator, index);
        defer allocator.free(lengths);

        const tile_part = try self.tilePartSlice(index);
        const sod_offset = try tilePartSodOffset(tile_part);
        const payload_len = tile_part.len - (sod_offset + 2);

        var total: usize = 0;
        for (lengths) |length| {
            total = try std.math.add(usize, total, @as(usize, @intCast(length)));
        }
        if (total != payload_len) return PacketScaffoldError.InvalidPacket;
    }

    pub fn parseTilePartPacketSpans(self: TilePartCodestreamFragment, allocator: std.mem.Allocator, index: usize) ![]ParsedTilePartPacketSpan {
        const lengths = try self.parseTilePartPltLengths(allocator, index);
        defer allocator.free(lengths);

        const spans = try allocator.alloc(ParsedTilePartPacketSpan, lengths.len);
        errdefer allocator.free(spans);

        var payload_offset: usize = 0;
        for (lengths, spans) |length, *span| {
            span.* = .{
                .payload_offset = payload_offset,
                .length = length,
            };
            payload_offset = try std.math.add(usize, payload_offset, @as(usize, @intCast(length)));
        }

        const tile_part = try self.tilePartSlice(index);
        const sod_offset = try tilePartSodOffset(tile_part);
        const payload_len = tile_part.len - (sod_offset + 2);
        if (payload_offset != payload_len) return PacketScaffoldError.InvalidPacket;
        return spans;
    }

    pub fn tilePartPacketPayloadSlice(
        self: TilePartCodestreamFragment,
        index: usize,
        span: ParsedTilePartPacketSpan,
    ) ![]const u8 {
        const tile_part = try self.tilePartSlice(index);
        const sod_offset = try tilePartSodOffset(tile_part);
        const payload_start = sod_offset + 2;
        const start = try std.math.add(usize, payload_start, span.payload_offset);
        const end = try std.math.add(usize, start, @as(usize, @intCast(span.length)));
        if (end > tile_part.len) return PacketScaffoldError.InvalidPacket;
        return tile_part[start..end];
    }

    pub fn validatePltMatchesAllTileParts(self: TilePartCodestreamFragment, allocator: std.mem.Allocator) !void {
        for (self.tile_part_offsets, 0..) |_, index| {
            try self.validatePltMatchesTilePartPayload(allocator, index);
        }
    }

    pub fn parseTilePartAudit(self: TilePartCodestreamFragment, allocator: std.mem.Allocator, options: TilePartLayoutOptions) ![]ParsedTilePartAuditEntry {
        const entries = try allocator.alloc(ParsedTilePartAuditEntry, self.tile_part_offsets.len);
        errdefer allocator.free(entries);

        for (entries, 0..) |*entry, index| {
            const tile_part = try self.tilePartSlice(index);
            if (tile_part.len < 14) return PacketScaffoldError.InvalidPacket;
            const sod_offset = try tilePartSodOffset(tile_part);
            const packet_spans = try self.parseTilePartPacketSpans(allocator, index);
            defer allocator.free(packet_spans);

            var framed_packet_bytes: usize = 0;
            var raw_packet_bytes: usize = 0;
            for (packet_spans) |span| {
                framed_packet_bytes = try std.math.add(usize, framed_packet_bytes, @as(usize, @intCast(span.length)));
                raw_packet_bytes = try std.math.add(
                    usize,
                    raw_packet_bytes,
                    try rawPacketLengthFromFramed(span.length, options),
                );
            }

            entry.* = .{
                .tile_index = readU16Be(tile_part, 4),
                .tile_part_index = tile_part[10],
                .tile_part_count = tile_part[11],
                .psot = readU32Be(tile_part, 6),
                .plt_bytes = sod_offset - 12,
                .packet_count = packet_spans.len,
                .framed_packet_bytes = framed_packet_bytes,
                .raw_packet_bytes = raw_packet_bytes,
            };
        }

        return entries;
    }

    pub fn validateSinglePartTileOrder(self: TilePartCodestreamFragment, allocator: std.mem.Allocator, options: TilePartLayoutOptions, grid: tile_grid.Grid) !void {
        const entries = try self.parseTilePartAudit(allocator, options);
        defer allocator.free(entries);
        try validateSinglePartTileAuditOrder(entries, grid);
    }

    pub fn validate(self: TilePartCodestreamFragment) !void {
        if (self.bytes.len < 4) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(self.bytes, 0) != @intFromEnum(TilePartMarker.soc)) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(self.bytes, self.bytes.len - 2) != @intFromEnum(TilePartMarker.eoc)) {
            return PacketScaffoldError.InvalidPacket;
        }
        if (self.tile_part_sequence_offset != 2) return PacketScaffoldError.InvalidPacket;
        _ = try self.tlmSlice();

        var previous_offset = self.tile_part_sequence_offset + self.tlm_bytes;
        for (self.tile_part_offsets, 0..) |offset, index| {
            if (offset != previous_offset) return PacketScaffoldError.InvalidPacket;
            const tile_part = try self.tilePartSlice(index);
            if (tile_part.len < 12) return PacketScaffoldError.InvalidPacket;
            if (readU16Be(tile_part, 0) != @intFromEnum(TilePartMarker.sot)) {
                return PacketScaffoldError.InvalidPacket;
            }
            if (readU16Be(tile_part, 2) != 10) return PacketScaffoldError.InvalidPacket;
            const psot = readU32Be(tile_part, 6);
            if (@as(usize, @intCast(psot)) != tile_part.len) return PacketScaffoldError.InvalidPacket;
            try validateTilePartContainsSod(tile_part);
            previous_offset += tile_part.len;
        }
        if (previous_offset != self.bytes.len - 2) return PacketScaffoldError.InvalidPacket;
    }
};

pub const TilePartLayoutEntry = struct {
    tile_index: u16,
    tile_part_index: u8,
    tile_part_count: u8,
    packet_count: usize,
    packet_bytes: usize,
    framed_packet_bytes: usize,
    plt_bytes: usize,
    psot: u32,
};

pub const TilePartLayout = struct {
    allocator: std.mem.Allocator,
    entries: []TilePartLayoutEntry,

    pub fn deinit(self: *TilePartLayout) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn totalPackets(self: TilePartLayout) !usize {
        var total: usize = 0;
        for (self.entries) |entry| {
            total = try std.math.add(usize, total, entry.packet_count);
        }
        return total;
    }

    pub fn totalPacketBytes(self: TilePartLayout) !usize {
        var total: usize = 0;
        for (self.entries) |entry| {
            total = try std.math.add(usize, total, entry.packet_bytes);
        }
        return total;
    }

    pub fn totalFramedPacketBytes(self: TilePartLayout) !usize {
        var total: usize = 0;
        for (self.entries) |entry| {
            total = try std.math.add(usize, total, entry.framed_packet_bytes);
        }
        return total;
    }

    pub fn totalPltBytes(self: TilePartLayout) !usize {
        var total: usize = 0;
        for (self.entries) |entry| {
            total = try std.math.add(usize, total, entry.plt_bytes);
        }
        return total;
    }

    pub fn totalPsotBytes(self: TilePartLayout) !usize {
        var total: usize = 0;
        for (self.entries) |entry| {
            total = try std.math.add(usize, total, entry.psot);
        }
        return total;
    }
};

pub const TilePartTlmEntry = struct {
    tile_index: u16,
    psot: u32,
};

pub const ParsedTilePartTlmEntry = struct {
    tile_index: u16,
    psot: u32,
};

pub const ParsedTilePartPacketSpan = struct {
    payload_offset: usize,
    length: u32,
};

pub const ParsedTilePartAuditEntry = struct {
    tile_index: u16,
    tile_part_index: u8,
    tile_part_count: u8,
    psot: u32,
    plt_bytes: usize,
    packet_count: usize,
    framed_packet_bytes: usize,
    raw_packet_bytes: usize,
};

pub fn validateSinglePartTileAuditOrder(entries: []const ParsedTilePartAuditEntry, grid: tile_grid.Grid) !void {
    const tile_count = std.math.cast(usize, grid.tileCount()) orelse return PacketScaffoldError.InvalidPacket;
    if (entries.len != tile_count) return PacketScaffoldError.InvalidPacket;
    for (entries, 0..) |entry, index| {
        if (index > std.math.maxInt(u16)) return PacketScaffoldError.InvalidPacket;
        if (entry.tile_index != @as(u16, @intCast(index))) return PacketScaffoldError.InvalidPacket;
        if (entry.tile_part_index != 0 or entry.tile_part_count != 1) return PacketScaffoldError.InvalidPacket;
    }
}

pub const TilePartTlmPlan = struct {
    allocator: std.mem.Allocator,
    entries: []TilePartTlmEntry,

    pub fn deinit(self: *TilePartTlmPlan) void {
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn payloadBytes(self: TilePartTlmPlan) !usize {
        return std.math.mul(usize, self.entries.len, tile_part_tlm_entry_bytes);
    }

    pub fn singleSegmentMarkerBytes(self: TilePartTlmPlan) !usize {
        const payload_bytes = try self.payloadBytes();
        const ltlm = try std.math.add(usize, 4, payload_bytes);
        if (ltlm > std.math.maxInt(u16)) return PacketScaffoldError.InvalidPacket;
        return try std.math.add(usize, 2, ltlm);
    }
};

pub const TilePartMarker = enum(u16) {
    soc = 0xff4f,
    sot = 0xff90,
    sop = 0xff91,
    eph = 0xff92,
    sod = 0xff93,
    tlm = 0xff55,
    plt = 0xff58,
    eoc = 0xffd9,
};

pub const TilePartPltEntry = struct {
    tile_index: u16,
    tile_part_index: u8,
    first_packet: usize,
    packet_count: usize,
    marker_bytes: usize,
};

pub const TilePartPltPlan = struct {
    allocator: std.mem.Allocator,
    entries: []TilePartPltEntry,
    packet_lengths: []u32,

    pub fn deinit(self: *TilePartPltPlan) void {
        self.allocator.free(self.packet_lengths);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn packetLengthsForEntry(self: TilePartPltPlan, entry_index: usize) ![]const u32 {
        if (entry_index >= self.entries.len) return PacketScaffoldError.InvalidPacket;
        const entry = self.entries[entry_index];
        const end = try std.math.add(usize, entry.first_packet, entry.packet_count);
        if (end > self.packet_lengths.len) return PacketScaffoldError.InvalidPacket;
        return self.packet_lengths[entry.first_packet..end];
    }

    pub fn totalPackets(self: TilePartPltPlan) !usize {
        var total: usize = 0;
        for (self.entries) |entry| {
            total = try std.math.add(usize, total, entry.packet_count);
        }
        return total;
    }

    pub fn totalMarkerBytes(self: TilePartPltPlan) !usize {
        var total: usize = 0;
        for (self.entries) |entry| {
            total = try std.math.add(usize, total, entry.marker_bytes);
        }
        return total;
    }
};

const TileGridEncodeJob = struct {
    allocator: std.mem.Allocator,
    source: image.RgbImage,
    grid: tile_grid.Grid,
    tile_order: []const usize,
    requested_levels: u8,
    options: PacketScaffoldOptions,
    style: ebcot.CodeBlockStyle,
    tiles: []TileRpclEncodeArtifacts,
    initialized: []bool,
    next_tile: *std.atomic.Value(usize),
    failed: *std.atomic.Value(bool),
    err: ?anyerror = null,
};

const TileWorkItem = struct {
    index: usize,
    cost: u64,
};

pub const RpclPacketBandGroups = struct {
    allocator: std.mem.Allocator,
    packet: packet_plan.Packet,
    groups: []RpclPacketBandGroupEntry,
    local_block_indexes: []usize,

    pub fn deinit(self: *RpclPacketBandGroups) void {
        self.allocator.free(self.local_block_indexes);
        self.allocator.free(self.groups);
        self.* = undefined;
    }

    pub fn groupLocalBlockIndexes(self: RpclPacketBandGroups, group_index: usize) ![]const usize {
        if (group_index >= self.groups.len) return PacketScaffoldError.InvalidPacket;
        const group = self.groups[group_index];
        const end = try std.math.add(usize, group.first_index, group.index_count);
        if (end > self.local_block_indexes.len) return PacketScaffoldError.InvalidPacket;
        return self.local_block_indexes[group.first_index..end];
    }

    pub fn encodedLayerBlocksForGroup(
        self: RpclPacketBandGroups,
        allocator: std.mem.Allocator,
        scaffold: PacketScaffold,
        catalog: EncodedBlockCatalog,
        group_index: usize,
        bit_depth: u8,
    ) ![]t2.EncodedLayerBlock {
        if (self.packet.component >= component_count) return PacketScaffoldError.InvalidPacket;
        if (catalog.component_block_count != scaffold.blocks.len) return PacketScaffoldError.InvalidComponentBlock;
        const group = if (group_index < self.groups.len) self.groups[group_index] else return PacketScaffoldError.InvalidPacket;
        const local_indexes = try self.groupLocalBlockIndexes(group_index);
        const blocks = try allocator.alloc(t2.EncodedLayerBlock, local_indexes.len);
        errdefer allocator.free(blocks);

        const component_offset = @as(usize, self.packet.component) * catalog.component_block_count;
        for (local_indexes, blocks) |local_index, *out_block| {
            if (local_index >= scaffold.blocks.len) return PacketScaffoldError.InvalidPacket;
            if (scaffold.blocks[local_index].band_index != group.band_index) return PacketScaffoldError.InvalidPacket;
            const catalog_index = component_offset + local_index;
            if (catalog_index >= catalog.blocks.len) return PacketScaffoldError.InvalidPacket;
            const encoded = catalog.blocks[catalog_index];
            const nominal_bitplanes = try reversible53NominalBitplanes(bit_depth, encoded.job.band.kind);
            out_block.* = try encoded.asEncodedLayerBlock(scaffold, nominal_bitplanes);
        }

        try normalizePacketGroupLocations(blocks);
        return blocks;
    }
};

pub const RpclPacketIndex = struct {
    allocator: std.mem.Allocator,
    entries: []RpclPacketIndexEntry,
    block_indexes: []usize,

    pub fn deinit(self: *RpclPacketIndex) void {
        self.allocator.free(self.block_indexes);
        self.allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn entry(self: RpclPacketIndex, packet_sequence: u64) !RpclPacketIndexEntry {
        const index = std.math.cast(usize, packet_sequence) orelse return PacketScaffoldError.InvalidPacket;
        if (index >= self.entries.len) return PacketScaffoldError.InvalidPacket;
        const result = self.entries[index];
        if (result.packet.sequence != packet_sequence) return PacketScaffoldError.InvalidPacket;
        return result;
    }

    pub fn blockIndexes(self: RpclPacketIndex, packet_sequence: u64) ![]const usize {
        const packet_entry = try self.entry(packet_sequence);
        const end = try std.math.add(usize, packet_entry.first_index, packet_entry.index_count);
        if (end > self.block_indexes.len) return PacketScaffoldError.InvalidPacket;
        return self.block_indexes[packet_entry.first_index..end];
    }

    pub fn catalogIndexesForPacket(
        self: RpclPacketIndex,
        allocator: std.mem.Allocator,
        catalog: EncodedBlockCatalog,
        packet_sequence: u64,
    ) ![]usize {
        const packet_entry = try self.entry(packet_sequence);
        if (packet_entry.packet.component >= component_count) return PacketScaffoldError.InvalidPacket;
        const local_indexes = try self.blockIndexes(packet_sequence);
        const indexes = try allocator.alloc(usize, local_indexes.len);
        errdefer allocator.free(indexes);

        const component_offset = @as(usize, packet_entry.packet.component) * catalog.component_block_count;
        for (local_indexes, indexes) |local_index, *out_index| {
            if (local_index >= catalog.component_block_count) return PacketScaffoldError.InvalidPacket;
            out_index.* = component_offset + local_index;
        }
        return indexes;
    }

    pub fn bandGroupsForPacket(
        self: RpclPacketIndex,
        allocator: std.mem.Allocator,
        scaffold: PacketScaffold,
        packet_sequence: u64,
    ) !RpclPacketBandGroups {
        const packet_entry = try self.entry(packet_sequence);
        const local_indexes = try self.blockIndexes(packet_sequence);

        var summaries: [max_rpcl_packet_band_groups]struct {
            band_index: usize = 0,
            count: usize = 0,
            active: bool = false,
        } = undefined;
        for (&summaries) |*summary| summary.* = .{};

        var group_count: usize = 0;
        for (local_indexes) |local_index| {
            if (local_index >= scaffold.blocks.len) return PacketScaffoldError.InvalidPacket;
            const band_index = scaffold.blocks[local_index].band_index;
            var found: ?usize = null;
            for (summaries[0..group_count], 0..) |summary, index| {
                if (summary.active and summary.band_index == band_index) {
                    found = index;
                    break;
                }
            }
            const summary_index = found orelse blk: {
                if (group_count >= summaries.len) return PacketScaffoldError.InvalidPacket;
                summaries[group_count] = .{ .band_index = band_index, .count = 0, .active = true };
                group_count += 1;
                break :blk group_count - 1;
            };
            summaries[summary_index].count += 1;
        }

        const groups = try allocator.alloc(RpclPacketBandGroupEntry, group_count);
        errdefer allocator.free(groups);
        var first_index: usize = 0;
        for (summaries[0..group_count], groups) |summary, *group| {
            group.* = .{
                .band_index = summary.band_index,
                .first_index = first_index,
                .index_count = summary.count,
            };
            first_index += summary.count;
        }

        const grouped_indexes = try allocator.alloc(usize, local_indexes.len);
        errdefer allocator.free(grouped_indexes);
        const fill_counts = try allocator.alloc(usize, group_count);
        defer allocator.free(fill_counts);
        @memset(fill_counts, 0);

        for (local_indexes) |local_index| {
            const band_index = scaffold.blocks[local_index].band_index;
            for (groups, 0..) |group, group_index| {
                if (group.band_index != band_index) continue;
                const out_index = group.first_index + fill_counts[group_index];
                grouped_indexes[out_index] = local_index;
                fill_counts[group_index] += 1;
                break;
            }
        }
        for (groups, fill_counts) |group, filled| {
            if (filled != group.index_count) return PacketScaffoldError.InvalidPacket;
        }

        return .{
            .allocator = allocator,
            .packet = packet_entry.packet,
            .groups = groups,
            .local_block_indexes = grouped_indexes,
        };
    }
};

pub const ComponentBlockIterator = struct {
    scaffold: PacketScaffold,
    next_index: usize = 0,

    pub fn next(self: *ComponentBlockIterator) !?ComponentBlock {
        const count = try self.scaffold.componentBlockCount();
        if (self.next_index >= count) return null;
        const block = try self.scaffold.componentBlock(self.next_index);
        self.next_index += 1;
        return block;
    }
};

const component_count: usize = 3;
const max_rpcl_packet_band_groups: usize = 3;
const tile_part_tlm_entry_bytes: usize = 6;
const tile_part_tlm_stlm_u16_u32: u8 = 0x60;

fn componentPlane(rct_tile: RctTile, component: u8) ?[]i32 {
    return switch (component) {
        0 => rct_tile.planes.y,
        1 => rct_tile.planes.cb,
        2 => rct_tile.planes.cr,
        else => null,
    };
}

fn validateRectInPlane(rect: subband.Rect, width: usize, height: usize) !void {
    if (rect.width == 0 or rect.height == 0) return PacketScaffoldError.InvalidComponentBlock;
    const end_x = std.math.add(usize, rect.x, rect.width) catch return PacketScaffoldError.InvalidComponentBlock;
    const end_y = std.math.add(usize, rect.y, rect.height) catch return PacketScaffoldError.InvalidComponentBlock;
    if (end_x > width or end_y > height) return PacketScaffoldError.InvalidPlane;
}

pub fn reversible53NominalBitplanes(bit_depth: u8, kind: subband.Kind) !u8 {
    const gain: u8 = switch (kind) {
        .ll => 0,
        .hl, .lh => 1,
        .hh => 2,
    };
    if (bit_depth == 0 or bit_depth > 31 - gain - 1) return PacketScaffoldError.InvalidLayer;
    return bit_depth + gain + 1;
}

fn markCoveredBlock(covered: []bool, stride: usize, rect: subband.Rect) !void {
    try validateRectInPlane(rect, stride, covered.len / stride);
    for (0..rect.height) |row| {
        const start = (rect.y + row) * stride + rect.x;
        for (covered[start..][0..rect.width]) |*slot| {
            if (slot.*) return PacketScaffoldError.InvalidComponentBlock;
            slot.* = true;
        }
    }
}

fn copyDecodedBlockIntoPlane(rct_tile: RctTile, job: ComponentBlock, decoded: []const i32) !void {
    const plane = componentPlane(rct_tile, job.component) orelse return PacketScaffoldError.InvalidComponentBlock;
    try validateRectInPlane(job.rect, rct_tile.planes.width, rct_tile.planes.height);
    if (decoded.len != try std.math.mul(usize, job.rect.width, job.rect.height)) {
        return PacketScaffoldError.InvalidComponentBlock;
    }

    for (0..job.rect.height) |row| {
        const dst_start = (job.rect.y + row) * rct_tile.planes.width + job.rect.x;
        const src_start = row * job.rect.width;
        @memcpy(plane[dst_start..][0..job.rect.width], decoded[src_start..][0..job.rect.width]);
    }
}

fn normalizePacketGroupLocations(blocks: []t2.EncodedLayerBlock) !void {
    if (blocks.len == 0) return;
    var min_x: usize = std.math.maxInt(usize);
    var min_y: usize = std.math.maxInt(usize);
    for (blocks) |block| {
        min_x = @min(min_x, block.location.leaf_x);
        min_y = @min(min_y, block.location.leaf_y);
    }
    var max_x: usize = 0;
    var max_y: usize = 0;
    for (blocks) |*block| {
        block.location.leaf_x -= min_x;
        block.location.leaf_y -= min_y;
        max_x = @max(max_x, block.location.leaf_x);
        max_y = @max(max_y, block.location.leaf_y);
    }

    std.mem.sort(t2.EncodedLayerBlock, blocks, {}, encodedLayerBlockLocationLessThan);
    const leaves_x = try std.math.add(usize, max_x, 1);
    const leaves_y = try std.math.add(usize, max_y, 1);
    const expected_count = try std.math.mul(usize, leaves_x, leaves_y);
    if (expected_count != blocks.len) return PacketScaffoldError.InvalidPacket;
    for (blocks, 0..) |block, index| {
        if (block.location.leaf_x != index % leaves_x or block.location.leaf_y != index / leaves_x) {
            return PacketScaffoldError.InvalidPacket;
        }
    }
}

fn encodedLayerBlockLocationLessThan(_: void, lhs: t2.EncodedLayerBlock, rhs: t2.EncodedLayerBlock) bool {
    if (lhs.location.leaf_y != rhs.location.leaf_y) return lhs.location.leaf_y < rhs.location.leaf_y;
    return lhs.location.leaf_x < rhs.location.leaf_x;
}

fn tileWorkItemGreaterThan(_: void, lhs: TileWorkItem, rhs: TileWorkItem) bool {
    if (lhs.cost != rhs.cost) return lhs.cost > rhs.cost;
    return lhs.index < rhs.index;
}

fn tileWorkCost(tile: tile_grid.Tile) u64 {
    return @as(u64, tile.rect.width()) * @as(u64, tile.rect.height());
}

fn framedPacketByteCount(packet_lengths: []const u32, options: TilePartLayoutOptions) !usize {
    var total: usize = 0;
    for (packet_lengths) |packet_length| {
        total = try std.math.add(usize, total, try framedPacketLength(packet_length, options));
    }
    return total;
}

fn framedPacketLength(packet_length: u32, options: TilePartLayoutOptions) !usize {
    var result: usize = packet_length;
    if (options.sop) result = try std.math.add(usize, result, 6);
    if (options.eph) result = try std.math.add(usize, result, 2);
    return result;
}

fn rawPacketLengthFromFramed(framed_length: u32, options: TilePartLayoutOptions) !usize {
    var overhead: usize = 0;
    if (options.sop) overhead += 6;
    if (options.eph) overhead += 2;
    if (framed_length <= overhead) return PacketScaffoldError.InvalidPacket;
    return @as(usize, @intCast(framed_length)) - overhead;
}

fn pltBytesForTilePacketLengths(packet_lengths: []const u32, options: TilePartLayoutOptions) !usize {
    if (packet_lengths.len == 0) return 0;
    var bytes: usize = 5;
    var segment_payload_bytes: usize = 0;
    var marker_count: usize = 1;

    for (packet_lengths) |packet_length| {
        const encoded_len = pltLengthByteCount(try framedPacketLength(packet_length, options));
        if (segment_payload_bytes + encoded_len > 65532) {
            marker_count += 1;
            if (marker_count > 256) return PacketScaffoldError.InvalidPacket;
            bytes = try std.math.add(usize, bytes, 5);
            segment_payload_bytes = 0;
        }
        segment_payload_bytes += encoded_len;
        bytes = try std.math.add(usize, bytes, encoded_len);
    }

    return bytes;
}

fn pltBytesForFramedPacketLengths(packet_lengths: []const u32) !usize {
    if (packet_lengths.len == 0) return 0;
    var bytes: usize = 5;
    var segment_payload_bytes: usize = 0;
    var marker_count: usize = 1;

    for (packet_lengths) |packet_length| {
        const encoded_len = pltLengthByteCount(packet_length);
        if (segment_payload_bytes + encoded_len > 65532) {
            marker_count += 1;
            if (marker_count > 256) return PacketScaffoldError.InvalidPacket;
            bytes = try std.math.add(usize, bytes, 5);
            segment_payload_bytes = 0;
        }
        segment_payload_bytes += encoded_len;
        bytes = try std.math.add(usize, bytes, encoded_len);
    }

    return bytes;
}

fn sumPacketLengths(packet_lengths: []const u32) !usize {
    var total: usize = 0;
    for (packet_lengths) |packet_length| {
        total = try std.math.add(usize, total, packet_length);
    }
    return total;
}

fn appendTilePartSodPayload(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    stream: TileRpclPacketStream,
    options: TilePartLayoutOptions,
) !void {
    if (stream.bytes.len != try stream.totalPacketBytes()) return PacketScaffoldError.InvalidPacket;

    var packet_offset: usize = 0;
    for (stream.packet_lengths, 0..) |packet_length_u32, packet_index| {
        const packet_length = std.math.cast(usize, packet_length_u32) orelse return PacketScaffoldError.InvalidPacket;
        const packet_end = try std.math.add(usize, packet_offset, packet_length);
        if (packet_end > stream.bytes.len) return PacketScaffoldError.InvalidPacket;

        if (options.sop) {
            try appendU16Be(allocator, out, @intFromEnum(TilePartMarker.sop));
            try appendU16Be(allocator, out, 4);
            try appendU16Be(allocator, out, @as(u16, @intCast(packet_index & 0xffff)));
        }
        try out.appendSlice(allocator, stream.bytes[packet_offset..packet_end]);
        if (options.eph) {
            try appendU16Be(allocator, out, @intFromEnum(TilePartMarker.eph));
        }
        packet_offset = packet_end;
    }

    if (packet_offset != stream.bytes.len) return PacketScaffoldError.InvalidPacket;
}

fn flushPltMarkerSegment(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    marker_index: u8,
    lengths: []const u8,
) !void {
    if (lengths.len == 0 or lengths.len > 65532) return PacketScaffoldError.InvalidPacket;
    try appendU16Be(allocator, out, @intFromEnum(TilePartMarker.plt));
    const lplt = try std.math.add(u16, 3, @as(u16, @intCast(lengths.len)));
    try appendU16Be(allocator, out, lplt);
    try out.append(allocator, marker_index);
    try out.appendSlice(allocator, lengths);
}

fn appendPltLength(allocator: std.mem.Allocator, out: *std.ArrayList(u8), length: u32) !void {
    var bytes: [5]u8 = undefined;
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

fn tilePartSodOffset(tile_part: []const u8) !usize {
    if (tile_part.len < 14) return PacketScaffoldError.InvalidPacket;
    var cursor: usize = 12;
    while (cursor < tile_part.len) {
        if (tile_part.len - cursor < 2) return PacketScaffoldError.InvalidPacket;
        const marker = readU16Be(tile_part, cursor);
        if (marker == @intFromEnum(TilePartMarker.sod)) {
            if (cursor + 2 > tile_part.len) return PacketScaffoldError.InvalidPacket;
            return cursor;
        }
        if (marker != @intFromEnum(TilePartMarker.plt)) return PacketScaffoldError.InvalidPacket;
        if (tile_part.len - cursor < 4) return PacketScaffoldError.InvalidPacket;
        const length = readU16Be(tile_part, cursor + 2);
        if (length < 3) return PacketScaffoldError.InvalidPacket;
        const total = try std.math.add(usize, 2, @as(usize, length));
        if (tile_part.len - cursor < total) return PacketScaffoldError.InvalidPacket;
        cursor += total;
    }
    return PacketScaffoldError.InvalidPacket;
}

fn validateTilePartContainsSod(tile_part: []const u8) !void {
    _ = try tilePartSodOffset(tile_part);
}

fn pltLengthByteCount(length: usize) usize {
    var value = length >> 7;
    var count: usize = 1;
    while (value > 0) : (value >>= 7) count += 1;
    return count;
}

pub fn forwardRctTile(
    allocator: std.mem.Allocator,
    source: image.RgbImage,
    tile: tile_grid.Tile,
) !RctTile {
    var rgb_tile = try tile_grid.extractRgbTile(allocator, source, tile.rect);
    defer rgb_tile.deinit();

    const planes = try color.forwardRct(allocator, rgb_tile);
    return .{
        .tile = tile,
        .planes = planes,
    };
}

pub fn inverseRctTileInto(
    allocator: std.mem.Allocator,
    destination: image.RgbImage,
    rct_tile: RctTile,
) !void {
    var rgb_tile = try color.inverseRct(allocator, rct_tile.planes);
    defer rgb_tile.deinit();
    try tile_grid.copyRgbTileInto(destination, rct_tile.tile.rect, rgb_tile);
}

pub fn forward53TileInPlace(allocator: std.mem.Allocator, rct_tile: *RctTile, requested_levels: u8) !u8 {
    const width = rct_tile.planes.width;
    const height = rct_tile.planes.height;
    var workspace = try wavelet_int.Workspace.init(allocator, @max(width, height));
    defer workspace.deinit();

    const y_levels = try wavelet_int.forward53WithWorkspace(&workspace, rct_tile.planes.y, width, height, requested_levels);
    const cb_levels = try wavelet_int.forward53WithWorkspace(&workspace, rct_tile.planes.cb, width, height, requested_levels);
    const cr_levels = try wavelet_int.forward53WithWorkspace(&workspace, rct_tile.planes.cr, width, height, requested_levels);
    if (cb_levels != y_levels or cr_levels != y_levels) return wavelet_int.TransformError.InvalidDimensions;
    return y_levels;
}

pub fn inverse53TileInPlace(allocator: std.mem.Allocator, rct_tile: *RctTile, levels: u8) !void {
    const width = rct_tile.planes.width;
    const height = rct_tile.planes.height;
    var workspace = try wavelet_int.Workspace.init(allocator, @max(width, height));
    defer workspace.deinit();

    try wavelet_int.inverse53WithWorkspace(&workspace, rct_tile.planes.y, width, height, levels);
    try wavelet_int.inverse53WithWorkspace(&workspace, rct_tile.planes.cb, width, height, levels);
    try wavelet_int.inverse53WithWorkspace(&workspace, rct_tile.planes.cr, width, height, levels);
}

pub fn buildPacketScaffold(
    allocator: std.mem.Allocator,
    rct_tile: RctTile,
    levels: u8,
    options: PacketScaffoldOptions,
) !PacketScaffold {
    if (options.layers == 0 or options.precincts.len == 0) return packet_plan.PacketPlanError.InvalidDimensions;
    const width = rct_tile.planes.width;
    const height = rct_tile.planes.height;
    if (width != rct_tile.tile.rect.width() or height != rct_tile.tile.rect.height()) {
        return packet_plan.PacketPlanError.InvalidDimensions;
    }

    const plan = try packet_plan.rpclSingleTile(width, height, levels, component_count, options.layers, options.precincts);
    const bands = try subband.makeBands(allocator, width, height, levels);
    errdefer allocator.free(bands);
    const blocks = try subband.makeCodeBlocks(allocator, bands, options.block_width, options.block_height);
    errdefer allocator.free(blocks);

    return .{
        .allocator = allocator,
        .tile = rct_tile.tile,
        .levels = levels,
        .layers = options.layers,
        .block_width = options.block_width,
        .block_height = options.block_height,
        .plan = plan,
        .bands = bands,
        .blocks = blocks,
    };
}

pub fn encodeComponentBlockIsoMq(
    allocator: std.mem.Allocator,
    view: ComponentBlockView,
    style: ebcot.CodeBlockStyle,
) !EncodedComponentBlock {
    var actual_style = style;
    actual_style.band_kind = view.job.band.kind;
    const segment = if (actual_style.terminate_all)
        try ebcot.encodeCodeBlockSegmentIsoMqTerminatedWithStyle(
            allocator,
            view.plane,
            view.stride,
            view.rect,
            actual_style,
        )
    else blk: {
        var scratch = ebcot.DirectBlockScratch.init(allocator);
        defer scratch.deinit();
        break :blk try ebcot.encodeCodeBlockSegmentDirectIsoScratchWithStyle(
            &scratch,
            view.plane,
            view.stride,
            view.rect,
            actual_style,
        );
    };
    return .{
        .job = view.job,
        .segment = segment,
    };
}

pub fn buildEncodedBlockCatalogIsoMq(
    allocator: std.mem.Allocator,
    scaffold: PacketScaffold,
    rct_tile: RctTile,
    style: ebcot.CodeBlockStyle,
) !EncodedBlockCatalog {
    const block_count = scaffold.blocks.len;
    const total_blocks = try scaffold.componentBlockCount();
    const blocks = try allocator.alloc(EncodedComponentBlock, total_blocks);
    errdefer allocator.free(blocks);

    var initialized: usize = 0;
    errdefer {
        for (blocks[0..initialized]) |*block| block.deinit(allocator);
    }

    var iterator = scaffold.componentBlockIterator();
    while (try iterator.next()) |job| {
        const view = try job.view(rct_tile);
        var encoded = try encodeComponentBlockIsoMq(allocator, view, style);
        var moved = false;
        errdefer if (!moved) encoded.deinit(allocator);
        encoded.layers = try computeLayerTruncations(allocator, encoded.segment, scaffold.layers);
        blocks[initialized] = encoded;
        moved = true;
        initialized += 1;
    }
    if (initialized != total_blocks) return PacketScaffoldError.InvalidComponentBlock;

    return .{
        .allocator = allocator,
        .tile = scaffold.tile,
        .component_block_count = block_count,
        .blocks = blocks,
    };
}

pub fn validateEncodedBlockCatalogCoversTile(
    allocator: std.mem.Allocator,
    scaffold: PacketScaffold,
    catalog: EncodedBlockCatalog,
) !void {
    if (catalog.tile.index != scaffold.tile.index) return PacketScaffoldError.InvalidComponentBlock;
    if (catalog.component_block_count != scaffold.blocks.len) return PacketScaffoldError.InvalidComponentBlock;
    if (catalog.blocks.len != try scaffold.componentBlockCount()) return PacketScaffoldError.InvalidComponentBlock;

    const pixels = try std.math.mul(usize, scaffold.tile.rect.width(), scaffold.tile.rect.height());
    for (0..component_count) |component| {
        const covered = try allocator.alloc(bool, pixels);
        defer allocator.free(covered);
        @memset(covered, false);

        var block_count: usize = 0;
        for (catalog.blocks) |encoded| {
            if (encoded.job.component != component) continue;
            if (encoded.job.tile.index != scaffold.tile.index) return PacketScaffoldError.InvalidComponentBlock;
            const expected_job = try scaffold.componentBlockAt(encoded.job.component, encoded.job.block_index);
            if (expected_job.band_index != encoded.job.band_index or
                expected_job.rect.x != encoded.job.rect.x or
                expected_job.rect.y != encoded.job.rect.y or
                expected_job.rect.width != encoded.job.rect.width or
                expected_job.rect.height != encoded.job.rect.height)
            {
                return PacketScaffoldError.InvalidComponentBlock;
            }
            try markCoveredBlock(covered, scaffold.tile.rect.width(), encoded.job.rect);
            block_count += 1;
        }
        if (block_count != scaffold.blocks.len) return PacketScaffoldError.InvalidComponentBlock;
        for (covered) |is_covered| {
            if (!is_covered) return PacketScaffoldError.InvalidComponentBlock;
        }
    }
}

pub fn decodeEncodedBlockCatalogIsoMqToRctTile(
    allocator: std.mem.Allocator,
    scaffold: PacketScaffold,
    catalog: EncodedBlockCatalog,
    bit_depth: u8,
    style: ebcot.CodeBlockStyle,
) !RctTile {
    try validateEncodedBlockCatalogCoversTile(allocator, scaffold, catalog);
    if (style.bypass) return PacketScaffoldError.InvalidPacket;

    const pixels = try std.math.mul(usize, scaffold.tile.rect.width(), scaffold.tile.rect.height());
    const y = try allocator.alloc(i32, pixels);
    var y_moved = false;
    errdefer if (!y_moved) allocator.free(y);
    const cb = try allocator.alloc(i32, pixels);
    var cb_moved = false;
    errdefer if (!cb_moved) allocator.free(cb);
    const cr = try allocator.alloc(i32, pixels);
    var cr_moved = false;
    errdefer if (!cr_moved) allocator.free(cr);
    @memset(y, 0);
    @memset(cb, 0);
    @memset(cr, 0);

    var rct_tile = RctTile{
        .tile = scaffold.tile,
        .planes = .{
            .allocator = allocator,
            .width = scaffold.tile.rect.width(),
            .height = scaffold.tile.rect.height(),
            .bit_depth = bit_depth,
            .y = y,
            .cb = cb,
            .cr = cr,
        },
    };
    y_moved = true;
    cb_moved = true;
    cr_moved = true;
    errdefer rct_tile.deinit();

    var scratch = ebcot.DecodeBlockScratch.init(allocator);
    defer scratch.deinit();
    for (catalog.blocks) |encoded| {
        var actual_style = style;
        actual_style.band_kind = encoded.job.band.kind;
        const decoded = try ebcot.decodeCodeBlockPayloadContinuousInferredIsoMqScratchWithStyle(
            &scratch,
            encoded.segment.bitplanes,
            encoded.segment.pass_count,
            encoded.segment.bytes,
            encoded.job.rect.width,
            encoded.job.rect.height,
            actual_style,
        );
        defer allocator.free(decoded);
        try copyDecodedBlockIntoPlane(rct_tile, encoded.job, decoded);
    }

    return rct_tile;
}

pub fn reconstructTileRpclEncodeArtifactsIsoMqInto(
    allocator: std.mem.Allocator,
    destination: image.RgbImage,
    artifacts: TileRpclEncodeArtifacts,
    style: ebcot.CodeBlockStyle,
) !void {
    var rct_tile = try decodeEncodedBlockCatalogIsoMqToRctTile(allocator, artifacts.scaffold, artifacts.catalog, artifacts.bit_depth, style);
    defer rct_tile.deinit();
    try inverse53TileInPlace(allocator, &rct_tile, artifacts.levels);
    try inverseRctTileInto(allocator, destination, rct_tile);
}

pub fn reconstructTileGridRpclEncodeArtifactsIsoMqInto(
    allocator: std.mem.Allocator,
    destination: image.RgbImage,
    artifacts: TileRpclEncodeGridArtifacts,
    style: ebcot.CodeBlockStyle,
) !void {
    if (destination.width != artifacts.grid.params.xsiz or destination.height != artifacts.grid.params.ysiz) {
        return tile_grid.TileGridError.InvalidImage;
    }
    for (artifacts.tiles) |tile_artifacts| {
        try reconstructTileRpclEncodeArtifactsIsoMqInto(allocator, destination, tile_artifacts, style);
    }
}

pub fn buildTileRpclEncodeArtifactsIsoMq(
    allocator: std.mem.Allocator,
    source: image.RgbImage,
    tile: tile_grid.Tile,
    requested_levels: u8,
    options: PacketScaffoldOptions,
    style: ebcot.CodeBlockStyle,
) !TileRpclEncodeArtifacts {
    var rct_tile = try forwardRctTile(allocator, source, tile);
    defer rct_tile.deinit();

    const bit_depth = rct_tile.planes.bit_depth;
    const levels = try forward53TileInPlace(allocator, &rct_tile, requested_levels);

    var scaffold = try buildPacketScaffold(allocator, rct_tile, levels, options);
    var scaffold_moved = false;
    errdefer if (!scaffold_moved) scaffold.deinit();

    var catalog = try buildEncodedBlockCatalogIsoMq(allocator, scaffold, rct_tile, style);
    var catalog_moved = false;
    errdefer if (!catalog_moved) catalog.deinit();
    try validateEncodedBlockCatalogCoversTile(allocator, scaffold, catalog);

    var index = try buildRpclPacketIndex(allocator, scaffold);
    var index_moved = false;
    errdefer if (!index_moved) index.deinit();

    var stream = try buildTileRpclPacketStream(allocator, scaffold, catalog, index, bit_depth);
    var stream_moved = false;
    errdefer if (!stream_moved) stream.deinit();

    try validateTileRpclPacketStream(allocator, scaffold, catalog, index, stream, bit_depth);

    scaffold_moved = true;
    catalog_moved = true;
    index_moved = true;
    stream_moved = true;
    return .{
        .allocator = allocator,
        .tile = tile,
        .bit_depth = bit_depth,
        .levels = levels,
        .scaffold = scaffold,
        .catalog = catalog,
        .index = index,
        .stream = stream,
    };
}

pub fn buildTileGridRpclEncodeArtifactsIsoMq(
    allocator: std.mem.Allocator,
    source: image.RgbImage,
    grid: tile_grid.Grid,
    requested_levels: u8,
    options: PacketScaffoldOptions,
    style: ebcot.CodeBlockStyle,
) !TileRpclEncodeGridArtifacts {
    if (grid.params.xsiz != source.width or grid.params.ysiz != source.height) {
        return tile_grid.TileGridError.InvalidImage;
    }
    const tile_count = std.math.cast(usize, grid.tileCount()) orelse return tile_grid.TileGridError.ImageTooLarge;
    const tiles = try allocator.alloc(TileRpclEncodeArtifacts, tile_count);
    errdefer allocator.free(tiles);

    var initialized: usize = 0;
    errdefer {
        for (tiles[0..initialized]) |*tile| tile.deinit();
    }

    var iterator = grid.iterator();
    while (try iterator.next()) |tile| {
        if (initialized >= tiles.len) return PacketScaffoldError.InvalidPacket;
        tiles[initialized] = try buildTileRpclEncodeArtifactsIsoMq(
            allocator,
            source,
            tile,
            requested_levels,
            options,
            style,
        );
        initialized += 1;
    }
    if (initialized != tiles.len) return PacketScaffoldError.InvalidPacket;

    return .{
        .allocator = allocator,
        .grid = grid,
        .tiles = tiles,
    };
}

pub fn buildTileGridRpclEncodeArtifactsIsoMqParallel(
    allocator: std.mem.Allocator,
    source: image.RgbImage,
    grid: tile_grid.Grid,
    requested_levels: u8,
    options: PacketScaffoldOptions,
    style: ebcot.CodeBlockStyle,
    worker_count: usize,
) !TileRpclEncodeGridArtifacts {
    if (worker_count <= 1 or grid.tileCount() <= 1) {
        return buildTileGridRpclEncodeArtifactsIsoMq(
            allocator,
            source,
            grid,
            requested_levels,
            options,
            style,
        );
    }
    if (grid.params.xsiz != source.width or grid.params.ysiz != source.height) {
        return tile_grid.TileGridError.InvalidImage;
    }

    const tile_count = std.math.cast(usize, grid.tileCount()) orelse return tile_grid.TileGridError.ImageTooLarge;
    const active_workers = @min(worker_count, tile_count);
    const tiles = try allocator.alloc(TileRpclEncodeArtifacts, tile_count);
    errdefer allocator.free(tiles);
    const initialized = try allocator.alloc(bool, tile_count);
    defer allocator.free(initialized);
    @memset(initialized, false);
    errdefer deinitInitializedTileArtifacts(tiles, initialized);

    const tile_order = try buildTileGridWorkOrder(allocator, grid);
    defer allocator.free(tile_order);

    var next_tile = std.atomic.Value(usize).init(0);
    var failed = std.atomic.Value(bool).init(false);

    const jobs = try allocator.alloc(TileGridEncodeJob, active_workers);
    defer allocator.free(jobs);
    for (jobs) |*job| {
        job.* = .{
            .allocator = allocator,
            .source = source,
            .grid = grid,
            .tile_order = tile_order,
            .requested_levels = requested_levels,
            .options = options,
            .style = style,
            .tiles = tiles,
            .initialized = initialized,
            .next_tile = &next_tile,
            .failed = &failed,
        };
    }

    const spawn_count = active_workers - 1;
    const threads = try allocator.alloc(std.Thread, spawn_count);
    defer allocator.free(threads);
    var spawned: usize = 0;
    while (spawned < spawn_count) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, tileGridEncodeWorker, .{&jobs[spawned]}) catch |err| {
            failed.store(true, .release);
            for (threads[0..spawned]) |thread| thread.join();
            return err;
        };
    }
    tileGridEncodeWorker(&jobs[spawn_count]);
    for (threads[0..spawned]) |thread| thread.join();

    for (jobs) |job| {
        if (job.err) |err| return err;
    }
    for (initialized) |is_initialized| {
        if (!is_initialized) return PacketScaffoldError.InvalidPacket;
    }

    return .{
        .allocator = allocator,
        .grid = grid,
        .tiles = tiles,
    };
}

pub fn buildTileGridWorkOrder(
    allocator: std.mem.Allocator,
    grid: tile_grid.Grid,
) ![]usize {
    const tile_count = std.math.cast(usize, grid.tileCount()) orelse return tile_grid.TileGridError.ImageTooLarge;
    const items = try allocator.alloc(TileWorkItem, tile_count);
    defer allocator.free(items);

    for (items, 0..) |*item, index| {
        const tile = try grid.tile(@intCast(index));
        item.* = .{
            .index = index,
            .cost = tileWorkCost(tile),
        };
    }

    std.mem.sort(TileWorkItem, items, {}, tileWorkItemGreaterThan);

    const order = try allocator.alloc(usize, tile_count);
    errdefer allocator.free(order);
    for (items, order) |item, *out_index| out_index.* = item.index;
    return order;
}

pub fn buildTilePartLayoutForGridArtifacts(
    allocator: std.mem.Allocator,
    artifacts: TileRpclEncodeGridArtifacts,
    options: TilePartLayoutOptions,
) !TilePartLayout {
    const entries = try allocator.alloc(TilePartLayoutEntry, artifacts.tiles.len);
    errdefer allocator.free(entries);

    for (artifacts.tiles, entries) |tile_artifacts, *entry| {
        if (tile_artifacts.tile.index > std.math.maxInt(u16)) return PacketScaffoldError.InvalidPacket;
        const packet_count = tile_artifacts.packetCount();
        if (packet_count == 0) return PacketScaffoldError.InvalidPacket;
        const packet_bytes = try tile_artifacts.totalPacketBytes();
        const framed_packet_bytes = try framedPacketByteCount(
            tile_artifacts.stream.packet_lengths,
            options,
        );
        const plt_bytes = if (options.plt)
            try pltBytesForTilePacketLengths(tile_artifacts.stream.packet_lengths, options)
        else
            0;
        const tile_part_payload = try std.math.add(usize, framed_packet_bytes, plt_bytes);
        const psot_usize = try std.math.add(usize, 14, tile_part_payload);
        const psot = std.math.cast(u32, psot_usize) orelse return PacketScaffoldError.InvalidPacket;

        entry.* = .{
            .tile_index = @intCast(tile_artifacts.tile.index),
            .tile_part_index = 0,
            .tile_part_count = 1,
            .packet_count = packet_count,
            .packet_bytes = packet_bytes,
            .framed_packet_bytes = framed_packet_bytes,
            .plt_bytes = plt_bytes,
            .psot = psot,
        };
    }

    return .{
        .allocator = allocator,
        .entries = entries,
    };
}

pub fn buildTilePartTlmPlan(
    allocator: std.mem.Allocator,
    layout: TilePartLayout,
) !TilePartTlmPlan {
    const entries = try allocator.alloc(TilePartTlmEntry, layout.entries.len);
    errdefer allocator.free(entries);

    for (layout.entries, entries) |layout_entry, *tlm_entry| {
        if (layout_entry.tile_part_index != 0 or layout_entry.tile_part_count != 1) {
            return PacketScaffoldError.InvalidPacket;
        }
        tlm_entry.* = .{
            .tile_index = layout_entry.tile_index,
            .psot = layout_entry.psot,
        };
    }

    var plan = TilePartTlmPlan{
        .allocator = allocator,
        .entries = entries,
    };
    _ = try plan.singleSegmentMarkerBytes();
    return plan;
}

pub fn writeTilePartTlmMarkerSegment(
    allocator: std.mem.Allocator,
    plan: TilePartTlmPlan,
) ![]u8 {
    _ = try plan.singleSegmentMarkerBytes();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendU16Be(allocator, &out, @intFromEnum(TilePartMarker.tlm));
    const ltlm = try std.math.add(u16, 4, @as(u16, @intCast(plan.entries.len * tile_part_tlm_entry_bytes)));
    try appendU16Be(allocator, &out, ltlm);
    try out.append(allocator, 0);
    try out.append(allocator, tile_part_tlm_stlm_u16_u32);
    for (plan.entries) |entry| {
        try appendU16Be(allocator, &out, entry.tile_index);
        try appendU32Be(allocator, &out, entry.psot);
    }

    return out.toOwnedSlice(allocator);
}

pub fn buildTilePartPltPlan(
    allocator: std.mem.Allocator,
    artifacts: TileRpclEncodeGridArtifacts,
    layout: TilePartLayout,
    options: TilePartLayoutOptions,
) !TilePartPltPlan {
    if (artifacts.tiles.len != layout.entries.len) return PacketScaffoldError.InvalidPacket;
    const total_packets = try layout.totalPackets();
    const entries = try allocator.alloc(TilePartPltEntry, layout.entries.len);
    errdefer allocator.free(entries);
    const packet_lengths = try allocator.alloc(u32, total_packets);
    errdefer allocator.free(packet_lengths);

    var first_packet: usize = 0;
    for (artifacts.tiles, layout.entries, entries) |tile_artifacts, layout_entry, *entry| {
        if (layout_entry.tile_index != tile_artifacts.tile.index or
            layout_entry.packet_count != tile_artifacts.packetCount())
        {
            return PacketScaffoldError.InvalidPacket;
        }
        const packet_count = tile_artifacts.stream.packet_lengths.len;
        const end = try std.math.add(usize, first_packet, packet_count);
        if (end > packet_lengths.len) return PacketScaffoldError.InvalidPacket;
        for (tile_artifacts.stream.packet_lengths, packet_lengths[first_packet..end]) |packet_length, *out_length| {
            const framed_length = try framedPacketLength(packet_length, options);
            out_length.* = std.math.cast(u32, framed_length) orelse return PacketScaffoldError.InvalidPacket;
        }

        const marker_bytes = if (options.plt)
            try pltBytesForFramedPacketLengths(packet_lengths[first_packet..end])
        else
            0;
        if (marker_bytes != layout_entry.plt_bytes) return PacketScaffoldError.InvalidPacket;
        if (try sumPacketLengths(packet_lengths[first_packet..end]) != layout_entry.framed_packet_bytes) {
            return PacketScaffoldError.InvalidPacket;
        }

        entry.* = .{
            .tile_index = layout_entry.tile_index,
            .tile_part_index = layout_entry.tile_part_index,
            .first_packet = first_packet,
            .packet_count = packet_count,
            .marker_bytes = marker_bytes,
        };
        first_packet = end;
    }
    if (first_packet != packet_lengths.len) return PacketScaffoldError.InvalidPacket;

    return .{
        .allocator = allocator,
        .entries = entries,
        .packet_lengths = packet_lengths,
    };
}

pub fn writeTilePartPltMarkerSegmentsForEntry(
    allocator: std.mem.Allocator,
    plan: TilePartPltPlan,
    entry_index: usize,
) ![]u8 {
    const packet_lengths = try plan.packetLengthsForEntry(entry_index);
    if (packet_lengths.len == 0) return PacketScaffoldError.InvalidPacket;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var marker_index: u8 = 0;
    var segment: std.ArrayList(u8) = .empty;
    defer segment.deinit(allocator);

    for (packet_lengths) |packet_length| {
        const encoded_len = pltLengthByteCount(packet_length);
        if (segment.items.len + encoded_len > 65532) {
            try flushPltMarkerSegment(allocator, &out, marker_index, segment.items);
            if (marker_index == std.math.maxInt(u8)) return PacketScaffoldError.InvalidPacket;
            marker_index += 1;
            segment.clearRetainingCapacity();
        }
        try appendPltLength(allocator, &segment, packet_length);
    }
    if (segment.items.len > 0) {
        try flushPltMarkerSegment(allocator, &out, marker_index, segment.items);
    }

    return out.toOwnedSlice(allocator);
}

pub fn writeTilePartBytesForEntry(
    allocator: std.mem.Allocator,
    artifacts: TileRpclEncodeGridArtifacts,
    layout: TilePartLayout,
    plt_plan: TilePartPltPlan,
    entry_index: usize,
    options: TilePartLayoutOptions,
) ![]u8 {
    if (artifacts.tiles.len != layout.entries.len or layout.entries.len != plt_plan.entries.len) {
        return PacketScaffoldError.InvalidPacket;
    }
    if (entry_index >= layout.entries.len) return PacketScaffoldError.InvalidPacket;

    const tile_artifacts = artifacts.tiles[entry_index];
    const layout_entry = layout.entries[entry_index];
    const plt_entry = plt_plan.entries[entry_index];
    if (layout_entry.tile_index != tile_artifacts.tile.index or
        layout_entry.tile_index != plt_entry.tile_index or
        layout_entry.tile_part_index != plt_entry.tile_part_index or
        layout_entry.tile_part_count != 1 or
        layout_entry.packet_count != tile_artifacts.packetCount())
    {
        return PacketScaffoldError.InvalidPacket;
    }
    if (layout_entry.psot < 14) return PacketScaffoldError.InvalidPacket;

    var plt_bytes: []u8 = &.{};
    if (options.plt) {
        plt_bytes = try writeTilePartPltMarkerSegmentsForEntry(allocator, plt_plan, entry_index);
        errdefer allocator.free(plt_bytes);
        if (plt_bytes.len != layout_entry.plt_bytes) return PacketScaffoldError.InvalidPacket;
    } else if (layout_entry.plt_bytes != 0) {
        return PacketScaffoldError.InvalidPacket;
    }
    defer if (options.plt) allocator.free(plt_bytes);

    var out = try std.ArrayList(u8).initCapacity(allocator, layout_entry.psot);
    errdefer out.deinit(allocator);

    try appendU16Be(allocator, &out, @intFromEnum(TilePartMarker.sot));
    try appendU16Be(allocator, &out, 10);
    try appendU16Be(allocator, &out, layout_entry.tile_index);
    try appendU32Be(allocator, &out, layout_entry.psot);
    try out.append(allocator, layout_entry.tile_part_index);
    try out.append(allocator, layout_entry.tile_part_count);
    try out.appendSlice(allocator, plt_bytes);
    try appendU16Be(allocator, &out, @intFromEnum(TilePartMarker.sod));
    try appendTilePartSodPayload(allocator, &out, tile_artifacts.stream, options);

    if (out.items.len != layout_entry.psot) return PacketScaffoldError.InvalidPacket;
    return out.toOwnedSlice(allocator);
}

pub fn writeTilePartSequenceBytes(
    allocator: std.mem.Allocator,
    artifacts: TileRpclEncodeGridArtifacts,
    layout: TilePartLayout,
    tlm_plan: ?TilePartTlmPlan,
    plt_plan: TilePartPltPlan,
    options: TilePartSequenceOptions,
) ![]u8 {
    const sequence = try buildTilePartSequence(
        allocator,
        artifacts,
        layout,
        tlm_plan,
        plt_plan,
        options,
    );
    allocator.free(sequence.tile_part_offsets);
    return sequence.bytes;
}

pub fn buildTilePartSequence(
    allocator: std.mem.Allocator,
    artifacts: TileRpclEncodeGridArtifacts,
    layout: TilePartLayout,
    tlm_plan: ?TilePartTlmPlan,
    plt_plan: TilePartPltPlan,
    options: TilePartSequenceOptions,
) !TilePartSequence {
    if (artifacts.tiles.len != layout.entries.len or layout.entries.len != plt_plan.entries.len) {
        return PacketScaffoldError.InvalidPacket;
    }
    const tile_part_offsets = try allocator.alloc(usize, layout.entries.len);
    errdefer allocator.free(tile_part_offsets);

    const tile_part_bytes = try layout.totalPsotBytes();
    const tlm_bytes = if (options.tlm) blk: {
        const plan = tlm_plan orelse return PacketScaffoldError.InvalidPacket;
        if (plan.entries.len != layout.entries.len) return PacketScaffoldError.InvalidPacket;
        break :blk try plan.singleSegmentMarkerBytes();
    } else 0;

    var out = try std.ArrayList(u8).initCapacity(
        allocator,
        try std.math.add(usize, tile_part_bytes, tlm_bytes),
    );
    errdefer out.deinit(allocator);

    if (options.tlm) {
        const plan = tlm_plan.?;
        const tlm_marker = try writeTilePartTlmMarkerSegment(allocator, plan);
        defer allocator.free(tlm_marker);
        if (tlm_marker.len != tlm_bytes) return PacketScaffoldError.InvalidPacket;
        try out.appendSlice(allocator, tlm_marker);
    }

    for (layout.entries, 0..) |entry, entry_index| {
        tile_part_offsets[entry_index] = out.items.len;
        const before = out.items.len;
        const tile_part = try writeTilePartBytesForEntry(
            allocator,
            artifacts,
            layout,
            plt_plan,
            entry_index,
            options.tile_part,
        );
        defer allocator.free(tile_part);
        if (tile_part.len != entry.psot) return PacketScaffoldError.InvalidPacket;
        try out.appendSlice(allocator, tile_part);
        if (out.items.len - before != entry.psot) return PacketScaffoldError.InvalidPacket;
    }

    if (out.items.len != tile_part_bytes + tlm_bytes) return PacketScaffoldError.InvalidPacket;
    const bytes = try out.toOwnedSlice(allocator);
    return .{
        .allocator = allocator,
        .bytes = bytes,
        .tile_part_offsets = tile_part_offsets,
        .tlm_bytes = tlm_bytes,
    };
}

pub fn buildTilePartCodestreamFragment(
    allocator: std.mem.Allocator,
    sequence: TilePartSequence,
) !TilePartCodestreamFragment {
    const bytes = try allocator.alloc(u8, try std.math.add(usize, sequence.bytes.len, 4));
    errdefer allocator.free(bytes);
    bytes[0] = @as(u8, @truncate(@intFromEnum(TilePartMarker.soc) >> 8));
    bytes[1] = @as(u8, @truncate(@intFromEnum(TilePartMarker.soc)));
    @memcpy(bytes[2..][0..sequence.bytes.len], sequence.bytes);
    const eoc_offset = bytes.len - 2;
    bytes[eoc_offset] = @as(u8, @truncate(@intFromEnum(TilePartMarker.eoc) >> 8));
    bytes[eoc_offset + 1] = @as(u8, @truncate(@intFromEnum(TilePartMarker.eoc)));

    const tile_part_offsets = try allocator.alloc(usize, sequence.tile_part_offsets.len);
    errdefer allocator.free(tile_part_offsets);
    for (sequence.tile_part_offsets, tile_part_offsets) |offset, *out_offset| {
        out_offset.* = try std.math.add(usize, offset, 2);
    }

    const fragment = TilePartCodestreamFragment{
        .allocator = allocator,
        .bytes = bytes,
        .tile_part_offsets = tile_part_offsets,
        .tile_part_sequence_offset = 2,
        .tlm_bytes = sequence.tlm_bytes,
    };
    try fragment.validate();
    try fragment.validatePltMatchesAllTileParts(allocator);
    return fragment;
}

pub fn parseTilePartCodestreamFragment(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !TilePartCodestreamFragment {
    if (bytes.len < 16) return PacketScaffoldError.InvalidPacket;
    if (readU16Be(bytes, 0) != @intFromEnum(TilePartMarker.soc)) return PacketScaffoldError.InvalidPacket;
    if (readU16Be(bytes, bytes.len - 2) != @intFromEnum(TilePartMarker.eoc)) {
        return PacketScaffoldError.InvalidPacket;
    }

    const eoc_offset = bytes.len - 2;
    var cursor: usize = 2;
    var tlm_bytes: usize = 0;
    var expected_tlm_index: u8 = 0;
    while (cursor < eoc_offset) {
        if (eoc_offset - cursor < 2) return PacketScaffoldError.InvalidPacket;
        const marker = readU16Be(bytes, cursor);
        if (marker == @intFromEnum(TilePartMarker.tlm)) {
            if (eoc_offset - cursor < 4) return PacketScaffoldError.InvalidPacket;
            const length = readU16Be(bytes, cursor + 2);
            if (length < 4) return PacketScaffoldError.InvalidPacket;
            const total = try std.math.add(usize, 2, @as(usize, length));
            if (eoc_offset - cursor < total) return PacketScaffoldError.InvalidPacket;
            const segment_end = cursor + total;
            if (bytes[cursor + 4] != expected_tlm_index) return PacketScaffoldError.InvalidPacket;
            expected_tlm_index +%= 1;
            if (bytes[cursor + 5] != tile_part_tlm_stlm_u16_u32) return PacketScaffoldError.InvalidPacket;
            const payload_len = segment_end - (cursor + 6);
            if (payload_len == 0 or payload_len % tile_part_tlm_entry_bytes != 0) {
                return PacketScaffoldError.InvalidPacket;
            }
            cursor += total;
            tlm_bytes = try std.math.add(usize, tlm_bytes, total);
            continue;
        }
        break;
    }

    var offsets: std.ArrayList(usize) = .empty;
    errdefer offsets.deinit(allocator);
    while (cursor < eoc_offset) {
        if (eoc_offset - cursor < 12) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(bytes, cursor) != @intFromEnum(TilePartMarker.sot)) {
            return PacketScaffoldError.InvalidPacket;
        }
        if (readU16Be(bytes, cursor + 2) != 10) return PacketScaffoldError.InvalidPacket;
        const psot = readU32Be(bytes, cursor + 6);
        if (psot < 14) return PacketScaffoldError.InvalidPacket;
        const tile_part_end = try std.math.add(usize, cursor, @as(usize, @intCast(psot)));
        if (tile_part_end > eoc_offset) return PacketScaffoldError.InvalidPacket;
        try validateTilePartContainsSod(bytes[cursor..tile_part_end]);
        try offsets.append(allocator, cursor);
        cursor = tile_part_end;
    }
    if (cursor != eoc_offset or offsets.items.len == 0) return PacketScaffoldError.InvalidPacket;

    const owned_offsets = try offsets.toOwnedSlice(allocator);
    errdefer allocator.free(owned_offsets);
    const owned_bytes = try allocator.dupe(u8, bytes);
    errdefer allocator.free(owned_bytes);

    const fragment = TilePartCodestreamFragment{
        .allocator = allocator,
        .bytes = owned_bytes,
        .tile_part_offsets = owned_offsets,
        .tile_part_sequence_offset = 2,
        .tlm_bytes = tlm_bytes,
    };
    try fragment.validate();
    if (fragment.tlm_bytes > 0) try fragment.validateTlmMatchesTileParts(allocator);
    try fragment.validatePltMatchesAllTileParts(allocator);
    return fragment;
}

pub fn parseTilePartTlmEntries(
    allocator: std.mem.Allocator,
    tlm_bytes: []const u8,
) ![]ParsedTilePartTlmEntry {
    var entries: std.ArrayList(ParsedTilePartTlmEntry) = .empty;
    errdefer entries.deinit(allocator);

    var cursor: usize = 0;
    var expected_marker_index: u8 = 0;
    while (cursor < tlm_bytes.len) {
        if (tlm_bytes.len - cursor < 6) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(tlm_bytes, cursor) != @intFromEnum(TilePartMarker.tlm)) {
            return PacketScaffoldError.InvalidPacket;
        }
        const ltlm = readU16Be(tlm_bytes, cursor + 2);
        if (ltlm < 4) return PacketScaffoldError.InvalidPacket;
        const segment_end = try std.math.add(usize, cursor, try std.math.add(usize, 2, @as(usize, ltlm)));
        if (segment_end > tlm_bytes.len) return PacketScaffoldError.InvalidPacket;
        if (tlm_bytes[cursor + 4] != expected_marker_index) return PacketScaffoldError.InvalidPacket;
        expected_marker_index +%= 1;
        if (tlm_bytes[cursor + 5] != tile_part_tlm_stlm_u16_u32) {
            return PacketScaffoldError.InvalidPacket;
        }

        const payload_start = cursor + 6;
        const payload_len = segment_end - payload_start;
        if (payload_len == 0 or payload_len % tile_part_tlm_entry_bytes != 0) {
            return PacketScaffoldError.InvalidPacket;
        }
        var entry_cursor = payload_start;
        while (entry_cursor < segment_end) : (entry_cursor += tile_part_tlm_entry_bytes) {
            try entries.append(allocator, .{
                .tile_index = readU16Be(tlm_bytes, entry_cursor),
                .psot = readU32Be(tlm_bytes, entry_cursor + 2),
            });
        }

        cursor = segment_end;
    }

    return entries.toOwnedSlice(allocator);
}

pub fn parseTilePartPltLengthsFromBytes(
    allocator: std.mem.Allocator,
    tile_part: []const u8,
) ![]u32 {
    if (tile_part.len < 14) return PacketScaffoldError.InvalidPacket;

    var lengths: std.ArrayList(u32) = .empty;
    errdefer lengths.deinit(allocator);

    var cursor: usize = 12;
    var expected_marker_index: u8 = 0;
    while (cursor < tile_part.len) {
        if (tile_part.len - cursor < 2) return PacketScaffoldError.InvalidPacket;
        const marker = readU16Be(tile_part, cursor);
        if (marker == @intFromEnum(TilePartMarker.sod)) {
            if (lengths.items.len == 0) return PacketScaffoldError.InvalidPacket;
            return lengths.toOwnedSlice(allocator);
        }
        if (marker != @intFromEnum(TilePartMarker.plt)) return PacketScaffoldError.InvalidPacket;
        if (tile_part.len - cursor < 5) return PacketScaffoldError.InvalidPacket;

        const lplt = readU16Be(tile_part, cursor + 2);
        if (lplt < 3) return PacketScaffoldError.InvalidPacket;
        const segment_end = try std.math.add(usize, cursor, try std.math.add(usize, 2, @as(usize, lplt)));
        if (segment_end > tile_part.len) return PacketScaffoldError.InvalidPacket;
        if (tile_part[cursor + 4] != expected_marker_index) return PacketScaffoldError.InvalidPacket;
        expected_marker_index +%= 1;

        try appendParsedPltLengths(allocator, &lengths, tile_part[cursor + 5 .. segment_end]);
        cursor = segment_end;
    }

    return PacketScaffoldError.InvalidPacket;
}

fn appendParsedPltLengths(
    allocator: std.mem.Allocator,
    lengths: *std.ArrayList(u32),
    payload: []const u8,
) !void {
    var value: u64 = 0;
    var pending = false;
    for (payload) |byte| {
        value = (value << 7) | @as(u64, byte & 0x7f);
        pending = true;
        if ((byte & 0x80) == 0) {
            if (value == 0 or value > std.math.maxInt(u32)) return PacketScaffoldError.InvalidPacket;
            try lengths.append(allocator, @intCast(value));
            value = 0;
            pending = false;
        }
    }
    if (pending) return PacketScaffoldError.InvalidPacket;
}

pub fn validateTilePartCodestreamFragmentMatchesGridArtifacts(
    allocator: std.mem.Allocator,
    fragment: TilePartCodestreamFragment,
    artifacts: TileRpclEncodeGridArtifacts,
    options: TilePartLayoutOptions,
) !void {
    if (!options.plt) return PacketScaffoldError.InvalidPacket;
    if (fragment.tile_part_offsets.len != artifacts.tiles.len) return PacketScaffoldError.InvalidPacket;

    for (artifacts.tiles, 0..) |tile_artifacts, tile_part_index| {
        const tile_part = try fragment.tilePartSlice(tile_part_index);
        if (tile_part.len < 14) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(tile_part, 4) != tile_artifacts.tile.index) return PacketScaffoldError.InvalidPacket;
        if (tile_part[10] != 0 or tile_part[11] != 1) return PacketScaffoldError.InvalidPacket;

        const packet_spans = try fragment.parseTilePartPacketSpans(allocator, tile_part_index);
        defer allocator.free(packet_spans);
        if (packet_spans.len != tile_artifacts.stream.packet_lengths.len) return PacketScaffoldError.InvalidPacket;

        var stream_cursor: usize = 0;
        for (packet_spans, tile_artifacts.stream.packet_lengths, 0..) |span, packet_length, packet_index| {
            if (span.length != try framedPacketLength(packet_length, options)) return PacketScaffoldError.InvalidPacket;
            const framed_packet = try fragment.tilePartPacketPayloadSlice(tile_part_index, span);
            try validateFramedPacketMatchesStreamForTilePart(
                framed_packet,
                tile_artifacts.stream.bytes,
                &stream_cursor,
                packet_length,
                packet_index,
                options,
            );
        }
        if (stream_cursor != tile_artifacts.stream.bytes.len) return PacketScaffoldError.InvalidPacket;
    }
}

pub fn validateTilePartCodestreamFragmentT2Readback(
    allocator: std.mem.Allocator,
    fragment: TilePartCodestreamFragment,
    artifacts: TileRpclEncodeGridArtifacts,
    options: TilePartLayoutOptions,
) !void {
    if (!options.plt) return PacketScaffoldError.InvalidPacket;
    if (fragment.tile_part_offsets.len != artifacts.tiles.len) return PacketScaffoldError.InvalidPacket;

    for (artifacts.tiles, 0..) |tile_artifacts, tile_part_index| {
        const stream = try extractTileRpclPacketStreamFromFragmentTilePart(
            allocator,
            fragment,
            tile_part_index,
            tile_artifacts.stream.packet_header_lengths,
            options,
        );
        var owned_stream = stream;
        defer owned_stream.deinit();

        validateTileRpclPacketStream(
            allocator,
            tile_artifacts.scaffold,
            tile_artifacts.catalog,
            tile_artifacts.index,
            owned_stream,
            tile_artifacts.bit_depth,
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return PacketScaffoldError.InvalidPacket,
        };
    }
}

pub fn extractTileRpclPacketStreamFromFragmentTilePart(
    allocator: std.mem.Allocator,
    fragment: TilePartCodestreamFragment,
    tile_part_index: usize,
    expected_header_lengths: []const u32,
    options: TilePartLayoutOptions,
) !TileRpclPacketStream {
    if (!options.plt) return PacketScaffoldError.InvalidPacket;

    const packet_spans = try fragment.parseTilePartPacketSpans(allocator, tile_part_index);
    defer allocator.free(packet_spans);
    if (packet_spans.len != expected_header_lengths.len) return PacketScaffoldError.InvalidPacket;

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var packet_lengths: std.ArrayList(u32) = .empty;
    errdefer packet_lengths.deinit(allocator);
    var packet_header_lengths: std.ArrayList(u32) = .empty;
    errdefer packet_header_lengths.deinit(allocator);

    for (packet_spans, expected_header_lengths, 0..) |span, expected_header_length, packet_index| {
        const framed_packet = try fragment.tilePartPacketPayloadSlice(tile_part_index, span);
        const before = bytes.items.len;
        try appendRawPacketFromFramedTilePart(allocator, &bytes, framed_packet, packet_index, options);
        const raw_length = bytes.items.len - before;
        if (raw_length == 0 or raw_length > std.math.maxInt(u32)) return PacketScaffoldError.InvalidPacket;
        if (expected_header_length == 0 or expected_header_length > raw_length) return PacketScaffoldError.InvalidPacket;
        try packet_lengths.append(allocator, @intCast(raw_length));
        try packet_header_lengths.append(allocator, expected_header_length);
    }

    const owned_bytes = try bytes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bytes);
    const owned_packet_lengths = try packet_lengths.toOwnedSlice(allocator);
    errdefer allocator.free(owned_packet_lengths);
    const owned_packet_header_lengths = try packet_header_lengths.toOwnedSlice(allocator);
    errdefer allocator.free(owned_packet_header_lengths);

    return .{
        .allocator = allocator,
        .bytes = owned_bytes,
        .packet_lengths = owned_packet_lengths,
        .packet_header_lengths = owned_packet_header_lengths,
    };
}

fn appendRawPacketFromFramedTilePart(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    framed_packet: []const u8,
    packet_index: usize,
    options: TilePartLayoutOptions,
) !void {
    var cursor: usize = 0;
    if (options.sop) {
        if (framed_packet.len - cursor < 6) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(framed_packet, cursor) != @intFromEnum(TilePartMarker.sop)) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(framed_packet, cursor + 2) != 4) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(framed_packet, cursor + 4) != @as(u16, @intCast(packet_index & 0xffff))) {
            return PacketScaffoldError.InvalidPacket;
        }
        cursor += 6;
    }

    const suffix_bytes: usize = if (options.eph) 2 else 0;
    if (framed_packet.len < cursor + suffix_bytes) return PacketScaffoldError.InvalidPacket;
    const raw_end = framed_packet.len - suffix_bytes;
    if (raw_end <= cursor) return PacketScaffoldError.InvalidPacket;
    try out.appendSlice(allocator, framed_packet[cursor..raw_end]);
    cursor = raw_end;

    if (options.eph) {
        if (framed_packet.len - cursor < 2) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(framed_packet, cursor) != @intFromEnum(TilePartMarker.eph)) return PacketScaffoldError.InvalidPacket;
        cursor += 2;
    }
    if (cursor != framed_packet.len) return PacketScaffoldError.InvalidPacket;
}

fn validateFramedPacketMatchesStreamForTilePart(
    framed_packet: []const u8,
    stream_bytes: []const u8,
    stream_cursor: *usize,
    packet_length: u32,
    packet_index: usize,
    options: TilePartLayoutOptions,
) !void {
    var cursor: usize = 0;
    if (options.sop) {
        if (framed_packet.len - cursor < 6) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(framed_packet, cursor) != @intFromEnum(TilePartMarker.sop)) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(framed_packet, cursor + 2) != 4) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(framed_packet, cursor + 4) != @as(u16, @intCast(packet_index & 0xffff))) {
            return PacketScaffoldError.InvalidPacket;
        }
        cursor += 6;
    }

    const raw_packet_length = @as(usize, @intCast(packet_length));
    const raw_packet_end = try std.math.add(usize, stream_cursor.*, raw_packet_length);
    const framed_packet_end = try std.math.add(usize, cursor, raw_packet_length);
    if (raw_packet_end > stream_bytes.len or framed_packet_end > framed_packet.len) {
        return PacketScaffoldError.InvalidPacket;
    }
    if (!std.mem.eql(u8, stream_bytes[stream_cursor.*..raw_packet_end], framed_packet[cursor..framed_packet_end])) {
        return PacketScaffoldError.InvalidPacket;
    }
    stream_cursor.* = raw_packet_end;
    cursor = framed_packet_end;

    if (options.eph) {
        if (framed_packet.len - cursor < 2) return PacketScaffoldError.InvalidPacket;
        if (readU16Be(framed_packet, cursor) != @intFromEnum(TilePartMarker.eph)) return PacketScaffoldError.InvalidPacket;
        cursor += 2;
    }
    if (cursor != framed_packet.len) return PacketScaffoldError.InvalidPacket;
}

pub fn buildRpclPacketIndex(
    allocator: std.mem.Allocator,
    scaffold: PacketScaffold,
) !RpclPacketIndex {
    const packet_count = std.math.cast(usize, scaffold.plan.packets) orelse return PacketScaffoldError.InvalidPacket;
    const entries = try allocator.alloc(RpclPacketIndexEntry, packet_count);
    errdefer allocator.free(entries);

    var block_indexes: std.ArrayList(usize) = .empty;
    errdefer block_indexes.deinit(allocator);

    var initialized: usize = 0;
    var iterator = try packet_plan.RpclIterator.init(scaffold.plan, component_count, scaffold.layers);
    while (iterator.next()) |packet| {
        if (initialized >= entries.len or packet.sequence != initialized) return PacketScaffoldError.InvalidPacket;
        const selected = try t2.collectRpclCodeBlockIndexes(
            allocator,
            scaffold.plan,
            packet,
            scaffold.levels,
            scaffold.bands,
            scaffold.blocks,
        );
        defer allocator.free(selected);

        const first_index = block_indexes.items.len;
        try block_indexes.appendSlice(allocator, selected);
        entries[initialized] = .{
            .packet = packet,
            .first_index = first_index,
            .index_count = selected.len,
        };
        initialized += 1;
    }
    if (initialized != entries.len) return PacketScaffoldError.InvalidPacket;

    const owned_indexes = try block_indexes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_indexes);

    return .{
        .allocator = allocator,
        .entries = entries,
        .block_indexes = owned_indexes,
    };
}

pub fn validateTileRpclPacketStream(
    allocator: std.mem.Allocator,
    scaffold: PacketScaffold,
    catalog: EncodedBlockCatalog,
    index: RpclPacketIndex,
    stream: TileRpclPacketStream,
    bit_depth: u8,
) !void {
    if (catalog.tile.index != scaffold.tile.index) return PacketScaffoldError.InvalidComponentBlock;
    if (catalog.component_block_count != scaffold.blocks.len) return PacketScaffoldError.InvalidComponentBlock;
    const packet_count = std.math.cast(usize, scaffold.plan.packets) orelse return PacketScaffoldError.InvalidPacket;
    if (index.entries.len != packet_count or
        stream.packet_lengths.len != packet_count or
        stream.packet_header_lengths.len != packet_count)
    {
        return PacketScaffoldError.InvalidPacket;
    }
    if (stream.bytes.len != try stream.totalPacketBytes()) return PacketScaffoldError.InvalidPacket;

    var active_storage: [max_rpcl_packet_band_groups]TilePacketReaderBandGroup = undefined;
    var active_count: usize = 0;
    defer deinitTilePacketReaderGroups(active_storage[0..active_count], allocator);

    var iterator = try packet_plan.RpclIterator.init(scaffold.plan, component_count, scaffold.layers);
    var packet_offset: usize = 0;
    var decoded_packets: usize = 0;
    while (iterator.next()) |packet| {
        const packet_index = std.math.cast(usize, packet.sequence) orelse return PacketScaffoldError.InvalidPacket;
        if (packet_index != decoded_packets) return PacketScaffoldError.InvalidPacket;
        const packet_length: usize = stream.packet_lengths[packet_index];
        const packet_end = try std.math.add(usize, packet_offset, packet_length);
        if (packet_end > stream.bytes.len) return PacketScaffoldError.InvalidPacket;

        if (packet.layer == 0) {
            if (active_count != 0) return PacketScaffoldError.InvalidPacket;
            var groups = try index.bandGroupsForPacket(allocator, scaffold, packet.sequence);
            defer groups.deinit();
            if (groups.groups.len > active_storage.len) return PacketScaffoldError.InvalidPacket;
            while (active_count < groups.groups.len) : (active_count += 1) {
                active_storage[active_count] = try initTilePacketReaderBandGroup(
                    allocator,
                    groups,
                    scaffold,
                    catalog,
                    active_count,
                    bit_depth,
                );
            }
        }

        try validateTileRpclPacketForGroups(
            active_storage[0..active_count],
            packet,
            stream.bytes[packet_offset..packet_end],
            stream.packet_header_lengths[packet_index],
        );
        packet_offset = packet_end;
        decoded_packets += 1;

        if (packet.layer + 1 == scaffold.layers) {
            deinitTilePacketReaderGroups(active_storage[0..active_count], allocator);
            active_count = 0;
        }
    }
    if (decoded_packets != packet_count or packet_offset != stream.bytes.len or active_count != 0) {
        return PacketScaffoldError.InvalidPacket;
    }
}

pub fn buildTileRpclPacketStream(
    allocator: std.mem.Allocator,
    scaffold: PacketScaffold,
    catalog: EncodedBlockCatalog,
    index: RpclPacketIndex,
    bit_depth: u8,
) !TileRpclPacketStream {
    if (catalog.tile.index != scaffold.tile.index) return PacketScaffoldError.InvalidComponentBlock;
    if (catalog.component_block_count != scaffold.blocks.len) return PacketScaffoldError.InvalidComponentBlock;
    const packet_count = std.math.cast(usize, scaffold.plan.packets) orelse return PacketScaffoldError.InvalidPacket;
    if (index.entries.len != packet_count) return PacketScaffoldError.InvalidPacket;

    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var packet_lengths: std.ArrayList(u32) = .empty;
    errdefer packet_lengths.deinit(allocator);
    var packet_header_lengths: std.ArrayList(u32) = .empty;
    errdefer packet_header_lengths.deinit(allocator);

    var active_storage: [max_rpcl_packet_band_groups]TilePacketWriterBandGroup = undefined;
    var active_count: usize = 0;
    defer deinitTilePacketWriterGroups(active_storage[0..active_count], allocator);

    var iterator = try packet_plan.RpclIterator.init(scaffold.plan, component_count, scaffold.layers);
    var emitted_packets: usize = 0;
    while (iterator.next()) |packet| {
        if (packet.layer == 0) {
            if (active_count != 0) return PacketScaffoldError.InvalidPacket;
            var groups = try index.bandGroupsForPacket(allocator, scaffold, packet.sequence);
            defer groups.deinit();
            if (groups.groups.len > active_storage.len) return PacketScaffoldError.InvalidPacket;
            while (active_count < groups.groups.len) : (active_count += 1) {
                const encoded = try groups.encodedLayerBlocksForGroup(
                    allocator,
                    scaffold,
                    catalog,
                    active_count,
                    bit_depth,
                );
                var encoded_moved = false;
                errdefer if (!encoded_moved) allocator.free(encoded);

                var writer_state = try t2.PrecinctPacketWriterState.initForEncodedBlocks(allocator, encoded);
                var writer_moved = false;
                errdefer if (!writer_moved) writer_state.deinit();

                active_storage[active_count] = .{
                    .encoded = encoded,
                    .writer_state = writer_state,
                };
                encoded_moved = true;
                writer_moved = true;
            }
        }

        const written = try appendTileRpclPacketForGroups(
            allocator,
            &bytes,
            active_storage[0..active_count],
            packet,
        );
        try appendPacketLength(allocator, &packet_lengths, written.packet_length());
        try appendPacketLength(allocator, &packet_header_lengths, written.header_length);
        emitted_packets += 1;

        if (packet.layer + 1 == scaffold.layers) {
            deinitTilePacketWriterGroups(active_storage[0..active_count], allocator);
            active_count = 0;
        }
    }
    if (emitted_packets != index.entries.len or active_count != 0) return PacketScaffoldError.InvalidPacket;

    const owned_bytes = try bytes.toOwnedSlice(allocator);
    errdefer allocator.free(owned_bytes);
    const owned_lengths = try packet_lengths.toOwnedSlice(allocator);
    errdefer allocator.free(owned_lengths);
    const owned_header_lengths = try packet_header_lengths.toOwnedSlice(allocator);
    errdefer allocator.free(owned_header_lengths);

    return .{
        .allocator = allocator,
        .bytes = owned_bytes,
        .packet_lengths = owned_lengths,
        .packet_header_lengths = owned_header_lengths,
    };
}

fn initTilePacketReaderBandGroup(
    allocator: std.mem.Allocator,
    groups: RpclPacketBandGroups,
    scaffold: PacketScaffold,
    catalog: EncodedBlockCatalog,
    group_index: usize,
    bit_depth: u8,
) !TilePacketReaderBandGroup {
    const encoded = try groups.encodedLayerBlocksForGroup(
        allocator,
        scaffold,
        catalog,
        group_index,
        bit_depth,
    );
    var encoded_moved = false;
    errdefer if (!encoded_moved) allocator.free(encoded);

    const locations = try allocator.alloc(t2.PacketBlockLocation, encoded.len);
    var locations_moved = false;
    errdefer if (!locations_moved) allocator.free(locations);

    const decoded = try allocator.alloc(t2.DecodedPacketBlock, encoded.len);
    var decoded_moved = false;
    errdefer if (!decoded_moved) allocator.free(decoded);

    const payloads = try allocator.alloc(?[]const u8, encoded.len);
    var payloads_moved = false;
    errdefer if (!payloads_moved) allocator.free(payloads);

    var max_zero_bitplanes: u8 = 0;
    var leaves_x: usize = 0;
    var leaves_y: usize = 0;
    for (encoded, locations) |block, *location| {
        location.* = block.location;
        leaves_x = @max(leaves_x, block.location.leaf_x + 1);
        leaves_y = @max(leaves_y, block.location.leaf_y + 1);
        max_zero_bitplanes = @max(max_zero_bitplanes, try t2.zeroBitPlaneCount(block.nominal_bitplanes, block.encoded_bitplanes));
    }
    const leaf_count = try std.math.mul(usize, leaves_x, leaves_y);
    if (leaf_count != encoded.len) return PacketScaffoldError.InvalidPacket;

    var reader_state = try t2.PrecinctPacketReaderState.initWithLayerCount(
        allocator,
        leaves_x,
        leaves_y,
        encoded.len,
        scaffold.layers,
    );
    var reader_moved = false;
    errdefer if (!reader_moved) reader_state.deinit();
    reader_state.terminate_all = try encodedLayerBlocksUseTerminateAll(encoded);

    encoded_moved = true;
    locations_moved = true;
    decoded_moved = true;
    payloads_moved = true;
    reader_moved = true;
    return .{
        .encoded = encoded,
        .reader_state = reader_state,
        .locations = locations,
        .decoded = decoded,
        .payloads = payloads,
        .max_zero_bitplanes = max_zero_bitplanes,
    };
}

fn encodedLayerBlocksUseTerminateAll(encoded: []const t2.EncodedLayerBlock) !bool {
    var saw_terminated_block = false;
    for (encoded) |block| {
        if (block.segments.len == 0) continue;
        saw_terminated_block = true;
        for (block.segments) |segment| {
            if (segment.pass_count != 1) return PacketScaffoldError.InvalidPacket;
        }
    }
    return saw_terminated_block;
}

fn validateTileRpclPacketForGroups(
    groups: []TilePacketReaderBandGroup,
    packet: packet_plan.Packet,
    packet_bytes: []const u8,
    expected_header_length: u32,
) !void {
    var reader = t2.PacketHeaderReader.init(packet_bytes);
    const packet_included = try reader.readBit();
    var expected_included = false;
    for (groups) |*group| {
        for (group.encoded) |encoded| {
            const contribution = try encodedLayerContribution(encoded, @intCast(packet.layer));
            expected_included = expected_included or contribution.included;
        }
    }
    if (packet_included != expected_included) return PacketScaffoldError.InvalidPacket;

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
    }
    try reader.byteAlign();

    const header_length = reader.bytesConsumed();
    if (header_length != expected_header_length or header_length > packet_bytes.len) {
        return PacketScaffoldError.InvalidPacket;
    }

    var payload_cursor = header_length;
    var included_blocks: usize = 0;
    const layer_index: usize = @intCast(packet.layer);
    if (packet_included) {
        for (groups) |*group| {
            for (group.decoded, group.payloads, group.encoded) |decoded, *payload_slot, encoded| {
                payload_slot.* = null;
                const expected = try encodedLayerContribution(encoded, layer_index);
                if (decoded.included != expected.included) return PacketScaffoldError.InvalidPacket;
                if (!decoded.included) continue;

                if (decoded.pass_count != expected.pass_count or
                    decoded.byte_length != expected.byte_length)
                {
                    return PacketScaffoldError.InvalidPacket;
                }

                const payload_length = std.math.cast(usize, decoded.byte_length) orelse return PacketScaffoldError.InvalidPacket;
                const payload_end = try std.math.add(usize, payload_cursor, payload_length);
                if (payload_end > packet_bytes.len) return PacketScaffoldError.InvalidPacket;
                const actual_payload = packet_bytes[payload_cursor..payload_end];
                const expected_payload = try encodedLayerPayload(encoded, layer_index);
                if (!std.mem.eql(u8, actual_payload, expected_payload)) return PacketScaffoldError.InvalidPacket;
                payload_slot.* = actual_payload;
                payload_cursor = payload_end;
                included_blocks += 1;
            }
        }
    }
    if ((included_blocks > 0) != packet_included) return PacketScaffoldError.InvalidPacket;
    if (payload_cursor != packet_bytes.len) return PacketScaffoldError.InvalidPacket;
}

fn appendTileRpclPacketForGroups(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    groups: []TilePacketWriterBandGroup,
    packet: packet_plan.Packet,
) !t2.WrittenPacket {
    var prepared_storage: [max_rpcl_packet_band_groups]PreparedTilePacketGroup = undefined;
    const prepared = prepared_storage[0..groups.len];
    var initialized: usize = 0;
    defer {
        for (prepared[0..initialized]) |*group| group.deinit(allocator);
    }

    var packet_included = false;
    var payload_length: usize = 0;
    var included_blocks: usize = 0;
    for (groups, 0..) |*group, group_index| {
        prepared[group_index] = try prepareTileRpclPacketGroup(allocator, group, packet.layer);
        initialized += 1;
        packet_included = packet_included or t2.packetBlocksIncluded(prepared[group_index].packet_blocks);
        for (prepared[group_index].packet_blocks) |packet_block| {
            if (!packet_block.included) continue;
            payload_length = try std.math.add(usize, payload_length, packet_block.byte_length);
            included_blocks += 1;
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
                const payload = try encodedLayerPayload(encoded, layer_index);
                if (payload.len != packet_block.byte_length) return PacketScaffoldError.InvalidPacket;
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

fn prepareTileRpclPacketGroup(
    allocator: std.mem.Allocator,
    group: *TilePacketWriterBandGroup,
    layer: u16,
) !PreparedTilePacketGroup {
    const layer_index: usize = @intCast(layer);
    const packet_blocks = try allocator.alloc(t2.PacketBlock, group.encoded.len);
    errdefer allocator.free(packet_blocks);

    for (group.encoded, 0..) |encoded, block_index| {
        const layer_block = try t2.layerPacketBlockFor(encoded, layer_index);
        if (layer_block.previous.cumulative_passes != group.writer_state.states[block_index].cumulative_passes or
            layer_block.previous.cumulative_bytes != group.writer_state.states[block_index].cumulative_bytes)
        {
            return PacketScaffoldError.InvalidPacket;
        }

        packet_blocks[block_index] = try t2.packetBlockForLayer(
            layer_block.location,
            layer_block.nominal_bitplanes,
            layer_block.encoded_bitplanes,
            layer_block.previous,
            layer_block.current,
        );
        if (layer_block.segments.len > 0 and packet_blocks[block_index].included) {
            var segment_passes: u16 = 0;
            var segment_bytes: u64 = 0;
            for (layer_block.segments) |segment| {
                segment_passes = std.math.add(u16, segment_passes, segment.pass_count) catch
                    return PacketScaffoldError.InvalidPacket;
                segment_bytes = std.math.add(u64, segment_bytes, segment.byte_length) catch
                    return PacketScaffoldError.InvalidPacket;
            }
            if (segment_passes != packet_blocks[block_index].pass_count or
                segment_bytes != packet_blocks[block_index].byte_length)
            {
                return PacketScaffoldError.InvalidPacket;
            }
            packet_blocks[block_index].segments = layer_block.segments;
        }

        const payload = try t2.layerPayloadSlice(layer_block.payload, layer_block.previous, layer_block.current);
        if (packet_blocks[block_index].included) {
            if (payload.len != packet_blocks[block_index].byte_length) return PacketScaffoldError.InvalidPacket;
        } else if (payload.len != 0) {
            return PacketScaffoldError.InvalidPacket;
        }
    }

    return .{ .packet_blocks = packet_blocks };
}

fn encodedLayerPayload(encoded: t2.EncodedLayerBlock, layer_index: usize) ![]const u8 {
    const previous = try encodedLayerPreviousTruncation(encoded, layer_index);
    if (layer_index >= encoded.layers.len) return PacketScaffoldError.InvalidPacket;
    return t2.layerPayloadSlice(encoded.payload, previous, encoded.layers[layer_index]);
}

fn encodedLayerContribution(encoded: t2.EncodedLayerBlock, layer_index: usize) !t2.LayerContribution {
    const previous = try encodedLayerPreviousTruncation(encoded, layer_index);
    if (layer_index >= encoded.layers.len) return PacketScaffoldError.InvalidPacket;
    return t2.layerContribution(previous, encoded.layers[layer_index]);
}

fn encodedLayerPreviousTruncation(encoded: t2.EncodedLayerBlock, layer_index: usize) !t2.LayerTruncation {
    if (layer_index >= encoded.layers.len) return PacketScaffoldError.InvalidPacket;
    return if (layer_index == 0)
        .{ .cumulative_passes = 0, .cumulative_bytes = 0 }
    else
        encoded.layers[layer_index - 1];
}

fn appendPacketLength(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u32),
    length: usize,
) !void {
    const value = std.math.cast(u32, length) orelse return PacketScaffoldError.InvalidPacket;
    try out.append(allocator, value);
}

fn deinitTilePacketWriterGroups(groups: []TilePacketWriterBandGroup, allocator: std.mem.Allocator) void {
    for (groups) |*group| group.deinit(allocator);
}

fn deinitTilePacketReaderGroups(groups: []TilePacketReaderBandGroup, allocator: std.mem.Allocator) void {
    for (groups) |*group| group.deinit(allocator);
}

fn tileGridEncodeWorker(job: *TileGridEncodeJob) void {
    while (!job.failed.load(.acquire)) {
        const order_index = job.next_tile.fetchAdd(1, .monotonic);
        if (order_index >= job.tile_order.len) return;
        const tile_index = job.tile_order[order_index];

        const tile = job.grid.tile(tile_index) catch |err| {
            recordTileGridEncodeError(job, err);
            return;
        };
        const artifacts = buildTileRpclEncodeArtifactsIsoMq(
            job.allocator,
            job.source,
            tile,
            job.requested_levels,
            job.options,
            job.style,
        ) catch |err| {
            recordTileGridEncodeError(job, err);
            return;
        };
        job.tiles[tile_index] = artifacts;
        job.initialized[tile_index] = true;
    }
}

fn recordTileGridEncodeError(job: *TileGridEncodeJob, err: anyerror) void {
    job.err = err;
    job.failed.store(true, .release);
}

fn deinitInitializedTileArtifacts(tiles: []TileRpclEncodeArtifacts, initialized: []const bool) void {
    for (tiles, initialized) |*tile, is_initialized| {
        if (is_initialized) tile.deinit();
    }
}

fn computeLayerTruncations(
    allocator: std.mem.Allocator,
    segment: ebcot.CodeBlockSegment,
    layer_count: u16,
) ![]t2.LayerTruncation {
    if (layer_count == 0 or layer_count > rate_alloc.max_layers) return PacketScaffoldError.InvalidLayer;

    const count: usize = @intCast(layer_count);
    var requested: [rate_alloc.max_layers]rate_alloc.Truncation = undefined;
    try rate_alloc.allocateEven(requested[0..count], .{
        .pass_count = segment.pass_count,
        .byte_length = segment.byte_length,
    });

    const layers = try allocator.alloc(t2.LayerTruncation, count);
    errdefer allocator.free(layers);

    var previous = t2.LayerTruncation{ .cumulative_passes = 0, .cumulative_bytes = 0 };
    for (requested[0..count], 0..) |layer, index| {
        const is_final = index == count - 1;
        layers[index] = try normalizedLayerTruncation(segment, layer.cumulative_passes, previous, is_final);
        previous = layers[index];
    }
    return layers;
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
        var cumulative_passes: u16 = 0;
        var cumulative_bytes: u64 = 0;
        var best = previous;
        for (segments) |span| {
            cumulative_passes = std.math.add(u16, cumulative_passes, span.pass_count) catch
                return PacketScaffoldError.InvalidLayer;
            cumulative_bytes = std.math.add(u64, cumulative_bytes, span.byte_length) catch
                return PacketScaffoldError.InvalidLayer;
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
