//! Cross server benchmarks. `run` measures one server in one scenario with some number of bots,
//! `sweep` measures every combination of servers, scenarios and bot counts, one at a time, and
//! `report` draws the results of a sweep.

const std = @import("std");
const linux = std.os.linux;
const bot = @import("bot.zig");
const scenario = @import("scenario.zig");
const server_module = @import("server.zig");
const process = @import("process.zig");
const report = @import("report.zig");

const Server = server_module.Server;
const now = bot.now;

pub const Settings = struct {
    servers: []const server_module.Kind = &.{},
    scenarios: []const scenario.Kind = &.{},
    players: []const usize = &.{},
    warmup_s: u64 = 20,
    measure_s: u64 = 60,
    port: u16 = 25700,
    server_cpus: []const u8 = "0-7",
    bot_cpus: []const u8 = "8-15",
    bot_threads: usize = 4,
    join_interval_ms: u64 = 200,
    out: []const u8 = "runs/latest",
    keep_worlds: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return usage();
    const verb = args[1];
    if (std.mem.eql(u8, verb, "report")) {
        if (args.len != 3) return usage();
        return report.write(allocator, init.io, args[2]);
    }
    var settings: Settings = .{};
    for (args[2..]) |argument| try parseOption(allocator, &settings, argument);
    if (std.mem.eql(u8, verb, "run")) {
        if (settings.servers.len != 1 or settings.scenarios.len != 1 or settings.players.len != 1) return usage();
    } else if (!std.mem.eql(u8, verb, "sweep")) return usage();
    if (settings.servers.len == 0 or settings.scenarios.len == 0 or settings.players.len == 0) return usage();

    // Bots keep to their own CPUs, apart from the server's.
    try process.pin(settings.bot_cpus);
    const root = try std.process.currentPathAlloc(init.io, allocator);
    try std.Io.Dir.cwd().createDirPath(init.io, settings.out);
    const results_path = try std.fs.path.join(allocator, &.{ settings.out, "results.jsonl" });

    var failures: usize = 0;
    for (settings.scenarios) |kind| for (settings.players) |players| for (settings.servers) |server| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        std.log.info("{s} {s} with {d} players", .{ @tagName(server), @tagName(kind), players });
        const result = measure(arena.allocator(), init.io, root, settings, server, kind, players) catch |err| {
            std.log.err("{s} {s} {d}: {s}", .{ @tagName(server), @tagName(kind), players, @errorName(err) });
            failures += 1;
            continue;
        };
        if (result.problems.len != 0) failures += 1;
        try append(arena.allocator(), init.io, results_path, result);
        std.log.info("  {d:.2} cpu ms/tick, {d:.1} tps, {d:.2} mspt, {d:.0} MB peak, {d:.1} KB/s per player, {d:.1} MB written, world {d:.1} MB, {d} problems", .{
            result.window.cpu_ms_per_tick, result.window.tps, result.window.mspt.mean_ms, result.peak_rss_mb,
            result.window.received_kb_per_s_per_player, result.window.disk_write_mb, result.world_mb, result.problems.len,
        });
    };
    if (failures != 0) std.log.warn("{d} runs had problems, see {s}", .{ failures, results_path });
}

fn usage() error{InvalidArguments} {
    std.log.err(
        \\usage:
        \\  bench run --server=<name> --scenario=<name> --players=<count> [options]
        \\  bench sweep --servers=a,b --scenarios=a,b --players=1,2,5 [options]
        \\  bench report <directory>
        \\servers: vanilla lightning-rod pumpkin steel
        \\scenarios: idle wander spread explore build
        \\options: --warmup=<s> --seconds=<s> --port=<n> --server-cpus=<list> --bot-cpus=<list>
        \\         --bot-threads=<n> --join-interval=<ms> --out=<directory> --keep-worlds
    , .{});
    return error.InvalidArguments;
}

