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
/// z2000 currently decodes only the unrestricted Part 1 `Rsiz == 0` profile;
/// other declarations are parsed and consistency-checked before failing
/// closed as unsupported.
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

    /// Complete the main-header profile gate. Nonzero Rsiz values and all CAP
    /// or PRF declarations describe profiles/extensions that are not wired to
    /// the current Part 1 MQ payload implementation.
    pub fn finish(self: State) Error!void {
        if ((self.rsiz & rsiz_cap_present) != 0 and !self.saw_cap) {
            return Error.InvalidCodestream;
        }
        if (self.rsiz != 0 or self.saw_cap or self.saw_prf) {
            return Error.UnsupportedPayload;
        }
    }
};

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
    try std.testing.expectError(Error.InvalidCodestream, validateCap(&.{ 0, 0, 0, 0, 0, 0 }));
    try std.testing.expectError(Error.InvalidCodestream, validateCap(&.{ 0x80, 0, 0, 1, 0, 1 }));
    try std.testing.expectError(Error.InvalidCodestream, validateCap(&.{ 0x80, 0, 0, 0, 0, 1, 0 }));
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
