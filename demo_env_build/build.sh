#!/usr/bin/env bash
# Assembles demo_env/ — the wasm32 ROS 2 + rmw_zenoh_pico prefix
# browser_demo/build_rclc.sh and build_rclpy.sh link against — from two
# already-built rattler-build output channels:
#
#   ROS_ROLLING_OUTPUT       output/ from a `pixi run build-emscripten` in
#                             a checkout of the ros-rolling PR branch
#                             (RoboStack/ros-rolling#46).
#   EMSCRIPTEN_FORGE_OUTPUT  output/ from building the two recipes on
#                             https://github.com/Tobias-Fischer/emscripten-forge-recipes
#                             (branch wasm-pthreads-python-numpy-orphan —
#                             pthreads CPython + numpy) — see that branch's
#                             README for the exact rattler-build commands.
#
# Usage:
#   ROS_ROLLING_OUTPUT=/path/to/ros-rolling/output \
#   EMSCRIPTEN_FORGE_OUTPUT=/path/to/emscripten-forge-recipes/output \
#   ./build.sh
#
# Leaves the finished environment at .pixi/envs/default (symlinked to
# ../demo_env for build_rclc.sh / build_rclpy.sh to pick up).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${ROS_ROLLING_OUTPUT:?Set ROS_ROLLING_OUTPUT to a built ros-rolling output/ dir}"
: "${EMSCRIPTEN_FORGE_OUTPUT:?Set EMSCRIPTEN_FORGE_OUTPUT to a built emscripten-forge-recipes output/ dir}"

sed \
  -e "s#@ROS_ROLLING_OUTPUT@#${ROS_ROLLING_OUTPUT}#" \
  -e "s#@EMSCRIPTEN_FORGE_OUTPUT@#${EMSCRIPTEN_FORGE_OUTPUT}#" \
  "$HERE/pixi.toml.in" > "$HERE/pixi.toml"

cd "$HERE"
rm -rf .pixi pixi.lock
pixi install

# rmw_zenoh_pico gaps this pipeline works around locally, not upstream yet
# (see ../README.md's Known limitations) — not present in the packaged
# rclpy, so patch it here every time the env is (re)assembled.
patch -p1 -d .pixi/envs/default/lib/python3.13/site-packages \
  < "$HERE/../patches/rclpy-node-rmw_zenoh_pico-workarounds.patch"

ln -sfn "$HERE/.pixi/envs/default" "$HERE/../demo_env"
echo "demo_env/ ready -> $HERE/.pixi/envs/default"
