const std = @import("std");

pub const max_precision: u8 = 38;

pub const NativeSampleError = error{
    InvalidCodestream,
    InvalidLayout,
    ResourceLimitExceeded,
    SampleOutOfRange,
    UnsupportedPgxPrecision,
};

pub const Limits = struct {
    max_components: usize = 256,
    max_reference_pixels: u64 = 1 << 32,
    max_total_component_samples: u64 = 1 << 32,
};

pub const ComponentLayout = struct {
    precision: u8,
    signed: bool,
    x0: u32,
    y0: u32,
    x_step: u8,
    y_step: u8,
    width: usize,
    height: usize,

    pub fn sampleCount(self: ComponentLayout) !usize {
        return std.math.mul(usize, self.width, self.height) catch
            NativeSampleError.ResourceLimitExceeded;
    }

    pub fn minimumSample(self: ComponentLayout) !i64 {
        try validateComponentLayout(self);
        if (!self.signed) return 0;
        return -(@as(i64, 1) << @as(u6, @intCast(self.precision - 1)));
    }

    pub fn maximumSample(self: ComponentLayout) !i64 {
        try validateComponentLayout(self);
        const magnitude_bits = if (self.signed) self.precision - 1 else self.precision;
        return (@as(i64, 1) << @as(u6, @intCast(magnitude_bits))) - 1;
    }
};

pub const CodestreamLayout = struct {
    allocator: std.mem.Allocator,
    capabilities: u16,
    reference_x0: u32,
    reference_y0: u32,
    reference_x1: u32,
    reference_y1: u32,
    tile_width: u32,
    tile_height: u32,
    tile_origin_x: u32,
    tile_origin_y: u32,
    components: []ComponentLayout,

    pub fn referenceWidth(self: CodestreamLayout) usize {
        return self.reference_x1 - self.reference_x0;
    }

    pub fn referenceHeight(self: CodestreamLayout) usize {
        return self.reference_y1 - self.reference_y0;
    }

    pub fn deinit(self: *CodestreamLayout) void {
        self.allocator.free(self.components);
        self.* = undefined;
    }
};

pub const ComponentPlane = struct {
    layout: ComponentLayout,
    samples: []i64,
};

