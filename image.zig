const std = @import("std");
const tif = @import("tiny_image_format");
const vfile = @import("vfile");
const tiny_ktx = @import("tiny_ktx.zig");
const assert = std.debug.assert;

pub const UsageHint = enum(u8) {
    Generic,
    DiffuseColour,
    SpecularColour,
    _,
};

pub const Flags = packed struct {
    cubemap: bool = false,
    isClut: bool = false,
    hasNextImageData: bool = false,
};

pub const Config = struct {
    width: u32,
    height: u32 = 1,
    depth: u16 = 1,
    slices: u16 = 1,
    format: tif.Format = .R8G8B8A8_UNORM,
    usage: UsageHint = .Generic,
    flags: Flags = .{},

    pub fn calculateDataSize(self: Config) usize {
        return (self.width * self.height * self.depth * self.slices * tif.Block.ByteSize(self.format)) / tif.Block.PixelCount(self.format);
    }
    pub fn pixelCountPerRow(self: Config) u32 {
        return self.width;
    }
    pub fn pixelCountPerPage(self: Config) u32 {
        return self.pixelCountPerRow() * self.height;
    }
    pub fn pixelCountPerSlice(self: Config) u32 {
        return self.pixelCountPerPage() * @as(u32, self.depth);
    }
    pub fn pixelCount(self: Config) u32 {
        return self.pixelCountPerSlice() * @as(u32, self.slices);
    }
    pub fn indexOf(self: Config, address: struct { x: u32, y: u32 = 0, z: u16 = 0, slice: u16 = 0 }) usize {
        assert(address.x < self.width);
        assert(address.y < self.height);
        assert(address.z < self.depth);
        assert(address.slice < self.slices);
        return (address.slice * self.pixelCountPerSlice()) +
            (address.z * self.pixelCountPerPage()) +
            (address.y * self.pixelCountPerRow()) +
            address.x;
    }
    pub fn byteOffsetOf(self: Config, address: struct { x: u32, y: u32 = 0, z: u16 = 0, slice: u16 = 0 }) usize {
        return (indexOf(self, address) * tif.Block.ByteSize(self.format)) / tif.Block.PixelCount(self.format);
    }
};

