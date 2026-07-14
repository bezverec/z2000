const std = @import("std");
const image = @import("image.zig");
const simd = @import("simd.zig");

pub const ColorError = error{
    InvalidImage,
    SampleOutOfRange,
};

/// F1 component-generic bound: layouts with 1..4 components are the public
/// surface (grayscale=1 and RGB=3 exist today; alpha and CMYK arrive on top).
pub const max_components = 4;

/// N-plane sample carrier shared by the reversible (i32) and irreversible
/// (f32) pipelines. `init` allocates and owns `component_count` planes of
/// `width * height` samples; a borrowed instance (planes filled in from
/// slices owned elsewhere) must simply not call `deinit`.
pub fn ComponentPlanesOf(comptime Sample: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        width: usize,
        height: usize,
        bit_depth: u8,
        planes: [][]Sample,

        pub fn init(
            allocator: std.mem.Allocator,
            width: usize,
            height: usize,
            bit_depth: u8,
            component_count: usize,
        ) !Self {
            if (component_count == 0 or component_count > max_components) {
                return ColorError.InvalidImage;
            }
            const pixels = try std.math.mul(usize, width, height);
            const planes = try allocator.alloc([]Sample, component_count);
            errdefer allocator.free(planes);
            var allocated: usize = 0;
            errdefer for (planes[0..allocated]) |plane_slice| allocator.free(plane_slice);
            while (allocated < component_count) : (allocated += 1) {
                planes[allocated] = try allocator.alloc(Sample, pixels);
            }
            return .{
                .allocator = allocator,
                .width = width,
                .height = height,
                .bit_depth = bit_depth,
                .planes = planes,
            };
        }

        pub fn componentCount(self: Self) usize {
            return self.planes.len;
        }

        pub fn deinit(self: *Self) void {
            for (self.planes) |plane_slice| self.allocator.free(plane_slice);
            self.allocator.free(self.planes);
            self.* = undefined;
        }
    };
}

pub const RctPlanes = ComponentPlanesOf(i32);
pub const IctPlanes = ComponentPlanesOf(f32);

/// Unsigned sample planes as they enter/leave the codec (one plane per
/// component, no interleaving): the input/output carrier for the bounded
/// 1..4-component no-MCT layouts.
pub const SamplePlanes = ComponentPlanesOf(u16);

fn validatePixelPlanes(comptime Sample: type, planes: ComponentPlanesOf(Sample), expected_components: usize) !usize {
    const pixels = try std.math.mul(usize, planes.width, planes.height);
    if (planes.planes.len != expected_components) return ColorError.InvalidImage;
    for (planes.planes) |plane_slice| {
        if (plane_slice.len != pixels) return ColorError.InvalidImage;
    }
    return pixels;
}

pub fn forwardRct(allocator: std.mem.Allocator, rgb: image.RgbImage) !RctPlanes {
    if (rgb.width == 0 or rgb.height == 0) return ColorError.InvalidImage;
    const pixels = try std.math.mul(usize, rgb.width, rgb.height);
    const sample_count = try std.math.mul(usize, pixels, 3);
    if (rgb.samples.len != sample_count) return ColorError.InvalidImage;

    var out = try RctPlanes.init(allocator, rgb.width, rgb.height, rgb.bit_depth, 3);
    errdefer out.deinit();
    forwardRctVector(rgb.samples, out.planes[0], out.planes[1], out.planes[2], pixels, try dcLevelShift(rgb.bit_depth));
    return out;
}

pub fn inverseRct(allocator: std.mem.Allocator, planes: RctPlanes) !image.RgbImage {
    const pixels = try validatePixelPlanes(i32, planes, 3);
    const sample_count = try std.math.mul(usize, pixels, 3);

    const max_sample = try maxSample(planes.bit_depth);
    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);

    try inverseRctVector(samples, planes, pixels, max_sample);

    return .{
        .allocator = allocator,
        .width = planes.width,
        .height = planes.height,
        .bit_depth = planes.bit_depth,
        .samples = samples,
    };
}

