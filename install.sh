#!/usr/bin/env bash
# ============================================================
#  Pterodactyl Quick Installer
#  Usage:  sudo ./install.sh
#  Wraps the official pterodactyl-installer in unattended mode
# ============================================================
set -u

BASE="https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer/master"
CRED_FILE="/root/pterodactyl-credentials.txt"

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
info()  { echo -e "${C}[i]${N} $*"; }
ok()    { echo -e "${G}[✓]${N} $*"; }
warn()  { echo -e "${Y}[!]${N} $*"; }
die()   { echo -e "${R}[x]${N} $*"; exit 1; }

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
  echo "  ║      Pterodactyl Quick Installer          ║"
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
  info "Virtualization: $VIRT"
  info "CPU: $(nproc) cores | RAM: $(free -h | awk '/Mem:/{print $2}')"

  info "Testing that the system can run apt..."
  if ! apt-get update -qq >/dev/null 2>&1; then
    die "apt-get update failed. Fix this first (check 'ps aux | wc -l' and process limits)."
  fi
  apt-get install -y -qq curl ca-certificates >/dev/null 2>&1
  SERVER_IP="$(curl -4 -s --max-time 10 ifconfig.me || true)"
  [[ -n "$SERVER_IP" ]] || die "Could not detect public IP."
  ok "Public IP: $SERVER_IP"
}

wings_check() {
  if [[ "$VIRT" == "lxc" || "$VIRT" == "openvz" ]]; then
    warn "This VPS is '$VIRT'. Docker (needed by Wings) usually does NOT work here."
    yesno "Try installing Wings anyway?" || return 1
  fi
  return 0
}

# ---------------- Domain selection ----------------
choose_domain() {
  local dashed="${SERVER_IP//./-}"
  echo
  echo "${B}Domain setup${N}"
  echo "  1) I have my own domain (Cloudflare or any provider)"
  echo "  2) I have no domain: use a free automatic one (sslip.io)"
  local c; read -r -p "Choose [1-2]: " c
  if [[ "$c" == "1" ]]; then
    ask_required "Panel domain (e.g. panel.example.com)"; PANEL_FQDN="$REPLY_VAL"
    ask "Node domain for Wings (e.g. node1.example.com)" "node1.${PANEL_FQDN#*.}"; NODE_FQDN="$REPLY_VAL"
    echo
    warn "In Cloudflare DNS, add these A records -> $SERVER_IP with the cloud GREY (DNS only):"
    echo "     $PANEL_FQDN"
    echo "     $NODE_FQDN"
    read -r -p "Press Enter once the records are added..." _
    local d ip
    for d in "$PANEL_FQDN" "$NODE_FQDN"; do
      ip="$(getent ahostsv4 "$d" | awk '{print $1; exit}')"
      if [[ "$ip" == "$SERVER_IP" ]]; then ok "$d -> $ip"
      else warn "$d resolves to '${ip:-nothing}', expected $SERVER_IP (SSL may fail)"; fi
    done
    yesno "Continue?" || exit 1
  else
    PANEL_FQDN="panel.${dashed}.sslip.io"
    NODE_FQDN="node1.${dashed}.sslip.io"
    ok "Using $PANEL_FQDN and $NODE_FQDN (no DNS setup needed)"
  fi
  if yesno "Get a free Let's Encrypt SSL certificate (HTTPS)?"; then USE_SSL=true; else USE_SSL=false; fi
}

# ---------------- Panel questions ----------------
panel_questions() {
  echo
  echo "${B}Admin account${N}"
  ask_required "Admin email"; ADMIN_EMAIL="$REPLY_VAL"
  ask "Admin username" "admin"; ADMIN_USER="$REPLY_VAL"
  ask "First name" "Admin"; ADMIN_FIRST="$REPLY_VAL"
  ask "Last name" "User"; ADMIN_LAST="$REPLY_VAL"
  local gp; gp="$(gen_pass 16)"
  read -r -s -p "Admin password (leave empty to auto-generate): " ADMIN_PASS; echo
  [[ -n "$ADMIN_PASS" ]] || { ADMIN_PASS="$gp"; info "Generated admin password."; }
  local tz; tz="$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
  ask "Timezone" "$tz"; TZ_VAL="$REPLY_VAL"
  DB_PASS="$(gen_pass 32)"
}

