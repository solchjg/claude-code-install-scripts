#!/usr/bin/env bash
# ============================================================================
# Claude Code Deployer for Lubuntu 26.04 (no containers)
# Turns a Lubuntu 26.04 desktop PC into a fully provisioned Claude Code box,
# with Claude Desktop (Chat, Code and Cowork) on its own desktop, run as ONE
# normal (non-root) user — one person per machine
#
# The bare-metal counterpart of the Claude Code LXC Deployer for Proxmox: same
# toolchain, same single-user model, same update/health tools — but everything
# is installed straight onto the Lubuntu OS: no Proxmox, no LXC and no Docker.
# Claude Code (CLI), Claude Desktop and the dev tools are installed for the one
# normal user. The only virtualization on the box is the small VM that Claude
# Desktop's Cowork starts by itself with QEMU/KVM; this script installs what
# that VM needs (QEMU, UEFI firmware, virtiofsd, the kvm group and the
# vhost_vsock kernel module) and checks that the CPU's hardware virtualization
# is turned on. Run it on the machine itself, from a terminal, as root:
#   sudo bash Claude_Code_Lubuntu_Deployer.sh
#
# Supported OS:
#   - Lubuntu 26.04 LTS (64-bit, x86_64) — the target. Claude Desktop's Linux
#     beta officially supports Ubuntu 22.04+, and Lubuntu is Ubuntu with the
#     LXQt desktop.
#   - Other Ubuntu 24.04+ flavours (Ubuntu, Kubuntu, Xubuntu...) work too; the
#     script warns but carries on. arm64 is accepted (Claude Desktop ships an
#     arm64 build), though Lubuntu itself only publishes x86_64 images.
#   Not supported: running this inside a container (LXC/Docker/WSL) — use the
#   Proxmox LXC deployer for that. Inside a VM it works, but Cowork then needs
#   nested virtualization turned on in the hypervisor.
#
# Running it in a Proxmox Lubuntu VM:
#   The script runs unchanged — to it a VM looks like a normal Lubuntu machine.
#   What needs setting is the VM itself, in Proxmox (no script option for it):
#   - Cowork needs NESTED virtualization, because its own VM runs inside this
#     one. Set the VM's CPU type to `host` (qm set <vmid> --cpu host) and make
#     sure nested KVM is on on the Proxmox host: cat
#     /sys/module/kvm_intel/parameters/nested (kvm_amd on AMD) must say Y or 1.
#     It's on by default on current Proxmox kernels; if not, add
#     "options kvm-intel nested=Y" (or "options kvm-amd nested=1") to
#     /etc/modprobe.d/kvm.conf on the host and reboot it. Stop and start the
#     VM after changing its CPU type. Without nested KVM the script still
#     installs everything, but warns that Cowork can't run (no /dev/kvm).
#   - Memory and disk: give the VM at least 8 GB of RAM, 4 or more cores and
#     ~40 GB of disk — Claude Desktop, Cowork's own VM and the dev tools all
#     share it.
#   - CPU type `host` ties the VM to the host's CPU model, so live migration
#     to a node with a different CPU won't work; snapshots (qm snapshot) do.
#   - Optional, not done by this script: `sudo apt install qemu-guest-agent`
#     in the VM plus Options -> QEMU Guest Agent = on in Proxmox lets Proxmox
#     shut the VM down cleanly and show its IP address.
#
# GitHub: https://github.com/solchjg/claude-code-install-scripts
# Based on the original by serversathome: https://github.com/serversathome/claudelxc
#
# How it runs (see main() at the bottom):
#   1. Interactive: check the machine/OS and its hardware virtualization, then
#      ask for the hostname, timezone, the root password and the ONE Claude
#      user (usually the account you created when installing Lubuntu, or a new
#      one), and Claude Desktop + Cowork y/n.
#   2. Logged to /var/log/agentic-deploy/: wait for network, then write a
#      provision script (the big quoted heredoc below) plus a small env file
#      and password file, and run it. It installs the toolchains, sets up the
#      user and Claude Code, Claude Desktop with Cowork's VM stack, the web UI
#      and the update/health tools, logging to /var/log/agentic-provision.log.
#   3. Write the box's notes card (/etc/agentic/README.md), print the summary
#      and offer the reboot (the kvm group and any new kernel need one).
#
# Uninstall: sudo bash Claude_Code_Lubuntu_Deployer.sh --uninstall
#   (asks what to remove first; see uninstall() near the bottom).
#
# Safe to re-run: existing users, settings and shell blocks are kept, and the
# installers skip what's already there — on a failure, fix the cause and run
# it again (there's no container to throw away).
#
# Tools left on the machine:
#   agentic-setup-user  set up / repair the Claude user's install (re-runnable)
#   agentic-update      weekly coordinated update (cron, Sunday 4 AM local time)
#   agentic-doctor      health check (incl. Cowork's virtualization requirements)
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
#                                deny floor); a re-run only adds new deny rules
#   /project/CLAUDE.md           what Claude is told about this box
#   /etc/agentic/README.md       the notes card (copy: ~USER/CLAUDE-BOX.md)
#   /etc/agentic/os-packages-kept  OS packages kept from autoremove on the first
#                                run (marked manual; see the provision script)
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
# account (the one the Lubuntu installer created) may keep its password, and
# root's must still differ from it. Hashes with the system crypt(3) —
# libxcrypt on Ubuntu, so yescrypt "$y$" hashes work. The password travels in
# the environment, never on a command line (where `ps` would show it).
is_current_password() {
  local hash
  hash=$(getent shadow "$1" | cut -d: -f2)
  [[ -n "$hash" && "$hash" != [\!*]* ]] || return 1
  PW="$2" H="$hash" perl -e 'exit(crypt($ENV{PW}, $ENV{H}) eq $ENV{H} ? 0 : 1)'
}