fn parseOption(allocator: std.mem.Allocator, settings: *Settings, argument: []const u8) !void {
    const equals = std.mem.indexOfScalar(u8, argument, '=');
    const name = argument[0 .. equals orelse argument.len];
    const value = if (equals) |at| argument[at + 1 ..] else "";
    if (std.mem.eql(u8, name, "--server") or std.mem.eql(u8, name, "--servers")) {
        settings.servers = try parseList(server_module.Kind, allocator, value);
    } else if (std.mem.eql(u8, name, "--scenario") or std.mem.eql(u8, name, "--scenarios")) {
        settings.scenarios = try parseList(scenario.Kind, allocator, value);
    } else if (std.mem.eql(u8, name, "--players")) {
        var list: std.ArrayList(usize) = .empty;
        var items = std.mem.tokenizeScalar(u8, value, ',');
        while (items.next()) |item| try list.append(allocator, try std.fmt.parseInt(usize, item, 10));
        settings.players = list.items;
    } else if (std.mem.eql(u8, name, "--warmup")) {
        settings.warmup_s = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        settings.measure_s = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--port")) {
        settings.port = try std.fmt.parseInt(u16, value, 10);
    } else if (std.mem.eql(u8, name, "--server-cpus")) {
        settings.server_cpus = value;
    } else if (std.mem.eql(u8, name, "--bot-cpus")) {
        settings.bot_cpus = value;
    } else if (std.mem.eql(u8, name, "--bot-threads")) {
        settings.bot_threads = try std.fmt.parseInt(usize, value, 10);
    } else if (std.mem.eql(u8, name, "--join-interval")) {
        settings.join_interval_ms = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--out")) {
        settings.out = value;
    } else if (std.mem.eql(u8, name, "--keep-worlds")) {
        settings.keep_worlds = true;
    } else {
        std.log.err("unknown option {s}", .{argument});
        return error.InvalidArguments;
    }
}

fn parseList(comptime T: type, allocator: std.mem.Allocator, value: []const u8) ![]const T {
    var list: std.ArrayList(T) = .empty;
    var items = std.mem.tokenizeScalar(u8, value, ',');
    while (items.next()) |item| try list.append(allocator, std.meta.stringToEnum(T, item) orelse {
        std.log.err("unknown name {s}", .{item});
        return error.InvalidArguments;
    });
    return list.items;
}

pub const Sample = struct {
    t_s: f64,
    phase: []const u8,
    cpu_s: f64,
    rss_mb: f64,
    threads: u64,
    disk_read_mb: f64,
    disk_write_mb: f64,
    received_mb: f64,
    sent_mb: f64,
    game_time: u64,
    playing: usize,
    chunks: u64,
};

pub const Mspt = struct {
    /// Where the numbers come from: the server's own tick query, its exported tick samples, or
    /// nothing when the server reports neither.
    source: []const u8 = "none",
    mean_ms: f64 = 0,
    p50_ms: f64 = 0,
    p95_ms: f64 = 0,
    p99_ms: f64 = 0,
    max_ms: f64 = 0,
};

pub const ThreadCpu = struct { name: []const u8, ms_per_tick: f64 };

/// What happened in the measured window, after joining, travelling and warming up.
pub const Window = struct {
    seconds: f64 = 0,
    tps: f64 = 0,
    /// CPU time of every server thread per tick, and in cores kept busy.
    cpu_ms_per_tick: f64 = 0,
    cpu_cores: f64 = 0,
    mspt: Mspt = .{},
    threads: []const ThreadCpu = &.{},
    rss_mb_mean: f64 = 0,
    rss_mb_max: f64 = 0,
    /// Bytes from the server to all bots and from all bots to the server, as they crossed the
    /// socket, compression included.
    received_kb_per_s: f64 = 0,
    received_kb_per_s_per_player: f64 = 0,
    sent_kb_per_s: f64 = 0,
    chunks_per_s: f64 = 0,
    disk_read_mb: f64 = 0,
    disk_write_mb: f64 = 0,
};

