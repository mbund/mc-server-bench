//! Writes the results of runs as one Markdown file: the servers measured, then for every terrain
//! and scenario its machine, its charts over its counts and a table for every count with a row per
//! server.

const std = @import("std");
const server_module = @import("server.zig");
const scenario = @import("scenario.zig");
const charts = @import("charts.zig");
const config = @import("config.zig");

const Object = std.json.ObjectMap;

pub fn write(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, charts_url: ?[]const u8) !void {
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
        \\{d} runs. `./run.sh` reproduces them all, `./run.sh <server>` one server, and
        \\`scenarios/<scenario>.sh` one scenario, as CI runs each on a machine of its own.
        \\Every server gets the same render distance, {d} chunks, and simulation distance, {d} chunks, and
        \\bots on their own CPUs.
        \\Each scenario names the machine its runs measured on and charts how its measures grow with
        \\players, or cows in the cows scenario, followed by a table for every count.
        \\
        \\## Servers
        \\
        \\| Server | Version |
        \\|---|---|
        \\
    , .{ runs.items.len, scenario.view_distance, config.simulation_distance });
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

    try startupSection(allocator, io, writer, directory, charts_url, runs.items);
    for ([_]server_module.Terrain{ .real, .flat, .wide }) |terrain| for (std.enums.values(scenario.Kind)) |kind| {
        var counts: std.ArrayList(u64) = .empty;
        for (runs.items) |run| {
            if (!matches(run, terrain, kind)) continue;
            const players: u64 = @intFromFloat(number(run, &.{kind.counted()}));
            if (std.mem.indexOfScalar(u64, counts.items, players) == null) try counts.append(allocator, players);
        }
        if (counts.items.len == 0) continue;
        std.mem.sort(u64, counts.items, {}, std.sort.asc(u64));
        try writer.print("## {s} terrain, {s}\n\n{s}\n\n", .{ terrainName(terrain), @tagName(kind), kind.description() });
        try machines(allocator, writer, runs.items, terrain, kind);
        if (counts.items.len > 1) try chartSection(allocator, io, writer, directory, charts_url, runs.items, terrain, kind, counts.items);
        try heldTable(writer, runs.items, terrain, kind);
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
fn chartSection(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, directory: []const u8, charts_url: ?[]const u8, runs: []const Object, terrain: server_module.Terrain, kind: scenario.Kind, counts: []const u64) !void {
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
        // A measure no server has here, like edit round trips where nobody edits, takes no panel.
        if (series.items.len == 0) continue;
        try panels.append(allocator, .{ .measure = measure, .series = series.items });
    }
    const name = try std.fmt.allocPrint(allocator, "{s}-{s}.svg", .{ @tagName(terrain), @tagName(kind) });
    const title = try std.fmt.allocPrint(allocator, "{s} terrain, {s}", .{ terrainName(terrain), @tagName(kind) });
    const image = try charts.svg(allocator, title, kind.counted(), counts, panels.items);
    const folder = try std.fs.path.join(allocator, &.{ directory, "charts" });
    try std.Io.Dir.cwd().createDirPath(io, folder);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ folder, name }), .data = image });
    try writer.print("![{s}: CPU time, tick time, traffic and memory by number of {s}, on log scales]({s})\n\n", .{ title, kind.counted(), try chartLink(allocator, charts_url, name) });
    try writer.writeAll("Log scales, so a server using a hundred times more than another reads as clearly as one using twice as much. A gap in a line is a player count without a result, and a server with no tick times of its own has no mspt line.\n\n");
}

/// Where the report links a chart: under the URL the charts were published to, as CI publishes
/// them where the run's summary can show them, or else the file beside the report.
fn chartLink(allocator: std.mem.Allocator, charts_url: ?[]const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ charts_url orelse "charts", name });
}

/// A measure of a server itself rather than of how it grows with players, taken from the idle
/// runs: the median of all of them, or that of the last step of the ramp, where the server stopped
/// and its world was measured.
const ServerMeasure = struct {
    title: []const u8,
    column: []const u8,
    unit: []const u8,
    path: []const []const u8,
    median: bool,
};

const server_measures = [_]ServerMeasure{
    .{ .title = "Status answered", .column = "Status", .unit = "s", .path = &.{"startup_s"}, .median = true },
    .{ .title = "First chunk", .column = "First chunk", .unit = "s", .path = &.{"first_chunk_s"}, .median = true },
    .{ .title = "Full render distance", .column = "Full view", .unit = "s", .path = &.{"full_view_s"}, .median = true },
    .{ .title = "World on disk", .column = "World", .unit = "MB", .path = &.{"world_mb"}, .median = false },
};

