"""Masked-hash comparison of two recompiled games' code (#2, CB-0.2).

usage: masked_hash.py <generated dir A> <generated dir B> [--all-d]

Reads the instruction comments ShiftGlue's codegen writes into every
generated *_recomp.N.cpp (one "// <mnemonic> <operands>" line per guest
instruction, functions opened by DEFINE_REX_FUNC(sub_XXXXXXXX)) and hashes
each function's instructions with the parts that move between builds masked,
as Lavender's LV-0.2 did for FH1 and FH2 ("mask B"): branch targets, lis/addis
immediates, offsets from r2 and r13. --all-d also masks every displacement
and immediate (16-bit D-form fields), the looser match.

Prints, for A against B: the share of A's functions, and of its code bytes,
whose masked hash also occurs in B; the same for functions of 8 instructions
or more (short ones match by chance); and how often unique matches keep
address order.
"""

import hashlib
import os
import re
import sys
from collections import Counter

FUNC = re.compile(r"^DEFINE_REX_FUNC\(sub_([0-9A-Fa-f]{8})\)")
ASM = re.compile(r"^\t// ([a-z][a-z0-9.+-]*)(?: (.*))?$")
HEX_TARGET = re.compile(r"0x[0-9a-f]{6,8}\b")
SMALL_REG_OFFSET = re.compile(r"(-?(?:0x)?[0-9a-f]+)\((r2|r13)\)")
D_FORM = re.compile(r"(-?(?:0x)?[0-9a-f]+)\((r\d+)\)")
IMM = re.compile(r"(?<=,)(-?(?:0x)?[0-9a-f]+)$")


def mask(mnemonic, operands, all_d):
    ops = operands or ""
    if mnemonic.startswith("b") and HEX_TARGET.search(ops):
        ops = HEX_TARGET.sub("T", ops)
    if mnemonic in ("lis", "addis"):
        ops = IMM.sub("I", ops)
    ops = SMALL_REG_OFFSET.sub(r"D(\2)", ops)
    if mnemonic in ("addi", "la") and re.search(r",(r2|r13),", ops):
        ops = IMM.sub("I", ops)
    if all_d:
        ops = D_FORM.sub(r"D(\2)", ops)
        ops = IMM.sub("I", ops)
    return mnemonic + " " + ops


def load(directory, all_d):
    funcs = {}  # address -> (hash, instruction count)
    for name in sorted(os.listdir(directory)):
        if not re.search(r"_recomp\.\d+\.cpp$", name):
            continue
        address, digest, count = None, None, 0
        with open(os.path.join(directory, name), encoding="utf-8", errors="replace") as f:
            for line in f:
                m = FUNC.match(line)
                if m:
                    if address is not None:
                        funcs[address] = (digest.digest(), count)
                    address, digest, count = int(m.group(1), 16), hashlib.blake2b(digest_size=12), 0
                    continue
                if address is None:
                    continue
                a = ASM.match(line)
                if a:
                    digest.update(mask(a.group(1), a.group(2), all_d).encode() + b"\n")
                    count += 1
        if address is not None:
            funcs[address] = (digest.digest(), count)
    return funcs


def report(a, b, min_count):
    b_hashes = Counter(h for h, n in b.values() if n >= min_count)
    total = matched = bytes_total = bytes_matched = 0
    for h, n in a.values():
        if n < min_count or n == 0:
            continue
        total += 1
        bytes_total += 4 * n
        if h in b_hashes:
            matched += 1
            bytes_matched += 4 * n
    return total, matched, bytes_total, bytes_matched


def order(a, b):
    a_count = Counter(h for h, n in a.values() if n >= 8)
    b_count = Counter(h for h, n in b.values() if n >= 8)
    b_addr = {h: addr for addr, (h, n) in b.items() if n >= 8 and b_count[h] == 1}
    pairs = sorted((addr, b_addr[h]) for addr, (h, n) in a.items()
                   if n >= 8 and a_count[h] == 1 and h in b_addr)
    kept = sum(1 for (_, x), (_, y) in zip(pairs, pairs[1:]) if y > x)
    return len(pairs), kept


def main():
    args = [x for x in sys.argv[1:] if not x.startswith("--")]
    all_d = "--all-d" in sys.argv
    a, b = load(args[0], all_d), load(args[1], all_d)
    print(f"A: {args[0]}: {len(a)} functions, {sum(n for _, n in a.values()) * 4 / 1e6:.2f} MB code")
    print(f"B: {args[1]}: {len(b)} functions, {sum(n for _, n in b.values()) * 4 / 1e6:.2f} MB code")
    print(f"mask: {'every D-form field' if all_d else 'B (branches, lis, r2/r13)'}")
    for min_count in (1, 8):
        t, m, bt, bm = report(a, b, min_count)
        print(f"functions of {min_count}+ instructions: {m}/{t} in B ({100 * m / max(1, t):.1f} %), "
              f"code bytes {100 * bm / max(1, bt):.1f} %")
    pairs, kept = order(a, b)
    print(f"unique matches (8+ instructions): {pairs}, in address order {100 * kept / max(1, pairs - 1):.1f} %")


if __name__ == "__main__":
    main()
