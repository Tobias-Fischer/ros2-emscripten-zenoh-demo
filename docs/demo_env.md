# demo_env

Build environment for the `../browser_demo/` talkers. Not committed here —
it's the output of a real build (dozens of packages, a custom CPython) —
but every step to reproduce it is, and (as of this doc) it's driven
entirely by `pixi`/`rattler-build`: no micromamba, no hand-assembled
directories. See [`../.github/workflows/deploy.yml`](../.github/workflows/deploy.yml)
for the same steps wired into CI — it runs on every push that touches the
relevant paths, using `actions/cache` (keyed on the recipe/patch inputs)
so only a genuinely cold cache pays the multi-hour full-closure cost.

## Layout

`demo_env` is a single, ordinary `pixi`-managed environment for the
`emscripten-wasm32` platform — `include/`, `lib/`, `lib/python3.13/`, the
usual conda env shape. Nothing is manually curated into nonstandard
subdirectories; the two things that make it non-obvious are which
*channels* it resolves from and one local patch applied afterwards.

## 1. Build the ROS 2 packages

From a checkout of [RoboStack/ros-rolling#46](https://github.com/RoboStack/ros-rolling/pull/46):

```bash
bash /path/to/ros2-emscripten-zenoh-demo/.github/scripts/build_ros_rolling_closure.sh
```

This builds the full `emscripten-wasm32` + `rmw_zenoh_pico` recipe closure
(~230 packages) into `output/emscripten-wasm32/`, using `--skip-existing`
so re-runs only rebuild what changed. Run it from the root of the
`ros-rolling` checkout.

A single `pixi run build-emscripten` isn't quite enough on its own for a
genuinely cold checkout: several packages' generated recipes declare a
`build:`-time dependency on a *native* (build-platform) copy of
`rosidl_default_generators`, which no channel actually publishes for any
native platform. `pixi.toml`'s `sync-native-bootstrap-mirror` task
satisfies it by mirroring already-built `emscripten-wasm32` packages into
a fake channel entry named after whatever machine is actually running the
build (`sync_native_bootstrap_mirror.sh` detects it — no real native build
involved) — but it needs re-running after each pass that produces new
packages, so the script loops sync+build until a pass adds nothing new.

`rosidl_typesupport_microxrcedds_cpp`'s codegen used to not generate
typesupport for ROS 2's auto-generated service/action "`_Event`" messages,
which used to require rebuilding a dozen affected packages by hand with
different typesupport overrides after the main build. Fixed at the source
now — see `patch/ros-rolling-rosidl-typesupport-microxrcedds-cpp.patch` in
`ros-rolling` — so a single `pixi run build-emscripten` pass (with both
typesupport overrides set globally, as `pixi.toml` already does) now
builds the entire closure correctly.

## 2. Build a pthreads-enabled CPython + numpy

Stock `emscripten-forge` `python`/`numpy` aren't pthread-enabled — linking
either into this pipeline's `-pthread` `MAIN_MODULE` fails with `wasm-ld:
error: --shared-memory is disallowed ... because it was not compiled with
'atomics' or 'bulk-memory' features`. Both fixes are one build flag each,
already applied on a branch:
[Tobias-Fischer/emscripten-forge-recipes@wasm-pthreads-python-numpy-orphan](https://github.com/Tobias-Fischer/emscripten-forge-recipes/tree/wasm-pthreads-python-numpy-orphan)
(see that branch's README for exactly what's patched and why — briefly:
CPython's own `--enable-wasm-pthreads` configure flag, and setting the
pthread flags directly in numpy's meson cross-file since meson doesn't
reliably propagate `CFLAGS`/`LDFLAGS` env vars to every compile unit).

```bash
git clone --branch wasm-pthreads-python-numpy-orphan --single-branch \
  https://github.com/Tobias-Fischer/emscripten-forge-recipes.git
cd emscripten-forge-recipes
pixi run -e rattler-build-env build-emscripten-wasm32-pkg recipes/recipes_emscripten/python
# numpy needs its own direct rattler-build invocation, not the task above --
# the task's cmd doesn't pass --test skip, and this recipe's own pytester
# test loads the .so in a non-pthread harness and fails there on purpose,
# unrelated to whether the build itself worked.
pixi run -e rattler-build-env rattler-build build \
  --package-format tar-bz2 \
  -c https://repo.prefix.dev/emscripten-forge-4x -c microsoft -c conda-forge \
  -c file://$(pwd)/output \
  --target-platform emscripten-wasm32 --skip-existing none -m variant.yaml \
  --test skip \
  --recipe recipes/recipes_emscripten/numpy
```

This produces its own `output/emscripten-wasm32/` with the patched
`python`/`numpy` builds.

## 3. Assemble demo_env

[`../demo_env_build/build.sh`](../demo_env_build/build.sh) does this in one
step: installs `ros2-rclcpp`, `ros2-rclc`, `ros2-rclpy`,
`ros2-rmw-zenoh-pico`, `ros2-std-msgs`, `ros2-rcutils` (plus `zenoh-pico`
pinned to the version this pipeline builds, and `libffi`/`xz` for
CPython's statically-linked `_ctypes`/`_lzma`) as one `pixi` environment,
with **both** local `output/` directories from steps 1 and 2 listed as
channels ahead of the public ones — `channel-priority = "disabled"`
lets a same-identity local build shadow a same-identity public one, which
is how the patched `python`/`numpy` get picked up automatically alongside
everything else, with no separate directory or manual file-copying:

```bash
ROS_ROLLING_OUTPUT=/path/to/ros-rolling/output \
EMSCRIPTEN_FORGE_OUTPUT=/path/to/emscripten-forge-recipes/output \
./demo_env_build/build.sh
```

It also applies [`../patches/rclpy-node-rmw_zenoh_pico-workarounds.patch`](../patches/README.md)
to the installed `rclpy` afterwards — two real `rmw_zenoh_pico` gaps
(disabling default publisher QoS-event callbacks, and not constructing
`TypeDescriptionService`) that aren't upstreamed. `Node(...,
enable_rosout=False, start_parameter_services=False)` sidesteps two more
unconditional-by-default `rclpy` features (rosout logging, parameter
get/set/list services) that would otherwise pull in more of the same
typesupport gap — pass those flags in your own node rather than patching
further.

Leaves the finished environment symlinked at `../demo_env`.

## 4. Build and run the talkers

```bash
cd ../browser_demo
pixi run build-rclc    # or build-rclpy
```

See [`../browser_demo/pixi.toml`](../browser_demo/pixi.toml) — this just
provides `em++` (pinned to the same `emscripten_emscripten-wasm32==4.0.9`
toolchain build the ROS packages above were cross-compiled with), no SDK
install step needed.

## Running a native zenoh router

The wasm32 build connects to `127.0.0.1:7447` by default (a loopback
address, so a browser will reach it from an `https://` page too).
`zenohd` is a plain [conda-forge](https://conda-forge.org/) package, so
[pixi](https://pixi.sh/)'s `exec` installs and runs it in one line, no
project directory or manual binary download needed:

```bash
pixi exec --with zenohd -c conda-forge \
  zenohd -l ws/127.0.0.1:7447 --no-multicast-scouting
```

(`rmw_zenoh_pico`'s wasm32 build defaults to connecting to `127.0.0.1:7447`
— see `RMW_ZENOH_PICO_CONNECT_PORT` in its `config.h` — so the `ws/` listener
above has to be on that exact port unless you override it. The 6 rclc-based
`browser_demo/` pages *are* runtime-configurable now, via
`rmw_zenoh_pico_set_unicast()` — see each page's "zenoh router" field, or
`?zenoh_host=&zenoh_port=` in the URL; the rclpy talker still only connects
to the compiled-in default.)

## Reproducing the rclpy demo

```bash
cd ../browser_demo
pixi run build-rclpy
# serve out/ with COOP/COEP headers (pixi run -- python3 serve.py, or see
# serve.py directly), open out/index_rclpy.html, point it at the zenohd above.
```
