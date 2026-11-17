//! Settings every server in the bench gets alike. The bench writes them into each server's own
//! configuration, and the Lightning Rod server it builds reads them here.

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
