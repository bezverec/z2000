const std = @import("std");
const codestream = @import("codestream.zig");
const color = @import("color.zig");
const image = @import("image.zig");
const jp2 = @import("jp2.zig");

const max_file_size = 1024 * 1024 * 1024;
const default_manifest_path = "src/testdata/part1-corpus.json";

const CoverageStatus = enum {
    complete,
    bounded,
    fail_closed,
    not_implemented,
    not_applicable,
};

const Capability = struct {
    id: []const u8,
    title: []const u8,
    parser: CoverageStatus,
    strict_decode: CoverageStatus,
    encode: CoverageStatus,
    malformed: CoverageStatus,
    interop: CoverageStatus,
    evidence: []const []const u8,
    note: []const u8,
};

const Availability = enum { committed, optional };
const InputFormat = enum { jp2, j2k };
const Decoder = enum { planar, native, interleaved_rgb };
const Expectation = enum { decode_pass, fail_closed };
const ReferenceSpace = enum { output_components, codestream_components };
const Marker = enum { siz, cod, coc, qcd, qcc, tlm, poc, sot };

const Reference = struct {
    path: []const u8,
    sha256: []const u8,
    format: enum { pgx },
    component: u16 = 0,
    resolution_reduction: u8 = 0,
    space: ReferenceSpace = .output_components,
    max_peak_error: u32 = 0,
    max_mse: f64 = 0,
};

const ReferenceAsset = struct {
    metadata: Reference,
    bytes: []u8,
};

const Patch = struct {
    marker: Marker,
    marker_occurrence: u32 = 0,
    marker_offset: u32,
    value: u8,
};

const Source = struct {
    producer: []const u8,
    version: []const u8,
    origin: []const u8,
    license: []const u8,
    redistribution: []const u8,
    command: ?[]const u8 = null,
};

const Entry = struct {
    id: []const u8,
    path: []const u8,
    availability: Availability,
    root_env: ?[]const u8 = null,
    format: InputFormat,
    decoder: Decoder = .planar,
    sha256: []const u8,
    source: Source,
    oracle: []const u8,
    features: []const []const u8,
    expectation: Expectation,
    expected_error: ?[]const u8 = null,
    expected_native_sha256: ?[]const u8 = null,
    references: []const Reference = &.{},
    patches: []const Patch = &.{},
};

const Manifest = struct {
    schema_version: u32,
    capabilities: []const Capability,
    entries: []const Entry,
};

const Options = struct {
    manifest_path: []const u8 = default_manifest_path,
    bless: bool = false,
    require_optional: bool = false,
};

const Counters = struct {
    decode_pass: usize = 0,
    expected_fail_closed: usize = 0,
    unexpected_acceptance: usize = 0,
    mismatch: usize = 0,
    skipped: usize = 0,
};

const EntryResult = enum {
    decode_pass,
    expected_fail_closed,
    unexpected_acceptance,
    mismatch,
    skipped,
};

const CorpusError = error{
    InvalidArguments,
    InvalidManifest,
    CorpusMismatch,
    MissingMarker,
    ImageTooLarge,
    InvalidReference,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const options = try parseOptions(init, allocator);

    const manifest_bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        options.manifest_path,
        allocator,
        .limited(max_file_size),
    );
    defer allocator.free(manifest_bytes);

    const parsed = try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{});
    defer parsed.deinit();
    try validateManifest(parsed.value, options.bless);

    std.debug.print(
        "Part 1 matrix: {} capabilities, {} corpus entries\n",
        .{ parsed.value.capabilities.len, parsed.value.entries.len },
    );

    var counters = Counters{};
    for (parsed.value.entries) |entry| {
        const result = try runEntry(init, allocator, entry, options);
        switch (result) {
            .decode_pass => counters.decode_pass += 1,
            .expected_fail_closed => counters.expected_fail_closed += 1,
            .unexpected_acceptance => counters.unexpected_acceptance += 1,
            .mismatch => counters.mismatch += 1,
            .skipped => counters.skipped += 1,
        }
    }

    std.debug.print(
        "SUMMARY decode-pass={} expected-fail-closed={} unexpected-acceptance={} mismatch={} skipped={}\n",
        .{
            counters.decode_pass,
            counters.expected_fail_closed,
            counters.unexpected_acceptance,
            counters.mismatch,
            counters.skipped,
        },
    );
    if (counters.unexpected_acceptance != 0 or counters.mismatch != 0 or
        (options.require_optional and counters.skipped != 0))
    {
        return CorpusError.CorpusMismatch;
    }
}

fn parseOptions(init: std.process.Init, allocator: std.mem.Allocator) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = Options{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--manifest")) {
            options.manifest_path = args.next() orelse return CorpusError.InvalidArguments;
        } else if (std.mem.eql(u8, arg, "--bless")) {
            options.bless = true;
        } else if (std.mem.eql(u8, arg, "--require-optional")) {
            options.require_optional = true;
        } else {
            std.debug.print(
                "usage: zig build part1-corpus -- [--manifest PATH] [--bless] [--require-optional]\n",
                .{},
            );
            return CorpusError.InvalidArguments;
        }
    }
    return options;
}

