const std = @import("std");

pub const InferredConversion = enum {
    tiff_to_jp2,
    bmp_to_jp2,
    png_to_jp2,
    jpeg_to_jp2,
    dng_to_jp2,
    exr_to_jp2,
    jp2_to_tiff,
    j2k_to_pgx,
    j2k_to_zraw,
};

/// Shorthand dispatch based on the two leading path extensions. Explicit
/// subcommands remain the caller's responsibility and therefore always win.
pub fn inferConversion(args: []const []const u8) ?InferredConversion {
    if (args.len < 2) return null;
    if (std.mem.startsWith(u8, args[0], "-") or std.mem.startsWith(u8, args[1], "-")) return null;
    return inferConversionExtensions(
        std.fs.path.extension(args[0]),
        std.fs.path.extension(args[1]),
    );
}

pub fn inferConversionExtensions(input_ext: []const u8, output_ext: []const u8) ?InferredConversion {
    const input_is_tiff = std.ascii.eqlIgnoreCase(input_ext, ".tif") or std.ascii.eqlIgnoreCase(input_ext, ".tiff");
    const input_is_bmp = std.ascii.eqlIgnoreCase(input_ext, ".bmp");
    const input_is_png = std.ascii.eqlIgnoreCase(input_ext, ".png");
    const input_is_jpeg = std.ascii.eqlIgnoreCase(input_ext, ".jpg") or std.ascii.eqlIgnoreCase(input_ext, ".jpeg");
    const input_is_dng = std.ascii.eqlIgnoreCase(input_ext, ".dng");
    const input_is_exr = std.ascii.eqlIgnoreCase(input_ext, ".exr");
    const input_is_jp2 = std.ascii.eqlIgnoreCase(input_ext, ".jp2");
    const input_is_j2k = std.ascii.eqlIgnoreCase(input_ext, ".j2k") or std.ascii.eqlIgnoreCase(input_ext, ".j2c");
    const output_is_tiff = std.ascii.eqlIgnoreCase(output_ext, ".tif") or std.ascii.eqlIgnoreCase(output_ext, ".tiff");
    const output_is_jp2 = std.ascii.eqlIgnoreCase(output_ext, ".jp2");
    const output_is_pgx = std.ascii.eqlIgnoreCase(output_ext, ".pgx");
    const output_is_zraw = std.ascii.eqlIgnoreCase(output_ext, ".zraw");
    if (input_is_tiff and output_is_jp2) return .tiff_to_jp2;
    if (input_is_bmp and output_is_jp2) return .bmp_to_jp2;
    if (input_is_png and output_is_jp2) return .png_to_jp2;
    if (input_is_jpeg and output_is_jp2) return .jpeg_to_jp2;
    if (input_is_dng and output_is_jp2) return .dng_to_jp2;
    if (input_is_exr and output_is_jp2) return .exr_to_jp2;
    if (input_is_jp2 and output_is_tiff) return .jp2_to_tiff;
    if (input_is_j2k and output_is_pgx) return .j2k_to_pgx;
    if (input_is_j2k and output_is_zraw) return .j2k_to_zraw;
    return null;
}
