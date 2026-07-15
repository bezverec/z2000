const std = @import("std");

pub const PacketPlanError = error{
    InvalidDimensions,
    TooManyResolutions,
};

pub const Precinct = struct {
    width: u32,
    height: u32,
};

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Resolution = struct {
    /// Bounds of this tile-component resolution on the component reference
    /// grid. Single-tile plans start at zero; tile plans retain their ISO
    /// B.6 partition origin so edge precincts can be clipped locally.
    x0: u32 = 0,
    y0: u32 = 0,
    width: u32,
    height: u32,
    precinct_width: u32,
    precinct_height: u32,
    precinct_x0: u32 = 0,
    precinct_y0: u32 = 0,
    precincts_x: u32,
    precincts_y: u32,
    precincts: u64,
    packets: u64,
};

pub const Plan = struct {
    resolution_count: u8,
    resolutions: [33]Resolution,
    packets: u64,
};

pub const Packet = struct {
    sequence: u64,
    resolution: u8,
    precinct_x: u32,
    precinct_y: u32,
    precinct_index: u64,
    component: u16,
    layer: u16,
};

pub const Position = struct {
    x_ref: u64,
    y_ref: u64,
};

/// One component-local packet plan plus its SIZ sampling factors. Component
/// plans use a component count of one; the merged stream assigns the slice
/// index as the packet component number.
pub const SampledComponentPlan = struct {
    plan: Plan,
    xrsiz: u8,
    yrsiz: u8,
};

pub const SampledOrder = enum { lrcp, rlcp, rpcl, pcrl, cprl };

/// Upper-left precinct position on the image reference grid used by the PCRL
/// and CPRL ordering rules. Keeping this projection here prevents tile-part
/// writers from duplicating the resolution scaling math.
pub fn packetPosition(plan: Plan, packet: Packet) !Position {
    if (plan.resolution_count == 0 or packet.resolution >= plan.resolution_count) {
        return PacketPlanError.InvalidDimensions;
    }
    const levels: u8 = plan.resolution_count - 1;
    const resolution = plan.resolutions[packet.resolution];
    const shift: u6 = @intCast(levels - packet.resolution);
    return .{
        .x_ref = (@as(u64, packet.precinct_x) * resolution.precinct_width) << shift,
        .y_ref = (@as(u64, packet.precinct_y) * resolution.precinct_height) << shift,
    };
}

fn sampledPacketPosition(
    component: SampledComponentPlan,
    packet: Packet,
    reference_x0: u32,
    reference_y0: u32,
) !Position {
    if (component.xrsiz == 0 or component.yrsiz == 0 or
        component.plan.resolution_count == 0 or packet.resolution >= component.plan.resolution_count)
    {
        return PacketPlanError.InvalidDimensions;
    }
    const levels: u8 = component.plan.resolution_count - 1;
    const resolution = component.plan.resolutions[packet.resolution];
    const shift: u6 = @intCast(levels - packet.resolution);
    const x = std.math.mul(u64, packet.precinct_x, resolution.precinct_width) catch
        return PacketPlanError.InvalidDimensions;
    const y = std.math.mul(u64, packet.precinct_y, resolution.precinct_height) catch
        return PacketPlanError.InvalidDimensions;
    const sampled_x = std.math.mul(u64, x, component.xrsiz) catch
        return PacketPlanError.InvalidDimensions;
    const sampled_y = std.math.mul(u64, y, component.yrsiz) catch
        return PacketPlanError.InvalidDimensions;
    const shifted_limit: u64 = @as(u64, std.math.maxInt(u64)) >> shift;
    if (sampled_x > shifted_limit or sampled_y > shifted_limit) {
        return PacketPlanError.InvalidDimensions;
    }
    return .{
        // A precinct aligned before a tile-component boundary is visited at
        // the tile boundary, not before the tile. This matters for sampled
        // components in all tiles except the top-left tile.
        .x_ref = @max(sampled_x << shift, reference_x0),
        .y_ref = @max(sampled_y << shift, reference_y0),
    };
}

