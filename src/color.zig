const std = @import("std");
const image = @import("image.zig");
const simd = @import("simd.zig");

pub const ColorError = error{
    InvalidImage,
    SampleOutOfRange,
};

pub const RctPlanes = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    bit_depth: u8,
    y: []i32,
    cb: []i32,
    cr: []i32,

    pub fn deinit(self: *RctPlanes) void {
        self.allocator.free(self.y);
        self.allocator.free(self.cb);
        self.allocator.free(self.cr);
        self.* = undefined;
    }
};

pub fn forwardRct(allocator: std.mem.Allocator, rgb: image.RgbImage) !RctPlanes {
    if (rgb.width == 0 or rgb.height == 0) return ColorError.InvalidImage;
    const pixels = try std.math.mul(usize, rgb.width, rgb.height);
    if (rgb.samples.len != pixels * 3) return ColorError.InvalidImage;

    const y = try allocator.alloc(i32, pixels);
    errdefer allocator.free(y);
    const cb = try allocator.alloc(i32, pixels);
    errdefer allocator.free(cb);
    const cr = try allocator.alloc(i32, pixels);
    errdefer allocator.free(cr);

    if (simd.has_neon) {
        forwardRctNeon(rgb.samples, y, cb, cr, pixels);
        return .{
            .allocator = allocator,
            .width = rgb.width,
            .height = rgb.height,
            .bit_depth = rgb.bit_depth,
            .y = y,
            .cb = cb,
            .cr = cr,
        };
    }

    for (0..pixels) |i| {
        const r = @as(i32, rgb.samples[i * 3]);
        const g = @as(i32, rgb.samples[i * 3 + 1]);
        const b = @as(i32, rgb.samples[i * 3 + 2]);

        y[i] = floorQuarter(r + 2 * g + b);
        cb[i] = b - g;
        cr[i] = r - g;
    }

    return .{
        .allocator = allocator,
        .width = rgb.width,
        .height = rgb.height,
        .bit_depth = rgb.bit_depth,
        .y = y,
        .cb = cb,
        .cr = cr,
    };
}

pub fn inverseRct(allocator: std.mem.Allocator, planes: RctPlanes) !image.RgbImage {
    const pixels = try std.math.mul(usize, planes.width, planes.height);
    if (planes.y.len != pixels or planes.cb.len != pixels or planes.cr.len != pixels) {
        return ColorError.InvalidImage;
    }

    const max_sample = try maxSample(planes.bit_depth);
    const samples = try allocator.alloc(u16, pixels * 3);
    errdefer allocator.free(samples);

    if (simd.has_neon) {
        try inverseRctNeon(samples, planes, pixels, max_sample);
        return .{
            .allocator = allocator,
            .width = planes.width,
            .height = planes.height,
            .bit_depth = planes.bit_depth,
            .samples = samples,
        };
    }

    for (0..pixels) |i| {
        const g = planes.y[i] - floorQuarter(planes.cb[i] + planes.cr[i]);
        const r = planes.cr[i] + g;
        const b = planes.cb[i] + g;

        if (r < 0 or g < 0 or b < 0 or
            r > max_sample or g > max_sample or b > max_sample)
        {
            return ColorError.SampleOutOfRange;
        }

        samples[i * 3] = @intCast(r);
        samples[i * 3 + 1] = @intCast(g);
        samples[i * 3 + 2] = @intCast(b);
    }

    return .{
        .allocator = allocator,
        .width = planes.width,
        .height = planes.height,
        .bit_depth = planes.bit_depth,
        .samples = samples,
    };
}

const RctVector = @Vector(simd.neon_i32_lanes, i32);
const RctShiftVector = @Vector(simd.neon_i32_lanes, u5);
const rct_shift_1: RctShiftVector = @splat(1);
const rct_shift_2: RctShiftVector = @splat(2);

