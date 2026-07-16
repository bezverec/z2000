const std = @import("std");
const image = @import("../image.zig");
const tiff = @import("../tiff.zig");

const max_file_size: usize = 1024 * 1024 * 1024;
const max_pixels: usize = 268_435_456;
const zigzag = [_]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

pub const JpegError = error{
    InvalidSignature,
    TruncatedMarker,
    InvalidMarker,
    InvalidMarkerOrder,
    UnsupportedFrame,
    UnsupportedPrecision,
    UnsupportedComponents,
    UnsupportedSampling,
    UnsupportedMultipleScans,
    UnsupportedArithmeticCoding,
    UnsupportedProgressive,
    UnsupportedLossless,
    UnsupportedColorSpace,
    UnsupportedMetadata,
    InvalidDimensions,
    InvalidQuantizationTable,
    InvalidHuffmanTable,
    MissingTable,
    InvalidScan,
    InvalidEntropyCode,
    InvalidRestartMarker,
    UnexpectedMarker,
    MissingEndMarker,
};

const QuantTable = struct {
    present: bool = false,
    values: [64]u16 = [_]u16{0} ** 64,
};

const HuffmanTable = struct {
    present: bool = false,
    counts: [16]u8 = [_]u8{0} ** 16,
    symbols: [256]u8 = [_]u8{0} ** 256,
    symbol_count: usize = 0,

    fn decode(self: HuffmanTable, reader: *EntropyReader) !u8 {
        if (!self.present) return JpegError.MissingTable;
        var code: u32 = 0;
        var first_code: u32 = 0;
        var symbol_offset: usize = 0;
        for (self.counts, 0..) |count, depth_index| {
            code = (code << 1) | try reader.readBit();
            const count_u32: u32 = count;
            if (code >= first_code and code - first_code < count_u32) {
                return self.symbols[symbol_offset + @as(usize, @intCast(code - first_code))];
            }
            symbol_offset += count;
            first_code = (first_code + count_u32) << 1;
            _ = depth_index;
        }
        return JpegError.InvalidEntropyCode;
    }
};

const Component = struct {
    id: u8,
    h: u8,
    v: u8,
    quant_id: u8,
    dc_table: u8 = 0,
    ac_table: u8 = 0,
    dc_predictor: i32 = 0,
    plane: ?[]u8 = null,
    plane_width: usize = 0,
    plane_height: usize = 0,
};

const Frame = struct {
    width: usize,
    height: usize,
    components: [3]Component,
    component_count: usize,
    max_h: u8,
    max_v: u8,
};

const Decoder = struct {
    allocator: std.mem.Allocator,
    quant: [4]QuantTable = [_]QuantTable{.{}} ** 4,
    dc_huffman: [4]HuffmanTable = [_]HuffmanTable{.{}} ** 4,
    ac_huffman: [4]HuffmanTable = [_]HuffmanTable{.{}} ** 4,
    frame: ?Frame = null,
    restart_interval: usize = 0,
    saw_jfif: bool = false,
    adobe_transform: ?u8 = null,

    fn deinit(self: *Decoder) void {
        if (self.frame) |*frame| {
            for (frame.components[0..frame.component_count]) |*component| {
                if (component.plane) |plane| self.allocator.free(plane);
                component.plane = null;
            }
        }
    }
};

