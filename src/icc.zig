const std = @import("std");
const image = @import("image.zig");

pub const IccError = error{
    InvalidImage,
    InvalidProfile,
    SampleOutOfRange,
    UnsupportedProfile,
};

const tag_table_offset = 128;
const tag_record_offset = 132;
const tag_record_bytes = 12;

const Xyz = [3]f64;
const Matrix = [3][3]f64;

const ParametricCurve = struct {
    function_type: u16,
    parameters: [7]f64 = [_]f64{0} ** 7,
};

const Curve = union(enum) {
    identity,
    gamma: f64,
    table: []const u8,
    parametric: ParametricCurve,

    fn evaluate(self: Curve, input: f64) f64 {
        const x = std.math.clamp(input, 0.0, 1.0);
        const output = switch (self) {
            .identity => x,
            .gamma => |gamma| std.math.pow(f64, x, gamma),
            .table => |bytes| evaluateTable(bytes, x),
            .parametric => |curve| evaluateParametric(curve, x),
        };
        return std.math.clamp(output, 0.0, 1.0);
    }
};

const MatrixTrcProfile = struct {
    matrix: Matrix,
    curves: [3]Curve,
};

const Tag = struct {
    data: []const u8,
};

/// Converts an unsigned 8/16-bit interleaved RGB image from a bounded ICC
/// matrix/TRC source profile to sRGB. The input pixels and profile remain
/// untouched; the returned image owns a new raster and carries no ICC payload
/// because its sample interpretation is the enumerated sRGB colour space.
///
/// The accepted source profile is deliberately narrow: ICC v2/v4 RGB input,
/// display, or colour-space profiles with a PCSXYZ matrix and three curveType
/// or parametricCurveType TRCs. LUT profiles and non-RGB/PCSXYZ profiles fail
/// closed.
pub fn convertRgbToSrgb(
    allocator: std.mem.Allocator,
    input: image.RgbImage,
    profile_bytes: []const u8,
) !image.RgbImage {
    if (input.width == 0 or input.height == 0 or
        (input.bit_depth != 8 and input.bit_depth != 16))
    {
        return IccError.InvalidImage;
    }
    const pixels = std.math.mul(usize, input.width, input.height) catch
        return IccError.InvalidImage;
    const sample_count = std.math.mul(usize, pixels, 3) catch
        return IccError.InvalidImage;
    if (input.samples.len != sample_count) return IccError.InvalidImage;

    const profile = try parseMatrixTrcProfile(profile_bytes);
    const srgb_inverse = invertMatrix(srgb_matrix).?;
    const max_sample: u16 = if (input.bit_depth == 8) 255 else 65535;
    const scale = @as(f64, @floatFromInt(max_sample));
    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);

    for (0..pixels) |pixel| {
        var linear_source: Xyz = undefined;
        for (0..3) |channel| {
            const sample = input.samples[pixel * 3 + channel];
            if (sample > max_sample) return IccError.SampleOutOfRange;
            linear_source[channel] = profile.curves[channel].evaluate(
                @as(f64, @floatFromInt(sample)) / scale,
            );
        }
        const pcs_xyz = multiplyMatrixVector(profile.matrix, linear_source);
        const linear_srgb = multiplyMatrixVector(srgb_inverse, pcs_xyz);
        for (0..3) |channel| {
            const encoded = encodeSrgb(std.math.clamp(linear_srgb[channel], 0.0, 1.0));
            samples[pixel * 3 + channel] = @intFromFloat(@round(
                std.math.clamp(encoded, 0.0, 1.0) * scale,
            ));
        }
    }

    return .{
        .allocator = allocator,
        .width = input.width,
        .height = input.height,
        .bit_depth = input.bit_depth,
        .samples = samples,
        .icc_profile = null,
    };
}

