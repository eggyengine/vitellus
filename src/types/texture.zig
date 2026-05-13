const std = @import("std");
const def = @import("def.zig");
const candler = @import("candler");
const hal = @import("../backends/hal.zig");

const log = std.log.scoped(.vitellus_texture);

pub const Texture = struct {
    width: def.IntegerCoordinateOut,
    height: def.IntegerCoordinateOut,
    depthOrArrayLayers: def.IntegerCoordinateOut,
    mipLevelCount: def.IntegerCoordinateOut,
    sampleCount: def.Size32Out,
    dimension: Dimension,
    format: Format,
    usage: UsageFlags,
    textureBindingViewDimension: ?View.Dimension,

    pub const UsageFlags = def.TextureUsageFlags;

    pub const Extent3D = struct {
        width: def.IntegerCoordinate,
        height: def.IntegerCoordinate = 1,
        depthOrArrayLayers: def.IntegerCoordinate = 1,
    };

    pub const Usage = packed struct(u32) {
        copy_src: bool = false,
        copy_dst: bool = false,
        texture_binding: bool = false,
        storage_binding: bool = false,
        render_attachment: bool = false,
        transient_attachment: bool = false,

        _: u26 = 0,

        pub const COPY_SRC: def.FlagsConstant = 0x01;
        pub const COPY_DST: def.FlagsConstant = 0x02;
        pub const TEXTURE_BINDING: def.FlagsConstant = 0x04;
        pub const STORAGE_BINDING: def.FlagsConstant = 0x08;
        pub const RENDER_ATTACHMENT: def.FlagsConstant = 0x10;
        pub const TRANSIENT_ATTACHMENT: def.FlagsConstant = 0x20;

        pub fn fromFlags(flags: UsageFlags) Usage {
            return @bitCast(flags);
        }

        pub fn toFlags(self: Usage) UsageFlags {
            return @bitCast(self);
        }
    };

    pub const View = struct {
        pub const Descriptor = struct {
            label: ?[*:0]const u8 = null,
            format: ?Format = null,
            dimension: ?Texture.View.Dimension = null,
            usage: UsageFlags = 0,
            aspect: Texture.Aspect = .all,
            baseMipLevel: def.IntegerCoordinate = 0,
            mipLevelCount: ?def.IntegerCoordinate = null,
            baseArrayLayer: def.IntegerCoordinate = 0,
            arrayLayerCount: ?def.IntegerCoordinate = null,
            swizzle: []const u8 = "rgba",
        };

        pub const Dimension = enum {
            @"1d",
            @"2d",
            @"2d-array",
            cube,
            @"cube-array",
            @"3d",
        };
    };

    pub const Aspect = enum {
        all,
        stencil_only,
        depth_only,
    };

    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        size: Extent3D,
        mipLevelCount: def.IntegerCoordinate = 1,
        sampleCount: def.Size32 = 1,
        dimension: Dimension = .@"2d",
        format: Format,
        usage: UsageFlags,
        viewFormats: []const Format = &.{},
        textureBindingViewDimension: ?View.Dimension = null,
    };

    pub const Dimension = enum {
        @"1d",
        @"2d",
        @"3d",
    };

    pub fn deinit(self: *Texture) void {
        _ = self;
    }

    pub fn createView(self: *Texture, descriptor: Texture.View.Descriptor) !*Texture.View {
        _ = self;
        _ = descriptor;
        return error.NotImplemented;
    }

    pub fn present(self: *Texture) void {
        _ = self;
    }

    pub const Format = enum {
        // 8-bit formats
        r8unorm,
        r8snorm,
        r8uint,
        r8sint,

        // 16-bit formats
        r16unorm,
        r16snorm,
        r16uint,
        r16sint,
        r16float,
        rg8unorm,
        rg8snorm,
        rg8uint,
        rg8sint,

        // 32-bit formats
        r32uint,
        r32sint,
        r32float,
        rg16unorm,
        rg16snorm,
        rg16uint,
        rg16sint,
        rg16float,
        rgba8unorm,
        rgba8unorm_srgb,
        rgba8snorm,
        rgba8uint,
        rgba8sint,
        bgra8unorm,
        bgra8unorm_srgb,

        // Packed 32-bit formats
        rgb9e5ufloat,
        rgb10a2uint,
        rgb10a2unorm,
        rg11b10ufloat,

        // 64-bit formats
        rg32uint,
        rg32sint,
        rg32float,
        rgba16unorm,
        rgba16snorm,
        rgba16uint,
        rgba16sint,
        rgba16float,

        // 128-bit formats
        rgba32uint,
        rgba32sint,
        rgba32float,

        // Depth/stencil formats
        stencil8,
        depth16unorm,
        depth24plus,
        depth24plus_stencil8,
        depth32float,

        // "depth32float-stencil8" feature
        depth32float_stencil8,

        // BC compressed formats
        bc1_rgba_unorm,
        bc1_rgba_unorm_srgb,
        bc2_rgba_unorm,
        bc2_rgba_unorm_srgb,
        bc3_rgba_unorm,
        bc3_rgba_unorm_srgb,
        bc4_r_unorm,
        bc4_r_snorm,
        bc5_rg_unorm,
        bc5_rg_snorm,
        bc6h_rgb_ufloat,
        bc6h_rgb_float,
        bc7_rgba_unorm,
        bc7_rgba_unorm_srgb,

        // ETC2 compressed formats
        etc2_rgb8unorm,
        etc2_rgb8unorm_srgb,
        etc2_rgb8a1unorm,
        etc2_rgb8a1unorm_srgb,
        etc2_rgba8unorm,
        etc2_rgba8unorm_srgb,
        eac_r11unorm,
        eac_r11snorm,
        eac_rg11unorm,
        eac_rg11snorm,

        // ASTC compressed formats
        astc_4x4_unorm,
        astc_4x4_unorm_srgb,
        astc_5x4_unorm,
        astc_5x4_unorm_srgb,
        astc_5x5_unorm,
        astc_5x5_unorm_srgb,
        astc_6x5_unorm,
        astc_6x5_unorm_srgb,
        astc_6x6_unorm,
        astc_6x6_unorm_srgb,
        astc_8x5_unorm,
        astc_8x5_unorm_srgb,
        astc_8x6_unorm,
        astc_8x6_unorm_srgb,
        astc_8x8_unorm,
        astc_8x8_unorm_srgb,
        astc_10x5_unorm,
        astc_10x5_unorm_srgb,
        astc_10x6_unorm,
        astc_10x6_unorm_srgb,
        astc_10x8_unorm,
        astc_10x8_unorm_srgb,
        astc_10x10_unorm,
        astc_10x10_unorm_srgb,
        astc_12x10_unorm,
        astc_12x10_unorm_srgb,
        astc_12x12_unorm,
        astc_12x12_unorm_srgb,

        pub fn toString(self: Format) []const u8 {
            return switch (self) {
                .r8unorm => "r8unorm",
                .r8snorm => "r8snorm",
                .r8uint => "r8uint",
                .r8sint => "r8sint",

                .r16unorm => "r16unorm",
                .r16snorm => "r16snorm",
                .r16uint => "r16uint",
                .r16sint => "r16sint",
                .r16float => "r16float",
                .rg8unorm => "rg8unorm",
                .rg8snorm => "rg8snorm",
                .rg8uint => "rg8uint",
                .rg8sint => "rg8sint",

                .r32uint => "r32uint",
                .r32sint => "r32sint",
                .r32float => "r32float",
                .rg16unorm => "rg16unorm",
                .rg16snorm => "rg16snorm",
                .rg16uint => "rg16uint",
                .rg16sint => "rg16sint",
                .rg16float => "rg16float",
                .rgba8unorm => "rgba8unorm",
                .rgba8unorm_srgb => "rgba8unorm-srgb",
                .rgba8snorm => "rgba8snorm",
                .rgba8uint => "rgba8uint",
                .rgba8sint => "rgba8sint",
                .bgra8unorm => "bgra8unorm",
                .bgra8unorm_srgb => "bgra8unorm-srgb",

                .rgb9e5ufloat => "rgb9e5ufloat",
                .rgb10a2uint => "rgb10a2uint",
                .rgb10a2unorm => "rgb10a2unorm",
                .rg11b10ufloat => "rg11b10ufloat",

                .rg32uint => "rg32uint",
                .rg32sint => "rg32sint",
                .rg32float => "rg32float",
                .rgba16unorm => "rgba16unorm",
                .rgba16snorm => "rgba16snorm",
                .rgba16uint => "rgba16uint",
                .rgba16sint => "rgba16sint",
                .rgba16float => "rgba16float",

                .rgba32uint => "rgba32uint",
                .rgba32sint => "rgba32sint",
                .rgba32float => "rgba32float",

                .stencil8 => "stencil8",
                .depth16unorm => "depth16unorm",
                .depth24plus => "depth24plus",
                .depth24plus_stencil8 => "depth24plus-stencil8",
                .depth32float => "depth32float",
                .depth32float_stencil8 => "depth32float-stencil8",

                .bc1_rgba_unorm => "bc1-rgba-unorm",
                .bc1_rgba_unorm_srgb => "bc1-rgba-unorm-srgb",
                .bc2_rgba_unorm => "bc2-rgba-unorm",
                .bc2_rgba_unorm_srgb => "bc2-rgba-unorm-srgb",
                .bc3_rgba_unorm => "bc3-rgba-unorm",
                .bc3_rgba_unorm_srgb => "bc3-rgba-unorm-srgb",
                .bc4_r_unorm => "bc4-r-unorm",
                .bc4_r_snorm => "bc4-r-snorm",
                .bc5_rg_unorm => "bc5-rg-unorm",
                .bc5_rg_snorm => "bc5-rg-snorm",
                .bc6h_rgb_ufloat => "bc6h-rgb-ufloat",
                .bc6h_rgb_float => "bc6h-rgb-float",
                .bc7_rgba_unorm => "bc7-rgba-unorm",
                .bc7_rgba_unorm_srgb => "bc7-rgba-unorm-srgb",

                .etc2_rgb8unorm => "etc2-rgb8unorm",
                .etc2_rgb8unorm_srgb => "etc2-rgb8unorm-srgb",
                .etc2_rgb8a1unorm => "etc2-rgb8a1unorm",
                .etc2_rgb8a1unorm_srgb => "etc2-rgb8a1unorm-srgb",
                .etc2_rgba8unorm => "etc2-rgba8unorm",
                .etc2_rgba8unorm_srgb => "etc2-rgba8unorm-srgb",
                .eac_r11unorm => "eac-r11unorm",
                .eac_r11snorm => "eac-r11snorm",
                .eac_rg11unorm => "eac-rg11unorm",
                .eac_rg11snorm => "eac-rg11snorm",

                .astc_4x4_unorm => "astc-4x4-unorm",
                .astc_4x4_unorm_srgb => "astc-4x4-unorm-srgb",
                .astc_5x4_unorm => "astc-5x4-unorm",
                .astc_5x4_unorm_srgb => "astc-5x4-unorm-srgb",
                .astc_5x5_unorm => "astc-5x5-unorm",
                .astc_5x5_unorm_srgb => "astc-5x5-unorm-srgb",
                .astc_6x5_unorm => "astc-6x5-unorm",
                .astc_6x5_unorm_srgb => "astc-6x5-unorm-srgb",
                .astc_6x6_unorm => "astc-6x6-unorm",
                .astc_6x6_unorm_srgb => "astc-6x6-unorm-srgb",
                .astc_8x5_unorm => "astc-8x5-unorm",
                .astc_8x5_unorm_srgb => "astc-8x5-unorm-srgb",
                .astc_8x6_unorm => "astc-8x6-unorm",
                .astc_8x6_unorm_srgb => "astc-8x6-unorm-srgb",
                .astc_8x8_unorm => "astc-8x8-unorm",
                .astc_8x8_unorm_srgb => "astc-8x8-unorm-srgb",
                .astc_10x5_unorm => "astc-10x5-unorm",
                .astc_10x5_unorm_srgb => "astc-10x5-unorm-srgb",
                .astc_10x6_unorm => "astc-10x6-unorm",
                .astc_10x6_unorm_srgb => "astc-10x6-unorm-srgb",
                .astc_10x8_unorm => "astc-10x8-unorm",
                .astc_10x8_unorm_srgb => "astc-10x8-unorm-srgb",
                .astc_10x10_unorm => "astc-10x10-unorm",
                .astc_10x10_unorm_srgb => "astc-10x10-unorm-srgb",
                .astc_12x10_unorm => "astc-12x10-unorm",
                .astc_12x10_unorm_srgb => "astc-12x10-unorm-srgb",
                .astc_12x12_unorm => "astc-12x12-unorm",
                .astc_12x12_unorm_srgb => "astc-12x12-unorm-srgb",
            };
        }

        pub fn is_srgb(self: Format) bool {
            return switch (self) {
                .rgba8unorm_srgb,
                .bgra8unorm_srgb,
                .bc1_rgba_unorm_srgb,
                .bc2_rgba_unorm_srgb,
                .bc3_rgba_unorm_srgb,
                .bc7_rgba_unorm_srgb,
                .etc2_rgb8unorm_srgb,
                .etc2_rgb8a1unorm_srgb,
                .etc2_rgba8unorm_srgb,
                .astc_4x4_unorm_srgb,
                .astc_5x4_unorm_srgb,
                .astc_5x5_unorm_srgb,
                .astc_6x5_unorm_srgb,
                .astc_6x6_unorm_srgb,
                .astc_8x5_unorm_srgb,
                .astc_8x6_unorm_srgb,
                .astc_8x8_unorm_srgb,
                .astc_10x5_unorm_srgb,
                .astc_10x6_unorm_srgb,
                .astc_10x8_unorm_srgb,
                .astc_10x10_unorm_srgb,
                .astc_12x10_unorm_srgb,
                .astc_12x12_unorm_srgb,
                => true,
                else => false,
            };
        }
    };
};

