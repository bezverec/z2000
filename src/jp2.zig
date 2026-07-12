const std = @import("std");
const image = @import("image.zig");
const rate_alloc = @import("rate_alloc.zig");

pub const Jp2Error = error{
    ImageTooLarge,
    CodestreamTooLarge,
    InvalidCodestream,
    InvalidBox,
    MissingRequiredBox,
    UnsupportedColorSpace,
    UnsupportedProfile,
};

pub const Info = struct {
    width: u32,
    height: u32,
    components: u16,
    bits_per_component: u8,
    has_icc_profile: bool = false,
    icc_profile_bytes: usize = 0,
    codestream_bytes: usize,
};

const BoxType = enum(u32) {
    signature = fourcc("jP  "),
    file_type = fourcc("ftyp"),
    jp2_header = fourcc("jp2h"),
    image_header = fourcc("ihdr"),
    bits_per_component = fourcc("bpcc"),
    color = fourcc("colr"),
    palette = fourcc("pclr"),
    component_mapping = fourcc("cmap"),
    channel_definition = fourcc("cdef"),
    resolution = fourcc("res "),
    capture_resolution = fourcc("resc"),
    display_resolution = fourcc("resd"),
    contiguous_codestream = fourcc("jp2c"),
    xml = fourcc("xml "),
    uuid = fourcc("uuid"),
    uuid_info = fourcc("uinf"),
};

const signature_payload = [_]u8{ 0x0d, 0x0a, 0x87, 0x0a };
const brand_jp2 = fourcc("jp2 ");
const marker_soc = 0xff4f;
const marker_cap = 0xff50;
const marker_siz = 0xff51;
const marker_cod = 0xff52;
const marker_coc = 0xff53;
const marker_tlm = 0xff55;
const marker_plt = 0xff58;
const marker_qcd = 0xff5c;
const marker_qcc = 0xff5d;
const marker_rgn = 0xff5e;
const marker_poc = 0xff5f;
const marker_ppm = 0xff60;
const marker_ppt = 0xff61;
const marker_crg = 0xff63;
const marker_com = 0xff64;
const marker_sot = 0xff90;
const marker_sop = 0xff91;
const marker_eph = 0xff92;
const marker_sod = 0xff93;
const marker_eoc = 0xffd9;

const CodestreamShape = struct {
    width: u32,
    height: u32,
    components: u16,
    bits_per_component: u8,
};

const CodSegmentInfo = struct {
    levels: u8,
    transform: u8,
    sop: bool,
    eph: bool,
};

// Multi-part tiles multiply the tile-part count (e.g. Kakadu pads every tile
// to a fixed TNsot), so the TLM capacity is tile-part-count sized rather than
// tile-count sized. 4096 covers 256 tiles x 16 parts with headroom while
// keeping the parser state a fixed-size stack value.
const max_tlm_entries = 4096;

const TlmState = struct {
    next_segment_index: u8 = 0,
    lengths: [max_tlm_entries]u32 = [_]u32{0} ** max_tlm_entries,
    tile_indices: [max_tlm_entries]u16 = [_]u16{0} ** max_tlm_entries,
    count: u16 = 0,
    saw: bool = false,
};

const PltState = struct {
    expected_segment_index: u8 = 0,
    packet_bytes: usize = 0,
    saw: bool = false,
};

const PptState = struct {
    expected_segment_index: u16 = 0,
    header_bytes: usize = 0,
    saw: bool = false,
};

const PpmState = struct {
    expected_segment_index: u16 = 0,
    saw: bool = false,
};

pub fn wrapRgbCodestream(
    allocator: std.mem.Allocator,
    input: image.RgbImage,
    codestream: []const u8,
) ![]u8 {
    if (input.width == 0 or input.height == 0) return Jp2Error.InvalidBox;
    if (input.width > std.math.maxInt(u32) or input.height > std.math.maxInt(u32)) {
        return Jp2Error.ImageTooLarge;
    }
    if (input.bit_depth != 8 and input.bit_depth != 16) return Jp2Error.UnsupportedProfile;
    const pixels = try std.math.mul(usize, input.width, input.height);
    const expected_samples = try std.math.mul(usize, pixels, 3);
    if (input.samples.len != expected_samples) return Jp2Error.InvalidBox;
    try validateCodestreamPayload(codestream, .{
        .width = @as(u32, @intCast(input.width)),
        .height = @as(u32, @intCast(input.height)),
        .components = 3,
        .bits_per_component = input.bit_depth,
    });
    if (codestream.len > std.math.maxInt(u32) - 8) return Jp2Error.CodestreamTooLarge;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try appendBox(allocator, &out, .signature, signature_payload[0..]);

    var ftyp: std.ArrayList(u8) = .empty;
    defer ftyp.deinit(allocator);
    try appendFourcc(allocator, &ftyp, "jp2 ");
    try appendU32Be(allocator, &ftyp, 0);
    try appendFourcc(allocator, &ftyp, "jp2 ");
    try appendBox(allocator, &out, .file_type, ftyp.items);

    var jp2h: std.ArrayList(u8) = .empty;
    defer jp2h.deinit(allocator);

    var ihdr: std.ArrayList(u8) = .empty;
    defer ihdr.deinit(allocator);
    try appendU32Be(allocator, &ihdr, @as(u32, @intCast(input.height)));
    try appendU32Be(allocator, &ihdr, @as(u32, @intCast(input.width)));
    try appendU16Be(allocator, &ihdr, 3);
    try ihdr.append(allocator, input.bit_depth - 1);
    try ihdr.append(allocator, 7);
    try ihdr.append(allocator, 0);
    try ihdr.append(allocator, 0);
    try appendBox(allocator, &jp2h, .image_header, ihdr.items);

    var colr: std.ArrayList(u8) = .empty;
    defer colr.deinit(allocator);
    if (input.icc_profile) |profile| {
        if (profile.len == 0) return Jp2Error.UnsupportedProfile;
        if (profile.len > std.math.maxInt(u32) - 11) return Jp2Error.CodestreamTooLarge;
        try colr.append(allocator, 2);
        try colr.append(allocator, 0);
        try colr.append(allocator, 0);
        try colr.appendSlice(allocator, profile);
    } else {
        try colr.append(allocator, 1);
        try colr.append(allocator, 0);
        try colr.append(allocator, 0);
        try appendU32Be(allocator, &colr, 16);
    }
    try appendBox(allocator, &jp2h, .color, colr.items);
    try appendBox(allocator, &out, .jp2_header, jp2h.items);

    try appendBox(allocator, &out, .contiguous_codestream, codestream);
    return out.toOwnedSlice(allocator);
}

pub fn parseInfo(bytes: []const u8) !Info {
    var cursor: usize = 0;
    var saw_signature = false;
    var saw_ftyp = false;
    var saw_jp2h = false;
    var saw_jp2c = false;
    var box_index: usize = 0;
    var info: Info = .{
        .width = 0,
        .height = 0,
        .components = 0,
        .bits_per_component = 0,
        .has_icc_profile = false,
        .icc_profile_bytes = 0,
        .codestream_bytes = 0,
    };

    while (cursor < bytes.len) {
        const box = try nextBox(bytes, &cursor, true);
        if (box_index == 0 and box.kind != @intFromEnum(BoxType.signature)) return Jp2Error.InvalidBox;
        if (box_index == 1 and box.kind != @intFromEnum(BoxType.file_type)) return Jp2Error.InvalidBox;
        switch (box.kind) {
            @intFromEnum(BoxType.signature) => {
                if (box_index != 0 or saw_signature) return Jp2Error.InvalidBox;
                if (box.payload.len != signature_payload.len or
                    !std.mem.eql(u8, box.payload, signature_payload[0..]))
                {
                    return Jp2Error.InvalidBox;
                }
                saw_signature = true;
            },
            @intFromEnum(BoxType.file_type) => {
                if (box_index != 1 or saw_ftyp) return Jp2Error.InvalidBox;
                try validateFileTypeBox(box.payload);
                saw_ftyp = true;
            },
            @intFromEnum(BoxType.jp2_header) => {
                if (!saw_ftyp or saw_jp2h or saw_jp2c) return Jp2Error.InvalidBox;
                try parseJp2Header(box.payload, &info);
                saw_jp2h = true;
            },
            @intFromEnum(BoxType.contiguous_codestream) => {
                if (!saw_jp2h or saw_jp2c) return Jp2Error.InvalidBox;
                try validateCodestreamPayload(box.payload, .{
                    .width = info.width,
                    .height = info.height,
                    .components = info.components,
                    .bits_per_component = info.bits_per_component,
                });
                info.codestream_bytes = box.payload.len;
                saw_jp2c = true;
            },
            // Top-level metadata boxes (ISO 15444-1 I.7): `xml `, `uuid`,
            // and `uinf` may appear anywhere after the file type box. Their
            // content is opaque to the codec; the box framing is validated
            // by nextBox and a uuid payload must at least carry its 16-byte
            // identifier.
            @intFromEnum(BoxType.xml),
            @intFromEnum(BoxType.uuid_info),
            => {
                if (!saw_ftyp) return Jp2Error.InvalidBox;
            },
            @intFromEnum(BoxType.uuid) => {
                if (!saw_ftyp) return Jp2Error.InvalidBox;
                if (box.payload.len < 16) return Jp2Error.InvalidBox;
            },
            else => return Jp2Error.InvalidBox,
        }
        box_index += 1;
    }

    if (!saw_signature or !saw_ftyp or !saw_jp2h or !saw_jp2c) {
        return Jp2Error.MissingRequiredBox;
    }
    return info;
}