fn parseMatrixTrcProfile(bytes: []const u8) !MatrixTrcProfile {
    if (bytes.len < tag_record_offset) return IccError.InvalidProfile;
    const declared_size = try readU32(bytes, 0);
    if (declared_size != bytes.len) return IccError.InvalidProfile;
    const version_major = bytes[8];
    if (version_major != 2 and version_major != 4) return IccError.UnsupportedProfile;
    const profile_class = bytes[12..16];
    if (!std.mem.eql(u8, profile_class, "scnr") and
        !std.mem.eql(u8, profile_class, "mntr") and
        !std.mem.eql(u8, profile_class, "spac"))
    {
        return IccError.UnsupportedProfile;
    }
    if (!std.mem.eql(u8, bytes[16..20], "RGB ") or
        !std.mem.eql(u8, bytes[20..24], "XYZ "))
    {
        return IccError.UnsupportedProfile;
    }
    if (!std.mem.eql(u8, bytes[36..40], "acsp")) return IccError.InvalidProfile;
    if (try readU32(bytes, 64) > 3) return IccError.InvalidProfile;

    const tag_count = try readU32(bytes, tag_table_offset);
    const table_bytes = std.math.mul(usize, tag_count, tag_record_bytes) catch
        return IccError.InvalidProfile;
    const table_end = std.math.add(usize, tag_record_offset, table_bytes) catch
        return IccError.InvalidProfile;
    if (table_end > bytes.len) return IccError.InvalidProfile;

    var required: [6]?Tag = [_]?Tag{null} ** 6;
    const signatures = [_]u32{
        fourcc("rXYZ"), fourcc("gXYZ"), fourcc("bXYZ"),
        fourcc("rTRC"), fourcc("gTRC"), fourcc("bTRC"),
    };
    for (0..tag_count) |index| {
        const record = tag_record_offset + index * tag_record_bytes;
        const signature = try readU32(bytes, record);
        const offset = try readU32(bytes, record + 4);
        const size = try readU32(bytes, record + 8);
        if (offset % 4 != 0 or offset < table_end or size < 8) {
            return IccError.InvalidProfile;
        }
        const end = std.math.add(usize, offset, size) catch
            return IccError.InvalidProfile;
        if (end > bytes.len) return IccError.InvalidProfile;
        for (signatures, 0..) |wanted, wanted_index| {
            if (signature != wanted) continue;
            if (required[wanted_index] != null) return IccError.InvalidProfile;
            required[wanted_index] = .{
                .data = bytes[offset..end],
            };
        }
    }
    for (required) |tag| if (tag == null) return IccError.UnsupportedProfile;

    const red = try parseXyz(required[0].?.data);
    const green = try parseXyz(required[1].?.data);
    const blue = try parseXyz(required[2].?.data);
    const matrix: Matrix = .{
        .{ red[0], green[0], blue[0] },
        .{ red[1], green[1], blue[1] },
        .{ red[2], green[2], blue[2] },
    };
    if (invertMatrix(matrix) == null) return IccError.InvalidProfile;

    const curves = [3]Curve{
        try parseCurve(required[3].?.data),
        try parseCurve(required[4].?.data),
        try parseCurve(required[5].?.data),
    };
    for (curves) |curve| try validateCurve(curve);
    return .{ .matrix = matrix, .curves = curves };
}

fn parseXyz(bytes: []const u8) !Xyz {
    if (bytes.len != 20 or !std.mem.eql(u8, bytes[0..4], "XYZ ") or
        !allZero(bytes[4..8]))
    {
        return IccError.InvalidProfile;
    }
    return .{
        try readS15Fixed16(bytes, 8),
        try readS15Fixed16(bytes, 12),
        try readS15Fixed16(bytes, 16),
    };
}

fn parseCurve(bytes: []const u8) !Curve {
    if (bytes.len < 12 or !allZero(bytes[4..8])) return IccError.InvalidProfile;
    if (std.mem.eql(u8, bytes[0..4], "curv")) {
        const count = try readU32(bytes, 8);
        const value_bytes = std.math.mul(usize, count, 2) catch
            return IccError.InvalidProfile;
        const expected = std.math.add(usize, 12, value_bytes) catch
            return IccError.InvalidProfile;
        if (bytes.len != expected) return IccError.InvalidProfile;
        return switch (count) {
            0 => .identity,
            1 => .{ .gamma = @as(f64, @floatFromInt(try readU16(bytes, 12))) / 256.0 },
            else => .{ .table = bytes[12..] },
        };
    }
    if (!std.mem.eql(u8, bytes[0..4], "para")) return IccError.UnsupportedProfile;
    const function_type = try readU16(bytes, 8);
    if (try readU16(bytes, 10) != 0 or function_type > 4) return IccError.InvalidProfile;
    const parameter_counts = [_]usize{ 1, 3, 4, 5, 7 };
    const parameter_count = parameter_counts[function_type];
    if (bytes.len != 12 + parameter_count * 4) return IccError.InvalidProfile;
    var curve = ParametricCurve{ .function_type = function_type };
    for (0..parameter_count) |index| {
        curve.parameters[index] = try readS15Fixed16(bytes, 12 + index * 4);
    }
    return .{ .parametric = curve };
}

fn validateCurve(curve: Curve) !void {
    var previous = curve.evaluate(0.0);
    if (!std.math.isFinite(previous) or @abs(previous) > 0.001) {
        return IccError.UnsupportedProfile;
    }
    for (1..257) |index| {
        const current = curve.evaluate(@as(f64, @floatFromInt(index)) / 256.0);
        if (!std.math.isFinite(current) or current + 0.000001 < previous or
            current < -0.001 or current > 1.001)
        {
            return IccError.UnsupportedProfile;
        }
        previous = current;
    }
    if (@abs(previous - 1.0) > 0.001) return IccError.UnsupportedProfile;
}

