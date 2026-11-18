//! Starting, driving and stopping each server the same way: a fresh directory, the same world
//! and settings, pinned to the same CPUs, with its output kept and its tick reports read.

const std = @import("std");
const linux = std.os.linux;
const scenario = @import("scenario.zig");
const config = @import("config.zig");
const process = @import("process.zig");
const farm = @import("farm.zig");
const session = @import("session_server.zig");

pub const Kind = enum {
    vanilla,
    @"lightning-rod",
    pumpkin,
    steel,
    /// Paper as shipped.
    paper,
    /// Paper with FPAntiFreecam, which sends each player only the blocks and entities it can see.
    @"paper-antifreecam",
    /// Folia, Paper's fork that ticks regions of the world apart on threads of their own.
    folia,
    /// Fabric with the mods servers commonly run for performance: FerriteCore for memory, Lithium
    /// for game logic, ScalableLux for light and Krypton for networking.
    @"fabric-optimized",

    pub fn isPaper(kind: Kind) bool {
        return kind == .paper or kind == .@"paper-antifreecam" or kind == .folia;
    }

    pub fn stopsFromConsole(kind: Kind) bool {
        return kind != .@"lightning-rod";
    }

    /// Whether the server answers vanilla's `tick query` on its console. SteelMC does with the
    /// patch setup.sh applies, which lets it read commands from a pipe.
    pub fn queriesTicks(kind: Kind) bool {
        return kind != .@"lightning-rod";
    }

    /// Whether the server can run ticks back to back, as vanilla's `tick sprint` does. Folia,
    /// which ticks each region on its own, has no tick command.
    pub fn warps(kind: Kind) bool {
        return kind != .folia;
    }

    /// Everything a server stores for its worlds, relative to the server's directory.
    pub fn worldPaths(kind: Kind) []const []const u8 {
        return switch (kind) {
            .vanilla, .pumpkin, .paper, .@"paper-antifreecam", .folia, .@"fabric-optimized" => &.{"world"},
            // Lightning Rod keeps its chunk cache and write ahead log beside the world.
            .@"lightning-rod" => &.{ "world", "world.cache", "world.wal" },
            .steel => &.{"saves"},
        };
    }
};

/// The release or commit of a server, so a report names what it compared. Releases are the ones
/// setup.sh pins, and servers built from source report the commit setup.sh built, which it
/// records beside the build, as CI runs them where the source is not checked out.
pub fn version(kind: Kind, allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    switch (kind) {
        .vanilla => return "26.2",
        .paper => return "26.2 build 135",
        .@"paper-antifreecam" => return "26.2 build 135, FPAntiFreecam 1.5.3.1, PacketEvents 2.14.0",
        .folia => return "26.2 build 7",
        .@"fabric-optimized" => return "26.2, Fabric Loader 0.20.1, FerriteCore 9.0.0, Lithium 0.25.3, ScalableLux 0.3.0-alpha.0.3, Krypton 0.3.1",
        .@"lightning-rod", .pumpkin, .steel => {},
    }
    const path = try std.fmt.allocPrint(allocator, "{s}/servers/build/versions/{s}", .{ root, @tagName(kind) });
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256)) catch return "not recorded";
    return std.mem.trim(u8, text, " \n");
}

/// Flat layers every server builds its world from: stone up to y 63 and grass on top, the world
/// Lightning Rod generates.
const flat_layers_json =
    \\{"layers":[{"block":"minecraft:stone","height":128},{"block":"minecraft:grass_block","height":1}],"biome":"minecraft:plains","structure_overrides":[]}
;

/// The worlds runs start from, every one pregenerated once in a square around the origin, so no
/// run generates terrain: vanilla generates each for every server that reads vanilla worlds,
/// Lightning Rod imports it, and SteelMC, which reads none, generates the same chunks itself.
pub const Terrain = enum {
    /// Stone and grass.
    flat,
    /// Vanilla's terrain from the bench's seed.
    real,
    /// Stone and grass far enough out for the views of 256 players spread apart, which reach about
    /// 2750 blocks out.
    wide,
    /// Vanilla's terrain from the bench's seed, structures and all, a tile a view across copied
    /// into a grid of 23 by 23 copies, so 512 players spread apart each stream real terrain of
    /// their own without generating a world that large.
    tiled,

    /// Chunks out from the origin that pregenerating covers. A tiled world is generated around the
    /// origin, a forceload tile either way, and its tile copied out from there.
    pub fn radius(terrain: Terrain) i32 {
        return switch (terrain) {
            .flat, .real => 64,
            .wide => 176,
            .tiled => 16,
        };
    }

    /// Whether the terrain is stone and grass rather than vanilla's.
    pub fn isFlat(terrain: Terrain) bool {
        return terrain == .flat or terrain == .wide;
    }

    /// Where a server's copy of the world is kept, under the bench repository.
    pub fn directory(terrain: Terrain, allocator: std.mem.Allocator, server: []const u8) ![]const u8 {
        return std.fmt.allocPrint(allocator, "servers/build/worlds/{s}/{s}", .{ @tagName(terrain), server });
    }
};

