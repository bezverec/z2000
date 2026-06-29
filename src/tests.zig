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

test "T2 code-block grid maps subband block rects to tag-tree leaves" {
    const allocator = std.testing.allocator;
    const bands = try subband.makeBands(allocator, 17, 9, 1);
    defer allocator.free(bands);
    const blocks = try subband.makeCodeBlocks(allocator, bands, 4, 4);
    defer allocator.free(blocks);

    const ll_band = bands[0];
    try std.testing.expectEqual(subband.Kind.ll, ll_band.kind);
    const grid = try t2.CodeBlockGrid.init(
        ll_band.rect.x,
        ll_band.rect.y,
        ll_band.rect.width,
        ll_band.rect.height,
        4,
        4,
    );
    try std.testing.expectEqual(@as(usize, 3), grid.leaves_x);
    try std.testing.expectEqual(@as(usize, 2), grid.leaves_y);

    try std.testing.expectEqual(
        t2.PacketBlockLocation{ .leaf_x = 0, .leaf_y = 0 },
        try grid.locationForRect(.{ .x = blocks[0].rect.x, .y = blocks[0].rect.y, .width = blocks[0].rect.width, .height = blocks[0].rect.height }),
    );
    try std.testing.expectEqual(
        t2.PacketBlockLocation{ .leaf_x = 2, .leaf_y = 0 },
        try grid.locationForRect(.{ .x = blocks[2].rect.x, .y = blocks[2].rect.y, .width = blocks[2].rect.width, .height = blocks[2].rect.height }),
    );
    try std.testing.expectEqual(
        t2.PacketBlockLocation{ .leaf_x = 2, .leaf_y = 1 },
        try grid.locationForRect(.{ .x = blocks[5].rect.x, .y = blocks[5].rect.y, .width = blocks[5].rect.width, .height = blocks[5].rect.height }),
    );

    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        grid.locationForRect(.{ .x = 1, .y = 0, .width = 4, .height = 4 }),
    );
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        grid.locationForRect(.{ .x = 8, .y = 4, .width = 3, .height = 2 }),
    );
}

test "T2 RPCL code-block selector maps resolution precincts to block indexes" {
    const allocator = std.testing.allocator;
    const levels: u8 = 2;
    const bands = try subband.makeBands(allocator, 17, 9, levels);
    defer allocator.free(bands);
    const blocks = try subband.makeCodeBlocks(allocator, bands, 4, 4);
    defer allocator.free(blocks);
    const precincts = [_]packet_plan.Precinct{
        .{ .width = 4, .height = 4 },
        .{ .width = 4, .height = 4 },
        .{ .width = 8, .height = 8 },
    };
    const plan = try packet_plan.rpclSingleTile(17, 9, levels, 3, 2, &precincts);

    const ll_packet = packet_plan.Packet{
        .sequence = 0,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 0,
    };
    const ll_indexes = try t2.collectRpclCodeBlockIndexes(allocator, plan, ll_packet, levels, bands, blocks);
    defer allocator.free(ll_indexes);
    try std.testing.expectEqualSlices(usize, &[_]usize{0}, ll_indexes);

    const low_high_packet = packet_plan.Packet{
        .sequence = 12,
        .resolution = 1,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 0,
    };
    const low_high_indexes = try t2.collectRpclCodeBlockIndexes(allocator, plan, low_high_packet, levels, bands, blocks);
    defer allocator.free(low_high_indexes);
    try std.testing.expectEqualSlices(usize, &[_]usize{3}, low_high_indexes);

    const edge_packet = packet_plan.Packet{
        .sequence = 78,
        .resolution = 2,
        .precinct_x = 2,
        .precinct_y = 1,
        .precinct_index = 5,
        .component = 0,
        .layer = 0,
    };
    const edge_indexes = try t2.collectRpclCodeBlockIndexes(allocator, plan, edge_packet, levels, bands, blocks);
    defer allocator.free(edge_indexes);
    try std.testing.expectEqualSlices(usize, &[_]usize{14}, edge_indexes);

    try std.testing.expectEqual(@as(u8, 0), try t2.bandResolutionIndex(levels, bands[0]));
    try std.testing.expectEqual(@as(u8, 1), try t2.bandResolutionIndex(levels, bands[1]));
    try std.testing.expectEqual(@as(u8, 2), try t2.bandResolutionIndex(levels, bands[4]));
}

test "T2 encoded layer block derives packet block previous and current truncations" {
    const payload = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    const layers = [_]t2.LayerTruncation{
        .{ .cumulative_passes = 1, .cumulative_bytes = 4 },
        .{ .cumulative_passes = 3, .cumulative_bytes = 9 },
    };
    const encoded = t2.EncodedLayerBlock{
        .location = .{ .leaf_x = 2, .leaf_y = 1 },
        .nominal_bitplanes = 8,
        .encoded_bitplanes = 5,
        .layers = layers[0..],
        .payload = payload[0..],
    };

    const first = try t2.layerPacketBlockFor(encoded, 0);
    try std.testing.expectEqual(t2.LayerTruncation{ .cumulative_passes = 0, .cumulative_bytes = 0 }, first.previous);
    try std.testing.expectEqual(layers[0], first.current);
    try std.testing.expectEqualSlices(u8, payload[0..4], try t2.layerPayloadSlice(first.payload, first.previous, first.current));

    const second = try t2.layerPacketBlockFor(encoded, 1);
    try std.testing.expectEqual(layers[0], second.previous);
    try std.testing.expectEqual(layers[1], second.current);
    try std.testing.expectEqualSlices(u8, payload[4..9], try t2.layerPayloadSlice(second.payload, second.previous, second.current));
    try std.testing.expectError(t2.PacketHeaderError.InvalidPacketHeader, t2.layerPacketBlockFor(encoded, 2));
}

test "T2 selected encoded blocks assemble into an RPCL layer packet" {
    const allocator = std.testing.allocator;
    const payload_a = [_]u8{ 10, 11, 12, 13, 14, 15 };
    const payload_b = [_]u8{ 20, 21, 22, 23, 24, 25 };
    const layers = [_]t2.LayerTruncation{
        .{ .cumulative_passes = 1, .cumulative_bytes = 3 },
        .{ .cumulative_passes = 2, .cumulative_bytes = 6 },
    };
    const encoded = [_]t2.EncodedLayerBlock{
        .{
            .location = .{ .leaf_x = 0, .leaf_y = 0 },
            .nominal_bitplanes = 8,
            .encoded_bitplanes = 5,
            .layers = layers[0..],
            .payload = payload_a[0..],
        },
        .{
            .location = .{ .leaf_x = 1, .leaf_y = 0 },
            .nominal_bitplanes = 8,
            .encoded_bitplanes = 4,
            .layers = layers[0..],
            .payload = payload_b[0..],
        },
    };
    const indexes = [_]usize{ 0, 1 };
    const first_blocks = try t2.layerPacketBlocksForIndexes(allocator, encoded[0..], indexes[0..], 0);
    defer allocator.free(first_blocks);
    try std.testing.expectEqual(@as(usize, 2), first_blocks.len);
    try std.testing.expectEqual(t2.LayerTruncation{ .cumulative_passes = 0, .cumulative_bytes = 0 }, first_blocks[0].previous);
    try std.testing.expectEqualSlices(u8, payload_b[0..3], try t2.layerPayloadSlice(first_blocks[1].payload, first_blocks[1].previous, first_blocks[1].current));

    var writer_state = try t2.PrecinctPacketWriterState.initForEncodedBlocks(allocator, encoded[0..]);
    defer writer_state.deinit();

    var packet_bytes: std.ArrayList(u8) = .empty;
    defer packet_bytes.deinit(allocator);
    const packet = packet_plan.Packet{
        .sequence = 0,
        .resolution = 1,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 0,
    };
    const written = try writer_state.appendRpclPacket(
        allocator,
        &packet_bytes,
        packet,
        1,
        0,
        0,
        first_blocks,
    );
    try std.testing.expectEqual(@as(usize, 2), written.included_blocks);
    try std.testing.expectEqual(@as(u16, 1), writer_state.states[0].cumulative_passes);
    try std.testing.expectEqual(@as(u64, 3), writer_state.states[1].cumulative_bytes);

    var reader_state = try t2.PrecinctPacketReaderState.init(allocator, 2, 1, 2);
    defer reader_state.deinit();
    var decoded: [2]t2.DecodedPacketBlock = undefined;
    var payloads: [2]?[]const u8 = undefined;
    const locations = [_]t2.PacketBlockLocation{ first_blocks[0].location, first_blocks[1].location };
    const read = try reader_state.readRpclPacket(
        allocator,
        packet_bytes.items,
        packet,
        1,
        0,
        0,
        locations[0..],
        8,
        decoded[0..],
        payloads[0..],
    );
    try std.testing.expectEqual(written.packet_length(), read.packet_length);
    try std.testing.expectEqualSlices(u8, payload_a[0..3], payloads[0].?);
    try std.testing.expectEqualSlices(u8, payload_b[0..3], payloads[1].?);
    try std.testing.expectEqualSlices(t2.CodeBlockPacketState, writer_state.states, reader_state.states);

    const second_offset = packet_bytes.items.len;
    const second_packet = packet_plan.Packet{
        .sequence = 1,
        .resolution = 1,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 1,
    };
    const second_written = try t2.appendRpclPacketForIndexes(
        &writer_state,
        allocator,
        &packet_bytes,
        second_packet,
        1,
        0,
        0,
        encoded[0..],
        indexes[0..],
    );
    const second_read = try reader_state.readRpclPacket(
        allocator,
        packet_bytes.items[second_offset..],
        second_packet,
        1,
        0,
        0,
        locations[0..],
        8,
        decoded[0..],
        payloads[0..],
    );
    try std.testing.expectEqual(second_written.packet_length(), second_read.packet_length);
    try std.testing.expectEqualSlices(u8, payload_a[3..6], payloads[0].?);
    try std.testing.expectEqualSlices(u8, payload_b[3..6], payloads[1].?);
    try std.testing.expectEqual(@as(u16, 2), writer_state.states[0].cumulative_passes);
    try std.testing.expectEqual(@as(u64, 6), writer_state.states[1].cumulative_bytes);
    try std.testing.expectEqualSlices(t2.CodeBlockPacketState, writer_state.states, reader_state.states);

    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        t2.layerPacketBlocksForIndexes(allocator, encoded[0..], &[_]usize{2}, 0),
    );
}

test "T2 encoded block state derives delayed first inclusion layers" {
    const allocator = std.testing.allocator;
    const payload_a = [_]u8{ 1, 2, 3 };
    const payload_b = [_]u8{ 4, 5, 6 };
    const layers_a = [_]t2.LayerTruncation{
        .{ .cumulative_passes = 0, .cumulative_bytes = 0 },
        .{ .cumulative_passes = 1, .cumulative_bytes = 3 },
    };
    const layers_b = [_]t2.LayerTruncation{
        .{ .cumulative_passes = 1, .cumulative_bytes = 3 },
        .{ .cumulative_passes = 1, .cumulative_bytes = 3 },
    };
    const encoded = [_]t2.EncodedLayerBlock{
        .{
            .location = .{ .leaf_x = 0, .leaf_y = 0 },
            .nominal_bitplanes = 8,
            .encoded_bitplanes = 6,
            .layers = layers_a[0..],
            .payload = payload_a[0..],
        },
        .{
            .location = .{ .leaf_x = 1, .leaf_y = 0 },
            .nominal_bitplanes = 8,
            .encoded_bitplanes = 5,
            .layers = layers_b[0..],
            .payload = payload_b[0..],
        },
    };
    const indexes = [_]usize{ 0, 1 };
    var writer_state = try t2.PrecinctPacketWriterState.initForEncodedBlocks(allocator, encoded[0..]);
    defer writer_state.deinit();
    var reader_state = try t2.PrecinctPacketReaderState.init(allocator, 2, 1, 2);
    defer reader_state.deinit();

    var packet_bytes: std.ArrayList(u8) = .empty;
    defer packet_bytes.deinit(allocator);
    const first_packet = packet_plan.Packet{
        .sequence = 0,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 0,
    };
    const first_written = try t2.appendRpclPacketForIndexes(
        &writer_state,
        allocator,
        &packet_bytes,
        first_packet,
        0,
        0,
        0,
        encoded[0..],
        indexes[0..],
    );
    try std.testing.expectEqual(@as(usize, 1), first_written.included_blocks);

    var decoded: [2]t2.DecodedPacketBlock = undefined;
    var payloads: [2]?[]const u8 = undefined;
    const locations = [_]t2.PacketBlockLocation{ encoded[0].location, encoded[1].location };
    const first_read = try reader_state.readRpclPacket(
        allocator,
        packet_bytes.items,
        first_packet,
        0,
        0,
        0,
        locations[0..],
        8,
        decoded[0..],
        payloads[0..],
    );
    try std.testing.expectEqual(first_written.packet_length(), first_read.packet_length);
    try std.testing.expect(!decoded[0].included);
    try std.testing.expect(decoded[1].first_inclusion);
    try std.testing.expectEqual(@as(?[]const u8, null), payloads[0]);
    try std.testing.expectEqualSlices(u8, payload_b[0..], payloads[1].?);

    const second_offset = packet_bytes.items.len;
    const second_packet = packet_plan.Packet{
        .sequence = 1,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 1,
    };
    const second_written = try t2.appendRpclPacketForIndexes(
        &writer_state,
        allocator,
        &packet_bytes,
        second_packet,
        0,
        0,
        0,
        encoded[0..],
        indexes[0..],
    );
    const second_read = try reader_state.readRpclPacket(
        allocator,
        packet_bytes.items[second_offset..],
        second_packet,
        0,
        0,
        0,
        locations[0..],
        8,
        decoded[0..],
        payloads[0..],
    );
    try std.testing.expectEqual(second_written.packet_length(), second_read.packet_length);
    try std.testing.expect(decoded[0].first_inclusion);
    try std.testing.expect(!decoded[1].included);
    try std.testing.expectEqualSlices(u8, payload_a[0..], payloads[0].?);
    try std.testing.expectEqual(@as(?[]const u8, null), payloads[1]);
    try std.testing.expectEqualSlices(t2.CodeBlockPacketState, writer_state.states, reader_state.states);

    const sparse = [_]t2.EncodedLayerBlock{.{
        .location = .{ .leaf_x = 1, .leaf_y = 0 },
        .nominal_bitplanes = 8,
        .encoded_bitplanes = 5,
        .layers = layers_b[0..],
        .payload = payload_b[0..],
    }};
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        t2.PrecinctPacketWriterState.initForEncodedBlocks(allocator, sparse[0..]),
    );
}

test "T2 layer contribution maps cumulative truncation points to packet deltas" {
    const previous = t2.LayerTruncation{ .cumulative_passes = 2, .cumulative_bytes = 10 };
    const current = t2.LayerTruncation{ .cumulative_passes = 5, .cumulative_bytes = 31 };

    const contribution = try t2.layerContribution(previous, current);
    try std.testing.expect(contribution.included);
    try std.testing.expectEqual(@as(u16, 3), contribution.pass_count);
    try std.testing.expectEqual(@as(u64, 10), contribution.byte_offset);
    try std.testing.expectEqual(@as(u64, 21), contribution.byte_length);

    const empty = try t2.layerContribution(current, current);
    try std.testing.expect(!empty.included);
    try std.testing.expectEqual(@as(u16, 0), empty.pass_count);
    try std.testing.expectEqual(@as(u64, 31), empty.byte_offset);
    try std.testing.expectEqual(@as(u64, 0), empty.byte_length);

    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        t2.layerContribution(current, previous),
    );
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        t2.layerContribution(previous, .{ .cumulative_passes = 2, .cumulative_bytes = 11 }),
    );
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        t2.layerContribution(previous, .{ .cumulative_passes = 3, .cumulative_bytes = 10 }),
    );
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        t2.layerContribution(.{ .cumulative_passes = 0, .cumulative_bytes = 0 }, .{ .cumulative_passes = 165, .cumulative_bytes = 1 }),
    );
}

test "T2 packet block derives EBCOT layer truncation metadata" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{
        0, -7,  0,  5,
        1, 0,   -2, 0,
        0, 0,   0,  0,
        9, -12, 0,  4,
    };

    var segment = try ebcot.encodeCodeBlockSegment(allocator, plane[0..], 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    defer segment.deinit(allocator);
    try std.testing.expect(segment.pass_count >= 3);

    const first_point = try segment.truncationPointForPasses(1);
    const third_point = try segment.truncationPointForPasses(3);
    const zero = t2.LayerTruncation{ .cumulative_passes = 0, .cumulative_bytes = 0 };
    const first = t2.LayerTruncation{ .cumulative_passes = first_point.cumulative_passes, .cumulative_bytes = first_point.cumulative_bytes };
    const third = t2.LayerTruncation{ .cumulative_passes = third_point.cumulative_passes, .cumulative_bytes = third_point.cumulative_bytes };

    const first_block = try t2.packetBlockForLayer(.{ .leaf_x = 0, .leaf_y = 0 }, 8, segment.bitplanes, zero, first);
    try std.testing.expect(first_block.included);
    try std.testing.expectEqual(@as(u8, 8) - segment.bitplanes, first_block.zero_bitplanes);
    try std.testing.expectEqual(@as(u16, 1), first_block.pass_count);
    try std.testing.expectEqual(first_point.cumulative_bytes, first_block.byte_length);

    const second_contribution = try t2.layerContribution(first, third);
    try std.testing.expect(second_contribution.included);
    try std.testing.expectEqual(@as(u16, 2), second_contribution.pass_count);
    try std.testing.expectEqual(first_point.cumulative_bytes, second_contribution.byte_offset);
    try std.testing.expectEqual(third_point.cumulative_bytes - first_point.cumulative_bytes, second_contribution.byte_length);
    try std.testing.expectEqualSlices(
        u8,
        segment.bytes[@intCast(first_point.cumulative_bytes)..@intCast(third_point.cumulative_bytes)],
        try t2.layerPayloadSlice(segment.bytes, first, third),
    );
}

