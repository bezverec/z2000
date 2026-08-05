const std = @import("std");
const builtin = @import("builtin");
const color = @import("color.zig");
const image = @import("image.zig");
const simd = @import("simd.zig");

pub const TiffError = error{
    InvalidHeader,
    InvalidIfd,
    InvalidTagValue,
    MissingRequiredTag,
    UnsupportedCompression,
    UnsupportedPhotometric,
    UnsupportedBitsPerSample,
    UnsupportedPlanarConfiguration,
    UnsupportedSampleFormat,
    UnsupportedExtraSamples,
    TruncatedData,
    ImageTooLarge,
};

const max_file_size = 1024 * 1024 * 1024;
const max_pixels = 268_435_456;
const max_icc_profile_bytes = 16 * 1024 * 1024;
const sample_lanes = simd.i32_lanes;
const SampleU8Vector = @Vector(sample_lanes, u8);
const SampleU16Vector = @Vector(sample_lanes, u16);

const Endian = enum {
    little,
    big,
};

const IfdEntry = struct {
    tag: u16,
    field_type: u16,
    count: u32,
    value_or_offset: u32,
};

pub const AlphaColorSpace = enum {
    grayscale,
    rgb,

    pub fn colorComponentCount(self: AlphaColorSpace) usize {
        return switch (self) {
            .grayscale => 1,
            .rgb => 3,
        };
    }
};

/// Bounded TIFF alpha layout: chunky gray+alpha or RGBA with one final
/// associated/unassociated alpha sample. The samples remain interleaved so a
/// TIFF read/write roundtrip does not change their numeric representation.
pub const AlphaImage = struct {
    allocator: std.mem.Allocator,
    width: usize,
    height: usize,
    bit_depth: u8,
    color_space: AlphaColorSpace,
    alpha_mode: color.AlphaMode,
    samples: []u16,
    white_is_zero: bool = false,
    icc_profile: ?[]u8 = null,
    metadata: image.Metadata = .{},

    pub fn componentCount(self: AlphaImage) usize {
        return self.color_space.colorComponentCount() + 1;
    }

    pub fn deinit(self: *AlphaImage) void {
        if (self.icc_profile) |profile| self.allocator.free(profile);
        self.metadata.deinit(self.allocator);
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    /// Converts chunky TIFF samples into the planar no-MCT codec boundary.
    /// WhiteIsZero normalization affects only the grayscale color plane.
    pub fn toSamplePlanes(self: AlphaImage, allocator: std.mem.Allocator) !color.SamplePlanes {
        if (self.width == 0 or self.height == 0 or
            (self.bit_depth != 8 and self.bit_depth != 16) or
            (self.color_space == .rgb and self.white_is_zero))
        {
            return TiffError.InvalidTagValue;
        }
        const pixels = try std.math.mul(usize, self.width, self.height);
        const components = self.componentCount();
        if (self.samples.len != try std.math.mul(usize, pixels, components)) {
            return TiffError.InvalidTagValue;
        }
        var planes = try color.SamplePlanes.init(
            allocator,
            self.width,
            self.height,
            self.bit_depth,
            components,
        );
        errdefer planes.deinit();
        const max_sample: u16 = if (self.bit_depth == 8) 255 else std.math.maxInt(u16);
        for (0..pixels) |pixel| {
            for (0..components) |component| {
                const sample = self.samples[pixel * components + component];
                if (sample > max_sample) return TiffError.InvalidTagValue;
                planes.planes[component][pixel] = if (self.white_is_zero and component == 0)
                    max_sample - sample
                else
                    sample;
            }
        }
        return planes;
    }

    pub fn fromSamplePlanes(
        allocator: std.mem.Allocator,
        planes: color.SamplePlanes,
        alpha_mode: color.AlphaMode,
    ) !AlphaImage {
        if (planes.width == 0 or planes.height == 0 or
            (planes.bit_depth != 8 and planes.bit_depth != 16) or
            (planes.planes.len != 2 and planes.planes.len != 4))
        {
            return TiffError.UnsupportedExtraSamples;
        }
        const pixels = try std.math.mul(usize, planes.width, planes.height);
        const max_sample: u16 = if (planes.bit_depth == 8) 255 else std.math.maxInt(u16);
        for (planes.planes) |plane| {
            if (plane.len != pixels) return TiffError.InvalidTagValue;
            for (plane) |sample| {
                if (sample > max_sample) return TiffError.InvalidTagValue;
            }
        }
        const samples = try allocator.alloc(u16, try std.math.mul(usize, pixels, planes.planes.len));
        errdefer allocator.free(samples);
        for (0..pixels) |pixel| {
            for (planes.planes, 0..) |plane, component| {
                samples[pixel * planes.planes.len + component] = plane[pixel];
            }
        }
        return .{
            .allocator = allocator,
            .width = planes.width,
            .height = planes.height,
            .bit_depth = planes.bit_depth,
            .color_space = if (planes.planes.len == 2) .grayscale else .rgb,
            .alpha_mode = alpha_mode,
            .samples = samples,
        };
    }
};

pub const DecodedImage = union(enum) {
    rgb: image.RgbImage,
    grayscale: image.GrayImage,
    alpha: AlphaImage,

    pub fn deinit(self: *DecodedImage) void {
        switch (self.*) {
            .rgb => |*rgb| rgb.deinit(),
            .grayscale => |*gray| gray.deinit(),
            .alpha => |*alpha| alpha.deinit(),
        }
        self.* = undefined;
    }
};

pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !DecodedImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);

    return parse(allocator, bytes);
}

pub fn readRgb(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !image.RgbImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);

    return parseRgb(allocator, bytes);
}

pub fn readGray(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !image.GrayImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);

    return parseGray(allocator, bytes);
}

pub fn readAlpha(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !AlphaImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);

    return parseAlpha(allocator, bytes);
}

