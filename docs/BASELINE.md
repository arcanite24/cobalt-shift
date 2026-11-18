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

Update (2026-11-17, evening): the misses are gone. With the ring-space wait
and the later front-end cuts, the first-run grid at the 60 fps cap measures
60.0 fps, p99 17.17 ms, max 17.48 ms (`bench-d2off`): no frame takes two
vblanks. FM3 takes its time step from the clock, so no frame-time hook is
needed. The cap stays at 60 by default (the least work for low-end
machines); `pinyon_shift_fh1_render_fps_limit=N` gives 2N fps, and above 120
the front end stays at 120 (`cobalt_frontend_fps`, `src/frontend_rate.cpp`).

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

## The GPU side: uploads ended the render passes

Uncapped (`--pinyon_shift_fh1_render_fps_limit=180 --host_present_fps_limit=0
--vsync=false`) the grid ran at 78-87 fps and was GPU-bound. The executor's
GPU profile (`--fh1_native_gpu_profile=true --fh1_native_gpu_profile_draws=true`)
showed 441 renderings a frame, 352 of them ended by
`VulkanSharedMemory::UploadRanges`: every guest-memory upload is a
`vkCmdCopyBuffer`, which can't run inside a rendering. The uploads took about
3.5-5.3 ms of GPU time over about 600 copies, and the main target was begun
245-339 times a frame for 3-4 ms. FM3 doesn't use MSAA on the host here:
`fh1_msaa_single_sample` is already on, and the "2x" in the target key is the
guest's sample count.

The volume was the surprise: about 17 MB a frame, 390 uploads, almost all
vertex data. The write-watch census (`--write_watch_fault_trace=600`) counted
only about 3 faults a frame and no announced writes, so the CPU wasn't
rewriting it. `clear_memory_page_state` (SDK default on) drops the valid bit
of every page the CPU uploaded at each frame end, so all of FM3's geometry
went up again every frame. Write watches already catch real CPU writes to
uploaded pages. Lavender Shift turns it off too, and now Cobalt does.

Clean A/B (c-*), nothing else running, same build and the other current
defaults:

| Run | Change | frames/s | cores | CPU ms/frame |
|---|---|---|---|---|
| c-cap-clear | 60 cap, `clear_memory_page_state=true` | 61.3 | 1.54 | 25.1 |
| c-cap | 60 cap, `clear_memory_page_state=false` | 60.4 | **1.27** | **21.0** |
| c-unc-clear | uncapped, `clear_memory_page_state=true` | 105.0 | 2.43 | 23.2 |
| c-unc | uncapped, `clear_memory_page_state=false` | **117.5** | 3.08 | 26.2 |

At the 60 fps cap the change saves 16 % of the CPU. Uncapped it is 12 % more
frames. Uploads fall from about 17 MB and 390 splits a frame to about 40 KB
and 7 (k-* runs; upload volume isn't affected by other load). Against the
first build on the same grid (41.8 ms with Lavender running, so only roughly
comparable), the 60 fps grid now costs half the CPU per frame. A full-throttle
run with the new defaults renders the moving car and scenery correctly.

### Shared memory the CPU writes (`vulkan_shared_memory_host_direct`)

Before finding the page-state reset, the SDK (`cobalt` branch) gained an
opt-in path: shared memory in device-local, host-visible memory (resizable BAR
here; any memory on an integrated GPU), with uploads `memcpy`'d into it by the
GPU commands thread instead of copied on the GPU. No copy, barrier or
rendering break. With the old 17 MB a frame it removed every upload-ended
rendering (352 -> 0; the main target was begun 6 times a frame instead of 245)
and GPU frame time fell from 15.3 to 11.9 ms under the profiler. Without the
profiler it lost overall, because the GPU commands thread then pushed all
17 MB over PCIe itself: roughly 2.8 ms more CPU a frame. With 40 KB a frame it
measures the same as the copy path (k-unc-direct 92.7 fps, k-cap-direct
26.8 ms), so it stays off. Not cleanly measured: Lavender was running for all
of these, and the 2.8 ms figure comes from a pair where it started mid-run. It is worth trying again on the UHD 620, where
the memory is shared and a GPU copy is pure overhead. It gives up snapshot
semantics: a draw already recorded in the same submission sees the new data.

The executor's profile now also logs uploads by kind (vertex, index, texture,
with bytes repeated within a frame), as the D3D12 executor did.

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

