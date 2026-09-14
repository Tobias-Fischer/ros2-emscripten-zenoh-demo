// Drives the two live demo cards. Each Emscripten build here is a classic
// (non-MODULARIZE) glue script that reads a pre-existing global `Module`
// object and starts running as soon as its <script> tag executes, so
// "launching" a demo means: set up `Module` with print/printErr wired to
// that card's console panel, then inject the glue script tag.
(function () {
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
      // No tickFn here (yet) -- unlike rclc_demo_tick(), calling
      // rclpy_demo_tick() repeatedly on this card hits a real, separate
      // bug: "NameError: name 'tick' is not defined" from the second call
      // on, even though rclpy_boot.c's main() does define a Python-level
      // tick() during its own initial run. Something about how that
      // function's global scope is (or isn't) preserved across repeated
      // re-entry from C isn't right yet -- confirmed live, not something
      // this file can work around. needsCallMain alone is still a real,
      // independent fix: without it main() (and rclpy.init()) never ran
      // at all on this card. Leave tickFn off until the Python-side bug
      // is actually root-caused, rather than shipping a card that error-
      // spams instead of just sitting idle.
    },
  };

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

  function launch(name) {
    const card = document.querySelector(`[data-demo="${name}"]`);
    const consoleEl = card.querySelector(".console");
    const button = card.querySelector(".run-btn");
    const cfg = DEMOS[name];

    // Running both demo cards at once loads two separate top-level
    // Emscripten MAIN_MODULE programs into the same page simultaneously --
    // confirmed live to be genuinely unstable (one crashes with a wasm
    // "unreachable" trap once the other starts loading its own module),
    // unrelated to anything this file controls. Disable every "Run demo"
    // button, not just this card's own, so a visitor can't stumble into
    // that combination; reload the page to try a different demo.
    document.querySelectorAll(".run-btn").forEach((btn) => {
      btn.disabled = true;
      btn.textContent =
        btn === button
          ? "Running (reload page to run again)"
          : "Reload page to try this demo instead";
    });
    setStatus(card, "loading", "downloading + compiling wasm…");
    appendLine(consoleEl, `$ fetching ${cfg.script.split("/").pop().replace(".js", ".wasm")}…`);

    let sawFirstOutput = false;

    // Captured locally (not read back via `window.Module` inside the
    // callbacks below) because both cards share that one global slot --
    // launching the second demo overwrites it while the first demo's own
    // tick setInterval is still running. Without this, that stale
    // interval keeps firing against whatever `window.Module` now points
    // to (the *other* card's, possibly still-uninitialized, Module),
    // throwing "ccall is not a function" every 100ms forever. Emscripten's
    // classic (non-MODULARIZE) glue reads the global once at script-load
    // time and mutates this exact object in place from then on, so this
    // reference stays valid for this card's own instance regardless of
    // what the global gets reassigned to later.
    const Module = (window.Module = {
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
    });

    if (cfg.needsCallMain) {
      Module.onRuntimeInitialized = () => {
        Module.callMain([]);
        if (cfg.tickFn) {
          setInterval(() => Module.ccall(cfg.tickFn, null, [], []), 100);
        }
      };
    }

    const s = document.createElement("script");
    s.src = cfg.script;
    s.onerror = () => {
      setStatus(card, "error", "failed to load " + cfg.script);
      appendLine(consoleEl, "[error] could not load " + cfg.script, true);
    };
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
