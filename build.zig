const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const lib = b.addStaticLibrary("alt_std", "alt_std.zig");
    lib.setBuildMode(mode);
    lib.setTarget(target);

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
}
