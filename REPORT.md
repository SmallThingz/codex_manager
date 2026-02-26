# WebUI API Improvement Report

## Context
This report captures what would have made integration and maintenance substantially easier while migrating this project to the latest `SmallThingz/webui` and debugging real runtime failures.

The focus is API and platform contract quality, not app-level business logic.

## Executive Summary
The biggest pain points were not styling or surface-level ergonomics. They were lifecycle contracts, transport ambiguity, async/RPC safety, and poor observability when fallback behavior changed at runtime.

The highest-impact API improvements are:
1. Deterministic transport/launch behavior with explicit policy objects.
2. First-class async RPC/job APIs instead of emulating non-blocking flows in app code.
3. Stronger lifecycle and diagnostics APIs so apps can react to fallback and launch failures predictably.
4. Hardening and contract guarantees around threaded dispatcher internals.
5. Explicit packaging/runtime APIs for Linux helper binaries and dependencies.

## What Made Integration Hard

### 1. Launch behavior was hard to reason about
`transport_mode`, `auto_open_browser`, and fallback options interact in ways that are powerful but easy to misconfigure. The app had to infer behavior from warning strings and runtime side-effects.

Impact:
- Duplicate browser tab + app window behavior in some setups.
- Extra app-side control logic to avoid opening multiple windows.

### 2. Fallback state was not explicit enough
When native rendering failed and browser fallback happened, there was no high-confidence, structured, first-class status API used by app code to branch behavior.

Impact:
- App had to parse warning text patterns to detect fallback mode.
- Fragile behavior when warning wording changes.

### 3. Async RPC was not sufficiently first-class for long operations
Long-running operations (OAuth callback listener) needed non-blocking behavior. We had to build a custom thread + poll state machine in backend app code.

Impact:
- More custom synchronization code in app backend.
- More surface area for race conditions.

### 4. Threaded dispatcher had a hard crash in real usage
After upgrading to latest commit, threaded dispatcher path crashed with a segfault (`invokeFromJsonPayload` task/mutex lifetime issue). We had to switch dispatcher mode to sync to stay stable.

Impact:
- Lost confidence in threaded dispatcher for production.
- Needed workaround despite async requirements.

### 5. Helper binaries/runtime expectations on Linux were implicit
Behavior can depend on helper binaries (`webui_linux_webview_host`, `webui_linux_browser_host`) being present and packaged correctly.

Impact:
- Debug cycles to understand why desktop behavior differed by environment.
- Harder distribution/release automation.

### 6. Diagnostics were too string-oriented
Errors/warnings are present but not consistently structured for app-level decision-making.

Impact:
- App side had to rely on text matching.
- Weak automation and poor future-proofing.

## Recommended API Improvements

## Priority 0: Deterministic App Launch Contract
Introduce a single `LaunchPolicy` that unifies transport + browser-open behavior.

Proposed shape:
```zig
pub const LaunchPolicy = struct {
    preferred_transport: enum { native_webview, browser },
    fallback_transport: enum { none, browser },
    browser_open_mode: enum { never, on_browser_transport, always },
    app_mode_required: bool,
};
```

Required guarantees:
- Exactly one user-visible window/tab by default.
- If both native and browser surfaces are active, it must be explicit and opt-in.
- Policy decisions must be surfaced via structured runtime state.

## Priority 0: Structured Runtime State Introspection
Add stable APIs that expose the active rendering mode and why it was selected.

Proposed API:
```zig
pub const RuntimeRenderState = struct {
    active_transport: enum { native_webview, browser },
    fallback_applied: bool,
    fallback_reason: ?enum {
        native_backend_unavailable,
        unsupported_style,
        launch_failed,
        dependency_missing,
    },
    browser_process: ?struct {
        pid: i64,
        kind: ?BrowserKind,
    },
};

pub fn getRuntimeRenderState(self: *Service) RuntimeRenderState;
```

This removes string parsing and allows deterministic app behavior.

## Priority 0: First-Class Async RPC Jobs
Add a built-in async job mechanism for RPC functions so long-running tasks do not block request handling and do not require app authors to build custom polling infrastructure.

Proposed API:
```zig
pub const RpcExecutionMode = enum { inline_sync, queued_async };

pub const RpcJobId = u64;

pub fn registerRpc(
    self: *Window,
    comptime RpcStruct: type,
    options: struct {
        mode: RpcExecutionMode,
        timeout_ms: ?u32 = null,
        max_queue: usize = 256,
    },
) !void;

pub fn rpcPollJob(self: *Window, job_id: RpcJobId) RpcJobStatus;
pub fn rpcCancelJob(self: *Window, job_id: RpcJobId) bool;
```

