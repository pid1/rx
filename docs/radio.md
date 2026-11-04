# Radio

SDR++ profiles, JS8 receive through the SDR, SDR troubleshooting, and CHIRP.

## Radio profiles

**`radio`** is one command per setup. `radio NAME` closes whatever is running
and brings NAME up ready to listen: a JS8 profile starts SDR++ tuned and
playing *and* JS8Call on the matching dial; any other profile starts SDR++
alone and closes JS8Call. Profile names tab-complete.

```bash
radio                 # list; * marks the active profile
radio fm-105.3        # switch (Tab completes the name)
radio off             # close SDR++ and JS8Call
radio resume          # bring the active profile back (i3 runs this at login)
radio save            # keep the current tuning in the active profile
radio save NAME       # ... or as a new profile
radio reset NAME      # back to the shipped default
radio help
```

Each profile is tuning only — frequency, offset mode, demodulator and its
settings, audio sink and volume, RTL-SDR gain — never window layout.
Switching saves the profile you are leaving first, so every profile resumes
where you left it. Re-running the profile already up just brings it to the
front. Saved state lives in `~/.config/rx/radio/`; the defaults
live in `radio` itself and are only starting points.

| Profile | Tuning | Ham It Up |
|---|---|---|
| `ghostnet` | 7.107 MHz USB → JS8Call | upconvert |
| `js8` | 7.078 MHz USB → JS8Call | upconvert |
| `vhf` | 146.520 MHz FM (2 m calling) | bypass |
| `dcara` | 146.920 MHz FM (DCARA) | bypass |
| `uhf` | 446.000 MHz FM (70 cm calling) | bypass |
| `noaa` | 162.400 MHz FM (NOAA weather) | bypass |
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
anything and restarts it already playing (`--autostart`). It shows
workspace 1 while SDR++ starts: SDR++ blocks in window creation until its
window is visible, so started onto a workspace that is not on screen it hangs
for good behind a black window. It then checks SDR++ really opened the dongle,
and restarts it once if not.

Every switch also sets SDR++'s FFT to its minimum — 1024 points at one frame
a second. SDR++ computes the FFT even with the FFT and waterfall hidden, and
then it feeds only the signal meter. That cut its memory from 1–2 GB to about
150 MB; CPU barely moved, since demodulation and the GUI dominate it.

## JS8 over the SDR

**`radio ghostnet`** (7.107 MHz) and **`radio js8`** (7.078 MHz) are the
JS8 profiles: whatever is running closes, and SDR++ comes up tuned on
workspace 1 with JS8Call on the matching dial on workspace 2. Plain
`js8call` is still just JS8Call, with no retuning.

Audio goes SDR++ → the `SDR_to_JS8` PipeWire null sink
(`/etc/pipewire/pipewire.conf.d/50-sdr-js8.conf`) → JS8Call, which records
from `SDR_to_JS8.monitor`. JS8Call's input is set to that only when it has
none, so a rig's sound card picked later is kept.

The GhostNet config is receive-only: auto-reply at startup, PSK Reporter and
APRS spotting are forced off, and the window layout set by hand on this panel
is reapplied on every run.

JS8 profiles warn if chrony is not synchronised: JS8 slots tolerate about
2 s of clock error and fail silently beyond it.

## Empty waterfall in SDR++

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
