# AGENTS.md

## Sadr

Sadr: off. The owner keeps this repo out of Sadr's runs.

## rxd

rxd, `radio`, `rxd-tui` and the browser UI live in
[pid1/rxd](https://github.com/pid1/rxd). setup.sh installs a pinned release
(`RXD_VERSION` and `RXD_SHA256` in its `sdr` section; build.sh refuses a
placeholder) and writes this station's `/etc/rxd/station.json` and
`/etc/rxd/rxd.env`. Change rxd itself there, then bump the pin here in a PR
of its own. What stays in rx: the station file's values, the firewall, the
wsjtx pin, `radio-mesh`, and everything else about the machine.
