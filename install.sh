#!/usr/bin/env bash
# ============================================================
#  Ptero Installer v4
#
#  ONE COMMAND, NO QUESTIONS:
#    bash -c "$(curl -fsSL https://raw.githubusercontent.com/whitigerxgaming-design/ptero-installer/main/install.sh)"
#
#  - Fresh VPS  -> installs everything automatically
#  - Already installed -> shows a simple manage menu
#  - Later you can just type:  ptero-manage
# ============================================================
set -u

SELF_URL="https://raw.githubusercontent.com/whitigerxgaming-design/ptero-installer/main/install.sh"
BASE="https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer/master"
CRED_FILE="/root/pterodactyl-credentials.txt"
PANEL_DIR="/var/www/pterodactyl"
PANEL_LOG="/var/log/ptero-tunnel-panel.log"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
info()  { echo -e "${C}[i]${N} $*"; }
ok()    { echo -e "${G}[✓]${N} $*"; }
warn()  { echo -e "${Y}[!]${N} $*"; }
die()   { echo -e "${R}[x]${N} $*"; exit 1; }

# ---- defaults ----
EASY=false
MODE=""; MODE_NAME=""; VIRT="unknown"; SERVER_IP=""; IS_NAT=false
DOMAIN_MODE=""; PANEL_FQDN=""; NODE_FQDN=""; PANEL_URL=""
USE_SSL=false; ASSUME_SSL=false
ADMIN_EMAIL=""; ADMIN_USER=""; ADMIN_FIRST=""; ADMIN_LAST=""; ADMIN_PASS=""
TZ_VAL="UTC"; DB_PASS=""; REPLY_VAL=""; NODE_OK=false

ask() {
  local p="$1" d="${2:-}" v
  if [[ -n "$d" ]]; then read -r -p "$p [$d]: " v; REPLY_VAL="${v:-$d}"
  else read -r -p "$p: " v; REPLY_VAL="$v"; fi
}
ask_required() { REPLY_VAL=""; while [[ -z "$REPLY_VAL" ]]; do ask "$1" "${2:-}"; done; }
gen_pass() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-20}"; }
yesno() { [[ "$EASY" == true ]] && return 0; local v; read -r -p "$1 [Y/n]: " v; [[ "${v:-y}" =~ ^[Yy] ]]; }

banner() {
  clear
  echo -e "${B}${C}"
  echo "  ╔═══════════════════════════════════════════╗"
  echo "  ║          Ptero Installer  v4              ║"
  echo "  ╚═══════════════════════════════════════════╝"
  echo -e "${N}"
}

# ---------------- Pre-flight checks ----------------
light_preflight() {
  [[ $EUID -eq 0 ]] || die "Run as root (type: sudo -i  and try again)."
  if ! command -v curl >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq curl ca-certificates >/dev/null 2>&1
  fi
  command -v curl >/dev/null 2>&1 || die "curl is missing and could not be installed."
}

preflight() {
  [[ $EUID -eq 0 ]] || die "Run as root (type: sudo -i  and try again)."
  . /etc/os-release 2>/dev/null || die "Cannot detect OS"
  case "$ID-$VERSION_ID" in
    ubuntu-22.04|ubuntu-24.04|debian-11|debian-12) ok "OS: $PRETTY_NAME" ;;
    *) warn "OS $PRETTY_NAME is not officially supported."; yesno "Continue anyway?" || exit 1 ;;
  esac
  VIRT="$(systemd-detect-virt 2>/dev/null || echo unknown)"
  info "Virtualization: $VIRT | CPU: $(nproc) cores | RAM: $(free -h | awk '/Mem:/{print $2}')"

  info "Checking that apt works..."
  apt-get update -qq >/dev/null 2>&1 || die "apt-get update failed. Your VPS has a package problem (check: apt update)."
  apt-get install -y -qq curl ca-certificates >/dev/null 2>&1 || die "Could not install curl."

  SERVER_IP="$(curl -4 -s --max-time 10 ifconfig.me || true)"
  [[ -n "$SERVER_IP" ]] || die "Could not detect public IP (no internet?)."
  ok "Public IP: $SERVER_IP"

  if ip -4 addr 2>/dev/null | grep -q "inet ${SERVER_IP}/"; then
    IS_NAT=false
  else
    IS_NAT=true
    info "Your VPS is behind NAT (normal for cloud VPS). A Cloudflare tunnel will be used for the website."
  fi
}

