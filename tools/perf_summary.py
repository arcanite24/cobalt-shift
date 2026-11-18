"""Summarise a --perf_log_csv capture.

usage: perf_summary.py <csv> [first_row] [last_row]

Prints percentiles for frame pacing and the per-frame cost counters that are
non-zero in the window, so two captures can be diffed by eye.
"""

import csv
import statistics
import sys


def pct(values, p):
    values = sorted(values)
    if not values:
        return 0.0
    k = (len(values) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def main():
    path = sys.argv[1]
    first = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    last = int(sys.argv[3]) if len(sys.argv) > 3 else None
    with open(path, newline="") as f:
        rows = list(csv.DictReader(f))
    rows = rows[first:last]
    if not rows:
        print("no rows")
        return
    cols = rows[0].keys()
    data = {}
    for c in cols:
        try:
            data[c] = [float(r[c]) for r in rows if r[c] not in ("", None)]
        except ValueError:
            continue
    ft = [v / 1000.0 for v in data["frame_time_us"] if v > 0]
    print(f"rows {len(rows)}  frame ms: p50 {pct(ft, 50):.2f}  p95 {pct(ft, 95):.2f}  "
          f"p99 {pct(ft, 99):.2f}  max {max(ft):.2f}  -> {1000.0 / statistics.mean(ft):.1f} fps avg")
    # Long frames: hitches a player sees (two and three vblanks at 60 Hz, and worse).
    print("long frames: " + "  ".join(f">{t} ms {sum(1 for v in ft if v > t)}" for t in (20, 34, 50, 100)))
    print(f"{'counter':48s} {'mean':>14s} {'p50':>14s} {'p95':>14s} {'max':>14s}")
    for c, v in data.items():
        if c == "frame_time_us" or not v or max(v) == 0:
            continue
        print(f"{c:48s} {statistics.mean(v):14.1f} {pct(v, 50):14.1f} {pct(v, 95):14.1f} {max(v):14.1f}")


if __name__ == "__main__":
    main()