test "T2 single block packet header carries EBCOT layer payload deltas" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{
        0, -7,  0,  5,
        1, 0,   -2, 0,
        0, 0,   0,  0,
        9, -12, 0,  4,
    };

    var segment = try ebcot.encodeCodeBlockSegment(allocator, plane[0..], 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    defer segment.deinit(allocator);
    try std.testing.expect(segment.pass_count >= 2);

    const first_point = try segment.truncationPointForPasses(1);
    const second_point = try segment.truncationPointForPasses(2);
    const zero = t2.LayerTruncation{ .cumulative_passes = 0, .cumulative_bytes = 0 };
    const first = t2.LayerTruncation{ .cumulative_passes = first_point.cumulative_passes, .cumulative_bytes = first_point.cumulative_bytes };
    const second = t2.LayerTruncation{ .cumulative_passes = second_point.cumulative_passes, .cumulative_bytes = second_point.cumulative_bytes };
    const zero_bitplanes = @as(u8, 8) - segment.bitplanes;

    var packet = std.ArrayList(u8).empty;
    defer packet.deinit(allocator);
    var inclusion_encoder = try t2.TagTreeEncoder.init(allocator, 1, 1, &[_]u32{0});
    defer inclusion_encoder.deinit();
    var zero_encoder = try t2.TagTreeEncoder.init(allocator, 1, 1, &[_]u32{zero_bitplanes});
    defer zero_encoder.deinit();
    var write_states = [_]t2.CodeBlockPacketState{.{}} ** 1;

    const first_payload = try t2.layerPayloadSlice(segment.bytes, zero, first);
    var writer = t2.PacketHeaderWriter.init(allocator, &packet);
    const first_block = try t2.packetBlockForLayer(.{ .leaf_x = 0, .leaf_y = 0 }, 8, segment.bitplanes, zero, first);
    try t2.writePrecinctPacketHeader(&writer, &inclusion_encoder, &zero_encoder, write_states[0..], 0, &[_]t2.PacketBlock{first_block});
    try writer.finish();
    const first_header_len = packet.items.len;
    try packet.appendSlice(allocator, first_payload);

    var inclusion_decoder = try t2.TagTreeDecoder.init(allocator, 1, 1);
    defer inclusion_decoder.deinit();
    var zero_decoder = try t2.TagTreeDecoder.init(allocator, 1, 1);
    defer zero_decoder.deinit();
    var read_states = [_]t2.CodeBlockPacketState{.{}} ** 1;
    var decoded: [1]t2.DecodedPacketBlock = undefined;

    var reader = t2.PacketHeaderReader.init(packet.items[0..first_header_len]);
    try std.testing.expect(try t2.readPrecinctPacketHeader(
        &reader,
        &inclusion_decoder,
        &zero_decoder,
        read_states[0..],
        0,
        &[_]t2.PacketBlockLocation{.{ .leaf_x = 0, .leaf_y = 0 }},
        8,
        decoded[0..],
    ));
    try reader.byteAlign();
    try std.testing.expectEqual(first_header_len, reader.bytesConsumed());
    try std.testing.expect(decoded[0].included);
    try std.testing.expect(decoded[0].first_inclusion);
    try std.testing.expectEqual(zero_bitplanes, decoded[0].zero_bitplanes);
    try std.testing.expectEqual(@as(u16, 1), decoded[0].pass_count);
    try std.testing.expectEqual(first_payload.len, @as(usize, @intCast(decoded[0].byte_length)));
    try std.testing.expectEqualSlices(u8, first_payload, packet.items[first_header_len..]);

    packet.clearRetainingCapacity();
    const second_payload = try t2.layerPayloadSlice(segment.bytes, first, second);
    writer = t2.PacketHeaderWriter.init(allocator, &packet);
    const second_block = try t2.packetBlockForLayer(.{ .leaf_x = 0, .leaf_y = 0 }, 8, segment.bitplanes, first, second);
    try t2.writePrecinctPacketHeader(&writer, &inclusion_encoder, &zero_encoder, write_states[0..], 1, &[_]t2.PacketBlock{second_block});
    try writer.finish();
    const second_header_len = packet.items.len;
    try packet.appendSlice(allocator, second_payload);

    reader = t2.PacketHeaderReader.init(packet.items[0..second_header_len]);
    try std.testing.expect(try t2.readPrecinctPacketHeader(
        &reader,
        &inclusion_decoder,
        &zero_decoder,
        read_states[0..],
        1,
        &[_]t2.PacketBlockLocation{.{ .leaf_x = 0, .leaf_y = 0 }},
        8,
        decoded[0..],
    ));
    try reader.byteAlign();
    try std.testing.expectEqual(second_header_len, reader.bytesConsumed());
    try std.testing.expect(decoded[0].included);
    try std.testing.expect(!decoded[0].first_inclusion);
    try std.testing.expectEqual(@as(u16, 1), decoded[0].pass_count);
    try std.testing.expectEqual(second_payload.len, @as(usize, @intCast(decoded[0].byte_length)));
    try std.testing.expectEqualSlices(u8, second_payload, packet.items[second_header_len..]);
    try std.testing.expectEqualSlices(t2.CodeBlockPacketState, write_states[0..], read_states[0..]);
}

test "T2 precinct layer packet assembles multiple EBCOT payload slices" {
    const allocator = std.testing.allocator;
    const plane_a = [_]i32{
        0, -7,  0,  5,
        1, 0,   -2, 0,
        0, 0,   0,  0,
        9, -12, 0,  4,
    };
    const plane_b = [_]i32{
        3, 0, -1, 0,
        0, 6, 0,  0,
        2, 0, -8, 0,
        0, 0, 0,  11,
    };

    var segment_a = try ebcot.encodeCodeBlockSegment(allocator, plane_a[0..], 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    defer segment_a.deinit(allocator);
    var segment_b = try ebcot.encodeCodeBlockSegment(allocator, plane_b[0..], 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    defer segment_b.deinit(allocator);
    try std.testing.expect(segment_a.pass_count >= 3);
    try std.testing.expect(segment_b.pass_count >= 1);

    const zero = t2.LayerTruncation{ .cumulative_passes = 0, .cumulative_bytes = 0 };
    const a1_point = try segment_a.truncationPointForPasses(1);
    const a3_point = try segment_a.truncationPointForPasses(3);
    const b1_point = try segment_b.truncationPointForPasses(1);
    const a1 = t2.LayerTruncation{ .cumulative_passes = a1_point.cumulative_passes, .cumulative_bytes = a1_point.cumulative_bytes };
    const a3 = t2.LayerTruncation{ .cumulative_passes = a3_point.cumulative_passes, .cumulative_bytes = a3_point.cumulative_bytes };
    const b1 = t2.LayerTruncation{ .cumulative_passes = b1_point.cumulative_passes, .cumulative_bytes = b1_point.cumulative_bytes };

    const zero_values = [_]u32{
        @as(u32, 8 - segment_a.bitplanes),
        @as(u32, 8 - segment_b.bitplanes),
    };
    var packet = std.ArrayList(u8).empty;
    defer packet.deinit(allocator);
    var inclusion_encoder = try t2.TagTreeEncoder.init(allocator, 2, 1, &[_]u32{ 0, 1 });
    defer inclusion_encoder.deinit();
    var zero_encoder = try t2.TagTreeEncoder.init(allocator, 2, 1, zero_values[0..]);
    defer zero_encoder.deinit();
    var write_states = [_]t2.CodeBlockPacketState{.{}} ** 2;

    const first_blocks = [_]t2.LayerPacketBlock{
        .{
            .location = .{ .leaf_x = 0, .leaf_y = 0 },
            .nominal_bitplanes = 8,
            .encoded_bitplanes = segment_a.bitplanes,
            .previous = zero,
            .current = a1,
            .payload = segment_a.bytes,
        },
        .{
            .location = .{ .leaf_x = 1, .leaf_y = 0 },
            .nominal_bitplanes = 8,
            .encoded_bitplanes = segment_b.bitplanes,
            .previous = zero,
            .current = zero,
            .payload = segment_b.bytes,
        },
    };
    const first_packet = try t2.appendPrecinctLayerPacket(
        allocator,
        &packet,
        &inclusion_encoder,
        &zero_encoder,
        write_states[0..],
        0,
        first_blocks[0..],
    );
    try std.testing.expectEqual(@as(usize, 0), first_packet.header_offset);
    try std.testing.expect(first_packet.header_length > 0);
    try std.testing.expectEqual(@as(usize, 1), first_packet.included_blocks);
    try std.testing.expectEqual(@as(usize, @intCast(a1.cumulative_bytes)), first_packet.payload_length);
    try std.testing.expectEqualSlices(
        u8,
        try t2.layerPayloadSlice(segment_a.bytes, zero, a1),
        packet.items[first_packet.payload_offset..][0..first_packet.payload_length],
    );

    const second_header_offset = packet.items.len;
    const second_blocks = [_]t2.LayerPacketBlock{
        .{
            .location = .{ .leaf_x = 0, .leaf_y = 0 },
            .nominal_bitplanes = 8,
            .encoded_bitplanes = segment_a.bitplanes,
            .previous = a1,
            .current = a3,
            .payload = segment_a.bytes,
        },
        .{
            .location = .{ .leaf_x = 1, .leaf_y = 0 },
            .nominal_bitplanes = 8,
            .encoded_bitplanes = segment_b.bitplanes,
            .previous = zero,
            .current = b1,
            .payload = segment_b.bytes,
        },
    };
    const second_packet = try t2.appendPrecinctLayerPacket(
        allocator,
        &packet,
        &inclusion_encoder,
        &zero_encoder,
        write_states[0..],
        1,
        second_blocks[0..],
    );
    try std.testing.expectEqual(second_header_offset, second_packet.header_offset);
    try std.testing.expectEqual(@as(usize, 2), second_packet.included_blocks);
    const a_delta = try t2.layerPayloadSlice(segment_a.bytes, a1, a3);
    const b_delta = try t2.layerPayloadSlice(segment_b.bytes, zero, b1);
    try std.testing.expectEqual(a_delta.len + b_delta.len, second_packet.payload_length);
    try std.testing.expectEqualSlices(
        u8,
        a_delta,
        packet.items[second_packet.payload_offset..][0..a_delta.len],
    );
    try std.testing.expectEqualSlices(
        u8,
        b_delta,
        packet.items[second_packet.payload_offset + a_delta.len ..][0..b_delta.len],
    );

    var inclusion_decoder = try t2.TagTreeDecoder.init(allocator, 2, 1);
    defer inclusion_decoder.deinit();
    var zero_decoder = try t2.TagTreeDecoder.init(allocator, 2, 1);
    defer zero_decoder.deinit();
    var read_states = [_]t2.CodeBlockPacketState{.{}} ** 2;
    const locations = [_]t2.PacketBlockLocation{
        .{ .leaf_x = 0, .leaf_y = 0 },
        .{ .leaf_x = 1, .leaf_y = 0 },
    };
    var decoded: [2]t2.DecodedPacketBlock = undefined;
    var payloads: [2]?[]const u8 = undefined;

    const first_read = try t2.readPrecinctLayerPacket(
        allocator,
        packet.items[first_packet.header_offset..second_packet.header_offset],
        &inclusion_decoder,
        &zero_decoder,
        read_states[0..],
        0,
        locations[0..],
        8,
        decoded[0..],
        payloads[0..],
    );
    try std.testing.expectEqual(first_packet.header_length, first_read.header_length);
    try std.testing.expectEqual(first_packet.payload_length, first_read.payload_length);
    try std.testing.expectEqual(second_packet.header_offset, first_packet.header_offset + first_read.packet_length);
    try std.testing.expectEqual(@as(usize, 1), first_read.included_blocks);
    try std.testing.expect(decoded[0].included);
    try std.testing.expect(decoded[0].first_inclusion);
    try std.testing.expectEqual(@as(u16, 1), decoded[0].pass_count);
    try std.testing.expectEqual(a1.cumulative_bytes, decoded[0].byte_length);
    try std.testing.expectEqualSlices(u8, try t2.layerPayloadSlice(segment_a.bytes, zero, a1), payloads[0].?);
    try std.testing.expect(!decoded[1].included);
    try std.testing.expect(payloads[1] == null);

    const second_read = try t2.readPrecinctLayerPacket(
        allocator,
        packet.items[second_packet.header_offset..],
        &inclusion_decoder,
        &zero_decoder,
        read_states[0..],
        1,
        locations[0..],
        8,
        decoded[0..],
        payloads[0..],
    );
    try std.testing.expectEqual(second_packet.header_length, second_read.header_length);
    try std.testing.expectEqual(second_packet.payload_length, second_read.payload_length);
    try std.testing.expectEqual(packet.items.len - second_packet.header_offset, second_read.packet_length);
    try std.testing.expectEqual(@as(usize, 2), second_read.included_blocks);
    try std.testing.expect(decoded[0].included);
    try std.testing.expect(!decoded[0].first_inclusion);
    try std.testing.expectEqual(@as(u16, 2), decoded[0].pass_count);
    try std.testing.expectEqual(@as(u64, @intCast(a_delta.len)), decoded[0].byte_length);
    try std.testing.expectEqualSlices(u8, a_delta, payloads[0].?);
    try std.testing.expect(decoded[1].included);
    try std.testing.expect(decoded[1].first_inclusion);
    try std.testing.expectEqual(@as(u16, 1), decoded[1].pass_count);
    try std.testing.expectEqual(@as(u64, @intCast(b_delta.len)), decoded[1].byte_length);
    try std.testing.expectEqualSlices(u8, b_delta, payloads[1].?);
    try std.testing.expectEqualSlices(t2.CodeBlockPacketState, write_states[0..], read_states[0..]);
}

test "T2 precinct layer reader rolls back state on truncated payload" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{
        0, -7,  0,  5,
        1, 0,   -2, 0,
        0, 0,   0,  0,
        9, -12, 0,  4,
    };

    var segment = try ebcot.encodeCodeBlockSegment(allocator, plane[0..], 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    defer segment.deinit(allocator);
    const point = try segment.truncationPointForPasses(1);
    const zero = t2.LayerTruncation{ .cumulative_passes = 0, .cumulative_bytes = 0 };
    const first = t2.LayerTruncation{ .cumulative_passes = point.cumulative_passes, .cumulative_bytes = point.cumulative_bytes };

    var packet = std.ArrayList(u8).empty;
    defer packet.deinit(allocator);
    var inclusion_encoder = try t2.TagTreeEncoder.init(allocator, 1, 1, &[_]u32{0});
    defer inclusion_encoder.deinit();
    var zero_encoder = try t2.TagTreeEncoder.init(allocator, 1, 1, &[_]u32{@as(u32, 8 - segment.bitplanes)});
    defer zero_encoder.deinit();
    var write_states = [_]t2.CodeBlockPacketState{.{}} ** 1;
    const blocks = [_]t2.LayerPacketBlock{.{
        .location = .{ .leaf_x = 0, .leaf_y = 0 },
        .nominal_bitplanes = 8,
        .encoded_bitplanes = segment.bitplanes,
        .previous = zero,
        .current = first,
        .payload = segment.bytes,
    }};
    const written = try t2.appendPrecinctLayerPacket(
        allocator,
        &packet,
        &inclusion_encoder,
        &zero_encoder,
        write_states[0..],
        0,
        blocks[0..],
    );
    try std.testing.expect(written.payload_length > 0);

    var inclusion_decoder = try t2.TagTreeDecoder.init(allocator, 1, 1);
    defer inclusion_decoder.deinit();
    var zero_decoder = try t2.TagTreeDecoder.init(allocator, 1, 1);
    defer zero_decoder.deinit();
    var read_states = [_]t2.CodeBlockPacketState{.{}} ** 1;
    var decoded: [1]t2.DecodedPacketBlock = undefined;
    var payloads: [1]?[]const u8 = undefined;

    const original_states = read_states;
    const original_inclusion_lows = try allocator.dupe(u32, inclusion_decoder.lows);
    defer allocator.free(original_inclusion_lows);
    const original_zero_lows = try allocator.dupe(u32, zero_decoder.lows);
    defer allocator.free(original_zero_lows);

    try std.testing.expectError(
        t2.PacketHeaderError.TruncatedHeader,
        t2.readPrecinctLayerPacket(
            allocator,
            packet.items[0 .. packet.items.len - 1],
            &inclusion_decoder,
            &zero_decoder,
            read_states[0..],
            0,
            &[_]t2.PacketBlockLocation{.{ .leaf_x = 0, .leaf_y = 0 }},
            8,
            decoded[0..],
            payloads[0..],
        ),
    );
    try std.testing.expectEqualSlices(t2.CodeBlockPacketState, original_states[0..], read_states[0..]);
    try std.testing.expectEqualSlices(u32, original_inclusion_lows, inclusion_decoder.lows);
    try std.testing.expectEqualSlices(u32, original_zero_lows, zero_decoder.lows);
}

test "T2 packet state validates cumulative layer deltas" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{ 1, 2, 3, 4, 5, 6 };
    var packet = std.ArrayList(u8).empty;
    defer packet.deinit(allocator);
    var inclusion_encoder = try t2.TagTreeEncoder.init(allocator, 1, 1, &[_]u32{0});
    defer inclusion_encoder.deinit();
    var zero_encoder = try t2.TagTreeEncoder.init(allocator, 1, 1, &[_]u32{5});
    defer zero_encoder.deinit();
    var states = [_]t2.CodeBlockPacketState{.{}} ** 1;

    const first_blocks = [_]t2.LayerPacketBlock{.{
        .location = .{ .leaf_x = 0, .leaf_y = 0 },
        .nominal_bitplanes = 8,
        .encoded_bitplanes = 3,
        .previous = .{ .cumulative_passes = 0, .cumulative_bytes = 0 },
        .current = .{ .cumulative_passes = 1, .cumulative_bytes = 2 },
        .payload = payload[0..],
    }};
    _ = try t2.appendPrecinctLayerPacket(
        allocator,
        &packet,
        &inclusion_encoder,
        &zero_encoder,
        states[0..],
        0,
        first_blocks[0..],
    );
    try std.testing.expect(states[0].included);
    try std.testing.expectEqual(@as(u16, 1), states[0].cumulative_passes);
    try std.testing.expectEqual(@as(u64, 2), states[0].cumulative_bytes);
    try std.testing.expectEqual(@as(u8, 5), states[0].zero_bitplanes);
    try std.testing.expectEqual(@as(u8, 3), states[0].numLenBits());

    const stale_previous = [_]t2.LayerPacketBlock{.{
        .location = .{ .leaf_x = 0, .leaf_y = 0 },
        .nominal_bitplanes = 8,
        .encoded_bitplanes = 3,
        .previous = .{ .cumulative_passes = 0, .cumulative_bytes = 0 },
        .current = .{ .cumulative_passes = 2, .cumulative_bytes = 4 },
        .payload = payload[0..],
    }};
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        t2.appendPrecinctLayerPacket(
            allocator,
            &packet,
            &inclusion_encoder,
            &zero_encoder,
            states[0..],
            1,
            stale_previous[0..],
        ),
    );
}

