const std = @import("std");
const primitives = @import("primitives");
const Context = @import("context.zig").Context;
const alloc_mod = @import("zesu_allocator");

/// Main EVM structure that contains all data needed for execution.
pub const Evm = struct {
    /// Context of the EVM it is used to fetch data from database.
    ctx: Context,
    /// Inspector of the EVM it is used to inspect the EVM.
    inspector: void,
    /// Instructions provider of the EVM it is used to execute instructions.
    instruction: void,
    /// Precompile provider of the EVM it is used to execute precompiles.
    precompiles: void,
    /// Frame that is going to be executed.
    frame_stack: FrameStack,

    /// Create a new EVM instance with a given context, instruction set, and precompile provider.
    ///
    /// Inspector will be set to `{}`.
    pub fn new(ctx: Context, instruction: anytype, precompiles: anytype) Evm {
        return Evm{
            .ctx = ctx,
            .inspector = {},
            .instruction = instruction,
            .precompiles = precompiles,
            .frame_stack = FrameStack.newPrealloc(8),
        };
    }

    /// Create a new EVM instance with a given context, inspector, instruction set, and precompile provider.
    pub fn newWithInspector(ctx: Context, inspector: anytype, instruction: anytype, precompiles: anytype) Evm {
        return Evm{
            .ctx = ctx,
            .inspector = inspector,
            .instruction = instruction,
            .precompiles = precompiles,
            .frame_stack = FrameStack.newPrealloc(8),
        };
    }

    /// Consumed self and returns new Evm type with given Inspector.
    pub fn withInspector(self: Evm, inspector: anytype) Evm {
        return Evm{
            .ctx = self.ctx,
            .inspector = inspector,
            .instruction = self.instruction,
            .precompiles = self.precompiles,
            .frame_stack = self.frame_stack,
        };
    }

    /// Consumes self and returns new Evm type with given Precompiles.
    pub fn withPrecompiles(self: Evm, precompiles: anytype) Evm {
        return Evm{
            .ctx = self.ctx,
            .inspector = self.inspector,
            .instruction = self.instruction,
            .precompiles = precompiles,
            .frame_stack = self.frame_stack,
        };
    }

    /// Consumes self and returns inner Inspector.
    pub fn intoInspector(self: Evm) void {
        return self.inspector;
    }

    /// Get context reference
    pub fn getCtx(self: Evm) *const Context {
        return &self.ctx;
    }

    /// Get context reference mutably
    pub fn getCtxMut(self: *Evm) *Context {
        return &self.ctx;
    }

    /// Get inspector reference
    pub fn getInspector(self: Evm) *const @TypeOf(self.inspector) {
        return &self.inspector;
    }

    /// Get inspector reference mutably
    pub fn getInspectorMut(self: *Evm) *@TypeOf(self.inspector) {
        return &self.inspector;
    }

    /// Get instruction reference
    pub fn getInstruction(self: Evm) *const @TypeOf(self.instruction) {
        return &self.instruction;
    }

    /// Get instruction reference mutably
    pub fn getInstructionMut(self: *Evm) *@TypeOf(self.instruction) {
        return &self.instruction;
    }

    /// Get precompiles reference
    pub fn getPrecompiles(self: Evm) *const @TypeOf(self.precompiles) {
        return &self.precompiles;
    }

    /// Get precompiles reference mutably
    pub fn getPrecompilesMut(self: *Evm) *@TypeOf(self.precompiles) {
        return &self.precompiles;
    }

    /// Get frame stack reference
    pub fn getFrameStack(self: Evm) *const @TypeOf(self.frame_stack) {
        return &self.frame_stack;
    }

    /// Get frame stack reference mutably
    pub fn getFrameStackMut(self: *Evm) *@TypeOf(self.frame_stack) {
        return &self.frame_stack;
    }
};

/// Frame stack for EVM execution
pub const FrameStack = struct {
    frames: ?std.ArrayList(Frame),
    max_depth: usize,

    pub fn newPrealloc(max_depth: usize) FrameStack {
        return .{
            .frames = null,
            .max_depth = max_depth,
        };
    }

    pub fn deinit(self: *FrameStack) void {
        self.frames.deinit();
    }

    pub fn push(self: *FrameStack, frame: Frame) !void {
        if (self.frames.items.len >= self.max_depth) {
            return error.MaxDepthExceeded;
        }
        try self.frames.append(frame);
    }

    pub fn pop(self: *FrameStack) ?Frame {
        return self.frames.popOrNull();
    }

    pub fn peek(self: FrameStack) ?Frame {
        return if (self.frames.items.len > 0) self.frames.items[self.frames.items.len - 1] else null;
    }

    pub fn len(self: FrameStack) usize {
        return self.frames.items.len;
    }

    pub fn isEmpty(self: FrameStack) bool {
        return self.frames.items.len == 0;
    }

    pub fn clear(self: *FrameStack) void {
        self.frames.clearRetainingCapacity();
    }
};

