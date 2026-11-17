// Cobalt Shift - Forza Motorsport 3 on ShiftGlue

#pragma once

#include <rex/cvar.h>
#include <rex/perf/counter.h>
#include <rex/rex_app.h>

#include <rex/input/input_system.h>
#include <rex/runtime.h>

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