/// mct = none: no inter-component decorrelation. Each component is coded
/// independently, so it carries only the ISO B.1.1 DC level shift
/// (2^(Ssiz-1)); component 0/1/2 land in planes 0/1/2 directly.
pub fn forwardNoTransform(allocator: std.mem.Allocator, rgb: image.RgbImage) !RctPlanes {
    if (rgb.width == 0 or rgb.height == 0) return ColorError.InvalidImage;
    const pixels = try std.math.mul(usize, rgb.width, rgb.height);
    const sample_count = try std.math.mul(usize, pixels, 3);
    if (rgb.samples.len != sample_count) return ColorError.InvalidImage;

    var out = try RctPlanes.init(allocator, rgb.width, rgb.height, rgb.bit_depth, 3);
    errdefer out.deinit();
    const c0 = out.planes[0];
    const c1 = out.planes[1];
    const c2 = out.planes[2];

    const level_shift = try dcLevelShift(rgb.bit_depth);
    var i: usize = 0;
    while (i < pixels) : (i += 1) {
        c0[i] = @as(i32, rgb.samples[i * 3]) - level_shift;
        c1[i] = @as(i32, rgb.samples[i * 3 + 1]) - level_shift;
        c2[i] = @as(i32, rgb.samples[i * 3 + 2]) - level_shift;
    }

    return out;
}

pub fn inverseNoTransform(allocator: std.mem.Allocator, planes: RctPlanes) !image.RgbImage {
    const pixels = try validatePixelPlanes(i32, planes, 3);
    const sample_count = try std.math.mul(usize, pixels, 3);
    const max_sample_value = try maxSample(planes.bit_depth);
    const level_shift = try dcLevelShift(planes.bit_depth);

    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);

    const plane0 = planes.planes[0];
    const plane1 = planes.planes[1];
    const plane2 = planes.planes[2];
    var i: usize = 0;
    while (i < pixels) : (i += 1) {
        const c0 = plane0[i] + level_shift;
        const c1 = plane1[i] + level_shift;
        const c2 = plane2[i] + level_shift;
        if (c0 < 0 or c1 < 0 or c2 < 0 or
            c0 > max_sample_value or c1 > max_sample_value or c2 > max_sample_value)
        {
            return ColorError.SampleOutOfRange;
        }
        samples[i * 3] = @intCast(c0);
        samples[i * 3 + 1] = @intCast(c1);
        samples[i * 3 + 2] = @intCast(c2);
    }

    return .{
        .allocator = allocator,
        .width = planes.width,
        .height = planes.height,
        .bit_depth = planes.bit_depth,
        .samples = samples,
    };
}

const rct_lanes = simd.i32_lanes;
const RctVector = @Vector(rct_lanes, i32);
const RctShiftVector = @Vector(rct_lanes, u5);
const rct_shift_1: RctShiftVector = @splat(1);
const rct_shift_2: RctShiftVector = @splat(2);
const ict_lanes = simd.i32_lanes;
const IctVector = @Vector(ict_lanes, f32);

fn forwardRctVector(samples: []const u16, y: []i32, cb: []i32, cr: []i32, pixels: usize, level_shift: i32) void {
    forwardRctRange(samples, y, cb, cr, 0, pixels, level_shift);
}

