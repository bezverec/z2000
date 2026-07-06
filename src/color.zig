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
    const sample_count = try std.math.mul(usize, pixels, 3);
    if (rgb.samples.len != sample_count) return ColorError.InvalidImage;

    const y = try allocator.alloc(i32, pixels);
    errdefer allocator.free(y);
    const cb = try allocator.alloc(i32, pixels);
    errdefer allocator.free(cb);
    const cr = try allocator.alloc(i32, pixels);
    errdefer allocator.free(cr);

    forwardRctVector(rgb.samples, y, cb, cr, pixels, try dcLevelShift(rgb.bit_depth));

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
/// (2^(Ssiz-1)). The three output planes reuse the generic RctPlanes carrier
/// (y/cb/cr hold component 0/1/2 directly).
pub fn forwardNoTransform(allocator: std.mem.Allocator, rgb: image.RgbImage) !RctPlanes {
    if (rgb.width == 0 or rgb.height == 0) return ColorError.InvalidImage;
    const pixels = try std.math.mul(usize, rgb.width, rgb.height);
    const sample_count = try std.math.mul(usize, pixels, 3);
    if (rgb.samples.len != sample_count) return ColorError.InvalidImage;

    const c0 = try allocator.alloc(i32, pixels);
    errdefer allocator.free(c0);
    const c1 = try allocator.alloc(i32, pixels);
    errdefer allocator.free(c1);
    const c2 = try allocator.alloc(i32, pixels);
    errdefer allocator.free(c2);

    const level_shift = try dcLevelShift(rgb.bit_depth);
    var i: usize = 0;
    while (i < pixels) : (i += 1) {
        c0[i] = @as(i32, rgb.samples[i * 3]) - level_shift;
        c1[i] = @as(i32, rgb.samples[i * 3 + 1]) - level_shift;
        c2[i] = @as(i32, rgb.samples[i * 3 + 2]) - level_shift;
    }

    return .{
        .allocator = allocator,
        .width = rgb.width,
        .height = rgb.height,
        .bit_depth = rgb.bit_depth,
        .y = c0,
        .cb = c1,
        .cr = c2,
    };
}

pub fn inverseNoTransform(allocator: std.mem.Allocator, planes: RctPlanes) !image.RgbImage {
    const pixels = try std.math.mul(usize, planes.width, planes.height);
    if (planes.y.len != pixels or planes.cb.len != pixels or planes.cr.len != pixels) {
        return ColorError.InvalidImage;
    }
    const sample_count = try std.math.mul(usize, pixels, 3);
    const max_sample_value = try maxSample(planes.bit_depth);
    const level_shift = try dcLevelShift(planes.bit_depth);

    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);

    var i: usize = 0;
    while (i < pixels) : (i += 1) {
        const c0 = planes.y[i] + level_shift;
        const c1 = planes.cb[i] + level_shift;
        const c2 = planes.cr[i] + level_shift;
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
    // ISO/IEC 15444-1 B.1.1 DC level shift: unsigned samples are shifted by
    // 2^(Ssiz-1) before the component transform. Cb/Cr are component
    // differences, so the shift cancels there; only Y needs it.
    const shift_vec: RctVector = @splat(level_shift);
    var i: usize = 0;
    while (i + rct_lanes <= pixels) : (i += rct_lanes) {
        const rgb = loadRgbVector(samples, i);
        const two_g = rgb.g << rct_shift_1;
        const y_vec = floorQuarterVector(rgb.r + two_g + rgb.b) - shift_vec;
        const cb_vec = rgb.b - rgb.g;
        const cr_vec = rgb.r - rgb.g;
        y[i..][0..rct_lanes].* = @as([rct_lanes]i32, y_vec);
        cb[i..][0..rct_lanes].* = @as([rct_lanes]i32, cb_vec);
        cr[i..][0..rct_lanes].* = @as([rct_lanes]i32, cr_vec);
    }

    while (i < pixels) : (i += 1) {
        const r = @as(i32, samples[i * 3]);
        const g = @as(i32, samples[i * 3 + 1]);
        const b = @as(i32, samples[i * 3 + 2]);
        y[i] = floorQuarter(r + 2 * g + b) - level_shift;
        cb[i] = b - g;
        cr[i] = r - g;
    }
}