fn forwardRctNeon(samples: []const u16, y: []i32, cb: []i32, cr: []i32, pixels: usize) void {
    var i: usize = 0;
    while (i + simd.neon_i32_lanes <= pixels) : (i += simd.neon_i32_lanes) {
        const rgb = loadRgbVector(samples, i);
        const two_g = rgb.g << rct_shift_1;
        const y_vec = floorQuarterVector(rgb.r + two_g + rgb.b);
        const cb_vec = rgb.b - rgb.g;
        const cr_vec = rgb.r - rgb.g;
        y[i..][0..simd.neon_i32_lanes].* = @as([simd.neon_i32_lanes]i32, y_vec);
        cb[i..][0..simd.neon_i32_lanes].* = @as([simd.neon_i32_lanes]i32, cb_vec);
        cr[i..][0..simd.neon_i32_lanes].* = @as([simd.neon_i32_lanes]i32, cr_vec);
    }

    while (i < pixels) : (i += 1) {
        const r = @as(i32, samples[i * 3]);
        const g = @as(i32, samples[i * 3 + 1]);
        const b = @as(i32, samples[i * 3 + 2]);
        y[i] = floorQuarter(r + 2 * g + b);
        cb[i] = b - g;
        cr[i] = r - g;
    }
}

fn inverseRctNeon(samples: []u16, planes: RctPlanes, pixels: usize, max_sample: i32) !void {
    const zero: RctVector = @splat(0);
    const max: RctVector = @splat(max_sample);

    var i: usize = 0;
    while (i + simd.neon_i32_lanes <= pixels) : (i += simd.neon_i32_lanes) {
        const y: RctVector = planes.y[i..][0..simd.neon_i32_lanes].*;
        const cb: RctVector = planes.cb[i..][0..simd.neon_i32_lanes].*;
        const cr: RctVector = planes.cr[i..][0..simd.neon_i32_lanes].*;
        const g = y - floorQuarterVector(cb + cr);
        const r = cr + g;
        const b = cb + g;

        const out_of_range = (r < zero) | (g < zero) | (b < zero) |
            (r > max) | (g > max) | (b > max);
        if (@reduce(.Or, out_of_range)) return ColorError.SampleOutOfRange;

        storeRgbVector(samples, i, r, g, b);
    }

    while (i < pixels) : (i += 1) {
        const g = planes.y[i] - floorQuarter(planes.cb[i] + planes.cr[i]);
        const r = planes.cr[i] + g;
        const b = planes.cb[i] + g;

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

const RgbVector = struct {
    r: RctVector,
    g: RctVector,
    b: RctVector,
};

fn loadRgbVector(samples: []const u16, pixel_index: usize) RgbVector {
    var r: RctVector = @splat(0);
    var g: RctVector = @splat(0);
    var b: RctVector = @splat(0);
    inline for (0..simd.neon_i32_lanes) |lane| {
        const base = (pixel_index + lane) * 3;
        r[lane] = @intCast(samples[base]);
        g[lane] = @intCast(samples[base + 1]);
        b[lane] = @intCast(samples[base + 2]);
    }
    return .{ .r = r, .g = g, .b = b };
}

fn storeRgbVector(samples: []u16, pixel_index: usize, r: RctVector, g: RctVector, b: RctVector) void {
    inline for (0..simd.neon_i32_lanes) |lane| {
        const base = (pixel_index + lane) * 3;
        samples[base] = @intCast(r[lane]);
        samples[base + 1] = @intCast(g[lane]);
        samples[base + 2] = @intCast(b[lane]);
    }
}

fn maxSample(bit_depth: u8) !i32 {
    if (bit_depth == 0 or bit_depth > 16) return ColorError.InvalidImage;
    return (@as(i32, 1) << @as(u5, @intCast(bit_depth))) - 1;
}

fn floorQuarter(value: i32) i32 {
    return value >> 2;
}

fn floorQuarterVector(value: RctVector) RctVector {
    return value >> rct_shift_2;
}
