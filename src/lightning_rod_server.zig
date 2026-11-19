//! Lightning Rod as a server outside its repository uses it: the vanilla plugins, configured in
//! code with the settings every server in the bench gets.

const std = @import("std");
const lightning_rod = @import("lightning_rod");
const profile = @import("profile");
const protocol_set = @import("protocols");
const sessions = @import("sessions");
const vanilla = @import("lightning_rod_vanilla_1_21_6");
const chunks = @import("chunks");
const Chunks = chunks.Chunks;
const Domains = @import("domains").domains.Domains;
const farm = @import("farm.zig");
const Players = @import("players").players.Players;
const Streaming = @import("terrain").streaming.Streaming;
const connection_plugins = @import("connection").plugins;
const LoginEncryption = @import("connection").session_encryption.LoginEncryption;
const java = @import("minecraft_java");
const config = @import("config.zig");

pub const std_options: std.Options = .{ .log_level = .info };

pub fn main(init: std.process.Init) !void {
    const startup = profile.Startup.capture(init.io);
    var memory = lightning_rod.Memory.init(lightning_rod.system.huge_page_allocator, init.io);
    defer memory.deinit();
    const allocator = memory.allocator("bootstrap");
    // The bench passes the room it gives every server for the run, room for the most cows it
    // spawns, and whether sessions are encrypted.
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 4) return error.MissingArguments;
    const max_players = try std.fmt.parseInt(usize, arguments[1], 10);
    const cows = try std.fmt.parseInt(usize, arguments[2], 10);
    const encrypted = std.mem.eql(u8, arguments[3], "encrypted");
    if (!encrypted and !std.mem.eql(u8, arguments[3], "plain")) return error.InvalidArguments;

    const gameplay = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.replace(vanilla.plugins(), .{
            // Visibility culling and one column past the view, the ring vanilla sends so every
            // column in view has its neighbours.
            lightning_rod.plugin.configured(Streaming, .{ .prefetch = 1, .hull = true }),
            lightning_rod.plugin.configured(Players, Players.Configuration{ .maximum = max_players, .render_distance = config.view_distance, .simulation_distance = config.simulation_distance }),
            lightning_rod.plugin.configured(Chunks, Chunks.Configuration.forPlayers(max_players)),
            lightning_rod.plugin.configured(vanilla.Mobs, vanilla.Mobs.Configuration{ .maximum = @max(1024, cows) }),
        }),
        lightning_rod.plugin.configured(Cows, Cows.Configuration{}),
        lightning_rod.plugin.configured(Teleports, Teleports.Configuration{}),
        lightning_rod.plugin.configured(lightning_rod.TickRate, lightning_rod.TickRate.Configuration{}),
        lightning_rod.plugin.configured(Farm, Farm.Configuration{}),
    });
    var protocols = try protocol_set.Default.init(allocator);
    defer protocols.deinit(allocator);
    // Sessions are encrypted, as on any server open to the internet, without asking Mojang who
    // players are, unless the bench turns encryption off to measure everything else.
    var key = try java.RsaPrivateKey.init(@import("encryption_key").der);
    defer key.deinit();
    const network = lightning_rod.plugin.compose(.{
        lightning_rod.plugin.configured(protocol_set.Handshake, protocol_set.Handshake.Configuration{}),
        lightning_rod.plugin.replace(connection_plugins(&protocols), .{
            lightning_rod.plugin.configured(LoginEncryption, LoginEncryption.Configuration{ .key = if (encrypted) &key else null }),
        }),
    });
    try profile.Server(@TypeOf(gameplay), protocol_set.Endpoint, @TypeOf(network), sessions.SingleSimulation).run(&memory, init, .{
        .plugins = gameplay,
        .network = .{
            .plugins = network,
            .protocols = &protocols,
            .router = .{},
            .max_players = max_players,
            .input_burst_slots = 2,
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

/// Builds the warp scenario's farm and runs its ticks back to back, as the commands and /tick
/// sprint do on the servers with a console: once the bench writes the farm file, it forces the
/// farm's columns to tick, places the same blocks the fills do and the same cows, and writes
/// that it is built; once the bench writes the warp file, it sprints that many ticks and writes
/// how many ran.
const Farm = struct {
    pub const id = "mc_server_bench:farm";
    pub const Configuration = struct {};
    pub const Dependencies = struct { chunks: *Chunks, mobs: *vanilla.Mobs, domains: *Domains, worlds: *vanilla.VanillaWorlds, tick_rate: *lightning_rod.TickRate };

    deps: Dependencies,
    ticks: u64 = 0,
    stage: enum { waiting, forced, built, warping, done } = .waiting,
    warp_from: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*Farm {
        const self = try allocator.create(Farm);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *Farm, io: std.Io) !void {
        self.ticks += 1;
        switch (self.stage) {
            .waiting => {
                if (self.ticks % 5 != 0) return;
                std.Io.Dir.cwd().access(io, config.farm_file, .{}) catch return;
                const world = self.deps.worlds.overworld;
                var x = farm.chunk_min[0];
                while (x <= farm.chunk_max[0]) : (x += 1) {
                    var z = farm.chunk_min[1];
                    while (z <= farm.chunk_max[1]) : (z += 1) try self.deps.domains.force(.{ .world = world, .x = x, .z = z });
                }
                try self.place();
                self.stage = .forced;
            },
            // Cows come once the farm's columns tick, as a summon does in loaded chunks.
            .forced => {
                const world = self.deps.worlds.overworld;
                var x = farm.chunk_min[0];
                while (x <= farm.chunk_max[0]) : (x += 1) {
                    var z = farm.chunk_min[1];
                    while (z <= farm.chunk_max[1]) : (z += 1) if (!self.deps.domains.ticks(.{ .world = world, .x = x, .z = z })) return;
                }
                // As /summon does: facing south, with the spawn a mob finalizes.
                for (0..farm.cows) |index| _ = try self.deps.mobs.spawn(.{ .species = .cow, .world = world, .position = farm.cowPosition(index), .yaw = 0 });
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config.farm_built_file, .data = "built\n" });
                self.stage = .built;
            },
            .built => {
                if (self.ticks % 5 != 0) return;
                var buffer: [32]u8 = undefined;
                const text = std.Io.Dir.cwd().readFile(io, config.warp_file, &buffer) catch return;
                const ticks = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch return;
                self.deps.tick_rate.sprint(ticks);
                self.warp_from = self.ticks;
                self.stage = .warping;
            },
            .warping => {
                if (self.deps.tick_rate.sprinting()) return;
                var buffer: [32]u8 = undefined;
                try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config.warped_file, .data = try std.fmt.bufPrint(&buffer, "{d}\n", .{self.ticks - self.warp_from}) });
                self.stage = .done;
            },
            .done => {},
        }
    }

    /// The farm's blocks: the ground, water and fence first, then the cane, so no cane is ever
    /// placed without the water beside it.
    fn place(self: *Farm) !void {
        const world = self.deps.worlds.overworld;
        const sand = try state("minecraft:sand");
        const water = try state("minecraft:water[level=0]");
        const cane = try state("minecraft:sugar_cane[age=0]");
        for ([_]bool{ false, true }) |canes| {
            var x = farm.block_min[0];
            while (x <= farm.block_max[0]) : (x += 1) {
                var z = farm.block_min[1];
                while (z <= farm.block_max[1]) : (z += 1) {
                    const ground: chunks.Position = .{ .x = x, .y = farm.ground_y, .z = z };
                    const above: chunks.Position = .{ .x = x, .y = farm.cane_y, .z = z };
                    switch (farm.cell(x, z)) {
                        .cane => if (canes) try self.deps.chunks.setBlock(world, above, cane) else try self.deps.chunks.setBlock(world, ground, sand),
                        .sand => if (!canes) try self.deps.chunks.setBlock(world, ground, sand),
                        .water => if (!canes) try self.deps.chunks.setBlock(world, ground, water),
                        .fence => if (!canes) try self.deps.chunks.setBlock(world, above, try fence(x, z)),
                    }
                }
            }
        }
    }

    /// A fence post joined to the fence beside it, as vanilla shapes one placed among others.
    fn fence(x: i32, z: i32) !u16 {
        const Side = struct {
            fn joins(at_x: i32, at_z: i32) []const u8 {
                if (at_x < farm.block_min[0] or at_x > farm.block_max[0] or at_z < farm.block_min[1] or at_z > farm.block_max[1]) return "false";
                return if (farm.cell(at_x, at_z) == .fence) "true" else "false";
            }
        };
        var buffer: [128]u8 = undefined;
        return state(try std.fmt.bufPrint(&buffer, "minecraft:oak_fence[east={s},north={s},south={s},waterlogged=false,west={s}]", .{ Side.joins(x + 1, z), Side.joins(x, z - 1), Side.joins(x, z + 1), Side.joins(x - 1, z) }));
    }

    fn state(name: []const u8) !u16 {
        return @intCast(protocol_set.registry.blockStateId(name) orelse return error.UnknownBlockState);
    }
};

