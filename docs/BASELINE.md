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

- The 2D UI is scaled about 1.25x from the top-left corner. The Dolby splash
  centre lands at (800, 450) instead of (640, 360), and dialogs and the race
  HUD's lap times are clipped at the right edge. The 3D scene is fine.
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
