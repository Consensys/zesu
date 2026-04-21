/// Diagnostic JSON output helpers for blockchain test failures.
const std = @import("std");
const executor_types = @import("executor").executor_types;
const json_helpers = @import("json.zig");

const Address = executor_types.Address;
const AllocAccount = executor_types.AllocAccount;
const Receipt = executor_types.Receipt;
const AllocMap = std.AutoHashMapUnmanaged(Address, AllocAccount);

/// Escape a string for embedding inside a JSON string value.
pub fn writeJsonStr(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
            else => try w.writeByte(c),
        }
    }
}

/// Emit a JSON diagnostic for a transaction decode error.
pub fn writeTxDecodeError(
    w: anytype,
    test_name: []const u8,
    block_number: u64,
    err_name: []const u8,
    description: []const u8,
) !void {
    try w.writeAll("{\"test_output\":{\"test\":\"");
    try writeJsonStr(w, test_name);
    try w.print("\",\"error\":\"tx-decode block {}: {s}\",\"description\":\"", .{ block_number, err_name });
    try writeJsonStr(w, description);
    try w.writeAll("\"}}");
}

/// Emit a JSON diagnostic for a state-root / receipts-root mismatch.
pub fn writeBlockMismatch(
    alloc: std.mem.Allocator,
    w: anytype,
    test_name: []const u8,
    description: []const u8,
    state_ok: bool,
    receipts_ok: bool,
    expected_state_root: [32]u8,
    actual_state_root: [32]u8,
    expected_receipts_root: [32]u8,
    actual_receipts_root: [32]u8,
    fixture_block: std.json.ObjectMap,
    fixture_post_state: ?std.json.Value,
    result_receipts: []const Receipt,
    result_alloc: AllocMap,
) !void {
    try w.writeAll("{\"test_output\":{");
    try w.writeAll("\"test\":\"");
    try writeJsonStr(w, test_name);
    try w.print("\",\"state_ok\":{},\"receipts_ok\":{}", .{ state_ok, receipts_ok });
    try w.writeAll(",\"description\":\"");
    try writeJsonStr(w, description);
    try w.print("\",\"expected_state_root\":\"0x{x}\"", .{expected_state_root});
    try w.print(",\"actual_state_root\":\"0x{x}\"", .{actual_state_root});
    try w.print(",\"expected_receipts_root\":\"0x{x}\"", .{expected_receipts_root});
    try w.print(",\"actual_receipts_root\":\"0x{x}\"", .{actual_receipts_root});

    // Expected receipts from fixture.
    try w.writeAll(",\"expected_receipts\":[");
    if (fixture_block.get("receipts")) |rv| {
        if (rv == .array) {
            for (rv.array.items, 0..) |rec_v, i| {
                if (i > 0) try w.writeByte(',');
                if (rec_v != .object) {
                    try w.writeAll("{}");
                    continue;
                }
                const ro = rec_v.object;
                const ty_s = if (ro.get("type")) |tv| switch (tv) {
                    .string => |s| s,
                    else => "0x0",
                } else "0x0";
                const status_bool = if (ro.get("status")) |sv| switch (sv) {
                    .bool => |b| b,
                    .string => |s| !std.mem.eql(u8, s, "0x0"),
                    else => false,
                } else false;
                const gas_s = if (ro.get("cumulativeGasUsed")) |gv| switch (gv) {
                    .string => |s| s,
                    else => "0x0",
                } else "0x0";
                try w.print("{{\"type\":\"{s}\",\"status\":{},\"cumulativeGasUsed\":\"{s}\",\"logs\":[", .{ ty_s, status_bool, gas_s });
                if (ro.get("logs")) |lv| {
                    if (lv == .array) {
                        for (lv.array.items, 0..) |log_v, j| {
                            if (j > 0) try w.writeByte(',');
                            if (log_v != .object) {
                                try w.writeAll("{}");
                                continue;
                            }
                            const lo = log_v.object;
                            const addr_s = if (lo.get("address")) |av| switch (av) {
                                .string => |s| s,
                                else => "0x",
                            } else "0x";
                            try w.print("{{\"address\":\"{s}\",\"topics\":[", .{addr_s});
                            if (lo.get("topics")) |tv| {
                                if (tv == .array) {
                                    for (tv.array.items, 0..) |t_v, k| {
                                        if (k > 0) try w.writeByte(',');
                                        const t_s = switch (t_v) {
                                            .string => |s| s,
                                            else => "0x",
                                        };
                                        try w.print("\"{s}\"", .{t_s});
                                    }
                                }
                            }
                            const data_s = if (lo.get("data")) |dv| switch (dv) {
                                .string => |s| s,
                                else => "0x",
                            } else "0x";
                            try w.print("],\"data\":\"{s}\"}}", .{data_s});
                        }
                    }
                }
                try w.writeAll("]}");
            }
        }
    }
    try w.writeByte(']');

    // Actual receipts from execution.
    try w.writeAll(",\"actual_receipts\":[");
    for (result_receipts, 0..) |r, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"type\":\"0x{x}\",\"status\":{},\"cumulativeGasUsed\":\"0x{x}\",\"logs\":[", .{ r.type, r.status, r.cumulative_gas_used });
        for (r.logs, 0..) |log, j| {
            if (j > 0) try w.writeByte(',');
            try w.print("{{\"address\":\"0x{x}\",\"topics\":[", .{log.address});
            for (log.topics, 0..) |topic, k| {
                if (k > 0) try w.writeByte(',');
                try w.print("\"0x{x}\"", .{topic});
            }
            try w.print("],\"data\":\"0x{x}\"}}", .{log.data});
        }
        try w.writeAll("]}");
    }
    try w.writeByte(']');

    // State comparison when state root mismatches.
    if (!state_ok) {
        // Expected post state from fixture.
        try w.writeAll(",\"expected_post_state\":{");
        if (fixture_post_state != null and fixture_post_state.? == .object) {
            var ps_it = fixture_post_state.?.object.iterator();
            var ps_first = true;
            while (ps_it.next()) |ps_entry| {
                if (!ps_first) try w.writeByte(',');
                ps_first = false;
                try w.writeByte('"');
                try writeJsonStr(w, ps_entry.key_ptr.*);
                try w.writeAll("\":{");
                const acct_obj = switch (ps_entry.value_ptr.*) {
                    .object => |o| o,
                    else => {
                        try w.writeByte('}');
                        continue;
                    },
                };
                const bal_s = if (acct_obj.get("balance")) |bv| switch (bv) {
                    .string => |s| s,
                    else => "0x0",
                } else "0x0";
                try w.print("\"balance\":\"{s}\"", .{bal_s});
                const nonce_s = if (acct_obj.get("nonce")) |nv| switch (nv) {
                    .string => |s| s,
                    else => "0x0",
                } else "0x0";
                try w.print(",\"nonce\":\"{s}\"", .{nonce_s});
                const code_hex = if (acct_obj.get("code")) |cv| switch (cv) {
                    .string => |s| s,
                    else => "0x",
                } else "0x";
                const code_bytes = json_helpers.hexToSlice(alloc, code_hex) catch &[_]u8{};
                var code_hash: [32]u8 = undefined;
                std.crypto.hash.sha3.Keccak256.hash(code_bytes, &code_hash, .{});
                try w.print(",\"codeHash\":\"0x{x}\"", .{code_hash});
                try w.writeAll(",\"storage\":{");
                if (acct_obj.get("storage")) |sv| {
                    if (sv == .object) {
                        var slot_it = sv.object.iterator();
                        var slot_first = true;
                        while (slot_it.next()) |slot_entry| {
                            if (!slot_first) try w.writeByte(',');
                            slot_first = false;
                            try w.writeByte('"');
                            try writeJsonStr(w, slot_entry.key_ptr.*);
                            try w.writeAll("\":\"");
                            const sv2 = switch (slot_entry.value_ptr.*) {
                                .string => |s| s,
                                else => "0x0",
                            };
                            try writeJsonStr(w, sv2);
                            try w.writeByte('"');
                        }
                    }
                }
                try w.writeAll("}}");
            }
        }
        try w.writeByte('}');

        // Actual post state from execution.
        try w.writeAll(",\"actual_post_state\":{");
        var alloc_it = result_alloc.iterator();
        var alloc_first = true;
        while (alloc_it.next()) |alloc_entry| {
            if (!alloc_first) try w.writeByte(',');
            alloc_first = false;
            try w.print("\"0x{x}\":{{", .{alloc_entry.key_ptr.*});
            const acct = alloc_entry.value_ptr.*;
            try w.print("\"balance\":\"0x{x}\"", .{acct.balance});
            try w.print(",\"nonce\":\"0x{x}\"", .{acct.nonce});
            var code_hash: [32]u8 = undefined;
            std.crypto.hash.sha3.Keccak256.hash(acct.code, &code_hash, .{});
            try w.print(",\"codeHash\":\"0x{x}\"", .{code_hash});
            try w.writeAll(",\"storage\":{");
            var stor_it = acct.storage.iterator();
            var stor_first = true;
            while (stor_it.next()) |stor_entry| {
                if (!stor_first) try w.writeByte(',');
                stor_first = false;
                try w.print("\"0x{x}\":\"0x{x}\"", .{ stor_entry.key_ptr.*, stor_entry.value_ptr.* });
            }
            try w.writeAll("}}");
        }
        try w.writeByte('}');
    }

    try w.writeAll("}}");
}

/// Emit a JSON diagnostic for a lastblockhash mismatch.
pub fn writeLastBlockHashMismatch(
    w: anytype,
    test_name: []const u8,
    expected: [32]u8,
    actual: [32]u8,
    description: []const u8,
) !void {
    try w.writeAll("{\"test_output\":{\"test\":\"");
    try writeJsonStr(w, test_name);
    try w.print("\",\"error\":\"lastblockhash\",\"expected\":\"0x{x}\",\"actual\":\"0x{x}\",\"description\":\"", .{ expected, actual });
    try writeJsonStr(w, description);
    try w.writeAll("\"}}");
}
