# Radio

`radio` profiles and the rxd receiver, JS8 receive through the SDR, SDR
troubleshooting, and CHIRP.

## Radio profiles

**`radio`** is one command per setup. `radio NAME` closes whatever is running
and brings NAME up ready to listen: every profile starts **rxd**, a headless
receiver, tuned and playing; a JS8 profile also starts JS8Call on the matching
dial, and any other profile closes JS8Call. Profile names tab-complete.

```bash
radio                 # list; * marks the active profile
radio fm-105.3        # switch (Tab completes the name)
radio off             # stop rxd and close JS8Call
radio resume          # bring the active profile back (i3 runs this at login)
radio save            # keep the current tuning in the active profile
radio save NAME       # ... or as a new profile
radio reset NAME      # back to the shipped default
radio show NAME       # print a profile
radio help
```

Each profile is tuning only — frequency, demodulator and its settings, audio
sink and volume, RTL-SDR gain. Switching saves the profile you are leaving
first, so every profile resumes where you left it. Saved state lives in
`~/.config/rx/radio/*.json`; the defaults live in `radio` itself and are only
starting points. `vfo_offset`, left in older profiles, is no longer used.

| Profile | Tuning | Ham It Up |
|---|---|---|
| `ghostnet` | 7.107 MHz USB → JS8Call | upconvert |
| `js8` | 7.078 MHz USB → JS8Call | upconvert |
| `wspr` | 7.0386 MHz USB → rxd's WSPR decoder, reported to WSPRnet | upconvert |
| `js8-160m` … `js8-2m` | every band's JS8 dial (table below) | upconvert, but 6 m and 2 m bypass |
| `wspr-2190m` … `wspr-2m` | every band's WSPR dial (table below) | upconvert, but 6 m and 2 m bypass |
| `vhf` | 146.520 MHz FM (2 m calling) | bypass |
| `dcara` | 146.920 MHz FM (DCARA) | bypass |
| `uhf` | 446.000 MHz FM (70 cm calling) | bypass |
| `noaa` | 162.550 MHz FM (NOAA weather) | bypass |
| `fm-93.3`, `fm-105.3` | broadcast WFM, mono, 75 µs de-emphasis | bypass |
| `am-820` | 820 kHz AM | upconvert |

All of them use the Nooelec behind the Ham It Up, which rxd opens by **serial
number**, so it gets the right dongle however they enumerated. Profiles use `"offset": "auto"`:
below 30 MHz the signal goes through the Ham It Up's 125 MHz offset, above it
not, including when you retune live. `"Ham-It-Up"` or `"None"` pins it. The
Ham It Up's bypass switch is the one thing software cannot change; `radio`
says when to flip it.

### JS8 and WSPR on every band

One JS8 and one WSPR profile per band, on the standard dial (USB). 40 m keeps
its old names, `js8` and `wspr`; `js8-40m` and `wspr-40m` are aliases.
`radio --json` gives each profile's `band` and `plan` (whether rxd's band
plan may pick it). Checked 2026-11-06 against JS8Call-improved 3.0.3's
default list (`JS8_Main/FrequencyList.cpp`) and WSJT-X's
(`models/FrequencyList.cpp`).

| Band | JS8 dial, MHz | WSPR dial, MHz |
|---|---|---|
| 2190 m | — | 0.136000 |
| 630 m | — | 0.474200 |
| 160 m | 1.843500 | 1.836600 |
| 80 m | 3.578000 | 3.568600 |
| 60 m | 5.363000 | 5.364700 |
| 40 m | 7.078000 (`js8`) | 7.038600 (`wspr`) |
| 30 m | 10.130000 | 10.138700 |
| 20 m | 14.078000 | 14.095600 |
| 17 m | 18.104000 | 18.104600 |
| 15 m | 21.078000 | 21.094600 |
| 12 m | 24.922000 | 24.924600 |
| 10 m | 28.078000 | 28.124600 |
| 6 m | 50.318000 | 50.293000 |
| 2 m | 144.178000 | 144.489000 |