test "T2 RPCL packet state writes and reads layer deltas" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{
        0, -7,  0,  5,
        1, 0,   -2, 0,
        0, 0,   0,  0,
        9, -12, 0,  4,
    };

    var segment = try ebcot.encodeCodeBlockSegmentDirect(allocator, plane[0..], 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    defer segment.deinit(allocator);
    try std.testing.expect(segment.pass_count >= 2);

    const plan = try packet_plan.rpclSingleTile(4, 4, 0, 1, 2, &[_]packet_plan.Precinct{.{ .width = 4, .height = 4 }});
    var iterator = try packet_plan.RpclIterator.init(plan, 1, 2);
    const first_packet = iterator.next().?;
    const second_packet = iterator.next().?;
    try std.testing.expectEqual(@as(?packet_plan.Packet, null), iterator.next());

    const zero = t2.LayerTruncation{ .cumulative_passes = 0, .cumulative_bytes = 0 };
    const first_point = try segment.truncationPointForPasses(1);
    const second_point = try segment.truncationPointForPasses(2);
    const first = t2.LayerTruncation{ .cumulative_passes = first_point.cumulative_passes, .cumulative_bytes = first_point.cumulative_bytes };
    const second = t2.LayerTruncation{ .cumulative_passes = second_point.cumulative_passes, .cumulative_bytes = second_point.cumulative_bytes };
    const zero_bitplanes = @as(u32, 8 - segment.bitplanes);

    var writer_state = try t2.PrecinctPacketWriterState.initWithLayerCount(
        allocator,
        1,
        1,
        &[_]u32{0},
        &[_]u32{zero_bitplanes},
        2,
    );
    defer writer_state.deinit();
    var packet_bytes = std.ArrayList(u8).empty;
    defer packet_bytes.deinit(allocator);

    const first_blocks = [_]t2.LayerPacketBlock{.{
        .location = .{ .leaf_x = 0, .leaf_y = 0 },
        .nominal_bitplanes = 8,
        .encoded_bitplanes = segment.bitplanes,
        .previous = zero,
        .current = first,
        .payload = segment.bytes,
    }};
    const first_written = try writer_state.appendRpclPacket(
        allocator,
        &packet_bytes,
        first_packet,
        0,
        0,
        0,
        first_blocks[0..],
    );
    try std.testing.expectEqual(@as(u16, 1), writer_state.next_layer);
    try std.testing.expectEqual(@as(?u64, 1), writer_state.next_sequence);
    try std.testing.expectEqual(@as(?u32, 0), writer_state.precinct_x);
    try std.testing.expectEqual(@as(?u32, 0), writer_state.precinct_y);

    const second_offset = packet_bytes.items.len;
    const second_blocks = [_]t2.LayerPacketBlock{.{
        .location = .{ .leaf_x = 0, .leaf_y = 0 },
        .nominal_bitplanes = 8,
        .encoded_bitplanes = segment.bitplanes,
        .previous = first,
        .current = second,
        .payload = segment.bytes,
    }};
    const second_written = try writer_state.appendRpclPacket(
        allocator,
        &packet_bytes,
        second_packet,
        0,
        0,
        0,
        second_blocks[0..],
    );
    try std.testing.expectEqual(@as(u16, 2), writer_state.next_layer);
    try std.testing.expectEqual(@as(?u64, 2), writer_state.next_sequence);

    try std.testing.expectEqual(@as(u16, 2), writer_state.states[0].cumulative_passes);
    try std.testing.expectEqual(second.cumulative_bytes, writer_state.states[0].cumulative_bytes);
    try std.testing.expectEqual(@as(u8, @intCast(zero_bitplanes)), writer_state.states[0].zero_bitplanes);

    var reader_state = try t2.PrecinctPacketReaderState.initWithLayerCount(allocator, 1, 1, 1, 2);
    defer reader_state.deinit();
    var decoded: [1]t2.DecodedPacketBlock = undefined;
    var payloads: [1]?[]const u8 = undefined;
    const locations = [_]t2.PacketBlockLocation{.{ .leaf_x = 0, .leaf_y = 0 }};

    const first_read = try reader_state.readRpclPacket(
        allocator,
        packet_bytes.items[0..second_offset],
        first_packet,
        0,
        0,
        0,
        locations[0..],
        8,
        decoded[0..],
        payloads[0..],
    );
    try std.testing.expectEqual(first_written.packet_length(), first_read.packet_length);
    try std.testing.expect(decoded[0].first_inclusion);
    try std.testing.expectEqualSlices(u8, try t2.layerPayloadSlice(segment.bytes, zero, first), payloads[0].?);
    try std.testing.expectEqual(@as(u16, 1), reader_state.next_layer);
    try std.testing.expectEqual(@as(?u64, 1), reader_state.next_sequence);
    try std.testing.expectEqual(@as(?u32, 0), reader_state.precinct_x);
    try std.testing.expectEqual(@as(?u32, 0), reader_state.precinct_y);

    const second_read = try reader_state.readRpclPacket(
        allocator,
        packet_bytes.items[second_offset..],
        second_packet,
        0,
        0,
        0,
        locations[0..],
        8,
        decoded[0..],
        payloads[0..],
    );
    try std.testing.expectEqual(second_written.packet_length(), second_read.packet_length);
    try std.testing.expect(!decoded[0].first_inclusion);
    try std.testing.expectEqualSlices(u8, try t2.layerPayloadSlice(segment.bytes, first, second), payloads[0].?);
    try std.testing.expectEqual(@as(u16, 2), reader_state.next_layer);
    try std.testing.expectEqual(@as(?u64, 2), reader_state.next_sequence);
    try std.testing.expectEqualSlices(t2.CodeBlockPacketState, writer_state.states, reader_state.states);

    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        writer_state.appendRpclPacket(
            allocator,
            &packet_bytes,
            second_packet,
            0,
            1,
            0,
            second_blocks[0..],
        ),
    );
}

test "T2 RPCL packet state rejects out-of-order layer packets" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{ 1, 2, 3, 4 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var writer_state = try t2.PrecinctPacketWriterState.initWithLayerCount(
        allocator,
        1,
        1,
        &[_]u32{0},
        &[_]u32{5},
        2,
    );
    defer writer_state.deinit();

    const block = [_]t2.LayerPacketBlock{.{
        .location = .{ .leaf_x = 0, .leaf_y = 0 },
        .nominal_bitplanes = 8,
        .encoded_bitplanes = 3,
        .previous = .{ .cumulative_passes = 0, .cumulative_bytes = 0 },
        .current = .{ .cumulative_passes = 1, .cumulative_bytes = 2 },
        .payload = payload[0..],
    }};
    const skipped_layer = packet_plan.Packet{
        .sequence = 1,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 1,
    };

    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        writer_state.appendRpclPacket(allocator, &out, skipped_layer, 0, 0, 0, block[0..]),
    );
    try std.testing.expectEqual(@as(u16, 0), writer_state.next_layer);
    try std.testing.expect(!writer_state.states[0].included);

    const first_layer = packet_plan.Packet{
        .sequence = 0,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 0,
    };
    _ = try writer_state.appendRpclPacket(allocator, &out, first_layer, 0, 0, 0, block[0..]);
    try std.testing.expectEqual(@as(u16, 1), writer_state.next_layer);
    try std.testing.expectEqual(@as(?u64, 1), writer_state.next_sequence);

    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        writer_state.appendRpclPacket(allocator, &out, first_layer, 0, 0, 0, block[0..]),
    );
    try std.testing.expectEqual(@as(u16, 1), writer_state.next_layer);
    try std.testing.expectEqual(@as(?u64, 1), writer_state.next_sequence);

    const wrong_sequence = packet_plan.Packet{
        .sequence = 7,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 1,
    };
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        writer_state.appendRpclPacket(allocator, &out, wrong_sequence, 0, 0, 0, block[0..]),
    );
    try std.testing.expectEqual(@as(u16, 1), writer_state.next_layer);
    try std.testing.expectEqual(@as(?u64, 1), writer_state.next_sequence);

    const wrong_precinct_coords = packet_plan.Packet{
        .sequence = 1,
        .resolution = 0,
        .precinct_x = 1,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 1,
    };
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        writer_state.appendRpclPacket(allocator, &out, wrong_precinct_coords, 0, 0, 0, block[0..]),
    );
    try std.testing.expectEqual(@as(u16, 1), writer_state.next_layer);
    try std.testing.expectEqual(@as(?u64, 1), writer_state.next_sequence);
}

test "T2 RPCL packet state rejects packets past configured layer count" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{ 1, 2, 3, 4 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var writer_state = try t2.PrecinctPacketWriterState.initWithLayerCount(
        allocator,
        1,
        1,
        &[_]u32{0},
        &[_]u32{5},
        1,
    );
    defer writer_state.deinit();

    const block = [_]t2.LayerPacketBlock{.{
        .location = .{ .leaf_x = 0, .leaf_y = 0 },
        .nominal_bitplanes = 8,
        .encoded_bitplanes = 3,
        .previous = .{ .cumulative_passes = 0, .cumulative_bytes = 0 },
        .current = .{ .cumulative_passes = 1, .cumulative_bytes = 2 },
        .payload = payload[0..],
    }};
    const first = packet_plan.Packet{
        .sequence = 0,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 0,
    };
    _ = try writer_state.appendRpclPacket(allocator, &out, first, 0, 0, 0, block[0..]);
    try std.testing.expectEqual(@as(u16, 1), writer_state.next_layer);

    const past_end = packet_plan.Packet{
        .sequence = 1,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 1,
    };
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        writer_state.appendRpclPacket(allocator, &out, past_end, 0, 0, 0, block[0..]),
    );
    try std.testing.expectEqual(@as(u16, 1), writer_state.next_layer);
    try std.testing.expectEqual(@as(?u64, 1), writer_state.next_sequence);
}

test "T2 RPCL reader state preserves order on failed packet decode" {
    const allocator = std.testing.allocator;
    const payload = [_]u8{ 1, 2, 3, 4 };
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);

    var writer_state = try t2.PrecinctPacketWriterState.initWithLayerCount(
        allocator,
        1,
        1,
        &[_]u32{0},
        &[_]u32{5},
        1,
    );
    defer writer_state.deinit();

    const packet = packet_plan.Packet{
        .sequence = 0,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 0,
    };
    const block = [_]t2.LayerPacketBlock{.{
        .location = .{ .leaf_x = 0, .leaf_y = 0 },
        .nominal_bitplanes = 8,
        .encoded_bitplanes = 3,
        .previous = .{ .cumulative_passes = 0, .cumulative_bytes = 0 },
        .current = .{ .cumulative_passes = 1, .cumulative_bytes = 2 },
        .payload = payload[0..],
    }};
    _ = try writer_state.appendRpclPacket(allocator, &out, packet, 0, 0, 0, block[0..]);

    var reader_state = try t2.PrecinctPacketReaderState.initWithLayerCount(allocator, 1, 1, 1, 1);
    defer reader_state.deinit();
    var decoded: [1]t2.DecodedPacketBlock = undefined;
    var payloads: [1]?[]const u8 = undefined;
    const locations = [_]t2.PacketBlockLocation{.{ .leaf_x = 0, .leaf_y = 0 }};
    const original_states = try allocator.dupe(t2.CodeBlockPacketState, reader_state.states);
    defer allocator.free(original_states);

    try std.testing.expectError(
        t2.PacketHeaderError.TruncatedHeader,
        reader_state.readRpclPacket(
            allocator,
            out.items[0 .. out.items.len - 1],
            packet,
            0,
            0,
            0,
            locations[0..],
            8,
            decoded[0..],
            payloads[0..],
        ),
    );
    try std.testing.expectEqual(@as(u16, 0), reader_state.next_layer);
    try std.testing.expectEqualSlices(t2.CodeBlockPacketState, original_states, reader_state.states);

    const skipped_layer = packet_plan.Packet{
        .sequence = 1,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 1,
    };
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        reader_state.readRpclPacket(
            allocator,
            out.items,
            skipped_layer,
            0,
            0,
            0,
            locations[0..],
            8,
            decoded[0..],
            payloads[0..],
        ),
    );
    try std.testing.expectEqual(@as(u16, 0), reader_state.next_layer);

    var packet_with_trailing = try std.ArrayList(u8).initCapacity(allocator, out.items.len + 1);
    defer packet_with_trailing.deinit(allocator);
    try packet_with_trailing.appendSlice(allocator, out.items);
    try packet_with_trailing.append(allocator, 0);
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        reader_state.readRpclPacket(
            allocator,
            packet_with_trailing.items,
            packet,
            0,
            0,
            0,
            locations[0..],
            8,
            decoded[0..],
            payloads[0..],
        ),
    );
    try std.testing.expectEqual(@as(u16, 0), reader_state.next_layer);
    try std.testing.expectEqual(@as(?u64, null), reader_state.next_sequence);
    try std.testing.expectEqualSlices(t2.CodeBlockPacketState, original_states, reader_state.states);

    _ = try reader_state.readRpclPacket(
        allocator,
        out.items,
        packet,
        0,
        0,
        0,
        locations[0..],
        8,
        decoded[0..],
        payloads[0..],
    );
    try std.testing.expectEqual(@as(u16, 1), reader_state.next_layer);
    try std.testing.expectEqual(@as(?u64, 1), reader_state.next_sequence);

    const wrong_sequence = packet_plan.Packet{
        .sequence = 7,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 1,
    };
    try std.testing.expectError(
        t2.PacketHeaderError.InvalidPacketHeader,
        reader_state.readRpclPacket(
            allocator,
            out.items,
            wrong_sequence,
            0,
            0,
            0,
            locations[0..],
            8,
            decoded[0..],
            payloads[0..],
        ),
    );
    try std.testing.expectEqual(@as(u16, 1), reader_state.next_layer);
    try std.testing.expectEqual(@as(?u64, 1), reader_state.next_sequence);
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

test "JP2 reader rejects unsupported file type brand" {
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

    {
        const corrupted = try allocator.dupe(u8, wrapped);
        defer allocator.free(corrupted);
        const ftyp_payload = try findJp2BoxPayload(corrupted, "ftyp");
        @memcpy(corrupted[ftyp_payload.start..][0..4], "jpx ");
        try std.testing.expectError(jp2.Jp2Error.UnsupportedProfile, jp2.parseInfo(corrupted));
    }

    {
        const corrupted = try allocator.dupe(u8, wrapped);
        defer allocator.free(corrupted);
        const ftyp_payload = try findJp2BoxPayload(corrupted, "ftyp");
        @memcpy(corrupted[ftyp_payload.start + 8 ..][0..4], "jpx ");
        try std.testing.expectError(jp2.Jp2Error.UnsupportedProfile, jp2.parseInfo(corrupted));
    }
}

