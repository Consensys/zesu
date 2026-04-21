/// Default cryptographic accelerator implementation.
///
/// Implements every function declared in src/crypto/accelerators.zig using:
///   - std.crypto      for: keccak256, sha256
///   - Pure-Zig        for: ripemd160, modexp, blake2f
///   - libsecp256k1    for: ecrecover, secp256k1_verify
///   - libmcl          for: BN254 operations
///   - libblst         for: BLS12-381 operations, KZG point evaluation
///   - libOpenSSL      for: secp256r1 (P-256) verification
///
/// C library linking is handled by build.zig.
/// Disable individual libraries at build time: -Dblst=false / -Dmcl=false etc.
///
/// Module dependencies (wired by build.zig):
///   build_options    — enable_secp256k1, enable_mcl, enable_blst, enable_openssl
///   zevm_allocator   — allocator for blst MSM scratch and modexp big-int path

const std = @import("std");
const opts = @import("build_options");

// Backend modules — all owned exclusively by this (accel_impl) module.
const secp256k1_wrapper = @import("backends/secp256k1_wrapper.zig");
const mcl_wrapper       = @import("backends/mcl_wrapper.zig");
const blst_wrapper      = @import("backends/blst_wrapper.zig");
const openssl_wrapper   = @import("backends/openssl_wrapper.zig");
const blake2f_impl      = @import("backends/blake2f_impl.zig");
const modexp_impl       = @import("backends/modexp_impl.zig");
const ripemd160_impl    = @import("backends/ripemd160_impl.zig");

// ── Non-precompile operations ─────────────────────────────────────────────────

pub fn keccak256(data: []const u8, output: *[32]u8) void {
    std.crypto.hash.sha3.Keccak256.hash(data, output, .{});
}

pub fn secp256k1_verify(
    msg:      *const [32]u8,
    sig:      *const [64]u8,
    pubkey:   *const [64]u8,
    verified: *bool,
) void {
    if (!opts.enable_secp256k1) { verified.* = false; return; }
    verified.* = secp256k1_wrapper.verify(msg.*, sig.*, pubkey.*);
}

// ── Precompile 0x01: ECRECOVER ────────────────────────────────────────────────

pub fn ecrecover(
    msg:    *const [32]u8,
    sig:    *const [64]u8,
    recid:  u8,
    output: *[64]u8,
) bool {
    if (!opts.enable_secp256k1) return false;
    const pubkey = secp256k1_wrapper.ecrecoverPubkey(msg.*, sig.*, recid) orelse return false;
    output.* = pubkey;
    return true;
}

// ── Precompile 0x02: SHA-256 ──────────────────────────────────────────────────

pub fn sha256(data: []const u8, output: *[32]u8) void {
    std.crypto.hash.sha2.Sha256.hash(data, output, .{});
}

// ── Precompile 0x03: RIPEMD-160 ──────────────────────────────────────────────

pub fn ripemd160(data: []const u8, output: *[32]u8) void {
    const hash = ripemd160_impl.ripemd160(data);
    output.* = [_]u8{0} ** 32;
    @memcpy(output[0..20], &hash);
}

// ── Precompile 0x05: ModExp ───────────────────────────────────────────────────

pub fn modexp(
    base:    []const u8,
    exp:     []const u8,
    modulus: []const u8,
    output:  []u8,
) bool {
    return modexp_impl.modexp(base, exp, modulus, output);
}

// ── Precompile 0x06–0x08: BN254 ──────────────────────────────────────────────

pub fn bn254_g1_add(p1: *const [64]u8, p2: *const [64]u8, result: *[64]u8) bool {
    if (!opts.enable_mcl) return false;
    const out = mcl_wrapper.g1Add(p1.*, p2.*) catch return false;
    result.* = out;
    return true;
}

pub fn bn254_g1_mul(point: *const [64]u8, scalar: *const [32]u8, result: *[64]u8) bool {
    if (!opts.enable_mcl) return false;
    const out = mcl_wrapper.g1Mul(point.*, scalar.*) catch return false;
    result.* = out;
    return true;
}

pub fn bn254_pairing(pairs: anytype, verified: *bool) bool {
    if (!opts.enable_mcl) return false;
    // Bn254PairingPair (extern struct {g1:[64]u8, g2:[128]u8}) and mcl_wrapper.PairingPair
    // (struct {g1:[64]u8, g2:[128]u8}) have the same binary layout (size 192, align 1).
    const ptr: [*]const mcl_wrapper.PairingPair = @ptrCast(pairs.ptr);
    const v = mcl_wrapper.pairingCheck(ptr[0..pairs.len]) catch return false;
    verified.* = v;
    return true;
}

