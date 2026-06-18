const std = @import("std");
const image = @import("image.zig");

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

    for (0..pixels) |i| {
        const r = @as(i32, rgb.samples[i * 3]);
        const g = @as(i32, rgb.samples[i * 3 + 1]);
        const b = @as(i32, rgb.samples[i * 3 + 2]);

        y[i] = @divFloor(r + 2 * g + b, 4);
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

    for (0..pixels) |i| {
        const g = planes.y[i] - @divFloor(planes.cb[i] + planes.cr[i], 4);
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

fn maxSample(bit_depth: u8) !i32 {
    if (bit_depth == 0 or bit_depth > 16) return ColorError.InvalidImage;
    return (@as(i32, 1) << @as(u5, @intCast(bit_depth))) - 1;
}
