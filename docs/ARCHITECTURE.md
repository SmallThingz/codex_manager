# Architecture

## Overview

Codex Manager is split into:

- **Frontend (`frontend/`)**: SolidJS UI for account operations, drag/drop, refresh, and settings.
- **Backend (`src/rpc.zig`)**: authoritative state + persistence + OpenAI/Codex interactions.
- **Runtime (`src/main.zig`)**: webui service startup and launch-surface policy.
- **Bridge (`src/rpc_webui.zig`)**: typed `cm_rpc` method exported to browser context.

## State Ownership

Backend is the source of truth.

- Frontend sends RPC intents (`invoke:*` with JSON object args).
- Backend applies mutation under mutex where needed.
- Backend persists state to disk.
- Frontend updates local UI from RPC responses (view updates, refresh payloads, etc.).

No frontend file-level read/write loops are used.

## Persistence Model

Managed data is stored in:

- `accounts.json`
  - active account id
  - managed accounts (`id`, `label`, `accountId`, `email`, `state`, `auth`)
- `bootstrap-state.json`
  - UI preferences
  - usage cache keyed by account id
  - saved timestamp

On each backend mutation, the backend also regenerates the live HTML bootstrap payload used at app startup.

## Concurrency Model

- `managed_files_mutex` guards read-modify-write operations for persisted state.
- Network calls (usage fetch, OAuth exchange) run outside the file mutex where possible.
- Refresh debounce is per-account (`15s`) to suppress redundant fetches.
- OAuth listener uses dedicated state + mutex/condvar to avoid blocking the RPC layer.

## Launch Model

CLI flags define launch surface preference order:

- `--webview` -> native webview
- `--browser` -> app/browser window
- `--web` -> browser tab

Without flags, fallback order is:

`webview -> browser -> web`

In browser/web surfaces, backend applies a short idle-shutdown timeout when no connections remain.

## Error Model

RPC responses are direct JSON:

- success: plain JSON payload (or `null`)
- failure: `{ "error": "..." }`

No nested `{ ok, value }` envelope and no stringified request payload layer.
