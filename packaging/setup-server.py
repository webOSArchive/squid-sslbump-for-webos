#!/usr/bin/env python3
"""
squid-sslbump-for-webos setup server
Runs on port 3129 alongside Squid, serves the CA cert and setup instructions.

Predictable endpoints (stable for webOS app automation):
  GET /cert        -> CA cert in DER format (for device installation)
  GET /cert.pem    -> CA cert in PEM format
  GET /            -> setup page with instructions and download links
"""

import http.server
import os
import socket
import sys

SQUID_DIR   = "/usr/local/squid"
CERT_DER    = os.path.join(SQUID_DIR, "ssl", "localCert.der")
CERT_PEM    = os.path.join(SQUID_DIR, "ssl", "localCert.crt")
PORT        = 3129
PROXY_PORT  = 3128


def local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "your-proxy-ip"


def setup_page(ip):
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
  .btn {{ display: inline-block; padding: 10px 22px; background: #005a9c; color: #fff;
          text-decoration: none; border-radius: 4px; margin: 6px 4px 6px 0; font-size: 0.95em; }}
  .btn.secondary {{ background: #555; }}
  ol li {{ margin: 6px 0; }}
  code {{ background: #eee; padding: 1px 5px; border-radius: 3px; font-size: 0.95em; }}
  .note {{ color: #666; font-size: 0.9em; }}
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
  <a class="btn" href="/cert">Download certificate (.der)</a>
  <a class="btn secondary" href="/cert.pem">Download certificate (.pem)</a>
  <p class="note">Use .der for most webOS devices. Use .pem if .der is not accepted.</p>
</div>

<h2>Device-specific instructions</h2>

<h3>Palm webOS (Pre, Pixi, TouchPad)</h3>
<ol>
  <li>Download the certificate above to your device.</li>
  <li>Open <b>Device Info</b> → <b>Certificate Manager</b>.</li>
  <li>Tap <b>Get Certificates</b> and locate the downloaded file.</li>
  <li>Accept and install. The certificate should appear as trusted.</li>
  <li>Go to <b>Wi-Fi</b> settings, tap your network, and set the proxy to the values above.</li>
</ol>

<h3>LG webOS Smart TV (2012–2016)</h3>
<ol>
  <li>Go to <b>Settings</b> → <b>Network</b> → <b>Wi-Fi Connection</b> → <b>Advanced Settings</b>.</li>
  <li>Enable <b>Proxy</b> and enter the host and port above.</li>
  <li>To install the certificate: insert a USB drive with the .der file,
      go to <b>Settings</b> → <b>General</b> → <b>About This TV</b> → <b>User Agreements</b>
      and follow your TV model's certificate import steps.</li>
</ol>

<h3>Other devices</h3>
<ol>
  <li>Set the HTTP/HTTPS proxy in your device's network settings.</li>
  <li>Install the .der certificate as a trusted CA in your device's certificate store.</li>
</ol>

<h2>For webOS app developers</h2>
<div class="box">
  <p>The certificate is always available at a predictable URL:</p>
  <code>http://{ip}:{PORT}/cert</code>
  <p class="note">This URL is stable across updates and suitable for automated cert download and installation from a webOS app.</p>
</div>

</body>
</html>
""".encode()


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
        else:
            body = setup_page(local_ip())
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

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

    def log_message(self, fmt, *args):
        # Suppress per-request access log noise; errors still go to stderr
        pass


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
