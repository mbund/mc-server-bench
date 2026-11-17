//! Writes the results of sweeps as one Markdown file: the servers and machines measured, then a
//! table for every terrain, scenario and player count with a row per server.

const std = @import("std");
const server_module = @import("server.zig");
const scenario = @import("scenario.zig");

const Object = std.json.ObjectMap;

pub fn write(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const lines = try cwd.readFileAlloc(io, try std.fs.path.join(allocator, &.{ directory, "results.jsonl" }), allocator, .limited(1 << 30));
    var runs: std.ArrayList(Object) = .empty;
    var each = std.mem.tokenizeScalar(u8, lines, '\n');
    while (each.next()) |line| {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{});
        if (value != .object) return error.InvalidResults;
        try runs.append(allocator, value.object);
    }
    if (runs.items.len == 0) return error.NoResults;

    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;
    try writer.print(
        \\# Minecraft server benchmark
        \\
        \\{d} runs. `./run.sh` in `nix develop` reproduces them all, and `./run.sh <server>` one server.
        \\Every server gets the same view and simulation distance, {d} chunks, and bots on their own CPUs.
        \\
        \\## Servers
        \\
        \\| Server | Version | CPU | CPUs | Memory | Kernel |
        \\|---|---|---|---:|---:|---|
        \\
    , .{ runs.items.len, scenario.view_distance });
    for (std.enums.values(server_module.Kind)) |kind| {
        const run = for (runs.items) |candidate| {
            if (std.mem.eql(u8, text(candidate, &.{"server"}), @tagName(kind))) break candidate;
        } else continue;
        // Results from before versions and machines were recorded have neither.
        if (text(run, &.{"version"}).len == 0) {
            try writer.print("| {s} | not recorded | | | | |\n", .{@tagName(kind)});
            continue;
        }
        try writer.print("| {s} | {s} | {s} | {d:.0} | {d:.0} GB | {s} |\n", .{ @tagName(kind), text(run, &.{"version"}), text(run, &.{ "host", "cpu" }), number(run, &.{ "host", "cpus" }), number(run, &.{ "host", "memory_mb" }) / 1024, text(run, &.{ "host", "kernel" }) });
    }
    try writer.writeAll(
        \\
        \\Columns, per player where it says so:
        \\- **Total KB** is everything a bot received over the whole run, joining included.
        \\- **KB/s** is what a bot received in the measured window, after joining and warming up.
        \\- **KB/chunk** and **Chunks** count chunk packets over the whole run.
        \\- **CPU ms/tick** is the CPU time of every server thread, measured from outside the server.
        \\- **mspt** is the server's own tick time, n/a where the server does not report it.
        \\- **Disk MB** is what the server wrote in the measured window, and **World MB** its world
        \\  on disk afterwards, caches included.
        \\
        \\
    );

    for ([_]server_module.Terrain{ .real, .flat }) |terrain| for (std.enums.values(scenario.Kind)) |kind| {
        var counts: std.ArrayList(u64) = .empty;
        for (runs.items) |run| {
            if (!matches(run, terrain, kind)) continue;
            const players: u64 = @intFromFloat(number(run, &.{"players"}));
            if (std.mem.indexOfScalar(u64, counts.items, players) == null) try counts.append(allocator, players);
        }
        std.mem.sort(u64, counts.items, {}, std.sort.asc(u64));
        for (counts.items) |players| try table(writer, runs.items, terrain, kind, players);
    };
    const path = try std.fs.path.join(allocator, &.{ directory, "report.md" });
    try cwd.writeFile(io, .{ .sub_path = path, .data = output.written() });
    std.log.info("wrote {s}", .{path});
}

