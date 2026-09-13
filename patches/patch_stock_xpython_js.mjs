#!/usr/bin/env node
// Patches a STOCK (unmodified, upstream emscripten-forge-4x) xpython.js so it
// can dlopen this project's own ROS2/rclpy .so packages, WITHOUT ever
// recompiling xeus-python locally.
//
// Why this exists (see ~/robot/ros-rolling-emscripten-zenoh/AGENTS.md's
// "BREAKTHROUGH 2026-09-13 (autonomous overnight session)" for the full
// investigation): every locally-recompiled xeus-python build this project
// produced (7 different configurations tried) hit an unreproducible
// Emscripten "null function or function signature mismatch"
// indirect-call-table-corruption bug during kernel bootstrap -- ruled out
// as caused by any of this project's own patches, Asyncify flags, or host
// dependency choices. Meanwhile the untouched, remotely-built STOCK
// xeus-python-0.19.0 package (from emscripten-forge-4x) never exhibits this
// bug at all. This script makes that stock binary usable for this project's
// real workload (rclpy + zenoh-pico + ROS2 message packages) by fixing up
// exactly the things a stock, non-Asyncify, pthread-free, generic-Python
// build doesn't anticipate needing:
//
//   1. rclpy's own compiled extension (_rclpy_pybind11...so) is an Emscripten
//      SIDE_MODULE built with -sASYNCIFY (needed for rmw_wait's
//      cooperative-polling fix elsewhere in this project). Asyncify's
//      dynamic-linking support requires the *host* module to provide a
//      shared `__asyncify_state`/`__asyncify_data` global -- normally only
//      present when the host's own MAIN_MODULE is *also* Asyncify-enabled.
//      Since the stock binary is not, and enabling Asyncify on it is
//      exactly what triggered the corruption bug, we instead hand-supply
//      two dummy `WebAssembly.Global` objects that satisfy the import
//      without ever exercising real Asyncify unwind/rewind machinery.
//      Safe as long as the code that actually needs cooperative yielding
//      (rmw_wait's blocking read path) is never reached -- true for
//      import/init/pub-sub without a long-running blocking spin().
//
//   2. The stock build's JS runtime omits a handful of exports that a
//      generic-Python build never needs but a heavy, many-.so ROS2 tree
//      does: `Module._dlerror`, and `Module._emscripten_dlopen_promise`
//      (present in the compiled .wasm itself, just not wired to `Module`).
//      We hook up `_dlerror` (safe, doesn't touch Asyncify) but deliberately
//      do NOT hook up `_emscripten_dlopen_promise` -- that function
//      internally relies on genuine Asyncify unwind/rewind to suspend a C
//      call stack across an async fetch, and calling it for real on a
//      non-Asyncify host causes a silent hard crash (not a catchable JS
//      exception). Instead we replace the whole eager/bootstrap-time
//      shared-library preload path with the safe, JS-level
//      `Module.loadDynamicLibrary()` (already used correctly by this
//      build for on-demand/lazy dlopen), with:
//        - "local" libraries (Python C-extensions) skipped entirely during
//          eager preload -- they need a `localScope` to receive symbols
//          into, which the generic per-package preload loop has no way to
//          supply; Python's own lazy import mechanism already handles these
//          correctly.
//        - "global" libraries retried across multiple passes, since ROS2's
//          typesupport/introspection libraries have circular/cross-package
//          template-instantiation dependencies and are discovered in
//          arbitrary (file-tree) order, not true dependency order.
//
//   3. A generic `invoke_*` JS trampoline for any signature the stock
//      build's runtime doesn't already define. The stock binary was
//      compiled without exception-safe indirect calls (no `-fexceptions`import
//      /`DISABLE_EXCEPTION_CATCHING=0`), so it defines zero `invoke_*`
//      helpers -- but several of this project's own locally-compiled .so
//      files (built *with* that setting) call them directly as external
//      imports regardless of what the host needs for itself. The
//      implementation here is intentionally minimal (no SjLj-style
//      `setThrew` bookkeeping, since that machinery doesn't exist in this
//      build either) -- it just forwards the call and lets a real JS/wasm
//      exception propagate naturally, which is correct for the common
//      case (successful calls) and for genuine unrecoverable errors, but
//      may not perfectly replicate every C++ catch/recover code path that
//      assumed the SjLj contract. Revisit if a specific catch block turns
//      out to matter.
//
//   4. `readBinary`, used by both the top-level wasm-fetch path (already
//      shimmed for Node by the caller) and by `loadDynamicLibrary`'s
//      synchronous fallback for a lazily-discovered `.so` dependency not
//      covered by eager preload. Extended with a bounded recursive search
//      of the Emscripten virtual filesystem (some conda packages keep
//      their own versioned top-level directory instead of being flattened
//      to a standard $PREFIX layout, e.g.
//      `/microcdr-2.0.2/lib/libmicrocdr.so.2.0.2` instead of
//      `/lib/libmicrocdr.so.2.0.2`).
//
// Status as of 2026-09-13 (autonomous overnight session): with these
// patches, `import rclpy` and `from rclpy.node import Node` both succeed
// against the REAL, unmodified stock xeus-python binary bootstrapped with
// this project's real, full (145-package) ROS2 kernel environment -- the
// core "null function" crash this whole investigation chased is completely
// avoided. `rclpy.init()` currently still fails with a NEW, separate,
// much narrower problem: `_rclpy_pybind11...so` itself directly contains a
// real `std::thread` construction (confirmed via `strings`, not a
// zenoh-pico/rmw issue -- zenoh-pico is correctly built with
// Z_FEATURE_MULTI_THREAD=0) that throws "thread constructor failed:
// Resource temporarily unavailable" in a build with no real pthreads.
// This is a new, well-scoped follow-up task (find and work around/patch
// whatever internal rclpy C++ code path spawns this thread -- possibly
// related to graph-change tracking or a wait-set implementation detail),
// NOT part of the Emscripten-toolchain mystery this script's other fixes
// address.
//
// Usage: node patch_stock_xpython_js.mjs <path-to-stock-xpython.js>
// Edits the file in place. Idempotent-ish (re-running on an
// already-patched file will fail its own `assert(n === 1)` checks loudly
// rather than silently double-patching or corrupting anything).