pub const Result = struct {
    server: []const u8,
    scenario: []const u8,
    players: usize,
    started_unix_s: i64,
    startup_s: f64,
    /// From the first bot connecting to the last one in play.
    join_s: f64 = 0,
    /// The median time from a bot entering play to it holding a full view.
    view_s: f64 = 0,
    travel_s: f64 = 0,
    window: Window = .{},
    peak_rss_mb: f64 = 0,
    total_disk_write_mb: f64 = 0,
    total_received_mb: f64 = 0,
    world_mb: f64 = 0,
    stop_s: f64 = 0,
    clean_stop: bool = false,
    bots: BotSummary = .{},
    /// Everything the bots received over the whole run, per player.
    traffic: TrafficSummary = .{},
    problems: []const []const u8 = &.{},
    samples: []const Sample = &.{},
};

pub const PacketTraffic = struct { name: []const u8, count_per_player: f64, kb_per_player: f64, decoded_kb_per_player: f64 };

pub const TrafficSummary = struct {
    /// Login and configuration, registries included.
    setup_kb_per_player: f64 = 0,
    setup_decoded_kb_per_player: f64 = 0,
    play_kb_per_player: f64 = 0,
    play_decoded_kb_per_player: f64 = 0,
    /// Play packets by kind, the heaviest first.
    packets: []const PacketTraffic = &.{},
};

pub const BotSummary = struct {
    joined: usize = 0,
    failed: usize = 0,
    corrections: u64 = 0,
    chunks: u64 = 0,
    unloads: u64 = 0,
    players_seen: u64 = 0,
    entities_seen: u64 = 0,
    edits: u64 = 0,
    acks: u64 = 0,
    block_changes: u64 = 0,
    packets_received: u64 = 0,
    packets_sent: u64 = 0,
};

const Run = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    server: *Server,
    swarm: *bot.Swarm,
    started_ns: u64,
    samples: std.ArrayList(Sample) = .empty,
    phase: []const u8 = "start",
    last_sample_ns: u64 = 0,
    last_query_ns: u64 = 0,

    /// Samples once a second until a condition holds or a limit passes.
    fn wait(self: *Run, limit_s: u64, comptime done: ?fn (*Run) bool) !bool {
        const until = now() + limit_s * std.time.ns_per_s;
        while (now() < until) {
            if (self.server.exited.load(.acquire)) return error.ServerExited;
            if (done) |condition| if (condition(self)) return true;
            if (now() - self.last_sample_ns >= std.time.ns_per_s) try self.sample();
            if (std.mem.eql(u8, self.phase, "measure") and now() - self.last_query_ns >= 5 * std.time.ns_per_s) {
                // Vanilla's report covers the last 100 ticks, so one every five seconds covers all.
                self.last_query_ns = now();
                self.server.queryTicks() catch {};
            }
            try self.io.sleep(.fromMilliseconds(50), .awake);
        }
        return done == null;
    }

    fn sample(self: *Run) !void {
        self.last_sample_ns = now();
        const taken = try process.sample(self.server.pid);
        const game_time, _ = self.swarm.gameTime();
        try self.samples.append(self.allocator, .{
            .t_s = seconds(self.last_sample_ns - self.started_ns),
            .phase = self.phase,
            .cpu_s = seconds(taken.cpu_ns),
            .rss_mb = megabytes(taken.rss_bytes),
            .threads = taken.threads,
            .disk_read_mb = megabytes(taken.disk_read_bytes),
            .disk_write_mb = megabytes(taken.disk_write_bytes),
            .received_mb = megabytes(self.swarm.total(.bytes_in)),
            .sent_mb = megabytes(self.swarm.total(.bytes_out)),
            .game_time = game_time,
            .playing = self.swarm.count(.play),
            .chunks = self.swarm.total(.chunks),
        });
    }

    fn joined(self: *Run) bool {
        return self.swarm.reached(.spawned_ns) + self.swarm.count(.failed) == self.swarm.bots.len;
    }

    fn arrived(self: *Run) bool {
        return self.swarm.reached(.arrived_ns) + self.swarm.count(.failed) == self.swarm.bots.len;
    }
};