/// Byte layout of a bounded chunky RGB TIFF. Every offset follows from the
/// dimensions, precision, and ICC length alone, which is what lets the raster
/// be streamed instead of buffered.
const RgbLayout = struct {
    width: usize,
    height: usize,
    bit_depth: u8,
    icc_len: usize,
    entry_count: u16,
    bits_offset: u32,
    raster_offset: u32,
    raster_bytes: u32,
    icc_offset: u32,

    fn init(width: usize, height: usize, bit_depth: u8, icc_len: usize) !RgbLayout {
        if (width == 0 or height == 0 or (bit_depth != 8 and bit_depth != 16)) {
            return TiffError.InvalidTagValue;
        }
        const pixels = try std.math.mul(usize, width, height);
        const sample_count = try std.math.mul(usize, pixels, 3);
        const raster_bytes = try std.math.mul(usize, sample_count, rasterBytesPerSample(bit_depth));
        if (width > std.math.maxInt(u32) or height > std.math.maxInt(u32) or
            raster_bytes > std.math.maxInt(u32))
        {
            return TiffError.ImageTooLarge;
        }
        if (icc_len != 0) {
            if (icc_len > max_icc_profile_bytes) return TiffError.InvalidTagValue;
            if (icc_len > std.math.maxInt(u32)) return TiffError.ImageTooLarge;
        }
        const entry_count: u16 = if (icc_len != 0) 11 else 10;
        const bits_offset: u32 = 8 + 2 + @as(u32, entry_count) * 12 + 4;
        const raster_offset: u32 = bits_offset + 6;
        return .{
            .width = width,
            .height = height,
            .bit_depth = bit_depth,
            .icc_len = icc_len,
            .entry_count = entry_count,
            .bits_offset = bits_offset,
            .raster_offset = raster_offset,
            .raster_bytes = @intCast(raster_bytes),
            .icc_offset = try std.math.add(u32, raster_offset, @as(u32, @intCast(raster_bytes))),
        };
    }

    fn totalBytes(self: RgbLayout) !usize {
        return std.math.add(usize, @as(usize, self.icc_offset), self.icc_len);
    }

    fn rowBytes(self: RgbLayout) usize {
        return self.width * 3 * rasterBytesPerSample(self.bit_depth);
    }

    /// Appends everything before the raster: header, IFD, and the BitsPerSample
    /// array. Shared so the buffered and streaming writers cannot diverge.
    fn appendPrefix(self: RgbLayout, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(allocator, "II");
        try appendU16Le(allocator, out, 42);
        try appendU32Le(allocator, out, 8);
        try appendU16Le(allocator, out, self.entry_count);
        try appendIfdEntryLe(allocator, out, 256, 4, 1, @as(u32, @intCast(self.width)));
        try appendIfdEntryLe(allocator, out, 257, 4, 1, @as(u32, @intCast(self.height)));
        try appendIfdEntryLe(allocator, out, 258, 3, 3, self.bits_offset);
        try appendIfdEntryLe(allocator, out, 259, 3, 1, 1);
        try appendIfdEntryLe(allocator, out, 262, 3, 1, 2);
        try appendIfdEntryLe(allocator, out, 273, 4, 1, self.raster_offset);
        try appendIfdEntryLe(allocator, out, 277, 3, 1, 3);
        try appendIfdEntryLe(allocator, out, 278, 4, 1, @as(u32, @intCast(self.height)));
        try appendIfdEntryLe(allocator, out, 279, 4, 1, self.raster_bytes);
        try appendIfdEntryLe(allocator, out, 284, 3, 1, 1);
        if (self.icc_len != 0) {
            try appendIfdEntryLe(allocator, out, 34675, 7, @as(u32, @intCast(self.icc_len)), self.icc_offset);
        }
        try appendU32Le(allocator, out, 0);
        try appendU16Le(allocator, out, self.bit_depth);
        try appendU16Le(allocator, out, self.bit_depth);
        try appendU16Le(allocator, out, self.bit_depth);
    }
};

pub fn writeRgb(io: std.Io, allocator: std.mem.Allocator, rgb: image.RgbImage, path: []const u8) !void {
    const icc_profile = rgb.icc_profile;
    const layout = try RgbLayout.init(
        rgb.width,
        rgb.height,
        rgb.bit_depth,
        if (icc_profile) |profile| profile.len else 0,
    );
    if (icc_profile) |profile| {
        if (profile.len == 0) return TiffError.InvalidTagValue;
    }
    const sample_count = try std.math.mul(usize, try std.math.mul(usize, rgb.width, rgb.height), 3);
    if (rgb.samples.len != sample_count) return TiffError.InvalidTagValue;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, try layout.totalBytes());
    try layout.appendPrefix(allocator, &out);

    appendRasterLe(&out, rgb.samples, rgb.bit_depth) catch |err| switch (err) {
        error.InvalidTagValue => return TiffError.InvalidTagValue,
    };
    if (icc_profile) |profile| try out.appendSlice(allocator, profile);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// Streaming chunky RGB TIFF writer. The header, IFD, and BitsPerSample array
/// are emitted from the declared geometry, then complete rows are appended as
/// they arrive and the optional ICC profile is appended last. Output is
/// byte-identical to `writeRgb` for the same image, but peak memory is one
/// band of rows rather than the whole file.
pub const RgbBandWriter = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    layout: RgbLayout,
    icc_profile: ?[]const u8,
    raster: std.ArrayList(u8),
    rows_written: usize = 0,
    finished: bool = false,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        width: usize,
        height: usize,
        bit_depth: u8,
        icc_profile: ?[]const u8,
    ) !RgbBandWriter {
        if (icc_profile) |profile| {
            if (profile.len == 0) return TiffError.InvalidTagValue;
        }
        const layout = try RgbLayout.init(
            width,
            height,
            bit_depth,
            if (icc_profile) |profile| profile.len else 0,
        );

        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(allocator);
        try prefix.ensureTotalCapacity(allocator, layout.raster_offset);
        try layout.appendPrefix(allocator, &prefix);
        std.debug.assert(prefix.items.len == layout.raster_offset);

        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        errdefer file.close(io);
        try file.writeStreamingAll(io, prefix.items);
        return .{
            .io = io,
            .allocator = allocator,
            .file = file,
            .layout = layout,
            .icc_profile = icc_profile,
            .raster = .empty,
        };
    }

    /// Appends one or more complete interleaved RGB rows in top-to-bottom
    /// order. `samples` must hold a whole number of rows.
    pub fn writeRows(self: *RgbBandWriter, samples: []const u16) !void {
        if (self.finished) return TiffError.InvalidTagValue;
        const row_samples = self.layout.width * 3;
        if (row_samples == 0 or samples.len % row_samples != 0) return TiffError.InvalidTagValue;
        const rows = samples.len / row_samples;
        if (rows == 0) return;
        if (try std.math.add(usize, self.rows_written, rows) > self.layout.height) {
            return TiffError.InvalidTagValue;
        }

        const bytes = samples.len * rasterBytesPerSample(self.layout.bit_depth);
        try self.raster.resize(self.allocator, bytes);
        serializeRasterLe(self.raster.items, samples, self.layout.bit_depth) catch |err| switch (err) {
            error.InvalidTagValue => return TiffError.InvalidTagValue,
        };
        try self.file.writeStreamingAll(self.io, self.raster.items);
        self.rows_written += rows;
    }

    /// Appends the ICC profile and closes the file. Fails closed unless exactly
    /// the declared number of rows was written.
    pub fn finish(self: *RgbBandWriter) !void {
        if (self.finished) return TiffError.InvalidTagValue;
        if (self.rows_written != self.layout.height) return TiffError.InvalidTagValue;
        if (self.icc_profile) |profile| try self.file.writeStreamingAll(self.io, profile);
        self.finished = true;
        self.file.close(self.io);
        self.raster.deinit(self.allocator);
        self.raster = .empty;
    }

    /// Releases the file handle without completing the image. Safe to call
    /// after `finish`.
    pub fn deinit(self: *RgbBandWriter) void {
        if (!self.finished) {
            self.finished = true;
            self.file.close(self.io);
        }
        self.raster.deinit(self.allocator);
        self.raster = .empty;
    }
};

