const std = @import("std");
const tif = @import("tiny_image_format");
const vfile = @import("vfile");
const tiny_ktx = @import("tiny_ktx.zig");
const assert = std.debug.assert;
const string = @import("zig_string");

pub const Flags = packed struct {
    cubemap: bool = false,
    is_clut: bool = false,
    has_extension_data: bool = false,
    has_next_image_data: bool = false,
};

pub const ImageExtension = extern struct {
    extension_name: [4]u8 align(1),
    size: u32 align(1), // size including this header

    pub fn is(self: *ImageExtension, name: []const u8) bool {
        return std.mem.eql(u8, &self.extension_name, name);
    }
};

pub const LayerExtension = extern struct {
    const MaxLayerNameBytes = 63;
    header: ImageExtension align(1),

    layer_name_size: u8,
    layer_name: [MaxLayerNameBytes]u8,

    pub fn init(name: []const u8) LayerExtension {
        var self: LayerExtension = undefined;
        std.mem.copy(u8, &self.header.extension_name, "LAYR");
        self.header.size = @sizeOf(LayerExtension);
        std.debug.assert(name.len < LayerExtension.MaxLayerNameBytes);
        self.layer_name_size = @intCast(u8, name.len);
        std.mem.copy(u8, &self.layer_name, name);
        return self;
    }
    pub fn getName(self: *const LayerExtension) []const u8 {
        return self.layer_name[0..self.layer_name_size];
    }
};

pub const ImageExtensionArray = struct {
    const MaxExtensions = 16;
    num_extensions: u8,
    extension_offsets: [MaxExtensions]usize,
    total_size: usize, // of all extension without the size of this header

    pub fn init() ImageExtensionArray {
        return ImageExtensionArray{
            .num_extensions = 0,
            .extension_offsets = undefined,
            .total_size = 0,
        };
    }

    pub fn getExtension(self: *ImageExtensionArray, index: usize) *ImageExtension {
        std.debug.assert(index < self.num_extensions);
        return @ptrCast(*ImageExtension, @ptrCast([*]u8, self) + @sizeOf(ImageExtensionArray) + self.extension_offsets[index]);
    }
};

