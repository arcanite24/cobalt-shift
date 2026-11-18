// Cobalt Shift - Forza Motorsport 3 on ShiftGlue

#pragma once

#include <rex/cvar.h>
#include <rex/perf/counter.h>
#include <rex/rex_app.h>

#include <rex/input/input_system.h>
#include <rex/runtime.h>
#include <rex/system/gpu_plugin.h>

#include <string>
#include <utility>

REXCVAR_DECLARE(std::string, gpu_backend);

// Included by main.cpp only, so the definition lives here.
REXCVAR_DEFINE_BOOL(cobalt_low_end, false, "Cobalt",
                    "Low-end preset for integrated GPUs: drop rendering work that changes the "
                    "image a little, for frame rate (docs/BASELINE.md, \"Low-end\")")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

#include "pad_script.h"
#include "scene_size.h"
#include "utility_drive.h"

class CobaltShiftApp : public rex::ReXApp {
 public:
  using rex::ReXApp::ReXApp;

  static std::unique_ptr<rex::ui::WindowedApp> Create(
      rex::ui::WindowedAppContext& ctx) {
    return std::unique_ptr<CobaltShiftApp>(new CobaltShiftApp(ctx, "cobalt_shift",
        PPCImageConfig));
  }

  // Stage 0 renders through ShiftGlue's Xenos (PM4) plugin, rexgpu-fh1,
  // unless --gpu_plugin names another one.
  void OnPreSetup(rex::RuntimeConfig& config) override {
    if (config.gpu_plugin.empty()) {
      config.gpu_plugin = "fh1";
    }
    // Loaded here rather than by the SDK just after, so the plugin's settings
    // exist when Cobalt's defaults are set; on failure the SDK loads it again
    // and reports.
    if (!config.graphics) {
      config.graphics = rex::system::LoadGpuPlugin(config.gpu_plugin, REXCVAR_GET(gpu_backend));
    }
    // Cobalt's defaults where the SDK's differ; a value from the config file
    // or the command line wins.
    //
    // spirv_implicit_lod_2d and spirv_fast_pixel_math: the UHD 620's grid went
    // from 14.7 to 17.9 fps with both, and the RTX 4080's image looks the same.
    //
    // FM3 runs its main loop once per guest vblank and takes its time step
    // from the millisecond clock (FM3-QUIRKS Q24), but the SDK fires vblanks
    // at twice the render limit for FH1, which waits for two. At 120 Hz FM3
    // rendered 102 frames a second for a 60 Hz display, 40 % of them never
    // shown. A render limit of 30 gives a 60 Hz vblank: 58 frames a second,
    // every one presented (docs/BASELINE.md). This is a cap; it pins 60 fps
    // until presentation follows the display.
    //
    // The CP writes the ring read pointer back inside long bursts too, and
    // wakes the render thread blocked in FM3's ring-space wait
    // (src/ring_wait.cpp), as Lavender does for FH2.
    //
    // clear_memory_page_state drops every CPU-uploaded page's valid bit at
    // each frame end, so FM3 re-uploaded all of its geometry every frame:
    // about 17 MB and 390 uploads, each ending the open rendering. Write
    // watches already catch the CPU's writes to uploaded pages; off, uploads
    // fall to about 40 KB a frame (docs/BASELINE.md). Lavender sets it too.
    //
    // fh1_untile_predicated_tiling (the SDK's default on Linux and macOS
    // only) draws FM3's predicated-tiling race scene once instead of once a
    // tile: 1,975 -> 1,502 draws a frame on the grid, about 7 % less CPU a
    // frame uncapped on the 5800X (250 -> 256-265 fps), the same image, and
    // the whole HUD at 960x540. The menus and garage tile at 4X and draw a
    // depth-only reset per tile; the SDK runs those in their tiles' rows.
    //
    // fh1_readback_resolve_sizes: images FM3's CPU code reads right after
    // rendering them, which stay on the GPU otherwise. At a track load, four
    // 32x512 road strips that it compresses to DXT1 and composes into the
    // road's detail image (FM3-QUIRKS Q18; stale, Ladera's asphalt showed
    // blocky bands, #25). When a car changes, its 512x256 picture and
    // 256x128 thumbnail, which it copies into the car's saved images.
    // FM3-ReGPU writes the same ones back at once (src/gpu_host.cpp).
    for (const auto& [name, value] : {std::pair{"pinyon_shift_fh1_render_fps_limit", "30"},
                                      std::pair{"gpu_read_pointer_publish_dwords", "1024"},
                                      std::pair{"clear_memory_page_state", "false"},
                                      std::pair{"spirv_implicit_lod_2d", "true"},
                                      std::pair{"spirv_fast_pixel_math", "true"},
                                      std::pair{"fh1_untile_predicated_tiling", "true"},
                                      std::pair{"fh1_readback_resolve_sizes",
                                                "32x512,512x256,256x128"}}) {
      if (rex::cvar::GetFlagSource(name) == rex::cvar::Source::kDefault) {
        rex::cvar::SetFlagByName(name, value);
      }
    }
    // The low-end preset (cobalt_low_end). Pixel shader 8FEC358DC5728647 is
    // a terrain detail layer (grass flowers, rock shading, flag cloth) drawn
    // with alpha to coverage, which the SDK emulates with a kill in the
    // shader, so the UHD 620 shades every covered pixel with no early depth
    // test: a third of its frame. Skipping it took the grid from 17.9 to
    // 30.5 fps there. A positive mip LOD bias gained nothing and turns the
    // road pink. The SDK forces 4x anisotropic filtering; the game's own
    // setting (-1) saved 7 % of the UHD 620's frame. FM3-ReGPU's cuts
    // (src/render_rates.cpp): car shadows, reflections and the mirror every
    // other frame and distant AI cars at detail level 3 took the UHD 620's
    // grid from 30.3 to 31.5 fps, with p95 frames from 34-48 to 33.9 ms.
    // The scene at 960x540 (src/scene_size.cpp, presenter upscale) took it
    // from 32.4 to 38.9-39.4 fps with the whole HUD (docs/BASELINE.md).
    if (REXCVAR_GET(cobalt_low_end)) {
      for (const auto& [name, value] :
           {std::pair{"fh1_skip_pixel_shaders", "8FEC358DC5728647"},
            std::pair{"anisotropic_override", "-1"},
            std::pair{"cobalt_shadow_rate", "2"},
            std::pair{"cobalt_reflect_rate", "2"},
            std::pair{"cobalt_mirror_rate", "2"},
            std::pair{"cobalt_far_car_lod", "3"},
            std::pair{"cobalt_scene_size", "960x540"}}) {
        if (rex::cvar::GetFlagSource(name) == rex::cvar::Source::kDefault) {
          rex::cvar::SetFlagByName(name, value);
        }
      }
    }
    // Above the default cap, split the GPU commands thread in two: decoding
    // on one, register writes and draw recording on the other. Uncapped on
    // the 5800X it took the grid from about 215 to 282 fps. At the 60 fps
    // cap it only adds CPU (1.04 -> 1.21 cores), and the UHD 620 laptop gains
    // little for 0.25 more cores, so the default and low-end setups keep one
    // thread. A limit of 0 follows the display, so it isn't counted as raised.
    if (rex::cvar::GetFlagSource("gpu_record_thread") == rex::cvar::Source::kDefault &&
        !REXCVAR_GET(cobalt_low_end)) {
      int render_limit = 0;
      try {
        render_limit = std::stoi(rex::cvar::GetFlagByName("pinyon_shift_fh1_render_fps_limit"));
      } catch (...) {
      }
      if (render_limit > 30) {
        rex::cvar::SetFlagByName("gpu_record_thread", "true");
      }
    }
  }

  // FM3 streams replays to cache: (FM3-QUIRKS Q8).
  // The scripted pad is added before any guest thread polls input.
  void OnPreLaunchModule() override {
    cobalt::MountUtilityDrive(runtime(), user_data_root());
    cobalt::InstallPadScript(
        static_cast<rex::input::InputSystem*>(runtime()->input_system()));
  }

  // The image is in memory and no guest code has run: the scene size (#23)
  // edits its static tiling records here.
  void OnPostLoadXexImage() override { cobalt::ApplySceneSize(); }

  // --perf_log_csv=<path> writes one row of the SDK's counters per frame;
  // the SDK leaves opening it to the app.
  void OnPostInitLogging() override {
    const std::string perf_csv = rex::cvar::GetFlagByName("perf_log_csv");
    if (!perf_csv.empty()) {
      rex::perf::SetCsvLogPath(perf_csv);
    }
  }
};
