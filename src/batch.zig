const std = @import("std");

pub const BatchError = error{
    InvalidPattern,
    InvalidTargetExtension,
    NoMatchingFiles,
    OutputCollision,
};

pub const Item = struct {
    input_path: []u8,
    output_path: []u8,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    items: []Item,

    pub fn deinit(self: *Plan) void {
        for (self.items) |item| {
            self.allocator.free(item.input_path);
            self.allocator.free(item.output_path);
        }
        self.allocator.free(self.items);
        self.* = undefined;
    }
};

/// Builds a deterministic, non-recursive conversion plan for a filename glob.
/// Only the basename may contain `*` and `?`; the directory itself must be a
/// concrete path. Matching is ASCII case-insensitive so `*.tif` also finds
/// `SCAN.TIF` consistently on every supported platform.
pub fn buildPlan(
    io: std.Io,
    allocator: std.mem.Allocator,
    pattern: []const u8,
    target_extension: []const u8,
) !Plan {
    if (!isTargetExtension(target_extension)) return BatchError.InvalidTargetExtension;
    const filename_pattern = std.fs.path.basename(pattern);
    if (filename_pattern.len == 0 or !hasWildcards(filename_pattern)) {
        return BatchError.InvalidPattern;
    }
    const explicit_directory = std.fs.path.dirname(pattern);
    const directory_path = explicit_directory orelse ".";
    if (hasWildcards(directory_path)) return BatchError.InvalidPattern;

    var directory = try std.Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterateAssumeFirstIteration();

    var items: std.ArrayList(Item) = .empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(item.input_path);
            allocator.free(item.output_path);
        }
        items.deinit(allocator);
    }
    var outputs: std.StringHashMap(void) = .init(allocator);
    defer outputs.deinit();

    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !matches(filename_pattern, entry.name)) continue;
        const input_path = if (explicit_directory) |path|
            try std.fs.path.join(allocator, &.{ path, entry.name })
        else
            try allocator.dupe(u8, entry.name);
        errdefer allocator.free(input_path);
        const output_path = try replaceExtension(allocator, input_path, target_extension);
        errdefer allocator.free(output_path);
        const output = try outputs.getOrPut(output_path);
        if (output.found_existing) return BatchError.OutputCollision;
        try items.append(allocator, .{
            .input_path = input_path,
            .output_path = output_path,
        });
    }
    if (items.items.len == 0) return BatchError.NoMatchingFiles;
    std.mem.sort(Item, items.items, {}, itemLessThan);
    return .{
        .allocator = allocator,
        .items = try items.toOwnedSlice(allocator),
    };
}

pub fn hasWildcards(text: []const u8) bool {
    return std.mem.findScalar(u8, text, '*') != null or
        std.mem.findScalar(u8, text, '?') != null;
}

/// Matches the simple filename-glob vocabulary used by batch conversion.
/// Character classes and recursive `**` semantics are intentionally absent.
pub fn matches(pattern: []const u8, name: []const u8) bool {
    if (containsPathSeparator(pattern) or containsPathSeparator(name)) return false;
    var pattern_index: usize = 0;
    var name_index: usize = 0;
    var star_index: ?usize = null;
    var star_name_index: usize = 0;

    while (name_index < name.len) {
        if (pattern_index < pattern.len and
            (pattern[pattern_index] == '?' or charsEqual(pattern[pattern_index], name[name_index])))
        {
            pattern_index += 1;
            name_index += 1;
        } else if (pattern_index < pattern.len and pattern[pattern_index] == '*') {
            star_index = pattern_index;
            pattern_index += 1;
            star_name_index = name_index;
        } else if (star_index) |star| {
            star_name_index += 1;
            name_index = star_name_index;
            pattern_index = star + 1;
        } else {
            return false;
        }
    }
    while (pattern_index < pattern.len and pattern[pattern_index] == '*') {
        pattern_index += 1;
    }
    return pattern_index == pattern.len;
}

pub fn replaceExtension(
    allocator: std.mem.Allocator,
    path: []const u8,
    target_extension: []const u8,
) ![]u8 {
    if (!isTargetExtension(target_extension)) return BatchError.InvalidTargetExtension;
    const source_extension = std.fs.path.extension(path);
    if (source_extension.len == 0) return BatchError.InvalidPattern;
    return std.mem.concat(allocator, u8, &.{
        path[0 .. path.len - source_extension.len],
        target_extension,
    });
}

pub fn isTargetExtension(extension: []const u8) bool {
    if (extension.len < 2 or extension[0] != '.' or
        hasWildcards(extension) or
        !std.mem.eql(u8, std.fs.path.basename(extension), extension))
    {
        return false;
    }
    for (extension[1..]) |character| {
        if (!std.ascii.isAlphanumeric(character)) return false;
    }
    return true;
}

fn charsEqual(a: u8, b: u8) bool {
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn containsPathSeparator(text: []const u8) bool {
    return std.mem.findScalar(u8, text, '/') != null or
        std.mem.findScalar(u8, text, '\\') != null;
}

fn itemLessThan(_: void, a: Item, b: Item) bool {
    return std.mem.order(u8, a.input_path, b.input_path) == .lt;
}