/// A number, since servers hash text seeds differently.
pub const terrain_seed = "8675309";

/// The settings that decide what a server generates on a terrain, which it is given both while
/// generating the world and while running on it: vanilla's world properties, which Paper and Fabric
/// read alike, or SteelMC's worlds file. `bench recipe` prints them, and CI keys each cached world
/// on them, so a world is generated again only when they change.
pub fn worldSettings(allocator: std.mem.Allocator, kind: Kind, terrain: Terrain) ![]const u8 {
    const flat = terrain.isFlat();
    switch (kind) {
        .vanilla, .paper, .@"paper-antifreecam", .folia, .@"fabric-optimized" => {
            if (!flat) return std.fmt.allocPrint(allocator, "level-seed={s}\n", .{terrain_seed});
            var escaped: std.ArrayList(u8) = .empty;
            for (flat_layers_json) |byte| {
                if (byte == ':') try escaped.append(allocator, '\\');
                try escaped.append(allocator, byte);
            }
            return std.fmt.allocPrint(allocator, "level-type=minecraft\\:flat\ngenerator-settings={s}\ngenerate-structures=false\n", .{escaped.items});
        },
        .steel => {
            const world = if (flat)
                \\generator = "minecraft:flat"
                \\default = true
                \\
                \\[domains.minecraft.worlds.config]
                \\layers = [{ block = "minecraft:stone", height = 128 }, { block = "minecraft:grass_block", height = 1 }]
                \\structure_overrides = []
                \\
            else
                \\generator = "minecraft:overworld"
                \\default = true
                \\
            ;
            return std.fmt.allocPrint(allocator,
                \\save_path = "saves"
                \\seed = "{s}"
                \\default_gamemode = "creative"
                \\difficulty = "normal"
                \\
                \\[storage]
                \\type = "steel:disk"
                \\
                \\[player_storage]
                \\type = "steel:disk"
                \\
                \\[domains.minecraft]
                \\default = true
                \\
                \\[[domains.minecraft.worlds]]
                \\name = "overworld"
                \\{s}
            , .{ terrain_seed, world });
        },
        .@"lightning-rod", .pumpkin => return error.GeneratesNoWorld,
    }
}

pub const Options = struct {
    kind: Kind,
    /// The bench repository, where servers were built.
    root: []const u8,
    /// A fresh directory the server runs in.
    directory: []const u8,
    players: usize,
    /// Cows the scenario summons, which Lightning Rod spawns itself.
    cows: usize = 0,
    cpus: []const u8,
    /// Where Lightning Rod writes its tick samples, off the disk being measured.
    metrics: []const u8,
    terrain: Terrain = .flat,
    /// Generating the world to pregenerate it, rather than starting from it.
    generating: bool = false,
    /// Whether sessions are encrypted.
    encryption: bool = true,
};

/// A tick report, as vanilla's `tick query` prints it.
pub const TickReport = struct {
    at_ns: u64,
    mean_ms: f64,
    p50_ms: f64,
    p95_ms: f64,
    p99_ms: f64,
};

