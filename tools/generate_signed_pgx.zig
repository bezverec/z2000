const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const output_path = args.next() orelse return error.MissingOutputPath;
    const precision_text = args.next();
    const width_text = args.next();
    const height_text = args.next();
    if (args.next() != null) return error.TooManyArguments;
    const precision = if (precision_text) |text|
        try std.fmt.parseInt(u8, text, 10)
    else
        8;
    if ((width_text == null) != (height_text == null)) return error.MissingDimension;
    const width = if (width_text) |text| try std.fmt.parseInt(usize, text, 10) else 16;
    const height = if (height_text) |text| try std.fmt.parseInt(usize, text, 10) else 16;

    if (precision == 0 or precision > 32) return error.UnsupportedPrecision;
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const sample_count = std.math.mul(usize, width, height) catch return error.InvalidDimensions;
    if (sample_count > 1 << 24) return error.InvalidDimensions;

    var pgx: std.ArrayList(u8) = .empty;
    defer pgx.deinit(allocator);
    const header = try std.fmt.allocPrint(allocator, "PG ML -{d} {d} {d}\n", .{ precision, width, height });
    defer allocator.free(header);
    try pgx.appendSlice(allocator, header);

    const span = @as(i64, 1) << @as(u6, @intCast(precision));
    const minimum = -(span >> 1);
    const maximum = (span >> 1) - 1;
    for (0..sample_count) |index| {
        const sample = if (index + 1 == sample_count)
            maximum
        else
            minimum + @divTrunc(
                @as(i64, @intCast(index)) * span,
                @as(i64, @intCast(sample_count)),
            );
        const raw: u64 = @bitCast(sample);
        if (precision <= 8) {
            try pgx.append(allocator, @truncate(raw));
        } else if (precision <= 16) {
            try pgx.append(allocator, @truncate(raw >> 8));
            try pgx.append(allocator, @truncate(raw));
        } else {
            try pgx.append(allocator, @truncate(raw >> 24));
            try pgx.append(allocator, @truncate(raw >> 16));
            try pgx.append(allocator, @truncate(raw >> 8));
            try pgx.append(allocator, @truncate(raw));
        }
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = pgx.items });
}
