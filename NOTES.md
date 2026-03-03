# Developer Notes: Migrating from Curl to Native Zig HTTP

Here is a summary of the mistakes made during the transition from `curl` process spawning to Zig's native `std.http.Client`, and lessons learned for future agents working in this repository.

## 1. Zig Standard Library API Volatility
- **Mistake:** Assuming the structure of Zig's `std.http.Client` based on older versions (e.g., trying to use `client.open()`, `req.start()`).
- **What I should have known:** The Zig standard library API changes rapidly across releases. Before exploring HTTP clients in Zig, I should have immediately checked the local Zig standard library source code (e.g., viewing `std/http/Client.zig`) to confirm signatures for request and response interfaces instead of relying on trial-and-error with the compiler.

## 2. Default HTTP Headers and Compression
- **Mistake:** Encountering "invalid JSON" errors after migrating from `curl` to `std.http.Client`. I initially assumed my parsing logic was broken.
- **What I should have known:** By default, Zig's `std.http.Client` requests include the header `Accept-Encoding: gzip, deflate`. The OpenAI endpoints honored this and returned compressed binary payloads, causing the application's JSON parser to fail. When working with plain JSON endpoints in Zig without a decompression pipeline, it is critical to disable this header explicitly in the RequestOptions: `.accept_encoding = .omit`. `curl` defaults differently and sidestepped this issue natively.

## 3. High-Level `fetch` Limitations vs Low-Level Connections
- **Mistake:** Trying to use `client.fetch(FetchOptions)` with a `.response_writer` bound to an `std.ArrayList(u8).writer().any()`. This resulted in obscure `Io.DeprecatedWriter` pointer cast issues during compilation.
- **What I should have known:** Zig has been overhauling its `std.io.Writer` typing system. Some high-level generic APIs like `client.fetch` can have rough edges when dynamically typing writers in recent versions. The most stable and predictable networking pattern is to use the low-level HTTP flow instead:
  1. `client.request(...)`
  2. `req.sendBodiless()` or `req.sendBodyUnflushed(...)`
  3. `req.receiveHead(&buffer)`
  4. `response.reader().appendRemaining(allocator, &array_list, limits)`

## 4. Managed vs Unmanaged ArrayLists
- **Mistake:** Mixing up `.init(allocator)` with `.empty` when declaring array lists for the HTTP headers.
- **What I should have known:** If an array list is initialized with `.empty`, it behaves like an unmanaged data structure and implicitly expects the `allocator` to be passed during mutations (e.g., `list.append(allocator, item)`). Attempting to use `.append(item)` on it will raise a compilation error regarding missing initialization struct members.

## 5. Test Suite Crawling in Zig
- **Mistake:** Writing multiple test blocks in `src/rpc.zig`, importing it in the root `rpc_tests.zig` via `_ = @import("src/rpc.zig");`, and expecting `zig build test` to run all 8 tests. It resulted in only 1 test tracking.
- **What I should have known:** Zig's test runner only explores the test blocks that are referenced or reachable from the root file. To recursively discover and run tests defined in imported files, you MUST use `std.testing.refAllDecls(@import("your_file.zig"));`.

## 6. Understanding `curl` Form Payload Mechanics
- **Mistake:** Underestimating what `--data-urlencode` does behind the scenes in `curl`.
- **What I should have known:** `curl` does heavy lifting regarding `application/x-www-form-urlencoded` payloads and safely converting key-value pairs into form strings. Zig does not have a comprehensive, single-function form serializer in the standard library. I should have anticipated needing to write an `appendUrlEncoded` function manually from the start rather than trying to figure out `curl` mappings implicitly.
