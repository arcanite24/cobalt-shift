"""Median frame time of row windows of a --perf_log_csv capture (bench_ab.ps1).

usage: ab_windows.py <csv> <first:last> [<first:last> ...]

Prints one median frame time in ms per window, space-separated. The median
ignores the odd slow frame that moves a window's mean.
"""

import csv
import statistics
import sys


def main():
    with open(sys.argv[1], newline="") as f:
        times = [r.get("frame_time_us") for r in csv.DictReader(f)]
    out = []
    for spec in sys.argv[2:]:
        first, last = (int(x) for x in spec.split(":"))
        window = [float(t) for t in times[first:last] if t not in ("", None)]
        out.append(f"{statistics.median(window) / 1000:.3f}" if window else "nan")
    print(" ".join(out))


if __name__ == "__main__":
    main()
