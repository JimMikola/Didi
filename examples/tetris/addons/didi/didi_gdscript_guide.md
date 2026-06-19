# Authoring & inspecting a Godot project with `run_gdscript`

This guide is for an **AI agent** connected to the **Didi** MCP server. Didi runs
inside the open Godot **editor** and exposes one general-purpose tool,
`run_gdscript`, that lets you read, write, and modify *anything* in the project by
executing GDScript on the editor's main thread.

If you can do it in the Godot editor or in GDScript, you can do it through this
tool. This document explains the contract and gives copy-pasteable patterns.

---

## The `run_gdscript` contract

`run_gdscript` takes a single argument, `script` (a string). That string is the
**body of a function** — it is wrapped, compiled, and run roughly like this:

```gdscript
@tool
extends RefCounted
func _didi_run():
    <your script, indented one level>
```

Therefore:

- **Return a value with `return`.** Whatever you `return` is serialized with
  Godot's `var_to_str()` and sent back as the tool result. Return a
  `Dictionary`/`Array` for structured output.
- **Statements are allowed** — declare `var`s, loop, branch, call methods, etc.
- **Indent consistently — all tabs *or* all spaces, never both.** Your script is
  wrapped as a function body, so it gets indented one level; the tool matches the
  indentation style it detects in your script (spaces if any line is
  space-indented, otherwise tabs). GDScript rejects a script that mixes tabs and
  spaces in its own indentation, so pick one style for your nested
  `if`/`for`/`while` blocks and stick to it.
- **You cannot declare functions, classes, signals, or `const`s at top level**
  inside the body (they would be nested inside `_didi_run`). If you need a helper
  type, build it as a separate `GDScript` resource (see "Run a standalone script"
  below).
- **It runs on the main thread**, so all editor and scene-tree APIs are safe to
  call. Long-running work blocks the editor — keep scripts quick.
- The script context is `@tool` and `extends RefCounted`, so `self` is a throwaway
  `RefCounted`. Use the global singletons (`EditorInterface`, `ProjectSettings`,
  `ResourceLoader`, `ResourceSaver`, `FileAccess`, `ClassDB`, …) to reach project
  state.

### Errors

- **Compile errors** come back as `compile error: GDScript.reload() returned Error <code>`
  (code `43` = `ERR_COMPILATION_FAILED`). Fix the syntax and retry.
- **Runtime errors** (e.g. calling a method on `null`) are printed to Godot's
  Output panel and the call returns `null`. Guard against `null` and validate
  paths before using them. To surface a problem in the result, check and
  `return` an explicit error string/Dictionary yourself.

### First call to orient yourself

```gdscript
return {
    "engine": Engine.get_version_info().string,
    "project": ProjectSettings.get_setting("application/config/name"),
    "edited_scene": EditorInterface.get_edited_scene_root() != null \
        if EditorInterface.get_edited_scene_root() == null else \
        EditorInterface.get_edited_scene_root().scene_file_path,
    "open_scenes": EditorInterface.get_open_scenes(),
}
```

---

## The key entry points

| You want to reach… | Use |
|---|---|
| The scene open in the editor | `EditorInterface.get_edited_scene_root()` |
| The current node selection | `EditorInterface.get_selection().get_selected_nodes()` |
| All open scenes / switch scenes | `EditorInterface.get_open_scenes()`, `EditorInterface.open_scene_from_path(path)` |
| The project's file system (editor) | `EditorInterface.get_resource_filesystem()` |
| Project settings | `ProjectSettings.get_setting(name)` / `set_setting(name, value)` |
| Load any resource | `ResourceLoader.load(path)` or `load(path)` |
| Save a resource | `ResourceSaver.save(res, path)` |
| Raw file read/write | `FileAccess.open(path, FileAccess.READ/WRITE)` |
| Directory listing | `DirAccess.open(path)` |
| Class/API reflection | `ClassDB.*` |
| Undo/redo integration | `EditorInterface.get_editor_undo_redo()` |

> `res://` paths address the project root. In the editor you can also read/write
> with absolute OS paths via `ProjectSettings.globalize_path("res://...")`.

---

## READ — inspecting the project

### Dump the scene tree

```gdscript
var root = EditorInterface.get_edited_scene_root()
if root == null:
    return "no scene is open"
var out := []
var stack := [root]
while not stack.is_empty():
    var n = stack.pop_back()
    out.append({
        "path": str(root.get_path_to(n)),
        "name": n.name,
        "type": n.get_class(),
        "script": n.get_script().resource_path if n.get_script() else null,
    })
    for c in n.get_children():
        stack.append(c)
return out
```

### Inspect one node's properties

```gdscript
var root = EditorInterface.get_edited_scene_root()
var node = root.get_node("Player/Sprite2D")   # path relative to the scene root
var data := {}
for p in node.get_property_list():
    # USAGE_EDITOR == 4: only the inspector-visible properties
    if p.usage & PROPERTY_USAGE_EDITOR:
        data[p.name] = var_to_str(node.get(p.name))
return data
```

### Read project settings, autoloads, input map

