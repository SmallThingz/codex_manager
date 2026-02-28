# RPC API

## Transport

`window.webuiRpc.cm_rpc(requestObject)`

- Request is a JSON object with `op` and optional typed fields.
- Arguments are **not** stringified into a second JSON layer.
- Responses are direct JSON payloads.

Success responses are plain JSON (`null`, object, bool, etc.).
Error responses are:

```json
{ "error": "message" }
```

## Request Shape

```json
{
  "op": "invoke:refresh_account_usage",
  "accountId": "acct-..."
}
```

## Supported Operations

### `shell:open_url`

Input:

```json
{ "op": "shell:open_url", "url": "https://example.com" }
```

Output: `null`

### `invoke:refresh_account_usage`

Input:

```json
{ "op": "invoke:refresh_account_usage", "accountId": "acct-..." }
```

Output:

```json
{
  "accountId": "acct-...",
  "credits": {
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
  },
  "email": "user@example.com"
}
```

### `invoke:switch_account`

Input:

```json
{ "op": "invoke:switch_account", "accountId": "acct-..." }
```

Output: `AccountsView` object.

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

Output: `null`

### `invoke:remove_account`

Input:

```json
{ "op": "invoke:remove_account", "accountId": "acct-..." }
```

Output: `AccountsView` object.

### `invoke:import_current_account`

Input:

```json
{ "op": "invoke:import_current_account", "label": "optional" }
```

Output: `AccountsView` object.

### `invoke:login_with_api_key`

Input:

```json
{ "op": "invoke:login_with_api_key", "apiKey": "sk-...", "label": "optional" }
```

Output: `AccountsView` object.

### `invoke:update_ui_preferences`

Input (partial):

```json
{
  "op": "invoke:update_ui_preferences",
  "theme": "dark",
  "autoRefreshActiveEnabled": true,
  "autoRefreshActiveIntervalSec": 300,
  "usageRefreshDisplayMode": "remaining"
}
```

Output: `null`

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
  "codeVerifier": "...",
  "label": "optional"
}
```

Output: `true`

### `invoke:poll_oauth_callback_listener`

Input:

```json
{ "op": "invoke:poll_oauth_callback_listener" }
```

Output one of:

```json
{ "status": "running" }
```

```json
{ "status": "idle" }
```

```json
{ "status": "ready", "account": { "id": "...", "accountId": null, "email": "...", "state": "active" } }
```

```json
{ "status": "error", "error": "..." }
```

### `invoke:cancel_oauth_callback_listener`

Input:

```json
{ "op": "invoke:cancel_oauth_callback_listener" }
```

Output: `true`

## Notes

- Unknown operations return `{ "error": "unknown ..." }`.
- Payload keys are camelCase and validated strictly per operation.
