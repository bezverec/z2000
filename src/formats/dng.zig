const std = @import("std");
const tiff_ifd = @import("tiff_ifd.zig");

const max_ifds = 32;

pub const DngError = error{
    TooManyIfds,
};

pub const Version = struct { bytes: [4]u8 };

pub const IfdSummary = struct {
    offset: usize,
    is_subifd: bool = false,
    width: ?u32 = null,
    height: ?u32 = null,
    bits_per_sample: ?u16 = null,
    bits_per_sample_count: usize = 0,
    samples_per_pixel: ?u16 = null,
    compression: ?u16 = null,
    photometric: ?u16 = null,
    sample_format: ?u16 = null,
    subfile_type: ?u32 = null,
    subifd_count: usize = 0,
};

pub const Info = struct {
    endian: tiff_ifd.Endian,
    ifd_count: usize,
    ifds: [max_ifds]IfdSummary,
    dng_version: ?Version = null,
    dng_backward_version: ?Version = null,
    make: ?[]const u8 = null,
    model: ?[]const u8 = null,
    unique_camera_model: ?[]const u8 = null,
    cfa_repeat: ?[2]u16 = null,
    cfa_pattern: ?[4]u8 = null,
    cfa_pattern_count: usize = 0,

    pub fn primary(self: Info) ?IfdSummary {
        if (self.ifd_count == 0) return null;
        return self.ifds[0];
    }
};

pub fn parseInfo(bytes: []const u8) !Info {
    const document = try tiff_ifd.Document.parse(bytes);
    var info = Info{
        .endian = document.endian,
        .ifd_count = 0,
        .ifds = [_]IfdSummary{.{ .offset = 0 }} ** max_ifds,
    };

    var ifd_offset = document.first_ifd_offset;
    var chain_count: usize = 0;
    while (ifd_offset != 0) {
        if (chain_count == max_ifds) return DngError.TooManyIfds;
        const ifd = try document.readIfd(ifd_offset);
        try appendSummary(document, ifd, false, &info);
        if (chain_count == 0) try readPrimaryDngTags(document, ifd, &info);
        chain_count += 1;
        ifd_offset = ifd.next_ifd_offset;
    }

    var index: usize = 0;
    while (index < info.ifd_count) : (index += 1) {
        const ifd = try document.readIfd(info.ifds[index].offset);
        const subifds_entry = try document.findEntry(ifd, 330) orelse continue;
        const subifds_ref = try subifds_entry.ref(document);
        info.ifds[index].subifd_count = subifds_ref.count;
        var sub_index: usize = 0;
        while (sub_index < subifds_ref.count) : (sub_index += 1) {
            if (info.ifd_count == max_ifds) return DngError.TooManyIfds;
            const subifd_offset = @as(usize, try subifds_ref.u32At(document, sub_index));
            const subifd = try document.readIfd(subifd_offset);
            try appendSummary(document, subifd, true, &info);
        }
    }

    return info;
}

fn appendSummary(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, is_subifd: bool, info: *Info) !void {
    if (info.ifd_count == max_ifds) return DngError.TooManyIfds;
    info.ifds[info.ifd_count] = try summarizeIfd(document, ifd, is_subifd);
    info.ifd_count += 1;
}

fn summarizeIfd(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, is_subifd: bool) !IfdSummary {
    var summary = IfdSummary{ .offset = ifd.offset, .is_subifd = is_subifd };
    if (try document.findEntry(ifd, 254)) |entry| summary.subfile_type = try entry.singleU32(document);
    if (try document.findEntry(ifd, 256)) |entry| summary.width = try entry.singleU32(document);
    if (try document.findEntry(ifd, 257)) |entry| summary.height = try entry.singleU32(document);
    if (try document.findEntry(ifd, 258)) |entry| {
        const value_ref = try entry.ref(document);
        if (value_ref.count > 0) summary.bits_per_sample = try value_ref.u16At(document, 0);
        summary.bits_per_sample_count = value_ref.count;
    }
    if (try document.findEntry(ifd, 259)) |entry| summary.compression = try entry.singleU16(document);
    if (try document.findEntry(ifd, 262)) |entry| summary.photometric = try entry.singleU16(document);
    if (try document.findEntry(ifd, 277)) |entry| summary.samples_per_pixel = try entry.singleU16(document);
    if (try document.findEntry(ifd, 339)) |entry| summary.sample_format = try entry.singleU16(document);
    return summary;
}

fn readPrimaryDngTags(document: tiff_ifd.Document, ifd: tiff_ifd.Ifd, info: *Info) !void {
    if (try document.findEntry(ifd, 271)) |entry| info.make = try (try entry.ref(document)).ascii(document);
    if (try document.findEntry(ifd, 272)) |entry| info.model = try (try entry.ref(document)).ascii(document);
    if (try document.findEntry(ifd, 50706)) |entry| info.dng_version = try readVersion(document, entry);
    if (try document.findEntry(ifd, 50707)) |entry| info.dng_backward_version = try readVersion(document, entry);
    if (try document.findEntry(ifd, 50708)) |entry| info.unique_camera_model = try (try entry.ref(document)).ascii(document);
    if (try document.findEntry(ifd, 33421)) |entry| {
        const value_ref = try entry.ref(document);
        if (value_ref.count == 2) {
            info.cfa_repeat = .{
                try value_ref.u16At(document, 0),
                try value_ref.u16At(document, 1),
            };
        }
    }
    if (try document.findEntry(ifd, 33422)) |entry| {
        const value_ref = try entry.ref(document);
        const count = @min(value_ref.count, 4);
        if (count > 0) {
            var pattern = [_]u8{0} ** 4;
            var index: usize = 0;
            while (index < count) : (index += 1) {
                pattern[index] = try value_ref.byteAt(document, index);
            }
            info.cfa_pattern = pattern;
            info.cfa_pattern_count = count;
        }
    }
}

fn readVersion(document: tiff_ifd.Document, entry: tiff_ifd.Entry) !Version {
    const value_ref = try entry.ref(document);
    if (value_ref.count != 4) return tiff_ifd.Error.InvalidTagValue;
    return .{ .bytes = .{
        try value_ref.byteAt(document, 0),
        try value_ref.byteAt(document, 1),
        try value_ref.byteAt(document, 2),
        try value_ref.byteAt(document, 3),
    } };
}
