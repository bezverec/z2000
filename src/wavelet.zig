const std = @import("std");
const simd = @import("simd.zig");

pub const Wavelet = enum(u8) {
    reversible_5_3 = 0,
    irreversible_9_7 = 1,

    pub fn label(self: Wavelet) []const u8 {
        return switch (self) {
            .reversible_5_3 => "5-3",
            .irreversible_9_7 => "9-7",
        };
    }
};

pub const TransformError = error{
    InvalidDimensions,
    TooManyLevels,
};

pub const ResolutionShape = struct {
    width: usize,
    height: usize,
    x0: u32 = 0,
    y0: u32 = 0,
};

const LevelShape = ResolutionShape;

const dwt97_alpha: f32 = -1.586134342059924;
const dwt97_beta: f32 = -0.052980118572961;
const dwt97_gamma: f32 = 0.882911075530934;
const dwt97_delta: f32 = 0.443506852043971;
// ISO/IEC 15444-1 F.4.8.2 / OpenJPEG: lowpass scales by 1/K, highpass by K.
const dwt97_k: f32 = 1.230174104914001;
const dwt97_inv_k: f32 = 1.0 / dwt97_k;

pub fn forward2D(
    allocator: std.mem.Allocator,
    data: []f32,
    width: usize,
    height: usize,
    requested_levels: u8,
    wavelet: Wavelet,
) !u8 {
    return forward2DOrigin(allocator, data, width, height, requested_levels, wavelet, 0, 0);
}

pub fn forward2DOrigin(
    allocator: std.mem.Allocator,
    data: []f32,
    width: usize,
    height: usize,
    requested_levels: u8,
    wavelet: Wavelet,
    x0: u32,
    y0: u32,
) !u8 {
    if (width == 0 or height == 0 or data.len != width * height) {
        return TransformError.InvalidDimensions;
    }

    const max_dim = @max(width, height);
    var line = try allocator.alloc(f32, max_dim);
    defer allocator.free(line);
    var scratch = try allocator.alloc(f32, max_dim);
    defer allocator.free(scratch);
    const vertical_scratch_len = if (wavelet == .irreversible_9_7)
        ((height + 1) / 2) * f32_block_lanes
    else
        0;
    const vertical_scratch = try allocator.alloc(f32, vertical_scratch_len);
    defer allocator.free(vertical_scratch);

    var cur_width = width;
    var cur_height = height;
    var cur_x0 = x0;
    var cur_y0 = y0;
    var done: u8 = 0;

    while (done < requested_levels and (cur_width > 1 or cur_height > 1)) : (done += 1) {
        const next_width = lowCountOrigin(cur_width, cur_x0);
        const next_height = lowCountOrigin(cur_height, cur_y0);
        if (next_width == 0 or next_height == 0) break;
        // ISO/IEC 15444-1 F.4.8: forward transform filters vertically first,
        // then horizontally, matching independent codecs.
        var col: usize = 0;
        if (wavelet == .irreversible_9_7 and cur_height >= 2) {
            // Whole cache-line column bands take the wide-vector kernel; the
            // remainder falls back to the per-column line path below.
            while (col + f32_block_lanes <= cur_width) : (col += f32_block_lanes) {
                forward97VerticalBand(data, width, col, cur_height, (cur_y0 & 1) == 1, vertical_scratch);
            }
        }
        while (col < cur_width) : (col += 1) {
            for (0..cur_height) |row| line[row] = data[row * width + col];
            forward1DOrigin(line[0..cur_height], scratch[0..cur_height], wavelet, cur_y0);
            for (0..cur_height) |row| data[row * width + col] = line[row];
        }

        for (0..cur_height) |row| {
            forward1DOrigin(data[row * width ..][0..cur_width], scratch[0..cur_width], wavelet, cur_x0);
        }

        cur_width = next_width;
        cur_height = next_height;
        cur_x0 = ceilDiv2(cur_x0);
        cur_y0 = ceilDiv2(cur_y0);
    }

    return done;
}

pub fn inverse2D(
    allocator: std.mem.Allocator,
    data: []f32,
    width: usize,
    height: usize,
    levels: u8,
    wavelet: Wavelet,
) !void {
    return inverse2DOrigin(allocator, data, width, height, levels, wavelet, 0, 0);
}

pub fn inverse2DOrigin(
    allocator: std.mem.Allocator,
    data: []f32,
    width: usize,
    height: usize,
    levels: u8,
    wavelet: Wavelet,
    x0: u32,
    y0: u32,
) !void {
    _ = try inverse2DReducedOrigin(allocator, data, width, height, levels, 0, wavelet, x0, y0);
}

