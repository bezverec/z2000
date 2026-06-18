const std = @import("std");

pub const TransformError = error{
    InvalidDimensions,
    TooManyLevels,
};

const LevelShape = struct {
    width: usize,
    height: usize,
};

pub fn forward53(
    allocator: std.mem.Allocator,
    data: []i32,
    width: usize,
    height: usize,
    requested_levels: u8,
) !u8 {
    if (width == 0 or height == 0 or data.len != width * height) {
        return TransformError.InvalidDimensions;
    }

    const max_dim = @max(width, height);
    var line = try allocator.alloc(i32, max_dim);
    defer allocator.free(line);
    var scratch = try allocator.alloc(i32, max_dim);
    defer allocator.free(scratch);

    var cur_width = width;
    var cur_height = height;
    var done: u8 = 0;
    while (done < requested_levels and (cur_width > 1 or cur_height > 1)) : (done += 1) {
        for (0..cur_height) |row| {
            forward53Line(rowSlice(data, width, row, cur_width), scratch[0..cur_width]);
        }

        for (0..cur_width) |col| {
            for (0..cur_height) |row| line[row] = data[row * width + col];
            forward53Line(line[0..cur_height], scratch[0..cur_height]);
            for (0..cur_height) |row| data[row * width + col] = line[row];
        }

        cur_width = lowCount(cur_width);
        cur_height = lowCount(cur_height);
    }

    return done;
}

pub fn inverse53(
    allocator: std.mem.Allocator,
    data: []i32,
    width: usize,
    height: usize,
    levels: u8,
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
    var line = try allocator.alloc(i32, max_dim);
    defer allocator.free(line);
    var scratch = try allocator.alloc(i32, max_dim);
    defer allocator.free(scratch);

    var level = actual_levels;
    while (level > 0) {
        level -= 1;
        const shape = shapes[level];

        for (0..shape.width) |col| {
            for (0..shape.height) |row| line[row] = data[row * width + col];
            inverse53Line(line[0..shape.height], scratch[0..shape.height]);
            for (0..shape.height) |row| data[row * width + col] = line[row];
        }

        for (0..shape.height) |row| {
            inverse53Line(rowSlice(data, width, row, shape.width), scratch[0..shape.width]);
        }
    }
}

fn rowSlice(data: []i32, stride: usize, row: usize, len: usize) []i32 {
    const start = row * stride;
    return data[start .. start + len];
}

fn forward53Line(data: []i32, scratch: []i32) void {
    if (data.len < 2) return;

    var i: usize = 1;
    while (i < data.len) : (i += 2) {
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] -= @divFloor(data[i - 1] + right, 2);
    }

    i = 0;
    while (i < data.len) : (i += 2) {
        const left = if (i > 0) data[i - 1] else data[1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += @divFloor(left + right + 2, 4);
    }

    packEvenOdd(data, scratch);
}

fn inverse53Line(data: []i32, scratch: []i32) void {
    if (data.len < 2) return;
    unpackEvenOdd(data, scratch);

    var i: usize = 0;
    while (i < data.len) : (i += 2) {
        const left = if (i > 0) data[i - 1] else data[1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] -= @divFloor(left + right + 2, 4);
    }

    i = 1;
    while (i < data.len) : (i += 2) {
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += @divFloor(data[i - 1] + right, 2);
    }
}

fn packEvenOdd(data: []i32, scratch: []i32) void {
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

fn unpackEvenOdd(data: []i32, scratch: []i32) void {
    const lows = lowCount(data.len);
    var low: usize = 0;
    var high: usize = lows;
    for (0..data.len) |i| {
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

fn lowCount(n: usize) usize {
    return (n + 1) / 2;
}