- ~~The 2D UI is scaled about 1.25x from the top-left corner.~~ Not FM3's:
  `tools/window_shot.ps1` was DPI-unaware, so on multivac's 4K display at
  125 % it captured the window's top-left 3072x1728 of 3840x2160, which looked
  like a 1.25x UI clipped at the right. It now sets per-monitor DPI awareness
  and captures the whole window. Screenshots in this file taken on multivac
  before 2026-11-17 evening show that crop.
- The car shadow, road and Montserrat scenery look right. Q18 and Q19 are not
  visible on this route.

## Low-end: blindvac (Intel UHD 620)

blindvac is an ASUS X510UR: Core i5-8250U, Intel UHD 620 (driver
31.0.101.2140), Windows 11. `tools/bench_remote.ps1` runs the same grid
route there over SSH. The game runs in session 0: Vulkan renders and the
frame loop runs, but nothing is displayed. The build goes to `C:\cobalt\bin`
with an app-local VC++ runtime, and the disc to `C:\cobalt\game\disc`. Vulkan
lists the disabled NVIDIA 930MX first and picks it by default. The one run on it
(started in the interactive session) stopped logging during startup, so the
bench passes `--vulkan_device=0` to use the UHD 620. Session 0 shows nothing,
so these numbers don't include presentation, and nothing yet checks the
UHD 620's image.

| Run | Change | frames/s | cores | GPU ms/frame | notes |
|---|---|---|---|---|---|
| s0 | Cobalt defaults | 14.7 | 1.04 | 67.7 | GPU-bound |
| s0-prof | + GPU profile | 11.2 | 1.07 | 88.9 (profiled) | main target 70 ms; one pixel shader 29 ms |
| s0-lodmath | `spirv_implicit_lod_2d` + `spirv_fast_pixel_math` | 13.1 | 1.14 | 76.5 (profiled) | -14 % |
| s0-flatps | + `vulkan_debug_flat_pixel_shaders` (wrong image) | 38.5 | 1.84 | 25.0 (profiled) | pixel shading is ~2/3 of the frame |

Pixel shading is the bottleneck, and one shader stands out: pixel shader
`8FEC358DC5728647` (4 texture fetches, about 20 ALU instructions) takes
25-29 ms over 21 draws on the UHD 620, against 0.17 ms on the RTX 4080. With
flat pixel shaders it costs 1.1 ms. Its draws run with alpha test or
alpha-to-coverage on (modification `...000F`, depth mode `kNoModifiers`), so
the translated shader carries `OpKill`s and has no early fragment tests.
Every covered pixel is shaded, whatever is in front.

Skipping that shader's draws (`fh1_skip_pixel_shaders`, new in the SDK's
`cobalt` branch) changes the frame only a little on the RTX 4080: some white
flowers in the grass and some shading on the rocks go. It is a detail layer.

| Run (no profiler) | Change | frames/s | cores | GPU ms p50 |
|---|---|---|---|---|
| s0 | Cobalt defaults then | 14.7 | 1.04 | 67.6 |
| p-lm | + `spirv_implicit_lod_2d` + `spirv_fast_pixel_math` | 17.9 | 1.17 | 56.0 |
| p-lm-skip | + `fh1_skip_pixel_shaders=8FEC358DC5728647` | **30.5** | 1.59 | 32.8 |
| p-lm-skip-bias | + `texture_mip_lod_bias=1` | 30.7 | 1.57 | 32.7 |

