#!/usr/bin/env python3
"""
squid-sslbump-for-webos archive server
Runs on port 3130 alongside Squid, serves locally-installed archived websites.

Squid routes requests for archived domains here via cache_peer.
Each installed site lives under:
  /usr/local/squid/var/archive/<hostname>/

If a site is not installed, requests return 503 with an install prompt.
"""

import http.server
import mimetypes
import os
import urllib.parse

ARCHIVE_ROOT = "/usr/local/squid/var/archive"
PORT = 3130

# Map hostname aliases to canonical install directory names
HOST_MAP = {
    "help.palm.com":           "help.palm.com",
    "downloads.help.palm.com": "help.palm.com",   # CNAME — same content
}

# Google domains to redirect to DuckDuckGo Lite
GOOGLE_DOMAINS = {"www.google.com", "google.com"}

MIME_EXTRA = {
    ".json": "application/json",
    ".cgi":  "text/html",
}


class ArchiveHandler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        host = self.headers.get("Host", "").split(":")[0].lower()

        if host in GOOGLE_DOMAINS:
            self._redirect_to_ddg()
            return

        site_name = HOST_MAP.get(host)

        if not site_name:
            self._send_text(404, f"No archived content for host: {host}")
            return

        site_root = os.path.join(ARCHIVE_ROOT, site_name)
        if not os.path.isdir(site_root):
            self._send_html(503, self._not_installed_page(host))
            return

        # Resolve file path
        # Strip query string
        path = self.path.split("?")[0]

        # Block path traversal
        rel = os.path.normpath(path.lstrip("/"))
        if rel.startswith(".."):
            self._send_text(400, "Bad request")
            return

        # PHP files are not executed — redirect to the GitHub repo
        if rel.endswith(".php"):
            self.send_response(302)
            self.send_header("Location", "https://github.com/webOSArchive/help.palm.com")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        # CGI files are not supported
        if rel.endswith(".cgi"):
            self._send_html(501, self._search_unavailable_page())
            return

        file_path = os.path.join(site_root, rel)

        # Directory: look for index.html or index.json
        if os.path.isdir(file_path):
            for index in ("index.html", "index.json"):
                candidate = os.path.join(file_path, index)
                if os.path.isfile(candidate):
                    file_path = candidate
                    break
            else:
                self._send_text(404, "Not found")
                return

        if not os.path.isfile(file_path):
            self._send_text(404, "Not found")
            return

        ext = os.path.splitext(file_path)[1].lower()
        content_type = (
            MIME_EXTRA.get(ext)
            or mimetypes.guess_type(file_path)[0]
            or "application/octet-stream"
        )

        with open(file_path, "rb") as f:
            data = f.read()

        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        # Allow retro devices with broken SSL stacks to cache aggressively
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        self.wfile.write(data)

    def _redirect_to_ddg(self):
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        q = params.get("q", [""])[0]
        if q:
            ddg_url = "https://lite.duckduckgo.com/lite/?" + urllib.parse.urlencode({"q": q})
        else:
            ddg_url = "https://lite.duckduckgo.com/lite/"
        self.send_response(302)
        self.send_header("Location", ddg_url)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _send_text(self, code, message):
        body = message.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, code, html):
        body = html if isinstance(html, bytes) else html.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _not_installed_page(self, host):
        return f"""<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Add-on not installed</title>
<style>body{{font-family:sans-serif;max-width:600px;margin:60px auto;padding:0 20px;color:#222}}
h1{{font-size:1.3em}}a{{color:#005a9c}}</style></head>
<body>
<h1>Archive content not installed</h1>
<p>You requested content from <strong>{host}</strong>, but the Palm Help Archive
add-on is not installed on this proxy.</p>
<p>To install it, open the <a href="http://your-proxy-ip:3129/">proxy setup page</a>
from a modern browser and click <strong>Install</strong> next to the Palm Help Archive.</p>
</body></html>"""

    def _search_unavailable_page(self):
        return """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Search unavailable</title>
<style>body{{font-family:sans-serif;max-width:600px;margin:60px auto;padding:0 20px;color:#222}}
h1{{font-size:1.3em}}</style></head>
<body>
<h1>Search is not available</h1>
<p>The help search feature requires a server-side component that is not
supported in the local archive. Browse the help topics from your device's
Help app instead.</p>
</body></html>"""

    def log_message(self, fmt, *args):
        pass  # Suppress per-request noise


if __name__ == "__main__":
    server = http.server.HTTPServer(("", PORT), ArchiveHandler)
    print(f"Archive server listening on port {PORT}")
    import sys
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
