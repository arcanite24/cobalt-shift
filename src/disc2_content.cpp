// Cobalt Shift - Disc 2 (Content Install Disc)
//
// FM3's Disc 2 carries eight STFS packages under
// Content\0000000000000000\4D53084D\00000002\ (Marketplace content). On the
// console the title copies them to the hard drive; here the SDK's
// ContentManager::InstallContent unpacks each one (with its .header) the
// first time a run finds it missing. tools/cobalt_setup.py disc2 puts the
// disc's files in <game root>/../disc2-raw.

#include "disc2_content.h"

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/runtime.h>
#include <rex/system/kernel_state.h>
#include <rex/system/xam/content_manager.h>

#include <string>
#include <system_error>
#include <vector>

REXCVAR_DEFINE_STRING(cobalt_disc2_root, "", "Cobalt",
                      "Disc 2's extracted files (empty: <game root>/../disc2-raw); its "
                      "content packages are installed once into cobalt_content_root");
REXCVAR_DEFINE_BOOL(cobalt_disc2_content, true, "Cobalt",
                    "Install and list Disc 2's content; false hides it, and the game asks "
                    "for Disc 2 as on a first run without it (the benchmark routes)");
REXCVAR_DEFINE_STRING(cobalt_content_root, "", "Cobalt",
                      "Marketplace content every profile shares, Disc 2's packages "
                      "among it (empty: <game root>/../content)");

namespace cobalt {

void InstallDisc2Content(rex::Runtime* runtime, const std::filesystem::path& game_root) {
  auto* kernel = runtime ? runtime->kernel_state() : nullptr;
  auto* content = kernel ? kernel->content_manager() : nullptr;
  if (!content) return;
  const std::filesystem::path base = game_root.parent_path();
  const std::string content_flag = REXCVAR_GET(cobalt_content_root);
  const std::filesystem::path content_root =
      content_flag.empty() ? base / "content" : std::filesystem::path(content_flag);
  content->SetMarketplaceRoot(content_root);
  const auto installed_root = content_root / "0000000000000000" / "4D53084D" / "00000002";
  std::error_code ec;

  if (!REXCVAR_GET(cobalt_disc2_content)) {
    // Disc 2's package names: 4D53084D0CCFxxxx.
    std::vector<std::string> hidden;
    for (const auto& entry : std::filesystem::directory_iterator(installed_root, ec)) {
      const auto name = entry.path().filename().string();
      if (name.rfind("4D53084D0CCF", 0) == 0) hidden.push_back(name);
    }
    REXLOG_INFO("Disc 2: content hidden ({} package(s))", hidden.size());
    content->SetHiddenMarketplacePackages(std::move(hidden));
    return;
  }

  const std::string disc2_flag = REXCVAR_GET(cobalt_disc2_root);
  const std::filesystem::path disc2 =
      disc2_flag.empty() ? base / "disc2-raw" : std::filesystem::path(disc2_flag);
  const auto packages = disc2 / "Content" / "0000000000000000" / "4D53084D" / "00000002";
  if (!std::filesystem::is_directory(packages, ec)) {
    REXLOG_INFO("Disc 2: no packages in {}", packages.string());
    return;
  }
  const auto headers =
      content_root / "0000000000000000" / "4D53084D" / "Headers" / "00000002";
  int installed = 0, present = 0;
  for (const auto& entry : std::filesystem::directory_iterator(packages, ec)) {
    if (!entry.is_regular_file()) continue;
    const auto name = entry.path().filename().string();
    if (std::filesystem::exists(headers / (name + ".header"), ec)) {
      ++present;
      continue;
    }
    REXLOG_INFO("Disc 2: installing {}", name);
    const auto result = content->InstallContent(entry.path());
    if (result) {
      REXLOG_WARN("Disc 2: {} failed to install ({:08X})", name, result);
    } else {
      ++installed;
    }
  }
  REXLOG_INFO("Disc 2: {} package(s) installed, {} already present in {}", installed, present,
              content_root.string());
}

}  // namespace cobalt