fn validateManifest(manifest: Manifest, bless: bool) !void {
    if (manifest.schema_version != 1 or manifest.capabilities.len == 0 or manifest.entries.len == 0) {
        return CorpusError.InvalidManifest;
    }
    for (manifest.capabilities, 0..) |capability, index| {
        if (capability.id.len == 0 or capability.title.len == 0 or capability.note.len == 0 or
            capability.evidence.len == 0)
        {
            return CorpusError.InvalidManifest;
        }
        for (manifest.capabilities[0..index]) |previous| {
            if (std.mem.eql(u8, capability.id, previous.id)) return CorpusError.InvalidManifest;
        }
    }
    for (manifest.entries, 0..) |entry, index| {
        if (entry.id.len == 0 or entry.path.len == 0 or entry.features.len == 0 or
            std.fs.path.isAbsolute(entry.path) or hasParentTraversal(entry.path) or
            !isLowerHexSha256(entry.sha256) or entry.source.producer.len == 0 or
            entry.source.version.len == 0 or entry.source.origin.len == 0 or
            entry.source.license.len == 0 or entry.source.redistribution.len == 0)
        {
            return CorpusError.InvalidManifest;
        }
        if (entry.oracle.len == 0 or
            (entry.source.command != null and entry.source.command.?.len == 0))
        {
            return CorpusError.InvalidManifest;
        }
        if ((entry.availability == .committed) != (entry.root_env == null)) {
            return CorpusError.InvalidManifest;
        }
        if (entry.expectation == .decode_pass) {
            if (entry.expected_error != null or entry.patches.len != 0) return CorpusError.InvalidManifest;
            if (entry.expected_native_sha256 != null and entry.references.len != 0) {
                return CorpusError.InvalidManifest;
            }
            if (entry.expected_native_sha256) |expected_hash| {
                if (!isLowerHexSha256(expected_hash)) return CorpusError.InvalidManifest;
            } else if (entry.references.len == 0 and !bless) return CorpusError.InvalidManifest;
        } else {
            if (entry.expected_error == null or entry.expected_error.?.len == 0 or
                entry.expected_native_sha256 != null)
            {
                return CorpusError.InvalidManifest;
            }
        }
        for (entry.references, 0..) |reference, reference_index| {
            if (reference.path.len == 0 or
                std.fs.path.isAbsolute(reference.path) or hasParentTraversal(reference.path) or
                !isLowerHexSha256(reference.sha256) or !std.math.isFinite(reference.max_mse) or
                reference.max_mse < 0)
            {
                return CorpusError.InvalidManifest;
            }
            for (entry.references[0..reference_index]) |previous| {
                if (previous.component == reference.component and
                    previous.resolution_reduction == reference.resolution_reduction)
                {
                    return CorpusError.InvalidManifest;
                }
            }
        }
        for (manifest.entries[0..index]) |previous| {
            if (std.mem.eql(u8, entry.id, previous.id)) return CorpusError.InvalidManifest;
        }
        for (entry.features) |feature| {
            if (!hasCapability(manifest.capabilities, feature)) return CorpusError.InvalidManifest;
        }
    }
}

fn hasParentTraversal(path: []const u8) bool {
    var components = std.mem.splitAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return true;
    }
    return false;
}

fn hasCapability(capabilities: []const Capability, id: []const u8) bool {
    for (capabilities) |capability| {
        if (std.mem.eql(u8, capability.id, id)) return true;
    }
    return false;
}

fn isLowerHexSha256(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |character| {
        if (!std.ascii.isDigit(character) and !(character >= 'a' and character <= 'f')) return false;
    }
    return true;
}

fn runEntry(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    entry: Entry,
    options: Options,
) !EntryResult {
    const resolved_path = try resolvePath(init, allocator, entry) orelse {
        std.debug.print("SKIP {s}: environment {s} is not set\n", .{ entry.id, entry.root_env.? });
        return .skipped;
    };
    defer if (entry.availability == .optional) allocator.free(resolved_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(
        init.io,
        resolved_path,
        allocator,
        .limited(max_file_size),
    ) catch |err| {
        std.debug.print("MISMATCH {s}: cannot read {s}: {s}\n", .{ entry.id, resolved_path, @errorName(err) });
        return .mismatch;
    };
    defer allocator.free(bytes);

    const input_hash = sha256Hex(bytes);
    if (!std.mem.eql(u8, &input_hash, entry.sha256)) {
        std.debug.print(
            "MISMATCH {s}: input sha256 expected={s} actual={s}\n",
            .{ entry.id, entry.sha256, input_hash },
        );
        return .mismatch;
    }

    var reference_assets: std.ArrayList(ReferenceAsset) = .empty;
    defer {
        for (reference_assets.items) |asset| allocator.free(asset.bytes);
        reference_assets.deinit(allocator);
    }
    for (entry.references) |reference| {
        const reference_path = try resolveAssetPath(
            init,
            allocator,
            entry.availability,
            entry.root_env,
            reference.path,
        ) orelse return .skipped;
        defer if (entry.availability == .optional) allocator.free(reference_path);
        const reference_bytes = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            reference_path,
            allocator,
            .limited(max_file_size),
        ) catch |err| {
            std.debug.print("MISMATCH {s}: cannot read reference {s}: {s}\n", .{
                entry.id,
                reference_path,
                @errorName(err),
            });
            return .mismatch;
        };
        const reference_hash = sha256Hex(reference_bytes);
        if (!std.mem.eql(u8, &reference_hash, reference.sha256)) {
            std.debug.print(
                "MISMATCH {s}: reference sha256 expected={s} actual={s}\n",
                .{ entry.id, reference.sha256, reference_hash },
            );
            allocator.free(reference_bytes);
            return .mismatch;
        }
        reference_assets.append(allocator, .{
            .metadata = reference,
            .bytes = reference_bytes,
        }) catch |err| {
            allocator.free(reference_bytes);
            return err;
        };
    }

    const extracted = switch (entry.format) {
        .jp2 => blk: {
            _ = jp2.parseInfo(bytes) catch |err| return reportEarlyError(entry, err);
            break :blk jp2.extractCodestream(bytes) catch |err| {
                return reportEarlyError(entry, err);
            };
        },
        .j2k => bytes,
    };
    var patched: ?[]u8 = null;
    defer if (patched) |owned| allocator.free(owned);
    if (entry.patches.len != 0) {
        patched = try allocator.dupe(u8, extracted);
        applyPatches(patched.?, entry.patches) catch |err| {
            std.debug.print("MISMATCH {s}: patch error={s}\n", .{ entry.id, @errorName(err) });
            return .mismatch;
        };
    }
    const stream = patched orelse extracted;

    return switch (entry.expectation) {
        .decode_pass => runDecodePass(allocator, entry, stream, reference_assets.items, options.bless),
        .fail_closed => runFailClosed(allocator, entry, stream),
    };
}

