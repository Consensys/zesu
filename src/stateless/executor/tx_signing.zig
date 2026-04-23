/// Transaction hashing, RLP encoding, and sender recovery.
///
/// Handles all per-transaction cryptographic operations:
/// signing hash construction, tx hash computation, sender recovery via
/// secp256k1, and CREATE address derivation.
const std = @import("std");
const primitives = @import("primitives");
const input = @import("executor_types");
const rlp = @import("./rlp_encode.zig");
const accel = @import("accelerators");

// ─── RLP helpers (private) ────────────────────────────────────────────────────

fn rlpAccessList(alloc: std.mem.Allocator, al: []const input.AccessListEntry) ![]u8 {
    var outer_items = std.ArrayListUnmanaged([]const u8).empty;
    defer outer_items.deinit(alloc);

    for (al) |entry| {
        var inner_items = std.ArrayListUnmanaged([]const u8).empty;
        defer inner_items.deinit(alloc);

        try inner_items.append(alloc, try rlp.encodeBytes(alloc, &entry.address));

        var key_items = std.ArrayListUnmanaged([]const u8).empty;
        defer key_items.deinit(alloc);
        for (entry.storage_keys) |key| {
            try key_items.append(alloc, try rlp.encodeBytes(alloc, &key));
        }
        try inner_items.append(alloc, try rlp.encodeList(alloc, key_items.items));
        try outer_items.append(alloc, try rlp.encodeList(alloc, inner_items.items));
    }

    return rlp.encodeList(alloc, outer_items.items);
}

fn rlpBlobVersionedHashes(alloc: std.mem.Allocator, hashes: []const input.Hash) ![]u8 {
    var items = std.ArrayListUnmanaged([]const u8).empty;
    defer items.deinit(alloc);
    for (hashes) |h| try items.append(alloc, try rlp.encodeBytes(alloc, &h));
    return rlp.encodeList(alloc, items.items);
}

/// Encode EIP-7702 authorization list to RLP (full wire form).
fn rlpAuthorizationList(alloc: std.mem.Allocator, auth_list: []const input.AuthorizationItem) ![]u8 {
    var outer = std.ArrayListUnmanaged([]const u8).empty;
    defer outer.deinit(alloc);
    for (auth_list) |item| {
        const items = [_][]const u8{
            try rlp.encodeU256(alloc, item.chain_id),
            try rlp.encodeBytes(alloc, &item.address),
            try rlp.encodeU64(alloc, item.nonce),
            try rlp.encodeU256(alloc, item.y_parity),
            try rlp.encodeU256(alloc, item.r),
            try rlp.encodeU256(alloc, item.s),
        };
        try outer.append(alloc, try rlp.encodeList(alloc, &items));
    }
    return rlp.encodeList(alloc, outer.items);
}

fn rlpTo(alloc: std.mem.Allocator, to: ?input.Address) ![]u8 {
    if (to) |addr| return rlp.encodeBytes(alloc, &addr);
    return rlp.encodeBytes(alloc, &.{});
}

