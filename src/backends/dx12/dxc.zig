//! Minimal ABI declarations for the interfaces used from dxcompiler.dll.
//!
//! The official `dxcapi.h` is a C++ COM header and cannot be translated by
//! Zig's C importer, so the small stable ABI surface used by Vitellus is
//! declared directly here.

const windows = @import("std").os.windows;

pub const HRESULT = i32;
pub const GUID = windows.GUID;
pub const DXC_CP_UTF8: u32 = 65001;

pub const DxcBuffer = extern struct {
    Ptr: ?*const anyopaque,
    Size: usize,
    Encoding: u32,
};

pub const IDxcBlob = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IDxcBlob, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDxcBlob) callconv(.winapi) u32,
        Release: *const fn (*IDxcBlob) callconv(.winapi) u32,
        GetBufferPointer: *const fn (*IDxcBlob) callconv(.winapi) ?*anyopaque,
        GetBufferSize: *const fn (*IDxcBlob) callconv(.winapi) usize,
    };
};

pub const IDxcResult = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IDxcResult, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDxcResult) callconv(.winapi) u32,
        Release: *const fn (*IDxcResult) callconv(.winapi) u32,
        GetStatus: *const fn (*IDxcResult, *HRESULT) callconv(.winapi) HRESULT,
        GetResult: *const fn (*IDxcResult, *?*IDxcBlob) callconv(.winapi) HRESULT,
        GetErrorBuffer: *const fn (*IDxcResult, *?*IDxcBlob) callconv(.winapi) HRESULT,
    };
};

pub const IDxcCompiler3 = extern struct {
    lpVtbl: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (*IDxcCompiler3, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const fn (*IDxcCompiler3) callconv(.winapi) u32,
        Release: *const fn (*IDxcCompiler3) callconv(.winapi) u32,
        Compile: *const fn (
            *IDxcCompiler3,
            *const DxcBuffer,
            [*]const [*:0]const u16,
            u32,
            ?*anyopaque,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
        Disassemble: *const fn (
            *IDxcCompiler3,
            *const DxcBuffer,
            *const GUID,
            *?*anyopaque,
        ) callconv(.winapi) HRESULT,
    };
};

pub const CLSID_DxcCompiler = GUID{
    .Data1 = 0x73e22d93,
    .Data2 = 0xe6ce,
    .Data3 = 0x47f3,
    .Data4 = .{ 0xb5, 0xbf, 0xf0, 0x66, 0x4f, 0x39, 0xc1, 0xb0 },
};

pub const IID_IDxcCompiler3 = GUID{
    .Data1 = 0x228b4687,
    .Data2 = 0x5a6a,
    .Data3 = 0x4730,
    .Data4 = .{ 0x90, 0x0c, 0x97, 0x02, 0xb2, 0x20, 0x3f, 0x54 },
};

pub const IID_IDxcResult = GUID{
    .Data1 = 0x58346cda,
    .Data2 = 0xdde7,
    .Data3 = 0x4497,
    .Data4 = .{ 0x94, 0x61, 0x6f, 0x87, 0xaf, 0x5e, 0x06, 0x59 },
};

pub extern "dxcompiler" fn DxcCreateInstance(
    class_id: *const GUID,
    interface_id: *const GUID,
    instance: *?*anyopaque,
) callconv(.winapi) HRESULT;