/// Forward RCT over the pixel range [`begin`, `end`). `begin` is a multiple
/// of `rct_lanes`; the scalar tail is emitted only when `end` is the real
/// pixel count. Each pixel is independent, so banding is byte-identical to a
/// single full pass.
fn forwardRctRange(samples: []const u16, y: []i32, cb: []i32, cr: []i32, begin: usize, end: usize, level_shift: i32) void {
    // ISO/IEC 15444-1 B.1.1 DC level shift: unsigned samples are shifted by
    // 2^(Ssiz-1) before the component transform. Cb/Cr are component
    // differences, so the shift cancels there; only Y needs it.
    const shift_vec: RctVector = @splat(level_shift);
    var i: usize = begin;
    while (i + rct_lanes <= end) : (i += rct_lanes) {
        const rgb = loadRgbVector(samples, i);
        const two_g = rgb.g << rct_shift_1;
        const y_vec = floorQuarterVector(rgb.r + two_g + rgb.b) - shift_vec;
        const cb_vec = rgb.b - rgb.g;
        const cr_vec = rgb.r - rgb.g;
        y[i..][0..rct_lanes].* = @as([rct_lanes]i32, y_vec);
        cb[i..][0..rct_lanes].* = @as([rct_lanes]i32, cb_vec);
        cr[i..][0..rct_lanes].* = @as([rct_lanes]i32, cr_vec);
    }

    while (i < end) : (i += 1) {
        const r = @as(i32, samples[i * 3]);
        const g = @as(i32, samples[i * 3 + 1]);
        const b = @as(i32, samples[i * 3 + 2]);
        y[i] = floorQuarter(r + 2 * g + b) - level_shift;
        cb[i] = b - g;
        cr[i] = r - g;
    }
}

fn inverseRctVector(samples: []u16, planes: RctPlanes, pixels: usize, max_sample: i32) !void {
    const level_shift = try dcLevelShift(planes.bit_depth);
    try inverseRctRange(samples, planes, 0, pixels, max_sample, level_shift);
}

fn inverseRctRange(samples: []u16, planes: RctPlanes, begin: usize, end: usize, max_sample: i32, level_shift: i32) !void {
    const zero: RctVector = @splat(0);
    const max: RctVector = @splat(max_sample);
    const shift_vec: RctVector = @splat(level_shift);
    const y_plane = planes.planes[0];
    const cb_plane = planes.planes[1];
    const cr_plane = planes.planes[2];

    var i: usize = begin;
    while (i + rct_lanes <= end) : (i += rct_lanes) {
        const y: RctVector = @as(RctVector, y_plane[i..][0..rct_lanes].*) + shift_vec;
        const cb: RctVector = cb_plane[i..][0..rct_lanes].*;
        const cr: RctVector = cr_plane[i..][0..rct_lanes].*;
        const g = y - floorQuarterVector(cb + cr);
        const r = cr + g;
        const b = cb + g;

        const out_of_range = (r < zero) | (g < zero) | (b < zero) |
            (r > max) | (g > max) | (b > max);
        if (@reduce(.Or, out_of_range)) return ColorError.SampleOutOfRange;

        storeRgbVector(samples, i, r, g, b);
    }

    while (i < end) : (i += 1) {
        const g = y_plane[i] + level_shift - floorQuarter(cb_plane[i] + cr_plane[i]);
        const r = cr_plane[i] + g;
        const b = cb_plane[i] + g;

        if (r < 0 or g < 0 or b < 0 or
            r > max_sample or g > max_sample or b > max_sample)
        {
            return ColorError.SampleOutOfRange;
        }

        samples[i * 3] = @intCast(r);
        samples[i * 3 + 1] = @intCast(g);
        samples[i * 3 + 2] = @intCast(b);
    }
}

// ---------------------------------------------------------------------------
// Parallel RCT: the color transform is per-pixel independent, so the pixel
// range splits cleanly across workers (bands aligned to rct_lanes, the last
// band taking the scalar tail). Output is byte-identical to the serial pass.
// Small phases (~3-5 ms at high thread counts) that were a serial tail once
// the DWT went full-core.
// ---------------------------------------------------------------------------

const max_rct_workers = 32;
// Inverse color is a short memory-heavy tail after T1. Four workers beat eight
// on the maintained 8C/16T host; smaller images stay serial to avoid spawn cost.
const max_inverse_color_workers = 4;
const min_inverse_color_pixels_per_worker = 64 * 1024;

const RctForwardJob = struct {
    samples: []const u16,
    y: []i32,
    cb: []i32,
    cr: []i32,
    begin: usize,
    end: usize,
    level_shift: i32,
};

