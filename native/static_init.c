/* static_init.c — runs Odin's runtime start-up in statically linked builds.
 *
 * Odin starts its runtime (global initialisers, @(init) procedures) from
 * `main` in an executable and from a loader hook in a shared library. The
 * static archive is built with -no-entry-point (Jolt's launcher owns `main`),
 * so nothing would start it. This constructor does, at program load, before
 * any Jolt code calls into the shim — the same moment a shared build gets it.
 */
extern void sk_startup_runtime(void);

__attribute__((constructor))
static void skald_jolt_static_init(void) { sk_startup_runtime(); }