fn signingHash(alloc: std.mem.Allocator, tx: *const input.TxInput, chain_id: u64) ![32]u8 {
    const to_enc = try rlpTo(alloc, tx.to);
    const al_enc = try rlpAccessList(alloc, tx.access_list);

    const payload = switch (tx.type) {
        0 => blk: {
            const tx_chain_id = tx.chain_id orelse chain_id;
            if (tx.protected and tx_chain_id > 0) {
                const items = [_][]const u8{
                    try rlp.encodeU64(alloc, tx.nonce orelse 0),
                    try rlp.encodeU128(alloc, tx.gas_price orelse 0),
                    try rlp.encodeU64(alloc, tx.gas),
                    to_enc,
                    try rlp.encodeU256(alloc, tx.value),
                    try rlp.encodeBytes(alloc, tx.data),
                    try rlp.encodeU64(alloc, tx_chain_id),
                    try rlp.encodeBytes(alloc, &.{}),
                    try rlp.encodeBytes(alloc, &.{}),
                };
                break :blk try rlp.encodeList(alloc, &items);
            } else {
                const items = [_][]const u8{
                    try rlp.encodeU64(alloc, tx.nonce orelse 0),
                    try rlp.encodeU128(alloc, tx.gas_price orelse 0),
                    try rlp.encodeU64(alloc, tx.gas),
                    to_enc,
                    try rlp.encodeU256(alloc, tx.value),
                    try rlp.encodeBytes(alloc, tx.data),
                };
                break :blk try rlp.encodeList(alloc, &items);
            }
        },
        1 => blk: {
            const items = [_][]const u8{
                try rlp.encodeU64(alloc, tx.chain_id orelse chain_id),
                try rlp.encodeU64(alloc, tx.nonce orelse 0),
                try rlp.encodeU128(alloc, tx.gas_price orelse 0),
                try rlp.encodeU64(alloc, tx.gas),
                to_enc,
                try rlp.encodeU256(alloc, tx.value),
                try rlp.encodeBytes(alloc, tx.data),
                al_enc,
            };
            break :blk try rlp.concat(alloc, &.{ &.{0x01}, try rlp.encodeList(alloc, &items) });
        },
        2 => blk: {
            const items = [_][]const u8{
                try rlp.encodeU64(alloc, tx.chain_id orelse chain_id),
                try rlp.encodeU64(alloc, tx.nonce orelse 0),
                try rlp.encodeU128(alloc, tx.max_priority_fee_per_gas orelse 0),
                try rlp.encodeU128(alloc, tx.max_fee_per_gas orelse 0),
                try rlp.encodeU64(alloc, tx.gas),
                to_enc,
                try rlp.encodeU256(alloc, tx.value),
                try rlp.encodeBytes(alloc, tx.data),
                al_enc,
            };
            break :blk try rlp.concat(alloc, &.{ &.{0x02}, try rlp.encodeList(alloc, &items) });
        },
        3 => blk: {
            const bvh_enc = try rlpBlobVersionedHashes(alloc, tx.blob_versioned_hashes);
            const items = [_][]const u8{
                try rlp.encodeU64(alloc, tx.chain_id orelse chain_id),
                try rlp.encodeU64(alloc, tx.nonce orelse 0),
                try rlp.encodeU128(alloc, tx.max_priority_fee_per_gas orelse 0),
                try rlp.encodeU128(alloc, tx.max_fee_per_gas orelse 0),
                try rlp.encodeU64(alloc, tx.gas),
                to_enc,
                try rlp.encodeU256(alloc, tx.value),
                try rlp.encodeBytes(alloc, tx.data),
                al_enc,
                try rlp.encodeU128(alloc, tx.max_fee_per_blob_gas orelse 0),
                bvh_enc,
            };
            break :blk try rlp.concat(alloc, &.{ &.{0x03}, try rlp.encodeList(alloc, &items) });
        },
        4 => blk: {
            const auth_enc = try rlpAuthorizationList(alloc, tx.authorization_list);
            const items = [_][]const u8{
                try rlp.encodeU64(alloc, tx.chain_id orelse chain_id),
                try rlp.encodeU64(alloc, tx.nonce orelse 0),
                try rlp.encodeU128(alloc, tx.max_priority_fee_per_gas orelse 0),
                try rlp.encodeU128(alloc, tx.max_fee_per_gas orelse 0),
                try rlp.encodeU64(alloc, tx.gas),
                to_enc,
                try rlp.encodeU256(alloc, tx.value),
                try rlp.encodeBytes(alloc, tx.data),
                al_enc,
                auth_enc,
            };
            break :blk try rlp.concat(alloc, &.{ &.{0x04}, try rlp.encodeList(alloc, &items) });
        },
        else => return error.UnsupportedTxType,
    };

    return rlp.keccak256(payload);
}

// ─── Public API ───────────────────────────────────────────────────────────────

