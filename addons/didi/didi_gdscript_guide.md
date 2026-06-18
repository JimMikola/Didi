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

```gdscript
var src = """extends Node
func _ready():
    print("hello from a generated script")
"""
var f = FileAccess.open("res://generated/hello.gd", FileAccess.WRITE)
if f == null: return "open error %d" % FileAccess.get_open_error()
f.store_string(src)
f.close()
EditorInterface.get_resource_filesystem().scan()
return "wrote res://generated/hello.gd"
```

### Attach a script to a node

```gdscript
var node = EditorInterface.get_edited_scene_root().get_node("Player")
node.set_script(load("res://player.gd"))
EditorInterface.mark_scene_as_unsaved()
return "ok"
```

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

---

## Run a standalone script (when you need helper funcs/classes)

The wrapped-body form can't declare top-level functions. When you need them, build
a full script as a `GDScript` resource and instance it yourself:

```gdscript
var gd = GDScript.new()
gd.source_code = """
extends RefCounted
func helper(x): return x * x
func run():
    var total := 0
    for i in range(5): total += helper(i)
    return total
"""
gd.reload()
var obj = gd.new()
return obj.run()
```

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
