// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2026 Chris Marchesi
const std = @import("std");
const cart = @import("cart-api");
const microzig = @import("microzig");
const z2d = @import("z2d");

// Screen dimensions
const width = cart.screen_width;
const height = cart.screen_height;
const margin = 5;

// Our "identity" transformation matrix. Due to how the framebuffer is
// currently laid out (we hopefully will be able to align this row-major
// eventually), we need to rotate and flip any path we enter. We apply
// additional transformations on top of this.
const identity_transformation = z2d.Transformation.identity
    .rotate(-std.math.pi / 2.0)
    .scale(-1.0, 1.0);

// Populated at startup
var start_time: u64 = undefined;
var heap_alloc: microzig.Allocator = undefined;
var frontbuffer_surface: z2d.Surface = undefined;
var backbuffer_surface: z2d.Surface = undefined;

// Current running demo (initialized on demo start/first frame)
var demo: ?Demo = null;

// Updated every tick (see update function)
var elapsed_time: u64 = undefined;

// Buffers for errors
var render_err_buf: [128]u8 = undefined;

comptime {
    cart.export_start_code();
}

pub fn start() void {
    // Init our heap allocator. We leave a reasonable amount for the stack.
    // Note that we've actually been able to do it with much less stack
    // reserve, but this should hopefully future-proof it, but we likely have
    // more allowance for the heap if need be.
    heap_alloc = microzig.Allocator.init_with_heap(16384) catch |err| {
        std.debug.panic("alloc init err: {t}", .{err});
    };

    // Init our surfaces, direct off our framebuffers. Note that we have to
    // swap height and width right now due to how the cart memory is arranged,
    // we can change this back once we switch to row-major instead of
    // column-major memory alignment.
    inline for (.{ &frontbuffer_surface, &backbuffer_surface }, 0..) |sfc, idx| {
        sfc.* = z2d.Surface.initBuffer(
            .image_surface_rgb565,
            null,
            @ptrCast(cart.platform.framebuffers[idx]),
            height,
            width,
        );
    }

    // Set our double buffering mode to .clear_full_frame. We can do this in
    // z2d as well (and then just use .no_copy_full_frame), but this is
    // *supposed* to be faster (it's not fully implemented in the badge kernel
    // yet, though).
    cart.set_double_buffer_mode(.{ .clear_full_frame = .{ .r = 0, .g = 0, .b = 0 } });

    // Done, log our start time
    start_time = cart.micros_since_boot();
}

pub fn update() void {
    // Check to see we are finished our current demo before rendering. This
    // allows us to switch the demo if need be and also do renders from zero
    // progress.
    checkSwitchDemo() catch |err| {
        renderErr("init err:\n{t}", .{err});
        return;
    };

    // Acquire our current surface
    const surface: *z2d.Surface = switch (cart.framebufferIndex()) {
        0 => &frontbuffer_surface,
        1 => &backbuffer_surface,
    };

    // Try the render
    if (demo) |*d|
        d.render(heap_alloc.allocator(), surface) catch |err| renderErr("render error:\n{t}", .{err});

    // Take our current time, determine our interval, add it to our elapsed
    // time, and update our demo progress.
    const new_elapsed_time = cart.micros_since_boot() - start_time;
    const interval = new_elapsed_time - elapsed_time;
    if (demo) |*d| d.update(interval);
    elapsed_time = new_elapsed_time;
}

fn checkSwitchDemo() !void {
    if (demo) |*d| {
        if (d.done()) {
            d.deinit(heap_alloc.allocator());
            d.* = switch (d.*) {
                .logo => try .init(.crawl, heap_alloc.allocator()),
                .crawl => try .init(.logo, heap_alloc.allocator()),
            };
        }
    } else demo = try .init(.logo, heap_alloc.allocator());
}

fn renderErr(comptime fmt: []const u8, args: anytype) void {
    const msg = std.mem.print(&render_err_buf, fmt, args) catch return;
    cart.text(.{
        .str = msg,
        .x = 0,
        .y = 0,
        .text_color = .{ .r = 31, .g = 63, .b = 31 },
    });
}

const DemoType = enum {
    logo,
    crawl,
};

