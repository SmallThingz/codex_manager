# WebUI Post-Update Feedback Report

## Scope
This report updates prior feedback after upgrading `SmallThingz/webui` to:
- `7e62b2c823c727e435cea95233f845ba5b7b3fd5`

It reflects integration results in this project (desktop + web fallback, bridge RPC, OAuth flow, runtime smoke checks).

## Executive Summary
A meaningful portion of prior feedback has been implemented upstream. The new API direction is substantially better and closer to a stable app platform:
- Deterministic launch policy is now first-class.
- Runtime render state introspection exists.
- Runtime requirements probing exists.
- Typed diagnostics exist.
- Async RPC jobs now exist (`queued_async` mode + poll/cancel APIs).

This is a strong improvement over the previous contract.

However, one critical regression remains in current `Service` lifecycle behavior:
- `Service.init` leaves window diagnostic callback pointers stale after `App` value move.
- This causes runtime crashes (segfault/GPF) on normal diagnostic emission paths (e.g. websocket connect, rpc dispatch error).

The regression is severe enough to block clean adoption without a local workaround.

## What Improved (And Why It Matters)

## 1. Deterministic launch policy
New `LaunchPolicy` (`preferred_transport`, `fallback_transport`, `browser_open_mode`, `allow_dual_surface`, `app_mode_required`) is exactly the kind of API unification needed.

Impact:
- Reduced ambiguity between native and browser modes.
- Cleaner app startup code.
- Better reasoning about dual-surface behavior.

## 2. Runtime render introspection
`runtimeRenderState()` with `active_transport`, `fallback_applied`, `fallback_reason`, and browser process metadata is a major upgrade.

Impact:
- Eliminates warning-string parsing for transport/fallback decisions.
- Allows deterministic telemetry and mode-aware behavior.

## 3. Runtime requirement probing
`listRuntimeRequirements()` addresses packaging and environment discovery pain directly.

Impact:
- Better install/runtime diagnostics before showing UI.
- Easier Linux support and release QA.

## 4. Typed diagnostics
`onDiagnostic` + structured diagnostic payloads provide machine-readable signals.

Impact:
- Better observability and error handling.
- Better separation of transport/browser/rpc/lifecycle classes.

## 5. Async RPC jobs
`RpcOptions.execution_mode = .queued_async`, plus poll/cancel APIs and push updates, is a strong foundation for non-blocking backend operations.

Impact:
- This maps well to long-running tasks.
- Reduces need for app-authored ad-hoc threading/polling.

## Remaining Issues (Priority Ordered)

## P0: `Service.init` diagnostic callback pointer lifetime bug
Observed behavior in this project after update:
- Crash in `root.zig` on `state.emitDiagnostic(...)` in websocket/rpc paths.
- Stack consistently points to diagnostic callback invocation.

Likely root cause:
- `WindowState` stores `diagnostic_callback: *DiagnosticCallbackState`.
- `Service.init` creates local `app`, creates windows with pointer to `&app.diagnostic_callback`, then returns `Service{ .app = app }` (value move).
- Stored pointers remain bound to stale stack storage.

Severity:
- Critical runtime crash.
- Reproducible in both desktop and web modes.

Temporary local workaround used here:
- After `Service.init`, rebind each `WindowState.diagnostic_callback` to `&service.app.diagnostic_callback`.

Required upstream fix:
- Ensure callback storage has stable address across `Service.init`.
- Options:
1. Make `Service` hold `*App` (heap-allocated app) instead of value-copying `App`.
2. Rebind window diagnostic pointers internally after moving `App` into `Service`.
3. Avoid raw pointer storage for this callback path and route via owning app lookup.

## P1: Bridge protocol compatibility guidance
The RPC HTTP route now expects bridge payload envelope (`{name,args}`), not app-native payloads.

Observed integration issue:
- App-side fallback code that posted raw backend payloads to `/rpc` hit error paths.

Fix applied locally:
- Wrapped fallback requests into bridge envelope targeting `call("cm_rpc", request)`.

Requested improvement:
- Explicit compatibility/migration notes for bridge route payload format changes.
- Optional “raw passthrough” route pattern for projects that embed a generic `cm_rpc` bridge.

## P1: Service/API migration docs
`AppOptions.transport_mode` style usage was replaced by `launch_policy` (good change), but migration guidance should explicitly map old field names to new fields and expected defaults.

Requested improvement:
- A concise migration table in `MIGRATION.md` for field-level changes.
- Mention default behavior differences (e.g., app mode requirement/dual surface defaults).

## P2: Strengthen release notes with regression callouts
Given the crash severity above, release notes should include known regressions and suggested mitigations when discovered.

Requested improvement:
- Add “Known Issues” section per release.

## Validation Summary In This Project
After upgrading and adapting app code:
- Build: `zig build` passes.
- Unit tests: `zig test src/rpc.zig` passes.
- Runtime smoke: `zig build dev --` and `zig build dev -- --web` run without crash after local `Service` pointer workaround.

## Recommended Upstream Actions
1. Fix `Service.init` pointer lifetime bug immediately (P0).
2. Add regression test that validates diagnostics emission through `Service`-constructed windows after init return.
3. Expand migration docs for bridge payload + launch policy mapping.
4. Keep pushing current direction: launch policy, introspection, requirements, typed diagnostics, async jobs.

## Bottom Line
This update is a substantial API improvement and aligns strongly with prior feedback.

The current release is very close to being a strong long-term base, but the `Service` callback lifetime regression is a hard blocker that must be fixed upstream for safe default adoption.
