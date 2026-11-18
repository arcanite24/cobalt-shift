# From `rexglue init` (ShiftGlue 101ad468), edited: output under .local/generated,
# and codegen applies the title-update patches (--xex_apply_patches=true).

# Android (docs/ANDROID.md), as in Pinyon Shift: every handheld the build
# targets is ARMv8.2 or later, so atomics compile to LSE instructions, in the
# SDK and its libraries too. Every library in the package is position
# independent, and the 0xE0000000 physical view assumes 4 KB pages (a 16 KB
# page kernel refuses the build at start instead of paying a run-time offset
# on every access).
if(ANDROID)
    set(CMAKE_POSITION_INDEPENDENT_CODE ON)
    set(COBALT_SHIFT_ANDROID_MARCH "armv8.2-a" CACHE STRING
        "-march for every Android target, the SDK and its libraries included")
    add_compile_options(-march=${COBALT_SHIFT_ANDROID_MARCH})
    set(REXGLUE_ARM64_MARCH ${COBALT_SHIFT_ANDROID_MARCH})
    option(COBALT_SHIFT_PHYSICAL_HEAP_4K_PAGES
        "Assume 4 KB memory pages: no run-time host offset on 0xE0000000 guest accesses" ON)
    if(COBALT_SHIFT_PHYSICAL_HEAP_4K_PAGES)
        add_compile_definitions(REX_PHYSICAL_HEAP_4K_PAGES=1)
    endif()
endif()

# SDK version
# Set REXSDK_VERSION to pin a specific SDK version.
# Otherwise, the version of the SDK that generated this file is used.
set(REXSDK_VERSION "" CACHE STRING "Override SDK version (leave empty for default)")

# Find SDK
set(REXSDK_DIR "" CACHE PATH "Path to rexglue-sdk source tree")
set(COBALT_SHIFT_SHIFTGLUE_KIT "" CACHE PATH "Unpacked prebuilt ShiftGlue kit")
if(REXSDK_DIR)
    add_subdirectory("${REXSDK_DIR}" rexglue-sdk)
    # Calls inside the runtime libraries bind locally instead of through the
    # PLT, as libmain's do (Pinyon Shift's NN-3.6).
    if(ANDROID)
        foreach(_cobalt_runtime IN ITEMS rexruntime rexgpu-fh1)
            if(TARGET ${_cobalt_runtime})
                target_link_options(${_cobalt_runtime} PRIVATE -Wl,-Bsymbolic-functions)
            endif()
        endforeach()
    endif()
    message(STATUS "Using ReXGlue SDK from source tree: ${REXSDK_DIR}")
    set(COBALT_SHIFT_SDK_SOURCE_DIR "${REXSDK_DIR}")