- JS8Call 2.2 (Debian's, on the uConsole) still lists 1.842 on 160 m and has
  no 60 m; the current list moved 160 m to 1.8435 and added 5.363.
- WSJT-X lists no 60 m WSPR. 5.3647 is where WSPRnet's 60 m spots are: in
  the first week of November 2026 wspr.live had about 552,000 there and
  190,000 on the older 5.2872.
- 6 m and 2 m need the Ham It Up on BYPASS; everything else goes through
  UPCONVERT, 2190 m and 630 m included.

### Band plan

rxd chooses the JS8 or WSPR band itself when its **band plan** is on Auto
(the Digital view of the browser UI, `a` in `rxd-tui`, or
`POST /api/bands {"plan": "auto"}`). On Manual it stays put. Picking a band
yourself, from a picker or with `radio NAME`, sets it to Manual.

- **With internet** it ranks the bands by N0NBH's calculated band conditions
  from hamqsl.com (SFI, A and K, day and night per band group), NOAA SWPC's
  solar flux and K index if hamqsl doesn't answer. It fetches at most every
  45 minutes, with a 10 s timeout, and caches them on disk. It combines them
  with the sun at the station's grid (day, gray line or night, from JS8Call's
  `MyGrid` or `RXD_GRID`) and with what rxd has heard on each band at this
  hour.
- **Without internet** it scans the bands it hasn't heard at this hour, at
  least two WSPR slots or the scan time each (6 minutes by default), keeps
  the counts, and then picks the band that heard the most. What it hears,
  per profile and UTC hour, is kept in `~/.local/share/rxd/bands.json` and
  counts for half as much every 14 days. Spot counts outweigh the
  conditions after a single good look.
- **Ham It Up:** Auto only uses bands on the side the switch is on now (the
  side the running profile needs), unless *Allow, I'll flip it* is set.
  The default bands are 160 m to 10 m on UPCONVERT, or 6 m and 2 m on
  BYPASS.
- **Switching** goes through `radio NAME`, so a JS8 band starts JS8Call and
  a WSPR band closes it. A switch waits for a WSPR slot's decode to finish,
  and stays put unless another band scores 15 % better. The re-check
  interval is 30 minutes by default.
- **State:** settings in `~/.config/rx/bands.json`; where the plan is
  (scanning, holding, why) in `~/.local/share/rxd/bandplan.json`; the last
  conditions in `~/.local/share/rxd/conditions.json`. rxd restarts on every
  switch and reads them back. `RXD_BANDS=off` in `/etc/rx/rxd.env` turns the
  band plan off.

## rxd

rxd runs as the systemd user unit **`rxd@NAME`**, one profile at a time, and
restarts itself on failure. It reads the profile's JSON, demodulates one
channel (USB, LSB, AM, FM, or WFM in mono) and plays it to the profile's
PipeWire sink. There is no waterfall or spectrum, no bookmarks, no recording,
and no stereo or RDS on broadcast FM.

Tune it live from **`rxd-tui`** in a terminal, from the **browser UI** at
`http://<uconsole>:8073/` on any device on the LAN or tailnet, or over its
two ports. `radio save` keeps whatever you tuned.

| `rxd-tui` key | Does |
|---|---|
| `←` / `→` | Tune down / up by one step |
| `↑` / `↓` | Larger / smaller step |
| `f` | Type a frequency |
| `m` | Next mode |
| `[` / `]` | Narrower / wider bandwidth |
| `g` / `G` | Gain down / up |
| `-` / `+` | Volume down / up |
| `?` | Help |
| `q` | Quit (rxd keeps playing) |

```bash
curl -s 127.0.0.1:8073/api/status                              # HTTP JSON
curl -s -XPOST -d '{"freq":7078000}' 127.0.0.1:8073/api/tune   # freq, mode, bandwidth, gain_db, volume
rigctl -m 2 -r 127.0.0.1:4532 f                                # Hamlib NET rigctl
journalctl --user -u 'rxd@*'                                   # logs
```

Frequencies on both ports are the dial frequency.

