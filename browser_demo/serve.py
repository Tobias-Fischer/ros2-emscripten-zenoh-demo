#!/usr/bin/env python3
import http.server
import functools
import os
import sys

class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "out")
    handler = functools.partial(Handler, directory=out_dir)
    http.server.ThreadingHTTPServer(("127.0.0.1", port), handler).serve_forever()
