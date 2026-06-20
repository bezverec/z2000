const std = @import("std");
const bitplane = @import("bitplane.zig");
const color = @import("color.zig");
const codec = @import("codec.zig");
const codestream = @import("codestream.zig");
const dng = @import("formats/dng.zig");
const ebcot = @import("ebcot.zig");
const entropy = @import("entropy.zig");
const image = @import("image.zig");
const jp2 = @import("jp2.zig");
const mq = @import("mq.zig");
const packet_plan = @import("packet_plan.zig");
const rate_alloc = @import("rate_alloc.zig");
const simd = @import("simd.zig");
const subband = @import("subband.zig");
const t2 = @import("t2.zig");
const tiff = @import("tiff.zig");
const wavelet = @import("wavelet.zig");
const wavelet_int = @import("wavelet_int.zig");

test "5/3 wavelet roundtrips integer-like samples" {
    const allocator = std.testing.allocator;
    const width = 5;
    const height = 4;

    var data = [_]f32{
        10, 11, 12, 13, 14,
        20, 21, 22, 23, 24,
        30, 31, 32, 33, 34,
        40, 41, 42, 43, 44,
    };
    const original = data;

    const levels = try wavelet.forward2D(
        allocator,
        data[0..],
        width,
        height,
        3,
        .reversible_5_3,
    );
    try wavelet.inverse2D(allocator, data[0..], width, height, levels, .reversible_5_3);

    for (data, original) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.001);
    }
}

test "SIMD lane policy is a supported power-of-two width" {
    try std.testing.expect(simd.i32_lanes == 4 or simd.i32_lanes == 8 or simd.i32_lanes == 16);
    try std.testing.expect((simd.i32_lanes & (simd.i32_lanes - 1)) == 0);
    try std.testing.expectEqual(@as(comptime_int, 2), simd.f32_pair_lanes);
    try std.testing.expect(simd.family.len > 0);
}

test "T2 packet header presence bit matches temporary envelope bytes" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    try t2.appendPacketPresenceHeader(allocator, &out, false);
    try t2.appendPacketPresenceHeader(allocator, &out, true);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x80 }, out.items);

    var cursor: usize = 0;
    try std.testing.expect(!try t2.readPacketPresenceHeader(out.items, &cursor, out.items.len));
    try std.testing.expectEqual(@as(usize, 1), cursor);
    try std.testing.expect(try t2.readPacketPresenceHeader(out.items, &cursor, out.items.len));
    try std.testing.expectEqual(out.items.len, cursor);
}

test "T2 packet header bitstream inserts marker-safe stuff bits after 0xff" {
    const allocator = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var writer = t2.PacketHeaderWriter.init(allocator, &out);
    try writer.writeBits(0xff, 8);
    try writer.writeBit(true);
    try writer.finish();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xff, 0x40 }, out.items);

    var reader = t2.PacketHeaderReader.init(out.items);
    var bit_count: usize = 0;
    while (bit_count < 9) : (bit_count += 1) {
        try std.testing.expect(try reader.readBit());
    }
    try reader.byteAlign();
    try std.testing.expectEqual(out.items.len, reader.bytesConsumed());
}

test "T2 tag-tree encoder and decoder preserve threshold decisions" {
    const allocator = std.testing.allocator;
    const leaf_values = [_]u32{
        0, 2,
        1, 3,
    };

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    var writer = t2.PacketHeaderWriter.init(allocator, &bytes);
    var encoder = try t2.TagTreeEncoder.init(allocator, 2, 2, leaf_values[0..]);
    defer encoder.deinit();

    try encoder.encode(0, 0, 1, &writer);
    try encoder.encode(1, 0, 1, &writer);
    try encoder.encode(0, 1, 2, &writer);
    try encoder.encode(1, 1, 3, &writer);
    try writer.finish();

    var reader = t2.PacketHeaderReader.init(bytes.items);
    var decoder = try t2.TagTreeDecoder.init(allocator, 2, 2);
    defer decoder.deinit();

    try std.testing.expect(try decoder.decode(0, 0, 1, &reader));
    try std.testing.expect(!try decoder.decode(1, 0, 1, &reader));
    try std.testing.expect(try decoder.decode(0, 1, 2, &reader));
    try std.testing.expect(!try decoder.decode(1, 1, 3, &reader));
    try reader.byteAlign();
    try std.testing.expectEqual(bytes.items.len, reader.bytesConsumed());
}

test "T2 zero bit-plane count bridges T1 block bitplane metadata" {
    try std.testing.expectEqual(@as(u8, 5), try t2.zeroBitPlaneCount(8, 3));
    try std.testing.expectEqual(@as(u8, 0), try t2.zeroBitPlaneCount(8, 8));
    try std.testing.expectError(t2.PacketHeaderError.InvalidPacketHeader, t2.zeroBitPlaneCount(3, 4));
}

test "T2 coding pass count coder roundtrips ISO packet header ranges" {
    const allocator = std.testing.allocator;
    const pass_counts = [_]u16{ 1, 2, 3, 5, 6, 36, 37, 164 };

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    var writer = t2.PacketHeaderWriter.init(allocator, &bytes);
    for (pass_counts) |pass_count| {
        try t2.writeCodingPassCount(&writer, pass_count);
    }
    try writer.finish();

    var reader = t2.PacketHeaderReader.init(bytes.items);
    for (pass_counts) |pass_count| {
        try std.testing.expectEqual(pass_count, try t2.readCodingPassCount(&reader));
    }
    try reader.byteAlign();
    try std.testing.expectEqual(bytes.items.len, reader.bytesConsumed());
    try std.testing.expectError(t2.PacketHeaderError.InvalidPacketHeader, t2.writeCodingPassCount(&writer, 0));
    try std.testing.expectError(t2.PacketHeaderError.InvalidPacketHeader, t2.writeCodingPassCount(&writer, 165));
}

test "T2 segment length coder preserves Lblock state" {
    const allocator = std.testing.allocator;
    const Segment = struct {
        passes: u16,
        bytes: u64,
    };
    const segments = [_]Segment{
        .{ .passes = 1, .bytes = 7 },
        .{ .passes = 1, .bytes = 8 },
        .{ .passes = 6, .bytes = 63 },
        .{ .passes = 37, .bytes = 1024 },
    };

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    var writer = t2.PacketHeaderWriter.init(allocator, &bytes);
    var write_state = t2.SegmentLengthState{};
    for (segments) |segment| {
        try write_state.write(&writer, segment.passes, segment.bytes);
    }
    try writer.finish();

    var reader = t2.PacketHeaderReader.init(bytes.items);
    var read_state = t2.SegmentLengthState{};
    for (segments) |segment| {
        try std.testing.expectEqual(segment.bytes, try read_state.read(&reader, segment.passes));
    }
    try reader.byteAlign();
    try std.testing.expectEqual(write_state.lblock, read_state.lblock);
    try std.testing.expectEqual(bytes.items.len, reader.bytesConsumed());
    try std.testing.expectError(t2.PacketHeaderError.InvalidPacketHeader, write_state.write(&writer, 0, 1));
}

test "T2 block packet header roundtrips first inclusion metadata" {
    const allocator = std.testing.allocator;
    const inclusion_values = [_]u32{0};
    const zero_bitplane_values = [_]u32{5};
    const pass_count = bitplane.isoCodingPassCount(3, 4);

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    var writer = t2.PacketHeaderWriter.init(allocator, &bytes);
    var inclusion_encoder = try t2.TagTreeEncoder.init(allocator, 1, 1, inclusion_values[0..]);
    defer inclusion_encoder.deinit();
    var zero_encoder = try t2.TagTreeEncoder.init(allocator, 1, 1, zero_bitplane_values[0..]);
    defer zero_encoder.deinit();
    var write_lengths = t2.SegmentLengthState{};

    try t2.writeCodeBlockPacketHeader(
        &writer,
        &inclusion_encoder,
        &zero_encoder,
        &write_lengths,
        0,
        .{
            .leaf_x = 0,
            .leaf_y = 0,
            .included = true,
            .zero_bitplanes = 5,
            .pass_count = pass_count,
            .byte_length = 321,
        },
    );
    try writer.finish();

    var reader = t2.PacketHeaderReader.init(bytes.items);
    var inclusion_decoder = try t2.TagTreeDecoder.init(allocator, 1, 1);
    defer inclusion_decoder.deinit();
    var zero_decoder = try t2.TagTreeDecoder.init(allocator, 1, 1);
    defer zero_decoder.deinit();
    var read_lengths = t2.SegmentLengthState{};

    const decoded = try t2.readCodeBlockPacketHeader(
        &reader,
        &inclusion_decoder,
        &zero_decoder,
        &read_lengths,
        0,
        0,
        0,
        false,
        8,
    );
    try reader.byteAlign();
    try std.testing.expectEqual(bytes.items.len, reader.bytesConsumed());
    try std.testing.expect(decoded.included);
    try std.testing.expect(decoded.first_inclusion);
    try std.testing.expectEqual(@as(u8, 5), decoded.zero_bitplanes);
    try std.testing.expectEqual(pass_count, decoded.pass_count);
    try std.testing.expectEqual(@as(u64, 321), decoded.byte_length);
    try std.testing.expectEqual(write_lengths.lblock, read_lengths.lblock);
}

test "T2 block packet header roundtrips continued block metadata" {
    const allocator = std.testing.allocator;
    const values = [_]u32{0};

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    var writer = t2.PacketHeaderWriter.init(allocator, &bytes);
    var inclusion_encoder = try t2.TagTreeEncoder.init(allocator, 1, 1, values[0..]);
    defer inclusion_encoder.deinit();
    var zero_encoder = try t2.TagTreeEncoder.init(allocator, 1, 1, values[0..]);
    defer zero_encoder.deinit();
    var write_lengths = t2.SegmentLengthState{};

    try t2.writeCodeBlockPacketHeader(
        &writer,
        &inclusion_encoder,
        &zero_encoder,
        &write_lengths,
        1,
        .{
            .leaf_x = 0,
            .leaf_y = 0,
            .included = true,
            .previously_included = true,
            .pass_count = 2,
            .byte_length = 9,
        },
    );
    try writer.finish();

    var reader = t2.PacketHeaderReader.init(bytes.items);
    var inclusion_decoder = try t2.TagTreeDecoder.init(allocator, 1, 1);
    defer inclusion_decoder.deinit();
    var zero_decoder = try t2.TagTreeDecoder.init(allocator, 1, 1);
    defer zero_decoder.deinit();
    var read_lengths = t2.SegmentLengthState{};

    const decoded = try t2.readCodeBlockPacketHeader(
        &reader,
        &inclusion_decoder,
        &zero_decoder,
        &read_lengths,
        1,
        0,
        0,
        true,
        8,
    );
    try reader.byteAlign();
    try std.testing.expectEqual(bytes.items.len, reader.bytesConsumed());
    try std.testing.expect(decoded.included);
    try std.testing.expect(!decoded.first_inclusion);
    try std.testing.expectEqual(@as(u8, 0), decoded.zero_bitplanes);
    try std.testing.expectEqual(@as(u16, 2), decoded.pass_count);
    try std.testing.expectEqual(@as(u64, 9), decoded.byte_length);
    try std.testing.expectEqual(write_lengths.lblock, read_lengths.lblock);
}

