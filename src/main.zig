const std = @import("std");
const builtin = @import("builtin");
const batch = @import("batch.zig");
const cli_dispatch = @import("cli_dispatch.zig");
const codec = @import("codec.zig");
const color = @import("color.zig");
const codestream = @import("codestream.zig");
const bmp = @import("formats/bmp.zig");
const dng = @import("formats/dng.zig");
const jpeg = @import("formats/jpeg.zig");
const openexr = @import("formats/openexr.zig");
const png = @import("formats/png.zig");
const image = @import("image.zig");
const icc_color = @import("icc.zig");
const jp2 = @import("jp2.zig");
const tiff = @import("tiff.zig");
const app_version = @import("version.zig");
const wavelet = @import("wavelet.zig");

const InferredConversion = cli_dispatch.InferredConversion;
const inferConversion = cli_dispatch.inferConversion;
const inferConversionExtensions = cli_dispatch.inferConversionExtensions;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(allocator);
    while (args_iter.next()) |arg| {
        try args_list.append(allocator, arg);
    }
    const args = args_list.items;

    if (args.len == 2 and
        (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-V")))
    {
        var buffer: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(&buffer, "z2000 {s}\n", .{app_version.string});
        try std.Io.File.stdout().writeStreamingAll(io, line);
        return;
    }

    if (args.len < 2) {
        usage();
        return;
    }

    if (std.mem.eql(u8, args[1], "encode")) {
        try encodeCommand(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "decode")) {
        try decodeCommand(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "tiff-info")) {
        try tiffInfoCommand(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "dng-info")) {
        try dngInfoCommand(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "tiff-to-jp2")) {
        try tiffToJp2Command(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "bmp-to-jp2")) {
        try bmpToJp2Command(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "png-to-jp2")) {
        try pngToJp2Command(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "jpeg-to-jp2")) {
        try jpegToJp2Command(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "dng-to-jp2")) {
        try dngToJp2Command(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "exr-to-jp2")) {
        try exrToJp2Command(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "jp2-info")) {
        try jp2InfoCommand(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "jp2-stats")) {
        try jp2StatsCommand(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "decode-temp-jp2")) {
        try decodeTempJp2Command(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "j2k-to-pgx")) {
        try j2kToPgxCommand(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "j2k-to-zraw")) {
        try j2kToZrawCommand(io, allocator, args[2..]);
    } else if (batch.hasWildcards(std.fs.path.basename(args[1]))) {
        try batchConversionCommand(io, allocator, args[1..]);
    } else if (expandedBatchTargetIndex(args[1..])) |target_index| {
        try expandedBatchConversionCommand(io, allocator, args[1..], target_index);
    } else if (inferConversion(args[1..])) |conversion| {
        switch (conversion) {
            .tiff_to_jp2 => try tiffToJp2Command(io, allocator, args[1..]),
            .bmp_to_jp2 => try bmpToJp2Command(io, allocator, args[1..]),
            .png_to_jp2 => try pngToJp2Command(io, allocator, args[1..]),
            .jpeg_to_jp2 => try jpegToJp2Command(io, allocator, args[1..]),
            .dng_to_jp2 => try dngToJp2Command(io, allocator, args[1..]),
            .exr_to_jp2 => try exrToJp2Command(io, allocator, args[1..]),
            .jp2_to_tiff => try decodeTempJp2Command(io, allocator, args[1..]),
            .j2k_to_pgx => try j2kToPgxCommand(io, allocator, args[1..]),
            .j2k_to_zraw => try j2kToZrawCommand(io, allocator, args[1..]),
        }
    } else {
        usage();
        return error.InvalidCommand;
    }
}

/// Detects the argument shape produced when a shell expands an unquoted glob:
/// `z2000 a.tif b.tif .jp2 [options]`. A normal output filename never starts
/// with a dot-only extension, so single-file shorthand remains unambiguous.
fn expandedBatchTargetIndex(args: []const []const u8) ?usize {
    if (args.len < 2) return null;
    var index: usize = 1;
    while (index < args.len and !std.mem.startsWith(u8, args[index], "-")) : (index += 1) {
        if (batch.isTargetExtension(args[index])) return index;
    }
    return null;
}

/// Non-recursive shorthand batch dispatch: `z2000 *.tif .jp2 [options]`.
/// The shell passes the wildcard through unchanged on Windows; z2000 expands
/// it in the concrete parent directory and derives one target path per file.
fn batchConversionCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
) !void {
    if (args.len < 2 or !batch.isTargetExtension(args[1])) {
        usage();
        return batch.BatchError.InvalidTargetExtension;
    }
    const conversion = inferConversionExtensions(std.fs.path.extension(args[0]), args[1]) orelse {
        usage();
        return error.InvalidCommand;
    };
    var plan = batch.buildPlan(io, allocator, args[0], args[1]) catch |err| {
        switch (err) {
            batch.BatchError.NoMatchingFiles => std.debug.print("batch: no files matched '{s}'\n", .{args[0]}),
            batch.BatchError.OutputCollision => std.debug.print("batch: multiple inputs map to the same target extension '{s}'\n", .{args[1]}),
            else => {},
        }
        return err;
    };
    defer plan.deinit();
    try executeBatchPlan(io, allocator, plan.items, conversion, args[2..]);
}

fn expandedBatchConversionCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    target_index: usize,
) !void {
    if (target_index == 0 or target_index >= args.len) return batch.BatchError.InvalidPattern;
    const target_extension = args[target_index];
    const input_paths = args[0..target_index];
    const conversion = inferConversionExtensions(
        std.fs.path.extension(input_paths[0]),
        target_extension,
    ) orelse {
        usage();
        return error.InvalidCommand;
    };
    for (input_paths[1..]) |path| {
        const candidate = inferConversionExtensions(
            std.fs.path.extension(path),
            target_extension,
        ) orelse {
            usage();
            return error.InvalidCommand;
        };
        if (candidate != conversion) {
            usage();
            return error.InvalidCommand;
        }
    }

    var plan = batch.buildExplicitPlan(allocator, input_paths, target_extension) catch |err| {
        if (err == batch.BatchError.OutputCollision) {
            std.debug.print("batch: multiple inputs map to the same target extension '{s}'\n", .{target_extension});
        }
        return err;
    };
    defer plan.deinit();
    try executeBatchPlan(io, allocator, plan.items, conversion, args[target_index + 1 ..]);
}

fn executeBatchPlan(
    io: std.Io,
    allocator: std.mem.Allocator,
    items: []const batch.Item,
    conversion: InferredConversion,
    options: []const []const u8,
) !void {
    var file_args: std.ArrayList([]const u8) = .empty;
    defer file_args.deinit(allocator);
    try file_args.ensureTotalCapacity(allocator, options.len + 2);
    for (items) |item| {
        file_args.clearRetainingCapacity();
        try file_args.appendSlice(allocator, &.{ item.input_path, item.output_path });
        try file_args.appendSlice(allocator, options);
        switch (conversion) {
            .tiff_to_jp2 => try tiffToJp2Command(io, allocator, file_args.items),
            .bmp_to_jp2 => try bmpToJp2Command(io, allocator, file_args.items),
            .png_to_jp2 => try pngToJp2Command(io, allocator, file_args.items),
            .jpeg_to_jp2 => try jpegToJp2Command(io, allocator, file_args.items),
            .dng_to_jp2 => try dngToJp2Command(io, allocator, file_args.items),
            .exr_to_jp2 => try exrToJp2Command(io, allocator, file_args.items),
            .jp2_to_tiff => try decodeTempJp2Command(io, allocator, file_args.items),
            .j2k_to_pgx => try j2kToPgxCommand(io, allocator, file_args.items),
            .j2k_to_zraw => try j2kToZrawCommand(io, allocator, file_args.items),
        }
    }
    std.debug.print("batch converted {} file{s}\n", .{
        items.len,
        if (items.len == 1) "" else "s",
    });
}

fn encodeCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        usage();
        return error.InvalidCommand;
    }

    var options = codec.Options{};
    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--wavelet")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.wavelet = try parseWavelet(args[index]);
        } else if (std.mem.eql(u8, args[index], "--levels")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.levels = try std.fmt.parseInt(u8, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--quant")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.quant_step = try std.fmt.parseFloat(f32, args[index]);
        } else {
            return error.UnknownOption;
        }
        index += 1;
    }

    var input = try image.readPgm(io, allocator, args[0]);
    defer input.deinit();

    const encoded = try codec.encodeImage(allocator, input, options);
    defer allocator.free(encoded);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = encoded });
    std.debug.print(
        "encoded {s} -> {s} using wavelet {s}, levels {}, quant {d:.3}\n",
        .{ args[0], args[1], options.wavelet.label(), options.levels, options.quant_step },
    );
}

