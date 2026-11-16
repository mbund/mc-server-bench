//! Draws a sweep's results as one HTML page of charts, with the numbers of every run in a table
//! below them.

const std = @import("std");

const template = @embedFile("report.html");
const placeholder = "/*RESULTS*/[]";

pub fn write(allocator: std.mem.Allocator, io: std.Io, directory: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const lines = try cwd.readFileAlloc(io, try std.fs.path.join(allocator, &.{ directory, "results.jsonl" }), allocator, .limited(1 << 30));
    var output: std.Io.Writer.Allocating = .init(allocator);
    const writer = &output.writer;
    const at = std.mem.indexOf(u8, template, placeholder) orelse return error.InvalidTemplate;
    try writer.writeAll(template[0..at]);

    // The page needs summaries only, so each run's timeline stays in its own result file.
    var json: std.Io.Writer.Allocating = .init(allocator);
    try json.writer.writeByte('[');
    var first = true;
    var runs = std.mem.tokenizeScalar(u8, lines, '\n');
    while (runs.next()) |line| {
        var parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{});
        _ = parsed.object.orderedRemove("samples");
        if (!first) try json.writer.writeByte(',');
        first = false;
        try std.json.Stringify.value(parsed, .{}, &json.writer);
    }
    try json.writer.writeByte(']');
    // Text in the results must not close the script it sits in.
    for (json.written(), 0..) |byte, index| {
        if (byte == '/' and index > 0 and json.written()[index - 1] == '<') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeAll(template[at + placeholder.len ..]);
    const path = try std.fs.path.join(allocator, &.{ directory, "report.html" });
    try cwd.writeFile(io, .{ .sub_path = path, .data = output.written() });
    std.log.info("wrote {s}", .{path});
}
