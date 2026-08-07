const std = @import("std");
const clock = @import("clock.zig");
const codestream = @import("codestream.zig");
const color = @import("color.zig");
const icc_color = @import("icc.zig");
const image = @import("image.zig");
const jp2 = @import("jp2.zig");
const tiff = @import("tiff.zig");

/// Phase timings for one JP2-to-TIFF conversion. `jp2_read_ns` is filled in by
/// the caller, which owns reading the input file.
pub const Timings = struct {
    total_ns: u64 = 0,
    jp2_read_ns: u64 = 0,
    codestream_extract_ns: u64 = 0,
    codestream_decode_ns: u64 = 0,
    icc_extract_ns: u64 = 0,
    tiff_write_ns: u64 = 0,
};

pub const Result = struct {
    info: jp2.Info,
    width: usize,
    height: usize,
    /// True when the conversion was written band by band, so neither the whole
    /// raster nor the whole output file was held in memory. False means the
    /// layout still needs a colour transform or interleaved assembly first.
    streamed: bool,
    timings: Timings,
    decode_timings: codestream.DecodeTimings,
};


/// Converts a bounded JP2 to TIFF. Every supported layout is written band by
/// band through a streaming TIFF writer; only the colour-converting and
/// interleaved-RGB layouts still assemble a whole raster first. The command
/// layer owns argument parsing, file reading, and reporting, so this entry
/// point is directly testable.
pub fn jp2ToTiff(
    io: std.Io,
    allocator: std.mem.Allocator,
    bytes: []const u8,
    output_path: []const u8,
    options: codestream.DecodeOptions,
    convert_to_srgb: bool,
    collect_decode_timings: bool,
) !Result {
    var command_timings = Timings{};
    const extract_start = clock.monotonicNs();
    const info = try jp2.parseInfo(bytes);
    const j2k = try jp2.extractCodestream(bytes);
    command_timings.codestream_extract_ns = clock.elapsedNs(extract_start);
    if (convert_to_srgb) {
        if (info.color_space != .restricted_icc or info.components != 3 or info.has_palette) {
            return icc_color.IccError.UnsupportedProfile;
        }
        for (0..info.components) |component| {
            const sampling = info.componentSampling(component) orelse
                return icc_color.IccError.UnsupportedProfile;
            if (sampling[0] != 1 or sampling[1] != 1) {
                return icc_color.IccError.UnsupportedProfile;
            }
        }
    } else switch (info.color_space) {
        // These spaces are intentionally preserved as native planes and
        // metadata by the JP2 API. The TIFF command has no explicit mapping
        // for them yet, so treating their samples as RGB/alpha would be a
        // silent colour conversion.
        .cmyk, .cielab, .esrgb, .esycc => return jp2.Jp2Error.UnsupportedColorSpace,
        else => {},
    }

    var decode_timings = codestream.DecodeTimings{};

    // Bounded streaming conversion: a one-component JP2 needs no colour
    // handling at all, so its bands go straight to the streaming grayscale
    // writer and neither the raster nor the file is held whole.
    if (!info.has_palette and info.components == 1 and !convert_to_srgb and
        !jp2InfoHasSubsampling(info))
    {
        const icc_start = clock.monotonicNs();
        const icc_profile = try jp2.extractIccProfile(allocator, bytes);
        defer if (icc_profile) |profile| allocator.free(profile);
        command_timings.icc_extract_ns = clock.elapsedNs(icc_start);

        const stream_start = clock.monotonicNs();
        var sink = tiff.GrayBandSink{
            .io = io,
            .allocator = allocator,
            .path = output_path,
            .bit_depth = info.bits_per_component,
            .icc_profile = icc_profile,
        };
        defer sink.deinit();
        if (collect_decode_timings) {
            try codestream.decodeLosslessPlanarBandsToSinkProfiled(
                allocator,
                j2k,
                options,
                &sink,
                &decode_timings,
            );
        } else {
            try codestream.decodeLosslessPlanarBandsToSink(allocator, j2k, options, &sink);
        }
        try sink.finish();
        command_timings.codestream_decode_ns = clock.elapsedNs(stream_start);
        command_timings.total_ns = command_timings.jp2_read_ns +
            command_timings.codestream_extract_ns +
            command_timings.codestream_decode_ns +
            command_timings.icc_extract_ns;
        return .{
            .info = info,
            .width = sink.width,
            .height = sink.height,
            .streamed = true,
            .timings = command_timings,
            .decode_timings = decode_timings,
        };
    }

    // A palette stream expands per index sample, so its bands can be expanded
    // and written one at a time too. `--convert-to-srgb` already fails closed
    // for palette input above, so no colour conversion can be pending here.
    if (info.has_palette and !jp2InfoHasSubsampling(info)) {
        const icc_start = clock.monotonicNs();
        const icc_profile = try jp2.extractIccProfile(allocator, bytes);
        defer if (icc_profile) |profile| allocator.free(profile);
        command_timings.icc_extract_ns = clock.elapsedNs(icc_start);

        const stream_start = clock.monotonicNs();
        var table = (try jp2.extractPalette(allocator, bytes)) orelse
            return jp2.Jp2Error.MissingRequiredBox;
        defer table.deinit();
        var sink = PaletteRgbBandSink{
            .io = io,
            .allocator = allocator,
            .path = output_path,
            .palette = table,
            .icc_profile = icc_profile,
        };
        defer sink.deinit();
        if (collect_decode_timings) {
            try codestream.decodeLosslessPlanarBandsToSinkProfiled(
                allocator,
                j2k,
                options,
                &sink,
                &decode_timings,
            );
        } else {
            try codestream.decodeLosslessPlanarBandsToSink(allocator, j2k, options, &sink);
        }
        try sink.finish();
        command_timings.codestream_decode_ns = clock.elapsedNs(stream_start);
        command_timings.total_ns = command_timings.jp2_read_ns +
            command_timings.codestream_extract_ns +
            command_timings.codestream_decode_ns +
            command_timings.icc_extract_ns;
        return .{
            .info = info,
            .width = sink.width,
            .height = sink.height,
            .streamed = true,
            .timings = command_timings,
            .decode_timings = decode_timings,
        };
    }

    // Gray+alpha and RGBA carry no colour conversion either, so their bands go
    // straight to the streaming alpha writer.
    if (!info.has_palette and (info.components == 2 or info.components == 4) and
        !convert_to_srgb and !jp2InfoHasSubsampling(info))
    {
        const alpha_mode = info.alpha_mode orelse return error.UnsupportedComponentCount;
        const icc_start = clock.monotonicNs();
        const icc_profile = try jp2.extractIccProfile(allocator, bytes);
        defer if (icc_profile) |profile| allocator.free(profile);
        command_timings.icc_extract_ns = clock.elapsedNs(icc_start);

        const stream_start = clock.monotonicNs();
        var sink = tiff.AlphaBandSink{
            .io = io,
            .allocator = allocator,
            .path = output_path,
            .bit_depth = info.bits_per_component,
            .alpha_mode = alpha_mode,
            .icc_profile = icc_profile,
        };
        defer sink.deinit();
        if (collect_decode_timings) {
            try codestream.decodeLosslessPlanarBandsToSinkProfiled(
                allocator,
                j2k,
                options,
                &sink,
                &decode_timings,
            );
        } else {
            try codestream.decodeLosslessPlanarBandsToSink(allocator, j2k, options, &sink);
        }
        try sink.finish();
        command_timings.codestream_decode_ns = clock.elapsedNs(stream_start);
        command_timings.total_ns = command_timings.jp2_read_ns +
            command_timings.codestream_extract_ns +
            command_timings.codestream_decode_ns +
            command_timings.icc_extract_ns;
        return .{
            .info = info,
            .width = sink.width,
            .height = sink.height,
            .streamed = true,
            .timings = command_timings,
            .decode_timings = decode_timings,
        };
    }

    // A subsampled three-component JP2 with no colour conversion is the other
    // path where both the upsampled raster and the TIFF file would otherwise be
    // held whole. Decoding it band by band into a streaming TIFF writer keeps
    // peak memory at one tile-row band. Every other layout keeps the
    // whole-raster path below.
    if (!info.has_palette and info.components == 3 and !convert_to_srgb and
        info.color_space != .sycc and jp2InfoHasSubsampling(info))
    {
        const icc_start = clock.monotonicNs();
        const icc_profile = try jp2.extractIccProfile(allocator, bytes);
        defer if (icc_profile) |profile| allocator.free(profile);
        command_timings.icc_extract_ns = clock.elapsedNs(icc_start);

        const stream_start = clock.monotonicNs();
        var sink = tiff.RgbBandSink{
            .io = io,
            .allocator = allocator,
            .path = output_path,
            .bit_depth = info.bits_per_component,
            .icc_profile = icc_profile,
        };
        defer sink.deinit();
        if (collect_decode_timings) {
            try codestream.decodeLosslessPlanarUpsampledToSinkProfiled(
                allocator,
                j2k,
                options,
                &sink,
                &decode_timings,
            );
        } else {
            try codestream.decodeLosslessPlanarUpsampledToSink(allocator, j2k, options, &sink);
        }
        try sink.finish();
        // Decode and write interleave on this path, so they are reported as one
        // streamed stage rather than split into a decode and a write phase.
        command_timings.codestream_decode_ns = clock.elapsedNs(stream_start);
        command_timings.total_ns = command_timings.jp2_read_ns +
            command_timings.codestream_extract_ns +
            command_timings.codestream_decode_ns +
            command_timings.icc_extract_ns;
        return .{
            .info = info,
            .width = sink.width,
            .height = sink.height,
            .streamed = true,
            .timings = command_timings,
            .decode_timings = decode_timings,
        };
    }

    const decode_start = clock.monotonicNs();
    var decoded: tiff.DecodedImage = if (info.has_palette) palette: {
        var indexed = if (collect_decode_timings)
            try codestream.decodeLosslessGrayWithOptionsProfiled(allocator, j2k, options, &decode_timings)
        else
            try codestream.decodeLosslessGrayWithOptions(allocator, j2k, options);
        defer indexed.deinit();
        var table = (try jp2.extractPalette(allocator, bytes)) orelse
            return jp2.Jp2Error.MissingRequiredBox;
        defer table.deinit();
        break :palette .{ .rgb = try table.expand(allocator, indexed) };
    } else switch (info.components) {
        1 => .{ .grayscale = if (collect_decode_timings)
            try codestream.decodeLosslessGrayWithOptionsProfiled(allocator, j2k, options, &decode_timings)
        else
            try codestream.decodeLosslessGrayWithOptions(allocator, j2k, options) },
        3 => rgb: {
            if (info.color_space == .sycc) {
                const chroma_sampling = info.componentSampling(1) orelse
                    return error.UnsupportedComponentCount;
                // Chroma phase follows the absolute image origin, so a selected
                // window is decoded from a chroma-aligned rectangle and cropped
                // after conversion. That keeps the result identical to the
                // corresponding crop of a full conversion.
                if (try codestream.chromaAlignedSelection(
                    allocator,
                    j2k,
                    options,
                    chroma_sampling[0],
                    chroma_sampling[1],
                )) |selection| {
                    var window_options = options;
                    window_options.tile_index = null;
                    window_options.reference_region = selection.source;
                    var window_planes = if (collect_decode_timings)
                        try codestream.decodeLosslessPlanarWithOptionsProfiled(
                            allocator,
                            j2k,
                            window_options,
                            &decode_timings,
                        )
                    else
                        try codestream.decodeLosslessPlanarWithOptions(allocator, j2k, window_options);
                    defer window_planes.deinit();
                    var converted = try color.syccToSrgb(allocator, window_planes, .{
                        .image_origin_x = selection.source.x0,
                        .image_origin_y = selection.source.y0,
                        .chroma_x = chroma_sampling[0],
                        .chroma_y = chroma_sampling[1],
                    });
                    defer converted.deinit();
                    break :rgb .{
                        .rgb = try codestream.cropConvertedChromaAlignedSelection(
                            allocator,
                            converted,
                            selection,
                        ),
                    };
                }
                var planes = if (collect_decode_timings)
                    try codestream.decodeLosslessPlanarWithOptionsProfiled(
                        allocator,
                        j2k,
                        options,
                        &decode_timings,
                    )
                else
                    try codestream.decodeLosslessPlanarWithOptions(allocator, j2k, options);
                defer planes.deinit();
                break :rgb .{ .rgb = try color.syccToSrgb(allocator, planes, .{
                    .image_origin_x = info.image_origin_x,
                    .image_origin_y = info.image_origin_y,
                    .chroma_x = chroma_sampling[0],
                    .chroma_y = chroma_sampling[1],
                }) };
            }
            var has_subsampling = false;
            for (0..info.components) |component| {
                const sampling = info.componentSampling(component) orelse return error.UnsupportedComponentCount;
                has_subsampling = has_subsampling or sampling[0] != 1 or sampling[1] != 1;
            }
            if (has_subsampling) {
                var planes = if (collect_decode_timings)
                    try codestream.decodeLosslessPlanarUpsampledWithOptionsProfiled(
                        allocator,
                        j2k,
                        options,
                        &decode_timings,
                    )
                else
                    try codestream.decodeLosslessPlanarUpsampledWithOptions(allocator, j2k, options);
                defer planes.deinit();
                break :rgb .{ .rgb = try color.interleaveRgb(allocator, planes) };
            }
            break :rgb .{ .rgb = if (collect_decode_timings)
                try codestream.decodeLosslessTemporaryWithOptionsProfiled(allocator, j2k, options, &decode_timings)
            else
                try codestream.decodeLosslessTemporaryWithOptions(allocator, j2k, options) };
        },
        2, 4 => alpha: {
            const alpha_mode = info.alpha_mode orelse return error.UnsupportedComponentCount;
            var planes = try codestream.decodeLosslessPlanarWithOptions(allocator, j2k, options);
            defer planes.deinit();
            break :alpha .{ .alpha = try tiff.AlphaImage.fromSamplePlanes(
                allocator,
                planes,
                alpha_mode,
            ) };
        },
        else => return error.UnsupportedComponentCount,
    };
    defer decoded.deinit();
    command_timings.codestream_decode_ns = clock.elapsedNs(decode_start);

    const icc_start = clock.monotonicNs();
    if (try jp2.extractIccProfile(allocator, bytes)) |profile| {
        if (convert_to_srgb) {
            defer allocator.free(profile);
            switch (decoded) {
                .rgb => |*rgb| {
                    const converted = try icc_color.convertRgbToSrgb(allocator, rgb.*, profile);
                    rgb.deinit();
                    rgb.* = converted;
                },
                else => return icc_color.IccError.UnsupportedProfile,
            }
        } else switch (decoded) {
            .rgb => |*rgb| {
                if (rgb.icc_profile) |existing| allocator.free(existing);
                rgb.icc_profile = profile;
            },
            .grayscale => |*gray| {
                if (gray.icc_profile) |existing| allocator.free(existing);
                gray.icc_profile = profile;
            },
            .alpha => |*alpha| {
                if (alpha.icc_profile) |existing| allocator.free(existing);
                alpha.icc_profile = profile;
            },
        }
    } else if (convert_to_srgb) {
        return icc_color.IccError.UnsupportedProfile;
    }
    command_timings.icc_extract_ns = clock.elapsedNs(icc_start);

    const write_start = clock.monotonicNs();
    switch (decoded) {
        .rgb => |rgb| try tiff.writeRgb(io, allocator, rgb, output_path),
        .grayscale => |gray| try tiff.writeGray(io, allocator, gray, output_path),
        .alpha => |alpha| try tiff.writeAlpha(io, allocator, alpha, output_path),
    }
    command_timings.tiff_write_ns = clock.elapsedNs(write_start);
    command_timings.total_ns = command_timings.jp2_read_ns +
        command_timings.codestream_extract_ns +
        command_timings.codestream_decode_ns +
        command_timings.icc_extract_ns +
        command_timings.tiff_write_ns;

    const output_dimensions = switch (decoded) {
        .rgb => |rgb| [2]usize{ rgb.width, rgb.height },
        .grayscale => |gray| [2]usize{ gray.width, gray.height },
        .alpha => |alpha| [2]usize{ alpha.width, alpha.height },
    };
    return .{
        .info = info,
        .width = output_dimensions[0],
        .height = output_dimensions[1],
        .streamed = false,
        .timings = command_timings,
        .decode_timings = decode_timings,
    };
}

