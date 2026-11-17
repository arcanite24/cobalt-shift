// Cobalt Shift - Forza Motorsport 3 on ShiftGlue

#pragma once

#include <rex/cvar.h>
#include <rex/perf/counter.h>
#include <rex/rex_app.h>

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
