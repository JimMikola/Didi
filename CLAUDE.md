# Didi — project guide for Claude

Didi is an **editor-only authoring helper** for the Godot game engine: a C++
GDExtension that runs an HTTP **MCP server** while the project is open in the
Godot editor, and is excluded from exported games.

## Submodules

- `godot-cpp/` — Godot C++ bindings, pinned to branch **4.5**.
- `fastmcpp/` — C++ MCP library (v3.3.1). CMake project; fetches `nlohmann/json`
  and `cpp-httplib` via `FetchContent` at configure time (needs network on first
  configure). Library target: `fastmcpp_core` (STATIC, exposes its includes +
  deps transitively).

Clone with `git submodule update --init --recursive`.

## Source layout (`src/`)

- `register_types.{h,cpp}` — GDExtension entry point `didi_library_init`.
  Registers `DidiServer` at the SCENE level; under `TOOLS_ENABLED`, registers
  `DidiEditorPlugin` at the EDITOR level via `EditorPlugins::add_by_type`.
- `didi_server.{h,cpp}` — `DidiServer : Node`. Hosts fastmcpp's
  `StreamableHttpServerWrapper` on `127.0.0.1:8900/mcp` (non-blocking, runs on a
  background thread). All fastmcpp types are behind a **pimpl** so heavy headers
  (httplib, nlohmann/json) don't leak into the GDExtension header. Properties:
  `port` (8900), `bind_address`, `autostart`. Methods: `start_server`,
  `stop_server`, `is_running`. Tools: `ping`, `godot_version`, `run_gdscript`,
  and `capture_screenshot`. Resources: `gdscript_authoring_guide` (see below).
  Lifetime note: in `Impl`, the `Server` (`meta`), `ToolManager`,
  `ResourceManager`, and `PromptManager` are declared **before** the server
  because the full `make_mcp_handler` overload captures **all four by reference**
  — they must outlive the server (reverse-order destruction guarantees it).

  **`run_gdscript` — the main tool.** Executes AI-provided GDScript against the
  open project for both inspection and authoring. Input: `{ script: string }`,
  where `script` is the **body** of a function. It's wrapped as
  `func _didi_run():` on a throwaway `@tool`/`extends RefCounted` `GDScript`,
  compiled via `Script::reload()`, instantiated with `call("new")`, and invoked;
  the return value is serialized with `UtilityFunctions::var_to_str`. Use
  `return <value>` to return data. Compile failures surface as
  `compile error: ... Error <code>` (e.g. **43** = `ERR_COMPILATION_FAILED`);
  runtime errors print to Godot's output and the call returns `null`.

  **Indentation (a real footgun):** the body is indented one level to nest
  inside the function. GDScript rejects mixing tabs and spaces in indentation,
  so `execute_gdscript` detects the caller's style — it indents with spaces if
  any line of the script is space-indented, otherwise a tab — so callers can
  write either style. A script that itself mixes tabs and spaces still fails
  (the caller's bug).

  **Threading — main-thread dispatch (mandatory):** the MCP server runs on a
  background worker thread, but Godot APIs are main-thread-only. So the
  `run_gdscript` callback never touches Godot directly: it pushes
  `{source, std::promise}` onto `Impl::pending` (guarded by `queue_mutex`) and
  blocks on the future with a **15s timeout** (prevents a permanent hang if the
  main loop stops draining during shutdown). `DidiServer::_process` (enabled via
  `set_process(true)` in `_ready`, **before** the `is_editor_hint()` early-out so
  it also runs under the editor plugin) calls `drain_script_queue()`, which swaps
  the batch out under the lock and runs each script on the main thread, then
  fulfills the promise. This is the same principle as the cached `godot_version`
  string: keep all Godot access on the main thread.

  **`capture_screenshot` + the generic task queue.** Any main-thread tool follows
  the same pattern as `run_gdscript`. To avoid baking GDScript-specific assumptions
  into it, there's a second queue `Impl::pending_tasks` of
  `{std::function<std::string()>, std::promise}`; `drain_script_queue()` drains it
  alongside the script queue each frame. `capture_screenshot` (args: `path`
  required, `target` = `window`|`3d`|`2d`) enqueues a task that calls
  `capture_screenshot(path, target)` on the main thread — it grabs the chosen
  `Viewport` (`EditorInterface::get_editor_viewport_2d/3d(0)` for the scene views,
  or `get_tree()->get_root()` for the whole editor window), reads its
  `ViewportTexture` → `Image`, and `save_png`s it. The tool callback captures the
  owning `DidiServer*` so the task can call the member function. **The DLL hot-swap
  caveat applies:** a rebuilt `libdidi…dll` must be deployed into the project's
  `addons/didi/` and the extension reloaded before the new tool appears.

  **`gdscript_authoring_guide` — the MCP resource** (`uri: didi://guides/gdscript`,
  `text/markdown`). Tells an AI agent how to use `run_gdscript` + GDScript to
  read/write/modify everything in the project. The canonical source lives at
  repo-root `addons/didi/didi_gdscript_guide.md` (the build copies it into the
  demo); at runtime it is read via Godot `FileAccess` from
  `res://addons/didi/didi_gdscript_guide.md` in `start_server()`
  (**main thread**) and cached
  in `Impl::guide_md`; the resource provider (worker thread) only returns the
  cached copy. Because it's cached at start, editing the `.md` is picked up on the
  next server start / extension reload, not live. Serving resources required
  switching to the full `make_mcp_handler(name, version, Server&, ToolManager&,
  ResourceManager&, PromptManager&)` overload — **that overload reads tool
  descriptions from the `Tool` objects (`set_description`), ignoring the separate
  `descriptions` map the simpler overload used.** The empty `PromptManager` is
  required by the overload's signature; no prompts are registered.
- `didi_editor_plugin.{h,cpp}` — `DidiEditorPlugin : EditorPlugin`, guarded by
  `#ifdef TOOLS_ENABLED`. `_enter_tree()` creates + starts a `DidiServer`;
  `_exit_tree()` stops + frees it. This is what ties the server to the editor
  session.

## Editor-only design (two independent mechanisms)

1. **Runs only in the editor:** `DidiEditorPlugin` (EditorPlugin code never runs
   in play mode or exported games).
2. **Absent from shipped games:** `addons/didi/didi.gdextension` (deployed to
   `demo/addons/didi/`) lists **only** `.editor` libraries. Exported games match
   `template_debug`/`template_release` feature tags, find no library, and never
   load or ship the extension.

**`.gdextension` comment syntax (cost an hour once):** these files are parsed as
Godot `ConfigFile`, whose comment character is **`;`, not `#`**. A `#` comment —
especially just before `[libraries]` — silently breaks parsing of the following
section, so Godot reports *"No GDExtension library found for current OS and
architecture"* and the extension fails to load entirely (server never starts,
nothing binds `8900`). Keep all comments in
`addons/didi/didi.gdextension` as `;`.

