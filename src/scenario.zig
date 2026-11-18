//! What bots do each tick. Every scenario is deterministic per bot, so two runs ask the same of
//! every server.

const std = @import("std");
const Bot = @import("bot.zig").Bot;
const bot_module = @import("bot.zig");

const config = @import("config.zig");

/// The view distance bots ask for and servers are configured with.
pub const view_distance = config.view_distance;
/// Blocks per tick of creative flight and walking.
const flight_speed = 1.0;
const walk_speed = 0.215;
const travel_speed = 0.5;
/// The height flying bots climb to before moving across, above every peak vanilla generates,
/// so no terrain is in their way.
const cruise_altitude = 300;
/// Blocks between neighbouring spots in `spread`: wider than a view, so views do not overlap.
const spread_spacing = 2 * (view_distance + 1) * 16;
/// How far wandering bots stray from spawn.
const wander_radius = 24;
/// Blocks between the spots of building bots.
const build_spacing = 4;
/// Blocks between the spots idle and wandering bots start from.
const spot_spacing = 2;
const golden_angle = std.math.pi * (3 - @sqrt(5.0));

pub const Kind = enum {
    /// Everyone hovers still above spawn, at a spot of their own.
    idle,
    /// Everyone moves at walking speed at random near spawn, in sight of the others, in flight so
    /// no terrain is in their way, from a spot of their own.
    wander,
    /// Everyone flies to a spot of their own, far from the others, and stays there.
    spread,
    /// Everyone flies back and forth across the pregenerated flat world, never stopping.
    explore,
    /// Everyone places and breaks blocks at a spot of their own near spawn.
    build,
    /// One player stands at spawn among cows the server summons on a square field around them.
    cows,

    /// What a run's count counts.
    pub fn counted(kind: Kind) []const u8 {
        return if (kind == .cows) "cows" else "players";
    }

    /// Whether bots must reach a place before measuring starts.
    pub fn travels(kind: Kind) bool {
        return kind != .explore and kind != .cows;
    }

    pub fn description(kind: Kind) []const u8 {
        return switch (kind) {
            .idle => "Everyone flies up above spawn to a spot of their own, two blocks from the next, and hovers there.",
            .wander => "Everyone flies up above spawn to a spot of their own, then at walking speed at random within 24 blocks of spawn, in sight of each other.",
            .spread => "Everyone flies to a spot of their own, far enough apart that views never overlap, and hovers there.",
            .explore => "Everyone flies back and forth across the pregenerated world at 20 blocks a second, so servers load and send terrain from disk.",
            .build => "Everyone places or breaks a block every tick at a spot of their own near spawn.",
            .cows => "One player stands at spawn while cows are summoned touching on a square spiral around them, more each step, all in view and ticking.",
        };
    }
};

/// The chunks a player renders around one spot: those vanilla's ChunkTrackingView.isWithinDistance
/// counts within the render distance, each axis a chunk short, 257 at a distance of 8. Vanilla
/// sends a ring more, so the client can draw the edge, which this leaves out.
pub fn viewChunks() u64 {
    return view_chunks;
}

const view_chunks: u64 = count: {
    @setEvalBranchQuota(10_000);
    var count: u64 = 0;
    const reach: i64 = view_distance + 1;
    var x: i64 = -reach;
    while (x <= reach) : (x += 1) {
        var z: i64 = -reach;
        while (z <= reach) : (z += 1) {
            const dx: i64 = @max(0, (if (x < 0) -x else x) - 1);
            const dz: i64 = @max(0, (if (z < 0) -z else z) - 1);
            if (dx * dx + dz * dz < view_distance * view_distance) count += 1;
        }
    }
    break :count count;
};

test "a full view is the chunks vanilla tracks" {
    if (view_distance == 8) try std.testing.expectEqual(@as(u64, 257), viewChunks());
}

pub fn step(kind: Kind, bot: *Bot, count: usize) !void {
    switch (kind) {
        .idle => try idle(bot),
        .cows => try still(bot),
        .wander => try wander(bot),
        .spread => try spread(bot, count),
        .explore => try explore(bot),
        .build => try build(bot, count),
    }
    try bot.endTick();
}

/// A vanilla client that does not move still reports its position once a second.
fn still(bot: *Bot) !void {
    if ((bot.ticks + bot.index) % 20 == 0) try bot.move(false);
}

/// The bot's own spot above spawn, where idle bots hover and wandering bots set out from.
fn spot(bot: *const Bot) [3]f64 {
    var at = config.spotPosition(bot.index, bot.home(), spot_spacing);
    at[1] = cruise_altitude;
    return at;
}

fn idle(bot: *Bot) !void {
    if (!try rise(bot)) return;
    if (try travel(bot, spot(bot), travel_speed)) try still(bot);
}

fn wander(bot: *Bot) !void {
    if (!try rise(bot)) return;
    if (bot.counters.get(.arrived_ns) == 0) {
        _ = try travel(bot, spot(bot), travel_speed);
        return;
    }
    const random = bot.random.random();
    if (bot.ticks % 40 == 0) bot.heading = random.float(f64) * std.math.tau;
    const dx = bot.position[0] - bot.home()[0];
    const dz = bot.position[2] - bot.home()[2];
    // Past the edge, head back toward spawn.
    if (dx * dx + dz * dz > wander_radius * wander_radius) bot.heading = std.math.atan2(-dz, -dx);
    bot.position[0] += @cos(bot.heading) * walk_speed;
    bot.position[2] += @sin(bot.heading) * walk_speed;
    bot.yaw = yawOf(bot.heading);
    try bot.move(true);
}