wings_check() {
  if [[ "$VIRT" == "lxc" || "$VIRT" == "openvz" ]]; then
    warn "This VPS is '$VIRT'. Docker (needed by Wings) usually does NOT work here."
    yesno "Try installing Wings anyway?" || return 1
  fi
  return 0
}

# ---------------- Cloudflare tunnel helpers ----------------
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

install_helpers() {
  cat > /usr/local/bin/ptero-url <<'EOF'
#!/usr/bin/env bash
grep '^APP_URL=' /var/www/pterodactyl/.env 2>/dev/null | cut -d= -f2-
EOF
  chmod +x /usr/local/bin/ptero-url

  cat > /usr/local/bin/ptero-url-sync <<'EOF'
#!/usr/bin/env bash
LOG=/var/log/ptero-tunnel-panel.log
DIR=/var/www/pterodactyl
url=""
for i in $(seq 1 40); do
  url="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$LOG" 2>/dev/null | grep -v '^https://api\.' | tail -1)"
  [ -n "$url" ] && break
  sleep 2
done
[ -n "$url" ] || exit 1
echo "$url" > /root/panel-url.txt
[ -f "$DIR/.env" ] || exit 0
host="${url#https://}"
sed -i "s|^APP_URL=.*|APP_URL=https://${host}|" "$DIR/.env"
if grep -q '^TRUSTED_PROXIES' "$DIR/.env"; then
  sed -i 's|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=*|' "$DIR/.env"
else
  echo 'TRUSTED_PROXIES=*' >> "$DIR/.env"
fi
chown www-data:www-data "$DIR/.env" 2>/dev/null
su -s /bin/bash www-data -c "cd $DIR && php artisan config:clear" >/dev/null 2>&1
exit 0
EOF
  chmod +x /usr/local/bin/ptero-url-sync

  cat > /etc/systemd/system/ptero-url-sync.service <<'EOF'
[Unit]
Description=Sync Panel URL with Cloudflare quick tunnel
After=ptero-tunnel-panel.service
PartOf=ptero-tunnel-panel.service

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=120
ExecStart=/usr/local/bin/ptero-url-sync

[Install]
WantedBy=ptero-tunnel-panel.service
EOF
}

start_tunnel() { # start_tunnel NAME PORT -> prints hostname
  local name="$1" port="$2" log="/var/log/ptero-tunnel-$1.log" url="" i
  cat > "/etc/systemd/system/ptero-tunnel-${name}.service" <<EOF
[Unit]
Description=Cloudflare quick tunnel (${name})
After=network-online.target
Wants=network-online.target

[Service]
ExecStartPre=/bin/bash -c ': > ${log}'
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --protocol http2 --url http://localhost:${port}
Restart=always
RestartSec=5
StandardOutput=append:${log}
StandardError=append:${log}

[Install]
WantedBy=multi-user.target
EOF
  [[ "$name" == "panel" ]] && install_helpers
  systemctl daemon-reload
  systemctl enable "ptero-tunnel-${name}" >/dev/null 2>&1
  [[ "$name" == "panel" ]] && systemctl enable ptero-url-sync >/dev/null 2>&1
  systemctl restart --no-block "ptero-tunnel-${name}"
  for i in $(seq 1 60); do
    url="$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$log" 2>/dev/null | grep -v '^https://api\.' | head -1)"
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

