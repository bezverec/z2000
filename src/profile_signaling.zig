const std = @import("std");

pub const marker_cap: u16 = 0xff50;
pub const marker_prf: u16 = 0xff56;
/// Corresponding profile (ITU-T T.814 A.6), an HTJ2K main-header marker.
pub const marker_cpf: u16 = 0xff59;

/// Rsiz bit 14 optionally announces that a CAP marker is present. When the
/// bit is set, the marker is mandatory; CAP itself may still be present when
/// the bit is clear (ISO/IEC 15444-1 A.5.2).
pub const rsiz_cap_present: u16 = 0x4000;

pub const Error = error{
    InvalidCodestream,
    UnsupportedPayload,
};

const Phase = enum {
    after_siz,
    after_cap,
    after_prf,
    after_cpf,
    closed,
};

/// Tracks the strictly ordered profile/capability prefix of a main header.
/// z2000 decodes unrestricted Part 1 (`Rsiz == 0`) and the Part 1 profiles of
/// ISO/IEC 15444-1 Table A.10, which only restrict the syntax an encoder may
/// use; see `restrictsPart1`. Part 2 extensions, CAP, PRF, and reserved
/// profile numbers are parsed and consistency-checked before failing closed as
/// unsupported. A CAP declaring only Part 15 is the HTJ2K signalling, which
/// `finishHighThroughput` hands to the caller.
pub const State = struct {
    rsiz: u16,
    phase: Phase = .after_siz,
    saw_cap: bool = false,
    saw_prf: bool = false,
    saw_cpf: bool = false,
    pcap: u32 = 0,
    high_throughput: ?HighThroughput = null,

    pub fn init(rsiz: u16) State {
        return .{ .rsiz = rsiz };
    }

    /// Observe every marker after SIZ, including segment-less reserved marker
    /// codes. CAP must precede PRF, PRF must precede CPF, and all three must
    /// precede every other marker (T.814 A.6).
    pub fn observeMarker(self: *State, marker: u16) Error!void {
        switch (marker) {
            marker_cap => {
                if (self.phase != .after_siz or self.saw_cap) {
                    return Error.InvalidCodestream;
                }
                self.saw_cap = true;
                self.phase = .after_cap;
            },
            marker_prf => {
                if ((self.phase != .after_siz and self.phase != .after_cap) or self.saw_prf) {
                    return Error.InvalidCodestream;
                }
                // PRF extends profile numbering beyond the 0..4094 range.
                if (self.rsiz <= 4094) return Error.InvalidCodestream;
                self.saw_prf = true;
                self.phase = .after_prf;
            },
            marker_cpf => {
                // Only an HTJ2K codestream defines CPF, at most once; its CAP
                // payload has been recorded by now.
                if ((self.phase != .after_cap and self.phase != .after_prf) or
                    self.high_throughput == null or self.saw_cpf)
                {
                    return Error.InvalidCodestream;
                }
                self.saw_cpf = true;
                self.phase = .after_cpf;
            },
            else => {
                self.phase = .closed;
                if ((self.rsiz & rsiz_cap_present) != 0 and !self.saw_cap) {
                    return Error.InvalidCodestream;
                }
            },
        }
    }

    /// Validate the payload of the CAP marker just observed and keep what
    /// the rest of the header is checked against.
    pub fn recordCap(self: *State, payload: []const u8) Error!void {
        try validateCap(payload);
        self.pcap = readU32Be(payload, 0);
        self.high_throughput = try parseHighThroughputCap(self.rsiz, payload);
    }

    /// Complete the main-header profile gate. CAP and PRF declarations and
    /// Rsiz values outside `restrictsPart1` describe extensions that are not
    /// wired to the current Part 1 MQ payload implementation.
    pub fn finish(self: State) Error!void {
        if ((self.rsiz & rsiz_cap_present) != 0 and !self.saw_cap) {
            return Error.InvalidCodestream;
        }
        if (!restrictsPart1(self.rsiz) or self.saw_cap or self.saw_prf) {
            return Error.UnsupportedPayload;
        }
    }

    /// `finish` for a decoder that also takes HTJ2K: a CAP declaring Part 15
    /// and nothing else, over a Part 1 Rsiz profile, returns its capabilities;
    /// every other prefix is gated as by `finish`. The Rsiz profile of an
    /// HTJ2K codestream restricts its syntax the same way (T.814 8.8).
    pub fn finishHighThroughput(self: State) Error!?HighThroughput {
        if ((self.rsiz & rsiz_cap_present) != 0 and !self.saw_cap) {
            return Error.InvalidCodestream;
        }
        const high_throughput = self.high_throughput orelse {
            try self.finish();
            return null;
        };
        if (self.pcap != pcap_part15 or self.saw_prf or
            !restrictsPart1(self.rsiz & ~rsiz_cap_present))
        {
            return Error.UnsupportedPayload;
        }
        return high_throughput;
    }
};

