const std = @import("std");
const simd = @import("simd.zig");

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

const vertical_lanes = simd.i32_lanes;
const VerticalVector = @Vector(vertical_lanes, i32);
const ShiftVector = @Vector(vertical_lanes, u5);
const horizontal_lanes = simd.i32_lanes;
const horizontal_pair_lanes = horizontal_lanes * 2;
const HorizontalVector = @Vector(horizontal_lanes, i32);
const HorizontalPairVector = @Vector(horizontal_pair_lanes, i32);
const HorizontalShiftVector = @Vector(horizontal_lanes, u5);
const horizontal_even_mask = makeHorizontalEvenMask();
const horizontal_interleave_mask = makeHorizontalInterleaveMask();
const workspace_lanes = @max(vertical_lanes, 2);

pub const Workspace = struct {
    allocator: std.mem.Allocator,
    scratch: []i32,

    pub fn init(allocator: std.mem.Allocator, max_dim: usize) !Workspace {
        if (max_dim == 0) return TransformError.InvalidDimensions;
        const scratch_len = try std.math.mul(usize, max_dim, workspace_lanes);
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
        const scratch_len = try std.math.mul(usize, max_dim, workspace_lanes);
        if (self.scratch.len < scratch_len) {
            return TransformError.InvalidDimensions;
        }
    }
};

pub fn canDecompose53Region(x0: u32, y0: u32, x1: u32, y1: u32, levels: u8) bool {
    if (x1 <= x0 or y1 <= y0 or levels > 32) return false;
    var cur_x0 = x0;
    var cur_y0 = y0;
    var cur_x1 = x1;
    var cur_y1 = y1;
    var level: u8 = 0;
    while (level < levels) : (level += 1) {
        if (cur_x1 - cur_x0 <= 1 and cur_y1 - cur_y0 <= 1) return false;
        cur_x0 = ceilDiv2(cur_x0);
        cur_y0 = ceilDiv2(cur_y0);
        cur_x1 = ceilDiv2(cur_x1);
        cur_y1 = ceilDiv2(cur_y1);
        if (cur_x1 <= cur_x0 or cur_y1 <= cur_y0) return false;
    }
    return true;
}

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
    return forward53WithWorkspaceOrigin(workspace, data, width, height, requested_levels, 0, 0);
}

pub fn forward53WithWorkspaceOrigin(
    workspace: *Workspace,
    data: []i32,
    width: usize,
    height: usize,
    requested_levels: u8,
    x0: u32,
    y0: u32,
) !u8 {
    if (width == 0 or height == 0 or data.len != width * height) {
        return TransformError.InvalidDimensions;
    }

    const max_dim = @max(width, height);
    try workspace.require(max_dim);
    const scratch = workspace.scratch;

    var cur_width = width;
    var cur_height = height;
    var cur_x0 = x0;
    var cur_y0 = y0;
    var done: u8 = 0;
    while (done < requested_levels and (cur_width > 1 or cur_height > 1)) : (done += 1) {
        const next_width = lowCountOrigin(cur_width, cur_x0);
        const next_height = lowCountOrigin(cur_height, cur_y0);
        if (next_width == 0 or next_height == 0) break;
        // ISO/IEC 15444-1 F.4.8: the forward 2D transform filters vertically
        // first, then horizontally. The 5/3 lifting steps use floor
        // operations, so the direction order changes coefficients by +-1 and
        // must match independent codecs.
        forward53ColumnsOrigin(data, width, cur_width, cur_height, scratch, cur_y0);

        for (0..cur_height) |row| {
            forward53LineOrigin(rowSlice(data, width, row, cur_width), scratch[0..cur_width], cur_x0);
        }

        cur_width = next_width;
        cur_height = next_height;
        cur_x0 = ceilDiv2(cur_x0);
        cur_y0 = ceilDiv2(cur_y0);
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
    return inverse53WithWorkspaceOrigin(workspace, data, width, height, levels, 0, 0);
}

pub fn inverse53WithWorkspaceOrigin(
    workspace: *Workspace,
    data: []i32,
    width: usize,
    height: usize,
    levels: u8,
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
        shapes[actual_levels] = .{ .width = cur_width, .height = cur_height, .x0 = cur_x0, .y0 = cur_y0 };
        cur_width = lowCountOrigin(cur_width, cur_x0);
        cur_height = lowCountOrigin(cur_height, cur_y0);
        if (cur_width == 0 or cur_height == 0) return TransformError.InvalidDimensions;
        cur_x0 = ceilDiv2(cur_x0);
        cur_y0 = ceilDiv2(cur_y0);
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
            inverse53LineOrigin(rowSlice(data, width, row, shape.width), scratch[0..shape.width], shape.x0);
        }

        inverse53ColumnsOrigin(data, width, shape.width, shape.height, scratch, shape.y0);
    }
}

