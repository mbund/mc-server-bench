//! Charts for the report: for one terrain and scenario, a panel per measure with a line per server
//! over player counts, or cow counts, on a log scale so a server using a little and one using thousands of times
//! more both read, drawn as one SVG file. Measures of different units never share a panel.

const std = @import("std");
const server_module = @import("server.zig");

const Server = server_module.Kind;

pub const Measure = struct {
    title: []const u8,
    unit: []const u8,
    path: []const []const u8,
    /// Whether the value counts only where the server reports its own tick times.
    reported: bool = false,
};

pub const measures = [_]Measure{
    .{ .title = "CPU time per tick", .unit = "ms", .path = &.{ "window", "cpu_ms_per_tick" } },
    .{ .title = "Mean tick time (mspt)", .unit = "ms", .path = &.{ "window", "mspt", "mean_ms" }, .reported = true },
    .{ .title = "Received per player", .unit = "KB/s", .path = &.{ "window", "received_kb_per_s_per_player" } },
    .{ .title = "Peak memory", .unit = "MB", .path = &.{"peak_rss_mb"} },
    .{ .title = "Action acknowledged p99", .unit = "ms", .path = &.{ "window", "action_p99_ms" } },
};

/// One server's values in a panel, one per player count, null where it has no result or a value
/// a log scale cannot show.
pub const Series = struct {
    server: Server,
    values: []const ?f64,
};

pub const Panel = struct {
    measure: Measure,
    series: []const Series,
};

/// A fixed color for every server, so a server keeps its color in every chart. Eight hues that
/// keep apart for every kind of color vision as neighbours, on light and dark pages alike. Lines
/// cross, so their names at the line ends and the legend tell them apart, never color alone.
const colors = [_][]const u8{ "#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767" };

comptime {
    if (std.enums.values(Server).len > colors.len) @compileError("every server needs a color of its own");
}

const margin = 16;
const panel_width = 480;
const panel_height = 300;
const gap = 20;
const width = 2 * margin + 2 * panel_width + gap;
const header = 64;
/// Inside a panel: room for the title above, the decade labels left, the player counts below and
/// the server names right, which fit the longest name, 16 characters of 12 pixel monospace.
const plot_left = 52;
const plot_right = 132;
const plot_top = 34;
const plot_bottom = 40;
const label_spacing = 13;

/// `axis` names what the counts count, players or cows.
pub fn svg(allocator: std.mem.Allocator, title: []const u8, axis: []const u8, counts: []const u64, panels: []const Panel) ![]u8 {
    std.debug.assert(counts.len >= 2);
    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;
    const rows = (panels.len + 1) / 2;
    const height = header + rows * (panel_height + gap);
    try begin(writer, height, title);
    try legend(writer, panels);
    for (panels, 0..) |panel, index| {
        const x: f64 = @floatFromInt(margin + (index % 2) * (panel_width + gap));
        const y: f64 = @floatFromInt(header + (index / 2) * (panel_height + gap));
        try drawPanel(allocator, writer, x, y, axis, counts, panel);
    }
    try writer.writeAll("</svg>\n");
    return output.toOwnedSlice();
}

/// Every server in any panel, in the fixed order, with its color.
fn legend(writer: *std.Io.Writer, panels: []const Panel) !void {
    var x: f64 = margin;
    for (std.enums.values(Server), 0..) |server, slot| {
        const present = found: {
            for (panels) |panel| for (panel.series) |series| if (series.server == server) break :found true;
            break :found false;
        };
        if (!present) continue;
        try writer.print("<line x1=\"{d:.1}\" y1=\"42\" x2=\"{d:.1}\" y2=\"42\" stroke=\"{s}\" stroke-width=\"2\"/><circle class=\"ring\" cx=\"{d:.1}\" cy=\"42\" r=\"4\" fill=\"{s}\" stroke-width=\"2\"/>", .{ x, x + 18, colors[slot], x + 9, colors[slot] });
        try writer.print("<text class=\"t1\" x=\"{d:.1}\" y=\"46\">{s}</text>\n", .{ x + 24, @tagName(server) });
        x += 24 + 7.2 * @as(f64, @floatFromInt(@tagName(server).len)) + 18;
    }
}

