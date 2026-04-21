/// EIP system contract call handlers for pre- and post-block processing.
///
/// "System contract calls" here refers to EVM-level calls made by the
/// protocol itself (from SYSTEM_ADDRESS) to designated system contracts —
/// not OS/machine-level system calls.
///
/// All system contract calls execute outside normal gas accounting and
/// tx validation. State changes are committed on success and discarded
/// on revert.
///
/// Pre-block  (Cancun+/Prague+, before user transactions):
///   EIP-4788 — call beacon roots contract with parent_beacon_block_root as calldata.
///   EIP-2935 — call block history contract with parent_hash as calldata.
///
/// Post-block (Prague+, after user transactions):
///   EIP-7002 — withdrawal requests system contract call.
///   EIP-7251 — consolidation requests system contract call.
const std = @import("std");
const primitives = @import("primitives");
const input = @import("executor_types");
const context_mod = @import("context");
const handler_mod = @import("handler");
const alloc_mod = @import("./executor_allocator.zig");

// ─── Well-known addresses ─────────────────────────────────────────────────────

const BEACON_ROOTS_ADDRESS: input.Address = .{
    0x00, 0x0F, 0x3d, 0xf6, 0xD7, 0x32, 0x80, 0x7E, 0xf1, 0x31,
    0x9f, 0xB7, 0xB8, 0xBb, 0x85, 0x22, 0xd0, 0xBe, 0xac, 0x02,
};

const HISTORY_STORAGE_ADDRESS: input.Address = .{
    0x00, 0x00, 0xf9, 0x08, 0x27, 0xf1, 0xc5, 0x3a, 0x10, 0xcb,
    0x7a, 0x02, 0x33, 0x5b, 0x17, 0x53, 0x20, 0x00, 0x29, 0x35,
};

const SYSTEM_ADDRESS: input.Address = .{
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    0xff, 0xff, 0xff, 0xfe,
};

const EIP7002_ADDRESS: input.Address = .{
    0x00, 0x00, 0x09, 0x61, 0xef, 0x48, 0x0e, 0xb5, 0x5e, 0x80,
    0xd1, 0x9a, 0xd8, 0x35, 0x79, 0xa6, 0x4c, 0x00, 0x70, 0x02,
};

const EIP7251_ADDRESS: input.Address = .{
    0x00, 0x00, 0xbb, 0xdd, 0xc7, 0xce, 0x48, 0x86, 0x42, 0xfb,
    0x57, 0x9f, 0x8b, 0x00, 0xf3, 0xa5, 0x90, 0x00, 0x72, 0x51,
};

// ─── Shared execution helper ──────────────────────────────────────────────────

/// Execute a single privileged system call as SYSTEM_ADDRESS.
///
/// Skips the call silently if the target contract is not deployed.
/// Discards state and returns on any execution error — a broken system
/// contract must not invalidate the block.
fn runSystemCall(
    ctx: anytype,
    instructions: *handler_mod.Instructions,
    precompiles: *handler_mod.Precompiles,
    target: input.Address,
    calldata: []const u8,
    chain_id: u64,
) void {
    // The spec gives each system contract exactly 30M execution gas.
    // zevm deducts the 21,000 intrinsic base before the frame starts.
    const SYSTEM_CALL_GAS: u64 = 30_000_000 + 21_000;

    // Skip if the contract has no code (also covers non-existing accounts).
    // Call discardTx so that the loadAccount call does not leave the target
    // address warm in the journal — otherwise user transactions in the same
    // block would see it as warm (cheap) instead of cold (EIP-2929).
    const account_load = ctx.journaled_state.loadAccount(target) catch {
        ctx.journaled_state.discardTx();
        return;
    };
    if (std.mem.eql(u8, &account_load.data.info.code_hash, &primitives.KECCAK_EMPTY)) {
        ctx.journaled_state.discardTx();
        return;
    }

    // Bypass normal tx validation for system calls.
    const saved_nonce = ctx.cfg.disable_nonce_check;
    const saved_bal = ctx.cfg.disable_balance_check;
    const saved_fee = ctx.cfg.disable_fee_charge;
    const saved_basefee = ctx.cfg.disable_base_fee;
    const saved_block_gas = ctx.cfg.disable_block_gas_limit;
    ctx.cfg.disable_nonce_check = true;
    ctx.cfg.disable_balance_check = true;
    ctx.cfg.disable_fee_charge = true;
    ctx.cfg.disable_base_fee = true;
    ctx.cfg.disable_block_gas_limit = true;
    defer {
        ctx.cfg.disable_nonce_check = saved_nonce;
        ctx.cfg.disable_balance_check = saved_bal;
        ctx.cfg.disable_fee_charge = saved_fee;
        ctx.cfg.disable_base_fee = saved_basefee;
        ctx.cfg.disable_block_gas_limit = saved_block_gas;
    }

    // Set up calldata (may be empty for post-block calls).
    var data_list: ?std.ArrayList(u8) = null;
    if (calldata.len > 0) {
        var dl = std.ArrayList(u8){};
        dl.appendSlice(alloc_mod.get(), calldata) catch return;
        data_list = dl;
    }

    ctx.tx.caller = SYSTEM_ADDRESS;
    ctx.tx.kind = context_mod.TxKind{ .Call = target };
    ctx.tx.gas_limit = SYSTEM_CALL_GAS;
    ctx.tx.gas_price = 0;
    ctx.tx.gas_priority_fee = null;
    ctx.tx.value = 0;
    ctx.tx.nonce = 0;
    ctx.tx.tx_type = 0;
    ctx.tx.data = data_list;
    ctx.tx.access_list = context_mod.AccessList{ .items = null };
    ctx.tx.blob_hashes = null;
    ctx.tx.authorization_list = null;
    ctx.tx.chain_id = chain_id;

    var frames = handler_mod.FrameStack.new();
    const EvmT = handler_mod.EvmFor(@TypeOf(ctx.*).DatabaseType);
    var evm = EvmT.init(ctx, null, instructions, precompiles, &frames);
    var result = handler_mod.ExecuteEvm.execute(&evm) catch {
        ctx.journaled_state.discardTx();
        if (ctx.tx.data) |*d| d.deinit(alloc_mod.get());
        ctx.tx.data = null;
        return;
    };
    result.deinit();

    if (ctx.tx.data) |*d| d.deinit(alloc_mod.get());
    ctx.tx.data = null;

    // System calls must not increment the caller's nonce.
    // zevm always bumps nonce unconditionally, so patch it back.
    if (ctx.journaled_state.inner.evm_state.getPtr(SYSTEM_ADDRESS)) |sa| {
        if (sa.info.nonce > 0) sa.info.nonce -= 1;
    }

    // Notify the fallback database that this system call committed successfully.
}

