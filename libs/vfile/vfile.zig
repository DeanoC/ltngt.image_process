pub const VFileError = error{
    InitError,
    ReadError,
    WriteError,
    SeekError,
};

pub const VFile = struct {
    
    fileType: u32,
    closeFn: *const fn (*VFile) void,
    flushFn: *const fn (self: *VFile) anyerror!void,
    readFn: *const fn (vfile: *VFile, buffer: []u8) anyerror!usize,
    writeFn: *const fn (vfile: *VFile, buffer: []const u8) anyerror!usize,
    seekFromStartFn: *const fn (vfile: *VFile, offset: u64) anyerror!void,
    seekFromCurrentFn: *const fn (vfile: *VFile, offset: i64) anyerror!void,
    seekFromEndFn: *const fn (vfile: *VFile, offset: i64) anyerror!void,
    tellFn: *const fn (vfile: *VFile) anyerror!usize,
    byteCountFn: *const fn (vfile: *VFile) anyerror!usize,
    endOfFileFn: *const fn (vfile: *VFile) anyerror!bool,

    pub fn makeFileType(id: *const [4]u8 ) u32 {
        return (@intCast(u32, id[0]) << 24) | (@intCast(u32, id[1]) << 16) | (@intCast(u32, id[2]) << 8) | (@intCast(u32, id[3]) << 0);
    }   
    pub fn fromFileType(id: i32 ) [4]u8 {
        return [4]u8 { ((id >> 24) & 0xFF), ((id >> 16) & 0xFF), ((id >> 8) & 0xFF), ((id >> 0) & 0xFF) };
    }

    pub fn close(iface: *VFile) void {
        return iface.closeFn(iface);
    }
    pub fn flush(iface: *VFile) anyerror!void {
        return iface.flushFn(iface);
    }
    pub fn read(iface: *VFile,  buffer: []u8) anyerror!usize {
        return iface.readFn(iface, buffer);
    }
    pub fn write(iface: *VFile, buffer: []const u8) anyerror!usize {
        return iface.writeFn(iface, buffer);
    }
    pub fn seekFromStart(iface: *VFile, offset: u64) anyerror!void {
        return iface.seekFromStartFn(iface, offset);
    }
    pub fn seekFromCurrent(iface: *VFile, offset: i64) anyerror!void {
        return iface.seekFromCurrentFn(iface, offset);
    }
    pub fn seekFromEnd(iface: *VFile, offset: i64) anyerror!void {
        return iface.seekFromEndFn(iface, offset);
    }

    pub fn tell(iface: *VFile) anyerror!usize {
        return iface.tellFn(iface);
    }
    pub fn byteCount(iface: *VFile) anyerror!usize {
        return iface.byteCountFn(iface);
    }
    pub fn endOfFile(iface: *VFile) anyerror!bool {
        return iface.endOfFileFn(iface);
    }


};
