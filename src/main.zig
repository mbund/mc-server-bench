//! Cross server benchmarks. `run` measures one server in one scenario on one terrain with some
//! number of bots, which the scripts in scenarios/ repeat for every server and count they compare,
//! and `report` writes the results of the runs as one Markdown file.

const std = @import("std");
const linux = std.os.linux;
const bot = @import("bot.zig");
const scenario = @import("scenario.zig");
const server_module = @import("server.zig");
const process = @import("process.zig");
const report = @import("report.zig");
const config = @import("config.zig");
const pregen_module = @import("pregen.zig");

const Server = server_module.Server;
const now = bot.now;

pub const Settings = struct {
    server: ?server_module.Kind = null,
    scenario: ?scenario.Kind = null,
    terrain: server_module.Terrain = .flat,
    /// The players of each step of the run, which goes on to the next while the server keeps up.
    players: []const usize = &.{1},
    /// Cows the cows scenario summons around its player.
    /// The cows of each step of a cows run, around its one player.
    cows: []const usize = &.{},
    warmup_s: u64 = 20,
    measure_s: u64 = 60,
    /// Half the machine's CPUs each when not given.
    server_cpus: ?[]const u8 = null,
    bot_cpus: ?[]const u8 = null,
    bot_threads: usize = 4,
    join_interval_ms: u64 = 200,
    out: []const u8 = "runs/latest",
    keep_worlds: bool = false,
    dump_frames: ?[]const u8 = null,
    /// Chunks out from the centre that `pregen` generates.
    /// The terrain's own unless given.
    radius: ?i32 = null,
    /// Another dimension for `pregen` to generate into the existing world, like minecraft:the_nether.
    dimension: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len < 2) return usage();
    const verb = args[1];
    if (std.mem.eql(u8, verb, "report")) {
        if (args.len != 3 and args.len != 4) return usage();
        const charts_url = if (args.len == 4) (if (std.mem.startsWith(u8, args[3], "--charts-url=")) args[3]["--charts-url=".len..] else return usage()) else null;
        return report.write(allocator, init.io, args[2], charts_url);
    }
    var settings: Settings = .{};
    for (args[2..]) |argument| try parseOption(&settings, argument);
    // The server takes the first half of the CPUs and the bots the second, unless told otherwise.
    const cpus = try std.Thread.getCpuCount();
    if (cpus < 2) return error.TooFewCpus;
    if (settings.server_cpus == null) settings.server_cpus = try std.fmt.allocPrint(allocator, "0-{d}", .{cpus / 2 - 1});
    if (settings.bot_cpus == null) settings.bot_cpus = try std.fmt.allocPrint(allocator, "{d}-{d}", .{ cpus / 2, cpus - 1 });
    if (std.mem.eql(u8, verb, "recipe")) {
        const kind = settings.server orelse return usage();
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        try stdout.interface.writeAll(try pregen_module.recipe(allocator, kind, settings.terrain));
        return stdout.interface.flush();
    }
    if (std.mem.eql(u8, verb, "pregen")) {
        return pregen(allocator, init.io, try std.process.currentPathAlloc(init.io, allocator), settings);
    }
    if (!std.mem.eql(u8, verb, "run")) return usage();
    const server = settings.server orelse return usage();
    const kind = settings.scenario orelse return usage();
    // A cows run steps through cows around one player, and every other run through players.
    // Cows come only with the cows scenario, which always has some, and steps grow.
    if ((kind == .cows) != (settings.cows.len != 0)) return usage();
    const steps = if (kind == .cows) settings.cows else settings.players;
    if (steps.len == 0 or steps[0] == 0) return usage();
    for (steps[1..], steps[0 .. steps.len - 1]) |after, before| if (after <= before) return usage();
    // Before pinning, while every CPU still counts.
    const host = try hostInfo(allocator, init.io);
    // Bots keep to their own CPUs, apart from the server's.
    try process.pin(settings.bot_cpus.?);
    const root = try std.process.currentPathAlloc(init.io, allocator);
    try std.Io.Dir.cwd().createDirPath(init.io, settings.out);
    const results_path = try std.fs.path.join(allocator, &.{ settings.out, "results.jsonl" });

    try measure(allocator, init.io, root, settings, server, kind, steps, results_path, host);
}

