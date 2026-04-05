#!/usr/bin/env python3
"""
squid-sslbump-for-webos setup server
Runs on port 3129 alongside Squid, serves the CA cert, setup instructions,
and add-on management.

Endpoints:
  GET /                          -> setup page with instructions and add-ons
  GET /cert                      -> redirect to /localCert.der
  GET /localCert.der             -> CA cert in DER format
  GET /cert.pem / /localCert.pem -> CA cert in PEM format
  GET /api/addons                -> JSON list of add-ons and install status
  POST /api/addon/install?id=X   -> install an add-on (downloads in background)
  GET  /api/addon/status?id=X   -> install progress (JSON)
  POST /api/addon/remove?id=X    -> remove an installed add-on
"""

import http.server
import json
import os
import shutil
import socket
import sys
import threading
import urllib.request
import zipfile

SQUID_DIR   = "/usr/local/squid"
CERT_DER    = os.path.join(SQUID_DIR, "ssl", "localCert.der")
CERT_PEM    = os.path.join(SQUID_DIR, "ssl", "localCert.crt")
ARCHIVE_DIR = os.path.join(SQUID_DIR, "var", "archive")
PORT        = 3129
PROXY_PORT  = 3128

# ---------------------------------------------------------------------------
# Add-on registry
# ---------------------------------------------------------------------------
ADDONS = [
    {
        "id":           "help-palm-com",
        "name":         "Palm Help Archive",
        "description":  "Restores the built-in Help app for Palm Pre, Pixi, Veer, and TouchPad. "
                        "Routes help.palm.com through this proxy to a local copy of the archive.",
        "download_url": "https://github.com/webOSArchive/help.palm.com/archive/refs/heads/main.zip",
        "install_dir":  "help.palm.com",
        "zip_root":     "help.palm.com-main",   # top-level dir inside the zip
        "size_hint":    "~300 MB download",
    },
]

# ---------------------------------------------------------------------------
# Install state (in-memory; one install at a time)
# ---------------------------------------------------------------------------
_install_state = {}   # addon_id -> {"status": ..., "message": ..., "pct": 0..100}
_install_lock  = threading.Lock()


def addon_install_dir(addon):
    return os.path.join(ARCHIVE_DIR, addon["install_dir"])


def addon_installed(addon):
    return os.path.isdir(addon_install_dir(addon))


def _run_install(addon):
    addon_id  = addon["id"]
    url       = addon["download_url"]
    dest_dir  = addon_install_dir(addon)
    tmp_zip   = dest_dir + ".download.zip"
    tmp_unzip = dest_dir + ".unzip_tmp"

    def set_state(status, message, pct=0):
        with _install_lock:
            _install_state[addon_id] = {"status": status, "message": message, "pct": pct}

    try:
        os.makedirs(ARCHIVE_DIR, exist_ok=True)

        # -- Download --
        set_state("downloading", f"Downloading {addon['size_hint']}…", 5)
        req = urllib.request.Request(url, headers={"User-Agent": "squid-sslbump-for-webos"})
        with urllib.request.urlopen(req, timeout=300) as resp, open(tmp_zip, "wb") as f:
            total = int(resp.headers.get("Content-Length", 0))
            downloaded = 0
            while True:
                chunk = resp.read(65536)
                if not chunk:
                    break
                f.write(chunk)
                downloaded += len(chunk)
                if total:
                    pct = 5 + int(downloaded / total * 55)
                    set_state("downloading", f"Downloading… {downloaded // (1024*1024)} MB / {total // (1024*1024)} MB", pct)

        # -- Extract --
        set_state("extracting", "Extracting archive…", 62)
        if os.path.exists(tmp_unzip):
            shutil.rmtree(tmp_unzip)
        with zipfile.ZipFile(tmp_zip, "r") as z:
            members = z.namelist()
            total_m = len(members)
            for i, member in enumerate(members):
                z.extract(member, tmp_unzip)
                if i % 500 == 0:
                    pct = 62 + int(i / total_m * 30)
                    set_state("extracting", f"Extracting… {i}/{total_m} files", pct)

        # -- Move into place --
        set_state("installing", "Installing files…", 94)
        extracted_root = os.path.join(tmp_unzip, addon["zip_root"])
        if os.path.exists(dest_dir):
            shutil.rmtree(dest_dir)
        shutil.move(extracted_root, dest_dir)

        # -- Cleanup --
        os.remove(tmp_zip)
        shutil.rmtree(tmp_unzip, ignore_errors=True)

        set_state("done", "Installed successfully.", 100)

    except Exception as e:
        set_state("error", f"Installation failed: {e}", 0)
        for path in (tmp_zip, tmp_unzip):
            if os.path.exists(path):
                try:
                    shutil.rmtree(path) if os.path.isdir(path) else os.remove(path)
                except Exception:
                    pass