fn decodeCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 2) {
        usage();
        return error.InvalidCommand;
    }

    const max_file_size = 512 * 1024 * 1024;
    const encoded = try std.Io.Dir.cwd().readFileAlloc(
        io,
        args[0],
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(encoded);

    var decoded = try codec.decodeImage(allocator, encoded);
    defer decoded.deinit();

    try image.writePgm(io, decoded.image, args[1]);
    std.debug.print(
        "decoded {s} -> {s} using wavelet {s}, levels {}, quant {d:.3}\n",
        .{
            args[0],
            args[1],
            decoded.options.wavelet.label(),
            decoded.options.levels,
            decoded.options.quant_step,
        },
    );
}

fn tiffInfoCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1) {
        usage();
        return error.InvalidCommand;
    }

    var decoded = try tiff.read(io, allocator, args[0]);
    defer decoded.deinit();

    switch (decoded) {
        .rgb => |rgb| std.debug.print(
            "TIFF RGB: {s}: {}x{}, {} bits/channel, {} samples\n",
            .{ args[0], rgb.width, rgb.height, rgb.bit_depth, rgb.samples.len },
        ),
        .grayscale => |gray| std.debug.print(
            "TIFF grayscale ({s}): {s}: {}x{}, {} bits, {} samples\n",
            .{
                if (gray.white_is_zero) "WhiteIsZero" else "BlackIsZero",
                args[0],
                gray.width,
                gray.height,
                gray.bit_depth,
                gray.samples.len,
            },
        ),
        .alpha => |alpha| std.debug.print(
            "TIFF {s}+alpha ({s}, {s}): {s}: {}x{}, {} bits/channel, {} samples\n",
            .{
                @tagName(alpha.color_space),
                alpha.alpha_mode.label(),
                if (alpha.color_space == .rgb)
                    "RGB"
                else if (alpha.white_is_zero)
                    "WhiteIsZero"
                else
                    "BlackIsZero",
                args[0],
                alpha.width,
                alpha.height,
                alpha.bit_depth,
                alpha.samples.len,
            },
        ),
    }
}

fn dngInfoCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1) {
        usage();
        return error.InvalidCommand;
    }

    const max_file_size = 1024 * 1024 * 1024;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        args[0],
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);

    const info = try dng.parseInfo(bytes);
    std.debug.print("DNG/TIFF: {s}: endian {s}, IFDs {}\n", .{ args[0], info.endian.label(), info.ifd_count });
    if (info.dng_version) |version| {
        std.debug.print("  DNG version {}.{}.{}.{}\n", .{ version.bytes[0], version.bytes[1], version.bytes[2], version.bytes[3] });
    }
    if (info.dng_backward_version) |version| {
        std.debug.print("  DNG backward version {}.{}.{}.{}\n", .{ version.bytes[0], version.bytes[1], version.bytes[2], version.bytes[3] });
    }
    if (info.make) |make| std.debug.print("  make {s}\n", .{make});
    if (info.model) |model| std.debug.print("  model {s}\n", .{model});
    if (info.unique_camera_model) |camera| std.debug.print("  unique camera {s}\n", .{camera});
    if (info.cfa_repeat) |repeat| std.debug.print("  CFA repeat {}x{}\n", .{ repeat[0], repeat[1] });
    if (info.cfa_pattern) |pattern| {
        std.debug.print("  CFA pattern", .{});
        for (pattern[0..info.cfa_pattern_count]) |value| std.debug.print(" {}", .{value});
        std.debug.print("\n", .{});
    }
    for (info.ifds[0..info.ifd_count], 0..) |ifd, index| {
        std.debug.print(
            "  IFD {}{s}: offset {}, {}x{}, bits {}, samples {}, compression {}, photometric {}, sample-format {}, subIFDs {}\n",
            .{
                index,
                if (ifd.is_subifd) " sub" else "",
                ifd.offset,
                ifd.width orelse 0,
                ifd.height orelse 0,
                ifd.bits_per_sample orelse 0,
                ifd.samples_per_pixel orelse 0,
                ifd.compression orelse 0,
                ifd.photometric orelse 0,
                ifd.sample_format orelse 1,
                ifd.subifd_count,
            },
        );
    }
}

const RasterInput = enum {
    tiff,
    bmp,
    png,
    jpeg,
    dng,
    openexr,

    fn label(self: RasterInput) []const u8 {
        return switch (self) {
            .tiff => "TIFF",
            .bmp => "BMP",
            .png => "PNG",
            .jpeg => "JPEG",
            .dng => "DNG",
            .openexr => "OpenEXR",
        };
    }
};

fn tiffToJp2Command(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    return rasterToJp2Command(io, allocator, args, .tiff);
}

fn bmpToJp2Command(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    return rasterToJp2Command(io, allocator, args, .bmp);
}

fn pngToJp2Command(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    return rasterToJp2Command(io, allocator, args, .png);
}

fn jpegToJp2Command(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    return rasterToJp2Command(io, allocator, args, .jpeg);
}

fn dngToJp2Command(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    return rasterToJp2Command(io, allocator, args, .dng);
}

fn exrToJp2Command(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    return rasterToJp2Command(io, allocator, args, .openexr);
}

