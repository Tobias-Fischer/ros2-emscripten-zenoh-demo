#!/usr/bin/env bash
# Build the full ros-rolling emscripten-wasm32 + rmw_zenoh_pico recipe
# closure. Run from the root of a RoboStack/ros-rolling checkout (the
# feature/emscripten-wasm32-zenoh-pico branch, or a fork/branch of it).
#
# `pixi run build-emscripten` is a deterministic two-pass sequence (build,
# sync the native-mirror workaround, build again -- see that task's own
# comment in pixi.toml for why two passes is provably enough for this
# recipe set) rather than something that needs discovering by looping
# externally until nothing new gets built. This script just runs it once
# and then verifies every recipe actually produced a package, failing
# loudly (not silently, the way --continue-on-failure alone would) if
# anything is still missing.
set -euo pipefail

echo "::group::pixi run build-emscripten"
pixi run build-emscripten
echo "::endgroup::"

# ---- Verify: fail loudly if anything is still missing after the build --
# that's a genuinely new problem worth seeing in CI logs, not something to
# paper over with another blind retry. Uses find, not `compgen -G`: the
# latter can return exit 0 with no actual match in some shells, silently
# turning this into a no-op that always reports success. -------------------
missing=()
for recipe_dir in recipes/*/; do
  pkg="$(basename "$recipe_dir")"
  if [ -z "$(find output -maxdepth 2 -name "${pkg}-*.tar.bz2" -print -quit)" ]; then
    missing+=("$pkg")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "The following recipes never produced a package after the build:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

echo "Full emscripten-wasm32 + rmw_zenoh_pico closure built successfully."
