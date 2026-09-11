#!/usr/bin/env python3
"""Injects coi-serviceworker.js into every JupyterLite entry-point page.

site/coi-serviceworker.js is only <script src="...">'d from site/index.html
-- JupyterLite's own generated pages (jupyterlite-content/_output/**) never
load it. GitHub Pages can't send custom response headers, so a visitor who
opens a JupyterLite page directly -- exactly what our own "Open the
notebook" button does, and what anyone does on a fresh/incognito visit --
gets no COOP/COEP headers and therefore no cross-origin isolation on that
page, which is what "gets stuck executing the first cell" was.

Run after `jupyter lite build`, before the built _output/ is copied into
the Pages payload. Usage:
    inject_coi_serviceworker.py <jupyterlite _output dir> <coi-serviceworker.js source>
"""
import re
import shutil
import sys
from pathlib import Path

ROOT_ATTR_RE = re.compile(r'data-jupyter-lite-root="([^"]*)"')


def main():
    output_dir = Path(sys.argv[1])
    coi_source = Path(sys.argv[2])
    shutil.copy(coi_source, output_dir / "coi-serviceworker.js")

    injected = 0
    for html_file in output_dir.rglob("index.html"):
        text = html_file.read_text()
        match = ROOT_ATTR_RE.search(text)
        if not match:
            continue  # a redirect-only page (e.g. lab/tree/) -- nothing boots here
        root = match.group(1)
        sw_url = "coi-serviceworker.js" if root == "." else f"{root}/coi-serviceworker.js"
        snippet = (
            f'<script>window.__coiServiceWorkerUrl = "{sw_url}";</script>'
            f'<script src="{sw_url}"></script>'
        )
        new_text = text.replace("<head>", "<head>\n    " + snippet, 1)
        if new_text == text:
            raise RuntimeError(f"no <head> tag found in {html_file}")
        html_file.write_text(new_text)
        injected += 1

    print(f"Injected coi-serviceworker.js into {injected} JupyterLite page(s)")


if __name__ == "__main__":
    main()
