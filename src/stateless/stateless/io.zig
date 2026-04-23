//! Input loaders for zevm_stateless: RLP (zkVM / file) and SSZ (file / stream).

const std = @import("std");
const input_mod = @import("input");
const rlp = @import("rlp.zig");
const ssz = @import("ssz.zig");
const zkvm_io = @import("zkvm_io");

/// RLP from zkvm_io.read_input() — default / zkVM production path.
pub fn fromRlpStream(allocator: std.mem.Allocator) !input_mod.StatelessInput {
    var buf_ptr: [*]const u8 = undefined;
    var buf_size: usize = 0;
    zkvm_io.read_input(&buf_ptr, &buf_size);
    const data = buf_ptr[0..buf_size];
    return rlp.decode(allocator, data);
}

/// RLP from a binary file — testing convenience.
pub fn fromRlpFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !input_mod.StatelessInput {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 << 20));
    return rlp.decode(allocator, data);
}

/// SSZ from zkvm_io.read_input().
pub fn fromSszStream(allocator: std.mem.Allocator) !input_mod.StatelessInput {
    var buf_ptr: [*]const u8 = undefined;
    var buf_size: usize = 0;
    zkvm_io.read_input(&buf_ptr, &buf_size);
    const data = buf_ptr[0..buf_size];
    return ssz.decode(allocator, data);
}

/// SSZ from a binary file.
pub fn fromSszFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !input_mod.StatelessInput {
    const data = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1 << 30));
    return ssz.decode(allocator, data);
}
