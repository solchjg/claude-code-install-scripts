#!/usr/bin/env bash
# ============================================================================
# Claude Code Deployer for Raspberry Pi 4
# Turns a Raspberry Pi 4 Model B (8 GB) into a fully provisioned Claude Code box, with
# the Claude Desktop app on the Pi's own desktop, run as ONE normal (non-root)
# user — one person per Pi
#
# The Pi counterpart of the Claude Code LXC Deployer for Proxmox: same toolchain,
# same single-user model, same update/health tools — but everything runs
# natively on the Pi's own desktop: no Proxmox, no LXC, and no Docker. Claude
# Code (CLI), Claude Desktop and the dev tools are installed straight onto the
# OS for the one normal user. Run it on the Pi itself, as root:
#   sudo bash Claude_Code_Raspberry_Pi_4_Deployer.sh
#
# Derived from the Raspberry Pi 5 deployer; only the Pi 4 parts differ: no
# page-size switch (the Pi 4 kernel is already 4K), the Pi 4 boot setting
# (arm_boost), the throttling/temperature checks (the Pi 4 soft-throttles at
# 80 °C) and memory tuning for the slower Cortex-A72 (zram swappiness, two
# cargo jobs by default).
#
# Supported OS (64-bit only):
#   - Raspberry Pi OS (64-bit, with desktop) — Debian 12 Bookworm or 13 Trixie.
#     Claude Desktop's arm64 build supports Debian 12+, but Anthropic hasn't
#     officially tested Raspberry Pi OS.
#   - Ubuntu 24.04 / 26.04 Desktop for Raspberry Pi — officially supported by
#     Claude Desktop.
#   "Lite"/Server images work for everything except Claude Desktop, which needs
#   a desktop session. Ubuntu Desktop is the intended target. Boot from a USB 3
#   SSD (blue port) if you can — the Pi 4 has no NVMe slot, and an SD card
#   makes apt, cargo and npm painfully slow.
#
# GitHub: https://github.com/serversathome/ServersatHome
#
# How it runs (see main() at the bottom):
#   1. Interactive: check the Pi/OS, then ask for the hostname, timezone, the
#      root password and the ONE Claude user (an existing account such as the
#      one Raspberry Pi Imager created, or a new one), Claude Desktop y/n and
#      the Pi 4 boot tuning (arm_boost) y/n.
#   2. Logged to /var/log/agentic-deploy/: wait for network, then write a
#      provision script (the big quoted heredoc below) plus a small env file
#      and password file, and run it. It installs the toolchains, sets up the
#      user and Claude Code, Claude Desktop, the web UI and the update/health
#      tools, logging to /var/log/agentic-provision.log.
#   3. Write the box's notes card (/etc/agentic/README.md), print the summary
#      and offer the reboot the boot tweaks need.
#
# Safe to re-run: existing users, settings and shell blocks are kept, and the
# installers skip what's already there — on a failure, fix the cause and run
# it again (there's no container to throw away on a Pi).
#
# Tools left on the Pi:
#   agentic-setup-user  set up / repair the Claude user's install (re-runnable)
#   agentic-update      weekly coordinated update (cron, Sunday 4 AM local time)
#   agentic-doctor      health check (incl. Pi memory/swap/throttling/temperature)
#   agentic-errorlog    copies update/health WARN/FAIL lines to Agentic-Errors.txt
#                       (+ optional ntfy push, set in /etc/agentic/ntfy.conf)
#   claude (as root)    a stub that refuses and points at the user
#
# Where things live:
#   /etc/agentic/users.conf      the Claude user and the deploy-time choices the
#                                tools read (agentic-update/-doctor/-setup-user)
#   /etc/agentic/ntfy.conf       ntfy alert settings (root-only, 0600)
#   /usr/local/share/agentic/    shared Claude settings template, shell block and
#                                the staged webapp-testing skill
#   ~USER/.claude/settings.json  the user's Claude Code settings (auto mode + the
#                                deny floor); never overwritten by a re-run
#   /project/CLAUDE.md           what Claude is told about this box
#   /etc/agentic/README.md       the notes card (copy: ~USER/CLAUDE-PI.md)
#   /etc/sysctl.d/90-agentic-pi4.conf   zram-friendly kernel memory settings
#   Agentic-Errors.txt           WARN/FAIL lines from agentic-update/-doctor, on
#                                the user's desktop (home folder if none)
#   /var/log/agentic-deploy/, /var/log/agentic-provision.log,
#   /var/log/agentic-update.log  logs
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
  error "Password entry failed 3 times; nothing was changed."
}

# is_current_password <user> <password>
# True when <password> is <user>'s current password. Needed because an existing
# account (the Imager-created user) may keep its password, and root's must still
# differ from it. Hashes with the system crypt(3) — libxcrypt on Debian 12+/
# Ubuntu, so yescrypt "$y$" hashes work. The password travels in the
# environment, never on a command line (where `ps` would show it).
is_current_password() {
  local hash
  hash=$(getent shadow "$1" | cut -d: -f2)
  [[ -n "$hash" && "$hash" != [\!*]* ]] || return 1
  PW="$2" H="$hash" perl -e 'exit(crypt($ENV{PW}, $ENV{H}) eq $ENV{H} ? 0 : 1)'
}

# ── Install log ──────────────────────────────────────────────────────────────
# Everything after the config prompts (all deployer output plus the full
# provisioning output) is copied to a log, so a failed run can be analysed
# after the fact. Passwords are never written to it: they're read before
# logging starts and only travel in 0600 files, never on stdout.
LOG_DIR=/var/log/agentic-deploy
start_logging() {
  mkdir -p "$LOG_DIR"
  DEPLOY_LOG="$LOG_DIR/pi-$(date +%Y%m%d-%H%M%S).log"
  ( umask 077; : > "$DEPLOY_LOG" )
  # From here on, all output (stdout + stderr) goes to the screen AND the log;
  # on_exit runs whenever the script ends, on success or failure.
  exec > >(tee -a "$DEPLOY_LOG") 2>&1
  trap on_exit EXIT
  info "Logging this install to $DEPLOY_LOG"
}

# On failure, say where the logs are. The provision log also holds a command
# trace of the provision script. Leftover secret files are removed either way.
on_exit() {
  local rc=$?
  rm -f /root/agentic-provision.env /root/agentic-provision.chpasswd /root/agentic-provision.pub
  [[ $rc -eq 0 ]] && return 0
  echo ""
  echo -e "${RED}[ERROR]${NC} Install failed (exit $rc). Deploy log: $DEPLOY_LOG"
  [[ -s /var/log/agentic-provision.log ]] \
    && echo -e "${RED}[ERROR]${NC} Provision log + trace: /var/log/agentic-provision.log"
  echo "Fix the cause and re-run this script — it is safe to run again."
}

header() {
  echo ""
  echo -e "${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║       Claude Code Deployer (Raspberry Pi 4)       ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
# Hard requirements: root, a 64-bit (arm64) OS, Debian 12+ or Ubuntu 22.04+
# (what Claude Desktop's Linux build supports). Soft ones (warned, not fatal):
# a Pi 4 (or Pi 400), 8 GB RAM, ~25 GB free disk, a 4K-page kernel, booting
# from something faster than SD.
preflight() {
  [[ $(id -u) -eq 0 ]] || error "This script must be run as root on the Pi: sudo bash $0"
  local arch
  arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
  [[ "$arch" == arm64 ]] \
    || error "Needs a 64-bit OS (dpkg arch arm64); this one is '$arch'. Flash Raspberry Pi OS (64-bit)."

  # shellcheck disable=SC1091
  source /etc/os-release
  VERSION_ID="${VERSION_ID:-0}"   # Debian testing/sid has none
  case "${ID:-}" in
    debian|raspbian)
      [[ "${VERSION_ID%%.*}" -ge 12 ]] 2>/dev/null \
        || error "Debian ${VERSION_ID:-?} is too old; Claude Desktop needs Debian 12 (Bookworm) or later."
      if [[ -f /etc/rpi-issue ]] || dpkg -s raspberrypi-sys-mods &>/dev/null; then
        PI_OS="Raspberry Pi OS (Debian ${VERSION_ID} ${VERSION_CODENAME:-})"
      else
        PI_OS="Debian ${VERSION_ID} ${VERSION_CODENAME:-}"
      fi
      ;;
    ubuntu)
      [[ "${VERSION_ID%%.*}" -ge 22 ]] 2>/dev/null \
        || error "Ubuntu ${VERSION_ID:-?} is too old; Claude Desktop needs 22.04 or later."
      PI_OS="Ubuntu ${VERSION_ID}"
      ;;
    *) error "Unsupported OS '${ID:-unknown}'. Use Raspberry Pi OS (64-bit) or Ubuntu for Raspberry Pi." ;;
  esac

  # Board name from the device tree (e.g. "Raspberry Pi 5 Model B Rev 1.0");
  # tr strips the NUL byte the kernel ends it with.
  PI_MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "unknown board")
  # Matches "Raspberry Pi 4 Model B" and "Raspberry Pi 400". A Pi 5 has its own deployer.
  [[ "$PI_MODEL" == *"Raspberry Pi 4"* ]] \
    || warn "This is a '$PI_MODEL', not a Raspberry Pi 4 — continuing, but this script is tuned for a Pi 4 (use the Pi 5 deployer on a Pi 5)."
  # Usable RAM in MB (MemTotal reads a little under the board's nominal size).
  PI_RAM_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  (( PI_RAM_MB >= 7000 )) \
    || warn "Only ${PI_RAM_MB} MB RAM. The full toolchain + Claude Desktop is sized for 8 GB; expect swapping."
  # Free space on / in GB, and the device / lives on (/dev/mmcblk* = SD card).
  PI_DISK_FREE_GB=$(( $(df --output=avail -k / | tail -1) / 1024 / 1024 ))
  (( PI_DISK_FREE_GB >= 25 )) \
    || warn "Only ${PI_DISK_FREE_GB} GB free on /. The full install needs ~15 GB; leave room for projects."
  PI_ROOT_DEV=$(findmnt -no SOURCE / 2>/dev/null || echo "?")
  [[ "$PI_ROOT_DEV" != /dev/mmcblk* ]] \
    || warn "Running from an SD card ($PI_ROOT_DEV). It works, but a USB 3 SSD is many times faster for this workload."
  # Every Pi 4 kernel (Raspberry Pi OS kernel8.img, Ubuntu's raspi kernel) uses
  # 4K pages, so there is nothing to switch — unlike the Pi 5's 16K default.
  # Only a hand-built kernel would differ; jemalloc tools (Claude Code's bundled
  # ripgrep, some Rust tools) crash on non-4K pages, so say so.
  # Kernel memory page size: 4096, or 16384 on Raspberry Pi OS's Pi 5 kernel.
  PI_PAGESIZE=$(getconf PAGESIZE)
  [[ "$PI_PAGESIZE" -eq 4096 ]] \
    || warn "This kernel uses ${PI_PAGESIZE}-byte pages; Pi 4 kernels normally use 4K. Some arm64 tools crash on it — go back to the stock kernel."
}

