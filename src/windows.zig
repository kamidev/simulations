const std = @import("std");
const zgui = @import("zgui");
const zgpu = @import("zgpu");
const main = @import("main.zig");
const DemoState = main.DemoState;

pub const window_flags = .{
    .popen = null,
    .flags = zgui.WindowFlags.no_decoration,
};

pub const ParametersWindow = PercentArgs{
    .x = 0.0,
    .y = 0.13,
    .w = 0.25,
    .h = 0.62,
    .margin = 0.02,
};

pub const StatsWindow = PercentArgs{
    .x = 0.0,
    .y = 0.75,
    .w = 1.0,
    .h = 0.25,
    .margin = 0.02,
    .no_margin = .{ .top = true },
};

pub const PercentArgs = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    margin: f32,
    no_margin: struct {
        top: bool = false,
        bottom: bool = false,
        left: bool = false,
        right: bool = false,
    } = .{},
    // flags: zgui.WindowFlags = .{},
};

pub fn setNextWindow(gctx: *zgpu.GraphicsContext, args: PercentArgs) void {
    std.debug.assert(0.0 <= args.x and args.x <= 1.0);
    std.debug.assert(0.0 <= args.y and args.y <= 1.0);
    std.debug.assert(0.0 <= args.w and args.w <= 1.0);
    std.debug.assert(0.0 <= args.h and args.h <= 1.0);
    std.debug.assert(0.0 <= args.margin and args.margin <= 1.0);
    const width = @as(f32, @floatFromInt(gctx.swapchain_descriptor.width));
    const height = @as(f32, @floatFromInt(gctx.swapchain_descriptor.height));
    const margin_x = width * args.margin;
    const margin_y = height * args.margin;
    const margin_pixels = @min(margin_x, margin_y);
    var x = width * args.x + margin_pixels;
    var y = height * args.y + margin_pixels;
    var w = width * args.w - (margin_pixels * 2);
    var h = height * args.h - (margin_pixels * 2);

    if (args.no_margin.top) {
        y -= margin_pixels;
        h += margin_pixels;
    }
    if (args.no_margin.bottom) {
        h += margin_pixels;
    }
    if (args.no_margin.left) {
        x -= margin_pixels;
        w += margin_pixels;
    }
    if (args.no_margin.right) {
        w += margin_pixels;
    }

    zgui.setNextWindowPos(.{
        .x = x,
        .y = y,
    });

    zgui.setNextWindowSize(.{
        .w = w,
        .h = h,
    });
}

pub fn commonGui(demo: *main.DemoState) void {
    setNextWindow(demo.gctx, PercentArgs{
        .x = 0.0,
        .y = 0.0,
        .w = 0.25,
        .h = 0.13,
        .margin = 0.02,
        .no_margin = .{ .bottom = true },
    });
    if (zgui.begin("Select Demo", window_flags)) {
        zgui.pushIntId(1);
        commonParameters(demo);
        zgui.popId();
    }
    zgui.end();
}

pub fn commonParameters(demo: *main.DemoState) void {
    zgui.pushItemWidth(zgui.getContentRegionAvail()[0]);
    zgui.bulletText("{d:.1} fps", .{demo.gctx.stats.fps});
    zgui.spacing();
    zgui.text("Select Demo", .{});

    if (zgui.combo("Select Demo", .{
        .current_item = &demo.current_demo,
        .items_separated_by_zeros = "Resource Simulation\x00Resource Editor\x00Signal Explorer\x00Arithmetic Visualization\x00",
    })) {
        if (demo.current_demo != 0) {
            demo.demos.random.running = false;
        }
        if (demo.current_demo != 1) {
            demo.demos.editor.running = false;
        }
    }
    zgui.spacing();
}
