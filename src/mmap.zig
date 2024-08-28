const std = @import("std");
const builtin = @import("builtin");

pub const MmapHandlePosix = struct {
    const Self = @This();

    file: std.fs.File,
    ptr: []align(std.mem.page_size) u8,

    pub fn init(path: []const u8, size: usize) !Self {
        if (builtin.os.tag == .windows) {
            return error.WindowsNotSupported;
        }

        const file = try std.fs.cwd().createFile(path, .{ .read = true });
        try file.setEndPos(size);
        const ptr = try std.posix.mmap(
            null, 
            size, 
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
        return Self{
            .file = file,
            .ptr = ptr,
        };
    }

    pub fn deinit(self: *const Self) void {
        std.posix.munmap(self.ptr);
        self.file.close();
    }
};

//// TODO: windows bullshit

// const windows = std.os.windows;
// const WINAPI = windows.WINAPI;
// const HANDLE = windows.HANDLE;
// const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
// const DWORD = windows.DWORD;
// const LPCSTR = windows.LPCSTR;
// const SIZE_T = windows.SIZE_T;
// const LPVOID = windows.LPVOID;
// const LPCVOID = windows.LPCVOID;
// const BOOL = windows.BOOL;
// const PAGE_READWRITE = windows.FILE_READ;
// const FILE_READ_ACCESS = windows.FILE_READ_ACCESS;
// const FILE_WRITE_ACCESS = windows.FILE_WRITE_ACCESS;

// const FILE_MAP_COPY = windows.SECTION_QUERY;
// const FILE_MAP_WRITE = windows.SECTION_MAP_WRITE;
// const FILE_MAP_READ = windows.SECTION_MAP_READ;
// const FILE_MAP_ALL_ACCESS = windows.SECTION_ALL_ACCESS;
// const FILE_MAP_EXECUTE = windows.SECTION_MAP_EXECUTE;

// pub extern "kernel32" fn CreateFileMapping(
//     hFile: HANDLE,
//     lpFileMappingAttributes: ?*SECURITY_ATTRIBUTES,
//     flProtect: DWORD,
//     dwMaximumSizeHigh: DWORD,
//     dwMaximumSizeLow: DWORD,
//     lpName: LPCSTR,
// ) callconv(WINAPI) HANDLE;

// pub extern "kernel32" fn MapViewOfFile(
//     hFileMappingObject: HANDLE,
//     dwDesiredAccess: DWORD,
//     dwFileOffsetHigh: DWORD,
//     dwFileOffsetLow: DWORD,
//     dwNumbeOfBytesToMap: SIZE_T,
// ) callconv(WINAPI) ?LPVOID;

// pub extern "kernel32" fn UnmapViewOfFile(
//     lpBaseAddress: LPCVOID,
// )callconv(WINAPI) BOOL;

// pub const MmapHandle = union(enum) {
//     const Self = @This();

//     posix: MmapHandlePosix,
//     windows: MmapHandleWindows,

//     pub fn init(path: []const u8, size: usize) !Self {
//         switch (builtin.os.tag) {
//             .windows => return Self{ .windows = try MmapHandleWindows.init(path, size) },
//             else => return Self{ .posix = try MmapHandlePosix.init(path, size) },
//         }
//     }

//     pub fn deinit(self: Self) void {
//         switch (self) {
//             .posix => |h| h.deinit(),
//             .windows => |h| h.deinit(),
//         }
//     }

//     pub fn ptr(self: Self) []align(std.mem.page_size) u8 {
//         return switch (self) {
//             .posix => |h| h.ptr,
//             .windows => |h| @alignCast(h.ptr),
//         };
//     }
// };

// pub const MmapHandleWindows = struct {
//     const Self = @This();

//     file: std.fs.File,
//     lp_base_ptr: *anyopaque,
//     ptr: []align(std.mem.page_size) u8,

//     pub fn init(path: []const u8, size: usize) !Self {
//         std.debug.assert(builtin.os.tag == .windows);

//         const file = try std.fs.cwd().createFile(path, .{ .read = true });
//         try file.setEndPos(size);

//         const h_map = CreateFileMapping(
//             file.handle,
//             null,
//             PAGE_READWRITE,
//             size,
//             0,
//             null,
//         );
//         const lp_base_ptr = MapViewOfFile(
//             h_map,
//             FILE_MAP_ALL_ACCESS,
//             size,
//             0,
//             0,
//         );
//         if (lp_base_ptr == null) return error.WindowsMemoryMappingFailed;

//         return Self{
//             .file = file,
//             .lp_base_ptr = lp_base_ptr.?,
//             .ptr = lp_base_ptr.?[0..size],
//         };
//     }

//     pub fn deinit(self: *const Self) void {
//         _ = UnmapViewOfFile(self.lp_base_ptr);
//         self.file.close();
//     }
// };
