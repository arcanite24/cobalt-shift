// Cobalt Shift - a minidump when the process crashes
//
// A fault nothing handles (the SDK's vectored handler takes only the guest
// memory faults it knows) writes <user data root>/crash-<time>.dmp with the
// threads' stacks and the module list, then lets Windows end the process as
// before. tools/read_dump.py reads the faulting thread from it. Added for an
// access violation inside the Intel Vulkan driver on blindvac
// (docs/BASELINE.md, "An intermittent Intel driver fault on blindvac").

#include "crash_dump.h"

#ifdef _WIN32
#include <windows.h>
#include <dbghelp.h>
#pragma comment(lib, "dbghelp.lib")

#include <atomic>
#include <ctime>
#include <string>

#include <rex/cvar.h>

REXCVAR_DEFINE_BOOL(cobalt_crash_dump, true, "Cobalt",
                    "Write a minidump to the user data folder when the process crashes")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

namespace {

std::wstring g_folder;

LONG WINAPI WriteDump(EXCEPTION_POINTERS* info) {
  static std::atomic<bool> once{false};
  if (once.exchange(true)) return EXCEPTION_CONTINUE_SEARCH;
  wchar_t name[64];
  const std::time_t now = std::time(nullptr);
  std::tm local{};
  localtime_s(&local, &now);
  wcsftime(name, 64, L"\\crash-%Y%m%d-%H%M%S.dmp", &local);
  const std::wstring path = g_folder + name;
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                            FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    MINIDUMP_EXCEPTION_INFORMATION exception{GetCurrentThreadId(), info, FALSE};
    MiniDumpWriteDump(GetCurrentProcess(), GetCurrentProcessId(), file,
                      MINIDUMP_TYPE(MiniDumpNormal | MiniDumpWithThreadInfo |
                                    MiniDumpWithUnloadedModules),
                      &exception, nullptr, nullptr);
    CloseHandle(file);
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace

namespace cobalt {

void InstallCrashDump(const std::filesystem::path& folder) {
  if (!REXCVAR_GET(cobalt_crash_dump)) return;
  g_folder = folder.wstring();
  SetUnhandledExceptionFilter(WriteDump);
}

}  // namespace cobalt

#else

namespace cobalt {
void InstallCrashDump(const std::filesystem::path&) {}
}  // namespace cobalt

#endif
