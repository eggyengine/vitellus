const candler = @import("candler");

pub const Window = struct {
    display_handle: candler.HasDisplayHandle,
    window_handle: candler.HasWindowHandle,
};