/// Expands each one-component index band through the JP2 palette and appends
/// the resulting RGB rows to a streaming TIFF writer. The palette table is a
/// container concern, so this adapter lives above the TIFF layer rather than
/// inside it.
const PaletteRgbBandSink = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    palette: jp2.Palette,
    icc_profile: ?[]const u8 = null,
    writer: ?tiff.RgbBandWriter = null,
    rows: std.ArrayList(u16) = .empty,
    width: usize = 0,
    height: usize = 0,

    pub fn begin(self: *PaletteRgbBandSink, info: codestream.BandSinkInfo) !void {
        if (info.components.len != 1) return error.UnsupportedComponentCount;
        self.width = info.width;
        self.height = info.height;
        // Output precision is the palette's, not the index component's.
        self.writer = try tiff.RgbBandWriter.init(
            self.io,
            self.allocator,
            self.path,
            info.width,
            info.height,
            self.palette.bit_depth,
            self.icc_profile,
        );
    }

    pub fn writeBand(self: *PaletteRgbBandSink, region: codestream.BandSinkRegion) !void {
        if (self.writer == null) return error.UnsupportedComponentCount;
        const writer = &self.writer.?;
        if (region.components.len != 1) return error.UnsupportedComponentCount;
        const component = region.components[0];
        const pixels = try std.math.mul(usize, region.width, region.height);
        if (component.width != region.width or component.height != region.height or
            component.stride != region.width or component.samples.len != pixels)
        {
            return error.UnsupportedComponentCount;
        }
        try self.rows.resize(self.allocator, try std.math.mul(usize, pixels, 3));
        try self.palette.expandSamples(self.rows.items, component.samples);
        try writer.writeRows(self.rows.items);
    }

    fn finish(self: *PaletteRgbBandSink) !void {
        if (self.writer == null) return error.UnsupportedComponentCount;
        try self.writer.?.finish();
    }

    fn deinit(self: *PaletteRgbBandSink) void {
        if (self.writer) |*writer| writer.deinit();
        self.writer = null;
        self.rows.deinit(self.allocator);
        self.rows = .empty;
    }
};

fn jp2InfoHasSubsampling(info: jp2.Info) bool {
    for (0..info.components) |component| {
        const sampling = info.componentSampling(component) orelse return false;
        if (sampling[0] != 1 or sampling[1] != 1) return true;
    }
    return false;
}
