//! Protocol bots: each logs in, answers what the server asks of a client, and moves as its
//! scenario says. A bot decodes only the packets it checks, so the load it adds stays small next
//! to the server it measures. Bots are split across worker threads, each polling its own sockets.

const std = @import("std");
const linux = std.os.linux;
const protocols = @import("protocols");
const java = @import("minecraft_java");
const scenario = @import("scenario.zig");
const offlineUuid = @import("session_server.zig").offlineUuid;
const farm = @import("farm.zig");

const Version = protocols.version("26.2");
const Protocol = Version.Protocol;
pub const protocol_number = Version.protocol_number;

const assert = std.debug.assert;

/// Largest frame and decoded packet a bot accepts, as the vanilla client does.
const frame_maximum = (1 << 21) + 3;
const decoded_maximum = 8 * 1024 * 1024;
/// What each bot holds of its input: whole frames of every packet servers send it in play, chunks
/// included. A larger frame goes into its worker's `overflow`, one bot's at a time.
const input_capacity = 64 * 1024;
/// What a bot queues to send in a pass, a few small packets.
const output_capacity = 8 * 1024;
const tick_ns = 50 * std.time.ns_per_ms;
/// How often a worker reads every one of its sockets, taking whatever piled up in each since: one
/// submission for all of them, rather than waking for every segment that arrives, most of what the
/// bots spent once their decoding was cut. It delays what the bots read by up to this, the same
/// for every server, adding half of it on average to the round trips they time.
pub const read_interval_ns = 5 * std.time.ns_per_ms;
/// The chunks per tick a bot asks for after each batch, about what a vanilla client on a desktop
/// asks for. Servers cap it, vanilla at 64.
pub const chunks_per_tick: f32 = 25;
pub const entity_player = 156;
pub const entity_cow = 30;

/// The chunks a bot holds loaded, by position, in a fixed table no larger than a view and the
/// ring around it ever needs: open addressing, probed linearly, deleted by shifting back.
pub const ChunkSet = struct {
    const capacity = 1024;
    keys: [capacity]u64 = undefined,
    occupied: std.StaticBitSet(capacity) = .empty,
    count: usize = 0,

    fn key(x: i32, z: i32) u64 {
        return @as(u64, @as(u32, @bitCast(x))) << 32 | @as(u32, @bitCast(z));
    }

    fn home(value: u64) usize {
        return @intCast(std.hash.int(value) & (capacity - 1));
    }

    pub fn contains(self: *const ChunkSet, x: i32, z: i32) bool {
        const value = key(x, z);
        var at = home(value);
        while (self.occupied.isSet(at)) : (at = (at + 1) & (capacity - 1)) {
            if (self.keys[at] == value) return true;
        }
        return false;
    }

    /// Adds a chunk, unless the table is full, which a server keeping more than a view and its
    /// ring loaded for one player would be.
    pub fn insert(self: *ChunkSet, x: i32, z: i32) void {
        const value = key(x, z);
        var at = home(value);
        while (self.occupied.isSet(at)) : (at = (at + 1) & (capacity - 1)) {
            if (self.keys[at] == value) return;
        }
        if (self.count == capacity * 3 / 4) return;
        self.keys[at] = value;
        self.occupied.set(at);
        self.count += 1;
    }

    pub fn remove(self: *ChunkSet, x: i32, z: i32) void {
        const value = key(x, z);
        var at = home(value);
        while (self.occupied.isSet(at)) : (at = (at + 1) & (capacity - 1)) {
            if (self.keys[at] != value) continue;
            // Each entry after it that would be found earlier moves into the gap.
            var gap = at;
            var next = (gap + 1) & (capacity - 1);
            while (self.occupied.isSet(next)) : (next = (next + 1) & (capacity - 1)) {
                const wanted = home(self.keys[next]);
                const distance_next = (next -% wanted) & (capacity - 1);
                const distance_gap = (gap -% wanted) & (capacity - 1);
                if (distance_gap < distance_next) {
                    self.keys[gap] = self.keys[next];
                    gap = next;
                }
            }
            self.occupied.unset(gap);
            self.count -= 1;
            return;
        }
    }
};

test "a chunk set holds what was added and not what was removed" {
    var set: ChunkSet = .{};
    var x: i32 = -12;
    while (x <= 12) : (x += 1) {
        var z: i32 = -12;
        while (z <= 12) : (z += 1) set.insert(x, z);
    }
    try std.testing.expectEqual(@as(usize, 625), set.count);
    x = -12;
    while (x <= 12) : (x += 1) {
        var z: i32 = -12;
        while (z <= 12) : (z += 1) if (@mod(x + z, 3) == 0) set.remove(x, z);
    }
    x = -12;
    while (x <= 12) : (x += 1) {
        var z: i32 = -12;
        while (z <= 12) : (z += 1) try std.testing.expectEqual(@mod(x + z, 3) != 0, set.contains(x, z));
    }
}

/// Sugar cane's block in 26.2, for the warp scenario's check, set before the bots start.
var cane_block: u16 = 0;

fn isCane(state: u32) bool {
    const blocks = Version.Registry.block_state_to_block;
    return state < blocks.len and blocks[state] == cane_block;
}
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
    /// Columns of the warp scenario's farm the bot found three tall, and short.
    cane_full,
    cane_short,
    /// Cows of the warp scenario still where they were summoned, as one that never wandered is.
    cows_unmoved,
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
    /// When the server moved the bot to where its scenario starts, and when every chunk of the
    /// view around it there was loaded.
    placed_ns,
    placed_view_ns,
    /// Chunks of the view around where the bot was moved that it does not hold, as last
    /// counted, and the offset of one of them, x in the high half and z in the low.
    view_missing,
    view_missing_at,
    /// When the bot reached the place its scenario sends it to.
    arrived_ns,
};

/// Actions a bot times at once: one a tick at most, so the server may take three seconds to
/// acknowledge one before it goes untimed.
const action_window = 64;

