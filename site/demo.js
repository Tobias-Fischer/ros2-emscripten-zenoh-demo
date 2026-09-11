// Drives the two live demo cards. Each Emscripten build here is a classic
// (non-MODULARIZE) glue script that reads a pre-existing global `Module`
// object and starts running as soon as its <script> tag executes, so
// "launching" a demo means: set up `Module` with print/printErr wired to
// that card's console panel, then inject the glue script tag.
(function () {
  const DEMOS = {
    rclc: {
      script: "v/%%ASSET_VERSION%%/assets/talker_rclc.js",
    },
    rclpy: {
      script: "v/%%ASSET_VERSION%%/assets/rclpy_boot.js",
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

    button.disabled = true;
    button.textContent = "Running (reload page to run again)";
    setStatus(card, "loading", "downloading + compiling wasm…");
    appendLine(consoleEl, `$ fetching ${cfg.script.split("/").pop().replace(".js", ".wasm")}…`);

    let sawFirstOutput = false;

    window.Module = {
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
        if (code === 0) {
          setStatus(card, "idle", "exited cleanly — no router was reachable to keep it alive");
          appendLine(consoleEl, "[exited 0] no zenoh router reachable — start one and reload to see continuous publishing", false);
        } else {
          setStatus(card, "error", "exited with code " + code);
          appendLine(consoleEl, "[exited " + code + "]", true);
        }
      },
    };

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
                "This browser did not become cross-origin isolated (needed for real wasm32 threads). " +
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