apply_panel_url() {
  local host="$1"
  [[ -d "$PANEL_DIR" ]] || die "Panel not found in $PANEL_DIR"
  sed -i "s|^APP_URL=.*|APP_URL=https://${host}|" "$PANEL_DIR/.env"
  if grep -q '^TRUSTED_PROXIES' "$PANEL_DIR/.env"; then
    sed -i 's|^TRUSTED_PROXIES=.*|TRUSTED_PROXIES=*|' "$PANEL_DIR/.env"
  else
    echo 'TRUSTED_PROXIES=*' >> "$PANEL_DIR/.env"
  fi
  chown www-data:www-data "$PANEL_DIR/.env" 2>/dev/null
  su -s /bin/bash www-data -c "cd $PANEL_DIR && php artisan config:clear" >/dev/null 2>&1
}

# ---------------- Manage-menu actions ----------------
enable_tunnel_existing() {
  [[ -d "$PANEL_DIR" ]] || die "No Panel found at $PANEL_DIR."
  install_cloudflared
  info "Switching nginx to plain HTTP (the tunnel provides HTTPS)..."
  write_nginx_http_conf
  info "Starting tunnel..."
  PANEL_FQDN="$(start_tunnel panel 80)"
  apply_panel_url "$PANEL_FQDN"
  ok "Panel is now at: https://${PANEL_FQDN}"
  [[ -f "$CRED_FILE" ]] && sed -i "s|^Panel URL .*|Panel URL : https://${PANEL_FQDN}|" "$CRED_FILE"
}

setup_named_tunnel() {
  [[ -d "$PANEL_DIR" ]] || die "No Panel found at $PANEL_DIR."
  echo
  echo "${B}Permanent tunnel (free, URL never changes)${N}"
  echo "Do this in the Cloudflare dashboard first:"
  echo "  1. Zero Trust -> Networks -> Tunnels -> Create a tunnel -> Cloudflared"
  echo "  2. Name it (e.g. ptero) and copy the TOKEN (long text starting with eyJ...)"
  echo "  3. Public hostname tab -> Add:"
  echo "        Domain: panel.yourdomain.com   Service: HTTP   URL: localhost:80"
  echo
  ask_required "Paste the tunnel token (or the whole install command)"
  local token="${REPLY_VAL##* }"
  ask_required "Panel hostname you added (e.g. panel.yourdomain.com)"
  PANEL_FQDN="$REPLY_VAL"

  install_cloudflared
  write_nginx_http_conf
  ( umask 077; echo "TUNNEL_TOKEN=${token}" > /etc/ptero-tunnel.env )
  systemctl disable --now ptero-url-sync >/dev/null 2>&1
  cat > /etc/systemd/system/ptero-tunnel-panel.service <<'EOF'
[Unit]
Description=Cloudflare named tunnel (panel)
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=/etc/ptero-tunnel.env
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate --protocol http2 run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  install_helpers
  systemctl disable ptero-url-sync >/dev/null 2>&1
  systemctl daemon-reload
  systemctl enable ptero-tunnel-panel >/dev/null 2>&1
  systemctl restart ptero-tunnel-panel
  apply_panel_url "$PANEL_FQDN"
  sleep 8
  if systemctl is-active --quiet ptero-tunnel-panel; then
    ok "Permanent tunnel running. Panel: https://${PANEL_FQDN}"
  else
    warn "Tunnel is not running. Check: journalctl -u ptero-tunnel-panel -n 30 --no-pager"
  fi
  [[ -f "$CRED_FILE" ]] && sed -i "s|^Panel URL .*|Panel URL : https://${PANEL_FQDN}|" "$CRED_FILE"
}

