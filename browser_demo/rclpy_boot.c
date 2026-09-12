// Embeds CPython + runs the talker script directly, rather than a
// standalone python.js. Extension modules (rclpy's own pybind11 module,
// each message package's rosidl_generator_py typesupport accessor,
// numpy's C extensions) are NOT statically registered here -- this
// python is a stock, non-pthreads emscripten-forge-4x build (see
// ../docs/demo_env.md), so Python's normal `import` machinery dlopen()s
// each compiled .so from site-packages on demand, the same way
// jupyterlite-xeus's xeus-python kernel loads this exact rclpy build.
// (An earlier revision of this file statically embedded every extension
// module via PyImport_AppendInittab() -- a workaround for a
// pthreads-enabled CPython build, since removed; see rmw_wait's Asyncify
// rewrite in RoboStack/ros-rolling#46 for why pthreads isn't needed
// anymore. Static embedding also triggered a wasm-ld crash linking that
// many .so's worth of relocations directly into one MAIN_MODULE, not
// just being needless complexity.)

#include <Python.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <emscripten/emscripten.h>

// DIAGNOSTIC: plain dlopen()'s sync wrapper (see emscripten's
// _dlopen_js in libdylink.js) swallows the real rejection reason on
// failure -- `.catch(() => wakeUp(0))` discards it entirely without
// ever calling dlSetError(), which is why both a raw dlopen() probe and
// CPython's own import (which also just calls plain dlopen() under the
// hood) only ever see "unknown dlopen() error" / a NULL dlerror(). The
// explicit async API's error callback path (_emscripten_dlopen_js) does
// call dlSetError() with the real reason first -- use that here instead.
static volatile int g_diag_done = 0;
static void diag_onsuccess(void *user_data, void *handle) {
  printf("DIAG: emscripten_dlopen SUCCEEDED, handle=%p\n", handle);
  fflush(stdout);
  g_diag_done = 1;
}
static void diag_onerror(void *user_data) {
  printf("DIAG: emscripten_dlopen FAILED: %s\n", dlerror());
  fflush(stdout);
  g_diag_done = 1;
}

int main(int argc, char *argv[]) {
  setenv("RCL_LOGGING_IMPLEMENTATION", "rcl_logging_noop", 1);

  // DIAGNOSTIC: force libzenohpico.so to load (and register its exports
  // globally) before anything else in the dependency graph. Its header
  // (protocol/core.h) defines `extern const _z_id_t empty_id;`, inlined via
  // a `static inline` helper into every rosidl_typesupport_microxrcedds_c/
  // cpp translation unit (and transitively almost every message typesupport
  // .so) -- so nearly every side module in this graph has an unresolved
  // *data* import for `empty_id`, only satisfiable once libzenohpico.so is
  // actually loaded with RTLD_GLOBAL. Unlike function imports, wasm dylink
  // resolves data (GOT.mem) imports synchronously at each module's own load
  // time, so load ORDER matters -- if some typesupport .so loads before
  // libzenohpico.so does, this aborts. Preload it explicitly here to rule
  // that out as the cause of the (formerly generic, now precisely-reported
  // via emscripten_dlopen) 'undefined symbol empty_id' abort.
  g_diag_done = 0;
  printf("DIAG: preloading libzenohpico.so\n");
  fflush(stdout);
  emscripten_dlopen("libzenohpico.so", RTLD_NOW | RTLD_GLOBAL, NULL, diag_onsuccess, diag_onerror);
  while (!g_diag_done) {
    emscripten_sleep(10);
  }

  // DIAGNOSTIC: same technique as the libzenohpico.so preload above, now
  // aimed at numpy's own _multiarray_umath.so -- CPython's import (via
  // plain dlopen()) still only ever reports "unknown dlopen() error" for
  // this one, so probe it directly first to get the real reason.
  g_diag_done = 0;
  printf("DIAG: probing _multiarray_umath.so\n");
  fflush(stdout);
  emscripten_dlopen(
      "/pyhome/lib/python3.13/site-packages/numpy/_core/_multiarray_umath.cpython-313-wasm32-emscripten.so",
      RTLD_NOW | RTLD_GLOBAL, NULL, diag_onsuccess, diag_onerror);
  while (!g_diag_done) {
    emscripten_sleep(10);
  }

  // Preload librmw_zenoh_pico.so with RTLD_GLOBAL before anything else
  // dlopen's it transitively -- same rationale as the libzenohpico.so
  // preload above (load-order matters for cross-.so data-symbol
  // resolution in this dylink graph).
  g_diag_done = 0;
  printf("DIAG: preloading librmw_zenoh_pico.so\n");
  fflush(stdout);
  emscripten_dlopen("librmw_zenoh_pico.so", RTLD_NOW | RTLD_GLOBAL, NULL, diag_onsuccess, diag_onerror);
  while (!g_diag_done) {
    emscripten_sleep(10);
  }
  {
    void *h = dlopen("librmw_zenoh_pico.so", RTLD_NOW | RTLD_GLOBAL | RTLD_NOLOAD);
    if (h != NULL) {
      typedef void (*set_unicast_fn)(const char *, const char *, const char *, const char *);
      set_unicast_fn set_unicast = (set_unicast_fn)dlsym(h, "rmw_zenoh_pico_set_unicast");
      if (set_unicast != NULL) {
        // Bare host/port, matching config.h's own compiled-in defaults --
        // rmw_zenoh_pico_init_option() builds the actual "ws/host:port"
        // locator itself; passing an already-schemed string here (tried
        // earlier) double-prefixes it into a malformed locator.
        set_unicast("127.0.0.1", "7447", NULL, NULL);
        printf("DIAG: rmw_zenoh_pico_set_unicast(\"127.0.0.1\", \"7447\", NULL, NULL) applied\n");
      } else {
        printf("DIAG: dlsym(rmw_zenoh_pico_set_unicast) failed: %s\n", dlerror());
      }
      fflush(stdout);
    }
  }

  // rmw_zenoh_pico's compiled-in default connect address (config.h:
  // RMW_ZENOH_PICO_CONNECT="127.0.0.1", RMW_ZENOH_PICO_CONNECT_PORT="7447")
  // already matches zenohd's own listen address below -- no override
  // needed, exactly like talker_rclc.c's own demo (it only calls
  // rmw_zenoh_pico_set_unicast() when its own JS-writable host buffer is
  // non-empty, i.e. never, for the default case). rmw_zenoh_pico_init_option()
  // builds the actual locator as "ws/<host>:<port>" vs. "tcp/<host>:<port>"
  // depending on whether ZENOH_EMSCRIPTEN was defined when *it* was
  // compiled (RoboStack/ros-rolling's own patch, gated on
  // vinca's build_ament_cmake.sh.in template defining that macro for the
  // emscripten-wasm32 target) -- nothing to do here at the Python/C-boot
  // level as long as that's correctly wired up on the package side.

  Py_SetPythonHome(L"/pyhome");
  Py_Initialize();

  int rc = PyRun_SimpleString(
    "import sys\n"
    "sys.path.insert(0, '/pyhome/lib/python3.13/site-packages')\n"
    "exec(open('/pyhome/talker_rclpy.py').read())\n"
  );
  printf("rclpy_boot: PyRun_SimpleString rc=%d\n", rc);
  if (rc != 0) {
    PyErr_Print();
  }
  Py_Finalize();
  return rc;
}
