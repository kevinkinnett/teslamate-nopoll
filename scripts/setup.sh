#!/usr/bin/env bash
# teslamate-nopoll — guided setup.
#
# Walks you through the whole thing end to end: configuration, certificates, the
# Tesla-side registration, and bringing the stack up. Every step detects whether
# it is already done and offers to skip, so you can quit any time (Ctrl-C) and
# re-run without starting over.
#
#   ./scripts/setup.sh
set -u
cd "$(dirname "$0")/.."

# ----------------------------------------------------------------- presentation
if [ -t 1 ]; then
  B=$'\e[1m'; DIM=$'\e[2m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; C=$'\e[36m'; N=$'\e[0m'
else B= DIM= G= Y= R= C= N=; fi
ok()   { echo "  ${G}✓${N} $*"; }
warn() { echo "  ${Y}!${N} $*"; }
die()  { echo "  ${R}✗ $*${N}"; exit 1; }
info() { echo "  $*"; }
sec()  { echo; echo "${B}${C}━━ $* ━━${N}"; }
EXPLAIN=1
explain() { [ "$EXPLAIN" = 1 ] && echo "    ${DIM}$*${N}"; return 0; }
pause()   { read -rp "  ${DIM}Press Enter to continue…${N} " _ || true; }
confirm() { local a; read -rp "  $* [y/N] " a || true; [[ "${a:-}" =~ ^[Yy] ]]; }

# --------------------------------------------------------------------- env I/O
ENV_FILE=.env
get_env() { [ -f "$ENV_FILE" ] && grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- || true; }
set_env() {
  python3 - "$ENV_FILE" "$1" "$2" <<'PY'
import sys
f, k, v = sys.argv[1], sys.argv[2], sys.argv[3]
try:    lines = open(f).read().splitlines()
except FileNotFoundError: lines = []
out, done = [], False
for l in lines:
    if l.split("=", 1)[0] == k: out.append(f"{k}={v}"); done = True
    else: out.append(l)
if not done: out.append(f"{k}={v}")
open(f, "w").write("\n".join(out) + "\n")
PY
}
ask() {  # ask VAR "prompt" ["default"]
  local var=$1 prompt=$2 def=${3:-} cur input
  cur=$(get_env "$var"); [ -n "$cur" ] && def=$cur
  read -rp "  $prompt${def:+ [$def]}: " input || true
  input=${input:-$def}
  set_env "$var" "$input"
}
ask_secret() {  # ask_secret VAR "prompt"
  local var=$1 prompt=$2 cur input
  cur=$(get_env "$var")
  if [ -n "$cur" ]; then confirm "$prompt is already set — keep it?" && return 0; fi
  read -rsp "  $prompt: " input || true; echo
  set_env "$var" "$input"
}
compose() { docker compose "$@"; }

# ------------------------------------------------------------------- 0. intro
preflight() {
  sec "Prerequisites"
  local miss=0 t
  for t in docker openssl python3 curl; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else warn "$t not found"; miss=1; fi
  done
  if compose version >/dev/null 2>&1; then ok "docker compose"; else warn "docker compose plugin not found"; miss=1; fi
  [ "$miss" = 0 ] || die "Install the missing tools above, then re-run."
}

intro() {
  echo "${B}teslamate-nopoll — guided setup${N}"
  echo "${DIM}Config → certs → Tesla registration → start the stack. Quit any time and re-run.${N}"
  if confirm "Show a detailed explanation at each step?"; then EXPLAIN=1; else EXPLAIN=0; fi
  [ -f "$ENV_FILE" ] || { cp .env.example "$ENV_FILE"; ok "created .env from template"; }
}

# ------------------------------------------------------------------- 1. config
gather() {
  sec "Configuration"
  explain "Everything is saved to .env (git-ignored). Blank answers keep existing values."

  echo; info "${B}Your vehicle${N}"
  ask VIN "VIN (17 chars — door jamb or Tesla app)"
  ask DISPLAY_NAME "Display name" "Tesla"

  echo; info "${B}Tesla account region${N}"
  echo "    1) North America / Asia-Pacific    2) Europe / Middle East    3) China"
  local r; read -rp "  choice [1]: " r || true
  case "${r:-1}" in
    2) set_env TESLA_API_BASE "https://fleet-api.prd.eu.vn.cloud.tesla.com" ;;
    3) set_env TESLA_API_BASE "https://fleet-api.prd.cn.vn.cloud.tesla.cn" ;;
    *) set_env TESLA_API_BASE "https://fleet-api.prd.na.vn.cloud.tesla.com" ;;
  esac
  ok "API base: $(get_env TESLA_API_BASE)"

  echo; info "${B}Public hostname${N}"
  explain "A domain that resolves to your public IP (dynamic DNS is fine). The car"
  explain "streams here, and Tesla fetches your public key here over HTTPS."
  ask DOMAIN "Public hostname (e.g. tesla.example.com)"
  ask LE_EMAIL "Email for Let's Encrypt renewal notices"

  echo; info "${B}Tesla developer app${N}  ${DIM}(https://developer.tesla.com)${N}"
  explain "Create a Fleet API app. Set its Allowed Redirect URI to"
  explain "http://localhost:3000/callback. You'll add the Allowed Origin a bit later,"
  explain "once your key endpoint is live (Tesla checks it as you type it in)."
  ask TESLA_CLIENT_ID "Client ID"
  ask_secret TESLA_CLIENT_SECRET "Client secret"
  ok "Configuration saved to .env"
}

