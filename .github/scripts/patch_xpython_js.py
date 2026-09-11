#!/usr/bin/env python3
"""Patches a Proxy get-trap bug in the JupyterLite kernel's pyjs-based
Python<->JS interop layer (xpython.js).

emscripten-forge/pyjs's make_proxy.js wraps every Python object exposed to
JS in a Proxy whose `get` trap forwards ANY missing property straight to
Python's getattr() -- including Symbol-keyed ones (Symbol.iterator,
Symbol.toStringTag, Node's util.inspect.custom, ...), which browser/Node
internals probe on ~any object during things as routine as
console.log(obj) or checking "is this thenable". Passing a Symbol into
the compiled _raw_getattr(), which expects a std::string, throws:
  BindingError: Cannot pass non-string to std::string
See https://github.com/emscripten-forge/pyjs -- pre_js/make_proxy.js.

xpython.js isn't built by this repo (jupyterlite-xeus downloads it as a
prebuilt kernel package), so this patches the deployed glue script's text
directly with a targeted, minification-safe string replacement, the same
way inject_coi_serviceworker.py post-processes the JupyterLite build
rather than rebuilding it from source.

Usage: patch_xpython_js.py <path to xpython.js>
"""
import sys
from pathlib import Path

OLD = (
    'get(target,property,receiver){var ret=target[property];'
    'if(ret!==undefined){return ret}return target._getattr(property)}'
)
NEW = (
    'get(target,property,receiver){'
    'if(typeof property!=="string"){return Reflect.get(target,property,receiver)}'
    'var ret=target[property];'
    'if(ret!==undefined){return ret}return target._getattr(property)}'
)


def main():
    path = Path(sys.argv[1])
    text = path.read_text()
    count = text.count(OLD)
    if count == 0:
        raise RuntimeError(
            f"make_proxy Proxy get-trap pattern not found in {path} -- "
            "xpython.js's bundling must have changed, update OLD/NEW above"
        )
    if count > 1:
        raise RuntimeError(f"expected exactly one match in {path}, found {count}")
    path.write_text(text.replace(OLD, NEW))
    print(f"Patched make_proxy Proxy get-trap Symbol-key crash in {path}")


if __name__ == "__main__":
    main()
