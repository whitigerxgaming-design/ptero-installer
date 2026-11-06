#!/usr/bin/env bash
# ============================================================
#  Ptero Installer v2
#  Usage:  sudo ./install.sh
#  Wraps the official pterodactyl-installer in unattended mode
#  Domain options: own domain | Cloudflare quick tunnel | sslip.io
# ============================================================
set -u

BASE="https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer/master"
CRED_FILE="/root/pterodactyl-credentials.txt"
PANEL_DIR="/var/www/pterodactyl"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
info()  { echo -e "${C}[i]${N} $*"; }
ok()    { echo -e "${G}[✓]${N} $*"; }
warn()  { echo -e "${Y}[!]${N} $*"; }
die()   { echo -e "${R}[x]${N} $*"; exit 1; }

# ---- defaults (avoid unset-variable errors) ----
MODE=""; MODE_NAME=""; VIRT="unknown"; SERVER_IP=""; IS_NAT=false
DOMAIN_MODE=""; PANEL_FQDN=""; NODE_FQDN=""; PANEL_URL=""
USE_SSL=false; ASSUME_SSL=false
ADMIN_EMAIL=""; ADMIN_USER=""; ADMIN_FIRST=""; ADMIN_LAST=""; ADMIN_PASS=""
TZ_VAL="UTC"; DB_PASS=""; REPLY_VAL=""

ask() { # ask "Question" "default" -> $REPLY_VAL
  local p="$1" d="${2:-}" v
  if [[ -n "$d" ]]; then read -r -p "$p [$d]: " v; REPLY_VAL="${v:-$d}"
  else read -r -p "$p: " v; REPLY_VAL="$v"; fi
}
ask_required() { REPLY_VAL=""; while [[ -z "$REPLY_VAL" ]]; do ask "$1" "${2:-}"; done; }
gen_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-20}"; }
yesno() { local v; read -r -p "$1 [Y/n]: " v; [[ "${v:-y}" =~ ^[Yy] ]]; }

banner() {
  clear
  echo -e "${B}${C}"
  echo "  ╔═══════════════════════════════════════════╗"
  echo "  ║          Ptero Installer  v2              ║"
  echo "  ╚═══════════════════════════════════════════╝"
  echo -e "${N}"
}

# ---------------- Pre-flight checks ----------------
preflight() {
  [[ $EUID -eq 0 ]] || die "Run as root: sudo ./install.sh"
  . /etc/os-release 2>/dev/null || die "Cannot detect OS"
  case "$ID-$VERSION_ID" in
    ubuntu-22.04|ubuntu-24.04|debian-11|debian-12) ok "OS: $PRETTY_NAME" ;;
    *) warn "OS $PRETTY_NAME is not officially supported."; yesno "Continue anyway?" || exit 1 ;;
  esac
  VIRT="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  info "Virtualization: $VIRT | CPU: $(nproc) cores | RAM: $(free -h | awk '/Mem:/{print $2}')"

  info "Checking that apt works..."
  apt-get update -qq >/dev/null 2>&1 || die "apt-get update failed. Fix apt first (process limit? broken repo in /etc/apt/sources.list.d?)."
  apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 || die "Could not install curl."

  SERVER_IP="$(curl -4 -s --max-time 10 ifconfig.me || true)"
  [[ -n "$SERVER_IP" ]] || die "Could not detect public IP (no internet?)."
  ok "Public IP: $SERVER_IP"

  # NAT detection: if the public IP is not on any local interface, inbound ports are NOT directly reachable
  if ip -4 addr 2>/dev/null | grep -q "inet ${SERVER_IP}/"; then
    IS_NAT=false
  else
    IS_NAT=true
    warn "Your public IP is not on this machine (NAT / cloud network)."
    warn "Ports 80/443 will NOT work until your provider forwards or opens them."
    warn "Recommended: use the Cloudflare tunnel option (no port forwarding needed)."
  fi
}

wings_check() {
  if [[ "$VIRT" == "lxc" || "$VIRT" == "openvz" ]]; then
    warn "This VPS is '$VIRT'. Docker (needed by Wings) usually does NOT work here."
    yesno "Try installing Wings anyway?" || return 1
  fi
  return 0
}

# ---------------- Cloudflare quick tunnel helpers ----------------
install_cloudflared() {
  command -v cloudflared >/dev/null 2>&1 && return 0
  info "Installing cloudflared..."
  local arch; arch="$(dpkg --print-architecture)"
  curl -fsSL -o /tmp/cloudflared.deb \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}.deb" \
    || die "Could not download cloudflared."
  dpkg -i /tmp/cloudflared.deb >/dev/null 2>&1 || die "Could not install cloudflared."
  ok "cloudflared installed."
}

