const std = @import("std");
const tif = @import("tiny_image_format");
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
        return pixelCountPerRow * self.height;
    }
    pub fn pixelCountPerSlice(self: Config) u32 {
        return pixelCountPerPage * self.depth;
    }
    pub fn pixelCount(self: Config) u32 {
        return pixelCountPerSlice * self.slices;
    }

    pub fn indexOf(self: Config, x: u32, y: u32, z: u16, slice: u16) usize {
        assert(x < self.width);
        assert(y < self.height);
        assert(z < self.depth);
        assert(slice < self.slices);
        return (slice * self.pixelCountPerSlice()) +
            (z * self.pixelCountPerPage()) +
            (y * self.pixelCountPerRow()) +
            x;
    }
    pub fn byteOffsetOf(self: Config, x: u32, y: u32, z: u16, slice: u16) usize {
        return (indexOf(self, x, y, z, slice) * tif.Block.ByteSize(self.format)) / tif.Block.PixelCount(self.format);
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
        allocator.destroy(self);
    }

    pub fn data(self: *Image, comptime T: type) []T {
        const image_start = @ptrCast([*]u8, self) + @sizeOf(Image);
        var ret: []T = undefined;
        ret.ptr = @ptrCast([*]T, @alignCast(@alignOf(T), image_start));
        ret.len = self.config.calculateDataSize() / @sizeOf(T);
        return ret;
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
