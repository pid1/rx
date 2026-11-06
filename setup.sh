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
        ("gain_db" turns automatic gain off; "gain_auto": true turns it on;
        "audio_auto", "audio_nr", "audio_filter", "audio_norm", "audio_limit"
        and "audio_squelch" switch the listening clean-up)

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
import sqlite3
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
# A JS8 profile's sink is JS8Call's input: silence there means no decodes
# (2026-11-06, a saved volume 0 cost 18 minutes of them). Below this rxd
# refuses a volume; a profile saved with less loads at JS8_VOLUME.
DECODER_MIN_VOLUME = 0.05
JS8_VOLUME = 0.2
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
            # Automatic RF gain (AutoGain), on unless the profile says false;
            # gain_db is then only where it starts.
            self.gain_auto = rtl.get("gain_auto", True) is not False
            self.audio = audio_settings(p.get("audio"))
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
            if self.decoder == "js8" and self.volume < DECODER_MIN_VOLUME:
                log("volume %g would silence JS8Call: using %g" % (self.volume, JS8_VOLUME))
                self.volume = JS8_VOLUME
            self.version = getattr(self, "version", 0) + 1

    def snapshot(self):
        with self.lock:
            return dict(mode=self.mode, bandwidth=self.bandwidth, dial=self.dial,
                        cal=self.cal, upconverter=self.upconverter(),
                        offset_mode=self.offset_mode,
                        upconvert_below=self.upconvert_below,
                        agc_attack=self.agc_attack, agc_decay=self.agc_decay,
                        volume=self.volume, gain_db=self.gain_db, squelch=self.squelch,
                        wspr_report=self.wspr_report, gain_auto=self.gain_auto,
                        audio=dict(self.audio), version=self.version)

    def upconverter(self):
        """The offset in effect for the current dial (call with the lock held)."""
        if self.offset_mode == "Ham-It-Up":
            return self.upconverter_hz
        if self.offset_mode == "auto" and self.dial < self.upconvert_below:
            return self.upconverter_hz
        return 0.0

    def update(self, freq=None, mode=None, bandwidth=None, gain_db=None,
               volume=None, squelch=Ellipsis, wspr_report=None, gain_auto=None, **audio):
        with self.lock:
            if gain_auto is not None and not isinstance(gain_auto, bool):
                raise ValueError("gain_auto must be true or false")
            new_audio = audio_update(self.audio, audio)
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
                if gain_auto is None:  # a gain set by hand turns the automatic off
                    self.gain_auto = False
            if gain_auto is not None:
                self.gain_auto = gain_auto
            self.audio = new_audio
            if volume is not None:
                volume = float(volume)
                if not 0 <= volume <= 4:
                    raise ValueError("volume must be between 0 and 4")
                if self.decoder == "js8" and volume < DECODER_MIN_VOLUME:
                    raise ValueError("JS8Call decodes this audio: volume can't go below %g"
                                     % DECODER_MIN_VOLUME)
                self.volume = volume
            if squelch is not Ellipsis:  # None (JSON null) turns it off
                if squelch is not None:
                    squelch = float(squelch)
                    if not -150 <= squelch <= 0:
                        raise ValueError("squelch must be in dBFS, -150 to 0, or null")
                self.squelch = squelch
            self.version += 1

    def set_auto_gain(self, db):
        """AutoGain's choice, kept unless gain_db was set by hand meanwhile."""
        with self.lock:
            if self.gain_auto:
                self.gain_db = float(db)
            return self.gain_auto


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


# ------------------------------------------------------- automatic RF gain

def db10(p):
    return float(10 * np.log10(p + 1e-12))


class AutoGain:
    """Picks the dongle's gain step from the raw IQ, a block at a time.

    The aim is the best signal-to-noise without overload. With an 8-bit ADC
    that means: enough gain that the band's noise floor (from the spectrum
    rxd already makes) sits well above the ADC's own quantisation noise, so
    the antenna sets the floor and not the ADC, and no more, since more gain
    only spends headroom. Overload shows as clipped samples (bytes 0 or 255)
    or an RMS near full scale; on the uConsole's R820T a crowded band
    compresses (the RMS stops rising with gain) before much clips.

    Measured 2026-11-06 on the box, 820 kHz AM through the Ham It Up: the
    carrier's SNR was best (47 dB) at 3.7-7.7 dB of gain, where the floor is
    7-11 dB over the ADC's, and fell to 34 dB at 30+ dB as the band compressed.

    After a start or a retune it steps once a second until it settles, then
    at most once every SLOW seconds. Under a WSPR or JS8 profile it then moves
    only in the gap between slots, so a decode never sees a step, unless the
    signal overloads or is far too low.
    """

    ADC_FLOOR_DB = -50.0   # 8-bit quantisation noise on make_spectrum's scale
    MARGIN_LO, MARGIN_HI, MARGIN_FAR = 6.0, 13.0, 2.0  # floor over the ADC's, dB
    RMS_HI, RMS_UP, RMS_URGENT = -10.0, -15.0, -5.0    # dBFS
    CLIP_HI, CLIP_UP, CLIP_URGENT = 1e-4, 1e-6, 1e-3   # fraction of I/Q values
    URGENT_DROP = 6.0      # dB: an overload steps down at least this far
    FAST, SLOW = 1.0, 5.0  # seconds between steps while settling / after
    SETTLE_FOR = 30.0      # seconds of fast steps at most
    # The floor doesn't always move dB for dB: on WFM at 93.3 MHz the R820T's
    # floor rose 11 dB for its 0 -> 3.7 dB step, so neither was in the band
    # and the loop flipped between them every second (2026-11-06). A step
    # that would undo the last one within REVERSAL_S is refused, the loop
    # holds the higher gain, and that move waits BAR_S. Overload isn't barred.
    REVERSAL_S, BAR_S = 120.0, 600.0
    # Decoder -> (slot period, gap start, gap end), seconds into the period.
    # WSPR records 114 s from the even minute; a JS8 Normal frame ends 13.1 s
    # into its 15 s slot.
    SLOTS = {"wspr": (120.0, 114.5, 119.5), "js8": (15.0, 13.3, 14.8)}

    def __init__(self, gains, decoder=None):
        self.gains = sorted(set(float(g) for g in gains))
        self.decoder = decoder
        self.key = None          # what it settled for: (mode, tuner MHz)
        self.spec_seq = None     # the last spectrum it took a floor from
        self.steps = 0
        self.state = "settling"
        self.reason = None
        self.last = {}
        self.cpu = 0.0
        self.reset(0.0)

    def reset(self, now):
        """Start settling again (a start, a retune or auto turned back on)."""
        self.t_dec = self.t_short = self.t_start = now
        self.acc = [0, 0, 0.0, []]   # clipped values, samples, sum |x|^2, floors
        self.short = [0, 0, 0.0]
        self.skip = 0
        self.settling = True
        self.holds = 0
        self.state = "settling"
        self.last_step = None    # (from, to, when) of the last non-overload step
        self.barred = {}         # (index, direction) -> until when

    @staticmethod
    def measure(x):
        """(clipped I/Q values, samples, sum of |x|^2) for a block from the dongle."""
        v = x.view(np.float32)
        # cu8 bytes 0 and 255 are -1.0 and +1.0; 1 and 254 are 0.992.
        return int(np.count_nonzero(np.abs(v) > 0.995)), len(x), float(np.dot(v, v))

    @staticmethod
    def floor_of(bins):
        """The band's noise floor: the 20th percentile of the spectrum, without
        the outer tenths (the dongle's filter rolls off) or the DC spike."""
        b = np.asarray(bins, np.float32)
        n = len(b)
        if n < 40:
            return None
        e, mid = n // 10, n // 2
        return float(np.percentile(np.concatenate([b[e:mid - 6], b[mid + 6:n - e]]), 20))

    def index(self, gain):
        g = self.gains
        return int(np.argmin([abs(x - (gain or 0.0)) for x in g]))

    def in_gap(self, wall):
        period, a, b = self.SLOTS[self.decoder]
        return a <= wall % period < b

    def decide(self, clip, rms, margin, i):
        """(-1, 0 or +1, why) for one window of measurements at gain step i."""
        g = self.gains
        down = None
        if clip > self.CLIP_HI:
            down = "clipping"
        elif rms > self.RMS_HI:
            down = "near full scale"
        elif margin is not None and margin > self.MARGIN_HI:
            down = "more gain than the noise needs"
        if down:
            return (-1, down) if i > 0 else (0, down + ", at the lowest gain")
        if margin is not None and margin < self.MARGIN_LO:
            if i + 1 >= len(g):
                return 0, "noise near the ADC's, at the highest gain"
            if clip > self.CLIP_UP or rms + (g[i + 1] - g[i]) > self.RMS_UP:
                return 0, "noise near the ADC's, but no headroom for more"
            return 1, "noise near the ADC's"
        return 0, "the antenna sets the noise floor, with headroom"

    def target(self, i, d, urgent=False):
        g = self.gains
        if d < 0 and urgent:
            lower = [j for j in range(i) if g[j] <= g[i] - self.URGENT_DROP]
            return lower[-1] if lower else 0
        return max(0, min(len(g) - 1, i + d))

    def jump(self, i, d, rms, margin):
        """While settling: the step nearest the middle of the target, at least
        one step in direction d."""
        g = self.gains
        mid = (self.MARGIN_LO + self.MARGIN_HI) / 2
        if d < 0:
            move = max(rms - self.RMS_UP, (margin - mid) if margin is not None else 0.0)
            want = g[i] - 0.75 * move  # the floor seldom falls dB for dB
            j = min(range(i), key=lambda k: abs(g[k] - want)) if i else 0
        else:
            move = min(mid - margin, self.RMS_UP - rms)
            want = g[i] + 0.75 * move
            j = min(range(i + 1, len(g)), key=lambda k: abs(g[k] - want)) \
                if i + 1 < len(g) else i
        return j

    def observe(self, x, gain, now, wall, floor=None):
        """One block of IQ in (with a new noise floor, if there is one); the
        gain to step to, or None to stay where it is."""
        if not self.gains:
            return None
        if self.skip > 0:      # blocks read before the last step
            self.skip -= 1
            return None
        c, n, pw = self.measure(x)
        for a in (self.acc, self.short):
            a[0] += c
            a[1] += n
            a[2] += pw
        if floor is not None:
            self.acc[3].append(floor)
        i = self.index(gain)
        if now - self.t_short >= self.FAST and self.short[1]:
            sc, sn, sp = self.short
            self.short = [0, 0, 0.0]
            self.t_short = now
            clip, rms = sc / (2.0 * sn), db10(sp / sn)
            fl = self.acc[3][-3:]
            margin = float(np.median(fl)) - self.ADC_FLOOR_DB if fl else None
            if (clip > self.CLIP_URGENT or rms > self.RMS_URGENT) and i > 0:
                return self.step(i, self.target(i, -1, urgent=True), now, "overload")
            if not self.settling and margin is not None and margin < self.MARGIN_FAR:
                d, why = self.decide(clip, rms, margin, i)
                if d > 0:
                    return self.step(i, i + 1, now, "noise far too near the ADC's")
        if now - self.t_dec < (self.FAST if self.settling else self.SLOW):
            return None
        cl, n, pw, fl = self.acc
        if not n:
            return None
        clip, rms = cl / (2.0 * n), db10(pw / n)
        floor_db = float(np.median(fl)) if fl else None
        margin = floor_db - self.ADC_FLOOR_DB if floor_db is not None else None
        if not self.settling and self.decoder in self.SLOTS and not self.in_gap(wall):
            d, why = self.decide(clip, rms, margin, i)
            if d:  # keep measuring; step in the gap
                self.state, self.reason = "waiting for the gap between slots", why
            return None
        self.last = {"clip": clip, "rms_dbfs": round(rms, 1),
                     "floor_db": None if floor_db is None else round(floor_db, 1),
                     "margin_db": None if margin is None else round(margin, 1)}
        self.acc = [0, 0, 0.0, []]
        self.t_dec = now
        d, why = self.decide(clip, rms, margin, i)
        self.reason = why
        if d and why not in ("clipping", "near full scale"):
            if self.barred.get((i, d), -1.0) > now:
                d, why = 0, why + "; held, as the step flip-flopped"
                self.reason = why
            elif self.last_step and now - self.last_step[2] < self.REVERSAL_S and \
                    (self.last_step[1] - self.last_step[0]) * d < 0:
                self.barred[(i, d) if d < 0 else (self.last_step[0], -1)] = now + self.BAR_S
                if d < 0:  # stay up here
                    d, why = 0, why + "; held, as the step flip-flopped"
                    self.reason = why
        if d:
            self.holds = 0
            j = self.jump(i, d, rms, margin) if self.settling else i + d
            if why not in ("clipping", "near full scale"):
                self.last_step = (i, j, now)
            return self.step(i, j, now, why)
        self.holds += 1
        if self.settling and (self.holds >= 2 or now - self.t_start > self.SETTLE_FOR):
            self.settling = False
        self.state = "settling" if self.settling else "holding"
        return None

    def step(self, i, j, now, why):
        self.reason = why
        self.acc = [0, 0, 0.0, []]
        self.short = [0, 0, 0.0]
        self.t_dec = self.t_short = now
        self.holds = 0
        if j == i:
            return None
        self.steps += 1
        self.state = "settling" if self.settling else "stepped"
        return self.gains[j]

    def status(self):
        return dict(self.last, state=self.state, reason=self.reason, steps=self.steps,
                    cpu=round(self.cpu, 4))


# ------------------------------------------------------- listening audio

# audio_* in /api/tune and the profile's "audio": {...}. nr is None for "by
# mode": on for voice (AM, FM, USB, LSB), off for WFM, whose music the
# noise estimate would eat into on long notes.
AUDIO_KEYS = ("auto", "nr", "filter", "norm", "limit", "squelch")


def audio_settings(p):
    a = {k: True for k in AUDIO_KEYS}
    a["nr"] = None
    return audio_update(a, {"audio_" + k: v for k, v in (p or {}).items()})


def audio_update(cur, fields):
    out = dict(cur)
    for name, v in fields.items():
        k = name[len("audio_"):] if name.startswith("audio_") else None
        if k not in AUDIO_KEYS:
            raise ValueError("unknown audio setting %s" % name)
        if not (isinstance(v, bool) or (k == "nr" and v is None)):
            raise ValueError("%s must be true or false%s" % (name, " or null" if k == "nr" else ""))
        out[k] = v
    return out


class NoiseReducer:
    """Spectral subtraction on 48 kHz audio: 512-point frames, half overlap.

    The noise is each bin's smoothed power at its quietest, let rise
    RISE_DB_S a second so it follows a changing band; a bin keeps
    1 - OVER * noise / power of itself, but never less than FLOOR. About
    11 ms of delay.
    """

    N, H = 512, 256
    RISE_DB_S = 3.0        # a held note 40 dB over the noise lasts ~13 s untouched
    OVER = 4.0             # the quietest of a smoothed power reads low: make up
    FLOOR = 0.18           # -15 dB
    SMOOTH = 0.2

    def __init__(self):
        n = np.arange(self.N)
        self.win = np.sqrt(0.5 - 0.5 * np.cos(2 * np.pi * n / self.N)).astype(np.float32)
        self.buf = np.zeros(self.H, np.float32)       # input not yet framed
        self.fifo = np.zeros(self.H, np.float32)      # output not yet given out
        self.tail = np.zeros(self.H, np.float32)      # overlap from the last frame
        self.rise = 10 ** (self.RISE_DB_S * self.H / AUDIO_RATE / 10)
        self.s = None          # smoothed power per bin
        self.noise = None

    def __call__(self, a):
        N, H = self.N, self.H
        data = np.concatenate([self.buf, a.astype(np.float32)])
        m = (len(data) - H) // H
        if m > 0:
            fr = np.lib.stride_tricks.sliding_window_view(data, N)[::H][:m]
            X = np.fft.rfft(fr * self.win, axis=1)
            P = (X.real ** 2 + X.imag ** 2).astype(np.float64)
            if self.s is None:  # start from the typical bin, so a tone isn't "noise"
                self.s = P[0].copy()
                self.noise = np.minimum(P[0], np.median(P[0]))
            S, _ = sps.lfilter([self.SMOOTH], [1, self.SMOOTH - 1], P, axis=0,
                               zi=(1 - self.SMOOTH) * self.s[None, :])
            # noise_k = min(noise_{k-1} * rise, S_k), all frames at once
            r = self.rise ** np.arange(1, m + 1)[:, None]
            runs = np.minimum.accumulate(np.vstack([self.noise[None, :], S / r]), axis=0)[1:]
            Nk = runs * r
            self.s, self.noise = S[-1], Nk[-1]
            G = np.maximum(1 - self.OVER * Nk / (S + 1e-20), self.FLOOR)
            y = np.fft.irfft(X * G, n=N, axis=1).astype(np.float32) * self.win
            out = (np.vstack([self.tail[None, :], y[:-1, H:]]) + y[:, :H]).ravel()
            self.tail = y[-1, H:].copy()
            self.buf = data[m * H:]
            self.fifo = np.concatenate([self.fifo, out])
        else:
            self.buf = data
        n = len(a)
        res, self.fifo = self.fifo[:n], self.fifo[n:]
        if len(res) < n:   # can't happen with the H samples banked first
            res = np.concatenate([res, np.zeros(n - len(res), np.float32)])
        return res


def soft_limit(a, knee=0.6, ceil=0.97):
    """Unchanged below knee; above it, a tanh curve up to ceil."""
    m = np.abs(a) > knee
    if not m.any():
        return a
    y = a.copy()
    v = np.abs(a[m])
    y[m] = np.sign(a[m]) * (knee + (ceil - knee) * np.tanh((v - knee) / (ceil - knee)))
    return y


