//! Mojang's session server, as far as servers ask it while players join: who a player is. Every
//! server in the bench encrypts its sessions, as servers open to the internet do, which vanilla
//! and the servers built on it do only in online mode, where they ask the session server who each
//! joining player is. Pointed here, they learn each bot is who it said it is, under the UUID
//! offline mode would give it, with no account and nothing leaving the machine.
//!
//! Authlib takes the session, services and profiles hosts from system properties, and only all
//! three together, so this answers for all of them: the services' signing keys, none, as no
//! profile here is signed.

const std = @import("std");
const linux = std.os.linux;
const config = @import("config.zig");

const log = std.log.scoped(.session_server);

/// The JVM properties that point authlib here.
pub const java_properties = [_][]const u8{
    std.fmt.comptimePrint("-Dminecraft.api.session.host=http://127.0.0.1:{d}", .{config.session_port}),
    std.fmt.comptimePrint("-Dminecraft.api.services.host=http://127.0.0.1:{d}", .{config.session_port}),
    std.fmt.comptimePrint("-Dminecraft.api.profiles.host=http://127.0.0.1:{d}", .{config.session_port}),
};

/// The players who joined, by UUID, for the servers that look their profiles up after. Bots are
/// named for their index, so the table holds each, as the most bots a run has.
const Joined = struct { uuid: u128 = 0, name: [16]u8 = undefined, name_len: u8 = 0 };
var joined: [1024]Joined = @splat(.{});

/// Listens on the session port and answers on a thread of its own until the bench exits.
pub fn start() !void {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(socket);
    errdefer _ = linux.close(fd);
    const one: i32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, std.mem.asBytes(&one), @sizeOf(i32));
    const address: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, config.session_port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.SessionPortInUse;
    if (linux.errno(linux.listen(fd, 128)) != .SUCCESS) return error.ListenFailed;
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, serve, .{fd});
    thread.detach();
}

fn serve(fd: linux.fd_t) void {
    while (true) {
        const accepted = linux.accept4(fd, null, null, linux.SOCK.CLOEXEC);
        switch (linux.errno(accepted)) {
            .SUCCESS => {},
            .INTR, .AGAIN, .CONNABORTED => continue,
            else => return,
        }
        const client: linux.fd_t = @intCast(accepted);
        answer(client) catch |err| log.warn("request failed: {s}", .{@errorName(err)});
        _ = linux.close(client);
    }
}

/// Answers one request, then closes, as each says it may.
fn answer(client: linux.fd_t) !void {
    var request: [4096]u8 = undefined;
    var filled: usize = 0;
    while (std.mem.indexOf(u8, request[0..filled], "\r\n\r\n") == null) {
        if (filled == request.len) return error.RequestTooLarge;
        const result = linux.read(client, request[filled..].ptr, request.len - filled);
        switch (linux.errno(result)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.ReadFailed,
        }
        if (result == 0) return error.Truncated;
        filled += result;
    }
    const line_end = std.mem.indexOf(u8, request[0..filled], "\r\n").?;
    var parts = std.mem.splitScalar(u8, request[0..line_end], ' ');
    _ = parts.next();
    const target = parts.next() orelse return error.InvalidRequest;
    var body_buffer: [512]u8 = undefined;
    const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
    const body: ?[]const u8 = if (std.mem.eql(u8, path, "/session/minecraft/hasJoined")) joined: {
        const name = parameter(target, "username") orelse return error.InvalidRequest;
        if (name.len == 0 or name.len > 16) return error.InvalidRequest;
        const uuid = offlineUuid(name);
        const slot = &joined[@intCast(uuid % joined.len)];
        slot.* = .{ .uuid = uuid, .name_len = @intCast(name.len) };
        @memcpy(slot.name[0..name.len], name);
        break :joined try std.fmt.bufPrint(&body_buffer, "{{\"id\":\"{x:0>32}\",\"name\":\"{s}\",\"properties\":[]}}", .{ uuid, name });
    } else if (std.mem.startsWith(u8, path, "/session/minecraft/profile/")) profile: {
        const uuid = std.fmt.parseInt(u128, path["/session/minecraft/profile/".len..], 16) catch return error.InvalidRequest;
        const slot = &joined[@intCast(uuid % joined.len)];
        if (slot.uuid != uuid) break :profile null;
        break :profile try std.fmt.bufPrint(&body_buffer, "{{\"id\":\"{x:0>32}\",\"name\":\"{s}\",\"properties\":[]}}", .{ uuid, slot.name[0..slot.name_len] });
    } else if (std.mem.eql(u8, path, "/publickeys"))
        "{\"profilePropertyKeys\":[],\"playerCertificateKeys\":[]}"
    else
        null;
    var response: [1024]u8 = undefined;
    const text = if (body) |json|
        try std.fmt.bufPrint(&response, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ json.len, json })
    else no_content: {
        log.warn("unanswered request for {s}", .{path});
        break :no_content try std.fmt.bufPrint(&response, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{});
    };
    var sent: usize = 0;
    while (sent < text.len) {
        const result = linux.write(client, text[sent..].ptr, text.len - sent);
        switch (linux.errno(result)) {
            .SUCCESS => sent += result,
            .INTR => continue,
            else => return error.WriteFailed,
        }
    }
}

/// A query parameter's value. Player names need no decoding.
fn parameter(target: []const u8, name: []const u8) ?[]const u8 {
    const query = target[(std.mem.indexOfScalar(u8, target, '?') orelse return null) + 1 ..];
    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equals], name)) return pair[equals + 1 ..];
    }
    return null;
}

/// The UUID a server in offline mode gives a player of this name.
pub fn offlineUuid(name: []const u8) u128 {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update("OfflinePlayer:");
    md5.update(name);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    digest[6] = (digest[6] & 0x0f) | 0x30;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    return std.mem.readInt(u128, &digest, .big);
}

test "a joining player is who it says, under its offline UUID" {
    try std.testing.expectEqualStrings("bot_3", parameter("/session/minecraft/hasJoined?username=bot_3&serverId=-1a2b", "username").?);
    try std.testing.expect(parameter("/publickeys", "username") == null);
    // Notch's offline UUID, as every offline server gives it.
    try std.testing.expectEqual(@as(u128, 0xb50ad385829d3141a2167e7d7539ba7f), offlineUuid("Notch"));
}