fn resolvePath(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    entry: Entry,
) !?[]const u8 {
    return resolveAssetPath(init, allocator, entry.availability, entry.root_env, entry.path);
}

fn resolveAssetPath(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    availability: Availability,
    root_env: ?[]const u8,
    path: []const u8,
) !?[]const u8 {
    if (availability == .committed) return path;
    const root = init.environ_map.get(root_env.?) orelse return null;
    return try std.fs.path.join(allocator, &.{ root, path });
}

fn reportEarlyError(entry: Entry, err: anyerror) EntryResult {
    if (entry.expectation == .fail_closed and
        std.mem.eql(u8, @errorName(err), entry.expected_error.?))
    {
        std.debug.print("PASS {s}: expected-fail-closed error={s}\n", .{ entry.id, @errorName(err) });
        return .expected_fail_closed;
    }
    std.debug.print("MISMATCH {s}: pre-decode error={s}\n", .{ entry.id, @errorName(err) });
    return .mismatch;
}

fn runDecodePass(
    allocator: std.mem.Allocator,
    entry: Entry,
    stream: []const u8,
    reference_assets: []const ReferenceAsset,
    bless: bool,
) EntryResult {
    if (reference_assets.len != 0 and !bless) {
        for (reference_assets) |reference| {
            const options = codestream.DecodeOptions{
                .resolution_reduction = reference.metadata.resolution_reduction,
            };
            const metrics = switch (entry.decoder) {
                .planar => blk: {
                    var decoded = decodePlanarReference(allocator, stream, options, reference.metadata) catch |err| {
                        std.debug.print("MISMATCH {s}: reference {s} decode error={s}\n", .{
                            entry.id,
                            reference.metadata.path,
                            @errorName(err),
                        });
                        return .mismatch;
                    };
                    defer decoded.deinit();
                    break :blk comparePlanarPgx(decoded, reference) catch |err| {
                        reportPlanarPgxMismatch(decoded, reference);
                        std.debug.print("MISMATCH {s}: reference {s} error={s}\n", .{
                            entry.id,
                            reference.metadata.path,
                            @errorName(err),
                        });
                        return .mismatch;
                    };
                },
                .native => blk: {
                    var decoded = codestream.decodeLosslessNativeWithOptions(
                        allocator,
                        stream,
                        options,
                        .{},
                    ) catch |err| {
                        std.debug.print("MISMATCH {s}: reference {s} decode error={s}\n", .{
                            entry.id,
                            reference.metadata.path,
                            @errorName(err),
                        });
                        return .mismatch;
                    };
                    defer decoded.deinit();
                    break :blk compareNativePgx(decoded, reference) catch |err| {
                        reportNativePgxMismatch(decoded, reference);
                        std.debug.print("MISMATCH {s}: reference {s} error={s}\n", .{
                            entry.id,
                            reference.metadata.path,
                            @errorName(err),
                        });
                        return .mismatch;
                    };
                },
                .interleaved_rgb => blk: {
                    var decoded = codestream.decodeLosslessTemporaryWithOptions(allocator, stream, options) catch |err| {
                        std.debug.print("MISMATCH {s}: reference {s} decode error={s}\n", .{
                            entry.id,
                            reference.metadata.path,
                            @errorName(err),
                        });
                        return .mismatch;
                    };
                    defer decoded.deinit();
                    break :blk compareInterleavedPgx(decoded, reference) catch |err| {
                        reportInterleavedPgxMismatch(decoded, reference);
                        std.debug.print("MISMATCH {s}: reference {s} error={s}\n", .{
                            entry.id,
                            reference.metadata.path,
                            @errorName(err),
                        });
                        return .mismatch;
                    };
                },
            };
            reportReferenceMetrics(entry, reference, metrics);
        }
        std.debug.print("PASS {s}: pgx-references={}\n", .{ entry.id, entry.references.len });
        return .decode_pass;
    }
    const native_hash = switch (entry.decoder) {
        .planar => blk: {
            var decoded = codestream.decodeLosslessPlanar(allocator, stream) catch |err| {
                std.debug.print("MISMATCH {s}: decode error={s}\n", .{ entry.id, @errorName(err) });
                return .mismatch;
            };
            defer decoded.deinit();
            for (reference_assets) |reference| {
                const metrics = comparePlanarPgx(decoded, reference) catch |err| {
                    reportPlanarPgxMismatch(decoded, reference);
                    std.debug.print("MISMATCH {s}: reference {s} error={s}\n", .{
                        entry.id,
                        reference.metadata.path,
                        @errorName(err),
                    });
                    return .mismatch;
                };
                reportReferenceMetrics(entry, reference, metrics);
            }
            break :blk nativeSampleSha256(decoded) catch |err| {
                std.debug.print("MISMATCH {s}: native hash error={s}\n", .{ entry.id, @errorName(err) });
                return .mismatch;
            };
        },
        .native => blk: {
            var decoded = codestream.decodeLosslessNative(allocator, stream, .{}) catch |err| {
                std.debug.print("MISMATCH {s}: decode error={s}\n", .{ entry.id, @errorName(err) });
                return .mismatch;
            };
            defer decoded.deinit();
            for (reference_assets) |reference| {
                const metrics = compareNativePgx(decoded, reference) catch |err| {
                    reportNativePgxMismatch(decoded, reference);
                    std.debug.print("MISMATCH {s}: reference {s} error={s}\n", .{
                        entry.id,
                        reference.metadata.path,
                        @errorName(err),
                    });
                    return .mismatch;
                };
                reportReferenceMetrics(entry, reference, metrics);
            }
            break :blk nativeWideSampleSha256(decoded) catch |err| {
                std.debug.print("MISMATCH {s}: native hash error={s}\n", .{ entry.id, @errorName(err) });
                return .mismatch;
            };
        },
        .interleaved_rgb => blk: {
            var decoded = codestream.decodeLosslessTemporary(allocator, stream) catch |err| {
                std.debug.print("MISMATCH {s}: decode error={s}\n", .{ entry.id, @errorName(err) });
                return .mismatch;
            };
            defer decoded.deinit();
            for (reference_assets) |reference| {
                const metrics = compareInterleavedPgx(decoded, reference) catch |err| {
                    reportInterleavedPgxMismatch(decoded, reference);
                    std.debug.print("MISMATCH {s}: reference {s} error={s}\n", .{
                        entry.id,
                        reference.metadata.path,
                        @errorName(err),
                    });
                    return .mismatch;
                };
                reportReferenceMetrics(entry, reference, metrics);
            }
            break :blk interleavedRgbSha256(decoded) catch |err| {
                std.debug.print("MISMATCH {s}: native hash error={s}\n", .{ entry.id, @errorName(err) });
                return .mismatch;
            };
        },
    };
    if (bless) {
        std.debug.print("OBSERVED {s}: native-sha256={s}\n", .{ entry.id, native_hash });
        return .decode_pass;
    }
    if (entry.references.len != 0) {
        std.debug.print("PASS {s}: pgx-references={} native-sha256={s}\n", .{
            entry.id,
            entry.references.len,
            native_hash,
        });
        return .decode_pass;
    }
    if (!std.mem.eql(u8, &native_hash, entry.expected_native_sha256.?)) {
        std.debug.print(
            "MISMATCH {s}: native sha256 expected={s} actual={s}\n",
            .{ entry.id, entry.expected_native_sha256.?, native_hash },
        );
        return .mismatch;
    }
    std.debug.print("PASS {s}: decode native-sha256={s}\n", .{ entry.id, native_hash });
    return .decode_pass;
}