class AudioFx:
    """Clean-up for listening: never on the audio a decoder gets.

    In order: an automatic noise squelch (NFM), a hum and DC filter (on NFM a
    300-3500 Hz voice band, so sub-audible tones and the discriminator's hiss
    go too), the noise reducer, a loudness normaliser so quiet and loud
    stations come out alike, and a soft limiter.
    """

    # mode -> (high-pass Hz, its order, low-pass Hz or None)
    FILTERS = {"USB": (100.0, 2, None), "LSB": (100.0, 2, None), "AM": (100.0, 4, None),
               "FM": (300.0, 6, 3500.0), "WFM": (30.0, 2, None)}
    TARGET_DB = -20.0                  # RMS the normaliser aims at, dBFS
    GAIN_MIN_DB, GAIN_MAX_DB = -20.0, 12.0  # +12: dead air stays quiet
    NORM_GATE_DB = -60.0               # quieter than this doesn't move it
    SQ_BAND = (8000.0, 16000.0)        # NFM noise squelch measures here
    SQ_OPEN_DB, SQ_CLOSE_DB = 6.0, 3.0  # quieter than pure noise by, to open/close
    SQ_HANG = 3                        # blocks it stays open after the signal goes

    def __init__(self, mode, bandwidth):
        self.mode, self.bandwidth = mode, bandwidth
        hp, order, lp = self.FILTERS[mode]
        sos = sps.butter(order, hp, "highpass", fs=AUDIO_RATE, output="sos")
        if lp:
            sos = np.vstack([sos, sps.butter(6, lp, "lowpass", fs=AUDIO_RATE, output="sos")])
        self.sos = sos
        self.zi = np.zeros((sos.shape[0], 2))
        self.nr = NoiseReducer()
        self.level = None      # the normaliser's loudness estimate, dBFS
        self.gain = 1.0
        self.sq_open, self.sq_hang = True, 0
        self.sq_ref = self.noise_ref(bandwidth) if mode == "FM" else None
        self.sq_quiet = None   # dB quieter than pure noise, last block
        self.active = []
        self.cpu = 0.0

    @classmethod
    def hf_power(cls, a):
        if len(a) < 64:
            return None
        X = np.fft.rfft(a)
        f = np.fft.rfftfreq(len(a), 1.0 / AUDIO_RATE)
        sel = (f >= cls.SQ_BAND[0]) & (f < cls.SQ_BAND[1])
        return float(np.mean(X.real[sel] ** 2 + X.imag[sel] ** 2)) / len(a)

    @classmethod
    def noise_ref(cls, bandwidth):
        """What the NFM discriminator gives for noise alone, in SQ_BAND: it
        depends only on the channel filter, not on the noise's level."""
        rng = np.random.default_rng(5)
        ch = Chain("FM", bandwidth, 0, 0)
        x = (rng.standard_normal(72000) + 1j * rng.standard_normal(72000)).astype(np.complex64)
        a = ch(x * 0.01, 50000.0)
        return cls.hf_power(a[len(a) // 3:])

    def nr_on(self, opt):
        return opt["nr"] if opt["nr"] is not None else self.mode != "WFM"

    def squelch(self, a):
        p = self.hf_power(a)
        if p is None or not self.sq_ref:
            return
        self.sq_quiet = db10(self.sq_ref) - db10(p)
        if self.sq_quiet >= (self.SQ_CLOSE_DB if self.sq_open else self.SQ_OPEN_DB):
            self.sq_open, self.sq_hang = True, self.SQ_HANG
        elif self.sq_hang > 0:
            self.sq_hang -= 1
        else:
            self.sq_open = False

    def normalise(self, a, adapt):
        lv = db10(float(np.mean(a * a))) if len(a) else -120.0
        if adapt and lv > self.NORM_GATE_DB:
            if self.level is None:
                self.level = lv
            self.level += (lv - self.level) * (0.35 if lv > self.level else 0.03)
        g_db = 0.0 if self.level is None else \
            min(max(self.TARGET_DB - self.level, self.GAIN_MIN_DB), self.GAIN_MAX_DB)
        g = 10 ** (g_db / 20)
        ramp = np.linspace(self.gain, g, len(a), endpoint=False, dtype=np.float32) \
            if len(a) else 1.0
        self.gain = g
        return a * ramp

    def __call__(self, a, opt, manual_squelch=False):
        """Audio for the speaker and the phone. opt is Settings.audio."""
        t0 = time.thread_time()
        act = []
        if not opt["auto"]:
            self.sq_open = True
            self.active = act
            return a
        if self.mode == "FM" and opt["squelch"] and not manual_squelch:
            self.squelch(a)
            act.append("squelch")
        else:
            self.sq_open = True
        if opt["filter"]:
            a, self.zi = sps.sosfilt(self.sos, a, zi=self.zi)
            a = a.astype(np.float32)
            act.append("filter")
        if self.nr_on(opt):
            a = self.nr(a)
            act.append("nr")
        if not self.sq_open:
            a = np.zeros_like(a)
        if opt["norm"]:
            a = self.normalise(a, adapt=self.sq_open)
            act.append("norm")
        if opt["limit"]:
            a = soft_limit(a)
            act.append("limit")
        self.active = act
        dt = time.thread_time() - t0
        self.cpu += (dt / (len(a) / AUDIO_RATE) - self.cpu) * 0.05 if len(a) else 0
        return a.astype(np.float32)

    def status(self, opt):
        return {"auto": opt["auto"], "nr": bool(self.nr_on(opt)), "nr_setting": opt["nr"],
                "filter": opt["filter"], "norm": opt["norm"], "limit": opt["limit"],
                "squelch": opt["squelch"], "active": list(self.active),
                "squelch_open": self.sq_open if "squelch" in self.active else None,
                "norm_gain_db": round(db10(self.gain ** 2), 1) if "norm" in self.active else None,
                "cpu": round(self.cpu, 4)}


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
        self.autogain = None         # an AutoGain, once the dongle's gains are known
        self.fx = None               # AudioFx for what's listened to
        self.clock, self.wallclock = time.monotonic, time.time  # tests run on their own
        self.bands = None            # the BandPlanner, on a live rxd
        self.js8dec = None           # a js8.SlotDecoder, for JS8 decoded by rxd

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
        gains = self.src.gains()
        self.autogain = AutoGain(gains, self.s.decoder) if gains else None
        self.retune(self.s.snapshot(), force=True)
        # Again after tuning: the R820T can lose a gain set before its first
        # tune (measured 2026-11-06: the band's floor 22 dB high at 3.7 dB
        # until the gain was set once more).
        self.src.set_gain(self.s.gain_db)
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
                self.retune(snap, force=rebuild)
                self.src.set_gain(snap["gain_db"])  # after a retune, as in start()
                self.version = snap["version"]
                if rebuild:
                    continue  # the block in hand was at the old rate
            t0 = time.thread_time()
            audio = self.chain(x, self.offset)
            self.auto_gain(x, snap)
            if self.wspr is not None:  # before squelch and volume
                self.wspr.push(audio, snap["dial"])
            if self.js8dec is not None:  # likewise
                self.js8dec.push(audio, snap["dial"])
            # Listening clean-up; a decoder's sink (JS8Call's cable) stays clean.
            heard = self.listening(audio, snap)
            audio = self.gate(audio if self.s.decoder else heard, snap["squelch"])
            pcm = np.clip(audio * snap["volume"] * 32767, -32768, 32767).astype("<i2")
            self.sink.write(pcm)
            if self.listeners:
                self.stream(heard if self.s.decoder else audio)
            dt = time.thread_time() - t0
            self.cpu += (dt / (len(x) / self.chain.rate) - self.cpu) * 0.05
            self.blocks += 1
            now = self.clock()
            if now - self.spectrum_at >= self.SPECTRUM_EVERY:
                self.spectrum_at = now
                self.spectrum = self.make_spectrum(x, snap)

    def auto_gain(self, x, snap):
        """Feed AutoGain a block and make the step it asks for."""
        ag = self.autogain
        if ag is None:
            return
        if not snap["gain_auto"]:
            ag.key, ag.state = None, "off"
            return
        t0 = time.thread_time()
        now = self.clock()
        key = (self.chain.mode, round((self.src.center or 0.0) / 1e6))
        if key != ag.key:  # started, retuned by a MHz or more, or turned back on
            ag.key = key
            ag.reset(now)
        ag.decoder = self.s.decoder
        floor, sp = None, self.spectrum
        if sp is not None and sp.get("seq") != ag.spec_seq:
            ag.spec_seq = sp.get("seq")
            floor = ag.floor_of(sp["bins"])
        new = ag.observe(x, snap["gain_db"], now, self.wallclock(), floor)
        if new is not None and self.s.set_auto_gain(new):
            self.src.set_gain(new)
            ag.skip = self.q.qsize() + 2   # blocks already read at the old gain
            log("auto gain %.1f dB (%s)" % (new, ag.reason))
        ag.cpu += ((time.thread_time() - t0) / (len(x) / self.chain.rate) - ag.cpu) * 0.05

    def listening(self, audio, snap):
        """The audio for the speaker and the phone, cleaned up by AudioFx."""
        if self.fx is None or (self.fx.mode, self.fx.bandwidth) != (self.chain.mode,
                                                                   self.chain.bandwidth):
            self.fx = AudioFx(self.chain.mode, self.chain.bandwidth)
        return self.fx(audio, snap["audio"], manual_squelch=snap["squelch"] is not None)

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
                "squelch": snap["squelch"],
                "volume_min": DECODER_MIN_VOLUME if self.s.decoder == "js8" else 0.0,
                "squelch_open": self.squelch_open and (self.fx is None or self.fx.sq_open),
                "gain_auto": snap["gain_auto"],
                "gain_loop": self.autogain.status() if self.autogain is not None else
                {"state": "unavailable", "reason": "this source has no gain control"},
                "audio": self.fx.status(snap["audio"]) if self.fx is not None else
                # Before the first block: the same shape, nothing active yet.
                dict(snap["audio"], active=[], nr_setting=snap["audio"]["nr"],
                     nr=snap["audio"]["nr"] if snap["audio"]["nr"] is not None
                     else snap["mode"] != "WFM"),
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
                "js8_decoder": self.js8dec.status() if self.js8dec is not None else
                ({"engine": "js8call"} if self.s.decoder == "js8" else None),
                "clock": clock_status(),
                "band_plan": self.bands.status() if self.bands is not None else None,
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


# ------------------------------------------------- rxd's own JS8 decoder

# A JS8 profile with "js8_engine": "rxd" (or RXD_JS8_ENGINE=rxd) decodes JS8
# in rxd itself, with rxd/js8.py, instead of in JS8Call. It records slots of
# this audio, before squelch and volume, and writes JS8Call-style ALL.TXT and
# DIRECTED.TXT under ~/.local/share/rxd/js8/, which Js8Feed then tails, so
# /api/js8 keeps its line shape. "js8_submodes" picks the speeds to decode
# (default normal, fast and slow, about a fifth of one CM4 core; turbo adds
# about 14%).
JS8_ENGINES = ("js8call", "rxd")
JS8_SUBMODES = ("normal", "fast", "turbo", "slow")
JS8_DEFAULT_SUBMODES = ["normal", "fast", "slow"]
JS8_PY = (os.environ.get("RXD_JS8_PY", ""),
          os.path.join(os.path.dirname(os.path.abspath(__file__)), "js8.py"),
          "/usr/local/lib/rxd/js8.py")


def js8_engine(p):
    engine = os.environ.get("RXD_JS8_ENGINE") or p.get("js8_engine") or "js8call"
    if engine not in JS8_ENGINES:
        raise ValueError("js8_engine must be one of " + ", ".join(JS8_ENGINES))
    return engine


def load_js8():
    import importlib.util
    for path in JS8_PY:
        if path and os.path.isfile(path):
            spec = importlib.util.spec_from_file_location("js8", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    return None


def make_js8(settings, p):
    """The SlotDecoder for a JS8 profile decoded by rxd, or None."""
    js8 = load_js8()
    if js8 is None:
        log("no js8.py at %s: JS8 won't decode" % ", ".join(x for x in JS8_PY if x))
        return None
    subs = p.get("js8_submodes") or JS8_DEFAULT_SUBMODES
    bad = [x for x in subs if x not in JS8_SUBMODES]
    if bad:
        raise ValueError("js8_submodes: unknown %s (have %s)" % (", ".join(bad),
                                                                ", ".join(JS8_SUBMODES)))
    return js8.SlotDecoder(settings.snapshot()["dial"], subs, rate_in=AUDIO_RATE)


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


# ---------------------------------------------------------------- band plan

# With the band plan on Auto, rxd picks the JS8 or WSPR band itself: from the
# day's band conditions (N0NBH's, from hamqsl.com, or NOAA SWPC's indices
# when hamqsl can't be had), the sun at the station, and what rxd has heard
# on each band at this hour. With no conditions (no internet) it scans the
# bands it has not yet heard at this hour, a couple of WSPR slots or a few
# minutes of JS8 each, and learns. Band changes go through `radio NAME`, which
# restarts rxd, so the planner keeps everything on disk and picks up where it
# was in the next rxd:
#   ~/.config/rx/bands.json             its settings, as the UI sets them
#   ~/.local/share/rxd/bands.json       what was heard, per profile and UTC hour
#   ~/.local/share/rxd/bandplan.json    where it is: scanning or holding, and why
#   ~/.local/share/rxd/conditions.json  the last band conditions fetched
BANDS_CONF = os.path.expanduser(os.environ.get("RXD_BANDS_CONF", "~/.config/rx/bands.json"))
BANDS_DIR = os.path.expanduser(os.environ.get("RXD_BANDS_DIR", "~/.local/share/rxd"))
HAMQSL_URL = os.environ.get("RXD_HAMQSL", "https://www.hamqsl.com/solarxml.php")
SWPC_FLUX_URL = os.environ.get("RXD_SWPC_FLUX",
                               "https://services.swpc.noaa.gov/json/f107_cm_flux.json")
SWPC_KP_URL = os.environ.get("RXD_SWPC_KP",
                             "https://services.swpc.noaa.gov/products/noaa-planetary-k-index.json")
HF_BANDS = ("160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m")
BAND_ORDER = ("2190m", "630m") + HF_BANDS + ("6m", "2m")
PLAN_MODES = ("wspr", "js8")
# N0NBH's calculated conditions come in four groups of HF bands.
HAMQSL_GROUP = {"160m": "80m-40m", "80m": "80m-40m", "60m": "80m-40m", "40m": "80m-40m",
                "30m": "30m-20m", "20m": "30m-20m", "17m": "17m-15m", "15m": "17m-15m",
                "12m": "12m-10m", "10m": "12m-10m"}
COND_VALUE = {"good": 1.0, "fair": 0.6, "poor": 0.2}
# What a mid-latitude station usually hears, by the sun: low bands at night,
# high bands by day, the middle ones around the gray line. 0 to 1.
BAND_PRIOR = {
    "day": {"2190m": .05, "630m": .1, "160m": .05, "80m": .25, "60m": .45, "40m": .6,
            "30m": .8, "20m": 1.0, "17m": .9, "15m": .8, "12m": .6, "10m": .5,
            "6m": .15, "2m": .05},
    "gray": {"2190m": .3, "630m": .4, "160m": .5, "80m": .75, "60m": .75, "40m": .9,
             "30m": .85, "20m": .85, "17m": .6, "15m": .45, "12m": .3, "10m": .25,
             "6m": .1, "2m": .05},
    "night": {"2190m": .5, "630m": .7, "160m": .7, "80m": .9, "60m": .8, "40m": 1.0,
              "30m": .8, "20m": .45, "17m": .25, "15m": .15, "12m": .1, "10m": .08,
              "6m": .05, "2m": .05},
}
PART_WORDS = {"day": "day", "night": "night", "gray": "gray line"}
# What counts as a lot heard: WSPR spots per two-minute slot, JS8 decodes a minute.
HEARD_SCALE = {"wspr": 10.0, "js8": 2.0}
# How much listening makes one good look at a band: two WSPR slots, six minutes of JS8.
HEARD_PER = {"wspr": 2.0, "js8": 6.0}
PLAN_DEFAULTS = {"plan": "auto", "mode": "wspr", "bands": None, "dwell_min": 6,
                 "every_min": 30, "cross_side": False}
CREDITS = {"hamqsl": "Band conditions courtesy of N0NBH, www.hamqsl.com",
           "swpc": "Solar indices from NOAA SWPC; band conditions estimated by rxd"}


def band_label(band):
    """"20m" -> "20 m"."""
    return band[:-1] + " m" if band and band.endswith("m") and not band.endswith("cm") else \
        (band or "?")


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def write_json(path, doc):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1)
    os.replace(tmp, path)


def http_get(url, timeout=10.0, limit=262144):
    import urllib.request  # here, not at the top: only the band plan fetches
    req = urllib.request.Request(url, headers={"User-Agent": RXD_VERSION + " (band plan)"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read(limit)


# ------------------------------------------------------- band conditions

def _num(text):
    m = re.search(r"-?\d+(?:\.\d+)?", text or "")
    return float(m.group(0)) if m else None


def parse_hamqsl(xml):
    """N0NBH's solarxml.php -> {"source", "updated", "sfi", "a", "k", "bands", "vhf", ...}.

    "bands" is {"80m-40m": {"day": "Fair", "night": "Good"}, ...}, as they
    calculate it; "vhf" is their E-skip and aurora words by location."""
    import xml.etree.ElementTree as ET
    root = ET.fromstring(xml)
    sd = root.find("solardata") if root.tag == "solar" else root
    if sd is None:
        raise ValueError("no solardata in the hamqsl XML")

    def text(tag):
        el = sd.find(tag)
        return el.text.strip() if el is not None and el.text else ""
    bands = {}
    for b in sd.iter("band"):
        name, when = b.get("name"), (b.get("time") or "").lower()
        if name and when in ("day", "night") and b.text:
            bands.setdefault(name, {})[when] = b.text.strip()
    vhf = {}
    for ph in sd.iter("phenomenon"):
        if ph.text:
            vhf["%s %s" % (ph.get("name"), ph.get("location"))] = ph.text.strip()
    sfi = _num(text("solarflux"))
    if sfi is None or not bands:
        raise ValueError("the hamqsl XML has no solar flux or band conditions")
    k = _num(text("kindex"))
    a = _num(text("aindex"))
    return {"source": "hamqsl", "updated": text("updated"), "sfi": int(sfi),
            "a": int(a) if a is not None else None, "k": int(k) if k is not None else None,
            "bands": bands, "vhf": vhf, "geomag": text("geomagfield") or None,
            "noise": text("signalnoise") or None}


def model_conditions(sfi, k):
    """Day and night words for hamqsl's four HF groups from SFI and K alone: a
    rough stand-in for N0NBH's calculation, used when only NOAA answers."""
    hi = min(max((sfi - 65) / 100.0, 0.0), 1.0)      # SFI 65 -> 0, 165 -> 1
    storm = min(max(((k or 0) - 3) / 4.0, 0.0), 1.0)  # K 3 -> 0, K 7 -> 1

    def word(v):
        v *= 1 - 0.7 * storm
        return "Good" if v >= 0.7 else "Fair" if v >= 0.4 else "Poor"
    day = {"80m-40m": .55, "30m-20m": .6 + .4 * hi, "17m-15m": .25 + .7 * hi,
           "12m-10m": .1 + .8 * hi}
    night = {"80m-40m": .85, "30m-20m": .4 + .4 * hi, "17m-15m": .1 + .5 * hi,
             "12m-10m": .05 + .3 * hi}
    return {g: {"day": word(day[g]), "night": word(night[g])} for g in day}


def parse_swpc(flux_json, kp_json):
    """NOAA SWPC's 10.7 cm flux and planetary K JSON -> the same shape as parse_hamqsl."""
    flux = json.loads(flux_json)
    rows = [r for r in flux if isinstance(r, dict) and r.get("flux") is not None]
    if not rows:
        raise ValueError("no solar flux in SWPC's JSON")
    latest = max(rows, key=lambda r: r.get("time_tag") or "")
    sfi = float(latest["flux"])
    kp = json.loads(kp_json)
    k = a = None
    if kp and isinstance(kp[0], list):  # the older shape: a header row, then rows
        head = kp[0]
        last = kp[-1]
        k = float(last[head.index("Kp")]) if "Kp" in head else None
        a = float(last[head.index("a_running")]) if "a_running" in head else None
    elif kp:
        last = max((r for r in kp if isinstance(r, dict)), key=lambda r: r.get("time_tag") or "")
        k, a = last.get("Kp"), last.get("a_running")
    k = int(round(float(k))) if k is not None else None
    return {"source": "swpc", "updated": latest.get("time_tag"), "sfi": int(round(sfi)),
            "a": int(a) if a is not None else None, "k": k,
            "bands": model_conditions(sfi, k), "vhf": {}, "geomag": None, "noise": None}


class Conditions:
    """Band conditions, fetched at most every 45 minutes and kept on disk, so
    the rxd that starts after each band switch doesn't fetch them again."""

    MAX_AGE = 45 * 60    # fetch again after this
    RETRY = 15 * 60      # after a failure, wait this long
    STALE = 3 * 3600     # older than this, they're no guide

    def __init__(self, path, fetch=None, clock=time.time):
        self.path = path
        self.fetch = fetch or http_get
        self.clock = clock
        self.doc = read_json(path, {}) or {}

    def due(self, now=None):
        now = self.clock() if now is None else now
        d = self.doc
        return now - (d.get("fetched") or 0) >= self.MAX_AGE and \
            now - (d.get("tried") or 0) >= self.RETRY

    def refresh(self, now=None):
        """Fetch them (blocking, up to about 20 s); True if they came."""
        now = self.clock() if now is None else now
        errors = []
        cond = None
        try:
            cond = parse_hamqsl(self.fetch(HAMQSL_URL))
        except Exception as e:  # noqa: BLE001 - any failure falls back to NOAA
            errors.append("hamqsl: %s" % (getattr(e, "reason", None) or e))
        if cond is None:
            try:
                cond = parse_swpc(self.fetch(SWPC_FLUX_URL), self.fetch(SWPC_KP_URL))
            except Exception as e:  # noqa: BLE001
                errors.append("NOAA: %s" % (getattr(e, "reason", None) or e))
        d = dict(self.doc, tried=now)
        if cond is not None:
            d.update(fetched=now, cond=cond, error=None)
        else:
            d["error"] = "; ".join(str(x) for x in errors)[:200]
            log("band conditions: %s" % d["error"])
        self.doc = d
        try:
            write_json(self.path, d)
        except OSError as e:
            log("can't keep band conditions in %s: %s" % (self.path, e))
        return cond is not None

    def current(self, now=None):
        """The conditions if they're fresh enough to steer by, else None."""
        now = self.clock() if now is None else now
        if self.doc.get("cond") and now - (self.doc.get("fetched") or 0) < self.STALE:
            return self.doc["cond"]
        return None

    def error(self):
        return self.doc.get("error")


# ------------------------------------------------------------- the sun

def sun_elevation(lat, lon, t):
    """The sun's elevation in degrees at (lat, lon) at Unix time t; good to a
    fraction of a degree, which is plenty for day, night and gray line."""
    import math
    d = t / 86400.0 + 2440587.5 - 2451545.0  # days since J2000
    g = math.radians((357.529 + 0.98560028 * d) % 360)
    q = (280.459 + 0.98564736 * d) % 360
    lam = math.radians((q + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g)) % 360)
    eps = math.radians(23.439 - 0.00000036 * d)
    ra = math.atan2(math.cos(eps) * math.sin(lam), math.cos(lam))
    dec = math.asin(math.sin(eps) * math.sin(lam))
    gmst = (18.697374558 + 24.06570982441908 * d) % 24
    ha = math.radians(gmst * 15 + lon) - ra
    la = math.radians(lat)
    return math.degrees(math.asin(math.sin(la) * math.sin(dec) +
                                  math.cos(la) * math.cos(dec) * math.cos(ha)))


def day_part(t, latlon=None):
    """"day", "gray" (the sun within 6 degrees of the horizon) or "night".
    With no location, this machine's local clock stands in for the sun."""
    if latlon:
        e = sun_elevation(latlon[0], latlon[1], t)
        return "day" if e > 6 else "night" if e < -6 else "gray"
    h = time.localtime(t).tm_hour
    return "day" if 8 <= h < 17 else "gray" if h in (6, 7, 17, 18) else "night"


def sun_times(t, latlon):
    """(sunrise, sunset) Unix times on t's local day, either None if it doesn't
    happen (or no location)."""
    if not latlon:
        return None, None
    lt = time.localtime(t)
    start = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
    rise = sset = None
    prev = sun_elevation(latlon[0], latlon[1], start)
    for m in range(5, 24 * 60 + 1, 5):
        e = sun_elevation(latlon[0], latlon[1], start + m * 60)
        if prev < -0.833 <= e and rise is None:
            rise = start + m * 60
        if prev >= -0.833 > e and sset is None:
            sset = start + m * 60
        prev = e
    return rise, sset


# ----------------------------------------------------- scoring a band

def cond_value(band, cond, part):
    """0 to 1: how good the conditions say band is now, or None if they don't say."""
    if not cond:
        return None
    if band in HAMQSL_GROUP:
        g = (cond.get("bands") or {}).get(HAMQSL_GROUP[band]) or {}
        vals = [COND_VALUE.get((g.get(w) or "").lower()) for w in
                (("day", "night") if part == "gray" else (part,))]
        vals = [v for v in vals if v is not None]
        if not vals:
            return None
        v = sum(vals) / len(vals)
        if band == "160m" and part == "day":
            v *= 0.3  # the 80-40 group says little about 160 m by day
        return v
    vhf = " ".join((cond.get("vhf") or {}).values()).lower()
    if band == "6m":
        if "50mhz" in vhf or "6m es" in vhf:
            return 1.0
        sfi = cond.get("sfi") or 0
        return 0.6 if part == "day" and sfi >= 180 else 0.1
    if band == "2m":
        return 1.0 if "144mhz" in vhf else 0.05
    return None  # 2190 m and 630 m: the sun and what's heard are the guide


def band_score(band, part, cond, heard):
    """(score 0..1, what it rests on: "conditions", "heard" or "usual").

    heard is (how much was heard 0..1, how many good looks that rests on).
    The conditions and the usual pattern for the time of day make the base;
    what rxd has actually heard here at this hour soon outweighs them, since
    hearing the most is the point: 72 % after one good look, up to 90 %."""
    prior = BAND_PRIOR[part].get(band, 0.1)
    c = cond_value(band, cond, part)
    base = prior if c is None else 0.4 * prior + 0.6 * c
    h, n = heard or (0.0, 0.0)
    w = 0.9 * n / (n + 0.25) if n > 0 else 0.0
    return round((1 - w) * base + w * h, 4), ("conditions" if c is not None else "usual"), w


class BandHistory:
    """What rxd heard on each profile, by UTC hour, kept on disk.

    A sample is one visit's worth in one hour: units (WSPR slots decoded, or
    minutes of JS8), count (spots or decodes), calls (distinct stations) and
    the median signal level. Old samples count for less: half every 14 days."""

    KEEP_DAYS = 60
    PER_HOUR = 40
    HALF_LIFE = 14 * 86400.0

    def __init__(self, path, clock=time.time):
        self.path = path
        self.clock = clock
        doc = read_json(path, {}) or {}
        self.bands = doc.get("bands") if isinstance(doc.get("bands"), dict) else {}

    def save(self):
        try:
            write_json(self.path, {"version": 1, "bands": self.bands})
        except OSError as e:
            log("can't keep the band history in %s: %s" % (self.path, e))

    def add(self, name, t, units, count, calls, visit, level=None):
        """Add to the sample for this visit and hour (made if it's new)."""
        hour = "%02d" % time.gmtime(t).tm_hour
        rows = self.bands.setdefault(name, {}).setdefault(hour, [])
        s = rows[-1] if rows and rows[-1].get("v") == visit else None
        if s is None:
            s = {"t": round(t), "v": visit, "units": 0, "count": 0, "calls": 0}
            rows.append(s)
        s["units"] += units
        s["count"] += count
        s["calls"] += calls
        s["t"] = round(t)
        if level is not None:
            s["level"] = round(level, 1)
        cut = self.clock() - self.KEEP_DAYS * 86400
        rows[:] = [x for x in rows if x.get("t", 0) >= cut][-self.PER_HOUR:]
        self.save()

    def heard(self, name, t, scale, per=1.0):
        """(0..1, good looks it rests on, rate) for name around t's UTC hour;
        per is how many units make one good look."""
        hour = time.gmtime(t).tm_hour
        now = self.clock()
        wsum = rsum = 0.0
        for dh, wh in ((0, 1.0), (-1, 0.5), (1, 0.5)):
            for s in (self.bands.get(name) or {}).get("%02d" % ((hour + dh) % 24), []):
                if not s.get("units"):
                    continue
                w = wh * 0.5 ** (max(0.0, now - s.get("t", now)) / self.HALF_LIFE) * \
                    min(s["units"] / per, 3.0)
                rate = (s.get("count", 0) + s.get("calls", 0)) / 2.0 / s["units"]
                wsum += w
                rsum += w * rate
        if wsum <= 0:
            return 0.0, 0.0, None
        import math
        rate = rsum / wsum
        return 1 - math.exp(-rate / scale), wsum, rate


def js8_decoding(rx):
    """Whether something is decoding JS8 for rxd: rxd's own decoder when it has
    one (rx.js8dec, decoding unless its status reports an error), else JS8Call."""
    dec = getattr(rx, "js8dec", None)
    if dec is not None and hasattr(dec, "status"):
        try:
            st = dec.status()
            return bool(st.get("running", not st.get("error")))
        except Exception:  # noqa: BLE001
            return False
    try:
        return subprocess.run(["pgrep", "-x", "js8call"], stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=5).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


class BandPlanner:
    """Auto: choose and hop bands; Manual: stay put. Runs in rxd, one tick
    every few seconds, and keeps its state on disk across rxd's restarts."""

    TICK = 5.0
    SCAN_SLOTS = 2          # WSPR slots a band needs, scanning
    SETTLE = 90.0           # a switch asked for this recently is still under way
    STAY = 0.85             # stay unless another band scores this much better
    RESCAN = 20 * 3600.0    # a band scanned at this hour this recently counts as heard
    ROWS_EVERY = 60.0       # how often radio's profile list is re-read

    def __init__(self, rx, js8=None, conf_path=None, data_dir=None, profiles=None,
                 switch=None, conditions=None, clock=time.time, latlon=Ellipsis,
                 synced=None, js8_alive=None):
        self.rx = rx
        self.js8 = js8
        self.conf_path = conf_path or BANDS_CONF
        d = data_dir or BANDS_DIR
        self.state_path = os.path.join(d, "bandplan.json")
        self.profiles = profiles or list_profiles
        self.switch_fn = switch or spawn_switch
        self.clock = clock
        self.cond = conditions or Conditions(os.path.join(d, "conditions.json"), clock=clock)
        self.history = BandHistory(os.path.join(d, "bands.json"), clock=clock)
        if latlon is Ellipsis:
            latlon = grid_latlon(station_id()[1])
        self.latlon = latlon
        self.synced = synced or (lambda: clock_status().get("synced") is not False)
        self.js8_alive = js8_alive or (lambda: js8_decoding(rx))
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.conf = self.load_conf()
        self.state = read_json(self.state_path, None)
        self.fresh = self.state is None
        self.state = self.state if isinstance(self.state, dict) else {}
        self.rows, self.rows_at, self.rows_error = None, -1e18, None
        self.tried_at = -1e18
        self.scores = {}
        self.doc = None
        now = clock()
        w = rx.wspr
        self.visit = {"name": rx.s.name, "t": now, "id": int(now), "slots": 0, "units": 0.0,
                      "count": 0, "levels": [], "wspr_last": w.last if w else None,
                      "wspr_seq": w.seq if w else 0, "js8_seq": None, "js8_at": now}
        self.arrive(now)

    # ----------------------------------------------------- settings, state

    def load_conf(self):
        c = dict(PLAN_DEFAULTS)
        doc = read_json(self.conf_path, {})
        if isinstance(doc, dict):
            try:
                c.update(self.check(doc))
            except ValueError as e:
                log("ignoring %s: %s" % (self.conf_path, e))
        return c

    @staticmethod
    def check(doc):
        """The valid settings in doc; ValueError for one that isn't."""
        out = {}
        for k, v in doc.items():
            if k == "plan":
                if v not in ("auto", "manual"):
                    raise ValueError("plan must be auto or manual")
            elif k == "mode":
                if v not in PLAN_MODES:
                    raise ValueError("mode must be wspr or js8")
            elif k == "bands":
                if v is not None and (not isinstance(v, list) or
                                      any(b not in BAND_ORDER for b in v)):
                    raise ValueError("bands must be null (the default) or a list of: " +
                                     ", ".join(BAND_ORDER))
                v = None if v is None else [b for b in BAND_ORDER if b in v]
            elif k == "dwell_min":
                if isinstance(v, bool) or not isinstance(v, (int, float)) or not 2 <= v <= 60:
                    raise ValueError("dwell_min must be 2 to 60 minutes")
            elif k == "every_min":
                if isinstance(v, bool) or not isinstance(v, (int, float)) or not 10 <= v <= 240:
                    raise ValueError("every_min must be 10 to 240 minutes")
            elif k == "cross_side":
                if not isinstance(v, bool):
                    raise ValueError("cross_side must be true or false")
            else:
                continue  # scan and anything unknown are not settings
            out[k] = v
        return out

    def save_conf(self):
        try:
            write_json(self.conf_path, self.conf)
        except OSError as e:
            log("can't save the band plan's settings in %s: %s" % (self.conf_path, e))

    def save_state(self):
        try:
            write_json(self.state_path, self.state)
        except OSError as e:
            log("can't keep the band plan's state in %s: %s" % (self.state_path, e))

    def arrive(self, now):
        """A new rxd on rx.s.name: carry on if the plan sent it here, or go
        Manual if someone switched to it by hand (radio NAME, a picker)."""
        name = self.rx.s.name
        st = self.state
        if not self.fresh and self.conf["plan"] == "auto" and \
                name not in (st.get("on"), st.get("requested")):
            self.conf["plan"] = "manual"
            self.save_conf()
            st["reason"] = "Manual: %s was chosen outside the band plan" % name
            log("band plan: Manual, since %s was switched to by hand" % name)
        st["on"], st["requested"], st["requested_at"] = name, None, None
        if self.fresh:
            st["after_scan"] = True  # the very first choice: the best band, no margin
        self.save_state()

    # ------------------------------------------------------------- inputs

    def profile_rows(self, now, force=False):
        if force or self.rows is None or now - self.rows_at >= self.ROWS_EVERY:
            try:
                self.rows = self.profiles()["profiles"]
                self.rows_error = None
            except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as e:
                self.rows_error = str(e)
            self.rows_at = now
        return self.rows or []

    def side_up(self):
        """True if the Ham It Up is (as far as rxd knows) on UPCONVERT: the side
        the running profile needs, which is how Win last set the switch."""
        with self.rx.s.lock:
            return self.rx.s.upconverter() > 0

    def enabled(self, up):
        b = self.conf.get("bands")
        if b is None:  # the default: every band (Win's call, 2026-11-06); the side
            return list(BAND_ORDER)  # rule still keeps Auto to the switch's side
        return list(b)

    def plan_rows(self, now, mode=None):
        mode = mode or self.conf["mode"]
        return [r for r in self.profile_rows(now)
                if r.get("plan") and r.get("decoder") == mode and r.get("band")]

    def candidates(self, now):
        """(the profiles Auto may pick from, {band: why not} for the others)."""
        up = self.side_up()
        en = self.enabled(up)
        out, why = [], {}
        for r in self.plan_rows(now):
            if r["band"] not in en:
                why[r["band"]] = "not enabled"
            elif bool(r.get("upconvert")) != up and not self.conf["cross_side"]:
                why[r["band"]] = "needs the Ham It Up on %s" % (
                    "UPCONVERT" if r.get("upconvert") else "BYPASS")
            else:
                out.append(r)
        return out, why

    def current_row(self, now):
        name = self.rx.s.name
        return next((r for r in self.profile_rows(now) if r.get("name") == name), None)

    # ------------------------------------------------------------ learning

    def sample(self, now):
        """Count what was heard on this band since the last tick."""
        v = self.visit
        row = self.current_row(now)
        if not row or not row.get("band") or not row.get("plan"):
            return
        snap = self.rx.s.snapshot()
        if abs(snap["dial"] - float(row.get("freq") or 0)) > 5000:
            return  # retuned by hand within the profile: not this band's dial
        chain = self.rx.chain
        if chain is not None and snap.get("gain_db") is not None:
            v["levels"].append(chain.level_db)
            del v["levels"][:-240]
        if not self.synced():
            return  # with the clock off nothing decodes; that says nothing of the band
        w = self.rx.wspr
        if row.get("decoder") == "wspr" and w is not None:
            last = w.last
            if last and last != v["wspr_last"]:
                v["wspr_last"] = last
                got = w.since(v["wspr_seq"])
                v["wspr_seq"] = got["seq"]
                calls = {x.get("call") for x in got["lines"] if x.get("call")}
                try:
                    import calendar
                    t = calendar.timegm(time.strptime(last["slot"], "%Y-%m-%dT%H:%M:00Z"))
                except (ValueError, KeyError, TypeError):
                    t = now
                v["slots"] += 1
                v["units"] += 1
                v["count"] += int(last.get("spots") or 0)
                self.history.add(row["name"], t, 1, int(last.get("spots") or 0), len(calls),
                                 v["id"], self.level())
        elif row.get("decoder") == "js8" and self.js8 is not None:
            if v["js8_seq"] is None:
                v["js8_seq"] = self.js8.since(0)["seq"]
                v["js8_at"] = now
                return
            if now - v["js8_at"] < 60:
                return
            minutes = (now - v["js8_at"]) / 60.0
            got = self.js8.since(v["js8_seq"])
            v["js8_seq"], v["js8_at"] = got["seq"], now
            if not self.js8_alive():
                return
            dial = snap["dial"]
            lines = [x for x in got["lines"]
                     if abs(float(x.get("freq") or 0) - dial) < 3000]
            calls = {x.get("from") for x in lines if x.get("from")}
            v["units"] += minutes
            v["count"] += len(lines)
            self.history.add(row["name"], now, round(minutes, 2), len(lines), len(calls),
                             v["id"], self.level())

    def level(self):
        lv = sorted(self.visit["levels"])
        return lv[len(lv) // 2] if lv else None

    def heard(self, name, mode, now):
        return self.history.heard(name, now, HEARD_SCALE.get(mode, 3.0),
                                  HEARD_PER.get(mode, 1.0))

    def visit_done(self, now):
        v = self.visit
        dwell = max(float(self.conf["dwell_min"]), 2.0) * 60
        if now - v["t"] < dwell:
            return False
        if self.conf["mode"] == "wspr" and v["slots"] < self.SCAN_SLOTS:
            # no slots at all for long past the dwell: wsprd or the audio is
            # broken here; move on rather than wait forever
            return now - v["t"] > dwell + 6 * 60
        return True

    def quiet(self, now):
        """Not in the middle of decoding a WSPR slot, whose spots a switch would lose."""
        w = self.rx.wspr
        if w is None:
            return True
        if w.decoding is not None or not w.jobs.empty():
            return False
        return w.slot is None or now - w.slot < 60 or self.visit["slots"] == 0

    # ------------------------------------------------------------ deciding

    def part(self, now):
        return day_part(now, self.latlon)

    def score_all(self, rows, now, cond):
        part = self.part(now)
        out = {}
        for r in rows:
            h, n, rate = self.heard(r["name"], r["decoder"], now)
            s, basis, w = band_score(r["band"], part, cond, (h, n))
            out[r["name"]] = {"score": s, "basis": basis, "heard_w": w, "visits": round(n, 2),
                              "rate": round(rate, 2) if rate is not None else None}
        return out

    def because(self, row, sc, cond, now, stay=False, rival=None):
        """Why row is the one, in words. rival: the better-scoring band stayed off."""
        b = band_label(row["band"])
        if rival is not None:
            return "%s: staying; about as good as %s %s" % (
                b, band_label(rival["band"]),
                ("by conditions (SFI %s, K %s, %s)" % (cond.get("sfi"), cond.get("k"),
                                                       PART_WORDS[self.part(now)]))
                if cond else "by what rxd has heard at this hour")
        part = PART_WORDS[self.part(now)]
        unit = "spots a slot" if row["decoder"] == "wspr" else "decodes a minute"
        heard = sc.get("heard_w", 0) > 0 and sc.get("rate") is not None
        if cond:
            idx = "SFI %s, K %s, %s" % (cond.get("sfi"), cond.get("k"), part)
            what = "conditions and what rxd has heard here" if heard else "conditions"
            return "%s: %s by %s (%s)" % (b, "still best" if stay else "best", what, idx)
        if heard:
            return "%s: %s heard at this hour (%.1f %s); no band conditions" % (
                b, "still best" if stay else "best", sc["rate"], unit)
        return "%s: usually best by %s; no band conditions and nothing heard yet" % (b, part)

    def switch(self, row, reason, now):
        st = self.state
        st["reason"] = reason
        if row["name"] == self.rx.s.name:
            self.save_state()
            return
        if st.get("requested") == row["name"] and now - (st.get("requested_at") or 0) < self.SETTLE:
            return  # asked already; radio is on its way
        if now - self.tried_at < 60:
            return
        self.tried_at = now
        st["requested"], st["requested_at"] = row["name"], now
        self.save_state()
        log("band plan: switching to %s: %s" % (row["name"], reason))
        try:
            self.switch_fn(row["name"])
        except OSError as e:
            st["reason"] = "Can't switch to %s: %s" % (row["name"], e)
            self.save_state()

    def start_scan(self, rows, now, why):
        cur = self.rx.s.name
        part = self.part(now)
        order = sorted(rows, key=lambda r: (r["name"] != cur, -BAND_PRIOR[part].get(r["band"], 0)))
        st = self.state
        st.update(phase="scan", scan=[r["name"] for r in order], scan_i=0, scan_why=why,
                  next_eval=None)
        self.scan_step(order[0], now)

    def scan_step(self, row, now):
        st = self.state
        n, i = len(st["scan"]), st["scan_i"]
        self.switch(row, "Scanning: %s, %d of %d (%s)" % (band_label(row["band"]), i + 1, n,
                                                          st.get("scan_why") or "learning"),
                    now)

    def evaluate(self, now, cands, fresh=False):
        """Choose among cands. Staying put wins a near tie (a switch costs a slot),
        except straight after a scan, whose point was to compare them."""
        st = self.state
        cond = self.cond.current(now)
        sc = self.score_all(cands, now, cond)
        self.scores = sc
        if cond is None and self.synced():
            scanned = st.setdefault("scanned", {})
            hour = time.gmtime(now).tm_hour
            unknown = [r for r in cands if sc[r["name"]]["visits"] < 0.5 and
                       now - scanned.get("%s@%02d" % (r["name"], hour), 0) > self.RESCAN]
            if unknown:
                self.start_scan(unknown, now, "no band conditions; learning this hour")
                return
        best = max(cands, key=lambda r: sc[r["name"]]["score"])
        cur = next((r for r in cands if r["name"] == self.rx.s.name), None)
        st.update(phase="hold", scan=None, scan_i=None,
                  next_eval=now + float(self.conf["every_min"]) * 60)
        stay = sc[best["name"]]["score"] * (1.0 if fresh else self.STAY)
        if cur is not None and sc[cur["name"]]["score"] >= stay:
            rival = None if sc[cur["name"]]["score"] >= sc[best["name"]]["score"] else best
            self.switch(cur, self.because(cur, sc[cur["name"]], cond, now, stay=True,
                                          rival=rival), now)
        else:
            self.switch(best, self.because(best, sc[best["name"]], cond, now), now)

    def decide(self, now):
        st = self.state
        cur = self.rx.s.name
        if self.conf["plan"] != "auto":
            st["phase"] = "manual"
            if not (st.get("reason") or "").startswith("Manual"):
                st["reason"] = "Manual: staying on %s" % cur
            return
        if st.get("phase") == "manual":
            st["phase"] = None
            st["reason"] = None
        cands, _ = self.candidates(now)
        if not cands:
            st.update(phase="idle", reason="Auto: no %s bands enabled on the Ham It Up's %s side" % (
                "WSPR" if self.conf["mode"] == "wspr" else "JS8",
                "UPCONVERT" if self.side_up() else "BYPASS") if not self.rows_error else
                "Auto: can't list profiles (%s)" % self.rows_error)
            return
        names = [r["name"] for r in cands]
        if st.get("phase") == "scan" and (st.get("scan_why") or "").startswith("no band") and \
                self.cond.current(now) and self.quiet(now):
            st["phase"] = None  # scanning for want of conditions, and now there are some
        if st.get("phase") == "scan" and st.get("scan"):
            scan = [n for n in st["scan"] if n in names]
            if not scan:
                st["phase"] = None
            else:
                if scan != st["scan"]:
                    i = st.get("scan_i") or 0
                    keep = st["scan"][i] if i < len(st["scan"]) else None
                    st["scan"] = scan
                    st["scan_i"] = scan.index(keep) if keep in scan else min(i, len(scan) - 1)
                i = st["scan_i"]
                target = next(r for r in cands if r["name"] == st["scan"][i])
                if cur != target["name"]:
                    self.scan_step(target, now)
                    return
                if not self.visit_done(now) or not self.quiet(now):
                    v = self.visit
                    extra = " · slot %d of %d" % (min(v["slots"] + 1, self.SCAN_SLOTS),
                                                   self.SCAN_SLOTS) \
                        if self.conf["mode"] == "wspr" else ""
                    st["reason"] = "Scanning: %s, %d of %d (%s)%s" % (
                        band_label(target["band"]), i + 1, len(st["scan"]),
                        st.get("scan_why") or "learning", extra)
                    return
                scanned = st.setdefault("scanned", {})
                scanned["%s@%02d" % (cur, time.gmtime(now).tm_hour)] = now
                for k in [k for k, t in scanned.items() if now - t > self.RESCAN]:
                    del scanned[k]
                if i + 1 < len(st["scan"]):
                    st["scan_i"] = i + 1
                    nxt = next(r for r in cands if r["name"] == st["scan"][i + 1])
                    self.scan_step(nxt, now)
                    return
                st["phase"], st["after_scan"] = None, True  # the scan is done: choose
        due = st.get("phase") != "hold" or cur not in names or \
            now >= (st.get("next_eval") or 0)
        if due and self.quiet(now):
            self.evaluate(now, cands, fresh=bool(st.pop("after_scan", False)))

    # ---------------------------------------------------------- the loop

    def tick(self, now=None):
        now = self.clock() if now is None else now
        if self.cond.due(now):
            self.cond.refresh(now)  # outside the lock: it can take seconds
        with self.lock:
            self.sample(now)
            self.decide(now)
            self.save_state()
            self.doc = self.build_status(now)

    def run(self):
        while not self.rx.stop.is_set():
            try:
                self.tick()
            except Exception as e:  # noqa: BLE001 - the plan must never take rxd down
                log("band plan: %s: %s" % (type(e).__name__, e))
            self.wake.wait(self.TICK)
            self.wake.clear()

    def start(self):
        threading.Thread(target=self.run, name="bands", daemon=True).start()

    # --------------------------------------------------------------- API

    def configure(self, doc):
        """POST /api/bands: settings, and {"scan": true} to scan now."""
        if not isinstance(doc, dict):
            raise ValueError("body must be a JSON object")
        unknown = set(doc) - set(PLAN_DEFAULTS) - {"scan"}
        if unknown:
            raise ValueError("unknown field(s): " + ", ".join(sorted(unknown)))
        new = self.check(doc)
        if "scan" in doc and not isinstance(doc["scan"], bool):
            raise ValueError("scan must be true or false")
        now = self.clock()
        with self.lock:
            old = dict(self.conf)
            self.conf.update(new)
            if doc.get("scan"):
                self.conf["plan"] = "auto"
            self.save_conf()
            st = self.state
            changed = any(old.get(k) != self.conf.get(k) for k in
                          ("plan", "mode", "bands", "cross_side"))
            if doc.get("scan"):
                cands, _ = self.candidates(now)
                if cands:
                    self.start_scan(cands, now, "asked for")
            elif changed and self.conf["plan"] == "auto":
                st.update(phase=None, scan=None, scan_i=None, next_eval=None)
            elif self.conf["plan"] == "auto" and old.get("every_min") != self.conf["every_min"] \
                    and st.get("phase") == "hold":
                st["next_eval"] = now + float(self.conf["every_min"]) * 60
            if self.conf["plan"] == "manual":
                st["reason"] = "Manual: staying on %s" % self.rx.s.name
            self.save_state()
            self.doc = self.build_status(now)
        self.wake.set()
        return self.describe()

    def manual_pick(self, name):
        """A profile picked by hand (POST /api/profile): the plan goes Manual."""
        with self.lock:
            if self.conf["plan"] == "auto":
                self.conf["plan"] = "manual"
                self.save_conf()
            self.state["reason"] = "Manual: %s picked by hand" % name
            self.state["on"] = name  # so the next rxd doesn't take it for a surprise
            self.save_state()
            self.doc = self.build_status(self.clock())

    def build_status(self, now):
        st = self.state
        cond = self.cond.current(now)
        up = self.side_up()
        row = self.current_row(now)
        scan = None
        if st.get("phase") == "scan" and st.get("scan"):
            i = st.get("scan_i") or 0
            nm = st["scan"][min(i, len(st["scan"]) - 1)]
            r = next((x for x in self.profile_rows(now) if x.get("name") == nm), None)
            scan = {"i": i + 1, "n": len(st["scan"]), "profile": nm,
                    "band": r.get("band") if r else None}
        rise, sset = sun_times(now, self.latlon)
        part = self.part(now)
        return {"plan": self.conf["plan"], "mode": self.conf["mode"],
                "phase": st.get("phase") or ("manual" if self.conf["plan"] != "auto" else "idle"),
                "profile": self.rx.s.name, "band": row.get("band") if row else None,
                "reason": st.get("reason") or ("Auto: choosing a band" if
                                               self.conf["plan"] == "auto" else
                                               "Manual: staying on %s" % self.rx.s.name),
                "scan": scan, "next_at": st.get("next_eval") if st.get("phase") == "hold" else None,
                "switching_to": st.get("requested"),
                "bands": self.enabled(up), "default_bands": self.conf.get("bands") is None,
                "dwell_min": self.conf["dwell_min"], "every_min": self.conf["every_min"],
                "cross_side": self.conf["cross_side"], "side": "UPCONVERT" if up else "BYPASS",
                "sun": {"part": part, "words": PART_WORDS[part], "sunrise": rise, "sunset": sset,
                        "located": bool(self.latlon)},
                "conditions": None if not cond else {
                    "source": cond.get("source"), "sfi": cond.get("sfi"), "a": cond.get("a"),
                    "k": cond.get("k"), "updated": cond.get("updated"),
                    "fetched": self.cond.doc.get("fetched"), "bands": cond.get("bands"),
                    "credit": CREDITS.get(cond.get("source"), "")},
                "conditions_error": None if cond else self.cond.error()}

    def status(self):
        doc = self.doc
        if doc is None:
            with self.lock:
                doc = self.doc = self.build_status(self.clock())
        return doc

    def describe(self):
        """GET /api/bands: settings, status, and every band profile with how it scores."""
        now = self.clock()
        with self.lock:
            cond = self.cond.current(now)
            up = self.side_up()
            en = self.enabled(up)
            rows = []
            for mode in PLAN_MODES:
                prs = self.plan_rows(now, mode)
                sc = self.score_all(prs, now, cond)
                for r in sorted(prs, key=lambda r: BAND_ORDER.index(r["band"])
                                if r["band"] in BAND_ORDER else 99):
                    why = None
                    if r["band"] not in en:
                        why = "not enabled"
                    elif bool(r.get("upconvert")) != up and not self.conf["cross_side"]:
                        why = "needs the Ham It Up on %s" % (
                            "UPCONVERT" if r.get("upconvert") else "BYPASS")
                    s = sc[r["name"]]
                    rows.append({"name": r["name"], "mode": mode, "band": r["band"],
                                 "freq": r.get("freq"), "upconvert": bool(r.get("upconvert")),
                                 "enabled": r["band"] in en, "eligible": why is None,
                                 "why_not": why, "score": s["score"], "basis": s["basis"],
                                 "heard": {"rate": s["rate"], "visits": s["visits"]}})
            return {"config": dict(self.conf), "status": self.build_status(now),
                    "all_bands": list(BAND_ORDER), "profiles": rows}


def make_bands(rx, js8):
    """The band plan for a live rxd, or None (RXD_BANDS=off, or not the dongle)."""
    env = os.environ.get("RXD_BANDS", "")
    if env == "off" or (env != "on" and not isinstance(rx.src, RtlSource)):
        return None
    try:
        bp = BandPlanner(rx, js8)
    except Exception as e:  # noqa: BLE001 - never stop rxd for the plan
        log("band plan off: %s" % e)
        return None
    bp.start()
    return bp


# ---------------------------------------------------------------------- map
# The web UI's station map. Two endpoints, both read-only:
#   GET /tiles/Z/X/Y.png  offline raster tiles (z/x/y, Web Mercator), from
#                         $RXD_TILES or the tree setup.sh installs for
#                         meshtastic-ui: ~/.portduino/default/maps/<style>/
#                         (OSM standard style, zoom 1-6 worldwide). Nothing
#                         is ever fetched from the internet.
#   GET /tiles/info.json  whether there are tiles, and which zooms
#   GET /api/stations     stations heard by JS8 and WSPR that have a grid,
#                         one per mode and call, at their grid square's centre
# Grids for JS8 stations come from their own heartbeats and CQs ("W1AW: @HB
# HEARTBEAT FN31"): DIRECTED.TXT drops the grid from those, so ALL.TXT beside
# it is read too. Learned grids are kept in $RXD_GRIDS
# (~/.local/share/rxd/grids.json) so a station that heartbeats once stays on
# the map when it's heard again later. No online callsign lookups.

TILE_DIRS = (os.environ.get("RXD_TILES", ""), "~/.portduino/default/maps", "/maps")
TILE_TYPES = {"png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp"}
TILE_PATH = re.compile(r"^/tiles/(\d{1,2})/(\d{1,7})/(\d{1,7})\.(png|jpg|jpeg|webp)$")
GRIDS_FILE = os.path.expanduser(os.environ.get("RXD_GRIDS", "~/.local/share/rxd/grids.json"))
TILE_ATTRIBUTION = "\u00a9 OpenStreetMap contributors"


def tile_root(dirs=TILE_DIRS):
    """The first directory holding a z/x/y tree, as (path, sorted zooms), else (None, [])."""
    for d in dirs:
        if not d:
            continue
        d = os.path.expanduser(d)
        try:
            names = os.listdir(d)
        except OSError:
            continue
        zooms = sorted(int(n) for n in names if n.isdigit() and os.path.isdir(os.path.join(d, n)))
        if zooms:
            return os.path.realpath(d), zooms
        # meshtastic-ui's layout: maps/<style>/z/x/y, OSM's style first
        for style in sorted(names, key=lambda n: (n not in ("openstreetmap", "osm"), n)):
            sub = os.path.join(d, style)
            try:
                zs = sorted(int(n) for n in os.listdir(sub) if n.isdigit())
            except OSError:
                continue
            if zs:
                return os.path.realpath(sub), zs
    return None, []


def tile_file(root, path):
    """The file for /tiles/Z/X/Y.ext under root, or None for anything else."""
    m = TILE_PATH.match(path)
    if not root or not m:
        return None, None
    z, x, y = int(m[1]), int(m[2]), int(m[3])
    if z > 22 or x >= 1 << z or y >= 1 << z:
        return None, None
    f = os.path.realpath(os.path.join(root, str(z), str(x), "%d.%s" % (y, m[4])))
    if not f.startswith(root + os.sep) or not os.path.isfile(f):
        return None, None
    return f, TILE_TYPES[m[4]]


def serve_tile(h, path):
    root, zooms = getattr(h.server, "tile_root", None) or tile_root()
    if path == "/tiles/info.json":
        return h.send(200, {"available": bool(root), "zooms": zooms,
                            "min": zooms[0] if zooms else None, "max": zooms[-1] if zooms else None,
                            "attribution": TILE_ATTRIBUTION if root else None})
    f, ctype = tile_file(root, path)
    if not f:
        return h.send(404, {"error": "no such tile"})
    with open(f, "rb") as fh:
        body = fh.read()
    h.send_response(200)
    h.send_header("Content-Type", ctype)
    h.send_header("Content-Length", str(len(body)))
    h.send_header("Cache-Control", "max-age=86400")
    h.end_headers()
    h.wfile.write(body)


def js8_grid(text):
    """(call, grid) from a JS8 heartbeat or CQ that carries one, else None."""
    frm, _, body = (text or "").replace("\u2662", "").partition(":")
    frm, words = frm.strip(), body.split()
    if len(words) < 2 or not CALLSIGN.match(frm) or not GRID.match(words[-1]):
        return None
    if not {"HEARTBEAT", "CQ", "GRID"} & set(words[:-1]):
        return None
    g = words[-1]
    return frm, g[:4].upper() + g[4:].lower()


# ALL.TXT, one line per JS8 frame:
# "2026-11-06 10:47:00-11  0.3  605 B  3+pVJzNoOkJW         3    WD4UQ: @HB HEARTBEAT EM88"
JS8_ALL_LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s*([+-]?\d+)\s+[+-]?\d+\.\d+\s+\d+\s+"
                          r"\S\s+\S+\s+\d+\s+(.*\S)\s*$")


def iso_utc(t):
    """'2026-11-06 10:47:03' or '2026-11-06T12:20:00Z' (both UTC) -> '2026-11-06T10:47:03Z'."""
    m = re.match(r"^(\d{4}-\d\d-\d\d)[ T](\d\d:\d\d)(:\d\d)?", t or "")
    return "%sT%s%sZ" % (m[1], m[2], m[3] or ":00") if m else None


# The offline callsign database rxd/callsign_db.py builds (FCC licences
# geocoded to 6-character grids, ZIP centroids, and cty.dat prefixes for
# everyone else). Read-only here; reopened when the updater replaces it.
CALLSIGNS_DB = os.path.expanduser(os.environ.get("RXD_CALLSIGNS", "~/.local/share/rxd/callsigns.sqlite"))
# call suffixes that say how, not where: /P portable, /M mobile, /QRP ...
CALL_SUFFIXES = {"P", "M", "QRP", "QRPP", "A", "LH", "R", "B", "J", "Y"}


class CallBook:
    """call -> {"grid", "prec": "addr" | "zip" | "country", "region"}, or None."""

    def __init__(self, path=None):
        self.path = path or CALLSIGNS_DB
        self.con = self.stamp = None
        self.memo = {}

    def db(self):
        try:
            st = os.stat(self.path)
        except OSError:
            st = None
        stamp = st and (st.st_ino, st.st_mtime_ns)
        if stamp != self.stamp:
            if self.con:
                self.con.close()
            self.con, self.stamp, self.memo = None, stamp, {}
            if st:
                try:
                    self.con = sqlite3.connect("file:%s?mode=ro" % urllib.parse.quote(self.path),
                                               uri=True, check_same_thread=False)
                    self.con.execute("SELECT 1 FROM calls LIMIT 1")
                except sqlite3.Error as e:
                    log("callsign database %s unusable: %s" % (self.path, e))
                    self.con = None
        return self.con

    def country(self, con, s):
        keys = ["=" + s] + [s[:n] for n in range(len(s), 0, -1)]
        rows = dict((k, (g, e)) for k, g, e in con.execute(
            "SELECT prefix, grid, entity FROM prefixes WHERE prefix IN (%s)" % ",".join("?" * len(keys)),
            keys))
        for k in keys:
            if k in rows:
                return {"grid": rows[k][0], "prec": "country", "region": rows[k][1]}
        return None

    def lookup(self, call):
        con = self.db()
        call = (call or "").strip().upper()
        if not con or not call:
            return None
        if call in self.memo:
            return self.memo[call]
        try:
            self.memo[call] = r = self.find(con, call)
        except sqlite3.Error:
            r = None
        return r

    def find(self, con, call):
        parts = [p for p in call.split("/") if p]
        if not parts or any(p in ("MM", "AM") for p in parts[1:]):
            return None  # at sea or in the air
        r = con.execute("SELECT grid, entity FROM prefixes WHERE prefix=?", ("=" + call,)).fetchone()
        if r:
            return {"grid": r[0], "prec": "country", "region": r[1]}
        full = [p for p in parts if CALLSIGN.match(p)]
        home = max(full, key=len) if full else parts[0]
        rest = [p for p in parts if p != home and p not in CALL_SUFFIXES]
        if rest:  # VE3/KA1PID, EA8/K1ABC, KA1PID/4: operating away from home
            where = rest[0]
            if where.isdigit():
                where = home
            return self.country(con, where)
        r = con.execute("SELECT grid, prec, region FROM calls WHERE call=?", (home,)).fetchone()
        if r:
            return {"grid": r[0], "prec": r[1], "region": r[2]}
        return self.country(con, home)


class StationMap:
    """Heard stations with a grid, merged per mode and call, for /api/stations."""

    ALL_TAIL = 262144

    def __init__(self, js8=None, wspr=None, all_path=None, grids_path=None, clock=time.time,
                 me=None, book=None):
        self.js8 = js8                # a Js8Feed (or anything with since())
        self.book = book if book is not None else CallBook()  # the offline callsign database
        self.wspr = wspr              # a callable returning the WsprDecoder or None
        self.all_path = all_path if all_path is not None else \
            os.path.join(os.path.dirname(JS8_LOG), "ALL.TXT")
        self.grids_path = grids_path if grids_path is not None else GRIDS_FILE
        self.clock = clock
        self.me = me if me is not None else station_id()
        self.lock = threading.Lock()
        self.grids = {}               # call -> {"grid", "time"}
        self.heard = {}               # call -> JS8 frames from ALL.TXT: {"time", "snr", "freq"}
        self.all_pos = self.all_inode = None
        self.dirty = False
        try:
            with open(self.grids_path, encoding="utf-8") as fh:
                doc = json.load(fh)
            self.grids = {c: v for c, v in doc.items()
                          if isinstance(v, dict) and GRID.match(str(v.get("grid", "")))}
        except (OSError, ValueError, AttributeError):
            pass

    @staticmethod
    def lines(src):
        if src is None:
            return []
        lk = getattr(src, "lock", None)
        if isinstance(getattr(src, "lines", None), collections.deque) and lk is not None:
            if hasattr(src, "refresh"):
                src.since(1 << 62)  # reads anything new in the log
            with lk:
                return list(src.lines)
        return src.since(0).get("lines", [])

    def learn(self, call, grid, t):
        old = self.grids.get(call)
        if old and (t or "") < (old.get("time") or ""):
            return  # an older frame: keep the newer grid
        if not old or old["grid"] != grid:
            self.dirty = True
        self.grids[call] = {"grid": grid, "time": t}

    def read_all(self):
        """New heartbeat and CQ frames with grids from ALL.TXT."""
        try:
            st = os.stat(self.all_path)
        except OSError:
            return
        if self.all_inode != st.st_ino or (self.all_pos or 0) > st.st_size:
            self.all_inode, self.all_pos = st.st_ino, max(st.st_size - self.ALL_TAIL, 0)
        if self.all_pos == st.st_size:
            return
        with open(self.all_path, "rb") as fh:
            fh.seek(self.all_pos)
            data = fh.read()
        cut = data.rfind(b"\n") + 1
        self.all_pos += cut
        for raw in data[:cut].decode("utf-8", "replace").split("\n"):
            m = JS8_ALL_LINE.match(raw)
            cg = m and js8_grid(m[3])
            if cg:
                t = iso_utc(m[1])
                self.learn(cg[0], cg[1], t)
                self.heard.setdefault(cg[0], []).append({"time": t, "snr": int(m[2])})
                del self.heard[cg[0]][:-50]

    def save(self):
        if not self.dirty:
            return
        self.dirty = False
        try:
            os.makedirs(os.path.dirname(self.grids_path), exist_ok=True)
            tmp = self.grids_path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(self.grids, fh, sort_keys=True)
            os.replace(tmp, self.grids_path)
        except OSError as e:
            log("can't save grids to %s: %s" % (self.grids_path, e))

    def snapshot(self, hours=24.0):
        cutoff = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(self.clock() - hours * 3600))
        out, nogrid = {}, set()

        def add(mode, call, grid, t, snr, freq=None, dbm=None):
            if not t or t < cutoff:
                return
            src, region = "heard", None
            if not grid:
                # never heard with a grid: the callsign database, if it knows
                found = self.book.lookup(call) if self.book else None
                if not found:
                    nogrid.add((mode, call))
                    return
                grid, src, region = found["grid"], found["prec"], found.get("region")
            k = (mode, call)
            s = out.get(k)
            if s is None:
                ll = grid_latlon(grid)
                s = out[k] = {"call": call, "mode": mode, "grid": grid, "lat": round(ll[0], 4),
                              "lon": round(ll[1], 4),
                              "km": grid_km(self.me[1], grid) if src != "country" else None,
                              "snr": snr, "last": t, "last_snr": snr, "freq": freq, "dbm": dbm,
                              "src": src, "region": region}
            if snr is not None and (s["snr"] is None or snr > s["snr"]):
                s["snr"] = snr
            if t >= s["last"]:
                s["last"], s["last_snr"] = t, snr
                if freq is not None:
                    s["freq"] = freq
                if dbm is not None:
                    s["dbm"] = dbm
                if grid != s["grid"] and src == "heard" == s["src"]:  # moved: plot it where it is now
                    ll = grid_latlon(grid)
                    s.update(grid=grid, lat=round(ll[0], 4), lon=round(ll[1], 4),
                             km=grid_km(self.me[1], grid))

        with self.lock:
            self.read_all()
            js8 = self.lines(self.js8)
            for ln in js8:
                cg = js8_grid(ln.get("text"))
                if cg:
                    self.learn(cg[0], cg[1], iso_utc(ln.get("time")))
            wspr = self.wspr() if self.wspr else None
            spots = self.lines(wspr)
            for sp in spots:
                if sp.get("grid") and sp.get("call"):
                    self.learn(sp["call"], sp["grid"], sp.get("time"))
            self.save()
            grids = self.grids
            for call, frames in self.heard.items():
                for f in frames:
                    add("js8", call, grids[call]["grid"], f["time"], f["snr"])
            for ln in js8:
                call = ln.get("from")
                t = iso_utc(ln.get("time"))
                if not call or not CALLSIGN.match(call):
                    continue
                g = grids.get(call)
                add("js8", call, g and g["grid"], t, ln.get("snr"), ln.get("freq"))
            for sp in spots:
                call = sp.get("call")
                g = sp.get("grid") or (grids.get(call) or {}).get("grid")
                add("wspr", call, g, sp.get("time"), sp.get("snr"), sp.get("freq"), sp.get("dbm"))
        stations = sorted(out.values(), key=lambda s: s["last"], reverse=True)
        call, grid = self.me
        ll = grid_latlon(grid)
        me = {"call": call, "grid": grid, "lat": ll[0], "lon": ll[1]} if ll else None
        return {"me": me, "hours": hours, "stations": stations,
                "no_grid": {m: sum(1 for x in nogrid if x[0] == m and x not in out)
                            for m in ("js8", "wspr")}}


def serve_stations(h):
    srv = h.server
    if getattr(srv, "stations", None) is None:
        srv.stations = StationMap(js8=getattr(srv, "js8", None), wspr=lambda: srv.rx.wspr)
    q = urllib.parse.parse_qs(urllib.parse.urlparse(h.path).query)
    try:
        hours = float(q.get("hours", ["24"])[0])
        if not 0 < hours <= 24 * 30:
            raise ValueError
    except ValueError:
        return h.send(400, {"error": "hours must be a number from 0 to 720"})
    doc = srv.stations.snapshot(hours)
    doc["decoder"] = srv.rx.s.decoder
    return h.send(200, doc)


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
        if path == "/api/bands":
            return self.bands_get()
        if path.startswith("/tiles/"):
            return serve_tile(self, path)
        if path == "/api/stations":
            return serve_stations(self)
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
        if self.path == "/api/bands":
            return self.bands_post()
        if self.path != "/api/tune":
            return self.send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", 0))
            doc = json.loads(self.rfile.read(n) or b"{}")
            if not isinstance(doc, dict):
                raise ValueError("body must be a JSON object")
            unknown = set(doc) - {"freq", "mode", "bandwidth", "gain_db", "volume", "squelch",
                                  "wspr_report", "gain_auto"} - {"audio_" + k for k in AUDIO_KEYS}
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
        if self.server.rx.bands is not None:
            self.server.rx.bands.manual_pick(name)
        self.send(202, {"switching": name})

    # the band plan (BandPlanner)
    def bands_get(self):
        bp = self.server.rx.bands
        if bp is None:
            return self.send(503, {"error": "no band plan: this rxd isn't on the radio "
                                            "(or RXD_BANDS=off)"})
        return self.send(200, bp.describe())

    def bands_post(self):
        bp = self.server.rx.bands
        if bp is None:
            return self.send(503, {"error": "no band plan: this rxd isn't on the radio "
                                            "(or RXD_BANDS=off)"})
        try:
            n = int(self.headers.get("Content-Length", 0))
            doc = json.loads(self.rfile.read(n) or b"{}")
            return self.send(200, bp.configure(doc))
        except (ValueError, TypeError) as e:
            return self.send(400, {"error": str(e)})


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
    try:
        if settings.decoder == "js8" and js8_engine(p) == "rxd":
            rx.js8dec = make_js8(settings, p)
    except ValueError as e:
        sys.exit("rxd: " + str(e))
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
        hs.js8 = Js8Feed(rx.js8dec.directed_path if rx.js8dec is not None else None)
        servers.append(hs)
        rx.bands = make_bands(rx, hs.js8)
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
    a = audio_of(st)
    if sq is None and a and a["auto"] and a.get("squelch"):
        if st.get("squelch_open") is False:
            return "Auto  %s Closed (quiet)" % g.stop, "label"
        return "Auto  %s Open (signal)" % g.rx, "ok"
    if sq is None:
        return "Off, always open", "value"
    lvl = "%d dBFS" % round(sq)
    if st.get("squelch_open") is False:
        return "%s  %s Closed (quiet)" % (lvl, g.stop), "label"
    return "%s  %s Open (signal)" % (lvl, g.rx), "ok"


# ---- gain: auto RF gain and audio clean-up

# Manual's keys for each stage of rxd's audio clean-up: (key, field, words)
AUDIO_STAGES = (("n", "nr", "noise reduction"), ("h", "filter", "hum filter"),
                ("e", "norm", "even loudness"), ("c", "limit", "limiter"),
                ("S", "squelch", "NFM squelch"))
AUDIO_SHORT = {"nr": "NR", "filter": "hum", "norm": "loudness", "limit": "limiter",
               "squelch": "squelch"}


def audio_of(st):
    """rxd's audio settings with anything sent but not yet confirmed, or None
    for an rxd without them. nr is the effective state; nr_setting None is
    "by mode" (on except for WFM)."""
    a = st.get("audio") if st else None
    if not isinstance(a, dict) or not isinstance(a.get("auto"), bool):
        return None
    a = dict(a)
    for k in ("auto",) + tuple(f for _, f, _ in AUDIO_STAGES):
        if "audio_" + k in st:
            a[k] = st["audio_" + k]
    if "audio_nr" in st:
        a["nr_setting"] = st["audio_nr"]
        a["nr"] = st["mode"] != "WFM" if st["audio_nr"] is None else st["audio_nr"]
    return a


def gain_words(st):
    """The gain in use, and whether rxd picks it: "Auto 7.7 dB" or "7.7 dB"."""
    gain = st.get("gain_db") if st else None
    if gain is None:
        return "---"
    return ("Auto %.1f dB" if st.get("gain_auto") else "%.1f dB") % gain


def audio_words(st, short=False):
    """What the clean-up is doing: "Auto: NR, hum, loudness, limiter" or "Off"."""
    a = audio_of(st)
    if a is None:
        return "---"
    if not a["auto"]:
        return "Off, untouched"
    names = AUDIO_SHORT if short else {f: w for _, f, w in AUDIO_STAGES}
    on = [names[f] for _, f, _ in AUDIO_STAGES
          if a.get(f) and (f != "squelch" or st.get("mode") == "FM")]
    return "Auto: " + (", ".join(on) if on else "nothing on")


def audio_toggle(st, key):
    """(fields to send, message) for A (all of it) or a stage's key in Manual."""
    a = audio_of(st)
    if a is None:
        return None, "This rxd has no audio clean-up"
    if key == "A":
        on = not a["auto"]
        return {"audio_auto": on}, "Audio clean-up %s" % ("on" if on else "off, untouched")
    _, field, words = next(x for x in AUDIO_STAGES if x[0] == key)
    if not a["auto"]:
        return None, "Audio clean-up is off; A turns it on"
    if field == "squelch" and st.get("mode") != "FM":
        return None, "The noise squelch is for NFM only"
    on = not a.get(field)
    v = on
    if field == "nr" and on == (st.get("mode") != "WFM"):
        v = None   # what the mode does anyway: back to "by mode"
    return {"audio_" + field: v}, "%s %s" % (words[0].upper() + words[1:], "on" if on else "off")


def squelch_cycle(st, level):
    """Listen's s on an rxd with the noise squelch: Off, Auto, Level, Off..."""
    a = audio_of(st)
    auto = bool(a and a["auto"] and a.get("squelch"))
    if st.get("squelch") is not None:
        return {"squelch": None, "audio_squelch": False}, "Squelch off"
    if auto:
        return {"squelch": level}, "Squelch opens above %d dBFS" % round(level)
    return {"audio_squelch": True, "audio_auto": True}, "Squelch auto: opens for a signal"


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


# ---- the band plan (rxd's status band_plan; POST /api/bands)

def band_plan_words(bp, g):
    """(text, role) for the band plan line: Auto or Manual, and why this band."""
    if not isinstance(bp, dict):
        return None
    auto = bp.get("plan") == "auto"
    mode = "WSPR" if bp.get("mode") == "wspr" else "JS8"
    head = "Band plan Auto %s %s" % (g.dot, mode) if auto else "Band plan Manual"
    phase = bp.get("phase")
    sym = g.stop if not auto else g.wait if phase == "scan" else g.drop if phase == "idle" else g.rx
    reason = bp.get("reason") or ""
    if reason.startswith("Manual: "):
        reason = reason[len("Manual: "):]
    role = "warn" if auto and phase == "idle" else "ok" if auto else "label"
    return "%s %s: %s" % (sym, head, reason), role


def band_plan_extra(bp, g):
    """The second band plan line: conditions (credited) and the sun, or why there are none."""
    if not isinstance(bp, dict):
        return None
    sun = bp.get("sun") or {}
    words = (sun.get("words") or "").capitalize()
    c = bp.get("conditions")
    if c:
        who = "N0NBH, hamqsl.com" if c.get("source") == "hamqsl" else "NOAA SWPC"
        text = "SFI %s %s K %s (%s)" % (c.get("sfi"), g.dot, c.get("k"), who)
    else:
        text = "No band conditions (offline?)"
    if words:
        text += "   %s" % words
    if bp.get("plan") == "auto" and bp.get("phase") == "hold" and bp.get("next_at"):
        text += "   next look %s" % time.strftime("%H:%M", time.localtime(bp["next_at"]))
    return text


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
                "reporting": "report", "auto gain": "auto g", "auto audio": "auto a",
                "clean-up": "clean"}


def help_items(g, view="manual", mode=None, listening=False, decoder=None, report=False,
               plan=False):
    """[(keys, label)] for a view's bottom line; ? and q always come last.
    In Digital, decoder is the receiver's ("js8", "wspr" or None) and report
    whether r can switch WSPR reporting, plan whether rxd has a band plan."""
    k = g.keys
    ud = k["updown"]
    if view == "digital":
        # When they don't all fit, the ones just before the view keys go first.
        items = [(ud + " Enter", "switch")] + ([("a", "auto")] if plan else [])
        if decoder == "wspr" and report:
            items.append(("r", "reporting"))
        if decoder != "js8":
            items += [("l", "listen")] + ([("[ ]", "volume")] if listening else [])
        items += [("PgUp PgDn", "scroll"), ("/", "filter")]
        if decoder == "js8" and listening:
            items.append(("l", "stop audio"))
        items.append(("1 2 3", "view"))
    elif view == "listen":
        items = [(ud + " Enter", "station"), ("g G", "gain"), ("a", "auto gain"),
                 ("A", "auto audio"), ("b", "bandwidth")]
        if mode == "FM":
            items.append(("s , .", "squelch"))
        items += [("l", "listen")] + ([("[ ]", "volume")] if listening else []) + \
            [("- +", "speaker"), ("M", "mute"), ("1 2 3", "view")]
    else:
        items = [(k["left"] + k["sep"] + k["right"], "tune"), (k["up"] + k["sep"] + k["down"], "step"),
                 ("f", "freq"), ("m", "mode"), ("l", "listen"), ("[ ]", "bandwidth"),
                 ("g G", "gain"), ("a", "auto gain"), ("A n h e c", "clean-up")] + \
            ([] if decoder == "js8" else [("- +", "volume")]) + [("1 2 3", "view")]
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
        self.bands_req = None      # a POST /api/bands body, for the side thread
        self.bands_acks = []       # (body, error or None)
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

    def bands(self, body):
        """The band plan's settings (Auto/Manual, mode, scan now), sent by the side thread."""
        with self.lock:
            self.bands_req = dict(self.bands_req or {}, **body)
        self.side_wake.set()

    def take_bands_acks(self):
        with self.lock:
            acks, self.bands_acks = self.bands_acks, []
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
                breq, self.bands_req = self.bands_req, None
                st, reachable = dict(self.status), self.reachable
            if breq:
                self._bands(breq)
                continue
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

    def _bands(self, body):
        try:
            code, doc = self.link.post("/api/bands", body, timeout=SLOW_TIMEOUT)
            err = None if code == 200 else \
                "rxd refused: %s" % (doc.get("error") or "HTTP %d" % code)
        except OSError as e:
            err = "Not sent: can't reach rxd (%s)" % reason(e)
            doc = {}
        with self.lock:
            self.bands_acks.append((body, err))
            if err is None and isinstance(doc.get("status"), dict):
                self.status = dict(self.status, band_plan=doc["status"])
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
        for body, err in (self.p.take_bands_acks() if hasattr(self.p, "take_bands_acks") else ()):
            if err:
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
        if sw.get("muted") is not None and st.get("volume") and decoder_of(st) != "js8":
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
        if self.decoder(s) == "js8":
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
        if decoder_of(st) == "js8":
            return self.say("Not on JS8: the receiver's audio feeds JS8Call")
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

    def gain_auto_key(self, st):
        """a: automatic RF gain on / off (off keeps the gain in use)."""
        if not st or "gain_auto" not in st:
            return self.say("This rxd has no automatic gain", "err") if st else self.not_yet()
        if st.get("gain_auto"):
            self.send(gain_db=st.get("gain_db"), gain_auto=False)
            self.say("Gain by hand, %.1f dB: g G change it" % st.get("gain_db"))
        else:
            self.send(gain_auto=True)
            self.say("Auto gain: rxd picks the best signal-to-noise")

    def audio_key(self, ch, st):
        if not st:
            return self.not_yet()
        fields, msg = audio_toggle(st, chr(ch))
        if fields:
            self.send(**fields)
        self.say(msg, "msg" if fields else "err")

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
        elif ch in (ord("a"), ord("m"), ord("s")):
            self.band_plan_key(ch, s)
        elif ch in (ord("["), ord("]")) and self.decoder(s) != "js8":
            self.local_volume_key(ch)
        else:
            self.other_key(ch)

    def band_plan_key(self, ch, s):
        """a: Auto / Manual; m: Auto listens for WSPR / JS8; s: scan the bands now."""
        bp = s["status"].get("band_plan")
        if not isinstance(bp, dict):
            self.say("This rxd has no band plan (it isn't on the radio)", "err")
        elif not s["reachable"]:
            self.say("Not sent: can't reach rxd", "err")
        elif ch == ord("a"):
            auto = bp.get("plan") != "auto"
            self.p.bands({"plan": "auto" if auto else "manual"})
            self.say("%s Band plan %s" % ((self.g.rx, "Auto: rxd picks the band") if auto
                                          else (self.g.stop, "Manual: staying on this band")))
        elif ch == ord("m"):
            mode = "js8" if bp.get("mode") == "wspr" else "wspr"
            self.p.bands({"mode": mode})
            self.say("Auto listens for %s%s" % ("JS8" if mode == "js8" else "WSPR",
                                                "" if bp.get("plan") == "auto"
                                                else " (once a turns Auto on)"))
        else:
            self.p.bands({"scan": True})
            self.say("%s Scanning the bands; Auto" % self.g.wait)

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
        controls = (ord("g"), ord("G"), ord("b"), ord("s"), ord(","), ord("."), ord("a"), ord("A"))
        if ch in controls and self.mismatch(s):
            self.say("Receiver is on %s; pick a station first (%s Enter)" % (
                st.get("profile"), self.g.keys["updown"]))
        elif ch in (ord("g"), ord("G")):
            self.gain_key(ch, st)
        elif ch == ord("a"):
            self.gain_auto_key(st)
        elif ch == ord("A"):
            self.audio_key(ch, st)
        elif ch == ord("s") and audio_of(st) is not None and st.get("mode") == "FM":
            fields, msg = squelch_cycle(st, self.sq_level)
            self.send(**fields)
            self.say(msg)
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
        elif ch == ord("a"):
            self.gain_auto_key(st)
        elif ch in [ord(c) for c in "AnhecS"]:
            self.audio_key(ch, st)
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
                           wspr_can_report(st.get("wspr")),
                           isinstance(st.get("band_plan"), dict))
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
        bpw = band_plan_words(st.get("band_plan"), g)
        if bpw:
            put(y, 1, clip(g.text(bpw[0]), w - 2, g), bpw[1])
            y += 1
            if bottom - y > 10:
                put(y, 3, clip(g.text(band_plan_extra(st["band_plan"], g)), w - 4, g), "label")
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
            fields = [("Gain", gain_words(st)),
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
            if audio_of(st) is not None:
                scr.put(y, 1, "Audio", "label")
                scr.put(y, 7, clip(audio_words(st), w - 8, g), "value")
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
        for label, val in (("Gain", gain_words(st)), ("Speaker", spk),
                           ("Audio", audio_words(st, short=True))):
            if label == "Audio" and x + len(label) + len(val) + 2 > w:
                val = val.split(":")[0]   # just Auto or Off when the list won't fit
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
                "a         band plan Auto (rxd picks the band) / Manual",
                "m         Auto listens for WSPR / JS8",
                "s         scan the bands now (and Auto)",
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
                "          (sets it by hand: auto gain goes off)",
                "a         auto gain on / off",
                "A         auto audio (the clean-up) on / off",
                "b         bandwidth: Narrow, Normal, Wide",
                "s         squelch: off, auto, at a level (NFM only)",
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
                "a         auto gain on / off",
                "A         audio clean-up on / off",
                "n h e c S its parts on / off: noise reduction, hum",
                "          filter, even loudness, limiter, NFM squelch",
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
            lines = [x for x in lines if x]
            if len(lines) + 2 > scr.h:  # keep the last line: how to close it
                lines = lines[:max(scr.h - 3, 0)] + lines[-1:]
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
/* gain: auto RF gain and audio clean-up */
#gAuto{margin:6px 0 0}
#gAuto .btn small,#auSl .btn small,.augrid .btn small{display:block;font-size:14px;font-weight:600}
#gWhy{margin:4px 0 0}
body[data-view=listen] #gWhy{display:none}
.augrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:6px;margin-top:6px}
.augrid .btn{font-size:18px;line-height:1.1;text-align:left;padding:4px 10px}
@media (min-width:700px){#jStat{grid-template-columns:repeat(6,auto)}}
/* band plan and the band picker */
.seg{display:grid;grid-auto-flow:column;grid-auto-columns:1fr;gap:6px;margin-top:6px}
.bgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(96px,1fr));gap:6px;margin-top:8px}
.bbtn{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:0;min-height:64px;padding:4px;line-height:1.1;text-align:center;width:100%}
.bbtn .bb{font-size:21px;font-weight:750}
.bbtn .bf{font-size:14px;font-weight:600;color:var(--dim)}
.bbtn .ba{font-size:14px;font-weight:800;color:var(--accent)}
.bbtn .bw{font-size:14px;font-weight:700;color:var(--warn)}
.bbtn.cur{border:3px solid var(--accent);background:var(--panel);border-radius:10px;min-height:64px}
.bbtn[aria-pressed=true] .bf,.bbtn[aria-pressed=true] .bw{color:inherit}
.bpwhy{margin:4px 0 2px;font-size:21px;font-weight:750;overflow-wrap:anywhere}
.bpsub{margin:0 0 4px;font-size:16px;font-weight:600;color:var(--dim)}
.bpk{margin:12px 0 0;font-size:15px;color:var(--dim);font-weight:700}
.bpstep{display:grid;grid-template-columns:72px 1fr 72px;gap:6px;align-items:center;margin-top:6px}
.bpstep .val{text-align:center;font-size:20px;font-weight:700}
.bpcred{font-size:14px;color:var(--dim);margin:6px 0 0}
.bpcred a{color:var(--accent)}
/* ---------------------------------------------------------------- station map (map helper) */
.mapc .btn.wide{margin-top:0}
.mapv{position:relative;height:min(62vh,520px);margin-top:8px;border:1px solid var(--line);border-radius:10px;overflow:hidden;
  background:var(--plot);touch-action:none;user-select:none;-webkit-user-select:none;cursor:grab}
