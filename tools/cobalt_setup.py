"""Cobalt Shift game setup: the player's own disc images, read-only.

Cobalt Shift supports one game version: Forza Motorsport 3 Ultimate Collection
(USA), title 4D53084D, whose Disc 1 carries default.xex v0.0.0.8 (no title
update is needed). This script lays the player's files out under .local/game,
which is git-ignored:

    disc/       every file on Disc 1 except $SystemUpdate   (game:\\, d:\\)
    disc2-raw/  Disc 2's files as they are
    content/    Disc 2's packages as the game installs them (first run)
    codegen/    default.xex, for the generator

Commands:

    python -I tools/cobalt_setup.py disc    <Disc 1 iso>
    python -I tools/cobalt_setup.py disc2   <Disc 2 iso>
    python -I tools/cobalt_setup.py codegen
    python -I tools/cobalt_setup.py status

Each extraction writes a catalog (path, size, SHA-256) beside the folder it
fills. Nothing here writes to the dump. The XDVDFS and STFS readers are Lavender
Shift's tools/lavender_setup.py (which follows Pinyon Shift and Xenia).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAME = ROOT / ".local" / "game"
MODULES = ("default.xex",)
SYSTEM_UPDATE = "$SystemUpdate"
FM3_TITLE_ID = 0x4D53084D

# The generated code is folded against this exact executable (FM3-ReGPU uses
# the same one), so setup checks it by SHA-256.
SUPPORTED_DISC_MODULES = {
    "default.xex": "AA15372C13BC4C899B5EF90A1CFB5634D389B0A3620CC9715F6023D61A9B8742",
}

SECTOR = 2048
XDVDFS_MAGIC = b"MICROSOFT*XBOX*MEDIA"
PARTITION_OFFSETS = (0, 0x2080000, 0xFD90000, 0x18300000)

STFS_BLOCK = 0x1000
STFS_PER_TABLE = 170

class SetupError(RuntimeError):
    pass


def check_supported(listing: list[dict], supported: dict[str, str], what: str) -> None:
    by_name = {entry["path"].lower(): entry["sha256"] for entry in listing}
    for name, expected in supported.items():
        actual = by_name.get(name.lower())
        if actual is None:
            raise SetupError(f"the {what} has no {name}")
        if actual != expected:
            raise SetupError(f"the {what}'s {name} is not the supported revision "
                             f"(SHA-256 {actual[:16]}..., expected {expected[:16]}...): "
                             "Cobalt Shift supports the Ultimate Collection USA disc only")


def sha256_bytes(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest().upper()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 << 20), b""):
            digest.update(block)
    return digest.hexdigest().upper()


class DiscImage:
    """The Xbox file system on a disc image, read-only."""

    def __init__(self, path: Path):
        self.stream = path.open("rb")
        self.offset = None
        for offset in PARTITION_OFFSETS:
            self.stream.seek(offset + 32 * SECTOR)
            if self.stream.read(len(XDVDFS_MAGIC)) == XDVDFS_MAGIC:
                self.offset = offset
                break
        if self.offset is None:
            raise SetupError(f"{path} is not an Xbox 360 disc image")
        self.stream.seek(self.offset + 32 * SECTOR + 20)
        self.root_sector, self.root_size = struct.unpack("<II", self.stream.read(8))

    def close(self) -> None:
        self.stream.close()

    def _read(self, sector: int, size: int) -> bytes:
        self.stream.seek(self.offset + sector * SECTOR)
        return self.stream.read(size)

    def files(self) -> list[tuple[str, int, int]]:
        """(path, first sector, size) of every file."""
        found = []
        pending = [("", self.root_sector, self.root_size)]
        while pending:
            prefix, sector, size = pending.pop()
            if size == 0:
                continue
            table = self._read(sector, size)
            nodes, seen = [0], set()
            while nodes:
                position = nodes.pop()
                if position in seen or position + 14 > len(table):
                    continue
                seen.add(position)
                left, right, start, length, attributes, name_length = struct.unpack_from(
                    "<HHIIBB", table, position)
                if left == 0xFFFF and right == 0xFFFF:
                    continue  # sector padding
                name = table[position + 14: position + 14 + name_length].decode("latin-1")
                if left:
                    nodes.append(left * 4)
                if right:
                    nodes.append(right * 4)
                path = f"{prefix}{name}"
                if attributes & 0x10:
                    pending.append((path + "/", start, length))
                else:
                    found.append((path, start, length))
        return found

    def copy(self, sector: int, size: int, destination: Path) -> str:
        digest = hashlib.sha256()
        self.stream.seek(self.offset + sector * SECTOR)
        remaining = size
        with destination.open("wb") as out:
            while remaining:
                block = self.stream.read(min(remaining, 8 << 20))
                if not block:
                    raise SetupError("the disc image ends early")
                out.write(block)
                digest.update(block)
                remaining -= len(block)
        return digest.hexdigest().upper()


def staging_for(target: Path) -> Path:
    staging = target.with_name(target.name + ".extracting")
    if staging.exists():
        shutil.rmtree(staging)
    return staging


def swap_in(staging: Path, target: Path) -> None:
    if target.exists():
        shutil.rmtree(target)
    staging.rename(target)


def write_catalog(path: Path, catalog: dict) -> None:
    path.write_text(json.dumps(catalog, indent=1) + "\n", encoding="utf-8")


def copy_disc(iso: Path, target: Path, required: tuple[str, ...]) -> tuple[Path, list[dict], int]:
    disc = DiscImage(iso)
    staging = staging_for(target)
    try:
        files = [entry for entry in disc.files()
                 if entry[0].split("/", 1)[0].lower() != SYSTEM_UPDATE.lower()]
        names = {path.lower() for path, _, _ in files}
        missing = [name for name in required if name.lower() not in names]
        if missing:
            raise SetupError(f"{iso.name} has no {missing[0]}: not the expected disc")
        files.sort(key=lambda entry: entry[1])
        total = sum(size for _, _, size in files)
        done, listing = 0, []
        for index, (path, sector, size) in enumerate(files):
            destination = staging / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            listing.append({"path": path, "size": size,
                            "sha256": disc.copy(sector, size, destination)})
            done += size
            if index % 200 == 0:
                print(f"{target.name}: {done / 1e9:.2f} of {total / 1e9:.2f} GB", flush=True)
    finally:
        disc.close()
    return staging, listing, total


def extract_disc(iso: Path) -> None:
    target = GAME / "disc"
    staging, listing, total = copy_disc(iso, target, MODULES)
    try:
        check_supported(listing, SUPPORTED_DISC_MODULES, "disc image")
    except SetupError:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    swap_in(staging, target)
    write_catalog(GAME / "disc-catalog.json", {
        "source": iso.name, "file_count": len(listing), "total_bytes": total,
        "files": listing})
    print(f"disc: {len(listing)} files, {total / 1e9:.2f} GB in {target}")


def extract_disc2(iso: Path) -> None:
    """Disc 2 holds STFS content packages. They are copied as they are: the
    game installs them into <game root>/content on its first run (cobalt_disc2_content)."""
    raw = GAME / "disc2-raw"
    staging, listing, _ = copy_disc(iso, raw, ())
    swap_in(staging, raw)
    packages = []
    for entry in listing:
        path = raw / entry["path"]
        with path.open("rb") as stream:
            head = stream.read(4)
        if head not in (b"LIVE", b"PIRS", b"CON ") or not entry["path"].startswith("Content"):
            continue
        packages.append({"package": entry["path"], "bytes": path.stat().st_size})
    write_catalog(GAME / "disc2-catalog.json", {"source": iso.name, "packages": packages,
                                                "files": listing})
    print(f"disc2: {len(packages)} packages in {raw}; the game installs them on its first run")


def prepare_codegen() -> None:
    disc = GAME / "disc"
    target = GAME / "codegen"
    target.mkdir(parents=True, exist_ok=True)
    for module in MODULES:
        xex = disc / module
        if not xex.is_file():
            raise SetupError(f"extract the disc first: {xex} is missing")
        shutil.copyfile(xex, target / module)
    print(f"codegen: {len(MODULES)} module(s) in {target}")


def status() -> None:
    report = {}
    for name in ("disc", "disc2"):
        catalog = GAME / f"{name}-catalog.json"
        if catalog.is_file():
            data = json.loads(catalog.read_text(encoding="utf-8"))
            report[name] = {k: v for k, v in data.items() if k != "files"}
        else:
            report[name] = None
    report["codegen"] = sorted(p.name for p in (GAME / "codegen").glob("*")) \
        if (GAME / "codegen").is_dir() else None
    print(json.dumps(report, indent=1))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("disc").add_argument("iso", type=Path)
    commands.add_parser("disc2").add_argument("iso", type=Path)
    commands.add_parser("codegen")
    commands.add_parser("status")
    args = parser.parse_args()
    GAME.mkdir(parents=True, exist_ok=True)
    try:
        if args.command == "disc":
            extract_disc(args.iso)
        elif args.command == "disc2":
            extract_disc2(args.iso)
        elif args.command == "codegen":
            prepare_codegen()
        else:
            status()
    except SetupError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
