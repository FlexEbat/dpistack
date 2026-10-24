# tech.md: dpistack (nDPI + Suricata + EveBox + ntopng)

English | [Русский](tech.ru.md)

**Document version: v32** (2026-10-24)
**Program version: v0.23.0**

This is the source of truth of the project: names of config keys, paths, commands, metrics, fields and endpoints come from here. Each change of a contract raises the version above. The full history of slices, reviews and the old changelog (versions up to v0.22.0) is in the git history: it was removed from this file on 2026-10-24 (the last commit that has it is `02929a8`, file `tech.md`).

## 1. Project

dpistack is an installer, two service scripts and a web panel for a home or small DPI/IDS lab: **nDPI + Suricata + EveBox + ntopng** on one host with one administrator. The goal is a working bundle that one command sets up, that is managed from a browser and reports its own failures. It is a finished, full project, not an MVP. It is not a SIEM, not a multi-host platform and not a replacement for an industrial NDR.

- **Topology limit.** The host sees only the traffic of its own interface. Passive capture (`af-packet`) shows the rest of the network only if that traffic reaches this host (a mirror port, a gateway, an in-line position). A host outside the path with NFQUEUE in `INPUT`/`OUTPUT` protects only itself. The installer prints this when interfaces are chosen.
- **Threat model.** The config editor of the panel equals root access to the host. A hacked panel is a hacked host. So `ACCESS_MODE=localhost` is the default, signing in is required and cannot be turned off; `lan` and `nginx` are enabled only after an explicit confirmation. The panel serves HTTP without TLS (use `nginx` with TLS or an SSH tunnel). `eve.json` holds traffic metadata and is `0640`. `dpistack` commands run as root only; the panel reaches only the control verbs through `sudo -n dpistack <verb>` and every argument is checked against lists. Secrets live only in `secrets.conf` (`0600`); the panel password is an argon2id hash.
- **Not in scope:** a multi-user panel, own SSO, Grafana dashboards, ntopng Enterprise, podman, LXD, an i18n layer in the program, capturing a whole network without a suitable topology.

## 2. Stack and platforms

- Installer and `dpistack-watch`: Bash 4.4+, no Python or Perl. External tools: `curl`, `jq`, `ss`, `ip`, `systemctl`, `sed`, `awk`, `tar`, `flock`; the `preflight` step installs what is missing.
- Panel: Go (the version in `panel/go.mod`), the standard library `net/http` plus `golang.org/x/crypto` (argon2id) v0.58.0 and its `golang.org/x/sys` v0.49.0. The `/metrics` text is written by hand. Front end: plain ES modules and CSS, no bundler, no framework, no icon fonts, no external resources.
- Tests: `bats` for Bash, `go test` for the panel, `node --test` for the interface logic. Checks: `shellcheck`, `shfmt`, `gofmt`, `go vet`.
- Platforms (required): Ubuntu LTS from 22.04, Debian from 12, Rocky Linux and AlmaLinux from 8. RHEL and CentOS Stream start with a warning. openSUSE, Arch and any other systemd Linux run with the components in Docker. Older releases are refused by `preflight` with code 3 (override at your own risk: `DPISTACK_ALLOW_UNSUPPORTED=1`). Package managers: `apt`, `dnf` on the host; `zypper`, `pacman`, `generic` need Docker for the components.
- Only stable versions are used by default: no `master`, `nightly`, `latest`, `dev`. Suricata comes from the last tested release of the 8.0 series (`SURICATA_STABLE_REF`, now `suricata-8.0.7`), nDPI 4.14 (`NDPI_COMPAT_REF`), ntop.org from its stable channel, EveBox from `stable`. Docker images use pinned tags.
- Architectures: `amd64`, `arm64`. Containers: Docker with the `compose` plugin only.

## 3. Repository layout

| Path | Purpose |
| --- | --- |
| `install.sh` | entry point: arguments, the root check, the command dispatcher |
| `lib/*.sh` | `schema.sh` (the key schema), `config.sh`, `os.sh`, `step_*.sh` (install steps), `ctl.sh` (control verbs), `menu.sh`, `render.sh`, `runtime_docker.sh`, `ips.sh` |
| `bin/dpistack-watch` | the watchdog |
| `templates/` | config and unit templates (`@@KEY@@` and blocks, filled by `lib/render.sh`) |
| `panel/` | the panel: Go (`cmd/panel`, `internal/{api,auth,ctl,eve,export,health,metrics}`) and `web/` |
| `tests/` | bats tests, stubs in `tests/mocks/`, data in `tests/data/` |
| `scripts/` | `gate.sh`, `bundle.sh`, `security.sh`, `check-conf-example.sh`, `gen-config-doc.sh`, `panel-budget.sh`, `suricata-*.sh` |
| `dpistack-install.sh` | the single-file installer, **generated** by `scripts/bundle.sh` |
| `docs/` | guides; `configuration*.md` is **generated** from the schema |
| `.github/` | CI, security and release workflows, Dependabot |

## 4. Contracts

### 4.1 Components

| id | what | runtime | unit / container |
| --- | --- | --- | --- |
| `suricata` | IDS/IPS engine | native, docker | `suricata.service` |
| `evebox` | alert viewer | native, docker | `evebox.service` |
| `ntopng` | traffic monitor | native, docker | `ntopng.service` |
| `redis` | the storage of ntopng, always where `ntopng` is | as `ntopng` | `redis.service` (rpm) or `redis-server.service` (deb) |
| `victoriametrics` | metrics backend, only with `METRICS_BACKEND=victoriametrics` | native, docker | `dpistack-vm.service` |
| `prometheus` | metrics backend, only with `METRICS_BACKEND=prometheus` | native, docker | `prometheus.service` |
| `panel` | the control panel | native, docker | `dpistack-panel.service` |
| `watch` | the watchdog | native only | `dpistack-watch.timer` |
| `rules` | rules update | native only | `dpistack-rules.timer` |

