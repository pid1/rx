# Radio

This uConsole's receiver: what setup.sh installs and configures for it, the
station's profiles, JS8 and WSPR here, SDR troubleshooting, and CHIRP.

**rxd, `radio`, `rxd-tui` and the browser UI are
[pid1/rxd](https://github.com/pid1/rxd)**, a project of its own. Its README
covers how profiles, the band plan, the JS8 decoder and WSPR reporting work,
and its [docs/API.md](https://github.com/pid1/rxd/blob/main/docs/API.md) the
HTTP API. This page is what rx adds.

## What rx installs

The `sdr` section of setup.sh:

- **rxd at a pinned release:** `RXD_VERSION` and `RXD_SHA256` in setup.sh.
  It downloads `rxd-X.Y.Z.tar.gz` from pid1/rxd's GitHub release, checks its
  SHA-256, keeps it in `/var/cache/rx/`, and runs its `install.py --prefix
  /usr/local --user jroemer`. That installs rxd, `radio`, `rxd-tui`, the
  browser UI and the `rxd@.service` user unit, and, as the desktop user,
  JS8's JSC word table and the callsign database for the map. A re-run with
  nothing new changes nothing; a run without network uses the cached tarball
  (and `maint` the cached setup.sh). A new rxd release is a PR bumping the two
  lines.
- **The station file**, `/etc/rxd/station.json` (rxd's
  [docs/station.md](https://github.com/pid1/rxd/blob/main/docs/station.md)),
  rewritten on every run from setup.sh's config: callsign KA1PID at EM13lc,
  the Nooelec NESDR SMArt v5 by its serial (57818712, so rxd gets the right
  dongle however USB enumerated it), the Ham It Up (125 MHz, below 30 MHz,
  with its physical switch), the built-in speaker, and the local profiles
  below.
- **`/etc/rxd/rxd.env`**, written once and then left alone:
  `RXD_HTTP=0.0.0.0:8073`, so the LAN and tailnet can reach the browser UI.
- **`radio mesh`**, `radio meshtastic` and `radio meshcore`: rx's
  `/usr/local/bin/radio-mesh` (and two links to it), which `radio` runs as an
  extension. The commands are in the [README](../README.md#radio-mesh-the-lora-mesh).
- **Around rxd:** the firewall rule for port 8073
  ([maintenance.md](maintenance.md#firewall)), `wsjtx` for `wsprd`, pinned to
  Debian's build (the `ham` section), chrony and GPS for the clock, the DVB-T
  blacklist, and the offline map tiles (the `lora` section).

## This station's profiles

rxd's own profiles are the band plan (`js8-160m` … `js8-2m`, `wspr-2190m` …
`wspr-2m`; 40 m's are `js8` and `wspr`), `ghostnet`, `vhf`, `uhf` and
`noaa`. The station file adds the local ones.

| Profile | Tuning | Ham It Up |
|---|---|---|
| `ghostnet` | 7.107 MHz USB, JS8 decoded (GhostNet) | upconvert |
| `js8` | 7.078 MHz USB, JS8 decoded | upconvert |
| `wspr` | 7.0386 MHz USB, WSPR decoded and reported to WSPRnet | upconvert |
| `js8-160m` … `js8-2m` | every band's JS8 dial | upconvert, but 6 m and 2 m bypass |
| `wspr-2190m` … `wspr-2m` | every band's WSPR dial | upconvert, but 6 m and 2 m bypass |
| `vhf` | 146.520 MHz FM (2 m calling) | bypass |
| `dcara` | 146.920 MHz FM (DCARA), from the station file | bypass |
| `uhf` | 446.000 MHz FM (70 cm calling) | bypass |
| `noaa` | 162.550 MHz FM (NOAA weather; the strongest of the seven at EM13) | bypass |
| `fm-93.3`, `fm-105.3` | broadcast WFM, mono, from the station file | bypass |
| `am-820` | 820 kHz AM, from the station file | upconvert |

To add or change a local profile, edit `STATION` in setup.sh's `sdr`
section; `radio save NAME` keeps a tuning without it, in
`~/.config/rxd/radio/NAME.json`.

**The Ham It Up's switch** is the one thing software can't change. Below
30 MHz the signal goes through its 125 MHz offset, above it not. `radio`, the
browser UI and `rxd-tui` say when to flip it, and the band plan keeps Auto to
the side it's on unless *Allow, I'll flip it* is set.

## JS8 and WSPR here

- **WSPR** spots go to WSPRnet as KA1PID at EM13lc, from the station file.
  `POST /api/v1/tune {"wspr_report": false}`, or the Digital view, turns it
  off.
- **JS8's JSC word table** is JS8Call's (GPL-3), so neither rx nor rxd
  carries it: rxd's installer fetches it at a pinned commit and checks it.
- **The clock:** both modes need it within about 2 s. Here chrony keeps it
  from GPS and the RTC without a network ([hardware.md](hardware.md)).

## The LAN can tune it

HTTP listens on every interface (`RXD_HTTP=0.0.0.0:8073` in
`/etc/rxd/rxd.env`), and the [firewall](maintenance.md#firewall) admits port
8073 from private addresses and Tailscale only. There is no authentication:
anyone on the LAN can tune the radio. To keep it to the device, set
`RXD_HTTP=127.0.0.1:8073` there and run `systemctl --user restart 'rxd@*'`;
re-running setup keeps the change.

**Why not SDR++.** SDR++Brown used about 220% CPU and leaked memory until the
kernel killed it — twice on 2026-11-05, at about 3.5 GB each time, after one
to one and a half hours. rxd decoded JS8 live at about 21% of one core and
94 MB.

## When rxd is silent

Check in this order:

1. **The unit failed.** `systemctl --user status 'rxd@*'` and
   `journalctl --user -u 'rxd@*'` say why — usually the dongle or the sink
   could not be opened.
2. **The dongle is busy** (below): another program, or a second rxd, holds it.
3. **The Ham It Up switch.** HF profiles need *upconvert*, VHF and up need
   *bypass*; in the wrong position the band is just noise.
4. **Test on a strong FM broadcast** (`radio fm-105.3`) before anything weak,
   and raise `gain_db` through `/api/v1/tune` if it is quiet.

**`usb_claim_interface error -6`** means the dongle enumerated but something
already holds it — `LIBUSB_ERROR_BUSY`, not a broken device. Either SDR
software is still running, or the kernel bound it as a TV tuner:

```bash
sudo fuser -v /dev/bus/usb/*/*        # definitive: names the holding process
systemctl is-active readsb            # ADS-B decoder — the usual culprit
systemctl --user list-units 'rxd@*'   # more than one rxd?
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

Prove the hardware independently of rxd first:

```bash
rtl_test -t                     # tuner type, and that the device opens
timeout 10 rtl_test -s 2400000  # sample rate; watch for "lost at least N bytes"
```

Sample loss points at USB rather than software — the dongle sits behind the
AIO's internal hub, so suspect the hub rather than rxd. The antenna belongs
on the pad marked **SDR**; the GPS pad is a separate path and will not feed
the dongle.

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