fn measure(allocator: std.mem.Allocator, io: std.Io, root: []const u8, settings: Settings, kind: server_module.Kind, scenario_kind: scenario.Kind, players: usize) !Result {
    const directory = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{d}", .{ settings.out, @tagName(scenario_kind), @tagName(kind), players });
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const metrics = try std.fmt.allocPrint(allocator, "/dev/shm/mc-server-bench-{d}", .{linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, metrics) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, metrics) catch {};
    var result: Result = .{ .server = @tagName(kind), .scenario = @tagName(scenario_kind), .players = players, .started_unix_s = std.Io.Clock.now(.real, io).toSeconds(), .startup_s = 0 };
    var problems: std.ArrayList([]const u8) = .empty;

    if (bot.probe(settings.port)) return error.PortInUse;
    const launched = now();
    const server = try Server.start(allocator, io, .{
        .kind = kind,
        .root = root,
        .directory = directory,
        .port = settings.port,
        .players = players,
        .cpus = settings.server_cpus,
        .metrics = metrics,
    });
    var stopped = false;
    defer if (!stopped) {
        _ = server.stop(10) catch {};
    };
    while (!bot.probe(settings.port)) {
        if (server.exited.load(.acquire)) return error.ServerExited;
        if (now() - launched > 300 * std.time.ns_per_s) return error.ServerNeverReady;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    result.startup_s = seconds(now() - launched);
    try server.configure();

    const swarm = try bot.Swarm.init(allocator, .{ .port = settings.port, .kind = scenario_kind, .join_interval_ns = settings.join_interval_ms * std.time.ns_per_ms }, players, settings.bot_threads);
    var run: Run = .{ .allocator = allocator, .io = io, .server = server, .swarm = swarm, .started_ns = launched };
    try swarm.start();
    var swarm_stopped = false;
    defer if (!swarm_stopped) swarm.stop();

    run.phase = "join";
    if (!try run.wait(players * settings.join_interval_ms / 1000 + 120, Run.joined)) try problems.append(allocator, "not every bot joined in time");
    result.join_s = seconds(latest(swarm, .spawned_ns) -| swarm.started_ns);
    if (scenario_kind.travels()) {
        run.phase = "travel";
        const travel_start = now();
        if (!try run.wait(300, Run.arrived)) try problems.append(allocator, "not every bot reached its spot in time");
        result.travel_s = seconds(now() - travel_start);
    }
    run.phase = "warmup";
    _ = try run.wait(settings.warmup_s, null);

    run.phase = "measure";
    try run.sample();
    const first = run.samples.items.len - 1;
    const window_start = now();
    const first_usage = try process.sample(server.pid);
    const first_threads = try threadTimes(allocator, io, server.pid);
    const first_time, const first_time_ns = swarm.gameTime();
    const first_received = swarm.total(.bytes_in);
    const first_sent = swarm.total(.bytes_out);
    const first_chunks = swarm.total(.chunks);
    run.last_query_ns = now();
    _ = try run.wait(settings.measure_s, null);
    try server.queryTicks();
    try run.sample();
    const window_end = now();
    const last_usage = try process.sample(server.pid);
    const last_threads = try threadTimes(allocator, io, server.pid);
    const last_time, const last_time_ns = swarm.gameTime();
    // Give the last tick report a moment to arrive.
    try io.sleep(.fromMilliseconds(500), .awake);

    const window = &result.window;
    window.seconds = seconds(window_end - window_start);
    window.tps = if (last_time_ns > first_time_ns and last_time > first_time) @as(f64, @floatFromInt(last_time - first_time)) / seconds(last_time_ns - first_time_ns) else 0;
    const ticks = if (window.tps > 0) window.tps * window.seconds else 20 * window.seconds;
    window.cpu_ms_per_tick = @as(f64, @floatFromInt(last_usage.cpu_ns - first_usage.cpu_ns)) / std.time.ns_per_ms / ticks;
    window.cpu_cores = seconds(last_usage.cpu_ns - first_usage.cpu_ns) / window.seconds;
    window.threads = try threadBreakdown(allocator, first_threads, last_threads, ticks);
    for (run.samples.items[first..]) |entry| {
        window.rss_mb_mean += entry.rss_mb;
        window.rss_mb_max = @max(window.rss_mb_max, entry.rss_mb);
    }
    window.rss_mb_mean /= @floatFromInt(run.samples.items.len - first);
    window.received_kb_per_s = kilobytes(swarm.total(.bytes_in) - first_received) / window.seconds;
    window.received_kb_per_s_per_player = window.received_kb_per_s / @as(f64, @floatFromInt(players));
    window.sent_kb_per_s = kilobytes(swarm.total(.bytes_out) - first_sent) / window.seconds;
    window.chunks_per_s = @as(f64, @floatFromInt(swarm.total(.chunks) - first_chunks)) / window.seconds;
    window.disk_read_mb = megabytes(last_usage.disk_read_bytes - first_usage.disk_read_bytes);
    window.disk_write_mb = megabytes(last_usage.disk_write_bytes - first_usage.disk_write_bytes);
    window.mspt = if (kind == .@"lightning-rod")
        try exportedTicks(allocator, io, metrics, window_start, window_end)
    else
        reportedTicks(server, window_start, window_end + std.time.ns_per_s);
    if (window.tps == 0) try problems.append(allocator, "no world time reached the bots, so ticks per second is unknown");

    result.view_s = try medianGap(allocator, swarm, .spawned_ns, .viewed_ns);
    result.bots = summarize(swarm);
    try check(allocator, swarm, scenario_kind, &problems);

    run.phase = "stop";
    swarm.stop();
    swarm_stopped = true;
    result.traffic = try traffic(allocator, swarm);
    result.total_received_mb = megabytes(swarm.total(.bytes_in));
    const before_stop = try process.sample(server.pid);
    result.peak_rss_mb = megabytes(before_stop.peak_rss_bytes);
    const ending = try server.stop(180);
    stopped = true;
    result.stop_s = ending.seconds;
    result.clean_stop = ending.clean;
    if (!ending.clean) try problems.append(allocator, "the server did not stop in time and was killed");
    result.total_disk_write_mb = megabytes(before_stop.disk_write_bytes);
    for (kind.worldPaths()) |name| {
        const world = try std.fs.path.join(allocator, &.{ directory, name });
        result.world_mb += megabytes(try diskUsage(allocator, io, world));
        if (!settings.keep_worlds) std.Io.Dir.cwd().deleteTree(io, world) catch {};
    }
    if (result.world_mb == 0) try problems.append(allocator, "the server saved no world");

    result.samples = run.samples.items;
    result.problems = problems.items;
    try writeJson(allocator, io, try std.fs.path.join(allocator, &.{ directory, "result.json" }), result);
    return result;
}

/// What the bots must have seen for a run to count: everyone in, a full view each, the server
/// never pulling anyone back, and whatever the scenario asks for.
fn check(allocator: std.mem.Allocator, swarm: *bot.Swarm, kind: scenario.Kind, problems: *std.ArrayList([]const u8)) !void {
    for (swarm.bots) |*each| {
        const counters = &each.counters;
        if (each.phase.load(.acquire) == .failed) {
            try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} failed: {s} {s}", .{ each.label(), @errorName(each.failure.?), each.reasonText() }));
            continue;
        }
        if (counters.get(.viewed_ns) == 0) try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} got {d} chunks, short of a full view", .{ each.label(), counters.get(.chunks) }));
        if (counters.get(.corrections) != 0) try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} was moved back {d} times", .{ each.label(), counters.get(.corrections) }));
        if (counters.get(.keepalives) == 0) try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} got no keep alive", .{each.label()}));
        switch (kind) {
            .idle, .wander => if (counters.get(.players_seen) + 1 < swarm.bots.len)
                try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} saw {d} of {d} other players", .{ each.label(), counters.get(.players_seen), swarm.bots.len - 1 })),
            .spread, .build => if (counters.get(.arrived_ns) == 0) try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} never reached its spot", .{each.label()})),
            .explore => {},
        }
        // Servers acknowledge every edit up to a sequence, often several at once, so the newest
        // acknowledged sequence must keep within a second of the newest edit sent.
        if (kind == .build and counters.get(.acked_sequence) + 20 < @as(u64, @intCast(each.sequence)))
            try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} had edits acknowledged up to {d} of {d}", .{ each.label(), counters.get(.acked_sequence), each.sequence }));
        if (kind == .build and counters.get(.block_changes) == 0)
            try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} saw no block change", .{each.label()}));
        if (kind == .explore) {
            // A bot flying a block a tick into new terrain needs a new column of chunks every 16 ticks.
            const expected = scenario.viewChunks() + each.ticks / 16 * (2 * scenario.view_distance) / 2;
            if (counters.get(.chunks) < expected) try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} got {d} chunks while exploring, expected at least {d}", .{ each.label(), counters.get(.chunks), expected }));
        }
    }
}

