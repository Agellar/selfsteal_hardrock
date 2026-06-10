#!/usr/bin/env bash
# Iron Wave Radio — selfsteal deploy for Ubuntu + Caddy (behind xray Reality)
# Usage on the server:
#     git clone https://github.com/Agellar/selfsteal_hardrock.git
#     cd selfsteal_hardrock
#     sudo bash deploy/deploy.sh
#
# Re-run anytime to update (after `git pull`).
set -euo pipefail

DOMAIN="hardrock.legendaryfm.uk"
WEBROOT="/var/www/hardrock"
CADDYFILE="/etc/caddy/Caddyfile"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ "$(id -u)" -ne 0 ]; then
	echo "!! Run as root:  sudo bash deploy/deploy.sh" >&2
	exit 1
fi

command -v caddy >/dev/null || { echo "!! Caddy not found in PATH." >&2; exit 1; }

echo ">>> [1/5] Syncing site files -> $WEBROOT"
mkdir -p "$WEBROOT" /var/log/caddy
if command -v rsync >/dev/null; then
	rsync -a --delete \
		--exclude='.git' --exclude='deploy' --exclude='README.md' \
		"$REPO_ROOT"/ "$WEBROOT"/
else
	cp -rf "$REPO_ROOT"/index.html "$REPO_ROOT"/about.html "$REPO_ROOT"/artists.html \
		"$REPO_ROOT"/guide.html "$REPO_ROOT"/history.html "$REPO_ROOT"/subgenres.html \
		"$REPO_ROOT"/robots.txt "$REPO_ROOT"/sitemap.xml "$REPO_ROOT"/assets "$WEBROOT"/
fi

if id caddy >/dev/null 2>&1; then
	chown -R caddy:caddy "$WEBROOT" /var/log/caddy
fi

echo ">>> [2/5] Installing Caddyfile -> $CADDYFILE"
if [ -f "$CADDYFILE" ] && ! cmp -s "$SCRIPT_DIR/Caddyfile" "$CADDYFILE"; then
	bak="$CADDYFILE.bak.$(date +%Y%m%d-%H%M%S)"
	cp "$CADDYFILE" "$bak"
	echo "    (existing Caddyfile backed up to $bak)"
	echo "    NOTE: if you run other sites in Caddy, merge the site block instead."
fi
cp "$SCRIPT_DIR/Caddyfile" "$CADDYFILE"

echo ">>> [3/5] Checking port 80 reachability for ACME (HTTP-01)"
if command -v ss >/dev/null && ss -ltnH 'sport = :80' | grep -q .; then
	echo "    Port 80 is already in use by another process — free it or use DNS-01."
fi
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
	ufw allow 80/tcp >/dev/null 2>&1 || true
	echo "    ufw: allowed 80/tcp"
fi

echo ">>> [4/5] Validating Caddy config"
caddy validate --adapter caddyfile --config "$CADDYFILE"

echo ">>> [5/5] Reloading Caddy"
systemctl reload caddy 2>/dev/null || systemctl restart caddy

echo
echo "================ DONE ================"
echo "Verify locally (should print <!DOCTYPE html>):"
echo "    curl -sk --resolve $DOMAIN:9443:127.0.0.1 https://$DOMAIN:9443/ | head -n1"
echo
echo "Verify the certificate is the real Let's Encrypt one (not self-signed):"
echo "    echo | openssl s_client -connect 127.0.0.1:9443 -servername $DOMAIN 2>/dev/null | openssl x509 -noout -issuer -subject"
echo
echo "Then open in a browser:  https://$DOMAIN"
echo "If the cert is still self-signed, ensure TCP/80 is open to the internet"
echo "and run:  sudo systemctl restart caddy  (watch: journalctl -u caddy -f)"