const Demo = union(DemoType) {
    logo: Logo,
    crawl: Crawl,

    fn init(comptime demo_type: DemoType, alloc: std.mem.Allocator) !Demo {
        // lock FPS to frame value
        cart.set_vsync_enabled(1000.0 / @FieldType(Demo, @tagName(demo_type)).fps);

        return switch (demo_type) {
            .logo => .{ .logo = try .init(alloc) },
            .crawl => .{ .crawl = try .init(alloc) },
        };
    }

    fn deinit(self: *Demo, alloc: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*d| d.deinit(alloc),
        }

        // Disable vsync
        cart.set_vsync_disabled();

        self.* = undefined;
    }

    fn update(self: *Demo, interval: u64) void {
        switch (self.*) {
            inline else => |*d| d.progress.update(interval),
        }
    }

    fn done(self: *const Demo) bool {
        return switch (self.*) {
            inline else => |*d| d.progress.done(),
        };
    }

    fn render(self: *Demo, alloc: std.mem.Allocator, surface: *z2d.Surface) !void {
        switch (self.*) {
            inline else => |*d| try d.render(alloc, surface),
        }
    }

    const Logo = struct {
        // FPS to lock to
        const fps = 60.0;

        // The time to run the demo for in seconds
        const max_s = 5;

        // The HSL cycle factor, controls how fast we cycle through the wheel
        // (lower is faster)
        const hsl_cycle = 1;

        // The z2d logo asset. Our dimensions are stored in the zon file.
        const logo = @import("logo.z2d.zon");
        const logo_scale = (@as(f32, @floatFromInt(width)) - margin * 2.0) / logo.width;

        // Our transformation, centers the logo.
        const transformation = identity_transformation
            .scale(logo_scale, logo_scale) // Scale to fit
            .translate(margin, height - logo.height * logo_scale); // Centers the logo

        path: z2d.Path,
        progress: Progress = .{ .max_us = max_s * 1_000_000 },

        fn init(alloc: std.mem.Allocator) !Logo {
            var path: z2d.Path = try .initCapacity(alloc, logo.len);
            path.transformation = transformation;
            try path.appendSerializedAssumeCapacity(logo.data);
            return .{ .path = path };
        }

        fn deinit(self: *Logo, alloc: std.mem.Allocator) void {
            self.path.deinit(alloc);
            self.* = undefined;
        }

        fn render(self: *Logo, alloc: std.mem.Allocator, surface: *z2d.Surface) !void {
            const hsl_offset = @mod(self.progress.value * max_s / hsl_cycle, 1.0) * 360.0;
            const pattern: z2d.Pattern = .{ .opaque_pattern = .{
                .pixel = .fromColor(.{ .hsl = .{ hsl_offset, 1.0, 0.5 } }),
            } };

            try z2d.painter.fill(alloc, surface, &pattern, self.path.nodes.items, .default);
        }
    };

    const Crawl = struct {
        // FPS to lock to
        const fps = 15.0;

        // The time to run the demo for in seconds
        const max_s = 10;

        // The HSL cycle factor, controls how fast we cycle through the wheel
        // (lower is faster)
        const hsl_cycle = 3;

        // Text crawl asset. Our dimensions are stored in the zon file.
        const text = @import("text_crawl.z2d.zon");

        // Our y-translate (center on y-axis)
        const y_offset = (@as(f32, @floatFromInt(height)) - text.text_extents.height) / 2.0 -
            text.text_extents.y_bearing;

        path: z2d.Path,
        next_idx: usize = 0,
        progress: Progress = .{ .max_us = max_s * 1_000_000 },

        fn init(alloc: std.mem.Allocator) !Crawl {
            const path: z2d.Path = try .initCapacity(alloc, text.path.len);
            return .{ .path = path };
        }

        fn deinit(self: *Crawl, alloc: std.mem.Allocator) void {
            self.path.deinit(alloc);
            self.* = undefined;
        }

        fn render(self: *Crawl, alloc: std.mem.Allocator, surface: *z2d.Surface) !void {
            const hsl_offset = @mod(self.progress.value * max_s / hsl_cycle, 1.0) * 360.0;
            const pattern: z2d.Pattern = .{ .opaque_pattern = .{
                .pixel = .fromColor(.{ .hsl = .{ hsl_offset, 1.0, 0.5 } }),
            } };

            // Our text X offset. We start with the text off-screen the right,
            // and end with it off-screen on the left.
            const x_offset: f32 = @as(f32, @floatFromInt(width)) -
                (self.progress.value * (text.text_extents.width + @as(f32, @floatFromInt(width)))) -
                text.text_extents.x_bearing;

            self.path.reset();
            self.path.transformation = identity_transformation.translate(x_offset, y_offset);
            try self.path.appendSerialized(alloc, text.path.data);

            try z2d.painter.fill(alloc, surface, &pattern, self.path.nodes.items, .default);
        }
    };

    const Progress = struct {
        max_us: u32,
        value: f32 = 0.0,

        fn update(self: *Progress, interval: u64) void {
            self.value += @as(f32, @floatFromInt(interval)) / @as(f32, @floatFromInt(self.max_us));
        }

        fn done(self: *const Progress) bool {
            return self.value >= 1.0;
        }
    };
};
