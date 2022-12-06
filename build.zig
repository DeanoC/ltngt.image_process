const std = @import("std");

const cflags = &.{"-fno-sanitize=undefined"};

pub fn link(exe: *std.build.LibExeObjStep) void {
    exe.addIncludePath(thisDir());
    exe.linkSystemLibraryName("c");
    exe.linkSystemLibraryName("c++");

    exe.addCSourceFile(thisDir() ++ "/tinyexr.cc", cflags);
    exe.addCSourceFile(thisDir() ++ "/miniz.c", cflags);
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
