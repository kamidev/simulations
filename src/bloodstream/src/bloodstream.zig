const std = @import("std");
const math = std.math;
const array = std.ArrayList;
const random = std.crypto.random;
const zm = @import("zmath");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const Simulation = @import("simulation.zig");
const Statistics = Simulation.stats;
const Shapes = @import("shapes.zig");
const wgsl = @import("shaders.zig");
const gui = @import("gui.zig");
const Consumers = @import("consumers.zig");
const Lines = @import("lines.zig");
const Splines = @import("splines.zig");

const content_dir = @import("build_options").content_dir;
const window_title = "Circulatory Simulation";

pub const StagingBuffer = struct {
    slice: ?[]const [4]i32 = null,
    buffer: wgpu.Buffer = undefined,
};

pub const Vertex = struct {
    position: [3]f32,
};

pub const GPUStats = struct {
    second: i32,
    num_transactions: i32,
    num_empty_consumers: i32,
    num_total_producer_inventory: i32,
};

pub const DemoState = struct {
    gctx: *zgpu.GraphicsContext,

    consumer_pipeline: zgpu.RenderPipelineHandle,
    line_pipeline: zgpu.RenderPipelineHandle,
    spline_pipeline: zgpu.RenderPipelineHandle,
    consumer_compute_pipeline: zgpu.ComputePipelineHandle,
    bind_group: zgpu.BindGroupHandle,

    consumer_vertex_buffer: zgpu.BufferHandle,
    consumer_index_buffer: zgpu.BufferHandle,
    consumer_buffer: zgpu.BufferHandle,
    consumer_bind_group: zgpu.BindGroupHandle,
    stats_buffer: zgpu.BufferHandle,
    size_buffer: zgpu.BufferHandle,
    lines_buffer: zgpu.BufferHandle,
    square_vertex_buffer: zgpu.BufferHandle,
    line_position_buffer: zgpu.BufferHandle,
    splines_point_buffer: zgpu.BufferHandle,
    splines_square_buffer: zgpu.BufferHandle,
    stats_mapped_buffer: zgpu.BufferHandle,
    stats: StagingBuffer,

    depth_texture: zgpu.TextureHandle,
    depth_texture_view: zgpu.TextureViewHandle,

    sim: Simulation,
    allocator: std.mem.Allocator,
};