pub const ExternalTexture = struct {
    pub const Descriptor = struct {
        label: ?[*:0]const u8 = null,
        source: Source,
        colorSpace: def.PredefinedColorSpace = .srgb,
    };

    pub const Source = union(enum) {
        html_video_element: *anyopaque,
        video_frame: *anyopaque,
    };
};

pub const Surface = struct {
    backend: hal.Surface,
    window: candler.WindowHandle,
    display: candler.DisplayHandle,
    configuration: ?Configuration = null,

    pub const CreateError = error{
        HandleUnavailable,
        UnsupportedHandle,
        BackendFailed,
    };

    pub const AlphaMode = enum {
        @"opaque",
        premultiplied,
    };

    pub const PresentMode = enum {
        fifo,
        fifo_relaxed,
        immediate,
        mailbox,
    };

    pub const Capabilities = struct {
        formats: []const Texture.Format,
        present_modes: []const PresentMode,
        alpha_modes: []const AlphaMode,
    };

    pub const Configuration = struct {
        device: ?*@import("gpu.zig").Device = null,
        format: Texture.Format,
        usage: Texture.UsageFlags = Texture.Usage.RENDER_ATTACHMENT,
        viewFormats: []const Texture.Format = &.{},
        colorSpace: def.PredefinedColorSpace = .srgb,
        alphaMode: AlphaMode = .@"opaque",
        width: def.IntegerCoordinate,
        height: def.IntegerCoordinate,
        presentMode: PresentMode = .fifo,
        desiredMaximumFrameLatency: def.Size32 = 2,
    };

    pub const CurrentSurfaceTexture = union(enum) {
        success: Texture,
        suboptimal: Texture,
        timeout,
        occluded,
        validation,
        outdated,
        lost,
    };

    pub fn init(backend: hal.Surface, window: candler.WindowHandle, display: candler.DisplayHandle) Surface {
        log.debug("initializing surface wrapper: window={s} display={s}", .{
            @tagName(window.asRaw()),
            @tagName(display.asRaw()),
        });
        return .{
            .backend = backend,
            .window = window,
            .display = display,
        };
    }

    pub fn deinit(self: *@This()) void {
        log.debug("deinitializing surface wrapper", .{});
        self.backend.destroy();
    }

    pub fn getCapabilities(self: *const @This(), adapter: *const @import("gpu.zig").Adapter) Capabilities {
        log.debug("getting surface capabilities", .{});
        return self.backend.getCapabilities(adapter.backend);
    }

    pub fn getDefaultConfig(
        self: *const @This(),
        adapter: *const @import("gpu.zig").Adapter,
        width: def.IntegerCoordinate,
        height: def.IntegerCoordinate,
    ) ?Configuration {
        const caps = self.getCapabilities(adapter);
        if (caps.formats.len == 0 or caps.present_modes.len == 0 or caps.alpha_modes.len == 0) {
            return null;
        }

        var format = caps.formats[0];
        for (caps.formats) |candidate| {
            if (candidate.is_srgb()) {
                format = candidate;
                break;
            }
        }

        return .{
            .format = format,
            .width = width,
            .height = height,
            .presentMode = caps.present_modes[0],
            .alphaMode = caps.alpha_modes[0],
        };
    }

    pub fn configure(self: *@This(), device: *@import("gpu.zig").Device, configuration: Configuration) void {
        log.debug("configuring surface: format={s} size={}x{}", .{
            @tagName(configuration.format),
            configuration.width,
            configuration.height,
        });
        var resolved = configuration;
        resolved.device = device;
        self.backend.configure(device.backend, resolved);
        self.configuration = resolved;
    }

    pub fn unconfigure(self: *@This()) void {
        log.debug("unconfiguring surface", .{});
        self.backend.unconfigure();
        self.configuration = null;
    }

    pub fn getConfiguration(self: *@This()) ?Configuration {
        return self.configuration;
    }

    pub fn getCurrentTexture(self: *@This()) !CurrentSurfaceTexture {
        log.debug("getting current surface texture", .{});
        return try self.backend.getCurrentTexture();
    }
};