elseif(COBALT_SHIFT_SHIFTGLUE_KIT)
    # RL-10 (docs/RELEASE_BACKLOG.md): the prebuilt ShiftGlue kit
    # (tools/build-shiftglue-kit.ps1) instead of the source tree, as in Pinyon
    # Shift. It holds the generator, the runtime and graphics backend with
    # their CMake package, and the few SDK headers the game compiles against.
    # It must be built from the pinned ShiftGlue revision.
    if(NOT EXISTS "${COBALT_SHIFT_SHIFTGLUE_KIT}/kit.json")
        message(FATAL_ERROR "${COBALT_SHIFT_SHIFTGLUE_KIT} is not an unpacked ShiftGlue kit.")
    endif()
    file(READ "${COBALT_SHIFT_SHIFTGLUE_KIT}/kit.json" _cobalt_kit)
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/config/release-toolchain.json" _cobalt_toolchain)
    string(JSON _cobalt_kit_revision GET "${_cobalt_kit}" shiftglue_revision)
    string(JSON _cobalt_pinned_revision GET "${_cobalt_toolchain}" rexglue revision)
    if(NOT _cobalt_kit_revision STREQUAL _cobalt_pinned_revision)
        message(FATAL_ERROR
            "The ShiftGlue kit was built from ${_cobalt_kit_revision}, but "
            "config/release-toolchain.json pins ${_cobalt_pinned_revision}.")
    endif()
    set_property(DIRECTORY "${PROJECT_SOURCE_DIR}" APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
        "${COBALT_SHIFT_SHIFTGLUE_KIT}/kit.json")
    # The kit is on the build host: a cross toolchain's sysroot (the NDK, for
    # the Android shell) would otherwise re-root the search under itself, for
    # the kit and for the dependencies its package finds through its prefix.
    set(_cobalt_find_root_mode "${CMAKE_FIND_ROOT_PATH_MODE_PACKAGE}")
    set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)
    find_package(rexglue CONFIG REQUIRED NO_DEFAULT_PATH NO_CMAKE_FIND_ROOT_PATH
        PATHS "${COBALT_SHIFT_SHIFTGLUE_KIT}")
    set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE "${_cobalt_find_root_mode}")
    set(COBALT_SHIFT_SDK_SOURCE_DIR "${COBALT_SHIFT_SHIFTGLUE_KIT}/share/rexglue/source")
    # The upscaler runtimes are vendor binaries no release ships
    # (docs/LEGAL.md): the kit's copies of the SDK's fetch modules download
    # them here, pinned and hashed, as a source build does.
    foreach(_cobalt_module IN ITEMS rexglue_ffx_api_headers rexglue_dlss)
        set(_cobalt_module "${COBALT_SHIFT_SHIFTGLUE_KIT}/share/rexglue/cmake/${_cobalt_module}.cmake")
        if(WIN32 AND EXISTS "${_cobalt_module}")
            include("${_cobalt_module}")
        endif()
    endforeach()
    if(REXGLUE_FFX_RUNTIME_DLL)
        set(REXGLUE_FFX_LICENSE "${COBALT_SHIFT_SHIFTGLUE_KIT}/share/rexglue/upscalers/fidelityfx/LICENSE.txt")
    endif()
    message(STATUS "Using the prebuilt ShiftGlue kit: ${COBALT_SHIFT_SHIFTGLUE_KIT}")
else()
    if(REXSDK_VERSION)
        find_package(rexglue ${REXSDK_VERSION} EXACT QUIET CONFIG)
    else()
        find_package(rexglue 0.10.0 QUIET CONFIG)
    endif()
    if(NOT rexglue_FOUND)
        message(FATAL_ERROR
            "ReXGlue SDK not found. Either:\n"
            "  - Set REXSDK_DIR to the rexglue-sdk source tree (e.g. thirdparty/rexglue-sdk)\n"
            "  - Install the SDK package and ensure it is on CMAKE_PREFIX_PATH")
    endif()
    message(STATUS "Found ReXGlue SDK ${REXGLUE_VERSION_STRING} at ${rexglue_DIR}")
endif()

# Host target name used by the codegen-emitted dll_targets.cmake to colocate
# guest DLLs with the host EXE. Defaults to PROJECT_NAME (which the
# manifest-first init flow sets equal to the host target name).
if(NOT DEFINED REXGLUE_HOST_TARGET)
    set(REXGLUE_HOST_TARGET ${PROJECT_NAME})
endif()

set(REXGLUE_RECOMP_DEBUG_INFO "line-tables-only" CACHE STRING
    "Debug info level for generated code: line-tables-only, full, or none")

# Guest SEH scopes emit __try/__except, which traps hardware faults only under
# asynchronous EH. clang++ spells that flag the GNU way. Codegen emits no SEH
# scope for FH2 (generate_exception_handlers is off), so the flag is opt-in,
# as in Pinyon Shift. Generated units also get -fno-strict-aliasing, as the
# SDK's own sources do: guest memory is read through casts of byte pointers.
option(LAVENDER_RECOMP_SEH
    "Compile the generated units for asynchronous (SEH) exceptions" OFF)
set(REXGLUE_RECOMP_OPTIONS "")
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang|GNU")
    list(APPEND REXGLUE_RECOMP_OPTIONS -fno-strict-aliasing)
