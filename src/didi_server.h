#ifndef DIDI_SERVER_H
#define DIDI_SERVER_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/variant/string.hpp>

#include <memory>
#include <string>

namespace godot {

// DidiServer hosts an HTTP-based Model Context Protocol (MCP) server inside the
// Godot runtime, backed by the fastmcpp library. The transport is fastmcpp's
// Streamable HTTP server (MCP spec 2025-03-26), exposed on a single POST
// endpoint (default: http://127.0.0.1:8900/mcp).
//
// The server runs on its own background thread (start() is non-blocking), so it
// integrates cleanly with Godot's main loop. All fastmcpp types are hidden
// behind a pimpl so the library's heavy headers (cpp-httplib, nlohmann/json)
// never leak into this GDExtension header.
class DidiServer : public Node {
    GDCLASS(DidiServer, Node)

private:
    struct Impl;
    std::unique_ptr<Impl> impl;

    int port = 8900;
    String bind_address = "127.0.0.1";
    bool autostart = true;

    void register_tools();

    // Loads the markdown authoring guide from res:// into the Impl cache.
    // Must be called on the main thread (uses Godot's FileAccess).
    void load_guide();

    // Runs an AI-provided GDScript source on the main thread and returns its
    // result as a string. Called only from _process (main thread).
    std::string execute_gdscript(const std::string &user_source);
    // Captures the editor (whole window, or the 2D/3D scene viewport) to a PNG.
    // Must run on the main thread (Godot viewport/image APIs are not thread-safe).
    std::string capture_screenshot(const String &path, const String &target);
    // Drains pending run_gdscript requests and main-thread tasks (e.g. screenshots).
    void drain_script_queue();

protected:
    static void _bind_methods();

public:
    DidiServer();
    ~DidiServer();

    void _ready() override;
    void _process(double delta) override;
    void _exit_tree() override;

    // Configuration (exposed to the editor / GDScript as properties).
    void set_port(int p_port);
    int get_port() const;
    void set_bind_address(const String &p_address);
    String get_bind_address() const;
    void set_autostart(bool p_autostart);
    bool get_autostart() const;

    // Lifecycle.
    bool start_server();
    void stop_server();
    bool is_running() const;
};

} // namespace godot

#endif // DIDI_SERVER_H