/// Band sink that converts upsampled reference-grid bands into interleaved RGB
/// rows and appends them to an `RgbBandWriter`, so a subsampled JP2-to-TIFF
/// conversion holds neither the whole raster nor the whole output file. The
/// band types are taken as `anytype` so this stays a TIFF-layer concern without
/// depending on the codestream layer.
pub const RgbBandSink = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    bit_depth: u8,
    icc_profile: ?[]const u8 = null,
    writer: ?RgbBandWriter = null,
    rows: std.ArrayList(u16) = .empty,
    width: usize = 0,
    height: usize = 0,

    pub fn begin(self: *RgbBandSink, info: anytype) !void {
        if (self.writer != null) return TiffError.InvalidTagValue;
        if (info.components.len != 3) return TiffError.InvalidTagValue;
        for (info.components) |layout| {
            if (layout.bit_depth != self.bit_depth) return TiffError.InvalidTagValue;
        }
        self.width = info.width;
        self.height = info.height;
        self.writer = try RgbBandWriter.init(
            self.io,
            self.allocator,
            self.path,
            info.width,
            info.height,
            self.bit_depth,
            self.icc_profile,
        );
    }

    pub fn writeBand(self: *RgbBandSink, region: anytype) !void {
        if (self.writer == null) return TiffError.InvalidTagValue;
        const writer = &self.writer.?;
        if (region.components.len != 3) return TiffError.InvalidTagValue;
        const pixels = try std.math.mul(usize, region.width, region.height);
        for (region.components) |component| {
            // Upsampling puts every component on the shared reference grid, so
            // a band's planes are contiguous and equally sized.
            if (component.width != region.width or component.height != region.height or
                component.stride != region.width or component.samples.len != pixels)
            {
                return TiffError.InvalidTagValue;
            }
        }
        try self.rows.resize(self.allocator, try std.math.mul(usize, pixels, 3));
        try color.interleaveRgbSamples(
            self.rows.items,
            region.components[0].samples,
            region.components[1].samples,
            region.components[2].samples,
            self.bit_depth,
        );
        try writer.writeRows(self.rows.items);
    }

    pub fn finish(self: *RgbBandSink) !void {
        if (self.writer == null) return TiffError.InvalidTagValue;
        try self.writer.?.finish();
    }

    pub fn deinit(self: *RgbBandSink) void {
        if (self.writer) |*writer| writer.deinit();
        self.writer = null;
        self.rows.deinit(self.allocator);
        self.rows = .empty;
    }
};

/// Byte layout of a bounded single-channel TIFF. BitsPerSample fits inline in
/// its IFD entry, so the raster starts immediately after the directory and
/// every offset again follows from the declared geometry alone.
const GrayLayout = struct {
    width: usize,
    height: usize,
    bit_depth: u8,
    white_is_zero: bool,
    icc_len: usize,
    entry_count: u16,
    raster_offset: u32,
    raster_bytes: u32,
    icc_offset: u32,

    fn init(
        width: usize,
        height: usize,
        bit_depth: u8,
        white_is_zero: bool,
        icc_len: usize,
    ) !GrayLayout {
        if (width == 0 or height == 0 or (bit_depth != 8 and bit_depth != 16)) {
            return TiffError.InvalidTagValue;
        }
        const pixels = try std.math.mul(usize, width, height);
        const raster_bytes = try std.math.mul(usize, pixels, rasterBytesPerSample(bit_depth));
        if (width > std.math.maxInt(u32) or height > std.math.maxInt(u32) or
            raster_bytes > std.math.maxInt(u32))
        {
            return TiffError.ImageTooLarge;
        }
        if (icc_len != 0) {
            if (icc_len > max_icc_profile_bytes) return TiffError.InvalidTagValue;
            if (icc_len > std.math.maxInt(u32)) return TiffError.ImageTooLarge;
        }
        const entry_count: u16 = if (icc_len != 0) 11 else 10;
        const raster_offset: u32 = 8 + 2 + @as(u32, entry_count) * 12 + 4;
        return .{
            .width = width,
            .height = height,
            .bit_depth = bit_depth,
            .white_is_zero = white_is_zero,
            .icc_len = icc_len,
            .entry_count = entry_count,
            .raster_offset = raster_offset,
            .raster_bytes = @intCast(raster_bytes),
            .icc_offset = try std.math.add(u32, raster_offset, @as(u32, @intCast(raster_bytes))),
        };
    }

    fn totalBytes(self: GrayLayout) !usize {
        return std.math.add(usize, @as(usize, self.icc_offset), self.icc_len);
    }

    fn appendPrefix(self: GrayLayout, allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.appendSlice(allocator, "II");
        try appendU16Le(allocator, out, 42);
        try appendU32Le(allocator, out, 8);
        try appendU16Le(allocator, out, self.entry_count);
        try appendIfdEntryLe(allocator, out, 256, 4, 1, @as(u32, @intCast(self.width)));
        try appendIfdEntryLe(allocator, out, 257, 4, 1, @as(u32, @intCast(self.height)));
        try appendIfdEntryLe(allocator, out, 258, 3, 1, self.bit_depth);
        try appendIfdEntryLe(allocator, out, 259, 3, 1, 1);
        try appendIfdEntryLe(allocator, out, 262, 3, 1, if (self.white_is_zero) 0 else 1);
        try appendIfdEntryLe(allocator, out, 273, 4, 1, self.raster_offset);
        try appendIfdEntryLe(allocator, out, 277, 3, 1, 1);
        try appendIfdEntryLe(allocator, out, 278, 4, 1, @as(u32, @intCast(self.height)));
        try appendIfdEntryLe(allocator, out, 279, 4, 1, self.raster_bytes);
        try appendIfdEntryLe(allocator, out, 284, 3, 1, 1);
        if (self.icc_len != 0) {
            try appendIfdEntryLe(allocator, out, 34675, 7, @as(u32, @intCast(self.icc_len)), self.icc_offset);
        }
        try appendU32Le(allocator, out, 0);
    }
};

