"""Speed of kaos_cleaner relative to pandas and polars on the same machine.

Absolute times on CI runners vary from run to run; ratios measured in the same
process are stable, so the gate below asserts a ratio, never a time. pandas
does the same cleaning as kaos_cleaner, so the comparison is like for like.

    pytest python/tests/test_benchmark.py --benchmark-columns=min,mean,stddev
"""
import random
import re
import statistics
import time

import pytest

from kaos_cleaner import clean_csv

pd = pytest.importorskip("pandas")
pl = pytest.importorskip("polars")

MISSING = ["", "NA", "N/A", "n/a", "na", "NaN", "nan", "null", "NULL", "None", "none"]
ROWS = 100_000


@pytest.fixture(scope="module")
def bench_csv(tmp_path_factory):
    """100k messy rows: padded text, missing markers, 2% duplicates."""
    rng = random.Random(1)
    lines = ["ID,Sensor Reading, Location ,Timestamp,Label"]
    for i in range(ROWS):
        reading = "NA" if rng.random() < 0.05 else f"{rng.gauss(20, 5):.4f}"
        loc = rng.choice(["loc_1", " loc_2", "loc_3 ", "N/A", ""])
        lines.append(f"{i},{reading},{loc},2024-0{rng.randint(1, 9)}-1{rng.randint(0, 9)}T10:30:00,"
                     f"label_{rng.randint(0, 999)}")
    lines += rng.sample(lines[1:], ROWS // 50)
    path = tmp_path_factory.mktemp("bench") / "bench.csv"
    path.write_text("\n".join(lines) + "\n")
    return str(path)


def _snake(name):
    return re.sub(r"[^\w]+|_+", "_", name.strip().lower()).strip("_") or "column"


def pandas_clean(path):
    """pandas doing what kaos_cleaner does."""
    df = pd.read_csv(path, na_values=MISSING, keep_default_na=False, skipinitialspace=True)
    df.columns = [_snake(c) for c in df.columns]
    for col in [c for c in df.columns if pd.api.types.is_string_dtype(df[c])]:
        df[col] = df[col].str.strip().replace(MISSING, None)
    return df.dropna(how="all").drop_duplicates()


def polars_clean(path):
    """polars doing what kaos_cleaner does."""
    df = pl.read_csv(path, null_values=MISSING, try_parse_dates=True)
    df = df.rename({c: _snake(c) for c in df.columns})
    text = [c for c, t in df.schema.items() if t == pl.String]
    df = df.with_columns(pl.col(text).str.strip_chars().replace(MISSING, None))
    return df.filter(~pl.all_horizontal(pl.all().is_null())).unique(maintain_order=True)


@pytest.mark.parametrize("engine", [pandas_clean, polars_clean, clean_csv], ids=["pandas", "polars", "kaos_cleaner"])
def test_benchmark(benchmark, bench_csv, engine):
    """Side-by-side report; `pytest --benchmark-only` prints the comparison table."""
    benchmark.group = f"clean {ROWS:,} rows"
    result = benchmark.pedantic(engine, args=(bench_csv,), rounds=5, warmup_rounds=1)
    assert len(result) == ROWS


def _median_time(fn, path, runs=7):
    fn(path)  # warm up
    times = []
    for _ in range(runs):
        start = time.perf_counter()
        fn(path)
        times.append(time.perf_counter() - start)
    return statistics.median(times)


# Regression guard: on 100k rows kaos_cleaner measures ~1.95x the speed of the
# equivalent pandas code on a 12-core machine (parallel parsing, deduplication
# and export); GitHub's 4-core runners show less. 0.7x still fails if
# threading or the cleaning fast paths stop working (one thread: ~0.6x).
MIN_SPEEDUP_VS_PANDAS = 0.7


def test_speed_vs_pandas(bench_csv):
    """Gate: fail if kaos_cleaner gets markedly slower relative to pandas."""
    pandas_s = _median_time(pandas_clean, bench_csv)
    kaos_s = _median_time(clean_csv, bench_csv)
    speedup = pandas_s / kaos_s
    print(f"\npandas {pandas_s:.3f}s | kaos_cleaner {kaos_s:.3f}s | speedup {speedup:.2f}x")
    assert speedup >= MIN_SPEEDUP_VS_PANDAS, f"speedup over pandas dropped to {speedup:.2f}x"