fn drawPanel(allocator: std.mem.Allocator, writer: *std.Io.Writer, x: f64, y: f64, axis: []const u8, counts: []const u64, panel: Panel) !void {
    try writer.print("<text class=\"t1 panel\" x=\"{d:.1}\" y=\"{d:.1}\">{s} ({s}, log scale)</text>\n", .{ x, y + 16, panel.measure.title, panel.measure.unit });
    const left = x + plot_left;
    const right = x + panel_width - plot_right;
    const top = y + plot_top;
    const bottom = y + panel_height - plot_bottom;

    var minimum = std.math.inf(f64);
    var maximum = -std.math.inf(f64);
    for (panel.series) |series| for (series.values) |value| if (value) |v| {
        minimum = @min(minimum, v);
        maximum = @max(maximum, v);
    };
    if (minimum > maximum) {
        try writer.print("<text class=\"t2\" x=\"{d:.1}\" y=\"{d:.1}\">No server reports this measure here.</text>\n", .{ left, (top + bottom) / 2 });
        return;
    }
    const low = @floor(std.math.log10(minimum));
    var high = @ceil(std.math.log10(maximum));
    if (high <= low) high = low + 1;
    const scale = struct {
        fn at(value: f64, l: f64, h: f64, t: f64, b: f64) f64 {
            return b - (std.math.log10(value) - l) / (h - l) * (b - t);
        }
    }.at;

    // A recessive line at every decade, labelled.
    var decade = low;
    while (decade <= high) : (decade += 1) {
        const at = scale(std.math.pow(f64, 10, decade), low, high, top, bottom);
        try writer.print("<line class=\"grid\" x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke-width=\"1\"/>", .{ left, at, right, at });
        var label: [16]u8 = undefined;
        try writer.print("<text class=\"t2\" x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"end\">{s}</text>\n", .{ left - 6, at + 4, decadeLabel(&label, @intFromFloat(decade)) });
    }
    try writer.print("<line class=\"axis\" x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke-width=\"1\"/>\n", .{ left, bottom, right, bottom });
    var shown: [64]bool = undefined;
    for (counts, 0..) |players, index| {
        if (!countsShown(counts, left, right, &shown)[index]) continue;
        try writer.print("<text class=\"t2\" x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\">{d}</text>\n", .{ column(index, counts.len, left, right), bottom + 16, players });
    }
    try writer.print("<text class=\"t2\" x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\">{s}</text>\n", .{ (left + right) / 2, bottom + 32, axis });

    // Lines join consecutive results, leaving a gap where one is missing.
    for (panel.series) |series| {
        const color = colors[@intFromEnum(series.server)];
        var previous: ?[2]f64 = null;
        for (series.values, 0..) |value, index| {
            const point: ?[2]f64 = if (value) |v| .{ column(index, counts.len, left, right), scale(v, low, high, top, bottom) } else null;
            if (previous != null and point != null) try writer.print("<line x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke=\"{s}\" stroke-width=\"2\" stroke-linecap=\"round\"/>", .{ previous.?[0], previous.?[1], point.?[0], point.?[1], color });
            previous = point;
        }
    }
    for (panel.series) |series| {
        const color = colors[@intFromEnum(series.server)];
        for (series.values, 0..) |value, index| if (value) |v| {
            try writer.print("<circle class=\"ring\" cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"4\" fill=\"{s}\" stroke-width=\"2\"><title>{s}, {d} {s}: {d:.2} {s}</title></circle>", .{ column(index, counts.len, left, right), scale(v, low, high, top, bottom), color, @tagName(series.server), counts[index], axis, v, panel.measure.unit });
        };
    }
    try writer.writeByte('\n');

    // Each server's name beside its last result, moved apart where names would overlap.
    const Label = struct { server: Server, x: f64, y: f64 };
    var labels: std.ArrayList(Label) = .empty;
    for (panel.series) |series| {
        var index = series.values.len;
        while (index > 0) : (index -= 1) if (series.values[index - 1]) |v| {
            try labels.append(allocator, .{ .server = series.server, .x = column(index - 1, counts.len, left, right) + 8, .y = scale(v, low, high, top, bottom) + 4 });
            break;
        };
    }
    std.mem.sort(Label, labels.items, {}, struct {
        fn less(_: void, a: Label, b: Label) bool {
            return a.y < b.y;
        }
    }.less);
    // Each name in turn, from the top, moves down past every name placed before it that it would
    // overlap, or up where that would take it below the plot, and never above the plot.
    for (labels.items, 0..) |*label, index| {
        const placed = labels.items[0..index];
        const wanted = label.y;
        label.y = clear(placed, label.*, wanted, label_spacing);
        if (label.y > bottom + 4) label.y = clear(placed, label.*, wanted, -label_spacing);
        label.y = std.math.clamp(label.y, top + 4, bottom + 4);
    }
    for (labels.items) |label| {
        try writer.print("<text class=\"t1\" x=\"{d:.1}\" y=\"{d:.1}\">{s}</text>\n", .{ label.x, label.y, @tagName(label.server) });
    }
}

