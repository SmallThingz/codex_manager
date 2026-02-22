const std = @import("std");
const builtin = @import("builtin");

fn addMatrixInstallCommand(
    b: *std.Build,
    step: *std.Build.Step,
    target_triple: []const u8,
    install_name: []const u8,
    maybe_sysroot: ?[]const u8,
) void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(b.allocator);

    argv.appendSlice(b.allocator, &.{
        "zig",
        "build",
        "install",
        "--prefix",
        "zig-out",
        "-Doptimize=ReleaseFast",
    }) catch @panic("OOM");

    if (maybe_sysroot) |sysroot| {
        argv.appendSlice(b.allocator, &.{ "--sysroot", sysroot }) catch @panic("OOM");
    }

    argv.append(b.allocator, b.fmt("-Dtarget={s}", .{target_triple})) catch @panic("OOM");
    argv.append(b.allocator, b.fmt("-Dmatrix_name={s}", .{install_name})) catch @panic("OOM");

    const cmd = b.addSystemCommand(argv.items);
    step.dependOn(&cmd.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const matrix_name = b.option([]const u8, "matrix_name", "Override installed binary name");

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

    const frontend_build = b.addSystemCommand(&.{
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
        "dist",
    });
    frontend_build.step.dependOn(&frontend_typecheck.step);

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
    exe.step.dependOn(&frontend_build.step);

    const install_artifact = b.addInstallArtifact(exe, .{
        .dest_sub_path = matrix_name,
        .pdb_dir = if (matrix_name == null) .default else .disabled,
    });
    b.getInstallStep().dependOn(&install_artifact.step);

    const dev_step = b.step("dev", "Build frontend and run Codex Manager in dev mode");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(&frontend_build.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    dev_step.dependOn(&run_cmd.step);

    const backend_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rpc.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_backend_tests = b.addRunArtifact(backend_tests);
    const test_step = b.step("test", "Run backend Zig tests");
    test_step.dependOn(&run_backend_tests.step);

    const build_all_targets_step = b.step(
        "build-all-targets",
        "Compile release binaries for supported target matrix into zig-out/bin",
    );

    switch (builtin.os.tag) {
        .linux => {
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "x86_64-linux-gnu",
                "codex-manager-linux-x86_64",
                null,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-linux-gnu",
                "codex-manager-linux-aarch64",
                null,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "x86_64-windows-gnu",
                "codex-manager-windows-x86_64",
                null,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-windows-gnu",
                "codex-manager-windows-aarch64",
                null,
            );

            if (b.graph.env_map.get("MACOS_SDK_ROOT")) |macos_sdk_root| {
                if (macos_sdk_root.len > 0) {
                    addMatrixInstallCommand(
                        b,
                        build_all_targets_step,
                        "x86_64-macos",
                        "codex-manager-macos-x86_64",
                        macos_sdk_root,
                    );
                    addMatrixInstallCommand(
                        b,
                        build_all_targets_step,
                        "aarch64-macos",
                        "codex-manager-macos-aarch64",
                        macos_sdk_root,
                    );
                }
            }
        },
        .macos => {
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "x86_64-macos",
                "codex-manager-macos-x86_64",
                null,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-macos",
                "codex-manager-macos-aarch64",
                null,
            );
        },
        .windows => {
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "x86_64-windows-gnu",
                "codex-manager-windows-x86_64",
                null,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-windows-gnu",
                "codex-manager-windows-aarch64",
                null,
            );
        },
        else => {},
    }
}