fn validatePlan(plan: Plan, components: u16, layers: u16) !void {
    if (components == 0 or layers == 0) return PacketPlanError.InvalidDimensions;
    if (plan.resolution_count == 0 or plan.resolution_count > plan.resolutions.len) {
        return PacketPlanError.InvalidDimensions;
    }

    var expected_packets: u64 = 0;
    for (plan.resolutions[0..plan.resolution_count]) |resolution| {
        try validateResolution(resolution, components, layers);
        expected_packets = try std.math.add(u64, expected_packets, resolution.packets);
    }
    if (expected_packets != plan.packets) return PacketPlanError.InvalidDimensions;
}

pub const RpclIterator = struct {
    plan: Plan,
    components: u16,
    layers: u16,
    resolution: u8 = 0,
    precinct_index: u64 = 0,
    component: u16 = 0,
    layer: u16 = 0,
    sequence: u64 = 0,

    pub fn init(plan: Plan, components: u16, layers: u16) !RpclIterator {
        try validatePlan(plan, components, layers);
        return .{
            .plan = plan,
            .components = components,
            .layers = layers,
        };
    }

    pub fn next(self: *RpclIterator) ?Packet {
        while (self.resolution < self.plan.resolution_count) {
            const resolution = self.plan.resolutions[self.resolution];
            if (self.precinct_index >= resolution.precincts) {
                self.resolution += 1;
                self.precinct_index = 0;
                self.component = 0;
                self.layer = 0;
                continue;
            }

            const packet = Packet{
                .sequence = self.sequence,
                .resolution = self.resolution,
                .precinct_x = resolution.precinct_x0 + @as(u32, @intCast(self.precinct_index % resolution.precincts_x)),
                .precinct_y = resolution.precinct_y0 + @as(u32, @intCast(self.precinct_index / resolution.precincts_x)),
                .precinct_index = self.precinct_index,
                .component = self.component,
                .layer = self.layer,
            };
            self.advance();
            return packet;
        }
        return null;
    }

    fn advance(self: *RpclIterator) void {
        self.sequence += 1;
        self.layer += 1;
        if (self.layer < self.layers) return;
        self.layer = 0;
        self.component += 1;
        if (self.component < self.components) return;
        self.component = 0;
        self.precinct_index += 1;
    }
};

/// ISO 15444-1 B.12.1.1 layer-resolution-component-position progression:
/// layer is outermost, then resolution, component, and precinct. Emits the
/// same packet identities as RpclIterator, only in LRCP stream order.
pub const LrcpIterator = struct {
    plan: Plan,
    components: u16,
    layers: u16,
    layer: u16 = 0,
    resolution: u8 = 0,
    component: u16 = 0,
    precinct_index: u64 = 0,
    sequence: u64 = 0,

    pub fn init(plan: Plan, components: u16, layers: u16) !LrcpIterator {
        try validatePlan(plan, components, layers);
        return .{
            .plan = plan,
            .components = components,
            .layers = layers,
        };
    }

    pub fn next(self: *LrcpIterator) ?Packet {
        while (self.layer < self.layers) {
            if (self.resolution >= self.plan.resolution_count) {
                self.layer += 1;
                self.resolution = 0;
                self.component = 0;
                self.precinct_index = 0;
                continue;
            }
            const resolution = self.plan.resolutions[self.resolution];
            if (self.precinct_index >= resolution.precincts) {
                self.precinct_index = 0;
                self.component += 1;
                if (self.component >= self.components) {
                    self.component = 0;
                    self.resolution += 1;
                }
                continue;
            }

            const packet = Packet{
                .sequence = self.sequence,
                .resolution = self.resolution,
                .precinct_x = resolution.precinct_x0 + @as(u32, @intCast(self.precinct_index % resolution.precincts_x)),
                .precinct_y = resolution.precinct_y0 + @as(u32, @intCast(self.precinct_index / resolution.precincts_x)),
                .precinct_index = self.precinct_index,
                .component = self.component,
                .layer = self.layer,
            };
            self.sequence += 1;
            self.precinct_index += 1;
            return packet;
        }
        return null;
    }
};

