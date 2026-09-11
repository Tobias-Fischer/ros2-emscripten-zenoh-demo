#!/usr/bin/env bash
# Run via `pixi run build-rclpy` (from this directory) so `em++` is on PATH —
# see pixi.toml. Needs demo_env/ assembled first (see ../docs/demo_env.md).
#
# KNOWN ISSUE (not yet resolved): this links and runs -- no more wasm-ld
# crash, no more main-module "undefined symbol" aborts -- but `import
# rclpy` still fails with a generic "unknown dlopen() error" dlopen()ing
# rclpy's own `_rclpy_pybind11.*.so` specifically (the largest, most
# symbol-heavy of the ~190 side modules this pulls in). CPython's dlopen
# wrapper doesn't propagate whatever the underlying JS-level reason is.
# Every other .so in the dependency graph (librcl.so, librmw.so, the
# microxrcedds typesupport chain, etc.) dlopens fine first. Next step:
# get the raw underlying error out of emscripten's dlopen (e.g. a
# from-C dlopen()+dlerror() probe, bypassing CPython's wrapper) rather
# than continuing to guess at EXPORTED_FUNCTIONS entries one at a time.
set -eo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$DEMO_DIR/../demo_env"
PY="$PREFIX"
SP="$PREFIX/lib/python3.13/site-packages"

command -v em++ >/dev/null || { echo "em++ not found — run this via 'pixi run build-rclpy', not directly." >&2; exit 1; }

mkdir -p "$DEMO_DIR/out"

# The emscripten-forge toolchain env's own activation script sets
# EMCC_CFLAGS="... -sSUPPORT_LONGJMP=wasm -fwasm-exceptions" globally --
# every em++ call gets native wasm exception-handling by default, which
# crashes binaryen's Asyncify pass outright ("UNREACHABLE executed ...
# Asyncify.cpp"), not just compiles slower. Override it here, dropping just
# the exception-handling part (matching the toolchain's own base flags).
export EMCC_CFLAGS="-O2 -g0 -fPIC -msimd128"

# This MAIN_MODULE's own compiled code (rclpy_boot.c) barely touches libc
# directly, so without this, symbols the *dlopen'd side modules* need at
# runtime (stdout/stderr/etc, libc++ exception machinery, and anything
# else no root reference here pulls in) never get compiled into the main
# module or exported for them -- "Assertion failed: undefined symbol
# 'stderr'. perhaps a side module was not linked in?", confirmed live.
# Scoped to just libc/libc++/libc++abi (not "1" for literally everything):
# EMCC_FORCE_STDLIBS=1 also drags in libwebgpu's stub bindings, which
# then need their own JS-side WebGPU imports wired in for no benefit here.
export EMCC_FORCE_STDLIBS=libc,libc++,libc++abi

# Unlike build_rclc.sh's LIBS array, rclpy's own extension modules and
# every ROS .so it transitively needs are NOT linked directly into this
# executable -- Python's normal `import` dlopen()s them from site-packages
# at runtime instead (see rclpy_boot.c's own comment for why; briefly,
# directly linking this many .so's worth of relocations, together with a
# statically-linked libpython3.13.a and Asyncify, crashed wasm-ld
# outright). They still need to physically exist next to the deployed
# .js/.wasm output for the browser to fetch, which the `cp`/`find` block
# at the bottom of this script handles regardless of link-time linkage.

