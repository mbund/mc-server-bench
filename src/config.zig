//! Settings every server in the bench gets alike. The bench writes them into each server's own
//! configuration, and the Lightning Rod server it builds reads them here.

const std = @import("std");

pub const port: u16 = 25700;
/// The render distance bots ask for and servers are configured with.
pub const view_distance = 8;
/// The distance around players that servers tick, the render distance, as no server ticks chunks
/// it has not loaded.
pub const simulation_distance = view_distance;
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
/// The file in Lightning Rod's directory that holds how many cows the cows scenario wants, as
/// it has no console to summon them through. Its plugin reads it once a second.
pub const cows_file = "cows";

/// Blocks between neighbouring cows in `cows`, so 8192 cover a field about 180 blocks across,
/// inside the render and simulation distance of the player in its middle, 8 chunks either way.
pub const cow_spacing = 2;

/// Where cow `index` stands: on a square spiral out from the spot of the player, leaving that spot
/// free, so any number of cows is a square field around the player and every step of a ramp adds
/// the next ones around the last. Every server gets the same field.
pub fn cowPosition(index: usize, centre: [3]f64) [3]f64 {
    const cell = spiral(@as(i64, @intCast(index)) + 2);
    return .{
        @floor(centre[0]) + 0.5 + @as(f64, @floatFromInt(cell[0])) * cow_spacing,
        centre[1],
        @floor(centre[2]) + 0.5 + @as(f64, @floatFromInt(cell[1])) * cow_spacing,
    };
}

/// The cell of the `n`th place on a square spiral counted from 1 at the middle, ring by ring.
fn spiral(n: i64) [2]i64 {
    if (n == 1) return .{ 0, 0 };
    const k: i64 = @intFromFloat(@ceil((@sqrt(@as(f64, @floatFromInt(n))) - 1) / 2));
    var side = 2 * k + 1;
    var m = side * side;
    side -= 1;
    if (n >= m - side) return .{ k - (m - n), -k };
    m -= side;
    if (n >= m - side) return .{ -k, -k + (m - n) };
    m -= side;
    if (n >= m - side) return .{ -k + (m - n), k };
    return .{ k, k - (m - n - side) };
}

test "cows fill a square spiral around the player, every place once" {
    var seen: std.AutoHashMapUnmanaged([2]i64, void) = .empty;
    defer seen.deinit(std.testing.allocator);
    try seen.put(std.testing.allocator, .{ 0, 0 }, {});
    // The first ring of 8, then the next of 16, close the squares around the player.
    for (0..8192) |index| {
        const cell = spiral(@as(i64, @intCast(index)) + 2);
        try std.testing.expect(!seen.contains(cell));
        try seen.put(std.testing.allocator, cell, {});
        if (index == 7) for (0..3) |x| for (0..3) |z| try std.testing.expect(seen.contains(.{ @as(i64, @intCast(x)) - 1, @as(i64, @intCast(z)) - 1 }));
    }
    const far = cowPosition(8191, .{ 8.3, 65, -3.7 });
    try std.testing.expect(@abs(far[0] - 8.5) <= 92 and @abs(far[2] + 3.5) <= 92);
}