/// The Ccap15 word of an HTJ2K CAP marker (ITU-T T.814 Table A.2).
pub const HighThroughput = struct {
    ccap15: u16,

    pub const BlockCoders = enum {
        /// Every code-block is an HT code-block.
        ht_only,
        /// Each tile-component uses one block coder throughout.
        ht_declared,
        /// A tile-component may mix HT and Part 1 code-blocks.
        mixed,
    };

    pub fn blockCoders(self: HighThroughput) BlockCoders {
        return switch (self.ccap15 >> 14) {
            0 => .ht_only,
            2 => .ht_declared,
            3 => .mixed,
            // `parseHighThroughputCap` rejects the reserved value 1.
            else => unreachable,
        };
    }

    /// Bit 13: a code-block may carry more than one HT set (MULTIHT).
    pub fn multipleSets(self: HighThroughput) bool {
        return (self.ccap15 & 0x2000) != 0;
    }

    /// Bit 12: RGN marker segments may be present.
    pub fn regions(self: HighThroughput) bool {
        return (self.ccap15 & 0x1000) != 0;
    }

    /// Bit 5: HT code-blocks may follow an irreversible transform (HTIRV).
    pub fn irreversible(self: HighThroughput) bool {
        return (self.ccap15 & 0x0020) != 0;
    }

    /// The HT cleanup magnitude bound parameter B of T.814 A.3.7.
    pub fn magnitudeBound(self: HighThroughput) u8 {
        const p: u8 = @intCast(self.ccap15 & 0x1f);
        if (p == 0) return 8;
        if (p < 20) return p + 8;
        if (p < 31) return 4 * (p - 19) + 27;
        return 74;
    }
};

/// Bits 6..10 of Ccap15 are reserved, as is the value 01 of bits 14..15.
const ccap15_reserved_bits: u16 = 0x07c0;

/// The HTJ2K capabilities of a CAP payload accepted by `validateCap`, or
/// null when it does not declare Part 15. T.814 A.2 requires Rsiz bit 14
/// with it. Reserved Ccap15 values are left for future editions of T.814
/// to define, so they are unsupported rather than malformed.
pub fn parseHighThroughputCap(rsiz: u16, payload: []const u8) Error!?HighThroughput {
    if (!capDeclaresHighThroughput(payload)) return null;
    if ((rsiz & rsiz_cap_present) == 0) return Error.InvalidCodestream;
    const pcap = readU32Be(payload, 0);
    // Ccap words follow in Pcap bit order from the most significant.
    const index: usize = @popCount(pcap >> (32 - 15 + 1));
    const ccap15 = readU16Be(payload, 4 + 2 * index);
    if ((ccap15 & ccap15_reserved_bits) != 0 or (ccap15 >> 14) == 1) {
        return Error.UnsupportedPayload;
    }
    return .{ .ccap15 = ccap15 };
}

