const std = @import("std");
const simd = @import("simd.zig");

pub const TransformError = error{
    InvalidDimensions,
    TooManyLevels,
};

const LevelShape = struct {
    width: usize,
    height: usize,
};

const vertical_lanes = simd.i32_lanes;
const VerticalVector = @Vector(vertical_lanes, i32);
const ShiftVector = @Vector(vertical_lanes, u5);

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    scratch: []i32,

    pub fn init(allocator: std.mem.Allocator, max_dim: usize) !Workspace {
        if (max_dim == 0) return TransformError.InvalidDimensions;
        const scratch_len = try std.math.mul(usize, max_dim, vertical_lanes);
        const scratch = try allocator.alloc(i32, scratch_len);
        errdefer allocator.free(scratch);
        return .{
            .allocator = allocator,
            .scratch = scratch,
        };
    }

    pub fn deinit(self: *Workspace) void {
        self.allocator.free(self.scratch);
        self.* = undefined;
    }

    fn require(self: Workspace, max_dim: usize) !void {
        const scratch_len = try std.math.mul(usize, max_dim, vertical_lanes);
        if (self.scratch.len < scratch_len) {
            return TransformError.InvalidDimensions;
        }
    }
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
    var workspace = try Workspace.init(allocator, max_dim);
    defer workspace.deinit();

    return forward53WithWorkspace(&workspace, data, width, height, requested_levels);
}

