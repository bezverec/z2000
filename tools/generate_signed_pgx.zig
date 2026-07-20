const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();
    const output_path = args.next() orelse return error.MissingOutputPath;
    const precision_text = args.next();
    if (args.next() != null) return error.TooManyArguments;
    const precision = if (precision_text) |text|
        try std.fmt.parseInt(u8, text, 10)
    else
        8;

    var pgx: std.ArrayList(u8) = .empty;
    defer pgx.deinit(allocator);
    switch (precision) {
        8 => {
            try pgx.appendSlice(allocator, "PG ML -8 16 16\n");
            for (0..256) |index| try pgx.append(allocator, @truncate(index + 128));
        },
        16 => {
            try pgx.appendSlice(allocator, "PG ML -16 16 16\n");
            for (0..256) |index| {
                const sample: i16 = if (index == 255)
                    32767
                else
                    @intCast(-32768 + @as(i32, @intCast(index)) * 256);
                const raw: u16 = @bitCast(sample);
                try pgx.append(allocator, @truncate(raw >> 8));
                try pgx.append(allocator, @truncate(raw));
            }
        },
        20 => {
            try pgx.appendSlice(allocator, "PG ML -20 16 16\n");
            for (0..256) |index| {
                const sample: i32 = if (index == 255)
                    524287
                else
                    -524288 + @as(i32, @intCast(index)) * 4096;
                const raw: u32 = @bitCast(sample);
                try pgx.append(allocator, @truncate(raw >> 24));
                try pgx.append(allocator, @truncate(raw >> 16));
                try pgx.append(allocator, @truncate(raw >> 8));
                try pgx.append(allocator, @truncate(raw));
            }
        },
        else => return error.UnsupportedPrecision,
    }
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output_path, .data = pgx.items });
}