@media (min-width:900px){.mapv{height:min(70vh,640px)}}
.mtiles{position:absolute;inset:0;overflow:hidden;isolation:isolate}
.mtiles img{position:absolute;left:0;top:0;pointer-events:none;-webkit-user-drag:none;max-width:none}
:root[data-theme=dark] .mtiles img{filter:invert(1) hue-rotate(180deg) brightness(.8) contrast(.9)}
@media (prefers-color-scheme:dark){:root[data-theme=auto] .mtiles img{filter:invert(1) hue-rotate(180deg) brightness(.8) contrast(.9)}}
/* Night: grey, inverted (dark land), then multiplied by pure red, so no tile pixel can be anything but red or black */
:root[data-theme=night] .mtiles img{filter:grayscale(1) invert(1) brightness(.85) contrast(1.15)}
:root[data-theme=night] .mtiles::after{content:"";position:absolute;inset:0;background:#f00;mix-blend-mode:multiply;z-index:1}
.mapv canvas{position:absolute;inset:0;width:100%;height:100%;background:transparent;border-radius:0;touch-action:none;cursor:inherit}
.mattr{position:absolute;right:0;bottom:0;font-size:13px;font-weight:600;padding:1px 6px;background:var(--panel);color:var(--dim);border-top-left-radius:6px;opacity:.9}
.mctl{display:grid;grid-template-columns:repeat(4,1fr);gap:6px;margin-top:8px}
.mctl .btn{font-size:19px;padding:2px;min-width:0}
.mleg{display:flex;flex-wrap:wrap;gap:4px 16px;margin-top:8px;font-size:17px;font-weight:650}
.mleg .s{font-size:20px;margin-right:4px}
.mk-js8{color:var(--accent)}.mk-wspr{color:var(--mark)}.mk-me{color:var(--fg)}.mk-hollow{color:var(--dim)}.mleg .s.big{font-size:28px;line-height:20px}
.minfo{margin-top:8px;border-top:1px solid var(--line);padding-top:6px;font-size:17px}
.minfo .mi+.mi{border-top:1px solid var(--line);margin-top:6px;padding-top:6px}
.minfo .mc{font-size:22px;font-weight:750;margin-right:8px}
.minfo .mm{font-size:15px;font-weight:800;border:2px solid currentColor;border-radius:6px;padding:0 5px}
.minfo .md{display:block;font-size:17px;color:var(--dim);font-weight:600}
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
<section class="card" id="bPlan" data-v="digital" data-live hidden>
  <div class="lbl"><span>Band plan</span><span id="bpState"></span></div>
  <p id="bpWhy" class="bpwhy" role="status" aria-live="polite">—</p>
  <p id="bpSub" class="bpsub"></p>
  <div class="row2" role="group" aria-label="Band plan"><button type="button" class="btn" id="bpAuto">Auto</button><button type="button" class="btn" id="bpMan">Manual</button></div>
  <div id="bpAutoBox">
    <p class="bpk">Auto listens for</p>
    <div class="row2" role="group" aria-label="Auto listens for"><button type="button" class="btn" id="bpWspr">WSPR</button><button type="button" class="btn" id="bpJs8">JS8</button></div>
  </div>
  <p id="bpCond" class="bpsub"></p>
  <p id="bpCred" class="bpcred" hidden></p>
  <p id="bpMsg" class="msg" role="status" hidden></p>
  <button type="button" class="btn wide" id="bpMore" aria-expanded="false" aria-controls="bpSet">Bands and timing ▾</button>
  <div id="bpSet" hidden>
    <p class="bpk">Bands Auto may use</p>
    <div id="bpBands" class="bgrid" role="group" aria-label="Bands Auto may use"></div>
    <button type="button" class="btn wide" id="bpDef">Use the default bands</button>
    <p class="bpk">Other side of the Ham It Up</p>
    <div class="row2" role="group" aria-label="Other side of the Ham It Up"><button type="button" class="btn" id="bpSideOff">Stay on this side</button><button type="button" class="btn" id="bpSideOn">Allow, I'll flip it</button></div>
    <p class="bpk">Time on each band when scanning</p>
    <div class="bpstep"><button type="button" class="btn" id="bpDwDn" aria-label="Less time on each band">−</button><span id="bpDw" class="val">—</span><button type="button" class="btn" id="bpDwUp" aria-label="More time on each band">+</button></div>
    <p class="bpk">Check for a better band every</p>
    <div id="bpEvery" class="seg" role="group" aria-label="Check for a better band every"></div>
    <button type="button" class="btn wide" id="bpScan">Scan the bands now</button>
  </div>
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
  <div id="jGainC" hidden><span class="k">RF gain</span><span id="jGain" class="v">—</span></div>
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
<section class="card mapc" id="mapCard" data-v="digital" data-live>
  <button type="button" class="btn wide" id="mapTog" aria-expanded="false" aria-controls="mapBody">▸ Show map of stations</button>
  <div id="mapBody" hidden>
    <div class="mapv" id="mapV" role="application" aria-label="Map of stations heard. Drag to pan, pinch or use the buttons to zoom, tap a station for its details.">
      <div class="mtiles" id="mTiles"></div>
      <canvas id="mCan"></canvas>
      <div class="mattr" id="mAttr" hidden></div>
    </div>
    <div class="mctl" role="group" aria-label="Map controls">
      <button type="button" class="btn" id="mOut" aria-label="Zoom out">−</button>
      <button type="button" class="btn" id="mIn" aria-label="Zoom in">+</button>
      <button type="button" class="btn" id="mFit">Fit all</button>
      <button type="button" class="btn" id="mPath" aria-pressed="false">Paths</button>
    </div>
    <div class="mleg" id="mLeg"></div>
    <div class="minfo" id="mInfo" role="status" aria-live="polite"></div>
    <p class="jmsg" id="mMsg"></p>
  </div>
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
      <div class="row2" id="gAuto" role="group" aria-label="RF gain: automatic or set by hand" hidden><button type="button" class="btn" id="gAutoOff">By hand</button><button type="button" class="btn" id="gAutoOn">Auto</button></div>
      <input type="range" id="gain" min="0" max="50" step="0.1">
      <p id="gWhy" class="note" hidden></p></div>
    <div class="sl" id="volSl"><div class="lbl"><label for="vol">uConsole speaker</label><span id="volV" class="val">—</span></div>
      <input type="range" id="vol" min="0" max="1000" step="1"></div>
  </section>
</div>
</fieldset>
<fieldset class="card" id="audioCard" data-v="manual" data-live disabled hidden>
  <div class="lbl"><span>Audio clean-up</span><span id="auState" class="val"></span></div>
  <div class="augrid" role="group" aria-label="Audio clean-up" id="auGrid"></div>
  <p class="note">For the uConsole speaker and the audio on this device. JS8Call and the WSPR decoder always get the audio untouched.</p>
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
  $("ctl").disabled = $("qual").disabled = $("audioCard").disabled = conn !== "ok" || !!switching;
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
  renderGainAudio(s);
  renderBandPlan(s);
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
  if (v === "listen") { home.appendChild($("sqSl")); home.appendChild($("auSl")); }
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
  const key = JSON.stringify([profiles, activeName(), curUp(), conn === "ok", switching && switching.name, view, bandPickKey()]);
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
  if (view === "digital") renderBandPicker(all, mk);
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
  // a mute carries over to the next station, never to JS8: its audio is JS8Call's input
  if (muted() && st.volume > 0 && !feedsDecoder(st)) { store("spkprev", String(st.volume)); tune({volume: 0}, 0); }
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
  '<div class="row2" id="sqBtns"><button type="button" class="btn" id="sqOff">Off</button><button type="button" class="btn" id="sqOn">On</button></div>' +
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
$("sqOff").onclick = () => { tune(sqAutoAvail() ? {squelch: null, audio_squelch: false} : {squelch: null}, 0); if (st) { st.squelch = null; if (sqAutoAvail()) st.audio.squelch = false; } renderQual(); };
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
    sqRenderAuto(on);
    if (on) {} else if (sqAuto()) setText($("sqS"), st.squelch_open ? "● Auto: open (signal)" : "■ Auto: closed (quiet)", st.squelch_open ? "val ok" : "val dimc");
    else if (!on) setText($("sqS"), "Off, always open", "val");
    else if (st.squelch_open) setText($("sqS"), "● Open (signal)", "val ok");
    else setText($("sqS"), "■ Closed (quiet)", "val dimc");
  }
}

