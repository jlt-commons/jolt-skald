/* x11_dl.c — lazy libX11 forwarder for statically linked Skald binaries.
 *
 * Skald calls six Xlib functions directly (window title and transparent-visual
 * selection on X11). A normal Skald build links libX11 dynamically, but
 * `jolt build` links :static natives with -Bstatic, which would mean baking
 * all of Xlib (and xcb, Xau, Xdmcp) into the binary.
 *
 * Instead this archive defines those six symbols and forwards each call to
 * libX11.so.6, opened with dlopen on first use — the same way SDL3 itself
 * loads X11. On a system without libX11 (Wayland-only), XOpenDisplay returns
 * NULL, which Skald already handles, and the rest are never reached.
 *
 * Only built into the static archive set (`jolt native-static`); the shared
 * library build links the real libX11 as usual.
 */
#include <dlfcn.h>
#include <stddef.h>
#include <pthread.h>

typedef struct _XDisplay Display;
typedef unsigned long XID;
typedef unsigned long Atom;
typedef int Bool;

static void *lib;
static pthread_once_t once = PTHREAD_ONCE_INIT;

static void open_x11(void) {
    lib = dlopen("libX11.so.6", RTLD_NOW | RTLD_LOCAL);
    if (!lib) lib = dlopen("libX11.so", RTLD_NOW | RTLD_LOCAL);
}

static void *sym(const char *name) {
    pthread_once(&once, open_x11);
    return lib ? dlsym(lib, name) : NULL;
}

#define FORWARD(ret, name, params, args, fallback)          \
    ret name params {                                       \
        static ret (*fn) params;                            \
        if (!fn) fn = (ret (*) params) sym(#name);          \
        return fn ? fn args : fallback;                     \
    }

FORWARD(Display *, XOpenDisplay, (const char *n), (n), NULL)
FORWARD(int, XCloseDisplay, (Display *d), (d), 0)
FORWARD(int, XFree, (void *p), (p), 0)
FORWARD(Atom, XInternAtom, (Display *d, const char *n, Bool only_if_exists),
        (d, n, only_if_exists), 0)
FORWARD(int, XChangeProperty,
        (Display *d, XID w, Atom prop, Atom type, int format, int mode,
         const unsigned char *data, int n),
        (d, w, prop, type, format, mode, data, n), 0)
/* XVisualInfo is opaque here: Skald reads it through its own struct. */
FORWARD(void *, XGetVisualInfo, (Display *d, long mask, void *tmpl, int *n),
        (d, mask, tmpl, n), NULL)