`ndpi` is not a component: it is a library and the `ndpi.so` plugin is a part of `suricata`; `status` shows it as the field `ndpi_plugin`.

### 4.2 Paths

| what | path |
| --- | --- |
| install config | `/etc/dpistack/dpistack.conf` (0644 root); draft of the menu `dpistack.conf.draft` (0600) |
| secrets | `/etc/dpistack/secrets.conf` (0600 root) |
| panel password hash | `/etc/dpistack/panel.auth` (0640 root:dpistack) |
| state | `/var/lib/dpistack/` (`state`, `health.json`, `events.jsonl`, `tests-last.json`, `metrics.json`, `backups/`, `staging/`, `scrape.yaml`) |
| lock, install log | `/var/lock/dpistack.lock`, `/var/log/dpistack/install.log` |
| helpers | `/usr/local/sbin/dpistack` (the persistent command), `/usr/local/sbin/dpistack-ctl` (a link to it), `/usr/local/sbin/dpistack-watch`, libraries and templates in `/usr/local/lib/dpistack/` (the installer copy in `installer/`) |
| panel | `/usr/local/bin/dpistack-panel` |
| Suricata | `/etc/suricata/suricata.yaml`, `/etc/suricata/{enable,disable,modify,drop}.conf`, `/etc/suricata/rules/local.rules`, `/var/lib/suricata/rules/suricata.rules`, `/var/log/suricata/eve.json`; socket native `/run/suricata-command.socket`, docker `/var/run/suricata/suricata-command.socket` |
| EveBox, ntopng | `/etc/evebox/evebox.yaml` (port 5636), `/etc/ntopng/ntopng.conf` (port 3000) |
| compose | `/opt/dpistack/compose/compose.yaml` |

The `state` file keeps step marks, a snapshot of the applied config (`applied.<KEY>=<value>`) and watchdog counters (`watch.miss.<id>`, `watch.restarts.<id>`). The system user `dpistack` (no login) runs the panel and can read `eve.json`.

### 4.3 Keys of `dpistack.conf`

Format `KEY=value`, one per line, no quotes or substitutions. The check is strict: an unknown key or a value outside the options stops the installer. A retired key (`PANEL_MODE`) is dropped when the file is loaded. A value whose implementation is not done is refused with `not supported yet`. Secrets live only in `secrets.conf`. The table mirrors `lib/schema.sh`.

