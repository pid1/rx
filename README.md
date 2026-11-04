<!-- Hidden until a hero image exists. Add it, restore this line, then delete this note.
<p align="center"><img src="docs/screenshots/uconsole.jpg" alt="The uConsole running SDR++ and JS8Call" width="880"></p>

Asset to create: docs/screenshots/uconsole.jpg. A photo of the uConsole (or a
1280x720 screenshot) with JS8Call decoding on workspace 2. Crop out the status
bar's Wi-Fi name.
-->

<p align="center">
  <a href="LICENSE"><img alt="license: BSD 3-Clause" src="https://img.shields.io/badge/license-BSD%203--Clause-15191f"></a>
  <a href="https://github.com/pid1/rx/actions/workflows/semgrep.yml"><img alt="semgrep" src="https://img.shields.io/github/actions/workflow/status/pid1/rx/semgrep.yml?label=semgrep&color=15191f"></a>
  <a href="docs/install.md#what-it-assumes"><img alt="hardware: uConsole CM4 + AIO v2" src="https://img.shields.io/badge/hardware-uConsole%20CM4%20%2B%20AIO%20v2-15191f"></a>
</p>

<p align="center">
  <a href="docs/install.md">Install</a> •
  <a href="docs/radio.md">Radio</a> •
  <a href="docs/hardware.md">Hardware</a> •
  <a href="docs/desktop.md">Desktop</a> •
  <a href="docs/maintenance.md">Maintenance</a>
</p>

<p align="center"><em>Receive-only comms and situational awareness, in a case.</em></p>

## What is rx?

rx is one script that turns a ClockworkPi uConsole into a field receiver. It
targets a **CM4 Lite** running **Rex's Debian Bookworm image** with the
**HackerGadgets AIO v2** board, and sets up the SDR, LoRa mesh, GPS-disciplined
time and an i3 desktop sized for the 5" panel.

It is also how the device is maintained. Every step is idempotent, so the same
script that provisions a blank card re-applies the configuration on every
`sudo maint`, and a run that changes nothing writes nothing.

## From SD card to listening

1. **Flash** Rex's image to a microSD card and finish its first-boot wizard.
2. **Run** `curl -fsSL pid1.space/rx | sudo bash`, then reboot.
3. **Listen.** `radio ghostnet` brings up SDR++ tuned to 7.107 MHz and JS8Call
   decoding GhostNet from it. `radio noaa` swaps to weather radio.
4. **Go off-grid.** The clock keeps JS8-grade time from GPS and the RTC with no
   network, and the mesh map works from offline tiles.
5. **Keep it current** with `sudo maint`: package upgrades, then this script
   again, so only drift changes.

## What it does

- **Switches the SDR between setups in one command.** `radio NAME` closes what
  is running and brings NAME up tuned, playing, and resuming where you left it.
- **Receives JS8** through the SDR: SDR++ feeds JS8Call over a virtual audio
  cable, with GhostNet's groups set and every transmit and upload path off.
- **Keeps time without a network**, from GPS PPS, the AIO's RTC and chrony.
- **Runs a LoRa mesh node** on the AIO's SX1262, Meshtastic or MeshCore, on
  the North Texas community's settings, with node lists, messaging, a
  dashboard and offline map tiles.
- **Powers the AIO's subsystems** on GPIO-switched rails, at boot and on demand.
- **Sets up the desktop**: i3 with Alt as the modifier, autologin, Atkinson
  Hyperlegible fonts, and screen blanking off at every layer.
- **Keeps itself current** with one `maint` command, holding the kernel so an
  unattended upgrade can't take the display away.
- **Closes the network** except for SSH: inbound is default-deny, and SSH is
  key-only with keys synced from GitHub, plus optional Tailscale.

## Quick start

On a fresh card, after Rex's first-boot wizard has created your account
([docs/install.md](docs/install.md) has the image links and flashing steps):

```bash
curl -fsSL pid1.space/rx | sudo bash      # provision; prints next steps at the end
sudo reboot                               # RTC, GPS and LoRa are boot overlays
```

Then:

```bash
radio                       # list the SDR profiles
radio ghostnet              # JS8 GhostNet: SDR++ on 7.107 MHz + JS8Call
chronyc sources             # time: PPS marked '*' once the GPS has a fix
radio meshtastic            # mesh node on North Texas settings (or: radio meshcore)
radio mesh nodes            # who the mesh has heard
```