pub fn inverse2DReducedOrigin(
    allocator: std.mem.Allocator,
    data: []f32,
    width: usize,
    height: usize,
    levels: u8,
    reduction: u8,
    wavelet: Wavelet,
    x0: u32,
    y0: u32,
) !ResolutionShape {
    if (width == 0 or height == 0 or data.len != width * height) {
        return TransformError.InvalidDimensions;
    }
    if (reduction > levels) return TransformError.InvalidDimensions;

    var shapes: [32]LevelShape = undefined;
    var resolutions: [33]ResolutionShape = undefined;
    if (levels > shapes.len) return TransformError.TooManyLevels;

    var cur_width = width;
    var cur_height = height;
    var cur_x0 = x0;
    var cur_y0 = y0;
    resolutions[0] = .{ .width = width, .height = height, .x0 = x0, .y0 = y0 };
    var actual_levels: u8 = 0;
    while (actual_levels < levels and (cur_width > 1 or cur_height > 1)) : (actual_levels += 1) {
        shapes[actual_levels] = .{ .width = cur_width, .height = cur_height, .x0 = cur_x0, .y0 = cur_y0 };
        cur_width = lowCountOrigin(cur_width, cur_x0);
        cur_height = lowCountOrigin(cur_height, cur_y0);
        if (cur_width == 0 or cur_height == 0) return TransformError.InvalidDimensions;
        cur_x0 = ceilDiv2(cur_x0);
        cur_y0 = ceilDiv2(cur_y0);
        resolutions[@as(usize, actual_levels) + 1] = .{
            .width = cur_width,
            .height = cur_height,
            .x0 = cur_x0,
            .y0 = cur_y0,
        };
    }
    if (reduction > actual_levels) return TransformError.InvalidDimensions;

    const max_dim = @max(width, height);
    var line = try allocator.alloc(f32, max_dim);
    defer allocator.free(line);
    var scratch = try allocator.alloc(f32, max_dim);
    defer allocator.free(scratch);
    const vertical_scratch_len = if (wavelet == .irreversible_9_7)
        ((height + 1) / 2) * f32_block_lanes
    else
        0;
    const vertical_scratch = try allocator.alloc(f32, vertical_scratch_len);
    defer allocator.free(vertical_scratch);

    var level = actual_levels;
    while (level > reduction) {
        level -= 1;
        const shape = shapes[level];

        // Mirror of the ISO forward order: horizontal first, then vertical.
        for (0..shape.height) |row| {
            inverse1DOrigin(data[row * width ..][0..shape.width], scratch[0..shape.width], wavelet, shape.x0);
        }

        var col: usize = 0;
        if (wavelet == .irreversible_9_7 and shape.height >= 2) {
            while (col + f32_block_lanes <= shape.width) : (col += f32_block_lanes) {
                inverse97VerticalBand(data, width, col, shape.height, (shape.y0 & 1) == 1, vertical_scratch);
            }
        }
        while (col < shape.width) : (col += 1) {
            for (0..shape.height) |row| line[row] = data[row * width + col];
            inverse1DOrigin(line[0..shape.height], scratch[0..shape.height], wavelet, shape.y0);
            for (0..shape.height) |row| data[row * width + col] = line[row];
        }
    }
    return resolutions[reduction];
}

fn lowCount(n: usize) usize {
    return (n + 1) / 2;
}

fn lowCountOrigin(n: usize, origin: u32) usize {
    return if ((origin & 1) == 0) (n + 1) / 2 else n / 2;
}

fn ceilDiv2(value: u32) u32 {
    return (value / 2) + @intFromBool((value & 1) != 0);
}

fn forward1DOrigin(data: []f32, scratch: []f32, wavelet: Wavelet, origin: u32) void {
    if (data.len < 2) return;
    switch (wavelet) {
        .reversible_5_3 => if ((origin & 1) == 0) forward53(data, scratch) else forward53OddOrigin(data, scratch),
        .irreversible_9_7 => if ((origin & 1) == 0) forward97(data, scratch) else forward97OddOrigin(data, scratch),
    }
}

fn inverse1DOrigin(data: []f32, scratch: []f32, wavelet: Wavelet, origin: u32) void {
    if (data.len < 2) return;
    switch (wavelet) {
        .reversible_5_3 => if ((origin & 1) == 0) inverse53(data, scratch) else inverse53OddOrigin(data, scratch),
        .irreversible_9_7 => if ((origin & 1) == 0) inverse97(data, scratch) else inverse97OddOrigin(data, scratch),
    }
}

fn forward53(data: []f32, scratch: []f32) void {
    var i: usize = 1;
    while (i < data.len) : (i += 2) {
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] -= @floor((data[i - 1] + right) / 2.0);
    }

    i = 0;
    while (i < data.len) : (i += 2) {
        const left = if (i > 0) data[i - 1] else data[1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += @floor((left + right + 2.0) / 4.0);
    }

    packEvenOdd(data, scratch);
}

fn inverse53(data: []f32, scratch: []f32) void {
    unpackEvenOdd(data, scratch);

    var i: usize = 0;
    while (i < data.len) : (i += 2) {
        const left = if (i > 0) data[i - 1] else data[1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] -= @floor((left + right + 2.0) / 4.0);
    }

    i = 1;
    while (i < data.len) : (i += 2) {
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += @floor((data[i - 1] + right) / 2.0);
    }
}

fn forward53OddOrigin(data: []f32, scratch: []f32) void {
    var i: usize = 0;
    while (i < data.len) : (i += 2) {
        const left = if (i > 0) data[i - 1] else data[i + 1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] -= @floor((left + right) / 2.0);
    }

    i = 1;
    while (i < data.len) : (i += 2) {
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += @floor((data[i - 1] + right + 2.0) / 4.0);
    }
    packOddEven(data, scratch);
}