| key | default | options / format |
| --- | --- | --- |
| `SURICATA_RUNTIME` | `native` | `native` `docker` |
| `EVEBOX_RUNTIME` | `native` | `native` `docker` |
| `NTOPNG_RUNTIME` | `native` | `native` `docker` |
| `SURICATA_SOURCE` | `source` | `distro` `oisf` `source`; `oisf` is the OISF PPA on Ubuntu and the COPR `@oisf/suricata-8.0` on the RHEL family; none on Debian |
| `SURICATA_VERSION` | empty | for `source`: empty = the last tested release of the 8.0 series, never `master`; a value is a tag or a branch |
| `NDPI_ENABLE` | `yes` | `yes` `no`; `yes` needs the `ndpi.so` plugin |
| `NDPI_SOURCE` | `source` | `pkg` `source` |
| `NDPI_VERSION` | empty | empty = the nDPI release the Suricata plugin builds with (now `4.14`) |
| `NTOPNG_VERSION` | empty | empty = the latest |
| `EVEBOX_VERSION` | empty | empty = the latest |
| `PIN_VERSIONS` | `no` | `yes` `no`; `yes` = `apt-mark hold` / `dnf versionlock` |
| `SURICATA_MODE` | `ids` | `ids` `ips` |
| `IFACES` | `enp2s0` | interface names, comma separated; if the value is still the default and no such interface exists, `install` takes the default-route interface and says so |
| `BPF_FILTER` | empty | a BPF expression |
| `HOME_NET` | auto | a list of CIDRs; auto = the RFC 1918 ranges |
| `IPS_METHOD` | `nfq` | `nfq` `afpacket` |
| `IPS_NFQ_CHAINS` | `INPUT,OUTPUT,FORWARD` | a subset of these chains |
| `EVE_FILE` | `yes` | `yes` `no`; `no` turns off the event view, the freshness check and the eve metrics |
| `EVE_TYPES` | `alert,flow,dns,tls,http,stats` | from `alert,anomaly,dns,http,tls,files,flow,netflow,ssh,smb,stats,drop` |
| `EVE_SYSLOG` | `no` | `yes` `no` |
| `EVE_REDIS` | empty | `host:port` or empty |
| `EVE_ROTATE` | `daily` | `daily` `weekly` `size` |
| `EVE_KEEP` | `14` | number of rotations |
| `EVE_MAX_SIZE_MB` | empty | a number, needed with `EVE_ROTATE=size` |
| `STATS_INTERVAL_SEC` | `30` | 5..300 |
| `RULES_SOURCES` | `et/open` | `suricata-update` source names, space separated |
| `RULES_URLS` | empty | your own URLs, space separated |
| `RULES_GROUPS` | `emerging-p2p,emerging-policy` | rule groups turned on in `enable.conf` |
| `RULES_UPDATE` | `on` | `on` `off` |
| `RULES_UPDATE_CALENDAR` | `weekly` | systemd `OnCalendar` syntax |
| `NTOPNG_IFACES` | as `IFACES` | interface names, comma separated |
| `NTOPNG_PORT` | `3000` | 1..65535 |
| `EVEBOX_DB` | `sqlite` | `sqlite` `elasticsearch` |
| `EVEBOX_ES_URL` | empty | a URL, needed with `elasticsearch` |
| `EVEBOX_PORT` | `5636` | 1..65535 |
| `EVEBOX_RETENTION_DAYS` | `30` | days, `0` = no limit (SQLite only) |
| `ACCESS_MODE` | `localhost` | `localhost` `lan` `nginx` |
| `LAN_CIDR` | auto | CIDR of the default-route interface network |
| `PANEL_PORT` | `9800` | 1..65535 |
| `PANEL_RUNTIME` | `native` | `native` (unit `dpistack-panel.service`) or `docker` (service `panel` of the same compose project: image `dpistack-panel:<hash of the binary>` built on the host from `alpine`, `network_mode: host`, `pid: host`, `privileged`; host commands go through `nsenter -t 1 -m -u -i -n -p -- env DPISTACK_CALLER=panel dpistack ...`); heavy, affects the `panel` step |
| `PANEL_EDITION` | `full` | `full` (rich dark console with a particle background) or `lite` (the same features on a plain, light page); light, affects the `panel` step; asked in the quick install |
| `PANEL_SOURCE` | `auto` | `auto` (a ready binary next to the installer, else a build), `build` (needs Go) or `prebuilt` (a ready binary only) |
| `NGINX_MANAGE` | `snippet` | `yes` (edits and reloads the system nginx) or `snippet` (writes a file and prints the command) |
| `NGINX_TLS` | `none` | `none` `selfsigned` `existing` |
| `NGINX_CERT` `NGINX_KEY` | empty | paths, needed with `existing` |
| `FIREWALL_MANAGE` | `no` | `no` `auto` (ufw or firewalld, only allow `LAN_CIDR`) |
| `METRICS_EXPORT` | `yes` | `yes` `no`; turns on `GET /metrics` |
| `METRICS_BACKEND` | `none` | `none` `victoriametrics` `prometheus`; `none` = the endpoint only |
| `METRICS_BACKEND_RUNTIME` | `native` | `native` `docker` |
| `METRICS_BACKEND_PORT` | empty | empty = 8428 (VictoriaMetrics) or 9090 (Prometheus) |
| `METRICS_RETENTION` | `30d` | a number with the suffix `h`, `d`, `w` or `y`; other values are refused with a backend |
| `WATCH_ENABLE` | `yes` | `yes` `no` |
| `WATCH_INTERVAL_SEC` | `60` | 10..3600 |
| `WATCH_EVE_STALE_SEC` | `300` | seconds without new events before `crit` |
| `WATCH_DROP_WARN_PCT` `WATCH_DROP_CRIT_PCT` | `1` `5` | percent |
| `WATCH_DISK_WARN_PCT` `WATCH_DISK_CRIT_PCT` | `15` `5` | free space, percent |
| `WATCH_RULES_WARN_DAYS` `WATCH_RULES_CRIT_DAYS` | `10` `30` | age of the rules |
| `WATCH_REPEAT_MIN` | `60` | repeat an alert until the status is `ok` |
| `WATCH_AUTORESTART` | `no` | `yes` `no`; `yes` = at most 3 restarts an hour per component |
| `ALERT_CHANNELS` | `panel,log` | a subset of `panel,log,tg,mail` |
| `ALERT_TG_CHAT_ID` | empty | needed with `tg` |
| `ALERT_MAIL_TO` `ALERT_MAIL_FROM` | empty | addresses, needed with `mail` |
| `TEST_HTTPS_URL` | `https://example.com` | the URL of the live HTTPS test |
| `TEST_BT_LIVE` | `no` | `yes` sends the pcap to a live interface with `tcpreplay` |
| `TEST_ON_INSTALL` | `yes` | `yes` `no` |
| secret `ALERT_TG_TOKEN` | empty | the bot token |
| secret `ALERT_SMTP_URL` | empty | `smtp://user:pass@host:587` |
| secret `METRICS_TOKEN` | generated | 32 random bytes in hex, created with `METRICS_EXPORT=yes` |

Load-time checks (cross checks):

- `NDPI_ENABLE=yes` with `SURICATA_SOURCE` `distro`/`oisf` is allowed only if `ndpi.so` is found after the install; otherwise the installer offers `SURICATA_SOURCE=source` (interactive) or stops with code 2.
- `EVE_TYPES` without `stats` with `WATCH_ENABLE=yes` warns: `eve_fresh` and `drop_rate` get `na`.
- `METRICS_BACKEND` other than `none` with `METRICS_EXPORT=no` is refused; `EVEBOX_DB=elasticsearch` without `EVEBOX_ES_URL` is refused; `EVE_FILE=no` with `EVEBOX_DB=sqlite` is refused.
- `ACCESS_MODE` other than `localhost` needs the confirmation of the warning in section 1 (non-interactive: `--set ACCESS_CONFIRM=yes`, the key is not saved).
- `SURICATA_MODE=ips` works only with `SURICATA_RUNTIME=native`; `IPS_METHOD=afpacket` needs an even number of interfaces (at least two).

Free keys (type `free`) are checked against the patterns of `SCHEMA_PATTERN` in `lib/schema.sh`: no quotes, backslash, `$`, backticks, `;`, braces, and no leading `-`. A rejected secret value is never printed in the error.

### 4.4 Installer CLI and the persistent `dpistack` command

```
install.sh <command> [options]
dpistack [command] [options]

commands: install | reconfigure | upgrade | uninstall | status | diag | test | logs | health | version | ...
options:  --config FILE   --set KEY=VALUE   --non-interactive, -y   --advanced   --dry-run
          --only STEP[,STEP]   --skip STEP[,STEP]   --force   --purge   --no-color
```