status_check() {
  echo
  echo "${B}Service status${N}"
  local sock svc s code
  sock="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -1)"
  svc="$(basename "${sock:-php-fpm.sock}" .sock)"
  for s in nginx mariadb redis-server "$svc" pteroq ptero-tunnel-panel ptero-tunnel-node wings docker; do
    systemctl list-unit-files "${s}.service" 2>/dev/null | grep -q "^${s}.service" || continue
    if systemctl is-active --quiet "$s"; then ok "$s is running"; else warn "$s is NOT running"; fi
  done
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1/ || true)"
  info "Local Panel response: HTTP ${code:-none}  (200 or 302 = good)"
  info "Panel URL: $(grep '^APP_URL=' "$PANEL_DIR/.env" 2>/dev/null | cut -d= -f2-)"
  if [[ -f "$PANEL_LOG" ]]; then echo; info "Last tunnel log lines:"; tail -n 5 "$PANEL_LOG"; fi
  echo
  if yesno "Restart everything now (fixes most problems)?"; then
    systemctl restart mariadb 2>/dev/null
    systemctl restart "$svc" 2>/dev/null
    systemctl restart nginx 2>/dev/null
    systemctl restart pteroq 2>/dev/null
    systemctl restart wings 2>/dev/null
    if systemctl list-unit-files ptero-tunnel-panel.service 2>/dev/null | grep -q ptero-tunnel-panel; then
      systemctl restart --no-block ptero-tunnel-panel
      systemctl restart --no-block ptero-tunnel-node 2>/dev/null
      info "Waiting for the tunnel to connect (about 25 seconds)..."
      sleep 25
    else
      warn "No tunnel service found. Use 'Get a new Panel link'."
    fi
    echo; ok "Panel URL now: $(ptero-url 2>/dev/null || grep '^APP_URL=' "$PANEL_DIR/.env" | cut -d= -f2-)"
  fi
}

show_details() {
  echo
  if [[ -f "$CRED_FILE" ]]; then cat "$CRED_FILE"; else warn "No saved credentials found."; fi
  echo
  info "Current Panel URL: $(ptero-url 2>/dev/null || echo unknown)"
}

# ---------------- Advanced (manual) install ----------------
choose_domain() {
  echo
  echo "${B}Domain setup${N}"
  echo "  1) I have my own domain (Cloudflare or any provider)"
  echo "  2) Cloudflare tunnel: random free URL (no port forwarding needed)"
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
    2) DOMAIN_MODE="tunnel" ;;
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
    tunnel) echo "  Domain:    Cloudflare tunnel (random URL)" ;;
    *)      echo "  Panel:     ${PANEL_FQDN:-n/a}"; echo "  Node:      ${NODE_FQDN:-n/a}"; echo "  SSL:       $USE_SSL" ;;
  esac
  if [[ "$MODE" == "1" || "$MODE" == "2" ]]; then echo "  Admin:     $ADMIN_USER <$ADMIN_EMAIL>"; fi
  echo
  yesno "Start installation?" || exit 0
}

# ---------------- Core installers ----------------
prepare_domain() {
  if [[ "$DOMAIN_MODE" == "tunnel" ]]; then
    install_cloudflared
    if [[ "$MODE" != "3" ]]; then PANEL_FQDN="$(start_tunnel panel 80)"; ok "Website link created: $PANEL_FQDN"; fi
    if [[ "$MODE" != "2" ]]; then NODE_FQDN="$(start_tunnel node 443)";  ok "Node link created:    $NODE_FQDN"; fi
    USE_SSL=false; ASSUME_SSL=true
    PANEL_URL="https://${PANEL_FQDN}"
  else
    ASSUME_SSL=false
    PANEL_URL="$([[ $USE_SSL == true ]] && echo https || echo http)://${PANEL_FQDN}"
  fi
}

fetch_lib() { curl -fsSL -o /tmp/lib.sh "$BASE/lib/lib.sh" || die "Could not download installer library."; }

