/// zkVM I/O Interface
///
/// Conforms to zkvm-standards/standards/io-interface/README.md
///
/// Semantics:
///   read_input  — zero-copy, idempotent; sets pointer to private input buffer.
///                 buf_size == 0 means input is invalid / unavailable.
///   write_output — appends to public output; multiple calls concatenate.
///                  Cannot fail.
///
/// Default implementation reads from ZESU_INPUT env var or stdin, writes to stdout.
/// Override at build time for zkVM targets:
///   exe.root_module.addImport("zkvm_io", your_io_module)
/// The replacement module must export the same two functions.
const std = @import("std");

var input_buf: ?[]const u8 = null;
var input_buf_mutex: std.Thread.Mutex = .{};

/// Read private input.
/// Sets *buf_ptr to the start of the input buffer and *buf_size to its length.
/// Idempotent — calling multiple times returns the same pointer and size.
/// buf_size == 0 means no valid input is available.
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
                buf_ptr.* = @ptrFromInt(1);
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

/// Append bytes to the public output stream.
/// Multiple calls concatenate; the verifier sees the combined output.
pub fn write_output(output: []const u8) void {
    const stdout = std.fs.File{ .handle = 1 };
    stdout.writeAll(output) catch {};
}