# ---------------------------------------------------------------------------
# HTML helpers
# ---------------------------------------------------------------------------

def local_ip():
    # Allow Docker users to override with the host machine's LAN IP, since
    # the container's default route interface returns an internal bridge IP.
    if os.environ.get("PROXY_IP"):
        return os.environ["PROXY_IP"]
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "your-proxy-ip"


def addon_card_html(addon, ip):
    installed  = addon_installed(addon)
    addon_id   = addon["id"]
    state      = _install_state.get(addon_id, {})
    status     = state.get("status", "")
    in_progress = status in ("downloading", "extracting", "installing")

    if in_progress:
        pct = state.get("pct", 0)
        msg = state.get("message", "Working…")
        action = f"""
      <div class="progress-wrap"><div class="progress-bar" style="width:{pct}%"></div></div>
      <p class="note" id="status-{addon_id}">{msg}</p>
      <p class="note">Do not close this page while installing.</p>"""
    elif status == "error":
        msg = state.get("message", "Unknown error")
        action = f"""
      <p class="err">{msg}</p>
      <button class="btn" onclick="installAddon('{addon_id}')">Retry</button>"""
    elif installed:
        action = f"""
      <span class="badge installed">Installed</span>
      <button class="btn secondary" onclick="removeAddon('{addon_id}')">Remove</button>"""
    else:
        action = f"""
      <button class="btn" onclick="installAddon('{addon_id}')">Install</button>
      <span class="hint">{addon['size_hint']}</span>"""

    return f"""
  <div class="addon-card" id="card-{addon_id}">
    <div class="addon-title">{addon['name']}</div>
    <p class="addon-desc">{addon['description']}</p>
    <div class="addon-action">{action}</div>
  </div>"""


def setup_page(ip):
    addon_cards = "".join(addon_card_html(a, ip) for a in ADDONS)
    # Collect any in-progress addon IDs for auto-poll
    polling = [a["id"] for a in ADDONS
               if _install_state.get(a["id"], {}).get("status") in
               ("downloading", "extracting", "installing")]
    polling_json = json.dumps(polling)

    return f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>squid-sslbump-for-webos setup</title>
