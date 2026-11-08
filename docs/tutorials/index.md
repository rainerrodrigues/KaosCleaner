# Tutorials

Step-by-step walkthroughs, each built around a small, realistic messy file.
Every tutorial creates its own sample data, so you can paste the code into a
Python session and follow along; the output shown is what it prints.

| Tutorial | You will learn to |
|---|---|
| [1. Clean your first file](first-file.md) | clean a messy CSV, read the engine's log, tune the cleaning, save the result |
| [2. Odd formats](formats.md) | read European number formats, title lines, TSV and Parquet files, and clean pandas DataFrames |
| [3. A robot's sensor log](robot-log.md) | convert ROS-style timestamps, remove glitches, fill dropped samples and fuse two sensors at a common rate |
| [4. Live data](live-data.md) | clean a feed batch by batch with state carried over |
| [5. Audit and undo](audit-undo.md) | trace every cleaned row to the file and get the original values back |
| [6. Files larger than memory](large-files.md) | clean a million-row file in chunks into Parquet |

Install first:

```bash
pip install kaos-cleaner
```

The tutorials use polars for display, which kaos-cleaner installs. Tutorial 2
also uses pandas.
