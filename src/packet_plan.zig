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
    width: u32,
    height: u32,
    precinct_width: u32,
    precinct_height: u32,
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
                .precinct_x = @intCast(self.precinct_index % resolution.precincts_x),
                .precinct_y = @intCast(self.precinct_index / resolution.precincts_x),
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
            .precinct_x = @intCast(precinct_index % resolution.precincts_x),
            .precinct_y = @intCast(precinct_index / resolution.precincts_x),
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

    const precinct_x = @as(u32, @intCast(precinct_index % resolution.precincts_x));
    const precinct_y = @as(u32, @intCast(precinct_index / resolution.precincts_x));
    const x = precinct_x * resolution.precinct_width;
    const y = precinct_y * resolution.precinct_height;
    const right = @min(resolution.width, x + resolution.precinct_width);
    const bottom = @min(resolution.height, y + resolution.precinct_height);

    return .{
        .x = x,
        .y = y,
        .width = right - x,
        .height = bottom - y,
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
    if (width == 0 or height == 0 or components == 0 or layers == 0 or precincts.len == 0) {
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
        const res_width = ceilDivPow2(width, decomp);
        const res_height = ceilDivPow2(height, decomp);
        const precinct = precinctForResolution(precincts, resolution);
        const precincts_x = ceilDiv(u32, res_width, precinct.width);
        const precincts_y = ceilDiv(u32, res_height, precinct.height);
        const precinct_count = try std.math.mul(u64, precincts_x, precincts_y);
        const precinct_packets = try std.math.mul(u64, precinct_count, components);
        const packets = try std.math.mul(u64, precinct_packets, layers);

        plan.resolutions[resolution] = .{
            .width = res_width,
            .height = res_height,
            .precinct_width = precinct.width,
            .precinct_height = precinct.height,
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
