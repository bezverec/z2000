const std = @import("std");
const builtin = @import("builtin");

pub const i32_lanes: comptime_int = switch (builtin.target.cpu.arch) {
    .x86, .x86_64 => x86I32Lanes(),
    .aarch64, .aarch64_be => 4,
    .arm, .armeb, .thumb, .thumbeb => 4,
    else => 4,
};

pub const has_neon: bool = switch (builtin.target.cpu.arch) {
    .aarch64, .aarch64_be => true,
    else => false,
};

pub const neon_i32_lanes: comptime_int = 4;

pub const family: []const u8 = switch (builtin.target.cpu.arch) {
    .x86, .x86_64 => x86Family(),
    .aarch64, .aarch64_be => "NEON-128",
    .arm, .armeb, .thumb, .thumbeb => "ARM-vector",
    else => "portable",
};

fn x86I32Lanes() comptime_int {
    const features = builtin.target.cpu.features;
    if (std.Target.x86.featureSetHas(features, .avx512f)) return 16;
    if (std.Target.x86.featureSetHas(features, .avx2)) return 8;
    return 4;
}

fn x86Family() []const u8 {
    const features = builtin.target.cpu.features;
    if (std.Target.x86.featureSetHas(features, .avx512f)) return "AVX-512F";
    if (std.Target.x86.featureSetHas(features, .avx2)) return "AVX2";
    return "SSE-width";
}
