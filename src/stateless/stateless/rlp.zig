//! Binary deserializer for the zevm-zisk RLP StatelessInput format.
//!
//! Binary layout (all integers big-endian):
//!
//!   [u64: block_rlp_len] [block_rlp_bytes]   — raw Ethereum block RLP
//!   ExecutionWitness:
//!     state / codes / keys / headers: u64 count + [u64-len-prefixed byte slices]
//!
//! Returned slices point directly into the caller-owned buffer (zero-copy).

const std = @import("std");
const input_mod = @import("input");
const json_mod = @import("json.zig");

/// Decode a zevm-zisk binary RLP StatelessInput from raw bytes.
pub fn decode(allocator: std.mem.Allocator, data: []const u8) !input_mod.StatelessInput {
    var pos: usize = 0;

    // ── Block RLP ─────────────────────────────────────────────────────────────
    if (pos + 8 > data.len) return error.UnexpectedEndOfInput;
    const rlp_len: usize = @intCast(std.mem.readInt(u64, data[pos..][0..8], .big));
    pos += 8;
    if (pos + rlp_len > data.len) return error.UnexpectedEndOfInput;
    const block_rlp = data[pos..][0..rlp_len];
    pos += rlp_len;

    const blk = try json_mod.parseBlockFromRlp(allocator, block_rlp);

    // ── ExecutionWitness ──────────────────────────────────────────────────────
    const nodes = try readSliceArray(allocator, data, &pos);
    const codes = try readSliceArray(allocator, data, &pos);
    _ = try readSliceArray(allocator, data, &pos); // keys — legacy field, ignored
    const headers = try readSliceArray(allocator, data, &pos);

    return input_mod.StatelessInput{
        .new_payload_request = .{
            .execution_payload = input_mod.payloadFromBlock(blk.header, blk.transactions, blk.withdrawals),
            .parent_beacon_block_root = blk.header.parent_beacon_block_root orelse @splat(0),
        },
        .witness = .{
            .nodes = nodes,
            .codes = codes,
            .headers = headers,
        },
    };
}

/// Read a u64-count array of u64-length-prefixed byte slices (zero-copy into `data`).
fn readSliceArray(allocator: std.mem.Allocator, data: []const u8, pos: *usize) ![]const []const u8 {
    if (pos.* + 8 > data.len) return error.UnexpectedEndOfInput;
    const count: usize = @intCast(std.mem.readInt(u64, data[pos.*..][0..8], .big));
    pos.* += 8;
    const result = try allocator.alloc([]const u8, count);
    for (0..count) |i| {
        if (pos.* + 8 > data.len) return error.UnexpectedEndOfInput;
        const len: usize = @intCast(std.mem.readInt(u64, data[pos.*..][0..8], .big));
        pos.* += 8;
        if (pos.* + len > data.len) return error.UnexpectedEndOfInput;
        result[i] = data[pos.*..][0..len];
        pos.* += len;
    }
    return result;
}
