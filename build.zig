const std = @import("std");
const builtin = @import("builtin");

const DEFAULT_MACOS_SDK_PATH = ".zig-cache/macos-sdk/MacOSX11.3.sdk";
const DEFAULT_MACOS_SDK_URL = "https://github.com/joseluisq/macosx-sdks/releases/download/11.3/MacOSX11.3.sdk.tar.xz";

fn resolveMacosSdkPath(
    b: *std.Build,
    macos_sdk_option: ?[]const u8,
) ?[]const u8 {
    if (macos_sdk_option) |path| {
        return path;
    }
    return b.graph.env_map.get("MACOS_SDK_ROOT");
}

fn absolutizePath(
    b: *std.Build,
    input_path: []const u8,
) []const u8 {
    if (std.fs.path.isAbsolute(input_path)) {
        return input_path;
    }
    const cwd = std.process.getCwdAlloc(b.allocator) catch return input_path;
    return std.fs.path.resolve(b.allocator, &.{ cwd, input_path }) catch input_path;
}

fn optimizeModeName(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };
}

fn appendUniqueCFlag(
    b: *std.Build,
    flags: []const []const u8,
    new_flag: []const u8,
) []const []const u8 {
    for (flags) |flag| {
        if (std.mem.eql(u8, flag, new_flag)) {
            return flags;
        }
    }

    const merged = b.allocator.alloc([]const u8, flags.len + 1) catch @panic("OOM");
    @memcpy(merged[0..flags.len], flags);
    merged[flags.len] = new_flag;
    return merged;
}

fn addEnsureMacosSdkStep(
    b: *std.Build,
    sdk_root: []const u8,
    sdk_url: []const u8,
) *std.Build.Step {
    const archive_path = b.fmt("{s}.tar.xz", .{sdk_root});
    const script =
        \\set -euo pipefail
        \\if [ -d "$CM_MACOS_SDK_ROOT" ]; then
        \\  exit 0
        \\fi
        \\mkdir -p "$(dirname "$CM_MACOS_SDK_ROOT")"
        \\if [ ! -f "$CM_MACOS_SDK_ARCHIVE" ]; then
        \\  if command -v curl >/dev/null 2>&1; then
        \\    curl -L --fail "$CM_MACOS_SDK_URL" -o "$CM_MACOS_SDK_ARCHIVE"
        \\  elif command -v wget >/dev/null 2>&1; then
        \\    wget -O "$CM_MACOS_SDK_ARCHIVE" "$CM_MACOS_SDK_URL"
        \\  else
        \\    echo "Neither curl nor wget is available to download macOS SDK." >&2
        \\    exit 1
        \\  fi
        \\fi
        \\tar -xf "$CM_MACOS_SDK_ARCHIVE" -C "$(dirname "$CM_MACOS_SDK_ROOT")"
        \\if [ ! -d "$CM_MACOS_SDK_ROOT" ]; then
        \\  echo "macOS SDK extraction failed: $CM_MACOS_SDK_ROOT not found." >&2
        \\  exit 1
        \\fi
    ;

    const cmd = b.addSystemCommand(&.{ "bash", "-lc", script });
    cmd.setEnvironmentVariable("CM_MACOS_SDK_ROOT", sdk_root);
    cmd.setEnvironmentVariable("CM_MACOS_SDK_ARCHIVE", archive_path);
    cmd.setEnvironmentVariable("CM_MACOS_SDK_URL", sdk_url);
    return &cmd.step;
}