# nopasswd_rules <user> <gets-sudo yes|no>
# Prints every sudoers line that would let <user> use sudo without a password:
# NOPASSWD rules for the user, for ALL, or for a group they're in or are about
# to join (sudo) — in /etc/sudoers or any drop-in — plus "Defaults !authenticate".
# Read from the files rather than `sudo -l -U`, because a new user (or a new
# sudo member) isn't covered by those rules until provisioning has run.
nopasswd_rules() {
  local p g principals="$1 ALL"
  for g in $(id -nG "$1" 2>/dev/null) $([[ "$2" == yes ]] && echo sudo); do principals+=" %$g"; done
  for p in $principals; do
    grep -hsE "^[[:space:]]*${p}[[:space:]].*NOPASSWD" /etc/sudoers /etc/sudoers.d/* || true
  done | sort -u
  grep -hsE '^[[:space:]]*Defaults.*!authenticate' /etc/sudoers /etc/sudoers.d/* || true
}

# ── Install log ──────────────────────────────────────────────────────────────
# Everything after the config prompts (all deployer output plus the full
# provisioning output) is copied to a log, so a failed run can be analysed
# after the fact. Passwords are never written to it: they're read before
# logging starts and only travel in 0600 files, never on stdout.
LOG_DIR=/var/log/agentic-deploy
start_logging() {
  mkdir -p "$LOG_DIR"
  DEPLOY_LOG="$LOG_DIR/lubuntu-$(date +%Y%m%d-%H%M%S).log"
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
  echo -e "${BOLD}║    Claude Code Deployer (Lubuntu 26.04 native)   ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ── Pre-flight checks ──────────────────────────────────────────────────────
# Hard requirements: root, a 64-bit OS (amd64 or arm64), Ubuntu 22.04+ (what
# Claude Desktop's Linux build supports), and NOT inside a container. Soft
# ones (warned, not fatal): Lubuntu 26.04 specifically, 8 GB+ RAM, ~25 GB free
# disk, and the hardware virtualization Cowork's VM needs (check_virt below).
preflight() {
  [[ $(id -u) -eq 0 ]] || error "This script must be run as root: sudo bash $0"
  # amd64 is the target; arm64 is accepted (Claude Desktop ships both builds).
  HOST_ARCH=$(dpkg --print-architecture 2>/dev/null || uname -m)
  case "$HOST_ARCH" in
    amd64) ;;
    arm64) warn "arm64 machine: Lubuntu only publishes x86_64 images, but Claude Desktop and Cowork have arm64 builds — continuing." ;;
    *) error "Needs a 64-bit OS (dpkg arch amd64 or arm64); this one is '$HOST_ARCH'." ;;
  esac

  # This is the no-container build: everything goes onto the real OS. Inside an
  # LXC/Docker/WSL container Cowork can't start its VM (no /dev/kvm, no kernel
  # modules), and the Proxmox LXC deployer is the right tool there.
  local ctr
  ctr=$(systemd-detect-virt --container 2>/dev/null || true)
  if [[ -n "$ctr" && "$ctr" != none ]]; then
    error "This is running inside a container ($ctr). This script installs onto a real Lubuntu machine (or a VM); use the Proxmox LXC deployer for containers."
  fi

  # shellcheck disable=SC1091
  source /etc/os-release
  VERSION_ID="${VERSION_ID:-0}"
  [[ "${ID:-}" == ubuntu ]] \
    || error "Unsupported OS '${ID:-unknown}'. This script is for Lubuntu 26.04 (Ubuntu-based)."
  [[ "${VERSION_ID%%.*}" -ge 22 ]] 2>/dev/null \
    || error "Ubuntu ${VERSION_ID} is too old; Claude Desktop needs 22.04 or later (this script targets 26.04)."
  [[ "$VERSION_ID" == 26.04 ]] \
    || warn "This is Ubuntu $VERSION_ID; the script is written for 26.04 — continuing."

  # Lubuntu = Ubuntu + LXQt. Detect it by its meta-package (or an LXQt session)
  # so the summary and notes can say which flavour this is.
  # '*sessions' matches both xsessions/ (X11) and wayland-sessions/, so an
  # LXQt X11 or Wayland session both count.
  if dpkg -s lubuntu-desktop &>/dev/null || compgen -G '/usr/share/*sessions/lxqt*.desktop' >/dev/null; then
    HOST_OS="Lubuntu ${VERSION_ID}"
  else
    HOST_OS="Ubuntu ${VERSION_ID} (${XDG_CURRENT_DESKTOP:-unknown desktop})"
    warn "This doesn't look like Lubuntu (no lubuntu-desktop / LXQt). It should still work on other Ubuntu flavours."
  fi

  # Maker + model from the firmware's DMI table (e.g. "LENOVO ThinkCentre M720q").
  HOST_MODEL=$(cat /sys/class/dmi/id/sys_vendor /sys/class/dmi/id/product_name 2>/dev/null | tr '\n' ' ' | sed 's/ *$//') || true
  HOST_MODEL="${HOST_MODEL:-unknown machine}"
  HOST_CPUS=$(nproc)
  HOST_RAM_MB=$(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 ))
  (( HOST_RAM_MB >= 7000 )) \
    || warn "Only ${HOST_RAM_MB} MB RAM. The toolchain + Claude Desktop + Cowork's VM want 8 GB or more; expect swapping."
  HOST_DISK_FREE_GB=$(( $(df --output=avail -k / | tail -1) / 1024 / 1024 ))
  (( HOST_DISK_FREE_GB >= 25 )) \
    || warn "Only ${HOST_DISK_FREE_GB} GB free on /. The full install plus Cowork's VM image needs ~20 GB; leave room for projects."

  check_virt
}

# ── Hardware virtualization (for Cowork) ────────────────────────────────────
# Cowork runs its tasks in a VM that Claude Desktop starts with QEMU + KVM. That
# needs the CPU's virtualization extensions (Intel VT-x = "vmx", AMD-V = "svm";
# on arm64 the kernel exposes KVM directly) TURNED ON in the BIOS/UEFI setup.
# Many PCs ship with it off. Without it Claude Desktop still installs and Chat
# and Code work; Cowork shows "Cowork requires hardware virtualization (KVM)"
# until you enable it in the firmware and reboot — nothing needs re-running.
# Sets VIRT_OK=yes|no and VIRT_NOTE (one line for the summary/notes).
check_virt() {
  local vm cpu_flag=no
  VIRT_OK=no
  # vm = the hypervisor's name when this machine is itself a VM, else empty;
  # cpu_flag = the CPU advertises VT-x (vmx) or AMD-V (svm).
  vm=$(systemd-detect-virt --vm 2>/dev/null || true)
  [[ "$vm" == none ]] && vm=""
  grep -qwE 'vmx|svm' /proc/cpuinfo 2>/dev/null && cpu_flag=yes
  [[ "$HOST_ARCH" == arm64 ]] && cpu_flag=yes   # no vmx/svm flags on arm; /dev/kvm decides

  # The KVM modules load at boot when the CPU supports them, so /dev/kvm
  # existing is the real proof. Try loading them once if it's missing (a
  # module that wasn't autoloaded), and ask the kernel why it refused if not.
  if [[ ! -e /dev/kvm && "$cpu_flag" == yes ]]; then
    modprobe kvm_intel 2>/dev/null || modprobe kvm_amd 2>/dev/null || modprobe kvm 2>/dev/null || true
  fi

  # Four outcomes, best first: KVM works; this is a VM without nested
  # virtualization; the CPU shows no extensions (usually switched off in the
  # BIOS); or the CPU has them but KVM didn't load.
  if [[ -e /dev/kvm ]]; then
    VIRT_OK=yes
    VIRT_NOTE="hardware virtualization on (/dev/kvm present)${vm:+, nested inside $vm}"
    success "Hardware virtualization is available — Cowork can run its VM."
  elif [[ -n "$vm" ]]; then
    VIRT_NOTE="NO /dev/kvm — this is a $vm VM without nested virtualization"
    warn "This machine is itself a VM ($vm) and exposes no /dev/kvm."
    warn "Cowork needs NESTED virtualization: turn it on in the hypervisor for this VM"
    warn "(e.g. Proxmox: CPU type 'host'; VirtualBox: 'Nested VT-x/AMD-V'), then reboot."
  elif [[ "$cpu_flag" == no ]]; then
    VIRT_NOTE="NO hardware virtualization reported by the CPU"
    warn "The CPU reports no virtualization extensions (no vmx/svm in /proc/cpuinfo)."
    warn "Most often it's switched OFF in the BIOS/UEFI setup: look for 'Intel Virtualization"
    warn "Technology', 'VT-x', 'SVM Mode' or 'AMD-V', enable it, save and reboot."
    warn "If the CPU truly has none, Cowork can't run here (Chat and Code still work)."
  else
    VIRT_NOTE="CPU supports virtualization but /dev/kvm is missing"
    warn "The CPU supports virtualization but /dev/kvm is missing (KVM didn't load)."
    warn "Check the BIOS/UEFI virtualization setting and 'dmesg | grep -i kvm', then reboot."
  fi
  if [[ "$VIRT_OK" == no ]]; then
    warn "Claude Desktop will still be installed with Cowork's packages, so Cowork starts"
    warn "working as soon as virtualization is enabled — no need to re-run this script."
  fi
}

# ── Configuration ───────────────────────────────────────────────────────────

# Ask how root may log in over SSH. "key" (the default) is PermitRootLogin
# prohibit-password: root needs an SSH key, and its password is never accepted
# over the network (the console and `su -` still take it). "password" keeps
# root's password usable over SSH, which lets anyone who can reach port 22
# try to guess it. Asked on every run, so a re-run can switch either way; the
# previous answer is the default.
ask_root_ssh() {
  local ans def=key has_key=no
  if grep -qs '^# root SSH: password' /etc/ssh/sshd_config.d/00-agentic.conf; then def=password; fi
  if [[ -n "${CT_SSH_KEY:-}" ]] || [[ -s /root/.ssh/authorized_keys ]]; then has_key=yes; fi
  while true; do
    read -rp "Root SSH login: key only, or password allowed too? [key/password, default $def]: " ans
    case "${ans:-$def}" in
      k|key) CT_ROOT_SSH=key ;;
      p|password) CT_ROOT_SSH=password ;;
      *) warn "Please answer key or password."; continue ;;
    esac
    break
  done
  if [[ "$CT_ROOT_SSH" == password ]]; then
    warn "Root's password will work over SSH. Anyone who can reach port 22 can try to guess it,"
    warn "and a guessed root password is the whole machine. Use a long, unique password, keep"
    warn "port 22 off the internet, and re-run this script and choose key once a key works."
  elif [[ "$has_key" == no ]]; then
    warn "No SSH key is set up for root, so root can't log in over SSH at all. The console"
    warn "and su - from the Claude user still work. To allow root over SSH, add a key to"
    warn "/root/.ssh/authorized_keys (or give one at the key prompt when you re-run this script)."
  fi
}

# Ask where the web UI (port 3001) should listen. Local is the default: the UI
# is a full shell as the Claude user, so only open it to the LAN on purpose.
# Asked on every run, so a re-run can switch it either way.
ask_webui_bind() {   # $1 = what "local" means here, e.g. "this machine"
  local ans
  while true; do
    read -rp "Web UI (port 3001) reachable from $1 only, or from your LAN? [local/lan, default local]: " ans
    case "${ans,,}" in
      ""|l|local) CT_WEBUI_BIND=127.0.0.1; return ;;
      lan)        CT_WEBUI_BIND=0.0.0.0; return ;;
      *)          warn "Please answer local or lan." ;;
    esac
  done
}

# Asks everything up front (nothing is changed until "Proceed? y"), so the rest
# of the run is unattended. Sets the HOST_* / CT_* globals used by every later
# step (CT_* names kept from the Proxmox deployer so the shared parts line up).
get_config() {
  echo ""
  echo -e "${BOLD}Machine Configuration${NC}"
  echo "─────────────────────────────────────────────────"

  local cur_host
  cur_host=$(hostname)
  read -rp "Hostname [$cur_host]: " CT_HOSTNAME
  CT_HOSTNAME="${CT_HOSTNAME:-$cur_host}"
  [[ "$CT_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
    || error "Invalid hostname '$CT_HOSTNAME'."

  # Keep the zone the Lubuntu installer set; a machine still on UTC defaults to
  # America/New_York like the Proxmox deployer.
  local cur_tz
  cur_tz=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo UTC)
  [[ "$cur_tz" == UTC || "$cur_tz" == Etc/UTC ]] && cur_tz="America/New_York"
  read -rp "Timezone [$cur_tz]: " CT_TZ
  CT_TZ="${CT_TZ:-$cur_tz}"
  [[ -f "/usr/share/zoneinfo/$CT_TZ" ]] || error "Unknown timezone '$CT_TZ' (see: timedatectl list-timezones)."

  # Ubuntu ships with root locked (no password). Setting one gives a console/
  # SSH root login like the Proxmox container had, and it's the password the
  # Claude user's must differ from.
  read_password CT_PASSWORD "Root password (console + SSH)"

  # SSH key (optional) — installed for root and for the Claude user. Password
  # logins stay on for both; a key is what Claude Desktop's SSH sessions from
  # another computer need.
  read -rp "Path to SSH public key (optional, press Enter to skip): " CT_SSH_KEY
  if [[ -n "$CT_SSH_KEY" && ! -f "$CT_SSH_KEY" ]]; then
    error "SSH public key not found: $CT_SSH_KEY"
  fi
  # It must be ONE public key line ("ssh-ed25519 AAAA... comment"). Giving the
  # private key by mistake (id_ed25519 instead of id_ed25519.pub) would copy it
  # onto this machine and into authorized_keys, so that's refused outright.
  if [[ -n "$CT_SSH_KEY" ]]; then
    if grep -q 'PRIVATE KEY' "$CT_SSH_KEY"; then
      error "$CT_SSH_KEY is a PRIVATE key. Give the public one instead (${CT_SSH_KEY%.pub}.pub); nothing was changed."
    fi
    if [[ "$(grep -cv '^[[:space:]]*$' "$CT_SSH_KEY")" -ne 1 ]] \
       || ! grep -qE '^(ssh-(ed25519|rsa|dss)|ecdsa-sha2-nistp[0-9]+|sk-(ssh-ed25519|ecdsa-sha2-nistp256)@openssh\.com) [A-Za-z0-9+/=]+' "$CT_SSH_KEY" \
       || { command -v ssh-keygen >/dev/null 2>&1 && ! ssh-keygen -l -f "$CT_SSH_KEY" >/dev/null 2>&1; }; then
      error "$CT_SSH_KEY isn't a single SSH public key line (like the contents of ~/.ssh/id_ed25519.pub)."
    fi
  fi
  ask_root_ssh

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
  # ran sudo — usually the account the Lubuntu installer created, which is also
  # the one the desktop logs in as, so Claude Desktop and Cowork run there too.
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
        root|agentic|sudo|nobody|daemon|bin|sys|adm|kvm|docker|ubuntu|lubuntu)
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
    # The desktop keyring (where Claude Desktop keeps its sign-in) is locked
    # with the OLD login password and isn't re-keyed by chpasswd.
    [[ "$CT_USER_EXISTS" == yes ]] \
      && warn "After the next login, the desktop keyring may ask for $CT_USER's OLD password once (it isn't changed by this script)."
  fi

  # An existing sudoer keeps sudo (removing it could lock you out of the box).
  if [[ "$CT_USER_EXISTS" == yes ]] && id -nG "$CT_USER" | grep -qw sudo; then
    CT_USER_SUDO="yes"
    info "$CT_USER already has sudo; keeping it."
  else
    read -rp "Give $CT_USER sudo (password required)? [Y/n]: " CT_USER_SUDO
    [[ "$CT_USER_SUDO" =~ ^[Nn] ]] && CT_USER_SUDO="no" || CT_USER_SUDO="yes"
  fi

  # Ubuntu's sudo asks for the password by default, but a NOPASSWD rule may have
  # been added since. Offer to remove it, so "sudo needs your password, which
  # Claude can't type" holds.
  # The check covers every sudoers file and group rules such as %sudo, not
  # just drop-ins that name the user (see nopasswd_rules above).
  CT_FIX_NOPASSWD="no"
  local nopw
  nopw="$(nopasswd_rules "$CT_USER" "$CT_USER_SUDO")"
  if [[ -n "$nopw" ]]; then
    local ans l
    warn "$CT_USER would get passwordless sudo from:"
    while IFS= read -r l; do warn "    $l"; done <<< "$nopw"
    info "Fixing it edits those rules, so a group rule (like %sudo) changes for every member of that group."
    read -rp "Make sudo ask $CT_USER for a password (strongly recommended for an auto-mode agent)? [Y/n]: " ans
    [[ "$ans" =~ ^[Nn] ]] || CT_FIX_NOPASSWD="yes"
    if [[ "$CT_FIX_NOPASSWD" == yes && "$setpw" != yes ]]; then
      info "sudo will use $CT_USER's existing login password."
    fi
  fi

  # Claude Desktop (Linux beta) from Anthropic's apt repo, WITH Cowork: the
  # QEMU/KVM stack, the kvm group and the vhost_vsock module come with it.
  # Needs a desktop session to launch (Lubuntu's LXQt is fine).
  echo ""
  # A desktop counts when EITHER folder has a session file, so an X11-only or
  # Wayland-only desktop is found too.
  # compgen -G <glob> prints the matching files and succeeds only when at
  # least one exists; unlike ls, an empty or missing folder is not an error.
  if compgen -G '/usr/share/wayland-sessions/*.desktop' >/dev/null \
     || compgen -G '/usr/share/xsessions/*.desktop' >/dev/null; then
    HOST_HAS_DESKTOP=yes
  else
    HOST_HAS_DESKTOP=no
    warn "No desktop environment found (server install?). Claude Desktop needs one to launch."
  fi
  read -rp "Install Claude Desktop with Cowork (Linux beta)? [$([[ $HOST_HAS_DESKTOP == yes ]] && echo Y/n || echo y/N)]: " CT_DESKTOP
  if [[ "$HOST_HAS_DESKTOP" == yes ]]; then
    [[ "$CT_DESKTOP" =~ ^[Nn] ]] && CT_DESKTOP="no" || CT_DESKTOP="yes"
  else
    [[ "$CT_DESKTOP" =~ ^[Yy] ]] && CT_DESKTOP="yes" || CT_DESKTOP="no"
  fi

  ask_webui_bind "this machine"

  echo ""
  # Everything chosen above, for a last look: nothing on the system has changed
  # yet, and answering anything but y at "Proceed?" leaves it that way.
  echo -e "${BOLD}Summary${NC}"
  echo "─────────────────────────────────────────────────"
  echo "  Machine:   $HOST_MODEL ($HOST_ARCH)"
  echo "  OS:        $HOST_OS"
  echo "  CPU/RAM:   ${HOST_CPUS} threads / ${HOST_RAM_MB} MB"
  echo "  Disk:      ${HOST_DISK_FREE_GB} GB free on /"
  echo "  Hostname:  $CT_HOSTNAME"
  echo "  Timezone:  $CT_TZ"
  echo "  User:      $CT_USER ($([[ $CT_USER_EXISTS == yes ]] && echo existing || echo new); sudo: $CT_USER_SUDO$([[ $CT_FIX_NOPASSWD == yes ]] && echo ', password now required'))"
  echo "  Password:  $([[ -n "${CT_USER_PASSWORDS[$CT_USER]:-}" ]] && echo "new for $CT_USER" || echo "$CT_USER keeps theirs"); root password set"
  echo "  SSH:       $CT_USER by password$([[ -n "$CT_SSH_KEY" ]] && echo " or key"); root by $([[ $CT_ROOT_SSH == key ]] && echo 'key only' || echo 'password or key (WARNING: guessable over the network)')"
  echo "  Web UI:    port 3001, $([[ $CT_WEBUI_BIND == 0.0.0.0 ]] && echo 'open to the LAN' || echo 'local only (reach it through an SSH tunnel)')"
  echo "  Alerts:    Agentic-Errors.txt$([[ -n "$CT_NTFY_TOPIC" ]] && echo " + ntfy push to $CT_NTFY_TOPIC$([[ -n "$CT_NTFY_TOKEN" ]] && echo ' (with token)')")"
  echo "  Desktop:   Claude Desktop $([[ $CT_DESKTOP == yes ]] && echo 'yes (Chat + Code + Cowork)' || echo no)"
  [[ "$CT_DESKTOP" == yes ]] && echo "  Cowork VM: $VIRT_NOTE"
  echo "  Containers: none (no Docker, no LXC)"
  echo "─────────────────────────────────────────────────"
  echo ""
  read -rp "Proceed? (y/N): " confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
}

# ── Hostname ────────────────────────────────────────────────────────────────
# Only touched when you changed it at the prompt. /etc/hosts keeps the Ubuntu
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
  # nothing about DNS. bash's /dev/tcp needs no extra packages. A laptop on
  # Wi-Fi right after login can take a moment to associate.
  local attempts=0
  while ! { getent hosts github.com >/dev/null && timeout 5 bash -c 'exec 3<>/dev/tcp/github.com/443'; } &>/dev/null; do
    (( ++attempts ))
    [[ $attempts -lt 30 ]] || error "No network after 60s (check Wi-Fi/Ethernet, DNS and the gateway)."
    sleep 2
  done
  success "Machine is online."
}

# ── Provision the machine ─────────────────────────────────────────────────
provision_host() {
  info "Provisioning this machine (this takes a while — typically 15-30 min)..."

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
# On a failure, also delete the secret files the deployer handed over (they
# are normally removed as soon as they've been applied).
trap 'rc=$?; rm -f /root/agentic-provision.env /root/agentic-provision.chpasswd /root/agentic-provision.pub; echo "!!! provisioning FAILED (exit $rc) at line $LINENO: $BASH_COMMAND — full log: $PROVISION_LOG"' ERR
set -x
# The env file holds the ntfy topic and token, so the trace is switched off
# while it's read: a traced `source` would copy every value into this log.
# AGENTIC_USERS / AGENTIC_PRIMARY / AGENTIC_SUDO / AGENTIC_TZ / AGENTIC_DESKTOP /
# AGENTIC_FIX_NOPASSWD / AGENTIC_OS, written by the deployer from its prompts
set +x
source /root/agentic-provision.env
set -x
# sudo may hand us a LANG from your desktop session that this script shouldn't
# depend on — every perl/apt call with a missing locale spews "Setting locale
# failed". C.UTF-8 is always built in; the system default is only touched
# below. Also set a full PATH: sudo's secure_path is fine on Ubuntu, but the
# provision script must not rely on it.
export LANG=C.UTF-8
unset LC_ALL LANGUAGE
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

echo ">>> Waiting for Ubuntu's first-boot apt jobs to finish..."
# A freshly installed Lubuntu kicks off apt-daily / unattended-upgrades (and
# the desktop's update notifier) right after the first login, and they hold the
# apt/dpkg locks, so our first apt-get would die with "Could not get lock
# /var/lib/apt/lists/lock". Pause the timers so nothing new starts
# mid-provision, wait out a job that really holds the apt/dpkg lock, and tell
# apt itself to wait on a held lock rather than fail.
systemctl stop apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
command -v cloud-init >/dev/null 2>&1 && timeout 120 cloud-init status --wait >/dev/null 2>&1 || true
# Wait only while a process actually HOLDS one of apt/dpkg's lock files.
# Matching process names doesn't work: unattended-upgrades keeps a shutdown
# helper (unattended-upgrade-shutdown --wait-for-signal) running all day, so a
# name check would always wait the full time for nothing. Who holds a lock is
# printed, and after 3 minutes we carry on anyway; apt's own
# DPkg::Lock::Timeout (set just below) then waits for the lock instead of failing.
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

# A Lubuntu install can leave packages marked "automatically installed" that
# nothing depends on any more (the installer's own leftovers, or tools you
# rely on that came in as a dependency). The autoremove at the end of this
# script, and the weekly one in agentic-update, would delete them, which is not
# what anyone asked for. So on the first run, before we install or remove
# anything, mark whatever is already autoremovable as manually installed.
# Autoremove then only takes what this script itself leaves orphaned. The
# marker file keeps later runs from doing it again.
if [ ! -f /etc/agentic/os-packages-kept ]; then
  # Simulate (-s) an autoremove; each "Remv <pkg> [...]" line is one package.
  OS_LEFTOVERS="$(apt-get -s autoremove 2>/dev/null | awk '/^Remv /{print $2}')"
  if [ -n "$OS_LEFTOVERS" ]; then
    # shellcheck disable=SC2086
    apt-mark manual $OS_LEFTOVERS >/dev/null 2>&1 || true
    echo "    keeping the OS's own unused packages (not auto-removed): $(echo $OS_LEFTOVERS | wc -w)"
  fi
  mkdir -p /etc/agentic
  printf '%s\n' $OS_LEFTOVERS > /etc/agentic/os-packages-kept
fi

echo ">>> Setting timezone to $AGENTIC_TZ..."
# Chosen at the prompt (defaults to what the Lubuntu installer already set, or
# America/New_York when the machine is still on UTC). The weekly update runs at 4 AM
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
# A locale you picked in the Lubuntu installer (say en_GB.UTF-8)
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
# full-upgrade, not upgrade: on a desktop install new kernels and meta-package
# changes (linux-generic, HWE) arrive as dependency changes that a plain
# `apt-get upgrade` holds back. A new kernel is picked up by the reboot offered
# at the end.
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
# software-properties-common gives add-apt-repository (handy for PPAs); nice to
# have, never required.
apt-get install -y -qq software-properties-common 2>/dev/null || true
# Set to yes by any step whose change only applies after a reboot or a fresh
# login (the kvm group for Cowork); the deployer then offers the reboot.
REBOOT_NEEDED=no
# Was the Claude user already in group kvm before this run? agentic-setup-user
# adds them further down, and a group change only reaches NEW logins — so if
# they weren't, the desktop session that ran this script can't start Cowork yet.
KVM_WAS_MEMBER=no
if id -nG "$AGENTIC_PRIMARY" 2>/dev/null | grep -qw kvm; then KVM_WAS_MEMBER=yes; fi

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
# Claude Code runs as this normal account, never as root. On Lubuntu it is
# usually the account the installer created (kept as-is, groups and all); a new
# one is created with the groups a desktop login needs (sound, video/GPU,
# input, removable media, network, printers). The Claude
# setup itself comes later, from agentic-setup-user, once the toolchains exist.
for u in $AGENTIC_USERS; do
  if id "$u" >/dev/null 2>&1; then
    echo "    $u already exists; keeping it"
  else
    useradd -m -s /bin/bash "$u"
    for g in video render audio input plugdev netdev lpadmin dialout; do
      if getent group "$g" >/dev/null; then usermod -aG "$g" "$u"; fi
    done
    echo "    created $u"
  fi
  # An existing sudoer is never removed from sudo here — on a desktop that
  # account is often the only admin, and dropping it would lock you out.
  if [ "$AGENTIC_SUDO" = yes ]; then usermod -aG sudo "$u"; fi
done
# user:password lines from the deployer (root's, plus the user's when it was
# set); deleted the moment they're applied.
chpasswd < /root/agentic-provision.chpasswd
rm -f /root/agentic-provision.chpasswd
# Ubuntu's sudo asks for the password by default, but a NOPASSWD rule added
# later (in /etc/sudoers.d) would make an auto-mode agent one full-path `sudo`
# away from root — the deny rules don't follow full paths.
# Answered at the prompt (default yes): from now on sudo asks for the password,
# which Claude can't type.
if [ "$AGENTIC_FIX_NOPASSWD" = yes ]; then
  # Every sudoers file (the main one and each drop-in) with a NOPASSWD rule for
  # the user, for ALL, or for one of the user's groups (%sudo, ...): back it up
  # once, strip the NOPASSWD: tags, and keep the edit only if visudo still
  # accepts the file (a broken sudoers file would lock everyone out of sudo).
  for u in $AGENTIC_USERS; do
    PRINCIPALS="$u ALL"
    for g in $(id -nG "$u"); do PRINCIPALS="$PRINCIPALS %$g"; done
    for f in /etc/sudoers /etc/sudoers.d/*; do
      [ -f "$f" ] || continue
      HITS=""
      for p in $PRINCIPALS; do
        if grep -qE "^[[:space:]]*${p}[[:space:]].*NOPASSWD" "$f"; then HITS="$HITS $p"; fi
      done
      [ -n "$HITS" ] || continue
      BAK="/root/$(basename "$f").agentic-bak"
      cp -a "$f" "$BAK"
      for p in $HITS; do
        sed -i -E "s/^([[:space:]]*${p}[[:space:]].*)NOPASSWD:[[:space:]]*/\1/" "$f"
      done
      if visudo -cf "$f" >/dev/null; then
        echo "   $HITS: sudo now asks for a password (was NOPASSWD in $f; backup: $BAK)"
      else
        cp -a "$BAK" "$f"
        echo "    [WARN] edited $f failed visudo; restored it unchanged"
      fi
    done
    # Then ask sudo itself, which sees every file and rule (and Defaults
    # !authenticate, which isn't edited here).
    if sudo -l -U "$u" 2>/dev/null | grep -qE 'NOPASSWD|!authenticate'; then
      echo "    [WARN] $u can still use sudo without a password ('sudo -l -U $u' shows the rule); fix it by hand with visudo"
    fi
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
    # Written AS the user (the key comes in on stdin, since they can't read
    # root's copy): a symlink planted in their home can't redirect a root
    # write. sshd wants ~/.ssh 700 and authorized_keys 600.
    runuser -u "$u" -- sh -c 'cd "$1" && install -d -m 700 .ssh && k="$(cat)" \
      && { grep -qxF "$k" .ssh/authorized_keys 2>/dev/null || printf "%s\n" "$k" >> .ssh/authorized_keys; } \
      && chmod 600 .ssh/authorized_keys' sh "$h" < /root/agentic-provision.pub
  done
fi
rm -f /root/agentic-provision.pub
# The Claude user, read by agentic-setup-user / agentic-doctor / agentic-update.
mkdir -p /etc/agentic
cat > /etc/agentic/users.conf << EOF
# The Claude Code user on this machine (one per box).
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
# The trace is off for this block too (it would print the topic and token),
# and the values are dropped from the environment right after.
set +x
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
unset AGENTIC_NTFY_TOPIC AGENTIC_NTFY_SERVER AGENTIC_NTFY_TOKEN
set -x
rm -f /root/agentic-provision.env

echo ">>> Setting up the shared toolchain environment..."
# Toolchains are installed once, system-wide (root-owned, updated by
# agentic-update); the user's shells and the CloudCLI service point at them.
# /etc/environment covers PAM logins (SSH, su, sudo -i); /etc/profile.d covers
# login shells; the bashrc block below covers
# terminals opened on the desktop (QTerminal).
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
# npm 12+ blocks packages' install scripts unless they're on an allowlist, so
# CloudCLI's native modules (better-sqlite3, node-pty, bcrypt) would never
# compile and the service would crash-loop with nothing on :3001. Allow exactly
# those four and nothing else: every other global tool here installs without
# scripts, and a compromised package anywhere else can't run code as root at
# install time. Set NOW, before the installs below; it persists to /root/.npmrc.
# npm <12 rejects the key (and runs all scripts anyway), hence the || true.
# An older deploy's allow-everything setting is removed.
NPM_ALLOW_SCRIPTS="@cloudcli-ai/cloudcli,bcrypt,better-sqlite3,node-pty"
npm config delete dangerously-allow-all-scripts 2>/dev/null || true
npm config set allow-scripts="$NPM_ALLOW_SCRIPTS" 2>/dev/null || true

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
  # Downloaded into a fresh private temp dir, and checked against the sha256
  # go.dev publishes for this exact file before anything is unpacked.
  GO_TGZ="${GO_VERSION}.linux-${GO_ARCH}.tar.gz"
  GO_SHA="$(curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r --arg f "$GO_TGZ" '.[].files[] | select(.filename == $f) | .sha256')"
  GO_TMP="$(mktemp -d)"
  curl -fsSL "https://go.dev/dl/$GO_TGZ" -o "$GO_TMP/go.tar.gz"
  if [ -z "$GO_SHA" ] || ! echo "$GO_SHA  $GO_TMP/go.tar.gz" | sha256sum -c --quiet -; then
    rm -rf "$GO_TMP"
    echo "!!! $GO_TGZ doesn't match the checksum on go.dev; not installing it"
    exit 1
  fi
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$GO_TMP/go.tar.gz"
  rm -rf "$GO_TMP"
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
# natively on Lubuntu as the one user — no containers. (Cowork's VM is the one
# exception, and Claude Desktop starts and manages it by itself.) Services a
# project needs (PostgreSQL, Redis, ...) are installed with apt and run as
# normal systemd services.

echo ">>> Writing shared Claude Code defaults (permissions + env + plugins)..."
# Claude Code itself is installed for the user (by agentic-setup-user, below) —
# the native installer puts it in ~/.local/bin and `claude update` must be able
# to write there. The defaults live in /usr/local/share/agentic: the settings
# template ~/.claude/settings.json starts from, the webapp-testing skill, and
# the shell block (used again if you re-run agentic-setup-user).
#
# enabledPlugins: `claude plugin install X@mkt` installs a plugin but leaves it
# disabled. Whether it's on is read from enabledPlugins in the user settings
# (~/.claude/settings.json, which this template becomes), and that is honored
# in non-interactive runs and containers too. Without this block every plugin
# below (the LSP servers included) stays off, and CloudCLI's /project chat
# shows only the one local skill. Enabled skills show up after the cloudcli
# restart at the end; no new session is needed.
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
      "Read(**/id_ecdsa)",
      "Read(~/.ssh/**)",
      "Read(~/.config/gh/hosts.yml)",
      "Read(~/.git-credentials)",
      "Read(~/.netrc)",
      "Read(~/.npmrc)",
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
# Cloned into a fresh private temp dir (a fixed /tmp path could already exist,
# left over or made by someone else, and stop a re-run).
SKILLS_TMP="$(mktemp -d)"
git clone --depth 1 --filter=blob:none --sparse https://github.com/anthropics/skills.git "$SKILLS_TMP/skills"
cd "$SKILLS_TMP/skills" && git sparse-checkout set skills/webapp-testing
rm -rf /usr/local/share/agentic/skills/webapp-testing
cp -r "$SKILLS_TMP/skills/skills/webapp-testing" /usr/local/share/agentic/skills/webapp-testing
chmod -R a+rX /usr/local/share/agentic
cd /
rm -rf "$SKILLS_TMP"

echo ">>> Installing Playwright (Python) for the webapp-testing skill..."
# The webapp-testing skill imports the PYTHON playwright package
# ("from playwright.sync_api import ..."), so the Node playwright we install for
# CloudCLI's Browser feature is NOT enough — the pip package must be present too,
# or the skill dies at import. pip runs as root here, so the package lands in the
# system site-packages the user imports from. Both share the same browser cache
# — PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright, not root's ~/.cache, so the
# user can launch it — and Chromium is downloaded once for both.
# Playwright supports Ubuntu 26.04 natively (since 1.61), so
# PLAYWRIGHT_HOST_PLATFORM_OVERRIDE must not be set: it would pull the wrong
# browser build. This whole block is non-fatal: a failed browser install must
# never stop provisioning, which runs under `set -e` and would otherwise skip
# everything after it (SSH, the web UI, the weekly update).
# set +e: until the matching set -e below, a failing command doesn't stop the run.
set +e
unset PLAYWRIGHT_HOST_PLATFORM_OVERRIDE
# The browser cache is root's: root downloads into it and the users can only
# read it, so nothing planted there can redirect a root write. An older deploy
# gave it to the Claude user; such a copy is deleted and downloaded again
# rather than written into.
if [ -d /opt/ms-playwright ] && find /opt/ms-playwright ! -user root -print -quit | grep -q .; then
  echo "    taking /opt/ms-playwright back from the user (re-downloading Chromium)"
  rm -rf /opt/ms-playwright
fi
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
  # Chromium's OS libraries (install-deps, via apt) and the browser itself, both
  # as root into the root-owned cache.
  install -d -m 755 /opt/ms-playwright
  python3 -m playwright install-deps chromium \
    || echo "    [WARN] some of Chromium's OS libraries didn't install (browser tests may fail)"
  if PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright python3 -m playwright install chromium; then
    echo "    Playwright chromium installed in /opt/ms-playwright"
  else
    echo "    [WARN] Playwright browser install failed. Retry later with:"
    echo "      sudo PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright python3 -m playwright install chromium"
  fi
fi
set -e

echo ">>> Setting up /project directory..."
# The Claude user's workspace, owned by them (not root) so Claude can work here.
# /project belongs to the user, so root never writes into it directly (a
# symlink planted there would redirect the write): CLAUDE.md is built in a
# root-private temp file, filled in, then installed by the user.
mkdir -p /project
[ ! -L /project ] || { echo "!!! /project is a symlink; refusing to write through it"; exit 1; }
chown "$AGENTIC_PRIMARY:$AGENTIC_PRIMARY" /project
chmod 755 /project
CLAUDEMD_TMP="$(mktemp)"
cat > "$CLAUDEMD_TMP" << 'CLAUDEMD'
# Claude Code Workspace

## Environment
- **Machine**: a PC or a Proxmox VM running __OS__, with Claude installed straight onto the OS (no container around it)
- **Working directory**: /project
- **Timezone**: __TZ__
- **User**: __USERS__ — a normal (non-root) account. Claude Code runs only as this
  user (root is blocked from running it). One person per machine.

## Available Tools
- **Languages**: Node.js (latest LTS), Python 3 (system default), Go (latest), Rust (latest)
- **Package managers**: npm (`npm i -g` installs into ~/.local for your user), pip
  (use a venv, or `pip install --user --break-system-packages`), cargo (shared toolchain
  in /opt/rust; your crates go to ~/.cargo), go install (~/go/bin)
- **System packages**: `sudo apt install ...` — run by YOU (if given sudo at deploy);
  Claude is denied sudo/su and should ask you to run admin commands
- **No containers**: there is no Docker/LXC here — everything runs natively on
  this machine as __PRIMARY__. Need a database server? Ask the user to `sudo apt install
  postgresql` (or redis-server) and use it as a normal systemd service
- **Web UI**: CloudCLI UI (claudecodeui) on port 3001 — chat, file explorer/editor, git, shell
  (runs as __PRIMARY__)
- **Claude Desktop** (if installed): the Linux desktop app (Chat, Code and
  Cowork) on this machine's LXQt desktop, signed in as __PRIMARY__; updated by
  apt. Cowork runs its tasks in a QEMU/KVM VM that the app manages itself —
  don't start, stop or edit QEMU processes or VM images yourself
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

## Resource tips
- Cowork's VM, Claude Desktop and a Rust build together can use a lot of RAM;
  prefer a few parallel agents/teammates over many on an 8 GB machine.
- Stop dev servers and watchers you no longer need (`npm run dev`, `cargo watch`).
- Close the Playwright browser when a test run is done.
- Check health with `sudo agentic-doctor` (also checks Cowork's KVM/QEMU setup).

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
       -e "s|__OS__|${AGENTIC_OS}|" -e "s|__TZ__|${AGENTIC_TZ}|" "$CLAUDEMD_TMP"
chmod 644 "$CLAUDEMD_TMP"
(cd / && runuser -u "$AGENTIC_PRIMARY" -- install -m 644 "$CLAUDEMD_TMP" /project/CLAUDE.md)
rm -f "$CLAUDEMD_TMP"
# Hand back anything under /project an older run created as root (chown -R
# never follows symlinks).
chown -R "$AGENTIC_PRIMARY:$AGENTIC_PRIMARY" /project

echo ">>> Configuring SSH..."
# Ubuntu's sshd_config Includes /etc/ssh/sshd_config.d/*.conf from the TOP of the
# file and the FIRST value of a keyword wins, so a drop-in (cloud-init ships one
# with PasswordAuthentication no) silently outranks any edit to the main file.
# Own a drop-in that sorts first instead, and keep the main-file edit for images
# that predate the Include.
# The user logs in with a password or a key. Root: key only (prohibit-password)
# unless "password" was chosen at the prompt. MaxAuthTries caps guesses per
# connection.
if [ "${AGENTIC_ROOT_SSH:-key}" = password ]; then ROOT_LOGIN=yes; else ROOT_LOGIN=prohibit-password; fi
# Save the main file's original two lines on the first run only (re-runs
# would save our own edits; a box deployed by an older version, which already
# has our drop-in, is skipped for the same reason), so --uninstall can put
# them back as they were.
if [ ! -f /etc/agentic/sshd-original ] && [ ! -f /etc/ssh/sshd_config.d/00-agentic.conf ] \
   && [ -f /etc/ssh/sshd_config ]; then
  mkdir -p /etc/agentic
  { grep -m1 -E '^#*PermitRootLogin' /etc/ssh/sshd_config || true
    grep -m1 -E '^#*PasswordAuthentication' /etc/ssh/sshd_config || true
  } > /etc/agentic/sshd-original
fi
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin $ROOT_LOGIN/" /etc/ssh/sshd_config
sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" /etc/ssh/sshd_config
# Claude Desktop's SSH sessions copy files over SFTP; Ubuntu ships the line, but
# make sure it's there.
grep -qE '^[[:space:]]*Subsystem[[:space:]]+sftp' /etc/ssh/sshd_config \
  || echo 'Subsystem sftp /usr/lib/openssh/sftp-server' >> /etc/ssh/sshd_config
if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config; then
  mkdir -p /etc/ssh/sshd_config.d
  cat > /etc/ssh/sshd_config.d/00-agentic.conf <<SSHD
# Managed by the Claude Code Lubuntu deployer. Sorts before any other drop-in,
# and sshd keeps the first value it sees, so these win over cloud-init's defaults.
# root SSH: ${AGENTIC_ROOT_SSH:-key} (chosen at deploy; re-run the deployer to change it)
PermitRootLogin $ROOT_LOGIN
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

# ── Claude Code Lubuntu ────────────────────────────────────
export EDITOR=nano
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

# Always start in /project
cd /project 2>/dev/null || true
BASHRC
grep -q '── Claude Code Lubuntu ──' /root/.bashrc 2>/dev/null \
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
# sudo (and, with Claude Desktop, kvm) groups, their own Claude Code install,
# the shared settings/ plugins/skills, shell block, npm and git defaults. Safe
# to re-run: an existing ~/.claude/settings.json and ~/.bashrc block are kept.
# Single-user by design — it refuses a second user; use another machine (or
# the Proxmox deployer) for another person.
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
  echo "This machine is single-user: Claude already runs as '$AGENTIC_PRIMARY'." >&2
  echo "Set up another machine for '$u' instead." >&2
  exit 1
fi

if ! id "$u" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$u"
  echo ">>> [$u] created user (set a password with: sudo passwd $u)"
fi
if [ "$AGENTIC_SUDO" = yes ]; then usermod -aG sudo "$u"; fi
# Cowork's VM needs /dev/kvm and /dev/vhost-vsock, which belong to group kvm.
if [ "$AGENTIC_DESKTOP" = yes ] && getent group kvm >/dev/null; then usermod -aG kvm "$u"; fi
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
# (npm 12+) is per user too, and gets the same four CloudCLI native modules as
# root's; anything else asks first (`npm approve-scripts` in that project).
as_user npm config set prefix "$h/.local"
as_user npm config delete dangerously-allow-all-scripts 2>/dev/null || true
as_user npm config set allow-scripts="@cloudcli-ai/cloudcli,bcrypt,better-sqlite3,node-pty" 2>/dev/null || true

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

# Everything in the user's home is written AS the user (as_user), never by
# root: a symlink the user (or an agent running as them) planted there would
# otherwise redirect a root write — ~/.claude -> /etc would hand them /etc.
# The chown -R first takes back anything an older version created as root;
# it never follows symlinks.
# ~/.claude is private (it holds the login). The shared settings template is
# copied only when the user has no settings.json yet, so yours is never
# overwritten by a re-run. An existing one only gains the template's deny rules
# it doesn't have yet (new secret paths added to this script); everything else
# in it is left alone. (So a template deny rule you deleted comes back on the
# next run; deny always beats allow, so edit the template above to drop one.)
if [ -e "$h/.claude" ]; then chown -R "$u:$u" "$h/.claude"; fi
as_user install -d -m 700 "$h/.claude"
as_user install -d "$h/.claude/skills"
as_user sh -c '[ -e "$1" ] || install -m 644 "$2" "$1"' sh "$h/.claude/settings.json" "$SHARE/claude-settings.json"
# jq: append each template deny rule that's missing, keeping the file's order.
# Written only if something changed and the result is valid; a settings.json
# jq can't parse is left as it is.
DENY_MERGE='(.permissions.deny // []) as $d | .permissions.deny = $d + [$t[0].permissions.deny[] | select(. as $x | $d | index($x) | not)]'
as_user bash -c 'f="$1"; [ -f "$f" ] && [ ! -L "$f" ] || exit 0
  n="$(mktemp "$f.XXXXXX")" || exit 0
  if jq --slurpfile t "$2" "$3" "$f" > "$n" 2>/dev/null \
     && [ "$(jq ".permissions.deny | length" "$n")" != "$(jq ".permissions.deny | length" "$f")" ]; then
    chmod 644 "$n" && mv "$n" "$f" && echo "    added new deny rules to settings.json"
  else
    rm -f "$n"
  fi' sh "$h/.claude/settings.json" "$SHARE/claude-settings.json" "$DENY_MERGE"

echo ">>> [$u] Adding plugin marketplaces..."
# The official marketplace is auto-registered on first INTERACTIVE launch only,
# so a non-interactive provisioning run must add it explicitly. Only the
# first-party marketplace is used: the 'anthropics/claude-code' demo repo
# (it registers as 'claude-code-plugins') ships example plugins with the same
# names, which would shadow the official ones.
as_user "$CLAUDE_BIN" plugin marketplace add anthropics/claude-plugins-official \
  || echo "    [WARN] could not add claude-plugins-official"
# Refresh the index BEFORE installing: with a stale cache, name@official can
# quietly fail to resolve.
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
if [ -d "$SHARE/skills/webapp-testing" ]; then
  as_user sh -c '[ -e "$1" ] || cp -r "$2" "$1"' sh "$h/.claude/skills/webapp-testing" "$SHARE/skills/webapp-testing"
fi
as_user sh -c 'grep -q "$1" "$2" 2>/dev/null || cat "$3" >> "$2"' sh '── Claude Code Lubuntu ──' "$h/.bashrc" "$SHARE/bashrc"
as_user git config --global init.defaultBranch main
as_user git config --global core.editor nano
as_user git config --global pull.rebase false

# Record the user so agentic-doctor / agentic-update cover them.
if [ -z "$AGENTIC_PRIMARY" ]; then
  mkdir -p /etc/agentic
  cat > "$CONF" << EOF
# The Claude Code user on this machine (one per box).
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
(cd / && runuser -u "$AGENTIC_PRIMARY" -- install -d -m 700 "$PRIMARY_HOME/.cloudcli")
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
# The build this Playwright version wants (a no-op when it's already there),
# into the root-owned browser cache.
install -d -m 755 /opt/ms-playwright
PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright playwright install chromium \
  || echo "    [WARN] Chromium download failed; retry later with: sudo PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright playwright install chromium"
# The browser cache stays root's and readable by everyone. A project that pins
# a different Playwright version can keep its own browsers in the user's home:
# PLAYWRIGHT_BROWSERS_PATH=~/.cache/ms-playwright npx playwright install.
if [ -d /opt/ms-playwright ]; then
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
# Listen on :3001, on localhost only (reach it through an SSH tunnel) unless
# LAN access was chosen at deploy; drive this user's claude and keep the web
# UI's own login database in their home.
Environment=HOST=${AGENTIC_WEBUI_BIND:-127.0.0.1}
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

# Load the new unit and start it at every boot. It's started at the very end,
# once the user's Claude setup, tools and permissions are all in place.
systemctl daemon-reload
systemctl enable cloudcli >/dev/null 2>&1 || true

if [ "$AGENTIC_DESKTOP" = yes ]; then
  echo ">>> Installing Claude Desktop with Cowork (Linux beta)..."
  # From Anthropic's apt repository, as documented at
  # code.claude.com/docs/en/desktop-linux, so updates arrive with normal apt
  # upgrades (and the weekly agentic-update). The key is checked against
  # Anthropic's published fingerprint before the repo is trusted. The app
  # refuses to run as root; it runs in the desktop session as the Claude user.
  # Non-fatal: a failure here never stops the rest of the provisioning.
  #
  # Cowork runs its tasks in a VM that the app hosts itself with QEMU + KVM.
  # Per the "Cowork requirements" in those docs it needs:
  #   1. QEMU, UEFI firmware and virtiofsd — qemu-system-x86 + ovmf + virtiofsd
  #      on x86_64, qemu-system-arm + qemu-efi-aarch64 + virtiofsd on arm64.
  #      claude-desktop only *Recommends* them, so they're named explicitly
  #      here: a box with Recommends turned off would otherwise miss them and
  #      Cowork would just say "Cowork requires QEMU".
  #   2. The user in group kvm — for /dev/kvm and /dev/vhost-vsock (the latter
  #      only kvm members can open, even where the desktop grants /dev/kvm).
  #   3. The vhost_vsock kernel module, loaded now and on every boot.
  #   4. Hardware virtualization switched on in the BIOS/UEFI — that one can't
  #      be fixed from here; the deployer checked it before starting and warned.
  # Also added: cpu-checker (`kvm-ok` explains a missing /dev/kvm), and
  # gnome-keyring + libpam-gnome-keyring — LXQt has no keyring of its own, and
  # Claude Desktop keeps its sign-in there; the PAM part unlocks it at login.
  case "$(dpkg --print-architecture)" in
    arm64) CD_EXTRA_WANTED=(qemu-system-arm qemu-efi-aarch64 virtiofsd) ;;
    *)     CD_EXTRA_WANTED=(qemu-system-x86 ovmf virtiofsd) ;;
  esac
  CD_EXTRA_WANTED+=(cpu-checker gnome-keyring libpam-gnome-keyring)
  # apt rejects the whole install for one unknown name, so skip any this
  # release doesn't carry (and say so).
  # CD_EXTRA = the wanted Cowork/keyring packages this release really has;
  # they go into the same apt call as claude-desktop below.
  CD_EXTRA=()
  for pkg in "${CD_EXTRA_WANTED[@]}"; do
    if apt-cache show "$pkg" >/dev/null 2>&1; then
      CD_EXTRA+=("$pkg")
    else
      echo "    [WARN] $pkg is not in this release's archive; skipped"
    fi
  done
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
    if apt-get install -y -qq claude-desktop "${CD_EXTRA[@]}"; then
      echo "    Claude Desktop $(dpkg-query -W -f='${Version}' claude-desktop 2>/dev/null) installed"
    else
      echo "    [WARN] claude-desktop install failed; retry later with: sudo apt install claude-desktop"
    fi
  else
    rm -f "$CD_KEY"
    echo "    [WARN] Claude Desktop signing key missing or wrong fingerprint; skipped"
  fi
  # Cowork's packages go on even if the app itself failed, so a later
  # `sudo apt install claude-desktop` is the only step left.
  if ! dpkg -s claude-desktop >/dev/null 2>&1 && [ "${#CD_EXTRA[@]}" -gt 0 ]; then
    apt-get install -y -qq "${CD_EXTRA[@]}" \
      || echo "    [WARN] Cowork's QEMU/KVM packages failed to install"
  fi
  # Only a warning; nothing is installed here. Either session folder counts,
  # as in the same check in the deployer's prompts.
  # No session file in either folder = no graphical desktop (warning only).
  if ! compgen -G '/usr/share/wayland-sessions/*.desktop' >/dev/null \
     && ! compgen -G '/usr/share/xsessions/*.desktop' >/dev/null; then
    echo "    [WARN] no desktop session found — Claude Desktop needs a graphical desktop to launch (on a server install: sudo apt install lubuntu-desktop)"
  fi
  # Ubuntu's SDDM PAM file calls pam_gnome_keyring when the module is present;
  # if a customised one doesn't, the keyring asks for the password on first use.
  if [ -f /etc/pam.d/sddm ] && ! grep -q pam_gnome_keyring /etc/pam.d/sddm; then
    echo "    [WARN] /etc/pam.d/sddm doesn't unlock the keyring at login; Claude Desktop may ask you to unlock it"
  fi

  echo ">>> Setting up Cowork's VM access (kvm group, vhost_vsock module)..."
  # The kvm group normally exists (systemd's udev rules create it and give it
  # /dev/kvm and /dev/vhost-vsock); create it if a trimmed image lacks it.
  getent group kvm >/dev/null || groupadd --system kvm
  # (agentic-setup-user normally added the user already; this covers a kvm
  # group that had to be created just now.)
  for u in $AGENTIC_USERS; do usermod -aG kvm "$u"; done
  if [ "$KVM_WAS_MEMBER" = no ]; then
    # Group changes only reach NEW logins: the desktop session that ran this
    # script doesn't have kvm yet, so Cowork works after logout/login or reboot.
    REBOOT_NEEDED=yes
    echo "    $AGENTIC_PRIMARY added to group kvm (takes effect at the next login)"
  else
    echo "    $AGENTIC_PRIMARY was already in group kvm"
  fi
  # vhost_vsock is the host side of the virtio socket the app uses to talk to
  # the Cowork VM. It isn't autoloaded, so load it now and list it in
  # modules-load.d for every boot (the docs' own fix for "Cowork requires the
  # vhost_vsock kernel module").
  cat > /etc/modules-load.d/claude-cowork.conf << 'MODULES'
