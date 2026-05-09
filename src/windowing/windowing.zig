const candler = @import("candler");

pub const Window = struct {
    window_handle: candler.HasWindowHandle,
    display_handle: candler.HasDisplayHandle,
};
