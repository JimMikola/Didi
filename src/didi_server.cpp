#include "didi_server.h"

#include <godot_cpp/classes/engine.hpp>
#include <godot_cpp/classes/file_access.hpp>
#include <godot_cpp/classes/gd_script.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/scene_tree.hpp>
#include <godot_cpp/classes/sub_viewport.hpp>
#include <godot_cpp/classes/texture2d.hpp>
#include <godot_cpp/classes/viewport.hpp>
#include <godot_cpp/classes/viewport_texture.hpp>
#include <godot_cpp/classes/window.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#ifdef TOOLS_ENABLED
#include <godot_cpp/classes/editor_interface.hpp>
#endif

#include <fastmcpp/mcp/handler.hpp>
#include <fastmcpp/prompts/manager.hpp>
#include <fastmcpp/resources/manager.hpp>
#include <fastmcpp/server/server.hpp>
#include <fastmcpp/server/streamable_http_server.hpp>
#include <fastmcpp/tools/manager.hpp>

#include <chrono>
#include <deque>
#include <functional>
#include <future>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>

using namespace godot;

namespace {
// One queued run_gdscript request: the source to run plus the promise the
// worker thread is blocked on. The main thread fulfills `result` after running.
struct PendingScript {
    std::string source;
    std::promise<std::string> result;
};

// A generic main-thread task (e.g. screenshot capture): a callable to run on the
// main thread plus the promise the worker thread is blocked on.
struct PendingTask {
    std::function<std::string()> fn;
    std::promise<std::string> result;
};
} // namespace

// All fastmcpp state lives here so it stays out of the public header.
// NOTE: `meta`, `tools`, `resources`, and `prompts` are declared before
// `server` on purpose. make_mcp_handler() captures all four by reference, so
// they must outlive the server; reverse-order destruction (server first)
// guarantees it.
struct DidiServer::Impl {
    fastmcpp::server::Server meta{ "didi", "0.1.0" };
    fastmcpp::tools::ToolManager tools;
    fastmcpp::resources::ResourceManager resources;
    fastmcpp::prompts::PromptManager prompts;
    std::string godot_version = "unknown";

    // Markdown guide served as an MCP resource. Read from disk on the main
    // thread in start_server(); the resource provider (worker thread) only ever
    // reads this cached copy, never touches Godot APIs.
    std::string guide_md;

    // run_gdscript requests are produced on the server's worker thread and
    // consumed on Godot's main thread (in _process), so Godot APIs are only
    // ever touched on the main thread. Guarded by `queue_mutex`.
    std::mutex queue_mutex;
    std::deque<PendingScript> pending;
    std::deque<PendingTask> pending_tasks;

    std::unique_ptr<fastmcpp::server::StreamableHttpServerWrapper> server;
};

// URI and project-relative path of the GDScript authoring guide resource.
namespace {
constexpr const char *kGuideUri = "didi://guides/gdscript";
constexpr const char *kGuidePath = "res://addons/didi/didi_gdscript_guide.md";
} // namespace

void DidiServer::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_port", "port"), &DidiServer::set_port);
    ClassDB::bind_method(D_METHOD("get_port"), &DidiServer::get_port);
    ADD_PROPERTY(PropertyInfo(Variant::INT, "port"), "set_port", "get_port");

    ClassDB::bind_method(D_METHOD("set_bind_address", "address"), &DidiServer::set_bind_address);
    ClassDB::bind_method(D_METHOD("get_bind_address"), &DidiServer::get_bind_address);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "bind_address"), "set_bind_address", "get_bind_address");

    ClassDB::bind_method(D_METHOD("set_autostart", "enabled"), &DidiServer::set_autostart);
    ClassDB::bind_method(D_METHOD("get_autostart"), &DidiServer::get_autostart);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "autostart"), "set_autostart", "get_autostart");

    ClassDB::bind_method(D_METHOD("start_server"), &DidiServer::start_server);
    ClassDB::bind_method(D_METHOD("stop_server"), &DidiServer::stop_server);
    ClassDB::bind_method(D_METHOD("is_running"), &DidiServer::is_running);
}

DidiServer::DidiServer() {
    impl = std::make_unique<Impl>();
    register_tools();
}