fn addMatrixInstallCommand(
    b: *std.Build,
    step: *std.Build.Step,
    target_triple: []const u8,
    install_name: []const u8,
    maybe_sysroot: ?[]const u8,
    ensure_macos_sdk_step: ?*std.Build.Step,
    frontend_prebuild_step: ?*std.Build.Step,
    optimize: std.builtin.OptimizeMode,
) void {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(b.allocator);

    argv.appendSlice(b.allocator, &.{
        "zig",
        "build",
        "install",
        "--prefix",
        "zig-out",
    }) catch @panic("OOM");
    argv.append(b.allocator, b.fmt("-Doptimize={s}", .{optimizeModeName(optimize)})) catch @panic("OOM");
    argv.appendSlice(b.allocator, &.{"-Dskip_frontend=true"}) catch @panic("OOM");

    if (maybe_sysroot) |sysroot| {
        argv.appendSlice(b.allocator, &.{ "--sysroot", sysroot }) catch @panic("OOM");
    }

    argv.append(b.allocator, b.fmt("-Dtarget={s}", .{target_triple})) catch @panic("OOM");
    argv.append(b.allocator, b.fmt("-Dmatrix_name={s}", .{install_name})) catch @panic("OOM");

    const cmd = b.addSystemCommand(argv.items);
    if (ensure_macos_sdk_step) |download_step| {
        cmd.step.dependOn(download_step);
    }
    if (frontend_prebuild_step) |frontend_step| {
        cmd.step.dependOn(frontend_step);
    }
    step.dependOn(&cmd.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const matrix_name = b.option([]const u8, "matrix_name", "Override installed binary name");
    const skip_frontend = b.option(
        bool,
        "skip_frontend",
        "Skip frontend npm typecheck/build steps (for internal matrix sub-builds).",
    ) orelse false;
    const macos_sdk_option = b.option(
        []const u8,
        "macos_sdk",
        "Path to a macOS SDK for macOS cross-compilation (sysroot).",
    );
    const macos_sdk_auto_download = b.option(
        bool,
        "macos_sdk_auto_download",
        "Automatically download macOS SDK when needed for macOS cross-compilation.",
    ) orelse false;
    const macos_sdk_url = b.option(
        []const u8,
        "macos_sdk_url",
        "URL used when automatically downloading the macOS SDK.",
    ) orelse DEFAULT_MACOS_SDK_URL;

    var macos_sdk_path = resolveMacosSdkPath(b, macos_sdk_option);
    if (macos_sdk_path == null and macos_sdk_auto_download and builtin.os.tag == .linux) {
        macos_sdk_path = DEFAULT_MACOS_SDK_PATH;
    }
    if (macos_sdk_path) |sdk| {
        macos_sdk_path = absolutizePath(b, sdk);
    }

    var ensure_macos_sdk_step: ?*std.Build.Step = null;
    if (macos_sdk_auto_download and builtin.os.tag == .linux) {
        if (macos_sdk_path) |sdk| {
            ensure_macos_sdk_step = addEnsureMacosSdkStep(b, sdk, macos_sdk_url);
        }
    }

    if (!target.query.isNative() and target.result.os.tag == .macos and b.sysroot == null) {
        const fail = b.addFail(
            "Cross-compiling to macOS requires --sysroot <sdk>. For matrix builds, use `zig build build-all-targets -Dmacos_sdk_auto_download=true`.",
        );
        b.default_step.dependOn(&fail.step);
        b.getInstallStep().dependOn(&fail.step);
        return;
    }

    var frontend_build_step: ?*std.Build.Step = null;
    if (!skip_frontend) {
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
        frontend_build_step = &frontend_build.step;
    }

    const webui_dep = b.dependency("webui", .{
        .target = target,
        .optimize = optimize,
        .dynamic = false,
        .@"enable-tls" = false,
        .@"enable-webui-log" = false,
    });
    const webui_module = webui_dep.module("webui");
    if (target.result.os.tag == .macos) {
        if (b.sysroot) |sysroot| {
            const frameworks_path = b.fmt("{s}/System/Library/Frameworks", .{sysroot});
            const sdk_usr_include = b.fmt("{s}/usr/include", .{sysroot});
            webui_module.addFrameworkPath(.{ .cwd_relative = frameworks_path });
            webui_module.addSystemIncludePath(.{ .cwd_relative = sdk_usr_include });
            for (webui_module.link_objects.items) |link_object| {
                switch (link_object) {
                    .other_step => |linked_compile| {
                        linked_compile.root_module.addFrameworkPath(.{ .cwd_relative = frameworks_path });
                        linked_compile.root_module.addSystemIncludePath(.{ .cwd_relative = sdk_usr_include });
                        for (linked_compile.root_module.link_objects.items) |*compile_link_object| {
                            switch (compile_link_object.*) {
                                .c_source_file => |c_source_file| {
                                    c_source_file.flags = appendUniqueCFlag(
                                        b,
                                        c_source_file.flags,
                                        "-Wno-error=gnu-folding-constant",
                                    );
                                },
                                .c_source_files => |c_source_files| {
                                    c_source_files.flags = appendUniqueCFlag(
                                        b,
                                        c_source_files.flags,
                                        "-Wno-error=gnu-folding-constant",
                                    );
                                },
                                else => {},
                            }
                        }
                    },
                    else => {},
                }
            }
        }
        if (!target.query.isNative()) {
            if (ensure_macos_sdk_step) |download_step| {
                for (webui_module.link_objects.items) |link_object| {
                    switch (link_object) {
                        .other_step => |linked_compile| {
                            linked_compile.step.dependOn(download_step);
                        },
                        else => {},
                    }
                }
            }
        }
    }

    const exe = b.addExecutable(.{
        .name = "codex-manager",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "webui", .module = webui_module },
            },
        }),
    });
    if (frontend_build_step) |frontend_step| {
        exe.step.dependOn(frontend_step);
    }
    if (!target.query.isNative() and target.result.os.tag == .macos) {
        if (ensure_macos_sdk_step) |download_step| {
            exe.step.dependOn(download_step);
        }
    }

    const install_artifact = b.addInstallArtifact(exe, .{
        .dest_sub_path = matrix_name,
        .pdb_dir = if (matrix_name == null) .default else .disabled,
    });
    b.getInstallStep().dependOn(&install_artifact.step);

    const dev_step = b.step("dev", "Build frontend and run Codex Manager in dev mode");
    const run_cmd = b.addRunArtifact(exe);
    if (frontend_build_step) |frontend_step| {
        run_cmd.step.dependOn(frontend_step);
    }
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
                null,
                frontend_build_step,
                optimize,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-linux-gnu",
                "codex-manager-linux-aarch64",
                null,
                null,
                frontend_build_step,
                optimize,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "x86_64-windows-gnu",
                "codex-manager-windows-x86_64.exe",
                null,
                null,
                frontend_build_step,
                optimize,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-windows-gnu",
                "codex-manager-windows-aarch64.exe",
                null,
                null,
                frontend_build_step,
                optimize,
            );

            if (macos_sdk_path) |macos_sdk_root| {
                if (macos_sdk_root.len > 0) {
                    addMatrixInstallCommand(
                        b,
                        build_all_targets_step,
                        "x86_64-macos",
                        "codex-manager-macos-x86_64",
                        macos_sdk_root,
                        ensure_macos_sdk_step,
                        frontend_build_step,
                        optimize,
                    );
                    addMatrixInstallCommand(
                        b,
                        build_all_targets_step,
                        "aarch64-macos",
                        "codex-manager-macos-aarch64",
                        macos_sdk_root,
                        ensure_macos_sdk_step,
                        frontend_build_step,
                        optimize,
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
                null,
                frontend_build_step,
                optimize,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-macos",
                "codex-manager-macos-aarch64",
                null,
                null,
                frontend_build_step,
                optimize,
            );
        },
        .windows => {
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "x86_64-windows-gnu",
                "codex-manager-windows-x86_64.exe",
                null,
                null,
                frontend_build_step,
                optimize,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-windows-gnu",
                "codex-manager-windows-aarch64.exe",
                null,
                null,
                frontend_build_step,
                optimize,
            );
        },
        else => {},
    }
}