/// ISO 15444-1 B.12.1.2 resolution-layer-component-position progression:
/// resolution is outermost, then layer, component, and precinct. Emits the
/// same packet identities as RpclIterator, only in RLCP stream order. Because
/// resolution stays outermost, per-resolution tile-part divisions remain
/// valid for any layer count.
pub const RlcpIterator = struct {
    plan: Plan,
    components: u16,
    layers: u16,
    resolution: u8 = 0,
    layer: u16 = 0,
    component: u16 = 0,
    precinct_index: u64 = 0,
    sequence: u64 = 0,

    pub fn init(plan: Plan, components: u16, layers: u16) !RlcpIterator {
        try validatePlan(plan, components, layers);
        return .{
            .plan = plan,
            .components = components,
            .layers = layers,
        };
    }

    pub fn next(self: *RlcpIterator) ?Packet {
        while (self.resolution < self.plan.resolution_count) {
            if (self.layer >= self.layers) {
                self.layer = 0;
                self.resolution += 1;
                continue;
            }
            const resolution = self.plan.resolutions[self.resolution];
            if (self.precinct_index >= resolution.precincts) {
                self.precinct_index = 0;
                self.component += 1;
                if (self.component >= self.components) {
                    self.component = 0;
                    self.layer += 1;
                }
                continue;
            }

            const packet = Packet{
                .sequence = self.sequence,
                .resolution = self.resolution,
                .precinct_x = resolution.precinct_x0 + @as(u32, @intCast(self.precinct_index % resolution.precincts_x)),
                .precinct_y = resolution.precinct_y0 + @as(u32, @intCast(self.precinct_index / resolution.precincts_x)),
                .precinct_index = self.precinct_index,
                .component = self.component,
                .layer = self.layer,
            };
            self.sequence += 1;
            self.precinct_index += 1;
            return packet;
        }
        return null;
    }
};

/// Position-major stream orders (ISO 15444-1 B.12.1.4 PCRL and B.12.1.5
/// CPRL). A precinct's position is its upper-left corner on the image
/// reference grid: one sample at resolution r spans 2^(levels - r) grid
/// units, so precinct (px, py) sits at (px * pw_r, py * ph_r) << (levels - r).
/// PCRL iterates y, x, component, resolution, layer; CPRL hoists component
/// outermost. Layer stays innermost in both, so each precinct's layers remain
/// consecutive and the packet bodies are the same byte-preserving permutation
/// of the RPCL stream the other orders use.
pub const PositionOrder = enum { pcrl, cprl };

const PositionKeyedPacket = struct {
    packet: Packet,
    x_ref: u64,
    y_ref: u64,
};

fn sampledRpclLessThan(_: void, a: PositionKeyedPacket, b: PositionKeyedPacket) bool {
    if (a.packet.resolution != b.packet.resolution) return a.packet.resolution < b.packet.resolution;
    if (a.y_ref != b.y_ref) return a.y_ref < b.y_ref;
    if (a.x_ref != b.x_ref) return a.x_ref < b.x_ref;
    if (a.packet.component != b.packet.component) return a.packet.component < b.packet.component;
    return a.packet.layer < b.packet.layer;
}

fn sampledOrderLessThan(order: SampledOrder, a: PositionKeyedPacket, b: PositionKeyedPacket) bool {
    switch (order) {
        .lrcp => {
            if (a.packet.layer != b.packet.layer) return a.packet.layer < b.packet.layer;
            if (a.packet.resolution != b.packet.resolution) return a.packet.resolution < b.packet.resolution;
            if (a.packet.component != b.packet.component) return a.packet.component < b.packet.component;
            return a.packet.precinct_index < b.packet.precinct_index;
        },
        .rlcp => {
            if (a.packet.resolution != b.packet.resolution) return a.packet.resolution < b.packet.resolution;
            if (a.packet.layer != b.packet.layer) return a.packet.layer < b.packet.layer;
            if (a.packet.component != b.packet.component) return a.packet.component < b.packet.component;
            return a.packet.precinct_index < b.packet.precinct_index;
        },
        .rpcl => return sampledRpclLessThan({}, a, b),
        .pcrl, .cprl => {
            if (order == .cprl and a.packet.component != b.packet.component) {
                return a.packet.component < b.packet.component;
            }
            if (a.y_ref != b.y_ref) return a.y_ref < b.y_ref;
            if (a.x_ref != b.x_ref) return a.x_ref < b.x_ref;
            if (order == .pcrl and a.packet.component != b.packet.component) {
                return a.packet.component < b.packet.component;
            }
            if (a.packet.resolution != b.packet.resolution) return a.packet.resolution < b.packet.resolution;
            return a.packet.layer < b.packet.layer;
        },
    }
}

