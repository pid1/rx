# Maintenance

Keeping it current, getting in over SSH, and fixing what breaks.

## Routine maintenance

```bash
sudo maint
```

One command, installed by the `base` section:

1. `apt update`, `apt full-upgrade`, `apt autoremove --purge`
2. re-fetches and re-applies `setup.sh` — idempotent, so only drift and newly
   added configuration change
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

**Password authentication is still on.** Once you have confirmed key login
works, turn it off:

```bash
sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl restart ssh
```

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

**LoRa silent** — check `/etc/meshtasticd/config.d/uconsole-aio-v2.yaml` is
actually being read before debugging the radio. The drop-in only applies if the
packaged version supports `config.d`.
