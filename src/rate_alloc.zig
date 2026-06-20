const std = @import("std");

pub const RateAllocError = error{
    InvalidLayerCount,
    InvalidRate,
    InvalidBlock,
};

pub const max_layers = 32;

pub const Block = struct {
    pass_count: u16,
    byte_length: u64,
};

pub const Truncation = struct {
    cumulative_passes: u16,
    cumulative_bytes: u64,
};

pub fn allocateEven(out: []Truncation, block: Block) !void {
    try validateLayerCount(out.len);
    try validateBlock(block);

    if (block.pass_count == 0 or block.byte_length == 0) {
        @memset(out, .{ .cumulative_passes = 0, .cumulative_bytes = 0 });
        return;
    }

    for (out, 0..) |*layer, index| {
        const layer_number = @as(u64, @intCast(index + 1));
        const layer_count = @as(u64, @intCast(out.len));
        const passes = ceilDiv(@as(u64, block.pass_count) * layer_number, layer_count);
        layer.* = truncationForPasses(block, @intCast(passes));
    }
    out[out.len - 1] = .{ .cumulative_passes = block.pass_count, .cumulative_bytes = block.byte_length };
}

pub fn allocateFromCompressionRatios(out: []Truncation, block: Block, rates: []const f64) !void {
    try validateLayerCount(out.len);
    try validateBlock(block);
    if (rates.len == 0) return allocateEven(out, block);
    if (rates.len > out.len) return RateAllocError.InvalidLayerCount;

    if (block.pass_count == 0 or block.byte_length == 0) {
        @memset(out, .{ .cumulative_passes = 0, .cumulative_bytes = 0 });
        return;
    }

    var previous_passes: u16 = 0;
    var previous_bytes: u64 = 0;
    for (out, 0..) |*layer, index| {
        const is_final = index == out.len - 1;
        const target_bytes = if (is_final)
            block.byte_length
        else if (index < rates.len)
            try targetBytesForRate(block.byte_length, rates[index])
        else
            interpolatedBytes(previous_bytes, block.byte_length, out.len - index);

        const clamped_bytes = @min(block.byte_length, @max(previous_bytes, target_bytes));
        var passes = passesForBytes(block, clamped_bytes);
        passes = @max(previous_passes, passes);
        layer.* = truncationForPasses(block, passes);
        previous_passes = layer.cumulative_passes;
        previous_bytes = layer.cumulative_bytes;
    }
    out[out.len - 1] = .{ .cumulative_passes = block.pass_count, .cumulative_bytes = block.byte_length };
}

fn validateLayerCount(layer_count: usize) !void {
    if (layer_count == 0 or layer_count > max_layers) return RateAllocError.InvalidLayerCount;
}

fn validateBlock(block: Block) !void {
    if (block.pass_count > 164) return RateAllocError.InvalidBlock;
    if (block.pass_count == 0 and block.byte_length != 0) return RateAllocError.InvalidBlock;
}

fn targetBytesForRate(full_bytes: u64, rate: f64) !u64 {
    if (!std.math.isFinite(rate) or rate <= 0) return RateAllocError.InvalidRate;
    const target = @as(f64, @floatFromInt(full_bytes)) / rate;
    if (target <= 1) return 1;
    if (target >= @as(f64, @floatFromInt(full_bytes))) return full_bytes;
    return @intFromFloat(@ceil(target));
}

fn interpolatedBytes(previous: u64, full: u64, remaining_layers: usize) u64 {
    if (remaining_layers <= 1) return full;
    const remaining_bytes = full - previous;
    return previous + ceilDiv(remaining_bytes, @intCast(remaining_layers));
}

fn passesForBytes(block: Block, bytes: u64) u16 {
    if (bytes == 0) return 0;
    const passes = ceilDiv(bytes * @as(u64, block.pass_count), block.byte_length);
    return @intCast(@min(@as(u64, block.pass_count), passes));
}

fn truncationForPasses(block: Block, passes: u16) Truncation {
    if (passes == 0) return .{ .cumulative_passes = 0, .cumulative_bytes = 0 };
    if (passes >= block.pass_count) return .{ .cumulative_passes = block.pass_count, .cumulative_bytes = block.byte_length };
    return .{
        .cumulative_passes = passes,
        .cumulative_bytes = ceilDiv(block.byte_length * @as(u64, passes), @as(u64, block.pass_count)),
    };
}

fn ceilDiv(numerator: u64, denominator: u64) u64 {
    return (numerator + denominator - 1) / denominator;
}