# Claude Desktop Cowork: host side of the virtio socket to its QEMU/KVM VM.
# Written by the Claude Code Lubuntu deployer.
vhost_vsock
MODULES
  if [ ! -d "/lib/modules/$(uname -r)" ]; then
    # The docs call this out: no module directory for the running kernel means
    # the module can't be loaded at all (typical of containers and ChromeOS).
    echo "    [WARN] /lib/modules/$(uname -r) is missing; vhost_vsock can't load until you boot a kernel that has it"
  elif modprobe vhost_vsock; then
    echo "    vhost_vsock loaded (and set to load on every boot)"
  else
    echo "    [WARN] modprobe vhost_vsock failed; it's set to load at boot — check after a reboot with: lsmod | grep vhost_vsock"
  fi
  # KVM itself (kvm_intel / kvm_amd) is autoloaded by udev when the CPU
  # supports it. Report what Cowork will find; nothing here can switch on
  # virtualization in the firmware.
  if [ -e /dev/kvm ]; then
    echo "    /dev/kvm present — Cowork's VM can use hardware virtualization"
  else
    echo "    [WARN] /dev/kvm missing — turn on VT-x/AMD-V (or nested virtualization) and reboot; 'kvm-ok' explains why"
  fi
fi

echo ">>> Installing coordinated update tooling (agentic-update / agentic-doctor / agentic-errorlog)..."
# Three tools, written below:
#   agentic-errorlog  files WARN/FAIL lines in Agentic-Errors.txt (+ optional ntfy)
#   agentic-doctor    the health check
#   agentic-update    one coordinated update pass, in this order: OS packages ->
#                     npm and the global dev tools (Playwright, gopls) -> Rust ->
#                     the user's Claude Code -> the CloudCLI web UI (restarted)
#                     -> agentic-doctor -> problems filed by agentic-errorlog.
# Modeled on homelabhero's hh-update + hh doctor. They run as root, act on the
# user named in /etc/agentic/users.conf, and can be run by hand at any time.
# Everything tracks the latest release (nothing pinned); the health check at
# the end is the safety net. The log is /var/log/agentic-update.log.

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
# Health check for the Claude Code Lubuntu box. Exit 0 = healthy, non-zero = problems.
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
  # sudo -l -U lists every rule that applies to the user (their own, group
  # rules like %sudo, any file); NOPASSWD or !authenticate there means an
  # auto-mode agent could become root without the password.
  note  "$u: sudo asks for a password (no NOPASSWD rule)" "! sudo -l -U '$u' 2>/dev/null | grep -qE 'NOPASSWD|!authenticate'"
  note  "$u: claude logged in (creds on disk; run 'claude' /login as $u if WARN)" "test -s '$h/.claude/.credentials.json'"