const EntropyReader = struct {
    bytes: []const u8,
    pos: usize,
    bit_buffer: u8 = 0,
    bits_left: u4 = 0,

    fn readBit(self: *EntropyReader) !u1 {
        if (self.bits_left == 0) {
            self.bit_buffer = try self.readByte();
            self.bits_left = 8;
        }
        self.bits_left -= 1;
        return @truncate(self.bit_buffer >> @as(u3, @intCast(self.bits_left)));
    }

    fn readBits(self: *EntropyReader, count: u4) !u16 {
        var value: u16 = 0;
        for (0..count) |_| value = (value << 1) | try self.readBit();
        return value;
    }

    fn readByte(self: *EntropyReader) !u8 {
        if (self.pos >= self.bytes.len) return JpegError.TruncatedMarker;
        const value = self.bytes[self.pos];
        self.pos += 1;
        if (value != 0xff) return value;
        if (self.pos >= self.bytes.len) return JpegError.TruncatedMarker;
        var marker = self.bytes[self.pos];
        while (marker == 0xff) {
            self.pos += 1;
            if (self.pos >= self.bytes.len) return JpegError.TruncatedMarker;
            marker = self.bytes[self.pos];
        }
        if (marker == 0x00) {
            self.pos += 1;
            return 0xff;
        }
        return JpegError.UnexpectedMarker;
    }

    fn byteAlign(self: *EntropyReader) void {
        self.bits_left = 0;
    }

    fn consumeRestart(self: *EntropyReader, expected: u8) !void {
        self.byteAlign();
        if (self.pos >= self.bytes.len or self.bytes[self.pos] != 0xff) return JpegError.InvalidRestartMarker;
        while (self.pos < self.bytes.len and self.bytes[self.pos] == 0xff) self.pos += 1;
        if (self.pos >= self.bytes.len or self.bytes[self.pos] != 0xd0 + expected) {
            return JpegError.InvalidRestartMarker;
        }
        self.pos += 1;
    }
};

pub fn read(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !tiff.DecodedImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_size));
    defer allocator.free(bytes);
    return parse(allocator, bytes);
}

pub fn readPreservingMetadata(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
) !tiff.DecodedImage {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_size));
    defer allocator.free(bytes);
    return parsePreservingMetadata(allocator, bytes);
}

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !tiff.DecodedImage {
    return parseImpl(allocator, bytes, false);
}

pub fn parsePreservingMetadata(allocator: std.mem.Allocator, bytes: []const u8) !tiff.DecodedImage {
    return parseImpl(allocator, bytes, true);
}

fn parseImpl(allocator: std.mem.Allocator, bytes: []const u8, preserve_metadata: bool) !tiff.DecodedImage {
    if (bytes.len < 4 or bytes[0] != 0xff or bytes[1] != 0xd8) return JpegError.InvalidSignature;
    var decoder = Decoder{ .allocator = allocator };
    defer decoder.deinit();
    var metadata = image.Metadata{};
    errdefer metadata.deinit(allocator);
    var cursor: usize = 2;
    var saw_scan = false;

    while (cursor < bytes.len) {
        const marker = try nextMarker(bytes, &cursor);
        if (saw_scan and marker != 0xd9) {
            if (marker == 0xda) return JpegError.UnsupportedMultipleScans;
            return JpegError.InvalidMarkerOrder;
        }
        switch (marker) {
            0xd9 => {
                if (!saw_scan or cursor != bytes.len) return JpegError.InvalidMarkerOrder;
                var result = try finishImage(allocator, &decoder);
                if (preserve_metadata) {
                    switch (result) {
                        .rgb => |*rgb| rgb.metadata = metadata,
                        .grayscale => |*gray| gray.metadata = metadata,
                        .alpha => unreachable,
                    }
                    metadata = .{};
                }
                return result;
            },
            0xc0 => {
                if (decoder.frame != null or saw_scan) return JpegError.InvalidMarkerOrder;
                try parseFrame(&decoder, try markerPayload(bytes, &cursor));
            },
            0xc1, 0xc5, 0xc8, 0xdc, 0xde, 0xdf => return JpegError.UnsupportedFrame,
            0xc2, 0xc6 => return JpegError.UnsupportedProgressive,
            0xc3, 0xc7 => return JpegError.UnsupportedLossless,
            0xc9, 0xca, 0xcb, 0xcc, 0xcd, 0xce, 0xcf => return JpegError.UnsupportedArithmeticCoding,
            0xdb => try parseQuantization(&decoder, try markerPayload(bytes, &cursor)),
            0xc4 => try parseHuffman(&decoder, try markerPayload(bytes, &cursor)),
            0xdd => try parseRestartInterval(&decoder, try markerPayload(bytes, &cursor)),
            0xda => {
                if (saw_scan) return JpegError.UnsupportedMultipleScans;
                const payload = try markerPayload(bytes, &cursor);
                try decodeScan(&decoder, bytes, payload, &cursor);
                saw_scan = true;
            },
            0xe0 => try parseApp0(&decoder, try markerPayload(bytes, &cursor)),
            0xee => try parseApp14(&decoder, try markerPayload(bytes, &cursor)),
            0xe1 => {
                const payload = try markerPayload(bytes, &cursor);
                if (!preserve_metadata) return JpegError.UnsupportedMetadata;
                try parseApp1Metadata(allocator, payload, &metadata);
            },
            0xed => {
                const payload = try markerPayload(bytes, &cursor);
                if (!preserve_metadata) return JpegError.UnsupportedMetadata;
                try parseApp13Metadata(allocator, payload, &metadata);
            },
            0xe2 => return JpegError.UnsupportedMetadata,
            0xe3...0xec, 0xef, 0xfe => _ = try markerPayload(bytes, &cursor),
            0xd0...0xd7, 0xd8 => return JpegError.InvalidMarkerOrder,
            0x01 => {},
            else => return JpegError.UnsupportedFrame,
        }
    }
    return JpegError.MissingEndMarker;
}

