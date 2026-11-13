# Hardware

The HackerGadgets AIO v2: power rails, time, the LoRa mesh and Bluetooth.

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

All four are up: GPS because chrony disciplines the clock from it, LoRa so
the radio is ready when a mesh is started. Powering the LoRa rail makes
`aiov2_ctl` start `meshtasticd`; rx's units refuse that start (see
[LoRa mesh](#lora-mesh)), so no mesh runs until you ask for one.

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
| PCF85063A RTC | seconds a day | keeps time across power-off **only with a CR1220 fitted** |
| `fake-hwclock` | last shutdown | fallback for a flat CR1220 |
| NTP pool | milliseconds | whenever there is a network |

The kernel probes the RTC before `aiov2-rails-boot` has powered the AIO board,
gets no answer ("RTC chip is not present", -121) and gives up. `uconsole-rtc`
binds it once the rails are up and sets the system clock from it before
chrony starts; run against a synchronised clock it seeds the chip instead, so
there is no manual `hwclock -w` step.

Without a working CR1220 the chip loses its time whenever the board loses
power, including across a reboot: `uconsole-rtc` then reports "RTC holds no
valid time" and the clock starts from `fake-hwclock`'s last hourly save, up to
an hour behind, until GPS or NTP corrects it.

chronyd will not start with a refclock it cannot open, so the PPS line is
not in the static config. `uconsole-pps` runs before each chrony start and
writes it to `/run/uconsole-pps/pps.conf` only when the kernel has a GPIO PPS
source. If `pps-gpio` did not bind (`dmesg | grep -i pps`), chrony still
runs and keeps time from NMEA and, with a network, the NTP pool. A udev rule
re-runs the check when a PPS source appears later and restarts chrony to add
it.

```bash
chronyc sources               # NMEA and PPS reachable, PPS '*' once locked
journalctl -u chrony | grep uconsole-pps   # which PPS device, or why none
systemctl status uconsole-rtc # chip bound, and which way time went
cgps -s                       # GPS fix; needs a sky view
```

## LoRa mesh

The AIO's SX1262 runs either **Meshtastic** or **MeshCore**, one at a time,
on the settings the North Texas community uses
([NTX Mesh](https://ntxmesh.com/join/)). `radio meshtastic` and
`radio meshcore` choose the network; `radio mesh …` works on whichever is
active. The command reference is in the [README](../README.md#radio-mesh-the-lora-mesh).

### North Texas defaults

| | Meshtastic | MeshCore |
|---|---|---|
| Radio | `LONG_FAST`, slot 20 (906.875 MHz) | 910.525 MHz, 62.5 kHz, SF 7, CR 5, 20 dBm |
| Role | `CLIENT` (NTX: not `ROUTER`), hop limit 3 | companion |
| Announces | node info every 3 h | one flood advert per start |
| Telemetry | device 3 h, environment 1 h | — |
| Position | never sent (`gps_mode NOT_PRESENT`) | never sent |
| MQTT | off, and MQTT-relayed packets ignored | — |

Every metroplex county runs `LONG_FAST` except Wise (Short Slow), per NTX
Mesh's county map. The slot is pinned to 20 rather than left at 0, which
would hash the primary channel's name: joining a private channel as primary
would otherwise move the node off the regional frequency. NTX also suggests a
60 s smart-position minimum; the firmware clamps it to 300 s, and with no
position sent it does not matter.

`radio meshtastic` applies these through the node's own API, writing only
what differs. A config write makes the node reboot itself about 7 s later and
can lose writes that land around it, so it reads back after the reboot and
retries what did not stick. The node presents as **KA1PID (PID1)** —
`NODE_NAME` and `NODE_SHORT` in `setup.sh`, written to `/etc/rx/mesh.conf`
for `radio`; the short name is capped at 4 characters.

MeshCore's radio settings live in `/etc/raspberrypimc/companion.env` and are
applied at every start; the client cannot change them. Only the name is set
through the client.

### One radio, two daemons

| | Meshtastic | MeshCore |
|---|---|---|
| Daemon | `meshtasticd` (OBS repo) | MeshCoreRPI companion, pinned `.deb` |
| Config | `/etc/meshtasticd/rx.yaml` | `/etc/raspberrypimc/companion.env` |
| Client | `meshtastic` (`/opt/meshtastic-cli`) | `meshcore-cli` (`/opt/meshcore-cli`) |
| Port | 4403 API, 443 web, all interfaces but firewalled | 5000, loopback only |

**`rx-mesh`** (`/usr/local/sbin`, run through one sudo rule) is the only way
either starts. Each unit carries `ExecCondition=test -e /run/rx/mesh/<network>`,
and `/run` is empty at every boot, so nothing else can start them — not boot,
and not `aiov2_ctl`, which starts `meshtasticd` every time it powers the LoRa
rail. Starting one stops the other first.

MeshCoreRPI drives the radio's BUSY, RESET and IRQ lines through sysfs and
leaves them exported when it stops; `meshtasticd` then cannot claim them
("cannot claim pin GPIO26"). Its unit's stop hook, `rx-mesh release-pins`,
unexports them.

`meshtasticd` runs from its own config, started with `--config` by a unit
drop-in, rather than the packaged `config.yaml`: the AIO metapackage adds
`GPS: SerialPath: /dev/ttyS0` there, a `config.d` drop-in cannot remove a key,
and `gpsd` owns that port to feed chrony. The state directory is unchanged, so
the node keeps its identity and keys.

MeshCore runs on [MeshCoreRPI](https://github.com/engperini/MeshCoreRPI), a
port of the MeshCore firmware to the Pi (MIT). It is a young fork, so it is
pinned to one release and checked against that release's SHA-256; bump
`MC_VER` and `MC_SHA` in `setup.sh` together. Its 1.8 V TCXO default and its
handling of the 512 sysfs GPIO offset were checked in its source. Its web GUI
(unauthenticated, on `0.0.0.0:8080` by default) and BLE bridge are off.

`meshtasticd` listens on every interface without authentication, its API on
4403 and its web client on 443, as the package ships. The
[firewall](maintenance.md#firewall) drops both from the network, so only this
device can reach them; `radio` talks to the node over loopback.

### Private channels

`radio mesh join` adds a channel on the node itself: a Meshtastic channel URL
or QR link (`https://meshtastic.org/e/#…`), or a MeshCore channel name and
key. The keys stay on the node and never enter this repository, which is
public. Ask the channel's members for the link; NTX Mesh shares keys by
direct message or in person.

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