fn rasterToJp2Command(
    io: std.Io,
    allocator: std.mem.Allocator,
    args: []const []const u8,
    input: RasterInput,
) !void {
    if (args.len < 2) {
        usage();
        return error.InvalidCommand;
    }

    var options = codestream.LosslessOptions{};
    options.threads = defaultThreadCount();
    var poc_storage: [64]codestream.PocRecord = undefined;
    var tile_parts_explicit = false;
    var mct_explicit = false;
    var show_timings = false;
    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--levels")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.levels = try std.fmt.parseInt(u8, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--block")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            const edge = try std.fmt.parseInt(u16, args[index], 10);
            options.block_width = edge;
            options.block_height = edge;
        } else if (std.mem.eql(u8, args[index], "--tile")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            const tile = try parseU32Pair(args[index]);
            options.tile_width = tile.first;
            options.tile_height = tile.second;
        } else if (std.mem.eql(u8, args[index], "--progression")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.progression = try parseProgression(args[index]);
        } else if (std.mem.eql(u8, args[index], "--poc")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            if (options.poc_records.len != 0) return error.InvalidValue;
            options.poc_records = try parsePocRecords(args[index], &poc_storage);
        } else if (std.mem.eql(u8, args[index], "--poc-location")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            if (std.mem.eql(u8, args[index], "main")) {
                options.poc_in_tile_header = false;
            } else if (std.mem.eql(u8, args[index], "tile")) {
                options.poc_in_tile_header = true;
            } else {
                return error.InvalidValue;
            }
        } else if (std.mem.eql(u8, args[index], "--mct")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.mct = try parseMct(args[index]);
            mct_explicit = true;
        } else if (std.mem.eql(u8, args[index], "--transform")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.transform = try parseJpeg2000Transform(args[index]);
        } else if (std.mem.eql(u8, args[index], "--qstyle")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.quantization = try parseQuantizationStyle(args[index]);
        } else if (std.mem.eql(u8, args[index], "--guard-bits")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.guard_bits = try std.fmt.parseInt(u8, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--resolutions")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            const resolutions = try std.fmt.parseInt(u8, args[index], 10);
            if (resolutions == 0) return error.InvalidValue;
            options.levels = resolutions - 1;
        } else if (std.mem.eql(u8, args[index], "--precincts")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            try parsePrecincts(args[index], &options);
        } else if (std.mem.eql(u8, args[index], "--layers")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.layers = try std.fmt.parseInt(u16, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--sop")) {
            options.sop = true;
        } else if (std.mem.eql(u8, args[index], "--no-sop")) {
            options.sop = false;
        } else if (std.mem.eql(u8, args[index], "--eph")) {
            options.eph = true;
        } else if (std.mem.eql(u8, args[index], "--no-eph")) {
            options.eph = false;
        } else if (std.mem.eql(u8, args[index], "--ppm")) {
            options.ppm = true;
        } else if (std.mem.eql(u8, args[index], "--no-ppm")) {
            options.ppm = false;
        } else if (std.mem.eql(u8, args[index], "--ppt")) {
            options.ppt = true;
        } else if (std.mem.eql(u8, args[index], "--no-ppt")) {
            options.ppt = false;
        } else if (std.mem.eql(u8, args[index], "--bypass")) {
            options.bypass = true;
        } else if (std.mem.eql(u8, args[index], "--no-bypass")) {
            options.bypass = false;
        } else if (std.mem.eql(u8, args[index], "--reset-context")) {
            options.reset_context = true;
        } else if (std.mem.eql(u8, args[index], "--no-reset-context")) {
            options.reset_context = false;
        } else if (std.mem.eql(u8, args[index], "--terminate-all")) {
            options.terminate_all = true;
        } else if (std.mem.eql(u8, args[index], "--no-terminate-all")) {
            options.terminate_all = false;
        } else if (std.mem.eql(u8, args[index], "--vertical-causal")) {
            options.vertical_causal = true;
        } else if (std.mem.eql(u8, args[index], "--no-vertical-causal")) {
            options.vertical_causal = false;
        } else if (std.mem.eql(u8, args[index], "--predictable-termination")) {
            options.predictable_termination = true;
        } else if (std.mem.eql(u8, args[index], "--no-predictable-termination")) {
            options.predictable_termination = false;
        } else if (std.mem.eql(u8, args[index], "--segmentation-symbols")) {
            options.segmentation_symbols = true;
        } else if (std.mem.eql(u8, args[index], "--no-segmentation-symbols")) {
            options.segmentation_symbols = false;
        } else if (std.mem.eql(u8, args[index], "--tlm")) {
            options.tlm = true;
        } else if (std.mem.eql(u8, args[index], "--no-tlm")) {
            options.tlm = false;
        } else if (std.mem.eql(u8, args[index], "--tile-parts")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            tile_parts_explicit = true;
            if (std.mem.eql(u8, args[index], "none") or std.mem.eql(u8, args[index], "0")) {
                options.tile_part_divisions = null;
            } else {
                if (args[index].len != 1) return error.InvalidValue;
                options.tile_part_divisions = args[index][0];
            }
        } else if (std.mem.eql(u8, args[index], "--threads")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.threads = try parseThreadCount(args[index]);
        } else if (std.mem.eql(u8, args[index], "--t1-backend")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.t1_backend = try parseT1Backend(args[index]);
        } else if (std.mem.eql(u8, args[index], "--timings")) {
            show_timings = true;
        } else if (std.mem.eql(u8, args[index], "--debug-temp-sidecar")) {
            options.emit_temporary_payload_sidecar = true;
        } else if (std.mem.eql(u8, args[index], "--no-debug-temp-sidecar")) {
            options.emit_temporary_payload_sidecar = false;
        } else if (std.mem.eql(u8, args[index], "--rates") or std.mem.eql(u8, args[index], "--rate")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            try parseRates(args[index], &options);
        } else {
            return error.UnknownOption;
        }
        index += 1;
    }
    if (options.poc_records.len != 0 and !tile_parts_explicit) {
        options.tile_part_divisions = null;
    }

    var command_timings = RasterToJp2Timings{};
    const read_start = monotonicNs();
    var decoded: tiff.DecodedImage = switch (input) {
        .tiff => try tiff.read(io, allocator, args[0]),
        .bmp => .{ .rgb = try bmp.read(io, allocator, args[0]) },
        .png => try png.read(io, allocator, args[0]),
        .jpeg => try jpeg.readPreservingMetadata(io, allocator, args[0]),
        .dng => .{ .rgb = try dng.read(io, allocator, args[0]) },
        .openexr => .{ .rgb = try openexr.read(io, allocator, args[0]) },
    };
    defer decoded.deinit();
    command_timings.input_read_ns = elapsedNs(read_start);

    var encode_timings = codestream.EncodeTimings{};
    var width: usize = 0;
    var height: usize = 0;
    var bit_depth: u8 = 0;
    var components: u16 = 0;
    var wrapped: []u8 = undefined;
    switch (decoded) {
        .rgb => |rgb| {
            width = rgb.width;
            height = rgb.height;
            bit_depth = rgb.bit_depth;
            components = 3;

            const encode_start = monotonicNs();
            const j2k = if (show_timings)
                try codestream.encodeLosslessWithOptionsProfiled(allocator, rgb, options, &encode_timings)
            else
                try codestream.encodeLosslessWithOptions(allocator, rgb, options);
            defer allocator.free(j2k);
            command_timings.codestream_ns = elapsedNs(encode_start);

            const wrap_start = monotonicNs();
            wrapped = try jp2.wrapRgbCodestream(allocator, rgb, j2k);
            command_timings.jp2_wrap_ns = elapsedNs(wrap_start);
        },
        .grayscale => |gray| {
            if (!mct_explicit) options.mct = .none;
            width = gray.width;
            height = gray.height;
            bit_depth = gray.bit_depth;
            components = 1;

            var normalized = gray;
            var normalized_samples: ?[]u16 = null;
            defer if (normalized_samples) |samples| allocator.free(samples);
            if (gray.white_is_zero) {
                const samples = try allocator.alloc(u16, gray.samples.len);
                normalized_samples = samples;
                const max_sample: u16 = if (gray.bit_depth == 8) 255 else std.math.maxInt(u16);
                for (gray.samples, samples) |sample, *out_sample| {
                    if (sample > max_sample) return error.InvalidValue;
                    out_sample.* = max_sample - sample;
                }
                normalized.samples = samples;
                normalized.white_is_zero = false;
            }

            const encode_start = monotonicNs();
            const j2k = try codestream.encodeLosslessGrayWithOptions(allocator, normalized, options);
            defer allocator.free(j2k);
            command_timings.codestream_ns = elapsedNs(encode_start);
            encode_timings.total_ns = command_timings.codestream_ns;

            const wrap_start = monotonicNs();
            wrapped = try jp2.wrapGrayCodestream(allocator, normalized, j2k);
            command_timings.jp2_wrap_ns = elapsedNs(wrap_start);
        },
        .alpha => |alpha| {
            if (!mct_explicit) {
                options.mct = if (alpha.color_space == .rgb) .rct else .none;
            }
            width = alpha.width;
            height = alpha.height;
            bit_depth = alpha.bit_depth;
            components = @intCast(alpha.componentCount());

            var planes = try alpha.toSamplePlanes(allocator);
            defer planes.deinit();
            const encode_start = monotonicNs();
            const j2k = try codestream.encodeLosslessPlanarWithOptions(allocator, planes, options);
            defer allocator.free(j2k);
            command_timings.codestream_ns = elapsedNs(encode_start);
            encode_timings.total_ns = command_timings.codestream_ns;

            const wrap_start = monotonicNs();
            wrapped = try jp2.wrapPlanarAlphaCodestream(
                allocator,
                planes,
                alpha.alpha_mode,
                alpha.icc_profile,
                j2k,
            );
            command_timings.jp2_wrap_ns = elapsedNs(wrap_start);
        },
    }
    defer allocator.free(wrapped);

    var metadata_wrapped: ?[]u8 = null;
    defer if (metadata_wrapped) |bytes| allocator.free(bytes);
    const source_metadata = decodedMetadata(decoded);
    if (source_metadata.exif != null or source_metadata.xmp != null or source_metadata.iptc != null) {
        metadata_wrapped = try jp2.attachMetadata(allocator, wrapped, source_metadata);
    }
    const output_bytes = metadata_wrapped orelse wrapped;

    const write_start = monotonicNs();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = output_bytes });
    command_timings.write_ns = elapsedNs(write_start);
    command_timings.total_ns = command_timings.input_read_ns +
        command_timings.codestream_ns +
        command_timings.jp2_wrap_ns +
        command_timings.write_ns;

    std.debug.print(
        "wrote JP2 {s} -> {s} ({}x{}, {} component{s}, {} bits/component, levels {}, tile {}x{}, block {}x{}, progression {s}, POC records {} ({s}), layers {}, MCT {s}, transform {s}, QCD {s}/guard {}, tile-parts {s}, TLM {}, PPM {}, PPT {}, T1 {s}, threads {}, debug sidecar {})\n",
        .{
            args[0],
            args[1],
            width,
            height,
            components,
            if (components == 1) "" else "s",
            bit_depth,
            options.levels,
            options.tile_width,
            options.tile_height,
            options.block_width,
            options.block_height,
            options.progression.label(),
            options.poc_records.len,
            if (options.poc_records.len == 0) "none" else if (options.poc_in_tile_header) "tile header" else "main header",
            options.layers,
            options.mct.label(),
            options.transform.label(),
            options.quantization.label(),
            options.guard_bits,
            tilePartDivisionLabel(options.tile_part_divisions),
            options.tlm,
            options.ppm,
            options.ppt,
            t1BackendLabel(options.t1_backend),
            options.threads,
            options.emit_temporary_payload_sidecar,
        },
    );
    if (show_timings) {
        printRasterToJp2Timings(command_timings, encode_timings, components, input.label());
    }
}

