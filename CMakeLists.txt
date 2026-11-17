# Cobalt Shift - Forza Motorsport 3 (Xbox 360) on ShiftGlue
#
# Stage 0 reference build: the SDK's project template, with the boilerplate
# in cmake/rexglue.cmake (carried from Lavender Shift).

cmake_minimum_required(VERSION 3.25)
project(cobalt_shift LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Stage 0 is a measuring build (--perf_log_csv), as Pinyon and Lavender's are.
option(COBALT_SHIFT_PERF_COUNTERS "Compile ShiftGlue's per-frame perf counters" ON)
if(COBALT_SHIFT_PERF_COUNTERS)
    add_compile_definitions(REXGLUE_ENABLE_PERF_COUNTERS)
endif()

include(cmake/rexglue.cmake)

set(COBALT_SHIFT_SOURCES
    src/main.cpp
    src/utility_drive.cpp
    src/pad_script.cpp
    src/ring_wait.cpp
)

if(WIN32)
    add_executable(cobalt_shift WIN32 ${COBALT_SHIFT_SOURCES})
else()
    add_executable(cobalt_shift ${COBALT_SHIFT_SOURCES})
endif()

target_include_directories(cobalt_shift PRIVATE "${COBALT_SHIFT_SDK_SOURCE_DIR}/thirdparty/imgui"
    "${CMAKE_CURRENT_SOURCE_DIR}/src")
if(REXSDK_DIR)
    set_property(SOURCE "${REXGLUE_SHARE_DIR}/rex_app.cpp" APPEND PROPERTY
        INCLUDE_DIRECTORIES "${CMAKE_CURRENT_BINARY_DIR}/rexglue-sdk/include")
endif()

# rexgpu-fh1 is ShiftGlue's Xenos (PM4) GPU plugin: the Stage 0 path.
rexglue_setup_target(cobalt_shift GPU_PLUGINS fh1)
