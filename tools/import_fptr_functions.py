#!/usr/bin/env python3
"""Write config/analysis/thunks-default.toml from forza3-recomp's manifest.

forza3-recomp (MIT, github.com/twilightysparkle/forza3-recomp at 5b14b0d)
lists FM3's function boundaries that .pdata omits under [entrypoint.functions]
in its forza3_manifest.toml (upstream ReXGlue syntax). ShiftGlue reads the
same facts as [functions."ADDR"] tables. Entries already in default.toml keep
their sizes there.

    python -I tools/import_fptr_functions.py <forza3_manifest.toml>
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    text = Path(sys.argv[1]).read_text(encoding="utf-8")
    section = text.split("[entrypoint.functions]", 1)[1].split("\n[", 1)[0]
    have = set(re.findall(r'\[functions\."([0-9A-F]{8})"\]',
                          (ROOT / "config/analysis/default.toml").read_text(encoding="utf-8")))
    out = ["# Function boundaries .pdata omits, mostly targets reached only through",
           "# pointers (vtables, callbacks). Imported by tools/import_fptr_functions.py",
           "# from forza3-recomp (MIT, twilightysparkle/forza3-recomp 5b14b0d),",
           "# which found them with its tools/analysis/ptrscan.py on the same xex.", ""]
    count = 0
    for line in section.splitlines():
        match = re.match(r"\s*0x([0-9A-Fa-f]{8})\s*=\s*\{([^}]*)\}\s*(#.*)?$", line)
        if not match:
            continue
        address, body, comment = match.group(1).upper(), match.group(2).strip(), match.group(3)
        if address in have:
            continue
        out.append(f'[functions."{address}"]' + (f"  {comment}" if comment else ""))
        for key, value in re.findall(r"(\w+)\s*=\s*(0x[0-9A-Fa-f]+|\d+)", body):
            out.append(f"{key} = {value}")
        count += 1
    (ROOT / "config/analysis/thunks-default.toml").write_text("\n".join(out) + "\n", encoding="utf-8")
    print(f"{count} entries")
    return 0


if __name__ == "__main__":
    sys.exit(main())