fn decodedMetadata(decoded: tiff.DecodedImage) jp2.Metadata {
    const metadata = switch (decoded) {
        .rgb => |rgb| rgb.metadata,
        .grayscale => |gray| gray.metadata,
        .alpha => |alpha| alpha.metadata,
    };
    return .{
        .exif = metadata.exif,
        .xmp = metadata.xmp,
        .iptc = metadata.iptc,
    };
}

fn jp2InfoCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len != 1) {
        usage();
        return error.InvalidCommand;
    }

    const max_file_size = 1024 * 1024 * 1024;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        args[0],
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);

    const info = try jp2.parseInfo(bytes);
    std.debug.print(
        "JP2: {s}: {}x{}, {} codestream component{s}, {} output component{s}",
        .{
            args[0],
            info.width,
            info.height,
            info.components,
            if (info.components == 1) "" else "s",
            info.output_components,
            if (info.output_components == 1) "" else "s",
        },
    );
    if (info.bits_per_component != 0) {
        std.debug.print(", {} bits/component", .{info.bits_per_component});
    } else {
        std.debug.print(", component bits [", .{});
        for (info.component_bit_depths[0..info.components], 0..) |bit_depth, component| {
            if (component != 0) std.debug.print(",", .{});
            std.debug.print("{}", .{bit_depth});
        }
        std.debug.print("]", .{});
    }
    var has_subsampling = false;
    for (0..info.components) |component| {
        if (info.component_xrsiz[component] != 1 or info.component_yrsiz[component] != 1) {
            has_subsampling = true;
            break;
        }
    }
    if (has_subsampling) {
        std.debug.print(", sampling [", .{});
        for (0..info.components) |component| {
            if (component != 0) std.debug.print(",", .{});
            std.debug.print("{}x{}", .{ info.component_xrsiz[component], info.component_yrsiz[component] });
        }
        std.debug.print("]", .{});
    }
    if (info.image_origin_x != 0 or info.image_origin_y != 0 or
        info.tile_origin_x != info.image_origin_x or info.tile_origin_y != info.image_origin_y)
    {
        std.debug.print(
            ", image origin {}x{}, tile origin {}x{}",
            .{ info.image_origin_x, info.image_origin_y, info.tile_origin_x, info.tile_origin_y },
        );
    }
    std.debug.print(
        ", color {s}, {} codestream bytes, ICC {s}",
        .{
            info.color_space.label(),
            info.codestream_bytes,
            if (info.has_icc_profile) "yes" else "no",
        },
    );
    if (info.has_icc_profile) {
        std.debug.print(" ({} bytes)", .{info.icc_profile_bytes});
    }
    if (info.alpha_mode) |alpha_mode| {
        std.debug.print(", alpha {s}", .{alpha_mode.label()});
    }
    if (info.has_palette) {
        std.debug.print(
            ", palette {}x3 at {} bits",
            .{ info.palette_entries, info.palette_bits_per_component },
        );
    }
    std.debug.print("\n", .{});
}

fn jp2StatsCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) {
        usage();
        return error.InvalidCommand;
    }

    var options = codestream.DecodeOptions{};
    var index: usize = 1;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--t1-backend")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.t1_backend = try parseT1Backend(args[index]);
        } else {
            return error.UnknownOption;
        }
        index += 1;
    }

    const max_file_size = 1024 * 1024 * 1024;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        args[0],
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);

    const j2k = try jp2.extractCodestream(bytes);
    const stats = try codestream.analyzeLosslessTemporaryWithOptions(j2k, options);
    printTemporaryStats(args[0], stats);
}

fn j2kToPgxCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        usage();
        return error.InvalidCommand;
    }
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(args[1]), ".pgx")) {
        return error.InvalidValue;
    }

    var options = codestream.DecodeOptions{};
    options.threads = defaultThreadCount();
    var component: usize = 0;
    var byte_order: codestream.NativePgxByteOrder = .most_significant_first;
    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--component")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            component = try std.fmt.parseInt(usize, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--reduce")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.resolution_reduction = try std.fmt.parseInt(u8, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--threads")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.threads = try parseThreadCount(args[index]);
        } else if (std.mem.eql(u8, args[index], "--t1-backend")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.t1_backend = try parseT1Backend(args[index]);
        } else if (std.mem.eql(u8, args[index], "--pgx-order")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            if (std.ascii.eqlIgnoreCase(args[index], "ML") or
                std.ascii.eqlIgnoreCase(args[index], "big"))
            {
                byte_order = .most_significant_first;
            } else if (std.ascii.eqlIgnoreCase(args[index], "LM") or
                std.ascii.eqlIgnoreCase(args[index], "little"))
            {
                byte_order = .least_significant_first;
            } else {
                return error.InvalidValue;
            }
        } else {
            return error.UnknownOption;
        }
        index += 1;
    }

    const max_file_size = 1024 * 1024 * 1024;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        args[0],
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);

    var layout = try codestream.inspectNativeCodestreamLayout(allocator, bytes, .{});
    defer layout.deinit();
    if (component >= layout.components.len) return codestream.NativeSampleError.InvalidLayout;

    var decoded = try codestream.decodeLosslessNativeWithOptions(
        allocator,
        bytes,
        options,
        .{},
    );
    defer decoded.deinit();
    const pgx = try decoded.encodePgx(allocator, component, byte_order);
    defer allocator.free(pgx);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = pgx });

    const plane = decoded.planes[component];
    std.debug.print(
        "decoded raw JPEG 2000 {s} component {} -> {s} ({}x{}, {s} {} bits, reduction {}, threads {}, PGX {s})\n",
        .{
            args[0],
            component,
            args[1],
            plane.layout.width,
            plane.layout.height,
            if (plane.layout.signed) "signed" else "unsigned",
            plane.layout.precision,
            options.resolution_reduction,
            options.threads,
            if (byte_order == .most_significant_first) "ML" else "LM",
        },
    );
}

fn j2kToZrawCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        usage();
        return error.InvalidCommand;
    }
    if (!std.ascii.eqlIgnoreCase(std.fs.path.extension(args[1]), ".zraw")) {
        return error.InvalidValue;
    }

    var options = codestream.DecodeOptions{};
    options.threads = defaultThreadCount();
    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--reduce")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.resolution_reduction = try std.fmt.parseInt(u8, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--threads")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.threads = try parseThreadCount(args[index]);
        } else if (std.mem.eql(u8, args[index], "--t1-backend")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.t1_backend = try parseT1Backend(args[index]);
        } else {
            return error.UnknownOption;
        }
        index += 1;
    }

    const max_file_size = 1024 * 1024 * 1024;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        args[0],
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);

    var decoded = try codestream.decodeLosslessNativeWithOptions(
        allocator,
        bytes,
        options,
        .{},
    );
    defer decoded.deinit();
    const zraw = try decoded.encodeRawPlanar(allocator);
    defer allocator.free(zraw);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = zraw });

    std.debug.print(
        "decoded raw JPEG 2000 {s} -> {s} ({} components, reference {}x{}, reduction {}, threads {}, canonical ZRAW)\n",
        .{
            args[0],
            args[1],
            decoded.componentCount(),
            decoded.reference_x1 - decoded.reference_x0,
            decoded.reference_y1 - decoded.reference_y0,
            options.resolution_reduction,
            options.threads,
        },
    );
}

