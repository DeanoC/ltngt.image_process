const std = @import("std");
const warn = std.log.warn;
const assert = std.debug.assert;
const VFile = @import("vfile.zig").VFile;
const VFileError = @import("vfile.zig").VFileError;
const File = std.fs.File;
const Dir = std.fs.Dir;

pub const VFileFile = struct {
    const FileType = VFile.makeFileType("FILE");

    file: File,
    vfile: VFile,

    fn setUpFunctionTable() VFile {
      return comptime VFile{
          .fileType = FileType,
          .closeFn = close,
          .flushFn = flush,
          .readFn = read,
          .writeFn = write,
          .seekFromStartFn = seekFromStart,
          .seekFromCurrentFn = seekFromCurrent,
          .seekFromEndFn = seekFromEnd,
          .tellFn = tell,
          .byteCountFn = byteCount,
          .endOfFileFn = endOfFile,
      };
  }
  pub fn initFromFile(file: File) anyerror!VFileFile {
    return VFileFile{
      .file = file,
      .vfile = setUpFunctionTable(),
    };
  }

  pub fn initFromPath(dir: Dir, path: []const u8, flags: File.OpenFlags) anyerror!VFileFile {
    return VFileFile{
      .file = try dir.openFile(path, flags),
      .vfile = setUpFunctionTable(),
    };
  }

  pub fn create(dir: Dir, path: []const u8, flags: File.CreateFlags) anyerror!VFileFile {
    return VFileFile{
      .file = try dir.createFile(path, flags),
      .vfile = setUpFunctionTable(),
    };
  }

  fn close(vfile: *VFile) void {
      assert(vfile.fileType == FileType);
      const self = @fieldParentPtr(VFileFile, "vfile", vfile);
      File.close(self.file);
  }

  fn flush(vfile: *VFile) anyerror!void {
      assert(vfile.fileType == FileType);
      const self = @fieldParentPtr(VFileFile, "vfile", vfile);
      try File.sync(self.file);
  }

  fn read(vfile: *VFile, buffer: []u8) anyerror!usize {
      assert(vfile.fileType == FileType);
      const self = @fieldParentPtr(VFileFile, "vfile", vfile);
      return File.read(self.file, buffer) catch return VFileError.ReadError;
  }

  fn write(vfile: *VFile, buffer: []const u8) anyerror!usize {
      assert(vfile.fileType == FileType);
      const self = @fieldParentPtr(VFileFile, "vfile", vfile);
      return File.write(self.file, buffer) catch return VFileError.WriteError;
  }

  fn seekFromStart(vfile: *VFile, offset: u64) anyerror!void {
      assert(vfile.fileType == FileType);
      const self = @fieldParentPtr(VFileFile, "vfile", vfile);
      File.seekTo(self.file, offset) catch return VFileError.SeekError;
  }
  fn seekFromCurrent(vfile: *VFile, offset: i64) anyerror!void {
      assert(vfile.fileType == FileType);
      const self = @fieldParentPtr(VFileFile, "vfile", vfile);
      File.seekBy(self.file, offset) catch return VFileError.SeekError;
  }
  fn seekFromEnd(vfile: *VFile, offset: i64) anyerror!void {
      assert(vfile.fileType == FileType);
      const self = @fieldParentPtr(VFileFile, "vfile", vfile);
      File.seekFromEnd(self.file, offset) catch return VFileError.SeekError;
  }

  fn tell(vfile: *VFile) anyerror!usize {
      assert(vfile.fileType == FileType);
      const self = @fieldParentPtr(VFileFile, "vfile", vfile);
      return File.getPos(self.file);
  }

  fn byteCount(vfile: *VFile) anyerror!usize {
      assert(vfile.fileType == FileType);
      const self = @fieldParentPtr(VFileFile, "vfile", vfile);

      return File.getEndPos(self.file);
  }

  fn endOfFile(vfile: *VFile) anyerror!bool {
      assert(vfile.fileType == FileType);
      const self = @fieldParentPtr(VFileFile, "vfile", vfile);
      return try File.getEndPos(self.file) == try File.getPos(self.file);
  }
};

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

var fancy_array = init: {
    var initial_value: [10]u8 = undefined;
    for (initial_value) |*pt, i| {
        pt.* = i + 'a';
    }
    break :init initial_value;
};

test "initFromFile" {
  const tmp_test = try std.fs.cwd().createFile("tmp/test.txt", File.CreateFlags{
    .read = true,
    .truncate = true,
  });
  _ = try tmp_test.write(&fancy_array);
 
  var vfile_file = try VFileFile.initFromFile(tmp_test);
  var v = &vfile_file.vfile;
  try expectEqual(try v.byteCount(), 10);
  v.close();
}

test "create" {
  var vfile_file = try VFileFile.create(std.fs.cwd(), "tmp/test2.txt", File.CreateFlags{
    .read = true,
    .truncate = true,
  });
  var v = &vfile_file.vfile;
  try expectEqual(try v.write(&fancy_array), 10);
  try expectEqual(try v.byteCount(), 10);
  v.close();
}

test "initFromPath" { 
  // make sure its created so we can check the initFromPath
  {
    var vfile_file = try VFileFile.create(std.fs.cwd(), "tmp/test2.txt", File.CreateFlags{
      .read = true,
      .truncate = true,
    });
    var v = &vfile_file.vfile;
    defer v.close();
    try expectEqual(try v.write(&fancy_array), 10);
    try expectEqual(try v.byteCount(), 10);
  }

  var vfile_file = try VFileFile.initFromPath(std.fs.cwd(), "tmp/test2.txt", File.OpenFlags{});
  var v = &vfile_file.vfile;
  defer v.close();
  try expectEqual(try v.seekFromStart(0), 0);  
  try expectEqual(try v.byteCount(), 10);  
}
