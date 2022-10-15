const std = @import("std");
const math = std.math;
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zgui = @import("zgui");
const zm = @import("zmath");
const array = std.ArrayList;
const random = std.crypto.random;
const F32x4 = @Vector(4, f32);
const Simulation = @import("simulation.zig");
const Statistics = @import("statistics.zig");
const Shapes = @import("shapes.zig");
const wgsl = @import("shaders.zig");
const gui = @import("gui.zig");
const Wgpu = @import("wgpu.zig");
const config = @import("config.zig");

const content_dir = @import("build_options").content_dir;
const window_title = "Resource Simulation";


pub const Vertex = struct {
    position: [3]f32,
};

pub const DemoState = struct {
    gctx: *zgpu.GraphicsContext,
    render_pipelines: struct {
        consumer: zgpu.RenderPipelineHandle,
        producer: zgpu.RenderPipelineHandle,
    },
    compute_pipelines: struct {
        consumer: zgpu.ComputePipelineHandle,
        producer: zgpu.ComputePipelineHandle,
    },
    bind_groups: struct {
        render: zgpu.BindGroupHandle,
        compute: zgpu.BindGroupHandle,
    },
    buffers: struct {
       data: struct {
           consumer: zgpu.BufferHandle,
           producer: zgpu.BufferHandle,
           stats: zgpu.BufferHandle,
           stats_mapped: zgpu.BufferHandle,
       },
       index: struct {
           consumer: zgpu.BufferHandle,
       },
       vertex: struct {
           consumer: zgpu.BufferHandle,
           producer: zgpu.BufferHandle,
       },
    }, 
    depth_texture: zgpu.TextureHandle,
    depth_texture_view: zgpu.TextureViewHandle,
    sim: Simulation,
    allocator: std.mem.Allocator,
};

fn init(allocator: std.mem.Allocator, window: zglfw.Window) !DemoState {
    const gctx = try zgpu.GraphicsContext.create(allocator, window);

    // Simulation struct
    var sim = Simulation.init(allocator);
    sim.createAgents();

    // Create Buffers
    const producer_buffer = Shapes.createProducerBuffer(gctx, sim.producers);
    var consumer_buffer = Shapes.createConsumerBuffer(gctx, sim.consumers);
    const stats_buffer = Statistics.createStatsBuffer(gctx);
    const stats_mapped_buffer = Statistics.createStatsMappedBuffer(gctx);

    const consumer_bind_group = Shapes.createBindGroup(
        gctx,
        sim,
        consumer_buffer,
        producer_buffer,
        stats_buffer
    );

    // Create a depth texture and its 'view'.
    const depth = createDepthTexture(gctx);

    return DemoState{
        .gctx = gctx,
        .render_pipelines = .{
            .producer = Wgpu.createRenderPipeline(gctx, config.ppi),
            .consumer = Wgpu.createRenderPipeline(gctx, config.cpi),
        },
        .compute_pipelines = .{
            .producer = Wgpu.createComputePipeline(gctx, config.pcpi),
            .consumer = Wgpu.createComputePipeline(gctx, config.ccpi),
        },
        .bind_groups = .{
            .render = Wgpu.createUniformBindGroup(gctx),
            .compute = consumer_bind_group,
        },
        .buffers = .{
            .data = .{
                .consumer = consumer_buffer,
                .producer = producer_buffer,
                .stats = stats_buffer,
                .stats_mapped = stats_mapped_buffer,
            },
            .index = .{
                .consumer = Shapes.createConsumerIndexBuffer(gctx),
            },
            .vertex = .{
                .consumer = Shapes.createConsumerVertexBuffer(gctx, sim.params.consumer_radius),
                .producer = Shapes.createProducerVertexBuffer(gctx, sim.params.producer_width),
            },
        },
        .depth_texture = depth.texture,
        .depth_texture_view = depth.view,
        .allocator = allocator,
        .sim = sim,
    };
}

fn deinit(allocator: std.mem.Allocator, demo: *DemoState) void {
    demo.gctx.destroy(allocator);
    demo.sim.deinit();
    demo.* = undefined;
}

fn update(demo: *DemoState) void {
    gui.update(demo);
}

