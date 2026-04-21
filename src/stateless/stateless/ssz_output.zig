//! SSZ serialization for SszStatelessValidationResult (Amsterdam spec output).
//!
//! Output layout (41 bytes, all fixed-size fields):
//!   [0..32]  new_payload_request_root  Bytes32   SSZ hash_tree_root of SszNewPayloadRequest
//!   [32]     successful_validation     boolean   0x01 = valid
//!   [33..41] chain_config.chain_id     uint64 LE
//!
//! SszStatelessValidationResult schema (stateless_ssz.py):
//!   new_payload_request_root: Bytes32
//!   successful_validation:    boolean
//!   chain_config:             SszChainConfig { chain_id: uint64 }

const std = @import("std");
const input = @import("input");

// ── SHA-256 ───────────────────────────────────────────────────────────────────

fn sha2(a: [32]u8, b: [32]u8) [32]u8 {
    var buf: [64]u8 = undefined;
    @memcpy(buf[0..32], &a);
    @memcpy(buf[32..64], &b);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&buf, &out, .{});
    return out;
}

fn sha2Bytes(data: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &out, .{});
    return out;
}

// ── Zero hash tree ────────────────────────────────────────────────────────────

/// z[k] = sha256(z[k-1] || z[k-1]), z[0] = 0x00*32.
/// Depth up to 25 covers all Amsterdam SSZ list limits.
fn zeroHash(depth: u8) [32]u8 {
    var h: [32]u8 = [_]u8{0} ** 32;
    var i: u8 = 0;
    while (i < depth) : (i += 1) h = sha2(h, h);
    return h;
}

// ── mix_in_length ─────────────────────────────────────────────────────────────

/// SSZ: hash_tree_root(list) = sha256(merkle_root || uint256_le(length))
fn mixInLength(root: [32]u8, length: u64) [32]u8 {
    var buf: [64]u8 = [_]u8{0} ** 64;
    @memcpy(buf[0..32], &root);
    std.mem.writeInt(u64, buf[32..40], length, .little);
    return sha2Bytes(&buf);
}

// ── Sparse Merkle tree ────────────────────────────────────────────────────────

/// Compute the Merkle root of `2^depth` virtual leaves where:
///   leaves[0..len] are the actual values
///   leaves[len..2^depth] are all zero chunks.
///
/// Uses precomputed zero subtree hashes for efficiency — O(len * depth) time.
fn sparseRoot(leaves: []const [32]u8, depth: u8) [32]u8 {
    if (depth == 0) {
        return if (leaves.len >= 1) leaves[0] else [_]u8{0} ** 32;
    }
    const half: usize = @as(usize, 1) << @intCast(depth - 1);
    const left_leaves = if (leaves.len > half) leaves[0..half] else leaves;
    const right_leaves = if (leaves.len > half) leaves[half..] else &[_][32]u8{};
    const left = sparseRoot(left_leaves, depth - 1);
    const right = if (leaves.len <= half) zeroHash(depth - 1) else sparseRoot(right_leaves, depth - 1);
    return sha2(left, right);
}

/// Merkleize exactly N chunks (N must be a power of two).
fn merkleizeExact(chunks: []const [32]u8) [32]u8 {
    std.debug.assert(chunks.len > 0);
    var n = chunks.len;
    // Must be power of 2 — caller is responsible
    while (n > 1) : (n /= 2) {}
    std.debug.assert(n == 1); // assert power of 2

    if (chunks.len == 1) return chunks[0];
    // Use simple in-place reduction on a stack buffer for small sizes (≤ 32).
    // Caller uses small fixed sizes (4, 8, 32) for container fields.
    var buf: [32][32]u8 = undefined;
    @memcpy(buf[0..chunks.len], chunks);
    var len = chunks.len;
    while (len > 1) {
        const half = len / 2;
        for (0..half) |i| buf[i] = sha2(buf[2 * i], buf[2 * i + 1]);
        len = half;
    }
    return buf[0];
}

// ── Primitive hash_tree_root helpers ─────────────────────────────────────────

fn htU64(v: u64) [32]u8 {
    var out: [32]u8 = [_]u8{0} ** 32;
    std.mem.writeInt(u64, out[0..8], v, .little);
    return out;
}

/// uint256 stored as u64 (high bytes are zero) — same encoding as htU64.
fn htU256AsU64(v: u64) [32]u8 {
    return htU64(v);
}

fn htBytes32(b: [32]u8) [32]u8 {
    return b;
}