fn inverse53OddOrigin(data: []f32, scratch: []f32) void {
    unpackOddEven(data, scratch);

    var i: usize = 1;
    while (i < data.len) : (i += 2) {
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] -= @floor((data[i - 1] + right + 2.0) / 4.0);
    }

    i = 0;
    while (i < data.len) : (i += 2) {
        const left = if (i > 0) data[i - 1] else data[i + 1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += @floor((left + right) / 2.0);
    }
}

// The 9/7 lifting kernels work on the line split into its even-position and
// odd-position halves so every step is a contiguous wide-vector pass instead
// of a per-sample gather over the interleaved layout. The per-element
// arithmetic (operand values and operation order) is identical to the
// interleaved formulation, so results stay bit-identical.
//
// Boundary rules mirror ISO 15444-1 F.4.8 symmetric extension and depend only
// on array-index parity, so the same two kernels serve both line origins: an
// odd origin merely swaps the lift order, the K scales, and the pack order.

fn forward97(data: []f32, scratch: []f32) void {
    const even_count = (data.len + 1) / 2;
    const even = scratch[0..even_count];
    const odd = scratch[even_count..data.len];
    deinterleaveSplit(data, even, odd);
    liftSplitOdd(even, odd, dwt97_alpha);
    liftSplitEven(even, odd, dwt97_beta);
    liftSplitOdd(even, odd, dwt97_gamma);
    liftSplitEven(even, odd, dwt97_delta);
    scaleSplit(even, dwt97_inv_k);
    scaleSplit(odd, dwt97_k);
    @memcpy(data[0..even_count], even);
    @memcpy(data[even_count..], odd);
}

fn inverse97(data: []f32, scratch: []f32) void {
    const even_count = (data.len + 1) / 2;
    const even = scratch[0..even_count];
    const odd = scratch[even_count..data.len];
    @memcpy(even, data[0..even_count]);
    @memcpy(odd, data[even_count..]);
    scaleSplit(even, dwt97_k);
    scaleSplit(odd, dwt97_inv_k);
    liftSplitEven(even, odd, -dwt97_delta);
    liftSplitOdd(even, odd, -dwt97_gamma);
    liftSplitEven(even, odd, -dwt97_beta);
    liftSplitOdd(even, odd, -dwt97_alpha);
    interleaveSplit(data, even, odd);
}

fn forward97OddOrigin(data: []f32, scratch: []f32) void {
    const even_count = (data.len + 1) / 2;
    const odd_count = data.len / 2;
    const even = scratch[0..even_count];
    const odd = scratch[even_count..data.len];
    deinterleaveSplit(data, even, odd);
    liftSplitEven(even, odd, dwt97_alpha);
    liftSplitOdd(even, odd, dwt97_beta);
    liftSplitEven(even, odd, dwt97_gamma);
    liftSplitOdd(even, odd, dwt97_delta);
    scaleSplit(even, dwt97_k);
    scaleSplit(odd, dwt97_inv_k);
    @memcpy(data[0..odd_count], odd);
    @memcpy(data[odd_count..], even);
}

fn inverse97OddOrigin(data: []f32, scratch: []f32) void {
    const even_count = (data.len + 1) / 2;
    const odd_count = data.len / 2;
    const even = scratch[0..even_count];
    const odd = scratch[even_count..data.len];
    @memcpy(odd, data[0..odd_count]);
    @memcpy(even, data[odd_count..]);
    scaleSplit(even, dwt97_inv_k);
    scaleSplit(odd, dwt97_k);
    liftSplitOdd(even, odd, -dwt97_delta);
    liftSplitEven(even, odd, -dwt97_gamma);
    liftSplitOdd(even, odd, -dwt97_beta);
    liftSplitEven(even, odd, -dwt97_alpha);
    interleaveSplit(data, even, odd);
}

const F32Block = @Vector(simd.f32_block_lanes, f32);
const f32_block_lanes = simd.f32_block_lanes;

/// odd[j] += c * (even[j] + even[j+1]), mirroring the final right neighbor
/// when the line ends on an odd position (even.len == odd.len).
fn liftSplitOdd(even: []f32, odd: []f32, coefficient: f32) void {
    const coeff: F32Block = @splat(coefficient);
    var j: usize = 0;
    while (j + f32_block_lanes <= odd.len and j + 1 + f32_block_lanes <= even.len) : (j += f32_block_lanes) {
        const target: F32Block = odd[j..][0..f32_block_lanes].*;
        const left: F32Block = even[j..][0..f32_block_lanes].*;
        const right: F32Block = even[j + 1 ..][0..f32_block_lanes].*;
        odd[j..][0..f32_block_lanes].* = @as([f32_block_lanes]f32, target + coeff * (left + right));
    }
    while (j < odd.len) : (j += 1) {
        const right = if (j + 1 < even.len) even[j + 1] else even[j];
        odd[j] += coefficient * (even[j] + right);
    }
}

