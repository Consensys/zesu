/// zesu — unified Ethereum execution library
///
/// Merges zevm (EVM implementation) and zevm-stateless (stateless block executor)
/// with a single build-time selectable crypto interface conforming to
/// zkvm-standards/standards/c-interface-accelerators/zkvm_accelerators.h.
///
/// Primary modules:
///   evm        — EVM core (primitives, bytecode, state, interpreter, precompile, handler)
///   stateless  — Stateless block executor (MPT witness verification, WitnessDatabase)
///   crypto     — Accelerator interface + default C-library implementation
///   io         — Read/write interface per zkvm-standards io-interface

pub const evm        = @import("evm/main.zig");
pub const stateless  = @import("stateless/root.zig");
pub const crypto     = @import("crypto/accelerators.zig");
pub const io         = @import("io/interface.zig");

// Re-export the most commonly used EVM types at the top level for convenience.
pub const primitives = evm.primitives;
