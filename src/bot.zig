//! Protocol bots: each logs in, answers what the server asks of a client, and moves as its
//! scenario says. A bot decodes only the packets it checks, so the load it adds stays small next
//! to the server it measures. Bots are split across worker threads, each polling its own sockets.

const std = @import("std");
const linux = std.os.linux;
const protocols = @import("protocols");
const java = @import("minecraft_java");
const scenario = @import("scenario.zig");

const Version = protocols.version("26.2");
const Protocol = Version.Protocol;
pub const protocol_number = Version.protocol_number;

const assert = std.debug.assert;

/// Largest frame and decoded packet a bot accepts, as the vanilla client does.
const frame_maximum = (1 << 21) + 3;
const decoded_maximum = 8 * 1024 * 1024;
const output_capacity = 64 * 1024;
const tick_ns = 50 * std.time.ns_per_ms;
/// The chunks per tick a bot asks for after each batch, about what a vanilla client on a desktop
/// asks for. Servers cap it, vanilla at 64.
pub const chunks_per_tick: f32 = 25;
pub const entity_player = 156;
pub const entity_cow = 30;
pub const item_stone = 1;

pub const Counter = enum {
    bytes_in,
    bytes_out,
    packets_in,
    packets_out,
    chunks,
    chunk_bytes,
    unloads,
    /// Server teleports after the first: the server disagreed with where the bot moved.
    corrections,
    players_seen,
    entities_seen,
    cows_seen,
    entities_removed,
    edits,
    acks,
    /// The highest edit sequence the server acknowledged.
    acked_sequence,
    block_changes,
    keepalives,
    /// The world age from the last time update, and when it came.
    game_time,
    game_time_ns,
    joined_ns,
    spawned_ns,
    /// When the bot had its first chunk.
    first_chunk_ns,
    /// When the bot had the chunks of a full view around its spawn.
    viewed_ns,
    /// When the bot reached the place its scenario sends it to.
    arrived_ns,
};

/// Round trips of pings, in buckets a quarter of a power of two wide in microseconds, so any
/// percentile is within about 12% at every scale. Bots record into their own and the swarm adds
/// them up.
pub const Latency = struct {
    pub const buckets = 104;
    counts: [buckets]std.atomic.Value(u32) = @splat(.init(0)),

    pub fn bucket(us: u64) usize {
        if (us < 4) return @intCast(us);
        const octave: usize = 63 - @clz(us);
        const sub: usize = @intCast((us >> @intCast(octave - 2)) & 3);
        return @min(buckets - 1, (octave - 1) * 4 + sub);
    }

    /// The middle of a bucket, in milliseconds.
    pub fn milliseconds(index: usize) f64 {
        if (index < 4) return @as(f64, @floatFromInt(index)) / 1000;
        const octave = index / 4 + 1;
        const low: f64 = @floatFromInt(@as(u64, 4 + index % 4) << @intCast(octave - 2));
        const width: f64 = @floatFromInt(@as(u64, 1) << @intCast(octave - 2));
        return (low + width / 2) / 1000;
    }

    pub fn record(self: *Latency, us: u64) void {
        _ = self.counts[bucket(us)].fetchAdd(1, .monotonic);
    }
};

test "latency buckets order round trips and keep within an eighth" {
    var previous: usize = 0;
    for ([_]u64{ 0, 3, 4, 7, 8, 15, 1000, 1200, 50_000, 3_000_000 }) |us| {
        const index = Latency.bucket(us);
        try std.testing.expect(index >= previous);
        previous = index;
        if (us >= 8) try std.testing.expect(@abs(Latency.milliseconds(index) * 1000 - @as(f64, @floatFromInt(us))) <= @as(f64, @floatFromInt(us)) / 8);
    }
}

pub const Counters = struct {
    values: [@typeInfo(Counter).@"enum".field_names.len]std.atomic.Value(u64) = @splat(.init(0)),

    pub fn add(self: *Counters, counter: Counter, amount: u64) void {
        _ = self.values[@intFromEnum(counter)].fetchAdd(amount, .monotonic);
    }

    pub fn set(self: *Counters, counter: Counter, value: u64) void {
        self.values[@intFromEnum(counter)].store(value, .monotonic);
    }

    pub fn get(self: *const Counters, counter: Counter) u64 {
        return self.values[@intFromEnum(counter)].load(.monotonic);
    }

    /// Sets a moment once, so the first time something happened stays.
    pub fn mark(self: *Counters, counter: Counter, value: u64) void {
        _ = self.values[@intFromEnum(counter)].cmpxchgStrong(0, @max(1, value), .monotonic, .monotonic);
    }
};

pub const Traffic = struct { count: u64 = 0, wire_bytes: u64 = 0, decoded_bytes: u64 = 0 };