test "T2 precinct packet header roundtrips first and continued layers" {
    const allocator = std.testing.allocator;
    const inclusion_values = [_]u32{
        0, 1,
        0, 3,
    };
    const zero_bitplane_values = [_]u32{
        5, 2,
        4, 1,
    };
    const locations = [_]t2.PacketBlockLocation{
        .{ .leaf_x = 0, .leaf_y = 0 },
        .{ .leaf_x = 1, .leaf_y = 0 },
        .{ .leaf_x = 0, .leaf_y = 1 },
        .{ .leaf_x = 1, .leaf_y = 1 },
    };

    var bytes = std.ArrayList(u8).empty;
    defer bytes.deinit(allocator);
    var inclusion_encoder = try t2.TagTreeEncoder.init(allocator, 2, 2, inclusion_values[0..]);
    defer inclusion_encoder.deinit();
    var zero_encoder = try t2.TagTreeEncoder.init(allocator, 2, 2, zero_bitplane_values[0..]);
    defer zero_encoder.deinit();
    var write_states = [_]t2.CodeBlockPacketState{.{}} ** 4;

    {
        var writer = t2.PacketHeaderWriter.init(allocator, &bytes);
        const blocks = [_]t2.PacketBlock{
            .{ .leaf_x = 0, .leaf_y = 0, .included = true, .zero_bitplanes = 5, .pass_count = 7, .byte_length = 321 },
            .{ .leaf_x = 1, .leaf_y = 0, .included = false },
            .{ .leaf_x = 0, .leaf_y = 1, .included = true, .zero_bitplanes = 4, .pass_count = 1, .byte_length = 8 },
            .{ .leaf_x = 1, .leaf_y = 1, .included = false },
        };
        try t2.writePrecinctPacketHeader(&writer, &inclusion_encoder, &zero_encoder, write_states[0..], 0, blocks[0..]);
        try writer.finish();
    }

    const second_packet_offset = bytes.items.len;
    {
        var writer = t2.PacketHeaderWriter.init(allocator, &bytes);
        const blocks = [_]t2.PacketBlock{
            .{ .leaf_x = 0, .leaf_y = 0, .included = true, .pass_count = 2, .byte_length = 17 },
            .{ .leaf_x = 1, .leaf_y = 0, .included = true, .zero_bitplanes = 2, .pass_count = 1, .byte_length = 9 },
            .{ .leaf_x = 0, .leaf_y = 1, .included = false },
            .{ .leaf_x = 1, .leaf_y = 1, .included = false },
        };
        try t2.writePrecinctPacketHeader(&writer, &inclusion_encoder, &zero_encoder, write_states[0..], 1, blocks[0..]);
        try writer.finish();
    }

    var inclusion_decoder = try t2.TagTreeDecoder.init(allocator, 2, 2);
    defer inclusion_decoder.deinit();
    var zero_decoder = try t2.TagTreeDecoder.init(allocator, 2, 2);
    defer zero_decoder.deinit();
    var read_states = [_]t2.CodeBlockPacketState{.{}} ** 4;
    var decoded: [4]t2.DecodedPacketBlock = undefined;

    var first_reader = t2.PacketHeaderReader.init(bytes.items[0..second_packet_offset]);
    try std.testing.expect(try t2.readPrecinctPacketHeader(
        &first_reader,
        &inclusion_decoder,
        &zero_decoder,
        read_states[0..],
        0,
        locations[0..],
        8,
        decoded[0..],
    ));
    try first_reader.byteAlign();
    try std.testing.expectEqual(second_packet_offset, first_reader.bytesConsumed());
    try std.testing.expect(decoded[0].included);
    try std.testing.expect(decoded[0].first_inclusion);
    try std.testing.expectEqual(@as(u8, 5), decoded[0].zero_bitplanes);
    try std.testing.expectEqual(@as(u16, 7), decoded[0].pass_count);
    try std.testing.expectEqual(@as(u64, 321), decoded[0].byte_length);
    try std.testing.expect(!decoded[1].included);
    try std.testing.expect(decoded[2].included);
    try std.testing.expect(decoded[2].first_inclusion);
    try std.testing.expectEqual(@as(u8, 4), decoded[2].zero_bitplanes);
    try std.testing.expectEqual(@as(u64, 8), decoded[2].byte_length);
    try std.testing.expect(!decoded[3].included);

    var second_reader = t2.PacketHeaderReader.init(bytes.items[second_packet_offset..]);
    try std.testing.expect(try t2.readPrecinctPacketHeader(
        &second_reader,
        &inclusion_decoder,
        &zero_decoder,
        read_states[0..],
        1,
        locations[0..],
        8,
        decoded[0..],
    ));
    try second_reader.byteAlign();
    try std.testing.expectEqual(bytes.items.len - second_packet_offset, second_reader.bytesConsumed());
    try std.testing.expect(decoded[0].included);
    try std.testing.expect(!decoded[0].first_inclusion);
    try std.testing.expectEqual(@as(u16, 2), decoded[0].pass_count);
    try std.testing.expectEqual(@as(u64, 17), decoded[0].byte_length);
    try std.testing.expect(decoded[1].included);
    try std.testing.expect(decoded[1].first_inclusion);
    try std.testing.expectEqual(@as(u8, 2), decoded[1].zero_bitplanes);
    try std.testing.expectEqual(@as(u64, 9), decoded[1].byte_length);
    try std.testing.expect(!decoded[2].included);
    try std.testing.expect(!decoded[3].included);
    try std.testing.expectEqualSlices(t2.CodeBlockPacketState, write_states[0..], read_states[0..]);
}

test "9/7 wavelet roundtrips within floating point tolerance" {
    const allocator = std.testing.allocator;
    const width = 6;
    const height = 3;

    var data = [_]f32{
        3.5, 5.0, 8.5,  13.0, 21.0, 34.0,
        1.0, 4.0, 9.0,  16.0, 25.0, 36.0,
        2.0, 6.0, 12.0, 20.0, 30.0, 42.0,
    };
    const original = data;

    const levels = try wavelet.forward2D(
        allocator,
        data[0..],
        width,
        height,
        2,
        .irreversible_9_7,
    );
    try wavelet.inverse2D(allocator, data[0..], width, height, levels, .irreversible_9_7);

    for (data, original) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.01);
    }
}

test "9/7 wavelet roundtrips odd scaling tails" {
    const allocator = std.testing.allocator;
    const width = 5;
    const height = 5;

    var data = [_]f32{
        1.0,  2.5,  4.0,  8.0,   16.0,
        3.0,  5.5,  9.0,  14.0,  22.0,
        7.0,  11.0, 18.0, 29.0,  47.0,
        -1.0, -3.0, -8.0, -13.0, -21.0,
        31.0, 0.25, -0.5, 63.0,  127.0,
    };
    const original = data;

    const levels = try wavelet.forward2D(
        allocator,
        data[0..],
        width,
        height,
        3,
        .irreversible_9_7,
    );
    try wavelet.inverse2D(allocator, data[0..], width, height, levels, .irreversible_9_7);

    for (data, original) |actual, expected| {
        try std.testing.expectApproxEqAbs(expected, actual, 0.015);
    }
}

test "codec encodes and decodes a small grayscale image" {
    const allocator = std.testing.allocator;
    const pixels = try allocator.dupe(u8, &[_]u8{
        0,   16,  32,  48,
        64,  80,  96,  112,
        128, 144, 160, 176,
        192, 208, 224, 255,
    });
    defer allocator.free(pixels);

    const input = image.Image{
        .allocator = allocator,
        .width = 4,
        .height = 4,
        .pixels = pixels,
    };

    const encoded = try codec.encodeImage(allocator, input, .{
        .wavelet = .reversible_5_3,
        .levels = 2,
        .quant_step = 1.0,
    });
    defer allocator.free(encoded);

    var decoded = try codec.decodeImage(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(input.width, decoded.image.width);
    try std.testing.expectEqual(input.height, decoded.image.height);
    try std.testing.expectEqualSlices(u8, input.pixels, decoded.image.pixels);
}

test "TIFF parser reads uncompressed RGB strip with per-component sample format" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    try bytes.appendSlice(allocator, "II");
    try appendU16Le(allocator, &bytes, 42);
    try appendU32Le(allocator, &bytes, 8);

    try appendU16Le(allocator, &bytes, 10);
    try appendIfdEntryLe(allocator, &bytes, 256, 4, 1, 2);
    try appendIfdEntryLe(allocator, &bytes, 257, 4, 1, 1);
    try appendIfdEntryLe(allocator, &bytes, 258, 3, 3, 134);
    try appendIfdEntryLe(allocator, &bytes, 259, 3, 1, 1);
    try appendIfdEntryLe(allocator, &bytes, 262, 3, 1, 2);
    try appendIfdEntryLe(allocator, &bytes, 273, 4, 1, 146);
    try appendIfdEntryLe(allocator, &bytes, 277, 3, 1, 3);
    try appendIfdEntryLe(allocator, &bytes, 339, 3, 3, 140);
    try appendIfdEntryLe(allocator, &bytes, 279, 4, 1, 6);
    try appendIfdEntryLe(allocator, &bytes, 284, 3, 1, 1);
    try appendU32Le(allocator, &bytes, 0);

    try appendU16Le(allocator, &bytes, 8);
    try appendU16Le(allocator, &bytes, 8);
    try appendU16Le(allocator, &bytes, 8);
    try appendU16Le(allocator, &bytes, 1);
    try appendU16Le(allocator, &bytes, 1);
    try appendU16Le(allocator, &bytes, 1);
    try bytes.appendSlice(allocator, &.{ 10, 20, 30, 40, 50, 60 });

    var rgb = try tiff.parseRgb(allocator, bytes.items);
    defer rgb.deinit();

    try std.testing.expectEqual(@as(usize, 2), rgb.width);
    try std.testing.expectEqual(@as(usize, 1), rgb.height);
    try std.testing.expectEqual(@as(u8, 8), rgb.bit_depth);
    try std.testing.expectEqualSlices(u16, &.{ 10, 20, 30, 40, 50, 60 }, rgb.samples);
}

