cmake_minimum_required(VERSION 3.22)

project(didi LANGUAGES CXX)

# Didi is an editor-only helper, so default godot-cpp's build target to
# `editor`. This produces an `.editor` library that loads while editing the
# project but is excluded from exported games (which match template_debug /
# template_release). Override with -DGODOTCPP_TARGET=template_release if you
# ever need a runtime build. Must be set before add_subdirectory(godot-cpp).
if(NOT DEFINED GODOTCPP_TARGET)
    set(GODOTCPP_TARGET "editor" CACHE STRING "godot-cpp build target" FORCE)
endif()

# godot-cpp ships a CMake build that produces the `godot-cpp` target.
add_subdirectory(godot-cpp)

# fastmcpp provides the MCP server implementation (target: fastmcpp_core).
# It fetches nlohmann/json and cpp-httplib via FetchContent at configure time.
# Disable its tests/examples so we don't pull in GoogleTest or build extras.
set(FASTMCPP_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(FASTMCPP_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
add_subdirectory(fastmcpp)

file(GLOB_RECURSE DIDI_SOURCES CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.cpp"
    "${CMAKE_CURRENT_SOURCE_DIR}/src/*.h"
)

add_library(didi SHARED ${DIDI_SOURCES})

target_include_directories(didi PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/src")
target_link_libraries(didi PRIVATE godot-cpp fastmcpp_core)

# --- Derive the godot-cpp-style library suffix at configure time ---------
# e.g. ".windows.template_debug.x86_64". We deliberately reconstruct this
# instead of reusing the godot-cpp target's GODOTCPP_SUFFIX property: that
# property stores unevaluated generator expressions, which leak verbatim into
# the filename if referenced from here. These values mirror SCons' defaults so
# both build systems emit identical names (matching demo/didi.gdextension).
if(CMAKE_SYSTEM_NAME STREQUAL "Windows")
    set(_didi_platform "windows")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    set(_didi_platform "linux")
elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
    set(_didi_platform "macos")
else()
    string(TOLOWER "${CMAKE_SYSTEM_NAME}" _didi_platform)
endif()

# template_debug / template_release / editor — defined by godot-cpp (cache var).
set(_didi_target "${GODOTCPP_TARGET}")

if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|amd64")
    set(_didi_arch "x86_64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "aarch64|arm64|ARM64")
    set(_didi_arch "arm64")
elseif(CMAKE_SYSTEM_PROCESSOR MATCHES "i686|x86|X86")
    set(_didi_arch "x86_32")
else()
    string(TOLOWER "${CMAKE_SYSTEM_PROCESSOR}" _didi_arch)
endif()

set(DIDI_LIB_SUFFIX ".${_didi_platform}.${_didi_target}.${_didi_arch}")

# The demo's addon directory is assembled entirely by the build: the compiled
# library (below) plus the static addon files copied from the repo-root
# addons/didi source (the canonical, tracked copies). demo/addons/didi is
# therefore generated output and git-ignored.
set(DIDI_ADDON_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/addons/didi")
set(DIDI_OUTPUT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/demo/addons/didi")

set_target_properties(didi PROPERTIES
    CXX_STANDARD 17
    CXX_STANDARD_REQUIRED ON

    # Install built libraries straight into the demo project. The $<1:...>
    # generator expression stops the MSVC generator from appending a
    # per-config subdirectory (e.g. Debug/) to the output path.
    LIBRARY_OUTPUT_DIRECTORY "$<1:${DIDI_OUTPUT_DIR}>"
    RUNTIME_OUTPUT_DIRECTORY "$<1:${DIDI_OUTPUT_DIR}>"
    PDB_OUTPUT_DIRECTORY     "$<1:${DIDI_OUTPUT_DIR}>"

    # Produce e.g. libdidi.windows.template_debug.x86_64.dll to match
    # demo/didi.gdextension.
    PREFIX "lib"
    OUTPUT_NAME "didi${DIDI_LIB_SUFFIX}"
)

# godot-cpp's CMake build (unlike its SCons build) does not define TOOLS_ENABLED
# for the editor target, so define it ourselves. This gates the DidiEditorPlugin
# and its registration to editor builds only.
if(_didi_target STREQUAL "editor")
    target_compile_definitions(didi PRIVATE TOOLS_ENABLED)
endif()

# Populate demo/addons/didi with the static addon files (the .gdextension that
# tells Godot how to load the library, its .uid, and the GDScript guide served
# as an MCP resource from res://addons/didi/didi_gdscript_guide.md). Runs after
# every build of `didi`, so the demo addon is always complete and current.
add_custom_command(TARGET didi POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${DIDI_OUTPUT_DIR}"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${DIDI_ADDON_SRC_DIR}/didi.gdextension"
        "${DIDI_ADDON_SRC_DIR}/didi.gdextension.uid"
        "${DIDI_ADDON_SRC_DIR}/didi_gdscript_guide.md"
        "${DIDI_OUTPUT_DIR}/"
    COMMENT "Copying static addon files into demo/addons/didi"
    VERBATIM
)

# macOS ships GDExtensions as .framework bundles.
if(CMAKE_SYSTEM_NAME STREQUAL Darwin)
    set_target_properties(didi PROPERTIES
        SUFFIX ""
        LIBRARY_OUTPUT_DIRECTORY "$<1:${DIDI_OUTPUT_DIR}/libdidi.macos.${_didi_target}.framework>"
        RUNTIME_OUTPUT_DIRECTORY "$<1:${DIDI_OUTPUT_DIR}/libdidi.macos.${_didi_target}.framework>"
    )
endif()
