pub const BufferDynamicOffset = u32;
pub const StencilValue = u32;
pub const SampleMask = u32;
pub const DepthBias = i32;

pub const Size64 = u64;
pub const IntegerCoordinate = u32;
pub const Index32 = u32;
pub const Size32 = u32;
pub const SignedOffset32 = i32;

pub const Size64Out = u64;
pub const IntegerCoordinateOut = u32;
pub const Size32Out = u32;

pub const FlagsConstant = u32;
pub const BufferUsageFlags = u32;
pub const TextureUsageFlags = u32;
pub const ShaderStageFlags = u32;
pub const MapModeFlags = u32;
pub const ColorWriteFlags = u32;

pub const ArrayBuffer = []u8;
pub const AllowSharedBufferSource = []const u8;

pub const ColorDict = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64,
};

pub const Color = union(enum) {
    sequence: []const f64,
    dict: ColorDict,
};

pub const Origin2D = struct {
    x: IntegerCoordinate = 0,
    y: IntegerCoordinate = 0,
};

pub const Origin3D = struct {
    x: IntegerCoordinate = 0,
    y: IntegerCoordinate = 0,
    z: IntegerCoordinate = 0,
};

pub const PredefinedColorSpace = enum {
    srgb,
    @"display-p3",
};

pub const ExternalImageSource = union(enum) {
    image_bitmap: *anyopaque,
    image_data: *anyopaque,
    html_image_element: *anyopaque,
    html_video_element: *anyopaque,
    video_frame: *anyopaque,
    html_canvas_element: *anyopaque,
    offscreen_canvas: *anyopaque,
};

pub const ObjectBase = struct {
    label: ?[*:0]const u8 = null,
};

pub const ObjectDescriptorBase = struct {
    label: ?[*:0]const u8 = null,
};