pub const Image = struct {
    config: Config,

    pub fn init(allocator: std.mem.Allocator, config: Config) !*Image {
        var mem = try allocator.alignedAlloc(u8, 8, @sizeOf(Image) + config.calculateDataSize());
        var image = @ptrCast(*Image, mem);
        image.config = config;
        return image;
    }
    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        var slice: []u8 = undefined;
        slice.ptr = @ptrCast([*]u8, self);
        slice.len = @sizeOf(Image) + self.config.calculateDataSize();
        allocator.free(slice);
    }
    fn vfileRead(self: *vfile.VFile, buffer: []u8) anyerror!usize {
        return self.read(buffer);
    }
    fn vfileSeek(self: *vfile.VFile, offset: u64) anyerror!void {
        return self.seekFromStart(offset);
    }
    fn vfileTell(self: *vfile.VFile) anyerror!usize {
        return self.tell();
    }

    const KtxLoader = tiny_ktx.Loader(*vfile.VFile, vfileRead, vfileSeek, vfileTell);

    pub fn fromKtx(allocator: std.mem.Allocator, file: *vfile.VFile) !*Image {
        var ktx = KtxLoader{ .userData = file, .allocator = allocator };
        defer ktx.deinit();
        try ktx.readHeader();
        const w = ktx.header.pixelWidth;
        // ktx files can have 0 to indicate a dimension isn't used
        const h = if (ktx.header.pixelHeight > 1) ktx.header.pixelHeight else 1;
        const d = if (ktx.header.pixelDepth > 1) ktx.header.pixelDepth else 1;
        const s = if (ktx.header.numberOfArrayElements > 1) ktx.header.numberOfArrayElements else 1;
        std.debug.assert(d < (1 << 16));
        std.debug.assert(s < (1 << 16));

        var image = try Image.init(allocator, Config{
            .width = w,
            .height = h,
            .depth = @intCast(u16, d),
            .slices = @intCast(u16, s),
            .format = ktx.getFormat(),
        });

        std.log.info("{any} {}", .{ image, image.config.calculateDataSize() });
        std.mem.copy(u8, image.data(u8), try ktx.imageDataAt(0));

        return image;
    }

    pub fn dataAt(self: *Image, comptime T: type, offsetInPixels: usize) []T {
        const offSetInBytes = offsetInPixels * tif.Block.ByteSize(self.config.format);
        const image_start = @ptrCast([*]u8, self) + @sizeOf(Image) + offSetInBytes;
        var ret: []T = undefined;
        ret.ptr = @ptrCast([*]T, @alignCast(@alignOf(T), image_start));
        ret.len = (self.config.calculateDataSize() + offSetInBytes) / @sizeOf(T);
        return ret;
    }

    pub fn data(self: *Image, comptime T: type) []T {
        return dataAt(self, T, 0);
    }

    pub fn next(self: *Image) ?*Image {
        if (self.config.flags.hasNextImageData == true) {
            var p = @ptrCast([*]u8, self) + self.sizeInBytes();
            return @ptrCast(*Image, @alignCast(8, p));
        } else {
            return null;
        }
    }

    pub fn clear(self: *Image) void {
        std.mem.set(u8, self.data(u8), 0);
    }

    pub fn decodePixelsAt(self: *Image, output: []@Vector(4, f32), offsetInPixels: usize) void {
        std.debug.assert(tif.Decode.CanDecodePixelsToF32(self.config.format));
        tif.Decode.DecodePixelsToF32(self.config.format, .{ .plane0 = dataAt(u8, offsetInPixels) }, output);
    }

    pub fn encodePixelsAt(self: *Image, input: []const @Vector(4, f32), offsetInPixels: usize) void {
        std.debug.assert(tif.Decode.CanEncodePixelsToF32(self.config.format));
        tif.Encode.EncodePixelsToF32(self.config.format, input, .{ .plane0 = dataAt(u8, offsetInPixels) });
    }

    pub fn getPixelAt(self: *Image, offsetInPixels: usize) @Vector(4, f32) {
        var result: [1]@Vector(4, f32) = undefined;
        tif.Decode.DecodePixelsToF32(self.config.format, .{ .plane0 = self.dataAt(u8, offsetInPixels)[0..tif.Block.ByteSize(self.config.format)] }, &result);
        return result[0];
    }
    pub fn setPixelAt(self: *Image, input: @Vector(4, f32), offsetInPixels: usize) void {
        var in: [1]@Vector(4, f32) = .{input};
        tif.Encode.EncodePixelsToF32(self.config.format, &in, .{ .plane0 = self.dataAt(u8, offsetInPixels)[0..tif.Block.ByteSize(self.config.format)] });
    }

    pub fn dataSizeInBytes(self: *Image) usize {
        return self.config.calculateDataSize();
    }

    pub fn imageChainLength(self: *Image) usize {
        var len: usize = 0;
        var img: ?*Image = self;
        while (img) |image| {
            len += 1;
            img = image.next();
        }
        return len;
    }

    // total size including header and any joined images
    pub fn totalSize(self: *Image) usize {
        var total: usize = 0;
        var img: ?*Image = self;
        while (img) |image| {
            total += image.sizeInBytes();
            img = image.next();
        }
        // if not more next images round up to 8 and return
        return (total + 7) & ~@as(usize, 7);
    }

    // size of this image only (without any following in the chain)
    pub fn sizeInBytes(self: *Image) usize {
        return @sizeOf(Image) + self.config.calculateDataSize();
    }

    /// join to images into a single chain
    pub fn join(allocator: std.mem.Allocator, a: *Image, b: *Image) !*Image {
        var mem = try allocator.alignedAlloc(u8, 8, a.totalSize() + b.totalSize());
        std.mem.copy(u8, mem[0..a.totalSize()], @ptrCast(*u8, a));
        std.mem.copy(u8, mem[a.totalSize()..], @ptrCast(*u8, b));

        var ret = @ptrCast(*Image, mem);
        var img: ?*Image = ret;
        while (img) |image| {
            // if end of original a, mark a has next and we are done
            if (image.config.hasNextImageData == false) {
                image.config.hasNextImageData = true;
                return ret;
            }
            img = image.next();
        }

        unreachable;
    }

    pub fn destructiveJoin(allocator: std.mem.Allocator, a: *Image, b: *Image) !*Image {
        const img = try join(allocator, a, b);
        allocator.free(a);
        allocator.free(b);
        return img;
    }
};

comptime {
    std.debug.assert(@sizeOf(Flags) == 1);
    std.debug.assert(@sizeOf(Image) == 16);
}
