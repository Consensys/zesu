/// Pure-Zig accel_impl — no C dependencies.
/// keccak256 and sha256 are functional; everything else stubs (returns false).
/// Used as the default accel_impl in zesu-core so that zkVM targets and
/// no-library builds compile cleanly without any C headers or linkage.
const std = @import("std");

pub fn keccak256(data: []const u8, output: *[32]u8) void {
    std.crypto.hash.sha3.Keccak256.hash(data, output, .{});
}

pub fn sha256(data: []const u8, output: *[32]u8) void {
    std.crypto.hash.sha2.Sha256.hash(data, output, .{});
}

pub fn secp256k1_verify(msg: *const [32]u8, sig: *const [64]u8, pubkey: *const [64]u8, verified: *bool) void {
    _ = msg;
    _ = sig;
    _ = pubkey;
    verified.* = false;
}

pub fn ecrecover(msg: *const [32]u8, sig: *const [64]u8, recid: u8, output: *[64]u8) bool {
    _ = msg;
    _ = sig;
    _ = recid;
    _ = output;
    return false;
}

pub fn ripemd160(data: []const u8, output: *[32]u8) void {
    _ = data;
    output.* = .{0} ** 32;
}

pub fn modexp(base: []const u8, exp: []const u8, modulus: []const u8, output: []u8) bool {
    _ = base;
    _ = exp;
    _ = modulus;
    @memset(output, 0);
    return false;
}

pub fn bn254_g1_add(p1: *const [64]u8, p2: *const [64]u8, result: *[64]u8) bool {
    _ = p1;
    _ = p2;
    _ = result;
    return false;
}

pub fn bn254_g1_mul(point: *const [64]u8, scalar: *const [32]u8, result: *[64]u8) bool {
    _ = point;
    _ = scalar;
    _ = result;
    return false;
}

pub fn bn254_pairing(pairs: anytype, verified: *bool) bool {
    _ = pairs;
    verified.* = false;
    return false;
}

pub fn blake2f(rounds: u32, h: *[64]u8, m: *const [128]u8, t: *const [16]u8, f: u8) bool {
    _ = rounds;
    _ = h;
    _ = m;
    _ = t;
    _ = f;
    return false;
}

pub fn kzg_point_eval(commitment: *const [48]u8, z: *const [32]u8, y: *const [32]u8, proof: *const [48]u8, verified: *bool) bool {
    _ = commitment;
    _ = z;
    _ = y;
    _ = proof;
    verified.* = false;
    return false;
}

pub fn bls12_g1_add(p1: *const [96]u8, p2: *const [96]u8, result: *[96]u8) bool {
    _ = p1;
    _ = p2;
    _ = result;
    return false;
}

pub fn bls12_g1_msm(pairs: anytype, result: *[96]u8) bool {
    _ = pairs;
    _ = result;
    return false;
}

pub fn bls12_g2_add(p1: *const [192]u8, p2: *const [192]u8, result: *[192]u8) bool {
    _ = p1;
    _ = p2;
    _ = result;
    return false;
}

pub fn bls12_g2_msm(pairs: anytype, result: *[192]u8) bool {
    _ = pairs;
    _ = result;
    return false;
}

pub fn bls12_pairing(pairs: anytype, verified: *bool) bool {
    _ = pairs;
    verified.* = false;
    return false;
}

pub fn bls12_map_fp_to_g1(field_element: *const [48]u8, result: *[96]u8) bool {
    _ = field_element;
    _ = result;
    return false;
}

pub fn bls12_map_fp2_to_g2(field_element: *const [96]u8, result: *[192]u8) bool {
    _ = field_element;
    _ = result;
    return false;
}

pub fn secp256r1_verify(msg: *const [32]u8, sig: *const [64]u8, pubkey: *const [64]u8, verified: *bool) void {
    _ = msg;
    _ = sig;
    _ = pubkey;
    verified.* = false;
}