# ── Configuration ───────────────────────────────────────────────────────────
# Asks everything up front (nothing is changed until "Proceed? y"), so the rest
# of the run is unattended. Sets the PI_* / CT_* globals used by every later
# step (CT_* names kept from the Proxmox deployer so the shared parts line up).
get_config() {
  echo -e "${BOLD}Pi Configuration${NC}"
  echo "─────────────────────────────────────────────────"

  local cur_host
  cur_host=$(hostname)
  read -rp "Hostname [$cur_host]: " CT_HOSTNAME
  CT_HOSTNAME="${CT_HOSTNAME:-$cur_host}"
  [[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
    || error "Invalid hostname '$CT_HOSTNAME'."

  # Keep the zone Raspberry Pi Imager / raspi-config set; a Pi still on UTC
  # defaults to America/New_York like the Proxmox deployer.
  local cur_tz
  cur_tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)
  [[ "$cur_tz" == UTC || "$cur_tz" == Etc/UTC ]] && cur_tz="America/New_York"
  read -rp "Timezone [$cur_tz]: " CT_TZ
  CT_TZ="${CT_TZ:-$cur_tz}"
  [[ -f "/usr/share/zoneinfo/$CT_TZ" ]] || error "Unknown timezone '$CT_TZ' (see: timedatectl list-timezones)."

  read_password CT_PASSWORD "Root password (console + SSH)"

  # SSH key (optional) — installed for root and for the Claude user. Password
  # logins stay on for both; a key is what Claude Desktop's SSH sessions from
  # another computer need.
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
  read -rp "ntfy topic or topic URL for problem alerts (optional; Enter skips, and keeps any current setting): " CT_NTFY_TOPIC
  # Defaults. An empty topic means no push alerts, and the provision step
  # then keeps any /etc/agentic/ntfy.conf from an earlier run unchanged.
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

  # The ONE normal (non-root) user that runs Claude Code. Defaults to whoever
  # ran sudo — usually the account Raspberry Pi Imager created, which is also
  # the one the Pi's desktop logs in as, so Claude Desktop runs there too.
  # Created if missing; gets their own Claude Code install, ~/.claude settings/
  # plugins/skills, shell and git config. The CloudCLI web UI runs as this user.
  echo ""
  local u pw _ def_user=""
  [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]] && def_user="$SUDO_USER"
  CT_USER=""
  for _ in 1 2 3; do
    read -rp "Claude Code user (normal, non-root; required)${def_user:+ [$def_user]}: " u
    u="${u:-$def_user}"
    if [[ -z "$u" ]]; then
      warn "A normal user is required — Claude Code never runs as root."
    elif ! [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
      warn "Invalid username '$u' (lowercase letters, digits, _ and -; start with a letter or _)."
    else
      case "$u" in
        root|agentic|sudo|nobody|daemon|bin|sys|adm|kvm)
          warn "'$u' is reserved — pick a normal username." ;;
        *)
          if id "$u" &>/dev/null && (( $(id -u "$u") < 1000 )); then
            warn "'$u' is a system account — pick a normal username."
          else
            CT_USER="$u"; break
          fi ;;
      esac
    fi
  done
  [[ -n "$CT_USER" ]] || error "No valid user given; nothing was changed."
  # Kept as a one-element list so the provisioning loops stay simple.
  CT_USERS=("$CT_USER")
  CT_PRIMARY_USER="$CT_USER"
  # New or existing account? That decides the password and sudo questions below.
  id "$CT_USER" &>/dev/null && CT_USER_EXISTS=yes || CT_USER_EXISTS=no

  # The user's password must differ from root's: root can SSH in with its
  # password, so a shared one would turn a leaked user password into root.
  # An existing user may keep their password — as long as it isn't root's new one.
  declare -gA CT_USER_PASSWORDS=()
  local setpw=yes
  if [[ "$CT_USER_EXISTS" == yes ]]; then
    read -rp "$CT_USER exists. Set a new password for $CT_USER? [y/N]: " setpw
    if [[ "$setpw" =~ ^[Yy] ]]; then
      setpw=yes
    # (Next test: a shadow hash that is empty or starts with ! or * means the
    # account has no usable password yet.)
    elif ! [[ "$(getent shadow "$CT_USER" | cut -d: -f2)" =~ ^[^!*] ]]; then
      warn "$CT_USER has no usable password yet — set one now."; setpw=yes
    elif is_current_password "$CT_USER" "$CT_PASSWORD"; then
      warn "$CT_USER's current password is the root password you just chose — set a different one for $CT_USER."
      setpw=yes
    else
      setpw=no
    fi
  fi
  if [[ "$setpw" == yes ]]; then
    pw=""
    for _ in 1 2 3; do
      read_password pw "Password for $CT_USER (must differ from root's)"
      [[ "$pw" != "$CT_PASSWORD" ]] && break
      warn "That's the root password — choose a different one for $CT_USER."
      pw=""
    done
    [[ -n "$pw" ]] || error "No acceptable password for $CT_USER; nothing was changed."
    CT_USER_PASSWORDS[$CT_USER]="$pw"
  fi

  # An existing sudoer keeps sudo (removing it could lock you out of your Pi).
  if [[ "$CT_USER_EXISTS" == yes ]] && id -nG "$CT_USER" | grep -qw sudo; then
    CT_USER_SUDO="yes"
    info "$CT_USER already has sudo; keeping it."
  else
    read -rp "Give $CT_USER sudo (password required)? [Y/n]: " CT_USER_SUDO
    [[ "$CT_USER_SUDO" =~ ^[Nn] ]] && CT_USER_SUDO="no" || CT_USER_SUDO="yes"
  fi

  # Raspberry Pi OS: the Imager user gets passwordless sudo. Offer to require
  # the password, so "sudo needs your password, which Claude can't type" holds.
  CT_FIX_NOPASSWD="no"
  if grep -qsE "^[[:space:]]*${CT_USER}[[:space:]].*NOPASSWD" /etc/sudoers.d/* 2>/dev/null; then
    local ans
    warn "$CT_USER has passwordless sudo (Raspberry Pi OS default)."
    read -rp "Make sudo ask $CT_USER for a password (recommended for an auto-mode agent)? [Y/n]: " ans
    [[ "$ans" =~ ^[Nn] ]] || CT_FIX_NOPASSWD="yes"
    if [[ "$CT_FIX_NOPASSWD" == yes && "$setpw" != yes ]]; then
      info "sudo will use $CT_USER's existing login password."
    fi
  fi

  # Claude Desktop: the Linux beta's arm64 .deb from Anthropic's apt repo.
  # Needs the Pi's desktop to launch; on Lite it's installed but idle.
  echo ""
  # Either session folder counts (ls needed BOTH to match, so an X11-only or
  # Wayland-only desktop was wrongly reported as missing).
  # compgen -G <glob> prints the matching files and succeeds only when at
  # least one exists; unlike ls, an empty or missing folder is not an error.
  if compgen -G '/usr/share/wayland-sessions/*.desktop' >/dev/null || compgen -G '/usr/share/xsessions/*.desktop' >/dev/null; then
    PI_HAS_DESKTOP=yes
  else
    PI_HAS_DESKTOP=no
    warn "No desktop environment found (Lite/Server image). Claude Desktop needs one to launch."
  fi
  read -rp "Install Claude Desktop (Chat + Code, Linux beta; no Cowork)? [$([[ $PI_HAS_DESKTOP == yes ]] && echo Y/n || echo y/N)]: " CT_DESKTOP
  if [[ "$PI_HAS_DESKTOP" == yes ]]; then
    [[ "$CT_DESKTOP" =~ ^[Nn] ]] && CT_DESKTOP="no" || CT_DESKTOP="yes"
  else
    [[ "$CT_DESKTOP" =~ ^[Yy] ]] && CT_DESKTOP="yes" || CT_DESKTOP="no"
  fi

  # Pi 4 boot tuning: arm_boost=1 in config.txt's [pi4] section lets rev 1.4+
  # boards (all 8 GB ones) run at 1.8 GHz instead of 1.5 GHz — the stock,
  # warrantied clock, not an overclock. Raspberry Pi OS and recent Ubuntu images
  # already set it; we only add it when missing. Needs a reboot to apply.
  local ans
  read -rp "Apply Pi 4 boot tuning (arm_boost=1, 1.8 GHz; only if not set; needs a reboot)? [Y/n]: " ans
  [[ "$ans" =~ ^[Nn] ]] && CT_BOOT_TUNE="no" || CT_BOOT_TUNE="yes"

  echo ""
  # Everything chosen above, for a last look: nothing on the system has changed
  # yet, and answering anything but y at "Proceed?" leaves it that way.
  echo -e "${BOLD}Summary${NC}"
  echo "─────────────────────────────────────────────────"
  echo "  Board:     $PI_MODEL"
  echo "  OS:        $PI_OS"
  echo "  RAM:       ${PI_RAM_MB} MB"
  echo "  Disk:      ${PI_DISK_FREE_GB} GB free on $PI_ROOT_DEV"
  echo "  Hostname:  $CT_HOSTNAME"
  echo "  Timezone:  $CT_TZ"
  echo "  User:      $CT_USER ($([[ $CT_USER_EXISTS == yes ]] && echo existing || echo new); sudo: $CT_USER_SUDO$([[ $CT_FIX_NOPASSWD == yes ]] && echo ', password now required'))"
  echo "  Password:  $([[ -n "${CT_USER_PASSWORDS[$CT_USER]:-}" ]] && echo "new for $CT_USER" || echo "$CT_USER keeps theirs"); root password set"
  echo "  SSH:       root + $CT_USER, password$([[ -n "$CT_SSH_KEY" ]] && echo " or key")"
  echo "  Alerts:    Agentic-Errors.txt$([[ -n "$CT_NTFY_TOPIC" ]] && echo " + ntfy push to $CT_NTFY_TOPIC$([[ -n "$CT_NTFY_TOKEN" ]] && echo ' (with token)')")"
  echo "  Desktop:   Claude Desktop $([[ $CT_DESKTOP == yes ]] && echo 'yes (Chat + Code; Cowork left out)' || echo no)"
  echo "  Kernel:    ${PI_PAGESIZE}-byte pages"
  echo "  Boot:      $([[ $CT_BOOT_TUNE == yes ]] && echo 'arm_boost=1 under [pi4] (if missing)' || echo 'config.txt left as is')"
  echo "─────────────────────────────────────────────────"
  echo ""
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Hostname ────────────────────────────────────────────────────────────────
# Only touched when you changed it at the prompt. /etc/hosts keeps the Debian
# 127.0.1.1 line in step, or sudo complains "unable to resolve host".
apply_hostname() {
  [[ "$CT_HOSTNAME" != "$(hostname)" ]] || return 0
  info "Setting hostname to $CT_HOSTNAME..."
  hostnamectl set-hostname "$CT_HOSTNAME"
  if grep -q '^127\.0\.1\.1' /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$CT_HOSTNAME/" /etc/hosts
  else
    printf '127.0.1.1\t%s\n' "$CT_HOSTNAME" >> /etc/hosts
  fi
  success "Hostname set (reachable as $CT_HOSTNAME.local via mDNS on most LANs)."
}

# ── Wait for Network ──────────────────────────────────────────────────────
wait_network() {
  info "Checking network (DNS + outbound HTTPS to github.com)..."
  # Test what provisioning actually needs — name resolution and an outbound TCP
  # connection — rather than ICMP, which some networks block and which proves
  # nothing about DNS. bash's /dev/tcp needs no extra packages. A Pi on Wi-Fi
  # right after boot can take a moment to associate.
  local attempts=0
  while ! { getent hosts github.com >/dev/null && timeout 5 bash -c 'exec 3<>/dev/tcp/github.com/443'; } &>/dev/null; do
    (( ++attempts ))
    [[ $attempts -lt 30 ]] || error "No network after 60s (check Wi-Fi/Ethernet, DNS and the gateway)."
    sleep 2
  done
  success "Pi is online."
}

# ── Provision the Pi ──────────────────────────────────────────────────────
provision_pi() {
  info "Provisioning the Pi (this takes a while on a Pi — 40-90 min from a USB 3 SSD, longer from SD)..."

  # Write the provision script to /root, then run it with a clean environment
  # (like `pct exec` gave the LXC): nothing of your sudo session leaks in.
  ( umask 077; cat > /root/agentic-provision.sh ) << 'PROVISION_EOF'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
# Keep a provisioning log too: all output, plus a command trace (set -x) that
# goes ONLY to the log file (fd 19), not the console. On any failure the ERR trap
# names the line and command. The deployer points at this file if provisioning fails.
PROVISION_LOG=/var/log/agentic-provision.log
( umask 077; : > "$PROVISION_LOG" )
exec > >(tee -a "$PROVISION_LOG") 2>&1
exec 19>>"$PROVISION_LOG"
BASH_XTRACEFD=19
trap 'rc=$?; echo "!!! provisioning FAILED (exit $rc) at line $LINENO: $BASH_COMMAND — full log: $PROVISION_LOG"' ERR
set -x
# AGENTIC_USERS / AGENTIC_PRIMARY / AGENTIC_SUDO / AGENTIC_NEWUSER / AGENTIC_TZ /
# AGENTIC_DESKTOP / AGENTIC_BOOT_TUNE / AGENTIC_FIX_NOPASSWD / AGENTIC_OS, written by
# the deployer from its prompts
source /root/agentic-provision.env
# sudo/ssh may hand us a LANG (from your workstation or the Imager settings)
# that isn't generated on the Pi yet — every perl/apt call until then spews
# "Setting locale failed". C.UTF-8 is always built in; the system default is
# only touched below. Also set a full PATH: sudo's secure_path can lack
# /usr/local/sbin on some images.
export LANG=C.UTF-8
unset LC_ALL LANGUAGE
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo ">>> Waiting for first-boot apt jobs to finish..."
# A freshly flashed Pi kicks off apt-daily / unattended-upgrades (and cloud-init
# on Ubuntu) right after the first boot, and they hold the apt/dpkg locks — our first
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
# The four lock files apt and dpkg take: lock-frontend (any apt/dpkg front
# end), lock (the dpkg database), lists/lock (apt update) and archives/lock
# (package downloads). A process holding any of them means apt is busy.
APT_LOCKS="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock"
# fuser prints the PIDs that have a file open (the file names go to stderr,
# which is discarded); the grep keeps only the numbers. lslocks is the
# fallback when psmisc (fuser) isn't installed.
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

echo ">>> Setting timezone to $AGENTIC_TZ..."
# Chosen at the prompt (defaults to what Raspberry Pi Imager already set, or
# America/New_York when the Pi is still on UTC). The weekly update runs at 4 AM
# in this zone.
ln -sf "/usr/share/zoneinfo/$AGENTIC_TZ" /etc/localtime
echo "$AGENTIC_TZ" > /etc/timezone
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
# A locale you picked in Raspberry Pi Imager / raspi-config (say en_GB.UTF-8)
# is kept; only an unset or C/POSIX default is switched to en_US.UTF-8.
CUR_LANG="$(sed -n 's/^LANG=//p' /etc/default/locale 2>/dev/null | tr -d '"' | head -1)"
if [ -n "$CUR_LANG" ] && ! [[ "$CUR_LANG" =~ ^(C|POSIX|C\.UTF-8)$ ]]; then
  echo "    keeping system locale $CUR_LANG"
elif locale -a 2>/dev/null | grep -qiE '^en_US\.utf-?8$'; then
  update-locale LANG=en_US.UTF-8
else
  echo "    [WARN] en_US.UTF-8 could not be generated; staying on C.UTF-8"
  update-locale LANG=C.UTF-8
fi

echo ">>> Updating system..."
# full-upgrade, not upgrade: Raspberry Pi OS ships kernel/firmware/bootloader
# updates as package changes that a plain upgrade holds back (Raspberry Pi's
# own docs say to use full-upgrade).
apt-get full-upgrade -y -qq

# Base tools: git + downloaders, apt/HTTPS plumbing, shells/editors/terminal
# multiplexers (tmux also gives agent teams split panes), JSON/YAML tools,
# network diagnostics, the SSH server, sudo, and cron/logrotate for the
# weekly agentic-update.
echo ">>> Installing core packages..."
apt-get install -y -qq \
  git curl wget unzip zip \
  ca-certificates gnupg lsb-release apt-transport-https \
  bash-completion locales \
  htop nano vim tmux screen \
  jq yq tree \
  net-tools iproute2 iputils-ping dnsutils \
  openssh-server sudo \
  cron logrotate
# Debian 13 (Raspberry Pi OS Trixie) dropped software-properties-common
# (add-apt-repository); Ubuntu still has it. Nice to have, never required.
apt-get install -y -qq software-properties-common 2>/dev/null || true
# vcgencmd, for agentic-doctor's throttling check. Raspberry Pi OS ships it
# (raspi-utils); on Ubuntu it's libraspberrypi-bin (newer releases: raspi-utils).
command -v vcgencmd >/dev/null 2>&1 \
  || apt-get install -y -qq libraspberrypi-bin 2>/dev/null \
  || apt-get install -y -qq raspi-utils 2>/dev/null \
  || echo "    [WARN] vcgencmd not available; agentic-doctor will only read the temperature"

echo ">>> Pi 4 memory & boot tuning..."
# 8 GB is plenty for one person, but Rust builds + rust-analyzer + a browser +
# Claude Desktop (and Ubuntu's GNOME desktop itself) can spike past it. Compressed swap in RAM (zram, zstd) absorbs
# those spikes far better than swapping to an SD card. Raspberry Pi OS Trixie
# already sets up zram (rpi-swap) and Ubuntu may have its own; only add
# zram-tools when no zram swap is active.
if swapon --noheadings --show=NAME 2>/dev/null | grep -q zram; then
  echo "    zram swap already active; keeping it"
elif apt-get install -y -qq zram-tools; then
  cat > /etc/default/zramswap << 'ZRAM'
# Managed by the Claude Code Pi deployer: zram swap sized at 50% of RAM.
ALGO=zstd
PERCENT=50
PRIORITY=100
ZRAM
  systemctl restart zramswap 2>/dev/null || true
  echo "    zram swap (zstd, 50% of RAM) enabled"
else
  echo "    [WARN] zram-tools install failed; running without compressed swap"
fi
# The Pi 4's Cortex-A72 cores and slower storage make swap-to-disk stalls far
# worse than on a Pi 5, so lean on zram: with swap in RAM, swapping out cold
# pages early is cheap (swappiness 100) and reading one page at a time beats
# readahead (page-cluster 0). Lower dirty limits keep big writes (cargo, npm)
# from freezing the desktop while a slow SD/USB drive catches up. Only applied
# when the active swap is zram; a disk swap keeps the kernel defaults.
if swapon --noheadings --show=NAME 2>/dev/null | grep -q zram; then
  cat > /etc/sysctl.d/90-agentic-pi4.conf << 'SYSCTL'
# Managed by the Claude Code Pi 4 deployer: tuning for zram swap on a Pi 4.
vm.swappiness=100
vm.page-cluster=0
vm.dirty_background_ratio=5
vm.dirty_ratio=10
SYSCTL
  sysctl -q -p /etc/sysctl.d/90-agentic-pi4.conf || true
  echo "    zram sysctl tuning applied (/etc/sysctl.d/90-agentic-pi4.conf)"
else
  echo "    no zram swap active; leaving vm.* sysctls at their defaults"
fi
# Pi 4 boot setting: arm_boost=1 under [pi4] runs rev 1.4+ boards at their
# rated 1.8 GHz (older boards ignore it). Raspberry Pi OS and recent Ubuntu
# images set it already; we add it only when no arm_boost line exists, with a
# backup. No kernel change: Pi 4 kernels already use 4K pages. Answered at the
# prompt.
BOOTFW=/boot/firmware
[ -f "$BOOTFW/config.txt" ] || BOOTFW=/boot
REBOOT_NEEDED=no
if [ "$AGENTIC_BOOT_TUNE" = yes ]; then
  if [ ! -f "$BOOTFW/config.txt" ]; then
    echo "    [WARN] no config.txt in /boot/firmware or /boot; boot tuning skipped"
  elif grep -qE '^[[:space:]]*arm_boost=' "$BOOTFW/config.txt"; then
    echo "    arm_boost already set in $BOOTFW/config.txt; keeping it"
  else
    cp -a "$BOOTFW/config.txt" "$BOOTFW/config.txt.agentic-bak"
    printf '\n# Claude Code Pi 4 deployer: rated 1.8 GHz on rev 1.4+ boards\n[pi4]\narm_boost=1\n[all]\n' \
      >> "$BOOTFW/config.txt"
    REBOOT_NEEDED=yes
    echo "    arm_boost=1 added under [pi4] in $BOOTFW/config.txt (backup: config.txt.agentic-bak)"
  fi
fi

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
# The user signs in later with `gh auth login`; Claude Code (CLI and the Code
# tab of Claude Desktop, locally or over SSH from another machine) uses it to
# open pull requests.
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

echo ">>> Setting up the Claude user ($AGENTIC_USERS)..."
# Claude Code runs as this normal account, never as root. On a Pi it is usually
# the account Raspberry Pi Imager created (kept as-is, groups and all); a new
# one is created with the groups a desktop login on a Pi needs. The Claude
# setup itself comes later, from agentic-setup-user, once the toolchains exist.
for u in $AGENTIC_USERS; do
  if id "$u" >/dev/null 2>&1; then
    echo "    $u already exists; keeping it"
  else
    useradd -m -s /bin/bash "$u"
    for g in video render audio input plugdev netdev gpio i2c spi dialout; do
      if getent group "$g" >/dev/null; then usermod -aG "$g" "$u"; fi
    done
    echo "    created $u"
  fi
  # An existing sudoer is never removed from sudo here — on a Pi that account is
  # often the only admin, and dropping it would lock you out.
  if [ "$AGENTIC_SUDO" = yes ]; then usermod -aG sudo "$u"; fi
done
# user:password lines from the deployer (root's, plus the user's when it was
# set); deleted the moment they're applied.
chpasswd < /root/agentic-provision.chpasswd
rm -f /root/agentic-provision.chpasswd
# Raspberry Pi OS gives the Imager-created user passwordless sudo
# (/etc/sudoers.d/010_pi-nopasswd). With that, an auto-mode agent is one
# full-path `sudo` away from root — the deny rules don't follow full paths.
# Answered at the prompt (default yes): from now on sudo asks for the password,
# which Claude can't type.
if [ "$AGENTIC_FIX_NOPASSWD" = yes ]; then
  # For each sudoers drop-in that gives the user NOPASSWD: back it up, strip
  # the NOPASSWD: tag, and keep the edit only if visudo still accepts the file
  # (a broken sudoers file would lock everyone out of sudo).
  for f in /etc/sudoers.d/*; do
    [ -f "$f" ] || continue
    for u in $AGENTIC_USERS; do
      if grep -qE "^[[:space:]]*${u}[[:space:]].*NOPASSWD" "$f"; then
        cp -a "$f" "/root/$(basename "$f").agentic-bak"
        sed -i -E "s/^([[:space:]]*${u}[[:space:]].*)NOPASSWD:[[:space:]]*/\1/" "$f"
        if visudo -cf "$f" >/dev/null; then
          echo "    $u: sudo now asks for a password (was NOPASSWD in $f; backup in /root)"
        else
          cp -a "/root/$(basename "$f").agentic-bak" "$f"
          echo "    [WARN] edited $f failed visudo; restored it unchanged"
        fi
      fi
    done
  done