/// even[j] += c * (odd[j-1] + odd[j]), mirroring odd[0] on the left edge and
/// the final left neighbor when the line ends on an even position.
fn liftSplitEven(even: []f32, odd: []f32, coefficient: f32) void {
    const coeff: F32Block = @splat(coefficient);
    even[0] += coefficient * (odd[0] + odd[0]);
    var j: usize = 1;
    while (j + f32_block_lanes <= odd.len) : (j += f32_block_lanes) {
        const target: F32Block = even[j..][0..f32_block_lanes].*;
        const left: F32Block = odd[j - 1 ..][0..f32_block_lanes].*;
        const right: F32Block = odd[j..][0..f32_block_lanes].*;
        even[j..][0..f32_block_lanes].* = @as([f32_block_lanes]f32, target + coeff * (left + right));
    }
    while (j < even.len) : (j += 1) {
        const right = if (j < odd.len) odd[j] else odd[j - 1];
        even[j] += coefficient * (odd[j - 1] + right);
    }
}

fn scaleSplit(half: []f32, scale: f32) void {
    const scales: F32Block = @splat(scale);
    var j: usize = 0;
    while (j + f32_block_lanes <= half.len) : (j += f32_block_lanes) {
        const block: F32Block = half[j..][0..f32_block_lanes].*;
        half[j..][0..f32_block_lanes].* = @as([f32_block_lanes]f32, block * scales);
    }
    while (j < half.len) : (j += 1) {
        half[j] *= scale;
    }
}

fn deinterleaveSplit(data: []const f32, even: []f32, odd: []f32) void {
    for (odd, 0..) |*value, j| {
        even[j] = data[2 * j];
        value.* = data[2 * j + 1];
    }
    if (even.len > odd.len) even[odd.len] = data[2 * odd.len];
}

fn interleaveSplit(data: []f32, even: []const f32, odd: []const f32) void {
    for (odd, 0..) |value, j| {
        data[2 * j] = even[j];
        data[2 * j + 1] = value;
    }
    if (even.len > odd.len) data[2 * odd.len] = even[odd.len];
}

// Vertical 9/7 over a band of f32_block_lanes columns at once: each lifting
// step is one wide vector op per row instead of a per-column strided gather,
// and one row access spans exactly one cache line. The row-parity boundary
// rules are the same as the split kernels above, so the per-column arithmetic
// is bit-identical to running the 1D transform on each column.

inline fn loadRow(data: []const f32, index: usize) F32Block {
    return data[index..][0..f32_block_lanes].*;
}

inline fn storeRow(data: []f32, index: usize, block: F32Block) void {
    data[index..][0..f32_block_lanes].* = @as([f32_block_lanes]f32, block);
}

fn forward97VerticalBand(
    data: []f32,
    stride: usize,
    col: usize,
    height: usize,
    origin_odd: bool,
    pack_scratch: []f32,
) void {
    if (!origin_odd) {
        liftVerticalOdd(data, stride, col, height, dwt97_alpha);
        liftVerticalEven(data, stride, col, height, dwt97_beta);
        liftVerticalOdd(data, stride, col, height, dwt97_gamma);
        liftVerticalEven(data, stride, col, height, dwt97_delta);
        scaleVertical(data, stride, col, height, dwt97_inv_k, dwt97_k);
        packVertical(data, stride, col, height, false, pack_scratch);
    } else {
        liftVerticalEven(data, stride, col, height, dwt97_alpha);
        liftVerticalOdd(data, stride, col, height, dwt97_beta);
        liftVerticalEven(data, stride, col, height, dwt97_gamma);
        liftVerticalOdd(data, stride, col, height, dwt97_delta);
        scaleVertical(data, stride, col, height, dwt97_k, dwt97_inv_k);
        packVertical(data, stride, col, height, true, pack_scratch);
    }
}

fn inverse97VerticalBand(
    data: []f32,
    stride: usize,
    col: usize,
    height: usize,
    origin_odd: bool,
    pack_scratch: []f32,
) void {
    if (!origin_odd) {
        unpackVertical(data, stride, col, height, false, pack_scratch);
        scaleVertical(data, stride, col, height, dwt97_k, dwt97_inv_k);
        liftVerticalEven(data, stride, col, height, -dwt97_delta);
        liftVerticalOdd(data, stride, col, height, -dwt97_gamma);
        liftVerticalEven(data, stride, col, height, -dwt97_beta);
        liftVerticalOdd(data, stride, col, height, -dwt97_alpha);
    } else {
        unpackVertical(data, stride, col, height, true, pack_scratch);
        scaleVertical(data, stride, col, height, dwt97_inv_k, dwt97_k);
        liftVerticalOdd(data, stride, col, height, -dwt97_delta);
        liftVerticalEven(data, stride, col, height, -dwt97_gamma);
        liftVerticalOdd(data, stride, col, height, -dwt97_beta);
        liftVerticalEven(data, stride, col, height, -dwt97_alpha);
    }
}

