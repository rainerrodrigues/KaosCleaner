// Clean a CSV from C with libkaoscleaner, in memory and as a stream.
//
//   cc examples/c/clean.c -Iinclude -Ikaos_binaries/include
//      -Lkaos_binaries/lib -lkaoscleaner -Wl,-rpath,$PWD/kaos_binaries/lib -o clean  (one line)
//   ./clean test_set.csv
#include <stdio.h>
#include <stdint.h>
#include "kaoscleaner.h"

int main(int argc, char** argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s file.csv\n", argv[0]);
        return 2;
    }
    char* julia_args[] = {argv[0], "--threads=auto", NULL};
    kaos_init_julia(2, julia_args);

    // In memory: one struct array with a child per column
    struct ArrowSchema schema;
    struct ArrowArray array;
    if (process_dataset_with_options(argv[1], "{\"impute\": \"median\"}", &schema, &array) != 0) {
        fprintf(stderr, "error: %s\n", kaos_last_error());
        return 1;
    }
    printf("%lld rows, %lld columns\n", (long long)array.length, (long long)schema.n_children);
    for (int64_t i = 0; i < schema.n_children; i++) {
        printf("  %-14s format %-4s nulls %lld\n", schema.children[i]->name, schema.children[i]->format,
               (long long)array.children[i]->null_count);
    }
    array.release(&array);  // the consumer owns the result and frees it
    schema.release(&schema);
    printf("logs: %s\n", kaos_take_logs());

    // Streaming: batches are parsed and cleaned as they are pulled
    struct ArrowArrayStream stream;
    if (kaos_open_stream(argv[1], NULL, 64 * 1024, &stream) != 0) {
        fprintf(stderr, "error: %s\n", kaos_last_error());
        return 1;
    }
    int64_t batches = 0, rows = 0;
    struct ArrowArray batch;
    while (stream.get_next(&stream, &batch) == 0 && batch.release != NULL) {
        batches++;
        rows += batch.length;
        batch.release(&batch);
    }
    const char* err = stream.get_last_error(&stream);
    stream.release(&stream);
    if (err != NULL) {
        fprintf(stderr, "stream error: %s\n", err);
        return 1;
    }
    printf("streamed %lld rows in %lld batches\n", (long long)rows, (long long)batches);

    kaos_shutdown_julia(0);
    return 0;
}