done
# Shared toolchains and services.
check "shared Rust toolchain"       "RUSTUP_HOME=/opt/rust/rustup /opt/rust/cargo/bin/rustc --version"
check "GitHub CLI (gh) present"     "command -v gh"
check "cloudcli service active"     "systemctl is-active --quiet cloudcli"
check "cloudcli runs as ${AGENTIC_PRIMARY:-<primary>}" "[ \"\$(systemctl show -p User --value cloudcli)\" = '$AGENTIC_PRIMARY' ]"
check "UI listening on :3001"       "ss -ltn | grep -q ':3001'"
# Claude Desktop + Cowork (only when they were installed). The packages, group
# and module are this box's own setup (check = FAIL when broken); hardware
# virtualization and the live device nodes depend on firmware/reboots (note).
if [ "$AGENTIC_DESKTOP" = yes ]; then
  check "Claude Desktop installed"    "dpkg -s claude-desktop"
  check "Cowork: QEMU present"        "command -v qemu-system-x86_64 || command -v qemu-system-aarch64"
  check "Cowork: UEFI firmware present (ovmf / qemu-efi-aarch64)" "ls /usr/share/OVMF/OVMF_CODE*.fd /usr/share/AAVMF/AAVMF_CODE*.fd /usr/share/qemu-efi-aarch64/QEMU_EFI.fd 2>/dev/null | grep -q ."
  check "Cowork: virtiofsd present"   "[ -x /usr/libexec/virtiofsd ] || [ -x /usr/lib/qemu/virtiofsd ] || command -v virtiofsd"
  check "Cowork: vhost_vsock set to load at boot" "grep -qx vhost_vsock /etc/modules-load.d/claude-cowork.conf"
  for u in $AGENTIC_USERS; do
    check "Cowork: $u in kvm group"   "id -nG '$u' | grep -qw kvm"
  done
  note "Cowork: hardware virtualization on (/dev/kvm; else enable VT-x/AMD-V in BIOS)" "test -e /dev/kvm"
  note "Cowork: /dev/vhost-vsock present (else: sudo modprobe vhost_vsock)" "test -e /dev/vhost-vsock"