## Worked examples: games built via `run_gdscript`

`examples/` holds complete games built end-to-end through Didi (every scene,
script, and project setting authored via `run_gdscript`, no hand-editing) — each a
step-by-step walkthrough plus a self-contained Godot project:

- `examples/tetris.md` + `examples/tetris/` — 2D Tetris (SRS rotation + wall kicks,
  7-bag, hold, ghost, line-clear scoring with levels, procedural sound).
- `examples/space-flight.md` + `examples/space-flight/` — 3D first-person
  space-flight sim (Newtonian flight + flight-assist, procedural asteroid field,
  cockpit + instrument HUD, shields/hull/fuel, starfield, sound).

(Each example folder is a self-contained project with its own `addons/didi/`; its
project file is named `<name>.godot` — rename to `project.godot` to open it.)

Beyond the games, the walkthroughs record the practical Didi techniques that came
out of building them — worth skimming before driving `run_gdscript` heavily:

- **Write multi-line files as an array of one-line strings** joined with `\n`
  (use `\t` for the file's own indentation). The tool indents *every* physical
  line of your script, so a triple-quoted multi-line literal gets corrupted.
- **`@tool` decides what you can test from Didi.** `@tool` nodes run in the editor
  (call methods, see `_draw`); non-`@tool` scripts have no live instance, so their
  methods can't be driven from a tool call, and the played game (F5) is a separate
  process Didi can't introspect. Verify runtime logic by mirroring it against a
  `@tool` node.
- **Split "change a script" from "use it" across two calls** (the engine binds the
  new script at the next frame); force a fresh load with
  `ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_REPLACE)`.

These same notes live in the `gdscript_authoring_guide` resource for MCP clients.

## Build (CMake only — no SCons)

```sh
cmake -S . -B build      # add -G "Visual Studio 17 2022" on Windows if needed
cmake --build build --config Debug --target didi
```

- **`demo/addons/didi/` is fully build-assembled and git-ignored.** The build
  compiles the library straight into it, then a `POST_BUILD` step copies the
  static addon files from the **canonical, tracked source at repo-root
  `addons/didi/`** (`didi.gdextension`, `didi.gdextension.uid`,
  `didi_gdscript_guide.md`). Edit those files in `/addons/didi`, never in
  `/demo/addons/didi` (your edits there are overwritten on the next build). A
  clean checkout + build produces a complete, loadable addon.
- The library is named `libdidi.windows.editor.x86_64.dll` to match the
  `[libraries]` entries in `addons/didi/didi.gdextension`.
- `GODOTCPP_TARGET` defaults to **`editor`** (set in `CMakeLists.txt`). Override
  with `-DGODOTCPP_TARGET=template_release` for a runtime build.
- SCons is intentionally not supported: fastmcpp is CMake+FetchContent only.

## Build gotchas (important — these cost real time)

- **MSBuild node-reuse zombies.** After a Visual Studio build, MSBuild leaves
  background nodes alive that hold locks on the build dir and the FetchContent
  git packs. This silently breaks reconfigures (they appear to succeed but write
  to the wrong dir) and `rm -rf build`. Always build with
  `MSBUILDDISABLENODEREUSE=1`, and if cleaning fails, kill stray `MSBuild`
  processes first (`Get-Process MSBuild | Stop-Process -Force`).
- **`TOOLS_ENABLED` is not defined by godot-cpp's CMake build** (its SCons build
  does). `CMakeLists.txt` defines it for the `editor` target so the
  `#ifdef TOOLS_ENABLED` guards work.
