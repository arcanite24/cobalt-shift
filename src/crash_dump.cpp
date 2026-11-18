// Cobalt Shift - a minidump when the process crashes
//
// A fault nothing handles (the SDK's vectored handler takes only the guest
// memory faults it knows) writes <user data root>/crash-<time>.dmp with the
// threads' stacks and the module list, then lets Windows end the process as
// before. tools/read_dump.py reads the faulting thread from it. It is
// installed at the first app hook, before the GPU device exists, writing next
// to the executable until the user data folder is known.
// --cobalt_crash_test=true checks it. It caught the NVIDIA driver's fault on
// blindvac at startup (docs/BASELINE.md, "The NVIDIA 930MX on blindvac").

#include "crash_dump.h"

#ifdef _WIN32
#include <windows.h>
#include <dbghelp.h>
#pragma comment(lib, "dbghelp.lib")

#include <atomic>
#include <ctime>
#include <string>

#include <rex/cvar.h>
#include <rex/logging/macros.h>

REXCVAR_DEFINE_BOOL(cobalt_crash_dump, true, "Cobalt",
                    "Write a minidump to the user data folder when the process crashes")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

REXCVAR_DEFINE_BOOL(cobalt_crash_test, false, "Cobalt",
                    "Crash on purpose once the image is loaded, to check the minidump")
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
  if (folder.empty()) {
    // Before the user data folder is known: next to the executable.
    wchar_t exe[MAX_PATH];
    const DWORD length = GetModuleFileNameW(nullptr, exe, MAX_PATH);
    g_folder = std::filesystem::path(std::wstring(exe, length)).parent_path().wstring();
  } else {
    g_folder = folder.wstring();
  }
  SetUnhandledExceptionFilter(WriteDump);
  if (REXCVAR_GET(cobalt_crash_test) && !folder.empty()) {
    REXLOG_WARN("crash dump: crashing on purpose (cobalt_crash_test)");
    *static_cast<volatile int*>(nullptr) = 1;
  }
}

}  // namespace cobalt

#else

namespace cobalt {
void InstallCrashDump(const std::filesystem::path&) {}
}  // namespace cobalt

#endif
