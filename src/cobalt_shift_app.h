// Cobalt Shift - Forza Motorsport 3 on ShiftGlue

#pragma once

#include <rex/cvar.h>
#include <rex/perf/counter.h>
#include <rex/rex_app.h>

#include <rex/input/input_system.h>
#include <rex/runtime.h>
#include <rex/system/gpu_plugin.h>

#include <utility>

REXCVAR_DECLARE(std::string, gpu_backend);

// Included by main.cpp only, so the definition lives here.
REXCVAR_DEFINE_BOOL(cobalt_low_end, false, "Cobalt",
                    "Low-end preset for integrated GPUs: drop rendering work that changes the "
                    "image a little, for frame rate (docs/BASELINE.md, \"Low-end\")")
    .lifecycle(rex::cvar::Lifecycle::kRequiresRestart);

#include "pad_script.h"
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
    for (const auto& [name, value] : {std::pair{"pinyon_shift_fh1_render_fps_limit", "30"},
                                      std::pair{"gpu_read_pointer_publish_dwords", "1024"},
                                      std::pair{"clear_memory_page_state", "false"},
                                      std::pair{"spirv_implicit_lod_2d", "true"},
                                      std::pair{"spirv_fast_pixel_math", "true"}}) {
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
    // setting (-1) saved 7 % of the UHD 620's frame.
    if (REXCVAR_GET(cobalt_low_end)) {
      for (const auto& [name, value] :
           {std::pair{"fh1_skip_pixel_shaders", "8FEC358DC5728647"},
            std::pair{"anisotropic_override", "-1"}}) {
        if (rex::cvar::GetFlagSource(name) == rex::cvar::Source::kDefault) {
          rex::cvar::SetFlagByName(name, value);
        }
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

  // --perf_log_csv=<path> writes one row of the SDK's counters per frame;
  // the SDK leaves opening it to the app.
  void OnPostInitLogging() override {
    const std::string perf_csv = rex::cvar::GetFlagByName("perf_log_csv");
    if (!perf_csv.empty()) {
      rex::perf::SetCsvLogPath(perf_csv);
    }
  }
};
