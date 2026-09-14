#!/usr/bin/env python3
"""Copies known "runtime-only" plugin .so's next to the xeus-extension's own
webpack chunks, where its custom locateFile() falls back to for anything it
doesn't otherwise recognize.

Some shared libraries are never referenced by any package's declared
`depends:` -- they're selected purely at runtime, by an env var a C library
reads and dlopen()s by name (e.g. rcl_logging_interface picking a logging
backend based on RCL_LOGGING_IMPLEMENTATION). jupyterlite-xeus's own eager
package-preload walks the *dependency graph* to decide what to proactively
extract from kernel_packages/*.tar.gz before Python even starts -- a leaf
package nothing depends on never gets discovered that way, even though its
tarball is present in kernel_packages/ (confirmed: ros2-rcl-logging-noop is
correctly listed in empack_env_meta.json and its tarball fetches fine).

When Python's own C-level code then dlopen()s it directly (not via eager
preload), the xeus-extension's own custom Module.locateFile() override
(baked into its built webpack worker chunk, e.g.
extensions/@jupyterlite/xeus-extension/static/654.<hash>.js) intercepts the
request -- and for anything that isn't a known kernel-package name,
"libxeus.so", ".wasm", or ".data", it falls through to returning the bare
filename unresolved, which the worker's own script-relative URL resolution
then serves from *its own* directory,
extensions/@jupyterlite/xeus-extension/static/ -- not
xeus/demo_env/bin/ where xpython.js/xpython.wasm actually live (confirmed
live via the real failing request URL: ".../jupyterlite/extensions/
@jupyterlite/xeus-extension/static/librcl_logging_noop.so", a 404 --
an earlier version of this fix wrongly assumed xeus/demo_env/bin/ instead,
reasoning from xpython.js's own *default* locateFile(), before realizing
the extension overrides it).

Fixes it the same way build_rclpy.sh flattens every .so next to
rclpy_boot.js: copy the file directly to where the *actual* fallback
resolves it. Extend PLUGIN_SO_NAMES below if another runtime-only-selected
plugin turns up with the same symptom.

Usage: flatten_runtime_only_plugins.py <demo_env dir> <xeus-extension static dir>
"""
import shutil
import sys
from pathlib import Path

PLUGIN_SO_NAMES = [
    "librcl_logging_noop.so",
]


def main():
    demo_env = Path(sys.argv[1])
    dest_dir = Path(sys.argv[2])

    for name in PLUGIN_SO_NAMES:
        src = demo_env / "lib" / name
        if not src.is_file():
            raise FileNotFoundError(f"expected {src} to exist in demo_env -- check PLUGIN_SO_NAMES")
        shutil.copy(src, dest_dir / name)
        print(f"flattened {name} -> {dest_dir / name}")


if __name__ == "__main__":
    main()