/// Where a name nearest `wanted` stops overlapping every name placed, moving a line at a time
/// down for a positive step or up for a negative one. Names overlap where their text would.
fn clear(placed: anytype, label: anytype, wanted: f64, step: f64) f64 {
    // A height that is not finite never stops overlapping, and would move forever.
    std.debug.assert(std.math.isFinite(wanted) and step != 0);
    var y = wanted;
    var moved = true;
    while (moved) {
        moved = false;
        for (placed) |other| {
            const apart_x = label.x >= other.x + nameWidth(other.server) or other.x >= label.x + nameWidth(label.server);
            if (apart_x or @abs(other.y - y) >= @abs(step)) continue;
            // A name a step from another can measure a hair under a step apart, which moves it
            // to where it already is. That is no move, or it would loop forever.
            const next = other.y + step;
            if (next == y) continue;
            y = next;
            moved = true;
        }
    }
    return y;
}

fn nameWidth(server: Server) f64 {
    return @as(f64, @floatFromInt(@tagName(server).len)) * digit_width + 4;
}

/// Width of one character of 12 pixel monospace, and the space kept between two count labels.
const digit_width = 7.2;
const label_gap = 6;

/// Which counts below a panel are labelled: each that fits beside the last one labelled, and the
/// last count always, dropping the one before it where they would touch. A ramp of fifteen
/// steps leaves less room than three digits take, and every point still names its count.
fn countsShown(counts: []const u64, left: f64, right: f64, shown: []bool) []const bool {
    std.debug.assert(counts.len <= shown.len);
    const result = shown[0..counts.len];
    @memset(result, false);
    var kept: ?usize = null;
    for (counts, 0..) |count, index| {
        const half = digits(count) * digit_width / 2;
        const at = column(index, counts.len, left, right);
        if (kept) |before| {
            const edge = column(before, counts.len, left, right) + digits(counts[before]) * digit_width / 2 + label_gap;
            if (at - half < edge) {
                if (index != counts.len - 1) continue;
                result[before] = false;
            }
        }
        result[index] = true;
        kept = index;
    }
    return result;
}

fn digits(count: u64) f64 {
    var value = count;
    var length: f64 = 1;
    while (value >= 10) : (value /= 10) length += 1;
    return length;
}

test "count labels never touch, and the first and last are always shown" {
    const ramp = [_]u64{ 1, 2, 4, 8, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512 };
    var shown: [64]bool = undefined;
    const result = countsShown(&ramp, 0, 296, &shown);
    try std.testing.expect(result[0] and result[ramp.len - 1]);
    var previous: ?usize = null;
    for (result, 0..) |label, index| {
        if (!label) continue;
        if (previous) |before| {
            const gap_between = column(index, ramp.len, 0, 296) - column(before, ramp.len, 0, 296);
            try std.testing.expect(gap_between >= (digits(ramp[index]) + digits(ramp[before])) * digit_width / 2 + label_gap);
        }
        previous = index;
    }
    // Two counts far apart both show.
    try std.testing.expect(countsShown(&.{ 16, 4096 }, 0, 296, &shown)[0]);
}

fn column(index: usize, count: usize, left: f64, right: f64) f64 {
    return left + (right - left) * @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(count - 1));
}

