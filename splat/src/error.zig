const c = @import("spirv_cross");

pub const SPIRVcError = error{
    /// The SPIR-V is invalid. Should have been caught by validation ideally.
    InvalidSpirv,
    /// The SPIR-V might be valid or invalid, but SPIRV-Cross currently cannot
    /// correctly translate this to the target language.
    UnsupportedSpirv,
    /// A memory allocation (new / malloc) failed.
    OutOfMemory,
    /// An invalid argument was passed to the API.
    InvalidArgument,

    UnknownError,
};

pub fn check(result: c_int) SPIRVcError!void {
    return switch (result) {
        c.SPVC_SUCCESS => {},
        c.SPVC_ERROR_INVALID_SPIRV => error.InvalidSpirv,
        c.SPVC_ERROR_UNSUPPORTED_SPIRV => error.UnsupportedSpirv,
        c.SPVC_ERROR_OUT_OF_MEMORY => error.OutOfMemory,
        c.SPVC_ERROR_INVALID_ARGUMENT => error.InvalidArgument,
        else => error.UnknownError,
    };
}