/// Moves players where the bench asks, as /tp does on the servers with a console: each line of
/// the teleports file in the server's directory, a name and where, once its player is in its
/// world, read a few times a second.
const Teleports = struct {
    pub const id = "mc_server_bench:teleports";
    pub const Configuration = struct {};
    pub const Dependencies = struct { players: *Players };

    deps: Dependencies,
    ticks: u64 = 0,
    /// Lines already carried out.
    done: usize = 0,
    buffer: [64 * 1024]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*Teleports {
        const self = try allocator.create(Teleports);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *Teleports, io: std.Io) !void {
        self.ticks += 1;
        if (self.ticks % 5 != 0) return;
        const text = std.Io.Dir.cwd().readFile(io, config.teleports_file, &self.buffer) catch return;
        var lines = std.mem.splitScalar(u8, text, '\n');
        var index: usize = 0;
        while (lines.next()) |line| : (index += 1) {
            // Only whole lines, which end before the text does.
            if (lines.peek() == null) break;
            if (index < self.done) continue;
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            const name = fields.next() orelse return error.InvalidTeleport;
            var at: [3]f64 = undefined;
            for (&at) |*axis| axis.* = try std.fmt.parseFloat(f64, fields.next() orelse return error.InvalidTeleport);
            const player = self.find(name) orelse return;
            if (!player.inWorld()) return;
            try self.deps.players.teleport(player, player.world, .{ .x = at[0], .y = at[1], .z = at[2] }, player.rotation);
            self.done = index + 1;
        }
    }

    fn find(self: *Teleports, name: []const u8) ?*@TypeOf(self.deps.players.records[0]) {
        for (self.deps.players.activeSlots()) |slot| {
            const player = &self.deps.players.records[slot];
            if (std.mem.eql(u8, player.name[0..player.name_len], name)) return player;
        }
        return null;
    }
};

