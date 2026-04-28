const std = @import("std");
const InstructionContext = @import("../instruction_context.zig").InstructionContext;
const InstructionFn = @import("../instruction_context.zig").InstructionFn;
const primitives = @import("primitives");
const gas_costs = @import("../gas_costs.zig");
const alloc_mod = @import("zesu_allocator");

pub fn memoryCostWords(num_words: usize) u64 {
    const n: u64 = @intCast(num_words);
    const linear = std.math.mul(u64, n, gas_costs.G_MEMORY) catch return std.math.maxInt(u64);
    const quadratic = (std.math.mul(u64, n, n) catch return std.math.maxInt(u64)) / 512;
    return std.math.add(u64, linear, quadratic) catch std.math.maxInt(u64);
}

pub fn expandMemory(ctx: *InstructionContext, new_size: usize) bool {
    if (new_size == 0) return true;
    const current = ctx.interpreter.memory.size();
    if (new_size <= current) return true;
    const current_words = (current + 31) / 32;
    const new_words = (std.math.add(usize, new_size, 31) catch return false) / 32;
    if (new_words > current_words) {
        const cost = memoryCostWords(new_words) - memoryCostWords(current_words);
        if (!ctx.interpreter.gas.spend(cost)) return false;
    }
    const aligned_size = new_words * 32;
    const old_size = ctx.interpreter.memory.size();
    ctx.interpreter.memory.buffer.resize(alloc_mod.get(), aligned_size) catch return false;
    @memset(ctx.interpreter.memory.buffer.items[old_size..aligned_size], 0);
    return true;
}

/// Comptime factory: binary op — pops 2, pushes 1.
/// `op` must be `fn (a: U256, b: U256) U256`.
pub fn makeBinaryOp(comptime op: fn (primitives.U256, primitives.U256) primitives.U256) InstructionFn {
    return struct {
        fn f(ctx: *InstructionContext) void {
            const stack = &ctx.interpreter.stack;
            if (!stack.hasItems(2)) {
                ctx.interpreter.halt(.stack_underflow);
                return;
            }
            const a = stack.peekUnsafe(0);
            const b = stack.peekUnsafe(1);
            stack.shrinkUnsafe(1);
            stack.setTopUnsafe().* = op(a, b);
        }
    }.f;
}

/// Comptime factory: unary op — in-place on top of stack.
/// `op` must be `fn (a: U256) U256`.
pub fn makeUnaryOp(comptime op: fn (primitives.U256) primitives.U256) InstructionFn {
    return struct {
        fn f(ctx: *InstructionContext) void {
            const stack = &ctx.interpreter.stack;
            if (!stack.hasItems(1)) {
                ctx.interpreter.halt(.stack_underflow);
                return;
            }
            const ptr = stack.setTopUnsafe();
            ptr.* = op(ptr.*);
        }
    }.f;
}

/// Comptime factory: ternary op — pops 3, pushes 1.
/// `op` must be `fn (a: U256, b: U256, c: U256) U256`.
pub fn makeTernaryOp(comptime op: fn (primitives.U256, primitives.U256, primitives.U256) primitives.U256) InstructionFn {
    return struct {
        fn f(ctx: *InstructionContext) void {
            const stack = &ctx.interpreter.stack;
            if (!stack.hasItems(3)) {
                ctx.interpreter.halt(.stack_underflow);
                return;
            }
            const a = stack.peekUnsafe(0);
            const b = stack.peekUnsafe(1);
            const c = stack.peekUnsafe(2);
            stack.shrinkUnsafe(2);
            stack.setTopUnsafe().* = op(a, b, c);
        }
    }.f;
}