const xmp_app1_id = "http://ns.adobe.com/xap/1.0/\x00";

fn parseApp1Metadata(
    allocator: std.mem.Allocator,
    payload: []const u8,
    metadata: *image.Metadata,
) !void {
    if (std.mem.startsWith(u8, payload, "Exif\x00\x00")) {
        if (metadata.exif != null or payload.len == 6) return JpegError.UnsupportedMetadata;
        metadata.exif = try allocator.dupe(u8, payload[6..]);
        return;
    }
    if (std.mem.startsWith(u8, payload, xmp_app1_id)) {
        if (metadata.xmp != null or payload.len == xmp_app1_id.len) return JpegError.UnsupportedMetadata;
        metadata.xmp = try allocator.dupe(u8, payload[xmp_app1_id.len..]);
        return;
    }
    return JpegError.UnsupportedMetadata;
}

fn parseApp13Metadata(
    allocator: std.mem.Allocator,
    payload: []const u8,
    metadata: *image.Metadata,
) !void {
    const photoshop_id = "Photoshop 3.0\x00";
    if (!std.mem.startsWith(u8, payload, photoshop_id)) return JpegError.UnsupportedMetadata;
    var cursor: usize = photoshop_id.len;
    var saw_iptc = false;
    while (cursor < payload.len) {
        if (payload.len - cursor < 7 or !std.mem.eql(u8, payload[cursor .. cursor + 4], "8BIM")) {
            return JpegError.UnsupportedMetadata;
        }
        const resource_id = readU16(payload, cursor + 4);
        cursor += 6;
        const name_length: usize = payload[cursor];
        cursor += 1;
        if (name_length > payload.len - cursor) return JpegError.TruncatedMarker;
        cursor += name_length;
        if ((1 + name_length) % 2 != 0) {
            if (cursor >= payload.len or payload[cursor] != 0) return JpegError.UnsupportedMetadata;
            cursor += 1;
        }
        if (payload.len - cursor < 4) return JpegError.TruncatedMarker;
        const data_length = (@as(usize, payload[cursor]) << 24) |
            (@as(usize, payload[cursor + 1]) << 16) |
            (@as(usize, payload[cursor + 2]) << 8) |
            payload[cursor + 3];
        cursor += 4;
        if (data_length > payload.len - cursor) return JpegError.TruncatedMarker;
        const data = payload[cursor .. cursor + data_length];
        cursor += data_length;
        if (data_length % 2 != 0) {
            if (cursor >= payload.len or payload[cursor] != 0) return JpegError.UnsupportedMetadata;
            cursor += 1;
        }
        // The bounded APP13 profile accepts exactly one IPTC-IIM resource and
        // refuses to discard any other Photoshop image resource blocks.
        if (resource_id != 0x0404 or saw_iptc or metadata.iptc != null or data.len == 0) {
            return JpegError.UnsupportedMetadata;
        }
        metadata.iptc = try allocator.dupe(u8, data);
        saw_iptc = true;
    }
    if (!saw_iptc) return JpegError.UnsupportedMetadata;
}

