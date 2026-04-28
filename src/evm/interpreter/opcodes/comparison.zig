const std = @import("std");
const primitives = @import("primitives");
const InstructionContext = @import("../instruction_context.zig").InstructionContext;
const helpers = @import("helpers.zig");

const U = primitives.U256;

fn ltOp(a: U, b: U) U { return if (a < b) 1 else 0; }
fn gtOp(a: U, b: U) U { return if (a > b) 1 else 0; }
fn eqOp(a: U, b: U) U { return if (a == b) 1 else 0; }
fn isZeroOp(a: U) U { return if (a == 0) 1 else 0; }

fn sltOp(a: U, b: U) U {
    const a_neg = (a >> 255) == 1;
    const b_neg = (b >> 255) == 1;
    if (a_neg == b_neg) return if (a < b) 1 else 0;
    return if (a_neg) 1 else 0;
}

fn sgtOp(a: U, b: U) U {
    const a_neg = (a >> 255) == 1;
    const b_neg = (b >> 255) == 1;
    if (a_neg == b_neg) return if (a > b) 1 else 0;
    return if (b_neg) 1 else 0;
}

/// LT opcode (0x10): a < b (unsigned)
pub const opLt = helpers.makeBinaryOp(ltOp);
/// GT opcode (0x11): a > b (unsigned)
pub const opGt = helpers.makeBinaryOp(gtOp);
/// SLT opcode (0x12): a < b (signed)
pub const opSlt = helpers.makeBinaryOp(sltOp);
/// SGT opcode (0x13): a > b (signed)
pub const opSgt = helpers.makeBinaryOp(sgtOp);
/// EQ opcode (0x14): a == b
pub const opEq = helpers.makeBinaryOp(eqOp);
/// ISZERO opcode (0x15): a == 0
pub const opIsZero = helpers.makeUnaryOp(isZeroOp);

test {
    _ = @import("comparison_tests.zig");
}