/// How long each server takes to start, three ways, and how much it keeps on disk, which no player
/// count changes. All come from the idle runs.
fn startupSection(allocator: std.mem.Allocator, io: std.Io, writer: *std.Io.Writer, directory: []const u8, charts_url: ?[]const u8, runs: []const Object) !void {
    const terrains = [_]server_module.Terrain{ .flat, .real };
    comptime std.debug.assert(terrains.len == charts.terrains.len);
    var panels: [server_measures.len]charts.DotPanel = undefined;
    var any = false;
    for (server_measures, &panels) |measure, *panel| {
        var rows: std.ArrayList(charts.Row) = .empty;
        for (std.enums.values(server_module.Kind)) |server| {
            var row: charts.Row = .{ .server = server, .values = @splat(null) };
            for (terrains, &row.values) |terrain, *value| {
                var samples: std.ArrayList(f64) = .empty;
                var last: ?Object = null;
                for (runs) |run| {
                    if (!matches(run, terrain, .idle) or !std.mem.eql(u8, text(run, &.{"server"}), @tagName(server))) continue;
                    const measured = number(run, measure.path);
                    if (measured > 0) try samples.append(allocator, measured);
                    if (last == null or number(run, &.{"players"}) > number(last.?, &.{"players"})) last = run;
                }
                if (measure.median) {
                    if (samples.items.len == 0) continue;
                    std.mem.sort(f64, samples.items, {}, std.sort.asc(f64));
                    value.* = samples.items[samples.items.len / 2];
                } else if (last) |run| {
                    const measured = number(run, measure.path);
                    if (measured > 0) value.* = measured;
                }
            }
            if (row.values[0] != null or row.values[1] != null) try rows.append(allocator, row);
        }
        any = any or rows.items.len != 0;
        panel.* = .{ .title = measure.title, .unit = measure.unit, .rows = rows.items };
    }
    if (!any) return;
    const name = "startup-world.svg";
    const image = try charts.dots(allocator, "Startup and world size", &panels);
    const folder = try std.fs.path.join(allocator, &.{ directory, "charts" });
    try std.Io.Dir.cwd().createDirPath(io, folder);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ folder, name }), .data = image });
    try writer.print(
        \\## Startup and world size
        \\
        \\Startup is timed from launching the server three ways: to its first answer to a status
        \\request, to a player logged in, without authentication, holding its first chunk, and to
        \\that player holding every chunk of its render distance. Each is the median of the server's
        \\idle runs. **World on disk** is everything the server keeps for its world once its idle ramp
        \\stopped, caches included. On real terrain every server starts from the same
        \\square of pregenerated chunks, which SteelMC, reading no vanilla worlds, generates itself.
        \\
        \\![Startup times and world size on disk of every server, flat and real terrain, on log scales]({s})
        \\
        \\| Server |
    , .{try chartLink(allocator, charts_url, name)});
    for (server_measures) |measure| for (charts.terrains) |terrain| try writer.print(" {s} {s} {s} |", .{ measure.column, terrain, measure.unit });
    try writer.writeAll("\n|---|");
    for (0..server_measures.len * charts.terrains.len) |_| try writer.writeAll("---:|");
    try writer.writeByte('\n');
    for (std.enums.values(server_module.Kind)) |server| {
        var line: std.Io.Writer.Allocating = .init(allocator);
        var present = false;
        for (panels) |panel| {
            const row = for (panel.rows) |row| {
                if (row.server == server) break row;
            } else charts.Row{ .server = server, .values = @splat(null) };
            for (row.values) |value| {
                if (value) |v| {
                    present = true;
                    try line.writer.print(" {d:.2} |", .{v});
                } else try line.writer.writeAll(" n/a |");
            }
        }
        if (present) try writer.print("| {s} |{s}\n", .{ @tagName(server), line.written() });
    }
    try writer.writeByte('\n');
}

/// How far each server went before breaking a limit: the most it kept up with, and what ended its
/// run, or that it kept up with every step.
fn heldTable(writer: *std.Io.Writer, runs: []const Object, terrain: server_module.Terrain, kind: scenario.Kind) !void {
    try writer.print(
        \\| Server | Most {s} held | Ended by |
        \\|---|---:|---|
        \\
    , .{kind.counted()});
    for (std.enums.values(server_module.Kind)) |server| {
        var held: f64 = 0;
        var tried: f64 = 0;
        var ended: []const u8 = "";
        for (runs) |run| {
            if (!matches(run, terrain, kind) or !std.mem.eql(u8, text(run, &.{"server"}), @tagName(server))) continue;
            const count = number(run, &.{kind.counted()});
            tried = @max(tried, count);
            const limit = text(run, &.{"limit"});
            if (limit.len == 0) held = @max(held, count) else ended = limit;
        }
        if (tried == 0) continue;
        if (ended.len == 0) {
            try writer.print("| {s} | {d:.0} | kept up with every step |\n", .{ @tagName(server), held });
        } else if (held == 0) {
            try writer.print("| {s} | none | {s} |\n", .{ @tagName(server), ended });
        } else try writer.print("| {s} | {d:.0} | {s} |\n", .{ @tagName(server), held, ended });
    }
    try writer.writeByte('\n');
}