/// Whether `rsiz` names unrestricted Part 1 or one of its restricted profiles
/// (ISO/IEC 15444-1 Table A.10). A profile only limits what an encoder may
/// emit, so such a stream decodes exactly like an unrestricted one; whether it
/// honours its declared limits is not checked. Bit 15 (Part 2), bit 14 (CAP),
/// and reserved numbers return false.
pub fn restrictsPart1(rsiz: u16) bool {
    // 0: unrestricted; 1/2: Profile 0/1; 3/4: 2K/4K digital cinema; 5/6:
    // scalable 2K/4K digital cinema; 7: long-term storage.
    if (rsiz <= 7) return true;
    const family = rsiz >> 8;
    const sublevel = (rsiz >> 4) & 0xf;
    const mainlevel = rsiz & 0xf;
    return switch (family) {
        // Broadcast single-tile, multi-tile, and multi-tile reversible, with
        // the main level in the low nibble.
        1...3 => sublevel == 0 and mainlevel <= 11,
        // IMF 2K/4K/8K and their reversible variants, with the sublevel in
        // bits 4..7 and the main level in bits 0..3.
        4...9 => sublevel <= 9 and mainlevel <= 11,
        else => false,
    };
}

/// Validate a CAP payload excluding Lcap. Pcap is followed by exactly one
/// 16-bit Ccap word for each set Pcap bit, in most-significant-bit order.
pub fn validateCap(payload: []const u8) Error!void {
    if (payload.len < 6) return Error.InvalidCodestream;
    const pcap = readU32Be(payload, 0);
    if (pcap == 0) return Error.InvalidCodestream;
    const capability_words: usize = @popCount(pcap);
    const expected_len = std.math.add(usize, 4, std.math.mul(usize, capability_words, 2) catch
        return Error.InvalidCodestream) catch return Error.InvalidCodestream;
    if (payload.len != expected_len) return Error.InvalidCodestream;
}

/// Pcap^15 (the fifteenth most significant Pcap bit): the codestream uses the
/// ISO/IEC 15444-15 high-throughput (HTJ2K) block coder.
pub const pcap_part15: u32 = 1 << (32 - 15);

/// Whether a CAP payload accepted by `validateCap` declares Part 15.
pub fn capDeclaresHighThroughput(payload: []const u8) bool {
    return (readU32Be(payload, 0) & pcap_part15) != 0;
}

/// Validate a PRF payload excluding Lprf. Words use little-word order; the
/// final word must be nonzero so the representation is canonical. The numeric
/// value need not be materialized because every current PRF number is outside
/// the Part 1 profile table and therefore unsupported by this decoder.
pub fn validatePrf(payload: []const u8) Error!void {
    if (payload.len < 2 or payload.len % 2 != 0) return Error.InvalidCodestream;
    if (readU16Be(payload, payload.len - 2) == 0) return Error.InvalidCodestream;
}

/// Validate a CPF payload excluding Lcpf: Pcpf words coded like PRF's, the
/// last nonzero (T.814 A.6). CPFnum only names the Part 1 profile the
/// codestream transcodes to, which decoding does not need.
pub fn validateCpf(payload: []const u8) Error!void {
    return validatePrf(payload);
}

fn readU16Be(bytes: []const u8, offset: usize) u16 {
    return (@as(u16, bytes[offset]) << 8) | bytes[offset + 1];
}

fn readU32Be(bytes: []const u8, offset: usize) u32 {
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        bytes[offset + 3];
}

test "CAP payload count follows Pcap population" {
    try validateCap(&.{ 0x80, 0x00, 0x00, 0x01, 0x12, 0x34, 0xab, 0xcd });
    try std.testing.expect(!capDeclaresHighThroughput(&.{ 0x80, 0x00, 0x00, 0x01, 0x12, 0x34, 0xab, 0xcd }));
    try std.testing.expect(capDeclaresHighThroughput(&.{ 0x00, 0x02, 0x00, 0x00, 0x00, 0x03 }));
    try std.testing.expectError(Error.InvalidCodestream, validateCap(&.{ 0, 0, 0, 0, 0, 0 }));
    try std.testing.expectError(Error.InvalidCodestream, validateCap(&.{ 0x80, 0, 0, 1, 0, 1 }));
    try std.testing.expectError(Error.InvalidCodestream, validateCap(&.{ 0x80, 0, 0, 0, 0, 1, 0 }));
}

