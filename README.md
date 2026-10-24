# dpistack

English | [Русский](README.ru.md)

Installer and control panel for a DPI/IDS lab on a single host: **nDPI + Suricata + EveBox + ntopng**. One command, `dpistack`, installs the stack, configures it and looks after it; the web panel shows the state and changes any setting without the command line.

## Features

- **One command, `dpistack`.** Install, upgrade, uninstall, service control, rules, interfaces, IDS/IPS mode, check tests and settings, all in one program (`dpistack help`). It runs as root only.
- **Two panels, your choice.** `PANEL_EDITION=full` is the rich dark console with a quiet particle background; `lite` is the same panel with every feature on a plain, light page for small hosts. The panel shows component state, **every setting of the stack** on the Settings screen (checked before it is applied), a config editor with rollback, rules, logs, events, metrics and alerts. Details: [docs/dashboard.md](docs/dashboard.md).
- **Any deployment mix.** Suricata, EveBox, ntopng, the metrics storage and the panel itself each run on the host or in Docker, independently. Details: [docs/deployment.md](docs/deployment.md).
- **Any Linux with systemd.** Ubuntu, Debian, Rocky, Alma, Fedora, RHEL on the host or in Docker; openSUSE, Arch and any other distribution with the components in Docker. Details: [docs/platforms.md](docs/platforms.md).
- **Busy ports.** A warning with the name of the process and a free port to take; you can pick another one.
- **Config check.** The rendered `suricata.yaml` matches the series of the installed Suricata and is checked with `suricata -T` before it is written.

## Documentation

Every document comes in English and Russian (`*.ru.md`).

| Document | What it covers |
| --- | --- |
| [docs/installation.md](docs/installation.md) | install, upgrade, uninstall, busy ports |
| [docs/configuration.md](docs/configuration.md) | reference of every `dpistack.conf` setting |
| [docs/dashboard.md](docs/dashboard.md) | panel screens, editions, settings, security |
| [docs/deployment.md](docs/deployment.md) | the runtime of each component, the panel in Docker, access |
| [docs/platforms.md](docs/platforms.md) | supported distributions |
| [docs/operations.md](docs/operations.md) | commands, settings, rules, IPS, watchdog, metrics |
| [docs/troubleshooting.md](docs/troubleshooting.md) | common messages and what to do |
| [tech.md](tech.md) | specification and decisions |
| [CONTRIBUTING.md](CONTRIBUTING.md), [AGENTS.md](AGENTS.md) | development |
| [SECURITY.md](SECURITY.md) | reporting vulnerabilities |

## Topology limit

The host sees only the traffic of its own interface. Passive capture (`af-packet`) will not show the rest of the network unless that traffic reaches this host: you need a mirror port on a switch, a gateway, or an in-line position (IPS mode). A host outside the path of the network protects and shows only itself. The installer reminds you of this when you choose interfaces.

## Threat model

- The panel's config editor equals root access to the host: edits of `suricata.yaml` and starting components allow running foreign code. A hacked panel is a hacked host.
- That is why `ACCESS_MODE=localhost` is the default, signing in with a password is required and cannot be turned off. The `lan` and `nginx` modes are enabled only after you explicitly confirm the warning.
- The panel itself serves HTTP without TLS. In `lan` mode the password and the `/metrics` token are visible on the network: use `nginx` with TLS or an SSH tunnel.
- `eve.json` holds traffic metadata (SNI, DNS names, addresses), mode `0640`, readable by Suricata and the `dpistack` user.
- `dpistack` commands run as root only. The panel does not run as root and does privileged things only through `sudo -n dpistack <command>`: `dpistack` lets the panel user reach the control commands only (not `install`, `upgrade`, `uninstall`) and checks every argument against lists. The `sudoers` rule allows the `dpistack` user this one file only.
- Secrets (`ALERT_TG_TOKEN`, `ALERT_SMTP_URL`, `METRICS_TOKEN`) live only in `/etc/dpistack/secrets.conf` (`0600`). The panel password is stored as an argon2id hash.

Reporting vulnerabilities: [SECURITY.md](SECURITY.md).

## Quick install

You need root and a clean machine (or a snapshot): the installer installs packages and repositories.

```
git clone https://github.com/FlexEbat/dpistack.git
cd dpistack
sudo ./install.sh install
```

On a terminal a menu opens (it asks which panel you want, `full` or `lite`); without a terminal, or with `-y`, there are no questions:

```
sudo ./install.sh install -y --set IFACES=eth0 --set ACCESS_MODE=localhost --set PANEL_EDITION=lite
sudo ./install.sh install --dry-run -y     # the plan only
```

