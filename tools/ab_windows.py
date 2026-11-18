"""Median frame time of row windows of a --perf_log_csv capture (bench_ab.ps1).

usage: ab_windows.py [--mean] <csv> <first:last> [<first:last> ...]

Prints one median frame time in ms per window, space-separated. The median
ignores the odd slow frame that moves a window's mean. --mean prints the mean
instead: under a frame cap FM3 takes one or two vblanks a frame, so the
median jumps between the two steps (blindvac at 60 Hz: 17 or 33 ms) and the
mean shows the share of slow frames.
"""

import csv
import statistics
import sys


def main():
    args = [a for a in sys.argv[1:] if a != "--mean"]
    mean = "--mean" in sys.argv
    with open(args[0], newline="") as f:
        times = [r.get("frame_time_us") for r in csv.DictReader(f)]
    out = []
    for spec in args[1:]:
        first, last = (int(x) for x in spec.split(":"))
        window = [float(t) for t in times[first:last] if t not in ("", None)]
        value = statistics.fmean(window) if mean else statistics.median(window) if window else 0
        out.append(f"{value / 1000:.3f}" if window else "nan")
    print(" ".join(out))


if __name__ == "__main__":
    main()