# start_tunnel NAME PORT  -> prints the random hostname (xxxx.trycloudflare.com)
start_tunnel() {
  local name="$1" port="$2" log="/var/log/ptero-tunnel-$1.log" url="" i
  cat > "/etc/systemd/system/ptero-tunnel-${name}.service" <<EOF
[Unit]
Description=Cloudflare quick tunnel (${name})
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --url http://localhost:${port}
Restart=always
RestartSec=5
StandardOutput=append:${log}
StandardError=append:${log}

[Install]
WantedBy=multi-user.target
EOF
  systemctl stop "ptero-tunnel-${name}" >/dev/null 2>&1
  : > "$log"
  systemctl daemon-reload
  systemctl enable "ptero-tunnel-${name}" >/dev/null 2>&1
  systemctl restart "ptero-tunnel-${name}"
  for i in $(seq 1 45); do
    url="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$log" | grep -v '^https://api\.' | head -1)"
    [[ -n "$url" ]] && break
    sleep 1
  done
  [[ -n "$url" ]] || die "Tunnel URL not found. See $log"
  echo "${url#https://}"
}

write_nginx_http_conf() {
  local sock; sock="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)"
  [[ -n "$sock" ]] || die "PHP-FPM socket not found."
  cat > /etc/nginx/sites-available/pterodactyl.conf <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/pterodactyl/public;
    index index.html index.htm index.php;
    charset utf-8;

    location / { try_files $uri $uri/ /index.php?$query_string; }
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    access_log off;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:__PHPSOCK__;
        fastcgi_index index.php;
        include /etc/nginx/fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht { deny all; }
}
EOF
  sed -i "s|__PHPSOCK__|${sock}|" /etc/nginx/sites-available/pterodactyl.conf
  ln -sf /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t >/dev/null 2>&1 || die "nginx config test failed (run: nginx -t)"
  systemctl reload nginx
}

apply_panel_url() { # apply_panel_url HOST  (https assumed)
  local host="$1"
  [[ -d "$PANEL_DIR" ]] || die "Panel not found in $PANEL_DIR"
  cd "$PANEL_DIR" || die "Cannot enter $PANEL_DIR"
  sed -i "s|^APP_URL=.*|APP_URL=https://${host}|" .env
  if grep -q '^TRUSTED_PROXIES' .env; then
    sed -i 's|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=*|' .env
  else
    echo 'TRUSTED_PROXIES=*' >> .env
  fi
  php artisan config:clear >/dev/null 2>&1
  php artisan cache:clear  >/dev/null 2>&1
  cd - >/dev/null || true
}

# Menu 4: add / refresh a Cloudflare tunnel for an already installed Panel
enable_tunnel_existing() {
  [[ -d "$PANEL_DIR" ]] || die "No Panel found at $PANEL_DIR. Install it first (menu 1 or 2)."
  install_cloudflared
  info "Switching nginx to plain HTTP (the tunnel provides HTTPS)..."
  write_nginx_http_conf
  info "Starting tunnel..."
  PANEL_FQDN="$(start_tunnel panel 80)"
  apply_panel_url "$PANEL_FQDN"
  ok "Panel is now at: https://${PANEL_FQDN}"
  echo
  warn "This URL changes whenever the VPS or tunnel restarts. Run this option (4) again to get the new one."
  [[ -f "$CRED_FILE" ]] && sed -i "s|^Panel URL .*|Panel URL : https://${PANEL_FQDN}|" "$CRED_FILE"
}

