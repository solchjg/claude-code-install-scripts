#!/usr/bin/env bash
# ============================================================================
# Claude Code LXC Deployer for Proxmox
# Creates a fully provisioned Ubuntu 26.04 LXC container ready for Claude Code,
# run as ONE normal (non-root) user — one person per container
#
# Run on your Proxmox host:
#   curl -fsSL https://raw.githubusercontent.com/serversathome/ServersatHome/main/agentic.sh -o /tmp/agentic.sh && bash /tmp/agentic.sh
#
# GitHub: https://github.com/serversathome/ServersatHome
#
# How it runs (see main() at the bottom):
#   1. Host side, interactive: ask for the container settings, the root
#      password and the ONE Claude user (name + its own password, sudo y/n).
#   2. Host side, logged to /var/log/agentic-deploy/: create the container,
#      start it, wait for network.
#   3. Inside the container: write a provision script (the big quoted heredoc
#      below) plus a small env file and password file, push them in and run it.
#      It installs the toolchains, sets up the user and Claude Code, the web UI
#      and the update/health tools, logging to /var/log/agentic-provision.log.
#   4. Host side again: write the Proxmox Notes card and print the summary.
#
# Tools left inside the container:
#   agentic-setup-user  set up / repair the Claude user's install (re-runnable)
#   agentic-update      weekly coordinated update (cron, Sunday 4 AM ET)
#   agentic-doctor      health check
#   agentic-errorlog    copies update/health WARN/FAIL lines to Agentic-Errors.txt
#                       (+ optional ntfy push, set in /etc/agentic/ntfy.conf)
#   claude (as root)    a stub that refuses and points at the user
#
# Where things live (inside the container unless noted):
#   /etc/agentic/users.conf      the Claude user and the deploy-time choices the
#                                tools read (agentic-update/-doctor/-setup-user)
#   /etc/agentic/ntfy.conf       ntfy alert settings (root-only, 0600)
#   /usr/local/share/agentic/    shared Claude settings template, shell block and
#                                the staged webapp-testing skill
#   ~USER/.claude/settings.json  the user's Claude Code settings (auto mode + the
#                                deny floor); never overwritten by a re-run
#   /project/CLAUDE.md           what Claude is told about this box
#   ~USER/Agentic-Errors.txt     WARN/FAIL lines from agentic-update/-doctor
#   /var/log/agentic-provision.log, /var/log/agentic-update.log   logs
#   /var/log/agentic-deploy/     on the Proxmox HOST: one log per deploy run
#   Proxmox UI → container → Notes   the notes card (connect, update, health)
# ============================================================================

set -euo pipefail

# ── Colors & Helpers ────────────────────────────────────────────────────────
# ANSI colour codes for the console messages (NC = back to normal).
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Message helpers. error() prints and EXITS, so it is only used to stop the
# run before (or instead of) making a change.
info()    { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# read_password <var> <prompt>
# Reads a password twice (hidden) and only accepts it when both entries match
# and it isn't empty; 3 tries, then abort. The double-underscore locals keep
# them from colliding with the caller's variable name passed in <var>.
read_password() {
  local __var="$1" __prompt="$2" __p1 __p2 __try
  for __try in 1 2 3; do
    read -rsp "$__prompt: " __p1; echo ""
    if [[ -z "$__p1" ]]; then
      warn "Password cannot be empty."; continue
    fi
    read -rsp "Confirm password: " __p2; echo ""
    if [[ "$__p1" == "$__p2" ]]; then printf -v "$__var" '%s' "$__p1"; return 0; fi
    warn "Passwords do not match — try again ($__try/3)."
  done
  error "Password entry failed 3 times; nothing was created."
}

# ── Install log ──────────────────────────────────────────────────────────────
# Everything after the config prompts (all host output plus the full in-container
# provisioning output) is copied to a log on the Proxmox host, so a failed run
# can be analysed after the fact. Passwords are never written to it: they're
# read before logging starts and only travel in 0600 files, never on stdout.
LOG_DIR=/var/log/agentic-deploy
start_logging() {
  mkdir -p "$LOG_DIR"
  DEPLOY_LOG="$LOG_DIR/ct-${CT_ID}-$(date +%Y%m%d-%H%M%S).log"
  ( umask 077; : > "$DEPLOY_LOG" )
  # From here on, all output (stdout + stderr) goes to the screen AND the log;
  # on_exit runs whenever the script ends, on success or failure.
  exec > >(tee -a "$DEPLOY_LOG") 2>&1
  trap on_exit EXIT
  info "Logging this install to $DEPLOY_LOG"
}

# On failure, say where the logs are and pull the container's own log (which
# also holds a command trace of the provision script) next to the host log —
# it survives even if you destroy the half-built container afterwards.
on_exit() {
  local rc=$?
  [[ $rc -eq 0 ]] && return 0
  echo ""
  echo -e "${RED}[ERROR]${NC} Install failed (exit $rc). Host log: $DEPLOY_LOG"
  if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null \
     && pct pull "$CT_ID" /var/log/agentic-provision.log "${DEPLOY_LOG%.log}-provision.log" &>/dev/null; then
    echo -e "${RED}[ERROR]${NC} Container log + trace: ${DEPLOY_LOG%.log}-provision.log"
  fi
  echo "Remove the partial container before retrying: pct stop $CT_ID; pct destroy $CT_ID"
}

header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║        Claude Code LXC Deployer (Proxmox)        ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
preflight() {
  [[ $(id -u) -eq 0 ]] || error "This script must be run as root on the Proxmox host."
  command -v pct   &>/dev/null || error "pct not found. Are you running this on a Proxmox host?"
  command -v pveam &>/dev/null || error "pveam not found. Are you running this on a Proxmox host?"
}

# ── Template Resolution ─────────────────────────────────────────────────────
resolve_template() {
  info "Resolving latest Ubuntu 26.04 LXC template from catalog..."
  pveam update >/dev/null 2>&1 || true
  local found
  # Match the filename by pattern rather than column position: PVE 9.2 added an
  # arch column, and a no-match must not trip set -e/pipefail (#52)
  found=$(pveam available --section system 2>/dev/null \
            | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^ubuntu-26\.04-standard/) print $i}' \
            | sort -V | tail -n1) || true
  if [[ -n "$found" ]]; then
    TEMPLATE="$found"
    success "Using template: $TEMPLATE"
  else
    TEMPLATE="ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
    warn "No 26.04 template found in catalog; using fallback name: $TEMPLATE"
    warn "Verify with: pveam available --section system | grep ubuntu-26.04"
  fi
}