pub const SamplePlanes = struct {
    allocator: std.mem.Allocator,
    reference_x0: u32,
    reference_y0: u32,
    reference_x1: u32,
    reference_y1: u32,
    planes: []ComponentPlane,

    pub fn initFromLayout(
        allocator: std.mem.Allocator,
        layout: CodestreamLayout,
        limits: Limits,
    ) !SamplePlanes {
        if (layout.components.len == 0 or layout.components.len > limits.max_components) {
            return NativeSampleError.ResourceLimitExceeded;
        }
        if (layout.reference_x1 <= layout.reference_x0 or layout.reference_y1 <= layout.reference_y0) {
            return NativeSampleError.InvalidLayout;
        }
        const reference_pixels = std.math.mul(
            u64,
            layout.reference_x1 - layout.reference_x0,
            layout.reference_y1 - layout.reference_y0,
        ) catch return NativeSampleError.ResourceLimitExceeded;
        if (reference_pixels > limits.max_reference_pixels) {
            return NativeSampleError.ResourceLimitExceeded;
        }
        var total_samples: u64 = 0;
        for (layout.components) |component| {
            try validateComponentLayout(component);
            const sample_count = try component.sampleCount();
            total_samples = std.math.add(u64, total_samples, sample_count) catch
                return NativeSampleError.ResourceLimitExceeded;
            if (total_samples > limits.max_total_component_samples) {
                return NativeSampleError.ResourceLimitExceeded;
            }
        }
        const planes = try allocator.alloc(ComponentPlane, layout.components.len);
        errdefer allocator.free(planes);
        var initialized: usize = 0;
        errdefer for (planes[0..initialized]) |plane| allocator.free(plane.samples);
        while (initialized < layout.components.len) : (initialized += 1) {
            const component = layout.components[initialized];
            const samples = try allocator.alloc(i64, try component.sampleCount());
            @memset(samples, 0);
            planes[initialized] = .{ .layout = component, .samples = samples };
        }
        return .{
            .allocator = allocator,
            .reference_x0 = layout.reference_x0,
            .reference_y0 = layout.reference_y0,
            .reference_x1 = layout.reference_x1,
            .reference_y1 = layout.reference_y1,
            .planes = planes,
        };
    }

    pub fn componentCount(self: SamplePlanes) usize {
        return self.planes.len;
    }

    pub fn validateSamples(self: SamplePlanes) !void {
        for (self.planes) |plane| {
            try validateComponentLayout(plane.layout);
            if (plane.samples.len != try plane.layout.sampleCount()) {
                return NativeSampleError.InvalidLayout;
            }
            const minimum = try plane.layout.minimumSample();
            const maximum = try plane.layout.maximumSample();
            for (plane.samples) |sample| {
                if (sample < minimum or sample > maximum) {
                    return NativeSampleError.SampleOutOfRange;
                }
            }
        }
    }

    pub fn encodePgx(
        self: SamplePlanes,
        allocator: std.mem.Allocator,
        component: usize,
        byte_order: PgxByteOrder,
    ) ![]u8 {
        if (component >= self.planes.len) return NativeSampleError.InvalidLayout;
        const plane = self.planes[component];
        try validateComponentLayout(plane.layout);
        if (plane.layout.precision > 32) return NativeSampleError.UnsupportedPgxPrecision;
        if (plane.samples.len != try plane.layout.sampleCount()) {
            return NativeSampleError.InvalidLayout;
        }
        const minimum = try plane.layout.minimumSample();
        const maximum = try plane.layout.maximumSample();
        const header = try std.fmt.allocPrint(
            allocator,
            "PG {s} {s}{d} {d} {d}\n",
            .{
                if (byte_order == .most_significant_first) "ML" else "LM",
                if (plane.layout.signed) "-" else "+",
                plane.layout.precision,
                plane.layout.width,
                plane.layout.height,
            },
        );
        defer allocator.free(header);

        const bytes_per_sample: usize = if (plane.layout.precision <= 8)
            1
        else if (plane.layout.precision <= 16)
            2
        else
            4;
        const payload_bytes = std.math.mul(usize, plane.samples.len, bytes_per_sample) catch
            return NativeSampleError.ResourceLimitExceeded;
        var out = try std.ArrayList(u8).initCapacity(allocator, header.len + payload_bytes);
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, header);
        for (plane.samples) |sample| {
            if (sample < minimum or sample > maximum) {
                return NativeSampleError.SampleOutOfRange;
            }
            const raw: u64 = @bitCast(sample);
            if (byte_order == .most_significant_first) {
                var byte_index = bytes_per_sample;
                while (byte_index > 0) {
                    byte_index -= 1;
                    try out.append(allocator, @truncate(raw >> @as(u6, @intCast(byte_index * 8))));
                }
            } else {
                for (0..bytes_per_sample) |byte_index| {
                    try out.append(allocator, @truncate(raw >> @as(u6, @intCast(byte_index * 8))));
                }
            }
        }
        return out.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *SamplePlanes) void {
        for (self.planes) |plane| self.allocator.free(plane.samples);
        self.allocator.free(self.planes);
        self.* = undefined;
    }
};

pub const PgxByteOrder = enum {
    most_significant_first,
    least_significant_first,
};