# ------------------------------------------------------------------- 2. ports
ports() {
  sec "Port forwarding"
  local tp; tp=$(get_env TELEMETRY_PORT); tp=${tp:-4443}
  explain "The car connects TO you, so these must reach THIS machine from the internet:"
  info "  ${B}80${N}    → this host   ${DIM}(Let's Encrypt issuance & renewal)${N}"
  info "  ${B}443${N}   → this host   ${DIM}(serves your public key to Tesla)${N}"
  info "  ${B}${tp}${N}  → this host   ${DIM}(the car's telemetry stream)${N}"
  explain "Some routers reserve 443. On AT&T gateways the built-in 'ssl' preset fails"
  explain "silently — create a CUSTOM NAT/Gaming service for TCP 443 instead."
  echo
  if ! confirm "Have you forwarded these ports to this machine?"; then
    warn "Set that up in your router. The validation step will confirm 443 for you."
    confirm "Continue for now?" || exit 0
  fi
}

# ------------------------------------------------------------------- 3. certs
gen_certs() {
  sec "Keys & certificates"
  if [ -f proxy/private-key.pem ] && [ -f certs/vehicle_device.CA.cert ]; then
    ok "keys/certs already present"
    confirm "Regenerate them all from scratch?" || return 0
    rm -rf certs proxy wellknown/srv/.well-known/appspecific/*.pem 2>/dev/null || true
  fi
  explain "Generating your app key pair, the self-signed telemetry CA + server cert,"
  explain "and the proxy's local TLS cert."
  ./scripts/gen-certs.sh && ok "generated" || die "cert generation failed"
}

# ---------------------------------------------------------------- 4. serve key
serve_key() {
  sec "Publish your public key (Let's Encrypt)"
  local dom; dom=$(get_env DOMAIN)
  explain "Starting the wellknown service. It obtains a Let's Encrypt cert for ${dom}"
  explain "and serves your public key at the path Tesla verifies."
  DOMAIN="$dom" LE_EMAIL="$(get_env LE_EMAIL)" compose up -d wellknown >/dev/null 2>&1 \
    || { compose logs --tail 20 wellknown; die "failed to start wellknown"; }
  ok "wellknown started"

  local path="/.well-known/appspecific/com.tesla.3p.public-key.pem"
  info "Validating ${dom}${path}"
  explain "First issuance needs a minute. Persistent failure is almost always port 443"
  explain "not reaching this host — see the router notes above."
  while true; do
    local code issuer
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 12 \
           --resolve "${dom}:443:127.0.0.1" "https://${dom}${path}" 2>/dev/null || echo 000)
    issuer=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$dom" 2>/dev/null \
             | openssl x509 -noout -issuer 2>/dev/null || true)
    if [ "$code" = "200" ] && echo "$issuer" | grep -qi "let's encrypt"; then
      ok "public key is live with a valid Let's Encrypt cert — Tesla can fetch it"
      return 0
    elif [ "$code" = "200" ]; then
      warn "served locally, but the cert isn't from Let's Encrypt yet"
      explain "ACME hasn't completed — Let's Encrypt couldn't reach ports 80/443 from"
      explain "the internet. Re-check forwarding (and 443 reservation), then retry."
    else
      warn "not serving yet (HTTP ${code})"
    fi
    echo "    ${DIM}[r] retry   [l] logs   [s] skip   [q] quit${N}"
    local c; read -rp "    choice [r]: " c || true
    case "${c:-r}" in
      l) compose logs --tail 25 wellknown ;;
      s) warn "skipping — Tesla registration will fail until this returns 200"; return 0 ;;
      q) exit 0 ;;
      *) sleep 4 ;;
    esac
  done
}

# --------------------------------------------------------- 5. allowed origin
allowed_origin() {
  sec "Add the Allowed Origin (Tesla portal)"
  local dom; dom=$(get_env DOMAIN)
  explain "Tesla validates this by fetching the key you just published, so it only"
  explain "succeeds now that the endpoint returns 200."
  info "1. https://developer.tesla.com → your app → Credentials & APIs → ${B}Edit${N}"
  info "2. Under ${B}Allowed Origin(s)${N} add:  ${B}https://${dom}${N}"
  info "3. Save."
  pause
}

# ------------------------------------------------------------- 6. pair key
pair_key() {
  sec "Pair your app's virtual key to the car"
  local dom; dom=$(get_env DOMAIN)
  explain "Authorises your app to configure the vehicle. Do this on your phone, which"
  explain "must have the Tesla app installed."
  info "Open on your phone:  ${B}https://tesla.com/_ak/${dom}${N}"
  info "Tap through to add the virtual key to your car."
  pause
}

# --------------------------------------------------------------- 7. oauth
oauth() {
  sec "Sign in (user token)"
  if [ -f secrets/.refresh_token ]; then
    confirm "A saved token already exists — reuse it?" && { ok "keeping existing token"; return 0; }
  fi
  ./scripts/get-token.sh url
  echo
  local cb
  read -rp "  Paste the localhost:3000 callback URL: " cb || true
  if [ -n "$cb" ] && ./scripts/get-token.sh "$cb"; then
    ok "token obtained"
  else
    warn "token exchange failed — codes expire in ~60s, so be quick."
    confirm "Try again?" && oauth || die "cannot continue without a token"
  fi
}

# ------------------------------------------------------ 8. register domain
register_domain() {
  sec "Register the partner domain"
  while true; do
    if ./scripts/register-domain.sh; then ok "domain registered"; return 0; fi
    warn "registration failed (see the message above)"
    explain "Most common causes: the Allowed Origin isn't saved yet, or the key"
    explain "endpoint isn't returning 200."
    echo "    ${DIM}[r] retry   [o] redo the Allowed Origin step   [q] quit${N}"
    local c; read -rp "    choice [r]: " c || true
    case "${c:-r}" in o) allowed_origin ;; q) exit 0 ;; *) : ;; esac
  done
}

# --------------------------------------------------- 9. register telemetry
register_telemetry() {
  sec "Configure the car to stream"
  explain "Starting the signing proxy, then telling the car to stream to your server."
  compose --profile setup up -d vehicle-command >/dev/null 2>&1 \
    && ok "signing proxy up" || warn "proxy may not have started (check: docker compose --profile setup logs vehicle-command)"
  sleep 4
  while true; do
    if ./scripts/register-telemetry.sh; then ok "telemetry configured"; break; fi
    warn "registration failed"
    explain "If it says the car is unreachable, wake it (open the Tesla app) and retry."
    echo "    ${DIM}[r] retry   [q] quit${N}"
    local c; read -rp "    choice [r]: " c || true
    case "${c:-r}" in q) exit 0 ;; *) : ;; esac
  done
  compose --profile setup stop vehicle-command >/dev/null 2>&1 || true
}

# ------------------------------------------------------------- 10. bring up
bring_up() {
  sec "Start the stack"
  compose up -d fleet-telemetry shim >/dev/null 2>&1 \
    && ok "fleet-telemetry + shim running" || { compose logs --tail 20; die "startup failed"; }
}

finish() {
  local sp wp; sp=$(get_env SHIM_PORT); sp=${sp:-8099}; wp=$(get_env WSS_PORT); wp=${wp:-8443}
  sec "Point TeslaMate at nopoll"
  info "In TeslaMate's environment, set:"
  echo "    ${B}TESLA_API_HOST=http://<this-host>:${sp}${N}"
  echo "    ${B}TESLA_WSS_HOST=wss://<this-host>:${wp}${N}"
  echo "    ${B}TESLA_WSS_TLS_ACCEPT_INVALID_CERTS=true${N}"
  echo "    ${B}TESLA_WSS_USE_VIN=true${N}"
  explain "Leave TESLA_AUTH_HOST at Tesla's real value — auth is free and must stay real."
  explain "Recreate TeslaMate (docker compose up -d, NOT restart) so it re-reads these."
  echo
  ok "Setup complete. The shim should report the car online within a minute or two."
  info "Check:  ${DIM}curl -s http://127.0.0.1:${sp}/debug | python3 -m json.tool${N}"
  echo
  info "${DIM}Tip: scripts/register-telemetry.sh must be re-run if you ever hit your${N}"
  info "${DIM}billing limit — Tesla deletes the telemetry config when that happens.${N}"
}

main() {
  clear 2>/dev/null || true
  intro
  preflight
  gather
  ports
  gen_certs
  serve_key
  allowed_origin
  pair_key
  oauth
  register_domain
  register_telemetry
  bring_up
  finish
}
main "$@"
