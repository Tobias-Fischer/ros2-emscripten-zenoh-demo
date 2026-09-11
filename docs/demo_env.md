# demo_env

Build environment for the `../browser_demo/` talkers. Not committed here —
it's the output of a real build (dozens of packages) — but every step to
reproduce it is, and (as of this doc) it's driven
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

`pixi run build-emscripten` is a deterministic two-pass sequence (build,
sync a native-mirror workaround, build again — see that task's own comment
in `pixi.toml`): several packages' generated recipes declare a `build:`-time
dependency on a *native* (build-platform) copy of `rosidl_default_generators`,
which no channel actually publishes for any native platform, so pass 1
builds everything that doesn't need it (including the generator itself),
`sync-native-bootstrap-mirror` mirrors that into a fake same-platform
channel entry (`sync_native_bootstrap_mirror.sh` detects the platform — no
real native build involved), and pass 2 builds everything that was waiting
on it. Nothing in this recipe set nests that workaround more than one
level deep, so two passes is provably enough — not something to discover
by looping externally until a pass adds nothing new.

Building `rmw_zenoh_pico` and its typesupport backend for `emscripten-wasm32`
also needs the `cross-python_emscripten-wasm32` toolchain package, which
`emscripten-forge-4x` doesn't publish yet — built locally instead from a
checkout of [emscripten-forge/recipes](https://github.com/emscripten-forge/recipes)
(or a fork of it):

```bash
git clone https://github.com/Tobias-Fischer/emscripten-forge-recipes.git
cd emscripten-forge-recipes
pixi run -e rattler-build-env build-cross-python-pkg
mkdir -p /tmp/emscripten_forge_recipes
ln -sfn "$(pwd)/output" /tmp/emscripten_forge_recipes/output
```

(`ros-rolling`'s own `pixi.toml` hardcodes that `/tmp` path as one of
`build-emscripten`'s channels — see its own comment for why.)

## 2. Assemble demo_env

[`../demo_env_build/build.sh`](../demo_env_build/build.sh) does this in one
step: installs `ros2-rclcpp`, `ros2-rclc`, `ros2-rclpy`,
`ros2-rmw-zenoh-pico`, `ros2-std-msgs`, `ros2-rcutils`, `xeus-python` (plus
`zenoh-pico` pinned to the version this pipeline builds, and `libffi`/`xz`
for CPython's statically-linked `_ctypes`/`_lzma`) as one `pixi`
environment, with the local `output/` directory from step 1 listed as a
channel ahead of the public ones — `channel-priority = "disabled"` lets a
same-identity local build shadow a same-identity public one. `python`/
`numpy` themselves are stock `emscripten-forge-4x` builds, no local build
needed: `rcl`/`rclpy` don't require WebAssembly shared memory at all
(`rmw_wait` polls zenoh-pico's transport instead of blocking on a real
`condition_variable` — see `ros-rolling`'s `ros-rolling-rmw-zenoh-pico.patch`),
so there's no pthreads-ABI reason for a custom Python build anymore:

```bash
ROS_ROLLING_OUTPUT=/path/to/ros-rolling/output ./demo_env_build/build.sh
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

## 3. Build and run the talkers

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