endif()
# CB-1: clang++ targeting MSVC turns on -fms-volatile, which gives every guest
# load and store (all volatile) acquire/release semantics, so the PPC context
# is kept in memory around each one. Measured A/B only for now; RESEARCH.md's
# order stands: compiler barriers for the PPC barriers first, then this off
# by default.
option(COBALT_SHIFT_MS_VOLATILE
    "Compile the generated units with MSVC volatile semantics (clang's Windows default)" OFF)
if(WIN32 AND CMAKE_CXX_COMPILER_ID MATCHES "Clang" AND NOT MSVC AND NOT COBALT_SHIFT_MS_VOLATILE)
    list(APPEND REXGLUE_RECOMP_OPTIONS -fno-ms-volatile -DREX_PPC_COMPILER_BARRIERS)
    # CB-1 step 3: relaxed atomic guest accesses (docs/BASELINE.md).
    option(COBALT_SHIFT_RELAXED_GUEST_ACCESS
        "Guest loads and stores as relaxed atomics instead of volatile accesses" ON)
    if(COBALT_SHIFT_RELAXED_GUEST_ACCESS)
        list(APPEND REXGLUE_RECOMP_OPTIONS -DREX_RELAXED_GUEST_ACCESS)
    endif()
endif()
# Extra flags for the generated units only, for A/B builds in a second folder.
set(COBALT_SHIFT_RECOMP_EXTRA_FLAGS "" CACHE STRING
    "Extra compiler flags for the generated units (A/B builds)")
if(COBALT_SHIFT_RECOMP_EXTRA_FLAGS)
    separate_arguments(_cobalt_extra NATIVE_COMMAND "${COBALT_SHIFT_RECOMP_EXTRA_FLAGS}")
    list(APPEND REXGLUE_RECOMP_OPTIONS ${_cobalt_extra})