import { readFileSync, writeFileSync } from 'node:fs';

const file = process.argv[2];
if (!file) {
  console.error('usage: node patch_stock_xpython_js.mjs <path-to-stock-xpython.js>');
  process.exit(1);
}

let content = readFileSync(file, 'utf8');

function applyPatch(name, old, replacement) {
  const count = content.split(old).length - 1;
  if (count !== 1) {
    throw new Error(`patch "${name}" expected exactly 1 occurrence of its target text, found ${count} -- file may already be patched, or this xpython.js build differs from the one these patches were written against.`);
  }
  content = content.replace(old, replacement);
  console.log(`applied: ${name}`);
}

// --- Patch 1: __asyncify_state / __asyncify_data dummy globals + generic invoke_* ---
applyPatch(
  'asyncify-stub-and-generic-invoke',
  'var proxyHandler={get(stubs,prop){switch(prop){case"__memory_base":return memoryBase;case"__table_base":return tableBase}if(prop in wasmImports&&!wasmImports[prop].stub){var res=wasmImports[prop];return res}if(!(prop in stubs)){var resolved;stubs[prop]=(...args)=>{resolved||=resolveSymbol(prop);if(!resolved){throw new Error(`Dynamic linking error: cannot resolve symbol ${prop}`)}return resolved(...args)}}return stubs[prop]}};',
  'var proxyHandler={get(stubs,prop){switch(prop){case"__memory_base":return memoryBase;case"__table_base":return tableBase;case"__asyncify_state":case"__asyncify_data":globalThis.__fakeAsyncifyGlobals||={};return globalThis.__fakeAsyncifyGlobals[prop]||=new WebAssembly.Global({value:"i32",mutable:true},0)}if(prop in wasmImports&&!wasmImports[prop].stub){var res=wasmImports[prop];return res}if(typeof prop==="string"&&prop.indexOf("invoke_")===0){if(!(prop in stubs)){stubs[prop]=(index,...args)=>{var sp=stackSave();try{return getWasmTableEntry(index)(...args)}catch(e){stackRestore(sp);throw e}}}return stubs[prop]}if(!(prop in stubs)){var resolved;stubs[prop]=(...args)=>{resolved||=resolveSymbol(prop);if(!resolved){throw new Error(`Dynamic linking error: cannot resolve symbol ${prop}`)}return resolved(...args)}}return stubs[prop]}};'
);

// --- Patch 2: hook up the real `dlerror` wasm export (present in the
// binary, just not wired to Module by the stock build) ---
applyPatch(
  'hook-up-dlerror-export',
  'function receiveInstance(instance,module){wasmExports=instance.exports;wasmExports=relocateExports(wasmExports,1024);',
  'function receiveInstance(instance,module){wasmExports=instance.exports;wasmExports=relocateExports(wasmExports,1024);if(!Module["_dlerror"]&&wasmExports["dlerror"]){Module["_dlerror"]=wasmExports["dlerror"]}'
);

