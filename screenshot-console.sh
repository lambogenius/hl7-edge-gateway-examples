#!/bin/sh
# Takes a screenshot of a running sample's admin console overview (light theme, 1600x900 at 2x), with Playwright in
# Docker. Signs in with HL7EDGE_ADMIN_TOKEN, or with CONSOLE_USER and CONSOLE_PASSWORD when those are set.
#   ./screenshot-console.sh overview.png                              http://localhost:8080
#   ./screenshot-console.sh overview.png https://localhost:8080       self-signed certificates are accepted
set -eu
[ $# -ge 1 ] || { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
out=$1
url=$(printf '%s' "${2:-http://localhost:8080}" | sed 's#//localhost#//host.docker.internal#; s#//127\.0\.0\.1#//host.docker.internal#')
[ -n "${CONSOLE_USER:-}${HL7EDGE_ADMIN_TOKEN:-}" ] || { echo "set HL7EDGE_ADMIN_TOKEN, or CONSOLE_USER and CONSOLE_PASSWORD" >&2; exit 2; }
mkdir -p "$(dirname "$out")"
export MSYS_NO_PATHCONV=1
dir=$(cd "$(dirname "$out")" && { pwd -W 2>/dev/null || pwd; })
docker run --rm -i --add-host host.docker.internal:host-gateway -v "$dir:/out" \
  -e URL="$url" -e NAME="$(basename "$out")" -e HL7EDGE_ADMIN_TOKEN -e CONSOLE_USER -e CONSOLE_PASSWORD \
  mcr.microsoft.com/playwright/python:v1.47.0-jammy \
  sh -c 'pip install -q --disable-pip-version-check --root-user-action=ignore playwright==1.47.0 && python -' <<'EOF'
import os

from playwright.sync_api import sync_playwright

url = os.environ["URL"].rstrip("/")
with sync_playwright() as p:
    browser = p.chromium.launch()
    ctx = browser.new_context(viewport={"width": 1600, "height": 900}, device_scale_factor=2, ignore_https_errors=True)
    page = ctx.new_page()
    page.on("pageerror", lambda e: print("page error:", e))
    if os.environ.get("CONSOLE_USER"):
        r = ctx.request.post(f"{url}/auth/login", headers={"X-Requested-With": "screenshot"},
                             data={"name": os.environ["CONSOLE_USER"], "password": os.environ.get("CONSOLE_PASSWORD", "")})
        if not r.ok:
            raise SystemExit(f"sign-in failed: HTTP {r.status}")
    page.goto(f"{url}/")
    token = "" if os.environ.get("CONSOLE_USER") else os.environ.get("HL7EDGE_ADMIN_TOKEN", "")
    page.evaluate("t => { if (t) sessionStorage.setItem('hl7edge-token', t); localStorage.setItem('hl7edge-theme', 'light') }", token)
    page.reload()
    page.wait_for_timeout(2500)
    page.locator("body").screenshot(path=f"/out/{os.environ['NAME']}")
    browser.close()
print("wrote", os.environ["NAME"])
EOF