fn draw(demo: *DemoState) void {
    const gctx = demo.gctx;

    const cam_world_to_view = zm.lookAtLh(
        //eye position 
        zm.f32x4(0.0, 0.0, -3000.0, 0.0),

        //focus position
        zm.f32x4(0.0, 0.0, 0.0, 0.0),

        //up direction
        zm.f32x4(0.0, 1.0, 0.0, 0.0),
    );

    const cam_view_to_clip = zm.perspectiveFovLh(
        //fovy
        0.25 * math.pi,

        //aspect
        1.8,

        //near
        0.01,

        //far
        3001.0,
    );
    const cam_world_to_clip = zm.mul(cam_world_to_view, cam_view_to_clip);

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        pass: {
            const pcp = gctx.lookupResource(demo.compute_pipelines.producer) orelse break :pass;
            const ccp = gctx.lookupResource(demo.compute_pipelines.consumer) orelse break :pass;
            const bg = gctx.lookupResource(demo.bind_groups.compute) orelse break :pass;
            const bg_info = gctx.lookupResourceInfo(demo.bind_groups.compute) orelse break :pass;
            const first_offset = @intCast(u32, bg_info.entries[0].offset);
            const second_offset = @intCast(u32, bg_info.entries[1].offset);
            const third_offset = @intCast(u32, bg_info.entries[2].offset);
            const dynamic_offsets = &.{ first_offset, second_offset, third_offset };

            const pass = encoder.beginComputePass(null);
            defer {
                pass.end();
                pass.release();
            }
            pass.setPipeline(pcp);
            pass.setBindGroup(0, bg, dynamic_offsets);
            const num_producers = @intToFloat(f32, demo.sim.producers.items.len);
            var workgroup_size = @floatToInt(u32, @ceil(num_producers / 64));
            pass.dispatchWorkgroups(workgroup_size, 1, 1);

            pass.setPipeline(ccp);
            const num_consumers = @intToFloat(f32, demo.sim.consumers.items.len);
            workgroup_size = @floatToInt(u32, @ceil(num_consumers / 64));
            pass.dispatchWorkgroups(workgroup_size, 1, 1);
        }

        // Copy transactions number to mapped buffer
        pass: {
            const buf = gctx.lookupResource(demo.buffers.data.stats) orelse break :pass;
            const cp = gctx.lookupResource(demo.buffers.data.stats_mapped) orelse break :pass;
            encoder.copyBufferToBuffer(buf, 0, cp, 0, @sizeOf(f32) * 3);
        }

        pass: {
            const vb_info = gctx.lookupResourceInfo(demo.buffers.vertex.producer) orelse break :pass;
            const vpb_info = gctx.lookupResourceInfo(demo.buffers.data.producer) orelse break :pass;
            const cvb_info = gctx.lookupResourceInfo(demo.buffers.vertex.consumer) orelse break :pass;
            const cpb_info = gctx.lookupResourceInfo(demo.buffers.data.consumer) orelse break :pass;
            const cib_info = gctx.lookupResourceInfo(demo.buffers.index.consumer) orelse break :pass;
            const producer_rp = gctx.lookupResource(demo.render_pipelines.producer) orelse break :pass;
            const consumer_rp = gctx.lookupResource(demo.render_pipelines.consumer) orelse break :pass;
            const render_bind_group = gctx.lookupResource(demo.bind_groups.render) orelse break :pass;
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
            pass.setBindGroup(0, render_bind_group, &.{mem.offset});

            pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
            pass.setVertexBuffer(1, vpb_info.gpuobj.?, 0, vpb_info.size);
            const num_producers = @intCast(u32, demo.sim.producers.items.len);
            pass.setPipeline(producer_rp);
            pass.draw(6, num_producers, 0, 0);

            pass.setVertexBuffer(0, cvb_info.gpuobj.?, 0, cvb_info.size);
            pass.setVertexBuffer(1, cpb_info.gpuobj.?, 0, cpb_info.size);
            pass.setIndexBuffer(cib_info.gpuobj.?, .uint32, 0, cib_info.size);
            const num_consumers = @intCast(u32, demo.sim.consumers.items.len);
            pass.setPipeline(consumer_rp);
            pass.drawIndexed(57, num_consumers, 0, 0, 0);
        }

        {
            const pass = zgpu.beginRenderPassSimple(encoder, .load, back_buffer_view, null, null, null);
            defer zgpu.endReleasePass(pass);
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
    const compute_bgl = Wgpu.createComputeBindGroupLayout(demo.gctx);
    defer demo.gctx.releaseResource(compute_bgl);

    demo.sim.createAgents();
    demo.buffers.data.producer = Shapes.createProducerBuffer(demo.gctx, demo.sim.producers);
    demo.buffers.data.consumer = Shapes.createConsumerBuffer(demo.gctx, demo.sim.consumers);
    const stats_data = [_][3]i32{ [3]i32{ 0, 0, 0 }, };
    demo.gctx.queue.writeBuffer(demo.gctx.lookupResource(demo.buffers.data.stats).?, 0, [3]i32, stats_data[0..]);
    demo.bind_groups.compute = Shapes.createBindGroup(demo.gctx, demo.sim, demo.buffers.data.consumer, demo.buffers.data.producer, demo.buffers.data.stats);
    demo.buffers.vertex.consumer = Shapes.createConsumerVertexBuffer(demo.gctx, demo.sim.params.consumer_radius);
}

pub fn supplyShock(demo: *DemoState) void {
    const compute_bgl = Wgpu.createComputeBindGroupLayout(demo.gctx);
    defer demo.gctx.releaseResource(compute_bgl);

    demo.sim.supplyShock();
    demo.buffers.data.producer = Shapes.createProducerBuffer(demo.gctx, demo.sim.producers);
    demo.bind_groups.compute = Shapes.createBindGroup(demo.gctx, demo.sim, demo.buffers.data.consumer, demo.buffers.data.producer, demo.buffers.data.stats);
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
        break :scale_factor math.max(scale[0], scale[1]);
    };

    zgui.init(allocator);
    defer zgui.deinit();

    zgui.plot.init();
    defer zgui.plot.deinit();

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