pub const Config = struct {
    width: u32,
    height: u32 = 1,
    depth: u16 = 1,
    slices: u16 = 1,
    format: tif.Format = .R8G8B8A8_UNORM,
    _padd: u8 = 0,
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

    pub fn init(
        allocator: std.mem.Allocator,
        config: Config,
    ) !*Image {
        return initWithExtensions(allocator, config, &[0]*ImageExtension{});
    }

    pub fn initWithExtensions(allocator: std.mem.Allocator, config: Config, extensions: []*ImageExtension) !*Image {
        std.debug.assert(extensions.len < ImageExtensionArray.MaxExtensions);

        const total_extension_size = init: {
            var total: usize = 0;
            if (extensions.len > 0) {
                total += @sizeOf(ImageExtensionArray);
            } else break :init 0;
            for (extensions) |ext| {
                total += ext.size;
            }
            break :init total;
        };
        const image_size = @sizeOf(Image) + config.calculateDataSize();
        var mem = try allocator.alignedAlloc(u8, 8, image_size + total_extension_size);
        var image = @ptrCast(*Image, mem);
        image.config = config;

        // generate image extensions array if required
        if (extensions.len > 0) {
            image.config.flags.has_extension_data = true;
            var ext_array = @ptrCast(*ImageExtensionArray, @alignCast(@alignOf(*ImageExtensionArray), mem.ptr + image_size));
            ext_array.num_extensions = @intCast(u8, extensions.len);
            const base_offset = image_size + @sizeOf(ImageExtensionArray);
            var current_ext: usize = 0;
            var i: u8 = 0;
            for (extensions) |ext| {
                std.mem.copy(u8, mem[base_offset + current_ext .. base_offset + current_ext + ext.size], @ptrCast([*]u8, ext)[0..ext.size]);
                ext_array.extension_offsets[i] = current_ext;
                std.debug.assert(ext_array.getExtension(i).size == ext.size);
                current_ext += ext.size;
                i += 1;
            }
            ext_array.total_size = current_ext;
        }

        return image;
    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        var slice: []u8 = undefined;
        slice.ptr = @ptrCast([*]u8, self);
        slice.len = self.totalSize();
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
        var ktx = KtxLoader{ .user_data = file, .allocator = allocator };
        defer ktx.deinit();
        try ktx.readHeader();
        const w = ktx.header.width;
        // ktx files can have 0 to indicate a dimension isn't used
        const h = if (ktx.header.height > 1) ktx.header.height else 1;
        const d = if (ktx.header.depth > 1) ktx.header.depth else 1;
        const s = if (ktx.header.number_of_array_elements > 1) ktx.header.number_of_array_elements else 1;
        std.debug.assert(d < (1 << 16));
        std.debug.assert(s < (1 << 16));

        var image = try Image.init(allocator, Config{
            .width = w,
            .height = h,
            .depth = @intCast(u16, d),
            .slices = @intCast(u16, s),
            .format = ktx.getFormat(),
        });

        std.mem.copy(u8, image.data(u8), try ktx.imageDataAt(0));
        return image;
    }
    const open_exr = @cImport({
        @cInclude("./tinyexr.h");
    });

    pub const OpenExrError = error{
        BadVersionError,
        BadHeaderError,
        BadImageError,
    };

    pub fn fromExr(allocator: std.mem.Allocator, file: *vfile.VFile) !*Image {
        var err: [*c]u8 = undefined;

        var version = std.mem.zeroes(open_exr.EXRVersion);
        var header = std.mem.zeroes(open_exr.EXRHeader);
        var image = std.mem.zeroes(open_exr.EXRImage);

        try file.seekFromEnd(0);
        const file_len = try file.tell();
        var file_mem = try allocator.alloc(u8, file_len);
        defer allocator.free(file_mem);

        try file.seekFromStart(0);
        _ = try file.read(file_mem);

        if (open_exr.ParseEXRVersionFromMemory(@ptrCast([*c]open_exr.EXRVersion, &version), @ptrCast([*c]const u8, file_mem), file_len) != open_exr.TINYEXR_SUCCESS) {
            return OpenExrError.BadVersionError;
        }
        if (open_exr.ParseEXRHeaderFromMemory(@ptrCast([*c]open_exr.EXRHeader, &header), &version, @ptrCast([*c]const u8, file_mem), file_len, &err) != open_exr.TINYEXR_SUCCESS) {
            std.log.warn("{any}", .{err});
            return OpenExrError.BadHeaderError;
        }

        if (open_exr.LoadEXRImageFromMemory(@ptrCast([*c]open_exr.EXRImage, &image), &header, @ptrCast([*c]const u8, file_mem), file_len, &err) != open_exr.TINYEXR_SUCCESS) {
            std.log.warn("{any}", .{err});
            return OpenExrError.BadImageError;
        }
        defer _ = open_exr.FreeEXRImage(@ptrCast([*c]open_exr.EXRImage, &image));

        var stack_memory: [16 * 1024]u8 = undefined;
        var buffer_allocator = std.heap.FixedBufferAllocator.init(&stack_memory);
        var arena = std.heap.ArenaAllocator.init(buffer_allocator.allocator());
        defer arena.deinit();

        const LayerPixelTypes = enum(u8) {
            UInt32,
            Float16,
            Float32,
        };

        const Layer = struct {
            name: string.String,
            num_channels: u8,
            channels: [16]u8,
            channel_types: [16]LayerPixelTypes,
            layer_indices: [16]usize,
        };

        var layers = std.StringArrayHashMap(Layer).init(arena.allocator());

        var first_img: ?*Image = null;

        {
            var i: usize = 0;
            while (i < header.num_channels) : (i = i + 1) {
                const ch = header.channels[i];
                var full_name = string.String.init(arena.allocator());
                try full_name.concat(&ch.name);

                var segment_count: usize = 0;
                var segment_indices: [16]usize = undefined;

                var name_it = full_name.iterator();
                while (name_it.next()) |c| {
                    if (c[0] == '.') {
                        segment_indices[segment_count] = name_it.index;
                        segment_count += 1;
                    }
                }
                var channel = full_name.buffer.?[segment_indices[segment_count - 1]];
                var layer_name = string.String.init(arena.allocator());
                try layer_name.concat(full_name.buffer.?[0 .. segment_indices[segment_count - 1] - 1]);
                if (layers.contains(layer_name.str())) {
                    var channels = layers.get(layer_name.str()).?;
                    channels.channels[channels.num_channels] = channel;
                    channels.layer_indices[channels.num_channels] = i;
                    channels.num_channels = channels.num_channels + 1;
                    layers.putAssumeCapacity(layer_name.str(), channels);
                } else {
                    const channels = [_]u8{channel} ** 16;
                    const pixel_type = switch (ch.pixel_type) {
                        0 => LayerPixelTypes.UInt32,
                        1 => LayerPixelTypes.Float16,
                        2 => LayerPixelTypes.Float32,
                        else => {
                            std.log.err("ERROR: Unknown pixel type {} for layer {s}", .{ ch.pixel_type, layer_name.str() });
                            return OpenExrError.BadImageError;
                        },
                    };
                    const types = [_]LayerPixelTypes{pixel_type} ** 16;
                    const layer_indices = [_]usize{i} ** 16;
                    try layers.put(layer_name.str(), .{
                        .name = layer_name,
                        .num_channels = 1,
                        .channels = channels,
                        .channel_types = types,
                        .layer_indices = layer_indices,
                    });
                }
            }

            var format: tif.Format = .R8G8B8A8_UNORM;

            var layers_it = layers.iterator();
            while (layers_it.next()) |entry| {
                var idx_channels = [_]i8{ -1, -1, -1, -1 };
                var num_idx_channels: usize = 0;
                const l = entry.value_ptr;
                {
                    var idx_r: i8 = -1;
                    var idx_g: i8 = -1;
                    var idx_b: i8 = -1;
                    var idx_a: i8 = -1;
                    {
                        var c: usize = 0;
                        std.debug.assert(l.num_channels < 127);
                        while (c < l.num_channels) : (c += 1) {
                            const ch = l.channels[c];
                            if (ch == 'R' or ch == 'X' or ch == 'Z') {
                                idx_r = @intCast(i8, c);
                            } else if (ch == 'G') {
                                idx_g = @intCast(i8, c);
                            } else if (ch == 'B') {
                                idx_b = @intCast(i8, c);
                            } else if (ch == 'A') {
                                idx_a = @intCast(i8, c);
                            } else {
                                std.log.err("Unknown {} openexr channel", .{c});
                            }
                        }
                    }
                    if (idx_r != -1) {
                        idx_channels[num_idx_channels] = idx_r;
                        num_idx_channels += 1;
                    }
                    if (idx_g != -1) {
                        idx_channels[num_idx_channels] = idx_g;
                        num_idx_channels += 1;
                    }
                    if (idx_b != -1) {
                        idx_channels[num_idx_channels] = idx_b;
                        num_idx_channels += 1;
                    }
                    if (idx_a != -1) {
                        idx_channels[num_idx_channels] = idx_a;
                        num_idx_channels += 1;
                    }
                    {
                        var c: usize = 1;
                        while (c < num_idx_channels) : (c += 1) {
                            if (l.channel_types[c - 1] != l.channel_types[c]) {
                                std.log.warn("Only homogenous openexr layers are supported {s}", .{l.name.str()});
                                continue;
                            }
                        }
                    }
                }
                switch (num_idx_channels) {
                    1 => {
                        switch (l.channels[0]) {
                            'R', 'X', 'Z' => {
                                switch (l.channel_types[0]) {
                                    .UInt32 => {
                                        format = tif.Format.R32_UINT;
                                    },
                                    .Float16 => {
                                        format = tif.Format.R16_SFLOAT;
                                    },
                                    .Float32 => {
                                        format = tif.Format.R32_SFLOAT;
                                    },
                                }
                            },
                            else => {
                                std.log.warn("Unknown single channel {c} for {s} later, ignoring", .{ l.channels[0], l.name.str() });
                                continue;
                            },
                        }
                    },
                    2 => {
                        switch (l.channel_types[0]) {
                            .UInt32 => {
                                format = tif.Format.R32G32_UINT;
                            },
                            .Float16 => {
                                format = tif.Format.R16G16_SFLOAT;
                            },
                            .Float32 => {
                                format = tif.Format.R32G32_SFLOAT;
                            },
                        }
                    },
                    3 => {
                        switch (l.channel_types[0]) {
                            .UInt32 => {
                                format = tif.Format.R32G32B32_UINT;
                            },
                            .Float16 => {
                                format = tif.Format.R16G16B16_SFLOAT;
                            },
                            .Float32 => {
                                format = tif.Format.R32G32B32_SFLOAT;
                            },
                        }
                    },
                    4 => {
                        switch (l.channel_types[0]) {
                            .UInt32 => {
                                format = tif.Format.R32G32B32A32_UINT;
                            },
                            .Float16 => {
                                format = tif.Format.R16G16B16A16_SFLOAT;
                            },
                            .Float32 => {
                                format = tif.Format.R32G32B32A32_SFLOAT;
                            },
                        }
                    },
                    else => {
                        std.log.warn("Unknown {} channels on {s} later, ignoring", .{ num_idx_channels, entry.value_ptr.name.str() });
                        continue;
                    },
                }
                var layer_extension = LayerExtension.init(entry.value_ptr.name.str());
                var iea = [_]*ImageExtension{@ptrCast(*ImageExtension, &layer_extension)};
                var img = try Image.initWithExtensions(allocator, Config{
                    .width = @intCast(u32, image.width),
                    .height = @intCast(u32, image.height),
                    .depth = 1,
                    .slices = 1,
                    .format = format,
                }, &iea);

                // finally copy the data into the correct channels inside the image
                switch (l.channel_types[0]) {
                    .UInt32 => {
                        var out_data = img.data(u32);
                        var pixel_index: usize = 0;
                        while (pixel_index < img.config.width * img.config.height) : (pixel_index += 1) {
                            var chan: usize = 0;
                            while (chan < num_idx_channels) : (chan += 1) {
                                const li = @intCast(usize, idx_channels[chan]);
                                const ptr = @ptrCast([*]u32, @alignCast(4, image.images[l.layer_indices[li]]));
                                out_data[(pixel_index * l.num_channels) + chan] = ptr[pixel_index];
                            }
                        }
                    },
                    .Float16 => {
                        var out_data = img.data(f16);
                        var pixel_index: usize = 0;
                        while (pixel_index < img.config.width * img.config.height) : (pixel_index += 1) {
                            var chan: usize = 0;
                            while (chan < num_idx_channels) : (chan += 1) {
                                const li = @intCast(usize, idx_channels[chan]);
                                const ptr = @ptrCast([*]f16, @alignCast(4, image.images[l.layer_indices[li]]));
                                out_data[(pixel_index * l.num_channels) + chan] = ptr[pixel_index];
                            }
                        }
                    },
                    .Float32 => {
                        var out_data = img.data(f32);
                        var pixel_index: usize = 0;
                        while (pixel_index < img.config.width * img.config.height) : (pixel_index += 1) {
                            var chan: usize = 0;
                            while (chan < num_idx_channels) : (chan += 1) {
                                const li = @intCast(usize, idx_channels[chan]);
                                const ptr = @ptrCast([*]f32, @alignCast(4, image.images[l.layer_indices[li]]));
                                out_data[(pixel_index * l.num_channels) + chan] = ptr[pixel_index];
                            }
                        }
                    },
                }

                if (first_img == null) {
                    first_img = img;
                } else {
                    first_img = try destructiveJoin(allocator, first_img.?, img);
                }
            }
        }
        if (first_img == null) {
            return OpenExrError.BadImageError;
        }

        return first_img.?;
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

    pub fn getExtensions(self: *Image) ?*ImageExtensionArray {
        if (!self.config.flags.has_extension_data) return null;

        return @ptrCast(*ImageExtensionArray, @alignCast(8, @ptrCast([*]u8, self) + @sizeOf(Image) + self.config.calculateDataSize()));
    }

    pub fn next(self: *Image) ?*Image {
        if (self.config.flags.has_next_image_data == true) {
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

    // size of this image and its extensions only (without any following in the chain)
    pub fn sizeInBytes(self: *Image) usize {
        const total_extension_size = init: {
            if (self.config.flags.has_extension_data) {
                break :init @sizeOf(ImageExtensionArray) + self.getExtensions().?.total_size;
            } else break :init 0;
        };
        return @sizeOf(Image) + self.config.calculateDataSize() + total_extension_size;
    }

    /// join to images into a single chain
    pub fn join(allocator: std.mem.Allocator, a: *Image, b: *Image) !*Image {
        var mem = try allocator.alignedAlloc(u8, 8, a.totalSize() + b.totalSize());
        std.mem.copy(u8, mem[0..a.totalSize()], @ptrCast([*]u8, a)[0..a.totalSize()]);
        std.mem.copy(u8, mem[a.totalSize()..], @ptrCast([*]u8, b)[0..b.totalSize()]);

        var ret = @ptrCast(*Image, mem);
        var img: ?*Image = ret;
        while (img) |image| {
            // if end of original a, mark a has next and we are done
            if (image.config.flags.has_next_image_data == false) {
                image.config.flags.has_next_image_data = true;
                return ret;
            }
            img = image.next();
        }

        unreachable;
    }

    pub fn destructiveJoin(allocator: std.mem.Allocator, a: *Image, b: *Image) !*Image {
        const img = try join(allocator, a, b);
        a.deinit(allocator);
        b.deinit(allocator);
        return img;
    }
    pub fn dumpInfo(self: *Image) void {
        var image: ?*Image = self;
        while (image) |i| {
            var layer: ?*const LayerExtension = null;
            if (i.config.flags.has_extension_data) {
                const extensions = i.getExtensions();
                std.debug.assert(extensions != null);

                var k: usize = 0;
                while (k < extensions.?.num_extensions) : (k += 1) {
                    const ext = extensions.?.getExtension(k);
                    if (ext.is("LAYR")) {
                        layer = @ptrCast(*const LayerExtension, ext);
                    }
                }

                if (layer != null) {
                    std.log.info("{s}: Size {} format: {s} ", .{ layer.?.getName(), i.sizeInBytes(), tif.Query.FormatToName(i.config.format) });
                } else {
                    std.log.info("Size: {} format: {s}", .{ i.sizeInBytes(), tif.Query.FormatToName(i.config.format) });
                }
            } else {
                std.log.info("Size: {} format: {s}", .{ i.sizeInBytes(), tif.Query.FormatToName(i.config.format) });
            }

            image = i.next();
        }
        std.log.info("totalSize: {}", .{self.totalSize()});
    }
};

comptime {
    std.debug.assert(@sizeOf(Flags) == 1);
    std.debug.assert(@sizeOf(Image) == 16);
    std.debug.assert(@sizeOf(ImageExtension) == 8);
}
