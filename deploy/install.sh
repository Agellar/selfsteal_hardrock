#!/usr/bin/env bash
# ============================================================================
# Iron Wave Radio — selfsteal one-click installer
# ----------------------------------------------------------------------------
# Sets up the decoy website for an xray Reality "selfsteal" node, on a server
# that ALREADY has remnanode installed.
#
# What it does (interactively, in one run):
#   1. Installs Caddy as a Docker container (matches the remnanode stack).
#   2. Opens TCP/80 (needed for the Let's Encrypt HTTP-01 challenge).
#   3. Obtains a REAL Let's Encrypt certificate for your domain.
#   4. Serves the static site over real TLS on 127.0.0.1:<port> (default 9443),
#      which xray Reality on :443 uses as its target/dest.
#   5. Deploys this repository's site template and hardens the web server
#      (no SPA catch-all, styled 404, cache + security headers, zstd).
#
# Usage on the server:
#       git clone https://github.com/Agellar/selfsteal_hardrock.git
#       cd selfsteal_hardrock
#       sudo bash deploy/install.sh
#
# Re-run anytime: it is idempotent (updates config + site, re-issues nothing
# unless the domain changed).
#
# Non-interactive / automation:
#       sudo DOMAIN=example.com SELF_STEAL_PORT=9443 ACME_EMAIL=you@example.com \
#            bash deploy/install.sh --yes
#       sudo bash deploy/install.sh --sync-only      # only re-deploy site files
#       sudo bash deploy/install.sh --dry-run        # generate+validate, change nothing
# ============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CADDY_DIR="/opt/caddy"
WEBROOT="${CADDY_DIR}/html"
CADDY_IMAGE="caddy:2.11.4"
CONTAINER="caddy-selfsteal"
DEFAULT_PORT="9443"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Flags / env defaults
# ---------------------------------------------------------------------------
ASSUME_YES=0
DRY_RUN=0
SYNC_ONLY=0
DOMAIN="${DOMAIN:-}"
PORT="${SELF_STEAL_PORT:-}"
EMAIL="${ACME_EMAIL:-}"

while [ $# -gt 0 ]; do
	case "$1" in
		-y|--yes)        ASSUME_YES=1 ;;
		--dry-run)       DRY_RUN=1 ;;
		--sync-only)     SYNC_ONLY=1 ;;
		--domain)        DOMAIN="${2:-}"; shift ;;
		--domain=*)      DOMAIN="${1#*=}" ;;
		--port)          PORT="${2:-}"; shift ;;
		--port=*)        PORT="${1#*=}" ;;
		--email)         EMAIL="${2:-}"; shift ;;
		--email=*)       EMAIL="${1#*=}" ;;
		-h|--help)
			sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*) echo "Unknown option: $1" >&2; exit 2 ;;
	esac
	shift
done

# ---------------------------------------------------------------------------
# Pretty output
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
	B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; C=$'\033[36m'; N=$'\033[0m'
else
	B=""; G=""; Y=""; R=""; C=""; N=""
