// Cobalt Shift - FM3 scene size (#23)
//
// FH1 renders its race scene in bands described by static "tiling scenario"
// records: {width, height, MSAA mode, tile count, ..., one {left, top, right,
// bottom} rect a tile}. Pinyon Shift scales those rects to render the scene
// smaller (pinyon_shift_fh1_scene_size); the SDK then rewrites the window
// offset and scissor the static command lists carry for the 720p bands
// (CommandProcessor::set_fh1_scene_size). FM3 shares FH1's engine, so this
// looks for the same records first.
//
// cobalt_scene_probe logs every 1280x720 pair in the image followed by
// small values, to find FM3's records and their layout.

#include "scene_size.h"

#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <iterator>
#include <string>
#include <thread>
#include <mutex>
#include <set>
#include <tuple>
#include <chrono>

#include <fmt/format.h>

#include <rex/cvar.h>
#include <rex/logging/macros.h>
#include <rex/ppc/context.h>
#include <rex/ppc/func.h>
#include <rex/runtime.h>
#include <rex/system/interfaces/graphics.h>
#include <rex/system/kernel_state.h>
#include <rex/system/xmemory.h>

REXCVAR_DEFINE_BOOL(cobalt_scene_probe, false, "Cobalt",
                    "Diagnostic: log the image's 1280x720 records that look like tiling "
                    "scenarios (#23)")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

REXCVAR_DEFINE_STRING(cobalt_scene_size, "", "Cobalt",
                      "Experimental (#23): render the race scene at <width>x<height> (width in "
                      "steps of 80, height in steps of 45, at most 1280x720) by scaling FM3's "
                      "tiling bands, as Pinyon Shift does for FH1")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

REXCVAR_DEFINE_INT32(cobalt_scene_keep_mask, 0, "Cobalt",
                     "Diagnostic (#23): screen texture headers left at 720p with "
                     "cobalt_scene_size, one bit a header (+56, +160, +480, +532, +584, +636)")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

