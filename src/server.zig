//! Starting, driving and stopping each server the same way: a fresh directory, the same world
//! and settings, pinned to the same CPUs, with its output kept and its tick reports read.

const std = @import("std");
const linux = std.os.linux;
const scenario = @import("scenario.zig");

pub const Kind = enum {
    vanilla,
    @"lightning-rod",
    pumpkin,
    steel,

    pub fn stopsFromConsole(kind: Kind) bool {
        return kind == .vanilla or kind == .pumpkin;
    }

    /// Whether the server answers vanilla's `tick query` on its console.
    pub fn queriesTicks(kind: Kind) bool {
        return kind == .vanilla or kind == .pumpkin;
    }

    /// Everything a server stores for its worlds, relative to the server's directory.
    pub fn worldPaths(kind: Kind) []const []const u8 {
        return switch (kind) {
            .vanilla, .pumpkin => &.{"world"},
            // Lightning Rod keeps its chunk cache and write ahead log beside the world.
            .@"lightning-rod" => &.{ "world", "world.cache", "world.wal" },
            .steel => &.{"saves"},
        };
    }
};

/// Flat layers every server builds its world from: stone up to y 63 and grass on top, the world
/// Lightning Rod generates.
const flat_layers_json =
    \\{"layers":[{"block":"minecraft:stone","height":128},{"block":"minecraft:grass_block","height":1}],"biome":"minecraft:plains","structure_overrides":[]}
;

pub const Options = struct {
    kind: Kind,
    /// The bench repository, where servers were built.
    root: []const u8,
    /// A fresh directory the server runs in.
    directory: []const u8,
    port: u16,
    players: usize,
    cpus: []const u8,
    /// Where Lightning Rod writes its tick samples, off the disk being measured.
    metrics: []const u8,
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
            .vanilla, .pumpkin => {
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
        .@"lightning-rod" => try allocator.dupe([]const u8, &.{
            try std.fs.path.join(allocator, &.{ root, "servers/build/lightning-rod/bin/lightning_rod" }),
            try std.fmt.allocPrint(allocator, "--port={d}", .{options.port}),
            "--world=world",
            try std.fmt.allocPrint(allocator, "--max-players={d}", .{@max(32, options.players + 1)}),
            try std.fmt.allocPrint(allocator, "--view-distance={d}", .{scenario.view_distance}),
            try std.fmt.allocPrint(allocator, "--simulation-distance={d}", .{scenario.view_distance}),
            try std.fmt.allocPrint(allocator, "--metrics-directory={s}", .{options.metrics}),
        }),
        .pumpkin => try allocator.dupe([]const u8, &.{try std.fs.path.join(allocator, &.{ root, "servers/pumpkin/target/release/pumpkin" })}),
        .steel => try allocator.dupe([]const u8, &.{try std.fs.path.join(allocator, &.{ root, "servers/steel/target/release/steel" })}),
    };
}

/// Writes each server's settings: offline mode, creative, the flat world, the same view and
/// simulation distance, no spawn protection, no pausing when empty and room for every bot.
fn prepare(allocator: std.mem.Allocator, io: std.Io, options: Options) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, options.directory);
    const path = struct {
        fn join(a: std.mem.Allocator, directory: []const u8, name: []const u8) ![]const u8 {
            return std.fs.path.join(a, &.{ directory, name });
        }
    }.join;
    switch (options.kind) {
        .vanilla => {
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, options.directory, "eula.txt"), .data = "eula=true\n" });
            var escaped: std.ArrayList(u8) = .empty;
            for (flat_layers_json) |byte| {
                if (byte == ':') try escaped.append(allocator, '\\');
                try escaped.append(allocator, byte);
            }
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, options.directory, "server.properties"), .data = try std.fmt.allocPrint(allocator,
                \\online-mode=false
                \\enforce-secure-profile=false
                \\server-port={d}
                \\gamemode=creative
                \\level-type=minecraft\:flat
                \\generator-settings={s}
                \\generate-structures=false
                \\spawn-protection=0
                \\pause-when-empty-seconds=0
                \\view-distance={d}
                \\simulation-distance={d}
                \\max-players={d}
                \\allow-flight=true
                \\
            , .{ options.port, escaped.items, scenario.view_distance, scenario.view_distance, @max(20, options.players + 1) }) });
        },
        .@"lightning-rod" => try cwd.createDirPath(io, options.metrics),
        .pumpkin => {
            // Pumpkin reads its settings from the directory it runs in and fills in every one left
            // out with its default.
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, options.directory, "pumpkin.toml"), .data = try std.fmt.allocPrint(allocator,
                \\default_gamemode = "Creative"
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
            , .{ options.port, @max(20, options.players + 1), scenario.view_distance, scenario.view_distance }) });
            // Pumpkin takes its flat layers from vanilla's world generation settings.
            const data = try path(allocator, options.directory, "world/data/minecraft");
            try cwd.createDirPath(io, data);
            try std.Io.Dir.copyFile(cwd, try path(allocator, options.root, "servers/build/flat/world_gen_settings.dat"), cwd, try path(allocator, data, "world_gen_settings.dat"), io, .{});
        },
        .steel => {
            const config = try path(allocator, options.directory, "config");
            try cwd.createDirPath(io, config);
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, config, "config.toml"), .data = try std.fmt.allocPrint(allocator,
                \\[server]
                \\server_port = {d}
                \\max_players = {d}
                \\view_distance = {d}
                \\simulation_distance = {d}
                \\online_mode = false
                \\encryption = false
                \\allow_flight = true
                \\use_favicon = false
                \\
                \\[server.compression]
                \\threshold = 256
                \\
            , .{ options.port, @max(20, options.players + 1), scenario.view_distance, scenario.view_distance }) });
            try cwd.writeFile(io, .{ .sub_path = try path(allocator, config, "worlds.toml"), .data =
                \\save_path = "saves"
                \\seed = ""
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
                \\generator = "minecraft:flat"
                \\default = true
                \\
                \\[domains.minecraft.worlds.config]
                \\layers = [{ block = "minecraft:stone", height = 128 }, { block = "minecraft:grass_block", height = 1 }]
                \\structure_overrides = []
                \\
            });
        },
    }
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
