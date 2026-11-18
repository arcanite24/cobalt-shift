"""Read the faulting thread of a minidump (src/crash_dump.cpp).

usage: read_dump.py <dump> [<module.map> ...]

Prints the exception, the module it happened in, and a scan of the faulting
thread's stack: every 8-byte value that points into a loaded module's code,
as module+offset, and as a symbol where a linker map for that module is
given (lld-link /MAP, e.g. thirdparty/shiftglue-sdk/out/win-amd64/
rexgpu-fh1.map). A stack scan also lists stale return addresses, so read it
from the top and trust the frames that make sense together.
"""

import bisect
import os
import struct
import sys

STREAM_THREADS, STREAM_MODULES, STREAM_EXCEPTION = 3, 4, 6


def read_string(data, rva):
    (length,) = struct.unpack_from("<I", data, rva)
    return data[rva + 4:rva + 4 + length].decode("utf-16-le")


def load_map(path):
    symbols = []
    module = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.split()
            if not module and parts:
                module = parts[0].lower()
            if len(parts) >= 3 and ":" in parts[0] and len(parts[2]) == 16:
                try:
                    symbols.append((int(parts[2], 16), parts[1]))
                except ValueError:
                    pass
    symbols.sort()
    preferred = 0x180000000
    return module, preferred, symbols


def main():
    data = open(sys.argv[1], "rb").read()
    maps = {}
    for path in sys.argv[2:]:
        module, preferred, symbols = load_map(path)
        maps[os.path.basename(path).lower().replace(".map", ".dll")] = (preferred, symbols)
    signature, version, streams, directory = struct.unpack_from("<4sIII", data, 0)
    assert signature == b"MDMP"
    found = {}
    for i in range(streams):
        kind, size, rva = struct.unpack_from("<III", data, directory + 12 * i)
        found[kind] = (size, rva)

    modules = []
    size, rva = found[STREAM_MODULES]
    (count,) = struct.unpack_from("<I", data, rva)
    for i in range(count):
        base, image_size, _, _, name_rva = struct.unpack_from("<QIIII", data, rva + 4 + 108 * i)
        modules.append((base, image_size, os.path.basename(read_string(data, name_rva))))
    modules.sort()

    def where(address):
        for base, image_size, name in modules:
            if base <= address < base + image_size:
                text = f"{name}+0x{address - base:X}"
                entry = maps.get(name.lower())
                if entry:
                    preferred, symbols = entry
                    target = preferred + (address - base)
                    k = bisect.bisect_right(symbols, (target, "￿")) - 1
                    if k >= 0:
                        text += f"  {symbols[k][1]}+0x{target - symbols[k][0]:X}"
                return text
        return None

    size, rva = found[STREAM_EXCEPTION]
    thread_id, _, code, flags, record, address = struct.unpack_from("<IIIIQQ", data, rva)
    (parameters,) = struct.unpack_from("<I", data, rva + 32)
    info = struct.unpack_from("<2Q", data, rva + 40)
    context_size, context_rva = struct.unpack_from("<II", data, rva + 8 + 152)
    rip, rsp = struct.unpack_from("<Q", data, context_rva + 0xF8)[0], struct.unpack_from("<Q", data, context_rva + 0x98)[0]
    print(f"exception {code:08X} at {address:X} ({where(address)})")
    if code == 0xC0000005:
        print(f"  {'write' if info[0] == 1 else 'read'} of {info[1]:X}")
    print(f"thread {thread_id}, rip {rip:X}, rsp {rsp:X}")

    size, rva = found[STREAM_THREADS]
    (count,) = struct.unpack_from("<I", data, rva)
    for i in range(count):
        tid, _, _, _, teb, stack_start, stack_size, stack_rva = struct.unpack_from("<IIIIQQII", data, rva + 4 + 48 * i)
        if tid != thread_id:
            continue
        stack = data[stack_rva:stack_rva + stack_size]
        first = max(0, rsp - stack_start)
        print("stack (code addresses from rsp up):")
        shown = 0
        for offset in range(first - first % 8, len(stack) - 7, 8):
            (value,) = struct.unpack_from("<Q", stack, offset)
            text = where(value)
            if text:
                print(f"  rsp+{offset - first:5X}  {value:016X}  {text}")
                shown += 1
                if shown >= 60:
                    break


if __name__ == "__main__":
    main()
