const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");
const posix = std.posix;
const compat_fd = @import("../lib/compat/fd.zig");

/// pipe() that works on Windows and POSIX. For POSIX systems, this sets
/// CLOEXEC on the file descriptors.
pub fn pipe() ![2]posix.fd_t {
    switch (builtin.os.tag) {
        else => return compat_fd.pipe2(.{ .CLOEXEC = true }),
        .windows => {
            var read_end: windows.HANDLE = undefined;
            var write_end: windows.HANDLE = undefined;
            if (windows.exp.kernel32.CreatePipe(&read_end, &write_end, null, 0) == windows.FALSE) {
                return windows.unexpectedError(windows.GetLastError());
            }

            return .{ read_end, write_end };
        },
    }
}

/// Close one end of a pipe returned by `pipe`.
pub fn close(fd: posix.fd_t) void {
    switch (builtin.os.tag) {
        else => _ = posix.system.close(fd),
        .windows => _ = windows.exp.kernel32.CloseHandle(fd),
    }
}

pub const WriteError = error{BrokenPipe} || std.posix.UnexpectedError;

/// Write the given bytes to the write end of a pipe returned by
/// `pipe`, returning the number of bytes written.
pub fn write(fd: posix.fd_t, bytes: []const u8) WriteError!usize {
    switch (builtin.os.tag) {
        else => {
            const rc = posix.system.write(fd, bytes.ptr, bytes.len);
            return switch (posix.errno(rc)) {
                .SUCCESS => @intCast(rc),
                .PIPE => error.BrokenPipe,
                else => |e| posix.unexpectedErrno(e),
            };
        },
        .windows => {
            var n: windows.DWORD = 0;
            if (windows.exp.kernel32.WriteFile(
                fd,
                bytes.ptr,
                @intCast(bytes.len),
                &n,
                null,
            ) == windows.FALSE) {
                return switch (windows.GetLastError()) {
                    .BROKEN_PIPE, .NO_DATA => error.BrokenPipe,
                    else => |err| windows.unexpectedError(err),
                };
            }
            return n;
        },
    }
}
