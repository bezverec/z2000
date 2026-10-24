//! Sampling profiler for Windows that needs no administrator rights (ETW
//! kernel sampling via xperf/WPR does). It runs the command that follows on
//! its own command line Z_SAMPLER_RUNS times (default 1), samples the main
//! thread's instruction pointer about once per millisecond, and prints the
//! hottest outermost functions, innermost inlined functions, and source lines
//! through DbgHelp and the executable's PDB. Single-threaded runs only
//! (`--threads 1`); no call stacks, since Win64 frame pointers do not chain.
//!
//!   zig build-exe tools/win_sample_profile.zig -O ReleaseSafe -ldbghelp -lwinmm -lntdll
//!   set Z_SAMPLER_RUNS=6
//!   win_sample_profile.exe zig-out/bin/z2000.exe decode-temp-jp2 in.jp2 out.tif --threads 1
//!
//! Keep the PDB beside the executable under the name the build wrote.
const std = @import("std");

const BOOL = i32;
const DWORD = u32;
const HANDLE = ?*anyopaque;

const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: HANDLE = null,
    hStdOutput: HANDLE = null,
    hStdError: HANDLE = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: [*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: BOOL, flags: DWORD, env: ?*anyopaque, cwd: ?[*:0]const u16, si: *STARTUPINFOW, pi: *PROCESS_INFORMATION) callconv(.winapi) BOOL;
