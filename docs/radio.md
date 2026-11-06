# Radio

`radio` profiles and the rxd receiver, JS8 and WSPR decoding, SDR
troubleshooting, and CHIRP.

## Radio profiles

**`radio`** is one command per setup. `radio NAME` stops whatever is running
and brings NAME up ready to listen: every profile starts **rxd**, a headless
receiver, tuned and playing. On a JS8 or WSPR profile rxd also decodes that
mode itself. Profile names tab-complete.

```bash
radio                 # list; * marks the active profile
radio fm-105.3        # switch (Tab completes the name)
radio off             # stop rxd
radio resume          # bring the active profile back (i3 runs this at login)
radio save            # keep the current tuning in the active profile
radio save NAME       # ... or as a new profile
radio reset NAME      # back to the shipped default
radio show NAME       # print a profile
radio help
```

Each profile is tuning only — the dial frequency, demodulator and its
settings, audio sink and volume, RTL-SDR gain, and what rxd decodes
(`"decoder": "js8"` or `"wspr"`). The decoders take the audio before the
volume, so the volume is only the speaker's. Switching saves the profile you
are leaving first, so every profile resumes where you left it. Saved state
lives in `~/.config/rx/radio/*.json`; the defaults live in `radio` itself and
are only starting points.

| Profile | Tuning | Ham It Up |
|---|---|---|
| `ghostnet` | 7.107 MHz USB, JS8 decoded (GhostNet) | upconvert |
| `js8` | 7.078 MHz USB, JS8 decoded | upconvert |
| `wspr` | 7.0386 MHz USB, WSPR decoded and reported to WSPRnet | upconvert |
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
plan may pick it). The dials are the usual JS8 and WSPR ones, checked
2026-11-06 against JS8Call-improved 3.0.3's default list
(`JS8_Main/FrequencyList.cpp`) and WSJT-X's (`models/FrequencyList.cpp`).

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

- Older JS8 lists have 1.842 on 160 m and no 60 m; the current one moved
  160 m to 1.8435 and added 5.363.
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
  with the sun at the station's grid (day, gray line or night, from
  `RXD_GRID`) and with what rxd has heard on each band at this hour.
- **Without internet** it scans the bands it hasn't heard at this hour, at
  least two WSPR slots or the scan time each (6 minutes by default), keeps
  the counts, and then picks the band that heard the most. What it hears,
  per profile and UTC hour, is kept in `~/.local/share/rxd/bands.json` and
  counts for half as much every 14 days. Spot counts outweigh the
  conditions after a single good look.
- **Bands:** every band is enabled by default, 2190 m and 630 m included
  (Win's call, 2026-11-06: no assumptions about antennas); turn off the ones
  without an antenna under *Bands and timing*.
- **Ham It Up:** Auto only uses bands on the side the switch is on now (the
  side the running profile needs), unless *Allow, I'll flip it* is set: on
  UPCONVERT that is 2190 m to 10 m, on BYPASS 6 m and 2 m.
- **First start:** Auto goes straight to the best-scoring band.
- **Switching** goes through `radio NAME`. A switch waits for a WSPR slot's decode to finish,
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
HTTP API. `radio save` keeps whatever you tuned.

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
curl -s 127.0.0.1:8073/api/js8                                 # JS8 messages (after=SEQ for new ones)
journalctl --user -u 'rxd@*'                                   # logs
```

Frequencies are the dial frequency: on USB, a signal 1500 Hz up in the audio
is 1500 Hz above it.

**The LAN can tune it.** HTTP listens on every interface
(`RXD_HTTP=0.0.0.0:8073` in `/etc/rx/rxd.env`), and the
[firewall](maintenance.md#firewall) admits port 8073 from private addresses
and Tailscale only. There is no authentication: anyone on the LAN can tune
the radio. To keep it to the device, set `RXD_HTTP=127.0.0.1:8073` there and
run `systemctl --user restart 'rxd@*'`; re-running setup keeps the change.

**Why not SDR++.** SDR++Brown used about 220% CPU and leaked memory until the
kernel killed it — twice on 2026-11-05, at about 3.5 GB each time, after one
to one and a half hours. rxd decoded JS8 live at about 21% of one core and
94 MB.

## JS8

**`radio ghostnet`** (7.107 MHz) and **`radio js8`** (7.078 MHz), and the
band plan's `js8-BAND` profiles, have rxd decode JS8 itself, with its own
decoder (`/usr/local/lib/rxd/js8.py`; how it works and how well, in
[rxd/README.md](../rxd/README.md#js8-decoded-by-rxd-rxdjs8py)). Receive only.

- **Messages** show in the Digital view of the browser UI and of `rxd-tui`,
  and come from `GET /api/js8`. They are logged in JS8's usual DIRECTED.TXT
  form in `~/.local/share/rxd/js8/`, with every frame in ALL.TXT, and
  reloaded when rxd restarts.
- **Speeds:** normal, fast and slow by default; `"js8_submodes"` in a
  profile picks others (`turbo` too).
- **Audio:** the speaker plays the band quietly (volume 0.2), and the browser
  UI and `rxd-tui -l` can listen, like any profile. The decoder takes the
  audio before the volume, so muting doesn't stop it.
- **Compressed free text** needs JS8's JSC word table, which rx doesn't
  ship. Without it, those words show as `……`; heartbeats, CQs, directed
  commands, SNR reports, callsigns and grids all decode.

JS8 and WSPR profiles warn if chrony is not synchronised: both modes'
slots tolerate about 2 s of clock error and fail silently beyond it.

## WSPR

**`radio wspr`** (7.0386 MHz, WSPR's 40 m dial) has rxd decode WSPR itself;
the WSJT-X application is not involved. rxd records each two-minute slot
from its own audio, from the even minute, and runs `wsprd` from Debian's
`wsjtx` package on it. The uConsole's speaker stays silent (volume 0), but the
browser UI and `rxd-tui -l` can still listen.

- **Spots** show in the Digital view of the browser UI and of `rxd-tui`, and
  come from `GET /api/wspr`. wsprd's own log, `ALL_WSPR.TXT`, is kept in
  `~/.local/share/rxd/wspr/` and reloaded when rxd restarts.
- **Reporting** to WSPRnet is on by default. rxd posts each spot the way
  WSJT-X does, plus a heartbeat for a slot with none, so the station shows
  as on the air.
  - The callsign and grid are `RXD_CALL` and `RXD_GRID` in
    `/etc/rx/rxd.env` (setup writes KA1PID and EM13lc). Without both, rxd
    decodes but doesn't report, and its status says why.
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
3. **The Ham It Up switch.** HF profiles need *upconvert*, VHF and up need
   *bypass*; in the wrong position the band is just noise.
4. **Test on a strong FM broadcast** (`radio fm-105.3`) before anything weak,
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
