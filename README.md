# Codex Account Manager

A Tauri + SolidJS desktop app to manage multiple Codex accounts and switch between them instantly.

## What It Does

- Manages multiple Codex identities in one place.
- Switches the active account by writing the selected auth payload to `~/.codex/auth.json`.
- Supports ChatGPT OAuth login flow and API key accounts.
- Lets you start browser login, then listen/stop listening for OAuth callback.
- Imports the currently active Codex CLI auth into the managed list.
- Archives/unarchives/removes accounts.
- Shows per-account usage/credits status.

## UI Highlights

- Minimal monochrome design with light/dark theme toggle.
- Custom window titlebar (minimize/fullscreen/close + drag support).
- Account cards in responsive columns.
- Add-account popup menu.

## Credits/Usage Behavior

For ChatGPT-auth accounts, usage is fetched in a Codex-CLI-compatible way:

- Endpoint: `https://chatgpt.com/backend-api/wham/usage`
- Headers:
  - `Authorization: Bearer <tokens.access_token>`
  - `ChatGPT-Account-Id: <tokens.account_id>` (when present)
  - `User-Agent: codex-cli`

If `credits.balance` is available, the app shows that value directly.

If `credits` is absent/null but `rate_limit.primary_window.used_percent` exists, the app uses fallback display:

- `available = 100 - used_percent`
- `total = 100`
- unit `%`

For API-key-only auth, a legacy billing endpoint fallback is still available.

## Project Structure

```text
src/
  App.tsx                # SolidJS UI
  App.css                # Styling/theme/layout
  lib/codexAuth.ts       # Account store + auth + credits logic

src-tauri/
  src/lib.rs             # Tauri commands (oauth callback listener, usage fetch)
  tauri.conf.json        # Tauri app config
  capabilities/          # Permission capabilities
```

## Local Data

- Managed accounts store: `$APPLOCALDATA/accounts.json`
- Active Codex auth file: `~/.codex/auth.json`

The app reads/writes those files to switch accounts and keep state in sync.

## Prerequisites

- Node.js (LTS recommended)
- Rust toolchain
- Tauri CLI (`@tauri-apps/cli` already in devDependencies)

Linux (Debian/Ubuntu) native deps (commonly required):

```bash
sudo apt update
sudo apt install -y \
  libwebkit2gtk-4.1-dev \
  libjavascriptcoregtk-4.1-dev \
  libsoup-3.0-dev \
  libgtk-3-dev \
  libayatana-appindicator3-dev \
  librsvg2-dev
```

## Development

Install dependencies:

```bash
npm install
```

Run web UI only:

```bash
npm run dev
```

Run desktop app (Tauri dev):

```bash
npm run tauri dev
```

Build frontend:

```bash
npm run build
```

Rust check:

```bash
cd src-tauri
cargo check
```

## Troubleshooting

### `javascriptcoregtk-4.1` / `webkit2gtk` build errors

Install the Linux native packages listed above and retry `npm run tauri dev`.

### Credits check fails in UI but works with curl

This app fetches `/wham/usage` through a Rust Tauri command (not browser fetch) to avoid webview/CORS/load limitations.

### Titlebar drag not working

Make sure the app is restarted after permission changes; drag support depends on Tauri window capabilities and drag-region attributes.

## Notes

- This project is intentionally focused on Codex account switching workflows.
- It assumes Codex-compatible auth payloads in `~/.codex/auth.json`.