pub const Server = struct {
    io: std.Io,
    options: Options,
    child: std.process.Child,
    pid: linux.pid_t,
    log: std.Io.File,
    reader: ?std.Thread = null,
    mutex: std.atomic.Mutex = .unlocked,
    reports: [4096]TickReport = undefined,
    report_count: usize = 0,
    /// The mean of a report seen before its percentiles came.
    pending_mean: ?f64 = null,
    exited: std.atomic.Value(bool) = .init(false),
    /// What Lightning Rod's teleports file holds, one line a request.
    teleports: std.ArrayList(u8) = .empty,
    /// Fills and summons the console confirmed, and the game time it last reported and how many
    /// times it did, for the warp scenario.
    fills: std.atomic.Value(u32) = .init(0),
    summons: std.atomic.Value(u32) = .init(0),
    game_time: std.atomic.Value(u64) = .init(0),
    game_times: std.atomic.Value(u32) = .init(0),

    pub fn start(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Server {
        try prepare(allocator, io, options);
        const argv = try command(allocator, options);
        const log = try std.Io.Dir.cwd().createFile(io, try std.fs.path.join(allocator, &.{ options.directory, "server.log" }), .{});
        // A shell joins stderr to stdout, then execs, so the process measured is the server itself.
        // The server dies with the bench, even one that crashed, so none outlives it holding the
        // port the next run needs.
        var full: std.ArrayList([]const u8) = .empty;
        try full.appendSlice(allocator, &.{ "sh", "-c", "exec setpriv --pdeathsig KILL taskset -c \"$0\" \"$@\" 2>&1", options.cpus });
        try full.appendSlice(allocator, argv);
        const child = try std.process.spawn(io, .{
            .argv = full.items,
            .cwd = .{ .path = options.directory },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .inherit,
        });
        const self = try allocator.create(Server);
        self.* = .{ .io = io, .options = options, .child = child, .pid = child.id orelse return error.ProcessIdUnavailable, .log = log };
        self.reader = try std.Thread.spawn(.{}, readOutput, .{self});
        return self;
    }

    pub fn console(self: *Server, line: []const u8) !void {
        const stdin = self.child.stdin orelse return error.NoConsole;
        try stdin.writeStreamingAll(self.io, line);
        try stdin.writeStreamingAll(self.io, "\n");
    }

    /// Settings only a console sets, sent once the server is ready and before anyone joins.
    pub fn configure(self: *Server) !void {
        switch (self.options.kind) {
            .vanilla, .pumpkin, .paper, .@"paper-antifreecam", .folia, .@"fabric-optimized" => {
                // No natural spawning on any server, so mobs come only from scenarios.
                try self.console("gamerule spawn_mobs false");
                // Everyone spawns on the same block, as on the servers without a spawn radius.
                try self.console("gamerule respawn_radius 0");
            },
            .@"lightning-rod", .steel => {},
        }
    }

    /// Summons the cows from `from` up to `to` around a player, through the console as an operator
    /// would. Lightning Rod has no console: it reads the count from the cows file in its directory,
    /// as config.cows_file describes, and spawns the same cows itself.
    /// Moves a player to a spot, as /tp does, which every server carries out once the player is in
    /// its world.
    pub fn teleport(self: *Server, allocator: std.mem.Allocator, name: []const u8, at: [3]f64) !void {
        var buffer: [128]u8 = undefined;
        if (self.options.kind == .@"lightning-rod") {
            try self.teleports.print(allocator, "{s} {d:.2} {d:.2} {d:.2}\n", .{ name, at[0], at[1], at[2] });
            const path = try std.fs.path.join(allocator, &.{ self.options.directory, config.teleports_file });
            const pending = try std.fmt.allocPrint(allocator, "{s}.new", .{path});
            // Written whole and renamed, so the server never reads half a line.
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = pending, .data = self.teleports.items });
            try std.Io.Dir.rename(std.Io.Dir.cwd(), pending, std.Io.Dir.cwd(), path, self.io);
            return;
        }
        try self.console(try std.fmt.bufPrint(&buffer, "tp {s} {d:.2} {d:.2} {d:.2}", .{ name, at[0], at[1], at[2] }));
    }

    /// Builds the warp scenario's farm and summons its cows, force loading its chunks first, and
    /// returns once the server confirmed every block and cow. Lightning Rod's plugin builds the
    /// same farm from the request file.
    pub fn buildFarm(self: *Server, allocator: std.mem.Allocator) !void {
        if (self.options.kind == .@"lightning-rod") {
            try self.request(allocator, config.farm_file, "build\n");
            try self.awaitFile(allocator, config.farm_built_file, 300);
            return;
        }
        var buffer: [128]u8 = undefined;
        try self.console(try std.fmt.bufPrint(&buffer, "forceload add {d} {d} {d} {d}", .{ farm.block_min[0], farm.block_min[1], farm.block_max[0], farm.block_max[1] }));
        const commands = try farm.commands(allocator);
        // The first fill fails until the chunks load, so it repeats until one is confirmed.
        const started = now();
        while (self.fills.load(.acquire) == 0) {
            if (now() - started > 300 * std.time.ns_per_s) return error.FarmNeverLoaded;
            try self.console(commands[0]);
            _ = try self.waitUntil(&self.fills, 1, 2);
        }
        const before = self.fills.load(.acquire);
        for (commands[1..]) |line| try self.console(line);
        if (!try self.waitUntil(&self.fills, before + @as(u32, @intCast(commands.len - 1)), 300)) return error.FarmNotBuilt;
        for (0..farm.cows) |index| {
            const at = farm.cowPosition(index);
            try self.console(try std.fmt.bufPrint(&buffer, "summon minecraft:cow {d:.1} {d:.1} {d:.1}", .{ at[0], at[1], at[2] }));
        }
        if (!try self.waitUntil(&self.summons, farm.cows, 300)) return error.CowsNotSummoned;
    }

    /// Asks the server to run `ticks` back to back, as /tick sprint does, returning the game time
    /// it starts from, which `warped` counts from.
    pub fn startWarp(self: *Server, allocator: std.mem.Allocator, ticks: u64) !u64 {
        if (self.options.kind == .@"lightning-rod") {
            try self.request(allocator, config.warp_file, try std.fmt.allocPrint(allocator, "{d}\n", .{ticks}));
            return 0;
        }
        const from = try self.gameTime(30);
        var buffer: [64]u8 = undefined;
        try self.console(try std.fmt.bufPrint(&buffer, "tick sprint {d}", .{ticks}));
        return from;
    }

    /// Whether the game time reached `ticks` past `from`, asking for it on the console and waiting
    /// at most a moment for the answer, or for Lightning Rod whether its plugin said so.
    pub fn warped(self: *Server, allocator: std.mem.Allocator, from: u64, ticks: u64) !bool {
        if (self.options.kind == .@"lightning-rod") {
            const path = try std.fs.path.join(allocator, &.{ self.options.directory, config.warped_file });
            std.Io.Dir.cwd().access(self.io, path, .{}) catch return false;
            return true;
        }
        return try self.gameTime(5) >= from + ticks;
    }

    /// The ticks the warp ran: the game time past `from`, or what Lightning Rod's plugin wrote.
    pub fn warpTime(self: *Server, allocator: std.mem.Allocator, from: u64) !u64 {
        if (self.options.kind == .@"lightning-rod") {
            var buffer: [32]u8 = undefined;
            const text = try std.Io.Dir.cwd().readFile(self.io, try std.fs.path.join(allocator, &.{ self.options.directory, config.warped_file }), &buffer);
            return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10);
        }
        return try self.gameTime(30) - from;
    }

    /// The game time, as `time query gametime` answers.
    fn gameTime(self: *Server, limit_s: u64) !u64 {
        const seen = self.game_times.load(.acquire);
        try self.console("time query gametime");
        if (!try self.waitUntil(&self.game_times, seen + 1, limit_s)) return error.NoGameTime;
        return self.game_time.load(.acquire);
    }

    /// Waits for a count to reach `target`, polling briefly, reporting whether it did in time.
    fn waitUntil(self: *Server, counter: *std.atomic.Value(u32), target: u32, limit_s: u64) !bool {
        const started = now();
        while (counter.load(.acquire) < target) {
            if (self.exited.load(.acquire)) return error.ServerExited;
            if (now() - started > limit_s * std.time.ns_per_s) return false;
            try self.io.sleep(.fromMilliseconds(5), .awake);
        }
        return true;
    }

    /// Writes a request file for Lightning Rod's plugins, whole and renamed, so it never reads
    /// half of one.
    fn request(self: *Server, allocator: std.mem.Allocator, name: []const u8, data: []const u8) !void {
        const path = try std.fs.path.join(allocator, &.{ self.options.directory, name });
        const pending = try std.fmt.allocPrint(allocator, "{s}.new", .{path});
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = pending, .data = data });
        try std.Io.Dir.rename(std.Io.Dir.cwd(), pending, std.Io.Dir.cwd(), path, self.io);
    }

    /// Waits for a file Lightning Rod's plugin writes when it is done.
    fn awaitFile(self: *Server, allocator: std.mem.Allocator, name: []const u8, limit_s: u64) !void {
        const path = try std.fs.path.join(allocator, &.{ self.options.directory, name });
        const started = now();
        while (true) {
            if (std.Io.Dir.cwd().access(self.io, path, .{})) |_| return else |_| {}
            if (self.exited.load(.acquire)) return error.ServerExited;
            if (now() - started > limit_s * std.time.ns_per_s) return error.PluginNeverAnswered;
            try self.io.sleep(.fromMilliseconds(50), .awake);
        }
    }

    pub fn summonCows(self: *Server, allocator: std.mem.Allocator, from: usize, to: usize, centre: [3]f64) !void {
        if (self.options.kind == .@"lightning-rod") {
            const path = try std.fs.path.join(allocator, &.{ self.options.directory, config.cows_file });
            const pending = try std.fmt.allocPrint(allocator, "{s}.new", .{path});
            // Written whole and renamed, so the server never reads half a count.
            try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = pending, .data = try std.fmt.allocPrint(allocator, "{d}\n", .{to}) });
            try std.Io.Dir.rename(std.Io.Dir.cwd(), pending, std.Io.Dir.cwd(), path, self.io);
            return;
        }
        var buffer: [128]u8 = undefined;
        for (from..to) |index| {
            const at = config.cowPosition(index, centre);
            try self.console(try std.fmt.bufPrint(&buffer, "summon minecraft:cow {d:.1} {d:.1} {d:.1}", .{ at[0], at[1], at[2] }));
        }
    }

    /// Asks for a tick report, which arrives in the log a moment later.
    pub fn queryTicks(self: *Server) !void {
        if (self.options.kind.queriesTicks()) try self.console("tick query");
    }

    pub fn tickReports(self: *Server, from_ns: u64, to_ns: u64, into: []TickReport) usize {
        lock(&self.mutex);
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.reports[0..self.report_count]) |report| {
            if (report.at_ns < from_ns or report.at_ns > to_ns or count == into.len) continue;
            into[count] = report;
            count += 1;
        }
        return count;
    }

    pub const Ending = struct { clean: bool, seconds: f64 };

    /// Stops the server the way an operator would and waits for it to save, killing it if it
    /// does not exit within a limit.
    pub fn stop(self: *Server, limit_s: u64) !Ending {
        const started = now();
        if (self.options.kind.stopsFromConsole()) {
            self.console("stop") catch {};
        } else {
            _ = linux.kill(self.pid, .INT);
        }
        var clean = true;
        while (!self.exited.load(.acquire)) {
            if (now() - started > limit_s * std.time.ns_per_s) {
                _ = linux.kill(self.pid, .KILL);
                clean = false;
                break;
            }
            try self.io.sleep(.fromMilliseconds(100), .awake);
        }
        _ = self.child.wait(self.io) catch {};
        if (self.reader) |thread| thread.join();
        self.log.close(self.io);
        return .{ .clean = clean, .seconds = @as(f64, @floatFromInt(now() - started)) / std.time.ns_per_s };
    }

    fn readOutput(self: *Server) void {
        const stdout = self.child.stdout orelse return;
        var buffer: [16384]u8 = undefined;
        var line: [4096]u8 = undefined;
        var line_len: usize = 0;
        while (true) {
            const count = stdout.readStreaming(self.io, &.{&buffer}) catch break;
            if (count == 0) break;
            self.log.writeStreamingAll(self.io, buffer[0..count]) catch {};
            for (buffer[0..count]) |byte| {
                if (byte == '\n') {
                    self.parse(line[0..line_len]);
                    line_len = 0;
                } else if (line_len < line.len) {
                    line[line_len] = byte;
                    line_len += 1;
                }
            }
        }
        self.exited.store(true, .release);
    }

    /// Reads vanilla's tick query lines: "Average time per tick: 0.2ms" and then
    /// "Percentiles: P50: 0.2ms P95: 0.2ms P99: 2.1ms".
    fn parse(self: *Server, line: []const u8) void {
        if (std.mem.indexOf(u8, line, "Successfully filled") != null) _ = self.fills.fetchAdd(1, .release);
        if (std.mem.indexOf(u8, line, "Summoned new") != null) _ = self.summons.fetchAdd(1, .release);
        // 26.2 answers "The game time is 1185 tick(s)", older releases "The time is 1185".
        if (number(line, "The game time is ") orelse number(line, "The time is ")) |time| {
            self.game_time.store(@intFromFloat(time), .release);
            _ = self.game_times.fetchAdd(1, .release);
            return;
        }
        if (number(line, "Average time per tick: ")) |mean| {
            self.pending_mean = mean;
            return;
        }
        const p50 = number(line, "P50: ") orelse return;
        const p95 = number(line, "P95: ") orelse return;
        const p99 = number(line, "P99: ") orelse return;
        const mean = self.pending_mean orelse return;
        self.pending_mean = null;
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (self.report_count == self.reports.len) return;
        self.reports[self.report_count] = .{ .at_ns = now(), .mean_ms = mean, .p50_ms = p50, .p95_ms = p95, .p99_ms = p99 };
        self.report_count += 1;
    }
};

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

