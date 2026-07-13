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
pub const f32_pair_lanes: comptime_int = 2;

/// Block width (in f32 lanes) for the 9/7 lifting kernels: two 64-byte cache
/// lines per row access. LLVM splits the block into however many native
/// registers the target has (8x NEON q-regs, 4x AVX2 ymm, 2x AVX-512 zmm),
/// so one constant serves every ISA. The S3 lane audit on the Ryzen 5700X
/// measured 32 lanes ahead of both 16 (the prior value) and 8 on the lossy
/// profile: encode t1 -6.0%, decode t1 -4.3% (20-run), encode/decode t16
/// -4.9%/-5.1%, lossless unchanged, streams bit-identical. Re-run the A/B on
/// the M4 before assuming the same win on NEON.
pub const f32_block_lanes: comptime_int = 32;

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
