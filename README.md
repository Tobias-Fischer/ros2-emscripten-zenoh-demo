# ROS 2 in the browser: emscripten-wasm32 + rmw_zenoh_pico

**[Live demo site →](https://www.tobiasfischer.info/ros2-emscripten-zenoh-demo/)**

Two WebAssembly ROS 2 talkers — one in C (`rclc`), one in Python (`rclpy`) —
running in an actual browser, publishing `std_msgs/String` via
[`rmw_zenoh_pico`](https://github.com/esol-community/rmw_zenoh_pico) over a
real WebSocket to a native `zenohd` router, received and correctly decoded
by a completely independent native process. No pthreads, no Asyncify — a
single wasm32 thread that never blocks, cooperatively retrying instead (see
[What it took to get `rclpy` working](#what-it-took-to-get-rclpy-working)
below for why that turned out simpler than the pthreads approach this repo
started with). Built on top of [RoboStack](https://robostack.github.io/)'s
`ros-rolling` distribution.

This repo holds the demo source (`browser_demo/`) and this README, which is
the single place documenting every upstream/downstream change this required
— see [Required changes](#required-changes) below. The actual build
environment (`demo_env/`: a curated extraction of ~230 conda packages, stock
`emscripten-forge` Python and `numpy` — no custom build needed) is not
committed here — it's several GB of build output — but every step to
reproduce it is.

## Required changes

Getting a real ROS 2 node — in C first, then in Python — running inside a
WebAssembly module with no pthreads and no Asyncify, talking to the outside
world over a real network transport, touched five projects. All of it is
either upstream PRs (genuine bugs, not RoboStack-specific) or config changes
in the RoboStack recipe repo that ties everything together. This list is
the map; each PR has the narrow, per-file rationale.

This repo (and the fork it builds against) started down a different path
first — real pthreads, `USE_PTHREADS=1`, `SharedArrayBuffer` — since that's
the obvious fix for `libc++`'s `condition_variable` never waking up without
a real OS thread. It worked for the C/C++ demos, but deadlocked completely
once loaded into JupyterLite's `xeus-python` kernel (itself not
pthreads-enabled, and can't be made so without every `dlopen`'d module
matching). Asyncify was tried next as a pthreads-free way to keep the
`condition_variable` wait cooperative, and also abandoned: it doesn't mix
with runtime `dlopen()` of a `SIDE_MODULE` on this Emscripten/Binaryen
version. What actually shipped needed neither — see
[What it took to get `rclpy` working](#what-it-took-to-get-rclpy-working)
below. The table below (and the PRs it links) describes that final,
no-threads-at-all approach; some PRs' own history still shows the pthreads
detour along the way.

| # | Repo | PR | What & why |
|---|---|---|---|
| 1 | [RoboStack/vinca](https://github.com/RoboStack/vinca) | [#154](https://github.com/RoboStack/vinca/pull/154) | Makes `emscripten-wasm32` a fully non-blocking, single-threaded `ament_cmake` build target for every recipe — no pthreads, no Asyncify. Also: drops an emcc flag emscripten 4.0.9 rejects, fixes v1 selector evaluation in pin overrides, makes `RMW_IMPLEMENTATION` and the static rosidl typesupport backend configurable per downstream pipeline, and — found only once a real `rclpy` `pybind11` module needed linking — sets `CMAKE_SHARED_MODULE_CREATE_*_FLAGS` alongside the `SHARED`-library variant (CMake's `MODULE` target type, what `pybind11_add_module()` uses, reads its own flag variables). |
| 2 | [eclipse-zenoh/zenoh-pico](https://github.com/eclipse-zenoh/zenoh-pico) | [#1314](https://github.com/eclipse-zenoh/zenoh-pico/pull/1314) | Rewrites zenoh-pico's emscripten/wasm32 transport (session open, read, send) to make exactly one non-blocking attempt per call and return immediately, instead of blocking or internally sleeping-and-retrying with `emscripten_sleep()`/`usleep()` — neither of which works without Asyncify or real threads. Retrying now happens entirely at the caller's level. |
| 3 | [esol-community/rmw_zenoh_pico](https://github.com/esol-community/rmw_zenoh_pico) | [#7](https://github.com/esol-community/rmw_zenoh_pico/pull/7) | Emscripten/browser support: `ws/` (not `tcp/`) locators, a `localhost_only` guard fix, a non-blocking/resumable session-open state machine (a synchronous call can't wait for a browser WebSocket handshake to finish), and a cooperative-polling rewrite of `rmw_wait()` that drives the whole no-threads approach. |
| 3b | [esol-community/rmw_zenoh_pico](https://github.com/esol-community/rmw_zenoh_pico) | [#9](https://github.com/esol-community/rmw_zenoh_pico/pull/9) | A separate, genuine upstream bug found later, unrelated to the emscripten port: session teardown stored a function pointer where a heap data pointer was expected, later dereferenced/freed as one — undefined behavior everywhere, a hard wasm trap here. |
| 4 | [micro-ROS/rosidl_typesupport_microxrcedds](https://github.com/micro-ROS/rosidl_typesupport_microxrcedds) | [#83](https://github.com/micro-ROS/rosidl_typesupport_microxrcedds/pull/83) | `ament_cmake_ros` → `ament_cmake_ros_core`, plus real CMake export sets (`rosidl_export_typesupport_targets()` instead of the legacy library-only export) and `$<BUILD_INTERFACE:...>`-wrapped include paths — both needed once other emscripten-wasm32 packages started depending on this one via a proper CMake target. |
| 5 | [ros2/rcutils](https://github.com/ros2/rcutils) | [#591](https://github.com/ros2/rcutils/pull/591) | Two Emscripten guards in `shared_library.c` so `rcl_logging_implementation`'s dlopen-by-name backend selection works: no emscripten case in the platform-library-name formatter, and a `dlinfo(RTLD_DI_LINKMAP)` call Emscripten's JS-backed `dlopen` doesn't support (treated a successful `dlopen()` as a failure). |
| 6 | [RoboStack/ros-rolling](https://github.com/RoboStack/ros-rolling) | [#46](https://github.com/RoboStack/ros-rolling/pull/46) | The actual integration: threads `emscripten-wasm32` + `rmw_zenoh_pico` through the ~230-package `ros-rolling` recipe closure (selectors, per-platform dependency mappings, typesupport backend wiring, new recipes for `zenoh-pico`/`microcdr` since neither has a conda-forge/RoboStack package). Points at (1)–(5) until they merge upstream. |

None of 1–5 (or 3b) are RoboStack-specific hacks kept only as local patches
— each is a real, narrow bug in a project with its own users, submitted
there first. (6) is where they're actually wired together for this distro.

## What it took to get `rclpy` working

A first pass concluded CPython for wasm32 was fundamentally blocked by not
being pthread-enabled, and built a custom CPython + `numpy` with
`--enable-wasm-pthreads` to work around it (CPython upstream has shipped
that flag since 3.11; `emscripten-forge`'s own `python` package just
doesn't turn it on). That conclusion turned out to be looking at the wrong
layer entirely: `rclpy`'s only real dependency on pthreads was `rmw_wait()`
blocking on a real `condition_variable`, one level removed — once
`rmw_zenoh_pico`'s wait path was rewritten to cooperatively poll
`zenoh-pico`'s transport instead (rmw_zenoh_pico #7 above), that dependency
disappeared completely. A **completely stock, unmodified**
`emscripten-forge` CPython and `numpy` work as-is — no custom build, no
patches, nothing pthreads-related anywhere in `demo_env/` anymore.

The one real remaining constraint: `rclpy`'s own extension module and every
ROS `.so` it transitively needs are too much to link directly into one
executable — that many relocations, together with a statically-linked
`libpython3.13.a`, crashed `wasm-ld` outright.
[`browser_demo/rclpy_boot.c`](browser_demo/rclpy_boot.c) instead builds a
`-sMAIN_MODULE=1` executable and lets Python's own `import` machinery
`dlopen()` `rclpy`'s pybind11 module, each message package's
`rosidl_generator_py` typesupport accessor, and `numpy`'s C extensions from
site-packages at runtime — the same way `jupyterlite-xeus`'s `xeus-python`
kernel loads this exact build, no special preloading needed.

Full reproduction steps are in [`docs/demo_env.md`](docs/demo_env.md).

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

`rosidl_typesupport_microxrcedds_cpp`'s codegen used to not handle ROS 2's
newer auto-generated service/action "_Event" messages. That one's fixed
now, not worked around — see `ros-rolling`'s
`patch/ros-rolling-rosidl-typesupport-microxrcedds-cpp.patch` and the
upstream PR linked from it.

## Reproducing it

1. Build `ros-rolling`'s `emscripten-wasm32` + `rmw_zenoh_pico` recipe
   closure — see [RoboStack/ros-rolling#46](https://github.com/RoboStack/ros-rolling/pull/46).
2. Assemble `demo_env/` from that closure's output — see
   [`docs/demo_env.md`](docs/demo_env.md).
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
  closure, assembling `demo_env/`, then linking).
- A JupyterLite deployment built from the one notebook in
  [`jupyterlite-content/`](jupyterlite-content/demo.ipynb) — a genuine
  `xeus-python` kernel running the same compiled `rclpy` + `rmw_zenoh_pico`
  wasm build as the rclpy talker above, over the same WebSocket transport
  (not a lighter-weight REST/HTTP path — it's the full stack, just editable).

A cold run rebuilds everything from source (the full ~230-package `ros-rolling`
closure included) and can take a couple of hours; `actions/cache` keyed on
the recipe/patch inputs makes subsequent runs — e.g. just editing
`site/index.html` — fast, since the expensive package builds hit cache and
skip straight to relinking the talkers.

Since GitHub Pages can't send custom response headers, the site registers a
small service worker (`site/coi-serviceworker.js`) that staples
`Cross-Origin-Opener-Policy` / `Cross-Origin-Embedder-Policy` onto every
same-origin response client-side — the same trick a number of other
wasm-on-Pages projects use, and `site/demo.js` gates the demo buttons on
`window.crossOriginIsolated` before letting them run. This dates from the
pthreads/`SharedArrayBuffer` era; nothing in the current no-threads build
requires cross-origin isolation anymore as far as we've checked, but it
hasn't been re-verified safe to remove, so it's still here out of caution.

🤖 Built with [Claude Code](https://claude.com/claude-code)
