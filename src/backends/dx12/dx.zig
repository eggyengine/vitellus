pub const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "");
    @cUndef("STRICT");
    @cInclude("d3d12.h");
    @cInclude("dxgi1_6.h");
});
