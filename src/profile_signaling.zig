const std = @import("std");

pub const marker_cap: u16 = 0xff50;
pub const marker_prf: u16 = 0xff56;

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
    closed,
};

/// Tracks the strictly ordered profile/capability prefix of a main header.
/// z2000 decodes unrestricted Part 1 (`Rsiz == 0`) and the Part 1 profiles of
/// ISO/IEC 15444-1 Table A.10, which only restrict the syntax an encoder may
/// use; see `restrictsPart1`. Part 2 extensions, CAP, PRF, and reserved
/// profile numbers are parsed and consistency-checked before failing closed as
/// unsupported.
pub const State = struct {
    rsiz: u16,
    phase: Phase = .after_siz,
    saw_cap: bool = false,
    saw_prf: bool = false,

    pub fn init(rsiz: u16) State {
        return .{ .rsiz = rsiz };
    }

    /// Observe every marker after SIZ, including segment-less reserved marker
    /// codes. CAP must precede PRF and both must precede every other marker.
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
            else => {
                self.phase = .closed;
                if ((self.rsiz & rsiz_cap_present) != 0 and !self.saw_cap) {
                    return Error.InvalidCodestream;
                }
            },
        }
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
};

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

/// Rejects a CAP payload accepted by `validateCap` that declares Part 15. An
/// HTJ2K codestream continues with syntax Part 1 does not define (the CPF
/// marker, the HT bits of SPcod and SPcoc), so a Part 1 decoder reports it
/// as unsupported here rather than as malformed later; without the Rsiz
/// bit 14 that T.814 A.2 requires, the declaration itself is malformed.
pub fn rejectHighThroughputCap(rsiz: u16, payload: []const u8) Error!void {
    if (!capDeclaresHighThroughput(payload)) return;
    if ((rsiz & rsiz_cap_present) == 0) return Error.InvalidCodestream;
    return Error.UnsupportedPayload;
}

/// Validate a PRF payload excluding Lprf. Words use little-word order; the
/// final word must be nonzero so the representation is canonical. The numeric
/// value need not be materialized because every current PRF number is outside
/// the Part 1 profile table and therefore unsupported by this decoder.
pub fn validatePrf(payload: []const u8) Error!void {
    if (payload.len < 2 or payload.len % 2 != 0) return Error.InvalidCodestream;
    if (readU16Be(payload, payload.len - 2) == 0) return Error.InvalidCodestream;
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
    try rejectHighThroughputCap(rsiz_cap_present, &.{ 0x80, 0x00, 0x00, 0x01, 0x12, 0x34, 0xab, 0xcd });
    try std.testing.expectError(Error.UnsupportedPayload, rejectHighThroughputCap(rsiz_cap_present, &.{ 0x00, 0x02, 0x00, 0x00, 0x00, 0x03 }));
    try std.testing.expectError(Error.InvalidCodestream, rejectHighThroughputCap(0, &.{ 0x00, 0x02, 0x00, 0x00, 0x00, 0x03 }));
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