```gdscript
return {
    "main_scene": ProjectSettings.get_setting("application/run/main_scene"),
    "actions": InputMap.get_actions(),
}
```

### Read a resource or a script's source

```gdscript
var res = load("res://data/config.tres")
return var_to_str(res)            # whole resource
# Or a script's text:
var src = FileAccess.get_file_as_string("res://player.gd")
return src
```

### List files of a given type

```gdscript
var found := []
var dirs := ["res://"]
while not dirs.is_empty():
    var d = dirs.pop_back()
    var da = DirAccess.open(d)
    if da == null: continue
    for f in da.get_files():
        if f.ends_with(".tscn"): found.append(d.path_join(f))
    for sub in da.get_directories():
        dirs.append(d.path_join(sub))
return found
```

---

## WRITE / MODIFY — changing existing content

### Set a property on a node in the open scene

```gdscript
var root = EditorInterface.get_edited_scene_root()
var node = root.get_node("Player")
node.position = Vector2(100, 200)
node.set("speed", 350.0)
# Tell the editor the scene changed so it offers to save (see "Saving" below).
EditorInterface.mark_scene_as_unsaved()
return "ok"
```

> **Prefer the undo/redo manager for editor edits** so the user can Ctrl-Z and
> the inspector refreshes:
> ```gdscript
> var ur = EditorInterface.get_editor_undo_redo()
> var node = EditorInterface.get_edited_scene_root().get_node("Player")
> ur.create_action("Set Player speed")
> ur.add_do_property(node, "speed", 350.0)
> ur.add_undo_property(node, "speed", node.speed)
> ur.commit_action()
> return "ok"
> ```

### Modify and re-save a resource

```gdscript
var res = load("res://data/config.tres")
res.volume = 0.8
var err = ResourceSaver.save(res, "res://data/config.tres")
return "save error %d" % err if err != OK else "saved"
```

### Edit project settings

```gdscript
ProjectSettings.set_setting("application/config/name", "My Game")
var err = ProjectSettings.save()
return "save error %d" % err if err != OK else "saved"
```

---

## CREATE — adding new content

### Add a node to the open scene

Nodes added in the editor must have their `owner` set to the scene root, or they
will not be saved into the `.tscn`.

```gdscript
var root = EditorInterface.get_edited_scene_root()
if root == null: return "no scene open"
var sprite = Sprite2D.new()
sprite.name = "NewSprite"
root.add_child(sprite)
sprite.owner = root                       # REQUIRED so it persists to the scene
EditorInterface.mark_scene_as_unsaved()
return str(root.get_path_to(sprite))
```

> **Procedural content: a `@tool` generator with *unowned* children.** The inverse
> of the rule above is useful for things like a scattered asteroid field, a
> starfield, or any generated layout: make a `@tool` node whose `_ready()` builds
> its children but **does not set their `owner`**. They then render both in the
> editor and at runtime, yet aren't saved into the `.tscn` (so it stays small and
> a regenerate isn't baked in). Clear existing children at the top of the generator
> (`for c in get_children(): c.free()`) so re-runs / scene reloads don't stack
> duplicates, and drive a fixed RNG `seed` for a reproducible layout.

### Create a brand-new scene file

```gdscript
var root = Node2D.new()
root.name = "Level1"
var child = Camera2D.new()
child.name = "Camera"
root.add_child(child)
child.owner = root                        # owner = the packed root

var packed = PackedScene.new()
var err = packed.pack(root)
if err != OK: return "pack error %d" % err
err = ResourceSaver.save(packed, "res://levels/level1.tscn")
EditorInterface.get_resource_filesystem().scan()   # refresh the FileSystem dock
return "save error %d" % err if err != OK else "res://levels/level1.tscn"
```

### Create a new resource

```gdscript
var mat = StandardMaterial3D.new()
mat.albedo_color = Color(1, 0, 0)
var err = ResourceSaver.save(mat, "res://materials/red.tres")
return "save error %d" % err if err != OK else "saved"
```

### Write a new script (or any text file)

**Build multi-line file content as an array of single-line strings — not a
triple-quoted literal.** The tool wraps your script as a function body and indents
**every physical line**, so a `"""..."""` block spanning several lines has its
indentation shifted and the file you write is corrupted. Joining single-line
strings sidesteps that; put the file's *own* indentation inside the strings as
`\t` (those escapes are part of the string value, untouched by the wrapper):

```gdscript
var lines = [
    "extends Node",
    "",
    "func _ready() -> void:",
    "\tprint(\"hello from a generated script\")",
]
var f = FileAccess.open("res://generated/hello.gd", FileAccess.WRITE)
if f == null: return "open error %d" % FileAccess.get_open_error()
f.store_string("\n".join(lines) + "\n")
f.close()
EditorInterface.get_resource_filesystem().scan()
return "wrote res://generated/hello.gd"
```

To **edit** an existing file, read it (`FileAccess.get_file_as_string`), transform
the text (`String.replace`, or append lines), and write it back — guard with an
`if "marker" in src` check so re-running is idempotent.

### Attach a script to a node