fn htBytes20(b: [20]u8) [32]u8 {
    var out: [32]u8 = [_]u8{0} ** 32;
    @memcpy(out[0..20], &b);
    return out;
}

/// ByteVector[256]: merkleize 8 chunks of 32 bytes.
fn htBytes256(b: [256]u8) [32]u8 {
    var chunks: [8][32]u8 = undefined;
    for (0..8) |i| @memcpy(&chunks[i], b[i * 32 ..][0..32]);
    return merkleizeExact(&chunks);
}

/// ByteList[32]: max 32 bytes → 1 chunk limit.
fn htByteList32(data: []const u8) [32]u8 {
    var chunk: [32]u8 = [_]u8{0} ** 32;
    const n = @min(data.len, 32);
    @memcpy(chunk[0..n], data[0..n]);
    // merkleize([chunk], limit=1) = chunk (single chunk, no reduction needed)
    return mixInLength(chunk, data.len);
}

/// ByteList[2^24]: block_access_list.
/// limit = 2^24 bytes → ceil(2^24/32) = 2^19 chunk limit → depth 19.
/// TODO: replace with allocator-backed version for large access lists.
fn htByteList2_24(data: []const u8) [32]u8 {
    const chunk_limit_depth = 19;
    if (data.len == 0) return mixInLength(zeroHash(chunk_limit_depth), 0);
    const nchunks = (data.len + 31) / 32;
    if (nchunks <= 32) {
        var leaf_buf: [32][32]u8 = undefined;
        for (0..nchunks) |i| {
            leaf_buf[i] = [_]u8{0} ** 32;
            const start = i * 32;
            const end = @min(start + 32, data.len);
            @memcpy(leaf_buf[i][0 .. end - start], data[start..end]);
        }
        const root = sparseRoot(leaf_buf[0..nchunks], chunk_limit_depth);
        return mixInLength(root, data.len);
    } else {
        const root = sparseRootFromBytes(data, chunk_limit_depth);
        return mixInLength(root, data.len);
    }
}

/// ByteList[2^30]: one raw transaction.
/// limit = 2^30 bytes → 2^25 chunk limit → depth 25.
fn htByteList2_30(tx_bytes: []const u8) [32]u8 {
    const chunk_limit_depth = 25;
    if (tx_bytes.len == 0) return mixInLength(zeroHash(chunk_limit_depth), 0);

    const nchunks = (tx_bytes.len + 31) / 32;
    var leaf_buf: [32][32]u8 = undefined; // max 1MB tx → way more than 32 chunks
    // For large txs, allocate dynamically. For typical txs (< 1KB), nchunks ≤ 32.
    if (nchunks <= 32) {
        for (0..nchunks) |i| {
            leaf_buf[i] = [_]u8{0} ** 32;
            const start = i * 32;
            const end = @min(start + 32, tx_bytes.len);
            @memcpy(leaf_buf[i][0 .. end - start], tx_bytes[start..end]);
        }
        const root = sparseRoot(leaf_buf[0..nchunks], chunk_limit_depth);
        return mixInLength(root, tx_bytes.len);
    } else {
        // Large tx: fall back to iterative chunking
        // (rare in practice; use a heap-less approximation: treat as the hashed identity of the bytes)
        // TODO: handle very large transactions via allocator
        // For now, compute chunks via a running hash tree
        const root = sparseRootFromBytes(tx_bytes, chunk_limit_depth);
        return mixInLength(root, tx_bytes.len);
    }
}

/// Compute sparseRoot from a byte slice, packing into 32-byte chunks.
/// Used for large transactions that don't fit in a fixed-size stack buffer.
fn sparseRootFromBytes(data: []const u8, depth: u8) [32]u8 {
    if (data.len == 0) return zeroHash(depth);

    // Build a virtual sparse tree where leaves are packed 32-byte chunks.
    // We do a single pass, building the tree bottom-up using a stack of partial roots.
    // For each chunk position, fold it into the running tree.
    const nchunks = (data.len + 31) / 32;

    // Use a persistent array of 64 "running partial roots" (one per tree level).
    // Inspired by Merkle single-pass streaming.
    var stack: [26][32]u8 = undefined;
    var stack_filled: [26]bool = [_]bool{false} ** 26;

    for (0..nchunks) |i| {
        var chunk: [32]u8 = [_]u8{0} ** 32;
        const start = i * 32;
        const end = @min(start + 32, data.len);
        @memcpy(chunk[0 .. end - start], data[start..end]);

        var node = chunk;
        var level: u8 = 0;
        while (stack_filled[level]) : (level += 1) {
            node = sha2(stack[level], node);
            stack_filled[level] = false;
        }
        stack[level] = node;
        stack_filled[level] = true;
    }

    // Fold remaining stack entries up to `depth`.
    // Track result_height so we pad with the correct zero-subtree size before
    // combining with a higher-level stack entry.
    var result: [32]u8 = [_]u8{0} ** 32;
    var found = false;
    var result_height: u8 = 0;
    for (0..@as(usize, depth) + 1) |lv| {
        const level: u8 = @intCast(lv);
        if (stack_filled[level]) {
            if (!found) {
                result = stack[level];
                result_height = level;
                found = true;
            } else {
                // Pad result up to height `level` before combining.
                while (result_height < level) : (result_height += 1) {
                    result = sha2(result, zeroHash(result_height));
                }
                result = sha2(stack[level], result);
                result_height = level + 1;
            }
        } else if (found and result_height < depth) {
            result = sha2(result, zeroHash(result_height));
            result_height += 1;
        }
    }

    return if (found) result else zeroHash(depth);
}