// ─── Pre-block system calls ───────────────────────────────────────────────────

/// Call the EIP-4788 (Cancun+) and EIP-2935 (Prague+) system contracts before
/// executing user transactions. Each call passes the relevant 32-byte hash as
/// calldata; the contract code handles the storage write.
pub fn applyPreBlockCalls(
    ctx: anytype,
    instructions: *handler_mod.Instructions,
    precompiles: *handler_mod.Precompiles,
    env: input.Env,
    spec: primitives.SpecId,
    chain_id: u64,
) void {
    if (primitives.isEnabledIn(spec, .cancun)) {
        if (env.parent_beacon_block_root) |root| {
            runSystemCall(ctx, instructions, precompiles, BEACON_ROOTS_ADDRESS, &root, chain_id);
        }
    }
    if (primitives.isEnabledIn(spec, .prague)) {
        if (env.parent_hash) |parent_hash| {
            runSystemCall(ctx, instructions, precompiles, HISTORY_STORAGE_ADDRESS, &parent_hash, chain_id);
        }
    }
}

// ─── Post-block system calls ──────────────────────────────────────────────────

/// Call the EIP-7002 (withdrawal requests) and EIP-7251 (consolidation requests)
/// system contracts after all user transactions (Prague+).
///
/// Per EIP-7002/7251: if the contract has no code the call is silently skipped,
/// matching the same fail-safe behaviour as the pre-block system calls.
pub fn applyPostBlockCalls(
    ctx: anytype,
    instructions: *handler_mod.Instructions,
    precompiles: *handler_mod.Precompiles,
    spec: primitives.SpecId,
    chain_id: u64,
) void {
    if (!primitives.isEnabledIn(spec, .prague)) return;
    for ([_]input.Address{ EIP7002_ADDRESS, EIP7251_ADDRESS }) |sc_addr| {
        runSystemCall(ctx, instructions, precompiles, sc_addr, &.{}, chain_id);
    }
}

pub const PostBlockRequestBytes = struct {
    /// Raw return bytes from the EIP-7002 system contract (76 bytes × n withdrawals).
    withdrawal_requests: []const u8,
    /// Raw return bytes from the EIP-7251 system contract (116 bytes × n consolidations).
    consolidation_requests: []const u8,
};

