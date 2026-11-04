# rx

**Receive-only comms and situational awareness, in a case.**

Provisioning for the ClockworkPi uConsole at the heart of it — a **CM4 Lite**
running **Rex's Debian Bookworm image** with the **HackerGadgets AIO v2**
board: SDR, LoRa mesh, GPS-disciplined time, and an i3 desktop sized for the
5" panel.

```bash
curl -fsSL pid1.space/rx | sudo bash
```

<details>
<summary>If the short URL is down</summary>

`pid1.space/rx` redirects to `rx.pid1.space`, a Cloudflare Worker that
Cloudflare builds and deploys straight from this repository on every push to
`main`. There is no mirror to fall out of date: if Cloudflare misses a push,
[`cf-fallback.yml`](.github/workflows/cf-fallback.yml) notices that the live
`/.build-id` is not the current commit and deploys it. The raw URL remains the
fallback for when Cloudflare itself is unreachable:

```bash
curl -fsSL https://raw.githubusercontent.com/pid1/rx/main/setup.sh | sudo bash
```

Both take the same flags. Substitute either URL wherever this README says
`pid1.space/rx`.
</details>

Re-running is safe and is the intended way to use this — every step is
idempotent, and a run that changes nothing writes nothing.

---

## Getting the OS on first

**1. Download Rex's image**, `ClockworkPi-Bookworm-6.12.y.img.xz`.

Rex (`ak-rex`) publishes **no images on GitHub** — his GitHub holds only source
(pi-gen, the kernel tree, the apt repo). The images live on:

- <https://mega.nz/folder/LSInGD6J#0YezWX8xC4PkbyForgl1Hw>
- <https://drive.google.com/drive/folders/1tw2uPVPsFDhQ5Onx4mlllYexUDmDp0eK>
- <https://app.drime.cloud/drive/s/O3faUnk9ihg2vlrgek0LiaHRiU3fGb>