test "DNG info parser reads primary IFD metadata and SubIFD summaries" {
    const allocator = std.testing.allocator;
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(allocator);

    const ifd0_offset: u32 = 8;
    const ifd0_entries: u16 = 15;
    const ifd0_end: u32 = ifd0_offset + 2 + @as(u32, ifd0_entries) * 12 + 4;
    const make_offset = ifd0_end;
    const model_offset = make_offset + 6;
    const unique_offset = model_offset + 6;
    const subifd_offset = unique_offset + 10;

    try bytes.appendSlice(allocator, "II");
    try appendU16Le(allocator, &bytes, 42);
    try appendU32Le(allocator, &bytes, ifd0_offset);

    try appendU16Le(allocator, &bytes, ifd0_entries);
    try appendIfdEntryLe(allocator, &bytes, 254, 4, 1, 0);
    try appendIfdEntryLe(allocator, &bytes, 256, 4, 1, 2);
    try appendIfdEntryLe(allocator, &bytes, 257, 4, 1, 2);
    try appendIfdEntryLe(allocator, &bytes, 258, 3, 1, 16);
    try appendIfdEntryLe(allocator, &bytes, 259, 3, 1, 1);
    try appendIfdEntryLe(allocator, &bytes, 262, 3, 1, 32803);
    try appendIfdEntryLe(allocator, &bytes, 271, 2, 6, make_offset);
    try appendIfdEntryLe(allocator, &bytes, 272, 2, 6, model_offset);
    try appendIfdEntryLe(allocator, &bytes, 277, 3, 1, 1);
    try appendIfdEntryLe(allocator, &bytes, 330, 4, 1, subifd_offset);
    try appendIfdEntryLe(allocator, &bytes, 33421, 3, 2, 2 | (@as(u32, 2) << 16));
    try appendIfdEntryLe(allocator, &bytes, 33422, 1, 4, 0 | (@as(u32, 1) << 8) | (@as(u32, 1) << 16) | (@as(u32, 2) << 24));
    try appendIfdEntryLe(allocator, &bytes, 50706, 1, 4, 1 | (@as(u32, 4) << 8));
    try appendIfdEntryLe(allocator, &bytes, 50707, 1, 4, 1 | (@as(u32, 1) << 8));
    try appendIfdEntryLe(allocator, &bytes, 50708, 2, 10, unique_offset);
    try appendU32Le(allocator, &bytes, 0);
    try bytes.appendSlice(allocator, "Codex\x00");
    try bytes.appendSlice(allocator, "Z2000\x00");
    try bytes.appendSlice(allocator, "Synthetic\x00");
    try std.testing.expectEqual(@as(usize, subifd_offset), bytes.items.len);

    try appendU16Le(allocator, &bytes, 8);
    try appendIfdEntryLe(allocator, &bytes, 254, 4, 1, 1);
    try appendIfdEntryLe(allocator, &bytes, 256, 4, 1, 640);
    try appendIfdEntryLe(allocator, &bytes, 257, 4, 1, 480);
    try appendIfdEntryLe(allocator, &bytes, 258, 3, 3, subifd_offset + 2 + 8 * 12 + 4);
    try appendIfdEntryLe(allocator, &bytes, 259, 3, 1, 1);
    try appendIfdEntryLe(allocator, &bytes, 262, 3, 1, 2);
    try appendIfdEntryLe(allocator, &bytes, 277, 3, 1, 3);
    try appendIfdEntryLe(allocator, &bytes, 339, 3, 1, 1);
    try appendU32Le(allocator, &bytes, 0);
    try appendU16Le(allocator, &bytes, 8);
    try appendU16Le(allocator, &bytes, 8);
    try appendU16Le(allocator, &bytes, 8);

    const info = try dng.parseInfo(bytes.items);
    try std.testing.expectEqualStrings("Codex", info.make.?);
    try std.testing.expectEqualStrings("Z2000", info.model.?);
    try std.testing.expectEqualStrings("Synthetic", info.unique_camera_model.?);
    try std.testing.expectEqual(@as(usize, 2), info.ifd_count);
    try std.testing.expectEqual(@as(u8, 1), info.dng_version.?.bytes[0]);
    try std.testing.expectEqual(@as(u8, 4), info.dng_version.?.bytes[1]);
    try std.testing.expectEqual(@as(u16, 2), info.cfa_repeat.?[0]);
    try std.testing.expectEqual(@as(u8, 2), info.cfa_pattern.?[3]);
    try std.testing.expectEqual(@as(u32, 640), info.ifds[1].width.?);
    try std.testing.expectEqual(@as(u16, 3), info.ifds[1].samples_per_pixel.?);
    try std.testing.expect(info.ifds[1].is_subifd);
}

test "JP2 wrapper records RGB image header" {
    const allocator = std.testing.allocator;
    const samples = try allocator.dupe(u16, &.{ 10, 20, 30, 40, 50, 60 });
    defer allocator.free(samples);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = 2,
        .height = 1,
        .bit_depth = 8,
        .samples = samples,
    };

    const wrapped = try jp2.wrapRgbCodestream(allocator, rgb, "temporary-codestream");
    defer allocator.free(wrapped);

    const info = try jp2.parseInfo(wrapped);
    try std.testing.expectEqual(@as(u32, 2), info.width);
    try std.testing.expectEqual(@as(u32, 1), info.height);
    try std.testing.expectEqual(@as(u16, 3), info.components);
    try std.testing.expectEqual(@as(u8, 8), info.bits_per_component);
    try std.testing.expectEqual(@as(usize, 20), info.codestream_bytes);
}

test "RCT transform matches JPEG2000 reversible equations" {
    const allocator = std.testing.allocator;
    const samples = try allocator.dupe(u16, &.{ 10, 20, 30 });
    defer allocator.free(samples);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = 1,
        .height = 1,
        .bit_depth = 8,
        .samples = samples,
    };

    var planes = try color.forwardRct(allocator, rgb);
    defer planes.deinit();

    try std.testing.expectEqual(@as(i32, 20), planes.y[0]);
    try std.testing.expectEqual(@as(i32, 10), planes.cb[0]);
    try std.testing.expectEqual(@as(i32, -10), planes.cr[0]);

    var reconstructed = try color.inverseRct(allocator, planes);
    defer reconstructed.deinit();
    try std.testing.expectEqualSlices(u16, rgb.samples, reconstructed.samples);
}

test "RCT transform roundtrips a small RGB image" {
    const allocator = std.testing.allocator;
    const samples = try allocator.dupe(u16, &.{
        0,   0,   0,
        255, 255, 255,
        128, 64,  32,
        7,   200, 121,
    });
    defer allocator.free(samples);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = 2,
        .height = 2,
        .bit_depth = 8,
        .samples = samples,
    };

    var planes = try color.forwardRct(allocator, rgb);
    defer planes.deinit();

    var reconstructed = try color.inverseRct(allocator, planes);
    defer reconstructed.deinit();

    try std.testing.expectEqual(rgb.width, reconstructed.width);
    try std.testing.expectEqual(rgb.height, reconstructed.height);
    try std.testing.expectEqual(rgb.bit_depth, reconstructed.bit_depth);
    try std.testing.expectEqualSlices(u16, rgb.samples, reconstructed.samples);
}

test "RCT transform roundtrips vector block and tail" {
    const allocator = std.testing.allocator;
    const samples = try allocator.dupe(u16, &.{
        0,   1,   2,
        3,   5,   8,
        13,  21,  34,
        55,  89,  144,
        233, 144, 55,
    });
    defer allocator.free(samples);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = 5,
        .height = 1,
        .bit_depth = 8,
        .samples = samples,
    };

    var planes = try color.forwardRct(allocator, rgb);
    defer planes.deinit();

    var reconstructed = try color.inverseRct(allocator, planes);
    defer reconstructed.deinit();

    try std.testing.expectEqualSlices(u16, rgb.samples, reconstructed.samples);
}

test "integer 5/3 DWT roundtrips signed component plane" {
    const allocator = std.testing.allocator;
    const width = 5;
    const height = 4;
    var data = [_]i32{
        -5,  4,   13,   22,   31,
        40,  -49, 58,   67,   76,
        85,  94,  -103, 112,  121,
        130, 139, 148,  -157, 166,
    };
    const original = data;

    const levels = try wavelet_int.forward53(allocator, data[0..], width, height, 4);
    try wavelet_int.inverse53(allocator, data[0..], width, height, levels);

    try std.testing.expectEqualSlices(i32, original[0..], data[0..]);
}

test "integer 5/3 DWT workspace roundtrips signed component plane" {
    const allocator = std.testing.allocator;
    const width = 6;
    const height = 5;

    var data = [_]i32{
        5,   4,   3,   2,   1,   0,
        -1,  -2,  -3,  -4,  -5,  -6,
        7,   11,  13,  17,  19,  23,
        -29, 31,  -37, 41,  -43, 47,
        53,  -59, 61,  -67, 71,  -73,
    };
    const original = data;

    var workspace = try wavelet_int.Workspace.init(allocator, @max(width, height));
    defer workspace.deinit();

    const levels = try wavelet_int.forward53WithWorkspace(&workspace, data[0..], width, height, 4);
    try wavelet_int.inverse53WithWorkspace(&workspace, data[0..], width, height, levels);

    try std.testing.expectEqualSlices(i32, original[0..], data[0..]);
}

