#!/usr/bin/env python3
# Local-only helper for previewing the site (or a full assembled deploy
# payload) the way GitHub Pages actually serves it -- COOP/COEP headers a
# real deploy won't send (coi-serviceworker.js papers over that gap in
# production; this script exists only so local testing doesn't even need
# it), and a content-hash ETag on every response so the browser always
# revalidates instead of silently reusing a stale copy from an earlier
# local rebuild on the same origin/port. Plain http.server sends neither,
# which is exactly what makes JupyterLite in particular look broken after
# a rebuild until you clear site data and hard-reload a few times --
# revalidation-by-default here means a changed file is always picked up
# on the very next load, no manual cache-busting required.
import functools
import hashlib
import http.server
import os
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        # No max-age at all: every request revalidates via the ETag below,
        # so a rebuilt file is always caught, but an unchanged one still
        # gets a cheap 304 instead of a full re-transfer.
        self.send_header("Cache-Control", "no-cache")
        etag = getattr(self, "_etag", None)
        if etag is not None:
            self.send_header("ETag", etag)
        super().end_headers()

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        try:
            with open(path, "rb") as f:
                digest = hashlib.sha256(f.read()).hexdigest()[:16]
        except OSError:
            return super().send_head()
        self._etag = f'"{digest}"'
        if self.headers.get("If-None-Match") == self._etag:
            self.send_response(304)
            self.end_headers()
            return None
        return super().send_head()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8877
    directory = (
        os.path.abspath(sys.argv[2])
        if len(sys.argv) > 2
        else os.path.dirname(os.path.abspath(__file__))
    )
    handler = functools.partial(Handler, directory=directory)
    print(f"Serving {directory} on http://127.0.0.1:{port} (ETag revalidation, no caching)")
    http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