The account is assumed to be `jroemer`; pass another with
`curl -fsSL pid1.space/rx | sudo bash -s -- --user NAME`.

## Command reference

### `radio`: the SDR

| Command | What it does |
|---|---|
| `radio` | List profiles; `*` marks the active one |
| `radio NAME` | Close what's running, bring NAME up. JS8 profiles also start JS8Call on the matching dial |
| `radio off` | Save the active profile, close SDR++ and JS8Call |
| `radio resume` | Bring the active profile back (i3 runs this at login) |
| `radio save [NAME]` | Keep SDR++'s current tuning in the active profile, or as a new one |
| `radio reset NAME` | Back to the shipped default |
| `radio show NAME` | Print a profile |
| `radio help` | All of the above |

`Tab` completes profile names and subcommands.

| Profile | Tuning | Ham It Up |
|---|---|---|
| `ghostnet` | JS8 GhostNet, 7.107 MHz USB → JS8Call | upconvert |
| `js8` | JS8, 7.078 MHz USB → JS8Call | upconvert |
| `vhf` | 2 m calling, 146.520 MHz FM | bypass |
| `dcara` | DCARA, 146.920 MHz FM | bypass |
| `uhf` | 70 cm calling, 446.000 MHz FM | bypass |
| `noaa` | NOAA weather, 162.400 MHz FM | bypass |
| `fm-93.3`, `fm-105.3` | broadcast FM | bypass |
| `am-820` | 820 kHz AM | upconvert |

`radio` says when the Ham It Up's switch needs flipping. How profiles work, and
the SDR++ quirks they work around: [docs/radio.md](docs/radio.md).

### `radio mesh`: the LoRa mesh

| Command | What it does |
|---|---|
| `radio meshtastic` | Put the LoRa radio on Meshtastic, with North Texas settings |
| `radio meshcore` | Put it on MeshCore, with North Texas settings |
| `radio mesh` | Open the client: the Meshtastic dashboard, or MeshCore's chat |
| `radio mesh nodes` | Who has been heard, with SNR and hops |
| `radio mesh send TEXT` | To the primary (Meshtastic) or public (MeshCore) channel |
| `radio mesh dm NAME TEXT` | Direct message; `Tab` completes heard names |
| `radio mesh join URL` | Meshtastic: add the channels in a shared URL |
| `radio mesh join NAME [KEY]` | MeshCore: add a channel (`#name` needs no key) |
| `radio mesh info` | Identity, radio settings and channels, without starting anything |
| `radio mesh on` / `off` | Start or stop the active mesh |

The two networks share one radio, so choosing one stops the other. Neither
starts at boot; every `radio mesh` command but `info` starts the active one.

| | Meshtastic | MeshCore |
|---|---|---|
| Radio | LongFast, slot 20 (906.875 MHz) | 910.525 MHz, 62.5 kHz, SF 7, CR 5 |
| Role | `CLIENT`, 3 hops | companion |
| Announces | node info every 3 h | one advert per start |
| Position | never sent | never sent |
| MQTT | off | — |