fn inverseRctVector(samples: []u16, planes: RctPlanes, pixels: usize, max_sample: i32) !void {
    const zero: RctVector = @splat(0);
    const max: RctVector = @splat(max_sample);
    const level_shift = try dcLevelShift(planes.bit_depth);
    const shift_vec: RctVector = @splat(level_shift);

    var i: usize = 0;
    while (i + rct_lanes <= pixels) : (i += rct_lanes) {
        const y: RctVector = @as(RctVector, planes.y[i..][0..rct_lanes].*) + shift_vec;
        const cb: RctVector = planes.cb[i..][0..rct_lanes].*;
        const cr: RctVector = planes.cr[i..][0..rct_lanes].*;
        const g = y - floorQuarterVector(cb + cr);
        const r = cr + g;
        const b = cb + g;

        const out_of_range = (r < zero) | (g < zero) | (b < zero) |
            (r > max) | (g > max) | (b > max);
        if (@reduce(.Or, out_of_range)) return ColorError.SampleOutOfRange;

        storeRgbVector(samples, i, r, g, b);
    }

    while (i < pixels) : (i += 1) {
        const g = planes.y[i] + level_shift - floorQuarter(planes.cb[i] + planes.cr[i]);
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

pub const IctPlanes = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    bit_depth: u8,
    y: []f32,
    cb: []f32,
    cr: []f32,

    pub fn deinit(self: *IctPlanes) void {
        self.allocator.free(self.y);
        self.allocator.free(self.cb);
        self.allocator.free(self.cr);
        self.* = undefined;
    }
};

/// ISO/IEC 15444-1 G.3: irreversible component transform on DC level shifted
/// samples.
pub fn forwardIct(allocator: std.mem.Allocator, rgb: image.RgbImage) !IctPlanes {
    if (rgb.width == 0 or rgb.height == 0) return ColorError.InvalidImage;
    const pixels = try std.math.mul(usize, rgb.width, rgb.height);
    const sample_count = try std.math.mul(usize, pixels, 3);
    if (rgb.samples.len != sample_count) return ColorError.InvalidImage;
    const shift: f32 = @floatFromInt(try dcLevelShift(rgb.bit_depth));

    const y = try allocator.alloc(f32, pixels);
    errdefer allocator.free(y);
    const cb = try allocator.alloc(f32, pixels);
    errdefer allocator.free(cb);
    const cr = try allocator.alloc(f32, pixels);
    errdefer allocator.free(cr);

    forwardIctVector(rgb.samples, y, cb, cr, pixels, shift);

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

pub fn inverseIct(allocator: std.mem.Allocator, planes: IctPlanes) !image.RgbImage {
    const pixels = try std.math.mul(usize, planes.width, planes.height);
    if (planes.y.len != pixels or planes.cb.len != pixels or planes.cr.len != pixels) {
        return ColorError.InvalidImage;
    }
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
    const shift_vec: IctVector = @splat(shift);
    const cr_to_r: IctVector = @splat(1.402);
    const cb_to_g: IctVector = @splat(0.34413);
    const cr_to_g: IctVector = @splat(0.71414);
    const cb_to_b: IctVector = @splat(1.772);

    var i: usize = 0;
    while (i + ict_lanes <= pixels) : (i += ict_lanes) {
        const y_vec: IctVector = planes.y[i..][0..ict_lanes].*;
        const cb_vec: IctVector = planes.cb[i..][0..ict_lanes].*;
        const cr_vec: IctVector = planes.cr[i..][0..ict_lanes].*;
        const r = y_vec + cr_to_r * cr_vec + shift_vec;
        const g = y_vec - cb_to_g * cb_vec - cr_to_g * cr_vec + shift_vec;
        const b = y_vec + cb_to_b * cb_vec + shift_vec;
        storeIctRgbVector(samples, i, r, g, b, max_sample);
    }

    while (i < pixels) : (i += 1) {
        const y = planes.y[i];
        const cb = planes.cb[i];
        const cr = planes.cr[i];
        const r = y + 1.402 * cr;
        const g = y - 0.34413 * cb - 0.71414 * cr;
        const b = y + 1.772 * cb;
        samples[i * 3] = clampToSample(r + shift, max_sample);
        samples[i * 3 + 1] = clampToSample(g + shift, max_sample);
        samples[i * 3 + 2] = clampToSample(b + shift, max_sample);
    }
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
