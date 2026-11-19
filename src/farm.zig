//! The warp scenario's farm: 32 chunks of sugar cane around spawn on the flat world, rows of cane
//! one block tall on sand, each beside a row of water, with cows among them inside a fence around
//! the farm. Every server builds the same farm, the servers with a console from the commands here
//! and Lightning Rod from the same layout in a plugin, and the bot that checks it after the warp
//! reads the farm against this layout.

const std = @import("std");

/// The farm's chunks: 4 across x and 8 across z, 32 in all, around spawn.
pub const chunk_min = [2]i32{ -2, -4 };
pub const chunk_max = [2]i32{ 1, 3 };
pub const chunks = (chunk_max[0] - chunk_min[0] + 1) * (chunk_max[1] - chunk_min[1] + 1);

/// The blocks the farm covers, the fence on their edge.
pub const block_min = [2]i32{ chunk_min[0] * 16, chunk_min[1] * 16 };
pub const block_max = [2]i32{ chunk_max[0] * 16 + 15, chunk_max[1] * 16 + 15 };

/// The flat world's grass, which the farm's sand and water replace, and the cane above it.
pub const ground_y = 64;
pub const cane_y = ground_y + 1;
/// The tallest sugar cane grows, as vanilla's SugarCaneBlock lets it.
pub const full_height = 3;

/// Cows a chunk holds.
pub const cows_per_chunk = 4;
pub const cows = chunks * cows_per_chunk;

pub const Cell = enum { fence, water, cane, sand };

/// What the farm puts at a column inside it: the fence on the edge, then a row of water every
/// third row along z and cane in the others, every cane beside water. A row by the fence with no
/// water beside it stays sand.
pub fn cell(x: i32, z: i32) Cell {
    std.debug.assert(x >= block_min[0] and x <= block_max[0] and z >= block_min[1] and z <= block_max[1]);
    if (x == block_min[0] or x == block_max[0] or z == block_min[1] or z == block_max[1]) return .fence;
    return switch (@mod(z, 3)) {
        0 => .water,
        1 => .cane,
        else => if (z + 1 < block_max[1]) .cane else .sand,
    };
}

/// Columns of cane the farm plants.
pub const canes = count: {
    @setEvalBranchQuota(100_000);
    var total: usize = 0;
    var z = block_min[1];
    while (z <= block_max[1]) : (z += 1) {
        if (cell(block_min[0] + 1, z) == .cane) total += block_max[0] - block_min[0] - 1;
    }
    break :count total;
};

/// Where a cow is summoned, on cane rows inside its chunk.
pub fn cowPosition(index: usize) [3]f64 {
    const across: usize = @intCast(chunk_max[0] - chunk_min[0] + 1);
    const chunk = index / cows_per_chunk;
    const x: i32 = chunk_min[0] + @as(i32, @intCast(chunk % across));
    const z: i32 = chunk_min[1] + @as(i32, @intCast(chunk / across));
    const within: i32 = @intCast(index % cows_per_chunk);
    // Four spots of the chunk clear of the fence, each on the first cane row from there.
    const at_x = x * 16 + 4 + 8 * @mod(within, 2);
    var at_z = z * 16 + 4 + 6 * @divFloor(within, 2);
    while (cell(at_x, at_z) != .cane) at_z += 1;
    return .{ @as(f64, @floatFromInt(at_x)) + 0.5, cane_y, @as(f64, @floatFromInt(at_z)) + 0.5 };
}

/// Whether a cow stands where one was summoned, to a quarter of a block across, as a cow that
/// never wandered does after the warp.
pub fn atSummonSpot(at: [3]f64) bool {
    for (0..cows) |index| {
        const spot = cowPosition(index);
        if (@abs(at[0] - spot[0]) < 0.25 and @abs(at[2] - spot[2]) < 0.25) return true;
    }
    return false;
}

/// The ticks the warp runs. Vanilla ticks `randomTickSpeed` (3) random blocks of each section a
/// tick, so a block is ticked 3/4096 times a tick, and cane grows a block every 16 random ticks
/// on its top block, 32 from one block tall to three. Over this many ticks a block expects 90, and
/// the chance any of the farm's cane falls short is below one in a million.
pub const warp_ticks = 122_880;

