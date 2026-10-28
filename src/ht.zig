//! HT block decoder of ITU-T T.814 | ISO/IEC 15444-15 (HTJ2K), clause 7.
//!
//! An HT code-block codes every magnitude bit above a chosen bit-plane in
//! one cleanup pass over 2x2 quads, from three byte-streams packed into the
//! HT cleanup segment: MagSgn (forward from the start), MEL (forward from
//! the suffix), and VLC (backward from the end). At most one SigProp and one
//! MagRef pass, in the HT refinement segment, add the next bit-plane.
//!
//! The decoder follows the procedures of clause 7 directly; its output is
//! the same coefficient layout as the Part 1 Tier-1 decoder in `ebcot.zig`:
//! signed magnitudes in absolute bit-planes, a sample whose lowest decoded
//! bit-plane is `p > 0` carrying the midpoint `2^(p-1)` of what is left.
//! The encoder runs the cleanup procedures backward for blocks coded
//! losslessly in one cleanup pass at bit-plane 0.

const std = @import("std");

pub const Error = error{
    /// The HT segments do not conform to T.814, where it leaves the
    /// decoder's behaviour undefined (`error()` in clause 7.1).
    InvalidBlock,
    OutOfMemory,
};

/// One code-block's HT set: the bytes of its HT cleanup and refinement
/// segments and what the packet headers say about them (T.814 B.3).
pub const Block = struct {
    width: usize,
    height: usize,
    /// The HT cleanup segment, Lcup bytes.
    cleanup: []const u8,
    /// The HT refinement segment, Lref bytes; empty without one.
    refinement: []const u8 = &.{},
    /// Z_blk: 1 decodes the cleanup pass, 2 adds SigProp, 3 adds MagRef.
    passes: u2,
    /// The bit-plane of the cleanup pass's least significant magnitude bit,
    /// `M_b - 1 - S_blk`.
    cleanup_plane: u8,
    /// M_b: every decoded magnitude is below `2^magnitude_bitplanes`.
    magnitude_bitplanes: u8,
    /// SPcod/SPcoc bit 3: SigProp ignores the next stripe (T.814 7.4).
    vertical_causal: bool = false,
};

/// Lcup and Lref limits of T.814 7.1.1.
pub const max_cleanup_length: usize = 65534;
pub const max_refinement_length: usize = 2046;

/// Reusable working memory for one coefficient type.
pub fn Decoder(comptime Coefficient: type) type {
    return struct {
        const Self = @This();
        const Magnitude = @Int(.unsigned, @bitSizeOf(Coefficient) - 1);
        /// The deepest M_b decoded: what the coefficient type holds, and
        /// at most 62 so that an exponent bound of M_b + 1 MagSgn bits and
        /// its known-1 bit fit in 64.
        pub const max_bitplanes: u8 = @min(@bitSizeOf(Magnitude), 62);

        allocator: std.mem.Allocator,
        /// `decode`'s output, `width * height` coefficients in raster order.
        coefficients: std.ArrayList(Coefficient) = .empty,
        /// SigProp and MagRef state, one byte per sample, for blocks with
        /// refinement passes.
        flags: std.ArrayList(u8) = .empty,
        /// Significance and exponents E_n of the bottom lines of the previous
        /// and the current quad row, one zero guard column on either side.
        lines: std.ArrayList(u8) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.coefficients.deinit(self.allocator);
            self.flags.deinit(self.allocator);
            self.lines.deinit(self.allocator);
            self.* = undefined;
        }

        /// Decode `block` into `width * height` coefficients in raster order,
        /// a view valid until the next call.
        pub fn decode(self: *Self, block: Block) Error![]const Coefficient {
            const area = std.math.mul(usize, block.width, block.height) catch return Error.InvalidBlock;
            try self.coefficients.resize(self.allocator, area);
            try self.decodeInto(block, self.coefficients.items, block.width);
            return self.coefficients.items;
        }

        /// Decode `block` into the rows of `out`: sample (x, y) lands at
        /// `out[y * stride + x]`, and every sample of the block is written.
        pub fn decodeInto(self: *Self, block: Block, out: []Coefficient, stride: usize) Error!void {
            if (block.width == 0 or block.height == 0 or stride < block.width) return Error.InvalidBlock;
            if (block.magnitude_bitplanes > max_bitplanes or
                block.cleanup_plane >= block.magnitude_bitplanes)
            {
                return Error.InvalidBlock;
            }
            if (block.passes > 1 and block.cleanup_plane == 0) return Error.InvalidBlock;
            const last_row = std.math.mul(usize, block.height - 1, stride) catch return Error.InvalidBlock;
            if (last_row + block.width > out.len) return Error.InvalidBlock;
            if (block.passes == 0) {
                for (0..block.height) |y| @memset(out[y * stride ..][0..block.width], 0);
                return;
            }
            try self.decodeCleanup(block, out, stride);
            if (block.passes == 1) return;

            // The refinement passes need cleanup significance apart from the
            // samples they make significant, and leave the midpoint to last.
            const area = block.width * block.height;
            try self.flags.resize(self.allocator, area);
            const flags = self.flags.items;
            for (0..block.height) |y| {
                for (out[y * stride ..][0..block.width], flags[y * block.width ..][0..block.width]) |value, *flag| {
                    flag.* = @intFromBool(value != 0);
                }
            }
            try checkSegmentBytes(block.refinement, max_refinement_length);
            var sig_prop = ForwardReader{ .bytes = block.refinement, .synthesize_ff = false };
            try decodeSigProp(flags, block.width, block, &sig_prop);
            if (block.passes == 3) {
                var mag_ref = MagRefReader.init(block.refinement);
                decodeMagRef(flags, block.width, block, &mag_ref);
            }
            const p = block.cleanup_plane;
            for (0..block.height) |y| {
                for (out[y * stride ..][0..block.width], flags[y * block.width ..][0..block.width]) |*value, flag| {
                    var magnitude: u64 = @abs(value.*);
                    var negative = value.* < 0;
                    var lowest: u8 = p;
                    if (magnitude != 0) {
                        if ((flag & flag_refined) != 0) {
                            lowest = p - 1;
                            if ((flag & flag_refinement_bit) != 0) magnitude |= @as(u64, 1) << @intCast(p - 1);
                        }
                    } else if ((flag & flag_refinement_bit) != 0) {
                        // Newly significant in the SigProp pass.
                        lowest = p - 1;
                        magnitude = @as(u64, 1) << @intCast(p - 1);
                        negative = (flag & flag_negative) != 0;
                    }
                    if (magnitude != 0 and lowest > 0) magnitude |= @as(u64, 1) << @intCast(lowest - 1);
                    const signed: Coefficient = @intCast(magnitude);
                    value.* = if (negative) -signed else signed;
                }
            }
        }

        /// The HT cleanup pass (7.3), quad pair by quad pair: CxtVLC and
        /// U-VLC decoding (7.3.4 to 7.3.7), then each quad's MagSgn values in
        /// scan order (7.3.8); the three bit-streams are independent, so
        /// interleaving them by pair keeps each one's order. A block with
        /// only the cleanup pass gets its final values, midpoint included;
        /// with refinement passes, `mu_n << p` and the sign.
        fn decodeCleanup(self: *Self, block: Block, out: []Coefficient, stride: usize) Error!void {
            const segment = try CleanupSegment.init(block.cleanup);
            var mag_sgn = ForwardReader{ .bytes = block.cleanup[0..segment.prefix_length], .synthesize_ff = true };
            var mel = MelDecoder{ .reader = .{ .segment = segment, .position = segment.prefix_length } };
            var vlc = VlcReader.init(segment);
            const quad_width = (block.width + 1) / 2;
            const quad_height = (block.height + 1) / 2;
            const line_length = 2 * quad_width + 2;
            try self.lines.resize(self.allocator, 4 * line_length);
            @memset(self.lines.items, 0);
            var above_significance = self.lines.items[0..line_length];
            var above_exponents = self.lines.items[line_length..][0..line_length];
            var below_significance = self.lines.items[2 * line_length ..][0..line_length];
            var below_exponents = self.lines.items[3 * line_length ..][0..line_length];
            const quad_out = QuadOutput{
                .out = out,
                .stride = stride,
                .width = block.width,
                .height = block.height,
                .plane = block.cleanup_plane,
                // An exponent bound above this, or a magnitude of M_b - p or
                // more bits, would not fit the band (7.3.7, 8.7).
                .magnitude_limit = block.magnitude_bitplanes - block.cleanup_plane,
                .half = if (block.passes == 1 and block.cleanup_plane > 0)
                    @as(u64, 1) << @intCast(block.cleanup_plane - 1)
                else
                    0,
            };

            // Insignificant samples are zero: clear the block first, so that
            // only significant ones are written.
            for (0..block.height) |y| @memset(out[y * stride ..][0..block.width], 0);

            var qy: usize = 0;
            while (qy < quad_height) : (qy += 1) {
                const initial = qy == 0;
                @memset(below_significance, 0);
                @memset(below_exponents, 0);
                const lines = Lines{
                    .above_significance = above_significance,
                    .above_exponents = above_exponents,
                    .below_significance = below_significance,
                    .below_exponents = below_exponents,
                };
                var left_rho: u4 = 0;
                var qx: usize = 0;
                while (qx < quad_width) : (qx += 2) {
                    const pair = qx + 1 < quad_width;
                    const first = try decodeSignificance(&vlc, &mel, quadContext(initial, left_rho, above_significance, qx), initial);
                    var second = Quad{};
                    if (pair) second = try decodeSignificance(&vlc, &mel, quadContext(initial, first.rho, above_significance, qx + 1), initial);
                    left_rho = if (pair) second.rho else first.rho;

                    var residual1: u8 = 0;
                    var residual2: u8 = 0;
                    const first_offset = first.u_off != 0;
                    const second_offset = second.u_off != 0;
                    if (initial and first_offset and second_offset) {
                        if (try mel.decode() == 1) {
                            const p1 = try decodeUPrefix(&vlc);
                            const p2 = try decodeUPrefix(&vlc);
                            const s1 = try decodeUSuffix(&vlc, p1);
                            const s2 = try decodeUSuffix(&vlc, p2);
                            residual1 = 2 + p1 + s1 + 4 * try decodeUExtension(&vlc, s1);
                            residual2 = 2 + p2 + s2 + 4 * try decodeUExtension(&vlc, s2);
                        } else {
                            const p1 = try decodeUPrefix(&vlc);
                            // A three-bit first prefix leaves the second
                            // residual one bit, u = u_bit + 1 (Formula 4ff).
                            const p2 = if (p1 > 2) @as(u8, try vlc.bit()) + 1 else try decodeUPrefix(&vlc);
                            const s1 = try decodeUSuffix(&vlc, p1);
                            const s2 = try decodeUSuffix(&vlc, p2);
                            residual1 = p1 + s1 + 4 * try decodeUExtension(&vlc, s1);
                            residual2 = p2 + s2 + 4 * try decodeUExtension(&vlc, s2);
                        }
                    } else {
                        const p1 = if (first_offset) try decodeUPrefix(&vlc) else 0;
                        const p2 = if (second_offset) try decodeUPrefix(&vlc) else 0;
                        const s1 = try decodeUSuffix(&vlc, p1);
                        const s2 = try decodeUSuffix(&vlc, p2);
                        residual1 = p1 + s1 + 4 * try decodeUExtension(&vlc, s1);
                        residual2 = p2 + s2 + 4 * try decodeUExtension(&vlc, s2);
                    }
                    try quad_out.write(first, exponentBound(first.rho, residual1, initial, above_exponents, qx), &mag_sgn, lines, qx, 2 * qy);
                    if (pair) try quad_out.write(second, exponentBound(second.rho, residual2, initial, above_exponents, qx + 1), &mag_sgn, lines, qx + 1, 2 * qy);
                }
                // The next quad row predicts from this one's bottom line.
                std.mem.swap([]u8, &above_significance, &below_significance);
                std.mem.swap([]u8, &above_exponents, &below_exponents);
            }
        }

        const Lines = struct {
            above_significance: []const u8,
            above_exponents: []const u8,
            below_significance: []u8,
            below_exponents: []u8,
        };

        const QuadOutput = struct {
            out: []Coefficient,
            stride: usize,
            width: usize,
            height: usize,
            plane: u8,
            magnitude_limit: u8,
            half: u64,

            /// Decode one quad's MagSgn values (7.3.8), write its samples,
            /// and record its bottom line for the next quad row.
            inline fn write(self: QuadOutput, quad: Quad, bound: u8, mag_sgn: *ForwardReader, lines: Lines, qx: usize, y: usize) Error!void {
                // The block and the line below are already zero.
                if (quad.rho == 0) return;
                const x = 2 * qx;
                if (bound > self.magnitude_limit + 1) return Error.InvalidBlock;
                inline for (0..4) |j| {
                    if ((quad.rho & (1 << j)) != 0) {
                        const sample_x = x + (j >> 1);
                        const sample_y = y + (j & 1);
                        // Padded samples stay insignificant (7.2).
                        if (sample_x >= self.width or sample_y >= self.height) return Error.InvalidBlock;
                        const known: u8 = (quad.e_k >> j) & 1;
                        const bits = bound - known;
                        // A significant sample needs at least its sign bit.
                        if (bits == 0) return Error.InvalidBlock;
                        var value = try mag_sgn.bits(bits);
                        value |= @as(u64, (quad.e_1 >> j) & 1) << @intCast(bits);
                        const magnitude = (value >> 1) + 1;
                        if ((magnitude >> @intCast(self.magnitude_limit)) != 0) return Error.InvalidBlock;
                        const scaled: Coefficient = @intCast((magnitude << @intCast(self.plane)) | self.half);
                        self.out[sample_y * self.stride + sample_x] = if ((value & 1) != 0) -scaled else scaled;
                        if ((j & 1) != 0) {
                            lines.below_significance[sample_x + 1] = 1;
                            lines.below_exponents[sample_x + 1] = magnitudeExponent(magnitude);
                        }
                    }
                }
            }
        };
    };
}

/// One code-block's HT cleanup segment coded by `Encoder`: from `encode`,
/// down to bit-plane 0, so that the cleanup pass alone is lossless
/// (Z_blk = 1, cleanup plane 0); in a `Set`, down to its plane.
pub const Cleanup = struct {
    /// The HT cleanup segment, Lcup bytes; empty for an all-zero block,
    /// which has no coding passes.
    bytes: []const u8,
    /// Bits of the largest magnitude, 0 for a block with nothing at or
    /// above the cleanup plane. The packet header signals `M_b - 1 - p`
    /// missing bit-planes for the cleanup pass at bit-plane p.
    bitplanes: u8,
    /// The block's significant samples.
    non_zero_count: u32,
};

/// One HT set coded by `Encoder.encodeSet`: an HT cleanup pass ending at
/// bit-plane `plane` and, for a plane above 0 and a non-empty cleanup pass,
/// the SigProp and MagRef passes of bit-plane `plane - 1`.
pub const Set = struct {
    plane: u8,
    cleanup: Cleanup,
    /// The HT refinement segment, Lref bytes: the SigProp bytes, then the
    /// MagRef bytes, which the decoder reads backward from the end.
    refinement: []const u8 = &.{},
    sig_prop_length: usize = 0,
    /// The squared error of the decoded magnitudes, in units of the band's
    /// quantization step: with no pass, then after the cleanup, SigProp,
    /// and MagRef passes, each decoded as `Decoder` reconstructs (the
    /// midpoint of what is known).
    distortion: [4]f64 = @splat(0),

    /// The coding passes worth signalling: those up to the last one that
    /// codes a byte or lowers the distortion.
    pub fn passCount(self: Set) u2 {
        if (self.cleanup.bytes.len == 0) return 0;
        if (self.refinement.len == 0) return 1;
        return if (self.refinement.len > self.sig_prop_length) 3 else 2;
    }
};