confirm_summary() {
  echo
  echo "${B}Summary${N}"
  echo "  Mode:        $MODE_NAME"
  echo "  Panel URL:   $([[ $USE_SSL == true ]] && echo https || echo http)://$PANEL_FQDN"
  [[ "$MODE" != "1" ]] && echo "  Node FQDN:   $NODE_FQDN"
  [[ "$MODE" != "2" ]] && echo "  Admin:       $ADMIN_USER <$ADMIN_EMAIL>"
  echo "  SSL:         $USE_SSL"
  echo
  yesno "Start installation?" || exit 0
}

# ---------------- Installers ----------------
fetch_lib() { curl -sSL -o /tmp/lib.sh "$BASE/lib/lib.sh" || die "Could not download installer library."; }

install_panel() {
  info "Installing Panel (this takes a few minutes)..."
  fetch_lib
  export FQDN="$PANEL_FQDN" MYSQL_DB="panel" MYSQL_USER="pterodactyl" MYSQL_PASSWORD="$DB_PASS"
  export timezone="$TZ_VAL" email="$ADMIN_EMAIL" user_email="$ADMIN_EMAIL"
  export user_username="$ADMIN_USER" user_firstname="$ADMIN_FIRST" user_lastname="$ADMIN_LAST" user_password="$ADMIN_PASS"
  export CONFIGURE_FIREWALL=true ASSUME_SSL=false CONFIGURE_LETSENCRYPT="$USE_SSL"
  bash <(curl -sSL "$BASE/installers/panel.sh") || die "Panel installation failed."
  ok "Panel installed."
}

install_wings() {
  info "Installing Wings + Docker..."
  fetch_lib
  export FQDN="$NODE_FQDN" email="${ADMIN_EMAIL:-admin@$NODE_FQDN}"
  export CONFIGURE_FIREWALL=true CONFIGURE_LETSENCRYPT="$USE_SSL"
  export INSTALL_MARIADB=false CONFIGURE_DBHOST=false CONFIGURE_DB_FIREWALL=false
  bash <(curl -sSL "$BASE/installers/wings.sh") || die "Wings installation failed."
  ok "Wings installed."
}

save_credentials() {
  local proto; proto=$([[ $USE_SSL == true ]] && echo https || echo http)
  {
    echo "Pterodactyl credentials ($(date))"
    echo "Panel URL : $proto://$PANEL_FQDN"
    echo "Username  : $ADMIN_USER"
    echo "Email     : $ADMIN_EMAIL"
    echo "Password  : $ADMIN_PASS"
    echo "DB user   : pterodactyl"
    echo "DB pass   : $DB_PASS"
    echo "Node FQDN : $NODE_FQDN"
  } > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
}

finish_panel() {
  save_credentials
  echo
  echo -e "${G}${B}══════════ DONE ══════════${N}"
  echo "  URL:      $([[ $USE_SSL == true ]] && echo https || echo http)://$PANEL_FQDN"
  echo "  Username: $ADMIN_USER"
  echo "  Password: $ADMIN_PASS"
  echo "  Saved to: $CRED_FILE"
  echo
  echo "${B}Next steps:${N}"
  echo "  1. Log in -> Admin -> Locations -> create one"
  echo "  2. Admin -> Nodes -> Create New (FQDN: $NODE_FQDN)"
  echo "  3. Node -> Configuration tab -> paste into /etc/pterodactyl/config.yml"
  echo "  4. systemctl enable --now wings"
  echo "  5. Node -> Allocation -> add IP $SERVER_IP and your game ports"
}

# ---------------- Main menu ----------------
banner
echo "  1) Install Panel + Wings (everything on this VPS)"
echo "  2) Install Panel only"
echo "  3) Install Wings only (node)"
echo "  0) Exit"
echo
read -r -p "Choose [0-3]: " MENU
case "$MENU" in
  1) MODE=1; MODE_NAME="Panel + Wings" ;;
  2) MODE=2; MODE_NAME="Panel only" ;;
  3) MODE=3; MODE_NAME="Wings only" ;;
  *) exit 0 ;;
esac

preflight
[[ "$MODE" != "2" ]] && { wings_check || { [[ "$MODE" == "3" ]] && exit 1; MODE=2; MODE_NAME="Panel only"; }; }
choose_domain
[[ "$MODE" != "3" ]] && panel_questions || { ask_required "Email for SSL notices"; ADMIN_EMAIL="$REPLY_VAL"; }
confirm_summary

case "$MODE" in
  1) install_panel; install_wings; finish_panel ;;
  2) install_panel; finish_panel ;;
  3) install_wings
     echo; ok "Wings installed. Create the node in your panel, paste its config into /etc/pterodactyl/config.yml, then: systemctl enable --now wings" ;;
esac
