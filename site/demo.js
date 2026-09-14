// Drives the two live demo cards. Each Emscripten build here is a classic
// (non-MODULARIZE) glue script that reads a pre-existing global `Module`
// object and starts running as soon as its <script> tag executes, so
// "launching" a demo means: set up `Module` with print/printErr wired to
// that card's console panel, then inject the glue script.
//
// Running both cards on one page (the whole point of having two cards)
// used to crash outright. Root cause, confirmed live: neither
// talker_rclc.js nor rclpy_boot.js wraps its own top-level code in an
// IIFE -- both are one flat sequence of statements from `var Module=...`
// straight through to the trailing `preInit();run();`, no wrapper -- so
// loading both via plain `<script src>` tags runs them in the *same*
// shared top-level scope. Two problems follow from that, not one:
//
//   1. Each declares a couple of `class` names directly at that top
//      level (ExitStatus always; rclpy_boot.js also HandleAllocator, for
//      its pybind11 handle table). `class`/`let`/`const` bindings live in
//      the shared *script* scope, and JS does not allow redeclaring one
//      of those, ever, even across separate <script> tags -- the second
//      script throws a page-fatal `SyntaxError: Identifier 'ExitStatus'
//      has already been declared` the instant it's parsed, and its
//      entire top-level code fails to run at all (a syntax error aborts
//      the whole file, not just the offending line).
//   2. Renaming just the classes isn't enough on its own, though: dozens
//      of *other* top-level `var`s (Module itself, plus internal runtime
//      state like wasmMemory/wasmExports/HEAP8/...) are shared the same
//      way -- `var` redeclaration doesn't throw, it silently reuses the
//      same global property, so the second script's own initialization
//      overwrites the first script's still-running internal state out
//      from under it. This is what caused the first (already publishing)
//      demo to start throwing wasm-level "unreachable" traps and calling
//      the *other* card's tick function once the second card launched,
//      even after the SyntaxError above was fixed on its own.
//
// Fixed by not using a plain `<script src>` (which always executes in
// the shared page scope) at all: fetch each glue script's own text, wrap
// the whole thing in an IIFE that takes `Module` as a parameter, and run
// that via an inline <script> tag instead. This makes every one of the
// script's own top-level `var`/`class`/`function` declarations local to
// that one IIFE invocation -- no shared scope, no collision, regardless
// of how many of these run at once. The parameter (not a `var Module=...`
// inside the wrapped body) is what supplies each instance's own config:
// the wrapped script's own `var Module=typeof Module!="undefined"?
// Module:{}` line still runs exactly as written, but `Module` now refers
// to the parameter, which is never "undefined", so it keeps the object
// this file already prepared instead of the (former) global lookup.
(function () {
  let launchCounter = 0;

  function isolateModule(scriptText, moduleConfig) {
    const key = "__demoModuleConfig_" + launchCounter++;
    window[key] = moduleConfig;
    return `(function(Module){\n${scriptText}\n})(window[${JSON.stringify(key)}]);`;
  }

  const DEMOS = {
    // Both talker_rclc.js and rclpy_boot.js are linked with -sINVOKE_RUN=0
    // (see build_rclc.sh / build_rclpy.sh) so a standalone page can set the
    // runtime-configurable zenoh connect address via
    // zenoh_get_connect_host_buf()/...port_buf() before main() opens the
    // session, then call Module.callMain() itself once that's done -- see
    // index_rclc.html / index_rclpy.html. Neither card here has such an
    // address to set, but both still need that same explicit call, or
    // main() simply never runs: the runtime loads every dylib regardless,
    // then sits at "still waiting on run dependencies" forever with no
    // error, since nothing ever asked it to call main(). Confirmed live
    // and locally -- calling Module.callMain([]) by hand on an
    // already-"stuck" page unblocks it immediately.
    //
    // main() itself only does one-time, network-independent setup and
    // returns -- this project's whole rcl/rmw/zenoh-pico stack dropped
    // pthreads and Asyncify project-wide, so nothing blocks waiting for a
    // network round-trip inside main() anymore. Each demo exports its own
    // tick function (talker_rclc.c's rclc_demo_tick(),
    // rclpy_boot.c's rclpy_demo_tick()) that retries session/node/
    // publisher setup on every call until the zenoh session is actually
    // up (the very first attempt always fails -- z_open() can't block
    // waiting for the WebSocket "open" event, which only fires once a
    // synchronous call returns control to the browser's event loop), then
    // spins/publishes once ready. index_rclc.html / index_rclpy.html both
    // drive this with a plain setInterval; tickFn below does the same for
    // these embedded cards -- without it, main() runs its one setup pass
    // and the demo just sits there forever, never actually publishing,
    // whether or not a router is reachable.
    rclc: {
      script: "v/%%ASSET_VERSION%%/assets/talker_rclc.js",
      needsCallMain: true,
      tickFn: "rclc_demo_tick",
    },
    rclpy: {
      script: "v/%%ASSET_VERSION%%/assets/rclpy_boot.js",
      needsCallMain: true,
      tickFn: "rclpy_demo_tick",
      // rclpy_boot.c links no .so directly (see build_rclpy.sh's own
      // comment) -- Python's own `import rclpy` chain dlopen()s its real
      // dependencies (librcl_action.so and ~164 others) on demand instead.
      // A plain synchronous dlopen() can't wait on the async fetch that
      // needs, so without eagerly preloading them all first via
      // Module.loadDynamicLibrary() (same approach as
      // patches/patch_stock_xpython_js.mjs's "safe-eager-preload-with-
      // retry" patch for jupyterlite-xeus), `import rclpy` throws
      // "file not found, and synchronous loading of external files is not
      // available" on its very first real dependency, main()'s own exec()
      // of talker_rclpy.py aborts right there -- before it ever reaches
      // `def tick():` -- and every later rclpy_demo_tick() call then
      // fails with "NameError: name 'tick' is not defined", which looks
      // like a Python-scoping bug but isn't one: tick() was simply never
      // defined in the first place. See index_rclpy.html's own
      // preloadGlobalDylibs() for the original version of this fix; this
      // is the same thing, driven from this card's own launch() instead.
      dylibsJson: "v/%%ASSET_VERSION%%/assets/rclpy_dylibs.json",
    },
  };

  // See the rclpy DEMOS entry's own comment above for why this exists.
  // Ported from index_rclpy.html's preloadGlobalDylibs() -- same
  // reasoning, same retry structure, just parameterized on `dylibsJsonUrl`
  // instead of a fixed relative path.
  async function preloadGlobalDylibs(Module, dylibsJsonUrl, consoleEl) {
    const names = await (await fetch(dylibsJsonUrl)).json();
    let pending = names;
    for (let pass = 0; pass < 6 && pending.length; pass++) {
      const stillPending = [];
      for (const name of pending) {
        try {
          // loadAsync: true is load-bearing -- without it this resolves via
          // the *synchronous* path, which either throws outright or (worse)
          // succeeds once and cascades into loading much of its own
          // transitive closure synchronously and unawaited, colliding with
          // this same loop's next iteration. allowUndefined: true is also
          // load-bearing: these libraries load in plain filename order, not
          // dependency order, so one referencing a symbol from a sibling
          // that hasn't loaded yet would otherwise throw immediately and
          // leave that name stuck "loading" for every later retry pass too.
          await Module.loadDynamicLibrary(name, { global: true, nodelete: true, loadAsync: true, allowUndefined: true });
        } catch (e) {
          stillPending.push(name);
        }
      }
      pending = stillPending;
    }
    if (pending.length) {
      appendLine(consoleEl, "[err] failed to preload: " + pending.join(", "), true);
    }
  }

  function setStatus(card, state, label) {
    const el = card.querySelector(".status");
    el.className = "status " + state;
    el.querySelector(".label").textContent = label;
  }

  function appendLine(consoleEl, text, isErr) {
    const placeholder = consoleEl.querySelector(".placeholder");
    if (placeholder) placeholder.remove();
    const line = document.createElement("div");
    if (isErr) line.className = "err-line";
    line.textContent = text;
    consoleEl.appendChild(line);
    consoleEl.scrollTop = consoleEl.scrollHeight;
  }

  async function launch(name) {
    const card = document.querySelector(`[data-demo="${name}"]`);
    const consoleEl = card.querySelector(".console");
    const button = card.querySelector(".run-btn");
    const cfg = DEMOS[name];

    button.disabled = true;
    button.textContent = "Running (reload page to run again)";
    setStatus(card, "loading", "downloading + compiling wasm…");
    appendLine(consoleEl, `$ fetching ${cfg.script.split("/").pop().replace(".js", ".wasm")}…`);

    let rawText;
    try {
      rawText = await (await fetch(cfg.script)).text();
    } catch (e) {
      setStatus(card, "error", "failed to load " + cfg.script);
      appendLine(consoleEl, "[error] could not load " + cfg.script, true);
      return;
    }

    let sawFirstOutput = false;

    // A plain object, local to this launch() call -- not `window.Module`.
    // See the top-of-file comment for why that matters: each card's glue
    // script runs inside its own isolateModule() IIFE below, receiving
    // this object as its own private `Module` parameter, so two cards
    // running at once never share (or race on) any global state at all.
    const assetDir = cfg.script.slice(0, cfg.script.lastIndexOf("/") + 1);
    const Module = {
      // Emscripten's glue code normally derives its own asset directory
      // (for the .wasm file, and anything else it fetches by a bare
      // filename) from document.currentScript.src -- which only exists
      // for a `<script src>`-loaded file. Running the glue as an inline
      // script (see isolateModule() below, and the top-of-file comment
      // for why) leaves that empty, and its own fallback resolves
      // against the *page's* URL instead of this asset's -- confirmed
      // live as "wasm streaming compile failed ... HTTP status code is
      // not ok", fetching e.g. talker_rclc.wasm from the site root
      // instead of v/<sha>/assets/. Overriding locateFile sidesteps the
      // guessing entirely: every bare filename the glue code asks for
      // resolves relative to this card's own known script URL.
      locateFile: (path) => assetDir + path,
      print: (t) => {
        if (!sawFirstOutput) {
          sawFirstOutput = true;
          setStatus(card, "running", "running — watching for zenoh router at 127.0.0.1:7447");
        }
        appendLine(consoleEl, t, false);
      },
      printErr: (t) => {
        appendLine(consoleEl, t, true);
      },
      websocket: { subprotocol: null },
      onAbort: (what) => {
        setStatus(card, "error", "aborted");
        appendLine(consoleEl, "[aborted] " + what, true);
      },
      onExit: (code) => {
        // main() itself only does one-time setup and returns quickly by
        // design (see the DEMOS comment above) -- the retry-until-a-router-
        // is-reachable loop lives entirely in the tick function, called on
        // an interval below, which keeps running after this. A nonzero
        // exit here means setup itself failed, not "no router yet".
        if (code !== 0) {
          setStatus(card, "error", "exited with code " + code);
          appendLine(consoleEl, "[exited " + code + "]", true);
        }
      },
    };

    if (cfg.needsCallMain) {
      Module.onRuntimeInitialized = async () => {
        if (cfg.dylibsJson) {
          await preloadGlobalDylibs(Module, cfg.dylibsJson, consoleEl);
        }
        Module.callMain([]);
        if (cfg.tickFn) {
          setInterval(() => Module.ccall(cfg.tickFn, null, [], []), 100);
        }
      };
    }

    const s = document.createElement("script");
    s.textContent = isolateModule(rawText, Module);
    document.body.appendChild(s);
  }

  document.addEventListener("DOMContentLoaded", () => {
    document.querySelectorAll(".run-btn").forEach((btn) => {
      btn.addEventListener("click", () => launch(btn.dataset.demo));
    });

    const isolated = window.crossOriginIsolated;
    if (isolated === false) {
      document.querySelectorAll(".run-btn").forEach((btn) => {
        btn.disabled = true;
        btn.textContent = "Waiting for cross-origin isolation…";
      });
      if (window.__coiReady) {
        window.__coiReady.then((ok) => {
          if (ok && window.crossOriginIsolated) {
            location.reload();
          } else {
            document.querySelectorAll(".run-btn").forEach((btn) => {
              btn.disabled = false;
              btn.textContent = "Run demo";
            });
            document.querySelectorAll(".console").forEach((c) => {
              appendLine(
                c,
                "This browser did not become cross-origin isolated (this page still requires it, a holdover " +
                  "from an earlier real-threads build this demo no longer uses). " +
                  "Try the latest Chrome or Firefox, and make sure this page isn't embedded in an iframe.",
                true
              );
            });
          }
        });
      }
    }
  });
})();
