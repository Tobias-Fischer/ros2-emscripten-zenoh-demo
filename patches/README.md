# patches/

Local patches applied when assembling `demo_env/` (see
[`../demo_env_build/build.sh`](../demo_env_build/build.sh)) that aren't
upstreamed yet — workarounds for real gaps in the projects this demo
depends on, not RoboStack-specific hacks. The `rmw_zenoh_pico` ones are
also documented in the main [README](../README.md#known-limitations).

- **`rclpy-node-rmw_zenoh_pico-workarounds.patch`** — two `rclpy/node.py`
  changes:
  - Disables the default publisher event callbacks on the internal
    `/parameter_events` publisher every `Node` creates unconditionally.
    `rmw_zenoh_pico` doesn't support publisher QoS event handlers and fails
    with a plain `RCLError` instead of the `UnsupportedEventTypeError`
    `rclpy` already catches and ignores elsewhere.
  - Skips constructing `TypeDescriptionService` (also unconditional per
    `Node`) — on `rmw_zenoh_pico` this doesn't error, it hangs.

  Applied with `patch -p1` against the `rclpy` package's own
  `site-packages` directory once `demo_env` is assembled (not a source
  patch on any recipe — `rclpy`'s recipe doesn't need to change, just the
  installed copy this demo runs against).

- **`pyjs-pyodide-polyfill-to_js-compat.patch`** — the JupyterLite kernel
  (`xeus-python`, via `emscripten-forge/pyjs`'s `pyodide.ffi` polyfill) has
  its own `to_js()`, which doesn't accept `dict_converter` (or any other)
  keyword arguments real Pyodide's does. `xeus_python_shell` imports
  `pyodide_http` unconditionally on kernel init to patch `urllib`, and
  `pyodide_http`'s streaming support calls `to_js(d,
  dict_converter=js.Object.fromEntries)` — so every kernel start hit
  `TypeError: to_js() got an unexpected keyword argument 'dict_converter'`
  before this patch existed. Known, still-open upstream bug:
  [emscripten-forge/pyjs#73](https://github.com/emscripten-forge/pyjs/issues/73)
  (filed 2024-08-28 against the identical `urllib3` call — this isn't
  `pyodide_http`- or ROS-specific). Wraps `pyodide_polyfill.py`'s own
  `to_js` to honor `dict_converter` by applying it to the `to_js()` result,
  matching what real Pyodide does.

  Applied with `patch -p1` against the `pyjs` package's own `site-packages`
  directory, same as the `rclpy` patch above.

The custom pthreads CPython + numpy patches live in a separate repo, since
they patch a different project's recipes: see
[Tobias-Fischer/emscripten-forge-recipes](https://github.com/Tobias-Fischer/emscripten-forge-recipes/tree/wasm-pthreads-python-numpy-orphan)
(branch `wasm-pthreads-python-numpy-orphan`).