/// The number after a label in a line, skipping color codes servers put in their logs.
fn number(line: []const u8, label: []const u8) ?f64 {
    const at = std.mem.indexOf(u8, line, label) orelse return null;
    var start = at + label.len;
    while (start < line.len and line[start] == 0x1b) {
        start = (std.mem.indexOfScalarPos(u8, line, start, 'm') orelse return null) + 1;
    }
    var end = start;
    while (end < line.len and (std.ascii.isDigit(line[end]) or line[end] == '.')) end += 1;
    return std.fmt.parseFloat(f64, line[start..end]) catch null;
}

/// The heap a Java server may grow to: three quarters of the machine's memory, the rest left to
/// the JVM's own memory, the system and the bots, as a machine given to one server would run it.
/// The native servers have no such limit and may use all of it, so a smaller heap would end the
/// Java servers' ramps where the bench set it rather than where they give out. It starts small and
/// grows, so their memory measures what they use.
fn javaHeap(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "-Xmx{d}m", .{try process.memoryMb() * 3 / 4});
}

/// Room Folia gets beyond the players of a run. Folia counts players still logging in as on the
/// server, and bots join a fifth of a second apart and take about a second to, so with room for
/// exactly the run's players it turns the last of each step away as full. A Java server sets
/// nothing aside for room it does not use, so the room costs it nothing.
const folia_headroom = 8;

