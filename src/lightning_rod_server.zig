//! Lightning Rod as a server outside its repository uses it: the vanilla plugins, configured in
//! code with the settings every server in the bench gets.

const std = @import("std");
const lightning_rod = @import("lightning_rod");
const profile = @import("profile");
const protocol_set = @import("protocols");
const sessions = @import("sessions");
const vanilla = @import("lightning_rod_vanilla_1_21_6");
const Chunks = @import("chunks").Chunks;
const Players = @import("players").players.Players;
const Streaming = @import("terrain").streaming.Streaming;
const connection_plugins = @import("connection").plugins;
const config = @import("config.zig");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const startup = profile.Startup.capture(init.io);
    var memory = lightning_rod.Memory.init(lightning_rod.system.huge_page_allocator, init.io);
    defer memory.deinit();
    const allocator = memory.allocator("bootstrap");
    // The bench passes the room it gives every server for the run.
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 2) return error.MissingMaxPlayers;
    const max_players = try std.fmt.parseInt(usize, arguments[1], 10);

    const gameplay = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            // Visibility culling and one column past the view, the ring vanilla sends so every
            // column in view has its neighbours.
            lightning_rod.plugin.configured(Streaming, .{ .prefetch = 1, .hull = true }),
            lightning_rod.plugin.configured(Players, Players.Configuration{ .maximum = max_players, .render_distance = config.view_distance, .simulation_distance = config.view_distance }),
            lightning_rod.plugin.configured(Chunks, Chunks.Configuration.forPlayers(max_players)),
        }),
    });
    var protocols = try protocol_set.Default.init(allocator);
    defer protocols.deinit(allocator);
    const network = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocol_set.Handshake, protocol_set.Handshake.Configuration{}),
        connection_plugins(&protocols),
    });
    try profile.Server(@TypeOf(gameplay), protocol_set.Endpoint, @TypeOf(network), sessions.SingleSimulation).run(&memory, init, .{
        .plugins = gameplay,
        .network = .{
            .plugins = network,
            .protocols = &protocols,
            .router = .{},
            .max_players = max_players,
            .codec_workers = 4,
            .input_burst_slots = 2,
            .output_burst_slots = 8,
            .decode_slots = 2,
            .endpoints = &.{.{ .id = 0, .connections = max_players }},
            // Vanilla's default threshold.
            .compression_threshold = 256,
            .address = .{ .ip4 = .{ .bytes = .{ 0, 0, 0, 0 }, .port = config.port } },
        },
        .metrics_export = .{ .directory = config.metrics },
        .startup = startup,
        .storage_path = config.world,
    }, .{});
}
