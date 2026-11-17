//! Starting, driving and stopping each server the same way: a fresh directory, the same world
//! and settings, pinned to the same CPUs, with its output kept and its tick reports read.

const std = @import("std");
const linux = std.os.linux;
const scenario = @import("scenario.zig");
const config = @import("config.zig");

pub const Kind = enum {
    vanilla,
    @"lightning-rod",
    pumpkin,
    steel,
    /// Paper as shipped, with anti-xray off.
    paper,
    /// Paper with anti-xray replacing ores enclosed by solid blocks with stone.
    @"paper-antixray-1",
    /// Fabric with the mods servers commonly run for performance: FerriteCore for memory, Lithium
    /// for game logic, ScalableLux for light and Krypton for networking.
    fabric,

    pub fn isPaper(kind: Kind) bool {
        return kind == .paper or kind == .@"paper-antixray-1";
    }

    pub fn stopsFromConsole(kind: Kind) bool {
        return kind != .@"lightning-rod";
    }

    /// Whether the server answers vanilla's `tick query` on its console. SteelMC does with the
    /// patch setup.sh applies, which lets it read commands from a pipe.
    pub fn queriesTicks(kind: Kind) bool {
        return kind != .@"lightning-rod";
    }

    /// Everything a server stores for its worlds, relative to the server's directory.
    pub fn worldPaths(kind: Kind) []const []const u8 {
        return switch (kind) {
            .vanilla, .pumpkin, .paper, .@"paper-antixray-1", .fabric => &.{"world"},
            // Lightning Rod keeps its chunk cache and write ahead log beside the world.
            .@"lightning-rod" => &.{ "world", "world.cache", "world.wal" },
            .steel => &.{"saves"},
        };
    }
};

/// The release or commit of a server, so a report names what it compared. Releases are the ones
/// setup.sh pins, and servers built from source report their submodule's commit.
pub fn version(kind: Kind, allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    const directory = switch (kind) {
        .vanilla => return "26.2",
        .paper, .@"paper-antixray-1" => return "26.2 build 135",
        .fabric => return "26.2, Fabric Loader 0.20.1, FerriteCore 9.0.0, Lithium 0.25.3, ScalableLux 0.3.0-alpha.0.3, Krypton 0.3.1",
        .@"lightning-rod" => "servers/lightning-rod",
        .pumpkin => "servers/pumpkin",
        .steel => "servers/steel",
    };
    const result = try std.process.run(allocator, io, .{ .argv = &.{ "git", "-C", try std.fs.path.join(allocator, &.{ root, directory }), "rev-parse", "--short=12", "HEAD" } });
    if (result.term != .exited or result.term.exited != 0) return error.UnknownCommit;
    return std.mem.trim(u8, result.stdout, " \n");
}

/// Flat layers every server builds its world from: stone up to y 63 and grass on top, the world
/// Lightning Rod generates.
const flat_layers_json =
    \\{"layers":[{"block":"minecraft:stone","height":128},{"block":"minecraft:grass_block","height":1}],"biome":"minecraft:plains","structure_overrides":[]}
;

pub const Terrain = enum {
    /// Stone and grass, which every server generates alike.
    flat,
    /// A copy of one pregenerated vanilla world, the same for every server that reads vanilla
    /// worlds.
    real,
    /// Vanilla generating that world from the seed, only for pregeneration.
    generate,
};

/// A number, since servers hash text seeds differently.
pub const terrain_seed = "8675309";