With a terminal (or `DPISTACK_INPUT`) and without `-y`, `install`, `reconfigure` and `dpistack` with no arguments open a text menu. `install.sh` with no arguments and no config offers the install; `dpistack` with no arguments and an installed config opens the control menu. **Root only:** every command refuses to run without root (code 1); the panel arrives through `sudo -n` and may run only the control verbs (section 4.5). Exit codes: `0` success, `1` a step failed, `2` bad arguments or config, `3` preflight failed or the change is not supported in this mode. `diag` writes a read-only report (platform, versions, packages, repositories, config without secrets, services, `suricata -T`, log tails) to stdout and to `DIAG_OUT`; tokens and URL passwords become `<hidden>`.

### 4.5 Control verbs of `dpistack`

The only place of privileged actions of the panel and the watchdog: `sudo -n dpistack <verb>`; the sudoers rule names `/usr/local/sbin/dpistack`. All arguments are checked against lists before any action; the allowed characters are letters, digits, `. _ : = / @ + , -` and space, anything else gives code `5`.

| verb | what it does |
| --- | --- |
| `status [--json]` | per component: `id`, `runtime`, `state` (`active` `inactive` `failed` `absent`), `enabled`, `version`; plus `ndpi_plugin` |
| `start\|stop\|restart <id>` | control a component through its runtime; `<id>` only from 4.1 |
| `reload suricata` | reload the rules without stopping |
| `logs <id> [-n N] [--follow\|--until-stdin-closed]` | the component log, `N` up to 1000; the last form ends when stdin closes (for the panel) |
| `config-read <name>`, `config-write <name> [--apply\|--check]`, `config-revert <name>` | config files: stdin, `staging/`, check, backup, atomic replace; `--apply` also reloads the component (or runs `reconfigure` for `dpistack.conf`) |
| `reconfigure [--light] [--dry-run]` | apply the current `dpistack.conf` without questions; heavy changes give code 3 |
| `settings list\|check\|set\|secret\|job` | every setting with checks, weight and busy ports; see the reference in `docs/operations.md` |
| `rules-update`, `rules-sources`, `rules-group`, `rules-sid`, `rules-search` | rules: a rollback if `suricata -T` rejects a set; search returns up to 50 rules |
| `iface list\|add\|remove <name>` | edit `IFACES`, then `reconfigure`; the last interface cannot be removed (3), an unknown one gives 5 |
| `mode ids\|ips [--confirm-timeout SEC]`, `mode status [--json]`, `mode-confirm` | IDS/IPS; `ips` rolls back by itself if `mode-confirm` does not come within `SEC` (10..3600, default 120) |
| `mode-rollback`, `fw apply\|remove\|restore` | internal: the timer rollback and the `DPISTACK` chain (`restore` runs at boot) |
| `test bittorrent\|https\|all [--json]` | section 10 |
| `health [--json]` | one watchdog run |
| `panel-passwd` | the password from stdin, an argon2id hash into `panel.auth` (`-id -t 3 -m 14 -p 4 -l 32`, 16 MiB) |
| `version` | the bundle version |

