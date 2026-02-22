# Codex Account Manager

Codex Account Manager is a SolidJS + Zig app (via [zig-webui](https://github.com/webui-dev/zig-webui)) for managing multiple Codex accounts.

It can switch the active `~/.codex/auth.json` on the fly, organize accounts by status, and show remaining usage per account.

## Features

- Manage multiple Codex accounts in one place
- Switch active account instantly
- Credits/usage checks via ChatGPT token flow (`/backend-api/wham/usage`)
- Account buckets:
  - active
  - depleted
  - frozen
- Drag-and-drop reordering in desktop and web modes
- Custom desktop title bar controls:
  - minimize
  - fullscreen toggle
  - close
  - double-click title bar to toggle fullscreen
- Theme persistence (light/dark)

## Tech Stack

- Frontend: SolidJS (`frontend/src`)
- Backend: Zig (`src`, `main.zig`)
- Runtime bridge: `window.cm_rpc(...)` and `window.webui.call(...)`
- Build pipeline: Zig orchestrates frontend typecheck + Vite builds (`build.zig`)

## Requirements

- Zig `0.15+`
- Node.js `20+`
- `npm`
- `curl`
- `codex` CLI

Linux desktop mode also requires GTK/WebKitGTK runtime libraries for WebView.

## Dependency Matrix

### Shared (all OS)

| Type | Dependencies |
|---|---|
| Comptime (build-time) | Zig `0.15.2+`, Node.js `20+`, npm, frontend packages: `solid-js`, `vite`, `vite-plugin-solid`, `typescript` |
| Runtime | `curl` in `PATH`, `codex` CLI in `PATH` |
| Notes | `zig_webui` is vendored via `build.zig.zon` and built as a static Zig dependency (`enable_tls = false`) |

### Linux

| Type | Dependencies |
|---|---|
| Comptime (build-time) | Shared dependencies above; C compilation support via Zig toolchain |
| Runtime (desktop mode `--desktop`) | `libgtk-3.so.0`, `libwebkit2gtk-4.1.so.0` (or `libwebkit2gtk-4.0.so.37`) and their distro-provided transitive libs |
| Runtime (web mode `--web`) | A supported installed browser (default browser launch path) |
| Notes | This project loads GTK/WebKit at runtime via `dlopen`, so missing desktop libs fail at runtime, not compile time |

### macOS

| Type | Dependencies |
|---|---|
| Comptime (build-time) | Shared dependencies above; Xcode Command Line Tools (clang + macOS SDK) for Objective-C/WebKit build path |
| Runtime (desktop mode `--desktop`) | System frameworks: `Cocoa.framework`, `WebKit.framework` |
| Runtime (web mode `--web`) | A default browser |
| Notes | No GTK/WebKitGTK packages are required on macOS |

### Windows

| Type | Dependencies |
|---|---|
| Comptime (build-time) | Shared dependencies above; C/C++ build support and Windows SDK link libs (`ws2_32`, `ole32`, and ABI-specific system libs) |
| Runtime (desktop mode `--desktop`) | Microsoft Edge WebView2 Runtime |
| Runtime (web mode `--web`) | A default browser |
| Notes | WebView2 headers are vendored by the `webui` dependency; no separate header package is required |

## Development

Run in default mode (desktop mode, with automatic fallback to web mode if WebView is unavailable):

```bash
zig build dev
```

Run explicitly in web mode:

```bash
zig build dev -- --web
```

Run in desktop WebView mode:

```bash
zig build dev -- --desktop
```

## Build and Install

Build/install optimized binary:

```bash
zig build install -Doptimize=ReleaseFast
```

Build release binaries for all supported targets:

```bash
zig build build-all-targets
```

Artifacts are written to `release/all-targets/` as `codex-manager-<os>-<arch>`.

Target set depends on host OS:
- Linux host: Linux + Windows targets
- macOS host: macOS targets
- Windows host: Windows targets

Binary output:

- Linux/macOS: `zig-out/bin/codex-manager`
- Windows: `zig-out/bin/codex-manager.exe`

Run installed binary:

```bash
./zig-out/bin/codex-manager --web
./zig-out/bin/codex-manager --desktop
```

## Testing

Run backend Zig tests:

```bash
zig build test
```

## Storage

- Managed accounts: app local data directory, file `accounts.json`
- UI bootstrap cache: app local data directory, file `bootstrap-state.json`
- Theme setting: app local data directory, file `ui-theme.txt`
- Active Codex auth target: `~/.codex/auth.json`

## Troubleshooting

- `WebUI RPC unavailable in this session`:
  - Launch through the app (`zig build dev -- --web` or `zig build dev -- --desktop`)
  - Open the app URL from the printed `127.0.0.1` address
- Desktop WebView crashes on Linux:
  - Ensure GTK/WebKitGTK packages are installed
  - Try web mode (`--web`) if your system WebView stack is unstable
- Window buttons do nothing:
  - This can happen in plain browser mode
  - Use desktop mode for native window controls

## Notes

- Frontend is built into a single embedded target:
  - `dist`
- The executable is self-contained for app logic and embedded frontend assets.
