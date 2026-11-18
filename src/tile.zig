//! Copies one tile of a pregenerated world into a square grid of copies, every chunk written to
//! the world's own files as the server saved it, so runs where players spread far apart stream
//! real terrain everywhere, from disk, without generating a world that large: generating real
//! terrain takes the time of minutes per thousand chunks, and copying it far less.
//!
//! The tile is the square of chunks around the origin a player's view fits in with a ring to
//! spare, so a player in the middle of a copy sees only that copy. Vanilla's chunks record their
//! own position, and those of their block entities and scheduled ticks, which every copy moves
//! with it. Structure records are left as the tile had them, as the bench uses none, and entity
//! and point of interest files are left out, as the worlds hold no entities and points of interest
//! come back from the blocks. SteelMC keeps those positions relative to the chunk, so its copies
//! are its saved chunks as they are, in other slots.

const std = @import("std");
const deflate = @import("deflate");
const nbt = @import("nbt");

/// Chunks along each side of the tile: a view of eight chunks either way and the chunk it is
/// centred on, and a ring beyond, so the views of players in neighbouring copies never meet.
pub const tile_chunks = 18;
/// The tile's first chunk along each axis, so it is centred on the origin.
pub const tile_start = -tile_chunks / 2;
/// Copies either way of the tile along each axis: 23 by 23 copies, room for 512 players.
pub const reach = 11;
/// Blocks between the middles of neighbouring copies.
pub const spacing = tile_chunks * 16;

pub const Format = enum { vanilla, steel };

/// Turns the tile of the world in `directory` into the grid of copies, in place.
pub fn tile(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, format: Format) !void {
    const dimension = switch (format) {
        .vanilla => try std.fs.path.join(allocator, &.{ directory, "world/dimensions/minecraft/overworld" }),
        .steel => try std.fs.path.join(allocator, &.{ directory, "saves/minecraft/worlds/overworld" }),
    };
    const extension = switch (format) {
        .vanilla => "mca",
        .steel => "srg",
    };
    const region = try std.fs.path.join(allocator, &.{ dimension, "region" });
    const source = try Source.read(allocator, io, region, extension, format);
    const output = try std.fs.path.join(allocator, &.{ dimension, "region.tiled" });
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, output) catch {};
    try cwd.createDirPath(io, output);

    var writer: RegionWriter = try .init(allocator, format, source.version);
    defer writer.deinit();
    // Every region file any copy reaches.
    const low = regionOf(tile_start - reach * tile_chunks);
    const high = regionOf(tile_start + (reach + 1) * tile_chunks - 1);
    var count: usize = 0;
    var region_x = low;
    while (region_x <= high) : (region_x += 1) {
        var region_z = low;
        while (region_z <= high) : (region_z += 1) {
            writer.begin();
            for (0..32) |local_z| for (0..32) |local_x| {
                const x = region_x * 32 + @as(i32, @intCast(local_x));
                const z = region_z * 32 + @as(i32, @intCast(local_z));
                const from = copyOf(x) orelse continue;
                const from_z = copyOf(z) orelse continue;
                const chunk = source.chunk(from.chunk, from_z.chunk) orelse return error.TileIncomplete;
                try writer.add(local_x + local_z * 32, chunk, .{ x - from.chunk, z - from_z.chunk });
                count += 1;
            };
            const name = try std.fmt.allocPrint(allocator, "{s}/r.{d}.{d}.{s}", .{ output, region_x, region_z, extension });
            try cwd.writeFile(io, .{ .sub_path = name, .data = writer.finish() });
        }
    }
    std.debug.assert(count == (2 * reach + 1) * (2 * reach + 1) * tile_chunks * tile_chunks);
    try cwd.deleteTree(io, region);
    try cwd.rename(output, cwd, region, io);
    if (format == .vanilla) for ([_][]const u8{ "entities", "poi" }) |name| {
        try cwd.deleteTree(io, try std.fs.path.join(allocator, &.{ dimension, name }));
    };
    std.log.info("tiled {d} chunks into {d} by {d} copies", .{ count, 2 * reach + 1, 2 * reach + 1 });
}

/// The region file a chunk coordinate falls in.
fn regionOf(chunk: i32) i32 {
    return @divFloor(chunk, 32);
}

/// The tile's chunk a copy's chunk is the copy of, if the coordinate falls in a copy.
fn copyOf(chunk: i32) ?struct { chunk: i32 } {
    const copy = @divFloor(chunk - tile_start, tile_chunks);
    if (copy < -reach or copy > reach) return null;
    return .{ .chunk = chunk - copy * tile_chunks };
}