# ── Configuration ───────────────────────────────────────────────────────────
# Asks everything up front (nothing is created until "Proceed? y"), so the rest
# of the run is unattended. Sets the CT_* globals used by every later step.
get_config() {
  # Find next available CT ID
  local next_id
  next_id=$(pvesh get /cluster/nextid 2>/dev/null || echo "100")

  # Resolve newest Ubuntu 26.04 template (sets $TEMPLATE)
  resolve_template

  echo -e "${BOLD}Container Configuration${NC}"
  echo "─────────────────────────────────────────────────"

  read -rp "Container ID [$next_id]: " CT_ID
  CT_ID="${CT_ID:-$next_id}"
  [[ "$CT_ID" =~ ^[0-9]+$ ]] || error "Container ID must be a number."
  # Refuse an ID that is already taken (pct create would fail later anyway).
  pct status "$CT_ID" &>/dev/null && error "Container ID $CT_ID already exists."

  read -rp "Hostname [claude-code]: " CT_HOSTNAME
  CT_HOSTNAME="${CT_HOSTNAME:-claude-code}"

  read_password CT_PASSWORD "Root password"

  # Resources. The defaults (4 cores, 10 GB RAM, 2 GB swap, 30 GB disk) leave
  # room for Docker builds, Playwright and a few Claude sessions at once.
  read -rp "CPU cores [4]: " CT_CORES
  CT_CORES="${CT_CORES:-4}"

  read -rp "RAM in MB [10240]: " CT_RAM
  CT_RAM="${CT_RAM:-10240}"

  read -rp "Swap in MB [2048]: " CT_SWAP
  CT_SWAP="${CT_SWAP:-2048}"

  read -rp "Disk size in GB [30]: " CT_DISK
  CT_DISK="${CT_DISK:-30}"

  # A Proxmox storage ID that can hold container disks (Datacenter → Storage).
  read -rp "Storage [local-lvm]: " CT_STORAGE
  CT_STORAGE="${CT_STORAGE:-local-lvm}"

  # Network - default DHCP
  read -rp "IP address (DHCP or x.x.x.x/xx) [dhcp]: " CT_IP
  CT_IP="${CT_IP:-dhcp}"
  if [[ "$CT_IP" != "dhcp" ]]; then
    read -rp "Gateway: " CT_GW
    [[ -n "$CT_GW" ]] || error "Gateway is required for static IP."
  fi

  read -rp "DNS server [1.1.1.1]: " CT_DNS
  CT_DNS="${CT_DNS:-1.1.1.1}"

  # SSH key (optional) — installed for root and for the Claude user. Password
  # logins stay on for both; a key is what Claude Desktop's SSH sessions need.
  read -rp "Path to SSH public key (optional, press Enter to skip): " CT_SSH_KEY
  if [[ -n "$CT_SSH_KEY" && ! -f "$CT_SSH_KEY" ]]; then
    error "SSH public key not found: $CT_SSH_KEY"
  fi

  # ntfy push alerts (optional). When agentic-update or agentic-doctor hits a
  # WARN/FAIL, agentic-errorlog writes Agentic-Errors.txt as always and, if a
  # topic is set, also sends a short push to the ntfy app on your phone. On a
  # public server anyone who knows the topic name can read (and post to) it,
  # so use a long, random name. Change or turn it off later in
  # /etc/agentic/ntfy.conf.
  read -rp "ntfy topic or topic URL for problem alerts (optional, press Enter to skip): " CT_NTFY_TOPIC
  CT_NTFY_SERVER="https://ntfy.sh" CT_NTFY_TOKEN=""
  if [[ -n "$CT_NTFY_TOPIC" ]]; then
    if [[ "$CT_NTFY_TOPIC" =~ ^https?:// ]]; then
      # A full URL already names the server; keep it whole.
      [[ "$CT_NTFY_TOPIC" =~ ^https?://[^[:space:]/]+/[-_A-Za-z0-9]+$ ]] \
        || error "ntfy topic URL should look like https://ntfy.sh/<topic>: $CT_NTFY_TOPIC"
    else
      # ntfy topic names are letters, digits, - and _ (at most 64).
      [[ "$CT_NTFY_TOPIC" =~ ^[-_A-Za-z0-9]{1,64}$ ]] \
        || error "ntfy topic names use only letters, digits, - and _ (max 64): $CT_NTFY_TOPIC"
      (( ${#CT_NTFY_TOPIC} >= 16 )) \
        || warn "Topic '$CT_NTFY_TOPIC' is short and easy to guess; a long random name is safer."
      read -rp "ntfy server [https://ntfy.sh]: " CT_NTFY_SERVER
      CT_NTFY_SERVER="${CT_NTFY_SERVER:-https://ntfy.sh}"
    fi
    # Only for a server or topic that requires login; typed hidden, like a password.
    read -rsp "ntfy access token (optional, press Enter for none): " CT_NTFY_TOKEN; echo ""
  fi

  # Unprivileged = container root is NOT host root (UIDs are shifted). This is the
  # single biggest hardening step for an LXC that runs an auto-mode agent with
  # Docker access. Answer N only if Docker misbehaves in the unprivileged build.
  read -rp "Unprivileged container (recommended)? [Y/n]: " CT_UNPRIV
  [[ "$CT_UNPRIV" =~ ^[Nn] ]] && CT_UNPRIV=0 || CT_UNPRIV=1

  # The ONE normal (non-root) user that runs Claude Code. Required, no default.
  # One person per container: a container is cheap, and users sharing one would
  # share docker (root-equivalent inside), sudo, /project and the web UI anyway.
  # Created if missing; gets their own Claude Code install, ~/.claude settings/
  # plugins/skills, shell and git config. The CloudCLI web UI runs as this user.
  echo ""
  local u pw _
  CT_USER=""
  for _ in 1 2 3; do
    read -rp "Claude Code user (normal, non-root; required): " u
    if [[ -z "$u" ]]; then
      warn "A normal user is required — Claude Code never runs as root."
    elif ! [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      warn "Invalid username '$u' (lowercase letters, digits, _ and -; start with a letter or _)."
    else
      case "$u" in
        root|docker|agentic|sudo|nobody|daemon|bin|sys|adm|ubuntu)
          warn "'$u' is reserved — pick a normal username." ;;
        *) CT_USER="$u"; break ;;
      esac
    fi
  done
  [[ -n "$CT_USER" ]] || error "No valid user given; nothing was created."
  # Kept as a one-element list so the provisioning loops stay simple.
  CT_USERS=("$CT_USER")
  CT_PRIMARY_USER="$CT_USER"

  # The user's password must differ from root's: root can SSH in with its
  # password, so a shared one would turn a leaked user password into root.
  declare -gA CT_USER_PASSWORDS=()
  pw=""
  for _ in 1 2 3; do
    read_password pw "Password for $CT_USER (must differ from root's)"
    [[ "$pw" != "$CT_PASSWORD" ]] && break
    warn "That's the root password — choose a different one for $CT_USER."
    pw=""
  done
  [[ -n "$pw" ]] || error "No acceptable password for $CT_USER; nothing was created."
  CT_USER_PASSWORDS[$CT_USER]="$pw"

  read -rp "Give $CT_USER sudo (password required)? [Y/n]: " CT_USER_SUDO
  [[ "$CT_USER_SUDO" =~ ^[Nn] ]] && CT_USER_SUDO="no" || CT_USER_SUDO="yes"

  echo ""
  # Everything chosen above, for a last look: nothing on the system has changed
  # yet, and answering anything but y at "Proceed?" leaves it that way.
  echo -e "${BOLD}Summary${NC}"
  echo "─────────────────────────────────────────────────"
  echo "  CT ID:     $CT_ID"
  echo "  Hostname:  $CT_HOSTNAME"
  echo "  Template:  $TEMPLATE"
  echo "  CPU:       $CT_CORES cores"
  echo "  RAM:       $CT_RAM MB ($(( CT_RAM / 1024 )) GB)"
  echo "  Swap:      $CT_SWAP MB"
  echo "  Disk:      ${CT_DISK}G on $CT_STORAGE"
  echo "  Network:   $CT_IP"
  echo "  DNS:       $CT_DNS"
  echo "  Type:      $([[ $CT_UNPRIV -eq 1 ]] && echo unprivileged || echo 'PRIVILEGED (container root = host root)')"
  echo "  User:      $CT_USER (sudo: $CT_USER_SUDO)"
  echo "  SSH:       root + $CT_USER, password$([[ -n "$CT_SSH_KEY" ]] && echo " or key")"
  echo "  Alerts:    Agentic-Errors.txt$([[ -n "$CT_NTFY_TOPIC" ]] && echo " + ntfy push to $CT_NTFY_TOPIC$([[ -n "$CT_NTFY_TOKEN" ]] && echo ' (with token)')")"
  echo "─────────────────────────────────────────────────"
  echo ""
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Download Ubuntu 26.04 Template ─────────────────────────────────────────
get_template() {
  info "Checking for template: $TEMPLATE"
  if ! pveam list local 2>/dev/null | grep -q "$TEMPLATE"; then
    info "Downloading $TEMPLATE ..."
    pveam download local "$TEMPLATE" || error "Failed to download template. Run 'pveam update' and try again."
  else
    success "Template already downloaded: $TEMPLATE"
  fi
  TEMPLATE_PATH="local:vztmpl/$TEMPLATE"
}

# ── Create Container ───────────────────────────────────────────────────────
create_container() {
  info "Creating LXC container $CT_ID..."

  # Build network string
  local net_str="name=eth0,bridge=vmbr0"
  if [[ "$CT_IP" == "dhcp" ]]; then
    net_str+=",ip=dhcp"
  else
    net_str+=",ip=$CT_IP,gw=$CT_GW"
  fi

  # Build pct create command. nesting=1 lets Docker (and systemd services) run
  # inside the container; keyctl=1 is needed by Docker in unprivileged mode.
  # --start 0: we add the AppArmor line below before the first boot.
  # shellcheck disable=SC2054  # the commas in --features are pct syntax, not array separators
  local cmd=(
    pct create "$CT_ID" "$TEMPLATE_PATH"
    --hostname "$CT_HOSTNAME"
    --password "$CT_PASSWORD"
    --cores "$CT_CORES"
    --memory "$CT_RAM"
    --swap "$CT_SWAP"
    --rootfs "$CT_STORAGE:$CT_DISK"
    --net0 "$net_str"
    --nameserver "$CT_DNS"
    --ostype ubuntu
    --unprivileged "$CT_UNPRIV"
    --features nesting=1,keyctl=1
    --onboot 1
    --start 0
  )

  # Add SSH key for root if provided (provisioning adds it for the user too)
  if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then
    cmd+=(--ssh-public-keys "$CT_SSH_KEY")
  fi

  "${cmd[@]}"
  success "Container $CT_ID created."

  # Disable AppArmor for Docker-in-LXC compatibility
  info "Setting AppArmor profile to unconfined (required for Docker)..."
  echo "lxc.apparmor.profile: unconfined" >> "/etc/pve/lxc/${CT_ID}.conf"
}

# ── Start & Wait for Network ──────────────────────────────────────────────
start_container() {
  info "Starting container $CT_ID..."
  pct start "$CT_ID"
  sleep 3

  info "Waiting for network (DNS + outbound HTTPS to github.com)..."
  # Test what provisioning actually needs — name resolution and an outbound TCP
  # connection — rather than ICMP, which some networks block and which proves
  # nothing about DNS. bash's /dev/tcp needs no extra packages in the template.
  local attempts=0
  while ! pct exec "$CT_ID" -- bash -c 'getent hosts github.com >/dev/null && timeout 5 bash -c "exec 3<>/dev/tcp/github.com/443"' &>/dev/null; do
    (( ++attempts ))
    [[ $attempts -lt 30 ]] || error "Container failed to get network after 60s (check DNS '$CT_DNS', the gateway, and bridge vmbr0)."
    sleep 2
  done
  success "Container is online."
}

# ── Provision Container ───────────────────────────────────────────────────
provision_container() {
  info "Provisioning container (this takes a few minutes)..."

  # Write provision script to host, then push into container
  cat > /tmp/provision-${CT_ID}.sh << 'PROVISION_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
# Keep a log inside the container too: all output, plus a command trace (set -x)
# that goes ONLY to the log file (fd 19), not the console. On any failure the ERR
# trap names the line and command. The host pulls this file if provisioning fails.
PROVISION_LOG=/var/log/agentic-provision.log
( umask 077; : > "$PROVISION_LOG" )
exec > >(tee -a "$PROVISION_LOG") 2>&1
exec 19>>"$PROVISION_LOG"
BASH_XTRACEFD=19
trap 'rc=$?; echo "!!! provisioning FAILED (exit $rc) at line $LINENO: $BASH_COMMAND — full log: $PROVISION_LOG"' ERR
set -x
# AGENTIC_USERS / AGENTIC_PRIMARY / AGENTIC_SUDO, pushed in by the host script
source /root/agentic-provision.env
# pct exec hands us the host's LANG (en_US.UTF-8), which doesn't exist in the
# container until we generate it below — every perl/apt call until then spews
# "Setting locale failed". C.UTF-8 is always built in; switch to en_US once it
# exists. Also set a full PATH: pct exec's can lack /usr/local/bin.
export LANG=C.UTF-8
unset LC_ALL LANGUAGE
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo ">>> Waiting for Ubuntu's first-boot apt jobs to finish..."
# A fresh container kicks off apt-daily / unattended-upgrades (and cloud-init,
# when present) right after boot, and they hold the apt/dpkg locks — our first
# apt-get then dies with "Could not get lock /var/lib/apt/lists/lock". Pause the
# timers so nothing new starts mid-provision, wait out a job that really holds
# the apt/dpkg lock, and tell apt itself to wait on a held lock rather than fail.
systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
command -v cloud-init >/dev/null 2>&1 && timeout 120 cloud-init status --wait >/dev/null 2>&1 || true
# Wait only while a process actually HOLDS one of apt/dpkg's lock files. The
# old check matched process NAMES, and 'unattended-upgr' is always running on
# a normal install: unattended-upgrades.service keeps its shutdown helper
# (unattended-upgrade-shutdown --wait-for-signal) alive all day, so every run
# sat out the full 10 minutes for nothing. Now: who holds a lock is printed,
# and after 3 minutes we carry on anyway — apt's own DPkg::Lock::Timeout
# (set just below) then waits for the lock instead of failing.
APT_LOCKS="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock"
apt_lock_holders() {  # PIDs holding an apt/dpkg lock file, one per line
  if command -v fuser >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    fuser $APT_LOCKS 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -u
  else
    # No psmisc: util-linux's lslocks lists the same POSIX locks.
    lslocks -n -r -o PID,PATH 2>/dev/null | awk -v l=" $APT_LOCKS " 'index(l, " " $2 " ") { print $1 }' | sort -u
  fi
}
# Poll every 5 s; print who holds the lock every 30 s; stop waiting at 180 s.
APT_WAITED=0
while APT_HOLDERS="$(apt_lock_holders)" && [ -n "$APT_HOLDERS" ]; do
  if [ "$APT_WAITED" -ge 180 ]; then
    echo "    still locked after 3 minutes; carrying on (apt waits for the lock itself)"
    break
  fi
  if [ $((APT_WAITED % 30)) -eq 0 ]; then
    echo "    waiting for the apt/dpkg lock, held by: $(ps -o pid=,args= -p "$(echo $APT_HOLDERS | tr ' ' ,)" 2>/dev/null | cut -c1-100 | tr '\n' ';')"
  fi
  sleep 5
  APT_WAITED=$((APT_WAITED + 5))
done
if [ "$APT_WAITED" -eq 0 ]; then echo "    no apt/dpkg lock held; continuing"; fi
# Persists, so the weekly agentic-update also waits instead of failing.
cat > /etc/apt/apt.conf.d/99agentic-lock-wait << 'APTLOCK'
DPkg::Lock::Timeout "600";
APTLOCK

echo ">>> Setting timezone to America/New_York..."
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo "America/New_York" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

echo ">>> Generating locale..."
apt-get update -qq
apt-get install -y -qq locales
# Ubuntu 26.04's /etc/locale.gen may not carry a commented en_US line to
# uncomment, so add it when missing — otherwise locale-gen builds nothing and
# en_US.UTF-8 never exists.
sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen
grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
locale-gen > /dev/null 2>&1
# Only the system default changes; this script stays on C.UTF-8. Switching the
# RUNNING shell warned "setlocale: cannot change locale" because apt has just
# upgraded libc underneath it. LC_ALL is left unset on purpose — it overrides
# every other locale setting and isn't meant as a system default.
if locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
  update-locale LANG=en_US.UTF-8
else
  echo "    [WARN] en_US.UTF-8 could not be generated; staying on C.UTF-8"
  update-locale LANG=C.UTF-8
fi

echo ">>> Updating system..."
apt-get upgrade -y -qq

# Base tools: git + downloaders, apt/HTTPS plumbing, shells/editors/terminal
# multiplexers (tmux also gives agent teams split panes), JSON/YAML tools,
# network diagnostics, the SSH server, sudo, and cron/logrotate for the
# weekly agentic-update.
echo ">>> Installing core packages..."
apt-get install -y -qq \
  git curl wget unzip zip \
  ca-certificates gnupg lsb-release apt-transport-https software-properties-common \
  bash-completion locales \
  htop nano vim tmux screen \
  jq yq tree \
  net-tools iproute2 iputils-ping dnsutils \
  openssh-server sudo \
  cron logrotate

# Compilers plus the -dev headers pip/npm/cargo need to build native
# extensions (OpenSSL, libffi, SQLite, zlib, readline, bz2, ncurses, xz, XML).
echo ">>> Installing build tools & dev libraries..."
apt-get install -y -qq \
  build-essential make cmake pkg-config autoconf automake libtool \
  python3 python3-pip python3-venv python3-dev \
  libssl-dev libffi-dev libsqlite3-dev zlib1g-dev \
  libreadline-dev libbz2-dev libncurses-dev liblzma-dev libxml2-dev libxslt-dev

# What Claude Code and you search with. Debian/Ubuntu rename two of them:
# fd is `fdfind` and bat is `batcat`.
echo ">>> Installing search & productivity tools..."
apt-get install -y -qq \
  ripgrep fd-find fzf bat \
  rsync \
  sqlite3

# Clients only (psql, redis-cli; sqlite3 above): no database server is
# installed by this script.
echo ">>> Installing database clients..."
apt-get install -y -qq \
  postgresql-client redis-tools

echo ">>> Installing GitHub CLI (gh)..."
# From GitHub's own apt repository (Ubuntu's archive copy lags behind), so the
# normal apt upgrades — including the weekly agentic-update — keep it current.
# The user signs in later with `gh auth login`; Claude Code uses it to open pull
# requests, and Claude Desktop needs it on this box to do so over SSH.
# Non-fatal: fall back to Ubuntu's package if the GitHub repo can't be reached.
install -d -m 0755 /etc/apt/keyrings
if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
     -o /etc/apt/keyrings/githubcli-archive-keyring.gpg; then
  chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    > /etc/apt/sources.list.d/github-cli.list
  apt-get update -qq
fi
apt-get install -y -qq gh || echo "    [WARN] gh install failed; install later with: sudo apt install gh"
echo "    $(gh --version 2>/dev/null | head -1 || echo 'gh not installed')"

echo ">>> Creating the Claude user ($AGENTIC_USERS)..."
# Claude Code runs as this normal account, never as root. Docker group membership
# and the Claude setup itself come later, from agentic-setup-user, once Docker
# exists.
for u in $AGENTIC_USERS; do
  if id "$u" >/dev/null 2>&1; then
    echo "    $u already exists; keeping it"
  else
    useradd -m -s /bin/bash "$u"
    echo "    created $u"
  fi
  if [ "$AGENTIC_SUDO" = yes ]; then usermod -aG sudo "$u"; fi
done
# user:password lines from the host; deleted the moment they're applied.
chpasswd < /root/agentic-provision.chpasswd
rm -f /root/agentic-provision.chpasswd
# Optional SSH public key from the prompt (root already got it from pct
# create): appended to the user's authorized_keys, with the permissions sshd
# insists on (700 / 600).
if [ -s /root/agentic-provision.pub ]; then
  for u in $AGENTIC_USERS; do
    h="$(getent passwd "$u" | cut -d: -f6)"
    install -d -m 700 -o "$u" -g "$u" "$h/.ssh"
    cat /root/agentic-provision.pub >> "$h/.ssh/authorized_keys"
    chown "$u:$u" "$h/.ssh/authorized_keys"
    chmod 600 "$h/.ssh/authorized_keys"
  done
fi
rm -f /root/agentic-provision.pub
# The Claude user, read by agentic-setup-user / agentic-doctor / agentic-update.
mkdir -p /etc/agentic
cat > /etc/agentic/users.conf << EOF
# The Claude Code user on this box (one per container).
AGENTIC_USERS="$AGENTIC_USERS"
AGENTIC_PRIMARY="$AGENTIC_PRIMARY"
AGENTIC_SUDO="$AGENTIC_SUDO"
EOF
# ntfy push alerts for agentic-errorlog (optional; off while NTFY_TOPIC is
# empty). Root-only (0600) because it can hold an access token. Written when a
# topic was given at the prompt, or as an empty template on a first install so
# alerts can be turned on later; a re-run that skipped the prompt keeps it.
if [ -n "${AGENTIC_NTFY_TOPIC:-}" ] || [ ! -f /etc/agentic/ntfy.conf ]; then
  ( umask 077; cat > /etc/agentic/ntfy.conf << EOF
# ntfy push alerts. agentic-errorlog sends one short push whenever agentic-update
# or agentic-doctor reports a WARN or FAIL (Agentic-Errors.txt is written either
# way). Leave NTFY_TOPIC empty to turn pushes off.
# Test after editing:  sudo agentic-errorlog --test-ntfy
#
# NTFY_TOPIC   topic name, or a full topic URL (https://server/topic). On a public
#              server anyone who knows the name can read it: use a long random
#              one, e.g. claude-alerts-\$(openssl rand -hex 8).
# NTFY_SERVER  server for a bare topic name (default https://ntfy.sh).
# NTFY_TOKEN   access token (tk_...) for a protected server or topic; else empty.
NTFY_TOPIC=$(printf '%q' "${AGENTIC_NTFY_TOPIC:-}")
NTFY_SERVER=$(printf '%q' "${AGENTIC_NTFY_SERVER:-https://ntfy.sh}")
NTFY_TOKEN=$(printf '%q' "${AGENTIC_NTFY_TOKEN:-}")
EOF
  )
fi
rm -f /root/agentic-provision.env

echo ">>> Setting up the shared toolchain environment..."
# Toolchains are installed once, system-wide (root-owned, updated by
# agentic-update); the user's shells and the CloudCLI service point at them. /etc/environment covers PAM logins (SSH,
# su, sudo -i); /etc/profile.d covers login shells; the bashrc block below covers
# `pct enter`.
# For the rest of THIS script: rustup installs into /opt/rust, and its
# cargo/rustc proxies are on PATH for the language-server step below.
export RUSTUP_HOME=/opt/rust/rustup
export CARGO_HOME=/opt/rust/cargo
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
export PATH="/opt/rust/cargo/bin:$PATH"
# Login shells get the shared toolchain locations. CARGO_HOME is deliberately
# NOT set for users (see the Rust step): their crates go to ~/.cargo.
cat > /etc/profile.d/agentic.sh << 'PROFILE'
export RUSTUP_HOME=/opt/rust/rustup
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
export PATH="$PATH:/opt/rust/cargo/bin"
PROFILE
grep -q '^RUSTUP_HOME=' /etc/environment || echo 'RUSTUP_HOME=/opt/rust/rustup' >> /etc/environment
grep -q '^PLAYWRIGHT_BROWSERS_PATH=' /etc/environment || echo 'PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright' >> /etc/environment

echo ">>> Installing Node.js (latest LTS via NodeSource)..."
# setup_lts.x tracks the current LTS line, so fresh deploys get the newest
# *safe* Node automatically (Node 24 today; it rolls to the next LTS on its own
# when one lands — no script edit needed). We deliberately track LTS, not the
# odd/Current line (short-lived, not recommended here). apt upgrades keep it
# patched within the line; a major-version jump stays a deliberate rebuild
# rather than an unattended 4 a.m. surprise.
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt-get install -y -qq nodejs
# Quiet flags reused for every provisioning npm install: drop the funding/audit
# lines and the deprecation warnings that come from these packages' upstream
# transitive deps (not fixable from here). Scoped to provisioning only — your
# own installs under /project behave normally.
NPM_QUIET=(--no-fund --no-audit --loglevel=error)
# Take npm to its own latest release — the bundled npm lags behind and otherwise
# prints an "update available" notice on every install.
npm install -g "${NPM_QUIET[@]}" npm@latest || echo "    [WARN] npm self-update failed; using bundled npm"
echo "    Node.js $(node --version) / npm $(npm --version)"
# npm 12+ blocks dependencies' install scripts behind an allowlist (separate from
# ignore-scripts), so native modules like CloudCLI's better-sqlite3/node-pty/
# bcrypt never compile and the service crash-loops with no bind on :3001. We just
# took npm to latest (>=12), so set the allowlist NOW, before any native install
# below (CloudCLI, Playwright, the language servers). It persists to /root/.npmrc
# under npm 12+; harmless if npm is still <12.
npm config set dangerously-allow-all-scripts true 2>/dev/null || true

echo ">>> Installing global npm packages..."
npm install -g "${NPM_QUIET[@]}" typescript ts-node eslint prettier

echo ">>> Installing Go..."
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
# Go's tarballs are per-architecture; the host arch decides (amd64 or arm64).
GO_ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz
rm -rf /usr/local/go
tar -C /usr/local -xzf /tmp/go.tar.gz
rm /tmp/go.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' >> /etc/profile.d/go.sh
echo "    Go $(/usr/local/go/bin/go version | awk '{print $3}')"

echo ">>> Installing Rust (shared toolchain in /opt/rust)..."
# One system toolchain: rustup keeps toolchains in RUSTUP_HOME
# (/opt/rust/rustup) and its proxies (cargo, rustc, rustup) in /opt/rust/cargo/bin,
# both root-owned and updated by agentic-update. The user does NOT get CARGO_HOME
# set, so they keep the default ~/.cargo for their registry cache and `cargo
# install` output — and Claude can't modify the toolchain itself.
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
chmod -R a+rX /opt/rust
echo "    Rust $(rustc --version | awk '{print $2}')"

echo ">>> Installing Docker..."
curl -fsSL https://get.docker.com | sh
systemctl enable docker
echo "    Docker $(docker --version | awk '{print $3}' | tr -d ',')"

echo ">>> Installing Docker Compose plugin..."
apt-get install -y -qq docker-compose-plugin 2>/dev/null || true
echo "    Compose $(docker compose version --short 2>/dev/null || echo 'included with Docker')"

echo ">>> Writing shared Claude Code defaults (permissions + env + plugins)..."
# Claude Code itself is installed for the user (by agentic-setup-user, below) —
# the native installer puts it in ~/.local/bin and `claude update` must be able
# to write there. The defaults live in /usr/local/share/agentic: the settings
# template ~/.claude/settings.json starts from, the webapp-testing skill, and
# the shell block (used again if you re-run agentic-setup-user).
#
# NOTE on enabledPlugins: we DO declare it here. Earlier belief was that
# enabledPlugins is ignored in non-interactive/container contexts — that's
# wrong. `claude plugin install X@mkt` installs the plugin but leaves it
# Status: disabled; the enabled-state lives in enabledPlugins in THIS file
# (user settings, ~/.claude/settings.json), which IS honored. Without this
# block every plugin below (including the LSP servers) stays disabled and
# CloudCLI's /project chat shows only the 1 local skill. Enabled skills show
# up live after the cloudcli restart — no fresh session needed.
#
# Verified keys (checked against code.claude.com/docs, 2026-10): everything
# below is current. CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS must live inside "env"
# (it's an environment variable, not a top-level key) and agent teams are still
# experimental/opt-in. Dropped on purpose:
#   - CLAUDE_CODE_ENABLE_AUTO_MODE: documented as "accepted for compatibility,
#     no effect" — auto mode works from permissions.defaultMode alone.
#   - MAX_THINKING_TOKENS / alwaysThinkingEnabled: current models (Fable,
#     Opus/Sonnet/Haiku 5.x) use adaptive reasoning; a fixed thinking budget has
#     no effect on them. Use /effort (or "effortLevel") to tune a session.
#   - CLAUDE_CODE_MAX_OUTPUT_TOKENS: per-model defaults beat a blanket cap.
#   - CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: it also turns off feature-flag
#     fetching, which makes Remote Control (/rc) unavailable and stops the
#     background runs of plugin command sources. Not worth it for quiet logs.
#   - "enableRemoteControl": never a real key. Remote Control is enabled with
#     /rc (per session), `claude --rc`, or remoteControlAtStartup via /config.
mkdir -p /usr/local/share/agentic/skills
# Permissions model: auto mode instead of a blanket allow-list.
#   defaultMode "auto" auto-approves actions but routes them through a
#   background safety classifier (still blocks rm -rf / , rm -rf ~ , etc.).
#   defaultMode is honored from USER settings (~/.claude/settings.json) — it is
#   silently ignored if set in a project .claude/settings.json. Running as a
#   normal user also means anything the classifier lets through is bounded by
#   that user's own permissions (plus docker/sudo, if granted).
#   The "deny" list applies in EVERY mode (including auto) and is evaluated
#   before the classifier — it's the hard floor for credentials/secrets.
# Deny-rule syntax (permissions docs):
#   - Read paths: "~/x" = home, "//x" = absolute, "/x" = RELATIVE TO THE
#     SETTINGS FILE'S DIRECTORY (so a single-slash /root/... never matched the
#     real credentials file — that's why the home-anchored forms are used).
#   - sudo/su are denied so Claude never escalates on its own; run admin work
#     yourself (sudo needs your password anyway, which Claude can't type).
#   - Bash: "cmd *" matches the command and its args; "cmd*" (no space) is a
#     prefix match, so "mkfs*" also catches mkfs.ext4 & friends. ("cmd:*" is an
#     accepted alias for "cmd *".) Deny rules don't follow a binary by full path
#     or through `sh -c`; they're a floor, not a sandbox.
# DISABLE_AUTOUPDATER stops Claude's background auto-updater only; we update
# deliberately via `claude update` in agentic-update, which still works.
cat > /usr/local/share/agentic/claude-settings.json << 'SETTINGS'
{
  "$schema": "https://json.schemastore.org/claude-code-settings.json",
  "permissions": {
    "defaultMode": "auto",
    "deny": [
      "Read(**/.env)",
      "Read(**/.env.*)",
      "Read(**/.credentials.json)",
      "Read(~/.claude/.credentials.json)",
      "Read(~/.claude.json)",
      "Read(~/.cloudcli/auth.db)",
      "Read(**/secrets/**)",
      "Read(**/*.pem)",
      "Read(**/id_rsa)",
      "Read(**/id_ed25519)",
      "Bash(dd *)",
      "Bash(mkfs*)",
      "Bash(rm -rf / *)",
      "Bash(rm -rf ~ *)",
      "Bash(sudo *)",
      "Bash(su *)"
    ]
  },
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
    "DISABLE_AUTOUPDATER": "1"
  },
  "enabledPlugins": {
    "code-review@claude-plugins-official": true,
    "commit-commands@claude-plugins-official": true,
    "context7@claude-plugins-official": true,
    "frontend-design@claude-plugins-official": true,
    "security-guidance@claude-plugins-official": true,
    "claude-security@claude-plugins-official": true,
    "modern-web-guidance@claude-plugins-official": true,
    "typescript-lsp@claude-plugins-official": true,
    "pyright-lsp@claude-plugins-official": true,
    "gopls-lsp@claude-plugins-official": true,
    "rust-analyzer-lsp@claude-plugins-official": true,
    "clangd-lsp@claude-plugins-official": true,
    "superpowers@superpowers-marketplace": true,
    "elements-of-style@superpowers-marketplace": true
  }
}
SETTINGS

echo ">>> Installing language servers (backends for the *-lsp plugins)..."
# The *-lsp plugins are thin wrappers that shell out to a language server on
# PATH — they do NOT self-install the binary. Toolchains (Node/Go/Rust) are
# already installed above, so this just adds the servers, system-wide so every
# user's plugins find them. All non-fatal.
# Each line: skip when the server is already on PATH, else install it, else
# only warn (a missing language server just disables that one plugin).
command -v typescript-language-server >/dev/null 2>&1 \
  || npm install -g "${NPM_QUIET[@]}" typescript-language-server typescript \
  || echo "    [WARN] typescript-language-server install failed"
command -v pyright-langserver >/dev/null 2>&1 \
  || npm install -g "${NPM_QUIET[@]}" pyright \
  || echo "    [WARN] pyright install failed"
command -v clangd >/dev/null 2>&1 \
  || apt-get install -y -qq clangd \
  || echo "    [WARN] clangd install failed"
if [ ! -x /usr/local/bin/gopls ] && [ -x /usr/local/go/bin/go ]; then
  GOBIN=/usr/local/bin /usr/local/go/bin/go install golang.org/x/tools/gopls@latest \
    || echo "    [WARN] gopls install failed"
fi
# The symlink points at the real binary inside the shared toolchain, so it works
# without RUSTUP_HOME set (e.g. from the LSP plugin's child process).
if ! command -v rust-analyzer >/dev/null 2>&1 && [ -x /opt/rust/cargo/bin/rustup ]; then
  /opt/rust/cargo/bin/rustup component add rust-analyzer >/dev/null 2>&1 \
    && ln -sf "$(/opt/rust/cargo/bin/rustup which rust-analyzer 2>/dev/null)" /usr/local/bin/rust-analyzer \
    || echo "    [WARN] rust-analyzer install failed"
  chmod -R a+rX /opt/rust
fi

echo ">>> Staging webapp-testing skill (from anthropics/skills)..."
# Installed as a plain user skill (NOT a marketplace plugin). A SKILL.md placed
# under ~/.claude/skills/ is picked up automatically with no plugin entry needed.
# Staged here; agentic-setup-user copies it into the user's ~/.claude/skills.
git clone --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git /tmp/anthropic-skills
cd /tmp/anthropic-skills && git sparse-checkout set skills/webapp-testing
rm -rf /usr/local/share/agentic/skills/webapp-testing
cp -r /tmp/anthropic-skills/skills/webapp-testing /usr/local/share/agentic/skills/webapp-testing
chmod -R a+rX /usr/local/share/agentic
rm -rf /tmp/anthropic-skills
cd /

echo ">>> Installing Playwright (Python) for the webapp-testing skill..."
# The webapp-testing skill imports the PYTHON playwright package
# ("from playwright.sync_api import ..."), so the Node playwright we install for
# CloudCLI's Browser feature is NOT enough — the pip package must be present too,
# or the skill dies at import. pip runs as root here, so the package lands in the
# system site-packages the user imports from. Both share the same browser cache
# — PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright, not root's ~/.cache, so the
# user can launch it — and Chromium is downloaded once for both.
# Playwright supports Ubuntu 26.04 natively since 1.61 (microsoft/playwright#40117
# is closed), so the old PLAYWRIGHT_HOST_PLATFORM_OVERRIDE=ubuntu24.04-x64 hack
# is gone and must not be set — it would pull the wrong browser build. This whole
# block is non-fatal: a browser-install failure must NEVER abort provisioning
# (it previously killed everything after it — Docker services, SSH, cron —
# because the script runs under `set -e`).
# set +e: until the matching set -e below, a failing command doesn't stop the run.
set +e
unset PLAYWRIGHT_HOST_PLATFORM_OVERRIDE
pip install --break-system-packages --root-user-action=ignore -q playwright \
  && echo "    python playwright package installed" \
  || echo "    [WARN] pip install playwright failed (webapp-testing skill will error on import)"
if python3 -m playwright install --with-deps chromium; then
  echo "    Playwright chromium + OS deps installed"
elif python3 -m playwright install chromium; then
  echo "    Playwright chromium installed (browser only; some OS deps may be missing)"
else
  echo "    [WARN] Playwright browser install failed. Retry later with:"
  echo "      sudo PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright python3 -m playwright install --with-deps chromium"
fi
set -e

echo ">>> Setting up /project directory..."
# The Claude user's workspace, owned by them (not root) so Claude can work here.
mkdir -p /project
cat > /project/CLAUDE.md << 'CLAUDEMD'
# Claude Code Workspace

## Environment
- **OS**: Ubuntu 26.04 LXC container on Proxmox
- **Working directory**: /project
- **Timezone**: America/New_York
- **User**: __USERS__ — a normal (non-root) account. Claude Code runs only as this
  user (root is blocked from running it). One person per container.

## Available Tools
- **Languages**: Node.js (latest LTS), Python 3 (system default), Go (latest), Rust (latest)
- **Package managers**: npm (`npm i -g` installs into ~/.local for your user), pip
  (use a venv, or `pip install --user --break-system-packages`), cargo (shared toolchain
  in /opt/rust; your crates go to ~/.cargo), go install (~/go/bin)
- **System packages**: `sudo apt install ...` — run by YOU (if given sudo at deploy);
  Claude is denied sudo/su and should ask you to run admin commands
- **Docker**: Docker Engine + Compose plugin, running and ready; your user is in the
  `docker` group, so no sudo needed
- **Web UI**: CloudCLI UI (claudecodeui) on port 3001 — chat, file explorer/editor, git, shell
  (runs as __PRIMARY__)
- **GitHub CLI**: `gh` (sign in once with `gh auth login`; used for PRs and issues)
- **Search tools**: ripgrep (rg), fd-find (fdfind), fzf
- **Databases**: PostgreSQL client (psql), Redis client (redis-cli), SQLite3

## Permissions
Permission mode is "auto" (permissions.defaultMode in ~/.claude/settings.json).
Actions are auto-approved but pass through a background safety classifier that
still blocks catastrophic commands (rm -rf /, rm -rf ~). A deny floor in
~/.claude/settings.json applies in every mode and blocks reading
credentials/secrets (.env, *.pem, id_rsa, .credentials.json, ~/.claude.json,
the CloudCLI auth DB) — do not try to work around it.

## Agent Teams
Agent teams are enabled (CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1; still
experimental). You can spawn parallel teammates for complex tasks:
- Use agent teams for work that benefits from parallel exploration
- Use subagents (the Agent tool) for quick focused work that reports back
- While teams are enabled, a *named* subagent launches as a teammate — leave
  subagents unnamed when you just want a worker that reports back
- Teammates run in-process by default; tmux is installed, so set
  `"teammateMode": "auto"` in ~/.claude/settings.json for split panes

## Remote Control
Remote Control lets you continue a session running on this box from the Claude
mobile app or claude.ai/code. Turn it on inside a session with `/remote-control`
(`/rc`), start a session with `claude --rc`, or run `claude remote-control` as a
headless server. To connect every session automatically, use `/config` →
"Enable Remote Control for all sessions" (it saves `remoteControlAtStartup` in
~/.claude/settings.json). Requires a claude.ai login (Pro/Max/Team/Enterprise;
API keys don't work), and the first use asks a one-time y/n confirmation, so do
it from an interactive shell.

## Docker Usage
Docker compose files should go in /docker/<service-name>/docker-compose.yml.
There is no always-on Watchtower daemon. Container images are refreshed one-shot
by the weekly `agentic-update` run (or on demand: `sudo agentic-update`), so give
containers you want updated the usual `restart: unless-stopped`.
All Docker containers in this LXC need `security_opt: [apparmor=unconfined]`.

## Conventions
- Prefer creating files over printing long code blocks
- Use git for version control on all projects in /project/src/
- When installing Python packages, prefer a venv (`python3 -m venv .venv`);
  otherwise use: pip install --user --break-system-packages <package>
- Thinking is adaptive on current models (no fixed budget is configured); use
  `/effort` to raise or lower effort for a session

## Installed Plugins / Skills
Plugins are staged via the `claude plugin` CLI at provision time and enabled via
the `enabledPlugins` block in ~/.claude/settings.json. Run `claude plugin list`
to confirm what's active.
- **frontend-design**: Production-grade UI with distinctive aesthetics (auto-activates on frontend tasks)
- **code-review**: Multi-agent PR review with confidence scoring
- **commit-commands**: Git commit, push, and PR workflows (/commit, /push, /pr)
- **security-guidance**: Security warnings when editing sensitive files
- **claude-security**: Deeper security review (/security-review style audits)
- **context7**: Live, version-specific library docs lookup (reduces API hallucinations)
- **modern-web-guidance**: Current web-platform best practices (fetched via npx at query time)
- **typescript-lsp / pyright-lsp / gopls-lsp / rust-analyzer-lsp / clangd-lsp**:
  real-time diagnostics + navigation (backed by the language servers on PATH)
- **superpowers**: Development workflow framework — brainstorm → plan → implement with TDD
  - /superpowers:brainstorm — Refine ideas before coding
  - /superpowers:write-plan — Create implementation plans
  - /superpowers:execute-plan — Execute plans in batches via subagents
  - Auto-activating skills: test-driven-development, systematic-debugging, verification-before-completion
- **elements-of-style**: Writing-style guidance for prose, docs, and commit messages
- **webapp-testing** (local skill, not a marketplace plugin): Playwright-based
  browser testing for UI verification and debugging
CLAUDEMD
sed -i -e "s/__USERS__/${AGENTIC_USERS}/" -e "s/__PRIMARY__/${AGENTIC_PRIMARY}/" /project/CLAUDE.md
chown -R "$AGENTIC_PRIMARY:$AGENTIC_PRIMARY" /project
chmod 755 /project
chmod 644 /project/CLAUDE.md

echo ">>> Configuring SSH..."
# Ubuntu's sshd_config Includes /etc/ssh/sshd_config.d/*.conf from the TOP of the
# file and the FIRST value of a keyword wins, so a drop-in (cloud-init ships one
# with PasswordAuthentication no) silently outranks any edit to the main file.
# Own a drop-in that sorts first instead, and keep the main-file edit for images
# that predate the Include.
# Root and the user may both log in with a password (or a key). MaxAuthTries
# caps guesses per connection.
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
# Claude Desktop's SSH sessions copy files over SFTP; Ubuntu ships the line, but
# make sure it's there.
grep -qE '^[[:space:]]*Subsystem[[:space:]]+sftp' /etc/ssh/sshd_config \
  || echo 'Subsystem sftp /usr/lib/openssh/sftp-server' >> /etc/ssh/sshd_config
if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/00-agentic.conf <<'SSHD'
# Managed by agentic.sh. Sorts before any other drop-in, and sshd keeps the first
# value it sees, so these win over cloud-init's defaults.
PermitRootLogin yes
PasswordAuthentication yes
MaxAuthTries 4
SSHD
  chmod 0644 /etc/ssh/sshd_config.d/00-agentic.conf
fi
# Never restart into a config sshd rejects — that locks the box out of SSH.
if sshd -t 2>/dev/null || /usr/sbin/sshd -t 2>/dev/null; then
  systemctl enable ssh
  systemctl restart ssh || echo "    [WARN] ssh restart failed (check 'journalctl -u ssh')"
else
  echo "    [WARN] sshd config test failed; leaving the running sshd untouched"
fi

echo ">>> Setting up shell environment..."
# One block, appended to root's ~/.bashrc here and to the Claude user's by
# agentic-setup-user (it checks for the header line, so re-runs don't duplicate it).
cat > /usr/local/share/agentic/bashrc << 'BASHRC'

# ── Claude Code Container ──────────────────────────────────
export EDITOR=nano
export LANG=en_US.UTF-8
export TZ=America/New_York
# System-wide toolchains: rustup's toolchains in /opt/rust (your crates stay
# in ~/.cargo) and the Playwright browser cache in /opt/ms-playwright.
export RUSTUP_HOME=/opt/rust/rustup
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
export PATH="$HOME/.local/bin:$HOME/.claude/bin:$HOME/.cargo/bin:/opt/rust/cargo/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"
# Aliases
alias ll="ls -lah --color=auto"
alias cls="clear"
alias ..="cd .."
alias ...="cd ../.."
alias gs="git status"
alias gl="git log --oneline -20"
alias dc="docker compose"
alias dps="docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# Always start in /project
cd /project 2>/dev/null || true
BASHRC
grep -q '── Claude Code Container ──' /root/.bashrc 2>/dev/null \
  || cat /usr/local/share/agentic/bashrc >> /root/.bashrc

echo ">>> Setting up Git defaults..."
# The user's own defaults are set by agentic-setup-user. System-wide, trust
# repos under /project whoever owns them — otherwise git refuses ("dubious
# ownership") when you run git there as root or a repo was created by root.
git config --global init.defaultBranch main
git config --global core.editor nano
git config --global pull.rebase false
git config --system --add safe.directory /project
git config --system --add safe.directory '/project/*'

echo ">>> Installing agentic-setup-user (Claude Code setup for the user)..."
# Everything the user needs to run Claude Code, in a re-runnable tool:
# provisioning runs it below, and `sudo agentic-setup-user` later repairs the
# setup (reinstall Claude, re-add plugins) without touching your settings.
cat > /usr/local/bin/agentic-setup-user << 'ADDUSER'
#!/usr/bin/env bash
# agentic-setup-user [name] — set up (or repair) the box's one Claude user:
# docker(/sudo) groups, their own Claude Code install, the shared settings/
# plugins/skills, shell block, npm and git defaults. Safe to re-run: an existing
# ~/.claude/settings.json and ~/.bashrc block are kept. Single-user by design —
# it refuses a second user; deploy another container for another person.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
SHARE=/usr/local/share/agentic
CONF=/etc/agentic/users.conf
AGENTIC_USERS="" AGENTIC_PRIMARY="" AGENTIC_SUDO="yes"
[ -f "$CONF" ] && source "$CONF"
# The user to set up: the first argument, or the one recorded in users.conf.
# Must be a valid normal user name; root is refused.
u="${1:-$AGENTIC_PRIMARY}"
if ! [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [ "$u" = root ]; then
  echo "usage: agentic-setup-user [username]   (a normal user, not root)" >&2
  exit 1
fi
if [ -n "$AGENTIC_PRIMARY" ] && [ "$u" != "$AGENTIC_PRIMARY" ]; then
  echo "This container is single-user: Claude already runs as '$AGENTIC_PRIMARY'." >&2
  echo "Deploy another container for '$u' instead." >&2
  exit 1
fi

if ! id "$u" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$u"
  echo ">>> [$u] created user (set a password with: sudo passwd $u)"
fi
# docker group = docker without sudo (root-equivalent inside this container).
if getent group docker >/dev/null; then usermod -aG docker "$u"; fi
if [ "$AGENTIC_SUDO" = yes ]; then usermod -aG sudo "$u"; fi
h="$(getent passwd "$u" | cut -d: -f6)"

# Run a command as the user: clean environment (env -i, so nothing of root's
# leaks in, e.g. npm reading /root/.npmrc), their own HOME, the shared toolchain env.
# runuser starts from cwd, which may be /root, so cd home first.
as_user() {
  ( cd "$h" && runuser -u "$u" -- env -i HOME="$h" USER="$u" LOGNAME="$u" \
      LANG=en_US.UTF-8 RUSTUP_HOME=/opt/rust/rustup PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright \
      PATH="$h/.local/bin:$h/.cargo/bin:/opt/rust/cargo/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      "$@" )
}

echo ">>> [$u] npm config..."
# prefix: `npm i -g` as this user lands in ~/.local (already on PATH) instead of
# failing on the root-owned /usr/lib/node_modules. The install-script allowlist
# (npm 12+) is per user too — CloudCLI's in-app plugin installs run as this
# user and need it.
as_user npm config set prefix "$h/.local"
as_user npm config set dangerously-allow-all-scripts true 2>/dev/null || true

echo ">>> [$u] Installing Claude Code (native installer)..."
as_user bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
CLAUDE_BIN="$h/.local/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$h/.claude/bin/claude"
echo "    Claude Code installed: $(as_user "$CLAUDE_BIN" --version 2>/dev/null || echo 'version unknown')"

# ~/.claude is private (it holds the login). The shared settings template is
# copied only when the user has no settings.json yet, so yours is never
# overwritten by a re-run.
install -d -m 700 -o "$u" -g "$u" "$h/.claude"
install -d -o "$u" -g "$u" "$h/.claude/skills"
if [ ! -e "$h/.claude/settings.json" ]; then
  install -m 644 -o "$u" -g "$u" "$SHARE/claude-settings.json" "$h/.claude/settings.json"
fi

echo ">>> [$u] Adding plugin marketplaces..."
# The official marketplace is auto-registered on first INTERACTIVE launch only,
# so a non-interactive provisioning run must add it explicitly. We use ONLY the
# first-party marketplace now — the old 'anthropics/claude-code' demo repo
# (registers as 'claude-code-plugins') ships same-named example copies that
# shadow the official ones, and boxes were silently landing on those.
as_user "$CLAUDE_BIN" plugin marketplace add anthropics/claude-plugins-official \
  || echo "    [WARN] could not add claude-plugins-official"
# Refresh the index BEFORE installing — a stale cache makes name@official
# silently fall through, which is how boxes ended up on demo copies.
as_user "$CLAUDE_BIN" plugin marketplace update claude-plugins-official \
  || echo "    [WARN] could not update claude-plugins-official index"
# Third-party marketplace for Superpowers.
as_user "$CLAUDE_BIN" plugin marketplace add obra/superpowers-marketplace \
  || echo "    [WARN] could not add superpowers-marketplace"

echo ">>> [$u] Installing Claude Code plugins (official CLI)..."
# Install pinned to the official marketplace only (no demo fallthrough).
# Non-fatal — a single failed plugin won't abort provisioning. Enabled-state is
# declared in settings.json (enabledPlugins); install just stages files.
# --yes: a plugin with a marketplace-declared install command would otherwise
# wait on a y/n prompt that this non-interactive run can never answer.
install_plugin() {  # install_plugin <name> <marketplace>
  local ref="$1@$2"
  if as_user "$CLAUDE_BIN" plugin install "$ref" --yes 2>/dev/null; then
    echo "    installed $ref"
  else
    echo "    [WARN] could not install plugin: $ref"
  fi
  return 0
}

# Curated plugins. modern-web-guidance fetches its guides via npx at query time,
# so it needs outbound npm access. LSP plugins give real-time diagnostics +
# navigation; they are thin wrappers around the system-wide language servers
# (one per toolchain this box ships, incl. C/C++ via build-essential).
for p in frontend-design code-review commit-commands security-guidance context7 \
         claude-security modern-web-guidance \
         typescript-lsp pyright-lsp gopls-lsp rust-analyzer-lsp clangd-lsp; do
  install_plugin "$p" claude-plugins-official
done

# Superpowers also appears in the official marketplace, but pinned to a SHA that
# lags upstream — install from Jesse Vincent's own marketplace so the box tracks
# current releases. elements-of-style lives only there (pure markdown).
for p in superpowers elements-of-style; do
  install_plugin "$p" superpowers-marketplace
done

# Sanity check — list what actually landed.
echo ">>> [$u] Installed plugins:"
as_user "$CLAUDE_BIN" plugin list 2>/dev/null || echo "    (plugin list unavailable)"

# ---------------------------------------------------------------------------
# FALLBACK if the above installs don't persist in your Claude Code version:
# The documented container mechanism is CLAUDE_CODE_PLUGIN_SEED_DIR (env-vars
# docs): a read-only directory (":"-separated list) whose marketplaces are
# registered at startup and whose cached plugins are used without re-cloning.
# If `claude plugin list` above is empty after provisioning, stage the plugin
# repos into a seed dir and export CLAUDE_CODE_PLUGIN_SEED_DIR=<dir> in the
# user's ~/.bashrc, or simply run the `claude plugin install` commands above
# once inside an interactive session as that user.
# ---------------------------------------------------------------------------

# The webapp-testing skill (copied once), the shell block (appended once; its
# header line is the marker that prevents duplicates) and git defaults.
echo ">>> [$u] Skills, shell and git defaults..."
if [ -d "$SHARE/skills/webapp-testing" ] && [ ! -e "$h/.claude/skills/webapp-testing" ]; then
  cp -r "$SHARE/skills/webapp-testing" "$h/.claude/skills/webapp-testing"
fi
grep -q '── Claude Code Container ──' "$h/.bashrc" 2>/dev/null \
  || cat "$SHARE/bashrc" >> "$h/.bashrc"
chown -R "$u:$u" "$h/.claude" "$h/.bashrc"
as_user git config --global init.defaultBranch main
as_user git config --global core.editor nano
as_user git config --global pull.rebase false

# Record the user so agentic-doctor / agentic-update cover them.
if [ -z "$AGENTIC_PRIMARY" ]; then
  mkdir -p /etc/agentic
  cat > "$CONF" << EOF
# The Claude Code user on this box (one per container).
AGENTIC_USERS="$u"
AGENTIC_PRIMARY="$u"
AGENTIC_SUDO="$AGENTIC_SUDO"
EOF
fi
echo ">>> [$u] ready — log in as $u and run 'claude' (first run asks you to /login)."
ADDUSER
chmod 755 /usr/local/bin/agentic-setup-user

echo ">>> Setting up Claude Code for $AGENTIC_PRIMARY..."
/usr/local/bin/agentic-setup-user "$AGENTIC_PRIMARY"

echo ">>> Blocking Claude Code for root..."
# Claude is installed only in the user's ~/.local/bin, which comes first on
# their PATH. This wrapper is what root finds instead: it refuses and points at
# the user. A guard rail, not a security boundary — root can do anything — but it
# stops the habit of running an auto-mode agent as root (which would also create
# a second, unmanaged /root/.claude).
cat > /usr/local/bin/claude << CLAUDEWRAP
#!/usr/bin/env bash
if [ "\$(id -u)" -eq 0 ]; then
  echo "claude: not run as root on this box. Use: su - ${AGENTIC_PRIMARY}  (then: claude)" >&2
  exit 1
fi
exec "\$HOME/.local/bin/claude" "\$@"
CLAUDEWRAP
chmod 755 /usr/local/bin/claude
# Paths later steps need: the user's home and their claude binary (the native
# installer uses ~/.local/bin; older installs used ~/.claude/bin).
PRIMARY_HOME="$(getent passwd "$AGENTIC_PRIMARY" | cut -d: -f6)"
PRIMARY_CLAUDE="$PRIMARY_HOME/.local/bin/claude"
[ -x "$PRIMARY_CLAUDE" ] || PRIMARY_CLAUDE="$PRIMARY_HOME/.claude/bin/claude"

echo ">>> Docker ready (no always-on service containers)..."
# code-server was removed — CloudCLI UI (below) already provides a file
# explorer/editor, so it was redundant (and dropped its :8443 + hardcoded
# 'admin' password surface). Watchtower is no longer a scheduled daemon; image
# updates for any containers YOU create now run one-shot from the coordinated
# 'agentic-update' script (see below).

echo ">>> Installing CloudCLI UI (claudecodeui web front end)..."
# Web front end for Claude Code: chat UI, file explorer/editor, git panel, and a
# built-in shell, served on :3001. It runs as the Claude user (never root),
# drives their `claude` and reads their ~/.claude, so it inherits their login
# and auto-mode settings — and its built-in shell is that user's shell.
# It ships with its own login/auth (first-run account setup on the login page);
# create that account right after deploy — until then anyone who reaches :3001
# can claim it. Plain HTTP: keep :3001 on a trusted LAN or behind a TLS proxy.
# Installed from the published npm package (latest, unpinned); the package
# includes a prebuilt server, so there is no client/server build step here.
npm install -g "${NPM_QUIET[@]}" @cloudcli-ai/cloudcli \
  || echo "    [WARN] CloudCLI UI install failed (needs Node 22+ and build tools for node-pty)"
# Self-heal in case the native build was still skipped (better-sqlite3 binding
# missing) — rebuild in place so the service can bind :3001. Gated by the
# allowlist set right after the npm self-update above.
CCUI_PKG="$(npm root -g 2>/dev/null)/@cloudcli-ai/cloudcli"
if [ -d "$CCUI_PKG/node_modules/better-sqlite3" ] && ! ls "$CCUI_PKG/node_modules/better-sqlite3/build/Release/"*.node >/dev/null 2>&1; then
  echo "    rebuilding CloudCLI native modules (better-sqlite3/node-pty/bcrypt)"
  ( cd "$CCUI_PKG" && npm rebuild >/dev/null 2>&1 ) || echo "    [WARN] CloudCLI native rebuild failed"
fi
CCUI_BIN="$(command -v cloudcli || echo /usr/bin/cloudcli)"
install -d -m 700 -o "$AGENTIC_PRIMARY" -g "$AGENTIC_PRIMARY" "$PRIMARY_HOME/.cloudcli"
echo "    CloudCLI UI installed: $("$CCUI_BIN" version 2>/dev/null || echo 'version unknown')"

# Browser feature runtime. CloudCLI detects Playwright via require('playwright')
# from its GLOBAL package dir, but its in-app "Install Runtime" button installs
# into the server's cwd (/project) — which require() can't resolve, so the button
# silently never takes effect. Fix: install Playwright GLOBALLY (resolvable). The
# Chromium build is shared with the Python install above (/opt/ms-playwright),
# so this only downloads if that step failed.
echo ">>> Installing Playwright runtime for CloudCLI Browser feature..."
npm install -g "${NPM_QUIET[@]}" playwright \
  || echo "    [WARN] global Playwright install failed (CloudCLI Browser feature won't work)"
ls -d /opt/ms-playwright/chromium-* >/dev/null 2>&1 \
  || playwright install chromium \
  || echo "    [WARN] Chromium download failed; retry later with: sudo PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright playwright install chromium"
# Browser cache owned by the Claude user, so their own Playwright (a pip --user
# or project install wanting a different browser build) can add to it.
if [ -d /opt/ms-playwright ]; then
  chown -R "$AGENTIC_PRIMARY:$AGENTIC_PRIMARY" /opt/ms-playwright
  chmod -R a+rX /opt/ms-playwright
fi

# systemd unit so the UI survives reboots and restarts on failure.
cat > /etc/systemd/system/cloudcli.service << EOF
[Unit]
Description=CloudCLI UI (claudecodeui) - web front end for Claude Code
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
User=${AGENTIC_PRIMARY}
Environment=NODE_ENV=production
# NODE_ENV=production makes child 'npm install' omit devDependencies, which
# breaks CloudCLI's in-app plugin installs (their 'npm run build' is 'tsc' and
# needs typescript/@types/node). Force npm to include dev deps so plugin builds
# succeed.
Environment=NPM_CONFIG_INCLUDE=dev
Environment=HOME=${PRIMARY_HOME}
# Listen on every interface (LAN access) on :3001; drive this user's claude
# and keep the web UI's own login database in their home.
Environment=HOST=0.0.0.0
Environment=SERVER_PORT=3001
Environment=CLAUDE_CLI_PATH=${PRIMARY_CLAUDE}
Environment=DATABASE_PATH=${PRIMARY_HOME}/.cloudcli/auth.db
Environment=RUSTUP_HOME=/opt/rust/rustup
Environment=PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
Environment=PATH=${PRIMARY_HOME}/.local/bin:${PRIMARY_HOME}/.cargo/bin:/opt/rust/cargo/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=/project
ExecStart=${CCUI_BIN} start
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Load the new unit, start it at every boot, and start it now.
systemctl daemon-reload
systemctl enable cloudcli >/dev/null 2>&1 || true
systemctl start cloudcli \
  || echo "    [WARN] cloudcli service failed to start; check 'journalctl -u cloudcli'"

echo ">>> Installing coordinated update tooling (agentic-update / agentic-doctor / agentic-errorlog)..."
# Single coordinated update pass, modeled on homelabhero's hh-update + hh doctor:
# OS packages -> Rust toolchain -> the user's Claude Code -> CloudCLI
# UI -> one-shot Watchtower for any Docker containers -> restart UI -> health
# check -> log. Both tools run as root (they re-exec through sudo for the user)
# and read the user from /etc/agentic/users.conf. Re-runnable on demand
# ('agentic-update'), no container recreation required. Everything tracks latest
# (unpinned); the post-update health check is the safety net, and results land
# in /var/log/agentic-update.log.

cat > /usr/local/bin/agentic-errorlog << 'ERRLOG'
#!/usr/bin/env bash
# Appends a problem report to Agentic-Errors.txt for each Claude user, so the
# WARN/FAIL results of agentic-update and agentic-doctor don't sit unread in a log,
# and, if set up in /etc/agentic/ntfy.conf, sends a short ntfy push as well.
#   Usage: <problem lines> | agentic-errorlog <source> [log-file [log-label]]
#          agentic-errorlog --test-ntfy   (send a test push)
# The file goes on the user's desktop (the folder xdg-user-dir names, so a
# renamed or translated Desktop works), or in their home folder when there is
# no desktop, which in this container is always. Each entry has a timestamp,
# the failing steps and the last lines of the log; more problems append to the
# same file. Entries older than 90 days are trimmed and the file is capped at
# 256 KB. Delete it once the problems are dealt with; the next problem starts
# a fresh one.
set -uo pipefail
NAME=Agentic-Errors.txt   # file name, on the desktop or in the home folder
KEEP_DAYS=90              # entries older than this are trimmed
MAX_BYTES=262144          # size cap (256 KB); the oldest entries go first
TAIL_LINES=40             # how much of the log each entry quotes

# --append <file>: the half that runs as the user (via runuser below), so the
# file is theirs and root never writes into a folder the user controls.
if [ "${1:-}" = "--append" ]; then
  f="$2"
  # Same "YYYY-MM-DD HH:MM:SS" form as the entry headers, so a plain string
  # comparison tells old from new.
  cutoff="$(date -d "-$KEEP_DAYS days" '+%Y-%m-%d %H:%M:%S')"
  # Add the new entry (from stdin), then rebuild the file trimmed in a temp
  # file next to it and swap it in, so the file is never left half-written.
  cat >> "$f" || exit 1
  tmp="$(mktemp "$f.XXXXXX")" || exit 1
  # Drop entries whose header is older than the cutoff (text above the first
  # entry is kept), then, if still too big, keep the newest whole entries.
  awk -v c="$cutoff" 'BEGIN { keep = 1 } /^===== [0-9][0-9][0-9][0-9]-/ { keep = (($2 " " $3) >= c) } keep' "$f" >"$tmp"
  if [ "$(stat -c %s "$tmp")" -gt "$MAX_BYTES" ]; then
    tail -c "$MAX_BYTES" "$tmp" | awk '/^===== [0-9][0-9][0-9][0-9]-/ { on = 1 } on' >"$tmp.cap" \
      && mv -f "$tmp.cap" "$tmp"
  fi
  # Private to the user, whichever path created the temp file.
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
  exit 0
fi

# Everything below runs as root: it builds the entry once, then hands it to
# each Claude user's --append half above.

[ $# -ge 1 ] || { echo "usage: <problem lines> | agentic-errorlog <source> [log-file [log-label]]  |  agentic-errorlog --test-ntfy" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"

# Optional ntfy push alerts, set at install or in /etc/agentic/ntfy.conf (root-
# only, as it may hold a token). Off while NTFY_TOPIC is empty.
NTFY_TOPIC="" NTFY_SERVER="https://ntfy.sh" NTFY_TOKEN=""
source /etc/agentic/ntfy.conf 2>/dev/null
# ntfy_push <title> <message> — POST to the topic. The token goes to curl on
# stdin (-K -), not on its command line, so other users can't see it in ps.
ntfy_push() {
  local url
  case "$NTFY_TOPIC" in
    http://*|https://*) url="$NTFY_TOPIC" ;;
    *) url="${NTFY_SERVER%/}/$NTFY_TOPIC" ;;
  esac
  if [ -n "$NTFY_TOKEN" ]; then printf 'header = "Authorization: Bearer %s"\n' "$NTFY_TOKEN"; fi \
    | curl -fsS --max-time 20 -K - -o /dev/null -H "Title: $1" -H "Tags: warning" \
        -H "Priority: high" --data-binary "$2" "$url"
}

# --test-ntfy: send a test push so the settings can be checked by hand.
if [ "$1" = "--test-ntfy" ]; then
  [ -n "$NTFY_TOPIC" ] || { echo "ntfy is off: set NTFY_TOPIC in /etc/agentic/ntfy.conf"; exit 1; }
  if ntfy_push "Test from $(hostname)" "agentic-errorlog test: ntfy alerts from $(hostname) are working."; then
    echo "Test push sent to $NTFY_TOPIC"
  else
    echo "Test push to $NTFY_TOPIC failed (check the topic, server and token)"; exit 1
  fi
  exit 0
fi
# source: the tool reporting (agentic-update / agentic-doctor); log-file: the
# log to quote; log-label: how to name it in the entry (default: its path).
SOURCE="$1" LOGFILE="${2:-}" LABEL="${3:-${2:-}}"
AGENTIC_USERS=""
source /etc/agentic/users.conf 2>/dev/null

# One entry: a dated header line (the trimming above keys on it), the problem
# lines, then the tail of the log for context.
# The problem lines (stdin, at most 100) are kept for the ntfy push below too.
PROBLEMS="$(head -n 100)"
ENTRY="$(
  echo "===== $(date '+%Y-%m-%d %H:%M:%S %Z')  $SOURCE on $(hostname) ====="
  echo "Problems (step and message):"
  printf '%s\n' "$PROBLEMS" | sed 's/^/  /'
  if [ -n "$LOGFILE" ] && [ -r "$LOGFILE" ]; then
    echo "Last $TAIL_LINES lines of $LABEL:"
    tail -n "$TAIL_LINES" "$LOGFILE" | sed 's/^/  | /'
  fi
)"

# Every Claude user listed in users.conf gets the entry in their own file.
for u in $AGENTIC_USERS; do
  h="$(getent passwd "$u" | cut -d: -f6)"
  { [ -n "$h" ] && [ -d "$h" ]; } || continue
  # Find the desktop folder as the user sees it: xdg-user-dir reads their
  # ~/.config/user-dirs.dirs; without it, fall back to a plain ~/Desktop.
  # xdg-user-dir prints the home folder itself when no desktop is configured.
  d=""
  if command -v xdg-user-dir >/dev/null 2>&1; then
    d="$(cd "$h" && runuser -u "$u" -- env -i HOME="$h" PATH=/usr/bin:/bin xdg-user-dir DESKTOP 2>/dev/null)"
  elif [ -d "$h/Desktop" ]; then
    d="$h/Desktop"
  fi
  { [ -n "$d" ] && [ -d "$d" ]; } || d="$h"
  # Append as the user (runuser + --append), never as root, so the file is
  # owned by them and a link planted in their folder can't redirect a root write.
  if printf '%s\n\n' "$ENTRY" | (cd "$h" && runuser -u "$u" -- env -i HOME="$h" PATH=/usr/bin:/bin \
      /usr/local/bin/agentic-errorlog --append "$d/$NAME"); then
    echo "    problems noted in $d/$NAME"
  else
    echo "    [WARN] could not write $d/$NAME"
  fi
done
# ntfy: one short push per entry, sent once for the box (not once per user).
# It only says what failed and where to look; the file stays the full record.
if [ -n "$NTFY_TOPIC" ]; then
  n="$(printf '%s\n' "$PROBLEMS" | grep -c .)"
  msg="$n problem(s):
$(printf '%s\n' "$PROBLEMS" | head -n 5)
Details: Agentic-Errors.txt on $(hostname)."
  if ntfy_push "$SOURCE: problems on $(hostname)" "$msg"; then
    echo "    ntfy alert sent"
  else
    echo "    [WARN] ntfy alert to $NTFY_TOPIC failed"
  fi
fi

# Never fail the caller: a missed note must not turn an update into an error.
exit 0
ERRLOG
chmod +x /usr/local/bin/agentic-errorlog

cat > /usr/local/bin/agentic-doctor << 'DOCTOR'
#!/usr/bin/env bash
# Health check for the Claude Code container. Exit 0 = healthy, non-zero = problems.
# Needs root to check the user's home and services; the user runs it via sudo.
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
AGENTIC_USERS="" AGENTIC_PRIMARY=""
source /etc/agentic/users.conf 2>/dev/null
LOG_TAG="[doctor]"
rc=0
check() { if eval "$2" >/dev/null 2>&1; then echo "  OK   $1"; else echo "  FAIL $1"; rc=1; fi; }
# note() is informational only — it never fails the health check. Used for
# user-actionable states (like "not logged in yet") that aren't container faults.
note()  { if eval "$2" >/dev/null 2>&1; then echo "  OK   $1"; else echo "  WARN $1"; fi; }

# The report is captured so its WARN/FAIL lines can be copied to the user's
# Agentic-Errors.txt (agentic-errorlog). A brace group, so rc stays in this shell.
REPORT="$(mktemp)"; trap 'rm -f "$REPORT"' EXIT
{
echo "$LOG_TAG $(date '+%Y-%m-%d %H:%M:%S %Z')"
[ -n "$AGENTIC_USERS" ] || { echo "  FAIL no Claude users in /etc/agentic/users.conf"; rc=1; }
# Per-user checks: claude exists and starts (run as the user with a clean
# environment), settings.json parses, and, informational only, whether
# they have logged in yet.
for u in $AGENTIC_USERS; do
  h="$(getent passwd "$u" | cut -d: -f6)"
  if [ -z "$h" ]; then echo "  FAIL $u: user does not exist"; rc=1; continue; fi
  cb="$h/.local/bin/claude"; [ -x "$cb" ] || cb="$h/.claude/bin/claude"
  check "$u: claude binary present"       "test -x '$cb'"
  check "$u: claude reports a version"    "(cd '$h' && runuser -u '$u' -- env -i HOME='$h' PATH=/usr/local/bin:/usr/bin:/bin '$cb' --version)"
  check "$u: settings.json is valid JSON" "python3 -m json.tool '$h/.claude/settings.json'"
  check "$u: in docker group"             "id -nG '$u' | grep -qw docker"
  note  "$u: claude logged in (creds on disk; run 'claude' /login as $u if WARN)" "test -s '$h/.claude/.credentials.json'"
done
# Shared toolchains and services.
check "shared Rust toolchain"       "RUSTUP_HOME=/opt/rust/rustup /opt/rust/cargo/bin/rustc --version"
check "GitHub CLI (gh) present"     "command -v gh"
check "cloudcli service active"     "systemctl is-active --quiet cloudcli"
check "cloudcli runs as ${AGENTIC_PRIMARY:-<primary>}" "[ \"\$(systemctl show -p User --value cloudcli)\" = '$AGENTIC_PRIMARY' ]"
check "UI listening on :3001"       "ss -ltn | grep -q ':3001'"
check "docker daemon running"       "systemctl is-active --quiet docker"
# Parse df once; an unreadable df is a "can't tell", not a failed box.
DISK_PCT=$(df --output=pcent / 2>/dev/null | tail -1 | tr -dc 0-9)
if [ -n "$DISK_PCT" ]; then
  check "disk under 90% on /"       "[ $DISK_PCT -lt 90 ]"
else
  echo "  WARN could not read disk usage for /"
fi

if [ $rc -eq 0 ]; then echo "$LOG_TAG all checks passed"; else echo "$LOG_TAG one or more checks FAILED"; fi
} >"$REPORT" 2>&1
cat "$REPORT"
# agentic-update sets AGENTIC_NO_ERRORLOG: it files one entry for its whole run.
if [ -z "${AGENTIC_NO_ERRORLOG:-}" ] && grep -qE '^  (WARN|FAIL) ' "$REPORT"; then
  grep -E '^  (WARN|FAIL) ' "$REPORT" | sed 's/^  //' \
    | agentic-errorlog agentic-doctor "$REPORT" "the agentic-doctor report" >/dev/null 2>&1 || true
fi
exit $rc
DOCTOR
chmod +x /usr/local/bin/agentic-doctor

cat > /usr/local/bin/agentic-update << 'UPDATE'
#!/usr/bin/env bash
# Coordinated update pass for the Claude Code container.
#   Run on demand:  agentic-update
#   Runs weekly via /etc/cron.d/agentic-update. Log: /var/log/agentic-update.log
# Deliberately NOT 'set -e': one component failing must not abort the rest.
set -uo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
export DEBIAN_FRONTEND=noninteractive
AGENTIC_USERS=""
source /etc/agentic/users.conf 2>/dev/null
# as_user <user> <cmd...> — run as a Claude user with their own HOME and PATH.
as_user() {
  local u="$1" h; shift
  h="$(getent passwd "$u" | cut -d: -f6)"
  ( cd "$h" && runuser -u "$u" -- env -i HOME="$h" USER="$u" LOGNAME="$u" LANG=en_US.UTF-8 \
      PATH="$h/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" "$@" )
}
LOG=/var/log/agentic-update.log
# Where this run starts in the log, so only its own problems are reported.
LOG_START=$(stat -c %s "$LOG" 2>/dev/null || echo 0)
exec >>"$LOG" 2>&1
echo "==================================================================="
echo ">>> agentic-update starting: $(date '+%Y-%m-%d %H:%M:%S %Z')"

echo ">>> [1/7] OS packages (includes Node.js patches within its LTS line)..."
apt-get update -qq && apt-get upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq \
  || echo "    [WARN] OS package update failed"

echo ">>> [2/7] npm (latest)..."
npm install -g --no-fund --no-audit --loglevel=error npm@latest || echo "    [WARN] npm self-update failed"
# npm 12+ blocks dependencies' install scripts behind an allowlist (separate
# from ignore-scripts), so CloudCLI's native deps (better-sqlite3/node-pty/
# bcrypt) never compile -> cloudcli crash-loops and nothing binds :3001. Boxes
# deploy on npm 10 (builds fine) but this weekly run upgrades npm above, so the
# config MUST be set here -- AFTER npm@latest lands (it only persists to
# /root/.npmrc under npm 12+) and BEFORE the cloudcli reinstall/rebuild below.
# The user gets it too: CloudCLI's in-app plugin installs run as them.
npm config set dangerously-allow-all-scripts true 2>/dev/null || true
for u in $AGENTIC_USERS; do
  as_user "$u" npm config set dangerously-allow-all-scripts true >/dev/null 2>&1 || true
done

echo ">>> [3/7] Rust (shared toolchain in /opt/rust)..."
# CARGO_HOME is set for this one call so rustup updates the shared proxies in
# /opt/rust/cargo; users keep their own ~/.cargo.
if [ -x /opt/rust/cargo/bin/rustup ]; then
  RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo /opt/rust/cargo/bin/rustup update \
    || echo "    [WARN] rustup update failed"
  chmod -R a+rX /opt/rust
else
  echo "    (no shared rustup; skipped)"
fi

echo ">>> [4/7] Claude Code (the user's own install)..."
# `claude update` is the documented manual update path for a native install
# (DISABLE_AUTOUPDATER only stops the background check; `update` still works and
# honors the autoUpdatesChannel / minimumVersion settings). Fall back to
# re-running the installer when claude is missing or too old to have `update`.
# Runs as the user, since the install lives in their ~/.local.
for u in $AGENTIC_USERS; do
  if ! id "$u" >/dev/null 2>&1; then echo "    [WARN] user $u not found; skipped"; continue; fi
  as_user "$u" bash -c 'command -v claude >/dev/null 2>&1 && claude update' \
    || as_user "$u" bash -c 'curl -fsSL https://claude.ai/install.sh | bash' \
    || echo "    [WARN] Claude Code update failed for $u"
  echo "    $u: Claude Code $(as_user "$u" claude --version 2>/dev/null || echo 'version unknown')"
done

echo ">>> [5/7] CloudCLI UI (claudecodeui)..."
npm install -g --no-fund --no-audit --loglevel=error @cloudcli-ai/cloudcli@latest || echo "    [WARN] CloudCLI UI update failed"
# Self-heal: if the native build was skipped (better-sqlite3 binding missing),
# rebuild in place before restart -- else cloudcli loops on "Could not locate
# the bindings file". npm rebuild is itself gated by the config set above.
CCUI_PKG="$(npm root -g 2>/dev/null)/@cloudcli-ai/cloudcli"
if [ -d "$CCUI_PKG/node_modules/better-sqlite3" ] && ! ls "$CCUI_PKG/node_modules/better-sqlite3/build/Release/"*.node >/dev/null 2>&1; then
  echo "    rebuilding CloudCLI native modules (better-sqlite3/node-pty/bcrypt)"
  ( cd "$CCUI_PKG" && npm rebuild >/dev/null 2>&1 ) || echo "    [WARN] CloudCLI native rebuild failed"
fi
systemctl restart cloudcli || echo "    [WARN] cloudcli restart failed"

echo ">>> [6/7] Docker images (one-shot Watchtower)..."
# Watchtower, run once and then removed (--rm): pulls newer images for the
# running containers, recreates them with the same settings, and deletes the
# old images (--cleanup).
if command -v docker >/dev/null 2>&1 && [ -n "$(docker ps -q 2>/dev/null)" ]; then
  docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
    containrrr/watchtower --run-once --cleanup \
    || echo "    [WARN] Watchtower one-shot run failed"
else
  echo "    (no running containers; skipped)"
fi

echo ">>> [7/7] Health check..."
if AGENTIC_NO_ERRORLOG=1 agentic-doctor; then
  echo ">>> agentic-update finished OK: $(date '+%Y-%m-%d %H:%M:%S %Z')"
else
  echo ">>> agentic-update finished WITH HEALTH-CHECK FAILURES: $(date '+%Y-%m-%d %H:%M:%S %Z')"
fi
# Copy this run's [WARN]/FAIL lines, each tagged with its step, to the user's
# Agentic-Errors.txt (agentic-errorlog). A clean run writes nothing.
# awk keeps the current ">>> [n/N]" step header in mind and prints every
# [WARN] / WARN / FAIL line prefixed with that step.
PROBLEMS="$(tail -c +"$((LOG_START + 1))" "$LOG" | awk '
  /^>>> \[[0-9]+\/[0-9]+\]/ { step = $2; next }
  /\[WARN\]|^  (WARN|FAIL) / { sub(/^ +/, ""); print (step ? step " " : "") $0 }')"
if [ -n "$PROBLEMS" ]; then
  printf '%s\n' "$PROBLEMS" | agentic-errorlog agentic-update "$LOG"
fi
echo ""
UPDATE
chmod +x /usr/local/bin/agentic-update

# cron.d format: minute hour day-of-month month day-of-week USER command.
# "0 4 * * 0" = 04:00 every Sunday, run as root.
cat > /etc/cron.d/agentic-update << 'CRON'
# Weekly coordinated update - Sunday 4:00 AM ET
# (OS + Rust + Claude Code + CloudCLI UI + container images,
#  then a health check)
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
0 4 * * 0 root /usr/local/bin/agentic-update
CRON
chmod 0644 /etc/cron.d/agentic-update

# Keep the update log small: rotated monthly, the last 3 kept compressed.
cat > /etc/logrotate.d/agentic-update << 'LOGROTATE'
/var/log/agentic-update.log {
    monthly
    rotate 3
    compress
    missingok
    notifempty
}
LOGROTATE

# Remove packages nothing depends on any more, and apt's downloaded .deb cache.
echo ">>> Cleaning up..."
apt-get autoremove -y -qq
apt-get clean -qq
rm -rf /var/lib/apt/lists/*
# Hand the daily apt timers back now that provisioning is done.
systemctl start apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║              Provisioning Complete!              ║"
echo "╚══════════════════════════════════════════════════╝"
PROVISION_EOF

  # User config for the provision script: names in a sourced env file, passwords
  # as chpasswd lines. Both are written 0600 and removed from the host right after
  # the push; the provision script deletes its copies as soon as they're applied.
  local u
  (
    umask 077
    {
      printf 'AGENTIC_USERS=%q\n' "${CT_USERS[*]}"
      printf 'AGENTIC_PRIMARY=%q\n' "$CT_PRIMARY_USER"
      printf 'AGENTIC_SUDO=%q\n' "$CT_USER_SUDO"
      printf 'AGENTIC_NTFY_TOPIC=%q\n' "$CT_NTFY_TOPIC"
      printf 'AGENTIC_NTFY_SERVER=%q\n' "$CT_NTFY_SERVER"
      printf 'AGENTIC_NTFY_TOKEN=%q\n' "$CT_NTFY_TOKEN"
    } > /tmp/provision-${CT_ID}.env
    for u in "${CT_USERS[@]}"; do
      printf '%s:%s\n' "$u" "${CT_USER_PASSWORDS[$u]}"
    done > /tmp/provision-${CT_ID}.chpasswd
  )
  # Copy the env and password files into the container (still 0600), then
  # delete the host copies straight away.
  pct push "$CT_ID" /tmp/provision-${CT_ID}.env /root/agentic-provision.env --perms 0600
  pct push "$CT_ID" /tmp/provision-${CT_ID}.chpasswd /root/agentic-provision.chpasswd --perms 0600
  rm -f /tmp/provision-${CT_ID}.env /tmp/provision-${CT_ID}.chpasswd
  if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then
    pct push "$CT_ID" "$CT_SSH_KEY" /root/agentic-provision.pub --perms 0600
  fi

  # Push the provision script in and run it inside the container. Its output
  # streams back here, so it lands in the host log too.
  chmod +x /tmp/provision-${CT_ID}.sh
  pct push "$CT_ID" /tmp/provision-${CT_ID}.sh /tmp/provision.sh
  pct exec "$CT_ID" -- chmod +x /tmp/provision.sh
  pct exec "$CT_ID" -- /tmp/provision.sh
  rm -f /tmp/provision-${CT_ID}.sh
}

# ── Write Proxmox Notes ─────────────────────────────────────────────────────
# Drops a Markdown "card" into the container's Notes panel in the Proxmox UI
# (rendered as Markdown on PVE 7+). Uses placeholders so the heredoc can stay
# single-quoted (no accidental expansion of backticks/$ in the Markdown).
write_notes() {
  local ct_ip
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
  ct_ip="${ct_ip:-<container-ip>}"

  local notes
  notes=$(cat <<'EOF'
# 🤖 Claude Code Container

**Web UI (CloudCLI UI):** http://__IP__:3001 — _create a login on first visit_
**SSH:** `ssh __USER__@__IP__`   |   **Console:** `pct enter __CTID__` (root; `su - __USER__`)

## Start Claude Code
Claude runs as **__USER__** only — never root (`claude` refuses to run as root).
Log in as __USER__, then run `claude` (the shell auto-cd's to `/project`).

## Update & health
- `sudo agentic-update` — one coordinated pass: OS → Rust → Claude Code → Web UI → container images → health check
- `sudo agentic-doctor` — run the health check on its own
- Auto-runs weekly (Sunday 4 AM ET). Log: `/var/log/agentic-update.log`
- Any WARN/FAIL from either is also appended to `Agentic-Errors.txt` on __USER__'s home folder; delete it once dealt with
- Optional ntfy phone alerts for the same problems: set `NTFY_TOPIC` in `/etc/agentic/ntfy.conf`, then `sudo agentic-errorlog --test-ntfy`

## Service & config
- `systemctl status cloudcli` — the Web UI service, runs as **__USER__** (`journalctl -u cloudcli` for logs)
- Permissions: **auto mode** + secret/sudo deny-floor — `~/.claude/settings.json`
- Repair the user's Claude setup: `sudo agentic-setup-user`
- Install logs: `/var/log/agentic-deploy/` on the host, `/var/log/agentic-provision.log` here

---
_IP above is the address at deploy time; on DHCP it may change (check with `pct exec __CTID__ -- hostname -I`)._
EOF
)
  # Fill in the placeholders.
  notes=${notes//__IP__/$ct_ip}
  notes=${notes//__CTID__/$CT_ID}
  notes=${notes//__USER__/$CT_PRIMARY_USER}

  # The Notes panel shows the container's description field.
  if pct set "$CT_ID" --description "$notes" >/dev/null 2>&1; then
    success "Wrote container notes to the Proxmox UI."
  else
    warn "Could not set container notes (non-fatal)."
  fi
}

# ── Print Summary ─────────────────────────────────────────────────────────
print_summary() {
  local ct_ip
  ct_ip=$(pct exec "$CT_ID" -- hostname -I 2>/dev/null | awk '{print $1}')

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║              Claude Code LXC Ready!               ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Container:${NC} $CT_ID ($CT_HOSTNAME)"
  echo -e "  ${BOLD}IP:${NC}        ${ct_ip:-pending (DHCP)}"
  echo -e "  ${BOLD}Resources:${NC} ${CT_CORES} CPU / $(( CT_RAM / 1024 )) GB RAM / ${CT_DISK} GB disk"
  echo -e "  ${BOLD}Storage:${NC}   $CT_STORAGE"
  echo -e "  ${BOLD}Timezone:${NC}  America/New_York"
  echo -e "  ${BOLD}User:${NC}      $CT_USER (Claude runs only as this user; sudo: $CT_USER_SUDO)"
  echo -e "  ${BOLD}Security:${NC}  $([[ $CT_UNPRIV -eq 1 ]] && echo 'unprivileged container' || echo 'PRIVILEGED container'); SSH for root + $CT_USER (password$([[ -n "$CT_SSH_KEY" ]] && echo ' or key'))"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  echo -e "    Console: ${CYAN}pct enter $CT_ID${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    SSH:     ${CYAN}ssh ${CT_USER}@${ct_ip}${NC}"
  [[ -n "${ct_ip:-}" ]] && echo -e "    Web UI:  ${CYAN}http://${ct_ip}:3001${NC} (as $CT_USER — ${YELLOW}create its login NOW${NC}; the first visitor claims it)"
  echo ""
  echo -e "  ${BOLD}Start Claude Code:${NC} (as a normal user, not root)"
  echo -e "    ${CYAN}claude${NC}  (shell auto-cd's to /project on login; from the console: ${CYAN}su - $CT_USER${NC})"
  echo ""
  echo -e "  ${BOLD}Verify plugins:${NC} ${CYAN}claude plugin list${NC}"
  echo ""
  echo -e "  ${BOLD}Installed:${NC}"
  echo "    • Claude Code (native)      • Node.js (latest LTS)"
  echo "    • Python 3 + pip + venv     • Go (latest)"
  echo "    • Rust (system, /opt/rust)  • Docker + Compose"
  echo "    • Git + GitHub CLI (gh)     • Build essentials
    • ripgrep, fzf, fd"
  echo "    • PostgreSQL & Redis CLI    • CloudCLI UI web front end (port 3001)"
  echo ""
  echo -e "  ${BOLD}Permissions:${NC} Auto mode (classifier-guarded) + deny floor for secrets and sudo/su"
  echo -e "  ${BOLD}Config:${NC}      ~/.claude/settings.json (template in /usr/local/share/agentic)"
  echo -e "  ${BOLD}Features:${NC}    Agent teams (experimental), adaptive thinking/effort (tune with ${CYAN}/effort${NC})"
  echo -e "  ${BOLD}Remote Control:${NC} ${CYAN}/rc${NC} in a session, ${CYAN}claude --rc${NC}, or all sessions via ${CYAN}/config${NC} (claude.ai login)"
  echo -e "  ${BOLD}Plugins:${NC}     frontend-design, code-review, commit-commands, security-guidance, claude-security,"
  echo -e "               context7, modern-web-guidance, superpowers, elements-of-style,"
  echo -e "               + LSP (typescript/pyright/gopls/rust-analyzer/clangd)"
  echo -e "  ${BOLD}Skills:${NC}      webapp-testing (local, Playwright)"
  echo -e "  ${BOLD}Updates:${NC}     Sundays 4 AM ET — coordinated (OS + Rust + Claude + UI + containers)"
  echo -e "               then a health check. Run anytime: ${CYAN}sudo agentic-update${NC} / ${CYAN}sudo agentic-doctor${NC}"
  echo ""
  echo -e "  ${BOLD}Install logs:${NC}"
  echo -e "    Host:      $DEPLOY_LOG"
  echo -e "    Container: /var/log/agentic-provision.log"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────
# Order matters: logging starts only after the prompts, so passwords typed at
# get_config never reach the log; everything after that is captured.
main() {
  header
  preflight
  get_config
  start_logging
  get_template
  create_container
  start_container
  provision_container
  write_notes
  print_summary
}

main "$@"
