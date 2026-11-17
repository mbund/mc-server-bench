//! Writes the results of sweeps as one Markdown file: the servers measured, then for every terrain
//! and scenario its machine, its charts over player counts and a table for every player count with
//! a row per server.

const std = @import("std");
const server_module = @import("server.zig");
const scenario = @import("scenario.zig");
const charts = @import("charts.zig");

const Object = std.json.ObjectMap;

pub fn write(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, chart_urls: ?[]const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const urls = if (chart_urls) |path| try cwd.readFileAlloc(io, path, allocator, .limited(1 << 20)) else "";
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
        \\{d} runs. `./run.sh` reproduces them all, `./run.sh <server>` one server, and
        \\`./run.sh --scenarios=<scenario>` one scenario, as CI runs each on a machine of its own.
        \\Every server gets the same view and simulation distance, {d} chunks, and bots on their own CPUs.
        \\Each scenario names the machine its runs measured on and charts how its measures grow with
        \\players, or cows in the cows scenario, followed by a table for every count.
        \\
        \\## Servers
        \\
        \\| Server | Version |
        \\|---|---|
        \\
    , .{ runs.items.len, scenario.view_distance });
    for (std.enums.values(server_module.Kind)) |kind| {
        const run = for (runs.items) |candidate| {
            if (std.mem.eql(u8, text(candidate, &.{"server"}), @tagName(kind))) break candidate;
        } else continue;
        // Results from before versions were recorded have none.
        const recorded = text(run, &.{"version"});
        try writer.print("| {s} | {s} |\n", .{ @tagName(kind), if (recorded.len == 0) "not recorded" else recorded });
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

    try startupSection(allocator, io, writer, directory, urls, runs.items);
    for ([_]server_module.Terrain{ .real, .flat }) |terrain| for (std.enums.values(scenario.Kind)) |kind| {
        var counts: std.ArrayList(u64) = .empty;
        for (runs.items) |run| {
            if (!matches(run, terrain, kind)) continue;
            const players: u64 = @intFromFloat(number(run, &.{axis(kind)}));
            if (std.mem.indexOfScalar(u64, counts.items, players) == null) try counts.append(allocator, players);
        }
        if (counts.items.len == 0) continue;
        std.mem.sort(u64, counts.items, {}, std.sort.asc(u64));
        try writer.print("## {s} terrain, {s}\n\n{s}\n\n", .{ terrainName(terrain), @tagName(kind), description(kind) });
        try machines(allocator, writer, runs.items, terrain, kind);
        if (counts.items.len > 1) try chartSection(allocator, io, writer, directory, urls, runs.items, terrain, kind, counts.items);
        for (counts.items) |players| try table(writer, runs.items, terrain, kind, players);
    };
    const path = try std.fs.path.join(allocator, &.{ directory, "report.md" });
    try cwd.writeFile(io, .{ .sub_path = path, .data = output.written() });
    std.log.info("wrote {s}", .{path});
}

/// Every machine a scenario measured on: one in CI, where a scenario runs in a job of its own,
/// and more only when results were joined from elsewhere.
fn machines(allocator: std.mem.Allocator, writer: *std.Io.Writer, runs: []const Object, terrain: server_module.Terrain, kind: scenario.Kind) !void {
    var seen: std.ArrayList(Object) = .empty;
    for (runs) |run| {
        if (!matches(run, terrain, kind) or text(run, &.{ "host", "cpu" }).len == 0) continue;
        for (seen.items) |other| {
            if (std.mem.eql(u8, text(other, &.{ "host", "cpu" }), text(run, &.{ "host", "cpu" })) and number(other, &.{ "host", "cpus" }) == number(run, &.{ "host", "cpus" }) and
                std.mem.eql(u8, text(other, &.{ "host", "kernel" }), text(run, &.{ "host", "kernel" }))) break;
        } else try seen.append(allocator, run);
    }
    if (seen.items.len == 0) return;
    try writer.writeAll(if (seen.items.len == 1) "**Machine:**" else "**Machines** (these runs were joined from more than one, so they compare less exactly):");
    for (seen.items, 0..) |run, index| {
        try writer.print("{s} {s}, {d:.0} CPUs, {d:.1} GB memory, Linux {s}", .{ if (index == 0) "" else ";", text(run, &.{ "host", "cpu" }), number(run, &.{ "host", "cpus" }), number(run, &.{ "host", "memory_mb" }) / 1024, text(run, &.{ "host", "kernel" }) });
    }
    try writer.writeAll("\n\n");
}