extern "kernel32" fn ResumeThread(h: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn SuspendThread(h: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn GetThreadContext(h: HANDLE, ctx: *anyopaque) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn Sleep(ms: DWORD) callconv(.winapi) void;
extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn ReadProcessMemory(h: HANDLE, addr: usize, buf: [*]u8, size: usize, read: ?*usize) callconv(.winapi) BOOL;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: DWORD) callconv(.winapi) DWORD;
extern "ntdll" fn NtQueryInformationProcess(h: HANDLE, class: u32, info: *anyopaque, len: u32, ret: ?*u32) callconv(.winapi) i32;
extern "winmm" fn timeBeginPeriod(ms: u32) callconv(.winapi) u32;

extern "dbghelp" fn SymSetOptions(options: DWORD) callconv(.winapi) DWORD;
extern "dbghelp" fn SymInitialize(h: HANDLE, path: ?[*:0]const u8, invade: BOOL) callconv(.winapi) BOOL;
extern "dbghelp" fn SymLoadModuleEx(h: HANDLE, file: HANDLE, image: [*:0]const u8, module: ?[*:0]const u8, base: u64, size: DWORD, data: ?*anyopaque, flags: DWORD) callconv(.winapi) u64;
extern "dbghelp" fn SymAddrIncludeInlineTrace(h: HANDLE, addr: u64) callconv(.winapi) DWORD;
extern "dbghelp" fn SymQueryInlineTrace(h: HANDLE, start: u64, start_ctx: DWORD, start_ret: u64, cur: u64, cur_ctx: *DWORD, cur_frame: *DWORD) callconv(.winapi) BOOL;
extern "dbghelp" fn SymFromInlineContext(h: HANDLE, addr: u64, ctx: DWORD, disp: *u64, sym: *anyopaque) callconv(.winapi) BOOL;
extern "dbghelp" fn SymGetLineFromInlineContext(h: HANDLE, addr: u64, ctx: DWORD, base: u64, disp: *DWORD, line: *ImagehlpLine64) callconv(.winapi) BOOL;
extern "dbghelp" fn SymFromAddr(h: HANDLE, addr: u64, disp: *u64, sym: *anyopaque) callconv(.winapi) BOOL;
extern "dbghelp" fn SymGetLineFromAddr64(h: HANDLE, addr: u64, disp: *DWORD, line: *ImagehlpLine64) callconv(.winapi) BOOL;

const ImagehlpLine64 = extern struct {
    size: DWORD = @sizeOf(ImagehlpLine64),
    key: ?*anyopaque = null,
    line: DWORD = 0,
    file: ?[*:0]const u8 = null,
    address: u64 = 0,
};

const CONTEXT_CONTROL: u32 = 0x100001;
const CREATE_SUSPENDED: u32 = 4;
const fake_base: u64 = 0x140000000;

const Entry = struct { key: []const u8, count: usize };

fn bump(map: *std.StringHashMapUnmanaged(usize), allocator: std.mem.Allocator, key: []const u8, n: usize) !void {
    const gop = try map.getOrPut(allocator, key);
    if (!gop.found_existing) {
        gop.key_ptr.* = try allocator.dupe(u8, key);
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += n;
}

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return a.count > b.count;
}

fn printTop(allocator: std.mem.Allocator, title: []const u8, map: *std.StringHashMapUnmanaged(usize), total: usize, limit: usize) !void {
    var list: std.ArrayList(Entry) = .empty;
    var it = map.iterator();
    while (it.next()) |e| try list.append(allocator, .{ .key = e.key_ptr.*, .count = e.value_ptr.* });
    std.mem.sort(Entry, list.items, {}, lessThan);
    std.debug.print("\n== {s} ({d} samples)\n", .{ title, total });
    for (list.items[0..@min(limit, list.items.len)]) |e| {
        std.debug.print("{d:6.2}% {d:6}  {s}\n", .{ @as(f64, @floatFromInt(e.count)) * 100.0 / @as(f64, @floatFromInt(total)), e.count, e.key });
    }
}

fn shortFile(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '\\' or path[i - 1] == '/') break;
    }
    return path[i..];
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    // Child command line: everything after our own executable token.
    const full = std.mem.span(GetCommandLineW());
    var i: usize = 0;
    if (full.len > 0 and full[0] == '"') {
        i = 1;
        while (i < full.len and full[i] != '"') i += 1;
        i += 1;
    } else {
        while (i < full.len and full[i] != ' ') i += 1;
    }
    while (i < full.len and full[i] == ' ') i += 1;
    const child = full[i..];

    var runs: usize = 1;
    var env_buf: [32]u8 = undefined;
    const env_len = GetEnvironmentVariableA("Z_SAMPLER_RUNS", &env_buf, env_buf.len);
    if (env_len > 0 and env_len < env_buf.len) runs = try std.fmt.parseInt(usize, env_buf[0..env_len], 10);

    _ = timeBeginPeriod(1);
    var offsets: std.ArrayList(u64) = .empty;
    var outside: usize = 0;
    var image_path_buf: [1024]u8 = undefined;
    var image_path: []const u8 = "";

    var run: usize = 0;
    while (run < runs) : (run += 1) {
        var cmd_buf: [32768]u16 = undefined;
        @memcpy(cmd_buf[0..child.len], child);
        cmd_buf[child.len] = 0;
        var si = STARTUPINFOW{ .cb = @sizeOf(STARTUPINFOW) };
        var pi: PROCESS_INFORMATION = undefined;
        if (CreateProcessW(null, cmd_buf[0..child.len :0], null, null, 1, CREATE_SUSPENDED, null, null, &si, &pi) == 0) return error.CreateProcessFailed;

        // Image base from the PEB, image size from the PE header.
        var pbi: [6]usize = undefined;
        if (NtQueryInformationProcess(pi.hProcess, 0, &pbi, @sizeOf(@TypeOf(pbi)), null) != 0) return error.QueryFailed;
        var base: usize = 0;
        if (ReadProcessMemory(pi.hProcess, pbi[1] + 0x10, @ptrCast(&base), 8, null) == 0) return error.ReadFailed;
        var lfanew: u32 = 0;
        _ = ReadProcessMemory(pi.hProcess, base + 0x3c, @ptrCast(&lfanew), 4, null);
        var image_size: u32 = 0;
        _ = ReadProcessMemory(pi.hProcess, base + lfanew + 0x50, @ptrCast(&image_size), 4, null);

        _ = ResumeThread(pi.hThread);
        var ctx: [1232]u8 align(16) = undefined;
        while (WaitForSingleObject(pi.hProcess, 0) != 0) {
            Sleep(1);
            if (SuspendThread(pi.hThread) == 0xffffffff) break;
            @memset(&ctx, 0);
            std.mem.writeInt(u32, ctx[0x30..0x34], CONTEXT_CONTROL, .little);
            const ok = GetThreadContext(pi.hThread, &ctx);
            _ = ResumeThread(pi.hThread);
            if (ok == 0) continue;
            const rip = std.mem.readInt(u64, ctx[0xf8..0x100], .little);
            if (rip >= base and rip < base + image_size) {
                try offsets.append(allocator, rip - base);
            } else outside += 1;
        }
        _ = CloseHandle(pi.hThread);
        _ = CloseHandle(pi.hProcess);
    }

    // The image is the child's first token.
    {
        var j: usize = 0;
        var end: usize = 0;
        if (child.len > 0 and child[0] == '"') {
            j = 1;
            end = 1;
            while (end < child.len and child[end] != '"') end += 1;
        } else {
            while (end < child.len and child[end] != ' ') end += 1;
        }
        var n: usize = 0;
        while (j < end) : (j += 1) {
            image_path_buf[n] = @intCast(child[j] & 0x7f);
            n += 1;
        }
        image_path_buf[n] = 0;
        image_path = image_path_buf[0..n];
    }

    const proc = GetCurrentProcess();
    _ = SymSetOptions(0x2 | 0x10 | 0x40000); // UNDNAME | LOAD_LINES | DEBUG off-noise
    if (SymInitialize(proc, null, 0) == 0) return error.SymInitFailed;
    if (SymLoadModuleEx(proc, null, @ptrCast(image_path_buf[0..image_path.len :0]), null, fake_base, 0, null, 0) == 0) return error.SymLoadFailed;

    var by_inner: std.StringHashMapUnmanaged(usize) = .empty;
    var by_line: std.StringHashMapUnmanaged(usize) = .empty;
    var by_outer: std.StringHashMapUnmanaged(usize) = .empty;

    std.mem.sort(u64, offsets.items, {}, std.sort.asc(u64));
    var sym_buf: [88 + 1024]u8 align(8) = undefined;
    var k: usize = 0;
    var key_buf: [2048]u8 = undefined;
    while (k < offsets.items.len) {
        var run_end = k;
        while (run_end < offsets.items.len and offsets.items[run_end] == offsets.items[k]) run_end += 1;
        const count = run_end - k;
        const addr = fake_base + offsets.items[k];
        k = run_end;

        @memset(&sym_buf, 0);
        std.mem.writeInt(u32, sym_buf[0..4], 88, .little);
        std.mem.writeInt(u32, sym_buf[80..84], 1024, .little);
        var disp64: u64 = 0;
        var outer_name: []const u8 = "?";
        if (SymFromAddr(proc, addr, &disp64, &sym_buf) != 0) {
            outer_name = try allocator.dupe(u8, std.mem.sliceTo(@as([*:0]const u8, @ptrCast(sym_buf[84..].ptr)), 0));
        }
        try bump(&by_outer, allocator, outer_name, count);

        var inner_name = outer_name;
        var line = ImagehlpLine64{};
        var disp32: DWORD = 0;
        var have_line = false;
        const inline_count = SymAddrIncludeInlineTrace(proc, addr);
        if (inline_count > 0) {
            var inline_ctx: DWORD = 0;
            var frame: DWORD = 0;
            if (SymQueryInlineTrace(proc, addr, 0, addr, addr, &inline_ctx, &frame) != 0) {
                @memset(&sym_buf, 0);
                std.mem.writeInt(u32, sym_buf[0..4], 88, .little);
                std.mem.writeInt(u32, sym_buf[80..84], 1024, .little);
                if (SymFromInlineContext(proc, addr, inline_ctx, &disp64, &sym_buf) != 0) {
                    inner_name = try allocator.dupe(u8, std.mem.sliceTo(@as([*:0]const u8, @ptrCast(sym_buf[84..].ptr)), 0));
                }
                have_line = SymGetLineFromInlineContext(proc, addr, inline_ctx, fake_base, &disp32, &line) != 0;
            }
        }
        if (!have_line) have_line = SymGetLineFromAddr64(proc, addr, &disp32, &line) != 0;
        try bump(&by_inner, allocator, inner_name, count);
        const line_key = if (have_line and line.file != null)
            try std.fmt.bufPrint(&key_buf, "{s}:{d}  [{s}]", .{ shortFile(std.mem.span(line.file.?)), line.line, inner_name })
        else
            try std.fmt.bufPrint(&key_buf, "?  [{s}]", .{inner_name});
        try bump(&by_line, allocator, line_key, count);
    }

    const total = offsets.items.len;
    std.debug.print("samples in image {d}, outside {d}, runs {d}\n", .{ total, outside, runs });
    try printTop(allocator, "outermost function", &by_outer, total, 25);
    try printTop(allocator, "innermost (inlined) function", &by_inner, total, 40);
    try printTop(allocator, "source line", &by_line, total, 60);
}