fn command(allocator: std.mem.Allocator, options: Options) ![]const []const u8 {
    const root = options.root;
    const heap = try javaHeap(allocator);
    return switch (options.kind) {
        .vanilla => try allocator.dupe([]const u8, &.{
            "java", heap, session.java_properties[0], session.java_properties[1], session.java_properties[2], try std.fmt.allocPrint(allocator, "-DbundlerRepoDir={s}/servers/vanilla/bundle", .{root}), "-jar", try std.fs.path.join(allocator, &.{ root, "servers/vanilla/server.jar" }), "--nogui",
        }),
        // Configured in code with the bench's settings, and takes the room for players and the cows
        // to spawn.
        .@"lightning-rod" => try allocator.dupe([]const u8, &.{ try std.fs.path.join(allocator, &.{ root, "servers/build/lightning-rod/bin/lightning_rod" }), try std.fmt.allocPrint(allocator, "{d}", .{config.maxPlayers(options.players)}), try std.fmt.allocPrint(allocator, "{d}", .{options.cows}), if (options.encryption) "encrypted" else "plain" }),
        // Vanilla's jar unpacks where the vanilla runs unpack it, and the launcher finds its
        // libraries beside itself.
        .@"fabric-optimized" => try allocator.dupe([]const u8, &.{
            "java", heap, session.java_properties[0], session.java_properties[1], session.java_properties[2], try std.fmt.allocPrint(allocator, "-DbundlerRepoDir={s}/servers/vanilla/bundle", .{root}), "-jar", try std.fs.path.join(allocator, &.{ root, "servers/fabric/fabric-server-launch.jar" }), "--nogui",
        }),
        // Paper converts the vanilla world it is given at every start, quickly, but first waits 30
        // seconds for its owner to stop it and make a backup, which a measured startup would count.
        .paper, .@"paper-antifreecam" => try allocator.dupe([]const u8, &.{
            "java", heap, session.java_properties[0], session.java_properties[1], session.java_properties[2], "-Dpaper.disableMigrationDelay=true", "-jar", try std.fs.path.join(allocator, &.{ root, "servers/paper/paper.jar" }), "--nogui",
        }),
        .folia => try allocator.dupe([]const u8, &.{
            "java", heap, session.java_properties[0], session.java_properties[1], session.java_properties[2], "-Dpaper.disableMigrationDelay=true", "-jar", try std.fs.path.join(allocator, &.{ root, "servers/folia/folia.jar" }), "--nogui",
        }),
        .pumpkin => try allocator.dupe([]const u8, &.{try std.fs.path.join(allocator, &.{ root, "servers/pumpkin/target/release/pumpkin" })}),
        .steel => try allocator.dupe([]const u8, &.{try std.fs.path.join(allocator, &.{ root, "servers/steel/target/release/steel" })}),
    };
}