/// Draws a scenario's charts into the report's charts directory and links them. The link is the
/// URL a `name url` line of the chart URLs gives for the file, as CI uploads each chart to a page
/// of its own, or else the file beside the report.
fn chartSection(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, directory: []const u8, urls: []const u8, runs: []const Object, terrain: server_module.Terrain, kind: scenario.Kind, counts: []const u64) !void {
    var panels: std.ArrayList(charts.Panel) = .empty;
    for (charts.measures) |measure| {
        var series: std.ArrayList(charts.Series) = .empty;
        for (std.enums.values(server_module.Kind)) |server| {
            const values = try allocator.alloc(?f64, counts.len);
            var any = false;
            for (counts, values) |players, *value| {
                value.* = null;
                const run = latest(runs, server, terrain, kind, players) orelse continue;
                if (measure.reported and std.mem.eql(u8, text(run, &.{ "window", "mspt", "source" }), "none")) continue;
                const measured = number(run, measure.path);
                // A log scale has no place for zero.
                if (measured <= 0) continue;
                value.* = measured;
                any = true;
            }
            if (any) try series.append(allocator, .{ .server = server, .values = values });
        }
        try panels.append(allocator, .{ .measure = measure, .series = series.items });
    }
    const name = try std.fmt.allocPrint(allocator, "{s}-{s}.svg", .{ @tagName(terrain), @tagName(kind) });
    const title = try std.fmt.allocPrint(allocator, "{s} terrain, {s}", .{ terrainName(terrain), @tagName(kind) });
    const image = try charts.svg(allocator, title, axis(kind), counts, panels.items);
    const folder = try std.fs.path.join(allocator, &.{ directory, "charts" });
    try std.Io.Dir.cwd().createDirPath(io, folder);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ folder, name }), .data = image });
    try writer.print("![{s}: CPU time, tick time, traffic and memory by number of {s}, on log scales]({s})\n\n", .{ title, axis(kind), try chartLink(allocator, urls, name) });
    try writer.writeAll("Log scales, so a server using a hundred times more than another reads as clearly as one using twice as much. A gap in a line is a player count without a result, and a server with no tick times of its own has no mspt line.\n\n");
}

/// Where the report links a chart: the URL a `name url` line of the chart URLs gives for it, as CI
/// uploads each chart to a page of its own, or else the file beside the report.
fn chartLink(allocator: std.mem.Allocator, urls: []const u8, name: []const u8) ![]const u8 {
    var lines = std.mem.tokenizeScalar(u8, urls, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        if (!std.mem.eql(u8, fields.next() orelse continue, name)) continue;
        return fields.next() orelse continue;
    }
    return std.fmt.allocPrint(allocator, "charts/{s}", .{name});
}

