//! Runs a command confined to a set of logical processors on Windows, for
//! comparing decoders per core type (P-cores, their hyper-threads, E-cores).
//! The child starts suspended inside a job object whose affinity limit no
//! thread can leave: a plain process affinity mask is not enough, since a
//! program that sets its own thread affinities (Kakadu's thread pool does)
//! escapes it. Exits with the child's exit code.
//!
//!   zig build-exe tools/win_affinity_run.zig -O ReleaseFast
//!   win_affinity_run.exe FF000 zig-out/bin/z2000.exe decode-temp-jp2 in.jp2 out.tif --threads 8
//!
//! The mask is hexadecimal, one bit per logical processor of the first
//! processor group (on an i5-14500: 0-11 are the six P-cores' hyper-thread
//! pairs, 12-19 the E-cores). The rest of the command line is passed through
//! unchanged.
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

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: DWORD = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: DWORD = 0,
    Affinity: usize = 0,
    PriorityClass: DWORD = 0,
    SchedulingClass: DWORD = 0,
};

const CREATE_SUSPENDED: DWORD = 0x4;
const JobObjectBasicLimitInformation: DWORD = 2;
const JOB_OBJECT_LIMIT_AFFINITY: DWORD = 0x10;
const INFINITE: DWORD = 0xffff_ffff;

extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]u16;
extern "kernel32" fn CreateProcessW(
    application: ?[*:0]const u16,
    command_line: [*:0]u16,
    process_attributes: ?*anyopaque,
    thread_attributes: ?*anyopaque,
    inherit_handles: BOOL,
    flags: DWORD,
    environment: ?*anyopaque,
    directory: ?[*:0]const u16,
    startup: *STARTUPINFOW,
    info: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) HANDLE;
extern "kernel32" fn SetInformationJobObject(job: HANDLE, class: DWORD, info: *anyopaque, length: DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn AssignProcessToJobObject(job: HANDLE, process: HANDLE) callconv(.winapi) BOOL;
extern "kernel32" fn TerminateProcess(process: HANDLE, code: u32) callconv(.winapi) BOOL;
extern "kernel32" fn ResumeThread(thread: HANDLE) callconv(.winapi) DWORD;
extern "kernel32" fn WaitForSingleObject(handle: HANDLE, milliseconds: DWORD) callconv(.winapi) DWORD;
extern "kernel32" fn GetExitCodeProcess(process: HANDLE, code: *DWORD) callconv(.winapi) BOOL;
extern "kernel32" fn ExitProcess(code: u32) callconv(.winapi) noreturn;

fn skipSpaces(line: []const u16, start: usize) usize {
    var i = start;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return i;
}

pub fn main() !void {
    const line = std.mem.span(GetCommandLineW());
    // Skip this program's own name, quoted or not.
    var i: usize = 0;
    if (line.len > 0 and line[0] == '"') {
        i = 1;
        while (i < line.len and line[i] != '"') i += 1;
        i += 1;
    } else {
        while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
    }
    i = skipSpaces(line, i);

    var mask: usize = 0;
    const mask_start = i;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {
        if (line[i] > 0x7f) return error.BadMask;
        const digit = std.fmt.charToDigit(@intCast(line[i]), 16) catch return error.BadMask;
        mask = std.math.mul(usize, mask, 16) catch return error.BadMask;
        mask += digit;
    }
    if (i == mask_start or mask == 0) return error.BadMask;
    i = skipSpaces(line, i);
    if (i >= line.len) return error.MissingCommand;

    // CreateProcessW may write into the command line, so pass a copy.
    const child = line[i..];
    var buffer: [32768]u16 = undefined;
    if (child.len >= buffer.len) return error.CommandTooLong;
    @memcpy(buffer[0..child.len], child);
    buffer[child.len] = 0;

    const job = CreateJobObjectW(null, null) orelse return error.CreateJobFailed;
    var limit = JOBOBJECT_BASIC_LIMIT_INFORMATION{
        .LimitFlags = JOB_OBJECT_LIMIT_AFFINITY,
        .Affinity = mask,
    };
    if (SetInformationJobObject(job, JobObjectBasicLimitInformation, &limit, @sizeOf(JOBOBJECT_BASIC_LIMIT_INFORMATION)) == 0) {
        return error.SetJobLimitFailed;
    }

    var startup = STARTUPINFOW{ .cb = @sizeOf(STARTUPINFOW) };
    var info: PROCESS_INFORMATION = undefined;
    if (CreateProcessW(null, buffer[0..child.len :0], null, null, 1, CREATE_SUSPENDED, null, null, &startup, &info) == 0) {
        return error.CreateProcessFailed;
    }
    if (AssignProcessToJobObject(job, info.hProcess) == 0) {
        _ = TerminateProcess(info.hProcess, 1);
        return error.AssignJobFailed;
    }
    _ = ResumeThread(info.hThread);
    _ = WaitForSingleObject(info.hProcess, INFINITE);
    var code: DWORD = 1;
    _ = GetExitCodeProcess(info.hProcess, &code);
    ExitProcess(code);
}