fn rowSlice(data: []i32, stride: usize, row: usize, len: usize) []i32 {
    const start = row * stride;
    return data[start .. start + len];
}

/// Forward 5/3 column pass restricted to columns [`col_begin`, `col_end`).
/// `col_begin` must be a multiple of `vertical_lanes`; the scalar tail is
/// only emitted by the band whose `col_end == width`. Each column transform
/// is independent, so banding is byte-identical to `forward53Columns`.
fn forward53ColumnBand(data: []i32, stride: usize, col_begin: usize, col_end: usize, width: usize, height: usize, scratch: []i32) void {
    if (height < 2) return;
    var col = col_begin;
    while (col + vertical_lanes <= col_end) : (col += vertical_lanes) {
        forward53ColumnVector(data, stride, col, height, scratch[0 .. height * vertical_lanes]);
    }
    if (col_end == width) {
        while (col < width) : (col += 1) {
            forward53ColumnScalar(data, stride, col, height, scratch[0..height]);
        }
    }
}

fn inverse53ColumnBand(data: []i32, stride: usize, col_begin: usize, col_end: usize, width: usize, height: usize, scratch: []i32) void {
    if (height < 2) return;
    var col = col_begin;
    while (col + vertical_lanes <= col_end) : (col += vertical_lanes) {
        inverse53ColumnVector(data, stride, col, height, scratch[0 .. height * vertical_lanes]);
    }
    if (col_end == width) {
        while (col < width) : (col += 1) {
            inverse53ColumnScalar(data, stride, col, height, scratch[0..height]);
        }
    }
}

// ---------------------------------------------------------------------------
// Parallel multi-component 5/3 DWT.
//
// The per-level cascade is inherently sequential (level n+1 filters level n's
// LL), but within a level the column transforms are mutually independent and
// so are the row transforms. The serial path caps parallelism at three
// component threads; on machines with more cores the DWT phase (up to 30% of
// a threaded encode) then starves. This driver keeps the exact serial
// operation order per column/row but distributes the three components' column
// bands and row bands across `thread_count` workers, each with private
// scratch. Output is byte-identical to running `forward53WithWorkspace` /
// `inverse53WithWorkspace` on each component (covered by a unit test).
// ---------------------------------------------------------------------------

const max_dwt_workers = 32;

const DwtPhase = enum { forward_columns, forward_rows, inverse_columns, inverse_rows };

const DwtBandJob = struct {
    planes: [3][]i32,
    stride: usize,
    cur_width: usize,
    cur_height: usize,
    scratch: []i32,
    begin: usize,
    end: usize,
    phase: DwtPhase,

    fn run(job: *const DwtBandJob) void {
        switch (job.phase) {
            .forward_columns => for (job.planes) |plane| {
                forward53ColumnBand(plane, job.stride, job.begin, job.end, job.cur_width, job.cur_height, job.scratch);
            },
            .inverse_columns => for (job.planes) |plane| {
                inverse53ColumnBand(plane, job.stride, job.begin, job.end, job.cur_width, job.cur_height, job.scratch);
            },
            .forward_rows => for (job.planes) |plane| {
                var row = job.begin;
                while (row < job.end) : (row += 1) {
                    forward53Line(rowSlice(plane, job.stride, row, job.cur_width), job.scratch[0..job.cur_width]);
                }
            },
            .inverse_rows => for (job.planes) |plane| {
                var row = job.begin;
                while (row < job.end) : (row += 1) {
                    inverse53Line(rowSlice(plane, job.stride, row, job.cur_width), job.scratch[0..job.cur_width]);
                }
            },
        }
    }
};