test "lossless codestream skeleton contains JPEG2000 markers" {
    const allocator = std.testing.allocator;
    const samples = try allocator.dupe(u16, &.{
        10,  20,  30,
        40,  50,  60,
        70,  80,  90,
        100, 110, 120,
    });
    defer allocator.free(samples);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = 2,
        .height = 2,
        .bit_depth = 8,
        .samples = samples,
    };

    const bytes = try codestream.encodeLosslessSkeleton(allocator, rgb, 2);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(u8, 0xff), bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x4f), bytes[1]);
    try std.testing.expect(codestream.hasMarker(bytes, codestream.markerValue("siz")));
    try std.testing.expect(codestream.hasMarker(bytes, codestream.markerValue("cod")));
    try std.testing.expect(codestream.hasMarker(bytes, codestream.markerValue("tlm")));
    try std.testing.expect(codestream.hasMarker(bytes, codestream.markerValue("qcd")));
    try std.testing.expect(codestream.hasMarker(bytes, codestream.markerValue("sot")));
    try std.testing.expect(codestream.hasMarker(bytes, codestream.markerValue("sop")));
    try std.testing.expect(codestream.hasMarker(bytes, codestream.markerValue("eph")));
    try std.testing.expect(codestream.hasMarker(bytes, codestream.markerValue("sod")));
    try std.testing.expect(codestream.hasMarker(bytes, codestream.markerValue("eoc")));
    try std.testing.expect(std.mem.indexOf(u8, bytes, "ZJ2K-CBLK-BP5") != null);

    const sot_index = findMarker(bytes, codestream.markerValue("sot")) orelse return error.MissingSot;
    const psot = try codestream.firstSotPsot(bytes);
    const ptlm = try codestream.firstTlmPtlm(bytes);
    const stats = try codestream.analyzeLosslessTemporary(bytes);
    const expected_tile_parts = @as(usize, stats.levels) + 1;
    try std.testing.expectEqual(psot, ptlm);
    try std.testing.expectEqual(expected_tile_parts, countMarker(bytes, codestream.markerValue("sot")));
    try std.testing.expectEqual(@as(usize, @intCast(stats.packet_count)), try countTilePartPrefixMarker(bytes, codestream.markerValue("sop")));
    try std.testing.expectEqual(@as(usize, @intCast(stats.packet_count)), try countTilePartPrefixMarker(bytes, codestream.markerValue("eph")));
    try std.testing.expectEqual(codestream.markerValue("sot"), readU16BeTest(bytes, sot_index + psot));
}

test "profiled lossless codestream matches normal encoder" {
    const allocator = std.testing.allocator;
    const samples = try allocator.dupe(u16, &.{
        10,  20,  30,
        40,  50,  60,
        70,  80,  90,
        100, 110, 120,
    });
    defer allocator.free(samples);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = 2,
        .height = 2,
        .bit_depth = 8,
        .samples = samples,
    };

    const normal = try codestream.encodeLosslessWithOptions(allocator, rgb, .{ .levels = 2 });
    defer allocator.free(normal);

    var timings = codestream.EncodeTimings{};
    const profiled = try codestream.encodeLosslessWithOptionsProfiled(allocator, rgb, .{ .levels = 2 }, &timings);
    defer allocator.free(profiled);

    try std.testing.expectEqualSlices(u8, normal, profiled);
    try std.testing.expect(timings.total_ns >= timings.color_transform_ns);
    try std.testing.expect(timings.total_ns >= timings.wavelet_ns);
    try std.testing.expect(timings.total_ns >= timings.payload_ns);
    try std.testing.expect(timings.total_ns >= timings.marker_ns);
}

test "subband partition produces LL and high-pass bands" {
    const allocator = std.testing.allocator;
    const bands = try subband.makeBands(allocator, 5, 4, 2);
    defer allocator.free(bands);

    try std.testing.expectEqual(@as(usize, 7), bands.len);
    try std.testing.expectEqual(subband.Kind.ll, bands[0].kind);
    try std.testing.expectEqual(@as(u8, 2), bands[0].level);
    try std.testing.expectEqual(@as(usize, 2), bands[0].rect.width);
    try std.testing.expectEqual(@as(usize, 1), bands[0].rect.height);

    const blocks = try subband.makeCodeBlocks(allocator, bands, 2, 2);
    defer allocator.free(blocks);
    try std.testing.expect(blocks.len >= bands.len);
    try std.testing.expectEqual(@as(usize, 0), blocks[0].rect.x);
    try std.testing.expectEqual(@as(usize, 0), blocks[0].rect.y);
}

test "raw bitplane block writer emits compact block data" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{
        0, 0,  0, 0,
        0, -3, 0, 0,
        0, 0,  5, 0,
        0, 0,  0, 0,
    };

    var encoded = try bitplane.encodeBlock(allocator, plane[0..], 4, .{
        .x = 0,
        .y = 0,
        .width = 4,
        .height = 4,
    });
    defer encoded.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), encoded.active_rect.x);
    try std.testing.expectEqual(@as(usize, 1), encoded.active_rect.y);
    try std.testing.expectEqual(@as(usize, 2), encoded.active_rect.width);
    try std.testing.expectEqual(@as(usize, 2), encoded.active_rect.height);
    try std.testing.expectEqual(@as(u8, 3), encoded.bitplanes);
    try std.testing.expectEqual(@as(u32, 2), encoded.non_zero_count);
    try std.testing.expect(encoded.bytes.len < plane.len * @sizeOf(i32));
}

test "bitplane packet contribution bridges T1 metadata into T2 fields" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{
        0, -7,
        0, 3,
    };

    var encoded = try bitplane.encodeBlockPasses(allocator, plane[0..], 2, .{
        .x = 0,
        .y = 0,
        .width = 2,
        .height = 2,
    });
    defer encoded.deinit(allocator);

    const contribution = try bitplane.packetContribution(8, encoded);
    try std.testing.expect(contribution.included);
    try std.testing.expectEqual(@as(u8, 5), contribution.zero_bitplanes);
    try std.testing.expectEqual(@as(u16, 7), contribution.pass_count);
    try std.testing.expectEqual(
        @as(u64, @intCast(encoded.significance_bytes.len + encoded.refinement_bytes.len + encoded.cleanup_bytes.len)),
        contribution.byte_length,
    );
    try std.testing.expectError(bitplane.BitplaneError.InvalidBlock, bitplane.packetContribution(2, encoded));

    const empty_plane = [_]i32{ 0, 0, 0, 0 };
    var empty = try bitplane.encodeBlockPasses(allocator, empty_plane[0..], 2, .{
        .x = 0,
        .y = 0,
        .width = 2,
        .height = 2,
    });
    defer empty.deinit(allocator);

    const empty_contribution = try bitplane.packetContribution(8, empty);
    try std.testing.expect(!empty_contribution.included);
    try std.testing.expectEqual(@as(u8, 0), empty_contribution.zero_bitplanes);
    try std.testing.expectEqual(@as(u16, 0), empty_contribution.pass_count);
    try std.testing.expectEqual(@as(u64, 0), empty_contribution.byte_length);
}

test "entropy auto codec roundtrips repetitive and literal bytes" {
    const allocator = std.testing.allocator;
    const input = "aaaaaaaabbbbccccxyz0123456789aaaa";
    var encoded = try entropy.encodeAuto(allocator, input);
    defer encoded.deinit(allocator);

    const decoded = try entropy.decode(allocator, encoded.method, encoded.raw_len, encoded.bytes);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, input, decoded);
}

test "entropy auto codec uses bit runs for sparse binary streams" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0x00, 0x00, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00 };
    var encoded = try entropy.encodeAuto(allocator, input[0..]);
    defer encoded.deinit(allocator);

    try std.testing.expectEqual(entropy.Method.bit_rle, encoded.method);

    const decoded = try entropy.decode(allocator, encoded.method, encoded.raw_len, encoded.bytes);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, input[0..], decoded);
}

test "entropy auto borrowed raw avoids copying incompressible streams" {
    const allocator = std.testing.allocator;
    const input = [_]u8{ 0x13, 0x57, 0x9b, 0xdf, 0x24, 0x68, 0xac, 0xf0 };

    var encoded = try entropy.encodeAutoBorrowingRaw(allocator, input[0..]);
    defer encoded.deinit(allocator);

    try std.testing.expectEqual(entropy.Method.raw, encoded.method);
    try std.testing.expectEqual(@as(u32, input.len), encoded.raw_len);
    try std.testing.expect(encoded.owned_bytes == null);
    try std.testing.expectEqualSlices(u8, input[0..], encoded.bytes);
}

test "arithmetic entropy codec roundtrips biased stream" {
    const allocator = std.testing.allocator;
    var input = [_]u8{0} ** 128;
    for (&input, 0..) |*byte, i| {
        byte.* = if (i % 7 == 0) 0x10 else if (i % 11 == 0) 0x01 else 0x00;
    }

    var encoded = try entropy.encodeWithMethod(allocator, .arith, input[0..]);
    defer encoded.deinit(allocator);
    try std.testing.expectEqual(entropy.Method.arith, encoded.method);

    const decoded = try entropy.decode(allocator, encoded.method, encoded.raw_len, encoded.bytes);
    defer allocator.free(decoded);

    try std.testing.expectEqualSlices(u8, input[0..], decoded);
}

test "MQ coder roundtrips short multi-context symbol stream" {
    const allocator = std.testing.allocator;
    const symbols = [_]mq.Symbol{
        .{ .context = 0, .bit = false },
        .{ .context = 1, .bit = true },
        .{ .context = 0, .bit = false },
        .{ .context = 1, .bit = true },
        .{ .context = 2, .bit = true },
        .{ .context = 2, .bit = false },
        .{ .context = 0, .bit = true },
    };

    var encoded = try mq.encode(allocator, 3, symbols[0..]);
    defer encoded.deinit(allocator);
    try expectMarkerStuffingIsValid(encoded.bytes);

    const contexts = try mqContextsFromSymbols(allocator, symbols[0..]);
    defer allocator.free(contexts);
    const decoded = try mq.decode(allocator, 3, encoded.bytes, encoded.symbol_count, contexts);
    defer allocator.free(decoded);
    try expectMqBitsEqual(symbols[0..], decoded);
}

test "MQ coder roundtrips all-zero and all-one streams" {
    const allocator = std.testing.allocator;
    const zeros = [_]mq.Symbol{.{ .context = 0, .bit = false }} ** 256;
    const ones = [_]mq.Symbol{.{ .context = 0, .bit = true }} ** 256;

    var encoded_zeros = try mq.encode(allocator, 1, zeros[0..]);
    defer encoded_zeros.deinit(allocator);
    try expectMarkerStuffingIsValid(encoded_zeros.bytes);
    const zero_contexts = try mqContextsFromSymbols(allocator, zeros[0..]);
    defer allocator.free(zero_contexts);
    const decoded_zeros = try mq.decode(allocator, 1, encoded_zeros.bytes, encoded_zeros.symbol_count, zero_contexts);
    defer allocator.free(decoded_zeros);
    try expectMqBitsEqual(zeros[0..], decoded_zeros);

    var encoded_ones = try mq.encode(allocator, 1, ones[0..]);
    defer encoded_ones.deinit(allocator);
    try expectMarkerStuffingIsValid(encoded_ones.bytes);
    const one_contexts = try mqContextsFromSymbols(allocator, ones[0..]);
    defer allocator.free(one_contexts);
    const decoded_ones = try mq.decode(allocator, 1, encoded_ones.bytes, encoded_ones.symbol_count, one_contexts);
    defer allocator.free(decoded_ones);
    try expectMqBitsEqual(ones[0..], decoded_ones);
}

