"""Benchmark kaos-cleaner against the same cleaning in pandas and Polars.

    pip install pandas polars pyarrow
    python scripts/benchmark.py                    # 100k, 1M and 10M rows
    python scripts/benchmark.py --rows 1000000 --runs 7

Generates messy CSV files (padded text, missing markers, ~2% duplicate rows),
then times each engine in its own process, so no engine's memory or warm
caches affect another. Reports the median of the runs (after one warm-up) and
each process's peak memory, as a Markdown table.
"""

import argparse
import os
import random
import resource
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "python"))
sys.path.insert(0, str(ROOT / "python" / "tests"))


def write_csv(path, rows, seed=1):
    """The same messy data as python/tests/test_benchmark.py, at any size."""
    rng = random.Random(seed)
    locations = ["loc_1", " loc_2", "loc_3 ", "N/A", ""]
    with open(path, "w") as f:
        f.write("ID,Sensor Reading, Location ,Timestamp,Label\n")
        dup_every = 50  # ~2% duplicates: every 50th row repeats an earlier one
        recent = []
        for i in range(rows):
            if i and i % dup_every == 0:
                f.write(rng.choice(recent))
                continue
            reading = "NA" if rng.random() < 0.05 else f"{rng.gauss(20, 5):.4f}"
            line = (
                f"{i},{reading},{rng.choice(locations)},"
                f"2024-0{rng.randint(1, 9)}-1{rng.randint(0, 9)}T10:30:00,label_{rng.randint(0, 999)}\n"
            )
            f.write(line)
            recent.append(line)
            if len(recent) > 1000:
                recent.pop(0)


def run_engine(engine, path, runs):
    """Time one engine in this process: (median seconds, peak RSS MB, rows)."""
    if engine == "kaos-cleaner":
        from kaos_cleaner import clean_csv as fn
    else:
        import test_benchmark as tb

        fn = tb.pandas_clean if engine == "pandas" else tb.polars_clean
    rows = len(fn(path))  # warm-up (and engine start-up for kaos-cleaner)
    times = []
    for _ in range(runs):
        start = time.perf_counter()
        fn(path)
        times.append(time.perf_counter() - start)
    peak_mb = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024
    return statistics.median(times), peak_mb, rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rows", type=int, nargs="+", default=[100_000, 1_000_000, 10_000_000])
    parser.add_argument("--runs", type=int, default=None, help="timed runs per engine (default: 5, or 3 for 10M+)")
    parser.add_argument("--engines", nargs="+", default=["pandas", "polars", "kaos-cleaner"])
    parser.add_argument("--child", nargs=3, metavar=("ENGINE", "PATH", "RUNS"), help=argparse.SUPPRESS)
    args = parser.parse_args()

    if args.child:  # one engine, one file, in a fresh process
        engine, path, runs = args.child
        median, peak, rows = run_engine(engine, path, int(runs))
        print(f"{median} {peak} {rows}")
        return

    results = {}
    with tempfile.TemporaryDirectory() as tmp:
        for n in args.rows:
            path = os.path.join(tmp, f"bench_{n}.csv")
            write_csv(path, n)
            size_mb = os.path.getsize(path) / 1e6
            runs = args.runs or (3 if n >= 10_000_000 else 5)
            for engine in args.engines:
                out = subprocess.run(
                    [sys.executable, __file__, "--child", engine, path, str(runs)],
                    capture_output=True,
                    text=True,
                    check=True,
                ).stdout.split()
                median, peak, rows = float(out[0]), float(out[1]), int(out[2])
                results[(n, engine)] = (median, peak, rows)
                print(
                    f"{n:>11,} rows ({size_mb:,.0f} MB)  {engine:13s} {median * 1000:9,.0f} ms"
                    f"  peak {peak:7,.0f} MB  -> {rows:,} rows",
                    file=sys.stderr,
                )
            os.remove(path)

    print("\n| Rows | " + " | ".join(args.engines) + " |")
    print("|---:|" + "---:|" * len(args.engines))
    for n in args.rows:
        times = {e: results[(n, e)][0] for e in args.engines}
        best = min(times.values())
        cells = [(f"**{t * 1000:,.0f} ms**" if t == best else f"{t * 1000:,.0f} ms") for t in times.values()]
        print(f"| {n:,} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