/// The name of a packet the server sends in play.
pub fn playPacketName(id: usize) []const u8 {
    const Names = Protocol.play.toClient.PacketName;
    inline for (@typeInfo(Names).@"enum".field_names) |name| {
        if (Protocol.play.toClient.packetId(@field(Names, name)) == id) return name;
    }
    return "unknown";
}

pub const Phase = enum(u8) { waiting, login, configuration, play, failed };

pub const Bot = struct {
    index: u32,
    name: [16]u8 = undefined,
    name_len: u8 = 0,
    fd: linux.fd_t = -1,
    phase: std.atomic.Value(Phase) = .init(.waiting),
    compressed: bool = false,
    threshold: usize = 0,
    input: []u8,
    filled: usize = 0,
    output: []u8,
    queued: usize = 0,
    entity: i32 = 0,
    spawned: bool = false,
    position: [3]f64 = @splat(0),
    yaw: f32 = 0,
    pitch: f32 = 0,
    on_ground: bool = true,
    /// Where the server first put the bot.
    origin: [3]f64 = @splat(0),
    /// Ticks since the bot spawned.
    ticks: u64 = 0,
    sequence: i32 = 0,
    flying: bool = false,
    stocked: bool = false,
    heading: f64 = 0,
    random: std.Random.DefaultPrng,
    failure: ?anyerror = null,
    reason: [160]u8 = undefined,
    reason_len: u8 = 0,
    counters: Counters = .{},
    latency: Latency = .{},
    /// When the bot may start joining, once the swarm admits it.
    due_ns: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    /// What the server sent before play, and in play by packet id: as it crossed the wire,
    /// compressed, and as decoded. Only the bot's worker writes these, so they are read after
    /// the swarm stops.
    setup: Traffic = .{},
    play: [256]Traffic = @splat(.{}),

    pub fn label(self: *const Bot) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn reasonText(self: *const Bot) []const u8 {
        return self.reason[0..self.reason_len];
    }

    fn fail(self: *Bot, err: anyerror, reason: []const u8) void {
        if (self.phase.load(.monotonic) == .failed) return;
        self.failure = err;
        var length: usize = 0;
        // Keep the readable part of a disconnect reason, whatever form it came in.
        for (reason) |byte| {
            if (length == self.reason.len) break;
            if (byte >= 32 and byte < 127) {
                self.reason[length] = byte;
                length += 1;
            }
        }
        self.reason_len = @intCast(length);
        self.phase.store(.failed, .release);
        self.close();
    }

    fn close(self: *Bot) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.fd = -1;
    }

    /// Queues one packet: the id and body in `packet`, framed as the connection expects.
    pub fn queue(self: *Bot, packet: []const u8) !void {
        assert(packet.len > 0);
        // Bots send small packets, always below the threshold, so they never compress.
        if (self.compressed) assert(packet.len < self.threshold);
        const length = packet.len + @intFromBool(self.compressed);
        var header: [4]u8 = undefined;
        const header_len = putVarint(&header, @intCast(length));
        if (self.queued + header_len + length > self.output.len) return error.OutputFull;
        @memcpy(self.output[self.queued..][0..header_len], header[0..header_len]);
        self.queued += header_len;
        if (self.compressed) {
            self.output[self.queued] = 0;
            self.queued += 1;
        }
        @memcpy(self.output[self.queued..][0..packet.len], packet);
        self.queued += packet.len;
        self.counters.add(.packets_out, 1);
    }

    fn flush(self: *Bot) !void {
        var sent: usize = 0;
        while (sent < self.queued) {
            const result = linux.write(self.fd, self.output[sent..].ptr, self.queued - sent);
            switch (linux.errno(result)) {
                .SUCCESS => sent += result,
                .AGAIN => break,
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
        self.counters.add(.bytes_out, sent);
        std.mem.copyForwards(u8, self.output[0 .. self.queued - sent], self.output[sent..self.queued]);
        self.queued -= sent;
    }

    fn connect(self: *Bot, address: linux.sockaddr.in, view_distance: u8) !void {
        const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
        self.fd = @intCast(socket);
        const one: i32 = 1;
        _ = linux.setsockopt(self.fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));
        while (true) {
            const result = linux.connect(self.fd, &address, @sizeOf(linux.sockaddr.in));
            switch (linux.errno(result)) {
                .SUCCESS => break,
                .INTR => continue,
                else => return error.ConnectFailed,
            }
        }
        const flags = linux.fcntl(self.fd, linux.F.GETFL, 0);
        _ = linux.fcntl(self.fd, linux.F.SETFL, flags | @as(usize, @bitCast(@as(isize, @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))))));
        self.phase.store(.login, .release);

        var buffer: [128]u8 = undefined;
        var packet: Packet = .init(&buffer, 0);
        packet.varint(protocol_number);
        packet.string("localhost");
        packet.int(u16, std.mem.bigToNative(u16, address.port));
        packet.varint(2);
        try self.queue(packet.bytes());

        packet = .init(&buffer, Protocol.login.toServer.packetId(.login_start));
        packet.string(self.label());
        packet.int(u128, offlineUuid(self.label()));
        try self.queue(packet.bytes());
        _ = view_distance;
    }

    /// Reads what the socket holds and handles every whole frame in it.
    fn receive(self: *Bot, worker: *Worker) !void {
        while (true) {
            if (self.filled == self.input.len) return error.FrameTooLarge;
            const result = linux.read(self.fd, self.input[self.filled..].ptr, self.input.len - self.filled);
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .AGAIN => break,
                .INTR => continue,
                else => return error.ReadFailed,
            }
            if (result == 0) return error.ConnectionClosed;
            self.filled += result;
            self.counters.add(.bytes_in, result);

            var start: usize = 0;
            while (start < self.filled) {
                const length, const prefix = readVarint(self.input[start..self.filled]) catch |err| switch (err) {
                    error.Incomplete => break,
                    else => return err,
                };
                if (length <= 0 or length > frame_maximum) return error.InvalidFrame;
                const end = start + prefix + @as(usize, @intCast(length));
                if (end > self.filled) break;
                try self.frame(worker, self.input[start + prefix .. end]);
                if (self.phase.load(.monotonic) == .failed) return;
                start = end;
            }
            std.mem.copyForwards(u8, self.input[0 .. self.filled - start], self.input[start..self.filled]);
            self.filled -= start;
        }
    }

    fn frame(self: *Bot, worker: *Worker, raw: []const u8) !void {
        self.counters.add(.packets_in, 1);
        if (self.index == 0 and self.phase.load(.monotonic) == .play) if (worker.swarm.config.dump) |fd| {
            var size: [4]u8 = undefined;
            std.mem.writeInt(u32, &size, @intCast(raw.len), .little);
            _ = linux.write(fd, &size, 4);
            _ = linux.write(fd, raw.ptr, raw.len);
        };
        var body = raw;
        if (self.compressed) {
            const length, const prefix = try readVarint(raw);
            body = raw[prefix..];
            if (length != 0) {
                if (length < 0 or length > decoded_maximum) return error.InvalidPacket;
                body = try worker.workspace.decompressor.decode(body, worker.decoded[0..@intCast(length)]);
            }
        }
        var reader: Reader = .{ .bytes = body };
        const id = try reader.varint();
        const traffic = if (self.phase.load(.monotonic) == .play and id >= 0 and id < self.play.len) &self.play[@intCast(id)] else &self.setup;
        traffic.count += 1;
        traffic.wire_bytes += raw.len;
        traffic.decoded_bytes += body.len;
        switch (self.phase.load(.monotonic)) {
            .login => try self.loginPacket(id, &reader),
            .configuration => try self.configurationPacket(id, &reader),
            .play => try self.playPacket(id, &reader, raw.len),
            .waiting, .failed => unreachable,
        }
    }

    fn loginPacket(self: *Bot, id: i32, reader: *Reader) !void {
        const In = Protocol.login.toClient;
        const Out = Protocol.login.toServer;
        var buffer: [256]u8 = undefined;
        if (id == In.packetId(.compress)) {
            const threshold = try reader.varint();
            self.compressed = threshold >= 0;
            self.threshold = @intCast(@max(threshold, 0));
        } else if (id == In.packetId(.success)) {
            var packet: Packet = .init(&buffer, Out.packetId(.login_acknowledged));
            try self.queue(packet.bytes());
            self.phase.store(.configuration, .release);
            try self.introduce();
        } else if (id == In.packetId(.login_plugin_request)) {
            var packet: Packet = .init(&buffer, Out.packetId(.login_plugin_response));
            packet.varint(try reader.varint());
            packet.boolean(false);
            try self.queue(packet.bytes());
        } else if (id == In.packetId(.cookie_request)) {
            var packet: Packet = .init(&buffer, Out.packetId(.cookie_response));
            packet.string(try reader.string());
            packet.boolean(false);
            try self.queue(packet.bytes());
        } else if (id == In.packetId(.encryption_begin)) {
            self.fail(error.OnlineMode, "the server asked for encryption, run it in offline mode");
        } else if (id == In.packetId(.disconnect)) {
            self.fail(error.LoginRejected, reader.rest());
        }
    }

    /// What a vanilla client sends as configuration starts: its brand and settings.
    fn introduce(self: *Bot) !void {
        const Out = Protocol.configuration.toServer;
        var buffer: [128]u8 = undefined;
        var packet: Packet = .init(&buffer, Out.packetId(.custom_payload));
        packet.string("minecraft:brand");
        packet.string("vanilla");
        try self.queue(packet.bytes());
        packet = .init(&buffer, Out.packetId(.settings));
        packet.string("en_us");
        packet.int(i8, @intCast(scenario.view_distance));
        packet.varint(0);
        packet.boolean(true);
        packet.int(u8, 0x7f);
        packet.varint(1);
        packet.boolean(false);
        packet.boolean(true);
        packet.varint(0);
        try self.queue(packet.bytes());
    }

    fn configurationPacket(self: *Bot, id: i32, reader: *Reader) !void {
        const In = Protocol.configuration.toClient;
        const Out = Protocol.configuration.toServer;
        var buffer: [512]u8 = undefined;
        if (id == In.packetId(.select_known_packs)) {
            // Claim every pack the server offers, as a vanilla client of the same release does.
            var packet: Packet = .init(&buffer, Out.packetId(.select_known_packs));
            packet.raw(reader.rest());
            try self.queue(packet.bytes());
        } else if (id == In.packetId(.keep_alive)) {
            var packet: Packet = .init(&buffer, Out.packetId(.keep_alive));
            packet.int(i64, try reader.int(i64));
            try self.queue(packet.bytes());
        } else if (id == In.packetId(.ping)) {
            var packet: Packet = .init(&buffer, Out.packetId(.pong));
            packet.int(i32, try reader.int(i32));
            try self.queue(packet.bytes());
        } else if (id == In.packetId(.cookie_request)) {
            var packet: Packet = .init(&buffer, Out.packetId(.cookie_response));
            packet.string(try reader.string());
            packet.boolean(false);
            try self.queue(packet.bytes());
        } else if (id == In.packetId(.code_of_conduct)) {
            var packet: Packet = .init(&buffer, Out.packetId(.accept_code_of_conduct));
            try self.queue(packet.bytes());
        } else if (id == In.packetId(.finish_configuration)) {
            var packet: Packet = .init(&buffer, Out.packetId(.finish_configuration));
            try self.queue(packet.bytes());
            self.phase.store(.play, .release);
            self.counters.mark(.joined_ns, now());
        } else if (id == In.packetId(.disconnect)) {
            self.fail(error.ConfigurationRejected, reader.rest());
        }
    }

    fn playPacket(self: *Bot, id: i32, reader: *Reader, frame_bytes: usize) !void {
        const In = Protocol.play.toClient;
        const Out = Protocol.play.toServer;
        var buffer: [256]u8 = undefined;
        if (id == In.packetId(.map_chunk)) {
            self.counters.add(.chunks, 1);
            self.counters.add(.chunk_bytes, frame_bytes);
            if (self.counters.get(.chunks) == 1) self.counters.mark(.first_chunk_ns, now());
            if (self.counters.get(.chunks) == scenario.viewChunks()) self.counters.mark(.viewed_ns, now());
        } else if (id == In.packetId(.chunk_batch_finished)) {
            var packet: Packet = .init(&buffer, Out.packetId(.chunk_batch_received));
            packet.int(u32, @bitCast(chunks_per_tick));
            try self.queue(packet.bytes());
        } else if (id == In.packetId(.unload_chunk)) {
            self.counters.add(.unloads, 1);
        } else if (id == In.packetId(.ping_response)) {
            const sent: u64 = @bitCast(try reader.int(i64));
            const moment = now();
            if (moment > sent) self.latency.record((moment - sent) / std.time.ns_per_us);
        } else if (id == In.packetId(.keep_alive)) {
            var packet: Packet = .init(&buffer, Out.packetId(.keep_alive));
            packet.int(i64, try reader.int(i64));
            try self.queue(packet.bytes());
            self.counters.add(.keepalives, 1);
        } else if (id == In.packetId(.ping)) {
            var packet: Packet = .init(&buffer, Out.packetId(.pong));
            packet.int(i32, try reader.int(i32));
            try self.queue(packet.bytes());
        } else if (id == In.packetId(.update_time)) {
            self.counters.set(.game_time, @bitCast(try reader.int(i64)));
            self.counters.set(.game_time_ns, now());
        } else if (id == In.packetId(.login)) {
            self.entity = try reader.int(i32);
        } else if (id == In.packetId(.position)) {
            try self.teleported(reader);
        } else if (id == In.packetId(.spawn_entity)) {
            _ = try reader.varint();
            _ = try reader.take(16);
            const kind = try reader.varint();
            self.counters.add(if (kind == entity_player) .players_seen else .entities_seen, 1);
            if (kind == entity_cow) self.counters.add(.cows_seen, 1);
        } else if (id == In.packetId(.entity_destroy)) {
            self.counters.add(.entities_removed, @intCast(@max(0, try reader.varint())));
        } else if (id == In.packetId(.acknowledge_player_digging)) {
            self.counters.add(.acks, 1);
            const sequence: u64 = @intCast(@max(0, try reader.varint()));
            if (sequence > self.counters.get(.acked_sequence)) self.counters.set(.acked_sequence, sequence);
        } else if (id == In.packetId(.block_change) or id == In.packetId(.multi_block_change)) {
            self.counters.add(.block_changes, 1);
        } else if (id == In.packetId(.start_configuration)) {
            var packet: Packet = .init(&buffer, Out.packetId(.configuration_acknowledged));
            try self.queue(packet.bytes());
            self.phase.store(.configuration, .release);
        } else if (id == In.packetId(.kick_disconnect)) {
            self.fail(error.Kicked, reader.rest());
        }
    }

    fn teleported(self: *Bot, reader: *Reader) !void {
        const Out = Protocol.play.toServer;
        const teleport = try reader.varint();
        var target: [3]f64 = undefined;
        for (&target) |*axis| axis.* = @bitCast(try reader.int(u64));
        for (0..3) |_| _ = try reader.int(u64);
        const yaw: f32 = @bitCast(try reader.int(u32));
        const pitch: f32 = @bitCast(try reader.int(u32));
        const relative = try reader.int(u32);
        for (0..3) |axis| self.position[axis] = if (relative & (@as(u32, 1) << @intCast(axis)) != 0) self.position[axis] + target[axis] else target[axis];
        self.yaw = if (relative & 8 != 0) self.yaw + yaw else yaw;
        self.pitch = if (relative & 16 != 0) self.pitch + pitch else pitch;

        var buffer: [64]u8 = undefined;
        var packet: Packet = .init(&buffer, Out.packetId(.teleport_confirm));
        packet.varint(teleport);
        try self.queue(packet.bytes());
        if (self.spawned) {
            self.counters.add(.corrections, 1);
        } else {
            self.spawned = true;
            self.origin = self.position;
            packet = .init(&buffer, Out.packetId(.player_loaded));
            try self.queue(packet.bytes());
            self.counters.mark(.spawned_ns, now());
        }
        try self.move(true);
    }

    /// Tells the server where the bot is, with its look when `look` is set.
    pub fn move(self: *Bot, look: bool) !void {
        const Out = Protocol.play.toServer;
        var buffer: [64]u8 = undefined;
        var packet: Packet = .init(&buffer, if (look) Out.packetId(.position_look) else Out.packetId(.position));
        for (self.position) |axis| packet.int(u64, @bitCast(axis));
        if (look) {
            packet.int(u32, @bitCast(self.yaw));
            packet.int(u32, @bitCast(self.pitch));
        }
        packet.int(u8, @intFromBool(self.on_ground));
        try self.queue(packet.bytes());
    }

    /// A ping request, once a second, which vanilla answers as its network thread reads it rather
    /// than in a tick, so it times how quickly the server's network side responds.
    pub fn ping(self: *Bot) !void {
        if ((self.ticks + self.index) % 20 != 0) return;
        var buffer: [16]u8 = undefined;
        var packet: Packet = .init(&buffer, Protocol.play.toServer.packetId(.ping_request));
        packet.int(i64, @bitCast(now()));
        try self.queue(packet.bytes());
    }

    pub fn endTick(self: *Bot) !void {
        var buffer: [8]u8 = undefined;
        var packet: Packet = .init(&buffer, Protocol.play.toServer.packetId(.tick_end));
        try self.queue(packet.bytes());
    }

    /// Starts creative flight, as a vanilla client does on a double jump.
    pub fn fly(self: *Bot) !void {
        if (self.flying) return;
        self.flying = true;
        self.on_ground = false;
        var buffer: [8]u8 = undefined;
        var packet: Packet = .init(&buffer, Protocol.play.toServer.packetId(.abilities));
        packet.int(i8, 2);
        try self.queue(packet.bytes());
    }

    /// Puts a stack of `item` in the first hotbar slot, the one a new player holds.
    pub fn stock(self: *Bot, item: i32) !void {
        if (self.stocked) return;
        self.stocked = true;
        var buffer: [32]u8 = undefined;
        var packet: Packet = .init(&buffer, Protocol.play.toServer.packetId(.set_creative_slot));
        packet.int(i16, 36);
        packet.varint(64);
        packet.varint(item);
        packet.varint(0);
        packet.varint(0);
        try self.queue(packet.bytes());
    }

    /// Places the held block on the top face of the block at `below`.
    pub fn place(self: *Bot, below: [3]i32) !void {
        self.sequence += 1;
        var buffer: [64]u8 = undefined;
        var packet: Packet = .init(&buffer, Protocol.play.toServer.packetId(.block_place));
        packet.varint(0);
        packet.int(i64, blockPosition(below));
        packet.varint(1);
        packet.int(u32, @bitCast(@as(f32, 0.5)));
        packet.int(u32, @bitCast(@as(f32, 1)));
        packet.int(u32, @bitCast(@as(f32, 0.5)));
        packet.boolean(false);
        packet.boolean(false);
        packet.varint(self.sequence);
        try self.queue(packet.bytes());
        self.counters.add(.edits, 1);
    }

    /// Breaks the block at `at`, which a creative player does at the first hit.
    pub fn dig(self: *Bot, at: [3]i32) !void {
        self.sequence += 1;
        var buffer: [32]u8 = undefined;
        var packet: Packet = .init(&buffer, Protocol.play.toServer.packetId(.block_dig));
        packet.varint(0);
        packet.int(i64, blockPosition(at));
        packet.int(i8, 1);
        packet.varint(self.sequence);
        try self.queue(packet.bytes());
        self.counters.add(.edits, 1);
    }
};