Config names: `suricata.yaml`, `evebox.yaml`, `ntopng.conf`, `dpistack.conf`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf`. `suricata.yaml` and the rule files pass `suricata -T` on a temporary copy; `dpistack.conf` passes the schema; `evebox.yaml` and `ntopng.conf` are only checked for being non-empty. A failed check changes nothing (code 3, the checker's output goes to stdout). `config-write dpistack.conf` refuses secret keys. Writes take the installer lock (up to 30 s). A file written through `config-write` counts as hand-edited for the installer. Exit codes of the verbs: `0` success, `1` error, `2` misuse, `3` check failed or unavailable in this mode, `4` component missing, `5` name outside the list.

### 4.6 `health.json` and events

`/var/lib/dpistack/health.json` is rewritten atomically by every watchdog run: `{"ts", "overall", "checks":[{"id","status","value","detail","since"}]}`. `status` is `ok`, `warn`, `crit` or `na`; `overall` is the worst one (`na` does not count); `since` changes only when the status changes. Check ids: `<id>.process` and `<id>.port` for `evebox`, `ntopng`, `redis`, `panel` and the metrics backend (`suricata` has only `.process`), then `suricata.eve_fresh`, `suricata.drop_rate`, `disk.free`, `rules.age`. A value exactly at a threshold gives the worse status; the comparison is exact arithmetic.

`events.jsonl` has one line per status change (`ts`, `check`, `from`, `to`, `detail`); the first appearance of a check with `ok` or `na` is not an event. `tests-last.json` holds the last result of each test (`{"results":[{"name","status","detail","duration_ms","timestamp"}]}`), one object per line, mode `0644`; running one test does not erase another's result.

### 4.7 EVE fields the panel and the tests rely on

`timestamp`, `event_type`, `in_iface`, `src_ip`, `dest_ip`, `proto` (all events); `alert.signature`, `alert.signature_id`, `alert.severity`, `alert.category`, `alert.metadata` (`alert`); `tls.sni` (`tls`); `stats.capture.kernel_packets`, `stats.capture.kernel_drops`, `stats.uptime` (`stats`). The nDPI plugin adds the rule keywords `ndpi-protocol` and `ndpi-risk` only; there are no `ndpi.*` fields in EVE. Drop rate of an interval is `delta(kernel_drops) / delta(kernel_packets) * 100`; a counter that went down skips the interval.

### 4.8 HTTP API of the panel

Answers are JSON; an error is `{"error":"text"}` with 4xx/5xx. Every method except `POST /api/login` and `GET /metrics` needs a session; methods that change something need the `X-CSRF-Token` header. **Both editions serve exactly the same API.**

| method and path | what it does |
| --- | --- |
| `POST /api/login`, `POST /api/logout` | session in a `HttpOnly; SameSite=Strict` cookie |
| `GET /api/status` | components (`ctl status`) plus `health.json` |
| `POST /api/components/{id}/{start\|stop\|restart}`, `POST /api/suricata/reload` | through `ctl`; stopping or restarting `panel` needs `?confirm=yes` |
| `GET /api/config`, `GET /api/config/{name}`, `PUT /api/config/{name}?apply=0\|1`, `POST /api/config/{name}/check`, `POST /api/config/{name}/revert` | the config editor |
| `GET /api/rules/sources`, `POST /api/rules/sources`, `POST /api/rules/update`, `GET /api/rules/search?q=`, `POST /api/rules/groups/{group}/{enable\|disable}`, `POST /api/rules/sid/{sid}/{enable\|disable}` | rules |
| `GET /api/logs/{id}?lines=N`, `GET /api/logs/{id}/stream` | the last lines; an SSE live tail (at most 4 streams at once) |
| `GET /api/eve?type=&q=&since=&limit=`, `GET /api/eve/stream?type=` | events, newest first (`limit` 1..500); an SSE stream of new events |
| `GET /api/metrics?range=1h\|6h\|24h` | chart series `pps`, `drops`, `cpu`, `rss`, `eve_size`, `disk` on one grid |
| `POST /api/tests/{bittorrent\|https\|all}`, `GET /api/tests/last` | run a test (a failed test is a result, 200; a second run while one runs is 409); the last results |
| `GET /api/alerts?limit=&check=` | the lines of `events.jsonl`, newest first |
| `GET /api/iface`, `POST /api/iface/{add\|remove}` | capture interfaces |
| `GET /api/mode`, `POST /api/mode` (body `{mode, acknowledged, confirm_timeout}`), `POST /api/mode/confirm` | the IDS/IPS mode |
| `GET /api/settings`, `POST /api/settings/check`, `POST /api/settings/apply`, `GET /api/settings/job`, `PUT /api/settings/secret/{key}` | every setting and the secrets (the schema comes from `dpistack settings list --json`) |
| `GET /metrics` | the Prometheus export (4.9) |

The panel answers 403 if the client IP is outside `LAN_CIDR` (`ACCESS_MODE=lan`) or outside loopback (`localhost`); with `nginx` it trusts `X-Forwarded-For` only from loopback.

### 4.9 Metrics export `GET /metrics`

Prometheus text format 0.0.4. Access: the header `Authorization: Bearer <METRICS_TOKEN>`, no session. With `METRICS_EXPORT=no` the answer is 404, without or with a wrong token 401. Metrics without data are not printed at all.

`dpistack_component_up{component}`, `dpistack_check_status{check}` (`ok`=0, `warn`=1, `crit`=2), `dpistack_suricata_kernel_packets_total`, `dpistack_suricata_kernel_drops_total`, `dpistack_suricata_drop_ratio`, `dpistack_suricata_uptime_seconds`, `dpistack_eve_events_total{event_type}`, `dpistack_eve_size_bytes`, `dpistack_eve_last_event_age_seconds`, `dpistack_disk_free_ratio{path}`, `dpistack_rules_age_seconds`, `dpistack_test_status{test}`, `dpistack_test_timestamp_seconds{test}`, `dpistack_panel_rss_bytes`. The `eve` and `suricata_*` metrics are not printed with `EVE_FILE=no` or without `stats` in `EVE_TYPES`.

## 5. The installer

A **step** is a pair `step_<name>_check` (0 if the state already matches the config) and `step_<name>_apply`, plus `step_<name>_plan` (one line for dry-run). Order: `preflight`, `selfinstall`, `ndpi`, `suricata`, `rules`, `redis`, `ntopng`, `evebox`, `metrics`, `access`, `panel`, `watch`, `verify`. `selfinstall` copies the installer into `/usr/local/lib/dpistack/installer/` and puts it at `/usr/local/sbin/dpistack`.

- **Menu** (`lib/menu.sh`, pure Bash, no dialog or ncurses): input from stdin or `/dev/tty`, `DPISTACK_INPUT=<file>` replaces it (tests). Navigation by number or letter, `0` or empty goes up, `?` helps, `q` quits. The quick install asks the interfaces, the Suricata source, the access mode, **which panel (`full` or `lite`)** and the panel password. Sections: capture, components, EVE, rules, access, metrics, watch, tests, panel password. Basic keys are shown at once, the others behind `a` (or `--advanced`). Edits go to a draft file after every change; `dpistack.conf` changes only when applied. Secrets are entered without echo and shown as "set"/"not set".
- **Install flow:** layers of values (defaults, `dpistack.conf`, secrets and environment, `--config`, `--set`, menu edits), a config check, a summary and a confirmation, `preflight` (all problems are listed, code 3), package preparation, a plan (`--dry-run` stops here, nothing is written, no password is generated), the steps in order (`apply`, then `check` as the post-condition), the `verify` step (`dpistack test all` with `TEST_ON_INSTALL=yes`; a failed test does not cancel the install) and a final report (addresses, test results, the `/metrics` token with a ready `scrape_config`, a generated panel password shown once, warnings). A failed step stops the install and prints how to continue: `install.sh install --only <step>`.
- **Panel password:** typed in the menu; with `-y` it comes from `DPISTACK_PANEL_PASSWORD` or a random 24-character one is generated and printed once. Only an argon2id hash is stored.
- **Reconfigure:** a diff of the applied and the new config, the affected steps, a split into light changes (render and restart) and heavy ones (packages, builds, runtime, version, pinning; they need `--force` or `settings set --apply-heavy`), a render with backups, a `suricata -T` check, then a restart; a failed check keeps the old files.

| key group | steps | weight |
| --- | --- | --- |
| `IFACES`, `BPF_FILTER`, `HOME_NET`, `SURICATA_MODE`, `IPS_*`, `EVE_*`, `STATS_INTERVAL_SEC` | `suricata`; `ntopng` for `IFACES`; `watch` for `EVE_*` | light |
| `RULES_*` | `rules` | light |
| `NTOPNG_*`, `EVEBOX_PORT`, `EVEBOX_RETENTION_DAYS`, `EVEBOX_ES_URL` | `ntopng` or `evebox`, `access` | light |
| `ACCESS_MODE`, `LAN_CIDR`, `PANEL_PORT`, `PANEL_EDITION`, `NGINX_*`, `FIREWALL_MANAGE` | `access`, `panel` | light |
| `WATCH_*`, `ALERT_*`, `TEST_*` | `watch`, `verify` | light |
| `METRICS_EXPORT`, `METRICS_RETENTION`, `METRICS_BACKEND_PORT` | `metrics`, `panel` | light |
| `METRICS_BACKEND`, `METRICS_BACKEND_RUNTIME`, `*_RUNTIME`, `*_SOURCE`, `*_VERSION`, `NDPI_*`, `PIN_VERSIONS`, `EVEBOX_DB`, `PANEL_SOURCE` | the component step | heavy |

- **Idempotence:** a second run with the same config changes nothing (every step says `no changes`). A rendered file keeps the hash of its last render in `state`; a hand-edited file stays and the installer says so; `--force` backs it up and overwrites. Packages are installed only if missing or different from the pinned version. The installer never flushes or recreates other people's iptables/nft chains: its own rules live in the `DPISTACK` chain (or the `inet dpistack` nft table), restored at boot by `dpistack-fw.service`.
- **Preflight:** root, Bash 4.4+, a supported distribution and architecture, systemd (native), Docker with `compose` (if a component uses it), the interfaces of `IFACES` exist, free space (4 GB for a source build, else 1 GB), the needed hosts reachable, the ports free (with nginx also the port behind it), the SELinux mode. A busy port in the menu is a warning with the process name and a free port to take; without a terminal the install stops with code 3. All problems are printed, not just the first.
- **dnf family:** `dnf makecache`, base packages only for missing commands, `epel-release` and `crb` (`powertools` on 8) for Rocky, AlmaLinux and CentOS, `dnf versionlock`, the OISF COPR when Rust is too old. The SELinux contexts and ports of the components are set with `semanage` and `restorecon`.
- **Source builds:** build dependencies are installed first; Suricata from git needs Rust 1.85 (a `rustc-1.N` package is used when the system one is older); with Rust 1.75 only, a distribution or OISF package is taken and nDPI is turned off with a message.
- **Modes and secrets:** non-interactive values come from `--config`, `--set`, then defaults; a prompt there is an error. `--dry-run` prints `+ command` and writes nothing. Secrets never get into `dpistack.conf`, the install log or the dry-run output; `set -x` is forbidden.
- **Upgrade and uninstall:** `upgrade` respects `PIN_VERSIONS`. `uninstall` stops and removes units, binaries and the installer copy, the `DPISTACK` chain and the ufw/firewalld rules dpistack added, and restarts Suricata that was running in NFQ; it keeps data and configs. `--purge` removes those too (the flag is the confirmation; in the menu you type `remove`).

## 6. Suricata and nDPI

- **Capture:** `af-packet`, a block per interface of `IFACES`, `cluster-type: cluster_flow`, `defrag: yes`, `threads: auto`, a unique `cluster-id`; `BPF_FILTER` is added if set.
- **nDPI:** with `NDPI_ENABLE=yes` the `ndpi.so` of the installed Suricata is added to `plugins:`. Rules with `ndpi-protocol` or `ndpi-risk` must start with `requires: keyword ...` so a Suricata without the plugin skips them. A source build uses `./configure --enable-ndpi --with-ndpi=<prefix>`; an incompatibility is shown as is.
- **Config:** `suricata.yaml` is rendered fully from the template, matches the built Suricata series (`suricata-version`) and is checked with `suricata -T` before it is written; one template serves IDS and IPS.
- **IDS to IPS:** `mode` turns on `afpacket` copy-mode or NFQUEUE rules in the `DPISTACK` chain (with `--queue-bypass`, so a stopped Suricata does not cut the network), restarts Suricata and starts a rollback timer; without `mode-confirm` in time the mode returns to `ids`. `drop` rules come from `drop.conf`; none are created.
- **EVE:** the types of `EVE_TYPES`, `stats` every `STATS_INTERVAL_SEC`, mode `0640`, `logrotate` without `copytruncate` and `suricatasc -c reopen-log-files` afterwards.

## 7. Rules

Sources `RULES_SOURCES` and `RULES_URLS`; local rules in `local.rules` are always loaded; `RULES_GROUPS` become `group:<name>.rules` lines in `enable.conf`; single rules are turned off in `disable.conf`. `dpistack-rules.timer` (`OnCalendar=$RULES_UPDATE_CALENDAR`, `Persistent=true`): snapshot, `suricata-update`, `suricata -T`, reload; any failure restores the snapshot and leaves `rules.age` growing (the watchdog sees it). `RULES_UPDATE=off` creates no timer.

## 8. Watchdog

`dpistack-watch` runs from a timer every `WATCH_INTERVAL_SEC` as a oneshot root job and fixes nothing unless `WATCH_AUTORESTART=yes`.

| check | how | ok / warn / crit |
| --- | --- | --- |
| `<id>.process` | state through the runtime | active / absent from the check list (`na`) / failed or inactive |
| `<id>.port` | `ss -ltn` on the configured port (with nginx the service port, plus 10000; redis 6379) | listening / missing 1-2 runs / missing 3 or more runs |
| `suricata.eve_fresh` | age of `eve.json` by mtime | younger than `WATCH_EVE_STALE_SEC` / file missing / older |
| `suricata.drop_rate` | the last two `stats` events (the last 4 MB of the file) | below `WARN` / from `WARN` / from `CRIT` |
| `disk.free` | the smallest free share of the Suricata log, EveBox data (sqlite) and metrics backend partitions | above `WARN` / below `WARN` / below `CRIT` |
| `rules.age` | age of `suricata.rules` | younger than `WARN_DAYS` / from `WARN_DAYS` or file missing / from `CRIT_DAYS` |

`na` means the check does not apply (`EVE_FILE=no`, no `stats`, `RULES_UPDATE=off`, component absent). With `WATCH_AUTORESTART=yes` a failed component is restarted through `restart <id>` at most 3 times in a sliding hour. **Alerts** go out on a status change and repeat every `WATCH_REPEAT_MIN` until `ok`; a recovery message is sent on return to `ok`. Channels of `ALERT_CHANNELS` work independently: `panel` (a line in `events.jsonl`), `log` (`logger`), `tg` (the Bot API through `curl`) and `mail` (`curl --url "$ALERT_SMTP_URL"`, no local MTA). A failing channel is logged and does not stop the others. Messages are English, one line per check.

## 9. The panel

**Budget:** idle RSS at most 25 MB, the binary at most 15 MB, the static files at most 150 KB, zero CPU with no open tab and no `/metrics` request. The unit has `ProtectHome=yes`, `PrivateTmp=yes`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`; it has **no `MemoryMax` and no `CPUQuota`** (decision of 2026-10-24: the lite edition is the way to a lighter panel). `NoNewPrivileges` and `ProtectSystem` are left out: `sudo` inherits the unit's restrictions and `dpistack` could not write to `/etc`.

