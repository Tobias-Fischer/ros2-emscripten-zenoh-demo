#!/usr/bin/env bash
# Run via `pixi run build-rclpy` (from this directory) so `em++` is on PATH —
# see pixi.toml. Needs demo_env/ assembled first (see ../docs/demo_env.md).
set -eo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$DEMO_DIR/../demo_env"
PY="$PREFIX"
SP="$PREFIX/lib/python3.13/site-packages"

command -v em++ >/dev/null || { echo "em++ not found — run this via 'pixi run build-rclpy', not directly." >&2; exit 1; }

mkdir -p "$DEMO_DIR/out"

# The emscripten-forge toolchain env's own activation script sets
# EMCC_CFLAGS="... -sSUPPORT_LONGJMP=wasm -fwasm-exceptions" -- kept as-is
# here (matching every other package in this project, all built with
# vinca's own now-Asyncify-free, -fwasm-exceptions default), since the
# dlopen'd side .so's Python imports at runtime (many of them real C++,
# e.g. librosidl_typesupport_cpp.so, libament_index_cpp.so) are compiled
# that same way and need this MAIN_MODULE to provide matching
# native-wasm-exception-handling runtime support once they actually
# throw/catch. See EMCC_FORCE_STDLIBS below for how that support
# actually gets in here, since nothing in this file's own C code needs it
# directly.
export EMCC_CFLAGS="-O2 -g0 -fPIC -msimd128 -sSUPPORT_LONGJMP=wasm -fwasm-exceptions"

# This MAIN_MODULE's own compiled code (rclpy_boot.c) barely touches libc
# directly, so without this, symbols the *dlopen'd side modules* need at
# runtime (stdout/stderr/etc, libc++ exception machinery, and anything
# else no root reference here pulls in) never get compiled into the main
# module or exported for them -- "Assertion failed: undefined symbol
# 'stderr'. perhaps a side module was not linked in?", confirmed live.
# Scoped to just libc/libc++/libc++abi/libunwind (not "1" for literally
# everything): EMCC_FORCE_STDLIBS=1 also drags in libwebgpu's stub
# bindings, which then need their own JS-side WebGPU imports wired in for
# no benefit here. libunwind specifically (added after libc++abi/
# libcompiler_rt turned out not to be enough on their own) provides
# _Unwind_CallPersonality/__wasm_lpad_context -- Unwind-wasm.c's actual
# native-wasm-exception unwinder, needed once dlopen'd C++ .so's (compiled
# with vinca's -fwasm-exceptions default, like everything else in this
# project) throw/catch for real -- confirmed via a real "undefined symbol
# '__wasm_lpad_context'" without it.
export EMCC_FORCE_STDLIBS=libc,libc++,libc++abi,libunwind,libcompiler_rt

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
# dlopen'd side modules (every ROS .so, numpy, rclpy's own pybind11
# module) reference assorted libc/libc++ symbols (stdio globals,
# program_invocation_name, and libc++'s exception-handling/RTTI machinery
# -- pybind11 translates any C++ exception a wrapped call throws into a
# Python one, so the *type information* for every std:: exception type it
# might see has to be resolvable across the dylink boundary, not just
# each exception class's own code) that EMCC_FORCE_STDLIBS above links
# the defining objects for. -sMAIN_MODULE=1 (below), not =2, is what
# actually exports all of them: this file used to build with =2 plus a
# large hand-curated EXPORTED_FUNCTIONS list, adding one symbol at a time
# every time a newly-reached one turned up missing (plain "undefined
# symbol" failures for the libc ones, then mangled-name libc++ RTTI/vtable
# symbols like `_ZTTNSt3__214basic_ifstreamIcNS_11char_traitsIcEEEE`, with
# no way to know the *next* one short of getting further into rclpy's own
# import chain and hitting it) -- =2's dead-code elimination keeps
# dropping anything nothing in this module's own root code touches,
# regardless of what EMCC_FORCE_STDLIBS links in as available. =1 (a
# larger main module, but this demo already ships a ~57 MB embedded
# CPython + site-packages tree, so the difference isn't the bottleneck)
# exports everything unconditionally instead, ending that whack-a-mole
# for good.
em++ \
  -std=c11 -x c \
  -DZENOH_EMSCRIPTEN -DRMW_IMPLEMENTATION=rmw_zenoh_pico \
  "${INCLUDE_FLAGS[@]}" \
  -sMAIN_MODULE=1 \
  -s ASSERTIONS=1 \
  -fwasm-exceptions \
  -sWASM_BIGINT \
  -s USE_ZLIB=1 -s USE_SQLITE3=1 -s USE_BZIP2=1 \
  -lwebsocket.js \
  -sSOCKET_DEBUG=1 \
  -sEXIT_RUNTIME=0 \
  -sINVOKE_RUN=0 \
  -sEXPORTED_RUNTIME_METHODS=ccall,callMain,loadDynamicLibrary,stringToUTF8 \
  -s DEFAULT_LIBRARY_FUNCS_TO_INCLUDE=emscripten_random \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s STACK_SIZE=5MB \
  -s INITIAL_MEMORY=134217728 -s MAXIMUM_MEMORY=1024MB \
  --embed-file "$PY/lib/python3.13@/pyhome/lib/python3.13" \
  --embed-file "$DEMO_DIR/talker_rclpy.py@/pyhome/talker_rclpy.py" \
  -L"$PY/lib" \
  "$DEMO_DIR/rclpy_boot.c" \
  "$DEMO_DIR/wasm_link_stubs_rclpy.c" \
  -Wl,--start-group -lpython3.13 -lffi -llzma "$PY/lib/libssl.a" "$PY/lib/libcrypto.a" -Wl,--end-group \
  -o "$DEMO_DIR/out/rclpy_boot.js"