pub fn extractCodestream(bytes: []const u8) ![]const u8 {
    _ = try parseInfo(bytes);
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const box = try nextBox(bytes, &cursor, true);
        if (box.kind == @intFromEnum(BoxType.contiguous_codestream)) {
            return box.payload;
        }
    }
    return Jp2Error.MissingRequiredBox;
}

pub fn extractIccProfile(allocator: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    const info = try parseInfo(bytes);
    if (!info.has_icc_profile) return null;

    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const box = try nextBox(bytes, &cursor, true);
        if (box.kind == @intFromEnum(BoxType.jp2_header)) {
            return extractIccProfileFromJp2Header(allocator, box.payload);
        }
    }
    return Jp2Error.MissingRequiredBox;
}

const Box = struct {
    kind: u32,
    payload: []const u8,
};

fn extractIccProfileFromJp2Header(allocator: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    // Mirrors parseJp2Header's colr choice: the first *supported*
    // specification wins (method 1 sRGB carries no profile; method 2 carries
    // the restricted ICC bytes); unsupported colr boxes are skipped.
    var cursor: usize = 0;
    while (cursor < bytes.len) {
        const box = try nextBox(bytes, &cursor, false);
        if (box.kind != @intFromEnum(BoxType.color)) continue;
        if (box.payload.len < 3) return Jp2Error.InvalidBox;
        switch (box.payload[0]) {
            1 => {
                if (box.payload.len == 7 and (try readU32Be(box.payload, 3)) == 16) return null;
            },
            2 => {
                if (box.payload.len <= 3) return Jp2Error.UnsupportedProfile;
                return try allocator.dupe(u8, box.payload[3..]);
            },
            else => {},
        }
    }
    return Jp2Error.MissingRequiredBox;
}

fn parseJp2Header(bytes: []const u8, info: *Info) !void {
    var cursor: usize = 0;
    var saw_ihdr = false;
    var saw_bpcc = false;
    var saw_colr = false;
    var chose_colr = false;
    var requires_bpcc = false;
    var box_index: usize = 0;
    while (cursor < bytes.len) {
        const box = try nextBox(bytes, &cursor, false);
        if (box_index == 0 and box.kind != @intFromEnum(BoxType.image_header)) return Jp2Error.InvalidBox;
        switch (box.kind) {
            @intFromEnum(BoxType.image_header) => {
                if (box_index != 0 or saw_ihdr) return Jp2Error.InvalidBox;
                if (box.payload.len != 14) return Jp2Error.InvalidBox;
                info.height = try readU32Be(box.payload, 0);
                info.width = try readU32Be(box.payload, 4);
                info.components = try readU16Be(box.payload, 8);
                const bpc = box.payload[10];
                const compression_type = box.payload[11];
                const colorspace_unknown = box.payload[12];
                const intellectual_property = box.payload[13];
                if (info.width == 0 or info.height == 0) return Jp2Error.InvalidBox;
                // UnkC is a boolean flag (ISO 15444-1 I.5.3.1): 0 = colourspace
                // known, 1 = unknown. Kakadu writes 1; both are legal.
                if (compression_type != 7 or colorspace_unknown > 1 or intellectual_property != 0) {
                    return Jp2Error.UnsupportedProfile;
                }
                if (info.components != 3) return Jp2Error.UnsupportedColorSpace;
                if (bpc == 0xff) {
                    requires_bpcc = true;
                    info.bits_per_component = 0;
                } else {
                    if ((bpc & 0x80) != 0) return Jp2Error.UnsupportedProfile;
                    info.bits_per_component = bpc + 1;
                    if (info.bits_per_component != 8 and info.bits_per_component != 16) {
                        return Jp2Error.UnsupportedColorSpace;
                    }
                }
                saw_ihdr = true;
            },
            @intFromEnum(BoxType.bits_per_component) => {
                if (!saw_ihdr or saw_bpcc or saw_colr) return Jp2Error.InvalidBox;
                if (!requires_bpcc) return Jp2Error.InvalidBox;
                if (box.payload.len != info.components) return Jp2Error.InvalidBox;
                var bits_per_component: u8 = 0;
                for (box.payload) |component_bpc| {
                    if ((component_bpc & 0x80) != 0) return Jp2Error.UnsupportedProfile;
                    const component_bits = (component_bpc & 0x7f) + 1;
                    if (component_bits != 8 and component_bits != 16) {
                        return Jp2Error.UnsupportedColorSpace;
                    }
                    if (bits_per_component == 0) {
                        bits_per_component = component_bits;
                    } else if (component_bits != bits_per_component) {
                        return Jp2Error.UnsupportedColorSpace;
                    }
                }
                if (bits_per_component == 0) return Jp2Error.InvalidBox;
                info.bits_per_component = bits_per_component;
                saw_bpcc = true;
                if (info.components != 3) {
                    return Jp2Error.UnsupportedColorSpace;
                }
            },
            @intFromEnum(BoxType.color) => {
                if (!saw_ihdr) return Jp2Error.InvalidBox;
                if (requires_bpcc and !saw_bpcc) return Jp2Error.MissingRequiredBox;
                if (box.payload.len < 3) return Jp2Error.InvalidBox;
                saw_colr = true;
                const method = box.payload[0];
                // PREC is advisory ordering information and APPROX has the
                // defined values 0..4 (ISO 15444-1 I.5.3.3); both are
                // accepted as informative. A file may carry several colr
                // boxes; a reader uses one it supports. z2000 keeps the
                // first supported specification and skips the rest, matching
                // extractIccProfileFromJp2Header.
                const approximation = box.payload[2];
                if (approximation > 4) return Jp2Error.InvalidBox;
                if (!chose_colr) {
                    switch (method) {
                        1 => {
                            if (box.payload.len != 7) return Jp2Error.UnsupportedProfile;
                            const enum_cs = try readU32Be(box.payload, 3);
                            if (enum_cs == 16) {
                                info.has_icc_profile = false;
                                info.icc_profile_bytes = 0;
                                chose_colr = true;
                            }
                            // Other enumerated colourspaces are skipped; a
                            // later colr box may still be supported.
                        },
                        2 => {
                            if (box.payload.len <= 3) return Jp2Error.UnsupportedProfile;
                            info.has_icc_profile = true;
                            info.icc_profile_bytes = box.payload.len - 3;
                            chose_colr = true;
                        },
                        else => {},
                    }
                }
            },
            @intFromEnum(BoxType.channel_definition) => {
                if (!saw_ihdr) return Jp2Error.InvalidBox;
                if (requires_bpcc and !saw_bpcc) return Jp2Error.MissingRequiredBox;
                try validateIdentityChannelDefinition(box.payload, info.components);
            },
            @intFromEnum(BoxType.palette),
            @intFromEnum(BoxType.component_mapping),
            => {
                if (!saw_ihdr) return Jp2Error.InvalidBox;
                return Jp2Error.UnsupportedProfile;
            },
            @intFromEnum(BoxType.resolution) => {
                if (!saw_ihdr) return Jp2Error.InvalidBox;
                if (requires_bpcc and !saw_bpcc) return Jp2Error.MissingRequiredBox;
                try validateResolutionBox(box.payload);
            },
            // Other optional jp2h boxes are not benign for the narrow RGB
            // profile until their component/colour semantics are implemented.
            else => {
                if (!saw_ihdr) return Jp2Error.InvalidBox;
                if (requires_bpcc and !saw_bpcc) return Jp2Error.MissingRequiredBox;
                return Jp2Error.UnsupportedProfile;
            },
        }
        box_index += 1;
    }
    if (!saw_ihdr or !saw_colr) return Jp2Error.MissingRequiredBox;
    // colr boxes were present but none carried a supported specification.
    if (!chose_colr) return Jp2Error.UnsupportedColorSpace;
    if (requires_bpcc and !saw_bpcc) return Jp2Error.MissingRequiredBox;
}

