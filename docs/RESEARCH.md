# Cobalt Shift: performance research

Written 2026-11-16. Cobalt Shift will be a native port of **Forza
Motorsport 3** (Xbox 360). It follows Pinyon Shift (FH1) and Lavender
Shift (FH2). This page answers one question: what can FM3 take from the
newest 360 recomp work to get **absolute performance and lower hardware
requirements, ahead of correctness**?

Nothing was built or run for FM3. All figures are other projects'
measurements, cited by file. **(est.)** marks an estimate. Item prefix:
**CB-**.

## Sources studied (pinned)

| Repo | Commit | What it is |
|---|---|---|
| [braaap-stututu/FM3-ReGPU](https://github.com/braaap-stututu/FM3-ReGPU) | `1b26d9e` (2026-11-17) | FM3 on XenonRecomp + ReGPU. MIT. About 40 AI-driven sessions, 72 ReGPU patches, 5 XenonRecomp patches |
| [zer0ducksgiven/ReGPU](https://github.com/zer0ducksgiven/ReGPU) | `7320e6a` (2026-11-12) | D3D12-only Xenos GPU layer, taken out of the FM2 port. MIT |
| [zer0ducksgiven/Glue2GPU](https://github.com/zer0ducksgiven/Glue2GPU) | `ad39270` (2026-11-10) | ReGPU as a ReXGlue GPU plugin (`--gpu_plugin=regpu`). MIT |
| [zer0ducksgiven/ReXenon](https://github.com/zer0ducksgiven/ReXenon) | `171c866` (2026-11-16) | XenonRecomp fork with relaxed-atomic guest memory. MIT |
| [zer0ducksgiven/Forza-Motorsport-2-ReGPU](https://github.com/zer0ducksgiven/Forza-Motorsport-2-ReGPU) | `0aa44a3` (2026-11-16) | The FM2 port that ReGPU came from |
| [zer0ducksgiven/PGR4-ReGPU](https://github.com/zer0ducksgiven/PGR4-ReGPU) | `6d777f7` (2026-11-08) | PGR4 port. Source of several ReGPU CPU cuts |
| [0herculabs/hl360-forza3](https://github.com/0herculabs/hl360-forza3) | `8612130` (2026-10-17) | FM3 on stock ReXGlue with D3D12. **No licence: read it only, never copy from it** |
| [rexglue/rexglue-sdk](https://github.com/rexglue/rexglue-sdk) | `ebac1cf` (2026-11-14) | Upstream ReXGlue v0.11.0 |
| ShiftGlue (our fork) | `537b2b64` | As used by Lavender Shift |

FM3-ReGPU uses the same `default.xex` we would use: Ultimate Collection
USA, title ID `4D53084D`.

## Answer in short

1. **One check turned up a likely CPU win that applies to our own SDK
   today (CB-1).** ShiftGlue emits every guest load and store as a
   `volatile` access (`REX_LOAD_U32` in the codegen PCH template). Our
   Windows clang++ turns on **`-fms-volatile` by default**; we checked
   it with `clang++ -###` on the bundled LLVM 20.1.8. That flag gives
   every guest access acquire/release semantics, so the compiler keeps
   the PPC context in memory around each one. ReXenon replaced these
   accesses with relaxed atomics and measured **−17 % main-thread CPU
   and +10–30 % fps on a Ryzen 7 5800X**, the same CPU as multivac. The
   first A/B is one flag (`-fno-ms-volatile` on the generated units).
   It also concerns FH1 and FH2. Android and Linux builds are not
   affected: the flag is on by default only for x86 MSVC targets.
2. **The stack decision is the user's and should be settled by a
   measurement.** There are two routes; see
   [The fork in the road](#the-fork-in-the-road).
   - **Route A:** ShiftGlue with Vulkan, which keeps one SDK, Vulkan on
     every platform, and Linux, Deck and Android.
   - **Route B:** ReGPU through Glue2GPU, on D3D12 and Windows only.
     It is about 2.2x faster at 1440p and 4K on strong GPUs, but its
     CPU side loses on weak laptops.
3. **Stage 0 has a blocker on Route A.** Two independent projects report
   that ReXGlue's Vulkan backend does not render FM3 correctly
   (hl360-forza3 README; FM3-ReGPU `FM3-QUIRKS.md` Q21). They also
   report that `readback_resolve=full` caps FM3 at 30 fps (Q18). Nothing
   else can be measured until FM3 renders on Vulkan.
4. **FM3 is Turn 10's engine, not Playground's.** FH1 and FH2 grew out
   of it, but nobody has measured how much code they share. Every
   FM3-ReGPU hook at a game address (half-rate passes, one tile, ring
   wait, LOD) is an idea only until we find the function in our own
   dump. Run an LV-0.2-style masked-hash comparison against FH1 first
   (CB-0.2).
5. **FM3-ReGPU's lesson matches Pinyon's.** On a fast PC the limit is
   CPU work per draw (about 1.0–1.4 µs a draw over 2,300–3,100 draws),
   not the GPU. Their biggest early loss was a fence-latency chain
   between the command processor and the host GPU: about 70 fps near
   cars, about 150 after fixing it. Their quote: "the lever for weak
   CPUs is less total CPU work per frame, not more threads."

## The fork in the road

| | Route A: ShiftGlue + Vulkan | Route B: ReGPU via Glue2GPU |
|---|---|---|
| Graphics API | Vulkan everywhere | **D3D12 only**. Linux only through vkd3d-proton, which hangs the GPU about 2 s in on RADV (ReGPU `docs/linux-vkd3d-proton.md`). No Android or macOS |
| FM3 status | **Renders wrongly** on ReXGlue's Vulkan backend (Q21, hl360). Needs a stage-0 fix | Renders well; FM3-ReGPU ships at 300–360 fps at 1440p 4x on a 9800X3D + 7900 XTX |
| Fast GPU, high resolution | FH1 on ReXGlue D3D12, RTX 4070: 1440p 67 fps, 4K 36 | Same machine: 1440p 91, 4K **79–86** (Glue2GPU README) |
| Weak, CPU-limited laptop | FH1R's own Vulkan renderer: 52 fps (GTX 1650 Ti) | ReGPU: 36 fps; "its limit there is its CPU side" (secondhand, from FM3-ReGPU `RESEARCH.md`) |
| EDRAM | Xenia-style: exact formats, ownership transfers (30–37 % of the GPU frame in FH1R) | One RGBA16F host surface per EDRAM base, D32S8 depth, no transfers. Less exact, much cheaper |
| Our rules | Fits: one SDK, Vulkan, handhelds | Breaks "Vulkan everywhere" and the handheld targets |
| Code size | about 254k lines of renderer (Glue2GPU's count) | about 16–21k lines; one main author |

**How to decide (CB-0.3).** Run one frozen-world scene on both routes:
- on **multivac** (5800X + RTX 4080) at 1440p and 4K;
- on **blindvac** (ASUS X510UR laptop, Intel UHD 620), the homelab's low-requirements
  machine, at 720p.

Record fps, p99, CPU cores and GPU ms. Route A can be measured only
after stage 0. Until then, FH1 on Glue2GPU against FH1 on ShiftGlue is
a proxy, since Glue2GPU already runs FH1.

A hybrid is possible: Route A everywhere, plus Glue2GPU as an optional
plugin for high-end Windows. Most items below work on both routes,
because they are ideas for a GPU front end rather than ReGPU code.

## Item catalog

Tags:
- **[SDK]** goes in ShiftGlue's codegen, runtime or GPU front end. Works
  on Route A, and as an idea on Route B.
- **[HOOK]** is a hook on an FM3 function. The FM3-ReGPU address helps
  locate it, but we must find it in our own dump.
- **[BUILD]** is a toolchain change.
- **[ReGPU]** works only on Route B.

Buckets:
- **New** to us.
- **Re-measure**: we measured it before, but another project disagrees.
- **Have**: already in ShiftGlue or Lavender.
- **Skip**: several projects measured a loss.

Unless noted, figures in the "Their result" column are FM3-ReGPU's own
(`PERF-PLAN.md` / `PERF-RESULTS.md`). They were measured on a 7900 XTX
at 200–360 fps, where the CPU is the limit, and will not translate
one-to-one to a 4080 at 60 fps.

### Stage 0 (blocks everything)

| ID | Item | Why |
|---|---|---|
| CB-0.1 | Dump `default.xex` (UC USA `4D53084D`, the version FM3-ReGPU uses), generate it with ShiftGlue, boot it | Baseline |
| CB-0.2 | Masked-hash comparison of FM3 against FH1 v4 and FH2 TU2 (code bytes, functions, shader files) | Shows which Pinyon and Lavender seams carry over |
| CB-0.3 | Fork-in-the-road benchmark (above) | Decides the route |
| CB-0.4 | Fix FM3 rendering on ShiftGlue Vulkan. Start from hl360's notes (read only): `readback_resolve=fast`, and the SDK `vsync` cvar stays on because it is the console vblank timer. Also the Xenia Canary fixes for square shadows and the road, such as `c02060f22`, which downscales resolve readback above 1x | Route A cannot be measured without it |
| CB-0.5 | Frozen-world benchmark scene and live A/B switches, like FM3-ReGPU's "frozen grid" plus `tools/fm3_ab.ps1` | Their method made 1–3 % effects measurable. Our Lavender results show 9 % run-to-run noise |

### CPU codegen and build

| ID | Item | Their result | Trade | Bucket |
|---|---|---|---|---|
| **CB-1** | **Guest loads and stores without MS volatile semantics.** Step 1: `-fno-ms-volatile` on the generated units. Step 2: ReXenon's relaxed `std::atomic_ref` loads and stores | ReXenon/FM2: **−17 % main-thread CPU, +10–30 % fps (5800X)**; 1–2 % on an FX-8350 | Ordering comes only from guest `sync`/`lwsync`/`eieio`. Under ISO volatile x86 still keeps hardware TSO; ARM64 needs explicit fences. Pinyon's "stack without volatile, 7–9 % slower" was a different change and does not rule this out | **New [SDK/BUILD]**, also FH1/FH2 |
| CB-2 | Pin the load address and link order when benchmarking (disable ASLR for A/B builds) | ReXenon: placement moved fps 3–10 %, more than most micro-optimisations | none | **New** (method) |
| CB-3 | PGO on the GPU front end and runtime only, not the game code | FM3-ReGPU: +3.2 % on the ReGPU target. Game-code PGO +0.4 %, dropped. Glue2GPU: about +6 % | Profile goes stale (theirs did) | **Re-measure**: Pinyon measured PGO at −0.13 to −0.72 %, but over everything |
| CB-4 | Fixed FP mode on x86 | Lavender: process CPU 104.0 → 86.6 ms a frame in AI free roam (one run, inside 9 % noise) | Rounding and denormals differ | **Re-measure**: rejected as a default under exactness rules; perf-first rules make it a candidate again |
| CB-5 | Trusted-ABI profile (planned LV-0.5) and lean memory macros without MMIO checks (LV-0.7) | Pinyon est. 0.6–1.6 ms on the Odin; MMIO checks 3.2 % of the Odin process | Breaks hooks that read dead registers | Planned in Lavender, not built |
| — | `non_volatile_as_local`, `-mavx2` on the game code, draw-thread priority, thread pinning on desktop | Pinyon −20 to −27 %; FM3 none; FH1R −1.3 % | — | **Skip** |

### GPU command processing (CPU side of the GPU)

| ID | Item | Their result | Trade | Bucket |
|---|---|---|---|---|
| **CB-6** | **Fence order off.** Don't drain every fence through the host GPU at each INTERRUPT packet | Near cars, 120 cap: **69–77 → 100–120 fps**, worst frame 17–19 → 11–13 ms | An interrupt can arrive before an older fence; no symptom seen | **New [SDK]** |
| **CB-7** | **Early fences** written when the CP reaches them, except fences behind a deferred write-back | Grid **117 → 147–153 fps** | The title may reuse memory early; the write-back exception keeps liveries correct | New on desktop (Pinyon has a related Odin item; check) |
| **CB-8** | **Register-write skip.** Shadow the register file and forward only changed words (about 29 % of about 660k writes a frame change) | **+8.1 %** CPU-bound (5/5 rounds) | none | **New [SDK]** |
| CB-9 | Drop exact repeat shader loads (55 % of about 2,200 a frame) | +2.4 % | none | New [SDK] |
| **CB-10** | **Async present.** Close, submit, Present and the frame fence run on the submission thread; the next frame records without waiting | **+17.9 %** CPU-bound, +4.3 % at 1440p 4x, byte-identical | Up to one more frame of latency | **New [SDK]**: check against ShiftGlue's async submission first |
| CB-11 | Fewer wakes: notify only when the other side waits; read the clock every 4096 calls; one index view over the arena (`IASetIndexBuffer` 1,985 → 9 a frame) | CP 75.9 → 64.1 % of a core | none | New [SDK] |
| CB-12 | Index cache swept gradually instead of cleared at 8,192 entries | Removed a **77–82 ms hitch once a lap** | none | New [SDK]: check whether ShiftGlue has the same cliff |
| CB-13 | Texture checks staggered (unchanged textures rechecked every 4th or 16th frame); big dynamic index buffers read in place | 108 → 120 fps; texture checks 0.46 → 0.33 ms, indices 0.43 → 0.16 ms | A texture may be stale for a few frames | New [SDK] |
| CB-14 | Memoise per-draw work: pass-scale epoch, vertex-cache answer, `getenv` and lock cuts | +3.8 to +4.6 %, +3.6 %, +2.2 %, +2.8 % | none | New [SDK] (ideas) |
| CB-15 | Light perf log: one record a frame through a lock-free queue | The full log cost 18–25 % fps; light ≈ 0 | — | New (method) |
| — | Draw workers or parallel segments; constant-block reuse; `SUBMIT_DRAWS` (+5.3 % CPU-bound, −5.7 % GPU-bound) | −2 to −12 % | — | **Skip**: same as Pinyon's parallel recording |

### Shaders and pipelines

| ID | Item | Their result | Trade | Bucket |
|---|---|---|---|---|
| **CB-16** | **Alpha-test-free pixel shader variants**: no run-time `discard` when the alpha test is off, which keeps early-Z | **+4.1–5 %**, byte-identical | More variants | **New [SDK]** |
| **CB-17** | **Vertex-shader corners fix**: remove the run-time-indexed `float4 vq[3][16]` array the translator emits (it goes to scratch, 240–255 VGPRs) | **iGPU +10.2 to +14.5 %**, exact | none | **New [SDK]**: check whether our SPIR-V translator has the same array |
| CB-18 | Fetch-constant specialisation with literals (`TFetch2DK` / `TFetchK`), up to 64 variants a shader | Car paint 236 → 41 samples; races 1440p +3.6 %, 4K +9 %, **iGPU 720p +26.9 %** | Variant explosion; base shader used until a variant is ready | **Have** (Pinyon fetch variants). Extend to cube and 3D textures, and compare coverage |
| CB-19 | Packed constants: renumber `c[N]` by use so a draw writes one contiguous run | −3.5 % per draw; races ±0 | First-boot recompile | New, low priority |
| CB-20 | Static shader scan of the game's `.fxobj` files + pipeline seed recorded by an automated tour of every track + scan-confirm | 0 unseeded pipelines in menus; cold first boot about 35 s | Long first boot | **Have** in part (Lavender AOT catalog). Add the automated tour and the `.fxobj` scan |
| CB-21 | Offline ISA statistics (Radeon GPU Analyzer: VGPRs, samples, code size) to find shader hot spots | Found CB-17 and the L30 items | — | New (tool). Works on SPIR-V too |
| CB-22 | IEEE multiply instead of Xenos 0×inf=0, per shader | +1.8–2.7 % | Global use turns crowd flags black; needs a per-shader allow list | Re-measure (Pinyon has the per-shader rule) |
| — | Optimised FXC level 1 (−6 %); 16-bit `min16float` (slower on RDNA2, blocky); a global plain multiply | — | — | **Skip** |

### Memory, uploads, textures

| ID | Item | Their result | Trade | Bucket |
|---|---|---|---|---|
| **CB-23** | **Per-draw upload ring in VRAM**: Vulkan `DEVICE_LOCAL \| HOST_VISIBLE` (Resizable BAR), written sequentially and never read. **Only after cutting bytes per draw** (sparse fetch table, skipping unread constant blocks: 2,996 → about 1,060 bytes a draw) | After the cuts: grid +26.3 %, races +18 %, 4K +22 %; 720p −0.8 %. **Before the cuts: races −13 %** | Writes over PCIe hurt when the CPU is the limit; needs ReBAR; keep a fallback | **New [SDK]**. Their `docs/VRAM-UPLOAD-RING.md` has a Vulkan section |
| CB-24 | Vertex arena: big vertex buffers in a 512 MB VRAM arena, recopied only after a write-watch page fault | +10.5 % at 1440p 4x | A missed write means stale geometry (FM2 had a tyre-mark bug) | New [SDK]. Lavender still keeps the 512 MB mirror |
| CB-25 | Zero-copy guest memory imported as a GPU heap | FM2: 150 → 211 fps | Needs `VK_EXT_external_memory_host`; Turnip lacks it (Pinyon) | Re-measure on desktop |
| CB-26 | Idle EDRAM surfaces released after 3,600 frames; surfaces 720 rows tall, not 1024 | 4K 4x VRAM **14.3 → 5.7 GB**, races +5.1 %; 5K 4x 82 → 154 fps | A few ms to recreate a surface | New: a low-requirements win (VRAM) |
| CB-27 | Texture untile and decode in bands on 3 helper threads, with the next heap allocated ahead | An 18.9 MB DXT5 upload 8.9 → 2.5 ms; race long frames ≤ 5.8 ms | none | New [SDK] |

### Resolves, EDRAM, MSAA

| ID | Item | Their result | Trade | Bucket |
|---|---|---|---|---|
| **CB-28** | **One guest tile**: force the game's two-tile predicated rendering to one tall tile and merge the per-tile window fixups | **+9.1 %** CPU-bound; draws 3,288 → 2,647 | Photo mode needed a fix | **New [HOOK + SDK]**: FH1 tile merge didn't help, but FM3 is a different engine |
| CB-29 | Resolve write-back to guest memory only for the cases the game reads on the CPU. FM3 needs 4: road strips 32x512, car pictures 512x256 and 256x128, liveries 2048² and 1024² (deferred). Everything else stays on the GPU | Avoids the 30 fps `full` readback cap | A missed case shows stale CPU-side pictures | **New [HOOK + SDK]**. The list is in FM3-ReGPU `src/gpu_host.cpp` |
| CB-30 | Draw the gamma pass straight into the back buffer | 4K +4 %, races +2.5 % | ≤ 1/255 | New |
| CB-31 | 2_10_10_10 copies | +2.3 % | Rounding up to 2/255 | New |
| — | Two-step MSAA resolve, fast whole-surface clears, batched barriers, per-pass MSAA, hidden-part draw cull | 0 to −1.3 % | — | **Skip** |

### Sync, sleep, pacing

| ID | Item | Their result | Bucket |
|---|---|---|---|
| CB-32 | Ring-wait sleep: hook the game's D3D ring-space loop | FM3: −17 to −19 % CPU (3.39 → 2.73 cores); Lavender: 2.26 → 1.41 cores | **Have**. Locate FM3's loop |
| CB-33 | CP sleeps when idle under a frame cap (≤ 144 or vsync) | At a 60 cap: CP 98 → 20 % of a core; process 2.1 → 1.5 cores | New [SDK]: big for handhelds and laptops |
| CB-34 | Vblank at 2x the frame cap, frame delta from the host clock, high-resolution waitable timer, sub-millisecond sleeps | Required for correct pacing (Q24) | Partly planned (Lavender lean kernel) |
| CB-35 | Menus capped at 120 fps (their animations step per frame) | Correctness at high fps | New [HOOK] |

### Low end and lower requirements

| ID | Item | Their result | Trade | Bucket |
|---|---|---|---|---|
| CB-36 | Half-rate car shadows (skip the whole pass, not just its draws) | +8.2 %, 4K +2.2 % | Shadows a frame late | New [HOOK] |
| CB-37 | Half-rate car reflections (each cube face every 4th frame); 30 Hz mirror | +2.1–2.3 %; cockpit 214 → ~240 | Stale reflections and mirror | New [HOOK] |
| CB-38 | Distant-car LOD | +4.1 % | 0.15 % of pixels | New [HOOK] |
| CB-39 | Presets bundling the above plus an upscaler | iGPU Low 64 → 78 fps (+22 %) | Visible | New. Lavender's Odin preset is the template |
| CB-40 | Bilinear upscale as the cheapest option (FSR 1 costs 1.65 ms on a 2-CU iGPU) | iGPU +6.9 % | Softer | New. ShiftGlue already has FSR, FSR 2/3, DLSS and frame generation |
| CB-41 | Anisotropic filtering at the level the game asks for, not forced to 16x | 4K GPU −3.8 % | 9 % of pixels softer | New |
| CB-42 | Laptop GPU selection (`NvOptimusEnablement`, `AmdPowerXpressRequestHighPerformance`) and a pipeline cache per GPU | — | — | New, trivial |
| — | Variable-rate shading on AI cars (<1 %), the game's dev `fast*`/`perfmode` flags (dead in retail), mesh decimation, 64 px draw cull (menus flicker) | — | — | **Skip** |

## Where frame time goes in FM3-ReGPU

- **Early (their S13):** a turn-taking chain. The game's render thread
  spent about 86 % of its time in the D3D ring wait. The CP waited on
  fences that completed only after the host GPU, so 720p ran at the
  same speed as 1440p. CB-6 and CB-7 broke the chain.
- **Later (S30–S37):** races are limited by the draw thread, at about
  1.0–1.4 µs a draw.
  - `DrawImpl` is 30–37 % of the draw thread; about 11 % of that is one
    store draining write-combined writes into the VRAM ring.
  - Hashing is about 6 %, pass scales about 5 %.
  - Each car costs about 183 draws, about 0.19 ms of draw thread and
    about 0.15 ms of GPU. The car shadow map is 16 % of the draw thread.
  - At 2 cores / 4 threads: draw thread 94 %, CP 62 %, game render
    thread 50 %.
- **4K:** GPU-bound, 4.1 of 4.4 ms. Half the cost of 4x MSAA over 2x is
  resolves reading 8-byte samples.
- **iGPU** (2-CU RDNA2, 720p): about 47 % pixel work, 25 % vertex work
  and 22 % fixed per-draw cost (about 1.8 µs × 2,700 draws).

## Suggested order

1. **CB-0.1 → CB-0.2 → CB-0.5.** Boot FM3, then measure how much code
   it shares with FH1 and build the benchmark scene.
2. **CB-1 now, on Lavender.** It needs no FM3 work. A one-flag A/B on
   FH2's AI free-roam route at a pinned load address (CB-2) gives the
   answer.
3. **CB-0.3 and CB-0.4.** Choose the route; on Route A, make FM3
   render.
4. CPU front end: **CB-6/7 → CB-8 → CB-10 → CB-33 → CB-11..14**.
5. Shaders: **CB-17 → CB-16**, then CB-18 coverage.
6. Memory: **CB-23** (byte cuts first), then CB-26 and CB-24.
7. FM3 hooks: **CB-28, CB-29, CB-32**, then the half-rate and LOD
   hooks with presets (CB-36..39).
8. Re-measure under perf-first rules: CB-3, CB-4, CB-22, CB-25.

## Licences

- ReGPU, Glue2GPU, ReXenon, FM2-ReGPU and FM3-ReGPU are MIT. Code we
  take from them needs a notice in `THIRD_PARTY_NOTICES.md`.
- hl360-forza3 has **no licence**. We read its notes and copy nothing.
- No game files, dumps, generated code or extracted shaders go in this
  repository.
