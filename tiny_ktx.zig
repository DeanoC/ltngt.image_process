const std = @import("std");

pub const KtxError = error{
    NotValidError,
    UnsupportedError,
    MipMapError,
};

const Header = struct {
    identifier: [12]u8,
    endianness: u32,
    glType: u32,
    glTypeSize: u32,
    glFormat: u32,
    glInternalFormat: u32,
    glBaseInternalFormat: u32,
    pixelWidth: u32,
    pixelHeight: u32,
    pixelDepth: u32,
    numberOfArrayElements: u32,
    numberOfFaces: u32,
    numberOfMipmapLevels: u32,
    bytesOfKeyValueData: u32,
};
const identifier = [12]u8{ 0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A };

pub fn Loader(comptime funcData: type, comptime readFn: fn (userData: funcData, buffer: []u8) anyerror!usize, comptime seekFn: fn (userData: funcData, offset: u64) anyerror!void, comptime tellFn: fn (userData: funcData) anyerror!usize) type {
    return struct {
        const Self = @This();
        const MaxMipMapLevels = 16;
        // must be provided by callee
        userData: funcData,
        allocator: std.mem.Allocator,

        // filled when the header is read
        headerPos: usize = undefined,
        firstImagePos: usize = undefined,
        header: Header = undefined,
        headerValid: bool = false,
        sameEndian: bool = false,
        keyValueData: []u8 = undefined,

        // filled when mipmaps are read
        mipMapSizes: [MaxMipMapLevels]u32 = [_]u32{0} ** MaxMipMapLevels,
        mipMaps: [MaxMipMapLevels]?[]u8 = undefined,

        comptime read: fn (_: funcData, buffer: []u8) anyerror!usize = readFn,
        comptime seek: fn (userData: funcData, offset: u64) anyerror!void = seekFn,
        comptime tell: fn (userData: funcData) anyerror!usize = tellFn,

        pub fn readHeader(self: *Self) !void {
            const same_endian = 0x04030201;
            const different_endian = 0x01020304;
            self.headerPos = try self.tell(self.userData);
            _ = try self.read(self.userData, @ptrCast([*]u8, &self.header)[0..@sizeOf(Header)]);
            if (std.mem.eql(u8, &self.header.identifier, &identifier) == false) {
                return KtxError.NotValidError;
            }
            if (self.header.endianness == same_endian) {
                self.sameEndian = true;
            } else if (self.header.endianness == different_endian) {
                self.sameEndian = false;
            } else {
                // corrupt or middle endian platform??
                return KtxError.NotValidError;
            }

            if (self.header.numberOfFaces != 1 and self.header.numberOfFaces != 6) {
                return KtxError.UnsupportedError;
            }

            self.keyValueData = try self.allocator.alloc(u8, self.header.bytesOfKeyValueData);
            _ = try self.read(self.userData, self.keyValueData);

            self.firstImagePos = try self.tell(self.userData);
            self.headerValid = true;
        }

        pub fn is1D(self: *Self) bool {
            std.debug.assert(self.headerValid);
            return (self.header.height <= 1 and self.header.depth <= 1);
        }
        pub fn is2D(self: *Self) bool {
            std.debug.assert(self.headerValid);
            return (self.header.height > 1 and self.header.depth <= 1);
        }
        pub fn is3D(self: *Self) bool {
            std.debug.assert(self.headerValid);
            return (self.header.height > 1 and self.header.depth > 1);
        }
        pub fn isCubemap(self: *Self) bool {
            std.debug.assert(self.headerValid);
            return self.header.faces == 6;
        }
        pub fn isArray(self: *Self) bool {
            std.debug.assert(self.headerValid);
            return self.header.numberOfArrayElements > 1;
        }
        /// reads the size of a particular mip map (caches the result)
        /// seekLast moves the file position even if the result was cached
        fn internalImageSizeAt(self: *Self, mipMapLevel: u4, seekLast: bool) !usize {
            std.debug.assert(self.headerValid);
            if (mipMapLevel >= self.header.numberOfMipmapLevels) return KtxError.MipMapError;
            if (seekLast == false and self.mipMapSizes[mipMapLevel] != 0) return self.mipMapSizes[mipMapLevel];

            var currentOffset = self.firstImagePos;
            var currentLevel:usize = 0;

            while (currentLevel <= mipMapLevel) : (currentLevel += 1) {
                // if we have already read this level, update seek if seekLast is set
                if (self.mipMapSizes[currentLevel] != 0) {
                    if(seekLast and currentLevel == mipMapLevel) {
                        try self.seek(self.userData, currentOffset + @sizeOf(u32));
                    }
                } else {
                    var sz8 = [4]u8{0,0,0,0};
                    try self.seek(self.userData, currentOffset);
                    if( try self.read(self.userData, &sz8) != 4) {
                        return KtxError.NotValidError;
                    }
                    var sz: u32 = @bitCast(u32, sz8);

                    // KTX v1 standard rounding rules
                    if (self.header.numberOfFaces == 6 and self.header.numberOfArrayElements == 0) {
                        sz = ((sz + 3) & ~ @as(u32,0b11)) * 6; // face padding and 6 faces
                    }
                    self.mipMaps[currentLevel] = null;
                    self.mipMapSizes[currentLevel] = sz;
                }
                // so in the really small print KTX v1 states GL_UNPACK_ALIGNMENT = 4
                // which PVR Texture Tool and I both missed at first. 
                // It means pad to 1, 2, 4, 8 so 3, 5, 6, 7 bytes sizes need rounding up!
                currentOffset += (self.mipMapSizes[currentLevel] + @sizeOf(u32) + 3) & ~@as(u32,0b11); // size + mip padding
            }
            return self.mipMapSizes[mipMapLevel];
        }
        pub fn imageSizeOf(self: *Self, mipMapLevel: u4) !usize {
            return try internalImageSizeAt(self, mipMapLevel, false);
        }
        pub fn imageDataAt(self: *Self, mipMapLevel: u4) ![]u8 {
            std.debug.assert(self.headerValid);
            if (mipMapLevel >= self.header.numberOfMipmapLevels) return KtxError.MipMapError;
            if(self.mipMaps[mipMapLevel] != null) return self.mipMaps[mipMapLevel].?;

            const size = try self.internalImageSizeAt(mipMapLevel, true);
            if(size == 0) return KtxError.MipMapError;

            self.mipMaps[mipMapLevel] = try self.allocator.alloc(u8, size);
            const bytesRead = try self.read(self.userData, self.mipMaps[mipMapLevel].?);
            if(bytesRead != self.mipMapSizes[mipMapLevel]) return KtxError.MipMapError;
            return self.mipMaps[mipMapLevel].?;
        }

    };
}

comptime {
    std.debug.assert(@sizeOf(Header) == 64);
}
