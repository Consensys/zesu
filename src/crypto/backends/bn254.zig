const std = @import("std");
const T = @import("precompile_types");
const mcl_wrapper = @import("mcl_wrapper.zig");
const alloc_mod = @import("zesu_allocator");

/// BN254 elliptic curve precompiles
pub const add = struct {
    pub const BYZANTIUM_ADD_GAS_COST: u64 = 500;
    pub const ISTANBUL_ADD_GAS_COST: u64 = 150;
};

pub const mul = struct {
    pub const BYZANTIUM_MUL_GAS_COST: u64 = 40_000;
    pub const ISTANBUL_MUL_GAS_COST: u64 = 6_000;
};

pub const pair = struct {
    pub const BYZANTIUM_PAIR_PER_POINT: u64 = 80_000;
    pub const BYZANTIUM_PAIR_BASE: u64 = 100_000;
    pub const ISTANBUL_PAIR_PER_POINT: u64 = 34_000;
    pub const ISTANBUL_PAIR_BASE: u64 = 45_000;
};

const FQ_LEN: usize = 32;
const SCALAR_LEN: usize = 32;
const FQ2_LEN: usize = 2 * FQ_LEN;
const G1_LEN: usize = 2 * FQ_LEN; // 64 bytes
const G2_LEN: usize = 2 * FQ2_LEN; // 128 bytes
const ADD_INPUT_LEN: usize = 2 * G1_LEN; // 128 bytes
const MUL_INPUT_LEN: usize = G1_LEN + SCALAR_LEN; // 96 bytes
const PAIR_ELEMENT_LEN: usize = G1_LEN + G2_LEN; // 192 bytes

// Pair type for pairing operations
const G1G2Pair = struct { g1: [G1_LEN]u8, g2: [G2_LEN]u8 };

/// Right pad input to specified length
fn rightPad(comptime len: usize, input: []const u8) [len]u8 {
    var padded: [len]u8 = [_]u8{0} ** len;
    const copy_len = @min(input.len, len);
    @memcpy(padded[0..copy_len], input[0..copy_len]);
    return padded;
}

/// BN254 elliptic curve addition (Byzantium)
pub fn bn254AddRunByzantium(input: []const u8, gas_limit: u64) T.PrecompileResult {
    return runAdd(input, add.BYZANTIUM_ADD_GAS_COST, gas_limit);
}

/// BN254 elliptic curve addition (Istanbul)
pub fn bn254AddRunIstanbul(input: []const u8, gas_limit: u64) T.PrecompileResult {
    return runAdd(input, add.ISTANBUL_ADD_GAS_COST, gas_limit);
}

fn runAdd(input: []const u8, gas_cost: u64, gas_limit: u64) T.PrecompileResult {
    if (gas_cost > gas_limit) {
        return T.PrecompileResult{ .err = T.PrecompileError.OutOfGas };
    }

    const padded_input = rightPad(ADD_INPUT_LEN, input);
    const p1_bytes: [G1_LEN]u8 = padded_input[0..G1_LEN].*;
    const p2_bytes: [G1_LEN]u8 = padded_input[G1_LEN..].*;

    // Validate points (basic check - should be enhanced with proper curve validation)
    if (!isValidG1Point(&p1_bytes) or !isValidG1Point(&p2_bytes)) {
        return T.PrecompileResult{ .err = T.PrecompileError.Bn254FieldPointNotAMember };
    }

    // Perform addition using mcl wrapper
    var output: [64]u8 = undefined;
    if (mcl_wrapper.isAvailable()) {
        if (mcl_wrapper.g1Add(p1_bytes, p2_bytes)) |result| {
            output = result;
        } else |err| switch (err) {
            error.MclNotAvailable => @memset(&output, 0),
            else => return T.PrecompileResult{ .err = T.PrecompileError.Bn254FieldPointNotAMember },
        }
    } else {
        // Placeholder if mcl not available
        @memset(&output, 0);
    }

    const heap_out = alloc_mod.get().dupe(u8, &output) catch
        return T.PrecompileResult{ .err = T.PrecompileError.OutOfGas };
    return T.PrecompileResult{ .success = T.PrecompileOutput.new(gas_cost, heap_out) };
}