test "MQ coder roundtrips alternating stream" {
    const allocator = std.testing.allocator;
    var symbols: [257]mq.Symbol = undefined;
    for (&symbols, 0..) |*symbol, index| {
        symbol.* = .{ .context = index % 3, .bit = (index % 2) != 0 };
    }

    var encoded = try mq.encode(allocator, 3, symbols[0..]);
    defer encoded.deinit(allocator);
    try expectMarkerStuffingIsValid(encoded.bytes);
    const contexts = try mqContextsFromSymbols(allocator, symbols[0..]);
    defer allocator.free(contexts);
    const decoded = try mq.decode(allocator, 3, encoded.bytes, encoded.symbol_count, contexts);
    defer allocator.free(decoded);
    try expectMqBitsEqual(symbols[0..], decoded);
}

test "MQ coder resetContext keeps encoder and decoder synchronized" {
    const allocator = std.testing.allocator;
    const before = [_]mq.Symbol{
        .{ .context = 0, .bit = true },
        .{ .context = 0, .bit = true },
        .{ .context = 0, .bit = false },
        .{ .context = 0, .bit = true },
    };
    const after = [_]mq.Symbol{
        .{ .context = 0, .bit = false },
        .{ .context = 0, .bit = false },
        .{ .context = 0, .bit = true },
        .{ .context = 0, .bit = false },
    };

    var encoder = try mq.Encoder.init(allocator, 1);
    defer encoder.deinit();
    for (before) |symbol| try encoder.write(symbol.context, symbol.bit);
    try encoder.resetContext(0);
    for (after) |symbol| try encoder.write(symbol.context, symbol.bit);
    var encoded = try encoder.finish();
    defer encoded.deinit(allocator);
    try expectMarkerStuffingIsValid(encoded.bytes);

    var decoder = try mq.Decoder.init(allocator, 1, encoded.bytes, encoded.symbol_count);
    defer decoder.deinit();
    for (before) |symbol| {
        try std.testing.expectEqual(symbol.bit, try decoder.read(symbol.context));
    }
    try decoder.resetContext(0);
    for (after) |symbol| {
        try std.testing.expectEqual(symbol.bit, try decoder.read(symbol.context));
    }
}

test "bitplane reports ISO-style coding pass counts" {
    try std.testing.expectEqual(@as(u16, 0), bitplane.isoCodingPassCount(0, 0));
    try std.testing.expectEqual(@as(u16, 1), bitplane.isoCodingPassCount(1, 4));
    try std.testing.expectEqual(@as(u16, 22), bitplane.isoCodingPassCount(8, 1));
}

test "bitplane exposes ISO-style coding pass order" {
    const expected = [_]bitplane.CodingPass{
        .{ .kind = .cleanup, .magnitude_bitplane = 2 },
        .{ .kind = .significance, .magnitude_bitplane = 1 },
        .{ .kind = .refinement, .magnitude_bitplane = 1 },
        .{ .kind = .cleanup, .magnitude_bitplane = 1 },
        .{ .kind = .significance, .magnitude_bitplane = 0 },
        .{ .kind = .refinement, .magnitude_bitplane = 0 },
        .{ .kind = .cleanup, .magnitude_bitplane = 0 },
    };

    for (expected, 0..) |pass, index| {
        try std.testing.expectEqual(pass, try bitplane.codingPassAt(3, 4, @intCast(index)));
    }
    try std.testing.expectError(bitplane.BitplaneError.InvalidBlock, bitplane.codingPassAt(3, 4, expected.len));
    try std.testing.expectError(bitplane.BitplaneError.InvalidBlock, bitplane.codingPassAt(0, 0, 0));
}

test "EBCOT cleanup pass emits top bitplane significance and sign symbols" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{
        0, -4,
        2, 0,
    };

    var encoded = try ebcot.encodeBlock(allocator, plane[0..], 2, .{ .x = 0, .y = 0, .width = 2, .height = 2 });
    defer encoded.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 3), encoded.bitplanes);
    try std.testing.expectEqual(@as(u32, 2), encoded.non_zero_count);
    try std.testing.expectEqual(@as(usize, 7), encoded.passes.len);
    try std.testing.expectEqual(ebcot.PassKind.cleanup, encoded.passes[0].kind);
    try std.testing.expectEqual(@as(u8, 2), encoded.passes[0].magnitude_bitplane);

    const top = encoded.symbols[encoded.passes[0].first_symbol..][0..encoded.passes[0].symbol_count];
    try std.testing.expectEqual(@as(usize, 5), top.len);
    try std.testing.expectEqual(ebcot.SymbolKind.zero_coding, top[0].kind);
    try std.testing.expectEqual(false, top[0].bit);
    try std.testing.expectEqual(ebcot.SymbolKind.zero_coding, top[1].kind);
    try std.testing.expectEqual(false, top[1].bit);
    try std.testing.expectEqual(@as(usize, 0), top[1].x);
    try std.testing.expectEqual(@as(usize, 1), top[1].y);
    try std.testing.expectEqual(ebcot.SymbolKind.zero_coding, top[2].kind);
    try std.testing.expectEqual(true, top[2].bit);
    try std.testing.expectEqual(@as(usize, 1), top[2].x);
    try std.testing.expectEqual(@as(usize, 0), top[2].y);
    try std.testing.expectEqual(ebcot.SymbolKind.sign, top[3].kind);
    try std.testing.expectEqual(true, top[3].bit);
}

test "EBCOT significance propagation precedes cleanup on lower bitplanes" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{ 4, 2 };

    var encoded = try ebcot.encodeBlock(allocator, plane[0..], 2, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    defer encoded.deinit(allocator);

    try std.testing.expectEqual(ebcot.PassKind.cleanup, encoded.passes[0].kind);
    try std.testing.expectEqual(ebcot.PassKind.significance, encoded.passes[1].kind);
    try std.testing.expectEqual(ebcot.PassKind.refinement, encoded.passes[2].kind);
    try std.testing.expectEqual(ebcot.PassKind.cleanup, encoded.passes[3].kind);

    const sig = encoded.symbols[encoded.passes[1].first_symbol..][0..encoded.passes[1].symbol_count];
    try std.testing.expectEqual(@as(usize, 2), sig.len);
    try std.testing.expectEqual(ebcot.SymbolKind.zero_coding, sig[0].kind);
    try std.testing.expectEqual(true, sig[0].bit);
    try std.testing.expectEqual(@as(usize, 1), sig[0].x);
    try std.testing.expectEqual(ebcot.Context.zero1, sig[0].context);
    try std.testing.expectEqual(ebcot.SymbolKind.sign, sig[1].kind);
    try std.testing.expectEqual(false, sig[1].bit);

    const refinement = encoded.symbols[encoded.passes[2].first_symbol..][0..encoded.passes[2].symbol_count];
    try std.testing.expectEqual(@as(usize, 1), refinement.len);
    try std.testing.expectEqual(ebcot.SymbolKind.magnitude_refinement, refinement[0].kind);
    try std.testing.expectEqual(@as(usize, 0), refinement[0].x);
    try std.testing.expectEqual(false, refinement[0].bit);
}

test "EBCOT scratch encoder reuses block state buffers" {
    const allocator = std.testing.allocator;
    const first_plane = [_]i32{
        0, -4, 0, 1,
        2, 0,  0, 0,
        0, 0,  3, 0,
        0, 0,  0, 0,
    };
    const second_plane = [_]i32{ 4, 2 };

    var scratch = ebcot.BlockScratch.init(allocator);
    defer scratch.deinit();

    const first = try ebcot.encodeBlockScratch(&scratch, first_plane[0..], 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    try std.testing.expectEqual(@as(usize, 7), first.passes.len);
    try std.testing.expect(first.symbols.len > 0);
    const significant_capacity = scratch.significant.capacity;
    const visited_capacity = scratch.visited.capacity;
    const became_capacity = scratch.became_significant.capacity;
    const pass_capacity = scratch.passes.capacity;
    const symbol_capacity = scratch.symbols.capacity;

    const second = try ebcot.encodeBlockScratch(&scratch, second_plane[0..], 2, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    try std.testing.expectEqual(@as(usize, 7), second.passes.len);
    try std.testing.expect(second.symbols.len < first.symbols.len);
    try std.testing.expectEqual(significant_capacity, scratch.significant.capacity);
    try std.testing.expectEqual(visited_capacity, scratch.visited.capacity);
    try std.testing.expectEqual(became_capacity, scratch.became_significant.capacity);
    try std.testing.expectEqual(pass_capacity, scratch.passes.capacity);
    try std.testing.expectEqual(symbol_capacity, scratch.symbols.capacity);
}

test "raw bitplane block writer roundtrips a block" {
    const allocator = std.testing.allocator;
    const original = [_]i32{
        0, -7,  0,  5,
        1, 0,   -2, 0,
        0, 0,   0,  0,
        9, -12, 0,  4,
    };
    var decoded = [_]i32{0} ** original.len;

    var encoded = try bitplane.encodeBlock(allocator, original[0..], 4, .{
        .x = 0,
        .y = 0,
        .width = 4,
        .height = 4,
    });
    defer encoded.deinit(allocator);

    try bitplane.decodeBlock(
        decoded[0..],
        4,
        encoded.active_rect,
        encoded.bitplanes,
        encoded.non_zero_count,
        encoded.bytes,
    );

    try std.testing.expectEqualSlices(i32, original[0..], decoded[0..]);
}

test "bitplane refinement packing roundtrips full vector groups" {
    const allocator = std.testing.allocator;
    const original = [_]i32{
        1,  -2,  3,   -4,
        5,  -6,  7,   -8,
        9,  -10, 11,  -12,
        13, -14, 127, -128,
    };
    var decoded = [_]i32{0} ** original.len;

    var encoded = try bitplane.encodeBlock(allocator, original[0..], 4, .{
        .x = 0,
        .y = 0,
        .width = 4,
        .height = 4,
    });
    defer encoded.deinit(allocator);

    try std.testing.expect(encoded.non_zero_count >= 16);
    try std.testing.expect(encoded.refinement_bytes.len >= encoded.bitplanes * 2);

    try bitplane.decodeBlock(
        decoded[0..],
        4,
        encoded.active_rect,
        encoded.bitplanes,
        encoded.non_zero_count,
        encoded.bytes,
    );

    try std.testing.expectEqualSlices(i32, original[0..], decoded[0..]);
}

test "bitplane significance writer preserves unaligned zero SIMD groups" {
    const allocator = std.testing.allocator;
    const original = [_]i32{
        1, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 1,
    };
    var decoded = [_]i32{0} ** original.len;

    var encoded = try bitplane.encodeBlock(allocator, original[0..], 12, .{
        .x = 0,
        .y = 0,
        .width = 12,
        .height = 1,
    });
    defer encoded.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 1), encoded.bitplanes);
    try std.testing.expectEqual(@as(u32, 2), encoded.non_zero_count);
    try std.testing.expectEqualSlices(u8, &.{ 0x80, 0x08 }, encoded.significance_bytes);
    try std.testing.expectEqualSlices(u8, &.{0xc0}, encoded.refinement_bytes);

    try bitplane.decodeBlock(
        decoded[0..],
        12,
        encoded.active_rect,
        encoded.bitplanes,
        encoded.non_zero_count,
        encoded.bytes,
    );

    try std.testing.expectEqualSlices(i32, original[0..], decoded[0..]);
}