DidiServer::~DidiServer() {
    // unique_ptr<Impl> needs Impl complete here; ensure the server is down.
    stop_server();
}

void DidiServer::register_tools() {
    using fastmcpp::Json;
    Impl *im = impl.get();
    DidiServer *self = this;

    const Json no_args = Json{ { "type", "object" }, { "properties", Json::object() } };

    // Health check.
    impl->tools.register_tool(fastmcpp::tools::Tool{
            "ping",
            no_args,
            Json{ { "type", "string" } },
            [](const Json &) -> Json { return "pong"; } }
            .set_description("Health check; returns 'pong'."));

    // Report the running Godot engine version. The value is captured on the
    // main thread in start_server(); the tool only reads the cached string,
    // which keeps Godot API access off the server's background thread.
    impl->tools.register_tool(fastmcpp::tools::Tool{
            "godot_version",
            no_args,
            Json{ { "type", "string" } },
            [im](const Json &) -> Json { return im->godot_version; } }
            .set_description("Returns the running Godot engine version string."));

    // Execute AI-provided GDScript against the open project. The callback runs
    // on the server's worker thread, so it cannot touch Godot APIs directly:
    // it enqueues the source and blocks until the main thread (_process) runs
    // it and reports the result back through the promise.
    impl->tools.register_tool(fastmcpp::tools::Tool{
            "run_gdscript",
            Json{ { "type", "object" },
                    { "properties", Json{ { "script", Json{ { "type", "string" } } } } },
                    { "required", Json::array({ "script" }) } },
            Json{ { "type", "string" } },
            [im](const Json &in) -> Json {
                std::string src = in.value("script", std::string());
                if (src.empty()) {
                    return std::string("error: the 'script' argument is required and must be non-empty");
                }

                std::promise<std::string> prom;
                std::future<std::string> fut = prom.get_future();
                {
                    std::lock_guard<std::mutex> lock(im->queue_mutex);
                    im->pending.push_back(PendingScript{ std::move(src), std::move(prom) });
                }

                // Block the worker thread until the main thread runs the script.
                // The timeout prevents a permanent hang if the main loop stops
                // draining (e.g. while the editor is shutting down).
                if (fut.wait_for(std::chrono::seconds(15)) != std::future_status::ready) {
                    return std::string("error: timed out after 15s waiting for the Godot main thread");
                }
                return fut.get();
            } }
            .set_description(
                    "Execute GDScript against the open Godot editor/project and return the result. "
                    "The 'script' argument is the BODY of a function (run with '@tool', 'extends RefCounted'); "
                    "use 'return <value>' to return data, serialized via var_to_str. Use this to BOTH inspect "
                    "(e.g. 'return EditorInterface.get_edited_scene_root().get_class()') and author/modify content "
                    "(e.g. create nodes, set properties, save resources). Runs on the editor's main thread. "
                    "See the 'gdscript_authoring_guide' resource for patterns and examples."));

    // Capture a screenshot of the editor to a PNG. Like run_gdscript, the
    // callback runs on the worker thread, so it enqueues a main-thread task
    // (Godot's viewport/image APIs are main-thread-only) and blocks on the result.
    impl->tools.register_tool(fastmcpp::tools::Tool{
            "capture_screenshot",
            Json{ { "type", "object" },
                    { "properties", Json{
                            { "path", Json{ { "type", "string" } } },
                            { "target", Json{ { "type", "string" },
                                    { "enum", Json::array({ "window", "3d", "2d" }) } } } } },
                    { "required", Json::array({ "path" }) } },
            Json{ { "type", "string" } },
            [self, im](const Json &in) -> Json {
                std::string path = in.value("path", std::string());
                std::string target = in.value("target", std::string("window"));
                if (path.empty()) {
                    return std::string("error: the 'path' argument is required (e.g. 'res://shot.png')");
                }

                std::promise<std::string> prom;
                std::future<std::string> fut = prom.get_future();
                {
                    std::lock_guard<std::mutex> lock(im->queue_mutex);
                    im->pending_tasks.push_back(PendingTask{
                            [self, path, target]() -> std::string {
                                return self->capture_screenshot(String::utf8(path.c_str()), String::utf8(target.c_str()));
                            },
                            std::move(prom) });
                }

                if (fut.wait_for(std::chrono::seconds(15)) != std::future_status::ready) {
                    return std::string("error: timed out after 15s waiting for the Godot main thread");
                }
                return fut.get();
            } }
            .set_description(
                    "Capture a screenshot of the Godot editor and save it as a PNG. Args: 'path' "
                    "(required; e.g. 'res://shot.png' or an absolute path) and optional 'target' = "
                    "'window' (whole editor window, default), '3d' (the 3D scene viewport), or '2d' "
                    "(the 2D scene viewport). Returns the saved path and image dimensions."));

    // Serve the GDScript authoring guide as an MCP resource. The provider runs
    // on the server's worker thread, so it only returns the cached markdown
    // (loaded on the main thread in start_server()); it never touches Godot.
    fastmcpp::resources::Resource guide;
    guide.uri = kGuideUri;
    guide.name = "gdscript_authoring_guide";
    guide.title = "GDScript authoring guide for run_gdscript";
    guide.description =
            "How an AI agent should use the run_gdscript tool and GDScript to read, write, "
            "and modify everything in the open Godot project.";
    guide.mime_type = "text/markdown";
    guide.provider = [im](const Json &) -> fastmcpp::resources::ResourceContent {
        return fastmcpp::resources::ResourceContent{ kGuideUri, std::string("text/markdown"), im->guide_md };
    };
    impl->resources.register_resource(guide);
}

