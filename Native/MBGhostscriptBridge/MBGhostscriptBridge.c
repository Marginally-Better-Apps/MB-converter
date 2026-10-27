#include "MBGhostscriptBridge.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

#include "iapi.h"
#include "ierrors.h"
#include "gsmemory.h"
#include "gslibctx.h"

static pthread_mutex_t mbgs_lock = PTHREAD_MUTEX_INITIALIZER;

/* Ghostscript's %pipe% device is the only thing that spawns processes. Even -dSAFER trusts
   pipes named on the command line, so the linked library gets these instead of libc's: no
   job can start a process, and the binary does not import popen at all. */
__attribute__((visibility("hidden"))) FILE *popen(const char *command, const char *mode) {
    (void)command; (void)mode;
    errno = EPERM;
    return NULL;
}

__attribute__((visibility("hidden"))) int pclose(FILE *stream) {
    (void)stream;
    errno = ECHILD;
    return -1;
}

/* Ghostscript is built with CHECK_INTERRUPTS, which makes it call this often during a job.
   Upstream only implements it for Windows; this is the same thing: ask the poll hook. */
__attribute__((visibility("hidden"))) int gp_check_interrupts(const gs_memory_t *mem) {
    if (mem && mem->gs_lib_ctx && mem->gs_lib_ctx->core->poll_fn)
        return mem->gs_lib_ctx->core->poll_fn(mem->gs_lib_ctx->core->poll_caller_handle);
    return 0;
}

typedef struct {
    mbgs_output_callback output;
    void *context;
    const int *cancel;
    int cancelled;
} mbgs_sink;

static int GSDLLCALL mbgs_stdin(void *handle, char *buffer, int length) {
    (void)handle; (void)buffer; (void)length;
    return 0; /* No interactive input: -dBATCH -dNOPAUSE runs never read stdin. */
}

static int GSDLLCALL mbgs_stdout(void *handle, const char *text, int length) {
    mbgs_sink *sink = handle;
    if (sink && sink->output) sink->output(sink->context, text, length);
    return length;
}

/* Ghostscript polls between operations; a negative result aborts the job. */
static int GSDLLCALL mbgs_poll(void *handle) {
    mbgs_sink *sink = handle;
    if (sink->cancel && __atomic_load_n(sink->cancel, __ATOMIC_RELAXED)) {
        sink->cancelled = 1;
        return gs_error_interrupt;
    }
    return 0;
}

int mbgs_run(int argc, const char *const *argv, mbgs_output_callback output, void *context, const int *cancel) {
    if (argc < 1 || !argv) return gs_error_undefined;
    pthread_mutex_lock(&mbgs_lock);
    mbgs_sink sink = { output, context, cancel, 0 };
    void *instance = NULL;
    int code = gsapi_new_instance(&instance, &sink);
    if (code >= 0) {
        gsapi_set_stdio(instance, mbgs_stdin, mbgs_stdout, mbgs_stdout);
        gsapi_set_poll_with_handle(instance, mbgs_poll, &sink);
        code = gsapi_set_arg_encoding(instance, GS_ARG_ENCODING_UTF8);
        if (code == 0) code = gsapi_init_with_args(instance, argc, (char **)argv);
        int exit_code = gsapi_exit(instance);
        /* gs_error_Quit means the job ended normally via `quit`. */
        if (code == 0 || code == gs_error_Quit) code = exit_code;
        gsapi_delete_instance(instance);
    }
    pthread_mutex_unlock(&mbgs_lock);
    if (sink.cancelled) return MBGS_CANCELLED;
    return code == gs_error_Quit ? 0 : code;
}

const char *mbgs_version(void) {
    static char version[32];
    gsapi_revision_t revision;
    if (version[0] == 0 && gsapi_revision(&revision, sizeof(revision)) == 0) {
        long r = revision.revision;
        snprintf(version, sizeof(version), "%ld.%02ld.%ld", r / 1000, (r / 10) % 100, r % 10);
    }
    return version;
}
