const std = @import("std");

/// Returns the allocator for zevm internal allocations.
///
/// Defaults to std.heap.c_allocator for native builds.
/// Override at build time by injecting a different "zevm_allocator" module
/// via addImport("zevm_allocator", my_module) in your build.zig.
///
/// The replacement module must export:
///   pub fn get() std.mem.Allocator { ... }
pub fn get() std.mem.Allocator {
    return std.heap.c_allocator;
}
