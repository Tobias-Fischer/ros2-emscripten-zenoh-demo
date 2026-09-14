#!/usr/bin/env node
// Patches browser_demo/out/rclpy_boot.js (the standalone rclpy demo's own
// MAIN_MODULE, built by build_rclpy.sh -- NOT jupyterlite-xeus's stock
// xpython.js, see patch_stock_xpython_js.mjs for that one) so it can
// dlopen numpy's own compiled extensions.
//
// Why this exists: rclpy_boot.js is built with -fwasm-exceptions (to
// match the rest of this project's own now-Asyncify-free packages, all
// built with vinca's own -fwasm-exceptions default -- see build_rclpy.sh's
// own comments on EMCC_FORCE_STDLIBS/libunwind for the full story on
// getting THAT part working). numpy's own compiled extensions
// (_multiarray_umath...so and friends), built separately by
// emscripten-forge-4x rather than by this project's own vinca pipeline,
// still reference the old JS-exception-model `invoke_*` trampolines
// (e.g. `invoke_viiii`) for indirect calls -- which a -fwasm-exceptions
// MAIN_MODULE's own proxyHandler doesn't generically provide (confirmed
// live: "undefined symbol 'invoke_viiii'" -> "RuntimeError: unreachable"
// dlopen'ing numpy's _multiarray_umath.so). The exact same class of gap,
// same generic fix, as patch_stock_xpython_js.mjs's "asyncify-stub-and-
// generic-invoke" patch -- this file reuses just that one patch (not the
// other three, which are xpython.js/jupyterlite-xeus-specific and don't
// apply to this project's own em++-built rclpy_boot.js at all: confirmed,
// patch_stock_xpython_js.mjs's "safe-eager-preload-with-retry" patch
// throws "found 0" occurrences against this file's different generated
// structure -- unsurprising, since this demo already has its own
// eager-preload mechanism, see index_rclpy.html's preloadGlobalDylibs()).
//
// Usage: node patch_rclpy_boot_js.mjs <path-to-rclpy_boot.js>
// Edits the file in place. Throws loudly (not a silent no-op) if the
// target text isn't found exactly once, same convention as
// patch_stock_xpython_js.mjs.

import { readFileSync, writeFileSync } from 'node:fs';

const file = process.argv[2];
if (!file) {
  console.error('usage: node patch_rclpy_boot_js.mjs <path-to-rclpy_boot.js>');
  process.exit(1);
}

let content = readFileSync(file, 'utf8');

function applyPatch(name, old, replacement) {
  const count = content.split(old).length - 1;
  if (count !== 1) {
    throw new Error(`patch "${name}" expected exactly 1 occurrence of its target text, found ${count} -- file may already be patched, or this build differs from the one this patch was written against.`);
  }
  content = content.replace(old, replacement);
  console.log(`applied: ${name}`);
}

// Same fix as patch_stock_xpython_js.mjs's "asyncify-stub-and-generic-invoke"
// patch -- see that file's own header comment for the full rationale. The
// __asyncify_state/__asyncify_data dummy-global half is inert here (this
// module never actually needs them), kept only because it's the same
// proxyHandler text block as the generic invoke_* fix this file actually
// needs.
applyPatch(
  'asyncify-stub-and-generic-invoke',
  'var proxyHandler={get(stubs,prop){switch(prop){case"__memory_base":return memoryBase;case"__table_base":return tableBase}if(prop in wasmImports&&!wasmImports[prop].stub){var res=wasmImports[prop];return res}if(!(prop in stubs)){var resolved;stubs[prop]=(...args)=>{resolved||=resolveSymbol(prop);if(!resolved){throw new Error(`Dynamic linking error: cannot resolve symbol ${prop}`)}return resolved(...args)}}return stubs[prop]}};',
  'var proxyHandler={get(stubs,prop){switch(prop){case"__memory_base":return memoryBase;case"__table_base":return tableBase;case"__asyncify_state":case"__asyncify_data":globalThis.__fakeAsyncifyGlobals||={};return globalThis.__fakeAsyncifyGlobals[prop]||=new WebAssembly.Global({value:"i32",mutable:true},0)}if(prop in wasmImports&&!wasmImports[prop].stub){var res=wasmImports[prop];return res}if(typeof prop==="string"&&prop.indexOf("invoke_")===0){if(!(prop in stubs)){stubs[prop]=(index,...args)=>{var sp=stackSave();try{return getWasmTableEntry(index)(...args)}catch(e){stackRestore(sp);throw e}}}return stubs[prop]}if(!(prop in stubs)){var resolved;stubs[prop]=(...args)=>{resolved||=resolveSymbol(prop);if(!resolved){throw new Error(`Dynamic linking error: cannot resolve symbol ${prop}`)}return resolved(...args)}}return stubs[prop]}};'
);

writeFileSync(file, content);
console.log(`\nDone. Patched file written to: ${file}`);
