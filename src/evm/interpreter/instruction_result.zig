/// Result of executing an EVM instruction.
pub const InstructionResult = enum(u8) {
    /// Continue execution to the next instruction.
    continue_ = 0,
    /// Encountered a `STOP` opcode
    stop = 1,
    /// Return from the current call.
    @"return",
    /// Self-destruct the current contract.
    selfdestruct,

    // Revert codes
    /// Revert the transaction.
    revert = 0x10,

    // Error codes
    /// Out of gas error.
    out_of_gas = 0x20,
    /// The memory limit of the EVM has been exceeded.
    memory_limit_oog,
    /// Unknown or invalid opcode.
    invalid_opcode,
    /// Invalid jump destination.
    invalid_jump,
    /// Invalid return data access (EIP-211).
    invalid_returndata,
    /// Write to state in a static call.
    invalid_static,
    /// Stack underflow — not enough items on the stack.
    stack_underflow,
    /// Stack overflow — too many items on the stack.
    stack_overflow,

    pub fn isSuccess(self: InstructionResult) bool {
        return switch (self) {
            .stop, .@"return", .selfdestruct => true,
            else => false,
        };
    }

    pub fn isRevert(self: InstructionResult) bool {
        return self == .revert;
    }

    pub fn isError(self: InstructionResult) bool {
        return !self.isSuccess() and self != .revert and self != .continue_;
    }

    pub fn default() InstructionResult {
        return .stop;
    }
};