void DidiServer::_ready() {
    // Process every frame so run_gdscript requests queued by the server thread
    // get executed on the main thread. This is needed in the editor too (where
    // the plugin owns the server), so enable it before the editor early-out.
    set_process(true);

    // Never run the network server while the node sits in the editor.
    if (Engine::get_singleton()->is_editor_hint()) {
        return;
    }

    if (autostart) {
        start_server();
    }
}

void DidiServer::_process(double delta) {
    drain_script_queue();
}

void DidiServer::drain_script_queue() {
    // Take both batches under the lock, then run them without holding it
    // (each can re-enter Godot for arbitrarily long).
    std::deque<PendingScript> scripts;
    std::deque<PendingTask> tasks;
    {
        std::lock_guard<std::mutex> lock(impl->queue_mutex);
        scripts.swap(impl->pending);
        tasks.swap(impl->pending_tasks);
    }

    for (PendingScript &s : scripts) {
        s.result.set_value(execute_gdscript(s.source));
    }
    for (PendingTask &t : tasks) {
        t.result.set_value(t.fn());
    }
}

std::string DidiServer::capture_screenshot(const String &path, const String &target) {
    // Pick the viewport to capture. "2d"/"3d" grab the editor's scene viewport;
    // anything else ("window") grabs the editor's root window viewport.
    Viewport *vp = nullptr;
    if (target == "3d" || target == "2d") {
        // Editor scene viewport. Fail explicitly if it isn't available rather
        // than silently capturing something the caller didn't ask for.
#ifdef TOOLS_ENABLED
        EditorInterface *ei = EditorInterface::get_singleton();
        if (ei != nullptr) {
            vp = (target == "3d") ? ei->get_editor_viewport_3d(0) : ei->get_editor_viewport_2d();
        }
#endif
        if (vp == nullptr) {
            return std::string("error: the '") + target.utf8().get_data() + "' scene viewport is unavailable";
        }
    } else {
        // "window" (the default): the editor's root window viewport.
        SceneTree *st = get_tree();
        if (st != nullptr) {
            vp = st->get_root();
        }
        if (vp == nullptr) {
            return "error: no window viewport available to capture";
        }
    }

    Ref<ViewportTexture> tex = vp->get_texture();
    if (tex.is_null()) {
        return "error: viewport has no texture";
    }
    Ref<Image> img = tex->get_image();
    if (img.is_null()) {
        return "error: could not read the viewport image";
    }
    const Error err = img->save_png(path);
    if (err != OK) {
        return std::string("error: save_png failed (Error ") + std::to_string((int)err) + ") for " +
                path.utf8().get_data();
    }
    return std::string("saved ") + path.utf8().get_data() + " (" +
            std::to_string(img->get_width()) + "x" + std::to_string(img->get_height()) + ")";
}