/// ISO 15444-1 I.5.3.6: the channel definition box is accepted when it
/// describes exactly the identity colour mapping the RGB profile already
/// implies — every codestream channel k is colour component k (Typ 0)
/// associated with colour k+1 (R=1, G=2, B=3), in any entry order. Alpha or
/// auxiliary channel definitions imply component semantics the codec does
/// not implement and fail closed.
fn validateIdentityChannelDefinition(payload: []const u8, components: u16) !void {
    if (payload.len < 2) return Jp2Error.InvalidBox;
    const entry_count = try readU16Be(payload, 0);
    if (payload.len != 2 + @as(usize, entry_count) * 6) return Jp2Error.InvalidBox;
    if (entry_count != components or components != 3) return Jp2Error.UnsupportedProfile;
    var seen = [_]bool{false} ** 3;
    var index: usize = 0;
    while (index < entry_count) : (index += 1) {
        const offset = 2 + index * 6;
        const channel = try readU16Be(payload, offset);
        const channel_type = try readU16Be(payload, offset + 2);
        const association = try readU16Be(payload, offset + 4);
        if (channel >= 3) return Jp2Error.UnsupportedProfile;
        if (seen[channel]) return Jp2Error.InvalidBox;
        seen[channel] = true;
        if (channel_type != 0) return Jp2Error.UnsupportedProfile;
        if (association != channel + 1) return Jp2Error.UnsupportedProfile;
    }
}

/// ISO 15444-1 I.5.3.7: the resolution superbox holds at most one capture
/// (`resc`) and one display (`resd`) resolution box, each a fixed 10-byte
/// record of nonzero numerator/denominator pairs plus exponents. The values
/// are informative for the codec, but the structure is validated so garbage
/// framed as `res ` no longer passes.
fn validateResolutionBox(payload: []const u8) !void {
    if (payload.len == 0) return Jp2Error.InvalidBox;
    var cursor: usize = 0;
    var saw_capture = false;
    var saw_display = false;
    while (cursor < payload.len) {
        const box = try nextBox(payload, &cursor, false);
        switch (box.kind) {
            @intFromEnum(BoxType.capture_resolution) => {
                if (saw_capture) return Jp2Error.InvalidBox;
                saw_capture = true;
            },
            @intFromEnum(BoxType.display_resolution) => {
                if (saw_display) return Jp2Error.InvalidBox;
                saw_display = true;
            },
            else => return Jp2Error.InvalidBox,
        }
        if (box.payload.len != 10) return Jp2Error.InvalidBox;
        const vertical_numerator = try readU16Be(box.payload, 0);
        const vertical_denominator = try readU16Be(box.payload, 2);
        const horizontal_numerator = try readU16Be(box.payload, 4);
        const horizontal_denominator = try readU16Be(box.payload, 6);
        if (vertical_numerator == 0 or vertical_denominator == 0 or
            horizontal_numerator == 0 or horizontal_denominator == 0)
        {
            return Jp2Error.InvalidBox;
        }
    }
}

fn validateFileTypeBox(payload: []const u8) !void {
    if (payload.len < 8 or (payload.len - 8) % 4 != 0) return Jp2Error.InvalidBox;
    if (try readU32Be(payload, 0) != brand_jp2) return Jp2Error.UnsupportedProfile;
    if (try readU32Be(payload, 4) != 0) return Jp2Error.UnsupportedProfile;

    var compatible = false;
    var cursor: usize = 8;
    while (cursor < payload.len) : (cursor += 4) {
        const compatibility = try readU32Be(payload, cursor);
        if (compatibility != brand_jp2) return Jp2Error.UnsupportedProfile;
        compatible = true;
    }
    if (!compatible) return Jp2Error.UnsupportedProfile;
}

fn validateCodestreamPayload(payload: []const u8, expected: CodestreamShape) !void {
    if (payload.len < 4) return Jp2Error.InvalidCodestream;
    if (try readU16Be(payload, 0) != marker_soc) return Jp2Error.InvalidCodestream;
    if (try readU16Be(payload, payload.len - 2) != marker_eoc) return Jp2Error.InvalidCodestream;
    if (payload.len < 8 or try readU16Be(payload, 2) != marker_siz) return Jp2Error.InvalidCodestream;

    const lsiz = try readU16Be(payload, 4);
    if (lsiz < 38) return Jp2Error.InvalidCodestream;
    const segment_end = std.math.add(usize, 4, lsiz) catch return Jp2Error.InvalidCodestream;
    if (segment_end > payload.len - 2) return Jp2Error.InvalidCodestream;
    if (segment_end < payload.len - 2) {
        const marker_prefix = payload[segment_end];
        const marker_code = payload[segment_end + 1];
        if (marker_prefix != 0xff or marker_code == 0x00 or marker_code == 0xff) {
            return Jp2Error.InvalidCodestream;
        }
    }
    const segment = payload[6..segment_end];
    const rsiz = try readU16Be(segment, 0);
    if (rsiz != 0) return Jp2Error.UnsupportedProfile;
    const components = try readU16Be(segment, 34);
    if (components == 0 or segment.len != 36 + @as(usize, components) * 3) {
        return Jp2Error.InvalidCodestream;
    }
    if (@as(usize, lsiz) != 38 + @as(usize, components) * 3) return Jp2Error.InvalidCodestream;

    const xsiz = try readU32Be(segment, 2);
    const ysiz = try readU32Be(segment, 6);
    const xosiz = try readU32Be(segment, 10);
    const yosiz = try readU32Be(segment, 14);
    const xtsiz = try readU32Be(segment, 18);
    const ytsiz = try readU32Be(segment, 22);
    const xtosiz = try readU32Be(segment, 26);
    const ytosiz = try readU32Be(segment, 30);
    if (xsiz <= xosiz or ysiz <= yosiz) return Jp2Error.InvalidCodestream;
    if (xosiz != 0 or yosiz != 0) return Jp2Error.UnsupportedProfile;
    if (xtsiz == 0 or ytsiz == 0) return Jp2Error.InvalidCodestream;
    if (xtosiz != xosiz or ytosiz != yosiz) return Jp2Error.UnsupportedProfile;
    const width = xsiz - xosiz;
    const height = ysiz - yosiz;
    // Multi-tile SIZ (XTSiz < width) is accepted: with zero tile offsets any
    // nonzero tile size partitions the image into a valid ISO B.3 grid.
    const tile_columns = (@as(u64, width) + xtsiz - 1) / xtsiz;
    const tile_rows = (@as(u64, height) + ytsiz - 1) / ytsiz;
    const tile_count_u64 = tile_columns * tile_rows;
    // The tile-part walker tracks up to 256 TLM entries; larger grids stay
    // unsupported in the wrapper profile until the walker is generalized.
    if (tile_count_u64 == 0 or tile_count_u64 > 256) return Jp2Error.UnsupportedProfile;
    const tile_count: u32 = @intCast(tile_count_u64);
    const bits_per_component = (segment[36] & 0x7f) + 1;
    if ((segment[36] & 0x80) != 0) return Jp2Error.UnsupportedProfile;
    if (width != expected.width or
        height != expected.height or
        components != expected.components or
        bits_per_component != expected.bits_per_component)
    {
        return Jp2Error.InvalidCodestream;
    }

    var component_index: usize = 0;
    while (component_index < components) : (component_index += 1) {
        const component_offset = 36 + component_index * 3;
        const ssiz = segment[component_offset];
        if ((ssiz & 0x80) != 0) return Jp2Error.UnsupportedProfile;
        if ((ssiz & 0x7f) + 1 != bits_per_component) return Jp2Error.InvalidCodestream;
        if (segment[component_offset + 1] != 1 or segment[component_offset + 2] != 1) {
            return Jp2Error.UnsupportedProfile;
        }
    }
    try validateMainHeaderMarkers(payload, segment_end, tile_count);
}

