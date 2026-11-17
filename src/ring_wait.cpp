// Cobalt Shift - FM3's D3D ring-space wait without spinning (CB-32)
//
// FM3's D3D layer waits for ring-buffer space or a fence by calling a poll in
// a loop (sub_824B5048 -> sub_824AAA68; FM3-ReGPU, MIT, src/hooks/ring_wait.cpp).
// Each call spins about 32 db16cyc delays, re-reads the read pointer the
// command processor writes back and returns 1 to keep waiting, 0 to stop. On
// the host that loop holds the render thread at a full core while the CP
// works through the ring: FM3-ReGPU's profile had ~65 % of that thread in it.
//
// This is Lavender Shift's FH2 fix (its src/ring_wait.cpp) in a form that
// needs no device offsets: the poll runs unchanged first, so its bookkeeping
// and hang check still see real time pass, and when it answers 1 the thread
// blocks until the CP next writes something CPU-visible (with
// gpu_read_pointer_publish_dwords set, the read pointer inside a burst too)
// or cobalt_ring_wait_us passes. The sequence is taken before the poll reads
// the pointer, so a writeback in between ends the wait at once.

#include <chrono>
#include <cstdint>

#include <rex/cvar.h>
#include <rex/ppc/context.h>
#include <rex/ppc/func.h>
#include <rex/system/gpu_write_signal.h>

REXCVAR_DEFINE_INT32(cobalt_ring_wait_us, 1000, "Cobalt",
                     "Longest sleep, in microseconds, after each poll of FM3's wait for "
                     "ring-buffer space that answers keep waiting; 0 keeps the game's busy poll")
    .range(0, 100000)
    .lifecycle(rex::cvar::Lifecycle::kHotReload);

extern "C" REX_FUNC(__imp__sub_824AAA68);

extern "C" REX_FUNC(sub_824AAA68) {
  const int32_t wait_us = REXCVAR_GET(cobalt_ring_wait_us);
  const uint32_t seen = wait_us > 0 ? rex::system::GpuWriteSequence() : 0;
  __imp__sub_824AAA68(ctx, base);
  if (wait_us > 0 && ctx.r3.u32 == 1) {
    rex::system::WaitForGpuWrite(seen, std::chrono::microseconds(wait_us));
  }
}
