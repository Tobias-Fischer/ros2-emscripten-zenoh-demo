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

# See build_rclc.sh's comment above its own LIBS array for how a list like
# this gets found (empirically, not from a manifest) and what it actually
# means for -sMAIN_MODULE=2. The extra entries here under $SP are the same
# idea applied to rclpy's own Python extension modules -- found the same
# way, but via Python ImportError/dlopen failures rather than wasm-ld's
# link-time errors.
LIBS=(
  "$PREFIX/lib/librclc.so"
  "$PREFIX/lib/librcl.so"
  "$PREFIX/lib/librcl_action.so"
  "$PREFIX/lib/librcl_lifecycle.so"
  "$PREFIX/lib/librcl_yaml_param_parser.so"
  "$PREFIX/lib/librcl_logging_interface.so"
  "$PREFIX/lib/librmw.so"
  "$PREFIX/lib/librmw_zenoh_pico.so"
  "$PREFIX/lib/libzenohpico.so"
  "$PREFIX/lib/librosidl_runtime_c.so"
  "$PREFIX/lib/librcpputils.so"
  "$PREFIX/lib/librcutils.so"
  "$PREFIX/lib/liblibstatistics_collector.so"
  "$PREFIX/lib/libstd_msgs__rosidl_generator_c.so"
  "$PREFIX/lib/libstd_msgs__rosidl_typesupport_c.so"
  "$PREFIX/lib/libstd_msgs__rosidl_typesupport_introspection_c.so"
  "$PREFIX/lib/libstd_msgs__rosidl_typesupport_microxrcedds_c.so"
  "$PREFIX/lib/libbuiltin_interfaces__rosidl_generator_c.so"
  "$PREFIX/lib/libbuiltin_interfaces__rosidl_typesupport_c.so"
  "$PREFIX/lib/libbuiltin_interfaces__rosidl_typesupport_introspection_c.so"
  "$PREFIX/lib/libbuiltin_interfaces__rosidl_typesupport_microxrcedds_c.so"
  "$PREFIX/lib/librcl_interfaces__rosidl_generator_c.so"
  "$PREFIX/lib/librcl_interfaces__rosidl_typesupport_c.so"
  "$PREFIX/lib/librcl_interfaces__rosidl_typesupport_microxrcedds_c.so"
  "$PREFIX/lib/librcl_interfaces__rosidl_typesupport_introspection_c.so"
  "$PREFIX/lib/liblifecycle_msgs__rosidl_generator_c.so"
  "$PREFIX/lib/liblifecycle_msgs__rosidl_typesupport_c.so"
  "$PREFIX/lib/libtype_description_interfaces__rosidl_typesupport_microxrcedds_c.so"
  "$PREFIX/lib/libtype_description_interfaces__rosidl_typesupport_c.so"
  "$PREFIX/lib/libservice_msgs__rosidl_typesupport_microxrcedds_c.so"
  "$PREFIX/lib/libservice_msgs__rosidl_typesupport_c.so"
  "$PREFIX/microcdr-2.0.2/lib/libmicrocdr.so"
  "$SP/rclpy/_rclpy_pybind11.cpython-313-wasm32-emscripten.so"
  "$SP/rcl_interfaces/rcl_interfaces_s__rosidl_typesupport_c.so"
  "$SP/builtin_interfaces/builtin_interfaces_s__rosidl_typesupport_c.so"
  "$SP/std_msgs/std_msgs_s__rosidl_typesupport_c.so"
  "$SP/type_description_interfaces/type_description_interfaces_s__rosidl_typesupport_c.so"
  "$SP/service_msgs/service_msgs_s__rosidl_typesupport_c.so"
  "$SP/numpy/_core/_multiarray_umath.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/_core/_simd.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/linalg/_umath_linalg.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/linalg/lapack_lite.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/fft/_pocketfft_umath.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/random/_common.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/random/_bounded_integers.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/random/bit_generator.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/random/mtrand.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/random/_philox.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/random/_sfc64.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/random/_generator.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/random/_pcg64.cpython-313-wasm32-emscripten.so"
  "$SP/numpy/random/_mt19937.cpython-313-wasm32-emscripten.so"
)

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
# PTHREAD_POOL_SIZE=16 below, not the default handful -- too few pool
# workers for this many concurrently dlopen'd .so files can deadlock
# outright, not just run slow. See build_rclc.sh for the full diagnosis.
em++ \
  -std=c11 -pthread -x c \
  -DZENOH_EMSCRIPTEN -DRMW_IMPLEMENTATION=rmw_zenoh_pico \
  "${INCLUDE_FLAGS[@]}" \
  -s USE_PTHREADS=1 \
  -sPROXY_TO_PTHREAD=1 \
  -sMAIN_MODULE=2 \
  -s ASSERTIONS=1 \
  -fexceptions \
  -sWASM_BIGINT \
  -s USE_ZLIB=1 -s USE_SQLITE3=1 -s USE_BZIP2=1 \
  -lwebsocket.js \
  -s PTHREAD_POOL_SIZE=16 \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s STACK_SIZE=5MB -s DEFAULT_PTHREAD_STACK_SIZE=5MB \
  -s INITIAL_MEMORY=134217728 -s MAXIMUM_MEMORY=1024MB \
  --embed-file "$PY/lib/python3.13@/pyhome/lib/python3.13" \
  --embed-file "$DEMO_DIR/talker_rclpy.py@/pyhome/talker_rclpy.py" \
  -L"$PY/lib" \
  -L"$PREFIX/lib" \
  -L"$PREFIX/microcdr-2.0.2/lib" \
  -Wl,--allow-multiple-definition \
  "$DEMO_DIR/rclpy_boot.c" \
  "$DEMO_DIR/wasm_link_stubs_rclpy.c" \
  -Wl,--start-group -lpython3.13 -lffi -llzma "${LIBS[@]}" -Wl,--end-group \
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
