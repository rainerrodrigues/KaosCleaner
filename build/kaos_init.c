// Initialization for hosts that call libkaoscleaner from several threads,
// such as Python. Compiled into the library next to PackageCompiler's
// julia_init.c (see build.jl).
#include "julia.h"
#include "julia_init.h"

#ifdef _OS_WINDOWS_
#define DLLEXPORT __declspec(dllexport)
#else
#define DLLEXPORT
#endif

static int8_t init_gc_state;

DLLEXPORT void kaos_init_julia(int argc, char **argv) {
    init_julia(argc, argv);
    // Julia's init leaves this thread marked as running Julia code, so a
    // garbage collection started by a call from any other thread would wait
    // forever for it to reach a safepoint. Mark it GC-safe, like any thread
    // that is outside Julia; each call into the library enters Julia and
    // restores this state on return.
    init_gc_state = jl_gc_safe_enter(jl_current_task->ptls);
}

// Call from the thread that called kaos_init_julia.
DLLEXPORT void kaos_shutdown_julia(int retcode) {
    jl_gc_safe_leave(jl_current_task->ptls, init_gc_state);
    shutdown_julia(retcode);
}