fi
# Machine health: swap and memory
note "swap active"                  "swapon --noheadings | grep -q ."
note "over 1 GB memory available"   "[ \$(awk '/MemAvailable/{print \$2}' /proc/meminfo) -gt 1048576 ]"
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
# Coordinated update pass for the Claude Code Lubuntu box.
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

echo ">>> [1/6] OS packages (Node.js patches within its LTS line, gh, Claude Desktop, QEMU, kernel)..."
# full-upgrade, so new kernels and meta-package changes aren't held back.
apt-get update -qq && apt-get full-upgrade -y -qq && apt-get autoremove -y -qq && apt-get clean -qq \
  || echo "    [WARN] OS package update failed"

echo ">>> [2/6] npm + global dev tools (incl. Playwright) + gopls..."
npm install -g --no-fund --no-audit --loglevel=error --ignore-scripts npm@latest || echo "    [WARN] npm self-update failed"
# npm 12+ only runs install scripts for packages on an allowlist. Allow just
# CloudCLI's native modules (better-sqlite3, node-pty, bcrypt), which must
# compile or cloudcli crash-loops with nothing on :3001. Set again on every run
# (after npm@latest, in case npm just reached 12, and before the CloudCLI step
# below), and an older allow-everything setting is removed. The users get the
# same list: CloudCLI's in-app plugin installs run as them.
NPM_ALLOW_SCRIPTS="@cloudcli-ai/cloudcli,bcrypt,better-sqlite3,node-pty"
npm config delete dangerously-allow-all-scripts 2>/dev/null || true
npm config set allow-scripts="$NPM_ALLOW_SCRIPTS" 2>/dev/null || true
for u in $AGENTIC_USERS; do
  as_user "$u" npm config delete dangerously-allow-all-scripts >/dev/null 2>&1 || true
  as_user "$u" npm config set allow-scripts="$NPM_ALLOW_SCRIPTS" >/dev/null 2>&1 || true