Defaults from [NTX Mesh](https://ntxmesh.com/join/); details in
[docs/hardware.md](docs/hardware.md#lora-mesh).

### Everything else

| Command | What it does |
|---|---|
| `sudo maint` | Upgrade packages, re-apply `setup.sh`, report a pending reboot. `--dry-run` and `--only NAME` pass through |
| `curl -fsSL pid1.space/rx \| sudo bash -s -- FLAGS` | Run the script directly: `--dry-run`, `--only NAME`, `--skip NAME`, `--user NAME` |
| `meshtastic --host localhost --info` | Everything the Meshtastic node knows, raw |
| `meshcore-cli -t 127.0.0.1` | MeshCore's own client, interactive |
| `aiov2_ctl --status` | AIO power rails and battery |
| `sudo aiov2_ctl GPS on` | Power a rail now: `GPS`, `LORA`, `SDR` or `USB` |
| `chronyc sources` | Time sources; PPS `*` means GPS-locked |
| `cgps -s` | GPS fix and satellites |
| `rtl_test -t` | Prove the RTL-SDR opens, independent of SDR++ |
| `chirp` | CHIRP, for programming handhelds |
| `js8call` | Plain JS8Call, without retuning the SDR |
| `claude` | Claude Code |
| `sudo tailscale up` | Join the tailnet |

Sections, flags and what each one installs: [docs/install.md](docs/install.md#sections).

## Key map

**The modifier is Alt.** The uConsole's CMD key is only reachable as `Fn`+`CMD`,
a two-key chord for every window operation. Window management sits on
`Alt+Shift` so the shell keeps most of readline's `Alt` bindings; why, and
which ones survive: [docs/desktop.md](docs/desktop.md#why-window-management-sits-on-altshift).

### Workspaces

| Keys | Action |
|---|---|
| `Alt+1` … `Alt+9` | Go to workspace 1–9 |
| `Alt+Shift+1` … `Alt+Shift+9` | Move the window to workspace 1–9 |

| Workspace | What lands there |
|---|---|
| `1` | SDR++, started at login by `radio resume` |
| `2` | JS8Call |
| `3` | Meshtastic dashboard (`radio mesh`) |

### Launch and close

| Keys | Action |
|---|---|
| `Alt+Return` | Terminal (Alacritty); `Alt+Shift+Return` too |
| `Alt+Shift+d` | dmenu, to launch anything by name |
| `Alt+Shift+q` | Close the window |

### Focus and move

| Keys | Action |
|---|---|
| `Alt+h` `j` `k` `l`, or `Alt+arrows` | Focus left, down, up, right |
| `Alt+Shift+h` `j` `k` `l`, or `Alt+Shift+arrows` | Move the window |
| `Alt+Shift+a` | Focus the parent container |

### Layout

| Keys | Action |
|---|---|
| `Alt+Shift+b` / `Alt+Shift+v` | Next window splits horizontally / vertically |
| `Alt+Shift+w` | Tabbed |
| `Alt+Shift+s` | Stacking |
| `Alt+Shift+e` | Toggle split direction |
| `Alt+Shift+f` | Fullscreen |
| `Alt+Shift+space` | Toggle floating |
| `Alt+r` | Resize mode: `h` `j` `k` `l` resize, `Escape` leaves |

### Session and hardware

| Keys | Action |
|---|---|
| `Alt+Shift+c` | Reload the i3 config |
| `Alt+Shift+r` | Restart i3 in place |
| `Alt+Shift+x` | Exit i3 (asks first) |
| `Alt+Shift+o` / `Alt+Shift+p` | Backlight off / restore |
| Brightness keys | Backlight ±10% |
| Volume keys | Volume ±5%, mute |
| `Ctrl+Alt+F2`, then `Ctrl+Alt+F1` | Repaint the panel if it comes back grey |

## Design principles

- **Idempotent, so it is the maintenance tool too.** Re-running is the intended
  use; a run that changes nothing writes nothing, and `maint` is just that run.
- **Closed by default.** Nothing reaches the device unsolicited but SSH, keys
  only. Services that listen widely, like `meshtasticd`, stay local.
- **Quiet until asked.** Nothing transmits or uploads on its own: JS8
  auto-reply and spotting are off, no mesh runs at boot, and neither mesh
  ever sends a position.
- **Works off-grid.** Time from GPS and the RTC, map tiles on the card, and no
  step that needs the network after provisioning.
- **Never brick a portable device.** Kernels are held, boot files are backed up,
  and a truncated download dies instead of running half a script.
- **Check the hardware, don't assume it.** Fonts are verified with `fc-match`, the
  SDR with `rtl_test`, the RTC with `dmesg`, and SDR++ by whether it actually
  opened the dongle.
- **One command per job.** `radio` and `maint`, each runnable from dmenu,
  with failures shown on screen when there is no terminal.

## Documentation

| Guide | What's in it |
|---|---|
| [Install](docs/install.md) | Rex's image, flashing, running the script, sections and flags, after the first run |
| [Radio](docs/radio.md) | `radio` profiles, JS8 over the SDR, an empty SDR++ waterfall, CHIRP |
| [Hardware](docs/hardware.md) | AIO v2 power rails, time (GPS, RTC, chrony), the LoRa mesh (Meshtastic, MeshCore) and map tiles, Bluetooth |
| [Desktop](docs/desktop.md) | Why `Alt+Shift`, what starts on which workspace, display and power, fonts |
| [Maintenance](docs/maintenance.md) | `maint` and held kernels, SSH, the firewall, troubleshooting |

## License

BSD 3-Clause. Made by Jonathan Roemer. See [LICENSE](LICENSE).