/// Every command a server with a console builds the farm from, in order: the ground, then water,
/// then cane, which needs water beside it, then the fence. Each fills at most one row, well within
/// what one fill may change.
pub fn commands(allocator: std.mem.Allocator) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    const x0 = block_min[0] + 1;
    const x1 = block_max[0] - 1;
    try list.append(allocator, try std.fmt.allocPrint(allocator, "fill {d} {d} {d} {d} {d} {d} minecraft:sand", .{ x0, ground_y, block_min[1] + 1, x1, ground_y, block_max[1] - 1 }));
    var z = block_min[1] + 1;
    while (z < block_max[1]) : (z += 1) {
        if (cell(x0, z) == .water) try list.append(allocator, try std.fmt.allocPrint(allocator, "fill {d} {d} {d} {d} {d} {d} minecraft:water", .{ x0, ground_y, z, x1, ground_y, z }));
    }
    z = block_min[1] + 1;
    while (z < block_max[1]) : (z += 1) {
        if (cell(x0, z) == .cane) try list.append(allocator, try std.fmt.allocPrint(allocator, "fill {d} {d} {d} {d} {d} {d} minecraft:sugar_cane", .{ x0, cane_y, z, x1, cane_y, z }));
    }
    // The fence's four sides, as not every server fills an outline.
    for ([_][4]i32{
        .{ block_min[0], block_min[1], block_max[0], block_min[1] },
        .{ block_min[0], block_max[1], block_max[0], block_max[1] },
        .{ block_min[0], block_min[1] + 1, block_min[0], block_max[1] - 1 },
        .{ block_max[0], block_min[1] + 1, block_max[0], block_max[1] - 1 },
    }) |side| {
        try list.append(allocator, try std.fmt.allocPrint(allocator, "fill {d} {d} {d} {d} {d} {d} minecraft:oak_fence", .{ side[0], cane_y, side[1], side[2], cane_y, side[3] }));
    }
    return list.items;
}

test "every cane is beside water and the farm is the size it says" {
    var counted: usize = 0;
    var x = block_min[0];
    while (x <= block_max[0]) : (x += 1) {
        var z = block_min[1];
        while (z <= block_max[1]) : (z += 1) {
            if (cell(x, z) != .cane) continue;
            counted += 1;
            try std.testing.expect(cell(x, z - 1) == .water or cell(x, z + 1) == .water);
        }
    }
    try std.testing.expectEqual(canes, counted);
    try std.testing.expectEqual(@as(usize, 32), chunks);
    try std.testing.expectEqual(@as(usize, 5146), canes);
    for (0..cows) |index| {
        const at = cowPosition(index);
        try std.testing.expect(cell(@intFromFloat(@floor(at[0])), @intFromFloat(@floor(at[2]))) == .cane);
    }
}

test "a farm block is ticked often enough for every cane to grow" {
    // A block's random ticks over the warp are Poisson with this mean, and cane needs 32.
    const mean: f64 = @as(f64, warp_ticks) * 3.0 / 4096.0;
    // Chernoff: P(X <= k) <= e^-mean (e mean / k)^k.
    const k: f64 = 31;
    const bound = @exp(-mean + k * (1 + @log(mean / k)));
    try std.testing.expect(bound * @as(f64, canes) < 1e-6);
}

/// Cane columns of one chunk found three tall, and short, and which of the farm's chunks it is,
/// as a server may send a chunk again and only its latest counts.
pub const Tally = struct { chunk: ?usize = null, full: u32 = 0, short: u32 = 0 };

/// The lowest block of the flat world, where a chunk's first section starts.
const world_min_y = -64;

/// Checks the farm's cane in a chunk packet's body, after its id, as 26.2 sends it: where the
/// farm plants cane, the three blocks from `cane_y` up must all be cane, which `isCane` tells by
/// block state. A chunk outside the farm tallies nothing.
pub fn checkChunk(body: []const u8, isCane: *const fn (u32) bool) !Tally {
    var reader: Bytes = .{ .bytes = body };
    const chunk_x = try reader.int(i32);
    const chunk_z = try reader.int(i32);
    if (chunk_x < chunk_min[0] or chunk_x > chunk_max[0] or chunk_z < chunk_min[1] or chunk_z > chunk_max[1]) return .{};
    // Heightmaps: a type and its longs each.
    const heightmaps = try reader.varint();
    for (0..heightmaps) |_| {
        _ = try reader.varint();
        _ = try reader.take(8 * try reader.varint());
    }
    var sections: Bytes = .{ .bytes = try reader.take(try reader.varint()) };
    // Every section below the cane's, then the cane's: the cane and the two blocks above it stay
    // in one section.
    comptime std.debug.assert(@divFloor(cane_y, 16) == @divFloor(cane_y + full_height - 1, 16));
    const target: usize = @intCast(@divFloor(cane_y - world_min_y, 16));
    var states: [4096]u32 = undefined;
    for (0..target + 1) |index| {
        // Blocks that are not air, then since 26.1 blocks holding fluid.
        _ = try sections.int(u16);
        _ = try sections.int(u16);
        try readContainer(&sections, if (index == target) &states else null, 4096);
        try readContainer(&sections, null, 64);
    }
    var tally: Tally = .{ .chunk = @intCast((chunk_z - chunk_min[1]) * (chunk_max[0] - chunk_min[0] + 1) + (chunk_x - chunk_min[0])) };
    const base_y: usize = @intCast(@mod(cane_y, 16));
    for (0..16) |local_z| for (0..16) |local_x| {
        const x = chunk_x * 16 + @as(i32, @intCast(local_x));
        const z = chunk_z * 16 + @as(i32, @intCast(local_z));
        if (cell(x, z) != .cane) continue;
        var tall = true;
        for (0..full_height) |up| {
            if (!isCane(states[((base_y + up) * 16 + local_z) * 16 + local_x])) tall = false;
        }
        if (tall) tally.full += 1 else tally.short += 1;
    };
    return tally;
}