fn nextMarker(bytes: []const u8, cursor: *usize) !u8 {
    if (cursor.* >= bytes.len or bytes[cursor.*] != 0xff) return JpegError.InvalidMarker;
    while (cursor.* < bytes.len and bytes[cursor.*] == 0xff) cursor.* += 1;
    if (cursor.* >= bytes.len) return JpegError.TruncatedMarker;
    const marker = bytes[cursor.*];
    cursor.* += 1;
    if (marker == 0x00 or marker == 0xff) return JpegError.InvalidMarker;
    return marker;
}

fn markerPayload(bytes: []const u8, cursor: *usize) ![]const u8 {
    if (bytes.len - cursor.* < 2) return JpegError.TruncatedMarker;
    const length = readU16(bytes, cursor.*);
    if (length < 2) return JpegError.InvalidMarker;
    const start = cursor.* + 2;
    const end = std.math.add(usize, cursor.*, length) catch return JpegError.TruncatedMarker;
    if (end > bytes.len) return JpegError.TruncatedMarker;
    cursor.* = end;
    return bytes[start..end];
}

fn parseFrame(decoder: *Decoder, payload: []const u8) !void {
    if (payload.len < 6) return JpegError.TruncatedMarker;
    if (payload[0] != 8) return JpegError.UnsupportedPrecision;
    const height: usize = readU16(payload, 1);
    const width: usize = readU16(payload, 3);
    if (width == 0 or height == 0) return JpegError.InvalidDimensions;
    const pixels = std.math.mul(usize, width, height) catch return JpegError.InvalidDimensions;
    if (pixels > max_pixels) return JpegError.InvalidDimensions;
    const component_count: usize = payload[5];
    if (component_count != 1 and component_count != 3) return JpegError.UnsupportedComponents;
    if (payload.len != 6 + component_count * 3) return JpegError.InvalidMarker;

    var components: [3]Component = undefined;
    var max_h: u8 = 0;
    var max_v: u8 = 0;
    for (0..component_count) |index| {
        const offset = 6 + index * 3;
        const sampling = payload[offset + 1];
        const h = sampling >> 4;
        const v = sampling & 0x0f;
        const quant_id = payload[offset + 2];
        if (h == 0 or v == 0 or h > 2 or v > 2 or quant_id > 3) return JpegError.UnsupportedSampling;
        for (components[0..index]) |existing| {
            if (existing.id == payload[offset]) return JpegError.InvalidMarker;
        }
        components[index] = .{ .id = payload[offset], .h = h, .v = v, .quant_id = quant_id };
        max_h = @max(max_h, h);
        max_v = @max(max_v, v);
    }
    if (component_count == 1 and (components[0].h != 1 or components[0].v != 1)) {
        return JpegError.UnsupportedSampling;
    }
    if (component_count == 3) {
        if (components[0].h != max_h or components[0].v != max_v or
            components[1].h != 1 or components[1].v != 1 or
            components[2].h != 1 or components[2].v != 1)
        {
            return JpegError.UnsupportedSampling;
        }
    }
    decoder.frame = .{
        .width = width,
        .height = height,
        .components = components,
        .component_count = component_count,
        .max_h = max_h,
        .max_v = max_v,
    };
}

fn parseQuantization(decoder: *Decoder, payload: []const u8) !void {
    var cursor: usize = 0;
    while (cursor < payload.len) {
        const spec = payload[cursor];
        cursor += 1;
        const precision = spec >> 4;
        const table_id = spec & 0x0f;
        if (precision != 0 or table_id > 3 or payload.len - cursor < 64) {
            return JpegError.InvalidQuantizationTable;
        }
        var table = QuantTable{ .present = true };
        for (0..64) |index| {
            const value = payload[cursor + index];
            if (value == 0) return JpegError.InvalidQuantizationTable;
            table.values[zigzag[index]] = value;
        }
        decoder.quant[table_id] = table;
        cursor += 64;
    }
}