fn summarize(swarm: *bot.Swarm) BotSummary {
    return .{
        .joined = swarm.reached(.joined_ns),
        .failed = swarm.count(.failed),
        .corrections = swarm.total(.corrections),
        .chunks = swarm.total(.chunks),
        .unloads = swarm.total(.unloads),
        .players_seen = swarm.total(.players_seen),
        .entities_seen = swarm.total(.entities_seen),
        .edits = swarm.total(.edits),
        .acks = swarm.total(.acks),
        .block_changes = swarm.total(.block_changes),
        .packets_received = swarm.total(.packets_in),
        .packets_sent = swarm.total(.packets_out),
    };
}

fn latest(swarm: *bot.Swarm, counter: bot.Counter) u64 {
    var value: u64 = 0;
    for (swarm.bots) |*each| value = @max(value, each.counters.get(counter));
    return value;
}

fn reportedTicks(server: *Server, from_ns: u64, to_ns: u64) Mspt {
    var reports: [256]server_module.TickReport = undefined;
    const count = server.tickReports(from_ns, to_ns, &reports);
    if (count == 0) return .{};
    var mspt: Mspt = .{ .source = "tick query" };
    for (reports[0..count]) |entry| {
        mspt.mean_ms += entry.mean_ms;
        mspt.p50_ms += entry.p50_ms;
        mspt.p95_ms += entry.p95_ms;
        mspt.p99_ms += entry.p99_ms;
        mspt.max_ms = @max(mspt.max_ms, entry.p99_ms);
    }
    // Each report covers the same hundred ticks, so their mean is the mean of the window.
    const n: f64 = @floatFromInt(count);
    mspt.mean_ms /= n;
    mspt.p50_ms /= n;
    mspt.p95_ms /= n;
    mspt.p99_ms /= n;
    return mspt;
}