/// Writes each server's settings: encrypted sessions without asking Mojang who players are,
/// creative, the same view and simulation distance, no spawn protection, no pausing when empty and
/// room for every bot. The world is a copy of the
/// server's pregenerated one, unless it is generating it.
fn prepare(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, options.directory);
    const path = struct {
        fn join(a: std.mem.Allocator, directory: []const u8, name: []const u8) ![]const u8 {
            return std.fs.path.join(a, &.{ directory, name });
        }
    }.join;
    // Where vanilla's pregenerated world is, which every server reading vanilla worlds copies.
    const vanilla_world = try path(allocator, options.root, try path(allocator, try options.terrain.directory(allocator, "vanilla"), "world"));
    switch (options.kind) {
        .vanilla, .paper, .@"paper-antifreecam", .folia, .@"fabric-optimized" => {
            if (options.kind.isPaper()) try preparePaper(allocator, io, options);
            if (options.kind == .@"fabric-optimized") try prepareFabric(allocator, io, options);
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, options.directory, "eula.txt"), .data = "eula=true\n" });
            const world = try worldSettings(allocator, options.kind, options.terrain);
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, options.directory, "server.properties"), .data = try std.fmt.allocPrint(allocator,
                \\online-mode={}
                \\enforce-secure-profile=false
                \\server-port={d}
                \\gamemode=creative
                \\{s}spawn-protection=0
                \\pause-when-empty-seconds=0
                \\view-distance={d}
                \\simulation-distance={d}
                \\max-players={d}
                \\allow-flight=true
                \\{s}
            , .{
                // Vanilla encrypts only in online mode, checking players with the bench's session
                // server. Generating a world needs no players.
                options.encryption and !options.generating,
                config.port, world, scenario.view_distance, config.simulation_distance, config.maxPlayers(options.players) + @as(usize, if (options.kind == .folia) folia_headroom else 0),
                // Pregenerating loads a thousand chunks at once, and a tick waiting on them can pass
                // the minute after which vanilla's watchdog stops the server. It is not measured,
                // so the watchdog is off then.
                if (options.generating) "max-tick-time=-1\n" else "",
            }) });
            if (!options.generating) try copy(allocator, io, vanilla_world, try path(allocator, options.directory, "world"));
        },
        .@"lightning-rod" => {
            try cwd.createDirPath(io, options.metrics);
            // It exports tick samples to a fixed directory, which leads to memory off the disk measured.
            try cwd.symLink(io, options.metrics, try path(allocator, options.directory, config.metrics), .{ .is_directory = true });
            // The import holds the world and the caches it prebuilt, as vanilla's region files
            // hold its light.
            try copy(allocator, io, try path(allocator, options.root, try path(allocator, try options.terrain.directory(allocator, "lightning-rod"), ".")), options.directory);
        },
        .pumpkin => {
            // Pumpkin reads its settings from the directory it runs in and fills in every one left
            // out with its default.
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, options.directory, "pumpkin.toml"), .data = try std.fmt.allocPrint(allocator,
                \\default_gamemode = "Creative"
                \\seed = "{s}"
                \\
                \\[networking.java]
                \\address = "0.0.0.0:{d}"
                \\encryption = {}
                \\online_mode = false
                \\max_players = {d}
                \\view_distance = {d}
                \\simulation_distance = {d}
                \\
                \\[networking.bedrock]
                \\enabled = false
                \\
            , .{ terrain_seed, config.port, options.encryption, config.maxPlayers(options.players), scenario.view_distance, config.simulation_distance }) });
            // Vanilla's world, whose generation settings also give Pumpkin its flat layers.
            try copy(allocator, io, vanilla_world, try path(allocator, options.directory, "world"));
        },
        .steel => {
            const config_directory = try path(allocator, options.directory, "config");
            try cwd.createDirPath(io, config_directory);
            // SteelMC wants every setting, so its own defaults are the base and only ours change.
            var text = try cwd.readFileAlloc(io, try path(allocator, options.root, "servers/steel/package-content/config.toml"), allocator, .limited(1 << 20));
            text = try setting(allocator, text, "server_port", try std.fmt.allocPrint(allocator, "{d}", .{config.port}));
            text = try setting(allocator, text, "max_players", try std.fmt.allocPrint(allocator, "{d}", .{config.maxPlayers(options.players)}));
            text = try setting(allocator, text, "view_distance", try std.fmt.allocPrint(allocator, "{d}", .{scenario.view_distance}));
            text = try setting(allocator, text, "simulation_distance", try std.fmt.allocPrint(allocator, "{d}", .{config.simulation_distance}));
            text = try setting(allocator, text, "online_mode", "false");
            text = try setting(allocator, text, "encryption", if (options.encryption) "true" else "false");
            text = try setting(allocator, text, "allow_flight", "true");
            text = try setting(allocator, text, "use_favicon", "false");
            text = try setting(allocator, text, "threshold", "256");
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, config_directory, "config.toml"), .data = text });
            // SteelMC reads no vanilla worlds, so it starts from the same square of chunks,
            // generated by itself once before any run.
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, config_directory, "worlds.toml"), .data = try worldSettings(allocator, options.kind, options.terrain) });
            if (!options.generating) try copy(allocator, io, try path(allocator, options.root, try path(allocator, try options.terrain.directory(allocator, "steel"), "saves")), try path(allocator, options.directory, "saves"));
        },
    }
}