fn usage() error{InvalidArguments} {
    std.log.err(
        \\usage:
        \\  bench run --server=<name> --scenario=<name> [--terrain=flat|real|wide] [--players=<count>,...] [--cows=<count>,...] [options]
        \\                                    measure one server in one scenario, a step for each count of players, or of cows
        \\                                    around one player, while it keeps up, adding a result for each to <out>/results.jsonl
        \\  bench report <directory> [--charts-url=<where the charts are published>]
        \\  bench recipe --server=vanilla|steel [--terrain=flat|real|wide]
        \\                                    print what decides the world pregen makes, which CI keys it on
        \\  bench pregen [--server=vanilla|steel] [--terrain=flat|real|wide] [--radius=<chunks>] [--dimension=<name>]
        \\                                    generate a world runs start from, or add a dimension to it
        \\servers: vanilla lightning-rod pumpkin steel paper paper-antixray-1 fabric fabric-occlusion
        \\scenarios: idle wander spread explore build cows
        \\options: --warmup=<s> --seconds=<s> --server-cpus=<list> --bot-cpus=<list>
        \\         --bot-threads=<n> --join-interval=<ms> --out=<directory> --keep-worlds
        \\         --dump-frames=<path prefix>
    , .{});
    return error.InvalidArguments;
}

fn parseOption(settings: *Settings, argument: []const u8) !void {
    const equals = std.mem.indexOfScalar(u8, argument, '=');
    const name = argument[0 .. equals orelse argument.len];
    const value = if (equals) |at| argument[at + 1 ..] else "";
    if (std.mem.eql(u8, name, "--server")) {
        settings.server = try parseName(server_module.Kind, value);
    } else if (std.mem.eql(u8, name, "--scenario")) {
        settings.scenario = try parseName(scenario.Kind, value);
    } else if (std.mem.eql(u8, name, "--players")) {
        var list: std.ArrayList(usize) = .empty;
        var items = std.mem.tokenizeScalar(u8, value, ',');
        while (items.next()) |item| try list.append(std.heap.page_allocator, try std.fmt.parseInt(usize, item, 10));
        settings.players = list.items;
    } else if (std.mem.eql(u8, name, "--cows")) {
        var list: std.ArrayList(usize) = .empty;
        var items = std.mem.tokenizeScalar(u8, value, ',');
        while (items.next()) |item| try list.append(std.heap.page_allocator, try std.fmt.parseInt(usize, item, 10));
        settings.cows = list.items;
    } else if (std.mem.eql(u8, name, "--warmup")) {
        settings.warmup_s = try std.fmt.parseInt(u64, value, 10);
    } else if (std.mem.eql(u8, name, "--seconds")) {
        settings.measure_s = try std.fmt.parseInt(u64, value, 10);
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
    } else if (std.mem.eql(u8, name, "--terrain")) {
        settings.terrain = try parseName(server_module.Terrain, value);
    } else if (std.mem.eql(u8, name, "--radius")) {
        settings.radius = try std.fmt.parseInt(i32, value, 10);
    } else if (std.mem.eql(u8, name, "--dimension")) {
        settings.dimension = value;
    } else if (std.mem.eql(u8, name, "--dump-frames")) {
        settings.dump_frames = value;
    } else if (std.mem.eql(u8, name, "--keep-worlds")) {
        settings.keep_worlds = true;
    } else {
        std.log.err("unknown option {s}", .{argument});
        return error.InvalidArguments;
    }
}

fn parseName(comptime T: type, value: []const u8) !T {
    return std.meta.stringToEnum(T, value) orelse {
        std.log.err("unknown name {s}", .{value});
        return error.InvalidArguments;
    };
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
    /// Round trips of the pings players sent in the window, and how many came back.
    ping_p50_ms: f64 = 0,
    ping_p99_ms: f64 = 0,
    pings: u64 = 0,
    /// The share of the bots' own CPUs they kept busy.
    bot_cpu: f64 = 0,
};

