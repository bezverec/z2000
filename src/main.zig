const std = @import("std");
const builtin = @import("builtin");
const codec = @import("codec.zig");
const codestream = @import("codestream.zig");
const dng = @import("formats/dng.zig");
const image = @import("image.zig");
const jp2 = @import("jp2.zig");
const tiff = @import("tiff.zig");
const wavelet = @import("wavelet.zig");

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
    } else if (std.mem.eql(u8, args[1], "jp2-info")) {
        try jp2InfoCommand(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "jp2-stats")) {
        try jp2StatsCommand(io, allocator, args[2..]);
    } else if (std.mem.eql(u8, args[1], "decode-temp-jp2")) {
        try decodeTempJp2Command(io, allocator, args[2..]);
    } else {
        usage();
        return error.InvalidCommand;
    }
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

    var rgb = try tiff.readRgb(io, allocator, args[0]);
    defer rgb.deinit();

    std.debug.print(
        "TIFF RGB: {s}: {}x{}, {} bits/channel, {} samples\n",
        .{ args[0], rgb.width, rgb.height, rgb.bit_depth, rgb.samples.len },
    );
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

fn tiffToJp2Command(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        usage();
        return error.InvalidCommand;
    }

    var options = codestream.LosslessOptions{};
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
        } else if (std.mem.eql(u8, args[index], "--mct")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.mct = try parseMct(args[index]);
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
            if (std.mem.eql(u8, args[index], "none") or std.mem.eql(u8, args[index], "0")) {
                options.tile_part_divisions = null;
            } else {
                if (args[index].len != 1) return error.InvalidValue;
                options.tile_part_divisions = args[index][0];
            }
        } else if (std.mem.eql(u8, args[index], "--threads")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.threads = try std.fmt.parseInt(u8, args[index], 10);
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

    var command_timings = TiffToJp2Timings{};
    const read_start = monotonicNs();
    var rgb = try tiff.readRgb(io, allocator, args[0]);
    defer rgb.deinit();
    command_timings.tiff_read_ns = elapsedNs(read_start);

    var encode_timings = codestream.EncodeTimings{};
    const encode_start = monotonicNs();
    const j2k = if (show_timings)
        try codestream.encodeLosslessWithOptionsProfiled(allocator, rgb, options, &encode_timings)
    else
        try codestream.encodeLosslessWithOptions(allocator, rgb, options);
    defer allocator.free(j2k);
    command_timings.codestream_ns = elapsedNs(encode_start);

    const wrap_start = monotonicNs();
    const wrapped = try jp2.wrapRgbCodestream(allocator, rgb, j2k);
    defer allocator.free(wrapped);
    command_timings.jp2_wrap_ns = elapsedNs(wrap_start);

    const write_start = monotonicNs();
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = wrapped });
    command_timings.write_ns = elapsedNs(write_start);
    command_timings.total_ns = command_timings.tiff_read_ns +
        command_timings.codestream_ns +
        command_timings.jp2_wrap_ns +
        command_timings.write_ns;

    std.debug.print(
        "wrote JP2 marker skeleton {s} -> {s} ({}x{}, {} bits/channel, levels {}, tile {}x{}, block {}x{}, progression {s}, layers {}, MCT {s}, transform {s}, QCD {s}/guard {}, tile-parts {s}, TLM {}, T1 {s}, threads {}, debug sidecar {})\n",
        .{
            args[0],
            args[1],
            rgb.width,
            rgb.height,
            rgb.bit_depth,
            options.levels,
            options.tile_width,
            options.tile_height,
            options.block_width,
            options.block_height,
            options.progression.label(),
            options.layers,
            options.mct.label(),
            options.transform.label(),
            options.quantization.label(),
            options.guard_bits,
            tilePartDivisionLabel(options.tile_part_divisions),
            options.tlm,
            t1BackendLabel(options.t1_backend),
            options.threads,
            options.emit_temporary_payload_sidecar,
        },
    );
    if (show_timings) {
        printTiffToJp2Timings(command_timings, encode_timings);
    }
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
        "JP2: {s}: {}x{}, {} components, {} bits/component, {} codestream bytes, ICC {s}",
        .{
            args[0],
            info.width,
            info.height,
            info.components,
            info.bits_per_component,
            info.codestream_bytes,
            if (info.has_icc_profile) "yes" else "no",
        },
    );
    if (info.has_icc_profile) {
        std.debug.print(" ({} bytes)", .{info.icc_profile_bytes});
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

fn decodeTempJp2Command(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        usage();
        return error.InvalidCommand;
    }

    var options = codestream.DecodeOptions{};
    var show_timings = false;
    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--threads")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.threads = try std.fmt.parseInt(u8, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--t1-backend")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.t1_backend = try parseT1Backend(args[index]);
        } else if (std.mem.eql(u8, args[index], "--timings")) {
            show_timings = true;
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
    const j2k = try jp2.extractCodestream(bytes);
    command_timings.codestream_extract_ns = elapsedNs(extract_start);

    var decode_timings = codestream.DecodeTimings{};
    const decode_start = monotonicNs();
    var rgb = if (show_timings)
        try codestream.decodeLosslessTemporaryWithOptionsProfiled(allocator, j2k, options, &decode_timings)
    else
        try codestream.decodeLosslessTemporaryWithOptions(allocator, j2k, options);
    defer rgb.deinit();
    command_timings.codestream_decode_ns = elapsedNs(decode_start);

    const icc_start = monotonicNs();
    if (try jp2.extractIccProfile(allocator, bytes)) |profile| {
        if (rgb.icc_profile) |existing| allocator.free(existing);
        rgb.icc_profile = profile;
    }
    command_timings.icc_extract_ns = elapsedNs(icc_start);

    const write_start = monotonicNs();
    try tiff.writeRgb(io, allocator, rgb, args[1]);
    command_timings.tiff_write_ns = elapsedNs(write_start);
    command_timings.total_ns = command_timings.jp2_read_ns +
        command_timings.codestream_extract_ns +
        command_timings.codestream_decode_ns +
        command_timings.icc_extract_ns +
        command_timings.tiff_write_ns;

    std.debug.print(
        "decoded temporary JP2 payload {s} -> {s} ({}x{}, {} bits/channel, threads {})\n",
        .{ args[0], args[1], rgb.width, rgb.height, rgb.bit_depth, options.threads },
    );
    if (show_timings) {
        printDecodeTempJp2Timings(command_timings, decode_timings);
    }
}

