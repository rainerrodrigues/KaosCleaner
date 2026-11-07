# How it works

```text
 Python                         │  libkaoscleaner (compiled Julia)
                                │
 clean_csv("data.csv", ...)     │
   │  options → JSON            │
   └──── process_dataset_with_options(path, json, schema*, array*) ──►
                                │   CSV.jl: parse with all CPU threads
                                │   clean, infer types, dedupe, impute
                                │   write columns into malloc'd Arrow buffers
   ◄──────────── fills ArrowSchema / ArrowArray structs ────────────────
   pyarrow imports the buffers  │
   (no copy, no serialisation)  │
   polars.from_arrow(...)       │
   …later: table dropped ───── release() callback frees the buffers ──►
```

## The engine

The cleaning code is a Julia package built on
[CSV.jl](https://github.com/JuliaData/CSV.jl) and
[DataFrames.jl](https://dataframes.juliadata.org). At build time,
[PackageCompiler.jl](https://github.com/JuliaLang/PackageCompiler.jl)
compiles it, together with the Julia runtime, into a native shared library
with a C interface. A precompile run on representative files means the code
paths you hit are already machine code, not compiled on first use.

## The handoff

Results cross the language boundary through the
[Arrow C Data Interface](https://arrow.apache.org/docs/format/CDataInterface.html):
Python allocates two small structs, the engine fills them with pointers to
column buffers it has written, and PyArrow wraps those buffers as they are.
When the last Python reference to the table goes away, PyArrow calls the
engine's release callback, which frees the memory. Large files use the
[Arrow C Stream Interface](https://arrow.apache.org/docs/format/CStreamInterface.html)
the same way, one batch at a time.

## Safety at the boundary

A few details keep the two runtimes from tripping over each other:

- **Threads**: the engine starts so that calls (and release callbacks) may
  come from any Python thread without deadlocking Julia's garbage collector.
- **Memory**: the engine collects its own garbage after each call, so memory
  stays flat across thousands of files.
- **Logging**: engine messages are buffered and handed to Python after each
  call instead of calling into Python mid-parse.
- **Hostile input**: invalid UTF-8, ragged rows, binary garbage and files
  with a thousand columns come back as a valid table or a Python exception,
  never a crash. The test suite checks this in isolated child processes.