test "JP2 reader rejects unsupported basic RGB profile boxes" {
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
    const jp2h_payload = try findJp2BoxPayload(wrapped, "jp2h");

    {
        const corrupted = try allocator.dupe(u8, wrapped);
        defer allocator.free(corrupted);
        const ihdr_payload = try findJp2ChildBoxPayload(corrupted, jp2h_payload, "ihdr");
        corrupted[ihdr_payload.start + 9] = 1;
        try std.testing.expectError(jp2.Jp2Error.UnsupportedColorSpace, jp2.parseInfo(corrupted));
    }

    {
        const corrupted = try allocator.dupe(u8, wrapped);
        defer allocator.free(corrupted);
        const ihdr_payload = try findJp2ChildBoxPayload(corrupted, jp2h_payload, "ihdr");
        corrupted[ihdr_payload.start + 10] = 0xff;
        try std.testing.expectError(jp2.Jp2Error.UnsupportedProfile, jp2.parseInfo(corrupted));
    }

    {
        const corrupted = try allocator.dupe(u8, wrapped);
        defer allocator.free(corrupted);
        const colr_payload = try findJp2ChildBoxPayload(corrupted, jp2h_payload, "colr");
        corrupted[colr_payload.start + 3] = 17;
        try std.testing.expectError(jp2.Jp2Error.UnsupportedColorSpace, jp2.parseInfo(corrupted));
    }
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
    try std.testing.expect(std.mem.indexOf(u8, bytes, "ZJ2K-CBLK-BP8") == null);

    const sot_index = findMarker(bytes, codestream.markerValue("sot")) orelse return error.MissingSot;
    const psot = try codestream.firstSotPsot(bytes);
    const ptlm = try codestream.firstTlmPtlm(bytes);
    const stats = try codestream.analyzeLosslessTemporary(bytes);
    const expected_tile_parts = @as(usize, stats.levels) + 1;
    try std.testing.expectEqual(psot, ptlm);
    try std.testing.expectEqual(@as(usize, 0), stats.payload_bytes);
    try std.testing.expectEqual(stats.packet_count, stats.sod_packets);
    try std.testing.expect(stats.sod_packet_bytes > 0);
    try std.testing.expectEqual(@as(u64, 0), stats.rpcl_shadow_packets);
    try std.testing.expectEqual(@as(u64, 0), stats.rpcl_shadow_bytes);
    var strict_catalog = try codestream.readStrictPacketBlockCatalog(allocator, bytes);
    defer strict_catalog.deinit();
    try std.testing.expect(strict_catalog.components[0].len > 0);
    try std.testing.expectError(
        codestream.CodestreamError.UnsupportedPayload,
        codestream.decodeLosslessTemporary(allocator, bytes),
    );
    try std.testing.expectEqual(expected_tile_parts, countMarker(bytes, codestream.markerValue("sot")));
    try std.testing.expectEqual(@as(usize, @intCast(stats.packet_count)), try countTilePartPrefixMarker(bytes, codestream.markerValue("sop")));
    try std.testing.expectEqual(@as(usize, @intCast(stats.packet_count)), try countTilePartPrefixMarker(bytes, codestream.markerValue("eph")));
    try std.testing.expectEqual(codestream.markerValue("sot"), readU16BeTest(bytes, sot_index + psot));
}

test "lossless codestream places EPH before non-empty packet payload" {
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

    try std.testing.expect(try hasNonTrailingEphPacketForTest(bytes));
}

test "debug temporary sidecar option preserves BP8 COM payload" {
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

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 2,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "ZJ2K-CBLK-BP8") != null);
    const stats = try codestream.analyzeLosslessTemporary(bytes);
    try std.testing.expect(stats.payload_bytes > 0);
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

test "EBCOT sign coding uses neighbor prediction context" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{ -4, -4 };

    var encoded = try ebcot.encodeBlock(allocator, plane[0..], 2, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    defer encoded.deinit(allocator);

    const top = encoded.symbols[encoded.passes[0].first_symbol..][0..encoded.passes[0].symbol_count];
    try std.testing.expectEqual(@as(usize, 4), top.len);
    try std.testing.expectEqual(ebcot.SymbolKind.sign, top[1].kind);
    try std.testing.expectEqual(ebcot.Context.sign0, top[1].context);
    try std.testing.expectEqual(true, top[1].bit);
    try std.testing.expectEqual(ebcot.SymbolKind.sign, top[3].kind);
    try std.testing.expectEqual(ebcot.Context.sign1, top[3].context);
    try std.testing.expectEqual(false, top[3].bit);
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

test "EBCOT symbol oracle scans block stats across vector tails" {
    const allocator = std.testing.allocator;
    const width = 11;
    const height = 3;
    var plane = [_]i32{0} ** (width * height);
    plane[0] = 1;
    plane[7] = -2;
    plane[8] = 3;
    plane[width + 10] = -17;
    plane[2 * width + 4] = 9;

    var encoded = try ebcot.encodeBlock(allocator, plane[0..], width, .{ .x = 0, .y = 0, .width = width, .height = height });
    defer encoded.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 5), encoded.non_zero_count);
    try std.testing.expectEqual(@as(u8, 5), encoded.bitplanes);
    try std.testing.expect(encoded.symbols.len > 0);
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

test "EBCOT symbols roundtrip through MQ contexts" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{
        0, -7,  0,  5,
        1, 0,   -2, 0,
        0, 0,   0,  0,
        9, -12, 0,  4,
    };

    var block = try ebcot.encodeBlock(allocator, plane[0..], 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    defer block.deinit(allocator);
    try std.testing.expect(block.symbols.len > 0);

    var encoded = try ebcot.encodeSymbolsMq(allocator, block.symbols);
    defer encoded.deinit(allocator);
    try std.testing.expectEqual(block.symbols.len, encoded.symbol_count);
    try expectMarkerStuffingIsValid(encoded.bytes);

    const decoded_bits = try ebcot.decodeSymbolBitsMq(allocator, encoded.bytes, encoded.symbol_count, block.symbols);
    defer allocator.free(decoded_bits);
    try std.testing.expectEqual(block.symbols.len, decoded_bits.len);
    for (block.symbols, decoded_bits) |symbol, bit| {
        try std.testing.expectEqual(symbol.bit, bit);
    }

    try std.testing.expectError(
        mq.MqError.InvalidData,
        ebcot.decodeSymbolBitsMq(allocator, encoded.bytes, encoded.symbol_count + 1, block.symbols),
    );
}

test "EBCOT code-block segment records MQ payload truncation points" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{
        0, -7,  0,  5,
        1, 0,   -2, 0,
        0, 0,   0,  0,
        9, -12, 0,  4,
    };

    var block = try ebcot.encodeBlock(allocator, plane[0..], 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    defer block.deinit(allocator);
    var segment = try ebcot.encodeBlockSymbolsSegment(allocator, .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .passes = block.passes,
        .symbols = block.symbols,
    });
    defer segment.deinit(allocator);

    try std.testing.expectEqual(block.bitplanes, segment.bitplanes);
    try std.testing.expectEqual(block.non_zero_count, segment.non_zero_count);
    try std.testing.expectEqual(@as(u16, @intCast(block.passes.len)), segment.pass_count);
    try std.testing.expectEqual(@as(u64, @intCast(segment.bytes.len)), segment.byte_length);
    try std.testing.expect(segment.bytes.len > 0);

    var cumulative_symbols: usize = 0;
    var previous_bytes: u64 = 0;
    for (segment.passes, block.passes, 0..) |payload, pass, index| {
        try std.testing.expectEqual(pass.kind, payload.kind);
        try std.testing.expectEqual(pass.magnitude_bitplane, payload.magnitude_bitplane);
        try std.testing.expectEqual(pass.symbol_count, payload.symbol_count);
        try std.testing.expectEqual(previous_bytes, @as(u64, @intCast(payload.byte_offset)));
        try std.testing.expect(payload.byte_length > 0);
        try std.testing.expect(payload.cumulative_bytes > previous_bytes);
        var standalone = try ebcot.encodeSymbolsMq(allocator, block.symbols[pass.first_symbol..][0..pass.symbol_count]);
        defer standalone.deinit(allocator);
        try std.testing.expectEqualSlices(
            u8,
            standalone.bytes,
            segment.bytes[payload.byte_offset..][0..payload.byte_length],
        );
        const point = try segment.truncationPointForPasses(@intCast(index + 1));
        try std.testing.expectEqual(@as(u16, @intCast(index + 1)), point.cumulative_passes);
        try std.testing.expectEqual(payload.cumulative_bytes, point.cumulative_bytes);
        previous_bytes = payload.cumulative_bytes;
        cumulative_symbols += payload.symbol_count;
    }
    try std.testing.expectEqual(block.symbols.len, cumulative_symbols);
    try std.testing.expectEqual(segment.byte_length, previous_bytes);
    try std.testing.expectEqual(ebcot.TruncationPoint{ .cumulative_passes = 0, .cumulative_bytes = 0 }, try segment.truncationPointForPasses(0));
    try std.testing.expectError(ebcot.EbcotError.InvalidBlock, segment.truncationPointForPasses(segment.pass_count + 1));

    const decoded_bits = try ebcot.decodeCodeBlockSegmentBits(allocator, segment, block.symbols);
    defer allocator.free(decoded_bits);
    try std.testing.expectEqual(block.symbols.len, decoded_bits.len);
    for (block.symbols, decoded_bits) |symbol, bit| {
        try std.testing.expectEqual(symbol.bit, bit);
    }
}

test "EBCOT continuous MQ segment roundtrips whole code-block payload" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{
        0, -7,  0,  5,
        1, 0,   -2, 0,
        3, 0,   0,  -6,
        9, -12, 0,  4,
    };

    var block = try ebcot.encodeBlock(allocator, plane[0..], 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    defer block.deinit(allocator);
    var segment = try ebcot.encodeBlockSymbolsSegmentContinuous(allocator, .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .passes = block.passes,
        .symbols = block.symbols,
    });
    defer segment.deinit(allocator);

    try std.testing.expectEqual(block.bitplanes, segment.bitplanes);
    try std.testing.expectEqual(block.non_zero_count, segment.non_zero_count);
    try std.testing.expectEqual(@as(u16, @intCast(block.passes.len)), segment.pass_count);
    try std.testing.expectEqual(@as(u64, @intCast(segment.bytes.len)), segment.byte_length);
    try expectMarkerStuffingIsValid(segment.bytes);

    var previous_end: u64 = 0;
    for (segment.passes, block.passes) |payload, pass| {
        try std.testing.expectEqual(pass.kind, payload.kind);
        try std.testing.expectEqual(pass.magnitude_bitplane, payload.magnitude_bitplane);
        try std.testing.expectEqual(pass.symbol_count, payload.symbol_count);
        try std.testing.expectEqual(previous_end, @as(u64, @intCast(payload.byte_offset)));
        try std.testing.expect(payload.cumulative_bytes >= previous_end);
        try std.testing.expectEqual(payload.cumulative_bytes - previous_end, @as(u64, @intCast(payload.byte_length)));
        previous_end = payload.cumulative_bytes;
    }
    try std.testing.expectEqual(segment.byte_length, previous_end);

    const decoded_bits = try ebcot.decodeCodeBlockSegmentBitsContinuous(allocator, segment, block.symbols);
    defer allocator.free(decoded_bits);
    for (block.symbols, decoded_bits) |symbol, bit| {
        try std.testing.expectEqual(symbol.bit, bit);
    }
}

test "EBCOT continuous MQ coefficient decoder roundtrips a block" {
    const allocator = std.testing.allocator;
    const width = 5;
    const height = 4;
    const plane = [_]i32{
        0, -7,  0,  5, 3,
        1, 0,   -2, 0, 0,
        0, 0,   0,  0, -1,
        9, -12, 0,  4, 0,
    };

    var block = try ebcot.encodeBlock(allocator, plane[0..], width, .{ .x = 0, .y = 0, .width = width, .height = height });
    defer block.deinit(allocator);
    var segment = try ebcot.encodeBlockSymbolsSegmentContinuous(allocator, .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .passes = block.passes,
        .symbols = block.symbols,
    });
    defer segment.deinit(allocator);

    const decoded = try ebcot.decodeCodeBlockSegmentCoefficientsContinuous(allocator, segment, width, height);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(i32, plane[0..], decoded);
}

test "EBCOT continuous MQ partial coefficient decoder accepts pass prefixes" {
    const allocator = std.testing.allocator;
    const width = 5;
    const height = 4;
    const plane = [_]i32{
        0, -7,  0,  5, 3,
        1, 0,   -2, 0, 0,
        0, 0,   0,  0, -1,
        9, -12, 0,  4, 0,
    };

    var block = try ebcot.encodeBlock(allocator, plane[0..], width, .{ .x = 0, .y = 0, .width = width, .height = height });
    defer block.deinit(allocator);
    var full = try ebcot.encodeBlockSymbolsSegmentContinuous(allocator, .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .passes = block.passes,
        .symbols = block.symbols,
    });
    defer full.deinit(allocator);

    const pass_count: u16 = @min(2, full.pass_count);
    const byte_length = full.passes[pass_count - 1].cumulative_bytes;
    const partial = ebcot.CodeBlockSegment{
        .bitplanes = full.bitplanes,
        .non_zero_count = full.non_zero_count,
        .pass_count = pass_count,
        .byte_length = byte_length,
        .passes = full.passes[0..pass_count],
        .bytes = full.bytes[0..@intCast(byte_length)],
    };

    const decoded = try ebcot.decodeCodeBlockSegmentCoefficientsContinuousPartial(allocator, partial, width, height);
    defer allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, width * height), decoded.len);
    try std.testing.expect(countNonZeroI32Test(decoded) <= full.non_zero_count);
}

test "EBCOT direct MQ segment matches symbol oracle" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{
        0, -7,  0,  5,  3,
        1, 0,   -2, 0,  0,
        0, 0,   0,  0,  -1,
        9, -12, 0,  4,  0,
        0, 6,   0,  -8, 2,
    };

    var block = try ebcot.encodeBlock(allocator, plane[0..], 5, .{ .x = 0, .y = 0, .width = 5, .height = 5 });
    defer block.deinit(allocator);
    var oracle = try ebcot.encodeBlockSymbolsSegment(allocator, .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .passes = block.passes,
        .symbols = block.symbols,
    });
    defer oracle.deinit(allocator);

    var direct = try ebcot.encodeCodeBlockSegmentDirect(allocator, plane[0..], 5, .{ .x = 0, .y = 0, .width = 5, .height = 5 });
    defer direct.deinit(allocator);

    try std.testing.expectEqual(oracle.bitplanes, direct.bitplanes);
    try std.testing.expectEqual(oracle.non_zero_count, direct.non_zero_count);
    try std.testing.expectEqual(oracle.pass_count, direct.pass_count);
    try std.testing.expectEqual(oracle.byte_length, direct.byte_length);
    try std.testing.expectEqualSlices(u8, oracle.bytes, direct.bytes);
    try std.testing.expectEqualSlices(ebcot.CodeBlockPassPayload, oracle.passes, direct.passes);
}

test "EBCOT direct MQ row masks match oracle across word boundaries" {
    const allocator = std.testing.allocator;
    const width = 70;
    const height = 4;
    var plane = [_]i32{0} ** (width * height);
    plane[63] = 5;
    plane[64] = -7;
    plane[65] = 3;
    plane[width + 62] = 2;
    plane[width + 66] = -4;
    plane[2 * width + 0] = 9;
    plane[3 * width + 69] = -6;

    var block = try ebcot.encodeBlock(allocator, plane[0..], width, .{ .x = 0, .y = 0, .width = width, .height = height });
    defer block.deinit(allocator);
    var oracle = try ebcot.encodeBlockSymbolsSegment(allocator, .{
        .bitplanes = block.bitplanes,
        .non_zero_count = block.non_zero_count,
        .passes = block.passes,
        .symbols = block.symbols,
    });
    defer oracle.deinit(allocator);

    var direct = try ebcot.encodeCodeBlockSegmentDirect(allocator, plane[0..], width, .{ .x = 0, .y = 0, .width = width, .height = height });
    defer direct.deinit(allocator);

    try std.testing.expectEqual(oracle.bitplanes, direct.bitplanes);
    try std.testing.expectEqual(oracle.non_zero_count, direct.non_zero_count);
    try std.testing.expectEqual(oracle.pass_count, direct.pass_count);
    try std.testing.expectEqual(oracle.byte_length, direct.byte_length);
    try std.testing.expectEqualSlices(u8, oracle.bytes, direct.bytes);
    try std.testing.expectEqualSlices(ebcot.CodeBlockPassPayload, oracle.passes, direct.passes);
}

test "EBCOT direct MQ segment reconstructs code-block coefficients" {
    const allocator = std.testing.allocator;
    const width = 5;
    const height = 5;
    const plane = [_]i32{
        0, -7,  0,  5,  3,
        1, 0,   -2, 0,  0,
        0, 0,   0,  0,  -1,
        9, -12, 0,  4,  0,
        0, 6,   0,  -8, 2,
    };

    var segment = try ebcot.encodeCodeBlockSegmentDirect(allocator, plane[0..], width, .{ .x = 0, .y = 0, .width = width, .height = height });
    defer segment.deinit(allocator);

    const decoded = try ebcot.decodeCodeBlockSegmentCoefficients(allocator, segment, width, height);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(i32, plane[0..], decoded);
}

