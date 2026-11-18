const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Bots and the harness are measured alongside the servers, so they are built to cost little.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const protocols = b.dependency("protocols", .{ .target = target, .optimize = optimize }).module("protocols");
    b.dependency("minecraft_packets", .{ .target = target, .optimize = optimize }).module("minecraft_packets").addImport("protocols", protocols);
    const module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    module.addImport("protocols", protocols);
    module.addImport("minecraft_java", b.dependency("minecraft_java", .{ .target = target, .optimize = optimize }).module("minecraft_java"));
    module.addImport("nbt", b.dependency("nbt", .{ .target = target, .optimize = optimize }).module("nbt"));
    module.addImport("deflate", b.dependency("deflate", .{ .target = target, .optimize = optimize }).module("deflate"));
    const executable = b.addExecutable(.{ .name = "bench", .root_module = module });
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.addPassthruArgs();
    b.step("run", "Run the benchmark harness").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Test the harness").dependOn(&b.addRunArtifact(tests).step);

    // The key Lightning Rod encrypts sessions with: the one its own tests use, as a bench needs
    // no secret one.
    const minecraft_java = b.dependency("minecraft_java", .{ .target = target, .optimize = optimize });
    const key_files = b.addWriteFiles();
    _ = key_files.addCopyFile(minecraft_java.path("tests/fixtures/rsa-key.der"), "rsa-key.der");
    const key = b.createModule(.{ .root_source_file = key_files.add("key.zig", "pub const der = @embedFile(\"rsa-key.der\");\n") });

    // The Lightning Rod server the bench runs, built from its packages as any server outside its
    // repository would be. Its own step, so the harness builds without it.
    const server = b.addExecutable(.{ .name = "lightning_rod", .root_module = b.createModule(.{
        .root_source_file = b.path("src/lightning_rod_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocols", .module = protocols },
            .{ .name = "lightning_rod", .module = b.dependency("lightning_rod", .{ .target = target, .optimize = optimize }).module("lightning_rod") },
            .{ .name = "profile", .module = b.dependency("lightning_rod_linux", .{ .target = target, .optimize = optimize }).module("lightning_rod_linux") },
            .{ .name = "lightning_rod_vanilla_1_21_6", .module = b.dependency("lightning_rod_vanilla_1_21_6", .{ .target = target, .optimize = optimize }).module("lightning_rod_vanilla_1_21_6") },
            .{ .name = "sessions", .module = b.dependency("sessions", .{ .target = target, .optimize = optimize }).module("sessions") },
            .{ .name = "chunks", .module = b.dependency("chunks", .{ .target = target, .optimize = optimize }).module("chunks") },
            .{ .name = "domains", .module = b.dependency("domains", .{ .target = target, .optimize = optimize }).module("domains") },
            .{ .name = "connection", .module = b.dependency("connection", .{ .target = target, .optimize = optimize }).module("connection") },
            .{ .name = "players", .module = b.dependency("players", .{ .target = target, .optimize = optimize }).module("players") },
            .{ .name = "terrain", .module = b.dependency("terrain", .{ .target = target, .optimize = optimize }).module("terrain") },
            .{ .name = "minecraft_java", .module = minecraft_java.module("minecraft_java") },
            .{ .name = "encryption_key", .module = key },
        },
    }) });
    b.step("lightning-rod", "Build the Lightning Rod server the bench runs").dependOn(&b.addInstallArtifact(server, .{}).step);
}