fn init(allocator: std.mem.Allocator, window: zglfw.Window) !DemoState {
    const gctx = try zgpu.GraphicsContext.init(allocator, window);

    // Uniform Bind Group
    const bind_group_layout = gctx.createBindGroupLayout(&.{
        zgpu.bglBuffer(0, .{ .vertex = true }, .uniform, true, 0),
    });
    defer gctx.releaseResource(bind_group_layout);
    const bind_group = gctx.createBindGroup(bind_group_layout, &[_]zgpu.BindGroupEntryInfo{
        .{ .binding = 0, .buffer_handle = gctx.uniforms.buffer, .offset = 0, .size = @sizeOf(zm.Mat) },
    });

    // Render Pipelines
    const pipeline_layout = gctx.createPipelineLayout(&.{bind_group_layout});
    defer gctx.releaseResource(pipeline_layout);

    const consumer_pipeline = Consumers.createConsumerPipeline(gctx, pipeline_layout);
    const line_pipeline = Lines.createLinePipeline(gctx, pipeline_layout);
    const spline_pipeline = Splines.createSplinePipeline(gctx, pipeline_layout);

    // Simulation struct
    var sim = Simulation.init(allocator);
    sim.createAgents(allocator);

    // Create Compute Bind Group and Pipeline
    const compute_bgl = gctx.createBindGroupLayout(&.{
        zgpu.bglBuffer(0, .{ .compute = true }, .storage, true, 0),
        zgpu.bglBuffer(1, .{ .compute = true }, .storage, true, 0),
        zgpu.bglBuffer(2, .{ .compute = true }, .read_only_storage, true, 0),
        zgpu.bglBuffer(3, .{ .compute = true }, .storage, true, 0),
    });
    defer gctx.releaseResource(compute_bgl);
    const compute_pl = gctx.createPipelineLayout(&.{compute_bgl});
    defer gctx.releaseResource(compute_pl);
    const consumer_compute_pipeline = Consumers.createConsumerComputePipeline(gctx, compute_pl);

    // Create Buffers
    const num_vertices = 20;
    const consumer_vertex_buffer = Consumers.createConsumerVertexBuffer(gctx, sim.params.consumer_radius, num_vertices);
    const consumer_index_buffer = Consumers.createConsumerIndexBuffer(gctx, num_vertices);
    var consumer_buffer = Consumers.createConsumerBuffer(gctx, sim.consumers);

    const lines_buffer = Lines.createLinesBuffer(gctx, sim.lines);
    const splines_point_buffer = Splines.createSplinePointsBuffer(gctx, sim.splines);
    const square_vertex_buffer = Lines.createSquareVertexBuffer(gctx);
    const line_position_buffer = Lines.createSquarePositionBuffer(gctx, sim.lines);
    const splines_square_buffer = Splines.createSplinesSquaresBuffer(gctx, sim.splines);

    const stats_buffer = gctx.createBuffer(.{
        .usage = .{ .copy_dst = true, .copy_src = true, .storage = true },
        .size = @sizeOf(i32) * 4,
    });
    const stats_mapped_buffer = gctx.createBuffer(.{
        .usage = .{ .copy_dst = true, .map_read = true },
        .size = @sizeOf(i32) * 4,
    });

    const stats_data = [_][4]i32{ [4]i32{ 0, 0, 0, 0 }, };
    gctx.queue.writeBuffer(gctx.lookupResource(stats_buffer).?, 0, [4]i32, stats_data[0..]);

    var stats: StagingBuffer = .{
        .slice = null,
        .buffer = gctx.lookupResource(stats_mapped_buffer).?,
    };

    const size_buffer = Shapes.createCoordinateSizeBuffer(gctx, sim.coordinate_size);
    var consumer_bind_group = Shapes.createBindGroup(gctx, sim, compute_bgl, consumer_buffer, stats_buffer, size_buffer, lines_buffer);

    // Create a depth texture and its 'view'.
    const depth = createDepthTexture(gctx);

    return DemoState{
        .gctx = gctx,
        .consumer_pipeline = consumer_pipeline,
        .line_pipeline = line_pipeline,
        .spline_pipeline = spline_pipeline,
        .consumer_compute_pipeline = consumer_compute_pipeline,
        .bind_group = bind_group,
        .consumer_vertex_buffer = consumer_vertex_buffer,
        .consumer_index_buffer = consumer_index_buffer,
        .consumer_buffer = consumer_buffer,
        .consumer_bind_group = consumer_bind_group,
        .stats_buffer = stats_buffer,
        .size_buffer = size_buffer,
        .lines_buffer = lines_buffer,
        .square_vertex_buffer = square_vertex_buffer,
        .line_position_buffer = line_position_buffer,
        .splines_point_buffer = splines_point_buffer,
        .splines_square_buffer = splines_square_buffer,
        .stats_mapped_buffer = stats_mapped_buffer,
        .stats = stats,
        .depth_texture = depth.texture,
        .depth_texture_view = depth.view,
        .allocator = allocator,
        .sim = sim,
    };
}

fn deinit(allocator: std.mem.Allocator, demo: *DemoState) void {
    demo.gctx.deinit(allocator);
    demo.sim.deinit();
    demo.* = undefined;
}

fn update(demo: *DemoState) void {
    gui.update(demo);
}