# ---------------- Domain selection ----------------
choose_domain() {
  echo
  echo "${B}Domain setup${N}"
  echo "  1) I have my own domain (Cloudflare or any provider)"
  echo "  2) Cloudflare tunnel: random free URL like xxxx.trycloudflare.com (no port forwarding needed)"
  echo "  3) sslip.io free domain (needs a real public IP with ports 80/443 open)"
  [[ "$IS_NAT" == true ]] && warn "NAT detected: options 1 and 3 will probably fail. Option 2 is recommended."
  local c; read -r -p "Choose [1-3]: " c
  case "$c" in
    1)
      DOMAIN_MODE="own"
      if [[ "$MODE" != "3" ]]; then ask_required "Panel domain (e.g. panel.example.com)"; PANEL_FQDN="$REPLY_VAL"; fi
      if [[ "$MODE" != "2" ]]; then ask "Node domain for Wings (e.g. node1.example.com)" "node1.${PANEL_FQDN#*.}"; NODE_FQDN="$REPLY_VAL"; fi
      echo
      warn "In Cloudflare DNS, add A records -> $SERVER_IP with the cloud GREY (DNS only):"
      [[ -n "$PANEL_FQDN" ]] && echo "     $PANEL_FQDN"
      [[ -n "$NODE_FQDN"  ]] && echo "     $NODE_FQDN"
      read -r -p "Press Enter once the records are added..." _
      local d ip
      for d in $PANEL_FQDN $NODE_FQDN; do
        ip="$(getent ahostsv4 "$d" | awk '{print $1; exit}')"
        if [[ "$ip" == "$SERVER_IP" ]]; then ok "$d -> $ip"
        else warn "$d resolves to '${ip:-nothing}', expected $SERVER_IP (SSL may fail)"; fi
      done
      yesno "Continue?" || exit 1
      if yesno "Get a free Let's Encrypt SSL certificate (HTTPS)?"; then USE_SSL=true; fi
      ;;
    2)
      DOMAIN_MODE="tunnel"
      ok "A random trycloudflare.com URL will be generated after you confirm."
      ;;
    *)
      DOMAIN_MODE="sslip"
      local dashed="${SERVER_IP//./-}"
      PANEL_FQDN="panel.${dashed}.sslip.io"
      NODE_FQDN="node1.${dashed}.sslip.io"
      ok "Using $PANEL_FQDN and $NODE_FQDN"
      if yesno "Get a free Let's Encrypt SSL certificate (HTTPS)?"; then USE_SSL=true; fi
      ;;
  esac
}

# ---------------- Panel questions ----------------
panel_questions() {
  echo
  echo "${B}Admin account${N}"
  ask_required "Admin email"; ADMIN_EMAIL="$REPLY_VAL"
  ask "Admin username" "admin"; ADMIN_USER="$REPLY_VAL"
  ask "First name" "Admin"; ADMIN_FIRST="$REPLY_VAL"
  ask "Last name" "User"; ADMIN_LAST="$REPLY_VAL"
  read -r -s -p "Admin password (leave empty to auto-generate): " ADMIN_PASS; echo
  if [[ -z "$ADMIN_PASS" ]]; then ADMIN_PASS="$(gen_pass 16)"; info "Generated admin password."; fi
  local tz; tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
  ask "Timezone" "$tz"; TZ_VAL="$REPLY_VAL"
  DB_PASS="$(gen_pass 32)"
}

confirm_summary() {
  echo
  echo "${B}Summary${N}"
  echo "  Mode:      $MODE_NAME"
  case "$DOMAIN_MODE" in
    tunnel) echo "  Domain:    Cloudflare tunnel (random trycloudflare.com URL)" ;;
    *)      echo "  Panel:     ${PANEL_FQDN:-n/a}"; echo "  Node:      ${NODE_FQDN:-n/a}"; echo "  SSL:       $USE_SSL" ;;
  esac
  if [[ "$MODE" == "1" || "$MODE" == "2" ]]; then echo "  Admin:     $ADMIN_USER <$ADMIN_EMAIL>"; fi
  echo
  yesno "Start installation?" || exit 0
}

# Starts tunnels (if chosen) and fixes the final hostnames/URLs
prepare_domain() {
  if [[ "$DOMAIN_MODE" == "tunnel" ]]; then
    install_cloudflared
    if [[ "$MODE" != "3" ]]; then PANEL_FQDN="$(start_tunnel panel 80)"; ok "Panel tunnel: $PANEL_FQDN"; fi
    if [[ "$MODE" != "2" ]]; then NODE_FQDN="$(start_tunnel node 443)";  ok "Node tunnel:  $NODE_FQDN"; fi
    USE_SSL=false; ASSUME_SSL=true
    PANEL_URL="https://${PANEL_FQDN}"
  else
    ASSUME_SSL=false
    PANEL_URL="$([[ $USE_SSL == true ]] && echo https || echo http)://${PANEL_FQDN}"
  fi
}

# ---------------- Installers ----------------
fetch_lib() { curl -fsSL -o /tmp/lib.sh "$BASE/lib/lib.sh" || die "Could not download installer library."; }

