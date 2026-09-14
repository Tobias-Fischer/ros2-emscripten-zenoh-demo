#!/usr/bin/env bash
# Run via `pixi run build-rclc` (from this directory) so `em++` is on PATH —
# see pixi.toml. Needs demo_env/ assembled first (see ../docs/demo_env.md).
set -eo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$DEMO_DIR/../demo_env"

command -v em++ >/dev/null || { echo "em++ not found — run this via 'pixi run build-rclc', not directly." >&2; exit 1; }

mkdir -p "$DEMO_DIR/out"

# Used to override EMCC_CFLAGS here to drop the toolchain's default
# -fwasm-exceptions (native wasm exception handling), because it used to
# crash binaryen's Asyncify pass outright. Now that this build no longer
# uses Asyncify at all (see rclc_demo_tick() in talker_rclc.c and
# vinca commit f6c8903, "fix: drop Asyncify project-wide"), that override
# is not just unneeded but actively wrong: librclc.so/librcl.so/etc. are
# themselves now compiled with -fwasm-exceptions (the toolchain's real
# default, restored by that same vinca commit), and a MAIN_MODULE built
# with a *different* exception-handling model (-fexceptions, JS-based)
# doesn't provide the wasm-EH runtime intrinsics
# (__cpp_exception/_Unwind_CallPersonality/__wasm_lpad_context) those side
# modules import -- confirmed via a real link failure, "undefined symbol:
# __cpp_exception" et al. Leave EMCC_CFLAGS alone; use -fwasm-exceptions
# below to match.

# Not derived from any manifest or dependency-graph tool — found empirically,
# the only real option given the architecture. -sMAIN_MODULE=2 means em++
# only resolves symbols against .so files actually passed on the command
# line (no implicit transitive pull-in the way a native linker's rpath/soname
# resolution would give you). Despite that, it does *not* stage them next to
# the output for the runtime's dylink loader to fetch -- confirmed via a real
# 404 on librclc.so in a from-scratch `out/` dir -- so they still need the
# same explicit `cp` build_teleop.sh and its siblings already use. Regenerate
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

em++ \
  -std=c11 -x c \
  -DZENOH_EMSCRIPTEN -DRMW_IMPLEMENTATION=rmw_zenoh_pico \
  "${INCLUDE_FLAGS[@]}" \
  -sMAIN_MODULE=2 \
  -s ASSERTIONS=1 \
  -fwasm-exceptions \
  -sWASM_BIGINT \
  -sINVOKE_RUN=0 \
  -sEXIT_RUNTIME=0 \
  -sEXPORTED_RUNTIME_METHODS=ccall,stringToUTF8,callMain \
  -lwebsocket.js \
  -sSOCKET_DEBUG=1 \
  -s ALLOW_MEMORY_GROWTH=1 \
  -L"$PREFIX/lib" \
  -L"$PREFIX/microcdr-2.0.2/lib" \
  "$DEMO_DIR/talker_rclc.c" \
  "$DEMO_DIR/wasm_link_stubs.c" \
  "${LIBS[@]}" \
  -o "$DEMO_DIR/out/talker_rclc.js"

cp "${LIBS[@]}" "$DEMO_DIR/out/"
cp "$DEMO_DIR/index_rclc.html" "$DEMO_DIR/demo-page.css" "$DEMO_DIR/out/"

echo "Build finished: $DEMO_DIR/out/talker_rclc.js / talker_rclc.wasm"
