# Install

Everything from a blank microSD card to a provisioned uConsole.

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

## What it assumes

This targets Rex's image specifically:

- **His apt repo is already configured** (it appears as `ClockworkPi-apt`).
  That's where `hackergadgets-uconsole-aio-board`, `pinctrl` and
  the rtlsdrblog `rtl-sdr` build come from rather than Debian. The script
  verifies it rather than adding a copy.
- **No games and no desktop.** True of both the Lite (stage2) and full (stage4)
  builds, so there is nothing to strip out.

## Run it

```bash
curl -fsSL pid1.space/rx | sudo bash
```

Re-running is safe and is the intended way to use this — every step is
idempotent, and a run that changes nothing writes nothing.

<details>
<summary>If the short URL is down</summary>

`pid1.space/rx` redirects to `rx.pid1.space`, a Cloudflare Worker that
Cloudflare builds and deploys straight from this repository on every push to
`main`. There is no mirror to fall out of date: if Cloudflare misses a push,
[`cf-fallback.yml`](../.github/workflows/cf-fallback.yml) notices that the live
`/.build-id` is not the current commit and deploys it. The raw URL remains the
fallback for when Cloudflare itself is unreachable:

```bash
curl -fsSL https://raw.githubusercontent.com/pid1/rx/main/setup.sh | sudo bash
```

Both take the same flags. Substitute either URL wherever these docs say
`pid1.space/rx`.
</details>

## Sections

Every section is skippable with `--skip NAME`, or run alone with `--only NAME`.

| Section | What it does |
|---|---|
| `base` | Timezone (America/Chicago), hushlogin, sshd enabled, GitHub-backed `authorized_keys` sync, the `maint` maintenance command, hardware group membership |
| `firewall` | Default-deny inbound: SSH and replies only, IPv4 and IPv6 (nftables) |
| `desktop` | X11 + i3, autologin on tty1, Alacritty, Atkinson fonts, PipeWire, blanking disabled |
| `claude` | Claude Code from Anthropic's signed apt repo |
| `aio` | HackerGadgets AIO v2 metapackage, GPIO power rails, boot overlays |
| `rtc` | PCF85063A over i2c, bound once the AIO rails are up (`uconsole-rtc`), `fake-hwclock` as fallback |
| `gps` | UART + PPS overlays, serial console removed, `gpsd` on `/dev/ttyS0` |
| `lora` | `meshtasticd` with its own config, the dashboard and map tiles; MeshCore (MeshCoreRPI, pinned); both clients; `rx-mesh`, so neither starts at boot |
| `sdr` | `rtl-sdr`, DVB-T driver blacklisted, rxd and its `rxd@` user unit, `radio` profiles; purges `sdrpp-brown`/`sdrpp` |
| `ham` | JS8Call + hamlib, receive-only GhostNet configuration, SDR→JS8Call loopback sink, CHIRP |
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
ssh jroemer@<its IP or tailnet name>  # from another machine (mDNS is firewalled)
sudo tailscale up                     # unless TS_AUTHKEY was passed
```

Four things the script deliberately leaves to you:

- **No mesh runs** until `radio meshtastic` or `radio meshcore`. Starting one
  applies `LORA_REGION` (`US`) and the North Texas settings; outside the US,
  change `LORA_REGION` in `setup.sh` first — the wrong region is a regulatory
  problem, not a config annoyance.
- **JS8Call transmit** is not configured — audio out and PTT depend on the
  rig attached. Groups, grid, callsign, the dial and the SDR receive input
  *are* set, and `radio` tunes rxd to match (see
  [Radio profiles](radio.md#radio-profiles)).
- **`hwclock -r` alone can lie**, reporting plausible time sourced from
  elsewhere. Check `/dev/rtc*` and `dmesg`. No output at all usually means the
  CR1220 is in backwards.
- **Old SDR++ settings.** The `sdr` section purges the `sdrpp-brown` and
  `sdrpp` packages but leaves `~/.config/sdrpp*`; delete it when you no
  longer want it.
