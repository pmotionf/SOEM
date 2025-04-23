const std = @import("std");

const version = std.SemanticVersion.parse("1.4.0") catch unreachable;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const link = b.option(
        std.builtin.LinkMode,
        "link",
        "link mode of library",
    ) orelse .static;

    const lib = if (link == .static) b.addStaticLibrary(.{
        .name = "soem",
        .target = target,
        .optimize = optimize,
        .version = version,
        .link_libc = true,
    }) else b.addSharedLibrary(.{
        .name = "soem",
        .target = target,
        .optimize = optimize,
        .version = version,
        .link_libc = true,
    });

    const os_libs: []const []const u8 = switch (target.result.os.tag) {
        .windows => &.{ "wpcap", "Packet", "ws2_32", "winmm" },
        .linux => &.{ "pthread", "rt" },
        .macos => &.{ "pthread", "pcap" },
        else => return error.UnsupportedTargetOs,
    };

    const os_subdir: []const u8 = switch (target.result.os.tag) {
        .windows => "win32",
        .linux => "linux",
        .macos => "macosx",
        else => return error.UnsupportedTargetOs,
    };

    const c_flags: []const []const u8 = if (target.result.abi == .msvc)
        &.{ "/D _CRT_SECURE_NO_WARNINGS", "/WX" }
    else
        &.{"-Wall -Wextra -Werror"};

    const soem_sources = try globFiles(
        b.path("soem"),
        std.heap.smp_allocator,
        .{ .extension = "c" },
    );
    defer std.heap.smp_allocator.free(soem_sources);
    const soem_headers = try globFiles(
        b.path("soem"),
        std.heap.smp_allocator,
        .{ .extension = "h" },
    );
    defer std.heap.smp_allocator.free(soem_headers);

    const osal_path = b.path("osal").path(b, os_subdir);
    const osal_sources = try globFiles(
        osal_path,
        std.heap.smp_allocator,
        .{ .extension = "c" },
    );
    defer std.heap.smp_allocator.free(osal_sources);
    const osal_headers = try globFiles(
        osal_path,
        std.heap.smp_allocator,
        .{ .extension = "h" },
    );
    defer std.heap.smp_allocator.free(osal_headers);

    const oshw_path = b.path("oshw").path(b, os_subdir);
    const oshw_sources = try globFiles(
        oshw_path,
        std.heap.smp_allocator,
        .{ .extension = "c" },
    );
    defer std.heap.smp_allocator.free(oshw_sources);
    const oshw_headers = try globFiles(
        oshw_path,
        std.heap.smp_allocator,
        .{ .extension = "h" },
    );
    defer std.heap.smp_allocator.free(oshw_headers);

    lib.root_module.addCSourceFiles(.{
        .root = b.path("soem"),
        .files = soem_sources,
        .language = .c,
        .flags = c_flags,
    });
    lib.root_module.addIncludePath(b.path("soem"));
    for (soem_headers) |header| {
        var buffer: [256]u8 = undefined;
        @memcpy(buffer[0..5], "soem/");
        @memcpy(buffer[5..][0..header.len], header);
        lib.installHeader(
            b.path("soem").path(b, header),
            buffer[0 .. header.len + 5],
        );
    }

    lib.root_module.addCSourceFiles(.{
        .root = osal_path,
        .files = osal_sources,
        .language = .c,
        .flags = c_flags,
    });
    lib.root_module.addIncludePath(b.path("osal"));
    lib.root_module.addIncludePath(osal_path);
    lib.installHeader(b.path("osal/osal.h"), "soem/osal.h");
    for (osal_headers) |header| {
        var buffer: [256]u8 = undefined;
        @memcpy(buffer[0..5], "soem/");
        @memcpy(buffer[5..][0..header.len], header);
        lib.installHeader(
            osal_path.path(b, header),
            buffer[0 .. header.len + 5],
        );
    }

    lib.root_module.addCSourceFiles(.{
        .root = oshw_path,
        .files = oshw_sources,
        .language = .c,
        .flags = c_flags,
    });
    lib.root_module.addIncludePath(oshw_path);
    if (target.result.os.tag == .windows) {
        lib.root_module.addIncludePath(oshw_path.path(b, "wpcap/Include"));
        if (target.result.ptrBitWidth() == 64) {
            lib.root_module.addLibraryPath(oshw_path.path(b, "wpcap/Lib/x64"));
        } else if (target.result.ptrBitWidth() == 32) {
            lib.root_module.addLibraryPath(oshw_path.path(b, "wpcap/Lib"));
        }
    }
    for (oshw_headers) |header| {
        var buffer: [256]u8 = undefined;
        @memcpy(buffer[0..5], "soem/");
        @memcpy(buffer[5..][0..header.len], header);
        lib.installHeader(
            oshw_path.path(b, header),
            buffer[0 .. header.len + 5],
        );
    }

    for (os_libs) |os_lib| {
        lib.root_module.linkSystemLibrary(
            os_lib,
            .{ .needed = true, .preferred_link_mode = .static },
        );
    }

    b.installArtifact(lib);
}

const GlobOptions = struct {
    extension: []const u8 = "",
    recursive: bool = false,
};

fn countFiles(dir: std.fs.Dir, options: GlobOptions) !usize {
    var walker = dir.iterate();
    var total_count: usize = 0;

    // Walk once to get total file count.
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            if (options.extension.len > 0) {
                const extension =
                    entry.name[entry.name.len - options.extension.len ..];

                if (std.ascii.eqlIgnoreCase(extension, options.extension)) {
                    total_count += 1;
                }
            } else {
                total_count += 1;
            }
        } else if (entry.kind == .directory and options.recursive) {
            var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
            defer sub_dir.close();
            total_count += try countFiles(sub_dir, options);
        }
    }

    return total_count;
}

fn globInner(
    dir: std.fs.Dir,
    allocator: std.mem.Allocator,
    results: [][]u8,
    filled_: usize,
    options: GlobOptions,
) !void {
    var walker = dir.iterate();
    var filled = filled_;

    // Walk once to get total file count.
    while (try walker.next()) |entry| {
        if (entry.kind == .file) {
            if (options.extension.len > 0) {
                const extension =
                    entry.name[entry.name.len - options.extension.len ..];

                if (std.ascii.eqlIgnoreCase(extension, options.extension)) {
                    results[filled] = try allocator.dupe(u8, entry.name);
                    filled += 1;
                }
            } else {
                results[filled] = try allocator.dupe(u8, entry.name);
                filled += 1;
            }
        } else if (entry.kind == .directory and options.recursive) {
            var sub_dir = try dir.openDir(entry.name, .{ .iterate = true });
            defer sub_dir.close();

            try globInner(sub_dir, allocator, results, filled, options);
        }
    }
}

fn globFiles(
    path: std.Build.LazyPath,
    allocator: std.mem.Allocator,
    options: GlobOptions,
) ![]const []const u8 {
    var dir = switch (path) {
        .cwd_relative => try std.fs.cwd().openDir(
            path.src_path.sub_path,
            .{ .iterate = true },
        ),
        .src_path => |sp| try sp.owner.build_root.handle.openDir(
            sp.sub_path,
            .{ .iterate = true },
        ),
        else => unreachable,
    };
    defer dir.close();

    const total_count = try countFiles(dir, options);

    const result: [][]u8 = try allocator.alloc([]u8, total_count);
    for (result) |*file| {
        file.* = &.{};
    }

    try globInner(dir, allocator, result, 0, options);

    return result;
}