fn decodeTempJp2Command(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        usage();
        return error.InvalidCommand;
    }

    var options = codestream.DecodeOptions{};
    options.threads = defaultThreadCount();
    var show_timings = false;
    var convert_to_srgb = false;
    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--threads")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.threads = try parseThreadCount(args[index]);
        } else if (std.mem.eql(u8, args[index], "--t1-backend")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.t1_backend = try parseT1Backend(args[index]);
        } else if (std.mem.eql(u8, args[index], "--timings")) {
            show_timings = true;
        } else if (std.mem.eql(u8, args[index], "--convert-to-srgb")) {
            convert_to_srgb = true;
        } else {
            return error.UnknownOption;
        }
        index += 1;
    }

    var command_timings = DecodeTempJp2Timings{};
    const max_file_size = 1024 * 1024 * 1024;
    const read_start = monotonicNs();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        args[0],
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(bytes);
    command_timings.jp2_read_ns = elapsedNs(read_start);

    const extract_start = monotonicNs();
    const info = try jp2.parseInfo(bytes);
    const j2k = try jp2.extractCodestream(bytes);
    command_timings.codestream_extract_ns = elapsedNs(extract_start);
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
    const decode_start = monotonicNs();
    var decoded: tiff.DecodedImage = if (info.has_palette) palette: {
        var indexed = if (show_timings)
            try codestream.decodeLosslessGrayWithOptionsProfiled(allocator, j2k, options, &decode_timings)
        else
            try codestream.decodeLosslessGrayWithOptions(allocator, j2k, options);
        defer indexed.deinit();
        var table = (try jp2.extractPalette(allocator, bytes)) orelse
            return jp2.Jp2Error.MissingRequiredBox;
        defer table.deinit();
        break :palette .{ .rgb = try table.expand(allocator, indexed) };
    } else switch (info.components) {
        1 => .{ .grayscale = if (show_timings)
            try codestream.decodeLosslessGrayWithOptionsProfiled(allocator, j2k, options, &decode_timings)
        else
            try codestream.decodeLosslessGrayWithOptions(allocator, j2k, options) },
        3 => rgb: {
            if (info.color_space == .sycc) {
                const chroma_sampling = info.componentSampling(1) orelse
                    return error.UnsupportedComponentCount;
                var planes = if (show_timings)
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
                var planes = if (show_timings)
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
            break :rgb .{ .rgb = if (show_timings)
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
    command_timings.codestream_decode_ns = elapsedNs(decode_start);

    const icc_start = monotonicNs();
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
    command_timings.icc_extract_ns = elapsedNs(icc_start);

    const write_start = monotonicNs();
    switch (decoded) {
        .rgb => |rgb| try tiff.writeRgb(io, allocator, rgb, args[1]),
        .grayscale => |gray| try tiff.writeGray(io, allocator, gray, args[1]),
        .alpha => |alpha| try tiff.writeAlpha(io, allocator, alpha, args[1]),
    }
    command_timings.tiff_write_ns = elapsedNs(write_start);
    command_timings.total_ns = command_timings.jp2_read_ns +
        command_timings.codestream_extract_ns +
        command_timings.codestream_decode_ns +
        command_timings.icc_extract_ns +
        command_timings.tiff_write_ns;

    std.debug.print(
        "decoded JP2 {s} -> {s} ({}x{}, {} output component{s}, {} bits/component, threads {})\n",
        .{
            args[0],
            args[1],
            info.width,
            info.height,
            info.output_components,
            if (info.output_components == 1) "" else "s",
            if (info.has_palette) info.palette_bits_per_component else info.bits_per_component,
            options.threads,
        },
    );
    if (show_timings) {
        printDecodeTempJp2Timings(command_timings, decode_timings);
    }
}

fn printTemporaryStats(path: []const u8, stats: codestream.TemporaryStats) void {
    std.debug.print(
        "JP2 payload stats: {s}: {}x{}, {} component{s}, {} bits/component, levels {}, layers {}, block {}x{}, tile-parts {s}",
        .{
            path,
            stats.width,
            stats.height,
            stats.component_count,
            if (stats.component_count == 1) "" else "s",
            stats.bit_depth,
            stats.levels,
            stats.layers,
            stats.block_width,
            stats.block_height,
            tilePartDivisionLabel(stats.tile_part_divisions),
        },
    );
    if (stats.tile_part_plan_count > 0) {
        std.debug.print(", plan ", .{});
        var index: usize = 0;
        while (index < stats.tile_part_plan_count) : (index += 1) {
            if (index > 0) std.debug.print(",", .{});
            std.debug.print("R{}", .{stats.tile_part_plan[index]});
        }
    }
    if (stats.packet_plan_count > 0) {
        std.debug.print(", packets {}", .{stats.packet_count});
    }
    std.debug.print("\n", .{});
    if (stats.packet_plan_count > 0) {
        for (stats.packet_plan[0..stats.packet_plan_count], 0..) |resolution, index| {
            std.debug.print(
                "  R{}: {}x{}, precinct {}x{}, grid {}x{}, packets {}\n",
                .{
                    index,
                    resolution.width,
                    resolution.height,
                    resolution.precinct_width,
                    resolution.precinct_height,
                    resolution.precincts_x,
                    resolution.precincts_y,
                    resolution.packets,
                },
            );
        }
    }
    std.debug.print(
        "  codestream {} bytes, temporary payload {} bytes\n",
        .{ stats.codestream_bytes, stats.payload_bytes },
    );
    if (stats.sod_packets > 0) {
        std.debug.print(
            "  SOD packet stream: {} packets, {} bytes\n",
            .{ stats.sod_packets, stats.sod_packet_bytes },
        );
    }
    if (stats.t2_audited_packets > 0) {
        std.debug.print(
            "  T2 header audit: {} packets, present {}, absent {}, geometry-empty {}, headers {} B, payload {} B, included blocks {}, assembled blocks {}, passes {}, T1-ready {}\n",
            .{
                stats.t2_audited_packets,
                stats.t2_present_packets,
                stats.t2_absent_packets,
                stats.t2_geometry_empty_packets,
                stats.t2_header_bytes,
                stats.t2_payload_bytes,
                stats.t2_included_blocks,
                stats.t2_assembled_blocks,
                stats.t2_assembled_passes,
                stats.t2_t1_ready_blocks,
            },
        );
    }
    if (stats.rpcl_shadow_packets > 0) {
        std.debug.print(
            "  BP8 shadow stream: {} packets, {} bytes\n",
            .{ stats.rpcl_shadow_packets, stats.rpcl_shadow_bytes },
        );
    }

    const total = totalComponentStats(stats);
    printComponentStats("total", total);
    if (stats.component_count == 1) {
        printComponentStats("Gray", stats.components[0]);
    } else {
        printComponentStats("Y", stats.components[0]);
        printComponentStats("Cb", stats.components[1]);
        printComponentStats("Cr", stats.components[2]);
    }
}

fn tilePartDivisionLabel(value: ?u8) []const u8 {
    return switch (value orelse 0) {
        0 => "none",
        'R' => "R/resolution",
        'L' => "L/layer",
        'C' => "C/component",
        'P' => "P/precinct",
        else => "unknown",
    };
}

fn printComponentStats(label: []const u8, stats: codestream.ComponentStats) void {
    std.debug.print(
        "  {s}: blocks {} active {} empty {}, coeffs {} active-coeffs {} nonzero {}, max bitplanes {}, T1 passes {}\n",
        .{
            label,
            stats.blocks,
            stats.active_blocks,
            stats.empty_blocks,
            stats.coeffs,
            stats.active_coeffs,
            stats.non_zero_coeffs,
            stats.max_bitplanes,
            stats.coding_passes,
        },
    );

    if (stats.ebcot_segments.blocks != 0) {
        std.debug.print(
            "    EBCOT shadow: blocks {}, passes {}, symbols {}, MQ bytes {} B\n",
            .{
                stats.ebcot_segments.blocks,
                stats.ebcot_segments.passes,
                stats.ebcot_segments.symbols,
                stats.ebcot_segments.mq_bytes,
            },
        );
    }

    const pass_labels = [_][]const u8{ "sig", "ref", "cleanup" };
    for (stats.pass_streams, 0..) |stream, index| {
        printStreamStats(pass_labels[index], stream);
    }

    const method_labels = [_][]const u8{ "raw", "rle", "bit-rle", "arith" };
    for (stats.method_streams, 0..) |stream, index| {
        if (stream.streams != 0) printStreamStats(method_labels[index], stream);
    }

    for (stats.quality_layers, 0..) |layer, index| {
        if (layer.blocks == 0) continue;
        std.debug.print(
            "    layer {}: blocks {}, cumulative passes {}, cumulative bytes {} B\n",
            .{ index + 1, layer.blocks, layer.cumulative_passes, layer.cumulative_bytes },
        );
    }
}

fn printStreamStats(label: []const u8, stats: codestream.EntropyStreamStats) void {
    std.debug.print(
        "    {s}: streams {}, raw {} B, encoded {} B, ratio {d:.3}\n",
        .{ label, stats.streams, stats.raw_bytes, stats.encoded_bytes, compressionRatio(stats) },
    );
}

fn compressionRatio(stats: codestream.EntropyStreamStats) f64 {
    if (stats.raw_bytes == 0) return 0.0;
    return @as(f64, @floatFromInt(stats.encoded_bytes)) / @as(f64, @floatFromInt(stats.raw_bytes));
}

fn totalComponentStats(stats: codestream.TemporaryStats) codestream.ComponentStats {
    var total = codestream.ComponentStats{};
    for (stats.components) |component| {
        total.blocks += component.blocks;
        total.active_blocks += component.active_blocks;
        total.empty_blocks += component.empty_blocks;
        total.coeffs += component.coeffs;
        total.active_coeffs += component.active_coeffs;
        total.non_zero_coeffs += component.non_zero_coeffs;
        total.max_bitplanes = @max(total.max_bitplanes, component.max_bitplanes);
        total.coding_passes += component.coding_passes;
        total.ebcot_segments.blocks += component.ebcot_segments.blocks;
        total.ebcot_segments.passes += component.ebcot_segments.passes;
        total.ebcot_segments.symbols += component.ebcot_segments.symbols;
        total.ebcot_segments.mq_bytes += component.ebcot_segments.mq_bytes;
        for (component.quality_layers, 0..) |layer, index| {
            total.quality_layers[index].blocks += layer.blocks;
            total.quality_layers[index].cumulative_passes += layer.cumulative_passes;
            total.quality_layers[index].cumulative_bytes += layer.cumulative_bytes;
        }
        for (component.pass_streams, 0..) |stream, index| {
            total.pass_streams[index].streams += stream.streams;
            total.pass_streams[index].raw_bytes += stream.raw_bytes;
            total.pass_streams[index].encoded_bytes += stream.encoded_bytes;
        }
        for (component.method_streams, 0..) |stream, index| {
            total.method_streams[index].streams += stream.streams;
            total.method_streams[index].raw_bytes += stream.raw_bytes;
            total.method_streams[index].encoded_bytes += stream.encoded_bytes;
        }
    }
    return total;
}

const RasterToJp2Timings = struct {
    total_ns: u64 = 0,
    input_read_ns: u64 = 0,
    codestream_ns: u64 = 0,
    jp2_wrap_ns: u64 = 0,
    write_ns: u64 = 0,
};

const DecodeTempJp2Timings = struct {
    total_ns: u64 = 0,
    jp2_read_ns: u64 = 0,
    codestream_extract_ns: u64 = 0,
    codestream_decode_ns: u64 = 0,
    icc_extract_ns: u64 = 0,
    tiff_write_ns: u64 = 0,
};

fn printRasterToJp2Timings(
    command: RasterToJp2Timings,
    encode: codestream.EncodeTimings,
    components: u16,
    input_label: []const u8,
) void {
    const total = command.total_ns;
    std.debug.print("timings:\n", .{});
    printTiming("total", total, total);
    var read_label_buffer: [32]u8 = undefined;
    const read_label = std.fmt.bufPrint(&read_label_buffer, "{s} read", .{input_label}) catch "input read";
    printTiming(read_label, command.input_read_ns, total);
    printTiming("codestream", command.codestream_ns, total);
    if (components == 3) {
        printTiming("  MCT", encode.color_transform_ns, total);
        printTiming("  DWT", encode.wavelet_ns, total);
        printTiming("  block payload", encode.payload_ns, total);
        printEncodeT1PassProfile(encode);
        printTiming("  markers/write SOD", encode.marker_ns, total);
    }
    printTiming("JP2 wrap", command.jp2_wrap_ns, total);
    printTiming("disk write", command.write_ns, total);
}

fn printDecodeTempJp2Timings(command: DecodeTempJp2Timings, decode: codestream.DecodeTimings) void {
    const total = command.total_ns;
    std.debug.print("timings:\n", .{});
    printTiming("total", total, total);
    printTiming("JP2 read", command.jp2_read_ns, total);
    printTiming("codestream box", command.codestream_extract_ns, total);
    printTiming("codestream", command.codestream_decode_ns, total);
    printTiming("  sidecar/legacy", decode.sidecar_or_legacy_ns, total);
    printTiming("  metadata", decode.metadata_ns, total);
    printTiming("  packet catalog", decode.packet_catalog_ns, total);
    printDecodePacketCatalogProfile(decode, total);
    printTiming("  block payload", decode.block_payload_ns, total);
    printDecodeBlockWorkerProfile(decode);
    printTiming("  inverse DWT", decode.wavelet_ns, total);
    printTiming("  inverse MCT", decode.color_transform_ns, total);
    printDecodeT1PassProfile(decode);
    printTiming("ICC extract", command.icc_extract_ns, total);
    printTiming("TIFF write", command.tiff_write_ns, total);
}

fn printDecodePacketCatalogProfile(decode: codestream.DecodeTimings, total: u64) void {
    if (decode.packet_catalog_scan_ns == 0 and
        decode.packet_catalog_header_ns == 0 and
        decode.packet_catalog_finalize_ns == 0) return;
    printTiming("    scan", decode.packet_catalog_scan_ns, total);
    printTiming("    headers", decode.packet_catalog_header_ns, total);
    printTiming("    finalize", decode.packet_catalog_finalize_ns, total);
}

fn printDecodeBlockWorkerProfile(decode: codestream.DecodeTimings) void {
    if (decode.block_worker_jobs == 0) return;
    const jobs_f = @as(f64, @floatFromInt(decode.block_worker_jobs));
    const avg_ns = @as(f64, @floatFromInt(decode.block_worker_ns_sum)) / jobs_f;
    const avg_blocks = @as(f64, @floatFromInt(decode.block_worker_blocks_sum)) / jobs_f;
    const avg_payload = @as(f64, @floatFromInt(decode.block_worker_payload_sum)) / jobs_f;
    std.debug.print(
        "    workers jobs {d:>3} max/avg wall {d:>7.3}/{d:>7.3} ms blocks {d:>5}/{d:>7.1} payload {d:>7.1}/{d:>7.1} KiB\n",
        .{
            decode.block_worker_jobs,
            nsToMs(decode.block_worker_ns_max),
            avg_ns / 1_000_000.0,
            decode.block_worker_blocks_max,
            avg_blocks,
            kibOf(decode.block_worker_payload_max),
            avg_payload / 1024.0,
        },
    );
}

fn printEncodeT1PassProfile(encode: codestream.EncodeTimings) void {
    const stats = encode.t1_pass_stats;
    if (!hasT1PassProfile(stats)) return;
    std.debug.print("  T1 encode pass profile (single-thread CPU time):\n", .{});
    printPassTiming("MQ significance", stats.mq_ns[0], stats.mq_passes[0], stats.mq_symbols[0]);
    printPassTiming("MQ refinement", stats.mq_ns[1], stats.mq_passes[1], stats.mq_symbols[1]);
    printPassTiming("MQ cleanup/RLC", stats.mq_ns[2], stats.mq_passes[2], stats.mq_symbols[2]);
    printPassTiming("RAW significance", stats.raw_ns[0], stats.raw_passes[0], stats.raw_symbols[0]);
    printPassTiming("RAW refinement", stats.raw_ns[1], stats.raw_passes[1], stats.raw_symbols[1]);
}

fn printDecodeT1PassProfile(decode: codestream.DecodeTimings) void {
    const stats = decode.t1_pass_stats;
    if (!hasT1PassProfile(stats)) return;
    std.debug.print("  T1 pass profile (CPU-sum across workers):\n", .{});
    printPassTiming("MQ significance", stats.mq_ns[0], stats.mq_passes[0], stats.mq_symbols[0]);
    printMqBranchStats("  branches", stats, 0);
    printPassTiming("MQ refinement", stats.mq_ns[1], stats.mq_passes[1], stats.mq_symbols[1]);
    printMqBranchStats("  branches", stats, 1);
    printPassTiming("MQ cleanup/RLC", stats.mq_ns[2], stats.mq_passes[2], stats.mq_symbols[2]);
    printMqBranchStats("  branches", stats, 2);
    printPassTiming("RAW significance", stats.raw_ns[0], stats.raw_passes[0], stats.raw_symbols[0]);
    printPassTiming("RAW refinement", stats.raw_ns[1], stats.raw_passes[1], stats.raw_symbols[1]);
}

fn hasT1PassProfile(stats: anytype) bool {
    inline for (0..3) |index| {
        if (stats.mq_passes[index] != 0 or stats.raw_passes[index] != 0) return true;
    }
    return false;
}

fn printTiming(label: []const u8, ns: u64, total_ns: u64) void {
    std.debug.print(
        "  {s:<18} {d:>9.3} ms {d:>6.2}%\n",
        .{ label, nsToMs(ns), percentOf(ns, total_ns) },
    );
}

fn printPassTiming(label: []const u8, ns: u64, passes: u64, symbols: u64) void {
    if (passes == 0 and symbols == 0 and ns == 0) return;
    std.debug.print(
        "    {s:<16} {d:>9.3} ms passes {d:>7} symbols {d:>12}\n",
        .{ label, nsToMs(ns), passes, symbols },
    );
}

fn printMqBranchStats(label: []const u8, stats: anytype, index: usize) void {
    const total = stats.mq_fast_mps[index] + stats.mq_lps[index] + stats.mq_renorm_mps[index];
    if (total == 0 and stats.mq_renorm_shifts[index] == 0 and stats.mq_byte_in[index] == 0) return;
    std.debug.print(
        "      {s:<14} fast {d:>12} lps {d:>10} renorm-mps {d:>10} shifts {d:>10} byte-in {d:>8}\n",
        .{
            label,
            stats.mq_fast_mps[index],
            stats.mq_lps[index],
            stats.mq_renorm_mps[index],
            stats.mq_renorm_shifts[index],
            stats.mq_byte_in[index],
        },
    );
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
}

fn kibOf(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1024.0;
}

fn percentOf(ns: u64, total_ns: u64) f64 {
    if (total_ns == 0) return 0.0;
    return 100.0 * @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(total_ns));
}

fn elapsedNs(start: u64) u64 {
    const now = monotonicNs();
    return if (now >= start) now - start else 0;
}

fn monotonicNs() u64 {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        var frequency: windows.LARGE_INTEGER = undefined;
        var counter: windows.LARGE_INTEGER = undefined;
        if (!windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool()) return 0;
        if (!windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool()) return 0;
        if (frequency <= 0 or counter < 0) return 0;
        return @intCast((@as(u128, @intCast(counter)) * std.time.ns_per_s) / @as(u128, @intCast(frequency)));
    }

    const posix = std.posix;
    var ts: posix.timespec = undefined;
    return switch (posix.errno(posix.system.clock_gettime(posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec)),
        else => 0,
    };
}

fn parseWavelet(value: []const u8) !wavelet.Wavelet {
    if (std.mem.eql(u8, value, "5-3") or std.mem.eql(u8, value, "53")) {
        return .reversible_5_3;
    }
    if (std.mem.eql(u8, value, "9-7") or std.mem.eql(u8, value, "97")) {
        return .irreversible_9_7;
    }
    return error.InvalidWavelet;
}

const U16Pair = struct {
    first: u16,
    second: u16,
};

const U32Pair = struct {
    first: u32,
    second: u32,
};

fn parseProgression(value: []const u8) !codestream.ProgressionOrder {
    if (std.ascii.eqlIgnoreCase(value, "LRCP")) return .lrcp;
    if (std.ascii.eqlIgnoreCase(value, "RLCP")) return .rlcp;
    if (std.ascii.eqlIgnoreCase(value, "RPCL")) return .rpcl;
    if (std.ascii.eqlIgnoreCase(value, "PCRL")) return .pcrl;
    if (std.ascii.eqlIgnoreCase(value, "CPRL")) return .cprl;
    return error.InvalidValue;
}

fn parsePocRecords(value: []const u8, storage: []codestream.PocRecord) ![]const codestream.PocRecord {
    var count: usize = 0;
    var encoded_records = std.mem.splitScalar(u8, value, ';');
    while (encoded_records.next()) |encoded_record| {
        if (count >= storage.len) return error.InvalidValue;
        var fields: [6][]const u8 = undefined;
        var field_count: usize = 0;
        var encoded_fields = std.mem.splitScalar(u8, encoded_record, ',');
        while (encoded_fields.next()) |encoded_field| {
            if (field_count >= fields.len) return error.InvalidValue;
            const field = std.mem.trim(u8, encoded_field, " \t\r\n");
            if (field.len == 0) return error.InvalidValue;
            fields[field_count] = field;
            field_count += 1;
        }
        if (field_count != fields.len) return error.InvalidValue;
        const progression = try parseProgression(fields[5]);
        storage[count] = .{
            .resolution_start = try std.fmt.parseInt(u8, fields[0], 10),
            .component_start = try std.fmt.parseInt(u16, fields[1], 10),
            .layer_end = try std.fmt.parseInt(u16, fields[2], 10),
            .resolution_end = try std.fmt.parseInt(u8, fields[3], 10),
            .component_end = try std.fmt.parseInt(u16, fields[4], 10),
            .progression = @enumFromInt(@intFromEnum(progression)),
        };
        count += 1;
    }
    if (count == 0) return error.InvalidValue;
    return storage[0..count];
}

fn parseMct(value: []const u8) !codestream.MultipleComponentTransform {
    if (std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "on") or
        std.ascii.eqlIgnoreCase(value, "rct"))
    {
        return .rct;
    }
    if (std.ascii.eqlIgnoreCase(value, "ict")) {
        return .ict;
    }
    if (std.ascii.eqlIgnoreCase(value, "none") or
        std.ascii.eqlIgnoreCase(value, "off") or
        std.mem.eql(u8, value, "0"))
    {
        return .none;
    }
    return error.InvalidValue;
}