/// BN254 elliptic curve scalar multiplication (Byzantium)
pub fn bn254MulRunByzantium(input: []const u8, gas_limit: u64) T.PrecompileResult {
    return runMul(input, mul.BYZANTIUM_MUL_GAS_COST, gas_limit);
}

/// BN254 elliptic curve scalar multiplication (Istanbul)
pub fn bn254MulRunIstanbul(input: []const u8, gas_limit: u64) T.PrecompileResult {
    return runMul(input, mul.ISTANBUL_MUL_GAS_COST, gas_limit);
}

fn runMul(input: []const u8, gas_cost: u64, gas_limit: u64) T.PrecompileResult {
    if (gas_cost > gas_limit) {
        return T.PrecompileResult{ .err = T.PrecompileError.OutOfGas };
    }

    const padded_input = rightPad(MUL_INPUT_LEN, input);
    const point_bytes: [G1_LEN]u8 = padded_input[0..G1_LEN].*;
    const scalar_bytes: [SCALAR_LEN]u8 = padded_input[G1_LEN..].*;

    // Validate point (basic check - should be enhanced with proper curve validation)
    if (!isValidG1Point(&point_bytes)) {
        return T.PrecompileResult{ .err = T.PrecompileError.Bn254FieldPointNotAMember };
    }

    // Perform scalar multiplication using mcl wrapper
    var output: [64]u8 = undefined;
    if (mcl_wrapper.isAvailable()) {
        if (mcl_wrapper.g1Mul(point_bytes, scalar_bytes)) |result| {
            output = result;
        } else |err| switch (err) {
            error.MclNotAvailable => @memset(&output, 0),
            else => return T.PrecompileResult{ .err = T.PrecompileError.Bn254FieldPointNotAMember },
        }
    } else {
        // Placeholder if mcl not available
        @memset(&output, 0);
    }

    const heap_out = alloc_mod.get().dupe(u8, &output) catch
        return T.PrecompileResult{ .err = T.PrecompileError.OutOfGas };
    return T.PrecompileResult{ .success = T.PrecompileOutput.new(gas_cost, heap_out) };
}

/// BN254 elliptic curve pairing check (Byzantium)
pub fn bn254PairingRunByzantium(input: []const u8, gas_limit: u64) T.PrecompileResult {
    return runPairing(input, pair.BYZANTIUM_PAIR_PER_POINT, pair.BYZANTIUM_PAIR_BASE, gas_limit);
}

/// BN254 elliptic curve pairing check (Istanbul)
pub fn bn254PairingRunIstanbul(input: []const u8, gas_limit: u64) T.PrecompileResult {
    return runPairing(input, pair.ISTANBUL_PAIR_PER_POINT, pair.ISTANBUL_PAIR_BASE, gas_limit);
}

