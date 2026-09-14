#!/usr/bin/env python3
"""Copies known "runtime-only" plugin .so's next to xpython.js/xpython.wasm.

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
preload), xpython.js's synchronous-XHR fallback (readBinary(), used for a
lazy dlopen that isn't already resident) constructs the request URL as
`scriptDirectory + path` -- i.e. it expects the plain file to sit flat next
to xpython.js/xpython.wasm, the same way build_rclpy.sh already flattens
every .so next to rclpy_boot.js for exactly this reason. Nothing in the
jupyterlite-xeus build pipeline does that flattening for a leaf-only
package, so that XHR 404s (confirmed live, Network tab: "librcl_logging_noop.so
404, xhr, initiator xpython.js").

Fixes it the same way build_rclpy.sh does: copy the file directly into
place. Extend PLUGIN_SO_NAMES below if another runtime-only-selected
plugin turns up with the same symptom.

Usage: flatten_runtime_only_plugins.py <demo_env dir> <xeus/demo_env/bin dir>
"""
import shutil
import sys
from pathlib import Path

PLUGIN_SO_NAMES = [
    "librcl_logging_noop.so",
]


def main():
    demo_env = Path(sys.argv[1])
    bin_dir = Path(sys.argv[2])

    for name in PLUGIN_SO_NAMES:
        src = demo_env / "lib" / name
        if not src.is_file():
            raise FileNotFoundError(f"expected {src} to exist in demo_env -- check PLUGIN_SO_NAMES")
        shutil.copy(src, bin_dir / name)
        print(f"flattened {name} -> {bin_dir / name}")


if __name__ == "__main__":
    main()
