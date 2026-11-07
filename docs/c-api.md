# C API

The engine is a native shared library with a plain C interface, so any
language that can call C and read Arrow data can use it: C, C++, Rust, Go, R,
Java through the Arrow C Data Interface. The Python package is one such
caller.

## Files

A build (`julia build.jl`, or the runtime inside a wheel) contains:

| Path | What |
|---|---|
| `lib/libkaoscleaner.so` / `.dylib`, `bin/libkaoscleaner.dll` | The library |
| `lib/`, `lib/julia/`, `bin/` | The Julia runtime it loads |
| `include/kaoscleaner.h` | This API, including the Arrow struct definitions |
| `include/julia_init.h` | PackageCompiler's plain `init_julia` |
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
| `const char* kaos_last_error(void)` | Message for the last failure |
| `const char* kaos_take_logs(void)` | Log records since the last call, as JSON |

Functions returning `int` return 0 on success and 1 on failure. Strings
returned by the library stay valid until the next call into it; copy them if
you need them longer.

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
