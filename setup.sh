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

Frequencies on both ports are the dial, as JS8Call means it. A JS8 profile
whose VFO sits off its js8call_dial (7077900 vs 7078000, tuned by hand)
keeps that difference as a calibration, so the dial still reads 7078000.

SIGHUP re-reads the profile; SIGINT or SIGTERM stops.
"""
import argparse
import ctypes
import ctypes.util
import json
import os
import queue
import signal
import socket
import socketserver
import sys
import threading
import time
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
            self.version = getattr(self, "version", 0) + 1

    def snapshot(self):
        with self.lock:
            return dict(mode=self.mode, bandwidth=self.bandwidth, dial=self.dial,
                        cal=self.cal, upconverter=self.upconverter(),
                        offset_mode=self.offset_mode,
                        agc_attack=self.agc_attack, agc_decay=self.agc_decay,
                        volume=self.volume, gain_db=self.gain_db,
                        version=self.version)

    def upconverter(self):
        """The offset in effect for the current dial (call with the lock held)."""
        if self.offset_mode == "Ham-It-Up":
            return self.upconverter_hz
        if self.offset_mode == "auto" and self.dial < self.upconvert_below:
            return self.upconverter_hz
        return 0.0

    def update(self, freq=None, mode=None, bandwidth=None, gain_db=None,
               volume=None):
        with self.lock:
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
            self.level_db = 10 * np.log10(p + 1e-12)
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
            pcm = np.clip(audio * snap["volume"] * 32767, -32768, 32767).astype("<i2")
            self.sink.write(pcm)
            dt = time.thread_time() - t0
            self.cpu += (dt / (len(x) / self.chain.rate) - self.cpu) * 0.05
            self.blocks += 1

    def status(self):
        snap = self.s.snapshot()
        return {"profile": self.s.name, "freq": snap["dial"],
                "vfo_hz": snap["dial"] - snap["cal"], "cal_hz": snap["cal"],
                "mode": snap["mode"], "bandwidth": snap["bandwidth"],
                "gain_db": snap["gain_db"], "volume": snap["volume"],
                "offset_mode": snap["offset_mode"], "upconverter_hz": snap["upconverter"],
                "level_dbfs": round(self.chain.level_db, 1) if self.chain else None,
                "tuner_hz": self.src.center, "offset_hz": self.offset,
                "sample_rate": self.chain.rate if self.chain else None,
                "dsp_cpu": round(self.cpu, 3), "blocks": self.blocks,
                "dropped": self.dropped, "error": self.error,
                "running": not self.stop.is_set()}


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
        if self.path == "/api/status":
            return self.send(200, self.server.rx.status())
        self.send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/api/tune":
            return self.send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", 0))
            doc = json.loads(self.rfile.read(n) or b"{}")
            if not isinstance(doc, dict):
                raise ValueError("body must be a JSON object")
            unknown = set(doc) - {"freq", "mode", "bandwidth", "gain_db", "volume"}
            if unknown:
                raise ValueError("unknown field(s): " + ", ".join(sorted(unknown)))
            self.server.rx.s.update(**doc)
        except (ValueError, TypeError, AttributeError) as e:
            return self.send(400, {"error": str(e)})
        self.send(200, self.server.rx.status())


# ---------------------------------------------------------------------- main

def hostport(text, default_port):
    host, _, port = text.rpartition(":")
    return (host or "127.0.0.1", int(port or default_port))


def main(argv=None):
    ap = argparse.ArgumentParser(prog="rxd", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("profile")
    ap.add_argument("--iq", help="cu8 file, - for stdin, or synth (default: the dongle)")
    ap.add_argument("--iq-center", type=float,
                    help="tuner frequency the IQ file was recorded at")
    ap.add_argument("--audio", default="pulse",
                    help="pulse, pulse:SINK, stdout or null (default: the profile's sink)")
    ap.add_argument("--rigctl", default="127.0.0.1:4532", help="HOST:PORT, or off")
    ap.add_argument("--http", default="127.0.0.1:8073", help="HOST:PORT, or off")
    a = ap.parse_args(argv)

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
RXDTUI
    log "installed rxd-tui"

    # The browser UI, served by rxd at / on its HTTP port.
    run install -d -m 0755 /usr/local/share/rxd
    write_file /usr/local/share/rxd/index.html 0644 <<'RXDWEB'
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
                       JS8 profile also brings up JS8Call on its dial. The
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

A profile is tuning only: frequency, offset mode, demodulator and its
settings, audio sink and volume, the RTL-SDR's settings and, for JS8
profiles, JS8Call's dial. The defaults below are starting points; saved
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
    # keeps that difference as a calibration.
    return {"description": desc, "frequency": dial - 100.0,
            "offset": "auto", "demod": "USB",
            "demod_settings": USB_JS8, "sink": JS8_SINK, "volume": 0.2090567648410797,
            "rtl": rtl(4), "js8call_dial": dial}


def vhf(desc, hz, demod="FM", settings=NFM, gain=20):
    return {"description": desc, "frequency": hz,
            "offset": "auto", "demod": demod, "demod_settings": settings,
            "sink": SPEAKER, "volume": 0.5, "rtl": rtl(gain)}


PROFILES = {
    "ghostnet": js8("JS8 GhostNet, 40 m", 7107000),
    "js8":      js8("JS8, 40 m", 7078000),
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


def summary(name, p):
    path = "Ham It Up upconvert" if upconverting(p) else "Ham It Up bypass"
    return "%-9s %11.4f MHz %-4s %-19s %s" % (
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


def has_window(pat):
    tree = subprocess.run(["i3-msg", "-t", "get_tree"],
                          capture_output=True, text=True).stdout
    return re.search(r'"class":"' + pat, tree, re.I) is not None


def i3(cmd):
    subprocess.run(["i3-msg", "-q", cmd],
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
    subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
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


def check_clock():
    # JS8 slots are 15 s with about 2 s of tolerance. Outside that nothing
    # decodes and nothing says why, so say it here.
    out = subprocess.run(["chronyc", "-n", "tracking"], capture_output=True,
                         text=True).stdout
    if not re.search(r"^Leap status\s*: Normal", out, re.M):
        say("clock not synchronised (no GPS fix and no network?) — JS8 will "
            "not decode until it is. See: chronyc sources", "warning")


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
    if st.get("gain_db") is not None:
        p["rtl"] = dict(p.get("rtl") or {}, gain_db=float(st["gain_db"]))
    # rxd is the source of truth for the dial too: JS8Call tunes it over
    # rigctl. Saving both dial and carrier keeps the calibration between them.
    if p.get("js8call_dial") is not None and st.get("freq") is not None:
        p["js8call_dial"] = int(round(float(st["freq"])))
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
        check_clock()

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

    if a.names:  # for tab completion
        print("\n".join(known()))
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
