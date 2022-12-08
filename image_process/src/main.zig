//------------------------------------------------------------------------------
//  sgl.zig
//
//  sokol_gl.h / sokol.sgl sample program.
//------------------------------------------------------------------------------
const std = @import("std");
const math = @import("std").math;
const vfile = @import("vfile");
const image = @import("image");
const tif = @import("tiny_image_format");
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const gpa_allocator = gpa.allocator();

const content_dir = "../data/";

pub fn main() void {
    // Change current working directory to where the executable is located.
    {
        var buffer: [1024]u8 = undefined;
        const path = std.fs.selfExeDirPath(buffer[0..]) catch ".";
        std.os.chdir(path) catch {};
    }
}