/// Like applyPostBlockCalls but captures and returns the raw output bytes from
/// each system contract so the caller can compute the EIP-7685 requests_hash.
/// Caller owns the returned slices (allocated with `alloc`).
/// Returns error.SystemContractCallFailed if any post-block system contract
/// call reverts, halts, or runs out of gas (per EIP-7685: such blocks are invalid).
pub fn applyPostBlockCallsCapture(
    alloc: std.mem.Allocator,
    ctx: anytype,
    instructions: *handler_mod.Instructions,
    precompiles: *handler_mod.Precompiles,
    spec: primitives.SpecId,
    chain_id: u64,
) error{SystemContractCallFailed}!PostBlockRequestBytes {
    if (!primitives.isEnabledIn(spec, .prague)) return .{ .withdrawal_requests = &.{}, .consolidation_requests = &.{} };
    return .{
        .withdrawal_requests = try runSystemCallCapture(alloc, ctx, instructions, precompiles, EIP7002_ADDRESS, &.{}, chain_id),
        .consolidation_requests = try runSystemCallCapture(alloc, ctx, instructions, precompiles, EIP7251_ADDRESS, &.{}, chain_id),
    };
}

/// Like runSystemCall but returns a caller-owned copy of the return data.
/// Returns an empty slice if the contract is not deployed.
/// Returns error.SystemContractCallFailed if the call reverts, halts, or runs out of gas.
fn runSystemCallCapture(
    alloc: std.mem.Allocator,
    ctx: anytype,
    instructions: *handler_mod.Instructions,
    precompiles: *handler_mod.Precompiles,
    target: input.Address,
    calldata: []const u8,
    chain_id: u64,
) error{SystemContractCallFailed}![]const u8 {
    const SYSTEM_CALL_GAS: u64 = 30_000_000 + 21_000;

    const account_load = ctx.journaled_state.loadAccount(target) catch {
        ctx.journaled_state.discardTx();
        return &.{};
    };
    if (std.mem.eql(u8, &account_load.data.info.code_hash, &primitives.KECCAK_EMPTY)) {
        ctx.journaled_state.discardTx();
        return &.{};
    }

    const saved_nonce = ctx.cfg.disable_nonce_check;
    const saved_bal = ctx.cfg.disable_balance_check;
    const saved_fee = ctx.cfg.disable_fee_charge;
    const saved_basefee = ctx.cfg.disable_base_fee;
    const saved_block_gas = ctx.cfg.disable_block_gas_limit;
    ctx.cfg.disable_nonce_check = true;
    ctx.cfg.disable_balance_check = true;
    ctx.cfg.disable_fee_charge = true;
    ctx.cfg.disable_base_fee = true;
    ctx.cfg.disable_block_gas_limit = true;
    defer {
        ctx.cfg.disable_nonce_check = saved_nonce;
        ctx.cfg.disable_balance_check = saved_bal;
        ctx.cfg.disable_fee_charge = saved_fee;
        ctx.cfg.disable_base_fee = saved_basefee;
        ctx.cfg.disable_block_gas_limit = saved_block_gas;
    }

    var data_list: ?std.ArrayList(u8) = null;
    if (calldata.len > 0) {
        var dl = std.ArrayList(u8){};
        dl.appendSlice(alloc_mod.get(), calldata) catch return &.{};
        data_list = dl;
    }

    ctx.tx.caller = SYSTEM_ADDRESS;
    ctx.tx.kind = context_mod.TxKind{ .Call = target };
    ctx.tx.gas_limit = SYSTEM_CALL_GAS;
    ctx.tx.gas_price = 0;
    ctx.tx.gas_priority_fee = null;
    ctx.tx.value = 0;
    ctx.tx.nonce = 0;
    ctx.tx.tx_type = 0;
    ctx.tx.data = data_list;
    ctx.tx.access_list = context_mod.AccessList{ .items = null };
    ctx.tx.blob_hashes = null;
    ctx.tx.authorization_list = null;
    ctx.tx.chain_id = chain_id;

    var frames = handler_mod.FrameStack.new();
    const EvmT = handler_mod.EvmFor(@TypeOf(ctx.*).DatabaseType);
    var evm = EvmT.init(ctx, null, instructions, precompiles, &frames);
    var result = handler_mod.ExecuteEvm.execute(&evm) catch {
        ctx.journaled_state.discardTx();
        if (ctx.tx.data) |*d| d.deinit(alloc_mod.get());
        ctx.tx.data = null;
        return error.SystemContractCallFailed;
    };

    if (result.status != .Success) {
        result.deinit();
        if (ctx.tx.data) |*d| d.deinit(alloc_mod.get());
        ctx.tx.data = null;
        return error.SystemContractCallFailed;
    }

    const output = if (result.return_data.len > 0) alloc.dupe(u8, result.return_data) catch &.{} else &.{};
    result.deinit();

    if (ctx.tx.data) |*d| d.deinit(alloc_mod.get());
    ctx.tx.data = null;

    if (ctx.journaled_state.inner.evm_state.getPtr(SYSTEM_ADDRESS)) |sa| {
        if (sa.info.nonce > 0) sa.info.nonce -= 1;
    }

    return output;
}
