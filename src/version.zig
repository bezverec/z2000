const build_options = @import("build_options.zig");

/// Manually selected pre-1.0 application/API version from the VERSION file.
pub const base = build_options.version_base;

/// Complete SemVer string including the Git-derived build provenance.
pub const string = build_options.version;
pub const build_number = build_options.build_number;
pub const git_sha = build_options.git_sha;
pub const dirty = build_options.git_dirty;
pub const is_release = build_options.release_build;
