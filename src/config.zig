//! Settings every server in the bench gets alike. The bench writes them into each server's own
//! configuration, and the Lightning Rod server it builds reads them here.

const std = @import("std");

pub const port: u16 = 25700;
/// The view distance bots ask for and servers are configured with, and the simulation distance.
pub const view_distance = 10;
/// Room for exactly the bots of a run, the same every server gets. Lightning Rod sets aside
/// everything for every player it has room for, so room for more would cost it what it costs the
/// others only once used.
pub fn maxPlayers(players: usize) usize {
    return players;
}
/// Where Lightning Rod keeps its world, beside its caches, relative to its directory.
pub const world = "world";
/// Where Lightning Rod exports its tick samples, a link the bench makes to memory off the disk
/// being measured.
pub const metrics = "metrics";
/// Chunks out from spawn that the real terrain world covers, as setup pregenerates it.
pub const terrain_radius = 64;

/// Blocks between neighbouring cows in `cows`, so 4096 cover a field 128 blocks across, inside
/// the view and simulation distance of the player in its middle.
pub const cow_spacing = 2;

/// Where cow `index` of `count` stands, on a square grid centred on a spot. Every server gets
/// the same field.
pub fn cowPosition(index: usize, count: usize, centre: [3]f64) [3]f64 {
    const side = std.math.sqrt(count - 1) + 1;
    const half: f64 = @floatFromInt(side / 2);
    return .{
        @floor(centre[0]) + 0.5 + (@as(f64, @floatFromInt(index % side)) - half) * cow_spacing,
        centre[1],
        @floor(centre[2]) + 0.5 + (@as(f64, @floatFromInt(index / side)) - half) * cow_spacing,
    };
}

test "cows stand on a square field around the centre" {
    const first = cowPosition(0, 4096, .{ 8.3, 65, -3.7 });
    const last = cowPosition(4095, 4096, .{ 8.3, 65, -3.7 });
    try std.testing.expectEqual([3]f64{ 8.5 - 64, 65, -3.5 - 64 }, first);
    try std.testing.expectEqual([3]f64{ 8.5 + 62, 65, -3.5 + 62 }, last);
}
