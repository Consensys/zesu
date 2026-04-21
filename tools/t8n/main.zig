/// t8n — Ethereum State Transition Tool
///
/// Compatible with execution-spec-tests and geth's evm t8n interface.
///
/// Usage:
///   t8n [flags]
///
/// Input flags:
///   --input.alloc FILE    Pre-state allocation (default: alloc.json)
///   --input.env FILE      Block environment (default: env.json)
///   --input.txs FILE      Transactions (default: txs.json)
///
/// Output flags:
///   --output.basedir DIR  Base directory for output files
///   --output.alloc FILE   Post-state allocation (default: alloc.json)
///   --output.result FILE  Execution result (default: result.json)
///   --output.body FILE    RLP-encoded transactions (optional, stub)
///
/// Execution flags:
///   --state.fork FORK     Fork name (default: Cancun)
///   --state.chainid N     Chain ID (default: 1)
///   --state.reward N      Mining reward in wei, -1 to disable (default: -1)
///
/// Special file values: "stdout" or "stderr" write to those streams.
/// When multiple outputs go to stdout, they are combined as {"alloc":..., "result":...}.
const std = @import("std");

const input_mod = @import("input.zig");
const transition_mod = @import("executor").executor_transition;
const hardfork = @import("hardfork");
const output_mod = @import("output.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Arena for all parsing and transition work
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // ── Parse CLI flags ───────────────────────────────────────────────────────

    var input_alloc_path: []const u8 = "alloc.json";
    var input_env_path: []const u8 = "env.json";
    var input_txs_path: []const u8 = "txs.json";
    var output_basedir: ?[]const u8 = null;
    var output_alloc_path: []const u8 = "alloc.json";
    var output_result_path: []const u8 = "result.json";
    var output_body_path: ?[]const u8 = null;
    var state_fork: []const u8 = "Cancun";
    var state_chainid: u64 = 1;
    var state_reward: i64 = -1;
    var trace_enabled: bool = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // Handle --flag=value and --flag value forms
        const val = getFlag(arg, args, &i);

        if (matchFlag(arg, "--input.alloc")) {
            if (val) |v| input_alloc_path = v;
        } else if (matchFlag(arg, "--input.env")) {
            if (val) |v| input_env_path = v;
        } else if (matchFlag(arg, "--input.txs")) {
            if (val) |v| input_txs_path = v;
        } else if (matchFlag(arg, "--output.basedir")) {
            if (val) |v| output_basedir = v;
        } else if (matchFlag(arg, "--output.alloc")) {
            if (val) |v| output_alloc_path = v;
        } else if (matchFlag(arg, "--output.result")) {
            if (val) |v| output_result_path = v;
        } else if (matchFlag(arg, "--output.body")) {
            if (val) |v| output_body_path = v;
        } else if (matchFlag(arg, "--state.fork")) {
            if (val) |v| state_fork = v;
        } else if (matchFlag(arg, "--state.chainid")) {
            if (val) |v| state_chainid = std.fmt.parseInt(u64, v, 10) catch 1;
        } else if (matchFlag(arg, "--state.reward")) {
            if (val) |v| state_reward = std.fmt.parseInt(i64, v, 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--trace")) {
            trace_enabled = true;
        }
    }
    if (trace_enabled) {
        std.debug.print("t8n: --trace flag noted; EIP-3155 tracing not yet implemented\n", .{});
    }

    // ── Resolve fork ──────────────────────────────────────────────────────────

    const spec = hardfork.specFromFork(state_fork) orelse {
        std.debug.print("t8n: unknown fork: {s}\n", .{state_fork});
        std.process.exit(3);
    };

    // ── Read and parse inputs ─────────────────────────────────────────────────

    const alloc_json = readFile(arena, input_alloc_path) catch |err| {
        std.debug.print("t8n: cannot read alloc '{s}': {}\n", .{ input_alloc_path, err });
        std.process.exit(11);
    };
    const env_json = readFile(arena, input_env_path) catch |err| {
        std.debug.print("t8n: cannot read env '{s}': {}\n", .{ input_env_path, err });
        std.process.exit(11);
    };
    const txs_json = readFile(arena, input_txs_path) catch |err| {
        std.debug.print("t8n: cannot read txs '{s}': {}\n", .{ input_txs_path, err });
        std.process.exit(11);
    };

    const pre_alloc = input_mod.parseAlloc(arena, alloc_json) catch |err| {
        std.debug.print("t8n: cannot parse alloc: {}\n", .{err});
        std.process.exit(10);
    };
    const env = input_mod.parseEnv(arena, env_json) catch |err| {
        std.debug.print("t8n: cannot parse env: {}\n", .{err});
        std.process.exit(10);
    };
    const txs = input_mod.parseTxs(arena, txs_json) catch |err| {
        std.debug.print("t8n: cannot parse txs: {}\n", .{err});
        std.process.exit(10);
    };

    // ── Run state transition ──────────────────────────────────────────────────

    const result = transition_mod.transition(
        arena,
        pre_alloc,
        env,
        txs,
        spec,
        state_chainid,
        state_reward,
    ) catch |err| {
        std.debug.print("t8n: transition failed: {}\n", .{err});
        std.process.exit(2);
    };

    // ── Write outputs ─────────────────────────────────────────────────────────

    const alloc_out = resolveOutputPath(arena, output_basedir, output_alloc_path) catch output_alloc_path;
    const result_out = resolveOutputPath(arena, output_basedir, output_result_path) catch output_result_path;

    // Determine if any outputs go to stdout (combined mode)
    const alloc_stdout = std.mem.eql(u8, alloc_out, "stdout");
    const result_stdout = std.mem.eql(u8, result_out, "stdout");

    const stdout_file = std.fs.File{ .handle = 1 };

    if (alloc_stdout and result_stdout) {
        // Combined stdout mode — buffer everything then write at once
        var out = std.ArrayListUnmanaged(u8){};
        const w = out.writer(arena);
        try w.writeAll("{\"alloc\": ");
        try output_mod.writeAllocJson(w, result.alloc);
        try w.writeAll(", \"result\": ");
        try output_mod.writeResultJson(arena, w, result, env.difficulty);
        try w.writeAll("}\n");
        try stdout_file.writeAll(out.items);
    } else {
        // Write alloc
        if (alloc_stdout) {
            var out = std.ArrayListUnmanaged(u8){};
            try output_mod.writeAllocJson(out.writer(arena), result.alloc);
            try stdout_file.writeAll(out.items);
        } else if (!std.mem.eql(u8, alloc_out, "")) {
            writeOutputFile(arena, alloc_out, result.alloc, result, env.difficulty, .alloc) catch |err| {
                std.debug.print("t8n: cannot write alloc '{s}': {}\n", .{ alloc_out, err });
                std.process.exit(11);
            };
        }

        // Write result
        if (result_stdout) {
            var out = std.ArrayListUnmanaged(u8){};
            try output_mod.writeResultJson(arena, out.writer(arena), result, env.difficulty);
            try stdout_file.writeAll(out.items);
        } else if (!std.mem.eql(u8, result_out, "")) {
            writeOutputFile(arena, result_out, result.alloc, result, env.difficulty, .result) catch |err| {
                std.debug.print("t8n: cannot write result '{s}': {}\n", .{ result_out, err });
                std.process.exit(11);
            };
        }
    }

    // output.body: stub — write empty RLP list
    if (output_body_path) |body_path| {
        const body_out = resolveOutputPath(arena, output_basedir, body_path) catch body_path;
        if (!std.mem.eql(u8, body_out, "stdout") and !std.mem.eql(u8, body_out, "")) {
            if (ensureParentDir(body_out)) {
                const f = std.fs.cwd().createFile(body_out, .{}) catch null;
                if (f) |file| {
                    defer file.close();
                    // Empty RLP list: 0xc0
                    file.writeAll("\"0xc0\"\n") catch {};
                }
            }
        }
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

const OutputKind = enum { alloc, result };

fn writeOutputFile(
    arena: std.mem.Allocator,
    path: []const u8,
    alloc_map: std.AutoHashMapUnmanaged(input_mod.Address, input_mod.AllocAccount),
    result: transition_mod.TransitionResult,
    difficulty: u256,
    kind: OutputKind,
) !void {
    _ = ensureParentDir(path);
    // Buffer the JSON output, then write to file in one shot
    // (File.writer() in Zig 0.15 requires an explicit buffer; using ArrayList avoids that)
    var out = std.ArrayListUnmanaged(u8){};
    const w = out.writer(arena);
    switch (kind) {
        .alloc => try output_mod.writeAllocJson(w, alloc_map),
        .result => try output_mod.writeResultJson(arena, w, result, difficulty),
    }
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(out.items);
}

/// If path contains a directory component, create the directories.
fn ensureParentDir(path: []const u8) bool {
    const dir = std.fs.path.dirname(path) orelse return true;
    std.fs.cwd().makePath(dir) catch {};
    return true;
}

fn resolveOutputPath(
    arena: std.mem.Allocator,
    basedir: ?[]const u8,
    path: []const u8,
) ![]const u8 {
    // Special values pass through
    if (std.mem.eql(u8, path, "stdout") or
        std.mem.eql(u8, path, "stderr") or
        std.mem.eql(u8, path, "")) return path;

    const bd = basedir orelse return path;

    // Absolute paths ignore basedir
    if (std.fs.path.isAbsolute(path)) return path;

    return std.fs.path.join(arena, &.{ bd, path });
}

/// Read a file or stdin ("stdin" special value) into a heap-allocated buffer.
fn readFile(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "stdin")) {
        // POSIX: file descriptor 0 is stdin
        const stdin_file = std.fs.File{ .handle = 0 };
        return stdin_file.readToEndAlloc(arena, 64 * 1024 * 1024);
    }
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    return file.readToEndAlloc(arena, 64 * 1024 * 1024);
}

