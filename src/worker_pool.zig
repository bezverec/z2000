//! Process-wide worker threads shared by the decode stages.
//!
//! A decode used to spawn a fresh set of threads for every parallel stage
//! (Tier-1, colour conversion, dequantization), about 50 microseconds each
//! on Windows. This pool starts its threads once, can start them in the
//! background while the caller still parses the codestream (`prepare`), and
//! lets them sleep on a futex between tasks.
//!
//! A task is `count` independent indices. `run` hands them out to the
//! pool's threads and the calling thread, and returns once every index has
//! finished and every pool thread has acknowledged the task, so no thread
//! can carry into the next one. Indices must not wait for one another:
//! a thread may run several of them in turn, so a barrier between indices
//! could deadlock. One task runs at a time; a concurrent `run` returns
//! false and the caller falls back to its own threads.
const std = @import("std");
const builtin = @import("builtin");

/// Most pool threads ever started (the caller is one more).
pub const max_threads = 63;

const Pool = struct {
    threads: [max_threads]std.Thread = undefined,
    /// Started threads; only grows, under `busy` or the starter.
    started: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Set while a task (or a background start) owns the pool.
    busy: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Futex word the threads sleep on; bumped once per task.
    generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Futex word the caller sleeps on: threads that finished the task.
    acknowledged: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    participants: u32 = 0,
    next_index: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    count: usize = 0,
    context: *anyopaque = undefined,
    task: *const fn (*anyopaque, usize) void = undefined,
};

var pool: Pool = .{};

fn futexIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// `seen` is the generation when the thread was started: it joins only
/// tasks published after that, never one already being acknowledged.
fn worker(start_generation: u32) void {
    var seen = start_generation;
    while (true) {
        var current = pool.generation.load(.acquire);
        while (current == seen) {
            futexIo().futexWaitUncancelable(u32, &pool.generation.raw, seen);
            current = pool.generation.load(.acquire);
        }
        seen = current;
        drain();
        if (pool.acknowledged.fetchAdd(1, .acq_rel) + 1 == pool.participants) {
            futexIo().futexWake(u32, &pool.acknowledged.raw, 1);
        }
    }
}

fn drain() void {
    while (true) {
        const index = pool.next_index.fetchAdd(1, .monotonic);
        if (index >= pool.count) return;
        pool.task(pool.context, index);
    }
}

/// Starts pool threads up to `threads - 1` (the caller is the last one).
/// Must hold `busy`. A failed spawn leaves the pool smaller.
fn grow(threads: usize) void {
    const wanted: u32 = @intCast(@min(threads -| 1, max_threads));
    var started = pool.started.load(.monotonic);
    while (started < wanted) : (started += 1) {
        pool.threads[started] = std.Thread.spawn(.{}, worker, .{pool.generation.load(.acquire)}) catch break;
        pool.started.store(started + 1, .release);
    }
}

fn growInBackground(threads: usize) void {
    grow(threads);
    pool.busy.store(false, .release);
}

/// Starts the pool's threads for a later `run` with up to `threads` workers
/// on a helper thread, so the caller can keep parsing. Does nothing when
/// they are already there or the pool is busy.
pub fn prepare(threads: usize) void {
    if (builtin.single_threaded or threads < 2) return;
    if (pool.started.load(.acquire) + 1 >= @min(threads, max_threads + 1)) return;
    if (pool.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
    const helper = std.Thread.spawn(.{}, growInBackground, .{threads}) catch {
        pool.busy.store(false, .release);
        return;
    };
    helper.detach();
}

/// Runs `task(context, i)` for every `i` in `0..count` on the pool's threads
/// and the caller, using up to `threads` threads in all. Returns false,
/// having run nothing, when the pool is busy; the caller then runs the work
/// its own way.
pub fn run(threads: usize, count: usize, context: *anyopaque, task: *const fn (*anyopaque, usize) void) bool {
    if (count == 0) return true;
    if (builtin.single_threaded or threads < 2 or count == 1) {
        for (0..count) |index| task(context, index);
        return true;
    }
    if (pool.busy.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return false;
    defer pool.busy.store(false, .release);
    grow(threads);
    const participants = pool.started.load(.acquire);
    if (participants == 0) {
        for (0..count) |index| task(context, index);
        return true;
    }

    pool.count = count;
    pool.context = context;
    pool.task = task;
    pool.participants = participants;
    pool.next_index.store(0, .monotonic);
    pool.acknowledged.store(0, .monotonic);
    _ = pool.generation.fetchAdd(1, .release);
    futexIo().futexWake(u32, &pool.generation.raw, std.math.maxInt(u32));

    drain();
    while (true) {
        const done = pool.acknowledged.load(.acquire);
        if (done == participants) break;
        futexIo().futexWaitUncancelable(u32, &pool.acknowledged.raw, done);
    }
    return true;
}

/// Calls `value.deinit()` on a short-lived detached thread, so releasing a
/// large buffer overlaps whatever the caller does next: unmapping pages that
/// many threads have touched costs milliseconds on Windows. `value` must own
/// its memory through a thread-safe allocator, and nothing may refer to that
/// memory any more. Falls back to releasing it on the calling thread.
pub fn deinitInBackground(value: anytype) void {
    const T = @TypeOf(value);
    const Release = struct {
        fn run(owned: T) void {
            var released = owned;
            released.deinit();
        }
    };
    if (!builtin.single_threaded) {
        if (std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Release.run, .{value})) |thread| {
            thread.detach();
            return;
        } else |_| {}
    }
    Release.run(value);
}

/// `run` over a slice of jobs, one index per job, each handed to `work`.
pub fn runJobs(comptime Job: type, jobs: []Job, comptime work: fn (*Job) void) bool {
    const Adapter = struct {
        fn call(context: *anyopaque, index: usize) void {
            const all: [*]Job = @ptrCast(@alignCast(context));
            work(&all[index]);
        }
    };
    return run(jobs.len, jobs.len, @ptrCast(jobs.ptr), Adapter.call);
}
