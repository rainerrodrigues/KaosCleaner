"""Check that repeated calls into libkaoscleaner do not leak memory (Linux).

    python scripts/memory_test.py [rows] [iterations]

Cleans the same generated CSV over and over and prints the process RSS after
each round. Exported Arrow buffers are freed by their release callback as
soon as the last Python reference goes away, so RSS should level off after
the first few rounds instead of growing with every file.
"""
import os
import random
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "python"))

from kaos_cleaner import clean_csv  # noqa: E402


def rss_mb() -> float:
    with open("/proc/self/status") as f:
        for line in f:
            if line.startswith("VmRSS:"):
                return int(line.split()[1]) / 1024
    raise RuntimeError("VmRSS not found")


def write_csv(path, rows):
    rng = random.Random(42)
    with open(path, "w") as f:
        f.write("ID,Sensor Reading,Location,Timestamp,Label\n")
        for i in range(rows):
            reading = "NA" if rng.random() < 0.05 else f"{rng.gauss(20, 5):.4f}"
            loc = rng.choice(["loc_1", "loc_2", "loc_3", " loc_4 ", "N/A"])
            ts = f"2024-0{rng.randint(1, 9)}-1{rng.randint(0, 9)}T1{rng.randint(0, 9)}:30:00"
            f.write(f"{i},{reading},{loc},{ts},label_{rng.randint(0, 999)}\n")


def main():
    rows = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
    iterations = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    path = os.path.join(tempfile.mkdtemp(), "memory_test.csv")
    write_csv(path, rows)
    print(f"{rows} rows, {os.path.getsize(path) / 2**20:.0f} MB on disk; RSS before: {rss_mb():.0f} MB")

    for i in range(1, iterations + 1):
        start = time.time()
        df = clean_csv(path)
        n = df.height
        del df  # drops the last reference, which fires the Arrow release callbacks
        print(f"round {i:2d}: {n} rows in {time.time() - start:.2f}s, RSS {rss_mb():.0f} MB")
    os.remove(path)


if __name__ == "__main__":
    main()
