const std = @import("std");
const gl = @import("tiny_ktx_gl.zig");
const tif = @import("tiny_image_format");

pub const KtxError = error{
    NotValidError,
    UnsupportedError,
    MipMapError,
};

const Header = struct {
    identifier: [12]u8,
    endianness: u32,
    gl_type: gl.Type,
    gl_type_size: u32,
    gl_format: gl.GlFormat,
    gl_internal_format: gl.IntFormat,
    gl_base_internal_format: gl.IntFormat,
    width: u32,
    height: u32,
    depth: u32,
    number_of_array_elements: u32,
    number_of_faces: u32,
    number_of_mip_map_levels: u32,
    bytes_of_key_value_data: u32,
};
const identifier = [12]u8{ 0xAB, 0x4B, 0x54, 0x58, 0x20, 0x31, 0x31, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A };

pub fn Loader(comptime func_data: type, comptime readFn: fn (user_data: func_data, buffer: []u8) anyerror!usize, comptime seekFn: fn (user_data: func_data, offset: u64) anyerror!void, comptime tellFn: fn (user_data: func_data) anyerror!usize) type {
    return struct {
        const Self = @This();
        const MaxMipMapLevels = 4;
        // must be provided by callee
        user_data: func_data,
        allocator: std.mem.Allocator,

        // filled when the header is read
        header_pos: usize = undefined,
        first_image_pos: usize = undefined,
        header: Header = undefined,
        header_valid: bool = false,
        same_endian: bool = false,
        format: tif.Format = .UNDEFINED,
        key_value_data: []u8 = undefined,

        // filled when mipmaps are read
        mip_map_sizes: [MaxMipMapLevels]u32 = [_]u32{0} ** MaxMipMapLevels,
        mip_maps: [MaxMipMapLevels]?[]u8 = [_]?[]u8{null} ** MaxMipMapLevels,

        comptime read: *const fn (data: func_data, buffer: []u8) anyerror!usize = readFn,
        comptime seek: *const fn (data: func_data, offset: u64) anyerror!void = seekFn,
        comptime tell: *const fn (data: func_data) anyerror!usize = tellFn,

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.key_value_data);
            for (self.mip_maps) |level| {
                if (level != null) self.allocator.free(level.?);
            }
        }

        pub fn readHeader(self: *Self) !void {
            const same_endian = 0x04030201;
            const different_endian = 0x01020304;
            self.header_pos = try self.tell(self.user_data);
            _ = try self.read(self.user_data, @ptrCast([*]u8, &self.header)[0..@sizeOf(Header)]);
            if (std.mem.eql(u8, &self.header.identifier, &identifier) == false) {
                return KtxError.NotValidError;
            }
            if (self.header.endianness == same_endian) {
                self.same_endian = true;
            } else if (self.header.endianness == different_endian) {
                self.same_endian = false;
            } else {
                // corrupt or middle endian platform??
                return KtxError.NotValidError;
            }

            if (self.header.number_of_faces != 1 and self.header.number_of_faces != 6) {
                return KtxError.UnsupportedError;
            }

            self.key_value_data = try self.allocator.alloc(u8, self.header.bytes_of_key_value_data);
            _ = try self.read(self.user_data, self.key_value_data);

            self.first_image_pos = try self.tell(self.user_data);
            self.format = gl.FromGl(.{
                .gltype = self.header.gl_type,
                .format = self.header.gl_format,
                .intformat = self.header.gl_internal_format,
            });
            self.header_valid = true;
        }

        pub fn getFormat(self: *Self) tif.Format {
            std.debug.assert(self.header_valid);
            return gl.FromGl(gl.Format{ .gltype = self.header.gl_type, .format = self.header.gl_format, .intformat = self.header.gl_internal_format });
        }

        pub fn is1D(self: *Self) bool {
            std.debug.assert(self.header_valid);
            return (self.header.height <= 1 and self.header.depth <= 1);
        }
        pub fn is2D(self: *Self) bool {
            std.debug.assert(self.header_valid);
            return (self.header.height > 1 and self.header.depth <= 1);
        }
        pub fn is3D(self: *Self) bool {
            std.debug.assert(self.header_valid);
            return (self.header.height > 1 and self.header.depth > 1);
        }
        pub fn isCubemap(self: *Self) bool {
            std.debug.assert(self.header_valid);
            return self.header.faces == 6;
        }
        pub fn isArray(self: *Self) bool {
            std.debug.assert(self.header_valid);
            return self.header.numberOfArrayElements > 1;
        }
        /// reads the size of a particular mip map (caches the result)
        /// seekLast moves the file position even if the result was cached
        fn internalImageSizeAt(self: *Self, mip_map_level: u4, seek_last: bool) !usize {
            std.debug.assert(self.header_valid);
            if (mip_map_level >= self.header.number_of_mip_map_levels) return KtxError.MipMapError;
            if (seek_last == false and self.mip_map_sizes[mip_map_level] != 0) return self.mip_map_sizes[mip_map_level];

            var current_offset = self.first_image_pos;
            var current_level: usize = 0;

            while (current_level <= mip_map_level) : (current_level += 1) {
                // if we have already read this level, update seek if seekLast is set
                if (self.mip_map_sizes[current_level] != 0) {
                    if (seek_last and current_level == mip_map_level) {
                        try self.seek(self.user_data, current_offset + @sizeOf(u32));
                    }
                } else {
                    var sz8 = [4]u8{ 0, 0, 0, 0 };
                    try self.seek(self.user_data, current_offset);
                    if (try self.read(self.user_data, &sz8) != 4) {
                        return KtxError.NotValidError;
                    }
                    var sz: u32 = @bitCast(u32, sz8);

                    // KTX v1 standard rounding rules
                    if (self.header.number_of_faces == 6 and self.header.number_of_array_elements == 0) {
                        sz = ((sz + 3) & ~@as(u32, 0b11)) * 6; // face padding and 6 faces
                    }
                    self.mip_map_sizes[current_level] = sz;
                }
                // so in the really small print KTX v1 states GL_UNPACK_ALIGNMENT = 4
                // which PVR Texture Tool and I both missed at first.
                // It means pad to 1, 2, 4, 8 so 3, 5, 6, 7 bytes sizes need rounding up!
                current_offset += (self.mip_map_sizes[current_level] + @sizeOf(u32) + 3) & ~@as(u32, 0b11); // size + mip padding
            }
            return self.mip_map_sizes[mip_map_level];
        }
        pub fn imageSizeOf(self: *Self, mip_map_level: u4) !usize {
            return try internalImageSizeAt(self, mip_map_level, false);
        }
        pub fn imageDataAt(self: *Self, mip_map_level: u4) ![]u8 {
            std.debug.assert(self.header_valid);
            if (mip_map_level >= self.header.number_of_mip_map_levels) return KtxError.MipMapError;
            if (self.mip_maps[mip_map_level] != null) return self.mip_maps[mip_map_level].?;

            const size = try self.internalImageSizeAt(mip_map_level, true);
            if (size == 0) return KtxError.MipMapError;

            self.mip_maps[mip_map_level] = try self.allocator.alloc(u8, size);
            const bytes_read = try self.read(self.user_data, self.mip_maps[mip_map_level].?);
            if (bytes_read != self.mip_map_sizes[mip_map_level]) return KtxError.MipMapError;
            return self.mip_maps[mip_map_level].?;
        }
    };
}

comptime {
    std.debug.assert(@sizeOf(Header) == 64);
}