pub const Configuration = struct {
    port: u16,
    kind: scenario.Kind,
    /// Time between two bots starting to join.
    join_interval_ns: u64,
    /// A file the first bot appends every frame it gets in play to, as a little endian length
    /// and the frame as it crossed the wire, for looking at what servers send.
    dump: ?linux.fd_t = null,
};

/// The bots of one thread and the scratch they share.
const Worker = struct {
    swarm: *Swarm,
    first: usize,
    last: usize,
    decoded: []u8,
    workspace: java.Wire.Workspace,
    descriptors: []linux.pollfd,
    owners: []u32,
    thread: ?std.Thread = null,

    fn run(self: *Worker) void {
        const swarm = self.swarm;
        var next_tick = swarm.started_ns;
        var tick: u64 = 0;
        while (!swarm.stopping.load(.acquire)) {
            const moment = now();
            var next_join: u64 = std.math.maxInt(u64);
            for (swarm.bots[self.first..self.last]) |*bot| {
                if (bot.phase.load(.monotonic) != .waiting) continue;
                const due = bot.due_ns.load(.acquire);
                if (due == std.math.maxInt(u64)) continue;
                if (moment < due) {
                    next_join = @min(next_join, due);
                    continue;
                }
                bot.connect(swarm.address, scenario.view_distance) catch |err| bot.fail(err, "could not connect");
            }
            if (moment >= next_tick) {
                for (swarm.bots[self.first..self.last]) |*bot| {
                    if (bot.phase.load(.monotonic) != .play or !bot.spawned) continue;
                    bot.ping() catch |err| bot.fail(err, "ping failed");
                    scenario.step(swarm.config.kind, bot, swarm.bots.len) catch |err| bot.fail(err, "scenario step failed");
                    bot.ticks += 1;
                }
                tick += 1;
                next_tick += tick_ns;
                // A worker that fell far behind starts over instead of bursting the ticks it missed.
                if (next_tick + std.time.ns_per_s < moment) next_tick = moment + tick_ns;
            }

            var count: usize = 0;
            for (swarm.bots[self.first..self.last], self.first..) |*bot, index| {
                if (bot.fd < 0) continue;
                if (bot.queued > 0) bot.flush() catch |err| bot.fail(err, "write failed");
                if (bot.fd < 0) continue;
                self.descriptors[count] = .{ .fd = bot.fd, .events = @as(i16, linux.POLL.IN) | @as(i16, if (bot.queued > 0) linux.POLL.OUT else 0) };
                self.owners[count] = @intCast(index);
                count += 1;
            }
            const wake = @min(next_tick, next_join);
            const later = now();
            const timeout: i32 = if (wake <= later) 0 else @intCast(@min(50, (wake - later + std.time.ns_per_ms - 1) / std.time.ns_per_ms));
            const ready = linux.poll(self.descriptors.ptr, count, timeout);
            if (linux.errno(ready) != .SUCCESS) continue;
            for (self.descriptors[0..count], self.owners[0..count]) |descriptor, owner| {
                if (descriptor.revents == 0) continue;
                const bot = &swarm.bots[owner];
                if (descriptor.revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
                    bot.receive(self) catch |err| bot.fail(err, @errorName(err));
                }
                if (bot.fd >= 0 and bot.queued > 0) bot.flush() catch |err| bot.fail(err, "write failed");
            }
        }
        for (swarm.bots[self.first..self.last]) |*bot| bot.close();
    }
};