/// Builds ISO RPCL order for components whose precinct grids differ because
/// of SIZ sampling. Precinct positions are projected onto the image reference
/// grid, then merged as resolution, position, component, layer.
pub fn sampledRpclPackets(
    allocator: std.mem.Allocator,
    components: []const SampledComponentPlan,
    layers: u16,
    reference_x0: u32,
    reference_y0: u32,
) ![]Packet {
    return sampledOrderedPackets(allocator, components, layers, reference_x0, reference_y0, .rpcl);
}

/// Builds any Part 1 progression order over component-local precinct grids.
/// LRCP/RLCP retain component-local precinct order; RPCL/PCRL/CPRL compare
/// projected precinct positions on the common reference grid.
pub fn sampledOrderedPackets(
    allocator: std.mem.Allocator,
    components: []const SampledComponentPlan,
    layers: u16,
    reference_x0: u32,
    reference_y0: u32,
    order: SampledOrder,
) ![]Packet {
    if (components.len == 0 or components.len > std.math.maxInt(u16) or layers == 0) {
        return PacketPlanError.InvalidDimensions;
    }

    const resolution_count = components[0].plan.resolution_count;
    var total: u64 = 0;
    for (components) |component| {
        if (component.xrsiz == 0 or component.yrsiz == 0 or
            component.plan.resolution_count != resolution_count)
        {
            return PacketPlanError.InvalidDimensions;
        }
        try validatePlan(component.plan, 1, layers);
        total = std.math.add(u64, total, component.plan.packets) catch
            return PacketPlanError.InvalidDimensions;
    }

    const packet_count = std.math.cast(usize, total) orelse return PacketPlanError.InvalidDimensions;
    const keyed = try allocator.alloc(PositionKeyedPacket, packet_count);
    defer allocator.free(keyed);

    var count: usize = 0;
    for (components, 0..) |component, component_index| {
        var iterator = try RpclIterator.init(component.plan, 1, layers);
        while (iterator.next()) |local_packet| {
            if (count >= keyed.len) return PacketPlanError.InvalidDimensions;
            var packet = local_packet;
            packet.component = @intCast(component_index);
            const position = try sampledPacketPosition(component, packet, reference_x0, reference_y0);
            keyed[count] = .{
                .packet = packet,
                .x_ref = position.x_ref,
                .y_ref = position.y_ref,
            };
            count += 1;
        }
    }
    if (count != keyed.len) return PacketPlanError.InvalidDimensions;

    const Context = struct {
        order: SampledOrder,
        fn lessThan(self: @This(), a: PositionKeyedPacket, b: PositionKeyedPacket) bool {
            return sampledOrderLessThan(self.order, a, b);
        }
    };
    std.sort.pdq(PositionKeyedPacket, keyed, Context{ .order = order }, Context.lessThan);
    const packets = try allocator.alloc(Packet, packet_count);
    errdefer allocator.free(packets);
    for (keyed, 0..) |entry, index| {
        packets[index] = entry.packet;
        packets[index].sequence = @intCast(index);
    }
    return packets;
}

fn positionKeyLessThan(order: PositionOrder, a: PositionKeyedPacket, b: PositionKeyedPacket) bool {
    if (order == .cprl and a.packet.component != b.packet.component) {
        return a.packet.component < b.packet.component;
    }
    if (a.y_ref != b.y_ref) return a.y_ref < b.y_ref;
    if (a.x_ref != b.x_ref) return a.x_ref < b.x_ref;
    if (order == .pcrl and a.packet.component != b.packet.component) {
        return a.packet.component < b.packet.component;
    }
    if (a.packet.resolution != b.packet.resolution) return a.packet.resolution < b.packet.resolution;
    return a.packet.layer < b.packet.layer;
}