/// 0.01, 0.1, 1, 10, 100, 1000, 10k, 100k, 1M and so on.
fn decadeLabel(buffer: []u8, decade: i32) []const u8 {
    if (decade < 0) {
        var at: usize = 0;
        buffer[0] = '0';
        buffer[1] = '.';
        at = 2;
        for (0..@intCast(-decade - 1)) |_| {
            buffer[at] = '0';
            at += 1;
        }
        buffer[at] = '1';
        return buffer[0 .. at + 1];
    }
    const suffixes = [_][]const u8{ "", "k", "M", "G" };
    const group: usize = @min(@as(usize, @intCast(decade)) / 3, suffixes.len - 1);
    const zeros = @as(usize, @intCast(decade)) - group * 3;
    buffer[0] = '1';
    for (0..zeros) |at| buffer[1 + at] = '0';
    @memcpy(buffer[1 + zeros ..][0..suffixes[group].len], suffixes[group]);
    return buffer[0 .. 1 + zeros + suffixes[group].len];
}

test "decades label as numbers" {
    var buffer: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0.01", decadeLabel(&buffer, -2));
    try std.testing.expectEqualStrings("1", decadeLabel(&buffer, 0));
    try std.testing.expectEqualStrings("100", decadeLabel(&buffer, 2));
    try std.testing.expectEqualStrings("10k", decadeLabel(&buffer, 4));
    try std.testing.expectEqualStrings("1M", decadeLabel(&buffer, 6));
}