fn decodePlanarReference(
    allocator: std.mem.Allocator,
    stream: []const u8,
    options: codestream.DecodeOptions,
    reference: Reference,
) !color.SamplePlanes {
    return switch (reference.space) {
        .output_components => codestream.decodeLosslessPlanarWithOptions(allocator, stream, options),
        .codestream_components => codestream.decodeLosslessCodestreamComponentsWithOptions(
            allocator,
            stream,
            options,
        ),
    };
}

fn reportReferenceMetrics(entry: Entry, asset: ReferenceAsset, metrics: ErrorMetrics) void {
    std.debug.print(
        "REFERENCE {s}: {s} component={} reduction={} peak={}/{} mse={d:.6}/{d:.6}\n",
        .{
            entry.id,
            asset.metadata.path,
            asset.metadata.component,
            asset.metadata.resolution_reduction,
            metrics.peak,
            asset.metadata.max_peak_error,
            metrics.mse,
            asset.metadata.max_mse,
        },
    );
}

fn runFailClosed(allocator: std.mem.Allocator, entry: Entry, stream: []const u8) EntryResult {
    return switch (entry.decoder) {
        .planar => if (codestream.decodeLosslessPlanar(allocator, stream)) |decoded_value| blk: {
            var decoded = decoded_value;
            defer decoded.deinit();
            break :blk reportUnexpectedAcceptance(entry);
        } else |err| reportExpectedDecodeError(entry, err),
        .native => if (codestream.decodeLosslessNative(allocator, stream, .{})) |decoded_value| blk: {
            var decoded = decoded_value;
            defer decoded.deinit();
            break :blk reportUnexpectedAcceptance(entry);
        } else |err| reportExpectedDecodeError(entry, err),
        .interleaved_rgb => if (codestream.decodeLosslessTemporary(allocator, stream)) |decoded_value| blk: {
            var decoded = decoded_value;
            defer decoded.deinit();
            break :blk reportUnexpectedAcceptance(entry);
        } else |err| reportExpectedDecodeError(entry, err),
    };
}

fn reportUnexpectedAcceptance(entry: Entry) EntryResult {
    std.debug.print("UNEXPECTED_ACCEPTANCE {s}: strict decode succeeded\n", .{entry.id});
    return .unexpected_acceptance;
}

fn reportExpectedDecodeError(entry: Entry, err: anyerror) EntryResult {
    if (!std.mem.eql(u8, @errorName(err), entry.expected_error.?)) {
        std.debug.print(
            "MISMATCH {s}: expected error={s} actual={s}\n",
            .{ entry.id, entry.expected_error.?, @errorName(err) },
        );
        return .mismatch;
    }
    std.debug.print("PASS {s}: expected-fail-closed error={s}\n", .{ entry.id, @errorName(err) });
    return .expected_fail_closed;
}

