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
    const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
    var list = std.ArrayListUnmanaged(u8){};
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = try stdin.read(&chunk);
        if (n == 0) break;
        try list.appendSlice(allocator, chunk[0..n]);
    }
    return list.items;
}

/// Write public output bytes (stdout in native builds).
pub fn write_output(data: []const u8) void {
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    stdout.writeAll(data) catch {};
}