fi
# Optional SSH public key from the prompt: added once to root's and the
# user's authorized_keys, with the permissions sshd insists on (700 / 600).
if [ -s /root/agentic-provision.pub ]; then
  # Root gets the key too (the Proxmox deployer set it at container creation).
  install -d -m 700 /root/.ssh
  grep -qxF "$(cat /root/agentic-provision.pub)" /root/.ssh/authorized_keys 2>/dev/null \
    || cat /root/agentic-provision.pub >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  for u in $AGENTIC_USERS; do
    h="$(getent passwd "$u" | cut -d: -f6)"
    install -d -m 700 -o "$u" -g "$u" "$h/.ssh"
    grep -qxF "$(cat /root/agentic-provision.pub)" "$h/.ssh/authorized_keys" 2>/dev/null \
      || cat /root/agentic-provision.pub >> "$h/.ssh/authorized_keys"
    chown "$u:$u" "$h/.ssh/authorized_keys"
    chmod 600 "$h/.ssh/authorized_keys"
  done
fi
rm -f /root/agentic-provision.pub
# The Claude user, read by agentic-setup-user / agentic-doctor / agentic-update.
mkdir -p /etc/agentic
cat > /etc/agentic/users.conf << EOF
# The Claude Code user on this Pi (one per box).
AGENTIC_USERS="$AGENTIC_USERS"
AGENTIC_PRIMARY="$AGENTIC_PRIMARY"
AGENTIC_SUDO="$AGENTIC_SUDO"
AGENTIC_DESKTOP="$AGENTIC_DESKTOP"
EOF
# ntfy push alerts for agentic-errorlog (optional; off while NTFY_TOPIC is
# empty). Root-only (0600) because it can hold an access token. Written when a
# topic was given at the prompt, or as an empty template on a first install so
# alerts can be turned on later; a re-run that skipped the prompt keeps it.
# printf %q (below) quotes each value, so the file stays safe to `source`
# even if a value has spaces or shell characters in it.
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
# terminals opened on the Pi's desktop.
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
# Re-runs: once NodeSource's repo and nodejs are in place, skip the repo setup
# (and the npm self-update below) — patch updates come from apt and the weekly
# agentic-update.
# NODE_FRESH=yes only when Node was installed just now; it decides below
# whether npm is taken to its latest release (later runs leave that to
# agentic-update).
if command -v node >/dev/null 2>&1 && ls /etc/apt/sources.list.d/nodesource.* >/dev/null 2>&1; then
  NODE_FRESH=no
  echo "    Node.js already installed from NodeSource; skipping repo setup"