**The LAN can tune it.** HTTP listens on every interface
(`RXD_HTTP=0.0.0.0:8073` in `/etc/rx/rxd.env`), and the
[firewall](maintenance.md#firewall) admits port 8073 from private addresses
and Tailscale only. There is no authentication: anyone on the LAN can tune
the radio. To keep it to the device, set `RXD_HTTP=127.0.0.1:8073` there and
run `systemctl --user restart 'rxd@*'`; re-running setup keeps the change.
Rigctl is always loopback only.

**Why not SDR++.** SDR++Brown used about 220% CPU and leaked memory until the
kernel killed it — twice on 2026-11-05, at about 3.5 GB each time, after one
to one and a half hours. rxd decoded JS8 live at about 21% of one core and
94 MB.

## JS8 over the SDR

**`radio ghostnet`** (7.107 MHz) and **`radio js8`** (7.078 MHz) are the
JS8 profiles: whatever is running closes, rxd comes up tuned, and JS8Call
starts on the matching dial on workspace 2. Plain `js8call` is still just
JS8Call, with no retuning.

Audio goes rxd → the `SDR_to_JS8` PipeWire null sink
(`/etc/pipewire/pipewire.conf.d/50-sdr-js8.conf`) → JS8Call, which records
from `SDR_to_JS8.monitor`. JS8Call's input is set to that only when it has
none, so a rig's sound card picked later is kept.

The GhostNet config is receive-only: auto-reply at startup, PSK Reporter and
APRS spotting are forced off, and the window layout set by hand on this panel
is reapplied on every run.

JS8 and WSPR profiles warn if chrony is not synchronised: both modes'
slots tolerate about 2 s of clock error and fail silently beyond it.

## WSPR

**`radio wspr`** (7.0386 MHz, WSPR's 40 m dial) has rxd decode WSPR itself;
JS8Call closes and WSJT-X is not involved. rxd records each two-minute slot
from its own audio, from the even minute, and runs `wsprd` from Debian's
`wsjtx` package on it. The uConsole's speaker stays silent (volume 0), but the
browser UI and `rxd-tui -l` can still listen.

- **Spots** show in the Digital view of the browser UI and of `rxd-tui`, and
  come from `GET /api/wspr`. wsprd's own log, `ALL_WSPR.TXT`, is kept in
  `~/.local/share/rxd/wspr/` and reloaded when rxd restarts.
- **Reporting** to WSPRnet is on by default. rxd posts each spot the way
  WSJT-X does, plus a heartbeat for a slot with none, so the station shows
  as on the air.
  - The callsign and grid are JS8Call's `MyCall` and `MyGrid`, unless
    `RXD_CALL` and `RXD_GRID` are set in `/etc/rx/rxd.env`. Without both, rxd
    decodes but doesn't report, and says why.
  - Spots that can't be sent (no internet) wait, up to 2000 of them, and go
    with the next slot.
  - Turn reporting off from the Digital view, or with
    `POST /api/tune {"wspr_report": false}`; `radio` saves the choice with
    the profile.
- **wsjtx** is pinned to Debian's build (`/etc/apt/preferences.d/rx-wsjtx`).
  The ClockworkPi repo's 2.7.0 conflicts with Debian's `wsjtx-data` and
  would fail to install or upgrade.

## When rxd is silent

Check in this order:

1. **The unit failed.** `systemctl --user status 'rxd@*'` and
   `journalctl --user -u 'rxd@*'` say why — usually the dongle or the sink
   could not be opened.
2. **The dongle is busy** (below): another program, or a second rxd, holds it.
3. **No audio in JS8Call.** The `SDR_to_JS8` sink must exist, with rxd
   playing into it and JS8Call reading its monitor. `pw-link -l` lists the
   links; then check JS8Call's audio input.
4. **The Ham It Up switch.** HF profiles need *upconvert*, VHF and up need
   *bypass*; in the wrong position the band is just noise.
5. **Test on a strong FM broadcast** (`radio fm-105.3`) before anything weak,
   and raise `gain_db` through `/api/tune` if it is quiet.

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
