//! What the kernel knows about a server process: CPU time, memory, threads and disk traffic, read
//! from /proc without allocating.

const std = @import("std");
const linux = std.os.linux;

/// Clock ticks per second of /proc/<pid>/stat times, fixed at 100 on Linux.
const clock_ticks = 100;

pub const Usage = struct {
    /// User and system CPU time of every thread the process ever ran.
    cpu_ns: u64 = 0,
    /// Resident memory now and at its peak.
    rss_bytes: u64 = 0,
    peak_rss_bytes: u64 = 0,
    threads: u64 = 0,
    /// Bytes the process made the storage layer read and write: disk traffic, not cache hits.
    disk_read_bytes: u64 = 0,
    disk_write_bytes: u64 = 0,
    /// Bytes passed through read and write calls of any kind, sockets included.
    read_chars: u64 = 0,
    write_chars: u64 = 0,
};

pub fn sample(pid: linux.pid_t) !Usage {
    var usage: Usage = .{};
    var buffer: [4096]u8 = undefined;
    var path: [64]u8 = undefined;

    const stat = try readProc(try std.fmt.bufPrintSentinel(&path, "/proc/{d}/stat", .{pid}, 0), &buffer);
    // The command name may hold spaces, so fields count from its closing parenthesis.
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return error.InvalidStat;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    var index: usize = 3;
    var ticks: u64 = 0;
    while (fields.next()) |word| : (index += 1) {
        switch (index) {
            14, 15 => ticks += try std.fmt.parseInt(u64, word, 10),
            20 => usage.threads = try std.fmt.parseInt(u64, word, 10),
            else => {},
        }
    }
    usage.cpu_ns = ticks * (std.time.ns_per_s / clock_ticks);

    const status = try readProc(try std.fmt.bufPrintSentinel(&path, "/proc/{d}/status", .{pid}, 0), &buffer);
    usage.rss_bytes = field(status, "VmRSS:") * 1024;
    usage.peak_rss_bytes = field(status, "VmHWM:") * 1024;

    const io = try readProc(try std.fmt.bufPrintSentinel(&path, "/proc/{d}/io", .{pid}, 0), &buffer);
    usage.read_chars = field(io, "rchar:");
    usage.write_chars = field(io, "wchar:");
    usage.disk_read_bytes = field(io, "read_bytes:");
    usage.disk_write_bytes = field(io, "write_bytes:");
    return usage;
}

/// The number after a label at the start of a line.
fn field(text: []const u8, label: []const u8) u64 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, label)) continue;
        var words = std.mem.tokenizeAny(u8, line[label.len..], " \t");
        return std.fmt.parseInt(u64, words.next() orelse return 0, 10) catch 0;
    }
    return 0;
}

pub fn readProc(path: [:0]const u8, buffer: []u8) ![]const u8 {
    const opened = linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(opened) != .SUCCESS) return error.ProcessGone;
    const fd: linux.fd_t = @intCast(opened);
    defer _ = linux.close(fd);
    var length: usize = 0;
    while (length < buffer.len) {
        const result = linux.read(fd, buffer[length..].ptr, buffer.len - length);
        if (linux.errno(result) != .SUCCESS) return error.ProcessGone;
        if (result == 0) break;
        length += result;
    }
    return buffer[0..length];
}

/// The machine's memory in megabytes, as the kernel counts it.
pub fn memoryMb() !u64 {
    var buffer: [8192]u8 = undefined;
    const kilobytes = field(try readProc("/proc/meminfo", &buffer), "MemTotal:");
    if (kilobytes == 0) return error.UnknownMemory;
    return kilobytes / 1024;
}