namespace cobalt {

uint32_t g_scene_width = 0;
uint32_t g_scene_height = 0;

namespace {

// FM3's tiling scenarios, as in FH1: records 1232 bytes apart, a vtable, the
// screen width and height, the MSAA mode (0 1x, 1 2x, 2 4x), the tile count,
// two words, a zero and one {left, top, right, bottom} rect a tile. Found at
// 0x82BF60D4 (UC default.xex): 4x in three bands of 256, 256 and 208 rows,
// 2x (the race) in two of 512 and 208, 1x in one.
void ResizeScene(rex::memory::Memory* memory) {
  const std::string& size = REXCVAR_GET(cobalt_scene_size);
  uint32_t width = 0, height = 0;
  if (size.empty() || std::sscanf(size.c_str(), "%ux%u", &width, &height) != 2) return;
  if (!width || !height || width > 1280 || height > 720 || width % 80 || height % 45) {
    REXLOG_WARN("[scene] scene size {} needs a width in steps of 80 and a height in steps of 45, "
                "at most 1280x720; unchanged",
                size);
    return;
  }
  static constexpr uint32_t kRecord[] = {1280, 720, 2, 3, 1, 3, 0, 0, 0, 1280, 256,
                                         0, 256, 1280, 512, 0, 512, 1280, 720};
  constexpr uint32_t kStride = 1232;
  uint32_t found = 0;
  for (uint32_t address : {0x82BF60D4u}) {
    const auto* words = memory->TranslateVirtual<const uint32_t*>(address);
    bool match = true;
    for (size_t i = 0; i < std::size(kRecord) && match; ++i) {
      match = rex::byte_swap(words[i]) == kRecord[i];
    }
    if (match) found = address;
  }
  if (!found) {
    REXLOG_WARN("[scene] tiling scenarios not at 0x82BF60D4 (another default.xex?); unchanged");
    return;
  }
  auto* graphics = rex::system::kernel_state()->emulator()->graphics_system();
  if (!graphics) return;
  for (uint32_t record = 0; record < 3; ++record) {
    auto* words = memory->TranslateVirtual<uint32_t*>(found + record * kStride);
    const uint32_t tiles = std::min<uint32_t>(rex::byte_swap(words[3]), 3);
    for (uint32_t tile = 0; tile < tiles; ++tile) {
      uint32_t* rect = words + 7 + tile * 4;
      rect[2] = rex::byte_swap(width);
      for (uint32_t k : {1u, 3u}) {
        rect[k] = rex::byte_swap(rex::byte_swap(rect[k]) * height / 720);
      }
    }
  }
  graphics->set_fh1_scene_size(width, height);
  g_scene_width = width;
  g_scene_height = height;
  REXLOG_INFO("[scene] tiling bands scaled to {}x{}", width, height);
}

}  // namespace

void ApplySceneSize() {
  auto* state = rex::system::kernel_state();
  if (!state) return;
  auto* memory = state->memory();
  ResizeScene(memory);
  if (!REXCVAR_GET(cobalt_scene_probe)) return;
  // The headers get their memory after the screen setup: log where each
  // points every 30 s (the renderer is the static object at 0x82C232A8).
  std::thread([memory] {
    for (int round = 0; round < 20; ++round) {
      std::this_thread::sleep_for(std::chrono::seconds(30));
      std::string line;
      for (uint32_t offset : {56u, 160u, 480u, 532u, 584u, 636u, 688u}) {
        const auto* header = memory->TranslateVirtual<const uint32_t*>(0x82C232A8u + offset);
        const uint32_t fetch1 = rex::byte_swap(header[8]), size = rex::byte_swap(header[9]);
        line += fmt::format(" +{}={:08X}/{}x{}/pitch{}", offset, fetch1 & 0xFFFFF000u,
                            (size & 0x1FFF) + 1, ((size >> 13) & 0x1FFF) + 1,
                            ((rex::byte_swap(header[7]) >> 22) & 0x1FF) * 32);
      }
      REXLOG_INFO("[scene] header memory:{}", line);
    }
  }).detach();
  uint32_t logged = 0;
  bool page_readable = false;
  for (uint32_t address = 0x82000000; address < 0x83800000 && logged < 64; address += 4) {
    if (!(address & 0xFFF)) {
      // The record may run 96 bytes into the next page; only start where
      // this page and the next are both committed.
      page_readable = true;
      for (uint32_t page : {address, address + 0x1000}) {
        auto* heap = memory->LookupHeap(page);
        uint32_t protect = 0;
        page_readable = page_readable && heap && heap->QueryProtect(page, &protect) && protect;
      }
    }
    if (!page_readable) continue;
    const auto* words = memory->TranslateVirtual<const uint32_t*>(address);
    if (!words) continue;
    if (rex::byte_swap(words[0]) != 1280 || rex::byte_swap(words[1]) != 720) continue;
    // A tiling record has a small MSAA mode and tile count after the size.
    const uint32_t msaa = rex::byte_swap(words[2]), tiles = rex::byte_swap(words[3]);
    if (msaa > 3 || tiles == 0 || tiles > 8) continue;
    std::string dump;
    for (uint32_t i = 0; i < 24; ++i) {
      dump += fmt::format(" {}", rex::byte_swap(words[i]));
    }
    REXLOG_INFO("[scene] candidate at {:08X}:{}", address, dump);
    ++logged;
  }
  REXLOG_INFO("[scene] probe done, {} candidates", logged);
}

}  // namespace cobalt

