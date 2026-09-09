# patches/

Local patches applied when assembling `demo_env/` (see
[`../demo_env_build/build.sh`](../demo_env_build/build.sh)) that aren't
upstreamed — these are workarounds for real `rmw_zenoh_pico` gaps, not
RoboStack-specific hacks, and are documented as such in the main
[README](../README.md#known-limitations).

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

The custom pthreads CPython + numpy patches live in a separate repo, since
they patch a different project's recipes: see
[Tobias-Fischer/emscripten-forge-recipes](https://github.com/Tobias-Fischer/emscripten-forge-recipes/tree/wasm-pthreads-python-numpy-orphan)
(branch `wasm-pthreads-python-numpy-orphan`).