**Editions (v0.23.0).** `PANEL_EDITION=full|lite` replaced `PANEL_MODE=limited|unlimited`. Both editions have the same screens, the same API and the same features. The server picks the files: the page always asks for `app.css` and `fx.js`; the `full` edition answers with `full.css` and `fx.js`, `lite` with `lite.css` and an empty `nofx.js`, so a lite page never downloads the full design.
- **full:** a dark console in the style of premium developer tools: near-black background, matte cards with hairline translucent borders and soft inner highlights, one cool-blue accent used sparingly, a left sidebar with a brand mark and thin line icons (an active pill with a faint glow), capsule controls, staggered entrance animations of 150-550 ms with a gentle easing curve, hover lifts, and a quiet background of drifting points joined by faint lines drawn on a canvas (`fx.js`: dim, capped at 70 points and 2x pixel ratio, paused while the tab is hidden, one still frame under `prefers-reduced-motion`). System fonts only (`Inter`, `Geist`, `Manrope` when installed), because the policy forbids external fonts. Narrow screens turn the sidebar into a top strip.
- **lite:** the plain, light page with system fonts, a small stylesheet, no canvas, no animations; it follows `prefers-color-scheme`.
- The installer asks for the edition in the quick install, the Settings screen and `dpistack settings set --apply PANEL_EDITION=...` switch it (light weight: the unit is rendered again and restarted). An old `dpistack.conf` with `PANEL_MODE` still loads: the key is dropped.
- Screens in both editions: Overview, Components, Settings, Configs, Rules, Logs, Events, Metrics, Tests, Alerts. Interface rules: no external fonts, scripts or images, no inline scripts or styles (CSP), `textContent` instead of `innerHTML`, charts as inline SVG, a hash router, a plain `<textarea>` editor, dangerous actions behind a confirmation.