/// Builds the full packet sequence for a position-major progression. The
/// caller owns the returned slice. Sequence numbers are rewritten to the
/// position-major stream slots.
pub fn positionOrderedPackets(
    allocator: std.mem.Allocator,
    plan: Plan,
    components: u16,
    layers: u16,
    order: PositionOrder,
) ![]Packet {
    const total = std.math.cast(usize, plan.packets) orelse return PacketPlanError.InvalidDimensions;
    const keyed = try allocator.alloc(PositionKeyedPacket, total);
    defer allocator.free(keyed);

    var iterator = try RpclIterator.init(plan, components, layers);
    var count: usize = 0;
    while (iterator.next()) |packet| {
        if (count >= total) return PacketPlanError.InvalidDimensions;
        const position = try packetPosition(plan, packet);
        keyed[count] = .{
            .packet = packet,
            .x_ref = position.x_ref,
            .y_ref = position.y_ref,
        };
        count += 1;
    }
    if (count != total) return PacketPlanError.InvalidDimensions;

    const Context = struct {
        order: PositionOrder,
        fn lessThan(self: @This(), a: PositionKeyedPacket, b: PositionKeyedPacket) bool {
            return positionKeyLessThan(self.order, a, b);
        }
    };
    std.sort.pdq(PositionKeyedPacket, keyed, Context{ .order = order }, Context.lessThan);

    const packets = try allocator.alloc(Packet, total);
    errdefer allocator.free(packets);
    for (keyed, 0..) |entry, index| {
        packets[index] = entry.packet;
        packets[index].sequence = @intCast(index);
    }
    return packets;
}

/// Maps a packet identity to its slot in RPCL stream order, independent of
/// the order the packet was emitted in. Used to permute packet streams and
/// catalogs between progression orders.
pub fn rpclSequenceForPacket(plan: Plan, components: u16, layers: u16, packet: Packet) !u64 {
    if (packet.resolution >= plan.resolution_count) return PacketPlanError.InvalidDimensions;
    if (packet.component >= components or packet.layer >= layers) return PacketPlanError.InvalidDimensions;
    var offset: u64 = 0;
    for (plan.resolutions[0..packet.resolution]) |resolution| {
        offset = try std.math.add(u64, offset, resolution.packets);
    }
    if (packet.precinct_index >= plan.resolutions[packet.resolution].precincts) {
        return PacketPlanError.InvalidDimensions;
    }
    const packets_per_precinct = @as(u64, components) * layers;
    const precinct_offset = try std.math.mul(u64, packet.precinct_index, packets_per_precinct);
    return offset + precinct_offset + @as(u64, packet.component) * layers + packet.layer;
}

pub fn rpclPacketAt(plan: Plan, components: u16, layers: u16, sequence: u64) !?Packet {
    _ = try RpclIterator.init(plan, components, layers);
    if (sequence >= plan.packets) return null;

    var remaining = sequence;
    var resolution_index: usize = 0;
    while (resolution_index < plan.resolution_count) : (resolution_index += 1) {
        const resolution = plan.resolutions[resolution_index];
        if (remaining >= resolution.packets) {
            remaining -= resolution.packets;
            continue;
        }

        const packets_per_precinct = @as(u64, components) * layers;
        const precinct_index = remaining / packets_per_precinct;
        const in_precinct = remaining % packets_per_precinct;
        const component = in_precinct / layers;
        const layer = in_precinct % layers;
        return .{
            .sequence = sequence,
            .resolution = @intCast(resolution_index),
            .precinct_x = resolution.precinct_x0 + @as(u32, @intCast(precinct_index % resolution.precincts_x)),
            .precinct_y = resolution.precinct_y0 + @as(u32, @intCast(precinct_index / resolution.precincts_x)),
            .precinct_index = precinct_index,
            .component = @intCast(component),
            .layer = @intCast(layer),
        };
    }
    return null;
}