/// Spawns the cows scenario's herd, the same cows the bench summons on servers with a console: as
/// many as the cows file in the server's directory says, read once a second, around the first
/// player where it stood when the first of them came.
const Cows = struct {
    pub const id = "mc_server_bench:cows";
    pub const Configuration = struct {};
    pub const Dependencies = struct { mobs: *vanilla.Mobs, players: *Players };

    deps: Dependencies,
    ticks: u64 = 0,
    spawned: usize = 0,
    centre: ?[3]f64 = null,
    world: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, _: Configuration, deps: Dependencies) !*Cows {
        const self = try allocator.create(Cows);
        self.* = .{ .deps = deps };
        return self;
    }

    pub fn tick(self: *Cows, io: std.Io) !void {
        self.ticks += 1;
        if (self.ticks % 20 != 0) return;
        var buffer: [32]u8 = undefined;
        const text = std.Io.Dir.cwd().readFile(io, config.cows_file, &buffer) catch return;
        const wanted = std.fmt.parseInt(usize, std.mem.trim(u8, text, " \n"), 10) catch return;
        if (wanted <= self.spawned) return;
        if (self.centre == null) {
            const slots = self.deps.players.activeSlots();
            if (slots.len == 0) return;
            const player = &self.deps.players.records[slots[0]];
            self.centre = .{ player.position.x, player.position.y, player.position.z };
            self.world = player.world;
        }
        // As /summon does: facing south, with the spawn a mob finalizes.
        for (self.spawned..wanted) |index| _ = try self.deps.mobs.spawn(.{ .species = .cow, .world = self.world, .position = config.cowPosition(index, self.centre.?), .yaw = 0 });
        self.spawned = wanted;
    }
};