pub const Swarm = struct {
    allocator: std.mem.Allocator,
    config: Configuration,
    address: linux.sockaddr.in,
    bots: []Bot,
    workers: []Worker,
    started_ns: u64 = 0,
    stopping: std.atomic.Value(bool) = .init(false),
    /// Bots allowed to join, the first ones by index.
    admitted: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: Configuration, bots: usize, threads: usize) !*Swarm {
        assert(bots > 0 and threads > 0);
        const self = try allocator.create(Swarm);
        const workers = @min(threads, bots);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .address = .{ .port = std.mem.nativeToBig(u16, config.port), .addr = std.mem.nativeToBig(u32, 0x7f000001) },
            .bots = try allocator.alloc(Bot, bots),
            .workers = try allocator.alloc(Worker, workers),
        };
        for (self.bots, 0..) |*bot, index| {
            bot.* = .{
                .index = @intCast(index),
                .input = try allocator.alloc(u8, frame_maximum + 8),
                .output = try allocator.alloc(u8, output_capacity),
                .random = .init(0x5eed_0000 + index),
            };
            bot.name_len = @intCast((try std.fmt.bufPrint(&bot.name, "bot_{d}", .{index})).len);
        }
        for (self.workers, 0..) |*worker, index| {
            const first = bots * index / workers;
            const last = bots * (index + 1) / workers;
            worker.* = .{
                .swarm = self,
                .first = first,
                .last = last,
                .decoded = try allocator.alloc(u8, decoded_maximum),
                .workspace = try java.Wire.Workspace.init(allocator),
                .descriptors = try allocator.alloc(linux.pollfd, last - first),
                .owners = try allocator.alloc(u32, last - first),
            };
        }
        return self;
    }

    /// Starts the workers with no bot admitted yet.
    pub fn start(self: *Swarm) !void {
        self.started_ns = now();
        for (self.workers) |*worker| worker.thread = try std.Thread.spawn(.{}, Worker.run, .{worker});
    }

    /// Lets the first `count` bots join, the newly admitted ones a join interval apart from now.
    pub fn admit(self: *Swarm, players: usize) void {
        assert(players >= self.admitted and players <= self.bots.len);
        const moment = now();
        for (self.bots[self.admitted..players], 0..) |*each, order| each.due_ns.store(moment + order * self.config.join_interval_ns, .release);
        self.admitted = players;
    }

    /// The admitted bots.
    pub fn joining(self: *Swarm) []Bot {
        return self.bots[0..self.admitted];
    }

    /// Every bot's ping round trips added up.
    pub fn latency(self: *const Swarm) [Latency.buckets]u64 {
        var sum: [Latency.buckets]u64 = @splat(0);
        for (self.bots) |*each| for (&sum, &each.latency.counts) |*summed, *value| {
            summed.* += value.load(.monotonic);
        };
        return sum;
    }

    pub fn stop(self: *Swarm) void {
        self.stopping.store(true, .release);
        for (self.workers) |*worker| if (worker.thread) |thread| thread.join();
    }

    pub fn total(self: *const Swarm, counter: Counter) u64 {
        var sum: u64 = 0;
        for (self.bots) |*bot| sum += bot.counters.get(counter);
        return sum;
    }

    pub fn count(self: *const Swarm, phase: Phase) usize {
        var sum: usize = 0;
        for (self.bots) |*bot| sum += @intFromBool(bot.phase.load(.monotonic) == phase);
        return sum;
    }

    /// Bots for which a moment has passed.
    pub fn reached(self: *const Swarm, counter: Counter) usize {
        var sum: usize = 0;
        for (self.bots) |*bot| sum += @intFromBool(bot.counters.get(counter) != 0);
        return sum;
    }

    /// The newest world age any bot was told, and when.
    pub fn gameTime(self: *const Swarm) struct { u64, u64 } {
        var best: struct { u64, u64 } = .{ 0, 0 };
        for (self.bots) |*bot| {
            const at = bot.counters.get(.game_time_ns);
            if (at > best[1]) best = .{ bot.counters.get(.game_time), at };
        }
        return best;
    }
};

