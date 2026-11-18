// Cobalt Shift - a frozen race grid and live switches, for A/B measurements
//
// Ported from FM3-ReGPU (MIT, src/hooks/grid_test.cpp and frame_time.cpp;
// THIRD_PARTY_NOTICES.md), same default.xex.
//
// --cobalt_freeze_grid_at=<s> stops the world on the start grid when the race
// start sequence's clock reaches <s> during the car intro. FM3-ReGPU timed it
// against a video of the countdown: the clock restarts at 0 when the intro
// starts, "3" shows at about 6.7 s, "2" at 7.7, "1" with the chase camera
// settled at 8.6, GO at 9.5. 9.0 is mid-"1": the AI cars on their grid spots,
// nothing moving yet. The game keeps drawing every frame, so the frames repeat
// the same scene (draw calls per frame within ±0.7 % on the Ladera grid).
//
// --cobalt_freeze_time stops (true) or releases (false) the world anywhere. It
// reloads live, so a line "cobalt_freeze_time false" in the live file lets a
// frozen race go on.
//
// --cobalt_live_file=<path>: a text file polled about twice a second and
// deleted once read. Each line "<cvar> <value>" is applied with
// rex::cvar::SetFlagByName and logged; only cvars that reload live
// (Lifecycle::kHotReload) take effect at once. tools/bench_ab.ps1 writes it.
//
// sub_821F6AF8 answers whether the main loop's frame time is the game's own;
// it has set f31 (dt in seconds) and r3 when it returns to the main loop's
// call at 0x821F6004 (sub_821F5DE8). dt 0 stops everything the main loop
// steps with it (cars, cameras, countdown, clocks).
//
// sub_822E6AD0(this, dt) updates the race start sequence: phase byte +4,
// flags +24..+26 (+25 set once Start Race is taken, +26 at GO), its clock a
// double at +16.

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#include <rex/types.h>
#include <rex/cvar.h>
#include <rex/logging/macros.h>
#include <rex/ppc/context.h>
#include <rex/ppc/func.h>

REXCVAR_DEFINE_DOUBLE(cobalt_freeze_grid_at, 0.0, "Cobalt",
                      "Stop the world on the start grid at this many seconds of the race "
                      "start clock (9.0: the countdown's \"1\"); 0 off")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

REXCVAR_DEFINE_BOOL(cobalt_freeze_time, false, "Cobalt",
                    "Stop the world (the main loop's frame time 0) while drawing goes on")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

REXCVAR_DEFINE_STRING(cobalt_live_file, "", "Cobalt",
                      "Text file of \"<cvar> <value>\" lines, polled and deleted once read "
                      "(live A/B switches)")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

namespace {

constexpr uint32_t kFrameTimeCallReturn = 0x821F6004;

std::atomic<bool> g_grid_frozen{false};
uint64_t g_main_frames = 0;

void PollLiveFile() {
  using Clock = std::chrono::steady_clock;
  static const std::string path = REXCVAR_GET(cobalt_live_file);
  if (path.empty()) return;
  static Clock::time_point next{};
  const auto now = Clock::now();
  if (now < next) return;
  next = now + std::chrono::milliseconds(500);
  std::error_code ec;
  if (!std::filesystem::exists(path, ec)) return;
  std::ifstream in(path);
  std::string line;
  while (std::getline(in, line)) {
    std::istringstream words(line);
    std::string name, value;
    if (!(words >> name) || name[0] == '#') continue;
    std::getline(words >> std::ws, value);
    while (!value.empty() && (value.back() == '\r' || value.back() == ' ')) value.pop_back();
    const bool applied = rex::cvar::SetFlagByName(name, value);
    REXLOG_INFO("live: {} = {} ({}, main frame {})", name, value,
                applied ? "applied" : "rejected", g_main_frames);
  }
  in.close();
  std::filesystem::remove(path, ec);
}

double LoadBEDouble(const uint8_t* p) {
  uint64_t bits;
  std::memcpy(&bits, p, sizeof(bits));
  bits = rex::byte_swap(bits);
  double d;
  std::memcpy(&d, &bits, sizeof(d));
  return d;
}

}  // namespace

extern "C" REX_FUNC(__imp__sub_821F6AF8);
extern "C" REX_FUNC(sub_821F6AF8) {
  const bool main_loop = ctx.lr == kFrameTimeCallReturn;
  __imp__sub_821F6AF8(ctx, base);
  if (!main_loop) return;
  ++g_main_frames;
  PollLiveFile();
  // Releasing the switch releases the grid's freeze too.
  static bool switch_was_on = false;
  const bool switch_on = REXCVAR_GET(cobalt_freeze_time);
  if (switch_was_on && !switch_on) g_grid_frozen.store(false, std::memory_order_relaxed);
  switch_was_on = switch_on;
  const bool frozen = switch_on || g_grid_frozen.load(std::memory_order_relaxed);
  static bool was_frozen = false;
  if (frozen != was_frozen) {
    was_frozen = frozen;
    REXLOG_INFO("[freeze] world {} at main frame {}", frozen ? "frozen (dt 0)" : "running again",
                g_main_frames);
  }
  if (frozen) {
    ctx.f31.f64 = 0.0;
    ctx.r3.u64 = 1;
  }
}

extern "C" REX_FUNC(__imp__sub_822E6AD0);
extern "C" REX_FUNC(sub_822E6AD0) {
  // The sequence object is a heap object: no physical-range offset.
  const uint32_t self = ctx.r3.u32;
  __imp__sub_822E6AD0(ctx, base);
  const uint8_t* p = base + self;
  const uint8_t f24 = p[24], f25 = p[25], f26 = p[26];
  const double clock = LoadBEDouble(p + 16);
  static uint32_t last_key = 0xFFFFFFFF;
  const uint32_t key = uint32_t(p[4]) << 24 | uint32_t(f24) << 16 | uint32_t(f25) << 8 | f26;
  if (key != last_key) {
    last_key = key;
    REXLOG_INFO("[freeze] race start {:08X} phase {} flags {} {} {}, clock {:.3f} s", self,
                key >> 24, f24, f25, f26, clock);
  }
  static bool done = false;
  const double at = REXCVAR_GET(cobalt_freeze_grid_at);
  if (at <= 0.0) return;
  if (f26) done = false;  // GO: a later race freezes again
  if (!done && !f24 && f25 && !f26 && clock >= at) {
    done = true;
    g_grid_frozen.store(true, std::memory_order_relaxed);
    REXLOG_INFO("[freeze] frozen on the grid at {:.3f} s of the race start clock", clock);
  }
}
