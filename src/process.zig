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
