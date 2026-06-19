const std = @import("std");

pub const PacketPlanError = error{
    InvalidDimensions,
    TooManyResolutions,
};

pub const Precinct = struct {
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
        const precinct_count = @as(u64, precincts_x) * precincts_y;
        const packets = precinct_count * components * layers;

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
