const std = @import("std");
const primitives = @import("primitives");
const bytecode = @import("bytecode");

/// Types for interpreter actions like calls and contract creation.
pub const InterpreterAction = union(enum) {
    /// Call action
    call: CallAction,
    /// Create action
    create: CreateAction,
    /// Return action
    @"return": ReturnAction,
    /// Selfdestruct action
    selfdestruct: SelfdestructAction,
    /// Stop action
    stop: StopAction,
    /// Revert action
    revert: RevertAction,
};

/// Call action for CALL, CALLCODE, DELEGATECALL, STATICCALL
pub const CallAction = struct {
    /// Call scheme
    scheme: CallScheme,
    /// Call inputs
    inputs: CallInputs,
    /// Call outcome
    outcome: ?CallOutcome,
};

/// Create action for CREATE, CREATE2
pub const CreateAction = struct {
    /// Create scheme
    scheme: CreateScheme,
    /// Create inputs
    inputs: CreateInputs,
    /// Create outcome
    outcome: ?CreateOutcome,
};

/// Return action
pub const ReturnAction = struct {
    /// Return data
    data: primitives.Bytes,
    /// Gas used
    gas_used: u64,
};

/// Selfdestruct action
pub const SelfdestructAction = struct {
    /// Target address
    target: primitives.Address,
    /// Refund address
    refund_address: primitives.Address,
    /// Balance
    balance: primitives.U256,
};

/// Stop action
pub const StopAction = struct {
    /// Gas used
    gas_used: u64,
};

/// Revert action
pub const RevertAction = struct {
    /// Revert data
    data: primitives.Bytes,
    /// Gas used
    gas_used: u64,
};

/// Call scheme
pub const CallScheme = enum {
    /// CALL
    call,
    /// CALLCODE
    callcode,
    /// DELEGATECALL
    delegatecall,
    /// STATICCALL
    staticcall,
};

/// Create scheme
pub const CreateScheme = enum {
    /// CREATE
    create,
    /// CREATE2
    create2,
};

/// Call inputs
pub const CallInputs = struct {
    /// Caller address
    caller: primitives.Address,
    /// Target address
    target: primitives.Address,
    /// Value
    value: primitives.U256,
    /// Data
    data: primitives.Bytes,
    /// Gas limit
    gas_limit: u64,
    /// Call scheme
    scheme: CallScheme,
    /// Is static call
    is_static: bool,
};

/// Call outcome
pub const CallOutcome = struct {
    /// Return data
    data: primitives.Bytes,
    /// Gas used
    gas_used: u64,
    /// Success
    success: bool,
};

/// Create inputs
pub const CreateInputs = struct {
    /// Caller address
    caller: primitives.Address,
    /// Value
    value: primitives.U256,
    /// Init code
    init_code: primitives.Bytes,
    /// Gas limit
    gas_limit: u64,
    /// Create scheme
    scheme: CreateScheme,
    /// Salt for CREATE2
    salt: ?primitives.Hash,
    /// EIP-8037 (Amsterdam+): state gas reservoir forwarded from parent to child.
    reservoir: u64,
};

/// Create outcome
pub const CreateOutcome = struct {
    /// Created address
    address: primitives.Address,
    /// Return data
    data: primitives.Bytes,
    /// Gas used
    gas_used: u64,
    /// Success
    success: bool,
};

/// Frame input
pub const FrameInput = struct {
    /// Caller address
    caller: primitives.Address,
    /// Target address
    target: primitives.Address,
    /// Value
    value: primitives.U256,
    /// Data
    data: primitives.Bytes,
    /// Gas limit
    gas_limit: u64,
    /// Call scheme
    scheme: CallScheme,
    /// Is static call
    is_static: bool,
    /// Depth
    depth: usize,
};

/// Call value
pub const CallValue = struct {
    /// Value
    value: primitives.U256,
    /// Is zero
    is_zero: bool,
};
