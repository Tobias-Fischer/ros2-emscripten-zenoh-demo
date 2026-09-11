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
  Py_Finalize();
  return rc;
}
