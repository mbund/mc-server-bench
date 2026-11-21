//! Settings every server in the bench gets alike. The bench writes them into each server's own
//! configuration, and the Lightning Rod server it builds reads them here.

const std = @import("std");

pub const port: u16 = 25700;
/// Where the bench answers for Mojang's session server, which the servers built on vanilla ask
/// who joining players are.
pub const session_port: u16 = port + 1;
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
/// The file in Lightning Rod's directory the bench appends a line to for each player to move, a
/// name and where, as it has no console for /tp. Its plugin reads it a few times a second.
pub const teleports_file = "teleports";
/// The files the bench and Lightning Rod's warp plugin talk through, in the server's directory:
/// a request to build the farm and the plugin's answer once it stands, then a request to run
/// some ticks back to back and the answer once they ran, holding how many.
pub const farm_file = "farm";
pub const farm_built_file = "farm.built";
pub const warp_file = "warp";
pub const warped_file = "warped";

/// What makes a step of players too many. A step that breaks one ends the run, recorded with the
/// limit it broke, so the step before it is the most the server held. The report's charts draw
/// them.
pub const limits = struct {
    /// The server falling behind, from the world time the bots receive.
    pub const tps = 19.0;
    /// The longest a tick may take and keep up with 20 ticks a second.
    pub const mspt = 50.0;
    /// The server acknowledging a player's action late: five ticks, its ticks or what it still has
    /// to send that far behind.
    pub const action_p99_ms = 250.0;
    /// The bots' own CPUs this busy, past which they may read what the server sent late enough to
    /// break the other limits themselves. A step that reaches it measured the bots rather than the
    /// server, so it ends the run as inconclusive rather than as the server's limit.
    pub const bot_cpu = 0.70;
};

/// The share of the machine's memory a Java server's heap may grow to.
pub const java_heap_share = 0.75;

/// Blocks between neighbouring cows in `cows`: a cow's width, so neighbours stand touching and
/// every step one takes pushes another, which tests collisions as well as ticking and sending.
/// 8192 then cover a field about 82 blocks across, every cow within 96 blocks of the player in
/// its middle: inside the render and simulation distance, 8 chunks either way, and inside the 96
/// blocks Paper sends animals out to by default, short of vanilla's.
pub const cow_spacing = 0.9;

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

/// Where bot `index` stays in scenarios that give everyone a spot of their own above spawn: the
/// same square spiral out from `centre`, `spacing` blocks apart, so no two players stand inside
/// each other, which servers that push players apart would do every tick for bots that never move
/// away as a client would.
pub fn spotPosition(index: usize, centre: [3]f64, spacing: f64) [3]f64 {
    const cell = spiral(@as(i64, @intCast(index)) + 1);
    return .{
        @floor(centre[0]) + 0.5 + @as(f64, @floatFromInt(cell[0])) * spacing,
        centre[1],
        @floor(centre[2]) + 0.5 + @as(f64, @floatFromInt(cell[1])) * spacing,
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
    // Every cow of the largest field within 96 blocks of the player.
    for (0..8192) |index| {
        const at = cowPosition(index, .{ 8.3, 65, -3.7 });
        const dx = at[0] - 8.3;
        const dz = at[2] + 3.7;
        try std.testing.expect(dx * dx + dz * dz <= 96 * 96);
    }
}