std::string DidiServer::execute_gdscript(const std::string &user_source) {
    // Wrap the caller's source as the body of a method on a throwaway @tool
    // RefCounted script. Every line is indented one level so it nests inside
    // _didi_run(); callers use `return <value>` to produce a result.
    //
    // GDScript forbids mixing tabs and spaces in indentation, so the indent we
    // add must match the caller's own style: if any line is space-indented we
    // indent with spaces, otherwise a tab (also the default when the body has
    // no nested blocks of its own). This lets callers write either style
    // without hitting a "mixed tabs and spaces" compile error.
    String body = String::utf8(user_source.c_str());

    String unit = "\t";
    const PackedStringArray lines = body.split("\n");
    for (int i = 0; i < lines.size(); i++) {
        const String &line = lines[i];
        if (line.begins_with(" ")) {
            unit = "    ";
            break;
        }
        if (line.begins_with("\t")) {
            break; // tab-indented; keep the default unit
        }
    }

    String indented = unit + body.replace("\n", "\n" + unit);
    String wrapped = "@tool\nextends RefCounted\nfunc _didi_run():\n" + indented + "\n";

    Ref<GDScript> gd;
    gd.instantiate();
    gd->set_source_code(wrapped);

    const Error err = gd->reload();
    if (err != OK) {
        return std::string("compile error: GDScript.reload() returned Error ") + std::to_string((int)err);
    }

    const Variant instance = gd->call("new");
    Object *obj = instance;
    if (obj == nullptr) {
        return "runtime error: failed to instantiate the compiled script";
    }

    const Variant result = obj->call("_didi_run");
    return std::string(UtilityFunctions::var_to_str(result).utf8().get_data());
}

void DidiServer::_exit_tree() {
    stop_server();
}

void DidiServer::load_guide() {
    // Read the markdown guide from the project (res://). Called on the main
    // thread; FileAccess is a Godot API and must not run on the worker thread.
    Ref<FileAccess> f = FileAccess::open(kGuidePath, FileAccess::READ);
    if (f.is_valid()) {
        impl->guide_md = f->get_as_text().utf8().get_data();
        f->close();
    } else {
        impl->guide_md =
                "# GDScript authoring guide\n\nThe guide file was not found at "
                "`res://addons/didi/didi_gdscript_guide.md`. Use the `run_gdscript` tool to execute "
                "GDScript against the open project: pass `script` (a function body) and "
                "use `return <value>` to return data.\n";
        UtilityFunctions::printerr("DidiServer: guide not found at ", kGuidePath, "; serving fallback text.");
    }
}

bool DidiServer::start_server() {
    if (impl->server && impl->server->running()) {
        return true;
    }

    // Capture the engine version on the (main) calling thread so the tool
    // callback never touches Godot APIs from the server's worker thread.
    Dictionary version_info = Engine::get_singleton()->get_version_info();
    impl->godot_version = String(version_info.get("string", "unknown")).utf8().get_data();

    // Load the authoring guide here, on the main thread, so the resource
    // provider (worker thread) only ever returns this cached copy.
    load_guide();

    auto handler = fastmcpp::mcp::make_mcp_handler(
            "didi", "0.1.0", impl->meta, impl->tools, impl->resources, impl->prompts);

    const std::string host = bind_address.utf8().get_data();
    impl->server = std::make_unique<fastmcpp::server::StreamableHttpServerWrapper>(
            handler, host, port, "/mcp");

    if (!impl->server->start()) {
        UtilityFunctions::printerr("DidiServer: failed to start MCP server on ", bind_address, ":", port);
        impl->server.reset();
        return false;
    }

    UtilityFunctions::print("DidiServer: MCP server listening on http://", bind_address, ":", port, "/mcp");
    return true;
}

void DidiServer::stop_server() {
    if (impl->server) {
        impl->server->stop();
        impl->server.reset();
    }
}

bool DidiServer::is_running() const {
    return impl->server && impl->server->running();
}

void DidiServer::set_port(int p_port) {
    port = p_port;
}

int DidiServer::get_port() const {
    return port;
}

void DidiServer::set_bind_address(const String &p_address) {
    bind_address = p_address;
}

String DidiServer::get_bind_address() const {
    return bind_address;
}

void DidiServer::set_autostart(bool p_autostart) {
    autostart = p_autostart;
}

bool DidiServer::get_autostart() const {
    return autostart;
}