pub fn precinctRect(plan: Plan, resolution_index: u8, precinct_index: u64) !Rect {
    if (resolution_index >= plan.resolution_count) return PacketPlanError.InvalidDimensions;
    const resolution = plan.resolutions[resolution_index];
    if (precinct_index >= resolution.precincts) return PacketPlanError.InvalidDimensions;

    const precinct_x = resolution.precinct_x0 + @as(u32, @intCast(precinct_index % resolution.precincts_x));
    const precinct_y = resolution.precinct_y0 + @as(u32, @intCast(precinct_index / resolution.precincts_x));
    const precinct_left = @as(u64, precinct_x) * resolution.precinct_width;
    const precinct_top = @as(u64, precinct_y) * resolution.precinct_height;
    const resolution_right = @as(u64, resolution.x0) + resolution.width;
    const resolution_bottom = @as(u64, resolution.y0) + resolution.height;
    const left = @max(@as(u64, resolution.x0), precinct_left);
    const top = @max(@as(u64, resolution.y0), precinct_top);
    const right = @min(resolution_right, precinct_left + resolution.precinct_width);
    const bottom = @min(resolution_bottom, precinct_top + resolution.precinct_height);
    if (right <= left or bottom <= top) return PacketPlanError.InvalidDimensions;

    return .{
        .x = @intCast(left - resolution.x0),
        .y = @intCast(top - resolution.y0),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

pub fn rectsIntersect(a: Rect, b: Rect) bool {
    if (a.width == 0 or a.height == 0 or b.width == 0 or b.height == 0) return false;
    const a_right = @as(u64, a.x) + a.width;
    const a_bottom = @as(u64, a.y) + a.height;
    const b_right = @as(u64, b.x) + b.width;
    const b_bottom = @as(u64, b.y) + b.height;
    return @as(u64, a.x) < b_right and
        @as(u64, b.x) < a_right and
        @as(u64, a.y) < b_bottom and
        @as(u64, b.y) < a_bottom;
}

pub fn rpclSingleTile(
    width: usize,
    height: usize,
    levels: u8,
    components: u16,
    layers: u16,
    precincts: []const Precinct,
) !Plan {
    if (width > std.math.maxInt(u32) or height > std.math.maxInt(u32)) {
        return PacketPlanError.InvalidDimensions;
    }
    return rpclTileRegion(0, 0, @intCast(width), @intCast(height), levels, components, layers, precincts);
}

/// Builds a packet plan for a tile-component region while retaining the
/// reference-grid precinct partition. Coordinates are component-grid sample
/// coordinates (the current codec uses XRsiz/YRsiz = 1).
pub fn rpclTileRegion(
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,
    levels: u8,
    components: u16,
    layers: u16,
    precincts: []const Precinct,
) !Plan {
    if (x1 <= x0 or y1 <= y0 or components == 0 or layers == 0 or precincts.len == 0) {
        return PacketPlanError.InvalidDimensions;
    }
    if (levels > 32) return PacketPlanError.TooManyResolutions;

    var plan = Plan{
        .resolution_count = levels + 1,
        .resolutions = [_]Resolution{emptyResolution()} ** 33,
        .packets = 0,
    };

    var resolution: u8 = 0;
    while (resolution <= levels) : (resolution += 1) {
        const decomp = levels - resolution;
        const res_x0 = ceilDivPow2U32(x0, decomp);
        const res_y0 = ceilDivPow2U32(y0, decomp);
        const res_x1 = ceilDivPow2U32(x1, decomp);
        const res_y1 = ceilDivPow2U32(y1, decomp);
        if (res_x1 <= res_x0 or res_y1 <= res_y0) return PacketPlanError.InvalidDimensions;
        const res_width = res_x1 - res_x0;
        const res_height = res_y1 - res_y0;
        const precinct = precinctForResolution(precincts, resolution);
        if (precinct.width == 0 or precinct.height == 0) return PacketPlanError.InvalidDimensions;
        const precinct_x0 = res_x0 / precinct.width;
        const precinct_y0 = res_y0 / precinct.height;
        const precinct_x1 = ceilDiv(u32, res_x1, precinct.width);
        const precinct_y1 = ceilDiv(u32, res_y1, precinct.height);
        const precincts_x = precinct_x1 - precinct_x0;
        const precincts_y = precinct_y1 - precinct_y0;
        const precinct_count = try std.math.mul(u64, precincts_x, precincts_y);
        const precinct_packets = try std.math.mul(u64, precinct_count, components);
        const packets = try std.math.mul(u64, precinct_packets, layers);

        plan.resolutions[resolution] = .{
            .x0 = res_x0,
            .y0 = res_y0,
            .width = res_width,
            .height = res_height,
            .precinct_width = precinct.width,
            .precinct_height = precinct.height,
            .precinct_x0 = precinct_x0,
            .precinct_y0 = precinct_y0,
            .precincts_x = precincts_x,
            .precincts_y = precincts_y,
            .precincts = precinct_count,
            .packets = packets,
        };
        plan.packets += packets;
    }

    return plan;
}

fn validateResolution(resolution: Resolution, components: u16, layers: u16) !void {
    if (resolution.width == 0 or resolution.height == 0) return PacketPlanError.InvalidDimensions;
    if (resolution.precinct_width == 0 or resolution.precinct_height == 0) return PacketPlanError.InvalidDimensions;
    if (resolution.precincts_x == 0 or resolution.precincts_y == 0) return PacketPlanError.InvalidDimensions;
    const right = @as(u64, resolution.x0) + resolution.width;
    const bottom = @as(u64, resolution.y0) + resolution.height;
    if (right > std.math.maxInt(u32) or bottom > std.math.maxInt(u32)) return PacketPlanError.InvalidDimensions;
    const expected_x0 = resolution.x0 / resolution.precinct_width;
    const expected_y0 = resolution.y0 / resolution.precinct_height;
    const expected_x1 = ceilDiv(u64, right, resolution.precinct_width);
    const expected_y1 = ceilDiv(u64, bottom, resolution.precinct_height);
    if (resolution.precinct_x0 != expected_x0 or resolution.precinct_y0 != expected_y0) {
        return PacketPlanError.InvalidDimensions;
    }
    if (expected_x1 - expected_x0 != resolution.precincts_x or
        expected_y1 - expected_y0 != resolution.precincts_y)
    {
        return PacketPlanError.InvalidDimensions;
    }
    const precinct_count = try std.math.mul(u64, resolution.precincts_x, resolution.precincts_y);
    if (resolution.precincts != precinct_count) return PacketPlanError.InvalidDimensions;
    const precinct_packets = try std.math.mul(u64, resolution.precincts, components);
    const packets = try std.math.mul(u64, precinct_packets, layers);
    if (resolution.packets != packets) return PacketPlanError.InvalidDimensions;
}

fn emptyResolution() Resolution {
    return .{
        .width = 0,
        .height = 0,
        .precinct_width = 0,
        .precinct_height = 0,
        .precincts_x = 0,
        .precincts_y = 0,
        .precincts = 0,
        .packets = 0,
    };
}

fn ceilDivPow2U32(value: u32, shift: u8) u32 {
    if (shift == 0) return value;
    const divisor = @as(u64, 1) << @as(u6, @intCast(shift));
    return @intCast((@as(u64, value) + divisor - 1) / divisor);
}

fn precinctForResolution(precincts: []const Precinct, resolution: usize) Precinct {
    if (resolution < precincts.len) return precincts[resolution];
    return precincts[precincts.len - 1];
}

fn ceilDivPow2(value: usize, shift: u8) u32 {
    if (shift == 0) return @intCast(value);
    const divisor = @as(usize, 1) << @as(std.math.Log2Int(usize), @intCast(shift));
    return @intCast(((value - 1) / divisor) + 1);
}

fn ceilDiv(comptime T: type, numerator: T, denominator: T) T {
    return (numerator / denominator) + @intFromBool(numerator % denominator != 0);
}