test "temporary lossless codestream roundtrips RGB samples" {
    const allocator = std.testing.allocator;
    const samples = try allocator.dupe(u16, &.{
        0,   0,   0,
        255, 0,   0,
        0,   255, 0,
        0,   0,   255,
        30,  60,  90,
        120, 150, 180,
    });
    defer allocator.free(samples);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = 3,
        .height = 2,
        .bit_depth = 8,
        .samples = samples,
    };

    const bytes = try codestream.encodeLosslessSkeleton(allocator, rgb, 2);
    defer allocator.free(bytes);

    var decoded = try codestream.decodeLosslessTemporary(allocator, bytes);
    defer decoded.deinit();

    try std.testing.expectEqual(rgb.width, decoded.width);
    try std.testing.expectEqual(rgb.height, decoded.height);
    try std.testing.expectEqual(rgb.bit_depth, decoded.bit_depth);
    try std.testing.expectEqualSlices(u16, rgb.samples, decoded.samples);
}

test "threaded temporary lossless codestream roundtrips RGB samples" {
    const allocator = std.testing.allocator;
    const width = 8;
    const height = 4;
    const samples = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(samples);
    for (0..width * height) |i| {
        samples[i * 3 + 0] = @as(u16, @intCast((i * 5) % 251));
        samples[i * 3 + 1] = @as(u16, @intCast((i * 7 + 3) % 251));
        samples[i * 3 + 2] = @as(u16, @intCast((i * 11 + 9) % 251));
    }

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = width,
        .height = height,
        .bit_depth = 8,
        .samples = samples,
    };

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 2,
        .block_width = 32,
        .block_height = 32,
        .threads = 3,
    });
    defer allocator.free(bytes);
    const serial_bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 2,
        .block_width = 32,
        .block_height = 32,
        .threads = 1,
    });
    defer allocator.free(serial_bytes);
    const two_thread_bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 2,
        .block_width = 32,
        .block_height = 32,
        .threads = 2,
    });
    defer allocator.free(two_thread_bytes);
    try std.testing.expectEqualSlices(u8, serial_bytes, two_thread_bytes);
    try std.testing.expectEqualSlices(u8, serial_bytes, bytes);

    var decoded = try codestream.decodeLosslessTemporaryWithOptions(allocator, bytes, .{ .threads = 3 });
    defer decoded.deinit();

    try std.testing.expectEqualSlices(u16, rgb.samples, decoded.samples);
}

test "temporary codestream analyzer reports block and stream stats" {
    const allocator = std.testing.allocator;
    const samples = try allocator.dupe(u16, &.{
        0,   0,   0,
        32,  16,  8,
        64,  32,  16,
        96,  48,  24,
        128, 64,  32,
        160, 80,  40,
        192, 96,  48,
        224, 112, 56,
    });
    defer allocator.free(samples);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = 4,
        .height = 2,
        .bit_depth = 8,
        .samples = samples,
    };

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 1,
        .layers = 3,
        .block_width = 32,
        .block_height = 32,
    });
    defer allocator.free(bytes);

    const stats = try codestream.analyzeLosslessTemporary(bytes);
    try std.testing.expectEqual(rgb.width, stats.width);
    try std.testing.expectEqual(rgb.height, stats.height);
    try std.testing.expectEqual(rgb.bit_depth, stats.bit_depth);
    try std.testing.expectEqual(@as(u8, 1), stats.levels);
    try std.testing.expectEqual(@as(u16, 3), stats.layers);
    try std.testing.expectEqual(@as(u16, 32), stats.block_width);
    try std.testing.expectEqual(@as(u16, 32), stats.block_height);
    try std.testing.expectEqual(@as(?u8, 'R'), stats.tile_part_divisions);
    try std.testing.expectEqual(@as(u8, 2), stats.tile_part_plan_count);
    try std.testing.expectEqual(@as(u8, 0), stats.tile_part_plan[0]);
    try std.testing.expectEqual(@as(u8, 1), stats.tile_part_plan[1]);
    try std.testing.expectEqual(@as(u8, 2), stats.packet_plan_count);
    try std.testing.expectEqual(@as(u64, 18), stats.packet_count);
    try std.testing.expectEqual(@as(u32, 2), stats.packet_plan[0].width);
    try std.testing.expectEqual(@as(u32, 1), stats.packet_plan[0].height);
    try std.testing.expectEqual(@as(u64, 9), stats.packet_plan[0].packets);
    try std.testing.expectEqual(@as(u32, 4), stats.packet_plan[1].width);
    try std.testing.expectEqual(@as(u32, 2), stats.packet_plan[1].height);
    try std.testing.expectEqual(@as(u64, 9), stats.packet_plan[1].packets);
    try std.testing.expect(stats.payload_bytes < stats.codestream_bytes);
    try std.testing.expect(stats.components[0].blocks > 0);
    try std.testing.expect(stats.components[0].coding_passes > 0);
    try std.testing.expect(stats.components[0].quality_layers[0].blocks > 0);
    try std.testing.expect(stats.components[0].quality_layers[1].cumulative_passes >= stats.components[0].quality_layers[0].cumulative_passes);
    try std.testing.expectEqual(stats.components[0].coding_passes, stats.components[0].quality_layers[2].cumulative_passes);
    try std.testing.expect(stats.components[0].pass_streams[@intFromEnum(codestream.PassKind.significance)].streams > 0);
    try std.testing.expectEqual(
        @as(u64, 0),
        stats.components[0].pass_streams[@intFromEnum(codestream.PassKind.cleanup)].raw_bytes,
    );
}

test "quality-layer rate allocation records truncation metadata without changing lossless roundtrip" {
    const allocator = std.testing.allocator;
    const samples = try allocator.dupe(u16, &.{
        0,   10,  20,
        30,  40,  50,
        60,  70,  80,
        90,  100, 110,
        120, 130, 140,
        150, 160, 170,
        180, 190, 200,
        210, 220, 230,
        240, 120, 60,
    });
    defer allocator.free(samples);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = 3,
        .height = 3,
        .bit_depth = 8,
        .samples = samples,
    };

    var options = codestream.LosslessOptions{
        .levels = 1,
        .block_width = 32,
        .block_height = 32,
        .layers = 3,
        .rate_count = 2,
    };
    options.rates[0] = 8.0;
    options.rates[1] = 2.0;

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, options);
    defer allocator.free(bytes);

    const stats = try codestream.analyzeLosslessTemporary(bytes);
    try std.testing.expectEqual(@as(u16, 3), stats.layers);
    const y = stats.components[0];
    try std.testing.expect(y.quality_layers[0].blocks > 0);
    try std.testing.expect(y.quality_layers[0].cumulative_bytes <= y.quality_layers[1].cumulative_bytes);
    try std.testing.expect(y.quality_layers[1].cumulative_bytes <= y.quality_layers[2].cumulative_bytes);
    try std.testing.expectEqual(y.coding_passes, y.quality_layers[2].cumulative_passes);

    var decoded = try codestream.decodeLosslessTemporary(allocator, bytes);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u16, samples, decoded.samples);
}

test "RPCL packet plan computes precinct grids per resolution" {
    const precincts = [_]packet_plan.Precinct{
        .{ .width = 4, .height = 4 },
        .{ .width = 4, .height = 4 },
        .{ .width = 8, .height = 8 },
    };

    const plan = try packet_plan.rpclSingleTile(17, 9, 2, 3, 2, &precincts);
    try std.testing.expectEqual(@as(u8, 3), plan.resolution_count);

    try std.testing.expectEqual(@as(u32, 5), plan.resolutions[0].width);
    try std.testing.expectEqual(@as(u32, 3), plan.resolutions[0].height);
    try std.testing.expectEqual(@as(u32, 2), plan.resolutions[0].precincts_x);
    try std.testing.expectEqual(@as(u32, 1), plan.resolutions[0].precincts_y);
    try std.testing.expectEqual(@as(u64, 12), plan.resolutions[0].packets);

    try std.testing.expectEqual(@as(u32, 9), plan.resolutions[1].width);
    try std.testing.expectEqual(@as(u32, 5), plan.resolutions[1].height);
    try std.testing.expectEqual(@as(u32, 3), plan.resolutions[1].precincts_x);
    try std.testing.expectEqual(@as(u32, 2), plan.resolutions[1].precincts_y);
    try std.testing.expectEqual(@as(u64, 36), plan.resolutions[1].packets);

    try std.testing.expectEqual(@as(u32, 17), plan.resolutions[2].width);
    try std.testing.expectEqual(@as(u32, 9), plan.resolutions[2].height);
    try std.testing.expectEqual(@as(u32, 3), plan.resolutions[2].precincts_x);
    try std.testing.expectEqual(@as(u32, 2), plan.resolutions[2].precincts_y);
    try std.testing.expectEqual(@as(u64, 36), plan.resolutions[2].packets);
    try std.testing.expectEqual(@as(u64, 84), plan.packets);
}

