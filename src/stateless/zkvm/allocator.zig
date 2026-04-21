/// Default allocator for the zevm_stateless main binary.
///
/// Returns std.heap.c_allocator for native builds.
/// Override at build time by injecting a different "main_allocator" module:
///
///   exe.root_module.addImport("main_allocator", your_module)
///
/// The replacement module must export:
///   pub fn get() std.mem.Allocator { ... }
///
/// See zevm-stateless-zisk for an example that injects the Zisk bump allocator.
const std = @import("std");

pub fn get() std.mem.Allocator {
    return std.heap.c_allocator;
}
