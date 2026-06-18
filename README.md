<p align="center">
  <h1 align="center">Didi MCP Server for Godot</h1>
  <p align="center">
    <strong>"We always find something, eh Didi, to give us the impression we exist?"</strong>
  </p>
  <p align="center">
    <a href="#"><img src="https://img.shields.io/badge/Godot-4.2%2B-blue?logo=godotengine" alt="Godot 4.5+"></a>
    <a href="#"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
    <a href="#"><img src="https://img.shields.io/badge/MCP-Compatible-green" alt="MCP Compatible"></a>
    <a href="#"><img src="https://img.shields.io/badge/Platform-Editor%20Only-orange" alt="Editor Only"></a>
  </p>
</p>

# Didi

MCP Server plugin for Godot Game Engine, implemented as a C++ [GDExtension](https://docs.godotengine.org/en/stable/tutorials/scripting/gdextension/what_is_gdextension.html).

Didi is an **editor-only authoring helper**: it runs an MCP server while you have
the project open in the Godot editor, and is excluded from exported games.

## Layout

```
Didi/
├── godot-cpp/              # submodule: Godot 4.5 C++ bindings
├── fastmcpp/               # submodule: MCP C++ library
├── addons/didi/            # canonical, tracked addon files (build copies these into the demo):
│   ├── didi.gdextension        # tells Godot which library to load per platform
│   ├── didi.gdextension.uid    # extension UID
│   └── didi_gdscript_guide.md  # guide served as the gdscript_authoring_guide MCP resource
├── src/
│   ├── register_types.{h,cpp}      # GDExtension entry point + class registration
│   ├── didi_server.{h,cpp}         # DidiServer node: HTTP MCP server (fastmcpp)
│   └── didi_editor_plugin.{h,cpp}  # editor-only plugin that runs the server
├── demo/
│   ├── project.godot       # minimal Godot project to load the extension
│   └── addons/didi/        # generated (git-ignored): static files above + the compiled library
└── CMakeLists.txt          # CMake build (godot-cpp + fastmcpp + the extension)
```

## Prerequisites

* A C++17 compiler (MSVC, GCC, or Clang).
* [Git](https://git-scm.com/) with submodule support.
* [CMake](https://cmake.org/) ≥ 3.22.
* Network access for the first configure (fastmcpp fetches `nlohmann/json` and
  `cpp-httplib` via CMake `FetchContent`).

## Getting the source

```sh
git clone --recurse-submodules <repo-url>
# or, if already cloned:
git submodule update --init --recursive
```

## Building

The build assembles a complete, loadable addon at `demo/addons/didi/` so the demo
project can load it directly.

```sh
cmake -S . -B build                  # add -G "Visual Studio 17 2022" on Windows if desired
cmake --build build --config Debug --target didi
```

Notes on the build:

* **`demo/addons/didi/` is generated (git-ignored).** The build compiles the
  library into it, then copies the static addon files (`didi.gdextension`, its
  `.uid`, and `didi_gdscript_guide.md`) from the canonical, tracked source at the
  repo root, **`addons/didi/`**. Edit the addon files there, not in the demo copy.
* It is CMake-only: fastmcpp is a CMake project that pulls its own dependencies
  via `FetchContent`, so it is consumed with `add_subdirectory(fastmcpp)` rather
  than through godot-cpp's SCons build.
* `GODOTCPP_TARGET` defaults to `editor`, producing
  `libdidi.<platform>.editor.<arch>.<ext>`. This is what makes the extension
  editor-only (see below). Override with `-DGODOTCPP_TARGET=template_release`
  for a runtime build.

## Editor-only by design

Didi is a development helper, so it must run in the editor but never in a
shipped game. Two independent mechanisms enforce that:

1. **It runs only in the editor — `DidiEditorPlugin`.** An `EditorPlugin`
   (registered from C++ at the `EDITOR` initialization level via
   `EditorPlugins::add_by_type`) is instantiated automatically by the editor.
   Its `_enter_tree()` starts the MCP server and `_exit_tree()` stops it, so the
   server's lifetime matches the editor session. `EditorPlugin` code never runs
   in play mode or in an exported game.

2. **It is absent from exported games — editor-only library.** `addons/didi/didi.gdextension`
   lists only `.editor` libraries. Exported games match the `template_debug` /
   `template_release` feature tags, find no matching library, and so the
   extension (and all of fastmcpp / cpp-httplib) is neither loaded nor shipped.

## The MCP server

`DidiServer` hosts an HTTP-based MCP server (fastmcpp's Streamable HTTP
transport, MCP spec 2025-03-26):

* Endpoint: `http://127.0.0.1:8900/mcp` (configurable via the `port` and
  `bind_address` properties).
* Runs on a background thread (`start()` is non-blocking), so it does not stall
  the editor.
* Tools registered out of the box: `ping`, `godot_version`, and `run_gdscript`
  (execute GDScript against the open project — inspect and author anything).
* Serves the `gdscript_authoring_guide` MCP resource
  (`didi://guides/gdscript`) describing how to drive `run_gdscript`.

### Trying it in Godot

1. Build the library (see above) — it lands in `demo/addons/didi/`.
2. Open `demo/project.godot` in the Godot **editor** (4.4+). The
   `DidiEditorPlugin` starts the server automatically and logs
   `DidiServer: MCP server listening on http://127.0.0.1:8900/mcp`.
3. Point any MCP client (Streamable HTTP transport) at that URL, or smoke-test
   with curl:

   ```sh
   curl -s http://127.0.0.1:8900/mcp -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
   ```

## Notes

* Compiled binaries and the generated `demo/addons/didi/` are intentionally
  git-ignored. The tracked source is `src/`, the build files, and the canonical
  addon files under `addons/didi/`.