test "EBCOT direct MQ partial coefficient decoder accepts layer truncation points" {
    const allocator = std.testing.allocator;
    const width = 5;
    const height = 5;
    const plane = [_]i32{
        0, -7,  0,  5,  3,
        1, 0,   -2, 0,  0,
        0, 0,   0,  0,  -1,
        9, -12, 0,  4,  0,
        0, 6,   0,  -8, 2,
    };

    var full = try ebcot.encodeCodeBlockSegmentDirect(allocator, plane[0..], width, .{ .x = 0, .y = 0, .width = width, .height = height });
    defer full.deinit(allocator);
    try std.testing.expect(full.pass_count >= 3);

    const pass_count: u16 = 2;
    const byte_length = full.passes[pass_count - 1].cumulative_bytes;
    const partial = ebcot.CodeBlockSegment{
        .bitplanes = full.bitplanes,
        .non_zero_count = full.non_zero_count,
        .pass_count = pass_count,
        .byte_length = byte_length,
        .passes = full.passes[0..pass_count],
        .bytes = full.bytes[0..@intCast(byte_length)],
    };

    const decoded = try ebcot.decodeCodeBlockSegmentCoefficientsPartial(allocator, partial, width, height);
    defer allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, width * height), decoded.len);
    try std.testing.expect(countNonZeroI32Test(decoded) <= full.non_zero_count);
    try std.testing.expectError(ebcot.EbcotError.InvalidBlock, ebcot.decodeCodeBlockSegmentCoefficients(allocator, partial, width, height));
}

test "EBCOT direct MQ coefficient decoder handles empty code-blocks" {
    const allocator = std.testing.allocator;
    const width = 4;
    const height = 3;
    const plane = [_]i32{0} ** (width * height);

    var segment = try ebcot.encodeCodeBlockSegmentDirect(allocator, plane[0..], width, .{ .x = 0, .y = 0, .width = width, .height = height });
    defer segment.deinit(allocator);

    const decoded = try ebcot.decodeCodeBlockSegmentCoefficients(allocator, segment, width, height);
    defer allocator.free(decoded);
    try std.testing.expectEqualSlices(i32, plane[0..], decoded);
}

test "EBCOT direct MQ scratch reuses buffers" {
    const allocator = std.testing.allocator;
    const first_plane = [_]i32{
        0, -7,  0,  5,
        1, 0,   -2, 0,
        0, 0,   0,  0,
        9, -12, 0,  4,
    };
    const second_plane = [_]i32{ 4, 2 };

    var scratch = ebcot.DirectBlockScratch.init(allocator);
    defer scratch.deinit();

    var first = try ebcot.encodeCodeBlockSegmentDirectScratch(&scratch, first_plane[0..], 4, .{ .x = 0, .y = 0, .width = 4, .height = 4 });
    defer first.deinit(allocator);
    try std.testing.expect(first.bytes.len > 0);
    const flags_capacity = scratch.flags.capacity;
    const pass_capacity = scratch.pass_payloads.capacity;
    const bytes_capacity = scratch.bytes.capacity;

    var second = try ebcot.encodeCodeBlockSegmentDirectScratch(&scratch, second_plane[0..], 2, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    defer second.deinit(allocator);
    try std.testing.expect(second.bytes.len < first.bytes.len);
    try std.testing.expectEqual(flags_capacity, scratch.flags.capacity);
    try std.testing.expectEqual(pass_capacity, scratch.pass_payloads.capacity);
    try std.testing.expectEqual(bytes_capacity, scratch.bytes.capacity);
}

test "EBCOT empty code-block segment has no passes or payload bytes" {
    const allocator = std.testing.allocator;
    const plane = [_]i32{ 0, 0, 0, 0 };

    var segment = try ebcot.encodeCodeBlockSegment(allocator, plane[0..], 2, .{ .x = 0, .y = 0, .width = 2, .height = 2 });
    defer segment.deinit(allocator);

    try std.testing.expectEqual(@as(u8, 0), segment.bitplanes);
    try std.testing.expectEqual(@as(u32, 0), segment.non_zero_count);
    try std.testing.expectEqual(@as(u16, 0), segment.pass_count);
    try std.testing.expectEqual(@as(u64, 0), segment.byte_length);
    try std.testing.expectEqual(@as(usize, 0), segment.passes.len);
    try std.testing.expectEqual(@as(usize, 0), segment.bytes.len);
    try std.testing.expectEqual(ebcot.TruncationPoint{ .cumulative_passes = 0, .cumulative_bytes = 0 }, try segment.truncationPointForPasses(0));
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

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{ .levels = 2, .emit_temporary_payload_sidecar = true });
    defer allocator.free(bytes);

    var decoded = try codestream.decodeLosslessTemporary(allocator, bytes);
    defer decoded.deinit();

    try std.testing.expectEqual(rgb.width, decoded.width);
    try std.testing.expectEqual(rgb.height, decoded.height);
    try std.testing.expectEqual(rgb.bit_depth, decoded.bit_depth);
    try std.testing.expectEqualSlices(u16, rgb.samples, decoded.samples);
}

test "temporary lossless decode prefers strict RPCL image over legacy sidecar pixels" {
    const allocator = std.testing.allocator;
    const width = 16;
    const height = 12;
    const samples = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(samples);
    for (0..width * height) |i| {
        samples[i * 3 + 0] = @as(u16, @intCast((i * 13 + 5) % 251));
        samples[i * 3 + 1] = @as(u16, @intCast((i * 17 + 11) % 251));
        samples[i * 3 + 2] = @as(u16, @intCast((i * 19 + 23) % 251));
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
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);
    const payload = try extractTemporaryPayloadCommentForTest(allocator, bytes) orelse return error.MissingPayload;
    defer allocator.free(payload);

    const corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);
    const legacy_payload_byte = try bp8FirstLegacyEntropyPayloadByteOffsetForTest(payload);
    try xorTemporaryPayloadCommentByteForTest(corrupted, legacy_payload_byte, 0x01);

    var decoded = try codestream.decodeLosslessTemporary(allocator, corrupted);
    defer decoded.deinit();

    try std.testing.expectEqual(rgb.width, decoded.width);
    try std.testing.expectEqual(rgb.height, decoded.height);
    try std.testing.expectEqual(rgb.bit_depth, decoded.bit_depth);
    try std.testing.expectEqualSlices(u16, rgb.samples, decoded.samples);
}

test "threaded temporary lossless codestream roundtrips RGB samples" {
    const allocator = std.testing.allocator;
    const width = 16;
    const height = 12;
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
        .block_width = 4,
        .block_height = 4,
        .threads = 3,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);
    const serial_bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 2,
        .block_width = 4,
        .block_height = 4,
        .threads = 1,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(serial_bytes);
    const two_thread_bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 2,
        .block_width = 4,
        .block_height = 4,
        .threads = 2,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(two_thread_bytes);
    const block_thread_bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 2,
        .block_width = 4,
        .block_height = 4,
        .threads = 6,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(block_thread_bytes);
    try std.testing.expectEqualSlices(u8, serial_bytes, two_thread_bytes);
    try std.testing.expectEqualSlices(u8, serial_bytes, bytes);
    try std.testing.expectEqualSlices(u8, serial_bytes, block_thread_bytes);

    var decoded = try codestream.decodeLosslessTemporaryWithOptions(allocator, block_thread_bytes, .{ .threads = 3 });
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
        .emit_temporary_payload_sidecar = true,
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
    try std.testing.expectEqual(stats.packet_count, stats.sod_packets);
    try std.testing.expect(stats.sod_packet_bytes > 0);
    try std.testing.expectEqual(stats.packet_count, stats.rpcl_shadow_packets);
    try std.testing.expect(stats.rpcl_shadow_bytes > 0);
    try std.testing.expectEqual(@as(u32, 2), stats.packet_plan[0].width);
    try std.testing.expectEqual(@as(u32, 1), stats.packet_plan[0].height);
    try std.testing.expectEqual(@as(u64, 9), stats.packet_plan[0].packets);
    try std.testing.expectEqual(@as(u32, 4), stats.packet_plan[1].width);
    try std.testing.expectEqual(@as(u32, 2), stats.packet_plan[1].height);
    try std.testing.expectEqual(@as(u64, 9), stats.packet_plan[1].packets);
    try std.testing.expect(stats.payload_bytes < stats.codestream_bytes);
    try std.testing.expect(stats.components[0].blocks > 0);
    try std.testing.expect(stats.components[0].coding_passes > 0);
    try std.testing.expect(stats.components[0].ebcot_segments.blocks > 0);
    try std.testing.expectEqual(stats.components[0].coding_passes, stats.components[0].ebcot_segments.passes);
    try std.testing.expect(stats.components[0].ebcot_segments.symbols > 0);
    try std.testing.expect(stats.components[0].ebcot_segments.mq_bytes > 0);
    try std.testing.expect(stats.components[0].quality_layers[0].blocks > 0);
    try std.testing.expect(stats.components[0].quality_layers[1].cumulative_passes >= stats.components[0].quality_layers[0].cumulative_passes);
    try std.testing.expectEqual(stats.components[0].coding_passes, stats.components[0].quality_layers[2].cumulative_passes);
    try std.testing.expectEqual(stats.components[0].ebcot_segments.mq_bytes, stats.components[0].quality_layers[2].cumulative_bytes);
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
        .emit_temporary_payload_sidecar = true,
    };
    options.rates[0] = 8.0;
    options.rates[1] = 2.0;

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, options);
    defer allocator.free(bytes);

    const stats = try codestream.analyzeLosslessTemporary(bytes);
    try std.testing.expectEqual(@as(u16, 3), stats.layers);
    const y = stats.components[0];
    try std.testing.expect(y.quality_layers[0].blocks > 0);
    try std.testing.expect(y.ebcot_segments.mq_bytes > 0);
    try std.testing.expect(y.quality_layers[0].cumulative_bytes <= y.quality_layers[1].cumulative_bytes);
    try std.testing.expect(y.quality_layers[1].cumulative_bytes <= y.quality_layers[2].cumulative_bytes);
    try std.testing.expectEqual(y.coding_passes, y.quality_layers[2].cumulative_passes);
    try std.testing.expectEqual(y.ebcot_segments.mq_bytes, y.quality_layers[2].cumulative_bytes);

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

test "RPCL precinct rectangles clip edge precincts and test block overlap" {
    const precincts = [_]packet_plan.Precinct{
        .{ .width = 4, .height = 4 },
        .{ .width = 4, .height = 4 },
        .{ .width = 8, .height = 8 },
    };

    const plan = try packet_plan.rpclSingleTile(17, 9, 2, 3, 2, &precincts);
    try std.testing.expectEqual(
        packet_plan.Rect{ .x = 0, .y = 0, .width = 4, .height = 3 },
        try packet_plan.precinctRect(plan, 0, 0),
    );
    try std.testing.expectEqual(
        packet_plan.Rect{ .x = 4, .y = 0, .width = 1, .height = 3 },
        try packet_plan.precinctRect(plan, 0, 1),
    );
    try std.testing.expectEqual(
        packet_plan.Rect{ .x = 16, .y = 8, .width = 1, .height = 1 },
        try packet_plan.precinctRect(plan, 2, 5),
    );

    const edge = try packet_plan.precinctRect(plan, 2, 5);
    try std.testing.expect(packet_plan.rectsIntersect(edge, .{ .x = 15, .y = 7, .width = 2, .height = 2 }));
    try std.testing.expect(!packet_plan.rectsIntersect(edge, .{ .x = 14, .y = 7, .width = 2, .height = 1 }));
    try std.testing.expect(!packet_plan.rectsIntersect(edge, .{ .x = 16, .y = 8, .width = 0, .height = 1 }));
    try std.testing.expectError(packet_plan.PacketPlanError.InvalidDimensions, packet_plan.precinctRect(plan, 3, 0));
    try std.testing.expectError(packet_plan.PacketPlanError.InvalidDimensions, packet_plan.precinctRect(plan, 2, 6));
}

test "RPCL packet iterator emits resolution precinct component layer order" {
    const precincts = [_]packet_plan.Precinct{
        .{ .width = 4, .height = 4 },
        .{ .width = 4, .height = 4 },
        .{ .width = 8, .height = 8 },
    };

    const plan = try packet_plan.rpclSingleTile(17, 9, 2, 3, 2, &precincts);
    var iterator = try packet_plan.RpclIterator.init(plan, 3, 2);

    const first = iterator.next().?;
    try std.testing.expectEqual(packet_plan.Packet{
        .sequence = 0,
        .resolution = 0,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 0,
    }, first);

    const second = iterator.next().?;
    try std.testing.expectEqual(@as(u64, 1), second.sequence);
    try std.testing.expectEqual(@as(u8, 0), second.resolution);
    try std.testing.expectEqual(@as(u64, 0), second.precinct_index);
    try std.testing.expectEqual(@as(u16, 0), second.component);
    try std.testing.expectEqual(@as(u16, 1), second.layer);

    const third = iterator.next().?;
    try std.testing.expectEqual(@as(u64, 2), third.sequence);
    try std.testing.expectEqual(@as(u16, 1), third.component);
    try std.testing.expectEqual(@as(u16, 0), third.layer);

    try std.testing.expectEqual(packet_plan.Packet{
        .sequence = 6,
        .resolution = 0,
        .precinct_x = 1,
        .precinct_y = 0,
        .precinct_index = 1,
        .component = 0,
        .layer = 0,
    }, (try packet_plan.rpclPacketAt(plan, 3, 2, 6)).?);

    try std.testing.expectEqual(packet_plan.Packet{
        .sequence = 12,
        .resolution = 1,
        .precinct_x = 0,
        .precinct_y = 0,
        .precinct_index = 0,
        .component = 0,
        .layer = 0,
    }, (try packet_plan.rpclPacketAt(plan, 3, 2, 12)).?);

    try std.testing.expectEqual(packet_plan.Packet{
        .sequence = 83,
        .resolution = 2,
        .precinct_x = 2,
        .precinct_y = 1,
        .precinct_index = 5,
        .component = 2,
        .layer = 1,
    }, (try packet_plan.rpclPacketAt(plan, 3, 2, 83)).?);
    try std.testing.expectEqual(@as(?packet_plan.Packet, null), try packet_plan.rpclPacketAt(plan, 3, 2, 84));
}

test "RPCL direct packet lookup matches iterator sequence" {
    const precincts = [_]packet_plan.Precinct{
        .{ .width = 4, .height = 4 },
        .{ .width = 4, .height = 4 },
        .{ .width = 8, .height = 8 },
    };

    const plan = try packet_plan.rpclSingleTile(17, 9, 2, 3, 2, &precincts);
    var iterator = try packet_plan.RpclIterator.init(plan, 3, 2);
    while (iterator.next()) |packet| {
        try std.testing.expectEqual(packet, (try packet_plan.rpclPacketAt(plan, 3, 2, packet.sequence)).?);
    }
}

test "RPCL packet iterator rejects inconsistent plan metadata" {
    const precincts = [_]packet_plan.Precinct{
        .{ .width = 4, .height = 4 },
        .{ .width = 8, .height = 8 },
    };
    const valid = try packet_plan.rpclSingleTile(8, 8, 1, 3, 2, &precincts);

    var zero_grid = valid;
    zero_grid.resolutions[0].precincts_x = 0;
    try std.testing.expectError(
        packet_plan.PacketPlanError.InvalidDimensions,
        packet_plan.RpclIterator.init(zero_grid, 3, 2),
    );

    var bad_precinct_count = valid;
    bad_precinct_count.resolutions[0].precincts += 1;
    try std.testing.expectError(
        packet_plan.PacketPlanError.InvalidDimensions,
        packet_plan.RpclIterator.init(bad_precinct_count, 3, 2),
    );

    var bad_packet_count = valid;
    bad_packet_count.resolutions[0].packets += 1;
    bad_packet_count.packets += 1;
    try std.testing.expectError(
        packet_plan.PacketPlanError.InvalidDimensions,
        packet_plan.RpclIterator.init(bad_packet_count, 3, 2),
    );
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
        .emit_temporary_payload_sidecar = true,
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
    const sop_count = try countTilePartPrefixMarker(bytes, codestream.markerValue("sop"));
    const eph_count = try countTilePartPrefixMarker(bytes, codestream.markerValue("eph"));
    try std.testing.expectEqual(@as(usize, 12), sop_count);
    try std.testing.expectEqual(@as(usize, 12), eph_count);
    try std.testing.expectEqual(
        try sumTilePartPayloadBytes(bytes),
        try sumTilePartPltLengths(bytes) + sop_count * 6 + eph_count * 2,
    );
}

test "strict metadata rejects resolution tile-part packet-count mismatch" {
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
        .block_width = 8,
        .block_height = 8,
        .tile_part_divisions = 'R',
    });
    defer allocator.free(bytes);

    const corrupted = try insertZeroLengthPacketIntoFirstPltForTest(allocator, bytes);
    defer allocator.free(corrupted);

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
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
        .emit_temporary_payload_sidecar = true,
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

test "temporary payload rejects BP8 shadow packet count mismatch" {
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
        .block_width = 4,
        .block_height = 4,
        .tile_part_divisions = 'R',
        .layers = 2,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    const payload = try extractTemporaryPayloadForTest(allocator, bytes);
    defer allocator.free(payload);

    const shadow_count = try bp8ShadowPacketCountOffsetForTest(payload);
    payload[shadow_count + 7] ^= 0x01;
    const wrapped = try wrapTemporaryPayloadForTest(allocator, payload);
    defer allocator.free(wrapped);

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(wrapped),
    );
}