/// How long each server takes to start and how much it keeps on disk, which no player count
/// changes. Both come from the idle runs alone, so the idle scenario's job draws the same chart
/// from its own results as the report does from all of them.
fn startupSection(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, directory: []const u8, urls: []const u8, runs: []const Object) !void {
    const terrains = [_]server_module.Terrain{ .flat, .real };
    comptime std.debug.assert(terrains.len == charts.terrains.len);
    var startup: std.ArrayList(charts.Row) = .empty;
    var world: std.ArrayList(charts.Row) = .empty;
    for (std.enums.values(server_module.Kind)) |server| {
        var started: charts.Row = .{ .server = server, .values = @splat(null) };
        var kept: charts.Row = .{ .server = server, .values = @splat(null) };
        for (terrains, 0..) |terrain, index| {
            var samples: std.ArrayList(f64) = .empty;
            // The world after the idle run with the fewest players, the least it can keep.
            var fewest: ?Object = null;
            for (runs) |run| {
                if (!matches(run, terrain, .idle) or !std.mem.eql(u8, text(run, &.{"server"}), @tagName(server))) continue;
                const seconds = number(run, &.{"startup_s"});
                if (seconds > 0) try samples.append(allocator, seconds);
                if (fewest == null or number(run, &.{"players"}) < number(fewest.?, &.{"players"})) fewest = run;
            }
            if (samples.items.len != 0) {
                std.mem.sort(f64, samples.items, {}, std.sort.asc(f64));
                started.values[index] = samples.items[samples.items.len / 2];
            }
            if (fewest) |run| {
                const megabytes = number(run, &.{"world_mb"});
                if (megabytes > 0) kept.values[index] = megabytes;
            }
        }
        if (started.values[0] != null or started.values[1] != null) try startup.append(allocator, started);
        if (kept.values[0] != null or kept.values[1] != null) try world.append(allocator, kept);
    }
    if (startup.items.len == 0 and world.items.len == 0) return;
    const name = "startup-world.svg";
    const image = try charts.dots(allocator, "Startup and world size", &.{
        .{ .title = "Startup", .unit = "s", .rows = startup.items },
        .{ .title = "World on disk", .unit = "MB", .rows = world.items },
    });
    const folder = try std.fs.path.join(allocator, &.{ directory, "charts" });
    try std.Io.Dir.cwd().createDirPath(io, folder);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ folder, name }), .data = image });
    try writer.print(
        \\## Startup and world size
        \\
        \\**Startup** is from launching the server to its first answer to a status request, the median
        \\of its idle runs. **World on disk** is everything the server keeps for its world after the
        \\idle run with the fewest players, caches included. On real terrain every server starts from the
        \\same square of pregenerated chunks, which SteelMC, reading no vanilla worlds, generates itself.
        \\
        \\![Startup time and world size on disk of every server, flat and real terrain, on log scales]({s})
        \\
        \\| Server | Startup flat s | Startup real s | World flat MB | World real MB |
        \\|---|---:|---:|---:|---:|
        \\
    , .{try chartLink(allocator, urls, name)});
    for (std.enums.values(server_module.Kind)) |server| {
        const started = for (startup.items) |row| {
            if (row.server == server) break row;
        } else charts.Row{ .server = server, .values = @splat(null) };
        const kept = for (world.items) |row| {
            if (row.server == server) break row;
        } else charts.Row{ .server = server, .values = @splat(null) };
        if (started.values[0] == null and started.values[1] == null and kept.values[0] == null and kept.values[1] == null) continue;
        try writer.print("| {s} ", .{@tagName(server)});
        for ([_]?f64{ started.values[0], started.values[1], kept.values[0], kept.values[1] }) |value| {
            if (value) |v| try writer.print("| {d:.1} ", .{v}) else try writer.writeAll("| n/a ");
        }
        try writer.writeAll("|\n");
    }
    try writer.writeByte('\n');
}

fn table(writer: *std.Io.Writer, runs: []const Object, terrain: server_module.Terrain, kind: scenario.Kind, players: u64) !void {
    try writer.print("### {d} {s}\n\n", .{ players, if (players == 1) axis(kind)[0 .. axis(kind).len - 1] else axis(kind) });
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
        if (number(run, &.{axis(kind)}) != @as(f64, @floatFromInt(players))) continue;
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
        .cows => "One player stands at spawn among cows summoned two blocks apart on a square field around them, all in view and ticking.",
    };
}

/// What a scenario counts: cows around one player in the cows scenario, players in every other.
fn axis(kind: scenario.Kind) []const u8 {
    return if (kind == .cows) "cows" else "players";
}
