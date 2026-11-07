const candler = @import("candler");

/// The middle-ground for window<->vitellus communication.
///
/// Using [candler](https://github.com/eggyengine/candler), it allows platform-specific
/// window handles. It's really just a common interface.
pub const Window = struct {
    display_handle: candler.HasDisplayHandle,
    window_handle: candler.HasWindowHandle,
};