fn parseHuffman(decoder: *Decoder, payload: []const u8) !void {
    var cursor: usize = 0;
    while (cursor < payload.len) {
        if (payload.len - cursor < 17) return JpegError.InvalidHuffmanTable;
        const spec = payload[cursor];
        cursor += 1;
        const class = spec >> 4;
        const table_id = spec & 0x0f;
        if (class > 1 or table_id > 3) return JpegError.InvalidHuffmanTable;
        var table = HuffmanTable{ .present = true };
        var total: usize = 0;
        for (0..16) |index| {
            table.counts[index] = payload[cursor + index];
            total += table.counts[index];
        }
        cursor += 16;
        if (total == 0 or total > 256 or payload.len - cursor < total) return JpegError.InvalidHuffmanTable;
        if (!validCanonicalCounts(table.counts)) return JpegError.InvalidHuffmanTable;
        @memcpy(table.symbols[0..total], payload[cursor .. cursor + total]);
        table.symbol_count = total;
        if (class == 0) {
            for (table.symbols[0..total]) |symbol| if (symbol > 11) return JpegError.InvalidHuffmanTable;
            decoder.dc_huffman[table_id] = table;
        } else {
            for (table.symbols[0..total]) |symbol| {
                const size = symbol & 0x0f;
                if (size > 10 or (size == 0 and symbol != 0x00 and symbol != 0xf0)) {
                    return JpegError.InvalidHuffmanTable;
                }
            }
            decoder.ac_huffman[table_id] = table;
        }
        cursor += total;
    }
}

fn validCanonicalCounts(counts: [16]u8) bool {
    var available: i32 = 1;
    for (counts) |count| {
        available = available * 2 - count;
        if (available < 0) return false;
    }
    return true;
}

fn parseRestartInterval(decoder: *Decoder, payload: []const u8) !void {
    if (payload.len != 2) return JpegError.InvalidMarker;
    decoder.restart_interval = readU16(payload, 0);
}

fn parseApp0(decoder: *Decoder, payload: []const u8) !void {
    if (payload.len >= 5 and std.mem.eql(u8, payload[0..5], "JFIF\x00")) {
        if (payload.len < 14 or decoder.saw_jfif) return JpegError.InvalidMarker;
        if (payload[7] > 2 or readU16(payload, 8) == 0 or readU16(payload, 10) == 0) {
            return JpegError.InvalidMarker;
        }
        const thumbnail_bytes = @as(usize, payload[12]) * payload[13] * 3;
        if (payload.len != 14 + thumbnail_bytes) return JpegError.InvalidMarker;
        decoder.saw_jfif = true;
    }
}

fn parseApp14(decoder: *Decoder, payload: []const u8) !void {
    if (payload.len >= 5 and std.mem.eql(u8, payload[0..5], "Adobe")) {
        if (payload.len != 12 or decoder.adobe_transform != null) return JpegError.InvalidMarker;
        decoder.adobe_transform = payload[11];
    }
}