This would have eliminated custom OAuth start/poll/cancel scaffolding in app code.

## Priority 0: Threaded Dispatcher Stability Contract
Threaded mode needs a strong correctness contract and dedicated stress tests around:
- task ownership
- mutex/condvar lifetimes
- cancellation + timeout races
- shutdown while tasks are inflight

Required changes:
- Explicit memory ownership docs for task/results.
- Sanitizer/valgrind stress suite in CI.
- A “threaded dispatcher stability” test matrix for Linux/macOS/Windows.

## Priority 1: Structured Diagnostics and Error Taxonomy
Replace ad-hoc warning strings with typed diagnostics and machine-readable error codes.

Proposed API:
```zig
pub const Diagnostic = struct {
    code: []const u8,
    category: enum { transport, browser_launch, rpc, websocket, tls, lifecycle },
    severity: enum { debug, info, warn, error },
    message: []const u8,
    window_id: usize,
};

pub fn onDiagnostic(self: *Service, handler: *const fn (d: Diagnostic) void) void;
```

The app should never need to infer behavior from free-form warning text.

## Priority 1: Explicit Packaging/Dependency API (especially Linux)
Expose helper/runtime requirements through API so installers and startup checks are deterministic.

Proposed API:
```zig
pub const RuntimeRequirement = struct {
    name: []const u8,
    required: bool,
    available: bool,
    details: ?[]const u8,
};

pub fn listRuntimeRequirements(self: *Service, allocator: std.mem.Allocator) ![]RuntimeRequirement;
```

Examples:
- `webui_linux_webview_host` present/absent
- browser host helper present/absent
- webkit runtime availability

## Priority 1: Capability Negotiation API Before Show
Allow querying effective capabilities before calling `show()`.

Proposed API:
```zig
pub const EffectiveCapabilities = struct {
    transport_if_shown: enum { native_webview, browser },
    supports_native_window_controls: bool,
    supports_transparency: bool,
    supports_frameless: bool,
};

pub fn probeCapabilities(self: *Service) EffectiveCapabilities;
```

This avoids optimistic configuration followed by reactive fallback handling.

## Priority 2: Lifecycle Hooks with Strong Ordering Guarantees
Current hooks exist, but ordering and causality should be formalized.

Needed guarantees:
- `fallback_applied` event before browser open.
- `close_requested` reason includes source (`user`, `backend_shutdown`, `child_exit`, `browser_exit`).
- deterministic ordering between websocket disconnect and service shutdown.

## Priority 2: Bridge-Level Contract Improvements
Bridge generation is useful but needs explicit versioning and compatibility metadata.

Proposed additions:
- bridge protocol version exposed at runtime
- method schema hash exposure
- optional strict mode rejecting unknown fields with typed error

## Priority 2: Built-in OAuth/Local Callback Utility (Optional Module)
A reusable callback listener utility would remove repetitive app code.

Proposed utility:
```zig
pub const LocalCallbackListener = struct {
    pub fn start(opts: ListenerOptions) !ListenerHandle;
    pub fn poll(handle: ListenerHandle) ListenerState;
    pub fn cancel(handle: ListenerHandle) void;
};
```

This should be optional and generic, not tied to OAuth vendor specifics.

## Documentation Improvements Needed
1. A decision table for transport and browser-launch behavior.
2. A packaging guide covering Linux helper binaries and expected deployment layout.
3. A “non-blocking RPC patterns” guide with recommended modes.
4. Stability caveats and maturity level per dispatcher mode.
5. Clear contract docs for lifecycle event ordering.

## Suggested Rollout Plan
1. Ship structured runtime state and diagnostics first.
2. Stabilize threaded dispatcher with tests and release notes.
3. Introduce unified launch policy API (deprecate ambiguous option combinations).
4. Add async RPC jobs and migration guide.
5. Add packaging/runtime requirement introspection APIs.

## Expected Developer Impact
If implemented well, these changes should reduce:
- transport/fallback integration bugs
- app-level thread/sync boilerplate
- environment-specific Linux startup regressions
- debugging time spent on ambiguous warnings
- risk of catastrophic crashes from dispatcher internals

## Bottom Line
`webui` already provides strong building blocks. The biggest opportunity is tightening behavioral contracts and exposing runtime state as typed APIs.

For this project specifically, that would have prevented:
- duplicate window/tab behavior
- warning-string-based control flow
- custom non-blocking RPC scaffolding for callback listeners
- losing threaded mode due to an upstream crash path

A more explicit, typed, and test-hardened API surface would have made the migration faster, safer, and much easier to maintain.