/// The machine a run measured on, as runs in CI land on different ones.
pub const Host = struct {
    cpu: []const u8 = "",
    cpus: usize = 0,
    kernel: []const u8 = "",
    memory_mb: f64 = 0,
};

/// Proc files report no size, so they are read to their end.
fn readProc(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &buffer);
    return reader.interface.allocRemaining(allocator, .limited(1 << 22));
}

fn hostInfo(allocator: std.mem.Allocator, io: std.Io) !Host {
    var host: Host = .{ .cpus = try std.Thread.getCpuCount() };
    const cpuinfo = try readProc(allocator, io, "/proc/cpuinfo");
    var lines = std.mem.splitScalar(u8, cpuinfo, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, "model name")) {
        host.cpu = std.mem.trim(u8, line[(std.mem.indexOfScalar(u8, line, ':') orelse continue) + 1 ..], " \t");
        break;
    };
    const meminfo = try readProc(allocator, io, "/proc/meminfo");
    var fields = std.mem.tokenizeAny(u8, meminfo, " \n");
    while (fields.next()) |field| if (std.mem.eql(u8, field, "MemTotal:")) {
        host.memory_mb = @as(f64, @floatFromInt(try std.fmt.parseInt(u64, fields.next() orelse break, 10))) / 1024;
        break;
    };
    const name = std.posix.uname();
    host.kernel = try allocator.dupe(u8, std.mem.sliceTo(&name.release, 0));
    return host;
}

pub const Result = struct {
    server: []const u8,
    /// The release or commit measured.
    version: []const u8 = "",
    host: Host = .{},
    terrain: []const u8,
    scenario: []const u8,
    players: usize,
    /// Cows summoned around the players, in the cows scenario.
    cows: usize = 0,
    started_unix_s: i64,
    /// From launching the server to its first answer to a status request.
    startup_s: f64,
    /// From launching the server to the first bot, logged in, holding its first chunk, and its
    /// full render distance. The first bot joins as soon as the server answers.
    first_chunk_s: f64 = 0,
    full_view_s: f64 = 0,
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
    /// The limit this step broke, which ended the run, or empty when the server kept up.
    limit: []const u8 = "",
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
    chunk_bytes: u64 = 0,
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
    cows: usize = 0,

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
        return self.swarm.reached(.spawned_ns) + self.swarm.count(.failed) == self.swarm.admitted;
    }

    fn viewed(self: *Run) bool {
        return self.swarm.reached(.viewed_ns) + self.swarm.count(.failed) == self.swarm.admitted;
    }

    fn sawCows(self: *Run) bool {
        return self.swarm.total(.cows_seen) >= self.cows;
    }

    fn arrived(self: *Run) bool {
        return self.swarm.reached(.arrived_ns) + self.swarm.count(.failed) == self.swarm.admitted;
    }
};

/// What makes a step of players too many. A step that breaks one ends the run, recorded with the
/// limit it broke, so the step before it is the most the server held.
const limits = struct {
    /// The server falling behind, from the world time the bots receive.
    const tps = 19.0;
    /// The server answering a player's ping late, which it does as it handles their packets.
    const ping_p99_ms = 200.0;
    /// The bots' own CPUs this busy, when the bots rather than the server set the limit.
    const bot_cpu = 0.95;
};