test "rate allocator distributes block truncation points across quality layers" {
    var layers: [4]rate_alloc.Truncation = undefined;
    try rate_alloc.allocateEven(layers[0..], .{ .pass_count = 10, .byte_length = 100 });

    try std.testing.expectEqual(rate_alloc.Truncation{ .cumulative_passes = 3, .cumulative_bytes = 30 }, layers[0]);
    try std.testing.expectEqual(rate_alloc.Truncation{ .cumulative_passes = 5, .cumulative_bytes = 50 }, layers[1]);
    try std.testing.expectEqual(rate_alloc.Truncation{ .cumulative_passes = 8, .cumulative_bytes = 80 }, layers[2]);
    try std.testing.expectEqual(rate_alloc.Truncation{ .cumulative_passes = 10, .cumulative_bytes = 100 }, layers[3]);
}

test "rate allocator maps compression ratios to cumulative layer budgets" {
    var layers: [3]rate_alloc.Truncation = undefined;
    const rates = [_]f64{ 8.0, 2.0 };
    try rate_alloc.allocateFromCompressionRatios(layers[0..], .{ .pass_count = 12, .byte_length = 96 }, rates[0..]);

    try std.testing.expectEqual(rate_alloc.Truncation{ .cumulative_passes = 2, .cumulative_bytes = 16 }, layers[0]);
    try std.testing.expectEqual(rate_alloc.Truncation{ .cumulative_passes = 6, .cumulative_bytes = 48 }, layers[1]);
    try std.testing.expectEqual(rate_alloc.Truncation{ .cumulative_passes = 12, .cumulative_bytes = 96 }, layers[2]);
}

test "temporary payload records resolution ordered tile-part plan" {
    const allocator = std.testing.allocator;
    const width = 16;
    const height = 16;
    const samples = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(samples);
    for (0..width * height) |i| {
        samples[i * 3 + 0] = @as(u16, @intCast(i % 251));
        samples[i * 3 + 1] = @as(u16, @intCast((i * 3) % 251));
        samples[i * 3 + 2] = @as(u16, @intCast((i * 7) % 251));
    }

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = width,
        .height = height,
        .bit_depth = 8,
        .samples = samples,
    };

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 3,
        .block_width = 32,
        .block_height = 32,
        .tile_part_divisions = 'R',
    });
    defer allocator.free(bytes);

    const stats = try codestream.analyzeLosslessTemporary(bytes);
    try std.testing.expectEqual(@as(?u8, 'R'), stats.tile_part_divisions);
    try std.testing.expectEqual(@as(u8, 4), stats.tile_part_plan_count);
    try std.testing.expectEqual(@as(u8, 0), stats.tile_part_plan[0]);
    try std.testing.expectEqual(@as(u8, 1), stats.tile_part_plan[1]);
    try std.testing.expectEqual(@as(u8, 2), stats.tile_part_plan[2]);
    try std.testing.expectEqual(@as(u8, 3), stats.tile_part_plan[3]);
    try std.testing.expectEqual(@as(u8, 4), stats.packet_plan_count);
    try std.testing.expectEqual(@as(u64, 12), stats.packet_count);
    try std.testing.expectEqual(@as(usize, 4), countMarker(bytes, codestream.markerValue("sot")));
    try std.testing.expectEqual(@as(usize, 4), try countTilePartHeaderMarker(bytes, codestream.markerValue("plt")));
    try std.testing.expectEqual(try sumTilePartPayloadBytes(bytes), try sumTilePartPltLengths(bytes));
    try std.testing.expectEqual(@as(usize, 12), try countTilePartPrefixMarker(bytes, codestream.markerValue("sop")));
    try std.testing.expectEqual(@as(usize, 12), try countTilePartPrefixMarker(bytes, codestream.markerValue("eph")));
}

test "temporary payload rejects unterminated PLT lengths" {
    const allocator = std.testing.allocator;
    const width = 16;
    const height = 16;
    const samples = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(samples);
    @memset(samples, 0);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = width,
        .height = height,
        .bit_depth = 8,
        .samples = samples,
    };

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 2,
        .block_width = 32,
        .block_height = 32,
        .tile_part_divisions = 'R',
    });
    defer allocator.free(bytes);

    var corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);

    const plt = findMarker(corrupted, codestream.markerValue("plt")) orelse return error.MissingMarker;
    const segment_length = readU16BeTest(corrupted, plt + 2);
    corrupted[plt + 2 + segment_length - 1] = 0x80;

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload omits tile-part plan when tile parts are disabled" {
    const allocator = std.testing.allocator;
    const width = 8;
    const height = 8;
    const samples = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(samples);
    @memset(samples, 0);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = width,
        .height = height,
        .bit_depth = 8,
        .samples = samples,
    };

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 1,
        .block_width = 64,
        .block_height = 64,
        .tile_part_divisions = null,
    });
    defer allocator.free(bytes);

    const stats = try codestream.analyzeLosslessTemporary(bytes);
    try std.testing.expectEqual(@as(?u8, null), stats.tile_part_divisions);
    try std.testing.expectEqual(@as(u8, 0), stats.tile_part_plan_count);
}

test "lossless options are reflected in SIZ and COD marker skeleton" {
    const allocator = std.testing.allocator;
    const width = 64;
    const height = 64;
    const samples = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(samples);
    for (0..width * height) |i| {
        samples[i * 3 + 0] = @as(u16, @intCast(i % 256));
        samples[i * 3 + 1] = @as(u16, @intCast((i / width) % 256));
        samples[i * 3 + 2] = @as(u16, @intCast((i * 3) % 256));
    }

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = width,
        .height = height,
        .bit_depth = 8,
        .samples = samples,
    };

    var options = codestream.LosslessOptions{
        .levels = 5,
        .tile_width = 4096,
        .tile_height = 4096,
        .progression = .rpcl,
        .layers = 1,
        .block_width = 64,
        .block_height = 64,
        .bypass = true,
        .sop = true,
        .eph = true,
    };
    options.precincts[0] = .{ .width = 256, .height = 256 };
    options.precincts[1] = .{ .width = 256, .height = 256 };
    options.precincts[2] = .{ .width = 128, .height = 128 };
    options.precinct_count = 3;

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, options);
    defer allocator.free(bytes);

    const siz = findMarker(bytes, codestream.markerValue("siz")) orelse return error.MissingMarker;
    try std.testing.expectEqual(@as(u32, 4096), readU32BeTest(bytes, siz + 22));
    try std.testing.expectEqual(@as(u32, 4096), readU32BeTest(bytes, siz + 26));

    const tlm = findMarker(bytes, codestream.markerValue("tlm")) orelse return error.MissingMarker;
    const psot = try codestream.firstSotPsot(bytes);
    try std.testing.expectEqual(psot, try codestream.firstTlmPtlm(bytes));
    try std.testing.expectEqual(@as(u16, 34), readU16BeTest(bytes, tlm + 2));
    try std.testing.expectEqual(@as(u8, 0), bytes[tlm + 4]);
    try std.testing.expectEqual(@as(u8, 0x50), bytes[tlm + 5]);
    try std.testing.expectEqual(@as(u8, 0), bytes[tlm + 6]);
    try std.testing.expectEqual(psot, readU32BeTest(bytes, tlm + 7));
    const stats = try codestream.analyzeLosslessTemporary(bytes);
    try std.testing.expectEqual(@as(usize, 6), countMarker(bytes, codestream.markerValue("sot")));
    try std.testing.expectEqual(@as(usize, 6), try countTilePartHeaderMarker(bytes, codestream.markerValue("plt")));
    try std.testing.expectEqual(try sumTilePartPayloadBytes(bytes), try sumTilePartPltLengths(bytes));
    try std.testing.expectEqual(@as(usize, @intCast(stats.packet_count)), try countTilePartPrefixMarker(bytes, codestream.markerValue("sop")));
    try std.testing.expectEqual(@as(usize, @intCast(stats.packet_count)), try countTilePartPrefixMarker(bytes, codestream.markerValue("eph")));

    const cod = findMarker(bytes, codestream.markerValue("cod")) orelse return error.MissingMarker;
    try std.testing.expectEqual(@as(u16, 18), readU16BeTest(bytes, cod + 2));
    try std.testing.expectEqual(@as(u8, 0x07), bytes[cod + 4]);
    try std.testing.expectEqual(@intFromEnum(codestream.ProgressionOrder.rpcl), bytes[cod + 5]);
    try std.testing.expectEqual(@as(u16, 1), readU16BeTest(bytes, cod + 6));
    try std.testing.expectEqual(@as(u8, 1), bytes[cod + 8]);
    try std.testing.expectEqual(@as(u8, 5), bytes[cod + 9]);
    try std.testing.expectEqual(@as(u8, 4), bytes[cod + 10]);
    try std.testing.expectEqual(@as(u8, 4), bytes[cod + 11]);
    try std.testing.expectEqual(@as(u8, 1), bytes[cod + 12]);
    try std.testing.expectEqual(@as(u8, 1), bytes[cod + 13]);
    try std.testing.expectEqual(@as(u8, 0x88), bytes[cod + 14]);
    try std.testing.expectEqual(@as(u8, 0x88), bytes[cod + 15]);
    try std.testing.expectEqual(@as(u8, 0x77), bytes[cod + 16]);
    try std.testing.expectEqual(@as(u8, 0x77), bytes[cod + 17]);
    try std.testing.expectEqual(@as(u8, 0x77), bytes[cod + 18]);
    try std.testing.expectEqual(@as(u8, 0x77), bytes[cod + 19]);

    const qcd = findMarker(bytes, codestream.markerValue("qcd")) orelse return error.MissingMarker;
    try std.testing.expectEqual(@as(u16, 19), readU16BeTest(bytes, qcd + 2));
    try std.testing.expectEqual(@as(u8, 0x40), bytes[qcd + 4]);
    try std.testing.expectEqual(@as(u8, 0x40), bytes[qcd + 5]);
}