fn parseJpeg2000Transform(value: []const u8) !codestream.WaveletTransform {
    if (std.ascii.eqlIgnoreCase(value, "5-3") or
        std.ascii.eqlIgnoreCase(value, "53") or
        std.ascii.eqlIgnoreCase(value, "reversible"))
    {
        return .reversible_5_3;
    }
    if (std.ascii.eqlIgnoreCase(value, "9-7") or
        std.ascii.eqlIgnoreCase(value, "97") or
        std.ascii.eqlIgnoreCase(value, "irreversible"))
    {
        return .irreversible_9_7;
    }
    return error.InvalidValue;
}

/// README-documented convention: the CLI defaults to all logical CPU
/// threads and `--threads 0` selects the same. The codec layers require an
/// explicit nonzero worker count (their library default stays 1), so the
/// resolution happens here at the CLI boundary.
fn defaultThreadCount() u8 {
    const logical = std.Thread.getCpuCount() catch 1;
    return @intCast(@min(@max(logical, 1), @as(usize, std.math.maxInt(u8))));
}

fn parseThreadCount(value: []const u8) !u8 {
    const requested = try std.fmt.parseInt(u8, value, 10);
    if (requested != 0) return requested;
    return defaultThreadCount();
}

fn parseT1Backend(value: []const u8) !codestream.T1Backend {
    if (std.ascii.eqlIgnoreCase(value, "legacy") or
        std.ascii.eqlIgnoreCase(value, "legacy-mq") or
        std.ascii.eqlIgnoreCase(value, "mq"))
    {
        return .legacy_mq;
    }
    if (std.ascii.eqlIgnoreCase(value, "iso") or
        std.ascii.eqlIgnoreCase(value, "iso-mq") or
        std.ascii.eqlIgnoreCase(value, "jpeg2000"))
    {
        return .iso_mq;
    }
    return error.InvalidValue;
}