pub fn writeGray(io: std.Io, allocator: std.mem.Allocator, gray: image.GrayImage, path: []const u8) !void {
    const icc_profile = gray.icc_profile;
    const layout = try GrayLayout.init(
        gray.width,
        gray.height,
        gray.bit_depth,
        gray.white_is_zero,
        if (icc_profile) |profile| profile.len else 0,
    );
    if (icc_profile) |profile| {
        if (profile.len == 0) return TiffError.InvalidTagValue;
    }
    const pixels = try std.math.mul(usize, gray.width, gray.height);
    if (gray.samples.len != pixels) return TiffError.InvalidTagValue;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, try layout.totalBytes());
    try layout.appendPrefix(allocator, &out);

    appendRasterLe(&out, gray.samples, gray.bit_depth) catch |err| switch (err) {
        error.InvalidTagValue => return TiffError.InvalidTagValue,
    };
    if (icc_profile) |profile| try out.appendSlice(allocator, profile);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// Streaming single-channel TIFF writer, the grayscale counterpart of
/// `RgbBandWriter`. Output is byte-identical to `writeGray` for the same image.
pub const GrayBandWriter = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    file: std.Io.File,
    layout: GrayLayout,
    icc_profile: ?[]const u8,
    raster: std.ArrayList(u8),
    rows_written: usize = 0,
    finished: bool = false,

    pub fn init(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
        width: usize,
        height: usize,
        bit_depth: u8,
        white_is_zero: bool,
        icc_profile: ?[]const u8,
    ) !GrayBandWriter {
        if (icc_profile) |profile| {
            if (profile.len == 0) return TiffError.InvalidTagValue;
        }
        const layout = try GrayLayout.init(
            width,
            height,
            bit_depth,
            white_is_zero,
            if (icc_profile) |profile| profile.len else 0,
        );

        var prefix: std.ArrayList(u8) = .empty;
        defer prefix.deinit(allocator);
        try prefix.ensureTotalCapacity(allocator, layout.raster_offset);
        try layout.appendPrefix(allocator, &prefix);
        std.debug.assert(prefix.items.len == layout.raster_offset);

        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        errdefer file.close(io);
        try file.writeStreamingAll(io, prefix.items);
        return .{
            .io = io,
            .allocator = allocator,
            .file = file,
            .layout = layout,
            .icc_profile = icc_profile,
            .raster = .empty,
        };
    }

    pub fn writeRows(self: *GrayBandWriter, samples: []const u16) !void {
        if (self.finished) return TiffError.InvalidTagValue;
        const row_samples = self.layout.width;
        if (row_samples == 0 or samples.len % row_samples != 0) return TiffError.InvalidTagValue;
        const rows = samples.len / row_samples;
        if (rows == 0) return;
        if (try std.math.add(usize, self.rows_written, rows) > self.layout.height) {
            return TiffError.InvalidTagValue;
        }

        const bytes = samples.len * rasterBytesPerSample(self.layout.bit_depth);
        try self.raster.resize(self.allocator, bytes);
        serializeRasterLe(self.raster.items, samples, self.layout.bit_depth) catch |err| switch (err) {
            error.InvalidTagValue => return TiffError.InvalidTagValue,
        };
        try self.file.writeStreamingAll(self.io, self.raster.items);
        self.rows_written += rows;
    }

    pub fn finish(self: *GrayBandWriter) !void {
        if (self.finished) return TiffError.InvalidTagValue;
        if (self.rows_written != self.layout.height) return TiffError.InvalidTagValue;
        if (self.icc_profile) |profile| try self.file.writeStreamingAll(self.io, profile);
        self.finished = true;
        self.file.close(self.io);
        self.raster.deinit(self.allocator);
        self.raster = .empty;
    }

    pub fn deinit(self: *GrayBandWriter) void {
        if (!self.finished) {
            self.finished = true;
            self.file.close(self.io);
        }
        self.raster.deinit(self.allocator);
        self.raster = .empty;
    }
};

/// Band sink that appends single-component bands to a `GrayBandWriter`. Like
/// `RgbBandSink` it takes the band types as `anytype`, so the TIFF layer gains
/// no dependency on the codestream layer.
pub const GrayBandSink = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    bit_depth: u8,
    white_is_zero: bool = false,
    icc_profile: ?[]const u8 = null,
    writer: ?GrayBandWriter = null,
    width: usize = 0,
    height: usize = 0,

    pub fn begin(self: *GrayBandSink, info: anytype) !void {
        if (self.writer != null) return TiffError.InvalidTagValue;
        if (info.components.len != 1) return TiffError.InvalidTagValue;
        if (info.components[0].bit_depth != self.bit_depth) return TiffError.InvalidTagValue;
        self.width = info.width;
        self.height = info.height;
        self.writer = try GrayBandWriter.init(
            self.io,
            self.allocator,
            self.path,
            info.width,
            info.height,
            self.bit_depth,
            self.white_is_zero,
            self.icc_profile,
        );
    }

    pub fn writeBand(self: *GrayBandSink, region: anytype) !void {
        if (self.writer == null) return TiffError.InvalidTagValue;
        const writer = &self.writer.?;
        if (region.components.len != 1) return TiffError.InvalidTagValue;
        const component = region.components[0];
        const pixels = try std.math.mul(usize, region.width, region.height);
        if (component.width != region.width or component.height != region.height or
            component.stride != region.width or component.samples.len != pixels)
        {
            return TiffError.InvalidTagValue;
        }
        try writer.writeRows(component.samples);
    }

    pub fn finish(self: *GrayBandSink) !void {
        if (self.writer == null) return TiffError.InvalidTagValue;
        try self.writer.?.finish();
    }

    pub fn deinit(self: *GrayBandSink) void {
        if (self.writer) |*writer| writer.deinit();
        self.writer = null;
    }
};

