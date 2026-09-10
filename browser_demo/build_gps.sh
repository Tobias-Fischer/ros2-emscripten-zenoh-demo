#!/usr/bin/env bash
# Run via `pixi run build-gps` (from this directory) so `em++` is on
# PATH — see pixi.toml. Needs demo_env/ assembled first (see
# ../docs/demo_env.md), including sensor_msgs (added there specifically
# for this demo).
set -eo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$DEMO_DIR/../demo_env"

command -v em++ >/dev/null || { echo "em++ not found — run this via 'pixi run build-gps', not directly." >&2; exit 1; }

mkdir -p "$DEMO_DIR/out"

# Same LIBS set as build_teleop.sh, swapping geometry_msgs for
# sensor_msgs, plus std_msgs (NavSatFix's header field needs it) -- both
# already present in build_rclc.sh's own LIBS for the same reason.
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
  "$PREFIX/lib/libsensor_msgs__rosidl_generator_c.so"
  "$PREFIX/lib/libsensor_msgs__rosidl_typesupport_c.so"
  "$PREFIX/lib/libsensor_msgs__rosidl_typesupport_introspection_c.so"
  "$PREFIX/lib/libsensor_msgs__rosidl_typesupport_microxrcedds_c.so"
  "$PREFIX/lib/libstd_msgs__rosidl_generator_c.so"
  "$PREFIX/lib/libstd_msgs__rosidl_typesupport_c.so"
  "$PREFIX/lib/libstd_msgs__rosidl_typesupport_introspection_c.so"
  "$PREFIX/lib/libstd_msgs__rosidl_typesupport_microxrcedds_c.so"
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
  -sEXPORTED_RUNTIME_METHODS=ccall,HEAPF64,HEAP32 \
  -lwebsocket.js \
  -sSOCKET_DEBUG=1 \
  -s PTHREAD_POOL_SIZE=4 \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s MAXIMUM_MEMORY=1024MB \
  -L"$PREFIX/lib" \
  -L"$PREFIX/microcdr-2.0.2/lib" \
  "$DEMO_DIR/gps_rclc.c" \
  "$DEMO_DIR/wasm_link_stubs.c" \
  "${LIBS[@]}" \
  -o "$DEMO_DIR/out/gps_rclc.js"

cp "${LIBS[@]}" "$DEMO_DIR/out/"
cp "$DEMO_DIR/demo-page.css" "$DEMO_DIR/out/"

echo "Build finished: $DEMO_DIR/out/gps_rclc.js / gps_rclc.wasm"