/// The HT cleanup encoder: the decoding procedures of clause 7.3 run
/// backward, writing the MagSgn, MEL, and VLC byte-streams of 7.1 and
/// packing them into one cleanup segment.
pub fn Encoder(comptime Coefficient: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        /// The cleanup segment of the last `encode`, MagSgn written in place.
        segment: std.ArrayList(u8) = .empty,
        mel: std.ArrayList(u8) = .empty,
        /// The VLC bytes, written from the end of the buffer backward.
        vlc: std.ArrayList(u8) = .empty,
        /// Exponents of the previous quad row's bottom line and the current
        /// row's two lines, in the guard layout of `quadContext`.
        lines: std.ArrayList(u8) = .empty,
        /// The current quad row's MagSgn values, top line then bottom.
        values: std.ArrayList(Magnitude) = .empty,
        /// The current quad row's `QuadRow` arrays.
        quad_row: std.ArrayList(u8) = .empty,
        /// `QuadRow.index`.
        indices: std.ArrayList(u16) = .empty,
        /// The current quad row's MagSgn bits, pair by pair.
        words: std.ArrayList(u64) = .empty,
        /// `encodeSet`'s per-sample SigProp and MagRef state.
        flags: std.ArrayList(u8) = .empty,
        /// `encodeSet`'s refinement segment: SigProp forward, MagRef backward.
        refinement: std.ArrayList(u8) = .empty,

        const Magnitude = @Int(.unsigned, @bitSizeOf(Coefficient));
        const Shift = std.math.Log2Int(Magnitude);

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.segment.deinit(self.allocator);
            self.mel.deinit(self.allocator);
            self.vlc.deinit(self.allocator);
            self.lines.deinit(self.allocator);
            self.values.deinit(self.allocator);
            self.quad_row.deinit(self.allocator);
            self.indices.deinit(self.allocator);
            self.words.deinit(self.allocator);
            self.flags.deinit(self.allocator);
            self.refinement.deinit(self.allocator);
            self.* = undefined;
        }

        /// Code the `width` x `height` block whose sample (x, y) is
        /// `samples[y * stride + x]`; the bytes are valid until the next call.
        pub fn encode(self: *Self, samples: []const Coefficient, stride: usize, width: usize, height: usize) Error!Cleanup {
            return self.encodeCleanup(samples, stride, width, height, 0);
        }

        /// The HT set whose cleanup pass ends at bit-plane `plane`, with a
        /// SigProp and a MagRef pass for bit-plane `plane - 1` when `plane`
        /// is not 0 (T.814 Annex B), SigProp with the vertically causal
        /// context if asked, and the distortion each pass leaves:
        /// the cleanup bytes as `encode` gives them and the refinement
        /// segment, both valid until the next call.
        pub fn encodeSet(self: *Self, samples: []const Coefficient, stride: usize, width: usize, height: usize, plane: u8, vertical_causal: bool) Error!Set {
            if (plane >= @bitSizeOf(Magnitude)) return Error.InvalidBlock;
            const cleanup = try self.encodeCleanup(samples, stride, width, height, @intCast(plane));
            var set = Set{ .plane = plane, .cleanup = cleanup };
            const area = width * height;
            try self.flags.resize(self.allocator, 2 * area);
            const flags = self.flags.items[0..area];
            set.distortion = cleanupDistortion(samples, stride, width, height, plane, flags);
            if (plane == 0 or cleanup.bytes.len == 0) return set;
            const near = self.flags.items[area..][0..area];
            markSignificantNeighbours(flags, near, width, height, vertical_causal);
            // SigProp at most two bits a sample, MagRef one, and a stuffing
            // bit per seven of either.
            const sig_prop_capacity = area / 4 + area / 28 + 24;
            const mag_ref_capacity = area / 8 + area / 56 + 16;
            try self.refinement.resize(self.allocator, sig_prop_capacity + mag_ref_capacity);
            // SigProp stuffs as MagSgn does (7.1.5).
            var sig_prop = MagSgnWriter{ .bytes = self.refinement.items[0..sig_prop_capacity] };
            var mag_ref = MagRefWriter{ .bytes = self.refinement.items[sig_prop_capacity..] };
            set.distortion[2] = set.distortion[1] - encodeSigProp(Coefficient, samples, stride, width, height, plane, vertical_causal, flags, near, &sig_prop);
            set.distortion[3] = set.distortion[2] - encodeMagRef(Coefficient, samples, stride, width, height, plane, flags, &mag_ref);
            sig_prop.finishWithZeros();
            mag_ref.finish();
            set.sig_prop_length = sig_prop.position;
            const length = sig_prop.position + mag_ref.written;
            if (length > max_refinement_length) return Error.InvalidBlock;
            // MagRef reads backward from the segment's end.
            const bytes = self.refinement.items[0..length];
            std.mem.copyForwards(u8, bytes[sig_prop.position..], mag_ref.bytes[mag_ref.bytes.len - mag_ref.written ..]);
            set.refinement = bytes;
            return set;
        }

        fn encodeCleanup(self: *Self, samples: []const Coefficient, stride: usize, width: usize, height: usize, plane: Shift) Error!Cleanup {
            if (width == 0 or height == 0 or stride < width) return Error.InvalidBlock;
            const last_row = std.math.mul(usize, height - 1, stride) catch return Error.InvalidBlock;
            if (last_row + width > samples.len) return Error.InvalidBlock;

            const quad_width = (width + 1) / 2;
            const quad_height = (height + 1) / 2;
            const quad_count = quad_width * quad_height;
            // Bounds on each stream: a MagSgn value of at most 64 bits per
            // sample, at most 20 VLC and 12 MEL bits per quad, and a stuffing
            // bit per seven.
            const area = std.math.mul(usize, width, height) catch return Error.InvalidBlock;
            const mag_sgn_capacity = area * 10 + 16;
            const mel_capacity = quad_count * 2 + 16;
            const vlc_capacity = quad_count * 3 + 16;
            try self.segment.resize(self.allocator, mag_sgn_capacity + mel_capacity + vlc_capacity);
            try self.mel.resize(self.allocator, mel_capacity);
            try self.vlc.resize(self.allocator, vlc_capacity);
            var mag_sgn = MagSgnWriter{ .bytes = self.segment.items[0..mag_sgn_capacity] };
            var mel = MelWriter{ .bytes = self.mel.items };
            var vlc = VlcWriter.init(self.vlc.items);

            // The previous quad row's bottom line and the current row's two
            // lines: exponents E_n in the guard layout of `quadContext`
            // (column x at x + 1, zero guards, zero where insignificant),
            // and the MagSgn values v_n.
            // The lines run on past the block, zero, for `QuadRow`'s whole
            // vectors.
            const line_length = 2 * quad_width + 2 + 2 * QuadRow.lanes + 2;
            try self.lines.resize(self.allocator, 3 * line_length);
            @memset(self.lines.items, 0);
            var above = self.lines.items[0..line_length];
            const top = self.lines.items[line_length..][0..line_length];
            var bottom = self.lines.items[2 * line_length ..][0..line_length];
            const row_length = quad_width + QuadRow.lanes;
            // The value lines run on past the block too, for
            // `packMagSgnPairs`.
            try self.values.resize(self.allocator, 4 * row_length);
            const top_values = self.values.items[0 .. 2 * row_length];
            const bottom_values = self.values.items[2 * row_length ..];
            try self.quad_row.resize(self.allocator, 5 * row_length);
            try self.indices.resize(self.allocator, row_length);
            const row = QuadRow{
                .rho = self.quad_row.items[0..row_length],
                .bound = self.quad_row.items[row_length..][0..row_length],
                .residual = self.quad_row.items[2 * row_length ..][0..row_length],
                .known = self.quad_row.items[3 * row_length ..][0..row_length],
                .mag_sgn_length = self.quad_row.items[4 * row_length ..][0..row_length],
                .index = self.indices.items,
            };
            try self.words.resize(self.allocator, row_length);

            var magnitudes: Magnitude = 0;
            var non_zero_count: u32 = 0;
            var qy: usize = 0;
            while (qy < quad_height) : (qy += 1) {
                const initial = qy == 0;
                const y = 2 * qy;
                // The next quad row's samples, rows a stride apart, on their
                // way into the cache meanwhile.
                if (y + 2 < height) prefetchLine(samples[(y + 2) * stride ..][0..width]);
                if (y + 3 < height) prefetchLine(samples[(y + 3) * stride ..][0..width]);
                magnitudes |= analyzeLine(samples[y * stride ..][0..width], top, top_values, plane);
                if (y + 1 < height) {
                    magnitudes |= analyzeLine(samples[(y + 1) * stride ..][0..width], bottom, bottom_values, plane);
                } else {
                    @memset(bottom, 0);
                    @memset(bottom_values, 0);
                }
                const widest = row.analyze(initial, top, bottom, above, quad_width);
                non_zero_count += switch (initial) {
                    inline else => |first_row| codeCodewords(first_row, row, quad_width, &mel, &vlc),
                };
                // Then the MagSgn bits: a quad pair's fit one word when no
                // U_q of the row exceeds 7.
                if (widest <= 7) {
                    packMagSgnPairs(Magnitude, row, top_values, bottom_values, self.words.items, quad_width);
                    putMagSgnPairs(&mag_sgn, self.words.items[0 .. (quad_width + 1) / 2], row.mag_sgn_length);
                } else {
                    putMagSgnQuads(Magnitude, &mag_sgn, row, top_values, bottom_values, quad_width);
                }
                // The next quad row predicts from this one's bottom line.
                std.mem.swap([]u8, &above, &bottom);
            }
            if (magnitudes == 0) return .{ .bytes = &.{}, .bitplanes = 0, .non_zero_count = 0 };

            mag_sgn.finish();
            vlc.settle();
            terminateMelVlc(&mel, &vlc);
            const suffix_length = mel.position + vlc.written;
            if (suffix_length > 4079) return Error.InvalidBlock;
            const length = mag_sgn.position + suffix_length;
            if (length > max_cleanup_length) return Error.InvalidBlock;
            const bytes = self.segment.items[0..length];
            @memcpy(bytes[mag_sgn.position..][0..mel.position], mel.bytes[0..mel.position]);
            @memcpy(bytes[mag_sgn.position + mel.position ..], vlc.bytes[vlc.bytes.len - vlc.written ..]);
            // Scup in the last twelve bits (7.1.1).
            bytes[length - 1] = @intCast(suffix_length >> 4);
            bytes[length - 2] = (bytes[length - 2] & 0xf0) | @as(u8, @intCast(suffix_length & 0x0f));
            return .{
                .bytes = bytes,
                .bitplanes = @intCast(@bitSizeOf(Magnitude) - @clz(magnitudes) + @as(u8, plane)),
                .non_zero_count = non_zero_count,
            };
        }

        /// Each cache line of `line`.
        fn prefetchLine(line: []const Coefficient) void {
            var offset: usize = 0;
            while (offset < line.len) : (offset += 64 / @sizeOf(Coefficient)) {
                @prefetch(line.ptr + offset, .{});
            }
        }

        /// One sample line, its magnitudes shifted down `plane` bits: each
        /// exponent E_n at `exponents[x + 1]` (zero where insignificant, and
        /// in the padding column and guard after the line) and
        /// v_n = 2 (mu_n - 1) + s_n at `values[x]` (zero in the padding
        /// column); returns the magnitudes ORed, whose bit length is the
        /// largest one's.
        fn analyzeLine(row: []const Coefficient, exponents: []u8, values: []Magnitude, plane: Shift) Magnitude {
            const lanes = comptime std.simd.suggestVectorLength(Coefficient) orelse 4;
            const Lanes = @Vector(lanes, Magnitude);
            const zero: Lanes = @splat(0);
            const one: Lanes = @splat(1);
            var ored = zero;
            var x: usize = 0;
            while (x + lanes <= row.len) : (x += lanes) {
                const sample: @Vector(lanes, Coefficient) = row[x..][0..lanes].*;
                const magnitude = @as(Lanes, @abs(sample)) >> @splat(plane);
                ored |= magnitude;
                const significant = magnitude != zero;
                const below = magnitude -% one;
                const leading: @Vector(lanes, u8) = @clz(below);
                const exponent = @as(@Vector(lanes, u8), @splat(@bitSizeOf(Magnitude) + 1)) - leading;
                exponents[x + 1 ..][0..lanes].* = @select(u8, significant, exponent, @as(@Vector(lanes, u8), @splat(0)));
                const negative = @select(Magnitude, sample < @as(@Vector(lanes, Coefficient), @splat(0)), one, zero);
                values[x..][0..lanes].* = @select(Magnitude, significant, (below << @splat(1)) | negative, zero);
            }
            var tail: Magnitude = @reduce(.Or, ored);
            while (x < row.len) : (x += 1) {
                const sample = row[x];
                const magnitude = @as(Magnitude, @abs(sample)) >> plane;
                tail |= magnitude;
                exponents[x + 1] = if (magnitude == 0) 0 else @intCast(@bitSizeOf(Magnitude) + 1 - @clz(magnitude - 1));
                values[x] = if (magnitude == 0) 0 else 2 * (magnitude - 1) + @intFromBool(sample < 0);
            }
            @memset(exponents[row.len + 1 ..], 0);
            @memset(values[row.len..], 0);
            return tail;
        }
    };
}

/// The decoder's reconstruction of magnitude `mu` known down to bit-plane
/// `lowest`: the bits above it, then the midpoint of the rest.
inline fn reconstructed(mu: u64, lowest: u8) u64 {
    if (lowest == 0) return mu;
    if (lowest >= 64 or (mu >> @intCast(lowest)) == 0) return 0;
    return ((mu >> @intCast(lowest)) << @intCast(lowest)) | (@as(u64, 1) << @intCast(lowest - 1));
}

inline fn squaredError(mu: u64, estimate: u64) f64 {
    const difference: f64 = @floatFromInt(if (mu > estimate) mu - estimate else estimate - mu);
    return difference * difference;
}

/// The distortion with no pass and after the cleanup pass ending at
/// `plane`, marking each sample the cleanup pass makes significant in
/// `flags` (and clearing the rest) for SigProp and MagRef.
fn cleanupDistortion(samples: anytype, stride: usize, width: usize, height: usize, plane: u8, flags: []u8) [4]f64 {
    var none: f64 = 0;
    var after: f64 = 0;
    for (0..height) |y| {
        for (samples[y * stride ..][0..width], flags[y * width ..][0..width]) |sample, *flag| {
            const mu: u64 = @abs(sample);
            const significant = plane < 64 and (mu >> @intCast(plane)) != 0;
            flag.* = if (significant) flag_significant | (if (sample < 0) flag_negative else 0) else 0;
            none += squaredError(mu, 0);
            after += squaredError(mu, reconstructed(mu, plane));
        }
    }
    return .{ none, after, after, after };
}

/// Marks in `near` each sample with a cleanup-significant sample among its
/// eight neighbours, leaving out the next stripe's under the vertically
/// causal context: `sigPropNeighbourhood` before SigProp makes any sample
/// significant.
fn markSignificantNeighbours(flags: []const u8, near: []u8, width: usize, height: usize, vertical_causal: bool) void {
    for (0..height) |y| {
        const row = near[y * width ..][0..width];
        @memset(row, 0);
        const first = if (y > 0) y - 1 else y;
        // The next row unless it starts the next stripe, which the
        // vertically causal context leaves out.
        const last = if (y + 1 < height and !(vertical_causal and (y + 1) % 4 == 0)) y + 1 else y;
        for (first..last + 1) |ny| {
            const line = flags[ny * width ..][0..width];
            for (row, 0..) |*out, x| {
                var any = (if (x > 0) line[x - 1] else 0) | (if (x + 1 < width) line[x + 1] else 0);
                if (ny != y) any |= line[x];
                out.* |= any & flag_significant;
            }
        }
    }
}

/// The HT SigProp pass for bit-plane `plane - 1` (7.4 run backward): in
/// four-line stripes and four-column groups, a bit for each insignificant
/// sample next to a significant one, then a sign bit for each sample it
/// made significant. Returns the distortion it removes. `near` marks the
/// samples next to a cleanup-significant one; only the others need a look
/// at the samples this pass made significant.
fn encodeSigProp(comptime Coefficient: type, samples: []const Coefficient, stride: usize, width: usize, height: usize, plane: u8, vertical_causal: bool, flags: []u8, near: []const u8, writer: *MagSgnWriter) f64 {
    const bit_plane: u6 = @intCast(plane - 1);
    var removed: f64 = 0;
    var stripe: usize = 0;
    while (stripe < height) : (stripe += 4) {
        const stripe_end = @min(stripe + 4, height);
        // Vertically causal context leaves out the next stripe.
        const below_limit = if (vertical_causal) stripe_end else height;
        var group: usize = 0;
        while (group < width) : (group += 4) {
            const group_end = @min(group + 4, width);
            var magnitude_bits: u64 = 0;
            var magnitude_count: u8 = 0;
            var sign_bits: u64 = 0;
            var sign_count: u8 = 0;
            for (group..group_end) |x| {
                for (stripe..stripe_end) |y| {
                    const location = y * width + x;
                    if ((flags[location] & flag_significant) != 0) continue;
                    if (near[location] == 0 and !sigPropNeighbourhood(flags, width, width, below_limit, x, y)) continue;
                    const sample = samples[y * stride + x];
                    const mu: u64 = @abs(sample);
                    const bit = (mu >> bit_plane) & 1;
                    magnitude_bits |= bit << @intCast(magnitude_count);
                    magnitude_count += 1;
                    if (bit == 1) {
                        flags[location] |= flag_refinement_bit;
                        removed += squaredError(mu, 0) - squaredError(mu, reconstructed(mu, plane - 1));
                        // The signs follow in the same order.
                        sign_bits |= @as(u64, @intFromBool(sample < 0)) << @intCast(sign_count);
                        sign_count += 1;
                    }
                }
            }
            writer.put(magnitude_bits, magnitude_count);
            writer.put(sign_bits, sign_count);
        }
    }
    return removed;
}

/// The HT MagRef pass for bit-plane `plane - 1` (7.5 run backward): bit
/// `plane - 1` of each sample the cleanup pass made significant, in stripe
/// scan order. Returns the distortion it removes.
fn encodeMagRef(comptime Coefficient: type, samples: []const Coefficient, stride: usize, width: usize, height: usize, plane: u8, flags: []const u8, writer: *MagRefWriter) f64 {
    const bit_plane: u6 = @intCast(plane - 1);
    var removed: f64 = 0;
    var stripe: usize = 0;
    while (stripe < height) : (stripe += 4) {
        const stripe_end = @min(stripe + 4, height);
        for (0..width) |x| {
            var bits: u64 = 0;
            var count: u8 = 0;
            for (stripe..stripe_end) |y| {
                if ((flags[y * width + x] & flag_significant) == 0) continue;
                const mu: u64 = @abs(samples[y * stride + x]);
                bits |= ((mu >> bit_plane) & 1) << @intCast(count);
                count += 1;
                removed += squaredError(mu, reconstructed(mu, plane)) - squaredError(mu, reconstructed(mu, plane - 1));
            }
            writer.put(bits, count);
        }
    }
    return removed;
}

/// MagRef bits least significant first into bytes stored backward from the
/// end of `bytes` (7.1.6): after a byte above 0x8F, a byte whose seven low
/// bits are all set takes only those seven, the stream starting as if after
/// 0xFF; it ends padded with zeros.
const MagRefWriter = struct {
    bytes: []u8,
    written: usize = 0,
    buffer: u64 = 0,
    count: u7 = 0,
    last_above_8f: bool = true,

    fn put(self: *MagRefWriter, value: u64, n: u8) void {
        self.buffer |= value << @intCast(self.count);
        self.count += @intCast(n);
        while (true) {
            if (self.last_above_8f) {
                if (self.count < 7) return;
                if ((self.buffer & 0x7f) == 0x7f) {
                    self.emit(0x7f, 7);
                    continue;
                }
            }
            if (self.count < 8) return;
            self.emit(@truncate(self.buffer), 8);
        }
    }

    fn emit(self: *MagRefWriter, byte: u8, width: u4) void {
        self.written += 1;
        self.bytes[self.bytes.len - self.written] = byte;
        self.buffer >>= width;
        self.count -= width;
        self.last_above_8f = byte > 0x8f;
    }

    fn finish(self: *MagRefWriter) void {
        if (self.count > 0) self.emit(@truncate(self.buffer), @intCast(self.count));
    }
};

/// What each quad of a row needs before its codewords, none of which
/// depends on the quad to its left: significance rho_q, the exponent bound
/// U_q and residual u_q (7.3.7), and its CxtVLC table index from rho_q,
/// u_off, the samples whose E_n reaches U_q, and the part of the context
/// c_q the line above gives (Formula 2). Computed a vector of quads at a
/// time from the exponent lines.
const QuadRow = struct {
    rho: []u8,
    bound: []u8,
    residual: []u8,
    /// The CxtVLC encode table index of each quad, `vlcEncodeIndex` with
    /// the part of c_q the line above gives (Formula 2).
    index: []u16,
    /// The EMB pattern e_k of each quad's codeword, set as the quads are
    /// coded.
    known: []u8,
    /// Each quad pair's MagSgn bits, from `packMagSgnPairs`.
    mag_sgn_length: []u8,

    const lanes = 16;
    const Bytes = @Vector(lanes, u8);
    const Pairs = @Vector(2 * lanes, u8);

    /// `top`, `bottom`, and `above` are exponent lines in the guard layout
    /// of `quadContext`, zero past the block for whole vectors.
    /// Returns the largest U_q of the row.
    fn analyze(self: QuadRow, initial: bool, top: []const u8, bottom: []const u8, above: []const u8, quad_width: usize) u8 {
        const zero: Bytes = @splat(0);
        const one: Bytes = @splat(1);
        var widest = zero;
        var qx: usize = 0;
        while (qx < quad_width) : (qx += lanes) {
            // Quad q's samples are columns 2q and 2q + 1, at 2q + 1 and
            // 2q + 2 in the guard layout.
            const top_pairs: Pairs = top[2 * qx + 1 ..][0 .. 2 * lanes].*;
            const bottom_pairs: Pairs = bottom[2 * qx + 1 ..][0 .. 2 * lanes].*;
            const exponents = [4]Bytes{
                @shuffle(u8, top_pairs, undefined, evenLanes(lanes)),
                @shuffle(u8, bottom_pairs, undefined, evenLanes(lanes)),
                @shuffle(u8, top_pairs, undefined, oddLanes(lanes)),
                @shuffle(u8, bottom_pairs, undefined, oddLanes(lanes)),
            };
            var rho = zero;
            inline for (0..4) |j| rho |= @select(u8, exponents[j] != zero, @as(Bytes, @splat(1 << j)), zero);
            const largest = @max(@max(exponents[0], exponents[1]), @max(exponents[2], exponents[3]));
            var kappa = one;
            var above_context = zero;
            if (!initial) {
                // The bottom line above: columns 2q - 1 to 2q + 2.
                const near: Pairs = above[2 * qx ..][0 .. 2 * lanes].*;
                const far: Pairs = above[2 * qx + 2 ..][0 .. 2 * lanes].*;
                const west = @shuffle(u8, near, undefined, evenLanes(lanes)) | @shuffle(u8, near, undefined, oddLanes(lanes));
                const east = @shuffle(u8, far, undefined, evenLanes(lanes)) | @shuffle(u8, far, undefined, oddLanes(lanes));
                const above_largest = @max(
                    @max(@shuffle(u8, near, undefined, evenLanes(lanes)), @shuffle(u8, near, undefined, oddLanes(lanes))),
                    @max(@shuffle(u8, far, undefined, evenLanes(lanes)), @shuffle(u8, far, undefined, oddLanes(lanes))),
                );
                // gamma_q: more than one significant sample.
                const several = (rho & (rho -% one)) != zero;
                kappa = @select(u8, several, @select(u8, above_largest > one, above_largest -% one, one), one);
                above_context = @select(u8, west != zero, one, zero) + @select(u8, east != zero, @as(Bytes, @splat(4)), zero);
            }
            const bound = @max(largest, kappa);
            var at_bound = zero;
            inline for (0..4) |j| at_bound |= @select(u8, exponents[j] == bound, @as(Bytes, @splat(1 << j)), zero);
            const residual = @select(u8, rho != zero, bound - kappa, zero);
            self.rho[qx..][0..lanes].* = rho;
            self.bound[qx..][0..lanes].* = bound;
            self.residual[qx..][0..lanes].* = residual;
            const Indices = @Vector(lanes, u16);
            const u_off: Indices = @select(u16, residual != zero, @as(Indices, @splat(1 << 4)), @as(Indices, @splat(0)));
            self.index[qx..][0..lanes].* = (@as(Indices, above_context) << @splat(9)) | (@as(Indices, rho) << @splat(5)) | u_off | @as(Indices, at_bound);
            widest = @max(widest, bound);
        }
        return @reduce(.Max, widest);
    }
};

