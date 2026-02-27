# Codex Manager

A Zig-first desktop/web account manager for Codex with typed RPC, deterministic launch modes, and automatic quota-state transitions.

![Zig](https://img.shields.io/badge/Zig-0.15.2+-f7a41d?logo=zig&logoColor=111)
![Frontend](https://img.shields.io/badge/Frontend-SolidJS-2c4f7c)
![Runtime](https://img.shields.io/badge/Runtime-WebUI_Zig-111827)
![Modes](https://img.shields.io/badge/Modes-webview%20%7C%20browser%20%7C%20web-0f766e)

## ⚡ Features

- Multi-account management with clear buckets: `active`, `depleted`, `frozen`.
- Fast account switching (updates `~/.codex/auth.json`).
- Drag-and-drop account movement across buckets.
- Per-account usage refresh with immediate card updates.
- Quota-driven lifecycle rules:
  - `0` remaining quota in active => auto-move to depleted.
  - non-zero quota in depleted => auto-move back to active.
- Auto-refresh support for active and depleted flows.
- Theme + UI preference persistence.

## 🚀 Quick Start

```bash
zig build dev
```

This runs frontend build steps (TypeScript + Vite) and launches the app.

### Launch Modes

```bash
zig build dev -- --webview
zig build dev -- --browser
zig build dev -- --web
```

- `--webview`: prefer native webview surface.
- `--browser`: prefer app-window/browser-window mode.
- `--web`: open in a normal browser tab.

Default (no flag) uses ordered fallback: `webview -> browser window -> web tab`.

## 📦 Build / Install

Optimized install:

```bash
zig build install -Doptimize=ReleaseFast
```

Run:

```bash
./zig-out/bin/codex-manager
./zig-out/bin/codex-manager --web
```

Build release matrix:

```bash
zig build build-all-targets
```

## 🧰 Requirements

Build-time:

- Zig `0.15.2+`
- Node.js `20+`
- `npm`

Runtime:

- `curl` in `PATH`
- `codex` CLI in `PATH`
- Browser installed (Chromium-family recommended for desktop-window behavior)

## 🧠 Architecture (At a Glance)

- **Frontend**: SolidJS SPA (`frontend/`).
- **Backend**: Zig app (`src/`) serving local UI + handling all account state mutations.
- **Bridge**: typed WebUI RPC surface via `webuiRpc.cm_rpc(...)`.
- **State ownership**: backend-authoritative persistence for account/view/usage data.

## 🗂️ Storage

Local app data directory:

- `accounts.json` — managed account records
- `bootstrap-state.json` — boot snapshot + UI cache
- `ui-theme.txt` — theme selection

Codex auth target:

- `~/.codex/auth.json`

## ✅ Testing

```bash
zig build test
```

## 🔎 Troubleshooting

- App prints URL but no window appears:
  - Open the printed `http://127.0.0.1:...` URL directly in your browser.
- Native webview mode fails on Linux:
  - Verify your WebKitGTK runtime/tooling for your distro.
  - Use `--browser` or `--web` as fallback.
- RPC bridge unavailable at startup:
  - Ensure `webui_bridge.js` is injected and loaded by the served page.
