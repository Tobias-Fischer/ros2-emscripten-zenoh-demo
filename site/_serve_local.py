#!/usr/bin/env python3
# Local-only helper for previewing the site with the COOP/COEP headers a real
# GitHub Pages deploy won't send (coi-serviceworker.js papers over that gap in
# production; this script exists only so local testing doesn't even need it).
import http.server
import functools
import sys
import os

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8877
    directory = os.path.dirname(os.path.abspath(__file__))
    handler = functools.partial(Handler, directory=directory)
    http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