fn liftVerticalOdd(data: []f32, stride: usize, col: usize, height: usize, coefficient: f32) void {
    const coeff: F32Block = @splat(coefficient);
    var row: usize = 1;
    while (row < height) : (row += 2) {
        const right_row = if (row + 1 < height) row + 1 else row - 1;
        const target = loadRow(data, row * stride + col);
        const left = loadRow(data, (row - 1) * stride + col);
        const right = loadRow(data, right_row * stride + col);
        storeRow(data, row * stride + col, target + coeff * (left + right));
    }
}

fn liftVerticalEven(data: []f32, stride: usize, col: usize, height: usize, coefficient: f32) void {
    const coeff: F32Block = @splat(coefficient);
    var row: usize = 0;
    while (row < height) : (row += 2) {
        const left_row = if (row > 0) row - 1 else 1;
        const right_row = if (row + 1 < height) row + 1 else row - 1;
        const target = loadRow(data, row * stride + col);
        const left = loadRow(data, left_row * stride + col);
        const right = loadRow(data, right_row * stride + col);
        storeRow(data, row * stride + col, target + coeff * (left + right));
    }
}

fn scaleVertical(data: []f32, stride: usize, col: usize, height: usize, even_scale: f32, odd_scale: f32) void {
    const evens: F32Block = @splat(even_scale);
    const odds: F32Block = @splat(odd_scale);
    var row: usize = 0;
    while (row < height) : (row += 1) {
        const scales = if ((row & 1) == 0) evens else odds;
        storeRow(data, row * stride + col, loadRow(data, row * stride + col) * scales);
    }
}

/// Reorder the band's rows into low|high halves: even rows first for an even
/// origin, odd rows first for an odd origin. The soon-to-be high half is
/// staged in pack_scratch so the in-place compaction cannot clobber it.
fn packVertical(data: []f32, stride: usize, col: usize, height: usize, origin_odd: bool, pack_scratch: []f32) void {
    const first_parity: usize = if (origin_odd) 1 else 0;
    const second_parity: usize = 1 - first_parity;
    const first_count = if (origin_odd) height / 2 else (height + 1) / 2;

    var staged: usize = 0;
    var row: usize = second_parity;
    while (row < height) : (row += 2) {
        @memcpy(pack_scratch[staged * f32_block_lanes ..][0..f32_block_lanes], data[row * stride + col ..][0..f32_block_lanes]);
        staged += 1;
    }
    var out: usize = 0;
    row = first_parity;
    while (row < height) : (row += 2) {
        if (out != row) {
            @memcpy(data[out * stride + col ..][0..f32_block_lanes], data[row * stride + col ..][0..f32_block_lanes]);
        }
        out += 1;
    }
    for (0..staged) |j| {
        @memcpy(
            data[(first_count + j) * stride + col ..][0..f32_block_lanes],
            pack_scratch[j * f32_block_lanes ..][0..f32_block_lanes],
        );
    }
}

/// Inverse of packVertical: spread the low|high halves back to interleaved
/// row parities. The high half is staged first because expanding the low half
/// in place overwrites the band's tail rows.
fn unpackVertical(data: []f32, stride: usize, col: usize, height: usize, origin_odd: bool, pack_scratch: []f32) void {
    const first_parity: usize = if (origin_odd) 1 else 0;
    const second_parity: usize = 1 - first_parity;
    const first_count = if (origin_odd) height / 2 else (height + 1) / 2;
    const second_count = height - first_count;

    for (0..second_count) |j| {
        @memcpy(
            pack_scratch[j * f32_block_lanes ..][0..f32_block_lanes],
            data[(first_count + j) * stride + col ..][0..f32_block_lanes],
        );
    }
    var j = first_count;
    while (j > 0) {
        j -= 1;
        const dest = 2 * j + first_parity;
        if (dest != j) {
            @memcpy(data[dest * stride + col ..][0..f32_block_lanes], data[j * stride + col ..][0..f32_block_lanes]);
        }
    }
    for (0..second_count) |k| {
        @memcpy(
            data[(2 * k + second_parity) * stride + col ..][0..f32_block_lanes],
            pack_scratch[k * f32_block_lanes ..][0..f32_block_lanes],
        );
    }
}

fn packEvenOdd(data: []f32, scratch: []f32) void {
    var out: usize = 0;
    var i: usize = 0;
    while (i < data.len) : (i += 2) {
        scratch[out] = data[i];
        out += 1;
    }

    i = 1;
    while (i < data.len) : (i += 2) {
        scratch[out] = data[i];
        out += 1;
    }

    @memcpy(data, scratch[0..data.len]);
}

fn unpackEvenOdd(data: []f32, scratch: []f32) void {
    const lows = lowCount(data.len);

    var low: usize = 0;
    var high: usize = lows;
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (i % 2 == 0) {
            scratch[i] = data[low];
            low += 1;
        } else {
            scratch[i] = data[high];
            high += 1;
        }
    }

    @memcpy(data, scratch[0..data.len]);
}

fn packOddEven(data: []f32, scratch: []f32) void {
    var out: usize = 0;
    var i: usize = 1;
    while (i < data.len) : (i += 2) {
        scratch[out] = data[i];
        out += 1;
    }
    i = 0;
    while (i < data.len) : (i += 2) {
        scratch[out] = data[i];
        out += 1;
    }
    @memcpy(data, scratch[0..data.len]);
}