/// Frame for EVM execution
pub const Frame = struct {
    /// Program counter
    pc: usize,
    /// Stack
    stack: std.ArrayList(primitives.U256),
    /// Memory
    memory: std.ArrayList(u8),
    /// Gas remaining
    gas: u64,
    /// Return data
    return_data: std.ArrayList(u8),
    /// Caller address
    caller: primitives.Address,
    /// Target address
    target: primitives.Address,
    /// Value being transferred
    value: primitives.U256,
    /// Input data
    input: std.ArrayList(u8),
    /// Code being executed
    code: std.ArrayList(u8),
    /// Is static call
    is_static: bool,
    /// Call depth
    depth: usize,

    pub fn new(caller: primitives.Address, target: primitives.Address, value: primitives.U256, input: []const u8, code: []const u8, gas: u64, is_static: bool, depth: usize) Frame {
        _ = input;
        _ = code;
        return .{
            .pc = 0,
            .stack = std.ArrayList(primitives.U256).init(alloc_mod.get()),
            .memory = std.ArrayList(u8).init(alloc_mod.get()),
            .gas = gas,
            .return_data = std.ArrayList(u8).init(alloc_mod.get()),
            .caller = caller,
            .target = target,
            .value = value,
            .input = std.ArrayList(u8).init(alloc_mod.get()),
            .code = std.ArrayList(u8).init(alloc_mod.get()),
            .is_static = is_static,
            .depth = depth,
        };
    }

    pub fn deinit(self: *Frame) void {
        self.stack.deinit();
        self.memory.deinit();
        self.return_data.deinit();
        self.input.deinit();
        self.code.deinit();
    }

    pub fn init(self: *Frame, caller: primitives.Address, target: primitives.Address, value: primitives.U256, input: []const u8, code: []const u8, gas: u64, is_static: bool, depth: usize) !void {
        self.pc = 0;
        self.gas = gas;
        self.caller = caller;
        self.target = target;
        self.value = value;
        self.is_static = is_static;
        self.depth = depth;

        try self.input.appendSlice(input);
        try self.code.appendSlice(code);
    }

    pub fn pushStack(self: *Frame, value: primitives.U256) !void {
        if (self.stack.items.len >= 1024) {
            return error.StackOverflow;
        }
        try self.stack.append(value);
    }

    pub fn popStack(self: *Frame) ?primitives.U256 {
        return self.stack.popOrNull();
    }

    pub fn peekStack(self: Frame, index: usize) ?primitives.U256 {
        if (index < self.stack.items.len) {
            return self.stack.items[self.stack.items.len - 1 - index];
        }
        return null;
    }

    pub fn stackLen(self: Frame) usize {
        return self.stack.items.len;
    }

    pub fn expandMemory(self: *Frame, size: usize) !void {
        if (size > self.memory.items.len) {
            try self.memory.resize(size);
        }
    }

    pub fn getMemory(self: Frame, offset: usize, size: usize) ?[]const u8 {
        if (offset + size <= self.memory.items.len) {
            return self.memory.items[offset .. offset + size];
        }
        return null;
    }

    pub fn setMemory(self: *Frame, offset: usize, data: []const u8) !void {
        if (offset + data.len > self.memory.items.len) {
            try self.memory.resize(offset + data.len);
        }
        std.mem.copy(u8, self.memory.items[offset .. offset + data.len], data);
    }

    pub fn setReturnData(self: *Frame, data: []const u8) !void {
        self.return_data.clearRetainingCapacity();
        try self.return_data.appendSlice(data);
    }

    pub fn getReturnData(self: Frame) []const u8 {
        return self.return_data.items;
    }

    pub fn consumeGas(self: *Frame, amount: u64) bool {
        if (self.gas >= amount) {
            self.gas -= amount;
            return true;
        }
        return false;
    }

    pub fn refundGas(self: *Frame, amount: u64) void {
        self.gas += amount;
    }

    pub fn getGas(self: Frame) u64 {
        return self.gas;
    }

    pub fn setPc(self: *Frame, pc: usize) void {
        self.pc = pc;
    }

    pub fn getPc(self: Frame) usize {
        return self.pc;
    }

    pub fn incrementPc(self: *Frame) void {
        self.pc += 1;
    }

    pub fn jumpTo(self: *Frame, pc: usize) void {
        self.pc = pc;
    }

    pub fn getCaller(self: Frame) primitives.Address {
        return self.caller;
    }

    pub fn getTarget(self: Frame) primitives.Address {
        return self.target;
    }

    pub fn getValue(self: Frame) primitives.U256 {
        return self.value;
    }

    pub fn getInput(self: Frame) []const u8 {
        return self.input.items;
    }

    pub fn getCode(self: Frame) []const u8 {
        return self.code.items;
    }

    pub fn isStatic(self: Frame) bool {
        return self.is_static;
    }

    pub fn getDepth(self: Frame) usize {
        return self.depth;
    }
};