fn parseQuantizationStyle(value: []const u8) !codestream.QuantizationStyle {
    if (std.ascii.eqlIgnoreCase(value, "none") or
        std.ascii.eqlIgnoreCase(value, "no-quantization") or
        std.mem.eql(u8, value, "0"))
    {
        return .none;
    }
    if (std.ascii.eqlIgnoreCase(value, "scalar-derived") or
        std.ascii.eqlIgnoreCase(value, "derived") or
        std.mem.eql(u8, value, "1"))
    {
        return .scalar_derived;
    }
    if (std.ascii.eqlIgnoreCase(value, "scalar-expounded") or
        std.ascii.eqlIgnoreCase(value, "expounded") or
        std.mem.eql(u8, value, "2"))
    {
        return .scalar_expounded;
    }
    return error.InvalidValue;
}

fn parseU32Pair(value: []const u8) !U32Pair {
    var parts = std.mem.splitScalar(u8, value, ',');
    const first_text = parts.next() orelse return error.InvalidValue;
    const second_text = parts.next() orelse return error.InvalidValue;
    if (parts.next() != null) return error.InvalidValue;
    return .{
        .first = try std.fmt.parseInt(u32, std.mem.trim(u8, first_text, " "), 10),
        .second = try std.fmt.parseInt(u32, std.mem.trim(u8, second_text, " "), 10),
    };
}