/// The CxtVLC codewords, MEL symbols, and U-VLC residuals of one quad row
/// (7.3.5 to 7.3.7 run backward), recording each quad's EMB pattern e_k in
/// `row.known`; returns the row's significant samples. The VLC writer's
/// state is copied in and out so that it stays in registers through the
/// row; MEL, coding only where c_q is 0, works in place.
noinline fn codeCodewords(comptime initial: bool, row: QuadRow, quad_width: usize, mel: *MelWriter, vlc_state: *VlcWriter) u32 {
    var vlc = vlc_state.*;
    defer vlc_state.* = vlc;
    const table = if (initial) &cxt_vlc_encode_0 else &cxt_vlc_encode_1;
    const left_contexts = &left_context_indices[@intFromBool(initial)];
    var non_zero_count: u32 = 0;
    var left_rho: u4 = 0;
    var qx: usize = 0;
    while (qx < quad_width) : (qx += 2) {
        const pair = qx + 1 < quad_width;
        // Past the block `QuadRow` reads zero exponents, so a missing second
        // quad is empty; it codes nothing.
        const rhos = [2]u4{ @intCast(row.rho[qx]), @intCast(row.rho[qx + 1]) };
        non_zero_count += @popCount(rhos[0]) + @as(u32, @popCount(rhos[1]));
        const residuals = [2]u8{ row.residual[qx], row.residual[qx + 1] };
        // The pair's VLC bits, at most 38, go out at once.
        var vlc_bits = Bits{};
        inline for (0..2) |i| {
            if (i == 0 or pair) {
                const left = if (i == 0) left_rho else rhos[0];
                const index = row.index[qx + i] | left_contexts[left];
                // encodeSigEMB, the inverse of decodeSigEMB (7.3.5): context
                // 0 codes significance in MEL, and an insignificant quad
                // there no codeword, which its table entry gives as zero
                // bits. The tables code every other quad (tested).
                if (index < 1 << 9) mel.encode(@intFromBool(rhos[i] != 0));
                const code = table[index];
                row.known[qx + i] = code.e_k;
                vlc_bits.add(code.codeword, code.len);
            }
        }
        left_rho = if (pair) rhos[1] else rhos[0];
        if (initial) {
            encodeInitialResiduals(&vlc_bits, mel, residuals);
        } else if ((residuals[0] | residuals[1]) < 16) {
            const code = residual_pairs[(@as(usize, residuals[0]) << 4) | residuals[1]];
            vlc_bits.add(code.bits, code.len);
        } else {
            encodeResiduals(&vlc_bits, residuals);
        }
        vlc.put(vlc_bits.value, vlc_bits.count);
    }
    return non_zero_count;
}

/// The words of `packMagSgnPairs`, `lengths[p]` bits of `words[p]`.
noinline fn putMagSgnPairs(state: *MagSgnWriter, words: []const u64, lengths: []const u8) void {
    var mag_sgn = state.*;
    defer state.* = mag_sgn;
    for (words, lengths[0..words.len]) |word, length| mag_sgn.put(word, length);
}

/// The MagSgn bits of one quad row quad by quad: a quad's at once while
/// they fit, an insignificant sample adding none, an empty quad nothing.
noinline fn putMagSgnQuads(comptime Magnitude: type, state: *MagSgnWriter, row: QuadRow, top: []const Magnitude, bottom: []const Magnitude, quad_width: usize) void {
    var mag_sgn = state.*;
    defer state.* = mag_sgn;
    for (0..quad_width) |q| {
        const rho: u4 = @intCast(row.rho[q]);
        const known: u4 = @intCast(row.known[q]);
        const bound = row.bound[q];
        const total = @as(u16, bound) * @popCount(rho) - @popCount(known);
        if (total <= 56) {
            var bits = Bits{};
            inline for (0..4) |j| {
                const n = magSgnLength(rho, known, bound, j);
                const value: u64 = (if ((j & 1) != 0) bottom else top)[2 * q + (j >> 1)];
                bits.add(value & ((@as(u64, 1) << @intCast(n)) - 1), n);
            }
            mag_sgn.put(bits.value, bits.count);
        } else {
            // Wide magnitudes: sample by sample.
            inline for (0..4) |j| {
                const value: u64 = (if ((j & 1) != 0) bottom else top)[2 * q + (j >> 1)];
                mag_sgn.putWide(value, magSgnLength(rho, known, bound, j));
            }
        }
    }
}

/// The part of c_q a quad's left neighbour gives, shifted into a
/// `vlcEncodeIndex`, by the neighbour's rho_q: in the initial row and
/// outside it (Formula 1 and 2).
const left_context_indices = blk: {
    var indices: [2][16]u16 = undefined;
    for (0..16) |left| {
        const rho: u4 = @intCast(left);
        const w = (rho >> 2) & 1;
        const sw = (rho >> 3) & 1;
        indices[0][left] = @as(u16, 2 * (w | sw)) << 9;
        indices[1][left] = @as(u16, ((rho & 1) | ((rho >> 1) & 1)) + 2 * @as(u16, w) + 4 * @as(u16, sw)) << 9;
    }
    break :blk indices;
};

/// `encodeResiduals` outside the initial row for both residuals below 16,
/// which code no extension: at most 16 bits.
const residual_pairs = blk: {
    @setEvalBranchQuota(10_000);
    var codes: [256]struct { bits: u16, len: u8 } = undefined;
    for (0..16) |first| {
        for (0..16) |second| {
            var bits = Bits{};
            encodeResiduals(&bits, .{ first, second });
            codes[(first << 4) | second] = .{ .bits = @intCast(bits.value), .len = bits.count };
        }
    }
    break :blk codes;
};

/// The U-VLC codes of one quad pair outside the initial row (7.3.6), the
/// inverse of the decoder's residual decoding: prefixes, then suffixes, then
/// extensions; a zero residual codes nothing.
inline fn encodeResiduals(vlc: *Bits, residuals: [2]u8) void {
    const codes = [2]UCode{ u_codes[residuals[0]], u_codes[residuals[1]] };
    vlc.add(codes[0].prefix, codes[0].prefix_len);
    vlc.add(codes[1].prefix, codes[1].prefix_len);
    vlc.add(codes[0].suffix, codes[0].suffix_len);
    vlc.add(codes[1].suffix, codes[1].suffix_len);
    vlc.add(codes[0].extension, codes[0].extension_len);
    vlc.add(codes[1].extension, codes[1].extension_len);
}

/// `encodeResiduals` in the initial row, where a pair with u_off = 1 in both
/// quads first codes in MEL whether both residuals exceed 2.
inline fn encodeInitialResiduals(vlc: *Bits, mel: *MelWriter, residuals: [2]u8) void {
    var first = residuals[0];
    var second = residuals[1];
    if (first != 0 and second != 0) {
        const both_large = first > 2 and second > 2;
        mel.encode(@intFromBool(both_large));
        if (both_large) {
            first -= 2;
            second -= 2;
        } else if (first > 2) {
            // The second residual is 1 or 2, one bit after a three-bit
            // first prefix.
            const code = u_codes[first];
            vlc.add(code.prefix, code.prefix_len);
            vlc.add(second - 1, 1);
            vlc.add(code.suffix, code.suffix_len);
            vlc.add(code.extension, code.extension_len);
            return;
        }
    }
    encodeResiduals(vlc, .{ first, second });
}

/// The MagSgn bits of each quad pair packed into `words`, first quad and
/// sample 0 lowest, and their count into `row.mag_sgn_length`, a vector of
/// quads at a time, for a row whose U_q are at most 7: 28 bits a quad. The
/// value lines run on past the block for whole vectors, where the quads
/// are empty.
fn packMagSgnPairs(comptime Magnitude: type, row: QuadRow, top: []const Magnitude, bottom: []const Magnitude, words: []u64, quad_width: usize) void {
    const lanes = 16;
    const Bytes = @Vector(lanes, u8);
    const Lanes = @Vector(lanes, u32);
    const Shifts = @Vector(lanes, u5);
    const Values = @Vector(2 * lanes, Magnitude);
    const Pairs = @Vector(lanes / 2, u64);
    const one: Lanes = @splat(1);
    var q: usize = 0;
    while (q < quad_width) : (q += lanes) {
        const top_pairs: Values = top[2 * q ..][0 .. 2 * lanes].*;
        const bottom_pairs: Values = bottom[2 * q ..][0 .. 2 * lanes].*;
        // Sample j of a quad: left column top and bottom, then right; below
        // 2^U_q, so 2^7.
        const samples = [4]Lanes{
            @truncate(@shuffle(Magnitude, top_pairs, undefined, evenLanes(lanes))),
            @truncate(@shuffle(Magnitude, bottom_pairs, undefined, evenLanes(lanes))),
            @truncate(@shuffle(Magnitude, top_pairs, undefined, oddLanes(lanes))),
            @truncate(@shuffle(Magnitude, bottom_pairs, undefined, oddLanes(lanes))),
        };
        const rho: Bytes = row.rho[q..][0..lanes].*;
        const known: Bytes = row.known[q..][0..lanes].*;
        const bound: Bytes = row.bound[q..][0..lanes].*;
        var word: Lanes = @splat(0);
        var offset: Lanes = @splat(0);
        inline for (0..4) |j| {
            const significant = (rho >> @splat(j)) & @as(Bytes, @splat(1));
            const implicit = (known >> @splat(j)) & @as(Bytes, @splat(1));
            const n: Lanes = (bound - implicit) & (@as(Bytes, @splat(0)) -% significant);
            word |= (samples[j] & ((one << @as(Shifts, @intCast(n))) - one)) << @as(Shifts, @intCast(offset));
            offset += n;
        }
        const first: Pairs = @shuffle(u32, word, undefined, evenLanes(lanes / 2));
        const second: Pairs = @shuffle(u32, word, undefined, oddLanes(lanes / 2));
        const first_length: Pairs = @shuffle(u32, offset, undefined, evenLanes(lanes / 2));
        const second_length: Pairs = @shuffle(u32, offset, undefined, oddLanes(lanes / 2));
        words[q / 2 ..][0 .. lanes / 2].* = first | (second << @as(@Vector(lanes / 2, u6), @intCast(first_length)));
        const lengths: @Vector(lanes / 2, u8) = @intCast(first_length + second_length);
        row.mag_sgn_length[q / 2 ..][0 .. lanes / 2].* = lengths;
    }
}

/// Shuffle masks picking the even and the odd lanes of twice `lanes`.
fn evenLanes(comptime lanes: usize) @Vector(lanes, i32) {
    var mask: [lanes]i32 = undefined;
    for (&mask, 0..) |*index, lane| index.* = @intCast(2 * lane);
    return mask;
}

fn oddLanes(comptime lanes: usize) @Vector(lanes, i32) {
    var mask: [lanes]i32 = undefined;
    for (&mask, 0..) |*index, lane| index.* = @intCast(2 * lane + 1);
    return mask;
}

/// The MagSgn bits of a quad's sample `j`: U_q less an implicit top bit,
/// none for an insignificant sample.
inline fn magSgnLength(rho: u4, known: u4, bound: u8, comptime j: u2) u8 {
    const significant: u8 = (rho >> j) & 1;
    const implicit: u8 = (known >> j) & 1;
    return (bound - implicit) & (0 -% significant);
}

/// Bits gathered least significant first before a writer takes them.
const Bits = struct {
    value: u64 = 0,
    count: u8 = 0,

    /// `bits` has no bits above the `n` it adds; at most 56 in all.
    inline fn add(self: *Bits, bits: u64, n: u8) void {
        self.value |= bits << @intCast(self.count);
        self.count += n;
    }
};

/// `UCode.of` for every residual up to the largest Table 3 codes, 96.
const u_codes = blk: {
    var codes: [256]UCode = @splat(.{});
    for (0..97) |u| codes[u] = UCode.of(u);
    break :blk codes;
};

/// Table 3: u = 1 is "1", 2 is "01", 3 and 4 are "001" and a one-bit
/// suffix, 5 and above "000", a five-bit suffix, and from a suffix of 28 a
/// four-bit extension (u = 5 + suffix + 4 extension). Zero codes nothing.
const UCode = struct {
    prefix: u8 = 0,
    prefix_len: u8 = 0,
    suffix: u8 = 0,
    suffix_len: u8 = 0,
    extension: u8 = 0,
    extension_len: u8 = 0,

    fn of(u: u8) UCode {
        return switch (u) {
            0 => .{},
            1 => .{ .prefix = 1, .prefix_len = 1 },
            2 => .{ .prefix = 2, .prefix_len = 2 },
            3, 4 => .{ .prefix = 4, .prefix_len = 3, .suffix = u - 3, .suffix_len = 1 },
            else => if (u - 5 < 28)
                .{ .prefix = 0, .prefix_len = 3, .suffix = u - 5, .suffix_len = 5 }
            else
                .{
                    .prefix = 0,
                    .prefix_len = 3,
                    .suffix = 28 + (u - 33) % 4,
                    .suffix_len = 5,
                    .extension = (u - 33) / 4,
                    .extension_len = 4,
                },
        };
    }
};

/// MagSgn bits least significant first; a byte after 0xFF holds seven
/// (7.1.2). The stream ends padded with ones, without a final 0xFF, which
/// the decoder supplies. `bytes` is sized for the block in advance, with
/// eight bytes to spare: the bits go out a whole word at a time.
const MagSgnWriter = struct {
    bytes: []u8,
    position: usize = 0,
    buffer: u64 = 0,
    /// Fewer than eight between calls.
    count: u7 = 0,
    last_ff: bool = false,

    /// `value` has no bits above the `n <= 56` it codes.
    inline fn put(self: *MagSgnWriter, value: u64, n: u8) void {
        self.buffer |= value << @intCast(self.count);
        self.count += @intCast(n);
        const whole: u6 = @intCast(self.count & ~@as(u7, 7));
        // The whole bytes in one store unless one is 0xFF, which stuffs
        // the next.
        const ready = self.buffer & ((@as(u64, 1) << whole) - 1);
        if (!self.last_ff and !hasFf(ready)) {
            std.mem.writeInt(u64, self.bytes[self.position..][0..8], self.buffer, .little);
            self.position += whole >> 3;
            self.buffer >>= whole;
            self.count -= whole;
        } else {
            while (self.count >= @as(u7, 8) - @intFromBool(self.last_ff)) self.flush();
        }
    }

    /// The low `n <= 64` bits of `value`.
    inline fn putWide(self: *MagSgnWriter, value: u64, n: u8) void {
        if (n > 32) {
            self.put(value & 0xffff_ffff, 32);
            self.put((value >> 32) & ((@as(u64, 1) << @intCast(n - 32)) - 1), n - 32);
        } else {
            self.put(value & ((@as(u64, 1) << @intCast(n)) - 1), n);
        }
    }

    inline fn flush(self: *MagSgnWriter) void {
        const width: u4 = if (self.last_ff) 7 else 8;
        const byte: u8 = @truncate(self.buffer & ((@as(u64, 1) << width) - 1));
        self.bytes[self.position] = byte;
        self.position += 1;
        self.buffer >>= width;
        self.count -= width;
        self.last_ff = byte == 0xff;
    }

    /// The SigProp end: the last bits padded with zeros, which the decoder
    /// reads past the stream's end anyway, and after a final 0xFF a zero
    /// byte, since a codeword segment may neither end in 0xFF nor follow it
    /// with a byte above 0x8F, as the MagRef bytes after it might.
    fn finishWithZeros(self: *MagSgnWriter) void {
        while (self.count >= @as(u7, 8) - @intFromBool(self.last_ff)) self.flush();
        if (self.count > 0 or self.last_ff) {
            self.bytes[self.position] = @truncate(self.buffer);
            self.position += 1;
            self.count = 0;
            self.buffer = 0;
            self.last_ff = false;
        }
    }

    fn finish(self: *MagSgnWriter) void {
        if (self.count > 0) {
            const width: u4 = if (self.last_ff) 7 else 8;
            const full = (@as(u16, 1) << width) - 1;
            const low = (@as(u16, 1) << @intCast(self.count)) - 1;
            const byte: u8 = @intCast((@as(u16, @truncate(self.buffer)) & low) | (full & ~low));
            if (byte != 0xff) {
                self.bytes[self.position] = byte;
                self.position += 1;
            }
            self.count = 0;
            self.buffer = 0;
        } else if (self.last_ff) {
            self.position -= 1;
        }
    }
};

/// Whether any byte of `word` is 0xFF.
inline fn hasFf(word: u64) bool {
    // A byte is 0xFF exactly when its complement is zero.
    const ones = ~word;
    return ((ones -% 0x0101_0101_0101_0101) & ~ones & 0x8080_8080_8080_8080) != 0;
}

/// encodeMELSym, the run-length coder that `MelDecoder` inverts (7.3.3),
/// with its bits most significant first (7.1.3).
const MelWriter = struct {
    bytes: []u8,
    position: usize = 0,
    current: u8 = 0,
    remaining: u4 = 8,
    run: u32 = 0,
    k: u8 = 0,

    inline fn emit(self: *MelWriter, bit: u1) void {
        self.current = (self.current << 1) | bit;
        self.remaining -= 1;
        if (self.remaining == 0) self.flush();
    }

    inline fn flush(self: *MelWriter) void {
        self.bytes[self.position] = self.current;
        self.position += 1;
        self.remaining = if (self.current == 0xff) 7 else 8;
        self.current = 0;
    }

    inline fn encode(self: *MelWriter, symbol: u1) void {
        const exponent = MelDecoder.exponents[self.k];
        if (symbol == 0) {
            self.run += 1;
            if (self.run == @as(u32, 1) << @intCast(exponent)) {
                self.emit(1);
                self.run = 0;
                self.k = @min(12, self.k + 1);
            }
            return;
        }
        self.emitRun(exponent);
    }

    inline fn emitRun(self: *MelWriter, exponent: u8) void {
        self.emit(0);
        var bit = exponent;
        while (bit > 0) {
            bit -= 1;
            self.emit(@intCast((self.run >> @intCast(bit)) & 1));
        }
        self.run = 0;
        self.k -|= 1;
    }
};

