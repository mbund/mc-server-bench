//! Settings every server in the bench gets alike. The bench writes them into each server's own
//! configuration, and the Lightning Rod server it builds reads them here.

pub const port: u16 = 25700;
/// The view distance bots ask for and servers are configured with, and the simulation distance.
pub const view_distance = 10;
/// Room for the largest run. Every run gets the same, as servers size memory by it.
pub const max_players = 32;
/// Where Lightning Rod keeps its world, beside its caches, relative to its directory.
pub const world = "world";
/// Where Lightning Rod exports its tick samples, a link the bench makes to memory off the disk
/// being measured.
pub const metrics = "metrics";