pub const Options = struct {
    kind: Kind,
    /// The bench repository, where servers were built.
    root: []const u8,
    /// A fresh directory the server runs in.
    directory: []const u8,
    players: usize,
    cpus: []const u8,
    /// Where Lightning Rod writes its tick samples, off the disk being measured.
    metrics: []const u8,
    terrain: Terrain = .flat,
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

    pub fn start(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Server {
        try prepare(allocator, io, options);
        const argv = try command(allocator, options);
        const log = try std.Io.Dir.cwd().createFile(io, try std.fs.path.join(allocator, &.{ options.directory, "server.log" }), .{});
        // A shell joins stderr to stdout, then execs, so the process measured is the server itself.
        var full: std.ArrayList([]const u8) = .empty;
        try full.appendSlice(allocator, &.{ "sh", "-c", "exec taskset -c \"$0\" \"$@\" 2>&1", options.cpus });
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
            .vanilla, .pumpkin, .paper, .@"paper-antixray-1", .fabric => {
                // No natural spawning on any server, so mobs come only from scenarios.
                try self.console("gamerule spawn_mobs false");
                // Everyone spawns on the same block, as on the servers without a spawn radius.
                try self.console("gamerule respawn_radius 0");
            },
            .@"lightning-rod", .steel => {},
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

fn command(allocator: std.mem.Allocator, options: Options) ![]const []const u8 {
    const root = options.root;
    return switch (options.kind) {
        .vanilla => try allocator.dupe([]const u8, &.{
            "java", "-Xmx4G", try std.fmt.allocPrint(allocator, "-DbundlerRepoDir={s}/servers/vanilla/bundle", .{root}), "-jar", try std.fs.path.join(allocator, &.{ root, "servers/vanilla/server.jar" }), "--nogui",
        }),
        // Configured in code with the bench's settings, so it takes no flags.
        .@"lightning-rod" => try allocator.dupe([]const u8, &.{try std.fs.path.join(allocator, &.{ root, "servers/build/lightning-rod/bin/lightning_rod" })}),
        // Vanilla's jar unpacks where the vanilla runs unpack it, and the launcher finds its
        // libraries beside itself.
        .fabric => try allocator.dupe([]const u8, &.{
            "java", "-Xmx4G", try std.fmt.allocPrint(allocator, "-DbundlerRepoDir={s}/servers/vanilla/bundle", .{root}), "-jar", try std.fs.path.join(allocator, &.{ root, "servers/fabric/fabric-server-launch.jar" }), "--nogui",
        }),
        .paper, .@"paper-antixray-1" => try allocator.dupe([]const u8, &.{
            "java", "-Xmx4G", "-jar", try std.fs.path.join(allocator, &.{ root, "servers/paper/paper.jar" }), "--nogui",
        }),
        .pumpkin => try allocator.dupe([]const u8, &.{try std.fs.path.join(allocator, &.{ root, "servers/pumpkin/target/release/pumpkin" })}),
        .steel => try allocator.dupe([]const u8, &.{try std.fs.path.join(allocator, &.{ root, "servers/steel/target/release/steel" })}),
    };
}

/// Writes each server's settings: offline mode, creative, the same view and simulation distance,
/// no spawn protection, no pausing when empty and room for every bot. The world is the flat one
/// every server generates alike, or a copy of the same pregenerated vanilla world.
fn prepare(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, options.directory);
    const path = struct {
        fn join(a: std.mem.Allocator, directory: []const u8, name: []const u8) ![]const u8 {
            return std.fs.path.join(a, &.{ directory, name });
        }
    }.join;
    const flat = options.terrain == .flat;
    switch (options.kind) {
        .vanilla, .paper, .@"paper-antixray-1", .fabric => {
            if (options.kind.isPaper()) try preparePaper(allocator, io, options);
            if (options.kind == .fabric) try prepareFabric(allocator, io, options);
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, options.directory, "eula.txt"), .data = "eula=true\n" });
            var escaped: std.ArrayList(u8) = .empty;
            for (flat_layers_json) |byte| {
                if (byte == ':') try escaped.append(allocator, '\\');
                try escaped.append(allocator, byte);
            }
            const world = if (flat) try std.fmt.allocPrint(allocator, "level-type=minecraft\\:flat\ngenerator-settings={s}\ngenerate-structures=false\n", .{escaped.items}) else try std.fmt.allocPrint(allocator, "level-seed={s}\n", .{terrain_seed});
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, options.directory, "server.properties"), .data = try std.fmt.allocPrint(allocator,
                \\online-mode=false
                \\enforce-secure-profile=false
                \\server-port={d}
                \\gamemode=creative
                \\{s}spawn-protection=0
                \\pause-when-empty-seconds=0
                \\view-distance={d}
                \\simulation-distance={d}
                \\max-players={d}
                \\allow-flight=true
                \\
            , .{ config.port, world, scenario.view_distance, scenario.view_distance, @max(20, options.players + 1) }) });
            if (options.terrain == .real) try copy(allocator, io, try path(allocator, options.root, "servers/build/terrain/vanilla/world"), try path(allocator, options.directory, "world"));
        },
        .@"lightning-rod" => {
            try cwd.createDirPath(io, options.metrics);
            // It exports tick samples to a fixed directory, which leads to memory off the disk measured.
            try cwd.symLink(io, options.metrics, try path(allocator, options.directory, config.metrics), .{ .is_directory = true });
            // The import holds the world and the caches it prebuilt, as vanilla's region files
            // hold its light.
            if (options.terrain == .real) try copy(allocator, io, try path(allocator, options.root, "servers/build/terrain/lightning-rod/."), options.directory);
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
                \\encryption = false
                \\online_mode = false
                \\max_players = {d}
                \\view_distance = {d}
                \\simulation_distance = {d}
                \\
                \\[networking.bedrock]
                \\enabled = false
                \\
            , .{ terrain_seed, config.port, @max(20, options.players + 1), scenario.view_distance, scenario.view_distance }) });
            if (flat) {
                // Pumpkin takes its flat layers from vanilla's world generation settings.
                const data = try path(allocator, options.directory, "world/data/minecraft");
                try cwd.createDirPath(io, data);
                try std.Io.Dir.copyFile(cwd, try path(allocator, options.root, "servers/build/flat/world_gen_settings.dat"), cwd, try path(allocator, data, "world_gen_settings.dat"), io, .{});
            } else if (options.terrain == .real) try copy(allocator, io, try path(allocator, options.root, "servers/build/terrain/vanilla/world"), try path(allocator, options.directory, "world"));
        },
        .steel => {
            const config_directory = try path(allocator, options.directory, "config");
            try cwd.createDirPath(io, config_directory);
            // SteelMC wants every setting, so its own defaults are the base and only ours change.
            var text = try cwd.readFileAlloc(io, try path(allocator, options.root, "servers/steel/package-content/config.toml"), allocator, .limited(1 << 20));
            text = try setting(allocator, text, "server_port", try std.fmt.allocPrint(allocator, "{d}", .{config.port}));
            text = try setting(allocator, text, "max_players", try std.fmt.allocPrint(allocator, "{d}", .{@max(20, options.players + 1)}));
            text = try setting(allocator, text, "view_distance", try std.fmt.allocPrint(allocator, "{d}", .{scenario.view_distance}));
            text = try setting(allocator, text, "simulation_distance", try std.fmt.allocPrint(allocator, "{d}", .{scenario.view_distance}));
            text = try setting(allocator, text, "online_mode", "false");
            text = try setting(allocator, text, "encryption", "false");
            text = try setting(allocator, text, "allow_flight", "true");
            text = try setting(allocator, text, "use_favicon", "false");
            text = try setting(allocator, text, "threshold", "256");
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, config_directory, "config.toml"), .data = text });
            // SteelMC reads no vanilla worlds, so on real terrain it generates the same seed.
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
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, config_directory, "worlds.toml"), .data = try std.fmt.allocPrint(allocator,
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
            , .{ terrain_seed, world }) });
        },
    }
}

