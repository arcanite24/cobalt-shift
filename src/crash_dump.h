// Cobalt Shift - a minidump when the process crashes (src/crash_dump.cpp)

#pragma once

#include <filesystem>

namespace cobalt {

// Writes <folder>/crash-<time>.dmp on an unhandled fault (cobalt_crash_dump).
void InstallCrashDump(const std::filesystem::path& folder);

}  // namespace cobalt