fn dwtBandWorker(job: *DwtBandJob) void {
    job.run();
}

/// Runs one DWT phase across `worker_count` bands. Column phases split the
/// column index at `vertical_lanes` boundaries (the final band absorbs the
/// scalar tail); row phases split the row index evenly. Bands touch disjoint
/// output regions, so no synchronization beyond the join is needed.
fn runDwtPhase(
    planes: [3][]i32,
    stride: usize,
    cur_width: usize,
    cur_height: usize,
    scratches: []const []i32,
    worker_count: usize,
    phase: DwtPhase,
) void {
    const is_columns = phase == .forward_columns or phase == .inverse_columns;
    // Split the driving dimension into `worker_count` bands.
    const span = if (is_columns) cur_width else cur_height;
    if (span == 0) return;

    var jobs: [max_dwt_workers]DwtBandJob = undefined;
    var threads: [max_dwt_workers]std.Thread = undefined;
    var job_count: usize = 0;

    if (is_columns) {
        // Distribute full vector groups; the last populated band runs to
        // `cur_width` so it emits the scalar tail.
        const vec_groups = cur_width / vertical_lanes;
        if (vec_groups == 0) {
            // Only a scalar tail exists — one worker handles it.
            jobs[0] = .{ .planes = planes, .stride = stride, .cur_width = cur_width, .cur_height = cur_height, .scratch = scratches[0], .begin = 0, .end = cur_width, .phase = phase };
            job_count = 1;
        } else {
            const bands = @min(worker_count, vec_groups);
            const base = vec_groups / bands;
            const extra = vec_groups % bands;
            var group_start: usize = 0;
            var b: usize = 0;
            while (b < bands) : (b += 1) {
                const groups = base + (if (b < extra) @as(usize, 1) else 0);
                const col_begin = group_start * vertical_lanes;
                const is_last = b == bands - 1;
                const col_end = if (is_last) cur_width else (group_start + groups) * vertical_lanes;
                jobs[b] = .{ .planes = planes, .stride = stride, .cur_width = cur_width, .cur_height = cur_height, .scratch = scratches[b], .begin = col_begin, .end = col_end, .phase = phase };
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
            jobs[b] = .{ .planes = planes, .stride = stride, .cur_width = cur_width, .cur_height = cur_height, .scratch = scratches[b], .begin = row_start, .end = row_start + rows, .phase = phase };
            row_start += rows;
            job_count += 1;
        }
    }

    if (job_count <= 1) {
        jobs[0].run();
        return;
    }

    var spawned: usize = 0;
    while (spawned < job_count - 1) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, dwtBandWorker, .{&jobs[spawned]}) catch {
            // Fall back to running the rest inline on spawn failure.
            break;
        };
    }
    var remaining = spawned;
    while (remaining < job_count) : (remaining += 1) jobs[remaining].run();
    for (threads[0..spawned]) |thread| thread.join();
}

fn dwtWorkerCount(thread_count: usize) usize {
    return @max(1, @min(thread_count, max_dwt_workers));
}

pub fn forward53Parallel(
    allocator: std.mem.Allocator,
    planes: [3][]i32,
    width: usize,
    height: usize,
    requested_levels: u8,
    thread_count: usize,
) !u8 {
    for (planes) |plane| {
        if (width == 0 or height == 0 or plane.len != width * height) return TransformError.InvalidDimensions;
    }
    const workers = dwtWorkerCount(thread_count);
    const max_dim = @max(width, height);
    const scratch_len = try std.math.mul(usize, max_dim, vertical_lanes);

    const scratches = try allocator.alloc([]i32, workers);
    defer allocator.free(scratches);
    var allocated: usize = 0;
    defer for (scratches[0..allocated]) |s| allocator.free(s);
    while (allocated < workers) : (allocated += 1) scratches[allocated] = try allocator.alloc(i32, scratch_len);

    var cur_width = width;
    var cur_height = height;
    var done: u8 = 0;
    while (done < requested_levels and (cur_width > 1 or cur_height > 1)) : (done += 1) {
        runDwtPhase(planes, width, cur_width, cur_height, scratches, workers, .forward_columns);
        runDwtPhase(planes, width, cur_width, cur_height, scratches, workers, .forward_rows);
        cur_width = lowCount(cur_width);
        cur_height = lowCount(cur_height);
    }
    return done;
}

