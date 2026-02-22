# Codex Account Manager

Codex Account Manager is a SolidJS frontend with a Zig backend powered by [zig-webui](https://github.com/webui-dev/zig-webui).

It manages multiple Codex accounts, switches active `~/.codex/auth.json` on the fly, and checks per-account credits.

## Architecture

- Frontend: SolidJS (`/home/a/projects/js/codex_manager/frontend/src`)
- Backend runtime: Zig + WebUI (`/home/a/projects/js/codex_manager/src`)
- Function bridge:
  - `window.cm_rpc(...)` (provided by `/webui.js` in desktop and `--web` modes)

## Build System

The Zig project is now root-level:

- `/home/a/projects/js/codex_manager/build.zig`
- `/home/a/projects/js/codex_manager/build.zig.zon`

### Commands

Run app in dev mode:

```bash
zig build dev
```

Default dev mode runs browser-hosted WebUI (`--web` behavior).

Run app in web mode:

```bash
zig build dev -- --web
```

Run desktop WebView mode explicitly:

```bash
zig build dev -- --desktop
```

Build/install release binary:

```bash
zig build install -Doptimize=ReleaseFast
```

Output binary:

- Linux/macOS: `/home/a/projects/js/codex_manager/zig-out/bin/codex-manager`
- Windows: `/home/a/projects/js/codex_manager/zig-out/bin/codex-manager.exe`

Run built binary in web mode:

```bash
./zig-out/bin/codex-manager --web
```

Run built binary in desktop mode:

```bash
./zig-out/bin/codex-manager --desktop
```

## Self-contained Binary

`zig build install` compiles a single binary with frontend assets embedded at compile time:
- web bundle: `frontend/dist-web/index.html`
- desktop bundle: `frontend/dist-desktop/index.html`

The runtime does not depend on shipping any external `dist` folder.

## Requirements

- Node.js 20+
- Zig 0.15+
- `curl` in PATH
- `codex` CLI
