//! What bots do each tick. Every scenario is deterministic per bot, so two runs ask the same of
//! every server.

const std = @import("std");
const Bot = @import("bot.zig").Bot;
const bot_module = @import("bot.zig");

/// The view distance bots ask for and servers are configured with.
pub const view_distance = 10;
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
const golden_angle = std.math.pi * (3 - @sqrt(5.0));

pub const Kind = enum {
    /// Everyone stands still at spawn.
    idle,
    /// Everyone moves at walking speed at random near spawn, in sight of the others, in flight so
    /// no terrain is in their way.
    wander,
    /// Everyone flies to a spot of their own, far from the others, and stays there.
    spread,
    /// Everyone flies outward without stopping, into terrain never generated before.
    explore,
    /// Everyone places and breaks blocks at a spot of their own near spawn.
    build,

    /// Whether bots must reach a place before measuring starts.
    pub fn travels(kind: Kind) bool {
        return kind == .spread or kind == .build;
    }
};

/// The chunks of a full view around one spot, at least: a vanilla view is the circle of chunks
/// within the view distance, about 3.1 times its square.
pub fn viewChunks() u64 {
    return 3 * view_distance * view_distance;
}

pub fn step(kind: Kind, bot: *Bot, count: usize) !void {
    switch (kind) {
        .idle => {
            // A vanilla client that does not move still reports its position once a second.
            if ((bot.ticks + bot.index) % 20 == 0) try bot.move(false);
        },
        .wander => try wander(bot),
        .spread => try spread(bot, count),
        .explore => try explore(bot),
        .build => try build(bot, count),
    }
    try bot.endTick();
}

fn wander(bot: *Bot) !void {
    if (!try rise(bot)) return;
    const random = bot.random.random();
    if (bot.ticks % 40 == 0) bot.heading = random.float(f64) * std.math.tau;
    const dx = bot.position[0] - bot.origin[0];
    const dz = bot.position[2] - bot.origin[2];
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
    return .{ bot.origin[0] + @cos(angle) * radius, cruise_altitude, bot.origin[2] + @sin(angle) * radius };
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

fn explore(bot: *Bot) !void {
    if (!try rise(bot)) return;
    const angle = @as(f64, @floatFromInt(bot.index + 1)) * golden_angle;
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
    return .{
        @floor(bot.origin[0]) + 0.5 + (column - half) * build_spacing,
        bot.origin[1],
        @floor(bot.origin[2]) + 0.5 + (row - half) * build_spacing,
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
