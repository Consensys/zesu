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
var input_buf_mutex: std.Thread.Mutex = .{};

pub fn read_input(buf_ptr: *[*]const u8, buf_size: *usize) void {
    input_buf_mutex.lock();
    defer input_buf_mutex.unlock();

    if (input_buf) |buf| {
        buf_ptr.* = buf.ptr;
        buf_size.* = buf.len;
        return;
    }

    const allocator = std.heap.c_allocator;
    const data = blk: {
        if (std.posix.getenv("ZESU_INPUT")) |path| {
            const file = std.fs.cwd().openFile(path, .{}) catch {
                buf_ptr.* = @ptrFromInt(1); // non-null sentinel
                buf_size.* = 0;
                return;
            };
            defer file.close();
            break :blk file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch {
                buf_ptr.* = @ptrFromInt(1);
                buf_size.* = 0;
                return;
            };
        } else {
            const stdin_file = std.fs.File{ .handle = 0 };
            break :blk stdin_file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch {
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

pub fn write_output(output: []const u8) void {
    const stdout = std.fs.File{ .handle = 1 };
    stdout.writeAll(output) catch {};
}