fn draw(demo: *DemoState) void {
    const gctx = demo.gctx;
    const fb_width = gctx.swapchain_descriptor.width;
    const fb_height = gctx.swapchain_descriptor.height;
    //const t = @floatCast(f32, gctx.stats.time);
    //const frame_num = gctx.stats.gpu_frame_number;

    const cam_world_to_view = zm.lookAtLh(
        zm.f32x4(0.0, 0.0, -3000.0, 1.0),
        zm.f32x4(0.0, 0.0, 0.0, 1.0),
        zm.f32x4(0.0, 1.0, 0.0, 0.0),
    );
    const cam_view_to_clip = zm.perspectiveFovLh(
        0.25 * math.pi,
        @intToFloat(f32, fb_width) / @intToFloat(f32, fb_height),
        0.01,
        3001.0,
    );
    const cam_world_to_clip = zm.mul(cam_world_to_view, cam_view_to_clip);

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        pass: {
            const ccp = gctx.lookupResource(demo.consumer_compute_pipeline) orelse break :pass;
            const bg = gctx.lookupResource(demo.consumer_bind_group) orelse break :pass;
            const bg_info = gctx.lookupResourceInfo(demo.consumer_bind_group) orelse break :pass;
            const first = @intCast(u32, bg_info.entries[0].offset);
            const second = @intCast(u32, bg_info.entries[1].offset);
            const third = @intCast(u32, bg_info.entries[2].offset);
            const fourth = @intCast(u32, bg_info.entries[3].offset);
            const dynamic_offsets = &.{ first, second, third, fourth };

            const pass = encoder.beginComputePass(null);
            defer {
                pass.end();
                pass.release();
            }

            pass.setBindGroup(0, bg, dynamic_offsets);
            pass.setPipeline(ccp);
            const num_consumers = @intToFloat(f32, demo.sim.consumers.items.len);
            var workgroup_size = @floatToInt(u32, @ceil(num_consumers / 64));
            pass.dispatchWorkgroups(workgroup_size, 1, 1);
        }

        // Copy transactions number to mapped buffer
        pass: {
            const buf = gctx.lookupResource(demo.stats_buffer) orelse break :pass;
            const cp = gctx.lookupResource(demo.stats_mapped_buffer) orelse break :pass;
            encoder.copyBufferToBuffer(buf, 0, cp, 0, @sizeOf(i32) * 4);
        }

        pass: {
            const cvb_info = gctx.lookupResourceInfo(demo.consumer_vertex_buffer) orelse break :pass;
            const cpb_info = gctx.lookupResourceInfo(demo.consumer_buffer) orelse break :pass;
            const cib_info = gctx.lookupResourceInfo(demo.consumer_index_buffer) orelse break :pass;
            const consumer_pipeline = gctx.lookupResource(demo.consumer_pipeline) orelse break :pass;
            const sp = gctx.lookupResource(demo.spline_pipeline) orelse break :pass;
            const svb_info = gctx.lookupResourceInfo(demo.square_vertex_buffer) orelse break :pass;
            const spb_info = gctx.lookupResourceInfo(demo.splines_point_buffer) orelse break :pass;
            const ssb_info = gctx.lookupResourceInfo(demo.splines_square_buffer) orelse break :pass;
            const bind_group = gctx.lookupResource(demo.bind_group) orelse break :pass;
            const depth_view = gctx.lookupResource(demo.depth_texture_view) orelse break :pass;

            const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
                .view = back_buffer_view,
                .load_op = .clear,
                .store_op = .store,
            }};
            const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
                .view = depth_view,
                .depth_load_op = .clear,
                .depth_store_op = .store,
                .depth_clear_value = 1.0,
            };
            const render_pass_info = wgpu.RenderPassDescriptor{
                .color_attachment_count = color_attachments.len,
                .color_attachments = &color_attachments,
                .depth_stencil_attachment = &depth_attachment,
            };
            const pass = encoder.beginRenderPass(render_pass_info);
            defer {
                pass.end();
                pass.release();
            }

            var mem = gctx.uniformsAllocate(zm.Mat, 1);
            mem.slice[0] = zm.transpose(cam_world_to_clip);
            pass.setBindGroup(0, bind_group, &.{mem.offset});

            pass.setVertexBuffer(0, cvb_info.gpuobj.?, 0, cvb_info.size);
            pass.setVertexBuffer(1, cpb_info.gpuobj.?, 0, cpb_info.size);
            pass.setIndexBuffer(cib_info.gpuobj.?, .uint32, 0, cib_info.size);
            const num_consumers = @intCast(u32, demo.sim.consumers.items.len);
            pass.setPipeline(consumer_pipeline);
            pass.drawIndexed(57, num_consumers, 0, 0, 0);

            pass.setPipeline(sp);
            pass.setVertexBuffer(0, svb_info.gpuobj.?, 0, svb_info.size);
            pass.setVertexBuffer(1, spb_info.gpuobj.?, 0, spb_info.size);
            var num_points: u32 = 0;
            for (demo.sim.splines.items) |s| {
                num_points += @intCast(u32, s.points.items.len);
            }
            pass.draw(6, num_points, 0, 0);

            pass.setVertexBuffer(0, svb_info.gpuobj.?, 0, svb_info.size);
            pass.setVertexBuffer(1, ssb_info.gpuobj.?, 0, ssb_info.size);
            pass.draw(6, 100000, 0, 0);
        }

        {
            const pass = zgpu.util.beginRenderPassSimple(encoder, .load, back_buffer_view, null, null, null);
            defer zgpu.util.endRelease(pass);
            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});

    if (gctx.present() == .swap_chain_resized) {
        // Release old depth texture.
        gctx.releaseResource(demo.depth_texture_view);
        gctx.destroyResource(demo.depth_texture);

        // Create a new depth texture to match the new window size.
        const depth = createDepthTexture(gctx);
        demo.depth_texture = depth.texture;
        demo.depth_texture_view = depth.view;
    }
}