pub fn inverse53Parallel(
    allocator: std.mem.Allocator,
    planes: [3][]i32,
    width: usize,
    height: usize,
    levels: u8,
    thread_count: usize,
) !void {
    for (planes) |plane| {
        if (width == 0 or height == 0 or plane.len != width * height) return TransformError.InvalidDimensions;
    }
    if (levels > 32) return TransformError.TooManyLevels;
    const workers = dwtWorkerCount(thread_count);
    const max_dim = @max(width, height);
    const scratch_len = try std.math.mul(usize, max_dim, vertical_lanes);

    const scratches = try allocator.alloc([]i32, workers);
    defer allocator.free(scratches);
    var allocated: usize = 0;
    defer for (scratches[0..allocated]) |s| allocator.free(s);
    while (allocated < workers) : (allocated += 1) scratches[allocated] = try allocator.alloc(i32, scratch_len);

    var shapes: [32]LevelShape = undefined;
    var cur_width = width;
    var cur_height = height;
    var actual_levels: u8 = 0;
    while (actual_levels < levels and (cur_width > 1 or cur_height > 1)) : (actual_levels += 1) {
        shapes[actual_levels] = .{ .width = cur_width, .height = cur_height };
        cur_width = lowCount(cur_width);
        cur_height = lowCount(cur_height);
    }

    var level = actual_levels;
    while (level > 0) {
        level -= 1;
        const shape = shapes[level];
        runDwtPhase(planes, width, shape.width, shape.height, scratches, workers, .inverse_rows);
        runDwtPhase(planes, width, shape.width, shape.height, scratches, workers, .inverse_columns);
    }
}