// At the epilogue of FM3's screen setup (sub_822A5670, r31 the renderer,
// config/analysis/default.toml), which has built the screen textures' D3D
// headers (52 bytes each, the fetch constant from +28, its size dword at
// +0x24) from the 1280x720 screen size. With a smaller scene, set each
// screen-sized texture header's size to the scene's (a quarter-sized one
// to a quarter of it), keeping the 720p memory and pitch, so every pass
// uses the surface's top-left corner and the presenter scales the smaller
// front buffer, as Pinyon Shift does for FH1.
void CobaltSceneTexturesMade(PPCRegister& r31) {
  auto* memory = rex::system::kernel_state()->memory();
  const bool probe = REXCVAR_GET(cobalt_scene_probe);
  if (!cobalt::g_scene_width && !probe) return;
  uint32_t bit = 0;
  for (uint32_t offset : {56u, 160u, 480u, 532u, 584u, 636u, 688u}) {
    const bool keep = (REXCVAR_GET(cobalt_scene_keep_mask) >> bit++) & 1;
    auto* header = memory->TranslateVirtual<uint32_t*>(r31.u32 + offset);
    const uint32_t fetch0 = rex::byte_swap(header[7]);
    uint32_t size = rex::byte_swap(header[9]);
    const uint32_t width = (size & 0x1FFF) + 1, height = ((size >> 13) & 0x1FFF) + 1;
    if (probe) {
      REXLOG_INFO("[scene] header +{}: fetch0 {:08X} size {}x{} words {:08X} {:08X} {:08X} {:08X}",
                  offset, fetch0, width, height, rex::byte_swap(header[0]),
                  rex::byte_swap(header[8]), rex::byte_swap(header[10]),
                  rex::byte_swap(header[11]));
    }
    if (!cobalt::g_scene_width || keep || (fetch0 & 3) != 2 || ((size >> 26) & 3)) continue;
    uint32_t scene_w = 0, scene_h = 0;
    if (width == 1280 && height == 720) {
      scene_w = cobalt::g_scene_width;
      scene_h = cobalt::g_scene_height;
    } else if (width == 320 && height == 192) {
      scene_w = (cobalt::g_scene_width / 4 + 31) & ~31u;
      scene_h = (cobalt::g_scene_height / 4 + 31) & ~31u;
    } else {
      continue;
    }
    size = (size & ~0x03FFFFFFu) | (scene_w - 1) | ((scene_h - 1) << 13);
    header[9] = rex::byte_swap(size);
    REXLOG_INFO("[scene] screen texture +{} {}x{} header set to {}x{}", offset, width, height,
                scene_w, scene_h);
  }
  if (!cobalt::g_scene_width) return;
  // The renderer's screen size, which the textures were just built from,
  // also sizes the scene's viewports: the scene size from here on.
  auto* screen = memory->TranslateVirtual<uint32_t*>(r31.u32 + 472);
  screen[0] = rex::byte_swap(cobalt::g_scene_width);
  screen[1] = rex::byte_swap(cobalt::g_scene_height);
}

// D3D's SetViewport(D3DVIEWPORT9*) (sub_824B4068: r3 the device, r4 the
// viewport: x, y, width, height, min z, max z).
REXCVAR_DEFINE_BOOL(cobalt_viewport_log, false, "Cobalt",
                    "Diagnostic (#23): log the game's D3D viewports and their callers")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

extern "C" REX_FUNC(__imp__sub_824B4068);
extern "C" REX_FUNC(sub_824B4068) {
  if (REXCVAR_GET(cobalt_viewport_log)) {
    const auto* vp = reinterpret_cast<const uint32_t*>(base + ctx.r4.u32);
    static std::mutex mutex;
    static std::set<std::tuple<uint32_t, uint32_t, uint32_t, uint32_t, uint32_t>> seen;
    std::lock_guard lock(mutex);
    const uint32_t x = rex::byte_swap(vp[0]), y = rex::byte_swap(vp[1]), w = rex::byte_swap(vp[2]),
                   h = rex::byte_swap(vp[3]);
    if (seen.size() < 300 && seen.emplace(uint32_t(ctx.lr), x, y, w, h).second) {
      REXLOG_INFO("[scene] D3D SetViewport from {:08X}: {} {} {} {}", uint32_t(ctx.lr), x, y, w, h);
    }
  }
  // The minimap (called from 0x827B5EF8) sets its viewport in 720p screen
  // pixels, {63, 502, 193, 186}, where the rest of the HUD follows the
  // renderer's screen size: scale it to the scene.
  if (cobalt::g_scene_width && uint32_t(ctx.lr) == 0x827B5EF8) {
    auto* vp = reinterpret_cast<uint32_t*>(base + ctx.r4.u32);
    uint32_t saved[4];
    for (int i = 0; i < 4; ++i) {
      saved[i] = vp[i];
      const uint32_t full = (i & 1) ? 720 : 1280, scene = (i & 1) ? cobalt::g_scene_height
                                                                    : cobalt::g_scene_width;
      vp[i] = rex::byte_swap(uint32_t((uint64_t(rex::byte_swap(vp[i])) * scene + full / 2) / full));
    }
    __imp__sub_824B4068(ctx, base);
    for (int i = 0; i < 4; ++i) vp[i] = saved[i];
    return;
  }
  __imp__sub_824B4068(ctx, base);
}