fn rctForwardWorker(job: *RctForwardJob) void {
    forwardRctRange(job.samples, job.y, job.cb, job.cr, job.begin, job.end, job.level_shift);
}

/// Splits [0, pixels) into up to `thread_count` bands aligned to rct_lanes
/// (last band → pixels). Writes band [begin,end) pairs into `out` and returns
/// the count. A single scalar-only band is produced when there are no full
/// vector groups.
fn colorBands(pixels: usize, lanes: usize, thread_count: usize, out: *[max_rct_workers][2]usize) usize {
    const groups = pixels / lanes;
    if (groups == 0) {
        out[0] = .{ 0, pixels };
        return 1;
    }
    const bands = @max(1, @min(@min(thread_count, max_rct_workers), groups));
    const base = groups / bands;
    const extra = groups % bands;
    var group_start: usize = 0;
    var b: usize = 0;
    while (b < bands) : (b += 1) {
        const g = base + (if (b < extra) @as(usize, 1) else 0);
        const begin = group_start * lanes;
        const is_last = b == bands - 1;
        out[b] = .{ begin, if (is_last) pixels else (group_start + g) * lanes };
        group_start += g;
    }
    return bands;
}

fn inverseColorThreadCount(pixels: usize, requested_threads: usize) usize {
    const workers_for_size = if (pixels == 0)
        1
    else
        1 + (pixels - 1) / min_inverse_color_pixels_per_worker;
    return @max(1, @min(@min(requested_threads, max_inverse_color_workers), workers_for_size));
}

fn runColorJobs(
    comptime Job: type,
    jobs: []Job,
    comptime worker: fn (*Job) void,
) void {
    if (jobs.len == 1) {
        worker(&jobs[0]);
        return;
    }

    var threads: [max_inverse_color_workers - 1]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < jobs.len - 1) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, worker, .{&jobs[spawned]}) catch break;
    }
    var remaining = spawned;
    while (remaining < jobs.len) : (remaining += 1) worker(&jobs[remaining]);
    for (threads[0..spawned]) |thread| thread.join();
}

const RctInverseJob = struct {
    samples: []u16,
    planes: RctPlanes,
    begin: usize,
    end: usize,
    max_sample: i32,
    level_shift: i32,
    result: ColorError!void = {},
};

fn rctInverseWorker(job: *RctInverseJob) void {
    job.result = inverseRctRange(job.samples, job.planes, job.begin, job.end, job.max_sample, job.level_shift);
}

pub fn inverseRctThreaded(
    allocator: std.mem.Allocator,
    planes: RctPlanes,
    requested_threads: usize,
) !image.RgbImage {
    const pixels = try validatePixelPlanes(i32, planes, 3);
    const sample_count = try std.math.mul(usize, pixels, 3);
    const max_sample = try maxSample(planes.bit_depth);
    const level_shift = try dcLevelShift(planes.bit_depth);
    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);

    var ranges: [max_rct_workers][2]usize = undefined;
    const band_count = colorBands(pixels, rct_lanes, inverseColorThreadCount(pixels, requested_threads), &ranges);
    var jobs: [max_inverse_color_workers]RctInverseJob = undefined;
    for (0..band_count) |band| {
        jobs[band] = .{
            .samples = samples,
            .planes = planes,
            .begin = ranges[band][0],
            .end = ranges[band][1],
            .max_sample = max_sample,
            .level_shift = level_shift,
        };
    }
    runColorJobs(RctInverseJob, jobs[0..band_count], rctInverseWorker);
    for (jobs[0..band_count]) |job| try job.result;

    return .{
        .allocator = allocator,
        .width = planes.width,
        .height = planes.height,
        .bit_depth = planes.bit_depth,
        .samples = samples,
    };
}

