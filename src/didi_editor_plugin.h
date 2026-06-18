#ifndef DIDI_EDITOR_PLUGIN_H
#define DIDI_EDITOR_PLUGIN_H

// This plugin only exists in editor builds (GODOTCPP_TARGET=editor, which
// defines TOOLS_ENABLED via CMakeLists). It is never compiled into the
// template libraries that ship with an exported game.
#ifdef TOOLS_ENABLED

#include <godot_cpp/classes/editor_plugin.hpp>

namespace godot {

class DidiServer;

// Editor-only plugin that owns the MCP DidiServer for the lifetime of the
// editor session. The editor instantiates this automatically (registered via
// EditorPlugins::add_by_type in register_types.cpp); its code never runs in a
// playing or exported game.
class DidiEditorPlugin : public EditorPlugin {
    GDCLASS(DidiEditorPlugin, EditorPlugin)

private:
    DidiServer *server = nullptr;

protected:
    static void _bind_methods() {}

public:
    void _enter_tree() override; // editor opens the project / plugin loads
    void _exit_tree() override;  // editor closes / plugin unloads
};

} // namespace godot

#endif // TOOLS_ENABLED
#endif // DIDI_EDITOR_PLUGIN_H
