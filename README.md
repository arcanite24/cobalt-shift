# Cobalt Shift

A native PC port of the Xbox 360 version of **Forza Motorsport 3**. It is the third port in the
series, after [Pinyon Shift](https://github.com/arcanite24/pinyon-shift) (Forza Horizon 1) and
[Lavender Shift](https://github.com/arcanite24/lavender-shift) (Forza Horizon 2).

**Goal:** the best performance and the lowest hardware requirements we can reach. Exact console
behaviour comes second.

**Status:** playable: menus, career and races run natively. The project is tracked in this
repository's issues.

- [docs/RESEARCH.md](docs/RESEARCH.md): what to take from other 360 recomp projects (items CB-*).

You bring your own copy of the game. This repository never contains game files, disc images,
dumps, generated code or extracted shaders. `tools/cobalt_setup.py` lays your discs out under
`.local/game` (git-ignored):

```
python -I tools/cobalt_setup.py disc    "<Disc 1 (Play Disc) iso>"
python -I tools/cobalt_setup.py disc2   "<Disc 2 (Content Install Disc) iso>"
python -I tools/cobalt_setup.py codegen
```

Disc 2 is optional. With it, the first run installs its eight content packages (the extra cars
and tracks, 3.4 GB) into `.local/game/content`, which every profile shares, and the game no
longer asks for the disc. `--cobalt_disc2_content=false` hides them again.