/// Compute the signing hash for a single EIP-7702 authorization item.
/// hash = keccak256(0x05 || rlp([chain_id, address, nonce]))
pub fn authorizationSigningHash(alloc: std.mem.Allocator, item: *const input.AuthorizationItem) ![32]u8 {
    const fields = [_][]const u8{
        try rlp.encodeU256(alloc, item.chain_id),
        try rlp.encodeBytes(alloc, &item.address),
        try rlp.encodeU64(alloc, item.nonce),
    };
    const payload = try rlp.concat(alloc, &.{ &.{0x05}, try rlp.encodeList(alloc, &fields) });
    return rlp.keccak256(payload);
}

/// Compute the hash of a signed transaction (used as receipt txHash).
pub fn txHash(alloc: std.mem.Allocator, tx: *const input.TxInput, chain_id: u64) ![32]u8 {
    const r = tx.r orelse 0;
    const s = tx.s orelse 0;
    const v = tx.v orelse 0;

    const to_enc = try rlpTo(alloc, tx.to);
    const al_enc = try rlpAccessList(alloc, tx.access_list);

    const payload = switch (tx.type) {
        0 => blk: {
            const items = [_][]const u8{
                try rlp.encodeU64(alloc, tx.nonce orelse 0),
                try rlp.encodeU128(alloc, tx.gas_price orelse 0),
                try rlp.encodeU64(alloc, tx.gas),
                to_enc,
                try rlp.encodeU256(alloc, tx.value),
                try rlp.encodeBytes(alloc, tx.data),
                try rlp.encodeU256(alloc, v),
                try rlp.encodeU256(alloc, r),
                try rlp.encodeU256(alloc, s),
            };
            break :blk try rlp.encodeList(alloc, &items);
        },
        1 => blk: {
            const items = [_][]const u8{
                try rlp.encodeU64(alloc, tx.chain_id orelse chain_id),
                try rlp.encodeU64(alloc, tx.nonce orelse 0),
                try rlp.encodeU128(alloc, tx.gas_price orelse 0),
                try rlp.encodeU64(alloc, tx.gas),
                to_enc,
                try rlp.encodeU256(alloc, tx.value),
                try rlp.encodeBytes(alloc, tx.data),
                al_enc,
                try rlp.encodeU256(alloc, v),
                try rlp.encodeU256(alloc, r),
                try rlp.encodeU256(alloc, s),
            };
            break :blk try rlp.concat(alloc, &.{ &.{0x01}, try rlp.encodeList(alloc, &items) });
        },
        2 => blk: {
            const items = [_][]const u8{
                try rlp.encodeU64(alloc, tx.chain_id orelse chain_id),
                try rlp.encodeU64(alloc, tx.nonce orelse 0),
                try rlp.encodeU128(alloc, tx.max_priority_fee_per_gas orelse 0),
                try rlp.encodeU128(alloc, tx.max_fee_per_gas orelse 0),
                try rlp.encodeU64(alloc, tx.gas),
                to_enc,
                try rlp.encodeU256(alloc, tx.value),
                try rlp.encodeBytes(alloc, tx.data),
                al_enc,
                try rlp.encodeU256(alloc, v),
                try rlp.encodeU256(alloc, r),
                try rlp.encodeU256(alloc, s),
            };
            break :blk try rlp.concat(alloc, &.{ &.{0x02}, try rlp.encodeList(alloc, &items) });
        },
        3 => blk: {
            const bvh_enc = try rlpBlobVersionedHashes(alloc, tx.blob_versioned_hashes);
            const items = [_][]const u8{
                try rlp.encodeU64(alloc, tx.chain_id orelse chain_id),
                try rlp.encodeU64(alloc, tx.nonce orelse 0),
                try rlp.encodeU128(alloc, tx.max_priority_fee_per_gas orelse 0),
                try rlp.encodeU128(alloc, tx.max_fee_per_gas orelse 0),
                try rlp.encodeU64(alloc, tx.gas),
                to_enc,
                try rlp.encodeU256(alloc, tx.value),
                try rlp.encodeBytes(alloc, tx.data),
                al_enc,
                try rlp.encodeU128(alloc, tx.max_fee_per_blob_gas orelse 0),
                bvh_enc,
                try rlp.encodeU256(alloc, v),
                try rlp.encodeU256(alloc, r),
                try rlp.encodeU256(alloc, s),
            };
            break :blk try rlp.concat(alloc, &.{ &.{0x03}, try rlp.encodeList(alloc, &items) });
        },
        4 => blk: {
            const auth_enc = try rlpAuthorizationList(alloc, tx.authorization_list);
            const items = [_][]const u8{
                try rlp.encodeU64(alloc, tx.chain_id orelse chain_id),
                try rlp.encodeU64(alloc, tx.nonce orelse 0),
                try rlp.encodeU128(alloc, tx.max_priority_fee_per_gas orelse 0),
                try rlp.encodeU128(alloc, tx.max_fee_per_gas orelse 0),
                try rlp.encodeU64(alloc, tx.gas),
                to_enc,
                try rlp.encodeU256(alloc, tx.value),
                try rlp.encodeBytes(alloc, tx.data),
                al_enc,
                auth_enc,
                try rlp.encodeU256(alloc, v),
                try rlp.encodeU256(alloc, r),
                try rlp.encodeU256(alloc, s),
            };
            break :blk try rlp.concat(alloc, &.{ &.{0x04}, try rlp.encodeList(alloc, &items) });
        },
        else => return error.UnsupportedTxType,
    };

    return rlp.keccak256(payload);
}