/// Lightning Rod's exported duration of every tick in the window.
fn exportedTicks(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, from_ns: u64, to_ns: u64) !Mspt {
    var durations: std.ArrayList(u64) = .empty;
    var dir = std.Io.Dir.cwd().openDir(io, directory, .{ .iterate = true }) catch return .{};
    defer dir.close(io);
    var entries = dir.iterate();
    const Observation = struct { type: []const u8 = "", name: []const u8 = "", recorded_ns: i128 = 0, value: u64 = 0 };
    while (try entries.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".metrics.jsonl")) continue;
        const bytes = try dir.readFileAlloc(io, entry.name, allocator, .limited(1 << 30));
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "\"server.tick\"") == null) continue;
            const parsed = std.json.parseFromSliceLeaky(Observation, allocator, line, .{ .ignore_unknown_fields = true }) catch continue;
            if (parsed.recorded_ns < from_ns or parsed.recorded_ns > to_ns) continue;
            try durations.append(allocator, parsed.value);
        }
    }
    if (durations.items.len == 0) return .{};
    std.mem.sort(u64, durations.items, {}, std.sort.asc(u64));
    var sum: u128 = 0;
    for (durations.items) |value| sum += value;
    const at = struct {
        fn quantile(values: []const u64, fraction: f64) f64 {
            const index: usize = @intFromFloat(@floor(fraction * @as(f64, @floatFromInt(values.len - 1))));
            return @as(f64, @floatFromInt(values[index])) / std.time.ns_per_ms;
        }
    }.quantile;
    return .{
        .source = "server.tick samples",
        .mean_ms = @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(durations.items.len)) / std.time.ns_per_ms,
        .p50_ms = at(durations.items, 0.5),
        .p95_ms = at(durations.items, 0.95),
        .p99_ms = at(durations.items, 0.99),
        .max_ms = at(durations.items, 1),
    };
}