test "Part 1 profile numbers follow Table A.10" {
    for ([_]u16{ 0, 1, 2, 3, 4, 5, 6, 7, 0x0100, 0x0101, 0x010b, 0x0200, 0x030b, 0x0400, 0x0500, 0x0600, 0x0700, 0x0800, 0x0900, 0x099b }) |rsiz| {
        try std.testing.expect(restrictsPart1(rsiz));
    }
    // Reserved numbers, out-of-range levels, Part 2, CAP, and the PRF escape.
    for ([_]u16{ 8, 0x00ff, 0x010c, 0x0110, 0x0a00, 0x04a0, 0x040c, 0x0fff, 0x8000, 0x8001, 0x4000, 0x4001 }) |rsiz| {
        try std.testing.expect(!restrictsPart1(rsiz));
    }
}

test "PRF requires canonical nonempty little-word sequence" {
    try validatePrf(&.{ 0, 1 });
    try validatePrf(&.{ 0, 0, 0, 1 });
    try std.testing.expectError(Error.InvalidCodestream, validatePrf(&.{}));
    try std.testing.expectError(Error.InvalidCodestream, validatePrf(&.{0}));
    try std.testing.expectError(Error.InvalidCodestream, validatePrf(&.{ 0, 1, 0, 0 }));
}

test "profile prefix enforces CAP PRF order and Rsiz consistency" {
    var baseline = State.init(0);
    try baseline.observeMarker(0xff52);
    try baseline.finish();

    // Profile 0 and the IMF 2K reversible profile restrict Part 1 only.
    for ([_]u16{ 1, 0x0700 }) |rsiz| {
        var restricted = State.init(rsiz);
        try restricted.observeMarker(0xff52);
        try restricted.finish();
    }
    var part2 = State.init(0x8000);
    try part2.observeMarker(0xff52);
    try std.testing.expectError(Error.UnsupportedPayload, part2.finish());

    var missing_cap = State.init(rsiz_cap_present);
    try std.testing.expectError(Error.InvalidCodestream, missing_cap.observeMarker(0xff52));

    var cap = State.init(rsiz_cap_present);
    try cap.observeMarker(marker_cap);
    try std.testing.expectError(Error.InvalidCodestream, cap.observeMarker(marker_cap));
    cap = State.init(rsiz_cap_present);
    try cap.observeMarker(marker_cap);
    try cap.observeMarker(0xff52);
    try std.testing.expectError(Error.UnsupportedPayload, cap.finish());

    var late_cap = State.init(0);
    try late_cap.observeMarker(0xff52);
    try std.testing.expectError(Error.InvalidCodestream, late_cap.observeMarker(marker_cap));

    var prf_low = State.init(4094);
    try std.testing.expectError(Error.InvalidCodestream, prf_low.observeMarker(marker_prf));

    var prf = State.init(4095);
    try prf.observeMarker(marker_prf);
    try std.testing.expectError(Error.InvalidCodestream, prf.observeMarker(marker_prf));
    prf = State.init(4095);
    try prf.observeMarker(marker_prf);
    try std.testing.expectError(Error.UnsupportedPayload, prf.finish());

    var cap_after_prf = State.init(4095);
    try cap_after_prf.observeMarker(marker_prf);
    try std.testing.expectError(Error.InvalidCodestream, cap_after_prf.observeMarker(marker_cap));
}