/// Asks a server for its status, which every server answers only once it is ready for players.
pub fn probe(port: u16) bool {
    const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(socket) != .SUCCESS) return false;
    const fd: linux.fd_t = @intCast(socket);
    defer _ = linux.close(fd);
    const timeout: linux.timeval = .{ .sec = 2, .usec = 0 };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&timeout), @sizeOf(linux.timeval));
    const address: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (linux.errno(linux.connect(fd, &address, @sizeOf(linux.sockaddr.in))) != .SUCCESS) return false;
    var buffer: [64]u8 = undefined;
    var frames: [80]u8 = undefined;
    var packet: Packet = .init(&buffer, 0);
    packet.varint(protocol_number);
    packet.string("localhost");
    packet.int(u16, port);
    packet.varint(1);
    var length = putVarint(&frames, @intCast(packet.bytes().len));
    @memcpy(frames[length..][0..packet.bytes().len], packet.bytes());
    length += packet.bytes().len;
    // An empty status request.
    frames[length] = 1;
    frames[length + 1] = 0;
    length += 2;
    if (linux.errno(linux.write(fd, &frames, length)) != .SUCCESS) return false;
    var answer: [16]u8 = undefined;
    const result = linux.read(fd, &answer, answer.len);
    return linux.errno(result) == .SUCCESS and result > 2;
}

