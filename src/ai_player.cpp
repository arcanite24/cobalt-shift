// Cobalt Shift - the player's car driven by FM3's own race AI
//
// Ported from FM3-ReGPU (MIT, src/hooks/ai_player.cpp; THIRD_PARTY_NOTICES.md),
// same default.xex. For automated benchmarks on a moving race, and to finish
// the first-run flow's opening race (#24), which a scripted pad can't drive.
//
// sub_828F8858(car, params) gives each car its driver as a race is built:
// car = the RacingAI::CAICar, params = its race entry (params[0]: 3 the
// player, 2 an opponent). For the player's car (car+104 == 0) FM3 installs a
// CHumanDriver; for an opponent (car+104 == 2) it sets up the car's physics
// and installs an AI driver from the factory. Built with both fields as an
// opponent's and then marked the player's again, the AI races the player's
// car for the whole race while the HUD, camera, position and results still
// follow it as the player's. (FM3-ReGPU: installing an AI driver afterwards
// left the pad in control, and +104 = 1 with type 3 revved on the line.)

#include <cstdint>

#include <rex/types.h>
#include <rex/cvar.h>
#include <rex/logging/macros.h>
#include <rex/ppc/context.h>
#include <rex/ppc/func.h>

REXCVAR_DEFINE_BOOL(cobalt_ai_player, false, "Cobalt",
                    "The race AI drives the player's car (automated benchmarks, and finishing "
                    "the first-run race)")
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

extern "C" REX_FUNC(__imp__sub_828F8858);
extern "C" REX_FUNC(sub_828F8858) {
  // The car and its race entry are heap objects: no physical-range offset.
  auto* flag = reinterpret_cast<uint32_t*>(base + ctx.r3.u32 + 104);
  auto* type = reinterpret_cast<uint32_t*>(base + ctx.r4.u32);
  if (!REXCVAR_GET(cobalt_ai_player) || rex::byte_swap(*flag) != 0) {
    __imp__sub_828F8858(ctx, base);
    return;
  }
  const uint32_t car = ctx.r3.u32, saved_type = *type;
  *flag = rex::byte_swap(2u);
  *type = rex::byte_swap(2u);
  __imp__sub_828F8858(ctx, base);
  *type = saved_type;
  *flag = 0;
  REXLOG_INFO("[ai] the player's car {:08X} is driven by the race AI", car);
}
