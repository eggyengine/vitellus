const candler = @import("candler");

pub const Handles = struct {
    window: candler.WindowHandle,
    display: ?candler.DisplayHandle = null,
};