/// Copies a directory tree, sharing extents where the filesystem can.
/// Links the vanilla jar Paper patched and the libraries it fetched in setup, which it would
/// otherwise rebuild in every fresh directory, and writes its anti-xray settings. Paper fills in
/// every setting left out.
fn preparePaper(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ "cache", "libraries", "versions" }) |name| {
        const target = try std.fs.path.join(allocator, &.{ options.root, "servers/paper", name });
        cwd.access(io, target, .{}) catch return error.MissingPaperSetup;
        try cwd.symLink(io, target, try std.fs.path.join(allocator, &.{ options.directory, name }), .{ .is_directory = true });
    }
    const anti_xray = switch (options.kind) {
        .paper => return,
        // The overworld settings Paper's anti-xray guide recommends for each mode.
        .@"paper-antixray-1" =>
        \\anticheat:
        \\  anti-xray:
        \\    enabled: true
        \\    engine-mode: 1
        \\    max-block-height: 64
        \\    update-radius: 2
        \\    lava-obscures: false
        \\    use-permission: false
        \\    hidden-blocks: [chest, coal_ore, deepslate_coal_ore, copper_ore, deepslate_copper_ore, raw_copper_block, diamond_ore, deepslate_diamond_ore, emerald_ore, deepslate_emerald_ore, gold_ore, deepslate_gold_ore, iron_ore, deepslate_iron_ore, raw_iron_block, lapis_ore, deepslate_lapis_ore, redstone_ore, deepslate_redstone_ore]
        \\    replacement-blocks: []
        \\
        ,
        else => unreachable,
    };
    const config_directory = try std.fs.path.join(allocator, &.{ options.directory, "config" });
    try cwd.createDirPath(io, config_directory);
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ config_directory, "paper-world-defaults.yml" }), .data = anti_xray });
}

/// Links the mods setup.sh fetched and points the launcher at the vanilla jar the vanilla runs use.
fn prepareFabric(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const cwd = std.Io.Dir.cwd();
    const mods = try std.fs.path.join(allocator, &.{ options.root, "servers/fabric/mods" });
    cwd.access(io, mods, .{}) catch return error.MissingFabricSetup;
    try cwd.symLink(io, mods, try std.fs.path.join(allocator, &.{ options.directory, "mods" }), .{ .is_directory = true });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ options.directory, "fabric-server-launcher.properties" }), .data = try std.fmt.allocPrint(allocator, "serverJar={s}/servers/vanilla/server.jar\n", .{options.root}) });
}

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
