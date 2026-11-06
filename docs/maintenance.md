# Maintenance

Keeping it current, getting in over SSH, and fixing what breaks.

## Routine maintenance

```bash
sudo maint
```

One command, installed by the `base` section:

1. `apt update`, `apt full-upgrade`, `apt autoremove --purge`
2. re-fetches and re-applies `setup.sh` — idempotent, so only drift and newly
   added configuration change. Without network it re-applies the last
   setup.sh it fetched (`/var/cache/rx/setup.sh`), which installs rxd from
   the release tarball cached beside it.
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
checks [`build.sh`](../build.sh) runs before publishing (`bash -n`, shebang, and
the trailing `main "$@"` without which the script would parse cleanly and do
nothing).

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

**Keys only.** `/etc/ssh/sshd_config.d/10-no-password.conf` turns off password
and keyboard-interactive login; `sudo sshd -T | grep -i authentication`
confirms what sshd actually uses.

## Firewall

Nothing reaches the device unsolicited except **SSH on 22**, from any
interface, and **rxd's HTTP on 8073** from private addresses (10/8,
172.16/12, 192.168/16, IPv6 `fc00::/7` and `fe80::/10`) and `tailscale0`
([turning that off](radio.md#the-lan-can-tune-it)). Everything else inbound is dropped, IPv4 and IPv6, and nothing is
forwarded. Replies to connections the device made itself still arrive, and so
do the few packets IPv6 needs to work at all (neighbour discovery, router
adverts, DHCPv6 replies). The `firewall` section installs it.

The rules are one nftables table, `inet rx_firewall`, in
`/etc/rx/firewall.nft`, loaded by `rx-firewall.service` before the network
comes up. It is a table of its own rather than `/etc/nftables.conf`, whose
`flush ruleset` would wipe the rules Tailscale keeps through iptables-nft;
a drop in any table still applies, since a packet must pass every base chain
on its hook. Loading checks the file first (`nft -c`) and keeps established
connections, an SSH session included.

```bash
sudo nft list table inet rx_firewall   # what is in force
systemctl status rx-firewall           # loaded at boot?
```

Two consequences. Other machines cannot resolve `clockworkpi.local`, since
mDNS answers are inbound traffic: reach it by IP or by its Tailscale name.
And the device does not answer ping.

To open something, add a rule to `/etc/rx/firewall.nft` in `setup.sh`, not on
the device: a re-run rewrites the file.

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

**LoRa silent** — `sudo rx-mesh status` says which mesh is running, if any;
`journalctl -u meshtasticd` or `-u raspberrypimc-companion` says why. "cannot
claim pin GPIO26" means MeshCore left the radio's lines exported:
`sudo rx-mesh release-pins`, then `radio mesh on`. A unit "skipped due to
exec-condition" was started by something other than `rx-mesh`, which is
working as intended.
