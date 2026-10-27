#ifndef MB_GHOSTSCRIPT_BRIDGE_H
#define MB_GHOSTSCRIPT_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/* Receives Ghostscript's stdout/stderr text. */
typedef void (*mbgs_output_callback)(void *context, const char *text, int length);

/* Returned when a job stops because *cancel became non-zero. */
#define MBGS_CANCELLED (-1000)

/* Runs Ghostscript with the given arguments (argv[0] is ignored, as with the gs CLI).
   Calls are serialized: Ghostscript keeps process-wide state. Returns 0 on success, or
   Ghostscript's error code. The text Ghostscript prints goes to `output` (may be NULL).
   Setting *cancel (may be NULL) to non-zero from another thread stops the job early. */
int mbgs_run(int argc, const char *const *argv, mbgs_output_callback output, void *context, const int *cancel);

/* "10.08.0" */
const char *mbgs_version(void);

#ifdef __cplusplus
}
#endif

#endif