install_panel() {
  info "Installing Panel (this takes a few minutes)..."
  fetch_lib
  export FQDN="$PANEL_FQDN" MYSQL_DB="panel" MYSQL_USER="pterodactyl" MYSQL_PASSWORD="$DB_PASS"
  export timezone="$TZ_VAL" email="$ADMIN_EMAIL" user_email="$ADMIN_EMAIL"
  export user_username="$ADMIN_USER" user_firstname="$ADMIN_FIRST" user_lastname="$ADMIN_LAST" user_password="$ADMIN_PASS"
  export CONFIGURE_FIREWALL=true ASSUME_SSL="$ASSUME_SSL" CONFIGURE_LETSENCRYPT="$USE_SSL"
  bash <(curl -fsSL "$BASE/installers/panel.sh") || die "Panel installation failed."
  [[ "$DOMAIN_MODE" == "tunnel" ]] && apply_panel_url "$PANEL_FQDN"
  ok "Panel installed."
}

install_wings() {
  info "Installing Wings + Docker..."
  fetch_lib
  export FQDN="$NODE_FQDN" email="${ADMIN_EMAIL:-admin@example.com}"
  export CONFIGURE_FIREWALL=true CONFIGURE_LETSENCRYPT="$USE_SSL"
  export INSTALL_MARIADB=false CONFIGURE_DBHOST=false CONFIGURE_DB_FIREWALL=false
  bash <(curl -fsSL "$BASE/installers/wings.sh") || die "Wings installation failed."
  ok "Wings installed."
}

save_credentials() {
  {
    echo "Pterodactyl credentials ($(date))"
    echo "Panel URL : $PANEL_URL"
    echo "Username  : $ADMIN_USER"
    echo "Email     : $ADMIN_EMAIL"
    echo "Password  : $ADMIN_PASS"
    echo "DB user   : pterodactyl"
    echo "DB pass   : $DB_PASS"
    echo "Node FQDN : ${NODE_FQDN:-n/a}"
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
}

finish_panel() {
  save_credentials
  echo
  echo -e "${G}${B}══════════ DONE ══════════${N}"
  echo "  URL:      $PANEL_URL"
  echo "  Username: $ADMIN_USER"
  echo "  Password: $ADMIN_PASS"
  echo "  Saved to: $CRED_FILE"
  echo
  echo "${B}Next steps:${N}"
  echo "  1. Log in -> Admin -> Locations -> create one"
  if [[ "$MODE" == "1" ]]; then
    echo "  2. Admin -> Nodes -> Create New:"
    echo "       FQDN: $NODE_FQDN"
    if [[ "$DOMAIN_MODE" == "tunnel" ]]; then
      echo "       Communicate over SSL: Use SSL connection | Behind Proxy: Yes"
      echo "       Daemon Port: 443   (Wings listens on 443 behind the tunnel)"
    else
      echo "       Daemon Port: 8080 | SFTP Port: 2022"
    fi
    echo "  3. Node -> Configuration tab -> paste into /etc/pterodactyl/config.yml"
    echo "  4. systemctl enable --now wings"
    echo "  5. Node -> Allocation -> add IP $SERVER_IP and your game ports"
  fi
  if [[ "$DOMAIN_MODE" == "tunnel" ]]; then
    echo
    warn "Tunnel URLs change after a reboot/restart. Run ./install.sh -> option 4 to get the new Panel URL."
    warn "Game ports (Minecraft etc.) can NOT go through trycloudflare. Players need your IP:port open at the provider."
  fi
}

# ---------------- Main menu ----------------
banner
echo "  1) Install Panel + Wings (everything on this VPS)"
echo "  2) Install Panel only"
echo "  3) Install Wings only (node)"
echo "  4) Enable / refresh Cloudflare tunnel for an existing Panel"
echo "  0) Exit"
echo
read -r -p "Choose [0-4]: " MENU
case "$MENU" in
  1) MODE=1; MODE_NAME="Panel + Wings" ;;
  2) MODE=2; MODE_NAME="Panel only" ;;
  3) MODE=3; MODE_NAME="Wings only" ;;
  4) MODE=4 ;;
  *) exit 0 ;;
esac

preflight

if [[ "$MODE" == "4" ]]; then enable_tunnel_existing; exit 0; fi

if [[ "$MODE" != "2" ]]; then
  if ! wings_check; then
    if [[ "$MODE" == "3" ]]; then exit 1; fi
    MODE=2; MODE_NAME="Panel only"
  fi
fi

choose_domain

if [[ "$MODE" == "3" ]]; then
  ask_required "Email for SSL notices"; ADMIN_EMAIL="$REPLY_VAL"
else
  panel_questions
fi

confirm_summary
prepare_domain

case "$MODE" in
  1) install_panel; install_wings; finish_panel ;;
  2) install_panel; finish_panel ;;
  3) install_wings
     echo; ok "Wings installed. Create the node in your panel, paste its config into /etc/pterodactyl/config.yml, then: systemctl enable --now wings" ;;
esac