/// Measures one server in one scenario. The server starts once, then each count in `steps` comes
/// in turn, players joining or, in the cows scenario, cows around its one player, settles and is
/// measured, adding a result for each to `results_path`, until a step breaks a limit. One step is
/// a plain run.
fn measure(allocator: std.mem.Allocator, io: std.Io, root: []const u8, settings: Settings, kind: server_module.Kind, scenario_kind: scenario.Kind, steps: []const usize, results_path: []const u8, host: Host) !void {
    const counting_cows = scenario_kind == .cows;
    const most = std.mem.max(usize, steps);
    const label = if (steps.len == 1) try std.fmt.allocPrint(allocator, "{d}", .{steps[0]}) else "ramp";
    const directory = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{s}/{s}", .{ settings.out, @tagName(settings.terrain), @tagName(scenario_kind), @tagName(kind), label });
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const metrics = try std.fmt.allocPrint(allocator, "/dev/shm/mc-server-bench-{d}", .{linux.getpid()});
    std.Io.Dir.cwd().deleteTree(io, metrics) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, metrics) catch {};
    var base: Result = .{
        .server = @tagName(kind),
        .version = try server_module.version(kind, allocator, io, root),
        .host = host,
        .terrain = @tagName(settings.terrain),
        .scenario = @tagName(scenario_kind),
        .players = 0,
        .started_unix_s = std.Io.Clock.now(.real, io).toSeconds(),
        .startup_s = 0,
    };

    if (bot.probe(config.port)) return error.PortInUse;
    const launched = now();
    const server = try Server.start(allocator, io, .{
        .kind = kind,
        .root = root,
        .directory = directory,
        .players = if (counting_cows) 1 else most,
        .cows = if (counting_cows) most else 0,
        .cpus = settings.server_cpus.?,
        .metrics = metrics,
        .terrain = settings.terrain,
    });
    var stopped = false;
    defer if (!stopped) {
        _ = server.stop(10) catch {};
    };
    while (!bot.probe(config.port)) {
        if (server.exited.load(.acquire)) return error.ServerExited;
        if (now() - launched > 300 * std.time.ns_per_s) return error.ServerNeverReady;
        try io.sleep(.fromMilliseconds(100), .awake);
    }
    base.startup_s = seconds(now() - launched);
    try server.configure();

    var dump: ?linux.fd_t = null;
    if (settings.dump_frames) |prefix| {
        const path = try std.fmt.allocPrintSentinel(allocator, "{s}-{s}-{s}-{s}.bin", .{ prefix, @tagName(kind), @tagName(scenario_kind), label }, 0);
        dump = @intCast(linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644));
    }
    defer if (dump) |fd| {
        _ = linux.close(fd);
    };
    const swarm = try bot.Swarm.init(allocator, .{ .port = config.port, .kind = scenario_kind, .join_interval_ns = settings.join_interval_ms * std.time.ns_per_ms, .dump = dump }, if (counting_cows) 1 else most, settings.bot_threads);
    var run: Run = .{ .allocator = allocator, .io = io, .server = server, .swarm = swarm, .started_ns = launched };
    try swarm.start();
    var swarm_stopped = false;
    defer if (!swarm_stopped) swarm.stop();

    var last: Result = base;
    for (steps, 0..) |count, index| {
        const players = if (counting_cows) 1 else count;
        const cows = if (counting_cows) count else 0;
        std.log.info("{s} {s} on {s} terrain with {d} players{s}", .{ @tagName(kind), @tagName(scenario_kind), @tagName(settings.terrain), players, if (cows > 0) try std.fmt.allocPrint(allocator, " among {d} cows", .{cows}) else "" });
        const result = step(allocator, io, settings, &run, kind, scenario_kind, players, cows, launched, metrics, base) catch |err| failed: {
            var broken = base;
            broken.players = players;
            broken.cows = cows;
            broken.limit = if (err == error.ServerExited) "the server exited" else @errorName(err);
            broken.problems = try allocator.dupe([]const u8, &.{broken.limit});
            break :failed broken;
        };
        // Startup is the first step's, the same for every later one.
        if (index == 0) {
            base.first_chunk_s = result.first_chunk_s;
            base.full_view_s = result.full_view_s;
        }
        std.log.info("  {d:.2} cpu ms/tick, {d:.1} tps, {d:.2} mspt, ping p99 {d:.1} ms, {d:.0} MB, {d:.1} KB/s per player, {d} problems{s}{s}", .{
            result.window.cpu_ms_per_tick, result.window.tps,                          result.window.mspt.mean_ms, result.window.ping_p99_ms,
            result.window.rss_mb_max,      result.window.received_kb_per_s_per_player, result.problems.len,        if (result.limit.len != 0) ", stopping: " else "",
            result.limit,
        });
        if (result.limit.len != 0 or index == steps.len - 1) {
            last = result;
            break;
        }
        try append(allocator, io, results_path, result);
    }

    // What only the end of the run tells, which goes with its last step.
    run.phase = "stop";
    swarm.stop();
    swarm_stopped = true;
    last.traffic = try traffic(allocator, swarm);
    var problems: std.ArrayList([]const u8) = .fromOwnedSlice(@constCast(last.problems));
    if (!server.exited.load(.acquire)) {
        const before_stop = try process.sample(server.pid);
        last.peak_rss_mb = megabytes(before_stop.peak_rss_bytes);
        last.total_disk_write_mb = megabytes(before_stop.disk_write_bytes);
    }
    const ending = try server.stop(180);
    stopped = true;
    last.stop_s = ending.seconds;
    last.clean_stop = ending.clean;
    if (!ending.clean) try problems.append(allocator, "the server did not stop in time and was killed");
    for (kind.worldPaths()) |name| {
        const world = try std.fs.path.join(allocator, &.{ directory, name });
        last.world_mb += megabytes(diskUsage(allocator, io, world) catch 0);
        if (!settings.keep_worlds) std.Io.Dir.cwd().deleteTree(io, world) catch {};
    }
    if (last.world_mb == 0) try problems.append(allocator, "the server saved no world");
    last.problems = problems.items;
    try append(allocator, io, results_path, last);
    try writeJson(allocator, io, try std.fs.path.join(allocator, &.{ directory, "result.json" }), last);
    if (last.problems.len != 0) std.log.warn("the run had problems, see {s}", .{results_path});
}