/// Recover the sender address from a signed transaction.
/// Returns null if the signature is invalid or missing.
pub fn recoverSender(alloc: std.mem.Allocator, tx: *const input.TxInput, chain_id: u64) !?input.Address {
    const r = tx.r orelse return null;
    const s = tx.s orelse return null;
    const v_val = tx.v orelse return null;

    if (r == 0 and s == 0) return null;

    const hash = try signingHash(alloc, tx, chain_id);

    const recid: u8 = switch (tx.type) {
        0 => blk: {
            const cid: u64 = tx.chain_id orelse chain_id;
            const chain_v: u256 = 2 * @as(u256, cid) + 35;
            if (v_val >= chain_v and v_val <= chain_v + 1) {
                break :blk @intCast(v_val - chain_v);
            } else if (v_val == 27 or v_val == 28) {
                break :blk @intCast(v_val - 27);
            } else {
                return null;
            }
        },
        else => blk: {
            if (v_val > 1) return null;
            break :blk @intCast(v_val);
        },
    };

    var sig: [64]u8 = undefined;
    var r_buf: [32]u8 = undefined;
    var s_buf: [32]u8 = undefined;
    std.mem.writeInt(u256, &r_buf, r, .big);
    std.mem.writeInt(u256, &s_buf, s, .big);
    @memcpy(sig[0..32], &r_buf);
    @memcpy(sig[32..64], &s_buf);

    var pubkey: [64]u8 = undefined;
    if (!accel.ecrecover(&hash, &sig, recid, &pubkey)) return null;
    var keccak_hash: [32]u8 = undefined;
    accel.keccak256(&pubkey, &keccak_hash);
    var address: [20]u8 = undefined;
    @memcpy(&address, keccak_hash[12..32]);
    return address;
}

/// Compute CREATE address: keccak256(RLP([sender, nonce]))[12:]
pub fn createAddress(alloc: std.mem.Allocator, sender: input.Address, nonce: u64) !input.Address {
    const items = [_][]const u8{
        try rlp.encodeBytes(alloc, &sender),
        try rlp.encodeU64(alloc, nonce),
    };
    const encoded = try rlp.encodeList(alloc, &items);
    const hash = rlp.keccak256(encoded);
    var addr: input.Address = undefined;
    @memcpy(&addr, hash[12..32]);
    return addr;
}
