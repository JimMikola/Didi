#include "didi_editor_plugin.h"

#ifdef TOOLS_ENABLED

#include "didi_server.h"

#include <godot_cpp/core/memory.hpp>

using namespace godot;

void DidiEditorPlugin::_enter_tree() {
    // Create the server as a child so it participates in the editor scene tree,
    // then start it explicitly (DidiServer's own _ready autostart is suppressed
    // while is_editor_hint() is true, so the plugin is the single owner here).
    server = memnew(DidiServer);
    add_child(server);
    server->start_server();
}

void DidiEditorPlugin::_exit_tree() {
    if (server) {
        server->stop_server();
        remove_child(server);
        memdelete(server);
        server = nullptr;
    }
}

#endif // TOOLS_ENABLED
