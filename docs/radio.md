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
| `vhf` | 146.520 MHz FM (2 m calling) | bypass |
| `dcara` | 146.920 MHz FM (DCARA) | bypass |
| `uhf` | 446.000 MHz FM (70 cm calling) | bypass |
| `noaa` | 162.400 MHz FM (NOAA weather) | bypass |
| `fm-93.3`, `fm-105.3` | broadcast WFM, mono, 75 µs de-emphasis | bypass |
| `am-820` | 820 kHz AM | upconvert |

All of them use the Nooelec behind the Ham It Up, which rxd opens by **serial
number**, so it gets the right dongle however they enumerated. Profiles use `"offset": "auto"`:
below 30 MHz the signal goes through the Ham It Up's 125 MHz offset, above it
not, including when you retune live. `"Ham-It-Up"` or `"None"` pins it. The
Ham It Up's bypass switch is the one thing software cannot change; `radio`
says when to flip it.

## rxd

rxd runs as the systemd user unit **`rxd@NAME`**, one profile at a time, and
restarts itself on failure. It reads the profile's JSON, demodulates one
channel (USB, LSB, AM, FM, or WFM in mono) and plays it to the profile's
PipeWire sink. There is no waterfall or spectrum, no bookmarks, no recording,
and no stereo or RDS on broadcast FM. A TUI client and a browser UI are
planned.

Tune it live on two local ports; `radio save` keeps whatever you tuned:

```bash
curl -s 127.0.0.1:8073/api/status                              # HTTP JSON
curl -s -XPOST -d '{"freq":7078000}' 127.0.0.1:8073/api/tune   # freq, mode, bandwidth, gain_db, volume
rigctl -m 2 -r 127.0.0.1:4532 f                                # Hamlib NET rigctl
journalctl --user -u 'rxd@*'                                   # logs
```

Frequencies on both ports are the dial frequency.

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

JS8 profiles warn if chrony is not synchronised: JS8 slots tolerate about
2 s of clock error and fail silently beyond it.

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
