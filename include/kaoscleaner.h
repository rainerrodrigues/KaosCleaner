#ifndef KAOSCLEANER_H
#define KAOSCLEANER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Arrow C Data Interface, https://arrow.apache.org/docs/format/CDataInterface.html */
#ifndef ARROW_C_DATA_INTERFACE
#define ARROW_C_DATA_INTERFACE

#define ARROW_FLAG_DICTIONARY_ORDERED 1
#define ARROW_FLAG_NULLABLE 2
#define ARROW_FLAG_MAP_KEYS_SORTED 4

struct ArrowSchema {
  const char* format;
  const char* name;
  const char* metadata;
  int64_t flags;
  int64_t n_children;
  struct ArrowSchema** children;
  struct ArrowSchema* dictionary;
  void (*release)(struct ArrowSchema*);
  void* private_data;
};

struct ArrowArray {
  int64_t length;
  int64_t null_count;
  int64_t offset;
  int64_t n_buffers;
  int64_t n_children;
  const void** buffers;
  struct ArrowArray** children;
  struct ArrowArray* dictionary;
  void (*release)(struct ArrowArray*);
  void* private_data;
};

#endif /* ARROW_C_DATA_INTERFACE */

/* Arrow C Stream Interface, https://arrow.apache.org/docs/format/CStreamInterface.html */
#ifndef ARROW_C_STREAM_INTERFACE
#define ARROW_C_STREAM_INTERFACE

struct ArrowArrayStream {
  int (*get_schema)(struct ArrowArrayStream*, struct ArrowSchema* out);
  int (*get_next)(struct ArrowArrayStream*, struct ArrowArray* out);
  const char* (*get_last_error)(struct ArrowArrayStream*);
  void (*release)(struct ArrowArrayStream*);
  void* private_data;
};

#endif /* ARROW_C_STREAM_INTERFACE */

/*
 * Load and clean the CSV at `filepath`, then export it as a struct array
 * (one child per column) into the caller-allocated `out_schema`/`out_array`.
 * Returns 0 on success; on failure returns 1 and leaves both structs untouched.
 * On success the caller owns both structs and must call their `release`.
 * Call kaos_init_julia() once before the first call.
 */
int process_dataset(const char* filepath, struct ArrowSchema* out_schema, struct ArrowArray* out_array);

/*
 * Start the Julia runtime. Unlike init_julia() (julia_init.h), it leaves the
 * calling thread GC-safe, so the library may then be called from any thread.
 * Pass argc = 1 and argv = {"name", NULL}, or add Julia options such as
 * argc = 2, argv = {"name", "--threads=auto", NULL} for multi-threaded parsing.
 */
void kaos_init_julia(int argc, char** argv);

/* Stop the runtime; call from the thread that called kaos_init_julia(). */
void kaos_shutdown_julia(int retcode);

/*
 * process_dataset with cleaning options as a JSON object, e.g.
 * {"drop": ["id"], "impute": "median", "datetime_formats": ["dd/mm/yyyy"]}.
 * Unknown or invalid options fail with a message in kaos_last_error().
 * Pass NULL or "" for the defaults.
 */
int process_dataset_with_options(const char* filepath, const char* options_json,
                                 struct ArrowSchema* out_schema, struct ArrowArray* out_array);

/*
 * Out-of-core cleaning: fill `out_stream` with a stream that parses and cleans
 * `filepath` in chunks of about `chunk_bytes` as batches are pulled with
 * get_next. Options as for process_dataset_with_options; types are planned
 * from the first 20,000 rows and impute accepts only "zero" and "ffill".
 * Returns 0 on success (the caller then owns the stream and must release it)
 * and 1 on failure (see kaos_last_error()).
 */
int kaos_open_stream(const char* filepath, const char* options_json, int64_t chunk_bytes,
                     struct ArrowArrayStream* out_stream);

/* Message describing the last failure ("" after a success). Valid until the next call. */
const char* kaos_last_error(void);

/*
 * Log records since the last call, as a JSON array of [level, message] with
 * Julia levels (Info 0, Warn 1000, Error 2000). Valid until the next call.
 */
const char* kaos_take_logs(void);

#ifdef __cplusplus
}
#endif

#endif /* KAOSCLEANER_H */
