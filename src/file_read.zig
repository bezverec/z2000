//! Whole-file reads for the conversion commands.

const std = @import("std");
const worker_pool = @import("worker_pool.zig");

pub const ReadError = error{ StreamTooLong, TruncatedFile };

/// Files at least this large are read in ranges on the shared pool.
const parallel_min_bytes = 4 << 20;
const max_ranges = 8;

/// Reads the whole file at `path` into one buffer of its size; a file of
/// `max_size` bytes or more is `error.StreamTooLong`, as for
/// `std.Io.Dir.readFileAlloc`. A large file is read in up to eight ranges on
/// the shared pool when it is free, which spreads the copy out of the page
/// cache and the buffer's page faults over several threads.
pub fn readWholeFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_size: u64) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const size = try file.length(io);
    if (size >= max_size) return error.StreamTooLong;
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);

    var jobs: [max_ranges]RangeJob = undefined;
    const count: usize = if (bytes.len >= parallel_min_bytes) max_ranges else 1;
    for (jobs[0..count], 0..) |*job, index| {
        const begin = bytes.len * index / count;
        const end = bytes.len * (index + 1) / count;
        job.* = .{ .io = io, .file = file, .bytes = bytes[begin..end], .offset = begin };
    }
    if (count == 1 or !worker_pool.runJobs(RangeJob, jobs[0..count], RangeJob.run)) {
        for (jobs[0..count]) |*job| job.run();
    }
    for (jobs[0..count]) |job| try job.result;
    return bytes;
}

const RangeJob = struct {
    io: std.Io,
    file: std.Io.File,
    bytes: []u8,
    offset: u64,
    result: anyerror!void = {},

    fn run(job: *RangeJob) void {
        const length = job.file.readPositionalAll(job.io, job.bytes, job.offset) catch |err| {
            job.result = err;
            return;
        };
        // The file shrank while it was read.
        if (length != job.bytes.len) job.result = ReadError.TruncatedFile;
    }
};