/// Check if arg matches a flag prefix (handles both --flag=value and --flag forms).
fn matchFlag(arg: []const u8, flag: []const u8) bool {
    if (std.mem.eql(u8, arg, flag)) return true;
    if (std.mem.startsWith(u8, arg, flag) and arg.len > flag.len and arg[flag.len] == '=') return true;
    return false;
}

/// Extract the value for a flag: either from --flag=VALUE or the next argument.
/// Advances `i` if consuming the next argument.
fn getFlag(arg: []const u8, args: []const []const u8, i: *usize) ?[]const u8 {
    // --flag=value form
    if (std.mem.indexOf(u8, arg, "=")) |eq| {
        if (eq < arg.len - 1) return arg[eq + 1 ..];
    }
    // --flag value form (consume next arg)
    if (i.* + 1 < args.len) {
        const next = args[i.* + 1];
        if (next.len == 0 or next[0] != '-') {
            i.* += 1;
            return next;
        }
        // Next arg starts with '-' but might still be a value (e.g. --state.reward -1)
        // Accept only if it looks like a negative number: '-' followed by a digit
        if (next.len > 2 and next[1] == '-' and std.ascii.isDigit(next[2])) {
            i.* += 1;
            return next;
        }
        if (next.len > 1 and std.ascii.isDigit(next[1])) {
            i.* += 1;
            return next;
        }
    }
    return null;
}
