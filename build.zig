// SPDX-License-Identifier: MPL-2.0
//   Copyright © 2026 Chris Marchesi

//! This is the build file for the z2d demo cart for the SYCL Badge v2, the
//! electronic badge given out at the Vancouver SYCL 2026 Conference's tables
//! day. The repository for the badge OS and other carts can be found at:
//!
//!     https://github.com/ZigEmbeddedGroup/sycl-badge
//!
//! Note that the build file here, while pulling the various OS kernel files
//! from the upstream badge project so that it can be built respectively with
//! MicroZig, operates fairly independently of the sycl-badge project. There
//! are some helpers for building carts that exist there, but they are coupled
//! to static local variables that would not be initialized when normally
//! working with these helpers outside of the main badge project. This is not
//! too much of an issue, as we can fairly easily mirror the functionality
//! needed to build the cart directly with MicroZig. This is what we do here.
const std = @import("std");
const microzig = @import("microzig");

/// Defines our default target matrix. These are the targets that will be
/// loaded in as dependencies when we initialize MicroBuild in the main
/// function.
const MicroBuild = microzig.MicroBuild(.{
    .rp2xxx = true,
});

pub fn build(b: *std.Build) void {
    // Our default optimize mode is ReleaseSmall.
    const optimize: std.builtin.OptimizeMode = .ReleaseSmall;
    // Badge dependency (for various badge OS/kernel/API files)
    const badge_dep = b.dependency("sycl_badge", .{});
    // z2d needs the optimize option passed in that we have above to ensure
    // that it gets set properly, otherwise it will likely default to Debug.
    const z2d_dep = b.dependency("z2d", .{ .optimize = optimize, .float_precision = .single });

    // Load in MicroBuild. Targets are lazily loaded, so we need to account for
    // that.
    const mz_dep = b.dependency("microzig", .{});
    const mb = MicroBuild.init(b, mz_dep) orelse return;

    // This is the full badge target (e.g., the badge itself, versus just the
    // RPi 2354 inside of it).
    const badge_target = target: {
        const base_target = mb.ports.rp2xxx.boards.raspberrypi.pico2_arm;
        break :target base_target.derive(.{
            .board = .{
                // For the SYCL v2 badge, taken from the badge SDK's build.zig
                .name = "SYCL Badge V2",
                .root_source_file = badge_dep.builder.path("src/board_v2.zig"),
            },
        });
    };

    // The cart API (generally how carts interact with the badge OS)
    const cart_api_module = b.createModule(.{
        .root_source_file = badge_dep.builder.path("src/os/cart/cart-api.zig"),
        .imports = &.{
            .{
                .name = "font",
                .module = b.createModule(.{
                    .root_source_file = badge_dep.builder.path("src/os/font.zig"),
                }),
            },
            .{
                // TODO: Not too sure if we can just get rid of Tracy here if we don't need it
                .name = "tracy_protocol",
                .module = b.createModule(.{
                    .root_source_file = badge_dep.builder.path("src/os/system/tracy_protocol.zig"),
                }),
            },
        },
    });

    // The main cart firmware instance. The root file here is the cart entry
    // point.
    const cart_firmware = mb.add_firmware(.{
        .name = "z2d-demo",
        .target = badge_target,
        .optimize = optimize,
        .root_source_file = b.path("src/z2d-demo.zig"),
        .linker_script = .{
            // Note that we have to patch the cart linker script as there are
            // currently some missing symbols to make the MicroZig allocator
            // functional. See the patchLinkerScript function for more details.
            .file = patchLinkerScript(b, badge_dep.builder.path("src/os/cart/badge_cart.ld")),
            .generate = .none,
            .assert_microzig_main = false,
        },
    });

    // Add our API imports that aren't automatically added by MicroBuild into
    // the cart.
    cart_firmware.exe.root_module.addImport("cart-api", cart_api_module);
    cart_firmware.exe.root_module.addImport("z2d", z2d_dep.module("z2d"));

    // This is a workaround to avoid import conflict that can arise around the
    // internal font functionality in the badge repository. See "add_cart"
    // there for more details.
    const board_mod = cart_firmware.core_mod.import_table.get("board") orelse unreachable;
    cart_api_module.addImport("board", board_mod);

    // Firmware install step. We use the same directories as is expected in the
    // badge repository for carts.
    const install_uf2 = mb.add_install_firmware(
        cart_firmware,
        .{ .format = .{ .uf2 = .{ .family_id = .RP2350_ARM_S } } },
    );
    const install_elf = mb.add_install_firmware(cart_firmware, .{ .format = .elf });
    install_uf2.dir = .{ .custom = "carts" };
    install_elf.dir = .{ .custom = "carts/debug" };
    b.getInstallStep().dependOn(&install_uf2.step);
    b.getInstallStep().dependOn(&install_elf.step);
}

/// Patches the sycl-badge cart linker script to add symbols needed by MicroZig
/// that are currently not present, namely the heap marker symbols that are
/// needed by MicroZig GPA.
fn patchLinkerScript(b: *std.Build, in_path: std.Build.LazyPath) std.Build.LazyPath {
    const data =
        \\
        \\/* Required for using the MicroZig core heap allocator */
        \\microzig_heap_start = __heap_start__;
        \\microzig_heap_end = __stack_top__;
    ;

    const cat_cmd = b.addSystemCommand(&.{"cat"});
    cat_cmd.addFileArg(in_path);
    cat_cmd.addArg("-");
    cat_cmd.setStdIn(.{ .bytes = data });
    const result = cat_cmd.captureStdOut(.{ .basename = "badge_cart_patched.ld" });
    return result;
}