/// Links what setup.sh made for a Paper server, which it would otherwise rebuild in every fresh
/// directory: the vanilla jar its launcher patched, the libraries it fetched, and for Paper with
/// FPAntiFreecam the plugin. Paper fills in every setting left out.
fn preparePaper(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const cwd = std.Io.Dir.cwd();
    const install = try std.fs.path.join(allocator, &.{ options.root, if (options.kind == .folia) "servers/folia" else "servers/paper" });
    for ([_][]const u8{ "cache", "libraries", "versions" }) |name| {
        const target = try std.fs.path.join(allocator, &.{ install, name });
        cwd.access(io, target, .{}) catch return error.MissingPaperSetup;
        try cwd.symLink(io, target, try std.fs.path.join(allocator, &.{ options.directory, name }), .{ .is_directory = true });
    }
    if (options.kind == .@"paper-antifreecam") {
        const plugins = try std.fs.path.join(allocator, &.{ install, "plugins-antifreecam" });
        cwd.access(io, plugins, .{}) catch return error.MissingPaperSetup;
        // A directory of its own, as plugins write their settings beside themselves.
        const directory = try std.fs.path.join(allocator, &.{ options.directory, "plugins" });
        try cwd.createDirPath(io, directory);
        for ([_][]const u8{ "FPAntiFreeCam-1.5.31.jar", "packetevents-spigot-2.14.0.jar" }) |jar|
            try cwd.symLink(io, try std.fs.path.join(allocator, &.{ plugins, jar }), try std.fs.path.join(allocator, &.{ directory, jar }), .{});
    }
}

