/// Minimal HTTP/1.1 JSON-RPC server for Hive consume-rlp.
///
/// Listens on :8545. Handles only:
///   eth_blockNumber          → hex block number (liveness probe)
///   eth_getBlockByNumber     → { "hash", "number", "coinbase", "stateRoot", "gasLimit", "timestamp", "extraData" }
const std = @import("std");
const Chain = @import("chain.zig").Chain;

pub fn serve(chain: *Chain) !void {
    const addr = try std.net.Address.parseIp4("0.0.0.0", 8545);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();

    while (true) {
        const conn = server.accept() catch continue;
        defer conn.stream.close();
        handleConn(chain, conn.stream) catch {};
    }
}

fn handleConn(chain: *Chain, stream: std.net.Stream) !void {
    // Arena lives for the entire connection so that the RPC response string
    // (allocated inside processRpc) remains valid until after writeAll.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var buf: [65536]u8 = undefined;
    var total: usize = 0;

    // Read until we have a complete HTTP request (headers + body)
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) break;
        total += n;

        // Check if we have full headers (\r\n\r\n)
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
    }
    const raw = buf[0..total];

    // Find headers / body split
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return;
    const headers_str = raw[0..header_end];
    const body_start = header_end + 4;

    // Parse Content-Length
    var content_length: usize = 0;
    var lines = std.mem.splitScalar(u8, headers_str, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
            const val = std.mem.trim(u8, trimmed["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, val, 10) catch 0;
        }
    }

    // Read remaining body bytes if needed
    while (total - body_start < content_length and total < buf.len) {
        const n = stream.read(buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }

    const body = buf[body_start..@min(body_start + content_length, total)];
    const response_body = processRpc(chain, alloc, body);

    // Write HTTP 200 response
    var resp_buf: [4096]u8 = undefined;
    const resp = std.fmt.bufPrint(
        &resp_buf,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{s}",
        .{ response_body.len, response_body },
    ) catch return;
    _ = stream.writeAll(resp) catch {};
}

fn processRpc(chain: *Chain, alloc: std.mem.Allocator, body: []const u8) []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, body, .{}) catch
        return errorResponse("-32700", "Parse error");
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return errorResponse("-32600", "Invalid Request"),
    };

    const id = root.get("id") orelse std.json.Value{ .integer = 0 };
    const method = switch (root.get("method") orelse return errorResponse("-32600", "Missing method")) {
        .string => |s| s,
        else => return errorResponse("-32600", "Invalid method"),
    };

    const id_str = jsonValueToIdStr(alloc, id);

    if (std.mem.eql(u8, method, "eth_blockNumber")) {
        const latest = chain.getLatest() orelse return buildResponse(alloc, id_str, "\"0x0\"");
        const result = std.fmt.allocPrint(alloc, "\"0x{x}\"", .{latest.number}) catch return "{}";
        return buildResponse(alloc, id_str, result);
    }

    if (std.mem.eql(u8, method, "eth_getBlockByNumber")) {
        const params = switch (root.get("params") orelse return nullResponse(alloc, id_str)) {
            .array => |a| a,
            else => return nullResponse(alloc, id_str),
        };
        if (params.items.len == 0) return nullResponse(alloc, id_str);

        const tag = switch (params.items[0]) {
            .string => |s| s,
            else => return nullResponse(alloc, id_str),
        };

        const stored = resolveBlock(chain, tag) orelse return nullResponse(alloc, id_str);
        const result = buildBlockObject(alloc, stored) catch return "{}";
        return buildResponse(alloc, id_str, result);
    }

    return errorResponse("-32601", "Method not found");
}

fn buildBlockObject(alloc: std.mem.Allocator, s: @import("chain.zig").StoredHeader) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8){};
    const w = buf.writer(alloc);
    try w.writeAll("{");
    try w.print("\"hash\":\"0x{x}\"", .{s.hash});
    try w.print(",\"number\":\"0x{x}\"", .{s.number});
    try w.print(",\"coinbase\":\"0x{x}\"", .{s.coinbase});
    try w.print(",\"stateRoot\":\"0x{x}\"", .{s.state_root});
    try w.print(",\"gasLimit\":\"0x{x}\"", .{s.gas_limit});
    try w.print(",\"timestamp\":\"0x{x}\"", .{s.timestamp});
    const extra_hex = bytesToHex(alloc, s.extra_data);
    try w.print(",\"extraData\":\"{s}\"", .{extra_hex});
    if (s.base_fee) |v| try w.print(",\"baseFeePerGas\":\"0x{x}\"", .{v});
    if (s.withdrawals_root) |v| try w.print(",\"withdrawalsRoot\":\"0x{x}\"", .{v});
    if (s.blob_gas_used) |v| try w.print(",\"blobGasUsed\":\"0x{x}\"", .{v});
    if (s.excess_blob_gas) |v| try w.print(",\"excessBlobGas\":\"0x{x}\"", .{v});
    if (s.parent_beacon_block_root) |v| try w.print(",\"parentBeaconBlockRoot\":\"0x{x}\"", .{v});
    if (s.requests_hash) |v| try w.print(",\"requestsHash\":\"0x{x}\"", .{v});
    if (s.block_access_list_hash) |v| try w.print(",\"blockAccessListHash\":\"0x{x}\"", .{v});
    if (s.slot_number) |v| try w.print(",\"slotNumber\":\"0x{x}\"", .{v});
    try w.writeAll("}");
    return buf.toOwnedSlice(alloc);
}

fn bytesToHex(alloc: std.mem.Allocator, bytes: []const u8) []const u8 {
    const hex_chars = "0123456789abcdef";
    const out = alloc.alloc(u8, 2 + bytes.len * 2) catch return "0x";
    out[0] = '0';
    out[1] = 'x';
    for (bytes, 0..) |b, i| {
        out[2 + i * 2] = hex_chars[b >> 4];
        out[2 + i * 2 + 1] = hex_chars[b & 0xf];
    }
    return out;
}

fn resolveBlock(chain: *Chain, tag: []const u8) ?@import("chain.zig").StoredHeader {
    if (std.mem.eql(u8, tag, "latest") or std.mem.eql(u8, tag, "pending"))
        return chain.getLatest();
    if (std.mem.eql(u8, tag, "earliest"))
        return chain.getByNumber(0);

    // Hex block number
    const s = if (std.mem.startsWith(u8, tag, "0x") or std.mem.startsWith(u8, tag, "0X"))
        tag[2..]
    else
        tag;
    const n = std.fmt.parseInt(u64, s, 16) catch return null;
    return chain.getByNumber(n);
}

fn jsonValueToIdStr(alloc: std.mem.Allocator, id: std.json.Value) []const u8 {
    return switch (id) {
        .integer => |n| std.fmt.allocPrint(alloc, "{}", .{n}) catch "0",
        .string => |s| std.fmt.allocPrint(alloc, "\"{s}\"", .{s}) catch "\"\"",
        .null => "null",
        else => "0",
    };
}

fn buildResponse(alloc: std.mem.Allocator, id: []const u8, result: []const u8) []const u8 {
    return std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id, result },
    ) catch "{}";
}

fn nullResponse(alloc: std.mem.Allocator, id: []const u8) []const u8 {
    return buildResponse(alloc, id, "null");
}

fn errorResponse(code: []const u8, message: []const u8) []const u8 {
    // Static buffer for error responses (no alloc needed)
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    return std.fmt.bufPrint(
        &S.buf,
        "{{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{{\"code\":{s},\"message\":\"{s}\"}}}}",
        .{ code, message },
    ) catch "{}";
}