else
  NODE_FRESH=yes
  curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
  apt-get install -y -qq nodejs
fi
# Quiet flags reused for every provisioning npm install: drop the funding/audit
# lines and the deprecation warnings that come from these packages' upstream
# transitive deps (not fixable from here). Scoped to provisioning only — your
# own installs under /project behave normally.
NPM_QUIET=(--no-fund --no-audit --loglevel=error)
# Take npm to its own latest release — the bundled npm lags behind and otherwise
# prints an "update available" notice on every install.
# Only on a fresh Node install; agentic-update keeps npm current after that.
if [ "$NODE_FRESH" = yes ]; then
  npm install -g "${NPM_QUIET[@]}" npm@latest || echo "    [WARN] npm self-update failed; using bundled npm"
fi
echo "    Node.js $(node --version) / npm $(npm --version)"
# npm 12+ blocks dependencies' install scripts behind an allowlist (separate from
# ignore-scripts), so native modules like CloudCLI's better-sqlite3/node-pty/
# bcrypt never compile and the service crash-loops with no bind on :3001. We just
# took npm to latest (>=12), so set the allowlist NOW, before any native install
# below (CloudCLI, Playwright, the language servers). It persists to /root/.npmrc
# under npm 12+; harmless if npm is still <12.
npm config set dangerously-allow-all-scripts true 2>/dev/null || true

