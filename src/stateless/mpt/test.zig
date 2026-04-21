//! Integration tests for MPT proof verification.
//!
//! Test vectors are built synthetically using the same RLP rules that the
//! verifier decodes.  The flat node pool replaces the old ordered-proof-array:
//! just put the node(s) in a slice and the verifier finds them by hash.

const std = @import("std");
const primitives = @import("primitives");
const mpt = @import("mpt");
const input = @import("input");

// ─── Known constants ───────────────────────────────────────────────────────────

const KECCAK_EMPTY: primitives.Hash = .{
    0xc5, 0xd2, 0x46, 0x01, 0x86, 0xf7, 0x23, 0x3c,
    0x92, 0x7e, 0x7d, 0xb2, 0xdc, 0xc7, 0x03, 0xc0,
    0xe5, 0x00, 0xb6, 0x53, 0xca, 0x82, 0x27, 0x3b,
    0x7b, 0xfa, 0xd8, 0x04, 0x5d, 0x85, 0xa4, 0x70,
};

const EMPTY_TRIE_HASH: primitives.Hash = .{
    0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
    0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
    0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
    0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
};

// ─── Minimal RLP encoder (test-local, allocation-free) ────────────────────────

fn encBytes(buf: []u8, off: usize, data: []const u8) usize {
    var o = off;
    if (data.len == 0) {
        buf[o] = 0x80;
        return o + 1;
    } else if (data.len == 1 and data[0] <= 0x7f) {
        buf[o] = data[0];
        return o + 1;
    } else if (data.len <= 55) {
        buf[o] = @intCast(0x80 + data.len);
        o += 1;
        @memcpy(buf[o..][0..data.len], data);
        return o + data.len;
    } else {
        std.debug.assert(data.len <= 255);
        buf[o] = 0xb8;
        buf[o + 1] = @intCast(data.len);
        o += 2;
        @memcpy(buf[o..][0..data.len], data);
        return o + data.len;
    }
}

fn encList(buf: []u8, off: usize, payload: []const u8) usize {
    var o = off;
    if (payload.len <= 55) {
        buf[o] = @intCast(0xc0 + payload.len);
        o += 1;
    } else {
        std.debug.assert(payload.len <= 255);
        buf[o] = 0xf8;
        buf[o + 1] = @intCast(payload.len);
        o += 2;
    }
    @memcpy(buf[o..][0..payload.len], payload);
    return o + payload.len;
}

fn buildAccountRlp(
    buf: []u8,
    nonce: u64,
    balance: u256,
    storage_root: primitives.Hash,
    code_hash: primitives.Hash,
) usize {
    var payload: [200]u8 = undefined;
    var pl: usize = 0;
    if (nonce == 0) {
        payload[pl] = 0x80;
        pl += 1;
    } else {
        var tmp: [8]u8 = undefined;
        var n = nonce;
        var nb: usize = 0;
        while (n > 0) : (nb += 1) {
            tmp[7 - nb] = @intCast(n & 0xff);
            n >>= 8;
        }
        pl = encBytes(&payload, pl, tmp[8 - nb ..]);
    }
    if (balance == 0) {
        payload[pl] = 0x80;
        pl += 1;
    } else {
        var tmp: [32]u8 = undefined;
        var b = balance;
        var nb: usize = 0;
        while (b > 0) : (nb += 1) {
            tmp[31 - nb] = @intCast(b & 0xff);
            b >>= 8;
        }
        pl = encBytes(&payload, pl, tmp[32 - nb ..]);
    }
    payload[pl] = 0xa0;
    pl += 1;
    @memcpy(payload[pl..][0..32], &storage_root);
    pl += 32;
    payload[pl] = 0xa0;
    pl += 1;
    @memcpy(payload[pl..][0..32], &code_hash);
    pl += 32;
    return encList(buf, 0, payload[0..pl]);
}

fn buildLeafNode(buf: []u8, key_hash: primitives.Hash, value: []const u8) usize {
    var hp_key: [33]u8 = undefined;
    hp_key[0] = 0x20;
    @memcpy(hp_key[1..33], &key_hash);
    var payload: [512]u8 = undefined;
    var pl: usize = 0;
    pl = encBytes(&payload, pl, &hp_key);
    pl = encBytes(&payload, pl, value);
    return encList(buf, 0, payload[0..pl]);
}

fn buildEmptyBranchNode(buf: []u8) usize {
    buf[0] = 0xd1;
    @memset(buf[1..18], 0x80);
    return 18;
}

// ─── Test 1: account inclusion — single-leaf pool ─────────────────────────────