fn printTemporaryStats(path: []const u8, stats: codestream.TemporaryStats) void {
    std.debug.print(
        "JP2 temporary payload stats: {s}: {}x{}, {} bits/channel, levels {}, layers {}, block {}x{}, tile-parts {s}",
        .{
            path,
            stats.width,
            stats.height,
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
    printComponentStats("Y", stats.components[0]);
    printComponentStats("Cb", stats.components[1]);
    printComponentStats("Cr", stats.components[2]);
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

const TiffToJp2Timings = struct {
    total_ns: u64 = 0,
    tiff_read_ns: u64 = 0,
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

fn printTiffToJp2Timings(command: TiffToJp2Timings, encode: codestream.EncodeTimings) void {
    const total = command.total_ns;
    std.debug.print("timings:\n", .{});
    printTiming("total", total, total);
    printTiming("TIFF read", command.tiff_read_ns, total);
    printTiming("codestream", command.codestream_ns, total);
    printTiming("  RCT", encode.color_transform_ns, total);
    printTiming("  DWT 5/3", encode.wavelet_ns, total);
    printTiming("  block payload", encode.payload_ns, total);
    printTiming("  markers/write SOD", encode.marker_ns, total);
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

fn printDecodeT1PassProfile(decode: codestream.DecodeTimings) void {
    const stats = decode.t1_pass_stats;
    if (!hasDecodeT1PassProfile(stats)) return;
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

fn hasDecodeT1PassProfile(stats: anytype) bool {
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
        \\Usage:
        \\  z2000 encode <input.pgm> <output.z2000> [--wavelet 5-3|9-7] [--levels N] [--quant STEP]
        \\  z2000 decode <input.z2000> <output.pgm>
        \\  z2000 tiff-info <input.tif>
        \\  z2000 dng-info <input.dng>
        \\  z2000 tiff-to-jp2 <input.tif> <output.jp2> [--levels N|--resolutions N] [--tile W,H] [--tile-parts none|R|L] [--block N] [--progression RPCL] [--mct rct|ict|none] [--transform 5-3|9-7] [--qstyle none|scalar-derived|scalar-expounded] [--guard-bits N] [--precincts LIST] [--layers N|--rates LIST] [--sop|--no-sop] [--eph|--no-eph] [--tlm|--no-tlm] [--t1-backend legacy-mq|iso-mq] [--bypass|--no-bypass] [--reset-context] [--terminate-all] [--vertical-causal] [--predictable-termination] [--segmentation-symbols] [--threads N] [--debug-temp-sidecar] [--timings]
        \\  z2000 jp2-info <input.jp2>
        \\  z2000 jp2-stats <input.jp2> [--t1-backend legacy-mq|iso-mq]
        \\  z2000 decode-temp-jp2 <input.jp2> <output.tif> [--threads N] [--t1-backend legacy-mq|iso-mq] [--timings]
        \\
        \\Notes:
        \\  PGM input must be binary P5 with max value 255.
        \\  .z2000 is an educational codestream, not ISO JPEG2000 yet.
        \\  tiff-to-jp2 writes strict RPCL packet payloads; --debug-temp-sidecar adds the legacy BP8 COM payload for diagnostics.
        \\
    , .{});
}
