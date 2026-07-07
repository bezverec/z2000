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

/// One code-block's rate-distortion data for global PCRD allocation
/// (ISO 15444-1 J.14): cumulative payload bytes after each coding pass and
/// the (band-weighted) squared-error reduction each pass contributes.
pub const PcrdBlock = struct {
    pass_bytes: []const u64,
    pass_distortion: []const f64,
};

const PcrdHullPoint = struct {
    passes: u16,
    bytes: u64,
    distortion: f64,
    slope: f64,
};

/// Cumulative byte targets per layer from compression ratios, mirroring the
/// per-block `allocateFromCompressionRatios` shape at image scale: explicit
/// ratios first, interpolation toward the full size for remaining layers,
/// the final layer always the full byte count.
pub fn layerTargetsFromRates(targets: []u64, total_bytes: u64, rates: []const f64) !void {
    try validateLayerCount(targets.len);
    if (rates.len > targets.len) return RateAllocError.InvalidLayerCount;
    var previous: u64 = 0;
    for (targets, 0..) |*target, index| {
        const is_final = index == targets.len - 1;
        const raw = if (is_final)
            total_bytes
        else if (index < rates.len)
            try targetBytesForRate(total_bytes, rates[index])
        else
            interpolatedBytes(previous, total_bytes, targets.len - index);
        target.* = @min(total_bytes, @max(previous, raw));
        previous = target.*;
    }
}

/// Global PCRD pass allocation. Builds each block's convex hull over
/// (cumulative bytes, cumulative distortion) truncation candidates, then for
/// every layer's cumulative byte target finds the smallest slope threshold
/// lambda whose selections fit the budget (selections never regress across
/// layers). The final layer always takes every pass, matching the existing
/// layer conventions. `out_passes` is block-major:
/// out_passes[block * layer_count + layer] = cumulative passes.
pub fn allocatePcrdPasses(
    allocator: std.mem.Allocator,
    blocks: []const PcrdBlock,
    layer_targets: []const u64,
    out_passes: []u16,
) !void {
    try validateLayerCount(layer_targets.len);
    const layer_count = layer_targets.len;
    if (out_passes.len != blocks.len * layer_count) return RateAllocError.InvalidBlock;

    // Per-block convex hulls stored back to back; hull slopes are strictly
    // decreasing within one block.
    var hull_points: std.ArrayList(PcrdHullPoint) = .empty;
    defer hull_points.deinit(allocator);
    const hull_offsets = try allocator.alloc(usize, blocks.len + 1);
    defer allocator.free(hull_offsets);

    for (blocks, 0..) |block, block_index| {
        hull_offsets[block_index] = hull_points.items.len;
        if (block.pass_bytes.len != block.pass_distortion.len) return RateAllocError.InvalidBlock;
        if (block.pass_bytes.len > 164) return RateAllocError.InvalidBlock;

        var cumulative_distortion: f64 = 0;
        var previous_bytes: u64 = 0;
        for (block.pass_bytes, block.pass_distortion, 0..) |bytes, distortion, pass_index| {
            if (bytes < previous_bytes) return RateAllocError.InvalidBlock;
            previous_bytes = bytes;
            cumulative_distortion += @max(distortion, 0);
            if (bytes == 0) continue;

            var candidate = PcrdHullPoint{
                .passes = @intCast(pass_index + 1),
                .bytes = bytes,
                .distortion = cumulative_distortion,
                .slope = 0,
            };
            // Upper convex hull on (bytes, distortion): pop points the
            // candidate dominates (no byte growth) or whose slope would not
            // strictly decrease along the hull.
            while (hull_points.items.len > hull_offsets[block_index]) {
                const top = hull_points.items[hull_points.items.len - 1];
                if (candidate.bytes == top.bytes) {
                    _ = hull_points.pop();
                    continue;
                }
                const candidate_slope = (candidate.distortion - top.distortion) /
                    @as(f64, @floatFromInt(candidate.bytes - top.bytes));
                if (candidate_slope >= top.slope) {
                    _ = hull_points.pop();
                    continue;
                }
                candidate.slope = candidate_slope;
                break;
            }
            if (hull_points.items.len == hull_offsets[block_index]) {
                candidate.slope = candidate.distortion / @as(f64, @floatFromInt(candidate.bytes));
            }
            try hull_points.append(allocator, candidate);
        }
    }
    hull_offsets[blocks.len] = hull_points.items.len;

    // The finite, sorted (descending) set of candidate thresholds.
    var slopes = try allocator.alloc(f64, hull_points.items.len);
    defer allocator.free(slopes);
    for (hull_points.items, 0..) |point, index| slopes[index] = point.slope;
    std.sort.pdq(f64, slopes, {}, std.sort.desc(f64));

    // Per-block selection floor (hull index count already committed by
    // earlier layers; 0 = nothing selected yet).
    const floors = try allocator.alloc(usize, blocks.len);
    defer allocator.free(floors);
    @memset(floors, 0);

    for (layer_targets, 0..) |target, layer| {
        const is_final = layer == layer_count - 1;
        if (is_final) {
            for (blocks, 0..) |block, block_index| {
                out_passes[block_index * layer_count + layer] = @intCast(block.pass_bytes.len);
            }
            break;
        }

        // Find the smallest threshold whose total still fits the budget;
        // totals grow monotonically as the threshold drops.
        var chosen_slope = std.math.inf(f64);
        var low: usize = 0;
        var high: usize = slopes.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const total = pcrdTotalBytes(hull_points.items, hull_offsets, floors, slopes[mid]);
            if (total <= target) {
                chosen_slope = slopes[mid];
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        for (blocks, 0..) |_, block_index| {
            const hull = hull_points.items[hull_offsets[block_index]..hull_offsets[block_index + 1]];
            var selected = floors[block_index];
            while (selected < hull.len and hull[selected].slope >= chosen_slope) : (selected += 1) {}
            floors[block_index] = selected;
            out_passes[block_index * layer_count + layer] =
                if (selected == 0) 0 else hull[selected - 1].passes;
        }
    }
}

fn pcrdTotalBytes(
    hull_points: []const PcrdHullPoint,
    hull_offsets: []const usize,
    floors: []const usize,
    slope_threshold: f64,
) u64 {
    var total: u64 = 0;
    for (floors, 0..) |floor, block_index| {
        const hull = hull_points[hull_offsets[block_index]..hull_offsets[block_index + 1]];
        var selected = floor;
        while (selected < hull.len and hull[selected].slope >= slope_threshold) : (selected += 1) {}
        if (selected > 0) total += hull[selected - 1].bytes;
    }
    return total;
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