test "Part 15 CAP yields the Ccap15 capabilities" {
    const cap = [_]u8{ 0x00, 0x02, 0x00, 0x00, 0x18, 0x23 };
    const ht = (try parseHighThroughputCap(rsiz_cap_present, &cap)).?;
    try std.testing.expectEqual(HighThroughput.BlockCoders.ht_only, ht.blockCoders());
    try std.testing.expect(!ht.multipleSets());
    try std.testing.expect(ht.regions());
    try std.testing.expect(ht.irreversible());
    try std.testing.expectEqual(@as(u8, 11), ht.magnitudeBound());
    try std.testing.expectEqual(@as(u8, 8), (HighThroughput{ .ccap15 = 0 }).magnitudeBound());
    try std.testing.expectEqual(@as(u8, 27), (HighThroughput{ .ccap15 = 19 }).magnitudeBound());
    try std.testing.expectEqual(@as(u8, 31), (HighThroughput{ .ccap15 = 20 }).magnitudeBound());
    try std.testing.expectEqual(@as(u8, 67), (HighThroughput{ .ccap15 = 29 }).magnitudeBound());
    try std.testing.expectEqual(@as(u8, 74), (HighThroughput{ .ccap15 = 31 }).magnitudeBound());
    try std.testing.expectEqual(HighThroughput.BlockCoders.ht_declared, (HighThroughput{ .ccap15 = 0x8000 }).blockCoders());
    try std.testing.expectEqual(HighThroughput.BlockCoders.mixed, (HighThroughput{ .ccap15 = 0xd800 }).blockCoders());

    // The Part 2 word comes first when Pcap^2 is also set.
    const two = [_]u8{ 0x40, 0x02, 0x00, 0x00, 0xff, 0xff, 0x20, 0x00 };
    try validateCap(&two);
    try std.testing.expect((try parseHighThroughputCap(rsiz_cap_present, &two)).?.multipleSets());

    try std.testing.expectEqual(@as(?HighThroughput, null), try parseHighThroughputCap(rsiz_cap_present, &.{ 0x80, 0x00, 0x00, 0x01, 0x12, 0x34, 0xab, 0xcd }));
    try std.testing.expectError(Error.InvalidCodestream, parseHighThroughputCap(0, &cap));
    try std.testing.expectError(Error.UnsupportedPayload, parseHighThroughputCap(rsiz_cap_present, &.{ 0x00, 0x02, 0x00, 0x00, 0x40, 0x00 }));
    try std.testing.expectError(Error.UnsupportedPayload, parseHighThroughputCap(rsiz_cap_present, &.{ 0x00, 0x02, 0x00, 0x00, 0x00, 0x40 }));
}

test "HTJ2K prefix orders CPF and gates the profile" {
    const cap = [_]u8{ 0x00, 0x02, 0x00, 0x00, 0x00, 0x03 };
    var state = State.init(rsiz_cap_present);
    try state.observeMarker(marker_cap);
    try state.recordCap(&cap);
    try state.observeMarker(marker_cpf);
    try validateCpf(&.{ 0x00, 0x02 });
    try std.testing.expectError(Error.InvalidCodestream, state.observeMarker(marker_cpf));
    state = State.init(rsiz_cap_present);
    try state.observeMarker(marker_cap);
    try state.recordCap(&cap);
    try state.observeMarker(marker_cpf);
    try std.testing.expectError(Error.InvalidCodestream, state.observeMarker(marker_prf));
    try state.observeMarker(0xff52);
    try std.testing.expectEqual(@as(u16, 3), (try state.finishHighThroughput()).?.ccap15);
    try std.testing.expectError(Error.UnsupportedPayload, state.finish());

    // CPF needs a Part 15 CAP before it, and nothing else in between.
    var no_cap = State.init(0);
    try std.testing.expectError(Error.InvalidCodestream, no_cap.observeMarker(marker_cpf));
    var part2_cap = State.init(rsiz_cap_present);
    try part2_cap.observeMarker(marker_cap);
    try part2_cap.recordCap(&.{ 0x80, 0x00, 0x00, 0x01, 0x12, 0x34, 0xab, 0xcd });
    try std.testing.expectError(Error.InvalidCodestream, part2_cap.observeMarker(marker_cpf));
    var late = State.init(rsiz_cap_present);
    try late.observeMarker(marker_cap);
    try late.recordCap(&cap);
    try late.observeMarker(0xff52);
    try std.testing.expectError(Error.InvalidCodestream, late.observeMarker(marker_cpf));
    try std.testing.expectError(Error.InvalidCodestream, validateCpf(&.{ 0x00, 0x00 }));

    // Part 15 with Part 2, or over a reserved Rsiz profile, stays unsupported.
    var with_part2 = State.init(rsiz_cap_present);
    try with_part2.observeMarker(marker_cap);
    try with_part2.recordCap(&.{ 0x40, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03 });
    try std.testing.expectError(Error.UnsupportedPayload, with_part2.finishHighThroughput());
    var reserved = State.init(rsiz_cap_present | 0x0a00);
    try reserved.observeMarker(marker_cap);
    try reserved.recordCap(&cap);
    try std.testing.expectError(Error.UnsupportedPayload, reserved.finishHighThroughput());
    var plain = State.init(0);
    try plain.observeMarker(0xff52);
    try std.testing.expectEqual(@as(?HighThroughput, null), try plain.finishHighThroughput());
}