// --- Patch 3: replace the broken eager/bootstrap-time shared-lib preload
// (relies on Module._emscripten_dlopen_promise, which is unsafe to call on
// a non-Asyncify host even though it exists in the compiled wasm) with the
// safe Module.loadDynamicLibrary path, skip "local" (Python C-extension)
// libs during eager preload entirely, and add a multi-pass retry for
// "global" libs with cross-package dependency-ordering issues. ---
applyPatch(
  'safe-eager-preload-with-retry',
  'try{const libt=libraryType(path);let flag=2;if(libt==="local"){flag=2|0}else if(libt==="global"){flag=2|256}const stack=Module.stackSave();const pathUTF8=Module.stringToUTF8OnStack(path);try{const pid=Module._emscripten_dlopen_promise(pathUTF8,flag);Module.stackRestore(stack);const promise=Module.getPromise(pid);Module.promiseMap.free(pid);await promise}catch(e){const dll_error_ptr=Module._dlerror();if(dll_error_ptr===0){throw Error("unknown error loading shared library")}const error=Module.UTF8ToString(dll_error_ptr,512);const error_msg=error.trim();throw new Error(`error loading shared library ${path} from package ${pkg_file_name}: ${error_msg}`)}}catch(e){throw e}finally{releaseDynlibLock()}}}Module["_loadDynlibsFromPackage"]=loadDynlibsFromPackage;',
  'try{const libt=libraryType(path);if(libt==="local"){continue}try{await Module.loadDynamicLibrary(path,{global:true,nodelete:true})}catch(e){throw new Error(`error loading shared library ${path} from package ${pkg_file_name} via loadDynamicLibrary: ${e&&e.message||e}`)}}catch(e){globalThis.__failedEagerPreloads||=[];globalThis.__failedEagerPreloads.push({path,pkg_file_name});console.warn("[eager-preload-nonfatal] skipping shared lib "+path+" from package "+pkg_file_name+" (eager preload failed, will retry in later passes): "+(e&&e.message||e))}finally{releaseDynlibLock()}}}Module["_loadDynlibsFromPackage"]=loadDynlibsFromPackage;Module["_retryFailedEagerPreloads"]=async function(maxPasses){maxPasses=maxPasses||5;for(let pass=0;pass<maxPasses;pass++){const pending=globalThis.__failedEagerPreloads||[];if(pending.length===0)break;globalThis.__failedEagerPreloads=[];let anySucceeded=false;for(const{path,pkg_file_name}of pending){try{await Module.loadDynamicLibrary(path,{global:true,nodelete:true});anySucceeded=true;console.log("[retry-pass "+pass+"] succeeded:",path)}catch(e){globalThis.__failedEagerPreloads.push({path,pkg_file_name});console.warn("[retry-pass "+pass+"] still failing:",path,"->",e&&e.message||e)}}if(!anySucceeded)break}return globalThis.__failedEagerPreloads||[]};'
);

// --- Patch 4: readBinary bounded recursive-search fallback, for .so files
// that keep their conda package's own versioned top-level directory
// instead of being flattened to a standard $PREFIX layout. Note: the
// caller is expected to have ALREADY installed a Node readAsync/readBinary
// shim (for fetching over HTTP in Node, where there's no browser
// XMLHttpRequest) before this patch runs; this patch only adds the
// virtual-FS search fallback on top of whatever readBinary already exists. ---
{
  const marker = 'readBinary=';
  const idx = content.indexOf(marker);
  if (idx === -1) {
    console.warn('WARNING: no `readBinary=` assignment found to extend with the FS-search fallback -- skipping patch 4. If you need it, apply your own Node readAsync/readBinary shim first, then re-run this script, or add the fallback manually (see this file\'s own history / AGENTS.md for the exact snippet).');
  } else {
    console.log('NOTE: patch 4 (readBinary FS-search fallback) is intentionally NOT auto-applied here, since it must be layered on top of a project/environment-specific Node readAsync/readBinary shim (browser deployments do not need it at all -- real browsers support synchronous XMLHttpRequest for this exact fallback path). See AGENTS.md for the exact snippet to splice into whatever custom readBinary the deployment environment defines.');
  }
}

writeFileSync(file, content);
console.log(`\nDone. Patched file written to: ${file}`);
