#!/usr/bin/env bash
# Run via `pixi run build-rclc` (from this directory) so `em++` is on PATH —
# see pixi.toml. Needs demo_env/ assembled first (see ../docs/demo_env.md).
set -eo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$DEMO_DIR/../demo_env"

command -v em++ >/dev/null || { echo "em++ not found — run this via 'pixi run build-rclc', not directly." >&2; exit 1; }

mkdir -p "$DEMO_DIR/out"

# Not derived from any manifest or dependency-graph tool — found empirically,
# the only real option given the architecture. -sMAIN_MODULE=2 means em++
# only resolves symbols against .so files actually passed on the command
# line (no implicit transitive pull-in the way a native linker's rpath/soname
# resolution would give you); passing a .so this way *also* stages it next
# to the output for the runtime's dylink loader to dlopen on demand (that's
# why there's no separate `cp` step here, unlike build_rclpy.sh). Regenerate
# by starting from just talker_rclc.c's direct includes (rclc, rmw_zenoh_pico)
# and iterating: link/run, and for every "unable to find library -lX" from
# wasm-ld or a 404 fetching X.so from the browser console, add
# lib/libX.so and retry -- until it both links and runs end-to-end
# against a real zenoh router with no further errors. Some entries below
# turned out not to be strictly required at *link* time (removing one and
# relinking can succeed) but are still needed for the *runtime* dylink
# closure another .so pulls in lazily -- link success alone doesn't confirm
# an entry is safe to drop, only a full run does.
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

# PTHREAD_POOL_SIZE=16 below, not the default handful: this MAIN_MODULE=2
# build dlopen's ~90 .so files on startup, and instantiating that many wasm
# modules across too few pre-spawned pool workers can deadlock outright
# rather than just run slow -- reproduced live (embedded "Run demo" card,
# real router running): every .so fetched fine (200s across the board) and
# several pool workers reached initRuntime, then it sat at "still waiting
# on run dependencies: dependency: loadDylibs" with zero further output,
# indefinitely. A standalone demo page loading the identical .so closure
# via a fresh navigation (no service worker fetch-wrapping in front of it)
# didn't reproduce it in repeated local tries at the old size 4 -- so this
# looks like ordinary pool-exhaustion, just one that only bites once fetch
# latency (here, coi-serviceworker.js's retry-wrapped requests) stretches
# the window where enough loads are in flight at once to exceed the pool.
# Confirmed fixed at 16 against the live site.
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
  -sINVOKE_RUN=0 \
  -sEXPORTED_RUNTIME_METHODS=ccall,stringToUTF8,callMain \
  -lwebsocket.js \
  -sSOCKET_DEBUG=1 \
  -s PTHREAD_POOL_SIZE=16 \
  -s ALLOW_MEMORY_GROWTH=1 \
  -s MAXIMUM_MEMORY=1024MB \
  -L"$PREFIX/lib" \
  -L"$PREFIX/microcdr-2.0.2/lib" \
  "$DEMO_DIR/talker_rclc.c" \
  "$DEMO_DIR/wasm_link_stubs.c" \
  "${LIBS[@]}" \
  -o "$DEMO_DIR/out/talker_rclc.js"

cp "$DEMO_DIR/index_rclc.html" "$DEMO_DIR/demo-page.css" "$DEMO_DIR/out/"

echo "Build finished: $DEMO_DIR/out/talker_rclc.js / talker_rclc.wasm"