fn decodeScan(decoder: *Decoder, bytes: []const u8, payload: []const u8, cursor: *usize) !void {
    var frame = &(decoder.frame orelse return JpegError.InvalidMarkerOrder);
    if (payload.len < 4) return JpegError.InvalidScan;
    const scan_components: usize = payload[0];
    if (scan_components != frame.component_count or payload.len != 1 + scan_components * 2 + 3) {
        return JpegError.UnsupportedMultipleScans;
    }
    var seen = [_]bool{false} ** 3;
    for (0..scan_components) |scan_index| {
        const id = payload[1 + scan_index * 2];
        const table_spec = payload[2 + scan_index * 2];
        const component_index = componentIndex(frame.*, id) orelse return JpegError.InvalidScan;
        if (seen[component_index]) return JpegError.InvalidScan;
        seen[component_index] = true;
        const dc_id = table_spec >> 4;
        const ac_id = table_spec & 0x0f;
        if (dc_id > 3 or ac_id > 3) return JpegError.InvalidScan;
        frame.components[component_index].dc_table = dc_id;
        frame.components[component_index].ac_table = ac_id;
    }
    const tail = 1 + scan_components * 2;
    if (payload[tail] != 0 or payload[tail + 1] != 63 or payload[tail + 2] != 0) {
        return JpegError.UnsupportedFrame;
    }

    const mcu_width = @as(usize, frame.max_h) * 8;
    const mcu_height = @as(usize, frame.max_v) * 8;
    const mcu_columns = ceilDiv(frame.width, mcu_width);
    const mcu_rows = ceilDiv(frame.height, mcu_height);
    for (frame.components[0..frame.component_count]) |*component| {
        const plane_width = try std.math.mul(usize, mcu_columns, @as(usize, component.h) * 8);
        const plane_height = try std.math.mul(usize, mcu_rows, @as(usize, component.v) * 8);
        component.plane = try decoder.allocator.alloc(u8, try std.math.mul(usize, plane_width, plane_height));
        @memset(component.plane.?, 0);
        component.plane_width = plane_width;
        component.plane_height = plane_height;
        if (!decoder.quant[component.quant_id].present or
            !decoder.dc_huffman[component.dc_table].present or
            !decoder.ac_huffman[component.ac_table].present)
        {
            return JpegError.MissingTable;
        }
    }

    var reader = EntropyReader{ .bytes = bytes, .pos = cursor.* };
    var mcu_index: usize = 0;
    var expected_restart: u8 = 0;
    for (0..mcu_rows) |mcu_y| {
        for (0..mcu_columns) |mcu_x| {
            for (frame.components[0..frame.component_count]) |*component| {
                for (0..component.v) |block_y| {
                    for (0..component.h) |block_x| {
                        try decodeBlock(
                            decoder,
                            component,
                            &reader,
                            mcu_x * component.h + block_x,
                            mcu_y * component.v + block_y,
                        );
                    }
                }
            }
            mcu_index += 1;
            if (decoder.restart_interval != 0 and mcu_index < mcu_columns * mcu_rows and
                mcu_index % decoder.restart_interval == 0)
            {
                try reader.consumeRestart(expected_restart);
                expected_restart = (expected_restart + 1) & 7;
                for (frame.components[0..frame.component_count]) |*component| component.dc_predictor = 0;
            }
        }
    }
    reader.byteAlign();
    cursor.* = reader.pos;
}

fn decodeBlock(
    decoder: *Decoder,
    component: *Component,
    reader: *EntropyReader,
    block_x: usize,
    block_y: usize,
) !void {
    var coefficients = [_]i32{0} ** 64;
    const dc_size = try decoder.dc_huffman[component.dc_table].decode(reader);
    const dc_delta = try receiveExtend(reader, dc_size);
    component.dc_predictor = std.math.add(i32, component.dc_predictor, dc_delta) catch
        return JpegError.InvalidEntropyCode;
    coefficients[0] = component.dc_predictor;

    var k: usize = 1;
    while (k < 64) {
        const symbol = try decoder.ac_huffman[component.ac_table].decode(reader);
        if (symbol == 0) break;
        if (symbol == 0xf0) {
            k += 16;
            if (k > 64) return JpegError.InvalidEntropyCode;
            continue;
        }
        const run: usize = symbol >> 4;
        const size: u8 = symbol & 0x0f;
        k += run;
        if (k >= 64 or size == 0) return JpegError.InvalidEntropyCode;
        coefficients[zigzag[k]] = try receiveExtend(reader, size);
        k += 1;
    }

    const quant = decoder.quant[component.quant_id];
    for (&coefficients, quant.values) |*coefficient, value| {
        coefficient.* = std.math.mul(i32, coefficient.*, value) catch return JpegError.InvalidEntropyCode;
    }
    var pixels: [64]u8 = undefined;
    inverseDct(coefficients, &pixels);
    const plane = component.plane.?;
    for (0..8) |y| {
        const target = (block_y * 8 + y) * component.plane_width + block_x * 8;
        @memcpy(plane[target .. target + 8], pixels[y * 8 ..][0..8]);
    }
}