fn unpackOddEven(data: []f32, scratch: []f32) void {
    const lows = data.len / 2;
    var low: usize = 0;
    var high: usize = lows;
    for (0..data.len) |i| {
        if ((i & 1) != 0) {
            scratch[i] = data[low];
            low += 1;
        } else {
            scratch[i] = data[high];
            high += 1;
        }
    }
    @memcpy(data, scratch[0..data.len]);
}

// ---------------------------------------------------------------------------
// Parallel multi-component 9/7 DWT.
//
// Same design as wavelet_int's 5/3 driver: the per-level cascade is
// sequential, but within a level the column transforms are mutually
// independent and so are the row transforms. The per-plane job structure in
// the lossy pipeline caps DWT parallelism at three component threads; this
// driver distributes the three planes' column bands and row bands across
// `thread_count` workers with private scratch. The per-column and per-row
// arithmetic is exactly the serial `forward2DOrigin` / `inverse2DOrigin`
// kernels, so output stays bit-identical (covered by a unit test).
// ---------------------------------------------------------------------------

// Wide 9/7 bands are memory-heavy and short-lived. More than eight workers
// adds phase-spawn and SMT contention on the maintained x86 benchmark host;
// T1 still receives the full caller thread count.
const max_dwt_workers = 8;

const Dwt97Phase = enum { forward_columns, forward_rows, inverse_columns, inverse_rows };

const Dwt97BandJob = struct {
    planes: [3][]f32,
    stride: usize,
    cur_width: usize,
    cur_height: usize,
    x0: u32,
    y0: u32,
    line: []f32,
    scratch: []f32,
    pack_scratch: []f32,
    begin: usize,
    end: usize,
    phase: Dwt97Phase,

    fn run(job: *const Dwt97BandJob) void {
        switch (job.phase) {
            .forward_columns => for (job.planes) |plane| {
                var col = job.begin;
                if (job.cur_height >= 2) {
                    while (col + f32_block_lanes <= job.end) : (col += f32_block_lanes) {
                        forward97VerticalBand(plane, job.stride, col, job.cur_height, (job.y0 & 1) == 1, job.pack_scratch);
                    }
                }
                if (job.end == job.cur_width) {
                    while (col < job.cur_width) : (col += 1) {
                        for (0..job.cur_height) |row| job.line[row] = plane[row * job.stride + col];
                        forward1DOrigin(job.line[0..job.cur_height], job.scratch[0..job.cur_height], .irreversible_9_7, job.y0);
                        for (0..job.cur_height) |row| plane[row * job.stride + col] = job.line[row];
                    }
                }
            },
            .inverse_columns => for (job.planes) |plane| {
                var col = job.begin;
                if (job.cur_height >= 2) {
                    while (col + f32_block_lanes <= job.end) : (col += f32_block_lanes) {
                        inverse97VerticalBand(plane, job.stride, col, job.cur_height, (job.y0 & 1) == 1, job.pack_scratch);
                    }
                }
                if (job.end == job.cur_width) {
                    while (col < job.cur_width) : (col += 1) {
                        for (0..job.cur_height) |row| job.line[row] = plane[row * job.stride + col];
                        inverse1DOrigin(job.line[0..job.cur_height], job.scratch[0..job.cur_height], .irreversible_9_7, job.y0);
                        for (0..job.cur_height) |row| plane[row * job.stride + col] = job.line[row];
                    }
                }
            },
            .forward_rows => for (job.planes) |plane| {
                var row = job.begin;
                while (row < job.end) : (row += 1) {
                    forward1DOrigin(plane[row * job.stride ..][0..job.cur_width], job.scratch[0..job.cur_width], .irreversible_9_7, job.x0);
                }
            },
            .inverse_rows => for (job.planes) |plane| {
                var row = job.begin;
                while (row < job.end) : (row += 1) {
                    inverse1DOrigin(plane[row * job.stride ..][0..job.cur_width], job.scratch[0..job.cur_width], .irreversible_9_7, job.x0);
                }
            },
        }
    }
};

const Dwt97PoolWorker = struct {
    pool: *Dwt97Pool,
    index: usize,
};

