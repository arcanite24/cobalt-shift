// Cobalt Shift - front-end frame rate (#21, CB-35)
//
// FM3's menu animations advance by at least 1/120 s per rendered frame,
// whatever the frame time, so above 120 fps the front end runs cap/120 times
// too fast (FM3-ReGPU session 40, MIT, src/hooks/frontend_rate.cpp: 19 frames
// for the Free Play submenu at 60 fps, ~40 at 120, 240 and 360). Its fix:
// the front end renders at most 120 fps, races at the full cap. The tiling
// set-up, sub_82798890, runs when the renderer switches scenario: index 0
// (+0 of r3) is the front end (photo mode too), 1 the race.
//
// Cobalt's frame rate is pinyon_shift_fh1_render_fps_limit, which the SDK
// reads every vblank tick (two guest vblanks per rendered frame at FH1's
// pacing, one FM3 frame per vblank: limit 30 = 60 fps). Under the default 60
// fps cap nothing changes.

#include <rex/types.h>
#include <rex/cvar.h>
#include <rex/logging.h>
#include <rex/ppc/context.h>
#include <rex/ppc/func.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <string>

REXCVAR_DEFINE_INT32(cobalt_frontend_fps, 120, "Cobalt",
                     "Most frames a second FM3's front end (menus, photo mode) renders when "
                     "the frame cap is higher: its menus animate per frame and run too fast "
                     "above 120. 0: the front end runs at the full cap")
    .range(0, 1000);

extern "C" REX_FUNC(__imp__sub_82798890);

extern "C" REX_FUNC(sub_82798890) {
  const uint32_t object = ctx.r3.u32;
  __imp__sub_82798890(ctx, base);
  const int32_t frontend_fps = REXCVAR_GET(cobalt_frontend_fps);
  if (frontend_fps <= 0) return;
  // The player's limit, as set when the first scenario was made.
  static const int user_limit =
      std::atoi(rex::cvar::GetFlagByName("pinyon_shift_fh1_render_fps_limit").c_str());
  const int frontend_limit = std::max(15, frontend_fps / 2);
  if (user_limit <= 0 || user_limit <= frontend_limit) return;
  // The renderer is a heap object: no physical-range offset.
  const uint32_t index = rex::byte_swap(*reinterpret_cast<const uint32_t*>(base + object));
  const int limit = index == 0 ? frontend_limit : user_limit;
  static int applied = user_limit;
  if (limit == applied) return;
  applied = limit;
  rex::cvar::SetFlagByName("pinyon_shift_fh1_render_fps_limit", std::to_string(limit));
  REXLOG_INFO("Front end: frame limit {} fps ({}; cap {} fps)", limit * 2,
              index == 0 ? "front end" : "race", user_limit * 2);
}