pub fn forwardRctThreaded(allocator: std.mem.Allocator, rgb: image.RgbImage, thread_count: usize) !RctPlanes {
    if (rgb.width == 0 or rgb.height == 0) return ColorError.InvalidImage;
    const pixels = try std.math.mul(usize, rgb.width, rgb.height);
    const sample_count = try std.math.mul(usize, pixels, 3);
    if (rgb.samples.len != sample_count) return ColorError.InvalidImage;

    var out = try RctPlanes.init(allocator, rgb.width, rgb.height, rgb.bit_depth, 3);
    errdefer out.deinit();
    const y = out.planes[0];
    const cb = out.planes[1];
    const cr = out.planes[2];

    const level_shift = try dcLevelShift(rgb.bit_depth);
    var ranges: [max_rct_workers][2]usize = undefined;
    const band_count = colorBands(pixels, rct_lanes, thread_count, &ranges);

    if (band_count <= 1) {
        forwardRctRange(rgb.samples, y, cb, cr, 0, pixels, level_shift);
    } else {
        var jobs: [max_rct_workers]RctForwardJob = undefined;
        for (0..band_count) |b| jobs[b] = .{ .samples = rgb.samples, .y = y, .cb = cb, .cr = cr, .begin = ranges[b][0], .end = ranges[b][1], .level_shift = level_shift };
        var threads: [max_rct_workers]std.Thread = undefined;
        var spawned: usize = 0;
        while (spawned < band_count - 1) : (spawned += 1) {
            threads[spawned] = std.Thread.spawn(.{}, rctForwardWorker, .{&jobs[spawned]}) catch break;
        }
        var remaining = spawned;
        while (remaining < band_count) : (remaining += 1) rctForwardWorker(&jobs[remaining]);
        for (threads[0..spawned]) |thread| thread.join();
    }

    return out;
}

const RgbVector = struct {
    r: RctVector,
    g: RctVector,
    b: RctVector,
};

fn loadRgbVector(samples: []const u16, pixel_index: usize) RgbVector {
    var r: RctVector = @splat(0);
    var g: RctVector = @splat(0);
    var b: RctVector = @splat(0);
    inline for (0..rct_lanes) |lane| {
        const base = (pixel_index + lane) * 3;
        r[lane] = @intCast(samples[base]);
        g[lane] = @intCast(samples[base + 1]);
        b[lane] = @intCast(samples[base + 2]);
    }
    return .{ .r = r, .g = g, .b = b };
}

fn storeRgbVector(samples: []u16, pixel_index: usize, r: RctVector, g: RctVector, b: RctVector) void {
    inline for (0..rct_lanes) |lane| {
        const base = (pixel_index + lane) * 3;
        samples[base] = @intCast(r[lane]);
        samples[base + 1] = @intCast(g[lane]);
        samples[base + 2] = @intCast(b[lane]);
    }
}

/// ISO/IEC 15444-1 G.3: irreversible component transform on DC level shifted
/// samples.
pub fn forwardIct(allocator: std.mem.Allocator, rgb: image.RgbImage) !IctPlanes {
    if (rgb.width == 0 or rgb.height == 0) return ColorError.InvalidImage;
    const pixels = try std.math.mul(usize, rgb.width, rgb.height);
    const sample_count = try std.math.mul(usize, pixels, 3);
    if (rgb.samples.len != sample_count) return ColorError.InvalidImage;
    const shift: f32 = @floatFromInt(try dcLevelShift(rgb.bit_depth));

    var out = try IctPlanes.init(allocator, rgb.width, rgb.height, rgb.bit_depth, 3);
    errdefer out.deinit();
    forwardIctVector(rgb.samples, out.planes[0], out.planes[1], out.planes[2], pixels, shift);
    return out;
}