pub fn writeAlpha(io: std.Io, allocator: std.mem.Allocator, alpha: AlphaImage, path: []const u8) !void {
    if (alpha.width == 0 or alpha.height == 0 or
        (alpha.bit_depth != 8 and alpha.bit_depth != 16) or
        (alpha.color_space == .rgb and alpha.white_is_zero))
    {
        return TiffError.InvalidTagValue;
    }
    const pixels = try std.math.mul(usize, alpha.width, alpha.height);
    const component_count = alpha.componentCount();
    const sample_count = try std.math.mul(usize, pixels, component_count);
    if (alpha.samples.len != sample_count) return TiffError.InvalidTagValue;

    const bytes_per_sample: usize = if (alpha.bit_depth == 8) 1 else 2;
    const raster_bytes = try std.math.mul(usize, sample_count, bytes_per_sample);
    if (alpha.width > std.math.maxInt(u32) or
        alpha.height > std.math.maxInt(u32) or
        raster_bytes > std.math.maxInt(u32))
    {
        return TiffError.ImageTooLarge;
    }

    const icc_profile = alpha.icc_profile;
    if (icc_profile) |profile| {
        if (profile.len == 0 or profile.len > max_icc_profile_bytes) return TiffError.InvalidTagValue;
        if (profile.len > std.math.maxInt(u32)) return TiffError.ImageTooLarge;
    }

    const entry_count: u16 = if (icc_profile != null) 12 else 11;
    const metadata_end: u32 = 8 + 2 + @as(u32, entry_count) * 12 + 4;
    const external_bits_bytes: u32 = if (component_count == 4) 8 else 0;
    const raster_offset = try std.math.add(u32, metadata_end, external_bits_bytes);
    const icc_offset = try std.math.add(u32, raster_offset, @as(u32, @intCast(raster_bytes)));
    const total_bytes = try std.math.add(usize, @as(usize, icc_offset), if (icc_profile) |profile| profile.len else 0);
    const bits_value: u32 = if (component_count == 2)
        @as(u32, alpha.bit_depth) | (@as(u32, alpha.bit_depth) << 16)
    else
        metadata_end;

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, total_bytes);

    try out.appendSlice(allocator, "II");
    try appendU16Le(allocator, &out, 42);
    try appendU32Le(allocator, &out, 8);
    try appendU16Le(allocator, &out, entry_count);
    try appendIfdEntryLe(allocator, &out, 256, 4, 1, @intCast(alpha.width));
    try appendIfdEntryLe(allocator, &out, 257, 4, 1, @intCast(alpha.height));
    try appendIfdEntryLe(allocator, &out, 258, 3, @intCast(component_count), bits_value);
    try appendIfdEntryLe(allocator, &out, 259, 3, 1, 1);
    try appendIfdEntryLe(allocator, &out, 262, 3, 1, switch (alpha.color_space) {
        .grayscale => if (alpha.white_is_zero) 0 else 1,
        .rgb => 2,
    });
    try appendIfdEntryLe(allocator, &out, 273, 4, 1, raster_offset);
    try appendIfdEntryLe(allocator, &out, 277, 3, 1, @intCast(component_count));
    try appendIfdEntryLe(allocator, &out, 278, 4, 1, @intCast(alpha.height));
    try appendIfdEntryLe(allocator, &out, 279, 4, 1, @intCast(raster_bytes));
    try appendIfdEntryLe(allocator, &out, 284, 3, 1, 1);
    try appendIfdEntryLe(allocator, &out, 338, 3, 1, switch (alpha.alpha_mode) {
        .associated => 1,
        .unassociated => 2,
    });
    if (icc_profile) |profile| {
        try appendIfdEntryLe(allocator, &out, 34675, 7, @intCast(profile.len), icc_offset);
    }
    try appendU32Le(allocator, &out, 0);
    if (component_count == 4) {
        for (0..component_count) |_| try appendU16Le(allocator, &out, alpha.bit_depth);
    }

    appendRasterLe(&out, alpha.samples, alpha.bit_depth) catch |err| switch (err) {
        error.InvalidTagValue => return TiffError.InvalidTagValue,
    };
    if (icc_profile) |profile| try out.appendSlice(allocator, profile);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

fn appendRasterLe(out: *std.ArrayList(u8), samples: []const u16, bit_depth: u8) error{InvalidTagValue}!void {
    const start = out.items.len;
    errdefer out.items.len = start;

    const raster_len = samples.len * rasterBytesPerSample(bit_depth);
    std.debug.assert(out.capacity >= start + raster_len);
    out.items.len = start + raster_len;
    try serializeRasterLe(out.items[start..][0..raster_len], samples, bit_depth);
}

fn rasterBytesPerSample(bit_depth: u8) usize {
    return if (bit_depth == 8) 1 else 2;
}

/// Writes `samples` into `raster` in the TIFF little-endian layout for
/// `bit_depth`. Shared by the whole-image writers and the streaming band
/// writer, so both serialize identically.
fn serializeRasterLe(raster: []u8, samples: []const u16, bit_depth: u8) error{InvalidTagValue}!void {
    if (bit_depth == 8) {
        std.debug.assert(raster.len == samples.len);
        var index: usize = 0;
        const max_value: SampleU16Vector = @splat(255);
        while (index + sample_lanes <= samples.len) : (index += sample_lanes) {
            const values: SampleU16Vector = samples[index..][0..sample_lanes].*;
            if (@reduce(.Or, values > max_value)) return error.InvalidTagValue;
            raster[index..][0..sample_lanes].* = @as(SampleU8Vector, @intCast(values));
        }
        while (index < samples.len) : (index += 1) {
            const sample = samples[index];
            if (sample > 255) return error.InvalidTagValue;
            raster[index] = @intCast(sample);
        }
        return;
    }

    std.debug.assert(raster.len == samples.len * 2);
    if (comptime builtin.target.cpu.arch.endian() == .little) {
        @memcpy(raster, std.mem.sliceAsBytes(samples));
        return;
    }

    for (samples, 0..) |sample, index| {
        const offset = index * 2;
        raster[offset] = @truncate(sample);
        raster[offset + 1] = @truncate(sample >> 8);
    }
}

