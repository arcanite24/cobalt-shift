// Cobalt Shift - Disc 2 (Content Install Disc)

#pragma once

#include <filesystem>

namespace rex {
class Runtime;
}

namespace cobalt {

// Installs Disc 2's content packages once, as the console's "install Disc 2"
// does, into a Marketplace content folder every profile shares, so the
// game lists the extra cars and tracks instead of asking for the disc.
void InstallDisc2Content(rex::Runtime* runtime, const std::filesystem::path& game_root);

}  // namespace cobalt