pub fn inspectCodestreamLayout(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    limits: Limits,
) !CodestreamLayout {
    if (bytes.len < 8 or readU16Be(bytes, 0) != 0xff4f or readU16Be(bytes, 2) != 0xff51) {
        return NativeSampleError.InvalidCodestream;
    }
    const lsiz = readU16Be(bytes, 4);
    if (lsiz < 41 or bytes.len - 4 < lsiz) return NativeSampleError.InvalidCodestream;
    const segment = bytes[6..][0 .. lsiz - 2];
    if (segment.len < 39) return NativeSampleError.InvalidCodestream;

    const capabilities = readU16Be(segment, 0);
    const xsiz = readU32Be(segment, 2);
    const ysiz = readU32Be(segment, 6);
    const xosiz = readU32Be(segment, 10);
    const yosiz = readU32Be(segment, 14);
    const xtsiz = readU32Be(segment, 18);
    const ytsiz = readU32Be(segment, 22);
    const xtosiz = readU32Be(segment, 26);
    const ytosiz = readU32Be(segment, 30);
    const component_count = readU16Be(segment, 34);
    if (component_count == 0 or component_count > limits.max_components) {
        return NativeSampleError.ResourceLimitExceeded;
    }
    if (segment.len != 36 + @as(usize, component_count) * 3 or
        xsiz <= xosiz or ysiz <= yosiz or xtsiz == 0 or ytsiz == 0)
    {
        return NativeSampleError.InvalidCodestream;
    }
    const reference_pixels = std.math.mul(u64, xsiz - xosiz, ysiz - yosiz) catch
        return NativeSampleError.ResourceLimitExceeded;
    if (reference_pixels > limits.max_reference_pixels) {
        return NativeSampleError.ResourceLimitExceeded;
    }

    const components = try allocator.alloc(ComponentLayout, component_count);
    errdefer allocator.free(components);
    var total_samples: u64 = 0;
    for (components, 0..) |*component, index| {
        const offset = 36 + index * 3;
        const ssiz = segment[offset];
        const precision = (ssiz & 0x7f) + 1;
        if (precision > max_precision) return NativeSampleError.InvalidLayout;
        const x_step = segment[offset + 1];
        const y_step = segment[offset + 2];
        if (x_step == 0 or y_step == 0) return NativeSampleError.InvalidLayout;
        const component_x0 = ceilDivU32(xosiz, x_step);
        const component_y0 = ceilDivU32(yosiz, y_step);
        const component_x1 = ceilDivU32(xsiz, x_step);
        const component_y1 = ceilDivU32(ysiz, y_step);
        if (component_x1 <= component_x0 or component_y1 <= component_y0) {
            return NativeSampleError.InvalidLayout;
        }
        const width: usize = component_x1 - component_x0;
        const height: usize = component_y1 - component_y0;
        const sample_count = std.math.mul(u64, width, height) catch
            return NativeSampleError.ResourceLimitExceeded;
        total_samples = std.math.add(u64, total_samples, sample_count) catch
            return NativeSampleError.ResourceLimitExceeded;
        if (total_samples > limits.max_total_component_samples) {
            return NativeSampleError.ResourceLimitExceeded;
        }
        component.* = .{
            .precision = precision,
            .signed = (ssiz & 0x80) != 0,
            .x0 = component_x0,
            .y0 = component_y0,
            .x_step = x_step,
            .y_step = y_step,
            .width = width,
            .height = height,
        };
    }
    return .{
        .allocator = allocator,
        .capabilities = capabilities,
        .reference_x0 = xosiz,
        .reference_y0 = yosiz,
        .reference_x1 = xsiz,
        .reference_y1 = ysiz,
        .tile_width = xtsiz,
        .tile_height = ytsiz,
        .tile_origin_x = xtosiz,
        .tile_origin_y = ytosiz,
        .components = components,
    };
}

fn validateComponentLayout(component: ComponentLayout) !void {
    if (component.precision == 0 or component.precision > max_precision or
        component.x_step == 0 or component.y_step == 0 or
        component.width == 0 or component.height == 0)
    {
        return NativeSampleError.InvalidLayout;
    }
}

fn ceilDivU32(value: u32, divisor: u8) u32 {
    return value / divisor + @intFromBool(value % divisor != 0);
}

fn readU16Be(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readU32Be(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}