/// The SVG element with the styles every chart shares, its background and its title.
fn begin(writer: *std.Io.Writer, height: usize, title: []const u8) !void {
    try writer.print(
        \\<svg xmlns="http://www.w3.org/2000/svg" width="{d}" height="{d}" viewBox="0 0 {d} {d}">
        \\<style>
        \\.bg{{fill:#ffffff}} .grid{{stroke:#d1d9e0}} .axis{{stroke:#818b98}} .t1{{fill:#1f2328}} .t2{{fill:#59636e}} .ring{{stroke:#ffffff}}
        \\@media (prefers-color-scheme: dark){{.bg{{fill:#0d1117}} .grid{{stroke:#2f353d}} .axis{{stroke:#656c76}} .t1{{fill:#f0f6fc}} .t2{{fill:#9198a1}} .ring{{stroke:#0d1117}}}}
        \\text{{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,"Liberation Mono",monospace;font-size:12px}}
        \\.title{{font-size:16px;font-weight:600}} .panel{{font-size:13px;font-weight:600}}
        \\</style>
        \\<rect class="bg" width="100%" height="100%"/>
        \\<text class="t1 title" x="{d}" y="24">{s}</text>
        \\
    , .{ width, height, width, height, margin, title });
}

/// One server's value on each terrain, null where it has none.
pub const Row = struct {
    server: Server,
    values: [terrains.len]?f64,
};

pub const DotPanel = struct {
    title: []const u8,
    unit: []const u8,
    rows: []const Row,
};

/// The terrains a dot chart sets side by side, each its own color and shape so neither is told
/// by color alone: flat as a circle, real as a square.
pub const terrains = [_][]const u8{ "flat", "real" };
const terrain_colors = [_][]const u8{ "#3987e5", "#d95926" };

/// Each server's row, with a lane for each terrain so a mark never hides the other.
const row_height = 28;
const lane_offset = 5;
const name_width = 136;

/// A row per server and a dot per terrain on a log scale, for a measure of the server itself
/// rather than of how it grows, like how long it takes to start. Panels sit side by side.
pub fn dots(allocator: std.mem.Allocator, title: []const u8, panels: []const DotPanel) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;
    var rows: usize = 0;
    for (panels) |panel| rows = @max(rows, panel.rows.len);
    const panel_rows = (panels.len + 1) / 2;
    const block = plot_top + rows * row_height + plot_bottom;
    try begin(writer, header + panel_rows * (block + gap), title);
    var x: f64 = margin;
    for (terrains, terrain_colors, 0..) |name, color, index| {
        try marker(writer, index, x + 6, 42, color);
        try writer.print("<text class=\"t1\" x=\"{d:.1}\" y=\"46\">{s} terrain</text>\n", .{ x + 16, name });
        x += 16 + 7.2 * @as(f64, @floatFromInt(name.len + 8)) + 18;
    }
    for (panels, 0..) |panel, index| {
        const left: f64 = @floatFromInt(margin + (index % 2) * (panel_width + gap));
        const top: f64 = @floatFromInt(header + (index / 2) * (block + gap));
        try dotPanel(writer, left, top, panel);
    }
    try writer.writeAll("</svg>\n");
    return output.toOwnedSlice();
}

fn dotPanel(writer: *std.Io.Writer, x: f64, y: f64, panel: DotPanel) !void {
    try writer.print("<text class=\"t1 panel\" x=\"{d:.1}\" y=\"{d:.1}\">{s} ({s}, log scale)</text>\n", .{ x, y + 16, panel.title, panel.unit });
    const left = x + name_width;
    const right = x + panel_width - 24;
    const top = y + plot_top;
    const bottom = top + @as(f64, @floatFromInt(panel.rows.len * row_height));
    var minimum = std.math.inf(f64);
    var maximum = -std.math.inf(f64);
    for (panel.rows) |row| for (row.values) |value| if (value) |v| {
        minimum = @min(minimum, v);
        maximum = @max(maximum, v);
    };
    if (minimum > maximum) return;
    const low = @floor(std.math.log10(minimum));
    var high = @ceil(std.math.log10(maximum));
    if (high <= low) high = low + 1;
    const scale = struct {
        fn at(value: f64, l: f64, h: f64, a: f64, b: f64) f64 {
            return a + (std.math.log10(value) - l) / (h - l) * (b - a);
        }
    }.at;
    // A recessive line at every decade, labelled below.
    var decade = low;
    while (decade <= high) : (decade += 1) {
        const at = scale(std.math.pow(f64, 10, decade), low, high, left, right);
        var label: [16]u8 = undefined;
        try writer.print("<line class=\"grid\" x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke-width=\"1\"/><text class=\"t2\" x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\">{s}</text>\n", .{ at, top, at, bottom, at, bottom + 16, decadeLabel(&label, @intFromFloat(decade)) });
    }
    for (panel.rows, 0..) |row, index| {
        const middle = top + (@as(f64, @floatFromInt(index)) + 0.5) * row_height;
        try writer.print("<text class=\"t1\" x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"end\">{s}</text>", .{ left - 10, middle + 4, @tagName(row.server) });
        try writer.print("<line class=\"grid\" x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" stroke-width=\"1\" stroke-dasharray=\"2 3\"/>", .{ left, middle, right, middle });
        for (row.values, terrain_colors, 0..) |value, color, terrain| if (value) |v| {
            try writer.print("<g><title>{s}, {s} terrain: {d:.2} {s}</title>", .{ @tagName(row.server), terrains[terrain], v, panel.unit });
            const lane = middle + (@as(f64, @floatFromInt(terrain)) - 0.5) * 2 * lane_offset;
            try marker(writer, terrain, scale(v, low, high, left, right), lane, color);
            try writer.writeAll("</g>");
        };
        try writer.writeByte('\n');
    }
}

/// A circle for the first terrain and a square for the second, ringed in the background color.
fn marker(writer: *std.Io.Writer, shape: usize, x: f64, y: f64, color: []const u8) !void {
    if (shape == 0) {
        try writer.print("<circle class=\"ring\" cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"5\" fill=\"{s}\" stroke-width=\"2\"/>", .{ x, y, color });
    } else {
        try writer.print("<rect class=\"ring\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"10\" height=\"10\" fill=\"{s}\" stroke-width=\"2\"/>", .{ x - 5, y - 5, color });
    }
}

test "a name exactly a step below another settles there" {
    const Placed = struct { server: Server, x: f64, y: f64 };
    // As a report met them: the label a step below vanilla measures 12.9999 from it.
    const placed = [_]Placed{
        .{ .server = .@"paper-antifreecam", .x = 224, .y = 462.39046183929696 },
        .{ .server = .pumpkin, .x = 298, .y = 481.7895210772604 },
        .{ .server = .@"fabric-optimized", .x = 298, .y = 494.7895210772604 },
        .{ .server = .vanilla, .x = 298, .y = 507.7895210772604 },
    };
    const label: Placed = .{ .server = .steel, .x = 298, .y = 482.49453581814566 };
    try std.testing.expectEqual(@as(f64, 507.7895210772604 + 13), clear(&placed, label, label.y, 13));
}
