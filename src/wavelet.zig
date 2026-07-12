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
const F32PairVector = @Vector(simd.f32_pair_lanes, f32);

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
        for (0..cur_width) |col| {
            for (0..cur_height) |row| line[row] = data[row * width + col];
            forward1DOrigin(line[0..cur_height], scratch[0..cur_height], wavelet, cur_y0);
            for (0..cur_height) |row| data[row * width + col] = line[row];
        }

        for (0..cur_height) |row| {
            for (0..cur_width) |col| line[col] = data[row * width + col];
            forward1DOrigin(line[0..cur_width], scratch[0..cur_width], wavelet, cur_x0);
            for (0..cur_width) |col| data[row * width + col] = line[col];
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

    var level = actual_levels;
    while (level > 0) {
        level -= 1;
        const shape = shapes[level];

        // Mirror of the ISO forward order: horizontal first, then vertical.
        for (0..shape.height) |row| {
            for (0..shape.width) |col| line[col] = data[row * width + col];
            inverse1DOrigin(line[0..shape.width], scratch[0..shape.width], wavelet, shape.x0);
            for (0..shape.width) |col| data[row * width + col] = line[col];
        }

        for (0..shape.width) |col| {
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

fn forward97(data: []f32, scratch: []f32) void {
    liftOdd(data, dwt97_alpha);
    liftEven(data, dwt97_beta);
    liftOdd(data, dwt97_gamma);
    liftEven(data, dwt97_delta);

    scaleEvenOdd(data, dwt97_inv_k, dwt97_k);

    packEvenOdd(data, scratch);
}

fn inverse97(data: []f32, scratch: []f32) void {
    unpackEvenOdd(data, scratch);

    scaleEvenOdd(data, dwt97_k, dwt97_inv_k);

    liftEven(data, -dwt97_delta);
    liftOdd(data, -dwt97_gamma);
    liftEven(data, -dwt97_beta);
    liftOdd(data, -dwt97_alpha);
}

fn forward97OddOrigin(data: []f32, scratch: []f32) void {
    liftEven(data, dwt97_alpha);
    liftOdd(data, dwt97_beta);
    liftEven(data, dwt97_gamma);
    liftOdd(data, dwt97_delta);
    scaleEvenOdd(data, dwt97_k, dwt97_inv_k);
    packOddEven(data, scratch);
}

fn inverse97OddOrigin(data: []f32, scratch: []f32) void {
    unpackOddEven(data, scratch);
    scaleEvenOdd(data, dwt97_inv_k, dwt97_k);
    liftOdd(data, -dwt97_delta);
    liftEven(data, -dwt97_gamma);
    liftOdd(data, -dwt97_beta);
    liftEven(data, -dwt97_alpha);
}

fn scaleEvenOdd(data: []f32, even_scale: f32, odd_scale: f32) void {
    // Adjacent even/odd samples map cleanly to 3DNow-style f32x2 scaling.
    const scales: F32PairVector = .{ even_scale, odd_scale };
    var i: usize = 0;
    while (i + simd.f32_pair_lanes <= data.len) : (i += simd.f32_pair_lanes) {
        const pair: F32PairVector = data[i..][0..simd.f32_pair_lanes].*;
        data[i..][0..simd.f32_pair_lanes].* = @as([simd.f32_pair_lanes]f32, pair * scales);
    }
    if (i < data.len) {
        data[i] *= even_scale;
    }
}

fn liftOdd(data: []f32, coefficient: f32) void {
    const coeff: F32PairVector = @splat(coefficient);
    var i: usize = 1;
    while (i + 2 < data.len) : (i += 4) {
        const target: F32PairVector = .{ data[i], data[i + 2] };
        const left: F32PairVector = .{ data[i - 1], data[i + 1] };
        const right: F32PairVector = .{
            data[i + 1],
            data[if (i + 3 < data.len) i + 3 else i + 1],
        };
        const updated = target + coeff * (left + right);
        data[i] = updated[0];
        data[i + 2] = updated[1];
    }
    while (i < data.len) : (i += 2) {
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += coefficient * (data[i - 1] + right);
    }
}

fn liftEven(data: []f32, coefficient: f32) void {
    const coeff: F32PairVector = @splat(coefficient);
    var i: usize = 0;
    while (i + 2 < data.len) : (i += 4) {
        const target: F32PairVector = .{ data[i], data[i + 2] };
        const left: F32PairVector = .{
            if (i > 0) data[i - 1] else data[1],
            data[i + 1],
        };
        const right: F32PairVector = .{
            data[i + 1],
            data[if (i + 3 < data.len) i + 3 else i + 1],
        };
        const updated = target + coeff * (left + right);
        data[i] = updated[0];
        data[i + 2] = updated[1];
    }
    while (i < data.len) : (i += 2) {
        const left = if (i > 0) data[i - 1] else data[1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += coefficient * (left + right);
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
