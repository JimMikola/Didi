<p align="center">
  <h1 align="center">Didi MCP Server for Godot</h1>
  <p align="center">
    <strong>"We always find something, eh Didi, to give us the impression we exist?"</strong>
  </p>
  <p align="center">
    <a href="#"><img src="https://img.shields.io/badge/Godot-4.5%2B-blue?logo=godotengine" alt="Godot 4.5+"></a>
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
├── examples/              # complete games built end-to-end through Didi (see "Examples")
│   ├── tetris.md              # walkthrough: a 2D Tetris game via run_gdscript
│   ├── tetris/                # the resulting self-contained Tetris project
│   ├── space-flight.md        # walkthrough: a 3D space-flight sim via run_gdscript
│   └── space-flight/          # the resulting self-contained space-flight project
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
* Tools registered out of the box: `ping`, `godot_version`, `run_gdscript`
  (execute GDScript against the open project — inspect and author anything), and
  `capture_screenshot` (save a PNG of the editor window or the 2D/3D scene
  viewport).
* Serves the `gdscript_authoring_guide` MCP resource
  (`didi://guides/gdscript`) describing how to drive `run_gdscript`.

### Trying it in Godot

1. Build the library (see above) — it lands in `demo/addons/didi/`.
2. Open `demo/project.godot` in the Godot **editor** (4.5+). The
   `DidiEditorPlugin` starts the server automatically and logs
   `DidiServer: MCP server listening on http://127.0.0.1:8900/mcp`.
3. Point any MCP client (Streamable HTTP transport) at that URL, or smoke-test
   with curl:

   ```sh
   curl -s http://127.0.0.1:8900/mcp -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
   ```

## Examples

The [`examples/`](examples/) folder contains complete games **built entirely
through Didi** — every scene, script, and project setting authored by an AI
calling the `run_gdscript` tool, with no hand-editing. Each example is a
step-by-step walkthrough (`.md`) alongside the resulting self-contained Godot
project:

* **Tetris** — [`examples/tetris.md`](examples/tetris.md) +
  [`examples/tetris/`](examples/tetris/). A 2D Tetris with SRS rotation + wall
  kicks, a 7-bag randomizer, hold and ghost pieces, line-clear scoring with
  rising levels/speed, and procedural sound.
* **Space flight** — [`examples/space-flight.md`](examples/space-flight.md) +
  [`examples/space-flight/`](examples/space-flight/). A 3D first-person
  space-flight sim: Newtonian 6DOF flight with flight-assist, a procedural
  asteroid field, a cockpit frame + instrument HUD, shields/hull/fuel survival
  systems, a starfield, and sound.

The walkthrough `.md` files double as practical guides to driving `run_gdscript`:
they record the techniques and gotchas that came up while building each game
(array-of-lines file writing, `@tool` vs. runtime testing, splitting
`set_script` across calls, and more), complementing the `gdscript_authoring_guide`
MCP resource.

Each example folder is a self-contained Godot project **except for `addons/didi/`**,
which is git-ignored — build the plugin (it lands in `demo/addons/didi/`) and copy
that folder into the example before opening it in Godot.

## Notes

* Compiled binaries and the generated `demo/addons/didi/` are intentionally
  git-ignored. The tracked source is `src/`, the build files, and the canonical
  addon files under `addons/didi/`.