/// Round trips, of pings or of edits, in buckets a quarter of a power of two wide in microseconds,
/// so any percentile is within about 12% at every scale. Bots record into their own and the swarm adds
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
        return self.values[@intFromEnum(counter)].load(.acquire);
    }

    /// Sets a moment once, so the first time something happened stays. What the bot learned
    /// before it is seen by whoever reads the moment.
    pub fn mark(self: *Counters, counter: Counter, value: u64) void {
        _ = self.values[@intFromEnum(counter)].cmpxchgStrong(0, @max(1, value), .release, .monotonic);
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
    /// The AES-CFB8 streams once the bot answered the server's encryption request, as every
    /// server in the bench encrypts, as real servers do.
    sending: ?java.Cipher = null,
    receiving: ?java.Cipher = null,
    /// How far the input is decrypted, in place, from its start: every byte before it the bot
    /// read, while the bodies of frames it passed by, as `skipTo` does, stay as they came.
    decrypted_to: usize = 0,
    /// The encryption answer was queued, so what follows the frame being read is encrypted.
    encryption_pending: bool = false,
    input: []u8,
    filled: usize = 0,
    output: []u8,
    queued: usize = 0,
    /// Requests the worker's ring holds for the bot: a receive into the input after what it
    /// holds, a send of the first `send_pending` bytes of its output, and its connect.
    receive_pending: bool = false,
    /// The room the pending receive had, and whether it filled it, so more may be waiting.
    receive_room: usize = 0,
    read_again: bool = false,
    send_pending: usize = 0,
    connect_pending: bool = false,
    /// Receiving a frame larger than `input`, of `frame_total` bytes, into the worker's overflow,
    /// or waiting for another bot of the worker to finish with it.
    large: bool = false,
    waiting_overflow: bool = false,
    frame_total: usize = 0,
    /// The last frames read, newest at `recent_count % recent.len`, kept to say what came
    /// before a frame that could not be read.
    recent: [16]Recent = undefined,
    recent_count: usize = 0,
    entity: i32 = 0,
    spawned: bool = false,
    /// Moved by the server to where its scenario starts.
    placed: bool = false,
    /// The chunks the bot has loaded, as the server sent and unloaded them, and whether it
    /// waits to hold the whole view around where it was moved.
    loaded: ChunkSet = .{},
    view_pending: bool = false,
    /// What the warp scenario's check counted in each of the farm's chunks.
    farm_tallies: [farm.chunks]farm.Tally = @splat(.{}),
    position: [3]f64 = @splat(0),
    yaw: f32 = 0,
    pitch: f32 = 0,
    on_ground: bool = true,
    /// Where the server first put the bot.
    origin: [3]f64 = @splat(0),
    /// The world's spawn, as the server announced it, which every bot shares, unlike where each
    /// was put: vanilla puts joining players anywhere within ten blocks of it.
    spawn: ?[3]f64 = null,
    /// Ticks since the bot spawned.
    ticks: u64 = 0,
    sequence: i32 = 0,
    flying: bool = false,
    stocked: bool = false,
    heading: f64 = 0,
    random: std.Random.DefaultPrng,
    failure: ?anyerror = null,
    /// When the bot last read and last sent anything, and what it was doing when it failed, to
    /// tell a server that dropped a bot from a bot that went quiet.
    last_read_ns: u64 = 0,
    last_sent_ns: u64 = 0,
    state: [160]u8 = undefined,
    state_len: u8 = 0,
    reason: [160]u8 = undefined,
    reason_len: u8 = 0,
    counters: Counters = .{},
    /// Round trips of pings, which vanilla answers from its network thread.
    latency: Latency = .{},
    /// Round trips of actions, block edits and uses of the hand, from sending one until the server
    /// acknowledged its sequence, which vanilla does in the player's tick after handling it: the
    /// wait for a tick, the tick and what the server is still sending, the delay players feel.
    action_latency: Latency = .{},
    /// When each of the latest actions was sent, by its sequence.
    action_sent_ns: [action_window]u64 = undefined,
    /// The highest action sequence timed so far.
    action_timed: i32 = 0,
    /// When the bot next uses its hand.
    action_due_ns: u64 = 0,
    /// When the bot may start joining, once the swarm admits it.
    due_ns: std.atomic.Value(u64) = .init(std.math.maxInt(u64)),
    /// What the server sent before play, and in play by packet id: as it crossed the wire,
    /// compressed, and as decoded. Only the bot's worker writes these, so they are read after
    /// the swarm stops.
    setup: Traffic = .{},
    play: [256]Traffic = @splat(.{}),

    /// Where scenarios lay their spots out from: the world's spawn every bot shares, or where the
    /// bot was put if the server never said.
    pub fn home(self: *const Bot) [3]f64 {
        return self.spawn orelse self.origin;
    }

    pub fn label(self: *const Bot) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn stateText(self: *const Bot) []const u8 {
        return self.state[0..self.state_len];
    }

    pub fn reasonText(self: *const Bot) []const u8 {
        return self.reason[0..self.reason_len];
    }

    /// Writes the frame the bot could not read to `failed-frames/<bot>.bin` in the run's directory: a
    /// line of JSON saying what failed and what came before, then everything the input held,
    /// decrypted as far as `decrypted_to` but for the bodies of frames passed by unread, the frame
    /// at `frame_start..frame_end` among it. Whether its bytes are a whole stream of the wrong
    /// length, a stream that turns into another packet partway, or nothing like a frame at all
    /// tells a server's bad bytes from a bot that lost its place.
    fn saveFailure(self: *Bot, worker: *Worker, err: anyerror, buffer: []const u8, frame_start: usize, frame_end: usize) void {
        const directory = worker.swarm.config.failed_frames orelse return;
        const input = buffer[0..self.filled];
        var name: [64]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&name, "failed-frames/{s}.bin", .{self.label()}, 0) catch return;
        _ = linux.mkdirat(directory, "failed-frames", 0o755);
        const opened = linux.openat(directory, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(opened) != .SUCCESS) return;
        const fd: linux.fd_t = @intCast(opened);
        defer _ = linux.close(fd);
        var header_bytes: [2048]u8 = undefined;
        var header: std.Io.Writer = .fixed(&header_bytes);
        header.print("{{\"bot\":\"{s}\",\"error\":\"{s}\",\"phase\":\"{s}\",\"compressed\":{},\"encrypted\":{},\"overflow\":{},\"frame_start\":{d},\"frame_end\":{d},\"input_bytes\":{d},\"decrypted_to\":{d},\"frames_read\":{d},\"recent\":[", .{
            self.label(), @errorName(err), @tagName(self.phase.load(.monotonic)), self.compressed, self.receiving != null, self.large, frame_start, frame_end, input.len, self.decrypted_to, self.recent_count,
        }) catch return;
        // Oldest first: packet id, bytes on the wire, bytes decoded.
        const kept = @min(self.recent_count, self.recent.len);
        for (0..kept) |offset| {
            const entry = self.recent[(self.recent_count - kept + offset) % self.recent.len];
            header.print("{s}[{d},{d},{d}]", .{ if (offset == 0) "" else ",", entry.id, entry.wire, entry.decoded }) catch return;
        }
        header.writeAll("]}\n") catch return;
        for ([_][]const u8{ header.buffered(), input }) |bytes| {
            var written: usize = 0;
            while (written < bytes.len) {
                const result = linux.write(fd, bytes[written..].ptr, bytes.len - written);
                if (linux.errno(result) != .SUCCESS or result == 0) return;
                written += result;
            }
        }
    }

    fn fail(self: *Bot, err: anyerror, reason: []const u8) void {
        if (self.phase.load(.monotonic) == .failed) return;
        self.failure = err;
        const moment = now();
        const state = std.fmt.bufPrint(&self.state, "in {s}, spawned {}, placed {}, last read {d} ms and sent {d} ms before, {d} keep alives, receive pending {}, waiting for overflow {}, {d} bytes held, {d} to send", .{
            @tagName(self.phase.load(.monotonic)),              self.spawned,                                      self.placed,
            (moment -| self.last_read_ns) / std.time.ns_per_ms, (moment -| self.last_sent_ns) / std.time.ns_per_ms, self.counters.get(.keepalives),
            self.receive_pending,                               self.waiting_overflow,                              self.filled,
            self.queued,
        }) catch "";
        self.state_len = @intCast(state.len);
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

    /// Its receive and send in the worker's ring complete once the socket is shut down, rather
    /// than hold it open.
    fn close(self: *Bot) void {
        if (self.fd >= 0) {
            _ = linux.shutdown(self.fd, linux.SHUT.RDWR);
            _ = linux.close(self.fd);
        }
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
        if (self.sending) |*cipher| {
            const framed = self.output[self.queued - header_len - length .. self.queued];
            cipher.transform(.encrypt, framed, framed);
        }
        self.counters.add(.packets_out, 1);
    }

    /// Queues a packet that may reach the compression threshold, compressing it then, as a client
    /// does. Only the encryption answer can, with a server's key of 2048 bits.
    fn queueCompressible(self: *Bot, worker: *Worker, packet: []const u8) !void {
        if (!self.compressed or packet.len < self.threshold) return self.queue(packet);
        var compressed: [2048]u8 = undefined;
        const body = try worker.workspace.compressor.encode(packet, &compressed);
        var size: [5]u8 = undefined;
        const size_len = putVarint(&size, @intCast(packet.len));
        var header: [4]u8 = undefined;
        const header_len = putVarint(&header, @intCast(size_len + body.len));
        const length = header_len + size_len + body.len;
        if (self.queued + length > self.output.len) return error.OutputFull;
        const framed = self.output[self.queued..][0..length];
        @memcpy(framed[0..header_len], header[0..header_len]);
        @memcpy(framed[header_len..][0..size_len], size[0..size_len]);
        @memcpy(framed[header_len + size_len ..], body);
        if (self.sending) |*cipher| cipher.transform(.encrypt, framed, framed);
        self.queued += length;
        self.counters.add(.packets_out, 1);
    }

    /// The first `count` bytes of the output went out.
    fn wrote(self: *Bot, count: usize) void {
        assert(count <= self.send_pending and self.send_pending <= self.queued);
        self.counters.add(.bytes_out, count);
        std.mem.copyForwards(u8, self.output[0 .. self.queued - count], self.output[count..self.queued]);
        self.queued -= count;
        self.send_pending = 0;
    }

    /// A socket of its own, which the worker's ring connects.
    fn open(self: *Bot) !void {
        const socket = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(socket) != .SUCCESS) return error.SocketFailed;
        self.fd = @intCast(socket);
        self.sending = null;
        self.receiving = null;
        self.decrypted_to = 0;
        self.encryption_pending = false;
        const one: i32 = 1;
        _ = linux.setsockopt(self.fd, linux.IPPROTO.TCP, linux.TCP.NODELAY, std.mem.asBytes(&one), @sizeOf(i32));
    }

    /// Logs in once connected.
    fn connected(self: *Bot, address: linux.sockaddr.in, view_distance: u8) !void {
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
    /// Handles the `result` bytes the ring received after what the input held: every whole
    /// frame now in it.
    fn received(self: *Bot, worker: *Worker, result: usize) !void {
        const buffer = self.inputBuffer(worker);
        assert(result > 0 and result <= buffer.len - self.filled);
        self.filled += result;

        var start: usize = 0;
        // The whole length of the frame left incomplete, once its length arrived.
        var incomplete: usize = 0;
        while (start < self.filled) {
            // The frame's length and the start of its packet, which the bot reads of every frame.
            self.decryptTo(buffer, @min(self.filled, start + head_bytes));
            const length, const prefix = readVarint(buffer[start..self.filled]) catch |err| switch (err) {
                error.Incomplete => break,
                else => {
                    self.saveFailure(worker, err, buffer, start, self.filled);
                    return err;
                },
            };
            if (length <= 0 or length > frame_maximum) {
                self.saveFailure(worker, error.InvalidFrame, buffer, start, self.filled);
                return error.InvalidFrame;
            }
            const end = start + prefix + @as(usize, @intCast(length));
            if (end > self.filled) {
                incomplete = end - start;
                break;
            }
            self.frame(worker, buffer, start + prefix, end) catch |err| {
                self.saveFailure(worker, err, buffer, start, end);
                return err;
            };
            if (self.phase.load(.monotonic) == .failed) return;
            start = end;
            // What arrived after the encryption request is encrypted, none of it decrypted yet.
            if (self.encryption_pending) {
                self.decrypted_to = end;
                self.encryption_pending = false;
            }
        }
        std.mem.copyForwards(u8, buffer[0 .. self.filled - start], buffer[start..self.filled]);
        self.filled -= start;
        self.decrypted_to -= start;
        if (self.large) {
            // It received exactly the rest of its large frame, so nothing follows it.
            if (self.filled == 0) {
                self.large = false;
                worker.overflow_owner = null;
            }
        } else if (incomplete > self.input.len) {
            self.frame_total = incomplete;
            self.waiting_overflow = true;
        }
    }

    /// Where the bot's input is.
    fn inputBuffer(self: *const Bot, worker: *const Worker) []u8 {
        return if (self.large) worker.overflow else self.input;
    }

    /// Where the bot receives next, or null while it waits for its worker's overflow.
    fn receiveSpan(self: *Bot, worker: *Worker) ?[]u8 {
        if (self.waiting_overflow) {
            if (worker.overflow_owner != null) return null;
            worker.overflow_owner = self.index;
            @memcpy(worker.overflow[0..self.filled], self.input[0..self.filled]);
            self.large = true;
            self.waiting_overflow = false;
        }
        // Only the rest of the large frame, so that the overflow holds no more than it.
        if (self.large) return worker.overflow[self.filled..self.frame_total];
        return self.input[self.filled..];
    }

    /// Decrypts the input in place up to `to`, on from as far as it was, as the server's stream
    /// goes on.
    fn decryptTo(self: *Bot, buffer: []u8, to: usize) void {
        if (to <= self.decrypted_to) return;
        if (self.receiving) |*cipher| cipher.transform(.decrypt, buffer[self.decrypted_to..to], buffer[self.decrypted_to..to]);
        self.decrypted_to = to;
    }

    /// Passes the input by up to `to` without decrypting it. CFB8 goes on from the 16 bytes of
    /// ciphertext before any byte, which are still in the input as they came, or, as far as fewer
    /// were passed by, in the cipher's register.
    fn skipTo(self: *Bot, buffer: []const u8, to: usize) void {
        if (to <= self.decrypted_to) return;
        if (self.receiving) |*cipher| {
            const passed = to - self.decrypted_to;
            if (passed >= cipher.feedback.len) {
                @memcpy(&cipher.feedback, buffer[to - cipher.feedback.len .. to]);
            } else {
                std.mem.copyForwards(u8, cipher.feedback[0 .. cipher.feedback.len - passed], cipher.feedback[passed..]);
                @memcpy(cipher.feedback[cipher.feedback.len - passed ..], buffer[self.decrypted_to..to]);
            }
        }
        self.decrypted_to = to;
    }

    /// Handles the frame at `buffer[from..to]`, decrypted as far as its start. In play, every bot
    /// but the first decodes a packet only as far as it reads it, as most of what servers send,
    /// chunks above all, is only counted: its id, a chunk's position, and the whole of the few
    /// small packets the bots answer, as `read_whole` lists, and passes the rest by. The first
    /// bot decodes everything whole, checking every server's frames decrypt and inflate as a
    /// client's would.
    fn frame(self: *Bot, worker: *Worker, buffer: []u8, from: usize, to: usize) !void {
        // A frame no longer than the start every frame is decrypted as far as is read whole.
        if (self.phase.load(.monotonic) != .play or self.index == 0 or to <= self.decrypted_to) {
            self.decryptTo(buffer, to);
            return self.whole(worker, buffer[from..to]);
        }
        const head = buffer[from..self.decrypted_to];
        var body: []const u8 = head;
        var decoded = to - from;
        var peeked: [peek_maximum]u8 = undefined;
        if (self.compressed) {
            const length, const prefix = try readVarint(head);
            body = head[prefix..];
            decoded -= prefix;
            if (length != 0) {
                if (length < 0 or length > decoded_maximum) return error.InvalidPacket;
                decoded = @intCast(length);
                body = try self.peek(buffer, from + prefix, to, peeked[0..@min(peeked.len, decoded)]);
            }
        }
        var reader: Reader = .{ .bytes = body };
        const id = try reader.varint();
        if (readsWhole(id, worker.swarm.config.kind)) {
            self.decryptTo(buffer, to);
            return self.whole(worker, buffer[from..to]);
        }
        self.skipTo(buffer, to);
        self.account(id, to - from, decoded);
        try self.playPacket(worker, id, &reader, to - from);
    }

    /// The first `output.len` bytes the compressed packet at `buffer[from..to]` decodes to,
    /// decrypting and inflating only as much of it as they take: the start of a stream, rarely
    /// more than its first few hundred bytes.
    fn peek(self: *Bot, buffer: []u8, from: usize, to: usize, output: []u8) ![]const u8 {
        var taken: usize = 256;
        while (true) : (taken *= 8) {
            const end = @min(to, from + taken);
            self.decryptTo(buffer, end);
            if (inflatePrefix(buffer[from..end], output)) |_| {
                return output;
            } else |err| if (end == to) return err;
        }
    }

    /// Counts a frame the bot read, under the packet's id in play.
    fn account(self: *Bot, id: i32, wire: usize, decoded: usize) void {
        self.counters.add(.packets_in, 1);
        self.recent[self.recent_count % self.recent.len] = .{ .id = id, .wire = @intCast(wire), .decoded = @intCast(decoded) };
        self.recent_count += 1;
        const traffic = if (self.phase.load(.monotonic) == .play and id >= 0 and id < self.play.len) &self.play[@intCast(id)] else &self.setup;
        traffic.count += 1;
        traffic.wire_bytes += wire;
        traffic.decoded_bytes += decoded;
    }

    /// Handles a frame decrypted whole, inflating its packet whole.
    fn whole(self: *Bot, worker: *Worker, raw: []const u8) !void {
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
        self.account(id, raw.len, body.len);
        switch (self.phase.load(.monotonic)) {
            .login => try self.loginPacket(worker, id, &reader),
            .configuration => try self.configurationPacket(id, &reader),
            .play => try self.playPacket(worker, id, &reader, raw.len),
            .waiting, .failed => unreachable,
        }
    }

    fn loginPacket(self: *Bot, worker: *Worker, id: i32, reader: *Reader) !void {
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
            try self.encrypt(worker, reader);
        } else if (id == In.packetId(.disconnect)) {
            self.fail(error.LoginRejected, reader.rest());
        }
    }

    /// Answers the server's encryption request as a client does, without asking Mojang's session
    /// server: the shared secret and the server's token, each encrypted with its public key.
    /// Everything after the answer is encrypted both ways.
    fn encrypt(self: *Bot, worker: *Worker, reader: *Reader) !void {
        _ = try reader.string();
        const public_key = try reader.string();
        const token = try reader.string();
        var secret: [16]u8 = undefined;
        self.random.random().bytes(&secret);
        var encrypted_secret: [rsa_bytes_maximum]u8 = undefined;
        var encrypted_token: [rsa_bytes_maximum]u8 = undefined;
        const secret_bytes = try rsaEncrypt(self.random.random(), public_key, &secret, &encrypted_secret);
        const token_bytes = try rsaEncrypt(self.random.random(), public_key, token, &encrypted_token);
        var buffer: [2 * rsa_bytes_maximum + 16]u8 = undefined;
        var packet: Packet = .init(&buffer, Protocol.login.toServer.packetId(.encryption_begin));
        packet.string(secret_bytes);
        packet.string(token_bytes);
        try self.queueCompressible(worker, packet.bytes());
        self.sending = java.Cipher.init(secret);
        self.receiving = java.Cipher.init(secret);
        self.encryption_pending = true;
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

    /// The play packets `playPacket` reads past their start, which bots decode whole, and in the
    /// warp scenario chunks, whose blocks its check counts. Every other packet comes decoded only
    /// as far as `peek_maximum` bytes, so a packet read further and left off here reads truncated
    /// and fails the bot, its frame saved, rather than reading wrong.
    const read_whole = [_]Protocol.play.toClient.PacketName{
        .unload_chunk, .ping_response, .keep_alive,     .ping,                       .update_time,         .login,           .spawn_position,
        .position,     .spawn_entity,  .entity_destroy, .acknowledge_player_digging, .start_configuration, .kick_disconnect,
    };

    fn readsWhole(id: i32, kind: scenario.Kind) bool {
        const In = Protocol.play.toClient;
        if (id == In.packetId(.map_chunk)) return kind == .warp;
        inline for (read_whole) |name| if (id == In.packetId(name)) return true;
        return false;
    }

    fn playPacket(self: *Bot, worker: *Worker, id: i32, reader: *Reader, frame_bytes: usize) !void {
        const In = Protocol.play.toClient;
        const Out = Protocol.play.toServer;
        var buffer: [256]u8 = undefined;
        if (id == In.packetId(.map_chunk)) {
            // The chunk's x and z lead the packet, which the farm check below reads whole.
            const at = reader.bytes[reader.at..];
            if (at.len >= 8) {
                self.loaded.insert(std.mem.readInt(i32, at[0..4], .big), std.mem.readInt(i32, at[4..8], .big));
                if (self.view_pending) self.checkView();
            }
            self.counters.add(.chunks, 1);
            self.counters.add(.chunk_bytes, frame_bytes);
            if (self.counters.get(.chunks) == 1) self.counters.mark(.first_chunk_ns, now());
            if (self.counters.get(.chunks) == scenario.viewChunks()) self.counters.mark(.viewed_ns, now());
            if (worker.swarm.config.kind == .warp) {
                const tally = try farm.checkChunk(reader.rest(), isCane);
                // The latest of a chunk sent again replaces what it counted before.
                if (tally.chunk) |index| {
                    const before = self.farm_tallies[index];
                    self.farm_tallies[index] = tally;
                    self.counters.set(.cane_full, self.counters.get(.cane_full) - before.full + tally.full);
                    self.counters.set(.cane_short, self.counters.get(.cane_short) - before.short + tally.short);
                }
            }
        } else if (id == In.packetId(.chunk_batch_finished)) {
            var packet: Packet = .init(&buffer, Out.packetId(.chunk_batch_received));
            packet.int(u32, @bitCast(chunks_per_tick));
            try self.queue(packet.bytes());
        } else if (id == In.packetId(.unload_chunk)) {
            self.counters.add(.unloads, 1);
            // The chunk as one long, z above x.
            const value = try reader.int(u64);
            self.loaded.remove(@bitCast(@as(u32, @truncate(value))), @bitCast(@as(u32, @truncate(value >> 32))));
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
        } else if (id == In.packetId(.spawn_position)) {
            // The dimension it is in, then the block.
            _ = try reader.take(@intCast(try reader.varint()));
            const at = try reader.int(i64);
            self.spawn = .{
                @as(f64, @floatFromInt(at >> 38)) + 0.5,
                @floatFromInt(@as(i64, at << 52) >> 52),
                @as(f64, @floatFromInt(@as(i64, at << 26) >> 38)) + 0.5,
            };
            self.markJoined();
        } else if (id == In.packetId(.position)) {
            try self.teleported(worker, reader);
        } else if (id == In.packetId(.spawn_entity)) {
            _ = try reader.varint();
            _ = try reader.take(16);
            const kind = try reader.varint();
            self.counters.add(if (kind == entity_player) .players_seen else .entities_seen, 1);
            if (kind == entity_cow) self.counters.add(.cows_seen, 1);
            if (kind == entity_cow and worker.swarm.config.kind == .warp) {
                var at: [3]f64 = undefined;
                for (&at) |*axis| axis.* = @bitCast(try reader.int(u64));
                if (farm.atSummonSpot(at)) self.counters.add(.cows_unmoved, 1);
            }
        } else if (id == In.packetId(.entity_destroy)) {
            self.counters.add(.entities_removed, @intCast(@max(0, try reader.varint())));
        } else if (id == In.packetId(.acknowledge_player_digging)) {
            self.counters.add(.acks, 1);
            const sequence: u64 = @intCast(@max(0, try reader.varint()));
            if (sequence > self.counters.get(.acked_sequence)) self.counters.set(.acked_sequence, sequence);
            // An acknowledgement covers every edit up to its sequence. Edits older than the
            // window are not timed, as their send times were overwritten.
            const acked: i32 = @intCast(@min(sequence, @as(u64, @intCast(self.sequence))));
            const moment = now();
            while (self.action_timed < acked) {
                self.action_timed += 1;
                if (acked - self.action_timed >= action_window) continue;
                const sent = self.action_sent_ns[@intCast(@mod(self.action_timed, action_window))];
                if (moment > sent) self.action_latency.record((moment - sent) / std.time.ns_per_us);
            }
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

    fn teleported(self: *Bot, worker: *Worker, reader: *Reader) !void {
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
        // The bench has the server move each bot to where its scenario starts, which corrects
        // nothing.
        const swarm = worker.swarm;
        const placed = if (scenario.startSpot(swarm.config, self, swarm.bots.len)) |spot| at: {
            for (spot, self.position) |want, have| if (@abs(want - have) > 0.01) break :at false;
            break :at true;
        } else false;
        if (placed and !self.placed) {
            self.placed = true;
            self.counters.mark(.placed_ns, now());
            self.view_pending = true;
        }
        if (placed) self.checkView();
        if (self.spawned and !placed) {
            self.counters.add(.corrections, 1);
        } else if (!self.spawned) {
            self.spawned = true;
            self.origin = self.position;
            packet = .init(&buffer, Out.packetId(.player_loaded));
            try self.queue(packet.bytes());
            self.markJoined();
        }
        try self.move(true);
    }

    /// Marks the bot joined once it is in the world and knows the world's spawn, which servers
    /// send before or after the player's first position, as everywhere it goes is laid out from
    /// the spawn.
    fn markJoined(self: *Bot) void {
        if (self.spawned and self.spawn != null) self.counters.mark(.spawned_ns, now());
    }

    /// Marks the bot as holding its view once every chunk of the view around where it stands is
    /// loaded, after the server moved it there.
    fn checkView(self: *Bot) void {
        if (!self.view_pending) return;
        const chunk_x: i32 = @intFromFloat(@floor(self.position[0] / 16));
        const chunk_z: i32 = @intFromFloat(@floor(self.position[2] / 16));
        var missing: u64 = 0;
        for (scenario.view_offsets) |offset| {
            if (self.loaded.contains(chunk_x + offset[0], chunk_z + offset[1])) continue;
            if (missing == 0) self.counters.set(.view_missing_at, @as(u64, @as(u8, @bitCast(offset[0]))) << 8 | @as(u8, @bitCast(offset[1])));
            missing += 1;
        }
        self.counters.set(.view_missing, missing);
        if (missing != 0) return;
        self.view_pending = false;
        self.counters.mark(.placed_view_ns, now());
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

    /// Uses the empty hand, which vanilla acknowledges in the player's tick and otherwise ignores,
    /// so every scenario times how long a player's action takes to be handled and heard back from,
    /// without changing the world. About once a second, at a random moment rather than on the
    /// bot's own tick, as a player's actions come at any moment of the server's tick: on the
    /// bot's tick, which keeps the same rate as the server's, every action would wait the same.
    pub fn act(self: *Bot, moment: u64) !void {
        self.action_due_ns = moment + std.time.ns_per_s / 2 + self.random.random().uintLessThan(u64, std.time.ns_per_s);
        self.sequence += 1;
        self.action_sent_ns[@intCast(@mod(self.sequence, action_window))] = now();
        var buffer: [32]u8 = undefined;
        var packet: Packet = .init(&buffer, Protocol.play.toServer.packetId(.use_item));
        packet.varint(0);
        packet.varint(self.sequence);
        packet.int(u32, @bitCast(self.yaw));
        packet.int(u32, @bitCast(self.pitch));
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
        self.action_sent_ns[@intCast(@mod(self.sequence, action_window))] = now();
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
        self.action_sent_ns[@intCast(@mod(self.sequence, action_window))] = now();
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
    /// The world the server runs, where spread lays its spots out differently on a tiled one.
    terrain: @import("server.zig").Terrain = .flat,
    /// Time between two bots starting to join.
    join_interval_ns: u64,
    /// How often each worker reads all its sockets, as `read_interval_ns` says.
    read_interval_ns: u64 = read_interval_ns,
    /// A file the first bot appends every frame it gets in play to, as a little endian length
    /// and the frame as it crossed the wire, for looking at what servers send.
    dump: ?linux.fd_t = null,
    /// The run's directory, in whose `failed-frames` a bot writes the frame it could not read,
    /// with what its input held, for telling a server that sent bad bytes from a bot that lost
    /// its place.
    failed_frames: ?linux.fd_t = null,
};

/// A frame a bot read: its packet id, its length on the wire and decoded.
const Recent = struct { id: i32, wire: u32, decoded: u32 };

/// The bots of one thread and the scratch they share. A pass does each kind of work for all of
/// them at once: their completions, their tick, their actions, then the receive, send and connect
/// each needs, submitted together with one system call that also waits for the next completion.
const Worker = struct {
    swarm: *Swarm,
    first: usize,
    last: usize,
    decoded: []u8,
    /// Input for the one bot at a time whose frame is larger than its own.
    overflow: []u8,
    overflow_owner: ?u32 = null,
    workspace: java.Wire.Workspace,
    /// Made on the worker's own thread as it starts, with room for `ring_entries`.
    ring: linux.IoUring = undefined,
    ring_entries: u16,
    completions: []linux.io_uring_cqe,
    /// When the earliest timeout armed in the ring fires, or never.
    alarm: u64 = std.math.maxInt(u64),
    alarm_time: linux.kernel_timespec = undefined,
    /// When the worker next reads every socket.
    next_read: u64 = 0,
    thread: ?std.Thread = null,

    const Request = enum(u2) { receive, send, connect, alarm };

    fn tag(index: u64, request: Request) u64 {
        return index << 2 | @intFromEnum(request);
    }

    fn run(self: *Worker) void {
        const swarm = self.swarm;
        // A ring only this thread uses, which then runs the kernel's side of its completions only
        // as the worker waits on it, rather than interrupting the worker as data arrives. Kernels
        // older than 6.1 have neither, and get a plain ring.
        self.ring = linux.IoUring.init(self.ring_entries, linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN) catch |deferred| plain: {
            std.log.warn("bots run a plain ring, as the kernel refused one of their own: {s}", .{@errorName(deferred)});
            break :plain linux.IoUring.init(self.ring_entries, 0);
        } catch |err| {
                for (swarm.bots[self.first..self.last]) |*bot| bot.fail(err, "could not set up its worker's ring");
                return;
            };
        defer self.ring.deinit();
        var next_tick = swarm.started_ns;
        var tick: u64 = 0;
        while (!swarm.stopping.load(.acquire)) {
            const moment = now();
            const reading = moment >= self.next_read;
            if (reading) {
                self.next_read += swarm.config.read_interval_ns;
                // A worker that fell behind reads from now on rather than bursting the reads it missed.
                if (self.next_read <= moment) self.next_read = moment + swarm.config.read_interval_ns;
            }
            var next_join: u64 = std.math.maxInt(u64);
            for (swarm.bots[self.first..self.last], self.first..) |*bot, index| {
                if (bot.phase.load(.monotonic) != .waiting or bot.fd >= 0) continue;
                const due = bot.due_ns.load(.acquire);
                if (due == std.math.maxInt(u64)) continue;
                if (moment < due) {
                    next_join = @min(next_join, due);
                    continue;
                }
                bot.open() catch |err| {
                    bot.fail(err, "could not open a socket");
                    continue;
                };
                _ = self.ring.connect(tag(index, .connect), bot.fd, @ptrCast(&swarm.address), @sizeOf(linux.sockaddr.in)) catch |err| {
                    bot.fail(err, "could not connect");
                    continue;
                };
                bot.connect_pending = true;
            }
            if (moment >= next_tick) {
                for (swarm.bots[self.first..self.last]) |*bot| {
                    if (bot.phase.load(.monotonic) != .play or !bot.spawned) continue;
                    bot.ping() catch |err| bot.fail(err, "ping failed");
                    scenario.step(swarm.config, bot, swarm.bots.len) catch |err| bot.fail(err, "scenario step failed");
                    bot.ticks += 1;
                }
                tick += 1;
                next_tick += tick_ns;
                // A worker that fell far behind starts over instead of bursting the ticks it missed.
                if (next_tick + std.time.ns_per_s < moment) next_tick = moment + tick_ns;
            }

            var next_action: u64 = std.math.maxInt(u64);
            for (swarm.bots[self.first..self.last]) |*bot| {
                if (bot.phase.load(.monotonic) != .play or !bot.spawned) continue;
                if (moment >= bot.action_due_ns) bot.act(moment) catch |err| bot.fail(err, "action failed");
                next_action = @min(next_action, bot.action_due_ns);
            }

            for (swarm.bots[self.first..self.last], self.first..) |*bot, index| {
                if (bot.fd < 0) {
                    // A bot that failed gives the overflow back.
                    if (self.overflow_owner == bot.index) self.overflow_owner = null;
                    continue;
                }
                if (bot.connect_pending) continue;
                // What piled up since the last read, at once, without waiting for more: nothing in
                // the ring waits on a socket, so data arriving wakes no one.
                if (!bot.receive_pending and (reading or bot.read_again)) receive: {
                    const span = bot.receiveSpan(self) orelse break :receive;
                    _ = self.ring.recv(tag(index, .receive), bot.fd, .{ .buffer = span }, linux.MSG.DONTWAIT) catch |err| {
                        bot.fail(err, "could not receive");
                        continue;
                    };
                    bot.receive_pending = true;
                    bot.receive_room = span.len;
                    bot.read_again = false;
                }
                if (bot.send_pending == 0 and bot.queued > 0) {
                    _ = self.ring.send(tag(index, .send), bot.fd, bot.output[0..bot.queued], 0) catch |err| {
                        bot.fail(err, "could not send");
                        continue;
                    };
                    bot.send_pending = bot.queued;
                }
            }

            // The ring wakes the worker at the next tick, join, action or read, unless an earlier
            // timeout already will.
            const wake = @min(next_tick, next_join, next_action, self.next_read);
            if (wake < self.alarm) {
                self.alarm_time = .{ .sec = @intCast(wake / std.time.ns_per_s), .nsec = @intCast(wake % std.time.ns_per_s) };
                if (self.ring.timeout(tag(wake, .alarm), &self.alarm_time, 0, linux.IORING_TIMEOUT_ABS)) |_| {
                    self.alarm = wake;
                } else |_| {}
            }
            _ = self.ring.submit_and_wait(1) catch continue;
            const count = self.ring.copy_cqes(self.completions, 0) catch continue;
            for (self.completions[0..count]) |completion| self.complete(completion);
        }
        for (swarm.bots[self.first..self.last]) |*bot| bot.close();
    }

    fn complete(self: *Worker, completion: linux.io_uring_cqe) void {
        const request: Request = @enumFromInt(completion.user_data & 3);
        const index = completion.user_data >> 2;
        if (request == .alarm) {
            if (index == self.alarm) self.alarm = std.math.maxInt(u64);
            return;
        }
        const bot = &self.swarm.bots[index];
        switch (request) {
            .connect => bot.connect_pending = false,
            .receive => bot.receive_pending = false,
            .send => {},
            .alarm => unreachable,
        }
        // A bot that failed shut its socket, which ends what it had in the ring.
        if (bot.fd < 0) {
            if (request == .send) bot.send_pending = 0;
            return;
        }
        const result = completion.res;
        switch (request) {
            .connect => {
                if (result < 0) return bot.fail(error.ConnectFailed, "could not connect");
                bot.connected(self.swarm.address, scenario.view_distance) catch |err| bot.fail(err, "could not log in");
            },
            .receive => {
                // Nothing arrived since the last read.
                if (result == -@as(i32, @intFromEnum(linux.E.AGAIN))) return;
                if (result < 0) return bot.fail(error.ReadFailed, "receive failed");
                if (result == 0) return bot.fail(error.ConnectionClosed, @errorName(error.ConnectionClosed));
                // A read that filled its room may have left more, which it reads at once.
                bot.read_again = @as(usize, @intCast(result)) == bot.receive_room;
                bot.last_read_ns = now();
                bot.counters.add(.bytes_in, @intCast(result));
                bot.received(self, @intCast(result)) catch |err| bot.fail(err, @errorName(err));
            },
            .send => {
                if (result < 0) return bot.fail(error.WriteFailed, "write failed");
                bot.last_sent_ns = now();
                bot.wrote(@intCast(result));
            },
            .alarm => unreachable,
        }
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
        // Before any worker reads it.
        if (config.kind == .warp) cane_block = Version.Registry.block_state_to_block[@intCast(Version.Registry.blockStateId("minecraft:sugar_cane[age=0]").?)];
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
                .input = try allocator.alloc(u8, input_capacity),
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
                .overflow = try allocator.alloc(u8, frame_maximum + 8),
                .workspace = try java.Wire.Workspace.init(allocator),
                // Room for each bot's receive, send and connect, and the timeouts in between.
                .ring_entries = try std.math.ceilPowerOfTwo(u16, @intCast(3 * (last - first) + 16)),
                .completions = try allocator.alloc(linux.io_uring_cqe, 6 * (last - first) + 32),
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

    /// Every bot's round trips of one kind added up.
    pub fn latency(self: *const Swarm, comptime kind: enum { ping, action }) [Latency.buckets]u64 {
        var sum: [Latency.buckets]u64 = @splat(0);
        for (self.bots) |*each| {
            const counts = switch (kind) {
                .ping => &each.latency.counts,
                .action => &each.action_latency.counts,
            };
            for (&sum, counts) |*summed, *value| summed.* += value.load(.monotonic);
        }
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

/// The largest RSA modulus a server may use, in bytes. Vanilla's is 1024 bits.
const rsa_bytes_maximum = 512;

/// Encrypts `message` with the RSA public key a server sent, as SubjectPublicKeyInfo, padded as
/// PKCS #1 v1.5 says, which every server decrypts with.
fn rsaEncrypt(random: std.Random, key: []const u8, message: []const u8, output: *[rsa_bytes_maximum]u8) ![]const u8 {
    const der = std.crypto.Certificate.der;
    const rsa = std.crypto.Certificate.rsa;
    const info = try der.Element.parse(key, 0);
    if (info.identifier.tag != .sequence) return error.InvalidPublicKey;
    const algorithm = try der.Element.parse(key, info.slice.start);
    const bits = try der.Element.parse(key, algorithm.slice.end);
    if (bits.identifier.tag != .bitstring or bits.slice.end - bits.slice.start < 2 or key[bits.slice.start] != 0) return error.InvalidPublicKey;
    const parts = try rsa.PublicKey.parseDer(key[bits.slice.start + 1 .. bits.slice.end]);
    const public = try rsa.PublicKey.fromBytes(parts.exponent, parts.modulus);
    const length = parts.modulus.len;
    if (length > rsa_bytes_maximum or message.len + 11 > length) return error.InvalidPublicKey;
    // 00 02, random nonzero padding, 00, the message.
    var block: [rsa_bytes_maximum]u8 = undefined;
    block[0] = 0;
    block[1] = 2;
    const padding = block[2 .. length - message.len - 1];
    for (padding) |*byte| byte.* = random.intRangeAtMost(u8, 1, 255);
    block[length - message.len - 1] = 0;
    @memcpy(block[length - message.len .. length], message);
    const Fe = @FieldType(rsa.PublicKey, "n").Fe;
    const value = try Fe.fromBytes(public.n, block[0..length], .big);
    const result = try public.n.powPublic(value, public.e);
    try result.toBytes(output[0..length], .big);
    return output[0..length];
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

/// The first `output.len` bytes a zlib stream decodes to, inflating no further: most of a chunk
/// is never read, and inflating all of it was most of what the bots spent. Fails when
/// `compressed` ends before them, as it does when only the start of a stream was decrypted. The
/// stream's checksum, at its end, goes unchecked.
fn inflatePrefix(compressed: []const u8, output: []u8) !void {
    var input: std.Io.Reader = .fixed(compressed);
    // Decoding straight into the output, with no window of its own, as nothing it decodes this
    // early refers further back than the output holds.
    var decompress: std.compress.flate.Decompress = .init(&input, .zlib, &.{});
    // Room for a whole match past the bytes wanted, which a match may write in one piece.
    var room: [peek_maximum + 258]u8 = undefined;
    assert(output.len <= peek_maximum);
    var writer: std.Io.Writer = .fixed(&room);
    decompress.reader.streamExact(&writer, output.len) catch |err| return decompress.err orelse err;
    @memcpy(output, room[0..output.len]);
}

/// The most of a packet the bots decode when they read only its start: its id and, for a chunk,
/// the position after it.
const peek_maximum = 16;

/// How far every frame is decrypted before it is read: its length, the compressed length of its
/// packet, and the start of the packet, as far as `peek_maximum` takes. A frame no longer is read
/// whole.
const head_bytes = 5 + 5 + peek_maximum;

test "the input decrypts in place on past the stretches passed by, and as the read is dropped" {
    var prng: std.Random.DefaultPrng = .init(2);
    const random = prng.random();
    var secret: [16]u8 = undefined;
    random.bytes(&secret);
    // A stream as the server sends it, encrypted from the first byte.
    var message: [1 << 16]u8 = undefined;
    random.bytes(&message);
    var wire = message;
    var server = java.Cipher.init(secret);
    server.transform(.encrypt, &wire, &wire);

    var input: [4096]u8 = undefined;
    var output: [16]u8 = undefined;
    var bot: Bot = .{ .index = 1, .input = &input, .output = &output, .random = .init(0) };
    bot.receiving = java.Cipher.init(secret);
    var sent: usize = 0;
    var consumed: usize = 0;
    while (consumed < wire.len) {
        // A read of some of what the server sent, as the socket hands it over.
        const arrived = @min(wire.len - sent, input.len - bot.filled, random.uintAtMost(usize, 1500));
        @memcpy(input[bot.filled..][0..arrived], wire[sent..][0..arrived]);
        bot.filled += arrived;
        sent += arrived;
        // Stretches decrypted and passed by in turn, some shorter than the cipher's register.
        while (bot.decrypted_to < bot.filled) {
            const to = @min(bot.filled, bot.decrypted_to + random.uintAtMost(usize, if (random.boolean()) 12 else 400));
            if (random.boolean()) {
                const from = bot.decrypted_to;
                bot.decryptTo(&input, to);
                try std.testing.expectEqualSlices(u8, message[consumed + from .. consumed + to], input[from..to]);
            } else bot.skipTo(&input, to);
        }
        // Drop the start of the input as the receive loop does once it read it.
        const start = random.uintAtMost(usize, bot.filled);
        std.mem.copyForwards(u8, input[0 .. bot.filled - start], input[start..bot.filled]);
        bot.filled -= start;
        bot.decrypted_to -= start;
        consumed += start;
        if (sent == wire.len) consumed += bot.filled;
    }
}

test "a zlib stream's first bytes inflate from the start of it alone" {
    var encoder: @import("deflate").Encoder = try .init(std.testing.allocator, 6);
    defer encoder.deinit();
    var prng: std.Random.DefaultPrng = .init(1);
    var data: [64 * 1024]u8 = undefined;
    var compressed: [80 * 1024]u8 = undefined;
    // Random bytes, a chunk's shape of a short header and long runs, and runs from the first byte.
    for (0..3) |pattern| {
        switch (pattern) {
            0 => prng.random().bytes(&data),
            1 => {
                prng.random().bytes(data[0..16]);
                for (data[16..], 16..) |*byte, index| byte.* = @truncate(index / 4096);
            },
            else => @memset(&data, 7),
        }
        const stream = try encoder.encode(&data, &compressed);
        for ([_]usize{ 1, 9, peek_maximum }) |wanted| {
            var output: [peek_maximum]u8 = undefined;
            try inflatePrefix(stream, output[0..wanted]);
            try std.testing.expectEqualSlices(u8, data[0..wanted], output[0..wanted]);
        }
        // Too little of the stream fails rather than decoding something else.
        var output: [peek_maximum]u8 = undefined;
        try std.testing.expect(std.meta.isError(inflatePrefix(stream[0..2], &output)));
    }
}

test "block positions pack as the protocol expects" {
    try std.testing.expectEqual(@as(i64, (@as(i64, 1) << 38) | (3 << 12) | 2), blockPosition(.{ 1, 2, 3 }));
    const negative: u64 = @bitCast(blockPosition(.{ -1, -1, -1 }));
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), negative);
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
