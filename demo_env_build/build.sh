#!/usr/bin/env bash
# Assembles demo_env/ — the wasm32 ROS 2 + rmw_zenoh_pico prefix
# browser_demo/build_rclc.sh and build_rclpy.sh link against — from:
#
#   ROS_ROLLING_OUTPUT       output/ from a `pixi run build-emscripten` in
#                             a checkout of the ros-rolling PR branch
#                             (RoboStack/ros-rolling#46).
#   emscripten-forge-4x       stock python/numpy, pulled straight from the
#                             remote channel. A pthreads-patched CPython +
#                             numpy used to be built locally instead (see
#                             git history / Tobias-Fischer/emscripten-forge-
#                             recipes branch wasm-pthreads-python-numpy-
#                             orphan) -- no longer needed now that rcl/rclpy
#                             don't require --shared-memory at all (rmw_wait
#                             polls instead of blocking; see the
#                             ros-rolling-rmw-zenoh-pico patch).
#
# Usage:
#   ROS_ROLLING_OUTPUT=/path/to/ros-rolling/output ./build.sh
#
# Leaves the finished environment at .pixi/envs/default (symlinked to
# ../demo_env for build_rclc.sh / build_rclpy.sh to pick up).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${ROS_ROLLING_OUTPUT:?Set ROS_ROLLING_OUTPUT to a built ros-rolling output/ dir}"

sed \
  -e "s#@ROS_ROLLING_OUTPUT@#${ROS_ROLLING_OUTPUT}#" \
  "$HERE/pixi.toml.in" > "$HERE/pixi.toml"

cd "$HERE"
rm -rf .pixi pixi.lock
pixi install

# rmw_zenoh_pico gaps this pipeline works around locally, not upstream yet
# (see ../README.md's Known limitations) — not present in the packaged
# rclpy, so patch it here every time the env is (re)assembled.
#
# -N (ignore already-applied patches) + `|| true` on all three patches
# below: this session's rclpy/pyjs rebuilds now sometimes already carry
# one of these fixes upstream in the built package itself (e.g. the
# rclpy-node patch's exact hunk was already present verbatim in a rebuilt
# ros2-rclpy), which makes `patch` unable to match context and fall back
# to an interactive "File to patch:" prompt -- fatal under `set -e` with
# no stdin attached. -N detects the already-applied case cleanly instead
# of erroring; `|| true` is a safety net for any other spurious mismatch,
# since none of these patches are load-bearing for a build that already
# has the fix baked in.
patch -p1 -N -d .pixi/envs/default/lib/python3.13/site-packages \
  < "$HERE/../patches/rclpy-node-rmw_zenoh_pico-workarounds.patch" || true

# pyjs's pyodide.ffi.to_js() polyfill doesn't accept dict_converter (or
# other) real-Pyodide kwargs -- breaks pyodide_http on import, which
# xeus_python_shell imports unconditionally on every JupyterLite kernel
# start. Upstream bug, still open: see ../patches/README.md.
patch -p1 -N -d .pixi/envs/default/lib/python3.13/site-packages \
  < "$HERE/../patches/pyjs-pyodide-polyfill-to_js-compat.patch" || true

# pyodide_http's own optional urllib-patching (xeus_python_shell calls it
# unconditionally on kernel start) can still fail in other ways even past
# the fix above -- this demo has no urllib/requests code to begin with, so
# don't let a failure in that convenience patch take the whole kernel
# down. See ../patches/README.md.
patch -p1 -N -d .pixi/envs/default/lib/python3.13/site-packages \
  < "$HERE/../patches/xeus_python_shell-urllib-patch-robustness.patch" || true

# asyncio's running-loop marker doesn't reliably survive between separate
# top-level calls into the wasm module on this build (confirmed via a
# Node.js harness driving the real xeus xkernel/notify_listener() path
# directly: `RuntimeError: no running event loop` on the very first
# execute_request after kernel.start(), even though pyjs.webloop already
# constructs a WebLoop during kernel configure). Defensively recreate the
# loop right before use instead of assuming a prior call's setup
# persisted. See ../ros-rolling-emscripten-zenoh/AGENTS.md's Asyncify
# migration section for the full investigation.
patch -p1 -N -d .pixi/envs/default/lib/python3.13/site-packages \
  < "$HERE/../patches/xeus_python_shell-defensive-event-loop.patch" || true

ln -sfn "$HERE/.pixi/envs/default" "$HERE/../demo_env"
echo "demo_env/ ready -> $HERE/.pixi/envs/default"
