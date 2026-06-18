#include "register_types.h"

#include "didi_server.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#ifdef TOOLS_ENABLED
#include "didi_editor_plugin.h"

#include <godot_cpp/classes/editor_plugin_registration.hpp>
#endif

using namespace godot;

void initialize_didi_module(ModuleInitializationLevel p_level) {
    if (p_level == MODULE_INITIALIZATION_LEVEL_SCENE) {
        GDREGISTER_CLASS(DidiServer);
    }

#ifdef TOOLS_ENABLED
    // Register the editor plugin so the editor instantiates it automatically.
    if (p_level == MODULE_INITIALIZATION_LEVEL_EDITOR) {
        GDREGISTER_INTERNAL_CLASS(DidiEditorPlugin);
        EditorPlugins::add_by_type<DidiEditorPlugin>();
    }
#endif
}

void uninitialize_didi_module(ModuleInitializationLevel p_level) {
}

extern "C" {
// Initialization entry point referenced by didi.gdextension.
GDExtensionBool GDE_EXPORT didi_library_init(
        GDExtensionInterfaceGetProcAddress p_get_proc_address,
        const GDExtensionClassLibraryPtr p_library,
        GDExtensionInitialization *r_initialization) {
    GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_didi_module);
    init_obj.register_terminator(uninitialize_didi_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}
}
