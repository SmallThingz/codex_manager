# WebUI Post-Update Feedback Report

## Evaluated Versions
- Previous: `7e62b2c823c727e435cea95233f845ba5b7b3fd5`
- Latest: `8e771c5580d6d147ef1f3be12be84b97ff3af34b`

This report reflects the latest integration pass against `8e771c...`.

## Executive Summary
The major API improvements introduced in the previous update are still present and useful:
- Deterministic `LaunchPolicy`
- Runtime render introspection (`runtimeRenderState`)
- Runtime requirement probing (`listRuntimeRequirements`)
- Typed diagnostics (`onDiagnostic`)
- Async RPC job model (`queued_async`, poll/cancel)

However, the critical `Service` lifecycle regression still exists in this latest commit and still requires a local workaround in this app.

## What Changed In This Latest Update

## 1. Public API impact (for this app)
For our integration path, no additional public API removals were observed between `7e62b2c...` and `8e771c...`.
- Build-level API migration from old fields (like `transport_mode`) was already handled in the prior pass.
- The current app still compiles against latest with the same adapted API usage.

## 2. Critical runtime status
The same runtime crash regression is still reproducible without workaround:
- crash on diagnostic emission path (e.g. websocket connected event)
- stack points to `emitDiagnostic` callback invocation from `Service`-created window state

Status:
- **Not fixed upstream yet** (as of `8e771c...`).

## 3. Bridge compatibility status
Bridge envelope contract remains required for `/rpc` fallback traffic.
- Our local envelope adaptation is still necessary and valid.

## Current Local Implementation (Updated)

## Dependency update
`build.zig.zon` now pins:
- `webui` URL: `git+https://github.com/SmallThingz/webui.git#8e771c5580d6d147ef1f3be12be84b97ff3af34b`
- hash: `webui-0.0.0-NV0cf5MDBwA9QZygQDPoPVxmhDbZqIUgaMcWyMogw-Qu`

## Workaround retained (required)
In `src/main.zig`, after `Service.init`, we rebind each `WindowState.diagnostic_callback` pointer to live `service.app` storage.

Reason:
- Without this, `zig build dev --` and `zig build dev -- --web` crash at runtime in latest commit.

## Runtime/bridge adaptation retained
In `frontend/src/lib/codexAuth.ts`, HTTP fallback now wraps payloads as bridge RPC envelopes (`{name,args}`) and decodes returned `value` string.

Reason:
- Required by current `/rpc` bridge protocol.

## Validation Results (Latest Commit)
With current implementation + workaround:
- `zig build` passes.
- `zig test src/rpc.zig` passes.
- `zig build dev --` runs (desktop URL printed, no crash during smoke window).
- `zig build dev -- --web` runs (web URL printed, no crash during smoke window).

Without workaround:
- both desktop and web dev runs crash in `emitDiagnostic` path.

## Remaining Issues (Priority)

## P0: `Service` diagnostic callback lifetime regression
Likely root cause remains unchanged:
- `WindowState` stores pointer to diagnostic callback state created before `Service` returns.
- App value move in `Service.init` invalidates that pointer.

Recommended upstream fix:
1. Make callback storage address-stable across `Service.init` return.
2. Add regression test that creates `Service`, emits websocket/rpc diagnostics, and verifies no invalid callback pointer access.

## P1: Migration/compat guidance for bridge route
Current route expects bridge envelope. Projects with custom `cm_rpc` wrappers need explicit migration examples.

## P1: Release notes clarity
Include known runtime regressions and workarounds directly in release notes.

## Bottom Line
Latest update is usable in this project **only with local workaround still in place**.

The API direction remains strong, but the `Service` diagnostic pointer bug is still the blocker for clean, workaround-free adoption.