**Behavior:** `eve.json` is read incrementally from a saved offset (never parsed whole; a first read takes at most 4 MiB from the end); a ring of at most 5000 events in memory. The graph ring is 24 hours at 30-second steps with a snapshot into `metrics.json` once an hour and on stop; `/metrics` is built from the same data and reads the disk at most once a second. `status` polling every 10 s only while the tab is visible; SSE opens only on the logs and events screens. One administrator, argon2id, 5 sign-in attempts per 5 minutes per IP, a 12-hour session. Every changing request needs the CSRF token. Client address: the connection address, `X-Forwarded-For` only from loopback (the last entry). Flags are passed by the unit (the panel does not read `dpistack.conf`): `-addr`, `-access`, `-lan-cidr`, `-auth-file`, `-health-file`, `-ctl`, `-tests-file`, `-events-file`, `-eve-file`, `-metrics-file`, `-metrics-token-file`, and `-lite` for the lite edition. In a container the panel calls `dpistack` through `nsenter` with `DPISTACK_CALLER=panel`.

## 10. Check tests (`dpistack test`)

Result: `{"name","status","detail","duration_ms"}`, `status` is `pass`, `fail` or `skip`; the outcome goes to `tests-last.json`. Exit code `0` for all `pass` or `skip`, `1` if any `fail`.

