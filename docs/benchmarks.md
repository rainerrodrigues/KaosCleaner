# Benchmarks

Numbers from one machine, to show orders of magnitude and trade-offs, not to
crown a winner. Run them yourself with
`pytest python/tests/test_benchmark.py --benchmark-columns=min,median`.

**Machine**: AMD Ryzen 5 5600H (6 cores, 12 threads), 7.6 GB RAM, WSL2 on
Windows. Python 3.14, pandas 3.1, Polars 2.1, PyArrow 26.

## Same cleaning, three engines

Each engine does the same work: parse, treat the same markers as missing,
trim text, snake_case column names, drop all-empty and duplicate rows. The
pandas and Polars versions are in `python/tests/test_benchmark.py`. The data
is generated messy CSV (integers, floats with `NA`s, padded text, timestamps,
labels, ~2% duplicates). Times are the median of 5 runs after a warm-up, and
include converting the result to a Polars DataFrame for kaos-cleaner.

| Rows | File | pandas | Polars | kaos-cleaner |
|---:|---:|---:|---:|---:|
| 100,000 | 4.7 MB | 61 ms | 63 ms | **43 ms** |
| 1,000,000 | 48 MB | **421 ms** | 431 ms | 478 ms |

On this data kaos-cleaner is the fastest at 100k rows and roughly on par at
a million. kaos-cleaner also infers booleans, dates and formatted numbers in
text columns, which the pandas and Polars versions above do not do.

## Threads

CSV parsing is the biggest cost and runs on all cores by default:

| Rows | 1 thread | all 12 threads |
|---:|---:|---:|
| 100,000 | 96 ms | 43 ms |
| 1,000,000 | 1,257 ms | 478 ms |

On machines with fewer cores, expect numbers between the two columns.

## Larger than memory

A 491 MB file with 10 million rows, cleaned in memory versus streamed to
Parquet in 64 MB chunks:

| Mode | Time | Peak RSS |
|---|---:|---:|
| `clean_csv` (in memory) | 9.5 s | 2,264 MB |
| `clean_csv_to_parquet` | 15.7 s | 1,752 MB |
| `clean_csv_to_parquet(..., dedupe=False)` | 13.9 s | 1,421 MB |

Reading the numbers:

- In memory, peak usage is about 4.6 times the file size, so a 16 GB file
  would need around 70 GB. Streaming does not grow that way.
- About 600 MB of every number is the engine's runtime.
- Streaming RSS includes pages of the memory-mapped input file. They count
  while there is free memory and are given back by the OS under pressure, so
  on a file far larger than RAM the streaming peak stays bounded.
- Deduplicating across the whole file costs about 33 bytes per distinct row
  (here 330 MB for 10 million rows). Turn it off with `dedupe=False` if that
  matters more than duplicates.
- Streaming is slower: chunks are parsed one at a time rather than with all
  threads on the whole file.

## Startup

The first call in a process starts the engine: about 1 second, plus a few
seconds once per installation while the runtime unpacks. Benchmarks above
exclude it.