done
# The global dev tools and npm-based language servers the deployer installed
# (re-running the deployer skips them, so they're kept current here). Only the
# ones still installed are touched; CloudCLI has its own step below.
# Builds a <pkg>@latest list of the tools that are still installed, so one
# npm call updates them all; a tool you uninstalled is not brought back. None
# of them needs an install script, so they run with --ignore-scripts: root
# runs this unattended every week, and that keeps a compromised release of any
# package in their trees from running code at install time.
NPM_TOOLS=()
for pkg in typescript ts-node eslint prettier typescript-language-server pyright playwright; do
  npm ls -g --depth=0 "$pkg" >/dev/null 2>&1 && NPM_TOOLS+=("${pkg}@latest")
done
if [ ${#NPM_TOOLS[@]} -gt 0 ]; then
  npm install -g --no-fund --no-audit --loglevel=error --ignore-scripts "${NPM_TOOLS[@]}" \
    && echo "    updated: ${NPM_TOOLS[*]}" \
    || echo "    [WARN] global dev tool update failed"
fi
# Playwright: the pip package follows the npm one to its latest release, then
# the Chromium build each one wants is fetched into the root-owned cache. A
# cache an older deploy gave to the Claude user is deleted and downloaded again
# rather than written into, so nothing planted there can redirect a root write.
if python3 -c 'import playwright' >/dev/null 2>&1; then
  pip install -U -q --break-system-packages --root-user-action=ignore playwright \
    || echo "    [WARN] pip playwright update failed"
fi
if [ -d /opt/ms-playwright ] && find /opt/ms-playwright ! -user root -print -quit | grep -q .; then
  rm -rf /opt/ms-playwright && install -d -m 755 /opt/ms-playwright
fi
pw_chromium() {  # pw_chromium <playwright command...>: fetch the Chromium it wants
  PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright "$@" install chromium
}
if [ -d /opt/ms-playwright ]; then
  if command -v playwright >/dev/null 2>&1; then
    pw_chromium playwright >/dev/null || echo "    [WARN] Chromium download for the npm Playwright failed"
  fi
  if python3 -c 'import playwright' >/dev/null 2>&1; then
    pw_chromium python3 -m playwright >/dev/null || echo "    [WARN] Chromium download for the Python Playwright failed"
  fi
  chmod -R a+rX /opt/ms-playwright
fi
# gopls, the Go language server behind the gopls-lsp plugin (only when the
# deployer installed it).
if [ -x /usr/local/bin/gopls ] && [ -x /usr/local/go/bin/go ]; then
  GOBIN=/usr/local/bin /usr/local/go/bin/go install golang.org/x/tools/gopls@latest \
    && echo "    gopls updated" || echo "    [WARN] gopls update failed"
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
# A new kernel only takes effect after a reboot; we don't reboot an
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
# Weekly coordinated update - Sunday 4:00 AM (this machine's local time)
# (OS incl. Claude Desktop, npm tools, Rust, Claude Code, CloudCLI UI,
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

# Start (or restart) the web UI last, now that everything it drives is ready.
if [ -f /etc/systemd/system/cloudcli.service ]; then
  echo ">>> Starting the web UI..."
  systemctl restart cloudcli \
    || echo "    [WARN] cloudcli service failed to start; check 'journalctl -u cloudcli'"
fi

echo ">>> Cleaning up..."
# Remove packages nothing depends on any more, and apt's downloaded .deb cache.
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
      printf 'AGENTIC_WEBUI_BIND=%q\n' "$CT_WEBUI_BIND"
      printf 'AGENTIC_ROOT_SSH=%q\n' "$CT_ROOT_SSH"
      printf 'AGENTIC_TZ=%q\n' "$CT_TZ"
      printf 'AGENTIC_DESKTOP=%q\n' "$CT_DESKTOP"
      printf 'AGENTIC_FIX_NOPASSWD=%q\n' "$CT_FIX_NOPASSWD"
      printf 'AGENTIC_OS=%q\n' "$HOST_OS"
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
# The stand-in for the Proxmox Notes panel: a Markdown card in
# /etc/agentic/README.md, with a copy in the user's home. Uses placeholders so
# the heredoc can stay single-quoted (no accidental expansion of backticks/$).
write_notes() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  ip="${ip:-<machine-ip>}"

  local notes
  notes=$(cat <<'EOF'
# 🤖 Claude Code on Lubuntu (__HOST__)

__WEBUI_LINE__
**SSH:** `ssh __USER__@__IP__` (or `ssh __USER__@__HOST__.local`)   |   **Console:** log in as root, then `su - __USER__`

## Start Claude Code
Claude runs as **__USER__** only — never root (`claude` refuses to run as root).
Log in as __USER__, then run `claude` (the shell auto-cd's to `/project`).

## Claude Desktop & Cowork
__DESKTOP__

## Update & health
- `sudo agentic-update` — one coordinated pass: OS (incl. Claude Desktop, QEMU) → npm tools → Rust → Claude Code → Web UI → health check
- `sudo agentic-doctor` — the health check on its own (also Cowork's KVM/QEMU/vsock requirements)
- Auto-runs weekly (Sunday 4 AM, __TZ__). Log: `/var/log/agentic-update.log`
- Any WARN/FAIL from either is also appended to `Agentic-Errors.txt` on __USER__'s desktop (home folder if there is none); delete it once dealt with
- Optional ntfy phone alerts for the same problems: set `NTFY_TOPIC` in `/etc/agentic/ntfy.conf`, then `sudo agentic-errorlog --test-ntfy`

## Running in a Proxmox VM
If this box is a Proxmox VM, Cowork needs nested virtualization: CPU type `host` (`qm set <vmid> --cpu host`, then stop/start the VM) and nested KVM on on the host (`cat /sys/module/kvm_intel/parameters/nested` → `Y`; `kvm_amd` → `1`). Give it 8 GB+ RAM, 4+ cores, ~40 GB disk. Optional: `sudo apt install qemu-guest-agent` here and turn on QEMU Guest Agent in the VM's Options, for clean shutdowns and the IP in Proxmox.

## Service & config
- `systemctl status cloudcli` — the Web UI service, runs as **__USER__** (`journalctl -u cloudcli` for logs)
- Permissions: **auto mode** + secret/sudo deny-floor — `~/.claude/settings.json`
- Repair the user's Claude setup: `sudo agentic-setup-user`
- Install logs: `/var/log/agentic-deploy/`, `/var/log/agentic-provision.log`

---
_IP above is the address at deploy time; on DHCP it may change (check with `hostname -I`)._
EOF
)
  local desk
  if [[ "$CT_DESKTOP" == yes ]]; then
    desk="Log in to the desktop as **$CT_PRIMARY_USER**, open **Claude** from the menu (or run \`claude-desktop\`) and sign in. Chat, Code and Cowork are set up; Cowork runs its tasks in a small QEMU/KVM VM that the app manages itself. Virtualization at deploy time: $VIRT_NOTE. If Cowork reports a missing requirement, run \`sudo agentic-doctor\`. Not on Linux yet: Computer Use, dictation."
  else
    desk="Not installed. Re-run this script and answer Y to add Claude Desktop with Cowork, or see code.claude.com/docs/en/desktop-linux."
  fi
  # Fill in the placeholders.
  # Web UI line: a direct link if it's open to the LAN, else the SSH tunnel.
  local webline
  if [[ "$CT_WEBUI_BIND" == 0.0.0.0 ]]; then
    webline="**Web UI (CloudCLI UI):** http://__IP__:3001 (open to the LAN) — _create a login on first visit_"
  else
    webline="**Web UI (CloudCLI UI):** this machine only. From your computer: \`ssh -L 3001:localhost:3001 __USER__@__IP__\`, then open http://localhost:3001 — _create a login on first visit_"
  fi
  notes=${notes//__WEBUI_LINE__/$webline}
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
    # Copied by the user, not root, so a symlink in their home can't redirect it.
    (cd / && runuser -u "$CT_PRIMARY_USER" -- install -m 644 /etc/agentic/README.md "$h/CLAUDE-BOX.md") 2>/dev/null || true
    success "Wrote the notes card to /etc/agentic/README.md (copy: ~$CT_PRIMARY_USER/CLAUDE-BOX.md)."
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
  echo -e "${GREEN}${BOLD}║          Claude Code on Lubuntu Ready!           ║${NC}"
  echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${BOLD}Machine:${NC}   $CT_HOSTNAME — $HOST_MODEL"
  echo -e "  ${BOLD}OS:${NC}        $HOST_OS ($HOST_ARCH)"
  echo -e "  ${BOLD}IP:${NC}        ${ip:-pending (DHCP)}"
  echo -e "  ${BOLD}Resources:${NC} ${HOST_CPUS} CPU / ${HOST_RAM_MB} MB RAM / $(df -h --output=avail / | tail -1 | tr -d ' ') free"
  echo -e "  ${BOLD}Timezone:${NC}  $CT_TZ"
  echo -e "  ${BOLD}User:${NC}      $CT_USER (Claude runs only as this user; sudo: $CT_USER_SUDO)"
  echo -e "  ${BOLD}Security:${NC}  SSH for $CT_USER (password$([[ -n "$CT_SSH_KEY" ]] && echo ' or key')) and root ($([[ $CT_ROOT_SSH == key ]] && echo 'key only' || echo 'password or key'))$([[ $CT_FIX_NOPASSWD == yes ]] && echo '; sudo now asks for a password')"
  echo ""
  echo -e "  ${BOLD}Connect:${NC}"
  [[ -n "${ip:-}" ]] && echo -e "    SSH:     ${CYAN}ssh ${CT_USER}@${ip}${NC}  (or ${CYAN}ssh ${CT_USER}@${CT_HOSTNAME}.local${NC})"
  if [[ -n "${ip:-}" ]] && [[ "$CT_WEBUI_BIND" == 0.0.0.0 ]]; then
    echo -e "    Web UI:  ${CYAN}http://${ip}:3001${NC} (as $CT_USER — ${YELLOW}create its login NOW${NC}; the first visitor claims it)"
  elif [[ -n "${ip:-}" ]]; then
    echo -e "    Web UI:  ${CYAN}ssh -L 3001:localhost:3001 ${CT_USER}@${ip}${NC}, then ${CYAN}http://localhost:3001${NC} (local only — ${YELLOW}create its login NOW${NC})"
  fi
  echo ""
  echo -e "  ${BOLD}Start Claude Code:${NC} (as a normal user, not root)"
  echo -e "    ${CYAN}claude${NC}  (shell auto-cd's to /project on login; as root: ${CYAN}su - $CT_USER${NC})"
  if [[ "$CT_DESKTOP" == yes ]]; then
    echo -e "  ${BOLD}Claude Desktop:${NC} log in to the desktop as ${CYAN}$CT_USER${NC}, open ${CYAN}Claude${NC} from the menu and sign in"
    echo -e "  ${BOLD}Cowork:${NC}    $VIRT_NOTE"
    [[ "$VIRT_OK" == yes ]] \
      || echo -e "    ${YELLOW}Enable virtualization (BIOS/UEFI, or nested in your hypervisor) and reboot — Cowork then works as-is.${NC}"
    echo -e "    ${YELLOW}Log out and back in (or reboot) first${NC} — the kvm group only applies to new logins."
    # SDDM (Lubuntu's login manager) auto-login as a different account would
    # start the desktop — and Claude Desktop — as the wrong user.
    local auto
    # (|| true: no auto-login configured is the normal case, and an empty grep
    # must not trip set -e/pipefail this late in the run.)
    auto=$(grep -hs -A5 '^\[Autologin\]' /etc/sddm.conf /etc/sddm.conf.d/*.conf 2>/dev/null | sed -n 's/^User=//p' | tail -1) || true
    [[ -n "$auto" && "$auto" != "$CT_USER" ]] \
      && echo -e "    ${YELLOW}The desktop auto-logs in as '$auto'${NC} — change User= under [Autologin] in /etc/sddm.conf(.d)"
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
  echo "    • CloudCLI UI (port 3001)"
  [[ "$CT_DESKTOP" == yes ]] && echo "    • Claude Desktop (Linux beta: Chat + Code + Cowork, with QEMU/KVM)"
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
  echo -e "  ${BOLD}Notes card:${NC}  /etc/agentic/README.md (copy in ~$CT_USER/CLAUDE-BOX.md)"
  echo ""
  echo -e "  ${BOLD}Install logs:${NC}"
  echo -e "    Deploy:    $DEPLOY_LOG"
  echo -e "    Provision: /var/log/agentic-provision.log"
  echo ""
}

# ── Reboot ────────────────────────────────────────────────────────────────
# A new kernel from the upgrade, and the kvm group Cowork needs (group changes
# only reach new logins), both want a reboot — a reboot covers everything.
offer_reboot() {
  local need ans
  # "yes" when provisioning changed a boot-time setting; Debian/Ubuntu also
  # flag kernel updates with /var/run/reboot-required.
  need=$(cat /etc/agentic/reboot-needed 2>/dev/null || echo no)
  [[ -e /var/run/reboot-required ]] && need=yes
  if [[ "$need" == yes ]]; then
    warn "A reboot is needed to finish (new kernel and/or the kvm group for Cowork)."
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

# ── Uninstall ───────────────────────────────────────────────────────────────
# `sudo bash Claude_Code_Lubuntu_Deployer.sh --uninstall` takes back what this
# script set up. It asks first, shows the plan, and only starts after you type
# "uninstall". Always removed: the web UI, the agentic-* tools, the weekly
# update, the settings and drop-ins under /etc and /usr/local the script wrote,
# and its shell block; sshd_config's two edited lines go back to how they were
# before the first deploy. Asked about: the dev toolchains, the apt software it
# added, and the Claude user's own Claude data. Never touched: the user account
# and its password, root's password, /project, the hostname, timezone and
# locale, the sudoers edits (their backups are in /root/*.agentic-bak), and the
# base packages (git, curl, build tools, Python, the SSH server...) that other
# software may rely on.
uninstall_yes() {   # uninstall_yes "<question>" <default y|n>
  local ans
  if [[ "$2" == y ]]; then read -rp "$1 [Y/n]: " ans; [[ ! "$ans" =~ ^[Nn] ]]
  else read -rp "$1 [y/N]: " ans; [[ "$ans" =~ ^[Yy] ]]; fi
}

uninstall() {
  [[ $(id -u) -eq 0 ]] || error "Run the uninstall as root: sudo bash $0 --uninstall"
  # shellcheck disable=SC2034  # AGENTIC_PRIMARY is set by users.conf; local keeps it here
  local AGENTIC_USERS="" AGENTIC_PRIMARY="" u h ans
  # shellcheck disable=SC1091
  [[ -r /etc/agentic/users.conf ]] && source /etc/agentic/users.conf
  if [[ -z "$AGENTIC_USERS" ]]; then
    warn "/etc/agentic/users.conf is missing, so the Claude user isn't known."
    read -rp "Claude user to clean up (Enter for none): " AGENTIC_USERS
    AGENTIC_USERS="${AGENTIC_USERS// /}"
    [[ -z "$AGENTIC_USERS" ]] || id "$AGENTIC_USERS" >/dev/null 2>&1 || error "No such user: $AGENTIC_USERS"
  fi
  echo ""
  echo -e "${BOLD}Uninstall${NC}: removes what this script set up${AGENTIC_USERS:+ for $AGENTIC_USERS}."
  echo "Always removed: the web UI (CloudCLI), agentic-update/-doctor/-setup-user/-errorlog,"
  echo "the weekly update, /etc/agentic, /usr/local/share/agentic, the root 'claude' stub, the"
  echo "SSH and apt drop-ins, the shell block in .bashrc and the npm install-script setting."
  echo ""
  local RM_TOOLS=no RM_APT=no RM_DATA=no
  uninstall_yes "Remove the dev toolchains it installed (Go, Rust, gopls, rust-analyzer, the global npm tools, Playwright and its browsers)?" y && RM_TOOLS=yes
  uninstall_yes "Remove the apt software it added (Node.js and the NodeSource repo, gh and its repo, Claude Desktop and its repo, clangd, and Cowork's QEMU/KVM stack)? Other software you installed may use them." n && RM_APT=yes
  if [[ -n "$AGENTIC_USERS" ]]; then
    uninstall_yes "Delete $AGENTIC_USERS's Claude Code data (~/.claude, ~/.claude.json, the claude install, ~/.cloudcli, the notes card, Agentic-Errors.txt)? This signs Claude out and deletes its settings, plugins and history." n && RM_DATA=yes
  fi
  echo ""
  echo "Kept: the user account, /project, root's password, hostname/timezone/locale, the"
  echo "SSH server, base packages, group memberships (sudo/kvm) and the sudoers edits."
  read -rp "Type 'uninstall' to go ahead (anything else cancels): " ans
  [[ "$ans" == uninstall ]] || { info "Cancelled; nothing was changed."; exit 0; }

  mkdir -p /var/log/agentic-deploy
  local log
  log="/var/log/agentic-deploy/uninstall-$(date +%Y%m%d-%H%M%S).log"
  ( umask 077; : > "$log" )
  exec > >(tee -a "$log") 2>&1
  info "Logging the uninstall to $log"

  # Runs a command as the Claude user, from /, so nothing in their home is
  # touched by root (the same reason the installer writes there as them).
  as_claude_user() { (cd / && runuser -u "$u" -- "$@"); }

  echo ">>> Web UI and weekly update..."
  systemctl disable --now cloudcli >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/cloudcli.service
  systemctl daemon-reload || true
  command -v npm >/dev/null 2>&1 && { npm uninstall -g --no-fund --no-audit --loglevel=error @cloudcli-ai/cloudcli || true; }
  rm -f /etc/cron.d/agentic-update /etc/logrotate.d/agentic-update

  echo ">>> Tools, settings and drop-ins..."
  rm -f /usr/local/bin/agentic-setup-user /usr/local/bin/agentic-update \
        /usr/local/bin/agentic-doctor /usr/local/bin/agentic-errorlog
  # The root 'claude' stub, only if it's ours (it points root at the user).
  if grep -qs 'not run as root on this box' /usr/local/bin/claude; then rm -f /usr/local/bin/claude; fi
  # Read what the deploy saved before /etc/agentic goes: the main sshd_config's
  # original PermitRootLogin / PasswordAuthentication lines (used further down).
  # Boxes deployed before that file existed get the OS's commented defaults.
  local ssh_orig_root="#PermitRootLogin prohibit-password" ssh_orig_pw="#PasswordAuthentication yes"
  if [[ -f /etc/agentic/sshd-original ]]; then
    ssh_orig_root="$(grep -m1 'PermitRootLogin' /etc/agentic/sshd-original || true)"
    ssh_orig_pw="$(grep -m1 'PasswordAuthentication' /etc/agentic/sshd-original || true)"
  fi
  rm -rf /usr/local/share/agentic /etc/agentic
  rm -f /etc/profile.d/agentic.sh /etc/apt/apt.conf.d/99agentic-lock-wait
  [[ -f /etc/environment ]] && sed -i -E '/^RUSTUP_HOME=\/opt\/rust\/rustup$/d; /^PLAYWRIGHT_BROWSERS_PATH=\/opt\/ms-playwright$/d' /etc/environment
  git config --system --unset-all safe.directory '^/project(/\*)?$' 2>/dev/null || true
  # npm's install-script allowlist (root's; the user's is below).
  command -v npm >/dev/null 2>&1 && { npm config delete allow-scripts 2>/dev/null || true; }
  # SSH: drop our drop-in and put the main file's two lines back the way they
  # were before the first deploy (read above). An empty saved line means the
  # file never had one, so the deploy didn't touch it and neither do we.
  # Values go in through the environment, not awk -v, so a backslash in them
  # stays a backslash. Never restart into a config sshd rejects.
  rm -f /etc/ssh/sshd_config.d/00-agentic.conf
  if [[ -f /etc/ssh/sshd_config ]]; then
    ROOT_LINE="$ssh_orig_root" PW_LINE="$ssh_orig_pw" awk '
      /^PermitRootLogin /        && ENVIRON["ROOT_LINE"] != "" { print ENVIRON["ROOT_LINE"]; next }
      /^PasswordAuthentication / && ENVIRON["PW_LINE"]   != "" { print ENVIRON["PW_LINE"];   next }
      { print }' /etc/ssh/sshd_config > /etc/ssh/sshd_config.agentic-new \
      && cat /etc/ssh/sshd_config.agentic-new > /etc/ssh/sshd_config
    rm -f /etc/ssh/sshd_config.agentic-new
  fi
  if [[ ! -f /etc/ssh/sshd_config ]]; then
    :
  elif sshd -t 2>/dev/null || /usr/sbin/sshd -t 2>/dev/null; then
    systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
  else
    warn "sshd's config test failed after the change; check /etc/ssh/sshd_config before the next restart"
  fi
  # The shell block, from root's .bashrc and (as them) the user's. The block
  # runs from its marker line to its closing "cd /project" line. The first awk
  # checks that both are there, in that order; if someone deleted the closing
  # line, removing "to the end of the block" would also delete everything
  # after it, so the file is left alone with a warning instead.
  local uninstall_bashrc_check='index($0, m) { s=1 } s && $0 == "cd /project 2>/dev/null || true" { f=1 } END { exit !f }'
  local uninstall_bashrc_awk='index($0, m) { skip=1; next } skip && $0 == "cd /project 2>/dev/null || true" { skip=0; next } !skip'
  if grep -qs "── Claude Code Lubuntu ──" /root/.bashrc; then
    if awk -v m="── Claude Code Lubuntu ──" "$uninstall_bashrc_check" /root/.bashrc; then
      # cat > (not mv) keeps the file's owner and mode.
      awk -v m="── Claude Code Lubuntu ──" "$uninstall_bashrc_awk" /root/.bashrc > /root/.bashrc.agentic-new \
        && cat /root/.bashrc.agentic-new > /root/.bashrc
      rm -f /root/.bashrc.agentic-new
    else
      warn "Left /root/.bashrc alone: its Claude Code block has no closing 'cd /project' line. Remove the block by hand."
    fi
  fi
  for u in $AGENTIC_USERS; do
    id "$u" >/dev/null 2>&1 || continue
    h="$(getent passwd "$u" | cut -d: -f6)"
    as_claude_user bash -c 'f="$1/.bashrc"; [ -f "$f" ] && [ ! -L "$f" ] && grep -q "$2" "$f" || exit 0
      awk -v m="$2" "$4" "$f" || exit 1
      awk -v m="$2" "$3" "$f" > "$f.agentic-new" && cat "$f.agentic-new" > "$f"; rm -f "$f.agentic-new"' \
      sh "$h" "── Claude Code Lubuntu ──" "$uninstall_bashrc_awk" "$uninstall_bashrc_check" \
      || warn "Left $h/.bashrc alone: its Claude Code block has no closing 'cd /project' line (or the file couldn't be written). Remove the block by hand."
    as_claude_user npm config delete allow-scripts >/dev/null 2>&1 || true
  done

  if [[ "$RM_TOOLS" == yes ]]; then
    echo ">>> Dev toolchains..."
    if command -v npm >/dev/null 2>&1; then
      npm uninstall -g --no-fund --no-audit --loglevel=error \
        typescript ts-node eslint prettier typescript-language-server pyright playwright || true
    fi
    pip uninstall -y -q --break-system-packages --root-user-action=ignore playwright 2>/dev/null || true
    rm -rf /opt/ms-playwright /usr/local/go /opt/rust
    rm -f /etc/profile.d/go.sh /usr/local/bin/gopls
    # rust-analyzer: only our symlink into the shared toolchain.
    if [[ -L /usr/local/bin/rust-analyzer ]]; then rm -f /usr/local/bin/rust-analyzer; fi
  fi

  if [[ "$RM_APT" == yes ]]; then
    echo ">>> apt software and repositories..."
    local pkgs=() p
    # The global npm tools can't run without Node, so they go first.
    if command -v npm >/dev/null 2>&1; then
      npm uninstall -g --no-fund --no-audit --loglevel=error \
        typescript ts-node eslint prettier typescript-language-server pyright playwright || true
    fi
    for p in claude-desktop gh nodejs clangd qemu-system-x86 qemu-system-arm ovmf qemu-efi-aarch64 virtiofsd cpu-checker; do
      dpkg -s "$p" >/dev/null 2>&1 && pkgs+=("$p")
    done
    if [[ ${#pkgs[@]} -gt 0 ]]; then
      apt-get purge -y -qq "${pkgs[@]}" || warn "some packages didn't uninstall: ${pkgs[*]}"
    fi
    rm -f /etc/apt/sources.list.d/claude-desktop.list /etc/apt/sources.list.d/github-cli.list \
          /etc/apt/sources.list.d/nodesource.* /etc/apt/keyrings/githubcli-archive-keyring.gpg \
          /etc/apt/keyrings/nodesource.gpg /usr/share/keyrings/claude-desktop-archive-keyring.asc \
          /etc/apt/preferences.d/nodejs /etc/apt/preferences.d/nsolid /etc/modules-load.d/claude-cowork.conf
    apt-get update -qq || true
    apt-get autoremove -y -qq || true
  fi

  if [[ "$RM_DATA" == yes ]]; then
    echo ">>> The Claude user's Claude data..."
    for u in $AGENTIC_USERS; do
      id "$u" >/dev/null 2>&1 || continue
      h="$(getent passwd "$u" | cut -d: -f6)"
      as_claude_user bash -c 'cd "$1" || exit 0
        rm -rf .claude .claude.json .claude.json.backup .cloudcli .local/share/claude .local/bin/claude \
               "$2" Agentic-Errors.txt Desktop/Agentic-Errors.txt' sh "$h" "CLAUDE-BOX.md" || true
    done
  fi

  echo ""
  success "Uninstall finished. Log: $log"
  echo "  Left in place: the user account, /project, the SSH server, base packages and group memberships."
  ls /root/*.agentic-bak >/dev/null 2>&1 \
    && echo "  sudoers backups from the NOPASSWD fix: $(ls /root/*.agentic-bak | tr '\n' ' ')(copy one back with visudo -cf first if you want the old rule)"
  [[ "$RM_TOOLS" == yes ]] || echo "  Toolchains kept: /usr/local/go, /opt/rust, /opt/ms-playwright and the global npm tools."
  echo "  Open shells still have the old PATH and settings; log out and back in."
}

# ── Command line ────────────────────────────────────────────────────────────
# One optional argument. Anything else stops with the usage text, so a typo
# such as --uninstal can never start a full install by mistake.
usage() {
  cat <<USAGE
Usage: sudo bash Claude_Code_Lubuntu_Deployer.sh [--uninstall | --help]

  (no option)    Asks a few questions, then sets up this machine. Safe to run again:
                 installed parts are skipped and your settings are kept.
  --uninstall    Removes what this script set up. Asks before removing toolchains,
                 apt software or the Claude user's data; keeps the user account.
  --help, -h     Show this text.
USAGE
}

# ── Main ────────────────────────────────────────────────────────────────────
# Order matters: logging starts only after the prompts, so passwords typed at
# get_config never reach the log; everything after that is captured.
main() {
  [[ $# -le 1 ]] || { usage >&2; error "Give at most one option."; }
  case "${1:-}" in
    "") ;;                                   # normal install, below
    --uninstall) header; uninstall; exit 0 ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; error "Unknown option: $1" ;;
  esac
  header
  preflight
  get_config
  start_logging
  apply_hostname
  wait_network
  provision_host
  write_notes
  print_summary
  offer_reboot
}

main "$@"