install_panel() {
  info "Installing Panel (about 5-10 minutes, please wait)..."
  fetch_lib
  export FQDN="$PANEL_FQDN" MYSQL_DB="panel" MYSQL_USER="pterodactyl" MYSQL_PASSWORD="$DB_PASS"
  export timezone="$TZ_VAL" email="$ADMIN_EMAIL" user_email="$ADMIN_EMAIL"
  export user_username="$ADMIN_USER" user_firstname="$ADMIN_FIRST" user_lastname="$ADMIN_LAST" user_password="$ADMIN_PASS"
  export CONFIGURE_FIREWALL=true ASSUME_SSL="$ASSUME_SSL" CONFIGURE_LETSENCRYPT="$USE_SSL"
  bash <(curl -fsSL "$BASE/installers/panel.sh") || die "Panel installation failed."
  if [[ "$DOMAIN_MODE" == "tunnel" ]]; then
    apply_panel_url "$PANEL_FQDN"
    systemctl restart --no-block ptero-url-sync 2>/dev/null
  fi
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

# Creates location + node + ports in the Panel and starts Wings (no manual steps)
artisan() { su -s /bin/bash www-data -c "cd $PANEL_DIR && php artisan $*"; }
dbq()     { mysql -u pterodactyl -p"$DB_PASS" panel -N -e "$1" 2>/dev/null; }

auto_node() {
  info "Creating the node automatically..."
  artisan p:location:make --short=auto --long=Auto >/dev/null 2>&1 || return 1
  local loc nid mem disk lip p vals=""
  loc="$(dbq 'select id from locations order by id desc limit 1;')"
  [[ -n "$loc" ]] || return 1
  mem=$(( $(free -m | awk '/Mem:/{print $2}') * 90 / 100 ))
  disk=$(( $(df -BM --output=avail / | tail -1 | tr -dc '0-9') * 90 / 100 ))
  artisan p:node:make --name=node1 --description=auto --locationId="$loc" --fqdn="$NODE_FQDN" \
    --public=1 --scheme=https --proxy=1 --maxMemory="$mem" --overallocateMemory=0 \
    --maxDisk="$disk" --overallocateDisk=0 --uploadSize=100 --daemonListeningPort=443 \
    --daemonSFTPPort=2022 --daemonBase=/var/lib/pterodactyl/volumes >/dev/null 2>&1 || return 1
  nid="$(dbq 'select id from nodes order by id desc limit 1;')"
  [[ -n "$nid" ]] || return 1

  mkdir -p /etc/pterodactyl
  artisan p:node:configuration "$nid" --format=yaml > /etc/pterodactyl/config.yml 2>/dev/null
  grep -q 'token' /etc/pterodactyl/config.yml || return 1

  lip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
  [[ -n "$lip" ]] || lip="$SERVER_IP"
  for p in $(seq 25565 25600); do vals+="(${nid},'${lip}','${SERVER_IP}',${p},now(),now()),"; done
  dbq "insert into allocations (node_id,ip,ip_alias,port,created_at,updated_at) values ${vals%,};" || true

  systemctl enable --now wings >/dev/null 2>&1
  sleep 5
  systemctl is-active --quiet wings || return 1
  ok "Node created and Wings started."
  return 0
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

install_self() {
  curl -fsSL "$SELF_URL" -o /usr/local/bin/ptero-manage 2>/dev/null && chmod +x /usr/local/bin/ptero-manage
}

finish_panel() {
  save_credentials
  install_self
  echo
  echo -e "${G}${B}══════════════ ALL DONE ══════════════${N}"
  echo "  Open this link:  $PANEL_URL"
  echo "  Username:        $ADMIN_USER"
  echo "  Password:        $ADMIN_PASS"
  echo "  (saved in $CRED_FILE)"
  echo
  if [[ "$MODE" == "1" ]]; then
    if [[ "$NODE_OK" == true ]]; then
      ok "Your node is ready. Go to Admin -> Servers -> Create New to make your first server."
    else
      warn "The node could not be created automatically. Create it in Admin -> Nodes:"
      echo "     FQDN: $NODE_FQDN | SSL: yes | Behind Proxy: yes | Daemon Port: 443"
      echo "     Then paste its Configuration into /etc/pterodactyl/config.yml and run: systemctl enable --now wings"
    fi
  else
    warn "Panel only: this VPS cannot run game servers (Docker is not supported here)."
    echo "     To host game servers, use a KVM VPS and run this same command there, choosing Wings."
  fi
  echo
  info "Need help later? Type:  ${B}ptero-manage${N}   (repair, new link, show login)"
  if [[ "$DOMAIN_MODE" == "tunnel" ]]; then
    warn "The link can change after a restart. The Panel updates itself; 'ptero-manage' shows the current link."
    warn "Players cannot join through this link. Game ports must be open at your VPS provider."
  fi
}

# ---------------- Easy mode: ZERO questions ----------------
easy_install() {
  EASY=true
  banner
  echo "  Installing Pterodactyl automatically. No questions will be asked."
  echo "  This takes about 10 minutes. Please do not close this window."
  echo
  preflight

  if [[ "$VIRT" == "lxc" || "$VIRT" == "openvz" ]]; then
    MODE=2; MODE_NAME="Panel only"
    warn "This VPS type ($VIRT) cannot run Docker, so only the Panel will be installed."
  else
    MODE=1; MODE_NAME="Panel + Wings"
  fi

  DOMAIN_MODE="tunnel"
  ADMIN_USER="admin"; ADMIN_FIRST="Admin"; ADMIN_LAST="User"
  ADMIN_EMAIL="admin@ptero.local"
  ADMIN_PASS="$(gen_pass 16)"
  DB_PASS="$(gen_pass 32)"
  TZ_VAL="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
  [[ -n "$TZ_VAL" ]] || TZ_VAL="UTC"

  prepare_domain
  install_panel
  if [[ "$MODE" == "1" ]]; then
    if ( install_wings ); then
      auto_node && NODE_OK=true
    else
      warn "Wings could not be installed on this VPS."
      MODE=2
    fi
  fi
  finish_panel
}

# ---------------- Advanced install menu ----------------
advanced_menu() {
  light_preflight
  banner
  echo "  1) Install Panel + Wings"
  echo "  2) Install Panel only"
  echo "  3) Install Wings only (node)"
  echo "  0) Back"
  echo
  read -r -p "Choose [0-3]: " m
  case "$m" in
    1) MODE=1; MODE_NAME="Panel + Wings" ;;
    2) MODE=2; MODE_NAME="Panel only" ;;
    3) MODE=3; MODE_NAME="Wings only" ;;
    *) return ;;
  esac
  preflight
  if [[ "$MODE" != "2" ]]; then
    if ! wings_check; then
      if [[ "$MODE" == "3" ]]; then exit 1; fi
      MODE=2; MODE_NAME="Panel only"
    fi
  fi
  choose_domain
  if [[ "$MODE" == "3" ]]; then ask_required "Email for SSL notices"; ADMIN_EMAIL="$REPLY_VAL"; else panel_questions; fi
  confirm_summary
  prepare_domain
  case "$MODE" in
    1) install_panel; install_wings; finish_panel ;;
    2) install_panel; finish_panel ;;
    3) install_wings; ok "Wings installed. Create the node in your panel and paste its config into /etc/pterodactyl/config.yml, then: systemctl enable --now wings" ;;
  esac
}

# ---------------- Manage menu (already installed) ----------------
manage_menu() {
  light_preflight
  banner
  echo "  Pterodactyl is already installed on this VPS."
  echo
  echo "  1) Fix problems (status check + restart everything)"
  echo "  2) Get a new Panel link (random trycloudflare.com)"
  echo "  3) Show my login details and current link"
  echo "  4) Permanent link with my own domain (advanced)"
  echo "  5) Advanced install menu"
  echo "  0) Exit"
  echo
  read -r -p "Choose [0-5]: " c
  case "$c" in
    1) status_check ;;
    2) enable_tunnel_existing ;;
    3) show_details ;;
    4) setup_named_tunnel ;;
    5) advanced_menu ;;
    *) exit 0 ;;
  esac
}

# ---------------- Entry point ----------------
case "${1:-}" in
  --advanced) advanced_menu ;;
  --manage)   manage_menu ;;
  --install)  easy_install ;;
  *)
    if [[ -d "$PANEL_DIR" ]]; then manage_menu; else easy_install; fi
    ;;
esac
