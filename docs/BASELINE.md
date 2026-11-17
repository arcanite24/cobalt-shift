# Cobalt Shift baseline and measured changes

Every number here comes from `tools/bench_race.ps1` unless stated otherwise.
The route boots FM3 (UC `default.xex` v0.0.0.8), walks the first-run flow into
the opening race at Montserrat (Audi R8, Disc 2 declined, Casual) with the
scripted pad (`--pad_script_file`, `src/pad_script.cpp`), then holds full
throttle for 60 s. Nobody steers, so the car runs along the first corner's
barrier. That makes the run repeatable. FM3 doesn't keep the first-run choices
without a signed-in profile, so every run takes the same route.

Machine: multivac (Ryzen 7 5800X, RTX 4080, Windows 11), ShiftGlue Vulkan,
rexgpu-fh1, 1280x720 (scale 1), window 3072x1728. A second ShiftGlue game
(Lavender Shift) was open in another session during these runs, so treat
small differences as noise until repeated.

Columns:

- **frames/s:** rows in the perf CSV during the window, one per guest frame.
- **cores:** the process's CPU time over the window.
- **GPU ms:** `guest_frame_gpu_time_ns`, timestamp to timestamp, so it
  includes gaps where the GPU waits on submission. It is not pure GPU work:
  it went *up* when the frame rate halved, because the GPU clocks down.
- **decoder ms:** `gpu_decoder_cpu_ns`, the CPU the PM4 decoder used per frame.

| Run | Change | frames/s | cores | frame p50 / p99 ms | GPU ms | decoder ms | presents |
|---|---|---|---|---|---|---|---|
| base | SDK defaults (120 Hz guest vblank) | 102.4 | 3.25 | 8.62 / 17.02 | 9.2 | 8.5 | 60/s, 0.4 dropped per frame |
| vb60 | `pinyon_shift_fh1_render_fps_limit=30` (60 Hz vblank) | 58.3 | 2.40 | 16.69 / 33.51 | 14.8 | 7.5 | 58/s, none dropped |

## Frame pacing: the guest vblank (FM3-QUIRKS Q24)

The SDK fires guest vblanks at twice the render limit, because FH1 renders a
frame every two vblanks. FM3 runs its main loop once per vblank and takes its
time step from the millisecond clock, so at the SDK's 120 Hz it rendered about
102 frames a second. The presenter showed 60 of them; the rest were simulated,
drawn and dropped. Game time still ran at real speed: the lap timer read 57 s
after the 60 s window.

At 60 Hz (render limit 30) FM3 renders 58 frames a second and every one is
presented. This is a frame cap, not a saving per frame. Process CPU fell 26 %
while frames fell 43 %, so CPU per frame *rose* from about 32 ms to about
41 ms. The idle time the cap opens is mostly spent spinning (CB-32 ring wait,
CB-33 CP idle sleep). About 2 frames a second miss a vblank and take 33 ms
(p99), where the 120 Hz vblank absorbed them.

The limit of 30 is fixed for now. It pins every display to 60 fps, although
FM3 keeps real-time speed at 102 fps. It should follow the display refresh
once presentation shows each frame once (Lavender's
`pinyon_shift_fh1_source_presentation`). Cobalt now sets the
limit by default (`src/cobalt_shift_app.h`). A frame-time hook on FM3's main
loop, as FM3-ReGPU's session 13 did, is how to keep 60 Hz and lose those
misses.

## Known rendering issues seen on the route

- The 2D UI is scaled about 1.25x from the top-left corner. The Dolby splash
  centre lands at (800, 450) instead of (640, 360), and dialogs and the race
  HUD's lap times are clipped at the right edge. The 3D scene is fine.
- The car shadow, road and Montserrat scenery look right. Q18 and Q19 are not
  visible on this route.
