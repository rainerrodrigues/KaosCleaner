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
 * Pass argc = 1 and argv = {"name", NULL}.
 */
void kaos_init_julia(int argc, char** argv);

/* Stop the runtime; call from the thread that called kaos_init_julia(). */
void kaos_shutdown_julia(int retcode);

/* Message describing the last failure ("" after a success). Valid until the next call. */
const char* kaos_last_error(void);

#ifdef __cplusplus
}
#endif

#endif /* KAOSCLEANER_H */