const ThreadTime = struct { id: u32, name: []const u8, ticks: u64 };

fn threadTimes(allocator: std.mem.Allocator, io: std.Io, pid: linux.pid_t) ![]const ThreadTime {
    var list: std.ArrayList(ThreadTime) = .empty;
    const path = try std.fmt.allocPrint(allocator, "/proc/{d}/task", .{pid});
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        const id = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        var buffer: [1024]u8 = undefined;
        const read = process.readProc(try std.fmt.allocPrintSentinel(allocator, "/proc/{d}/task/{s}/stat", .{ pid, entry.name }, 0), &buffer) catch continue;
        const stat = try allocator.dupe(u8, read);
        const open = std.mem.indexOfScalar(u8, stat, '(') orelse continue;
        const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
        var index: usize = 3;
        var ticks: u64 = 0;
        while (fields.next()) |field| : (index += 1) {
            if (index == 14 or index == 15) ticks += std.fmt.parseInt(u64, field, 10) catch 0;
            if (index == 15) break;
        }
        try list.append(allocator, .{ .id = id, .name = stat[open + 1 .. close], .ticks = ticks });
    }
    return list.items;
}

/// CPU per tick by kind of thread, numbered pools folded together, busiest first.
fn threadBreakdown(allocator: std.mem.Allocator, first: []const ThreadTime, last: []const ThreadTime, ticks: f64) ![]const ThreadCpu {
    var groups: std.StringArrayHashMapUnmanaged(u64) = .empty;
    for (last) |thread| {
        var before: u64 = 0;
        for (first) |earlier| if (earlier.id == thread.id) {
            before = earlier.ticks;
        };
        const name = std.mem.trimEnd(u8, thread.name, "0123456789-#_ ");
        const entry = try groups.getOrPutValue(allocator, if (name.len == 0) thread.name else name, 0);
        entry.value_ptr.* += thread.ticks -| before;
    }
    var list: std.ArrayList(ThreadCpu) = .empty;
    var iterator = groups.iterator();
    while (iterator.next()) |entry| {
        if (entry.value_ptr.* == 0) continue;
        try list.append(allocator, .{ .name = entry.key_ptr.*, .ms_per_tick = @as(f64, @floatFromInt(entry.value_ptr.* * 10)) / ticks });
    }
    std.mem.sort(ThreadCpu, list.items, {}, struct {
        fn busier(_: void, a: ThreadCpu, b: ThreadCpu) bool {
            return a.ms_per_tick > b.ms_per_tick;
        }
    }.busier);
    return list.items[0..@min(list.items.len, 12)];
}