/// One step of a run: the players up to `players` join, settle and are measured, and the step
/// is checked against the limits.
fn step(allocator: std.mem.Allocator, io: std.Io, settings: Settings, run: *Run, kind: server_module.Kind, scenario_kind: scenario.Kind, players: usize, cows: usize, launched: u64, metrics: []const u8, base: Result) !Result {
    const swarm = run.swarm;
    const server = run.server;
    var result = base;
    result.players = players;
    result.cows = cows;
    var problems: std.ArrayList([]const u8) = .empty;
    const newcomers = players - swarm.admitted;
    const admitted_at = now();
    swarm.admit(players);

    run.phase = "join";
    if (!try run.wait(newcomers * settings.join_interval_ms / 1000 + 120, Run.joined)) try problems.append(allocator, "not every bot joined in time");
    result.join_s = seconds(latest(swarm, .spawned_ns) -| admitted_at);
    var cows_missing: u64 = 0;
    if (cows > run.cows) {
        // The step's new cows around the player, before warming up, and every cow sent to it.
        run.phase = "cows";
        // Servers load the field around the player while it joins, and refuse a cow in a chunk
        // not yet loaded, so the first cows come once the player holds a full view.
        if (run.cows == 0 and !try run.wait(120, Run.viewed)) try problems.append(allocator, "the player had no full view to summon cows in");
        try server.summonCows(allocator, run.cows, cows, swarm.bots[0].origin);
        run.cows = cows;
        if (!try run.wait(120, Run.sawCows)) {
            cows_missing = cows -| swarm.total(.cows_seen);
            try problems.append(allocator, try std.fmt.allocPrint(allocator, "the player saw {d} of {d} cows", .{ swarm.total(.cows_seen), cows }));
        }
    }
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
    const first_bots = try process.sample(linux.getpid());
    const first_threads = try threadTimes(allocator, io, server.pid);
    const first_time, const first_time_ns = swarm.gameTime();
    const first_received = swarm.total(.bytes_in);
    const first_sent = swarm.total(.bytes_out);
    const first_chunks = swarm.total(.chunks);
    const first_corrections = swarm.total(.corrections);
    const first_latency = swarm.latency();
    run.last_query_ns = now();
    _ = try run.wait(settings.measure_s, null);
    try server.queryTicks();
    try run.sample();
    const window_end = now();
    const last_usage = try process.sample(server.pid);
    const last_bots = try process.sample(linux.getpid());
    const last_threads = try threadTimes(allocator, io, server.pid);
    const last_time, const last_time_ns = swarm.gameTime();
    const last_latency = swarm.latency();
    // Give the last tick report a moment to arrive.
    try io.sleep(.fromMilliseconds(500), .awake);

    const window = &result.window;
    window.seconds = seconds(window_end - window_start);
    window.tps = if (last_time_ns > first_time_ns and last_time > first_time) @as(f64, @floatFromInt(last_time - first_time)) / seconds(last_time_ns - first_time_ns) else 0;
    const ticks = if (window.tps > 0) window.tps * window.seconds else 20 * window.seconds;
    window.cpu_ms_per_tick = @as(f64, @floatFromInt(last_usage.cpu_ns - first_usage.cpu_ns)) / std.time.ns_per_ms / ticks;
    window.cpu_cores = seconds(last_usage.cpu_ns - first_usage.cpu_ns) / window.seconds;
    window.bot_cpu = seconds(last_bots.cpu_ns - first_bots.cpu_ns) / window.seconds / @as(f64, @floatFromInt(cpuCount(settings.bot_cpus.?)));
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
    var pings: [bot.Latency.buckets]u64 = undefined;
    for (&pings, first_latency, last_latency) |*count, before, after| count.* = after - before;
    window.pings = 0;
    for (pings) |count| window.pings += count;
    window.ping_p50_ms = percentile(&pings, window.pings, 0.50);
    window.ping_p99_ms = percentile(&pings, window.pings, 0.99);
    if (window.tps == 0) try problems.append(allocator, "no world time reached the bots, so ticks per second is unknown");

    result.view_s = try medianGap(allocator, swarm, .spawned_ns, .viewed_ns);
    result.first_chunk_s = seconds(earliest(swarm, .first_chunk_ns) -| launched);
    result.full_view_s = seconds(earliest(swarm, .viewed_ns) -| launched);
    result.bots = summarize(swarm);
    result.total_received_mb = megabytes(swarm.total(.bytes_in));
    result.peak_rss_mb = window.rss_mb_max;
    try check(allocator, swarm, scenario_kind, &problems);
    result.problems = problems.items;

    // The first limit the step broke, in order of how plainly it is the server's.
    const failed = swarm.count(.failed);
    var viewless: usize = 0;
    for (swarm.joining()) |*each| viewless += @intFromBool(each.phase.load(.acquire) != .failed and each.counters.get(.viewed_ns) == 0);
    const corrections = swarm.total(.corrections) - first_corrections;
    result.limit = if (failed != 0)
        try std.fmt.allocPrint(allocator, "{d} {s} disconnected", .{ failed, if (failed == 1) "player was" else "players were" })
    else if (window.bot_cpu >= limits.bot_cpu)
        "the bots ran out of CPU"
    else if (window.tps < limits.tps)
        try std.fmt.allocPrint(allocator, "{d:.1} TPS", .{window.tps})
    else if (window.pings != 0 and window.ping_p99_ms > limits.ping_p99_ms)
        try std.fmt.allocPrint(allocator, "ping p99 {d:.0} ms", .{window.ping_p99_ms})
    else if (cows_missing != 0)
        try std.fmt.allocPrint(allocator, "the player never got {d} cows", .{cows_missing})
    else if (viewless != 0)
        try std.fmt.allocPrint(allocator, "{d} {s} no full view", .{ viewless, if (viewless == 1) "player had" else "players had" })
    else if (corrections != 0)
        try std.fmt.allocPrint(allocator, "players moved back {d} times", .{corrections})
    else
        "";
    result.samples = run.samples.items[first..];
    return result;
}