pub fn inverseIct(allocator: std.mem.Allocator, planes: IctPlanes) !image.RgbImage {
    const pixels = try validatePixelPlanes(f32, planes, 3);
    const sample_count = try std.math.mul(usize, pixels, 3);
    const max_sample = try maxSample(planes.bit_depth);
    const shift: f32 = @floatFromInt(try dcLevelShift(planes.bit_depth));

    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);

    inverseIctVector(samples, planes, pixels, shift, max_sample);

    return .{
        .allocator = allocator,
        .width = planes.width,
        .height = planes.height,
        .bit_depth = planes.bit_depth,
        .samples = samples,
    };
}

fn forwardIctVector(samples: []const u16, y: []f32, cb: []f32, cr: []f32, pixels: usize, shift: f32) void {
    const shift_vec: IctVector = @splat(shift);
    const y_r: IctVector = @splat(0.299);
    const y_g: IctVector = @splat(0.587);
    const y_b: IctVector = @splat(0.114);
    const cb_r: IctVector = @splat(-0.16875);
    const cb_g: IctVector = @splat(-0.331260);
    const cr_g: IctVector = @splat(0.41869);
    const cr_b: IctVector = @splat(0.08131);
    const half: IctVector = @splat(0.5);

    var i: usize = 0;
    while (i + ict_lanes <= pixels) : (i += ict_lanes) {
        const rgb = loadIctRgbVector(samples, i, shift_vec);
        y[i..][0..ict_lanes].* = @as([ict_lanes]f32, y_r * rgb.r + y_g * rgb.g + y_b * rgb.b);
        cb[i..][0..ict_lanes].* = @as([ict_lanes]f32, cb_r * rgb.r + cb_g * rgb.g + half * rgb.b);
        cr[i..][0..ict_lanes].* = @as([ict_lanes]f32, half * rgb.r - cr_g * rgb.g - cr_b * rgb.b);
    }

    while (i < pixels) : (i += 1) {
        const r = @as(f32, @floatFromInt(samples[i * 3])) - shift;
        const g = @as(f32, @floatFromInt(samples[i * 3 + 1])) - shift;
        const b = @as(f32, @floatFromInt(samples[i * 3 + 2])) - shift;
        y[i] = 0.299 * r + 0.587 * g + 0.114 * b;
        cb[i] = -0.16875 * r - 0.331260 * g + 0.5 * b;
        cr[i] = 0.5 * r - 0.41869 * g - 0.08131 * b;
    }
}

fn inverseIctVector(samples: []u16, planes: IctPlanes, pixels: usize, shift: f32, max_sample: i32) void {
    inverseIctRange(samples, planes, 0, pixels, shift, max_sample);
}

fn inverseIctRange(samples: []u16, planes: IctPlanes, begin: usize, end: usize, shift: f32, max_sample: i32) void {
    const shift_vec: IctVector = @splat(shift);
    const cr_to_r: IctVector = @splat(1.402);
    const cb_to_g: IctVector = @splat(0.34413);
    const cr_to_g: IctVector = @splat(0.71414);
    const cb_to_b: IctVector = @splat(1.772);

    const y_plane = planes.planes[0];
    const cb_plane = planes.planes[1];
    const cr_plane = planes.planes[2];
    var i: usize = begin;
    while (i + ict_lanes <= end) : (i += ict_lanes) {
        const y_vec: IctVector = y_plane[i..][0..ict_lanes].*;
        const cb_vec: IctVector = cb_plane[i..][0..ict_lanes].*;
        const cr_vec: IctVector = cr_plane[i..][0..ict_lanes].*;
        const r = y_vec + cr_to_r * cr_vec + shift_vec;
        const g = y_vec - cb_to_g * cb_vec - cr_to_g * cr_vec + shift_vec;
        const b = y_vec + cb_to_b * cb_vec + shift_vec;
        storeIctRgbVector(samples, i, r, g, b, max_sample);
    }

    while (i < end) : (i += 1) {
        const y = y_plane[i];
        const cb = cb_plane[i];
        const cr = cr_plane[i];
        const r = y + 1.402 * cr;
        const g = y - 0.34413 * cb - 0.71414 * cr;
        const b = y + 1.772 * cb;
        samples[i * 3] = clampToSample(r + shift, max_sample);
        samples[i * 3 + 1] = clampToSample(g + shift, max_sample);
        samples[i * 3 + 2] = clampToSample(b + shift, max_sample);
    }
}