fn table(writer: *std.Io.Writer, runs: []const Object, terrain: server_module.Terrain, kind: scenario.Kind, players: u64) !void {
    try writer.print("## {s} terrain, {s}, {d} {s}\n\n{s}\n\n", .{ terrainName(terrain), @tagName(kind), players, if (players == 1) "player" else "players", description(kind) });
    try writer.writeAll(
        \\| Server | Total KB | KB/s | KB/chunk | Chunks | CPU ms/tick | mspt mean | mspt p99 | TPS | Peak RAM MB | Disk MB | World MB | Problems |
        \\|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
        \\
    );
    var problems: usize = 0;
    for (std.enums.values(server_module.Kind)) |server| {
        const run = latest(runs, server, terrain, kind, players) orelse continue;
        const chunks = chunkTraffic(run);
        const reported = !std.mem.eql(u8, text(run, &.{ "window", "mspt", "source" }), "none");
        const count = if (run.get("problems")) |value| value.array.items.len else 0;
        problems += count;
        try writer.print("| {s} | {d:.0} | {d:.2} | {d:.2} | {d:.0} | {d:.2} | ", .{
            @tagName(server),
            number(run, &.{ "traffic", "setup_kb_per_player" }) + number(run, &.{ "traffic", "play_kb_per_player" }),
            number(run, &.{ "window", "received_kb_per_s_per_player" }),
            if (chunks.count == 0) 0 else chunks.kb / chunks.count,
            chunks.count,
            number(run, &.{ "window", "cpu_ms_per_tick" }),
        });
        if (reported) {
            try writer.print("{d:.2} | {d:.2} | ", .{ number(run, &.{ "window", "mspt", "mean_ms" }), number(run, &.{ "window", "mspt", "p99_ms" }) });
        } else try writer.writeAll("n/a | n/a | ");
        try writer.print("{d:.1} | {d:.0} | {d:.1} | {d:.1} | {d} |\n", .{
            number(run, &.{ "window", "tps" }),
            number(run, &.{"peak_rss_mb"}),
            number(run, &.{ "window", "disk_write_mb" }),
            number(run, &.{"world_mb"}),
            count,
        });
    }
    try writer.writeByte('\n');
    if (problems == 0) return;
    for (std.enums.values(server_module.Kind)) |server| {
        const run = latest(runs, server, terrain, kind, players) orelse continue;
        const list = run.get("problems") orelse continue;
        for (list.array.items) |problem| try writer.print("- {s}: {s}\n", .{ @tagName(server), problem.string });
    }
    try writer.writeByte('\n');
}

fn matches(run: Object, terrain: server_module.Terrain, kind: scenario.Kind) bool {
    return std.mem.eql(u8, text(run, &.{"terrain"}), @tagName(terrain)) and std.mem.eql(u8, text(run, &.{"scenario"}), @tagName(kind));
}

/// The last run of a combination, so a rerun replaces an earlier one.
fn latest(runs: []const Object, server: server_module.Kind, terrain: server_module.Terrain, kind: scenario.Kind, players: u64) ?Object {
    var found: ?Object = null;
    for (runs) |run| {
        if (!matches(run, terrain, kind) or !std.mem.eql(u8, text(run, &.{"server"}), @tagName(server))) continue;
        if (number(run, &.{"players"}) != @as(f64, @floatFromInt(players))) continue;
        found = run;
    }
    return found;
}

fn chunkTraffic(run: Object) struct { kb: f64, count: f64 } {
    const traffic = run.get("traffic") orelse return .{ .kb = 0, .count = 0 };
    const packets = traffic.object.get("packets") orelse return .{ .kb = 0, .count = 0 };
    for (packets.array.items) |packet| {
        if (!std.mem.eql(u8, text(packet.object, &.{"name"}), "map_chunk")) continue;
        return .{ .kb = number(packet.object, &.{"kb_per_player"}), .count = number(packet.object, &.{"count_per_player"}) };
    }
    return .{ .kb = 0, .count = 0 };
}

fn lookup(object: Object, path: []const []const u8) ?std.json.Value {
    var current: std.json.Value = .{ .object = object };
    for (path) |name| {
        if (current != .object) return null;
        current = current.object.get(name) orelse return null;
    }
    return current;
}

fn number(object: Object, path: []const []const u8) f64 {
    return switch (lookup(object, path) orelse return 0) {
        .integer => |value| @floatFromInt(value),
        .float => |value| value,
        else => 0,
    };
}

fn text(object: Object, path: []const []const u8) []const u8 {
    return switch (lookup(object, path) orelse return "") {
        .string => |value| value,
        else => "",
    };
}

fn terrainName(terrain: server_module.Terrain) []const u8 {
    return switch (terrain) {
        .real => "Real",
        .flat => "Flat",
        .generate => unreachable,
    };
}

fn description(kind: scenario.Kind) []const u8 {
    return switch (kind) {
        .idle => "Everyone stands still at spawn.",
        .wander => "Everyone flies at walking speed at random within 24 blocks of spawn, in sight of each other.",
        .spread => "Everyone flies to a spot of their own, far enough apart that views never overlap, and hovers there.",
        .explore => "Everyone flies outward at 20 blocks a second into terrain never generated before.",
        .build => "Everyone places or breaks a block every tick at a spot of their own near spawn.",
    };
}
