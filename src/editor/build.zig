const std = @import("std");

pub fn build(b: *std.Build, options: anytype) *std.Build.Step.Compile {
    const emscripten = options.target.result.os.tag == .emscripten;
    const exe_desc = .{
        .name = "Simulations",
        .root_source_file = b.path("src/editor/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
    };
    const exe = blk: {
        if (emscripten) {
            break :blk b.addStaticLibrary(exe_desc);
        } else {
            break :blk b.addExecutable(exe_desc);
        }
    };

    @import("system_sdk").addLibraryPathsTo(exe);
    const zglfw = b.dependency("zglfw", .{
        .target = options.target,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));

    @import("zgpu").addLibraryPathsTo(exe);
    const zgpu = b.dependency("zgpu", .{
        .target = options.target,
    });
    exe.root_module.addImport("zgpu", zgpu.module("root"));

    const zemscripten = b.dependency("zemscripten", .{});

    if (!emscripten) {
        exe.linkLibrary(zglfw.artifact("glfw"));
        exe.linkLibrary(zgpu.artifact("zdawn"));
        exe.root_module.addImport("zemscripten", zemscripten.module("dummy"));
    } else {
        exe.root_module.addImport("zemscripten", zemscripten.module("root"));
    }

    const zmath = b.dependency("zmath", .{
        .target = options.target,
    });
    exe.root_module.addImport("zmath", zmath.module("root"));

    const zgui = b.dependency("zgui", .{
        .target = options.target,
        .backend = .glfw_wgpu,
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    const zpool = b.dependency("zpool", .{
        .target = options.target,
    });
    exe.root_module.addImport("zpool", zpool.module("root"));

    const zstbi = b.dependency("zstbi", .{
        .target = options.target,
    });
    exe.root_module.addImport("zstbi", zstbi.module("root"));
    exe.linkLibrary(zstbi.artifact("zstbi"));

    const install_content_step = b.addInstallDirectory(.{
        .source_dir = b.path("content"),
        .install_dir = .{ .custom = "" },
        .install_subdir = "bin/content",
    });
    exe.step.dependOn(&install_content_step.step);

    return exe;
}

pub fn buildWeb(b: *std.Build, options: anytype) *std.Build.Step {
    const exe = b.addStaticLibrary(.{
        .name = "Simulations",
        .root_source_file = b.path("src/editor/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
    });

    const zglfw = b.dependency("zglfw", .{
        .target = options.target,
    });
    exe.root_module.addImport("zglfw", zglfw.module("root"));

    @import("zgpu").addLibraryPathsTo(exe);
    const zgpu = b.dependency("zgpu", .{
        .target = options.target,
    });
    exe.root_module.addImport("zgpu", zgpu.module("root"));

    const zemscripten = b.dependency("zemscripten", .{});
    exe.root_module.addImport("zemscripten", zemscripten.module("root"));

    const zmath = b.dependency("zmath", .{
        .target = options.target,
    });
    exe.root_module.addImport("zmath", zmath.module("root"));

    const zgui = b.dependency("zgui", .{
        .target = options.target,
        .backend = .glfw_wgpu,
    });
    exe.root_module.addImport("zgui", zgui.module("root"));
    exe.linkLibrary(zgui.artifact("imgui"));

    const zpool = b.dependency("zpool", .{
        .target = options.target,
    });
    exe.root_module.addImport("zpool", zpool.module("root"));

    const zstbi = b.dependency("zstbi", .{
        .target = options.target,
    });
    exe.root_module.addImport("zstbi", zstbi.module("root"));
    exe.linkLibrary(zstbi.artifact("zstbi"));

    const zems = @import("zemscripten");
    const emcc_step = zems.emccStep(b, exe, .{
        .optimize = options.optimize,
        .flags = zems.emccDefaultFlags(b.allocator, options.optimize),
        .settings = zems.emccDefaultSettings(b.allocator, .{
            .optimize = options.optimize,
        }),
        .use_preload_plugins = true,
        .embed_paths = &.{
            .{
                .src_path = "content",
                .virtual_path = "/content",
            },
        },
        .preload_paths = &.{},
        .install_dir = .{ .custom = "web" },
        .shell_file_path = "libs/zemscripten/content/shell_minimal.html",
    });

    return emcc_step;
}
