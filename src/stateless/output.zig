//! ProofOutput: the values the verifier checks after block execution.
//!
//! The guest commits to these; the on-chain verifier checks them against
//! the block header stored in the chain.

const primitives = @import("primitives");

/// Result of executing one transaction.
pub const ReceiptData = struct {
    /// Cumulative gas used after this tx.
    cumulative_gas_used: u64,
    /// Whether the tx succeeded.
    success: bool,
    /// Logs emitted.
    logs_bloom: [256]u8,
};

/// Output committed by the guest program.
pub const ProofOutput = struct {
    /// Pre-execution state root (must match the block's parentHash state).
    pre_state_root: primitives.Hash,
    /// Post-execution state root.
    post_state_root: primitives.Hash,
    /// Receipts root derived from the executed transactions.
    receipts_root: primitives.Hash,
    /// Per-transaction receipt data.
    receipts: []const ReceiptData,
    /// Fork name used for execution (e.g. "Prague").
    fork_name: []const u8,
};
