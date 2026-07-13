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

const LevelShape = struct {
    width: usize,
    height: usize,
    x0: u32 = 0,
    y0: u32 = 0,
};

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
    if (width == 0 or height == 0 or data.len != width * height) {
        return TransformError.InvalidDimensions;
    }

    var shapes: [32]LevelShape = undefined;
    if (levels > shapes.len) return TransformError.TooManyLevels;

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
    while (level > 0) {
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
