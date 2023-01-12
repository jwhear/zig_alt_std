const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) !void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    var buildDir = try std.fs.openIterableDirAbsolute(b.build_root,
                             .{ .access_sub_paths=true });
    defer buildDir.close();

    const lib = b.addStaticLibrary("alt_std", "alt_std.zig");
    lib.setBuildMode(mode);
    lib.setTarget(target);

    // Package
    const package = std.build.Pkg{
        .name = "alt_std",
        .source = std.build.FileSource{
            .path = "alt_std.zig",
        }
    };

    // Tests
    const tests = b.addTest("alt_std.zig");
    tests.setBuildMode(mode);
    const test_step = b.step("test", "run all tests");
    test_step.dependOn(&tests.step);


    // Documentation
    const docs = b.addTest("alt_std.zig");
    docs.setBuildMode(mode);
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
            const exe = b.addExecutable(binary, srcPath);
            exe.setTarget(target);
            exe.setBuildMode(mode);
            exe.addPackage(package);
            exe.linkLibC();

            // Create an install step
            const install_exe = b.addInstallArtifact(exe);
            const install_step = b.step(
                try std.fmt.allocPrint(b.allocator, "build-bench-{s}", .{binary}),
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