/// Links the mods setup.sh fetched and points the launcher at the vanilla jar the vanilla runs
/// use.
fn prepareFabric(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const cwd = std.Io.Dir.cwd();
    const mods = try std.fs.path.join(allocator, &.{ options.root, "servers/fabric/mods" });
    cwd.access(io, mods, .{}) catch return error.MissingFabricSetup;
    try cwd.symLink(io, mods, try std.fs.path.join(allocator, &.{ options.directory, "mods" }), .{ .is_directory = true });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ options.directory, "fabric-server-launcher.properties" }), .data = try std.fmt.allocPrint(allocator, "serverJar={s}/servers/vanilla/server.jar\n", .{options.root}) });
}

/// Copies a directory tree, sharing extents where the filesystem can.
fn copy(allocator: std.mem.Allocator, io: std.Io, from: []const u8, to: []const u8) !void {
    std.Io.Dir.cwd().access(io, from, .{}) catch return error.MissingPregeneratedWorld;
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "cp", "-r", "--reflink=auto", from, to } });
    if (result.term != .exited or result.term.exited != 0) return error.CopyFailed;
}

pub fn now() u64 {
    var time: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &time);
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.nsec));
}

test "tick report lines parse with and without color codes" {
    try std.testing.expectEqual(@as(?f64, 0.2), number("Average time per tick: 0.2ms (Target: 50.0ms)", "Average time per tick: "));
    try std.testing.expectEqual(@as(?f64, 2.1), number("[INFO]: Percentiles: P50: 0.2ms P95: 0.2ms P99: \x1b[32m2.1ms. Sample: 100", "P99: "));
    try std.testing.expectEqual(@as(?f64, null), number("Done (0.497s)!", "P50: "));
}

/// Replaces the value of the first `key = value` line of a TOML text.
fn setting(allocator: std.mem.Allocator, text: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var start: usize = 0;
    while (lines.next()) |line| : (start += line.len + 1) {
        const trimmed = std.mem.trimStart(u8, line, " ");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const rest = std.mem.trimStart(u8, trimmed[key.len..], " ");
        if (rest.len == 0 or rest[0] != '=') continue;
        return std.mem.concat(allocator, u8, &.{ text[0..start], key, " = ", value, text[start + line.len ..] });
    }
    return error.MissingSetting;
}

test "settings replace their own line only" {
    const text = "[server]\nserver_port = 25565\nmax_players = 20\n";
    const changed = try setting(std.testing.allocator, text, "max_players", "64");
    defer std.testing.allocator.free(changed);
    try std.testing.expectEqualStrings("[server]\nserver_port = 25565\nmax_players = 64\n", changed);
}
