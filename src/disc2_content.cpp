// Cobalt Shift - Disc 2 (Content Install Disc)
//
// FM3's Disc 2 carries eight STFS packages under
// Content\0000000000000000\4D53084D\00000002\ (Marketplace content). On the
// console the title copies them to the hard drive; here the SDK's
// ContentManager::InstallContent unpacks each one (with its .header) the
// first time a run finds it missing. tools/cobalt_setup.py disc2 puts the
// disc's files in <game root>/../disc2-raw.
//
// Each package's Media\DLCZips\<id>_pri_65.zip carries the game database's
// patches (media/db/patch/*_merge.slt and *_execute.sql: the DLC cars' and
// Disc 2's tracks' rows, and IsInstalled=1 for them), but FM3 reads them from
// a folder of that name (DLCRootN:\media\dlczips\<id>_pri_65\media\db\patch),
// which the package doesn't have: without them no Disc 2 car or track
// is in the database. They are unpacked next to the zip once, as FM3-ReGPU
// does (session 18, src/kernel/imports_xam.cpp UnpackDlcPatches, MIT; found by
// the FM2 port, eda8833). Members are stored or Xbox LZX (method 21).

#include "disc2_content.h"

#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/runtime.h>
#include <rex/system/kernel_state.h>
#include <rex/system/xam/content_manager.h>

#include "lzx.h"

#include <algorithm>
#include <cstring>
#include <fstream>

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
namespace {

uint32_t Le16(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8; }
uint32_t Le32(const uint8_t* p) { return Le16(p) | Le16(p + 2) << 16; }

// Writes the zip's media/db/patch/ members under `folder`; returns their names.
std::vector<std::string> UnpackDbPatches(const std::filesystem::path& zip_path,
                                         const std::filesystem::path& folder) {
  std::vector<std::string> written;
  std::ifstream in(zip_path, std::ios::binary | std::ios::ate);
  if (!in) return written;
  const uint64_t size = uint64_t(in.tellg());
  if (size < 22) return written;
  const uint64_t tail_size = std::min<uint64_t>(size, 0x10000 + 22);
  std::vector<uint8_t> tail(static_cast<size_t>(tail_size));
  in.seekg(std::streamoff(size - tail_size));
  in.read(reinterpret_cast<char*>(tail.data()), std::streamsize(tail_size));
  size_t eocd = tail.size() - 22;
  while (eocd > 0 && Le32(&tail[eocd]) != 0x06054B50) --eocd;
  if (Le32(&tail[eocd]) != 0x06054B50) return written;
  const uint32_t entries = Le16(&tail[eocd + 10]);
  const uint32_t cd_size = Le32(&tail[eocd + 12]), cd_offset = Le32(&tail[eocd + 16]);
  if (uint64_t(cd_offset) + cd_size > size) return written;
  std::vector<uint8_t> cd(cd_size);
  in.seekg(cd_offset);
  in.read(reinterpret_cast<char*>(cd.data()), cd_size);
  size_t at = 0;
  for (uint32_t e = 0; e < entries && at + 46 <= cd.size() && Le32(&cd[at]) == 0x02014B50; ++e) {
    const uint32_t method = Le16(&cd[at + 10]);
    const uint32_t csize = Le32(&cd[at + 20]), usize = Le32(&cd[at + 24]);
    const uint32_t name_len = Le16(&cd[at + 28]), extra_len = Le16(&cd[at + 30]),
                   comment_len = Le16(&cd[at + 32]);
    const uint32_t local = Le32(&cd[at + 42]);
    if (at + 46 + name_len > cd.size()) break;
    std::string name(reinterpret_cast<const char*>(&cd[at + 46]), name_len);
    at += 46 + name_len + extra_len + comment_len;
    std::string lower = name;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](char c) { return char(std::tolower(uint8_t(c))); });
    if (lower.rfind("media/db/patch/", 0) != 0 || lower.back() == '/' ||
        lower.find("..") != std::string::npos) {
      continue;
    }
    uint8_t header[30];
    in.seekg(local);
    if (!in.read(reinterpret_cast<char*>(header), 30)) continue;
    const uint64_t start = uint64_t(local) + 30 + Le16(&header[26]) + Le16(&header[28]);
    if (start + csize > size) continue;
    std::vector<uint8_t> raw(csize), data;
    in.seekg(std::streamoff(start));
    in.read(reinterpret_cast<char*>(raw.data()), csize);
    if (method == 0) {
      data = std::move(raw);
    } else if (method != 21 || !LzxDecompress(raw.data(), csize, usize, data)) {
      REXLOG_WARN("Disc 2: {}: can't unpack {} (method {})", zip_path.filename().string(), name,
                  method);
      continue;
    }
    std::error_code ec;
    const auto out_path = folder / std::filesystem::path(name).make_preferred();
    std::filesystem::create_directories(out_path.parent_path(), ec);
    std::ofstream(out_path, std::ios::binary)
        .write(reinterpret_cast<const char*>(data.data()), std::streamsize(data.size()));
    written.push_back(name);
  }
  return written;
}

// Every package's database patches, unpacked once (a stamp beside them).
void UnpackPackagePatches(const std::filesystem::path& installed_root) {
  std::error_code ec;
  int unpacked = 0;
  for (const auto& package : std::filesystem::directory_iterator(installed_root, ec)) {
    const auto zips = package.path() / "Media" / "DLCZips";
    for (const auto& zip : std::filesystem::directory_iterator(zips, ec)) {
      if (!zip.is_regular_file() || zip.path().extension() != ".zip") continue;
      const auto folder = zip.path().parent_path() / zip.path().stem();
      const auto stamp = folder / ".cobalt-db-patches";
      const std::string want = std::to_string(zip.file_size(ec));
      {
        std::ifstream in(stamp);
        std::string have;
        if (in && std::getline(in, have) && have == want) continue;
      }
      const auto names = UnpackDbPatches(zip.path(), folder);
      std::filesystem::create_directories(folder, ec);
      std::ofstream out(stamp);
      out << want << '\n';
      for (const auto& name : names) out << name << '\n';
      if (!names.empty()) {
        REXLOG_INFO("Disc 2: {}: {} database patch file(s) unpacked",
                    zip.path().filename().string(), names.size());
        unpacked += int(names.size());
      }
    }
  }
  if (unpacked) REXLOG_INFO("Disc 2: {} database patch file(s) in all", unpacked);
}

}  // namespace

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
  UnpackPackagePatches(installed_root);
}

}  // namespace cobalt