fn validateMainHeaderMarkers(payload: []const u8, cursor_after_siz: usize, tile_count: u32) !void {
    var cursor = cursor_after_siz;
    var cod_info: ?CodSegmentInfo = null;
    var cod_payload: []const u8 = &.{};
    var saw_qcd = false;
    var qcd_payload: []const u8 = &.{};
    var tlm_state = TlmState{};
    var ppm_state = PpmState{};
    var override_state = ComponentOverrideState{};
    while (cursor < payload.len - 2) {
        const marker = try readU16Be(payload, cursor);
        if ((marker >> 8) != 0xff) return Jp2Error.InvalidCodestream;
        switch (marker) {
            marker_sot => {
                if (cod_info == null or !saw_qcd) return Jp2Error.InvalidCodestream;
                try validateUniformComponentOverrides(&override_state, cod_payload, qcd_payload);
                if (tile_count == 1) {
                    try validateTilePartSequence(payload, cursor, cod_info.?, if (tlm_state.saw) &tlm_state else null, ppm_state.saw);
                } else {
                    try validateMultiTileTilePartSequence(payload, cursor, cod_info.?, if (tlm_state.saw) &tlm_state else null, tile_count, ppm_state.saw);
                }
                return;
            },
            marker_cod => {
                if (cod_info != null) return Jp2Error.InvalidCodestream;
            },
            marker_qcd => {
                if (cod_info == null) return Jp2Error.InvalidCodestream;
                if (saw_qcd) return Jp2Error.InvalidCodestream;
            },
            marker_tlm => {
                if (cod_info == null or !saw_qcd) return Jp2Error.InvalidCodestream;
            },
            marker_com => {},
            // COC/QCC are accepted structurally here (after their main COD/QCD);
            // the strict codestream reader enforces that they byte-replicate the
            // main marker (z2000 has no per-component coding/quantization path).
            marker_coc => {
                if (cod_info == null) return Jp2Error.InvalidCodestream;
            },
            marker_qcc => {
                if (cod_info == null or !saw_qcd) return Jp2Error.InvalidCodestream;
            },
            marker_ppm => {
                if (!saw_qcd) return Jp2Error.InvalidCodestream;
            },
            marker_cap, marker_rgn, marker_poc, marker_ppt, marker_crg => {
                return Jp2Error.UnsupportedProfile;
            },
            marker_soc, marker_siz, marker_sod, marker_eoc => return Jp2Error.InvalidCodestream,
            else => return Jp2Error.UnsupportedProfile,
        }

        const length_offset = std.math.add(usize, cursor, 2) catch return Jp2Error.InvalidCodestream;
        const marker_length = try readU16Be(payload, length_offset);
        try validateMarkerSegmentLength(marker, marker_length);
        const next = std.math.add(usize, length_offset, marker_length) catch return Jp2Error.InvalidCodestream;
        if (next > payload.len - 2) return Jp2Error.InvalidCodestream;
        switch (marker) {
            marker_cod => {
                cod_info = try validateCodSegment(payload, length_offset, marker_length);
                cod_payload = payload[length_offset + 2 .. length_offset + marker_length];
            },
            marker_qcd => {
                try validateQcdSegment(payload, length_offset, marker_length, cod_info.?);
                qcd_payload = payload[length_offset + 2 .. length_offset + marker_length];
                saw_qcd = true;
            },
            marker_coc => try validateUniformCocSegment(payload, length_offset, marker_length, cod_payload, &override_state),
            marker_qcc => try validateUniformQccSegment(payload, length_offset, marker_length, cod_info.?, &override_state),
            else => try validateMainHeaderMarkerSegment(payload, marker, length_offset, marker_length, &tlm_state, &ppm_state),
        }
        cursor = next;
    }
}

fn validateTilePartSequence(
    payload: []const u8,
    first_sot_offset: usize,
    cod: CodSegmentInfo,
    tlm_state: ?*const TlmState,
    has_ppm: bool,
) !void {
    var cursor = first_sot_offset;
    var expected_tile_part_index: u8 = 0;
    var tile_part_count: ?u8 = null;
    var packet_sequence: u16 = 0;
    var ppt_state = PptState{};
    while (cursor < payload.len - 2) {
        if (try readU16Be(payload, cursor) != marker_sot) return Jp2Error.InvalidCodestream;
        const expected_psot = if (tlm_state) |state| blk: {
            if (expected_tile_part_index >= state.count) return Jp2Error.InvalidCodestream;
            if (state.tile_indices[expected_tile_part_index] != 0) return Jp2Error.InvalidCodestream;
            break :blk state.lengths[expected_tile_part_index];
        } else null;
        cursor = try validateSotSegment(payload, cursor, expected_tile_part_index, expected_psot, cod, &packet_sequence, &tile_part_count, &ppt_state, has_ppm);
        expected_tile_part_index = std.math.add(u8, expected_tile_part_index, 1) catch return Jp2Error.InvalidCodestream;
    }
    if (cursor != payload.len - 2) return Jp2Error.InvalidCodestream;
    const expected_count = tile_part_count orelse return Jp2Error.InvalidCodestream;
    if (expected_tile_part_index != expected_count) return Jp2Error.InvalidCodestream;
    if (tlm_state) |state| {
        if (state.count != expected_count) return Jp2Error.InvalidCodestream;
    }
}

/// Multi-tile tile-part discipline: one-part tiles may appear in any unique
/// tile order (Kakadu writes some small grids as 0,1,3,2). Resolution-divided
/// tiles carry exactly NL+1 consecutive parts with TPsot increasing from zero.
fn validateMultiTileTilePartSequence(
    payload: []const u8,
    first_sot_offset: usize,
    cod: CodSegmentInfo,
    tlm_state: ?*const TlmState,
    tile_count: u32,
    has_ppm: bool,
) !void {
    if (tile_count > 256) return Jp2Error.UnsupportedProfile;
    var next_parts = [_]u8{0} ** 256;
    var expected_parts = [_]u8{0} ** 256;
    var completed_tiles = [_]bool{false} ** 256;
    var packet_sequences = [_]u16{0} ** 256;
    var ppt_states = [_]PptState{.{}} ** 256;
    var cursor = first_sot_offset;
    var sequence_index: u32 = 0;
    while (cursor < payload.len - 2) {
        if (try readU16Be(payload, cursor) != marker_sot) return Jp2Error.InvalidCodestream;
        const length_offset = std.math.add(usize, cursor, 2) catch return Jp2Error.InvalidCodestream;
        if (try readU16Be(payload, length_offset) != 10) return Jp2Error.InvalidCodestream;
        const segment_end = length_offset + 10;
        if (segment_end > payload.len - 2) return Jp2Error.InvalidCodestream;
        const sot_tile_index = try readU16Be(payload, cursor + 4);
        const tile_part_length = try readU32Be(payload, cursor + 6);
        const sot_tile_part_index = payload[cursor + 10];
        const tile_part_total = payload[cursor + 11];
        if (sot_tile_index >= tile_count) return Jp2Error.InvalidCodestream;
        // Any TNsot is structurally acceptable here: 0 means "count not
        // signalled in this part" (ISO A.4.2), nonzero values must agree
        // across the tile and exceed the current part index. Each part's
        // header is validated below, and the strict decoder enforces the
        // per-part PLT packet accounting (non-empty PLT-less multi-part
        // tiles still fail closed there).
        const state_index = @as(usize, sot_tile_index);
        if (completed_tiles[state_index]) return Jp2Error.InvalidCodestream;
        if (tile_part_total != 0) {
            if (tile_part_total <= sot_tile_part_index) return Jp2Error.InvalidCodestream;
            if (expected_parts[state_index] == 0) {
                expected_parts[state_index] = tile_part_total;
            } else if (expected_parts[state_index] != tile_part_total) {
                return Jp2Error.InvalidCodestream;
            }
        }
        if (sot_tile_part_index != next_parts[state_index]) return Jp2Error.InvalidCodestream;
        if (tile_part_length == 0) return Jp2Error.UnsupportedProfile;
        if (tlm_state) |state| {
            if (sequence_index >= state.count) return Jp2Error.InvalidCodestream;
            if (state.tile_indices[sequence_index] != sot_tile_index) return Jp2Error.InvalidCodestream;
            if (state.lengths[sequence_index] != tile_part_length) return Jp2Error.InvalidCodestream;
        }
        const tile_part_end = std.math.add(usize, cursor, tile_part_length) catch return Jp2Error.InvalidCodestream;
        if (tile_part_end > payload.len - 2) return Jp2Error.InvalidCodestream;
        try validateFirstTilePartHeader(payload, segment_end, tile_part_end, cod, &packet_sequences[state_index], &ppt_states[state_index], has_ppm);
        cursor = tile_part_end;
        next_parts[state_index] = std.math.add(u8, next_parts[state_index], 1) catch return Jp2Error.InvalidCodestream;
        if (expected_parts[state_index] != 0 and next_parts[state_index] == expected_parts[state_index]) {
            completed_tiles[state_index] = true;
        }
        sequence_index += 1;
    }
    if (cursor != payload.len - 2) return Jp2Error.InvalidCodestream;
    // Tiles whose count was never signalled (TNsot 0 everywhere) are
    // structurally complete with at least one part; the strict decoder's
    // packet accounting decides whether the data is actually whole.
    for (completed_tiles[0..tile_count], next_parts[0..tile_count], expected_parts[0..tile_count]) |completed, next, expected| {
        if (completed) continue;
        if (expected == 0 and next > 0) continue;
        return Jp2Error.InvalidCodestream;
    }
    if (tlm_state) |state| {
        if (state.count != sequence_index) return Jp2Error.InvalidCodestream;
    }
}

