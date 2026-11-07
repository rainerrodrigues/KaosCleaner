# kaos-cleaner

Fast CSV cleaning for Python, powered by a pre-compiled Julia engine. Results
come back through the Arrow C Data Interface as a `pyarrow.Table` or a
`polars.DataFrame`, with no Julia installation needed.

```bash
pip install kaos-cleaner
```

```python
from kaos_cleaner import clean_csv, process_dataset

df = clean_csv("data.csv")            # polars.DataFrame
table = process_dataset("data.csv")   # pyarrow.Table
```

## What the cleaning does

- Treats `""`, `NA`, `N/A`, `NaN`, `null`, `NULL`, `None` (and lowercase variants) as missing
- Detects integer, float, boolean, date and datetime columns
- Trims whitespace in text cells
- Renames columns to unique `snake_case` (`" Spend (USD)"` → `spend_usd`)
- Drops rows that are entirely empty, and duplicate rows

Errors (a missing file, an unreadable CSV) are raised as `RuntimeError` with
the engine's message.

## Good to know

- **First import** unpacks the bundled Julia runtime (~600 MB) into your user
  cache directory (`~/.cache/kaos_cleaner` on Linux, `~/Library/Caches` on
  macOS, `%LOCALAPPDATA%` on Windows). This takes a few seconds once; later
  imports start in well under a second.
- **Platforms:** wheels are built for Linux x86_64 (glibc 2.17+), Windows
  x86_64 and macOS arm64. There is no source distribution.
- **Threads:** calls are serialized; it is safe to call from several threads.
- Set `KAOSCLEANER_HOME` to a `kaos_binaries/` directory to use your own build
  of the engine.

## License

MIT. The wheel bundles the Julia runtime and Julia packages under their own
(mostly MIT) licenses; their texts are in `share/licenses/` inside the
unpacked runtime.
