# ROS 2 in the browser: emscripten-wasm32 + rmw_zenoh_pico

**[Live demo site →](https://www.tobiasfischer.info/ros2-emscripten-zenoh-demo/)**

Two WebAssembly ROS 2 talkers — one in C (`rclc`), one in Python (`rclpy`) —
running with real pthreads in an actual browser, publishing
`std_msgs/String` via [`rmw_zenoh_pico`](https://github.com/esol-community/rmw_zenoh_pico)
over a real WebSocket to a native `zenohd` router, received and correctly
decoded by a completely independent native process. Built on top of
[RoboStack](https://robostack.github.io/)'s `ros-rolling` distribution.

This repo holds the demo source (`browser_demo/`) and this README, which is
the single place documenting every upstream/downstream change this required
— see [Required changes](#required-changes) below. The actual build
environment (`demo_env/`: a curated extraction of ~230 conda packages, a
custom pthreads-enabled CPython, patched `numpy`) is not committed here —
it's several GB of build output — but every step to reproduce it is.

## Required changes

Getting a real ROS 2 node — in C first, then in Python — running inside a
`-pthread` WebAssembly module and talking to the outside world over a real
network transport touched five projects. All of it is either upstream PRs
(genuine bugs, not RoboStack-specific) or config changes in the RoboStack
recipe repo that ties everything together. This list is the map; each PR
has the narrow, per-file rationale.

| # | Repo | PR | What & why |
|---|---|---|---|
| 1 | [RoboStack/vinca](https://github.com/RoboStack/vinca) | [#154](https://github.com/RoboStack/vinca/pull/154) | Real pthreads (`USE_PTHREADS=1`, compile *and* link) for every `emscripten-wasm32` `ament_cmake` build — without it, `libc++`'s `condition_variable` timed-wait never wakes up, so any executor-based program hangs after its first callback. Also: drops an emcc flag emscripten 4.0.9 rejects, fixes v1 selector evaluation in pin overrides, makes `RMW_IMPLEMENTATION` and the static rosidl typesupport backend configurable per downstream pipeline, and — found only once a real `rclpy` `pybind11` module needed linking — sets `CMAKE_SHARED_MODULE_CREATE_*_FLAGS` alongside the `SHARED`-library variant (CMake's `MODULE` target type, what `pybind11_add_module()` uses, reads its own flag variables). |
| 2 | [eclipse-zenoh/zenoh-pico](https://github.com/eclipse-zenoh/zenoh-pico) | [#1314](https://github.com/eclipse-zenoh/zenoh-pico/pull/1314) | `emscripten_sleep()` requires Asyncify, incompatible with a real-pthreads build; falls back to a plain blocking `usleep()` when pthreads are available. |
| 3 | [esol-community/rmw_zenoh_pico](https://github.com/esol-community/rmw_zenoh_pico) | [#7](https://github.com/esol-community/rmw_zenoh_pico/pull/7) | Emscripten/browser support: `ws/` (not `tcp/`) locators, and a `localhost_only` guard fix. |
| 4 | [micro-ROS/rosidl_typesupport_microxrcedds](https://github.com/micro-ROS/rosidl_typesupport_microxrcedds) | [#83](https://github.com/micro-ROS/rosidl_typesupport_microxrcedds/pull/83) | `ament_cmake_ros` → `ament_cmake_ros_core`, plus real CMake export sets (`rosidl_export_typesupport_targets()` instead of the legacy library-only export) and `$<BUILD_INTERFACE:...>`-wrapped include paths — both needed once other emscripten-wasm32 packages started depending on this one via a proper CMake target. |
| 5 | [ros2/rcutils](https://github.com/ros2/rcutils) | [#591](https://github.com/ros2/rcutils/pull/591) | Two Emscripten guards in `shared_library.c` so `rcl_logging_implementation`'s dlopen-by-name backend selection works: no emscripten case in the platform-library-name formatter, and a `dlinfo(RTLD_DI_LINKMAP)` call Emscripten's JS-backed `dlopen` doesn't support (treated a successful `dlopen()` as a failure). |
| 6 | [RoboStack/ros-rolling](https://github.com/RoboStack/ros-rolling) | [#46](https://github.com/RoboStack/ros-rolling/pull/46) | The actual integration: threads `emscripten-wasm32` + `rmw_zenoh_pico` through the ~230-package `ros-rolling` recipe closure (selectors, per-platform dependency mappings, typesupport backend wiring, new recipes for `zenoh-pico`/`microcdr` since neither has a conda-forge/RoboStack package). Points at (1)–(5) until they merge upstream. |

None of 1–5 are RoboStack-specific hacks kept only as local patches — each
is a real, narrow bug in a project with its own users, submitted there
first. (6) is where they're actually wired together for this distro.

## What it took to get `rclpy` working

A first pass concluded CPython for wasm32 was fundamentally blocked by not
being pthread-enabled. That conclusion was wrong — it's one configure flag.
CPython upstream has shipped `--enable-wasm-pthreads` since 3.11 (adds
exactly `-pthread -sUSE_PTHREADS -sPROXY_TO_PTHREAD`, the same flags this
whole pipeline already uses for everything else); `emscripten-forge`'s own
`python` package just doesn't turn it on. Same story for `numpy` (pthreads
via the meson cross-file, since meson doesn't reliably propagate
`CFLAGS`/`LDFLAGS` env vars to every compile unit).

The one real constraint: this CPython is *not* built with
`--enable-wasm-dynamic-linking` (its own docs flag that combination with
pthreads as known-crashy), so nothing can rely on Python's normal `import`
dynamically `dlopen`-ing a compiled `.so` extension. Every extension module
anything might import — `rclpy`'s own `_rclpy_pybind11`, each message
package's `rosidl_generator_py` typesupport accessor, `numpy`'s ~14
eagerly-imported extensions — is registered ahead of time via
`PyImport_AppendInittab()` in [`browser_demo/rclpy_boot.c`](browser_demo/rclpy_boot.c)
instead of left for Python's import system to find dynamically.

Full reproduction steps (the custom CPython/`numpy` builds, the exact
`rattler-build` invocations, why three message packages need a second
build pass) are in [`docs/demo_env.md`](docs/demo_env.md).

## Known limitations

Two real `rmw_zenoh_pico` gaps, found but not fixed here (not root-caused
on the `rmw_zenoh_pico` side yet — worth a closer look if this gets taken
further):

- No support for publisher/subscriber QoS event handlers
  (`RCL_PUBLISHER_OFFERED_INCOMPATIBLE_QOS` etc.) — fails with a plain
  `RCLError` instead of the `UnsupportedEventTypeError` `rclpy` already
  handles gracefully. Worked around by disabling default event callbacks
  on every publisher this demo creates.
- `rclpy`'s `TypeDescriptionService` (an unconditional per-`Node` RCL
  service) doesn't error, it hangs. Worked around by not constructing it
  (a two-line local patch to `rclpy/node.py`, documented in
  [`docs/demo_env.md`](docs/demo_env.md)).

Also: `rosidl_typesupport_microxrcedds_cpp`'s codegen doesn't handle ROS
2's newer service "_Event" messages — specific to the **C++** typesupport
variant (the **C** variant those same packages need for `rmw_zenoh_pico`
builds fine). Not upstreamed — a real codegen fix, out of scope here.

## Reproducing it

1. Build `ros-rolling`'s `emscripten-wasm32` + `rmw_zenoh_pico` recipe
   closure — see [RoboStack/ros-rolling#46](https://github.com/RoboStack/ros-rolling/pull/46).
2. Assemble `demo_env/` from that closure's output, plus the extra pthreads
   `python`/`numpy` builds — see [`docs/demo_env.md`](docs/demo_env.md).
3. `./browser_demo/build_rclc.sh` or `./browser_demo/build_rclpy.sh`.
4. Run a native `zenohd` router (`ws/` listener), serve `browser_demo/out/`
   with COOP/COEP headers (`serve.py`), open `index_rclc.html` /
   `index_rclpy.html`.
5. Verify independently: `curl` the router's REST API for the published
   key and decode the base64 payload — confirms a process that never
   touched a browser received the message.

## The site (`site/`)

[GitHub Pages](https://www.tobiasfischer.info/ros2-emscripten-zenoh-demo/)
site (this account has an account-level custom domain configured, so
`tobias-fischer.github.io/ros2-emscripten-zenoh-demo/` redirects there
rather than serving directly). `site/` holds only hand-written source —
`index.html`, `style.css`, `demo.js`, `coi-serviceworker.js` — nothing
generated is committed anywhere in this repo. Everything else is built
fresh by [`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) and
deployed straight to Pages from that build (via `actions/deploy-pages` —
no `gh-pages`/`_site` branch; GitHub manages the deployment from the
uploaded build artifact directly, visible under Settings > Environments >
github-pages and the repo's Deployments tab):

- The two talkers from `browser_demo/`, rebuilt via `demo_env_build/` +
  `browser_demo/pixi.toml` — see [`docs/demo_env.md`](docs/demo_env.md)
  for the full pipeline (the `ros-rolling` emscripten-wasm32 recipe
  closure, the pthreads CPython/numpy build, assembling `demo_env/`, then
  linking).
- A small JupyterLite deployment built from the one notebook in
  [`jupyterlite-content/`](jupyterlite-content/demo.ipynb) — plain HTTP
  against `zenohd`'s REST plugin, no compiled wasm required, much lighter
  than the two talkers above.

A cold run rebuilds everything from source (the full ~230-package `ros-rolling`
closure included) and can take a couple of hours; `actions/cache` keyed on
the recipe/patch inputs makes subsequent runs — e.g. just editing
`site/index.html` — fast, since the expensive package builds hit cache and
skip straight to relinking the talkers.

Since GitHub Pages can't send custom response headers and the two live
demos need `SharedArrayBuffer` (real wasm32 threads) which requires
cross-origin isolation, the site registers a small service worker
(`site/coi-serviceworker.js`) that staples `Cross-Origin-Opener-Policy` /
`Cross-Origin-Embedder-Policy` onto every same-origin response client-side —
the same trick a number of other wasm-on-Pages projects use.

🤖 Built with [Claude Code](https://claude.com/claude-code)
