const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var buildDir = try std.fs.openIterableDirAbsolute(b.build_root,
                             .{ .access_sub_paths=true });
    defer buildDir.close();

    _ = b.addStaticLibrary(.{
        .name = "alt_std",
        .root_source_file = .{ .path = "alt_std.zig" },
        .target = target,
        .optimize = optimize,
    });

    // Package
    b.addModule(.{
        .name = "alt_std",
        .source_file = std.build.FileSource{
            .path = "alt_std.zig",
        }
    });

    // Tests
    const tests = b.addTest(.{
        .root_source_file = .{ .path = "alt_std.zig" },
    });
    const test_step = b.step("test", "run all tests");
    test_step.dependOn(&tests.step);


    // Documentation
    const docs = b.addTest(.{
        .root_source_file = .{ .path = "alt_std.zig" },
    });
    docs.emit_docs = .emit;
    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&docs.step);

    // Benchmarks
    var benchDir = try buildDir.dir.openIterableDir("bench",
                             .{ .access_sub_paths=false });
    defer benchDir.close();

    var it = benchDir.iterate();
    while (try it.next()) |entry| {

        // An independent compilation unit?
        if (isBuildableSource(entry)) |binary| {

            const srcPath = try std.fs.path.join(b.allocator,
                                   &[_][]const u8{"bench", entry.name});

            // Generate a binary
            const exe = b.addExecutable(.{
                .name = binary,
                .root_source_file = .{ .path = srcPath },
                .target = target,
                .optimize = optimize,
            });
            exe.addModule("alt_std", b.modules.get("alt_std") orelse return error.missing_module);
            exe.linkLibC();

            // Create an install step
            const install_exe = b.addInstallArtifact(exe);
            const install_step = b.step(
                try std.fmt.allocPrint(b.allocator, "bench-{s}", .{binary}),
                try std.fmt.allocPrint(b.allocator, "Compile the {s} benchmark", .{binary}),
            );
            install_step.dependOn(&install_exe.step);

            // Add this to the overall install step
            b.getInstallStep().dependOn(&install_exe.step);

            // We'll also add a step to automatically run the process
            const run_cmd = exe.run();
            run_cmd.step.dependOn(&install_exe.step); // gotta build it first
            if (b.args) |args| {
                run_cmd.addArgs(args);
            }
            b.step(
                try std.fmt.allocPrint(b.allocator, "run-bench-{s}", .{binary}),
                try std.fmt.allocPrint(b.allocator, "Run the {s} benchmark", .{binary}),
            ).dependOn(&run_cmd.step);

        }
    }
}

// Detects whether this is a source file that we should compile into a process
// If it is, returns the name for the resulting binary
fn isBuildableSource(entry: std.fs.IterableDir.Entry) ?[]const u8 {
    if (entry.kind != .File) return null;

    const ext = std.fs.path.extension(entry.name);
    return if (std.mem.eql(u8, ext, ".zig")) entry.name[0..entry.name.len - 4] else null;
}
