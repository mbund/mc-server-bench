//! Generates the worlds runs start from: the same square of chunks around the origin, forced
//! loaded a few tiles at a time until generation quiets. Vanilla generates the world every server
//! reading vanilla worlds starts from, and SteelMC, which reads none, the same chunks in its own.
//! With a dimension, the square is added to that dimension of the existing world.
//!
//! The worlds hold no entities: vanilla's are cleared of the animals and villagers it spawns into
//! the chunks it generates, and both servers' of the minecarts and frames their structures
//! place, as Lightning Rod, which imports vanilla's, keeps none, while Pumpkin loads them. The
//! cows scenario measures what mobs cost, the same cows on every server.
//!
//! CI keys each cached world on this file, with the settings the server generates from, so only
//! what decides how a world is generated belongs here.

const std = @import("std");
const bot = @import("bot.zig");
const config = @import("config.zig");
const process = @import("process.zig");
const server_module = @import("server.zig");

const Server = server_module.Server;

pub const Options = struct {
    kind: server_module.Kind,
    terrain: server_module.Terrain,
    /// Chunks out from the origin, the terrain's own unless given.
    radius: ?i32 = null,
    /// Another dimension to generate into the existing world, like minecraft:the_nether.
    dimension: ?[]const u8 = null,
    cpus: []const u8,
};

/// The bench repository's directory for the world generated.
pub fn generate(allocator: std.mem.Allocator, io: std.Io, root: []const u8, options: Options) ![]const u8 {
    const kind = options.kind;
    if (kind != .vanilla and kind != .steel) return error.InvalidArguments;
    if (kind == .steel and options.dimension != null) return error.InvalidArguments;
    const directory = try options.terrain.directory(allocator, @tagName(kind));
    if (options.dimension == null) std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const prefix = if (options.dimension) |name| try std.fmt.allocPrint(allocator, "execute in {s} run ", .{name}) else "";
    if (bot.probe(config.port)) return error.PortInUse;
    const server = try Server.start(allocator, io, .{
        .kind = kind,
        .root = root,
        .directory = directory,
        .players = 1,
        .cpus = options.cpus,
        .metrics = "",
        .terrain = options.terrain,
        .generating = true,
    });
    var stopped = false;
    defer if (!stopped) {
        _ = server.stop(60) catch {};
    };
    while (!bot.probe(config.port)) {
        if (server.exited.load(.acquire)) return error.ServerExited;
        try io.sleep(.fromMilliseconds(200), .awake);
    }
    // No mobs spawn on their own while it generates. Runs turn off spawning themselves.
    if (kind == .vanilla) try server.console("gamerule spawn_mobs false");
    // Forceload takes at most 256 chunks a command, so the square goes in tiles of 16 by 16.
    const tiles = @divFloor((options.radius orelse options.terrain.radius()) + 15, 16);
    // Tiles forced at once: each batch waits for generation to quiet, which the wide world would
    // otherwise spend most of its time on.
    const batch = 16;
    // Each batch is released tile by tile, which every server's forceload takes.
    var pending: [batch][2]i32 = undefined;
    var pending_count: usize = 0;
    var tile_x = -tiles;
    while (tile_x < tiles) : (tile_x += 1) {
        var tile_z = -tiles;
        while (tile_z < tiles) : (tile_z += 1) {
            const x = tile_x * 256;
            const z = tile_z * 256;
            try server.console(try std.fmt.allocPrint(allocator, "{s}forceload add {d} {d} {d} {d}", .{ prefix, x, z, x + 255, z + 255 }));
            pending[pending_count] = .{ x, z };
            pending_count += 1;
            if (pending_count == batch or (tile_x == tiles - 1 and tile_z == tiles - 1)) {
                try quiet(io, server);
                // Each chunk gets its animals as it finishes generating, here while its tile is
                // loaded, so they go before the tiles are released. A second time for what the
                // first left lying about: mobs' loot, the contents of mineshafts' chest minecarts.
                for (0..2) |_| {
                    try server.console(try std.fmt.allocPrint(allocator, "{s}kill @e[type=!minecraft:player]", .{prefix}));
                    try quiet(io, server);
                }
                for (pending[0..pending_count]) |tile| try server.console(try std.fmt.allocPrint(allocator, "{s}forceload remove {d} {d} {d} {d}", .{ prefix, tile[0], tile[1], tile[0] + 255, tile[1] + 255 }));
                pending_count = 0;
                std.log.info("generated through tile {d}, {d}", .{ tile_x, tile_z });
            }
        }
    }
    // SteelMC saves when it stops and has no save command.
    if (kind == .vanilla) try server.console("save-all flush");
    try quiet(io, server);
    const ending = try server.stop(600);
    stopped = true;
    if (!ending.clean) return error.ServerKilled;
    return directory;
}

/// Waits until the server keeps under half a core for three seconds running.
fn quiet(io: std.Io, server: *Server) !void {
    var calm: usize = 0;
    var previous = try process.sample(server.pid);
    for (0..1800) |_| {
        try io.sleep(.fromSeconds(1), .awake);
        if (server.exited.load(.acquire)) return error.ServerExited;
        const now_usage = try process.sample(server.pid);
        calm = if (now_usage.cpu_ns - previous.cpu_ns < std.time.ns_per_s / 2) calm + 1 else 0;
        previous = now_usage;
        if (calm == 3) return;
    }
    return error.GenerationNeverSettled;
}

/// What decides the world `generate` makes for a server on a terrain, which CI keys its cached
/// copy on: the square, the settings the server generates from, and this file, by its hash.
pub fn recipe(allocator: std.mem.Allocator, kind: server_module.Kind, terrain: server_module.Terrain) ![]const u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(@embedFile("pregen.zig"), &digest, .{});
    return std.fmt.allocPrint(allocator, "server={s}\nterrain={s}\nradius={d}\npregen={x}\n{s}", .{
        @tagName(kind),
        @tagName(terrain),
        terrain.radius(),
        digest,
        try server_module.worldSettings(allocator, kind, terrain),
    });
}
