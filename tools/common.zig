const std = @import("std");

/// Minimal anytype-writer wrapper backed by an ArrayListUnmanaged(u8).
pub const ListWriter = struct {
    list: *std.ArrayListUnmanaged(u8),
    alloc: std.mem.Allocator,
    pub const Error = std.mem.Allocator.Error;
    pub fn writeAll(self: @This(), bytes: []const u8) Error!void {
        return self.list.appendSlice(self.alloc, bytes);
    }
    pub fn print(self: @This(), comptime fmt: []const u8, args: anytype) Error!void {
        return self.list.print(self.alloc, fmt, args);
    }
    pub fn writeByte(self: @This(), byte: u8) Error!void {
        return self.list.append(self.alloc, byte);
    }
};