<style>
  body {{ font-family: sans-serif; max-width: 700px; margin: 40px auto; padding: 0 20px; color: #222; }}
  h1 {{ font-size: 1.4em; }}
  h2 {{ font-size: 1.1em; margin-top: 2em; border-bottom: 1px solid #ccc; padding-bottom: 4px; }}
  .box {{ background: #f4f4f4; border: 1px solid #ddd; border-radius: 4px; padding: 14px 18px; margin: 12px 0; }}
  .val {{ font-family: monospace; font-size: 1.2em; font-weight: bold; color: #005a9c; }}
  .btn {{ display: inline-block; padding: 8px 18px; background: #005a9c; color: #fff; border: none;
          border-radius: 4px; margin: 4px 4px 4px 0; font-size: 0.9em; cursor: pointer; }}
  .btn.secondary {{ background: #888; }}
  ol li {{ margin: 6px 0; }}
  code {{ background: #eee; padding: 1px 5px; border-radius: 3px; font-size: 0.95em; }}
  .note {{ color: #666; font-size: 0.9em; }}
  .hint {{ display: inline-block; color: #888; font-size: 0.85em; margin-left: 8px; }}
  .err  {{ color: #c00; font-size: 0.9em; }}
  .addon-card {{ border: 1px solid #ddd; border-radius: 4px; padding: 14px 18px; margin: 10px 0; }}
  .addon-title {{ font-weight: bold; font-size: 1em; margin-bottom: 4px; }}
  .addon-desc {{ font-size: 0.9em; color: #444; margin: 4px 0 10px; }}
  .addon-action {{ }}
  .addon-action .btn {{ margin-right: 6px; }}
  .badge.installed {{ background: #2a7; color: #fff; border-radius: 3px; padding: 3px 10px;
                       font-size: 0.85em; display: inline-block; margin-right: 6px; }}
  .progress-wrap {{ width: 100%; background: #e0e0e0; border-radius: 3px; height: 8px; margin: 6px 0; }}
  .progress-bar  {{ background: #005a9c; height: 8px; border-radius: 3px; }}
  .addon-note {{ background: #fffbe6; border: 1px solid #e6d800; border-radius: 4px;
                  padding: 10px 14px; margin: 8px 0; font-size: 0.88em; color: #555; }}
</style>
</head>
<body>

<h1>squid-sslbump-for-webos</h1>
<p>Your SSL proxy is running. Follow the steps below to configure your retro device.</p>

<h2>Step 1 — Configure the proxy</h2>
<div class="box">
  <p>Set your device's HTTP and HTTPS proxy to:</p>
  <p>Host: <span class="val">{ip}</span> &nbsp;&nbsp; Port: <span class="val">{PROXY_PORT}</span></p>
</div>

<h2>Step 2 — Install the CA certificate</h2>
<div class="box">
  <p>Download and install the certificate so your device trusts HTTPS connections through the proxy.</p>
  <a class="btn" href="/localCert.der">Download certificate (.der)</a>
  <a class="btn secondary" href="/cert.pem">Download certificate (.pem)</a>
  <p class="note">Use .der for most webOS devices. Use .pem if .der is not accepted.</p>
</div>

<h3>Setup on Palm/HP webOS</h3>
<ol>
  <li>Download the certificate above to your device.</li>
  <li>Open <b>Device Info</b> → <b>Certificate Manager</b>.</li>
  <li>Tap <b>Get Certificates</b> and locate the downloaded file.</li>
  <li>Accept and install. The certificate should appear as trusted.</li>
  <li>Go to <b>Wi-Fi</b> settings, tap your network, and set the proxy to the values above.</li>
</ol>

<h3>Other devices</h3>
<ol>
  <li>Set the HTTP/HTTPS proxy in your device's network settings.</li>
  <li>Install the .der certificate as a trusted CA in your device's certificate store.</li>
</ol>

<h2>Add-ons</h2>
<div class="addon-note">
  &#9432; Add-on installation downloads content from the internet.
  You might want to Install from a modern browser on your network.
</div>
{addon_cards}

<script>
function installAddon(id) {{
  var action = document.querySelector('#card-' + id + ' .addon-action');
  action.innerHTML =
    '<div class="progress-wrap"><div class="progress-bar" id="bar-' + id + '" style="width:2%"></div></div>' +
    '<p class="note" id="status-' + id + '">Starting download...</p>' +
    '<p class="note">Do not close this page while installing.</p>';
  var xhr = new XMLHttpRequest();
  xhr.open('POST', '/api/addon/install?id=' + id, true);
  xhr.onreadystatechange = function() {{
    if (xhr.readyState === 4) {{ pollStatus(id); }}
  }};
  xhr.send();
}}
function removeAddon(id) {{
  if (!confirm('Remove this add-on? The downloaded content will be deleted.')) return;
  var xhr = new XMLHttpRequest();
  xhr.open('POST', '/api/addon/remove?id=' + id, true);
  xhr.onreadystatechange = function() {{
    if (xhr.readyState === 4) {{ location.reload(); }}
  }};
  xhr.send();
}}
function pollStatus(id) {{
  var xhr = new XMLHttpRequest();
  xhr.open('GET', '/api/addon/status?id=' + id, true);
  xhr.onreadystatechange = function() {{
    if (xhr.readyState !== 4) {{ return; }}
    var s = JSON.parse(xhr.responseText);
    var el = document.getElementById('status-' + id);
    if (el) {{ el.innerHTML = s.message; }}
    var bar = document.getElementById('bar-' + id);
    if (!bar) {{ bar = document.querySelector('#card-' + id + ' .progress-bar'); }}
    if (bar) {{ bar.style.width = s.pct + '%'; }}
    if (s.status === 'done' || s.status === 'error') {{
      location.reload();
    }} else {{
      setTimeout(function() {{ pollStatus(id); }}, 1500);
    }}
  }};
  xhr.send();
}}
// Resume polling for any in-progress installs after page load
var inProgress = {polling_json};
for (var i = 0; i < inProgress.length; i++) {{
  (function(id) {{ setTimeout(function() {{ pollStatus(id); }}, 1500); }})(inProgress[i]);
}}
</script>

</body>
</html>
""".encode()


# ---------------------------------------------------------------------------
# Request handler
# ---------------------------------------------------------------------------

class SetupHandler(http.server.BaseHTTPRequestHandler):

    def do_GET(self):
        if self.path == "/cert":
            self.send_response(302)
            self.send_header("Location", "/localCert.der")
            self.send_header("Content-Length", "0")
            self.end_headers()
        elif self.path == "/localCert.der":
            self._serve_file(CERT_DER, "application/x-x509-ca-cert", "localCert.der")
        elif self.path in ("/cert.pem", "/localCert.pem"):
            self._serve_file(CERT_PEM, "application/x-pem-file", "localCert.pem")
        elif self.path == "/api/addons":
            self._api_addons()
        elif self.path.startswith("/api/addon/status"):
            self._api_status()
        else:
            body = setup_page(local_ip())
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    def do_POST(self):
        if self.path.startswith("/api/addon/install"):
            self._api_install()
        elif self.path.startswith("/api/addon/remove"):
            self._api_remove()
        else:
            self._json(404, {"error": "not found"})

    # ------------------------------------------------------------------

    def _api_addons(self):
        result = []
        for a in ADDONS:
            state = _install_state.get(a["id"], {})
            result.append({
                "id":        a["id"],
                "name":      a["name"],
                "installed": addon_installed(a),
                "status":    state.get("status", "idle"),
                "message":   state.get("message", ""),
                "pct":       state.get("pct", 0),
            })
        self._json(200, result)

    def _api_status(self):
        addon_id = self._query_param("id")
        state = _install_state.get(addon_id, {"status": "idle", "message": "", "pct": 0})
        self._json(200, state)

    def _api_install(self):
        addon_id = self._query_param("id")
        addon = next((a for a in ADDONS if a["id"] == addon_id), None)
        if not addon:
            self._json(404, {"error": "unknown addon"})
            return

        with _install_lock:
            current = _install_state.get(addon_id, {}).get("status", "")
            if current in ("downloading", "extracting", "installing"):
                self._json(409, {"error": "already in progress"})
                return
            _install_state[addon_id] = {"status": "downloading", "message": "Starting…", "pct": 0}

        t = threading.Thread(target=_run_install, args=(addon,), daemon=True)
        t.start()
        self._json(202, {"status": "started"})

    def _api_remove(self):
        addon_id = self._query_param("id")
        addon = next((a for a in ADDONS if a["id"] == addon_id), None)
        if not addon:
            self._json(404, {"error": "unknown addon"})
            return
        dest = addon_install_dir(addon)
        if os.path.isdir(dest):
            shutil.rmtree(dest)
        with _install_lock:
            _install_state.pop(addon_id, None)
        self._json(200, {"status": "removed"})

    # ------------------------------------------------------------------

    def _serve_file(self, path, content_type, filename):
        if not os.path.exists(path):
            self.send_response(503)
            body = b"Certificate not yet generated. The proxy service may still be starting."
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        with open(path, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _query_param(self, key):
        if "?" not in self.path:
            return ""
        qs = self.path.split("?", 1)[1]
        for part in qs.split("&"):
            if "=" in part:
                k, v = part.split("=", 1)
                if k == key:
                    return v
        return ""

    def log_message(self, fmt, *args):
        pass


# ---------------------------------------------------------------------------

if __name__ == "__main__":
    server = http.server.HTTPServer(("", PORT), SetupHandler)
    ip = local_ip()
    print(f"Setup server listening on port {PORT}")
    print(f"  http://{ip}:{PORT}/       — setup page")
    print(f"  http://{ip}:{PORT}/cert   — CA certificate (DER)")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
