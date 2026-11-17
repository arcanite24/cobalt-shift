// Cobalt Shift - car shadows and reflections at a lower rate (low end)
//
// Ported from FM3-ReGPU (MIT, src/hooks/car_shadows.cpp and
// car_reflections.cpp; THIRD_PARTY_NOTICES.md), same default.xex.
//
// Car shadows: sub_827B5088 drives the car shadow maps once a frame in two
// phases; each phase begins a pass (sub_827B4D30: render target, clear),
// draws the cars through the drop-shadow effect's method (sub_82592168) and
// ends it (sub_827B4E40: two resolves). About 70 of each car's ~183 draws a
// frame go there. Skipping the whole pass leaves no clear and no resolve, so
// the ground shadows read last time's images: drawn every Nth frame, they are
// up to N-1 frames old. Skipping only the cars would blink them away.
//
// Reflections: sub_827FF238 draws three of the six 256x256 4x MSAA faces of
// the cube map every car reflects, alternating between the two sets, and
// resolves them. Skipped whole, the faces keep their last images.

#include <atomic>
#include <cstdint>

#include <rex/types.h>
#include <rex/cvar.h>
#include <rex/ppc/context.h>
#include <rex/ppc/func.h>

REXCVAR_DEFINE_INT32(cobalt_shadow_rate, 1, "Cobalt",
                     "Draw the car shadow maps every Nth frame (1 = every frame, as the game does)")
    .range(1, 60)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

REXCVAR_DEFINE_INT32(cobalt_reflect_rate, 1, "Cobalt",
                     "Draw the cars' reflection cube faces every Nth time (1 = every frame, as the "
                     "game does)")
    .range(1, 60)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

namespace {
// This frame's shadow passes are skipped (FM3's render thread only).
bool g_skip_shadows = false;
}  // namespace

extern "C" REX_FUNC(__imp__sub_827B5088);
extern "C" REX_FUNC(__imp__sub_827B4D30);
extern "C" REX_FUNC(__imp__sub_82592168);
extern "C" REX_FUNC(__imp__sub_827B4E40);
extern "C" REX_FUNC(__imp__sub_827FF238);

// The car shadows' driver: decides for the frame.
extern "C" REX_FUNC(sub_827B5088) {
  static uint64_t frames = 0;
  const uint64_t rate = uint64_t(REXCVAR_GET(cobalt_shadow_rate));
  g_skip_shadows = rate > 1 && frames++ % rate != 0;
  __imp__sub_827B5088(ctx, base);
  g_skip_shadows = false;
}

// Begin a shadow pass.
extern "C" REX_FUNC(sub_827B4D30) {
  if (!g_skip_shadows) __imp__sub_827B4D30(ctx, base);
}

// Draw the cars into it.
extern "C" REX_FUNC(sub_82592168) {
  if (!g_skip_shadows) __imp__sub_82592168(ctx, base);
}

// End it (resolves).
extern "C" REX_FUNC(sub_827B4E40) {
  if (!g_skip_shadows) __imp__sub_827B4E40(ctx, base);
}

// Three reflection faces.
extern "C" REX_FUNC(sub_827FF238) {
  static uint64_t calls = 0;
  const uint64_t rate = uint64_t(REXCVAR_GET(cobalt_reflect_rate));
  if (rate > 1 && calls++ % rate != 0) return;
  __imp__sub_827FF238(ctx, base);
}

// Rear-view mirror (FM3-ReGPU src/hooks/mirror.cpp): sub_827FDB88 renders
// the scene behind the car into the mirror's 384x128 target, once a frame in
// the cockpit view only (~140-300 world draws). Skipped, the mirror keeps its
// last picture.
REXCVAR_DEFINE_INT32(cobalt_mirror_rate, 1, "Cobalt",
                     "Draw the rear-view mirror every Nth frame (1 = every frame, as the game does)")
    .range(1, 8)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

// Distant AI cars (same file): in the main view the game ranks the cars by
// distance and sets each one's detail level (+596 of the object in r10) to 0
// for the nearest one or two, 1 to rank 3-4 and 2 beyond, then draws it
// through sub_828329C8 from 0x82837F0C. Cars ranked at level 1 or more are
// drawn at this level instead (levels go to 4); FM3-ReGPU measured +4.1 % at
// level 3 where its draw thread limited, with mid-distance cars losing small
// details.
REXCVAR_DEFINE_INT32(cobalt_far_car_lod, 0, "Cobalt",
                     "Detail level for AI cars beyond the nearest two (0 = as the game ranks "
                     "them, up to 4 = least)")
    .range(0, 4)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

extern "C" REX_FUNC(__imp__sub_827FDB88);
extern "C" REX_FUNC(__imp__sub_828329C8);

extern "C" REX_FUNC(sub_827FDB88) {
  static uint64_t calls = 0;
  const uint64_t rate = uint64_t(REXCVAR_GET(cobalt_mirror_rate));
  if (rate > 1 && calls++ % rate != 0) return;
  __imp__sub_827FDB88(ctx, base);
}

extern "C" REX_FUNC(sub_828329C8) {
  const uint32_t far_lod = uint32_t(REXCVAR_GET(cobalt_far_car_lod));
  if (far_lod && uint32_t(ctx.lr) == 0x82837F0C) {
    // A heap object: no physical-range offset.
    auto* field = reinterpret_cast<uint32_t*>(base + ctx.r10.u32 + 596);
    const uint32_t old = rex::byte_swap(*field);
    if (old >= 1 && old < 16) {
      *field = rex::byte_swap(far_lod);
      __imp__sub_828329C8(ctx, base);
      *field = rex::byte_swap(old);
      return;
    }
  }
  __imp__sub_828329C8(ctx, base);
}