/// The id a server in offline mode gives a name: a version 3 UUID of "OfflinePlayer:" and it.
fn offlineUuid(name: []const u8) u128 {
    var md5 = std.crypto.hash.Md5.init(.{});
    md5.update("OfflinePlayer:");
    md5.update(name);
    var digest: [16]u8 = undefined;
    md5.final(&digest);
    digest[6] = (digest[6] & 0x0f) | 0x30;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    return std.mem.readInt(u128, &digest, .big);
}

fn blockPosition(at: [3]i32) i64 {
    const x: u64 = @as(u26, @truncate(@as(u32, @bitCast(at[0]))));
    const z: u64 = @as(u26, @truncate(@as(u32, @bitCast(at[2]))));
    const y: u64 = @as(u12, @truncate(@as(u32, @bitCast(at[1]))));
    return @bitCast((x << 38) | (z << 12) | y);
}

pub fn now() u64 {
    var time: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &time);
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.nsec));
}

/// A packet being written: its id, then fields in protocol encoding.
const Packet = struct {
    buffer: []u8,
    length: usize = 0,

    fn init(buffer: []u8, id: i32) Packet {
        var packet: Packet = .{ .buffer = buffer };
        packet.varint(id);
        return packet;
    }

    fn bytes(self: *const Packet) []const u8 {
        return self.buffer[0..self.length];
    }

    fn varint(self: *Packet, value: i32) void {
        self.length += putVarint(self.buffer[self.length..], @bitCast(value));
    }

    fn int(self: *Packet, comptime T: type, value: T) void {
        std.mem.writeInt(T, self.buffer[self.length..][0..@sizeOf(T)], value, .big);
        self.length += @sizeOf(T);
    }

    fn boolean(self: *Packet, value: bool) void {
        self.int(u8, @intFromBool(value));
    }

    fn string(self: *Packet, value: []const u8) void {
        self.varint(@intCast(value.len));
        self.raw(value);
    }

    fn raw(self: *Packet, value: []const u8) void {
        @memcpy(self.buffer[self.length..][0..value.len], value);
        self.length += value.len;
    }
};