fn parseU16Pair(value: []const u8) !U16Pair {
    var parts = std.mem.splitScalar(u8, value, ',');
    const first_text = parts.next() orelse return error.InvalidValue;
    const second_text = parts.next() orelse return error.InvalidValue;
    if (parts.next() != null) return error.InvalidValue;
    return .{
        .first = try std.fmt.parseInt(u16, std.mem.trim(u8, first_text, " "), 10),
        .second = try std.fmt.parseInt(u16, std.mem.trim(u8, second_text, " "), 10),
    };
}

fn parsePrecincts(value: []const u8, options: *codestream.LosslessOptions) !void {
    var index: usize = 0;
    var count: usize = 0;
    while (index < value.len) {
        while (index < value.len and (value[index] == ' ' or value[index] == ',')) : (index += 1) {}
        if (index >= value.len) break;

        const open = value[index];
        const close: u8 = switch (open) {
            '[' => ']',
            '{' => '}',
            else => return error.InvalidValue,
        };
        index += 1;
        const start = index;
        while (index < value.len and value[index] != close) : (index += 1) {}
        if (index >= value.len) return error.InvalidValue;
        if (count >= options.precincts.len) return error.InvalidValue;

        const pair = try parseU16Pair(value[start..index]);
        options.precincts[count] = .{ .width = pair.first, .height = pair.second };
        count += 1;
        index += 1;
    }

    if (count == 0) return error.InvalidValue;
    options.precinct_count = @as(u8, @intCast(count));
}

fn parseRates(value: []const u8, options: *codestream.LosslessOptions) !void {
    var count: usize = 0;
    var parts = std.mem.splitScalar(u8, value, ',');
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) return error.InvalidValue;
        if (count >= options.rates.len) return error.InvalidValue;
        const rate = try std.fmt.parseFloat(f64, part);
        if (!std.math.isFinite(rate) or rate <= 0) return error.InvalidValue;
        options.rates[count] = rate;
        count += 1;
    }

    if (count == 0) return error.InvalidValue;
    options.rate_count = @intCast(count);
    options.layers = @intCast(count);
}

fn t1BackendLabel(backend: codestream.T1Backend) []const u8 {
    return switch (backend) {
        .legacy_mq => "legacy-mq",
        .iso_mq => "iso-mq",
    };
}

fn usage() void {
    std.debug.print(
        \\Usage: (z2k is an installed alias for z2000; --threads defaults to all logical CPUs)
        \\  z2000 --version
        \\  z2000 <input.tif> <output.jp2> [options]   (shorthand for tiff-to-jp2)
        \\  z2000 <input.bmp> <output.jp2> [options]   (shorthand for bmp-to-jp2)
        \\  z2000 <input.png> <output.jp2> [options]   (shorthand for png-to-jp2)
        \\  z2000 <input.jpg> <output.jp2> [options]   (shorthand for jpeg-to-jp2)
        \\  z2000 <input.dng> <output.jp2> [options]   (shorthand for dng-to-jp2)
        \\  z2000 <input.exr> <output.jp2> [options]   (shorthand for exr-to-jp2)
        \\  z2000 <input.jp2> <output.tif> [options]   (shorthand for decode-temp-jp2)
        \\  z2000 <input.j2k> <output.pgx> [options]   (raw codestream component diagnostic)
        \\  z2000 <input.j2k> <output.zraw> [options]  (exact all-component raw diagnostic)
        \\  z2000 *.tif .jp2 [options]                  (non-recursive batch; supports * and ?)
        \\  z2000 *.bmp .jp2 [options]                  (non-recursive BMP batch)
        \\  z2000 *.png .jp2 [options]                  (non-recursive PNG batch)
        \\  z2000 *.jpg .jp2 [options]                  (non-recursive JPEG batch)
        \\  z2000 *.dng .jp2 [options]                  (non-recursive DNG batch)
        \\  z2000 *.exr .jp2 [options]                  (non-recursive OpenEXR batch)
        \\  z2000 *.jp2 .tif [options]                  (non-recursive reverse batch)
        \\  z2000 *.j2k .pgx [options]                  (non-recursive raw component batch)
        \\  z2000 *.j2k .zraw [options]                 (non-recursive exact all-component batch)
        \\  z2000 encode <input.pgm> <output.z2000> [--wavelet 5-3|9-7] [--levels N] [--quant STEP]
        \\  z2000 decode <input.z2000> <output.pgm>
        \\  z2000 tiff-info <input.tif>
        \\  z2000 dng-info <input.dng>
        \\  z2000 tiff-to-jp2 <input.tif> <output.jp2> [--levels N|--resolutions N] [--tile W,H] [--tile-parts none|R|L|C|P] [--block N] [--progression RPCL|LRCP|RLCP|PCRL|CPRL] [--poc RECORDS] [--poc-location main|tile] [--mct rct|ict|none] [--transform 5-3|9-7] [--qstyle none|scalar-derived|scalar-expounded] [--guard-bits N] [--precincts LIST] [--layers N|--rates LIST] [--sop|--no-sop] [--eph|--no-eph] [--ppm|--no-ppm] [--ppt|--no-ppt] [--tlm|--no-tlm] [--t1-backend legacy-mq|iso-mq] [--bypass|--no-bypass] [--reset-context] [--terminate-all] [--vertical-causal] [--predictable-termination] [--segmentation-symbols] [--threads N] [--debug-temp-sidecar] [--timings]
        \\  z2000 bmp-to-jp2 <input.bmp> <output.jp2> [tiff-to-jp2 options]
        \\  z2000 png-to-jp2 <input.png> <output.jp2> [tiff-to-jp2 options]
        \\  z2000 jpeg-to-jp2 <input.jpg> <output.jp2> [tiff-to-jp2 options]
        \\  z2000 dng-to-jp2 <input.dng> <output.jp2> [tiff-to-jp2 options]
        \\  z2000 exr-to-jp2 <input.exr> <output.jp2> [tiff-to-jp2 options]
        \\  z2000 jp2-info <input.jp2>
        \\  z2000 jp2-stats <input.jp2> [--t1-backend legacy-mq|iso-mq]
        \\  z2000 decode-temp-jp2 <input.jp2> <output.tif> [--threads N] [--t1-backend legacy-mq|iso-mq] [--convert-to-srgb] [--timings]
        \\  z2000 j2k-to-pgx <input.j2k|input.j2c> <output.pgx> [--component N] [--reduce N] [--threads N] [--t1-backend legacy-mq|iso-mq] [--pgx-order ML|LM]
        \\  z2000 j2k-to-zraw <input.j2k|input.j2c> <output.zraw> [--reduce N] [--threads N] [--t1-backend legacy-mq|iso-mq]
        \\
        \\Notes:
        \\  PGM input must be binary P5 with max value 255.
        \\  Batch patterns apply only to filenames in one concrete directory; shell-expanded input lists are accepted too.
        \\  Existing targets follow single-file overwrite behavior.
        \\  Raw PGX diagnostics write one selected codestream component; --component defaults to 0 and --pgx-order defaults to ML.
        \\  ZRAW diagnostics preserve every native component, signedness, precision, sampling geometry, and origin in canonical big-endian form.
        \\  .z2000 is an educational codestream, not ISO JPEG2000 yet.
        \\  tiff-to-jp2 writes the selected checked progression profile; --debug-temp-sidecar adds the legacy BP8 COM payload for diagnostics.
        \\  --poc uses quoted ISO records: RSpoc,CSpoc,LYEpoc,REpoc,CEpoc,ORDER;... and supports tile-parts none or compatible R/L/C/P; --poc-location defaults to main.
        \\
    , .{});
}
