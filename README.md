# Codex Account Manager

Manage multiple Codex accounts from one UI: switch the active `~/.codex/auth.json`, group accounts by status, and keep an eye on usage/refresh.

Built with SolidJS (frontend) + Zig (backend), rendered locally through WebUI Zig (SmallThingz/webui).

## What It Does

- Manage multiple accounts in one place (active / depleted / frozen)
- Switch the active account instantly (updates `~/.codex/auth.json`)
- Drag-and-drop reorder between buckets
- Pull usage/credits and show refresh timing
- Light/dark theme with persistence

## Quick Start

### Dev

```bash
zig build dev
```

This runs the frontend build (npm + Vite) and starts the app.

### Modes

- Default: desktop-ish window (Chromium app-window when available)
- Force web mode:

```bash
zig build dev -- --web
```

If the app prints a `http://127.0.0.1:...` URL, you can always open it manually in any browser.

## Requirements

Build-time:
- Zig `0.15.2+`
- Node.js `20+`
- `npm`

Runtime:
- `curl` in `PATH`
- `codex` CLI in `PATH`
- A browser installed (Chromium-family recommended for the best desktop window behavior)

## Build / Install

Optimized local install:

```bash
zig build install -Doptimize=ReleaseFast
```

Run:

```bash
./zig-out/bin/codex-manager
./zig-out/bin/codex-manager --web
```

Build the release matrix (writes to `zig-out/bin/`):

```bash
zig build build-all-targets
```

## How It Works (High Level)

- The Zig backend serves a local HTTP UI on `127.0.0.1` and exposes typed RPC.
- The frontend calls back into Zig via `globalThis.webui.call("cm_rpc", requestJson)` (with HTTP fallback to `/rpc`).
- Account state is stored locally; switching updates `~/.codex/auth.json`.

## Storage

Local app data directory files:
- `accounts.json` (managed accounts)
- `bootstrap-state.json` (UI bootstrap cache)
- `ui-theme.txt` (theme selection)

Active Codex auth target:
- `~/.codex/auth.json`

## Testing

```bash
zig build test
```

## Troubleshooting

- UI opens but looks blank:
  - Use the printed `http://127.0.0.1:...` URL in a browser to confirm the server is reachable.
- `Backend RPC unavailable in this session`:
  - Launch through the app (`zig build dev`) and make sure `/webui.js` loads.
- Desktop window does not appear:
  - Ensure a Chromium-based browser is installed (Chrome/Chromium/Brave/Edge).
