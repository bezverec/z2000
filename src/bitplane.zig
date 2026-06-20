const std = @import("std");
const simd = @import("simd.zig");
const subband = @import("subband.zig");

pub const BitplaneError = error{
    InvalidBlock,
    TruncatedData,
    TrailingData,
};

const scan_lanes = simd.i32_lanes;
const ScanVector = @Vector(scan_lanes, i32);
const ScanMaskVector = @Vector(scan_lanes, u32);
const scan_lane_masks = makeScanLaneMasks();
const neon_pack_lanes = simd.neon_i32_lanes;
const NeonPackVector = @Vector(neon_pack_lanes, u32);
const neon_pack_masks: NeonPackVector = .{ 0x80, 0x40, 0x20, 0x10 };
const neon_pack_tail_masks: NeonPackVector = .{ 0x08, 0x04, 0x02, 0x01 };
const max_codeblock_area = 4096;

const BlockScan = struct {
    active_rect: subband.Rect,
    non_zero_count: u32,
    max_mag: u32,
};

const PackedBits = struct {
    bits: u32,
    bit_count: u6,
};

pub const EncodedBlock = struct {
    active_rect: subband.Rect,
    bitplanes: u8,
    non_zero_count: u32,
    significance_bytes: []u8,
    refinement_bytes: []u8,
    cleanup_bytes: []u8,
    bytes: []u8,

    pub fn deinit(self: *EncodedBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.significance_bytes);
        allocator.free(self.refinement_bytes);
        allocator.free(self.cleanup_bytes);
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

pub const EncodedBlockPasses = struct {
    active_rect: subband.Rect,
    bitplanes: u8,
    non_zero_count: u32,
    significance_bytes: []u8,
    refinement_bytes: []u8,
    cleanup_bytes: []u8,

    pub fn deinit(self: *EncodedBlockPasses, allocator: std.mem.Allocator) void {
        allocator.free(self.significance_bytes);
        allocator.free(self.refinement_bytes);
        allocator.free(self.cleanup_bytes);
        self.* = undefined;
    }
};

pub const EncodedBlockPassView = struct {
    active_rect: subband.Rect,
    bitplanes: u8,
    non_zero_count: u32,
    significance_bytes: []const u8,
    refinement_bytes: []const u8,
    cleanup_bytes: []const u8,
};

pub const CodingPassKind = enum(u8) {
    significance = 0,
    refinement = 1,
    cleanup = 2,
};

pub const CodingPass = struct {
    kind: CodingPassKind,
    magnitude_bitplane: u8,
};

pub const PacketContribution = struct {
    included: bool,
    zero_bitplanes: u8,
    pass_count: u16,
    byte_length: u64,
};

pub const BlockScratch = struct {
    allocator: std.mem.Allocator,
    significance: BitWriter,
    refinement: BitWriter,
    magnitudes: std.ArrayList(u32) = .empty,

    pub fn init(allocator: std.mem.Allocator) BlockScratch {
        return .{
            .allocator = allocator,
            .significance = BitWriter.init(allocator),
            .refinement = BitWriter.init(allocator),
        };
    }

    pub fn deinit(self: *BlockScratch) void {
        self.significance.deinit();
        self.refinement.deinit();
        self.magnitudes.deinit(self.allocator);
        self.* = undefined;
    }

    fn reset(self: *BlockScratch) void {
        self.significance.reset();
        self.refinement.reset();
        self.magnitudes.clearRetainingCapacity();
    }
};

pub fn isoCodingPassCount(bitplanes: u8, non_zero_count: u32) u16 {
    if (bitplanes == 0 or non_zero_count == 0) return 0;
    return @as(u16, bitplanes) * 3 - 2;
}

pub fn codingPassAt(bitplanes: u8, non_zero_count: u32, pass_index: u16) !CodingPass {
    const pass_count = isoCodingPassCount(bitplanes, non_zero_count);
    if (pass_index >= pass_count) return BitplaneError.InvalidBlock;

    const top_bitplane = bitplanes - 1;
    if (pass_index == 0) {
        return .{ .kind = .cleanup, .magnitude_bitplane = top_bitplane };
    }

    const adjusted = pass_index - 1;
    const lower_bitplane_index: u8 = @intCast(adjusted / 3);
    const phase = adjusted % 3;
    return .{
        .kind = switch (phase) {
            0 => .significance,
            1 => .refinement,
            2 => .cleanup,
            else => unreachable,
        },
        .magnitude_bitplane = top_bitplane - 1 - lower_bitplane_index,
    };
}

pub fn packetContribution(nominal_bitplanes: u8, passes: anytype) !PacketContribution {
    if (passes.bitplanes > nominal_bitplanes) return BitplaneError.InvalidBlock;

    const pass_count = isoCodingPassCount(passes.bitplanes, passes.non_zero_count);
    if (pass_count == 0) {
        return .{
            .included = false,
            .zero_bitplanes = 0,
            .pass_count = 0,
            .byte_length = 0,
        };
    }

    const significance_len: u64 = @intCast(passes.significance_bytes.len);
    const refinement_len: u64 = @intCast(passes.refinement_bytes.len);
    const cleanup_len: u64 = @intCast(passes.cleanup_bytes.len);
    return .{
        .included = true,
        .zero_bitplanes = nominal_bitplanes - passes.bitplanes,
        .pass_count = pass_count,
        .byte_length = significance_len + refinement_len + cleanup_len,
    };
}

pub fn encodeBlockPasses(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !EncodedBlockPasses {
    var scratch = BlockScratch.init(allocator);
    defer scratch.deinit();

    const view = try encodeBlockPassesScratch(&scratch, plane, stride, rect);
    const significance_bytes = try allocator.dupe(u8, view.significance_bytes);
    errdefer allocator.free(significance_bytes);
    const refinement_bytes = try allocator.dupe(u8, view.refinement_bytes);
    errdefer allocator.free(refinement_bytes);
    const cleanup_bytes = try allocator.dupe(u8, view.cleanup_bytes);
    errdefer allocator.free(cleanup_bytes);

    return .{
        .active_rect = view.active_rect,
        .bitplanes = view.bitplanes,
        .non_zero_count = view.non_zero_count,
        .significance_bytes = significance_bytes,
        .refinement_bytes = refinement_bytes,
        .cleanup_bytes = cleanup_bytes,
    };
}

pub fn encodeBlockPassesScratch(
    scratch: *BlockScratch,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !EncodedBlockPassView {
    scratch.reset();

    if (stride == 0 or rect.width == 0 or rect.height == 0) return BitplaneError.InvalidBlock;
    if (rect.y >= plane.len / stride or rect.x >= stride) return BitplaneError.InvalidBlock;
    const last_row = rect.y + rect.height - 1;
    const last_col = rect.x + rect.width - 1;
    if (last_col >= stride or last_row >= plane.len / stride) return BitplaneError.InvalidBlock;

    const scan = scanBlock(plane, stride, rect);

    if (scan.non_zero_count == 0) {
        return .{
            .active_rect = .{ .x = rect.x, .y = rect.y, .width = 0, .height = 0 },
            .bitplanes = 0,
            .non_zero_count = 0,
            .significance_bytes = &.{},
            .refinement_bytes = &.{},
            .cleanup_bytes = &.{},
        };
    }

    const active_rect = scan.active_rect;
    const bitplanes = bitPlaneCount(scan.max_mag);
    var significance = &scratch.significance;
    var refinement = &scratch.refinement;
    const active_area = try std.math.mul(usize, active_rect.width, active_rect.height);
    const significance_bits = try std.math.add(usize, active_area, scan.non_zero_count);
    const refinement_bits = try std.math.mul(usize, scan.non_zero_count, bitplanes);
    try significance.ensureUnusedBits(significance_bits);
    try refinement.ensureUnusedBits(refinement_bits);
    try scratch.magnitudes.ensureUnusedCapacity(scratch.allocator, scan.non_zero_count);

    var y: usize = 0;
    while (y < active_rect.height) : (y += 1) {
        const row = (active_rect.y + y) * stride;
        var x: usize = 0;
        while (x + scan_lanes <= active_rect.width) : (x += scan_lanes) {
            const values = plane[row + active_rect.x + x ..][0..scan_lanes];
            const chunk = scanChunk(values);
            if (chunk.mask == 0) {
                significance.writeZeroBitsAssumeCapacity(scan_lanes);
                continue;
            }

            const chunk_bits = packSignificanceChunk(chunk.mask, chunk.sign_mask);
            significance.writeBitsAssumeCapacity(chunk_bits.bits, chunk_bits.bit_count);

            inline for (0..scan_lanes) |lane| {
                if ((chunk.mask & (@as(u32, 1) << @as(u5, @intCast(lane)))) != 0) {
                    const coeff = values[lane];
                    scratch.magnitudes.appendAssumeCapacity(magnitude(coeff));
                }
            }
        }

        while (x < active_rect.width) : (x += 1) {
            const coeff = plane[row + active_rect.x + x];
            const mag = magnitude(coeff);
            const is_significant = mag != 0;
            if (is_significant) {
                significance.writePresentAndSignAssumeCapacity(coeff < 0);
                scratch.magnitudes.appendAssumeCapacity(mag);
            } else {
                significance.writeBitAssumeCapacity(false);
            }
        }
    }

    const magnitudes = scratch.magnitudes.items;
    var bitplane_index = bitplanes;
    while (bitplane_index > 0) {
        bitplane_index -= 1;
        refinement.writeMagnitudeBitsAssumeCapacity(magnitudes, @intCast(bitplane_index));
    }

    const significance_bytes = try significance.finishView();
    const refinement_bytes = try refinement.finishView();

    return .{
        .active_rect = active_rect,
        .bitplanes = bitplanes,
        .non_zero_count = scan.non_zero_count,
        .significance_bytes = significance_bytes,
        .refinement_bytes = refinement_bytes,
        .cleanup_bytes = &.{},
    };
}

fn scanBlock(plane: []const i32, stride: usize, rect: subband.Rect) BlockScan {
    var active_min_x = rect.width;
    var active_min_y = rect.height;
    var active_max_x: usize = 0;
    var active_max_y: usize = 0;
    var non_zero_count: u32 = 0;
    var max_mag: u32 = 0;

    var y: usize = 0;
    while (y < rect.height) : (y += 1) {
        const row_start = (rect.y + y) * stride + rect.x;
        var x: usize = 0;
        while (x + scan_lanes <= rect.width) : (x += scan_lanes) {
            const chunk = scanChunk(plane[row_start + x ..][0..scan_lanes]);
            max_mag = @max(max_mag, chunk.max_mag);
            if (chunk.mask == 0) continue;

            active_min_y = @min(active_min_y, y);
            active_max_y = @max(active_max_y, y);
            inline for (0..scan_lanes) |lane| {
                if ((chunk.mask & (@as(u32, 1) << @as(u5, @intCast(lane)))) != 0) {
                    const col = x + lane;
                    active_min_x = @min(active_min_x, col);
                    active_max_x = @max(active_max_x, col);
                    non_zero_count += 1;
                }
            }
        }

        while (x < rect.width) : (x += 1) {
            const coeff = plane[row_start + x];
            const mag = magnitude(coeff);
            max_mag = @max(max_mag, mag);
            if (mag != 0) {
                active_min_x = @min(active_min_x, x);
                active_min_y = @min(active_min_y, y);
                active_max_x = @max(active_max_x, x);
                active_max_y = @max(active_max_y, y);
                non_zero_count += 1;
            }
        }
    }

    const active_rect = if (non_zero_count == 0)
        subband.Rect{ .x = rect.x, .y = rect.y, .width = 0, .height = 0 }
    else
        subband.Rect{
            .x = rect.x + active_min_x,
            .y = rect.y + active_min_y,
            .width = active_max_x - active_min_x + 1,
            .height = active_max_y - active_min_y + 1,
        };

    return .{
        .active_rect = active_rect,
        .non_zero_count = non_zero_count,
        .max_mag = max_mag,
    };
}

const ScanChunk = struct {
    mask: u32,
    sign_mask: u32,
    max_mag: u32,
};

fn scanChunk(values: *const [scan_lanes]i32) ScanChunk {
    const coeffs: ScanVector = values.*;
    const zero: ScanVector = @splat(0);
    const abs_values = @select(i32, coeffs < zero, -coeffs, coeffs);
    const max_mag = @as(u32, @intCast(@reduce(.Max, abs_values)));
    const non_zero = coeffs != zero;
    const mask = @reduce(.Or, @select(u32, non_zero, scan_lane_masks, @as(ScanMaskVector, @splat(0))));
    const negative = coeffs < zero;
    const sign_mask = @reduce(.Or, @select(u32, negative, scan_lane_masks, @as(ScanMaskVector, @splat(0))));
    return .{ .mask = mask, .sign_mask = sign_mask, .max_mag = max_mag };
}

fn packSignificanceChunk(mask: u32, sign_mask: u32) PackedBits {
    var bits: u32 = 0;
    var bit_count: u6 = 0;

    inline for (0..scan_lanes) |lane| {
        const lane_bit = @as(u32, 1) << @as(u5, @intCast(lane));
        bits <<= 1;
        bit_count += 1;
        if ((mask & lane_bit) != 0) {
            bits |= 1;
            bits <<= 1;
            bit_count += 1;
            if ((sign_mask & lane_bit) != 0) bits |= 1;
        }
    }

    return .{ .bits = bits, .bit_count = bit_count };
}

fn makeScanLaneMasks() ScanMaskVector {
    var masks: [scan_lanes]u32 = undefined;
    inline for (0..scan_lanes) |lane| {
        masks[lane] = @as(u32, 1) << @as(u5, @intCast(lane));
    }
    return masks;
}

pub fn encodeBlock(
    allocator: std.mem.Allocator,
    plane: []const i32,
    stride: usize,
    rect: subband.Rect,
) !EncodedBlock {
    var passes = try encodeBlockPasses(allocator, plane, stride, rect);
    errdefer passes.deinit(allocator);

    var combined: std.ArrayList(u8) = .empty;
    errdefer combined.deinit(allocator);
    try appendU32Be(allocator, &combined, @as(u32, @intCast(passes.significance_bytes.len)));
    try combined.appendSlice(allocator, passes.significance_bytes);
    try appendU32Be(allocator, &combined, @as(u32, @intCast(passes.refinement_bytes.len)));
    try combined.appendSlice(allocator, passes.refinement_bytes);
    try appendU32Be(allocator, &combined, @as(u32, @intCast(passes.cleanup_bytes.len)));
    try combined.appendSlice(allocator, passes.cleanup_bytes);

    return .{
        .active_rect = passes.active_rect,
        .bitplanes = passes.bitplanes,
        .non_zero_count = passes.non_zero_count,
        .significance_bytes = passes.significance_bytes,
        .refinement_bytes = passes.refinement_bytes,
        .cleanup_bytes = passes.cleanup_bytes,
        .bytes = try combined.toOwnedSlice(allocator),
    };
}

pub fn decodeBlockPasses(
    plane: []i32,
    stride: usize,
    rect: subband.Rect,
    bitplanes: u8,
    non_zero_count: u32,
    significance_bytes: []const u8,
    refinement_bytes: []const u8,
) !void {
    if (bitplanes == 0 and non_zero_count == 0 and rect.width == 0 and rect.height == 0) return;
    if (stride == 0 or rect.width == 0 or rect.height == 0) return BitplaneError.InvalidBlock;
    if (rect.y >= plane.len / stride or rect.x >= stride) return BitplaneError.InvalidBlock;
    const last_row = rect.y + rect.height - 1;
    const last_col = rect.x + rect.width - 1;
    if (last_col >= stride or last_row >= plane.len / stride) return BitplaneError.InvalidBlock;
    const active_area = try std.math.mul(usize, rect.width, rect.height);
    if (active_area > max_codeblock_area or @as(usize, @intCast(non_zero_count)) > active_area) return BitplaneError.InvalidBlock;

    var sig_reader = BitReader.init(significance_bytes);
    var ref_reader = BitReader.init(refinement_bytes);
    var significant_positions: [max_codeblock_area]usize = undefined;

    var signs_read: u32 = 0;
    var positions_len: usize = 0;
    var y: usize = 0;
    while (y < rect.height) : (y += 1) {
        const row = (rect.y + y) * stride;
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            if (try sig_reader.readBit()) {
                const negative = try sig_reader.readBit();
                const index = row + rect.x + x;
                significant_positions[positions_len] = index;
                positions_len += 1;
                plane[index] = if (negative) -1 else 1;
                signs_read += 1;
            }
        }
    }

    if (signs_read != non_zero_count) return BitplaneError.InvalidBlock;

    var bitplane_index = bitplanes;
    while (bitplane_index > 0) {
        bitplane_index -= 1;
        var position_index: usize = 0;
        while (position_index < positions_len) : (position_index += 1) {
            const index = significant_positions[position_index];
            if (try ref_reader.readBit()) {
                const bit = @as(i32, 1) << @as(u5, @intCast(bitplane_index));
                if (plane[index] > 0) {
                    plane[index] += bit;
                } else {
                    plane[index] -= bit;
                }
            }
        }
    }

    var position_index: usize = 0;
    while (position_index < positions_len) : (position_index += 1) {
        const index = significant_positions[position_index];
        if (plane[index] > 0) {
            plane[index] -= 1;
        } else {
            plane[index] += 1;
        }
    }
}

pub fn decodeBlock(
    plane: []i32,
    stride: usize,
    rect: subband.Rect,
    bitplanes: u8,
    non_zero_count: u32,
    bytes: []const u8,
) !void {
    if (bitplanes == 0 and non_zero_count == 0 and rect.width == 0 and rect.height == 0) {
        if (bytes.len != 0) return BitplaneError.TrailingData;
        return;
    }

    var cursor = ByteCursor.init(bytes);
    const significance_bytes = try cursor.readLengthPrefixed();
    const refinement_bytes = try cursor.readLengthPrefixed();
    _ = try cursor.readLengthPrefixed();
    if (!cursor.finished()) return BitplaneError.TrailingData;
    try decodeBlockPasses(
        plane,
        stride,
        rect,
        bitplanes,
        non_zero_count,
        significance_bytes,
        refinement_bytes,
    );
}

pub fn decodeBlockLegacy(
    plane: []i32,
    stride: usize,
    rect: subband.Rect,
    bitplanes: u8,
    non_zero_count: u32,
    bytes: []const u8,
) !void {
    if (bitplanes == 0 and non_zero_count == 0 and rect.width == 0 and rect.height == 0) {
        if (bytes.len != 0) return BitplaneError.TrailingData;
        return;
    }

    if (stride == 0 or rect.width == 0 or rect.height == 0) return BitplaneError.InvalidBlock;
    if (rect.y >= plane.len / stride or rect.x >= stride) return BitplaneError.InvalidBlock;
    const last_row = rect.y + rect.height - 1;
    const last_col = rect.x + rect.width - 1;
    if (last_col >= stride or last_row >= plane.len / stride) return BitplaneError.InvalidBlock;

    var reader = BitReader.init(bytes);

    var bitplane_index = bitplanes;
    while (bitplane_index > 0) {
        bitplane_index -= 1;
        var y: usize = 0;
        while (y < rect.height) : (y += 1) {
            const row = (rect.y + y) * stride;
            var x: usize = 0;
            while (x < rect.width) : (x += 1) {
                if (try reader.readBit()) {
                    plane[row + rect.x + x] |= @as(i32, 1) << @as(u5, @intCast(bitplane_index));
                }
            }
        }
    }

    var signs_read: u32 = 0;
    var y: usize = 0;
    while (y < rect.height) : (y += 1) {
        const row = (rect.y + y) * stride;
        var x: usize = 0;
        while (x < rect.width) : (x += 1) {
            const index = row + rect.x + x;
            if (plane[index] != 0) {
                signs_read += 1;
                if (try reader.readBit()) plane[index] = -plane[index];
            }
        }
    }

    if (signs_read != non_zero_count) return BitplaneError.InvalidBlock;
}

fn bitPlaneCount(max_mag: u32) u8 {
    if (max_mag == 0) return 0;
    return @as(u8, @intCast(32 - @clz(max_mag)));
}

fn magnitude(value: i32) u32 {
    const wide = @as(i64, value);
    const abs = if (wide < 0) -wide else wide;
    return @as(u32, @intCast(abs));
}

const BitWriter = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    current: u8 = 0,
    used: u4 = 0,

    fn init(allocator: std.mem.Allocator) BitWriter {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *BitWriter) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }

    fn reset(self: *BitWriter) void {
        self.bytes.clearRetainingCapacity();
        self.current = 0;
        self.used = 0;
    }

    fn writeBit(self: *BitWriter, bit: bool) !void {
        if (bit) {
            self.current |= @as(u8, 1) << @as(u3, @intCast(7 - self.used));
        }
        self.used += 1;
        if (self.used == 8) {
            try self.bytes.append(self.allocator, self.current);
            self.current = 0;
            self.used = 0;
        }
    }

    fn ensureUnusedBits(self: *BitWriter, bit_count: usize) !void {
        try self.bytes.ensureUnusedCapacity(self.allocator, (bit_count + 7) / 8);
    }

    fn writeBitAssumeCapacity(self: *BitWriter, bit: bool) void {
        if (bit) {
            self.current |= @as(u8, 1) << @as(u3, @intCast(7 - self.used));
        }
        self.used += 1;
        if (self.used == 8) {
            self.bytes.appendAssumeCapacity(self.current);
            self.current = 0;
            self.used = 0;
        }
    }

    fn writeBitsAssumeCapacity(self: *BitWriter, value: u32, bit_count: u6) void {
        var remaining = bit_count;
        while (remaining > 0) {
            const free: u4 = 8 - self.used;
            const take: u4 = if (remaining < free) @intCast(remaining) else free;
            const shift = remaining - take;
            const mask = (@as(u32, 1) << @as(u5, @intCast(take))) - 1;
            const chunk: u8 = @intCast((value >> @as(u5, @intCast(shift))) & mask);
            self.current |= chunk << @as(u3, @intCast(free - take));
            self.used += take;
            remaining = shift;
            if (self.used == 8) {
                self.bytes.appendAssumeCapacity(self.current);
                self.current = 0;
                self.used = 0;
            }
        }
    }

    fn writeZeroBitsAssumeCapacity(self: *BitWriter, count: usize) void {
        var remaining = count;
        while (remaining > 0 and self.used != 0) : (remaining -= 1) {
            self.writeBitAssumeCapacity(false);
        }

        while (remaining >= 8) : (remaining -= 8) {
            self.bytes.appendAssumeCapacity(0);
        }

        if (remaining > 0) {
            self.used = @intCast(remaining);
        }
    }

    fn writePresentAndSignAssumeCapacity(self: *BitWriter, negative: bool) void {
        if (self.used <= 6) {
            self.current |= @as(u8, 1) << @as(u3, @intCast(7 - self.used));
            if (negative) {
                self.current |= @as(u8, 1) << @as(u3, @intCast(6 - self.used));
            }
            self.used += 2;
            if (self.used == 8) {
                self.bytes.appendAssumeCapacity(self.current);
                self.current = 0;
                self.used = 0;
            }
            return;
        }

        self.current |= 1;
        self.bytes.appendAssumeCapacity(self.current);
        self.current = if (negative) 0x80 else 0;
        self.used = 1;
    }

    fn writeMagnitudeBitsAssumeCapacity(self: *BitWriter, magnitudes: []const u32, bit_index: u5) void {
        var index: usize = 0;

        if (self.used != 0) {
            while (index < magnitudes.len and self.used != 0) : (index += 1) {
                self.writeBitAssumeCapacity(((magnitudes[index] >> bit_index) & 1) != 0);
            }
        }

        while (index + 8 <= magnitudes.len) : (index += 8) {
            self.bytes.appendAssumeCapacity(packMagnitudeByte(magnitudes[index..][0..8], bit_index));
        }

        while (index < magnitudes.len) : (index += 1) {
            self.writeBitAssumeCapacity(((magnitudes[index] >> bit_index) & 1) != 0);
        }
    }

    fn writeUnary(self: *BitWriter, count: u32) !void {
        var i: u32 = 0;
        while (i < count) : (i += 1) try self.writeBit(false);
        try self.writeBit(true);
    }

    fn finish(self: *BitWriter) ![]u8 {
        if (self.used != 0) {
            try self.bytes.append(self.allocator, self.current);
            self.current = 0;
            self.used = 0;
        }
        return self.bytes.toOwnedSlice(self.allocator);
    }

    fn finishView(self: *BitWriter) ![]const u8 {
        if (self.used != 0) {
            try self.bytes.append(self.allocator, self.current);
            self.current = 0;
            self.used = 0;
        }
        return self.bytes.items;
    }
};

