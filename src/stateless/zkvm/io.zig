//! Native zkVM I/O implementation.
//!
//! read_input  — reads all private input bytes from stdin.
//! write_output — writes public output bytes to stdout.
//!
//! Override at build time by injecting a different "zkvm_io" module:
//!
//!   exe.root_module.addImport("zkvm_io", your_module)
//!
//! The replacement module must export:
//!   pub fn read_input(allocator: std.mem.Allocator) ![]const u8 { ... }
//!   pub fn write_output(data: []const u8) void { ... }
//!
//! See zevm-stateless-zisk for an example that uses memory-mapped I/O.

const std = @import("std");

/// Read all private input bytes (stdin in native builds).
pub fn read_input(allocator: std.mem.Allocator) ![]const u8 {
    var list = std.ArrayListUnmanaged(u8).empty;
    errdefer list.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(std.posix.STDIN_FILENO, &chunk);
        if (n == 0) break;
        try list.appendSlice(allocator, chunk[0..n]);
    }
    return list.items;
}

/// Write public output bytes (stdout in native builds).
pub fn write_output(data: []const u8) void {
    var remaining = data;
    while (remaining.len > 0) {
        const n = std.c.write(std.posix.STDOUT_FILENO, remaining.ptr, remaining.len);
        if (n <= 0) break;
        remaining = remaining[@intCast(n)..];
    }
}