A positive mip bias gains nothing, and on the RTX 4080 it turns the road pink
and noisy: the road's texture has lower mips that aren't plain downscales.
Implicit LOD and fast pixel math look the same as before on the RTX 4080, so
Cobalt now turns both on by default. The skip is the first part of
`--cobalt_low_end=true`, a preset for integrated GPUs (issue #22). At 30.5 fps
the UHD 620 is still GPU-bound (32.8 ms), just past two 60 Hz vblanks. The
rest of the pixel work is spread over many shaders: with flat pixel shaders
the frame is 25 ms.

### The UHD 620's own image

Session 0 shows nothing, so the SDK gained `fh1_capture_output_frame` and
`fh1_capture_output_path`: after that many swaps, the guest output (before
presenter scaling) is written as a PPM. The frame replay (`fh1_frame_replay`
on a dump from multivac) crashes in `memcpy` on the UHD 620, though it runs on
the RTX 4080. Captures from live runs on the grid:

- Defaults: `docs/images/uhd620-grid-default.png`. Correct.
- `--cobalt_low_end=true`: `docs/images/uhd620-grid-low-end.png`. The grass
  flowers are gone, and the two flags above the grandstand turn into black
  shapes: `8FEC` also draws the flag cloth.

The skipped draws, logged once (`fh1_skip_pixel_shaders`): alpha test off,
**alpha to coverage on**, depth test and write on, opaque blend. With
single-sampled host surfaces the SDK emulates alpha to coverage with a
dithered `OpKill` in the shader. That and the depth write rule out early depth
tests, so the UHD 620 shades every covered pixel. Hardware alpha to coverage
(`alphaToCoverageEnable`, no kill in the shader) would fix the cause for every
such draw on any GPU, instead of skipping one shader on one track.

Anisotropic filtering: the SDK forces 4x (`anisotropic_override=3`). The
game's own setting (-1) or off (0) saves about 7 % of the UHD 620's frame
(76.5 -> 71.4 ms profiled). It doesn't change `8FEC`.

The guest output in these captures has the HUD in the right place at the
right size. The "UI scaled 1.25x from the top-left" seen in multivac's window
screenshots is in presentation or window scaling, not in FM3's rendering.

### Alpha to coverage on the UHD 620: the cost is the foliage itself

Three ways to make the alpha-to-coverage draws (cut-out grass, trees, fence
crowds, flags) cheaper, measured unprofiled on the grid (defaults: 17.9 fps):

| Run | fps | Image |
|---|---|---|
| `fh1_debug_alpha_to_mask_off=true` (draw them opaque) | 34.3 | broken: grass tufts as quads, black grid boxes, no fence crowd |
| Pipeline alpha to coverage, shader kill not executed | 27.7 | broken, as above |
| Pipeline alpha to coverage, no kill in the shader | 18.1 | cut-outs right, road corrupted (cyan streaks) |
| Kill kept, no depth write for these draws | 16.7 | not captured |

The results fit overdraw as the cost: an opaque quad hides the layers behind
it, a cut-out one doesn't, and every layer gets shaded. They don't prove it.
The opaque row clears the guest's alpha-to-coverage bit, which other paths
also check. Nothing confirmed that the no-kill row's shaders and pipelines
were the ones intended (no shader dump; the road corruption suggests
something else changed too). The no-depth-write row has no image. So
"hardware alpha to coverage doesn't help on this GPU" holds for these builds
only. What is solid: the low-end preset's skip of `8FEC` (30.5 fps) is the
only change here that kept a usable image, and shading fewer pixels is the
other lever (#23). The hardware path and the depth-write option were not
kept; `fh1_debug_alpha_to_mask_off` stays as a diagnostic.

Per-draw GPU profile (`fh1_native_gpu_profile_draws`, profiled so slower
overall), emulation on vs `fh1_debug_alpha_to_mask_off`: `8FEC` 24.4 ms ->
1.5 ms over its 21 draws a frame. The next alpha-to-coverage shaders move by
1-2 ms (`033347E3` 3.9 -> 2.1, `1B9530D4` 1.9 -> 0.7). The cost is one shader,
so a per-shader lever fits this track. Whether other tracks have their own
`8FEC` is not measured.

`--cobalt_low_end=true` with `anisotropic_override=-1` added: 31.4 fps
unprofiled (30.3 without it).

Between all and none: `fh1_skip_pixel_shaders_keep_every=N` still draws one
in N of the matching draws. With the low-end preset:

| `8FEC` draws kept | fps | Image |
|---|---|---|
| all (defaults) | 17.9 | full |
| 1 in 2 | 23.0 | |
| 1 in 3 | 24.9 | `docs/images/uhd620-grid-keep3.png`: flowers mostly there, flags right |
| none (preset) | 31.4 | flowers gone, two flags black |

Only skipping them all holds 30 fps, so the preset keeps that. Keeping 1 in 3
is the option for a better image on the same GPU.

Car moving (`bench_remote.ps1 -Drive`: the throttle held from the race
start, no steering, so the car ends up somewhere along the first straight or
at the first turn; no image, the capture swap was never reached):

| Run | fps | p99 frame |
|---|---|---|
| defaults | 28.1 | 50.1 ms |
| `--cobalt_low_end=true` | 37.3 | 34.1 ms |

Away from the grid the scene is lighter, and the preset stays above 30 fps.
Other tracks are not measured yet.

## Uncapped on multivac, current defaults (2026-11-17, evening)

Same grid, `--pinyon_shift_fh1_render_fps_limit=180 --host_present_fps_limit=0
--vsync=false`, at the current defaults (with `spirv_implicit_lod_2d` and
`spirv_fast_pixel_math` on, added after the c-* table above):

| `gpu_read_pointer_publish_dwords` | fps | p99 frame |
|---|---|---|
| 1024 (default), two runs | 206.5, 215.4 | 7.4 ms |
| 4096 | 216.0 | 7.3 ms |
| 16384 | 219.8 | 7.1 ms |

The publish interval is within run-to-run noise, so the default stays. The
limit is the GPU Commands thread at 0.99 cores. The GPU frame is about 5 ms,
with idle gaps waiting for the CPU.

Sampled (`tools/sample_threads.ps1`, which now names exports in modules
without a map, such as ntdll and the driver), the thread's time spreads over
the draw path: `IssueDrawImpl` 10 %, `ExecutePacket` 7 %, `UpdateBindings`
6 %, register writes from memory 8 %, memcpy about 6 %, and
`NtAlertThreadByThreadId` (waking another thread) 6 %. Write-watch protection
costs about 84 µs a frame. No single item is large: the remaining CPU levers
are the per-draw cuts already filed (#9, #11, #14).

For #3: FM3-ReGPU reports 300-360 fps in races on a 9800X3D + 7900 XTX at
1440p 4x MSAA. This is 215 fps on a 5800X + RTX 4080 at 720p. That's not the
same machine or scene, so it doesn't decide anything. The like-for-like run
needs FM3-ReGPU built here.

### Split command thread (`gpu_record_thread`)

The submission settings changed nothing (`vulkan_submit_on_primary_buffer_end=false`:
214.5 fps; plus `vulkan_async_submission_split_draws=0`: 222.8). Splitting
the GPU commands thread did: one thread decodes the guest's command stream,
a second applies register writes and records draws (Pinyon's LP-1.1).

| Run | fps | p99 frame | cores busy | CPU per frame |
|---|---|---|---|---|
| uncapped, one thread | ~215 | 7.4 ms | 2.9 | 13.4 ms |
| uncapped, `gpu_record_thread=true` | 282.0 | 5.6 ms | 4.06 | 14.4 ms |
| uncapped, automatic (below) | **292.7** | 5.3 ms | 4.05 | 13.8 ms |
| 60 fps cap, one thread | 60.0 | 17.1 ms | 1.04 | 17.1 ms |
| 60 fps cap, `gpu_record_thread=true` | 60.0 | 17.1 ms | 1.21 | 20.1 ms |
| blindvac low-end, one thread | 31.4 | | 1.44 | |
| blindvac low-end, `gpu_record_thread=true` | 33.1 | 34.5 ms | 1.69 | 51.1 ms |

The image is unchanged (`bench-unc-rec.png`). Cobalt now turns it on by
itself when `pinyon_shift_fh1_render_fps_limit` is above 30 (the frame cap
raised) and `cobalt_low_end` is off. At the default cap it would only cost
CPU, so it stays off there; the command line or config file still decides
when set.

Sampled with the split (uncapped, 293 fps): the decoder spends about 30 % of
its samples sleeping or waiting (`ZwDelayExecution` 20 %,
`ZwWaitForAlertByThreadId` 11 %), so it is no longer the limit on its own.
Its busy part is register writes from memory (`PacketWriteRegistersFromMem`
13 %, `RecordRegisterRun` 5 %, `FindRegisterChange` 4 %). The recorder:
`IssueDrawImpl` 14 %, `UpdateBindings` 7 %, waits and wakes 14 %. The rest
is the hand-off between the guest render thread, decoder and recorder, plus
the per-draw cuts already filed (#9, #11).

## Untiled scene and FM3-ReGPU's cuts (2026-11-17)

`fh1_untile_predicated_tiling` (SDK; on by default only on Linux and macOS)
draws FM3's predicated-tiling scene once instead of once a tile. Cobalt now
turns it on. On multivac, grid route:

| Run | fps | CPU per frame | cores busy | draws/frame |
|---|---|---|---|---|
| uncapped, tiled | 250.0 | 16.1 ms | 4.03 | 1,975 |
| uncapped, untiled, two runs | 265.1, 256.3 | 14.7, 15.0 ms | 3.89, 3.84 | 1,502 |
| 60 fps cap, tiled, two runs | 60.0 | 31.7, 31.3 ms | 1.95, 1.89 | |
| 60 fps cap, untiled, two runs | 60.0 | 29.5, 17.1 ms | 1.79, 1.03 | |

The images match (`bench-capA.png`, `bench-capT.png`). The cap runs are
noisy, but every untiled run used less CPU.

### Menus cut untiled, and the 2X-only fix

The menus showed it first: untiled, My Cars and Quick Upgrade lost
everything below guest row 320 (the car, the stat bars, the lower half of
dialogs), and stale background showed through. With
`fh1_untile_predicated_tiling=false` they were whole. The race and the
menus both tile in 256/256/208-row bands, but the race tiles a 2X MSAA
surface (`RB_SURFACE_INFO` 0x14010500) and the menus and the garage's car
tile at 4X (0x14020500).

For a while the SDK's `fh1_untile_msaa_mask` (bit per guest MSAA mode)
kept the 4X tilings tiled, with Cobalt setting it to 2. The cause turned
up in a draw log of Quick Upgrade. Between its UI layers each tile has a
depth-only draw (EDRAM mode 5) predicated on that tile's bins alone, at
window offset 0, in the tile's own EDRAM rows. Untiled, the first tile
left the later tiles' copies to their passes, where they hit the first
tile's rows. Below row 256 depth was never reset, and later layers failed
the depth test there. Disabling the shared 4X depth alias didn't help.

The SDK now records each later tile's screen rows from its pass's window
offset. The first tile runs a draw predicated on one later tile in that
tile's rows, and that tile's pass drops it. With all MSAA modes untiled
again (the SDK's default mask, 7), My Cars and the main menu match the
tiled image.

The race doesn't change. At 720p it untiles only its 2X scene, and its
4X targets (mirror and reflection sizes) aren't tiled. Uncapped on the
grid, mask 7 measured 178 and 179 fps and mask 2 189 and 192. Aligned on
race start, though, 30-second segments vary by ±15 % in both and neither
leads. Ladera at 960x540 (low-end) tiles 2X too, and skips about 1,500
draws a frame either way with the whole HUD.

`src/render_rates.cpp` ports four of FM3-ReGPU's cuts, all hot-reloadable
and off by default:

- `cobalt_shadow_rate`: car shadow maps every Nth frame.
- `cobalt_reflect_rate`: the cars' reflection cube faces every Nth time.
- `cobalt_mirror_rate`: the rear-view mirror every Nth frame.
- `cobalt_far_car_lod`: detail level for AI cars beyond the nearest two.

On multivac uncapped, shadows and reflections at rate 2 took the draws from
1,975 to 1,875 a frame, but the fps change (264 -> 272) is within noise. On
blindvac with the low-end preset and vsync off (two runs each):

| Run | fps | p95 frame | cores busy |
|---|---|---|---|
| low-end | 30.4, 30.2 | 34.2, 34.2 ms | 1.59, 1.47 |
| + untiled | 30.2, 29.4 | 34.8, 47.7 ms | 1.46, 1.48 |
| + untiled + cuts (2, 2, 2, LOD 3) | 31.4, 31.5 | 33.9, 33.9 ms | 1.56, 1.40 |

The UHD 620 is GPU-bound here, so untiling saves only a little CPU. The
cuts add a frame a second and remove the 48 ms frames, so `cobalt_low_end`
now sets all four. Shadows, reflections and the mirror can be one frame old;
mid-distance AI cars lose small details. With the new defaults, plain
`--cobalt_low_end=true` (vsync off) ran 32.2 and 32.3 fps, p95 33.9 ms, 1.57
and 1.47 cores.

## Scene size 960x540 (#23, experimental, 2026-11-17)

`--cobalt_scene_size=960x540` renders the race scene at 960x540 the way
Pinyon Shift does for FH1 (`src/scene_size.cpp`): FM3's tiling bands are
scaled, and at the end of its screen setup (`sub_822A5670`) the screen
textures' fetch sizes are shrunk to the scene size while their memory stays
720p. The renderer's screen size is set to it too, so viewports follow and
the presenter scales the smaller front buffer up. Off by default.

blindvac (UHD 620) with `cobalt_low_end`, parked on the grid, 30 s:

| | fps | frame ms p50 / p95 / p99 | cores |
|---|---|---|---|
| 1280x720 | 32.6 | 33.2 / 33.8 / 34.3 | 1.50 |
| 960x540 | 44.3 (+36 %) | 18.0 / 33.5 / 33.8 | 1.98 |

Frames land on one or two 60 Hz vblanks, so 540p alternates between 60
and 30 fps here.

### The HUD at 540p (fixed)

The UI lays out at 960x540, but two parts of the HUD went missing:

- **Gear and speed readout:** the HUD is drawn in the same two tile bands as
  the scene, and the game picks which band draws each element from its 720p
  position. The gear and speed fell outside the scaled bands they were drawn
  in. Drawing the scene once (`fh1_untile_predicated_tiling`, now the
  default for the race's 2X tiling) draws the whole HUD in the first band,
  and they show.
- **Minimap:** it is the one element that sets its own viewport, through
  D3D's `SetViewport` (`sub_824B4068`, called from 0x827B5EF8), in 720p
  screen pixels: {63, 502, 193, 186}. D3D clips the viewport to the
  960x540 target and derives the scissor from it, so the map was cut to a
  strip at the bottom edge (or nothing, untiled). Cobalt scales that one
  call to the scene size and the minimap draws in place.

How it was found: `fh1_debug_log_draws` for a few frames at 720p and 540p
showed the minimap's draws carrying a scissor of (63,502)-(256,688) in
720p pixels. Hooking D3D's scissor path (`sub_824B1120`, the per-tile
intersection; `sub_824B36D8`, `SetScissorRect`; `sub_824B3E00` and
`sub_824B4068`, `SetViewport`) and logging callers found the viewport. The
other non-zero viewports are 128x128 tiles in 512x512 targets and already
at their own sizes. `cobalt_viewport_log` logs the viewports and callers.

"PLACE" next to the position is a label that fades in and out, at both
sizes. One 540p capture out of five (frames 8700-9600) came out darker, with a
warm cast toward the right: the whole frame's colour shifted, not a band,
so likely an exposure state caught mid-change. Not seen at 720p.

With the HUD complete, blindvac (UHD 620, `cobalt_low_end`, vsync off, 30 s):
960x540 ran 38.9 and 39.4 fps (1.93, 1.90 cores) against 32.4 fps (1.62
cores) at 720p in between, +21 %. p95 frames stay at 33.7-33.9 ms.

`cobalt_low_end` now sets `cobalt_scene_size=960x540` (the command line or
config file still wins; `--cobalt_scene_size=` keeps 720p). Plain
`--cobalt_low_end=true` with vsync off: 40.4 and 38.7 fps on blindvac.

Diagnostics: `cobalt_scene_probe` logs the headers, and
`cobalt_scene_keep_mask` leaves chosen ones at 720p.

## Another track: Season Play at Ladera (#24, 2026-11-17)

FM3 repeats its first-run flow until the opening race is finished, which a
scripted pad can't drive. `cobalt_ai_player` (`src/ai_player.cpp`, from
FM3-ReGPU) lets the race AI drive the player's car, so
`tools/make_seed.ps1` plays the first run and the next races with the pad
pressing A through the menus, and saves the profile as a seed
(`.local/seeds/after-first-race`, not in the repo). After about 20 minutes
it had finished the opening race, picked the Ford Fiesta Zetec S and won
FWD Open race 1 at the Iberian Short Circuit.

`tools/bench_race.ps1 -Route season` (and `tools/bench_remote.ps1 -Route
season`, seed in `C:\cobalt\seeds`) restores the seed each run, walks
title > MAIN MENU > GO RACE > SEASON PLAY into the next event, FWD Open race
2 at Ladera Test Track, Short Circuit Reverse, and measures 60 s from about
255 s in, with the AI racing the Fiesta among seven cars. Two things about
the menus: they hide after a few idle seconds, and the next press only
shows them again, so the route doubles the presses that may meet a hidden
menu; and A is the title screen's button, not START.

| Machine, settings | fps | frame p95 | cores | draws/frame |
|---|---|---|---|---|
| multivac, defaults (60 cap) | 60.0 | 17.1 ms | 1.20 | 2,285 |
| multivac, uncapped | 268.7 | | 3.97 (14.8 ms CPU/frame) | |
| blindvac, `cobalt_low_end`, vsync off, two runs | 37.7, 38.3 | 33.7 ms | 2.26, 2.30 | |

The first blindvac numbers here (29.8 fps, 0.98 cores) measured the
pre-race flyover, not the race. blindvac loads Ladera later than multivac,
and the route's last A presses came during the load. The remote route now
presses A eight more times, 8 s apart, and a capture of frame 11,500 shows
the race with the whole 540p HUD (`remote-fix-m2.png`). The flyover tiles
a 4X surface, while the race tiles 2X as on multivac. The two runs above
are with 4X tilings untiled and kept tiled (`fh1_untile_msaa_mask` 7 and
2); the race doesn't differ.

Low-end levers in the race on blindvac (one run each, against the two
above):

| Change | fps | frame p50 / p95 |
|---|---|---|
| `vulkan_shared_memory_host_direct` (uploads written by the CPU), two runs | 37.5, 38.4 | 31.5 / 33.8 ms |
| scene at 800x450 | 41.3 | 18.9 / 33.6 ms |

Writing uploads from the CPU removed few rendering breaks (113 -> 105 a
frame) and gained nothing, so it stays off. MSAA was already single-sampled
on the UHD 620. Shading in the 2X scene takes about 28 ms of the profiled
41 ms of GPU time, spread over many shaders (the heaviest is 2.3 ms), so
pixel count is the lever. `cobalt_low_end` now renders the scene at
800x450 (`remote-450.png`: the whole HUD and the minimap).

Ladera's road showed blocky bands over the asphalt and run-off
(`bench-ladA.png`). Untiling, `spirv_implicit_lod_2d`,
`spirv_fast_pixel_math` and the texture cache's packed-mip keys and
band/layer reloads didn't matter. FM3-QUIRKS Q18 was the cause. When a
track loads, FM3 renders road strips (32x512; Ladera resolved 128) and its
CPU code compresses them to DXT1 to compose the road's detail image. The
SDK kept those resolves on the GPU, so the CPU compressed stale memory.
The SDK's `fh1_readback_resolve_sizes` now reads chosen color resolve
sizes back to guest RAM before the next CPU-visible fence. Cobalt lists
the strips and the car pictures (512x256, 256x128), as FM3-ReGPU does. The
asphalt is right now (`bench-ladRB.png`).

Ladera renders its 128 strips again all race, one every other frame. Each
readback makes the CPU wait for the GPU at the next fence, which cost
blindvac's measurement 1-3 fps. The CPU doesn't read those re-renders: read
back only once per address, the road stayed right. The SDK's
`fh1_readback_resolve_quiet_frames` (Cobalt: 600) reads an address back only
after 600 frames without a resolve to it. On multivac the load's burst was
read back (229 readbacks) and nothing during the race, where each address
is resolved again about every 256 frames.
The start line's painted checks still have stair-stepped edges, which
look like a point-sampled mask; that needs a console reference.

The log's `PM4_DRAW_INDX_2 ... Failed in backend (edram_mode=6)` errors,
one to three a frame, were resolves the SDK skipped: FM3 resolves a 16_16
color target into a 16_16 texture (`c4->t25`, 1X and 4X), and the executor
had no 16_16 destination. The resolve shader now writes one (pack 7: the
target's snorm words, the samples averaged), and a Ladera run logs no
skipped resolves and no draw failures.

## Per-draw constants in VRAM (#17, 2026-11-17)

`--vulkan_device_local_uniform_memory=true` (SDK) puts the per-draw uniform
pages in host-visible device-local memory (Resizable BAR on multivac's RTX
4080: memory type 4) instead of host-cached system memory (type 3), as
FM3-ReGPU's VRAM upload ring does. Uncapped grid on multivac
(`pinyon_shift_fh1_render_fps_limit=180`, no vsync), alternating:

| Run | off | on |
|---|---|---|
| 1 | 262.3 fps, 13.99 ms CPU/frame | 251.7 fps, 14.21 ms |
| 2 | 247.0 fps, 15.06 ms | 255.7 fps, 14.47 ms |

No difference beyond run-to-run noise: the grid is limited by the CPU
(about 3.8 cores busy), not by the GPU reading constants over PCIe. On the
UHD 620 all memory is already device-local. The switch stays off.

## Disc 2 content in game (2026-11-17)

With Disc 2 installed (`src/disc2_content.cpp`), FM3 lists the eight
packages, opens them as `DLCRoot0`-`DLCRoot7` and no longer asks for the
disc. Each package's `Media\DLCZips\zipmount.xml` names archives the game
mounts as folders (package 0060: Amalfi, Fujimi Kaido and Nürburgring
tracks; 0045: Nürburgring GP, the physics and test tracks, track images;
the others string tables, engine and harmonic tuning, thumbnails). Hiding
0060's `zipmount.xml` makes the boot log `FAILED: DLCRoot7:\media\dlczips\
zipmount.xml`, so the game reads every mount list at boot; the archives
themselves open on first use (hiding `FujimiKaido_pri_65.zip` logs nothing at
boot). With everything in place the failed opens were `stringtables.xml` in
three packages (an optional probe) and `<id>_pri_65mediadbpatch`.
The `<id>_pri_65\media\db\patch\` failures were not optional: those
folders are where FM3 looks for each package's database patches
(`*_merge.slt`, `*_execute.sql`: the DLC cars' and Disc 2 tracks' rows, and
`IsInstalled=1` for them), which ship only inside `<id>_pri_65.zip`. Cobalt
now unpacks them next to each zip once (15 files, stored or Xbox LZX), as
FM3-ReGPU does (its session 18; found by the FM2 port). With them in place
those opens succeed; the remaining `...\media\db\patch\` probes are for
the other archives, which have none.

A Season Play race at Ladera with Disc 2 on (patches applied) against off,
multivac, 60 fps cap, 30 s:

| Run | fps | p99 | cores | CPU per frame |
|---|---|---|---|---|
| Disc 2 on | 60.0 | 17.15 ms | 1.92 | 31.5 ms |
| Disc 2 off | 60.0 | 17.12 ms | 1.11 | 18.3 ms |
| Disc 2 on, again | 60.0 | 17.16 ms | 1.06 | 17.4 ms |

The first run's extra CPU was the main guest thread (822BDE68) at a full
core; it didn't repeat (0.23-0.29 in two later runs, mostly waiting when
sampled). Disc 2 costs nothing in a race. A busy main thread now and then is
worth watching for on any route.

Not yet seen: a race on a Disc 2 track (the seeded profile's events are
locked and its menus have no Free Play).