fn validateSotSegment(
    payload: []const u8,
    marker_offset: usize,
    expected_tile_part_index: u8,
    expected_tile_part_length: ?u32,
    cod: CodSegmentInfo,
    packet_sequence: *u16,
    tile_part_count: *?u8,
    ppt_state: *PptState,
    has_ppm: bool,
) !usize {
    const length_offset = std.math.add(usize, marker_offset, 2) catch return Jp2Error.InvalidCodestream;
    const marker_length = try readU16Be(payload, length_offset);
    if (marker_length != 10) return Jp2Error.InvalidCodestream;
    const segment_end = std.math.add(usize, length_offset, marker_length) catch return Jp2Error.InvalidCodestream;
    if (segment_end > payload.len - 2) return Jp2Error.InvalidCodestream;
    const tile_index = try readU16Be(payload, marker_offset + 4);
    const tile_part_length = try readU32Be(payload, marker_offset + 6);
    const tile_part_index = payload[marker_offset + 10];
    const current_tile_part_count = payload[marker_offset + 11];
    if (tile_index != 0 or tile_part_index != expected_tile_part_index or current_tile_part_count == 0) {
        return Jp2Error.UnsupportedProfile;
    }
    if (tile_part_count.*) |expected_count| {
        if (current_tile_part_count != expected_count) return Jp2Error.InvalidCodestream;
    } else {
        tile_part_count.* = current_tile_part_count;
    }
    if (tile_part_length == 0) return Jp2Error.UnsupportedProfile;
    if (expected_tile_part_length) |expected_length| {
        if (tile_part_length != expected_length) return Jp2Error.InvalidCodestream;
    }
    const tile_part_end = std.math.add(usize, marker_offset, tile_part_length) catch return Jp2Error.InvalidCodestream;
    if (tile_part_end > payload.len - 2) return Jp2Error.InvalidCodestream;
    try validateFirstTilePartHeader(payload, segment_end, tile_part_end, cod, packet_sequence, ppt_state, has_ppm);
    return tile_part_end;
}

fn validateFirstTilePartHeader(
    payload: []const u8,
    start: usize,
    end: usize,
    cod: CodSegmentInfo,
    packet_sequence: *u16,
    ppt_state: *PptState,
    has_ppm: bool,
) !void {
    var cursor = start;
    var plt_state = PltState{};
    var part_has_ppt = false;
    while (cursor < end) {
        const marker = try readU16Be(payload, cursor);
        if ((marker >> 8) != 0xff) return Jp2Error.InvalidCodestream;
        switch (marker) {
            marker_sod => {
                const payload_start = std.math.add(usize, cursor, 2) catch return Jp2Error.InvalidCodestream;
                if (payload_start > end) return Jp2Error.InvalidCodestream;
                if (plt_state.saw) {
                    if (plt_state.packet_bytes != end - payload_start) {
                        return Jp2Error.InvalidCodestream;
                    }
                    if (has_ppm) {
                        if (part_has_ppt or cod.sop or cod.eph) return Jp2Error.UnsupportedProfile;
                    } else if (part_has_ppt) {
                        if (cod.sop or cod.eph or ppt_state.header_bytes == 0) return Jp2Error.UnsupportedProfile;
                    } else {
                        try validateTilePartPacketFrames(payload, start, cursor, payload_start, end, cod, packet_sequence);
                    }
                } else if (part_has_ppt) {
                    return Jp2Error.UnsupportedProfile;
                }
                // PLT-less tile-parts (default OpenJPEG/Grok/Kakadu output):
                // packet spans are recoverable only by decoding the headers in
                // stream order, which the strict decoder does (foreign
                // Stage B); the wrapper skips per-packet frame validation.
                return;
            },
            marker_plt, marker_com => {},
            marker_ppt => part_has_ppt = true,
            marker_sot, marker_eoc => return Jp2Error.InvalidCodestream,
            else => return Jp2Error.UnsupportedProfile,
        }

        const length_offset = std.math.add(usize, cursor, 2) catch return Jp2Error.InvalidCodestream;
        const marker_length = try readU16Be(payload, length_offset);
        try validateMarkerSegmentLength(marker, marker_length);
        const next = std.math.add(usize, length_offset, marker_length) catch return Jp2Error.InvalidCodestream;
        if (next > end) return Jp2Error.InvalidCodestream;
        try validateTilePartHeaderMarkerSegment(payload, marker, length_offset, marker_length, &plt_state, ppt_state);
        cursor = next;
    }
    return Jp2Error.InvalidCodestream;
}

fn validateMarkerSegmentLength(marker: u16, marker_length: u16) !void {
    const min_length: u16 = switch (marker) {
        marker_cod => 12,
        marker_qcd => 4,
        marker_coc => 5, // Lcoc(2) Ccoc(1) Scoc(1) + >=1 SPcoc byte
        marker_qcc => 4, // Lqcc(2) Cqcc(1) Sqcc(1)
        marker_tlm => 9,
        marker_plt => 4,
        marker_ppm => 4,
        marker_ppt => 4,
        marker_com => 4,
        else => 2,
    };
    if (marker_length < min_length) return Jp2Error.InvalidCodestream;
}

fn validateMainHeaderMarkerSegment(
    payload: []const u8,
    marker: u16,
    length_offset: usize,
    marker_length: u16,
    tlm_state: *TlmState,
    ppm_state: *PpmState,
) !void {
    switch (marker) {
        marker_tlm => try validateTlmSegment(payload, length_offset, marker_length, tlm_state),
        marker_ppm => {
            if (ppm_state.expected_segment_index > std.math.maxInt(u8) or
                payload[length_offset + 2] != @as(u8, @intCast(ppm_state.expected_segment_index)))
            {
                return Jp2Error.InvalidCodestream;
            }
            ppm_state.expected_segment_index += 1;
            ppm_state.saw = true;
        },
        else => {},
    }
}

