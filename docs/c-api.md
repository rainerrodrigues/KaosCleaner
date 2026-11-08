# C API

The engine is a native shared library with a plain C interface, so any
language that can call C and read Arrow data can use it: C, C++, Rust, Go, R,
Java through the Arrow C Data Interface. The Python package is one such
caller.

## Getting the SDK

Each [GitHub release](https://github.com/rainerrodrigues/KaosCleaner/releases)
has a C SDK per platform, `libkaoscleaner-<version>-<os>-<arch>.tar.xz`
(for example `libkaoscleaner-0.1.5-linux-x86_64.tar.xz`). Unpack it anywhere
and build against it with pkg-config:

```bash
mkdir kaoscleaner && tar -xJf libkaoscleaner-*-linux-x86_64.tar.xz -C kaoscleaner
```
```bash
export PKG_CONFIG_PATH=$PWD/kaoscleaner/lib/pkgconfig
```
```bash
cc myprogram.c $(pkg-config --cflags --libs kaoscleaner) -o myprogram
```

The pkg-config file is relocatable and adds an rpath on Linux and macOS, so
the program finds the library in the unpacked directory without
`LD_LIBRARY_PATH`. On Windows, link against `bin/libkaoscleaner.dll` and keep
the `bin/` directory next to your program or on `PATH`.

## Files

An SDK (or a local build with `julia build.jl`) contains:

| Path | What |
|---|---|
| `lib/libkaoscleaner.so` / `.dylib`, `bin/libkaoscleaner.dll` | The library |
| `lib/`, `lib/julia/`, `bin/` | The Julia runtime it loads |
| `include/kaoscleaner.h` | This API, including the Arrow struct definitions |
| `include/julia_init.h` | PackageCompiler's plain `init_julia` |
| `lib/pkgconfig/kaoscleaner.pc` | pkg-config file |
| `share/` | Runtime data and third-party licenses |

Keep the directory together: the library finds its runtime relative to
itself.

## Lifecycle

```c
char* args[] = {"myapp", "--threads=auto", NULL};
kaos_init_julia(2, args);    // once per process, before anything else
/* ... calls from any thread ... */
kaos_shutdown_julia(0);      // optional, from the thread that called init
```

`kaos_init_julia` takes Julia command-line options; `--threads=N` or `auto`
enables multi-threaded parsing. Use it rather than `init_julia` from
`julia_init.h` if more than one thread will call the library:
`init_julia` leaves the starting thread in a state that deadlocks Julia's
garbage collector when another thread calls in.

## Functions

| Function | Purpose |
|---|---|
| `int process_dataset_with_options(const char* path, const char* options_json, struct ArrowSchema*, struct ArrowArray*)` | Clean a file into caller-allocated Arrow structs |
| `int process_dataset(const char* path, struct ArrowSchema*, struct ArrowArray*)` | Same with default options |
| `int kaos_open_stream(const char* path, const char* options_json, int64_t chunk_bytes, struct ArrowArrayStream*)` | Clean a file chunk by chunk as an Arrow stream |
| `int kaos_clean_arrow(struct ArrowSchema* in_schema, struct ArrowArray* in_array, const char* options_json, struct ArrowSchema* out_schema, struct ArrowArray* out_array)` | Clean a record batch already in memory |
| `const char* kaos_last_error(void)` | Message for the last failure |
| `const char* kaos_take_logs(void)` | Log records since the last call, as JSON |

Functions returning `int` return 0 on success and 1 on failure. Strings
returned by the library stay valid until the next call into it; copy them if
you need them longer.

The cleaning functions may be called from any thread, but the error message
and the log buffer are shared by the whole process. If several threads call
the library and read `kaos_last_error` or `kaos_take_logs`, serialize those
calls with a lock, as the Python package does; otherwise one thread can read
another thread's message.

`options_json` is a JSON object with the keys described in
[Cleaning options](options.md), for example
`{"drop": ["id"], "impute": "median"}`. `NULL` or `""` means defaults.

## Results and memory

`process_dataset_with_options` fills a struct array (format `+s`) with one
child per column. Column formats are standard Arrow: `l` int64, `g` float64,
`b` boolean, `u` UTF-8 string, `tdD` date, `tsm:` timestamp in milliseconds,
`n` all-null.

The caller owns both structs once the call succeeds and must call their
`release` callbacks when done; that frees the engine's buffers. Importing
them into an Arrow implementation (`arrow::ImportRecordBatch` in C++,
`arrow::ffi` in Rust, `RecordBatch._import_from_c` in PyArrow) transfers that
responsibility to the importer.

## Cleaning data in memory

`kaos_clean_arrow` takes a record batch (a struct array, format `+s`) that
the caller exported through the C Data Interface, cleans it, and fills the
output structs as `process_dataset_with_options` does. Input columns may be
`n`, `b`, the integer formats `c C s S i I l L`, `f`/`g` floats, `u`/`U`
strings, `tdD`/`tdm` dates, and `tss:`/`tsm:`/`tsu:`/`tsn:` timestamps
without a time zone; anything else (dictionaries, time zones, nested types)
is an error. Convert such columns first, as the Python package's
`clean_table` does.

The library copies the values and **always releases the input structs**,
on success and on failure, so the caller must not release them again. The
parsing options (`delimiter`, `decimal`, ...) have no effect here.

## Streams

`kaos_open_stream` fills an `ArrowArrayStream`. Call `get_schema` once and
`get_next` until it returns an array whose `release` is `NULL` (end of
stream); release each batch and finally the stream. On a non-zero return,
`get_last_error` describes the problem. All batches share the schema from
`get_schema`, with every field nullable. Streaming limits are described in
[Large files](large-files.md).

## Logs

`kaos_take_logs` returns the records collected since the previous call as a
JSON array of `[level, message]` pairs, with Julia's levels: Info `0`,
Warn `1000`, Error `2000`:

```json
[[0, "Dropped 2 empty rows"], [1000, "thread = 1 warning: only found 3 / 4 columns around data row: 12"]]
```

## Example

[`examples/c/clean.c`](https://github.com/rainerrodrigues/KaosCleaner/blob/main/examples/c/clean.c)
cleans a file in memory and as a stream:

```c
#include <stdio.h>
#include <stdint.h>
#include "kaoscleaner.h"

int main(int argc, char** argv) {
    char* julia_args[] = {argv[0], "--threads=auto", NULL};
    kaos_init_julia(2, julia_args);

    struct ArrowSchema schema;
    struct ArrowArray array;
    if (process_dataset_with_options(argv[1], "{\"impute\": \"median\"}", &schema, &array) != 0) {
        fprintf(stderr, "error: %s\n", kaos_last_error());
        return 1;
    }
    printf("%lld rows, %lld columns\n", (long long)array.length, (long long)schema.n_children);
    array.release(&array);
    schema.release(&schema);

    struct ArrowArrayStream stream;
    if (kaos_open_stream(argv[1], NULL, 64 * 1024, &stream) != 0) {
        fprintf(stderr, "error: %s\n", kaos_last_error());
        return 1;
    }
    struct ArrowArray batch;
    int64_t rows = 0;
    while (stream.get_next(&stream, &batch) == 0 && batch.release != NULL) {
        rows += batch.length;
        batch.release(&batch);
    }
    stream.release(&stream);
    printf("streamed %lld rows\n", (long long)rows);

    kaos_shutdown_julia(0);
    return 0;
}
```

Build and run it against a local build:

```bash
cc examples/c/clean.c -Iinclude -Ikaos_binaries/include -Lkaos_binaries/lib -lkaoscleaner -Wl,-rpath,$PWD/kaos_binaries/lib -o clean
```
```bash
./clean test_set.csv
```