/// The bot's own spot in `spread`: a sunflower layout, which keeps neighbours about the spacing
/// apart however many bots there are.
pub fn spreadTarget(bot: *const Bot) [3]f64 {
    const index: f64 = @floatFromInt(bot.index + 1);
    const radius = @as(f64, spread_spacing) / @sqrt(std.math.pi) * @sqrt(index);
    const angle = index * golden_angle;
    return .{ bot.home()[0] + @cos(angle) * radius, cruise_altitude, bot.home()[2] + @sin(angle) * radius };
}

fn spread(bot: *Bot, count: usize) !void {
    _ = count;
    if (!try rise(bot)) return;
    const target = spreadTarget(bot);
    if (try travel(bot, target, flight_speed)) {
        // Hovering in place, as a still client does.
        if ((bot.ticks + bot.index) % 20 == 0) try bot.move(false);
    }
}

/// Blocks from spawn where an exploring bot turns back, so its view stays inside the flat world
/// every server pregenerated.
const explore_reach: f64 = @floatFromInt((@import("server.zig").Terrain.flat.radius() - view_distance - 1) * 16);

/// Back and forth along a line of its own through spawn, turning where its view would leave the
/// pregenerated world, so every chunk it reaches is on disk and none is generated.
fn explore(bot: *Bot) !void {
    if (!try rise(bot)) return;
    // The heading is 0 flying out along the bot's line and pi flying back.
    var angle = @as(f64, @floatFromInt(bot.index + 1)) * golden_angle + bot.heading;
    const dx = bot.position[0] - bot.home()[0];
    const dz = bot.position[2] - bot.home()[2];
    if (dx * dx + dz * dz >= explore_reach * explore_reach and dx * @cos(angle) + dz * @sin(angle) > 0) {
        bot.heading = if (bot.heading == 0) std.math.pi else 0;
        angle += std.math.pi;
    }
    bot.position[0] += @cos(angle) * flight_speed;
    bot.position[2] += @sin(angle) * flight_speed;
    bot.yaw = yawOf(angle);
    try bot.move(true);
}

/// The bot's own spot in `build`, on a square grid around spawn.
pub fn buildTarget(bot: *const Bot, count: usize) [3]f64 {
    const side = std.math.sqrt(count) + 1;
    const column: f64 = @floatFromInt(bot.index % side);
    const row: f64 = @floatFromInt(bot.index / side);
    const half: f64 = @floatFromInt(side / 2);
    // Laid out from the spawn every bot shares, at the height of the ground the bot stands on.
    return .{
        @floor(bot.home()[0]) + 0.5 + (column - half) * build_spacing,
        bot.origin[1],
        @floor(bot.home()[2]) + 0.5 + (row - half) * build_spacing,
    };
}

fn build(bot: *Bot, count: usize) !void {
    const target = buildTarget(bot, count);
    if (!try travel(bot, target, travel_speed)) return;
    try bot.stock(bot_module.item_stone);
    // The block east of the bot, standing on the ground it stands on.
    const at: [3]i32 = .{ @as(i32, @intFromFloat(@floor(target[0]))) + 1, @intFromFloat(@floor(target[1])), @intFromFloat(@floor(target[2])) };
    if (bot.ticks % 2 == 0) {
        try bot.place(.{ at[0], at[1] - 1, at[2] });
    } else {
        try bot.dig(at);
    }
    if ((bot.ticks + bot.index) % 20 == 0) try bot.move(false);
}

/// Moves toward a target at a speed and reports whether the bot is there. The first arrival
/// marks the bot arrived.
fn travel(bot: *Bot, target: [3]f64, speed: f64) !bool {
    var offset: [3]f64 = undefined;
    var distance: f64 = 0;
    for (&offset, bot.position, target) |*axis, from, to| {
        axis.* = to - from;
        distance += axis.* * axis.*;
    }
    distance = @sqrt(distance);
    if (distance < 1e-6) {
        bot.counters.mark(.arrived_ns, bot_module.now());
        return true;
    }
    const fraction = @min(1, speed / distance);
    for (&bot.position, offset) |*axis, delta| axis.* += delta * fraction;
    bot.yaw = yawOf(std.math.atan2(offset[2], offset[0]));
    try bot.move(true);
    return false;
}

/// Minecraft's yaw for a heading in the horizontal plane: zero faces +z, ninety faces -x.
fn yawOf(heading: f64) f32 {
    return @floatCast(std.math.radiansToDegrees(heading) - 90);
}

/// Starts flight and climbs straight up to the cruise altitude, reporting whether the bot is
/// there.
fn rise(bot: *Bot) !bool {
    try bot.fly();
    if (bot.position[1] >= cruise_altitude) return true;
    bot.position[1] = @min(cruise_altitude, bot.position[1] + flight_speed);
    try bot.move(false);
    return false;
}