fn validateCodSegment(payload: []const u8, length_offset: usize, marker_length: u16) !CodSegmentInfo {
    const scod = payload[length_offset + 2];
    if ((scod & ~@as(u8, 0x07)) != 0) return Jp2Error.InvalidCodestream;
    // All five Part 1 progression orders (LRCP..CPRL, values 0-4) are wired
    // through the codestream layer; higher values are undefined.
    const progression = payload[length_offset + 3];
    if (progression > 4) return Jp2Error.UnsupportedProfile;
    const layers = try readU16Be(payload, length_offset + 4);
    if (layers == 0) return Jp2Error.InvalidCodestream;
    if (layers > rate_alloc.max_layers) return Jp2Error.UnsupportedProfile;
    const mct = payload[length_offset + 6];
    if (mct != 0 and mct != 1) return Jp2Error.UnsupportedProfile;
    const levels = payload[length_offset + 7];
    if (levels > 32) return Jp2Error.InvalidCodestream;
    const block_width = try codeBlockSizeFromCodExponent(payload[length_offset + 8]);
    const block_height = try codeBlockSizeFromCodExponent(payload[length_offset + 9]);
    if (@as(u32, block_width) * @as(u32, block_height) > 4096) return Jp2Error.InvalidCodestream;
    try validateCodeBlockStyleByte(payload[length_offset + 10]);
    const transform = payload[length_offset + 11];
    if (transform != 0 and transform != 1) return Jp2Error.InvalidCodestream;
    // Scod bit 0 unset (no precinct partition, ISO B.6) is a supported
    // profile: the codestream layer maps it to maximal 2^15 precincts.
    const precinct_bytes: u16 = if ((scod & 0x01) != 0) @as(u16, levels) + 1 else 0;
    if (marker_length != 12 + precinct_bytes) return Jp2Error.InvalidCodestream;
    try validateCodPrecinctBytes(payload, length_offset + 12, precinct_bytes);
    return .{
        .levels = levels,
        .transform = transform,
        .sop = (scod & 0x02) != 0,
        .eph = (scod & 0x04) != 0,
    };
}

fn validateCodPrecinctBytes(payload: []const u8, start: usize, count: u16) !void {
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const value = payload[start + index];
        const width_exponent = value & 0x0f;
        const height_exponent = value >> 4;
        if (width_exponent > 15 or height_exponent > 15) return Jp2Error.InvalidCodestream;
    }
}

fn codeBlockSizeFromCodExponent(exponent: u8) !u16 {
    if (exponent > 8) return Jp2Error.InvalidCodestream;
    return @as(u16, 1) << @as(u4, @intCast(exponent + 2));
}

fn validateCodeBlockStyleByte(code_block_style: u8) !void {
    if ((code_block_style & 0xc0) != 0) return Jp2Error.InvalidCodestream;
    // BYPASS (0x01), RESET (0x02), TERMALL (0x04), CAUSAL (0x08), ERTERM
    // (0x10), and SEGMARK (0x20) all have implemented payload models in
    // every combination; only the two reserved bits stay rejected.
    if ((code_block_style & ~@as(u8, 0x3f)) != 0) return Jp2Error.UnsupportedProfile;
}

/// Cross-marker state for COC/QCC handling: z2000 accepts them either as
/// byte-replications of the main COD/QCD or as a *uniform override* where
/// every RGB component carries identical data (Kakadu signals uniform
/// per-component Cmodes/Qguard requests this way). Genuinely per-component
/// divergence fails closed in validateUniformComponentOverrides.
const ComponentOverrideState = struct {
    coc_seen: [3]bool = .{ false, false, false },
    coc_first: []const u8 = &.{},
    qcc_seen: [3]bool = .{ false, false, false },
    qcc_first: []const u8 = &.{},
};

fn validateUniformCocSegment(payload: []const u8, length_offset: usize, marker_length: u16, cod_payload: []const u8, state: *ComponentOverrideState) !void {
    if (cod_payload.len < 6) return Jp2Error.InvalidCodestream;
    const component = payload[length_offset + 2];
    if (component >= 3) return Jp2Error.UnsupportedProfile;
    const scoc = payload[length_offset + 3];
    if ((scoc & ~@as(u8, 0x01)) != 0) return Jp2Error.InvalidCodestream;
    if ((scoc & 0x01) != (cod_payload[0] & 0x01)) return Jp2Error.UnsupportedProfile;
    const coc_coding = payload[length_offset + 4 .. length_offset + marker_length];
    try validateCocCodingPayload(coc_coding, scoc);
    if (state.coc_seen[component]) return Jp2Error.InvalidCodestream;
    state.coc_seen[component] = true;
    const coc_body = payload[length_offset + 3 .. length_offset + marker_length];
    if (state.coc_first.len == 0) {
        state.coc_first = coc_body;
    } else if (!std.mem.eql(u8, coc_body, state.coc_first)) {
        return Jp2Error.UnsupportedProfile;
    }
}

fn validateUniformComponentOverrides(state: *ComponentOverrideState, cod_payload: []const u8, qcd_payload: []const u8) !void {
    if (state.coc_first.len != 0) {
        const spcoc = state.coc_first[1..];
        const cod_coding = cod_payload[5..];
        if (!std.mem.eql(u8, spcoc, cod_coding)) {
            // A uniform override requires every component and may differ from
            // the COD only in the code-block style byte; the style itself must
            // be implemented. Redundant byte-replication is fine on its own.
            if (!state.coc_seen[0] or !state.coc_seen[1] or !state.coc_seen[2]) {
                return Jp2Error.UnsupportedProfile;
            }
            if (spcoc.len != cod_coding.len or spcoc.len < 5) return Jp2Error.UnsupportedProfile;
            for (spcoc, cod_coding, 0..) |coc_byte, cod_byte, index| {
                if (index == 3) continue;
                if (coc_byte != cod_byte) return Jp2Error.UnsupportedProfile;
            }
            try validateCodeBlockStyleByte(spcoc[3]);
        }
    }
    if (state.qcc_first.len != 0) {
        // A uniform QCC override replaces the QCD wholesale and requires all
        // components; each segment was already bounds-validated, so the JP2
        // boundary only enforces the uniformity (strict decode consumes the
        // signalled values). Redundant byte-replication is fine on its own.
        if (!std.mem.eql(u8, state.qcc_first, qcd_payload)) {
            if (!state.qcc_seen[0] or !state.qcc_seen[1] or !state.qcc_seen[2]) {
                return Jp2Error.UnsupportedProfile;
            }
        }
    }
}

fn validateCocCodingPayload(segment: []const u8, scoc: u8) !void {
    if (segment.len < 5) return Jp2Error.InvalidCodestream;
    const levels = segment[0];
    if (levels > 32) return Jp2Error.InvalidCodestream;
    const block_width = try codeBlockSizeFromCodExponent(segment[1]);
    const block_height = try codeBlockSizeFromCodExponent(segment[2]);
    if (@as(u32, block_width) * @as(u32, block_height) > 4096) return Jp2Error.InvalidCodestream;
    try validateCodeBlockStyleByte(segment[3]);
    const transform = segment[4];
    if (transform != 0 and transform != 1) return Jp2Error.InvalidCodestream;
    const precinct_bytes: usize = if ((scoc & 0x01) != 0) @as(usize, levels) + 1 else 0;
    if (segment.len != 5 + precinct_bytes) return Jp2Error.InvalidCodestream;
    try validateCodPrecinctBytes(segment, 5, @intCast(precinct_bytes));
}

fn validateUniformQccSegment(payload: []const u8, length_offset: usize, marker_length: u16, cod: CodSegmentInfo, state: *ComponentOverrideState) !void {
    const component = payload[length_offset + 2];
    if (component >= 3) return Jp2Error.UnsupportedProfile;
    const qcc_quantization = payload[length_offset + 3 .. length_offset + marker_length];
    try validateQcdPayloadBytes(qcc_quantization, cod);
    if (state.qcc_seen[component]) return Jp2Error.InvalidCodestream;
    state.qcc_seen[component] = true;
    if (state.qcc_first.len == 0) {
        state.qcc_first = qcc_quantization;
    } else if (!std.mem.eql(u8, qcc_quantization, state.qcc_first)) {
        return Jp2Error.UnsupportedProfile;
    }
}

fn validateQcdSegment(payload: []const u8, length_offset: usize, marker_length: u16, cod: CodSegmentInfo) !void {
    try validateQcdPayloadBytes(payload[length_offset + 2 .. length_offset + marker_length], cod);
}

