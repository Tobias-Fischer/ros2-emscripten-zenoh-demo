#!/usr/bin/env bash
# Run via `pixi run build-imu` (from this directory) so `em++` is on
# PATH — see pixi.toml. Needs demo_env/ assembled first (see
# ../docs/demo_env.md).
set -eo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$DEMO_DIR/../demo_env"

command -v em++ >/dev/null || { echo "em++ not found — run this via 'pixi run build-imu', not directly." >&2; exit 1; }

mkdir -p "$DEMO_DIR/out"

# The emscripten-forge toolchain env's own activation script sets
# EMCC_CFLAGS="... -sSUPPORT_LONGJMP=wasm -fwasm-exceptions" globally --
# every em++ call gets native wasm exception-handling by default, which
# crashes binaryen's Asyncify pass outright ("UNREACHABLE executed ...
# Asyncify.cpp"), not just compiles slower. Override it here, dropping just
# the exception-handling part (matching the toolchain's own base flags).
export EMCC_CFLAGS="-O2 -g0 -fPIC -msimd128"

# Same geometry_msgs LIBS set as build_teleop.sh (identical message type).
LIBS=(
  "$PREFIX/lib/librclc.so"
  "$PREFIX/lib/librcl.so"
  "$PREFIX/lib/librcl_yaml_param_parser.so"
  "$PREFIX/lib/librcl_logging_interface.so"
  "$PREFIX/lib/librmw.so"
  "$PREFIX/lib/librmw_zenoh_pico.so"
  "$PREFIX/lib/libzenohpico.so"
  "$PREFIX/lib/librosidl_runtime_c.so"
  "$PREFIX/lib/librosidl_typesupport_microxrcedds_c.so"
  "$PREFIX/lib/librcutils.so"
  "$PREFIX/lib/liblibstatistics_collector.so"
  "$PREFIX/lib/libgeometry_msgs__rosidl_generator_c.so"
  "$PREFIX/lib/libgeometry_msgs__rosidl_typesupport_c.so"
  "$PREFIX/lib/libgeometry_msgs__rosidl_typesupport_introspection_c.so"
  "$PREFIX/lib/libgeometry_msgs__rosidl_typesupport_microxrcedds_c.so"
  "$PREFIX/lib/libbuiltin_interfaces__rosidl_typesupport_microxrcedds_c.so"
  "$PREFIX/microcdr-2.0.2/lib/libmicrocdr.so"
)

INCLUDE_FLAGS=(-I"$PREFIX/include")
for d in "$PREFIX"/include/*/; do
  INCLUDE_FLAGS+=(-I"${d%/}")
done

em++ \
  -std=c11 -x c \
  -DZENOH_EMSCRIPTEN -DRMW_IMPLEMENTATION=rmw_zenoh_pico \
  "${INCLUDE_FLAGS[@]}" \
  -sMAIN_MODULE=2 \
  -s ASSERTIONS=1 \
  -fexceptions \
  -sWASM_BIGINT \
  -sINVOKE_RUN=0 \
  -sEXPORTED_RUNTIME_METHODS=ccall,HEAPF64,HEAP32,stringToUTF8,callMain \
  -lwebsocket.js \
  -sSOCKET_DEBUG=1 \
  -sASYNCIFY -s ASYNCIFY_STACK_SIZE=24576 \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s MAXIMUM_MEMORY=1024MB \
  -L"$PREFIX/lib" \
  -L"$PREFIX/microcdr-2.0.2/lib" \
  "$DEMO_DIR/imu_rclc.c" \
  "$DEMO_DIR/wasm_link_stubs.c" \
  "${LIBS[@]}" \
  -o "$DEMO_DIR/out/imu_rclc.js"

cp "${LIBS[@]}" "$DEMO_DIR/out/"
cp "$DEMO_DIR/index_imu.html" "$DEMO_DIR/demo-page.css" "$DEMO_DIR/out/"

echo "Build finished: $DEMO_DIR/out/imu_rclc.js / imu_rclc.wasm"