fn applyPatches(stream: []u8, patches: []const Patch) !void {
    for (patches) |patch| {
        const marker_value = switch (patch.marker) {
            .siz => codestream.markerValue("siz"),
            .cod => codestream.markerValue("cod"),
            .coc => codestream.markerValue("coc"),
            .qcd => codestream.markerValue("qcd"),
            .qcc => codestream.markerValue("qcc"),
            .tlm => codestream.markerValue("tlm"),
            .poc => codestream.markerValue("poc"),
            .sot => codestream.markerValue("sot"),
        };
        const marker_bytes = [2]u8{ @intCast(marker_value >> 8), @intCast(marker_value & 0xff) };
        var marker_index: usize = 0;
        var search_start: usize = 0;
        for (0..@as(usize, patch.marker_occurrence) + 1) |_| {
            marker_index = std.mem.indexOfPos(u8, stream, search_start, &marker_bytes) orelse
                return CorpusError.MissingMarker;
            search_start = std.math.add(usize, marker_index, marker_bytes.len) catch
                return CorpusError.InvalidManifest;
        }
        const target = std.math.add(usize, marker_index, patch.marker_offset) catch return CorpusError.InvalidManifest;
        if (target >= stream.len) return CorpusError.InvalidManifest;
        stream[target] = patch.value;
    }
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn nativeSampleSha256(planes: color.SamplePlanes) ![64]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hasher = Sha256.init(.{});
    hasher.update("z2000-part1-native-v1\x00");
    try hashU32(&hasher, planes.width);
    try hashU32(&hasher, planes.height);
    try hashU32(&hasher, planes.componentCount());
    for (0..planes.componentCount()) |component| {
        const dimensions = planes.componentDimensions(component) orelse return CorpusError.InvalidManifest;
        const bit_depth = planes.componentBitDepth(component) orelse return CorpusError.InvalidManifest;
        hasher.update(&.{bit_depth});
        try hashU32(&hasher, dimensions[0]);
        try hashU32(&hasher, dimensions[1]);
        try hashU32(&hasher, planes.planes[component].len);
        for (planes.planes[component]) |sample| {
            var encoded: [2]u8 = undefined;
            std.mem.writeInt(u16, &encoded, sample, .big);
            hasher.update(&encoded);
        }
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn nativeWideSampleSha256(planes: codestream.NativeSamplePlanes) ![64]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var hasher = Sha256.init(.{});
    hasher.update("z2000-part1-native-wide-v1\x00");
    try hashU32(&hasher, planes.reference_x1 - planes.reference_x0);
    try hashU32(&hasher, planes.reference_y1 - planes.reference_y0);
    try hashU32(&hasher, planes.componentCount());
    for (planes.planes) |plane| {
        hasher.update(&.{ plane.layout.precision, @intFromBool(plane.layout.signed) });
        try hashU32(&hasher, plane.layout.width);
        try hashU32(&hasher, plane.layout.height);
        try hashU32(&hasher, plane.samples.len);
        for (plane.samples) |sample| {
            var encoded: [8]u8 = undefined;
            std.mem.writeInt(i64, &encoded, sample, .big);
            hasher.update(&encoded);
        }
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn interleavedRgbSha256(decoded: image.RgbImage) ![64]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    const component_count = 3;
    const pixel_count = std.math.mul(usize, decoded.width, decoded.height) catch
        return CorpusError.ImageTooLarge;
    const sample_count = std.math.mul(usize, pixel_count, component_count) catch
        return CorpusError.ImageTooLarge;
    if (decoded.samples.len != sample_count) return CorpusError.InvalidManifest;

    var hasher = Sha256.init(.{});
    hasher.update("z2000-part1-native-v1\x00");
    try hashU32(&hasher, decoded.width);
    try hashU32(&hasher, decoded.height);
    try hashU32(&hasher, component_count);
    for (0..component_count) |component| {
        hasher.update(&.{decoded.bit_depth});
        try hashU32(&hasher, decoded.width);
        try hashU32(&hasher, decoded.height);
        try hashU32(&hasher, pixel_count);
        for (0..pixel_count) |pixel| {
            var encoded: [2]u8 = undefined;
            std.mem.writeInt(u16, &encoded, decoded.samples[pixel * component_count + component], .big);
            hasher.update(&encoded);
        }
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

const PgxImage = struct {
    big_endian: bool,
    signed: bool,
    bit_depth: u8,
    width: usize,
    height: usize,
    payload: []const u8,
};

const InterleavedSamples = struct {
    values: []const u16,
    stride: usize,
    component: usize,
};

const ComponentSamples = union(enum) {
    unsigned_contiguous: []const u16,
    unsigned_interleaved: InterleavedSamples,
    signed_contiguous: []const i32,
    native_contiguous: []const i64,
};

const ComponentView = struct {
    width: usize,
    height: usize,
    bit_depth: u8,
    signed: bool,
    samples: ComponentSamples,

    fn sample(self: ComponentView, index: usize) !i32 {
        return switch (self.samples) {
            .unsigned_contiguous => |values| if (index < values.len)
                values[index]
            else
                CorpusError.InvalidReference,
            .unsigned_interleaved => |values| blk: {
                const offset = std.math.mul(usize, index, values.stride) catch
                    return CorpusError.ImageTooLarge;
                const sample_index = std.math.add(usize, offset, values.component) catch
                    return CorpusError.ImageTooLarge;
                if (sample_index >= values.values.len) return CorpusError.InvalidReference;
                break :blk values.values[sample_index];
            },
            .signed_contiguous => |values| if (index < values.len)
                values[index]
            else
                CorpusError.InvalidReference,
            .native_contiguous => |values| if (index < values.len)
                std.math.cast(i32, values[index]) orelse CorpusError.InvalidReference
            else
                CorpusError.InvalidReference,
        };
    }
};

const ErrorMetrics = struct {
    peak: u32,
    mse: f64,
};

fn parsePgx(bytes: []const u8) !PgxImage {
    const newline = std.mem.indexOfScalar(u8, bytes, '\n') orelse return CorpusError.InvalidReference;
    var tokens = std.mem.tokenizeAny(u8, bytes[0..newline], " \t\r");
    if (!std.mem.eql(u8, tokens.next() orelse return CorpusError.InvalidReference, "PG")) {
        return CorpusError.InvalidReference;
    }
    const endian_token = tokens.next() orelse return CorpusError.InvalidReference;
    const big_endian = if (std.mem.eql(u8, endian_token, "ML"))
        true
    else if (std.mem.eql(u8, endian_token, "LM"))
        false
    else
        return CorpusError.InvalidReference;

    var depth_token = tokens.next() orelse return CorpusError.InvalidReference;
    var signed = false;
    if (std.mem.eql(u8, depth_token, "+") or std.mem.eql(u8, depth_token, "-")) {
        signed = depth_token[0] == '-';
        depth_token = tokens.next() orelse return CorpusError.InvalidReference;
    } else if (depth_token.len > 1 and (depth_token[0] == '+' or depth_token[0] == '-')) {
        signed = depth_token[0] == '-';
        depth_token = depth_token[1..];
    }
    const bit_depth = std.fmt.parseInt(u8, depth_token, 10) catch return CorpusError.InvalidReference;
    if (bit_depth == 0 or bit_depth > 31) return CorpusError.InvalidReference;
    const width = std.fmt.parseInt(usize, tokens.next() orelse return CorpusError.InvalidReference, 10) catch
        return CorpusError.InvalidReference;
    const height = std.fmt.parseInt(usize, tokens.next() orelse return CorpusError.InvalidReference, 10) catch
        return CorpusError.InvalidReference;
    if (tokens.next() != null) return CorpusError.InvalidReference;

    const sample_count = std.math.mul(usize, width, height) catch return CorpusError.ImageTooLarge;
    const bytes_per_sample: usize = if (bit_depth <= 8)
        1
    else if (bit_depth <= 16)
        2
    else
        4;
    const payload_size = std.math.mul(usize, sample_count, bytes_per_sample) catch
        return CorpusError.ImageTooLarge;
    const payload = bytes[newline + 1 ..];
    if (payload.len != payload_size) return CorpusError.InvalidReference;
    return .{
        .big_endian = big_endian,
        .signed = signed,
        .bit_depth = bit_depth,
        .width = width,
        .height = height,
        .payload = payload,
    };
}

fn pgxSample(reference: PgxImage, index: usize) !i32 {
    const bytes_per_sample: usize = if (reference.bit_depth <= 8)
        1
    else if (reference.bit_depth <= 16)
        2
    else
        4;
    const offset = std.math.mul(usize, index, bytes_per_sample) catch
        return CorpusError.ImageTooLarge;
    if (offset + bytes_per_sample > reference.payload.len) return CorpusError.InvalidReference;
    var raw: u32 = 0;
    if (reference.big_endian) {
        for (reference.payload[offset..][0..bytes_per_sample]) |byte| {
            raw = (raw << 8) | byte;
        }
    } else {
        var byte_index = bytes_per_sample;
        while (byte_index > 0) {
            byte_index -= 1;
            raw = (raw << 8) | reference.payload[offset + byte_index];
        }
    }
    const range: u32 = @as(u32, 1) << @as(u5, @intCast(reference.bit_depth));
    const masked: u32 = raw & (range - 1);
    if (!reference.signed) return @intCast(masked);
    const sign_bit = range >> 1;
    return if ((masked & sign_bit) == 0)
        @intCast(masked)
    else
        @intCast(@as(i64, masked) - @as(i64, range));
}

fn comparePgxView(view: ComponentView, bytes: []const u8, limits: Reference) !ErrorMetrics {
    const metrics = try measurePgxView(view, bytes);
    if (metrics.peak > limits.max_peak_error or metrics.mse > limits.max_mse) {
        return CorpusError.CorpusMismatch;
    }
    return metrics;
}

fn measurePgxView(view: ComponentView, bytes: []const u8) !ErrorMetrics {
    const reference = try parsePgx(bytes);
    if (view.width != reference.width or view.height != reference.height or
        view.bit_depth != reference.bit_depth or view.signed != reference.signed)
    {
        return CorpusError.InvalidReference;
    }
    const sample_count = std.math.mul(usize, view.width, view.height) catch
        return CorpusError.ImageTooLarge;
    var peak: u64 = 0;
    var squared_error_sum: u128 = 0;
    for (0..sample_count) |index| {
        const actual = try view.sample(index);
        const expected = try pgxSample(reference, index);
        const difference = @as(i64, actual) - @as(i64, expected);
        const magnitude: u64 = @intCast(if (difference < 0) -difference else difference);
        peak = @max(peak, magnitude);
        squared_error_sum += @as(u128, magnitude) * magnitude;
    }
    if (peak > std.math.maxInt(u32)) return CorpusError.ImageTooLarge;
    const mse = @as(f64, @floatFromInt(squared_error_sum)) /
        @as(f64, @floatFromInt(sample_count));
    return .{ .peak = @intCast(peak), .mse = mse };
}

fn reportPgxMismatch(view: ComponentView, asset: ReferenceAsset) void {
    const metrics = measurePgxView(view, asset.bytes) catch return;
    const reference = parsePgx(asset.bytes) catch return;
    const sample_count = std.math.mul(usize, view.width, view.height) catch return;
    var actual_min: i32 = std.math.maxInt(i32);
    var actual_max: i32 = std.math.minInt(i32);
    var expected_min: i32 = std.math.maxInt(i32);
    var expected_max: i32 = std.math.minInt(i32);
    var first_mismatch: ?struct { index: usize, actual: i32, expected: i32 } = null;
    for (0..sample_count) |index| {
        const actual = view.sample(index) catch return;
        const expected = pgxSample(reference, index) catch return;
        actual_min = @min(actual_min, actual);
        actual_max = @max(actual_max, actual);
        expected_min = @min(expected_min, expected);
        expected_max = @max(expected_max, expected);
        if (first_mismatch == null and actual != expected) {
            first_mismatch = .{ .index = index, .actual = actual, .expected = expected };
        }
    }
    std.debug.print(
        "OBSERVED_MISMATCH {s}: component={} reduction={} peak={}/{} mse={d:.6}/{d:.6} actual=[{},{}] expected=[{},{}]",
        .{
            asset.metadata.path,
            asset.metadata.component,
            asset.metadata.resolution_reduction,
            metrics.peak,
            asset.metadata.max_peak_error,
            metrics.mse,
            asset.metadata.max_mse,
            actual_min,
            actual_max,
            expected_min,
            expected_max,
        },
    );
    if (first_mismatch) |mismatch| {
        std.debug.print(
            " first=({},{}):{}/{}\n",
            .{ mismatch.index % view.width, mismatch.index / view.width, mismatch.actual, mismatch.expected },
        );
    } else {
        std.debug.print("\n", .{});
    }
}

fn comparePlanarPgx(decoded: color.SamplePlanes, asset: ReferenceAsset) !ErrorMetrics {
    const component: usize = asset.metadata.component;
    const dimensions = decoded.componentDimensions(component) orelse return CorpusError.InvalidReference;
    const bit_depth = decoded.componentBitDepth(component) orelse return CorpusError.InvalidReference;
    return comparePgxView(.{
        .width = dimensions[0],
        .height = dimensions[1],
        .bit_depth = bit_depth,
        .signed = false,
        .samples = .{ .unsigned_contiguous = decoded.planes[component] },
    }, asset.bytes, asset.metadata);
}

fn compareNativePgx(decoded: codestream.NativeSamplePlanes, asset: ReferenceAsset) !ErrorMetrics {
    const component = asset.metadata.component;
    if (component >= decoded.planes.len) return CorpusError.InvalidReference;
    const plane = decoded.planes[component];
    return comparePgxView(.{
        .width = plane.layout.width,
        .height = plane.layout.height,
        .bit_depth = plane.layout.precision,
        .signed = plane.layout.signed,
        .samples = .{ .native_contiguous = plane.samples },
    }, asset.bytes, asset.metadata);
}

fn reportNativePgxMismatch(decoded: codestream.NativeSamplePlanes, asset: ReferenceAsset) void {
    const component = asset.metadata.component;
    if (component >= decoded.planes.len) return;
    const plane = decoded.planes[component];
    reportPgxMismatch(.{
        .width = plane.layout.width,
        .height = plane.layout.height,
        .bit_depth = plane.layout.precision,
        .signed = plane.layout.signed,
        .samples = .{ .native_contiguous = plane.samples },
    }, asset);
}

fn reportPlanarPgxMismatch(decoded: color.SamplePlanes, asset: ReferenceAsset) void {
    const component: usize = asset.metadata.component;
    const dimensions = decoded.componentDimensions(component) orelse return;
    const bit_depth = decoded.componentBitDepth(component) orelse return;
    reportPgxMismatch(.{
        .width = dimensions[0],
        .height = dimensions[1],
        .bit_depth = bit_depth,
        .signed = false,
        .samples = .{ .unsigned_contiguous = decoded.planes[component] },
    }, asset);
}

fn compareInterleavedPgx(decoded: image.RgbImage, asset: ReferenceAsset) !ErrorMetrics {
    if (asset.metadata.component >= 3) {
        return CorpusError.InvalidReference;
    }
    return comparePgxView(.{
        .width = decoded.width,
        .height = decoded.height,
        .bit_depth = decoded.bit_depth,
        .signed = false,
        .samples = .{ .unsigned_interleaved = .{
            .values = decoded.samples,
            .stride = 3,
            .component = asset.metadata.component,
        } },
    }, asset.bytes, asset.metadata);
}

fn reportInterleavedPgxMismatch(decoded: image.RgbImage, asset: ReferenceAsset) void {
    if (asset.metadata.component >= 3) return;
    reportPgxMismatch(.{
        .width = decoded.width,
        .height = decoded.height,
        .bit_depth = decoded.bit_depth,
        .signed = false,
        .samples = .{ .unsigned_interleaved = .{
            .values = decoded.samples,
            .stride = 3,
            .component = asset.metadata.component,
        } },
    }, asset);
}

fn hashU32(hasher: *std.crypto.hash.sha2.Sha256, value: usize) !void {
    if (value > std.math.maxInt(u32)) return CorpusError.ImageTooLarge;
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, @intCast(value), .big);
    hasher.update(&encoded);
}

test "native sample hash is stable and sample-sensitive" {
    const allocator = std.testing.allocator;
    var first = try color.SamplePlanes.initWithComponentLayouts(
        allocator,
        2,
        2,
        &.{ 8, 8 },
        &.{ 2, 1 },
        &.{ 2, 2 },
    );
    defer first.deinit();
    first.planes[0][0..4].* = .{ 1, 2, 3, 4 };
    first.planes[1][0..2].* = .{ 5, 6 };
    const baseline = try nativeSampleSha256(first);
    try std.testing.expectEqualSlices(u8, &baseline, &(try nativeSampleSha256(first)));
    first.planes[1][1] = 7;
    const changed = try nativeSampleSha256(first);
    try std.testing.expect(!std.mem.eql(u8, &baseline, &changed));
}

test "planar and interleaved RGB use one canonical native hash" {
    const allocator = std.testing.allocator;
    var planar = try color.SamplePlanes.init(allocator, 2, 1, 8, 3);
    defer planar.deinit();
    const plane0 = [_]u16{ 1, 2 };
    const plane1 = [_]u16{ 3, 4 };
    const plane2 = [_]u16{ 5, 6 };
    @memcpy(planar.planes[0], &plane0);
    @memcpy(planar.planes[1], &plane1);
    @memcpy(planar.planes[2], &plane2);

    var rgb = image.RgbImage{
        .allocator = allocator,
        .width = 2,
        .height = 1,
        .bit_depth = 8,
        .samples = try allocator.dupe(u16, &[_]u16{ 1, 3, 5, 2, 4, 6 }),
    };
    defer rgb.deinit();

    const planar_hash = try nativeSampleSha256(planar);
    const interleaved_hash = try interleavedRgbSha256(rgb);
    try std.testing.expectEqualSlices(u8, &planar_hash, &interleaved_hash);
}

test "PGX comparison accepts big-endian and little-endian unsigned samples" {
    const samples = [_]u16{ 0x123, 0xabc };
    const view = ComponentView{
        .width = 2,
        .height = 1,
        .bit_depth = 12,
        .signed = false,
        .samples = .{ .unsigned_contiguous = &samples },
    };
    const limits = Reference{ .path = "test", .sha256 = "test", .format = .pgx };
    const big_endian = "PG ML + 12 2 1\n\x01\x23\x0a\xbc";
    const big_metrics = try comparePgxView(view, big_endian, limits);
    try std.testing.expectEqual(@as(u32, 0), big_metrics.peak);
    try std.testing.expectEqual(@as(f64, 0), big_metrics.mse);
    const little_endian = "PG LM 12 2 1\n\x23\x01\xbc\x0a";
    const little_metrics = try comparePgxView(view, little_endian, limits);
    try std.testing.expectEqual(@as(u32, 0), little_metrics.peak);
    try std.testing.expectEqual(@as(f64, 0), little_metrics.mse);
}

test "PGX comparison enforces peak and MSE independently" {
    const samples = [_]u16{ 1, 4 };
    const view = ComponentView{
        .width = 2,
        .height = 1,
        .bit_depth = 8,
        .signed = false,
        .samples = .{ .unsigned_contiguous = &samples },
    };
    const pgx = "PG ML + 8 2 1\n\x00\x02";
    const accepted = try comparePgxView(view, pgx, .{
        .path = "test",
        .sha256 = "test",
        .format = .pgx,
        .max_peak_error = 2,
        .max_mse = 2.5,
    });
    try std.testing.expectEqual(@as(u32, 2), accepted.peak);
    try std.testing.expectEqual(@as(f64, 2.5), accepted.mse);
    try std.testing.expectError(
        CorpusError.CorpusMismatch,
        comparePgxView(view, pgx, .{
            .path = "test",
            .sha256 = "test",
            .format = .pgx,
            .max_peak_error = 1,
            .max_mse = 2.5,
        }),
    );
    try std.testing.expectError(
        CorpusError.CorpusMismatch,
        comparePgxView(view, pgx, .{
            .path = "test",
            .sha256 = "test",
            .format = .pgx,
            .max_peak_error = 2,
            .max_mse = 2.49,
        }),
    );
}

test "PGX comparison supports signed sub-byte samples" {
    const samples = [_]i32{ -8, -1, 0, 7 };
    const metrics = try comparePgxView(.{
        .width = 4,
        .height = 1,
        .bit_depth = 4,
        .signed = true,
        .samples = .{ .signed_contiguous = &samples },
    }, "PG ML -4 4 1\n\xf8\xff\x00\x07", .{
        .path = "test",
        .sha256 = "test",
        .format = .pgx,
    });
    try std.testing.expectEqual(@as(u32, 0), metrics.peak);
    try std.testing.expectEqual(@as(f64, 0), metrics.mse);
}

test "PGX comparison selects one component from interleaved samples" {
    const samples = [_]u16{ 1, 3, 5, 2, 4, 6 };
    const metrics = try comparePgxView(.{
        .width = 2,
        .height = 1,
        .bit_depth = 8,
        .signed = false,
        .samples = .{ .unsigned_interleaved = .{
            .values = &samples,
            .stride = 3,
            .component = 1,
        } },
    }, "PG ML +8 2 1\n\x03\x04", .{
        .path = "test",
        .sha256 = "test",
        .format = .pgx,
        .component = 1,
    });
    try std.testing.expectEqual(@as(u32, 0), metrics.peak);
    try std.testing.expectEqual(@as(f64, 0), metrics.mse);
}

test "manifest validation rejects unknown capability references" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "capabilities": [{
        \\    "id": "known", "title": "Known", "parser": "bounded",
        \\    "strict_decode": "bounded", "encode": "bounded",
        \\    "malformed": "bounded", "interop": "bounded",
        \\    "evidence": ["test"], "note": "test"
        \\  }],
        \\  "entries": [{
        \\    "id": "bad", "path": "bad.jp2", "availability": "committed",
        \\    "format": "jp2",
        \\    "sha256": "0000000000000000000000000000000000000000000000000000000000000000",
        \\    "source": {"producer":"test","version":"1","origin":"test","license":"test","redistribution":"test"},
        \\    "oracle": "test",
        \\    "features": ["unknown"], "expectation": "decode_pass"
        \\  }]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(Manifest, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectError(CorpusError.InvalidManifest, validateManifest(parsed.value, true));
}