fn forward53Line(data: []i32, scratch: []i32) void {
    if (data.len < 2) return;

    var i: usize = 1;
    while (i + 1 + horizontal_pair_lanes <= data.len) : (i += horizontal_pair_lanes) {
        forward53PredictHorizontalGroup(data, i);
    }
    while (i < data.len) : (i += 2) {
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] -= floorHalf(data[i - 1] + right);
    }

    data[0] += floorQuarterBiased(data[1] + data[1]);
    i = 2;
    while (i + 1 + horizontal_pair_lanes <= data.len) : (i += horizontal_pair_lanes) {
        forward53UpdateHorizontalGroup(data, i);
    }
    while (i < data.len) : (i += 2) {
        const left = data[i - 1];
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

fn forward53ColumnsOrigin(data: []i32, stride: usize, width: usize, height: usize, scratch: []i32, y0: u32) void {
    if ((y0 & 1) == 0) return forward53Columns(data, stride, width, height, scratch);
    const line = scratch[0..height];
    const temp = scratch[height .. height * 2];
    for (0..width) |col| {
        for (0..height) |row| line[row] = data[row * stride + col];
        forward53LineOrigin(line, temp, y0);
        for (0..height) |row| data[row * stride + col] = line[row];
    }
}

fn inverse53ColumnsOrigin(data: []i32, stride: usize, width: usize, height: usize, scratch: []i32, y0: u32) void {
    if ((y0 & 1) == 0) return inverse53Columns(data, stride, width, height, scratch);
    const line = scratch[0..height];
    const temp = scratch[height .. height * 2];
    for (0..width) |col| {
        for (0..height) |row| line[row] = data[row * stride + col];
        inverse53LineOrigin(line, temp, y0);
        for (0..height) |row| data[row * stride + col] = line[row];
    }
}

fn forward53LineOrigin(data: []i32, scratch: []i32, origin: u32) void {
    if ((origin & 1) == 0) return forward53Line(data, scratch);
    if (data.len == 1) {
        data[0] *= 2;
        return;
    }

    // Odd reference origin: local even indexes are high-pass samples and
    // local odd indexes are low-pass samples.
    var i: usize = 0;
    while (i < data.len) : (i += 2) {
        const left = if (i > 0) data[i - 1] else data[i + 1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] -= floorHalf(left + right);
    }
    i = 1;
    while (i < data.len) : (i += 2) {
        const left = data[i - 1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += floorQuarterBiased(left + right);
    }
    packOddEven(data, scratch);
}

fn inverse53LineOrigin(data: []i32, scratch: []i32, origin: u32) void {
    if ((origin & 1) == 0) return inverse53Line(data, scratch);
    if (data.len == 1) {
        data[0] = @divExact(data[0], 2);
        return;
    }

    unpackOddEven(data, scratch);
    var i: usize = 1;
    while (i < data.len) : (i += 2) {
        const left = data[i - 1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] -= floorQuarterBiased(left + right);
    }
    i = 0;
    while (i < data.len) : (i += 2) {
        const left = if (i > 0) data[i - 1] else data[i + 1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] += floorHalf(left + right);
    }
}

fn inverse53Line(data: []i32, scratch: []i32) void {
    if (data.len < 2) return;
    unpackEvenOdd(data, scratch);

    data[0] -= floorQuarterBiased(data[1] + data[1]);
    var i: usize = 2;
    while (i + 1 + horizontal_pair_lanes <= data.len) : (i += horizontal_pair_lanes) {
        inverse53UpdateHorizontalGroup(data, i);
    }
    while (i < data.len) : (i += 2) {
        const left = data[i - 1];
        const right = if (i + 1 < data.len) data[i + 1] else data[i - 1];
        data[i] -= floorQuarterBiased(left + right);
    }

    i = 1;
    while (i + 1 + horizontal_pair_lanes <= data.len) : (i += horizontal_pair_lanes) {
        inverse53PredictHorizontalGroup(data, i);
    }
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

fn floorHalfHorizontal(value: HorizontalVector) HorizontalVector {
    return value >> @as(HorizontalShiftVector, @splat(1));
}

fn floorQuarterBiasedHorizontal(value: HorizontalVector) HorizontalVector {
    return (value + @as(HorizontalVector, @splat(2))) >> @as(HorizontalShiftVector, @splat(2));
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
    while (i + horizontal_pair_lanes <= data.len) : (i += horizontal_pair_lanes) {
        storeHorizontal(scratch, out, evenHorizontalSamples(loadHorizontalPair(data, i)));
        out += horizontal_lanes;
    }
    while (i < data.len) : (i += 2) {
        scratch[out] = data[i];
        out += 1;
    }

    i = 1;
    while (i + horizontal_pair_lanes <= data.len) : (i += horizontal_pair_lanes) {
        storeHorizontal(scratch, out, evenHorizontalSamples(loadHorizontalPair(data, i)));
        out += horizontal_lanes;
    }
    while (i < data.len) : (i += 2) {
        scratch[out] = data[i];
        out += 1;
    }

    @memcpy(data, scratch[0..data.len]);
}

fn unpackEvenOdd(data: []i32, scratch: []i32) void {
    if (data.len <= 2) return;

    const lows = lowCount(data.len);
    const highs = data.len / 2;
    var pair: usize = 0;
    while (pair + horizontal_lanes <= highs) : (pair += horizontal_lanes) {
        const low = loadHorizontal(data, pair);
        const high = loadHorizontal(data, lows + pair);
        storeHorizontalPair(scratch, pair * 2, interleaveHorizontal(low, high));
    }

    var i = pair * 2;
    var packed_index = pair;
    while (i < data.len) : (i += 2) {
        scratch[i] = data[packed_index];
        packed_index += 1;
    }

    i = pair * 2 + 1;
    packed_index = lows + pair;
    while (i < data.len) : (i += 2) {
        scratch[i] = data[packed_index];
        packed_index += 1;
    }

    @memcpy(data, scratch[0..data.len]);
}

fn packOddEven(data: []i32, scratch: []i32) void {
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

fn unpackOddEven(data: []i32, scratch: []i32) void {
    const lows = data.len / 2;
    var local: usize = 1;
    var packed_index: usize = 0;
    while (local < data.len) : (local += 2) {
        scratch[local] = data[packed_index];
        packed_index += 1;
    }
    local = 0;
    packed_index = lows;
    while (local < data.len) : (local += 2) {
        scratch[local] = data[packed_index];
        packed_index += 1;
    }
    @memcpy(data, scratch[0..data.len]);
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

fn makeHorizontalEvenMask() [horizontal_lanes]i32 {
    var mask: [horizontal_lanes]i32 = undefined;
    for (&mask, 0..) |*entry, index| {
        entry.* = @intCast(index * 2);
    }
    return mask;
}

fn makeHorizontalInterleaveMask() [horizontal_pair_lanes]i32 {
    var mask: [horizontal_pair_lanes]i32 = undefined;
    for (0..horizontal_lanes) |index| {
        mask[index * 2] = @intCast(index);
        mask[index * 2 + 1] = -@as(i32, @intCast(index + 1));
    }
    return mask;
}

inline fn loadHorizontal(data: []const i32, index: usize) HorizontalVector {
    return data[index..][0..horizontal_lanes].*;
}

inline fn storeHorizontal(data: []i32, index: usize, value: HorizontalVector) void {
    data[index..][0..horizontal_lanes].* = value;
}

inline fn loadHorizontalPair(data: []const i32, index: usize) HorizontalPairVector {
    return data[index..][0..horizontal_pair_lanes].*;
}

inline fn storeHorizontalPair(data: []i32, index: usize, value: HorizontalPairVector) void {
    data[index..][0..horizontal_pair_lanes].* = value;
}

inline fn evenHorizontalSamples(value: HorizontalPairVector) HorizontalVector {
    return @shuffle(i32, value, undefined, horizontal_even_mask);
}

inline fn interleaveHorizontal(low: HorizontalVector, high: HorizontalVector) HorizontalPairVector {
    return @shuffle(i32, low, high, horizontal_interleave_mask);
}

inline fn forward53PredictHorizontalGroup(data: []i32, odd_index: usize) void {
    const left = evenHorizontalSamples(loadHorizontalPair(data, odd_index - 1));
    const odd = evenHorizontalSamples(loadHorizontalPair(data, odd_index));
    const right = evenHorizontalSamples(loadHorizontalPair(data, odd_index + 1));
    const updated = odd - floorHalfHorizontal(left + right);
    storeHorizontalPair(data, odd_index - 1, interleaveHorizontal(left, updated));
}

inline fn forward53UpdateHorizontalGroup(data: []i32, even_index: usize) void {
    const even = evenHorizontalSamples(loadHorizontalPair(data, even_index));
    const left = evenHorizontalSamples(loadHorizontalPair(data, even_index - 1));
    const right = evenHorizontalSamples(loadHorizontalPair(data, even_index + 1));
    const updated = even + floorQuarterBiasedHorizontal(left + right);
    storeHorizontalPair(data, even_index, interleaveHorizontal(updated, right));
}

inline fn inverse53UpdateHorizontalGroup(data: []i32, even_index: usize) void {
    const even = evenHorizontalSamples(loadHorizontalPair(data, even_index));
    const left = evenHorizontalSamples(loadHorizontalPair(data, even_index - 1));
    const right = evenHorizontalSamples(loadHorizontalPair(data, even_index + 1));
    const updated = even - floorQuarterBiasedHorizontal(left + right);
    storeHorizontalPair(data, even_index, interleaveHorizontal(updated, right));
}

inline fn inverse53PredictHorizontalGroup(data: []i32, odd_index: usize) void {
    const left = evenHorizontalSamples(loadHorizontalPair(data, odd_index - 1));
    const odd = evenHorizontalSamples(loadHorizontalPair(data, odd_index));
    const right = evenHorizontalSamples(loadHorizontalPair(data, odd_index + 1));
    const updated = odd + floorHalfHorizontal(left + right);
    storeHorizontalPair(data, odd_index - 1, interleaveHorizontal(left, updated));
}