INCLUDE_FLAGS=(-I"$PREFIX/include")
for d in "$PREFIX"/include/*/; do
  INCLUDE_FLAGS+=(-I"${d%/}")
done

# --embed-file below bakes the whole lib/python3.13 tree (site-packages
# included) into the wasm binary's static data -- adding xeus-python to
# demo_env (see ../demo_env_build/pixi.toml.in) lands its own files in that
# same site-packages and pushed the required initial memory past the old
# 64 MB ("wasm-ld: error: initial memory too small, ~80.7 MB needed"); 128 MB
# below leaves real headroom rather than just clearing today's number.
#
# EXPORTED_FUNCTIONS below: dlopen'd side modules (every ROS .so, numpy,
# rclpy's own pybind11 module) reference assorted libc/libc++ symbols
# (stdio globals, program_invocation_name, and libc++'s exception-
# handling/RTTI machinery -- pybind11 translates any C++ exception a
# wrapped call throws into a Python one, so the *type information* for
# every std:: exception type it might see has to be resolvable across
# the dylink boundary, not just each exception class's own code) that
# EMCC_FORCE_STDLIBS above links the defining objects for but doesn't by
# itself export -- MAIN_MODULE's dead-code elimination still drops
# anything nothing in this module's own root code touches. Found one at
# a time (each only surfacing once the previous one was fixed): plain
# "undefined symbol" assertion failures for the plain libc ones, then
# (once those were exhausted) a "bad export type ... can potentially be
# ignored" warning for every libc++ RTTI symbol -- which is actually
# wrong for the specific ones something ends up calling; the warning's
# optimism doesn't hold once _rclpy_pybind11.so is actually dlopen'd and
# throws through one of these types. A blanket -Wl,--export-all instead
# pulls in unrelated stub object files (EMCC_FORCE_STDLIBS=1 links in
# literally everything, WebGPU bindings included) needing their own
# JS-side imports -- scoping EMCC_FORCE_STDLIBS to libc/libc++/libc++abi
# above avoids that without giving up on an explicit list here.
em++ \
  -std=c11 -x c \
  -DZENOH_EMSCRIPTEN -DRMW_IMPLEMENTATION=rmw_zenoh_pico \
  "${INCLUDE_FLAGS[@]}" \
  -sMAIN_MODULE=2 \
  -s ASSERTIONS=1 \
  -fexceptions \
  -sWASM_BIGINT \
  -s USE_ZLIB=1 -s USE_SQLITE3=1 -s USE_BZIP2=1 \
  -lwebsocket.js \
  -sASYNCIFY -s ASYNCIFY_STACK_SIZE=24576 \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s STACK_SIZE=5MB \
  -s INITIAL_MEMORY=134217728 -s MAXIMUM_MEMORY=1024MB \
  -s EXPORTED_FUNCTIONS=_main,_stdin,_stdout,_stderr,_program_invocation_name,_program_invocation_short_name,__ZNSt13runtime_errorD1Ev,__ZTISt13runtime_error,__ZTVN10__cxxabiv120__si_class_type_infoE,__ZTISt9exception,__ZNSt12length_errorD1Ev,__ZTISt12length_error,__ZTVSt12length_error,__ZNSt16invalid_argumentD1Ev,__ZTISt16invalid_argument,__ZTVSt16invalid_argument,__ZTVNSt3__218basic_stringstreamIcNS_11char_traitsIcEENS_9allocatorIcEEEE,__ZTTNSt3__218basic_stringstreamIcNS_11char_traitsIcEENS_9allocatorIcEEEE,__ZTVNSt3__215basic_stringbufIcNS_11char_traitsIcEENS_9allocatorIcEEEE,__ZNSt20bad_array_new_lengthD1Ev,__ZTISt20bad_array_new_length,__ZNSt9bad_allocD1Ev,__ZTISt9bad_alloc,__ZNSt3__24cerrE,__ZNSt3__25ctypeIcE2idE,__ZTVN10__cxxabiv117__class_type_infoE,__ZNSt3__212system_errorD1Ev,__ZTINSt3__212system_errorE,__ZNKSt3__219__shared_weak_count13__get_deleterERKSt9type_info,__ZTINSt3__219__shared_weak_countE,___cxa_atexit \
  --embed-file "$PY/lib/python3.13@/pyhome/lib/python3.13" \
  --embed-file "$DEMO_DIR/talker_rclpy.py@/pyhome/talker_rclpy.py" \
  -L"$PY/lib" \
  "$DEMO_DIR/rclpy_boot.c" \
  "$DEMO_DIR/wasm_link_stubs_rclpy.c" \
  -Wl,--start-group -lpython3.13 -lffi -llzma "$PY/lib/libssl.a" "$PY/lib/libcrypto.a" -Wl,--end-group \
  -o "$DEMO_DIR/out/rclpy_boot.js"

echo "Build finished: $DEMO_DIR/out/rclpy_boot.js / rclpy_boot.wasm"

# Emscripten's MAIN_MODULE loader resolves each "needed" shared library by
# basename, relative to the deployed .js file's own directory -- not via the
# -L paths used at link time above. Every dylink dependency has to sit flat
# next to rclpy_boot.js, regardless of where it lived in demo_env/.
cp "$PREFIX"/lib/*.so "$DEMO_DIR/out/"
cp -L "$PREFIX"/microcdr-2.0.2/lib/*.so* "$DEMO_DIR/out/"
find "$SP" -iname "*.so" -exec cp {} "$DEMO_DIR/out/" \;
cp "$DEMO_DIR/index_rclpy.html" "$DEMO_DIR/out/index_rclpy.html"
cp "$DEMO_DIR/demo-page.css" "$DEMO_DIR/out/"
echo "Deployed $(find "$DEMO_DIR/out" -iname '*.so' | wc -l | tr -d ' ') shared libraries to $DEMO_DIR/out/"
