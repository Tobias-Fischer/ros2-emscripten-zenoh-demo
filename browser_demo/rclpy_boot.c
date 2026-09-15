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
//
// This file used to also carry three emscripten_dlopen()+emscripten_sleep()
// diagnostic preload blocks (for libzenohpico.so, numpy's
// _multiarray_umath.so, and librmw_zenoh_pico.so) plus an
// rmw_zenoh_pico_set_unicast() call gated on one of them -- exploratory
// debugging for a since-resolved "unknown dlopen() error"/load-ordering
// issue (see git history if the detail is ever needed again), the one
// thing in this file that actually required -sASYNCIFY (emscripten_sleep
// needs it to cooperatively wait for the async callback). Removed once
// the exact same non-Asyncify, non-pthreads dlopen chain was confirmed
// working end-to-end elsewhere in this project (jupyterlite-xeus's own
// xeus-python kernel imports this identical rclpy build via plain
// CPython `import`, no special preloading) -- see AGENTS.md for that
// verification. Dropping these also lets this file drop Asyncify
// entirely, matching every other package in this build (see
// talker_rclc.c and vinca commit f6c8903).

#include <Python.h>
#include <stdio.h>
#include <stdlib.h>
#include <emscripten.h>

// Runtime-configurable zenoh connect address, same mechanism as
// talker_rclc.c's zenoh_connect_host/port: main() is linked with
// -sINVOKE_RUN=0 so index_rclpy.html can write into these buffers (via
// ccall) before calling Module.callMain(), which runs talker_rclpy.py
// below. talker_rclpy.py reads them back via ctypes.CDLL(None) (this
// executable's own exported symbols -- -sMAIN_MODULE=1 exports everything
// unconditionally, no EXPORTED_FUNCTIONS entry needed) and passes them to
// rmw_zenoh_pico_set_unicast() itself, since this file -- unlike
// talker_rclc.c -- never links librmw_zenoh_pico.so directly (Python's
// own `import rclpy` chain dlopen()s it lazily). Left blank (the default),
// talker_rclpy.py's override is a no-op and rmw_zenoh_pico's compiled-in
// default (127.0.0.1:7447) is used, matching index_rclc.html's behavior.
#define ZENOH_HOST_MAX 64
#define ZENOH_PORT_MAX 8
static char zenoh_connect_host[ZENOH_HOST_MAX] = "";
static char zenoh_connect_port[ZENOH_PORT_MAX] = "";

EMSCRIPTEN_KEEPALIVE
char * zenoh_get_connect_host_buf(void) { return zenoh_connect_host; }

EMSCRIPTEN_KEEPALIVE
char * zenoh_get_connect_port_buf(void) { return zenoh_connect_port; }

// talker_rclpy.py does rclpy.init() + defines a tick() function, but
// doesn't call it -- rmw_zenoh_pico's z_open() can't block for its
// WebSocket handshake, so (same as talker_rclc.c) a single blocking
// rclpy.spin(node) call here would just freeze this synchronous main()
// forever without ever letting the "open" event reach the JS event loop.
// index_rclpy.html drives tick() repeatedly instead, via
// rclpy_demo_tick() below, once main() has returned.
EMSCRIPTEN_KEEPALIVE
void rclpy_demo_tick(void) {
  if (PyRun_SimpleString("tick()") != 0) {
    PyErr_Print();
  }
}

int main(int argc, char *argv[]) {
  setenv("RCL_LOGGING_IMPLEMENTATION", "rcl_logging_noop", 1);

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
  // Deliberately no Py_Finalize()/return here -- the interpreter (and
  // everything talker_rclpy.py just defined, including tick()) needs to
  // stay alive for rclpy_demo_tick() above to keep calling into it.
  return 0;
}