const Reader = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Reader, length: usize) ![]const u8 {
        if (self.bytes.len - self.at < length) return error.Truncated;
        defer self.at += length;
        return self.bytes[self.at..][0..length];
    }

    fn int(self: *Reader, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }

    fn varint(self: *Reader) !i32 {
        const value, const length = readVarint(self.bytes[self.at..]) catch return error.Truncated;
        self.at += length;
        return value;
    }

    fn string(self: *Reader) ![]const u8 {
        const length = try self.varint();
        if (length < 0) return error.InvalidString;
        return self.take(@intCast(length));
    }

    fn rest(self: *Reader) []const u8 {
        defer self.at = self.bytes.len;
        return self.bytes[self.at..];
    }
};

fn putVarint(buffer: []u8, value: u32) usize {
    var rest = value;
    var length: usize = 0;
    while (rest >= 0x80) : (length += 1) {
        buffer[length] = @as(u8, @truncate(rest)) | 0x80;
        rest >>= 7;
    }
    buffer[length] = @intCast(rest);
    return length + 1;
}

fn readVarint(bytes: []const u8) !struct { i32, usize } {
    var value: u32 = 0;
    for (0..5) |index| {
        if (index == bytes.len) return error.Incomplete;
        const byte = bytes[index];
        value |= @as(u32, byte & 0x7f) << @intCast(7 * index);
        if (byte & 0x80 == 0) return .{ @bitCast(value), index + 1 };
    }
    return error.InvalidVarint;
}

test "block positions pack as the protocol expects" {
    try std.testing.expectEqual(@as(i64, (@as(i64, 1) << 38) | (3 << 12) | 2), blockPosition(.{ 1, 2, 3 }));
    const negative: u64 = @bitCast(blockPosition(.{ -1, -1, -1 }));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), negative);
}

test "offline ids match vanilla" {
    // What vanilla gives "Notch" in offline mode.
    try std.testing.expectEqual(@as(u128, 0xb50ad385829d3141a2167e7d7539ba7f), offlineUuid("Notch"));
}

test "varints round trip" {
    var buffer: [5]u8 = undefined;
    for ([_]i32{ 0, 1, 127, 128, 25565, -1, std.math.maxInt(i32) }) |value| {
        const length = putVarint(&buffer, @bitCast(value));
        const decoded, const used = try readVarint(buffer[0..length]);
        try std.testing.expectEqual(value, decoded);
        try std.testing.expectEqual(length, used);
    }
}
