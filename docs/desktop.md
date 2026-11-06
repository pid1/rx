# Desktop

i3 on the 5" panel: key bindings, what starts where, display and fonts.

## Key bindings

**`$mod` is Alt.** The uConsole's CMD key is only reachable as `Fn`+`CMD` — a
two-key chord for every window operation — so Alt wins on ergonomics.

Every binding is in the [key map](../README.md#key-map).

### Why window management sits on `Alt+Shift`

i3 grabs `$mod` combinations globally, so every plain `Alt`+letter binding is
taken away from the shell, where readline uses Meta for word motion. i3 claims
only `Alt+h/j/k/l`, `Alt+1..9`, `Alt+r` and `Alt+Return` — costing readline
`M-l`, `M-r` and `M-<digit>`, all rare.

**Still yours in the terminal:** `Alt+b`, `Alt+f`, `Alt+d`, `Alt+t`, `Alt+u`,
`Alt+p`, `Alt+y`, `Alt+.`, `Alt+Backspace`.

## Applications at login

i3 runs `radio resume` at login, which starts the active profile's receiver,
rxd, as a headless systemd user unit (`rxd@NAME`) with no window. Two apps
have placement rules:

| Workspace | Application | At boot |
|---|---|---|
| 2 | JS8Call | started by `radio resume` for a JS8 profile |
| 3 | `meshtastic-ui` | placement only |

JS8Call and the dashboard land on 2 and 3 whenever started — `Alt+2` and
`Alt+3` reach those workspaces at any time, whether or not anything is on
them.

No mesh daemon runs at boot either. **`radio mesh`** starts the active one
and opens its client — the dashboard on workspace 3 for Meshtastic — from a
terminal or dmenu (`Alt+Shift+d`). It starts the daemon through `rx-mesh`, the
one command the desktop user may run as root, under a sudo rule at
`/etc/sudoers.d/50-rx-mesh` that is validated with `visudo -c` before being
put in place. Failures surface through `i3-nagbar`, since dmenu gives it no
terminal to print to.

One quirk the rules work around: `meshtastic-ui` sets **no `WM_CLASS` at
all**, so `assign` has nothing to match and a `for_window [title="^Meshtastic"]`
rule moves it instead.

`radio resume` runs from `exec`, which runs only at i3 startup —
`i3-msg restart` will not rerun it, by design, since `exec_always` would spawn duplicates on every
reload.

## Display and power

**Screen blanking, DPMS and idle actions are disabled at every layer** — Xorg
(`/etc/X11/xorg.conf.d/10-no-blanking.conf`), logind (`IdleAction=ignore`), the
kernel console (`consoleblank=0`) and `xset` in `.xinitrc`. Nothing locks or
blanks the screen.

This is not only a battery preference: the DSI panel **wakes from DPMS to a
solid grey screen** and needs a VT switch to repaint, so blanking is actively
harmful here. Use `Alt+Shift+o` to kill the backlight deliberately — that drives
`brightnessctl` and never touches DPMS.

**Rotation** is detected at X startup rather than hardcoded. The panel is
mounted rotated and presents portrait; some images already apply the transform
at the DRM level, and rotating twice leaves the display sideways. If it comes up
sideways, edit `~/.xinitrc`.

## Fonts

`monospace` → **Atkinson Hyperlegible Mono**, `serif` and `sans-serif` →
**Atkinson Hyperlegible Next**, via `/etc/fonts/local.conf`.

Neither is packaged in Debian (`fonts-atkinson-hyperlegible` is the *original*
family only), so both come from the upstream Google Fonts repos. The install
verifies with `fc-match` rather than assuming — a silent miss would just fall
back to DejaVu and look fine.

i3 uses Mono at 12pt. The panel is ~290 DPI, so raise it in
`~/.config/i3/config` if it reads small.