fn diskUsage(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !u64 {
    std.Io.Dir.cwd().access(io, path, .{}) catch return 0;
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "du", "-sb", path } });
    if (result.term != .exited or result.term.exited != 0) return 0;
    var words = std.mem.tokenizeAny(u8, result.stdout, " \t\n");
    return std.fmt.parseInt(u64, words.next() orelse return 0, 10);
}

fn writeJson(allocator: std.mem.Allocator, io: std.Io, path: []const u8, value: anytype) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_1 }, &output.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = output.written() });
}

fn append(allocator: std.mem.Allocator, io: std.Io, path: []const u8, result: Result) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(result, .{}, &output.writer);
    try output.writer.writeByte('\n');
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    defer file.close(io);
    const end = try file.length(io);
    try file.writePositionalAll(io, output.written(), end);
}

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_s;
}

fn megabytes(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024 * 1024);
}

fn kilobytes(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1024;
}

test {
    _ = bot;
    _ = scenario;
    _ = server_module;
    _ = process;
}

test "thread times cover the threads of a process" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const threads = try threadTimes(arena.allocator(), std.testing.io, linux.getpid());
    try std.testing.expect(threads.len >= 1);
    var burned: u64 = 0;
    const started = now();
    while (now() - started < 50 * std.time.ns_per_ms) burned +%= 1;
    std.mem.doNotOptimizeAway(burned);
    const later = try threadTimes(arena.allocator(), std.testing.io, linux.getpid());
    const breakdown = try threadBreakdown(arena.allocator(), threads, later, 1);
    try std.testing.expect(breakdown.len >= 1);
}

/// The median time between two moments of each bot, over the bots that saw both.
fn medianGap(allocator: std.mem.Allocator, swarm: *bot.Swarm, from: bot.Counter, to: bot.Counter) !f64 {
    var gaps: std.ArrayList(u64) = .empty;
    for (swarm.bots) |*each| {
        const start = each.counters.get(from);
        const end = each.counters.get(to);
        if (start != 0 and end >= start) try gaps.append(allocator, end - start);
    }
    if (gaps.items.len == 0) return 0;
    std.mem.sort(u64, gaps.items, {}, std.sort.asc(u64));
    return seconds(gaps.items[gaps.items.len / 2]);
}

fn traffic(allocator: std.mem.Allocator, swarm: *bot.Swarm) !TrafficSummary {
    const players: f64 = @floatFromInt(swarm.bots.len);
    var summary: TrafficSummary = .{};
    var totals: [256]bot.Traffic = @splat(.{});
    for (swarm.bots) |*each| {
        summary.setup_kb_per_player += kilobytes(each.setup.wire_bytes) / players;
        summary.setup_decoded_kb_per_player += kilobytes(each.setup.decoded_bytes) / players;
        for (&totals, each.play) |*total, kind| {
            total.count += kind.count;
            total.wire_bytes += kind.wire_bytes;
            total.decoded_bytes += kind.decoded_bytes;
        }
    }
    var packets: std.ArrayList(PacketTraffic) = .empty;
    for (totals, 0..) |total, id| {
        if (total.count == 0) continue;
        summary.play_kb_per_player += kilobytes(total.wire_bytes) / players;
        summary.play_decoded_kb_per_player += kilobytes(total.decoded_bytes) / players;
        try packets.append(allocator, .{
            .name = bot.playPacketName(id),
            .count_per_player = @as(f64, @floatFromInt(total.count)) / players,
            .kb_per_player = kilobytes(total.wire_bytes) / players,
            .decoded_kb_per_player = kilobytes(total.decoded_bytes) / players,
        });
    }
    std.mem.sort(PacketTraffic, packets.items, {}, struct {
        fn heavier(_: void, a: PacketTraffic, b: PacketTraffic) bool {
            return a.kb_per_player > b.kb_per_player;
        }
    }.heavier);
    summary.packets = packets.items;
    return summary;
}