fn validateQcdPayloadBytes(segment: []const u8, cod: CodSegmentInfo) !void {
    if (segment.len < 1) return Jp2Error.InvalidCodestream;
    const style = segment[0];
    const guard_bits = style >> 5;
    const quantization_style = style & 0x1f;
    if (quantization_style > 2) return Jp2Error.InvalidCodestream;
    // The JP2 boundary validates the QCD shape and bounds. Strict codestream
    // decode consumes the signalled irreversible step sizes for Mb sizing and
    // dequantization; the wrapper must not require z2000's local norm table.
    if (cod.transform != 1) {
        if (guard_bits == 0 or guard_bits > 7) return Jp2Error.InvalidCodestream;
    } else if (guard_bits == 0 or guard_bits > 7) {
        return Jp2Error.InvalidCodestream;
    }
    const bands: u16 = 1 + 3 * @as(u16, cod.levels);
    if (cod.transform == 0) {
        if (quantization_style == 1) {
            // Scalar-derived (A.6.4): a single signalled step for the NL LL
            // band; every other subband is derived via E-5.
            if (segment.len != 1 + 2) return Jp2Error.InvalidCodestream;
            var cursor: usize = 1;
            try validateScalarQcdStep(segment, &cursor, guard_bits);
            return;
        }
        if (quantization_style != 2) return Jp2Error.UnsupportedProfile;
        if (segment.len != 1 + 2 * bands) return Jp2Error.InvalidCodestream;
        try validateScalarQcdSteps(segment, 1, bands, guard_bits);
    } else {
        if (quantization_style != 0) return Jp2Error.UnsupportedProfile;
        if (segment.len != 1 + bands) return Jp2Error.InvalidCodestream;
        try validateReversibleQcdExponents(segment, 1, bands, guard_bits);
    }
}

fn validateScalarQcdSteps(payload: []const u8, start: usize, bands: u16, guard_bits: u8) !void {
    var cursor = start;
    var band: u16 = 0;
    while (band < bands) : (band += 1) {
        try validateScalarQcdStep(payload, &cursor, guard_bits);
    }
}

fn validateScalarQcdStep(payload: []const u8, cursor: *usize, guard_bits: u8) !void {
    const value = try readU16Be(payload, cursor.*);
    cursor.* += 2;
    const epsilon: u8 = @intCast(value >> 11);
    if (epsilon == 0) return Jp2Error.InvalidCodestream;
    const nominal = @as(u16, epsilon) + guard_bits - 1;
    if (nominal == 0 or nominal > 31) return Jp2Error.InvalidCodestream;
}

/// Reversible SPqcd values carry epsilon_b in bits 7..3 (low bits must be
/// zero). Foreign encoders choose legal exponents that differ from z2000's
/// formula (Kakadu widens for the RCT), so the wrapper only bounds-checks:
/// Mb = guard + epsilon - 1 must land in 1..31 (E-2).
fn validateReversibleQcdExponents(payload: []const u8, start: usize, bands: u16, guard_bits: u8) !void {
    var cursor = start;
    var band: u16 = 0;
    while (band < bands) : (band += 1) {
        const value = payload[cursor];
        if ((value & 0x07) != 0) return Jp2Error.UnsupportedProfile;
        const epsilon = value >> 3;
        if (epsilon == 0) return Jp2Error.InvalidCodestream;
        const nominal = @as(u16, epsilon) + guard_bits - 1;
        if (nominal == 0 or nominal > 31) return Jp2Error.InvalidCodestream;
        cursor += 1;
    }
}

const SubbandKind = enum { ll, hl, lh, hh };

fn reversibleQcdExponentByte(bit_depth: u8, kind: SubbandKind) !u8 {
    if (bit_depth == 0) return Jp2Error.InvalidCodestream;
    const gain: u8 = switch (kind) {
        .ll => 0,
        .hl, .lh => 1,
        .hh => 2,
    };
    const exponent = std.math.add(u8, bit_depth, gain) catch return Jp2Error.InvalidCodestream;
    if (exponent > 31) return Jp2Error.InvalidCodestream;
    return exponent << 3;
}

fn validateTlmSegment(payload: []const u8, length_offset: usize, marker_length: u16, state: *TlmState) !void {
    if (payload[length_offset + 2] != state.next_segment_index) return Jp2Error.UnsupportedProfile;
    // Stlm 0x50: ST=1/SP=1 (u8 tile index + u32 length), the single-tile
    // resolution-part layout. Stlm 0x60: ST=2/SP=1 (u16 tile index + u32
    // length), the multi-tile one-part-per-tile layout.
    const stlm = payload[length_offset + 3];
    const entry_bytes: usize = switch (stlm) {
        0x50 => 5,
        0x60 => 6,
        else => return Jp2Error.UnsupportedProfile,
    };
    if ((marker_length - 4) % entry_bytes != 0) return Jp2Error.InvalidCodestream;
    state.next_segment_index = std.math.add(u8, state.next_segment_index, 1) catch return Jp2Error.InvalidCodestream;
    var cursor = length_offset + 4;
    const end = length_offset + @as(usize, marker_length);
    while (cursor < end) : (cursor += entry_bytes) {
        if (state.count >= state.lengths.len) return Jp2Error.UnsupportedProfile;
        const tile_index: u16 = switch (stlm) {
            0x50 => blk: {
                if (payload[cursor] != 0) return Jp2Error.UnsupportedProfile;
                break :blk 0;
            },
            0x60 => try readU16Be(payload, cursor),
            else => unreachable,
        };
        const tile_part_length = try readU32Be(payload, cursor + (entry_bytes - 4));
        if (tile_part_length == 0) return Jp2Error.InvalidCodestream;
        state.tile_indices[state.count] = tile_index;
        state.lengths[state.count] = tile_part_length;
        state.count = std.math.add(u16, state.count, 1) catch return Jp2Error.InvalidCodestream;
    }
    state.saw = true;
}

fn validateTilePartHeaderMarkerSegment(
    payload: []const u8,
    marker: u16,
    length_offset: usize,
    marker_length: u16,
    plt_state: *PltState,
    ppt_state: *PptState,
) !void {
    switch (marker) {
        marker_plt => try validatePltSegment(payload, length_offset, marker_length, plt_state),
        marker_ppt => try validatePptSegment(payload, length_offset, marker_length, ppt_state),
        else => {},
    }
}

fn validatePptSegment(payload: []const u8, length_offset: usize, marker_length: u16, state: *PptState) !void {
    if (state.expected_segment_index > std.math.maxInt(u8) or
        payload[length_offset + 2] != @as(u8, @intCast(state.expected_segment_index)))
    {
        return Jp2Error.InvalidCodestream;
    }
    state.expected_segment_index += 1;
    const data_bytes = @as(usize, marker_length) - 3;
    if (data_bytes == 0) return Jp2Error.InvalidCodestream;
    state.header_bytes = std.math.add(usize, state.header_bytes, data_bytes) catch return Jp2Error.InvalidCodestream;
    state.saw = true;
}

fn validatePltSegment(payload: []const u8, length_offset: usize, marker_length: u16, state: *PltState) !void {
    if (payload[length_offset + 2] != state.expected_segment_index) return Jp2Error.InvalidCodestream;
    state.expected_segment_index = std.math.add(u8, state.expected_segment_index, 1) catch return Jp2Error.InvalidCodestream;

    var cursor = length_offset + 3;
    const end = length_offset + @as(usize, marker_length);
    var packet_length: usize = 0;
    var pending_length = false;
    while (cursor < end) : (cursor += 1) {
        packet_length = std.math.mul(usize, packet_length, 128) catch return Jp2Error.InvalidCodestream;
        packet_length = std.math.add(usize, packet_length, @as(usize, payload[cursor] & 0x7f)) catch return Jp2Error.InvalidCodestream;
        pending_length = true;
        if ((payload[cursor] & 0x80) == 0) {
            state.packet_bytes = std.math.add(usize, state.packet_bytes, packet_length) catch return Jp2Error.InvalidCodestream;
            packet_length = 0;
            pending_length = false;
            state.saw = true;
        }
    }
    if (pending_length) return Jp2Error.InvalidCodestream;
}

