#!/usr/bin/env bash
# Build the full ros-rolling emscripten-wasm32 + rmw_zenoh_pico recipe
# closure. Run from the root of a RoboStack/ros-rolling checkout (the
# feature/emscripten-wasm32-zenoh-pico branch, or a fork/branch of it).
#
# A single `pixi run build-emscripten` isn't quite enough to get a
# genuinely clean checkout all the way to a full closure: several
# packages' generated recipes declare a build:-time (build-platform, i.e.
# native osx-arm64) dependency on rosidl_default_generators, which no
# channel actually publishes for this platform. ros-rolling's own
# `sync-native-bootstrap-mirror` pixi task satisfies it by mirroring
# already-built emscripten-wasm32 packages into a fake osx-arm64 channel
# entry (see that task's own comment in pixi.toml for the full story) --
# but only packages built *before* the mirror was last synced are visible
# to it, so a cold build needs sync+build repeated until nothing new
# appears.
#
# This used to also need two disjoint groups of packages rebuilt with a
# scoped typesupport override, working around a rosidl_typesupport_microxrcedds_cpp
# codegen gap for ROS 2's auto-generated service/action "_Event" messages.
# That's fixed at the source now (see
# patch/ros-rolling-rosidl-typesupport-microxrcedds-cpp.patch and the
# upstream PR linked from it) -- a single `pixi run build-emscripten` with
# both typesupport overrides set globally now builds the entire closure,
# no scoped rebuilds needed.
set -euo pipefail

sync_mirror() {
  pixi run sync-native-bootstrap-mirror
}

full_pass() {
  echo "::group::pixi run build-emscripten"
  # --continue-on-failure (baked into the task itself) makes this exit 0
  # even when some recipes fail -- that's fine, the check below re-verifies
  # what's actually missing once the bootstrap sequence is done.
  pixi run build-emscripten
  echo "::endgroup::"
}

# A cold build typically needs a handful of these rounds: each pass
# unblocks more of the native-mirror-gated packages, which then let the
# next pass go further. Once a pass adds nothing new to the mirror,
# there's nothing left to unblock.
prev_count=-1
for _ in $(seq 1 10); do
  sync_mirror
  full_pass
  count=$(find output/emscripten-wasm32 -maxdepth 1 -name '*.tar.bz2' | wc -l)
  if [ "$count" -eq "$prev_count" ]; then
    break
  fi
  prev_count="$count"
done

# ---- Verify: fail loudly (not silently, the way --continue-on-failure
# would) if anything is still missing after the full bootstrap sequence --
# that's a genuinely new problem worth seeing in CI logs, not something to
# paper over with another blind retry. --------------------------------------
missing=()
for recipe_dir in recipes/*/; do
  pkg="$(basename "$recipe_dir")"
  if ! compgen -G "output/*/${pkg}-*.tar.bz2" > /dev/null 2>&1; then
    missing+=("$pkg")
  fi
done

if [ "${#missing[@]}" -gt 0 ]; then
  echo "The following recipes never produced a package after the full bootstrap sequence:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

echo "Full emscripten-wasm32 + rmw_zenoh_pico closure built successfully."