fn receiveExtend(reader: *EntropyReader, size: u8) !i32 {
    if (size == 0) return 0;
    if (size > 11) return JpegError.InvalidEntropyCode;
    const value: i32 = try reader.readBits(@intCast(size));
    const threshold: i32 = @as(i32, 1) << @intCast(size - 1);
    if (value >= threshold) return value;
    return value - ((@as(i32, 1) << @intCast(size)) - 1);
}

const idct_basis: [8][8]f64 = blk: {
    var table: [8][8]f64 = undefined;
    for (0..8) |position| {
        for (0..8) |frequency| {
            const scale = if (frequency == 0) @sqrt(0.5) else 1.0;
            table[position][frequency] = scale * @cos((@as(f64, @floatFromInt(2 * position + 1)) *
                @as(f64, @floatFromInt(frequency)) * std.math.pi) / 16.0);
        }
    }
    break :blk table;
};

fn inverseDct(coefficients: [64]i32, pixels: *[64]u8) void {
    var temp: [64]f64 = undefined;
    for (0..8) |v| {
        for (0..8) |x| {
            var sum: f64 = 0;
            for (0..8) |u| sum += idct_basis[x][u] * @as(f64, @floatFromInt(coefficients[v * 8 + u]));
            temp[v * 8 + x] = sum;
        }
    }
    for (0..8) |y| {
        for (0..8) |x| {
            var sum: f64 = 0;
            for (0..8) |v| sum += idct_basis[y][v] * temp[v * 8 + x];
            const sample = @as(i32, @intFromFloat(@round(sum * 0.25 + 128.0)));
            pixels[y * 8 + x] = @intCast(std.math.clamp(sample, 0, 255));
        }
    }
}

fn finishImage(allocator: std.mem.Allocator, decoder: *Decoder) !tiff.DecodedImage {
    const frame = decoder.frame orelse return JpegError.InvalidMarkerOrder;
    if (frame.component_count == 1) {
        const samples = try allocator.alloc(u16, try std.math.mul(usize, frame.width, frame.height));
        errdefer allocator.free(samples);
        const plane = frame.components[0].plane orelse return JpegError.InvalidScan;
        for (0..frame.height) |y| {
            for (0..frame.width) |x| samples[y * frame.width + x] = plane[y * frame.components[0].plane_width + x];
        }
        return .{ .grayscale = .{
            .allocator = allocator,
            .width = frame.width,
            .height = frame.height,
            .bit_depth = 8,
            .samples = samples,
        } };
    }

    const ids_are_rgb = frame.components[0].id == 'R' and frame.components[1].id == 'G' and
        frame.components[2].id == 'B';
    const ids_are_ycc = frame.components[0].id == 1 and frame.components[1].id == 2 and
        frame.components[2].id == 3;
    const direct_rgb = if (decoder.saw_jfif) blk: {
        if (!ids_are_ycc) return JpegError.UnsupportedColorSpace;
        if (decoder.adobe_transform) |transform| {
            if (transform != 1) return JpegError.UnsupportedColorSpace;
        }
        break :blk false;
    } else if (decoder.adobe_transform) |transform| blk: {
        if (transform == 0 and ids_are_rgb) break :blk true;
        if (transform == 1 and ids_are_ycc) break :blk false;
        return JpegError.UnsupportedColorSpace;
    } else {
        return JpegError.UnsupportedColorSpace;
    };
    const samples = try allocator.alloc(u16, try std.math.mul(usize, try std.math.mul(usize, frame.width, frame.height), 3));
    errdefer allocator.free(samples);
    for (0..frame.height) |y| {
        for (0..frame.width) |x| {
            var source: [3]u8 = undefined;
            for (frame.components[0..3], 0..) |component, index| {
                source[index] = sampledComponent(component, frame.max_h, frame.max_v, x, y);
            }
            const target = (y * frame.width + x) * 3;
            if (direct_rgb) {
                samples[target] = source[0];
                samples[target + 1] = source[1];
                samples[target + 2] = source[2];
            } else {
                const rgb = ycbcrToRgb(source[0], source[1], source[2]);
                samples[target] = rgb[0];
                samples[target + 1] = rgb[1];
                samples[target + 2] = rgb[2];
            }
        }
    }
    return .{ .rgb = .{
        .allocator = allocator,
        .width = frame.width,
        .height = frame.height,
        .bit_depth = 8,
        .samples = samples,
    } };
}

