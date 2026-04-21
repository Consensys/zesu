/// Default (host) I/O implementation.
///
/// read_input:  reads from a file path provided via the ZESU_INPUT env var,
///              or from stdin if unset.  Entire input is read on first call
///              and cached (idempotent).
///
/// write_output: writes to stdout.
///
/// For zkVM targets, replace this module with an implementation that reads
/// from the zkVM's memory-mapped input region and writes to its output region.
const std = @import("std");

// Cached input buffer — allocated once on first read_input call.
var input_buf: ?[]const u8 = null;

pub fn read_input(buf_ptr: *[*]const u8, buf_size: *usize) void {
    if (input_buf) |buf| {
        buf_ptr.* = buf.ptr;
        buf_size.* = buf.len;
        return;
    }

    const allocator = std.heap.c_allocator;
    const data: []u8 = blk: {
        if (std.c.getenv("ZESU_INPUT")) |path_z| {
            const fd = std.posix.openatZ(
                std.posix.AT.FDCWD,
                path_z,
                .{},
                0,
            ) catch {
                buf_ptr.* = @ptrFromInt(1);
                buf_size.* = 0;
                return;
            };
            defer _ = std.c.close(fd);
            break :blk readFd(allocator, fd) catch {
                buf_ptr.* = @ptrFromInt(1);
                buf_size.* = 0;
                return;
            };
        } else {
            break :blk readFd(allocator, std.posix.STDIN_FILENO) catch {
                buf_ptr.* = @ptrFromInt(1);
                buf_size.* = 0;
                return;
            };
        }
    };

    input_buf = data;
    buf_ptr.* = data.ptr;
    buf_size.* = data.len;
}

fn readFd(allocator: std.mem.Allocator, fd: std.posix.fd_t) ![]u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(fd, &chunk);
        if (n == 0) break;
        try list.appendSlice(allocator, chunk[0..n]);
    }
    return list.items;
}

pub fn write_output(output: []const u8) void {
    var remaining = output;
    while (remaining.len > 0) {
        const n = std.c.write(std.posix.STDOUT_FILENO, remaining.ptr, remaining.len);
        if (n <= 0) break;
        remaining = remaining[@intCast(n)..];
    }
}