const IctInverseJob = struct {
    samples: []u16,
    planes: IctPlanes,
    begin: usize,
    end: usize,
    shift: f32,
    max_sample: i32,
};

fn ictInverseWorker(job: *IctInverseJob) void {
    inverseIctRange(job.samples, job.planes, job.begin, job.end, job.shift, job.max_sample);
}

pub fn inverseIctThreaded(
    allocator: std.mem.Allocator,
    planes: IctPlanes,
    requested_threads: usize,
) !image.RgbImage {
    const pixels = try validatePixelPlanes(f32, planes, 3);
    const sample_count = try std.math.mul(usize, pixels, 3);
    const max_sample = try maxSample(planes.bit_depth);
    const shift: f32 = @floatFromInt(try dcLevelShift(planes.bit_depth));
    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);

    var ranges: [max_rct_workers][2]usize = undefined;
    const band_count = colorBands(pixels, ict_lanes, inverseColorThreadCount(pixels, requested_threads), &ranges);
    var jobs: [max_inverse_color_workers]IctInverseJob = undefined;
    for (0..band_count) |band| {
        jobs[band] = .{
            .samples = samples,
            .planes = planes,
            .begin = ranges[band][0],
            .end = ranges[band][1],
            .shift = shift,
            .max_sample = max_sample,
        };
    }
    runColorJobs(IctInverseJob, jobs[0..band_count], ictInverseWorker);

    return .{
        .allocator = allocator,
        .width = planes.width,
        .height = planes.height,
        .bit_depth = planes.bit_depth,
        .samples = samples,
    };
}

const IctRgbVector = struct {
    r: IctVector,
    g: IctVector,
    b: IctVector,
};

fn loadIctRgbVector(samples: []const u16, pixel_index: usize, shift: IctVector) IctRgbVector {
    var r: IctVector = @splat(0);
    var g: IctVector = @splat(0);
    var b: IctVector = @splat(0);
    inline for (0..ict_lanes) |lane| {
        const base = (pixel_index + lane) * 3;
        r[lane] = @as(f32, @floatFromInt(samples[base]));
        g[lane] = @as(f32, @floatFromInt(samples[base + 1]));
        b[lane] = @as(f32, @floatFromInt(samples[base + 2]));
    }
    return .{ .r = r - shift, .g = g - shift, .b = b - shift };
}

fn storeIctRgbVector(samples: []u16, pixel_index: usize, r: IctVector, g: IctVector, b: IctVector, max_sample: i32) void {
    inline for (0..ict_lanes) |lane| {
        const base = (pixel_index + lane) * 3;
        samples[base] = clampToSample(r[lane], max_sample);
        samples[base + 1] = clampToSample(g[lane], max_sample);
        samples[base + 2] = clampToSample(b[lane], max_sample);
    }
}

fn clampToSample(value: f32, max_sample: i32) u16 {
    if (std.math.isNan(value)) return 0;
    const max_f: f32 = @floatFromInt(max_sample);
    const clamped = std.math.clamp(@round(value), 0.0, max_f);
    return @intFromFloat(clamped);
}

fn maxSample(bit_depth: u8) !i32 {
    if (bit_depth == 0 or bit_depth > 16) return ColorError.InvalidImage;
    return (@as(i32, 1) << @as(u5, @intCast(bit_depth))) - 1;
}

fn dcLevelShift(bit_depth: u8) !i32 {
    if (bit_depth == 0 or bit_depth > 16) return ColorError.InvalidImage;
    return @as(i32, 1) << @as(u5, @intCast(bit_depth - 1));
}

fn floorQuarter(value: i32) i32 {
    return value >> 2;
}

fn floorQuarterVector(value: RctVector) RctVector {
    return value >> rct_shift_2;
}