const AxisWeights = struct {
    first: usize,
    second: usize,
    first_weight: u8,
    second_weight: u8,
};

fn sampledComponent(component: Component, max_h: u8, max_v: u8, x: usize, y: usize) u8 {
    const horizontal = axisWeights(x, component.h, max_h, component.plane_width);
    const vertical = axisWeights(y, component.v, max_v, component.plane_height);
    const plane = component.plane.?;
    const a: u32 = plane[vertical.first * component.plane_width + horizontal.first];
    const b: u32 = plane[vertical.first * component.plane_width + horizontal.second];
    const c: u32 = plane[vertical.second * component.plane_width + horizontal.first];
    const d: u32 = plane[vertical.second * component.plane_width + horizontal.second];
    const top = a * horizontal.first_weight + b * horizontal.second_weight;
    const bottom = c * horizontal.first_weight + d * horizontal.second_weight;
    return @intCast((top * vertical.first_weight + bottom * vertical.second_weight + 8) / 16);
}

fn axisWeights(position: usize, sampling: u8, maximum: u8, limit: usize) AxisWeights {
    if (sampling == maximum) {
        return .{ .first = position, .second = position, .first_weight = 4, .second_weight = 0 };
    }
    const current = position / 2;
    if (position & 1 == 0) {
        return .{
            .first = if (current == 0) 0 else current - 1,
            .second = current,
            .first_weight = 1,
            .second_weight = 3,
        };
    }
    return .{
        .first = current,
        .second = @min(current + 1, limit - 1),
        .first_weight = 3,
        .second_weight = 1,
    };
}

fn ycbcrToRgb(y: u8, cb: u8, cr: u8) [3]u8 {
    const yi: i32 = y;
    const cbi: i32 = @as(i32, cb) - 128;
    const cri: i32 = @as(i32, cr) - 128;
    const red = yi + ((91881 * cri + 32768) >> 16);
    const green = yi - ((22554 * cbi + 46802 * cri + 32768) >> 16);
    const blue = yi + ((116130 * cbi + 32768) >> 16);
    return .{
        @intCast(std.math.clamp(red, 0, 255)),
        @intCast(std.math.clamp(green, 0, 255)),
        @intCast(std.math.clamp(blue, 0, 255)),
    };
}

fn componentIndex(frame: Frame, id: u8) ?usize {
    for (frame.components[0..frame.component_count], 0..) |component, index| {
        if (component.id == id) return index;
    }
    return null;
}

fn ceilDiv(value: usize, divisor: usize) usize {
    return value / divisor + @intFromBool(value % divisor != 0);
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

test "JPEG floating IDCT reconstructs a DC-only block" {
    var coefficients = [_]i32{0} ** 64;
    coefficients[0] = 80;
    var pixels: [64]u8 = undefined;
    inverseDct(coefficients, &pixels);
    for (pixels) |sample| try std.testing.expectEqual(@as(u8, 138), sample);
}

test "JPEG YCbCr conversion pins neutral and primary-biased samples" {
    try std.testing.expectEqual([3]u8{ 128, 128, 128 }, ycbcrToRgb(128, 128, 128));
    try std.testing.expectEqual([3]u8{ 254, 73, 80 }, ycbcrToRgb(128, 101, 218));
}