fn evaluateTable(bytes: []const u8, input: f64) f64 {
    const count = bytes.len / 2;
    const position = input * @as(f64, @floatFromInt(count - 1));
    const low: usize = @intFromFloat(@floor(position));
    if (low + 1 >= count) return @as(f64, @floatFromInt(readU16Unchecked(bytes, low * 2))) / 65535.0;
    const fraction = position - @as(f64, @floatFromInt(low));
    const a = @as(f64, @floatFromInt(readU16Unchecked(bytes, low * 2))) / 65535.0;
    const b = @as(f64, @floatFromInt(readU16Unchecked(bytes, (low + 1) * 2))) / 65535.0;
    return a + (b - a) * fraction;
}

fn evaluateParametric(curve: ParametricCurve, x: f64) f64 {
    const p = curve.parameters;
    return switch (curve.function_type) {
        0 => std.math.pow(f64, x, p[0]),
        1 => if (x >= -p[2] / p[1]) std.math.pow(f64, p[1] * x + p[2], p[0]) else 0.0,
        2 => if (x >= -p[2] / p[1]) std.math.pow(f64, p[1] * x + p[2], p[0]) + p[3] else p[3],
        3 => if (x >= p[4]) std.math.pow(f64, p[1] * x + p[2], p[0]) else p[3] * x,
        4 => if (x >= p[4]) std.math.pow(f64, p[1] * x + p[2], p[0]) + p[5] else p[3] * x + p[6],
        else => unreachable,
    };
}

// Exact s15Fixed16 columns from the CC0 sRGB-v4 reference fixture. They are
// the D50-adapted PCSXYZ matrix inverted by an ICC relative-colorimetric path.
const srgb_matrix: Matrix = .{
    .{ 0.43603515625, 0.385101318359375, 0.14306640625 },
    .{ 0.222442626953125, 0.7169342041015625, 0.0606231689453125 },
    .{ 0.0139007568359375, 0.097076416015625, 0.71392822265625 },
};

fn encodeSrgb(linear: f64) f64 {
    // Inverse of the same profile's type-3 parametric TRC.
    const gamma = 2.4000396728515625;
    const a = 0.9478607177734375;
    const b = 0.0521392822265625;
    const c = 0.077392578125;
    const d = 0.0404510498046875;
    const split = c * d;
    return if (linear < split)
        linear / c
    else
        (std.math.pow(f64, linear, 1.0 / gamma) - b) / a;
}

fn multiplyMatrixVector(matrix: Matrix, vector: Xyz) Xyz {
    return .{
        matrix[0][0] * vector[0] + matrix[0][1] * vector[1] + matrix[0][2] * vector[2],
        matrix[1][0] * vector[0] + matrix[1][1] * vector[1] + matrix[1][2] * vector[2],
        matrix[2][0] * vector[0] + matrix[2][1] * vector[1] + matrix[2][2] * vector[2],
    };
}

fn invertMatrix(matrix: Matrix) ?Matrix {
    const determinant =
        matrix[0][0] * (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) -
        matrix[0][1] * (matrix[1][0] * matrix[2][2] - matrix[1][2] * matrix[2][0]) +
        matrix[0][2] * (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]);
    if (!std.math.isFinite(determinant) or @abs(determinant) < 0.000000000001) return null;
    const inverse = 1.0 / determinant;
    return .{
        .{
            (matrix[1][1] * matrix[2][2] - matrix[1][2] * matrix[2][1]) * inverse,
            (matrix[0][2] * matrix[2][1] - matrix[0][1] * matrix[2][2]) * inverse,
            (matrix[0][1] * matrix[1][2] - matrix[0][2] * matrix[1][1]) * inverse,
        },
        .{
            (matrix[1][2] * matrix[2][0] - matrix[1][0] * matrix[2][2]) * inverse,
            (matrix[0][0] * matrix[2][2] - matrix[0][2] * matrix[2][0]) * inverse,
            (matrix[0][2] * matrix[1][0] - matrix[0][0] * matrix[1][2]) * inverse,
        },
        .{
            (matrix[1][0] * matrix[2][1] - matrix[1][1] * matrix[2][0]) * inverse,
            (matrix[0][1] * matrix[2][0] - matrix[0][0] * matrix[2][1]) * inverse,
            (matrix[0][0] * matrix[1][1] - matrix[0][1] * matrix[1][0]) * inverse,
        },
    };
}

fn readU16(bytes: []const u8, offset: usize) !u16 {
    if (offset > bytes.len or bytes.len - offset < 2) return IccError.InvalidProfile;
    return readU16Unchecked(bytes, offset);
}

fn readU16Unchecked(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readU32(bytes: []const u8, offset: usize) !u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return IccError.InvalidProfile;
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}

fn readS15Fixed16(bytes: []const u8, offset: usize) !f64 {
    const raw = try readU32(bytes, offset);
    const signed: i32 = @bitCast(raw);
    return @as(f64, @floatFromInt(signed)) / 65536.0;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn fourcc(comptime text: *const [4:0]u8) u32 {
    return (@as(u32, text[0]) << 24) |
        (@as(u32, text[1]) << 16) |
        (@as(u32, text[2]) << 8) |
        text[3];
}