test "verifyAccount inclusion — single-leaf pool" {
    var address: primitives.Address = @splat(0x00);
    address[19] = 0x02;
    const key_hash = mpt.keccak256(&address);

    var account_rlp: [200]u8 = undefined;
    const account_len = buildAccountRlp(&account_rlp, 5, 1000, EMPTY_TRIE_HASH, KECCAK_EMPTY);

    var leaf_node: [512]u8 = undefined;
    const leaf_len = buildLeafNode(&leaf_node, key_hash, account_rlp[0..account_len]);
    const leaf_bytes = leaf_node[0..leaf_len];
    const root = mpt.keccak256(leaf_bytes);

    // Pool contains just the one leaf node.
    const pool = &[_][]const u8{leaf_bytes};
    const result = try mpt.verifyAccount(root, address, pool);

    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u64, 5), result.?.nonce);
    try std.testing.expectEqual(@as(u256, 1000), result.?.balance);
    try std.testing.expectEqualSlices(u8, &KECCAK_EMPTY, &result.?.code_hash);
}

// ─── Test 2: storage inclusion — single-leaf pool ─────────────────────────────

test "verifyStorage inclusion — single-leaf pool" {
    var slot: primitives.Hash = @splat(0x00);
    slot[31] = 0x01;
    const key_hash = mpt.keccak256(&slot);

    const rlp_value = &[_]u8{ 0x84, 0xde, 0xad, 0xbe, 0xef };

    var leaf_node: [256]u8 = undefined;
    const leaf_len = buildLeafNode(&leaf_node, key_hash, rlp_value);
    const leaf_bytes = leaf_node[0..leaf_len];
    const storage_root = mpt.keccak256(leaf_bytes);

    const pool = &[_][]const u8{leaf_bytes};
    const value = try mpt.verifyStorage(storage_root, slot, pool);
    try std.testing.expectEqual(@as(u256, 0xdeadbeef), value);
}

// ─── Test 3: account non-inclusion — empty branch root ────────────────────────

test "verifyAccount non-inclusion — empty branch root" {
    var branch: [18]u8 = undefined;
    const branch_len = buildEmptyBranchNode(&branch);
    const root = mpt.keccak256(branch[0..branch_len]);

    var address: primitives.Address = @splat(0x00);
    address[0] = 0xab;

    const pool = &[_][]const u8{branch[0..branch_len]};
    const result = try mpt.verifyAccount(root, address, pool);
    try std.testing.expect(result == null);
}

// ─── Test 4: storage non-inclusion — empty branch root ────────────────────────

test "verifyStorage non-inclusion — empty branch root" {
    var branch: [18]u8 = undefined;
    const branch_len = buildEmptyBranchNode(&branch);
    const storage_root = mpt.keccak256(branch[0..branch_len]);

    var slot: primitives.Hash = @splat(0x00);
    slot[31] = 0x99;

    const pool = &[_][]const u8{branch[0..branch_len]};
    const value = try mpt.verifyStorage(storage_root, slot, pool);
    try std.testing.expectEqual(@as(u256, 0), value);
}

// ─── Test 5: tampered node — InvalidProof ─────────────────────────────────────

test "verifyProof tampered node — returns InvalidProof" {
    var slot: primitives.Hash = @splat(0x00);
    slot[31] = 0x07;
    const key_hash = mpt.keccak256(&slot);

    var leaf_node: [256]u8 = undefined;
    const leaf_len = buildLeafNode(&leaf_node, key_hash, &[_]u8{0x01});
    const root = mpt.keccak256(leaf_node[0..leaf_len]);

    // Corrupt one byte — keccak256 of the tampered node won't match root.
    var tampered: [256]u8 = undefined;
    @memcpy(tampered[0..leaf_len], leaf_node[0..leaf_len]);
    tampered[leaf_len / 2] ^= 0xff;

    const pool = &[_][]const u8{tampered[0..leaf_len]};
    const result = mpt.verifyProof(root, key_hash, pool);
    try std.testing.expectError(error.InvalidProof, result);
}

// ─── Test 6: verifyWitness with flat pool ─────────────────────────────────────

test "verifyWitness — single account in pool" {
    var address: primitives.Address = @splat(0x00);
    address[19] = 0x03;
    const key_hash = mpt.keccak256(&address);

    var account_rlp: [200]u8 = undefined;
    const account_len = buildAccountRlp(&account_rlp, 0, 0, EMPTY_TRIE_HASH, KECCAK_EMPTY);

    var leaf_node: [512]u8 = undefined;
    const leaf_len = buildLeafNode(&leaf_node, key_hash, account_rlp[0..account_len]);
    const leaf_bytes = leaf_node[0..leaf_len];
    const state_root = mpt.keccak256(leaf_bytes);

    const w = input.StateWitness{
        .state_root = state_root,
        .nodes = &[_][]const u8{leaf_bytes},
        .codes = &.{},
        .keys = &[_][]const u8{&address},
        .headers = &.{},
    };
    const proven_root = try mpt.verifyWitness(w);
    try std.testing.expectEqualSlices(u8, &state_root, &proven_root);
}
