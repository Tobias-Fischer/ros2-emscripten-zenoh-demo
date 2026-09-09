# demo_env

Build environment for the `../browser_demo/` talkers — not committed to
this repo (several GB of build output: extracted conda packages, a custom
CPython, `numpy`). This document is how to reproduce it from a checkout of
[RoboStack/ros-rolling#46](https://github.com/RoboStack/ros-rolling/pull/46)
("this repo" below refers to that `ros-rolling` checkout, not this demo
repo): a flattened extraction of packages it builds (plus a few hand-built
ones), so `../browser_demo/build_rclc.sh` / `build_rclpy.sh` have a stable
set of `.so` files and headers to link against.

## Layout

- `lib/`, `include/`, `microcdr-2.0.2/` — extracted `emscripten-wasm32`
  conda packages from this repo's own `output/` (rcl, rmw_zenoh_pico,
  zenoh-pico, the message packages, etc).
- `python3.13-pthread/` — a custom CPython 3.13.1 build, **not** the one
  `ros2-rclpy`'s own recipe pulls from `emscripten-forge-4x`. See below.
- `python3.13-pthread/site-packages-rclpy/` — `rclpy` + its message-package
  Python bindings + `numpy`, assembled from this repo's built packages plus
  two local patches to `rclpy/node.py`. See below.

## Why a custom CPython

`emscripten-forge`'s own `python` package isn't built with real pthreads
(same as most of its packages, before this repo's vinca fork patched
`build_ament_cmake.sh.in` to turn `USE_PTHREADS=1` on for every ROS package
here) — linking it into this pipeline's `-pthread` `MAIN_MODULE` fails with
`wasm-ld: error: --shared-memory is disallowed ... because it was not
compiled with 'atomics' or 'bulk-memory' features`.

The fix is one configure flag. CPython upstream has shipped
`--enable-wasm-pthreads` since 3.11 (adds exactly `-pthread -sUSE_PTHREADS
-sPROXY_TO_PTHREAD` — the same flags this whole pipeline already uses).
Reproduce it from a clone of `emscripten-forge/recipes`:

```bash
git clone https://github.com/emscripten-forge/recipes emscripten-forge-recipes
cd emscripten-forge-recipes
# check out the recipe.yaml/build.sh/Makefile matching the *exact* pinned
# version+build (python-3.13.1-h_..._11_cp313 as of this writing) -- find it
# by bisecting git log on recipes/recipes_emscripten/python, NOT the tip of
# main (which has since moved to a newer python).
```

Then in `recipes/recipes_emscripten/python/Makefile`, add
`--enable-wasm-pthreads` to the `./configure` invocation, and in
`Setup.local`, move `_ssl` from the `*static*` section to `*disabled*`
(OpenSSL is *also* non-pthread on `emscripten-forge`, and this demo doesn't
need TLS to talk to a local `zenohd`; dropping it avoids needing to also
port OpenSSL). Bump `build_number` in `recipe.yaml` so the artifact gets a
distinct identity, then:

```bash
pixi run -e rattler-build-env build-emscripten-wasm32-pkg recipes/recipes_emscripten/python
```

## Why a patched numpy

`numpy` from `emscripten-forge` is non-pthread for the same reason. Fix is
the same idea, but `numpy`'s meson build doesn't reliably pick up
`CFLAGS`/`LDFLAGS` env vars for every compile unit — set flags in the
meson cross file instead, which meson always honors:

```toml
# recipes/recipes_emscripten/numpy/emscripten.meson.cross
[built-in options]
c_args = ['-pthread']
cpp_args = ['-pthread']
c_link_args = ['-pthread', '-sUSE_PTHREADS=1']
cpp_link_args = ['-pthread', '-sUSE_PTHREADS=1']
```

Build the same way (bump `build_number`, run
`build-emscripten-wasm32-pkg recipes/recipes_emscripten/numpy`, pass
`--test skip` if invoking `rattler-build` directly — the recipe's own
pytester test loads the `.so` in a non-pthread harness and fails there on
purpose, unrelated to whether the build itself worked).

Combining several of `numpy`'s independently-built extension modules
(`_core`, `linalg`, `random`, `fft`) into one `MAIN_MODULE` link produces
duplicate-symbol errors for `npymath`'s small helper functions (each module
statically links its own copy) — harmless; link with
`-Wl,--allow-multiple-definition`.

## Why `rclpy/node.py` is patched

CPython here is *not* built with `--enable-wasm-dynamic-linking` (its own
docs flag that combination with pthreads as known-crashy), so nothing can
rely on Python's normal `import` mechanism dynamically `dlopen`-ing a
compiled `.so` extension module the way it would on a normal platform.
Every extension module anything might import — `rclpy`'s own
`_rclpy_pybind11`, each message package's `rosidl_generator_py` typesupport
accessor, all of `numpy`'s eagerly-imported extensions — is registered
ahead of time via `PyImport_AppendInittab()` in `browser_demo/rclpy_boot.c`
instead.