/// VLC bits least significant first into bytes stored from the end of
/// `bytes` backward (7.1.4): the first byte is the one whose twelve Scup
/// bits read as ones, and after a byte above 0x8F a byte whose seven low
/// bits are all set takes only those seven. Eight bytes before the stream
/// stay spare: the bits go out a whole word at a time.
const VlcWriter = struct {
    bytes: []u8,
    written: usize,
    buffer: u64,
    /// Fewer than eight between calls.
    count: u7,
    last_above_8f: bool,

    fn init(bytes: []u8) VlcWriter {
        bytes[bytes.len - 1] = 0xff;
        return .{ .bytes = bytes, .written = 1, .buffer = 0x0f, .count = 4, .last_above_8f = true };
    }

    /// `value` has no bits above the `n <= 56` it codes.
    inline fn put(self: *VlcWriter, value: u64, n: u8) void {
        self.buffer |= value << @intCast(self.count);
        self.count += @intCast(n);
        const whole: u6 = @intCast(self.count & ~@as(u7, 7));
        // The whole bytes in one store unless one has its seven low bits
        // set, the only kind that can be stuffed; seven pending bits that
        // will be wait for the next call or `settle`.
        const ready = (self.buffer | 0x8080_8080_8080_8080) & ((@as(u64, 1) << whole) - 1);
        if (!hasFf(ready)) {
            const end = self.bytes.len - self.written;
            std.mem.writeInt(u64, self.bytes[end - 8 ..][0..8], self.buffer, .big);
            self.written += whole >> 3;
            const last: u8 = @truncate(self.buffer >> (whole -% 8));
            self.last_above_8f = if (whole != 0) last > 0x8f else self.last_above_8f;
            self.buffer >>= whole;
            self.count -= whole;
        } else {
            self.settle();
        }
    }

    /// Writes every byte the pending bits complete.
    inline fn settle(self: *VlcWriter) void {
        while (true) {
            if (self.last_above_8f) {
                if (self.count < 7) return;
                // Seven bits after a byte above 0x8F: an eighth unless
                // they are all ones, which the decoder reads as a stuffed
                // byte.
                if ((self.buffer & 0x7f) == 0x7f) {
                    self.emit(0x7f, 7);
                    continue;
                }
            }
            if (self.count < 8) return;
            self.emit(@truncate(self.buffer), 8);
        }
    }

    inline fn emit(self: *VlcWriter, byte: u8, width: u4) void {
        self.written += 1;
        self.bytes[self.bytes.len - self.written] = byte;
        self.buffer >>= width;
        self.count -= width;
        self.last_above_8f = byte > 0x8f;
    }
};

/// The MEL stream's last byte and the VLC stream's first share a byte when
/// their bits do not overlap (OpenJPH's termination, which every HT decoder
/// reads, since each stream ignores the other's bits past its own end).
fn terminateMelVlc(mel: *MelWriter, vlc: *VlcWriter) void {
    if (mel.run > 0) mel.emit(1);
    const mel_bits: u8 = @intCast((@as(u16, mel.current) << mel.remaining) & 0xff);
    const mel_mask: u8 = @intCast((@as(u16, 0xff) << mel.remaining) & 0xff);
    const vlc_bits: u8 = @truncate(vlc.buffer);
    const vlc_mask: u8 = @intCast(@as(u16, 0xff) >> @intCast(8 - vlc.count));
    if ((mel_mask | vlc_mask) == 0) return;
    const fused = mel_bits | vlc_bits;
    if ((((fused ^ mel_bits) & mel_mask) | ((fused ^ vlc_bits) & vlc_mask)) == 0 and
        fused != 0xff and vlc.written > 1)
    {
        mel.bytes[mel.position] = fused;
        mel.position += 1;
    } else {
        mel.bytes[mel.position] = mel_bits;
        mel.position += 1;
        vlc.written += 1;
        vlc.bytes[vlc.bytes.len - vlc.written] = vlc_bits;
    }
}

/// A CxtVLC codeword chosen for coding, and the EMB pattern it carries.
const VlcCode = struct {
    codeword: u7 = 0,
    /// Zero where no codeword fits.
    len: u8 = 0,
    e_k: u4 = 0,
    e_1: u4 = 0,
};

inline fn vlcEncodeIndex(context: u8, rho: u4, u_off: u1, at_bound: u4) usize {
    return (@as(usize, context) << 9) | (@as(usize, rho) << 5) | (@as(usize, u_off) << 4) | at_bound;
}

/// Indexed by c_q, rho_q, u_off, and the significant samples whose E_n
/// reaches U_q: the codeword of each context's table that is valid for them
/// (eps_1 = eps_k & at_bound, so every implicit top bit is right) and costs
/// the fewest bits, counting the MagSgn bit each eps_k bit saves.
fn buildEncodeTable(comptime table: []const CxtVlcEntry) [8 * 16 * 2 * 16]VlcCode {
    @setEvalBranchQuota(1_000_000);
    var codes: [8 * 16 * 2 * 16]VlcCode = @splat(.{});
    for (table) |entry| {
        for (0..16) |pattern| {
            const at_bound: u4 = @intCast(pattern);
            if ((at_bound & ~entry.rho) != 0 or (at_bound & entry.e_k) != entry.e_1) continue;
            const slot = &codes[vlcEncodeIndex(entry.context, entry.rho, entry.u_off, at_bound)];
            const cost = @as(i32, entry.len) - @popCount(entry.e_k);
            if (slot.len == 0 or cost < @as(i32, slot.len) - @popCount(slot.e_k)) {
                slot.* = .{ .codeword = entry.codeword, .len = entry.len, .e_k = entry.e_k, .e_1 = entry.e_1 };
            }
        }
    }
    return codes;
}

const cxt_vlc_encode_0 = buildEncodeTable(&cxt_vlc_table_0);
const cxt_vlc_encode_1 = buildEncodeTable(&cxt_vlc_table_1);

const flag_significant: u8 = 0x01;
const flag_negative: u8 = 0x02;
/// z_n: the sample was visited by SigProp or MagRef.
const flag_refined: u8 = 0x04;
/// r_n: the refinement bit decoded for it.
const flag_refinement_bit: u8 = 0x08;

const Quad = struct {
    rho: u4 = 0,
    u_off: u1 = 0,
    e_k: u4 = 0,
    e_1: u4 = 0,
};

/// The context c_q of Formulas (1) and (2). `left_rho` is the significance
/// of the quad to the left (zero for the first quad of a row); `above` holds
/// the previous quad row's bottom line with a zero guard column either side,
/// so column x is at index x + 1.
inline fn quadContext(initial: bool, left_rho: u4, above: []const u8, qx: usize) u8 {
    const w: u8 = (left_rho >> 2) & 1;
    const sw: u8 = (left_rho >> 3) & 1;
    if (initial) {
        const f: u8 = left_rho & 1;
        const sf: u8 = (left_rho >> 1) & 1;
        return (f | sf) + 2 * w + 4 * sw;
    }
    const c = 2 * qx + 1;
    return (above[c - 1] | above[c]) + 2 * (w | sw) + 4 * (above[c + 1] | above[c + 2]);
}

/// decodeSigEMB (7.3.5).
inline fn decodeSignificance(vlc: *VlcReader, mel: *MelDecoder, context: u8, initial: bool) Error!Quad {
    if (context == 0 and try mel.decode() == 0) return .{};
    const entry = (if (initial) &cxt_vlc_lookup_0 else &cxt_vlc_lookup_1)[(@as(usize, context) << 7) | try vlc.peek(7)];
    if (entry.len == 0) return Error.InvalidBlock;
    try vlc.skip(entry.len);
    return .{ .rho = entry.rho, .u_off = entry.u_off, .e_k = entry.e_k, .e_1 = entry.e_1 };
}

/// kappa_q + u_q (7.3.7), with the exponents of the line above in the
/// guard layout of `quadContext`.
inline fn exponentBound(rho: u4, u: u8, initial: bool, above: []const u8, qx: usize) u8 {
    var kappa: u8 = 1;
    // gamma_q: more than one significant sample.
    if (!initial and @popCount(rho) > 1) {
        const c = 2 * qx + 1;
        const largest = @max(@max(above[c - 1], above[c]), @max(above[c + 1], above[c + 2]));
        if (largest > 1) kappa = largest - 1;
    }
    return kappa + u;
}

/// E_n of Table 1: the smallest E with 2 mu - 1 < 2^E.
fn magnitudeExponent(magnitude: u64) u8 {
    if (magnitude == 0) return 0;
    return @intCast(65 - @clz(magnitude - 1));
}

/// The U-VLC prefix of Table 3 from one look-ahead: "1", "01", "001", "000".
inline fn decodeUPrefix(vlc: *VlcReader) Error!u8 {
    const look = try vlc.peek(3);
    if ((look & 1) != 0) {
        try vlc.skip(1);
        return 1;
    }
    if ((look & 2) != 0) {
        try vlc.skip(2);
        return 2;
    }
    try vlc.skip(3);
    return if ((look & 4) != 0) 3 else 5;
}

inline fn decodeUSuffix(vlc: *VlcReader, prefix: u8) Error!u8 {
    if (prefix < 3) return 0;
    if (prefix == 3) return try vlc.bit();
    return @intCast(try vlc.bits(5));
}

inline fn decodeUExtension(vlc: *VlcReader, suffix: u8) Error!u8 {
    if (suffix < 28) return 0;
    return @intCast(try vlc.bits(4));
}

/// The HT cleanup segment's suffix length and modified last two bytes
/// (7.1.1).
const CleanupSegment = struct {
    bytes: []const u8,
    prefix_length: usize,

    fn init(bytes: []const u8) Error!CleanupSegment {
        try checkSegmentBytes(bytes, max_cleanup_length);
        if (bytes.len < 2) return Error.InvalidBlock;
        const suffix_length = (@as(usize, bytes[bytes.len - 1]) << 4) | (bytes[bytes.len - 2] & 0x0f);
        if (suffix_length < 2 or suffix_length > @min(bytes.len, 4079)) return Error.InvalidBlock;
        const prefix_length = bytes.len - suffix_length;
        if (prefix_length > 0 and bytes[prefix_length - 1] == 0xff) return Error.InvalidBlock;
        return .{ .bytes = bytes, .prefix_length = prefix_length };
    }

    /// modDcup: the last byte reads as 0xFF and the low nibble of the one
    /// before it as ones, once Scup has been taken from them.
    fn byte(self: CleanupSegment, position: usize) u8 {
        if (position == self.bytes.len - 1) return 0xff;
        if (position == self.bytes.len - 2) return self.bytes[position] | 0x0f;
        return self.bytes[position];
    }
};

/// No HT segment has a byte pair above 0xFF8F or ends in 0xFF (7.1.1).
fn checkSegmentBytes(bytes: []const u8, max_length: usize) Error!void {
    if (bytes.len > max_length) return Error.InvalidBlock;
    if (bytes.len == 0) return;
    if (bytes[bytes.len - 1] == 0xff) return Error.InvalidBlock;
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, start, 0xff)) |index| {
        // Not the last byte, checked above.
        if (bytes[index + 1] > 0x8f) return Error.InvalidBlock;
        start = index + 1;
    }
}

/// importMagSgnBit (7.1.2) and importSigPropBit (7.1.5): bits least
/// significant first, a byte after 0xFF giving only its seven low bits,
/// whose stuffed top bit must be 0.
const ForwardReader = struct {
    bytes: []const u8,
    /// MagSgn reads one 0xFF past its bytes and nothing after it; SigProp
    /// reads zeros past its bytes.
    synthesize_ff: bool,
    position: usize = 0,
    last: u8 = 0,
    buffer: u64 = 0,
    count: u7 = 0,

    fn load(self: *ForwardReader) Error!void {
        // Four bytes at once when none but the last is 0xFF, so that each
        // gives all eight bits.
        if (self.last != 0xff and self.count <= 32 and self.bytes.len - @min(self.position, self.bytes.len) >= 4) {
            const word = std.mem.readInt(u32, self.bytes[self.position..][0..4], .little);
            if ((word & 0xff) != 0xff and ((word >> 8) & 0xff) != 0xff and ((word >> 16) & 0xff) != 0xff) {
                self.buffer |= @as(u64, word) << @intCast(self.count);
                self.count += 32;
                self.position += 4;
                self.last = @truncate(word >> 24);
                return;
            }
        }
        const width: u4 = if (self.last == 0xff) 7 else 8;
        var value: u8 = 0;
        if (self.position < self.bytes.len) {
            value = self.bytes[self.position];
            if (width == 7 and (value & 0x80) != 0) return Error.InvalidBlock;
        } else if (self.synthesize_ff) {
            if (self.position > self.bytes.len) return Error.InvalidBlock;
            value = 0xff;
        }
        self.position += 1;
        self.last = value;
        const unpacked = @as(u64, value) & ((@as(u64, 1) << width) - 1);
        self.buffer |= unpacked << @intCast(self.count);
        self.count += width;
    }

    fn bit(self: *ForwardReader) Error!u1 {
        return @intCast(try self.bits(1));
    }

    /// The next `n <= 64` bits, the first one least significant.
    inline fn bits(self: *ForwardReader, n: u8) Error!u64 {
        if (n > 32) return self.wideBits(n);
        if (self.count < n) {
            @branchHint(.unlikely);
            try self.load();
            while (self.count < n) try self.load();
        }
        const value = self.buffer & ((@as(u64, 1) << @intCast(n)) - 1);
        self.buffer >>= @intCast(n);
        self.count -= @intCast(n);
        return value;
    }

    fn wideBits(self: *ForwardReader, n: u8) Error!u64 {
        const low = try self.bits(32);
        return low | (try self.bits(n - 32)) << 32;
    }
};

/// importMELBit and decodeMELSym (7.1.3, 7.3.3).
const MelDecoder = struct {
    reader: MelReader,
    k: u8 = 0,
    run: u32 = 0,
    one: bool = false,

    const exponents = [13]u8{ 0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 4, 5 };

    fn decode(self: *MelDecoder) Error!u1 {
        if (self.run == 0 and !self.one) {
            var exponent = exponents[self.k];
            if (self.reader.bit() == 1) {
                self.run = @as(u32, 1) << @intCast(exponent);
                self.k = @min(12, self.k + 1);
            } else {
                self.run = 0;
                while (exponent > 0) : (exponent -= 1) {
                    self.run = 2 * self.run + self.reader.bit();
                }
                self.k -|= 1;
                self.one = true;
            }
        }
        if (self.run > 0) {
            self.run -= 1;
            return 0;
        }
        self.one = false;
        return 1;
    }
};

/// Bits most significant first from Pcup on, 0xFF past the segment.
const MelReader = struct {
    segment: CleanupSegment,
    position: usize,
    current: u8 = 0,
    remaining: u4 = 0,

    fn bit(self: *MelReader) u1 {
        if (self.remaining == 0) {
            self.remaining = if (self.current == 0xff) 7 else 8;
            if (self.position < self.segment.bytes.len) {
                self.current = self.segment.byte(self.position);
                self.position += 1;
            } else {
                self.current = 0xff;
            }
        }
        self.remaining -= 1;
        return @intCast((self.current >> @intCast(self.remaining)) & 1);
    }
};

/// importVLCBit (7.1.4): bits least significant first from bytes read
/// backward from Lcup - 2, skipping the twelve Scup bits and a stuffed top
/// bit after a byte above 0x8F.
const VlcReader = struct {
    segment: CleanupSegment,
    /// The next byte to load; below Pcup the stream has ended.
    position: isize,
    last: u8,
    buffer: u64,
    count: u7,
    /// Bits loaded past the end of the stream for a look-ahead, which must
    /// not be consumed.
    padding: u7 = 0,

    fn init(segment: CleanupSegment) VlcReader {
        const last = segment.byte(segment.bytes.len - 2);
        const first = last >> 4;
        const width: u7 = if ((first & 7) < 7) 4 else 3;
        return .{
            .segment = segment,
            .position = @as(isize, @intCast(segment.bytes.len)) - 3,
            .last = last,
            .buffer = first & ((@as(u64, 1) << @intCast(width)) - 1),
            .count = width,
        };
    }

    fn load(self: *VlcReader) void {
        // Four bytes at once, read backward, when none has its seven low bits
        // set: then none loses a stuffing bit whatever came before it. The
        // bytes below Lcup - 2 are never the ones modDcup changes.
        const lowest = self.position - 3;
        if (self.count <= 32 and lowest >= @as(isize, @intCast(self.segment.prefix_length))) {
            const word = std.mem.readInt(u32, self.segment.bytes[@intCast(lowest)..][0..4], .big);
            if (!hasLowSevenSet(word)) {
                self.buffer |= @as(u64, word) << @intCast(self.count);
                self.count += 32;
                self.position -= 4;
                self.last = @truncate(word >> 24);
                return;
            }
        }
        if (self.position < @as(isize, @intCast(self.segment.prefix_length))) {
            self.count += 8;
            self.padding += 8;
            return;
        }
        const value = self.segment.byte(@intCast(self.position));
        const width: u4 = if (self.last > 0x8f and (value & 0x7f) == 0x7f) 7 else 8;
        self.last = value;
        self.position -= 1;
        const unpacked = @as(u64, value) & ((@as(u64, 1) << width) - 1);
        self.buffer |= unpacked << @intCast(self.count);
        self.count += width;
    }

    inline fn fill(self: *VlcReader, n: u7) void {
        while (self.count < n) self.load();
    }

    /// The next `n` bits without consuming them; bits past the stream's
    /// end read as zero here and fail in `skip`.
    fn peek(self: *VlcReader, comptime n: u7) Error!usize {
        self.fill(n);
        return @intCast(self.buffer & ((1 << n) - 1));
    }

    fn skip(self: *VlcReader, n: u7) Error!void {
        self.fill(n);
        if (self.count - self.padding < n) return Error.InvalidBlock;
        self.buffer >>= @intCast(n);
        self.count -= n;
    }

    fn bit(self: *VlcReader) Error!u1 {
        return @intCast(try self.bits(1));
    }

    fn bits(self: *VlcReader, n: u7) Error!u64 {
        self.fill(n);
        const value = self.buffer & ((@as(u64, 1) << @intCast(n)) - 1);
        try self.skip(n);
        return value;
    }
};

/// Whether any byte of `word` has its seven low bits all set.
inline fn hasLowSevenSet(word: u32) bool {
    inline for (0..4) |i| {
        if (((word >> (8 * i)) & 0x7f) == 0x7f) return true;
    }
    return false;
}

