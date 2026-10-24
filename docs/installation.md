# Install, upgrade, uninstall

English | [Русский](installation.ru.md)

## Requirements

- Linux with systemd, root access, architecture `amd64` or `arm64`.
- Internet access during the install (packages, repositories, component releases).
- For components in Docker: Docker with the `compose` plugin.
- The list of platforms and what is installed on each: [platforms.md](platforms.md).

The `dpistack` command and `install.sh` run as root only. Without root they exit with code 1 and the message `dpistack: the command runs as root only`.

## Ways to get the installer

From a clone of the repository:

```
git clone https://github.com/FlexEbat/dpistack.git
cd dpistack
sudo ./install.sh install
```

As a single file: `dpistack-install.sh` in the repository root. It is built by `scripts/bundle.sh` from the same `install.sh`, `lib/`, `templates/` and `bin/` and takes the same commands: `sudo bash dpistack-install.sh install`. The panel is not part of the file: next to it there must be a ready `dpistack-panel-linux-amd64` binary (or `-arm64`) from the release archive, or a `panel/` directory and Go of the right version. From a pipe (`curl ... | bash`) the file will run, but the menu gets no input, so download it first.

## The menu, and no questions

On a terminal `install` opens a text menu. "Quick install" asks for the interfaces, the way to install Suricata, the access mode, which panel to use (`full` or `lite`) and the panel password; the other sections (capture, components, EVE, rules, access, metrics, watch, tests) open if you want them, and `--advanced` asks every key. The install starts with its own menu item.

Without a terminal, or with `-y`, there are no questions and missing values take their defaults:

```
sudo ./install.sh install -y --set IFACES=eth0 --set ACCESS_MODE=localhost --set PANEL_EDITION=lite
```

The plan with no changes to the system:

```
sudo ./install.sh install --dry-run -y
```

The final report shows the generated panel password once (only an argon2id hash stays on disk) and, if the metrics export is on, the `/metrics` token. You can set the password in advance: `DPISTACK_PANEL_PASSWORD=... sudo -E ./install.sh install -y`.

## Busy ports

Before the install the ports of the panel (`PANEL_PORT`, 9800), EveBox (`EVEBOX_PORT`, 5636), ntopng (`NTOPNG_PORT`, 3000) and the metrics storage are checked. With nginx the port behind it is checked too (the public port + 10000).

- In the menu a busy port is shown as a warning: the process that holds it is named and the nearest free port is offered. Enter takes it, you can type your own, `q` keeps the port as it is (then the check before the install stops on it).
- Without a terminal the install stops with code 3 and the message names a free port: `port 9800 (PANEL_PORT) is already busy (held by: nginx); free: --set PANEL_PORT=9801`.
- From the panel and with `dpistack settings set` a change of a port to a busy one is refused with the same message and the config file is not changed.

## After the install

The `dpistack` command is available (a copy of the installer in `/usr/local/sbin`). Without arguments it opens the control menu: configuration, status, logs, tests, upgrade, uninstall, panel password. By default the panel listens on `http://127.0.0.1:9800`, EveBox on `5636`, ntopng on `3000`. From another machine: `ssh -L 9800:127.0.0.1:9800 user@host`.

`dpistack-ctl` stays as a symbolic link to `dpistack` so that services created by earlier versions keep working; use `dpistack` in new scripts.

## Changing settings

```
sudo dpistack reconfigure                 # the menu, or applying dpistack.conf
sudo dpistack reconfigure --dry-run -y    # which keys changed and which steps are affected
sudo dpistack settings set --apply STATS_INTERVAL_SEC=45
```

A light change applies at once. A heavy one (a change of the Suricata source, of a component's runtime and the like) needs `--force` or `settings set --apply-heavy`: the installer overwrites hand-edited files and keeps copies of them. The reference of settings: [configuration.md](configuration.md).

## Upgrade

```
sudo dpistack upgrade
```

Packages and pinned component versions, the installer copy and the panel are updated. You can pin component versions with the `*_VERSION` keys and `PIN_VERSIONS=yes`.

## Uninstall

```
sudo dpistack uninstall            # services, timers, dpistack firewall rules, program copies
sudo dpistack uninstall --purge    # and configs, component data, users
```

System packages are not removed. The `DPISTACK` chain and the rules dpistack added are removed; other people's rules are not touched.