test "temporary payload rejects BP8 metadata that diverges from ISO markers" {
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
        .block_width = 4,
        .block_height = 4,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    const corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);
    try xorTemporaryPayloadCommentByteForTest(corrupted, "ZJ2K-CBLK-BP8".len + 3, 0x01);

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload rejects BP8 block layout that diverges from ISO layout" {
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
        .block_width = 4,
        .block_height = 4,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    const payload = try extractTemporaryPayloadCommentForTest(allocator, bytes) orelse return error.MissingPayload;
    defer allocator.free(payload);

    const corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);
    const first_block_band = try bp8FirstBlockBandOffsetForTest(payload);
    try xorTemporaryPayloadCommentByteForTest(corrupted, first_block_band + 1, 0x01);

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload rejects BP8 band metadata that diverges from ISO subbands" {
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
        .block_width = 4,
        .block_height = 4,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    const payload = try extractTemporaryPayloadCommentForTest(allocator, bytes) orelse return error.MissingPayload;
    defer allocator.free(payload);

    const corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);
    const first_band_kind = try bp8FirstBandKindOffsetForTest(payload);
    try xorTemporaryPayloadCommentByteForTest(corrupted, first_band_kind, 0x01);

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload rejects SOD packet bytes that diverge from BP8 shadow stream" {
    const allocator = std.testing.allocator;
    const width = 16;
    const height = 16;
    const samples = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(samples);
    for (0..width * height) |i| {
        samples[i * 3 + 0] = @as(u16, @intCast((i * 5) % 251));
        samples[i * 3 + 1] = @as(u16, @intCast((i * 11) % 251));
        samples[i * 3 + 2] = @as(u16, @intCast((i * 17) % 251));
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
        .block_width = 8,
        .block_height = 8,
        .tile_part_divisions = 'R',
        .layers = 2,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    var corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);

    var payload_offset = try firstSodPayloadOffsetForTest(corrupted);
    if (readU16BeTest(corrupted, payload_offset) == codestream.markerValue("sop")) {
        payload_offset += 6;
    }
    if (payload_offset >= corrupted.len) return error.Truncated;
    corrupted[payload_offset] ^= 0x01;

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload rejects corrupt T2 packet header mirrored in BP8 shadow stream" {
    const allocator = std.testing.allocator;
    const width = 16;
    const height = 16;
    const samples = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(samples);
    for (0..width * height) |i| {
        samples[i * 3 + 0] = @as(u16, @intCast((i * 13) % 251));
        samples[i * 3 + 1] = @as(u16, @intCast((i * 19) % 251));
        samples[i * 3 + 2] = @as(u16, @intCast((i * 23) % 251));
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
        .block_width = 8,
        .block_height = 8,
        .tile_part_divisions = 'R',
        .layers = 2,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    const payload = try extractTemporaryPayloadForTest(allocator, bytes);
    defer allocator.free(payload);
    const shadow_packet_byte = try bp8FirstShadowPacketByteOffsetForTest(payload);

    var corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);

    var sod_packet_byte = try firstSodPayloadOffsetForTest(corrupted);
    if (readU16BeTest(corrupted, sod_packet_byte) == codestream.markerValue("sop")) {
        sod_packet_byte += 6;
    }
    corrupted[sod_packet_byte] ^= 0x40;
    try xorTemporaryPayloadCommentByteForTest(corrupted, shadow_packet_byte, 0x40);

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload rejects PLT packet length mismatch" {
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
        .block_width = 8,
        .block_height = 8,
        .tile_part_divisions = 'R',
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    var corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);

    const plt = findMarker(corrupted, codestream.markerValue("plt")) orelse return error.MissingMarker;
    const segment_length = readU16BeTest(corrupted, plt + 2);
    corrupted[plt + 2 + segment_length - 1] ^= 0x01;

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload rejects PLT segment index mismatch" {
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
        .block_width = 8,
        .block_height = 8,
        .tile_part_divisions = 'R',
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    var corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);

    const plt = findMarker(corrupted, codestream.markerValue("plt")) orelse return error.MissingMarker;
    const segment_length = readU16BeTest(corrupted, plt + 2);
    if (segment_length < 3) return error.InvalidPlt;
    corrupted[plt + 4] = 1;

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload rejects TLM tile-part length mismatch" {
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
        .block_width = 8,
        .block_height = 8,
        .tile_part_divisions = 'R',
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    var corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);

    const tlm = findMarker(corrupted, codestream.markerValue("tlm")) orelse return error.MissingMarker;
    const segment_length = readU16BeTest(corrupted, tlm + 2);
    if (segment_length < 9) return error.InvalidTlm;
    corrupted[tlm + 10] ^= 0x01;

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload rejects SOT tile-part sequence mismatch" {
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
        .block_width = 8,
        .block_height = 8,
        .tile_part_divisions = 'R',
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    var corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);

    const sot = findMarker(corrupted, codestream.markerValue("sot")) orelse return error.MissingSot;
    corrupted[sot + 10] = 1;

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload rejects inconsistent SOT tile-part count" {
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
        .block_width = 8,
        .block_height = 8,
        .tile_part_divisions = 'R',
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    var corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);

    const sot = findMarker(corrupted, codestream.markerValue("sot")) orelse return error.MissingSot;
    corrupted[sot + 11] = 1;

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload rejects bad SOP sequence outside packet bytes" {
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
        .block_width = 8,
        .block_height = 8,
        .tile_part_divisions = 'R',
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    var corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);

    const sop = try firstSodPayloadOffsetForTest(corrupted);
    try std.testing.expectEqual(codestream.markerValue("sop"), readU16BeTest(corrupted, sop));
    corrupted[sop + 5] ^= 0x01;

    try std.testing.expectError(
        codestream.CodestreamError.InvalidCodestream,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "temporary payload strict RPCL decode accepts SOP and EPH disabled" {
    const allocator = std.testing.allocator;
    const width = 16;
    const height = 16;
    const samples = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(samples);
    for (0..width * height) |i| {
        samples[i * 3 + 0] = @as(u16, @intCast((i * 3) % 251));
        samples[i * 3 + 1] = @as(u16, @intCast((i * 7) % 251));
        samples[i * 3 + 2] = @as(u16, @intCast((i * 11) % 251));
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
        .block_width = 8,
        .block_height = 8,
        .tile_part_divisions = 'R',
        .sop = false,
        .eph = false,
        .emit_temporary_payload_sidecar = true,
    });
    defer allocator.free(bytes);

    const stats = try codestream.analyzeLosslessTemporary(bytes);
    try std.testing.expect(stats.sod_packets > 0);
    try std.testing.expect(stats.rpcl_shadow_packets > 0);
    try std.testing.expectEqual(@as(usize, 0), try countTilePartPrefixMarker(bytes, codestream.markerValue("sop")));
    try std.testing.expectEqual(@as(usize, 0), try countTilePartPrefixMarker(bytes, codestream.markerValue("eph")));
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
        .emit_temporary_payload_sidecar = true,
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
        .sop = true,
        .eph = true,
    };
    options.precincts[0] = .{ .width = 256, .height = 256 };
    options.precincts[1] = .{ .width = 256, .height = 256 };
    options.precincts[2] = .{ .width = 128, .height = 128 };
    options.precinct_count = 3;

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, options);
    defer allocator.free(bytes);
    try std.testing.expect(!codestream.hasMarker(bytes, codestream.markerValue("com")));

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
    try std.testing.expectEqual(stats.packet_count, stats.sod_packets);
    try std.testing.expect(stats.sod_packet_bytes > 0);
    try std.testing.expectEqual(@as(u64, 0), stats.rpcl_shadow_packets);
    try std.testing.expectEqual(stats.packet_count, stats.t2_audited_packets);
    try std.testing.expectEqual(stats.packet_count, stats.t2_present_packets + stats.t2_absent_packets);
    try std.testing.expect(stats.t2_present_packets > 0);
    try std.testing.expectEqual(stats.t2_audited_packets, stats.t2_header_decoded_packets);
    try std.testing.expectEqual(stats.sod_packet_bytes, stats.t2_header_bytes + stats.t2_payload_bytes);
    try std.testing.expect(stats.t2_header_bytes > 0);
    try std.testing.expect(stats.t2_payload_bytes > 0);
    try std.testing.expect(stats.t2_included_blocks > 0);
    try std.testing.expect(stats.t2_assembled_blocks > 0);
    try std.testing.expectEqual(stats.t2_payload_bytes, stats.t2_assembled_bytes);
    try std.testing.expect(stats.t2_assembled_passes > 0);
    try std.testing.expectEqual(stats.t2_assembled_blocks, stats.t2_t1_ready_blocks);
    const audit = try codestream.auditStrictPacketHeaders(allocator, bytes);
    try std.testing.expectEqual(stats.t2_audited_packets, audit.packets);
    try std.testing.expectEqual(stats.t2_present_packets, audit.present_packets);
    try std.testing.expectEqual(stats.t2_absent_packets, audit.absent_packets);
    try std.testing.expectEqual(stats.t2_geometry_empty_packets, audit.geometry_empty_packets);
    try std.testing.expectEqual(stats.t2_header_decoded_packets, audit.header_decoded_packets);
    try std.testing.expectEqual(stats.t2_header_bytes, audit.header_bytes);
    try std.testing.expectEqual(stats.t2_payload_bytes, audit.payload_bytes);
    try std.testing.expectEqual(stats.t2_included_blocks, audit.included_blocks);
    try std.testing.expectEqual(stats.t2_assembled_blocks, audit.assembled_blocks);
    try std.testing.expectEqual(stats.t2_assembled_bytes, audit.assembled_bytes);
    try std.testing.expectEqual(stats.t2_assembled_passes, audit.assembled_passes);
    try std.testing.expectEqual(stats.t2_t1_ready_blocks, audit.t1_ready_blocks);
    var catalog = try codestream.readStrictPacketCatalog(allocator, bytes);
    defer catalog.deinit();
    try std.testing.expectEqual(@as(usize, @intCast(stats.packet_count)), catalog.entries.len);
    try std.testing.expectEqual(@as(usize, @intCast(stats.sod_packet_bytes)), catalog.packet_bytes.len);
    var block_catalog = try codestream.readStrictPacketBlockCatalog(allocator, bytes);
    defer block_catalog.deinit();
    var strict_catalog_blocks: u64 = 0;
    var strict_catalog_bytes: u64 = 0;
    var strict_catalog_passes: u64 = 0;
    for (0..3) |component| {
        try std.testing.expect(block_catalog.components[component].len > 0);
        var component_payload_offset: usize = 0;
        for (block_catalog.components[component], 0..) |block, block_index| {
            try std.testing.expectEqual(component_payload_offset, block.payload_offset);
            try std.testing.expectEqual(@as(usize, @intCast(block.cumulative_bytes)), block.payload_length);
            try std.testing.expectEqual(block.payload_length, block_catalog.blockPayload(component, block_index).len);
            component_payload_offset += block.payload_length;
            if (!block.metadata_ready) {
                try std.testing.expectEqual(@as(u16, 0), block.cumulative_passes);
                try std.testing.expectEqual(@as(usize, 0), block.payload_length);
                continue;
            }
            try std.testing.expect(block.rect.width > 0);
            try std.testing.expect(block.rect.height > 0);
            try std.testing.expect(block.encoded_bitplanes <= block.nominal_bitplanes);
            strict_catalog_blocks += 1;
            strict_catalog_bytes += block.cumulative_bytes;
            strict_catalog_passes += block.cumulative_passes;
        }
        try std.testing.expectEqual(component_payload_offset, block_catalog.payloads[component].len);
    }
    try std.testing.expectEqual(stats.t2_assembled_blocks, strict_catalog_blocks);
    try std.testing.expectEqual(stats.t2_assembled_bytes, strict_catalog_bytes);
    try std.testing.expectEqual(stats.t2_assembled_passes, strict_catalog_passes);

    const strict_plan = packet_plan.Plan{
        .resolution_count = stats.packet_plan_count,
        .resolutions = stats.packet_plan,
        .packets = stats.packet_count,
    };
    var packet_byte_offset: usize = 0;
    for (catalog.entries, 0..) |entry, sequence| {
        try std.testing.expectEqual(@as(u64, @intCast(sequence)), entry.packet.sequence);
        try std.testing.expectEqual((try packet_plan.rpclPacketAt(strict_plan, 3, stats.layers, entry.packet.sequence)).?, entry.packet);
        try std.testing.expectEqual(packet_byte_offset, entry.byte_offset);
        try std.testing.expectEqual(@as(usize, @intCast(entry.byte_length)), catalog.packetBytes(entry).len);
        packet_byte_offset += entry.byte_length;
    }
    try std.testing.expectEqual(catalog.packet_bytes.len, packet_byte_offset);

    var tile_part_packet_start: usize = 0;
    for (stats.tile_part_plan[0..stats.tile_part_plan_count], 0..) |resolution_value, tile_part_index| {
        const resolution_index: usize = resolution_value;
        const packet_count: usize = @intCast(stats.packet_plan[resolution_index].packets);
        for (catalog.entries[tile_part_packet_start..][0..packet_count]) |entry| {
            try std.testing.expectEqual(@as(u8, @intCast(tile_part_index)), entry.tile_part_index);
            try std.testing.expectEqual(resolution_value, entry.packet.resolution);
        }
        tile_part_packet_start += packet_count;
    }
    try std.testing.expectEqual(catalog.entries.len, tile_part_packet_start);
    try std.testing.expectEqual(@as(usize, 6), countMarker(bytes, codestream.markerValue("sot")));
    try std.testing.expectEqual(@as(usize, 6), try countTilePartHeaderMarker(bytes, codestream.markerValue("plt")));
    const sop_count = try countTilePartPrefixMarker(bytes, codestream.markerValue("sop"));
    const eph_count = try countTilePartPrefixMarker(bytes, codestream.markerValue("eph"));
    try std.testing.expectEqual(@as(usize, @intCast(stats.packet_count)), sop_count);
    try std.testing.expectEqual(@as(usize, @intCast(stats.packet_count)), eph_count);
    try std.testing.expectEqual(
        try sumTilePartPayloadBytes(bytes),
        try sumTilePartPltLengths(bytes) + sop_count * 6 + eph_count * 2,
    );

    const cod = findMarker(bytes, codestream.markerValue("cod")) orelse return error.MissingMarker;
    try std.testing.expectEqual(@as(u16, 18), readU16BeTest(bytes, cod + 2));
    try std.testing.expectEqual(@as(u8, 0x07), bytes[cod + 4]);
    try std.testing.expectEqual(@intFromEnum(codestream.ProgressionOrder.rpcl), bytes[cod + 5]);
    try std.testing.expectEqual(@as(u16, 1), readU16BeTest(bytes, cod + 6));
    try std.testing.expectEqual(@as(u8, 1), bytes[cod + 8]);
    try std.testing.expectEqual(@as(u8, 5), bytes[cod + 9]);
    try std.testing.expectEqual(@as(u8, 4), bytes[cod + 10]);
    try std.testing.expectEqual(@as(u8, 4), bytes[cod + 11]);
    try std.testing.expectEqual(@as(u8, 0), bytes[cod + 12]);
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

test "lossless 16-bit codestream writes matching QCD exponent" {
    const allocator = std.testing.allocator;
    const width = 8;
    const height = 8;
    const samples = try allocator.alloc(u16, width * height * 3);
    defer allocator.free(samples);
    for (0..width * height) |i| {
        samples[i * 3 + 0] = @as(u16, @intCast((i * 257) % 65535));
        samples[i * 3 + 1] = @as(u16, @intCast((i * 509) % 65535));
        samples[i * 3 + 2] = @as(u16, @intCast((i * 1021) % 65535));
    }

    const rgb = image.RgbImage{
        .allocator = allocator,
        .width = width,
        .height = height,
        .bit_depth = 16,
        .samples = samples,
    };

    const bytes = try codestream.encodeLosslessWithOptions(allocator, rgb, .{
        .levels = 1,
        .block_width = 4,
        .block_height = 4,
    });
    defer allocator.free(bytes);

    const stats = try codestream.analyzeLosslessTemporary(bytes);
    try std.testing.expectEqual(@as(u8, 16), stats.bit_depth);

    const qcd = findMarker(bytes, codestream.markerValue("qcd")) orelse return error.MissingMarker;
    try std.testing.expectEqual(@as(u8, 0x80), bytes[qcd + 5]);
}