- **Don't reuse godot-cpp's `GODOTCPP_SUFFIX` target property** from the parent
  project — its value contains unevaluated generator expressions that leak into
  the output filename. `CMakeLists.txt` reconstructs the
  `.<platform>.<target>.<arch>` suffix from plain values instead.
- `build/` and `out/` are git-ignored. An orphaned, OS-locked `out/` and
  `fastmcpp/build/` may linger from earlier runs; safe to delete once unlocked.

## Open items / watch-outs

- **Version mismatch:** `demo/project.godot` targets Godot **4.7** features while
  `godot-cpp` is pinned to the **4.5** branch. GDExtensions are generally
  forward-compatible (`compatibility_minimum = 4.4`), but consider bumping the
  `godot-cpp` submodule to a matching branch if issues arise. In practice the
  4.5-built editor library loaded and ran fine in the 4.7-stable editor
  (see "Runtime verified" below), so the gap is not currently blocking.
- **Runtime verified (2026-06-18):** with the Godot **4.7-stable** editor open on
  `demo/`, the extension loads, the server listens on `127.0.0.1:8900/mcp`, and
  all tools execute end-to-end (`godot_version` → `4.7-stable (official)`).
  `run_gdscript` verified for inspection (`return {...}` → serialized
  Dictionary), multi-statement authoring (create/configure/free a `Node2D`), and
  the compile-error path (`Error 43`). The `gdscript_authoring_guide` resource
  also verified: `initialize` advertises the `resources` capability,
  `resources/list` shows it, and `resources/read` of `didi://guides/gdscript`
  returns the full markdown. Server identifies as `didi` v0.1.0, MCP protocol
  `2024-11-05`. Note: **Godot hot-reloads the GDExtension** — rebuilding
  `libdidi...dll` while the editor is open swaps in the new build, **but only
  when the editor window regains focus** (click into it); until then the running
  server still serves the previous DLL.

  **Smoke test — the server uses MCP Streamable HTTP, so a bare `tools/list`
  returns `{"error":"Mcp-Session-Id header required"}`.** You must `initialize`
  first to obtain the session id, then carry it (and an `Accept` header listing
  both JSON and SSE) on every later call:
  ```sh
  URL=http://127.0.0.1:8900/mcp
  CT='Content-Type: application/json'
  ACCEPT='Accept: application/json, text/event-stream'

  # 1) initialize — the Mcp-Session-Id comes back in a RESPONSE HEADER
  SID=$(curl -s -D - -o /dev/null "$URL" -H "$CT" -H "$ACCEPT" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"curl","version":"1.0"}}}' \
    | grep -i '^Mcp-Session-Id:' | sed 's/.*: *//' | tr -d '\r')

  # 2) complete the handshake
  curl -s "$URL" -H "$CT" -H "$ACCEPT" -H "Mcp-Session-Id: $SID" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'

  # 3) now tools/list and tools/call work
  curl -s "$URL" -H "$CT" -H "$ACCEPT" -H "Mcp-Session-Id: $SID" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

  # 4) tools/call — tool input goes under "arguments", NOT "params".
  #    (Putting it under "params" silently yields empty args; run_gdscript
  #    then reports "the 'script' argument is required".)
  curl -s "$URL" -H "$CT" -H "$ACCEPT" -H "Mcp-Session-Id: $SID" \
    -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"run_gdscript","arguments":{"script":"return Engine.get_version_info().string"}}}'

  # 5) resources — list, then read the authoring guide by URI.
  curl -s "$URL" -H "$CT" -H "$ACCEPT" -H "Mcp-Session-Id: $SID" \
    -d '{"jsonrpc":"2.0","id":4,"method":"resources/list"}'
  curl -s "$URL" -H "$CT" -H "$ACCEPT" -H "Mcp-Session-Id: $SID" \
    -d '{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"didi://guides/gdscript"}}'
  ```

## Local toolchain (as last built)

Windows; Visual Studio 2019 (MSVC v142), CMake 3.26, Python 3.12.