test "every copy of a chunk maps back to the tile" {
    try std.testing.expectEqual(@as(i32, tile_start), copyOf(tile_start).?.chunk);
    try std.testing.expectEqual(@as(i32, tile_start), copyOf(tile_start + tile_chunks).?.chunk);
    try std.testing.expectEqual(@as(i32, tile_start + tile_chunks - 1), copyOf(tile_start - 1).?.chunk);
    try std.testing.expectEqual(@as(?@TypeOf(copyOf(0).?), null), copyOf(tile_start + (reach + 1) * tile_chunks));
    try std.testing.expect(copyOf(tile_start - reach * tile_chunks) != null);
    try std.testing.expectEqual(@as(?@TypeOf(copyOf(0).?), null), copyOf(tile_start - reach * tile_chunks - 1));
}

/// A chunk of the tile as its region file held it.
const Chunk = struct {
    /// Vanilla: the compression type and the compressed NBT. SteelMC: the compressed chunk.
    data: []const u8,
    compression: u8 = 0,
    /// SteelMC: the chunk's status, from its region table.
    status: u8 = 0,
    timestamp: u32 = 0,
};

/// The tile's chunks, read from the region files it spans.
const Source = struct {
    chunks: [tile_chunks * tile_chunks]?Chunk,
    /// SteelMC's format version, which the copies keep.
    version: u16,

    fn read(allocator: std.mem.Allocator, io: std.Io, region: []const u8, extension: []const u8, format: Format) !Source {
        var source: Source = .{ .chunks = @splat(null), .version = 0 };
        var region_x = regionOf(tile_start);
        while (region_x <= regionOf(tile_start + tile_chunks - 1)) : (region_x += 1) {
            var region_z = regionOf(tile_start);
            while (region_z <= regionOf(tile_start + tile_chunks - 1)) : (region_z += 1) {
                const name = try std.fmt.allocPrint(allocator, "{s}/r.{d}.{d}.{s}", .{ region, region_x, region_z, extension });
                const bytes = try std.Io.Dir.cwd().readFileAlloc(io, name, allocator, .limited(1 << 30));
                for (0..tile_chunks) |z| for (0..tile_chunks) |x| {
                    const chunk_x = tile_start + @as(i32, @intCast(x));
                    const chunk_z = tile_start + @as(i32, @intCast(z));
                    if (regionOf(chunk_x) != region_x or regionOf(chunk_z) != region_z) continue;
                    const index: usize = @intCast(@mod(chunk_x, 32) + @mod(chunk_z, 32) * 32);
                    source.chunks[x + z * tile_chunks] = switch (format) {
                        .vanilla => try vanillaChunk(bytes, index),
                        .steel => try steelChunk(bytes, index, &source.version),
                    };
                };
            }
        }
        return source;
    }

    fn chunk(self: *const Source, x: i32, z: i32) ?Chunk {
        return self.chunks[@intCast((x - tile_start) + (z - tile_start) * tile_chunks)];
    }
};

/// Anvil: a table of sector offsets and counts, a table of timestamps, then sectors holding each
/// chunk's length, compression type and compressed NBT.
fn vanillaChunk(bytes: []const u8, index: usize) !?Chunk {
    if (bytes.len < 8192) return error.InvalidRegion;
    const location = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .big);
    const sector = location >> 8;
    if (sector == 0) return null;
    const start = sector * 4096;
    if (start + 5 > bytes.len) return error.InvalidRegion;
    const length = std.mem.readInt(u32, bytes[start..][0..4], .big);
    if (length < 1 or start + 4 + length > bytes.len) return error.InvalidRegion;
    const compression = bytes[start + 4];
    // Zlib, vanilla's default. Others, and chunks too large for their region file, are not
    // expected of a fresh world.
    if (compression != 2) return error.UnsupportedCompression;
    return .{ .data = bytes[start + 5 .. start + 4 + length], .compression = compression, .timestamp = std.mem.readInt(u32, bytes[4096 + index * 4 ..][0..4], .big) };
}

/// SteelMC: a header with its magic and format version, a table of sector offsets, sizes and
/// statuses, then sectors holding each compressed chunk.
fn steelChunk(bytes: []const u8, index: usize, version: *u16) !?Chunk {
    if (bytes.len < 8 + 8192 or !std.mem.eql(u8, bytes[0..4], "STLR")) return error.InvalidRegion;
    version.* = std.mem.readInt(u16, bytes[4..6], .little);
    const entry = bytes[8 + index * 8 ..][0..8];
    const sector = std.mem.readInt(u32, entry[0..4], .little);
    if (sector == 0) return null;
    const size = std.mem.readInt(u24, entry[4..7], .little);
    const start = @as(usize, sector) * 4096;
    if (start + size > bytes.len) return error.InvalidRegion;
    return .{ .data = bytes[start .. start + size], .status = entry[7] };
}