/// importMagRefBit (7.1.6): bits least significant first from the end of
/// the refinement segment backward, zeros before its start.
const MagRefReader = struct {
    bytes: []const u8,
    position: isize,
    last: u8 = 0xff,
    current: u8 = 0,
    remaining: u4 = 0,

    fn init(bytes: []const u8) MagRefReader {
        return .{ .bytes = bytes, .position = @as(isize, @intCast(bytes.len)) - 1 };
    }

    fn bit(self: *MagRefReader) u1 {
        if (self.remaining == 0) {
            var value: u8 = 0;
            if (self.position >= 0) {
                value = self.bytes[@intCast(self.position)];
                self.position -= 1;
            }
            self.remaining = if (self.last > 0x8f and (value & 0x7f) == 0x7f) 7 else 8;
            self.last = value;
            self.current = value;
        }
        const result: u1 = @intCast(self.current & 1);
        self.current >>= 1;
        self.remaining -= 1;
        return result;
    }
};

/// The HT SigProp pass (7.4): four-line stripes, four-column groups, a
/// magnitude step then a sign step over each group.
fn decodeSigProp(flags: []u8, stride: usize, block: Block, reader: *ForwardReader) Error!void {
    const width = block.width;
    const height = block.height;
    var stripe: usize = 0;
    while (stripe < height) : (stripe += 4) {
        const stripe_end = @min(stripe + 4, height);
        // Vertically causal context leaves out the next stripe.
        const below_limit = if (block.vertical_causal) stripe_end else height;
        var group: usize = 0;
        while (group < width) : (group += 4) {
            const group_end = @min(group + 4, width);
            for (group..group_end) |x| {
                for (stripe..stripe_end) |y| {
                    const location = y * stride + x;
                    if ((flags[location] & flag_significant) != 0) continue;
                    if (!sigPropNeighbourhood(flags, stride, width, below_limit, x, y)) continue;
                    flags[location] |= flag_refined;
                    if (try reader.bit() == 1) flags[location] |= flag_refinement_bit;
                }
            }
            for (group..group_end) |x| {
                for (stripe..stripe_end) |y| {
                    const location = y * stride + x;
                    if ((flags[location] & flag_significant) != 0 or (flags[location] & flag_refinement_bit) == 0) continue;
                    if (try reader.bit() == 1) flags[location] |= flag_negative;
                }
            }
        }
    }
}

/// Whether a cleanup-significant sample neighbours (x, y), or a sample
/// earlier in the stripe scan that SigProp made significant. During SigProp
/// only samples already scanned carry a refinement bit, so every one found
/// is in the scan-causal neighbourhood.
fn sigPropNeighbourhood(
    flags: []const u8,
    stride: usize,
    width: usize,
    below_limit: usize,
    x: usize,
    y: usize,
) bool {
    const x0 = if (x > 0) x - 1 else x;
    const x1 = @min(x + 1, width - 1);
    const y0 = if (y > 0) y - 1 else y;
    const y1 = @min(y + 1, below_limit - 1);
    for (y0..y1 + 1) |ny| {
        for (x0..x1 + 1) |nx| {
            if (nx == x and ny == y) continue;
            if ((flags[ny * stride + nx] & (flag_significant | flag_refinement_bit)) != 0) return true;
        }
    }
    return false;
}

/// The HT MagRef pass (7.5): one bit for each cleanup-significant sample,
/// in stripe scan order.
fn decodeMagRef(flags: []u8, stride: usize, block: Block, reader: *MagRefReader) void {
    var stripe: usize = 0;
    while (stripe < block.height) : (stripe += 4) {
        const stripe_end = @min(stripe + 4, block.height);
        for (0..block.width) |x| {
            for (stripe..stripe_end) |y| {
                const location = y * stride + x;
                if ((flags[location] & flag_significant) == 0) continue;
                flags[location] |= flag_refined;
                if (reader.bit() == 1) flags[location] |= flag_refinement_bit;
            }
        }
    }
}

test "CxtVLC lookups resolve every context and look-ahead" {
    // Each context's prefix code is complete (its Kraft sum is 1) with
    // codewords of at most seven bits, so no look-ahead stays unmatched.
    for ([_]*const [8 * 128]VlcMatch{ &cxt_vlc_lookup_0, &cxt_vlc_lookup_1 }) |lookup| {
        for (lookup) |entry| try std.testing.expect(entry.len != 0);
    }
    try std.testing.expectEqual(@as(usize, 444), cxt_vlc_table_0.len);
    try std.testing.expectEqual(@as(usize, 358), cxt_vlc_table_1.len);
}

test "CxtVLC encode tables code every quad the cleanup encoder meets" {
    for ([_]*const [8 * 16 * 2 * 16]VlcCode{ &cxt_vlc_encode_0, &cxt_vlc_encode_1 }) |table| {
        for (0..8) |context| {
            for (0..16) |rho_index| {
                const rho: u4 = @intCast(rho_index);
                // Context 0 codes an insignificant quad with MEL alone.
                if (rho == 0) {
                    if (context != 0) try std.testing.expect(table[vlcEncodeIndex(@intCast(context), 0, 0, 0)].len != 0);
                    continue;
                }
                for (0..16) |pattern| {
                    const at_bound: u4 = @intCast(pattern);
                    if ((at_bound & ~rho) != 0) continue;
                    try std.testing.expect(table[vlcEncodeIndex(@intCast(context), rho, 0, at_bound)].len != 0);
                    // u_off = 1 puts U_q at E_qmax, so some sample reaches it.
                    if (at_bound != 0) try std.testing.expect(table[vlcEncodeIndex(@intCast(context), rho, 1, at_bound)].len != 0);
                }
            }
        }
    }
}

test "HT encoder output decodes to the coded block" {
    // The narrow coefficients of 8- to 16-bit images, then the wide ones
    // up to the deepest wide band, 37 magnitude bits.
    try expectEncoderRoundTrip(i32, 31);
    try expectEncoderRoundTrip(i64, 37);
}

test "HT sets decode to the distortion they report at every plane and pass count" {
    try expectSetRoundTrip(i32, 20);
    try expectSetRoundTrip(i64, 37);
}

fn expectSetRoundTrip(comptime Coefficient: type, max_bits: u7) !void {
    const allocator = std.testing.allocator;
    var encoder = Encoder(Coefficient).init(allocator);
    defer encoder.deinit();
    var decoder = Decoder(Coefficient).init(allocator);
    defer decoder.deinit();
    var prng = std.Random.DefaultPrng.init(0x48545345);
    const random = prng.random();
    const shapes = [_][2]usize{ .{ 1, 1 }, .{ 3, 5 }, .{ 7, 9 }, .{ 16, 16 }, .{ 64, 64 }, .{ 33, 17 }, .{ 4, 1024 }, .{ 1024, 4 } };
    const stride = 1031;
    // How many decodes ran with each pass count.
    var decodes: [4]usize = @splat(0);
    const plane_samples = try allocator.alloc(Coefficient, stride * 1024);
    defer allocator.free(plane_samples);
    for (shapes) |shape| {
        const width = shape[0];
        const height = shape[1];
        for (0..12) |round| {
            const bits: u7 = @intCast(1 + (round * 7 + width) % max_bits);
            const kept = round % 4;
            @memset(plane_samples, 0);
            for (0..height) |y| {
                for (plane_samples[y * stride ..][0..width]) |*sample| {
                    if (random.uintLessThan(u8, 4) > kept) continue;
                    var magnitude = random.int(u64) >> @intCast(64 - bits);
                    if (random.boolean()) magnitude >>= random.uintLessThan(u6, @intCast(bits));
                    const value: Coefficient = @intCast(magnitude);
                    sample.* = if (random.boolean()) -value else value;
                }
            }
            const vertical_causal = round % 3 == 1;
            for (0..bits) |plane_index| {
                const plane: u8 = @intCast(plane_index);
                const set = try encoder.encodeSet(plane_samples, stride, width, height, plane, vertical_causal);
                const passes = set.passCount();
                // Both codeword segment prefixes keep the 0xFF rules.
                try checkSegmentBytes(set.refinement[0..set.sig_prop_length], max_refinement_length);
                try checkSegmentBytes(set.refinement, max_refinement_length);
                for (1..@as(usize, passes) + 1) |pass_count| {
                    const decoded = try decoder.decode(.{
                        .width = width,
                        .height = height,
                        .cleanup = set.cleanup.bytes,
                        .refinement = set.refinement[0..if (pass_count == 2) set.sig_prop_length else if (pass_count == 3) set.refinement.len else 0],
                        .passes = @intCast(pass_count),
                        .cleanup_plane = plane,
                        .magnitude_bitplanes = @intCast(bits + 1),
                        .vertical_causal = vertical_causal,
                    });
                    var distortion: f64 = 0;
                    for (0..height) |y| {
                        for (plane_samples[y * stride ..][0..width], decoded[y * width ..][0..width]) |sample, value| {
                            const mu: u64 = @abs(sample);
                            const estimate: u64 = @abs(value);
                            distortion += squaredError(mu, estimate);
                            if (value != 0) try std.testing.expectEqual(sample < 0, value < 0);
                        }
                    }
                    decodes[pass_count] += 1;
                    const reported = set.distortion[pass_count];
                    try std.testing.expectApproxEqRel(reported, distortion, 1e-9);
                }
                if (passes == 0) try std.testing.expectEqual(set.distortion[0], set.distortion[1]);
            }
        }
    }
    for (decodes[1..]) |count| try std.testing.expect(count > 100);
}

fn expectEncoderRoundTrip(comptime Coefficient: type, max_bits: u7) !void {
    const allocator = std.testing.allocator;
    var encoder = Encoder(Coefficient).init(allocator);
    defer encoder.deinit();
    var decoder = Decoder(Coefficient).init(allocator);
    defer decoder.deinit();
    var prng = std.Random.DefaultPrng.init(0x48544a32);
    const random = prng.random();
    const shapes = [_][2]usize{
        .{ 1, 1 },   .{ 1, 7 },  .{ 7, 1 },   .{ 2, 2 },   .{ 3, 5 },   .{ 4, 4 },    .{ 5, 3 },
        .{ 16, 16 }, .{ 17, 9 }, .{ 32, 32 }, .{ 64, 64 }, .{ 63, 65 }, .{ 1024, 4 }, .{ 4, 1024 },
    };
    // Rows of the block sit in a wider plane, as code-blocks of a band do.
    const stride = 1031;
    const plane = try allocator.alloc(Coefficient, stride * 1024);
    defer allocator.free(plane);
    for (shapes) |shape| {
        const width = shape[0];
        const height = shape[1];
        for (0..48) |round| {
            // Magnitudes below 2^1 to 2^max_bits, with a quarter to all of
            // the samples significant.
            const bits: u7 = @intCast(1 + round % max_bits);
            const kept = round % 4;
            @memset(plane, 0);
            for (0..height) |y| {
                for (plane[y * stride ..][0..width]) |*sample| {
                    if (random.uintLessThan(u8, 4) > kept) continue;
                    var magnitude = random.int(u64) >> @intCast(64 - bits);
                    if (random.boolean()) magnitude >>= random.uintLessThan(u6, @intCast(bits));
                    const value: Coefficient = @intCast(magnitude);
                    sample.* = if (random.boolean()) -value else value;
                }
            }
            const cleanup = try encoder.encode(plane, stride, width, height);
            var expected_bitplanes: u8 = 0;
            var expected_non_zero: u32 = 0;
            for (0..height) |y| {
                for (plane[y * stride ..][0..width]) |sample| {
                    const magnitude: u64 = @abs(sample);
                    expected_bitplanes = @max(expected_bitplanes, @as(u8, @intCast(64 - @clz(magnitude))));
                    expected_non_zero += @intFromBool(magnitude != 0);
                }
            }
            try std.testing.expectEqual(expected_bitplanes, cleanup.bitplanes);
            try std.testing.expectEqual(expected_non_zero, cleanup.non_zero_count);
            if (cleanup.bitplanes == 0) {
                try std.testing.expectEqual(@as(usize, 0), cleanup.bytes.len);
                continue;
            }
            const decoded = try decoder.decode(.{
                .width = width,
                .height = height,
                .cleanup = cleanup.bytes,
                .passes = 1,
                .cleanup_plane = 0,
                .magnitude_bitplanes = cleanup.bitplanes,
            });
            for (0..height) |y| {
                try std.testing.expectEqualSlices(Coefficient, plane[y * stride ..][0..width], decoded[y * width ..][0..width]);
            }
        }
    }
}

test "HT cleanup segments follow the T.814 7.1.1 byte rules" {
    // Scup = 2 from the last two bytes leaves no MagSgn bytes; the MEL bits
    // 1111 (the low nibble reads as ones) code four zero symbols, one per
    // all-zero-context quad of a 4x4 block.
    var decoder = Decoder(i32).init(std.testing.allocator);
    defer decoder.deinit();
    const block = Block{ .width = 4, .height = 4, .cleanup = &.{ 0xf2, 0x00 }, .passes = 1, .cleanup_plane = 0, .magnitude_bitplanes = 8 };
    const zero = try decoder.decode(block);
    for (zero) |coefficient| try std.testing.expectEqual(@as(i32, 0), coefficient);

    const malformed = [_][]const u8{
        &.{0x02}, // Lcup below 2
        &.{ 0x01, 0x00 }, // Scup 1
        &.{ 0x00, 0x00, 0x03 }, // Scup 48 > Lcup
        &.{ 0xff, 0x02, 0x00 }, // byte Pcup - 1 is 0xFF
        &.{ 0xff, 0x90, 0x02, 0x00 }, // byte pair above 0xFF8F
        &.{ 0x02, 0xff }, // ends in 0xFF
    };
    for (malformed) |bytes| {
        var bad = block;
        bad.cleanup = bytes;
        try std.testing.expectError(Error.InvalidBlock, decoder.decode(bad));
    }
    // Refinement passes need a bit-plane below the cleanup pass.
    var refined = block;
    refined.passes = 2;
    try std.testing.expectError(Error.InvalidBlock, decoder.decode(refined));
}

const CxtVlcEntry = struct {
    context: u3,
    rho: u4,
    u_off: u1,
    e_k: u4,
    e_1: u4,
    codeword: u7,
    len: u3,
};

fn e(context: u3, rho: u4, u_off: u1, e_k: u4, e_1: u4, codeword: u7, len: u3) CxtVlcEntry {
    return .{ .context = context, .rho = rho, .u_off = u_off, .e_k = e_k, .e_1 = e_1, .codeword = codeword, .len = len };
}

const VlcMatch = struct {
    rho: u4 = 0,
    u_off: u1 = 0,
    e_k: u4 = 0,
    e_1: u4 = 0,
    /// Zero for a look-ahead no codeword matches.
    len: u7 = 0,
};

/// Indexed by context and the next seven VLC bits: the prefix code of each
/// context (test_match and get_match of 7.3.5) resolved at compile time.
fn buildLookup(comptime table: []const CxtVlcEntry) [8 * 128]VlcMatch {
    @setEvalBranchQuota(1_000_000);
    var lookup: [8 * 128]VlcMatch = @splat(.{});
    for (table) |entry| {
        const step = @as(usize, 1) << entry.len;
        var bits: usize = entry.codeword;
        while (bits < 128) : (bits += step) {
            lookup[(@as(usize, entry.context) << 7) | bits] = .{
                .rho = entry.rho,
                .u_off = entry.u_off,
                .e_k = entry.e_k,
                .e_1 = entry.e_1,
                .len = entry.len,
            };
        }
    }
    return lookup;
}

const cxt_vlc_lookup_0 = buildLookup(&cxt_vlc_table_0);
const cxt_vlc_lookup_1 = buildLookup(&cxt_vlc_table_1);