/// A paletted container of `count` entries, into `into` when given: a bit count, then one value,
/// a palette and packed indices into it, or packed values themselves.
fn readContainer(reader: *Bytes, into: ?[]u32, count: usize) !void {
    const bits = (try reader.take(1))[0];
    if (bits == 0) {
        const value = try reader.varint();
        if (into) |out| @memset(out, value);
        return;
    }
    // Block states use a palette up to 8 bits, biomes up to 3; above that the values are direct.
    const direct = bits > (if (count == 4096) @as(u8, 8) else 3);
    var palette: [256]u32 = undefined;
    var palette_len: usize = 0;
    if (!direct) {
        palette_len = try reader.varint();
        if (palette_len > palette.len) return error.InvalidPalette;
        for (palette[0..palette_len]) |*entry| entry.* = try reader.varint();
    }
    const per_long = 64 / @as(usize, bits);
    const longs = (count + per_long - 1) / per_long;
    const data = try reader.take(8 * longs);
    const out = into orelse return;
    const mask = (@as(u64, 1) << @intCast(bits)) - 1;
    for (out, 0..) |*entry, index| {
        const long = std.mem.readInt(u64, data[8 * (index / per_long) ..][0..8], .big);
        const value: u32 = @intCast((long >> @intCast((index % per_long) * bits)) & mask);
        entry.* = if (direct) value else if (value < palette_len) palette[value] else return error.InvalidPalette;
    }
}

const Bytes = struct {
    bytes: []const u8,
    at: usize = 0,

    fn take(self: *Bytes, length: usize) ![]const u8 {
        if (self.bytes.len - self.at < length) return error.Truncated;
        defer self.at += length;
        return self.bytes[self.at..][0..length];
    }

    fn int(self: *Bytes, comptime T: type) !T {
        return std.mem.readInt(T, (try self.take(@sizeOf(T)))[0..@sizeOf(T)], .big);
    }

    fn varint(self: *Bytes) !u32 {
        var value: u32 = 0;
        for (0..5) |shift| {
            const byte = (try self.take(1))[0];
            value |= @as(u32, byte & 0x7f) << @intCast(7 * shift);
            if (byte & 0x80 == 0) return value;
        }
        return error.InvalidVarint;
    }
};

test "a chunk packet's farm cane is read three tall where it is and short where it is not" {
    const Fake = struct {
        const cane = 7;
        fn isCane(state: u32) bool {
            return state == cane;
        }
    };
    // Chunk (0, 0): no heightmaps, then sections 0 to 8 of the world, all air but the cane's,
    // where every planted column is cane three tall but one, which is one tall.
    var packet: std.ArrayList(u8) = .empty;
    defer packet.deinit(std.testing.allocator);
    const a = std.testing.allocator;
    try packet.appendSlice(a, &.{ 0, 0, 0, 0, 0, 0, 0, 0, 0 });
    var sections: std.ArrayList(u8) = .empty;
    defer sections.deinit(a);
    const target: usize = @intCast(@divFloor(cane_y - world_min_y, 16));
    var states: [4096]u8 = @splat(0);
    var planted: u32 = 0;
    for (0..16) |z| for (0..16) |x| {
        if (cell(@intCast(x), @intCast(z)) != .cane) continue;
        planted += 1;
        const height: usize = if (x == 3 and z == 4) 1 else full_height;
        for (0..height) |up| states[((@as(usize, @intCast(@mod(cane_y, 16))) + up) * 16 + z) * 16 + x] = 1;
    };
    for (0..target + 1) |index| {
        try sections.appendSlice(a, &.{ 0, 0, 0, 0 });
        if (index == target) {
            // A palette of air and cane, four bits an entry, sixteen to a long.
            try sections.appendSlice(a, &.{ 4, 2, 0, Fake.cane });
            for (0..256) |long_index| {
                var long: u64 = 0;
                for (0..16) |slot| long |= @as(u64, states[long_index * 16 + slot]) << @intCast(4 * slot);
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, long, .big);
                try sections.appendSlice(a, &bytes);
            }
        } else {
            try sections.appendSlice(a, &.{ 0, 0 });
        }
        try sections.appendSlice(a, &.{ 0, 1 });
    }
    // The section bytes' length, as one varint byte or two.
    if (sections.items.len < 128) {
        try packet.append(a, @intCast(sections.items.len));
    } else {
        try packet.appendSlice(a, &.{ @intCast(0x80 | (sections.items.len & 0x7f)), @intCast(sections.items.len >> 7) });
    }
    try packet.appendSlice(a, sections.items);
    const tally = try checkChunk(packet.items, Fake.isCane);
    try std.testing.expectEqual(planted - 1, tally.full);
    try std.testing.expectEqual(@as(u32, 1), tally.short);
}