all linked from the [forum thread](https://forum.clockworkpi.com/t/bookworm-6-12-y-for-the-uconsole-and-devterm/15847),
which is also where the current release and any per-version caveats are posted.

**2. Write it with Raspberry Pi Imager** — *Choose OS → Use custom* → pick the
`.xz` directly, it decompresses on the fly. Balena Etcher works too. Use
Imager's advanced options to preset the Wi-Fi SSID/password; the uConsole
keyboard is a slow way to type a passphrase.

**3. Target is a microSD card.** A CM4 *with* eMMC has no SD lines wired up and
must be flashed over USB with `rpiboot`/`usbboot`. CM4 Lite uses SD.

**4. First boot** expands the filesystem and reboots itself, then runs a wizard
that creates your user account. The script does not create users — it expects
that account to exist, and takes `--user NAME` if it isn't `jroemer`.

---

## What it assumes

This targets Rex's image specifically:

- **His apt repo is already configured** (it appears as `ClockworkPi-apt`).
  That's where `sdrpp-brown`, `hackergadgets-uconsole-aio-board`, `pinctrl` and
  the rtlsdrblog `rtl-sdr` build come from rather than Debian. The script
  verifies it rather than adding a copy.
- **No games and no desktop.** True of both the Lite (stage2) and full (stage4)
  builds, so there is nothing to strip out.

---

## Sections

Every section is skippable with `--skip NAME`, or run alone with `--only NAME`.

| Section | What it does |
|---|---|
| `base` | Timezone (America/Chicago), hushlogin, sshd enabled, GitHub-backed `authorized_keys` sync, the `maint` maintenance command, hardware group membership |
| `desktop` | X11 + i3, autologin on tty1, Alacritty, Atkinson fonts, PipeWire, blanking disabled |
| `claude` | Claude Code from Anthropic's signed apt repo |
| `aio` | HackerGadgets AIO v2 metapackage, GPIO power rails, boot overlays |
| `rtc` | PCF85063A over i2c, bound once the AIO rails are up (`uconsole-rtc`), `fake-hwclock` as fallback |
| `gps` | UART + PPS overlays, serial console removed, `gpsd` on `/dev/ttyS0` |
| `lora` | SPI overlays, `meshtasticd` with the SX1262 config, `meshtastic-ui` dashboard, region |
| `sdr` | `sdrpp-brown`, `rtl-sdr`, DVB-T driver blacklisted, gqrx bookmarks migrated, `radio` profiles |
| `ham` | JS8Call + hamlib, receive-only GhostNet configuration, SDR→JS8Call loopback sink, `js8ghost`/`js8call` launchers, CHIRP |
| `tailscale` | Tailscale from its official repo |

### Flags

```
--dry-run           print every change without making one
--user NAME         target account (default: jroemer)
--only SECTION      run only these (repeatable)
--skip SECTION      skip these (repeatable)
```

Flags must go through `bash -s --`, since `| sudo bash --dry-run` hands the flag
to bash rather than to the script:

```bash
curl -fsSL pid1.space/rx | sudo bash -s -- --dry-run
curl -fsSL pid1.space/rx | sudo bash -s -- --only sdr --skip lora
```

`sudo` scrubs the environment, so `TS_AUTHKEY` must be set **after** `sudo`:

```bash
curl -fsSL pid1.space/rx | sudo TS_AUTHKEY=tskey-auth-... bash -s -- --only tailscale
```

---

## Routine maintenance

```bash
sudo maint
```

One command, installed by the `base` section:

1. `apt update`, `apt full-upgrade`, `apt autoremove --purge`
2. re-fetches and re-applies `setup.sh` — idempotent, so only drift and newly
   added configuration change
3. reports whether a reboot is pending, and which packages want one

Arguments pass through, so `sudo maint --dry-run` previews the configuration
half without touching anything, and `sudo maint --only sdr` narrows it.

**Kernel and boot firmware are held**, so `maint` will not replace them. The
display, panel rotation and the AIO overlays depend on kernel patches matched
to this image, and the apt suite the image ships carries newer kernels than the
build — an unattended run could otherwise leave a portable device with no
display, away from a desk.

`maint` reports when a held package has an update waiting. Take those
deliberately:

```bash
sudo apt-mark unhold clockworkpi-kernel
sudo apt install clockworkpi-kernel
sudo reboot                      # confirm the display comes up
sudo apt-mark hold clockworkpi-kernel
```

Held by default: `akrex-kernel`, `clockworkpi-kernel`,
`clockworkpi-cm-firmware`, `raspberrypi-kernel`, `raspberrypi-bootloader`
(whichever are installed) — `HOLD_PACKAGES` in `setup.sh`.

It fetches from `pid1.space/rx`, falling back to the raw URL, and downloads to
a file rather than piping — a truncated transfer is then caught by the same
checks [`build.sh`](build.sh) runs before publishing (`bash -n`, shebang, and
the trailing `main "$@"` without which the script would parse cleanly and do
nothing).

---

## SSH

Enabled and listening on 22 by the `base` section. pi-gen's stage2 contains
both `systemctl enable ssh` and `systemctl disable ssh` behind a build-time
condition, so the image's state is not assumable either way.

`authorized_keys` is refreshed from `github.com/pid1.keys` every 5 minutes for
both `root` and the desktop user, via `/usr/local/sbin/sync-github-keys`. It
fetches to a temp file, requires the result to be non-empty and to parse as SSH
public keys, and only then swaps it in atomically — a GitHub outage can never
empty the file and lock you out. It also only rewrites when the content
actually changed, which matters against an SD card.

**Password authentication is still on.** Once you have confirmed key login
works, turn it off:

```bash
sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

---

## Key bindings

**`$mod` is Alt.** The uConsole's CMD key is only reachable as `Fn`+`CMD` — a
two-key chord for every window operation — so Alt wins on ergonomics.

| | |
|---|---|
| `Alt + Return` | terminal (Alacritty) |
| `Alt + Shift + d` | dmenu |
| `Alt + Shift + q` | close window |
| `Alt + h/j/k/l` or arrows | focus |
| `Alt + Shift + h/j/k/l` or arrows | move window |
| `Alt + 1..9` | switch workspace |
| `Alt + Shift + 1..9` | move window to workspace |
| `Alt + Shift + b` / `v` | split horizontal / vertical |
| `Alt + Shift + f` | fullscreen |
| `Alt + Shift + w` / `s` / `e` | tabbed / stacking / toggle split |
| `Alt + r` | resize mode (`Escape` exits) |
| `Alt + Shift + c` / `r` | reload / restart i3 |
| `Alt + Shift + x` | exit i3 |
| `Alt + Shift + o` / `p` | backlight off / restore |

### Why window management sits on `Alt+Shift`

i3 grabs `$mod` combinations globally, so every plain `Alt`+letter binding is
taken away from the shell, where readline uses Meta for word motion. i3 claims
only `Alt+h/j/k/l`, `Alt+1..9`, `Alt+r` and `Alt+Return` — costing readline
`M-l`, `M-r` and `M-<digit>`, all rare.

**Still yours in the terminal:** `Alt+b`, `Alt+f`, `Alt+d`, `Alt+t`, `Alt+u`,
`Alt+p`, `Alt+y`, `Alt+.`, `Alt+Backspace`.

---

## Power rails

AIO v2 gates each subsystem behind a GPIO-switched rail — nothing on the board
responds until its rail is driven high. This is the main difference from V1,
which had no such gating.

| Rail | GPIO | At boot |
|---|---|---|
| `SDR` | 7 | **on** |
| `USB` (internal hub) | 23 | **on** |
| `GPS` | 27 | **on** |
| `LORA` | 16 | **on** |

**SDR and USB come up together on purpose.** The RTL-SDR is an internal USB
device behind the AIO's hub, so powering the SDR rail alone will not make it
enumerate — `rtl_test` would report no supported devices found.

All four are up: GPS because chrony disciplines the clock from it, LoRa
because `meshtasticd` runs at boot.

`aiov2_ctl` tracks the current state and the boot state separately —
`aiov2_ctl SDR on` powers a rail now, while `aiov2-rails-boot.service` replays
only what `--boot-rail` recorded. The setup sets both.

### Turning one on for this session

```bash
sudo aiov2_ctl GPS on          # or LORA, SDR, USB
sudo aiov2_ctl GPS off
```

Without the vendor tool, the fallback installed here does the same:

```bash
sudo uconsole-aio-rails GPS on
sudo uconsole-aio-rails            # just the boot set (SDR + USB)
```

### Making it persistent

Edit `BOOT_RAILS` near the top of `setup.sh` and re-run `--only aio`:

```bash
local BOOT_RAILS=(SDR USB GPS)
```

A re-run never forces GPS or LoRa *off*, so a rail you switched on by hand
survives until you reboot.

### Empty waterfall in SDR++

A working device and a dead one look the same in SDR++, so check in this order:

1. **Gain starts at 0.** This is the usual cause. Raise the gain slider.
2. **Press play.** A stopped SDR++ shows an empty waterfall, not an error.
3. **Source → RTL-SDR → Refresh**, then select the device. It will not
   auto-select one that appeared after launch.
4. **Test on a strong FM broadcast** (88–108 MHz) before anything weak.
5. Check the waterfall **min/max dB** sliders have not collapsed together.

**`usb_claim_interface error -6`** means the dongle enumerated but something
already holds it — `LIBUSB_ERROR_BUSY`, not a broken device. Either SDR
software is still running, or the kernel bound it as a TV tuner:

```bash
sudo fuser -v /dev/bus/usb/*/*        # definitive: names the holding process
systemctl is-active readsb            # ADS-B decoder — the usual culprit
pgrep -a sdrpp                        # SDR++ still running?
lsmod | grep -E 'rtl28|dvb'           # DVB-T driver bound?
```

Only one process can claim the dongle. If the holder is a *service* — an ADS-B
decoder such as `readsb` or `dump1090` is the usual one — killing the process is
not enough, since it restarts and reclaims the device:

```bash
sudo systemctl disable --now readsb
sudo systemctl mask readsb            # cannot be silently re-enabled
```

Some decoders are built from source into `/usr/bin` by a package postinst
rather than installed as packages themselves, so `apt purge` will not remove
them. Masking the unit is what reliably keeps them off the dongle.

For the kernel driver, `sudo modprobe -r dvb_usb_rtl28xxu`.

The blacklist in `/etc/modprobe.d/blacklist-dvb-rtl.conf` stops it loading at
boot, but a module already loaded stays loaded until unloaded or rebooted.

Prove the hardware independently of SDR++ first:

```bash
rtl_test -t                     # tuner type, and that the device opens
timeout 10 rtl_test -s 2400000  # sample rate; watch for "lost at least N bytes"
```

Sample loss points at USB rather than software — the dongle sits behind the
AIO's internal hub, so lower the sample rate rather than chasing SDR++
settings. The antenna belongs on the pad marked **SDR**; the GPS pad is a
separate path and will not feed the dongle.

### Checking

```bash
rtl_test -t                   # SDR enumerated
pinctrl get 7                 # rail state directly
cgps -s                       # GPS, once its rail is on
```

## Meshtastic

`meshtasticd` drives the SX1262 over `/dev/spidev1.0`, created by the
`spi1-1cs` overlay. `meshtastic-ui` is the dashboard, on workspace 3.

Setting identity or config drops the client connection once the node applies
it, so the CLI reports `BrokenPipeError` even on success. Read the value back
rather than trusting the exit status.

```bash
meshtastic --host localhost --info      # node, region, modem preset
meshtastic --host localhost --nodes     # what the mesh can see
systemctl status meshtasticd
```

The node presents as **KA1PID (PID1)** on the mesh — `NODE_NAME` and
`NODE_SHORT` in `setup.sh`; the short name is capped at 4 characters.

Region is set to `US` (`LORA_REGION` in `setup.sh`). **Nothing transmits until
a region is set**, and the wrong one is a regulatory problem rather than a
config annoyance.

The Meshtastic config deliberately has **no `GPS:` block**: `gpsd` owns
`/dev/ttyS0` to feed chrony, and a second reader would fight it for the
receiver.

The CLI lives in a venv at `/opt/meshtastic-cli`, symlinked to
`/usr/local/bin/meshtastic` — there is no Debian package, and bookworm marks
the system interpreter externally-managed.

### Map tiles

`meshtastic-ui` ships with no tiles. The `osm` bundle from
`meshtastic/device-ui` is installed to `~/.portduino/default/maps/` — the
portduino emulated filesystem root — in the SD-card layout it expects,
`maps/<style>/z/x/y.png`, with `/maps` symlinked to the same tree. `MAP_STYLE`
selects `positron`, `atlas` or `dark-matter-brown` instead.

That covers **zoom 1–6 worldwide**, which is country-level rather than
streets. For detail around home, take a regional bundle from
<https://download.tiles.coalition.space/> and unzip it into
`~/.portduino/default/` keeping the same layout.

## Applications at login

i3 launches three apps and places them:

| Workspace | Application | At boot |
|---|---|---|
| 1 | SDR++Brown | launched, via `radio resume` |
| 2 | JS8Call | placement only |
| 3 | `meshtastic-ui` | placement only |

Only SDR++ starts on its own. JS8Call and the dashboard keep their placement
rules, so they land on 2 and 3 whenever started — `Alt+2` and `Alt+3` reach
those workspaces at any time, whether or not anything is on them.

`meshtasticd` does not run at boot either. **`mesh`** starts the daemon, waits
for the radio, and opens the dashboard — run it from dmenu (`Alt+Shift+d`).
It uses a sudo rule scoped to exactly `systemctl start meshtasticd`, installed
at `/etc/sudoers.d/50-meshtasticd` and validated with `visudo -c` before being
put in place. Failures surface through `i3-nagbar`, since dmenu gives it no
terminal to print to.

Two quirks the rules work around. SDR++Brown puts its version and build date
*inside* `WM_CLASS`, so the rule matches a `^sdr` prefix rather than the whole
string, which would break on every upgrade. `meshtastic-ui` sets **no
`WM_CLASS` at all**, so `assign` has nothing to match and a
`for_window [title="^Meshtastic"]` rule moves it instead.

These use `exec`, which runs only at i3 startup — `i3-msg restart` will not
relaunch them, by design, since `exec_always` would spawn duplicates on every
reload.

## Radio profiles

**`radio`** switches SDR++ between saved setups. Each profile is tuning only —
frequency, offset mode, demodulator and its settings, audio sink and volume,
RTL-SDR gain — never window layout.

```bash
radio                 # list; * marks the active profile
radio dcara           # switch
radio save            # keep the current tuning in the active profile
radio save NAME       # ... or as a new profile
radio reset NAME      # back to the shipped default
```

Switching saves the profile you are leaving first, so every profile resumes
where you left it. Saved state lives in `~/.config/rx/radio/`; the defaults
live in `radio` itself and are only starting points.

| Profile | Tuning | Ham It Up |
|---|---|---|
| `ghostnet` | 7.107 MHz USB → JS8Call | upconvert |
| `js8` | 7.078 MHz USB → JS8Call | upconvert |
| `vhf` | 146.520 MHz FM (2 m calling) | bypass |
| `dcara` | 146.920 MHz FM (DCARA) | bypass |
| `uhf` | 446.000 MHz FM (70 cm calling) | bypass |
| `noaa` | 162.550 MHz FM (NOAA weather) | bypass |
| `fm-93.3`, `fm-105.3` | broadcast WFM, 75 µs de-emphasis | bypass |
| `am-820` | 820 kHz AM | upconvert |

All of them use the Nooelec behind the Ham It Up, pinned by **serial
number**. SDR++ names a dongle by enumeration index as well, and the index
shifts as dongles come and go — an SDR++ started before the Nooelec was
plugged in opened it under the AIO dongle's label. `radio` resolves the serial
to SDR++'s current name on every switch, and i3 starts SDR++ at login through
`radio resume` for the same reason. The Ham It Up's bypass switch is the one
thing a file cannot change; `radio` says when to flip it.

SDR++ rewrites its config on exit, so `radio` closes it before touching
anything and restarts it already playing (`--autostart`).

## JS8 over the SDR

**`js8ghost`** (GhostNet, 7.107 MHz) and **`js8call`** (standard JS8,
7.078 MHz) each switch SDR++ to the matching profile, set JS8Call's dial to
agree, and open JS8Call. SDR++ stays on workspace 1 and JS8Call gets
workspace 2 to itself. `js8call` deliberately shadows `/usr/bin/js8call`, so
starting JS8Call the usual way tunes the SDR too; it always runs the real
binary by absolute path. (There is no `js8` command: `/usr/bin/js8` is
JS8Call's decoder.)

Audio goes SDR++ → the `SDR_to_JS8` PipeWire null sink
(`/etc/pipewire/pipewire.conf.d/50-sdr-js8.conf`) → JS8Call, which records
from `SDR_to_JS8.monitor`. JS8Call's input is set to that only when it has
none, so a rig's sound card picked later is kept.

The GhostNet config is receive-only: auto-reply at startup, PSK Reporter and
APRS spotting are forced off, and the window layout set by hand on this panel
is reapplied on every run.

The launchers warn if chrony is not synchronised: JS8 slots tolerate about
2 s of clock error and fail silently beyond it.

## CHIRP

Radio programming, from Debian's package. Run `chirp` (symlinked) or `chirpw`
(the actual binary name) — both appear in dmenu.

Serial cables need the `dialout` group, which the `base` section grants; it
applies after a full re-login.

Debian's build lags upstream and CHIRP gains radio support continuously, so a
recently released model may not be listed. `chirpmyradio.com` returns 403 to
scripted requests, so a current build cannot be fetched unattended — download
the wheel in a browser, then:

```bash
sudo apt remove chirp
pipx install --system-site-packages ./chirp-*.whl
```

The `chirp` package on PyPI is an unrelated bioacoustics library, not this.

## Display and power

**Screen blanking, DPMS and idle actions are disabled at every layer** — Xorg
(`/etc/X11/xorg.conf.d/10-no-blanking.conf`), logind (`IdleAction=ignore`), the
kernel console (`consoleblank=0`) and `xset` in `.xinitrc`. Nothing locks or
blanks the screen.

This is not only a battery preference: the DSI panel **wakes from DPMS to a
solid grey screen** and needs a VT switch to repaint, so blanking is actively
harmful here. Use `Alt+Shift+o` to kill the backlight deliberately — that drives
`brightnessctl` and never touches DPMS.

**Rotation** is detected at X startup rather than hardcoded. The panel is
mounted rotated and presents portrait; some images already apply the transform
at the DRM level, and rotating twice leaves the display sideways. If it comes up
sideways, edit `~/.xinitrc`.

## Fonts

`monospace` → **Atkinson Hyperlegible Mono**, `serif` and `sans-serif` →
**Atkinson Hyperlegible Next**, via `/etc/fonts/local.conf`.

Neither is packaged in Debian (`fonts-atkinson-hyperlegible` is the *original*
family only), so both come from the upstream Google Fonts repos. The install
verifies with `fc-match` rather than assuming — a silent miss would just fall
back to DejaVu and look fine.

i3 uses Mono at 12pt. The panel is ~290 DPI, so raise it in
`~/.config/i3/config` if it reads small.

---

## After the first run

A reboot is **required** — RTC, GPS and LoRa are all boot overlays and do
nothing until then.

```bash
ls /dev/rtc* && dmesg | grep -i rtc   # RTC actually bound
systemctl status uconsole-rtc         # RTC bound and seeded (automatic)
rtl_test -t                           # SDR enumerated (its rail is on by default)
cgps -s                               # GPS fix; needs a sky view
chronyc sources                       # NMEA and PPS reachable, PPS '*' once locked
claude                                # log in via browser prompt
ssh jroemer@clockworkpi.local         # from another machine
sudo tailscale up                     # unless TS_AUTHKEY was passed
```

Three things the script deliberately leaves to you:

- **Meshtastic will not transmit** until a LoRa region is set:
  `meshtastic --set lora.region US`. Transmitting on the wrong region is a
  regulatory problem, not a config annoyance.
- **JS8Call transmit** is not configured — audio out and PTT depend on the
  rig attached. Groups, grid, callsign, the dial and the SDR receive input
  *are* set, and `radio` tunes SDR++ to match (see
  [Radio profiles](#radio-profiles)).
- **`hwclock -r` alone can lie**, reporting plausible time sourced from
  elsewhere. Check `/dev/rtc*` and `dmesg`. No output at all usually means the
  CR1220 is in backwards.

## Bluetooth

`bluez` ships with the image; there's no GUI manager under i3.

```bash
sudo systemctl enable --now bluetooth
bluetoothctl
```

```
power on
agent on
default-agent
scan on                      # note the MAC
pair    AA:BB:CC:DD:EE:FF
trust   AA:BB:CC:DD:EE:FF    # without this it will not reconnect after reboot
connect AA:BB:CC:DD:EE:FF
scan off
```

`trust` is the one that matters — without it the device pairs but won't
reconnect, which reads like flaky Bluetooth. Bluetooth and Wi-Fi share one
antenna on the CM4, so expect input lag on 2.4 GHz when Wi-Fi is busy.

---

## Troubleshooting

**Grey screen after the panel powers off** — shouldn't happen now that blanking
is disabled everywhere. If it does: `Ctrl+Alt+F2` then `Ctrl+Alt+F1` forces a
repaint.

**i3 wedged, or you want the GUI off** — `Ctrl+Alt+F2` for another tty, then:

```bash
sudo rm /etc/systemd/system/getty@tty1.service.d/autologin.conf
```

**dpkg half-configured** — usually a postinst that needed hardware present:

```bash
sudo dpkg --configure -a
sudo apt --fix-broken install
```

**A section failed** — re-run just that one with `--only NAME` rather than the
whole script. Boot files always have a `.bak-<timestamp>` beside them (taken
once, on the first run — that copy is the pristine pre-script state).

**LoRa silent** — check `/etc/meshtasticd/config.d/uconsole-aio-v2.yaml` is
actually being read before debugging the radio. The drop-in only applies if the
packaged version supports `config.d`.