const Dwt97Pool = struct {
    jobs: [max_dwt_workers]Dwt97BandJob = undefined,
    worker_args: [max_dwt_workers - 1]Dwt97PoolWorker = undefined,
    threads: [max_dwt_workers - 1]std.Thread = undefined,
    worker_count: usize = 1,
    spawned: usize = 0,
    active_jobs: usize = 0,
    generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    completed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn start(pool: *Dwt97Pool, requested_workers: usize) void {
        pool.worker_count = @max(1, @min(requested_workers, max_dwt_workers));
        if (pool.worker_count == 1) return;

        while (pool.spawned < pool.worker_count - 1) : (pool.spawned += 1) {
            pool.worker_args[pool.spawned] = .{ .pool = pool, .index = pool.spawned };
            pool.threads[pool.spawned] = std.Thread.spawn(.{}, dwt97PoolWorker, .{&pool.worker_args[pool.spawned]}) catch {
                // A partial pool cannot safely change its barrier width. Stop
                // the threads already created and use the caller thread.
                pool.stopping.store(true, .release);
                _ = pool.generation.fetchAdd(1, .release);
                for (pool.threads[0..pool.spawned]) |thread| thread.join();
                pool.worker_count = 1;
                pool.spawned = 0;
                return;
            };
        }
    }

    fn dispatch(pool: *Dwt97Pool, active_jobs: usize) void {
        if (pool.worker_count == 1) {
            pool.jobs[0].run();
            return;
        }

        pool.active_jobs = active_jobs;
        pool.completed.store(0, .monotonic);
        _ = pool.generation.fetchAdd(1, .release);

        const caller_index = pool.worker_count - 1;
        if (caller_index < active_jobs) pool.jobs[caller_index].run();
        while (pool.completed.load(.acquire) != pool.spawned) std.atomic.spinLoopHint();
    }

    fn stop(pool: *Dwt97Pool) void {
        if (pool.spawned == 0) return;
        pool.stopping.store(true, .release);
        _ = pool.generation.fetchAdd(1, .release);
        for (pool.threads[0..pool.spawned]) |thread| thread.join();
        pool.spawned = 0;
    }
};

fn dwt97PoolWorker(worker: *Dwt97PoolWorker) void {
    const pool = worker.pool;
    var observed_generation: u32 = 0;
    while (true) {
        var generation = pool.generation.load(.acquire);
        while (generation == observed_generation) {
            std.atomic.spinLoopHint();
            generation = pool.generation.load(.acquire);
        }
        observed_generation = generation;
        if (pool.stopping.load(.acquire)) return;
        if (worker.index < pool.active_jobs) pool.jobs[worker.index].run();
        _ = pool.completed.fetchAdd(1, .acq_rel);
    }
}

/// Runs one 9/7 DWT phase across `worker_count` bands. Column phases split
/// the column index at `f32_block_lanes` boundaries (the final band absorbs
/// the per-column line tail); row phases split the row index evenly. Bands
/// touch disjoint output regions, so no synchronization beyond the join is
/// needed. Each worker's scratch is sliced pack|line|1D from one allocation.
fn runDwt97Phase(
    pool: *Dwt97Pool,
    planes: [3][]f32,
    stride: usize,
    cur_width: usize,
    cur_height: usize,
    x0: u32,
    y0: u32,
    scratches: []const []f32,
    pack_len: usize,
    max_dim: usize,
    phase: Dwt97Phase,
) void {
    const is_columns = phase == .forward_columns or phase == .inverse_columns;
    const span = if (is_columns) cur_width else cur_height;
    if (span == 0) return;

    const jobs = &pool.jobs;
    const worker_count = pool.worker_count;
    var job_count: usize = 0;

    const makeJob = struct {
        fn make(
            planes_: [3][]f32,
            stride_: usize,
            cur_width_: usize,
            cur_height_: usize,
            x0_: u32,
            y0_: u32,
            scratch_all: []f32,
            pack_len_: usize,
            max_dim_: usize,
            begin: usize,
            end: usize,
            phase_: Dwt97Phase,
        ) Dwt97BandJob {
            return .{
                .planes = planes_,
                .stride = stride_,
                .cur_width = cur_width_,
                .cur_height = cur_height_,
                .x0 = x0_,
                .y0 = y0_,
                .pack_scratch = scratch_all[0..pack_len_],
                .line = scratch_all[pack_len_..][0..max_dim_],
                .scratch = scratch_all[pack_len_ + max_dim_ ..][0..max_dim_],
                .begin = begin,
                .end = end,
                .phase = phase_,
            };
        }
    }.make;

    if (is_columns) {
        // Distribute full vector groups; the last populated band runs to
        // `cur_width` so it emits the per-column line tail.
        const vec_groups = cur_width / f32_block_lanes;
        if (vec_groups == 0) {
            jobs[0] = makeJob(planes, stride, cur_width, cur_height, x0, y0, scratches[0], pack_len, max_dim, 0, cur_width, phase);
            job_count = 1;
        } else {
            const bands = @min(worker_count, vec_groups);
            const base = vec_groups / bands;
            const extra = vec_groups % bands;
            var group_start: usize = 0;
            var b: usize = 0;
            while (b < bands) : (b += 1) {
                const groups = base + (if (b < extra) @as(usize, 1) else 0);
                const col_begin = group_start * f32_block_lanes;
                const is_last = b == bands - 1;
                const col_end = if (is_last) cur_width else (group_start + groups) * f32_block_lanes;
                jobs[b] = makeJob(planes, stride, cur_width, cur_height, x0, y0, scratches[b], pack_len, max_dim, col_begin, col_end, phase);
                group_start += groups;
                job_count += 1;
            }
        }
    } else {
        const bands = @min(worker_count, cur_height);
        const base = cur_height / bands;
        const extra = cur_height % bands;
        var row_start: usize = 0;
        var b: usize = 0;
        while (b < bands) : (b += 1) {
            const rows = base + (if (b < extra) @as(usize, 1) else 0);
            jobs[b] = makeJob(planes, stride, cur_width, cur_height, x0, y0, scratches[b], pack_len, max_dim, row_start, row_start + rows, phase);
            row_start += rows;
            job_count += 1;
        }
    }

    pool.dispatch(job_count);
}