pub const TexelCopyBufferLayout = struct {
    offset: def.Size64 = 0,
    bytesPerRow: ?def.Size32 = null,
    rowsPerImage: ?def.Size32 = null,
};

pub const TexelCopyBufferInfo = struct {
    buffer: *@import("buffer.zig").Buffer,
    offset: def.Size64 = 0,
    bytesPerRow: ?def.Size32 = null,
    rowsPerImage: ?def.Size32 = null,
};

pub const TexelCopyTextureInfo = struct {
    texture: *Texture,
    mipLevel: def.IntegerCoordinate = 0,
    origin: def.Origin3D = .{},
    aspect: Texture.Aspect = .all,
};

pub const CopyExternalImageDestInfo = struct {
    texture: *Texture,
    mipLevel: def.IntegerCoordinate = 0,
    origin: def.Origin3D = .{},
    aspect: Texture.Aspect = .all,
    colorSpace: def.PredefinedColorSpace = .srgb,
    premultipliedAlpha: bool = false,
};

pub const CopyExternalImageSourceInfo = struct {
    source: def.ExternalImageSource,
    origin: def.Origin2D = .{},
    flipY: bool = false,
};

pub const CanvasContext = struct {
    canvas: Canvas,
    configuration: ?Configuration = null,

    pub const Canvas = union(enum) {
        html_canvas_element: *anyopaque,
        offscreen_canvas: *anyopaque,
    };

    pub const AlphaMode = enum {
        @"opaque",
        premultiplied,
    };

    pub const ToneMappingMode = enum {
        standard,
        extended,
    };

    pub const ToneMapping = struct {
        mode: ToneMappingMode = .standard,
    };

    pub const Configuration = struct {
        device: *@import("gpu.zig").Device,
        format: Texture.Format,
        usage: Texture.UsageFlags = Texture.Usage.RENDER_ATTACHMENT,
        viewFormats: []const Texture.Format = &.{},
        colorSpace: def.PredefinedColorSpace = .srgb,
        toneMapping: ToneMapping = .{},
        alphaMode: AlphaMode = .@"opaque",
    };

    pub fn configure(self: *@This(), configuration: Configuration) void {
        self.configuration = configuration;
    }

    pub fn unconfigure(self: *@This()) void {
        self.configuration = null;
    }

    pub fn getConfiguration(self: *@This()) ?Configuration {
        return self.configuration;
    }

    pub fn getCurrentTexture(self: *@This()) Texture {
        _ = self;
        return undefined;
    }
};