// ── Precompile 0x09: BLAKE2f ──────────────────────────────────────────────────

pub fn blake2f(
    rounds: u32,
    h:      *[64]u8,
    m:      *const [128]u8,
    t:      *const [16]u8,
    f:      u8,
) bool {
    return blake2f_impl.compress(rounds, h, m, t, f);
}

// ── Precompile 0x0a: KZG point evaluation ─────────────────────────────────────

pub fn kzg_point_eval(
    commitment: *const [48]u8,
    z:          *const [32]u8,
    y:          *const [32]u8,
    proof:      *const [48]u8,
    verified:   *bool,
) bool {
    if (!opts.enable_blst) return false;
    const v = blst_wrapper.verifyKzgProof(commitment.*, z.*, y.*, proof.*) catch return false;
    verified.* = v;
    return true;
}

// ── Precompile 0x0b–0x11: BLS12-381 ──────────────────────────────────────────

pub fn bls12_g1_add(p1: *const [96]u8, p2: *const [96]u8, result: *[96]u8) bool {
    if (!opts.enable_blst) return false;
    const out = blst_wrapper.g1Add(p1.*, p2.*) catch return false;
    result.* = out;
    return true;
}

pub fn bls12_g1_msm(pairs: anytype, result: *[96]u8) bool {
    if (!opts.enable_blst) return false;
    // Bls12G1MsmPair (extern struct {point:[96]u8, scalar:[32]u8}) and blst_wrapper.G1MsmPair
    // (struct {point:[96]u8, scalar:[32]u8}) have the same binary layout (size 128, align 1).
    const ptr: [*]const blst_wrapper.G1MsmPair = @ptrCast(pairs.ptr);
    const out = blst_wrapper.g1Msm(ptr[0..pairs.len]) catch return false;
    result.* = out;
    return true;
}

pub fn bls12_g2_add(p1: *const [192]u8, p2: *const [192]u8, result: *[192]u8) bool {
    if (!opts.enable_blst) return false;
    const out = blst_wrapper.g2Add(p1.*, p2.*) catch return false;
    result.* = out;
    return true;
}

pub fn bls12_g2_msm(pairs: anytype, result: *[192]u8) bool {
    if (!opts.enable_blst) return false;
    // Bls12G2MsmPair (extern struct {point:[192]u8, scalar:[32]u8}) and blst_wrapper.G2MsmPair
    // (struct {point:[192]u8, scalar:[32]u8}) have the same binary layout (size 224, align 1).
    const ptr: [*]const blst_wrapper.G2MsmPair = @ptrCast(pairs.ptr);
    const out = blst_wrapper.g2Msm(ptr[0..pairs.len]) catch return false;
    result.* = out;
    return true;
}

pub fn bls12_pairing(pairs: anytype, verified: *bool) bool {
    if (!opts.enable_blst) return false;
    // Bls12PairingPair (extern struct {g1:[96]u8, g2:[192]u8}) and blst_wrapper.PairingPair
    // (struct {g1:[96]u8, g2:[192]u8}) have the same binary layout (size 288, align 1).
    const ptr: [*]const blst_wrapper.PairingPair = @ptrCast(pairs.ptr);
    const v = blst_wrapper.pairingCheck(ptr[0..pairs.len]) catch return false;
    verified.* = v;
    return true;
}

pub fn bls12_map_fp_to_g1(field_element: *const [48]u8, result: *[96]u8) bool {
    if (!opts.enable_blst) return false;
    const out = blst_wrapper.mapFpToG1(field_element.*) catch return false;
    result.* = out;
    return true;
}

pub fn bls12_map_fp2_to_g2(field_element: *const [96]u8, result: *[192]u8) bool {
    if (!opts.enable_blst) return false;
    const out = blst_wrapper.mapFp2ToG2(field_element.*) catch return false;
    result.* = out;
    return true;
}

// ── Precompile 0x100: secp256r1 (P-256) ──────────────────────────────────────

pub fn secp256r1_verify(
    msg:      *const [32]u8,
    sig:      *const [64]u8,
    pubkey:   *const [64]u8,
    verified: *bool,
) void {
    if (!opts.enable_openssl) { verified.* = false; return; }
    verified.* = openssl_wrapper.verifyP256(msg.*, sig.*, pubkey.*);
}