fn runPairing(input: []const u8, pair_per_point_cost: u64, pair_base_cost: u64, gas_limit: u64) T.PrecompileResult {
    if (input.len % PAIR_ELEMENT_LEN != 0) {
        return T.PrecompileResult{ .err = T.PrecompileError.Bn254PairLength };
    }

    const num_pairs = input.len / PAIR_ELEMENT_LEN;
    const gas_used = @as(u64, num_pairs) * pair_per_point_cost + pair_base_cost;
    if (gas_used > gas_limit) {
        return T.PrecompileResult{ .err = T.PrecompileError.OutOfGas };
    }

    // Parse pairs
    var pairs = std.ArrayListUnmanaged(G1G2Pair){};
    defer pairs.deinit(alloc_mod.get());
    pairs.ensureTotalCapacity(alloc_mod.get(), num_pairs) catch {
        return T.PrecompileResult{ .err = T.PrecompileError.OutOfGas };
    };

    var i: usize = 0;
    while (i < input.len) : (i += PAIR_ELEMENT_LEN) {
        const g1_bytes = input[i..][0..G1_LEN];
        const g2_bytes = input[i + G1_LEN ..][0..G2_LEN];

        // Validate points
        if (!isValidG1Point(g1_bytes) or !isValidG2Point(g2_bytes)) {
            return T.PrecompileResult{ .err = T.PrecompileError.Bn254FieldPointNotAMember };
        }

        const g1: [G1_LEN]u8 = g1_bytes[0..G1_LEN].*;
        const g2: [G2_LEN]u8 = g2_bytes[0..G2_LEN].*;
        pairs.append(alloc_mod.get(), .{ .g1 = g1, .g2 = g2 }) catch {
            return T.PrecompileResult{ .err = T.PrecompileError.OutOfGas };
        };
    }

    // Perform pairing check using mcl wrapper
    var pairing_valid = false;
    if (mcl_wrapper.isAvailable()) {
        // Convert pairs to format expected by mcl_wrapper
        const mcl_pairs = alloc_mod.get().alloc(struct { g1: [64]u8, g2: [128]u8 }, pairs.items.len) catch {
            return T.PrecompileResult{ .err = T.PrecompileError.OutOfGas };
        };
        defer alloc_mod.get().free(mcl_pairs);
        for (pairs.items, 0..) |pair_item, idx| {
            mcl_pairs[idx].g1 = pair_item.g1;
            mcl_pairs[idx].g2 = pair_item.g2;
        }

        if (mcl_wrapper.pairingCheck(@ptrCast(mcl_pairs))) |result| {
            pairing_valid = result;
        } else |err| switch (err) {
            error.MclNotAvailable => pairing_valid = false,
            // Invalid G1/G2 points: spec requires returning an error (empty output, CALL fails)
            else => return T.PrecompileResult{ .err = T.PrecompileError.Bn254FieldPointNotAMember },
        }
    } else {
        // Placeholder: assume invalid if mcl not available
        pairing_valid = false;
    }

    // Result is 1 if pairing is valid, 0 otherwise
    var output: [32]u8 = [_]u8{0} ** 32;
    if (pairing_valid) {
        output[31] = 1;
    }

    const heap_out = alloc_mod.get().dupe(u8, &output) catch
        return T.PrecompileResult{ .err = T.PrecompileError.OutOfGas };
    return T.PrecompileResult{ .success = T.PrecompileOutput.new(gas_used, heap_out) };
}

/// BN254 field modulus (Fq) = 0x30644e72e131a029b85045b68181585d97816a916871ca8d3c208c16d87cfd47
const BN254_FQ_MODULUS: [32]u8 = .{
    0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
    0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
    0x97, 0x81, 0x6a, 0x91, 0x68, 0x71, 0xca, 0x8d,
    0x3c, 0x20, 0x8c, 0x16, 0xd8, 0x7c, 0xfd, 0x47,
};

/// Returns true iff the 32-byte big-endian value is strictly less than the BN254 field modulus.
fn isBelowFieldModulus(value: *const [32]u8) bool {
    for (value, &BN254_FQ_MODULUS) |v, m| {
        if (v < m) return true;
        if (v > m) return false;
    }
    return false; // equal to modulus — not valid
}

/// Validate a G1 point per EIP-196: both coordinates must be < field modulus.
/// (0, 0) is the point at infinity and is always valid.
fn isValidG1Point(point: []const u8) bool {
    if (point.len < G1_LEN) return false;
    const x: *const [32]u8 = point[0..32];
    const y: *const [32]u8 = point[32..64];
    // Point at infinity
    if (std.mem.allEqual(u8, x, 0) and std.mem.allEqual(u8, y, 0)) return true;
    return isBelowFieldModulus(x) and isBelowFieldModulus(y);
}

/// Validate a G2 point per EIP-197: all four 32-byte Fq field elements must be < field modulus.
/// (0, 0, 0, 0) is the point at infinity and is always valid.
fn isValidG2Point(point: []const u8) bool {
    if (point.len < G2_LEN) return false;
    // G2 coordinates are Fq2 elements encoded as (im, re) pairs.
    const x_im: *const [32]u8 = point[0..32];
    const x_re: *const [32]u8 = point[32..64];
    const y_im: *const [32]u8 = point[64..96];
    const y_re: *const [32]u8 = point[96..128];
    // Point at infinity
    if (std.mem.allEqual(u8, x_im, 0) and std.mem.allEqual(u8, x_re, 0) and
        std.mem.allEqual(u8, y_im, 0) and std.mem.allEqual(u8, y_re, 0)) return true;
    return isBelowFieldModulus(x_im) and isBelowFieldModulus(x_re) and
        isBelowFieldModulus(y_im) and isBelowFieldModulus(y_re);
}