echo ">>> Installing global npm packages..."
# Only what's missing, so a re-run doesn't reinstall all of them.
# `npm ls -g --depth=0 <pkg>` exits non-zero when <pkg> isn't installed
# globally, so the list ends up holding only the missing ones.
NPM_MISSING=()
for pkg in typescript ts-node eslint prettier; do
  npm ls -g --depth=0 "$pkg" >/dev/null 2>&1 || NPM_MISSING+=("$pkg")
done
if [ ${#NPM_MISSING[@]} -gt 0 ]; then
  npm install -g "${NPM_QUIET[@]}" "${NPM_MISSING[@]}"
else
  echo "    already installed; skipping"
fi

echo ">>> Installing Go..."
GO_VERSION=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -1)
# Go's tarballs are per-architecture; the host arch decides (amd64 or arm64).
GO_ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
# Re-runs: keep /usr/local/go when it's already the latest release.
# go.dev/VERSION returns e.g. "go1.27.3", the same form `go env GOVERSION`
# prints, so the two compare directly; no go binary yet = no match = install.
if [ "$(/usr/local/go/bin/go env GOVERSION 2>/dev/null)" = "$GO_VERSION" ]; then
  echo "    $GO_VERSION already installed; skipping download"
else
  curl -fsSL "https://go.dev/dl/${GO_VERSION}.linux-${GO_ARCH}.tar.gz" -o /tmp/go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm /tmp/go.tar.gz
fi
# Written, not appended, so re-runs don't stack duplicate PATH lines.
echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
echo "    Go $(/usr/local/go/bin/go version | awk '{print $3}')"

echo ">>> Installing Rust (shared toolchain in /opt/rust)..."
# One system toolchain: rustup keeps toolchains in RUSTUP_HOME
# (/opt/rust/rustup) and its proxies (cargo, rustc, rustup) in /opt/rust/cargo/bin,
# both root-owned and updated by agentic-update. The user does NOT get CARGO_HOME
# set, so they keep the default ~/.cargo for their registry cache and `cargo
# install` output — and Claude can't modify the toolchain itself.
# Re-runs: rustup is already there; agentic-update runs `rustup update`.
if [ -x /opt/rust/cargo/bin/rustup ]; then
  echo "    shared rustup already installed; skipping"
else
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path
  chmod -R a+rX /opt/rust
fi
echo "    Rust $(rustc --version | awk '{print $2}')"

# No Docker on this box, by design: Claude and everything it builds run
# natively on the Pi's OS as the one user — no containers. That also frees the
# daemon's RAM. Services a project needs (PostgreSQL, Redis, ...) are installed
# with apt and run as normal systemd services.

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
#   that user's own permissions (plus sudo, if granted — which asks for a
#   password Claude can't type).
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
# USE_BUILTIN_RIPGREP=0 makes Claude Code use the system ripgrep (apt, above)
# instead of its bundled arm64 build, whose jemalloc crashes on a 16K-page
# kernel and silently drops custom slash commands
# (anthropics/claude-code#9462, closed "not planned"). Harmless on 4K.
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
    "DISABLE_AUTOUPDATER": "1",
    "USE_BUILTIN_RIPGREP": "0"
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
# Playwright publishes linux-arm64 Chromium builds for Ubuntu and Debian
# (Raspberry Pi OS reports itself as Debian). PLAYWRIGHT_HOST_PLATFORM_OVERRIDE
# must not be set — it would pull the wrong (x64) browser build. This whole
# block is non-fatal: a browser-install failure must NEVER abort provisioning
# (it previously killed everything after it — SSH, the web UI, cron —
# because the script runs under `set -e`).
# set +e: until the matching set -e below, a failing command doesn't stop the run.
set +e
unset PLAYWRIGHT_HOST_PLATFORM_OVERRIDE
# Re-runs: skip when the package imports and its Chromium is already in the
# shared cache (pip without -U never changes the version, so they still match).
# Skip only when BOTH are there: the pip package imports AND a Chromium
# build is in the shared cache. If either is missing, the install below runs.
if python3 -c 'import playwright' >/dev/null 2>&1 && ls -d /opt/ms-playwright/chromium-* >/dev/null 2>&1; then
  echo "    python playwright + chromium already installed; skipping"
else
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
fi
set -e

echo ">>> Setting up /project directory..."
# The Claude user's workspace, owned by them (not root) so Claude can work here.
mkdir -p /project
cat > /project/CLAUDE.md << 'CLAUDEMD'
# Claude Code Workspace

## Environment
- **Machine**: Raspberry Pi 4 (8 GB RAM, 4× Cortex-A72 @ 1.5–1.8 GHz, arm64) running __OS__
- **Working directory**: /project
- **Timezone**: __TZ__
- **User**: __USERS__ — a normal (non-root) account. Claude Code runs only as this
  user (root is blocked from running it). One person per Pi.

## Available Tools
- **Languages**: Node.js (latest LTS), Python 3 (system default), Go (latest), Rust (latest)
- **Package managers**: npm (`npm i -g` installs into ~/.local for your user), pip
  (use a venv, or `pip install --user --break-system-packages`), cargo (shared toolchain
  in /opt/rust; your crates go to ~/.cargo), go install (~/go/bin)
- **System packages**: `sudo apt install ...` — run by YOU (if given sudo at deploy);
  Claude is denied sudo/su and should ask you to run admin commands
- **No containers**: there is no Docker/LXC here — everything runs natively on the
  Pi as __PRIMARY__. Need a database server? Ask the user to `sudo apt install
  postgresql` (or redis-server) and use it as a normal systemd service
- **Web UI**: CloudCLI UI (claudecodeui) on port 3001 — chat, file explorer/editor, git, shell
  (runs as __PRIMARY__)
- **Claude Desktop** (if installed): the Linux desktop app (Chat and Code) on
  the Pi's own desktop, signed in as __PRIMARY__; updated by apt. Cowork is
  deliberately not set up here (it needs a VM), so its tab reports missing QEMU
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

## Raspberry Pi 4 limits (8 GB)
- CPU and memory are the constraints: builds and tests take 2–3× as long as on
  a laptop. Prefer ONE agent at a time; at most two parallel teammates.
- Rust builds already default to two jobs (CARGO_BUILD_JOBS=2); use `-j1` if the
  box still swaps hard. Give long builds/tests generous timeouts.
- Stop dev servers and watchers you no longer need (`npm run dev`, `cargo watch`).
- Close the Playwright browser when a test run is done.
- Check health with `sudo agentic-doctor` (memory, swap, throttling, temperature).

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
sed -i -e "s/__USERS__/${AGENTIC_USERS}/" -e "s/__PRIMARY__/${AGENTIC_PRIMARY}/g" \
       -e "s|__OS__|${AGENTIC_OS}|" -e "s|__TZ__|${AGENTIC_TZ}|" /project/CLAUDE.md
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
# Managed by the Claude Code Pi deployer. Sorts before any other drop-in, and sshd keeps the first
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

# ── Claude Code Pi ─────────────────────────────────────────
export EDITOR=nano
# System-wide toolchains: rustup's toolchains in /opt/rust (your crates stay
# in ~/.cargo) and the Playwright browser cache in /opt/ms-playwright.
export RUSTUP_HOME=/opt/rust/rustup
export PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
# Pi 4: two parallel rustc jobs, not four — four A72 cores compiling at once
# can need more RAM than 8 GB and swap hard. Override per build with -j.
export CARGO_BUILD_JOBS=2
export PATH="$HOME/.local/bin:$HOME/.claude/bin:$HOME/.cargo/bin:/opt/rust/cargo/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"
# Aliases
alias ll="ls -lah --color=auto"
alias cls="clear"
alias ..="cd .."
alias ...="cd ../.."
alias gs="git status"
alias gl="git log --oneline -20"

# Always start in /project
cd /project 2>/dev/null || true
BASHRC
grep -q '── Claude Code Pi ──' /root/.bashrc 2>/dev/null \
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
# sudo group, their own Claude Code install, the shared settings/
# plugins/skills, shell block, npm and git defaults. Safe to re-run: an existing
# ~/.claude/settings.json and ~/.bashrc block are kept. Single-user by design —
# it refuses a second user; use another Pi (or the Proxmox deployer) for another person.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
SHARE=/usr/local/share/agentic
CONF=/etc/agentic/users.conf
AGENTIC_USERS="" AGENTIC_PRIMARY="" AGENTIC_SUDO="yes" AGENTIC_DESKTOP="no"
[ -f "$CONF" ] && source "$CONF"
# The user to set up: the first argument, or the one recorded in users.conf.
# Must be a valid normal user name; root is refused.
u="${1:-$AGENTIC_PRIMARY}"
if ! [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || [ "$u" = root ]; then
  echo "usage: agentic-setup-user [username]   (a normal user, not root)" >&2
  exit 1
fi
if [ -n "$AGENTIC_PRIMARY" ] && [ "$u" != "$AGENTIC_PRIMARY" ]; then
  echo "This Pi is single-user: Claude already runs as '$AGENTIC_PRIMARY'." >&2
  echo "Set up another machine for '$u' instead." >&2
  exit 1
fi

if ! id "$u" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$u"
  echo ">>> [$u] created user (set a password with: sudo passwd $u)"
fi
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
CLAUDE_BIN="$h/.local/bin/claude"
[ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$h/.claude/bin/claude"
# Re-runs: a working install is kept (agentic-update runs `claude update`);
# a missing or broken one is (re)installed.
# Running --version as the user proves the binary exists AND starts; a
# half-finished or broken install fails this test and is reinstalled.
if as_user "$CLAUDE_BIN" --version >/dev/null 2>&1; then
  echo "    already installed; skipping the installer"
else
  as_user bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
  CLAUDE_BIN="$h/.local/bin/claude"
  [ -x "$CLAUDE_BIN" ] || CLAUDE_BIN="$h/.claude/bin/claude"
fi
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
grep -q '── Claude Code Pi ──' "$h/.bashrc" 2>/dev/null \
  || cat "$SHARE/bashrc" >> "$h/.bashrc"
chown -R "$u:$u" "$h/.claude" "$h/.bashrc"
as_user git config --global init.defaultBranch main
as_user git config --global core.editor nano
as_user git config --global pull.rebase false

# Record the user so agentic-doctor / agentic-update cover them.
if [ -z "$AGENTIC_PRIMARY" ]; then
  mkdir -p /etc/agentic
  cat > "$CONF" << EOF
# The Claude Code user on this Pi (one per box).
AGENTIC_USERS="$u"
AGENTIC_PRIMARY="$u"
AGENTIC_SUDO="$AGENTIC_SUDO"
AGENTIC_DESKTOP="${AGENTIC_DESKTOP:-no}"
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

# code-server is not installed — CloudCLI UI (below) already provides a file
# explorer/editor, and Claude Desktop's Code tab covers the desktop.

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
# Re-runs: skip when it's already installed; agentic-update moves it to latest.
# Same `npm ls` test as the global npm packages. The native-module
# self-heal below runs either way, so a skipped install still gets repaired.
if npm ls -g --depth=0 @cloudcli-ai/cloudcli >/dev/null 2>&1; then
  echo "    already installed; skipping (agentic-update keeps it current)"
else
  npm install -g "${NPM_QUIET[@]}" @cloudcli-ai/cloudcli \
    || echo "    [WARN] CloudCLI UI install failed (needs Node 22+ and build tools for node-pty)"
fi
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
npm ls -g --depth=0 playwright >/dev/null 2>&1 \
  || npm install -g "${NPM_QUIET[@]}" playwright \
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
After=network-online.target
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

if [ "$AGENTIC_DESKTOP" = yes ]; then
  echo ">>> Installing Claude Desktop (Linux beta, arm64)..."
  # From Anthropic's apt repository, as documented at
  # code.claude.com/docs/en/desktop-linux, so updates arrive with normal apt
  # upgrades (and the weekly agentic-update). The key is checked against
  # Anthropic's published fingerprint before the repo is trusted. The app
  # refuses to run as root; it runs in the Pi's desktop session as the Claude
  # user. Non-fatal.
  # Cowork is left out on purpose — nothing on this Pi runs in a container or
  # VM. claude-desktop only *Recommends* Cowork's VM stack (qemu-system-arm,
  # qemu-efi-aarch64, virtiofsd), so an apt pin (priority -1 = never install)
  # blocks those packages; every other Recommends, like the gnome-keyring that
  # remembers the sign-in, still installs, and no kvm group or vhost_vsock
  # module is set up. The Cowork tab then just reports "Cowork requires QEMU";
  # Chat and Code work.
  # Why a pin and not apt's "qemu-system-arm-" exclusion: Raspberry Pi OS has
  # armhf enabled as a second architecture, and an exclusion only covers the
  # arm64 package — apt then satisfied the Recommends with qemu-system-arm:armhf
  # and ~300 armhf libraries. ":any" makes the pin cover every architecture,
  # and because it's a file in preferences.d it also holds for later upgrades.
  # The pin, field by field: Package = the names to block (globs allowed;
  # ':any' = every architecture); 'Pin: release *' = from every repository;
  # Pin-Priority -1 = never install, not as a Recommends and not on upgrade.
  cat > /etc/apt/preferences.d/agentic-no-cowork-vm << 'PIN'
# Managed by the Claude Code Pi deployer: no Cowork VM stack (QEMU) on this box.
# Delete this file if you ever want to install QEMU yourself.
Package: qemu-system*:any qemu-efi*:any qemu-utils:any qemu-block-extra:any virtiofsd:any
Pin: release *
Pin-Priority: -1
PIN
  # A run of the earlier version of this script already installed the armhf
  # QEMU stack; remove it (its armhf libraries go in the autoremove at the end).
  # dpkg-query prints each matching package with its state; only the ones
  # actually 'installed' are purged (leftover config-only entries are skipped).
  CD_VM_PKGS=$(dpkg-query -W -f='${db:Status-Status} ${binary:Package}\n' \
      'qemu-system*' 'qemu-efi*' qemu-utils qemu-block-extra virtiofsd 2>/dev/null \
    | awk '$1=="installed"{print $2}' || true)
  if [ -n "$CD_VM_PKGS" ]; then
    echo "    removing a previously installed QEMU stack: $(echo $CD_VM_PKGS)"
    # shellcheck disable=SC2086
    apt-get purge -y -qq $CD_VM_PKGS || echo "    [WARN] could not remove the QEMU packages"
  fi
  # Download Anthropic's signing key, and trust the repo only if the key's
  # fingerprint matches the one published in the Linux install docs.
  CD_KEY=/usr/share/keyrings/claude-desktop-archive-keyring.asc
  CD_FPR=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
  if curl -fsSLo "$CD_KEY" https://downloads.claude.ai/claude-desktop/key.asc \
     && [ "$(gpg --show-keys --with-colons "$CD_KEY" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')" = "$CD_FPR" ]; then
    chmod 0644 "$CD_KEY"
    echo "deb [arch=amd64,arm64 signed-by=$CD_KEY] https://downloads.claude.ai/claude-desktop/apt/stable stable main" \
      > /etc/apt/sources.list.d/claude-desktop.list
    apt-get update -qq
    if apt-get install -y -qq claude-desktop; then
      echo "    Claude Desktop $(dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null) installed"
    else
      echo "    [WARN] claude-desktop install failed; retry later with: sudo apt install claude-desktop"
    fi
  else
    rm -f "$CD_KEY"
    echo "    [WARN] Claude Desktop signing key missing or wrong fingerprint; skipped"
  fi
  if dpkg -s claude-desktop >/dev/null 2>&1; then
    # No graphical login on the box (Raspberry Pi OS Lite / Ubuntu Server): the
    # app is installed but needs a desktop to launch.
    # No session file in either folder = no graphical desktop (warning only).
    if ! compgen -G '/usr/share/wayland-sessions/*.desktop' >/dev/null && ! compgen -G '/usr/share/xsessions/*.desktop' >/dev/null; then
      echo "    [WARN] no desktop environment found — install one to launch Claude Desktop"
    fi
  fi
fi

echo ">>> Installing coordinated update tooling (agentic-update / agentic-doctor / agentic-errorlog)..."
# Single coordinated update pass, modeled on homelabhero's hh-update + hh doctor:
# OS packages -> Rust toolchain -> the user's Claude Code -> CloudCLI
# UI -> restart UI -> health
# check -> log. Both tools run as root (they re-exec through sudo for the user)
# and read the user from /etc/agentic/users.conf. Re-runnable on demand
# ('agentic-update'), no reinstall required. Everything tracks latest
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
# no desktop. Each entry has a timestamp, the failing steps and the last
# lines of the log; more problems append to the same file. Entries older than
# 90 days are trimmed and the file is capped at 256 KB. Delete it once the
# problems are dealt with; the next problem starts a fresh one.
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
# The title, tag and priority travel as ntfy HTTP headers and the message
# as the POST body; --max-time 20 stops a dead server from stalling the run.
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
  # n = number of non-empty problem lines; the push lists the first 5 of them.
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
# Health check for the Claude Code Pi. Exit 0 = healthy, non-zero = problems.
# Needs root to check the user's home and services; the user runs it via sudo.
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
AGENTIC_USERS="" AGENTIC_PRIMARY="" AGENTIC_DESKTOP="no"
source /etc/agentic/users.conf 2>/dev/null
LOG_TAG="[doctor]"
rc=0
# check <label> <shell test>: runs the test with eval; prints OK when it
# succeeds, otherwise FAIL and sets rc=1 (the exit status at the end).
check() { if eval "$2" >/dev/null 2>&1; then echo "  OK   $1"; else echo "  FAIL $1"; rc=1; fi; }
# note() is informational only — it never fails the health check. Used for
# user-actionable states (like "not logged in yet") that aren't faults of the box.
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
    note  "$u: claude logged in (creds on disk; run 'claude' /login as $u if WARN)" "test -s '$h/.claude/.credentials.json'"
done
# Shared toolchains and services.
check "shared Rust toolchain"       "RUSTUP_HOME=/opt/rust/rustup /opt/rust/cargo/bin/rustc --version"
check "GitHub CLI (gh) present"     "command -v gh"
check "cloudcli service active"     "systemctl is-active --quiet cloudcli"
check "cloudcli runs as ${AGENTIC_PRIMARY:-<primary>}" "[ \"\$(systemctl show -p User --value cloudcli)\" = '$AGENTIC_PRIMARY' ]"
check "UI listening on :3001"       "ss -ltn | grep -q ':3001'"
# Claude Desktop (only when it was installed; Cowork is deliberately absent)
if [ "$AGENTIC_DESKTOP" = yes ]; then
  note "Claude Desktop installed"     "dpkg -s claude-desktop"
fi
# Raspberry Pi 4 health: page size, swap, memory, power/thermal throttling
note "4K-page kernel (jemalloc tools need it)" "[ \$(getconf PAGESIZE) -eq 4096 ]"
note "swap active (zram)"           "swapon --noheadings | grep -q ."
note "over 1 GB memory available"   "[ \$(awk '/MemAvailable/{print \$2}' /proc/meminfo) -gt 1048576 ]"
# The Pi 4 starts soft-throttling at 80 °C and caps hard at 85 °C. The kernel's
# thermal zone works on every OS, with or without vcgencmd (millidegrees).
SOC_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || true)
if [ -n "$SOC_TEMP" ]; then
  echo "  INFO SoC temperature: $((SOC_TEMP / 1000)) °C"
  note "SoC under 80 °C (Pi 4 throttles from 80 °C; add a heatsink/fan)" "[ $SOC_TEMP -lt 80000 ]"
fi
# get_throttled bits: 0x1 under-voltage, 0x2 ARM clock capped, 0x4 throttled,
# 0x8 soft temperature limit — now (low bits) and since boot (same bits << 16).
# Under-voltage on a Pi 4 almost always means a weak supply or cable.
if command -v vcgencmd >/dev/null 2>&1; then
  THR=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
  if [ -n "$THR" ]; then
    note "no under-voltage now (get_throttled=$THR)"        "[ \$(( $THR & 0x1 )) -eq 0 ]"
    note "no throttling/clock cap now (get_throttled=$THR)" "[ \$(( $THR & 0xE )) -eq 0 ]"
    note "no under-voltage/throttling since boot"           "[ \$(( $THR & 0xF0000 )) -eq 0 ]"
  fi
fi
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
# Coordinated update pass for the Claude Code Pi.
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

echo ">>> [1/6] OS packages (Node.js patches within its LTS line, gh, Claude Desktop, Pi kernel/firmware)..."
# full-upgrade, as Raspberry Pi recommends: kernel/firmware updates otherwise
# get held back.
apt-get update -qq && apt-get full-upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq \
  || echo "    [WARN] OS package update failed"

echo ">>> [2/6] npm (latest) + global dev tools..."
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
# The global dev tools and npm-based language servers the deployer installed
# (re-running the deployer skips them, so they're kept current here). Only the
# ones still installed are touched; CloudCLI has its own step below.
# Builds a <pkg>@latest list of the tools that are still installed, so one
# npm call updates them all; a tool you uninstalled is not brought back.
NPM_TOOLS=()
for pkg in typescript ts-node eslint prettier typescript-language-server pyright; do
  npm ls -g --depth=0 "$pkg" >/dev/null 2>&1 && NPM_TOOLS+=("${pkg}@latest")
done
if [ ${#NPM_TOOLS[@]} -gt 0 ]; then
  npm install -g --no-fund --no-audit --loglevel=error "${NPM_TOOLS[@]}" \
    && echo "    updated: ${NPM_TOOLS[*]}" \
    || echo "    [WARN] global dev tool update failed"
fi

echo ">>> [3/6] Rust (shared toolchain in /opt/rust)..."
# CARGO_HOME is set for this one call so rustup updates the shared proxies in
# /opt/rust/cargo; users keep their own ~/.cargo.
if [ -x /opt/rust/cargo/bin/rustup ]; then
  RUSTUP_HOME=/opt/rust/rustup CARGO_HOME=/opt/rust/cargo /opt/rust/cargo/bin/rustup update \
    || echo "    [WARN] rustup update failed"
  chmod -R a+rX /opt/rust
else
  echo "    (no shared rustup; skipped)"
fi

echo ">>> [4/6] Claude Code (the user's own install)..."
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

echo ">>> [5/6] CloudCLI UI (claudecodeui)..."
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

echo ">>> [6/6] Health check..."
# A new Pi kernel/firmware only takes effect after a reboot; we don't reboot an
# unattended box on our own — just leave the reminder in the log.
[ -e /var/run/reboot-required ] && echo "    NOTE: a reboot is required to finish these updates (sudo reboot)"
# AGENTIC_NO_ERRORLOG=1 keeps agentic-doctor from filing its own entry: its
# WARN/FAIL lines land in this log and are filed below with everything else.
if AGENTIC_NO_ERRORLOG=1 agentic-doctor; then
  echo ">>> agentic-update finished OK: $(date '+%Y-%m-%d %H:%M:%S %Z')"
else
  echo ">>> agentic-update finished WITH HEALTH-CHECK FAILURES: $(date '+%Y-%m-%d %H:%M:%S %Z')"
fi
# Copy this run's [WARN]/FAIL lines, each tagged with its step, to the user's
# Agentic-Errors.txt (agentic-errorlog). A clean run writes nothing.
# tail -c +N starts at byte N (1-based), i.e. just after where this run
# began. The awk remembers the current '[n/6]' step header and prints each
# [WARN] line (and agentic-doctor's WARN/FAIL lines) prefixed with that step.
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
# Weekly coordinated update - Sunday 4:00 AM (the Pi's local time)
# (OS incl. Claude Desktop + Rust + Claude Code + CloudCLI UI,
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
# Unlike the LXC, the package lists stay: this is a full machine, and the
# desktop's software tools and `apt search` need them.
# Hand the daily apt timers back now that provisioning is done.
systemctl start apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

echo "$REBOOT_NEEDED" > /etc/agentic/reboot-needed
echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║              Provisioning Complete!              ║"
echo "╚══════════════════════════════════════════════════╝"
PROVISION_EOF

  # User config for the provision script: names in a sourced env file, passwords
  # as chpasswd lines. Both are written 0600; the provision script deletes them
  # as soon as they're applied (and on_exit does, if it never got that far).
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
      printf 'AGENTIC_TZ=%q\n' "$CT_TZ"
      printf 'AGENTIC_DESKTOP=%q\n' "$CT_DESKTOP"
      printf 'AGENTIC_BOOT_TUNE=%q\n' "$CT_BOOT_TUNE"
      printf 'AGENTIC_FIX_NOPASSWD=%q\n' "$CT_FIX_NOPASSWD"
      printf 'AGENTIC_OS=%q\n' "$PI_OS"
    } > /root/agentic-provision.env
    {
      printf 'root:%s\n' "$CT_PASSWORD"
      for u in "${CT_USERS[@]}"; do
        # Only when a new password was set; otherwise the user keeps theirs.
        if [[ -n "${CT_USER_PASSWORDS[$u]:-}" ]]; then printf '%s:%s\n' "$u" "${CT_USER_PASSWORDS[$u]}"; fi
      done
    } > /root/agentic-provision.chpasswd
    if [[ -n "${CT_SSH_KEY:-}" && -f "$CT_SSH_KEY" ]]; then
      cp "$CT_SSH_KEY" /root/agentic-provision.pub
    fi
  )
  # A new user must exist before chpasswd can set their password — the
  # provision script creates them first, then applies this file.

  env -i HOME=/root TERM="${TERM:-xterm}" LANG=C.UTF-8 \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    bash /root/agentic-provision.sh
  rm -f /root/agentic-provision.sh
}

# ── Write the Notes card ───────────────────────────────────────────────────
# The Pi's stand-in for the Proxmox Notes panel: a Markdown card in
# /etc/agentic/README.md, with a copy in the user's home. Uses placeholders so
# the heredoc can stay single-quoted (no accidental expansion of backticks/$).
write_notes() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip="${ip:-<pi-ip>}"

  local notes
  notes=$(cat <<'EOF'
# 🤖 Claude Code Pi (__HOST__)

**Web UI (CloudCLI UI):** http://__IP__:3001 — _create a login on first visit_
**SSH:** `ssh __USER__@__IP__` (or `ssh __USER__@__HOST__.local`)   |   **Console:** log in as root, then `su - __USER__`

## Start Claude Code
Claude runs as **__USER__** only — never root (`claude` refuses to run as root).
Log in as __USER__, then run `claude` (the shell auto-cd's to `/project`).

## Claude Desktop
__DESKTOP__

## Update & health
- `sudo agentic-update` — one coordinated pass: OS (incl. Claude Desktop, Pi firmware) → Rust → Claude Code → Web UI → health check
- `sudo agentic-doctor` — the health check on its own (also memory, swap, throttling, temperature)
- Auto-runs weekly (Sunday 4 AM, __TZ__). Log: `/var/log/agentic-update.log`
- Any WARN/FAIL from either is also appended to `Agentic-Errors.txt` on __USER__'s desktop (home folder if there is none); delete it once dealt with
- Optional ntfy phone alerts for the same problems: set `NTFY_TOPIC` in `/etc/agentic/ntfy.conf`, then `sudo agentic-errorlog --test-ntfy`

## Service & config
- `systemctl status cloudcli` — the Web UI service, runs as **__USER__** (`journalctl -u cloudcli` for logs)
- Permissions: **auto mode** + secret/sudo deny-floor — `~/.claude/settings.json`
- Repair the user's Claude setup: `sudo agentic-setup-user`
- Install logs: `/var/log/agentic-deploy/`, `/var/log/agentic-provision.log`

## Pi 4 tips
CPU and memory are the limits: run one agent at a time, let Rust builds use
their default two jobs (CARGO_BUILD_JOBS=2), and stop dev servers you're done
with. Boot from a USB 3 SSD, use the official 15 W (5 V / 3 A) USB-C supply and
a heatsink or fan case — `agentic-doctor` warns on under-voltage, throttling and
temperatures from 80 °C.

---
_IP above is the address at deploy time; on DHCP it may change (check with `hostname -I`)._
EOF
)
  local desk
  if [[ "$CT_DESKTOP" == yes ]]; then
    desk="Log in to the Pi's desktop as **$CT_PRIMARY_USER**, open **Claude** from the menu (or run \`claude-desktop\`) and sign in. Chat and Code work; Cowork is left out on purpose (it needs a VM). Not on Linux yet: Computer Use, dictation."
  else
    desk="Not installed. Add it later from a desktop session: see code.claude.com/docs/en/desktop-linux (\`sudo apt install claude-desktop\` once the repo is added)."
  fi
  # Fill in the placeholders.
  notes=${notes//__IP__/$ip}
  notes=${notes//__HOST__/$CT_HOSTNAME}
  notes=${notes//__USER__/$CT_PRIMARY_USER}
  notes=${notes//__TZ__/$CT_TZ}
  notes=${notes//__DESKTOP__/$desk}

  # The card goes to /etc/agentic (root's copy) and, owned by the user, into
  # their home folder.
  local h
  h=$(getent passwd "$CT_PRIMARY_USER" | cut -d: -f6)
  if printf '%s\n' "$notes" > /etc/agentic/README.md; then
    chmod 644 /etc/agentic/README.md
    install -m 644 -o "$CT_PRIMARY_USER" -g "$CT_PRIMARY_USER" /etc/agentic/README.md "$h/CLAUDE-PI.md" 2>/dev/null || true
    success "Wrote the notes card to /etc/agentic/README.md (copy: ~$CT_PRIMARY_USER/CLAUDE-PI.md)."
  else
    warn "Could not write the notes card (non-fatal)."
  fi
}

# ── Print Summary ─────────────────────────────────────────────────────────
print_summary() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')

  echo ""
  echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}${BOLD}║              Claude Code Pi Ready!               ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Pi:${NC}        $CT_HOSTNAME — $PI_MODEL"
  echo -e "  ${BOLD}OS:${NC}        $PI_OS"
  echo -e "  ${BOLD}IP:${NC}        ${ip:-pending (DHCP)}"
  echo -e "  ${BOLD}Resources:${NC} 4 CPU / ${PI_RAM_MB} MB RAM / $(df -h --output=avail / | tail -1 | tr -d ' ') free"
  echo -e "  ${BOLD}Timezone:${NC}  $CT_TZ"
  echo -e "  ${BOLD}User:${NC}      $CT_USER (Claude runs only as this user; sudo: $CT_USER_SUDO)"
  echo -e "  ${BOLD}Security:${NC}  SSH for root + $CT_USER (password$([[ -n "$CT_SSH_KEY" ]] && echo ' or key'))$([[ $CT_FIX_NOPASSWD == yes ]] && echo '; sudo now asks for a password')"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  [[ -n "${ip:-}" ]] && echo -e "    SSH:     ${CYAN}ssh ${CT_USER}@${ip}${NC}  (or ${CYAN}ssh ${CT_USER}@${CT_HOSTNAME}.local${NC})"
  [[ -n "${ip:-}" ]] && echo -e "    Web UI:  ${CYAN}http://${ip}:3001${NC} (as $CT_USER — ${YELLOW}create its login NOW${NC}; the first visitor claims it)"
  echo ""
  echo -e "  ${BOLD}Start Claude Code:${NC} (as a normal user, not root)"
  echo -e "    ${CYAN}claude${NC}  (shell auto-cd's to /project on login; as root: ${CYAN}su - $CT_USER${NC})"
  if [[ "$CT_DESKTOP" == yes ]]; then
    echo -e "  ${BOLD}Claude Desktop:${NC} log in to the Pi's desktop as ${CYAN}$CT_USER${NC}, open ${CYAN}Claude${NC} from the menu and sign in"
    local auto
    auto=$(grep -hs '^autologin-user=' /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf 2>/dev/null | tail -1 | cut -d= -f2) || true
    [[ -n "$auto" && "$auto" != "$CT_USER" ]] \
      && echo -e "    ${YELLOW}The desktop auto-logs in as '$auto'${NC} — switch it with ${CYAN}sudo raspi-config${NC} → System Options → Auto Login"
  fi
  echo ""
  echo -e "  ${BOLD}Verify plugins:${NC} ${CYAN}claude plugin list${NC}    ${BOLD}Health:${NC} ${CYAN}sudo agentic-doctor${NC}"
  echo ""
  echo -e "  ${BOLD}Installed:${NC}"
  echo "    • Claude Code (native)      • Node.js (latest LTS)"
  echo "    • Python 3 + pip + venv     • Go (latest)"
  echo "    • Rust (system, /opt/rust)  • No containers (all native)"
  echo "    • Git + GitHub CLI (gh)     • Build essentials"
  echo "    • ripgrep, fzf, fd          • PostgreSQL & Redis CLI"
  echo "    • CloudCLI UI (port 3001)   • zram swap"
  [[ "$CT_DESKTOP" == yes ]] && echo "    • Claude Desktop (Linux beta, arm64: Chat + Code)"
  echo ""
  echo -e "  ${BOLD}Permissions:${NC} Auto mode (classifier-guarded) + deny floor for secrets and sudo/su"
  echo -e "  ${BOLD}Config:${NC}      ~/.claude/settings.json (template in /usr/local/share/agentic)"
  echo -e "  ${BOLD}Features:${NC}    Agent teams (experimental), adaptive thinking/effort (tune with ${CYAN}/effort${NC})"
  echo -e "  ${BOLD}Remote Control:${NC} ${CYAN}/rc${NC} in a session, ${CYAN}claude --rc${NC}, or all sessions via ${CYAN}/config${NC} (claude.ai login)"
  echo -e "  ${BOLD}Plugins:${NC}     frontend-design, code-review, commit-commands, security-guidance, claude-security,"
  echo -e "               context7, modern-web-guidance, superpowers, elements-of-style,"
  echo -e "               + LSP (typescript/pyright/gopls/rust-analyzer/clangd)"
  echo -e "  ${BOLD}Skills:${NC}      webapp-testing (local, Playwright)"
  echo -e "  ${BOLD}Updates:${NC}     Sundays 4 AM ($CT_TZ) — coordinated (OS + Desktop + Rust + Claude + UI)"
  echo -e "               then a health check. Run anytime: ${CYAN}sudo agentic-update${NC} / ${CYAN}sudo agentic-doctor${NC}"
  echo -e "  ${BOLD}Notes card:${NC}  /etc/agentic/README.md (copy in ~$CT_USER/CLAUDE-PI.md)"
  echo ""
  echo -e "  ${BOLD}Install logs:${NC}"
  echo -e "    Deploy:    $DEPLOY_LOG"
  echo -e "    Provision: /var/log/agentic-provision.log"
  echo ""
}

# ── Reboot ────────────────────────────────────────────────────────────────
# arm_boost is a boot setting, and a new user's groups and shell setup
# apply at the next login — a reboot covers both.
offer_reboot() {
  local need ans
  # "yes" when provisioning changed a boot-time setting; Debian/Ubuntu also
  # flag kernel updates with /var/run/reboot-required.
  need=$(cat /etc/agentic/reboot-needed 2>/dev/null || echo no)
  [[ -e /var/run/reboot-required ]] && need=yes
  if [[ "$need" == yes ]]; then
    warn "A reboot is needed to activate the boot changes (arm_boost / kernel updates)."
  else
    info "Log out and back in (or reboot) so $CT_USER's sessions pick up the new setup."
  fi
  read -rp "Reboot now? [$([[ $need == yes ]] && echo Y/n || echo y/N)]: " ans
  # Enter takes the default shown: reboot when one is needed, otherwise don't.
  if [[ "$need" == yes && ! "$ans" =~ ^[Nn] ]] || [[ "$need" != yes && "$ans" =~ ^[Yy] ]]; then
    info "Rebooting..."
    sync
    systemctl reboot
  else
    info "Skipped. Reboot later with: sudo reboot"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────
# Order matters: logging starts only after the prompts, so passwords typed at
# get_config never reach the log; everything after that is captured.
main() {
  header
  preflight
  get_config
  start_logging
  apply_hostname
  wait_network
  provision_pi
  write_notes
  print_summary
  offer_reboot
}

main "$@"
