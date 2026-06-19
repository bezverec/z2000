const std = @import("std");
const codec = @import("codec.zig");
const codestream = @import("codestream.zig");
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
            if (index >= args.len or args[index].len != 1) return error.InvalidValue;
            options.tile_part_divisions = args[index][0];
        } else if (std.mem.eql(u8, args[index], "--threads")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.threads = try std.fmt.parseInt(u8, args[index], 10);
        } else if (std.mem.eql(u8, args[index], "--timings")) {
            show_timings = true;
        } else if (std.mem.eql(u8, args[index], "--rates") or std.mem.eql(u8, args[index], "--rate")) {
            return codestream.CodestreamError.UnsupportedPayload;
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
        "wrote JP2 marker skeleton {s} -> {s} ({}x{}, {} bits/channel, levels {}, tile {}x{}, block {}x{}, progression {s}, layers {}, MCT {s}, transform {s}, QCD {s}/guard {}, tile-parts {s}, TLM {}, threads {}); packet coder is next\n",
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
            options.threads,
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
        "JP2: {s}: {}x{}, {} components, {} bits/component, {} codestream bytes\n",
        .{
            args[0],
            info.width,
            info.height,
            info.components,
            info.bits_per_component,
            info.codestream_bytes,
        },
    );
}

fn jp2StatsCommand(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
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

    const j2k = try jp2.extractCodestream(bytes);
    const stats = try codestream.analyzeLosslessTemporary(j2k);
    printTemporaryStats(args[0], stats);
}

fn decodeTempJp2Command(io: std.Io, allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        usage();
        return error.InvalidCommand;
    }

    var options = codestream.DecodeOptions{};
    var index: usize = 2;
    while (index < args.len) {
        if (std.mem.eql(u8, args[index], "--threads")) {
            index += 1;
            if (index >= args.len) return error.MissingValue;
            options.threads = try std.fmt.parseInt(u8, args[index], 10);
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
    var rgb = try codestream.decodeLosslessTemporaryWithOptions(allocator, j2k, options);
    defer rgb.deinit();

    try tiff.writeRgb(io, allocator, rgb, args[1]);
    std.debug.print(
        "decoded temporary JP2 payload {s} -> {s} ({}x{}, {} bits/channel, threads {})\n",
        .{ args[0], args[1], rgb.width, rgb.height, rgb.bit_depth, options.threads },
    );
}

fn printTemporaryStats(path: []const u8, stats: codestream.TemporaryStats) void {
    std.debug.print(
        "JP2 temporary payload stats: {s}: {}x{}, {} bits/channel, levels {}, block {}x{}, tile-parts {s}",
        .{
            path,
            stats.width,
            stats.height,
            stats.bit_depth,
            stats.levels,
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

    const pass_labels = [_][]const u8{ "sig", "ref", "cleanup" };
    for (stats.pass_streams, 0..) |stream, index| {
        printStreamStats(pass_labels[index], stream);
    }

    const method_labels = [_][]const u8{ "raw", "rle", "bit-rle", "arith" };
    for (stats.method_streams, 0..) |stream, index| {
        if (stream.streams != 0) printStreamStats(method_labels[index], stream);
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

fn printTiming(label: []const u8, ns: u64, total_ns: u64) void {
    std.debug.print(
        "  {s:<18} {d:>9.3} ms {d:>6.2}%\n",
        .{ label, nsToMs(ns), percentOf(ns, total_ns) },
    );
}

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
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
    var ts: std.c.timespec = undefined;
    const rc = std.c.clock_gettime(.MONOTONIC, &ts);
    if (rc != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
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
        std.ascii.eqlIgnoreCase(value, "rct") or
        std.ascii.eqlIgnoreCase(value, "ict"))
    {
        return .yes;
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

fn usage() void {
    std.debug.print(
        \\Usage:
        \\  z2000 encode <input.pgm> <output.z2000> [--wavelet 5-3|9-7] [--levels N] [--quant STEP]
        \\  z2000 decode <input.z2000> <output.pgm>
        \\  z2000 tiff-info <input.tif>
        \\  z2000 tiff-to-jp2 <input.tif> <output.jp2> [--levels N|--resolutions N] [--tile W,H] [--block N] [--progression RPCL] [--mct yes|none] [--transform 5-3|9-7] [--qstyle none|scalar-derived|scalar-expounded] [--guard-bits N] [--precincts LIST] [--tlm|--no-tlm] [--bypass|--no-bypass] [--reset-context] [--terminate-all] [--vertical-causal] [--predictable-termination] [--segmentation-symbols] [--threads N] [--timings]
        \\  z2000 jp2-info <input.jp2>
        \\  z2000 jp2-stats <input.jp2>
        \\  z2000 decode-temp-jp2 <input.jp2> <output.tif> [--threads N]
        \\
        \\Notes:
        \\  PGM input must be binary P5 with max value 255.
        \\  .z2000 is an educational codestream, not ISO JPEG2000 yet.
        \\  tiff-to-jp2 currently writes JPEG2000 markers plus temporary raw DWT payload.
        \\
    , .{});
}