/// Builds one region file at a time.
const RegionWriter = struct {
    allocator: std.mem.Allocator,
    format: Format,
    version: u16,
    bytes: std.ArrayList(u8) = .empty,
    encoder: deflate.Encoder,
    decoder: deflate.Decoder,
    nbt_buffer: []u8,
    compressed: []u8,
    nodes: []nbt.Node,
    stack: []nbt.Frame,

    fn init(allocator: std.mem.Allocator, format: Format, version: u16) !RegionWriter {
        return .{
            .allocator = allocator,
            .format = format,
            .version = version,
            .encoder = try .init(allocator, 6),
            .decoder = try .init(allocator),
            .nbt_buffer = try allocator.alloc(u8, 16 << 20),
            .compressed = try allocator.alloc(u8, 17 << 20),
            .nodes = try allocator.alloc(nbt.Node, 1 << 18),
            .stack = try allocator.alloc(nbt.Frame, 512),
        };
    }

    fn deinit(self: *RegionWriter) void {
        self.encoder.deinit();
        self.decoder.deinit();
    }

    fn header(self: *const RegionWriter) usize {
        return switch (self.format) {
            .vanilla => 8192,
            .steel => 3 * 4096,
        };
    }

    fn begin(self: *RegionWriter) void {
        self.bytes.clearRetainingCapacity();
        self.bytes.appendNTimes(self.allocator, 0, self.header()) catch unreachable;
        if (self.format == .steel) {
            @memcpy(self.bytes.items[0..4], "STLR");
            std.mem.writeInt(u16, self.bytes.items[4..6], self.version, .little);
        }
    }

    /// Adds a copy of a chunk at a slot, moved `copy` chunks along each axis from the tile.
    fn add(self: *RegionWriter, index: usize, chunk: Chunk, copy: [2]i32) !void {
        const sector: u32 = @intCast(self.bytes.items.len / 4096);
        switch (self.format) {
            .vanilla => {
                const moved = try self.move(chunk.data, copy);
                try self.bytes.ensureUnusedCapacity(self.allocator, moved.len + 5 + 4096);
                var length: [4]u8 = undefined;
                std.mem.writeInt(u32, &length, @intCast(moved.len + 1), .big);
                self.bytes.appendSliceAssumeCapacity(&length);
                self.bytes.appendAssumeCapacity(chunk.compression);
                self.bytes.appendSliceAssumeCapacity(moved);
                self.pad();
                const sectors: u32 = @intCast(self.bytes.items.len / 4096 - sector);
                if (sectors > 255) return error.ChunkTooLarge;
                std.mem.writeInt(u32, self.bytes.items[index * 4 ..][0..4], sector << 8 | sectors, .big);
                std.mem.writeInt(u32, self.bytes.items[4096 + index * 4 ..][0..4], chunk.timestamp, .big);
            },
            .steel => {
                try self.bytes.appendSlice(self.allocator, chunk.data);
                self.pad();
                const entry = self.bytes.items[8 + index * 8 ..][0..8];
                std.mem.writeInt(u32, entry[0..4], sector, .little);
                std.mem.writeInt(u24, entry[4..7], @intCast(chunk.data.len), .little);
                entry[7] = chunk.status;
            },
        }
    }

    /// Pads the file to a whole sector.
    fn pad(self: *RegionWriter) void {
        const start = self.bytes.items.len;
        self.bytes.appendNTimes(self.allocator, 0, (4096 - start % 4096) % 4096) catch unreachable;
    }

    fn finish(self: *RegionWriter) []const u8 {
        return self.bytes.items;
    }

    /// A vanilla chunk moved along each axis: its position, and the positions of its block entities
    /// and scheduled ticks, recompressed.
    fn move(self: *RegionWriter, compressed: []const u8, copy: [2]i32) ![]const u8 {
        const data = try self.decoder.decode(compressed, self.nbt_buffer);
        const document = try nbt.scan_named(data, self.nodes, self.stack);
        try shift(document.childNamed("xPos") orelse return error.InvalidChunk, copy[0]);
        try shift(document.childNamed("zPos") orelse return error.InvalidChunk, copy[1]);
        for ([_][]const u8{ "block_entities", "block_ticks", "fluid_ticks" }) |name| {
            const list = document.childNamed(name) orelse continue;
            var entries = list.childIterator(document.nodes);
            while (entries.next()) |entry| {
                if (entry.tag != .compound) continue;
                try shift(entry.childNamed(document.nodes, "x") orelse return error.InvalidChunk, copy[0] * 16);
                try shift(entry.childNamed(document.nodes, "z") orelse return error.InvalidChunk, copy[1] * 16);
            }
        }
        return self.encoder.encode(data, self.compressed);
    }
};

/// Adds to an int in the NBT it was scanned from.
fn shift(node: nbt.Node, by: i32) !void {
    const value = try node.int();
    const bytes: *[4]u8 = @constCast(node.payload[0..4]);
    std.mem.writeInt(i32, bytes, value + by, .big);
}