fn table(writer: *std.Io.Writer, runs: []const Object, terrain: server_module.Terrain, kind: scenario.Kind, players: u64) !void {
    // Folded away, as a ramp measures many counts.
    try writer.print("<details><summary>{d} {s}</summary>\n\n", .{ players, if (players == 1) kind.counted()[0 .. kind.counted().len - 1] else kind.counted() });
    defer writer.writeAll("</details>\n\n") catch {};
    try writer.writeAll(
        \\| Server | Total KB | KB/s | KB/chunk | Chunks | CPU ms/tick | mspt mean | mspt p99 | TPS | Round trip p99 ms | Edit ack p99 ms | Peak RAM MB | Disk MB | World MB | Problems |
        \\|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
        \\
    );
    var problems: usize = 0;
    for (std.enums.values(server_module.Kind)) |server| {
        const run = latest(runs, server, terrain, kind, players) orelse continue;
        const reported = !std.mem.eql(u8, text(run, &.{ "window", "mspt", "source" }), "none");
        const count = if (run.get("problems")) |value| value.array.items.len else 0;
        problems += count;
        // Per player, over the run until this step was measured.
        const present = @max(1, number(run, &.{"players"}));
        const chunks = number(run, &.{ "bots", "chunks" });
        try writer.print("| {s} | {d:.0} | {d:.2} | {d:.2} | {d:.0} | {d:.2} | ", .{
            @tagName(server),
            number(run, &.{"total_received_mb"}) * 1024 / present,
            number(run, &.{ "window", "received_kb_per_s_per_player" }),
            if (chunks == 0) 0 else number(run, &.{ "bots", "chunk_bytes" }) / 1024 / chunks,
            chunks / present,
            number(run, &.{ "window", "cpu_ms_per_tick" }),
        });
        if (reported) {
            try writer.print("{d:.2} | {d:.2} | ", .{ number(run, &.{ "window", "mspt", "mean_ms" }), number(run, &.{ "window", "mspt", "p99_ms" }) });
        } else try writer.writeAll("n/a | n/a | ");
        try writer.print("{d:.1} | ", .{number(run, &.{ "window", "tps" })});
        if (number(run, &.{ "window", "pings" }) > 0) try writer.print("{d:.1} | ", .{number(run, &.{ "window", "ping_p99_ms" })}) else try writer.writeAll("n/a | ");
        if (number(run, &.{ "window", "edits" }) > 0) try writer.print("{d:.1} | ", .{number(run, &.{ "window", "edit_p99_ms" })}) else try writer.writeAll("n/a | ");
        try writer.print("{d:.0} | {d:.1} | {d:.1} | {d} |\n", .{
            number(run, &.{"peak_rss_mb"}),
            number(run, &.{ "window", "disk_write_mb" }),
            number(run, &.{"world_mb"}),
            count,
        });
    }
    try writer.writeByte('\n');
    if (problems == 0) return;
    // Each server's problems folded away under their count, as a run with many bots can list
    // one for each.
    for (std.enums.values(server_module.Kind)) |server| {
        const run = latest(runs, server, terrain, kind, players) orelse continue;
        const list = run.get("problems") orelse continue;
        if (list.array.items.len == 0) continue;
        try writer.print("<details><summary>{s}: {d} {s}</summary>\n\n", .{ @tagName(server), list.array.items.len, if (list.array.items.len == 1) "problem" else "problems" });
        for (list.array.items) |problem| try writer.print("- {s}\n", .{problem.string});
        try writer.writeAll("\n</details>\n\n");
    }
}

fn matches(run: Object, terrain: server_module.Terrain, kind: scenario.Kind) bool {
    return std.mem.eql(u8, text(run, &.{"terrain"}), @tagName(terrain)) and std.mem.eql(u8, text(run, &.{"scenario"}), @tagName(kind));
}

/// The last run of a combination, so a rerun replaces an earlier one.
fn latest(runs: []const Object, server: server_module.Kind, terrain: server_module.Terrain, kind: scenario.Kind, players: u64) ?Object {
    var found: ?Object = null;
    for (runs) |run| {
        if (!matches(run, terrain, kind) or !std.mem.eql(u8, text(run, &.{"server"}), @tagName(server))) continue;
        if (number(run, &.{kind.counted()}) != @as(f64, @floatFromInt(players))) continue;
        found = run;
    }
    return found;
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
        .wide => "Wide flat",
    };
}