The final report shows the generated panel password once (only a hash stays on disk). The panel listens on `http://127.0.0.1:9800`, EveBox on `5636`, ntopng on `3000`; from another machine: `ssh -L 9800:127.0.0.1:9800 user@host`. As a single file: `dpistack-install.sh`. Details: [docs/installation.md](docs/installation.md).

## Config

Settings live in `/etc/dpistack/dpistack.conf` (`KEY=VALUE` format), secrets apart in `/etc/dpistack/secrets.conf` (`0600`). Example: [dpistack.conf.example](dpistack.conf.example), reference: [docs/configuration.md](docs/configuration.md). You can change settings on the Settings screen, with `dpistack settings set` or through `dpistack reconfigure`; a light change applies at once, a heavy one (an install or a rebuild of a component) runs as a separate job.

## Commands

After installation `dpistack` is available (a copy of the installer in `/usr/local/sbin`). Without arguments it opens the control menu.

```
dpistack status [--json]                 # components and install steps
dpistack start|stop|restart <component>
dpistack logs <component> [-n N] [--follow]
dpistack settings list|check|set|secret|job
dpistack reconfigure                     # apply dpistack.conf
dpistack upgrade | uninstall [--purge]
dpistack rules-update | rules-sources | rules-group | rules-sid | rules-search
dpistack iface list|add|remove
dpistack mode ids|ips | mode-confirm
dpistack test bittorrent|https|all
dpistack diag
```

The old name `dpistack-ctl` stays as a symbolic link to `dpistack` for services created by earlier versions. All commands: [docs/operations.md](docs/operations.md).

## IPS mode

By default Suricata works as IDS: it watches traffic and blocks nothing. `dpistack mode ips` (or the "Enable IPS" button on the Components screen) turns it into IPS: through NFQUEUE (`IPS_METHOD=nfq`, rules in a separate `DPISTACK` chain that is restored at boot) or with pairs of interfaces (`afpacket`). The rules use `--queue-bypass`, so stopping Suricata does not cut the network. The switch must be confirmed with `mode-confirm` (the "Confirm IPS" button) within 120 seconds (`--confirm-timeout`, 10 to 3600): otherwise the mode goes back to IDS by itself and the rules are removed. Other people's chains and rules are not touched. The decision to block is made by your rules with the `drop` action (`drop.conf`); none are created for you. A host outside the path of the network protects only itself.

## Metrics

The panel serves `GET /metrics` in the Prometheus format with a token in the `Authorization: Bearer` header (`METRICS_EXPORT=yes` by default, the token is created at install). Example `curl`:

```
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9800/metrics
```

An entry for `scrape_configs` (Prometheus and VictoriaMetrics; with `ACCESS_MODE=nginx` and TLS the scheme is `https`, and the address and port are the ones you open the panel with):

```yaml
scrape_configs:
  - job_name: dpistack
    metrics_path: /metrics
    scheme: http
    authorization:
      type: Bearer
      credentials_file: /etc/prometheus/dpistack.token
    static_configs:
      - targets: ['127.0.0.1:9800']
```

`credentials_file` keeps the token out of the config. In the final report the installer prints the same entry with `credentials: <token>` instead of a file. For `vmagent` take the same `scrape_configs` block in the file named by the `-promscrape.config` flag and add `-remoteWrite.url` with the address of your VictoriaMetrics; a single-node VictoriaMetrics accepts such a file with its own `-promscrape.config` flag.

By default `METRICS_BACKEND=none`: there is only the endpoint and you set up the collecting. You can leave it to the installer: `METRICS_BACKEND=victoriametrics` or `prometheus` (a binary from the project's release with a sha256 check, or a container with `METRICS_BACKEND_RUNTIME=docker`). It puts `scrape.yaml` with this target, reads the token from a file, keeps `METRICS_RETENTION` of data (a number with the suffix `h`, `d`, `w` or `y`, `30d` by default) in `/var/lib/dpistack-metrics` and listens by the rules of `ACCESS_MODE` (with `localhost` on `127.0.0.1` only; port `METRICS_BACKEND_PORT`, 8428 and 9090 by default). Changing the backend or `none` stops the old one and leaves its data; only `uninstall --purge` removes it.

## Development

```
bash scripts/gate.sh
```

The gate runs `shfmt`, `shellcheck`, the security checks, `bats` and, if Go is there, `gofmt`, `go vet`, `go test`, the interface tests and the check of the panel's resource budget. The `dev` branch is for work, `main` for the tested state; merging into `main` goes through a pull request after a green gate. More: [CONTRIBUTING.md](CONTRIBUTING.md), [AGENTS.md](AGENTS.md), tech.md.

License: [MIT](LICENSE).