Two `rclpy` behaviors don't work with `rmw_zenoh_pico` as-is and are
patched out locally in `site-packages-rclpy/rclpy/node.py` (not upstreamed —
these look like real `rmw_zenoh_pico` gaps, not just missing typesupport):

- The internal `/parameter_events` publisher (created unconditionally by
  every `Node`) registers a default QoS-incompatible-event callback.
  `rmw_zenoh_pico` doesn't support publisher QoS event handlers and fails
  with a plain `RCLError` instead of the `UnsupportedEventTypeError`
  `rclpy`'s own `create_event_handlers()` already catches and ignores —
  so the default callback is turned off explicitly
  (`event_callbacks=PublisherEventCallbacks(use_default_callbacks=False)`).
  Do the same for any publisher your own node creates.
- `TypeDescriptionService` (also created unconditionally) creates a real
  RCL service; on `rmw_zenoh_pico` this doesn't error, it hangs. Patched to
  `self._type_description_service = None` instead of constructing it.

`Node(..., enable_rosout=False, start_parameter_services=False)` sidesteps
two more unconditional-by-default features (rosout logging publisher,
parameter get/set/list services) that pull in message packages
(`rcl_interfaces`, `service_msgs`) with their own typesupport wrinkles (see
below) — pass those flags rather than patching further.

## Why `rcl_interfaces` / `type_description_interfaces` / `service_msgs` are rebuilt separately

`rosidl_typesupport_microxrcedds_cpp`'s codegen has a real gap: it doesn't
generate typesupport handles for ROS 2's newer auto-generated service
"_Event" messages. This repo already works around it for
`action_msgs`/`lifecycle_msgs`/`rosgraph_msgs`/`statistics_msgs`/
`micro_ros_msgs` by leaving them on the default (introspection) typesupport
entirely (see `pixi.toml`'s `build-emscripten` task comment).

But `rmw_zenoh_pico` needs the **C** typesupport backend specifically for
messages it actually publishes/subscribes/services, and the gap above is
specific to the **C++** variant — the C backend for these packages builds
fine. So `rcl_interfaces`, `type_description_interfaces`, and
`service_msgs` are rebuilt once more with only
`VINCA_EMSCRIPTEN_STATIC_TYPESUPPORT_C=rosidl_typesupport_microxrcedds_c`
set (not `_CPP`), e.g.:

```bash
VINCA_EMSCRIPTEN_RMW_IMPLEMENTATION=rmw_zenoh_pico \
VINCA_EMSCRIPTEN_STATIC_TYPESUPPORT_C=rosidl_typesupport_microxrcedds_c \
rattler-build build --recipe ./recipes/ros2-rcl-interfaces/recipe.yaml \
  -m ./conda_build_config.yaml \
  -c https://repo.prefix.dev/conda-forge -c https://repo.prefix.dev/emscripten-forge-4x \
  -c file:///tmp/emscripten_forge_recipes/output -c microsoft -c robostack-staging \
  --target-platform emscripten-wasm32 --skip-existing none --test skip --channel-priority disabled
```

(repeat for `ros2-type-description-interfaces` and `ros2-service-msgs`).
This isn't wired into `pixi run build-emscripten` as a single command yet —
that would need vinca to support a per-package typesupport override rather
than one global env var for the whole invocation.

## Running a native zenoh router

Download a `zenohd` standalone release (matches the `zenoh-pico`/
`rmw_zenoh_pico` version this pipeline pins) and run it with a `ws/`
listener — `rmw_zenoh_pico` on wasm32 only speaks WebSocket, not raw TCP:

```bash
gh release download 1.10.1 --repo eclipse-zenoh/zenoh \
  --pattern "*aarch64-apple-darwin-standalone.zip"  # pick your platform's asset
unzip *.zip -d zenoh_router && cd zenoh_router
./zenohd -l tcp/127.0.0.1:7448 -l ws/127.0.0.1:7447 --no-multicast-scouting
```

(`rmw_zenoh_pico`'s wasm32 build defaults to connecting to `127.0.0.1:7447`
— see `RMW_ZENOH_PICO_CONNECT_PORT` in its `config.h` — so the `ws/` listener
above has to be on that exact port unless you rebuild with a different one.)

## Reproducing the rclpy demo

```bash
cd ../browser_demo
./build_rclpy.sh
# serve out/ with COOP/COEP headers (see serve.py), open index_rclpy.html,
# point it at the zenohd above.
```