test "strict SIZ marker reader rejects unsupported component layout" {
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
        .block_width = 4,
        .block_height = 4,
    });
    defer allocator.free(bytes);

    const SizCase = struct {
        label: []const u8,
        mutate: *const fn ([]u8, usize) void,
        expected: anyerror,
    };
    const cases = [_]SizCase{
        .{ .label = "multi tile width", .mutate = struct {
            fn mutate(corrupted: []u8, siz: usize) void {
                writeU32BeTest(corrupted, siz + 22, 4);
            }
        }.mutate, .expected = codestream.CodestreamError.UnsupportedPayload },
        .{ .label = "tile origin offset", .mutate = struct {
            fn mutate(corrupted: []u8, siz: usize) void {
                writeU32BeTest(corrupted, siz + 30, 1);
            }
        }.mutate, .expected = codestream.CodestreamError.UnsupportedPayload },
        .{ .label = "unsupported component count", .mutate = struct {
            fn mutate(corrupted: []u8, siz: usize) void {
                writeU16BeTest(corrupted, siz + 38, 4);
            }
        }.mutate, .expected = codestream.CodestreamError.UnsupportedPayload },
        .{ .label = "signed component", .mutate = struct {
            fn mutate(corrupted: []u8, siz: usize) void {
                corrupted[siz + 40] = 0x87;
            }
        }.mutate, .expected = codestream.CodestreamError.UnsupportedPayload },
        .{ .label = "mixed precision component", .mutate = struct {
            fn mutate(corrupted: []u8, siz: usize) void {
                corrupted[siz + 43] = 15;
            }
        }.mutate, .expected = codestream.CodestreamError.UnsupportedPayload },
        .{ .label = "subsampled component", .mutate = struct {
            fn mutate(corrupted: []u8, siz: usize) void {
                corrupted[siz + 41] = 2;
            }
        }.mutate, .expected = codestream.CodestreamError.UnsupportedPayload },
        .{ .label = "trailing SIZ payload", .mutate = struct {
            fn mutate(corrupted: []u8, siz: usize) void {
                writeU16BeTest(corrupted, siz + 2, readU16BeTest(corrupted, siz + 2) + 1);
            }
        }.mutate, .expected = codestream.CodestreamError.InvalidCodestream },
    };

    for (cases) |scenario| {
        errdefer std.debug.print("SIZ corruption case failed: {s}\n", .{scenario.label});
        const corrupted = try allocator.dupe(u8, bytes);
        defer allocator.free(corrupted);
        const siz = findMarker(corrupted, codestream.markerValue("siz")) orelse return error.MissingMarker;
        scenario.mutate(corrupted, siz);
        try std.testing.expectError(scenario.expected, codestream.auditStrictPacketHeaders(allocator, corrupted));
    }
}

test "strict QCD marker reader rejects exponent that diverges from SIZ bit depth" {
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
        .block_width = 4,
        .block_height = 4,
    });
    defer allocator.free(bytes);

    const corrupted = try allocator.dupe(u8, bytes);
    defer allocator.free(corrupted);
    const siz = findMarker(corrupted, codestream.markerValue("siz")) orelse return error.MissingMarker;
    corrupted[siz + 40] = 15;

    try std.testing.expectError(
        codestream.CodestreamError.UnsupportedPayload,
        codestream.analyzeLosslessTemporary(corrupted),
    );
}

test "strict COD marker reader rejects unsupported coding profile bytes" {
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
        .block_width = 4,
        .block_height = 4,
    });
    defer allocator.free(bytes);

    const CodCase = struct {
        label: []const u8,
        offset: usize,
        value: u8,
        expected: anyerror,
    };
    const cases = [_]CodCase{
        .{ .label = "reserved Scod bit", .offset = 4, .value = 0x87, .expected = codestream.CodestreamError.InvalidCodestream },
        .{ .label = "zero layers", .offset = 7, .value = 0, .expected = codestream.CodestreamError.InvalidCodestream },
        .{ .label = "unsupported MCT", .offset = 8, .value = 2, .expected = codestream.CodestreamError.UnsupportedPayload },
        .{ .label = "oversized code-block width exponent", .offset = 10, .value = 9, .expected = codestream.CodestreamError.InvalidCodestream },
        .{ .label = "unsupported code-block style", .offset = 12, .value = 1, .expected = codestream.CodestreamError.UnsupportedPayload },
        .{ .label = "unsupported wavelet transform", .offset = 13, .value = 0, .expected = codestream.CodestreamError.UnsupportedPayload },
    };

    for (cases) |scenario| {
        errdefer std.debug.print("COD corruption case failed: {s}\n", .{scenario.label});
        const corrupted = try allocator.dupe(u8, bytes);
        defer allocator.free(corrupted);
        const cod = findMarker(corrupted, codestream.markerValue("cod")) orelse return error.MissingMarker;
        corrupted[cod + scenario.offset] = scenario.value;
        try std.testing.expectError(scenario.expected, codestream.auditStrictPacketHeaders(allocator, corrupted));
    }

    {
        const corrupted = try allocator.dupe(u8, bytes);
        defer allocator.free(corrupted);
        const cod = findMarker(corrupted, codestream.markerValue("cod")) orelse return error.MissingMarker;
        writeU16BeTest(corrupted, cod + 2, readU16BeTest(corrupted, cod + 2) + 1);
        try std.testing.expectError(codestream.CodestreamError.InvalidCodestream, codestream.auditStrictPacketHeaders(allocator, corrupted));
    }
}

test "strict QCD marker reader rejects unsupported quantization profile bytes" {
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
        .block_width = 4,
        .block_height = 4,
    });
    defer allocator.free(bytes);

    const QcdCase = struct {
        label: []const u8,
        offset: usize,
        value: u8,
        expected: anyerror,
    };
    const cases = [_]QcdCase{
        .{ .label = "unsupported scalar quantization", .offset = 4, .value = 0x41, .expected = codestream.CodestreamError.UnsupportedPayload },
        .{ .label = "unsupported guard bits", .offset = 4, .value = 0x20, .expected = codestream.CodestreamError.UnsupportedPayload },
        .{ .label = "unsupported reversible exponent", .offset = 5, .value = 0x41, .expected = codestream.CodestreamError.UnsupportedPayload },
        .{ .label = "invalid quantization style", .offset = 4, .value = 0x5f, .expected = codestream.CodestreamError.InvalidCodestream },
    };

    for (cases) |scenario| {
        errdefer std.debug.print("QCD corruption case failed: {s}\n", .{scenario.label});
        const corrupted = try allocator.dupe(u8, bytes);
        defer allocator.free(corrupted);
        const qcd = findMarker(corrupted, codestream.markerValue("qcd")) orelse return error.MissingMarker;
        corrupted[qcd + scenario.offset] = scenario.value;
        try std.testing.expectError(scenario.expected, codestream.analyzeLosslessTemporary(corrupted));
    }
}

test "unsupported code-block style options fail closed" {
    const allocator = std.testing.allocator;
    const width = 2;
    const height = 2;
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

    const UnsupportedCase = struct {
        label: []const u8,
        options: codestream.LosslessOptions,
    };
    const cases = [_]UnsupportedCase{
        .{ .label = "BYPASS", .options = .{ .bypass = true } },
        .{ .label = "RESET", .options = .{ .reset_context = true } },
        .{ .label = "TERMALL", .options = .{ .terminate_all = true } },
        .{ .label = "CAUSAL", .options = .{ .vertical_causal = true } },
        .{ .label = "ERTERM", .options = .{ .predictable_termination = true } },
        .{ .label = "SEGMARK", .options = .{ .segmentation_symbols = true } },
    };

    for (cases) |scenario| {
        errdefer std.debug.print("unsupported code-block style case failed: {s}\n", .{scenario.label});
        try std.testing.expectError(
            codestream.CodestreamError.UnsupportedPayload,
            codestream.encodeLosslessWithOptions(allocator, rgb, scenario.options),
        );
    }
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

const Jp2BoxPayload = struct {
    start: usize,
    end: usize,
};

fn findJp2BoxPayload(bytes: []const u8, comptime kind: *const [4]u8) !Jp2BoxPayload {
    return findJp2ChildBoxPayload(bytes, .{ .start = 0, .end = bytes.len }, kind);
}

fn findJp2ChildBoxPayload(bytes: []const u8, parent: Jp2BoxPayload, comptime kind: *const [4]u8) !Jp2BoxPayload {
    var cursor = parent.start;
    while (cursor < parent.end) {
        if (parent.end - cursor < 8) return error.MissingJp2Box;
        const length = readU32BeTest(bytes, cursor);
        if (length < 8) return error.MissingJp2Box;
        const end = cursor + @as(usize, @intCast(length));
        if (end > parent.end) return error.MissingJp2Box;
        if (readU32BeTest(bytes, cursor + 4) == fourccTest(kind)) {
            return .{ .start = cursor + 8, .end = end };
        }
        cursor = end;
    }
    return error.MissingJp2Box;
}

fn fourccTest(comptime value: *const [4]u8) u32 {
    return (@as(u32, value[0]) << 24) |
        (@as(u32, value[1]) << 16) |
        (@as(u32, value[2]) << 8) |
        @as(u32, value[3]);
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

fn appendU16BeTest(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value)));
}

fn appendU32BeTest(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    try out.append(allocator, @as(u8, @truncate(value >> 24)));
    try out.append(allocator, @as(u8, @truncate(value >> 16)));
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value)));
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
        var packet_lengths: std.ArrayList(usize) = .empty;
        defer packet_lengths.deinit(std.testing.allocator);
        while (cursor + 1 < tile_part_end and readU16BeTest(bytes, cursor) != sod) {
            const tile_header_marker = readU16BeTest(bytes, cursor);
            cursor += 2;
            if (tile_part_end - cursor < 2) return error.Truncated;
            const header_segment_length = readU16BeTest(bytes, cursor);
            if (header_segment_length < 2 or tile_part_end - cursor < header_segment_length) return error.Truncated;
            if (tile_header_marker == codestream.markerValue("plt")) {
                try appendPltLengthsForTest(std.testing.allocator, &packet_lengths, bytes[cursor + 2 .. cursor + header_segment_length]);
            }
            cursor += header_segment_length;
        }
        if (cursor + 1 >= tile_part_end or readU16BeTest(bytes, cursor) != sod) return error.MissingSod;
        cursor += 2;

        if (packet_lengths.items.len > 0) {
            for (packet_lengths.items) |packet_length| {
                const packet_start = cursor;
                var packet_content_start = packet_start;
                if (tile_part_end - packet_content_start >= 2 and readU16BeTest(bytes, packet_content_start) == sop) {
                    if (tile_part_end - packet_content_start < 6) return error.Truncated;
                    if (marker == sop) count += 1;
                    packet_content_start += 6;
                }
                const packet_search_end = @min(tile_part_end, packet_content_start + packet_length + 2);
                const has_eph = findMarkerInPacketForTest(bytes, packet_content_start, packet_search_end, eph) != null;
                if (has_eph) {
                    if (marker == eph) count += 1;
                }
                cursor = packet_content_start + packet_length + if (has_eph) @as(usize, 2) else 0;
                if (cursor > tile_part_end) return error.Truncated;
            }
            if (cursor != tile_part_end) return error.InvalidCodestream;
        } else {
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
        }

        cursor = tile_part_end;
    }

    return error.MissingEoc;
}