const ParsedChunkyImage = struct {
    width: usize,
    height: usize,
    bit_depth: u8,
    photometric: u16,
    alpha_mode: ?color.AlphaMode,
    samples: []u16,
    icc_profile: ?[]u8,

    fn deinit(self: *ParsedChunkyImage, allocator: std.mem.Allocator) void {
        if (self.icc_profile) |profile| allocator.free(profile);
        allocator.free(self.samples);
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !DecodedImage {
    const parsed = try parseChunky(allocator, bytes);
    if (parsed.alpha_mode) |alpha_mode| {
        return .{ .alpha = .{
            .allocator = allocator,
            .width = parsed.width,
            .height = parsed.height,
            .bit_depth = parsed.bit_depth,
            .color_space = if (parsed.photometric == 2) .rgb else .grayscale,
            .alpha_mode = alpha_mode,
            .samples = parsed.samples,
            .white_is_zero = parsed.photometric == 0,
            .icc_profile = parsed.icc_profile,
        } };
    }
    return switch (parsed.photometric) {
        2 => .{ .rgb = .{
            .allocator = allocator,
            .width = parsed.width,
            .height = parsed.height,
            .bit_depth = parsed.bit_depth,
            .samples = parsed.samples,
            .icc_profile = parsed.icc_profile,
        } },
        0, 1 => .{ .grayscale = .{
            .allocator = allocator,
            .width = parsed.width,
            .height = parsed.height,
            .bit_depth = parsed.bit_depth,
            .samples = parsed.samples,
            .white_is_zero = parsed.photometric == 0,
            .icc_profile = parsed.icc_profile,
        } },
        else => unreachable,
    };
}

pub fn parseRgb(allocator: std.mem.Allocator, bytes: []const u8) !image.RgbImage {
    var parsed = try parseChunky(allocator, bytes);
    if (parsed.alpha_mode != null) {
        parsed.deinit(allocator);
        return TiffError.UnsupportedExtraSamples;
    }
    if (parsed.photometric != 2) {
        parsed.deinit(allocator);
        return TiffError.UnsupportedPhotometric;
    }
    return .{
        .allocator = allocator,
        .width = parsed.width,
        .height = parsed.height,
        .bit_depth = parsed.bit_depth,
        .samples = parsed.samples,
        .icc_profile = parsed.icc_profile,
    };
}

pub fn parseGray(allocator: std.mem.Allocator, bytes: []const u8) !image.GrayImage {
    var parsed = try parseChunky(allocator, bytes);
    if (parsed.alpha_mode != null) {
        parsed.deinit(allocator);
        return TiffError.UnsupportedExtraSamples;
    }
    if (parsed.photometric != 0 and parsed.photometric != 1) {
        parsed.deinit(allocator);
        return TiffError.UnsupportedPhotometric;
    }
    return .{
        .allocator = allocator,
        .width = parsed.width,
        .height = parsed.height,
        .bit_depth = parsed.bit_depth,
        .samples = parsed.samples,
        .white_is_zero = parsed.photometric == 0,
        .icc_profile = parsed.icc_profile,
    };
}

pub fn parseAlpha(allocator: std.mem.Allocator, bytes: []const u8) !AlphaImage {
    var parsed = try parseChunky(allocator, bytes);
    const alpha_mode = parsed.alpha_mode orelse {
        parsed.deinit(allocator);
        return TiffError.UnsupportedExtraSamples;
    };
    return .{
        .allocator = allocator,
        .width = parsed.width,
        .height = parsed.height,
        .bit_depth = parsed.bit_depth,
        .color_space = if (parsed.photometric == 2) .rgb else .grayscale,
        .alpha_mode = alpha_mode,
        .samples = parsed.samples,
        .white_is_zero = parsed.photometric == 0,
        .icc_profile = parsed.icc_profile,
    };
}

fn parseChunky(allocator: std.mem.Allocator, bytes: []const u8) !ParsedChunkyImage {
    if (bytes.len < 8) return TiffError.InvalidHeader;

    const endian: Endian = if (std.mem.eql(u8, bytes[0..2], "II"))
        .little
    else if (std.mem.eql(u8, bytes[0..2], "MM"))
        .big
    else
        return TiffError.InvalidHeader;

    if (try readU16(bytes, 2, endian) != 42) return TiffError.InvalidHeader;

    const ifd_offset = @as(usize, try readU32(bytes, 4, endian));
    if (ifd_offset > bytes.len - 2) return TiffError.InvalidIfd;

    const entry_count = try readU16(bytes, ifd_offset, endian);
    const entries_offset = ifd_offset + 2;
    const entries_bytes = try std.math.mul(usize, entry_count, 12);
    if (entries_offset > bytes.len or bytes.len - entries_offset < entries_bytes) {
        return TiffError.InvalidIfd;
    }

    var width: ?u32 = null;
    var height: ?u32 = null;
    var compression: u16 = 1;
    var photometric: ?u16 = null;
    var bits_ref: ?ValueRef = null;
    var strip_offsets_ref: ?ValueRef = null;
    var strip_counts_ref: ?ValueRef = null;
    var samples_per_pixel: u16 = 1;
    var planar_config: u16 = 1;
    var sample_format: u16 = 1;
    var extra_samples_ref: ?ValueRef = null;
    var icc_profile_ref: ?ValueRef = null;

    for (0..entry_count) |i| {
        const entry = try readEntry(bytes, entries_offset + i * 12, endian);
        switch (entry.tag) {
            256 => width = try readSingleU32(bytes, endian, entry),
            257 => height = try readSingleU32(bytes, endian, entry),
            258 => bits_ref = try valueRef(bytes, entry),
            259 => compression = try readSingleU16(bytes, endian, entry),
            262 => photometric = try readSingleU16(bytes, endian, entry),
            273 => strip_offsets_ref = try valueRef(bytes, entry),
            277 => samples_per_pixel = try readSingleU16(bytes, endian, entry),
            278 => {},
            279 => strip_counts_ref = try valueRef(bytes, entry),
            284 => planar_config = try readSingleU16(bytes, endian, entry),
            338 => {
                if (extra_samples_ref != null) return TiffError.InvalidIfd;
                extra_samples_ref = try valueRef(bytes, entry);
            },
            339 => sample_format = try readSampleFormat(bytes, endian, entry),
            34675 => icc_profile_ref = try valueRef(bytes, entry),
            else => {},
        }
    }

    const w = width orelse return TiffError.MissingRequiredTag;
    const h = height orelse return TiffError.MissingRequiredTag;
    const photo = photometric orelse return TiffError.MissingRequiredTag;
    const offsets_ref = strip_offsets_ref orelse return TiffError.MissingRequiredTag;
    const counts_ref = strip_counts_ref orelse return TiffError.MissingRequiredTag;

    if (w == 0 or h == 0) return TiffError.InvalidTagValue;
    if (compression != 1) return TiffError.UnsupportedCompression;
    const color_component_count: usize = switch (photo) {
        0, 1 => 1,
        2 => 3,
        else => return TiffError.UnsupportedPhotometric,
    };
    const component_count = @as(usize, samples_per_pixel);
    if (component_count < color_component_count) return TiffError.InvalidTagValue;
    const extra_count = component_count - color_component_count;
    const alpha_mode: ?color.AlphaMode = switch (extra_count) {
        0 => no_alpha: {
            if (extra_samples_ref != null) return TiffError.InvalidTagValue;
            break :no_alpha null;
        },
        1 => has_alpha: {
            const extra = extra_samples_ref orelse return TiffError.InvalidTagValue;
            if (extra.count != 1) return TiffError.UnsupportedExtraSamples;
            break :has_alpha switch (try readU16Value(bytes, endian, extra, 0)) {
                1 => .associated,
                2 => .unassociated,
                else => return TiffError.UnsupportedExtraSamples,
            };
        },
        else => return TiffError.UnsupportedExtraSamples,
    };
    if (planar_config != 1) return TiffError.UnsupportedPlanarConfiguration;
    if (sample_format != 1) return TiffError.UnsupportedSampleFormat;
    const bit_values = bits_ref orelse return TiffError.UnsupportedBitsPerSample;
    if (bit_values.count != component_count) return TiffError.UnsupportedBitsPerSample;
    const bit_depth = try readU16Value(bytes, endian, bit_values, 0);
    var component: usize = 1;
    while (component < component_count) : (component += 1) {
        if (try readU16Value(bytes, endian, bit_values, component) != bit_depth) {
            return TiffError.UnsupportedBitsPerSample;
        }
    }
    if (bit_depth != 8 and bit_depth != 16) return TiffError.UnsupportedBitsPerSample;

    const width_usize = @as(usize, w);
    const height_usize = @as(usize, h);
    const pixels = try std.math.mul(usize, width_usize, height_usize);
    if (pixels > max_pixels) return TiffError.ImageTooLarge;
    const sample_count = try std.math.mul(usize, pixels, component_count);
    const bytes_per_sample: usize = if (bit_depth == 8) 1 else 2;
    const expected_raster_bytes = try std.math.mul(usize, sample_count, bytes_per_sample);

    if (offsets_ref.count != counts_ref.count or offsets_ref.count == 0) {
        return TiffError.InvalidTagValue;
    }

    var total_strip_bytes: usize = 0;
    for (0..offsets_ref.count) |i| {
        const strip_count = try readU32Value(bytes, endian, counts_ref, i);
        total_strip_bytes = try std.math.add(usize, total_strip_bytes, strip_count);
    }
    if (total_strip_bytes != expected_raster_bytes) return TiffError.InvalidTagValue;

    const samples = try allocator.alloc(u16, sample_count);
    errdefer allocator.free(samples);

    var sample_index: usize = 0;
    for (0..offsets_ref.count) |strip| {
        const strip_offset = @as(usize, try readU32Value(bytes, endian, offsets_ref, strip));
        const strip_count = @as(usize, try readU32Value(bytes, endian, counts_ref, strip));
        if (strip_offset > bytes.len or bytes.len - strip_offset < strip_count) {
            return TiffError.TruncatedData;
        }
        const strip_bytes = bytes[strip_offset .. strip_offset + strip_count];
        if (strip_bytes.len % bytes_per_sample != 0) return TiffError.InvalidTagValue;

        if (bit_depth == 8) {
            sample_index = widenU8Samples(samples, sample_index, strip_bytes);
        } else {
            sample_index = try readU16Samples(samples, sample_index, strip_bytes, endian);
        }
    }

    if (sample_index != sample_count) return TiffError.InvalidTagValue;

    const icc_profile = if (icc_profile_ref) |ref| try readIccProfile(allocator, bytes, endian, ref) else null;
    errdefer if (icc_profile) |profile| allocator.free(profile);

    return .{
        .width = width_usize,
        .height = height_usize,
        .bit_depth = @as(u8, @intCast(bit_depth)),
        .photometric = photo,
        .alpha_mode = alpha_mode,
        .samples = samples,
        .icc_profile = icc_profile,
    };
}

fn widenU8Samples(out: []u16, start: usize, bytes: []const u8) usize {
    var index: usize = 0;
    while (index + sample_lanes <= bytes.len) : (index += sample_lanes) {
        const packed_bytes: SampleU8Vector = bytes[index..][0..sample_lanes].*;
        out[start + index ..][0..sample_lanes].* = @as(SampleU16Vector, @intCast(packed_bytes));
    }
    while (index < bytes.len) : (index += 1) {
        out[start + index] = bytes[index];
    }
    return start + bytes.len;
}

fn readU16Samples(out: []u16, start: usize, bytes: []const u8, endian: Endian) !usize {
    const sample_count = bytes.len / 2;
    if (comptime builtin.target.cpu.arch.endian() == .little) {
        if (endian == .little) {
            @memcpy(std.mem.sliceAsBytes(out[start..][0..sample_count]), bytes);
            return start + sample_count;
        }
    }

    var cursor: usize = 0;
    var sample_index = start;
    while (cursor < bytes.len) : (cursor += 2) {
        out[sample_index] = try readU16(bytes, cursor, endian);
        sample_index += 1;
    }
    return sample_index;
}

const ValueRef = struct {
    field_type: u16,
    count: usize,
    inline_value: u32,
    offset: ?usize,
};

fn readEntry(bytes: []const u8, offset: usize, endian: Endian) !IfdEntry {
    return .{
        .tag = try readU16(bytes, offset, endian),
        .field_type = try readU16(bytes, offset + 2, endian),
        .count = try readU32(bytes, offset + 4, endian),
        .value_or_offset = try readU32(bytes, offset + 8, endian),
    };
}

fn valueRef(bytes: []const u8, entry: IfdEntry) !ValueRef {
    const elem_size = typeSize(entry.field_type) orelse return TiffError.InvalidTagValue;
    const count = @as(usize, @intCast(entry.count));
    const byte_count = try std.math.mul(usize, count, elem_size);
    const offset: ?usize = if (byte_count <= 4) null else @as(usize, entry.value_or_offset);
    if (offset) |start| {
        if (start > bytes.len or bytes.len - start < byte_count) return TiffError.TruncatedData;
    }
    return .{
        .field_type = entry.field_type,
        .count = count,
        .inline_value = entry.value_or_offset,
        .offset = offset,
    };
}

fn typeSize(field_type: u16) ?usize {
    return switch (field_type) {
        1, 2, 7 => 1,
        3 => 2,
        4 => 4,
        else => null,
    };
}

fn readIccProfile(allocator: std.mem.Allocator, bytes: []const u8, endian: Endian, ref: ValueRef) ![]u8 {
    if (ref.count == 0 or ref.count > max_icc_profile_bytes) return TiffError.InvalidTagValue;
    if (ref.field_type != 1 and ref.field_type != 7) return TiffError.InvalidTagValue;
    const out = try allocator.alloc(u8, ref.count);
    errdefer allocator.free(out);
    if (ref.offset) |offset| {
        @memcpy(out, bytes[offset..][0..ref.count]);
    } else {
        var inline_bytes: [4]u8 = undefined;
        switch (endian) {
            .little => {
                inline_bytes[0] = @as(u8, @truncate(ref.inline_value));
                inline_bytes[1] = @as(u8, @truncate(ref.inline_value >> 8));
                inline_bytes[2] = @as(u8, @truncate(ref.inline_value >> 16));
                inline_bytes[3] = @as(u8, @truncate(ref.inline_value >> 24));
            },
            .big => {
                inline_bytes[0] = @as(u8, @truncate(ref.inline_value >> 24));
                inline_bytes[1] = @as(u8, @truncate(ref.inline_value >> 16));
                inline_bytes[2] = @as(u8, @truncate(ref.inline_value >> 8));
                inline_bytes[3] = @as(u8, @truncate(ref.inline_value));
            },
        }
        @memcpy(out, inline_bytes[0..ref.count]);
    }
    return out;
}

fn readSingleU16(bytes: []const u8, endian: Endian, entry: IfdEntry) !u16 {
    const ref = try valueRef(bytes, entry);
    if (ref.count != 1) return TiffError.InvalidTagValue;
    return readU16Value(bytes, endian, ref, 0);
}

fn readSingleU32(bytes: []const u8, endian: Endian, entry: IfdEntry) !u32 {
    const ref = try valueRef(bytes, entry);
    if (ref.count != 1) return TiffError.InvalidTagValue;
    return readU32Value(bytes, endian, ref, 0);
}

fn readSampleFormat(bytes: []const u8, endian: Endian, entry: IfdEntry) !u16 {
    const ref = try valueRef(bytes, entry);
    if (ref.count == 0) return TiffError.InvalidTagValue;
    const first = try readU16Value(bytes, endian, ref, 0);
    var index: usize = 1;
    while (index < ref.count) : (index += 1) {
        if (try readU16Value(bytes, endian, ref, index) != first) {
            return TiffError.UnsupportedSampleFormat;
        }
    }
    return first;
}

fn readU16Value(bytes: []const u8, endian: Endian, ref: ValueRef, index: usize) !u16 {
    if (index >= ref.count) return TiffError.InvalidTagValue;
    return switch (ref.field_type) {
        3 => if (ref.offset) |offset|
            try readU16(bytes, offset + index * 2, endian)
        else
            inlineU16(ref.inline_value, endian, index),
        else => TiffError.InvalidTagValue,
    };
}

fn readU32Value(bytes: []const u8, endian: Endian, ref: ValueRef, index: usize) !u32 {
    if (index >= ref.count) return TiffError.InvalidTagValue;
    return switch (ref.field_type) {
        3 => try readU16Value(bytes, endian, ref, index),
        4 => if (ref.offset) |offset| try readU32(bytes, offset + index * 4, endian) else ref.inline_value,
        else => TiffError.InvalidTagValue,
    };
}

fn inlineU16(value: u32, endian: Endian, index: usize) u16 {
    return switch (endian) {
        .little => @as(u16, @truncate(value >> @as(u5, @intCast(index * 16)))),
        .big => @as(u16, @truncate(value >> @as(u5, @intCast((1 - index) * 16)))),
    };
}

fn readU16(bytes: []const u8, offset: usize, endian: Endian) !u16 {
    const end = std.math.add(usize, offset, 2) catch return TiffError.TruncatedData;
    if (end > bytes.len) return TiffError.TruncatedData;
    return switch (endian) {
        .little => @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8),
        .big => (@as(u16, bytes[offset]) << 8) | @as(u16, bytes[offset + 1]),
    };
}

fn readU32(bytes: []const u8, offset: usize, endian: Endian) !u32 {
    const end = std.math.add(usize, offset, 4) catch return TiffError.TruncatedData;
    if (end > bytes.len) return TiffError.TruncatedData;
    return switch (endian) {
        .little => @as(u32, bytes[offset]) |
            (@as(u32, bytes[offset + 1]) << 8) |
            (@as(u32, bytes[offset + 2]) << 16) |
            (@as(u32, bytes[offset + 3]) << 24),
        .big => (@as(u32, bytes[offset]) << 24) |
            (@as(u32, bytes[offset + 1]) << 16) |
            (@as(u32, bytes[offset + 2]) << 8) |
            @as(u32, bytes[offset + 3]),
    };
}

fn appendIfdEntryLe(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tag: u16,
    field_type: u16,
    count: u32,
    value: u32,
) !void {
    try appendU16Le(allocator, out, tag);
    try appendU16Le(allocator, out, field_type);
    try appendU32Le(allocator, out, count);
    try appendU32Le(allocator, out, value);
}

fn appendU16Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    try out.append(allocator, @as(u8, @truncate(value)));
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
}

fn appendU32Le(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    try out.append(allocator, @as(u8, @truncate(value)));
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value >> 16)));
    try out.append(allocator, @as(u8, @truncate(value >> 24)));
}
