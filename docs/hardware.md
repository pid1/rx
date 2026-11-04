# Hardware

The HackerGadgets AIO v2: power rails, time, Meshtastic and Bluetooth.

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

### Checking

```bash
rtl_test -t                   # SDR enumerated
pinctrl get 7                 # rail state directly
cgps -s                       # GPS, once its rail is on
```

## Time

JS8 decodes nothing once the clock is more than about 2 s off, and off-grid
there is no network to set it from, so time comes from the hardware.

| Source | Accuracy | Notes |
|---|---|---|
| GPS PPS (`/dev/pps0`, GPIO 6) | microseconds | needs a fix; chrony locks it to NMEA's seconds |
| GPS NMEA via `gpsd` (SHM 0) | ~100 ms | coarse time for PPS to lock to |
| PCF85063A RTC | seconds a day | keeps time across power-off on its CR1220 |
| `fake-hwclock` | last shutdown | fallback for a flat CR1220 |
| NTP pool | milliseconds | whenever there is a network |

The kernel probes the RTC before `aiov2-rails-boot` has powered the AIO board,
gets no answer ("RTC chip is not present", -121) and gives up. `uconsole-rtc`
binds it once the rails are up and sets the system clock from it before
chrony starts; run against a synchronised clock it seeds the chip instead, so
there is no manual `hwclock -w` step.

```bash
chronyc sources               # NMEA and PPS reachable, PPS '*' once locked
systemctl status uconsole-rtc # chip bound, and which way time went
cgps -s                       # GPS fix; needs a sky view
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