// ---------------------------------------------------------------- uConsole speaker mute
function muted() { return load("spkprev") !== null; }
function syncMute() {
  if (muted() && st && st.volume > 0 && !held("volume") && !feedsDecoder(st)) forget("spkprev");
  renderMute();
}
function renderMute() {
  const b = $("mute"), m = muted();
  b.hidden = feedsDecoder(st);
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

// ---------------------------------------------------------------- gain: auto RF gain and audio clean-up
// Auto gain sits in the RF gain block, which moves between Listen and Manual;
// moving the slider sets the gain by hand, which turns auto off in rxd.
// Listen gets one Auto audio switch; Manual a switch per stage.
const AU = [["auto", "Auto audio"], ["nr", "Noise reduction"], ["filter", "Hum filter"],
  ["norm", "Even loudness"], ["limit", "Limiter"], ["squelch", "NFM squelch"]];
const auSl = document.createElement("div");
auSl.className = "sl"; auSl.id = "auSl"; auSl.dataset.v = "listen"; auSl.hidden = true;
auSl.innerHTML = '<div class="lbl"><span>Auto audio</span><span id="auS" class="val">—</span></div>' +
  '<div class="row2" role="group" aria-label="Auto audio"><button type="button" class="btn" id="auOff">Off</button><button type="button" class="btn" id="auOn">On</button></div>' +
  '<p id="auNote" class="note"></p>';
$("qual").appendChild(auSl);
for (const [k, name] of AU) {
  const b = document.createElement("button");
  b.type = "button"; b.className = "btn"; b.dataset.k = k; b.dataset.name = name;
  b.onclick = () => auToggle(k);
  $("auGrid").appendChild(b);
}
function gAuto(s) { return held("gain_auto") && "gain_auto" in pend ? pend.gain_auto : s.gain_auto; }
function setGainAuto(on) { if (!st) return; tune({gain_auto: on}, 0); st.gain_auto = on; renderGainAudio(st); }
$("gAutoOn").onclick = () => setGainAuto(true);
$("gAutoOff").onclick = () => { if (st) { tune({gain_db: st.gain_db}, 0); st.gain_auto = false; renderGainAudio(st); } };
$("auOn").onclick = () => auSet("auto", true);
$("auOff").onclick = () => auSet("auto", false);
function auSet(k, v) {
  if (!st || !st.audio) return;
  const f = {}; f["audio_" + k] = v; tune(f, 0);
  st.audio[k] = v;
  if (k === "nr") { st.audio.nr_setting = v; st.audio.nr = v === null ? st.mode !== "WFM" : v; }
  renderGainAudio(st);
}
function auToggle(k) {
  if (!st || !st.audio) return;
  if (k !== "nr") return auSet(k, !st.audio[k]);
  // noise reduction is on by mode (off for WFM); back to "by mode" when that's what's asked
  const want = !st.audio.nr, byMode = st.mode !== "WFM";
  auSet("nr", want === byMode ? null : want);
}
const AU_WORDS = {nr: "noise reduction", filter: "hum filter", norm: "even loudness", limit: "limiter", squelch: "squelch"};
function gainWhy(s) {
  const g = s.gain_loop || {};
  if (!s.gain_auto) return "Set by hand. Auto picks the gain with the best signal-to-noise without overload.";
  if (g.state === "unavailable") return "✕ " + (g.reason || "No gain control on this source.");
  const state = {settling: "■ Settling", holding: "● Holding", stepped: "● Stepped", "waiting for the gap between slots": "■ Stepping in the next gap between slots"}[g.state] || g.state;
  const m = typeof g.margin_db === "number" ? "; band noise " + Math.round(g.margin_db) + " dB over the ADC's" : "";
  return state + (g.reason ? ": " + g.reason : "") + m + ".";
}
// NFM's squelch row in Listen: Off, Auto (rxd's noise squelch) or a level
const sqAutoB = document.createElement("button");
sqAutoB.type = "button"; sqAutoB.className = "btn"; sqAutoB.id = "sqAuto"; sqAutoB.textContent = "Auto";
$("sqBtns").insertBefore(sqAutoB, $("sqOn"));
sqAutoB.onclick = () => { tune({squelch: null, audio_squelch: true, audio_auto: true}, 0); if (st) { st.squelch = null; Object.assign(st.audio, {squelch: true, auto: true}); } renderQual(); renderGainAudio(st); };
function sqAutoAvail() { return !!(st && st.audio && typeof st.audio.squelch === "boolean"); }
function sqAuto() { return sqAutoAvail() && st.audio.auto && st.audio.squelch && (st.squelch === null || st.squelch === undefined); }
function sqRenderAuto(level) {
  const av = sqAutoAvail(), au = sqAuto() && !level;
  sqAutoB.hidden = !av;
  $("sqBtns").className = av ? "row3" : "row2";
  sqAutoB.setAttribute("aria-pressed", String(au));
  $("sqOff").setAttribute("aria-pressed", String(!level && !au));
  $("sqOn").textContent = av ? "Level" : "On";
}
// A JS8 profile's speaker audio is JS8Call's input (rxd refuses a volume
// under volume_min there), so no speaker volume or mute is offered.
function feedsDecoder(s) { return !!s && (s.volume_min > 0 || pdec(s) === "js8"); }
function renderGainAudio(s) {
  $("volSl").hidden = feedsDecoder(s);
  const has = typeof s.gain_auto === "boolean";
  $("gAuto").hidden = !has;
  if (has) {
    const on = gAuto(s);
    $("gAutoOn").setAttribute("aria-pressed", String(on)); $("gAutoOff").setAttribute("aria-pressed", String(!on));
    $("gAutoOn").textContent = (on ? "● " : "") + "Auto"; $("gAutoOff").textContent = (on ? "" : "● ") + "By hand";
    if (!held("gain_db") && typeof s.gain_db === "number") setText($("gainV"), (on ? "Auto, " : "") + s.gain_db.toFixed(1) + " dB");
    setText($("gWhy"), gainWhy(s)); $("gWhy").hidden = false;
  }
  const jc = $("jGainC");
  jc.hidden = !has;
  if (has && view === "digital") setText($("jGain"), (s.gain_auto ? "Auto " : "Set ") + (typeof s.gain_db === "number" ? s.gain_db.toFixed(1) : "—") + " dB", "v");
  const a = s.audio;
  const hasA = !!a && typeof a.auto === "boolean";
  $("auSl").hidden = !hasA || view !== "listen";
  $("audioCard").hidden = $("audioCard").hidden || !hasA;
  if (!hasA) return;
  const act = Array.isArray(a.active) ? a.active : [];
  const sum = !a.auto ? "Off, untouched" : act.length ? "On: " + act.map(k => AU_WORDS[k]).filter(Boolean).join(", ") : "On, nothing for this mode";
  $("auOn").setAttribute("aria-pressed", String(a.auto)); $("auOff").setAttribute("aria-pressed", String(!a.auto));
  $("auOn").textContent = (a.auto ? "● " : "") + "On"; $("auOff").textContent = (a.auto ? "" : "● ") + "Off";
  setText($("auS"), a.auto ? "On" : "Off", "val");
  setText($("auNote"), sum);
  setText($("auState"), a.auto ? (a.squelch_open === false ? "■ Squelch closed (quiet)" : a.squelch_open ? "● Squelch open (signal)" : "● On") : "Off", "val");
  for (const b of $("auGrid").children) {
    const k = b.dataset.k;
    b.hidden = k === "squelch" && s.mode !== "FM";
    const on = k === "nr" ? a.nr : a[k];
    b.disabled = k !== "auto" && !a.auto;
    b.setAttribute("aria-pressed", String(!!on));
    b.textContent = "";
    b.append((on ? "● " : "○ ") + (k === "filter" && s.mode === "FM" ? "Voice filter" : b.dataset.name));
    const sm = document.createElement("small");
    sm.textContent = (on ? "On" : "Off") + (k === "nr" && a.nr_setting === null ? " (by mode)" : "") +
      (k === "squelch" && on && s.squelch !== null && s.squelch !== undefined ? ", the level squelch is on instead" : "");
    b.appendChild(sm);
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

// ---------------------------------------------------------------- band plan and the band picker
// rxd's band plan (status band_plan, GET/POST /api/bands): Auto picks the JS8
// or WSPR band by conditions, time of day and what rxd has heard; Manual
// stays put. The picker is a mode toggle plus a grid of bands.
const BAND_ORDER = ["2190m", "630m", "160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m", "2m"];
const DWELLS = [2, 4, 6, 8, 10, 15, 20, 30];
const EVERY = [15, 30, 60, 120];
let pickMode = null, bandsDoc = null, bandsAt = -1e9, bandsBusy = false, bpOpen = false;
function bandWord(b) { return b ? b.replace(/m$/, " m") : "—"; }
function bp() { return st && st.band_plan ? st.band_plan : null; }
function bestBand(mode) {
  if (!bandsDoc || !Array.isArray(bandsDoc.profiles)) return null;
  let best = null;
  for (const r of bandsDoc.profiles) if (r.mode === mode && r.eligible && (!best || r.score > best.score)) best = r;
  return best && best.name;
}
function bandPickKey() { const b = bp(); return [pickMode, b && b.plan, b && b.mode, bestBand("js8"), bestBand("wspr")].join(); }
function pickModeNow() { return pickMode || curDec() || (bp() && bp().mode) || "wspr"; }

function bandBtn(p, best) {
  const act = p.name === activeName() && !switching;
  const el = document.createElement(act ? "div" : "button");
  el.className = act ? "bbtn cur" : "btn bbtn";
  const add = (cls, t) => { const s = document.createElement("span"); s.className = cls; s.textContent = t; el.appendChild(s); };
  add("bb", bandWord(p.band));
  add("bf", trim(p.freq / 1e6, 4));
  if (act) add("ba", "● On");
  else {
    el.type = "button";
    if (switching && switching.name === p.name) add("ba", "■ Switching");
    else if (!!p.upconvert !== curUp()) add("bw", "▲ " + hiuWord(p.upconvert));
    else if (best) add("ba", "★ Best now");
    el.setAttribute("aria-label", decName(pdec(p)) + " " + bandWord(p.band) + ", " + fmtMHz(p.freq) + (best ? ", best now" : ""));
    el.disabled = conn !== "ok" || !!switching;
    el.onclick = () => askSwitch(p);
  }
  return el;
}
function renderBandPicker(all, mk) {
  const box = $("jPickL");
  const dig = all.filter(p => pdec(p));
  if (!profiles || !dig.length) { mk("jPickL", dig, null); return; }
  box.textContent = "";
  const mode = pickModeNow();
  const seg = document.createElement("div"); seg.className = "row2"; seg.setAttribute("role", "group"); seg.setAttribute("aria-label", "Mode");
  for (const [d, t] of DECODERS) {
    const b = document.createElement("button");
    b.type = "button"; b.className = "btn"; b.setAttribute("aria-pressed", String(d === mode));
    b.textContent = (d === mode ? "● " : "") + t + (d === curDec() ? " (on now)" : "");
    b.onclick = () => { pickMode = d; pickKey = ""; renderProfiles(); };
    seg.appendChild(b);
  }
  box.appendChild(seg);
  const best = bp() && bp().plan === "auto" && bp().mode === mode ? bestBand(mode) : null;
  const grid = document.createElement("div"); grid.className = "bgrid";
  const plan = dig.filter(p => pdec(p) === mode && p.plan && p.band)
    .sort((a, b) => BAND_ORDER.indexOf(a.band) - BAND_ORDER.indexOf(b.band));
  for (const p of plan) grid.appendChild(bandBtn(p, p.name === best));
  box.appendChild(grid);
  const extra = dig.filter(p => pdec(p) === mode && !(p.plan && p.band));
  if (extra.length) {
    const h = document.createElement("div"); h.className = "pgroup"; h.textContent = "Other " + decName(mode) + " profiles"; box.appendChild(h);
    const l = document.createElement("div"); l.className = "plist"; box.appendChild(l);
    for (const p of extra) l.appendChild(profBtn(p, p.name, (p.description ? p.description + " · " : "") + fmtMHz(p.freq)));
  }
  if (bp() && bp().plan === "auto") {
    const n = document.createElement("p"); n.className = "note";
    n.textContent = "Auto is choosing the band. Picking one here sets the band plan to Manual.";
    box.appendChild(n);
  }
}

function bpMsg(t) { const m = $("bpMsg"); m.textContent = t ? "✕ " + t : ""; m.hidden = !t; }
async function postBands(body) {
  if (bandsBusy) return;
  bandsBusy = true; bpMsg(""); renderBandPlan(st);
  let r = null;
  try { r = await api("/api/bands", body); } catch (e) {}
  bandsBusy = false;
  if (!r) bpMsg("Could not reach rxd. Nothing was changed.");
  else if (!r.ok) bpMsg("rxd refused: " + ((r.doc && r.doc.error) || ("HTTP " + r.status)));
  else if (r.doc) { bandsDoc = r.doc; bandsAt = now(); if (st) st.band_plan = r.doc.status; }
  pickKey = ""; renderBandPlan(st); renderProfiles();
}
async function loadBands() {
  bandsAt = now();
  try {
    const r = await api("/api/bands");
    if (r.ok && r.doc) { bandsDoc = r.doc; pickKey = ""; renderProfiles(); }
  } catch (e) {}
}
function localHM(epoch) { return epoch ? hhmm(new Date(epoch * 1000)) : "—"; }
function pressed(id, on, text) {
  const b = $(id); b.setAttribute("aria-pressed", String(!!on));
  setText(b, (on ? "● " : "") + text);
  b.disabled = conn !== "ok" || bandsBusy;
}
function renderBandPlan(s) {
  const b = s && s.band_plan, card = $("bPlan");
  if (!b) { card.hidden = true; return; }
  if (view === "digital" && !card.hidden && now() - bandsAt > 60000) loadBands();
  const auto = b.plan === "auto";
  const sym = !auto ? "■ " : b.phase === "scan" ? "◔ " : b.phase === "idle" ? "▲ " : "● ";
  setText($("bpState"), auto ? (b.phase === "scan" ? "Auto, scanning" : "Auto") : "Manual");
  setText($("bpWhy"), sym + (b.reason || "—"), "bpwhy" + (b.phase === "idle" ? " warn" : ""));
  const sun = b.sun || {};
  const parts = [];
  if (auto && b.phase === "hold" && b.next_at) parts.push("Next look " + localHM(b.next_at));
  if (auto && b.switching_to && b.switching_to !== b.profile) parts.push("Switching to " + b.switching_to);
  parts.push((sun.words ? sun.words[0].toUpperCase() + sun.words.slice(1) : "—") +
    (sun.sunrise ? " · sunrise " + localHM(sun.sunrise) : "") + (sun.sunset ? " · sunset " + localHM(sun.sunset) : "") +
    (sun.located === false ? " (no grid set: by this clock)" : ""));
  setText($("bpSub"), parts.join(" · "));
  pressed("bpAuto", auto, "Auto"); pressed("bpMan", !auto, "Manual");
  $("bpAutoBox").hidden = !auto;
  pressed("bpWspr", b.mode === "wspr", "WSPR"); pressed("bpJs8", b.mode === "js8", "JS8");
  const c = b.conditions;
  if (c) {
    setText($("bpCond"), "Conditions: SFI " + c.sfi + " · A " + (c.a == null ? "—" : c.a) + " · K " + (c.k == null ? "—" : c.k) +
      (c.fetched ? " · as of " + localHM(c.fetched) : ""));
    const cr = $("bpCred");
    if (c.source === "hamqsl") {
      if (!cr.firstChild || cr.dataset.src !== "hamqsl") {
        cr.textContent = "Band conditions courtesy of N0NBH, ";
        const a = document.createElement("a"); a.href = "https://www.hamqsl.com/solar.html"; a.rel = "noopener"; a.target = "_blank";
        a.textContent = "www.hamqsl.com"; cr.appendChild(a); cr.dataset.src = "hamqsl";
      }
    } else { cr.textContent = c.credit || ""; cr.dataset.src = c.source || ""; }
    cr.hidden = false;
  } else {
    setText($("bpCond"), "▲ No band conditions" + (b.conditions_error ? ": can't reach hamqsl.com or NOAA" : "") +
      ". Auto goes by time of day and what rxd has heard, scanning to learn.");
    $("bpCred").hidden = true;
  }
  $("bpMore").setAttribute("aria-expanded", String(bpOpen));
  setText($("bpMore"), bpOpen ? "Bands and timing ▴" : "Bands and timing ▾");
  $("bpSet").hidden = !bpOpen;
  if (!bpOpen) return;
  // bands
  const box = $("bpBands"), en = b.bands || [];
  const key = JSON.stringify([en, b.side, b.cross_side, conn, bandsBusy]);
  if (box.dataset.key !== key) {
    box.dataset.key = key; box.textContent = "";
    for (const band of BAND_ORDER) {
      const on = en.indexOf(band) >= 0, up = !(band === "6m" || band === "2m");
      const btn = document.createElement("button");
      btn.type = "button"; btn.className = "btn bbtn"; btn.setAttribute("aria-pressed", String(on));
      const t = document.createElement("span"); t.className = "bb"; t.textContent = bandWord(band); btn.appendChild(t);
      const sub = document.createElement("span"); sub.className = "bf"; sub.textContent = on ? "✓ On" : "Off"; btn.appendChild(sub);
      if ((up ? "UPCONVERT" : "BYPASS") !== b.side) {
        const w = document.createElement("span"); w.className = "bw"; w.textContent = "▲ " + (up ? "UPCONVERT" : "BYPASS"); btn.appendChild(w);
      }
      btn.setAttribute("aria-label", bandWord(band) + (on ? ", on" : ", off") + ((up ? "UPCONVERT" : "BYPASS") !== b.side ? ", needs the Ham It Up on " + (up ? "UPCONVERT" : "BYPASS") : ""));
      btn.disabled = conn !== "ok" || bandsBusy;
      btn.onclick = () => postBands({bands: on ? en.filter(x => x !== band) : en.concat([band])});
      box.appendChild(btn);
    }
  }
  $("bpDef").hidden = !!b.default_bands;
  $("bpDef").disabled = conn !== "ok" || bandsBusy;
  pressed("bpSideOff", !b.cross_side, "Stay on this side"); pressed("bpSideOn", b.cross_side, "Allow, I'll flip it");
  setText($("bpDw"), b.dwell_min + " min" + (b.mode === "wspr" ? ", 2 slots at least" : ""));
  const di = DWELLS.indexOf(b.dwell_min);
  $("bpDwDn").disabled = conn !== "ok" || bandsBusy || di === 0;
  $("bpDwUp").disabled = conn !== "ok" || bandsBusy || di === DWELLS.length - 1;
  const ev = $("bpEvery");
  if (!ev.children.length) for (const m of EVERY) {
    const x = document.createElement("button"); x.type = "button"; x.className = "btn"; x.dataset.m = m;
    x.onclick = () => postBands({every_min: m}); ev.appendChild(x);
  }
  for (const x of ev.children) pressed(x.id || (x.id = "bpEv" + x.dataset.m), +x.dataset.m === b.every_min, x.dataset.m + " min");
  $("bpScan").disabled = conn !== "ok" || bandsBusy;
}
$("bpAuto").onclick = () => postBands({plan: "auto"});
$("bpMan").onclick = () => postBands({plan: "manual"});
$("bpWspr").onclick = () => postBands({mode: "wspr"});
$("bpJs8").onclick = () => postBands({mode: "js8"});
$("bpMore").onclick = () => { bpOpen = !bpOpen; renderBandPlan(st); };
$("bpDef").onclick = () => postBands({bands: null});
$("bpSideOff").onclick = () => postBands({cross_side: false});
$("bpSideOn").onclick = () => postBands({cross_side: true});
function stepDwell(d) {
  const b = bp(); if (!b) return;
  let i = DWELLS.indexOf(b.dwell_min); if (i < 0) i = DWELLS.findIndex(x => x >= b.dwell_min);
  const n = DWELLS[Math.max(0, Math.min(DWELLS.length - 1, (i < 0 ? 2 : i) + d))];
  if (n !== b.dwell_min) postBands({dwell_min: n});
}
$("bpDwDn").onclick = () => stepDwell(-1);
$("bpDwUp").onclick = () => stepDwell(1);
$("bpScan").onclick = () => postBands({scan: true});

// ---------------------------------------------------------------- station map (map helper)
// A small pan/zoom map of the stations heard, in the Digital view. Stations
// sit at the centre of their Maidenhead grid square (from /api/stations),
// never anywhere more precise. Tiles are rxd's own offline tiles
// (/tiles/Z/X/Y.png); with none, or past their zoom, Maidenhead grid lines
// still draw. Tiles load only while the map is open.
// map:projection begin
const MTILE = 256;
// Web Mercator, in pixels of a world 256 * 2^z wide.
function mercX(lon, z) { return (lon + 180) / 360 * MTILE * Math.pow(2, z); }
function mercY(lat, z) {
  const s = Math.sin(Math.max(-85.05112878, Math.min(85.05112878, lat)) * Math.PI / 180);
  return (0.5 - Math.log((1 + s) / (1 - s)) / (4 * Math.PI)) * MTILE * Math.pow(2, z);
}
function unmercY(y, z) {
  const n = Math.PI - 2 * Math.PI * y / (MTILE * Math.pow(2, z));
  return Math.atan(Math.sinh(n)) * 180 / Math.PI;
}
// n+1 points along the great circle from a to b, [[lat, lon], ...]
function greatCircle(lat1, lon1, lat2, lon2, n) {
  const r = Math.PI / 180, p1 = lat1 * r, l1 = lon1 * r, p2 = lat2 * r, l2 = lon2 * r;
  const d = 2 * Math.asin(Math.sqrt(Math.pow(Math.sin((p2 - p1) / 2), 2) +
    Math.cos(p1) * Math.cos(p2) * Math.pow(Math.sin((l2 - l1) / 2), 2)));
  const out = [];
  for (let i = 0; i <= n; i++) {
    const f = i / n;
    if (d < 1e-9) { out.push([lat1, lon1]); continue; }
    const A = Math.sin((1 - f) * d) / Math.sin(d), B = Math.sin(f * d) / Math.sin(d);
    const x = A * Math.cos(p1) * Math.cos(l1) + B * Math.cos(p2) * Math.cos(l2);
    const y = A * Math.cos(p1) * Math.sin(l1) + B * Math.cos(p2) * Math.sin(l2);
    const zz = A * Math.sin(p1) + B * Math.sin(p2);
    out.push([Math.atan2(zz, Math.sqrt(x * x + y * y)) / r, Math.atan2(y, x) / r]);
  }
  return out;
}
// map:projection end

const M = {
  open: load("map") === "1", paths: load("mapPaths") === "1",
  doc: null, tiles: null, z: 4, cx: 0.5, cy: 0.5, fitted: false,
  imgs: new Map(), sel: null, timer: 0, raf: 0, col: {}, busy: false
};
const mapV = $("mapV"), mCan = $("mCan"), mTiles = $("mTiles");
const MZMIN = 0, MZMAX = 10;
const MODE = {js8: ["JS8", "●", "js8"], wspr: ["WSPR", "▲", "wspr"]};

function mapShown() { return M.open && !$("mapCard").hidden && !document.hidden; }
function mapColors() {
  const cs = getComputedStyle(document.documentElement);
  for (const k of ["accent", "mark", "fg", "bg", "panel", "dim", "line", "grid", "plot"]) M.col[k] = cs.getPropertyValue("--" + k).trim();
}
function worldW(z) { return MTILE * Math.pow(2, z); }
// a point to screen pixels (CSS px), the copy of it nearest the centre
function toScreen(lat, lon, w, h) {
  const W = worldW(M.z);
  let dx = mercX(lon, M.z) / W - M.cx;
  dx -= Math.round(dx);
  return [w / 2 + dx * W, h / 2 + (mercY(lat, M.z) / W - M.cy) * W];
}
function clampView() {
  M.z = Math.max(MZMIN, Math.min(MZMAX, M.z));
  M.cx -= Math.floor(M.cx);
  const h = mapV.clientHeight / worldW(M.z) / 2;
  M.cy = h >= 0.5 ? 0.5 : Math.max(h, Math.min(1 - h, M.cy));
}
function zoomAt(f, sx, sy) {
  const w = mapV.clientWidth, h = mapV.clientHeight, W0 = worldW(M.z);
  const wx = M.cx + (sx - w / 2) / W0, wy = M.cy + (sy - h / 2) / W0;
  M.z = Math.max(MZMIN, Math.min(MZMAX, M.z + Math.log2(f)));
  const W1 = worldW(M.z);
  M.cx = wx - (sx - w / 2) / W1; M.cy = wy - (sy - h / 2) / W1;
  clampView(); mapDraw();
}
function mapFit() {
  const pts = [];
  const d = M.doc;
  if (d && d.me) pts.push([d.me.lat, d.me.lon]);
  if (d) for (const s of d.stations) if (s.src !== "country") pts.push([s.lat, s.lon]);
  const w = mapV.clientWidth || 360, h = mapV.clientHeight || 400;
  if (pts.length < 2) {
    M.z = pts.length ? 4 : MZMIN;
    M.cx = pts.length ? mercX(pts[0][1], 0) / MTILE : 0.5;
    M.cy = pts.length ? mercY(pts[0][0], 0) / MTILE : 0.5;
  } else {
    // longitudes around the station, so a path across the date line fits
    const ref = pts[0][1];
    const xs = pts.map(p => mercX(ref + ((p[1] - ref + 540) % 360 - 180), 0) / MTILE), ys = pts.map(p => mercY(p[0], 0) / MTILE);
    const x0 = Math.min(...xs), x1 = Math.max(...xs), y0 = Math.min(...ys), y1 = Math.max(...ys);
    const pad = 56;
    const zx = Math.log2((w - 2 * pad) / MTILE / Math.max(x1 - x0, 1e-6));
    const zy = Math.log2((h - 2 * pad) / MTILE / Math.max(y1 - y0, 1e-6));
    M.z = Math.min(zx, zy, 7);
    M.cx = (x0 + x1) / 2; M.cy = (y0 + y1) / 2;
  }
  clampView(); mapDraw();
}

function mapDraw() {
  if (M.raf) return;
  M.raf = requestAnimationFrame(() => { M.raf = 0; drawTiles(); drawOverlay(); });
}
function drawTiles() {
  const t = M.tiles, want = new Set();
  const w = mapV.clientWidth, h = mapV.clientHeight;
  if (t && t.available && w && h) {
    const tz = Math.max(t.min, Math.min(t.max, Math.round(M.z)));
    const n = Math.pow(2, tz), ts = MTILE * Math.pow(2, M.z - tz), W = worldW(M.z);
    const ox = w / 2 - M.cx * W, oy = h / 2 - M.cy * W;  // screen position of the world's corner
    const i0 = Math.floor(-ox / ts), i1 = Math.floor((w - ox) / ts);
    const j0 = Math.max(0, Math.floor(-oy / ts)), j1 = Math.min(n - 1, Math.floor((h - oy) / ts));
    for (let i = i0; i <= i1; i++) {
      for (let j = j0; j <= j1; j++) {
        const x = ((i % n) + n) % n, key = tz + "/" + i + "/" + j;
        want.add(key);
        let img = M.imgs.get(key);
        if (!img) {
          img = new Image();
          img.alt = ""; img.decoding = "async";
          img.onerror = () => { img.style.visibility = "hidden"; };
          img.src = "/tiles/" + tz + "/" + x + "/" + j + ".png";
          M.imgs.set(key, img); mTiles.appendChild(img);
        }
        const l = Math.floor(ox + i * ts), tp = Math.floor(oy + j * ts);
        img.style.left = l + "px"; img.style.top = tp + "px";
        img.style.width = (Math.ceil(ox + (i + 1) * ts) - l) + "px";
        img.style.height = (Math.ceil(oy + (j + 1) * ts) - tp) + "px";
      }
    }
  }
  for (const [k, img] of M.imgs) if (!want.has(k)) { img.remove(); M.imgs.delete(k); }
  const a = $("mAttr");
  a.hidden = !(t && t.available && t.attribution);
  if (!a.hidden) setText(a, t.attribution);
}
function fieldName(lon, lat) {
  return String.fromCharCode(65 + Math.floor((lon + 180) / 20)) + String.fromCharCode(65 + Math.floor((lat + 90) / 10));
}
function drawGrid(g, w, h) {
  const tiles = M.tiles && M.tiles.available;
  const W = worldW(M.z);
  const latTop = unmercY((M.cy - h / 2 / W) * W, M.z), latBot = unmercY((M.cy + h / 2 / W) * W, M.z);
  const lonL = (M.cx - w / 2 / W) * 360 - 180, lonR = (M.cx + w / 2 / W) * 360 - 180;
  const squares = M.z >= 5.5;
  g.lineWidth = 1;
  g.strokeStyle = tiles ? M.col.dim : M.col.line;
  g.globalAlpha = tiles ? 0.35 : 1;
  g.beginPath();
  const dLon = squares ? 2 : 20, dLat = squares ? 1 : 10;
  for (let lon = Math.floor(lonL / dLon) * dLon; lon <= lonR; lon += dLon) {
    const x = Math.round(w / 2 + ((lon + 180) / 360 - M.cx) * W) + 0.5;
    g.moveTo(x, 0); g.lineTo(x, h);
  }
  for (let lat = Math.max(-80, Math.floor(latBot / dLat) * dLat); lat <= Math.min(80, latTop); lat += dLat) {
    const y = Math.round(h / 2 + (mercY(lat, M.z) / W - M.cy) * W) + 0.5;
    g.moveTo(0, y); g.lineTo(w, y);
  }
  g.stroke();
  if (squares) {  // field lines heavier over the squares
    g.lineWidth = 2; g.beginPath();
    for (let lon = Math.floor(lonL / 20) * 20; lon <= lonR; lon += 20) {
      const x = Math.round(w / 2 + ((lon + 180) / 360 - M.cx) * W);
      g.moveTo(x, 0); g.lineTo(x, h);
    }
    for (let lat = Math.max(-80, Math.floor(latBot / 10) * 10); lat <= Math.min(80, latTop); lat += 10) {
      const y = Math.round(h / 2 + (mercY(lat, M.z) / W - M.cy) * W);
      g.moveTo(0, y); g.lineTo(w, y);
    }
    g.stroke();
  }
  // labels: fields, or squares when zoomed in far enough to read them
  g.globalAlpha = tiles ? 0.75 : 1;
  g.fillStyle = M.col.dim;
  g.font = "600 15px system-ui,sans-serif";
  g.textBaseline = "top";
  // only where a cell is wide enough for its name
  if (dLon / 360 * W >= (squares ? 48 : 34)) {
    for (let lon = Math.floor(lonL / dLon) * dLon; lon <= lonR; lon += dLon) {
      for (let lat = Math.max(-90, Math.floor(latBot / dLat) * dLat); lat < Math.min(90, latTop); lat += dLat) {
        const lo = ((lon + 180) % 360 + 360) % 360 - 180;
        const x = w / 2 + ((lon + 180) / 360 - M.cx) * W + 4;
        const y = h / 2 + (mercY(lat + dLat, M.z) / W - M.cy) * W + 3;
        const name = fieldName(lo, lat) + (squares ? Math.floor(((lo + 180) % 20) / 2) + "" + Math.floor((lat + 90) % 10) : "");
        g.fillText(name, x, Math.max(y, 3));
      }
    }
  }
  g.globalAlpha = 1;
}
// where a position came from: the station's own grid, or the callsign database
const SRC = {addr: "Approx. location: licence address, to the grid square", zip: "Approx. location: licence ZIP code",
  country: "Country only, from the callsign prefix"};
function marker(g, mode, x, y, r, src) {
  g.beginPath();
  if (mode === "wspr") { g.moveTo(x, y - r * 1.25); g.lineTo(x + r * 1.15, y + r * 0.8); g.lineTo(x - r * 1.15, y + r * 0.8); g.closePath(); }
  else if (mode === "me") g.rect(x - r, y - r, 2 * r, 2 * r);
  else g.arc(x, y, r, 0, 2 * Math.PI);
  const c = mode === "wspr" ? M.col.mark : mode === "me" ? M.col.fg : M.col.accent;
  if (src && src !== "heard") {  // hollow: not the station's own grid
    g.fillStyle = M.col.panel; g.fill();
    g.lineWidth = 3; g.strokeStyle = c;
    if (src === "country") g.setLineDash([3, 3]);
    g.stroke(); g.setLineDash([]);
    return;
  }
  g.fillStyle = c;
  g.fill();
  g.lineWidth = 2.5; g.strokeStyle = M.col.panel; g.stroke();
}
function drawOverlay() {
  fit(mCan);
  const g = mCan.getContext("2d"), d = dpr(), w = mCan.width / d, h = mCan.height / d;
  g.setTransform(d, 0, 0, d, 0, 0);
  g.clearRect(0, 0, w, h);
  drawGrid(g, w, h);
  const doc = M.doc;
  if (!doc) return;
  const me = doc.me, pts = [];
  if (M.paths && me) {
    g.lineWidth = 2; g.globalAlpha = 0.7;
    for (const s of doc.stations) {
      if (s.src === "country") continue;  // a country's centre isn't a path
      g.strokeStyle = s.mode === "wspr" ? M.col.mark : M.col.accent;
      g.setLineDash(s.mode === "wspr" ? [6, 4] : []);
      g.beginPath();
      let prev = null;
      const gc = greatCircle(me.lat, me.lon, s.lat, s.lon, 48);
      const [mx] = toScreen(me.lat, me.lon, w, h), W = worldW(M.z);
      let base = mx - mercX(me.lon, M.z), lonPrev = me.lon;
      for (const [la, lo] of gc) {
        // keep the line continuous across the date line
        let dl = lo - lonPrev; if (dl > 180) base -= W; else if (dl < -180) base += W;
        lonPrev = lo;
        const x = base + mercX(lo, M.z), y = h / 2 + (mercY(la, M.z) / W - M.cy) * W;
        if (prev) g.lineTo(x, y); else g.moveTo(x, y);
        prev = [x, y];
      }
      g.stroke();
    }
    g.setLineDash([]); g.globalAlpha = 1;
  }
  // oldest first, so the newest draw on top
  const list = doc.stations.slice().reverse();
  for (const s of list) {
    const [x, y] = toScreen(s.lat, s.lon, w, h);
    if (x < -20 || y < -20 || x > w + 20 || y > h + 20) continue;
    marker(g, s.mode, x, y, 8, s.src);
    pts.push([x, y, s]);
  }
  if (me) {
    const [x, y] = toScreen(me.lat, me.lon, w, h);
    marker(g, "me", x, y, 8);
    pts.push([x, y, null]);
  }
  // call labels, newest first, skipping any that would overlap
  g.font = "700 15px system-ui,sans-serif"; g.textBaseline = "middle";
  const boxes = [];
  for (const [x, y, s] of pts.slice().reverse()) {
    const t = s ? s.call : (me.call || "You") + " (you)", tw = g.measureText(t).width;
    const b = [x + 12, y - 9, x + 16 + tw, y + 9];
    if (boxes.some(o => b[0] < o[2] && b[2] > o[0] && b[1] < o[3] && b[3] > o[1])) continue;
    boxes.push(b);
    g.lineWidth = 4; g.strokeStyle = M.col.panel; g.lineJoin = "round"; g.strokeText(t, x + 13, y);
    g.fillStyle = M.col.fg; g.fillText(t, x + 13, y);
  }
  if (M.sel) {
    g.lineWidth = 3; g.strokeStyle = M.col.fg;
    const shown = M.sel.slice(0, 6);  // the ones the details list
    for (const [x, y, s] of pts) if (shown.indexOf(s) >= 0) { g.beginPath(); g.arc(x, y, 15, 0, 2 * Math.PI); g.stroke(); }
  }
  M.pts = pts;
}

function fmtDist(km) { return typeof km === "number" ? Math.round(km * 0.621371).toLocaleString() + " mi · " + km.toLocaleString() + " km" : null; }
function renderInfo() {
  const box = $("mInfo");
  box.textContent = "";
  if (!M.sel || !M.sel.length) { box.textContent = M.doc && M.doc.stations.length ? "Tap a station for its details." : ""; return; }
  for (const s of M.sel.slice(0, 6)) {
    const div = document.createElement("div"); div.className = "mi";
    const add = (cls, t, parent) => { const e = document.createElement("span"); e.className = cls; e.textContent = t; (parent || div).appendChild(e); return e; };
    if (s === null) {
      const me = M.doc.me;
      add("mc", me.call || "This station");
      add("mm mk-me", "■ You");
      add("md", "Grid " + me.grid);
    } else {
      const m = MODE[s.mode] || [s.mode, "●", ""];
      add("mc", s.call);
      add("mm mk-" + m[2], m[1] + " " + m[0]);
      const dist = fmtDist(s.km), approx = s.src && s.src !== "heard";
      if (s.src === "country") add("md", (s.region || "Country") + " · " + SRC.country);
      else add("md", "Grid " + s.grid + (dist ? " · " + (approx ? "about " : "") + dist : ""));
      if (s.src === "addr" || s.src === "zip") add("md", SRC[s.src] + (s.region ? " (" + s.region + ")" : ""));
      add("md", "Last heard " + lineTime(s.last) + (typeof s.last_snr === "number" ? " at " + signed(s.last_snr) + " dB" : ""));
      const extra = [];
      if (typeof s.snr === "number") extra.push("Best SNR " + signed(s.snr) + " dB");
      if (typeof s.dbm === "number") extra.push(fmtPower(s.dbm));
      if (extra.length) add("md", extra.join(" · "));
    }
    box.appendChild(div);
  }
  if (M.sel.length > 6) { const p = document.createElement("div"); p.className = "md"; p.textContent = "and " + (M.sel.length - 6) + " more here: zoom in."; box.appendChild(p); }
}
function mapTap(sx, sy) {
  const hits = (M.pts || []).filter(([x, y]) => Math.hypot(x - sx, y - sy) <= 28);
  M.sel = hits.length ? hits.sort((a, b) => Math.hypot(a[0] - sx, a[1] - sy) - Math.hypot(b[0] - sx, b[1] - sy)).map(p => p[2]) : null;
  renderInfo(); mapDraw();
}
function renderLegend() {
  const doc = M.doc, leg = $("mLeg");
  leg.textContent = "";
  const add = (cls, sym, text) => {
    const e = document.createElement("span");
    const s = document.createElement("span"); s.className = "s " + cls; s.textContent = sym;
    e.append(s, text); leg.appendChild(e);
  };
  if (doc && doc.me) add("mk-me", "■", (doc.me.call || "You") + " · " + doc.me.grid);
  const dec = doc ? doc.decoder : null;
  for (const k of ["js8", "wspr"]) {
    const n = doc ? doc.stations.filter(s => s.mode === k).length : 0;
    if (n || k === dec) add("mk-" + k, MODE[k][1], MODE[k][0] + " · " + n + (n === 1 ? " station" : " stations"));
  }
  const nLook = doc ? doc.stations.filter(s => s.src === "addr" || s.src === "zip").length : 0;
  const nCty = doc ? doc.stations.filter(s => s.src === "country").length : 0;
  if (nLook) add("mk-hollow", "○", "Approx., from licence · " + nLook);
  if (nCty) add("mk-hollow big", "◌", "Country only · " + nCty);
  const msgs = [];
  if (doc) {
    for (const k of ["js8", "wspr"]) {
      const n = doc.no_grid && doc.no_grid[k];
      if (n) msgs.push(n + " " + MODE[k][0] + (n === 1 ? " station" : " stations") + " heard without a grid, not on the map.");
    }
    msgs.unshift("Stations heard in the last " + doc.hours + " hours, at the centre of their grid square." +
      (nLook || nCty ? " Hollow markers are stations that never sent a grid, placed from the offline callsign database; country-only ones aren't counted by Fit all." : ""));
  }
  const t = M.tiles;
  if (t) msgs.push(t.available ? "Map tiles: offline, zoom " + t.min + "–" + t.max + "." : "No map tiles on this rxd: grid lines only.");
  setText($("mMsg"), msgs.join(" "));
}
async function mapPoll() {
  clearTimeout(M.timer);
  if (!M.open) return;
  if (mapShown() && !M.busy) {
    M.busy = true;
    try {
      if (!M.tiles) { const r = await api("/tiles/info.json"); if (r.ok && r.doc) M.tiles = r.doc; else if (r.status === 404) M.tiles = {available: false}; }
      const r = await api("/api/stations");
      if (r.ok && r.doc && Array.isArray(r.doc.stations)) {
        M.doc = r.doc;
        if (M.sel) {  // keep the selection on the same stations
          const keys = new Set(M.sel.map(s => s ? s.mode + s.call : "me"));
          M.sel = (M.doc.me && keys.has("me") ? [null] : []).concat(M.doc.stations.filter(s => keys.has(s.mode + s.call)));
          if (!M.sel.length) M.sel = null;
        }
        if (!M.fitted) { M.fitted = true; mapFit(); }
        renderLegend(); renderInfo(); mapDraw();
      }
    } catch (e) {}
    M.busy = false;
  }
  M.timer = setTimeout(mapPoll, 15000);
}
function renderMapOpen() {
  const b = $("mapTog");
  b.setAttribute("aria-expanded", String(M.open));
  b.textContent = M.open ? "▾ Hide map" : "▸ Show map of stations";
  $("mapBody").hidden = !M.open;
  $("mPath").setAttribute("aria-pressed", String(M.paths));
  $("mPath").textContent = M.paths ? "✓ Paths" : "Paths";
  if (!M.open) { clearTimeout(M.timer); for (const img of M.imgs.values()) img.remove(); M.imgs.clear(); }
}
$("mapTog").onclick = () => {
  M.open = !M.open; store("map", M.open ? "1" : "0");
  renderMapOpen();
  if (M.open) { mapColors(); mapDraw(); mapPoll(); }
};
$("mIn").onclick = () => zoomAt(2, mapV.clientWidth / 2, mapV.clientHeight / 2);
$("mOut").onclick = () => zoomAt(0.5, mapV.clientWidth / 2, mapV.clientHeight / 2);
$("mFit").onclick = mapFit;
$("mPath").onclick = () => { M.paths = !M.paths; store("mapPaths", M.paths ? "1" : "0"); renderMapOpen(); mapDraw(); };

// drag to pan, pinch to zoom, tap to pick; the wheel zooms on a desktop
const mp = new Map();
let mTapAt = null, mPinch = null;
function mRel(e) { const r = mapV.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; }
mapV.addEventListener("pointerdown", e => {
  try { mapV.setPointerCapture(e.pointerId); } catch (err) {}
  mp.set(e.pointerId, mRel(e));
  mTapAt = mp.size === 1 ? mRel(e) : null;
  mPinch = null;
});
mapV.addEventListener("pointermove", e => {
  if (!mp.has(e.pointerId)) return;
  const prev = mp.get(e.pointerId), cur = mRel(e);
  if (mTapAt && Math.hypot(cur[0] - mTapAt[0], cur[1] - mTapAt[1]) > 8) mTapAt = null;
  if (mp.size === 1) {
    const W = worldW(M.z);
    M.cx -= (cur[0] - prev[0]) / W; M.cy -= (cur[1] - prev[1]) / W;
    mp.set(e.pointerId, cur); clampView(); mapDraw();
  } else if (mp.size === 2) {
    mp.set(e.pointerId, cur);
    const [a, b] = [...mp.values()];
    const mid = [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], dist = Math.max(1, Math.hypot(a[0] - b[0], a[1] - b[1]));
    if (mPinch) {
      const W = worldW(M.z);
      M.cx -= (mid[0] - mPinch.mid[0]) / W; M.cy -= (mid[1] - mPinch.mid[1]) / W;
      zoomAt(dist / mPinch.dist, mid[0], mid[1]);
    }
    mPinch = {mid, dist};
  }
});
function mUp(e) {
  if (!mp.has(e.pointerId)) return;
  mp.delete(e.pointerId);
  if (mTapAt && e.type === "pointerup") mapTap(mTapAt[0], mTapAt[1]);
  mTapAt = null; mPinch = null;
}
mapV.addEventListener("pointerup", mUp);
mapV.addEventListener("pointercancel", mUp);
mapV.addEventListener("wheel", e => {
  e.preventDefault();
  const [x, y] = mRel(e);
  zoomAt(Math.pow(2, -e.deltaY / (e.deltaMode ? 3 : 300)), x, y);
}, {passive: false});
mapV.addEventListener("dblclick", e => { const [x, y] = mRel(e); zoomAt(2, x, y); });

// redraw for a new size (the card shown again, a rotation) or appearance
if (window.ResizeObserver) new ResizeObserver(() => { if (M.open && mapV.clientWidth) { clampView(); mapDraw(); mapPoll(); } }).observe(mapV);
new MutationObserver(() => { mapColors(); if (M.open) mapDraw(); }).observe(document.documentElement, {attributes: true, attributeFilter: ["data-theme"]});
window.matchMedia("(prefers-color-scheme: dark)").addEventListener?.("change", () => { mapColors(); if (M.open) mapDraw(); });
document.addEventListener("visibilitychange", () => { if (!document.hidden && M.open) mapPoll(); });
mapColors(); renderMapOpen(); renderInfo();
if (M.open) mapPoll();

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

    # rxd's own JS8 decoder, which a JS8 profile with "js8_engine": "rxd"
    # uses instead of the JS8Call desktop app. rxd loads it from here.
    write_file /usr/local/lib/rxd/js8.py 0644 <<'RXDJS8'
#!/usr/bin/env python3
"""js8: rxd's own JS8 receiver, so a JS8 profile needs no JS8Call.

Receive only. It takes slots of 12 kHz audio, finds JS8 signals in them and
turns them into the frames and messages JS8Call shows:

  candidates    a spectrogram one symbol long, a quarter symbol apart, scored
                against the three 7x7 Costas arrays every JS8 signal carries
  refinement    each candidate is cut out of one FFT of the whole slot, mixed
                to baseband at 24 samples a symbol, then timed to 1/24 symbol
                and tuned to 1/16 of a tone against the Costas arrays
  soft symbols  58 data symbols x 8 tones -> 174 bit log-likelihoods
  LDPC(174,87)  belief propagation, all candidates at once, then CRC-12
  subtraction   decoded signals are rebuilt and taken out of the slot, and
                the slot is searched again for what they were hiding
  frames        72 bits -> heartbeat, CQ, compound callsign, directed command
                or data frame -> text, then frames are joined into messages

Run as a script it serves decodes for rxd over a pipe (--serve), decodes WAV
files (--wav), or reports what it is (--version). See rxd/README.md for the
protocol sources and their licences: no JS8Call or WSJT-X code is used here.
"""
import json
import os
import struct
import sys
import time

for _var in ("OPENBLAS_NUM_THREADS", "OMP_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_var, "1")

import numpy as np  # noqa: E402
from scipy import fft as sfft  # noqa: E402
from scipy import ndimage  # noqa: E402
from scipy import special  # noqa: E402

VERSION = "rxd-js8-1"
RATE = 12000

# ------------------------------------------------------------ the waveform

# 79 symbols: Costas A, 29 parity symbols, Costas B, 29 message symbols,
# Costas C. Each symbol is one of 8 tones, a tone apart; the tone is the
# 3-bit word itself (no Gray code). Normal mode uses one Costas array three
# times; the faster and slower modes use three different ones, which is how
# a Normal decoder ignores them.
COSTAS_ORIGINAL = ((4, 2, 5, 6, 1, 3, 0),) * 3
COSTAS_MODIFIED = ((0, 6, 2, 3, 5, 4, 1), (1, 5, 0, 2, 3, 6, 4), (2, 5, 0, 6, 4, 1, 3))
NSYM = 79
SYNC_AT = (0, 36, 72)
DATA_AT = tuple(range(7, 36)) + tuple(range(43, 72))


class Submode:
    """One JS8 speed: samples per symbol at 12 kHz, the slot, and when in the
    slot a transmission starts."""

    def __init__(self, name, letter, sps, slot, delay, costas, snr_floor):
        self.name, self.letter, self.sps, self.slot = name, letter, sps, slot
        self.delay, self.costas, self.snr_floor = delay, costas, snr_floor
        self.baud = RATE / sps
        self.duration = NSYM * sps / RATE
        # Audio kept either side of the slot, so a signal up to 2.5 s early or
        # late (a station's clock, or the audio path) is still whole.
        self.pre = min(2.0, slot * 0.15)
        self.post = 0.5 if slot >= 10 else 0.25

    def __repr__(self):
        return "Submode(%s)" % self.name


SUBMODES = {
    "normal": Submode("normal", "A", 1920, 15, 0.5, COSTAS_ORIGINAL, -24),
    "fast": Submode("fast", "B", 1200, 10, 0.2, COSTAS_MODIFIED, -22),
    "turbo": Submode("turbo", "C", 600, 6, 0.1, COSTAS_MODIFIED, -20),
    "slow": Submode("slow", "E", 3840, 30, 0.5, COSTAS_MODIFIED, -28),
}
BY_LETTER = {m.letter: m for m in SUBMODES.values()}

# ------------------------------------------------------------- the code

# The (174,87) LDPC code's generator, one row per parity bit, 87 message bits
# each, MSB first (hex), and the order its 174 bits go on the air. Both are
# FT8 v1's, as published in Karlis Goba's MIT-licensed ft8_lib (2018): the
# 87 parity bits and then the 87 message bits, the bit at i sent at
# COLORDER[i].
GEN = (
    "23bba830e23b6b6f50982e", "1f8e55da218c5df3309052", "ca7b3217cd92bd59a5ae20", "56f78313537d0f4382964e",
    "29c29dba9c545e267762fe", "6be396b5e2e819e373340c", "293548a138858328af4210", "cb6c6afcdc28bb3f7c6e86",
    "3f2a86f5c5bd225c961150", "849dd2d63673481860f62c", "56cdaec6e7ae14b43feeee", "04ef5cfa3766ba778f45a4",
    "c525ae4bd4f627320a3974", "fe37802941d66dde02b99c", "41fd9520b2e4abeb2f989c", "40907b01280f03c0323946",
    "7fb36c24085a34d8c1dbc4", "40fc3e44bb7d2bb2756e44", "d38ab0a1d2e52a8ec3bc76", "3d0f929ef3949bd84d4734",
    "45d3814f504064f80549ae", "f14dbf263825d0bd04b05e", "f08a91fb2e1f78290619a8", "7a8dec79a51e8ac5388022",
    "ca4186dd44c3121565cf5c", "db714f8f64e8ac7af1a76e", "8d0274de71e7c1a8055eb0", "51f81573dd4049b082de14",
    "d037db825175d851f3af00", "d8f937f31822e57c562370", "1bf1490607c54032660ede", "1616d78018d0b4745ca0f2",
    "a9fa8e50bcb032c85e3304", "83f640f1a48a8ebc0443ea", "eca9afa0f6b01d92305edc", "3776af54ccfbae916afde6",
    "6abb212d9739dfc02580f2", "05209a0abb530b9e7e34b0", "612f63acc025b6ab476f7c", "0af7723161ec223080be86",
    "a8fc906976c35669e79ce0", "45b7ab6242b77474d9f11a", "b274db8abd3c6f396ea356", "9059dfa2bb20ef7ef73ad4",
    "3d188ea477f6fa41317a4e", "8d9071b7e7a6a2eed6965e", "a377253773ea678367c3f6", "ecbd7c73b9cd34c3720c8a",
    "b6537f417e61d1a7085336", "6c280d2a0523d9c4bc5946", "d36d662a69ae24b74dcbd8", "d747bfc5fd65ef70fbd9bc",
    "a9fa2eefa6f8796a355772", "cc9da55fe046d0cb3a770c", "f6ad4824b87c80ebfce466", "cc6de59755420925f90ed2",
    "164cc861bdd803c547f2ac", "c0fc3ec4fb7d2bb2756644", "0dbd816fba1543f721dc72", "a0c0033a52ab6299802fd2",
    "bf4f56e073271f6ab4bf80", "57da6d13cb96a7689b2790", "81cfc6f18c35b1e1f17114", "481a2a0df8a23583f82d6c",
    "1ac4672b549cd6dba79bcc", "c87af9a5d5206abca532a8", "97d4169cb33e7435718d90", "a6573f3dc8b16c9d19f746",
    "2c4142bf42b01e71076acc", "081c29a10d468ccdbcecb6", "5b0f7742bca86b8012609a", "012dee2198eba82b19a1da",
    "f1627701a2d692fd9449e6", "35ad3fb0faeb5f1b0c30dc", "b1ca4ea2e3d173bad4379c", "37d8e0af9258b9e8c5f9b2",
    "cd921fdf59e882683763f6", "6114e08483043fd3f38a8a", "2e547dd7a05f6597aac516", "95e45ecd0135aca9d6e6ae",
    "b33ec97be83ce413f9acc8", "c8b5dffc335095dcdcaf2a", "3dd01a59d86310743ec752", "14cd0f642fc0c5fe3a65ca",
    "3a0a1dfd7eee29c2e827e0", "8abdb889efbe39a510a118", "3f231f212055371cf3e2a2",
)
COLORDER = (
    0, 1, 2, 3, 30, 4, 5, 6, 7, 8, 9, 10, 11, 32, 12, 40, 13, 14, 15, 16, 17, 18, 37, 45, 29, 19,
    20, 21, 41, 22, 42, 31, 33, 34, 44, 35, 47, 51, 50, 43, 36, 52, 63, 46, 25, 55, 27, 24, 23, 53,
    39, 49, 59, 38, 48, 61, 60, 57, 28, 62, 56, 58, 65, 66, 26, 70, 64, 69, 68, 67, 74, 71, 54, 76,
    72, 75, 78, 77, 80, 79, 73, 83, 84, 81, 82, 85, 86, 87, 88, 89, 90, 91, 92, 93, 94, 95, 96, 97,
    98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116,
    117, 118, 119, 120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135,
    136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154,
    155, 156, 157, 158, 159, 160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173,
)

# The sparse parity checks: each row lists the codeword bits (in GEN's order,
# parity then message) that sum to zero. They are not copied from anywhere: they were derived
# from GEN alone, as the 87 lowest-weight words of the code's dual (weights
# 5 to 7, each bit in exactly 3 checks), found by information-set search.
# test_js8 checks every row against GEN.
NM = (
    (12, 45, 81, 87, 138), (5, 39, 77, 108, 140), (5, 41, 78, 104, 139), (46, 54, 61, 93, 136),
    (12, 50, 56, 100, 127, 144), (25, 50, 69, 116, 140, 159), (41, 58, 63, 98, 141, 172),
    (30, 56, 58, 115, 131, 161), (4, 46, 85, 99, 116, 170), (10, 23, 68, 102, 135, 164),
    (14, 45, 55, 110, 145, 170), (43, 58, 79, 91, 145, 171), (2, 36, 59, 106, 123, 166),
    (2, 49, 67, 100, 139, 169), (16, 53, 80, 98, 129, 157), (9, 51, 61, 92, 127, 163),
    (44, 65, 72, 92, 141, 166), (11, 53, 65, 99, 125, 154), (19, 55, 72, 115, 124, 153),
    (7, 33, 63, 95, 119, 151), (7, 72, 84, 100, 130, 167), (47, 50, 82, 93, 123, 158),
    (11, 36, 78, 88, 145, 168), (3, 13, 59, 91, 120, 148), (1, 59, 60, 102, 137, 156),
    (10, 22, 67, 98, 126, 153), (9, 49, 81, 89, 140, 168), (1, 4, 56, 89, 118, 146),
    (1, 32, 42, 92, 121, 149), (27, 49, 82, 109, 135, 160), (37, 46, 67, 103, 131, 143),
    (11, 37, 62, 87, 118, 147), (48, 51, 77, 105, 142, 148), (18, 30, 65, 102, 117, 159),
    (14, 28, 74, 89, 128, 155), (20, 54, 80, 96, 114, 166), (20, 34, 52, 95, 131, 160),
    (43, 64, 85, 97, 133, 152), (32, 64, 80, 105, 130, 164), (3, 38, 75, 114, 126, 167),
    (26, 41, 81, 112, 137, 167), (25, 34, 75, 111, 139, 156), (2, 31, 55, 90, 119, 147),
    (20, 28, 79, 108, 138, 153), (15, 26, 76, 106, 136, 164), (19, 39, 75, 97, 129, 155),
    (0, 31, 73, 104, 135, 163), (0, 24, 52, 88, 117, 146), (40, 44, 79, 104, 143, 150),
    (29, 54, 78, 109, 134, 165), (6, 31, 86, 103, 144, 168), (29, 33, 70, 112, 144, 152),
    (38, 47, 76, 88, 121, 157), (4, 19, 83, 112, 120, 160), (8, 37, 84, 110, 117, 165),
    (21, 23, 74, 84, 132, 161), (6, 32, 62, 94, 123, 150), (27, 28, 62, 107, 137, 151),
    (26, 35, 42, 91, 129, 158), (6, 38, 63, 110, 133, 154), (17, 30, 70, 101, 130, 158),
    (17, 57, 87, 111, 120, 163), (10, 13, 52, 94, 127, 155), (18, 51, 83, 90, 128, 157),
    (18, 34, 86, 113, 124, 171), (0, 35, 83, 107, 126, 173), (8, 35, 69, 96, 124, 152),
    (7, 24, 71, 109, 142, 150), (9, 40, 68, 97, 125, 151), (25, 36, 74, 105, 122, 162),
    (17, 24, 85, 114, 122, 149), (33, 48, 73, 99, 121, 161), (23, 29, 42, 90, 143, 172),
    (48, 60, 69, 94, 136, 141), (12, 22, 73, 101, 133, 162), (8, 40, 66, 101, 128, 169),
    (14, 15, 71, 96, 125, 156), (5, 13, 66, 93, 122, 147), (16, 57, 60, 108, 119, 165),
    (47, 57, 68, 115, 142, 173), (22, 44, 76, 111, 134, 170), (21, 53, 82, 113, 138, 149),
    (21, 43, 77, 103, 134, 146), (15, 16, 86, 107, 116, 148, 169),
    (27, 39, 70, 106, 132, 154, 171), (45, 64, 66, 95, 132, 159, 173),
    (3, 61, 71, 113, 118, 162, 172),
)

ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-+"
ALPHABET_INDEX = {c: i for i, c in enumerate(ALPHABET)}
CRC_POLY = 0xC06   # CRC-12, x^12 + x^11 + x^10 + x^2 + x (the x^12 implied)
CRC_XOR = 42       # JS8's CRC differs from FT8 v1's by this constant

_GEN = np.array([[(int(r, 16) >> (87 - j)) & 1 for j in range(87)] for r in GEN], np.uint8)
_NMAX = max(len(r) for r in NM)
# Check -> its bits, padded with 174, a dummy bit that is always 0.
_CV = np.array([list(r) + [174] * (_NMAX - len(r)) for r in NM], np.intp)
_REAL = _CV < 174
# Bit -> the flat positions of its three edges in _CV.
_VE = np.zeros((174, 3), np.intp)
_fill = np.zeros(174, np.intp)
for _e, _v in enumerate(_CV.ravel()):
    if _v < 174:
        _VE[_v, _fill[_v]] = _e
        _fill[_v] += 1
assert (_fill == 3).all()
del _e, _v, _fill


def crc12(bits75):
    """JS8's CRC of the 72 payload bits and 3 frame bits: an augmented CRC-12
    over them and 13 zero bits (the CRC's place, rounded up to 11 bytes)."""
    reg = 0
    for b in list(bits75) + [0] * 13:
        top = reg >> 11
        reg = ((reg << 1) & 0xFFF) | int(b)
        if top:
            reg ^= CRC_POLY
    return reg ^ CRC_XOR


def frame_bits(frame, i3):
    """12 characters and the 3 transmission bits -> the 87 message bits."""
    if len(frame) != 12 or any(c not in ALPHABET_INDEX for c in frame):
        raise ValueError("a frame is 12 characters of %s" % ALPHABET)
    v = 0
    for c in frame:
        v = (v << 6) | ALPHABET_INDEX[c]
    bits = [(v >> (71 - i)) & 1 for i in range(72)] + [(i3 >> (2 - i)) & 1 for i in range(3)]
    crc = crc12(bits)
    return bits + [(crc >> (11 - i)) & 1 for i in range(12)]


def bits_frame(bits87):
    """The 87 decoded message bits -> (frame, i3), or None if the CRC fails."""
    b = [int(x) for x in bits87]
    crc = 0
    for x in b[75:87]:
        crc = (crc << 1) | x
    if crc12(b[:75]) != crc:
        return None
    v = 0
    for x in b[:72]:
        v = (v << 1) | x
    frame = "".join(ALPHABET[(v >> (66 - 6 * i)) & 63] for i in range(12))
    return frame, (b[72] << 2) | (b[73] << 1) | b[74]


_COLORDER = np.array(COLORDER, np.intp)


def encode(frame, i3):
    """The 174-bit codeword: 87 parity bits, then the 87 message bits."""
    m = np.array(frame_bits(frame, i3), np.uint8)
    return np.concatenate([(_GEN.astype(np.int32) @ m) % 2, m]).astype(np.uint8)


def to_air(cw):
    """A codeword (or its bits' likelihoods) in the order sent, and back."""
    out = np.empty_like(cw)
    out[..., _COLORDER] = cw
    return out


def from_air(bits):
    return bits[..., _COLORDER]


def tones(frame, i3, submode="normal"):
    """The 79 tones (0-7) a transmitter sends for one frame."""
    m = SUBMODES[submode] if isinstance(submode, str) else submode
    cw = to_air(encode(frame, i3))
    words = cw[0::3] * 4 + cw[1::3] * 2 + cw[2::3]
    out = np.zeros(NSYM, np.int8)
    for a, at in enumerate(SYNC_AT):
        out[at:at + 7] = m.costas[a]
    out[list(DATA_AT)] = words
    return out


def synth(tone_seq, f0, submode="normal", amp=1.0, phase=0.0):
    """Phase-continuous 8-FSK audio at 12 kHz: tone 0 at f0 Hz (for tests)."""
    m = SUBMODES[submode] if isinstance(submode, str) else submode
    f = f0 + np.repeat(np.asarray(tone_seq, float), m.sps) * m.baud
    ph = phase + 2 * np.pi * np.cumsum(f) / RATE
    return (amp * np.sin(ph)).astype(np.float32)


def check_parity(cw):
    c = np.append(np.asarray(cw, np.uint8), 0)
    return not (c[_CV].sum(1) % 2).any()


def bp_decode(llr, iters=30, patience=8):
    """Belief propagation on a batch: llr (B, 174), positive meaning 1.
    A row is dropped once its count of failed checks hasn't improved for
    patience iterations (it is noise, or too weak). Returns (bits (B, 174)
    uint8, ok (B,) bool, iterations used (B,))."""
    llr = np.atleast_2d(np.asarray(llr, np.float64))
    nb = llr.shape[0]
    out = (llr > 0).astype(np.uint8)
    done = np.zeros(nb, bool)
    used = np.full(nb, iters, np.int32)
    rows = np.arange(nb)
    L = np.concatenate([-llr, np.full((nb, 1), 50.0)], 1)  # log P(0)/P(1)
    r = np.zeros((nb, _CV.size))
    best = np.full(nb, 999)
    since = np.zeros(nb, np.int32)
    flat = _CV.ravel()
    pad = ~_REAL.ravel()
    for it in range(iters + 1):
        tot = L.copy()
        tot[:, :174] += r[:, _VE].sum(2)
        hard = np.concatenate([(tot[:, :174] < 0), np.zeros((len(rows), 1), bool)], 1)
        nbad = (hard[:, _CV].sum(2) % 2).sum(1)
        good = nbad == 0
        if good.any():
            out[rows[good]] = hard[good, :174]
            used[rows[good]] = it
            done[rows[good]] = True
        better = nbad < best
        since = np.where(better, 0, since + 1)
        best = np.minimum(best, nbad)
        keep = ~good & (since < patience)
        if it == iters or not keep.any():
            break
        if not keep.all():
            rows, L, r, tot, best, since = rows[keep], L[keep], r[keep], tot[keep], best[keep], since[keep]
        q = tot[:, flat] - r
        t = np.tanh(np.clip(q, -40, 40) / 2).reshape(len(rows), _CV.shape[0], _NMAX)
        t = np.where(np.abs(t) < 1e-12, 1e-12, t)
        sgn = np.sign(t)
        la = np.log(np.abs(t))
        ex = sgn.prod(2, keepdims=True) * sgn * np.exp(la.sum(2, keepdims=True) - la)
        r = (2 * np.arctanh(np.clip(ex, -0.999999, 0.999999))).reshape(len(rows), -1)
        r[:, pad] = 0
    return out, done, used

_GFULL = np.concatenate([_GEN.T, np.eye(87, dtype=np.uint8)], 1)   # message bit -> codeword
_PAIRS = np.array([(i, j) for i in range(87) for j in range(i + 1, 87)], np.intp)


def osd_decode(llr, order=2):
    """Ordered-statistics decoding (Fossorier and Lin): take the 87 most
    reliable independent bits as given, re-encode, and try flipping one or two
    of them. Returns (codeword, discrepancy): the sum of |llr| over the bits
    where the codeword disagrees with the received hard decisions."""
    llr = np.asarray(llr, np.float64)
    hard = (llr > 0).astype(np.uint8)
    rel = np.abs(llr)
    perm = np.argsort(-rel, kind="stable")
    G = _GFULL[:, perm].copy()
    piv = []
    r = 0
    for col in range(174):
        nz = np.nonzero(G[r:, col])[0]
        if len(nz) == 0:
            continue
        p = r + nz[0]
        if p != r:
            G[[r, p]] = G[[p, r]]
        mask = G[:, col].astype(bool)
        mask[r] = False
        G[mask] ^= G[r]
        piv.append(col)
        r += 1
        if r == 87:
            break
    hp, rp = hard[perm], rel[perm]
    info = hp[piv]
    c0 = (info.astype(np.int32) @ G) % 2
    c0 = c0.astype(np.uint8)
    cands = [c0[None]]
    if order >= 1:
        cands.append(c0[None] ^ G)
    if order >= 2:
        cands.append(c0[None] ^ G[_PAIRS[:, 0]] ^ G[_PAIRS[:, 1]])
    C = np.concatenate(cands)
    dis = (C != hp[None]).astype(np.float32) @ rp.astype(np.float32)
    best = int(np.argmin(dis))
    cw = np.empty(174, np.uint8)
    cw[perm] = C[best]
    return cw, float(dis[best])


# ------------------------------------------------------------ the decoder

class Decoder:
    """Decodes one submode's slots. decode(x, t0) takes 12 kHz audio whose
    first sample is t0 seconds from the slot's start (negative: before it)."""

    SPS_DS = 24          # baseband samples per symbol
    LLR_MAX = 6.0
    # Ordered-statistics decoding is slow (tens of ms a candidate on a CM4),
    # so it gets only the strongest few candidates belief propagation failed
    # on, and a result only counts if it disagrees with what was received
    # on little of the total confidence (true decodes ~0.04, noise >0.06).
    OSD_SYNC, OSD_MAX, OSD_DISCREPANCY = 4.0, 6, 0.045
    DT_MAX = {"normal": 2.5, "fast": 2.0, "turbo": 1.0, "slow": 3.0}

    def __init__(self, submode="normal", fmin=200.0, fmax=3000.0, max_candidates=None,
                 sync_min=1.25, passes=2, iters=30):
        self.m = SUBMODES[submode] if isinstance(submode, str) else submode
        self.fmin, self.fmax = fmin, fmax
        self.max_candidates = max_candidates or 120
        self.sync_min, self.passes, self.iters = sync_min, passes, iters
        self.dt_max = self.DT_MAX[self.m.name]
        self.D = self.m.sps // self.SPS_DS
        c = self.m.costas
        self.sync_pos = np.array([at + i for at in SYNC_AT for i in range(7)])
        self.sync_tone = np.array([c[a][i] for a in range(3) for i in range(7)])
        self.ones = [[t for t in range(8) if (t >> (2 - b)) & 1] for b in range(3)]
        self.zeros = [[t for t in range(8) if not (t >> (2 - b)) & 1] for b in range(3)]
        # Each Costas symbol's tone, shifted by -4/16 .. +4/16 of a tone.
        self._shifts = self.m.baud * np.arange(-4, 5) / 16
        n = np.arange(self.SPS_DS)
        frac = self.sync_tone[:, None] + np.arange(-4, 5)[None, :] / 16
        self._ref = np.exp(-2j * np.pi * frac[:, :, None] * n / self.SPS_DS).astype(np.complex64)

    def window(self):
        """(before, after): seconds of audio decode() wants either side of the
        slot, so every start time it searches is whole."""
        m = self.m
        before = max(0.0, self.dt_max - m.delay) + 0.1
        after = max(0.0, m.delay + self.dt_max + m.duration - m.slot) + 0.1
        return before, after

    # ---------------------------------------------------------- stage 1
    def candidates(self, x, t0):
        m = self.m
        sps, hop = m.sps, m.sps // 4
        nfr = (len(x) - sps) // hop + 1
        if nfr < 4 * NSYM:
            return []
        frames = np.lib.stride_tricks.as_strided(
            x, shape=(nfr, sps), strides=(hop * x.strides[0], x.strides[0]), writeable=False)
        bw = m.baud / 2
        k0 = max(1, int(self.fmin / bw))
        k1 = int(self.fmax / bw) + 1
        spec = sfft.rfft(frames, n=2 * sps, axis=1, workers=1)[:, k0:k1 + 16]
        P = (spec.real ** 2 + spec.imag ** 2).astype(np.float32)
        nf = P.shape[1] - 16
        # Start frames whose dt (start - nominal delay) is within +-dt_max.
        lo = int(np.ceil((m.delay - self.dt_max - t0) * RATE / hop))
        hi = int(np.floor((m.delay + self.dt_max - t0) * RATE / hop))
        lo = max(lo, 0)
        hi = min(hi, nfr - 1 - 4 * 78)
        if hi < lo:
            return []
        nt = hi - lo + 1
        ta = np.zeros((3, nt, nf), np.float32)
        tt = np.zeros((3, nt, nf), np.float32)
        for a in range(3):
            for i in range(7):
                row = lo + 4 * (SYNC_AT[a] + i)
                blk = P[row:row + nt]
                ta[a] += blk[:, 2 * self.sync_tone[7 * a + i]:][:, :nf]
                for k in range(8):
                    tt[a] += blk[:, 2 * k:2 * k + nf]
        eps = 1e-12

        def ratio(sel):
            s, t = ta[sel].sum(0), tt[sel].sum(0)
            return s / ((t - s) / 7 + eps)

        score = np.maximum(ratio([0, 1, 2]), np.maximum(ratio([0, 1]), ratio([1, 2])))
        peak = ndimage.maximum_filter(score, size=(9, 3), mode="nearest")
        ti, fi = np.nonzero((score == peak) & (score >= self.sync_min))
        order = np.argsort(-score[ti, fi])[: self.max_candidates]
        out = []
        for j in order:
            out.append({"start": (lo + ti[j]) * hop, "freq": (k0 + fi[j]) * bw,
                        "sync": float(score[ti[j], fi[j]])})
        return out

    # ---------------------------------------------------------- stage 2
    def baseband(self, X, N, f):
        """The slot at 24 samples a symbol, tone 0 of a signal at f near 0 Hz."""
        M = N // self.D
        df = RATE / N
        kc = int(round(f / df))
        k = np.arange(-(M // 2), M - M // 2)
        idx = kc + k
        ok = (idx >= 0) & (idx < len(X))
        Y = np.zeros(M, np.complex64)
        Y[k[ok] % M] = X[idx[ok]]
        # Flat over the eight tones, rolled off beyond them.
        b = self.m.baud
        fk = k * df
        w = np.ones(M, np.float32)
        lo, hi = -1.5 * b, 8.5 * b
        w[fk < lo] = np.cos(np.clip((lo - fk[fk < lo]) / (2 * b), 0, 1) * np.pi / 2) ** 2
        w[fk > hi] = np.cos(np.clip((fk[fk > hi] - hi) / (2 * b), 0, 1) * np.pi / 2) ** 2
        Y *= w[k % M]
        return sfft.ifft(Y, workers=1).astype(np.complex64), kc * df

    def refine(self, y, start):
        """Best (start sample at 24/symbol, frequency shift in Hz) near start:
        the Costas symbols' power, a symbol at a time, against each of the
        sync tones shifted by up to a quarter tone either way."""
        S = self.SPS_DS
        n0 = int(round(start / self.D))
        offs = np.arange(n0 - 8, n0 + 9)
        pad = 8 * S
        yp = np.concatenate([np.zeros(pad, y.dtype), y, np.zeros(NSYM * S + pad, y.dtype)])
        idx = (offs[:, None, None] + S * self.sync_pos[None, :, None] + np.arange(S)) + pad
        z = yp[idx]                                     # (offsets, 21, S)
        pw = np.abs(np.einsum("oin,idn->oid", z, self._ref)) ** 2
        s = pw.sum(1)                                   # (offsets, shifts)
        o, k = np.unravel_index(int(np.argmax(s)), s.shape)
        return int(offs[o]), float(self._shifts[k])

    def symbols(self, y, n, df):
        S = self.SPS_DS
        rate = self.m.baud * S
        pad = 2 * NSYM * S
        yp = np.concatenate([np.zeros(pad, y.dtype), y, np.zeros(pad, y.dtype)])
        idx = n + pad + S * np.arange(NSYM)[:, None] + np.arange(S)
        rot = np.exp(-2j * np.pi * df * (idx - pad) / rate).astype(np.complex64)
        return sfft.fft(yp[idx] * rot, axis=1, workers=1)[:, :8]

    def soft(self, Sy):
        """Bit log-likelihoods for non-coherent 8-FSK: each tone's Rician
        likelihood from the estimated signal and noise, summed over the tones
        whose word has the bit set, against those where it is clear."""
        P = np.abs(Sy[list(DATA_AT)]) ** 2
        n0 = float(np.median(np.sort(P, 1)[:, :7])) / np.log(2)
        if n0 <= 0:
            return np.zeros(174)
        es = max(float(P.max(1).mean()) - n0, 0.05 * n0)
        z = 2 * np.sqrt(es * P) / n0
        lt = np.log(special.i0e(z)) + z
        out = np.empty((58, 3))
        for b in range(3):
            out[:, b] = np.logaddexp.reduce(lt[:, self.ones[b]], 1) - \
                np.logaddexp.reduce(lt[:, self.zeros[b]], 1)
        return out.ravel()

    # ---------------------------------------------------------- the slot
    def decode(self, x, t0=0.0):
        x = np.ascontiguousarray(x, np.float32)
        m = self.m
        found, seen = [], set()
        for _ in range(self.passes):
            new = self._pass(x, t0, seen)
            if not new:
                break
            found += new
            x = x.copy()
            for d in new:
                self.subtract(x, d)
        return found

    def _pass(self, x, t0, seen):
        cands = self.candidates(x, t0)
        if not cands:
            return []
        N = self.D * sfft.next_fast_len(-(-len(x) // self.D))
        X = sfft.rfft(x, n=N, workers=1)
        rows, info = [], []
        for c in cands:
            y, fc = self.baseband(X, N, c["freq"])
            n, df = self.refine(y, c["start"])
            Sy = self.symbols(y, n, df)
            rows.append(from_air(self.soft(Sy)))
            info.append((c, n, fc + df, Sy))
        rows = np.array(rows)
        bits, ok, used = bp_decode(rows, self.iters)
        # A strong signal gives each bit so much confidence that one symbol
        # hit by a fade or a burst of QRM can't be overruled (seen off the
        # air at +4 dB): try those that failed again with the confidence
        # capped. Each way decodes some the other doesn't.
        again = np.nonzero(~ok)[0]
        if len(again):
            b2, ok2, u2 = bp_decode(np.clip(rows[again], -self.LLR_MAX, self.LLR_MAX), self.iters)
            bits[again[ok2]], ok[again[ok2]], used[again[ok2]] = b2[ok2], True, u2[ok2]
        tried = 0
        for j in sorted(np.nonzero(~ok)[0], key=lambda j: -cands[j]["sync"]):
            if cands[j]["sync"] < self.OSD_SYNC or tried >= self.OSD_MAX:
                break
            tried += 1
            cw, dis = osd_decode(rows[j])
            if dis < self.OSD_DISCREPANCY * np.abs(rows[j]).sum() and \
                    bits_frame(cw[87:]) is not None:
                bits[j], ok[j], used[j] = cw, True, -1
        out = []
        for j in np.nonzero(ok)[0]:
            got = bits_frame(bits[j, 87:])
            if got is None:
                continue
            c, n, f, Sy = info[j]
            frame, i3 = got
            tn = tones(frame, i3, self.m)
            A2 = np.abs(Sy) ** 2
            hard = np.argmax(A2, 1)
            sync_ok = int((hard[self.sync_pos] == tn[self.sync_pos]).sum())
            nerr = int((bits[j] != (np.array(rows[j]) > 0)).sum())
            if sync_ok < 4 or nerr > 50:
                continue  # a codeword, but too unlike what was received
            key = (frame, i3)
            if key in seen:
                continue
            seen.add(key)
            ps = A2[np.arange(NSYM), tn]
            mask = np.ones_like(A2, bool)
            mask[np.arange(NSYM), tn] = False
            pn = float(np.median(A2[mask])) / np.log(2)
            snr = 10 * np.log10(max(ps.mean() / pn - 1, 1e-3)) + 10 * np.log10(self.m.baud / 2500)
            start = n * self.D / RATE + t0
            out.append({"frame": frame, "i3": i3, "freq": f, "dt": start - self.m.delay,
                        "snr": int(round(max(snr, -30))), "sync": c["sync"],
                        "submode": self.m.letter, "start": n * self.D, "iters": int(used[j]),
                        "errors": nerr})
        return out

    def subtract(self, x, d):
        """Take a decoded signal out of x: re-make it a symbol at a time with
        that symbol's measured amplitude and phase."""
        m = self.m
        tn = tones(d["frame"], d["i3"], m)
        s0 = int(d["start"])
        nn = np.arange(m.sps)
        for i, t in enumerate(tn):
            a = s0 + i * m.sps
            if a < 0 or a + m.sps > len(x):
                continue
            f = d["freq"] + t * m.baud
            e = np.exp(-2j * np.pi * f * (a + nn) / RATE)
            seg = x[a:a + m.sps]
            amp = 2 * np.dot(seg, e) / m.sps
            seg -= (amp * np.conj(e)).real.astype(np.float32)



# ------------------------------------------------------------- the frames

# The 3 transmission bits sent beside each frame.
FIRST, LAST, DATA = 1, 2, 4
# The first 3 of a frame's 72 bits say what it is; a data frame needs only
# its first bit, which is 1, and the second says whether it is compressed.
HEARTBEAT, COMPOUND, COMPOUND_DIRECTED, DIRECTED = 0, 1, 2, 3

CALL_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ /@"
NBASECALL = 37 * 36 * 10 * 27 * 27 * 27
NBASEGRID = 180 * 180
NUSERGRID = NBASEGRID + 10
NMAXGRID = (1 << 15) - 1

# Callsign values past NBASECALL name groups (protocol constants).
GROUPS = ("<....>", "@ALLCALL", "@JS8NET", "@DX/NA", "@DX/SA", "@DX/EU", "@DX/AS", "@DX/AF",
          "@DX/OC", "@DX/AN", "@REGION/1", "@REGION/2", "@REGION/3") + \
    tuple("@GROUP/%d" % i for i in range(10)) + \
    ("@COMMAND", "@CONTROL", "@NET", "@NTS") + tuple("@RESERVE/%d" % i for i in range(5)) + \
    ("@APRSIS", "@RAGCHEW", "@JS8", "@EMCOMM", "@ARES", "@MARS", "@AMRRON", "@RACES",
     "@RAYNET", "@RADAR", "@SKYWARN", "@CQ", "@HB", "@QSO", "@QSOPARTY", "@CONTEST",
     "@FIELDDAY", "@SOTA", "@IOTA", "@POTA", "@QRP", "@QRO")
GROUP_VALUE = {g: NBASECALL + 1 + i for i, g in enumerate(GROUPS)}
VALUE_GROUP = {v: g for g, v in GROUP_VALUE.items()}

# Directed commands by their 5-bit code, as JS8Call writes them.
COMMANDS = {0: " SNR?", 1: " DIT DIT", 2: " NACK", 3: " HEARING?", 4: " GRID?", 5: ">",
            6: " STATUS?", 7: " STATUS", 8: " HEARING", 9: " MSG", 10: " MSG TO:",
            11: " QUERY", 12: " QUERY MSGS", 13: " QUERY CALL", 14: " ACK", 15: " GRID",
            16: " INFO?", 17: " INFO", 18: " FB", 19: " HW CPY?", 20: " SK", 21: " RR",
            22: " QSL?", 23: " QSL", 24: " CMD", 25: " SNR", 26: " NO", 27: " YES", 28: " 73",
            29: " HEARTBEAT SNR", 30: " AGN?", 31: " "}
COMMAND_CODE = {v: k for k, v in COMMANDS.items()}
SNR_COMMANDS = (25, 29)
# Commands whose text comes after them in data frames, with a checksum of
# that text at the end: relay, MSG, MSG TO:, QUERY, QUERY MSGS, QUERY CALL,
# CMD. JS8Call drops one whose checksum is wrong, and so does rxd.
CHECKSUMMED = (5, 9, 10, 11, 12, 13, 24)
CHECK_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-./?"
CQS = ("CQ CQ CQ", "CQ DX", "CQ QRP", "CQ CONTEST", "CQ FIELD", "CQ FD", "CQ CQ", "CQ")

# Uncompressed data frames: a fixed character code (a protocol constant).
HUFFMAN = {
    " ": "01", "E": "100", "T": "1101", "A": "0011", "O": "11111", "I": "11100", "N": "10111",
    "S": "10100", "H": "00011", "R": "00000", "D": "111011", "L": "110011", "C": "110001",
    "U": "101101", "M": "101011", "W": "001011", "F": "001001", "G": "000101", "Y": "000011",
    "P": "1111011", "B": "1111001", ".": "1110100", "V": "1100101", "K": "1100100",
    "-": "1100001", "+": "1100000", "?": "1011001", "!": "1011000", '"': "1010101",
    "X": "1010100", "0": "0010101", "J": "0010100", "1": "0010001", "Q": "0010000",
    "2": "0001001", "Z": "0001000", "3": "0000101", "5": "0000100", "4": "11110101",
    "9": "11110100", "8": "11110001", "6": "11110000", "7": "11101011", "/": "11101010"}
_HUFF_DECODE = {v: k for k, v in HUFFMAN.items()}


def frame_value(frame):
    v = 0
    for c in frame:
        v = (v << 6) | ALPHABET_INDEX[c]
    return v


def _field(v, start, n):
    """n bits of the 72-bit frame value v, from bit start (0 = first sent)."""
    return (v >> (72 - start - n)) & ((1 << n) - 1)


def unpack_call(value, portable=False):
    if value in VALUE_GROUP:
        return VALUE_GROUP[value]
    w = [""] * 6
    for i in (5, 4, 3):
        w[i] = CALL_CHARS[value % 27 + 10]
        value //= 27
    w[2] = CALL_CHARS[value % 10]
    value //= 10
    w[1] = CALL_CHARS[value % 36]
    value //= 36
    if value >= len(CALL_CHARS):
        return None
    w[0] = CALL_CHARS[value]
    call = "".join(w)
    if call.startswith("3D0"):
        call = "3DA0" + call[3:]
    if call[0] == "Q" and "A" <= call[1] <= "Z":
        call = "3X" + call[1:]
    call = call.strip()
    return call + "/P" if portable else call


def pack_call(call):
    """A callsign -> (28-bit value, portable), or None (for the test encoder)."""
    call = call.upper().strip()
    if call in GROUP_VALUE:
        return GROUP_VALUE[call], False
    portable = call.endswith("/P")
    if portable:
        call = call[:-2]
    if call.startswith("3DA0"):
        call = "3D0" + call[4:]
    if call.startswith("3X") and len(call) > 2 and call[2].isalpha():
        call = "Q" + call[2:]
    # Line it up as [digit or letter or space][digit or letter][digit][letters].
    for cand in (call, " " + call):
        cand = cand.ljust(6)
        if len(cand) == 6 and cand[2].isdigit() and cand[1] in CALL_CHARS[:36] and \
                cand[0] in CALL_CHARS[:37] and all(c == " " or c.isalpha() for c in cand[3:]):
            v = CALL_CHARS.index(cand[0])
            v = 36 * v + CALL_CHARS.index(cand[1])
            v = 10 * v + CALL_CHARS.index(cand[2])
            for c in cand[3:]:
                v = 27 * v + CALL_CHARS.index(c) - 10
            return v, portable
    return None


def unpack_alnum50(v):
    w = [""] * 11
    for i in (10, 9, 8):
        w[i] = CALL_CHARS[v % 38]
        v //= 38
    w[7] = "/" if v % 2 else " "
    v //= 2
    for i in (6, 5, 4):
        w[i] = CALL_CHARS[v % 38]
        v //= 38
    w[3] = "/" if v % 2 else " "
    v //= 2
    for i in (2, 1):
        w[i] = CALL_CHARS[v % 38]
        v //= 38
    w[0] = CALL_CHARS[v % 39]
    return "".join(w).replace(" ", "")


def pack_alnum50(text):
    w = "".join(c for c in text if c in CALL_CHARS)
    if len(w) > 3 and w[3] != "/":
        w = w[:3] + " " + w[3:]
    if len(w) > 7 and w[7] != "/":
        w = w[:7] + " " + w[7:]
    w = w.ljust(11)
    v = CALL_CHARS.index(w[0])
    for i in range(1, 11):
        if i in (3, 7):
            v = v * 2 + (w[i] == "/")
        else:
            v = v * 38 + CALL_CHARS.index(w[i])
    return v


def unpack_grid(value):
    """A 15-bit grid value -> a 4-character Maidenhead square ('' for none)."""
    if value > NBASEGRID:
        return ""
    lat = value % 180 - 90
    lon = value // 180 * 2 - 180 + 2
    nlon = int(60.0 * (180.0 - lon) / 5)
    nlat = int(60.0 * (lat + 90) / 2.5)
    return chr(65 + nlon // 240) + chr(65 + nlat // 240) + \
        chr(48 + (nlon % 240) // 24) + chr(48 + (nlat % 240) // 24)


def pack_grid(grid):
    if not grid or len(grid) < 4:
        return NMAXGRID
    g = grid[:4].upper()
    lon = 180 - 20 * (ord(g[0]) - 65) - 2 * (ord(g[2]) - 48) - 5 * 12.5 / 60
    lat = -90 + 10 * (ord(g[1]) - 65) + (ord(g[3]) - 48) + 2.5 * 12.5 / 60
    return ((int(lon) + 180) // 2) * 180 + int(lat + 90)


def crc16_kermit(data):
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc


def checksum16(text):
    """The 3 characters a checksummed command's text ends with."""
    v = crc16_kermit(text.encode("latin-1", "replace"))
    n = len(CHECK_CHARS)
    return CHECK_CHARS[v // (n * n)] + CHECK_CHARS[v // n % n] + CHECK_CHARS[v % n]


def snr_text(snr):
    return ("+%02d" % snr) if snr >= 0 else ("-%02d" % -snr)


# The JSC word table, if the user has supplied one (see README): it is not
# part of rxd. None until loaded; False if there is none.
_JSC = None
JSC_PATHS = [os.path.expanduser(p) for p in (
    os.environ.get("RXD_JSC", ""), "~/.local/share/rxd/js8/jsc_map.txt",
    "/usr/local/share/rxd/jsc_map.txt") if p]


def jsc_table():
    global _JSC
    if _JSC is None:
        _JSC = False
        for p in JSC_PATHS:
            try:
                with open(p, encoding="ascii") as fh:
                    words = [w.encode("ascii").decode("unicode_escape")
                             for w in fh.read().split("\n")]
            except (OSError, ValueError):
                continue
            if words and words[-1] == "":
                words.pop()
            if len(words) >= 1000:
                _JSC = words
                break
    return _JSC or None


def jsc_decompress(bits, table):
    """(s,c)-dense code with 4-bit digits, s=7, c=9 (Brisaboa et al.): each
    word is any number of continuers (8-15) and one stopper (0-7); a bit
    after each stopper says whether a space follows the word."""
    s, c = 7, 9
    base = [0]
    for k in range(1, 8):
        base.append(base[-1] + s * c ** (k - 1))
    digits, spaces = [], set()
    i = 0
    while i + 4 <= len(bits):
        d = (bits[i] << 3) | (bits[i + 1] << 2) | (bits[i + 2] << 1) | bits[i + 3]
        digits.append(d)
        i += 4
        if d < s:
            if i < len(bits) and bits[i]:
                spaces.add(len(digits) - 1)
            i += 1
    out, start = [], 0
    while start < len(digits):
        j = k = 0
        while start + k < len(digits) and digits[start + k] >= s:
            j = j * c + digits[start + k] - s
            k += 1
        if start + k >= len(digits) or k >= len(base):
            break
        j = j * s + digits[start + k] + base[k]
        if j >= len(table):
            break
        out.append(table[j])
        if start + k in spaces:
            out.append(" ")
        start += k + 1
    return "".join(out)


def _bits72(v):
    return [(v >> (71 - i)) & 1 for i in range(72)]


def _huffman(bits):
    out, code = [], ""
    for b in bits:
        code += "1" if b else "0"
        if code in _HUFF_DECODE:
            out.append(_HUFF_DECODE[code])
            code = ""
        elif len(code) > 8:
            break
    return "".join(out)


def unpack(frame, i3):
    """One frame -> a dict: kind (heartbeat, cq, compound, directed, data or
    raw), text as JS8Call shows it, and the parts. Data that needs the JSC
    table and doesn't have it comes back as kind "jsc" with text None."""
    v = frame_value(frame)
    flag = _field(v, 0, 3)
    tail8 = _field(v, 64, 8)
    if i3 & DATA:
        b = _bits72(v)
        n = len(b) - 1 - b[::-1].index(0) if 0 in b else 0
        table = jsc_table()
        if table is None:
            return {"kind": "jsc", "text": None}
        text = jsc_decompress(b[:n], table)
        return {"kind": "data", "text": text} if text else {"kind": "raw", "text": frame}
    if flag >= 4:
        b = _bits72(v)[1:]
        compressed = b[0]
        n = len(b) - 1 - b[::-1].index(0) if 0 in b else 0
        payload = b[1:n]
        if compressed:
            table = jsc_table()
            if table is None:
                return {"kind": "jsc", "text": None}
            text = jsc_decompress(payload, table)
        else:
            text = _huffman(payload)
        if text:
            return {"kind": "data", "text": text}
    if flag != DIRECTED and flag != 4:
        call = unpack_alnum50(_field(v, 3, 50))
        num = (_field(v, 53, 11) << 5) | (tail8 >> 3)
        bits3 = tail8 & 7
        if flag == HEARTBEAT:
            grid = unpack_grid(num & 0x7FFF)
            if num & 0x8000:
                kind, what = "cq", "@ALLCALL " + CQS[bits3]
            else:
                kind, what = "heartbeat", "@HB HEARTBEAT"
            return {"kind": kind, "from": call, "to": what.split()[0], "cmd": what[what.index(" "):],
                    "grid": grid, "text": "%s: %s %s " % (call, what, grid)}
        if flag in (COMPOUND, COMPOUND_DIRECTED):
            extra, cmd, grid = [], None, ""
            if num <= NBASEGRID:
                grid = unpack_grid(num)
                extra.append(" " + grid)
            elif NUSERGRID <= num < NMAXGRID:
                code, n = _unpack_cmd(num - NUSERGRID)
                cmd = COMMANDS.get(code)
                if cmd is not None:
                    extra.append(cmd)
                    if code in SNR_COMMANDS:
                        extra.append(snr_text(n - 31))
            if flag == COMPOUND:
                return {"kind": "compound", "from": call, "grid": grid, "text": call + ": "}
            return {"kind": "compound_directed", "to": call, "cmd": cmd, "grid": grid,
                    "extra": extra[1:] if cmd else [], "text": call + " ".join(extra) + " "}
        return {"kind": "raw", "text": frame}
    if flag == DIRECTED:
        frm = unpack_call(_field(v, 3, 28), (tail8 >> 7) & 1)
        to = unpack_call(_field(v, 31, 28), (tail8 >> 6) & 1)
        code = _field(v, 59, 5) % 32
        cmd = COMMANDS[code]
        num = tail8 % 64
        if frm is None or to is None:
            return {"kind": "raw", "text": frame}
        extra = []
        if num:
            extra.append(snr_text(num - 31) if code in SNR_COMMANDS else str(num - 31))
        return {"kind": "directed", "from": frm, "to": to, "cmd": cmd, "extra": extra,
                "text": "%s: %s%s " % (frm, to, " ".join([cmd] + extra))}
    return {"kind": "raw", "text": frame}


def _unpack_cmd(value):
    if value & 0x80:
        return (29 if value & 0x40 else 25), value & 0x3F
    return value & 0x7F, 0


def pack_directed(frm, to, cmd, num=None, i3=FIRST | LAST):
    """A directed frame (for tests and the test encoder)."""
    f, fp = pack_call(frm)
    t, tp = pack_call(to)
    code = COMMAND_CODE[cmd]
    extra = 0 if num is None else max(-30, min(num, 31)) + 31
    v = (DIRECTED << 69) | (f << 41) | (t << 13) | (code << 8) | (fp << 7) | (tp << 6) | extra
    return value_frame(v), i3


def pack_heartbeat(call, grid="", cq=None, i3=FIRST | LAST):
    num = pack_grid(grid) if grid else NMAXGRID
    bits3 = 0
    if cq is not None:
        num |= 0x8000
        bits3 = CQS.index(cq)
    v = (HEARTBEAT << 69) | (pack_alnum50(call) << 19) | ((num >> 5) << 8) | ((num & 31) << 3) | bits3
    return value_frame(v), i3


def pack_huffman(text, i3=0):
    """An uncompressed data frame holding as much of text as fits."""
    bits = [1, 0]
    for ch in text.upper():
        code = HUFFMAN.get(ch)
        if code is None or len(bits) + len(code) >= 72:
            break
        bits += [int(c) for c in code]
    bits += [0] + [1] * (71 - len(bits))
    v = 0
    for b in bits[:72]:
        v = (v << 1) | b
    return value_frame(v), i3


def value_frame(v):
    return "".join(ALPHABET[(v >> (66 - 6 * i)) & 63] for i in range(12))


# --------------------------------------------------------- the messages

EOT = "♢"   # JS8Call's end-of-message mark
GAP = "……"


class Assembler:
    """Joins frames into the messages JS8Call writes to DIRECTED.TXT.

    A message is the frames one station sends at one offset, slot after slot,
    from a frame flagged first to one flagged last. Heartbeats, CQs and
    directed commands start one; data frames continue it. A missing frame
    shows as '……', and a message that stops without its last frame is let go
    after a few slots. feed(slot, decodes) returns the finished messages as
    dicts: from, to, text (in JS8Call's form), freq, snr, submode, slot."""

    TOLERANCE = 10.0   # Hz between frames of one message (JS8Call's default)
    LINGER = 3         # slots without a frame before an unfinished message goes

    def __init__(self):
        self.open = []

    def feed(self, slot, decodes, slot_len=15, submode=None):
        done = []
        for d in sorted(decodes, key=lambda d: d["freq"]):
            u = d.get("unpacked") or unpack(d["frame"], d["i3"])
            i3 = d["i3"]
            kind = u["kind"]
            msg = self._near(d["freq"], d["submode"])
            starts = kind in ("heartbeat", "cq", "directed", "compound", "compound_directed")
            if starts and (i3 & FIRST or msg is None):
                if msg is not None and not (kind == "directed" and msg["head"] is not None and
                                            msg["head"].get("kind") == "compound"):
                    done.append(self._close(msg, complete=False))
                    msg = None
                if msg is None:
                    msg = self._new(d, slot)
                self._header(msg, u)
            elif msg is None:
                msg = self._new(d, slot)
                msg["parts"].append(GAP)
                self._data(msg, u, d)
            else:
                self._step(msg, slot, slot_len)
                if starts:
                    self._header(msg, u)
                else:
                    self._data(msg, u, d)
            msg["last_slot"] = slot
            msg["snr"] = d["snr"]
            if i3 & LAST:
                done.append(self._close(msg, complete=True))
        for msg in list(self.open):
            if submode is not None and msg["submode"] != submode:
                continue
            if slot - msg["last_slot"] >= self.LINGER * slot_len:
                done.append(self._close(msg, complete=False))
        return [x for x in done if x]

    def flush(self):
        out = [self._close(m, complete=False) for m in list(self.open)]
        return [x for x in out if x]

    def _near(self, f, sub):
        best = None
        for m in self.open:
            if m["submode"] == sub and abs(m["freq"] - f) <= self.TOLERANCE:
                if best is None or abs(m["freq"] - f) < abs(best["freq"] - f):
                    best = m
        return best

    def _new(self, d, slot):
        m = {"freq": d["freq"], "submode": d["submode"], "slot": slot, "last_slot": slot,
             "head": None, "parts": [], "snr": d["snr"], "jsc": False}
        self.open.append(m)
        return m

    def _step(self, msg, slot, slot_len):
        if slot - msg["last_slot"] > slot_len and (not msg["parts"] or msg["parts"][-1] != GAP):
            msg["parts"].append(GAP)

    def _header(self, msg, u):
        head = msg["head"]
        if head is not None and head.get("kind") == "compound":
            # A compound callsign's frame, then the frame it is the sender of.
            if u["kind"] == "directed" and u["from"] == "<....>":
                u = dict(u, **{"from": head["from"]})
            elif u["kind"] == "compound_directed":
                u = dict(u, **{"from": head["from"], "kind": "directed",
                               "extra": u.get("extra", [])})
        elif head is not None and head.get("kind") == "directed" and u["kind"] == "compound_directed":
            # A directed frame to "<....>", then the compound callsign it's to.
            u = dict(head, to=u["to"], cmd=u.get("cmd") or head["cmd"],
                     extra=u.get("extra") or head.get("extra", []))
        msg["head"] = u

    def _data(self, msg, u, d):
        if u["kind"] == "jsc":
            msg["jsc"] = True
            msg["parts"].append(GAP)
        elif u["kind"] == "data":
            if msg["parts"] and msg["parts"][-1] != GAP:
                msg["parts"][-1] += u["text"]
            else:
                msg["parts"].append(u["text"])
        else:
            msg["parts"].append(u["text"].strip())

    def _close(self, msg, complete):
        if msg in self.open:
            self.open.remove(msg)
        h = msg["head"]
        body = " ".join(p for p in msg["parts"]).strip()
        if h is None:
            if not body or body == GAP:
                return None
            frm, _, _ = body.partition(":")
            text, frm, to = body, (frm if ":" in body else None), None
        elif h["kind"] in ("heartbeat", "cq"):
            text = "%s: %s%s" % (h["from"], h["to"], h["cmd"])
            if h.get("grid"):
                text += " " + h["grid"]
            frm, to = h["from"], h["to"]
        elif h["kind"] == "compound":
            text = h["text"].strip() + (" " + h["grid"] if h.get("grid") else "")
            frm, to = h["from"], None
        elif h["kind"] == "compound_directed":
            text = "<....>: %s%s" % (h["to"], " ".join([h.get("cmd") or ""] + h.get("extra", [])))
            frm, to = None, h["to"]
        else:
            text = "%s: %s%s" % (h["from"], h["to"], " ".join([h["cmd"]] + h.get("extra", [])))
            frm, to = h["from"], h["to"]
        code = COMMAND_CODE.get(h.get("cmd")) if h is not None else None
        if code in CHECKSUMMED and h["kind"] == "directed":
            # The text is the data frames run together; it ends in a space
            # and its checksum, which is checked and taken off.
            whole = "".join(p for p in msg["parts"] if p != GAP).strip()
            if not complete or GAP in msg["parts"] or len(whole) < 4 or \
                    checksum16(whole[:-4]) != whole[-3:]:
                return None
            body = whole[:-4]
        if h is not None and body:
            text = text.rstrip() + " " + body if h.get("cmd") != " " else text + " " + body
        text = text.rstrip()
        if complete:
            text += " " + EOT
        return {"from": frm, "to": to, "text": text, "freq": msg["freq"], "snr": msg["snr"],
                "submode": msg["submode"], "slot": msg["slot"], "complete": complete,
                "needs_jsc": msg["jsc"]}


# ----------------------------------------------------------- the records

def all_line(slot, d, text):
    """A line in JS8Call's ALL.TXT form."""
    return "%s%3d %4.1f %4d %s  %-12s         %d   %s" % (
        time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(slot)), d["snr"], d["dt"],
        int(round(d["freq"])), d["submode"], d["frame"], d["i3"], text if text is not None else "")


def directed_line(when, dial, msg):
    """A line in JS8Call's DIRECTED.TXT form (the offset is the sender's)."""
    return "%s\t%.6f\t%d\t%s\t%s" % (time.strftime("%Y-%m-%d %H:%M:%S", time.gmtime(when)),
                                     dial / 1e6, int(round(msg["freq"])), snr_text(msg["snr"]),
                                     msg["text"])


def decode_slot(x, t0, submodes=("normal",), decoders=None):
    """Every submode's decodes in one block of audio, each with its frame
    unpacked. decoders caches Decoder objects between calls."""
    decoders = {} if decoders is None else decoders
    out = []
    for name in submodes:
        dec = decoders.get(name) or decoders.setdefault(name, Decoder(name))
        for d in dec.decode(x, t0):
            d["unpacked"] = unpack(d["frame"], d["i3"])
            out.append(d)
    return out


# -------------------------------------------------------- serving rxd

def serve(inp=None, out=None):
    """Decode slots for rxd: a JSON header line, then the audio as float32;
    one JSON line back per slot. Runs at reduced priority, in its own process,
    so a busy band can't starve rxd's audio."""
    inp = inp or sys.stdin.buffer
    out = out or sys.stdout
    try:
        os.nice(10)
    except OSError:
        pass
    decoders = {}
    jsc_table()
    while True:
        line = inp.readline()
        if not line:
            return 0
        job = json.loads(line)
        raw = inp.read(4 * job["n"])
        if len(raw) < 4 * job["n"]:
            return 1
        x = np.frombuffer(raw, "<f4")
        c0, w0 = time.process_time(), time.monotonic()
        try:
            res = decode_slot(x, job["t0"], [job["submode"]], decoders)
            reply = {"id": job.get("id"), "decodes": res, "error": None}
        except Exception as e:  # noqa: BLE001 - reported to rxd, not fatal
            reply = {"id": job.get("id"), "decodes": [], "error": "%s: %s" % (type(e).__name__, e)}
        reply["cpu"] = time.process_time() - c0
        reply["wall"] = time.monotonic() - w0
        out.write(json.dumps(reply, default=float) + "\n")
        out.flush()


def read_wav(path):
    import wave
    with wave.open(path, "rb") as w:
        rate, n, ch, width = w.getframerate(), w.getnframes(), w.getnchannels(), w.getsampwidth()
        raw = w.readframes(n)
    if width != 2:
        raise ValueError("%s: 16-bit WAV only" % path)
    x = np.frombuffer(raw, "<i2").astype(np.float32) / 32768
    if ch > 1:
        x = x.reshape(-1, ch).mean(1)
    if rate != RATE:
        from scipy.signal import resample_poly
        from math import gcd
        g = gcd(rate, RATE)
        x = resample_poly(x, RATE // g, rate // g).astype(np.float32)
    return x


def write_wav(path, x, rate=RATE):
    import wave
    pcm = np.clip(np.asarray(x) * 32767, -32768, 32767).astype("<i2")
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())


# ------------------------------------------------------- inside rxd

JS8_DIR = os.path.expanduser(os.environ.get("RXD_JS8_DIR", "~/.local/share/rxd/js8"))


class Resampler:
    """48 kHz (or any multiple of 12 kHz) -> 12 kHz, block by block."""

    def __init__(self, rate_in):
        from scipy import signal as sps
        if rate_in % RATE:
            raise ValueError("audio must come at a multiple of 12 kHz")
        self.n = rate_in // RATE
        self.h = sps.firwin(129, 5000, fs=rate_in).astype(np.float32)
        self.zi = np.zeros(len(self.h) - 1, np.float32)
        self.phase = 0
        self.lfilter = sps.lfilter

    def __call__(self, x):
        if self.n == 1:
            return np.asarray(x, np.float32)
        y, self.zi = self.lfilter(self.h, 1.0, np.asarray(x, np.float32), zi=self.zi)
        out = y[self.phase::self.n]
        self.phase = (self.phase - len(y)) % self.n
        return out.astype(np.float32)


class SlotDecoder:
    """rxd's audio -> slots by the system clock -> the decoder process ->
    ALL.TXT and DIRECTED.TXT under datadir, in JS8Call's forms.

    push() is called from rxd's DSP thread with the audio before squelch and
    volume; it only copies into a ring and hands finished slots to a worker
    thread, which feeds a separate, lower-priority decoder process. A slot is
    dropped when the dial moves during it or the audio has a gap."""

    RING_S = 45
    KEEP_BYTES = 8 << 20   # each log is rolled over to .1 past this

    def __init__(self, dial_hz=None, submodes=("normal",), datadir=None, rate_in=48000,
                 clock=time.time, inline=False):
        self.submodes = [s for s in submodes if s in SUBMODES]
        if not self.submodes:
            raise ValueError("no JS8 submodes among %s" % (submodes,))
        self.dir = datadir or JS8_DIR
        os.makedirs(self.dir, exist_ok=True)
        self.directed_path = os.path.join(self.dir, "DIRECTED.TXT")
        self.all_path = os.path.join(self.dir, "ALL.TXT")
        self.clock = clock
        self.inline = inline
        self.resample = Resampler(rate_in)
        self.ring = np.zeros(int(self.RING_S * RATE), np.float32)
        self.written = 0          # samples ever written
        self.valid_from = 0       # first sample since the last gap or retune
        self.t_end = None         # the clock when the last sample arrived
        self.dial = dial_hz
        self.windows = {s: Decoder(s).window() for s in self.submodes}
        self.next_slot = {}
        import queue
        import threading
        self.jobs = queue.Queue(maxsize=2 * len(self.submodes))
        self.lock = threading.Lock()
        self.assembler = Assembler()
        self.proc = None
        self.decoders = {}
        self.decoding = None
        self.last = None
        self.error = None
        self.skipped = 0
        self.cpu = []             # (cpu seconds, slot seconds) for recent slots
        self.worker = threading.Thread(target=self._work, name="js8", daemon=True)
        self.worker.start()

    # ----------------------------------------------------- recording
    def push(self, audio, dial, now=None):
        a = self.resample(audio)
        now = self.clock() if now is None else now
        if self.t_end is not None:
            gap = now - self.t_end - len(a) / RATE
            if dial != self.dial or abs(gap) > 0.5:
                self.valid_from = self.written  # retuned, or the audio stalled
        self.dial = dial
        n = len(a)
        if n >= len(self.ring):
            a, n = a[-len(self.ring):], len(self.ring)
        i = self.written % len(self.ring)
        k = min(n, len(self.ring) - i)
        self.ring[i:i + k] = a[:k]
        self.ring[:n - k] = a[k:]
        self.written += n
        self.t_end = now
        for name in self.submodes:
            self._due(name)

    def _due(self, name):
        m = SUBMODES[name]
        before, after = self.windows[name]
        if name not in self.next_slot:
            self.next_slot[name] = (self.t_end // m.slot) * m.slot
        s = self.next_slot[name]
        if self.t_end < s + m.slot + after:
            return
        self.next_slot[name] = s + m.slot
        if self.t_end > s + 2 * m.slot + after:  # far behind (a stall): skip ahead
            self.next_slot[name] = (self.t_end // m.slot) * m.slot
        length = int(round((m.slot + before + after) * RATE))
        first = self.written - int(round((self.t_end - (s - before)) * RATE))
        if first < self.valid_from or first < self.written - len(self.ring) or first < 0:
            return  # joined late, retuned, or a gap: not a whole slot
        idx = np.arange(first, first + length) % len(self.ring)
        try:
            self.jobs.put_nowait((name, s, -before, self.ring[idx].copy(), self.dial))
        except Exception:  # queue.Full
            self.skipped += 1
            self.error = "decoding is falling behind; a slot was skipped"

    # ----------------------------------------------------- decoding
    def _work(self):
        while True:
            name, slot, t0, x, dial = self.jobs.get()
            if name is None:
                return
            self.decoding = (name, slot)
            try:
                decodes, cpu, wall = self._decode(name, x, t0)
                self.error = None
            except (OSError, ValueError, RuntimeError) as e:
                self.error = "JS8 decoder failed: %s" % e
                decodes, cpu, wall = [], 0.0, 0.0
            finally:
                self.decoding = None
            self._record(name, slot, dial, decodes, cpu, wall)

    def _decode(self, name, x, t0):
        if self.inline:
            c0, w0 = time.process_time(), time.monotonic()
            d = decode_slot(x, t0, [name], self.decoders)
            return d, time.process_time() - c0, time.monotonic() - w0
        import subprocess
        for attempt in (1, 2):
            if self.proc is None or self.proc.poll() is not None:
                self.proc = subprocess.Popen(
                    [sys.executable, os.path.abspath(__file__), "--serve"],
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            try:
                head = json.dumps({"submode": name, "t0": t0, "n": len(x)}) + "\n"
                self.proc.stdin.write(head.encode() + np.asarray(x, "<f4").tobytes())
                self.proc.stdin.flush()
                line = self.proc.stdout.readline()
                if not line:
                    raise OSError("the decoder process exited")
                r = json.loads(line)
                if r.get("error"):
                    raise RuntimeError(r["error"])
                return r["decodes"], r["cpu"], r["wall"]
            except (OSError, ValueError) as e:
                self.proc.kill()
                self.proc = None
                if attempt == 2:
                    raise OSError(str(e))
        return [], 0.0, 0.0

    def _record(self, name, slot, dial, decodes, cpu, wall):
        m = SUBMODES[name]
        msgs = self.assembler.feed(slot, decodes, m.slot, m.letter)
        now = self.clock()
        with self.lock:
            self.cpu = (self.cpu + [(cpu, m.slot)])[-40:]
            self.last = {"slot": iso(slot), "submode": name, "decodes": len(decodes),
                         "messages": len(msgs), "cpu_s": round(cpu, 2), "wall_s": round(wall, 2)}
        self._append(self.all_path, [all_line(slot, d, d["unpacked"]["text"]) for d in decodes])
        if dial is not None:
            self._append(self.directed_path, [directed_line(now, dial, x) for x in msgs])

    def _append(self, path, rows):
        if not rows:
            return
        try:
            if os.path.getsize(path) > self.KEEP_BYTES:
                os.replace(path, path + ".1")
        except OSError:
            pass
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write("".join(r + "\n" for r in rows))
        except OSError as e:
            self.error = "can't write %s: %s" % (path, e)

    # ------------------------------------------------------- status
    def status(self):
        now = self.clock() if self.t_end is None else self.t_end
        with self.lock:
            cpu = sum(c for c, _ in self.cpu)
            span = sum(s for _, s in self.cpu) / max(len(self.submodes), 1)
            if self.decoding is not None:
                state, slot = "decoding", self.decoding[1]
            elif self.t_end is None:
                state, slot = "waiting", None
            else:
                state = "recording"
                slot = self.next_slot.get(self.submodes[0])
            return {"engine": "rxd", "version": VERSION, "submodes": self.submodes,
                    "state": state, "slot": iso(slot) if slot is not None else None,
                    "last": self.last, "error": self.error, "skipped": self.skipped,
                    "cpu_pct": round(100 * cpu / span, 1) if span else None,
                    "jsc": jsc_path() is not None, "log": self.directed_path}

    def close(self):
        self.jobs.put((None, 0, 0, None, None))
        if self.proc is not None:
            self.proc.kill()


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def jsc_path():
    for p in JSC_PATHS:
        if os.path.isfile(p):
            return p
    return None


# ------------------------------------------------- the JSC word table

JSC_WORDS = 262144


def jsc_import(src, dest=None):
    """Write the JSC word table, one word per line in code order (escaped as
    Python writes a string's insides, since one word is a newline), from the
    user's own copy of JS8Call: its program, /usr/bin/js8call from the
    js8call package.
    The table is JS8Call's (GPL-3); rxd neither ships nor needs it, but with
    it rxd can show compressed free text. Returns (dest, word count)."""
    dest = dest or os.path.join(os.path.expanduser("~/.local/share/rxd/js8"), "jsc_map.txt")
    with open(src, "rb") as fh:
        data = fh.read()
    if data[:4] != b"\x7fELF":
        raise ValueError("%s is not a program; give the path to js8call" % src)
    words = _jsc_from_elf(data)
    if len(words) != JSC_WORDS:
        raise ValueError("%s: found %d JSC words, not %d" % (src, len(words), JSC_WORDS))
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    tmp = dest + ".new"
    with open(tmp, "w", encoding="ascii", newline="\n") as fh:
        fh.write("".join(w.encode("unicode_escape").decode("ascii") + "\n" for w in words))
    os.replace(tmp, dest)
    return dest, len(words)


def _jsc_from_elf(data):
    """JSC::map in a 64-bit little-endian ELF: 262144 entries of {char *str,
    int size, int index}, index counting up from 0. In a position-independent
    program the pointers are filled in at load time, so they are read from
    the relative relocations."""
    if data[4] != 2 or data[5] != 1:
        raise ValueError("only 64-bit little-endian programs")
    shoff, = struct.unpack_from("<Q", data, 0x28)
    phoff, = struct.unpack_from("<Q", data, 0x20)
    phnum, = struct.unpack_from("<H", data, 0x38)
    shnum, = struct.unpack_from("<H", data, 0x3C)
    loads = []
    for i in range(phnum):
        p_type, _, p_offset, p_vaddr, _, p_filesz = struct.unpack_from("<IIQQQQ", data, phoff + 56 * i)
        if p_type == 1:
            loads.append((p_vaddr, p_offset, p_filesz))

    def at(vaddr):
        for va, off, size in loads:
            if va <= vaddr < va + size:
                return off + vaddr - va
        raise ValueError("address %#x is not in the program" % vaddr)

    def vaddr_of(off):
        for va, o, size in loads:
            if o <= off < o + size:
                return va + off - o
        raise ValueError("offset %#x is not loaded" % off)

    relocs = {}
    for i in range(shnum):
        sh = struct.unpack_from("<IIQQQQIIQQ", data, shoff + 64 * i)
        if sh[1] == 4 and sh[9] == 24:   # SHT_RELA
            r = np.frombuffer(data, "<u8", count=sh[5] // 8, offset=sh[4]).reshape(-1, 3)
            rel = r[(r[:, 1] & 0xFFFFFFFF) == 1027]   # R_AARCH64_RELATIVE
            relocs.update(zip(rel[:, 0].tolist(), rel[:, 2].tolist()))
    u = np.frombuffer(data[: len(data) // 4 * 4], "<u4")
    hits = np.nonzero((u[:-20] == 0) & (u[4:-16] == 1) & (u[8:-12] == 2) &
                      (u[12:-8] == 3) & (u[16:-4] == 4))[0]
    for h in hits:
        base = 4 * int(h) - 12
        idx = u[(base + 12) // 4::4][:JSC_WORDS]
        if len(idx) < JSC_WORDS or not (idx == np.arange(JSC_WORDS)).all():
            continue
        words = []
        for e in range(JSC_WORDS):
            off = base + 16 * e
            ptr, = struct.unpack_from("<Q", data, off)
            ptr = ptr or relocs.get(vaddr_of(off))
            if not ptr:
                break
            s = at(ptr)
            words.append(data[s:data.index(b"\0", s)].decode("latin-1"))
        if len(words) == JSC_WORDS:
            return words
    raise ValueError("no JSC word table in this program")


def main(argv=None):
    import argparse
    ap = argparse.ArgumentParser(prog="js8", description="rxd's JS8 decoder")
    ap.add_argument("--serve", action="store_true", help="decode slots for rxd on stdin/stdout")
    ap.add_argument("--wav", nargs="+", help="decode WAV files, each one slot")
    ap.add_argument("--t0", type=float, default=0.0,
                    help="where the WAV starts, in seconds from the slot's start")
    ap.add_argument("--submode", default="normal", help="normal, fast, turbo, slow or all")
    ap.add_argument("--jsc-import", metavar="FILE",
                    help="build the JSC word table from your JS8Call (/usr/bin/js8call)")
    ap.add_argument("--version", action="store_true")
    a = ap.parse_args(argv)
    if a.version:
        print(VERSION)
        return 0
    if a.serve:
        return serve()
    if a.jsc_import:
        dest, n = jsc_import(a.jsc_import)
        print("wrote %d JSC words to %s" % (n, dest))
        return 0
    if a.wav:
        subs = list(SUBMODES) if a.submode == "all" else a.submode.split(",")
        decoders = {}
        for path in a.wav:
            x = read_wav(path)
            for d in decode_slot(x, a.t0, subs, decoders):
                print(all_line(0, d, d["unpacked"]["text"]))
        return 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
RXDJS8
    log "installed rxd's JS8 decoder"

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
        vol = float(st["volume"])
        # A JS8 profile's volume is JS8Call's input level: never save it
        # silent (an older rxd let a speaker mute through to it).
        if not (p.get("js8call_dial") is not None and vol < 0.05):
            p["volume"] = vol
    if "squelch" in st:  # in SDR++'s keys, which rxd reads back
        ds = dict(p.get("demod_settings") or {}, squelchEnabled=st["squelch"] is not None)
        if st["squelch"] is not None:
            ds["squelchLevel"] = float(st["squelch"])
        p["demod_settings"] = ds
    if st.get("gain_db") is not None:
        p["rtl"] = dict(p.get("rtl") or {}, gain_db=float(st["gain_db"]))
    if "gain_auto" in st:  # with it on, gain_db is only where rxd starts
        p["rtl"] = dict(p.get("rtl") or {}, gain_auto=bool(st["gain_auto"]))
    au = st.get("audio")
    if isinstance(au, dict):
        saved = {k: au[k] for k in ("auto", "filter", "norm", "limit", "squelch") if k in au}
        if "nr_setting" in au:  # the setting (None: by mode), not whether it's on now
            saved["nr"] = au["nr_setting"]
        if saved:
            p["audio"] = saved
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
    # "js8_engine": "rxd" has rxd decode JS8 itself; JS8Call isn't needed.
    app = js8 and target.get("js8_engine", "js8call") != "rxd"

    # Re-running the profile already playing changes nothing: a restart would
    # throw away tuning done live through rigctl or HTTP. rxd's own idea of
    # its profile guards against an instance started for some other name.
    st = rxd_status()
    same = prev == name and st is not None and st.get("profile", name) == name

    # Only re-running a JS8Call profile already up leaves JS8Call be.
    if not (app and prev == name):
        close("js8call", JS8_CRIT)

    # Save the profile being left, so coming back resumes it. Resuming at
    # login has nothing current to save.
    if prev and st is not None and not resume and not same:
        store(prev, capture(profile(prev), st))
        target = profile(name)

    set_active(name)
    if not same:
        if app:
            ensure_js8_sink()  # before rxd starts: it opens its sink then
        ensure_stored(name, target)
        rxd_stop()
        rxd_start(name)

    if app:
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
    elif js8:
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
    if focus and app:
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