test "code-block style options are reflected in COD marker" {
    const allocator = std.testing.allocator;
    const width = 8;
    const height = 8;
    const samples = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(samples);
    for (0..width * height) |i| {
        samples[i * 3 + 0] = @as(u16, @intCast(i % 256));
        samples[i * 3 + 1] = @as(u16, @intCast((i * 3) % 256));
        samples[i * 3 + 2] = @as(u16, @intCast((i * 5) % 256));
    }

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = width,
        .height = height,
        .bit_depth = 8,
        .samples = samples,
    };

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 1,
        .block_width = 64,
        .block_height = 64,
        .bypass = true,
        .reset_context = true,
        .terminate_all = true,
        .vertical_causal = true,
        .predictable_termination = true,
        .segmentation_symbols = true,
    });
    defer allocator.free(bytes);

    const cod = findMarker(bytes, codestream.markerValue("cod")) orelse return error.MissingMarker;
    try std.testing.expectEqual(@as(u8, 0x3f), bytes[cod + 12]);
}

test "unsupported JP2 profile marker options fail closed" {
    const allocator = std.testing.allocator;
    const samples = try allocator.dupe(u16, &.{
        0,  0,  0,
        10, 20, 30,
        40, 50, 60,
        70, 80, 90,
    });
    defer allocator.free(samples);

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = 2,
        .height = 2,
        .bit_depth = 8,
        .samples = samples,
    };

    const UnsupportedCase = struct {
        label: []const u8,
        options: codestream.LosslessOptions,
    };
    const cases = [_]UnsupportedCase{
        .{ .label = "LRCP progression", .options = .{ .progression = .lrcp } },
        .{ .label = "RLCP progression", .options = .{ .progression = .rlcp } },
        .{ .label = "PCRL progression", .options = .{ .progression = .pcrl } },
        .{ .label = "CPRL progression", .options = .{ .progression = .cprl } },
        .{ .label = "L tile-parts", .options = .{ .tile_part_divisions = 'L' } },
        .{ .label = "C tile-parts", .options = .{ .tile_part_divisions = 'C' } },
        .{ .label = "P tile-parts", .options = .{ .tile_part_divisions = 'P' } },
        .{ .label = "ICT", .options = .{ .mct = .ict } },
        .{ .label = "9-7 JP2", .options = .{ .transform = .irreversible_9_7 } },
        .{ .label = "scalar-derived quantization", .options = .{ .quantization = .scalar_derived } },
        .{ .label = "scalar-expounded quantization", .options = .{ .quantization = .scalar_expounded } },
        .{ .label = "multi-tile request", .options = .{ .tile_width = 1, .tile_height = 2 } },
    };

    for (cases) |scenario| {
        errdefer std.debug.print("unsupported profile case failed: {s}\n", .{scenario.label});
        try std.testing.expectError(
            codestream.CodestreamError.UnsupportedPayload,
            codestream.encodeLosslessWithOptions(allocator, rgb, scenario.options),
        );
    }
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

fn findMarker(bytes: []const u8, marker: u16) ?usize {
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        const value = (@as(u16, bytes[i]) << 8) | bytes[i + 1];
        if (value == marker) return i;
    }
    return null;
}

fn countMarker(bytes: []const u8, marker: u16) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 1) {
        const value = (@as(u16, bytes[i]) << 8) | bytes[i + 1];
        if (value == marker) count += 1;
    }
    return count;
}

fn countTilePartPrefixMarker(bytes: []const u8, marker: u16) !usize {
    const sot = codestream.markerValue("sot");
    const sod = codestream.markerValue("sod");
    const eoc = codestream.markerValue("eoc");
    const sop = codestream.markerValue("sop");
    const eph = codestream.markerValue("eph");

    var count: usize = 0;
    var cursor: usize = 2;
    while (cursor + 1 < bytes.len and readU16BeTest(bytes, cursor) != sot) {
        cursor += 2;
        if (readU16BeTest(bytes, cursor - 2) == eoc) return error.MissingSot;
        if (bytes.len - cursor < 2) return error.Truncated;
        const segment_length = readU16BeTest(bytes, cursor);
        cursor += segment_length;
    }

    while (cursor + 1 < bytes.len) {
        const marker_value = readU16BeTest(bytes, cursor);
        if (marker_value == eoc) return count;
        if (marker_value != sot) return error.MissingSot;
        if (bytes.len - cursor < 14) return error.Truncated;

        const tile_part_start = cursor;
        const segment_length = readU16BeTest(bytes, cursor + 2);
        if (segment_length != 10) return error.InvalidSot;
        const psot = readU32BeTest(bytes, cursor + 6);
        const tile_part_end = tile_part_start + psot;
        if (psot == 0 or tile_part_end > bytes.len) return error.InvalidSot;

        cursor += 12;
        while (cursor + 1 < tile_part_end and readU16BeTest(bytes, cursor) != sod) {
            cursor += 2;
            if (tile_part_end - cursor < 2) return error.Truncated;
            const header_segment_length = readU16BeTest(bytes, cursor);
            if (header_segment_length < 2 or tile_part_end - cursor < header_segment_length) return error.Truncated;
            cursor += header_segment_length;
        }
        if (cursor + 1 >= tile_part_end or readU16BeTest(bytes, cursor) != sod) return error.MissingSod;
        cursor += 2;

        while (cursor + 1 < tile_part_end) : (cursor += 1) {
            const prefix_marker = readU16BeTest(bytes, cursor);
            if (prefix_marker == sop) {
                if (tile_part_end - cursor < 6) return error.Truncated;
                if (marker == sop) count += 1;
                cursor += 6;
                try skipTemporaryPacketHeader(bytes, &cursor, tile_part_end);
                if (cursor + 1 < tile_part_end and readU16BeTest(bytes, cursor) == eph) {
                    if (marker == eph) count += 1;
                    cursor += 1;
                }
            } else if (prefix_marker == eph) {
                if (marker == eph) count += 1;
                cursor += 1;
            }
        }

        cursor = tile_part_end;
    }

    return error.MissingEoc;
}

fn skipTemporaryPacketHeader(bytes: []const u8, cursor: *usize, end: usize) !void {
    if (cursor.* >= end) return error.Truncated;
    cursor.* += 1;
    var byte_count: usize = 0;
    while (cursor.* < end) {
        if (byte_count == 10) return error.InvalidPacketHeader;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        byte_count += 1;
        if ((byte & 0x80) == 0) return;
    }
    return error.Truncated;
}

fn countTilePartHeaderMarker(bytes: []const u8, marker: u16) !usize {
    return try walkTilePartHeaders(bytes, marker, null, null);
}

fn sumTilePartPltLengths(bytes: []const u8) !usize {
    var sum: usize = 0;
    _ = try walkTilePartHeaders(bytes, codestream.markerValue("plt"), &sum, null);
    return sum;
}

fn sumTilePartPayloadBytes(bytes: []const u8) !usize {
    var sum: usize = 0;
    _ = try walkTilePartHeaders(bytes, codestream.markerValue("plt"), null, &sum);
    return sum;
}

fn walkTilePartHeaders(bytes: []const u8, marker: u16, plt_sum: ?*usize, payload_sum: ?*usize) !usize {
    const sot = codestream.markerValue("sot");
    const sod = codestream.markerValue("sod");
    const eoc = codestream.markerValue("eoc");

    var count: usize = 0;
    var cursor: usize = 2;
    while (cursor + 1 < bytes.len and readU16BeTest(bytes, cursor) != sot) {
        cursor += 2;
        if (readU16BeTest(bytes, cursor - 2) == eoc) return error.MissingSot;
        if (bytes.len - cursor < 2) return error.Truncated;
        const segment_length = readU16BeTest(bytes, cursor);
        cursor += segment_length;
    }

    while (cursor + 1 < bytes.len) {
        const marker_value = readU16BeTest(bytes, cursor);
        if (marker_value == eoc) return count;
        if (marker_value != sot) return error.MissingSot;
        if (bytes.len - cursor < 14) return error.Truncated;

        const tile_part_start = cursor;
        const segment_length = readU16BeTest(bytes, cursor + 2);
        if (segment_length != 10) return error.InvalidSot;
        const psot = readU32BeTest(bytes, cursor + 6);
        const tile_part_end = tile_part_start + psot;
        if (psot == 0 or tile_part_end > bytes.len) return error.InvalidSot;

        cursor += 12;
        while (cursor + 1 < tile_part_end) {
            const tile_header_marker = readU16BeTest(bytes, cursor);
            if (tile_header_marker == sod) break;
            if (tile_part_end - cursor < 4) return error.Truncated;
            const header_segment_start = cursor;
            const header_segment_length = readU16BeTest(bytes, cursor + 2);
            if (header_segment_length < 2 or tile_part_end - cursor - 2 < header_segment_length) return error.Truncated;
            if (tile_header_marker == marker) count += 1;
            if (tile_header_marker == codestream.markerValue("plt")) {
                if (plt_sum) |sum| {
                    sum.* += try sumPltSegment(bytes[header_segment_start + 4 .. header_segment_start + 2 + header_segment_length]);
                }
            }
            cursor += 2 + header_segment_length;
        }

        if (cursor + 1 >= tile_part_end or readU16BeTest(bytes, cursor) != sod) return error.MissingSod;
        if (payload_sum) |sum| sum.* += tile_part_end - (cursor + 2);
        cursor = tile_part_end;
    }

    return error.MissingEoc;
}

fn sumPltSegment(segment: []const u8) !usize {
    if (segment.len == 0) return error.InvalidPlt;
    var sum: usize = 0;
    var length: usize = 0;
    var pending_length = false;
    for (segment[1..]) |byte| {
        length = (length << 7) | (byte & 0x7f);
        pending_length = true;
        if ((byte & 0x80) == 0) {
            sum += length;
            length = 0;
            pending_length = false;
        }
    }
    if (pending_length) return error.InvalidPlt;
    return sum;
}

fn mqContextsFromSymbols(allocator: std.mem.Allocator, symbols: []const mq.Symbol) ![]usize {
    const contexts = try allocator.alloc(usize, symbols.len);
    for (symbols, 0..) |symbol, index| {
        contexts[index] = symbol.context;
    }
    return contexts;
}

fn expectMqBitsEqual(symbols: []const mq.Symbol, bits: []const bool) !void {
    try std.testing.expectEqual(symbols.len, bits.len);
    for (symbols, bits) |symbol, bit| {
        try std.testing.expectEqual(symbol.bit, bit);
    }
}

fn expectMarkerStuffingIsValid(bytes: []const u8) !void {
    var index: usize = 1;
    while (index < bytes.len) : (index += 1) {
        if (bytes[index - 1] == 0xff) {
            try std.testing.expect((bytes[index] & 0x80) == 0);
        }
    }
}

fn readU16BeTest(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readU32BeTest(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}