fi
info() { printf '%s>>>%s %s\n' "$C" "$N" "$*"; }
ok()   { printf '%s ok %s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s !! %s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%s!!!%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# Read from the real terminal so prompts work under `curl ... | bash` too.
ask() { # ask <prompt> <default> -> echoes answer
	local prompt="$1" def="${2:-}" ans=""
	if [ "$ASSUME_YES" = "1" ] || [ ! -t 0 -a ! -r /dev/tty ]; then
		echo "$def"; return 0
	fi
	if [ -n "$def" ]; then prompt="$prompt ${B}[$def]${N}"; fi
	read -r -p "$(printf '%s: ' "$prompt")" ans < /dev/tty || true
	echo "${ans:-$def}"
}
confirm() { # confirm <prompt> -> 0/1
	[ "$ASSUME_YES" = "1" ] && return 0
	local a; a="$(ask "$1 (y/N)" "")"
	case "$a" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "Run as root:  sudo bash deploy/install.sh"
command -v docker >/dev/null || die "Docker not found. Install Docker first (remnanode needs it too)."

DC=""
if docker compose version >/dev/null 2>&1; then DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then DC="docker-compose"
else die "Docker Compose not found (need the 'docker compose' plugin or docker-compose)."; fi

# ---------------------------------------------------------------------------
# --sync-only : just refresh the site files and exit (used by CI auto-deploy)
# ---------------------------------------------------------------------------
deploy_site() {
	info "Deploying site files -> ${WEBROOT}"
	mkdir -p "${WEBROOT}"
	if command -v rsync >/dev/null; then
		rsync -a --delete \
			--exclude='.git' --exclude='.github' --exclude='deploy' --exclude='README.md' \
			"${REPO_ROOT}/" "${WEBROOT}/"
	else
		cp -rf "${REPO_ROOT}/"*.html "${REPO_ROOT}/robots.txt" "${REPO_ROOT}/sitemap.xml" \
			"${REPO_ROOT}/favicon.ico" "${REPO_ROOT}/assets" "${WEBROOT}/"
	fi
	id www-data >/dev/null 2>&1 && chown -R www-data:www-data "${WEBROOT}" || true
	ok "Site files in place ($(find "${WEBROOT}" -type f | wc -l) files)"
}

if [ "$SYNC_ONLY" = "1" ]; then
	[ -d "${CADDY_DIR}" ] || die "--sync-only: ${CADDY_DIR} not found. Run a full install first."
	deploy_site
	ok "Site updated. (static files are served live from the volume — no reload needed)"
	exit 0
fi

# ---------------------------------------------------------------------------
# Detect remnanode + public IP
# ---------------------------------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx 'remnanode'; then
	ok "remnanode container detected (xray Reality will target this decoy)."
else
	warn "remnanode container not found. This installer only sets up the decoy site;"
	warn "make sure remnanode is installed and its Reality inbound targets 127.0.0.1:<port>."
fi

PUBLIC_IP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[ -z "$PUBLIC_IP" ] && PUBLIC_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

# ---------------------------------------------------------------------------
# Gather configuration (reuse existing .env as defaults if present)
# ---------------------------------------------------------------------------
if [ -f "${CADDY_DIR}/.env" ]; then
	# shellcheck disable=SC1090
	. "${CADDY_DIR}/.env" 2>/dev/null || true
	[ -z "$DOMAIN" ] && DOMAIN="${SELF_STEAL_DOMAIN:-}"
	[ -z "$PORT" ]   && PORT="${SELF_STEAL_PORT:-}"
fi

echo
info "${B}Selfsteal decoy — configuration${N}"
[ -n "$PUBLIC_IP" ] && echo "    This server's public IP looks like: ${B}${PUBLIC_IP}${N}"
echo "    The domain's DNS A/AAAA record must already point here."
echo

DOMAIN="$(ask 'Domain (serverName used by Reality)' "$DOMAIN")"
[ -n "$DOMAIN" ] || die "Domain is required."
PORT="$(ask 'Selfsteal HTTPS port (loopback, used as Reality target)' "${PORT:-$DEFAULT_PORT}")"
EMAIL="$(ask 'Email for Let'\''s Encrypt (optional, for expiry notices)' "$EMAIL")"

# DNS sanity check (best-effort, non-fatal)
RESOLVED="$(getent ahosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
if [ -n "$PUBLIC_IP" ] && [ -n "$RESOLVED" ]; then
	if echo "$RESOLVED" | grep -qw "$PUBLIC_IP"; then
		ok "DNS: ${DOMAIN} resolves to this server (${PUBLIC_IP})."
	else
		warn "DNS: ${DOMAIN} resolves to [${RESOLVED}], not this server (${PUBLIC_IP})."
		warn "Let's Encrypt will FAIL until the A record points here."
		confirm "Continue anyway?" || die "Aborted. Fix DNS and re-run."
	fi
fi

echo
echo "    ${B}Domain:${N} ${DOMAIN}"
echo "    ${B}Port:  ${N} 127.0.0.1:${PORT}  (xray Reality target/dest)"
echo "    ${B}Email: ${N} ${EMAIL:-<none>}"
echo "    ${B}Webroot:${N} ${WEBROOT}"
echo
confirm "Proceed with installation?" || die "Aborted by user."

# ---------------------------------------------------------------------------
# Render config files (to a staging dir; copied into place unless --dry-run)
# ---------------------------------------------------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cat > "${STAGE}/.env" <<EOF
# Caddy selfsteal configuration — generated by deploy/install.sh
SELF_STEAL_DOMAIN=${DOMAIN}
SELF_STEAL_PORT=${PORT}
# Generated on $(date -u) for server ${PUBLIC_IP:-unknown}
EOF

cat > "${STAGE}/docker-compose.yml" <<EOF
services:
  caddy:
    image: ${CADDY_IMAGE}
    container_name: ${CONTAINER}
    restart: unless-stopped
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - ${WEBROOT}:/var/www/html
      - ./logs:/var/log/caddy
      - caddy_data:/data
      - caddy_config:/config
    env_file:
      - .env
    network_mode: "host"
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  caddy_data:
  caddy_config:
EOF

# Global block — add the ACME email line only if provided.
EMAIL_LINE=""
[ -n "$EMAIL" ] && EMAIL_LINE=$'\n\temail '"${EMAIL}"

cat > "${STAGE}/Caddyfile" <<EOF
{
	https_port {\$SELF_STEAL_PORT}
	default_bind 127.0.0.1${EMAIL_LINE}
	servers {
		protocols h1 h2
		listener_wrappers {
			proxy_protocol {
				allow 127.0.0.1/32
			}
			tls
		}
	}
	auto_https disable_redirects
	# Admin API off: it isn't used (managed via docker compose) and its default
	# localhost bind boot-loops under network_mode: host without a 127.0.0.1 entry.
	admin off
	log {
		output file /var/log/caddy/access.log {
			roll_size 10MB
			roll_keep 5
			roll_keep_for 720h
		}
		level ERROR
		format json
	}
}

# Port 80: serves the Let's Encrypt HTTP-01 challenge (auto) and redirects real
# visitors to HTTPS. Must be reachable from the internet for cert issuance.
http://{\$SELF_STEAL_DOMAIN} {
	bind 0.0.0.0
	redir https://{\$SELF_STEAL_DOMAIN}{uri} permanent
	log {
		output file /var/log/caddy/redirect.log {
			roll_size 5MB
			roll_keep 3
			roll_keep_for 168h
		}
	}
}

# The real-TLS decoy. Bound to loopback; xray Reality on :443 forwards
# probe/fallback traffic here (with PROXY protocol) so it sees a genuine site
# with a valid Let's Encrypt certificate.
https://{\$SELF_STEAL_DOMAIN} {
	# Compression + headers to mirror a modern, well-configured real site.
	encode zstd gzip
	root * /var/www/html

	header {
		-Server
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		X-XSS-Protection "1; mode=block"
		Referrer-Policy "strict-origin-when-cross-origin"
		Permissions-Policy "geolocation=(), microphone=(), camera=()"
		Strict-Transport-Security "max-age=31536000"
	}

	# Cache like a real site: fingerprinted assets long-lived, HTML short.
	@assets path /assets/*
	header @assets Cache-Control "public, max-age=31536000, immutable"
	@html path *.html /
	header @html Cache-Control "public, max-age=600"

	file_server

	# Real multi-page static site, not a SPA: unknown paths must return a styled
	# 404 and never echo the homepage (that catch-all is a selfsteal fingerprint).
	handle_errors {
		@404 expression {err.status_code} == 404
		handle @404 {
			rewrite * /404.html
			file_server
		}
	}

	log {
		output file /var/log/caddy/access.log {
			roll_size 10MB
			roll_keep 5
			roll_keep_for 720h
		}
		level ERROR
	}
}

# Dummy responders so direct hits to the loopback port / bare :80 reveal nothing.
:{\$SELF_STEAL_PORT} {
	tls internal
	respond 204
	log off
}

:80 {
	bind 0.0.0.0
	respond 204
	log off
}
EOF

# ---------------------------------------------------------------------------
# Validate the rendered Caddyfile (throwaway container, no side effects)
# ---------------------------------------------------------------------------
info "Validating generated Caddyfile"
VAL_LOGS="$(mktemp -d)"
if docker run --rm \
	-e SELF_STEAL_DOMAIN="$DOMAIN" -e SELF_STEAL_PORT="$PORT" \
	-v "${STAGE}/Caddyfile:/etc/caddy/Caddyfile:ro" \
	-v "${VAL_LOGS}:/var/log/caddy" \
	"$CADDY_IMAGE" caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile >/dev/null 2>"${VAL_LOGS}/err"; then
	ok "Caddyfile is valid."
else
	cat "${VAL_LOGS}/err" >&2 || true
	rm -rf "$VAL_LOGS"
	die "Generated Caddyfile failed validation (see above)."
fi
rm -rf "$VAL_LOGS"

if [ "$DRY_RUN" = "1" ]; then
	echo
	info "${B}--dry-run:${N} generated files (NOT applied):"
	echo "    ${STAGE}/.env"
	echo "    ${STAGE}/docker-compose.yml"
	echo "    ${STAGE}/Caddyfile"
	cp "${STAGE}/.env" "${STAGE}/docker-compose.yml" "${STAGE}/Caddyfile" /tmp/ 2>/dev/null || true
	echo "    (also copied to /tmp/ for inspection)"
	trap - EXIT
	exit 0
fi

# ---------------------------------------------------------------------------
# Open port 80 (ACME). 443 belongs to xray — never touched. 9443 is loopback.
# ---------------------------------------------------------------------------
info "Ensuring TCP/80 is open for the ACME challenge"
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
	ufw allow 80/tcp >/dev/null 2>&1 && ok "ufw: allowed 80/tcp" || warn "ufw: could not add rule"
fi
if command -v ss >/dev/null && ss -ltnH 'sport = :80' 2>/dev/null | grep -qv "$CONTAINER"; then
	if ss -ltnpH 'sport = :80' 2>/dev/null | grep -q .; then
		warn "Something is already listening on :80 — free it or ACME (HTTP-01) will fail."
	fi
fi
warn "If this is a cloud VM, also open TCP/80 in the provider's security group/firewall."

# ---------------------------------------------------------------------------
# Write config into place + deploy site + launch
# ---------------------------------------------------------------------------
info "Installing config into ${CADDY_DIR}"
mkdir -p "${CADDY_DIR}/logs" "${WEBROOT}"
for f in .env docker-compose.yml Caddyfile; do
	if [ -f "${CADDY_DIR}/${f}" ] && ! cmp -s "${STAGE}/${f}" "${CADDY_DIR}/${f}"; then
		cp -a "${CADDY_DIR}/${f}" "${CADDY_DIR}/${f}.bak.$(date +%Y%m%d-%H%M%S)"
	fi
	cp "${STAGE}/${f}" "${CADDY_DIR}/${f}"
done
ok "Config written (existing files backed up if changed)."

deploy_site

info "Starting Caddy (${DC} up -d)"
( cd "${CADDY_DIR}" && $DC pull >/dev/null 2>&1 || true; cd "${CADDY_DIR}" && $DC up -d )

# ---------------------------------------------------------------------------
# Wait for container + real certificate
# ---------------------------------------------------------------------------
info "Waiting for the container to come up"
for _ in $(seq 1 15); do
	[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = "running" ] && break
	sleep 1
done
[ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = "running" ] \
	|| die "Container is not running. Check: docker logs ${CONTAINER}"
ok "Container is running."

info "Waiting for the Let's Encrypt certificate (HTTP-01 on :80, up to ~90s)"
ISSUER=""
for _ in $(seq 1 30); do
	ISSUER="$(echo | timeout 5 openssl s_client -connect "127.0.0.1:${PORT}" -servername "$DOMAIN" 2>/dev/null \
		| openssl x509 -noout -issuer 2>/dev/null || true)"
	echo "$ISSUER" | grep -qi "Let's Encrypt" && break
	sleep 3
done

echo
if echo "$ISSUER" | grep -qi "Let's Encrypt"; then
	ok "Real certificate issued: ${ISSUER#issuer=}"
else
	warn "No Let's Encrypt cert yet (${ISSUER:-none})."
	warn "Most common cause: TCP/80 not reachable from the internet (cloud firewall)."
	warn "Watch issuance with:  docker logs -f ${CONTAINER}"
fi

# ---------------------------------------------------------------------------
# Verify serving
# ---------------------------------------------------------------------------
info "Verifying the site"
HOME_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" || true)"
NF_CODE="$(curl -sk -o /dev/null -w '%{http_code}' --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/nope-12345" || true)"
echo "    GET /          -> HTTP ${HOME_CODE} (expect 200)"
echo "    GET /nope-12345 -> HTTP ${NF_CODE} (expect 404)"

echo
echo "${G}================ DONE ================${N}"
echo "Decoy site:   https://${DOMAIN}/   (served on 127.0.0.1:${PORT})"
echo
echo "${B}In the remnawave panel${N}, the Reality inbound for this node must use:"
echo "    serverNames / SNI : ${DOMAIN}"
echo "    dest / target     : 127.0.0.1:${PORT}"
echo "    (and PROXY protocol enabled toward the target)"
echo
echo "Verify the certificate is the real Let's Encrypt one:"
echo "    echo | openssl s_client -connect 127.0.0.1:${PORT} -servername ${DOMAIN} 2>/dev/null | openssl x509 -noout -issuer"
echo "Update the site later:   sudo bash deploy/install.sh --sync-only"
trap - EXIT
