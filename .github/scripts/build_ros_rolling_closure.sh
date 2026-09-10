#!/usr/bin/env bash
# Build the full ros-rolling emscripten-wasm32 + rmw_zenoh_pico recipe
# closure. Run from the root of a RoboStack/ros-rolling checkout (the
# feature/emscripten-wasm32-zenoh-pico branch, or a fork/branch of it).
#
# A single `pixi run build-emscripten` isn't enough to get a genuinely
# clean checkout all the way to a full closure -- two separate, understood
# bootstrap requirements (both documented at length in this repo's own
# pixi.toml) mean some packages need extra, explicit handling:
#
# 1. Native bootstrap mirror (see pixi.toml's `sync-native-bootstrap-mirror`
#    task comment). Several packages' generated recipes declare a build:
#    (build-platform, i.e. native osx-arm64) dependency on
#    rosidl_default_generators, which no channel actually publishes for
#    this platform. `sync-native-bootstrap-mirror` satisfies it by mirroring
#    already-built emscripten-wasm32 packages into a fake osx-arm64 channel
#    entry -- but only packages built *before* the mirror was last synced
#    are visible, so a cold build needs sync+build repeated until nothing
#    new appears.
# 2. The typesupport "_Event" codegen gap (see pixi.toml's `build-emscripten`
#    task comment, both the --continue-on-failure bullet and the "Known
#    gap" paragraph on its env= line). rosidl_typesupport_microxrcedds_cpp
#    doesn't generate typesupport for ROS 2's auto-generated service/action
#    "_Event" messages. Two DISJOINT groups of affected packages need
#    different scoped rebuilds -- see pixi.toml for exactly why they must
#    stay disjoint (routing a C-only package through the no-override
#    rebuild "succeeds" but silently wires the wrong typesupport backend
#    into its dispatch table):
#      - NO_OVERRIDE_PKGS: rebuilt with no typesupport override at all.
#      - C_ONLY_PKGS: rmw_zenoh_pico needs the C backend from these
#        specifically, so rebuilt directly with only the C override set
#        (never routed through the no-override rebuild first).
#
# Both groups' package lists are a live, evolving fact about the current
# ROS 2 rolling message set (e.g. test_msgs was added to NO_OVERRIDE_PKGS
# only once it became a real, non-optional build/test_depend of rcl) --
# keep them in sync with pixi.toml's own comments, which are the source of
# truth.
set -euo pipefail

NO_OVERRIDE_PKGS=(action-msgs lifecycle-msgs rosgraph-msgs statistics-msgs micro-ros-msgs test-msgs example-interfaces)
C_ONLY_PKGS=(rcl-interfaces type-description-interfaces service-msgs)

EMSCRIPTEN_FORGE_OUTPUT="${EMSCRIPTEN_FORGE_OUTPUT:?set EMSCRIPTEN_FORGE_OUTPUT to the emscripten-forge-recipes output dir}"

sync_mirror() {
  pixi run sync-native-bootstrap-mirror
}

full_pass() {
  echo "::group::pixi run build-emscripten"
  # --continue-on-failure (baked into the task itself) makes this exit 0
  # even when some recipes fail -- that's fine, later steps re-check what's
  # actually missing.
  pixi run build-emscripten
  echo "::endgroup::"
}

build_scoped() {
  local pkg="$1"
  shift
  echo "::group::rebuild ros2-${pkg} ($*)"
  env "$@" pixi run rattler-build build \
    --package-format tar-bz2 \
    --recipe "./recipes/ros2-${pkg}/recipe.yaml" \
    -m ./conda_build_config.yaml \
    -c https://repo.prefix.dev/conda-forge \
    -c https://repo.prefix.dev/emscripten-forge-4x \
    -c "file://${EMSCRIPTEN_FORGE_OUTPUT}" \
    -c microsoft \
    -c robostack-staging \
    --target-platform emscripten-wasm32 \
    --skip-existing \
    --test skip \
    --channel-priority disabled
  echo "::endgroup::"
}

is_built() {
  compgen -G "output/emscripten-wasm32/ros2-${1}-*.tar.bz2" > /dev/null
}

# ---- Phase 1: everything that doesn't need special handling --------------
sync_mirror
full_pass

# ---- Phase 2: the C-only group (rmw_zenoh_pico's actual requirement) -----
# In dependency order: service_msgs has no dependency on the other two,
# rcl_interfaces and type_description_interfaces don't depend on each
# other or on service_msgs, so the only real ordering constraint is that
# each of these gets its own mirror resync before the next depends on it
# transitively (rosgraph_msgs, in phase 3, needs rcl_interfaces).
for pkg in "${C_ONLY_PKGS[@]}"; do
  if ! is_built "$pkg"; then
    build_scoped "$pkg" VINCA_EMSCRIPTEN_RMW_IMPLEMENTATION=rmw_zenoh_pico VINCA_EMSCRIPTEN_STATIC_TYPESUPPORT_C=rosidl_typesupport_microxrcedds_c
    sync_mirror
  fi
done

# ---- Phase 3: the no-override group ---------------------------------------
for pkg in "${NO_OVERRIDE_PKGS[@]}"; do
  if ! is_built "$pkg"; then
    build_scoped "$pkg" VINCA_EMSCRIPTEN_RMW_IMPLEMENTATION=rmw_zenoh_pico
    sync_mirror
  fi
done

# ---- Phase 4: mop up everything now unblocked (std_msgs, and everything
# downstream of it: rmw_zenoh_pico, rcl, rclcpp, rclc, rclpy, ...) ---------
sync_mirror
full_pass

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
