const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const frontend_install = b.addSystemCommand(&.{
        "bash",
        "-lc",
        "test -d frontend/node_modules || npm --prefix frontend ci --no-audit --no-fund",
    });

    const frontend_typecheck = b.addSystemCommand(&.{
        "npm",
        "--prefix",
        "frontend",
        "exec",
        "--",
        "tsc",
        "-p",
        "frontend/tsconfig.json",
        "--noEmit",
    });
    frontend_typecheck.step.dependOn(&frontend_install.step);

    const frontend_build_web = b.addSystemCommand(&.{
        "npm",
        "--prefix",
        "frontend",
        "exec",
        "--",
        "vite",
        "build",
        "--config",
        "frontend/vite.config.ts",
        "--outDir",
        "dist-web",
    });
    frontend_build_web.step.dependOn(&frontend_typecheck.step);
    frontend_build_web.setEnvironmentVariable("VITE_SHOW_WINDOW_BAR", "0");

    const frontend_build_desktop = b.addSystemCommand(&.{
        "npm",
        "--prefix",
        "frontend",
        "exec",
        "--",
        "vite",
        "build",
        "--config",
        "frontend/vite.config.ts",
        "--outDir",
        "dist-desktop",
    });
    frontend_build_desktop.step.dependOn(&frontend_typecheck.step);
    frontend_build_desktop.setEnvironmentVariable("VITE_SHOW_WINDOW_BAR", "1");

    const zig_webui = b.dependency("zig_webui", .{
        .target = target,
        .optimize = optimize,
        .enable_tls = false,
        .is_static = true,
    });

    const exe = b.addExecutable(.{
        .name = "codex-manager",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "webui", .module = zig_webui.module("webui") },
            },
        }),
    });
    exe.step.dependOn(&frontend_build_web.step);
    exe.step.dependOn(&frontend_build_desktop.step);

    b.installArtifact(exe);

    const dev_step = b.step("dev", "Build frontend and run Codex Manager in dev mode");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&frontend_build_web.step);
    run_cmd.step.dependOn(&frontend_build_desktop.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    dev_step.dependOn(&run_cmd.step);

    const backend_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rpc.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "webui", .module = zig_webui.module("webui") },
            },
        }),
    });

    const run_backend_tests = b.addRunArtifact(backend_tests);
    const test_step = b.step("test", "Run backend Zig tests");
    test_step.dependOn(&run_backend_tests.step);
}