/// The round trip a share of pings came back within, in milliseconds, from the middle of its
/// bucket.
fn percentile(counts: []const u64, total: u64, share: f64) f64 {
    if (total == 0) return 0;
    const wanted: u64 = @intFromFloat(@ceil(@as(f64, @floatFromInt(total)) * share));
    var seen: u64 = 0;
    for (counts, 0..) |count, index| {
        seen += count;
        if (seen >= wanted) return bot.Latency.milliseconds(index);
    }
    return bot.Latency.milliseconds(counts.len - 1);
}

/// CPUs in a list like 0-3,8.
fn cpuCount(list: []const u8) usize {
    var count: usize = 0;
    var ranges = std.mem.tokenizeScalar(u8, list, ',');
    while (ranges.next()) |range| {
        const dash = std.mem.indexOfScalar(u8, range, '-') orelse {
            count += 1;
            continue;
        };
        const low = std.fmt.parseInt(usize, range[0..dash], 10) catch continue;
        const high = std.fmt.parseInt(usize, range[dash + 1 ..], 10) catch continue;
        count += high - low + 1;
    }
    return @max(1, count);
}

test "cpu lists count every cpu" {
    try std.testing.expectEqual(@as(usize, 5), cpuCount("0-3,8"));
    try std.testing.expectEqual(@as(usize, 1), cpuCount("2"));
}