fn dwt97WorkerCount(thread_count: usize) usize {
    return @max(1, @min(thread_count, max_dwt_workers));
}

fn allocDwt97Scratches(allocator: std.mem.Allocator, workers: usize, scratch_len: usize) ![][]f32 {
    const scratches = try allocator.alloc([]f32, workers);
    errdefer allocator.free(scratches);
    var allocated: usize = 0;
    errdefer for (scratches[0..allocated]) |s| allocator.free(s);
    while (allocated < workers) : (allocated += 1) scratches[allocated] = try allocator.alloc(f32, scratch_len);
    return scratches;
}

fn freeDwt97Scratches(allocator: std.mem.Allocator, scratches: [][]f32) void {
    for (scratches) |s| allocator.free(s);
    allocator.free(scratches);
}

pub fn forward97Parallel(
    allocator: std.mem.Allocator,
    planes: [3][]f32,
    width: usize,
    height: usize,
    requested_levels: u8,
    x0: u32,
    y0: u32,
    thread_count: usize,
) !u8 {
    for (planes) |plane| {
        if (width == 0 or height == 0 or plane.len != width * height) return TransformError.InvalidDimensions;
    }
    const workers = dwt97WorkerCount(thread_count);
    const max_dim = @max(width, height);
    const pack_len = ((height + 1) / 2) * f32_block_lanes;
    const scratch_len = pack_len + 2 * max_dim;
    const scratches = try allocDwt97Scratches(allocator, workers, scratch_len);
    defer freeDwt97Scratches(allocator, scratches);
    var pool: Dwt97Pool = .{};
    pool.start(workers);
    defer pool.stop();

    var cur_width = width;
    var cur_height = height;
    var cur_x0 = x0;
    var cur_y0 = y0;
    var done: u8 = 0;
    while (done < requested_levels and (cur_width > 1 or cur_height > 1)) : (done += 1) {
        const next_width = lowCountOrigin(cur_width, cur_x0);
        const next_height = lowCountOrigin(cur_height, cur_y0);
        if (next_width == 0 or next_height == 0) break;
        // ISO/IEC 15444-1 F.4.8 forward order: vertical first, then horizontal.
        runDwt97Phase(&pool, planes, width, cur_width, cur_height, cur_x0, cur_y0, scratches, pack_len, max_dim, .forward_columns);
        runDwt97Phase(&pool, planes, width, cur_width, cur_height, cur_x0, cur_y0, scratches, pack_len, max_dim, .forward_rows);
        cur_width = next_width;
        cur_height = next_height;
        cur_x0 = ceilDiv2(cur_x0);
        cur_y0 = ceilDiv2(cur_y0);
    }
    return done;
}

pub fn inverse97Parallel(
    allocator: std.mem.Allocator,
    planes: [3][]f32,
    width: usize,
    height: usize,
    levels: u8,
    x0: u32,
    y0: u32,
    thread_count: usize,
) !void {
    for (planes) |plane| {
        if (width == 0 or height == 0 or plane.len != width * height) return TransformError.InvalidDimensions;
    }
    var shapes: [32]LevelShape = undefined;
    if (levels > shapes.len) return TransformError.TooManyLevels;
    const workers = dwt97WorkerCount(thread_count);
    const max_dim = @max(width, height);
    const pack_len = ((height + 1) / 2) * f32_block_lanes;
    const scratch_len = pack_len + 2 * max_dim;
    const scratches = try allocDwt97Scratches(allocator, workers, scratch_len);
    defer freeDwt97Scratches(allocator, scratches);
    var pool: Dwt97Pool = .{};
    pool.start(workers);
    defer pool.stop();

    var cur_width = width;
    var cur_height = height;
    var cur_x0 = x0;
    var cur_y0 = y0;
    var actual_levels: u8 = 0;
    while (actual_levels < levels and (cur_width > 1 or cur_height > 1)) : (actual_levels += 1) {
        const next_width = lowCountOrigin(cur_width, cur_x0);
        const next_height = lowCountOrigin(cur_height, cur_y0);
        if (next_width == 0 or next_height == 0) break;
        shapes[actual_levels] = .{ .width = cur_width, .height = cur_height, .x0 = cur_x0, .y0 = cur_y0 };
        cur_width = next_width;
        cur_height = next_height;
        cur_x0 = ceilDiv2(cur_x0);
        cur_y0 = ceilDiv2(cur_y0);
    }

    var level = actual_levels;
    while (level > 0) {
        level -= 1;
        const shape = shapes[level];
        // Mirror of the ISO forward order: horizontal first, then vertical.
        runDwt97Phase(&pool, planes, width, shape.width, shape.height, shape.x0, shape.y0, scratches, pack_len, max_dim, .inverse_rows);
        runDwt97Phase(&pool, planes, width, shape.width, shape.height, shape.x0, shape.y0, scratches, pack_len, max_dim, .inverse_columns);
    }
}