pub fn startSimulation(demo: *DemoState) void {
    const compute_bgl = demo.gctx.createBindGroupLayout(&.{
        zgpu.bglBuffer(0, .{ .compute = true }, .storage, true, 0),
        zgpu.bglBuffer(1, .{ .compute = true }, .storage, true, 0),
        zgpu.bglBuffer(2, .{ .compute = true }, .read_only_storage, true, 0),
        zgpu.bglBuffer(3, .{ .compute = true }, .storage, true, 0),
    });
    defer demo.gctx.releaseResource(compute_bgl);
    demo.sim.createAgents(demo.allocator);
    demo.consumer_buffer = Consumers.createConsumerBuffer(demo.gctx, demo.sim.consumers);
    const stats_data = [_]i32{ 0, 0, 0, 0 };
    demo.gctx.queue.writeBuffer(demo.gctx.lookupResource(demo.stats_buffer).?, 0, i32, stats_data[0..]);
    demo.lines_buffer = Lines.createLinesBuffer(demo.gctx, demo.sim.lines);
    demo.consumer_bind_group = Shapes.createBindGroup(demo.gctx, demo.sim, compute_bgl, demo.consumer_buffer, demo.stats_buffer, demo.size_buffer, demo.lines_buffer);
    demo.consumer_vertex_buffer = Consumers.createConsumerVertexBuffer(demo.gctx, demo.sim.params.consumer_radius, 20);
}

pub fn buffersMappedCallback(status: wgpu.BufferMapAsyncStatus, userdata: ?*anyopaque) callconv(.C) void {
    const usb = @ptrCast(*StagingBuffer, @alignCast(@sizeOf(usize), userdata));
    std.debug.assert(usb.slice == null);
    if (status == .success) {
        usb.slice = usb.buffer.getConstMappedRange([4]i32, 0, 1).?;
    } else {
        std.debug.print("[zgpu] Failed to map buffer (code: {d})\n", .{@enumToInt(status)});
    }
}

fn createDepthTexture(gctx: *zgpu.GraphicsContext) struct {
    texture: zgpu.TextureHandle,
    view: zgpu.TextureViewHandle,
} {
    const texture = gctx.createTexture(.{
        .usage = .{ .render_attachment = true },
        .dimension = .tdim_2d,
        .size = .{
            .width = gctx.swapchain_descriptor.width,
            .height = gctx.swapchain_descriptor.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const view = gctx.createTextureView(texture, .{});
    return .{ .texture = texture, .view = view };
}

pub fn main() !void {
    try zglfw.init();
    defer zglfw.terminate();

    //zgpu.checkSystem(content_dir) catch {
    //    // In case of error zgpu.checkSystem() will print error message.
    //    return;
    //};

    zglfw.defaultWindowHints();
    zglfw.windowHint(.cocoa_retina_framebuffer, 1);
    zglfw.windowHint(.client_api, 0);
    const window = try zglfw.createWindow(1600, 1000, window_title, null, null);
    defer window.destroy();
    window.setSizeLimits(400, 400, -1, -1);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var demo = try init(allocator, window);
    defer deinit(allocator, &demo);

    const scale_factor = scale_factor: {
        const scale = window.getContentScale();
        break :scale_factor math.max(scale.x, scale.y);
    };

    zgui.init();
    defer zgui.deinit();

    _ = zgui.io.addFontFromFile(content_dir ++ "Roboto-Medium.ttf", 19.0 * scale_factor);

    zgui.backend.init(
        window,
        demo.gctx.device,
        @enumToInt(zgpu.GraphicsContext.swapchain_format),
    );
    defer zgui.backend.deinit();

    zgui.getStyle().scaleAllSizes(scale_factor);

    while (!window.shouldClose()) {
        zglfw.pollEvents();
        update(&demo);
        draw(&demo);
    }
}
