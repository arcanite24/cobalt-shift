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

## Static grid route (from 2026-11-17)

The throttle runs were not repeatable: mean draw calls were 1142, 1658 and
1218 over three runs of the same configuration. `bench_race.ps1` now sits on
the grid by default. It measures 60 s from 15 s after the green light, while
the field drives off and the camera stays still. After the Disc 2 prompt it
presses A every 2.5 s. Blind timings had left two runs stuck in the
pre-race flyover, which FM3 caps at 30 fps. `tools/thread_cpu.ps1` adds CPU
per thread name.

| Run | Build | frames/s | cores | CPU ms/frame | busiest threads (cores) |
|---|---|---|---|---|---|
| b-msvol | first build (-O3, MS volatile), vblank 60 Hz | 60.1 | 2.52 | 41.8 | main guest 822BDE68 0.95, GPU Commands 0.61, GPU Submission 0.26 |
| g-cb1 | -O3, CB-1 (`-fno-ms-volatile` + compiler barriers), ring wait off | 60.7 | 2.37 | 39.0 | main guest 0.98, GPU Commands 0.58 |
| g-cb1b | same, repeated | 55.3 | 2.28 | 41.3 | (Lavender running alongside) |
| g-cb1ring | CB-1 + ring wait 1000 us + read pointer published every 1024 dwords (defaults) | 58.5 | **1.76** | **30.2** | GPU Commands 0.60, GPU Submission 0.25, **main guest 0.24** |
| g-r250 | defaults, ring wait 250 us | 58.0 | 1.79 | 30.8 | |
| g-pub256 | defaults, publish every 256 dwords | 50.9 | 1.56 | 30.7 | |

Another ShiftGlue game was being benchmarked by another session at the same
time, so frames per second varied between 51 and 61 across identical setups.
CPU per frame held steady, so read the results from it:

- **CB-1 is within noise.** 39.0 and 41.3 ms against 41.8. It stays on: it
  matches how the Linux builds already compile, and the barriers keep the
  ordering the game's `sync`/`lwsync` ask for.
- **The ring-space wait (CB-32) saves about a quarter of the CPU.** CPU per
  frame fell from 39-41 to 30-31 ms, and the game's main thread from 0.98 to
  0.24 of a core. Its spin was most of that thread. The 1000 us timeout
  stays: 250 us and more frequent read-pointer writebacks gained nothing.
- **What's left is the GPU front end.** "GPU Commands" (PM4 decode) at 0.6
  of a core and "GPU Submission" at 0.25 now make up half the process.

### The GPU front end is work, not spinning

With the command processor's idle spin and WAIT_REG_MEM yield off
(`--gpu_idle_spin_count=0 --wait_reg_mem_yield_us=0`), "GPU Commands" stayed
at 0.63 of a core and the process at 1.79 cores. That is about 10.5 ms of CPU
a frame for about 2,080 draws, roughly 5 us a draw; FM3-ReGPU quotes about
1 us for its draw thread.

`tools/sample_threads.ps1` samples a thread's instruction pointer about
1,000 times a second and names functions from linker maps (`/MAP`, now on for
every binary). Fifteen seconds of "GPU Commands" on the grid, by share of
wall-clock samples:

| share | where |
|---|---|
| 33.8 % | `ntdll` (waits and syscalls) |
| 10.2 % | `VCRUNTIME140` (`memcpy`/`memset`) |
| 7.3 % | `VulkanCommandProcessor::IssueDrawImpl` |
| 6.0 % | `WriteRegistersFromMem` / `PacketWriteRegistersFromMem` (register loads from memory) |
| 4.3 % | `CommandProcessor::ExecutePacket` |
| 3.2 % | `UpdateBindings` |
| 2.5 % | an EH funclet in `rexgpu-fh1` |
| 1.4 % each | `copy_and_swap_32_unaligned`, `UpdateSystemConstantValues` |
| ~25 % | a long tail of 1 % entries: texture requests, `Fh1NativeExecutor` target binding, shader cache, dynamic state |

"GPU Submission" is 98 % inside the NVIDIA driver and `ntdll`. No single
hotspot: the cost is the per-draw Xenos emulation, spread across the path.

## The generated code was being compiled at -O0

The rebuild for CB-1 came out three times larger (`.text` 36 -> 103 MB). On
the grid it used 4.1 cores at 52-54 fps, with or without CB-1, ring wait or
read-pointer publishing. Two guest threads went from about 0.2 to 0.8 cores
each. The generated units' ninja rules carried no `-O` flag. The SDK adds
`-O3 -DNDEBUG` only in its own directory, and the build cache's
`CMAKE_CXX_FLAGS_RELEASE` was empty. A disassembly sample shows 44 % of
instructions touching the stack, against 1 % in the first build. The
top-level `CMakeLists.txt` now sets the Release optimisation itself.

Lavender Shift's current executable (built 2026-11-17 00:44) shows the same
pattern: 43 % stack instructions and no `-O` on its generated units.

## Known rendering issues seen on the route

- The 2D UI is scaled about 1.25x from the top-left corner. The Dolby splash
  centre lands at (800, 450) instead of (640, 360), and dialogs and the race
  HUD's lap times are clipped at the right edge. The 3D scene is fine.
- The car shadow, road and Montserrat scenery look right. Q18 and Q19 are not
  visible on this route.