/// CxtVLC_table_0 of ITU-T T.814 Annex C (initial quad rows):
/// c_q, rho_q, u_off, eps_k, eps_1, codeword w (LSB first), length l_w.
const cxt_vlc_table_0 = [_]CxtVlcEntry{
    e(0, 0x1, 0, 0x0, 0x0, 0x06, 4), e(0, 0x1, 1, 0x1, 0x1, 0x3F, 7),
    e(0, 0x2, 0, 0x0, 0x0, 0x00, 3), e(0, 0x2, 1, 0x2, 0x2, 0x7F, 7),
    e(0, 0x3, 0, 0x0, 0x0, 0x11, 5), e(0, 0x3, 1, 0x2, 0x2, 0x5F, 7),
    e(0, 0x3, 1, 0x3, 0x1, 0x1F, 7), e(0, 0x4, 0, 0x0, 0x0, 0x02, 3),
    e(0, 0x4, 1, 0x4, 0x4, 0x13, 6), e(0, 0x5, 0, 0x0, 0x0, 0x0E, 5),
    e(0, 0x5, 1, 0x4, 0x4, 0x23, 6), e(0, 0x5, 1, 0x5, 0x1, 0x0F, 7),
    e(0, 0x6, 0, 0x0, 0x0, 0x03, 6), e(0, 0x6, 1, 0x0, 0x0, 0x6F, 7),
    e(0, 0x7, 0, 0x0, 0x0, 0x2F, 7), e(0, 0x7, 1, 0x2, 0x2, 0x4F, 7),
    e(0, 0x7, 1, 0x2, 0x0, 0x0D, 6), e(0, 0x8, 0, 0x0, 0x0, 0x04, 3),
    e(0, 0x8, 1, 0x8, 0x8, 0x3D, 6), e(0, 0x9, 0, 0x0, 0x0, 0x1D, 6),
    e(0, 0x9, 1, 0x0, 0x0, 0x2D, 6), e(0, 0xA, 0, 0x0, 0x0, 0x01, 5),
    e(0, 0xA, 1, 0x8, 0x8, 0x35, 6), e(0, 0xA, 1, 0xA, 0x2, 0x77, 7),
    e(0, 0xB, 0, 0x0, 0x0, 0x37, 7), e(0, 0xB, 1, 0x1, 0x1, 0x57, 7),
    e(0, 0xB, 1, 0x1, 0x0, 0x09, 6), e(0, 0xC, 0, 0x0, 0x0, 0x1E, 5),
    e(0, 0xC, 1, 0xC, 0xC, 0x17, 7), e(0, 0xC, 1, 0xC, 0x4, 0x15, 6),
    e(0, 0xC, 1, 0xC, 0x8, 0x25, 6), e(0, 0xD, 0, 0x0, 0x0, 0x67, 7),
    e(0, 0xD, 1, 0x1, 0x1, 0x27, 7), e(0, 0xD, 1, 0x5, 0x4, 0x47, 7),
    e(0, 0xD, 1, 0xD, 0x8, 0x07, 7), e(0, 0xE, 0, 0x0, 0x0, 0x7B, 7),
    e(0, 0xE, 1, 0x2, 0x2, 0x4B, 7), e(0, 0xE, 1, 0xA, 0x8, 0x05, 6),
    e(0, 0xE, 1, 0xE, 0x4, 0x3B, 7), e(0, 0xF, 0, 0x0, 0x0, 0x5B, 7),
    e(0, 0xF, 1, 0x9, 0x9, 0x1B, 7), e(0, 0xF, 1, 0xB, 0xA, 0x6B, 7),
    e(0, 0xF, 1, 0xF, 0xC, 0x2B, 7), e(0, 0xF, 1, 0xF, 0x8, 0x39, 6),
    e(0, 0xF, 1, 0xE, 0x6, 0x73, 7), e(0, 0xF, 1, 0xE, 0x2, 0x19, 6),
    e(0, 0xF, 1, 0xF, 0x5, 0x0B, 7), e(0, 0xF, 1, 0xF, 0x4, 0x29, 6),
    e(0, 0xF, 1, 0xF, 0x1, 0x33, 7), e(1, 0x0, 0, 0x0, 0x0, 0x00, 2),
    e(1, 0x1, 0, 0x0, 0x0, 0x0E, 4), e(1, 0x1, 1, 0x1, 0x1, 0x1F, 7),
    e(1, 0x2, 0, 0x0, 0x0, 0x06, 4), e(1, 0x2, 1, 0x2, 0x2, 0x3B, 6),
    e(1, 0x3, 0, 0x0, 0x0, 0x1B, 6), e(1, 0x3, 1, 0x0, 0x0, 0x3D, 6),
    e(1, 0x4, 0, 0x0, 0x0, 0x0A, 4), e(1, 0x4, 1, 0x4, 0x4, 0x2B, 6),
    e(1, 0x5, 0, 0x0, 0x0, 0x0B, 6), e(1, 0x5, 1, 0x4, 0x4, 0x33, 6),
    e(1, 0x5, 1, 0x5, 0x1, 0x7F, 7), e(1, 0x6, 0, 0x0, 0x0, 0x13, 6),
    e(1, 0x6, 1, 0x0, 0x0, 0x23, 6), e(1, 0x7, 0, 0x0, 0x0, 0x3F, 7),
    e(1, 0x7, 1, 0x2, 0x2, 0x5F, 7), e(1, 0x7, 1, 0x2, 0x0, 0x03, 6),
    e(1, 0x8, 0, 0x0, 0x0, 0x02, 4), e(1, 0x8, 1, 0x8, 0x8, 0x1D, 6),
    e(1, 0x9, 0, 0x0, 0x0, 0x2D, 6), e(1, 0x9, 1, 0x0, 0x0, 0x0D, 6),
    e(1, 0xA, 0, 0x0, 0x0, 0x35, 6), e(1, 0xA, 1, 0x8, 0x8, 0x15, 6),
    e(1, 0xA, 1, 0xA, 0x2, 0x6F, 7), e(1, 0xB, 0, 0x0, 0x0, 0x2F, 7),
    e(1, 0xB, 1, 0x1, 0x1, 0x4F, 7), e(1, 0xB, 1, 0x1, 0x0, 0x11, 6),
    e(1, 0xC, 0, 0x0, 0x0, 0x01, 5), e(1, 0xC, 1, 0x8, 0x8, 0x25, 6),
    e(1, 0xC, 1, 0xC, 0x4, 0x05, 6), e(1, 0xD, 0, 0x0, 0x0, 0x0F, 7),
    e(1, 0xD, 1, 0x1, 0x1, 0x17, 7), e(1, 0xD, 1, 0x5, 0x4, 0x39, 6),
    e(1, 0xD, 1, 0xD, 0x8, 0x77, 7), e(1, 0xE, 0, 0x0, 0x0, 0x37, 7),
    e(1, 0xE, 1, 0x2, 0x2, 0x57, 7), e(1, 0xE, 1, 0xA, 0x8, 0x19, 6),
    e(1, 0xE, 1, 0xE, 0x4, 0x67, 7), e(1, 0xF, 0, 0x0, 0x0, 0x07, 7),
    e(1, 0xF, 1, 0xB, 0x8, 0x29, 6), e(1, 0xF, 1, 0x8, 0x8, 0x27, 7),
    e(1, 0xF, 1, 0xA, 0x2, 0x09, 6), e(1, 0xF, 1, 0xE, 0x4, 0x31, 6),
    e(1, 0xF, 1, 0xF, 0x1, 0x47, 7), e(2, 0x0, 0, 0x0, 0x0, 0x00, 2),
    e(2, 0x1, 0, 0x0, 0x0, 0x0E, 4), e(2, 0x1, 1, 0x1, 0x1, 0x1B, 6),
    e(2, 0x2, 0, 0x0, 0x0, 0x06, 4), e(2, 0x2, 1, 0x2, 0x2, 0x3F, 7),
    e(2, 0x3, 0, 0x0, 0x0, 0x2B, 6), e(2, 0x3, 1, 0x1, 0x1, 0x33, 6),
    e(2, 0x3, 1, 0x3, 0x2, 0x7F, 7), e(2, 0x4, 0, 0x0, 0x0, 0x0A, 4),
    e(2, 0x4, 1, 0x4, 0x4, 0x0B, 6), e(2, 0x5, 0, 0x0, 0x0, 0x01, 5),
    e(2, 0x5, 1, 0x5, 0x5, 0x2F, 7), e(2, 0x5, 1, 0x5, 0x1, 0x13, 6),
    e(2, 0x5, 1, 0x5, 0x4, 0x23, 6), e(2, 0x6, 0, 0x0, 0x0, 0x03, 6),
    e(2, 0x6, 1, 0x0, 0x0, 0x5F, 7), e(2, 0x7, 0, 0x0, 0x0, 0x1F, 7),
    e(2, 0x7, 1, 0x2, 0x2, 0x6F, 7), e(2, 0x7, 1, 0x3, 0x1, 0x11, 6),
    e(2, 0x7, 1, 0x7, 0x4, 0x37, 7), e(2, 0x8, 0, 0x0, 0x0, 0x02, 4),
    e(2, 0x8, 1, 0x8, 0x8, 0x4F, 7), e(2, 0x9, 0, 0x0, 0x0, 0x3D, 6),
    e(2, 0x9, 1, 0x0, 0x0, 0x1D, 6), e(2, 0xA, 0, 0x0, 0x0, 0x2D, 6),
    e(2, 0xA, 1, 0x0, 0x0, 0x0D, 6), e(2, 0xB, 0, 0x0, 0x0, 0x0F, 7),
    e(2, 0xB, 1, 0x2, 0x2, 0x77, 7), e(2, 0xB, 1, 0x2, 0x0, 0x35, 6),
    e(2, 0xC, 0, 0x0, 0x0, 0x15, 6), e(2, 0xC, 1, 0x4, 0x4, 0x25, 6),
    e(2, 0xC, 1, 0xC, 0x8, 0x57, 7), e(2, 0xD, 0, 0x0, 0x0, 0x17, 7),
    e(2, 0xD, 1, 0x8, 0x8, 0x05, 6), e(2, 0xD, 1, 0xC, 0x4, 0x39, 6),
    e(2, 0xD, 1, 0xD, 0x1, 0x67, 7), e(2, 0xE, 0, 0x0, 0x0, 0x27, 7),
    e(2, 0xE, 1, 0x2, 0x2, 0x7B, 7), e(2, 0xE, 1, 0x2, 0x0, 0x19, 6),
    e(2, 0xF, 0, 0x0, 0x0, 0x47, 7), e(2, 0xF, 1, 0xF, 0x1, 0x29, 6),
    e(2, 0xF, 1, 0x1, 0x1, 0x09, 6), e(2, 0xF, 1, 0x3, 0x2, 0x07, 7),
    e(2, 0xF, 1, 0x7, 0x4, 0x31, 6), e(2, 0xF, 1, 0xF, 0x8, 0x3B, 7),
    e(3, 0x0, 0, 0x0, 0x0, 0x00, 3), e(3, 0x1, 0, 0x0, 0x0, 0x04, 4),
    e(3, 0x1, 1, 0x1, 0x1, 0x3D, 6), e(3, 0x2, 0, 0x0, 0x0, 0x0C, 5),
    e(3, 0x2, 1, 0x2, 0x2, 0x4F, 7), e(3, 0x3, 0, 0x0, 0x0, 0x1D, 6),
    e(3, 0x3, 1, 0x1, 0x1, 0x05, 6), e(3, 0x3, 1, 0x3, 0x2, 0x7F, 7),
    e(3, 0x4, 0, 0x0, 0x0, 0x16, 5), e(3, 0x4, 1, 0x4, 0x4, 0x2D, 6),
    e(3, 0x5, 0, 0x0, 0x0, 0x06, 5), e(3, 0x5, 1, 0x5, 0x5, 0x1A, 5),
    e(3, 0x5, 1, 0x5, 0x1, 0x0D, 6), e(3, 0x5, 1, 0x5, 0x4, 0x35, 6),
    e(3, 0x6, 0, 0x0, 0x0, 0x3F, 7), e(3, 0x6, 1, 0x4, 0x4, 0x5F, 7),
    e(3, 0x6, 1, 0x6, 0x2, 0x1F, 7), e(3, 0x7, 0, 0x0, 0x0, 0x6F, 7),
    e(3, 0x7, 1, 0x6, 0x6, 0x2F, 7), e(3, 0x7, 1, 0x6, 0x4, 0x15, 6),
    e(3, 0x7, 1, 0x7, 0x3, 0x77, 7), e(3, 0x7, 1, 0x7, 0x1, 0x25, 6),
    e(3, 0x7, 1, 0x7, 0x2, 0x0F, 7), e(3, 0x8, 0, 0x0, 0x0, 0x0A, 5),
    e(3, 0x8, 1, 0x8, 0x8, 0x07, 7), e(3, 0x9, 0, 0x0, 0x0, 0x39, 6),
    e(3, 0x9, 1, 0x1, 0x1, 0x37, 7), e(3, 0x9, 1, 0x9, 0x8, 0x57, 7),
    e(3, 0xA, 0, 0x0, 0x0, 0x19, 6), e(3, 0xA, 1, 0x8, 0x8, 0x29, 6),
    e(3, 0xA, 1, 0xA, 0x2, 0x17, 7), e(3, 0xB, 0, 0x0, 0x0, 0x67, 7),
    e(3, 0xB, 1, 0xB, 0x1, 0x27, 7), e(3, 0xB, 1, 0x1, 0x1, 0x47, 7),
    e(3, 0xB, 1, 0x3, 0x2, 0x09, 6), e(3, 0xB, 1, 0xB, 0x8, 0x7B, 7),
    e(3, 0xC, 0, 0x0, 0x0, 0x31, 6), e(3, 0xC, 1, 0x4, 0x4, 0x11, 6),
    e(3, 0xC, 1, 0xC, 0x8, 0x3B, 7), e(3, 0xD, 0, 0x0, 0x0, 0x5B, 7),
    e(3, 0xD, 1, 0x9, 0x9, 0x1B, 7), e(3, 0xD, 1, 0xD, 0x5, 0x2B, 7),
    e(3, 0xD, 1, 0xD, 0x1, 0x21, 6), e(3, 0xD, 1, 0xD, 0xC, 0x6B, 7),
    e(3, 0xD, 1, 0xD, 0x4, 0x01, 6), e(3, 0xD, 1, 0xD, 0x8, 0x4B, 7),
    e(3, 0xE, 0, 0x0, 0x0, 0x0B, 7), e(3, 0xE, 1, 0xE, 0x4, 0x73, 7),
    e(3, 0xE, 1, 0x4, 0x4, 0x13, 7), e(3, 0xE, 1, 0xC, 0x8, 0x3E, 6),
    e(3, 0xE, 1, 0xE, 0x2, 0x33, 7), e(3, 0xF, 0, 0x0, 0x0, 0x53, 7),
    e(3, 0xF, 1, 0xA, 0xA, 0x0E, 6), e(3, 0xF, 1, 0xB, 0x9, 0x63, 7),
    e(3, 0xF, 1, 0xF, 0xC, 0x03, 7), e(3, 0xF, 1, 0xF, 0x8, 0x12, 5),
    e(3, 0xF, 1, 0xE, 0x6, 0x23, 7), e(3, 0xF, 1, 0xF, 0x5, 0x1E, 6),
    e(3, 0xF, 1, 0xF, 0x4, 0x02, 5), e(3, 0xF, 1, 0xF, 0x3, 0x43, 7),
    e(3, 0xF, 1, 0xF, 0x1, 0x1C, 5), e(3, 0xF, 1, 0xF, 0x2, 0x2E, 6),
    e(4, 0x0, 0, 0x0, 0x0, 0x00, 2), e(4, 0x1, 0, 0x0, 0x0, 0x0E, 4),
    e(4, 0x1, 1, 0x1, 0x1, 0x3F, 7), e(4, 0x2, 0, 0x0, 0x0, 0x06, 4),
    e(4, 0x2, 1, 0x2, 0x2, 0x1B, 6), e(4, 0x3, 0, 0x0, 0x0, 0x2B, 6),
    e(4, 0x3, 1, 0x2, 0x2, 0x3D, 6), e(4, 0x3, 1, 0x3, 0x1, 0x7F, 7),
    e(4, 0x4, 0, 0x0, 0x0, 0x0A, 4), e(4, 0x4, 1, 0x4, 0x4, 0x5F, 7),
    e(4, 0x5, 0, 0x0, 0x0, 0x0B, 6), e(4, 0x5, 1, 0x0, 0x0, 0x33, 6),
    e(4, 0x6, 0, 0x0, 0x0, 0x13, 6), e(4, 0x6, 1, 0x0, 0x0, 0x23, 6),
    e(4, 0x7, 0, 0x0, 0x0, 0x1F, 7), e(4, 0x7, 1, 0x4, 0x4, 0x6F, 7),
    e(4, 0x7, 1, 0x4, 0x0, 0x03, 6), e(4, 0x8, 0, 0x0, 0x0, 0x02, 4),
    e(4, 0x8, 1, 0x8, 0x8, 0x1D, 6), e(4, 0x9, 0, 0x0, 0x0, 0x11, 6),
    e(4, 0x9, 1, 0x0, 0x0, 0x77, 7), e(4, 0xA, 0, 0x0, 0x0, 0x01, 5),
    e(4, 0xA, 1, 0xA, 0xA, 0x2F, 7), e(4, 0xA, 1, 0xA, 0x2, 0x2D, 6),
    e(4, 0xA, 1, 0xA, 0x8, 0x0D, 6), e(4, 0xB, 0, 0x0, 0x0, 0x4F, 7),
    e(4, 0xB, 1, 0xB, 0x2, 0x0F, 7), e(4, 0xB, 1, 0x0, 0x0, 0x35, 6),
    e(4, 0xC, 0, 0x0, 0x0, 0x15, 6), e(4, 0xC, 1, 0x8, 0x8, 0x25, 6),
    e(4, 0xC, 1, 0xC, 0x4, 0x37, 7), e(4, 0xD, 0, 0x0, 0x0, 0x57, 7),
    e(4, 0xD, 1, 0x1, 0x1, 0x07, 7), e(4, 0xD, 1, 0x1, 0x0, 0x05, 6),
    e(4, 0xE, 0, 0x0, 0x0, 0x17, 7), e(4, 0xE, 1, 0x4, 0x4, 0x39, 6),
    e(4, 0xE, 1, 0xC, 0x8, 0x19, 6), e(4, 0xE, 1, 0xE, 0x2, 0x67, 7),
    e(4, 0xF, 0, 0x0, 0x0, 0x27, 7), e(4, 0xF, 1, 0x9, 0x9, 0x47, 7),
    e(4, 0xF, 1, 0x9, 0x1, 0x29, 6), e(4, 0xF, 1, 0x7, 0x6, 0x7B, 7),
    e(4, 0xF, 1, 0x7, 0x2, 0x09, 6), e(4, 0xF, 1, 0xB, 0x8, 0x31, 6),
    e(4, 0xF, 1, 0xF, 0x4, 0x3B, 7), e(5, 0x0, 0, 0x0, 0x0, 0x00, 3),
    e(5, 0x1, 0, 0x0, 0x0, 0x1A, 5), e(5, 0x1, 1, 0x1, 0x1, 0x7F, 7),
    e(5, 0x2, 0, 0x0, 0x0, 0x0A, 5), e(5, 0x2, 1, 0x2, 0x2, 0x1D, 6),
    e(5, 0x3, 0, 0x0, 0x0, 0x2D, 6), e(5, 0x3, 1, 0x3, 0x3, 0x5F, 7),
    e(5, 0x3, 1, 0x3, 0x2, 0x39, 6), e(5, 0x3, 1, 0x3, 0x1, 0x3F, 7),
    e(5, 0x4, 0, 0x0, 0x0, 0x12, 5), e(5, 0x4, 1, 0x4, 0x4, 0x1F, 7),
    e(5, 0x5, 0, 0x0, 0x0, 0x0D, 6), e(5, 0x5, 1, 0x4, 0x4, 0x35, 6),
    e(5, 0x5, 1, 0x5, 0x1, 0x6F, 7), e(5, 0x6, 0, 0x0, 0x0, 0x15, 6),
    e(5, 0x6, 1, 0x2, 0x2, 0x25, 6), e(5, 0x6, 1, 0x6, 0x4, 0x2F, 7),
    e(5, 0x7, 0, 0x0, 0x0, 0x4F, 7), e(5, 0x7, 1, 0x6, 0x6, 0x57, 7),
    e(5, 0x7, 1, 0x6, 0x4, 0x05, 6), e(5, 0x7, 1, 0x7, 0x3, 0x0F, 7),
    e(5, 0x7, 1, 0x7, 0x2, 0x77, 7), e(5, 0x7, 1, 0x7, 0x1, 0x37, 7),
    e(5, 0x8, 0, 0x0, 0x0, 0x02, 5), e(5, 0x8, 1, 0x8, 0x8, 0x19, 6),
    e(5, 0x9, 0, 0x0, 0x0, 0x26, 6), e(5, 0x9, 1, 0x8, 0x8, 0x17, 7),
    e(5, 0x9, 1, 0x9, 0x1, 0x67, 7), e(5, 0xA, 0, 0x0, 0x0, 0x1C, 5),
    e(5, 0xA, 1, 0xA, 0xA, 0x29, 6), e(5, 0xA, 1, 0xA, 0x2, 0x09, 6),
    e(5, 0xA, 1, 0xA, 0x8, 0x31, 6), e(5, 0xB, 0, 0x0, 0x0, 0x27, 7),
    e(5, 0xB, 1, 0x9, 0x9, 0x07, 7), e(5, 0xB, 1, 0x9, 0x8, 0x11, 6),
    e(5, 0xB, 1, 0xB, 0x3, 0x47, 7), e(5, 0xB, 1, 0xB, 0x2, 0x21, 6),
    e(5, 0xB, 1, 0xB, 0x1, 0x7B, 7), e(5, 0xC, 0, 0x0, 0x0, 0x01, 6),
    e(5, 0xC, 1, 0x8, 0x8, 0x3E, 6), e(5, 0xC, 1, 0xC, 0x4, 0x3B, 7),
    e(5, 0xD, 0, 0x0, 0x0, 0x5B, 7), e(5, 0xD, 1, 0x9, 0x9, 0x6B, 7),
    e(5, 0xD, 1, 0x9, 0x8, 0x1E, 6), e(5, 0xD, 1, 0xD, 0x5, 0x1B, 7),
    e(5, 0xD, 1, 0xD, 0x4, 0x2E, 6), e(5, 0xD, 1, 0xD, 0x1, 0x2B, 7),
    e(5, 0xE, 0, 0x0, 0x0, 0x4B, 7), e(5, 0xE, 1, 0x6, 0x6, 0x0B, 7),
    e(5, 0xE, 1, 0xE, 0xA, 0x33, 7), e(5, 0xE, 1, 0xE, 0x2, 0x0E, 6),
    e(5, 0xE, 1, 0xE, 0xC, 0x73, 7), e(5, 0xE, 1, 0xE, 0x8, 0x36, 6),
    e(5, 0xE, 1, 0xE, 0x4, 0x53, 7), e(5, 0xF, 0, 0x0, 0x0, 0x13, 7),
    e(5, 0xF, 1, 0x7, 0x7, 0x43, 7), e(5, 0xF, 1, 0x7, 0x6, 0x16, 6),
    e(5, 0xF, 1, 0x7, 0x5, 0x63, 7), e(5, 0xF, 1, 0xF, 0xC, 0x23, 7),
    e(5, 0xF, 1, 0xF, 0x4, 0x0C, 5), e(5, 0xF, 1, 0xD, 0x9, 0x03, 7),
    e(5, 0xF, 1, 0xF, 0xA, 0x3D, 7), e(5, 0xF, 1, 0xF, 0x8, 0x14, 5),
    e(5, 0xF, 1, 0xF, 0x3, 0x7D, 7), e(5, 0xF, 1, 0xF, 0x2, 0x04, 5),
    e(5, 0xF, 1, 0xF, 0x1, 0x06, 6), e(6, 0x0, 0, 0x0, 0x0, 0x00, 3),
    e(6, 0x1, 0, 0x0, 0x0, 0x04, 4), e(6, 0x1, 1, 0x1, 0x1, 0x03, 6),
    e(6, 0x2, 0, 0x0, 0x0, 0x0C, 5), e(6, 0x2, 1, 0x2, 0x2, 0x0D, 6),
    e(6, 0x3, 0, 0x0, 0x0, 0x1A, 5), e(6, 0x3, 1, 0x3, 0x3, 0x3D, 6),
    e(6, 0x3, 1, 0x3, 0x1, 0x1D, 6), e(6, 0x3, 1, 0x3, 0x2, 0x2D, 6),
    e(6, 0x4, 0, 0x0, 0x0, 0x0A, 5), e(6, 0x4, 1, 0x4, 0x4, 0x3F, 7),
    e(6, 0x5, 0, 0x0, 0x0, 0x35, 6), e(6, 0x5, 1, 0x1, 0x1, 0x15, 6),
    e(6, 0x5, 1, 0x5, 0x4, 0x7F, 7), e(6, 0x6, 0, 0x0, 0x0, 0x25, 6),
    e(6, 0x6, 1, 0x2, 0x2, 0x5F, 7), e(6, 0x6, 1, 0x6, 0x4, 0x1F, 7),
    e(6, 0x7, 0, 0x0, 0x0, 0x6F, 7), e(6, 0x7, 1, 0x6, 0x6, 0x4F, 7),
    e(6, 0x7, 1, 0x6, 0x4, 0x05, 6), e(6, 0x7, 1, 0x7, 0x3, 0x2F, 7),
    e(6, 0x7, 1, 0x7, 0x1, 0x36, 6), e(6, 0x7, 1, 0x7, 0x2, 0x77, 7),
    e(6, 0x8, 0, 0x0, 0x0, 0x12, 5), e(6, 0x8, 1, 0x8, 0x8, 0x0F, 7),
    e(6, 0x9, 0, 0x0, 0x0, 0x39, 6), e(6, 0x9, 1, 0x1, 0x1, 0x37, 7),
    e(6, 0x9, 1, 0x9, 0x8, 0x57, 7), e(6, 0xA, 0, 0x0, 0x0, 0x19, 6),
    e(6, 0xA, 1, 0x2, 0x2, 0x29, 6), e(6, 0xA, 1, 0xA, 0x8, 0x17, 7),
    e(6, 0xB, 0, 0x0, 0x0, 0x67, 7), e(6, 0xB, 1, 0x9, 0x9, 0x47, 7),
    e(6, 0xB, 1, 0x9, 0x1, 0x09, 6), e(6, 0xB, 1, 0xB, 0xA, 0x27, 7),
    e(6, 0xB, 1, 0xB, 0x2, 0x31, 6), e(6, 0xB, 1, 0xB, 0x8, 0x7B, 7),
    e(6, 0xC, 0, 0x0, 0x0, 0x11, 6), e(6, 0xC, 1, 0xC, 0xC, 0x07, 7),
    e(6, 0xC, 1, 0xC, 0x8, 0x21, 6), e(6, 0xC, 1, 0xC, 0x4, 0x3B, 7),
    e(6, 0xD, 0, 0x0, 0x0, 0x5B, 7), e(6, 0xD, 1, 0x5, 0x5, 0x33, 7),
    e(6, 0xD, 1, 0x5, 0x4, 0x01, 6), e(6, 0xD, 1, 0xC, 0x8, 0x1B, 7),
    e(6, 0xD, 1, 0xD, 0x1, 0x6B, 7), e(6, 0xE, 0, 0x0, 0x0, 0x2B, 7),
    e(6, 0xE, 1, 0xE, 0x2, 0x4B, 7), e(6, 0xE, 1, 0x2, 0x2, 0x0B, 7),
    e(6, 0xE, 1, 0xE, 0xC, 0x73, 7), e(6, 0xE, 1, 0xE, 0x8, 0x3E, 6),
    e(6, 0xE, 1, 0xE, 0x4, 0x53, 7), e(6, 0xF, 0, 0x0, 0x0, 0x13, 7),
    e(6, 0xF, 1, 0x6, 0x6, 0x1E, 6), e(6, 0xF, 1, 0xE, 0xA, 0x2E, 6),
    e(6, 0xF, 1, 0xF, 0x3, 0x0E, 6), e(6, 0xF, 1, 0xF, 0x2, 0x02, 5),
    e(6, 0xF, 1, 0xB, 0x9, 0x63, 7), e(6, 0xF, 1, 0xF, 0xC, 0x16, 6),
    e(6, 0xF, 1, 0xF, 0x8, 0x06, 6), e(6, 0xF, 1, 0xF, 0x5, 0x23, 7),
    e(6, 0xF, 1, 0xF, 0x1, 0x1C, 5), e(6, 0xF, 1, 0xF, 0x4, 0x26, 6),
    e(7, 0x0, 0, 0x0, 0x0, 0x12, 5), e(7, 0x1, 0, 0x0, 0x0, 0x05, 6),
    e(7, 0x1, 1, 0x1, 0x1, 0x7F, 7), e(7, 0x2, 0, 0x0, 0x0, 0x39, 6),
    e(7, 0x2, 1, 0x2, 0x2, 0x3F, 7), e(7, 0x3, 0, 0x0, 0x0, 0x5F, 7),
    e(7, 0x3, 1, 0x3, 0x3, 0x1F, 7), e(7, 0x3, 1, 0x3, 0x2, 0x6F, 7),
    e(7, 0x3, 1, 0x3, 0x1, 0x2F, 7), e(7, 0x4, 0, 0x0, 0x0, 0x4F, 7),
    e(7, 0x4, 1, 0x4, 0x4, 0x0F, 7), e(7, 0x5, 0, 0x0, 0x0, 0x57, 7),
    e(7, 0x5, 1, 0x1, 0x1, 0x19, 6), e(7, 0x5, 1, 0x5, 0x4, 0x77, 7),
    e(7, 0x6, 0, 0x0, 0x0, 0x37, 7), e(7, 0x6, 1, 0x0, 0x0, 0x29, 6),
    e(7, 0x7, 0, 0x0, 0x0, 0x17, 7), e(7, 0x7, 1, 0x6, 0x6, 0x67, 7),
    e(7, 0x7, 1, 0x7, 0x3, 0x27, 7), e(7, 0x7, 1, 0x7, 0x2, 0x47, 7),
    e(7, 0x7, 1, 0x7, 0x5, 0x1B, 7), e(7, 0x7, 1, 0x7, 0x1, 0x09, 6),
    e(7, 0x7, 1, 0x7, 0x4, 0x07, 7), e(7, 0x8, 0, 0x0, 0x0, 0x7B, 7),
    e(7, 0x8, 1, 0x8, 0x8, 0x3B, 7), e(7, 0x9, 0, 0x0, 0x0, 0x5B, 7),
    e(7, 0x9, 1, 0x0, 0x0, 0x31, 6), e(7, 0xA, 0, 0x0, 0x0, 0x53, 7),
    e(7, 0xA, 1, 0x2, 0x2, 0x11, 6), e(7, 0xA, 1, 0xA, 0x8, 0x6B, 7),
    e(7, 0xB, 0, 0x0, 0x0, 0x2B, 7), e(7, 0xB, 1, 0x9, 0x9, 0x4B, 7),
    e(7, 0xB, 1, 0xB, 0x3, 0x0B, 7), e(7, 0xB, 1, 0xB, 0x1, 0x73, 7),
    e(7, 0xB, 1, 0xB, 0xA, 0x33, 7), e(7, 0xB, 1, 0xB, 0x2, 0x21, 6),
    e(7, 0xB, 1, 0xB, 0x8, 0x13, 7), e(7, 0xC, 0, 0x0, 0x0, 0x63, 7),
    e(7, 0xC, 1, 0x8, 0x8, 0x23, 7), e(7, 0xC, 1, 0xC, 0x4, 0x43, 7),
    e(7, 0xD, 0, 0x0, 0x0, 0x03, 7), e(7, 0xD, 1, 0x9, 0x9, 0x7D, 7),
    e(7, 0xD, 1, 0xD, 0x5, 0x5D, 7), e(7, 0xD, 1, 0xD, 0x1, 0x01, 6),
    e(7, 0xD, 1, 0xD, 0xC, 0x3D, 7), e(7, 0xD, 1, 0xD, 0x4, 0x3E, 6),
    e(7, 0xD, 1, 0xD, 0x8, 0x1D, 7), e(7, 0xE, 0, 0x0, 0x0, 0x6D, 7),
    e(7, 0xE, 1, 0x6, 0x6, 0x2D, 7), e(7, 0xE, 1, 0xE, 0xA, 0x0D, 7),
    e(7, 0xE, 1, 0xE, 0x2, 0x1E, 6), e(7, 0xE, 1, 0xE, 0xC, 0x4D, 7),
    e(7, 0xE, 1, 0xE, 0x8, 0x0E, 6), e(7, 0xE, 1, 0xE, 0x4, 0x75, 7),
    e(7, 0xF, 0, 0x0, 0x0, 0x15, 7), e(7, 0xF, 1, 0xF, 0xF, 0x06, 5),
    e(7, 0xF, 1, 0xF, 0xD, 0x35, 7), e(7, 0xF, 1, 0xF, 0x7, 0x55, 7),
    e(7, 0xF, 1, 0xF, 0x5, 0x1A, 5), e(7, 0xF, 1, 0xF, 0xB, 0x25, 7),
    e(7, 0xF, 1, 0xF, 0x3, 0x0A, 5), e(7, 0xF, 1, 0xF, 0x9, 0x2E, 6),
    e(7, 0xF, 1, 0xF, 0x1, 0x00, 4), e(7, 0xF, 1, 0xF, 0xE, 0x65, 7),
    e(7, 0xF, 1, 0xF, 0x6, 0x36, 6), e(7, 0xF, 1, 0xF, 0xA, 0x02, 5),
    e(7, 0xF, 1, 0xF, 0x2, 0x0C, 4), e(7, 0xF, 1, 0xF, 0xC, 0x16, 6),
    e(7, 0xF, 1, 0xF, 0x8, 0x04, 4), e(7, 0xF, 1, 0xF, 0x4, 0x08, 4),
};