echo "Build finished: $DEMO_DIR/out/rclpy_boot.js / rclpy_boot.wasm"

# numpy's own compiled extensions (built separately by emscripten-forge-4x,
# not by this project's vinca pipeline) still expect the old JS-exception-
# model invoke_* trampolines for indirect calls -- this MAIN_MODULE's own
# proxyHandler doesn't generically provide those. See
# ../patches/patch_rclpy_boot_js.mjs's own header comment for the full story.
node "$DEMO_DIR/../patches/patch_rclpy_boot_js.mjs" "$DEMO_DIR/out/rclpy_boot.js"

# Emscripten's MAIN_MODULE loader resolves each "needed" shared library by
# basename, relative to the deployed .js file's own directory -- not via the
# -L paths used at link time above. Every dylink dependency has to sit flat
# next to rclpy_boot.js, regardless of where it lived in demo_env/. *.so*
# (not just *.so): microcdr installs versioned SONAMEs (libmicrocdr.so.2.0,
# .so.2.0.2) alongside the plain .so, unlike every other package here --
# and those are themselves a *.so -> *.so.2.0 -> *.so.2.0.2 symlink chain,
# not independent files, so -L (dereference) turns each into a real,
# independently-fetchable copy instead of a symlink some deploy pipeline
# (GitHub Pages' own upload-artifact step included) might not preserve.
cp -L "$PREFIX"/lib/*.so* "$DEMO_DIR/out/"
find "$SP" -iname "*.so" -exec cp {} "$DEMO_DIR/out/" \;
cp "$DEMO_DIR/index_rclpy.html" "$DEMO_DIR/out/index_rclpy.html"
cp "$DEMO_DIR/demo-page.css" "$DEMO_DIR/out/"
echo "Deployed $(find "$DEMO_DIR/out" -iname '*.so' | wc -l | tr -d ' ') shared libraries to $DEMO_DIR/out/"

# rclpy_boot.c links no .so directly (see the big comment above the em++
# invocation), so this MAIN_MODULE's own dylink metadata declares zero
# "needed" libraries -- nothing gets eagerly preloaded at startup the way
# build_rclc.sh's LIBS array does. Without this, the *first* time Python's
# `import rclpy` chain reaches a plain (synchronous) dlopen() for one of
# these -- e.g. librcl_action.so, a real dependency of
# _rclpy_pybind11...so -- it hits "file not found, and synchronous loading
# of external files is not available", even though the file is right there
# on the server: browsers don't support synchronous XHR for an
# on-the-fly fetch, only Module.loadDynamicLibrary()'s async path does.
# List every plain shared library here (skip real CPython extension
# modules, named *.cpython-313-wasm32-emscripten.so -- those are meant to
# be lazily dlopen'd by Python's own import machinery, which already
# works correctly once their own non-Python dependencies below are
# preloaded) so index_rclpy.html can eagerly Module.loadDynamicLibrary()
# each one -- with retries, since ROS2's typesupport/introspection
# libraries have circular/cross-package dependencies discovered in
# arbitrary order -- before ever calling into main()/Python. Same
# approach as patches/patch_stock_xpython_js.mjs's "safe-eager-preload-
# with-retry" patch for jupyterlite-xeus's xpython.js, just written
# directly here since this file (unlike stock xpython.js) is one we
# control the build of.
# rcl_logging_spdlog and its own libspdlog dependency are excluded here
# deliberately, not just an oversight: rclpy_boot.c sets
# RCL_LOGGING_IMPLEMENTATION=rcl_logging_noop before rclc_support_init()
# ever runs, so nothing in this demo actually needs the spdlog backend --
# and eagerly preloading it anyway hits a genuinely separate problem
# (spdlog uses std::ifstream; "undefined symbol
# '_ZTTNSt3__214basic_ifstreamIcNS_11char_traitsIcEEEE'", a libc++
# iostream vtable EMCC_FORCE_STDLIBS above doesn't happen to keep, since
# MAIN_MODULE's own dead-code elimination only keeps what's actually
# reachable from something -- nothing here uses iostreams either). Not
# worth chasing for a backend this demo never selects.
find "$DEMO_DIR/out" -maxdepth 1 -iname '*.so' -exec basename {} \; \
  | grep -v '\.cpython-313-wasm32-emscripten\.so$' \
  | grep -v '^librcl_logging_spdlog\.so$' \
  | grep -v '^libspdlogd\.so' \
  | python3 -c 'import json,sys; json.dump(sorted(l.strip() for l in sys.stdin), sys.stdout)' \
  > "$DEMO_DIR/out/rclpy_dylibs.json"
echo "Wrote $(python3 -c "import json; print(len(json.load(open('$DEMO_DIR/out/rclpy_dylibs.json'))))") eager-preload entries to rclpy_dylibs.json"
