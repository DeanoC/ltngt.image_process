const std = @import("std");

pub fn build(b: *std.build.Builder) !*std.build.LibExeObjStep {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const image_process_build_root = b.pathFromRoot("image_process/src/main.zig");
    const exe = b.addExecutable("image_process", image_process_build_root);
    exe.setTarget(target);
    exe.setBuildMode(mode);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
    return exe;
}
