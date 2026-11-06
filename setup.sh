#!/usr/bin/env bash
#
# Provisioning for a ClockworkPi uConsole (CM4) on Rex's Debian Bookworm image
# with the HackerGadgets AIO v2 board. See README.md in this directory for
# what it installs, key bindings, and post-install steps.
#
#   curl -fsSL pid1.space/rx | sudo bash
#
# pid1.space/rx redirects to rx.pid1.space, which Cloudflare deploys straight
# from this repository on every push. If it is unreachable, the raw URL still
# works:
#
#   curl -fsSL https://raw.githubusercontent.com/pid1/rx/main/setup.sh | sudo bash
#
# Flags must go through `bash -s --`; `| sudo bash --dry-run` hands the flag to
# bash instead of to this script:
#
#   ... | sudo bash -s -- --dry-run
#   ... | sudo bash -s -- --only sdr --skip lora
#   ... | sudo TS_AUTHKEY=tskey-auth-... bash -s -- --only tailscale
#
# Two constraints shape this file:
#
#   The body is wrapped in main() so a truncated download -- the pipe dropping
#   mid-transfer -- dies on an incomplete function definition instead of
#   executing half a script that rewrites config.txt.
#
#   stdin is the script itself, so nothing here may read from it. apt is fully
#   non-interactive; the escape hatch for a real prompt is `< /dev/tty`.
#
# Every step is idempotent: re-running is the intended way to use this as
# config management. A run that changes nothing writes nothing.

main() {
  set -euo pipefail

  # ------------------------------------------------------------------ config

  local GH_KEY_USER=pid1
  local DEFAULT_USER=jroemer
  local TIMEZONE=America/Chicago   # US/Central; America/Chicago is the canonical name
  # Meshtastic will not transmit until a region is set. Wrong region is a
  # regulatory problem, so this is explicit rather than guessed.
  local LORA_REGION=US
  # Node identity as it appears to everyone else on the mesh. Short name is
  # capped at 4 characters.
  local NODE_NAME=KA1PID
  local NODE_SHORT=PID1
  # Offline map style for meshtastic-ui; bundles live in meshtastic/device-ui.
  # Alternatives: positron, atlas, dark-matter-brown.
  local MAP_STYLE=osm
  local AIOV2_REPO=https://github.com/hackergadgets/aiov2_ctl.git
  local AIOV2_DIR=/opt/aiov2_ctl
  local MESHTASTIC_REPO=http://download.opensuse.org/repositories/network:/Meshtastic:/beta/Raspbian_12/
  # Rex (ak-rex) maintains the ClockworkPi apt repo that his Bookworm image
  # ships with. It is served straight out of a GitHub repo, and carries the
  # things Debian does not have: the hackergadgets AIO metapackage, pinctrl,
  # and the rtlsdrblog fork of rtl-sdr.
  # Anthropic's release signing key, per code.claude.com/docs/en/setup.
  local CLAUDE_KEY_URL=https://downloads.claude.ai/keys/claude-code.asc
  local CLAUDE_KEY=/etc/apt/keyrings/claude-code.asc
  local CLAUDE_KEY_FP=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
  local CLAUDE_LIST=/etc/apt/sources.list.d/claude-code.list

  # AIO v2 puts each subsystem behind a GPIO-switched power rail. Nothing on
  # the board responds until these are driven high. (V1 had no such gating.)
  local RAIL_GPS=27 RAIL_LORA=16 RAIL_SDR=7 RAIL_USB=23

  # Rails brought up at boot. SDR needs USB as well: the RTL-SDR is an
  # internal USB device behind the AIO hub, so powering the SDR rail alone
  # will not make it enumerate. GPS is up because chrony disciplines the clock
  # from it, and LoRa because meshtasticd runs at boot.
  local BOOT_RAILS=(SDR USB GPS LORA)

  local BEGIN_MARK='# >>> uconsole-setup >>>'
  local END_MARK='# <<< uconsole-setup <<<'

  local ALL_SECTIONS=(base firewall desktop claude aio rtc gps lora sdr ham tailscale)

  # Hardware groups. The account created by the image's first-boot wizard is
  # not in these, and no AIO peripheral works non-root without them.
  local HW_GROUPS=(dialout spi i2c gpio plugdev audio video netdev)

  # Kernel and boot firmware are held. The display, panel rotation and the AIO
  # overlays all depend on kernel patches matched to this image, and the apt
  # suite configured here carries newer kernels than the image ships -- so an
  # unattended `maint` run could otherwise replace the kernel and leave a
  # portable device with no display, away from a desk. Upgrade these
  # deliberately: unhold, upgrade, reboot, verify, re-hold.
  local HOLD_PACKAGES=(akrex-kernel clockworkpi-kernel clockworkpi-cm-firmware
                       raspberrypi-kernel raspberrypi-bootloader)

  # --------------------------------------------------------------- arg parse

  local DRY_RUN=false
  local DESKTOP_USER=""
  local -a ONLY=() SKIP=()

  while (( $# )); do
    case $1 in
      --dry-run)      DRY_RUN=true ;;
      --user)         DESKTOP_USER=${2:?--user needs a value}; shift ;;
      --user=*)       DESKTOP_USER=${1#*=} ;;
      --only)         ONLY+=("${2:?--only needs a section}"); shift ;;
      --only=*)       ONLY+=("${1#*=}") ;;
      --skip)         SKIP+=("${2:?--skip needs a section}"); shift ;;
      --skip=*)       SKIP+=("${1#*=}") ;;
      -h|--help)
        printf 'usage: setup.sh [--dry-run] [--user NAME] [--only SECTION]... [--skip SECTION]...\n'
        printf 'sections: %s\n' "${ALL_SECTIONS[*]}"
        return 0 ;;
      *) printf 'unknown argument: %s\n' "$1" >&2; return 2 ;;
    esac
    shift
  done

  # ---------------------------------------------------------------- plumbing

  local -a NOTES=()

  log()     { printf '  %s\n' "$*"; }
  warn()    { printf '  !! %s\n' "$*" >&2; }
  die()     { printf '\nFATAL: %s\n' "$*" >&2; exit 1; }
  section() { printf '\n== %s\n' "$*"; }
  note()    { NOTES+=("$*"); }

  run() {
    if $DRY_RUN; then printf '  [dry-run] %s\n' "$*"; return 0; fi
    "$@"
  }

  # write_file <path> [mode]; content on stdin. Writes via a same-directory
  # temp file so a failure part-way never leaves a truncated target.
  write_file() {
    local path=$1 mode=${2:-0644} content tmp
    content=$(cat)
    if $DRY_RUN; then
      printf '  [dry-run] write %s (mode %s):\n' "$path" "$mode"
      printf '%s\n' "$content" | sed 's/^/    | /'
      return 0
    fi
    mkdir -p "$(dirname "$path")"
    tmp=$(mktemp "${path}.XXXXXX")
    printf '%s\n' "$content" > "$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$path"
  }

  pkg_installed() {
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'ok installed'
  }

  pkg_available() {
    local cand
    cand=$(apt-cache policy "$1" 2>/dev/null | awk -F': ' '/Candidate:/{print $2}')
    [[ -n $cand && $cand != '(none)' ]]
  }

  apt_install() { run apt-get install -y "$@"; }

  # For optional extras: warn rather than abort. A missing optional package
  # should not take down a whole provisioning run, and under set -e a plain
  # apt_install would.
  apt_install_opt() {
    run apt-get install -y "$@" || warn "optional install failed: $*"
    return 0
  }

  # apt refuses to update a repo whose Release metadata changed, until the
  # change is confirmed. Two benign ones show up here: Debian bumping Version
  # across point releases (12.13 -> 12.15), and Rex relabelling his repo. Both
  # are accepted narrowly by field.
  #
  # Origin, Codename and Suite are deliberately NOT accepted: those indicate
  # the repository is claiming to be something other than what it was, which is
  # the case apt-secure(8) actually exists to stop. Confirm those by hand.
  #
  # Non-fatal: one third-party repo failing should not abort provisioning, and
  # the error stays visible above the warning.
  # Reports apt's real exit status, so callers that need to roll back can.
  apt_update() {
    run apt-get update -y \
      --allow-releaseinfo-change-version \
      --allow-releaseinfo-change-label
  }

  # Never fatal: one third-party repo failing should not abort provisioning,
  # and apt's own error stays visible above the warning.
  apt_update_soft() {
    apt_update || warn "apt-get update reported errors (see above); continuing anyway"
    return 0
  }

  # Replace our marker-delimited block in a file, or append it if absent.
  apply_block() {
    local file=$1 content stripped
    content=$(cat)
    stripped=$(sed "\|^${BEGIN_MARK}\$|,\|^${END_MARK}\$|d" "$file")
    printf '%s\n\n%s\n%s\n%s\n' \
      "$stripped" "$BEGIN_MARK" "$content" "$END_MARK" | write_file "$file" 0644
  }

  # Rex's image ships his apt repo already configured (it appears as
  # ClockworkPi-apt), and that is where the HackerGadgets AIO metapackage,
  # pinctrl and the rtlsdrblog rtl-sdr build come from. This
  # script targets that image, so it verifies the repo is there rather than
  # carrying the key-fetch and sources.list plumbing to install a second copy
  # of the same packages under a different name.
  local AKREX_CHECKED=false
  require_akrex_repo() {
    $AKREX_CHECKED && return 0
    AKREX_CHECKED=true
    pkg_available hackergadgets-uconsole-aio-board || {
      warn "Rex's ClockworkPi apt repo does not look configured: hackergadgets-uconsole-aio-board does not resolve."
      warn "This script targets Rex's image, which ships it. On another image, add it from"
      warn "  https://github.com/ak-rex/akrex-arm-repo   then re-run."
    }
    return 0
  }

  want() {
    local s=$1 x
    if (( ${#ONLY[@]} )); then
      for x in "${ONLY[@]}"; do [[ $x == "$s" ]] && return 0; done
      return 1
    fi
    for x in "${SKIP[@]}"; do [[ $x == "$s" ]] && return 1; done
    return 0
  }

  # --------------------------------------------------------------- preflight

  section "Preflight"

  (( EUID == 0 )) || die "must run as root (pipe to 'sudo bash', not 'bash')"

  local s known
  for s in "${ONLY[@]}" "${SKIP[@]}"; do
    known=false
    for x in "${ALL_SECTIONS[@]}"; do [[ $x == "$s" ]] && known=true; done
    $known || die "unknown section '$s' (valid: ${ALL_SECTIONS[*]})"
  done

  $DRY_RUN && log "DRY RUN — no changes will be made"

  # Bookworm moved the firmware partition; older images still use /boot.
  local BOOT_DIR
  if [[ -f /boot/firmware/config.txt ]]; then
    BOOT_DIR=/boot/firmware
  elif [[ -f /boot/config.txt ]]; then
    BOOT_DIR=/boot
  else
    die "cannot find config.txt in /boot/firmware or /boot — is this a Pi image?"
  fi
  log "boot dir: $BOOT_DIR"

  local OS_ID=debian OS_CODENAME=bookworm
  if [[ -r /etc/os-release ]]; then
    OS_ID=$(awk -F= '/^ID=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
    OS_CODENAME=$(awk -F= '/^VERSION_CODENAME=/{gsub(/"/,"",$2); print $2}' /etc/os-release)
  fi
  log "os: ${OS_ID} ${OS_CODENAME}"
  [[ $OS_CODENAME == bookworm ]] || warn "expected bookworm, found '${OS_CODENAME}' — continuing anyway"

  local MODEL="unknown"
  [[ -r /proc/device-tree/model ]] && MODEL=$(tr -d '\0' < /proc/device-tree/model)
  log "model: $MODEL"
  case $MODEL in
    *"Compute Module 4"*) ;;
    *) warn "this script targets CM4; overlays and device paths may be wrong on '$MODEL'" ;;
  esac

  # Resolve the desktop account. Never create it — the password policy and
  # sudo membership are decisions this script should not be making silently.
  [[ -n $DESKTOP_USER ]] || DESKTOP_USER=$DEFAULT_USER
  # Rex's Lite image runs a first-boot wizard that creates the user account, so
  # by the time this runs it should already exist.
  if ! id -u "$DESKTOP_USER" >/dev/null 2>&1; then
    if [[ -n ${SUDO_USER:-} ]] && id -u "$SUDO_USER" >/dev/null 2>&1; then
      warn "user '$DESKTOP_USER' does not exist; falling back to '\$SUDO_USER' ($SUDO_USER)"
      DESKTOP_USER=$SUDO_USER
    else
      die "user '$DESKTOP_USER' does not exist. Create it first:
    adduser $DESKTOP_USER && adduser $DESKTOP_USER sudo
  then re-run, or pass --user NAME for a different account."
    fi
  fi

  local USER_HOME USER_GROUP
  USER_HOME=$(getent passwd "$DESKTOP_USER" | cut -d: -f6)
  USER_GROUP=$(id -gn "$DESKTOP_USER")
  [[ -d $USER_HOME ]] || die "home directory '$USER_HOME' for '$DESKTOP_USER' does not exist"
  log "desktop user: $DESKTOP_USER ($USER_HOME)"

  # Back up the boot files once per run, before anything touches them.
  local STAMP; STAMP=$(date +%Y%m%d-%H%M%S)
  # Back up once, not per run: this script is meant to be re-runnable as
  # config management, and /boot/firmware is a small FAT partition that would
  # slowly fill with timestamped copies. The first backup is the pristine
  # pre-script state, which is the one worth keeping.
  local f
  for f in "$BOOT_DIR/config.txt" "$BOOT_DIR/cmdline.txt"; do
    [[ -f $f ]] || continue
    if compgen -G "${f}.bak-*" >/dev/null; then
      log "$(basename "$f"): pre-existing backup kept ($(basename "$(ls -1 "${f}".bak-* | head -1)"))"
    else
      run cp -a "$f" "${f}.bak-${STAMP}"
      log "$(basename "$f") backed up as .bak-${STAMP}"
    fi
  done

  export DEBIAN_FRONTEND=noninteractive
  apt_update_soft

  # -------------------------------------------------------------------- base

  if want base; then
    section "Base system"

    # US/Central. Also matters beyond the clock display: JS8Call and the RTC
    # both care, and gpsd/chrony will be feeding real time in shortly.
    if command -v timedatectl >/dev/null 2>&1; then
      local current_tz
      current_tz=$(timedatectl show -p Timezone --value 2>/dev/null || echo "")
      if [[ $current_tz == "$TIMEZONE" ]]; then
        log "timezone already $TIMEZONE"
      else
        run timedatectl set-timezone "$TIMEZONE"
        log "timezone set to $TIMEZONE (was ${current_tz:-unknown})"
      fi
    else
      warn "timedatectl not found — timezone unchanged"
    fi

    run touch /root/.hushlogin
    run install -o "$DESKTOP_USER" -g "$USER_GROUP" -m 0644 /dev/null "$USER_HOME/.hushlogin"
    log "hushlogin set for root and $DESKTOP_USER"

    # -A generates one host key per supported type, skipping any that exist.
    run ssh-keygen -A
    log "ssh host keys present"

    # pi-gen's stage2 contains both `systemctl enable ssh` and
    # `systemctl disable ssh` behind a build-time condition, so whether the
    # image arrives with a listener is not something to assume either way.
    apt_install openssh-server

    # A masked unit cannot be enabled, and `systemctl enable` on one fails --
    # which under set -e would take the whole base section down. Some images
    # ship ssh masked rather than merely disabled.
    run systemctl unmask ssh.service 2>/dev/null || true
    run systemctl unmask ssh.socket  2>/dev/null || true

    # Bookworm uses ssh.service; socket activation (ssh.socket) exists but is
    # not the default. If the socket is enabled, the service is held inactive
    # and starting it directly conflicts -- so defer to whichever is in play.
    if systemctl is-enabled ssh.socket >/dev/null 2>&1; then
      run systemctl restart ssh.socket || warn "ssh.socket would not start"
      log "sshd via socket activation (ssh.socket)"
    else
      run systemctl enable ssh || warn "could not enable ssh"
      run systemctl restart ssh || warn "could not start ssh"
      log "sshd enabled (ssh.service)"
    fi

    # Say plainly whether anything is actually listening, rather than leaving
    # a 'connection refused' to be discovered from another machine.
    if ! $DRY_RUN; then
      if ss -tln 2>/dev/null | grep -qE ':22[[:space:]]'; then
        log "sshd listening on 22"
      else
        warn "nothing is listening on port 22 — check: systemctl status ssh; journalctl -u ssh -n 30"
        note "SSH is not listening. 'systemctl status ssh' and 'journalctl -u ssh -n 30' will say why; a missing host key or a masked unit are the usual causes."
      fi
    fi

    apt_install curl ca-certificates gnupg git

    # GitHub-backed authorized_keys sync. Fetches to a temp file, requires the
    # result to be non-empty and to parse as SSH public keys, and only then
    # swaps it in atomically: a failed fetch must never be able to empty
    # authorized_keys on a device whose only other input is its own keyboard.
    write_file /usr/local/sbin/sync-github-keys 0755 <<'SYNCKEYS'
#!/bin/sh
# Managed by rx/setup.sh — refresh authorized_keys from GitHub.
set -eu

GH_USER="__GH_USER__"
URL="https://github.com/${GH_USER}.keys"

sync_for() {
    _user=$1
    _home=$2
    [ -d "$_home" ] || return 0

    _tmp=$(mktemp "${_home}/.ssh-keys.XXXXXX" 2>/dev/null) || return 0

    if ! curl -fsSL --max-time 20 "$URL" -o "$_tmp"; then
        rm -f "$_tmp"
        return 0
    fi
    # Empty response, or an HTML error page, must never reach authorized_keys.
    if [ ! -s "$_tmp" ] || ! ssh-keygen -l -f "$_tmp" >/dev/null 2>&1; then
        rm -f "$_tmp"
        return 0
    fi

    # Only rewrite when the content actually differs — this runs every 5
    # minutes against an SD card, and an unchanged key set is the normal case.
    if [ -f "${_home}/.ssh/authorized_keys" ] \
       && cmp -s "$_tmp" "${_home}/.ssh/authorized_keys"; then
        rm -f "$_tmp"
        return 0
    fi

    mkdir -p "${_home}/.ssh"
    chmod 700 "${_home}/.ssh"
    chown "$_user" "${_home}/.ssh"
    chmod 600 "$_tmp"
    chown "$_user" "$_tmp"
    mv -f "$_tmp" "${_home}/.ssh/authorized_keys"
}

sync_for root /root
sync_for "__DESKTOP_USER__" "__USER_HOME__"
SYNCKEYS

    if ! $DRY_RUN; then
      sed -i \
        -e "s|__GH_USER__|${GH_KEY_USER}|" \
        -e "s|__DESKTOP_USER__|${DESKTOP_USER}|" \
        -e "s|__USER_HOME__|${USER_HOME}|" \
        /usr/local/sbin/sync-github-keys
    fi

    write_file /etc/cron.d/keys 0644 <<'CRON'
# Managed by rx/setup.sh
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
*/5 * * * *   root   /usr/local/sbin/sync-github-keys
CRON

    # Seed immediately so the first login does not wait on cron.
    run /usr/local/sbin/sync-github-keys || warn "initial key sync failed (network?); cron will retry"
    log "github key sync installed (${GH_KEY_USER}, every 5 min)"

    # Key-only SSH. Guarded on a usable key actually being present: turning
    # password auth off against an empty authorized_keys would leave the
    # physical console as the only way in.
    local ak="$USER_HOME/.ssh/authorized_keys"
    if [[ -s $ak ]] && ssh-keygen -l -f "$ak" >/dev/null 2>&1; then
      # KbdInteractiveAuthentication too: with it left on, PAM can still put
      # up a password prompt even when PasswordAuthentication is no.
      if grep -qs '^[[:space:]]*Include[[:space:]]\+/etc/ssh/sshd_config.d/\*.conf' /etc/ssh/sshd_config; then
        write_file /etc/ssh/sshd_config.d/10-no-password.conf 0644 <<'SSHDNOPW'
# Managed by rx/setup.sh
PasswordAuthentication no
KbdInteractiveAuthentication no
SSHDNOPW
      else
        printf '%s\n' \
          'PasswordAuthentication no' \
          'KbdInteractiveAuthentication no' \
          | apply_block /etc/ssh/sshd_config
      fi

      # Validate before reloading: a config sshd rejects would otherwise take
      # the listener down on restart.
      if $DRY_RUN; then
        log "[dry-run] would disable SSH password authentication"
      elif sshd -t 2>/dev/null; then
        systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        log "SSH password authentication disabled (keys only)"
      else
        warn "sshd rejected the config; password auth left enabled:"
        sshd -t 2>&1 | sed 's/^/      /' >&2
      fi
    else
      warn "not disabling SSH password auth: no usable key in $ak"
      note "SSH password auth is still enabled because $ak held no usable key. Once 'ssh-keygen -l -f $ak' succeeds, re-run --only base."
    fi

    # One command for routine upkeep: package updates plus a re-apply of this
    # script, which is idempotent and so only changes what has drifted or is
    # newly added. /usr/local/bin rather than sbin -- Debian keeps sbin off a
    # normal user's PATH, so `sudo maint` would not resolve.
    write_file /usr/local/bin/maint 0755 <<'MAINT'
#!/bin/bash
# Managed by rx/setup.sh — daily maintenance.
#
#   sudo maint              update packages, then re-apply configuration
#   sudo maint --dry-run    show what the config step would change
#
# Arguments pass through to setup.sh, so --only/--skip work here too.
set -euo pipefail

# pid1.space/rx first. It is no longer a mirror that can silently freeze:
# Cloudflare deploys it from the repository on push, and a push Cloudflare
# misses is caught by .github/workflows/cf-fallback.yml, which redeploys when
# the live /.build-id does not match the commit. The raw URL stays as the
# fallback for when Cloudflare is unreachable.
PRIMARY=https://pid1.space/rx
FALLBACK=https://raw.githubusercontent.com/pid1/rx/main/setup.sh

if [ "$(id -u)" -ne 0 ]; then
    echo "maint: needs root — run: sudo maint $*" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "== packages"
# Benign Release metadata changes (Debian point releases, Rex relabelling his
# repo) would otherwise abort the update. Origin/Codename/Suite still stop it.
apt-get update -y \
    --allow-releaseinfo-change-version \
    --allow-releaseinfo-change-label \
    || echo "maint: apt update reported errors, continuing" >&2
apt-get full-upgrade -y
apt-get autoremove --purge -y

echo
echo "== held packages"
# Held packages are skipped by the upgrade above by design, so say when one
# has an update waiting rather than letting it sit unnoticed for months.
held=$(apt-mark showhold 2>/dev/null || true)
if [ -z "$held" ]; then
    echo "  none"
else
    for p in $held; do
        inst=$(apt-cache policy "$p" 2>/dev/null | awk '/Installed:/{print $2}')
        cand=$(apt-cache policy "$p" 2>/dev/null | awk '/Candidate:/{print $2}')
        if [ "$inst" != "$cand" ]; then
            echo "  $p: held at $inst, $cand available"
            echo "     upgrade deliberately: sudo apt-mark unhold $p && sudo apt install $p"
            echo "     then reboot and confirm the display comes up before re-holding"
        else
            echo "  $p: $inst (current)"
        fi
    done
fi

echo
echo "== configuration"
tmp=$(mktemp)
src=""
trap 'rm -f "$tmp"' EXIT

if curl -fsSL --max-time 30 "$PRIMARY" -o "$tmp"; then
    src=$PRIMARY
elif curl -fsSL --max-time 30 "$FALLBACK" -o "$tmp"; then
    src=$FALLBACK
    echo "maint: pid1.space unreachable, fetched from GitHub instead" >&2
fi

if [ -s "$tmp" ]; then
    # Say what is being applied, so a wrong or stale copy is visible rather
    # than inferred from behaviour.
    echo "  source: $src"
    echo "  sha256: $(sha256sum "$tmp" | cut -c1-16)  ($(wc -l < "$tmp") lines)"
    # Downloaded to a file rather than piped, so a truncated transfer is caught
    # here instead of part-executing. Same checks the publish workflow applies:
    # the body lives inside main(), so a file missing its trailing invocation
    # parses fine and then silently does nothing.
    if bash -n "$tmp" \
       && head -1 "$tmp" | grep -qx '#!/usr/bin/env bash' \
       && tail -1 "$tmp" | grep -qx 'main "\$@"'; then
        bash "$tmp" "$@"
    else
        echo "maint: downloaded setup.sh failed verification; config step skipped" >&2
        exit 1
    fi
else
    echo "maint: could not fetch setup.sh from either URL; config step skipped" >&2
    exit 1
fi

if [ -f /var/run/reboot-required ]; then
    echo
    echo "== reboot required"
    sed 's/^/   /' /var/run/reboot-required.pkgs 2>/dev/null || true
fi
MAINT
    log "installed the 'maint' maintenance command"

    local hp
    for hp in "${HOLD_PACKAGES[@]}"; do
      pkg_installed "$hp" || continue
      if apt-mark showhold 2>/dev/null | grep -qx "$hp"; then
        log "already held: $hp"
      else
        run apt-mark hold "$hp" || warn "could not hold $hp"
      fi
    done

    # Hardware group membership — required for the AIO peripherals to be
    # usable without sudo. Only add groups that actually exist on this image.
    local g present=()
    for g in "${HW_GROUPS[@]}"; do
      getent group "$g" >/dev/null 2>&1 && present+=("$g")
    done
    if (( ${#present[@]} )); then
      local joined; joined=$(IFS=,; printf '%s' "${present[*]}")
      run usermod -aG "$joined" "$DESKTOP_USER"
      log "added $DESKTOP_USER to: ${present[*]}"
      note "Group changes need a full logout/login (or reboot) before they apply."
    note "Routine upkeep is one command: 'sudo maint' — apt update + full-upgrade + autoremove, then re-applies this script (idempotent, so only drift changes). 'sudo maint --dry-run' previews the config half."
    note "SSH is listening on 22, key-only (password auth disabled), keys synced from github.com/${GH_KEY_USER}.keys every 5 minutes."
    fi
  fi

  # ---------------------------------------------------------------- firewall

  # Default-deny inbound. Nothing on this device needs to accept unsolicited
  # traffic except SSH, and rxd's HTTP port from the LAN, and some of what it
  # runs would otherwise be wide open -- meshtasticd serves an unauthenticated
  # API (4403) and web client (443) on every interface, as packaged.
  #
  # Its own table and its own unit rather than /etc/nftables.conf: Debian's
  # file starts with `flush ruleset`, which would wipe the rules Tailscale
  # installs through iptables-nft. A separate table's drop still applies to
  # everything, since a packet must pass every base chain on its hook.
  if want firewall; then
    section "Firewall"
    apt_install nftables

    write_file /etc/rx/firewall.nft 0644 <<'NFT'
#!/usr/sbin/nft -f
# Managed by rx/setup.sh — inbound: SSH, rxd's HTTP from the LAN, and
# replies. Loaded by rx-firewall.service. Replaces only its own table, never
# the ruleset.

table inet rx_firewall
delete table inet rx_firewall

table inet rx_firewall {
    # The LAN: private IPv4, IPv6 unique-local and link-local. The tailnet is
    # matched by interface instead.
    set lan4 {
        type ipv4_addr; flags interval;
        elements = { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 }
    }
    set lan6 {
        type ipv6_addr; flags interval;
        elements = { fc00::/7, fe80::/10 }
    }

    chain input {
        type filter hook input priority filter; policy drop;

        iif "lo" accept
        ct state established,related accept
        ct state invalid drop

        # IPv6 does not work without these: neighbour discovery, router
        # adverts (link-local, hop limit 255) and DHCPv6 replies, which go
        # to a multicast solicit that conntrack cannot match.
        icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept
        ip6 saddr fe80::/10 ip6 hoplimit 255 icmpv6 type nd-router-advert accept
        ip6 saddr fe80::/10 udp sport 547 udp dport 546 accept

        # Key-only (sshd_config.d/10-no-password.conf), on every interface.
        tcp dport 22 accept

        # rxd's HTTP API and browser UI, from the LAN and the tailnet only.
        # Unauthenticated: anyone allowed here can tune the radio. rxd
        # listens on it only when /etc/rx/rxd.env says so.
        ip saddr @lan4 tcp dport 8073 accept
        ip6 saddr @lan6 tcp dport 8073 accept
        iifname "tailscale0" tcp dport 8073 accept
    }

    # Not a router.
    chain forward {
        type filter hook forward priority filter; policy drop;
    }
}
NFT

    write_file /etc/systemd/system/rx-firewall.service 0644 <<'FWUNIT'
[Unit]
Description=rx inbound firewall (SSH, rxd from the LAN, and replies)
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/usr/sbin/nft -c -f /etc/rx/firewall.nft
ExecStart=/usr/sbin/nft -f /etc/rx/firewall.nft
ExecReload=/usr/sbin/nft -f /etc/rx/firewall.nft
ExecStop=-/usr/sbin/nft delete table inet rx_firewall

[Install]
WantedBy=sysinit.target
FWUNIT
    run systemctl daemon-reload
    run systemctl enable rx-firewall.service

    # Check before loading: a ruleset that fails to parse loads nothing, but
    # this says so here rather than leaving the device open without a word.
    # Loading keeps established connections, an SSH session included.
    if $DRY_RUN; then
      log "[dry-run] nft -c -f /etc/rx/firewall.nft, then load it"
    elif nft -c -f /etc/rx/firewall.nft; then
      run systemctl restart rx-firewall.service
      log "firewall loaded: inbound SSH, rxd HTTP from the LAN, and replies"
    else
      warn "firewall rules failed to parse; NOT loaded — the device is unfiltered"
    fi
    note "Firewall: nothing reaches this device unsolicited except SSH on 22, and rxd's HTTP on 8073 from private addresses and Tailscale. Other machines can no longer resolve clockworkpi.local (mDNS answers are inbound); use its IP or Tailscale name. Rules: /etc/rx/firewall.nft; 'sudo nft list table inet rx_firewall'."
  fi

  # ----------------------------------------------------------------- desktop

  if want desktop; then
    section "Desktop (i3 + X11)"

    apt_install xserver-xorg xinit x11-xserver-utils \
                i3 i3status dmenu alacritty brightnessctl \
                fonts-dejavu-core fontconfig

    # A Lite image has no audio userland at all, and both JS8Call and rxd
    # need one. clockworkpi-audio carries the device-specific config.
    apt_install pipewire pipewire-pulse wireplumber || warn "audio stack install failed"
    if pkg_available clockworkpi-audio; then
      apt_install clockworkpi-audio || warn "clockworkpi-audio failed"
    fi

    # The complete config, written here rather than patched onto Debian's, so
    # every binding in it is one this script set. Writing it also avoids i3's
    # interactive first-run config wizard, which would block a headless boot.
    #
    # No binding uses a bare Return anywhere, including to leave resize mode.
    # Enter is always just Enter.
    #
    # This file is managed: local edits are overwritten on the next run.
    write_file "$USER_HOME/.config/i3/config" 0644 <<'I3CONF'
# Managed by rx/setup.sh -- edits here are overwritten on the next run.

# $mod is Alt (Mod1). The uConsole's CMD key needs Fn+CMD, a two-key chord for
# every window operation.
#
# i3 grabs $mod combinations globally, so any plain Alt+<letter> bound here is
# unavailable to the shell, where readline uses Meta for word motion. Window
# management therefore lives on Alt+Shift, and i3 claims only these:
#
#   taken by i3:              Alt+h/j/k/l (focus), Alt+1..9 (workspaces),
#                             Alt+r, Alt+Return
#   left to bash:             Alt+b Alt+f Alt+d Alt+t Alt+u Alt+p Alt+y Alt+.
#                             Alt+BackSpace  (word motion, kill-word, yank-arg)
#
# The cost is readline's M-l, M-r and M-<digit>.
set $mod Mod1

# 12pt is a starting point for the 5" 720p panel (~290 DPI); raise if small.
font pango:Atkinson Hyperlegible Mono 12

# --- launching --------------------------------------------------------------
bindsym $mod+Return       exec alacritty
bindsym $mod+Shift+Return exec alacritty
bindsym $mod+Shift+d      exec dmenu_run
bindsym $mod+Shift+q      kill

# --- focus ------------------------------------------------------------------
bindsym $mod+h focus left
bindsym $mod+j focus down
bindsym $mod+k focus up
bindsym $mod+l focus right
bindsym $mod+Left  focus left
bindsym $mod+Down  focus down
bindsym $mod+Up    focus up
bindsym $mod+Right focus right

# --- moving -----------------------------------------------------------------
bindsym $mod+Shift+h move left
bindsym $mod+Shift+j move down
bindsym $mod+Shift+k move up
bindsym $mod+Shift+l move right
bindsym $mod+Shift+Left  move left
bindsym $mod+Shift+Down  move down
bindsym $mod+Shift+Up    move up
bindsym $mod+Shift+Right move right

# --- layout -----------------------------------------------------------------
# The panel is wide and short, so default to side-by-side splits.
bindsym $mod+Shift+b split h
bindsym $mod+Shift+v split v
bindsym $mod+Shift+f fullscreen toggle
bindsym $mod+Shift+s layout stacking
bindsym $mod+Shift+w layout tabbed
bindsym $mod+Shift+e layout toggle split
bindsym $mod+Shift+space floating toggle
bindsym $mod+Shift+a focus parent

# --- workspaces -------------------------------------------------------------
bindsym $mod+1 workspace number 1
bindsym $mod+2 workspace number 2
bindsym $mod+3 workspace number 3
bindsym $mod+4 workspace number 4
bindsym $mod+5 workspace number 5
bindsym $mod+6 workspace number 6
bindsym $mod+7 workspace number 7
bindsym $mod+8 workspace number 8
bindsym $mod+9 workspace number 9
bindsym $mod+Shift+1 move container to workspace number 1
bindsym $mod+Shift+2 move container to workspace number 2
bindsym $mod+Shift+3 move container to workspace number 3
bindsym $mod+Shift+4 move container to workspace number 4
bindsym $mod+Shift+5 move container to workspace number 5
bindsym $mod+Shift+6 move container to workspace number 6
bindsym $mod+Shift+7 move container to workspace number 7
bindsym $mod+Shift+8 move container to workspace number 8
bindsym $mod+Shift+9 move container to workspace number 9

# --- session ----------------------------------------------------------------
bindsym $mod+Shift+c reload
bindsym $mod+Shift+r restart
bindsym $mod+Shift+x exec "i3-nagbar -t warning -m 'Exit i3?' -B 'Yes' 'i3-msg exit'"

# --- hardware keys ----------------------------------------------------------
bindsym XF86MonBrightnessUp   exec brightnessctl set +10%
bindsym XF86MonBrightnessDown exec brightnessctl set 10%-

# Automatic blanking is disabled (the panel does not survive DPMS), so this is
# the deliberate way to kill the backlight on battery. Brightness-up restores
# it; --save/--restore keeps the previous level.
bindsym $mod+Shift+o exec --no-startup-id brightnessctl --save set 0
bindsym $mod+Shift+p exec --no-startup-id brightnessctl --restore

bindsym XF86AudioRaiseVolume  exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+
bindsym XF86AudioLowerVolume  exec wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-
bindsym XF86AudioMute         exec wpctl set-mute   @DEFAULT_AUDIO_SINK@ toggle

# --- resize -----------------------------------------------------------------
# Escape only. Debian's default also binds a bare Return here, which is
# exactly the kind of stray Enter binding this config avoids.
mode "resize" {
        bindsym h resize shrink width  10 px or 10 ppt
        bindsym j resize grow   height 10 px or 10 ppt
        bindsym k resize shrink height 10 px or 10 ppt
        bindsym l resize grow   width  10 px or 10 ppt
        bindsym Escape mode "default"
}
bindsym $mod+r mode "resize"

# --- application workspaces -------------------------------------------------
assign [class="(?i)^js8call$"] workspace number 2

# meshtastic-ui sets no WM_CLASS at all, so assign has no criteria to match
# on. for_window fires once the window is mapped and titled instead.
for_window [title="^Meshtastic"] move to workspace number 3

# Only the receiver starts on its own. JS8Call and the Meshtastic dashboard
# keep their placement rules above, so they land on 2 and 3 whenever started
# -- from dmenu, or via `mesh`, which also brings meshtasticd up.
#
# rxd is headless, so it has no window to place. `radio resume` brings the
# active profile back up as the rxd@PROFILE user service, already playing,
# rather than starting rxd by hand.
exec --no-startup-id radio resume

bar {
        status_command i3status
        position top
        tray_output primary
}
I3CONF
    log "wrote a managed i3 config (no bare Return bindings)"

    # Alacritty config, pulled from this same repo. Its theme import points at
    # cytracom_light.toml, which is in neither the upstream alacritty-theme
    # repo nor any local checkout, so the import is commented out and the
    # built-in default colours are used. Uncomment once the file exists.
    local aldir="$USER_HOME/.config/alacritty"
    run mkdir -p "$aldir"
    if $DRY_RUN; then
      log "[dry-run] fetch alacritty.toml into $aldir"
    elif curl -fsSL --max-time 20 \
           "https://raw.githubusercontent.com/${GH_KEY_USER}/rx/main/alacritty.toml" \
           -o "$aldir/alacritty.toml"; then
      sed -i 's|^\( *\)\("~/.*themes.*\.toml"\)|\1# \2  # uconsole-setup: no such file|' \
        "$aldir/alacritty.toml"
      log "installed alacritty.toml (theme import disabled, using defaults)"
    else
      warn "could not fetch alacritty.toml — using alacritty defaults"
    fi

    # Atkinson Hyperlegible Next and Mono. Debian's fonts-atkinson-hyperlegible
    # is the original family only; Next and Mono are separate newer families
    # and are not packaged, so take them from the upstream Google Fonts repos.
    # alacritty.toml asks for "Atkinson Hyperlegible Mono", which is the family
    # name shipped by the -next-mono repo.
    local fontdir=/usr/local/share/fonts frepo dest tmpd
    for frepo in atkinson-hyperlegible-next atkinson-hyperlegible-next-mono; do
      dest="$fontdir/$frepo"
      if [[ -d $dest ]]; then
        log "fonts: $frepo already present"
        continue
      fi
      if $DRY_RUN; then
        log "[dry-run] install fonts from googlefonts/$frepo"
        continue
      fi
      tmpd=$(mktemp -d)
      if git clone --depth 1 "https://github.com/googlefonts/$frepo" "$tmpd" >/dev/null 2>&1 \
         && compgen -G "$tmpd/fonts/otf/*.otf" >/dev/null; then
        mkdir -p "$dest"
        cp "$tmpd"/fonts/otf/*.otf "$dest"/
        chmod 0644 "$dest"/*.otf
        log "fonts: installed $frepo ($(ls "$dest" | wc -l | tr -d ' ') faces)"
      else
        warn "fonts: could not fetch googlefonts/$frepo"
      fi
      rm -rf "$tmpd"
    done
    # Point the generic families at Atkinson: Mono for monospace, Next for
    # both proportional families. <prefer> puts these at the head of the
    # substitution list without removing the existing fallbacks, so anything
    # they lack a glyph for still resolves.
    write_file /etc/fonts/local.conf 0644 <<'FONTCONF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<!-- Managed by rx/setup.sh -->
<fontconfig>
  <alias>
    <family>monospace</family>
    <prefer><family>Atkinson Hyperlegible Mono</family></prefer>
  </alias>
  <alias>
    <family>sans-serif</family>
    <prefer><family>Atkinson Hyperlegible Next</family></prefer>
  </alias>
  <alias>
    <family>serif</family>
    <prefer><family>Atkinson Hyperlegible Next</family></prefer>
  </alias>
</fontconfig>
FONTCONF

    if ! $DRY_RUN; then
      fc-cache -f >/dev/null 2>&1 || warn "fc-cache failed"
      # Confirm the aliases actually resolve; a silent miss here means every
      # generic-family lookup quietly falls back to DejaVu.
      local generic resolved
      for generic in monospace sans-serif serif; do
        resolved=$(fc-match "$generic" 2>/dev/null | head -1) || resolved=""
        case $resolved in
          *Atkinson*) log "font: $generic -> $resolved" ;;
          *) warn "font: $generic resolved to '$resolved', not Atkinson" ;;
        esac
      done
    fi

    # i3status: Debian's default shows "ethernet" and "battery all", neither of
    # which reports anything here -- there is no wired NIC, and the uConsole
    # battery is not exposed as a standard power_supply device. Replaced with
    # labelled CPU, RAM and temperature so the numbers are identifiable.
    write_file "$USER_HOME/.config/i3status/config" 0644 <<'I3STATUS'
# Managed by rx/setup.sh
general {
        colors = true
        interval = 5
}

order += "battery 0"
order += "cpu_usage"
order += "memory"
order += "cpu_temperature 0"
order += "disk /"
order += "wireless _first_"
order += "tztime local"

# The PMIC exposes the pack as axp20x-battery rather than BAT0, so the path is
# given explicitly. It reports ENERGY_NOW/ENERGY_FULL and POWER_NOW, so
# %remaining is meaningful while discharging.
battery 0 {
        # No %remaining: it reads 00:00 whenever the pack is charging or full,
        # which is most of the time on a device that is usually plugged in.
        # format_percentage drops the two decimal places i3status defaults to.
        format = "BAT %status %percentage"
        format_percentage = "%.00f%s"
        format_down = "BAT n/a"
        path = "/sys/class/power_supply/axp20x-battery/uevent"
        # Without this i3status divides ENERGY_NOW (uWh) by CHARGE_FULL_DESIGN
        # (uAh) -- different units, and the result reads several hundred
        # percent. last_full_capacity makes it use ENERGY_FULL as denominator.
        last_full_capacity = true
        status_chr = "CHR"
        status_bat = "DIS"
        status_full = "FULL"
        low_threshold = 20
        threshold_type = percentage
}

cpu_usage {
        format = "CPU %usage"
}

memory {
        format = "RAM %used / %total"
        threshold_degraded = "10%"
        format_degraded = "RAM LOW %available"
}

cpu_temperature 0 {
        format = "TEMP %degrees°C"
        path = "/sys/class/thermal/thermal_zone0/temp"
}

disk "/" {
        format = "SD %avail"
}

wireless _first_ {
        format_up = "%essid %quality"
        format_down = "no wifi"
}

tztime local {
        format = "%H:%M"
}
I3STATUS
    log "wrote i3status config (CPU/RAM/temp/disk/wifi/clock)"

    # Start X on tty1 only. The panel is mounted rotated, so it comes up
    # portrait and needs a transform; detect at runtime rather than assume,
    # because some images already apply it at the DRM level and rotating a
    # second time leaves the display sideways.
    # Screen blanking and power management are disabled at every layer, not
    # just in X. This device is almost always on battery and the screen is
    # wanted on regardless; the DSI panel also wakes from DPMS to a grey
    # screen, so blanking is actively harmful here rather than merely unwanted.
    #
    # 1. Xorg itself, from server start. This is the durable one: it applies
    #    before any session script runs and survives anything that resets xset.
    write_file /etc/X11/xorg.conf.d/10-no-blanking.conf 0644 <<'XORGBLANK'
# Managed by rx/setup.sh
Section "ServerFlags"
    Option "BlankTime"   "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime"     "0"
EndSection

Section "Extensions"
    Option "DPMS" "Disable"
EndSection
XORGBLANK

    # 2. logind, so no idle action fires at the seat level.
    write_file /etc/systemd/logind.conf.d/10-no-idle.conf 0644 <<'LOGIND'
# Managed by rx/setup.sh
[Login]
IdleAction=ignore
IdleActionSec=0
LOGIND

    # 3. The kernel framebuffer console, which blanks independently of X and
    #    is what you land on if X ever exits. consoleblank is a boot parameter,
    #    so this needs the reboot the overlays already require.
    if [[ -f $BOOT_DIR/cmdline.txt ]]; then
      if grep -q 'consoleblank=' "$BOOT_DIR/cmdline.txt"; then
        $DRY_RUN || sed -i 's/consoleblank=[0-9]*/consoleblank=0/' "$BOOT_DIR/cmdline.txt"
      else
        # cmdline.txt must stay exactly one line.
        $DRY_RUN || sed -i '1s/$/ consoleblank=0/' "$BOOT_DIR/cmdline.txt"
      fi
      log "console blanking disabled (consoleblank=0)"
    fi

    write_file "$USER_HOME/.xinitrc" 0755 <<'XINITRC'
#!/bin/sh
# Managed by rx/setup.sh
line=$(xrandr | grep -m1 ' connected')
out=${line%% *}
geom=$(printf '%s\n' "$line" | grep -oE '[0-9]+x[0-9]+\+[0-9]+\+[0-9]+' | head -1)
w=${geom%%x*}
h=${geom#*x}; h=${h%%+*}
case "$w" in ''|*[!0-9]*) w=0 ;; esac
case "$h" in ''|*[!0-9]*) h=0 ;; esac
if [ -n "$out" ] && [ "$h" -gt "$w" ]; then
    xrandr --output "$out" --rotate right
fi

# Belt and braces. Xorg is already configured not to blank (see
# /etc/X11/xorg.conf.d/10-no-blanking.conf), but anything in a session can
# turn it back on at runtime, so assert it here too. The panel wakes from
# DPMS to a solid grey screen that needs a VT switch to clear, and this
# device is almost always on battery with the screen wanted on regardless.
xset s off
xset s noblank
xset -dpms

exec i3
XINITRC

    # Sourcing .profile keeps this from shadowing the shell's normal setup,
    # which bash would otherwise skip once .bash_profile exists.
    write_file "$USER_HOME/.bash_profile" 0644 <<'BASHPROF'
# Managed by rx/setup.sh
[ -f "$HOME/.profile" ] && . "$HOME/.profile"

# Deliberately not `exec startx`: with exec, a failing X replaces the login
# shell, the shell exits, getty respawns, autologin fires again -- an endless
# tty1 login loop with no prompt to debug from. This way a failure (or exiting
# i3) drops you at a shell on tty1 instead.
if [ -z "${DISPLAY:-}" ] && [ "$(tty)" = "/dev/tty1" ]; then
    startx || echo "startx exited ($?); you are at a shell on tty1."
fi
BASHPROF

    write_file /etc/systemd/system/getty@tty1.service.d/autologin.conf 0644 <<AUTOLOGIN
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin ${DESKTOP_USER} --noclear %I \$TERM
AUTOLOGIN
    run systemctl daemon-reload

    run chown -R "${DESKTOP_USER}:${USER_GROUP}" \
      "$USER_HOME/.config" "$USER_HOME/.xinitrc" "$USER_HOME/.bash_profile"

    log "i3 + X11 configured, autologin on tty1 as $DESKTOP_USER"
    note "Desktop: tty1 autologins as $DESKTOP_USER and starts i3. Mod is ALT: Alt+Return for a terminal, Alt+Shift+d for dmenu, Alt+Shift+q to close. Window management sits on Alt+Shift so bash keeps Alt+b/f/d/. for word motion."
    note "i3status shows battery, CPU, RAM, temperature, disk, wifi and the clock. Config: ~/.config/i3status/config (Alt+Shift+r reloads i3)."
    note "Fonts: monospace -> Atkinson Hyperlegible Mono, serif/sans-serif -> Atkinson Hyperlegible Next, via /etc/fonts/local.conf. i3 uses Mono at 12pt (~/.config/i3/config); raise it if it reads small on the 5\" panel."
    note "Display: blanking and power management are off at every layer — Xorg (10-no-blanking.conf), logind (IdleAction=ignore), the kernel console (consoleblank=0, needs the reboot) and xset in .xinitrc. Nothing locks or blanks the screen. Mod+Shift+b kills the backlight deliberately, Mod+Shift+n restores it."
    note "Desktop: screen rotation is detected at X startup, so it is a no-op if the image already rotates the panel. If it lands sideways, edit ~/.xinitrc."
    note "Wi-Fi on a Lite image: 'sudo raspi-config' (System Options -> Wireless LAN), or nmtui if NetworkManager is in use."
  fi

  # ------------------------------------------------------------------ claude

  if want claude; then
    section "Claude Code"

    # The signed apt repo rather than the native curl|bash installer. That
    # installer puts everything under $HOME and explicitly refuses to run
    # under sudo -- here it would either abort or land in /root/.local/bin,
    # where the desktop user's shell would never find it. apt also makes this
    # step idempotent for free and folds updates into the normal upgrade path.
    if ! pkg_available claude-code; then
      apt_install curl gnupg
      if $DRY_RUN; then
        log "[dry-run] add downloads.claude.ai apt repo (key ${CLAUDE_KEY_FP})"
      else
        install -d -m 0755 /etc/apt/keyrings
        if curl -fsSL --max-time 30 "$CLAUDE_KEY_URL" -o "$CLAUDE_KEY"; then
          # Check the key is the expected one before trusting it. A truncated
          # or captive-portal-mangled download otherwise shows up much later
          # as an opaque NO_PUBKEY error, and a substituted key would be worse.
          local fp
          fp=$(gpg --show-keys --with-colons "$CLAUDE_KEY" 2>/dev/null \
               | awk -F: '/^fpr:/{print $10; exit}')
          if [[ $fp == "$CLAUDE_KEY_FP" ]]; then
            printf 'deb [signed-by=%s] https://downloads.claude.ai/claude-code/apt/stable stable main\n' \
              "$CLAUDE_KEY" > "$CLAUDE_LIST"
            apt_update_soft
            log "added the Claude Code apt repo (key verified)"
          else
            rm -f "$CLAUDE_KEY"
            warn "claude-code signing key fingerprint mismatch (got '${fp:-none}', expected $CLAUDE_KEY_FP) — repo NOT added"
          fi
        else
          warn "could not fetch the Claude Code signing key"
        fi
      fi
    fi

    if pkg_available claude-code || $DRY_RUN; then
      apt_install claude-code
      log "installed claude-code"
      note "Claude Code: run 'claude' to start; log in via the browser prompt. Needs a Pro/Max/Team/Enterprise or Console account (the free plan does not include it)."
      note "Claude Code installed from apt does not auto-update: 'sudo apt upgrade claude-code'."
    else
      warn "claude-code not available from apt"
      note "Claude Code was not installed. Fall back to the native installer, run as your own user and NOT with sudo: curl -fsSL https://claude.ai/install.sh | bash"
    fi
  fi

  # --------------------------------------------------------------- AIO board

  local AIO_VIA_PACKAGE=false
  if want aio; then
    section "HackerGadgets AIO v2 board"
    require_akrex_repo

    if pkg_available hackergadgets-uconsole-aio-board; then
      log "vendor metapackage available — using it"
      # No --install-recommends: the Recommends are tar1090, sdrpp-brown (an
      # SDR++ build, which rxd replaces) and pygpsclient. tar1090 is an ADS-B
      # stack that builds from source in its postinst (pulling gcc, make, git,
      # lighttpd, tk-dev) and starts readsb, which claims the RTL-SDR and
      # fails when none is visible. Only Depends: rtl-sdr is required here.
      if run apt-get install -y --no-install-recommends hackergadgets-uconsole-aio-board; then
        AIO_VIA_PACKAGE=true
      else
        warn "hackergadgets-uconsole-aio-board failed to install — falling back to manual overlays"
        note "The AIO metapackage failed. Check 'sudo dpkg --configure -a' output; the boot overlays were written by hand instead."
      fi
    else
      log "vendor metapackage not in any configured repo — writing overlays by hand"
      note "hackergadgets-uconsole-aio-board was unavailable; boot config was written manually. If you later add Rex's ClockworkPi apt repo, the metapackage is the more maintainable path."
    fi

    # The metapackage's postinst writes into the desktop user's home while
    # running as root -- a pygpsclient venv, a .cache directory, an installer
    # script. A root-owned .cache in particular breaks any GUI app that tries
    # to write its own cache, so hand these back.
    if ! $DRY_RUN; then
      local stray
      while IFS= read -r stray; do
        [[ -n $stray ]] || continue
        chown -R "${DESKTOP_USER}:${USER_GROUP}" "$stray" 2>/dev/null \
          && log "reclaimed $(basename "$stray") from root"
      done < <(find "$USER_HOME" -mindepth 1 -maxdepth 1 ! -user "$DESKTOP_USER" 2>/dev/null)
    fi

    # aiov2_ctl drives the v2 power rails and reapplies them at boot. Install
    # it regardless of which path above ran — the metapackage may or may not
    # include it, and the rails are what make the board respond at all.
    if command -v aiov2_ctl >/dev/null 2>&1; then
      log "aiov2_ctl already installed"
    else
      apt_install python3 python3-pyqt6
      if [[ -d $AIOV2_DIR/.git ]]; then
        run git -C "$AIOV2_DIR" pull --ff-only
      else
        run git clone --depth 1 "$AIOV2_REPO" "$AIOV2_DIR"
      fi
      if ! run python3 "$AIOV2_DIR/aiov2_ctl.py" --install; then
        warn "aiov2_ctl install failed — falling back to a plain pinctrl rail unit"
      fi
    fi

    if command -v aiov2_ctl >/dev/null 2>&1 || $DRY_RUN; then
      local rail
      local rail
      for rail in "${BOOT_RAILS[@]}"; do
        # Current state, and separately the state applied at boot. These are
        # distinct in aiov2_ctl: `aiov2_ctl SDR on` powers the rail now, while
        # aiov2-rails-boot.service replays only what --boot-rail has recorded,
        # so setting just the former leaves every rail dark after a reboot.
        run aiov2_ctl "$rail" on || warn "aiov2_ctl $rail on failed"
        run aiov2_ctl --boot-rail "$rail" on || warn "could not set $rail to come up at boot"
      done
      # GPS and LoRa are deliberately not touched rather than forced off, so a
      # re-run does not undo a rail you switched on by hand.
      run systemctl enable aiov2-rails-boot.service \
        || warn "aiov2-rails-boot.service not found; rails may not persist across reboot"
      log "power rails on now and at boot: ${BOOT_RAILS[*]} (others left as-is)"
    else
      # Fallback: raw pinctrl plus our own oneshot, so the board still comes
      # up with its rails on even without the vendor tooling.
      apt_install pinctrl || apt_install raspi-utils || true
      write_file /usr/local/sbin/uconsole-aio-rails 0755 <<'RAILS'
#!/bin/sh
# Managed by rx/setup.sh — AIO v2 GPIO power rails.
#
#   usage: uconsole-aio-rails [on|off]           boot rails (SDR + USB hub)
#          uconsole-aio-rails <RAIL> [on|off]    one rail by name
#
# Rails: GPS LORA SDR USB. Only the boot set comes up automatically; the
# RTL-SDR needs USB too, being an internal USB device behind the AIO hub.
set -eu

rail_pin() {
    case "$1" in
        GPS)  echo __RAIL_GPS__ ;;
        LORA) echo __RAIL_LORA__ ;;
        SDR)  echo __RAIL_SDR__ ;;
        USB)  echo __RAIL_USB__ ;;
        *)    echo "unknown rail: $1 (GPS LORA SDR USB)" >&2; exit 2 ;;
    esac
}

level_for() {
    case "$1" in
        on)  echo dh ;;
        off) echo dl ;;
        *)   echo "usage: $0 [RAIL] [on|off]" >&2; exit 2 ;;
    esac
}

case "${1:-}" in
    GPS|LORA|SDR|USB)
        pin=$(rail_pin "$1")
        lvl=$(level_for "${2:-on}")
        pinctrl "$pin" op
        pinctrl "$pin" "$lvl"
        ;;
    *)
        lvl=$(level_for "${1:-on}")
        for r in __BOOT_RAILS__; do
            pin=$(rail_pin "$r")
            pinctrl "$pin" op
            pinctrl "$pin" "$lvl"
        done
        ;;
esac
RAILS
      if ! $DRY_RUN; then
        sed -i \
          -e "s|__RAIL_GPS__|${RAIL_GPS}|" \
          -e "s|__RAIL_LORA__|${RAIL_LORA}|" \
          -e "s|__RAIL_SDR__|${RAIL_SDR}|" \
          -e "s|__RAIL_USB__|${RAIL_USB}|" \
          -e "s|__BOOT_RAILS__|${BOOT_RAILS[*]}|" \
          /usr/local/sbin/uconsole-aio-rails
      fi
      write_file /etc/systemd/system/uconsole-aio-rails.service 0644 <<'UNIT'
[Unit]
Description=uConsole AIO v2 power rails
DefaultDependencies=no
After=sysinit.target
Before=basic.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/uconsole-aio-rails on

[Install]
WantedBy=sysinit.target
UNIT
      run systemctl daemon-reload
      run systemctl enable uconsole-aio-rails.service
      run /usr/local/sbin/uconsole-aio-rails on || warn "pinctrl rail enable failed (pinctrl missing?)"
      log "power rails on via pinctrl fallback unit: ${BOOT_RAILS[*]}"
    fi
  fi

  # ----------------------------------------------------- boot config (CM4)

  # --------------------------------------------------------- boot config

  # The overlays this hardware needs, independent of which sections are
  # running. Building the list from the active sections means `--only gps`
  # rewrites the block with just the GPS lines and silently drops the RTC and
  # SPI overlays the other subsystems depend on.
  #
  # Lines already set elsewhere in config.txt are skipped rather than
  # repeated: the AIO metapackage writes some of these itself, and a second
  # dtoverlay for the same device would try to instantiate it twice.
  if [[ -f $BOOT_DIR/config.txt ]]; then
    section "Boot configuration ($BOOT_DIR/config.txt)"

    local -a want_overlays=(
      "dtparam=i2c_arm=on"                 # RTC bus
      "dtoverlay=i2c-rtc,pcf85063a"        # RTC
      "enable_uart=1"                      # GPS on the PL011
      "dtoverlay=pps-gpio,gpiopin=6"       # GPS PPS for chrony
      "dtparam=spi=on"
      "dtoverlay=spi1-1cs"                 # LoRa: creates /dev/spidev1.0
    )

    local -a stanza=("[all]" "# HackerGadgets AIO v2 on uConsole CM4")
    local ov existing
    existing=$(sed "\|^${BEGIN_MARK}\$|,\|^${END_MARK}\$|d" "$BOOT_DIR/config.txt" \
               | grep -vE '^[[:space:]]*#')
    for ov in "${want_overlays[@]}"; do
      if printf '%s\n' "$existing" | grep -qxF "$ov"; then
        log "already set elsewhere: $ov"
      else
        stanza+=("$ov")
        log "adding: $ov"
      fi
    done

    if (( ${#stanza[@]} > 2 )); then
      printf '%s\n' "${stanza[@]}" | apply_block "$BOOT_DIR/config.txt"
      note "Boot overlays changed — a reboot is required before RTC/GPS/LoRa work."
    else
      # Still rewrite, so a block left over from an earlier narrower run is
      # replaced by the full set rather than kept.
      printf '%s\n' "${stanza[@]}" | apply_block "$BOOT_DIR/config.txt"
      log "all required overlays already present"
    fi
  fi

  # --------------------------------------------------------------------- rtc

  if want rtc; then
    section "Real-time clock"
    apt_install i2c-tools

    # The kernel probes the PCF85063A early in boot, before aiov2-rails-boot
    # has brought the AIO rails up, gets no answer ("RTC chip is not present",
    # -121) and gives up -- so /dev/rtc0 never appears and the clock boots at
    # whatever date systemd last knew. The chip answers fine once the rails
    # are on, so bind it then, and load the time from it before chrony starts.
    #
    # The same script seeds the chip when the system clock is already
    # disciplined, which is the state any re-run of this script finds it in.
    # That replaces a manual 'hwclock -w' that could never work while the
    # chip was unbound.
    write_file /usr/local/sbin/uconsole-rtc 0755 <<'RTC'
#!/bin/sh
# Managed by rx/setup.sh — bind the AIO v2 RTC once the power rails are up,
# then either load the system clock from it (boot) or seed it (clock synced).
set -u

if [ ! -e /dev/rtc0 ]; then
    for dev in /sys/bus/i2c/devices/*-0051; do
        [ -e "$dev" ] || continue
        [ -e "$dev/driver" ] && continue
        # The rail may still be settling; give the chip a few seconds.
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            echo "${dev##*/}" > /sys/bus/i2c/drivers/rtc-pcf85063/bind 2>/dev/null && break
            sleep 1
        done
    done
fi

if [ ! -e /dev/rtc0 ]; then
    echo "uconsole-rtc: no RTC bound — the chip is not answering at 0x51" >&2
    exit 1
fi

# At boot this runs before chrony, so 'tracking' fails and the RTC is read.
# Run later against a disciplined clock, it writes the chip instead -- never
# the other way round, which would step good time back to the RTC's drift.
if chronyc -n tracking 2>/dev/null | grep -q '^Leap status *: Normal'; then
    hwclock --systohc && echo "uconsole-rtc: RTC seeded from the synchronised system clock"
elif hwclock --hctosys; then
    echo "uconsole-rtc: system clock set from the RTC"
else
    # A chip that lost power (flat or missing CR1220) holds no valid time.
    # The clock then keeps fake-hwclock's restore until GPS or NTP fixes it.
    echo "uconsole-rtc: RTC holds no valid time; system clock left alone" >&2
fi
exit 0
RTC
    write_file /etc/systemd/system/uconsole-rtc.service 0644 <<'UNIT'
[Unit]
Description=uConsole AIO v2 RTC (bind after the power rails, then load time)
After=aiov2-rails-boot.service uconsole-aio-rails.service fake-hwclock.service
Before=chrony.service time-sync.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/uconsole-rtc

[Install]
WantedBy=multi-user.target
UNIT
    run systemctl daemon-reload
    run systemctl enable uconsole-rtc.service
    # Not --now: start is a no-op on an already-active oneshot, so call the
    # script directly; on a synced clock that binds and seeds the chip.
    run /usr/local/sbin/uconsole-rtc || warn "RTC did not bind — see 'dmesg | grep -i rtc'"

    # fake-hwclock stays on as the fallback for a flat CR1220. It restores
    # the last-saved time early in boot and only ever moves the clock
    # forward, and uconsole-rtc runs after it, so a working RTC still wins.
    if pkg_installed fake-hwclock; then
      run systemctl enable fake-hwclock
      log "fake-hwclock enabled as the fallback behind the RTC"
    fi
    note "RTC: 'systemctl status uconsole-rtc' says whether the chip bound and which way time went. 'Power loss detected' in dmesg after a full power-off means the CR1220 is flat, missing or in backwards."
  fi

  # --------------------------------------------------------------------- gps

  if want gps; then
    section "GPS"
    apt_install gpsd gpsd-clients pps-tools minicom

    # The kernel serial console owns /dev/ttyS0 and will fight gpsd for it.
    if [[ -f $BOOT_DIR/cmdline.txt ]] && grep -q 'console=serial0,115200' "$BOOT_DIR/cmdline.txt"; then
      if $DRY_RUN; then
        log "[dry-run] strip console=serial0,115200 from cmdline.txt"
      else
        sed -i 's/console=serial0,115200 *//' "$BOOT_DIR/cmdline.txt"
      fi
      log "removed serial console from cmdline.txt"
    fi
    run systemctl disable --now serial-getty@ttyS0.service 2>/dev/null || true

    write_file /etc/default/gpsd 0644 <<'GPSD'
# Managed by rx/setup.sh — AIO v2 GPS on the CM4 PL011 UART.
START_DAEMON="true"
USBAUTO="false"
DEVICES="/dev/ttyS0"
# -n polls the receiver without waiting for a client to connect.
GPSD_OPTIONS="-n -s 9600"
GPSD
    # The service, not just the socket: socket activation only starts gpsd when
    # a client connects to 2947, and chrony reads shared memory rather than
    # that socket -- so under socket activation alone gpsd would never run and
    # no time would ever reach chrony.
    run systemctl enable gpsd.socket
    run systemctl enable --now gpsd.service || warn "gpsd.service would not start"
    log "gpsd running against /dev/ttyS0 @ 9600"

    # GPS-disciplined time. This matters off-grid: JS8 and FT8 need sub-second
    # accuracy, which is exactly when there is no network to get it from.
    apt_install chrony
    # Only one thing may discipline the clock.
    run systemctl disable --now systemd-timesyncd 2>/dev/null || true

    local chrony_conf=/etc/chrony/chrony.conf
    local chrony_drop=/etc/chrony/conf.d/10-uconsole-gps.conf
    local chrony_target="$chrony_conf"
    [[ -d /etc/chrony/conf.d ]] && chrony_target="$chrony_drop"

    # rtcsync is in Debian's shipped chrony.conf; declaring it twice is a
    # config error, so only add it when it is not already there.
    local rtcsync_line=""
    if ! grep -qs '^[[:space:]]*rtcsync' "$chrony_conf"; then
      rtcsync_line=$'\n# Keep the battery-backed RTC in step, so the clock is right at boot\n# before any GPS fix or network.\nrtcsync'
    fi

    if [[ $chrony_target == "$chrony_drop" ]]; then
      write_file "$chrony_drop" 0644 <<CHRONYGPS
# Managed by rx/setup.sh — GPS-disciplined time.
#
# gpsd publishes NMEA time on SHM segment 0. That is only good to ~100 ms, so
# it supplies coarse time while the kernel PPS device from the pps-gpio
# overlay (GPIO 6) does the actual disciplining. 'lock NMEA' ties the PPS
# pulses to NMEA's seconds so chrony knows which second each pulse belongs to.
refclock SHM 0 refid NMEA offset 0.2 delay 0.2 poll 3
refclock PPS /dev/pps0 refid PPS lock NMEA${rtcsync_line}
CHRONYGPS
    else
      printf '%s\n' \
        '# GPS-disciplined time: NMEA over gpsd shared memory for coarse time,' \
        '# kernel PPS (pps-gpio on GPIO 6) for the actual disciplining.' \
        'refclock SHM 0 refid NMEA offset 0.2 delay 0.2 poll 3' \
        'refclock PPS /dev/pps0 refid PPS lock NMEA'"${rtcsync_line}" \
        | apply_block "$chrony_conf"
    fi

    if ! $DRY_RUN; then
      if chronyd -Q -f "$chrony_conf" >/dev/null 2>&1 || true; then :; fi
      systemctl restart chrony 2>/dev/null || warn "chrony would not restart"
    fi
    log "chrony configured for GPS + PPS (wrote ${chrony_target})"
    note "GPS time: after reboot check 'chronyc sources' — NMEA and PPS should both appear, PPS with a '*' once locked. 'ppstest /dev/pps0' proves the pulse itself."
    note "GPS: needs the antenna on the 'GPS' IPEX pad and a clear sky view. The rail comes up at boot; check with 'cgps -s' or 'gpsmon'."
  fi

  # -------------------------------------------------------------------- lora

  if want lora; then
    section "LoRa mesh (Meshtastic / MeshCore)"
    require_akrex_repo

    apt_install libgpiod-dev libyaml-cpp-dev libbluetooth-dev libusb-1.0-0-dev \
                libi2c-dev openssl libssl-dev

    if ! pkg_available meshtasticd; then
      log "adding the Meshtastic apt repo"
      # The vendor guide wgets a pinned .deb that is long stale; the OBS repo
      # keeps meshtasticd updatable through normal apt upgrades.
      if $DRY_RUN; then
        log "[dry-run] fetch Meshtastic signing key and add ${MESHTASTIC_REPO}"
      else
        mkdir -p /etc/apt/keyrings
        if curl -fsSL --max-time 30 "${MESHTASTIC_REPO}Release.key" \
             | gpg --dearmor --yes -o /etc/apt/keyrings/meshtastic.gpg; then
          chmod 0644 /etc/apt/keyrings/meshtastic.gpg
          printf 'deb [signed-by=/etc/apt/keyrings/meshtastic.gpg] %s /\n' "$MESHTASTIC_REPO" \
            > /etc/apt/sources.list.d/meshtastic.list
          apt_update_soft
        else
          warn "could not fetch the Meshtastic signing key"
        fi
      fi
    fi

    if pkg_available meshtasticd || $DRY_RUN; then
      apt_install meshtasticd
    else
      warn "meshtasticd unavailable; install it by hand from https://github.com/meshtastic/firmware/releases"
      note "meshtasticd was not installed — the SPI overlays are in place, so the radio is ready once you do."
    fi

    # meshtasticd gets a config of its own rather than the packaged
    # config.yaml, which the AIO metapackage edits to add `GPS: SerialPath:
    # /dev/ttyS0`. A config.d drop-in cannot remove that key, and gpsd owns
    # the port to feed chrony; two readers on one UART garble both streams.
    # Same state directory as before, so the node keeps its identity.
    if [[ -f /etc/meshtasticd/config.d/uconsole-aio-v2.yaml ]] \
       && grep -qs 'Managed by rx/setup.sh' /etc/meshtasticd/config.d/uconsole-aio-v2.yaml; then
      run rm -f /etc/meshtasticd/config.d/uconsole-aio-v2.yaml
      log "removed the old config.d drop-in (superseded by rx.yaml)"
    fi
    write_file /etc/meshtasticd/rx.yaml 0644 <<'MESHYAML'
# Managed by rx/setup.sh — meshtasticd on the HackerGadgets AIO v2 (SX1262).
# Started with --config by meshtasticd.service.d/50-rx.conf, in place of the
# packaged config.yaml.
Lora:
  Module: sx1262
  DIO2_AS_RF_SWITCH: true
  DIO3_TCXO_VOLTAGE: true
  IRQ: 26
  Busy: 24
  Reset: 25
  spidev: spidev1.0

# No GPS block on purpose: gpsd owns /dev/ttyS0 to feed chrony.

Logging:
  LogLevel: info

Webserver:
  Port: 443
  RootPath: /usr/share/meshtasticd/web
  SSLKey: /etc/meshtasticd/ssl/private_key.pem
  SSLCert: /etc/meshtasticd/ssl/certificate.pem

General:
  MaxNodes: 200
  MaxMessageQueue: 100
  ConfigDirectory: /etc/meshtasticd/config.d/
MESHYAML

    # Both mesh daemons drive the same SX1262, so at most one may run, and
    # only when asked for. aiov2_ctl starts meshtasticd every time it powers
    # the LoRa rail -- at boot, and on every run of the aio section -- so
    # rather than fight it, each unit refuses to start unless rx-mesh has
    # left a flag in /run, which is empty at every boot.
    write_file /etc/systemd/system/meshtasticd.service.d/50-rx.conf 0644 <<'MESHUNIT'
# Managed by rx/setup.sh — start only through rx-mesh, with rx's config.
[Service]
ExecCondition=/usr/bin/test -e /run/rx/mesh/meshtastic
ExecStart=
ExecStart=/usr/bin/meshtasticd --config=/etc/meshtasticd/rx.yaml
MESHUNIT

    write_file /usr/local/sbin/rx-mesh 0755 <<'RXMESH'
#!/bin/sh
# Managed by rx/setup.sh — the one way to start or stop the mesh daemons that
# share the AIO's LoRa radio. Run as root (radio calls it through sudo).
#
#   rx-mesh start meshtastic|meshcore   stop the other, then start this one
#   rx-mesh stop                        stop both
#   rx-mesh status                      the running network, or "off"
#   rx-mesh release-pins                free the radio's GPIO lines
#
# Each unit has ExecCondition=test -e /run/rx/mesh/<network>, so nothing else
# can start it: not boot, and not aiov2_ctl, which starts meshtasticd whenever
# it powers the LoRa rail.
set -eu
FLAGS=/run/rx/mesh

unit() {
    case $1 in
        meshtastic) echo meshtasticd ;;
        meshcore)   echo raspberrypimc-companion ;;
        *)          echo "rx-mesh: unknown network '$1'" >&2; exit 2 ;;
    esac
}

release_pins() {
    # MeshCoreRPI drives BUSY, RESET and IRQ through sysfs and leaves them
    # exported when it stops; meshtasticd then cannot claim them ("cannot
    # claim pin GPIO26"). sysfs numbers are offset by the lowest chip base,
    # 512 on current Pi kernels -- the same rule MeshCoreRPI uses.
    base=""
    for c in /sys/class/gpio/gpiochip*; do
        [ -e "$c/base" ] || continue
        b=$(cat "$c/base")
        if [ -z "$base" ] || [ "$b" -lt "$base" ]; then base=$b; fi
    done
    [ -n "$base" ] || return 0
    for pin in 24 25 26; do
        n=$((base + pin))
        if [ -e "/sys/class/gpio/gpio$n" ]; then echo "$n" > /sys/class/gpio/unexport || true; fi
    done
}

stop_all() {
    rm -f "$FLAGS/meshtastic" "$FLAGS/meshcore"
    systemctl stop meshtasticd raspberrypimc-companion 2>/dev/null || true
    release_pins
}

case ${1:-} in
    start)
        net=${2:-}; u=$(unit "$net")
        if [ -e "$FLAGS/$net" ] && systemctl is-active --quiet "$u"; then exit 0; fi
        stop_all
        mkdir -p "$FLAGS"
        : > "$FLAGS/$net"
        systemctl reset-failed "$u" 2>/dev/null || true
        systemctl start "$u"
        ;;
    stop)
        stop_all
        ;;
    status)
        for net in meshtastic meshcore; do
            if systemctl is-active --quiet "$(unit "$net")"; then echo "$net"; exit 0; fi
        done
        echo off
        ;;
    release-pins)
        release_pins
        ;;
    *)
        echo "usage: rx-mesh start meshtastic|meshcore | stop | status | release-pins" >&2
        exit 2
        ;;
esac
RXMESH
    run systemctl daemon-reload
    # Not at boot: the flags above already guarantee that, and disabling
    # keeps systemctl's own view honest. aiov2_ctl's switch is left off too,
    # but only written when it is not already -- its "off" path runs
    # `disable --now`, which would stop a running node on every maint run.
    run systemctl disable meshtasticd 2>/dev/null || true
    if command -v aiov2_ctl >/dev/null 2>&1 \
       && ! aiov2_ctl --mesh-on-boot status 2>/dev/null | grep -q 'mesh_on_boot: off'; then
      run aiov2_ctl --mesh-on-boot off || warn "could not turn off aiov2_ctl's mesh autostart"
    fi

    # meshtastic-mui provides /usr/bin/meshtastic-ui, the dashboard.
    if pkg_available meshtastic-mui; then
      apt_install_opt meshtastic-mui
    else
      warn "meshtastic-mui not available in any configured repo"
    fi

    # The radio needs /dev/spidev1.0 from the spi1-1cs overlay. Say so plainly
    # rather than leaving a daemon that starts and finds nothing.
    if ! $DRY_RUN && [[ ! -e /dev/spidev1.0 ]]; then
      warn "/dev/spidev1.0 does not exist — the LoRa radio cannot be reached until the spi1-1cs overlay is active (reboot)."
      note "LoRa: /dev/spidev1.0 was missing at setup time. Reboot, then check it exists before 'radio meshtastic'."
    fi

    # MeshCore on Linux: MeshCoreRPI, a port of the MeshCore firmware to the
    # Pi, run as a companion (the node a client app talks to). A third-party
    # fork, so pinned to one release and checked against its digest; bump
    # both together. Its 1.8 V TCXO default and its handling of the 512 sysfs
    # GPIO offset were read in its source before choosing it.
    local MC_VER=0.2.4+de72da2
    local MC_DEB="raspberrypimc-native-companion_${MC_VER}_arm64.deb"
    local MC_URL="https://github.com/engperini/MeshCoreRPI/releases/download/v${MC_VER%%+*}/${MC_DEB}"
    local MC_SHA=3301d139cc206c4bd548c5935cf59afcfc0353cd1d62fed9292e067b72a7a318

    # The env file first: the package's postinst copies its example only when
    # none exists, and restarts the service on upgrade (which the
    # ExecCondition below then refuses unless MeshCore is the active network).
    write_file /etc/raspberrypimc/companion.env 0644 <<'MCENV'
# Managed by rx/setup.sh — MeshCoreRPI companion on the AIO v2's SX1262.
# Radio: the North Texas MeshCore settings (ntxmesh.com/join): 910.525 MHz,
# 62.5 kHz, SF 7, CR 5. Applied at every start; the client app cannot
# change them.
RPI_FREQ_HZ=910525000
RPI_BW_HZ=62500
RPI_SF=7
RPI_CR=5
# The firmware reports 20 dBm as its maximum.
RPI_TX_DBM=20
RPI_RADIO_DRIVER=sx1262
RPI_DATA_DIR=/var/lib/raspberrypimc/userdata
# spidev1.0, with chip select left to the kernel (-1: no manual CS pin).
RPI_SPI_DEV_PREFIX=/dev/spidev
RPI_SPI_BUS=1
RPI_SPI_CS=0
RPI_CS_PIN=-1
RPI_SPI_SPEED_HZ=1000000
RPI_RESET_PIN=25
RPI_BUSY_PIN=24
RPI_IRQ_PIN=26
RPI_TXEN_PIN=-1
RPI_RXEN_PIN=-1
# 1.8 V TCXO on DIO3, RF switch on DIO2 -- as in meshtasticd's config.
RPI_USE_TCXO=1
RPI_USE_DIO2_RF=1
# Clients connect over loopback only: the port is unauthenticated.
RPI_COMPANION_TCP_PORT=5000
RPI_COMPANION_TCP_HOST=127.0.0.1
RPI_COMPANION_BLE_ENABLE=0
# Its web GUI would listen on 0.0.0.0:8080 without a password.
RPI_COMPANION_WEB_ENABLE=0
RPI_ADVERT_INTERVAL_MIN=0
RPI_ADVERT_MODE=flood
MCENV
    write_file /etc/systemd/system/raspberrypimc-companion.service.d/50-rx.conf 0644 <<'MCUNIT'
# Managed by rx/setup.sh — start only through rx-mesh; free the radio's pins
# on the way out so meshtasticd can claim them.
[Service]
ExecCondition=/usr/bin/test -e /run/rx/mesh/meshcore
ExecStopPost=/usr/local/sbin/rx-mesh release-pins
MCUNIT
    run systemctl daemon-reload

    local mc_have=""
    mc_have=$(dpkg-query -W -f='${Version}' raspberrypimc-native-companion 2>/dev/null) || mc_have=""
    if [[ $mc_have == "$MC_VER" ]]; then
      log "MeshCoreRPI companion $MC_VER already installed"
    elif [[ $(dpkg --print-architecture) != arm64 ]]; then
      warn "MeshCoreRPI ships arm64 only; skipping MeshCore"
    elif $DRY_RUN; then
      log "[dry-run] install MeshCoreRPI companion $MC_VER from $MC_URL"
    else
      local mc_tmp; mc_tmp=$(mktemp -d)
      if curl -fsSL --max-time 120 "$MC_URL" -o "$mc_tmp/$MC_DEB" \
         && printf '%s  %s\n' "$MC_SHA" "$mc_tmp/$MC_DEB" | sha256sum -c --quiet -; then
        if apt-get install -y "$mc_tmp/$MC_DEB"; then
          log "installed MeshCoreRPI companion $MC_VER"
        else
          warn "MeshCoreRPI install failed"
        fi
      else
        warn "MeshCoreRPI download failed or did not match its pinned digest; MeshCore not installed"
      fi
      rm -rf "$mc_tmp"
    fi
    # Its postinst enables the service at boot; rx-mesh starts it instead.
    if [[ -f /lib/systemd/system/raspberrypimc-companion.service ]]; then
      run systemctl disable raspberrypimc-companion 2>/dev/null || true
    fi

    # Python clients, each in a venv: neither has a Debian package, and
    # bookworm marks the system interpreter externally-managed. radio talks
    # to the nodes through them.
    local mtcli=/opt/meshtastic-cli mccli=/opt/meshcore-cli
    if ! $DRY_RUN; then
      apt_install_opt python3-venv
      if [[ ! -x $mtcli/bin/meshtastic ]]; then
        if python3 -m venv "$mtcli" 2>/dev/null \
           && "$mtcli/bin/pip" install --quiet --upgrade pip meshtastic 2>/dev/null; then
          log "installed the meshtastic CLI into $mtcli"
        else
          warn "could not install the meshtastic CLI"
        fi
      fi
      [[ -x $mtcli/bin/meshtastic ]] && ln -sf "$mtcli/bin/meshtastic" /usr/local/bin/meshtastic
      if [[ ! -x $mccli/bin/meshcli ]]; then
        if python3 -m venv "$mccli" 2>/dev/null \
           && "$mccli/bin/pip" install --quiet --upgrade pip meshcore-cli 2>/dev/null; then
          log "installed meshcore-cli into $mccli"
        else
          warn "could not install meshcore-cli"
        fi
      fi
      [[ -x $mccli/bin/meshcli ]] && ln -sf "$mccli/bin/meshcli" /usr/local/bin/meshcore-cli
    fi

    # The node-side half of `radio meshtastic`: its settings and the mesh
    # commands, through the meshtastic library in the CLI's venv. Identity
    # and region come from the config at the top of this script.
    write_file /usr/local/lib/rx/meshtastic_ops.py 0644 <<'MTOPS'
"""Managed by rx/setup.sh — Meshtastic operations for radio, run with the
meshtastic CLI's venv interpreter (/opt/meshtastic-cli/bin/python).

  apply            put the North Texas settings and our identity in effect
  nodes            heard nodes, most recent first
  send TEXT        to the primary channel
  dm NAME TEXT     direct message; NAME is a long or short name, or !id
  join URL         add the channels in a shared URL, keeping ours
  info             identity, radio, channels and policy

Settings follow NTX Mesh (ntxmesh.com/join): every metroplex county runs
LONG_FAST except Wise. Position is never sent.
"""
import json
import logging
import os
import sys
import time

from meshtastic.tcp_interface import TCPInterface

# The library logs tracebacks from its heartbeat thread whenever a connection
# closes under it, which every short-lived command here does.
logging.disable(logging.CRITICAL)


def mesh_conf():
    # Written by setup.sh from the config at the top of it.
    conf = {}
    with open("/etc/rx/mesh.conf", encoding="utf-8") as fh:
        for line in fh:
            key, sep, value = line.strip().partition("=")
            if sep and not key.startswith("#"):
                conf[key] = value
    return conf


CONF = mesh_conf()
OWNER_LONG, OWNER_SHORT, REGION = CONF["NODE_NAME"], CONF["NODE_SHORT"], CONF["LORA_REGION"]

# Slot 20 is LongFast's default, 906.875 MHz in the US. Pinned rather than
# left at 0, which hashes the primary channel's name: joining a private
# channel as primary would otherwise move the node off the regional
# frequency.
WANT = {
    "config": {
        "lora": {"region": REGION, "use_preset": True, "modem_preset": "LONG_FAST",
                 "channel_num": 20, "hop_limit": 3, "tx_enabled": True,
                 "ignore_mqtt": True, "config_ok_to_mqtt": False},
        "device": {"role": "CLIENT", "node_info_broadcast_secs": 10800},
        # NTX also suggests a 60 s smart minimum interval; the firmware clamps
        # it to 300, and with no position ever sent it would not matter.
        "position": {"gps_mode": "NOT_PRESENT", "fixed_position": False,
                     "position_broadcast_secs": 3600,
                     "position_broadcast_smart_enabled": True,
                     "broadcast_smart_minimum_distance": 100},
    },
    "module": {
        "telemetry": {"device_update_interval": 10800, "environment_update_interval": 3600},
        "mqtt": {"enabled": False},
    },
}

NAMES_CACHE = os.path.expanduser("~/.cache/rx/mesh-names-meshtastic")


def connect():
    last = None
    for _ in range(20):
        try:
            iface = TCPInterface(hostname="localhost")
        except Exception as exc:  # the daemon takes a few seconds to listen
            last = exc
            time.sleep(1.5)
            continue
        # The library's reader thread finishes connecting -- and sends its
        # first heartbeat -- just after the constructor returns. Closing
        # before then makes it print a BrokenPipe traceback.
        time.sleep(0.5)
        return iface
    sys.exit("meshtastic: cannot reach meshtasticd on localhost:4403 (%s)" % last)


def coerce(msg, key, value):
    field = msg.DESCRIPTOR.fields_by_name[key]
    if field.enum_type is not None and isinstance(value, str):
        return field.enum_type.values_by_name[value].number
    return value


def differences(iface):
    node = iface.localNode
    out = []
    for kind, groups in WANT.items():
        root = node.localConfig if kind == "config" else node.moduleConfig
        for group, fields in groups.items():
            msg = getattr(root, group)
            for key, value in fields.items():
                value = coerce(msg, key, value)
                if getattr(msg, key) != value:
                    out.append((msg, group, key, value))
    user = (iface.getMyNodeInfo() or {}).get("user", {})
    owner_ok = user.get("longName") == OWNER_LONG and user.get("shortName") == OWNER_SHORT
    return out, owner_ok


def apply():
    # A config write makes the node reboot itself about 7 s later, and writes
    # that land around that reboot can be lost -- seen with lora and position
    # together. So write, wait out the reboot, read back, and retry what is
    # still different.
    applied = set()
    for _ in range(3):
        iface = connect()
        try:
            diffs, owner_ok = differences(iface)
            if not diffs and owner_ok:
                break
            if diffs:
                iface.localNode.beginSettingsTransaction()
                for msg, group, key, value in diffs:
                    setattr(msg, key, value)
                    applied.add("%s.%s" % (group, key))
                for group in sorted({d[1] for d in diffs}):
                    iface.localNode.writeConfig(group)
                iface.localNode.commitSettingsTransaction()
            if not owner_ok:
                iface.localNode.setOwner(long_name=OWNER_LONG, short_name=OWNER_SHORT)
                applied.add("owner")
            time.sleep(2)
        finally:
            iface.close()
        time.sleep(12)
    else:
        iface = connect()
        try:
            diffs, owner_ok = differences(iface)
        finally:
            iface.close()
        left = ["%s.%s" % (d[1], d[2]) for d in diffs] + ([] if owner_ok else ["owner"])
        if left:
            sys.exit("meshtastic: these would not stick: " + ", ".join(left))
    print("meshtastic: applied " + ", ".join(sorted(applied)) if applied
          else "meshtastic: settings already in effect")


def heard(iface):
    me = iface.myInfo.my_node_num
    rows = []
    for n in (iface.nodes or {}).values():
        if n.get("num") == me:
            continue
        u = n.get("user", {})
        rows.append({"id": u.get("id", ""), "long": u.get("longName", "?"),
                     "short": u.get("shortName", ""), "hw": u.get("hwModel", ""),
                     "role": u.get("role", "CLIENT"), "snr": n.get("snr"),
                     "hops": n.get("hopsAway"), "last": n.get("lastHeard") or 0})
    rows.sort(key=lambda r: r["last"], reverse=True)
    os.makedirs(os.path.dirname(NAMES_CACHE), exist_ok=True)
    with open(NAMES_CACHE, "w", encoding="utf-8") as fh:
        fh.write("\n".join(r["short"] or r["long"] for r in rows if r["short"] or r["long"]) + "\n")
    return rows


def age(epoch):
    if not epoch:
        return "-"
    s = int(time.time() - epoch)
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if s >= n:
            return "%d%s ago" % (s // n, unit)
    return "%ds ago" % s


def nodes(iface):
    rows = heard(iface)
    if not rows:
        print("no nodes heard yet — node info goes out every few hours, or when a node boots")
        return
    print("%-20s %-5s %-10s %-12s %6s %4s  %s" % ("NAME", "SHORT", "ID", "HARDWARE", "SNR", "HOPS", "LAST HEARD"))
    for r in rows:
        snr = "" if r["snr"] is None else "%.1f" % r["snr"]
        hops = "" if r["hops"] is None else str(r["hops"])
        print("%-20s %-5s %-10s %-12s %6s %4s  %s" % (r["long"][:20], r["short"][:5], r["id"],
                                                      r["hw"][:12], snr, hops, age(r["last"])))


def resolve(iface, name):
    want = name.lower()
    for n in (iface.nodes or {}).values():
        u = n.get("user", {})
        if want in (u.get("id", "").lower(), u.get("longName", "").lower(), u.get("shortName", "").lower()):
            return u["id"], u.get("longName", u["id"])
    sys.exit("meshtastic: no heard node named '%s' (see: radio mesh nodes)" % name)


def info(iface):
    node = iface.localNode
    lora, dev = node.localConfig.lora, node.localConfig.device
    enum = lambda msg, key: msg.DESCRIPTOR.fields_by_name[key].enum_type.values_by_number[getattr(msg, key)].name
    me = (iface.getMyNodeInfo() or {}).get("user", {})
    print("network   Meshtastic")
    print("identity  %s (%s) %s" % (me.get("longName"), me.get("shortName"), me.get("id")))
    print("radio     %s %s, slot %d, hop limit %d, tx %s" % (
        enum(lora, "region"), enum(lora, "modem_preset"), lora.channel_num, lora.hop_limit,
        "on" if lora.tx_enabled else "off"))
    print("role      %s; node info every %dh; position never sent" % (
        enum(dev, "role"), dev.node_info_broadcast_secs // 3600))
    print("mqtt      %s" % ("on" if node.moduleConfig.mqtt.enabled else "off"))
    for ch in node.channels or []:
        if ch.role == 0:
            continue
        role = "primary" if ch.role == 1 else "secondary"
        print("channel   %d %s %s" % (ch.index, role, ch.settings.name or "(default LongFast)"))
    print("heard     %d nodes" % len(heard(iface)))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "apply":
        apply()
        return
    iface = connect()
    try:
        if cmd == "nodes":
            nodes(iface)
        elif cmd == "send" and args:
            iface.sendText(" ".join(args))
            time.sleep(2)  # let the queue drain before disconnecting
            print("sent to the primary channel")
        elif cmd == "dm" and len(args) >= 2:
            dest, label = resolve(iface, args[0])
            iface.sendText(" ".join(args[1:]), destinationId=dest, wantAck=True)
            time.sleep(2)
            print("sent to %s" % label)
        elif cmd == "join" and len(args) == 1:
            iface.localNode.setURL(args[0], addOnly=True)
            print("joined; channels now:")
            info(iface)
        elif cmd == "info":
            info(iface)
        else:
            sys.exit(__doc__)
    finally:
        iface.close()


if __name__ == "__main__":
    main()
MTOPS
    # Identity for both networks, read by radio and meshtastic_ops.py.
    write_file /etc/rx/mesh.conf 0644 <<MESHCONF
# Managed by rx/setup.sh — mesh identity, from the config at the top of it.
NODE_NAME=${NODE_NAME}
NODE_SHORT=${NODE_SHORT}
LORA_REGION=${LORA_REGION}
MESHCONF

    # radio starts and stops the daemons through rx-mesh; that one helper is
    # all the desktop user may run as root. It validates its own arguments.
    # Validated before installing: a malformed drop-in makes sudo refuse to
    # run at all.
    if ! $DRY_RUN; then
      local sudo_tmp; sudo_tmp=$(mktemp)
      printf '%s ALL=(root) NOPASSWD: /usr/local/sbin/rx-mesh\n' "$DESKTOP_USER" > "$sudo_tmp"
      if visudo -cqf "$sudo_tmp" 2>/dev/null; then
        install -m 0440 -o root -g root "$sudo_tmp" /etc/sudoers.d/50-rx-mesh
        log "sudo rule installed: $DESKTOP_USER may run rx-mesh"
        # Superseded: it allowed only `systemctl start meshtasticd`.
        rm -f /etc/sudoers.d/50-meshtasticd
      else
        warn "sudoers snippet failed validation; not installed"
      fi
      rm -f "$sudo_tmp"
    fi

    # `radio mesh` replaces the old `mesh` launcher. Remove it, if ours.
    if grep -qs 'Managed by rx/setup.sh' /usr/local/bin/mesh; then
      run rm -f /usr/local/bin/mesh
      log "removed the old mesh launcher (now: radio mesh)"
    fi

    # Offline map tiles for meshtastic-ui, in the SD-card layout its bundles
    # use: maps/<style>/z/x/y.png. They live under the portduino emulated
    # filesystem root, ~/.portduino/default, with /maps symlinked to the same
    # tree so the path resolves whether it is read through the emulated
    # filesystem or as an absolute one.
    local mapdir="$USER_HOME/.portduino/default/maps"
    if [[ -d $mapdir ]] && [[ -n $(find "$mapdir" -name '*.png' -print -quit 2>/dev/null) ]]; then
      log "map tiles already installed ($mapdir)"
    elif $DRY_RUN; then
      log "[dry-run] download and install meshtastic map tiles"
    else
      apt_install_opt unzip
      local mz; mz=$(mktemp /tmp/osm-tiles.XXXXXX.zip)
      if curl -fsSL --max-time 300 \
           "https://raw.githubusercontent.com/meshtastic/device-ui/master/maps/${MAP_STYLE}.zip" \
           -o "$mz" && unzip -qo "$mz" -d "$USER_HOME/.portduino/default/"; then
        chown -R "${DESKTOP_USER}:${USER_GROUP}" "$USER_HOME/.portduino"
        log "installed map tiles: $(find "$mapdir" -name '*.png' | wc -l | tr -d ' ') tiles"
      else
        warn "could not install map tiles"
      fi
      rm -f "$mz"
    fi
    if [[ -d $mapdir ]] && [[ ! -e /maps ]]; then
      run ln -sfn "$mapdir" /maps
    fi

    note "Mesh: 'radio meshtastic' or 'radio meshcore' picks the network (North Texas settings), and 'radio mesh nodes|send|dm|join|info|on|off' works on whichever is active, starting it if needed. Neither runs at boot. 'radio mesh' alone opens the dashboard."
    note "Map tiles cover zoom 1-6 worldwide. For detail around home, fetch a regional bundle from https://download.tiles.coalition.space/ and unzip it into ~/.portduino/default/ keeping the maps/<style>/z/x/y layout."
  fi

  # --------------------------------------------------------------------- sdr

  if want sdr; then
    section "SDR"
    require_akrex_repo
    apt_install rtl-sdr librtlsdr0 libpulse0 python3 python3-numpy python3-scipy

    # The DVB-T driver claims the dongle on plug-in and starves SDR software.
    write_file /etc/modprobe.d/blacklist-dvb-rtl.conf 0644 <<'BLACKLIST'
# Managed by rx/setup.sh — keep the DVB-T drivers off the RTL-SDR.
# Without this the kernel binds the dongle as a TV tuner and every SDR tool
# fails with usb_claim_interface error -6 (LIBUSB_ERROR_BUSY).
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
blacklist rtl2832_sdr
blacklist dvb_usb_v2
BLACKLIST
    log "blacklisted the DVB-T kernel drivers"

    # A blacklist only stops the module loading next boot; if it is already
    # bound to the dongle, the device stays claimed until it is unloaded.
    if ! $DRY_RUN; then
      local mod
      for mod in dvb_usb_rtl28xxu rtl2832_sdr rtl2832 rtl2830 dvb_usb_v2; do
        if lsmod 2>/dev/null | grep -q "^${mod} "; then
          modprobe -r "$mod" 2>/dev/null \
            && log "unloaded $mod (was holding the dongle)" \
            || warn "$mod is loaded and would not unload — reboot to release the SDR"
        fi
      done
    fi

    # Report what is actually there, rather than leaving a silent failure to
    # be discovered later when rxd will not start. The rails matter here: the RTL-SDR sits
    # behind the AIO's internal USB hub, so SDR alone is not enough.
    if ! $DRY_RUN; then
      if lsusb 2>/dev/null | grep -qiE 'RTL2832|RTL2838|Realtek.*DVB|0bda:2838'; then
        log "RTL-SDR present on USB"
        if command -v rtl_test >/dev/null 2>&1; then
          local out
          out=$(timeout 10 rtl_test -t </dev/null 2>&1 || true)
          if printf '%s' "$out" | grep -q 'Found 1 device' \
             && ! printf '%s' "$out" | grep -q 'Failed to open'; then
            log "rtl_test: device opens cleanly"
          elif printf '%s' "$out" | grep -q 'usb_claim_interface error -6'; then
            warn "RTL-SDR is enumerated but BUSY (usb_claim_interface -6): something already holds it."
            # Name the actual holder rather than leaving a guessing game. An
            # ADS-B decoder is the usual one: it is a service, so it restarts
            # itself and reclaims the dongle after every attempt to free it.
            local svc
            for svc in readsb dump1090-fa dump1090 dump1090-mutability adsbexchange-feed skyaware978; do
              if systemctl is-active --quiet "$svc" 2>/dev/null; then
                warn "  '$svc' is running and holds the SDR: sudo systemctl disable --now $svc"
                note "The '$svc' service holds the RTL-SDR and restarts itself, so disable and mask it: sudo systemctl disable --now $svc && sudo systemctl mask $svc. Some decoders are built into /usr/bin by a postinst rather than installed as packages, so 'apt purge' may not remove them."
              fi
            done
            warn "  otherwise:  pgrep -a rxd   |   sudo fuser -v /dev/bus/usb/*/*"
          elif [[ -n $out ]]; then
            warn "RTL-SDR enumerates but rtl_test cannot open it — check the plugdev group (needs a full re-login):"
            printf '%s\n' "$out" | sed 's/^/      /' >&2
          fi
        fi
      else
        warn "no RTL-SDR on USB. Check the power rails: 'pinctrl get ${RAIL_SDR}' and 'pinctrl get ${RAIL_USB}' should read hi, and the dongle sits behind the internal USB hub so both are needed."
        note "SDR not detected on USB. Turn the rails on with 'sudo uconsole-aio-rails on' (or 'sudo aiov2_ctl SDR on; sudo aiov2_ctl USB on'), then re-check with 'lsusb | grep -i rtl'."
      fi
    fi

    # rxd is the receiver: a headless Python daemon that demodulates one
    # channel from the RTL-SDR and plays it to PipeWire, at about a tenth of
    # SDR++Brown's CPU on a CM4. librtlsdr0 and libpulse0 are loaded through
    # ctypes, so it needs no build step and no -dev packages. 'radio' starts
    # and stops it as the rxd@PROFILE user service below; HTTP control and the
    # browser UI are on port 8073 (LAN-wide, per /etc/rx/rxd.env below) and
    # Hamlib NET rigctl on 127.0.0.1:4532.
    #
    # The copies of rxd, rxd-tui and the browser UI are generated from
    # rxd/rxd.py, rxd/rxd_tui.py and rxd/web/index.html by rxd/embed.sh, and
    # build.sh refuses to publish when any differs. Edit those, not these
    # heredocs.
    write_file /usr/local/bin/rxd 0755 <<'RXD'
#!/usr/bin/env python3
"""rxd: a small RTL-SDR receiver daemon, the receiver behind `radio`.

  rxd PROFILE                 receive with a radio profile (a name under
                              ~/.config/rx/radio/ or a path to its JSON)
  rxd PROFILE --audio stdout  raw s16le mono 48 kHz on stdout instead
  rxd PROFILE --iq FILE|-     read cu8 IQ from a file or stdin, not a dongle
  rxd PROFILE --iq synth      a synthetic signal: noise plus a test tone
                              1500 Hz above the dial, for testing anything
                              but the radio itself

It reads the same profile JSON as `radio`, opens the dongle by serial,
demodulates one channel (USB, LSB, AM, FM or WFM) and plays it to a
PipeWire/PulseAudio sink. Two control ports, both on 127.0.0.1 by default:

  4532  Hamlib NET rigctl (rig model 2), so JS8Call or `rigctl -m 2` can
        read and set the frequency and mode
  8073  HTTP JSON: GET /api/status, POST /api/tune {"freq": 7078000,
        "mode": "USB", "bandwidth": 2800, "gain_db": 3.7, "volume": 0.2}

A WSPR profile ("decoder": "wspr") also decodes WSPR with wsprd and reports
the spots to WSPRnet; GET /api/wspr lists them.

Frequencies on both ports are the dial, as JS8Call means it. A JS8 profile
whose VFO sits off its js8call_dial (7077900 vs 7078000, tuned by hand)
keeps that difference as a calibration, so the dial still reads 7078000.

SIGHUP re-reads the profile; SIGINT or SIGTERM stops.
"""
import argparse
import collections
import configparser
import ctypes
import ctypes.util
import json
import os
import queue
import re
import signal
import socket
import shutil
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# One BLAS thread. The filters are small matrix products, and OpenBLAS's
# default pool of one thread per core busy-waits between them: measured on
# the uConsole, a live run sat at 131% CPU with the pool and the DSP needed
# about 16% of one core without it. Set before numpy loads, or it is ignored.
for _var in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_var, "1")

import numpy as np  # noqa: E402
from scipy import signal as sps  # noqa: E402

STATE = os.path.expanduser("~/.config/rx/radio")
AUDIO_RATE = 48000
# A profile's "offset": "auto" (the default) upconverts below
# upconvert_below_hz, since the R820T tunes no lower than about 24 MHz and
# the Ham It Up is how HF gets in; "Ham-It-Up" always upconverts and "None"
# (or SDR++'s "Manual") never does. The Ham It Up's own UPCONVERT/BYPASS
# switch is physical: rxd can only report which way it should be.
OFFSET_MODES = ("auto", "Ham-It-Up", "None", "Manual")
UPCONVERTER_HZ = 125e6
UPCONVERT_BELOW_HZ = 30e6
# Profile sink descriptions -> PipeWire node names (None: default sink).
SINKS = {"SDR to JS8 (virtual cable)": "SDR_to_JS8", "Built-in Audio": None}
MODES = ("USB", "LSB", "AM", "FM", "WFM")
DECODERS = ("js8", "wspr", None)
DEFAULT_BW = {"USB": 2800.0, "LSB": 2800.0, "AM": 10000.0, "FM": 12500.0,
              "WFM": 150000.0}


def log(msg):
    print("rxd: " + msg, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ profile

def load_profile(spec):
    path = spec if os.sep in spec or spec.endswith(".json") else \
        os.path.join(STATE, spec + ".json")
    if not os.path.isfile(path):
        sys.exit("rxd: no profile at %s (save one with: radio show NAME > FILE)"
                 % path)
    with open(path, encoding="utf-8") as fh:
        p = json.load(fh)
    return p, path


class Settings:
    """What to receive. Shared between the control ports and the DSP thread."""

    def __init__(self, p, name=None):
        self.lock = threading.Lock()
        self.name = name
        self.apply_profile(p)

    def apply_profile(self, p):
        with self.lock:
            mode = p.get("demod", "USB")
            if mode not in MODES:
                raise ValueError("rxd does not demodulate %s" % mode)
            self.mode = mode
            ds = p.get("demod_settings", {})
            bw = float(ds.get("bandwidth", DEFAULT_BW[mode]))
            # SDR++'s 3000 Hz USB filter starts at 0; ours starts at 200 Hz.
            self.bandwidth = min(bw, 2800.0) if mode in ("USB", "LSB") else bw
            self.agc_attack = float(ds.get("agcAttack", 50.0))
            self.agc_decay = float(ds.get("agcDecay", 5.0))
            self.volume = float(p.get("volume", 0.5))
            # SDR++'s squelchEnabled/squelchLevel, carried in demod_settings.
            self.squelch = float(ds["squelchLevel"]) if ds.get("squelchEnabled") and \
                ds.get("squelchLevel") is not None else None
            carrier = float(p["frequency"])  # SDR++'s VFO: the carrier
            dial = float(p.get("js8call_dial", carrier))
            self.cal = dial - carrier
            self.dial = dial
            self.offset_mode = p.get("offset", "auto")
            if self.offset_mode not in OFFSET_MODES:
                raise ValueError("offset must be one of " + ", ".join(OFFSET_MODES))
            self.upconverter_hz = float(p.get("upconverter_hz", UPCONVERTER_HZ))
            self.upconvert_below = float(p.get("upconvert_below_hz", UPCONVERT_BELOW_HZ))
            rtl = p.get("rtl", {})
            self.serial = str(rtl.get("serial", ""))
            self.gain_index = rtl.get("gain")
            # A saved gain_db wins; otherwise the index (SDR++'s convention)
            # is looked up in the dongle's gain table once it is open.
            self.gain_db = float(rtl["gain_db"]) if rtl.get("gain_db") is not None else None
            self.ppm = int(rtl.get("ppm", 0))
            self.bias_t = bool(rtl.get("biasT", False))
            self.sink = SINKS.get(p.get("sink"), p.get("sink"))
            self.js8 = p.get("js8call_dial") is not None
            # What decodes this profile's audio: JS8Call (any profile with a
            # js8call_dial), rxd's own WSPR decoder, or nothing.
            self.decoder = p.get("decoder") or ("js8" if self.js8 else None)
            if self.decoder not in DECODERS:
                raise ValueError("decoder must be one of " + ", ".join(d for d in DECODERS if d))
            self.wspr_report = bool(p.get("wspr_report", True))
            self.version = getattr(self, "version", 0) + 1

    def snapshot(self):
        with self.lock:
            return dict(mode=self.mode, bandwidth=self.bandwidth, dial=self.dial,
                        cal=self.cal, upconverter=self.upconverter(),
                        offset_mode=self.offset_mode,
                        upconvert_below=self.upconvert_below,
                        agc_attack=self.agc_attack, agc_decay=self.agc_decay,
                        volume=self.volume, gain_db=self.gain_db, squelch=self.squelch,
                        wspr_report=self.wspr_report, version=self.version)

    def upconverter(self):
        """The offset in effect for the current dial (call with the lock held)."""
        if self.offset_mode == "Ham-It-Up":
            return self.upconverter_hz
        if self.offset_mode == "auto" and self.dial < self.upconvert_below:
            return self.upconverter_hz
        return 0.0

    def update(self, freq=None, mode=None, bandwidth=None, gain_db=None,
               volume=None, squelch=Ellipsis, wspr_report=None):
        with self.lock:
            if wspr_report is not None:
                if not isinstance(wspr_report, bool):
                    raise ValueError("wspr_report must be true or false")
                self.wspr_report = wspr_report
            if mode is not None:
                mode = mode.upper()
                if mode not in MODES:
                    raise ValueError("mode must be one of " + ", ".join(MODES))
                if mode != self.mode and bandwidth is None:
                    self.bandwidth = DEFAULT_BW[mode]
                self.mode = mode
            if freq is not None:
                freq = float(freq)
                if not 100e3 <= freq <= 1.7e9:
                    raise ValueError("frequency out of range")
                self.dial = freq
            if bandwidth is not None and float(bandwidth) > 0:
                self.bandwidth = float(bandwidth)
            if gain_db is not None:
                self.gain_db = float(gain_db)
            if volume is not None:
                volume = float(volume)
                if not 0 <= volume <= 4:
                    raise ValueError("volume must be between 0 and 4")
                self.volume = volume
            if squelch is not Ellipsis:  # None (JSON null) turns it off
                if squelch is not None:
                    squelch = float(squelch)
                    if not -150 <= squelch <= 0:
                        raise ValueError("squelch must be in dBFS, -150 to 0, or null")
                self.squelch = squelch
            self.version += 1


# ------------------------------------------------------------------ sources

class RtlSource:
    """An RTL-SDR dongle through librtlsdr (the library radio already uses)."""

    def __init__(self, serial):
        path = ctypes.util.find_library("rtlsdr")
        if not path:
            sys.exit("rxd: librtlsdr not found")
        lib = self.lib = ctypes.CDLL(path)
        lib.rtlsdr_get_device_usb_strings.argtypes = [
            ctypes.c_uint32, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
        lib.rtlsdr_open.argtypes = [ctypes.POINTER(ctypes.c_void_p), ctypes.c_uint32]
        for fn in ("set_tuner_gain_mode", "set_tuner_gain", "set_freq_correction",
                   "set_bias_tee", "set_direct_sampling", "set_agc_mode"):
            if hasattr(lib, "rtlsdr_" + fn):  # bias-T is rtl-sdr-blog's
                getattr(lib, "rtlsdr_" + fn).argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.rtlsdr_set_sample_rate.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        lib.rtlsdr_set_center_freq.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
        lib.rtlsdr_get_tuner_gains.argtypes = [ctypes.c_void_p,
                                               ctypes.POINTER(ctypes.c_int)]
        lib.rtlsdr_reset_buffer.argtypes = [ctypes.c_void_p]
        lib.rtlsdr_close.argtypes = [ctypes.c_void_p]
        lib.rtlsdr_read_sync.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                         ctypes.c_int, ctypes.POINTER(ctypes.c_int)]
        index = None
        for i in range(lib.rtlsdr_get_device_count()):
            bufs = [ctypes.create_string_buffer(256) for _ in range(3)]
            if lib.rtlsdr_get_device_usb_strings(i, *bufs) == 0 and \
                    (not serial or bufs[2].value.decode(errors="replace") == serial):
                index = i
                break
        if index is None:
            sys.exit("rxd: dongle SN %s is not plugged in" % serial)
        self.dev = ctypes.c_void_p()
        if lib.rtlsdr_open(ctypes.byref(self.dev), index) != 0:
            sys.exit("rxd: could not open dongle SN %s (is another rxd holding it? sudo fuser -v /dev/bus/usb/*/*)"
                     % serial)
        self.center = None
        self.rate = None
        self.lock = threading.Lock()

    def gains(self):
        n = self.lib.rtlsdr_get_tuner_gains(self.dev, None)
        arr = (ctypes.c_int * max(n, 0))()
        self.lib.rtlsdr_get_tuner_gains(self.dev, arr)
        return [g / 10.0 for g in arr]

    def configure(self, rate, ppm, bias_t):
        lib, dev = self.lib, self.dev
        lib.rtlsdr_set_direct_sampling(dev, 0)
        lib.rtlsdr_set_agc_mode(dev, 0)
        lib.rtlsdr_set_tuner_gain_mode(dev, 1)
        if ppm:
            lib.rtlsdr_set_freq_correction(dev, ppm)
        if hasattr(lib, "rtlsdr_set_bias_tee"):
            lib.rtlsdr_set_bias_tee(dev, int(bias_t))
        self.set_rate(rate)

    def set_rate(self, rate):
        with self.lock:
            if rate != self.rate:
                self.lib.rtlsdr_set_sample_rate(self.dev, int(rate))
                self.lib.rtlsdr_reset_buffer(self.dev)
                self.rate = rate

    def set_gain(self, db):
        self.lib.rtlsdr_set_tuner_gain(self.dev, int(round(db * 10)))

    def set_center(self, hz):
        with self.lock:
            self.lib.rtlsdr_set_center_freq(self.dev, int(hz))
            self.center = float(hz)

    def read(self, n):
        buf = (ctypes.c_uint8 * (2 * n))()
        got = ctypes.c_int()
        with self.lock:
            r = self.lib.rtlsdr_read_sync(self.dev, buf, 2 * n, ctypes.byref(got))
        if r != 0:
            raise IOError("rtlsdr_read_sync returned %d" % r)
        return cu8_to_complex(np.frombuffer(buf, np.uint8, got.value))

    def close(self):
        self.lib.rtlsdr_close(self.dev)


class FileSource:
    """cu8 IQ from a file or stdin. Retuning only moves the software mixer."""

    paced = False  # nothing is lost by waiting: block rather than drop

    def __init__(self, path, center=None):
        self.fh = sys.stdin.buffer if path == "-" else open(path, "rb")
        self.center = center
        self.rate = None
        self.fixed_center = center is not None

    def gains(self):
        return []

    def configure(self, rate, ppm, bias_t):
        self.rate = rate

    def set_rate(self, rate):
        self.rate = rate

    def set_gain(self, db):
        pass

    def set_center(self, hz):
        if not self.fixed_center:
            self.center = float(hz)

    def read(self, n):
        raw = self.fh.read(2 * n)
        if len(raw) < 2:
            raise EOFError
        return cu8_to_complex(np.frombuffer(raw[: len(raw) // 2 * 2], np.uint8))

    def close(self):
        if self.fh is not sys.stdin.buffer:
            self.fh.close()


class SynthSource:
    """Noise plus a carrier at a fixed RF, paced in real time."""

    def __init__(self, tone_rf, snr_db=20.0):
        self.tone_rf = tone_rf
        self.amp = 10 ** (snr_db / 20) * 0.01
        self.center = None
        self.rate = None
        self.phase = 0.0
        self.t_next = None
        self.rng = np.random.default_rng(8)

    def gains(self):
        return [0.0, 3.7, 16.6, 37.2]

    def configure(self, rate, ppm, bias_t):
        self.rate = rate

    def set_rate(self, rate):
        self.rate = rate

    def set_gain(self, db):
        pass

    def set_center(self, hz):
        self.center = float(hz)

    def read(self, n):
        now = time.monotonic()
        if self.t_next is None:
            self.t_next = now
        if self.t_next > now:
            time.sleep(self.t_next - now)
        self.t_next += n / self.rate
        w = 2 * np.pi * (self.tone_rf - self.center) / self.rate
        ph = self.phase + w * np.arange(n)
        self.phase = (self.phase + w * n) % (2 * np.pi)
        noise = (self.rng.standard_normal(n) + 1j * self.rng.standard_normal(n))
        return (self.amp * np.exp(1j * ph) + 0.01 * noise).astype(np.complex64)

    def close(self):
        pass


# Every (I, Q) byte pair as one little-endian uint16 -> its complex sample.
_CU8 = (np.arange(256, dtype=np.float32) - 127.5) / 127.5
CU8_LUT = (_CU8[np.arange(65536) & 0xFF] + 1j * _CU8[np.arange(65536) >> 8]).astype(np.complex64)


def cu8_to_complex(b):
    b = b[: len(b) // 2 * 2]
    return CU8_LUT[np.ascontiguousarray(b).view("<u2")]


# --------------------------------------------------------------------- sinks

class PulseSink:
    """Playback through libpulse-simple (PipeWire's Pulse server)."""

    class Spec(ctypes.Structure):
        _fields_ = [("format", ctypes.c_int), ("rate", ctypes.c_uint32),
                    ("channels", ctypes.c_uint8)]

    class Attr(ctypes.Structure):
        _fields_ = [(n, ctypes.c_uint32) for n in
                    ("maxlength", "tlength", "prebuf", "minreq", "fragsize")]

    def __init__(self, device):
        path = ctypes.util.find_library("pulse-simple")
        if not path:
            sys.exit("rxd: libpulse-simple not found")
        lib = self.lib = ctypes.CDLL(path)
        lib.pa_simple_new.restype = ctypes.c_void_p
        lib.pa_simple_new.argtypes = [
            ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p,
            ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_int)]
        lib.pa_simple_write.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                        ctypes.c_size_t, ctypes.POINTER(ctypes.c_int)]
        lib.pa_simple_free.argtypes = [ctypes.c_void_p]
        spec = self.Spec(3, AUDIO_RATE, 1)  # PA_SAMPLE_S16LE, mono
        # About 300 ms of buffer: enough to ride out a slow block.
        tl = AUDIO_RATE * 2 * 3 // 10
        attr = self.Attr(0xFFFFFFFF, tl, 0xFFFFFFFF, 0xFFFFFFFF, 0xFFFFFFFF)
        err = ctypes.c_int()
        self.s = lib.pa_simple_new(None, b"rxd", 1, device.encode() if device else None,
                                   b"receiver", ctypes.byref(spec), None,
                                   ctypes.byref(attr), ctypes.byref(err))
        if not self.s:
            sys.exit("rxd: could not open audio sink %s (pulse error %d)"
                     % (device or "default", err.value))

    def write(self, pcm):
        err = ctypes.c_int()
        b = pcm.tobytes()
        if self.lib.pa_simple_write(self.s, b, len(b), ctypes.byref(err)) < 0:
            raise IOError("pulse write failed (%d)" % err.value)

    def close(self):
        self.lib.pa_simple_free(self.s)


class StdoutSink:
    def write(self, pcm):
        sys.stdout.buffer.write(pcm.tobytes())
        sys.stdout.buffer.flush()

    def close(self):
        pass


class NullSink:
    def write(self, pcm):
        pass

    def close(self):
        pass


# ----------------------------------------------------------------------- DSP

class FirDecimator:
    """FIR filter keeping only every D-th output, with history across blocks."""

    def __init__(self, taps, decim):
        self.taps = np.asarray(taps)[::-1].copy()
        self.decim = decim
        self.hist = np.zeros(len(taps) - 1, np.complex64 if np.iscomplexobj(taps)
                             else np.float32)
        self.phase = 0  # index into the next block of the next output
        self.count = 0  # samples taken in before this block

    def set_taps(self, taps):
        """New taps of the same length, keeping history and phase."""
        self.taps = np.asarray(taps)[::-1].copy()

    def __call__(self, x):
        n = len(self.taps)
        if np.iscomplexobj(x) and not np.iscomplexobj(self.hist):
            self.hist = self.hist.astype(np.complex64)
        xx = np.concatenate([self.hist, x])
        win = np.lib.stride_tricks.sliding_window_view(xx, n)
        out = win[self.phase::self.decim] @ self.taps
        consumed = len(x) - self.phase
        self.phase = (-consumed) % self.decim
        self.hist = xx[len(xx) - (n - 1):]
        self.count += len(x)
        return out.astype(np.complex64 if np.iscomplexobj(out) else np.float32)


class Agc:
    """Envelope-following gain, computed per 5 ms and interpolated between."""

    STEP = 240

    def __init__(self, attack, decay, rate=AUDIO_RATE, target=0.5):
        # SDR++'s attack and decay are per-second rates: a = rate / fs.
        self.a = 1 - (1 - min(attack / rate, 1.0)) ** self.STEP
        self.d = 1 - (1 - min(decay / rate, 1.0)) ** self.STEP
        self.env = 1e-4
        self.gain = target / self.env
        self.target = target

    def __call__(self, x):
        n = len(x)
        steps = max(n // self.STEP, 1)
        pk = np.abs(x[: steps * self.STEP]).reshape(steps, -1).max(axis=1) \
            if n >= self.STEP else np.array([np.abs(x).max() if n else 0.0])
        gains = np.empty(steps + 1)
        gains[0] = self.gain
        for i, e in enumerate(pk):
            k = self.a if e > self.env else self.d
            self.env += (e - self.env) * k
            self.env = max(self.env, e if e > 4 * self.env else 0.0, 1e-6)
            gains[i + 1] = self.target / self.env
        self.gain = gains[-1]
        g = np.interp(np.arange(n), np.linspace(0, n, steps + 1), gains)
        return x * g.astype(np.float32)


class Chain:
    """Shift and decimate -> channel filter -> demodulator -> 48 kHz audio.

    The frequency shift is folded into the first filter: its taps are the
    low-pass prototype moved up to the signal, and the output is turned back
    down at the decimated rate. Mixing every input sample first costs a
    complex exponential per sample, which at WFM's 1.2 MS/s alone was more
    than the CM4 has.
    """

    def __init__(self, mode, bandwidth, attack, decay):
        self.mode = mode
        self.bandwidth = bandwidth
        if mode == "WFM":
            self.rate, self.if_rate = 1200000, 240000
            self.offset = 250000.0
            cutoff = min(bandwidth / 2 + 15000, 100000)
        else:
            self.rate, self.if_rate = 240000, AUDIO_RATE
            self.offset = 50000.0
            cutoff = 20000.0 if mode in ("USB", "LSB") else min(bandwidth / 2 + 2000, 20000)
        d1 = self.rate // self.if_rate
        self.proto1 = sps.firwin(16 * d1 + 1, cutoff, fs=self.rate)
        self.stage1 = FirDecimator(self.proto1.astype(np.complex64), d1)
        self.shift = None  # the offset stage1's taps are built for
        fs = self.if_rate
        if mode == "WFM":
            # stage1 already cuts at 90 kHz; a second filter adds nothing.
            self.chan = None
        elif mode in ("USB", "LSB"):
            lo, hi = 200.0, 200.0 + bandwidth
            half = (hi - lo) / 2
            proto = sps.firwin(255, half, fs=fs)
            fc = (lo + hi) / 2 * (1 if mode == "USB" else -1)
            taps = proto * np.exp(2j * np.pi * fc * np.arange(len(proto)) / fs)
            self.chan = FirDecimator(taps.astype(np.complex64), 1)
        else:
            self.chan = FirDecimator(sps.firwin(127, min(bandwidth / 2, fs / 2 * 0.9),
                                                fs=fs), 1)
        self.agc = Agc(attack, decay) if mode in ("USB", "LSB", "AM") else None
        self.prev = np.complex64(1)
        self.dc = 0.0
        if mode == "WFM":
            tau = 75e-6
            a = np.exp(-1 / (fs * tau))
            self.deemph = ([1 - a], [1, -a])
            self.deemph_zi = np.zeros(1)
            self.stage2 = FirDecimator(sps.firwin(63, 15000, fs=fs), fs // AUDIO_RATE)
        self.level_db = -120.0

    def shift_decimate(self, x, offset):
        w = 2 * np.pi * offset / self.rate
        if offset != self.shift:
            n = np.arange(len(self.proto1))
            self.stage1.set_taps((self.proto1 * np.exp(1j * w * n)).astype(np.complex64))
            self.shift = offset
        first = self.stage1.count + self.stage1.phase
        y = self.stage1(x)
        m = first + self.stage1.decim * np.arange(len(y), dtype=np.int64)
        return y * np.exp(-1j * ((w * m) % (2 * np.pi))).astype(np.complex64)

    def fm(self, y):
        z = np.concatenate([[self.prev], y])
        self.prev = y[-1] if len(y) else self.prev
        return np.angle(z[1:] * np.conj(z[:-1])).astype(np.float32)

    def __call__(self, iq, offset):
        y = self.shift_decimate(iq, offset)
        if self.chan is not None:
            y = self.chan(y)
        if len(y):
            p = float(np.mean(np.abs(y) ** 2))
            self.level_db = float(10 * np.log10(p + 1e-12))
        if self.mode in ("USB", "LSB"):
            audio = self.agc(y.real.astype(np.float32))
        elif self.mode == "AM":
            env = np.abs(y).astype(np.float32)
            self.dc += (float(env.mean()) - self.dc) * 0.1 if len(env) else 0
            audio = self.agc(env - self.dc)
        elif self.mode == "FM":
            audio = self.fm(y) * (self.if_rate / (2 * np.pi * 5000.0))
        else:  # WFM
            d = self.fm(y) * (self.if_rate / (2 * np.pi * 75000.0))
            d, self.deemph_zi = sps.lfilter(*self.deemph, d, zi=self.deemph_zi)
            audio = self.stage2(d.astype(np.float32))
        return audio.astype(np.float32)


# -------------------------------------------------------------------- engine

class Receiver:
    """Reader thread -> queue -> DSP thread -> sink."""

    MIN_OFF, MAX_OFF = 20000.0, 100000.0  # keep clear of the DC spike

    def __init__(self, settings, source, sink):
        self.s = settings
        self.src = source
        self.sink = sink
        self.q = queue.Queue(maxsize=8)
        self.stop = threading.Event()
        self.dropped = 0
        self.blocks = 0
        self.chain = None
        self.version = None
        self.error = None
        self.cpu = 0.0
        self.offset = 0.0
        self.spectrum = None
        self.spectrum_at = 0.0
        self.squelch_open = True
        self.listeners = []          # (rate, queue) per streaming client
        self.listen_lock = threading.Lock()
        self.resamplers = {}         # rate -> FirDecimator from 48 kHz
        self.wspr = None             # a WsprDecoder, for a WSPR profile

    def gain_db_for(self, index):
        g = self.src.gains()
        if not g:
            return 0.0
        return g[max(0, min(int(index), len(g) - 1))] if index is not None else g[len(g) // 2]

    def start(self):
        snap = self.s.snapshot()
        self.build(snap)
        self.src.configure(self.chain.rate, self.s.ppm, self.s.bias_t)
        with self.s.lock:
            if self.s.gain_db is None:
                self.s.gain_db = self.gain_db_for(self.s.gain_index)
        self.src.set_gain(self.s.gain_db)
        self.retune(self.s.snapshot(), force=True)
        self.version = self.s.snapshot()["version"]
        threading.Thread(target=self.reader, name="reader", daemon=True).start()
        threading.Thread(target=self.dsp, name="dsp", daemon=True).start()

    def build(self, snap):
        self.chain = Chain(snap["mode"], snap["bandwidth"], snap["agc_attack"],
                           snap["agc_decay"])

    def rf(self, snap):
        return snap["dial"] - snap["cal"] + snap["upconverter"]

    def retune(self, snap, force=False):
        rf = self.rf(snap)
        off = rf - (self.src.center or 0.0)
        lo = self.MIN_OFF if self.chain.mode != "WFM" else 150000.0
        hi = self.MAX_OFF if self.chain.mode != "WFM" else 400000.0
        if force or self.src.center is None or not lo <= abs(off) <= hi:
            self.src.set_center(rf - self.chain.offset)
        self.offset = rf - self.src.center

    def block_len(self):
        return int(self.chain.rate // 10) // 256 * 256  # ~100 ms, 512-byte multiple

    def reader(self):
        while not self.stop.is_set():
            try:
                x = self.src.read(self.block_len())
            except EOFError:
                self.q.put(None)
                return
            except Exception as e:  # dongle unplugged and the like
                self.error = str(e)
                log("read failed: %s" % e)
                self.q.put(None)
                return
            if not getattr(self.src, "paced", True):
                self.q.put(x)
                continue
            try:
                self.q.put_nowait(x)
            except queue.Full:
                self.dropped += 1

    def dsp(self):
        while not self.stop.is_set():
            x = self.q.get()
            if x is None:
                self.stop.set()
                return
            snap = self.s.snapshot()
            if snap["version"] != self.version:
                rebuild = (snap["mode"] != self.chain.mode or
                           snap["bandwidth"] != self.chain.bandwidth)
                if rebuild:
                    self.build(snap)
                    self.src.set_rate(self.chain.rate)
                    while not self.q.empty():  # blocks read at the old rate
                        try:
                            self.q.get_nowait()
                        except queue.Empty:
                            break
                if snap["gain_db"] is None:  # a reloaded profile: index -> dB
                    with self.s.lock:
                        self.s.gain_db = self.gain_db_for(self.s.gain_index)
                    snap = self.s.snapshot()
                self.src.set_gain(snap["gain_db"])
                self.retune(snap, force=rebuild)
                self.version = snap["version"]
                if rebuild:
                    continue  # the block in hand was at the old rate
            t0 = time.thread_time()
            audio = self.chain(x, self.offset)
            if self.wspr is not None:  # before squelch and volume
                self.wspr.push(audio, snap["dial"])
            audio = self.gate(audio, snap["squelch"])
            pcm = np.clip(audio * snap["volume"] * 32767, -32768, 32767).astype("<i2")
            self.sink.write(pcm)
            if self.listeners:
                self.stream(audio)
            dt = time.thread_time() - t0
            self.cpu += (dt / (len(x) / self.chain.rate) - self.cpu) * 0.05
            self.blocks += 1
            now = time.monotonic()
            if now - self.spectrum_at >= self.SPECTRUM_EVERY:
                self.spectrum_at = now
                self.spectrum = self.make_spectrum(x, snap)

    SPECTRUM_EVERY = 0.2   # seconds: about 5 a second for the clients
    SPECTRUM_BINS = 512

    def make_spectrum(self, x, snap):
        """The whole captured band, averaged over a few FFTs, on the dial's scale."""
        n = 2 * self.SPECTRUM_BINS
        segs = min(len(x) // n, 4)
        if not segs:
            return self.spectrum
        w = np.hanning(n).astype(np.float32)
        p = (np.abs(np.fft.fft(x[: segs * n].reshape(segs, n) * w, axis=1)) ** 2).mean(axis=0)
        p = np.fft.fftshift(p) / (n * float(np.sum(w ** 2)) / n)
        p = p.reshape(self.SPECTRUM_BINS, -1).mean(axis=1)
        db = 10 * np.log10(p + 1e-12)
        rate = self.chain.rate
        # RF -> dial scale: take off the upconverter, put back the calibration.
        to_dial = -snap["upconverter"] + snap["cal"]
        center = self.src.center + to_dial
        dial, bw, mode = snap["dial"], snap["bandwidth"], snap["mode"]
        if mode == "USB":
            band = [dial + 200, dial + 200 + bw]
        elif mode == "LSB":
            band = [dial - 200 - bw, dial - 200]
        else:
            band = [dial - bw / 2, dial + bw / 2]
        return {"bins": [round(float(v), 1) for v in db], "start_hz": center - rate / 2,
                "stop_hz": center + rate / 2, "dial_hz": dial, "passband": band,
                "seq": (self.spectrum or {}).get("seq", 0) + 1}

    def gate(self, audio, level):
        """Squelch: silence below level dBFS; opens at it, closes 3 dB under."""
        if level is None:
            self.squelch_open = True
            return audio
        lv = self.chain.level_db
        # bool(): lv is numpy's, and a numpy bool_ in status breaks json.dumps.
        self.squelch_open = bool(lv >= (level - 3 if self.squelch_open else level))
        return audio if self.squelch_open else np.zeros_like(audio)

    # ------------------------------------------------ audio to the clients

    STREAM_RATES = (12000, 24000, 48000)
    MAX_LISTENERS = 4

    def listen(self, rate):
        """A queue of s16le chunks at rate, or None if too many are listening."""
        q = queue.Queue(maxsize=30)  # about 3 s; a slow client loses chunks, never the DSP
        with self.listen_lock:
            if len(self.listeners) >= self.MAX_LISTENERS:
                return None
            self.listeners.append((rate, q))
        return q

    def unlisten(self, q):
        with self.listen_lock:
            self.listeners = [(r, x) for r, x in self.listeners if x is not q]

    def stream(self, audio):
        # Before the uConsole's own volume, so muting its speaker doesn't
        # silence the phone; the client has its own volume.
        with self.listen_lock:
            listeners = list(self.listeners)
        chunks = {}
        for rate, q in listeners:
            if rate not in chunks:
                d = AUDIO_RATE // rate
                if d > 1:
                    if rate not in self.resamplers:
                        self.resamplers[rate] = FirDecimator(
                            sps.firwin(16 * d + 1, rate * 0.45, fs=AUDIO_RATE), d)
                    a = self.resamplers[rate](audio)
                else:
                    a = audio
                chunks[rate] = np.clip(a * 0.8 * 32767, -32768, 32767).astype("<i2").tobytes()
            try:
                q.put_nowait(chunks[rate])
            except queue.Full:
                pass

    def status(self):
        snap = self.s.snapshot()
        return {"profile": self.s.name, "freq": snap["dial"],
                "vfo_hz": snap["dial"] - snap["cal"], "cal_hz": snap["cal"],
                "mode": snap["mode"], "bandwidth": snap["bandwidth"],
                "gain_db": snap["gain_db"], "volume": snap["volume"],
                "squelch": snap["squelch"], "squelch_open": self.squelch_open,
                "offset_mode": snap["offset_mode"], "upconverter_hz": snap["upconverter"],
                "upconvert_below_hz": snap["upconvert_below"],
                "level_dbfs": round(self.chain.level_db, 1) if self.chain else None,
                "tuner_hz": self.src.center, "offset_hz": self.offset,
                "sample_rate": self.chain.rate if self.chain else None,
                "dsp_cpu": round(self.cpu, 3), "blocks": self.blocks,
                "dropped": self.dropped, "error": self.error,
                "running": not self.stop.is_set(), "gains": self.src.gains(),
                "js8": self.s.js8, "js8_call": js8_mycall() if self.s.js8 else None,
                "decoder": self.s.decoder,
                "wspr": self.wspr.status() if self.wspr is not None else None,
                "clock": clock_status(),
                "listeners": len(self.listeners)}


# ----------------------------------------------------------- Hamlib rigctl

# Hamlib mode bits (rig.h): AM 0x1, USB 0x4, LSB 0x8, FM 0x20, WFM 0x40.
MODE_BITS = 0x1 | 0x4 | 0x8 | 0x20 | 0x40

DUMP_STATE = "\n".join([
    "1", "2", "0",
    # rx range: start end modes low_power high_power vfo ant
    "100000.000000 1700000000.000000 0x%x -1 -1 0x1 0x1" % MODE_BITS,
    "0 0 0 0 0 0 0",
    "0 0 0 0 0 0 0",          # no tx ranges: receive only
    "0x%x 1" % MODE_BITS,     # tuning step 1 Hz
    "0 0",
    "0xc 2800", "0xc 2400", "0xc 3000", "0x1 10000", "0x20 12500",
    "0x40 150000", "0 0",
    "0", "0", "0", "0",       # max rit, xit, if shift, announces
    "",                       # preamps
    "",                       # attenuators
    "0x0", "0x0",             # has get/set func
    "0x40000000", "0x0",      # get level: STRENGTH; set level: none
    "0x0", "0x0",             # get/set parm
    "vfo_ops=0x0", "ptt_type=0x0", "targetable_vfo=0x0",
    "has_set_vfo=0", "has_get_vfo=1", "has_set_freq=1", "has_get_freq=1",
    "has_set_conf=0", "has_get_conf=0", "has_power2mW=0", "has_mW2power=0",
    "timeout=0", "rig_model=2", "rigctld_version=rxd 0.1",
    "done", ""])


def rigctl_reply(cmd, rx):
    """One rigctl command line -> the reply text, or None to hang up."""
    parts = cmd.strip().split()
    if not parts:
        return ""
    head, args = parts[0], parts[1:]
    ok, nimpl, einval = "RPRT 0\n", "RPRT -11\n", "RPRT -1\n"
    s = rx.s
    if head in ("q", "Q", "\\quit"):
        return None
    if head in ("\\chk_vfo", "chk_vfo"):
        return "0\n"
    if head in ("\\dump_state", "dump_state"):
        return DUMP_STATE
    if head in ("f", "\\get_freq"):
        return "%d\n" % round(s.snapshot()["dial"])
    if head in ("F", "\\set_freq"):
        try:
            s.update(freq=float(args[0]))
        except (IndexError, ValueError):
            return einval
        return ok
    if head in ("m", "\\get_mode"):
        snap = s.snapshot()
        return "%s\n%d\n" % (snap["mode"], snap["bandwidth"])
    if head in ("M", "\\set_mode"):
        try:
            bw = float(args[1]) if len(args) > 1 and float(args[1]) > 0 else None
            # JS8Call asks for PKTUSB; data modes are plain SSB here.
            s.update(mode=args[0].upper().replace("PKT", ""), bandwidth=bw)
        except (IndexError, ValueError):
            return einval
        return ok
    if head in ("v", "\\get_vfo"):
        return "VFOA\n"
    if head in ("V", "\\set_vfo"):
        return ok
    if head in ("t", "\\get_ptt"):
        return "0\n"
    if head in ("T", "\\set_ptt"):
        # Receive only. Accept "off" so a client releasing PTT is not an error.
        return ok if args and args[0] == "0" else nimpl
    if head in ("s", "\\get_split_vfo"):
        return "0\nVFOA\n"
    if head in ("S", "\\set_split_vfo"):
        return ok if args and args[0] == "0" else nimpl
    if head == "\\get_powerstat":
        return "1\n"
    if head in ("l", "\\get_level"):
        if args and args[0] == "STRENGTH":
            # dB relative to S9 (-73 dBm). Uncalibrated: dBFS + 73 is only a guess.
            return "%d\n" % round(rx.chain.level_db + 73)
        return nimpl
    return nimpl


class RigctlHandler(socketserver.StreamRequestHandler):
    def handle(self):
        rx = self.server.rx
        for raw in self.rfile:
            line = raw.decode(errors="replace")
            # Several commands may share a line ("f\nm\n" arrives either way).
            reply = rigctl_reply(line, rx)
            if reply is None:
                return
            self.wfile.write(reply.encode())


class RigctlServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


# ---------------------------------------------------------------------- HTTP

# ------------------------------------------------------- profiles via radio

RADIO = os.environ.get("RXD_RADIO") or shutil.which("radio") or "/usr/local/bin/radio"
_profiles = {"at": 0.0, "doc": None}


def list_profiles():
    """radio's profiles and the active one ({"active", "profiles"}), cached briefly."""
    if _profiles["doc"] is not None and time.monotonic() - _profiles["at"] < 5:
        return _profiles["doc"]
    out = subprocess.run([RADIO, "--json"], capture_output=True, text=True, timeout=15)
    if out.returncode != 0:
        raise OSError((out.stderr or out.stdout).strip() or "radio --json failed")
    _profiles.update(at=time.monotonic(), doc=json.loads(out.stdout))
    return _profiles["doc"]


def spawn_switch(name):
    """Run `radio NAME` outside this unit: it stops this very rxd to start the next.

    systemd-run --scope puts radio (and any JS8Call it starts) in a scope of
    its own, so neither dies with rxd@OLD when radio stops it.
    """
    env = dict(os.environ)
    env.setdefault("DISPLAY", ":0")  # radio drives JS8Call's window through i3
    argv = [RADIO, "--no-focus", name]
    if shutil.which("systemd-run"):
        argv = ["systemd-run", "--user", "--scope", "--collect", "--quiet",
                "--unit=radio-switch-%d" % int(time.time() * 1000)] + argv
    subprocess.Popen(argv, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    _profiles["doc"] = None


# ------------------------------------------------------------------ clock

_clock = {"at": 0.0, "doc": None}


def parse_tracking(text):
    """chronyc -n tracking -> {"synced", "source", "offset_s"}.

    JS8's 15 s slots tolerate about 2 s of error and fail silently past it,
    so "synced" means chrony is locked (leap status Normal) and within 1 s.
    """
    def field(name):
        m = re.search(r"^%s\s*:\s*(.*)$" % re.escape(name), text, re.M)
        return m.group(1).strip() if m else None
    ref, leap, sys_t = field("Reference ID"), field("Leap status"), field("System time")
    offset = None
    if sys_t:
        m = re.match(r"([0-9.]+) seconds (fast|slow)", sys_t)
        if m:
            offset = float(m.group(1)) * (1 if m.group(2) == "fast" else -1)
    name = re.search(r"\((.*)\)", ref or "")
    name = name.group(1) if name else None
    if name in ("PPS", "NMEA", "GPS", "GPS1", "SHM0", "SOCK"):
        source = "GPS"
    elif name and name not in ("", "0.0.0.0"):
        source = "network"
    else:
        source = None
    synced = leap == "Normal" and offset is not None and abs(offset) < 1.0
    return {"synced": synced, "source": source if synced or source else None,
            "offset_s": offset}


def clock_status():
    """The system clock as JS8 sees it; synced None when chrony can't say."""
    if _clock["doc"] is not None and time.monotonic() - _clock["at"] < 10:
        return _clock["doc"]
    try:
        out = subprocess.run(["chronyc", "-n", "tracking"], capture_output=True,
                             text=True, timeout=5)
        doc = parse_tracking(out.stdout) if out.returncode == 0 else \
            {"synced": False, "source": None, "offset_s": None}
    except (OSError, subprocess.SubprocessError):
        doc = {"synced": None, "source": None, "offset_s": None}
    _clock.update(at=time.monotonic(), doc=doc)
    return doc


# ----------------------------------------------------------- JS8Call's log

JS8_LOG = os.path.expanduser(os.environ.get("RXD_JS8_LOG",
                                            "~/.local/share/JS8Call/DIRECTED.TXT"))
JS8_INI = os.path.expanduser("~/.config/JS8Call.ini")


def js8_mycall():
    cp = configparser.ConfigParser(interpolation=None, strict=False, delimiters=("=",),
                                   comment_prefixes=())
    cp.optionxform = str
    try:
        cp.read(JS8_INI, encoding="utf-8")
    except (OSError, configparser.Error):
        return None
    for sec in ("Configuration", "Common"):
        if cp.has_option(sec, "MyCall"):
            return cp.get(sec, "MyCall").strip() or None
    return None


# A callsign: a 1-3 character prefix, a digit, a 1-4 letter suffix, and an
# optional /P-style part. Not "INFO", "HELLO" or a group like "@HB".
CALLSIGN = re.compile(r"^(?:[A-Z0-9]{1,4}/)?[A-Z0-9]{1,3}[0-9][A-Z]{1,4}(?:/[A-Z0-9]{1,4})?$")


class Js8Feed:
    """New lines of DIRECTED.TXT, parsed and numbered, read as they're asked for."""

    KEEP = 500

    def __init__(self, path=None):
        self.path = path or JS8_LOG
        self.lock = threading.Lock()
        self.lines = collections.deque(maxlen=self.KEEP)
        self.seq = 0
        self.pos = None
        self.inode = None
        self.partial = b""

    @staticmethod
    def parse(raw):
        f = raw.rstrip("\n").split("\t")
        if len(f) < 5:
            return None
        text = f[4].replace("\u2662", "").strip()  # JS8Call's end-of-message diamond
        frm, _, body = text.partition(":")
        words = body.split()
        to = words[0] if words and CALLSIGN.match(words[0]) else None
        try:
            freq = float(f[1]) * 1e6 if float(f[1]) < 1000 else float(f[1])
            off, snr = int(f[2]), int(f[3])
        except ValueError:
            return None
        return {"time": f[0], "freq": freq, "offset": off, "snr": snr,
                "from": frm.strip() or None, "to": to, "text": text}

    def refresh(self):
        try:
            st = os.stat(self.path)
        except OSError:
            return
        if self.inode != st.st_ino or (self.pos or 0) > st.st_size:
            # First read, or logrotate moved it: start over, from the last 64 KB.
            self.inode, self.partial = st.st_ino, b""
            self.pos = max(st.st_size - 65536, 0)
            skip_first = self.pos > 0
        else:
            skip_first = False
        if st.st_size == self.pos:
            return
        with open(self.path, "rb") as fh:
            fh.seek(self.pos)
            data = self.partial + fh.read()
            self.pos = fh.tell()
        rows = data.split(b"\n")
        self.partial = rows.pop()
        if skip_first and rows:
            rows.pop(0)
        for r in rows:
            line = self.parse(r.decode("utf-8", "replace"))
            if line:
                self.seq += 1
                line["seq"] = self.seq
                self.lines.append(line)

    def since(self, after):
        with self.lock:
            self.refresh()
            if after <= 0:
                out = list(self.lines)[-200:]
            else:
                out = [x for x in self.lines if x["seq"] > after]
            return {"seq": self.seq, "lines": out}


# --------------------------------------------------------------------- WSPR

# rxd decodes WSPR itself rather than through WSJT-X: it records each
# two-minute slot from its own audio, before the volume and squelch, and runs
# wsprd (WSJT-X's command-line decoder, from the wsjtx package) on it. Spots
# go to the feed at /api/wspr and, when reporting is on, to WSPRnet.
WSPRD = os.environ.get("RXD_WSPRD") or shutil.which("wsprd") or "/usr/bin/wsprd"
WSPR_DIR = os.path.expanduser(os.environ.get("RXD_WSPR_DIR", "~/.local/share/rxd/wspr"))
# WSJT-X's own upload endpoint (Network/wsprnet.cpp): one form POST per spot.
WSPRNET_URL = os.environ.get("RXD_WSPRNET", "http://wsprnet.org/post/")
RXD_VERSION = "rxd-0.2"
GRID = re.compile(r"^[A-Ra-r]{2}[0-9]{2}(?:[A-Xa-x]{2})?$")


def grid_latlon(grid):
    """A Maidenhead locator's centre as (lat, lon), or None."""
    if not grid or not GRID.match(grid):
        return None
    g = grid.upper()
    lon = (ord(g[0]) - 65) * 20 - 180 + int(g[2]) * 2
    lat = (ord(g[1]) - 65) * 10 - 90 + int(g[3])
    if len(g) >= 6:
        lon += (ord(g[4]) - 65) * (2 / 24) + 1 / 24
        lat += (ord(g[5]) - 65) * (1 / 24) + 1 / 48
    else:
        lon, lat = lon + 1, lat + 0.5
    return lat, lon


def grid_km(a, b):
    pa, pb = grid_latlon(a), grid_latlon(b)
    if not pa or not pb:
        return None
    la1, lo1, la2, lo2 = map(np.radians, (pa[0], pa[1], pb[0], pb[1]))
    h = np.sin((la2 - la1) / 2) ** 2 + np.cos(la1) * np.cos(la2) * np.sin((lo2 - lo1) / 2) ** 2
    return int(round(float(2 * 6371 * np.arcsin(np.sqrt(h)))))


def station_id():
    """(call, grid) to report as: $RXD_CALL/$RXD_GRID, else JS8Call's MyCall/MyGrid."""
    call = os.environ.get("RXD_CALL") or js8_mycall()
    grid = os.environ.get("RXD_GRID")
    if not grid:
        cp = configparser.ConfigParser(interpolation=None, strict=False, delimiters=("=",),
                                       comment_prefixes=())
        cp.optionxform = str
        try:
            cp.read(JS8_INI, encoding="utf-8")
        except (OSError, configparser.Error):
            pass
        for sec in ("Configuration", "Common"):
            if cp.has_option(sec, "MyGrid"):
                grid = cp.get(sec, "MyGrid").strip()
                break
    call = call.strip().upper() if call else None
    if grid and GRID.match(grid.strip()):
        g = grid.strip()
        grid = g[:4].upper() + g[4:].lower()
    else:
        grid = None
    return call or None, grid


# wspr_spots.txt, which wsprd rewrites each run: date time sync snr dt freq
# message drift cycles jitter. WSJT-X parses it with this same expression.
SPOT_LINE = re.compile(r"^(\d{6})\s+(\d{4})\s+(-?\d+)\s+([+-]?\d+)\s+([+-]?\d+\.\d+)\s+"
                       r"(\d+\.\d+)\s+(\S.*\S)\s+([+-]?\d+)\s+([+-]?\d+)\s+([+-]?\d+)\s*$")
# ALL_WSPR.TXT, wsprd's running log: date time snr dt freq message drift ...
ALL_LINE = re.compile(r"^(\d{6})\s+(\d{4})\s+([+-]?\d+)\s+([+-]?\d+\.\d+)\s+(\d+\.\d+)\s+"
                      r"(\S.*?\S)\s+([+-]?\d+)\s+[+-]?\d+\.\d+\s")


def parse_wspr_message(msg):
    """'K1ABC FN42 37', 'PJ4/K1ABC 37' or '<PJ4/K1ABC> FK52UD 37' -> (call, grid, dbm)."""
    w = msg.split()
    try:
        dbm = int(w[-1])
    except (ValueError, IndexError):
        return None
    if len(w) == 3 and GRID.match(w[1]):
        call, grid = w[0].strip("<>"), w[1]
    elif len(w) == 2:
        call, grid = w[0].strip("<>"), None
    else:
        return None
    if not call or call == "...":
        return None
    return call, grid, dbm


def spot_from(date, hhmm, snr, dt, mhz, msg, drift, mygrid=None):
    parsed = parse_wspr_message(msg)
    if not parsed:
        return None
    call, grid, dbm = parsed
    if grid:  # DM33vq, as WSPRnet and everyone else writes it
        grid = grid[:4].upper() + grid[4:].lower()
    iso = "20%s-%s-%sT%s:%s:00Z" % (date[:2], date[2:4], date[4:6], hhmm[:2], hhmm[2:])
    return {"time": iso, "snr": int(snr), "dt": float(dt), "freq": round(float(mhz) * 1e6),
            "drift": int(drift), "call": call, "grid": grid, "dbm": dbm,
            "km": grid_km(mygrid, grid) if grid else None, "text": msg.strip(),
            "date": date, "hhmm": hhmm, "mhz": mhz}


class WsprNet:
    """Uploads spots to WSPRnet the way WSJT-X does: one form POST each, and a
    'wsprstat' heartbeat for a slot with none, so the station shows as on air.

    A spot that can't be sent (no internet) waits and goes with the next slot;
    one the server answers without "spot(s) added" is dropped, not retried.
    """

    KEEP = 2000  # about a day of a busy band, offline

    def __init__(self, call, grid, url=None, post=None):
        self.call, self.grid = call, grid
        self.url = url or WSPRNET_URL
        self.post = post or self._post
        self.pending = collections.deque(maxlen=self.KEEP)
        self.sent = 0
        self.error = None
        self.online = None   # None until the first upload says either way

    def _post(self, fields):
        import urllib.request
        body = urllib.parse.urlencode(fields).encode()
        req = urllib.request.Request(self.url, data=body, headers={
            "Content-Type": "application/x-www-form-urlencoded"})
        with urllib.request.urlopen(req, timeout=20) as r:
            return r.status, r.read(4096).decode("utf-8", "replace")

    def queue_slot(self, spots, dial_hz):
        rqrg = "%.6f" % (dial_hz / 1e6)
        common = {"version": RXD_VERSION, "rcall": self.call, "rgrid": self.grid,
                  "rqrg": rqrg, "mode": "2"}
        n = 0
        for s in spots:
            # WSJT-X's guard against reporting a spot off the band it's on.
            if abs(float(s["mhz"]) - dial_hz / 1e6) >= 0.01:
                continue
            f = {"function": "wspr", "date": s["date"], "time": s["hhmm"],
                 "sig": str(s["snr"]), "dt": "%.1f" % s["dt"], "drift": str(s["drift"]),
                 "tqrg": s["mhz"], "tcall": s["call"], "tgrid": s["grid"] or "",
                 "dbm": str(s["dbm"])}
            f.update(common)
            self.pending.append(f)
            n += 1
        return n

    def flush(self, dial_hz, had_spots):
        """Send what's waiting (and a heartbeat for an empty slot)."""
        if not had_spots:
            beat = {"function": "wsprstat", "rcall": self.call, "rgrid": self.grid,
                    "rqrg": "%.6f" % (dial_hz / 1e6), "tpct": "0",
                    "tqrg": "%.6f" % (dial_hz / 1e6), "dbm": "0",
                    "version": RXD_VERSION, "mode": "2"}
            try:
                self.post(beat)
                self.online, self.error = True, None
            except OSError as e:
                self.online, self.error = False, "can't reach WSPRnet: %s" % e
        while self.pending:
            f = self.pending[0]
            try:
                code, text = self.post(f)
            except OSError as e:
                self.online, self.error = False, "can't reach WSPRnet: %s" % e
                return
            self.online = True
            self.pending.popleft()
            if code == 200 and "spot(s) added" in text:
                self.sent += 1
                self.error = None
            else:
                self.error = "WSPRnet refused a spot: %s" % (text.strip()[:120] or code)
            time.sleep(0.2)  # WSJT-X's pace

    def status(self):
        return {"enabled": True, "call": self.call, "grid": self.grid, "sent": self.sent,
                "pending": len(self.pending), "online": self.online, "error": self.error}


class WsprDecoder:
    """Two-minute slots of the receiver's audio -> wsprd -> spots.

    A slot starts on an even UTC minute and a transmission 1 s into it; wsprd
    reads 114 s at 12 kHz. A slot is joined at most 2 s late (padded with
    silence) and dropped if the dial moves during it.
    """

    RATE = 12000
    SLOT = 120
    SAMPLES = 114 * 12000
    LATE = 2.0
    KEEP = 1000

    def __init__(self, settings, datadir=None, wsprd=None, reporter=None, clock=time.time):
        self.s = settings
        self.dir = datadir or WSPR_DIR
        os.makedirs(self.dir, exist_ok=True)
        self.wsprd = wsprd or WSPRD
        self.reporter = reporter
        self.clock = clock
        self.resample = FirDecimator(sps.firwin(129, 5000, fs=AUDIO_RATE).astype(np.float32),
                                     AUDIO_RATE // self.RATE)
        self.chunks, self.n, self.slot, self.dial = [], 0, None, None
        self.jobs = queue.Queue(maxsize=2)
        self.lock = threading.Lock()
        self.lines = collections.deque(maxlen=self.KEEP)
        self.seq = 0
        self.decoding = None   # the slot being decoded
        self.last = None       # {"slot", "spots"} for the last decoded slot
        self.error = None
        self.call, self.grid = station_id()
        self.load_history()
        threading.Thread(target=self.worker, name="wspr", daemon=True).start()

    def iso(self, t):
        return time.strftime("%Y-%m-%dT%H:%M:00Z", time.gmtime(t))

    # -------------------------------------------------------- recording

    def push(self, audio, dial, now=None):
        """A block of 48 kHz audio that ended at now (Unix time)."""
        a = self.resample(audio)
        now = self.clock() if now is None else now
        t0 = now - len(a) / self.RATE
        if self.slot is not None and (dial != self.dial or t0 > self.slot + self.SLOT):
            self.slot = None  # retuned, or a gap (the dongle stalled)
        if self.slot is None:
            slot = (t0 // self.SLOT) * self.SLOT
            late = t0 - slot
            if late > self.LATE:
                return
            self.slot, self.dial = slot, dial
            pad = int(round(late * self.RATE))
            self.chunks, self.n = [np.zeros(pad, np.float32)], pad
        self.chunks.append(a)
        self.n += len(a)
        if self.n >= self.SAMPLES:
            x = np.concatenate(self.chunks)[: self.SAMPLES]
            try:
                self.jobs.put_nowait((self.slot, self.dial, x))
            except queue.Full:
                self.error = "decoding is falling behind; a slot was skipped"
                log(self.error)
            self.slot, self.chunks, self.n = None, [], 0

    # --------------------------------------------------------- decoding

    def worker(self):
        while True:
            slot, dial, x = self.jobs.get()
            self.decoding = slot
            try:
                spots = self.decode(slot, dial, x)
                self.error = None
            except (OSError, subprocess.SubprocessError, RuntimeError) as e:
                self.error = "wsprd failed: %s" % e
                log(self.error)
                spots = None
            finally:
                self.decoding = None
            if spots is None:
                continue
            with self.lock:
                for sp in spots:
                    self.seq += 1
                    self.lines.append(dict(sp, seq=self.seq))
                self.last = {"slot": self.iso(slot), "spots": len(spots)}
            if self.reporter and self.s.snapshot().get("wspr_report"):
                self.reporter.queue_slot(spots, dial)
                self.reporter.flush(dial, bool(spots))

    def decode(self, slot, dial, x):
        import wave
        name = time.strftime("%y%m%d_%H%M", time.gmtime(slot))
        wav = os.path.join(self.dir, name + ".wav")
        # The audio is AGC'd to about 0.5 peak; wsprd wants 16-bit PCM.
        pcm = np.clip(x * 16000, -32768, 32767).astype("<i2")
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(self.RATE)
            w.writeframes(pcm.tobytes())
        spots_file = os.path.join(self.dir, "wspr_spots.txt")
        try:
            os.remove(spots_file)
        except OSError:
            pass
        argv = [self.wsprd, "-a", self.dir, "-f", "%.6f" % (dial / 1e6), wav]
        if shutil.which("nice"):
            argv = ["nice", "-n", "10"] + argv
        try:
            out = subprocess.run(argv, capture_output=True, text=True, timeout=110,
                                 cwd=self.dir)
        finally:
            try:
                os.remove(wav)
            except OSError:
                pass
        if "<DecodeFinished>" not in out.stdout:
            raise RuntimeError((out.stderr or out.stdout).strip()[-200:] or
                               "exit %d" % out.returncode)
        spots = []
        try:
            with open(spots_file, encoding="utf-8", errors="replace") as fh:
                for row in fh:
                    m = SPOT_LINE.match(row.rstrip("\n"))
                    if m:
                        sp = spot_from(m[1], m[2], m[4], m[5], m[6], m[7], m[8], self.grid)
                        if sp:
                            spots.append(sp)
        except FileNotFoundError:
            pass  # no spots this slot
        return spots

    def load_history(self):
        """The tail of ALL_WSPR.TXT, so a restart doesn't empty the feed."""
        path = os.path.join(self.dir, "ALL_WSPR.TXT")
        try:
            with open(path, "rb") as fh:
                fh.seek(0, 2)
                size = fh.tell()
                fh.seek(max(size - 131072, 0))
                rows = fh.read().decode("utf-8", "replace").split("\n")
        except OSError:
            return
        if size > 131072:
            rows = rows[1:]
        for row in rows:
            m = ALL_LINE.match(row)
            if m:
                sp = spot_from(m[1], m[2], m[3], m[4], m[5], m[6], m[7], self.grid)
                if sp:
                    self.seq += 1
                    self.lines.append(dict(sp, seq=self.seq))

    # ----------------------------------------------------------- status

    def since(self, after):
        with self.lock:
            out = list(self.lines)[-200:] if after <= 0 else \
                [x for x in self.lines if x["seq"] > after]
            return {"seq": self.seq, "lines": out}

    def status(self):
        now = self.clock()
        if self.decoding is not None:
            state, slot = "decoding", self.decoding
        elif self.slot is not None:
            state, slot = "recording", self.slot
        else:
            state, slot = "waiting", (now // self.SLOT + 1) * self.SLOT
        snap = self.s.snapshot()
        if self.reporter is None:
            report = {"enabled": False, "call": self.call, "grid": self.grid,
                      "reason": "no callsign and grid: set MyCall and MyGrid in JS8Call, "
                                "or RXD_CALL and RXD_GRID in /etc/rx/rxd.env"}
        else:
            report = self.reporter.status()
            report["enabled"] = bool(snap.get("wspr_report"))
        return {"state": state, "slot": self.iso(slot),
                "decoding": self.iso(self.decoding) if self.decoding is not None else None,
                "last": self.last, "error": self.error, "report": report}


# The browser UI: $RXD_WEB, where setup.sh installs it, or beside this file in
# a checkout. Read on every request so a reinstall needs no restart.
WEB_PATHS = (os.environ.get("RXD_WEB", ""), "/usr/local/share/rxd/index.html",
             os.path.join(os.path.dirname(os.path.abspath(__file__)), "web", "index.html"))


def web_page():
    for path in WEB_PATHS:
        if path and os.path.isfile(path):
            with open(path, "rb") as fh:
                return fh.read()
    return None


class Api(BaseHTTPRequestHandler):
    server_version = "rxd/0.1"

    def log_message(self, fmt, *args):
        pass

    def send(self, code, doc):
        body = (json.dumps(doc) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api/status":
            return self.send(200, self.server.rx.status())
        if path == "/api/spectrum":
            spec = self.server.rx.spectrum
            return self.send(200, spec) if spec else self.send(503, {"error": "no spectrum yet"})
        if path == "/api/profiles":
            try:
                return self.send(200, list_profiles())
            except (OSError, ValueError, subprocess.SubprocessError) as e:
                return self.send(503, {"error": "can't list profiles: %s" % e})
        if path == "/api/js8":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            try:
                after = int(q.get("after", ["0"])[0])
            except ValueError:
                return self.send(400, {"error": "after must be a number"})
            return self.send(200, self.server.js8.since(after))
        if path == "/api/wspr":
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            try:
                after = int(q.get("after", ["0"])[0])
            except ValueError:
                return self.send(400, {"error": "after must be a number"})
            wspr = self.server.rx.wspr
            if wspr is None:
                return self.send(200, {"seq": 0, "lines": [], "decoder": self.server.rx.s.decoder})
            return self.send(200, wspr.since(after))
        if path == "/api/audio":
            return self.audio()
        if path in ("/", "/index.html"):
            page = web_page()
            if page is None:
                return self.send(404, {"error": "no web UI at " + ", ".join(p for p in WEB_PATHS if p)})
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(page)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(page)
            return
        self.send(404, {"error": "not found"})

    def audio(self):
        rx = self.server.rx
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        try:
            rate = int(q.get("rate", ["24000"])[0])
        except ValueError:
            rate = 0
        if rate not in rx.STREAM_RATES:
            return self.send(400, {"error": "rate must be one of %s" % (rx.STREAM_RATES,)})
        chunks = rx.listen(rate)
        # A client that stops reading without closing (a phone off the Wi-Fi)
        # would block the write forever and hold a listener slot: give up.
        self.connection.settimeout(10)
        if chunks is None:
            return self.send(429, {"error": "%d clients are already listening" % rx.MAX_LISTENERS})
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("X-Audio-Rate", str(rate))
            self.send_header("X-Audio-Format", "s16le; channels=1")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Access-Control-Expose-Headers", "X-Audio-Rate")
            self.end_headers()
            # HTTP/1.0: the stream simply runs until either side closes it.
            while not rx.stop.is_set():
                try:
                    data = chunks.get(timeout=5)
                except queue.Empty:
                    continue
                self.wfile.write(data)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            rx.unlisten(chunks)

    def do_POST(self):
        if self.path == "/api/profile":
            return self.switch()
        if self.path != "/api/tune":
            return self.send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", 0))
            doc = json.loads(self.rfile.read(n) or b"{}")
            if not isinstance(doc, dict):
                raise ValueError("body must be a JSON object")
            unknown = set(doc) - {"freq", "mode", "bandwidth", "gain_db", "volume", "squelch",
                                  "wspr_report"}
            if unknown:
                raise ValueError("unknown field(s): " + ", ".join(sorted(unknown)))
            self.server.rx.s.update(**doc)
        except (ValueError, TypeError, AttributeError) as e:
            return self.send(400, {"error": str(e)})
        self.send(200, self.server.rx.status())

    def switch(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            doc = json.loads(self.rfile.read(n) or b"{}")
            name = doc.get("name") if isinstance(doc, dict) else None
            if not isinstance(name, str):
                raise ValueError('body must be {"name": PROFILE}')
            names = [p["name"] for p in list_profiles()["profiles"]]
            if name not in names:
                raise ValueError("no profile '%s' (have: %s)" % (name, ", ".join(names)))
        except (ValueError, TypeError) as e:
            return self.send(400, {"error": str(e)})
        except (OSError, subprocess.SubprocessError) as e:
            return self.send(503, {"error": "can't list profiles: %s" % e})
        try:
            spawn_switch(name)
        except OSError as e:
            return self.send(503, {"error": "can't run radio: %s" % e})
        log("switching to %s for an HTTP client" % name)
        self.send(202, {"switching": name})


# ---------------------------------------------------------------------- main

def make_wspr(settings):
    if not os.path.isfile(WSPRD):
        log("no wsprd at %s (sudo apt install wsjtx): WSPR won't decode" % WSPRD)
    call, grid = station_id()
    reporter = WsprNet(call, grid) if call and grid else None
    return WsprDecoder(settings, reporter=reporter)


def hostport(text, default_port):
    host, _, port = text.rpartition(":")
    return (host or "127.0.0.1", int(port or default_port))


def parse_args(argv=None):
    ap = argparse.ArgumentParser(prog="rxd", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("profile")
    ap.add_argument("--iq", help="cu8 file, - for stdin, or synth (default: the dongle)")
    ap.add_argument("--iq-center", type=float,
                    help="tuner frequency the IQ file was recorded at")
    ap.add_argument("--audio", default="pulse",
                    help="pulse, pulse:SINK, stdout or null (default: the profile's sink)")
    # Defaults from the environment, so the systemd unit's EnvironmentFile
    # (/etc/rx/rxd.env) can open HTTP to the LAN without editing the unit.
    ap.add_argument("--rigctl", default=os.environ.get("RXD_RIGCTL", "127.0.0.1:4532"),
                    help="HOST:PORT, or off (default $RXD_RIGCTL or 127.0.0.1:4532)")
    ap.add_argument("--http", default=os.environ.get("RXD_HTTP", "127.0.0.1:8073"),
                    help="HOST:PORT, or off (default $RXD_HTTP or 127.0.0.1:8073)")
    return ap.parse_args(argv)


def main(argv=None):
    a = parse_args(argv)
    p, path = load_profile(a.profile)
    try:
        settings = Settings(p, os.path.basename(path)[:-5])
    except ValueError as e:
        sys.exit("rxd: " + str(e))
    snap = settings.snapshot()

    if a.iq == "synth":
        src = SynthSource(snap["dial"] - snap["cal"] + snap["upconverter"] + 1500)
    elif a.iq:
        src = FileSource(a.iq, a.iq_center)
    else:
        src = RtlSource(settings.serial)

    if a.audio == "stdout":
        sink = StdoutSink()
    elif a.audio == "null":
        sink = NullSink()
    elif a.audio.startswith("pulse"):
        sink = PulseSink(a.audio.partition(":")[2] or settings.sink)
    else:
        sys.exit("rxd: --audio must be pulse, pulse:SINK, stdout or null")

    rx = Receiver(settings, src, sink)
    if settings.decoder == "wspr":
        rx.wspr = make_wspr(settings)
    rx.start()
    servers = []
    if a.rigctl != "off":
        rs = RigctlServer(hostport(a.rigctl, 4532), RigctlHandler)
        rs.rx = rx
        servers.append(rs)
    if a.http != "off":
        hs = ThreadingHTTPServer(hostport(a.http, 8073), Api)
        hs.daemon_threads = True
        hs.rx = rx
        hs.js8 = Js8Feed()
        servers.append(hs)
    for srv in servers:
        threading.Thread(target=srv.serve_forever, daemon=True).start()

    def reload(*_):
        try:
            settings.apply_profile(load_profile(path)[0])
            log("reloaded %s" % path)
        except (OSError, ValueError, KeyError) as e:
            log("reload failed: %s" % e)

    signal.signal(signal.SIGHUP, reload)
    signal.signal(signal.SIGTERM, lambda *_: rx.stop.set())
    st = rx.status()
    log("%s %.4f MHz %s, tuner %.4f MHz, rigctl %s, http %s"
        % (os.path.basename(path), st["freq"] / 1e6, st["mode"],
           (st["tuner_hz"] or 0) / 1e6, a.rigctl, a.http))
    try:
        while not rx.stop.wait(0.5):
            pass
    except KeyboardInterrupt:
        rx.stop.set()
    for srv in servers:
        srv.shutdown()
    src.close()
    sink.close()
    return 1 if rx.error else 0


if __name__ == "__main__":
    sys.exit(main())
RXD
    log "installed rxd"

    # The terminal client: tunes rxd over its HTTP API on this machine.
    write_file /usr/local/bin/rxd-tui 0755 <<'RXDTUI'
#!/usr/bin/env python3
"""rxd-tui: a terminal client for rxd, the RTL-SDR receiver daemon.

It talks only to rxd's HTTP API, by default at http://127.0.0.1:8073, and
has three views, like rxd's browser UI. The view follows the receiver's
profile; 1, 2 and 3 pick one.

  1 Digital  the digital modes, with a picker for their profiles grouped
             by mode (JS8: Ghostnet or regular JS8Call; WSPR). On JS8 it
             shows JS8Call's decodes and the clock; on WSPR, rxd's own spots,
             the two-minute cycle and the reporting to WSPRnet, which r turns
             on and off. Nothing to tune.
  2 Listen   a picker of broadcast FM, VHF/UHF and AM stations, with gain,
             bandwidth, squelch (NFM) and the uConsole speaker's volume.
  3 Manual   the full instrument: tuning, spectrum and waterfall.

Picking a station or frequency switches rxd's profile; rxd restarts, which
takes a few seconds. Leaving a JS8 profile asks first, since it closes
JS8Call.

Times are shown in this machine's time zone ($TZ), 24-hour.

l plays the receiver's audio on this machine, through the first of pw-cat,
paplay, aplay, ffplay or sox's play on PATH (or --player), so the TUI works
as a remote listening station; on JS8 the audio goes to JS8Call instead.
[ ] set its volume here; M mutes the uConsole's own speaker meanwhile.
--listen starts with it on.

? shows each view's keys. A typed frequency (f, in Manual) is MHz when it is
under 2000 (7.078, 146.52), kHz under 100000 (14074) and Hz above that;
a unit (k, M, Hz) overrides this.

Status is shown with a symbol and a word as well as colour, and NO_COLOR is
honoured. --ascii draws without Unicode block characters.
"""
import argparse
import calendar
import collections
import curses
import json
import locale
import math
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from array import array

DEFAULT_URL = "http://127.0.0.1:8073"
STEPS = (10, 100, 1000, 5000, 12500, 100000, 1000000)  # same set as the web UI
DEFAULT_STEP = 1000
MODES = ("USB", "LSB", "AM", "FM", "WFM")
# Bandwidth presets for [ and ] in Manual. rxd's SSB filter runs from 200 Hz
# to 200 Hz plus the bandwidth, so 2800 is SDR++'s 3000 Hz filter.
BANDWIDTHS = {"USB": (500, 1000, 1800, 2400, 2800), "LSB": (500, 1000, 1800, 2400, 2800),
              "AM": (3000, 5000, 6000, 8000, 10000), "FM": (6250, 10000, 12500, 25000),
              "WFM": (100000, 150000, 200000)}
FREQ_MIN, FREQ_MAX = 100e3, 1.7e9      # rxd's tuning range
VOLUME_MAX = 4.0                       # rxd accepts 0 to 4
GAIN_FALLBACK_MAX = 50.0               # 1 dB steps when rxd reports no gain table
LEVEL_LO, LEVEL_HI = -110.0, -10.0     # signal bar span, dBFS

# The views, and which profiles belong to which (as in the browser UI).
VIEWS = (("digital", "Digital"), ("listen", "Listen"), ("manual", "Manual"))
# The Digital view's picker groups its profiles by decoder, in this order.
DECODERS = (("js8", "JS8"), ("wspr", "WSPR"))
LISTEN_MODES = ("WFM", "FM", "AM")
GROUPS = (("WFM", "Broadcast FM"), ("FM", "VHF · UHF"), ("AM", "AM"))
# Listen's b cycles these: Narrow, Normal, Wide.
LISTEN_BW = {"WFM": (100e3, 150e3, 200e3), "FM": (8e3, 12.5e3, 16e3), "AM": (6e3, 10e3, 15e3)}
BW_NAMES = ("Narrow", "Normal", "Wide")
SQUELCH_DEFAULT, SQUELCH_STEP = -60.0, 2.0       # dBFS
SQUELCH_MIN, SQUELCH_MAX = -120.0, 0.0
LOCAL_VOL_STEP, LOCAL_VOL_MAX = 10, 200          # percent, for audio played here
PLAYERS = ("pw-cat", "paplay", "aplay", "ffplay", "play")

STATUS_EVERY = 0.5      # seconds: about 2 a second
SPECTRUM_EVERY = 0.25   # about 4 a second, in Manual only
RETRY_EVERY = 1.0       # while rxd is unreachable
NO_SPECTRUM_EVERY = 5.0  # while rxd has no /api/spectrum
JS8_EVERY = 2.5         # the decode feed, on a JS8 profile
WSPR_EVERY = 3.0        # the spot feed, on a WSPR profile (spots come every 2 minutes)
PROFILES_RETRY = 10.0   # after /api/profiles failed
TIMEOUT = 0.8           # per request
SLOW_TIMEOUT = 20.0     # /api/profiles and the switch run `radio --json`
DROPPING_HOLD = 3.0     # "DROPPING" stays up this long after the count last rose
SWITCH_TIMEOUT = 25.0   # a profile switch that hasn't finished by then failed
WATERFALL_MAX = 64
JS8_KEEP = 500
AUDIO_STALL = 3.0       # seconds without audio before the stream is reopened
AUDIO_FRESH = 1.5       # audio this recent counts as playing


# ------------------------------------------------------------ pure logic

def parse_freq(text):
    """A typed frequency in Hz (an int). Raises ValueError with a readable message."""
    t = text.strip().lower().replace(" ", "").replace("_", "")
    m = re.fullmatch(r"(\d+(?:\.\d*)?|\.\d+)(hz|khz|k|mhz|m|ghz|g)?", t)
    if not m:
        raise ValueError("not a frequency: %r (try 7.078, 14074 or 7078000)" % text.strip())
    v = float(m.group(1))
    unit = m.group(2)
    if unit:
        hz = v * {"hz": 1, "k": 1e3, "khz": 1e3, "m": 1e6, "mhz": 1e6,
                  "g": 1e9, "ghz": 1e9}[unit]
    elif v < 2000:
        hz = v * 1e6
    elif v < 100000:
        hz = v * 1e3
    else:
        hz = v
    hz = int(round(hz))
    if not FREQ_MIN <= hz <= FREQ_MAX:
        raise ValueError("%s MHz is outside rxd's range, 0.1 to 1700 MHz" % format_mhz(hz))
    return hz


def clamp(v, lo, hi):
    return max(lo, min(hi, v))


def step_tune(freq, step, direction):
    """Tune to the next multiple of step up (direction > 0) or down, within range."""
    n = freq / step
    k = math.floor(n + 1e-9) + 1 if direction > 0 else math.ceil(n - 1e-9) - 1
    return int(clamp(k * step, FREQ_MIN, FREQ_MAX))


def next_step(step, direction):
    i = min(range(len(STEPS)), key=lambda j: abs(STEPS[j] - step))
    return STEPS[clamp(i + (1 if direction > 0 else -1), 0, len(STEPS) - 1)]


def next_mode(mode):
    return MODES[(MODES.index(mode) + 1) % len(MODES)] if mode in MODES else MODES[0]


def next_bandwidth(mode, bw, direction):
    """The next preset wider or narrower than bw; bw itself at either end."""
    presets = BANDWIDTHS.get(mode, BANDWIDTHS["USB"])
    bw = float(bw or presets[0])
    if direction > 0:
        wider = [p for p in presets if p > bw + 0.5]
        return float(wider[0]) if wider else bw
    narrower = [p for p in presets if p < bw - 0.5]
    return float(narrower[-1]) if narrower else bw


def next_gain(gains, gain_db, direction):
    """The next of the dongle's gain steps, or 1 dB steps when there is no table."""
    gains = sorted(float(g) for g in (gains or []))
    if not gains:
        g = 0.0 if gain_db is None else float(gain_db)
        return round(clamp(g + (1 if direction > 0 else -1), 0.0, GAIN_FALLBACK_MAX), 1)
    if gain_db is None:
        return gains[len(gains) // 2]
    if direction > 0:
        up = [g for g in gains if g > gain_db + 0.05]
        return up[0] if up else float(gain_db)
    down = [g for g in gains if g < gain_db - 0.05]
    return down[-1] if down else float(gain_db)


def next_volume(volume, direction):
    """0.05 steps up to 1, 0.25 steps above it, within rxd's 0 to 4."""
    v = float(volume or 0)
    if direction > 0:
        v += 0.05 if v < 1 - 1e-9 else 0.25
    else:
        v -= 0.05 if v <= 1 + 1e-9 else 0.25
    return round(clamp(v, 0.0, VOLUME_MAX), 2)


def format_mhz(hz):
    """7078000 -> '7.078 000' (MHz, grouped in threes)."""
    hz = int(round(hz))
    whole, frac = divmod(abs(hz), 1000000)
    return "%s%d.%03d %03d" % ("-" if hz < 0 else "", whole, frac // 1000, frac % 1000)


def format_hz(hz):
    """A size in Hz with a unit: 10 Hz, 12.5 kHz, 1 MHz."""
    hz = float(hz)
    for div, unit in ((1e6, "MHz"), (1e3, "kHz")):
        if abs(hz) >= div:
            return "%s %s" % (("%.3f" % (hz / div)).rstrip("0").rstrip("."), unit)
    return "%d Hz" % round(hz)


def short_mhz(hz):
    """105300000 -> '105.3 MHz'; 7078000 -> '7.078 MHz'."""
    return ("%.6f" % (float(hz) / 1e6)).rstrip("0").rstrip(".") + " MHz"


def station_freq(hz, mode):
    """The number and unit a station is known by: 105.3 MHz, or 1030 kHz on AM."""
    hz = float(hz)
    if mode == "AM" and hz < 30e6:
        return ("%.3f" % (hz / 1e3)).rstrip("0").rstrip("."), "kHz"
    return ("%.6f" % (hz / 1e6)).rstrip("0").rstrip("."), "MHz"


def percent(volume):
    return "%d %%" % round(float(volume) * 100)


def clip(text, width, g):
    """text cut to width, with an ellipsis if anything was cut."""
    if width <= 0:
        return ""
    if len(text) <= width:
        return text
    e = g.ellipsis if width > len(g.ellipsis) else ""
    return text[:width - len(e)] + e


# ---- profiles and views

def mode_label(mode):
    """rxd's FM is narrow FM; the browser UI calls it NFM too."""
    return "NFM" if mode == "FM" else (mode or "---")


def decoder_of(d):
    """What decodes a profile's (or a status's) audio: "js8", "wspr" or None.
    An older rxd or `radio --json` has only the js8 flag."""
    if "decoder" in d:
        return d["decoder"] if d["decoder"] in dict(DECODERS) else None
    return "js8" if d.get("js8") else None


def profile_kind(p):
    """Which view a profile belongs to: digital, listen or manual."""
    if decoder_of(p):
        return "digital"
    return "listen" if p.get("mode") in LISTEN_MODES else "manual"


def status_kind(st):
    """The same for a status, when the profile list isn't available."""
    if not st or not st.get("mode"):
        return None
    if decoder_of(st):
        return "digital"
    return "listen" if st["mode"] in LISTEN_MODES else "manual"


def group_digital(profiles):
    """The Digital view's picker: [(mode title, [profiles])], JS8 then WSPR."""
    out = []
    for dec, title in DECODERS:
        members = [p for p in profiles if decoder_of(p) == dec]
        if members:
            out.append((title, members))
    return out


def group_stations(profiles):
    """Listen's picker: [(group title, [profiles])], in the browser UI's order."""
    ls = [p for p in profiles if profile_kind(p) == "listen"]
    out = []
    for mode, title in GROUPS:
        members = [p for p in ls if p.get("mode") == mode]
        if members:
            out.append((title, members))
    return out


def picker_list(view, profiles):
    """The profiles a view's picker offers, in order."""
    if view == "digital":
        return [p for _, members in group_digital(profiles) for p in members]
    if view == "listen":
        return [p for _, members in group_stations(profiles) for p in members]
    return []


def cycle_bandwidth(mode, bw):
    """Listen's b: the next of Narrow, Normal and Wide, round again after Wide.
    Off a preset, the next wider one. None for a mode without presets."""
    presets = LISTEN_BW.get(mode)
    if not presets:
        return None
    bw = float(bw or 0)
    for i, p in enumerate(presets):
        if abs(p - bw) < 1:
            return presets[(i + 1) % len(presets)]
    wider = [p for p in presets if p > bw]
    return wider[0] if wider else presets[0]


def bandwidth_name(mode, bw):
    for name, p in zip(BW_NAMES, LISTEN_BW.get(mode, ())):
        if bw is not None and abs(p - float(bw)) < 1:
            return name
    return "Custom"


NOSEND = object()


def squelch_key(key, squelch, level):
    """Listen's squelch keys: s toggles, , lowers and . raises the level.

    Returns (what to send as squelch, or NOSEND; the level to remember;
    a message, or "")."""
    if key == "s":
        if squelch is None:
            return level, level, ""
        return None, float(squelch), ""
    if squelch is None:
        return NOSEND, level, "Squelch is off: s turns it on"
    d = SQUELCH_STEP if key == "." else -SQUELCH_STEP
    new = clamp(float(squelch) + d, SQUELCH_MIN, SQUELCH_MAX)
    if new == squelch:
        return NOSEND, new, "Squelch at its %s: %d dBFS" % (
            "highest" if d > 0 else "lowest", new)
    return new, new, ""


def squelch_words(st, g):
    """(text, role) for the squelch: Off, or the level and whether it's open."""
    sq = st.get("squelch")
    if sq is None:
        return "Off, always open", "value"
    lvl = "%d dBFS" % round(sq)
    if st.get("squelch_open") is False:
        return "%s  %s Closed (quiet)" % (lvl, g.stop), "label"
    return "%s  %s Open (signal)" % (lvl, g.rx), "ok"


def clock_words(clock, g, mode="JS8"):
    """(text, role) for the clock, which JS8 and WSPR need within about a second."""
    c = clock if isinstance(clock, dict) else {}
    if c.get("synced") is True:
        src = c.get("source")
        return "%s Clock synced%s" % (g.rx, " (%s)" % src if src else ""), "ok"
    if c.get("synced") is False:
        off = c.get("offset_s")
        extra = " (%.1f s off)" % abs(off) if isinstance(off, (int, float)) else ""
        return "%s Clock not synced: %s won't decode%s" % (g.bad, mode, extra), "bad"
    return "%s Clock unknown" % g.unknown, "warn"


def hiu_word(up):
    return "UPCONVERT" if up else "BYPASS"


def flip_needed(p, st):
    """Whether switching to profile p means flipping the Ham It Up's switch."""
    if "upconverter_hz" not in st or st.get("upconverter_hz") is None:
        return False
    return bool(p.get("upconvert")) != (st["upconverter_hz"] > 0)


# ---- JS8 decodes

def js8_mine(line, call):
    """Whether a decode is to (or mentions) the owner's callsign."""
    if line.get("mycall") is True:
        return True
    c = (call or "").upper()
    if not c:
        return False
    if (line.get("to") or "").upper() == c:
        return True
    text = str(line.get("text") or "").upper()
    sender = str(line.get("from") or "").upper()
    if sender and text.startswith(sender + ":"):
        text = text[len(sender) + 1:]  # the sender's own name isn't a mention
    return c in re.split(r"[^A-Z0-9/]+", text)


def js8_key(line):
    return " ".join([str(line.get("from") or ""), str(line.get("to") or ""),
                     str(line.get("text") or "")]).upper()


def js8_filter(lines, text):
    """The lines whose callsigns or text contain text (any case)."""
    return line_filter(lines, text, js8_key)


UTC_TIME = re.compile(r"(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d)(?::(\d\d))?")


def utc_epoch(t):
    """A UTC time from rxd ("2026-11-05 14:03:15" or "2026-11-06T12:20:00Z") as Unix
    time, or None."""
    m = UTC_TIME.match(str(t or "").strip())
    if not m:
        return None
    y, mo, d, hh, mm, ss = (int(x or 0) for x in m.groups())
    try:
        return calendar.timegm((y, mo, d, hh, mm, ss, 0, 0, 0))
    except (ValueError, OverflowError):
        return None


def local_time(t, seconds=True):
    """A UTC time from rxd in this machine's time zone, 24-hour: 08:03:15 (or 08:03)."""
    e = utc_epoch(t)
    if e is None:
        return None
    return time.strftime("%H:%M:%S" if seconds else "%H:%M", time.localtime(e))


def js8_time(t):
    """A decode's time, local. A bare time of day (no date) can't be converted and is
    shown as it came."""
    lt = local_time(t)
    if lt:
        return lt
    m = re.search(r"\d\d:\d\d:\d\d", str(t or ""))
    return m.group(0) if m else str(t or "--:--:--")[:8]


JS8_HEADER = "Time     SNR  From      Message"


def format_js8(line, call, width, g):
    """(text, mine) for one decode: time, SNR, sender, a mark if it's to us, text."""
    fr = str(line.get("from") or "?")
    text = str(line.get("text") or "")
    if text.upper().startswith(fr.upper() + ":"):
        text = text[len(fr) + 1:].strip()
    snr = line.get("snr")
    snr_t = "%+3d" % snr if isinstance(snr, int) else "  ?"
    mine = js8_mine(line, call)
    s = "%s %s  %-9s %s%s" % (js8_time(line.get("time")), snr_t, fr,
                              (g.mine + " ") if mine else "", text)
    return clip(s, width, g), mine


def stations_heard(lines, key="from"):
    return len({x.get(key) for x in lines if x.get(key)})


# ---- WSPR spots

KM_PER_MILE = 1.609344
WSPR_FORMAT = "%-5s  %-10s %-6s %5s %4s %4s %8s"
WSPR_HEADER = WSPR_FORMAT % ("Time", "Call", "Grid", "Miles", "SNR", "dBm", "Audio Hz")


def wspr_key(line):
    return " ".join(str(line.get(k) or "") for k in ("call", "grid", "text")).upper()


def line_filter(lines, text, key=js8_key):
    """The lines whose callsigns or text contain text (any case)."""
    f = (text or "").strip().upper()
    return [x for x in lines if f in key(x)] if f else list(lines)


def format_wspr(line, dial, width, g):
    """One spot: local time, call, grid, miles, SNR, dBm and the audio offset."""
    km = line.get("km")
    miles = "%d" % round(km / KM_PER_MILE) if isinstance(km, (int, float)) else ""
    snr, dbm, f = line.get("snr"), line.get("dbm"), line.get("freq")
    off = "%d" % round(f - dial) if isinstance(f, (int, float)) and \
        isinstance(dial, (int, float)) else ""
    s = WSPR_FORMAT % (local_time(line.get("time"), False) or "--:--",
                       str(line.get("call") or "?"), str(line.get("grid") or ""), miles,
                       "%+d" % snr if isinstance(snr, int) else "?",
                       "%d" % dbm if isinstance(dbm, int) else "?", off)
    return clip(s.rstrip(), width, g)


def slot_time(iso):
    return local_time(iso, False) or "--:--"


def wspr_cycle(w, g):
    """(text, role) for where the two-minute cycle is."""
    state = w.get("state")
    if state == "recording":
        return "%s Recording the %s slot" % (g.rx, slot_time(w.get("slot"))), "ok"
    if state == "decoding":
        slot = slot_time(w.get("decoding") or w.get("slot"))
        return "%s Decoding the %s slot" % (g.wait, slot), "value"
    if state == "waiting":
        return "%s Next slot %s" % (g.wait, slot_time(w.get("slot"))), "label"
    return "%s Cycle unknown" % g.unknown, "warn"


def wspr_last(w):
    last = w.get("last")
    if not isinstance(last, dict) or not last.get("slot"):
        return "No slot decoded yet"
    n = last.get("spots") or 0
    t = slot_time(last["slot"])
    if not n:
        return "No spots in the %s slot" % t
    return "%d spot%s in the %s slot" % (n, "" if n == 1 else "s", t)


def wspr_can_report(w):
    """Whether r can turn reporting on and off: rxd has a callsign and grid."""
    r = (w or {}).get("report")
    return isinstance(r, dict) and not r.get("reason")


def wspr_report_words(w, g):
    """(text, role) for the reporting to WSPRnet, in words as well as colour."""
    r = w.get("report")
    if not isinstance(r, dict):
        return "%s Reporting unknown" % g.unknown, "warn"
    if r.get("reason"):
        return "%s Not reporting: %s" % (g.stop, r["reason"]), "warn"
    who = " ".join(x for x in (r.get("call"), r.get("grid")) if x)
    if not r.get("enabled"):
        return "%s Not reporting to WSPRnet (r reports as %s)" % (g.stop, who), "label"
    pending = r.get("pending") or 0
    if r.get("online") is False:
        return "%s Offline: %d spot%s waiting" % (g.drop, pending, "" if pending == 1 else "s"), \
            "warn"
    if r.get("error"):
        return "%s %s" % (g.bad, r["error"]), "bad"
    text = "%s Reporting to WSPRnet as %s %s %d sent" % (g.rx, who, g.dot, r.get("sent") or 0)
    if pending:
        text += ", %d waiting" % pending
    return text, "ok"


# ---- audio here

def rate_for(mode):
    """The stream rate: 24 kHz carries broadcast FM's audio, 12 kHz is plenty for voice."""
    return 24000 if mode == "WFM" else 12000


def find_player(which=shutil.which):
    """(name, path) of the first raw-PCM player on PATH, or None."""
    for name in PLAYERS:
        path = which(name)
        if path:
            return name, path
    return None


def ffplay_channels(help_text):
    """ffmpeg 7 dropped the raw demuxers' -ac for -ch_layout; older ones lack it."""
    return ["-ch_layout", "mono"] if "ch_layout" in help_text else ["-ac", "1"]


def probe_ffplay(path):
    try:
        out = subprocess.run([path, "-hide_banner", "-h", "demuxer=s16le"],
                             capture_output=True, text=True, timeout=5,
                             stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return ["-ac", "1"]
    return ffplay_channels(out.stdout + out.stderr)


def player_command(name, path, rate, channels=None):
    """The argv that plays raw s16le mono at rate from stdin."""
    r = str(int(rate))
    if name == "pw-cat":
        return [path, "--playback", "--raw", "--format", "s16", "--rate", r, "--channels", "1", "-"]
    if name == "paplay":
        return [path, "--raw", "--format=s16le", "--rate=" + r, "--channels=1"]
    if name == "aplay":
        return [path, "-q", "-t", "raw", "-f", "S16_LE", "-r", r, "-c", "1"]
    if name == "ffplay":
        return [path, "-nodisp", "-loglevel", "quiet", "-f", "s16le", "-ar", r] + \
            list(channels or ["-ac", "1"]) + ["-"]
    if name == "play":
        return [path, "-q", "-t", "raw", "-e", "signed", "-b", "16", "-c", "1", "-r", r, "-"]
    raise ValueError("no such player: %s" % name)


def custom_command(cmd, rate):
    """--player's command, with {rate} replaced by the sample rate."""
    return [a.replace("{rate}", str(int(rate))) for a in shlex.split(cmd)]


def no_player_hint(platform=sys.platform):
    if platform == "darwin":
        return "No audio player found. Install one: brew install ffmpeg (or sox), or use --player"
    return "No audio player found. Install pipewire-bin, alsa-utils, ffmpeg or sox"



WAITING = "Waiting for rxd; 3 opens Manual meanwhile"

class Player:
    """How to start the local player: a name for the status and an argv per rate."""

    def __init__(self, name, build):
        self.name = name
        self.build = build

    @classmethod
    def found(cls, name, path):
        chans = []

        def build(rate):
            if name == "ffplay" and not chans:
                chans.extend(probe_ffplay(path))
            return player_command(name, path, rate, chans)
        return cls(name, build)

    @classmethod
    def custom(cls, cmd):
        argv = shlex.split(cmd)
        if not argv:
            raise ValueError("--player needs a command")
        return cls(os.path.basename(argv[0]), lambda rate: custom_command(cmd, rate))


def scale_pcm(data, gain):
    """s16le samples times gain, clamped to 16 bits. data must be whole samples."""
    if gain == 1.0:
        return data
    if gain <= 0:
        return bytes(len(data))
    a = array("h")
    a.frombytes(data)
    if sys.byteorder == "big":
        a.byteswap()
    out = array("h", [-32768 if v < -32768 else 32767 if v > 32767 else v
                      for v in (int(s * gain) for s in a)])
    if sys.byteorder == "big":
        out.byteswap()
    return out.tobytes()


# ---- glyphs and drawing helpers

class Glyphs:
    """Characters for Unicode terminals, or plain ASCII."""

    def __init__(self, ascii_only=False):
        self.ascii = ascii_only
        if ascii_only:
            self.bars = " .-=#"
            self.shade = " .:-=+*#%@"
            self.level = ("#", "-", "")
            self.dial, self.band, self.left, self.right = "^", "=", "<", ">"
            self.rx, self.drop, self.bad, self.stop, self.wait = "*", "!", "x", "#", "~"
            self.unknown, self.mine, self.cursor, self.dot = "?", ">", ">", "/"
            self.keys = {"left": "<-", "right": "->", "up": "Up", "down": "Dn", "sep": "/",
                         "updown": "Up/Dn"}
            self.ellipsis = "..."
        else:
            self.bars = " ▁▂▃▄▅▆▇█"
            self.shade = " ░▒▓█"
            self.level = ("█", "░", " ▏▎▍▌▋▊▉")
            self.dial, self.band, self.left, self.right = "▲", "━", "◀", "▶"
            self.rx, self.drop, self.bad, self.stop, self.wait = "●", "▲", "✕", "■", "…"
            self.unknown, self.mine, self.cursor, self.dot = "?", "◆", "▸", "·"
            self.keys = {"left": "←", "right": "→", "up": "↑", "down": "↓", "sep": "",
                         "updown": "↑↓"}
            self.ellipsis = "…"

    def text(self, s):
        """Text written with Unicode punctuation, made ASCII when it must be."""
        if not self.ascii:
            return s
        for a, b in (("·", "/"), ("…", "..."), ("●", "*"), ("▲", "!"), ("✕", "x"),
                     ("■", "#"), ("◆", ">"), ("▸", ">"), ("↑↓", "Up/Dn"), ("—", "-")):
            s = s.replace(a, b)
        return s


def resample(bins, start, stop, width, view_start=None, view_stop=None):
    """Bins spanning start..stop Hz -> width columns spanning the view (peak per column).

    Columns outside the bins' span are None, so an old waterfall row from
    before a retune lines up by frequency rather than by position."""
    n = len(bins)
    if not n or width <= 0 or stop <= start:
        return [None] * max(width, 0)
    vs = start if view_start is None else view_start
    ve = stop if view_stop is None else view_stop
    binw = (stop - start) / n
    colw = (ve - vs) / width
    out = []
    for c in range(width):
        f0 = vs + c * colw
        i0 = int(math.floor((f0 - start) / binw + 1e-9))
        i1 = int(math.ceil((f0 + colw - start) / binw - 1e-9))
        i1 = max(i1, i0 + 1)
        if i1 <= 0 or i0 >= n:
            out.append(None)
            continue
        out.append(max(bins[max(i0, 0):min(i1, n)]))
    return out


def db_range(values):
    """A display range: the noise floor (20th percentile) up to the strongest bin."""
    v = sorted(x for x in values if x is not None)
    if not v:
        return -120.0, -60.0
    lo = v[len(v) // 5] - 3
    hi = max(v[-1] + 3, lo + 30)
    return lo, hi


def _frac(v, lo, hi):
    return clamp((v - lo) / (hi - lo), 0.0, 1.0) if hi > lo else 0.0


def render_spectrum(values, rows, lo, hi, g):
    """Columns of dB -> rows of bar characters, top row first."""
    chars = g.bars
    per_row = len(chars) - 1
    lines = [[] for _ in range(rows)]
    for v in values:
        if v is None:
            for line in lines:
                line.append(" ")
            continue
        total = max(1, int(round(_frac(v, lo, hi) * rows * per_row)))
        for r in range(rows):
            base = (rows - 1 - r) * per_row
            lines[r].append(chars[clamp(total - base, 0, per_row)])
    return ["".join(line) for line in lines]


def render_waterfall_row(values, lo, hi, g):
    top = len(g.shade) - 1
    return "".join(" " if v is None else g.shade[int(round(_frac(v, lo, hi) * top))]
                   for v in values)


def column_of(hz, start, stop, width):
    return int(math.floor((hz - start) / (stop - start) * width)) if stop > start else -1


def marker_row(width, start, stop, dial, passband, g):
    """The passband as a bar and the dial as a pointer, under the spectrum."""
    row = [" "] * width
    if stop <= start or width <= 0:
        return "".join(row)
    if passband:
        a = column_of(min(passband), start, stop, width)
        b = column_of(max(passband), start, stop, width)
        for c in range(max(a, 0), min(b, width - 1) + 1):
            row[c] = g.band
    c = column_of(dial, start, stop, width)
    if c < 0:
        row[0] = g.left
    elif c >= width:
        row[-1] = g.right
    else:
        row[c] = g.dial
    return "".join(row)


def axis_row(width, start, stop):
    """Frequency labels (MHz) centred on round values across the spectrum."""
    row = [" "] * width
    span = stop - start
    if span <= 0 or width < 8:
        return "".join(row)
    raw = span / max(1, width // 14)
    mag = 10 ** math.floor(math.log10(raw))
    step = next(m * mag for m in (1, 2, 5, 10) if m * mag >= raw)
    decimals = max(0, -int(math.floor(math.log10(step / 1e6))))
    f = math.ceil(start / step) * step
    last_end = -1
    while f <= stop:
        label = "%.*f" % (decimals, f / 1e6)
        c = column_of(f, start, stop, width) - len(label) // 2
        if c > last_end and c >= 0 and c + len(label) <= width:
            row[c:c + len(label)] = label
            last_end = c + len(label)
        f += step
    return "".join(row)


def level_bar(dbfs, width, g):
    """The signal level as a filled bar from LEVEL_LO to LEVEL_HI dBFS."""
    if width <= 0:
        return ""
    full, empty, parts = g.level
    if dbfs is None:
        return empty * width
    cells = _frac(dbfs, LEVEL_LO, LEVEL_HI) * width
    n = int(cells)
    bar = full * n
    if parts and n < width:
        p = int((cells - n) * len(parts))
        if p:
            bar += parts[p]
    return bar + empty * (width - len(bar))


# 3x5 digits; '#' is lit. Drawn with half blocks (3 rows) or full cells.
FONT = {
    "0": ("###", "#.#", "#.#", "#.#", "###"), "1": (".#.", "##.", ".#.", ".#.", "###"),
    "2": ("###", "..#", "###", "#..", "###"), "3": ("###", "..#", "###", "..#", "###"),
    "4": ("#.#", "#.#", "###", "..#", "..#"), "5": ("###", "#..", "###", "..#", "###"),
    "6": ("###", "#..", "###", "#.#", "###"), "7": ("###", "..#", "..#", "..#", "..#"),
    "8": ("###", "#.#", "###", "#.#", "###"), "9": ("###", "#.#", "###", "..#", "###"),
    "-": ("...", "...", "###", "...", "..."), ".": (".", ".", ".", ".", "#"),
    " ": (".", ".", ".", ".", "."),
}


def big_text(text, scale, g):
    """Text in the big font: scale 1 is 3 rows (half blocks; 5 in ASCII), scale 2 is 5 rows."""
    cols = []  # one 5-pixel column at a time, with a blank column between glyphs
    for i, ch in enumerate(text):
        glyph = FONT.get(ch, FONT[" "])
        for x in range(len(glyph[0])):
            cols.append([glyph[y][x] == "#" for y in range(5)])
        if i < len(text) - 1:
            cols.append([False] * 5)
    if scale >= 2:
        on = "#" if g.ascii else "█"
        return ["".join((on * 2) if col[y] else "  " for col in cols) for y in range(5)]
    if g.ascii:
        return ["".join("#" if col[y] else " " for col in cols) for y in range(5)]
    pix = [[False] + col for col in cols]  # a blank pixel row on top: 6 rows -> 3
    half = {(True, True): "█", (True, False): "▀", (False, True): "▄", (False, False): " "}
    return ["".join(half[(p[2 * r], p[2 * r + 1])] for p in pix) for r in range(3)]


def badge(reachable, status, dropping, g, switching=None):
    """(symbol, word, role) for the receiver's state. Never colour alone."""
    if switching:
        return g.stop, "SWITCHING", "warn"
    if reachable is None:
        return g.wait, "CONNECTING", "warn"
    if not reachable:
        return g.bad, "NO RXD", "bad"
    if status.get("error"):
        return g.bad, "ERROR", "bad"
    if status.get("running") is False:
        return g.stop, "STOPPED", "bad"
    if dropping:
        return g.drop, "DROPPING", "warn"
    return g.rx, "RX", "ok"


SHORT_LABELS = {"bandwidth": "bw", "volume": "vol", "speaker": "spkr", "station": "pick",
                "switch": "pick", "squelch": "sq", "listen": "listen", "filter": "filter",
                "reporting": "report"}


def help_items(g, view="manual", mode=None, listening=False, decoder=None, report=False):
    """[(keys, label)] for a view's bottom line; ? and q always come last.
    In Digital, decoder is the receiver's ("js8", "wspr" or None) and report
    whether r can switch WSPR reporting."""
    k = g.keys
    ud = k["updown"]
    if view == "digital":
        # When they don't all fit, the ones just before the view keys go first.
        items = [(ud + " Enter", "switch")]
        if decoder == "wspr" and report:
            items.append(("r", "reporting"))
        if decoder != "js8":
            items += [("l", "listen")] + ([("[ ]", "volume")] if listening else [])
        items += [("PgUp PgDn", "scroll"), ("/", "filter")]
        if decoder == "js8" and listening:
            items.append(("l", "stop audio"))
        items.append(("1 2 3", "view"))
    elif view == "listen":
        items = [(ud + " Enter", "station"), ("g G", "gain"), ("b", "bandwidth")]
        if mode == "FM":
            items.append(("s , .", "squelch"))
        items += [("l", "listen")] + ([("[ ]", "volume")] if listening else []) + \
            [("- +", "speaker"), ("M", "mute"), ("1 2 3", "view")]
    else:
        items = [(k["left"] + k["sep"] + k["right"], "tune"), (k["up"] + k["sep"] + k["down"], "step"),
                 ("f", "freq"), ("m", "mode"), ("l", "listen"), ("[ ]", "bandwidth"),
                 ("g G", "gain"), ("- +", "volume"), ("1 2 3", "view")]
    return items + [("?", "help"), ("q", "quit")]


def help_line(width, g, items=None):
    """[(text, role)] for the bottom line: full labels if they fit, then shorter,
    then fewer items; ? help and q quit always stay."""
    items = list(items or help_items(g))

    def build(its, short, gap):
        parts = []
        for key, label in its:
            if short:
                label = SHORT_LABELS.get(label, label)
            if parts:
                parts.append((gap, "help"))
            parts += [(key, "key"), (" " + label, "help")]
        return parts

    def size(parts):
        return sum(len(t) for t, _ in parts)
    for short, gap in ((False, "  "), (True, "  "), (True, " ")):
        parts = build(items, short, gap)
        if size(parts) <= width:
            return parts
    while len(items) > 3:
        items.pop(-4)  # the view keys, ? and q always stay
        parts = build(items, True, " ")
        if size(parts) <= width:
            return parts
    return parts  # the caller clips


def use_color(environ=os.environ):
    """NO_COLOR (any non-empty value) turns colour off: https://no-color.org."""
    return not environ.get("NO_COLOR")


def unicode_ok():
    enc = (locale.getpreferredencoding(False) or "").lower().replace("-", "")
    return enc in ("utf8", "utf16", "utf32")


# ------------------------------------------------------------- talking to rxd

class Link:
    """rxd's HTTP API. Every call returns (code, doc) or raises OSError."""

    def __init__(self, url, timeout=TIMEOUT):
        self.url = url.rstrip("/")
        self.timeout = timeout

    def request(self, path, body=None, timeout=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(self.url + path, data=data,
                                     headers={"Content-Type": "application/json"} if data else {})
        try:
            with urllib.request.urlopen(req, timeout=timeout or self.timeout) as r:
                return r.status, json.loads(r.read() or b"{}")
        except urllib.error.HTTPError as e:
            try:
                doc = json.loads(e.read() or b"{}")
            except ValueError:
                doc = {}
            return e.code, doc if isinstance(doc, dict) else {}
        except ValueError as e:  # a reply that isn't JSON
            raise OSError("bad reply from rxd: %s" % e)

    def get(self, path, timeout=None):
        return self.request(path, timeout=timeout)

    def post(self, path, body, timeout=None):
        return self.request(path, body, timeout=timeout)


def reason(exc):
    """A short why for an unreachable rxd."""
    r = getattr(exc, "reason", exc)
    if isinstance(r, ConnectionRefusedError):
        return "connection refused"
    if isinstance(r, (TimeoutError, OSError)) and "timed out" in str(r):
        return "no answer"
    text = getattr(r, "strerror", None) or str(r)
    return text.strip() or r.__class__.__name__


class Poller:
    """Talks to rxd off the curses thread.

    One thread polls status (and the spectrum, in Manual) and sends tunes;
    another does the slow things: the profile list, profile switches and
    the decoder's feed (JS8 decodes or WSPR spots)."""

    def __init__(self, link, clock=time.monotonic):
        self.link = link
        self.clock = clock
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.side_wake = threading.Event()
        self.changed = threading.Event()
        self.halt = threading.Event()
        self.reachable = None      # None until the first answer or failure
        self.why = ""
        self.status = {}
        self.spectrum = None
        self.spec_state = "waiting"  # waiting, ok or missing (no /api/spectrum)
        self.want_spectrum = True
        self.history = collections.deque(maxlen=WATERFALL_MAX)
        self.dropping_until = 0.0
        self.pending = {}
        self.acks = []             # (sent, error or None), drained by the UI
        self.profiles = None       # rxd's {"active", "profiles"}
        self.profiles_state = "loading"  # loading, ok, missing (old rxd) or error
        self.profiles_error = ""
        self.want_profiles = True
        self.profiles_asked_for = None
        self.profiles_retry_at = 0.0
        self.switch_req = None
        self.switch_acks = []      # (name, error or None)
        # The decoder's feed: one of these fills at a time, the other is empty.
        self.js8_lines = collections.deque(maxlen=JS8_KEEP)
        self.wspr_lines = collections.deque(maxlen=JS8_KEEP)
        self.js8_state = self.wspr_state = "waiting"  # waiting, ok, missing or error
        self.feed_seq = 0
        self.feed_for = None       # (profile, decoder) the lines are from
        self.threads = []

    # called from the UI thread
    def start(self):
        for name, fn in (("rxd-poller", self.run), ("rxd-side", self.side)):
            th = threading.Thread(target=fn, name=name, daemon=True)
            th.start()
            self.threads.append(th)

    def tune(self, **fields):
        with self.lock:
            self.pending.update(fields)
        self.wake.set()

    def take_acks(self):
        with self.lock:
            acks, self.acks = self.acks, []
        return acks

    def switch(self, name):
        with self.lock:
            self.switch_req = name
        self.side_wake.set()

    def take_switch_acks(self):
        with self.lock:
            acks, self.switch_acks = self.switch_acks, []
        return acks

    def reload_profiles(self):
        with self.lock:
            self.want_profiles = True
            self.profiles_retry_at = 0.0
        self.side_wake.set()

    def dropping(self):
        return self.clock() < self.dropping_until

    def stop(self):
        self.halt.set()
        self.wake.set()
        self.side_wake.set()

    # the status thread
    def run(self):
        next_status = next_spec = 0.0
        while not self.halt.is_set():
            self.wake.clear()
            with self.lock:
                req, self.pending = self.pending, {}
            if req:
                self._tune(req)
                next_status = self.clock() + STATUS_EVERY
                continue
            now = self.clock()
            if now >= next_status:
                ok = self._status()
                next_status = now + (STATUS_EVERY if ok else RETRY_EVERY)
            if not self.want_spectrum:
                next_spec = next_status
            elif now >= next_spec:
                if self.reachable:
                    self._spectrum()
                    next_spec = now + (NO_SPECTRUM_EVERY if self.spec_state == "missing"
                                       else SPECTRUM_EVERY)
                else:
                    next_spec = next_status
            self.wake.wait(max(0.01, min(next_status, next_spec) - self.clock()))

    def _offline(self, exc):
        with self.lock:
            self.reachable = False
            self.why = reason(exc)
            self.spectrum = None
        self.changed.set()

    def _set_status(self, doc):
        with self.lock:
            old = self.status.get("dropped")
            if old is not None and (doc.get("dropped") or 0) > old:
                self.dropping_until = self.clock() + DROPPING_HOLD
            self.status = doc
            self.reachable = True
            self.why = ""

    def _status(self):
        try:
            code, doc = self.link.get("/api/status")
        except OSError as e:
            self._offline(e)
            return False
        if code != 200:
            self._offline(OSError("HTTP %d from /api/status" % code))
            return False
        self._set_status(doc)
        self.changed.set()
        return True

    def _spectrum(self):
        try:
            code, doc = self.link.get("/api/spectrum")
        except OSError as e:
            self._offline(e)
            return
        with self.lock:
            if code == 404:
                self.spec_state, self.spectrum = "missing", None
            elif code != 200 or not doc.get("bins"):
                self.spec_state = "waiting"
            else:
                self.spec_state = "ok"
                if not self.spectrum or doc.get("seq") != self.spectrum.get("seq"):
                    self.history.appendleft((float(doc["start_hz"]), float(doc["stop_hz"]),
                                             doc["bins"]))
                self.spectrum = doc
        self.changed.set()

    def _tune(self, req):
        try:
            code, doc = self.link.post("/api/tune", req)
        except OSError as e:
            with self.lock:
                self.acks.append((req, "not sent: can't reach rxd (%s)" % reason(e)))
            self._offline(e)
            return
        with self.lock:
            if code == 200:
                self.acks.append((req, None))
            else:
                self.acks.append((req, doc.get("error") or "rxd refused it (HTTP %d)" % code))
        if code == 200:
            self._set_status(doc)
        else:
            self._status()
        self.changed.set()

    # the side thread: profiles, switches and the decoder's feed
    def side(self):
        next_feed = 0.0
        while not self.halt.is_set():
            self.side_wake.clear()
            with self.lock:
                name, self.switch_req = self.switch_req, None
                st, reachable = dict(self.status), self.reachable
            if name:
                self._switch(name)
                continue
            if reachable and self._profiles_due(st):
                self._load_profiles(st)
                continue
            now = self.clock()
            dec = decoder_of(st)
            if reachable and dec:
                if (st.get("profile"), dec) != self.feed_for:
                    self._feed_reset((st.get("profile"), dec))
                    next_feed = 0.0
                if now >= next_feed:
                    self._feed(dec)
                    next_feed = self.clock() + (WSPR_EVERY if dec == "wspr" else JS8_EVERY)
            elif reachable and self.feed_for is not None:
                self._feed_reset(None)
            self.side_wake.wait(clamp(next_feed - self.clock(), 0.05, 0.5) if dec else 0.5)

    def _profiles_due(self, st):
        with self.lock:
            if self.clock() < self.profiles_retry_at:
                return False
            if self.want_profiles:
                return True
            # rxd moved to another profile (switched by `radio` or the web UI)
            act = self.profiles.get("active") if self.profiles else None
            name = st.get("profile")
            return bool(self.profiles and name and name != act and name != self.profiles_asked_for)

    def _load_profiles(self, st):
        with self.lock:
            self.profiles_asked_for = st.get("profile")
        try:
            code, doc = self.link.get("/api/profiles", timeout=SLOW_TIMEOUT)
        except OSError as e:
            with self.lock:
                self.profiles_error = "can't reach rxd (%s)" % reason(e)
                self.profiles_retry_at = self.clock() + RETRY_EVERY
            return
        with self.lock:
            self.want_profiles = False
            if code == 200 and isinstance(doc.get("profiles"), list):
                self.profiles, self.profiles_state, self.profiles_error = doc, "ok", ""
            elif code == 404:
                self.profiles, self.profiles_state = None, "missing"
            else:
                self.profiles_state = "error" if self.profiles is None else "ok"
                self.profiles_error = doc.get("error") or "HTTP %d" % code
                self.want_profiles = True
                self.profiles_retry_at = self.clock() + PROFILES_RETRY
        self.changed.set()

    def _switch(self, name):
        try:
            code, doc = self.link.post("/api/profile", {"name": name}, timeout=SLOW_TIMEOUT)
            err = None if code in (200, 202) else \
                "rxd refused: %s" % (doc.get("error") or "HTTP %d" % code)
        except OSError as e:
            err = "Not switched: can't reach rxd (%s)" % reason(e)
        with self.lock:
            self.switch_acks.append((name, err))
        self.changed.set()

    def _feed_reset(self, key):
        with self.lock:
            self.js8_lines.clear()
            self.wspr_lines.clear()
            self.feed_seq = 0
            self.feed_for = key
            self.js8_state = self.wspr_state = "waiting"
        self.changed.set()

    def _feed(self, dec):
        """New lines from /api/js8 or /api/wspr, which number them the same way."""
        lines = self.wspr_lines if dec == "wspr" else self.js8_lines
        try:
            code, doc = self.link.get("/api/%s?after=%d" % (dec, self.feed_seq), timeout=3.0)
        except OSError:
            return  # the status thread reports rxd's absence
        with self.lock:
            if code == 200 and isinstance(doc.get("lines"), list):
                seq = doc.get("seq") if isinstance(doc.get("seq"), int) else self.feed_seq
                if seq < self.feed_seq:  # rxd restarted and numbers from 1 again
                    lines.clear()
                    self.feed_seq = 0
                    self.side_wake.set()
                    return
                new = sorted((x for x in doc["lines"] if isinstance(x, dict)
                              and (x.get("seq") or 0) > self.feed_seq),
                             key=lambda x: x.get("seq") or 0)
                lines.extend(new)
                self.feed_seq = max(self.feed_seq, seq)
                state = "ok"
            elif code == 404:
                state = "missing"
            else:
                state = "error: " + (doc.get("error") or "HTTP %d" % code)
            setattr(self, dec + "_state", state)
        self.changed.set()


# ------------------------------------------------------------ audio here

class Refused(Exception):
    """rxd answered the audio request with an error: retry slowly."""


class AudioPlayer:
    """rxd's /api/audio piped into a local player, in a background thread.

    It reconnects when the stream drops (as it does across a profile switch),
    restarts the player when the rate changes with the mode, scales the
    samples for the volume here, and kills the player when it stops."""

    def __init__(self, url, player, changed=None, clock=time.monotonic):
        u = urllib.parse.urlsplit(url)
        self.scheme = u.scheme
        self.host = u.hostname or "127.0.0.1"
        self.port = u.port or 80
        self.base = u.path.rstrip("/")
        self.player = player
        self.changed = changed or threading.Event()
        self.clock = clock
        self.lock = threading.Lock()
        self.on = False
        self.rate = 12000
        self.gain = 1.0
        self.state = "off"     # off, connecting, playing, reconnecting, error
        self.error = ""
        self.play_rate = None
        self.last_data = 0.0
        self.bytes = 0
        self.proc = None
        self.sock = None
        self.halt = None
        self.thread = None

    # called from the UI thread
    def start(self, rate):
        if self.on:
            return
        self.rate = rate
        self.on = True
        self.halt = threading.Event()
        self._set("connecting")
        self.thread = threading.Thread(target=self.run, args=(self.halt,), name="rxd-audio",
                                       daemon=True)
        self.thread.start()

    def stop(self, wait=2.0):
        if not self.on:
            return
        self.on = False
        self.halt.set()
        self._close_sock()
        self._kill(self.proc)
        if self.thread:
            self.thread.join(wait)
        self._set("off")

    def set_rate(self, rate):
        self.rate = rate

    def words(self, g):
        """(symbol, text, role) for the audio's state."""
        with self.lock:
            state, err, rate, last = self.state, self.error, self.play_rate, self.last_data
        if not self.on:
            if err:
                return g.bad, "Audio stopped: " + err, "bad"
            return g.stop, "Not listening here", "dim"
        if state == "error":
            return g.bad, "Audio: %s Retrying." % err, "bad"
        if state == "playing" and self.clock() - last < AUDIO_FRESH:
            return g.rx, "Listening on this machine (%s, %s kHz)" % (
                self.player.name, ("%.1f" % (rate / 1000)).rstrip("0").rstrip(".")), "ok"
        if state == "connecting":
            return g.drop, "Connecting audio", "warn"
        return g.drop, "Reconnecting", "warn"

    # the thread
    def _set(self, state, error=""):
        with self.lock:
            changed = (state, error) != (self.state, self.error)
            self.state, self.error = state, error
        if changed:
            self.changed.set()

    def _close_sock(self):
        s, self.sock = self.sock, None
        if s:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            s.close()

    @staticmethod
    def _kill(proc):
        if not proc:
            return
        try:
            if proc.stdin:
                proc.stdin.close()
        except OSError:
            pass
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(1.0)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(1.0)

    def connect(self, rate):
        """A socket positioned at the PCM, and the stream's rate. Raises Refused or OSError."""
        if self.scheme not in ("http", ""):
            raise Refused("audio needs an http:// rxd URL.")
        s = socket.create_connection((self.host, self.port), timeout=3.0)
        try:
            s.sendall(("GET %s/api/audio?rate=%d HTTP/1.0\r\nHost: %s\r\n\r\n"
                       % (self.base, rate, self.host)).encode())
            buf = b""
            while b"\r\n\r\n" not in buf:
                data = s.recv(4096)
                if not data:
                    raise OSError("rxd closed the audio stream")
                buf += data
                if len(buf) > 65536:
                    raise OSError("bad audio reply from rxd")
            head, _, rest = buf.partition(b"\r\n\r\n")
            lines = head.decode("latin-1").split("\r\n")
            m = re.match(r"HTTP/\d\.\d (\d+)", lines[0])
            if not m:
                raise OSError("bad audio reply from rxd")
            code = int(m.group(1))
            headers = dict((k.strip().lower(), v.strip()) for k, _, v in
                           (x.partition(":") for x in lines[1:]))
            if code != 200:
                body = rest
                try:
                    while len(body) < 65536:
                        data = s.recv(4096)
                        if not data:
                            break
                        body += data
                except OSError:
                    pass
                try:
                    err = json.loads(body or b"{}").get("error")
                except (ValueError, AttributeError):
                    err = None
                if code == 404:
                    raise Refused("this rxd has no audio stream.")
                raise Refused("rxd refused: %s." % (err or "HTTP %d" % code))
            try:
                got = int(headers.get("x-audio-rate", rate))
            except ValueError:
                got = rate
            return s, got, rest
        except BaseException:
            s.close()
            raise

    def run(self, halt):
        proc, proc_rate, retries = None, None, 0
        try:
            while not halt.is_set():
                rate = self.rate
                try:
                    s, got, first = self.connect(rate)
                except Refused as e:
                    self._set("error", str(e))
                    halt.wait(5.0)
                    continue
                except OSError:
                    retries += 1
                    self._set("reconnecting" if self.bytes or retries > 1 else "connecting")
                    halt.wait(min(0.5 * retries, 3.0))
                    continue
                self.sock = s
                if halt.is_set():
                    break
                if proc is None or proc_rate != got or proc.poll() is not None:
                    self._kill(proc)
                    proc = None
                    try:
                        argv = self.player.build(got)
                        proc = subprocess.Popen(argv, stdin=subprocess.PIPE, bufsize=0,
                                                stdout=subprocess.DEVNULL,
                                                stderr=subprocess.DEVNULL,
                                                start_new_session=True)
                    except (OSError, ValueError) as e:
                        self._close_sock()
                        self._set("error", "can't start %s (%s)." % (self.player.name, e))
                        halt.wait(5.0)
                        continue
                    self.proc, proc_rate = proc, got
                with self.lock:
                    self.play_rate = got
                ended = self.pump(s, proc, first, rate, halt)
                self._close_sock()
                if ended == "player":
                    self._kill(proc)
                    proc = None
                    self._set("error", "%s stopped." % self.player.name)
                    halt.wait(2.0)
                elif ended == "rate":
                    retries = 0
                elif not halt.is_set():
                    retries += 1
                    self._set("reconnecting")
                    halt.wait(min(0.5 * retries, 3.0))
        finally:
            self._close_sock()
            self._kill(proc)
            self.proc = None

    def pump(self, s, proc, first, rate, halt):
        """Copy PCM to the player until something ends it; says what did."""
        s.settimeout(0.5)
        carry = b""
        last = self.clock()
        data = first
        while not halt.is_set():
            if self.rate != rate:
                return "rate"
            if data:
                data = carry + data
                n = len(data) & ~1
                carry, data = data[n:], data[:n]
                try:
                    proc.stdin.write(scale_pcm(data, self.gain))
                except (BrokenPipeError, OSError, ValueError):
                    return "player"
                now = self.clock()
                last = now
                self.bytes += n
                with self.lock:
                    self.last_data = now
                    was = self.state
                    self.state, self.error = "playing", ""
                if was != "playing":
                    self.changed.set()
            elif self.clock() - last > AUDIO_STALL:
                return "stall"
            if proc.poll() is not None:
                return "player"
            try:
                data = s.recv(8192)
            except socket.timeout:
                data = b""
                continue
            except OSError:
                return "closed"
            if not data:
                return "closed"
        return "halt"


# ------------------------------------------------------------------ drawing

class Canvas:
    """A plain-text screen, for tests."""

    def __init__(self, h, w):
        self.h, self.w = h, w
        self.cells = [[" "] * w for _ in range(h)]
        self.roles = [[""] * w for _ in range(h)]

    def put(self, y, x, text, role=""):
        if not 0 <= y < self.h:
            return
        for i, ch in enumerate(text):
            if 0 <= x + i < self.w:
                self.cells[y][x + i] = ch
                self.roles[y][x + i] = role

    def text(self):
        return "\n".join("".join(r).rstrip() for r in self.cells)

    def role_at(self, y, x):
        return self.roles[y][x]


class CursesScreen:
    ROLES = ("bar", "tabon", "big", "dim", "label", "value", "ok", "warn", "bad", "spec", "wf",
             "marker", "key", "help", "msg", "err", "upconv", "sel", "mine", "head")

    def __init__(self, win, color):
        self.win = win
        self.h, self.w = win.getmaxyx()
        self.attrs = self.make_attrs(color)

    @staticmethod
    def make_attrs(color):
        b, r, d = curses.A_BOLD, curses.A_REVERSE, getattr(curses, "A_DIM", 0)
        a = {"bar": r, "tabon": b, "big": b, "dim": d, "label": 0, "value": b, "ok": b,
             "warn": b, "bad": b | r, "spec": 0, "wf": 0, "marker": b, "key": r, "help": 0,
             "msg": 0, "err": b, "upconv": b, "sel": r, "mine": b | r, "head": b}
        if color:
            pairs = {"ok": curses.COLOR_GREEN, "warn": curses.COLOR_YELLOW,
                     "bad": curses.COLOR_RED, "err": curses.COLOR_RED,
                     "spec": curses.COLOR_CYAN, "marker": curses.COLOR_YELLOW,
                     "big": curses.COLOR_WHITE, "upconv": curses.COLOR_YELLOW,
                     "mine": curses.COLOR_CYAN}
            for n, (role, fg) in enumerate(sorted(pairs.items()), start=1):
                try:
                    curses.init_pair(n, fg, -1)
                    a[role] |= curses.color_pair(n)
                except curses.error:
                    pass
        return a

    def put(self, y, x, text, role=""):
        if not 0 <= y < self.h or x >= self.w:
            return
        text = text[:self.w - x]
        try:
            self.win.addstr(y, x, text, self.attrs.get(role, 0))
        except curses.error:
            pass  # writing the bottom-right cell moves the cursor off screen: harmless


class App:
    def __init__(self, poller, glyphs, url=DEFAULT_URL, audio=None, player_hint="",
                 clock=time.monotonic, listen=False):
        self.p = poller
        self.g = glyphs
        self.url = url
        self.audio = audio          # an AudioPlayer, or None when no player was found
        self.player_hint = player_hint or no_player_hint()
        self.clock = clock
        self.step = DEFAULT_STEP
        self.overrides = {}     # values sent but not yet confirmed by rxd
        self.message = ""       # the result of the last action
        self.message_role = "msg"
        self.entry = None       # text being typed, or None
        self.entry_kind = None  # "freq" or "filter"
        self.show_help = False
        self.confirm = None     # the profile a y/n question is about
        self.lo = self.hi = None  # smoothed spectrum range
        self.wf_cache = {}      # waterfall rows already resampled to the screen
        # views
        self.view = None        # digital, listen or manual; None until rxd says
        self.view_for = None    # the profile the view was chosen for
        self.pinned = False     # Manual, chosen by the user, stays
        self.cursor = 0
        self.cursor_key = None
        self.switching = None   # {"name", "desc", "prev_up", "want_up", "since"}
        self.sq_level = SQUELCH_DEFAULT
        self.mute_prev = None   # the uConsole volume M will restore
        self.local_vol = 100    # percent, for audio played here
        # the Digital view's list (JS8 decodes or WSPR spots)
        self.js8_filter = ""
        self.js8_scroll = 0     # lines back from the newest
        self.js8_seen = None    # (profile, matching lines) at the last draw
        self.js8_page = 10      # rows on screen, for PgUp and PgDn
        self.want_listen = listen  # --listen: start once rxd says which mode

    # ---- state
    def snap(self):
        with self.p.lock:
            s = dict(status=dict(self.p.status), spectrum=self.p.spectrum,
                     history=list(self.p.history), reachable=self.p.reachable, why=self.p.why,
                     spec_state=self.p.spec_state, profiles=self.p.profiles,
                     profiles_state=self.p.profiles_state,
                     profiles_error=getattr(self.p, "profiles_error", ""),
                     js8=list(self.p.js8_lines), js8_state=self.p.js8_state,
                     wspr=list(getattr(self.p, "wspr_lines", ())),
                     wspr_state=getattr(self.p, "wspr_state", "waiting"))
        st = s["status"]
        st.update(self.overrides)
        w = st.get("wspr")
        if "wspr_report" in self.overrides and isinstance(w, dict) and \
                isinstance(w.get("report"), dict):  # sent, not yet confirmed
            st["wspr"] = dict(w, report=dict(w["report"], enabled=self.overrides["wspr_report"]))
        return s

    def decoder(self, s):
        """The receiver's decoder: "js8", "wspr" or None."""
        return decoder_of(s["status"]) if s["status"] else None

    def profile_list(self, s):
        return (s["profiles"] or {}).get("profiles") or []

    def active_name(self, s):
        return s["status"].get("profile") or (s["profiles"] or {}).get("active")

    def active_profile(self, s):
        n = self.active_name(s)
        return next((p for p in self.profile_list(s) if p.get("name") == n), None)

    def kind(self, s):
        p = self.active_profile(s)
        return profile_kind(p) if p else status_kind(s["status"])

    def mismatch(self, s):
        k = self.kind(s)
        return self.view in ("digital", "listen") and k is not None and k != self.view

    def drain(self):
        for sent, err in self.p.take_acks():
            for k, v in sent.items():
                if self.overrides.get(k) == v:
                    del self.overrides[k]
            if err:
                self.say(err, "err")
        for name, err in self.p.take_switch_acks():
            if err and self.switching and self.switching["name"] == name:
                self.switching = None
                self.say(err, "err")

    def update(self):
        """Everything that follows from rxd's state: views, switches, the audio rate."""
        self.drain()
        s = self.snap()
        st = s["status"]
        self.p.want_spectrum = self.view == "manual"
        sw = self.switching
        if sw:
            if s["reachable"] and st.get("profile") == sw["name"]:
                self.finish_switch(st)
            elif self.clock() - sw["since"] > SWITCH_TIMEOUT:
                self.switching = None
                self.say("%s The switch to %s did not finish. %s" % (
                    self.g.bad, sw["name"],
                    "rxd is still on %s." % st.get("profile") if s["reachable"]
                    else "rxd has not come back after %d seconds." % SWITCH_TIMEOUT), "err")
                self.p.reload_profiles()
        if s["profiles_state"] == "missing":
            self.view = "manual"  # an rxd that can't switch profiles: the instrument only
        elif self.pinned:
            self.view = "manual"
            self.view_for = self.active_name(s)
        else:
            n, k = self.active_name(s), self.kind(s)
            if n and k and n != self.view_for:
                self.view_for, self.view = n, k
                self.js8_scroll = 0
        if self.mute_prev is not None and st.get("volume") and not self.switching \
                and "volume" not in self.overrides and s["reachable"]:
            self.mute_prev = None  # the speaker was turned up elsewhere
        if self.audio and self.want_listen and st.get("mode"):
            self.want_listen = False
            self.audio.start(rate_for(st["mode"]))
        if self.audio and self.audio.on and st.get("mode"):
            self.audio.set_rate(rate_for(st["mode"]))
        if self.audio:
            self.audio.gain = self.local_vol / 100.0
        return s

    def finish_switch(self, st):
        sw, self.switching = self.switching, None
        up = (st.get("upconverter_hz") or 0) > 0
        if up != sw["prev_up"]:
            self.say("%s Flip the Ham It Up to %s for %s; the wrong way is silent."
                     % (self.g.drop, hiu_word(up), sw["desc"]), "warn")
        else:
            self.say("%s Now on %s" % (self.g.rx, sw["desc"]), "ok")
        if sw.get("muted") is not None and st.get("volume"):
            self.mute_prev = st["volume"]
            self.send(volume=0.0)
        self.js8_scroll = 0
        self.p.reload_profiles()

    def say(self, text, role="msg"):
        self.message, self.message_role = text, role

    def send(self, **fields):
        self.overrides.update(fields)
        self.p.tune(**fields)

    def close(self):
        """On quit: stop the audio here, and give the uConsole speaker back if M muted it."""
        if self.audio:
            self.audio.stop()
        if self.mute_prev is not None and getattr(self.p, "link", None):
            try:
                self.p.link.post("/api/tune", {"volume": self.mute_prev})
            except OSError:
                pass
            self.mute_prev = None

    # ---- keys; returns False to quit
    def key(self, ch):
        s = self.update()
        if self.show_help:
            self.show_help = False
            return True
        if self.confirm is not None:
            p, self.confirm = self.confirm, None
            if ch in (ord("y"), ord("Y")):
                self.do_switch(p, s)
            else:
                self.say("Stayed on %s" % self.active_name(s))
            return True
        if self.entry is not None:
            return self.entry_key(ch)
        if ch in (ord("q"), ord("Q")):
            return False
        self.say("")
        if ch == ord("?"):
            self.show_help = True
        elif ch in (ord("1"), ord("2"), ord("3")):
            self.pick_view(VIEWS[ch - ord("1")][0], s)
        elif ch == ord("l"):
            self.toggle_audio(s)
        elif self.view == "digital":
            self.digital_key(ch, s)
        elif self.view == "listen":
            self.listen_key(ch, s)
        elif self.view == "manual":
            self.manual_key(ch, s)
        elif s["reachable"] is not True:
            self.say(WAITING)
        return True

    def pick_view(self, v, s):
        if v != "manual" and s["profiles_state"] == "missing":
            self.say("This rxd can't switch profiles (no /api/profiles), so it's Manual only",
                     "err")
            return
        self.view, self.pinned = v, v == "manual"
        self.view_for = self.active_name(s)
        self.cursor_key = None
        self.js8_scroll = 0

    def picker(self, s):
        """(the current view's picker list, the cursor, kept on the list)."""
        items = picker_list(self.view, self.profile_list(s))
        key = (self.view, self.active_name(s), tuple(p.get("name") for p in items))
        if key != self.cursor_key:
            self.cursor_key = key
            names = [p.get("name") for p in items]
            self.cursor = names.index(key[1]) if key[1] in names else 0
        self.cursor = clamp(self.cursor, 0, max(len(items) - 1, 0))
        return items

    def picker_key(self, ch, s):
        """↑/↓ and Enter in a picker. True if the key was the picker's."""
        if ch not in (curses.KEY_UP, curses.KEY_DOWN, 10, 13, curses.KEY_ENTER):
            return False
        items = self.picker(s)
        if not items:
            self.say(self.picker_empty(s), "err")
            return True
        if ch == curses.KEY_UP:
            self.cursor = max(0, self.cursor - 1)
        elif ch == curses.KEY_DOWN:
            self.cursor = min(len(items) - 1, self.cursor + 1)
        else:
            self.select(items[self.cursor], s)
        return True

    def picker_empty(self, s):
        if s["profiles_state"] == "error" and not s["profiles"]:
            return "%s Can't list profiles: %s" % (self.g.bad, s["profiles_error"])
        if not s["profiles"]:
            return "Loading profiles from rxd" + self.g.ellipsis
        return "No %s profiles are saved." % ("JS8 or WSPR" if self.view == "digital"
                                              else "station")

    def select(self, p, s):
        st = s["status"]
        if self.switching:
            self.say("Already switching to %s" % self.switching["name"])
        elif p.get("name") == self.active_name(s):
            self.say("Already on %s" % p.get("name"))
        elif not s["reachable"]:
            self.say("Not switched: can't reach rxd", "err")
        else:
            cur = self.active_profile(s)
            if decoder_of(st) == "js8" or (cur and decoder_of(cur) == "js8"):
                self.confirm = p
            else:
                self.do_switch(p, s)

    def do_switch(self, p, s):
        st = s["status"]
        self.switching = {"name": p["name"], "desc": p.get("description") or p["name"],
                          "prev_up": (st.get("upconverter_hz") or 0) > 0,
                          "want_up": bool(p.get("upconvert")), "since": self.clock(),
                          "muted": self.mute_prev}
        self.say("")
        self.p.switch(p["name"])

    def toggle_audio(self, s):
        if self.audio is None:
            self.say("%s %s" % (self.g.bad, self.player_hint), "err")
        elif self.audio.on:
            self.audio.stop()
            self.say("%s Stopped listening here" % self.g.stop)
        elif self.decoder(s) == "js8":
            self.say("No audio here on JS8: it goes to JS8Call. 2 or 3 to listen.")
        else:
            self.audio.start(rate_for(s["status"].get("mode")))

    def local_volume_key(self, ch):
        d = LOCAL_VOL_STEP if ch in (ord("]"), ord("}")) else -LOCAL_VOL_STEP
        v = clamp(self.local_vol + d, 0, LOCAL_VOL_MAX)
        if v == self.local_vol:
            self.say("Volume here at its %s: %d %%" % ("maximum" if d > 0 else "minimum", v))
        self.local_vol = v
        if self.audio:
            self.audio.gain = v / 100.0
        if not (self.audio and self.audio.on):
            self.say("Volume here %d %%, for when l plays the audio" % v)

    def mute_key(self, s):
        st = s["status"]
        if self.view == "digital" and self.decoder(s) == "js8":
            self.say("Not on JS8: the receiver's audio feeds JS8Call")
        elif st.get("volume") is None:
            self.not_yet()
        elif self.mute_prev is not None:
            v, self.mute_prev = self.mute_prev, None
            self.send(volume=v)
        elif st["volume"] <= 0:
            self.say("The uConsole speaker is already at 0 %; + turns it up")
        else:
            self.mute_prev = st["volume"]
            self.send(volume=0.0)

    def speaker_key(self, ch, st):
        if st.get("volume") is None:
            return self.not_yet()
        d = 1 if ch in (ord("+"), ord("=")) else -1
        base = self.mute_prev if (self.mute_prev is not None and d > 0) else st["volume"]
        v = next_volume(base, d)
        self.mute_prev = None
        if v == st["volume"]:
            self.say("Speaker at its %s: %s" % ("maximum" if d > 0 else "minimum", percent(v)))
        else:
            self.send(volume=v)

    def gain_key(self, ch, st):
        if not st:
            return self.not_yet()
        d = 1 if ch == ord("G") else -1
        g = next_gain(st.get("gains"), st.get("gain_db"), d)
        if g == st.get("gain_db"):
            self.say("Gain at its %s: %.1f dB" % ("maximum" if d > 0 else "minimum", g))
        else:
            self.send(gain_db=g)

    def digital_key(self, ch, s):
        if self.picker_key(ch, s):
            return
        if ch in (curses.KEY_PPAGE, curses.KEY_NPAGE):
            page = max(1, self.js8_page - 1)
            self.js8_scroll = max(0, self.js8_scroll + (page if ch == curses.KEY_PPAGE else -page))
        elif ch == ord("/"):
            self.entry, self.entry_kind = self.js8_filter, "filter"
        elif ch == 27:
            if self.js8_filter:
                self.js8_filter, self.js8_scroll = "", 0
        elif ch == ord("M"):
            self.mute_key(s)
        elif ch == ord("r"):
            self.report_key(s)
        elif ch in (ord("["), ord("]")) and self.decoder(s) != "js8":
            self.local_volume_key(ch)
        else:
            self.other_key(ch)

    def report_key(self, s):
        """r: WSPR reporting to WSPRnet on / off."""
        st = s["status"]
        w = st.get("wspr")
        if self.decoder(s) != "wspr" or self.mismatch(s):
            self.say("r turns WSPR reporting on and off; the receiver isn't on WSPR")
        elif not isinstance(w, dict) or not isinstance(w.get("report"), dict):
            self.not_yet()
        elif not wspr_can_report(w):
            self.say("%s Can't report: %s" % (self.g.stop, w["report"]["reason"]), "err")
        else:
            on = not w["report"].get("enabled")
            self.send(wspr_report=on)
            self.say("%s %s" % ((self.g.rx, "Reporting spots to WSPRnet") if on else
                                (self.g.stop, "Stopped reporting to WSPRnet")))

    def listen_key(self, ch, s):
        st = s["status"]
        if self.picker_key(ch, s):
            return
        controls = (ord("g"), ord("G"), ord("b"), ord("s"), ord(","), ord("."))
        if ch in controls and self.mismatch(s):
            self.say("Receiver is on %s; pick a station first (%s Enter)" % (
                st.get("profile"), self.g.keys["updown"]))
        elif ch in (ord("g"), ord("G")):
            self.gain_key(ch, st)
        elif ch == ord("b"):
            if st.get("mode") is None:
                return self.not_yet()
            bw = cycle_bandwidth(st["mode"], st.get("bandwidth"))
            if bw is None:
                self.say("No bandwidth presets for %s" % st["mode"])
            else:
                self.send(bandwidth=bw)
        elif ch in (ord("s"), ord(","), ord(".")):
            if st.get("mode") != "FM":
                self.say("Squelch is for NFM only; this is %s" % mode_label(st.get("mode")))
            elif "squelch" not in st:
                self.say("This rxd has no squelch", "err")
            else:
                send, self.sq_level, msg = squelch_key(chr(ch), st.get("squelch"), self.sq_level)
                if send is not NOSEND:
                    self.send(squelch=send)
                if msg:
                    self.say(msg)
        elif ch in (ord("-"), ord("_"), ord("+"), ord("=")):
            self.speaker_key(ch, st)
        elif ch == ord("M"):
            self.mute_key(s)
        elif ch in (ord("["), ord("]")):
            self.local_volume_key(ch)
        else:
            self.other_key(ch)

    def manual_key(self, ch, s):
        st = s["status"]
        if ch in (curses.KEY_LEFT, curses.KEY_RIGHT):
            if st.get("freq") is None:
                return self.not_yet()
            d = 1 if ch == curses.KEY_RIGHT else -1
            f = step_tune(float(st["freq"]), self.step, d)
            if f == st["freq"]:
                self.say("At the %s of rxd's range" % ("top" if d > 0 else "bottom"))
            else:
                self.send(freq=f)
        elif ch in (curses.KEY_UP, curses.KEY_DOWN):
            self.step = next_step(self.step, 1 if ch == curses.KEY_UP else -1)
        elif ch == ord("f"):
            self.entry, self.entry_kind = "", "freq"
        elif ch == ord("m"):
            if st.get("mode") is None:
                return self.not_yet()
            self.send(mode=next_mode(st["mode"]))
            self.overrides.pop("bandwidth", None)
        elif ch in (ord("["), ord("]")):
            if st.get("mode") is None:
                return self.not_yet()
            d = 1 if ch == ord("]") else -1
            bw = next_bandwidth(st["mode"], st.get("bandwidth"), d)
            if bw == st.get("bandwidth"):
                self.say("Bandwidth at its %s for %s: %s" % (
                    "widest" if d > 0 else "narrowest", st["mode"], format_hz(bw)))
            else:
                self.send(bandwidth=bw)
        elif ch in (ord("{"), ord("}")):
            self.local_volume_key(ch)
        elif ch in (ord("g"), ord("G")):
            self.gain_key(ch, st)
        elif ch in (ord("-"), ord("_"), ord("+"), ord("=")):
            self.speaker_key(ch, st)
        elif ch == ord("M"):
            self.mute_key(s)
        else:
            self.other_key(ch)

    def other_key(self, ch):
        if 32 < ch < 127:
            self.say("%s isn't a key in %s; ? lists them" % (
                chr(ch), dict(VIEWS)[self.view]))

    def not_yet(self):
        self.say("Not sent: no status from rxd yet", "err")
        return True

    def entry_key(self, ch):
        if ch in (27, 7):  # Esc, Ctrl-G
            self.entry = None
        elif ch in (10, 13, curses.KEY_ENTER):
            text, self.entry = self.entry, None
            if self.entry_kind == "filter":
                self.js8_filter, self.js8_scroll = text.strip().upper(), 0
            elif text.strip():
                try:
                    self.send(freq=parse_freq(text))
                except ValueError as e:
                    self.say(str(e), "err")
        elif ch in (curses.KEY_BACKSPACE, 127, 8):
            self.entry = self.entry[:-1]
        elif ch == 21:  # Ctrl-U
            self.entry = ""
        elif 32 <= ch < 127 and len(self.entry) < 20:
            self.entry += chr(ch)
        return True

    # ---- drawing
    def draw(self, scr):
        s = self.update()
        g, h, w = self.g, scr.h, scr.w
        if h < 10 or w < 30:
            scr.put(0, 0, "rxd-tui: too small", "err")
            scr.put(1, 0, "Needs 30x10; q quits")
            return
        st = s["status"]
        self.draw_bar(scr, s)
        bottom = h - 2           # message line; help on h - 1
        if self.view == "digital":
            self.draw_digital(scr, s, 1, bottom)
        elif self.view == "listen":
            self.draw_listen(scr, s, 1, bottom)
        elif self.view == "manual":
            self.draw_manual(scr, s, bottom)
        elif s["reachable"]:
            scr.put(h // 2, 2, "Loading profiles from rxd" + g.ellipsis, "dim")

        self.draw_message(scr, s, bottom)
        x = 1
        listening = bool(self.audio and self.audio.on)
        items = help_items(g, self.view or "manual", st.get("mode"), listening,
                           None if self.mismatch(s) else self.decoder(s),
                           wspr_can_report(st.get("wspr")))
        for text, r in help_line(w - 2, g, items):
            scr.put(h - 1, x, text, r)
            x += len(text)
        if self.show_help:
            self.draw_box(scr, self.help_lines())
        elif self.confirm is not None:
            self.draw_box(scr, self.confirm_lines(s))

    def draw_bar(self, scr, s):
        g, w = self.g, scr.w
        st = s["status"]
        sym, word, role = badge(s["reachable"], st, self.p.dropping(), g, self.switching)
        b = " %s %s " % (sym, word)
        scr.put(0, 0, " " * w, "bar")
        tabs = []
        for n, (v, name) in enumerate(VIEWS, start=1):
            on = v == self.view
            tabs.append((" %d %s%s " % (n, (g.rx + " ") if on else "", name), on))
        tabw = sum(len(t) for t, _ in tabs)
        title = " rxd  " + (self.active_name(s) or "")
        if self.url.rstrip("/") != DEFAULT_URL:
            title += "  @ " + self.url.split("//", 1)[-1]
        room = w - len(b) - 2 - tabw - 1
        if room < 6:
            tabs = [(t.replace(name, name[:1]) if not on else t, on)
                    for (t, on), (_, name) in zip(tabs, VIEWS)]
            tabw = sum(len(t) for t, _ in tabs)
            room = w - len(b) - 2 - tabw - 1
        scr.put(0, 0, clip(title, max(room, 4), g), "bar")
        x = max(room, 4) + 1
        if x + tabw <= w - len(b) - 1:
            for t, on in tabs:
                scr.put(0, x, t, "tabon" if on else "bar")
                x += len(t)
        scr.put(0, w - len(b) - 1, b, role)

    def draw_message(self, scr, s, y):
        g, w = self.g, scr.w
        st = s["status"]
        if self.entry is not None:
            if self.entry_kind == "filter":
                prompts = ("Show lines with (a callsign, or nothing for all), Enter shows, "
                           "Esc cancels: ", "Callsign, Enter filters, Esc cancels: ", "Filter: ")
            else:
                prompts = ("Frequency (7.078 MHz, 14074 kHz or 7078000 Hz), Enter tunes, "
                           "Esc cancels: ", "Frequency (MHz, kHz or Hz), Enter tunes, "
                           "Esc cancels: ", "Frequency: ")
            for prompt in prompts:
                if len(prompt) + 14 <= w:
                    break
            scr.put(y, 0, prompt, "value")
            scr.put(y, len(prompt), self.entry + "_", "key")
        elif self.message and not (self.message == WAITING and s["reachable"] is True):
            # "Waiting for rxd" is over once it answers; don't leave it up.
            scr.put(y, 1, clip(g.text(self.message), w - 2, g), self.message_role)
        elif self.switching:
            sw = self.switching
            text = "%s Switching to %s%s rxd restarts, which takes a few seconds." % (
                g.stop, sw["name"], g.ellipsis)
            if sw["want_up"] != sw["prev_up"]:
                text = "%s Switching to %s%s  %s Flip the Ham It Up to %s" % (
                    g.stop, sw["name"], g.ellipsis, g.drop, hiu_word(sw["want_up"]))
            scr.put(y, 1, clip(text, w - 2, g), "warn")
        elif s["reachable"] is False:
            scr.put(y, 1, clip("%s Can't reach rxd at %s (%s). Retrying." % (
                g.bad, self.url, s["why"]), w - 2, g), "err")
        elif st.get("error"):
            scr.put(y, 1, clip("rxd: %s" % st["error"], w - 2, g), "err")

    def draw_note(self, scr, s, y, what):
        """The note above a picker for a view the receiver isn't in."""
        g = self.g
        st = s["status"]
        p = self.active_profile(s)
        text = "Receiver is on %s%s. Pick %s to switch." % (
            st.get("profile") or "another profile",
            " (%s)" % p["description"] if p and p.get("description") else "", what)
        scr.put(y, 1, clip(g.text(text), scr.w - 2, g), "warn")

    def picker_row(self, p, s, i, top, sub):
        """(text, role, state text, state role) for one picker entry."""
        g = self.g
        st = s["status"]
        active = p.get("name") == self.active_name(s) and not self.switching
        mark = g.cursor if i == self.cursor else " "
        if active:
            state, srole = g.rx + " Active", "ok"
        elif self.switching and self.switching["name"] == p.get("name"):
            state, srole = g.stop + " Switching" + g.ellipsis, "warn"
        elif flip_needed(p, st):
            state, srole = "%s Flip Ham It Up to %s" % (g.drop, hiu_word(p.get("upconvert"))), \
                "upconv"
        else:
            state, srole = "", "label"
        text = "%s %s %s" % (mark, top, sub)
        return text, ("sel" if i == self.cursor else "value"), state, srole

    def draw_picker_rows(self, scr, rows, y0, y1):
        """rows: [(text, role, state, srole)] or ("group", title); kept in view of the cursor."""
        w = scr.w
        n = y1 - y0
        if n <= 0:
            return
        cur = next((i for i, r in enumerate(rows) if r[0] != "group" and r[1] == "sel"), 0)
        first = 0
        if len(rows) > n:
            first = clamp(cur - n // 2, 0, len(rows) - n)
            if first > 0 and rows[first - 1][0] == "group" and cur - first < n - 1:
                first -= 1
        for k, r in enumerate(rows[first:first + n]):
            y = y0 + k
            if r[0] == "group":
                scr.put(y, 1, self.g.text(r[1]), "head")
                continue
            text, role, state, srole = r
            state = self.g.text(state)
            sx = max(w - len(state) - 2, w // 2) if state else w - 1
            body = clip(text, (sx - 2 if state else w - 3), self.g)
            scr.put(y, 1, body.ljust(min(sx - 2, w - 3)) if role == "sel" else body, role)
            if state and sx < w - 2:
                scr.put(y, sx, clip(self.g.text(state), w - sx - 1, self.g), srole)
        if first > 0:
            scr.put(y0, w - 2, self.g.keys["up"][:1], "label")
        if first + n < len(rows):
            scr.put(y1 - 1, w - 2, self.g.keys["down"][:1], "label")

    def draw_digital(self, scr, s, y, bottom):
        """The Digital view: the picker, the receiver and clock, then JS8's decodes
        or WSPR's cycle, reporting and spots, whichever the receiver decodes."""
        g, w = self.g, scr.w
        st = s["status"]
        mis = self.mismatch(s)
        if mis:
            self.draw_note(scr, s, y, "a JS8 or WSPR frequency")
            y += 2
        items = self.picker(s)
        if not items:
            scr.put(y, 2, g.text(self.picker_empty(s)), "dim")
            y += 2
        else:
            rows, i = [], 0
            for title, members in group_digital(self.profile_list(s)):
                rows.append(("group", title))
                for p in members:
                    sub = "%s%s %s" % (p.get("description") or "",
                                       " " + g.dot if p.get("description") else "",
                                       short_mhz(p.get("freq") or 0))
                    rows.append(self.picker_row(p, s, i, "%-10s" % p.get("name"), sub.strip()))
                    i += 1
            room = bottom - y
            n = min(len(rows), room - 1 if mis else
                    min(max(2, room // 3), 8 if room >= 30 else 5))
            self.draw_picker_rows(scr, rows, y, y + n)
            y += n + 1
        if mis:
            return
        dec = self.decoder(s)
        wspr = dec == "wspr"
        lines = s["wspr"] if wspr else s["js8"]

        def put(y, x, text, role=""):
            if y < bottom:
                scr.put(y, x, text, role)
        # status: Ham It Up, receiver, level, stations heard
        sym, word, role = badge(s["reachable"], st, self.p.dropping(), g, self.switching)
        x = 1
        up = st.get("upconverter_hz")
        parts = [("Ham It Up ", "label"),
                 (hiu_word(up > 0) if up is not None else "---",
                  "upconv" if up else "value"),
                 ("   ", ""), ("%s %s" % (sym, word), role), ("   Signal ", "label")]
        lvl = st.get("level_dbfs")
        parts.append(("%.1f dBFS" % lvl if lvl is not None else "--- dBFS", "value"))
        heard = stations_heard(lines, "call" if wspr else "from")
        tail = "%d station%s heard" % (heard, "" if heard == 1 else "s")
        used = sum(len(t) for t, _ in parts)
        barw = clamp(w - used - len(tail) - 8, 0, 20)
        if barw >= 4:
            parts += [(" ", ""), (level_bar(lvl, barw, g), "spec")]
        parts += [("   ", ""), (tail, "value")]
        for t, r in parts:
            put(y, x, t[:max(0, w - 1 - x)], r)
            x += len(t)
        y += 1
        ctext, crole = clock_words(st.get("clock"), g, "WSPR" if wspr else "JS8")
        if crole == "bad":
            put(y, 0, " " * w, "bad")
            put(y, 1, clip(ctext + ". Check chrony and the GPS.", w - 2, g), "bad")
        else:
            put(y, 1, clip(ctext, w - 2, g), crole)
        y += 1
        if wspr:
            y = self.draw_wspr_status(scr, st.get("wspr"), y, bottom)
        if self.audio and self.audio.on and y < bottom:
            y = self.draw_audio_row(scr, y)
        y += 1 if bottom - y > 8 else 0
        # decodes or spots
        if wspr:
            header, key = WSPR_HEADER, wspr_key
        else:
            header, key = JS8_HEADER, js8_key
        shown = line_filter(lines, self.js8_filter, key)
        area = bottom - y - 1
        self.js8_page = max(area, 1)
        prof = st.get("profile")
        if self.js8_seen and self.js8_seen[0] == prof and self.js8_scroll:
            self.js8_scroll += max(0, len(shown) - self.js8_seen[1])  # stay put as lines arrive
        self.js8_seen = (prof, len(shown))
        self.js8_scroll = clamp(self.js8_scroll, 0, max(0, len(shown) - area))
        if y >= bottom:
            return
        info = ""
        if self.js8_filter:
            info = "Filter %s: %d of %d  (Esc clears)" % (
                self.js8_filter, len(shown), len(lines))
        if self.js8_scroll:
            info = ("%s %d back, PgDn for newest" % (g.drop, self.js8_scroll)) + \
                ("   " + info if info else "")
        scr.put(y, 1, clip(header, w - 2, g), "head")
        if info:
            scr.put(y, max(len(header) + 3, w - len(info) - 2),
                    clip(info, w - len(header) - 5, g), "warn" if self.js8_scroll else "label")
        y += 1
        if area <= 0:
            return
        if not shown:
            state = s["wspr_state"] if wspr else s["js8_state"]
            what = "spots" if wspr else "decodes"
            if state == "missing":
                text = "%s This rxd has no %s feed." % (g.bad, "WSPR" if wspr else "JS8")
            elif str(state).startswith("error"):
                text = "%s No %s: %s" % (g.bad, what, state[7:])
            elif self.js8_filter and lines:
                text = "No lines with %s. / changes the filter, Esc clears it." % self.js8_filter
            elif wspr:
                text = "No spots yet. They appear here as each two-minute slot is decoded."
            else:
                text = "No decodes yet. They appear here as JS8Call hears them."
            scr.put(y, 2, clip(text, w - 3, g), "dim")
            return
        end = len(shown) - self.js8_scroll
        view = shown[max(0, end - area):end]
        call = st.get("js8_call")
        for i, line in enumerate(view):
            if wspr:
                scr.put(y + i, 1, format_wspr(line, st.get("freq"), w - 2, g))
                continue
            text, mine = format_js8(line, call, w - 2, g)
            scr.put(y + i, 1, text.ljust(w - 2) if mine else text, "mine" if mine else "")

    def draw_wspr_status(self, scr, wsp, y, bottom):
        """WSPR's cycle, last slot, reporting and any error; returns the next row."""
        g, w = self.g, scr.w

        def put(text, role):
            if y < bottom:
                scr.put(y, 1, clip(g.text(text), w - 2, g), role)
        if not isinstance(wsp, dict):
            put("%s Waiting for the WSPR decoder" % g.wait, "dim")
            return y + 1
        ctext, crole = wspr_cycle(wsp, g)
        last = wspr_last(wsp)
        if len(ctext) + 3 + len(last) <= w - 2:
            put(ctext, crole)
            if y < bottom:
                scr.put(y, 1 + len(ctext) + 3, last, "value")
            y += 1
        else:
            put(ctext, crole)
            y += 1
            put(last, "value")
            y += 1
        put(*wspr_report_words(wsp, g))
        y += 1
        if wsp.get("error"):
            put("%s %s" % (g.bad, wsp["error"]), "err")
            y += 1
        return y

    def draw_listen(self, scr, s, y, bottom):
        g, w, h = self.g, scr.w, scr.h
        st = s["status"]
        stale = not s["reachable"]
        mis = self.mismatch(s)
        if mis:
            self.draw_note(scr, s, y, "a station")
            y += 2
        else:
            p = self.active_profile(s)
            name = (p.get("description") if p else None) or st.get("profile") or "---"
            num, unit = station_freq(st["freq"], st.get("mode")) if st.get("freq") else ("-.-", "MHz")
            scale = 2 if (w >= 120 and h >= 36) else 1
            big = big_text(num, scale, g)
            bigw = len(big[0])
            y += 1 if h >= 22 else 0
            sub = "%s   %s" % (unit, mode_label(st.get("mode")))
            grp = dict(GROUPS).get(st.get("mode"))
            if grp:
                sub += "   " + g.text(grp)
            if h >= 20 and bigw + 30 <= w:
                for i, line in enumerate(big):
                    scr.put(y + i, 2, line, "dim" if stale else "big")
                sx = 2 + bigw + 3
                rows = [0, 1, 2] if len(big) == 3 else [0, 2, 4]
                scr.put(y + rows[0], sx, clip(name, w - sx - 1, g), "value")
                scr.put(y + rows[1], sx, clip(sub, w - sx - 1, g), "label")
                scr.put(y + rows[2], sx, clip(st.get("profile") or "", w - sx - 1, g), "dim")
                y += len(big) + 1
            else:
                scr.put(y, 1, clip("%s  %s %s  %s" % (name, num, unit, mode_label(st.get("mode"))),
                                   w - 2, g), "dim" if stale else "big")
                y += 1
            # signal and Ham It Up
            lvl = st.get("level_dbfs")
            scr.put(y, 1, "Signal", "label")
            scr.put(y, 8, "%6.1f dBFS" % lvl if lvl is not None else "  --- dBFS", "value")
            up = st.get("upconverter_hz")
            hiu = "Ham It Up " + (hiu_word(up > 0) if up is not None else "---")
            barw = clamp(w - 20 - len(hiu) - 4, 4, 40)
            scr.put(y, 20, level_bar(lvl, barw, g), "spec")
            scr.put(y, 20 + barw + 3, "Ham It Up ", "label")
            scr.put(y, 20 + barw + 13, hiu[10:], "upconv" if up else "value")
            y += 1
            # gain, bandwidth, speaker
            gain = st.get("gain_db")
            bw = st.get("bandwidth")
            vol = st.get("volume")
            if self.mute_prev is not None:
                spk = "Muted (M restores %s)" % percent(self.mute_prev)
            else:
                spk = percent(vol) if vol is not None else "---"
            fields = [("Gain", "%.1f dB" % gain if gain is not None else "---"),
                      ("Bandwidth", "%s %s" % (bandwidth_name(st.get("mode"), bw), format_hz(bw))
                       if bw else "---"),
                      ("Speaker", spk)]
            x = 1
            for label, val in fields:
                if x + len(label) + len(val) + 1 > w - 1:
                    break
                scr.put(y, x, label, "label")
                scr.put(y, x + len(label) + 1, val, "warn" if label == "Speaker" and
                        self.mute_prev is not None else "value")
                x += len(label) + len(val) + 5
            y += 1
            if st.get("mode") == "FM" and "squelch" in st:
                text, role = squelch_words(st, g)
                scr.put(y, 1, "Squelch", "label")
                scr.put(y, 9, text, role)
                y += 1
            y = self.draw_audio_row(scr, y)
            y += 1
        # the station picker
        items = self.picker(s)
        if not items:
            scr.put(y, 2, g.text(self.picker_empty(s)), "dim")
            return
        rows, i = [], 0
        for title, members in group_stations(self.profile_list(s)):
            rows.append(("group", title))
            for p in members:
                desc = p.get("description") or p.get("name")
                num, unit = station_freq(p.get("freq") or 0, p.get("mode"))
                rows.append(self.picker_row(p, s, i, "%-22s" % clip(desc, 22, g),
                                            "%7s %-3s  %s" % (num, unit, mode_label(p.get("mode")))))
                i += 1
        self.draw_picker_rows(scr, rows, y, bottom)

    def draw_audio_row(self, scr, y, x=1):
        g = self.g
        if self.audio is None:
            scr.put(y, x, clip("%s No audio player: %s" % (g.bad, self.player_hint.split(". ", 1)[-1]),
                               scr.w - x - 1, g), "bad")
            return y + 1
        sym, text, role = self.audio.words(g)
        text = "%s %s" % (sym, text)
        if self.audio.on:
            text += "   Volume here %d %%" % self.local_vol
        else:
            text += ": l plays the audio here"
        scr.put(y, x, clip(text, scr.w - x - 1, g), role)
        return y + 1

    def draw_manual(self, scr, s, bottom):
        st, spec, hist = s["status"], s["spectrum"], s["history"]
        reachable, spec_state = s["reachable"], s["spec_state"]
        g, h, w = self.g, scr.h, scr.w
        stale = not reachable
        # big frequency, with mode, bandwidth and step beside it
        freq = st.get("freq")
        ftext = format_mhz(freq) if freq is not None else "-.--- ---"
        scale = 2 if (w >= 120 and h >= 36) else 1
        big = big_text(ftext, scale, g)
        y = 2 if h >= 20 else 1
        side = ["%s" % (st.get("mode") or "---"),
                "Bandwidth " + (format_hz(st["bandwidth"]) if st.get("bandwidth") else "---"),
                "Step " + format_hz(self.step)]
        bigw = len(big[0])
        if h >= 20 and bigw + 26 <= w:
            x0 = 2
            for i, line in enumerate(big):
                scr.put(y + i, x0, line, "dim" if stale else "big")
            scr.put(y + len(big) - 1, x0 + bigw + 2, "MHz", "label")
            sx = x0 + bigw + 8
            rows = [0, 1, 2] if len(big) == 3 else [0, 2, 4]
            scr.put(y + rows[0], sx, " %s " % side[0], "key")
            scr.put(y + rows[1], sx, side[1], "value")
            scr.put(y + rows[2], sx, side[2], "value")
            y += len(big) + 1
        else:
            scr.put(y, 1, ftext + " MHz", "dim" if stale else "big")
            scr.put(y, len(ftext) + 7, "  ".join([" %s " % side[0]] + side[1:]), "value")
            y += 2 if h >= 16 else 1

        # Ham It Up, gain, volume
        up = st.get("upconverter_hz")
        x = 1
        scr.put(y, x, "Ham It Up switch:", "label")
        x += 18
        if up is None:
            sw, srole = "---", "value"
        elif up > 0:
            sw, srole = "UPCONVERT (%s)" % format_hz(up), "upconv"
        else:
            sw, srole = "BYPASS", "value"
        scr.put(y, x, sw, srole)
        x += len(sw) + 4
        gain = st.get("gain_db")
        if self.mute_prev is not None:
            spk = "Muted"
        else:
            spk = percent(st["volume"]) if st.get("volume") is not None else "---"
        for label, val in (("Gain", "%.1f dB" % gain if gain is not None else "---"),
                           ("Speaker", spk)):
            if x + len(label) + len(val) + 2 > w:
                break
            scr.put(y, x, label, "label")
            scr.put(y, x + len(label) + 1, val, "value")
            x += len(label) + len(val) + 5
        y += 1

        # signal level, the audio here when it's on, and the receiver's health when there is room
        lvl = st.get("level_dbfs")
        scr.put(y, 1, "Signal", "label")
        ltext = "%6.1f dBFS" % lvl if lvl is not None else "  --- dBFS"
        scr.put(y, 8, ltext, "value")
        extra, erole = "", "label"
        if self.audio and self.audio.on:
            sym, text, erole = self.audio.words(g)
            extra = "%s %s" % (sym, text)
        elif w >= 110 and st:
            extra = "DSP %d%%   Dropped %d" % (round((st.get("dsp_cpu") or 0) * 100),
                                              st.get("dropped") or 0)
        barw = clamp(w - 21 - (len(extra) + 4 if extra else 0), 4, 60)
        scr.put(y, 20, level_bar(lvl, barw, g), "spec")
        if extra:
            scr.put(y, 20 + barw + 3, clip(extra, w - barw - 24, g), erole)
        y += 2 if h >= 30 else 1

        # spectrum, markers and waterfall
        avail = bottom - y
        if avail >= 3:
            self.draw_spectrum(scr, y, avail, w, spec, hist, reachable, spec_state)

    def draw_spectrum(self, scr, y, avail, w, spec, hist, reachable, spec_state):
        g = self.g
        if not spec:
            text = {"missing": "No spectrum: this rxd has no /api/spectrum",
                    "waiting": "Waiting for the spectrum from rxd"}.get(spec_state)
            if not reachable:
                text = "No spectrum: rxd not reachable"
            scr.put(y + avail // 2, max(0, (w - len(text)) // 2), text, "dim")
            return
        start, stop = float(spec["start_hz"]), float(spec["stop_hz"])
        cols = resample(spec["bins"], start, stop, w)
        lo, hi = db_range(cols)
        if self.lo is None:
            self.lo, self.hi = lo, hi
        else:  # ease the scale so the picture doesn't jump
            self.lo += (lo - self.lo) * 0.2
            self.hi += (hi - self.hi) * 0.2
        rows = clamp(avail // 3, 1, 12)
        wf_rows = avail - 2 - rows
        scr.put(y, 0, axis_row(w, start, stop), "label")
        for i, line in enumerate(render_spectrum(cols, rows, self.lo, self.hi, g)):
            scr.put(y + 1 + i, 0, line, "spec")
        scr.put(y + 1 + rows, 0, marker_row(w, start, stop, spec.get("dial_hz"),
                                            spec.get("passband"), g), "marker")
        # Resampling is most of the drawing time; each row is done once per size.
        cache = {}
        for i, (s0, s1, bins) in enumerate(hist[:max(wf_rows, 0)]):
            key = (id(bins), w, start, stop)
            hit = self.wf_cache.get(key)
            cols_i = hit[1] if hit and hit[0] is bins else resample(bins, s0, s1, w, start, stop)
            cache[key] = (bins, cols_i)
            scr.put(y + 2 + rows + i, 0, render_waterfall_row(cols_i, self.lo, self.hi, g), "wf")
        self.wf_cache = cache

    def help_lines(self):
        k = self.g.keys
        ud = k["updown"]
        views = ["1 2 3     Digital, Listen or Manual view"]
        if self.view == "digital":
            body = [
                "rxd-tui: Digital (JS8 and WSPR)",
                "",
                "%-9s pick a JS8 or WSPR frequency; Enter switches" % ud,
                "PgUp PgDn scroll back through the decodes or spots",
                "          / forward",
                "/         show only lines with a callsign; Esc",
                "          shows them all again",
                "r         WSPR: report spots to WSPRnet / stop",
                "l         play the audio on this machine / stop",
                "          (not on JS8: its audio goes to JS8Call)",
                "[ ]       volume of the audio here",
            ] + views + [
                "",
                "%s marks JS8 lines to your callsign. JS8 and WSPR" % self.g.mine,
                "need the clock right to about a second, so the",
                "clock's state is shown under the receiver's.",
                "Times are this machine's local time.",
            ]
        elif self.view == "listen":
            body = [
                "rxd-tui: Listen",
                "",
                "%-9s pick a station; Enter switches" % ud,
                "g G       gain down / up through the dongle's steps",
                "b         bandwidth: Narrow, Normal, Wide",
                "s         squelch off / on (NFM only)",
                ", .       squelch level down / up, 2 dB a press",
                "- +       uConsole speaker volume down / up",
                "M         mute the uConsole speaker / restore it",
                "l         play the audio on this machine / stop",
                "[ ]       volume of the audio here",
            ] + views
        else:
            body = [
                "rxd-tui: Manual",
                "",
                "%-9s tune down / up by the step" % (k["left"] + " " + k["right"]),
                "%-9s larger / smaller step: 10 Hz to 1 MHz" % (k["up"] + " " + k["down"]),
                "f         type a frequency and press Enter:",
                "            7.078 or 146.52 is MHz, 14074 is kHz,",
                "            7078000 is Hz; 7078k and 7.078M work too",
                "m         next mode: USB LSB AM FM WFM",
                "[ ]       narrower / wider bandwidth",
                "g G       gain down / up through the dongle's steps",
                "- +       uConsole speaker volume down / up (0-400 %)",
                "M         mute the uConsole speaker / restore it",
                "l         play the audio on this machine / stop",
                "{ }       volume of the audio here",
            ] + views
        return body + [
            "?         this help",
            "q         quit (Ctrl-C works too)",
            "",
            "Ham It Up: the UPCONVERT/BYPASS switch on the box is",
            "physical. rxd only says which way it should be; the",
            "wrong way gives silence.",
            "",
            "Any key closes this.",
        ]

    def confirm_lines(self, s):
        p = self.confirm
        lines = ["Switch to %s?" % p["name"], ""]
        if p.get("description"):
            lines[0] = "Switch to %s (%s)?" % (p["name"], p["description"])
        lines += ["Leaving %s closes JS8Call. rxd restarts," % self.active_name(s),
                  "which takes a few seconds."]
        if flip_needed(p, s["status"]):
            lines += ["", "%s Then flip the Ham It Up to %s." % (self.g.drop,
                                                                 hiu_word(p.get("upconvert")))]
        return lines + ["", "y switches; any other key stays."]

    def draw_box(self, scr, lines):
        lines = [self.g.text(x) for x in lines]
        bw = min(max(len(x) for x in lines) + 4, scr.w)
        bh = len(lines) + 2
        if bh > scr.h:
            lines = [x for x in lines if x][:scr.h - 2]
            bh = len(lines) + 2
        y0 = max(0, (scr.h - bh) // 2)
        x0 = max(0, (scr.w - bw) // 2)
        for i in range(bh):
            scr.put(y0 + i, x0, " " * bw, "bar")
        for i, x in enumerate(lines):
            scr.put(y0 + 1 + i, x0 + 2, x[:bw - 4], "bar")


# --------------------------------------------------------------------- main

ESCAPES = {"[A": curses.KEY_UP, "OA": curses.KEY_UP, "[B": curses.KEY_DOWN,
           "OB": curses.KEY_DOWN, "[C": curses.KEY_RIGHT, "OC": curses.KEY_RIGHT,
           "[D": curses.KEY_LEFT, "OD": curses.KEY_LEFT, "[5~": curses.KEY_PPAGE,
           "[6~": curses.KEY_NPAGE, "OM": 10}


def read_escape(win):
    """A key whose sequence curses didn't recognise (the terminal not in the
    keypad mode terminfo expects), Esc on its own, or None for anything else."""
    win.nodelay(True)
    seq = ""
    try:
        while len(seq) < 8:
            c = win.getch()
            if c == -1:
                break
            seq += chr(c) if c < 256 else "?"
            if len(seq) >= 2 and (seq[-1].isalpha() or seq[-1] == "~"):
                break
    finally:
        win.nodelay(False)
        win.timeout(100)
    if not seq:
        return 27
    return ESCAPES.get(seq)


def run(stdscr, app, color):
    try:
        curses.curs_set(0)
    except curses.error:
        pass
    if curses.has_colors():
        # curses.wrapper has started colour; keep the terminal's own
        # foreground and background either way, so NO_COLOR draws no colour.
        try:
            curses.use_default_colors()
        except curses.error:
            color = False
    else:
        color = False
    stdscr.keypad(True)
    stdscr.timeout(100)
    app.p.start()
    dirty = True
    while True:
        if dirty or app.p.changed.is_set():
            app.p.changed.clear()
            stdscr.erase()
            app.draw(CursesScreen(stdscr, color))
            stdscr.noutrefresh()
            curses.doupdate()
            dirty = False
        ch = stdscr.getch()
        if ch == -1:
            if app.switching or (app.audio and app.audio.on):
                dirty = True  # the switch's timeout and the audio's state move on their own
            continue
        dirty = True
        if ch == 27:
            ch = read_escape(stdscr)
            if ch is None:
                continue
        if ch == curses.KEY_RESIZE:
            curses.update_lines_cols()
            stdscr.clear()
            continue
        if not app.key(ch):
            return


def main(argv=None):
    ap = argparse.ArgumentParser(prog="rxd-tui", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", default=os.environ.get("RXD_URL", DEFAULT_URL),
                    help="rxd's HTTP API (default $RXD_URL or %s)" % DEFAULT_URL)
    ap.add_argument("--ascii", action="store_true",
                    help="plain ASCII, no Unicode block characters")
    ap.add_argument("--listen", action="store_true",
                    help="start with the audio playing on this machine")
    ap.add_argument("--player", metavar="CMD",
                    help="the command that plays raw s16le mono PCM from stdin; "
                         "{rate} becomes the sample rate (default: the first of %s on PATH)"
                         % ", ".join(PLAYERS))
    a = ap.parse_args(argv)
    try:
        locale.setlocale(locale.LC_ALL, "")
    except locale.Error:
        # A locale the machine doesn't have, usually forwarded over SSH
        # (macOS sends LC_CTYPE=UTF-8). curses still needs UTF-8 to draw.
        for name in ("C.UTF-8", "C.utf8"):
            try:
                locale.setlocale(locale.LC_ALL, name)
                break
            except locale.Error:
                pass
    os.environ.setdefault("ESCDELAY", "25")  # Esc cancels typing without a pause
    url = a.url if "//" in a.url else "http://" + a.url
    poller = Poller(Link(url))
    if a.player:
        try:
            player = Player.custom(a.player)
        except ValueError as e:
            ap.error(str(e))
    else:
        found = find_player()
        player = Player.found(*found) if found else None
    audio = AudioPlayer(url, player, poller.changed) if player else None
    app = App(poller, Glyphs(a.ascii or not unicode_ok()), url, audio, listen=a.listen)
    if a.listen and not audio:
        app.say("%s %s" % (app.g.bad, app.player_hint), "err")
    try:
        curses.wrapper(run, app, use_color())
    except KeyboardInterrupt:
        pass
    finally:
        poller.stop()
        app.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
RXDTUI
    log "installed rxd-tui"

    # The browser UI, served by rxd at / on its HTTP port.
    run install -d -m 0755 /usr/local/share/rxd
    write_file /usr/local/share/rxd/index.html 0644 <<'RXDWEB'
<!DOCTYPE html>
<html lang="en" data-theme="auto">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#f4f4f2">
<title>rxd</title>
<script>
try { var t = localStorage.getItem("rxd.theme");
  if (["auto", "light", "dark", "night"].indexOf(t) >= 0) document.documentElement.dataset.theme = t;
} catch (e) {}
</script>
<style>
:root{
  --bg:#f4f4f2;--panel:#fff;--fg:#111;--dim:#555;--line:#c4c4bf;--accent:#0b57c9;--accent-fg:#fff;
  --ok:#14713f;--warn:#9a5200;--bad:#b3261e;--plot:#fcfcfb;--grid:#e3e3df;--trace:#0b57c9;
  --pass:rgba(11,87,201,.14);--mark:#c2185b;color-scheme:light;
}
@media (prefers-color-scheme:dark){:root[data-theme=auto]{
  --bg:#111214;--panel:#1d1e21;--fg:#f2f2f2;--dim:#a8a8a8;--line:#3c3d42;--accent:#4c9dff;--accent-fg:#000;
  --ok:#4fd27d;--warn:#ffb02e;--bad:#ff6b5e;--plot:#0a0a0b;--grid:#25262a;--trace:#74b6ff;
  --pass:rgba(76,157,255,.18);--mark:#ff6fa8;color-scheme:dark}}
:root[data-theme=dark]{
  --bg:#111214;--panel:#1d1e21;--fg:#f2f2f2;--dim:#a8a8a8;--line:#3c3d42;--accent:#4c9dff;--accent-fg:#000;
  --ok:#4fd27d;--warn:#ffb02e;--bad:#ff6b5e;--plot:#0a0a0b;--grid:#25262a;--trace:#74b6ff;
  --pass:rgba(76,157,255,.18);--mark:#ff6fa8;color-scheme:dark}
:root[data-theme=night]{
  --bg:#000;--panel:#140000;--fg:#ff3b2f;--dim:#b8281f;--line:#4a0e09;--accent:#ff3b2f;--accent-fg:#000;
  --ok:#ff3b2f;--warn:#ff3b2f;--bad:#ff3b2f;--plot:#000;--grid:#2a0604;--trace:#ff3b2f;
  --pass:rgba(255,40,20,.20);--mark:#ff2a10;color-scheme:dark}
*{box-sizing:border-box}
[hidden]{display:none!important}
html{background:var(--bg);color:var(--fg);scrollbar-color:var(--line) var(--bg)}
body{margin:0;background:var(--bg);color:var(--fg);font:18px/1.3 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
  font-variant-numeric:tabular-nums;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);
  -webkit-text-size-adjust:100%}
::selection{background:var(--accent);color:var(--accent-fg)}
button,input{font:inherit;color:inherit}
:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
.wrap{max-width:1400px;margin:0 auto;padding:10px 12px 16px;display:grid;gap:10px}
header{display:flex;align-items:center;gap:10px;min-height:44px}
header .id{flex:1;min-width:0;display:flex;align-items:baseline;gap:10px;font-size:22px;font-weight:700;white-space:nowrap;overflow:hidden}
#profile{overflow:hidden;text-overflow:ellipsis}
.tag{font-size:17px;font-weight:700;border:2px solid var(--fg);border-radius:6px;padding:0 6px}
.app{color:var(--dim);font-weight:600}
.pill{font-size:17px;font-weight:600;white-space:nowrap}
.ok{color:var(--ok)}.warn{color:var(--warn)}.bad{color:var(--bad)}.dimc{color:var(--dim)}
.jclock{grid-column:1/-1;margin:4px 0 0}
.banner{border:2px solid var(--bad);color:var(--bad);background:var(--panel);border-radius:10px;padding:12px 14px;font-weight:700;font-size:19px}
.hiu{border:2px solid var(--accent);border-radius:10px;padding:10px 14px;display:flex;flex-wrap:wrap;align-items:baseline;gap:4px 12px;background:var(--panel)}
.hiu b{font-size:22px}
.hiu.up{background:var(--accent);color:var(--accent-fg);border-color:var(--accent)}
:root[data-theme=night] .hiu.up{background:#3d0804;color:var(--fg);border-width:3px}
.hiu span{font-size:16px}
.hiu.stale{opacity:.55}
input:disabled{opacity:.45}
.stats{display:grid;grid-template-columns:1fr;background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:4px 12px}
.stat{display:flex;justify-content:space-between;align-items:baseline;gap:10px;padding:3px 0;min-width:0}
.stat+.stat{border-top:1px solid var(--line)}
.stat .v{text-align:right}
@media (min-width:600px){.stats{grid-template-columns:repeat(3,1fr);background:none;border:0;padding:0;gap:8px}
.stat,.stat+.stat{display:block;background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:6px 10px}.stat .v{text-align:left}}
.k{display:block;font-size:15px;color:var(--dim);font-weight:600;letter-spacing:.02em}
.v{display:block;font-size:18px;font-weight:650;overflow-wrap:anywhere}
fieldset{border:0;margin:0;padding:0;min-width:0}
fieldset:disabled .live{opacity:.45}
.layout{display:grid;gap:10px;grid-template-columns:minmax(0,1fr);grid-template-areas:"tuner" "scope" "modes" "sliders"}
.card{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px;min-width:0}
.tuner{grid-area:tuner}.scope{grid-area:scope}.modes{grid-area:modes}.sliders{grid-area:sliders}
.lbl{display:flex;justify-content:space-between;gap:8px;font-size:15px;color:var(--dim);font-weight:600}
.freq{font-size:clamp(40px,13.2vw,76px);font-weight:700;line-height:1.05;letter-spacing:-.01em;white-space:nowrap;margin:2px 0 6px;cursor:ns-resize}
.freq .hz{font-size:.72em;color:var(--dim);margin-left:.18em}
.meter{display:grid;grid-template-columns:1fr auto;align-items:center;gap:4px 12px;margin-bottom:10px}
.mbar{height:14px;border:1px solid var(--line);border-radius:7px;overflow:hidden;background:var(--bg)}
.mbar i{display:block;height:100%;width:0;background:var(--accent)}
.mnum{font-size:22px;font-weight:700;min-width:6.5em;text-align:right}
.mscale{grid-column:1;display:flex;justify-content:space-between;font-size:13px;color:var(--dim)}
.btn{min-height:56px;border:2px solid var(--line);background:var(--bg);border-radius:10px;font-weight:700;font-size:20px;
  cursor:pointer;touch-action:manipulation;padding:4px 8px}
.btn[aria-pressed=true]{background:var(--accent);border-color:var(--accent);color:var(--accent-fg)}
.btn:disabled{cursor:default;opacity:.45}
@media (hover:hover){.btn:not(:disabled):hover{border-color:var(--accent)}}
.row2{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.steps{display:grid;grid-template-columns:repeat(7,1fr);gap:5px;margin:8px 0}
.steps .btn{font-size:17px;line-height:1.05;padding:2px;min-width:0}
.steps .btn small{display:block;font-size:13px;font-weight:600}
form{display:grid;grid-template-columns:1fr auto;gap:8px}
input[type=text]{min-height:56px;border:2px solid var(--line);border-radius:10px;background:var(--bg);padding:0 12px;font-size:22px;width:100%;min-width:0}
input[type=text]::placeholder{color:var(--dim);opacity:1}
.msg{margin:8px 0 0;font-weight:700;color:var(--bad);font-size:17px}
.hint{font-size:14px;color:var(--dim);margin:8px 0 0;display:none}
@media (hover:hover) and (pointer:fine){.hint{display:block}}
.scope{display:flex;flex-direction:column;gap:6px}
canvas[hidden]{display:none}
canvas{display:block;width:100%;border-radius:6px;cursor:crosshair;touch-action:manipulation;background:var(--plot)}
#spec{height:150px}#wf{height:150px}
.mgrid{display:grid;grid-template-columns:repeat(5,1fr);gap:6px;margin-top:6px}
.sl{margin-top:4px}.sl+.sl{margin-top:10px}
.sl .lbl .val{color:var(--fg);font-size:19px}
input[type=range]{-webkit-appearance:none;appearance:none;width:100%;height:56px;background:transparent;margin:0;cursor:pointer;touch-action:pan-y;--p:0%}
input[type=range]::-webkit-slider-runnable-track{height:10px;border-radius:5px;background:linear-gradient(to right,var(--accent) var(--p),var(--line) var(--p))}
input[type=range]::-moz-range-track{height:10px;border-radius:5px;background:linear-gradient(to right,var(--accent) var(--p),var(--line) var(--p))}
input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:34px;height:34px;margin-top:-12px;border-radius:50%;background:var(--panel);border:4px solid var(--accent)}
input[type=range]::-moz-range-thumb{width:26px;height:26px;border-radius:50%;background:var(--panel);border:4px solid var(--accent)}
.appear{display:grid;grid-template-columns:repeat(4,1fr);gap:6px;margin-top:6px;max-width:620px}
.appear .btn{font-size:17px;padding:2px}
@media (min-width:900px){
  .wrap{padding:14px 20px 20px}
  .top{display:grid;grid-template-columns:minmax(0,1.2fr) minmax(0,1fr);gap:10px}
  .layout{grid-template-columns:minmax(380px,460px) minmax(0,1fr);grid-template-areas:"tuner scope" "modes scope" "sliders scope"}
  .scope{grid-row:1/4}
  #spec{height:240px}#wf{flex:1;min-height:240px}
  .freq{font-size:64px}
}
.top{display:grid;gap:10px}
.banner .sub{display:block;font-weight:600;font-size:16px;color:var(--dim);margin-top:4px}
.banner.sw{border-color:var(--accent);color:var(--fg)}
.banner.flip{border-color:var(--warn);color:var(--fg);display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:8px 12px}
.banner .btn{font-size:18px;padding:4px 14px}
.views{display:grid;grid-template-columns:repeat(3,1fr);gap:6px}
.views .btn{font-size:19px}
.views .btn small{display:block;font-size:13px;font-weight:600}
.nname{font-size:clamp(30px,9vw,44px);font-weight:750;line-height:1.1;margin:2px 0;overflow-wrap:anywhere}
.nfreq{font-size:24px;font-weight:650;color:var(--dim);margin-bottom:10px}
.row3{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin:6px 0 4px}
.row3 .btn{font-size:18px;line-height:1.1;padding:2px}
.row3 .btn small{display:block;font-size:14px;font-weight:600}
#sqLv{margin-top:8px}
.pgroup{font-size:15px;color:var(--dim);font-weight:700;margin:12px 0 0}
.pgroup:first-child{margin-top:4px}
.jstat{display:grid;grid-template-columns:1fr 1fr;gap:4px 12px;padding:8px 12px}
@media (min-width:700px){.jstat{grid-template-columns:repeat(5,auto);justify-content:space-between}}
.wrap>*{order:0}
body[data-view=manual] #aPick,body[data-view=manual] #js8,body[data-view=manual] #wspr,body[data-view=manual] #listenCard{order:1}
body[data-view=digital] #listenCard,body[data-view=digital] #js8,body[data-view=digital] #wspr{order:1}
body[data-view=manual] #pmsg,#appear0{order:2}
body[data-view=digital] .jlist{max-height:none;overflow:visible}
@media (min-width:900px){
  body[data-view=listen] .wrap,body[data-view=digital] .wrap{max-width:1100px}
  body[data-view=listen] .wrap{grid-template-columns:minmax(0,1fr) minmax(0,1fr);align-items:start;grid-auto-flow:row dense}
  body[data-view=listen] .wrap>*{grid-column:1/-1}
  body[data-view=listen] #now,body[data-view=listen] .top,body[data-view=listen] #listenCard,body[data-view=listen] #qual{grid-column:1}
  body[data-view=listen] #lPick{grid-column:2;grid-row:span 4}
  body[data-view=listen] .top{grid-template-columns:1fr}
}
.btn.big{width:100%;min-height:72px;font-size:22px;margin-top:6px}
.btn.wide{width:100%;margin-top:8px;font-size:18px}
.btn.pri{background:var(--accent);border-color:var(--accent);color:var(--accent-fg)}
.astate{margin:8px 0 0;font-weight:700;font-size:19px}
.note{font-size:14px;color:var(--dim);margin:8px 0 0}
.plist{display:grid;gap:8px;margin-top:6px;grid-template-columns:repeat(auto-fill,minmax(230px,1fr))}
.prof{display:flex;flex-direction:column;align-items:flex-start;justify-content:center;gap:1px;text-align:left;width:100%;min-height:76px;padding:6px 12px}
.prof.cur{border:3px solid var(--accent);background:var(--panel);border-radius:10px;font-weight:700}
.prof .pd{font-size:21px;font-weight:750}
.prof .pf{font-size:16px;font-weight:600;color:var(--dim)}
.prof .pa{font-size:16px;font-weight:800;color:var(--accent)}
.prof .pw{font-size:15px;font-weight:700;color:var(--warn)}
dialog{background:var(--panel);color:var(--fg);border:2px solid var(--line);border-radius:14px;padding:16px;width:calc(100vw - 24px);max-width:520px}
dialog::backdrop{background:rgba(0,0,0,.65)}
dialog h2{margin:0 0 10px;font-size:22px}
dialog p{margin:0 0 12px;font-size:18px}
dialog .row2{margin-top:6px}
.jf{display:grid;grid-template-columns:1fr auto;gap:8px;margin-top:6px}
.jmsg{margin:8px 0 0;color:var(--dim);font-size:16px;font-weight:600}
.jlist{list-style:none;margin:8px 0 0;padding:0;max-height:480px;overflow-y:auto;border-top:1px solid var(--line)}
.jl{display:flex;flex-wrap:wrap;align-items:baseline;gap:0 10px;padding:6px 4px;border-bottom:1px solid var(--line)}
.jl .jt,.jl .js{font-size:15px;font-weight:600;color:var(--dim)}
.jl .jfr{font-size:18px}
.jl .jme{font-size:15px;font-weight:800;color:var(--accent)}
.jl .jx{flex-basis:100%;font-size:17px;overflow-wrap:anywhere}
.jl.me{background:var(--pass);border-left:5px solid var(--accent);padding-left:8px}
@media (min-width:900px){.jl .jx{flex:1 1 300px}}
.wst{display:grid;grid-template-columns:1fr;gap:6px 12px;padding:8px 12px}
@media (min-width:700px){.wst{grid-template-columns:repeat(3,minmax(0,1fr))}}
.wst .banner{grid-column:1/-1;margin:4px 0 0}
.wrep{grid-column:1/-1;margin-top:4px}
.wrep .lbl .val{color:var(--fg);font-size:19px}
.wl .wc{font-size:20px;font-weight:750}
.wl .wg{font-size:18px;font-weight:650}
.wl .wd{font-size:18px}
.wl .wx{flex-basis:100%;font-size:16px;font-weight:600;color:var(--dim)}
</style>
</head>
<body>
<div class="wrap">
<header>
  <div class="id"><span class="app">rxd</span><span id="profile">—</span><span id="modeTag" class="tag" hidden></span></div>
  <div id="conn" class="pill dimc" aria-live="polite">◌ Connecting</div>
</header>
<nav id="views" class="views" aria-label="View" hidden></nav>
<div id="down" class="banner" hidden>✕ Disconnected from rxd. Retrying.</div>
<div id="err" class="banner" hidden></div>
<div id="sw" class="banner sw" role="status" aria-live="polite" hidden><span id="swT"></span><span id="swS" class="sub"></span></div>
<div id="swErr" class="banner flip" role="alert" hidden><span id="swErrT"></span><button type="button" class="btn" id="swErrOk">OK</button></div>
<div id="flip" class="banner flip" role="alert" hidden><span id="flipT"></span><button type="button" class="btn" id="flipOk">✓ Done, it's flipped</button></div>
<div id="note" class="banner sw" hidden></div>
<section class="card" id="now" data-v="listen" data-live>
  <div class="lbl"><span>Station</span><span id="nMode" class="tag"></span></div>
  <div id="nName" class="nname">—</div>
  <div id="nFreq" class="nfreq">—</div>
  <div class="meter">
    <div class="mbar" role="meter" aria-label="Signal level" aria-valuemin="-100" aria-valuemax="0" id="mbar2"><i id="mfill2"></i></div>
    <div id="mnum2" class="mnum">— dBFS</div>
    <div class="mscale"><span>−100</span><span>−75</span><span>−50</span><span>−25</span><span>0</span></div>
  </div>
</section>
<div class="top" data-v="listen manual" data-live>
  <div id="hiu" class="hiu"><b id="hiuW">Ham It Up: —</b><span id="hiuS"></span></div>
  <div class="stats" data-v="manual">
    <div class="stat"><span class="k">Receiver</span><span id="sRx" class="v">—</span></div>
    <div class="stat"><span class="k">DSP CPU</span><span id="sCpu" class="v">—</span></div>
    <div class="stat"><span class="k">Blocks</span><span id="sDrop" class="v">—</span></div>
  </div>
</div>
<section class="card" id="listenCard" data-v="listen manual" data-live>
  <div class="lbl"><span>Audio on this device</span><span id="aDepth"></span></div>
  <button type="button" class="btn big" id="listen" aria-pressed="false">▶ Listen on this device</button>
  <p id="aState" class="astate" role="status">■ Not listening</p>
  <div class="sl"><div class="lbl"><label for="pvol">Volume on this device</label><span id="pvolV" class="val">—</span></div>
    <input type="range" id="pvol" min="0" max="150" step="1"></div>
  <button type="button" class="btn wide" id="mute" aria-pressed="false" disabled>Mute uConsole speaker</button>
  <p class="note">Audio may stop when the phone locks or the browser goes to the background.</p>
</section>
<section class="card" id="jPick" data-v="digital">
  <div class="lbl"><span>Mode and frequency</span></div>
  <div id="jPickL"></div>
</section>
<section class="card jstat" id="jStat" data-v="digital" data-live>
  <div><span class="k">Ham It Up</span><span id="jHiu" class="v">—</span></div>
  <div><span class="k">Receiver</span><span id="jRx" class="v">—</span></div>
  <div><span class="k">Signal</span><span id="jLvl" class="v">— dBFS</span></div>
  <div><span class="k">Heard</span><span id="jHeard" class="v">—</span></div>
  <div><span class="k">Clock</span><span id="jClock" class="v">—</span></div>
  <p id="jClockBad" class="banner jclock" role="alert" hidden></p>
</section>
<section class="card wst" id="wStat" data-v="digital" data-live hidden>
  <div><span class="k">Cycle</span><span id="wCycle" class="v">—</span></div>
  <div><span class="k">Last slot</span><span id="wLast" class="v">—</span></div>
  <div><span class="k">Reporting</span><span id="wRep" class="v">—</span></div>
  <p id="wErr" class="banner" role="alert" hidden></p>
  <div id="wRepSl" class="wrep" hidden><div class="lbl"><span>Report spots to WSPRnet</span><span id="wRepS" class="val">—</span></div>
    <div class="row2" role="group" aria-label="Report spots to WSPRnet"><button type="button" class="btn" id="wRepOff">Off</button><button type="button" class="btn" id="wRepOn">On</button></div>
    <p id="wMsg" class="msg" role="status" hidden></p></div>
</section>
<section class="card" id="js8" data-v="digital manual" data-live hidden>
  <div class="lbl"><span>JS8 decodes, newest first</span><span id="jCount"></span></div>
  <div class="jf"><input type="text" id="jFilter" placeholder="Filter by callsign" aria-label="Filter decodes by callsign" autocomplete="off" autocapitalize="characters" spellcheck="false" enterkeyhint="done">
    <button type="button" class="btn" id="jClear" hidden>Clear</button></div>
  <p id="jMsg" class="jmsg" role="status"></p>
  <ol id="jList" class="jlist"></ol>
</section>
<section class="card" id="wspr" data-v="digital manual" data-live hidden>
  <div class="lbl"><span>WSPR spots, newest first</span><span id="wCount"></span></div>
  <div class="jf"><input type="text" id="wFilter" placeholder="Filter by callsign or grid" aria-label="Filter spots by callsign or grid" autocomplete="off" autocapitalize="characters" spellcheck="false" enterkeyhint="done">
    <button type="button" class="btn" id="wClear" hidden>Clear</button></div>
  <p id="wsMsg" class="jmsg" role="status"></p>
  <ol id="wList" class="jlist"></ol>
</section>
<section class="card" id="lPick" data-v="listen">
  <div class="lbl"><span>Stations</span></div>
  <div id="lPickL"></div>
</section>
<fieldset id="qual" class="card" data-v="listen" data-live disabled>
  <div class="lbl"><span>Bandwidth</span><span id="bwPV" class="val">—</span></div>
  <div class="row3" id="bwP" role="group" aria-label="Bandwidth"></div>
</fieldset>
<fieldset id="ctl" data-v="manual" disabled>
<div class="layout">
  <section class="card tuner">
    <div class="lbl"><span>Dial, MHz</span><span id="cal"></span></div>
    <div id="freq" class="freq live" aria-live="off"><span id="fM">—</span><span id="fH" class="hz"></span></div>
    <div class="meter live">
      <div class="mbar" role="meter" aria-label="Signal level" aria-valuemin="-100" aria-valuemax="0" id="mbar"><i id="mfill"></i></div>
      <div id="mnum" class="mnum">— dBFS</div>
      <div class="mscale"><span>−100</span><span>−75</span><span>−50</span><span>−25</span><span>0</span></div>
    </div>
    <div class="row2">
      <button type="button" class="btn" id="dn">− 1 kHz</button>
      <button type="button" class="btn" id="up">+ 1 kHz</button>
    </div>
    <div class="steps" role="group" aria-label="Tuning step" id="steps"></div>
    <form id="entry" autocomplete="off">
      <input type="text" id="fin" inputmode="decimal" enterkeyhint="go" spellcheck="false" aria-label="Frequency in MHz, kHz or Hz" placeholder="7.078, 146.52 or Hz">
      <button class="btn" type="submit">Tune</button>
    </form>
    <p id="msg" class="msg" role="status" hidden></p>
    <p class="hint">Keys: ← → tune by the step, ↑ ↓ change the step. Scroll over the dial or spectrum to tune.</p>
  </section>
  <section class="card scope">
    <div class="lbl"><span>Spectrum and waterfall</span><span id="tapHint">Tap or click to tune</span></div>
    <canvas id="spec" aria-label="Spectrum. Click to tune."></canvas>
    <canvas id="wf" aria-label="Waterfall. Click to tune."></canvas>
  </section>
  <section class="card modes">
    <div class="lbl"><span>Mode</span></div>
    <div class="mgrid" role="group" aria-label="Mode" id="modes"></div>
  </section>
  <section class="card sliders" id="sliders">
    <div class="sl"><div class="lbl"><label for="bw">Bandwidth</label><span id="bwV" class="val">—</span></div>
      <input type="range" id="bw" min="300" max="4000" step="100"></div>
    <div class="sl" id="gainSl"><div class="lbl"><label for="gain">RF gain</label><span id="gainV" class="val">—</span></div>
      <input type="range" id="gain" min="0" max="50" step="0.1"></div>
    <div class="sl" id="volSl"><div class="lbl"><label for="vol">uConsole speaker</label><span id="volV" class="val">—</span></div>
      <input type="range" id="vol" min="0" max="1000" step="1"></div>
  </section>
</div>
</fieldset>
<section class="card" id="aPick" data-v="manual">
  <div class="lbl"><span>Profiles</span></div>
  <div id="aPickL" class="plist"></div>
</section>
<p id="pmsg" class="msg" role="status" hidden></p>
<section class="card" id="appear0">
  <div class="lbl"><span>Appearance</span></div>
  <div class="appear" role="group" aria-label="Appearance" id="appear"></div>
</section>
</div>
<dialog id="dlg" aria-labelledby="dlgT">
  <h2 id="dlgT"></h2><div id="dlgB"></div>
  <div class="row2"><button type="button" class="btn" id="dlgNo">Cancel</button><button type="button" class="btn pri" id="dlgYes">Switch</button></div>
</dialog>
<script>
"use strict";
(function () {
const $ = id => document.getElementById(id);
const STEPS = [10, 100, 1e3, 5e3, 12.5e3, 100e3, 1e6];
const MODES = ["USB", "LSB", "AM", "FM", "WFM"];
const BWR = {USB: [300, 4000, 100], LSB: [300, 4000, 100], AM: [2000, 20000, 500], FM: [5000, 30000, 500], WFM: [50000, 250000, 5000]};
const FMIN = 100e3, FMAX = 1.7e9;
const THEMES = [["auto", "Automatic"], ["light", "Light"], ["dark", "Dark"], ["night", "Night"]];

function load(k) { try { return localStorage.getItem("rxd." + k); } catch (e) { return null; } }
function store(k, v) { try { localStorage.setItem("rxd." + k, v); } catch (e) {} }
function forget(k) { try { localStorage.removeItem("rxd." + k); } catch (e) {} }
function now() { return performance.now(); }

// ---------------------------------------------------------------- state
let st = null;            // last status from rxd
let conn = "connecting";  // connecting | ok | down
let fails = 0;
let localFreq = null, localMode = null;
let step = +load("step"); if (STEPS.indexOf(step) < 0) step = 1e3;
const holdUntil = {}, active = {};
function held(k) { return !!active[k] || (holdUntil[k] || 0) > now(); }
function hold(k, ms) { holdUntil[k] = Math.max(holdUntil[k] || 0, now() + ms); }
function release(k) { holdUntil[k] = 0; }

// ---------------------------------------------------------------- formatting
function freqParts(hz) {
  hz = Math.round(hz);
  const m = Math.floor(hz / 1e6), r = hz - m * 1e6;
  return [m + "." + String(Math.floor(r / 1000)).padStart(3, "0"), String(r % 1000).padStart(3, "0")];
}
function trim(x, d) { return x.toFixed(d).replace(/\.?0+$/, ""); }
function fmtHz(v) {
  if (v >= 1e6) return [trim(v / 1e6, 3), "MHz"];
  if (v >= 1e3) return [trim(v / 1e3, 2), "kHz"];
  return [String(v), "Hz"];
}
function fmtBw(v) { const p = fmtHz(v); return p[0] + " " + p[1]; }
// rxd sends UTC: "2026-11-06 10:47:03" (JS8Call) or "2026-11-06T12:20:00Z".
// Everything shown is the browser's local time, 24 hour.
function utcDate(t) {
  const m = /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d)(?::(\d\d))?/.exec(String(t || ""));
  return m ? new Date(Date.UTC(+m[1], m[2] - 1, +m[3], +m[4], +m[5], +(m[6] || 0))) : null;
}
const p2 = n => String(n).padStart(2, "0");
function hhmm(d, secs) { return p2(d.getHours()) + ":" + p2(d.getMinutes()) + (secs ? ":" + p2(d.getSeconds()) : ""); }
// a time for a list line: the day too when it isn't today
function lineTime(t, secs) {
  const d = utcDate(t);
  if (!d) return String(t || "");
  const today = new Date().toDateString() === d.toDateString();
  return (today ? "" : d.toLocaleDateString(undefined, {month: "short", day: "numeric"}) + " ") + hhmm(d, secs);
}
function slotTime(t) { const d = utcDate(t); return d ? hhmm(d) : "—"; }
function signed(n) { return (n > 0 ? "+" : n < 0 ? "−" : "") + Math.abs(n); }
function parseFreq(t) {
  t = t.trim().toLowerCase().replace(/[\s,_']/g, "");
  const m = t.match(/^(\d+(?:\.\d*)?|\.\d+)(mhz|m|khz|k|hz)?$/);
  if (!m) return null;
  let v = parseFloat(m[1]); const u = m[2] || "";
  if (u[0] === "m") v *= 1e6;
  else if (u[0] === "k") v *= 1e3;
  else if (u === "hz") {}
  else if (v < 2000) v *= 1e6;      // bare 7.078, 146.52, 1296: MHz
  else if (v < 100000) v *= 1e3;    // bare 14074: kHz
  return Math.round(v);             // bare 7078000: Hz
}

// ---------------------------------------------------------------- network
async function api(path, body) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 4000);
  try {
    const opt = body === undefined ? {cache: "no-store", signal: ctl.signal}
      : {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify(body), signal: ctl.signal};
    const r = await fetch(path, opt);
    let doc = null;
    try { doc = await r.json(); } catch (e) {}
    return {ok: r.ok, status: r.status, doc: doc};
  } finally { clearTimeout(t); }
}

let statusTimer = 0, backoff = 0;
async function pollStatus() {
  clearTimeout(statusTimer);
  try {
    const r = await api("/api/status");
    if (!r.ok || !r.doc || typeof r.doc.freq !== "number") throw new Error("bad status");
    fails = 0; backoff = 0;
    setConn("ok");
    applyStatus(r.doc);
  } catch (e) {
    fails++;
    backoff = Math.min(backoff ? backoff * 2 : 1000, switching ? 1000 : 10000);
    if (fails >= 2 || conn !== "ok") setConn("down");
  }
  statusTimer = setTimeout(pollStatus, backoff || (document.hidden ? 5000 : 500));
}

// Tuning: fields merge into one pending request; one request in flight at a time.
let pend = {}, inflight = false, tuneTimer = 0, entryText = "";
function tune(fields, delay) {
  Object.assign(pend, fields);
  for (const k in fields) hold(k, 2000);
  if (!delay) { clearTimeout(tuneTimer); tuneTimer = 0; flush(); }
  else if (!tuneTimer) tuneTimer = setTimeout(() => { tuneTimer = 0; flush(); }, delay);
}
async function flush() {
  if (inflight || !Object.keys(pend).length) return;
  const body = pend; pend = {}; inflight = true;
  try {
    const r = await api("/api/tune", body);
    if (r.ok && r.doc && typeof r.doc.freq === "number") {
      clearMsg();
      if ("freq" in body) entryText = "";
      for (const k in body) if (!(k in pend) && !active[k]) { release(k); hold(k, 400); }
      setConn("ok");
      applyStatus(r.doc);
    } else {
      fail(body, "rxd refused: " + ((r.doc && r.doc.error) || ("HTTP " + r.status)));
    }
  } catch (e) {
    fail(body, "Could not reach rxd. Nothing was changed.");
  }
  inflight = false;
  if (Object.keys(pend).length) flush();
}
function fail(body, text) {
  showMsg(text);
  if ("freq" in body && entryText && !$("fin").value) $("fin").value = entryText;
  for (const k in body) if (!(k in pend)) release(k);
  if ("freq" in body && !("freq" in pend) && st) localFreq = st.freq;
  if ("mode" in body && !("mode" in pend) && st) localMode = st.mode;
  if (st) applyStatus(st);
}
function showMsg(t) { const m = $("msg"); m.textContent = "✕ " + t; m.hidden = false; }
function clearMsg() { $("msg").hidden = true; }

// ---------------------------------------------------------------- status rendering
let viewKey = "";
let lastDropped = null, dropAt = -1e9, lastBlocks = null, stallCount = 0, gainsKey = "";
function setText(el, t, cls) {
  if (el.textContent !== t) el.textContent = t;
  if (cls !== undefined && el.className !== cls) el.className = cls;
}
function setConn(c) {
  if (c === conn) return;
  conn = c;
  renderConn();
  if (c === "down") {
    setText($("sRx"), "— Unknown", "v dimc"); setText($("sCpu"), "—", "v dimc"); setText($("sDrop"), "—", "v dimc");
    if (st) { $("hiu").classList.add("stale"); setText($("hiuS"), "Last known. rxd is not answering."); }
    drawSpecMsg(downMsg());
  }
  if (c === "ok") { pollSpecSoon(); if (profAvail && !profiles) loadProfiles(); }
}
function downMsg() { return switching ? "■ Switching to " + switching.name + "…" : "✕ Disconnected"; }
function renderConn() {
  const el = $("conn");
  if (switching) setText(el, "■ Switching", "pill warn");
  else if (conn === "ok") setText(el, "● Connected", "pill ok");
  else if (conn === "down") setText(el, "✕ Disconnected", "pill bad");
  $("down").hidden = conn !== "down" || !!switching;
  $("ctl").disabled = $("qual").disabled = conn !== "ok" || !!switching;
  $("sw").hidden = !switching;
  if (switching) $("note").hidden = true;
  renderProfiles(); renderMute();
}

function applyStatus(s) {
  st = s;
  if (switching && s.profile === switching.name) finishSwitch();
  if (!held("freq")) localFreq = s.freq;
  if (!held("mode")) localMode = s.mode;
  renderFreq();
  setText($("profile"), s.profile || "rxd");
  const tag = $("modeTag"); tag.hidden = false; setText(tag, localMode);
  setText($("cal"), s.cal_hz ? "VFO " + freqParts(s.vfo_hz).join(" ") + " (cal " + (s.cal_hz > 0 ? "+" : "−") + Math.abs(Math.round(s.cal_hz)) + " Hz)" : "");
  for (const b of $("modes").children) b.setAttribute("aria-pressed", String(b.dataset.m === localMode));

  // Ham It Up
  const up = s.upconverter_hz > 0, hiu = $("hiu");
  hiu.className = "hiu" + (up ? " up" : "");
  setText($("hiuW"), up ? "⇅ Ham It Up: UPCONVERT" : "→ Ham It Up: BYPASS");
  var below = trim((s.upconvert_below_hz || 30e6) / 1e6, 3) + " MHz";
  setText($("hiuS"), up ? "Set the switch to UPCONVERT (+" + trim(s.upconverter_hz / 1e6, 3) + " MHz)" + (s.offset_mode === "auto" ? ", below " + below : "")
    : "Set the switch to BYPASS" + (s.offset_mode === "auto" ? ", " + below + " and up" : ""));

  // receiver
  if (s.error) { $("err").hidden = false; setText($("err"), "✕ rxd error: " + s.error); } else $("err").hidden = true;
  if (lastBlocks !== null && s.blocks === lastBlocks) stallCount++; else stallCount = 0;
  lastBlocks = s.blocks;
  if (!s.running) setText($("sRx"), "■ Stopped", "v bad");
  else if (s.error) setText($("sRx"), "✕ Error", "v bad");
  else if (stallCount >= 3) setText($("sRx"), "▲ No samples", "v warn");
  else setText($("sRx"), "● Receiving", "v ok");

  const cpu = Math.round((s.dsp_cpu || 0) * 100);
  setText($("sCpu"), (cpu >= 80 ? "▲ " : "") + cpu + " %", cpu >= 80 ? "v warn" : "v");

  if (lastDropped !== null && s.dropped > lastDropped) dropAt = now();
  lastDropped = s.dropped;
  if (now() - dropAt < 10000) setText($("sDrop"), "▲ Dropping (" + s.dropped + " lost)", "v warn");
  else if (s.dropped > 0) setText($("sDrop"), "✓ OK, " + s.dropped + " lost earlier", "v");
  else setText($("sDrop"), "✓ None lost", "v ok");

  // meter
  const lv = s.level_dbfs;
  if (typeof lv === "number") {
    const pct = Math.max(0, Math.min(100, (lv + 100)));
    for (const i of ["", "2"]) {
      $("mfill" + i).style.width = pct + "%";
      $("mbar" + i).setAttribute("aria-valuenow", String(lv));
      setText($("mnum" + i), (lv < 0 ? "−" : "") + Math.abs(lv).toFixed(1) + " dBFS");
    }
  } else for (const i of ["", "2"]) { $("mfill" + i).style.width = "0"; setText($("mnum" + i), "— dBFS"); }

  // sliders
  if (!held("bandwidth")) setBw(localMode, s.bandwidth);
  const gains = Array.isArray(s.gains) ? s.gains : [];
  const gk = gains.join(",");
  if (gk !== gainsKey) { gainsKey = gk; setupGain(gains); }
  if (!held("gain_db")) setGain(s.gain_db);
  if (!held("volume")) setVol(s.volume);

  syncMute();
  autoView();
  // JS8's audio is only tones; WSPR's speaker is muted by design, so the phone may listen
  if (A.on && pdec(s) === "js8" && view === "digital") stopListen();
  const vk = [view, curKind(), pdec(s), profAvail, A.on].join();
  if (vk !== viewKey) { viewKey = vk; renderView(); }
  renderProfiles(); renderQual();
  renderJs8Stat(s, $("sRx").textContent, $("sRx").className);
  renderWsprStat(s);
  if (profAvail && profiles && !switching && !profLoading && s.profile !== profiles.active && s.profile !== profAskedFor) loadProfiles();
  if (A.on && rateFor(s.mode) !== A.want) connectAudio();
  js8Sync(); wsprSync();
}

function renderFreq() {
  if (localFreq == null) return;
  const p = freqParts(localFreq);
  setText($("fM"), p[0]); setText($("fH"), " " + p[1]);
}

// ---------------------------------------------------------------- tuning controls
function clampF(f) { return Math.max(FMIN, Math.min(FMAX, f)); }
function tuneTo(f) {
  f = Math.round(clampF(f));
  localFreq = f; renderFreq();
  tune({freq: f}, 0);
}
function stepBy(n) {
  if (localFreq == null || conn !== "ok") return;
  const q = localFreq / step, e = 1e-6;
  const k = n > 0 ? Math.floor(q + e) + n : Math.ceil(q - e) + n;
  tuneTo(k * step);
}
function renderSteps() {
  const p = fmtHz(step), t = p[0] + " " + p[1];
  $("dn").textContent = "− " + t; $("up").textContent = "+ " + t;
  $("dn").setAttribute("aria-label", "Tune down " + t); $("up").setAttribute("aria-label", "Tune up " + t);
  for (const b of $("steps").children) b.setAttribute("aria-pressed", String(+b.dataset.s === step));
}
function setStep(s) { step = s; store("step", String(s)); renderSteps(); }
for (const s of STEPS) {
  const b = document.createElement("button");
  const p = fmtHz(s);
  b.type = "button"; b.className = "btn"; b.dataset.s = s;
  b.setAttribute("aria-label", "Step " + p[0] + " " + p[1]);
  b.innerHTML = p[0] + "<small>" + p[1] + "</small>";
  b.onclick = () => setStep(s);
  $("steps").appendChild(b);
}
$("dn").onclick = () => stepBy(-1);
$("up").onclick = () => stepBy(1);
renderSteps();

$("entry").onsubmit = e => {
  e.preventDefault();
  const inp = $("fin"), t = inp.value;
  if (!t.trim()) { showMsg("Type a frequency first: 7.078 (MHz), 14074 (kHz) or 7078000 (Hz)."); return; }
  const f = parseFreq(t);
  if (f == null) { showMsg("Not a frequency: " + t.trim() + ". Type MHz (7.078), kHz (14074) or Hz (7078000)."); return; }
  if (f < FMIN || f > FMAX) { showMsg("Out of range: rxd tunes 0.1 to 1700 MHz."); return; }
  inp.value = ""; inp.blur();
  tuneTo(f);
  entryText = t.trim();
};

for (const m of MODES) {
  const b = document.createElement("button");
  b.type = "button"; b.className = "btn"; b.textContent = m; b.dataset.m = m;
  b.onclick = () => {
    if (m === localMode) return;
    localMode = m;
    for (const x of $("modes").children) x.setAttribute("aria-pressed", String(x.dataset.m === m));
    setText($("modeTag"), m);
    release("bandwidth");
    tune({mode: m}, 0);
  };
  $("modes").appendChild(b);
}

// ---------------------------------------------------------------- sliders
function fill(el) {
  const a = +el.min, b = +el.max, v = +el.value;
  el.style.setProperty("--p", (b > a ? (v - a) / (b - a) * 100 : 0) + "%");
}
function track(el, key) {
  el.addEventListener("pointerdown", () => { active[key] = true; });
  const up = () => { if (active[key]) { active[key] = false; hold(key, 1500); } };
  window.addEventListener("pointerup", up); window.addEventListener("pointercancel", up);
  el.addEventListener("focus", () => hold(key, 1500));
}
const bwEl = $("bw"), gainEl = $("gain"), volEl = $("vol");
let gainSteps = [];
function setBw(mode, bw) {
  const r = BWR[mode] || [100, 250000, 100];
  bwEl.min = r[0]; bwEl.max = r[1]; bwEl.step = r[2];
  bwEl.value = Math.max(r[0], Math.min(r[1], bw)); fill(bwEl);
  setText($("bwV"), fmtBw(Math.round(bw)));
}
bwEl.oninput = () => { const v = +bwEl.value; setText($("bwV"), fmtBw(v)); fill(bwEl); tune({bandwidth: v}, 200); };
function setupGain(g) {
  gainSteps = g.slice().sort((a, b) => a - b);
  if (gainSteps.length) { gainEl.min = 0; gainEl.max = gainSteps.length - 1; gainEl.step = 1; }
  else { gainEl.min = 0; gainEl.max = 50; gainEl.step = 0.1; }
}
function gainFromEl() { return gainSteps.length ? gainSteps[+gainEl.value] : +gainEl.value; }
function setGain(db) {
  if (db == null) { setText($("gainV"), "—"); return; }
  if (gainSteps.length) {
    let bi = 0;
    gainSteps.forEach((g, i) => { if (Math.abs(g - db) < Math.abs(gainSteps[bi] - db)) bi = i; });
    gainEl.value = bi;
  } else gainEl.value = db;
  fill(gainEl);
  setText($("gainV"), db.toFixed(1) + " dB");
}
gainEl.oninput = () => { const v = gainFromEl(); setText($("gainV"), v.toFixed(1) + " dB"); fill(gainEl); tune({gain_db: v}, 200); };
// Volume 0..4 on a squared taper so the useful low end gets most of the travel.
function setVol(v) {
  if (v == null) return;
  volEl.value = Math.round(Math.sqrt(Math.max(0, v) / 4) * 1000); fill(volEl);
  setText($("volV"), Math.round(v * 100) + " %");
}
volEl.oninput = () => {
  const p = +volEl.value / 1000, v = Math.round(4 * p * p * 100) / 100;
  setText($("volV"), Math.round(v * 100) + " %"); fill(volEl); tune({volume: v}, 200);
};
track(bwEl, "bandwidth"); track(gainEl, "gain_db"); track(volEl, "volume");

// ---------------------------------------------------------------- keys and wheel
document.addEventListener("keydown", e => {
  const t = e.target;
  if (e.altKey || e.ctrlKey || e.metaKey || $("ctl").disabled) return;
  if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
  const i = STEPS.indexOf(step);
  if (e.key === "ArrowRight") stepBy(1);
  else if (e.key === "ArrowLeft") stepBy(-1);
  else if (e.key === "ArrowUp") setStep(STEPS[Math.min(STEPS.length - 1, i + 1)]);
  else if (e.key === "ArrowDown") setStep(STEPS[Math.max(0, i - 1)]);
  else return;
  e.preventDefault();
});
let wheelAcc = 0;
function onWheel(e) {
  if ($("ctl").disabled) return;
  e.preventDefault();
  wheelAcc += e.deltaMode === 1 ? e.deltaY * 40 : e.deltaY;
  while (Math.abs(wheelAcc) >= 100) { stepBy(wheelAcc < 0 ? 1 : -1); wheelAcc -= Math.sign(wheelAcc) * 100; }
}

// ---------------------------------------------------------------- spectrum and waterfall
const spec = $("spec"), wf = $("wf");
const wbuf = document.createElement("canvas");
let col = {}, lut = null, last = null, range = null, ring = [], specMsg = "Waiting for the spectrum";
const DAY = [[0, 0, 0, 16], [.25, 10, 26, 110], [.5, 29, 127, 214], [.7, 47, 209, 196], [.86, 245, 233, 74], [1, 255, 255, 255]];
const NIGHT = [[0, 0, 0, 0], [.35, 60, 0, 0], [.7, 165, 8, 0], [1, 255, 40, 20]];
function buildLut(stops) {
  const a = new Uint8ClampedArray(256 * 3);
  for (let i = 0; i < 256; i++) {
    const x = i / 255; let j = 1;
    while (j < stops.length - 1 && stops[j][0] < x) j++;
    const s0 = stops[j - 1], s1 = stops[j], f = (x - s0[0]) / (s1[0] - s0[0]);
    for (let c = 0; c < 3; c++) a[i * 3 + c] = s0[c + 1] + (s1[c + 1] - s0[c + 1]) * f;
  }
  return a;
}
function isNight() { return document.documentElement.dataset.theme === "night"; }
function readColors() {
  const cs = getComputedStyle(document.documentElement);
  for (const k of ["plot", "grid", "trace", "pass", "mark", "dim", "fg", "bg"]) col[k] = cs.getPropertyValue("--" + k).trim();
  lut = buildLut(isNight() ? NIGHT : DAY);
  const meta = document.querySelector('meta[name="theme-color"]');
  if (meta) meta.setAttribute("content", col.bg);
  rerenderWaterfall(); redrawSpec();
}
function dpr() { return window.devicePixelRatio || 1; }
function fit(c) {
  const r = c.getBoundingClientRect(), d = dpr();
  const w = Math.max(1, Math.round(r.width * d)), h = Math.max(1, Math.round(r.height * d));
  if (c.width !== w || c.height !== h) { c.width = w; c.height = h; return true; }
  return false;
}
function onResize() {
  const a = fit(spec), b = fit(wf);
  if (b) { wbuf.width = wf.width; wbuf.height = wf.height; rerenderWaterfall(); }
  if (a || b) redrawSpec();
}
function niceStep(span, maxLabels) {
  const c = [100, 200, 500, 1e3, 2e3, 2.5e3, 5e3, 1e4, 2e4, 2.5e4, 5e4, 1e5, 2e5, 2.5e5, 5e5, 1e6, 2e6, 5e6];
  for (const s of c) if (span / s <= maxLabels) return s;
  return 1e7;
}
function decimals(s) { let d = 0; while (d < 6 && Math.abs(Math.round(s / 1e6 * 10 ** d) - s / 1e6 * 10 ** d) > 1e-9) d++; return d; }
function updateRange(bins) {
  const s = Array.from(bins).sort((a, b) => a - b);
  const floor = s[Math.floor(s.length * 0.2)], peak = s[s.length - 1];
  const lo = floor - 8, hi = Math.max(peak + 6, floor + 45);
  if (!range) range = {lo: lo, hi: hi};
  else { range.lo += (lo - range.lo) * 0.15; range.hi += (hi - range.hi) * 0.15; }
}
function redrawSpec() {
  if (last && conn === "ok") drawSpec(last); else drawSpecMsg(conn === "down" ? downMsg() : specMsg);
}
function drawSpecMsg(text) {
  if (!spec.width) return;
  const g = spec.getContext("2d"), d = dpr();
  g.fillStyle = col.plot; g.fillRect(0, 0, spec.width, spec.height);
  g.fillStyle = col.dim; g.font = "600 " + Math.round(17 * d) + "px system-ui,sans-serif";
  g.textAlign = "center"; g.textBaseline = "middle";
  g.fillText(text, spec.width / 2, spec.height / 2);
  drawWfView();
}
function drawSpec(s) {
  const g = spec.getContext("2d"), d = dpr(), W = spec.width, H = spec.height;
  const axis = Math.round(24 * d), ph = H - axis, span = s.stop_hz - s.start_hz;
  const X = hz => (hz - s.start_hz) / span * W;
  const lo = range.lo, hi = range.hi, Y = v => ph - (v - lo) / (hi - lo) * ph;
  g.fillStyle = col.plot; g.fillRect(0, 0, W, H);
  // passband
  if (s.passband) { const a = X(s.passband[0]), b = X(s.passband[1]); g.fillStyle = col.pass; g.fillRect(a, 0, Math.max(b - a, d), ph); }
  // dB grid
  g.strokeStyle = col.grid; g.lineWidth = d; g.fillStyle = col.dim;
  g.font = Math.round(13 * d) + "px system-ui,sans-serif"; g.textBaseline = "bottom"; g.textAlign = "left";
  const dbStep = (hi - lo) > 60 ? 20 : 10, dbs = [];
  for (let v = Math.ceil(lo / dbStep) * dbStep; v < hi; v += dbStep) {
    const y = Math.round(Y(v)) + .5; g.beginPath(); g.moveTo(0, y); g.lineTo(W, y); g.stroke();
    if (y > 14 * d && v > lo + (hi - lo) * 0.2) dbs.push([v, y]);
  }
  // frequency grid and labels
  const fs = niceStep(span, Math.max(2, Math.floor(W / (62 * d)))), dec = decimals(fs);
  g.textAlign = "center"; g.textBaseline = "middle";
  for (let f = Math.ceil(s.start_hz / fs) * fs; f <= s.stop_hz; f += fs) {
    const x = Math.round(X(f)) + .5;
    g.beginPath(); g.moveTo(x, 0); g.lineTo(x, ph); g.stroke();
    const t = (f / 1e6).toFixed(dec);
    const tw = g.measureText(t).width / 2;
    if (x - tw > 2 && x + tw < W - 2) g.fillText(t, x, ph + axis / 2);
  }
  // trace
  const n = s.bins.length;
  g.beginPath();
  for (let i = 0; i < n; i++) { const x = (i + .5) / n * W, y = Math.max(0, Math.min(ph, Y(s.bins[i]))); i ? g.lineTo(x, y) : g.moveTo(x, y); }
  g.strokeStyle = col.trace; g.lineWidth = 1.5 * d; g.stroke();
  g.lineTo(W, ph); g.lineTo(0, ph); g.closePath();
  g.globalAlpha = .18; g.fillStyle = col.trace; g.fill(); g.globalAlpha = 1;
  // dB labels over the trace, with a halo
  g.font = Math.round(13 * d) + "px system-ui,sans-serif"; g.textAlign = "left"; g.textBaseline = "bottom";
  g.lineWidth = 3 * d; g.strokeStyle = col.plot; g.fillStyle = col.dim;
  for (const [v, y] of dbs) { const t = (v < 0 ? "−" : "") + Math.abs(v) + " dB"; g.strokeText(t, 4 * d, y - 2 * d); g.fillText(t, 4 * d, y - 2 * d); }
  // dial marker
  const dx = Math.round(X(s.dial_hz)) + .5;
  g.strokeStyle = col.mark; g.lineWidth = 2 * d; g.beginPath(); g.moveTo(dx, 0); g.lineTo(dx, ph); g.stroke();
  g.strokeStyle = col.grid; g.lineWidth = d; g.beginPath(); g.moveTo(0, ph + .5); g.lineTo(W, ph + .5); g.stroke();
}
function rowH() { return Math.max(1, Math.round(2 * dpr())); }
function paintRow(g, y, r, vs, ve, W) {
  const h = rowH(), img = g.createImageData(W, h), px = img.data, n = r.bins.length;
  const lo = range.lo, k = 255 / (range.hi - range.lo), rs = r.start, rspan = r.stop - r.start;
  for (let x = 0; x < W; x++) {
    const f0 = vs + x / W * (ve - vs), f1 = vs + (x + 1) / W * (ve - vs);
    let b0 = Math.floor((f0 - rs) / rspan * n), b1 = Math.floor((f1 - rs) / rspan * n);
    let ci = 0;
    if (b1 >= 0 && b0 < n) {
      b0 = Math.max(0, b0); b1 = Math.min(n - 1, Math.max(b0, b1));
      let v = r.bins[b0]; for (let b = b0 + 1; b <= b1; b++) if (r.bins[b] > v) v = r.bins[b];
      ci = Math.max(0, Math.min(255, Math.round((v - lo) * k)));
    }
    for (let yy = 0; yy < h; yy++) { const o = (yy * W + x) * 4; px[o] = lut[ci * 3]; px[o + 1] = lut[ci * 3 + 1]; px[o + 2] = lut[ci * 3 + 2]; px[o + 3] = 255; }
  }
  g.putImageData(img, 0, y);
}
function rerenderWaterfall() {
  if (!wbuf.width || !lut) return;
  const g = wbuf.getContext("2d"), W = wbuf.width, H = wbuf.height;
  g.fillStyle = "rgb(" + lut[0] + "," + lut[1] + "," + lut[2] + ")"; g.fillRect(0, 0, W, H);
  if (last && range) { const h = rowH(); for (let i = 0; i < ring.length && i * h < H; i++) paintRow(g, i * h, ring[i], last.start_hz, last.stop_hz, W); }
  drawWfView();
}
function addRow(s) {
  const r = {bins: s.bins, start: s.start_hz, stop: s.stop_hz};
  const h = rowH(), cap = Math.ceil((wbuf.height || 300) / h) + 1;
  const moved = !last || last.start_hz !== s.start_hz || last.stop_hz !== s.stop_hz;
  ring.unshift(r); if (ring.length > cap) ring.length = cap;
  last = s;
  if (!wbuf.width) return;
  if (moved) { rerenderWaterfall(); return; }
  const g = wbuf.getContext("2d");
  g.drawImage(wbuf, 0, 0, wbuf.width, wbuf.height - h, 0, h, wbuf.width, wbuf.height - h);
  paintRow(g, 0, r, s.start_hz, s.stop_hz, wbuf.width);
  drawWfView();
}
function drawWfView() {
  if (!wf.width) return;
  const g = wf.getContext("2d"), W = wf.width, H = wf.height, d = dpr();
  g.drawImage(wbuf, 0, 0);
  if (!last || conn !== "ok") return;
  const span = last.stop_hz - last.start_hz, X = hz => (hz - last.start_hz) / span * W;
  g.strokeStyle = col.mark; g.lineWidth = 2 * d; g.setLineDash([6 * d, 6 * d]);
  const dx = Math.round(X(last.dial_hz)) + .5; g.beginPath(); g.moveTo(dx, 0); g.lineTo(dx, H); g.stroke();
  g.setLineDash([]);
}

let specTimer = 0, specBusy = false, lastSeq = null;
function pollSpecSoon() { clearTimeout(specTimer); specTimer = setTimeout(pollSpec, 0); }
async function pollSpec() {
  clearTimeout(specTimer);
  if (document.hidden || specBusy || view !== "manual") return;
  specBusy = true;
  const t0 = now(); let wait = 200;
  if (conn === "ok") {
    try {
      const r = await api("/api/spectrum");
      const s = r.doc;
      if (r.ok && s && Array.isArray(s.bins) && s.bins.length && s.stop_hz > s.start_hz) {
        specAvail(true);
        if (s.seq !== lastSeq) { lastSeq = s.seq; updateRange(s.bins); addRow(s); if (conn === "ok") drawSpec(s); }
      } else {
        wait = 5000; last = null; specAvail(false);
        specMsg = r.status === 404 ? "This rxd has no spectrum" : "No spectrum yet"; drawSpecMsg(specMsg);
      }
    } catch (e) { wait = 1000; }
  } else wait = 1000;
  specBusy = false;
  if (!document.hidden) specTimer = setTimeout(pollSpec, Math.max(20, wait - (now() - t0)));
}
function specAvail(ok) {
  if (wf.hidden === !ok) return;
  wf.hidden = !ok; $("tapHint").hidden = !ok;
  spec.style.cursor = ok ? "" : "default";
  onResize();
}
function canvasTune(e) {
  if (!last || conn !== "ok") return;
  const r = e.currentTarget.getBoundingClientRect();
  const x = Math.max(0, Math.min(1, (e.clientX - r.left) / r.width));
  const span = last.stop_hz - last.start_hz;
  let f = last.start_hz + x * span;
  const q = step <= span / 10 ? step : 100;
  f = Math.round(f / q) * q;
  tuneTo(f);
}
for (const c of [spec, wf]) { c.addEventListener("click", canvasTune); c.addEventListener("wheel", onWheel, {passive: false}); }
$("freq").addEventListener("wheel", onWheel, {passive: false});

// ---------------------------------------------------------------- appearance
function setTheme(t) {
  document.documentElement.dataset.theme = t;
  store("theme", t);
  for (const b of $("appear").children) b.setAttribute("aria-pressed", String(b.dataset.t === t));
  readColors();
}
for (const [t, name] of THEMES) {
  const b = document.createElement("button");
  b.type = "button"; b.className = "btn"; b.dataset.t = t; b.textContent = name;
  b.onclick = () => setTheme(t);
  $("appear").appendChild(b);
}
for (const b of $("appear").children) b.setAttribute("aria-pressed", String(b.dataset.t === document.documentElement.dataset.theme));
const mq = window.matchMedia("(prefers-color-scheme: dark)");
(mq.addEventListener ? mq.addEventListener.bind(mq, "change") : mq.addListener.bind(mq))(readColors);


// ---------------------------------------------------------------- profiles and views
// Views follow the active profile's kind: digital profiles (a JS8 or WSPR
// decoder) get the decodes, WFM/FM/AM get the station picker and Listen,
// anything else gets Manual.
// Manual is the only view that sticks, and only because the user chose it.
const LISTEN_MODES = ["WFM", "FM", "AM"];
const GROUPS = [["WFM", "Broadcast FM"], ["FM", "VHF · UHF"], ["AM", "AM"]];
const VIEWS = [["digital", "Digital"], ["listen", "Listen"], ["manual", "Manual", "tuning"]];
const DECODERS = [["js8", "JS8"], ["wspr", "WSPR"]];
let profiles = null, profAvail = true, profLoading = false, profAskedFor = null;
let switching = null, switchTimer = 0, flipText = "";
let view = load("view") === "manual" ? "manual" : null, viewFor = null;
// rxd and radio say "decoder"; older ones only the js8 flag
function pdec(p) { return p.decoder !== undefined ? p.decoder || null : p.js8 ? "js8" : null; }
function pkind(p) { return pdec(p) ? "digital" : LISTEN_MODES.indexOf(p.mode) >= 0 ? "listen" : "manual"; }
function curDec() { if (st) return pdec(st); const p = activeProf(); return p ? pdec(p) : null; }
function decName(d) { const x = DECODERS.find(x => x[0] === d); return x ? x[1] : "digital"; }
function activeName() { return (st && st.profile) || (profiles && profiles.active) || null; }
function activeProf() { const n = activeName(); return (profiles && profiles.profiles.find(p => p.name === n)) || null; }
function curKind() {
  const p = activeProf();
  if (p) return pkind(p);
  if (!st) return null;
  return pdec(st) ? "digital" : LISTEN_MODES.indexOf(st.mode) >= 0 ? "listen" : "manual";
}
function curUp() { return !!(st && st.upconverter_hz > 0); }
function hiuWord(up) { return up ? "UPCONVERT" : "BYPASS"; }
function fmtMHz(hz) { return trim(hz / 1e6, 6) + " MHz"; }
function pdesc(p) { return p.description || p.name; }
function showPmsg(t) { const m = $("pmsg"); m.textContent = t ? "✕ " + t : ""; m.hidden = !t; }

async function loadProfiles() {
  if (profLoading) return;
  profLoading = true; profAskedFor = st && st.profile;
  try {
    const r = await api("/api/profiles");
    if (r.status === 404) { profAvail = false; profiles = null; }
    else if (r.ok && r.doc && Array.isArray(r.doc.profiles)) { profAvail = true; profiles = r.doc; }
  } catch (e) {}
  profLoading = false;
  pickKey = ""; autoView(); renderView();
}

function autoView() {
  const n = activeName(), k = curKind();
  if (!profAvail) { view = "manual"; return; }
  if (view === "manual" && load("view") === "manual") { viewFor = n; return; }
  if (n && k && n !== viewFor) { viewFor = n; view = k; }
}
function setView(v) {
  view = v;
  if (v === "manual") store("view", "manual"); else forget("view");
  viewFor = activeName();
  renderView();
  window.scrollTo(0, 0);
}
for (const [v, name, sub] of VIEWS) {
  const b = document.createElement("button");
  b.type = "button"; b.className = "btn"; b.dataset.view = v;
  b.onclick = () => setView(v);
  $("views").appendChild(b);
}

function renderView() {
  const v = view, k = curKind();
  const mis = !!v && v !== "manual" && !!k && k !== v;
  document.body.dataset.view = v || "";
  $("views").hidden = !profAvail || !v;
  for (const b of $("views").children) {
    const on = b.dataset.view === v, d = VIEWS.find(x => x[0] === b.dataset.view);
    b.setAttribute("aria-pressed", String(on));
    b.innerHTML = "";
    b.append((on ? "● " : "") + d[1]);
    if (on || d[2]) { const sm = document.createElement("small"); sm.textContent = on ? "showing" : d[2]; b.appendChild(sm); }
  }
  for (const el of document.querySelectorAll("[data-v]")) {
    if (el.parentElement.closest("[data-v]")) { el.hidden = el.dataset.v.split(" ").indexOf(v) < 0; continue; }
    el.hidden = !v || el.dataset.v.split(" ").indexOf(v) < 0 || (el.hasAttribute("data-live") && mis);
  }
  // each decode list needs its decoder; Listen stays reachable while audio
  // plays, and on WSPR, where the phone is the only way to hear it
  const dec = curDec();
  if (!st || pdec(st) !== "js8") $("js8").hidden = true;
  if (!st || pdec(st) !== "wspr") $("wspr").hidden = $("wStat").hidden = true;
  $("jCount").hidden = $("wCount").hidden = v === "digital";
  if (v === "digital" && (A.on || (dec === "wspr" && !mis))) $("listenCard").hidden = false;
  $("aPick").hidden = $("aPick").hidden || !profiles;
  $("lPick").hidden = $("lPick").hidden || !profAvail;
  $("jPick").hidden = $("jPick").hidden || !profAvail;
  const nt = $("note");
  if (mis && st && !switching) {
    const p = activeProf();
    nt.textContent = "Receiver is on " + st.profile + (p && p.description ? " (" + p.description + ")" : "") + ". " +
      (v === "digital" ? "Pick a digital mode to switch." : "Pick a station to switch.");
    nt.hidden = false;
  } else nt.hidden = true;
  // RF gain and the speaker slider live in whichever view shows them
  const home = v === "listen" ? $("qual") : $("sliders");
  if ($("gainSl").parentElement !== home) { home.appendChild($("gainSl")); home.appendChild($("volSl")); }
  if (v === "listen") home.appendChild($("sqSl"));
  renderProfiles(); renderQual();
  if (v === "manual") requestAnimationFrame(() => { onResize(); pollSpecSoon(); });
}

let pickKey = "";
function profBtn(p, top, sub) {
  const act = p.name === activeName() && !switching;
  const el = document.createElement(act ? "div" : "button");
  el.className = act ? "prof cur" : "btn prof";
  const add = (cls, t) => { const s = document.createElement("span"); s.className = cls; s.textContent = t; el.appendChild(s); };
  add("pd", top); add("pf", sub);
  if (act) add("pa", "● Active");
  else {
    el.type = "button";
    if (switching && switching.name === p.name) add("pa", "■ Switching…");
    else if (!!p.upconvert !== curUp()) add("pw", "▲ Flip the Ham It Up to " + hiuWord(p.upconvert));
    el.disabled = conn !== "ok" || !!switching;
    el.onclick = () => askSwitch(p);
  }
  return el;
}
function renderProfiles() {
  const key = JSON.stringify([profiles, activeName(), curUp(), conn === "ok", switching && switching.name, view]);
  if (key === pickKey) return;
  pickKey = key;
  const all = profiles ? profiles.profiles : [];
  const mk = (id, list, f) => {
    const box = $(id); box.textContent = "";
    if (!profiles) { const m = document.createElement("span"); m.className = "jmsg"; m.textContent = profAvail ? "Loading stations" : ""; box.appendChild(m); return; }
    if (!list.length) { const m = document.createElement("span"); m.className = "jmsg"; m.textContent = "No profiles of this kind are saved."; box.appendChild(m); return; }
    for (const p of list) box.appendChild(f(p));
  };
  const grouped = (id, ls, groups, f) => {
    if (!profiles || !ls.length) { mk(id, ls, null); return; }
    const box = $(id); box.textContent = "";
    for (const [k, title, test] of groups) {
      const g = ls.filter(test);
      if (!g.length) continue;
      const h = document.createElement("div"); h.className = "pgroup"; h.textContent = title; box.appendChild(h);
      const l = document.createElement("div"); l.className = "plist"; box.appendChild(l);
      for (const p of g) l.appendChild(f(p));
    }
  };
  if (view === "digital") grouped("jPickL", all.filter(p => pdec(p)), DECODERS.map(([d, t]) => [d, t, p => pdec(p) === d]),
    p => profBtn(p, p.name, (p.description ? p.description + " · " : "") + fmtMHz(p.freq)));
  if (view === "manual") mk("aPickL", all, p => profBtn(p, pdesc(p), p.name + " · " + fmtMHz(p.freq) + " · " + p.mode + (pdec(p) ? " · " + decName(pdec(p)) : "")));
  if (view === "listen") grouped("lPickL", all.filter(p => pkind(p) === "listen"), GROUPS.map(([m, t]) => [m, t, p => p.mode === m]),
    p => profBtn(p, pdesc(p), fmtMHz(p.freq) + " · " + (p.mode === "FM" ? "NFM" : p.mode)));
}

// switching
const dlg = $("dlg");
let dlgAct = null;
$("dlgNo").onclick = () => dlg.close();
$("dlgYes").onclick = () => { dlg.close(); if (dlgAct) dlgAct(); };
dlg.addEventListener("close", () => { dlgAct = null; });
function askSwitch(p) {
  const cur = activeProf(), leavingJs8 = curDec() === "js8" || !!(cur && pdec(cur) === "js8");
  if (!leavingJs8) return doSwitch(p);
  $("dlgT").textContent = "Switch to " + p.name + "?";
  const b = $("dlgB"); b.textContent = "";
  const para = t => { const e = document.createElement("p"); e.textContent = t; b.appendChild(e); };
  para("Leaving " + activeName() + " closes JS8Call. rxd restarts, which takes a few seconds.");
  if (!!p.upconvert !== curUp()) para("▲ Then flip the Ham It Up to " + hiuWord(p.upconvert) + ".");
  $("dlgYes").textContent = "Switch";
  dlgAct = () => doSwitch(p);
  dlg.showModal();
}
async function doSwitch(p) {
  showPmsg(""); $("swErr").hidden = true; $("flip").hidden = true;
  let r;
  try { r = await api("/api/profile", {name: p.name}); }
  catch (e) { showPmsg("Could not reach rxd. Still on " + activeName() + "."); return; }
  if (!r.ok) { showPmsg("rxd refused: " + ((r.doc && r.doc.error) || ("HTTP " + r.status))); return; }
  switching = {name: p.name, desc: pdesc(p), prevUp: curUp(), wantUp: !!p.upconvert};
  setText($("swT"), "■ Switching to " + p.name + "…");
  setText($("swS"), "rxd restarts on " + pdesc(p) + "; this takes a few seconds." +
    (switching.wantUp !== switching.prevUp ? " Flip the Ham It Up to " + hiuWord(switching.wantUp) + "." : ""));
  clearTimeout(switchTimer);
  switchTimer = setTimeout(switchTimeout, 25000);
  renderConn(); drawSpecMsg(downMsg());
  clearTimeout(statusTimer); statusTimer = setTimeout(pollStatus, 1500);
}
function finishSwitch() {
  const sw = switching;
  clearTimeout(switchTimer); switching = null;
  if (curUp() !== sw.prevUp) {
    setText($("flipT"), "▲ Flip the Ham It Up to " + hiuWord(curUp()) + ". " + sw.desc + " needs it; without it you hear nothing.");
    $("flip").hidden = false;
  }
  if (muted() && st.volume > 0) { store("spkprev", String(st.volume)); tune({volume: 0}, 0); }
  jKey = null; wKey = null;
  renderConn(); renderView();
  loadProfiles();
}
function switchTimeout() {
  const sw = switching; if (!sw) return;
  switching = null;
  setText($("swErrT"), "✕ The switch to " + sw.name + " did not finish. " +
    (conn === "ok" && st ? "rxd is still on " + st.profile + "." : "rxd has not come back after 25 seconds."));
  $("swErr").hidden = false;
  renderConn(); renderView();
  if (conn === "ok") loadProfiles();
}
$("swErrOk").onclick = () => { $("swErr").hidden = true; };
$("flipOk").onclick = () => { $("flip").hidden = true; };

// ---------------------------------------------------------------- Listen view: station, bandwidth, squelch
const BWP = {WFM: [100e3, 150e3, 200e3], FM: [8e3, 12.5e3, 16e3], AM: [6e3, 10e3, 15e3]};
const sqSl = document.createElement("div");
sqSl.className = "sl"; sqSl.id = "sqSl"; sqSl.dataset.v = "listen";
sqSl.innerHTML = '<div class="lbl"><span>Squelch</span><span id="sqS" class="val">—</span></div>' +
  '<div class="row2"><button type="button" class="btn" id="sqOff">Off</button><button type="button" class="btn" id="sqOn">On</button></div>' +
  '<div id="sqLv"><div class="lbl"><label for="sq">Opens above</label><span id="sqV" class="val">—</span></div>' +
  '<input type="range" id="sq" min="-120" max="0" step="1"></div>';
$("qual").appendChild(sqSl);
for (const [i, name] of ["Narrow", "Normal", "Wide"].entries()) {
  const b = document.createElement("button");
  b.type = "button"; b.className = "btn"; b.dataset.i = i;
  b.onclick = () => { const p = BWP[st && st.mode]; if (p) { tune({bandwidth: p[i]}, 0); st.bandwidth = p[i]; renderQual(); } };
  b.dataset.name = name;
  $("bwP").appendChild(b);
}
const sqEl = $("sq");
function sqLevel() { const v = +load("squelch"); return v <= 0 && v >= -150 && load("squelch") !== null ? v : -60; }
$("sqOff").onclick = () => { tune({squelch: null}, 0); if (st) st.squelch = null; renderQual(); };
$("sqOn").onclick = () => { const v = sqLevel(); tune({squelch: v}, 0); if (st) st.squelch = v; renderQual(); };
sqEl.oninput = () => { const v = +sqEl.value; store("squelch", String(v)); setText($("sqV"), "−" + Math.abs(v) + " dBFS"); fill(sqEl); tune({squelch: v}, 200); };
track(sqEl, "squelch");
function renderQual() {
  if (!st || view !== "listen") return;
  const p = activeProf();
  setText($("nName"), p ? pdesc(p) : st.profile || "—");
  setText($("nFreq"), fmtMHz(st.freq));
  setText($("nMode"), st.mode === "FM" ? "NFM" : st.mode);
  const pre = BWP[st.mode] || [];
  for (const b of $("bwP").children) {
    const hz = pre[+b.dataset.i];
    b.hidden = !hz;
    if (!hz) continue;
    b.innerHTML = ""; b.append(b.dataset.name);
    const sm = document.createElement("small"); sm.textContent = fmtBw(hz); b.appendChild(sm);
    b.setAttribute("aria-pressed", String(Math.abs(st.bandwidth - hz) < 1));
  }
  const named = pre.findIndex(hz => Math.abs(st.bandwidth - hz) < 1);
  setText($("bwPV"), named >= 0 ? fmtBw(Math.round(st.bandwidth)) : "Custom, " + fmtBw(Math.round(st.bandwidth)));
  // squelch: NFM voice only, and only if this rxd reports it
  const hasSq = st.mode === "FM" && "squelch" in st;
  $("sqSl").hidden = !hasSq;
  if (hasSq) {
    const on = st.squelch !== null && st.squelch !== undefined;
    $("sqOff").setAttribute("aria-pressed", String(!on)); $("sqOn").setAttribute("aria-pressed", String(on));
    $("sqLv").hidden = !on;
    if (on && !held("squelch")) { sqEl.value = st.squelch; fill(sqEl); setText($("sqV"), (st.squelch < 0 ? "−" : "") + Math.abs(st.squelch) + " dBFS"); }
    if (!on) setText($("sqS"), "Off, always open", "val");
    else if (st.squelch_open) setText($("sqS"), "● Open (signal)", "val ok");
    else setText($("sqS"), "■ Closed (quiet)", "val dimc");
  }
}

// ---------------------------------------------------------------- uConsole speaker mute
function muted() { return load("spkprev") !== null; }
function syncMute() {
  if (muted() && st && st.volume > 0 && !held("volume")) forget("spkprev");
  renderMute();
}
function renderMute() {
  const b = $("mute"), m = muted();
  b.disabled = conn !== "ok" || !!switching || !st || (!m && st.volume === 0);
  b.setAttribute("aria-pressed", String(m));
  if (m) setText(b, "Unmute uConsole speaker (back to " + Math.round(+load("spkprev") * 100) + " %)");
  else if (st && st.volume === 0) setText(b, "uConsole speaker is at 0 %");
  else setText(b, "Mute uConsole speaker");
}
$("mute").onclick = () => {
  if (!st) return;
  if (muted()) { const v = +load("spkprev") || 0.5; forget("spkprev"); setVol(v); tune({volume: v}, 0); st.volume = v; }
  else { store("spkprev", String(st.volume)); setVol(0); tune({volume: 0}, 0); st.volume = 0; }
  renderMute();
};

// ---------------------------------------------------------------- audio on this device
// rxd streams s16le mono PCM; chunks are queued and scheduled back to back on
// one AudioContext clock, with ~0.4 s banked first and again after an underrun.
const A = {ctx: null, gain: null, on: false, gen: 0, want: 0, rate: 0, up: 1, bufRate: 0, ctl: null,
  q: [], qLen: 0, head: 0, playing: false, rest: -1, prev: 0, srcs: new Set(), scheduled: 0, underruns: 0,
  dropped: 0, bytes: 0, lastData: 0, retry: 0, err: "", rt: 0, tick: 0};
window.rxdAudio = A;  // read-only inspection from the console
function rateFor(m) { return m === "WFM" ? 24000 : 12000; }
function insecure() { return window.isSecureContext === false ? " This page is plain http, not a secure context, and some browsers limit audio there." : ""; }
const pvol = $("pvol");
pvol.value = load("phonevol") !== null ? +load("phonevol") : 100;
function phoneGain() { const v = +pvol.value / 100; return v * v; }
function renderPvol() { setText($("pvolV"), pvol.value + " %"); fill(pvol); if (A.gain) A.gain.gain.value = phoneGain(); }
pvol.oninput = () => { store("phonevol", pvol.value); renderPvol(); };
renderPvol();

$("listen").onclick = () => {
  if (A.on && A.ctx && A.ctx.state !== "running") { A.ctx.resume().then(renderAudio, renderAudio); return; }
  if (A.on) stopListen(); else startListen();
};
function startListen() {
  const AC = window.AudioContext || window.webkitAudioContext;
  A.err = "";
  if (!AC || !window.fetch || !window.ReadableStream) { A.err = "this browser cannot play a live stream." + insecure(); renderAudio(); return; }
  try {
    if (!A.ctx) {
      A.ctx = new AC();
      A.gain = A.ctx.createGain(); A.gain.connect(A.ctx.destination);
      A.ctx.onstatechange = renderAudio;
    }
    A.gain.gain.value = phoneGain();
    A.ctx.resume().catch(() => {});
    // iOS unlocks output for a context that starts a source inside the tap
    const s = A.ctx.createBufferSource(); s.buffer = A.ctx.createBuffer(1, 1, A.ctx.sampleRate); s.connect(A.ctx.destination); s.start(0);
  } catch (e) { A.err = "the browser refused to start audio." + insecure(); renderAudio(); return; }
  A.on = true; A.retry = 0; A.underruns = 0;
  clearInterval(A.tick); A.tick = setInterval(audioTick, 250);
  connectAudio();
  renderView();
}
function stopListen() {
  A.on = false; A.gen++;
  if (A.ctl) A.ctl.abort();
  A.ctl = null; clearTimeout(A.rt); clearInterval(A.tick);
  dropAudio();
  if (A.ctx) A.ctx.suspend().catch(() => {});
  renderAudio(); renderView();
}
function dropAudio() {
  for (const s of A.srcs) { try { s.stop(); } catch (e) {} }
  A.srcs.clear(); A.q = []; A.qLen = 0; A.playing = false; A.rest = -1;
}
function setRate(rate) {
  A.rate = rate; A.up = 1;
  try { A.ctx.createBuffer(1, 1, rate); } catch (e) { A.up = Math.ceil(22050 / rate); }
  A.bufRate = rate * A.up;
}
async function connectAudio() {
  const gen = ++A.gen;
  if (A.ctl) A.ctl.abort();
  clearTimeout(A.rt);
  dropAudio();
  const want = rateFor(st ? st.mode : "USB");
  A.want = want;
  const ctl = new AbortController(); A.ctl = ctl;
  renderAudio();
  let why = "";
  try {
    const r = await fetch("/api/audio?rate=" + want, {cache: "no-store", signal: ctl.signal});
    if (gen !== A.gen) return;
    if (!r.ok) {
      let d = null; try { d = await r.json(); } catch (e) {}
      why = r.status === 404 ? "this rxd has no audio stream." : "rxd refused: " + ((d && d.error) || "HTTP " + r.status) + ".";
      throw new Error(why);
    }
    if (!r.body || !r.body.getReader) { why = "this browser cannot read a stream." + insecure(); throw new Error(why); }
    setRate(+r.headers.get("X-Audio-Rate") || want);
    A.lastData = now();
    const rd = r.body.getReader();
    for (;;) {
      const x = await rd.read();
      if (gen !== A.gen) { rd.cancel().catch(() => {}); return; }
      if (x.done) break;
      A.bytes += x.value.length; A.lastData = now(); A.retry = 0; A.err = "";
      push(x.value);
    }
  } catch (e) { if (gen !== A.gen) return; }
  if (gen !== A.gen || !A.on) return;
  A.retry++; A.err = why;
  renderAudio();
  A.rt = setTimeout(() => { if (A.on && gen === A.gen) connectAudio(); }, why ? 5000 : Math.min(500 * A.retry, 3000));
}
function push(u8) {
  let b = u8;
  if (A.rest >= 0) { b = new Uint8Array(u8.length + 1); b[0] = A.rest; b.set(u8, 1); A.rest = -1; }
  const n = b.length >> 1;
  if (b.length & 1) A.rest = b[b.length - 1];
  if (!n) return;
  const dv = new DataView(b.buffer, b.byteOffset, n * 2), up = A.up, f = new Float32Array(n * up);
  if (up === 1) for (let i = 0; i < n; i++) f[i] = dv.getInt16(2 * i, true) / 32768;
  else {
    let p = A.prev;
    for (let i = 0; i < n; i++) { const x = dv.getInt16(2 * i, true) / 32768; for (let k = 1; k <= up; k++) f[i * up + k - 1] = p + (x - p) * k / up; p = x; }
    A.prev = p;
  }
  A.q.push(f); A.qLen += f.length;
  pump();
}
function pump() {
  const ctx = A.ctx, t = ctx.currentTime, R = A.bufRate;
  if (A.playing && A.head < t + 0.01) { A.playing = false; A.underruns++; }
  if (!A.playing) {
    if (A.qLen < R * 0.4) return;
    A.head = t + 0.05; A.playing = true;
  } else if (A.qLen < R * 0.05) return;
  if (A.head - t > 0.9) { A.dropped += A.qLen; A.q = []; A.qLen = 0; return; }  // clocks drift: stay near 0.4 s
  const buf = ctx.createBuffer(1, A.qLen, R), ch = buf.getChannelData(0);
  let o = 0; for (const c of A.q) { ch.set(c, o); o += c.length; }
  A.q = []; A.qLen = 0;
  const s = ctx.createBufferSource(); s.buffer = buf; s.connect(A.gain); s.start(A.head);
  A.head += buf.duration; A.scheduled++;
  A.srcs.add(s); s.onended = () => A.srcs.delete(s);
}
function audioTick() {
  // a stream that stalls without closing (rxd went away mid-restart) is dropped and retried
  if (A.on && A.ctl && A.lastData && now() - A.lastData > 3000 && !A.err) { A.lastData = 0; A.ctl.abort(); connectAudio(); }
  renderAudio();
}
function renderAudio() {
  const b = $("listen"), el = $("aState");
  let t, cls, depth = "";
  if (!A.on) {
    setText(b, "▶ Listen on this device"); b.setAttribute("aria-pressed", "false");
    if (A.err) { t = "✕ Audio unavailable: " + A.err; cls = "astate bad"; } else { t = "■ Not listening"; cls = "astate dimc"; }
  } else if (A.ctx.state !== "running") {
    setText(b, "▶ Resume listening"); b.setAttribute("aria-pressed", "true");
    t = "■ Paused by the browser. Tap Resume listening."; cls = "astate warn";
  } else {
    setText(b, "■ Stop listening"); b.setAttribute("aria-pressed", "true");
    const d = A.head - A.ctx.currentTime;
    if (A.err) { t = "✕ Audio unavailable: " + A.err + " Retrying."; cls = "astate bad"; }
    else if (A.playing && d > 0) { t = "● Listening, " + trim(A.rate / 1000, 1) + " kHz"; cls = "astate ok"; depth = "Buffer " + Math.round(d * 1000) + " ms"; }
    else if (A.retry || (switching && !A.playing)) { t = "▲ Reconnecting to rxd"; cls = "astate warn"; }
    else { t = "▲ Buffering"; cls = "astate warn"; }
  }
  setText(el, t, cls); setText($("aDepth"), depth);
}
renderAudio();

// ---------------------------------------------------------------- JS8 decodes
const JMAX = 500;
let jOn = false, jKey = null, jSeq = 0, jTimer = 0, jHeard = new Map(), jFilt = "";
function js8Sync() {
  const want = !!(st && pdec(st) === "js8");
  if (want && st.profile !== jKey) {
    jKey = st.profile; jOn = true; jSeq = 0; jHeard = new Map();
    $("jList").textContent = ""; setText($("jMsg"), "Loading decodes");
    pollJs8();
  } else if (!want && jOn) { jOn = false; jKey = null; clearTimeout(jTimer); }
}
async function pollJs8() {
  clearTimeout(jTimer);
  if (!jOn) return;
  if (document.hidden) { jTimer = setTimeout(pollJs8, 5000); return; }
  const key = jKey;
  try {
    const r = await api("/api/js8?after=" + jSeq);
    if (key !== jKey) return;
    if (r.ok && r.doc && Array.isArray(r.doc.lines)) {
      addJs8(r.doc.lines.filter(l => l.seq > jSeq).sort((a, b) => a.seq - b.seq));
      if (typeof r.doc.seq === "number") jSeq = Math.max(jSeq, r.doc.seq);
      jStatus("");
    } else jStatus(r.status === 404 ? "✕ This rxd has no JS8 feed." : "✕ No decodes: " + ((r.doc && r.doc.error) || "HTTP " + r.status));
  } catch (e) {}
  if (jOn && key === jKey) jTimer = setTimeout(pollJs8, 2500);
}
function mineLine(l) {
  if (l.mycall === true) return true;
  const c = (st && st.js8_call || "").toUpperCase();
  if (!c) return false;
  return (l.to || "").toUpperCase() === c || String(l.text || "").toUpperCase().split(/[^A-Z0-9\/]+/).indexOf(c) >= 0;
}
function jMatch(li) { return !jFilt || li.dataset.k.indexOf(jFilt) >= 0; }
function addJs8(lines) {
  if (!lines.length) return jStatus("");
  const list = $("jList"), frag = document.createDocumentFragment(), call = (st && st.js8_call) || "";
  for (let i = lines.length - 1; i >= 0; i--) {
    const l = lines[i], li = document.createElement("li"), mine = mineLine(l), fr = String(l.from || "?");
    li.className = "jl" + (mine ? " me" : "");
    li.dataset.k = [fr, l.to || "", l.text || ""].join(" ").toUpperCase();
    li.dataset.f = fr;
    const add = (tag, cls, t) => { const e = document.createElement(tag); e.className = cls; e.textContent = t; li.appendChild(e); };
    add("span", "jt", lineTime(l.time, true));
    add("span", "js", typeof l.snr === "number" ? "SNR " + signed(l.snr) : "SNR —");
    add("b", "jfr", fr);
    if (mine) add("span", "jme", "◆ " + (call || "You"));
    let text = String(l.text || "");
    if (text.toUpperCase().indexOf(fr.toUpperCase() + ":") === 0) text = text.slice(fr.length + 1).trim();
    add("span", "jx", text);
    li.hidden = !jMatch(li);
    jHeard.set(fr, (jHeard.get(fr) || 0) + 1);
    frag.appendChild(li);
  }
  list.insertBefore(frag, list.firstChild);
  while (list.children.length > JMAX) {
    const f = list.lastChild.dataset.f, n = jHeard.get(f) - 1;
    if (n > 0) jHeard.set(f, n); else jHeard.delete(f);
    list.removeChild(list.lastChild);
  }
  jStatus("");
}
function jStatus(err) {
  const list = $("jList"), n = jHeard.size;
  const heard = n + (n === 1 ? " station heard" : " stations heard");
  let shown = 0; if (jFilt) for (const li of list.children) if (!li.hidden) shown++;
  setText($("jCount"), heard); setText($("jHeard"), n + (n === 1 ? " station" : " stations"), "v");
  if (err) setText($("jMsg"), err);
  else if (!list.children.length) setText($("jMsg"), "No decodes yet. They appear here as JS8Call hears them.");
  else if (jFilt) setText($("jMsg"), shown ? "Showing " + shown + " of " + list.children.length + " lines with " + jFilt : "No lines with " + jFilt + ".");
  else setText($("jMsg"), "");
}
$("jFilter").oninput = () => {
  jFilt = $("jFilter").value.trim().toUpperCase();
  $("jClear").hidden = !jFilt;
  for (const li of $("jList").children) li.hidden = !jMatch(li);
  jStatus("");
};
$("jClear").onclick = () => { $("jFilter").value = ""; $("jFilter").oninput(); $("jFilter").focus(); };
function renderJs8Stat(s, rxText, rxCls) {
  if (view !== "digital") return;
  setText($("jHiu"), s.upconverter_hz > 0 ? "⇅ UPCONVERT" : "→ BYPASS", "v");
  setText($("jRx"), rxText, rxCls);
  const lv = s.level_dbfs;
  setText($("jLvl"), typeof lv === "number" ? (lv < 0 ? "−" : "") + Math.abs(lv).toFixed(1) + " dBFS" : "— dBFS", "v");
  // JS8's 15 s slots and WSPR's 2 min ones fail silently past about 2 s of
  // clock error, so a clock that isn't synced is the first thing to say.
  const c = s.clock || {};
  if (c.synced === true) setText($("jClock"), "● Synced" + (c.source ? " (" + c.source + ")" : ""), "v ok");
  else if (c.synced === false) setText($("jClock"), "✕ Not synced", "v bad");
  else setText($("jClock"), "? Unknown", "v");
  const bad = $("jClockBad");
  bad.hidden = c.synced !== false;
  if (c.synced === false) {
    const off = typeof c.offset_s === "number" ? " It is " + Math.abs(c.offset_s).toFixed(1) + " s " + (c.offset_s > 0 ? "fast" : "slow") + "." : "";
    setText(bad, "✕ Clock not synced: " + decName(pdec(s)) + " won't decode until it is." + off + " No GPS fix and no network? Check chronyc sources.");
  }
}

// ---------------------------------------------------------------- WSPR spots
let wOn = false, wKey = null, wSeq = 0, wTimer = 0, wHeard = new Map(), wFilt = "", wBusy = false;
function wsprSync() {
  const want = !!(st && pdec(st) === "wspr");
  if (want && st.profile !== wKey) {
    wKey = st.profile; wOn = true; wSeq = 0; wHeard = new Map();
    $("wList").textContent = ""; setText($("wsMsg"), "Loading spots");
    pollWspr();
  } else if (!want && wOn) { wOn = false; wKey = null; clearTimeout(wTimer); }
}
async function pollWspr() {
  clearTimeout(wTimer);
  if (!wOn) return;
  if (document.hidden) { wTimer = setTimeout(pollWspr, 5000); return; }
  const key = wKey;
  try {
    const r = await api("/api/wspr?after=" + wSeq);
    if (key !== wKey) return;
    if (r.ok && r.doc && Array.isArray(r.doc.lines)) {
      addWspr(r.doc.lines.filter(l => l.seq > wSeq).sort((a, b) => a.seq - b.seq));
      if (typeof r.doc.seq === "number") wSeq = Math.max(wSeq, r.doc.seq);
      wStatus("");
    } else wStatus(r.status === 404 ? "✕ This rxd has no WSPR feed." : "✕ No spots: " + ((r.doc && r.doc.error) || "HTTP " + r.status));
  } catch (e) {}
  if (wOn && key === wKey) wTimer = setTimeout(pollWspr, 5000);
}
function fmtPower(dbm) {
  const w = Math.pow(10, (dbm - 30) / 10);
  const mw = w * 1000;
  return dbm + " dBm (" + (w >= 1 ? trim(w, 1) + " W" : (mw < 10 ? trim(mw, 1) : String(Math.round(mw))) + " mW") + ")";
}
function wMatch(li) { return !wFilt || li.dataset.k.indexOf(wFilt) >= 0; }
function addWspr(lines) {
  if (!lines.length) return wStatus("");
  const list = $("wList"), frag = document.createDocumentFragment(), dial = st ? st.freq : null;
  for (let i = lines.length - 1; i >= 0; i--) {
    const l = lines[i], li = document.createElement("li"), call = String(l.call || "?");
    li.className = "jl wl";
    li.dataset.k = [call, l.grid || ""].join(" ").toUpperCase();
    li.dataset.f = call;
    const add = (tag, cls, t) => { const e = document.createElement(tag); e.className = cls; e.textContent = t; li.appendChild(e); };
    add("span", "jt", lineTime(l.time));
    add("b", "wc", call);
    if (l.grid) add("span", "wg", l.grid);
    if (typeof l.km === "number") add("span", "wd", Math.round(l.km * 0.621371).toLocaleString() + " mi");
    const x = [typeof l.snr === "number" ? "SNR " + signed(l.snr) + " dB" : "SNR —"];
    if (typeof l.dbm === "number") x.push(fmtPower(l.dbm));
    if (typeof l.freq === "number" && typeof dial === "number") x.push("Audio " + Math.round(l.freq - dial) + " Hz");
    add("span", "wx", x.map(t => t.replace(/ /g, "\u00a0")).join(" · "));
    li.hidden = !wMatch(li);
    wHeard.set(call, (wHeard.get(call) || 0) + 1);
    frag.appendChild(li);
  }
  list.insertBefore(frag, list.firstChild);
  while (list.children.length > JMAX) {
    const f = list.lastChild.dataset.f, n = wHeard.get(f) - 1;
    if (n > 0) wHeard.set(f, n); else wHeard.delete(f);
    list.removeChild(list.lastChild);
  }
  wStatus("");
}
function wStatus(err) {
  const list = $("wList"), n = wHeard.size;
  let shown = 0; if (wFilt) for (const li of list.children) if (!li.hidden) shown++;
  setText($("wCount"), n + (n === 1 ? " station heard" : " stations heard"));
  if (st && pdec(st) === "wspr") setText($("jHeard"), n + (n === 1 ? " station" : " stations"), "v");
  if (err) setText($("wsMsg"), err);
  else if (!list.children.length) setText($("wsMsg"), "No spots yet. They appear here after each two-minute slot is decoded.");
  else if (wFilt) setText($("wsMsg"), shown ? "Showing " + shown + " of " + list.children.length + " spots with " + wFilt : "No spots with " + wFilt + ".");
  else setText($("wsMsg"), "");
}
$("wFilter").oninput = () => {
  wFilt = $("wFilter").value.trim().toUpperCase();
  $("wClear").hidden = !wFilt;
  for (const li of $("wList").children) li.hidden = !wMatch(li);
  wStatus("");
};
$("wClear").onclick = () => { $("wFilter").value = ""; $("wFilter").oninput(); $("wFilter").focus(); };
function renderWsprStat(s) {
  const w = s.wspr;
  if (!w || view !== "digital") return;
  const slot = slotTime(w.decoding || w.slot);
  if (w.state === "recording") setText($("wCycle"), "● Recording the " + slot + " slot", "v ok");
  else if (w.state === "decoding") setText($("wCycle"), "◆ Decoding the " + slot + " slot", "v");
  else setText($("wCycle"), "■ Next slot " + slot, "v");
  const L = w.last;
  if (!L) setText($("wLast"), "No slot decoded yet", "v dimc");
  else setText($("wLast"), (L.spots ? L.spots + (L.spots === 1 ? " spot" : " spots") : "No spots") + " in the " + slotTime(L.slot) + " slot", "v");
  const e = $("wErr");
  e.hidden = !w.error;
  if (w.error) setText(e, "✕ WSPR decoder: " + w.error);
  const p = w.report || {}, id = [p.call, p.grid].filter(Boolean).join(" ");
  if (!p.enabled) setText($("wRep"), "■ Not reporting" + (p.reason ? ": " + p.reason : ""), "v dimc");
  else if (p.online === false) setText($("wRep"), "▲ Offline: " + (p.pending || 0) + (p.pending === 1 ? " spot" : " spots") + " waiting", "v warn");
  else if (p.error) setText($("wRep"), "✕ " + p.error, "v bad");
  else setText($("wRep"), "● Reporting to WSPRnet" + (id ? " as " + id : "") + " · " + (p.sent || 0) + " sent" +
    (p.pending ? " · " + p.pending + " waiting" : ""), "v ok");
  // the switch only where reporting can be on: a callsign and grid are set
  $("wRepSl").hidden = !!p.reason;
  const on = !!p.enabled, dis = wBusy || conn !== "ok" || !!switching;
  setText($("wRepS"), on ? "On" : "Off", "val");
  for (const [id2, v] of [["wRepOff", false], ["wRepOn", true]]) {
    const b = $(id2);
    b.setAttribute("aria-pressed", String(on === v));
    setText(b, (on === v ? "● " : "") + (v ? "On" : "Off"));
    b.disabled = dis;
  }
}
async function setReport(on) {
  if (!st || !st.wspr || wBusy) return;
  wBusy = true; $("wMsg").hidden = true; renderWsprStat(st);
  let msg = "";
  try {
    const r = await api("/api/tune", {wspr_report: on});
    if (r.ok && r.doc && typeof r.doc.freq === "number") { wBusy = false; applyStatus(r.doc); return; }
    msg = "rxd refused: " + ((r.doc && r.doc.error) || "HTTP " + r.status);
  } catch (e) { msg = "Could not reach rxd. Reporting is unchanged."; }
  wBusy = false;
  setText($("wMsg"), "✕ " + msg); $("wMsg").hidden = false;
  if (st) renderWsprStat(st);
}
$("wRepOff").onclick = () => setReport(false);
$("wRepOn").onclick = () => setReport(true);

// ---------------------------------------------------------------- start
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) {
    pollStatus(); pollSpecSoon(); if (jOn) pollJs8(); if (wOn) pollWspr();
    if (A.on && A.ctx && A.ctx.state !== "running") A.ctx.resume().catch(() => {});
    renderAudio();
  }
});
if (window.ResizeObserver) new ResizeObserver(onResize).observe($("ctl"));
window.addEventListener("resize", onResize);
renderView();
onResize(); readColors();
pollStatus();
})();
</script>
</body>
</html>
RXDWEB
    log "installed the rxd browser UI"

    # Where rxd listens when its command line does not say.
    # Written once and then left alone, so turning the LAN off survives
    # 'maint'. Rigctl stays on loopback: only JS8Call uses it.
    if [[ -e /etc/rx/rxd.env ]]; then
      log "kept /etc/rx/rxd.env as it is"
    else
      write_file /etc/rx/rxd.env 0644 <<'RXDENV'
# Managed by rx/setup.sh, written once: edits here survive re-runs.
# Where rxd listens, as HOST:PORT; read by rxd@.service. A --http or
# --rigctl flag wins over these.
#
# RXD_HTTP=0.0.0.0:8073 serves rxd's API and browser UI to the LAN and the
# tailnet (the firewall admits 8073 from nowhere else). There is no
# authentication: anyone on the LAN can tune the radio. To keep it to this
# machine, set RXD_HTTP=127.0.0.1:8073, then
# 'systemctl --user restart rxd@*'.
#
# RXD_RIGCTL is left unset, so rigctl stays on 127.0.0.1:4532 for JS8Call.
RXD_HTTP=0.0.0.0:8073
RXDENV
      log "wrote /etc/rx/rxd.env (HTTP on the LAN)"
    fi

    # A template, never enabled: 'radio' starts and stops rxd@NAME itself, so
    # only one profile owns the dongle at a time. PipeWire runs per user here,
    # socket-activated, so rxd is ordered after its Pulse server rather than
    # left to race it at login.
    write_file /etc/systemd/user/rxd@.service 0644 <<'RXDUNIT'
# Managed by rx/setup.sh — the rxd receiver for one radio profile.
# Started and stopped by 'radio'; not enabled on its own.
[Unit]
Description=rxd receiver (%i)
Wants=pipewire-pulse.service
After=pipewire-pulse.service wireplumber.service

[Service]
EnvironmentFile=-/etc/rx/rxd.env
ExecStart=/usr/local/bin/rxd %i
Restart=on-failure
RestartSec=3
RXDUNIT
    log "wrote the rxd@.service user template"

    # Without lingering the desktop user's systemd only runs while they are
    # logged in. When it is not running, it reads the template fresh at the
    # next login, so there is nothing to reload.
    local uid
    uid=$(id -u "$DESKTOP_USER")
    if systemctl is-active --quiet "user@${uid}.service" 2>/dev/null; then
      run systemctl --user --machine="${DESKTOP_USER}@" daemon-reload \
        || warn "could not reload ${DESKTOP_USER}'s systemd; log out and back in to pick up rxd@.service"
    fi

    # rxd replaces SDR++ outright. Purge it from machines provisioned before
    # the switch. Its user config is left in place.
    local pkg; local -a sdrpp_pkgs=()
    for pkg in sdrpp-brown sdrpp; do
      if pkg_installed "$pkg"; then sdrpp_pkgs+=("$pkg"); fi
    done
    if (( ${#sdrpp_pkgs[@]} )); then
      run apt-get purge -y "${sdrpp_pkgs[@]}"
      log "purged ${sdrpp_pkgs[*]} (replaced by rxd)"
    fi
    if compgen -G "$USER_HOME/.config/sdrpp*" >/dev/null; then
      note "SDR++ is gone, replaced by rxd. Its old settings are still in ~/.config/sdrpp* and can be deleted."
    fi
    # The gqrx-to-SDR++ bookmark converter earlier revisions installed. Only
    # ours; the gqrx config and its backup tarball are left alone.
    if grep -qs 'Managed by rx/setup.sh' /usr/local/sbin/gqrx-bookmarks-to-sdrpp; then
      run rm -f /usr/local/sbin/gqrx-bookmarks-to-sdrpp
      log "removed the old gqrx-bookmarks-to-sdrpp converter"
    fi

    # Switchable, resumable receiver profiles, played by rxd through its
    # systemd user unit. See the docstring for how a profile is kept.
    write_file /usr/local/bin/radio 0755 <<'RADIO'
#!/usr/bin/env python3
"""Managed by rx/setup.sh — switchable, resumable receiver profiles.

  radio                list profiles; * marks the active one
  radio NAME           switch to NAME. rxd, the receiver, restarts on NAME; a
                       JS8 profile also brings up JS8Call on its dial, and
                       a WSPR profile has rxd decode WSPR itself. The
                       profile being left is saved first, so coming back to
                       it resumes where it was. NAME when it is already up
                       changes nothing.
  radio off            save the active profile, stop rxd, close JS8Call
  radio resume         bring the active profile back up (i3 runs it at login)
  radio save [NAME]    save rxd's current tuning as NAME (default: active)
  radio reset NAME     forget your saved state for NAME; back to its default
  radio show NAME      print a profile as JSON
  radio help           this text

  radio meshtastic     put the LoRa radio on Meshtastic, North Texas settings
  radio meshcore       put the LoRa radio on MeshCore, North Texas settings
  radio mesh           start the active mesh and open its client
  radio mesh nodes     who has been heard
  radio mesh send TEXT          to the primary (Meshtastic) or public channel
  radio mesh dm NAME TEXT       direct message; Tab completes names
  radio mesh join URL           Meshtastic: add channels from a shared URL
  radio mesh join NAME [KEY]    MeshCore: add a channel (#name needs no key)
  radio mesh info      identity, radio settings, channels -- without starting it
  radio mesh on | off  start / stop the active mesh

  Every mesh command but info starts the mesh if it is not running. The two
  networks share one radio, so choosing one stops the other. Neither starts at
  boot.

  --no-focus           leave focus where it is (JS8Call)

Tab completes profile names (/usr/share/bash-completion/completions/radio).

Every amateur band has a JS8 and a WSPR profile on its standard dial:
js8-160m ... js8-2m and wspr-2190m ... wspr-2m. On 40 m they keep their old
names, js8 and wspr (js8-40m and wspr-40m mean the same). 6 m and 2 m need
the Ham It Up on BYPASS. rxd's band plan (Auto in its Digital view) picks
among them by band conditions, time of day and what it has heard.

A profile is tuning only: frequency, offset mode, demodulator and its
settings, audio sink and volume, the RTL-SDR's settings and, for JS8
profiles, JS8Call's dial. A WSPR profile ("decoder": "wspr") also says
whether rxd reports its spots to WSPRnet ("wspr_report", on by default). The defaults below are starting points; saved
state lives in ~/.config/rx/radio/ and wins.

rxd (systemd user unit rxd@NAME) reads only ~/.config/rx/radio/NAME.json, so
the merged profile is written there before it starts. Its HTTP status on
127.0.0.1:8073 is where the tuning is saved from. One rxd runs at a time: it
holds the dongle. Edit NAME.json while it plays and
'systemctl --user kill -s HUP rxd@NAME' makes it re-read the file.
"""
import argparse
import configparser
import copy
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import urllib.request

HOME = os.path.expanduser("~")
STATE = os.path.join(HOME, ".config", "rx", "radio")
ACTIVE = os.path.join(STATE, "active")
JS8_INI = os.path.join(HOME, ".config", "JS8Call.ini")

JS8_CRIT, JS8_TREE = "(?i)^js8call$", 'js8call"'  # i3 criteria / tree match
# By absolute path, so a stray wrapper earlier on PATH cannot recurse.
JS8CALL = "/usr/bin/js8call"
JS8_NODE = "SDR_to_JS8"

# rxd's HTTP control port; module-level so the tests can point it elsewhere.
RXD_URL = "http://127.0.0.1:8073"
RXD_START_SECS = 15

NOOELEC = "57818712"  # NESDR SMArt v5, behind the Ham It Up
JS8_SINK = "SDR to JS8 (virtual cable)"
SPEAKER = "Built-in Audio"


def rtl(gain):
    # gain is an index into the tuner's gain table, not dB. On the R820T:
    # 4 = 3.7 dB, 10 = 16.6 dB, 20 = 37.2 dB. A saved gain_db wins over it.
    return {"serial": NOOELEC, "gain": gain, "biasT": False, "ppm": 0}


# USB as set by hand for JS8 on 2026-11-04.
USB_JS8 = {"bandwidth": 3000.0, "agcAttack": 47.916229248046875,
           "agcDecay": 4.896891117095947}
NFM = {"bandwidth": 12500.0}
WFM = {"bandwidth": 150000.0}
AM = {"bandwidth": 10000.0}


def js8(desc, dial):
    # The VFO sits 100 Hz under the dial, as tuned by hand for GhostNet; rxd
    # keeps that difference as a calibration. "decoder": "js8" and the dial
    # are all a JS8 profile says about decoding: JS8Call today (radio starts
    # it on js8call_dial), rxd's own decoder when it has one.
    return {"description": desc, "frequency": dial - 100.0,
            "offset": "auto", "demod": "USB",
            "demod_settings": USB_JS8, "sink": JS8_SINK, "volume": 0.2090567648410797,
            "rtl": rtl(4), "decoder": "js8", "js8call_dial": dial}


def wspr(desc, dial):
    # rxd records each two-minute slot and decodes it with wsprd; the
    # speaker stays silent (volume 0) but the browser and rxd-tui can listen.
    return {"description": desc, "frequency": dial, "offset": "auto",
            "demod": "USB", "demod_settings": {"bandwidth": 2800.0},
            "sink": SPEAKER, "volume": 0.0, "rtl": rtl(4),
            "decoder": "wspr", "wspr_report": True}


def vhf(desc, hz, demod="FM", settings=NFM, gain=20):
    return {"description": desc, "frequency": hz,
            "offset": "auto", "demod": demod, "demod_settings": settings,
            "sink": SPEAKER, "volume": 0.5, "rtl": rtl(gain)}


# Amateur bands, ITU Region 2 edges in Hz, lowest first: what band a
# frequency is in, for `radio --json` and rxd's band plan.
BANDS = (("2190m", 135700, 137800), ("630m", 472000, 479000),
         ("160m", 1800000, 2000000), ("80m", 3500000, 4000000),
         ("60m", 5250000, 5450000), ("40m", 7000000, 7300000),
         ("30m", 10100000, 10150000), ("20m", 14000000, 14350000),
         ("17m", 18068000, 18168000), ("15m", 21000000, 21450000),
         ("12m", 24890000, 24990000), ("10m", 28000000, 29700000),
         ("6m", 50000000, 54000000), ("2m", 144000000, 148000000),
         ("1.25m", 222000000, 225000000), ("70cm", 420000000, 450000000))

# Standard dial frequencies (USB), checked 2026-11-06. JS8: JS8Call's default
# list (JS8Call-improved 3.0.3, JS8_Main/FrequencyList.cpp; the original
# JS8Call 2.2 had 1842 kHz on 160 m and nothing on 60 m). WSPR: WSJT-X's
# default list (models/FrequencyList.cpp), which has no 60 m; 5364.7 kHz is
# where WSPRnet's 60 m spots are (wspr.live, 552,000 a week there against
# 190,000 on the older 5287.2).
JS8_DIALS = (("160m", 1843500), ("80m", 3578000), ("60m", 5363000), ("40m", 7078000),
             ("30m", 10130000), ("20m", 14078000), ("17m", 18104000), ("15m", 21078000),
             ("12m", 24922000), ("10m", 28078000), ("6m", 50318000), ("2m", 144178000))
WSPR_DIALS = (("2190m", 136000), ("630m", 474200), ("160m", 1836600), ("80m", 3568600),
              ("60m", 5364700), ("40m", 7038600), ("30m", 10138700), ("20m", 14095600),
              ("17m", 18104600), ("15m", 21094600), ("12m", 24924600), ("10m", 28124600),
              ("6m", 50293000), ("2m", 144489000))
# 40 m keeps the names it always had; js8-40m and wspr-40m are aliases.
BAND_NAMES = {("js8", "40m"): "js8", ("wspr", "40m"): "wspr"}


def band_profile_name(mode, band):
    return BAND_NAMES.get((mode, band), "%s-%s" % (mode, band))


ALIASES = {"%s-40m" % m: n for (m, _), n in BAND_NAMES.items()}


def band_of(hz):
    """The amateur band hz is in ("20m"), or None."""
    for name, lo, hi in BANDS:
        if lo <= hz <= hi:
            return name
    return None


def band_label(band):
    return band[:-1] + " m" if band.endswith("m") and not band.endswith("cm") else band


def band_profiles():
    """The band plan's profiles, one per mode and band: {name: profile}."""
    out = {}
    for mode, dials, make, title in (("js8", JS8_DIALS, js8, "JS8"),
                                     ("wspr", WSPR_DIALS, wspr, "WSPR")):
        for band, dial in dials:
            out[band_profile_name(mode, band)] = make(
                "%s, %s" % (title, band_label(band)), float(dial) if mode == "wspr" else dial)
    return out


BAND_PLAN = band_profiles()

PROFILES = {
    "ghostnet": js8("JS8 GhostNet, 40 m", 7107000),
    **BAND_PLAN,
    "vhf":      vhf("2 m calling", 146520000.0),
    "dcara":    vhf("DCARA", 146920000.0),
    "uhf":      vhf("70 cm calling", 446000000.0),
    "noaa":     vhf("NOAA weather", 162550000.0),  # strongest of the seven at EM13
    "fm-93.3":  vhf("93.3 FM", 93300000.0, "WFM", WFM, gain=10),
    "fm-105.3": vhf("105.3 FM", 105300000.0, "WFM", WFM, gain=10),
    # Below the R820T's range, so through the Ham It Up like HF: "auto"
    # upconverts anything under 30 MHz.
    "am-820":   vhf("820 AM", 820000.0, "AM", AM, gain=4),
}


def say(msg, kind=None):
    print("radio: " + msg, file=sys.stderr)
    # From dmenu or a launcher there is no terminal; surface what matters.
    if kind and os.environ.get("DISPLAY") and shutil.which("i3-nagbar"):
        subprocess.Popen(["i3-nagbar", "-t", kind, "-m", "radio: " + msg],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)


def die(msg):
    say(msg, "error")
    sys.exit(1)


# ------------------------------------------------------------------ files

def dump(path, doc):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=4)
    os.replace(tmp, path)


def read_ini():
    # Same parser settings as js8call-ghostnet-config: QSettings values
    # carry bare '%', ';' and '#', and keys are case-sensitive.
    cp = configparser.ConfigParser(interpolation=None, strict=False,
                                   delimiters=("=",), comment_prefixes=())
    cp.optionxform = str
    if os.path.isfile(JS8_INI):
        with open(JS8_INI, encoding="utf-8") as fh:
            cp.read_file(fh)
    return cp


def write_dial(hz):
    cp = read_ini()
    if not cp.has_section("Common"):
        cp.add_section("Common")
    cp.set("Common", "DialFreq", str(hz))
    tmp = JS8_INI + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        cp.write(fh, space_around_delimiters=False)
    os.replace(tmp, JS8_INI)


# --------------------------------------------------------------- profiles

def known():
    saved = []
    if os.path.isdir(STATE):
        saved = sorted(f[:-5] for f in os.listdir(STATE) if f.endswith(".json"))
    return list(PROFILES) + [n for n in saved if n not in PROFILES]


def profile(name):
    p = copy.deepcopy(PROFILES.get(name, {}))
    path = os.path.join(STATE, name + ".json")
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as fh:
            p.update(json.load(fh))
    if not p:
        die("no profile '%s' (have: %s)" % (name, ", ".join(known())))
    return p


def store(name, p):
    os.makedirs(STATE, exist_ok=True)
    dump(os.path.join(STATE, name + ".json"), p)


def ensure_stored(name, p):
    # rxd knows nothing of PROFILES: it reads only NAME.json, so a default
    # that was never saved has to be written out before rxd can play it.
    path = os.path.join(STATE, name + ".json")
    try:
        with open(path, encoding="utf-8") as fh:
            if json.load(fh) == p:
                return
    except (OSError, ValueError):
        pass
    store(name, p)


def active():
    try:
        with open(ACTIVE, encoding="utf-8") as fh:
            name = fh.read().strip()
    except OSError:
        return None
    return name if name in known() else None


def set_active(name):
    os.makedirs(STATE, exist_ok=True)
    with open(ACTIVE, "w", encoding="utf-8") as fh:
        fh.write(name + "\n")


def upconverting(p):
    """Whether rxd puts p through the Ham It Up's 125 MHz upconversion."""
    # "auto" (the default) follows the frequency, as rxd does: the R820T
    # cannot tune below about 24 MHz, so HF and AM broadcast go through the
    # upconverter. "Ham-It-Up" and "None" pin it on or off.
    mode = p.get("offset", "auto")
    if mode == "auto":
        return float(p["frequency"]) < float(p.get("upconvert_below_hz", 30e6))
    return mode != "None"


def decoder(p):
    return p.get("decoder") or ("js8" if p.get("js8call_dial") is not None else None)


def summary(name, p):
    path = "Ham It Up upconvert" if upconverting(p) else "Ham It Up bypass"
    return "%-10s %11.4f MHz %-4s %-19s %s" % (
        name, p["frequency"] / 1e6, p["demod"], path, p.get("description", ""))


def unit_name(name):
    # The unit passes %i to rxd verbatim, so keep to characters that need no
    # systemd escaping; anything else would reach rxd mangled.
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
        die("profile name '%s': use letters, digits, '.', '-' or '_'" % name)
    return "rxd@%s.service" % name


# ------------------------------------------------------------------ apps

def running(proc):
    return subprocess.run(["pgrep", "-x", proc],
                          stdout=subprocess.DEVNULL).returncode == 0


_desktop = {}


def desktop():
    """The environment for i3-msg and JS8Call: the desktop's, even when radio
    runs from SSH, a service or rxd (band plan switches), where DISPLAY and
    I3SOCK are unset. i3's socket is found the way i3 --get-socketpath would
    be asked, or failing that from i3's runtime directory."""
    if _desktop:
        return _desktop
    env = dict(os.environ)
    env.setdefault("DISPLAY", ":0")
    if not env.get("XAUTHORITY") and os.path.isfile(os.path.join(HOME, ".Xauthority")):
        env["XAUTHORITY"] = os.path.join(HOME, ".Xauthority")
    if not env.get("I3SOCK"):
        sock = ""
        try:
            sock = subprocess.run(["i3", "--get-socketpath"], env=env, capture_output=True,
                                  text=True, timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            pass
        if not sock:
            import glob
            found = glob.glob("/run/user/%d/i3/ipc-socket.*" % os.getuid())
            sock = max(found, key=os.path.getmtime) if found else ""
        if sock:
            env["I3SOCK"] = sock
    _desktop.update(env)
    return _desktop


def has_window(pat):
    tree = subprocess.run(["i3-msg", "-t", "get_tree"], env=desktop(),
                          capture_output=True, text=True).stdout
    return re.search(r'"class":"' + pat, tree, re.I) is not None


def i3(cmd):
    subprocess.run(["i3-msg", "-q", cmd], env=desktop(),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def close(proc, crit):
    """Close politely, so the app saves its own config; True if it was up."""
    if not running(proc):
        return False
    i3('[class="%s"] kill' % crit)
    for sig in (None, "-TERM", "-KILL"):
        if sig:
            subprocess.run(["pkill", sig, "-x", proc])
        for _ in range(30):
            if not running(proc):
                return True
            time.sleep(0.5)
    die("%s would not exit" % proc)


def start(argv, pat):
    subprocess.Popen(argv, env=desktop(), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(60):
        if has_window(pat):
            return
        time.sleep(0.5)
    die("%s did not open a window" % argv[0])


def ensure_js8_sink():
    # Normally made by /etc/pipewire/pipewire.conf.d/50-sdr-js8.conf when
    # PipeWire starts; a session that predates that file has to be given it.
    nodes = subprocess.run(["pw-cli", "ls", "Node"], capture_output=True,
                           text=True).stdout
    if 'node.name = "%s"' % JS8_NODE in nodes:
        return
    if subprocess.run(["pw-cli", "create-node", "adapter",
                       "{ factory.name=support.null-audio-sink node.name=%s "
                       "node.description=\"%s\" media.class=Audio/Sink "
                       "audio.position=[FL FR] object.linger=true }" % (JS8_NODE, JS8_SINK)],
                      stdout=subprocess.DEVNULL).returncode != 0:
        die("could not create the %s audio sink" % JS8_NODE)


def check_clock(mode):
    # JS8's 15 s and WSPR's 2 min slots tolerate about 2 s of clock error.
    # Outside that nothing decodes and nothing says why, so say it here.
    out = subprocess.run(["chronyc", "-n", "tracking"], capture_output=True,
                         text=True).stdout
    if not re.search(r"^Leap status\s*: Normal", out, re.M):
        say("clock not synchronised (no GPS fix and no network?) — %s will "
            "not decode until it is. See: chronyc sources" % mode, "warning")


# ------------------------------------------------------------------- rxd

def systemctl(*args, **kw):
    return subprocess.run(["systemctl", "--user", *args], **kw)


def rxd_status():
    """rxd's /api/status as a dict, or None when nothing answers."""
    try:
        with urllib.request.urlopen(RXD_URL + "/api/status", timeout=1) as r:
            return json.load(r)
    except (OSError, ValueError):  # refused, timed out, HTTP error, not JSON
        return None


def rxd_stop():
    # Every instance, not just the active profile's: whichever one runs holds
    # the dongle. systemctl matches the pattern against loaded units.
    systemctl("stop", "rxd@*.service", stderr=subprocess.DEVNULL)


def rxd_fail(name, why):
    unit = unit_name(name)
    log = subprocess.run(["journalctl", "--user", "-u", unit, "-n", "15", "--no-pager"],
                         capture_output=True, text=True).stdout.rstrip()
    # Stopped so Restart=on-failure does not keep hammering a missing dongle.
    systemctl("stop", unit, stderr=subprocess.DEVNULL)
    if log:
        print(log, file=sys.stderr)
    # rxd says plainly when the dongle is missing or busy; put its own last
    # word in the message, which is all a nagbar shows.
    lines = [ln for ln in log.splitlines() if "rxd: " in ln] or log.splitlines() or [""]
    last = lines[-1].split("rxd: ", 1)[-1].strip()
    die("%s %s%s" % (unit, why, ": " + last if last else ""))


def rxd_start(name):
    unit = unit_name(name)
    # After a run of failures systemd refuses to start the unit again until
    # its counter is cleared; an explicit 'radio NAME' is a fresh attempt.
    systemctl("reset-failed", unit, stderr=subprocess.DEVNULL)
    if systemctl("start", unit).returncode != 0:
        rxd_fail(name, "did not start")
    deadline = time.monotonic() + RXD_START_SECS
    while time.monotonic() < deadline:
        if rxd_status() is not None:
            return
        state = systemctl("is-active", unit, capture_output=True, text=True).stdout.strip()
        if state in ("failed", "inactive"):
            rxd_fail(name, "exited")
        time.sleep(0.25)
    rxd_fail(name, "is not answering on %s" % RXD_URL)


# ------------------------------------------------------ capture and apply

def capture(p, st):
    """The profile p, updated with rxd's current tuning from status st."""
    p = copy.deepcopy(p)
    p.pop("vfo_offset", None)  # SDR++'s; rxd ignores it
    # offset is left as it was: status reports the upconverter now in
    # effect, and saving that would pin an "auto" profile to one side.
    if st.get("vfo_hz") is not None:
        p["frequency"] = float(st["vfo_hz"])  # the carrier, as rxd reads it
    if st.get("mode"):
        p["demod"] = st["mode"]
    if st.get("bandwidth") is not None:
        p["demod_settings"] = dict(p.get("demod_settings") or {},
                                   bandwidth=float(st["bandwidth"]))
    if st.get("volume") is not None:
        p["volume"] = float(st["volume"])
    if "squelch" in st:  # in SDR++'s keys, which rxd reads back
        ds = dict(p.get("demod_settings") or {}, squelchEnabled=st["squelch"] is not None)
        if st["squelch"] is not None:
            ds["squelchLevel"] = float(st["squelch"])
        p["demod_settings"] = ds
    if st.get("gain_db") is not None:
        p["rtl"] = dict(p.get("rtl") or {}, gain_db=float(st["gain_db"]))
    # rxd is the source of truth for the dial too: JS8Call tunes it over
    # rigctl. Saving both dial and carrier keeps the calibration between them.
    if p.get("js8call_dial") is not None and st.get("freq") is not None:
        p["js8call_dial"] = int(round(float(st["freq"])))
    report = (st.get("wspr") or {}).get("report") or {}
    if p.get("decoder") == "wspr" and "reason" not in report and "enabled" in report:
        p["wspr_report"] = bool(report["enabled"])
    return p


def save_running(name):
    """Save rxd's tuning into name; False if no rxd answers to save from."""
    st = rxd_status()
    if st is None:
        return False
    store(name, capture(profile(name), st))
    return True


def switch(name, focus, resume=False):
    prev = active()
    target = profile(name)
    unit_name(name)  # a name rxd cannot be started on fails before anything closes
    js8 = target.get("js8call_dial") is not None

    # Re-running the profile already playing changes nothing: a restart would
    # throw away tuning done live through rigctl or HTTP. rxd's own idea of
    # its profile guards against an instance started for some other name.
    st = rxd_status()
    same = prev == name and st is not None and st.get("profile", name) == name

    # Only re-running the JS8 profile already up leaves JS8Call be.
    if not (js8 and prev == name):
        close("js8call", JS8_CRIT)

    # Save the profile being left, so coming back resumes it. Resuming at
    # login has nothing current to save.
    if prev and st is not None and not resume and not same:
        store(prev, capture(profile(prev), st))
        target = profile(name)

    set_active(name)
    if not same:
        if js8:
            ensure_js8_sink()  # before rxd starts: it opens its sink then
        ensure_stored(name, target)
        rxd_stop()
        rxd_start(name)

    if js8:
        want = str(target["js8call_dial"])
        if same and st.get("freq") is not None:
            # JS8Call may have moved rxd since the profile was saved; the
            # running dial is the current one.
            want = str(int(round(float(st["freq"]))))
        if read_ini().get("Common", "DialFreq", fallback="") != want:
            close("js8call", JS8_CRIT)
            write_dial(want)
        if not running("js8call"):
            start([JS8CALL], JS8_TREE)
        check_clock("JS8")
    elif decoder(target) == "wspr":
        check_clock("WSPR")

    print(summary(name, target))
    # The one setting no file can change.
    if prev and prev != name:
        was = upconverting(profile(prev))
        now = upconverting(target)
        if was != now:
            say("flip the Ham It Up to %s" % ("UPCONVERT" if now else "BYPASS"),
                "warning")
    if focus and js8:
        i3('[class="%s"] focus' % JS8_CRIT)


# --------------------------------------------------------------------- mesh

# Both networks share the AIO's SX1262, so one runs at a time. rx-mesh (root,
# through sudo) is the only thing that starts or stops their daemons.
MESHES = ("meshtastic", "meshcore")
MESH_FILE = os.path.join(STATE, "mesh")
MESH_UNITS = {"meshtastic": "meshtasticd", "meshcore": "raspberrypimc-companion"}
MESH_PORTS = {"meshtastic": 4403, "meshcore": 5000}
RX_MESH = "/usr/local/sbin/rx-mesh"
MT_PY = "/opt/meshtastic-cli/bin/python"
MT_OPS = "/usr/local/lib/rx/meshtastic_ops.py"
MESHCLI = "/opt/meshcore-cli/bin/meshcli"
NAMES_CACHE = os.path.join(HOME, ".cache", "rx", "mesh-names-%s")
MC_TYPES = {1: "companion", 2: "repeater", 3: "room", 4: "sensor"}


def mesh_conf():
    conf = {}
    try:
        with open("/etc/rx/mesh.conf", encoding="utf-8") as fh:
            for line in fh:
                key, sep, value = line.strip().partition("=")
                if sep and not key.startswith("#"):
                    conf[key] = value
    except OSError:
        die("no /etc/rx/mesh.conf — run setup.sh --only lora")
    return conf


def mesh_network():
    try:
        with open(MESH_FILE, encoding="utf-8") as fh:
            name = fh.read().strip()
    except OSError:
        name = ""
    return name if name in MESHES else "meshtastic"


def mesh_running():
    for net in MESHES:
        if subprocess.run(["systemctl", "is-active", "--quiet", MESH_UNITS[net]]).returncode == 0:
            return net
    return None


def wait_port(port, secs=60):
    for _ in range(secs * 2):
        with socket.socket() as sock:
            sock.settimeout(0.5)
            if sock.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.5)
    return False


def mesh_up(net, apply=False):
    """Make net the running mesh, applying its settings when it (re)starts."""
    started = False
    if mesh_running() != net:
        if subprocess.run(["sudo", "-n", RX_MESH, "start", net]).returncode != 0:
            die("could not start %s (rx-mesh via sudo; re-run setup.sh --only lora)" % net)
        started = True
    if not wait_port(MESH_PORTS[net]):
        die("%s started but is not answering on port %d" % (net, MESH_PORTS[net]))
    if apply or started:
        mesh_apply(net, started)


def mt_ops(*args, check=True):
    if not os.path.exists(MT_OPS):
        die("no %s — run setup.sh --only lora" % MT_OPS)
    rc = subprocess.run([MT_PY, MT_OPS, *args]).returncode
    if check and rc != 0:
        sys.exit(rc)
    return rc


def meshcli(*args, as_json=False):
    cmd = [MESHCLI, "-q", "-t", "127.0.0.1", "-p", str(MESH_PORTS["meshcore"])]
    if as_json:
        cmd.append("-j")
    out = subprocess.run(cmd + list(args), capture_output=True, text=True, timeout=90)
    if out.returncode != 0:
        die("meshcore-cli %s failed: %s" % (args[0], (out.stderr or out.stdout).strip()[-200:]))
    if not as_json:
        return out.stdout
    text = out.stdout.strip()
    try:
        return json.loads(text) if text else {}
    except ValueError:
        die("meshcore-cli %s returned something unexpected" % args[0])


def mesh_apply(net, started):
    conf = mesh_conf()
    if net == "meshtastic":
        mt_ops("apply")  # waits out the node's own reboot
        wait_port(MESH_PORTS[net])
        return
    # MeshCore's radio settings live in companion.env and are applied at
    # every start; only the identity is set through the client.
    info = meshcli("infos", as_json=True)
    if info.get("name") != conf["NODE_NAME"]:
        meshcli("set", "name", conf["NODE_NAME"])
        print("meshcore: name set to %s" % conf["NODE_NAME"])
    # One flood advert per start, so the mesh learns this node exists --
    # MeshCore nodes only appear in each other's contacts from adverts.
    if started:
        meshcli("floodadv")
        print("meshcore: sent an advert")


def age(epoch):
    if not epoch:
        return "-"
    secs = int(time.time() - epoch)
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if secs >= n:
            return "%d%s ago" % (secs // n, unit)
    return "%ds ago" % secs


def mc_nodes():
    contacts = meshcli("contacts", as_json=True) or {}
    rows = sorted(contacts.values(), key=lambda c: c.get("last_advert", 0), reverse=True)
    os.makedirs(os.path.dirname(NAMES_CACHE), exist_ok=True)
    with open(NAMES_CACHE % "meshcore", "w", encoding="utf-8") as fh:
        fh.write("".join(c["adv_name"] + "\n" for c in rows if c.get("adv_name") and " " not in c["adv_name"]))
    if not rows:
        print("no contacts yet — MeshCore learns nodes from their adverts")
        return
    print("%-24s %-10s %-6s %s" % ("NAME", "TYPE", "HOPS", "LAST ADVERT"))
    for c in rows:
        hops = c.get("out_path_len", -1)
        print("%-24s %-10s %-6s %s" % (c.get("adv_name", "?")[:24], MC_TYPES.get(c.get("type"), "?"),
                                       "flood" if hops < 0 else hops, age(c.get("last_advert"))))


def mc_info():
    me = meshcli("infos", as_json=True)
    print("network   MeshCore")
    print("identity  %s %s" % (me.get("name"), me.get("public_key", "")[:16]))
    print("radio     %.3f MHz, %.1f kHz, SF %s, CR %s, %s dBm" % (
        me.get("radio_freq", 0), me.get("radio_bw", 0), me.get("radio_sf"), me.get("radio_cr"),
        me.get("tx_power")))
    print("position  %s" % ("never sent" if not me.get("adv_lat") and not me.get("adv_lon") else "in adverts"))
    chans = meshcli("get_channels", as_json=True) or []
    for ch in chans if isinstance(chans, list) else []:
        print("channel   %s %s" % (ch.get("channel_idx"), ch.get("channel_name")))
    contacts = meshcli("contacts", as_json=True) or {}
    print("heard     %d contacts" % len(contacts))


def mesh_main(argv, focus):
    net = mesh_network()
    sub, args = (argv[0] if argv else None), argv[1:]

    if sub == "info":
        if mesh_running() == net:
            mt_ops("info") if net == "meshtastic" else mc_info()
        else:
            print("network   %s (off; 'radio mesh on' starts it)" % ("Meshtastic" if net == "meshtastic" else "MeshCore"))
        return
    if sub == "off":
        subprocess.run(["sudo", "-n", RX_MESH, "stop"], check=False)
        print("mesh off")
        return
    if sub not in (None, "on", "nodes", "send", "dm", "join"):
        die("unknown mesh command '%s' (see: radio help)" % sub)

    mesh_up(net)
    if sub == "on":
        print("%s on" % net)
    elif sub is None:
        if net == "meshtastic":
            # It sets no WM_CLASS, so there is no window to wait for by class;
            # i3's title rule moves it to workspace 3.
            if not running("meshtastic-ui"):
                subprocess.Popen(["meshtastic-ui"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True)
            if focus:
                i3("workspace number 3")
        elif sys.stdin.isatty():
            os.execv(MESHCLI, [MESHCLI, "-t", "127.0.0.1", "-p", str(MESH_PORTS["meshcore"])])
        else:
            print("MeshCore is up; for its chat client run: meshcore-cli -t 127.0.0.1")
    elif net == "meshtastic":
        mt_ops(sub, *args)
    elif sub == "nodes":
        mc_nodes()
    elif sub == "send" and args:
        meshcli("public", " ".join(args))
        print("sent to the public channel")
    elif sub == "dm" and len(args) >= 2:
        sys.stdout.write(meshcli("msg", args[0], " ".join(args[1:])))
    elif sub == "join" and args:
        meshcli("add_channel", *args[:2])
        mc_info()
    else:
        die("usage: radio mesh %s ... (see: radio help)" % sub)


def choose_mesh(net, focus):
    os.makedirs(STATE, exist_ok=True)
    with open(MESH_FILE, "w", encoding="utf-8") as fh:
        fh.write(net + "\n")
    mesh_up(net, apply=True)
    mt_ops("info") if net == "meshtastic" else mc_info()


def main():
    ap = argparse.ArgumentParser(prog="radio", add_help=True)
    ap.add_argument("--no-focus", action="store_true")
    ap.add_argument("--names", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("--json", action="store_true", help=argparse.SUPPRESS)
    ap.add_argument("cmd", nargs="?")
    ap.add_argument("arg", nargs="?")
    rest = sys.argv[1:]
    if rest[:1] == ["--no-focus"]:
        rest, focus_flag = rest[1:], False
    else:
        focus_flag = True
    if rest[:1] == ["mesh"]:
        # radio [--no-focus] mesh SUB ARGS...: free text follows, so take the
        # rest verbatim rather than through argparse.
        mesh_main(rest[1:], focus_flag)
        return
    a = ap.parse_args()
    focus = not a.no_focus

    if a.cmd in ALIASES:  # js8-40m and wspr-40m are js8 and wspr
        a.cmd = ALIASES[a.cmd]
    if a.arg in ALIASES and a.cmd in ("show", "reset", "save"):
        a.arg = ALIASES[a.arg]

    if a.names:  # for tab completion
        print("\n".join(known() + sorted(ALIASES)))
    elif a.json:  # for rxd's browser UI: the profiles and which is active
        rows = []
        for n in known():
            p = profile(n)
            rows.append({"name": n, "description": p.get("description", ""),
                         "freq": float(p.get("js8call_dial", p["frequency"])),
                         "mode": p["demod"], "upconvert": upconverting(p),
                         "js8": p.get("js8call_dial") is not None,
                         "decoder": decoder(p),
                         "band": band_of(float(p.get("js8call_dial", p["frequency"]))),
                         "plan": n in BAND_PLAN,
                         "saved": os.path.isfile(os.path.join(STATE, n + ".json"))})
        print(json.dumps({"active": active(), "profiles": rows}))
    elif a.cmd is None:
        cur = active()
        for n in known():
            saved = os.path.isfile(os.path.join(STATE, n + ".json"))
            print("%s %s%s" % ("*" if n == cur else " ", summary(n, profile(n)),
                               "  (saved)" if saved else ""))
        print("\nradio NAME switches · radio off · radio help · Tab completes names")
        print("mesh: radio %s (active) · radio mesh nodes|send|dm|join|info|on|off" % mesh_network())
    elif a.cmd == "help":
        print(__doc__.split("\n\n", 1)[1].split("\nA profile is")[0])
    elif a.cmd == "off":
        name = active()
        close("js8call", JS8_CRIT)
        if name:
            save_running(name)
        rxd_stop()
        print("rxd stopped, JS8Call closed" + ("; 'radio resume' brings back %s" % name if name else ""))
    elif a.cmd == "resume":
        name = active()
        if name:
            switch(name, focus, resume=True)
        else:
            print("no active profile; 'radio NAME' picks one")
    elif a.cmd == "save":
        name = a.arg or active() or die("nothing active; name the profile: radio save NAME")
        unit_name(name)  # a profile rxd could not be started on is no use
        st = rxd_status()
        if st is None:
            die("rxd is not running; nothing to save")
        base = profile(name) if name in known() else dict(profile(active() or "ghostnet"),
                                                          description=name)
        store(name, capture(base, st))
        set_active(name)
        print("saved " + summary(name, profile(name)))
    elif a.cmd == "reset":
        if not a.arg:
            die("usage: radio reset NAME")
        path = os.path.join(STATE, a.arg + ".json")
        if os.path.isfile(path):
            os.remove(path)
        print("reset %s to its default" % a.arg if a.arg in PROFILES
              else "removed %s" % a.arg)
    elif a.cmd in MESHES:
        choose_mesh(a.cmd, focus)
    elif a.cmd == "show":
        print(json.dumps(profile(a.arg or active() or "ghostnet"), indent=2))
    else:
        switch(a.cmd, focus)


if __name__ == "__main__":
    main()
RADIO
    log "installed the radio profile switcher"

    # bash-completion loads this lazily, the first time 'radio <Tab>' runs.
    write_file /usr/share/bash-completion/completions/radio 0644 <<'RADIOCOMP'
# Managed by rx/setup.sh — tab completion for radio.
_radio() {
    local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]}
    local names
    names=$(radio --names 2>/dev/null)
    case $prev in
        save|reset|show)
            COMPREPLY=($(compgen -W "$names" -- "$cur")) ;;
        radio|--no-focus)
            COMPREPLY=($(compgen -W "$names meshtastic meshcore mesh off resume save reset show help --no-focus" -- "$cur")) ;;
        mesh)
            COMPREPLY=($(compgen -W "nodes send dm join info on off" -- "$cur")) ;;
        dm)
            # Names seen by the last 'radio mesh nodes' on the active network.
            local net
            net=$(cat ~/.config/rx/radio/mesh 2>/dev/null || echo meshtastic)
            COMPREPLY=($(compgen -W "$(cat ~/.cache/rx/mesh-names-"$net" 2>/dev/null)" -- "$cur")) ;;
    esac
}
complete -F _radio radio
RADIOCOMP
    note "radio: 'radio' lists profiles, 'radio NAME' (Tab completes) closes whatever runs and brings NAME up; 'radio off' closes everything. Each profile resumes where it was left. Profiles: ghostnet js8 vhf dcara uhf noaa fm-93.3 fm-105.3 am-820. It says when the Ham It Up needs flipping between upconvert (HF, AM) and bypass (VHF/UHF, FM)."

    note "SDR needs the antenna on the 'SDR' IPEX pad (the GPS pad is a separate path). All four AIO rails (SDR, USB, GPS, LoRa) come up at boot — see docs/hardware.md for switching them."
    note "rxd: 'systemctl --user status rxd@NAME' and 'journalctl --user -u rxd@NAME' show the receiver for profile NAME; 'curl -s 127.0.0.1:8073/api/status' shows its frequency, mode, gain and dropped blocks. Test against a strong FM broadcast (88-108 MHz) before anything weak."
    note "rxd-tui tunes rxd from a terminal ('?' lists its keys), and http://$(hostname):8073/ does the same from a browser anywhere on the LAN or tailnet. No authentication: anyone on the LAN can tune the radio. To keep it local, set RXD_HTTP=127.0.0.1:8073 in /etc/rx/rxd.env, then 'systemctl --user restart rxd@*'."
    note "If rxd plays silence, prove the hardware first with 'rtl_test -t' and 'timeout 10 rtl_test -s 2400000'. The dongle is behind the AIO's internal USB hub, so 'lost at least N bytes' there is a hub or power problem, not an rxd setting."
  fi

  # --------------------------------------------------------------------- ham

  if want ham; then
    section "Amateur radio"
    apt_install python3
    # libhamlib-utils, not hamlib-utils: Debian names the binary package after
    # the library. It provides rigctl/rotctl, which is what JS8Call drives a
    # rig with.
    apt_install_opt js8call libhamlib-utils

    # wsjtx for wsprd, the WSPR decoder rxd runs on its own recordings (the
    # WSJT-X GUI itself is not used). Pinned to Debian's build: the ClockworkPi
    # repo's wsjtx 2.7.0 overwrites a file of Debian's wsjtx-data 2.6.1, so
    # installing or upgrading to it fails, and that would break 'maint' too.
    write_file /etc/apt/preferences.d/rx-wsjtx 0644 <<'WSJTXPIN'
# Managed by rx/setup.sh. wsjtx from Debian, matching Debian's wsjtx-data:
# the ClockworkPi repo's newer wsjtx conflicts with it.
Package: wsjtx wsjtx-data wsjtx-doc
Pin: origin deb.debian.org
Pin-Priority: 990
WSJTXPIN
    apt_install_opt --no-install-recommends wsjtx

    # CHIRP, for programming handhelds. Debian's package rather than
    # upstream's newer build: chirpmyradio.com's archive returns 403 to
    # anything scripted, so a current wheel cannot be fetched unattended.
    # Note that `chirp` on PyPI is an unrelated bioacoustics library.
    apt_install_opt chirp
    # The Debian package installs the binary as chirpw. Symlink the name
    # everyone actually types, which is also what dmenu will show.
    if [[ -x /usr/bin/chirpw ]]; then
      run ln -sf /usr/bin/chirpw /usr/local/bin/chirp
    fi

    note "CHIRP: run 'chirp' or 'chirpw' (dmenu, Alt+Shift+d). Serial cables need the dialout group, which you have — it applies after a full re-login."
    note "CHIRP is Debian's build and lags upstream, so a radio released since then may not be listed. For a current one, download the wheel from chirpmyradio.com in a browser (its archive blocks scripted access), then: sudo apt remove chirp && pipx install --system-site-packages ./chirp-*.whl"
    log "installed js8call and hamlib-utils"

    # GhostNet (S2 Underground) config, migrated from a working macOS install.
    # Identity, groups and dial frequency are baked in; audio devices, PTT and
    # rig control are not, since those depend on the radio attached here.
    write_file /usr/local/sbin/js8call-ghostnet-config 0755 <<'JS8CONF'
#!/usr/bin/env python3
"""Managed by rx/setup.sh — apply the GhostNet JS8Call configuration.

Migrated selectively from a working macOS JS8Call install. Only portable keys
are written: identity, groups, heartbeat/autoreply behaviour, and the dial
frequency. Deliberately NOT carried over, because they would be wrong or
harmful on the uConsole:

  SoundInId/SoundInName/SoundOutId/SoundOutName   macOS Core Audio devices
                                                  (SoundInName instead defaults
                                                  to the SDR loopback; below)
  WindowGeometry, Font, RXTextFont, TXTextFont    sized for a Mac, not 1280x480
  Rig, PTTMethod, PTTport, CATSerialPort          depends on the attached radio
  Notifications\\*\\path                            macOS sound file paths
  CallActivity, stations                          stale per-callsign heard data

JS8Call reads this with QSettings. Values are written exactly as QSettings
itself stores them — in particular MyGroups keeps its doubled '@@', which is
QSettings' own escaping. Do not "tidy" it to a single '@'.
"""
import argparse
import configparser
import os
import shutil
import subprocess
import sys
import time

CALLSIGN = "KA1PID"
GRID = "EM13LC"
GROUPS = "@@GHOSTNET, @@GSTFLASH, @@GNUSATX"
GHOSTNET_DIAL = "7107000"  # GhostNet calling frequency, 7.107 MHz

SETTINGS = {
    "Common": {
        "Freq": "1000",          # audio offset within the passband
        "SubMode": "0",          # normal speed
        "SubModeHB": "false",
        "SubModeHBAck": "false",
        "SubModeMultiDecode": "true",
        "HBInterval": "0",       # heartbeat off by default
        "CQInterval": "0",
    },
    "Configuration": {
        "MyCall": CALLSIGN,
        "MyGrid": GRID,
        "MyGroups": GROUPS,
        "AutoreplyOnAtStartup": "true",
        "AutoreplyConfirmation": "true",
        "HeartbeatQSOPause": "true",
        "HeartbeatAckSNR": "false",
        "HBRateLimit": "false",
        "HBMessage": "HB <MYGRID4>",
        "CQMessage": "CQ CQ CQ <MYGRID4>",
        "MyStatus": "IDLE <MYIDLE> VERSION <MYVERSION>",
        "Reply": "HW CPY?",
        "Macros": "TNX 73 GL",
        "AutoGrid": "false",
        "AvoidAllcall": "false",
        "TxIdleWatchdog": "60",
        # Receive-only on the SDR: nothing transmits or uploads on its own.
        "AutoreplyOnAtStartup": "false",
        "PSKReporter": "false",
        "SpotToAPRS": "false",
    },
    # Layout set by hand on the uConsole's 1280x720 panel. The ByteArrays are QSettings' own encoding, copied
    # verbatim; they are opaque and only JS8Call can regenerate them.
    "MainWindow": {
        "BandHBActivityVisible": "false",
        "ShowTooltips": "false",
        "MainSplitter": r"@ByteArray(\0\0\0\xff\0\0\0\x1\0\0\0\x4\0\0\0}\0\0\x1\xb3\0\0\0\x1e\0\0\0\0\x1\0\0\0\x6\x1\0\0\0\x2\x1)",
        "TextHorizontalSplitter": r"@ByteArray(\0\0\0\xff\0\0\0\x1\0\0\0\x3\0\0\x1\x1\0\0\0\xb1\0\0\0\xb2\x1\0\0\0\x6\x1\0\0\0\x1\0)",
        "geometry": r"@ByteArray(\x1\xd9\xd0\xcb\0\x3\0\0\0\0\x2\x80\0\0\0\x1c\0\0\x4\xff\0\0\x2\xcf\0\0\x2\x82\0\0\0\x36\0\0\x4\xfd\0\0\x2\xcd\0\0\0\0\0\0\0\0\x5\0\0\0\x2\x82\0\0\0\x36\0\0\x4\xfd\0\0\x2\xcd)",
        "state": r"@ByteArray(\0\0\0\xff\0\0\0\0\xfd\0\0\0\0\0\0\x2|\0\0\x2l\0\0\0\x4\0\0\0\x4\0\0\0\b\0\0\0\b\xfc\0\0\0\0)",
    },
    "WideGraph": {
        "HideControls": "true",
        "PlotWidth": "479",
        "geometry": r"@ByteArray(\x1\xd9\xd0\xcb\0\x3\0\0\0\0\0\0\0\0\0\0\0\0\x1\xde\0\0\0\t\0\0\0\0\0\0\0\x14\0\0\x1\xf9\0\0\x1\xb7\0\0\0\0\x2\0\0\0\x5\0\0\0\0\0\0\0\0\0\0\0\x1\xde\0\0\0\t)",
    },
}

# Written only when the key is absent or empty, so a later choice survives
# re-runs.
DEFAULTS = {
    "Common": {
        # 'radio' sets the dial when switching JS8 profiles; forcing it here
        # would pull JS8Call back to GhostNet on every maint run while rxd
        # stayed on the other frequency.
        "DialFreq": GHOSTNET_DIAL,
    },
    "Configuration": {
        # Monitor of the PipeWire loopback sink rxd plays into.
        "SoundInName": "SDR_to_JS8.monitor",
    },
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--home", default=os.path.expanduser("~"))
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    ini = os.path.join(args.home, ".config", "JS8Call.ini")

    # JS8Call writes its whole ini back on exit, so anything written while it
    # runs is silently undone the next time it closes.
    if not args.dry_run and subprocess.run(
            ["pgrep", "-x", "js8call"], stdout=subprocess.DEVNULL).returncode == 0:
        print("  JS8Call is running and would overwrite %s on exit — close it and re-run" % ini)
        return 2

    cp = configparser.ConfigParser(
        interpolation=None,   # values contain bare '%' and '$'
        strict=False,         # tolerate duplicate keys from older writes
        delimiters=("=",),
        comment_prefixes=(),  # ';' and '#' are legal inside values here
    )
    cp.optionxform = str      # QSettings keys are case-sensitive

    existed = os.path.isfile(ini)
    if existed:
        try:
            with open(ini, encoding="utf-8") as fh:
                cp.read_file(fh)
        except (configparser.Error, OSError, UnicodeDecodeError) as exc:
            print("  existing %s is unparseable (%s) — refusing to touch it" % (ini, exc))
            return 1
    else:
        print("  no existing JS8Call.ini — creating one")

    changed = []
    for section, keys in SETTINGS.items():
        if not cp.has_section(section):
            cp.add_section(section)
        for key, val in keys.items():
            if cp.get(section, key, fallback=None) != val:
                changed.append("%s/%s" % (section, key))
            cp.set(section, key, val)
    for section, keys in DEFAULTS.items():
        if not cp.has_section(section):
            cp.add_section(section)
        for key, val in keys.items():
            if not cp.get(section, key, fallback=""):
                changed.append("%s/%s" % (section, key))
                cp.set(section, key, val)

    if args.dry_run:
        print("  [dry-run] would write %d key(s) to %s" % (len(changed), ini))
        return 0

    # Re-running as config management must be a no-op when nothing differs:
    # no rewrite, and above all no new backup file each time.
    if existed and not changed:
        print("  %s already correct; nothing to do" % ini)
        return 0

    if existed:
        backup = "%s.bak-%s" % (ini, time.strftime("%Y%m%d-%H%M%S"))
        shutil.copy2(ini, backup)
        print("  backed up existing config to %s" % backup)

    os.makedirs(os.path.dirname(ini), exist_ok=True)
    tmp = ini + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        cp.write(fh, space_around_delimiters=False)
    os.replace(tmp, ini)

    print("  wrote GhostNet config to %s (%d key(s) changed)" % (ini, len(changed)))
    print("  callsign %s, grid %s, groups %s"
          % (CALLSIGN, GRID, GROUPS.replace("@@", "@")))
    print("  dial frequency %s MHz" % (int(GHOSTNET_DIAL) / 1e6))
    print("  audio in: %s (unless already set)"
          % cp.get("Configuration", "SoundInName", fallback=""))
    print("  NOT set (device-specific, configure in JS8Call): audio out, PTT method, rig")
    return 0


if __name__ == "__main__":
    sys.exit(main())
JS8CONF

    if $DRY_RUN; then
      log "[dry-run] would write the GhostNet JS8Call config for $DESKTOP_USER"
    else
      local js8rc=0
      /usr/local/sbin/js8call-ghostnet-config --home "$USER_HOME" || js8rc=$?
      case $js8rc in
        0) ;;
        2) note "JS8Call config skipped because JS8Call was open (it rewrites its ini on exit). Close it and re-run: sudo maint, or --only ham." ;;
        *) warn "JS8Call config failed — any existing config was left untouched" ;;
      esac
      chown "${DESKTOP_USER}:${USER_GROUP}" "$USER_HOME/.config/JS8Call.ini" 2>/dev/null || true
    fi
    # Receive path for JS8 without a rig: rxd demodulates USB into this
    # null sink, and JS8Call records from its monitor. A null sink rather
    # than the speaker's monitor so decoding does not depend on the volume
    # key, and the speaker stays quiet. System-wide, so it needs no per-user
    # PipeWire config; PipeWire picks it up at its next start.
    write_file /etc/pipewire/pipewire.conf.d/50-sdr-js8.conf 0644 <<'PWSINK'
# Managed by rx/setup.sh — virtual audio cable from rxd to JS8Call.
# rxd plays into "SDR_to_JS8"; JS8Call records from SDR_to_JS8.monitor.
context.objects = [
  { factory = adapter
    args = {
      factory.name     = support.null-audio-sink
      node.name        = "SDR_to_JS8"
      node.description = "SDR to JS8 (virtual cable)"
      media.class      = Audio/Sink
      audio.position   = [ FL FR ]
      audio.rate       = 48000
    }
  }
]
PWSINK
    log "PipeWire loopback sink SDR_to_JS8 configured"

    # JS8 receive is 'radio ghostnet' / 'radio js8' (the sdr section).
    # Earlier revisions installed launchers for it -- js8, then js8ghost with
    # js8call as a symlink -- and js8 and js8call shadowed JS8Call's own
    # binaries. Remove them, but only ours.
    local old
    for old in /usr/local/bin/js8 /usr/local/bin/js8ghost; do
      if grep -qs 'Managed by rx/setup.sh' "$old"; then
        run rm -f "$old"
        log "removed the old launcher $old"
      fi
    done
    if [[ -L /usr/local/bin/js8call && $(readlink /usr/local/bin/js8call) == js8ghost ]]; then
      run rm -f /usr/local/bin/js8call
      log "removed the old js8call launcher symlink"
    fi

    note "JS8Call: groups @GHOSTNET, @GSTFLASH, @GNUSATX; dial 7.107 MHz (GhostNet)."
    note "JS8 receive: 'radio ghostnet' (7.107) or 'radio js8' (7.078) brings up rxd tuned there and JS8Call on the matching dial on workspace 2. JS8Call's audio input defaults to the SDR_to_JS8.monitor loopback; a device picked under Settings -> Audio is kept on re-runs."
    note "JS8Call: 7.107 is set as the dial but is not in the preset Frequencies list; add it under Settings -> Frequencies to get it in the dropdown."
    note "JS8Call transmit needs an external rig (CAT + USB audio) — the SDR is receive-only. Set audio out and PTT under Settings -> Audio / Radio."
  fi

  # ---------------------------------------------------------------- tailscale

  if want tailscale; then
    section "Tailscale"

    if ! pkg_available tailscale; then
      local ts_id=$OS_ID
      case $ts_id in
        debian|raspbian) ;;
        *) warn "unrecognised distro '$ts_id' for the Tailscale repo; using debian"; ts_id=debian ;;
      esac
      local ts_base="https://pkgs.tailscale.com/stable/${ts_id}/${OS_CODENAME}"
      if $DRY_RUN; then
        log "[dry-run] add Tailscale repo from ${ts_base}"
      else
        # These are served pre-dearmored, so no gpg step.
        curl -fsSL --max-time 30 "${ts_base}.noarmor.gpg" \
          -o /usr/share/keyrings/tailscale-archive-keyring.gpg \
          || die "could not fetch the Tailscale signing key"
        curl -fsSL --max-time 30 "${ts_base}.tailscale-keyring.list" \
          -o /etc/apt/sources.list.d/tailscale.list \
          || die "could not fetch the Tailscale apt source"
        apt_update_soft
      fi
    fi

    apt_install tailscale
    run systemctl enable --now tailscaled

    # 'tailscale up' needs interactive auth, which a piped script cannot do.
    if tailscale status >/dev/null 2>&1; then
      log "tailscale already authenticated; leaving it alone"
    elif [[ -n ${TS_AUTHKEY:-} ]]; then
      run tailscale up --authkey "$TS_AUTHKEY" --hostname uconsole \
        || warn "tailscale up failed — check the auth key"
      log "tailscale brought up as 'uconsole'"
    else
      note "Tailscale is installed but not authenticated. Run: sudo tailscale up
    (or re-run with the key set after sudo: curl -fsSL <url> | sudo TS_AUTHKEY=tskey-... bash -s -- --only tailscale)"
    fi
  fi

  # -------------------------------------------------------------- postflight

  section "Done"
  if (( ${#NOTES[@]} )); then
    printf '\nNext steps:\n'
    local n
    for n in "${NOTES[@]}"; do printf '  * %s\n' "$n"; done
  fi
  printf '\n'
  if $DRY_RUN; then
    log "dry run complete — nothing was changed"
  else
    log "reboot to load the new overlays: sudo reboot"
  fi
}

main "$@"
