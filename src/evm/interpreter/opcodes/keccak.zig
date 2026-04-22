const std = @import("std");
const primitives = @import("primitives");
const InstructionContext = @import("../instruction_context.zig").InstructionContext;
const gas_costs = @import("../gas_costs.zig");
const alloc_mod = @import("zesu_allocator");

fn memoryCostWords(num_words: usize) u64 {
    const n: u64 = @intCast(num_words);
    const linear = std.math.mul(u64, n, gas_costs.G_MEMORY) catch return std.math.maxInt(u64);
    const quadratic = (std.math.mul(u64, n, n) catch return std.math.maxInt(u64)) / 512;
    return std.math.add(u64, linear, quadratic) catch std.math.maxInt(u64);
}

/// KECCAK256 opcode (0x20): Compute Keccak-256 hash of memory region
/// Stack: [offset, length] -> [hash]
/// Gas: 30 (G_KECCAK256, dispatch) + 6*ceil(length/32) (word cost) + memory_expansion
pub fn opKeccak256(ctx: *InstructionContext) void {
    const stack = &ctx.interpreter.stack;
    if (!stack.hasItems(2)) {
        ctx.interpreter.halt(.stack_underflow);
        return;
    }

    const offset = stack.peekUnsafe(0);
    const length = stack.peekUnsafe(1);

    if (length > std.math.maxInt(usize)) {
        ctx.interpreter.halt(.memory_limit_oog);
        return;
    }
    const length_usize: usize = @intCast(length);
    // When length == 0, offset is unused — do not halt on huge offset.
    if (length_usize > 0 and offset > std.math.maxInt(usize)) {
        ctx.interpreter.halt(.memory_limit_oog);
        return;
    }
    const offset_usize: usize = if (length_usize == 0) 0 else @intCast(offset);

    // Compute end = offset + length before word-cost so a huge length is caught early.
    const end = if (length_usize > 0)
        std.math.add(usize, offset_usize, length_usize) catch {
            ctx.interpreter.halt(.memory_limit_oog);
            return;
        }
    else
        offset_usize;

    // Dynamic: word cost — std.math.divCeil avoids (length + 31) overflow when
    // length_usize is near maxInt(usize) (e.g. from GASLIMIT with maxInt gas limit).
    const num_words: u64 = @intCast(std.math.divCeil(usize, length_usize, 32) catch unreachable);
    const word_cost = gas_costs.G_KECCAK256WORD * num_words;
    if (!ctx.interpreter.gas.spend(word_cost)) {
        ctx.interpreter.halt(.out_of_gas);
        return;
    }

    // Dynamic: memory expansion
    if (length_usize > 0) {
        const current_words = (ctx.interpreter.memory.size() + 31) / 32;
        // std.math.divCeil avoids (end + 31) overflow when end is near maxInt(usize).
        const new_words = std.math.divCeil(usize, end, 32) catch unreachable;
        if (new_words > current_words) {
            const expansion_cost = memoryCostWords(new_words) - memoryCostWords(current_words);
            if (!ctx.interpreter.gas.spend(expansion_cost)) {
                ctx.interpreter.halt(.out_of_gas);
                return;
            }
        }
        const aligned_end = new_words * 32;
        if (aligned_end > ctx.interpreter.memory.size()) {
            const old_size = ctx.interpreter.memory.size();
            ctx.interpreter.memory.buffer.resize(alloc_mod.get(), aligned_end) catch {
                ctx.interpreter.halt(.memory_limit_oog);
                return;
            };
            @memset(ctx.interpreter.memory.buffer.items[old_size..aligned_end], 0);
        }
    }

    const data = if (length_usize > 0)
        ctx.interpreter.memory.buffer.items[offset_usize..end]
    else
        &[_]u8{};

    var hash: [32]u8 = undefined;
    const accel = @import("accelerators");
    accel.keccak256(data, &hash);

    const U = primitives.U256;
    const value: U = (@as(U, std.mem.readInt(u64, hash[0..8], .big)) << 192) |
        (@as(U, std.mem.readInt(u64, hash[8..16], .big)) << 128) |
        (@as(U, std.mem.readInt(u64, hash[16..24], .big)) << 64) |
        @as(U, std.mem.readInt(u64, hash[24..32], .big));

    stack.shrinkUnsafe(1);
    stack.setTopUnsafe().* = value;
}

test {
    _ = @import("keccak_tests.zig");
}
