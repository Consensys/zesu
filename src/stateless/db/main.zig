//! WitnessDatabase: stateless EVM database backed by a pre-built MPT NodeIndex.
//!
//! Serves account/storage reads via live MPT proof verification (O(log n) per read
//! via NodeIndex O(1) node lookups). Contract bytecodes are served via linear scan
//! over the (bounded) codes pool.
//!
//! Used directly as the DB type in Context(WitnessDatabase):
//!   var ctx = context.Context(WitnessDatabase).new(witness_db, spec);
//!
//! Implements the zevm DB interface (basic, codeByHash, storage, blockHash).
//! EIP-7928 BAL tracking is handled by the Journal layer — no tracking state here.

const std = @import("std");
const primitives = @import("primitives");
const state = @import("state");
const bytecode = @import("bytecode");
const mpt = @import("mpt");
const types = @import("executor_types");

pub const DbError = error{
    /// MPT proof verification failed — witness is inconsistent with state root.
    InvalidWitness,
};

const EMPTY_TRIE_HASH: primitives.Hash = .{
    0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
    0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
    0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
    0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
};

/// Stateless database built from a pre-built NodeIndex + pre-state root.
///
/// Implements duck-typed Database interface (same methods as InMemoryDB):
///   basic(address)              → ?AccountInfo
///   codeByHash(code_hash)       → Bytecode
///   storage(address, key)       → StorageValue
///   blockHash(number)           → Hash
pub const WitnessDatabase = struct {
    node_index: *const mpt.NodeIndex,
    pre_state_root: primitives.Hash,
    codes: []const []const u8,
    block_hashes: []const types.BlockHashEntry,

    const Self = @This();

    pub fn init(
        alloc: std.mem.Allocator,
        node_index: *const mpt.NodeIndex,
        pre_state_root: primitives.Hash,
        codes: []const []const u8,
        block_hashes: []const types.BlockHashEntry,
    ) Self {
        _ = alloc;
        return .{
            .node_index = node_index,
            .pre_state_root = pre_state_root,
            .codes = codes,
            .block_hashes = block_hashes,
        };
    }

    pub fn deinit(_: *Self) void {}

    // ── basic ───────────────────────────────────────────────────────────────

    pub fn basic(self: *Self, address: primitives.Address) !?state.AccountInfo {
        const account_state = mpt.verifyAccountIndexed(
            self.pre_state_root,
            address,
            self.node_index,
        ) catch |err| switch (err) {
            // InvalidProof means the witness doesn't include proof nodes for this account.
            // Treat as non-existent (e.g., precompile addresses have no witness proof).
            error.InvalidProof => return null,
            else => return DbError.InvalidWitness,
        };

        const as = account_state orelse return null;
        return state.AccountInfo{
            .balance = as.balance,
            .nonce = as.nonce,
            .code_hash = as.code_hash,
            .code = null, // served on demand via codeByHash
        };
    }

    // ── codeByHash ──────────────────────────────────────────────────────────

    pub fn codeByHash(self: *Self, code_hash: primitives.Hash) !bytecode.Bytecode {
        if (std.mem.eql(u8, &code_hash, &primitives.KECCAK_EMPTY)) {
            return bytecode.Bytecode.newLegacy(&.{});
        }
        for (self.codes) |code_bytes| {
            const h = mpt.keccak256(code_bytes);
            if (std.mem.eql(u8, &h, &code_hash)) {
                // Detect EIP-7702 delegation pointer: 0xEF 0x01 0x00 + 20-byte address (23 bytes total).
                // Must return Bytecode.eip7702 so that setupCall detects it and loads the delegation target.
                if (code_bytes.len == 23 and code_bytes[0] == 0xEF and code_bytes[1] == 0x01 and code_bytes[2] == 0x00) {
                    var delegation_addr: primitives.Address = [_]u8{0} ** 20;
                    @memcpy(&delegation_addr, code_bytes[3..23]);
                    return bytecode.Bytecode{ .eip7702 = bytecode.Eip7702Bytecode.new(delegation_addr) };
                }
                return bytecode.Bytecode.newLegacy(code_bytes);
            }
        }
        return bytecode.Bytecode.new();
    }

    // ── storage ─────────────────────────────────────────────────────────────

    pub fn storage(
        self: *Self,
        address: primitives.Address,
        index: primitives.StorageKey,
    ) !primitives.StorageValue {
        const account_state = mpt.verifyAccountIndexed(
            self.pre_state_root,
            address,
            self.node_index,
        ) catch |err| switch (err) {
            // Witness doesn't include proof for this account — treat storage as 0.
            error.InvalidProof => return 0,
            else => return DbError.InvalidWitness,
        };

        const storage_root = if (account_state) |as| as.storage_root else EMPTY_TRIE_HASH;
        const slot = u256ToHash(index);
        const value = mpt.verifyStorageIndexed(storage_root, slot, self.node_index) catch |err| switch (err) {
            error.InvalidProof => return 0,
            else => return DbError.InvalidWitness,
        };

        return value;
    }

    // ── blockHash ───────────────────────────────────────────────────────────

    pub fn blockHash(self: *Self, number: u64) !primitives.Hash {
        for (self.block_hashes) |bhe| {
            if (bhe.number == number) return bhe.hash;
        }
        return [_]u8{0} ** 32;
    }
};

// ─── Private helpers ───────────────────────────────────────────────────────────

fn u256ToHash(value: u256) primitives.Hash {
    var out: primitives.Hash = @splat(0);
    var n = value;
    var i: usize = 32;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast(n & 0xff);
        n >>= 8;
    }
    return out;
}