endif()
if(WIN32 AND LAVENDER_RECOMP_SEH)
    if(MSVC)
        list(APPEND REXGLUE_RECOMP_OPTIONS /EHa)
    elseif(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        list(APPEND REXGLUE_RECOMP_OPTIONS -fasync-exceptions)
    endif()
endif()
if(REXGLUE_RECOMP_DEBUG_INFO STREQUAL "none")
    list(APPEND REXGLUE_RECOMP_OPTIONS
        $<$<CXX_COMPILER_ID:Clang,AppleClang,GNU>:-g0>)
elseif(REXGLUE_RECOMP_DEBUG_INFO STREQUAL "line-tables-only")
    list(APPEND REXGLUE_RECOMP_OPTIONS
        $<$<CXX_COMPILER_ID:Clang,AppleClang>:-gline-tables-only>)
endif()

# Include entrypoint generated code if codegen has been run.
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.local/generated/default/sources.cmake")
    include(.local/generated/default/sources.cmake)
    set(REXGLUE_ENTRYPOINT_GENERATED_SOURCES ${GENERATED_SOURCES})
    set(REXGLUE_ENTRYPOINT_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/.local/generated/default")

    # Carried on the sources so they hold for whichever target compiles them.
    set_source_files_properties(${REXGLUE_ENTRYPOINT_GENERATED_SOURCES}
        PROPERTIES COMPILE_OPTIONS "${REXGLUE_RECOMP_OPTIONS}")
endif()

# The options go on the target as well: CMake compiles the header from its own
# cmake_pch.hxx.cxx, which carries none of the source properties above, and
# clang rejects a PCH whose EH mode disagrees with the TU including it.
function(rexglue_apply_recomp_settings target_name pch_header)
    target_precompile_headers(${target_name} PRIVATE "${pch_header}")
    target_compile_options(${target_name} PRIVATE ${REXGLUE_RECOMP_OPTIONS})
endfunction()

# Configure a rexglue target with SDK libraries and platform settings.
# Call after add_executable() in your CMakeLists.txt.
# Usage: rexglue_setup_target(<target> [GPU_PLUGINS fh1])
macro(rexglue_setup_target target_name)
    if(REXGLUE_ENTRYPOINT_GENERATED_SOURCES)
        add_library(${target_name}_recomp OBJECT
            ${REXGLUE_ENTRYPOINT_GENERATED_SOURCES})
        target_include_directories(${target_name}_recomp PRIVATE
            ${CMAKE_CURRENT_SOURCE_DIR}
            ${CMAKE_CURRENT_SOURCE_DIR}/src
            ${REXGLUE_ENTRYPOINT_INCLUDE_DIR}
        )
        target_link_libraries(${target_name}_recomp PRIVATE rex::runtime)
        rexglue_apply_target_settings(${target_name}_recomp)
        rexglue_apply_recomp_settings(${target_name}_recomp
            "${REXGLUE_ENTRYPOINT_INCLUDE_DIR}/cobalt_shift_pch.h")
        add_dependencies(${target_name}_recomp cobalt_shift_codegen)
        target_link_libraries(${target_name} PRIVATE
            ${target_name}_recomp)
    endif()
    # Also on the host, so a tree that has never run codegen still generates it.
    add_dependencies(${target_name} cobalt_shift_codegen)
    target_include_directories(${target_name} PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}
        ${CMAKE_CURRENT_SOURCE_DIR}/src
        ${REXGLUE_ENTRYPOINT_INCLUDE_DIR}
    )
    target_link_libraries(${target_name} PRIVATE rex::runtime)
    if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/metadata/icons")
        rexglue_embed_metadata(${target_name}
            DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/metadata/icons"
            PREFIX "icons")
    endif()
    rexglue_configure_target(${target_name} ${ARGN})
endmacro()

# A cross build (Android) runs the generator built for this PC: the SDK's
# standalone build (out/<os>-<arch>/Release), which the PC build made.
set(COBALT_SHIFT_CODEGEN "$<TARGET_FILE:rex::rexglue>")
if(CMAKE_CROSSCOMPILING)
    if(CMAKE_HOST_WIN32)
        set(_cobalt_host_os win)
    elseif(CMAKE_HOST_APPLE)
        set(_cobalt_host_os mac)
    else()
        set(_cobalt_host_os linux)
    endif()
    if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
        set(_cobalt_host_arch amd64)
    else()
        set(_cobalt_host_arch arm64)
    endif()
    set(COBALT_SHIFT_HOST_CODEGEN
        "${REXSDK_DIR}/out/${_cobalt_host_os}-${_cobalt_host_arch}/Release/rexglue${CMAKE_HOST_EXECUTABLE_SUFFIX}"
        CACHE FILEPATH "The ReXGlue generator built for the build host")
    if(NOT EXISTS "${COBALT_SHIFT_HOST_CODEGEN}")
        message(FATAL_ERROR "The host generator is missing: ${COBALT_SHIFT_HOST_CODEGEN}. "
            "Build the game on this PC first (tools/build.ps1).")
    endif()
    set(COBALT_SHIFT_CODEGEN "${COBALT_SHIFT_HOST_CODEGEN}")
endif()

# Codegen runs as part of the build, re-running only when an input in codegen.d
# changes. Build it alone with 'cmake --build . --target cobalt_shift_codegen'.
# Listing the sources as outputs orders any target that compiles them after
# codegen, including one a project assembles itself rather than taking the
# library rexglue_setup_target() builds. The stamp comes first: the DEPFILE
# names it.
add_custom_command(
    OUTPUT "${CMAKE_CURRENT_SOURCE_DIR}/.local/generated/default/codegen.build.stamp"
           ${REXGLUE_ENTRYPOINT_GENERATED_SOURCES}
    COMMAND ${COBALT_SHIFT_CODEGEN} codegen ${CMAKE_CURRENT_SOURCE_DIR}/cobalt_shift_manifest.toml
    DEPFILE "${CMAKE_CURRENT_SOURCE_DIR}/.local/generated/default/codegen.d"
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    COMMENT "Generating recompiled code for cobalt_shift"
    VERBATIM
)
add_custom_target(cobalt_shift_codegen
    DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/.local/generated/default/codegen.build.stamp")

# Include DLL module shared library targets if codegen has generated them
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/.local/generated/default/dll_targets.cmake")
    include(.local/generated/default/dll_targets.cmake)
endif()