/// CxtVLC_table_1 of ITU-T T.814 Annex C (non-initial quad rows):
/// c_q, rho_q, u_off, eps_k, eps_1, codeword w (LSB first), length l_w.
const cxt_vlc_table_1 = [_]CxtVlcEntry{
    e(0, 0x1, 0, 0x0, 0x0, 0x00, 3), e(0, 0x1, 1, 0x1, 0x1, 0x27, 6),
    e(0, 0x2, 0, 0x0, 0x0, 0x06, 3), e(0, 0x2, 1, 0x2, 0x2, 0x17, 6),
    e(0, 0x3, 0, 0x0, 0x0, 0x0D, 5), e(0, 0x3, 1, 0x0, 0x0, 0x3B, 6),
    e(0, 0x4, 0, 0x0, 0x0, 0x02, 3), e(0, 0x4, 1, 0x4, 0x4, 0x07, 6),
    e(0, 0x5, 0, 0x0, 0x0, 0x15, 5), e(0, 0x5, 1, 0x0, 0x0, 0x2B, 6),
    e(0, 0x6, 0, 0x0, 0x0, 0x01, 5), e(0, 0x6, 1, 0x0, 0x0, 0x7F, 7),
    e(0, 0x7, 0, 0x0, 0x0, 0x1F, 7), e(0, 0x7, 1, 0x0, 0x0, 0x1B, 6),
    e(0, 0x8, 0, 0x0, 0x0, 0x04, 3), e(0, 0x8, 1, 0x8, 0x8, 0x05, 5),
    e(0, 0x9, 0, 0x0, 0x0, 0x19, 5), e(0, 0x9, 1, 0x0, 0x0, 0x13, 6),
    e(0, 0xA, 0, 0x0, 0x0, 0x09, 5), e(0, 0xA, 1, 0x8, 0x8, 0x0B, 6),
    e(0, 0xA, 1, 0xA, 0x2, 0x3F, 7), e(0, 0xB, 0, 0x0, 0x0, 0x5F, 7),
    e(0, 0xB, 1, 0x0, 0x0, 0x33, 6), e(0, 0xC, 0, 0x0, 0x0, 0x11, 5),
    e(0, 0xC, 1, 0x8, 0x8, 0x23, 6), e(0, 0xC, 1, 0xC, 0x4, 0x6F, 7),
    e(0, 0xD, 0, 0x0, 0x0, 0x0F, 7), e(0, 0xD, 1, 0x0, 0x0, 0x03, 6),
    e(0, 0xE, 0, 0x0, 0x0, 0x2F, 7), e(0, 0xE, 1, 0x4, 0x4, 0x4F, 7),
    e(0, 0xE, 1, 0x4, 0x0, 0x3D, 6), e(0, 0xF, 0, 0x0, 0x0, 0x77, 7),
    e(0, 0xF, 1, 0x1, 0x1, 0x37, 7), e(0, 0xF, 1, 0x1, 0x0, 0x1D, 6),
    e(1, 0x0, 0, 0x0, 0x0, 0x00, 1), e(1, 0x1, 0, 0x0, 0x0, 0x05, 4),
    e(1, 0x1, 1, 0x1, 0x1, 0x7F, 7), e(1, 0x2, 0, 0x0, 0x0, 0x09, 4),
    e(1, 0x2, 1, 0x2, 0x2, 0x1F, 7), e(1, 0x3, 0, 0x0, 0x0, 0x1D, 5),
    e(1, 0x3, 1, 0x1, 0x1, 0x3F, 7), e(1, 0x3, 1, 0x3, 0x2, 0x5F, 7),
    e(1, 0x4, 0, 0x0, 0x0, 0x0D, 5), e(1, 0x4, 1, 0x4, 0x4, 0x37, 7),
    e(1, 0x5, 0, 0x0, 0x0, 0x03, 6), e(1, 0x5, 1, 0x0, 0x0, 0x6F, 7),
    e(1, 0x6, 0, 0x0, 0x0, 0x2F, 7), e(1, 0x6, 1, 0x0, 0x0, 0x4F, 7),
    e(1, 0x7, 0, 0x0, 0x0, 0x0F, 7), e(1, 0x7, 1, 0x0, 0x0, 0x77, 7),
    e(1, 0x8, 0, 0x0, 0x0, 0x01, 4), e(1, 0x8, 1, 0x8, 0x8, 0x17, 7),
    e(1, 0x9, 0, 0x0, 0x0, 0x0B, 6), e(1, 0x9, 1, 0x0, 0x0, 0x57, 7),
    e(1, 0xA, 0, 0x0, 0x0, 0x33, 6), e(1, 0xA, 1, 0x0, 0x0, 0x67, 7),
    e(1, 0xB, 0, 0x0, 0x0, 0x27, 7), e(1, 0xB, 1, 0x0, 0x0, 0x2B, 7),
    e(1, 0xC, 0, 0x0, 0x0, 0x13, 6), e(1, 0xC, 1, 0x0, 0x0, 0x47, 7),
    e(1, 0xD, 0, 0x0, 0x0, 0x07, 7), e(1, 0xD, 1, 0x0, 0x0, 0x7B, 7),
    e(1, 0xE, 0, 0x0, 0x0, 0x3B, 7), e(1, 0xE, 1, 0x0, 0x0, 0x5B, 7),
    e(1, 0xF, 0, 0x0, 0x0, 0x1B, 7), e(1, 0xF, 1, 0x4, 0x4, 0x6B, 7),
    e(1, 0xF, 1, 0x4, 0x0, 0x23, 6), e(2, 0x0, 0, 0x0, 0x0, 0x00, 1),
    e(2, 0x1, 0, 0x0, 0x0, 0x09, 4), e(2, 0x1, 1, 0x1, 0x1, 0x7F, 7),
    e(2, 0x2, 0, 0x0, 0x0, 0x01, 4), e(2, 0x2, 1, 0x2, 0x2, 0x23, 6),
    e(2, 0x3, 0, 0x0, 0x0, 0x3D, 6), e(2, 0x3, 1, 0x2, 0x2, 0x3F, 7),
    e(2, 0x3, 1, 0x3, 0x1, 0x1F, 7), e(2, 0x4, 0, 0x0, 0x0, 0x15, 5),
    e(2, 0x4, 1, 0x4, 0x4, 0x5F, 7), e(2, 0x5, 0, 0x0, 0x0, 0x03, 6),
    e(2, 0x5, 1, 0x0, 0x0, 0x6F, 7), e(2, 0x6, 0, 0x0, 0x0, 0x2F, 7),
    e(2, 0x6, 1, 0x0, 0x0, 0x4F, 7), e(2, 0x7, 0, 0x0, 0x0, 0x0F, 7),
    e(2, 0x7, 1, 0x0, 0x0, 0x17, 7), e(2, 0x8, 0, 0x0, 0x0, 0x05, 5),
    e(2, 0x8, 1, 0x8, 0x8, 0x77, 7), e(2, 0x9, 0, 0x0, 0x0, 0x37, 7),
    e(2, 0x9, 1, 0x0, 0x0, 0x57, 7), e(2, 0xA, 0, 0x0, 0x0, 0x1D, 6),
    e(2, 0xA, 1, 0xA, 0xA, 0x7B, 7), e(2, 0xA, 1, 0xA, 0x2, 0x2D, 6),
    e(2, 0xA, 1, 0xA, 0x8, 0x67, 7), e(2, 0xB, 0, 0x0, 0x0, 0x27, 7),
    e(2, 0xB, 1, 0xB, 0x2, 0x47, 7), e(2, 0xB, 1, 0x0, 0x0, 0x07, 7),
    e(2, 0xC, 0, 0x0, 0x0, 0x0D, 6), e(2, 0xC, 1, 0x0, 0x0, 0x3B, 7),
    e(2, 0xD, 0, 0x0, 0x0, 0x5B, 7), e(2, 0xD, 1, 0x0, 0x0, 0x1B, 7),
    e(2, 0xE, 0, 0x0, 0x0, 0x6B, 7), e(2, 0xE, 1, 0x4, 0x4, 0x2B, 7),
    e(2, 0xE, 1, 0x4, 0x0, 0x4B, 7), e(2, 0xF, 0, 0x0, 0x0, 0x0B, 7),
    e(2, 0xF, 1, 0x4, 0x4, 0x73, 7), e(2, 0xF, 1, 0x5, 0x1, 0x33, 7),
    e(2, 0xF, 1, 0x7, 0x2, 0x53, 7), e(2, 0xF, 1, 0xF, 0x8, 0x13, 7),
    e(3, 0x0, 0, 0x0, 0x0, 0x00, 2), e(3, 0x1, 0, 0x0, 0x0, 0x0A, 4),
    e(3, 0x1, 1, 0x1, 0x1, 0x0B, 6), e(3, 0x2, 0, 0x0, 0x0, 0x02, 4),
    e(3, 0x2, 1, 0x2, 0x2, 0x23, 6), e(3, 0x3, 0, 0x0, 0x0, 0x0E, 5),
    e(3, 0x3, 1, 0x3, 0x3, 0x7F, 7), e(3, 0x3, 1, 0x3, 0x2, 0x33, 6),
    e(3, 0x3, 1, 0x3, 0x1, 0x13, 6), e(3, 0x4, 0, 0x0, 0x0, 0x16, 5),
    e(3, 0x4, 1, 0x4, 0x4, 0x3F, 7), e(3, 0x5, 0, 0x0, 0x0, 0x03, 6),
    e(3, 0x5, 1, 0x1, 0x1, 0x3D, 6), e(3, 0x5, 1, 0x5, 0x4, 0x1F, 7),
    e(3, 0x6, 0, 0x0, 0x0, 0x1D, 6), e(3, 0x6, 1, 0x0, 0x0, 0x5F, 7),
    e(3, 0x7, 0, 0x0, 0x0, 0x2D, 6), e(3, 0x7, 1, 0x4, 0x4, 0x2F, 7),
    e(3, 0x7, 1, 0x5, 0x1, 0x1E, 6), e(3, 0x7, 1, 0x7, 0x2, 0x6F, 7),
    e(3, 0x8, 0, 0x0, 0x0, 0x06, 5), e(3, 0x8, 1, 0x8, 0x8, 0x4F, 7),
    e(3, 0x9, 0, 0x0, 0x0, 0x0D, 6), e(3, 0x9, 1, 0x0, 0x0, 0x35, 6),
    e(3, 0xA, 0, 0x0, 0x0, 0x15, 6), e(3, 0xA, 1, 0x2, 0x2, 0x25, 6),
    e(3, 0xA, 1, 0xA, 0x8, 0x0F, 7), e(3, 0xB, 0, 0x0, 0x0, 0x05, 6),
    e(3, 0xB, 1, 0x8, 0x8, 0x39, 6), e(3, 0xB, 1, 0xB, 0x3, 0x17, 7),
    e(3, 0xB, 1, 0xB, 0x2, 0x19, 6), e(3, 0xB, 1, 0xB, 0x1, 0x77, 7),
    e(3, 0xC, 0, 0x0, 0x0, 0x29, 6), e(3, 0xC, 1, 0x0, 0x0, 0x09, 6),
    e(3, 0xD, 0, 0x0, 0x0, 0x37, 7), e(3, 0xD, 1, 0x4, 0x4, 0x57, 7),
    e(3, 0xD, 1, 0x4, 0x0, 0x31, 6), e(3, 0xE, 0, 0x0, 0x0, 0x67, 7),
    e(3, 0xE, 1, 0x4, 0x4, 0x27, 7), e(3, 0xE, 1, 0xC, 0x8, 0x47, 7),
    e(3, 0xE, 1, 0xE, 0x2, 0x6B, 7), e(3, 0xF, 0, 0x0, 0x0, 0x11, 6),
    e(3, 0xF, 1, 0x6, 0x6, 0x07, 7), e(3, 0xF, 1, 0x7, 0x3, 0x7B, 7),
    e(3, 0xF, 1, 0xF, 0xA, 0x3B, 7), e(3, 0xF, 1, 0xF, 0x2, 0x21, 6),
    e(3, 0xF, 1, 0xF, 0x8, 0x01, 6), e(3, 0xF, 1, 0xA, 0x8, 0x5B, 7),
    e(3, 0xF, 1, 0xF, 0x5, 0x1B, 7), e(3, 0xF, 1, 0xF, 0x1, 0x3E, 6),
    e(3, 0xF, 1, 0xF, 0x4, 0x2B, 7), e(4, 0x0, 0, 0x0, 0x0, 0x00, 1),
    e(4, 0x1, 0, 0x0, 0x0, 0x0D, 5), e(4, 0x1, 1, 0x1, 0x1, 0x7F, 7),
    e(4, 0x2, 0, 0x0, 0x0, 0x15, 5), e(4, 0x2, 1, 0x2, 0x2, 0x3F, 7),
    e(4, 0x3, 0, 0x0, 0x0, 0x5F, 7), e(4, 0x3, 1, 0x0, 0x0, 0x6F, 7),
    e(4, 0x4, 0, 0x0, 0x0, 0x09, 4), e(4, 0x4, 1, 0x4, 0x4, 0x23, 6),
    e(4, 0x5, 0, 0x0, 0x0, 0x33, 6), e(4, 0x5, 1, 0x0, 0x0, 0x1F, 7),
    e(4, 0x6, 0, 0x0, 0x0, 0x13, 6), e(4, 0x6, 1, 0x0, 0x0, 0x2F, 7),
    e(4, 0x7, 0, 0x0, 0x0, 0x4F, 7), e(4, 0x7, 1, 0x0, 0x0, 0x57, 7),
    e(4, 0x8, 0, 0x0, 0x0, 0x01, 4), e(4, 0x8, 1, 0x8, 0x8, 0x0F, 7),
    e(4, 0x9, 0, 0x0, 0x0, 0x77, 7), e(4, 0x9, 1, 0x0, 0x0, 0x37, 7),
    e(4, 0xA, 0, 0x0, 0x0, 0x1D, 6), e(4, 0xA, 1, 0x0, 0x0, 0x17, 7),
    e(4, 0xB, 0, 0x0, 0x0, 0x67, 7), e(4, 0xB, 1, 0x0, 0x0, 0x6B, 7),
    e(4, 0xC, 0, 0x0, 0x0, 0x05, 5), e(4, 0xC, 1, 0xC, 0xC, 0x27, 7),
    e(4, 0xC, 1, 0xC, 0x8, 0x47, 7), e(4, 0xC, 1, 0xC, 0x4, 0x07, 7),
    e(4, 0xD, 0, 0x0, 0x0, 0x7B, 7), e(4, 0xD, 1, 0x0, 0x0, 0x3B, 7),
    e(4, 0xE, 0, 0x0, 0x0, 0x5B, 7), e(4, 0xE, 1, 0x2, 0x2, 0x1B, 7),
    e(4, 0xE, 1, 0x2, 0x0, 0x03, 6), e(4, 0xF, 0, 0x0, 0x0, 0x2B, 7),
    e(4, 0xF, 1, 0x1, 0x1, 0x4B, 7), e(4, 0xF, 1, 0x3, 0x2, 0x0B, 7),
    e(4, 0xF, 1, 0x3, 0x0, 0x3D, 6), e(5, 0x0, 0, 0x0, 0x0, 0x00, 2),
    e(5, 0x1, 0, 0x0, 0x0, 0x1E, 5), e(5, 0x1, 1, 0x1, 0x1, 0x3B, 6),
    e(5, 0x2, 0, 0x0, 0x0, 0x0A, 5), e(5, 0x2, 1, 0x2, 0x2, 0x3F, 7),
    e(5, 0x3, 0, 0x0, 0x0, 0x1B, 6), e(5, 0x3, 1, 0x0, 0x0, 0x0B, 6),
    e(5, 0x4, 0, 0x0, 0x0, 0x02, 4), e(5, 0x4, 1, 0x4, 0x4, 0x2B, 6),
    e(5, 0x5, 0, 0x0, 0x0, 0x0E, 5), e(5, 0x5, 1, 0x4, 0x4, 0x33, 6),
    e(5, 0x5, 1, 0x5, 0x1, 0x7F, 7), e(5, 0x6, 0, 0x0, 0x0, 0x13, 6),
    e(5, 0x6, 1, 0x0, 0x0, 0x6F, 7), e(5, 0x7, 0, 0x0, 0x0, 0x23, 6),
    e(5, 0x7, 1, 0x2, 0x2, 0x5F, 7), e(5, 0x7, 1, 0x2, 0x0, 0x15, 6),
    e(5, 0x8, 0, 0x0, 0x0, 0x16, 5), e(5, 0x8, 1, 0x8, 0x8, 0x03, 6),
    e(5, 0x9, 0, 0x0, 0x0, 0x3D, 6), e(5, 0x9, 1, 0x0, 0x0, 0x1F, 7),
    e(5, 0xA, 0, 0x0, 0x0, 0x1D, 6), e(5, 0xA, 1, 0x0, 0x0, 0x2D, 6),
    e(5, 0xB, 0, 0x0, 0x0, 0x0D, 6), e(5, 0xB, 1, 0x1, 0x1, 0x4F, 7),
    e(5, 0xB, 1, 0x1, 0x0, 0x35, 6), e(5, 0xC, 0, 0x0, 0x0, 0x06, 5),
    e(5, 0xC, 1, 0x4, 0x4, 0x25, 6), e(5, 0xC, 1, 0xC, 0x8, 0x2F, 7),
    e(5, 0xD, 0, 0x0, 0x0, 0x05, 6), e(5, 0xD, 1, 0x1, 0x1, 0x77, 7),
    e(5, 0xD, 1, 0x5, 0x4, 0x39, 6), e(5, 0xD, 1, 0xD, 0x8, 0x0F, 7),
    e(5, 0xE, 0, 0x0, 0x0, 0x19, 6), e(5, 0xE, 1, 0x2, 0x2, 0x57, 7),
    e(5, 0xE, 1, 0xA, 0x8, 0x01, 6), e(5, 0xE, 1, 0xE, 0x4, 0x37, 7),
    e(5, 0xF, 0, 0x0, 0x0, 0x1A, 5), e(5, 0xF, 1, 0x9, 0x9, 0x17, 7),
    e(5, 0xF, 1, 0xD, 0x5, 0x67, 7), e(5, 0xF, 1, 0xF, 0x3, 0x07, 7),
    e(5, 0xF, 1, 0xF, 0x1, 0x29, 6), e(5, 0xF, 1, 0x7, 0x6, 0x27, 7),
    e(5, 0xF, 1, 0xF, 0xC, 0x09, 6), e(5, 0xF, 1, 0xF, 0x4, 0x31, 6),
    e(5, 0xF, 1, 0xF, 0xA, 0x47, 7), e(5, 0xF, 1, 0xF, 0x8, 0x11, 6),
    e(5, 0xF, 1, 0xF, 0x2, 0x21, 6), e(6, 0x0, 0, 0x0, 0x0, 0x00, 3),
    e(6, 0x1, 0, 0x0, 0x0, 0x02, 4), e(6, 0x1, 1, 0x1, 0x1, 0x03, 6),
    e(6, 0x2, 0, 0x0, 0x0, 0x0C, 4), e(6, 0x2, 1, 0x2, 0x2, 0x3D, 6),
    e(6, 0x3, 0, 0x0, 0x0, 0x1D, 6), e(6, 0x3, 1, 0x2, 0x2, 0x0D, 6),
    e(6, 0x3, 1, 0x3, 0x1, 0x7F, 7), e(6, 0x4, 0, 0x0, 0x0, 0x04, 4),
    e(6, 0x4, 1, 0x4, 0x4, 0x2D, 6), e(6, 0x5, 0, 0x0, 0x0, 0x0A, 5),
    e(6, 0x5, 1, 0x4, 0x4, 0x35, 6), e(6, 0x5, 1, 0x5, 0x1, 0x2F, 7),
    e(6, 0x6, 0, 0x0, 0x0, 0x15, 6), e(6, 0x6, 1, 0x2, 0x2, 0x3F, 7),
    e(6, 0x6, 1, 0x6, 0x4, 0x5F, 7), e(6, 0x7, 0, 0x0, 0x0, 0x25, 6),
    e(6, 0x7, 1, 0x2, 0x2, 0x29, 6), e(6, 0x7, 1, 0x3, 0x1, 0x1F, 7),
    e(6, 0x7, 1, 0x7, 0x4, 0x6F, 7), e(6, 0x8, 0, 0x0, 0x0, 0x16, 5),
    e(6, 0x8, 1, 0x8, 0x8, 0x05, 6), e(6, 0x9, 0, 0x0, 0x0, 0x39, 6),
    e(6, 0x9, 1, 0x0, 0x0, 0x19, 6), e(6, 0xA, 0, 0x0, 0x0, 0x06, 5),
    e(6, 0xA, 1, 0xA, 0xA, 0x0F, 7), e(6, 0xA, 1, 0xA, 0x2, 0x09, 6),
    e(6, 0xA, 1, 0xA, 0x8, 0x4F, 7), e(6, 0xB, 0, 0x0, 0x0, 0x0E, 6),
    e(6, 0xB, 1, 0xB, 0x2, 0x77, 7), e(6, 0xB, 1, 0x2, 0x2, 0x37, 7),
    e(6, 0xB, 1, 0xA, 0x8, 0x57, 7), e(6, 0xB, 1, 0xB, 0x1, 0x47, 7),
    e(6, 0xC, 0, 0x0, 0x0, 0x1A, 5), e(6, 0xC, 1, 0xC, 0xC, 0x17, 7),
    e(6, 0xC, 1, 0xC, 0x8, 0x67, 7), e(6, 0xC, 1, 0xC, 0x4, 0x27, 7),
    e(6, 0xD, 0, 0x0, 0x0, 0x31, 6), e(6, 0xD, 1, 0xD, 0x4, 0x07, 7),
    e(6, 0xD, 1, 0x4, 0x4, 0x7B, 7), e(6, 0xD, 1, 0xC, 0x8, 0x3B, 7),
    e(6, 0xD, 1, 0xD, 0x1, 0x2B, 7), e(6, 0xE, 0, 0x0, 0x0, 0x11, 6),
    e(6, 0xE, 1, 0xE, 0x4, 0x5B, 7), e(6, 0xE, 1, 0x4, 0x4, 0x1B, 7),
    e(6, 0xE, 1, 0xE, 0xA, 0x6B, 7), e(6, 0xE, 1, 0xE, 0x8, 0x21, 6),
    e(6, 0xE, 1, 0xE, 0x2, 0x33, 7), e(6, 0xF, 0, 0x0, 0x0, 0x01, 6),
    e(6, 0xF, 1, 0x3, 0x3, 0x4B, 7), e(6, 0xF, 1, 0x7, 0x6, 0x0B, 7),
    e(6, 0xF, 1, 0xF, 0xA, 0x73, 7), e(6, 0xF, 1, 0xF, 0x2, 0x3E, 6),
    e(6, 0xF, 1, 0xB, 0x9, 0x53, 7), e(6, 0xF, 1, 0xF, 0xC, 0x63, 7),
    e(6, 0xF, 1, 0xF, 0x8, 0x1E, 6), e(6, 0xF, 1, 0xF, 0x5, 0x13, 7),
    e(6, 0xF, 1, 0xF, 0x4, 0x2E, 6), e(6, 0xF, 1, 0xF, 0x1, 0x23, 7),
    e(7, 0x0, 0, 0x0, 0x0, 0x04, 4), e(7, 0x1, 0, 0x0, 0x0, 0x33, 6),
    e(7, 0x1, 1, 0x1, 0x1, 0x13, 6), e(7, 0x2, 0, 0x0, 0x0, 0x23, 6),
    e(7, 0x2, 1, 0x2, 0x2, 0x7F, 7), e(7, 0x3, 0, 0x0, 0x0, 0x03, 6),
    e(7, 0x3, 1, 0x1, 0x1, 0x3F, 7), e(7, 0x3, 1, 0x3, 0x2, 0x6F, 7),
    e(7, 0x4, 0, 0x0, 0x0, 0x2D, 6), e(7, 0x4, 1, 0x4, 0x4, 0x5F, 7),
    e(7, 0x5, 0, 0x0, 0x0, 0x16, 5), e(7, 0x5, 1, 0x1, 0x1, 0x3D, 6),
    e(7, 0x5, 1, 0x5, 0x4, 0x1F, 7), e(7, 0x6, 0, 0x0, 0x0, 0x1D, 6),
    e(7, 0x6, 1, 0x0, 0x0, 0x77, 7), e(7, 0x7, 0, 0x0, 0x0, 0x06, 5),
    e(7, 0x7, 1, 0x7, 0x4, 0x2F, 7), e(7, 0x7, 1, 0x4, 0x4, 0x4F, 7),
    e(7, 0x7, 1, 0x7, 0x3, 0x0F, 7), e(7, 0x7, 1, 0x7, 0x1, 0x0D, 6),
    e(7, 0x7, 1, 0x7, 0x2, 0x57, 7), e(7, 0x8, 0, 0x0, 0x0, 0x35, 6),
    e(7, 0x8, 1, 0x8, 0x8, 0x37, 7), e(7, 0x9, 0, 0x0, 0x0, 0x15, 6),
    e(7, 0x9, 1, 0x0, 0x0, 0x27, 7), e(7, 0xA, 0, 0x0, 0x0, 0x25, 6),
    e(7, 0xA, 1, 0x0, 0x0, 0x29, 6), e(7, 0xB, 0, 0x0, 0x0, 0x1A, 5),
    e(7, 0xB, 1, 0xB, 0x1, 0x17, 7), e(7, 0xB, 1, 0x1, 0x1, 0x67, 7),
    e(7, 0xB, 1, 0x3, 0x2, 0x05, 6), e(7, 0xB, 1, 0xB, 0x8, 0x7B, 7),
    e(7, 0xC, 0, 0x0, 0x0, 0x39, 6), e(7, 0xC, 1, 0x0, 0x0, 0x19, 6),
    e(7, 0xD, 0, 0x0, 0x0, 0x0C, 5), e(7, 0xD, 1, 0xD, 0x1, 0x47, 7),
    e(7, 0xD, 1, 0x1, 0x1, 0x07, 7), e(7, 0xD, 1, 0x5, 0x4, 0x09, 6),
    e(7, 0xD, 1, 0xD, 0x8, 0x1B, 7), e(7, 0xE, 0, 0x0, 0x0, 0x31, 6),
    e(7, 0xE, 1, 0xE, 0x2, 0x3B, 7), e(7, 0xE, 1, 0x2, 0x2, 0x5B, 7),
    e(7, 0xE, 1, 0xA, 0x8, 0x3E, 6), e(7, 0xE, 1, 0xE, 0x4, 0x0B, 7),
    e(7, 0xF, 0, 0x0, 0x0, 0x00, 3), e(7, 0xF, 1, 0xF, 0xF, 0x6B, 7),
    e(7, 0xF, 1, 0xF, 0x7, 0x2B, 7), e(7, 0xF, 1, 0xF, 0xB, 0x4B, 7),
    e(7, 0xF, 1, 0xF, 0x3, 0x11, 6), e(7, 0xF, 1, 0x7, 0x6, 0x21, 6),
    e(7, 0xF, 1, 0xF, 0xA, 0x01, 6), e(7, 0xF, 1, 0xF, 0x2, 0x0A, 5),
    e(7, 0xF, 1, 0xB, 0x9, 0x1E, 6), e(7, 0xF, 1, 0xF, 0xC, 0x0E, 6),
    e(7, 0xF, 1, 0xF, 0x8, 0x12, 5), e(7, 0xF, 1, 0xF, 0x5, 0x2E, 6),
    e(7, 0xF, 1, 0xF, 0x1, 0x02, 5), e(7, 0xF, 1, 0xF, 0x4, 0x1C, 5),
};