fn firstSodPayloadOffsetForTest(bytes: []const u8) !usize {
    const sot = codestream.markerValue("sot");
    const sod = codestream.markerValue("sod");
    const eoc = codestream.markerValue("eoc");

    var cursor: usize = 2;
    while (cursor + 1 < bytes.len) {
        const marker = readU16BeTest(bytes, cursor);
        cursor += 2;
        if (marker == sot) {
            cursor -= 2;
            break;
        }
        if (marker == sod or marker == eoc) return error.MissingSot;
        if (bytes.len - cursor < 2) return error.Truncated;
        const segment_length = readU16BeTest(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) return error.Truncated;
        cursor += segment_length;
    } else {
        return error.MissingSot;
    }

    if (bytes.len - cursor < 12 or readU16BeTest(bytes, cursor) != sot) return error.MissingSot;
    const tile_part_start = cursor;
    const segment_length = readU16BeTest(bytes, cursor + 2);
    if (segment_length != 10) return error.InvalidSot;
    const psot = readU32BeTest(bytes, cursor + 6);
    const tile_part_end = tile_part_start + psot;
    if (psot == 0 or tile_part_end > bytes.len) return error.InvalidSot;
    cursor += 12;

    while (cursor + 1 < tile_part_end) {
        const marker = readU16BeTest(bytes, cursor);
        cursor += 2;
        if (marker == sod) return cursor;
        if (marker == sot or marker == eoc) return error.MissingSod;
        if (tile_part_end - cursor < 2) return error.Truncated;
        const header_segment_length = readU16BeTest(bytes, cursor);
        if (header_segment_length < 2 or tile_part_end - cursor < header_segment_length) return error.Truncated;
        cursor += header_segment_length;
    }
    return error.MissingSod;
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

fn findMarkerInPacketForTest(bytes: []const u8, start: usize, end: usize, marker: u16) ?usize {
    var cursor = start;
    while (cursor + 1 < end) : (cursor += 1) {
        if (readU16BeTest(bytes, cursor) == marker) return cursor;
    }
    return null;
}

fn hasNonTrailingEphPacketForTest(bytes: []const u8) !bool {
    const sot = codestream.markerValue("sot");
    const sod = codestream.markerValue("sod");
    const eoc = codestream.markerValue("eoc");
    const eph = codestream.markerValue("eph");

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
        if (marker_value == eoc) return false;
        if (marker_value != sot) return error.MissingSot;
        if (bytes.len - cursor < 14) return error.Truncated;

        const tile_part_start = cursor;
        const segment_length = readU16BeTest(bytes, cursor + 2);
        if (segment_length != 10) return error.InvalidSot;
        const psot = readU32BeTest(bytes, cursor + 6);
        const tile_part_end = tile_part_start + psot;
        if (psot == 0 or tile_part_end > bytes.len) return error.InvalidSot;

        cursor += 12;
        var packet_lengths: std.ArrayList(usize) = .empty;
        defer packet_lengths.deinit(std.testing.allocator);
        while (cursor + 1 < tile_part_end and readU16BeTest(bytes, cursor) != sod) {
            const tile_header_marker = readU16BeTest(bytes, cursor);
            cursor += 2;
            if (tile_part_end - cursor < 2) return error.Truncated;
            const header_segment_length = readU16BeTest(bytes, cursor);
            if (header_segment_length < 2 or tile_part_end - cursor < header_segment_length) return error.Truncated;
            if (tile_header_marker == codestream.markerValue("plt")) {
                try appendPltLengthsForTest(std.testing.allocator, &packet_lengths, bytes[cursor + 2 .. cursor + header_segment_length]);
            }
            cursor += header_segment_length;
        }
        if (cursor + 1 >= tile_part_end or readU16BeTest(bytes, cursor) != sod) return error.MissingSod;
        cursor += 2;

        for (packet_lengths.items) |packet_length| {
            const packet_start = cursor;
            var packet_content_start = packet_start;
            if (tile_part_end - packet_content_start >= 2 and
                readU16BeTest(bytes, packet_content_start) == codestream.markerValue("sop"))
            {
                if (tile_part_end - packet_content_start < 6) return error.Truncated;
                packet_content_start += 6;
            }
            const packet_search_end = @min(tile_part_end, packet_content_start + packet_length + 2);
            const has_eph = findMarkerInPacketForTest(bytes, packet_content_start, packet_search_end, eph);
            cursor = packet_content_start + packet_length + if (has_eph != null) @as(usize, 2) else 0;
            if (cursor > tile_part_end) return error.Truncated;
            if (has_eph) |offset| {
                if (offset + 2 < cursor) return true;
            }
        }
        if (cursor != tile_part_end) return error.InvalidCodestream;
    }

    return error.MissingEoc;
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

fn extractTemporaryPayloadForTest(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const soc = codestream.markerValue("soc");
    const sot = codestream.markerValue("sot");
    const sod = codestream.markerValue("sod");
    const eoc = codestream.markerValue("eoc");
    const sop = codestream.markerValue("sop");
    const eph = codestream.markerValue("eph");
    const plt = codestream.markerValue("plt");

    if (bytes.len < 2 or readU16BeTest(bytes, 0) != soc) return error.InvalidCodestream;
    if (try extractTemporaryPayloadCommentForTest(allocator, bytes)) |payload| return payload;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 2;
    while (cursor + 1 < bytes.len and readU16BeTest(bytes, cursor) != sot) {
        if (readU16BeTest(bytes, cursor) == eoc) return error.MissingSot;
        cursor += 2;
        if (bytes.len - cursor < 2) return error.Truncated;
        const segment_length = readU16BeTest(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) return error.Truncated;
        cursor += segment_length;
    }

    while (cursor + 1 < bytes.len) {
        const marker_value = readU16BeTest(bytes, cursor);
        if (marker_value == eoc) return out.toOwnedSlice(allocator);
        if (marker_value != sot) return error.MissingSot;
        const tile_part_start = cursor;
        if (bytes.len - cursor < 14) return error.Truncated;
        const segment_length = readU16BeTest(bytes, cursor + 2);
        if (segment_length != 10) return error.InvalidSot;
        const psot = readU32BeTest(bytes, cursor + 6);
        const tile_part_end = tile_part_start + psot;
        if (psot == 0 or tile_part_end > bytes.len) return error.InvalidSot;
        cursor += 12;

        var packet_lengths: std.ArrayList(usize) = .empty;
        defer packet_lengths.deinit(allocator);
        while (cursor + 1 < tile_part_end and readU16BeTest(bytes, cursor) != sod) {
            const tile_header_marker = readU16BeTest(bytes, cursor);
            cursor += 2;
            if (tile_part_end - cursor < 2) return error.Truncated;
            const header_segment_length = readU16BeTest(bytes, cursor);
            if (header_segment_length < 2 or tile_part_end - cursor < header_segment_length) return error.Truncated;
            if (tile_header_marker == plt) {
                try appendPltLengthsForTest(allocator, &packet_lengths, bytes[cursor + 2 .. cursor + header_segment_length]);
            }
            cursor += header_segment_length;
        }

        if (cursor + 1 >= tile_part_end or readU16BeTest(bytes, cursor) != sod) return error.MissingSod;
        cursor += 2;
        if (packet_lengths.items.len == 0) {
            try out.appendSlice(allocator, bytes[cursor..tile_part_end]);
        } else {
            var packet_start = cursor;
            for (packet_lengths.items) |packet_length| {
                const packet_end = packet_start + packet_length;
                if (packet_end > tile_part_end) return error.Truncated;
                var packet_cursor = packet_start;
                if (packet_end - packet_cursor >= 2 and readU16BeTest(bytes, packet_cursor) == sop) {
                    if (packet_end - packet_cursor < 6) return error.Truncated;
                    packet_cursor += 6;
                }
                if (packet_cursor >= packet_end) return error.Truncated;
                packet_cursor += 1;
                _ = try readVariableLengthForTest(bytes, &packet_cursor, packet_end);
                if (packet_end - packet_cursor >= 2 and readU16BeTest(bytes, packet_cursor) == eph) {
                    packet_cursor += 2;
                }
                try out.appendSlice(allocator, bytes[packet_cursor..packet_end]);
                packet_start = packet_end;
            }
            if (packet_start != tile_part_end) return error.InvalidCodestream;
        }
        cursor = tile_part_end;
    }

    return error.MissingEoc;
}

fn extractTemporaryPayloadCommentForTest(allocator: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    const soc = codestream.markerValue("soc");
    const sot = codestream.markerValue("sot");
    const sod = codestream.markerValue("sod");
    const eoc = codestream.markerValue("eoc");
    const com = codestream.markerValue("com");
    const magic = "ZJ2K-TEMP-PAYLOAD1";

    if (bytes.len < 2 or readU16BeTest(bytes, 0) != soc) return error.InvalidCodestream;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var expected_total: ?u32 = null;
    var next_chunk: u32 = 0;
    var saw_payload = false;

    var cursor: usize = 2;
    while (cursor + 1 < bytes.len) {
        const marker_value = readU16BeTest(bytes, cursor);
        cursor += 2;
        if (marker_value == sot) break;
        if (marker_value == sod or marker_value == eoc) return error.InvalidCodestream;
        if (bytes.len - cursor < 2) return error.Truncated;
        const segment_length = readU16BeTest(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) return error.Truncated;
        const segment = bytes[cursor + 2 .. cursor + segment_length];
        if (marker_value == com and segment.len >= 2 + magic.len + 8 and readU16BeTest(segment, 0) == 0) {
            const comment = segment[2..];
            if (std.mem.eql(u8, comment[0..magic.len], magic)) {
                const chunk_index = readU32BeTest(comment, magic.len);
                const chunk_count = readU32BeTest(comment, magic.len + 4);
                if (chunk_count == 0) return error.InvalidCodestream;
                if (expected_total) |total| {
                    if (chunk_count != total) return error.InvalidCodestream;
                } else {
                    expected_total = chunk_count;
                }
                if (chunk_index != next_chunk or chunk_index >= chunk_count) return error.InvalidCodestream;
                next_chunk += 1;
                saw_payload = true;
                try out.appendSlice(allocator, comment[magic.len + 8 ..]);
            }
        }
        cursor += segment_length;
    }

    if (!saw_payload) return null;
    if (expected_total == null or next_chunk != expected_total.?) return error.InvalidCodestream;
    return try out.toOwnedSlice(allocator);
}

fn xorTemporaryPayloadCommentByteForTest(bytes: []u8, payload_offset: usize, mask: u8) !void {
    const soc = codestream.markerValue("soc");
    const sot = codestream.markerValue("sot");
    const sod = codestream.markerValue("sod");
    const eoc = codestream.markerValue("eoc");
    const com = codestream.markerValue("com");
    const magic = "ZJ2K-TEMP-PAYLOAD1";

    if (bytes.len < 2 or readU16BeTest(bytes, 0) != soc) return error.InvalidCodestream;
    var consumed_payload: usize = 0;
    var cursor: usize = 2;
    while (cursor + 1 < bytes.len) {
        const marker_value = readU16BeTest(bytes, cursor);
        cursor += 2;
        if (marker_value == sot) break;
        if (marker_value == sod or marker_value == eoc) return error.InvalidCodestream;
        if (bytes.len - cursor < 2) return error.Truncated;
        const segment_length = readU16BeTest(bytes, cursor);
        if (segment_length < 2 or bytes.len - cursor < segment_length) return error.Truncated;
        const segment_start = cursor + 2;
        const segment = bytes[segment_start .. cursor + segment_length];
        if (marker_value == com and segment.len >= 2 + magic.len + 8 and readU16BeTest(segment, 0) == 0) {
            const comment = segment[2..];
            if (std.mem.eql(u8, comment[0..magic.len], magic)) {
                const chunk_payload_start = segment_start + 2 + magic.len + 8;
                const chunk_payload_len = segment.len - (2 + magic.len + 8);
                if (payload_offset < consumed_payload + chunk_payload_len) {
                    bytes[chunk_payload_start + (payload_offset - consumed_payload)] ^= mask;
                    return;
                }
                consumed_payload += chunk_payload_len;
            }
        }
        cursor += segment_length;
    }
    return error.MissingPayloadByte;
}

fn wrapTemporaryPayloadForTest(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendU16BeTest(allocator, &out, codestream.markerValue("soc"));
    try appendU16BeTest(allocator, &out, codestream.markerValue("sot"));
    try appendU16BeTest(allocator, &out, 10);
    try appendU16BeTest(allocator, &out, 0);
    try appendU32BeTest(allocator, &out, @intCast(14 + payload.len));
    try out.append(allocator, 0);
    try out.append(allocator, 1);
    try appendU16BeTest(allocator, &out, codestream.markerValue("sod"));
    try out.appendSlice(allocator, payload);
    try appendU16BeTest(allocator, &out, codestream.markerValue("eoc"));
    return out.toOwnedSlice(allocator);
}

fn insertZeroLengthPacketIntoFirstPltForTest(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const sot = findMarker(bytes, codestream.markerValue("sot")) orelse return error.MissingSot;
    const tlm = findMarker(bytes, codestream.markerValue("tlm")) orelse return error.MissingMarker;
    const plt = findMarker(bytes, codestream.markerValue("plt")) orelse return error.MissingMarker;
    const plt_length = readU16BeTest(bytes, plt + 2);
    if (plt_length < 3) return error.InvalidPlt;

    const insert_at = plt + 5;
    if (insert_at > bytes.len) return error.Truncated;

    var out = try std.ArrayList(u8).initCapacity(allocator, bytes.len + 1);
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, bytes[0..insert_at]);
    try out.append(allocator, 0);
    try out.appendSlice(allocator, bytes[insert_at..]);

    writeU16BeTest(out.items, plt + 2, plt_length + 1);
    writeU32BeTest(out.items, sot + 6, readU32BeTest(bytes, sot + 6) + 1);
    writeU32BeTest(out.items, tlm + 7, readU32BeTest(bytes, tlm + 7) + 1);
    return out.toOwnedSlice(allocator);
}

fn appendPltLengthsForTest(allocator: std.mem.Allocator, out: *std.ArrayList(usize), segment: []const u8) !void {
    if (segment.len == 0) return error.InvalidPlt;
    var length: usize = 0;
    var pending_length = false;
    for (segment[1..]) |byte| {
        length = (length << 7) | (byte & 0x7f);
        pending_length = true;
        if ((byte & 0x80) == 0) {
            try out.append(allocator, length);
            length = 0;
            pending_length = false;
        }
    }
    if (pending_length) return error.InvalidPlt;
}

fn readVariableLengthForTest(bytes: []const u8, cursor: *usize, end: usize) !u64 {
    var length: u64 = 0;
    var byte_count: usize = 0;
    while (cursor.* < end) {
        if (byte_count == 10) return error.InvalidPacketHeader;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        length = (length << 7) | @as(u64, byte & 0x7f);
        byte_count += 1;
        if ((byte & 0x80) == 0) return length;
    }
    return error.Truncated;
}

fn bp8ShadowPacketCountOffsetForTest(payload: []const u8) !usize {
    var cursor: usize = 0;
    if (payload.len < "ZJ2K-CBLK-BP8".len or !std.mem.eql(u8, payload[0.."ZJ2K-CBLK-BP8".len], "ZJ2K-CBLK-BP8")) {
        return error.InvalidPayload;
    }
    cursor += "ZJ2K-CBLK-BP8".len;
    cursor += 4 + 4 + 1 + 1 + 2 + 2 + 1;
    const tile_part_plan_count = payload[cursor];
    cursor += 1 + tile_part_plan_count;
    const packet_plan_count = payload[cursor];
    cursor += 1 + @as(usize, packet_plan_count) * 40;
    cursor += 2;

    var component: usize = 0;
    while (component < 3) : (component += 1) {
        cursor += 1;
        const band_count = readU16BeTest(payload, cursor);
        cursor += 2;
        const block_count = readU32BeTest(payload, cursor);
        cursor += 4;
        cursor += @as(usize, band_count) * 18;

        var block_index: u32 = 0;
        while (block_index < block_count) : (block_index += 1) {
            cursor += 2 + 16 + 16 + 1 + 4 + 2;
            const layer_count = readU16BeTest(payload, cursor);
            cursor += 2 + @as(usize, layer_count) * 10;
            var stream_index: usize = 0;
            while (stream_index < 3) : (stream_index += 1) {
                cursor += 1 + 4;
                const encoded_len = readU32BeTest(payload, cursor);
                cursor += 4 + encoded_len;
            }
            const pass_count = readU16BeTest(payload, cursor);
            cursor += 2;
            const byte_length = readU64BeTest(payload, cursor);
            cursor += 8 + @as(usize, pass_count) * 30 + @as(usize, @intCast(byte_length));
        }
    }
    if (cursor + 16 > payload.len) return error.InvalidPayload;
    return cursor;
}

fn bp8FirstLegacyEntropyPayloadByteOffsetForTest(payload: []const u8) !usize {
    var cursor: usize = 0;
    if (payload.len < "ZJ2K-CBLK-BP8".len or !std.mem.eql(u8, payload[0.."ZJ2K-CBLK-BP8".len], "ZJ2K-CBLK-BP8")) {
        return error.InvalidPayload;
    }
    cursor += "ZJ2K-CBLK-BP8".len;
    cursor += 4 + 4 + 1 + 1 + 2 + 2 + 1;
    if (cursor >= payload.len) return error.InvalidPayload;
    const tile_part_plan_count = payload[cursor];
    cursor += 1 + tile_part_plan_count;
    if (cursor >= payload.len) return error.InvalidPayload;
    const packet_plan_count = payload[cursor];
    cursor += 1 + @as(usize, packet_plan_count) * 40;
    if (cursor + 2 > payload.len) return error.InvalidPayload;
    cursor += 2;

    var component: usize = 0;
    while (component < 3) : (component += 1) {
        if (cursor + 7 > payload.len) return error.InvalidPayload;
        cursor += 1;
        const band_count = readU16BeTest(payload, cursor);
        cursor += 2;
        const block_count = readU32BeTest(payload, cursor);
        cursor += 4;
        const band_bytes = @as(usize, band_count) * 18;
        if (cursor + band_bytes > payload.len) return error.InvalidPayload;
        cursor += band_bytes;

        var block_index: u32 = 0;
        while (block_index < block_count) : (block_index += 1) {
            if (cursor + 41 > payload.len) return error.InvalidPayload;
            cursor += 2 + 16 + 16 + 1 + 4 + 2;
            const layer_count = readU16BeTest(payload, cursor);
            cursor += 2;
            const layer_bytes = @as(usize, layer_count) * 10;
            if (cursor + layer_bytes > payload.len) return error.InvalidPayload;
            cursor += layer_bytes;

            var stream_index: usize = 0;
            while (stream_index < 3) : (stream_index += 1) {
                if (cursor + 9 > payload.len) return error.InvalidPayload;
                cursor += 1;
                cursor += 4;
                const encoded_len = readU32BeTest(payload, cursor);
                cursor += 4;
                if (cursor + encoded_len > payload.len) return error.InvalidPayload;
                if (encoded_len > 0) return cursor;
                cursor += encoded_len;
            }

            if (cursor + 10 > payload.len) return error.InvalidPayload;
            const pass_count = readU16BeTest(payload, cursor);
            cursor += 2;
            const byte_length = readU64BeTest(payload, cursor);
            cursor += 8;
            const pass_bytes = @as(usize, pass_count) * 30;
            if (cursor + pass_bytes > payload.len) return error.InvalidPayload;
            cursor += pass_bytes;
            const mq_bytes = std.math.cast(usize, byte_length) orelse return error.InvalidPayload;
            if (cursor + mq_bytes > payload.len) return error.InvalidPayload;
            cursor += mq_bytes;
        }
    }
    return error.MissingPayloadByte;
}

fn bp8FirstBlockBandOffsetForTest(payload: []const u8) !usize {
    var cursor: usize = 0;
    if (payload.len < "ZJ2K-CBLK-BP8".len or !std.mem.eql(u8, payload[0.."ZJ2K-CBLK-BP8".len], "ZJ2K-CBLK-BP8")) {
        return error.InvalidPayload;
    }
    cursor += "ZJ2K-CBLK-BP8".len;
    cursor += 4 + 4 + 1 + 1 + 2 + 2 + 1;
    if (cursor >= payload.len) return error.InvalidPayload;
    const tile_part_plan_count = payload[cursor];
    cursor += 1 + tile_part_plan_count;
    if (cursor >= payload.len) return error.InvalidPayload;
    const packet_plan_count = payload[cursor];
    cursor += 1 + @as(usize, packet_plan_count) * 40;
    if (cursor + 2 > payload.len) return error.InvalidPayload;
    cursor += 2;

    if (cursor + 7 > payload.len) return error.InvalidPayload;
    cursor += 1;
    const band_count = readU16BeTest(payload, cursor);
    cursor += 2;
    const block_count = readU32BeTest(payload, cursor);
    cursor += 4;
    if (block_count == 0) return error.InvalidPayload;
    const band_bytes = @as(usize, band_count) * 18;
    if (cursor + band_bytes + 2 > payload.len) return error.InvalidPayload;
    cursor += band_bytes;
    return cursor;
}

fn bp8FirstBandKindOffsetForTest(payload: []const u8) !usize {
    var cursor: usize = 0;
    if (payload.len < "ZJ2K-CBLK-BP8".len or !std.mem.eql(u8, payload[0.."ZJ2K-CBLK-BP8".len], "ZJ2K-CBLK-BP8")) {
        return error.InvalidPayload;
    }
    cursor += "ZJ2K-CBLK-BP8".len;
    cursor += 4 + 4 + 1 + 1 + 2 + 2 + 1;
    if (cursor >= payload.len) return error.InvalidPayload;
    const tile_part_plan_count = payload[cursor];
    cursor += 1 + tile_part_plan_count;
    if (cursor >= payload.len) return error.InvalidPayload;
    const packet_plan_count = payload[cursor];
    cursor += 1 + @as(usize, packet_plan_count) * 40;
    if (cursor + 2 > payload.len) return error.InvalidPayload;
    cursor += 2;

    if (cursor + 7 > payload.len) return error.InvalidPayload;
    cursor += 1;
    const band_count = readU16BeTest(payload, cursor);
    cursor += 2;
    _ = readU32BeTest(payload, cursor);
    cursor += 4;
    if (band_count == 0 or cursor >= payload.len) return error.InvalidPayload;
    return cursor;
}

fn bp8FirstShadowPacketByteOffsetForTest(payload: []const u8) !usize {
    const count_offset = try bp8ShadowPacketCountOffsetForTest(payload);
    const packet_count = readU64BeTest(payload, count_offset);
    if (packet_count == 0) return error.InvalidPayload;
    const first_length_offset = count_offset + 16;
    if (first_length_offset + 4 > payload.len) return error.InvalidPayload;
    const first_length = readU32BeTest(payload, first_length_offset);
    if (first_length == 0 or first_length_offset + 4 + first_length > payload.len) return error.InvalidPayload;
    return first_length_offset + 4;
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

fn countNonZeroI32Test(values: []const i32) u32 {
    var count: u32 = 0;
    for (values) |value| {
        if (value != 0) count += 1;
    }
    return count;
}

fn readU16BeTest(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn writeU16BeTest(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @as(u8, @truncate(value >> 8));
    bytes[offset + 1] = @as(u8, @truncate(value));
}

fn readU32BeTest(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}

fn writeU32BeTest(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @as(u8, @truncate(value >> 24));
    bytes[offset + 1] = @as(u8, @truncate(value >> 16));
    bytes[offset + 2] = @as(u8, @truncate(value >> 8));
    bytes[offset + 3] = @as(u8, @truncate(value));
}

fn readU64BeTest(bytes: []const u8, offset: usize) u64 {
    return (@as(u64, bytes[offset]) << 56) |
        (@as(u64, bytes[offset + 1]) << 48) |
        (@as(u64, bytes[offset + 2]) << 40) |
        (@as(u64, bytes[offset + 3]) << 32) |
        (@as(u64, bytes[offset + 4]) << 24) |
        (@as(u64, bytes[offset + 5]) << 16) |
        (@as(u64, bytes[offset + 6]) << 8) |
        bytes[offset + 7];
}
