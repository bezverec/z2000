const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const release_build = b.option(
        bool,
        "release",
        "Format the application version as a release rather than a development build",
    ) orelse false;
    const prerelease = b.option(
        []const u8,
        "prerelease",
        "Optional SemVer prerelease label for release builds, for example rc.1",
    ) orelse "";
    const build_number = b.option(
        u64,
        "build-number",
        "Override the build number (defaults to the reachable Git commit count)",
    ) orelse gitBuildNumber(b) orelse 0;
    const git_sha = b.option(
        []const u8,
        "git-sha",
        "Override the Git revision embedded in the application version",
    ) orelse gitRevision(b) orelse "unknown";
    const git_dirty = b.option(
        bool,
        "git-dirty",
        "Override whether the build provenance is marked as a dirty worktree",
    ) orelse gitWorktreeDirty(b);
    const packed_t1_context_flags = b.option(
        bool,
        "packed-t1-context-flags",
        "Use the experimental OpenJPEG-style packed T1 context-word hot path",
    ) orelse false;

    if (!validGitRevision(git_sha)) {
        std.debug.panic("invalid -Dgit-sha value '{s}': expected 7-40 hexadecimal characters or 'unknown'", .{git_sha});
    }
    if (prerelease.len > 0 and !release_build) {
        std.debug.panic("-Dprerelease requires -Drelease=true", .{});
    }
    const base_version = readBaseVersion(b);
    const dirty_suffix = if (git_dirty) ".dirty" else "";
    const application_version = if (release_build)
        if (prerelease.len > 0)
            b.fmt("{s}-{s}+build.{d}.g{s}{s}", .{ base_version, prerelease, build_number, git_sha, dirty_suffix })
        else
            b.fmt("{s}+build.{d}.g{s}{s}", .{ base_version, build_number, git_sha, dirty_suffix })
    else
        b.fmt("{s}-dev.{d}+g{s}{s}", .{ base_version, build_number, git_sha, dirty_suffix });
    _ = std.SemanticVersion.parse(application_version) catch {
        std.debug.panic("generated application version is not valid SemVer: '{s}'", .{application_version});
    };

    const options = b.addOptions();
    options.addOption(bool, "packed_t1_context_flags", packed_t1_context_flags);
    options.addOption([]const u8, "version_base", base_version);
    options.addOption([]const u8, "version", application_version);
    options.addOption([]const u8, "prerelease", prerelease);
    options.addOption(u64, "build_number", build_number);
    options.addOption([]const u8, "git_sha", git_sha);
    options.addOption(bool, "git_dirty", git_dirty);
    options.addOption(bool, "release_build", release_build);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addOptions("build_options.zig", options);
    const exe = b.addExecutable(.{
        .name = "z2000",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the codec CLI");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options.zig", options);
    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}

fn readBaseVersion(b: *std.Build) []const u8 {
    const raw = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "VERSION",
        b.allocator,
        .limited(128),
    ) catch |err| std.debug.panic("cannot read VERSION: {s}", .{@errorName(err)});
    const version = std.mem.trim(u8, raw, " \t\r\n");
    if (version.len == 0) std.debug.panic("VERSION must not be empty", .{});
    const parsed = std.SemanticVersion.parse(version) catch {
        std.debug.panic("VERSION is not valid SemVer: '{s}'", .{version});
    };
    if (parsed.pre != null or parsed.build != null) {
        std.debug.panic("VERSION must contain only MAJOR.MINOR.PATCH: '{s}'", .{version});
    }
    return version;
}

fn gitBuildNumber(b: *std.Build) ?u64 {
    const output = runGit(b, &.{ "rev-list", "--count", "HEAD" }) orelse return null;
    return std.fmt.parseInt(u64, output, 10) catch null;
}

fn gitRevision(b: *std.Build) ?[]const u8 {
    const output = runGit(b, &.{ "rev-parse", "--short=8", "HEAD" }) orelse return null;
    return if (validGitRevision(output)) output else null;
}

fn gitWorktreeDirty(b: *std.Build) bool {
    const output = runGit(b, &.{ "status", "--porcelain=v1", "--untracked-files=no" }) orelse
        return false;
    return output.len != 0;
}

fn runGit(b: *std.Build, arguments: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(b.allocator, &.{ "git", "-C", b.pathFromRoot(".") }) catch @panic("OOM");
    argv.appendSlice(b.allocator, arguments) catch @panic("OOM");
    var exit_code: u8 = 0;
    const output = b.runAllowFail(argv.items, &exit_code, .ignore) catch return null;
    return std.mem.trim(u8, output, " \t\r\n");
}

fn validGitRevision(revision: []const u8) bool {
    if (std.mem.eql(u8, revision, "unknown")) return true;
    if (revision.len < 7 or revision.len > 40) return false;
    for (revision) |character| {
        if (!std.ascii.isHex(character)) return false;
    }
    return true;
}