// ── SszWithdrawal hash_tree_root ──────────────────────────────────────────────

fn htWithdrawal(w: input.Withdrawal) [32]u8 {
    // SszWithdrawal: 4 fields → merkleize 4 chunks (power of 2, no padding)
    //   index: uint64, validator_index: uint64, address: ByteVector[20], amount: uint256
    const chunks: [4][32]u8 = .{
        htU64(w.index),
        htU64(w.validator_index),
        htBytes20(w.address),
        htU256AsU64(w.amount), // amount is gwei, fits in u64
    };
    return merkleizeExact(&chunks);
}

// ── SszExecutionPayload hash_tree_root ────────────────────────────────────────

fn htExecutionPayload(alloc: std.mem.Allocator, ep: input.ExecutionPayload) !([32]u8) {
    // 19 fields → pad to 32 (next power of 2), 13 zero chunks appended.
    var chunks: [32][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** 32;

    // f0..f5: simple fixed fields
    chunks[0] = htBytes32(ep.parent_hash);
    chunks[1] = htBytes20(ep.fee_recipient);
    chunks[2] = htBytes32(ep.state_root);
    chunks[3] = htBytes32(ep.receipts_root);
    chunks[4] = htBytes256(ep.logs_bloom);
    chunks[5] = htBytes32(ep.prev_randao);

    // f6..f9: uint64 fields
    chunks[6] = htU64(ep.block_number);
    chunks[7] = htU64(ep.gas_limit);
    chunks[8] = htU64(ep.gas_used);
    chunks[9] = htU64(ep.timestamp);

    // f10: extra_data: ByteList[32]
    chunks[10] = htByteList32(ep.extra_data);

    // f11: base_fee_per_gas: uint256 (stored as u64, high bytes = 0)
    chunks[11] = htU256AsU64(ep.base_fee_per_gas);

    // f12: block_hash: Bytes32
    chunks[12] = htBytes32(ep.block_hash);

    // f13: transactions: List[ByteList[2^30], 2^20]
    chunks[13] = try htTransactionList(alloc, ep.raw_transactions);

    // f14: withdrawals: List[SszWithdrawal, 2^16]
    chunks[14] = try htWithdrawalList(alloc, ep.withdrawals);

    // f15..f16: blob gas fields
    chunks[15] = htU64(ep.blob_gas_used);
    chunks[16] = htU64(ep.excess_blob_gas);

    // f17: block_access_list: ByteList[2^24]
    chunks[17] = htByteList2_24(ep.block_access_list);

    // f18: slot_number: uint64
    chunks[18] = htU64(ep.slot_number orelse 0);

    // f19..f31: zero (already zero-initialized above)

    return merkleizeExact(&chunks);
}

fn htTransactionList(alloc: std.mem.Allocator, raw_txs: []const []const u8) !([32]u8) {
    // List[ByteList[2^30], 2^20]: each tx is a ByteList, list limit = 2^20.
    // Depth for the list = 20.
    const list_depth = 20;

    if (raw_txs.len == 0) return mixInLength(zeroHash(list_depth), 0);

    const tx_roots = try alloc.alloc([32]u8, raw_txs.len);
    defer alloc.free(tx_roots);
    for (raw_txs, 0..) |tx, i| tx_roots[i] = htByteList2_30(tx);

    const root = sparseRoot(tx_roots, list_depth);
    return mixInLength(root, raw_txs.len);
}

fn htWithdrawalList(alloc: std.mem.Allocator, withdrawals: []const input.Withdrawal) !([32]u8) {
    // List[SszWithdrawal, 2^16]: list limit = 2^16, depth = 16.
    const list_depth = 16;

    if (withdrawals.len == 0) return mixInLength(zeroHash(list_depth), 0);

    const roots = try alloc.alloc([32]u8, withdrawals.len);
    defer alloc.free(roots);
    for (withdrawals, 0..) |w, i| roots[i] = htWithdrawal(w);

    const root = sparseRoot(roots, list_depth);
    return mixInLength(root, withdrawals.len);
}

// ── SszNewPayloadRequest hash_tree_root ───────────────────────────────────────

/// hash_tree_root for List[Bytes32, 4096] (versioned_hashes).
/// limit = 4096 → depth 12. Elements are already 32-byte chunks.
fn htVersionedHashes(hashes: []const [32]u8) [32]u8 {
    const list_depth = 12;
    if (hashes.len == 0) return mixInLength(zeroHash(list_depth), 0);
    const root = sparseRoot(hashes, list_depth);
    return mixInLength(root, hashes.len);
}

/// ByteList[2^20]: one execution request entry.
/// limit = 2^20 bytes → ceil(2^20/32) = 2^15 chunk limit → depth 15.
fn htByteList2_20(data: []const u8) [32]u8 {
    const chunk_limit_depth = 15;
    if (data.len == 0) return mixInLength(zeroHash(chunk_limit_depth), 0);
    const nchunks = (data.len + 31) / 32;
    if (nchunks <= 32) {
        var leaf_buf: [32][32]u8 = undefined;
        for (0..nchunks) |i| {
            leaf_buf[i] = [_]u8{0} ** 32;
            const start = i * 32;
            const end = @min(start + 32, data.len);
            @memcpy(leaf_buf[i][0 .. end - start], data[start..end]);
        }
        const root = sparseRoot(leaf_buf[0..nchunks], chunk_limit_depth);
        return mixInLength(root, data.len);
    } else {
        const root = sparseRootFromBytes(data, chunk_limit_depth);
        return mixInLength(root, data.len);
    }
}

/// hash_tree_root for List[ByteList[2^20], 16] (execution_requests).
/// limit = 16 → depth 4.
fn htExecutionRequests(alloc: std.mem.Allocator, requests: []const []const u8) ![32]u8 {
    const list_depth = 4;
    if (requests.len == 0) return mixInLength(zeroHash(list_depth), 0);
    const roots = try alloc.alloc([32]u8, requests.len);
    defer alloc.free(roots);
    for (requests, 0..) |req_bytes, i| roots[i] = htByteList2_20(req_bytes);
    const root = sparseRoot(roots, list_depth);
    return mixInLength(root, requests.len);
}

/// Compute the SSZ hash_tree_root of SszNewPayloadRequest.
/// This is the `new_payload_request_root` field in the output.
///
/// SszNewPayloadRequest has 4 fields (already power of 2):
///   execution_payload:        SszExecutionPayload
///   versioned_hashes:         List[Bytes32, 4096]
///   parent_beacon_block_root: Bytes32
///   execution_requests:       List[ByteList[2^20], 16]
pub fn newPayloadRequestRoot(alloc: std.mem.Allocator, req: input.NewPayloadRequest) ![32]u8 {
    const h0 = try htExecutionPayload(alloc, req.execution_payload);
    const h1 = htVersionedHashes(req.versioned_hashes);
    const h2 = htBytes32(req.parent_beacon_block_root);
    const h3 = try htExecutionRequests(alloc, req.execution_requests);

    // merkleize([h0, h1, h2, h3]): 4 chunks, power of 2
    return sha2(sha2(h0, h1), sha2(h2, h3));
}

// ── Serialize output ──────────────────────────────────────────────────────────

/// Serialize SszStatelessValidationResult to 41 bytes:
///   [0..32]  new_payload_request_root
///   [32]     successful_validation (0x01 = valid, 0x00 = invalid)
///   [33..41] chain_config.chain_id (uint64 LE)
pub fn serialize(
    alloc: std.mem.Allocator,
    req: input.NewPayloadRequest,
    chain_id: u64,
    successful_validation: bool,
) ![41]u8 {
    const root = try newPayloadRequestRoot(alloc, req);
    var out: [41]u8 = undefined;
    @memcpy(out[0..32], &root);
    out[32] = if (successful_validation) 0x01 else 0x00;
    std.mem.writeInt(u64, out[33..41], chain_id, .little);
    return out;
}
