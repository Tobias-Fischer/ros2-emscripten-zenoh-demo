#!/usr/bin/env bash
# Run via `pixi run build-teleop` (from this directory) so `em++` is on
# PATH — see pixi.toml. Needs demo_env/ assembled first (see
# ../docs/demo_env.md), including geometry_msgs (added there specifically
# for this demo).
set -eo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$DEMO_DIR/../demo_env"

command -v em++ >/dev/null || { echo "em++ not found — run this via 'pixi run build-teleop', not directly." >&2; exit 1; }

mkdir -p "$DEMO_DIR/out"

# Same LIBS set as build_rclc.sh, plus geometry_msgs' own generator/
# typesupport .so's (same 4-library pattern std_msgs needed: generator_c,
# typesupport_c, typesupport_introspection_c, typesupport_microxrcedds_c).
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
  -std=c11 -pthread -x c \
  -DZENOH_EMSCRIPTEN -DRMW_IMPLEMENTATION=rmw_zenoh_pico \
  "${INCLUDE_FLAGS[@]}" \
  -s USE_PTHREADS=1 \
  -sPROXY_TO_PTHREAD=1 \
  -sMAIN_MODULE=2 \
  -s ASSERTIONS=1 \
  -fexceptions \
  -sWASM_BIGINT \
  -sEXPORTED_RUNTIME_METHODS=ccall,HEAPF64 \
  -lwebsocket.js \
  -sSOCKET_DEBUG=1 \
  -s PTHREAD_POOL_SIZE=4 \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s MAXIMUM_MEMORY=1024MB \
  -L"$PREFIX/lib" \
  -L"$PREFIX/microcdr-2.0.2/lib" \
  "$DEMO_DIR/teleop_rclc.c" \
  "$DEMO_DIR/wasm_link_stubs.c" \
  "${LIBS[@]}" \
  -o "$DEMO_DIR/out/teleop_rclc.js"

# build_rclc.sh's own comment claims -sMAIN_MODULE=2 auto-stages every .so
# passed on the command line next to the output -- true for std_msgs, but
# empirically *not* true here: libgeometry_msgs__rosidl_generator_c.so
# still 404'd at runtime despite being linked. Deploying the LIBS set
# explicitly instead of relying on that (matching build_rclpy.sh's own
# explicit `cp`, for the same reason) is more robust either way.
cp "${LIBS[@]}" "$DEMO_DIR/out/"

echo "Build finished: $DEMO_DIR/out/teleop_rclc.js / teleop_rclc.wasm"