/// Pins the calling thread, and the threads it starts after, to a list of CPUs like "0-7,12".
pub fn pin(cpus: []const u8) !void {
    var set: linux.cpu_set_t = @splat(0);
    var ranges = std.mem.tokenizeScalar(u8, cpus, ',');
    while (ranges.next()) |range| {
        const dash = std.mem.indexOfScalar(u8, range, '-');
        const first = try std.fmt.parseInt(usize, if (dash) |at| range[0..at] else range, 10);
        const last = if (dash) |at| try std.fmt.parseInt(usize, range[at + 1 ..], 10) else first;
        if (last < first or last >= @bitSizeOf(linux.cpu_set_t)) return error.InvalidCpuList;
        for (first..last + 1) |cpu| set[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    }
    try linux.sched_setaffinity(0, &set);
}

test "a process can read its own usage" {
    const usage = try sample(linux.getpid());
    try std.testing.expect(usage.rss_bytes > 0 and usage.threads >= 1);
    try std.testing.expect(usage.peak_rss_bytes >= usage.rss_bytes);
}

test "fields read past their labels" {
    try std.testing.expectEqual(@as(u64, 1234), field("Name:\tx\nVmRSS:\t    1234 kB\n", "VmRSS:"));
    try std.testing.expectEqual(@as(u64, 0), field("Name:\tx\n", "VmRSS:"));
}

/// The CPUs of the server and of the bots when not given. The bots, which cost little, get a
/// quarter of the CPUs and at least one, from the last physical core, and the server the rest, so
/// that servers which spread work over threads, collectors and thread pools have the room a real
/// host gives them. Without readable topology, the last quarter of the CPUs.
pub const CpuSplit = struct { server: []const u8, bots: []const u8, cores: usize };

pub fn splitCores(allocator: std.mem.Allocator, io: std.Io, cpus: usize) !CpuSplit {
    std.debug.assert(cpus >= 2);
    const bot_count = @max(1, cpus / 4);
    // Every CPU, ordered by the physical core it is on, cores in the order they first appear.
    const order = try allocator.alloc(usize, cpus);
    const cores = try allocator.alloc(u64, cpus);
    const owners = try allocator.alloc(usize, cpus);
    var core_count: usize = 0;
    var known = true;
    for (0..cpus) |cpu| {
        const core = coreOf(io, cpu) orelse {
            known = false;
            break;
        };
        owners[cpu] = std.mem.indexOfScalar(u64, cores[0..core_count], core) orelse found: {
            cores[core_count] = core;
            core_count += 1;
            break :found core_count - 1;
        };
    }
    if (known) {
        var at: usize = 0;
        for (0..core_count) |core| for (owners[0..cpus], 0..) |owner, cpu| if (owner == core) {
            order[at] = cpu;
            at += 1;
        };
    } else {
        core_count = cpus;
        for (order, 0..) |*cpu, index| cpu.* = index;
    }
    const is_bot = try allocator.alloc(bool, cpus);
    @memset(is_bot, false);
    for (order[cpus - bot_count ..]) |cpu| is_bot[cpu] = true;
    var server: std.ArrayList(u8) = .empty;
    var bots: std.ArrayList(u8) = .empty;
    for (is_bot, 0..) |bot, cpu| {
        const list = if (bot) &bots else &server;
        if (list.items.len != 0) try list.append(allocator, ',');
        try list.print(allocator, "{d}", .{cpu});
    }
    return .{ .server = server.items, .bots = bots.items, .cores = core_count };
}

/// The physical core a CPU is on, as its package and core, or null when the kernel does not say.
fn coreOf(io: std.Io, cpu: usize) ?u64 {
    var path: [96]u8 = undefined;
    var bytes: [32]u8 = undefined;
    var ids: [2]u64 = undefined;
    for ([_][]const u8{ "physical_package_id", "core_id" }, &ids) |name, *id| {
        const file = std.fmt.bufPrint(&path, "/sys/devices/system/cpu/cpu{d}/topology/{s}", .{ cpu, name }) catch return null;
        const text = std.Io.Dir.cwd().readFile(io, file, &bytes) catch return null;
        id.* = std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 10) catch return null;
    }
    return ids[0] << 32 | ids[1];
}

test "the bots get a quarter of the cpus and the server the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cpus = try std.Thread.getCpuCount();
    if (cpus < 2) return error.SkipZigTest;
    const split = try splitCores(arena.allocator(), std.testing.io, cpus);
    try std.testing.expect(split.server.len > 0 and split.bots.len > 0 and split.cores >= 1);
}