fn packMagnitudeByte(magnitudes: *const [8]u32, bit_index: u5) u8 {
    if (simd.has_neon) {
        return packMagnitudeByteNeon(magnitudes, bit_index);
    }

    var byte: u8 = 0;
    inline for (0..8) |offset| {
        byte |= @as(u8, @intCast((magnitudes[offset] >> bit_index) & 1)) << @as(u3, @intCast(7 - offset));
    }
    return byte;
}

fn packMagnitudeByteNeon(magnitudes: *const [8]u32, bit_index: u5) u8 {
    const shift: @Vector(neon_pack_lanes, u5) = @splat(bit_index);
    const low_values: NeonPackVector = magnitudes[0..4].*;
    const high_values: NeonPackVector = magnitudes[4..8].*;
    const low = (low_values >> shift) & @as(NeonPackVector, @splat(1));
    const high = (high_values >> shift) & @as(NeonPackVector, @splat(1));
    const low_bits = low * neon_pack_masks;
    const high_bits = high * neon_pack_tail_masks;
    return @as(u8, @intCast(@reduce(.Or, low_bits) | @reduce(.Or, high_bits)));
}

const ByteCursor = struct {
    bytes: []const u8,
    index: usize = 0,

    fn init(bytes: []const u8) ByteCursor {
        return .{ .bytes = bytes };
    }

    fn finished(self: ByteCursor) bool {
        return self.index == self.bytes.len;
    }

    fn readLengthPrefixed(self: *ByteCursor) ![]const u8 {
        if (self.bytes.len - self.index < 4) return BitplaneError.TruncatedData;
        const len = (@as(u32, self.bytes[self.index]) << 24) |
            (@as(u32, self.bytes[self.index + 1]) << 16) |
            (@as(u32, self.bytes[self.index + 2]) << 8) |
            self.bytes[self.index + 3];
        self.index += 4;
        if (self.bytes.len - self.index < len) return BitplaneError.TruncatedData;
        const start = self.index;
        self.index += @as(usize, len);
        return self.bytes[start..self.index];
    }
};

fn appendU32Be(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    try out.append(allocator, @as(u8, @truncate(value >> 24)));
    try out.append(allocator, @as(u8, @truncate(value >> 16)));
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value)));
}

const BitReader = struct {
    bytes: []const u8,
    byte_index: usize = 0,
    bit_index: u4 = 0,

    fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes };
    }

    fn readBit(self: *BitReader) !bool {
        if (self.byte_index >= self.bytes.len) return BitplaneError.TruncatedData;
        const value = (self.bytes[self.byte_index] & (@as(u8, 0x80) >> @as(u3, @intCast(self.bit_index)))) != 0;
        self.bit_index += 1;
        if (self.bit_index == 8) {
            self.byte_index += 1;
            self.bit_index = 0;
        }
        return value;
    }
};