fn validateTilePartPacketFrames(
    payload: []const u8,
    tile_header_start: usize,
    sod_offset: usize,
    payload_start: usize,
    payload_end: usize,
    cod: CodSegmentInfo,
    packet_sequence: *u16,
) !void {
    var packet_cursor = payload_start;
    var cursor = tile_header_start;
    var expected_plt_index: u8 = 0;
    while (cursor < sod_offset) {
        const marker = try readU16Be(payload, cursor);
        const length_offset = std.math.add(usize, cursor, 2) catch return Jp2Error.InvalidCodestream;
        const marker_length = try readU16Be(payload, length_offset);
        const next = std.math.add(usize, length_offset, marker_length) catch return Jp2Error.InvalidCodestream;
        if (next > sod_offset) return Jp2Error.InvalidCodestream;
        if (marker == marker_plt) {
            try validatePltPacketFrameSegment(payload, length_offset, marker_length, &expected_plt_index, &packet_cursor, payload_end, cod, packet_sequence);
        }
        cursor = next;
    }
    if (packet_cursor != payload_end) return Jp2Error.InvalidCodestream;
}

fn validatePltPacketFrameSegment(
    payload: []const u8,
    length_offset: usize,
    marker_length: u16,
    expected_plt_index: *u8,
    packet_cursor: *usize,
    payload_end: usize,
    cod: CodSegmentInfo,
    packet_sequence: *u16,
) !void {
    if (payload[length_offset + 2] != expected_plt_index.*) return Jp2Error.InvalidCodestream;
    expected_plt_index.* = std.math.add(u8, expected_plt_index.*, 1) catch return Jp2Error.InvalidCodestream;
    var cursor = length_offset + 3;
    const end = length_offset + @as(usize, marker_length);
    var packet_length: usize = 0;
    var pending_length = false;
    while (cursor < end) : (cursor += 1) {
        packet_length = std.math.mul(usize, packet_length, 128) catch return Jp2Error.InvalidCodestream;
        packet_length = std.math.add(usize, packet_length, @as(usize, payload[cursor] & 0x7f)) catch return Jp2Error.InvalidCodestream;
        pending_length = true;
        if ((payload[cursor] & 0x80) == 0) {
            try validatePacketFrame(payload, packet_cursor, payload_end, packet_length, cod, packet_sequence);
            packet_length = 0;
            pending_length = false;
        }
    }
    if (pending_length) return Jp2Error.InvalidCodestream;
}

fn validatePacketFrame(
    payload: []const u8,
    packet_cursor: *usize,
    payload_end: usize,
    packet_length: usize,
    cod: CodSegmentInfo,
    packet_sequence: *u16,
) !void {
    const packet_start = packet_cursor.*;
    const packet_end = std.math.add(usize, packet_start, packet_length) catch return Jp2Error.InvalidCodestream;
    if (packet_end > payload_end) return Jp2Error.InvalidCodestream;
    var packet_payload_start = packet_start;
    if (cod.sop) {
        if (packet_end - packet_start < 6) return Jp2Error.InvalidCodestream;
        if (try readU16Be(payload, packet_start) != marker_sop) return Jp2Error.InvalidCodestream;
        if (try readU16Be(payload, packet_start + 2) != 4) return Jp2Error.InvalidCodestream;
        if (try readU16Be(payload, packet_start + 4) != packet_sequence.*) return Jp2Error.InvalidCodestream;
        packet_sequence.* +%= 1;
        packet_payload_start += 6;
    } else if (packet_end - packet_start >= 2 and try readU16Be(payload, packet_start) == marker_sop) {
        return Jp2Error.InvalidCodestream;
    }

    const eph_offset = try packetEphOffsetRejectingSop(payload, packet_payload_start, packet_end);
    if (cod.eph != (eph_offset != null)) return Jp2Error.InvalidCodestream;
    packet_cursor.* = packet_end;
}

fn packetEphOffsetRejectingSop(payload: []const u8, start: usize, end: usize) !?usize {
    var eph_offset: ?usize = null;
    var cursor = start;
    while (cursor + 1 < end) {
        const searchable = payload[cursor .. end - 1];
        const relative = std.mem.indexOfScalar(u8, searchable, 0xff) orelse break;
        const offset = cursor + relative;
        const marker = try readU16Be(payload, offset);
        if (marker == marker_sop) return Jp2Error.InvalidCodestream;
        if (marker == marker_eph) {
            if (eph_offset != null) return Jp2Error.InvalidCodestream;
            eph_offset = offset;
        }
        cursor = offset + 1;
    }
    return eph_offset;
}

fn nextBox(bytes: []const u8, cursor: *usize, allow_length_to_eof: bool) !Box {
    if (cursor.* > bytes.len or bytes.len - cursor.* < 8) return Jp2Error.InvalidBox;
    const start = cursor.*;
    const length = try readU32Be(bytes, start);
    const kind = try readU32Be(bytes, start + 4);
    var payload_start = try std.math.add(usize, start, 8);
    const end = switch (length) {
        0 => if (allow_length_to_eof) bytes.len else return Jp2Error.InvalidBox,
        1 => blk: {
            if (bytes.len - start < 16) return Jp2Error.InvalidBox;
            const xl_box = try readU64Be(bytes, start + 8);
            if (xl_box < 16 or xl_box > std.math.maxInt(usize)) return Jp2Error.InvalidBox;
            payload_start = std.math.add(usize, start, 16) catch return Jp2Error.InvalidBox;
            break :blk std.math.add(usize, start, @as(usize, @intCast(xl_box))) catch return Jp2Error.InvalidBox;
        },
        2...7 => return Jp2Error.InvalidBox,
        else => std.math.add(usize, start, length) catch return Jp2Error.InvalidBox,
    };
    if (end > bytes.len) return Jp2Error.InvalidBox;
    cursor.* = end;
    return .{
        .kind = kind,
        .payload = bytes[payload_start..end],
    };
}

fn appendBox(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    box_type: BoxType,
    payload: []const u8,
) !void {
    const length = try std.math.add(u32, 8, @as(u32, @intCast(payload.len)));
    try appendU32Be(allocator, out, length);
    try appendU32Be(allocator, out, @intFromEnum(box_type));
    try out.appendSlice(allocator, payload);
}

fn appendFourcc(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: *const [4]u8) !void {
    try out.appendSlice(allocator, value);
}

fn appendU16Be(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u16) !void {
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value)));
}

fn appendU32Be(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: u32) !void {
    try out.append(allocator, @as(u8, @truncate(value >> 24)));
    try out.append(allocator, @as(u8, @truncate(value >> 16)));
    try out.append(allocator, @as(u8, @truncate(value >> 8)));
    try out.append(allocator, @as(u8, @truncate(value)));
}

fn readU16Be(bytes: []const u8, offset: usize) !u16 {
    const end = std.math.add(usize, offset, 2) catch return Jp2Error.InvalidBox;
    if (end > bytes.len) return Jp2Error.InvalidBox;
    return (@as(u16, bytes[offset]) << 8) | @as(u16, bytes[offset + 1]);
}

fn readU32Be(bytes: []const u8, offset: usize) !u32 {
    const end = std.math.add(usize, offset, 4) catch return Jp2Error.InvalidBox;
    if (end > bytes.len) return Jp2Error.InvalidBox;
    return (@as(u32, bytes[offset]) << 24) |
        (@as(u32, bytes[offset + 1]) << 16) |
        (@as(u32, bytes[offset + 2]) << 8) |
        @as(u32, bytes[offset + 3]);
}

fn readU64Be(bytes: []const u8, offset: usize) !u64 {
    const end = std.math.add(usize, offset, 8) catch return Jp2Error.InvalidBox;
    if (end > bytes.len) return Jp2Error.InvalidBox;
    return (@as(u64, bytes[offset]) << 56) |
        (@as(u64, bytes[offset + 1]) << 48) |
        (@as(u64, bytes[offset + 2]) << 40) |
        (@as(u64, bytes[offset + 3]) << 32) |
        (@as(u64, bytes[offset + 4]) << 24) |
        (@as(u64, bytes[offset + 5]) << 16) |
        (@as(u64, bytes[offset + 6]) << 8) |
        @as(u64, bytes[offset + 7]);
}

fn fourcc(comptime value: *const [4]u8) u32 {
    return (@as(u32, value[0]) << 24) |
        (@as(u32, value[1]) << 16) |
        (@as(u32, value[2]) << 8) |
        @as(u32, value[3]);
}
