const std = @import("std");
const image = @import("image.zig");
const simd = @import("simd.zig");

pub const ColorError = error{
    InvalidImage,
    SampleOutOfRange,
    UnsupportedColorSpace,
};

/// F1 component-generic bound: layouts with 1..4 components are the public
/// surface (grayscale=1 and RGB=3 exist today; alpha and CMYK arrive on top).
pub const max_components = 4;

/// Whole-image alpha semantics shared by TIFF ExtraSamples and JP2 cdef.
/// Samples are preserved as stored; the codec never silently changes between
/// associated (premultiplied) and unassociated alpha.
pub const AlphaMode = enum {
    unassociated,
    associated,

    pub fn label(self: AlphaMode) []const u8 {
        return switch (self) {
            .unassociated => "unassociated",
            .associated => "associated",
        };
    }
};

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
        /// Common precision, or zero for a mixed-precision sample carrier.
        bit_depth: u8,
        component_bit_depths: [max_components]u8 = [_]u8{0} ** max_components,
        component_widths: [max_components]usize = [_]usize{0} ** max_components,
        component_heights: [max_components]usize = [_]usize{0} ** max_components,
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
            var component_bit_depths = [_]u8{0} ** max_components;
            @memset(component_bit_depths[0..component_count], bit_depth);
            var component_widths = [_]usize{0} ** max_components;
            var component_heights = [_]usize{0} ** max_components;
            @memset(component_widths[0..component_count], width);
            @memset(component_heights[0..component_count], height);
            return .{
                .allocator = allocator,
                .width = width,
                .height = height,
                .bit_depth = bit_depth,
                .component_bit_depths = component_bit_depths,
                .component_widths = component_widths,
                .component_heights = component_heights,
                .planes = planes,
            };
        }

        pub fn initWithComponentBitDepths(
            allocator: std.mem.Allocator,
            width: usize,
            height: usize,
            bit_depths: []const u8,
        ) !Self {
            if (bit_depths.len == 0 or bit_depths.len > max_components) {
                return ColorError.InvalidImage;
            }
            var common = bit_depths[0];
            for (bit_depths) |bit_depth| {
                if (bit_depth == 0 or bit_depth > 16) return ColorError.InvalidImage;
                if (bit_depth != common) common = 0;
            }
            var out = try Self.init(allocator, width, height, common, bit_depths.len);
            @memcpy(out.component_bit_depths[0..bit_depths.len], bit_depths);
            return out;
        }

        pub fn initWithComponentLayouts(
            allocator: std.mem.Allocator,
            width: usize,
            height: usize,
            bit_depths: []const u8,
            component_widths: []const usize,
            component_heights: []const usize,
        ) !Self {
            if (bit_depths.len == 0 or bit_depths.len > max_components or
                component_widths.len != bit_depths.len or component_heights.len != bit_depths.len)
            {
                return ColorError.InvalidImage;
            }

            var common = bit_depths[0];
            const planes = try allocator.alloc([]Sample, bit_depths.len);
            errdefer allocator.free(planes);
            var allocated: usize = 0;
            errdefer for (planes[0..allocated]) |plane_slice| allocator.free(plane_slice);

            var stored_depths = [_]u8{0} ** max_components;
            var stored_widths = [_]usize{0} ** max_components;
            var stored_heights = [_]usize{0} ** max_components;
            while (allocated < bit_depths.len) : (allocated += 1) {
                const component_depth = bit_depths[allocated];
                const component_width = component_widths[allocated];
                const component_height = component_heights[allocated];
                if (component_depth == 0 or component_depth > 16 or
                    component_width == 0 or component_height == 0)
                {
                    return ColorError.InvalidImage;
                }
                if (component_depth != common) common = 0;
                const pixels = try std.math.mul(usize, component_width, component_height);
                planes[allocated] = try allocator.alloc(Sample, pixels);
                stored_depths[allocated] = component_depth;
                stored_widths[allocated] = component_width;
                stored_heights[allocated] = component_height;
            }

            return .{
                .allocator = allocator,
                .width = width,
                .height = height,
                .bit_depth = common,
                .component_bit_depths = stored_depths,
                .component_widths = stored_widths,
                .component_heights = stored_heights,
                .planes = planes,
            };
        }

        pub fn componentBitDepth(self: Self, component: usize) ?u8 {
            if (component >= self.planes.len) return null;
            const component_depth = self.component_bit_depths[component];
            return if (component_depth != 0) component_depth else self.bit_depth;
        }

        pub fn componentDimensions(self: Self, component: usize) ?[2]usize {
            if (component >= self.planes.len) return null;
            const component_width = self.component_widths[component];
            const component_height = self.component_heights[component];
            return .{
                if (component_width != 0) component_width else self.width,
                if (component_height != 0) component_height else self.height,
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

pub const SyccSampling = struct {
    image_origin_x: u32 = 0,
    image_origin_y: u32 = 0,
    chroma_x: u8 = 1,
    chroma_y: u8 = 1,
};

/// Converts unsigned native-size sYCC planes to interleaved sRGB samples.
/// Chroma may be full-resolution, 4:2:2, or 4:2:0. For an image origin not
/// aligned to the chroma grid, uncovered leading edge positions use zero-code
/// Cb/Cr with the same row/column phase as OpenJPEG's sYCC conversion. Native
/// planes remain unchanged; the edge rule exists only at this RGB boundary.
pub fn syccToSrgb(
    allocator: std.mem.Allocator,
    planes: SamplePlanes,
    sampling: SyccSampling,
) !image.RgbImage {
    if (planes.width == 0 or planes.height == 0 or planes.planes.len != 3) {
        return ColorError.InvalidImage;
    }
    const bit_depth = planes.componentBitDepth(0) orelse return ColorError.InvalidImage;
    if (bit_depth != 8 and bit_depth != 16) return ColorError.UnsupportedColorSpace;
    const pixels = try std.math.mul(usize, planes.width, planes.height);
    const luma_dimensions = planes.componentDimensions(0) orelse return ColorError.InvalidImage;
    if (luma_dimensions[0] != planes.width or luma_dimensions[1] != planes.height or
        planes.planes[0].len != pixels)
    {
        return ColorError.UnsupportedColorSpace;
    }
    if (!((sampling.chroma_x == 1 and sampling.chroma_y == 1) or
        (sampling.chroma_x == 2 and sampling.chroma_y == 1) or
        (sampling.chroma_x == 2 and sampling.chroma_y == 2)))
    {
        return ColorError.UnsupportedColorSpace;
    }
    const width_u32 = std.math.cast(u32, planes.width) orelse return ColorError.InvalidImage;
    const height_u32 = std.math.cast(u32, planes.height) orelse return ColorError.InvalidImage;
    const reference_x1 = std.math.add(u32, sampling.image_origin_x, width_u32) catch
        return ColorError.InvalidImage;
    const reference_y1 = std.math.add(u32, sampling.image_origin_y, height_u32) catch
        return ColorError.InvalidImage;
    const chroma_x0 = ceilDivU32Color(sampling.image_origin_x, sampling.chroma_x);
    const chroma_y0 = ceilDivU32Color(sampling.image_origin_y, sampling.chroma_y);
    const chroma_width = @as(usize, ceilDivU32Color(reference_x1, sampling.chroma_x) - chroma_x0);
    const chroma_height = @as(usize, ceilDivU32Color(reference_y1, sampling.chroma_y) - chroma_y0);
    const chroma_pixels = try std.math.mul(usize, chroma_width, chroma_height);
    for (1..3) |component| {
        const dimensions = planes.componentDimensions(component) orelse return ColorError.InvalidImage;
        if (planes.componentBitDepth(component) != bit_depth or
            dimensions[0] != chroma_width or dimensions[1] != chroma_height or
            planes.planes[component].len != chroma_pixels)
        {
            return ColorError.UnsupportedColorSpace;
        }
    }

    const max_sample: i32 = @intCast((@as(u32, 1) << @as(u5, @intCast(bit_depth))) - 1);
    const chroma_offset: i32 = @as(i32, 1) << @as(u5, @intCast(bit_depth - 1));
    const samples = try allocator.alloc(u16, try std.math.mul(usize, pixels, 3));
    errdefer allocator.free(samples);
    const edge_x = @as(usize, sampling.image_origin_x % sampling.chroma_x);
    const edge_y = @as(usize, sampling.image_origin_y % sampling.chroma_y);
    for (0..planes.height) |y| {
        for (0..planes.width) |x| {
            const luma_index = y * planes.width + x;
            const chroma_index = syccChromaIndex(
                x,
                y,
                edge_x,
                edge_y,
                sampling.chroma_x,
                sampling.chroma_y,
                chroma_width,
                chroma_height,
            );
            const cb_code = if (chroma_index) |index| planes.planes[1][index] else 0;
            const cr_code = if (chroma_index) |index| planes.planes[2][index] else 0;
            const rgb = try syccSampleToRgb(
                planes.planes[0][luma_index],
                cb_code,
                cr_code,
                max_sample,
                chroma_offset,
            );
            @memcpy(samples[luma_index * 3 ..][0..3], &rgb);
        }
    }
    return .{
        .allocator = allocator,
        .width = planes.width,
        .height = planes.height,
        .bit_depth = bit_depth,
        .samples = samples,
    };
}

/// Maps one full-resolution pixel to its sampled chroma plane. OpenJPEG's
/// established 4:2:0 edge phase uses zero chroma for a leading odd-origin row
/// and for the leading column of each first row in a two-row pair; the second
/// row reuses the first stored chroma sample at that column. In 4:2:2 every
/// leading odd-origin column position uses zero chroma.
fn syccChromaIndex(
    x: usize,
    y: usize,
    edge_x: usize,
    edge_y: usize,
    chroma_x: u8,
    chroma_y: u8,
    chroma_width: usize,
    chroma_height: usize,
) ?usize {
    if (y < edge_y) return null;
    const relative_y = y - edge_y;
    const source_y = relative_y / chroma_y;
    if (source_y >= chroma_height) return null;
    const source_x = if (x < edge_x) edge: {
        if (relative_y % chroma_y == 0) return null;
        break :edge 0;
    } else (x - edge_x) / chroma_x;
    if (source_x >= chroma_width) return null;
    return source_y * chroma_width + source_x;
}

/// Convenience entry point for full-resolution sYCC planes.
pub fn sycc444ToSrgb(allocator: std.mem.Allocator, planes: SamplePlanes) !image.RgbImage {
    return syccToSrgb(allocator, planes, .{});
}

fn syccSampleToRgb(y_code: u16, cb_code: u16, cr_code: u16, max_sample: i32, chroma_offset: i32) ![3]u16 {
    if (y_code > max_sample or cb_code > max_sample or cr_code > max_sample) {
        return ColorError.SampleOutOfRange;
    }
    const y: i32 = y_code;
    const cb = @as(i32, cb_code) - chroma_offset;
    const cr = @as(i32, cr_code) - chroma_offset;
    const red_delta: i32 = @intFromFloat(1.402 * @as(f32, @floatFromInt(cr)));
    const green_delta: i32 = @intFromFloat(0.344 * @as(f32, @floatFromInt(cb)) +
        0.714 * @as(f32, @floatFromInt(cr)));
    const blue_delta: i32 = @intFromFloat(1.772 * @as(f32, @floatFromInt(cb)));
    return .{
        @intCast(std.math.clamp(y + red_delta, 0, max_sample)),
        @intCast(std.math.clamp(y - green_delta, 0, max_sample)),
        @intCast(std.math.clamp(y + blue_delta, 0, max_sample)),
    };
}

fn ceilDivU32Color(value: u32, divisor: u8) u32 {
    return @intCast((@as(u64, value) + divisor - 1) / divisor);
}

/// Converts three full-resolution, equal-precision component planes to the
/// interleaved RGB carrier used by the TIFF boundary. This function performs
/// no colour-space conversion; callers must establish RGB semantics from the
/// container before using it.
pub fn interleaveRgb(allocator: std.mem.Allocator, planes: SamplePlanes) !image.RgbImage {
    if (planes.planes.len != 3 or planes.width == 0 or planes.height == 0) {
        return ColorError.InvalidImage;
    }
    const bit_depth = planes.componentBitDepth(0) orelse return ColorError.InvalidImage;
    if (bit_depth == 0 or bit_depth > 16) return ColorError.InvalidImage;
    const pixels = try std.math.mul(usize, planes.width, planes.height);
    for (0..3) |component| {
        const dimensions = planes.componentDimensions(component) orelse return ColorError.InvalidImage;
        if (planes.componentBitDepth(component) != bit_depth or
            dimensions[0] != planes.width or dimensions[1] != planes.height or
            planes.planes[component].len != pixels)
        {
            return ColorError.InvalidImage;
        }
    }

    const sample_count = try std.math.mul(usize, pixels, 3);
    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);
    const max_sample: u16 = @intCast((@as(u32, 1) << @as(u5, @intCast(bit_depth))) - 1);
    for (0..pixels) |pixel| {
        const red = planes.planes[0][pixel];
        const green = planes.planes[1][pixel];
        const blue = planes.planes[2][pixel];
        if (red > max_sample or green > max_sample or blue > max_sample) {
            return ColorError.SampleOutOfRange;
        }
        samples[pixel * 3] = red;
        samples[pixel * 3 + 1] = green;
        samples[pixel * 3 + 2] = blue;
    }
    return .{
        .allocator = allocator,
        .width = planes.width,
        .height = planes.height,
        .bit_depth = bit_depth,
        .samples = samples,
    };
}

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

/// JPEG2000 Part 1 MCT=1 on an RGBA layout: the reversible color transform
/// consumes components 0..2 while component 3 remains an independent alpha
/// plane with only the unsigned-sample DC level shift.
pub fn forwardRctAlpha(allocator: std.mem.Allocator, samples: SamplePlanes) !RctPlanes {
    const pixels = try validatePixelPlanes(u16, samples, 4);
    if (samples.width == 0 or samples.height == 0) return ColorError.InvalidImage;
    const level_shift = try dcLevelShift(samples.bit_depth);
    const max_sample = try maxSample(samples.bit_depth);

    var out = try RctPlanes.init(allocator, samples.width, samples.height, samples.bit_depth, 4);
    errdefer out.deinit();
    const r = samples.planes[0];
    const g = samples.planes[1];
    const b = samples.planes[2];
    const alpha = samples.planes[3];
    for (0..pixels) |pixel| {
        const r_value: i32 = r[pixel];
        const g_value: i32 = g[pixel];
        const b_value: i32 = b[pixel];
        const alpha_value: i32 = alpha[pixel];
        if (r_value > max_sample or g_value > max_sample or
            b_value > max_sample or alpha_value > max_sample)
        {
            return ColorError.SampleOutOfRange;
        }
        out.planes[0][pixel] = floorQuarter(r_value + 2 * g_value + b_value) - level_shift;
        out.planes[1][pixel] = b_value - g_value;
        out.planes[2][pixel] = r_value - g_value;
        out.planes[3][pixel] = alpha_value - level_shift;
    }
    return out;
}

pub fn inverseRctAlpha(allocator: std.mem.Allocator, planes: RctPlanes) !SamplePlanes {
    const pixels = try validatePixelPlanes(i32, planes, 4);
    const level_shift = try dcLevelShift(planes.bit_depth);
    const max_sample = try maxSample(planes.bit_depth);

    var out = try SamplePlanes.init(allocator, planes.width, planes.height, planes.bit_depth, 4);
    errdefer out.deinit();
    for (0..pixels) |pixel| {
        const y = planes.planes[0][pixel] + level_shift;
        const cb = planes.planes[1][pixel];
        const cr = planes.planes[2][pixel];
        const g = y - floorQuarter(cb + cr);
        const r = cr + g;
        const b = cb + g;
        const alpha = planes.planes[3][pixel] + level_shift;
        if (r < 0 or g < 0 or b < 0 or alpha < 0 or
            r > max_sample or g > max_sample or b > max_sample or alpha > max_sample)
        {
            return ColorError.SampleOutOfRange;
        }
        out.planes[0][pixel] = @intCast(r);
        out.planes[1][pixel] = @intCast(g);
        out.planes[2][pixel] = @intCast(b);
        out.planes[3][pixel] = @intCast(alpha);
    }
    return out;
}

pub fn inverseRctPlanar(allocator: std.mem.Allocator, planes: RctPlanes) !SamplePlanes {
    return inverseRctPlanarImpl(allocator, planes, false);
}

pub fn inverseRctPlanarSaturated(allocator: std.mem.Allocator, planes: RctPlanes) !SamplePlanes {
    return inverseRctPlanarImpl(allocator, planes, true);
}

fn inverseRctPlanarImpl(
    allocator: std.mem.Allocator,
    planes: RctPlanes,
    saturate: bool,
) !SamplePlanes {
    const pixels = try validatePixelPlanes(i32, planes, 3);
    const level_shift = try dcLevelShift(planes.bit_depth);
    const max_sample = try maxSample(planes.bit_depth);

    var out = try SamplePlanes.init(allocator, planes.width, planes.height, planes.bit_depth, 3);
    errdefer out.deinit();
    for (0..pixels) |pixel| {
        const y = planes.planes[0][pixel] + level_shift;
        const cb = planes.planes[1][pixel];
        const cr = planes.planes[2][pixel];
        const g = y - floorQuarter(cb + cr);
        const r = cr + g;
        const b = cb + g;
        if (!saturate and
            (r < 0 or g < 0 or b < 0 or
                r > max_sample or g > max_sample or b > max_sample))
        {
            return ColorError.SampleOutOfRange;
        }
        out.planes[0][pixel] = @intCast(std.math.clamp(r, 0, max_sample));
        out.planes[1][pixel] = @intCast(std.math.clamp(g, 0, max_sample));
        out.planes[2][pixel] = @intCast(std.math.clamp(b, 0, max_sample));
    }
    return out;
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

fn inverseRctSaturatedRange(samples: []u16, planes: RctPlanes, begin: usize, end: usize, max_sample: i32, level_shift: i32) void {
    const y_plane = planes.planes[0];
    const cb_plane = planes.planes[1];
    const cr_plane = planes.planes[2];
    for (begin..end) |pixel| {
        const g = y_plane[pixel] + level_shift - floorQuarter(cb_plane[pixel] + cr_plane[pixel]);
        const r = cr_plane[pixel] + g;
        const b = cb_plane[pixel] + g;
        samples[pixel * 3] = @intCast(std.math.clamp(r, 0, max_sample));
        samples[pixel * 3 + 1] = @intCast(std.math.clamp(g, 0, max_sample));
        samples[pixel * 3 + 2] = @intCast(std.math.clamp(b, 0, max_sample));
    }
}

const SaturatedRctInverseJob = struct {
    samples: []u16,
    planes: RctPlanes,
    begin: usize,
    end: usize,
    max_sample: i32,
    level_shift: i32,
};

fn saturatedRctInverseWorker(job: *SaturatedRctInverseJob) void {
    inverseRctSaturatedRange(job.samples, job.planes, job.begin, job.end, job.max_sample, job.level_shift);
}

/// Reduced-resolution RCT output may overshoot the unsigned component range
/// because omitted detail bands no longer cancel exactly. Apply the inverse
/// transform first, then saturate reconstructed RGB samples.
pub fn inverseRctSaturatedThreaded(
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
    const band_count = colorBands(pixels, 1, inverseColorThreadCount(pixels, requested_threads), &ranges);
    var jobs: [max_inverse_color_workers]SaturatedRctInverseJob = undefined;
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
    runColorJobs(SaturatedRctInverseJob, jobs[0..band_count], saturatedRctInverseWorker);

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

/// MCT=0 irreversible front end: convert each unsigned RGB component to the
/// floating-point, DC-level-shifted domain without inter-component mixing.
pub fn forwardNoTransformFloat(allocator: std.mem.Allocator, rgb: image.RgbImage) !IctPlanes {
    if (rgb.width == 0 or rgb.height == 0) return ColorError.InvalidImage;
    const pixels = try std.math.mul(usize, rgb.width, rgb.height);
    const sample_count = try std.math.mul(usize, pixels, 3);
    if (rgb.samples.len != sample_count) return ColorError.InvalidImage;
    const shift: f32 = @floatFromInt(try dcLevelShift(rgb.bit_depth));

    var out = try IctPlanes.init(allocator, rgb.width, rgb.height, rgb.bit_depth, 3);
    errdefer out.deinit();
    for (0..pixels) |pixel| {
        out.planes[0][pixel] = @as(f32, @floatFromInt(rgb.samples[pixel * 3])) - shift;
        out.planes[1][pixel] = @as(f32, @floatFromInt(rgb.samples[pixel * 3 + 1])) - shift;
        out.planes[2][pixel] = @as(f32, @floatFromInt(rgb.samples[pixel * 3 + 2])) - shift;
    }
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

fn inverseNoTransformFloatRange(samples: []u16, planes: IctPlanes, begin: usize, end: usize, shift: f32, max_sample: i32) void {
    for (begin..end) |pixel| {
        samples[pixel * 3] = clampToSample(planes.planes[0][pixel] + shift, max_sample);
        samples[pixel * 3 + 1] = clampToSample(planes.planes[1][pixel] + shift, max_sample);
        samples[pixel * 3 + 2] = clampToSample(planes.planes[2][pixel] + shift, max_sample);
    }
}

const NoTransformFloatInverseJob = struct {
    samples: []u16,
    planes: IctPlanes,
    begin: usize,
    end: usize,
    shift: f32,
    max_sample: i32,
};

fn noTransformFloatInverseWorker(job: *NoTransformFloatInverseJob) void {
    inverseNoTransformFloatRange(job.samples, job.planes, job.begin, job.end, job.shift, job.max_sample);
}

/// MCT=0 irreversible back end. The reconstruction rule is the same checked
/// nearest-integer rounding and precision saturation used by inverse ICT.
pub fn inverseNoTransformFloatThreaded(
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
    const band_count = colorBands(pixels, 1, inverseColorThreadCount(pixels, requested_threads), &ranges);
    var jobs: [max_inverse_color_workers]NoTransformFloatInverseJob = undefined;
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
    runColorJobs(NoTransformFloatInverseJob, jobs[0..band_count], noTransformFloatInverseWorker);

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
