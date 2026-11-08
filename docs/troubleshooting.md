# Troubleshooting

## The first call takes several seconds

The first call in a process starts the Julia runtime (about a second). The
very first call after installing also unpacks the runtime into your cache
directory, which takes a few seconds more. Both happen once; time later calls
when benchmarking.

## Where are the files, and how do I remove them?

The unpacked runtime lives in:

| OS | Directory |
|---|---|
| Linux | `$XDG_CACHE_HOME/kaos_cleaner` or `~/.cache/kaos_cleaner` |
| macOS | `~/Library/Caches/kaos_cleaner` |
| Windows | `%LOCALAPPDATA%\kaos_cleaner` |

One subdirectory per installed version; delete old ones freely. A damaged
copy (for example after a crash during unpacking) is detected and unpacked
again automatically.

## "is not a supported wheel on this platform"

The wheel does not match your OS or CPU. Wheels exist for Linux x86_64 with
glibc 2.17 or newer, Linux aarch64 (64-bit ARM), Windows x86_64, and macOS
11+ on Apple silicon. Intel Macs, 32-bit ARM (armv7, such as 32-bit
Raspberry Pi OS) and musl-based distributions (Alpine) are not supported
yet; on a Raspberry Pi, install the 64-bit OS.

## A column was not converted to dates or booleans

Type inference only converts a text column when **every** non-missing value
fits. Check for the odd value out:

```python
df = clean_csv("data.csv")
df.filter(~df["when"].str.contains(r"^\d{2}/\d{2}/\d{4}$"))["when"]
```

Common causes: day/month-ambiguous dates (pass `datetime_formats`), a stray
word in a yes/no column, decimal commas, or percentages. See
[type inference](options.md#type-inference).

## Values became null when streaming

When streaming, types are decided from the first 20,000 rows. Later values
that do not fit become null, and a warning names the column and count:

```text
WARNING:kaos_cleaner:3 values in `flag` did not fit Bool and became missing
```

Clean the file in memory if it fits, pass `infer_types=False` to keep text
columns as text, or fix the input.

## I see no log messages

kaos-cleaner logs to the `"kaos_cleaner"` logger but does not configure
logging. Enable it in your application, for example
`logging.basicConfig(level=logging.INFO)`. See [Logging](logging.md).

## Memory use is high

- In memory, expect peak usage of a few times the file size, plus about
  500 MB for the runtime. Use [streaming](large-files.md) for files that do
  not fit.
- Streaming with `dedupe=True` keeps 16 bytes (about 33 with overhead) per
  distinct row; pass `dedupe=False` for billions of rows.
- Lower `chunk_size` for smaller batches.

## RuntimeError: unknown option / no column named ...

Option values are validated. The message names the problem and lists the
valid choices, for example:

```text
RuntimeError: ArgumentError: unknown impute strategy "avg"; use one of: mean, median, mode, zero, ffill, bfill
RuntimeError: ArgumentError: no column named "Order Id"; columns are: order_id, amount, region
```

Misspelled option *names* raise `TypeError` before the engine is called.

## Using a different build of the engine

Point `KAOSCLEANER_HOME` at a `kaos_binaries/` directory produced by
`julia build.jl`:

```bash
KAOSCLEANER_HOME=/path/to/kaos_binaries python my_script.py
```

## Reporting a bug

Open an issue at
[github.com/rainerrodrigues/KaosCleaner/issues](https://github.com/rainerrodrigues/KaosCleaner/issues)
with the kaos-cleaner version (`kaos_cleaner.__version__`), your OS, the full
error, and if possible a few lines of the file that trigger it.