- **`bittorrent`** (offline): `suricata -r tests/data/bittorrent.pcap` with the config of `suricata-test.yaml.tpl` into a temporary directory; `pass` if an `alert` whose signature contains `BitTorrent` appears. With the nDPI plugin loaded the test adds its own `ndpi-protocol:BitTorrent` rule (sid 9000001). `skip` with the reason if there are neither `emerging-p2p` rules nor the plugin. `TEST_BT_LIVE=yes` also replays the pcap into the first interface with `tcpreplay`.
- **`https`** (live): `curl --max-time 15 "$TEST_HTTPS_URL"`, then waits up to 20 s for a `tls` event with `tls.sni` equal to the host; `fail` at once if `eve.json` is missing, and the detail names the cause (curl failed, no event, the capture interface differs from the one curl uses).
- **`all`** runs both; `verify` runs it with `TEST_ON_INSTALL=yes`.

## 11. Project tests

Tests come from acceptance criteria, not from finished code. Bash: `bats` with stubs of external commands in `tests/mocks/` through `PATH`, paths redirected with `DPISTACK_ROOT`, and the test-only variables `DPISTACK_INPUT`, `DPISTACK_TEST_WAIT`, `DPISTACK_NOW`. Go: `go test` with `httptest` and the `ctl.Runner` interface. Interface: `node --test` for the pure logic. A forbidden kind of test: "ran the step, checked for 0"; a test checks a result (file content, the commands called, a refusal). Every change brings a test for each criterion, one for the error path and, for installer steps, one for idempotence. Platform matrix before a release: Ubuntu 22.04 and 24.04, Debian 12 and 13, Rocky Linux or AlmaLinux 8, 9 and 10, each with `install -y`, `distro` and `oisf` sources where they exist, a repeat install, `reconfigure`, `upgrade`, `uninstall --purge` and `dpistack test all`.

## 12. Checks and the gate

`scripts/gate.sh` runs `shfmt -d`, `shellcheck -x -S style`, `scripts/security.sh`, `scripts/bundle.sh --check`, `scripts/check-conf-example.sh` (the keys and defaults of the example against 4.3 and the schema), `scripts/gen-config-doc.sh --check` (both reference files), `bats tests` and, if `panel/` is there, `gofmt -l`, `go vet`, `go test`, `node --test` and `scripts/panel-budget.sh`. A red gate means the work is not done.

- **CI/CD (`.github/`):** the `ci` workflow runs the gate on Ubuntu 22.04 and 24.04 (with a timeout), plus `actionlint`, `gitleaks` and `trivy`; the `security` workflow runs `scripts/security.sh`; a release is the tag `vX.Y.Z` on `main` (a tag off `main` is not published): binaries of the panel, the single-file installer and build provenance. GitHub actions are pinned by SHA, updates come from Dependabot.
- **Suricata release watch:** `suricata-watch.yml` runs weekly: it builds the pinned release with the installer, compares the pinned tag with the final `OISF/suricata` tags, builds a newer release of the same series and opens an issue ("verified: raise SURICATA_STABLE_REF" or "failed the build check"), and announces a newer series once. It changes nothing in the repository.
- **Branches and merging:** `main` is protected (checks `gate (ubuntu-22.04)`, `gate (ubuntu-24.04)`, `lint workflows`, `gitleaks`, `shell security checks`, `trivy (config and secrets)`; pull requests only; no force-push). Work goes to `dev`; a commit must pass the local gate and the GitHub checks; only when everything is green is a PR `dev` to `main` opened and merged with a merge commit (not squash, not rebase), message `merge dev into main: <what went in>`. A release is a tag on `main`.
- **Security checks (`scripts/security.sh`):** secrets in tracked files, `eval` and `bash -c` over a built string, `curl | sh`, group/other-writable `chmod`, fixed `/tmp` paths and `mktemp -u`, `set -u` in every entry point, CRLF, secrets in `curl` arguments (they go through `-K -` on stdin).

## 13. Conventions

- **Language.** The program is English only: messages, menus, errors, the panel text, comments. Documents are written in English first and kept in Russian next to them (`X.md` and `X.ru.md`, each linking to its twin); both are changed together, and `tests/docs.bats` checks that every document has its twin. Generated references (`docs/configuration.md`, `docs/configuration.ru.md`) come from `scripts/gen-config-doc.sh` (English hints live in `settings-model.js`, Russian ones in `scripts/config-hints.ru`).
- **Decisions marked "choose yourself"** are taken by the developer and recorded in this file. When a contract is missing, stop and ask the owner instead of inventing a key or a field.
- **Prefer ready-made solutions** (packages, images, tools) to writing code from scratch.
- **Tests, CI/CD and security checks** are part of the project and are documented here (sections 11 and 12).
- **Git workflow for this repository:** commit to `dev`, wait for the tests, and only if everything is green merge `dev` into `main` (12, Branches and merging). The version of the program in `lib/common.sh` and in this file change together.
- **Tokens** given for GitHub access are used for the session only and are never written into the repository, the remote URL or any memory file.

## 14. Decisions

- **2026-10-24, v0.23.0.** `PANEL_MODE` (limited/unlimited) removed together with the unit limits `MemoryMax=64M` and `CPUQuota=20%` and the `-max-streams` flag (the cap is 4 streams); `PANEL_EDITION=full|lite` added and asked in the quick install. The `full` panel was redesigned (dark matte surfaces, one blue accent, sidebar, entrance animations, particle background); `lite` keeps every feature with a plain, light page. The program was translated to English; documents became English first with Russian twins. This file was cleaned: the changelog, the slice results and the review logs were removed (they stay in the git history).
- **Earlier decisions that still hold:** `dpistack` and `dpistack-ctl` are one program; the dashboard holds every setting of the program; components can run on the host or in Docker in any combination; a busy port gives a warning and a choice; `suricata.yaml.tpl` matches the built Suricata series and is checked with `suricata -T`; the `dpistack` command must run as root and refuses otherwise; `main` is protected and receives only tested merges from `dev`.
