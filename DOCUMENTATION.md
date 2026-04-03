# Documentation

## Architecture

### Overview

Codex Manager is split into four layers:

- `frontend/`: SolidJS UI for account operations, drag/drop, refresh, login, and settings.
- `src/rpc.zig`: authoritative backend state, persistence, OpenAI/Codex integration, and RPC dispatch.
- `src/main.zig`: `webui` runtime startup and launch-surface policy.
- `src/rpc_webui.zig`: bridge glue that exposes `cm_rpc` to the page and pushes completion events back over the websocket.

### State Ownership

The backend is the source of truth.

- Frontend sends typed RPC intents.
- Backend validates input, mutates state, persists files, and regenerates bootstrap state.
- Frontend updates local UI from RPC responses and pushed refresh completions.

### Persistence Model

Managed state is stored in:

- `accounts.json`
  - active account id
  - managed accounts
  - persisted auth payloads
- `bootstrap-state.json`
  - UI preferences
  - cached usage snapshots keyed by account id
  - save timestamp

Whenever backend state changes, the backend also regenerates the live HTML/bootstrap payload used at startup.

### Concurrency Model

- `managed_files_mutex` guards read-modify-write operations over persisted state.
- Network work runs outside the file mutex where practical.
- Usage refreshes are debounced per account.
- OAuth callback listening uses dedicated shared state with mutex + condition variable.
- The `webui` RPC dispatcher stays threaded, while UI work remains on the main thread.

### Launch Model

CLI flags define ordered launch-surface preference:

- `--webview` / `-w`: native webview
- `--browser` / `-b`: browser app window
- `--web` / `-u`: browser tab / printed URL flow

Default order when no flags are supplied:

`webview -> browser -> web`

### Error Model

RPC responses are direct JSON:

- success: plain JSON payload or `null`
- failure: `{ "error": "..." }`

There is no nested `{ ok, value }` envelope.

## RPC API

## Transport

The frontend calls:

`window.webuiRpc.cm_rpc(requestObject)`

Requests are plain JSON objects with an `op` field and optional typed fields.

Success responses are direct JSON payloads.
Error responses are:

```json
{ "error": "message" }
```

The `webui` bridge itself uses a websocket-backed runtime channel. Usage refresh completion is pushed back to the frontend over that channel instead of being polled.

## Request Shape

Example:

```json
{
  "op": "invoke:refresh_account_usage",
  "accountId": "acct-..."
}
```

Supported request fields currently include:

- `theme`
- `apiKey`
- `issuer`
- `clientId`
- `redirectUri`
- `oauthState`
- `codeVerifier`
- `url`
- `timeoutSeconds`
- `accountId`
- `targetBucket`
- `targetIndex`
- `switchAwayFromMoved`
- `autoArchiveZeroQuota`
- `autoUnarchiveNonZeroQuota`
- `autoSwitchAwayFromArchived`
- `autoRefreshActiveEnabled`
- `autoRefreshActiveIntervalSec`
- `usageRefreshDisplayMode`

## Main Operations

### `shell:open_url`

Input:

```json
{ "op": "shell:open_url", "url": "https://example.com" }
```

Output:

`null`

### `invoke:refresh_account_usage`

Input:

```json
{ "op": "invoke:refresh_account_usage", "accountId": "acct-..." }
```

Immediate response:

```json
{
  "accountId": "acct-...",
  "credits": { "...": "credits payload" },
  "email": "user@example.com",
  "inFlight": true
}
```

or, if refresh completed immediately:

```json
{
  "accountId": "acct-...",
  "credits": { "...": "credits payload" },
  "email": "user@example.com",
  "inFlight": false
}
```

When the backend refresh finishes asynchronously, it pushes the completion payload back through the websocket bridge.

Credits payload shape:

```json
{
  "available": 12.34,
  "used": 1.0,
  "total": null,
  "currency": "USD",
  "source": "wham_usage",
  "mode": "balance",
  "unit": "USD",
  "planType": "free",
  "isPaidPlan": false,
  "hourlyRemainingPercent": null,
  "weeklyRemainingPercent": null,
  "hourlyRefreshAt": null,
  "weeklyRefreshAt": null,
  "status": "available",
  "message": "...",
  "checkedAt": 1772000000
}
```

### `invoke:switch_account`

Input:

```json
{ "op": "invoke:switch_account", "accountId": "acct-..." }
```

Output: `AccountsView`

### `invoke:move_account`

Input:

```json
{
  "op": "invoke:move_account",
  "accountId": "acct-...",
  "targetBucket": "active",
  "targetIndex": 0,
  "switchAwayFromMoved": true
}
```

Output:

`null`

### `invoke:remove_account`

Input:

```json
{ "op": "invoke:remove_account", "accountId": "acct-..." }
```

Output: `AccountsView`

### `invoke:import_current_account`

Input:

```json
{ "op": "invoke:import_current_account" }
```

Output: `AccountsView`

### `invoke:login_with_api_key`

Input:

```json
{ "op": "invoke:login_with_api_key", "apiKey": "sk-..." }
```

Output: `AccountsView`

### `invoke:update_ui_preferences`

Input is partial. Example:

```json
{
  "op": "invoke:update_ui_preferences",
  "theme": "dark",
  "autoRefreshActiveEnabled": true,
  "autoRefreshActiveIntervalSec": 300,
  "usageRefreshDisplayMode": "remaining"
}
```

Output:

`null`

### `invoke:start_oauth_callback_listener`

Input:

```json
{
  "op": "invoke:start_oauth_callback_listener",
  "timeoutSeconds": 180,
  "issuer": "https://auth.openai.com",
  "clientId": "app_...",
  "redirectUri": "http://localhost:1455/auth/callback",
  "oauthState": "...",
  "codeVerifier": "..."
}
```

Output:

`true`

### `invoke:poll_oauth_callback_listener`

Input:

```json
{ "op": "invoke:poll_oauth_callback_listener" }
```

Output is one of:

```json
{ "status": "running" }
```

```json
{ "status": "idle" }
```

```json
{ "status": "ready", "account": { "id": "...", "email": "...", "state": "active" } }
```

```json
{ "status": "error", "error": "..." }
```

### `invoke:cancel_oauth_callback_listener`

Input:

```json
{ "op": "invoke:cancel_oauth_callback_listener" }
```

Output:

`true`

## View Models

### `AccountsView`

```json
{
  "accounts": [
    { "id": "acct-...", "email": "user@example.com", "state": "active" }
  ],
  "activeAccountId": "acct-...",
  "activeDiskAccountId": "acct-...",
  "codexAuthExists": true,
  "codexAuthPath": "/home/user/.codex/auth.json",
  "storePath": "/home/user/.local/share/com.codex.manager/accounts.json"
}
```

Account summaries only expose:

- `id`
- `email`
- `state`

There is no persisted `label`, and there is no top-level `accountId` field on account summaries anymore.

## Notes

- Unknown operations return an error object.
- Payload keys are camelCase.
- OAuth redirect/callback constants are intentionally aligned with Codex CLI.
