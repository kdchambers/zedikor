// SPDX-License-Identifier: GPL-3.0
// Copyright (c) 2021 Keith Chambers
// This program is free software: you can redistribute it and/or modify it under the terms
// of the GNU General Public License as published by the Free Software Foundation, version 3.

const std = @import("std");

const Builder = std.build.Builder;
const Build = std.build;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zedikor", "src/core.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);

    exe.addIncludeDir("/usr/include/");
    exe.addIncludeDir("/usr/include/freetype2");

    exe.addPackagePath("vulkan", "external/vulkan/vulkan.zig");
    exe.addPackagePath("geometry", "src/geometry.zig");
    exe.addPackagePath("graphics", "src/graphics.zig");
    exe.addPackagePath("text", "src/text.zig");
    exe.addPackagePath("gui", "src/gui.zig");

    exe.linkSystemLibrary("c");
    exe.linkSystemLibrary("vulkan");
    exe.linkSystemLibrary("glfw");
    exe.linkSystemLibrary("freetype");

    exe.install();

    const run_cmd = exe.run();
    if (b.args) |args| run_cmd.addArgs(args);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run zedikor");
    run_step.dependOn(&run_cmd.step);
}
