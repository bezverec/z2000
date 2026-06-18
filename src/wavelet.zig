const std = @import("std");

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
};

pub fn forward2D(
    allocator: std.mem.Allocator,
    data: []f32,
    width: usize,
    height: usize,
    requested_levels: u8,
    wavelet: Wavelet,
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
    var done: u8 = 0;

    while (done < requested_levels and (cur_width > 1 or cur_height > 1)) : (done += 1) {
        for (0..cur_height) |row| {
            for (0..cur_width) |col| line[col] = data[row * width + col];
            forward1D(line[0..cur_width], scratch[0..cur_width], wavelet);
            for (0..cur_width) |col| data[row * width + col] = line[col];
        }

        for (0..cur_width) |col| {
            for (0..cur_height) |row| line[row] = data[row * width + col];
            forward1D(line[0..cur_height], scratch[0..cur_height], wavelet);
            for (0..cur_height) |row| data[row * width + col] = line[row];
        }

        cur_width = lowCount(cur_width);
        cur_height = lowCount(cur_height);
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
    if (width == 0 or height == 0 or data.len != width * height) {
        return TransformError.InvalidDimensions;
    }

    var shapes: [32]LevelShape = undefined;
    if (levels > shapes.len) return TransformError.TooManyLevels;

    var cur_width = width;
    var cur_height = height;
    var actual_levels: u8 = 0;
    while (actual_levels < levels and (cur_width > 1 or cur_height > 1)) : (actual_levels += 1) {
        shapes[actual_levels] = .{ .width = cur_width, .height = cur_height };
        cur_width = lowCount(cur_width);
        cur_height = lowCount(cur_height);
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

        for (0..shape.width) |col| {
            for (0..shape.height) |row| line[row] = data[row * width + col];
            inverse1D(line[0..shape.height], scratch[0..shape.height], wavelet);
            for (0..shape.height) |row| data[row * width + col] = line[row];
        }

        for (0..shape.height) |row| {
            for (0..shape.width) |col| line[col] = data[row * width + col];
            inverse1D(line[0..shape.width], scratch[0..shape.width], wavelet);
            for (0..shape.width) |col| data[row * width + col] = line[col];
        }
    }
}

fn lowCount(n: usize) usize {
    return (n + 1) / 2;
}

fn forward1D(data: []f32, scratch: []f32, wavelet: Wavelet) void {
    if (data.len < 2) return;
    switch (wavelet) {
        .reversible_5_3 => forward53(data, scratch),
        .irreversible_9_7 => forward97(data, scratch),
    }
}

fn inverse1D(data: []f32, scratch: []f32, wavelet: Wavelet) void {
    if (data.len < 2) return;
    switch (wavelet) {
        .reversible_5_3 => inverse53(data, scratch),
        .irreversible_9_7 => inverse97(data, scratch),
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

fn forward97(data: []f32, scratch: []f32) void {
    liftOdd(data, -1.586134342059924);
    liftEven(data, -0.052980118572961);
    liftOdd(data, 0.882911075530934);
    liftEven(data, 0.443506852043971);

    const k = 1.1496043988602418;
    var i: usize = 0;
    while (i < data.len) : (i += 2) data[i] *= k;
    i = 1;
    while (i < data.len) : (i += 2) data[i] /= k;

    packEvenOdd(data, scratch);
}

fn inverse97(data: []f32, scratch: []f32) void {
    unpackEvenOdd(data, scratch);

    const k = 1.1496043988602418;
    var i: usize = 0;
    while (i < data.len) : (i += 2) data[i] /= k;
    i = 1;
    while (i < data.len) : (i += 2) data[i] *= k;

    liftEven(data, -0.443506852043971);
    liftOdd(data, -0.882911075530934);
    liftEven(data, 0.052980118572961);
    liftOdd(data, 1.586134342059924);
}

fn liftOdd(data: []f32, coefficient: f32) void {
    var i: usize = 1;
    while (i < data.len) : (i += 2) {
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += coefficient * (data[i - 1] + right);
    }
}

fn liftEven(data: []f32, coefficient: f32) void {
    var i: usize = 0;
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
