<div align="center">

# dpistack

**Deep packet inspection and intrusion detection for one Linux host, set up with a single command.**

nDPI · Suricata · EveBox · ntopng · optional Prometheus or VictoriaMetrics, Grafana and node_exporter, all managed from one command line and one web panel.

[![CI](https://github.com/FlexEbat/dpistack/actions/workflows/ci.yml/badge.svg)](https://github.com/FlexEbat/dpistack/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

English | [Русский](README.ru.md)

</div>

---

## Why dpistack

Putting a traffic-analysis stack together by hand means a dozen packages, three repositories, a hand-edited `suricata.yaml`, a rule updater, services that must start in the right order and nothing that tells you when it quietly stops working. dpistack does that part for you:

- **One command installs it all.** `dpistack` asks a few questions (or none with `-y`), installs the components, renders consistent configs, starts the services and checks that detection really works.
- **One panel runs it.** A web panel shows what is up and what is not, changes every setting with validation, edits configs with a rollback, manages rules, shows logs and events and runs check tests.
- **It watches itself.** A watchdog checks the services, the ports, packet drops, the disk and the age of the rules, and tells you through the panel, the log, Telegram or mail.
- **It does not lock you in.** Every component runs on the host or in Docker, in any combination; everything is plain files under `/etc` and `/var/lib`.

## What you get

| Component | What it does |
| --- | --- |
| **Suricata** + **nDPI** | the engine: IDS or IPS, with application detection (BitTorrent, TLS names and so on) |
| **EveBox** | browse and triage Suricata alerts and events |
| **ntopng** (+ Redis) | live traffic, hosts and flows |
| **Panel** | the control web UI, in two editions: `full` and `lite` |
| **Watchdog** | health checks, alerts, optional automatic restarts |
| **Prometheus** or **VictoriaMetrics** (optional) | metrics storage that scrapes the panel |
| **Grafana** (optional) | dashboards, with the storage wired in as the default data source |
| **node_exporter** (optional) | CPU, memory, disk and network of the host |

```
                    ┌────────────────────── one host ───────────────────────┐
  network traffic ─▶│  Suricata (+ nDPI) ──▶ eve.json ──▶ EveBox             │
  (mirror, gateway, │        │                  │                            │
   or in-line)      │        ▼                  ▼                            │
                    │  rules updater       Panel ◀── Watchdog ──▶ alerts     │
                    │  ntopng + Redis        │  /metrics                     │
                    │                        ▼                               │
                    │      Prometheus | VictoriaMetrics ──▶ Grafana          │
                    │                   node_exporter ──┘                    │
                    └────────────────────────────────────────────────────────┘
```

## Quick install

You need root and a clean machine (or a snapshot): the installer installs packages and repositories.

```
git clone https://github.com/FlexEbat/dpistack.git
cd dpistack
sudo ./install.sh              # the menu (the same as: sudo ./install.sh install)
sudo ./install.sh --fast       # the short questionnaire instead of the guided setup
```

On a terminal a menu opens and first offers the guided setup, which asks every setting that applies. Press `m` in the menu to choose the parts one by one (Suricata, nDPI, rules, EveBox, ntopng, panel, watchdog, Grafana, node_exporter); every action asks for a confirmation and every screen has an exit. The quick install asks only what matters: the capture interfaces, how to get Suricata, who may open the panels (and on which address), the optional metrics stack and which panel you want. Everything else keeps a sensible default. Without a terminal, or with `-y`, nothing is asked:

```
sudo ./install.sh install -y --set IFACES=eth0 --set PANEL_EDITION=lite
sudo ./install.sh install --dry-run -y        # show the plan, change nothing
```

At the end you get a report with the addresses, the results of the check tests and, once, the generated panel password (only a hash stays on disk). By default the panel listens on `http://127.0.0.1:9800`, EveBox on `5636` and ntopng on `3000`; from another machine use an SSH tunnel: `ssh -L 9800:127.0.0.1:9800 user@host`. The whole installer is also available as a single file, `dpistack-install.sh`. Details: [docs/installation.md](docs/installation.md).

**Requirements:** Linux with systemd, root, `amd64` or `arm64`. Tested platforms: Ubuntu LTS from 22.04, Debian from 12, Rocky Linux and AlmaLinux from 8. Any other systemd distribution works with the components in Docker ([docs/platforms.md](docs/platforms.md)).

## Choose your setup

| Choice | Options | Key |
| --- | --- | --- |
| Which panel | `full` (rich dark console with a quiet particle background) or `lite` (the same features on a plain, light page for small hosts) | `PANEL_EDITION` |
| Who may open the panels | `localhost` (this machine only, the default), `lan` (your network) or `nginx` (a reverse proxy, optionally with TLS) | `ACCESS_MODE` |
| On which address | `auto` or one address of this host, picked from the list the installer prints (for example `192.168.1.156` on `enp2s0`) | `BIND_ADDR` |
| Where each component runs | the host or Docker, independently, for Suricata, EveBox, ntopng, the metrics storage, Grafana, node_exporter and the panel | `*_RUNTIME` |
| Metrics stack | a storage (`prometheus` or `victoriametrics`), Grafana and node_exporter, each chosen on its own | `METRICS_BACKEND`, `GRAFANA_ENABLE`, `NODE_EXPORTER_ENABLE` |
| Suricata mode | `ids` (watch only) or `ips` (can block), switched at any time | `SURICATA_MODE` |

Every setting is described in [docs/configuration.md](docs/configuration.md).

## The panel

Ten screens: Overview, Components, Settings, Configs, Rules, Logs, Events, Metrics, Tests and Alerts. The Settings screen is built from the same schema as the installer, so it shows every setting, checks it before applying it, flags changes that start a rebuild and warns about busy ports with a free one to take. Both editions have exactly the same features. More: [docs/dashboard.md](docs/dashboard.md).

## Listening address and access

By default everything listens on `127.0.0.1`. To reach the panels from your network, either choose `ACCESS_MODE=lan` (all addresses) or keep `ACCESS_MODE=localhost` and set `BIND_ADDR` to one address of this host: the services then listen only there and the panel lets in clients from `LAN_CIDR`. Anything beyond loopback needs an explicit confirmation. A busy port is reported with the name of the process that holds it and a free port to take. More: [docs/deployment.md](docs/deployment.md).

## IPS mode

By default Suricata works as IDS: it watches traffic and blocks nothing. `dpistack mode ips` (or the "Enable IPS" button) turns it into IPS: through NFQUEUE (`IPS_METHOD=nfq`, rules in a separate `DPISTACK` chain that is restored at boot) or with pairs of interfaces (`afpacket`). The rules use `--queue-bypass`, so stopping Suricata does not cut the network. The switch must be confirmed with `mode-confirm` (the "Confirm IPS" button) within 120 seconds (`--confirm-timeout`, 10 to 3600): otherwise the mode goes back to IDS by itself. Other people's chains and rules are not touched. Blocking is done by your rules with the `drop` action (`drop.conf`); none are created for you.

## Metrics

The panel serves `GET /metrics` in the Prometheus format with a token in the `Authorization: Bearer` header (`METRICS_EXPORT=yes` by default; the token is created at install):

```
curl -H "Authorization: Bearer $TOKEN" http://127.0.0.1:9800/metrics
```

By default `METRICS_BACKEND=none`: only the endpoint exists and you bring your own collector. An entry for `scrape_configs` (Prometheus and VictoriaMetrics; with `ACCESS_MODE=nginx` and TLS the scheme is `https`):

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

For `vmagent` take the same `scrape_configs` block in the file named by `-promscrape.config` and add `-remoteWrite.url` with the address of your VictoriaMetrics.

Or let the installer do it all: choose a storage (`METRICS_BACKEND=victoriametrics` or `prometheus`), and optionally **Grafana** (`GRAFANA_ENABLE=yes`, port 3030, the storage is set up as its default data source, the first login is `admin`/`admin`) and **node_exporter** (`NODE_EXPORTER_ENABLE=yes`, port 9100, scraped by the storage). Each one is a separate choice. The storage keeps `METRICS_RETENTION` of data (a number with `h`, `d`, `w` or `y`, `30d` by default). Changing or turning off a part stops it and leaves its data; only `uninstall --purge` removes data.

## Everyday commands

After the install `dpistack` is on your `PATH`. Without arguments it opens the control menu.

```
dpistack status [--json]                  # components and install steps
dpistack start|stop|restart <component>
dpistack logs <component> [-n N] [--follow]
dpistack settings list|check|set|secret|job
dpistack reconfigure                      # apply dpistack.conf
dpistack upgrade | uninstall [--purge]
dpistack self-update [--check]            # update dpistack itself from its latest release
dpistack rules-update | rules-sources | rules-group | rules-sid | rules-search
dpistack iface list|add|remove
dpistack mode ids|ips | mode-confirm
dpistack test bittorrent|https|all
dpistack diag                             # a report for troubleshooting
```

All commands: [docs/operations.md](docs/operations.md). Settings live in `/etc/dpistack/dpistack.conf`, secrets apart in `/etc/dpistack/secrets.conf` (`0600`); an example is in [dpistack.conf.example](dpistack.conf.example). A light change applies at once, a heavy one (an install or a rebuild) runs as a separate job.

## Topology limit

The host sees only the traffic of its own interface. Passive capture (`af-packet`) will not show the rest of the network unless that traffic reaches this host: you need a mirror port on a switch, a gateway, or an in-line position (IPS mode). A host outside the path of the network protects and shows only itself. The installer reminds you of this when you choose interfaces.

## Threat model

- The panel's config editor equals root access to the host: edits of `suricata.yaml` and starting components allow running foreign code. A hacked panel is a hacked host.
- That is why `ACCESS_MODE=localhost` is the default, signing in with a password is required and cannot be turned off. The `lan` and `nginx` modes, and any address other than loopback, are enabled only after you explicitly confirm the warning.
- The panel itself serves HTTP without TLS. In `lan` mode the password and the `/metrics` token are visible on the network: use `nginx` with TLS or an SSH tunnel.
- `eve.json` holds traffic metadata (SNI, DNS names, addresses), mode `0640`.
- `dpistack` commands run as root only. The panel does not run as root and reaches only the control verbs through `sudo -n dpistack <command>`; every argument is checked against lists.
- Secrets (`ALERT_TG_TOKEN`, `ALERT_SMTP_URL`, `METRICS_TOKEN`) live only in `/etc/dpistack/secrets.conf`. The panel password is stored as an argon2id hash.

Reporting vulnerabilities: [SECURITY.md](SECURITY.md).

## Documentation

The README and the guides come in English and Russian (`*.ru.md`).

| Document | What it covers |
| --- | --- |
| [docs/installation.md](docs/installation.md) | install, upgrade, uninstall, busy ports |
| [docs/configuration.md](docs/configuration.md) | reference of every `dpistack.conf` setting |
| [docs/runtimes.md](docs/runtimes.md) | Docker or native: what can run where and how the parts find each other |
| [docs/dashboard.md](docs/dashboard.md) | the panel: screens, editions, settings, security |
| [docs/deployment.md](docs/deployment.md) | runtimes, the panel in Docker, access and the listen address |
| [docs/platforms.md](docs/platforms.md) | supported distributions |
| [docs/operations.md](docs/operations.md) | commands, rules, IPS, watchdog, metrics stack |
| [docs/troubleshooting.md](docs/troubleshooting.md) | common messages and what to do |
| [tech.md](tech.md) | specification, contracts and the project history |
| [CONTRIBUTING.md](CONTRIBUTING.md), [AGENTS.md](AGENTS.md) | development |

## Development

```
bash scripts/gate.sh
```

The gate runs `shfmt`, `shellcheck`, the security checks, `bats` and, if Go is there, `gofmt`, `go vet`, `go test` and the interface tests. The `dev` branch is for work, `main` for the tested state; releases are tags `vX.Y.Z` on `main`. See [CONTRIBUTING.md](CONTRIBUTING.md).

License: [MIT](LICENSE).