pub fn forward53WithWorkspace(
    workspace: *Workspace,
    data: []i32,
    width: usize,
    height: usize,
    requested_levels: u8,
) !u8 {
    if (width == 0 or height == 0 or data.len != width * height) {
        return TransformError.InvalidDimensions;
    }

    const max_dim = @max(width, height);
    try workspace.require(max_dim);
    const scratch = workspace.scratch;

    var cur_width = width;
    var cur_height = height;
    var done: u8 = 0;
    while (done < requested_levels and (cur_width > 1 or cur_height > 1)) : (done += 1) {
        // ISO/IEC 15444-1 F.4.8: the forward 2D transform filters vertically
        // first, then horizontally. The 5/3 lifting steps use floor
        // operations, so the direction order changes coefficients by +-1 and
        // must match independent codecs.
        forward53Columns(data, width, cur_width, cur_height, scratch);

        for (0..cur_height) |row| {
            forward53Line(rowSlice(data, width, row, cur_width), scratch[0..cur_width]);
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

    const max_dim = @max(width, height);
    var workspace = try Workspace.init(allocator, max_dim);
    defer workspace.deinit();

    try inverse53WithWorkspace(&workspace, data, width, height, levels);
}

pub fn inverse53WithWorkspace(
    workspace: *Workspace,
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
    try workspace.require(max_dim);
    const scratch = workspace.scratch;

    var level = actual_levels;
    while (level > 0) {
        level -= 1;
        const shape = shapes[level];

        // Mirror of the ISO forward order (vertical then horizontal): the
        // inverse runs horizontally first, then vertically (F.3.8 2D_SR).
        for (0..shape.height) |row| {
            inverse53Line(rowSlice(data, width, row, shape.width), scratch[0..shape.width]);
        }

        inverse53Columns(data, width, shape.width, shape.height, scratch);
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
        data[i] -= floorHalf(data[i - 1] + right);
    }

    i = 0;
    while (i < data.len) : (i += 2) {
        const left = if (i > 0) data[i - 1] else data[1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += floorQuarterBiased(left + right);
    }

    packEvenOdd(data, scratch);
}

fn forward53Columns(data: []i32, stride: usize, width: usize, height: usize, scratch: []i32) void {
    if (height < 2) return;

    var col: usize = 0;
    while (col + vertical_lanes <= width) : (col += vertical_lanes) {
        forward53ColumnVector(data, stride, col, height, scratch[0 .. height * vertical_lanes]);
    }
    while (col < width) : (col += 1) {
        forward53ColumnScalar(data, stride, col, height, scratch[0..height]);
    }
}

fn forward53ColumnVector(data: []i32, stride: usize, col: usize, height: usize, scratch: []i32) void {
    var row: usize = 1;
    while (row < height) : (row += 2) {
        const right = if (row + 1 < height)
            loadVector(data, stride, row + 1, col)
        else
            loadVector(data, stride, row - 1, col);
        const updated = loadVector(data, stride, row, col) -
            floorHalfVector(loadVector(data, stride, row - 1, col) + right);
        storeVector(data, stride, row, col, updated);
    }

    row = 0;
    while (row < height) : (row += 2) {
        const left = if (row > 0)
            loadVector(data, stride, row - 1, col)
        else
            loadVector(data, stride, 1, col);
        const right = if (row + 1 < height)
            loadVector(data, stride, row + 1, col)
        else
            loadVector(data, stride, row - 1, col);
        const updated = loadVector(data, stride, row, col) + floorQuarterBiasedVector(left + right);
        storeVector(data, stride, row, col, updated);
    }

    var out: usize = 0;
    row = 0;
    while (row < height) : (row += 2) {
        storeScratchVector(scratch, out, loadVector(data, stride, row, col));
        out += 1;
    }

    row = 1;
    while (row < height) : (row += 2) {
        storeScratchVector(scratch, out, loadVector(data, stride, row, col));
        out += 1;
    }

    row = 0;
    while (row < height) : (row += 1) {
        storeVector(data, stride, row, col, loadScratchVector(scratch, row));
    }
}

fn forward53ColumnScalar(data: []i32, stride: usize, col: usize, height: usize, scratch: []i32) void {
    var row: usize = 1;
    while (row < height) : (row += 2) {
        const right = if (row + 1 < height) data[(row + 1) * stride + col] else data[(row - 1) * stride + col];
        data[row * stride + col] -= floorHalf(data[(row - 1) * stride + col] + right);
    }

    row = 0;
    while (row < height) : (row += 2) {
        const left = if (row > 0) data[(row - 1) * stride + col] else data[stride + col];
        const right = if (row + 1 < height) data[(row + 1) * stride + col] else data[(row - 1) * stride + col];
        data[row * stride + col] += floorQuarterBiased(left + right);
    }

    var out: usize = 0;
    row = 0;
    while (row < height) : (row += 2) {
        scratch[out] = data[row * stride + col];
        out += 1;
    }

    row = 1;
    while (row < height) : (row += 2) {
        scratch[out] = data[row * stride + col];
        out += 1;
    }

    row = 0;
    while (row < height) : (row += 1) {
        data[row * stride + col] = scratch[row];
    }
}

fn inverse53Columns(data: []i32, stride: usize, width: usize, height: usize, scratch: []i32) void {
    if (height < 2) return;

    var col: usize = 0;
    while (col + vertical_lanes <= width) : (col += vertical_lanes) {
        inverse53ColumnVector(data, stride, col, height, scratch[0 .. height * vertical_lanes]);
    }
    while (col < width) : (col += 1) {
        inverse53ColumnScalar(data, stride, col, height, scratch[0..height]);
    }
}

fn inverse53ColumnVector(data: []i32, stride: usize, col: usize, height: usize, scratch: []i32) void {
    const lows = lowCount(height);
    var row: usize = 0;
    var packed_row: usize = 0;
    while (row < height) : (row += 2) {
        storeScratchVector(scratch, row, loadVector(data, stride, packed_row, col));
        packed_row += 1;
    }

    row = 1;
    packed_row = lows;
    while (row < height) : (row += 2) {
        storeScratchVector(scratch, row, loadVector(data, stride, packed_row, col));
        packed_row += 1;
    }

    row = 0;
    while (row < height) : (row += 2) {
        const left = if (row > 0)
            loadScratchVector(scratch, row - 1)
        else
            loadScratchVector(scratch, 1);
        const right = if (row + 1 < height)
            loadScratchVector(scratch, row + 1)
        else
            loadScratchVector(scratch, row - 1);
        const updated = loadScratchVector(scratch, row) - floorQuarterBiasedVector(left + right);
        storeScratchVector(scratch, row, updated);
    }

    row = 1;
    while (row < height) : (row += 2) {
        const right = if (row + 1 < height)
            loadScratchVector(scratch, row + 1)
        else
            loadScratchVector(scratch, row - 1);
        const updated = loadScratchVector(scratch, row) +
            floorHalfVector(loadScratchVector(scratch, row - 1) + right);
        storeScratchVector(scratch, row, updated);
    }

    row = 0;
    while (row < height) : (row += 1) {
        storeVector(data, stride, row, col, loadScratchVector(scratch, row));
    }
}

fn inverse53ColumnScalar(data: []i32, stride: usize, col: usize, height: usize, scratch: []i32) void {
    const lows = lowCount(height);
    var row: usize = 0;
    var packed_row: usize = 0;
    while (row < height) : (row += 2) {
        scratch[row] = data[packed_row * stride + col];
        packed_row += 1;
    }

    row = 1;
    packed_row = lows;
    while (row < height) : (row += 2) {
        scratch[row] = data[packed_row * stride + col];
        packed_row += 1;
    }

    row = 0;
    while (row < height) : (row += 2) {
        const left = if (row > 0) scratch[row - 1] else scratch[1];
        const right = if (row + 1 < height) scratch[row + 1] else scratch[row - 1];
        scratch[row] -= floorQuarterBiased(left + right);
    }

    row = 1;
    while (row < height) : (row += 2) {
        const right = if (row + 1 < height) scratch[row + 1] else scratch[row - 1];
        scratch[row] += floorHalf(scratch[row - 1] + right);
    }

    row = 0;
    while (row < height) : (row += 1) {
        data[row * stride + col] = scratch[row];
    }
}

fn inverse53Line(data: []i32, scratch: []i32) void {
    if (data.len < 2) return;
    unpackEvenOdd(data, scratch);

    var i: usize = 0;
    while (i < data.len) : (i += 2) {
        const left = if (i > 0) data[i - 1] else data[1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] -= floorQuarterBiased(left + right);
    }

    i = 1;
    while (i < data.len) : (i += 2) {
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += floorHalf(data[i - 1] + right);
    }
}

fn floorHalf(value: i32) i32 {
    return value >> 1;
}

fn floorQuarterBiased(value: i32) i32 {
    return (value + 2) >> 2;
}

fn floorHalfVector(value: VerticalVector) VerticalVector {
    return value >> @as(ShiftVector, @splat(1));
}

fn floorQuarterBiasedVector(value: VerticalVector) VerticalVector {
    return (value + @as(VerticalVector, @splat(2))) >> @as(ShiftVector, @splat(2));
}

fn loadVector(data: []const i32, stride: usize, row: usize, col: usize) VerticalVector {
    return data[row * stride + col ..][0..vertical_lanes].*;
}

fn storeVector(data: []i32, stride: usize, row: usize, col: usize, value: VerticalVector) void {
    data[row * stride + col ..][0..vertical_lanes].* = value;
}

fn loadScratchVector(scratch: []const i32, row: usize) VerticalVector {
    return scratch[row * vertical_lanes ..][0..vertical_lanes].*;
}

fn storeScratchVector(scratch: []i32, row: usize, value: VerticalVector) void {
    scratch[row * vertical_lanes ..][0..vertical_lanes].* = value;
}

fn packEvenOdd(data: []i32, scratch: []i32) void {
    if (data.len <= 2) return;

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
    if (data.len <= 2) return;

    const lows = lowCount(data.len);
    var i: usize = 0;
    var packed_index: usize = 0;
    while (i < data.len) : (i += 2) {
        scratch[i] = data[packed_index];
        packed_index += 1;
    }

    i = 1;
    packed_index = lows;
    while (i < data.len) : (i += 2) {
        scratch[i] = data[packed_index];
        packed_index += 1;
    }

    @memcpy(data, scratch[0..data.len]);
}

fn lowCount(n: usize) usize {
    return (n + 1) / 2;
}