```gdscript
var node = EditorInterface.get_edited_scene_root().get_node("Player")
node.set_script(load("res://player.gd"))
EditorInterface.mark_scene_as_unsaved()
return "ok"
```

> **Split "change a script" and "use it" across two `run_gdscript` calls.** When
> you write/reload a `.gd` file or `set_script()` a node, the new members are not
> usable until the engine processes the reload — which happens at the next frame
> boundary, i.e. on your **next** tool call. Calling a freshly-assigned method in
> the *same* script (e.g. `node.set_script(s); node.new_method()`) fails. So:
> **call 1** writes the file / sets the script (and `scan()`); **call 2** loads it,
> instantiates it, or calls its new methods. To bypass the resource cache when a
> script changed on disk, reload with
> `ResourceLoader.load(path, "GDScript", ResourceLoader.CACHE_MODE_REPLACE)`.

---

## Saving — making changes stick

Editing live nodes changes the in-memory scene only. To persist:

- **Save the currently edited scene:** `EditorInterface.save_scene()`
- **Save a scene by path:** `EditorInterface.save_scene_as(path)` (or pack +
  `ResourceSaver.save` as above).
- **Save all open scenes:** `EditorInterface.save_all_scenes()`
- **Resources/settings:** `ResourceSaver.save(...)` / `ProjectSettings.save()`.
- After creating or deleting files on disk, call
  `EditorInterface.get_resource_filesystem().scan()` so the FileSystem dock and
  the resource cache pick them up.

Use `EditorInterface.mark_scene_as_unsaved()` when you mutate nodes but want the
user to decide when to save.

**Only node properties and `@export` variables persist to a saved scene** — plain
script variables do not. So `label.text = "5"` then `save_scene()` sticks, but a
non-exported script field won't. The flip side: values you poke onto live nodes
just to preview something *can* get baked in if you `save_scene()` afterward, so
reset them (or don't save) when you're only inspecting.

---

## Run a standalone script (when you need helper funcs/classes)

The wrapped-body form can't declare top-level functions. When you need them, build
a full script as a `GDScript` resource and instance it yourself. Build its source
the same way — an array of lines joined with `\n` — so the wrapper can't shift the
indentation (a triple-quoted literal here would break the same way it does when
writing a file):

```gdscript
var lines = [
    "extends RefCounted",
    "func helper(x): return x * x",
    "func run():",
    "\tvar total := 0",
    "\tfor i in range(5):",
    "\t\ttotal += helper(i)",
    "\treturn total",
]
var gd = GDScript.new()
gd.source_code = "\n".join(lines) + "\n"
gd.reload()
var obj = gd.new()
return obj.run()
```

---

## What you can observe and test from Didi

`run_gdscript` executes inside the **editor**, against the edited scene. That
determines what you can actually verify:

- **`@tool` nodes run in the editor.** Their `_ready`/`_process`/`_draw` execute,
  and you can call their methods directly from a tool call. Make data/visual nodes
  you want to inspect or drive from Didi `@tool` — then you can call a method and
  *see* `_draw` update in the viewport.
- **Non-`@tool` scripts have no live instance in the editor.** The node carries the
  script (so `node.has_method(...)` is true), but nothing is running, so calling
  its methods from a tool call errors. Keep gameplay-only logic non-`@tool` so it
  runs solely in the real game.
- **The played game (F5) is a separate OS process.** Didi talks to the editor, not
  to the running game — you can't introspect or drive a live play session through
  it.

So to test runtime-only logic without launching the game, **mirror it against a
`@tool` node**: call the same lower-level methods (which *do* run in the editor)
and assert the result — e.g. drive a board/model node's `is_valid`/`move`/`rotate`
directly, instead of the controller that only runs at play time. Then confirm
input and timing by running the game and watching.

---

## Practical tips

- **Always null-check** `EditorInterface.get_edited_scene_root()` and
  `get_node(...)` results; return a clear message instead of dereferencing `null`.
- **Return structured data** (`Dictionary`/`Array`) when inspecting; it serializes
  cleanly and is easy for you to parse.
- **Make one change at a time** and re-inspect to confirm, especially before
  saving over user files.
- **Respect the user's work:** prefer the undo/redo manager for scene edits, and
  avoid `save_*` / overwriting files unless that's the explicit goal.
- **Keep scripts fast** — they run on the editor's main thread and block the UI.
- **Paths are `res://`-relative.** Use `node.get_path_to(other)` to produce paths
  you can feed back into `get_node(...)`.
- **Don't use `:=` on values read through an untyped node reference.** Node
  handles like `get_node_or_null(...)`, `get_edited_scene_root()`, or a plain
  `var ship = ...` are untyped (`Variant`) to the compiler, so anything you read
  off them is also untyped — and `var b := ship.global_transform.basis` fails to
  compile with *"Cannot infer the type of 'b' because the value doesn't have a set
  type."* Use plain `=` (`var b = ship.global_transform.basis`), or give the
  reference a concrete type (`@onready var ship: CharacterBody3D = $Ship`, or a
  `class_name`) so inference works. The same applies when writing a generated
  script that reads other nodes.
