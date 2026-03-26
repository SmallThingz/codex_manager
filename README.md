# Codex Manager

A Zig + SolidJS account manager for Codex with backend-authoritative state, typed WebUI RPC, and deterministic launch behavior.

![zig](https://img.shields.io/badge/Zig-0.16.0--dev+-f7a41d?logo=zig&logoColor=111)
![solid](https://img.shields.io/badge/Frontend-SolidJS-1f3b6f)
![webui](https://img.shields.io/badge/Runtime-webui-111827)
![modes](https://img.shields.io/badge/Modes---webview%20--browser%20--web-0f766e)

## Highlights

- Multi-account management with explicit states: `active`, `archived`, `frozen`.
- Fast account switching (writes selected auth to `~/.codex/auth.json`).
- Per-account refresh with immediate, per-card UI updates.
- Automatic quota transitions:
  - active accounts with zero quota move to archived.
  - archived accounts with non-zero quota move back to active.
- Depleted auto-refresh at refresh-window + grace.
- Optional active-account auto-refresh with interval slider (`15s` to `6h`).
- Backend-owned persistence (frontend sends intents, backend mutates + persists).

## Quick Start

```bash
zig build dev
```

This runs frontend checks/build and starts the app.

## Launch Modes

```bash
zig build dev -- --webview
zig build dev -- --browser
zig build dev -- --web
```

Default order when no explicit flag is provided:

`webview -> browser -> web`

## Build & Install

Release build:

```bash
zig build install -Doptimize=ReleaseFast
```

Release build with stripped symbols:

```bash
zig build install -Doptimize=ReleaseFast -Dstrip=true
```

Build the full release matrix:

```bash
zig build build-all-targets -Doptimize=ReleaseFast
```

On Linux, `build-all-targets` now auto-downloads and caches a macOS SDK under `.zig-cache/macos-sdk/sdk` if you do not provide `-Dmacos_sdk=<path>` or `MACOS_SDK_ROOT`. Disable that with `-Dauto_download_macos_sdk=false`, or change the cache location with `-Dmacos_sdk_cache_dir=<path>`.

Run installed binary:

```bash
./zig-out/bin/codex-manager
```

## Requirements

Build-time:

- Zig `0.16.0-dev+`
- Node.js `20+`
- npm

Runtime:

- `codex` CLI in `PATH`
- browser available for `--browser` / `--web`

## Project Layout

- `src/` Zig backend, state management, RPC bridge, launch runtime
- `frontend/` SolidJS UI
- `docs/` architecture and RPC contract
- `examples/` minimal integration examples

## Storage

- `~/.local/share/com.codex.manager/accounts.json` (or platform equivalent)
- `~/.local/share/com.codex.manager/bootstrap-state.json`
- `~/.codex/auth.json`

## Documentation

- [Architecture](docs/ARCHITECTURE.md)
- [RPC API](docs/RPC.md)

## Development

Typecheck frontend:

```bash
npm --prefix frontend exec -- tsc -p frontend/tsconfig.json --noEmit
```

Run Zig tests:

```bash
zig build test
```

## Troubleshooting

- Native webview unavailable on Linux:
  - run with `--browser` or `--web`.
- URL prints but no window appears:
  - open the printed `http://127.0.0.1:...` URL manually.
- OAuth callback issues:
  - ensure port `1455` is available and retry login.