/// What the bots must have seen for a run to count: everyone in, a full view each, the server
/// never pulling anyone back, and whatever the scenario asks for.
fn check(allocator: std.mem.Allocator, swarm: *bot.Swarm, kind: scenario.Kind, problems: *std.ArrayList([]const u8)) !void {
    const players = swarm.joining().len;
    for (swarm.joining()) |*each| {
        const counters = &each.counters;
        if (each.phase.load(.acquire) == .failed) {
            try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} failed: {s} {s}", .{ each.label(), @errorName(each.failure.?), each.reasonText() }));
            continue;
        }
        if (counters.get(.viewed_ns) == 0) try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} got {d} chunks, short of a full view", .{ each.label(), counters.get(.chunks) }));
        if (counters.get(.corrections) != 0) try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} was moved back {d} times", .{ each.label(), counters.get(.corrections) }));
        if (counters.get(.keepalives) == 0) try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} got no keep alive", .{each.label()}));
        switch (kind) {
            .idle, .wander => if (counters.get(.players_seen) + 1 < players)
                try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} saw {d} of {d} other players", .{ each.label(), counters.get(.players_seen), players - 1 })),
            .spread, .build => if (counters.get(.arrived_ns) == 0) try problems.append(allocator, try std.fmt.allocPrint(allocator, "{s} never reached its spot", .{each.label()})),
            // Measured when the cows were summoned, before warming up.
            .explore, .cows => {},
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
        .chunk_bytes = swarm.total(.chunk_bytes),
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

/// The first time any bot reached a mark, or zero when none did.
fn earliest(swarm: *bot.Swarm, counter: bot.Counter) u64 {
    var value: u64 = std.math.maxInt(u64);
    for (swarm.bots) |*each| {
        const at = each.counters.get(counter);
        if (at != 0) value = @min(value, at);
    }
    return if (value == std.math.maxInt(u64)) 0 else value;
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
    const players: f64 = @floatFromInt(swarm.joining().len);
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

/// Generates a world runs start from with the server given, and reports its size.
fn pregen(allocator: std.mem.Allocator, io: std.Io, root: []const u8, settings: Settings) !void {
    const kind = settings.server orelse .vanilla;
    const directory = try pregen_module.generate(allocator, io, root, .{
        .kind = kind,
        .terrain = settings.terrain,
        .radius = settings.radius,
        .dimension = settings.dimension,
        .cpus = settings.server_cpus.?,
    });
    const world = try std.fs.path.join(allocator, &.{ directory, kind.worldPaths()[0] });
    std.log.info("world of {d:.0} MB in {s}", .{ megabytes(try diskUsage(allocator, io, world)), world });
}
