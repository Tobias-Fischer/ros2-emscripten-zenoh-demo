// coi-registration.js
//
// GitHub Pages serves every file with fixed headers and gives no way to add
// Cross-Origin-Opener-Policy / Cross-Origin-Embedder-Policy, but those two
// headers are exactly what a browser requires before it will hand out
// SharedArrayBuffer -- which is what these demos' pthreads (real OS-style
// threads inside the wasm32 build, not a JS shim) are built on.
//
// The fix is a small service worker that sits in front of every same-origin
// request this page makes and re-issues the response with those headers
// stapled on, so the browser treats the page as "cross-origin isolated"
// without the server having said a word about it. This is a well-known
// pattern for exactly this GitHub Pages limitation (the same trick backs
// pyodide.org, sql.js's demo, and others); this is an independent
// implementation of the same idea, not a copy of any one project's file.
(function () {
  if (typeof window === "undefined") {
    // We're inside the service worker itself.
    self.addEventListener("install", () => self.skipWaiting());
    self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));

    self.addEventListener("fetch", (event) => {
      const request = event.request;
      if (request.cache === "only-if-cached" && request.mode !== "same-origin") {
        return;
      }
      event.respondWith(
        fetch(request).then((response) => {
          if (response.status === 0) {
            return response;
          }
          const headers = new Headers(response.headers);
          headers.set("Cross-Origin-Opener-Policy", "same-origin");
          headers.set("Cross-Origin-Embedder-Policy", "require-corp");
          return new Response(response.body, {
            status: response.status,
            statusText: response.statusText,
            headers,
          });
        }).catch((err) => new Response("coi-serviceworker fetch failed: " + err, { status: 500 }))
      );
    });
    return;
  }

  // We're on the page. If we're already isolated, there's nothing to do.
  if (window.crossOriginIsolated !== false) {
    window.__coiReady = Promise.resolve(true);
    return;
  }

  if (!window.isSecureContext) {
    window.__coiReady = Promise.resolve(false);
    return;
  }

  window.__coiReady = navigator.serviceWorker
    .register(window.__coiServiceWorkerUrl || "coi-serviceworker.js")
    .then((registration) => {
      registration.addEventListener("updatefound", () => {});
      // A freshly-installed worker only controls requests made *after* this
      // one, so the very first load needs one reload to pick up the headers.
      if (!navigator.serviceWorker.controller) {
        return new Promise((resolve) => {
          navigator.serviceWorker.addEventListener("controllerchange", () => resolve(true));
        }).then(() => {
          window.location.reload();
          return new Promise(() => {}); // reloading; never resolve on this load
        });
      }
      return true;
    })
    .catch((err) => {
      console.error("coi-serviceworker registration failed", err);
      return false;
    });
})();
