const std = @import("std");
const primitives = @import("primitives");
const InstructionContext = @import("../instruction_context.zig").InstructionContext;
const helpers = @import("helpers.zig");

const U = primitives.U256;

fn andOp(a: U, b: U) U { return a & b; }
fn orOp(a: U, b: U) U { return a | b; }
fn xorOp(a: U, b: U) U { return a ^ b; }
fn notOp(a: U) U { return ~a; }
fn clzOp(a: U) U { return @as(U, @clz(a)); }

fn byteOp(i: U, x: U) U {
    return if (i < 32) (x >> @intCast((31 - i) * 8)) & 0xFF else 0;
}

fn shlOp(shift: U, value: U) U {
    return if (shift < 256) value << @intCast(shift) else 0;
}

fn shrOp(shift: U, value: U) U {
    return if (shift < 256) value >> @intCast(shift) else 0;
}

fn sarOp(shift: U, value: U) U {
    const is_negative = (value >> 255) == 1;
    const MAX: U = std.math.maxInt(U);
    if (shift >= 256) return if (is_negative) MAX else 0;
    if (shift == 0) return value;
    const shifted = value >> @intCast(shift);
    return if (is_negative) shifted | (MAX << @intCast(256 - shift)) else shifted;
}

/// AND opcode (0x16): a & b
pub const opAnd = helpers.makeBinaryOp(andOp);
/// OR opcode (0x17): a | b
pub const opOr = helpers.makeBinaryOp(orOp);
/// XOR opcode (0x18): a ^ b
pub const opXor = helpers.makeBinaryOp(xorOp);
/// NOT opcode (0x19): ~a
pub const opNot = helpers.makeUnaryOp(notOp);
/// CLZ opcode (0x1E): count leading zeros (EIP-7939, Osaka+)
pub const opClz = helpers.makeUnaryOp(clzOp);
/// BYTE opcode (0x1A): extract byte i from word x
pub const opByte = helpers.makeBinaryOp(byteOp);
/// SHL opcode (0x1B): logical shift left
pub const opShl = helpers.makeBinaryOp(shlOp);
/// SHR opcode (0x1C): logical shift right
pub const opShr = helpers.makeBinaryOp(shrOp);
/// SAR opcode (0x1D): arithmetic shift right (sign-extending)
pub const opSar = helpers.makeBinaryOp(sarOp);

test {
    _ = @import("bitwise_tests.zig");
}
