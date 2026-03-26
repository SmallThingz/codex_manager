const std = @import("std");
const builtin = @import("builtin");

fn resolveMacosSdkPath(
    b: *std.Build,
    macos_sdk_option: ?[]const u8,
) ?[]const u8 {
    if (macos_sdk_option) |path| {
        return path;
    }
    return b.graph.environ_map.get("MACOS_SDK_ROOT");
}

fn absolutizePath(
    b: *std.Build,
    input_path: []const u8,
) []const u8 {
    if (std.fs.path.isAbsolute(input_path)) {
        return input_path;
    }
    return std.Io.Dir.cwd().realPathFileAlloc(b.graph.io, input_path, b.allocator) catch input_path;
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

fn addMacosSdkAutoDownloadStep(
    b: *std.Build,
    cache_dir: []const u8,
    sdk_dir: []const u8,
) *std.Build.Step.Run {
    const script =
        \\set -euo pipefail
        \\cache_dir="$1"
        \\sdk_dir="$2"
        \\metadata_url="$3"
        \\release_json="$cache_dir/latest-release.json"
        \\archive_path="$cache_dir/macos-sdk.tar.xz"
        \\staging_dir="$cache_dir/staging"
        \\
        \\if [ -d "$sdk_dir" ]; then
        \\  exit 0
        \\fi
        \\
        \\mkdir -p "$cache_dir"
        \\rm -rf "$staging_dir"
        \\trap 'rm -rf "$staging_dir"' EXIT
        \\
        \\echo "Downloading macOS SDK metadata from $metadata_url" >&2
        \\curl --fail --silent --show-error --location \
        \\  -H 'Accept: application/vnd.github+json' \
        \\  -H 'User-Agent: codex-manager-build' \
        \\  "$metadata_url" -o "$release_json"
        \\
        \\asset_url="$(sed -nE 's/.*"browser_download_url"[[:space:]]*:[[:space:]]*"([^"]*MacOSX[^"]*\\.sdk\\.tar\\.xz)".*/\1/p' "$release_json" | head -n 1)"
        \\if [ -z "$asset_url" ]; then
        \\  echo "Could not find a MacOSX*.sdk.tar.xz asset in $metadata_url." >&2
        \\  echo "Set -Dmacos_sdk=<path> or MACOS_SDK_ROOT to use a local SDK instead." >&2
        \\  echo "Metadata excerpt:" >&2
        \\  sed -n '1,80p' "$release_json" >&2 || true
        \\  exit 1
        \\fi
        \\
        \\echo "Downloading macOS SDK archive from $asset_url" >&2
        \\curl --fail --silent --show-error --location \
        \\  -H 'User-Agent: codex-manager-build' \
        \\  "$asset_url" -o "$archive_path"
        \\
        \\mkdir -p "$staging_dir"
        \\tar -xf "$archive_path" -C "$staging_dir"
        \\
        \\found_sdk="$(find "$staging_dir" -type d -name 'MacOSX*.sdk' -print -quit)"
        \\if [ -z "$found_sdk" ]; then
        \\  echo "Downloaded archive did not contain a MacOSX*.sdk directory." >&2
        \\  exit 1
        \\fi
        \\
        \\rm -rf "$sdk_dir"
        \\mv "$found_sdk" "$sdk_dir"
        \\rm -f "$release_json" "$archive_path"
    ;

    return b.addSystemCommand(&.{
        "bash",
        "-lc",
        script,
        "download-macos-sdk",
        cache_dir,
        sdk_dir,
        "https://api.github.com/repos/joseluisq/macosx-sdks/releases/latest",
    });
}

fn addMatrixInstallCommand(
    b: *std.Build,
    step: *std.Build.Step,
    target_triple: []const u8,
    install_name: []const u8,
    maybe_sysroot: ?[]const u8,
    frontend_prebuild_step: ?*std.Build.Step,
    extra_dependency_step: ?*std.Build.Step,
    optimize: std.builtin.OptimizeMode,
    strip_symbols: bool,
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
    argv.append(b.allocator, b.fmt("-Dstrip={}", .{strip_symbols})) catch @panic("OOM");
    argv.appendSlice(b.allocator, &.{"-Dskip_frontend=true"}) catch @panic("OOM");

    if (maybe_sysroot) |sysroot| {
        argv.appendSlice(b.allocator, &.{ "--sysroot", sysroot }) catch @panic("OOM");
    }

    argv.append(b.allocator, b.fmt("-Dtarget={s}", .{target_triple})) catch @panic("OOM");
    argv.append(b.allocator, b.fmt("-Dmatrix_name={s}", .{install_name})) catch @panic("OOM");

    const cmd = b.addSystemCommand(argv.items);
    if (frontend_prebuild_step) |frontend_step| {
        cmd.step.dependOn(frontend_step);
    }
    if (extra_dependency_step) |dependency_step| {
        cmd.step.dependOn(dependency_step);
    }
    step.dependOn(&cmd.step);
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip_symbols = b.option(bool, "strip", "Strip debug symbols from binaries.") orelse false;
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
    const auto_download_macos_sdk = b.option(
        bool,
        "auto_download_macos_sdk",
        "Automatically download a cached macOS SDK on Linux when build-all-targets needs one.",
    ) orelse true;
    const macos_sdk_cache_dir = absolutizePath(
        b,
        b.option(
            []const u8,
            "macos_sdk_cache_dir",
            "Directory used to cache an auto-downloaded macOS SDK on Linux.",
        ) orelse ".zig-cache/macos-sdk",
    );

    var macos_sdk_path = resolveMacosSdkPath(b, macos_sdk_option);
    if (macos_sdk_path) |sdk| {
        macos_sdk_path = absolutizePath(b, sdk);
    }

    if (!target.query.isNative() and target.result.os.tag == .macos and b.sysroot == null) {
        const fail = b.addFail(
            "Cross-compiling to macOS requires --sysroot <sdk>. Provide one via --sysroot, -Dmacos_sdk=<path>, or MACOS_SDK_ROOT.",
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
    }

    const exe = b.addExecutable(.{
        .name = "codex-manager",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_symbols,
            .imports = &.{
                .{ .name = "webui", .module = webui_module },
            },
        }),
    });
    if (frontend_build_step) |frontend_step| {
        exe.step.dependOn(frontend_step);
    }
    const install_artifact = b.addInstallArtifact(exe, .{
        .dest_sub_path = matrix_name,
        .pdb_dir = if (matrix_name == null) .default else .disabled,
    });
    b.getInstallStep().dependOn(&install_artifact.step);

    const dev_step = b.step("dev", "Build frontend and run Codex Manager in dev mode");
    const installed_exe_name = matrix_name orelse "codex-manager";
    const installed_exe_path = b.getInstallPath(.bin, installed_exe_name);
    const dev_runner_script =
        \\set -euo pipefail
        \\ulimit -c unlimited || true
        \\export ZIG_BACKTRACE=full
        \\if [ "${CM_DEV_NO_GDB:-0}" = "1" ]; then
        \\  exec "$0" "$@"
        \\fi
        \\if command -v gdb >/dev/null 2>&1; then
        \\  exec gdb -q -nx -batch \
        \\    -iex "set debuginfod enabled off" \
        \\    -ex "set pagination off" \
        \\    -ex "set confirm off" \
        \\    -ex "set print thread-events off" \
        \\    -ex "run" \
        \\    -ex "thread apply all bt full" \
        \\    -ex "quit" \
        \\    --args "$0" "$@"
        \\fi
        \\exec "$0" "$@"
    ;

    const run_cmd = b.addSystemCommand(&.{ "bash", "-lc", dev_runner_script, installed_exe_path });
    run_cmd.step.dependOn(&install_artifact.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    dev_step.dependOn(&run_cmd.step);

    const backend_tests = b.addTest(.{
        .root_module = b.createModule(.{
            // Keep package root at repo root so @embedFile("../frontend/...") used by
            // imported modules remains inside package boundaries during tests.
            .root_source_file = b.path("rpc_tests.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip_symbols,
        }),
    });

    const run_backend_tests = b.addRunArtifact(backend_tests);
    const test_step = b.step("test", "Run backend Zig tests");
    test_step.dependOn(&run_backend_tests.step);

    const build_all_targets_step = b.step(
        "build-all-targets",
        "Compile release binaries for supported target matrix into zig-out/bin",
    );
    const auto_downloaded_macos_sdk_path = b.fmt("{s}/sdk", .{macos_sdk_cache_dir});
    var matrix_macos_sdk_path = macos_sdk_path;
    var matrix_macos_sdk_step: ?*std.Build.Step = null;

    if (builtin.os.tag == .linux and matrix_macos_sdk_path == null and auto_download_macos_sdk) {
        const download_macos_sdk = addMacosSdkAutoDownloadStep(
            b,
            macos_sdk_cache_dir,
            auto_downloaded_macos_sdk_path,
        );
        matrix_macos_sdk_path = auto_downloaded_macos_sdk_path;
        matrix_macos_sdk_step = &download_macos_sdk.step;
    }

    switch (builtin.os.tag) {
        .linux => {
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "x86_64-linux-gnu",
                "codex-manager-linux-x86_64",
                null,
                frontend_build_step,
                null,
                optimize,
                strip_symbols,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-linux-gnu",
                "codex-manager-linux-aarch64",
                null,
                frontend_build_step,
                null,
                optimize,
                strip_symbols,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "x86_64-windows-gnu",
                "codex-manager-windows-x86_64.exe",
                null,
                frontend_build_step,
                null,
                optimize,
                strip_symbols,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-windows-gnu",
                "codex-manager-windows-aarch64.exe",
                null,
                frontend_build_step,
                null,
                optimize,
                strip_symbols,
            );

            if (matrix_macos_sdk_path) |macos_sdk_root| {
                if (macos_sdk_root.len > 0) {
                    addMatrixInstallCommand(
                        b,
                        build_all_targets_step,
                        "x86_64-macos",
                        "codex-manager-macos-x86_64",
                        macos_sdk_root,
                        frontend_build_step,
                        matrix_macos_sdk_step,
                        optimize,
                        strip_symbols,
                    );
                    addMatrixInstallCommand(
                        b,
                        build_all_targets_step,
                        "aarch64-macos",
                        "codex-manager-macos-aarch64",
                        macos_sdk_root,
                        frontend_build_step,
                        matrix_macos_sdk_step,
                        optimize,
                        strip_symbols,
                    );
                }
            } else {
                const missing_macos_sdk = b.addFail(
                    "build-all-targets on Linux could not resolve a macOS SDK. Set -Dmacos_sdk=<path>, MACOS_SDK_ROOT, or leave auto-download enabled.",
                );
                build_all_targets_step.dependOn(&missing_macos_sdk.step);
            }
        },
        .macos => {
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "x86_64-macos",
                "codex-manager-macos-x86_64",
                null,
                frontend_build_step,
                null,
                optimize,
                strip_symbols,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-macos",
                "codex-manager-macos-aarch64",
                null,
                frontend_build_step,
                null,
                optimize,
                strip_symbols,
            );
        },
        .windows => {
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "x86_64-windows-gnu",
                "codex-manager-windows-x86_64.exe",
                null,
                frontend_build_step,
                null,
                optimize,
                strip_symbols,
            );
            addMatrixInstallCommand(
                b,
                build_all_targets_step,
                "aarch64-windows-gnu",
                "codex-manager-windows-aarch64.exe",
                null,
                frontend_build_step,
                null,
                optimize,
                strip_symbols,
            );
        },
        else => {},
    }
}
