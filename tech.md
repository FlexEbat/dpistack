# tech.md: dpistack (nDPI + Suricata + EveBox + ntopng)

**Document version: v75** (2026-11-12)
**Program version: v0.46.0** (slices 0-45 are done; the index of slices, with what is done and what remains, is 18.0; the assumptions are in section 17)

This is the source of truth of the project: the names of config keys, paths, commands, metrics, fields and endpoints come from here. Each change of a contract raises the version above. The file is English only (the README and the guides in `docs/` also come in Russian). It holds the whole history of the project: the changelog below, the results of the slices (17) and the logs of the reviews (18). The Russian original of v31 is in the git history (`02929a8`); v32 removed the history, v33 restored it in English and brought the contracts of sections 4-12 up to date with v0.24.0.

Program changelog. Only the last five entries are kept; older ones are deleted (they stay in the git history). Add the new entry on top and delete the oldest when there are more than five:
- v0.46.0: slice 45, the security of the panel (18.45): a Security screen with the security check (access mode, TLS, default ports, accounts that do not sign in, rule file permissions, files with secrets), your sessions (where from, end one, end all the others), API tokens (a script signs in with `Authorization: Bearer`; read only or by role, never more than its owner, 1 to 365 days, shown once, only a hash kept) and the history of sign ins; an administrator can sign everyone out. New verbs `tokens create|list|revoke` and `security check`, file `api-tokens.json`, routes `/api/security/...`. The gate of the CI runs on Ubuntu 24.04 (D110).
- v0.45.0: slice 44, Settings v2 (18.44): the Settings screen in three columns (categories with a search, the keys, and the details of the key in focus with the staged change and the profiles); a key that does not apply with the values as they are is dimmed with the reason (the rules of the guided setup, now data in the schema); for every key the default, the allowed values, what it depends on and what a change touches; a diff of the staged change, and Apply opens only after a check of exactly those values has passed; profiles, named sets of keys saved and loaded into the staged change. `settings list --json` has `steps`, `touches` and `depends` per key; new verb `settings profile list|show|save|delete|apply`, file `profiles.json`, routes `GET /api/settings/profiles[/{name}]`, `PUT` and `DELETE /api/settings/profiles/{name}`. The gate of the CI may now run 45 minutes, not 30, and it runs on Ubuntu 22.04 only.
- v0.44.0: slice 43, the Alert Center (18.43): the alerts of the watchdog (a check that is warn or crit) and of Suricata (one per rule, from the tail of `eve.json`) with a state a person sets (new, acknowledged, snoozed for 1 h, 4 h, 24 h or 7 d, resolved), a list of decisions and filters, on the Alerts screen above the feed of status changes; the bell of the top bar (the count of new alerts, the piece of slice 37 that waited). New verb `alerts list|history|ack|snooze|resolve|reopen`, the state in `alerts-state.json`, routes `GET /api/alert-center`, `GET /api/alert-center/history`, `POST /api/alert-center`; `GET /api/alerts` is unchanged. `ips status` no longer loses its counters when the log tail cuts a line.
- v0.43.0: slice 42, the IPS page (18.42): a new IPS screen with the readiness of IPS (mode, Suricata, the queue rules, whether a process listens on the queue, the confirmation timer), the packet counters of the newest stats event, the number of drop rules and the latest blocked events, and a rule test that replays a shipped pcap through Suricata offline in simulated IPS mode and says which rules would drop. New verb `ips status|test` (read only, the screen shows its JSON), routes `GET /api/ips` and `POST /api/ips/test`; no new config key, no change to the Suricata config or the firewall rules.
- v0.42.0: slice 41, Rules v2 (18.41): the counts per rule source, the history of updates, a rule search by category, source, state and text (disabled rules included), a check of `local.rules` (not a rule, no sid, a sid used twice or by the rule set, `suricata -T`) and the history of changes of a config file with a comparison. New verbs `rules-stats`, `rules-history`, `rules-describe`, `rules-find`, `rules-facets`, `rules-local check`, `config-history`; `rules-update` records each update. Findings R218 and R219.

Changelog of this document. Only the last five entries are kept; older ones are deleted (they stay in the git history):
- v75: v0.46.0. 18.45 (slice 45) written; the slice 45 row of 18.0; 4.4 `api-tokens.json`; 4.5 the verbs `tokens` and `security`; 4.8 the Bearer way in and the routes of the Security screen; the screens text; the test list; D110 (the gate on 24.04) already in 12; decisions D111 to D118.
- v74: v0.45.0. 18.44 (slice 44) written; the slice 44 row of 18.0; 4.5 `settings list` keys and the `settings profile` verb; 4.8 the routes of the profiles; `profiles.json` in the list of 4.4; the description of the Settings screen (v0.45.0); the test list; the limit and the system of the gate in 12; decisions D103 to D109.
- v73: v0.44.0. 18.43 (slice 43) written; the slices 37 and 43 rows of 18.0; 4.5 the `alerts` verb; 4.8 the routes of the Alert Center; the state file in the list of 4.4; the test list; decisions D96 to D102; 18.42 corrected (R223: its audit test looked at the wrong file).
- v72: v0.43.0. 18.42 (slice 42) written; the slice 42 row of 18.0; 4.5 the `ips` verb; 4.8 the routes of the IPS page; the screens list; the test list; decisions D90 to D95.
- v71: v0.42.0. 18.41 (slice 41) written; the slice 41 row of 18.0; 4.5 the verbs of Rules v2; 4.8 the routes of Rules v2; decisions D84 to D89.

---

## Domain (in brief)

- **DPI (deep packet inspection):** finding the application protocol of a flow from the content of packets, not from the port number. The **nDPI** library (ntop) does this and gives flows "risks" (a self-signed certificate, a protocol on a non-standard port and so on).
- **Suricata:** a signature engine. In **IDS** mode it looks at a copy of the traffic and only reports, in **IPS** mode it stands in the path and can drop packets. The nDPI plugin adds the rule keywords `ndpi-protocol` and `ndpi-risk`. The plugin exists only in a Suricata build with `--enable-ndpi`.
- **EVE JSON:** the line-by-line JSON log of Suricata (`alert`, `flow`, `dns`, `tls`, `http`, `stats` and others). The single source of data for EveBox, the panel, the watchdog and the tests.
- **EveBox:** a web viewer of Suricata alerts (the "Inbox"), stores events in the built-in SQLite or in Elasticsearch.
- **ntopng:** a real-time web traffic monitor (hosts, flows, protocols), uses Redis and its own copy of nDPI.
- **Rules:** sets of signatures. The default source is Emerging Threats Open through `suricata-update`. The groups `emerging-p2p` and `emerging-policy` catch BitTorrent and policy violations.
- **Metrics:** numeric series over time. The Prometheus format (`/metrics`) is read by Prometheus, VictoriaMetrics and `vmagent`.
- **The point where traffic is taken:** passive capture (`af-packet`) sees only the packets that pass through the interface of the host itself. To see the whole network you need a mirror port, a gateway or an in-line position. A host outside the path of the network, with NFQUEUE in the `INPUT`/`OUTPUT` chains, protects only itself.

## Specification (in brief)

1. **The installer** `install.sh` in Bash: interactive (a CLI menu) and non-interactive modes, idempotent, with `--dry-run`, `reconfigure`, `upgrade`, `uninstall`. After the install it is available as the persistent command `dpistack` with the same menu for configuring, status, logs, tests, upgrading and removing.
2. **It installs** nDPI, Suricata, Redis, ntopng, EveBox, the systemd units, the EVE config, logrotate. The user chooses the Suricata source (distribution packages, OISF, sources), the pinning of versions and the way each component is deployed (`native` or `docker`).
3. **OS:** Ubuntu LTS from 22.04, Debian from 12, Rocky Linux and AlmaLinux from 8 (the owner's decision, v12). RHEL and CentOS Stream are not a goal yet: they start with a warning, support is added by a separate decision. Fedora starts with a warning.
4. **Capture:** IDS mode by default, IPS optional. Interfaces: a list, `enp2s0` by default, adding and removing without a reinstall. There is an offline pcap replay.
5. **Rules:** ET Open plus additional and your own sources, an automatic update once a week (configurable), the p2p and policy groups are on.
6. **Access to the web interfaces:** `localhost`, `lan` or through `nginx`. An external SSO is not needed.
7. **Checks:** BitTorrent (a pcap replay) and ordinary HTTPS (a live request) with an automatic verdict.
8. **Watchdog:** checks processes, ports, the freshness of `eve.json`, the drop rate, disk space, the age of the rules. Alerts: the panel, a log, Telegram, mail, the channels combine.
9. **Metrics:** the panel serves `/metrics` in the Prometheus format. Optionally the installer installs VictoriaMetrics or Prometheus and sets up the collection.
10. **A personal panel:** light on resources, a modern look. Features: the status of components, start/stop/restart, a config editor with validation (`suricata -T`), rule management, running tests, viewing logs and EVE events, metrics charts.
11. **This is a finished and full project, not an MVP.** Every declared feature is brought to a working state on every supported platform and checked on a stand; there are no "we will do it after the MVP" items in the plan. The required platforms: Ubuntu LTS from 22.04, Debian from 12, Rocky Linux and AlmaLinux from 8 (section 11, the platform matrix). Only stable versions: development builds (`master`, `nightly`, `latest`, `dev`) are not used anywhere by default. Release 1.0 is possible when all stages 0-5 are closed and every platform has passed acceptance. The order of the stages sets the order of work, not its volume; slice 26 (the RHEL family) is done out of turn because the platform is required.
12. **The project says it is under development.** One sentence says so in the README (both languages), in the CLI (the usage text and the install menu) and in the dashboard (the login page and the menu): "Under development: dpistack is still being developed. Settings, commands and screens can change between releases." (the Russian README has its own wording). A test compares the sentence in every place, so the wording cannot drift. Rule 11 stays: the features that are declared work; the notice is about change between releases, not about missing parts.
13. **Out of scope:** a multi-user panel, an own SSO, Grafana dashboards of our own (Grafana itself is an optional component since v0.24.0), ntopng Enterprise, podman, LXD, i18n, capturing the traffic of a whole network without a suitable topology.

---

## 0. How to read this file

This is the source of truth of the project. Read it before every task and follow it to the letter.

- The names of config keys, paths, commands, metrics, fields and endpoints come from here. Do not invent your own variants.
- The contract you need is not here: STOP and give a `CONTRACT GAP` block (section 15). Do not write code with an invented key or field.
- Only the owner of the project changes this file. Every change of a contract raises the version at the top of the file.
- Work one slice at a time. The index of slices is 18.0 and every slice has its entry in section 18; go from the top down.

---

## 1. Project

A set of an installer, two service scripts and a panel for a home or small DPI/IDS lab. One host, one administrator.

The goal: a working bundle that one command sets up, that is managed from a browser and that reports its own failures. It is not a SIEM, not a platform for several hosts and not a replacement for an industrial NDR.

The topology limit: the host sees only the traffic of its own interface. The installer prints this warning when interfaces are chosen and does not promise visibility of the whole network.

**The threat model (in short):**

- The config editor of the panel gives root-level access to the host: edits of `suricata.yaml` and starting components allow running foreign code. The allow-list in `dpistack` protects against arbitrary commands, but not against harmful config edits. A hacked panel is a hacked host.
- That is why `ACCESS_MODE=localhost` is the default, signing in with a password is required and cannot be turned off. The installer turns `lan` and `nginx` (and any address other than loopback in `BIND_ADDR`) on only after an explicit confirmation of the warning.
- The panel itself serves HTTP without TLS. The password and the `/metrics` token are visible on the network in `lan`, so the installer recommends `nginx` with TLS or an SSH tunnel.
- `eve.json` holds traffic metadata (SNI, DNS names, addresses). Permissions: `0640`, the access group is only Suricata and the `dpistack` user.
- The persistent command `dpistack` runs as root only (a direct run by the administrator, or `sudo`). The panel reaches only the control verbs (section 4.5) through `sudo -n dpistack <verb>`; for that caller `dpistack` allows nothing but those verbs (not `install`, `upgrade`, `uninstall`) and checks every argument against lists. The second command name `dpistack-ctl` of the versions up to v0.23.0 no longer exists (v0.24.0): there is one program.

---

## 2. Stack and platforms

- The installer and `dpistack-watch`: Bash 4.4+, no Python and no Perl. External utilities: `curl`, `jq`, `ss`, `ip`, `systemctl`, `sed`, `awk`, `tar`, `flock`. The installer brings the missing packages in the `preflight` step.
- The panel: Go 1.26+, only `net/http` from the standard library. The only external dependency: `golang.org/x/crypto` (argon2id) v0.58.0 (the latest on 2026-10-12; it pulls in `golang.org/x/sys` v0.49.0). The minimum Go is set by the `go` directive in `panel/go.mod`: `actions/setup-go` in CI follows it, and `PANEL_SOURCE=prebuilt` does not need Go on the host. A host whose Go is missing or older than that is not a blocker when Docker runs: the panel is built in the image `golang:<major.minor of go.mod>` (v0.25.2, 18.27). The `/metrics` format is written by hand, without `client_golang`. The front end: plain ES modules and CSS, no bundler, no frameworks, no icon fonts.
- Tests: `bats` for Bash, `go test` for the panel, `node --test` for the pure logic of the interface.
- Checks: `shellcheck`, `shfmt`, `gofmt`, `go vet`.
- Package managers: `apt` (Ubuntu, Debian), `dnf` (Rocky Linux, AlmaLinux; RHEL, CentOS Stream and Fedora with a warning); `zypper`, `pacman` and `generic` with the components in Docker (v0.22.0). Supported: Ubuntu LTS from 22.04 (22.04, 24.04, 26.04, then by LTS), Debian from 12, Rocky Linux and AlmaLinux from 8. Releases older than these are refused by `preflight` with code 3 (Ubuntu 20.04 and older, Debian 11 and older, EL 7 and older), at your own risk it can be bypassed with `DPISTACK_ALLOW_UNSUPPORTED=1`. Intermediate Ubuntu releases, RHEL and CentOS Stream from 8, Fedora and derivatives (Mint) start with a warning.
- Architectures: `amd64`, `arm64`.
- Containers: Docker with the `compose` plugin only.

No ORM, no database in the panel, no Node/npm at runtime, no CSS frameworks.

---

## 3. Repository structure

```
install.sh                    the entry point: argument parsing, loading lib/, running the steps
dpistack.conf.example         an example config with every key
README.md  README.ru.md  LICENSE  SECURITY.md  AGENTS.md  CONTRIBUTING.md  tech.md
.github/
  workflows/ci.yml            the gate on every push and pull request (12.1)
  workflows/security.yml      gitleaks, security.sh, trivy (12.1)
  workflows/release.yml       build and publication by the tag vX.Y.Z (12.1)
  workflows/suricata-watch.yml  the weekly check of Suricata releases (12.4)
  dependabot.yml
docs/                         the guides, English and Russian (*.ru.md); configuration*.md is generated
lib/
  paths.sh                    every path of the system from the prefix DPISTACK_ROOT
  common.sh                   log, run (honors dry-run), die, lock, atomic_write, backup
  schema.sh                   the key table: name|type|default|options|level|group|affected steps|weight|secret
  config.sh                   loading, checking by the schema, questions, saving, the diff of old and new
  menu.sh                     the text menu of install and reconfigure (section 5.0)
  os.sh                       OS detection, the wrappers pkg_install/pkg_repo_add/pkg_pin
  state.sh                    the state of the steps and the hashes of rendered files
  render.sh                   substitution of @@KEY@@ and blocks in templates/
  ctl.sh                      the control verbs of dpistack (section 4.5)
  step_preflight.sh
  step_selfinstall.sh         a copy of install.sh, lib/, templates/ into the system and the binary /usr/local/sbin/dpistack
  step_ndpi.sh
  step_suricata.sh
  step_rules.sh
  step_redis.sh
  step_ntopng.sh
  step_evebox.sh
  step_metrics.sh             VictoriaMetrics or Prometheus and setting up the collection
  step_nodeexp.sh             node_exporter (optional)
  step_grafana.sh             Grafana (optional)
  step_access.sh              bind modes, the listen address, nginx, firewall, SELinux
  step_panel.sh
  step_watch.sh
  step_verify.sh              the final tests after the install
  runtime_docker.sh           compose
templates/
  suricata.yaml.tpl
  suricata-test.yaml.tpl      a minimal config for the offline tests
  evebox.yaml.tpl
  ntopng.conf.tpl
  nginx.conf.tpl
  compose.yaml.tpl
  scrape.yaml.tpl             the metrics collection config for VictoriaMetrics and Prometheus
  grafana.ini.tpl  grafana-datasource.yaml.tpl
  logrotate.tpl
  sudoers.tpl
  *.service.tpl  *.timer.tpl
bin/
  dpistack-watch              the watchdog (section 8)
panel/
  go.mod
  cmd/panel/main.go
  internal/{api,auth,ctl,eve,export,metrics,health}/
  web/                        index.html, full.css, lite.css, fx.js, nofx.js, app.js, modules/*.js, embed.go (go:embed: the static files are inside the binary)
tests/
  data/bittorrent.pcap        a handshake, documentation IPs
  data/README.md              how the pcap was recorded
  mocks/                      stubs of external commands for bats
  helpers/verbs               a test helper: runs the verbs of dpistack (DPISTACK_VERBS_ONLY=1)
  *.bats
scripts/
  gate.sh
  security.sh
  bundle.sh                   gluing into the single file dpistack-install.sh
  gen-config-doc.sh           the settings reference (English and Russian) from the schema
  config-hints.ru             the Russian hints for that reference
```

Placement rules:

- The paths of system files are built only in `lib/paths.sh` from the prefix `DPISTACK_ROOT` (empty by default). The tests substitute a temporary directory. There are no direct `/etc/...` in the steps.
- A step does not call system commands directly, only through `run` from `common.sh` (dry-run and the log).
- Logic that depends on the OS lives in `os.sh`. The steps call `pkg_install`, not `apt-get` or `dnf`.
- Logic that depends on the way of deployment lives in `runtime_docker.sh` and the steps. The steps do not call `docker` outside it.
- The panel runs no commands except `sudo -n dpistack <verb>`. The panel itself reads only `eve.json`, `health.json`, `events.jsonl`, `tests-last.json`, `metrics.json` (it also writes that one), does a `stat` on `suricata.rules` and a `statfs` on the data directories.

---

## 4. Contracts (frozen)

### 4.1 Components

| id | what it is | runtime | unit / container |
| --- | --- | --- | --- |
| `suricata` | the IDS/IPS engine | native, docker | `suricata.service` |
| `evebox` | the alert viewer | native, docker | `evebox.service` |
| `ntopng` | the traffic monitor | native, docker | `ntopng.service` |
| `redis` | the store of ntopng, always where `ntopng` is | as `ntopng` | `redis.service` (rpm) or `redis-server.service` (deb), resolved by `os.sh` |
| `victoriametrics` | the metrics backend, only with `METRICS_BACKEND=victoriametrics` | native, docker | `dpistack-vm.service` |
| `prometheus` | the metrics backend, only with `METRICS_BACKEND=prometheus` | native, docker | `prometheus.service` |
| `node_exporter` | host metrics, only with `NODE_EXPORTER_ENABLE=yes` | native, docker | `dpistack-node-exporter.service` |
| `grafana` | dashboards, only with `GRAFANA_ENABLE=yes` | native, docker | `dpistack-grafana.service` |
| `panel` | the control panel | native, docker | `dpistack-panel.service` |
| `watch` | the watchdog | native only | `dpistack-watch.timer` |
| `rules` | the rules update | native only | `dpistack-rules.timer` |

`ndpi` is not a component: it is a library, and the plugin `ndpi.so` is a part of `suricata`. Its state is shown by `dpistack status` in a separate field `ndpi_plugin`.

### 4.2 Paths

| what | path |
| --- | --- |
| the install config | `/etc/dpistack/dpistack.conf` (0644 root) |
| the menu draft | `/etc/dpistack/dpistack.conf.draft` (0600 root) |
| secrets | `/etc/dpistack/secrets.conf` (0600 root) |
| the panel password hash | `/etc/dpistack/panel.auth` (0640 root:dpistack) |
| API tokens | `/etc/dpistack/api-tokens.json` (0640 root:dpistack, beside `users.json`; only the SHA-256 of each token, never the token; written only by `dpistack tokens`) |
| state | `/var/lib/dpistack/` (`state`, `health.json`, `events.jsonl`, `tests-last.json`, `metrics.json`, `alerts-state.json`, `profiles.json`, `backups/`, `archives/`, `staging/`, `scrape.yaml`) |
| the lock | `/var/lock/dpistack.lock` |
| the install log | `/var/log/dpistack/install.log` |
| helpers | `/usr/local/sbin/dpistack` (the persistent command, section 5.2), `/usr/local/sbin/dpistack-watch`, libraries and templates in `/usr/local/lib/dpistack/` (among them the installer copy in `/usr/local/lib/dpistack/installer/`) |
| the panel | `/usr/local/bin/dpistack-panel` |
| node_exporter | `/usr/local/bin/node_exporter` |
| Grafana | `/opt/dpistack/grafana/` (the program), `/etc/dpistack/grafana.ini`, `/etc/dpistack/grafana-provisioning/`, data in `/var/lib/dpistack-grafana/` |
| Suricata | `/etc/suricata/suricata.yaml`, `/etc/suricata/{enable,disable,modify,drop}.conf`, `/etc/suricata/rules/local.rules`, `/var/lib/suricata/rules/suricata.rules`, `/var/log/suricata/eve.json` |
| the Suricata socket | native: `/run/suricata-command.socket` (the stock `suricata.yaml` creates it too, and `suricatasc` goes to it by default); docker: `/var/run/suricata/suricata-command.socket` inside the container, `run/suricata/` on the host |
| EveBox | `/etc/evebox/evebox.yaml`, port 5636 |
| ntopng | `/etc/ntopng/ntopng.conf`, port 3000 |
| compose | `/opt/dpistack/compose/compose.yaml` |

Besides the marks of the steps, the `state` file keeps a snapshot of the applied config (`applied.<KEY>=<value>`, written by the installer after every successful apply) and the counters of the watchdog (`watch.miss.<id>`, `watch.restarts.<id>`).

The system user `dpistack` (no login) runs the panel and is in a group that can read `eve.json`. The system user `dpistack-monitor` runs node_exporter and Grafana, `dpistack-metrics` the metrics backend.

### 4.3 Keys of `dpistack.conf`

The format is `KEY=value`, one per line, no quotes and no substitutions. The check is strict: an unknown key or a value outside the options stops the installer. A retired key (`PANEL_MODE`) is dropped when the file is loaded. A value whose implementation is not done yet is refused with the message `not supported yet`. Secrets live only in `secrets.conf`. The table mirrors `lib/schema.sh`.

| key | default | options / format |
| --- | --- | --- |
| `SURICATA_ENABLE` | `yes` | `yes` `no`; `no` skips the steps `suricata`, `ndpi`, `rules` and `verify` (v0.25.0); turning a component off does not remove what is installed, use `uninstall` |
| `RULES_ENABLE` | `yes` | `yes` `no`; the rules and their update timer, needs `SURICATA_ENABLE=yes` |
| `EVEBOX_ENABLE` | `yes` | `yes` `no`; the `evebox` step |
| `NTOPNG_ENABLE` | `yes` | `yes` `no`; the steps `redis` and `ntopng` |
| `PANEL_ENABLE` | `yes` | `yes` `no`; the `panel` step |
| `SURICATA_RUNTIME` | `native` | `native` `docker` |
| `EVEBOX_RUNTIME` | `native` | `native` `docker` |
| `NTOPNG_RUNTIME` | `native` | `native` `docker` |
| `SURICATA_SOURCE` | `source` | `distro` `oisf` `source`; `oisf` is the OISF PPA on Ubuntu and the COPR `@oisf/suricata-8.0` on the RHEL family; there is none on Debian |
| `SURICATA_VERSION` | empty | for `source`: empty = the last tested release of the stable 8.0 series (now `suricata-8.0.8`), not `master`; a value is a tag or a branch |
| `NDPI_ENABLE` | `yes` | `yes` `no`; `yes` needs the `ndpi.so` plugin |
| `NDPI_SOURCE` | `source` | `pkg` `source` |
| `NDPI_VERSION` | empty | empty = the nDPI release the Suricata plugin builds with (now `4.14`, checked by a build; master and 5.0 do not build the plugin) |
| `NTOPNG_VERSION` | empty | empty = the latest |
| `EVEBOX_VERSION` | empty | empty = the latest |
| `PIN_VERSIONS` | `no` | `yes` `no`; `yes` = `apt-mark hold` / `dnf versionlock` |
| `SURICATA_MODE` | `ids` | `ids` `ips` |
| `IFACES` | `enp2s0` | names, comma separated; if the value is still the default and there is no such interface, `install` takes the default-route interface (else the first non-`lo`) and says so; a value you typed is not replaced |
| `BPF_FILTER` | empty | a BPF expression |
| `HOME_NET` | auto | a list of CIDRs; auto = the RFC 1918 private ranges |
| `IPS_METHOD` | `nfq` | `nfq` `afpacket` |
| `IPS_NFQ_CHAINS` | `INPUT,OUTPUT,FORWARD` | a subset of these chains |
| `EVE_FILE` | `yes` | `yes` `no`; `no` turns off the EVE view, the freshness check and the eve metrics |
| `EVE_TYPES` | `alert,flow,dns,tls,http,stats` | from `alert,anomaly,dns,http,tls,files,flow,netflow,ssh,smb,stats,drop` |
| `EVE_SYSLOG` | `no` | `yes` `no` |
| `EVE_REDIS` | empty | `host:port` or empty |
| `EVE_ROTATE` | `daily` | `daily` `weekly` `size` |
| `EVE_KEEP` | `14` | number of rotations |
| `EVE_MAX_SIZE_MB` | empty | a number, needed with `EVE_ROTATE=size` |
| `STATS_INTERVAL_SEC` | `30` | 5..300 |
| `RULES_SOURCES` | `et/open` | `suricata-update` source names, comma separated |
| `RULES_URLS` | empty | your own URLs, comma separated |
| `RULES_GROUPS` | `emerging-p2p,emerging-policy` | the rule groups turned on in `enable.conf` |
| `RULES_UPDATE` | `on` | `on` `off` |
| `RULES_UPDATE_CALENDAR` | `weekly` | the systemd `OnCalendar` syntax |
| `EXCEPTIONS_DEFAULT_DAYS` | `30` | `0..3650`; how many days a new exception lasts when `exceptions add` gets neither `--days` nor `--never`; `0` means it never expires (slice 40) |
| `NTOPNG_IFACES` | as `IFACES` | names, comma separated |
| `NTOPNG_PORT` | `3000` | 1..65535 |
| `EVEBOX_DB` | `sqlite` | `sqlite` `elasticsearch` |
| `EVEBOX_ES_URL` | empty | a URL, needed with `elasticsearch` |
| `EVEBOX_PORT` | `5636` | 1..65535 |
| `EVEBOX_RETENTION_DAYS` | `30` | number of days, `0` = no limit; the mechanism is by assumption A9 |
| `ACCESS_MODE` | `localhost` | `localhost` `lan` `nginx` |
| `BIND_ADDR` | `auto` | `auto` or one IPv4 address of this host (checked by `preflight`). `auto` = `127.0.0.1` in `localhost` mode and `0.0.0.0` in `lan` mode; an address makes ntopng, EveBox, the panel, the metrics backend, Grafana and node_exporter listen there. A non-loopback address with `ACCESS_MODE=localhost` opens the panels to `LAN_CIDR`: the panel runs with `-access lan` and the access confirmation is needed. Ignored with `nginx` (the services stay on `127.0.0.1`) |
| `LAN_CIDR` | auto | the CIDR of the network of the default-route interface, or a comma-separated list of CIDRs (v0.31.0); `auto` inside a list stands for that network, for example `auto,172.18.0.0/16` |
| `PANEL_PORT` | `9800` | 1..65535 |
| `PANEL_RUNTIME` | `native` | `native` (the unit `dpistack-panel.service`) or `docker` (the service `panel` of the same compose project: the image `dpistack-panel:<hash of the binary>` built on the host from `alpine`, `network_mode: host`, `pid: host`, `privileged`; commands to the host go through `nsenter -t 1 -m -u -i -n -p -- env DPISTACK_CALLER=panel dpistack ...`); heavy, affects the `panel` step |
| `PANEL_EDITION` | `full` | `full` (the rich dark console with a particle background) or `lite` (the same features on a plain, light page); light, affects the `panel` step; asked in the quick install. Replaced `PANEL_MODE` (v0.23.0) |
| `PANEL_SOURCE` | `auto` | `auto` (a ready binary next to the installer, else a build), `build` (needs Go) or `prebuilt` (a ready binary only) |
| `NGINX_MANAGE` | `snippet` | `yes` (edits and reloads the system nginx) or `snippet` (only writes a file and prints the command) |
| `NGINX_TLS` | `none` | `none` `selfsigned` `existing` |
| `NGINX_CERT` `NGINX_KEY` | empty | paths, needed with `existing` |
| `FIREWALL_MANAGE` | `no` | `no` `auto` (ufw or firewalld, only allow `LAN_CIDR`) |
| `METRICS_EXPORT` | `yes` | `yes` `no`; turns on `GET /metrics` of the panel |
| `METRICS_BACKEND` | `none` | `none` `victoriametrics` `prometheus`; `none` = the endpoint only, the user sets up the collection |
| `METRICS_BACKEND_RUNTIME` | `native` | `native` `docker` |
| `METRICS_BACKEND_PORT` | empty | empty = 8428 (VictoriaMetrics) or 9090 (Prometheus) |
| `METRICS_RETENTION` | `30d` | a number and the suffix `h`, `d`, `w` or `y`; with a metrics backend other values are refused (the backends read a bare number and `m` differently: VictoriaMetrics as months, Prometheus `m` as minutes) |
| `NODE_EXPORTER_ENABLE` | `no` | `yes` `no`; installs node_exporter (host metrics) and adds a `node` job to `scrape.yaml`; heavy, steps `nodeexp` and `metrics` |
| `NODE_EXPORTER_RUNTIME` | `native` | `native` (a GitHub release with a pinned sha256, the unit `dpistack-node-exporter.service`) `docker` (`prom/node-exporter`, `pid: host`) |
| `NODE_EXPORTER_PORT` | `9100` | 1..65535 |
| `GRAFANA_ENABLE` | `no` | `yes` `no`; installs Grafana; with a metrics backend it is provisioned as the default data source; heavy, step `grafana` |
| `GRAFANA_RUNTIME` | `native` | `native` (the vendor tarball from `dl.grafana.com`, its sha256 is read from the vendor `.sha256` file next to it; the unit `dpistack-grafana.service`) `docker` (`grafana/grafana-oss`) |
| `GRAFANA_PORT` | `3030` | 1..65535; the first login is `admin`/`admin` and Grafana asks for a new password |
| `WATCH_ENABLE` | `yes` | `yes` `no` |
| `WATCH_INTERVAL_SEC` | `60` | 10..3600 |
| `WATCH_EVE_STALE_SEC` | `300` | seconds without new events before `crit` |
| `WATCH_DROP_WARN_PCT` `WATCH_DROP_CRIT_PCT` | `1` `5` | percent |
| `WATCH_DISK_WARN_PCT` `WATCH_DISK_CRIT_PCT` | `15` `5` | free space, percent |
| `WATCH_RULES_WARN_DAYS` `WATCH_RULES_CRIT_DAYS` | `10` `30` | the age of the rules |
| `WATCH_REPEAT_MIN` | `60` | repeat an alert until the status is `ok` |
| `WATCH_AUTORESTART` | `no` | `yes` `no`; `yes` = at most 3 restarts an hour per component |
| `ALERT_CHANNELS` | `panel,log` | a subset of `panel,log,tg,mail` |
| `ALERT_TG_CHAT_ID` | empty | needed with `tg` |
| `ALERT_MAIL_TO` `ALERT_MAIL_FROM` | empty | addresses, needed with `mail` |
| `TEST_HTTPS_URL` | `https://example.com` | the URL of the live HTTPS test |
| `TEST_BT_LIVE` | `no` | `yes` sends the pcap to a live interface with `tcpreplay` and adds one test rule (sid 9000100, `dpistack-test.rules`) to the live Suricata |
| `TEST_ON_INSTALL` | `yes` | `yes` `no` |
| secret `ALERT_TG_TOKEN` | empty | the bot token |
| secret `ALERT_SMTP_URL` | empty | `smtp://user:pass@host:587` |
| secret `METRICS_TOKEN` | generated | 32 random bytes in hex, created with `METRICS_EXPORT=yes` |

Load-time checks (cross checks):

- `NDPI_ENABLE=yes` with `SURICATA_SOURCE` of `distro`/`oisf` is allowed only if the file `ndpi.so` is found after the install; otherwise the installer offers `SURICATA_SOURCE=source` (interactive) or stops with code 2 (non-interactive).
- `EVE_TYPES` without `stats` with `WATCH_ENABLE=yes` gives a warning: the checks `eve_fresh` and `drop_rate` get the status `na`.
- `METRICS_BACKEND` other than `none` with `METRICS_EXPORT=no` is refused: the backend has nothing to scrape.
- `EVEBOX_DB=elasticsearch` without `EVEBOX_ES_URL` is refused; `EVE_FILE=no` with `EVEBOX_DB=sqlite` is refused.
- `ACCESS_MODE` other than `localhost`, and a non-loopback `BIND_ADDR` (not with `nginx`), need the confirmation of the warning of section 1 (non-interactive: `--set ACCESS_CONFIRM=yes`, the key is not saved). `BIND_ADDR` must be an IPv4 address that is not `0.0.0.0` and, outside `nginx`, an address of this host (`preflight`, code 3).
- `SURICATA_MODE=ips` works only with `SURICATA_RUNTIME=native`; `IPS_METHOD=afpacket` needs an even number of interfaces (at least two).

The free keys (the `free` type) are checked against the patterns of `SCHEMA_PATTERN` in `lib/schema.sh`. Their values end up in YAML, nginx and systemd, in the arguments of `curl` and `suricata-update`, and root executes or reads all of it, while `dpistack config-write` lets the panel change them. A value outside the format is refused before it is written anywhere: no quotes, no backslash, no `$`, no backticks, no `;`, no braces and no leading `-` that a command would read as an option. The format of the keys: `IFACES` and `NTOPNG_IFACES` are interface names, comma separated; `LAN_CIDR` is `auto` or `address/length`; `BIND_ADDR` is `auto` or an IPv4 address; `HOME_NET` is `auto` or a list of CIDRs; `TEST_HTTPS_URL` and `EVEBOX_ES_URL` are `http://` or `https://` URLs; `ALERT_SMTP_URL` is a `smtp://` or `smtps://` URL; `NGINX_CERT` and `NGINX_KEY` are an absolute path; `*_VERSION` is letters, digits and `. ~ + : _ -`; the others are described in the code next to the pattern. A refused value of a secret key is not printed in the error message.

`NTOPNG_VERSION` and `EVEBOX_VERSION` pin the version of the package at install (`package=version` for apt, `package-version` for dnf). A change of the version of an already installed package does not reinstall it.

### 4.4 The CLI of the installer and of the persistent command `dpistack`

`install.sh` (run from a clone or an archive, before the install) and `dpistack` (the persistent command, available after the install, section 5.2) take the same syntax:

```
install.sh [command] [options]
dpistack [command] [options]

commands: install | reconfigure | upgrade | uninstall | status | diag | test | logs
options:  --config FILE          the path to dpistack.conf (default /etc/dpistack/dpistack.conf)
          --set KEY=VALUE        override a key, may be repeated
          --non-interactive, -y  no questions; missing values take their defaults
          --fast                 install: the short questionnaire (5.1) instead of the guided setup
          --advanced             ask every key, not only the basic level
          --dry-run              show the plan, change nothing
          --only STEP[,STEP]     run only the given steps
          --skip STEP[,STEP]     skip steps
          --force                overwrite hand-edited files (with a backup)
          --purge                for uninstall: also remove the data and the configs
          --no-color             no ANSI colors in the menu and the output
```

Without `--non-interactive`, and on a terminal (or with the variable `DPISTACK_INPUT`), the command `install`, `reconfigure` or `dpistack` itself with no arguments opens the text menu instead of a row of questions, section 5.0. `--set` and `--config` then act as pre-filled values that the menu shows and lets you change. The difference between `install.sh` and `dpistack` is only the default state: `install.sh` with no arguments and no installed config always offers the install; `dpistack` with no arguments and an already installed config opens the control menu, not the install menu (section 5.2).

`test`, `logs <id>` and the other verbs of section 4.5 (`start`, `stop`, `restart`, `reload`, `config-*`, `rules-*`, `iface`, `mode*`, `fw`, `settings`, `panel-passwd`, `health`, `version`, `self-update`) are verbs of the same command. There is no separate program `dpistack-ctl` (v0.21.0 made it a link, v0.24.0 removed it; an old link is deleted by the `selfinstall` step). `reconfigure --light` is the non-interactive form (light changes only, otherwise code `3`).

**Root only.** Every `dpistack` and `install.sh` command without root ends with code `1` and a message; the panel comes through `sudo -n`, which gives root. If `SUDO_USER` matches the user of the panel, only the verbs of section 4.5 are accepted, and the installer commands (`install`, `upgrade`, `uninstall`, the interactive `reconfigure`) get code `2`. Tests set `DPISTACK_VERBS_ONLY=1` to treat every argument as a verb (the helper `tests/helpers/verbs`).

`status` first prints the components (like `status --json` in 4.5, but as text), then the result of `check` for every step: `ok` or `mismatch` with the reason. It changes nothing. `status --json` returns the components only.

Exit codes: `0` success, `1` a step failed, `2` bad arguments or config, `3` preflight failed or the change is not supported in this mode.

`diag` (v11, read only): one text report for troubleshooting on a stand: the platform and the support level, the versions of the components, `suricata --build-info`, packages, repositories, `dpistack.conf`, the state, services and `systemctl --failed`, the network, SELinux and the firewall, `suricata -T`, the tail of the installer log and `journalctl`. It goes to stdout and to the file `DIAG_OUT` (by default a new `mktemp` file, the path is printed; the project uses no fixed paths in `/tmp`); tokens, passwords and a login with a password in a URL are replaced with `<hidden>`. This is the file the owner sends after checking a platform.

### 4.5 The verbs of `dpistack` (the former `dpistack-ctl`)

The only place of the privileged actions of the panel and the watchdog. It works as root through `sudo -n dpistack <verb>`; the rule in `/etc/sudoers.d/dpistack` names `/usr/local/sbin/dpistack`, and `dpistack` itself lets the panel user reach only the verbs of this table (section 4.4). All arguments are checked against the lists below before any action. Shell metacharacters in arguments are refused.

| command | what it does |
| --- | --- |
| `status [--json]` | for every component: `id`, `runtime`, `state` (`active` `inactive` `failed` `absent`), `enabled`, `version`; plus `ndpi_plugin` (`loaded` `absent`) |
| `start\|stop\|restart <id>` | controls a component through its runtime; `<id>` only from 4.1 |
| `reload suricata` | reloads the rules without stopping (`ruleset-reload-nonblocking`) |
| `logs <id> [-n N] [--follow]` | the log of a component, `N` up to 1000 |
| `config-read <name>` | prints the current file |
| `config-write <name> [--apply\|--check]` | reads stdin, puts it into `staging/`, checks, makes a backup, replaces atomically; `--apply` then reloads the component, and for `dpistack.conf` runs `reconfigure` |
| `config-revert <name>` | restores the latest backup |
| `reconfigure [--light] [--dry-run]` | applies the current `dpistack.conf` with no questions: finds the affected steps (section 5.3), renders the configs again and restarts the components. It installs no packages and builds nothing: on a change of "heavy" keys it refuses with code 3 and asks for `install.sh reconfigure` |
| `settings list\|check\|set\|secret\|job` | every setting with its value (and, from v0.45.0, per key `steps`, `touches`, the labels of what a change touches, and `depends`, the conditions under which the key applies: `[{key,op,values}]`, `op` is `=`, `!=` or `~`, all must hold), the checks, the weight of a change and the busy ports; `set --apply` applies a light change at once, `--apply-heavy` starts a heavy one as a separate job (`dpistack-apply`), `--confirm-access` confirms a wider access, `secret KEY` takes the value from stdin; `job` reports the progress |
| `settings profile list [--json]`, `show <name> [--json]`, `save <name> [--by NAME] [KEY=VALUE...]`, `delete <name> [--by NAME]`, `apply <name> [--apply\|--apply-heavy] [--confirm-access]` | named sets of keys in `profiles.json`: `list` gives `{profiles:[{name,created,by,count}]}`, `show` gives `{name,created,by,keys:{K:V}}`; `save` takes the pairs from the arguments or from stdin, refuses an unknown key, a secret, a key given twice, more than 100 keys, a 51st profile, and values that `settings check` refuses (3, or 5 for an unknown key), and saving a name again replaces it; the name is 1 to 32 characters of `a-z 0-9 - _`, starting with a letter or digit (otherwise 5); `apply` is `settings set` with the pairs of the profile and the same flags, so it has the same checks, the same weight and the same confirmation of a wider access; `save`, `delete` and `apply` are audited, `list` and `show` are not; changes the file under a lock (18.44) |
| `rules-update` | `suricata-update`, the `suricata -T` check, a reload; on an error the set is rolled back. What the tools said (the last 40 lines) goes to stdout on success and on failure alike: the panel needs the reason |
| `rules-sources list [--enabled]\|enable\|disable\|add-url\|remove <arg>` | rule sources; `list --enabled` shows the enabled ones |
| `rules-group enable\|disable <group>` | edits `enable.conf` |
| `rules-sid enable\|disable <sid>` | edits `disable.conf`, `sid` is a number only |
| `exceptions list [--json]` | the entries of `threshold.config` with their data (18.40); `--json`: `{default_days,today,entries:[{id,kind,sid,track,ip,count,seconds,added,expires,days_left,expired,by,note}]}` |
| `exceptions add suppress\|limit <sid> [--track src\|dst] [--ip ADDR] [--count N --seconds S] [--days N\|--never] [--note TEXT] [--by NAME]` | adds one entry, checks the file with `suricata -T`, reloads Suricata; prints the id. `suppress` with `--ip` and `--track` is silent for one address, without them for every address (a warning says so); `limit` allows at most N alerts per S seconds for each address of the side `--track`; no `--days` and no `--never` means `EXCEPTIONS_DEFAULT_DAYS` |
| `exceptions remove <id>` | removes the entry with that id (`kind:sid:track:ip`, `any` for none) |
| `exceptions prune` | removes the entries past their last day (the watchdog runs it) |
| `rules-search <q>` | up to 50 rules by `sid` or the text of `msg` |
| `rules-stats [--json]` | `{ruleset:{present,updated,total,enabled,disabled}, local:{total,enabled,disabled}, sources:[{name,cached,total,enabled,disabled,missing,fetched}]}`; a source is counted from its newest cache file and each rule has its state in the merged set (18.41) |
| `rules-history [--json]` | `{updates:[{time,result,loaded,total,enabled,added,removed,modified,parsed}]}`, the last 50 updates, newest first; `rules-update` writes one line per update (the last 100 are kept) |
| `rules-describe <sid>...` | 1 to 20 sids: `{rules:[{sid,msg,enabled,where}], asked}`, from the merged set and `local.rules` |
| `rules-find [--class C] [--source S] [--state enabled\|disabled\|any] [--text T]` | `{results:[{sid,msg,class,enabled}], truncated, source_known}`, up to 50 rules, disabled ones too; at least one filter; a number as the text is an exact sid |
| `rules-facets` | `{classes:[{name,count}], sources:[name]}`: what the filters of `rules-find` offer (the 200 largest categories) |
| `rules-local check` | the candidate `local.rules` on stdin (1 MiB at most); `{ok,rules,problems:[{line,kind,text}],warnings:[{line,text}],suricata:{run,ok,output}}`; kinds `not_a_rule`, `no_sid`, `duplicate`, `conflict`; a sid outside 9000000 to 9999999 is a warning; writes nothing |
| `config-history <name> [<version>]` | `{name,versions:[{id,time,size,lines}]}` newest first (the backups of every change), or the content of one version; ids look like `20261108T101010Z` |
| `iface list\|add\|remove <name>` | edits `IFACES`, calls `reconfigure` |
| `mode ids\|ips [--confirm-timeout SEC]` | switches the mode; for `ips` it rolls back by itself if `mode-confirm` does not come within `SEC` (10-3600, 120 by default); `mode status [--json]` shows the mode, the method and the seconds left |
| `mode-confirm` | confirms the switch to IPS; with no pending switch, or after the time is over, code 3 |
| `ips status [--json]` | `{mode,method,chains,backend,pending,remaining_sec,drop_rules:{enabled,disabled,local_enabled,local_disabled},counters:{time,accepted,blocked,rejected,replaced}\|null,blocked:[{time,src,dest,proto,sid,msg}],checks:[{id,state,text}],ready}`; read only; `checks` are `mode`, `suricata`, `firewall`, `queue`, `confirm` with the state `ok`, `warn`, `fail` or `na`; `ready` is true in IPS mode when no check fails (18.42) |
| `ips test [--sid N,...] [--pcap NAME] [--json]` | replays a shipped pcap (`tests/data/NAME.pcap`, now `bittorrent`) through Suricata offline with `--simulate-ips` and the active drop rules (or up to 20 sids); `{ran,pcap,simulate_ips,loaded,matched:[{sid,msg,would_drop}],would_drop,requested:[{sid,state}],reason}`; a sid state is `would_drop`, `alert_only`, `no_match`, `disabled`, `not_found` or `needs_ndpi`; a Suricata in a container or none gives `ran:false` and a `reason`, exit 0; a bad argument gives 5; never touches the capture or the main `eve.json` |
| `alerts list [--state S] [--source S] [--severity S] [--json]` | `{ts, alerts:[{key,source,severity,title,detail,first_seen,last_seen,count,state,by,note,decided_at,until,cleared}], counts:{new,acknowledged,snoozed,resolved,new_crit}}`; `key` is `watch:<check id>` or `sid:<number>`, `source` is `watchdog` or `suricata`, `severity` is `crit`, `warn` or `info`, `state` is `new`, `acknowledged`, `snoozed` or `resolved`; `counts` are of all alerts, not of the filter; a bad filter value gives 5; read only (18.43) |
| `alerts history [--limit N] [--json]` | `{history:[{ts,kind,key,action,by,note,detail}]}`, newest first, `kind` is `action` (a decision of a person) or `event` (a status change of the watchdog, from `events.jsonl`); `--limit` 1 to 500, 100 by default, otherwise 5; read only |
| `alerts ack\|resolve\|reopen <key> [--note T] [--by NAME]`, `alerts snooze <key> --for 1h\|4h\|24h\|7d [--note T] [--by NAME]` | sets the state of an alert and writes one line to the history of `alerts-state.json`; `reopen` drops the decision; the key must be an alert now or one with a decision, otherwise 5; a bad key, note (80 characters of letters, digits and `. _ : / @ + , = -`), name or `--for` gives 5; changes the file under a lock, so two at once both land; audited (`cli alerts`) |
| `tokens create --user U --name N [--scope S] [--days D] [--json]` | makes an API token for an account and prints `{id, token, expires}` once (without `--json`, the id, the token, the expiry and a reminder): the token is `dpt_` and 43 characters of randomness, only its SHA-256 goes into `api-tokens.json`, and it is nowhere else (not in the log, not in the audit); the scope is `read`, `viewer`, `analyst`, `operator` or `admin` (not `custom`) and may not hold more than the account may do (5); the name is 1 to 32 of `a-z 0-9 space . _ -`; `--days` is 1 to 365 (90 by default, otherwise 5), `08` is eight; the account must exist and not be disabled; at most 10 tokens an account and 100 in all (5); audited as `cli tokens` |
| `tokens list [--user U] [--json]` | `{tokens:[{id,name,user,scope,created,expires,expired}]}`, newest first, never the hash; read only |
| `tokens revoke <id> [--user U]` | removes a token; with `--user` it must be that account's, otherwise (and for an id that is not 8 hex digits or is unknown) 5; audited |
| `security check [--json]` | `{ts, checks:[{id,level,title,detail,fix}], counts:{ok,warn,crit,na}}`, six items in this order: `access-mode`, `tls`, `default-ports`, `stale-users`, `rules-files`, `secret-files`; `level` is `ok`, `warn`, `crit` or `na`, and every item that is not ok or na has a `fix`; reads settings, the modes of files and the audit log, changes nothing, not audited (18.45) |
| `mode-rollback`, `fw apply\|remove\|restore` | internal: the rollback by the timer and the `DPISTACK` chain (`dpistack-fw.service` calls `restore` at boot) |
| `test bittorrent\|https\|all [--json]` | section 10 |
| `health [--json]` | one run of the watchdog |
| audit of verbs | every verb of this table that changes something (not `list`, `status`, `check`) appends a line to the audit log when it is run by hand (slice 35) |
| `diagnose [<part>]` | the parts that should run and do not: state, systemd exit status and the last 25 log lines; the installer runs the same after a step that is "partly applied" and at the end (v0.29.1) |
| `runtime [--json]` | what can run in Docker, the runtime of every part, the links between them (4.10) |
| `panel-passwd` | reads the password from stdin, writes an argon2id hash into `panel.auth` and into the user `admin` of `users.json` |
| `users list [--json]`, `users add <name> <role> [--perms a,b]`, `users passwd <name>`, `users role <name> <role> [--perms a,b]`, `users disable\|enable\|remove <name>` | users of the panel in `/etc/dpistack/users.json` (slice 34); passwords on stdin, 8 characters at least; exit 3 when the change would leave nobody able to manage users, 4 for an unknown user; open to the panel |
| `backup create [--out FILE]`, `backup list [--json]`, `backup verify FILE`, `backup restore FILE [--dry-run]` | archives of the configs in `/var/lib/dpistack/archives/` (slice 36, 18.36); `create` and `restore` are audited; the panel may name an archive by its file name only (`--out` and paths give 5 for it); exit 3 for an archive or a configuration that failed its checks, 4 for a missing archive |
| `version` | the version of the bundle |

Arguments: letters, digits and `. _ : = / @ + , -` and a space are allowed (`rules-search` takes a phrase); everything else, including `; | & $ ( ) < > \` quotes and a line break, gives code `5` before any action. A URL with `?`, `&`, `%` therefore does not pass `rules-sources add-url`.

`logs <id> -n N --until-stdin-closed` (v16): the same as `--follow`, but the stream ends when the stdin of `ctl` is closed. The panel needs it: it does not run as root and cannot send a signal to the `sudo` process, so it has no right to kill `ctl` when the connection breaks. The panel keeps stdin open while the client listens and closes it when the client has gone; `ctl` then stops `journalctl` even if there are no new lines. The other ways to call `--follow` do not change.

`logs -n N`: `N` from 1 to 1000, leading zeros are a decimal notation (`08` is 8, `01750` is refused as 1750). `config-write dpistack.conf` refuses the secret keys (`ALERT_TG_TOKEN`, `ALERT_SMTP_URL`, `METRICS_TOKEN`): secrets live only in `secrets.conf`. Writing and rolling back configs take the installer lock (they wait up to 30 seconds) so that the file does not change while `install.sh` renders from it.

`config-write --apply`: `dpistack.conf` runs `reconfigure`; `suricata.yaml` restarts `suricata`; `evebox.yaml` and `ntopng.conf` restart their component; `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf` run `rules-update`. A file written through `ctl` counts as hand-edited for the installer (5.4): `config-write` does not update the hash of the last render.

`reconfigure` compares `dpistack.conf` with the snapshot `applied.<KEY>` in `state`, not with the file itself, because `config-write` has already replaced the file. `ACCESS_CONFIRM=yes` is substituted only while `ACCESS_MODE` and `BIND_ADDR` equal the applied ones; a change of the access goes through `install.sh reconfigure` (or `settings set --confirm-access`). A heavy change gives code `3` and a message with the words `install.sh reconfigure`.

`iface add|remove` writes `IFACES` into `dpistack.conf` (with a backup) and calls `reconfigure`; on a failure the file is restored from the backup. The name for `add` must exist in the system, otherwise `5`; the last interface cannot be removed (`3`).

`rules-sources list` prints `suricata-update list-sources` (every source of the index, without the "enabled" mark), `list --enabled` prints `suricata-update list-enabled-sources`; `add-url` names a source `dpistack-custom-<8 characters of the sha256 of the URL>`. `rules-group enable|disable` adds and removes the line `group:<name>.rules` in `enable.conf`, `rules-sid` the line `<sid>` in `disable.conf`; they do not change `RULES_GROUPS` in `dpistack.conf`.

`panel-passwd` calls the `argon2` CLI (the package `argon2`, installed by the installer): `-id -t 3 -m 14 -p 4 -l 32 -e` (16 MiB: the check runs inside the panel; 64 MiB did not fit into the `MemoryMax=64M` that the panel unit had before v0.23.0, and the panel keeps refusing a hash heavier than 32 MiB and asks to set the password again), a salt of 16 random bytes. The password goes to stdin, not to the arguments. The line `$argon2id$...` is written into `panel.auth`, permissions `0640`, group `dpistack`; while the user does not exist yet (the first install) the group is set by the `panel` step. The same code writes the password at an install from the menu.

The allowed `<name>` for configs: `suricata.yaml`, `evebox.yaml`, `ntopng.conf`, `dpistack.conf`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf`, `threshold.config`.

Checks at `config-write`: `suricata.yaml`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf`, `threshold.config` pass `suricata -T` on a temporary copy of the set; `dpistack.conf` passes the schema check of 4.3; `evebox.yaml` and `ntopng.conf` are checked for non-emptiness only: EveBox and ntopng have no config check mode (assumption A8 closed). For `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf` `suricata -T` checks that the set stays workable, but these files themselves are read only by `suricata-update`. A failed check: nothing changes, code `3`, the output of the check goes to stdout.

Exit codes: `0` success, `1` error, `2` misuse, `3` the check failed or the action is unavailable in this mode, `4` the component is missing, `5` a name outside the list.

### 4.6 `health.json` and events

`/var/lib/dpistack/health.json`, rewritten atomically by every run of the watchdog:

```json
{
  "ts": "2026-09-24T12:00:00Z",
  "overall": "ok",
  "checks": [
    { "id": "suricata.process", "status": "ok", "value": "active", "detail": "", "since": "2026-09-24T09:00:00Z" }
  ]
}
```

`status` is only `ok`, `warn`, `crit`, `na`. `overall` takes the worst status, `na` does not count. `since` changes only when the status changes.

The ids of the checks: `<id>.process` and `<id>.port` for `suricata` (there is no port, only the process), `evebox`, `ntopng`, `redis`, `panel`, and, when installed, `victoriametrics` or `prometheus`, `node_exporter` and `grafana`; `suricata.eve_fresh`, `suricata.drop_rate`, `disk.free`, `rules.age`.

`/var/lib/dpistack/events.jsonl`: a line per status change of a check, the `panel` channel:

```json
{"ts":"...","check":"suricata.drop_rate","from":"ok","to":"warn","detail":"drops 2.4%"}
```

`/var/lib/dpistack/tests-last.json`, the last result of each test of section 10. Running one test does not erase the result of another:

```json
{"results":[
{"name":"bittorrent","status":"pass","detail":"signature: ET P2P BitTorrent DHT ping request","duration_ms":812,"timestamp":"2026-10-08T12:00:00Z"}
]}
```

One object per line, so the file can be merged without `jq`. `status` is `pass`, `fail`, `skip`. Permissions `0644`.

The threshold rule for `health.json` and `ctl health`: a value exactly at a threshold gives the worse of the two statuses (`drop_rate` 1 % with `WARN=1` is `warn`, free space exactly `WARN` is `warn`, an age of `WATCH_EVE_STALE_SEC` is `crit`). The comparison is exact arithmetic with no rounding. An event in `events.jsonl` is written on a status change; the first appearance of a check with the status `ok` or `na` does not count as an event.

### 4.7 EVE: the fields the panel and the tests rely on

| field | where | what for |
| --- | --- | --- |
| `timestamp`, `event_type`, `in_iface`, `src_ip`, `dest_ip`, `proto` | all events | the event feed, filters |
| `alert.signature`, `alert.signature_id`, `alert.severity`, `alert.category` | `alert` | the feed, the BitTorrent test |
| `tls.sni` | `tls` | the HTTPS test |
| `alert.metadata` | `alert` | an nDPI detection, if the rule with `ndpi-protocol` or `ndpi-risk` sets `metadata` |
| `stats.capture.kernel_packets`, `stats.capture.kernel_drops` | `stats` | the drop rate, the packets chart, the metrics |
| `stats.uptime` | `stats` | the metrics |

There are no separate `ndpi.*` fields in EVE: the merged nDPI plugin gives only the rule keywords `ndpi-protocol` and `ndpi-risk`, and the result is visible through `alert.signature` and `alert.metadata` (assumption A2 closed).

The drop rate of an interval: `delta(kernel_drops) / delta(kernel_packets) * 100`. The counters accumulate; a reset (a value lower than before) skips the interval.

### 4.8 The HTTP API of the panel

All answers are JSON, an error is `{"error":"text"}` with the code 4xx/5xx. All methods except `POST /api/login` and `GET /metrics` need a session. The methods that change something need the header `X-CSRF-Token`. **Both panel editions serve exactly the same API.** From v0.46.0 a method that needs a session also takes an **API token** in its place: `Authorization: Bearer dpt_...` (the word `Bearer` in any case), made by `dpistack tokens create` (18.45). A request with that header is never read as a session, even when a cookie came with it; it needs no `X-CSRF-Token`; it acts as the owner of the token with the permissions of the token's scope, never more than the owner holds now (a disabled or removed owner stops it at once); a `read` token is refused every method but GET, HEAD and OPTIONS with `403 this token is read only`; an expired or unknown token is 401, and an address that sends 30 wrong tokens in 5 minutes gets 429 for every token, a right one included (a right token is never counted). Tokens and sessions are managed only with a session: `/api/security/sessions*` and `/api/security/tokens*` answer a token with 403. The audit line of a token request names `token:<name>`.

| method and path | what it does |
| --- | --- |
| `POST /api/login`, `POST /api/logout` | the session is in a `HttpOnly; SameSite=Strict` cookie; the login body is `{username?, password}`, no name means `admin`; a wrong name, a disabled user and a wrong password give the same answer |
| `GET /api/backups`, `POST /api/backups`, `GET /api/backups/{name}`, `POST /api/backups/{name}/verify`, `POST /api/backups/{name}/restore` | permission `backup.manage`; list, create, download (the panel reads the archive from `-backups-dir` and follows no link), verify, and restore with `{dry_run:true}` (the difference) or `{acknowledged:true}`; a bare restore is 400; a failed check is 409 with the checker's words in `output` |
| `GET /api/audit`, `GET /api/audit/export` | permission `audit.view`; filters `user`, `action` (substring of action and target), `result` (`ok`, `denied`, `error`), `since`, `until` (a date or RFC 3339), `limit` (up to 5000); the export is `csv` or `json` as a download (CSV cells that start like a formula are quoted) |
| `GET /api/me`, `POST /api/me/password` | who is signed in with the permissions; a user changes their own password with the current one (their sessions end) |
| `GET\|POST /api/users`, `PUT\|DELETE /api/users/{name}` | permission `users.manage`; the list never holds a hash; nobody can remove or disable their own account |
| permissions | every other route needs one (table in `panel/internal/api/users_test.go`, checked for every role); reading `/api/config*` needs `configs.edit`; a missing permission is 403 `{"error":"forbidden","permission":...}` |
| `GET /api/system` | permission `view`; the host state read from `/proc`, `/sys` and statfs: `uptime_seconds`, `load` (3 numbers), `cpu` (`cores`, `percent` since the previous call, `null` on the first), `memory` (kB), `disks` (`/`, `/var/lib/dpistack`, `/var/log`; a missing path is left out and paths on one filesystem count once), `interfaces` (`state`, `mac`, `mtu`, `speed_mbps` or `null`, byte, packet, error and drop counters, `virtual` when there is no `device` link, `capture` from `ctl iface list`, left out when that fails), `systemd_present`, `docker_socket`, `hostname` (from `/proc/sys/kernel/hostname`, empty when it cannot be read) |
| `GET /api/status` | the components (`ctl status`) + `health.json` |
| `GET /api/version` | the running version and, from the latest GitHub release of the project (checked at most every 6 hours, a failed check again after 15 minutes), `latest`, `update_available`, `release_url`, `check_error`. The version comes from the panel flag `-version`, which `panel_args` fills, so an update that changes the unit restarts the panel with the new number |
| `POST /api/update` | the Update button after the confirmation dialog: refused with 409 unless a newer release exists, otherwise `ctl self-update run` (202) |
| `GET /api/update/job` | the state and the last lines of the update unit (`ctl self-update job`) |
| `POST /api/components/{id}/{start\|stop\|restart}` | through `ctl`; stopping or restarting `panel` needs `?confirm=yes` |
| `POST /api/suricata/reload` | `ctl reload suricata` |
| `GET /api/config` | the list of the names of files that can be edited |
| `GET /api/config/{name}` | `{name, content}` |
| `PUT /api/config/{name}?apply=0\|1` | `ctl config-write`; the answer is `{ok, output}` |
| `POST /api/config/{name}/check` | the same check as at save, but with no write: `ctl config-write --check` |
| `POST /api/config/{name}/revert` | `ctl config-revert` |
| `GET /api/rules/sources` | `{sources:[{name,vendor,summary,license,enabled,custom}], last_update, updating}`: `ctl rules-sources list` and `list --enabled` together |
| `POST /api/rules/sources` | the body `{action:"enable\|disable\|remove", name}` or `{action:"add-url", url}`; the answer is `{ok, output}` |
| `POST /api/rules/update` | `ctl rules-update`; the answer is `{ok, output, last_update}`, on a failure 500 with `{error, output}` |
| `GET /api/rules/stats` | `ctl rules-stats --json`, passed on as it is; permission `view` |
| `GET /api/rules/history` | `ctl rules-history --json`; permission `view` |
| `GET /api/rules/describe?sids=1,2,3` | `ctl rules-describe`; up to 20 numbers, each checked before ctl; permission `view` |
| `GET /api/rules/find?class=&source=&state=&q=` | `ctl rules-find`; at least one filter, each checked before ctl (400); permission `view` |
| `GET /api/rules/facets` | `ctl rules-facets`; permission `view` |
| `POST /api/rules/local/check` | the body is the candidate `local.rules` as text (1 MiB, 413 above); `ctl rules-local check`; permission `rules.edit`; writes nothing |
| `GET /api/config/{name}/history` and `/history/{id}` | `ctl config-history`; permission `configs.edit`; an id that is not `YYYYMMDDTHHMMSSZ` is 400, a version that is not there is 409 |
| `GET /api/rules/search?q=` | `{results:[{sid,msg}], truncated}`, up to 50 rules: `ctl rules-search` |
| `POST /api/rules/groups/{group}/{enable\|disable}` | `ctl rules-group` |
| `POST /api/rules/sid/{sid}/{enable\|disable}` | `ctl rules-sid` |
| `GET /api/exceptions` | `ctl exceptions list --json`; permission `view`; the answer is `{default_days,today,entries:[...]}` of 4.5 |
| `POST /api/exceptions` | `ctl exceptions add`; permission `rules.edit`; JSON body `{kind,sid,track,ip,count,seconds,days,never,note}`; `--by` is the signed in user, never a body field; 400 for a value ctl refuses (exit 2 or 5), 422 with the `suricata -T` output when the file does not pass (exit 3), 409 when a tool is missing (exit 4), 500 with the reason for exit 1 such as a duplicate |
| `POST /api/exceptions/remove` | `ctl exceptions remove <id>`; permission `rules.edit`; body `{id}` (the id holds `:` and `/`, so it travels in the body) |
| `GET /api/logs/{id}?lines=N` | the last lines |
| `GET /api/logs/{id}/stream` | SSE, a live tail (at most 4 streams at once) |
| `GET /api/eve?type=&q=&since=&limit=` | `{available, reason?, file_present, types, events:[{id,type,time,event}]}`, newest first; `limit` 1-500 (50 by default), `since` in RFC 3339; with `EVE_FILE=no` `available` is false with a reason |
| `GET /api/eve/stream?type=` | SSE: only the events that came after the connection and only of the chosen type; `data` is one object like in `events` above |
| `GET /api/metrics?range=1h\|6h\|24h` | `{range, start, step, series:{pps,drops,cpu,rss,eve_size,disk:{unit, available, reason?, values:[number\|null]}}}`; every series is on one grid, `values[k]` covers `[start+k*step, start+(k+1)*step)`; the default range is `1h`, another one is a 400 |
| `POST /api/tests/{bittorrent\|https\|all}` | a run, the answer is an array `[{name,status,detail,duration_ms}]` like `ctl test --json`; a failed test is a result (200), not an error; a second run while one runs is 409 |
| `GET /api/tests/last` | `{results:[{name,status,detail,duration_ms,timestamp}], running}`: the last result of each test from `tests-last.json`; no file or a damaged one is an empty list |
| `GET /api/alerts?limit=&check=` | `{alerts:[{ts,check,from,to,detail}], checks, file_present}`: the lines of `events.jsonl`, newest first; `limit` 1-500 (100 by default), `check` filters by check, `checks` is the list of checks for the menu |
| `GET /api/iface` | `{ifaces:[name]}`: `ctl iface list` |
| `POST /api/iface/{add\|remove}` | the body `{name}`, `ctl iface`; the answer is `{ok, output, ifaces}` |
| `GET /api/mode`, `POST /api/mode` (the body `{mode, acknowledged, confirm_timeout}`), `POST /api/mode/confirm` | the IDS/IPS mode |
| `GET /api/ips` (view), `POST /api/ips/test` (the body `{sids:[...], pcap}`, both optional; the permission `tests.run`; one test at a time, 409 otherwise) | the IPS page: the JSON of `ips status` and of `ips test`, unchanged (18.42) |
| `GET /api/alert-center` (view; filters `state`, `source`, `severity`), `GET /api/alert-center/history` (view; `limit` 1 to 500), `POST /api/alert-center` (the permission `events.ack`; the body `{action, key, for?, note?}`, `action` is `ack`, `snooze`, `resolve` or `reopen`, `for` only with `snooze`) | the Alert Center: the JSON of `alerts list`, of `alerts history` and the answer `{ok:true}` of a decision, which runs the verb with `--by` the panel user; a query that does not parse or a bad value is 400 before the verb; `GET /api/alerts` (the feed of status changes) is unchanged (18.43) |
| `GET /api/security/sessions[?all=1]`, `DELETE /api/security/sessions/{handle}`, `POST /api/security/sessions/revoke-others` (all `view`, a session only), `POST /api/security/sessions/revoke-all` (`users.manage`, a session only) | the sessions of the signed in user, `{sessions:[{handle,user,created,expires,ip,user_agent,current}]}` (`all=1` lists everyone's and needs `users.manage`); a handle is 16 hex digits, the first 8 bytes of the SHA-256 of the session id, so the page can name a session without having its id; `DELETE` ends one of one's own (404 for another user's), `revoke-others` ends the others of the same user and answers `{ended:N}`, `revoke-all` ends every session of everyone including this one and clears the cookies (18.45) |
| `GET /api/security/tokens[?all=1]`, `POST /api/security/tokens`, `DELETE /api/security/tokens/{id}` (all `view`, a session only) | one's own tokens, `{tokens:[{id,name,user,scope,created,expires,expired,last_used?}]}`, never the hash (`all=1` needs `users.manage`; `last_used` is since the panel started, because the panel writes no file); `POST` takes `{name,scope,days}`, checks them (400) and runs `tokens create` for the signed in user, and answers `{id,token,expires}` with `Cache-Control: no-store`, the only time the secret exists outside the script that gets it; `DELETE` ends one's own token, or any for `users.manage`, and an unknown one and another user's both answer 404 |
| `GET /api/security/logins[?user=NAME\|all=1][&limit=N]` (`view` for one's own; another user's or everyone's needs `audit.view`), `GET /api/security/check` (`audit.view`) | the sign ins from the audit log, `{logins:[{ts,user,ip,result}]}` newest first, `result` is `ok`, `denied` (wrong user or password) or `error` (too many tries), `limit` 1 to 200 and 50 by default; the JSON of `security check` unchanged (18.45) |
| `GET /api/settings`, `POST /api/settings/check`, `POST /api/settings/apply`, `GET /api/settings/job`, `PUT /api/settings/secret/{key}` | every setting and the secrets (the schema comes from `dpistack settings list --json`) |
| `GET /api/settings/profiles` (view), `GET /api/settings/profiles/{name}` (view), `PUT /api/settings/profiles/{name}` (the permission `settings.edit`; the body `{values:{K:V}}` of the other settings routes), `DELETE /api/settings/profiles/{name}` (`settings.edit`) | the profiles: the JSON of `settings profile list` and `show`, `{ok:true}` for a save or a delete, which run the verb with `--by` the panel user and the pairs on stdin; a name that is not 1 to 32 of `a-z 0-9 - _`, a key or a value of the wrong shape is 400 before the verb; there is no route that applies a profile, the screen loads its values into the staged change (18.44) |
| `GET /metrics` | the Prometheus export (section 4.9) |

The panel answers 403 if the IP of the client is outside every network of `LAN_CIDR` (with the `lan` policy) or outside loopback (the `localhost` policy). With `nginx` it trusts `X-Forwarded-For` only from `127.0.0.1`.

### 4.9 The metrics export `GET /metrics`

The Prometheus text exposition format 0.0.4, `Content-Type: text/plain; version=0.0.4; charset=utf-8`. Access: the header `Authorization: Bearer <METRICS_TOKEN>` (the word `Bearer` is case-insensitive; a token without it is not accepted), no session is needed. The IP restriction of 4.8 applies. With `METRICS_EXPORT=no` the answer is 404, without a token or with a wrong one 401.

| metric | type | labels | source |
| --- | --- | --- | --- |
| `dpistack_component_up` | gauge | `component` | `health.json`, `<id>.process`: 1 with `active`, otherwise 0 |
| `dpistack_check_status` | gauge | `check` | `health.json`: `ok`=0, `warn`=1, `crit`=2; `na` is not printed |
| `dpistack_suricata_kernel_packets_total` | counter |  | `stats.capture.kernel_packets` |
| `dpistack_suricata_kernel_drops_total` | counter |  | `stats.capture.kernel_drops` |
| `dpistack_suricata_drop_ratio` | gauge |  | the share 0..1 over the last `stats` interval, see 4.7 |
| `dpistack_suricata_uptime_seconds` | gauge |  | `stats.uptime` |
| `dpistack_eve_events_total` | counter | `event_type` | the events read by the panel since its start |
| `dpistack_eve_size_bytes` | gauge |  | the size of `eve.json` |
| `dpistack_eve_last_event_age_seconds` | gauge |  | the age of the last event |
| `dpistack_disk_free_ratio` | gauge | `path` | `statfs` on the data directories (the Suricata log, the EveBox data, the metrics backend data) |
| `dpistack_rules_age_seconds` | gauge |  | the age of `suricata.rules` |
| `dpistack_test_status` | gauge | `test` | the last result: 1 `pass`, 0 `fail`; `skip` is not printed |
| `dpistack_test_timestamp_seconds` | gauge | `test` | the time of the last run |
| `dpistack_panel_rss_bytes` | gauge |  | the RSS of the panel |

The metrics `eve` and `suricata_*` are not printed with `EVE_FILE=no` or without `stats` in `EVE_TYPES`.

---

### 4.10 Runtimes: what can run in Docker and how the parts find each other (v41)

Every part that has an image can run as a container (`<PART>_RUNTIME=docker`) or natively, in any combination. Containers use `network_mode: host`, so a native part and a container reach each other on the same host addresses (`127.0.0.1` or the bind address of `ACCESS_MODE`); there is no second set of addresses to keep in step. Files are shared by bind mounts of the same host paths (`/var/log/suricata`, `/var/run/suricata`, the rules and the config directories).

| Part | Docker | Why / how |
|---|---|---|
| `suricata` | yes | image `jasonish/suricata`; no nDPI plugin in the image, no IPS (`mode ips` needs a native Suricata) |
| `ndpi` | no | a plugin built into a native Suricata |
| `rules` | follows `suricata` | `suricata-update` runs on the host or inside the Suricata container |
| `evebox` | yes | image `jasonish/evebox` |
| `ntopng` | yes | image `ntop/ntopng` |
| `redis` | follows `ntopng` | the store of ntopng, always in the same runtime as ntopng |
| `victoriametrics`, `prometheus` | yes | only the selected backend |
| `node_exporter`, `grafana` | yes | images `prom/node-exporter`, `grafana/grafana-oss` |
| `panel` | yes | an image built on the host; privileged, `pid: host`, reaches `dpistack` through `nsenter` |
| `watch` | no | a systemd timer that calls the `dpistack` of the host |
| `nginx` | no | a host package, only with `ACCESS_MODE=nginx` |
| `firewall` | no | rules of the host kernel; they guard host-network containers too |
| `installer` | no | `install.sh` and `dpistack` are host scripts |

The links between the parts and what is checked on each: `suricata` to `evebox` and to `panel` (the file `eve.json` is readable), `redis` to `ntopng` (`127.0.0.1:6379` accepts a connection), `panel` and `node_exporter` to the metrics backend (the scrape target accepts a connection; with nginx the panel is on `PANEL_PORT+10000`), the metrics backend to `grafana` (the data source accepts a connection).

`dpistack runtime [--json]` (read only, open to the panel) prints the table above with the runtime of every part now, the flag `mixed` (some parts are containers and some are native) and the list of links `{from, to, what, endpoint, ok}`; `ok` is `true` or `false` when both ends run and `null` when one does not. A refusal of an impossible combination stays where it is (the config check, `preflight` and `mode ips`: nDPI with a Suricata container, IPS with a Suricata container) and names the reason.

## 5. The installer: rules and scenarios

A **step** is a pair of functions `step_<name>_check` (code 0 if the state already matches the config) and `step_<name>_apply`, plus `step_<name>_plan` (one line for dry-run). The order of the steps: `preflight`, `selfinstall`, `ndpi`, `suricata`, `rules`, `redis`, `ntopng`, `evebox`, `metrics`, `nodeexp`, `grafana`, `access`, `panel`, `watch`, `verify`.

The `selfinstall` step copies `install.sh`, `lib/*.sh` and `templates/*` into `/usr/local/lib/dpistack/installer/` and puts the executable `install.sh` of that copy at `/usr/local/sbin/dpistack`. After this step the `dpistack` command works without the original clone or archive of the repository (section 5.2). It is idempotent by the hash of the copied files, like the other steps (5.4). It also deletes a leftover link `/usr/local/sbin/dpistack-ctl` of an earlier version.

### 5.0 The installer menu: general rules

- The menu is opened by the commands `install` and `reconfigure`, and by the binary `dpistack` with no arguments, when there is a terminal and `-y` is not given. The implementation is pure Bash in `lib/menu.sh`: no `dialog`, `whiptail`, ncurses and no cursor sequences. The screen is printed anew after every action, so the menu works over SSH and `tmux` and stays in the history of the terminal.
- Input is read from stdin, and from `/dev/tty` when run through `curl | bash`. The variable `DPISTACK_INPUT=<file>` replaces the source (this is how the tests work). No terminal, no `DPISTACK_INPUT` and no `-y`: code 2 and a hint about `-y`.
- Colors are on only on a terminal and without `NO_COLOR` and `--no-color`.
- **A question only where something is lost or hard to undo (v0.26.1, replaces "every action asks first" of v0.25.0; policy in 18.29).** Asked: `Install?`/Apply with the summary and the diff, `q` with unapplied edits, `r` (discard edits), overwriting an existing file on save (`[y/N]`), upgrade of packages, uninstall (the word `remove`), the first question of a fresh install (guided setup or not) and the continue-the-draft question. Not asked: setting or resetting a key and switching a part (they are edits of a draft until Apply, with `d` for the diff and `r` to drop them), what was just typed (a value, the panel password repeated twice), check, plan, load from a file, the check tests, opening the password screen, entering and leaving a group of the guided setup (`s` skips a group, `x` leaves and keeps the answers). `[Y/n, 0 = cancel]` is the form of a question (`[y/N]` for the risky ones); `-y` asks nothing, as before.
- **Every screen has an exit (v0.25.0).** `0` or an empty input goes back from a section, a key editor (`cancel` too), the component screen and the file prompts; `!cancel` leaves the panel password prompt; `q` quits from every list screen.
- **Choose components (`m`).** One screen with a `[x]`/`[ ]` line for Suricata, the nDPI plugin, the rules, EveBox, ntopng with Redis, the panel, the watchdog, Grafana and node_exporter, plus the metrics storage. A number switches a part after a confirmation. Switching Suricata off switches nDPI and the rules off, nDPI and the rules cannot be switched on while Suricata is off. The note says that anything already installed stays (`uninstall` removes it).
- **Guided setup (`w`).** Asks the components screen first, then every key of every group, advanced keys included, except the keys of a part that is switched off or of a mode that is not chosen (`IPS_*` without `ips`, `NGINX_*` without `nginx`, `ALERT_TG_*` without the `tg` channel and so on; the table is `menu_key_skipped` in `lib/menu.sh`). Per question: Enter keeps, `-` resets, `s` skips the group, `x` leaves (with a confirmation, the answers so far stay), `?` helps; a typed value is confirmed. On a fresh `install` it is offered first (`Run the guided setup first?`), `n` goes to the main menu.
- Navigation: an item is chosen by a number or a letter; `0` or an empty input goes one level up; `?` shows the help of the screen; `q` quits.
- The screen of a config section: the keys as a list `N) KEY = value`. Markers: `*` the value differs from the default, `~` (only in "Configure" of an existing install) differs from the applied one, `!` the key has an error. The item `a` turns the display of advanced keys on and off (with `--advanced` they are visible at once).
- Editing a key: the number of the key, then a question with the hint, the options and the default. A key with fixed options is chosen by a number from the list, the others are typed as text. Enter keeps the value, `-` resets to the default, `?` shows the hint. The value is checked against the schema at once: a wrong one is refused with the list of the allowed ones, the previous one stays.
- The screen of the config sections always shows the summary of problems (the schema and the cross checks of 4.3) and does not let you choose "Install" or "Apply" while they exist.
- Secrets are typed without echo. In the screens, the summary and the diff they are shown as `set` or `not set`.
- Edits are saved into `/etc/dpistack/dpistack.conf.draft` (0600 root) after every change. Secrets are not written into the draft. A broken session does not lose the input: at the next start the menu offers to continue the draft. `dpistack.conf` changes only on apply.
- `q` with unapplied edits asks for a confirmation. `Ctrl+C` ends the work, changing nothing in the system and leaving no partly written files (`trap`, temporary files are removed).
- The keys of the basic level: `SURICATA_RUNTIME`, `EVEBOX_RUNTIME`, `NTOPNG_RUNTIME`, `SURICATA_SOURCE`, `NDPI_ENABLE`, `IFACES`, `EVE_TYPES`, `ACCESS_MODE`, `BIND_ADDR`, `ALERT_CHANNELS`, `METRICS_BACKEND`, `NODE_EXPORTER_ENABLE`, `GRAFANA_ENABLE`, `PANEL_EDITION`, `PIN_VERSIONS`. The other keys are of the advanced level.

The sections of the config screen (the "group" column is the column of `lib/schema.sh`; every key belongs to exactly one group):

| group | menu item | keys |
| --- | --- | --- |
| `capture` | Capture and mode | `IFACES`, `BPF_FILTER`, `HOME_NET`, `SURICATA_MODE`, `IPS_METHOD`, `IPS_NFQ_CHAINS`, `NTOPNG_IFACES` |
| `components` | Components and sources | `SURICATA_RUNTIME`, `EVEBOX_RUNTIME`, `NTOPNG_RUNTIME`, `SURICATA_SOURCE`, `SURICATA_VERSION`, `NDPI_ENABLE`, `NDPI_SOURCE`, `NDPI_VERSION`, `NTOPNG_VERSION`, `EVEBOX_VERSION`, `PIN_VERSIONS`, `PANEL_SOURCE` |
| `eve` | EVE and storage | `EVE_FILE`, `EVE_TYPES`, `EVE_SYSLOG`, `EVE_REDIS`, `EVE_ROTATE`, `EVE_KEEP`, `EVE_MAX_SIZE_MB`, `STATS_INTERVAL_SEC`, `EVEBOX_DB`, `EVEBOX_ES_URL`, `EVEBOX_RETENTION_DAYS` |
| `rules` | Rules | `RULES_SOURCES`, `RULES_URLS`, `RULES_GROUPS`, `RULES_UPDATE`, `RULES_UPDATE_CALENDAR`, `EXCEPTIONS_DEFAULT_DAYS` |
| `access` | Access | `ACCESS_MODE`, `BIND_ADDR`, `LAN_CIDR`, `PANEL_PORT`, `PANEL_RUNTIME`, `PANEL_EDITION`, `NTOPNG_PORT`, `EVEBOX_PORT`, `NGINX_MANAGE`, `NGINX_TLS`, `NGINX_CERT`, `NGINX_KEY`, `FIREWALL_MANAGE` |
| `metrics` | Metrics | `METRICS_EXPORT`, `METRICS_BACKEND`, `METRICS_BACKEND_RUNTIME`, `METRICS_BACKEND_PORT`, `METRICS_RETENTION`, `NODE_EXPORTER_*`, `GRAFANA_*` |
| `watch` | Watch and alerts | `WATCH_ENABLE`, every `WATCH_*`, `ALERT_CHANNELS`, `ALERT_TG_CHAT_ID`, `ALERT_TG_TOKEN`, `ALERT_MAIL_TO`, `ALERT_MAIL_FROM`, `ALERT_SMTP_URL` |
| `tests` | Tests | `TEST_HTTPS_URL`, `TEST_BT_LIVE`, `TEST_ON_INSTALL` |
| an action | Panel password | not a config key, kept only as a hash |

`METRICS_TOKEN` is generated by the installer and is not edited in the menu.

### 5.1 `install.sh install` / `dpistack install`: what happens

The explicit command `install` (unlike the binary `dpistack` called with no arguments, section 5.2) always leads along the install path described here, even if `dpistack.conf` already exists.

**Start.** A `flock` lock on `/var/lock/dpistack.lock` is taken (a second instance exits with code 1), `install.log` is opened. The installer detects the system: the distribution, the architecture, the presence of `systemd` and Docker. Then:

- if `dpistack.conf` already exists, the screen "Installation found" opens: `1) configure (go to "Configure", section 5.3)`, `2) apply the current config again` (idempotent, no questions), `3) open the control menu (section 5.2)`, `4) quit`. An existing install must not be silently overwritten;
- if there is a draft, `Continue the draft? [Y/n]` is offered;
- otherwise (a fresh install) the main install menu opens.

**The main install menu** (an example, a short summary of values on the right):

```
dpistack 0.24  |  Ubuntu 24.04, amd64  |  systemd: yes  |  docker: no
Install. Config: /etc/dpistack/dpistack.conf (not created)

  1) Quick install
  2) Capture and mode              IDS, enp2s0
  3) Components and sources        Suricata: source, with the nDPI plugin: yes
  4) EVE and storage               6 types, rotation daily
  5) Rules                         ET Open, weekly
  6) Access                        localhost
  7) Metrics                       export: yes, backend: none
  8) Watch and alerts              panel, log
  9) Tests                         after install: yes
 10) Panel password                not set

  c) Check the system    p) Plan    s) Save to file    l) Load from file
  i) Install             q) Quit

Problems (1): the panel password is not set
>
```

The items:

- **1, Quick install.** A short survey: the interfaces (the list of those found by `ip -o link` without `lo`, the default-route interface is marked, the choice is by numbers separated by commas), the Suricata source (`source` gives nDPI, `oisf` and `distro` install faster but without the nDPI plugin), the access mode, **the listen address** (the IPv4 addresses of this host from `ip -o -4 addr`, for example `192.168.1.156 on enp2s0`, or `0) auto`; asked unless the mode is `nginx`), **the metrics stack** (a storage `none`/`victoriametrics`/`prometheus`, Grafana yes/no and node_exporter yes/no, each on its own), **which panel (`full` or `lite`)**, the panel password. The rest is the default. The install does not start by itself: the menu returns to the main one so the summary can be checked.
- **2-9, sections.** The screen of a section by the rules of 5.0.
- **10, Panel password.** Typed twice without echo, an empty password is refused. The hash is written at the apply stage.
- **m, w.** The component screen and the guided setup of 5.0, also in the reconfigure screen.
- **c, Check the system.** Preflight (5.5) with no changes to the system, the result as a list.
- **p, Plan.** The `check` of every step and a table `needs applying / no changes`. It changes nothing.
- **s, l.** Save the current values into a file and load them from a file. A loaded file is checked against the schema, errors are shown as a list, the loaded values become edits.
- **i, Install.** Starts the sequence below.

**What happens after `i`** (and at once with `-y`, with no menu):

1. **The layers of values.** A later one overrides an earlier one: the defaults from `schema.sh` -> the existing `dpistack.conf` -> `secrets.conf` and the environment variables for secrets -> `--config` -> `--set` -> the edits from the menu.
2. **The config check.** The schema (type, options) and the cross rules of 4.3. All errors are printed as a list, code 2 (in the menu a return to the main menu). For `ACCESS_MODE` other than `localhost`, or a non-loopback `BIND_ADDR`, the warning of section 1 is shown and a confirmation is required.
3. **The summary and the confirmation.** The final config is printed (secrets hidden) and `Install? [y/N]` (with `-y` there is no question). Then `dpistack.conf` (0644) and `secrets.conf` (0600) are written and the draft is removed.
4. **Preflight.** All the checks of 5.5 are run to the end, the errors are printed as a list, code 3. Until this moment no component has been touched. Two things are written before it on purpose: `dpistack.conf` (the answers of a long guided setup must survive a failed check) and the persistent command `dpistack` (the `selfinstall` step runs first, v0.25.2; it depends on no component), so the next run after the fix is `sudo dpistack install`. A failed preflight prints exactly that.
4a0. **Preflight tools.** Preflight itself calls `ss` and `curl`; a minimal image has none, so before it (not in `--dry-run`, only as root) `iproute2 curl ca-certificates` are installed. The existence of an interface is checked through `ip`, and without it through `/sys/class/net`; the default-route interface is read from `/proc/net/route`, so detection works before `iproute2` is installed.
4a. **Preparing packages** (a "choose yourself" decision, v9; `prepare_packages`, does not change the config while everything is there). One `apt-get update` per run before the first install (the steps that add a repository update the index once more themselves). Then the base packages: `ca-certificates curl wget gnupg jq git openssl logrotate iproute2 sudo` (`sudo` is needed by `visudo` for the rule of the panel), on Ubuntu also `software-properties-common` (for `add-apt-repository`); a minimal image contains none of them. Then a check that the chosen source can give the component at all: `SURICATA_SOURCE=distro` without the `suricata` package in the repositories, `SURICATA_SOURCE=oisf` not on Ubuntu (the PPA is for Ubuntu only), `NDPI_SOURCE=pkg` without `libndpi-dev` are replaced by `source` with a message; the new value is written into `dpistack.conf` and the `applied` snapshot, and preflight runs again (the build needs 4 GB). If the component is already installed in any way, the value is not touched. `reconfigure` and `upgrade` also update the index before installing packages (`upgrade` used not to update it and did not notice an `apt-get` error).
5. **The plan.** For every step `check` is called, a table and the `plan` lines are printed. With `--dry-run` the work ends here, code 0, `dpistack.conf` is not written.
6. **Applying** in the order of the steps (including `selfinstall`, see the note at the start of section 5). On the screen there is one line per step: `[3/15] suricata ... done`, `no changes` or `error`; the details are in `install.log`. On every step: `apply`, then `check` again (the postcondition) and the result is written to `state`. Rendered files keep a hash; hand-edited ones are not overwritten without `--force`. A failed step stops the install: the name of the step, the reason and the command to continue `install.sh install --only <step>` are printed. The steps already applied stay, installed packages are not removed, the files changed by the failed step in this run are restored from `backups/`.
7. **Verification.** The `verify` step runs `ctl test all` with `TEST_ON_INSTALL=yes`. A failed test does not cancel the install and goes into the report.
8. **The final report.** The addresses by `ACCESS_MODE` and `BIND_ADDR` (the panel, EveBox, ntopng, the metrics backend, Grafana), the result of the tests, where the configs and logs are, the `dpistack` command for further control (section 5.2), the `/metrics` token and a ready `scrape_config` line, the generated panel password (only if it was created, shown once), warnings (the topology, SELinux, a password over HTTP in `lan`, the first Grafana login `admin`/`admin`).

The panel password: in the menu it is typed by hand and without it "Install" is unavailable. With `-y` it is taken from `DPISTACK_PANEL_PASSWORD`, and if the variable is absent a random one (24 characters) is generated and printed once in the report of a real install (with `--dry-run` it is neither generated nor printed). It is stored in plain form nowhere. It is changed by the control menu item "Panel password" (5.2) or by the command `ctl panel-passwd`.

### 5.2 The persistent command `dpistack` and the control menu

After the install the system has an executable `/usr/local/sbin/dpistack` (the `selfinstall` step): the same code as `install.sh`, copied together with `lib/` and `templates/` into `/usr/local/lib/dpistack/installer/`, so the command works without the original clone or archive. `dpistack` is meant for a direct run by the administrator as root; the panel and the watchdog call the same program through `sudo -n` and may use only the narrow list of verbs of 4.5.

**What `dpistack` shows with no arguments** depends on the state:

- there is no `dpistack.conf`: the main install menu, section 5.1 (the same path as `install.sh install` on a fresh system);
- there is a `dpistack.conf`: **the control menu**:

```
dpistack 0.24  |  Managing the installed stand
Config: /etc/dpistack/dpistack.conf  |  components: 6 of 6 active  |  health: ok

  1) Configure                     config sections, diff, apply
  2) Component status
  3) Logs
  4) Run tests
  5) Upgrade packages (upgrade)
  6) Uninstall (uninstall)
  7) Panel password

  q) Quit
>
```

The items:

- **1, Configure.** Opens the screen of the config sections with the diff and applying (section 5.3). The same screen is opened by the command `dpistack reconfigure`, bypassing the control menu.
- **2, Component status.** The output of `dpistack status` line by line: the component, the state, whether it is enabled at boot.
- **3, Logs.** The list of components of 4.1, chosen by a number, then `dpistack logs <id> -n 200`; `f` inside the view switches to `--follow` until `Ctrl+C`.
- **4, Run tests.** `dpistack test all --json`, the result line by line as in 10.
- **5, Upgrade packages.** Runs `upgrade` (5.7) with a confirmation if there are unpinned packages to upgrade.
- **6, Uninstall.** Requires typing the word `remove` as a confirmation, then `1) normal removal` or `2) removal with data (--purge)`; an empty input cancels.
- **7, Panel password.** Typed twice without echo, then `ctl panel-passwd`.

Items 2-4 only read the system and need no confirmation. If a verb is unavailable or returned an error, the item shows the reason and returns to the control menu without ending `dpistack` as a whole.

**Non-interactively** the same actions are available as subcommands: `dpistack status`, `dpistack test [bittorrent|https|all]`, `dpistack logs <id> [-n N] [--follow]`. `dpistack upgrade` and `dpistack uninstall [--purge]` are as in 5.7. `dpistack reconfigure` is as in 5.3.

### 5.3 "Configure" (`dpistack reconfigure`): what happens

**The start** is as in 5.1 (the lock, the log, the draft). If there is no `dpistack.conf`, an error with a hint about `install`, code 2. Otherwise the screen of the config sections of the existing install opens. Its items are the same as at the install, but the values are the current ones, not the defaults:

```
dpistack 0.24  |  Configuring an existing installation
Config: /etc/dpistack/dpistack.conf  |  components: 6 of 6 active  |  health: ok

  1) Capture and mode              IDS, enp2s0, enp3s0       ~
  2) Components and sources        Suricata: source, with the nDPI plugin: yes
  3) EVE and storage               6 types, rotation daily
  4) Rules                         ET Open, weekly
  5) Access                        localhost
  6) Metrics                       export: yes, backend: none
  7) Watch and alerts              panel, log
  8) Tests                         after install: yes
  9) Panel password                change

  d) Changes (diff)       a) Apply                r) Discard edits
  0) Back to the control menu      q) Quit

Edits: 1 key (IFACES). Problems: none
>
```

The differences from the install:

- The marker `~` at a section and a key means "differs from the applied one".
- **d, Changes.** Line by line `KEY: old -> new` (secrets: `changed`), the list of the affected steps by the table below and a "light" or "heavy" mark at every change.
- **r, Discard edits.** With a confirmation it drops all unapplied edits and deletes the draft.
- **0, Back.** Available only when the screen is opened from the control menu (not with a direct `dpistack reconfigure`); without edits it leaves at once, with edits it acts like `q`.
- **There is no quick install.** The panel password is changed by a separate item (without echo, twice); at the apply stage `ctl panel-passwd` is called.

The component status and running tests are not duplicated on this screen: they are in the control menu (5.2).

**What happens after `a`** (and at once with `-y --set ...` through `dpistack reconfigure`, with no menu):

1. **The diff.** `config.sh` compares the applied config (`old`) with the new set and gives the list of changed keys. No changes: `no changes`, code 0.
2. **Finding the steps.** Every key of the schema knows its steps (the table below). The changed keys give the set of steps to apply, the others are skipped by `check`.
3. **Classification.** The changes are split into light (rendering files again and a restart) and heavy (packages, a build, a runtime change, a version, pinning). For the heavy ones it is shown what will be reinstalled or rebuilt, and `Continue? [y/N]` is asked (with `-y` `--force` is needed).
4. **The summary and the confirmation** with the diff of keys and the list of steps. `--dry-run` prints the plan and exits.
5. **Applying.** The new config is written to `dpistack.conf.new`, the steps work with it. Every affected file is rendered with a backup, then checked (`suricata -T` for Suricata and the rules), then the component is restarted or reloads its config. A failed check keeps the previous file and the previous `dpistack.conf`, prints the output of the check, code 1; the screen stays open with the edits so they can be fixed. Success atomically renames `dpistack.conf.new` to `dpistack.conf`, updates `state`, deletes the draft.
6. **The report** with what changed and the warnings. The tests are not run automatically (the item "Run tests" of the control menu or `--only verify`).

From the panel and `ctl` a change of the config goes the same way, but with no menu, no questions and no heavy changes (`ctl reconfigure`, section 4.5; `settings set --apply-heavy` runs a heavy one as a separate job).

The keys and the affected steps:

| key group | steps | type |
| --- | --- | --- |
| `IFACES`, `BPF_FILTER`, `HOME_NET`, `SURICATA_MODE`, `IPS_*`, `EVE_*`, `STATS_INTERVAL_SEC` | `suricata` (rendering, restart), `ntopng` for `IFACES`, `watch` for `EVE_*` and `STATS_*` | light |
| `RULES_*` | `rules` | light |
| `NTOPNG_IFACES`, `NTOPNG_PORT`, `EVEBOX_PORT`, `EVEBOX_RETENTION_DAYS`, `EVEBOX_ES_URL` | `ntopng` or `evebox`, `access` | light |
| `ACCESS_MODE`, `BIND_ADDR`, `LAN_CIDR`, `PANEL_PORT`, `PANEL_EDITION`, `NGINX_*`, `FIREWALL_MANAGE` | `access`, `panel`; `BIND_ADDR` and `ACCESS_MODE` also `evebox`, `ntopng`, `metrics`, `nodeexp`, `grafana` | light |
| `WATCH_*`, `ALERT_*` | `watch` | light |
| `METRICS_EXPORT`, `METRICS_RETENTION`, `METRICS_BACKEND_PORT` | `metrics`, `panel` (and `grafana` for the port) | light |
| `NODE_EXPORTER_PORT`, `GRAFANA_PORT` | `nodeexp` and `metrics`, `grafana` | light |
| `METRICS_BACKEND`, `METRICS_BACKEND_RUNTIME` | `metrics` (and `grafana` for the backend) | heavy |
| `NODE_EXPORTER_ENABLE`, `NODE_EXPORTER_RUNTIME`, `GRAFANA_ENABLE`, `GRAFANA_RUNTIME` | `nodeexp` (and `metrics`), `grafana` | heavy |
| `TEST_*` | `verify` | light |
| `*_RUNTIME`, `*_SOURCE`, `*_VERSION`, `NDPI_*`, `PIN_VERSIONS`, `EVEBOX_DB`, `PANEL_SOURCE` | the step of the component | heavy |

### 5.4 Idempotence

- A repeated run with the same config changes nothing: every step prints `no changes`, code 0. It is checked by a bats test on stubs.
- A rendered file keeps the hash of the last render in `state`. No file: render. The hash matches and the input changed: render. The file was changed by hand (also through the panel): it stays and the installer prints a notice. `--force` makes a backup in `backups/` and overwrites. This rule applies to the re-rendering at `iface add|remove` and `reconfigure` too.
- Packages are installed only if they are missing or their version differs from the pinned one.
- The `selfinstall` step copies files only if their hash in `/usr/local/lib/dpistack/installer/` differs from the hash in the source (an update of the version of the bundle).
- The installer never flushes or recreates other people's iptables/nft chains. Its own rules live in a separate chain `DPISTACK` (or, without `iptables`, in the `nft` table `inet dpistack`) that the unit `dpistack-fw.service` restores at every boot.

### 5.5 Preflight

Root, Bash 4.4+, a distribution and an architecture from the supported ones, `systemd` (for native), Docker with `compose` (if some component uses `docker`), the interfaces of `IFACES` exist (`ip link`), `BIND_ADDR` is an address of this host (outside `nginx`), free space (at least 4 GB with `SURICATA_SOURCE=source`, otherwise 1 GB), the needed hosts are reachable with `curl`, the ports of 4.3 are free (`ss -ltn`), the SELinux mode (only to report). A failure gives code 3 and the whole list of the reasons, not the first one. A busy port in the menu is a warning with the name of the process that holds it and the nearest free port (Enter takes it, the user can type another one); without a terminal the install stops with code 3 and the message names a free port.

**The dnf family (v10).** `pkg_update_once` does `dnf makecache`; the base packages are installed only for the missing commands (on RHEL 9 `curl` conflicts with `curl-minimal`): `curl wget gnupg2 jq git openssl logrotate iproute sudo ca-certificates`. Rocky, AlmaLinux and CentOS get `epel-release` and the `crb` repository (version 8: `powertools`); Fedora and Amazon Linux get nothing; RHEL asks to turn on EPEL and CodeReady Builder by hand. Names: `ndpi-devel`, `redis` and `redis.service`; package versions through `rpm -q`, pinning through `dnf versionlock`, the update `dnf upgrade`. ntopng: the repository `packages.ntop.org/centos-stable/ntop.repo` for the RHEL clones (by the documentation of ntop.org), for Fedora and Amazon Linux there is none, there the package comes from the distribution or the step is skipped. EveBox: the URL of the rpm repository is not confirmed, so it is not guessed: the step stops with a hint `--skip evebox` or installing the package by hand. The firewall: `ufw` where there is one, otherwise `firewalld` (rich rules and `--reload`); with SELinux Enforcing and `ACCESS_MODE=nginx` `httpd_can_network_connect` is turned on. On dnf the preflight writes a warning and does not refuse.

**Platforms and stable versions (v11).** `os_support_level` parses `/etc/os-release`: `supported`, `unverified` (a warning in the log) or `unsupported` (the reason in `preflight`, code 3). Stable sources are taken, development builds are not used anywhere by default: Suricata from the last tested release of the 8.0 series (`SURICATA_STABLE_REF`, now `suricata-8.0.8`; the MSRV of Rust is 1.75, so the stock `rustc` of Ubuntu 24.04 is enough), nDPI 4.14, ntop.org from `apt-stable` for the Debian family (for Ubuntu `apt-stable/<version>`, for Debian `apt-stable/<release name>`, the file `apt-ntop-stable.deb`) and `centos-stable` for the RHEL family, EveBox from the `stable` channel. The `apt` channel of ntop.org (nightly builds of `master`) is not used and there is no quiet fall back to it: no stable package means the step stops with an error. On Debian ntop.org requires the `contrib` component: `apt_enable_component` adds it to the lines and blocks of `deb`, `deb-src` and `*.sources` (deb822) only for `debian.org` hosts, once, with a copy in the backup directory. A change of the Suricata release tag in an already built tree leads to `git clean -fdx` and a rebuild. The RHEL family: `SURICATA_SOURCE=oisf` turns on the COPR `@oisf/suricata-8.0`, the package is started by a unit with the options from `/etc/sysconfig/suricata` (`--af-packet --user suricata`, the interfaces are taken from `suricata.yaml`), RHEL gets EPEL from the Fedora project and CodeReady Builder through `subscription-manager` (without a subscription a message, the install of packages goes on). Where Suricata cannot be built (no Rust 1.75), `install` takes the package: from the distribution on the Debian family, from the COPR on the RHEL family, and nDPI is turned off. `preflight` checks the availability of the repositories that the chosen steps will need (the OISF PPA or COPR, ntop.org, EveBox) and honors `--skip` and `--only`. `uninstall --purge` removes the system user of the panel.

**The RHEL clones from 8 (v12).** Rocky Linux and AlmaLinux 8, 9 and 10 are supported by one code: on 8 `powertools` is turned on instead of `crb`. Rust for a build on EL8 comes from modular packages that `dnf repoquery` may not show; then `install` takes the OISF COPR package (the 8.0 series is built for EPEL 8 too) and nDPI is turned off.

**Building from source (v9).** Before building Suricata and nDPI the dependencies are installed: `build-essential git autoconf automake libtool pkg-config make libpcap-dev`, for Suricata also `libpcre2-dev libyaml-dev libjansson-dev libmagic-dev zlib1g-dev libcap-ng-dev libnet1-dev liblz4-dev python3-yaml cargo rustc` and `cbindgen` if it is in the repository (the names were checked on Ubuntu 24.04). Building Suricata from git needs Rust 1.85. If `rustc` is older, `rustc-1.N` and `cargo-1.N` with the smallest `N` not below 85 are installed (on Ubuntu 22.04 and 24.04 they lie next to `rustc` 1.75) and passed to `configure` through `RUSTC` and `CARGO`, as OISF describes. If there are no such packages (Debian 12: `rustc` 1.63) and `SURICATA_VERSION` is not set, `install` switches, before the build, to the Suricata package of the distribution and turns nDPI off: the plugin exists only in a build from source. A pinned `SURICATA_VERSION` is not touched, and `configure` will stop at the Rust check. This adds no new keys to `dpistack.conf`. `configure` gets `--libdir=/usr/lib`, otherwise the nDPI plugin lies in `/usr/local/lib/suricata`, while `suricata.yaml` and all the code look for it in `/usr/lib/suricata`; after `make install` `make install-conf` runs, which installs `classification.config`, `reference.config` and `threshold.config` and does not overwrite an existing `suricata.yaml`. The build of Suricata from source uses a stable tag by default, `master` only with an explicit `SURICATA_VERSION=master`. The pinned `NDPI_VERSION` and `SURICATA_VERSION` are compared with the state as commits (`git rev-parse <ref>^{commit}`), not as text.

### 5.6 Modes and secrets

- The non-interactive mode: values from `--config`, then `--set`, then the defaults. Secrets only from `secrets.conf` or environment variables. A prompt for input in this mode is an error.
- `--dry-run`: `run` prints `+ command` and does not execute. Nothing is written to `state`, `dpistack.conf`, `panel.auth` and the install log, the panel password is neither generated nor printed, `argon2` is not installed (R81: a password generated in a trial run would be shown but not saved, and the real run would create another one). Reading the system is allowed.
- Secrets do not get into `dpistack.conf`, the install log and the output of `--dry-run`. `set -x` in the scripts is forbidden.

### 5.7 Upgrade and uninstall

`upgrade` honors `PIN_VERSIONS` and does not touch the pinned ones without `--set`. `uninstall` stops and disables the units, removes the units and binaries of the bundle (including `/usr/local/sbin/dpistack` and `/usr/local/lib/dpistack/installer/`, and the node_exporter and Grafana it installed), keeps the data and configs of Suricata, EveBox, ntopng and the metrics backend. `uninstall --purge` removes those too, after a confirmation (in the non-interactive mode the flag itself is the confirmation; in the control menu it is the word `remove`, section 5.2).

**What `uninstall` removes (v0.26.0), and what it never does.** Always: the units, binaries, the persistent command and installer copy, the sudoers file, the nginx snippet, the firewall rules dpistack added, `metrics.token`, the Grafana ini and provisioning, `dpistack.conf` and the state, and, for the docker runtime, the whole compose project (`docker compose -p <project> down --remove-orphans`: only the containers of that project) with its compose file and the panel images dpistack built (`dpistack-panel:*`). With `--purge` also: the EveBox and Grafana data, the logs, the apt/dnf repository files dpistack added, the nDPI plugin and the build trees (`make uninstall` of each, so only what that build installed), and the pulled images of the stack (`docker image rm`, which refuses an image another container still uses, so a shared image stays). Never: packages (`apt`/`dnf` remove), Docker itself, a container, image, volume or network that is not dpistack's, `docker system prune` or any blanket cleanup, and any file outside the paths above. The log directory is removed last because every step writes to it. The menu offers it twice: the first screen of an existing installation ("4) Uninstall") and the control menu (item 6); both ask for the word `remove`.

---

## 6. Suricata and nDPI: integration rules

- **Capture:** `af-packet`, a block per interface of `IFACES`, `cluster-type: cluster_flow`, `defrag: yes`, `threads: auto`, `cluster-id` is unique for an interface. `BPF_FILTER` is substituted if set.
- **nDPI:** with `NDPI_ENABLE=yes` the `ndpi.so` from the plugin directory of the installed Suricata is added to `plugins:`. Rules that use `ndpi-protocol` and `ndpi-risk` must start with `requires: keyword ndpi-protocol` (and/or `ndpi-risk`), so that a Suricata without the plugin skips them instead of failing.
- **Building from source:** `./configure --enable-ndpi --with-ndpi=<prefix>`. The version of nDPI is set by the requirement of the chosen version of Suricata. An incompatibility is caught at `configure` and printed as it is, there are no workarounds. After the build the installer checks for `ndpi.so` and `suricata --build-info`.
- **The unit** with `source` is rendered from `templates/`, with packages the distribution one is used and complemented with a drop-in file.
- **The config:** `suricata.yaml` is rendered fully from the template, matches the series of the built or installed Suricata (`suricata-version`) and is checked with `suricata -T` before it is written. One template serves IDS and IPS (assumption A5).
- **IDS to IPS:** switching with the `mode` command turns on `afpacket` copy-mode or the NFQUEUE rules in the `DPISTACK` chain, restarts Suricata and starts a rollback timer. Without `mode-confirm` in the given time the mode goes back to `ids`. Rules with the `drop` action come from `drop.conf`. The NFQUEUE rules are set with the flag `--queue-bypass`, so that a failure of Suricata does not cut the network. A host outside the path of the network protects only itself (the section "Domain").
- **EVE:** the types of `EVE_TYPES`. `stats` is on with the interval `STATS_INTERVAL_SEC`. The permissions of the file are `0640`. Rotation through `logrotate` without `copytruncate`: after the rotation `suricatasc -c reopen-log-files` runs, so that Suricata opens a new file.

---

## 7. Suricata rules

- Sources: `RULES_SOURCES` (names from `suricata-update list-sources`), `RULES_URLS` (your own). Your local rules lie in `local.rules` and are always included.
- The groups of `RULES_GROUPS` are turned on by lines `group:<name>.rules` in `enable.conf`. Single rules are turned off in `disable.conf`.
- The update: `dpistack-rules.timer` with `OnCalendar=$RULES_UPDATE_CALENDAR` and `Persistent=true`. The order: a snapshot of the current set -> `suricata-update` -> `suricata -T` -> `reload suricata`. An error at any step restores the snapshot and leaves `rules.age` growing (the watchdog will see it).
- `RULES_UPDATE=off` creates no timer, the update is manual only.

---

## 8. Watchdog

`dpistack-watch` is started by `dpistack-watch.timer` every `WATCH_INTERVAL_SEC` as a oneshot as root. It fixes nothing while `WATCH_AUTORESTART=no`.

| check | how | `ok` / `warn` / `crit` |
| --- | --- | --- |
| `<id>.process` | the state through the runtime | `active` / no / `failed` or `inactive` |
| `<id>.port` | `ss -ltn` on the port from the config | listening / no / missing for more than two runs in a row |
| `suricata.eve_fresh` | the age of the last event in `eve.json` | younger than `WATCH_EVE_STALE_SEC` / no / older |
| `suricata.drop_rate` | by the last two `stats` | below `WARN` / from `WARN` / from `CRIT` |
| `disk.free` | the minimum of free space over the partitions of the Suricata logs, of the EveBox data (with `sqlite`) and of the metrics backend; `detail` names the worst path | above `WARN` / below `WARN` / below `CRIT` |
| `rules.age` | the age of `suricata.rules` | younger than `WARN_DAYS` / from `WARN_DAYS` / from `CRIT_DAYS` |

The details of the checks:

- `<id>.process` takes the state from `dpistack status --json` (that is, through the runtime): `active` gives `ok`, `failed` and `inactive` give `crit`, `absent` gives `na`. The ids are `suricata`, `evebox`, `ntopng`, `redis`, `panel`, the metrics backend, `node_exporter` and `grafana`.
- `<id>.port`: the ports `EVEBOX_PORT`, `NTOPNG_PORT`, `PANEL_PORT` (with `ACCESS_MODE=nginx` the port of the service itself, plus 10000, not the port of the nginx in front of it), `METRICS_BACKEND_PORT`, `NODE_EXPORTER_PORT`, `GRAFANA_PORT`, 6379 for `redis`. A missing port for one or two runs in a row gives `warn`, three or more in a row give `crit`; the counter is in `state` (`watch.miss.<id>`).
- `suricata.eve_fresh`: the age of `eve.json` by mtime. No file gives `warn`.
- `suricata.drop_rate`: by the last two `stats` from the tail of the file (the last 4 MB, the file is not read whole). Fewer than two events give `na`. A reset of the counter (a value lower than before) gives `ok` with a note, the interval is skipped.
- `disk.free`: the partitions of the directory of `eve.json` and `/var/lib/evebox` (with `sqlite`) and of the data directory of the metrics backend. The smallest share of free space wins.
- `rules.age`: no `suricata.rules` file gives `warn`.
- With `WATCH_AUTORESTART=yes` a failed (`crit`) component is restarted through `dpistack restart <id>`, at most 3 times in a sliding hour, the time marks are in `state` (`watch.restarts.<id>`). The restart is written to the journal of the unit.
- Dependencies: `jq` (the `watch` step installs it), `flock` (util-linux): a second simultaneous run exits quietly. The unit skips the start while there is no copy of the installer and of `dpistack` (`ConditionPathExists`).
- `dpistack-watch` takes no arguments; `dpistack health` runs it once and prints `health.json`.

`na` is set if a check does not apply: `EVE_FILE=no`, no `stats` in `EVE_TYPES`, `RULES_UPDATE=off` for `rules.age`, the component is not installed.

**Alerts:** they are sent on a status change and repeated every `WATCH_REPEAT_MIN` until the status is `ok`. On return to `ok` a recovery message is sent. The channels of `ALERT_CHANNELS` work independently and in any combination:

- `panel`: a line in `events.jsonl`;
- `log`: `logger -t dpistack-watch -p daemon.warning` (the level `err` for `crit`);
- `tg`: `curl` to the Bot API, the token and `ALERT_TG_CHAT_ID`;
- `mail`: `curl --url "$ALERT_SMTP_URL"` with `ALERT_MAIL_FROM` and `ALERT_MAIL_TO`, with no local MTA.

A failure of one channel is written to the journal and does not stop the others. The texts of the messages are in English, one line per check.

---

## 9. The panel

**Resources:** the panel has no resource budget and no size limits (v0.28.0: the check `scripts/panel-budget.sh`, its stage in the gate and the weight test were removed; the panel takes the memory and the CPU it needs). It still does no polling and no work with no open tabs and no `/metrics` requests, apart from the collector tick of the metrics ring (30 seconds). The unit: `ProtectHome=yes`, `PrivateTmp=yes`, `RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6`. **There is no `MemoryMax` and no `CPUQuota`** (since v0.23.0, a decision of 2026-10-24: the lite edition is the way to a lighter panel; the earlier `PANEL_MODE=limited` had `MemoryMax=64M` and `CPUQuota=20%`). `NoNewPrivileges` and `ProtectSystem` are not set: `sudo` inherits the restrictions of the unit and `dpistack` could not write to `/etc`. The protection is built on the lists in `dpistack`.

**Editions (v0.23.0).** `PANEL_EDITION=full|lite` replaced `PANEL_MODE=limited|unlimited`. Both editions have the same screens, the same API (section 4.8) and the same features. The server picks the files: the page always asks for `app.css` and `fx.js`; the `full` edition answers with `full.css` and `fx.js`, `lite` answers with `lite.css` and an empty `nofx.js`, so a lite page never downloads the full design. The number of open log streams is fixed at 4 in both.
- **full:** a dark console: flat near-black surfaces from a fixed list, hairline borders, one cool-blue accent used sparingly, a left sidebar with the brand mark and Phosphor icons (the active item is a filled pill), capsule controls, rises into view once on scroll, and a quiet background of drifting points joined by faint lines drawn on a canvas (`fx.js`: dim, at most 70 points and a 2x pixel ratio, paused while the tab is hidden, one still frame under `prefers-reduced-motion`). The fonts are Geist and Geist Mono, served by the panel itself (9.1). On narrow screens the sidebar becomes a floating bar with a menu that opens as a full height panel.
- **lite:** a plain page with system fonts, a small stylesheet, no canvas and almost no motion; it follows `prefers-color-scheme` (the same design rules as full, 9.1; system fonts on purpose, because lite downloads nothing but its stylesheet).
- The installer asks for the edition in the quick install; the Settings screen and `dpistack settings set --apply PANEL_EDITION=...` switch it (a light change: the unit is rendered again and restarted). An old `dpistack.conf` with `PANEL_MODE` still loads: the key is dropped.

### 9.1 Design rules of the panel (v0.27.0)

The owner supplied the landing page design skill (`SKILL.md`, part B, the visual system) and asked to restyle the panel by it. The panel is a dashboard, not a landing page, so part A (intake, page structure, conversion copy) and B11 (the tagline section) do not apply; part B applies to both editions, and where the owner's earlier decisions are explicit they win (the skill says so itself). The rules are in `full.css` and `lite.css` as tokens and are enforced by `panel/web/test/design.test.mjs`.

| Rule of the skill | What the panel does |
| --- | --- |
| Fonts: Geist, Manrope, Geist Mono, Poppins; never Inter, Roboto, Arial, Open Sans, Helvetica; one typeface; no italics; no weight above bold | `full`: Geist (variable, latin subset, 29 KB) and Geist Mono for code and data only (23 KB), `panel/web/fonts/`, licence `OFL.txt` next to them, served by the panel (`font/woff2`, cached for a day). `lite`: the system stack `ui-sans-serif, system-ui` (decision: lite is the edition that downloads nothing but a stylesheet). `font-style: normal` everywhere, weights 400 to 700 |
| Copy: no hyphens in text, no orphaned words, sentence case, no exclamation marks | The visible texts of the page and the setting descriptions were rewritten (`by-size` to `size mode`, `self-signed` to `self signed`, and so on); `text-wrap: balance` on headings and `pretty` on paragraphs; the upper case labels are gone. Messages that come from the API (Go) are not part of the design layer and are unchanged |
| Type scale: Tailwind steps, snapped to the step below | Tokens `--text-xs` to `--text-3xl` with their line heights; no other size appears. Main buttons `text-base` semibold, the small ones (header, tables) `text-sm` semibold. 15 px became 14, 0.85 rem became 12, 1.7 rem became 24 |
| Spacing: 0, 2, 4, 8, 12, 16, 24, 32, 40, 48, 64, 80, 96 px only; main buttons 8 by 12 px | Tokens `--s-0` to `--s-900`; every padding, margin and gap uses them |
| Radius: Tailwind values; nested radius = outer minus gap when the gap is under 32 px and the result is over 2 | Tokens `--r-lg` 8, `--r-xl` 12, `--r-2xl` 16, `--r-full`. Cards 16; the settings warning 8; pills for controls. Where a card holds an element with 16 px of padding the formula gives 0, so the inner shape is left square or as it was |
| Borders and backgrounds: no one sided card border, no gradient backgrounds, dark backgrounds only `#000000 #181818 #1F1F1F #272727 #313131 #131209` | Flat surfaces from that list (`bg` 000000, `card` 181818, `card-2` 1F1F1F, `hover` 272727, `edge` 313131, the log wells 131209). The warning line has a full border instead of a left one. The only gradient is on the title text. The two translucent bars (the floating bar of narrow screens, the settings bar) are the skill's own "translucent surface over a blur" |
| Hero: heading gradient `#FFFFFF` to `#9B9B9B` (dark) and `#000000` to `#666666` (light), heading and subheading at most 680 px | The page title (h1) and the line under it; lite switches the gradient with the colour scheme |
| Icons: Phosphor, Solar or Iconamoon; never Material | Phosphor Icons 2.1.1 (MIT), regular weight, inline SVG (the panel has no icon fonts and no icon files); the favicon is the same shield |
| Motion: one curve `cubic-bezier(0.22, 1, 0.36, 1)`, 500 ms for position, 300 ms for colour and opacity, never under 200 ms, only transform and opacity (and colours on hover); reduced motion means plain opacity | `--ease`; no `transition: all`, no `ease`, `linear`; the glow animation of the update button is gone (a plain accent border); under `prefers-reduced-motion` movement is removed and the changes stay as opacity and colour |
| Navigation: a compact floating bar, a toggle that transforms, a full height mobile menu, links that arrive 60 ms apart (at most 400 ms in total) | On screens under 60 rem `nav` becomes a bar floating 12 px from the top, centred, translucent over a blur; the three lines of the toggle turn into a cross; the menu is a full height panel and its links rise 24 px while fading in. Escape closes it and returns the focus. Wide screens keep the sidebar (a dashboard needs it) |
| Scroll reveals: rise 32 px and fade over 600 to 800 ms once, with `IntersectionObserver` | `modules/chrome.js` marks the static blocks of the page; each one is revealed once and then unobserved. Without `IntersectionObserver` nothing is hidden. Content that scripts put into the blocks is not animated |
| States: hover, active `scale(0.98)`, a visible focus ring, skeleton loaders (no spinners), composed empty states, inline errors, no `alert()` | A 2 px accent focus ring; skeleton blocks in the first state of the lists; empty lists are cards (`.muted.empty`); errors stay inline. `confirm()` is kept for the confirmations of 5.0 and 18.29 (the owner's decision; they are not alerts) |
| Ship: skip link, description, favicon, semantic HTML, a current item in the navigation | A "Skip to content" button that moves the focus to the title, `<meta name="description">`, `favicon.svg`, `aria-current="page"` on the active item. Not applicable to a panel behind a login: privacy and terms links, cookie consent, `og:image`. A branded 404 would need a Go handler and is left for a later slice |

Decisions (the owner says "choose yourself"): the fonts are bundled into the binary (OFL 1.1 allows it), so the page stays offline and under `default-src 'self'`; the fonts are bundled as woff2; Phosphor icons are copied into the markup instead of adding a runtime dependency (the panel has no npm at runtime).

**Installing the panel (slice 17, "choose yourself" decisions):** the `panel` step installs the binary `/usr/local/bin/dpistack-panel` and the unit `dpistack-panel.service`, then `enable --now`; when the binary or the unit changes, `restart` after that. `PANEL_SOURCE=auto` (the default) takes a ready binary if it lies next to `install.sh`: `dpistack-panel-linux-amd64` or `dpistack-panel-linux-arm64` by `uname -m` (this is how the release archive puts it), else a plain `dpistack-panel`; if there is no ready one, it builds from `panel/`, as in a clone of the repository. `build` always builds, `prebuilt` takes only a ready one. The build: `go build` (`CGO_ENABLED=0`, `-trimpath -ldflags "-s -w"`) from `panel/`, the hash of the sources is remembered in `state` (`panel.src_hash`), while the sources did not change there is no rebuild. `preflight` stops the install with code 3 if the binary cannot be obtained: no ready file with `prebuilt`, and with `auto` and `build` neither a ready file, nor Go of the needed version (the minimum is in `panel/go.mod`) on the host, nor a Docker whose daemon answers `docker info` (the panel is then built in `golang:<major.minor>` with the sources mounted read-only, same flags as the host build; `DPISTACK_GO_IMAGE` overrides the image), nor the `panel/` directory. An already installed and current binary does not need these checks, so a repeated run on a host without Go passes. The flags of the unit are built by the installer: the access policy is `lan` if `ACCESS_MODE=lan` or if `BIND_ADDR` is a non-loopback address with `localhost`, the address is `access_effective_bind_host:PANEL_PORT` (`BIND_ADDR`, else `127.0.0.1`, or `0.0.0.0` in `lan`), with the policy `lan` also `-lan-cidr` with the already resolved `LAN_CIDR` (if it cannot be determined, `127.0.0.1/32` with a warning, as in the `access` step: the panel is closed for all except the host itself until `LAN_CIDR` is set by hand); with `nginx` the address is `127.0.0.1:PANEL_PORT+10000` (nginx holds the outer `PANEL_PORT`) and `-lan-cidr`; with the `lite` edition also `-lite`. `uninstall` stops the unit and removes it together with the binary. The generated password is printed in the final report once next to `METRICS_TOKEN`; it is not in `install.log`, `dpistack.conf`, `secrets.conf` and `state`, only the hash is on disk.

**Overview (slice 17):** the overall `overall` from `health.json` with a colored badge (`ok`, `warn`, `crit`, and "No data" while the watchdog has not written a report), the table of components from `ctl status` and the list of the checks of the watchdog. Polling of `/api/status` every 10 seconds, only while the tab is visible and the screen is open; on a hidden tab and after leaving the timer is stopped. The page is built with `textContent`, without `innerHTML`.

**Components and logs (slice 18, "choose yourself" decisions):** `POST /api/components/{id}/{start|stop|restart}` and `POST /api/suricata/reload` call `ctl` and answer `{ok, output}`; the format of `id` is checked by the pattern `^[a-z][a-z0-9_-]{0,31}$`, and which components exist is decided by `ctl` (4.1). The exit code of `ctl` is turned into HTTP: 4 and 5 (no such component or it is not installed) are 404 with the text of `ctl`, 2 is 400, 3 is 409, the rest 500, `ctl` did not start is 502. Stopping and restarting `panel` without `?confirm=yes` give 409 with `confirm_required`: the screen asks a second time and repeats the request with `confirm=yes`; the command runs after the answer (202, `detached`), because it kills the panel process itself and an answer after it would never arrive. `GET /api/logs/{id}?lines=N`: `N` from 1 to 1000, 200 by default, otherwise 400 with no `ctl` call. `GET /api/logs/{id}/stream?lines=N` (50 by default) is SSE: the last lines and the new ones. The headers go out after the first line or after 300 ms, so an error like "no such component" stays an ordinary 404, not an event. A comment ping goes every 15 seconds, every record has its own window of 10 seconds instead of the common `WriteTimeout`. No more than four open streams (429 above that): each has its own `sudo` and `journalctl`. When the client leaves, the panel closes the stdin of `ctl` (`--until-stdin-closed`, 4.5), and after 5 seconds without an exit it kills the process. The screens are built from `/api/status`, polling every 10 seconds only on a visible tab, and when the section changes the previous screen stops and closes its stream.

**The config editor (slice 19, "choose yourself" decisions):** the panel takes the names of files from its own list of ten (`dpistack.conf`, `suricata.yaml`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf`, `threshold.config` since slice 40, `ntopng.conf`, `evebox.yaml`, it repeats the list of `ctl`), so a name outside the list, an encoded directory traversal included, gives 404 with no `ctl` call; the last word on a name stays with `ctl`. `GET /api/config` gives this list to the screen. "Check" is `POST /api/config/{name}/check` (`ctl config-write --check`: the verdict and the words of the checker, nothing is written). "Save" is `PUT /api/config/{name}?apply=0`, "Save and apply" is `?apply=1` (another value is 400). A body larger than 1 MiB gives 413 before it reaches `ctl`. The exit code 3 of `ctl` in the editor is 422 with the text of `ctl` and the output of the checker in the field `output`: this is how both a failed check (the file does not change, `ctl` guarantees this) and a refusal of `reconfigure` on a heavy change look. Code 4 (no component) is 409, the rest as in `ctlError`. A write call waits up to three minutes (`suricata -T` loads the whole set of rules), the deadline of writing the answer is extended for the time of the call. A file saved this way counts as hand-edited for the installer (rule 5.4): the panel writes only through `ctl config-write`. The screen asks for a confirmation before "Save and apply" and "Roll back" and does not let you go to another file with unsaved edits without a confirmation.

**Rules in the panel (slice 20, "choose yourself" decisions):** every edit goes through `ctl` (4.5), the panel itself does not touch rule files. The values are checked by patterns that repeat `ctl`, before the call, with a clear phrase (400): a source name `^[A-Za-z0-9._/-]{1,100}$`, an `http(s)://` address from the characters `ctl` allows (`?`, `&`, `%` and quotes in an address are not supported: this is decided by the common list of argument characters), a group `^[A-Za-z0-9._-]{1,100}$`, a `sid` up to 10 digits, a search query up to 100 characters of Latin letters, digits and `. _ : = / @ + , -` and a space; a `sid` and a group outside the pattern are 404. The exit code of `ctl`: 5 is 400, 4 is 409 (no `suricata-update` or no set of rules), 1 is 500 (for the update with the field `output`), the rest as in `ctlError`. The list of sources is assembled from two calls: `list-sources` prints color codes even into a pipe, the panel strips them, and it does not show which sources are enabled, `list-enabled-sources` gives that; an enabled source that is not in the index (one added by address) is marked `custom` and only it can be removed. The groups and the disabled `sid`s the screen reads from `enable.conf` and `disable.conf` through `GET /api/config/{name}`, not through a separate endpoint; it shows the groups and `sid`s written by the commands `rules-group` and `rules-sid` (the lines `group:<name>` and a number), the rest in the files is left as it is. Every edit takes effect at the next update, and the screen reminds about it. "Update now" goes one at a time: a second press while the first runs is 409 and there is no second `ctl`. `ctl` is started apart from the request (`context.WithoutCancel`): if the browser left in the middle, a killed `ctl` would not roll the set back. The deadline of writing the answer is extended to six minutes (`ctl` itself is limited to five), and the screen survives a broken answer (`nginx` cuts a proxy request at 60 seconds by default): after 502, 504 or a network error it polls `GET /api/rules/sources` until `updating` becomes false and shows the result. The time of the last update the panel keeps in memory (`last_update`: the time, the success, the reason, the output): the file of the set is not suitable for it, because `suricata-update` does not rewrite it when there are no changes, and the timer updates past `ctl`. After a restart of the panel the record is lost and the screen says so in words.

**EVE events (slice 21, "choose yourself" decisions):** the package `panel/internal/eve` holds a `Reader` that at every `Poll` reads only what was appended from a saved offset; the file is never parsed whole. The first opening of a large file and catching up after a long idle read no more than 4 MiB from the end, a line cut by such a border is dropped (the reader does not need to be kept in the background: nobody looks, nothing is read, and EveBox answers for the missed as the archive). Rotation: until `Poll` has made sure that the path points to another file (`os.SameFile`), it reads the old file to the end through the still open descriptor, so a file renamed by `logrotate` does not lose its tail; the new file is read from the start. Truncation in place (`copytruncate`, the size is smaller than the offset) reads the file again from the start. An incomplete last line waits for its end in the buffer, a complete but broken line (not JSON, no `event_type`, longer than 64 KiB) is skipped silently. Memory: a ring of 500 per event type and no more than ten types (in the order of appearance), so no more than 5000 events (section 9, "Reading"); the events of the eleventh and further types are not stored. A ring per type, not one common ring, so that a stream of `flow` does not push out the rare `alert`. `GET /api/eve`: `type` `^[a-z0-9_]{1,32}$`, `q` up to 100 characters (a case-insensitive substring in the line of the event, only over what is in memory), `since` in RFC 3339, `limit` from 1 to 500 (50 by default), otherwise 400 before the file is read. Without `-eve-file` the answer is 200 with `available: false` and a reason: an empty list would be read as "no events"; the file not existing yet is `available: true, file_present: false`. No permission to read is 500 with the text of the error. The stream `GET /api/eve/stream` counts both its own cursor over all types and the Poll itself once a second while a client is connected; it takes part in the common limit of open streams (four, like the logs); without `-eve-file` it answers 409. When following, the screen first loads the list, then subscribes, applies the filter by text itself (the stream filters by type only), keeps no more than 500 lines and closes the stream when the section changes.

**Metrics for charts (slice 22, "choose yourself" decisions):** `panel/internal/metrics` holds a ring of 2880 points (24 hours in 30 seconds, never more: both in memory and when loading the file), a point has six values. `pps` and `drops`: packets and drops per second by the last `stats` event (`kernel_packets`, `kernel_drops`), the rate between two events is taken by `stats.uptime`, and without it by `timestamp`; `drops` is the number of drops per second, the share of drops of 4.7 is needed by the checks of slice 24. In NFQ mode (IPS) `pps` is taken from `stats.decoder.pkts`, because the capture counters are zero there. `cpu` and `rss` are of the panel itself (the percent of one core by `getrusage`, the resident memory by `/proc/self/statm`): section 3 lets the panel read only the listed files, and the Suricata process is not in the list. `eve_size` is a `stat` on `eve.json`, `disk` is the share of free space of the partition with `eve.json` (`statfs`). A reset of the counters (a value became lower than before, drops alone included, or `uptime` went back) skips the interval and takes the new event as a base; a tick without a new `stats` event is skipped the same way. A value that does not exist is `null` both in memory and in the answer, not zero: the series `pps` and `drops` are unavailable with `EVE_FILE=no` or while `eve.json` has never had `stats`, the series `eve_size` and `disk` with `EVE_FILE=no`; such a series arrives with `available: false` and a reason, and the screen writes it in words instead of a chart. While there is no `eve.json` file, `eve_size` is a series with gaps. The grids of the answer: `1h` by 30 seconds (120 points), `6h` by 2 minutes (180), `24h` by 8 minutes (180), a bucket is the average of the points that have a value, an empty bucket is `null`; the grid covers `(now-period, now]`. The collector takes a point at once at start and then every 30 seconds independent of the open tabs (otherwise there is nothing to draw for a day); this is the only timer work, and the words "zero CPU at idle" of the budget of section 9 mean no polls and loops, not the absence of this tick. The polling of `eve.json` from the collector reads only what was appended. `metrics.json`: `{version:1, step_seconds, saved, samples:[[time, v0..v5]]}` with `null` in place of an unknown one; at load the points not older than 24 hours, not from the future and in ascending time are kept, a file of another version, an empty or a damaged one gives an empty ring. A snapshot once an hour and on stop (the `SIGTERM` signal waits for the write). Permissions: the directory `/var/lib/dpistack` belongs to root, and the panel must not be given write access to it (there are `state`, `health.json`, copies of configs), so the installer creates an empty `metrics.json` (`0640`, owner `dpistack`) and does not touch an existing one; the panel rewrites the file in place (new content, then truncating the length), not through a temporary file and a rename, so a break in the middle of a write can cost the history but not correctness. The screen polls every 30 seconds and only while the tab is visible and the screen is open.

**The metrics export (slice 23, "choose yourself" decisions):** `panel/internal/export` assembles all the metrics of 4.9 into one text. A metric without data is not printed at all (neither `# TYPE` nor a line): `na` checks and `skip` tests (a `skip` has no `dpistack_test_status`, but has `dpistack_test_timestamp_seconds`, because the run happened), everything of `eve` and `suricata_*` with `EVE_FILE=no` (the panel gets an empty `-eve-file` flag), the Suricata counters and `drop_ratio` while `eve.json` has had no `stats`, `rules_age` without a rules file, everything about tests without `tests-last.json`, a damaged `health.json` or `tests-last.json` is just skipped; all of that gives an empty 200 answer, not an error. `dpistack_component_up` is taken from the checks `<id>.process`: `ok` is 1, `crit` is 0, `na` (the component is not installed) is not printed. `dpistack_suricata_drop_ratio` is the share of drops between the last two `stats` events (`delta drops / delta packets`): when any counter became lower than before (Suricata was restarted), when packets did not grow but drops did, and when there are fewer than two events, there is no metric, not a negative or invented value; the value is no more than 1. `dpistack_eve_events_total` is the events read by the panel since its start, by types, no more than 50 types (`eve.MaxCountTypes`); the panel reads `eve.json` at every taking of metrics, at every tick of the chart collector (the section "Metrics for charts") and with open screens, what is skipped above 4 MiB is not counted, and at a restart of the panel the counter starts from zero (for Prometheus this is an ordinary counter reset). `dpistack_disk_free_ratio{path}` is taken over the directories of the `-disk-paths` flag: the directory of the Suricata log and, with `EVEBOX_DB=sqlite`, the EveBox data (the same list as in the `disk.free` check), and the data of the metrics backend. `dpistack_rules_age_seconds` is the age of the file `suricata.rules` (as in the `rules.age` check). The disk is read no more than once a second (`export.MinInterval`): however many requests come, the text of the last read is served until the second is over, a clock that went back does not freeze the cache. The token is compared through `SHA-256` and `subtle.ConstantTimeCompare` (the time does not depend on the length), without a token or with a wrong one the answer is 401 with `WWW-Authenticate: Bearer`, the address policy of 4.8 applies here too (a foreign address is 403), with `METRICS_EXPORT=no` (there is no token flag) and with an empty token there is no page (404). The token reaches the panel through the file `-metrics-token-file` (`/etc/dpistack/metrics.token`, `0640 root:dpistack`, written atomically with the needed permissions, the content is never passed as a command argument, so it is neither in `ps`, nor in the unit, nor in the journal, nor in `dpistack.conf`); a panel with a given but unreadable or empty file does not start (otherwise `/metrics` could quietly let everyone in). The file is created and removed together with `METRICS_EXPORT` and rewritten on a change of `METRICS_TOKEN`: both keys affect the `panel` step. The final report (section 5, item 8) prints the token and a ready entry `scrape_configs` (`job_name`, `metrics_path`, `scheme`, `authorization` of the type `Bearer`, `targets`) once, when the token has just been created, also after a `reconfigure` that turned the export on; with `--dry-run` nothing is printed (there is no token yet). The address in the entry: the bind address and `<PANEL_PORT>` with `ACCESS_MODE=localhost`, otherwise `<server-address>:<PANEL_PORT>` (the public port of the panel is `PANEL_PORT` in all modes), `scheme: https` with `ACCESS_MODE=nginx` and `NGINX_TLS`. The `# HELP` texts are in English.

**Tests, alerts and interfaces (slice 24, "choose yourself" decisions):** `POST /api/tests/{which}` runs `ctl test <which> --json`; the exit code `1` (some test failed) is not an error but a result: the answer is 200 with an array where the failed one has `status` equal to `fail` and the reason in `detail`; code `1` without a parsable array, and also `2`, `4`, `5` go through the common parsing of `ctl` errors (`opError`). The parsing takes the last line of the output that starts with `[`, so extra lines before the array do not break the answer. `ctl` is started with no binding to the request (`context.WithoutCancel`), like the rules update: a test killed in the middle could leave its rule or traffic; one run at a time (a second is 409), the deadline of the answer is three and a half minutes. `GET /api/tests/last` reads `tests-last.json` by the panel itself (section 3), so the result survives a restart of the panel; the field `running` shows a run in progress. `nginx` cuts a proxy request at 60 seconds by default and `test all` may take longer: the screen, on 502, 504 or a network error, polls `GET /api/tests/last` until `running` is false and shows the result (the same as the Rules screen). Before a run the screen asks for a confirmation, because the HTTPS test goes to the network. `GET /api/alerts` reads not the whole `events.jsonl` but the last megabyte (the file only grows and the fresh ones are needed); the first line cut by the slice and lines that are not an event are skipped, the order of the file is reversed (newest first), `check` is the id of a check `^[a-z0-9_.-]{1,64}$`, `limit` from 1 to 500, otherwise 400; the list `checks` for the menu is built from what was read and is not narrowed by the filter; no file is `file_present: false` and an empty list. Interfaces: there is no separate screen in the list of section 9, so the block "Capture interfaces" is on the Components screen (this is what Suricata listens to). `GET /api/iface` takes the list from `ctl iface list`, and the answer to an addition and a removal already carries the new list; the name is checked by the pattern `^[A-Za-z0-9._-]{1,15}$` (as in `ctl`) before the call, the codes of `ctl`: `5` (no such interface in the system or in `IFACES`) is 400, `3` (the last interface) is 409, `1` (`reconfigure` failed, `dpistack.conf` restored) is 500 with the text; the change goes apart from the request, one at a time (a second is 409: `reconfigure` restarts Suricata and two changes in a row would race for `dpistack.conf`). The screen asks for a confirmation (Suricata will restart), the "Remove" button of the only interface is blocked and stays blocked after a request (the server would refuse anyway), after a change the list is redrawn with the answer of the server, and the status of the components is updated by the ordinary polling of the screen (every 10 seconds).

**The Settings screen and the settings verbs (v0.22.0):** the screen is built from the schema that the program itself serves (`dpistack settings list --json`), so it shows exactly the keys the installed version knows. The groups are `capture`, `components`, `eve`, `rules`, `access`, `metrics`, `watch`, `tests`; the hints are in `panel/web/modules/settings-model.js` (a test compares them with the schema). "Check" (`POST /api/settings/check`) writes nothing and returns the errors by key, the weight of the change (light or heavy) and the busy ports with the nearest free one; "Apply" (`POST /api/settings/apply`) checks, writes and applies, a heavy change starts a separate job `dpistack-apply` whose progress `GET /api/settings/job` returns; widening the access (`ACCESS_MODE` other than `localhost`, or a non-loopback `BIND_ADDR`) needs `confirm_access`. Secrets are never returned: only `set`/`not set`; `PUT /api/settings/secret/{key}` takes a new value (an empty one removes it) and the value goes through stdin, not through the arguments.

**Settings v2 (v0.45.0, 18.44):** the same screen in three columns: the categories (the groups above, with the number of keys shown and of keys edited) with a search and the switch "Show advanced settings"; the keys of the chosen category, or the search results (the search matches a key name, a description or a group title and says how many advanced matches it hides); and the details of the key in focus (what it does, the allowed values, the default, the saved value, what it depends on and whether that holds now, light or heavy, what it touches), the **staged change** (every edited key as old to new with its weight, the sum of what it touches) and the **profiles**. A key whose `depends` do not hold with the values as they are on the screen is dimmed and says why, and this follows each edit at once. **Apply opens only after a check of exactly the staged values has passed**: any later edit, even back to the same value, closes it again. A profile is loaded into the staged change, never applied by itself; "Save staged changes" saves the edited keys and "Save all values" every non secret key as it is on the screen (this includes keys that belong to one machine, such as `IFACES`).

**Security (v0.46.0, 18.45):** a screen in the Admin group with four parts. The **security check** (for `audit.view`): six items, each with a level, what was found and a line "To fix: ...". **Your sessions**: where each was opened from (the address and the client, as the panel saw them at sign in), when, when it expires, "this one" on the session you are in, a button to end one and one to end all your others; with `users.manage` also **Sign everyone out**, which asks first. There is no session key to rotate, and the page says so: a session is a random token in the memory of the panel. **API tokens**: yours (everyone's with `users.manage`), when each expires and when it was last used since the panel started, a button to revoke, and a form (name, scope, days) that shows the secret once, in a box that is cleared by "I have copied it" and when the screen is left. **Sign in history**: your own sign ins and failed attempts (everyone's with `audit.view`). The lists refresh every 30 seconds; the check runs only when asked.

**Start (the decision of slice 16, "choose yourself"):** the panel reads its settings from flags that the unit of slice 17 passes (the panel does not look into `dpistack.conf` itself, `LAN_CIDR=auto` has been resolved by the installer by then): `-addr` (`127.0.0.1:9800` by default), `-access` (`localhost`, `lan`, `nginx`), `-lan-cidr` (address/length, required for `lan`), `-auth-file`, `-health-file`, `-ctl`, `-tests-file` and `-events-file` (the paths to `tests-last.json` and `events.jsonl`, the unit always passes them), `-metrics-token-file` (the file with the `/metrics` token; empty means there is no `/metrics`, the unit passes the flag only with `METRICS_EXPORT=yes`), `-rules-file`, `-disk-paths` (a list of directories separated by commas; the unit passes the last two together with the token), `-metrics-file` (the path to `metrics.json`; empty means the history is in memory only, the unit always passes it), `-eve-file` (the path to `eve.json`; empty means the event view is off, the unit passes the flag only with `EVE_FILE=yes`), `-sudo` (on by default), `-lite` (the lite edition: the stylesheet and the script that are served). With `localhost` and `nginx` the bind address must be loopback, otherwise the panel does not start. There is no flag that turns the sign-in off.

**Addresses and sign-in (slice 16):** the client IP is the address of the connection; `X-Forwarded-For` is read only if the connection came from loopback, and the last entry is taken (it was appended by `nginx`). A broken header from a trusted proxy gives 403. Admission: `localhost` only loopback; `lan` only addresses from `-lan-cidr` (loopback is not included); `nginx` a connection from loopback and, if `-lan-cidr` is set, a client from it. A sign-in attempt is counted before the password is checked, so a batch of parallel guesses does not bypass the limit; a successful sign-in resets the counter. The session is kept in memory (a restart of the panel signs everyone out). CSRF: at sign-in the cookies `dpistack_session` (`HttpOnly`) and `dpistack_csrf` (readable by the script) are set, both `SameSite=Strict`, `Secure` with HTTPS; the script repeats the value in `X-CSRF-Token`, the server compares it with the token of the session, not with the cookie. The sign-in accepts only `application/json`. The hash check goes one at a time, a hash with memory above 32 MiB is refused.

**Behavior:**

- Reading `eve.json` is incremental from a saved offset. A ring of no more than 5000 events in memory. The file is never parsed whole.
- Metrics for charts: a ring of 24 hours with a step of 30 seconds, a snapshot into `metrics.json` once an hour and on stop. `GET /metrics` is built from the same data and does not read the disk more often than once a second.
- The `status` polling is no more often than once in 10 seconds and only while the tab is visible. SSE is opened only on the logs and events screens and is closed when you leave the screen.
- Authentication: one administrator, argon2id, a limit of sign-in attempts (5 per 5 minutes per IP), a session of 12 hours. The sign-in cannot be turned off.

**The interface:** a single page, a hash router. The screens: Overview, Network, Traffic, Components, IPS, Settings, Configs, Rules, Logs, Events, Metrics, Tests, Alerts. The `full` edition is dark; `lite` follows `prefers-color-scheme`; adaptive layout. The charts are drawn by an own function on inline SVG. The static files are served with gzip. The config editor is a plain `<textarea>` with a monospace font, the buttons "Check", "Save", "Save and apply", "Roll back". Dangerous actions (stopping a component, switching to IPS) ask for a confirmation. No external fonts, scripts or images (the fonts and the icons are inside the binary) and no inline scripts or styles (the CSP policy); `textContent` instead of `innerHTML`.

---

## 10. Check tests (`dpistack test`)

The result: `{"name","status","detail","duration_ms"}`, `status` is `pass`, `fail`, `skip`. The outcome is written to `tests-last.json`. The exit code: `0` all `pass` or `skip`, `1` there is a `fail`.

**`bittorrent`** (offline, does not touch live traffic by default):

1. It runs `suricata -r tests/data/bittorrent.pcap -l <tmp>` with the config of `suricata-test.yaml.tpl`. The config connects the same rules and plugins, writes `alert` and `netflow` into a temporary directory and does not touch the main `eve.json`.
2. `pass` if the temporary `eve.json` has an `alert` with a signature that contains `BitTorrent`. With the nDPI plugin loaded the test adds its own rule to the set: `alert tcp any any -> any any (msg:"dpistack test nDPI BitTorrent"; requires: keyword ndpi-protocol; ndpi-protocol:BitTorrent; sid:9000001;)`, so the plugin is checked even without the `emerging-p2p` group (A2: there are no separate nDPI fields in EVE).
3. `skip` with a reason if there are neither the rules of the `emerging-p2p` group nor the nDPI plugin. The message says what exactly to turn on.
4. `TEST_BT_LIVE=yes` additionally sends the same pcap through `tcpreplay` into the first interface of `IFACES` and looks for an event in the main `eve.json`. Off by default: spoofing traffic on a live interface is noisy. The live Suricata gets its own rule for this (`dpistack-test.rules`, listed in `suricata.yaml` only while the key is `yes`, sid 9000100, `alert tcp any any -> any any` on the handshake `|13|BitTorrent protocol`): the Emerging Threats rules are written for a `$HOME_NET` to `$EXTERNAL_NET` direction and the pcap has private addresses on both ends, so they never match it live (18.52). The same rule alerts on a real BitTorrent client on the network, which is detection, not noise.

The origin of the pcap: recorded once in slice 0. A BitTorrent client with a legal torrent in an isolated network, `tcpdump` of the first packets of the handshake, the addresses are replaced with documentation ones (`192.0.2.0/24`) through `tcprewrite`. The way of recording and the check on a real ET signature are described in `tests/data/README.md`.

**`https`** (live):

1. It runs `curl -sS -o /dev/null "$TEST_HTTPS_URL"`. The mark of the event is the SNI, that is, the host of the URL.
2. It waits up to 20 seconds for a `tls` event in the main `eve.json` with `tls.sni` equal to the host of the URL.
3. There is no nDPI `TLS` line in `detail`: there are no nDPI fields in EVE (A2).
4. No `eve.json`: `fail` at once, without waiting. `curl` runs with `--max-time 15`, so that a network with no answer does not hang the request of the panel. `fail` if the event did not appear: `detail` names the reason (`curl` failed, no events, the capture interface is not the one `curl` uses, otherwise the packets are not seen).

The result of each test is written into `tests-last.json` (4.6). `--json` prints an array of objects `{"name","status","detail","duration_ms"}`.

**`all`** runs both in turn. `verify` in the installer runs `all` with `TEST_ON_INSTALL=yes`, a failed test does not cancel the install and goes into the final report.

---

## 11. Project tests

The tests are derived from the acceptance criteria of a slice, not from the finished code. The criteria are written in the entry of the slice in section 18 before the code.

- Bash: `bats`. External commands (`apt-get`, `dnf`, `systemctl`, `suricata`, `curl`, `ss`, `docker`, `ip`) are replaced by stubs from `tests/mocks/` through `PATH`. Paths are redirected into `mktemp -d` through `DPISTACK_ROOT`. The other environment variables needed by the tests only: `DPISTACK_INPUT` (the menu input from a file), `DPISTACK_TEST_WAIT` (seconds to wait for an event instead of 20), `DPISTACK_NOW` (the time of the watchdog in epoch seconds), `DPISTACK_MENU_ASSUME_YES=1` (the menu answers yes to its confirmations and does not offer the guided setup; the older menu tests drive the screens with fixed lines, `tests/menu_confirm.bats` runs without it), `DPISTACK_VERBS_ONLY=1` (every argument is a verb; the helper `tests/helpers/verbs`), `DPISTACK_BIN` (another program that answers the verbs in the menu and the watchdog), `MOCK_IP_ADDRS` (`iface=address/prefix` pairs the `ip` stub reports for `ip -o -4 addr`).
- Go: `go test`, the HTTP handlers through `httptest`, the call of `dpistack` is replaced by the interface `ctl.Runner`. A test of the choice of the stylesheet and script by the edition (`edition_test.go`).
- The interface: `node --test` for the pure logic (the countdown of the mode screen, polling, the settings model).
- A forbidden kind of test: "ran a step, checked that 0 came back". A test checks the result: the content of a file, the commands called, a refusal.
- For every slice at least: a test for every criterion with a checkable condition, a test of the error path (a wrong key, a missing component, a failed validation), a test of idempotence for the slices of the installer. A negative test must really fail when the code it guards is removed.
- The integration on a real OS is checked by hand against the criteria of the slice and is not automated in bats.
- **The platform matrix (required acceptance, v11, updated in v12).** A release and every fix of a platform are confirmed by a run on a stand: Ubuntu 22.04 and 24.04, Debian 12 and 13, Rocky Linux or AlmaLinux 8, 9 and 10. On every platform these pass: `install -y` with the defaults (a build from source or a package if Rust 1.75 is unavailable), `install -y --set SURICATA_SOURCE=distro`, on Ubuntu and the RHEL clones also `oisf`, a repeated `install` with no changes, `reconfigure`, `upgrade`, `uninstall --purge`, then `dpistack test all`. The development environment checks only Ubuntu 24.04 (without systemd, with a stubbed `systemctl`); the rest is confirmed by the owner, and the result comes as the output of `install.sh diag` (4.4), by which fixes are made. The results are recorded in section 18.
- `tests/bundle.bats` (v28, slice 30): `bash -n` and `shellcheck` of the built file, `--check` (fresh, stale, no file), repeatability of the build, a refusal on a heredoc terminator and on a file without a final line break, the same `--help` and `install --dry-run -y` output, the same exit code, the same installer copy after a real install (`diff -r`, the whole pcap), removal of the temporary directory, finding the panel next to the file, a run from a pipe; the old second command name is absent.
- `tests/ips.bats` (v27, slice 29): `mode ips`, NFQUEUE with `--queue-bypass`, the rollback by the timer, `mode-confirm`, other people's chains (a comparison of `iptables-save`), `dpistack-fw.service`, `fw restore`, af-packet in pairs, `uninstall`. Stubs with state `iptables`, `ip6tables`, `iptables-save`, `ip6tables-save` (the file of rules from `MOCK_IPT_STATE`), the stub `systemd-run`, the clock of the tests through `DPISTACK_NOW_CMD`.
- `tests/ips_page.bats` (v72, slice 42): `ips status` (ids mode, the drop rules counted per file, ips mode with and without a listener on the queue, afpacket, a pending switch, counters from the newest stats event, blocked events newest first and limited to 20, text output), `ips test` (all drop rules in simulated IPS mode, named sids in every state, a rule of `local.rules`, the main `eve.json` untouched, every refused argument, a container Suricata, an engine failure, no audit line, with a control that an audited verb does write to the file being checked), a cut line in `eve.json` (R222). Suricata is a stub that writes the alerts a real offline run would write; `panel/internal/api/ips_test.go` (6) and `panel/web/test/ips.test.mjs` (12) cover the route and the screen.
- `tests/alerts.bats` (v73, slice 43): `alerts list` (nothing wrong, watchdog checks as alerts and only warn or crit, Suricata alerts grouped by rule with severity, count and times, a broken line in `eve.json`, filters and bad filters, the plain text), every state (acknowledged with who and why, snoozed until the second and new again at it, the four durations and nothing else, resolved until a newer event or status change, an acknowledged alert that cleared, reopen), refused input (an unknown alert, a bad key, note, name, argument, `--for` on a non-snooze), `alerts history` (actions and status changes merged, newest first, limits), keeping 500 history entries and dropping old resolved decisions, a damaged state file, two actions at once, audit of changes and not of reading. Time is fixed with `DPISTACK_NOW_CMD`. `panel/internal/api/alertcenter_test.go` (8, and the five new routes in the permission table of `users_test.go`) and `panel/web/test/alertcenter.test.mjs` (17) cover the routes, the screen and the bell.
- `tests/settings_v2.bats` (v74, slice 44): the metadata of `settings list --json` (`steps`, `touches`, `depends` of sample keys, every step has a label, every dependency names a real key and a real enum value), **the table of dependencies against `menu_key_skipped` over every value of every switch alone and in pairs** (checked by breaking a rule on purpose), and the profiles (save, list, show, stdin values, replacing a name, the refusals of `settings check` and of secrets, duplicate keys and bad pairs, names, the limits of 50 and 100, delete, apply as a light change, a heavy one needing its flag and a wider access needing its confirmation, audit, two saves at once, a damaged file). `panel/internal/api/profiles_test.go` (6, and the four routes in the permission table of `users_test.go`) and `panel/web/test/settings2.test.mjs` (22: search, categories, the rules, the words, the staged change, the signature, profiles, and the screen: dimming and un-dimming, details, Apply closed until a passing check, a failed check or a busy port, a heavy change, search, loading, saving and deleting a profile, refusals) cover the routes and the screen. The rules were also compared by hand once between the JavaScript and the shell on the real JSON of a fresh install, 12 scenarios over every key.
- `tests/panel_security.bats` (v75, slice 45, 20): `tokens create` (the secret on stdout and **nowhere on disk**, checked by searching the whole tree for it; the hash in the file; mode 0640; every scope against an owner that holds less or more, a custom account; refused names, scopes, days including `08`, missing or disabled accounts; the limits of 10 and 100; list without the hash, filtered, with the expired flag; revoke by owner; audit of making and revoking and not of listing; two at once; a damaged file) and `security check` (the six items and their fixes, localhost, lan, nginx with and without TLS, default ports only for components that are on and only when the network can reach them, accounts without a recent sign in from the audit log including a rotated file and failed attempts and new and disabled accounts, no audit log, rule files and secret files with the modes that are and are not allowed, that it only reads). `panel/internal/auth/security_test.go` (sessions with handles, metadata, revocation, expiry; the limiter's look without counting; token lookup, expiry, a damaged file; a token never holding more than its owner) and `panel/internal/api/security_test.go` (a token acting as its owner, a read token refused every write, a role token holding the role, expired, unknown, disabled-owner and malformed tokens, a header never falling back to a cookie, only wrong tokens counted, the audit name, tokens and sessions not manageable with a token, the sessions routes, the token routes with their checks and the secret never in the audit, the sign in history and its permissions, the check) cover the panel. The four guards that matter (a read token cannot write, nobody revokes another user's token, a token cannot manage tokens, a token never holds more than its owner) were each broken on purpose to see a test fail. `panel/web/test/security.test.mjs` (16) covers the screen.
- `tests/suricata_logs.bats` (v30, R144-R146): logrotate without `create 0640 root root`, reopening the logs through the socket that Suricata creates, the socket path in docker, the `suricata` group and the log directory. Stubs `groupadd`, `chgrp`, `getent` with `MOCK_GETENT_MISSING`.
- `tests/firewall_rules.bats` (v30, R150-R151): the `ufw` and `firewalld` rules are removed on a change of the mode, `LAN_CIDR`, `FIREWALL_MANAGE` and `uninstall`, another person's rule stays, a repeat duplicates nothing, `uninstall` restarts Suricata from NFQ. The stubs `ufw` and `firewall-cmd` keep the rules in `$MOCK_CALLS_LOG.ufw` and `.fwd`; the stub `nft` keeps the table `inet dpistack`.
- `tests/metrics_step.bats` (v26, slice 28): the retention and the bind address in the unit and in the docker parameters, the token in the file only, the sha256 check on a fake archive, a repeat with no changes, a change of the backend, `none`, `uninstall` and `--purge`, the docker variant. The stub `curl` returns a file (`MOCK_CURL_BODY_FILE`); to replace the sums and the architecture there are `DPISTACK_METRICS_SHA256_<VM|PROM>_<AMD64|ARM64>` and `DPISTACK_METRICS_ARCH`.
- `tests/monitoring_step.bats` (v0.24.0): node_exporter and Grafana separately and together, with and without a backend (the `node` job in `scrape.yaml`, the default data source), the sha256 checks on fake archives (`DPISTACK_NODEEXP_SHA256_<ARCH>`, `DPISTACK_GRAFANA_SHA256`), docker, turning a part off, `BIND_ADDR`, `uninstall`.
- `tests/access_step.bats`: the access modes and `BIND_ADDR` (the listen address of ntopng, EveBox and the panel, the panel policy, the confirmation, the check that the address belongs to the host, `nginx` ignoring it).
- `tests/runtime_docker.bats` (v25, slice 27): a mixed scheme, a repeat with no changes, the path of `eve.json`, Suricata in docker, `preflight` (code 3), `DOCKER-USER` and `iptables` are not touched, `status`, `start|stop|restart`, `logs`, `reload`, the config check in the container. The stub `docker` (`MOCK_DOCKER_PS`, `MOCK_DOCKER_RUNNING`, `MOCK_DOCKER_IMAGE`, `MOCK_DOCKER_COMPOSE_EXIT`), the stubs `iptables`, `ip6tables`, `nft`.
- `tests/selinux.bats` (v24, slice 26): SELinux labels and ports, `firewalld` only for `LAN_CIDR`, a stopped `firewalld`; `tests/pkg_dnf.bats` (v24): `versionlock`, the package version as `package-version`, the COPR chroot by OS and code 3 in `preflight`. All on stubs (`getenforce`, `semanage`, `restorecon`, `firewall-cmd`, `curl`).
- `tests/families.bats` (v10): the package manager families (apt, dnf), fall backs between a package and a build, interface detection, pinned references. The dnf paths go through the stubs `dnf`, `rpm`, `firewall-cmd`, `setsebool`.
- `tests/docs.bats`: the generated references are current, every key of the example is documented, the README and the guides come in English and Russian and link to their twins, local links work, the documents carry no remark that the software was not tried.

---

## 12. Checks and the gate

`scripts/gate.sh`:

```
shfmt -d install.sh lib bin scripts tests
shellcheck -x -S style install.sh lib/*.sh bin/dpistack-watch scripts/*.sh
scripts/security.sh
scripts/bundle.sh --check        (the single file matches the sources)
scripts/check-conf-example.sh    (keys and defaults of dpistack.conf.example against 4.3 and lib/schema.sh)
scripts/gen-config-doc.sh --check  (docs/configuration.md and docs/configuration.ru.md match the schema)
bats tests
# when panel/ is there:
gofmt -l panel        (empty output)
go vet ./...          (in panel/)
go test ./...         (in panel/)
node --test panel/web/test/*.test.mjs
```

`gate.sh` red means the slice is not closed. Fixes for the gate are made in the same session.

### 12.1 CI/CD (`.github/`)

- `ci.yml` on every push to `main` and `dev` and on every pull request: `scripts/gate.sh` on `ubuntu-24.04` only (D110; `ubuntu-22.04` and `ubuntu-24.04` before v0.45.0, `ubuntu-22.04` alone in v0.45.0, D109), plus `actionlint` for the workflows themselves. Rights `contents: read`, stale runs of the same branch are cancelled.
- `security.yml` on push, pull request and once a week: `gitleaks` over the whole history (a token that got into an old commit stays in it); it runs as a ready binary of version 8.30.1 from the release with a SHA-256 check (`gitleaks/gitleaks-action` failed on every pull request from Dependabot with no findings and needs a license for organizations); `dependabot` does not update the version and the sum, they are changed together by hand; `scripts/security.sh`, `shellcheck -S style`, `trivy fs` (secrets and configuration errors, HIGH and CRITICAL) with SARIF sent to code scanning. A finding that is not a secret (an invented token in a test) does not turn the rule off: the fingerprint of that one finding goes into `.gitleaksignore` with a reason above the line, and the file in the tree no longer contains the literal; the first such case is the test `/metrics` token of slice 23 (the commit `76a0b94` stayed in the history, the history was not rewritten).
- `release.yml` by the tag `vX.Y.Z`: the same `gate.sh`, then a check that the tag equals `DPISTACK_VERSION` in `lib/common.sh`, building `dpistack-X.Y.Z.tar.gz` (`install.sh`, `lib`, `templates`, `bin`, `panel`, `tests/data` and the ready panel binaries `dpistack-panel-linux-amd64` and `dpistack-panel-linux-arm64` built with `CGO_ENABLED=0` in the `publish` job through the pinned `actions/setup-go`), the `.sha256` file, an attestation of the origin (`actions/attest-build-provenance`) and publishing the release. Only the `publish` job has write rights.
- `dependabot.yml` updates the versions of GitHub Actions once a week.
- The rules for workflows, checked by `tests/ci_config.bats`: every one has an explicit `permissions` block, no `pull_request_target`, no text of an event (`head_ref`, issue titles and comments) in `run:`, every third-party action is pinned by a version, the version of the program in `tech.md` equals the version in the code.
- The review (v7) added: all actions are pinned by the full SHA of a commit with a version comment (`dependabot` updates them), `actionlint` runs as a ready image, not as a script piped into `bash`; `trivy-action` v0.36.0 (v0.28.0 pulled a removed `setup-trivy@v0.2.1` and the job failed at preparation); a release is published only if the tag is on `main`; uploading SARIF is skipped for a pull request from a fork (its token is read-only). `tests/ci_config.bats` checks the pinning by SHA, the absence of `curl | sh`, the check of the tag and the presence of the files that `release.yml` copies. The first runs on GitHub were red from the first commit for two reasons, both found only there: (1) the `preflight` of the installer requires root, and the steps of the runner run as an ordinary user, so every test with an install failed; the gate on the runner now runs as `sudo -E env "PATH=$PATH" bash scripts/gate.sh`; (2) `trivy-action` v0.28.0 pulled the nested action `setup-trivy@v0.2.1`, which no longer exists, and the job failed at preparation; now v0.36.0, whose nested actions are pinned by SHA. Checked locally on the tool versions of Ubuntu 22.04 (`shfmt` 3.4.3, `shellcheck` 0.8.0, `bats` 1.2.1). The logs of the runs from the development environment are unavailable, so the reasons were confirmed by reproduction, not by reading a log. So that a red gate does not have to be sorted out blindly, the step `Report failing checks` in `ci.yml` publishes the names of the first six failed checks as a commit status with the context `gate <OS> #N` (the right `statuses: write` is only in that job). Two more defects found there: a test looked for `uses: ` as a substring and took `statuses: write` for an action (now the parsing is tied to the start of the line), and the stub of `journalctl` in a test did not stop on an ignored `SIGPIPE`, as on the runners of GitHub.

### 12.4 The automatic check of Suricata releases (v12)

`SURICATA_STABLE_REF` (5.1) is not raised blindly and is not forgotten. The workflow `.github/workflows/suricata-watch.yml` runs `scripts/suricata-watch.sh` once a week (Monday, 05:17 UTC) and on a button:

1. the pinned release is built by the same installer (`scripts/suricata-build-check.sh`: the steps `ndpi` and `suricata`, then the version, the nDPI support, the plugin in `/usr/lib/suricata` and `suricata -T` on the rendered configuration); if it stopped building (a new runner image, Rust, nDPI), an issue is opened and the run is red;
2. `scripts/check-suricata-release.sh` compares the pinned tag with the tags of `OISF/suricata`: only the final releases `suricata-X.Y.Z` count (candidates, betas and dev tags do not), the comparison is numeric; a newer release of the same series is built too, and the result goes into an issue: "verified: raise SURICATA_STABLE_REF" or "failed the build check";
3. a stable series newer than the pinned one (for example 9.0) is announced by a separate issue once: moving to a series needs a decision, because `SURICATA_COPR` and the PPA are tied to the series.

The scripts change nothing in the repository: the rights of the workflow are `contents: read` and `issues: write`, there are no repeated issues (one open per title). Raising the tag is an ordinary change through `dev`, the gate and a PR to `main`. Tests: `tests/release_watch.bats` (tags, rc and betas, numeric order, all the issue scenarios on the stubs `gh` and of the build). nDPI is pinned by a release (`NDPI_COMPAT_REF`, 4.14, the plugin builds only with 4.12 and 4.14) and is checked by the same build.

Docker images (the slices of the `docker` runtime): only pinned stable version tags, not `latest`, `master`, `nightly` and `dev`.

### 12.3 Branches and merging

The `gate` jobs of `ci.yml` may run 45 minutes (30 until v0.45.0; D103). The `main` branch is protected on GitHub (a "choose yourself" decision, v8): the checks `gate (ubuntu-24.04)`, `lint workflows`, `gitleaks`, `shell security checks`, `trivy (config and secrets)` are required; changes go only through a pull request (0 approvals, the project has one owner); the protection applies to the administrator too; force-push and deleting `main` are forbidden; discussions in a PR must be closed. Being up to date with `main` is not required (`strict` is off), otherwise `main` would have to be pulled after every merge of `dev`. A direct push to `main` is impossible, so merging goes by the button "Create a merge commit" in the PR `dev` -> `main`. Do not delete the `dev` branch: "Automatically delete head branches" in the repository settings is off.

Work goes in the `dev` branch, the `main` branch holds only the tested state:

1. Every slice or fix is committed to `dev` and pushed.
2. The commit must pass the checks: locally `scripts/gate.sh` (`shfmt`, `shellcheck`, `scripts/security.sh`, `scripts/check-conf-example.sh`, `bats`), on GitHub the workflows `ci` and `security` for that commit.
3. While at least one check is red or not finished, nothing is merged into `main`.
4. When everything is green, a PR `dev` -> `main` is opened and merged with a merge commit (not squash, not rebase) with a message like `merge dev into main: <what went in>`; there are no direct commits to `main`.
5. Every merge into `main` is a new version, with no exception (owner's rule, v0.33.0): the PR raises `DPISTACK_VERSION` in `lib/common.sh` and the program version at the top of this file (and the program changelog, which keeps five entries), and right after the merge the tag `vX.Y.Z` and the GitHub release `vX.Y.Z` are made on the merge commit. A merge that does not change the version is not made; a version that was merged is never reused. The tag must be on `main` (12.1: a tag not on `main` is not published) and must equal `DPISTACK_VERSION` of the tagged commit. Since v0.26.0 the release is also what the panel's update check reads (`releases/latest`): a version without a published release (not a draft, not a pre-release) is never offered as an update. Releases and tags exist for every version (v0.2.0-v0.25.2 were added afterwards at the last commit of each version and marked "not latest").

If a merge gives a conflict, it is resolved in `dev`, after which the checks pass again.

6. Authorship (owner's rule, v0.32.0): every commit, in `dev` and in `main`, is authored and committed by the owner, `FlexEbat <52438328+FlexEbat@users.noreply.github.com>`. No other author, no `Co-authored-by` trailer, no tool or assistant named in the message. Set it before the first commit (`git config user.name FlexEbat`, `git config user.email 52438328+FlexEbat@users.noreply.github.com`); a commit made under another name is fixed with `git commit --amend --reset-author` before it is merged.
7. A one-off exception to rule 3 needs the owner's explicit word in that session (v0.32.0 was merged on the owner's word that the checks had passed, before the run finished); the exception is not a standing rule.

### 12.2 Security checks (`scripts/security.sh`)

A cheap local check with no network, the same in the gate and in CI. A red result closes a slice the same way as a red `shellcheck`. It checks:

1. secrets in tracked files (GitHub tokens, AWS keys, private keys, Slack and Telegram tokens); with `gitleaks` present it runs that too;
2. `eval` and `bash -c` / `sh -c` over an assembled string in the code (lines that only print the `ExecStart=` of a unit are excluded);
3. `curl | sh` and `wget | sh`;
4. `chmod` with a write right for the group and others;
5. fixed paths in `/tmp`, `mktemp -u` and temporary names through `$$`: a temporary thing is created only through `mktemp` in a private directory;
6. `set -u` in every entry point;
7. CRLF line endings;
8. secrets in the arguments of `curl`: tokens and passwords are passed through `-K -` on stdin, so that they are not in `ps`.

What is already accounted for in the code and checked by tests: the Telegram token and the SMTP password get neither into the journal, nor into `events.jsonl`, nor into `--dry-run` (`tests/alerts.bats`); `sudo` allows the user `dpistack` only `dpistack`, and its arguments are checked against lists (`tests/ctl_basic.bats`, `tests/ctl_config.bats`); `sudoers` is checked with `visudo` before it is written; `panel.auth` keeps argon2id with permissions 0640; `config-write` does not update the render hash, so an edit from the panel is not overwritten by the installer. The `suricata -T` checks go in a private temporary directory, not in `/tmp`. The installer lock takes a free descriptor through `exec {fd}>`, with no `eval`.

Tests of the checks themselves: `tests/security.bats` puts every violation into a temporary repository and requires a red result, while a clean tree and repository pass.

- `shfmt` catches formatting;
- `shellcheck` catches quoting errors, unused variables, unsafe constructions;
- `bats` and `go test` catch the acceptance criteria.

Slice 0 (the prototype) and slice 25 (the README) do not touch the gate, except the check of links in 25.

---

## 13. The convention of text

**Language (v0.23.0).** The program is English only: messages, the menu, errors, the panel text, comments, commits, log records and the names in the API and the metrics. The README and the guides in `docs/` are written in English first and kept in Russian next to them (`X.md` and `X.ru.md`, each linking to its twin); both are changed together, and `tests/docs.bats` checks it. This file, `AGENTS.md`, `CONTRIBUTING.md` and `SECURITY.md` are English only. The generated references (`docs/configuration.md` and `docs/configuration.ru.md`) come from `scripts/gen-config-doc.sh` (the English hints live in `panel/web/modules/settings-model.js`, the Russian ones in `scripts/config-hints.ru`). There is no i18n layer in the program. (Before v0.23.0 everything a human sees was in Russian; the old Russian texts of the log below are translated.)

Commits, Conventional Commits, a fixed format:

```
type(scope): summary
```

- `type` from the set `feat|fix|test|refactor|chore|docs`;
- `scope` from the set `installer|ctl|watch|panel|rules|suricata|ndpi|ntopng|evebox|metrics|access|tests|docs`;
- `summary` in the imperative, lowercase, no period, up to 50 characters;
- a body only to explain *why*, not *what*;
- commit as you go in small steps. Every commit passes `gate.sh` where possible.

Examples: `feat(installer): add idempotent suricata step`, `test(watch): cover drop rate counter reset`.

Rules of writing for all the prose of the project (commits, comments, README): the active voice, specifics instead of general phrases, no introductory turns, no long dash, no intensifying adverbs. A comment explains the reason for a decision, not retells the next line. Do not leave commented-out code. Before writing a README look at [https://docs.github.com/en](https://docs.github.com/en), [https://github.com/matiassingers/awesome-readme](https://github.com/matiassingers/awesome-readme), [https://www.makeareadme.com/](https://www.makeareadme.com/).

Other conventions: decisions marked "choose yourself" are taken by the developer and recorded in this file; when a contract is missing, stop and ask the owner (section 15); prefer ready-made solutions (packages, images, tools) to writing code from scratch; tests, CI/CD and security checks are part of the project (sections 11 and 12); the git workflow of this repository is: commit to `dev`, wait for the tests, and only if everything is green merge `dev` into `main` (12.3); the version of the program in `lib/common.sh` and in this file change together; a token given for GitHub access is used for the session only and is never written into the repository, the remote URL or a memory file.

---

## 14. Definition of Done of one slice

1. The acceptance criteria of the slice from its entry in section 18 are met and checked by hand on a clean OS (stages 1-4: Ubuntu LTS; slices 26-28: the environment named there).
2. The tests are written from the criteria, `scripts/gate.sh` is green.
3. For the slices of the installer: the second run gives `no changes`, `--dry-run` changes nothing (checked by comparing the state of the system before and after).
4. There are no new files and abstractions beyond section 3.
5. There is no dead code: no unused functions, templates, schema keys, JS modules.
6. Commits by the convention of section 13.
7. `tech.md` is not changed (a change of a contract goes separately, through section 15). In practice the owner allows the developer to update this file for the decisions of a slice and to record them in the log.

---

## 15. CONTRACT GAP

A config key, a `dpistack` verb, a metric, an EVE field or an endpoint is missing: work stops. Give the block and wait for an answer:

```
CONTRACT GAP
What is needed: <key/command/metric/field/endpoint>
Why: <which acceptance criterion is not met without it>
Proposed form: <the exact name, type, defaults>
What I do meanwhile: <a local stub in my slice / wait>
```

Do not write code with an invented contract. Do not extend the key schema, the list of verbs of `dpistack`, the format of `health.json`, the list of metrics, the HTTP API on your own.

---

## 16. Rules of behavior in a session

- Think before code: name the assumptions, ask on ambiguity, show options instead of a silent choice.
- Simplicity: no features beyond what was asked, no abstractions for one-off code, no handling of errors that cannot happen.
- Surgical edits: do not improve or refactor neighboring working code. Every changed line follows from the current task.
- One slice per session. Do not roll out everything at once.
- Run commands that change the system (`apt`, `dnf`, `iptables`, `systemctl`) only on a test machine or in `--dry-run`. Never change network rules or switch IPS on a host where the work goes over SSH without a rollback timer.
- The review goes in a second pass, after the slice is ready, not in the same message in which the code was written.

---

## 17. Assumptions that need checking (not frozen)

The slices are not listed here: the index of slices, with what is done and what remains, is 18.0, and every slice has its own entry in section 18 in the style of 18.20. This section keeps only the assumptions.

| # | assumption | confirmed in slice |
| --- | --- | --- |
| A1 | The name of the bundle `dpistack` and all the derived paths of 4.2 | agreed by the owner before slice 1 |
| A2 | Closed (v5): there are no separate `ndpi.*` fields in EVE, nDPI is visible through `alert.signature` and `alert.metadata` (4.7) | closed |
| A3 | The `distro` and `oisf` packages may not contain `ndpi.so` | 0, 4 |
| A4 | The way to set the ntopng administrator password at install; until it is found, ntopng listens on `127.0.0.1` only and the installer prints a warning | 0, 5 |
| A5 | A full render of `suricata.yaml` instead of `include` additions (lists in `include` may be replaced, not merged) | 0, 2 |
| A6 | The Docker images `jasonish/suricata`, `jasonish/evebox`, `ntop/ntopng`, `victoriametrics/victoria-metrics`, `prom/prometheus` and their paths and volumes. For slice 27 the accepted ones are `jasonish/suricata` (the command `--af-packet`, the config, rules and logs on the same paths as on the host), `jasonish/evebox` (the command `server -c /etc/evebox/evebox.yaml`), `ntop/ntopng:stable` (the config `/etc/ntopng/ntopng.conf`), `redis:7-alpine`; neither the image, nor the entry point, nor the volume path was checked against the image itself | 27 (accepted, not confirmed), 28 |
| A7 | The presence of the ntop and EveBox repositories for every supported OS | 5, 6, 26 |
| A8 | Closed (v5): EveBox and ntopng have no check mode, non-emptiness is checked (4.5) | closed |
| A9 | The retention mechanism of EveBox (`EVEBOX_RETENTION_DAYS`): a built-in setting or a periodic cleanup | 0, 6 |
| A10 | The source of the VictoriaMetrics and Prometheus binary for `native` and the check of the checksum. **Closed in v26:** the GitHub releases of the projects (`VictoriaMetrics/VictoriaMetrics`: `victoria-metrics-linux-<arch>-<version>.tar.gz` and `_checksums.txt`; `prometheus/prometheus`: `prometheus-<version>.linux-<arch>.tar.gz` and `sha256sums.txt`); the file names and sums were taken from the real releases, v1.153.0 and v3.15.0 are pinned (older than two weeks on 2026-10-18, a newer one is not taken). node_exporter (v1.12.1, taken the same way on 2026-10-25) follows the same rule; Grafana has no GitHub release, so its tarball sum is read from the vendor file next to it | 28 |
| A11 | The type of the license is chosen by the owner: GNU General Public License v3.0 (said by the owner on 2026-11-08; before that the repository held MIT). `LICENSE` holds the full GPLv3 text, Copyright (C) 2026 FlexEbat. Phosphor Icons stay MIT and are listed in THIRD_PARTY.md | 25 |

---

## 18. Review after every slice

A separate session, after a slice is ready and the gate is green. The task of the session is to look for problems, not to praise what was written.

The checklist:

1. The config keys, the `ctl` commands, the fields of `health.json`, the metrics, the endpoints match section 4 word for word. There are no extra ones.
2. Steps do not call system commands past `run`, package and service operations go through `os.sh` and `runtime_*.sh`.
3. All paths are built through `lib/paths.sh`.
4. Every step of the installer is idempotent, `--dry-run` does not change the system, `reconfigure` touches only the steps of table 5.3.
5. `dpistack-ctl` checks every argument against a list before acting. There is no `eval`, no substitution of user input into a command string.
6. Secrets (the panel password, `METRICS_TOKEN`, the Telegram token, SMTP) are printed nowhere and written to no log, except the single display in the final report.
7. The panel runs nothing except `sudo -n dpistack-ctl`, reads no files outside the list of section 3.
8. No false errors in normal situations: the rotation of `eve.json`, a reset of the `stats` counters, a quiet interface with no events.
9. The tests check the acceptance criteria, not repeat the implementation. For every criterion with a refusal there is a test of the refusal.
10. There is no dead code: unused functions, templates, schema keys, JS modules, CSS selectors with no markup.
11. No files and abstractions beyond section 3 have appeared.

The findings are fixed in the same session, then the gate is run again.

*A note: the reviews below record what was found and fixed at the time. `dpistack-ctl` in them is the name of the verbs program of that time (today the verbs of `dpistack`), and some limits mentioned (for example `MemoryMax=64M` of the panel unit) were removed later (v0.23.0).*

### 18.0 Index of slices: done and remaining

One row per slice. **Done** means the Definition of Done of section 14 was met; a slice that is only partly done lists what is done and what remains, and the same two lists are in its entry below. The order is strict, from the top down, one slice per session. A slice is vertical: from a config key to a visible result. Slice 31 was never used. Every slice has an entry in the style of 18.20: `### 18.NN Slice N: name (version)`, a table of findings (No, Severity, Finding, Fix) and an `Open:` paragraph for what was not checked or is left. The entry of a slice not yet done holds its specification and is filled in with the review when the slice is done. The detail of the slices without an entry is in the sections 4 to 12 (contracts) and in the git history.

| Slice | Name | Status | Version | Detail |
| --- | --- | --- | --- | --- |
| 0 | the manual prototype | done | v0.1.0 | sections 4 to 12 |
| 1 | the skeleton | done | v0.1.0 | sections 4 to 12 |
| 2 | Suricata (IDS) from packages, EVE, systemd, logrotate | done | v0.1.0 | sections 4 to 12 |
| 3 | rules | done | v0.1.0 | sections 4 to 12 |
| 4 | nDPI and Suricata from source | done | v0.1.0 | sections 4 to 12 |
| 5 | Redis and ntopng | done | v0.1.0 | sections 4 to 12 |
| 6 | EveBox | done | v0.1.0 | sections 4 to 12 |
| 7 | access (localhost, lan, nginx), firewall | done | v0.1.0 | sections 4 to 12 |
| 8 | reconfigure, upgrade, uninstall | done | v0.2.0 | sections 4 to 12 |
| 9 | the install and reconfigure menu | done | v0.2.0 | sections 4 to 12 |
| 10 | `dpistack-ctl`, status, control, logs | done | v0.3.0 | sections 4 to 12 |
| 11 | `dpistack-ctl`, configs, rules, iface, reconfigure | done | v0.3.0 | sections 4 to 12 |
| 12 | the BitTorrent and HTTPS tests | done | v0.3.0 | sections 4 to 12 |
| 13 | the watchdog | done | v0.3.0 | sections 4 to 12 |
| 14 | alert channels | done | v0.3.1 | sections 4 to 12 |
| 15 | the persistent command `dpistack` and the control menu | done | v0.3.1 | sections 4 to 12 |
| 16 | the panel, the server, sign-in, security | done | v0.6.0 | 18.6 |
| 17 | the panel, the install and Overview | done | v0.7.0 | 18.7 |
| 18 | components and logs | done | v0.8.0 | 18.8 |
| 19 | the config editor | done | v0.9.0 | 18.9 |
| 20 | rules in the panel | done | v0.10.0 | 18.10 |
| 21 | EVE events | done | v0.11.0 | 18.11 |
| 22 | metrics, charts | done | v0.12.0 | 18.12 |
| 23 | the `/metrics` export | done | v0.13.0 | 18.13 |
| 24 | tests, alerts, interfaces in the panel | done | v0.14.0 | 18.14 |
| 25 | README and LICENSE | done | v0.15.0 | 18.15 |
| 26 | the RHEL family and SELinux (a required platform) | done | v0.16.0 | 18.16 |
| 27 | the Docker runtime | done | v0.17.0 | 18.17 |
| 28 | the metrics backend, VictoriaMetrics and Prometheus | done | v0.18.0 | 18.18 |
| 29 | IPS mode | done | v0.19.0 | 18.19 |
| 30 | the single file | done | v0.20.0 | 18.20 |
| 32 | no panel budget | done | v0.28.0 | sections 4 to 12 |
| 33 | runtimes, the matrix and the links | done | v0.28.0 | sections 4 to 12 |
| 34 | users, roles and permissions | done | v0.29.0 | sections 4 to 12 |
| 35 | the audit log and login history | done | v0.30.0 | sections 4 to 12 |
| 36 | backup and restore | done | v0.33.0 | 18.36 |
| 37 | the shell of the panel | **done.** Done: the corner, Build info, the look, readable Audit actions, the menu in groups, routes by hash, the folded menu. Top bar (host, state, mode, user menu, theme) in v0.38.0. The alert bell came with slice 43 | v0.32.0, v0.32.1, v0.34.0, v0.38.0 | 18.35, 18.37, 18.49 |
| 38 | Overview v2, system health and topology | **done.** `GET /api/system`, host cards, interfaces table, state cards, warnings, alerts by severity, latest alerts, traffic graph, watchdog warnings, and the Network screen (the capture chain and the interfaces table); docker and systemd state is decided in D70 | v0.35.0 to v0.37.0, v0.39.0 | 18.38, 18.50 |
| 39 | Traffic Explorer | **done.** The Traffic screen: devices, applications, domains, connections, a text filter, one device in detail, a link to ntopng; built in the browser from `/api/eve` (flow, dns, tls), no new endpoint | v0.40.0 | 18.39 |
| 40 | the Events workspace and exceptions | **done.** Events: filters (address, rule, category, protocol, severity, domain, time), grouping, the events of one flow, the history of one rule, JSON and CSV export, Create exception; Exceptions screen; `dpistack exceptions`; `EXCEPTIONS_DEFAULT_DAYS` | v0.41.0 | 18.40 |
| 41 | Rules v2 | **done.** Counts per rule source, the history of updates, rule search by category, source, state and text, a check and editor of `local.rules`, the history of changes of a config file with a comparison | v0.42.0 | 18.41 |
| 42 | the IPS page | **done.** The IPS screen: readiness checks (mode, Suricata, queue rules, a listener on the queue, the confirmation timer), packet counters, drop rule counts, the latest blocked events, and the rule test (an offline replay in simulated IPS mode); `dpistack ips status\|test` | v0.43.0 | 18.42 |
| 43 | the Alert Center | **done.** Alerts of the watchdog and of Suricata with the states new, acknowledged, snoozed until, resolved; decisions with who and why; filters; the bell of the top bar; `dpistack alerts`, `alerts-state.json` | v0.44.0 | 18.43 |
| 44 | Settings v2 | **done.** Three columns, search, the standard and advanced levels, dimming of the keys that do not apply, details for every key, the staged change with a diff and a gated Apply, profiles; `settings profile`, `profiles.json` | v0.45.0 | 18.44 |
| 45 | security of the panel | **done.** The Security screen: the security check, your sessions (end one, end the others, sign everyone out), API tokens (read only or by role, expiring, shown once), the history of sign ins; `dpistack tokens` and `security check`, `api-tokens.json` | v0.46.0 | 18.45 |

**Rules for the slices not yet done.** Decided on the request of 2026-10-31 (`todo.md`), "choose yourself". General rules for all of them: (1) Nothing is shown that the program cannot really do: the IPS page does not say "dry run" unless a drop is really tested (slice 42 calls what it does a "rule test"). (2) Every change of the system goes through a verb of section 4.5; the panel never writes outside `/var/lib/dpistack`. (3) Every action that changes something is written to the audit log (slice 35) with the user, the time, the address and the result. (4) The permission of the user is checked in the panel for every route (slice 34), the verbs trust the panel. (5) There are no resource budgets for the panel. (6) New screens follow the design of 9.1 and work in both themes.

### 18.1 The result of the full review (v7)

The review followed the checklist above: automatic passes (dead code, paths past `paths.sh`, system commands past `run`, unused keys and templates), fuzzing of the arguments of `dpistack-ctl` (metacharacters, empty values, unicode, numbers on the borders), reading the alert code, `common.sh`, `state.sh`, `schema.sh` and the workflows. Every finding is closed by a test from `tests/hardening.bats` or `tests/ci_config.bats`; the new tests were checked on the code before the fix, where they fail.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R1 | critical | `run` always returned 0: inside `if ! cmd` `$?` equals the result of the negation, so any `run ... \|\| return 1` in the steps did not fire and a failure of a package or service install passed silently | the return code is read right after the command |
| R2 | high | `atomic_write` on a write error (a full disk) still replaced the target with a truncated file | on an error the temporary file is removed, the target does not change |
| R3 | high | `state` was rewritten with no lock by the installer and the watchdog (lost updates: step marks, render hashes), keys were compared as regular expressions | writing under `flock`, keys are compared as text |
| R4 | high | free keys were not checked: `LAN_CIDR`, `NGINX_CERT`, `BPF_FILTER`, `HOME_NET`, `IFACES` could inject directives into the nginx config or YAML, and `TEST_HTTPS_URL` with `-o...` would become an option of `curl` (a file write as root) | the `SCHEMA_PATTERN` patterns (4.3), `curl` is called with `--` |
| R5 | medium | `config-write dpistack.conf` accepted secret keys and left them in a file with permissions 0644 | a refusal with code 3 |
| R6 | medium | `apt-get install -y` without `DEBIAN_FRONTEND=noninteractive` could stop at a debconf question | `os_detect` sets `DEBIAN_FRONTEND` and `NEEDRESTART_MODE` |
| R7 | medium | `ctl` changed configs without waiting for the installer lock | `ctl_lock` (waits up to 30 s) |
| R8 | medium | `NTOPNG_VERSION` and `EVEBOX_VERSION` are described in 4.3 but were ignored | `pkg_spec` pins the package version |
| R9 | low | `logs -n 08` was refused (octal notation), `-n 01750` passed the limit 1000 | decimal parsing, no more than six digits |
| R10 | low | alerts: the Telegram token was not escaped in the `curl` config, the list of recipients was expanded by a glob, `\r` was not stripped; the decimal values of the watchdog depended on the locale | escaping, `read -a`, `LC_NUMERIC=C` |
| R11 | high for CI | `trivy-action@0.28.0` does not exist (the tag `v0.28.0`): the job would fail; actions were not pinned by SHA; `actionlint` was downloaded and piped into `bash`; the release tag was not checked on `main`; SARIF from a fork would not upload | see 12.1 |
| R12 | low | three paths were defined past `lib/paths.sh` (`os-release`, the data directory of `suricata-update`, `libndpi`) | moved into `paths.sh` |

What stayed open:

- (closed in 18.3, R18) a common `apt-get update` once per run.
- A change of `*_VERSION` of an installed package does not reinstall it (4.3).
- (closed in 18.48, R203) the key `EVE_SYSLOG` was described in the schema but the code did not read it.
- `suricata.eve_fresh` relies on the modification time of `eve.json`, not on the mark of the last event: a quiet interface with `stats` on does not give a false alarm, with `stats` off the check gets `na`.
- The image of `actionlint` is given by a tag, not a digest.

### 18.2 The result of the repeated review (v8)

The gate before the fixes is green (223 bats). Every finding is closed by a test in `tests/hardening.bats`; the new tests fail on the former code.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R13 | high | `atomic_write` gave the target the permissions of the temporary file (0600): `evebox.yaml`, `ntopng.conf`, units, `logrotate`, the nginx and Suricata configs re-rendered by the installer lost their permissions; the packaged EveBox runs as the user `evebox` and could not read its config | an existing file keeps its mode and owner, a new one gets 0644, secrets and `state` pass the mode explicitly (`atomic_write <path> [mode]`, likewise `dry_run_write` and `write_rendered_file`); `sudoers` is written at once with 0440 |
| R14 | high | the steps did not pass on the error of `run`: a failure of `pkg_install`, of adding a repository, of `systemctl enable --now`, `git`, `openssl`, `ufw` passed, the step printed "done" or "partly applied", the install ended with code 0; `redis` wrote `done` after a failure | `\|\| return 1` in the steps `access`, `evebox`, `ntopng`, `redis`, `ndpi`, `suricata`, `rules`, `watch`; `run_apply` stops at a failed step |
| R15 | medium | `ntopng_repo_add` called `add-apt-repository -y universe` on Debian, which has no such component | the call only with `ID=ubuntu`; a failed download of `apt-ntop.deb` stops the step and removes the temporary file |
| R16 | medium | `config_snapshot_applied` rewrote `state` with no lock that `state_write_value` and the watchdog take (a lost update, R3 not fully closed) | the same `flock` on `state.lock` |

Not changed, stays open:

- `rules_register_sources`: `suricata-update add-source` for an already added source at a repeated `reconfigure` may return an error; so a failure is not made fatal.
- `suricatasc -c ruleset-reload-nonblocking` after a rules update: with a stopped Suricata the error is not fatal, left as it is.
- (closed in 18.3) the URL of the ntop.org repository for Debian.
- The window after R14: `check` after `apply` still allows "partly applied" for a hand-edited file (5.4).

### 18.3 Packages, build and CI (v9)

The open item of 18.1 about `apt-get update` is closed. Every finding is closed by a test in `tests/hardening.bats` (or `tests/ci_config.bats`); the new tests fail on the former code.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R17 | high | the defaults `SURICATA_SOURCE=source`, `NDPI_ENABLE=yes`, `NDPI_SOURCE=source` need a build, but no step installed compilers and libraries: on a clean image `autogen.sh` failed | `pkg_build_deps` before the build (5.5) |
| R18 | high | `apt-get update` was only in the steps `oisf`, `evebox`, `ntopng`: on a fresh image the `suricata` package of the distribution was not found; `upgrade` did not update the index and swallowed the `apt-get` error; a minimal image has no `curl`, `wget`, `gnupg`, `git` | `pkg_update_once` and `pkg_install_base` (5.1 step 4a) |
| R19 | medium | the ntop.org repository for Debian was built by number (`apt/12/...`), ntop.org has the path by the release name (`apt/bookworm/...`; Ubuntu by number, `apt/24.04/...`) | `VERSION_CODENAME` on Debian, an error on an empty value |
| R20 | medium | no package (`suricata`, `libndpi-dev`) or the OISF PPA not on Ubuntu: a failure in the middle of the install | a fall back to `source` with a message and a write into `dpistack.conf` (5.1 step 4a) |
| R21 | medium | Suricata from git needs Rust 1.85, Ubuntu 22.04 and 24.04 have 1.75 by default | `rustc-1.N` through `RUSTC` and `CARGO` (5.5) |
| R22 | medium for CI | four PRs from Dependabot (#4-#7) failed in `security` on `gitleaks-action` with no findings (the whole history of `main` and every branch are clean, checked locally with gitleaks 8.30.1) | a binary with SHA-256 instead of the action (12.1) |

Not changed, stays open:

- the ntop.org repository is taken from `apt` (development builds), not from `apt-stable`; there is no stable channel for Debian 13 and Ubuntu 26.04. The owner's decision. (Closed in 18.5, R33.)
- ntop.org needs the `contrib` component in `sources.list` for Debian; the installer does not add it (an edit of a system file), without it `apt` will not find `ntopng`. (Closed in 18.5, R34.)
- ntopng and EveBox from their repositories have no fall back to a build: Rust, Node and various dependencies are needed, building from source is not implemented; without a package the step stops with an error.
- the dnf family: `pkg_available` exists, the install and the build wait for slice 26.

### 18.4 Real installs and the dnf family (v10)

The installer was run as root on Ubuntu 24.04 with a real `apt`, a build from source and a fake `systemctl` (there is no systemd in the environment). The Debian and Fedora mirrors, `packages.ntop.org` and `evebox.org` were unavailable: their paths were checked with mocks only.

Checked on a real system: the path `SURICATA_SOURCE=distro` (Suricata 7.0.3, the rendered `suricata.yaml` passes `suricata -T`, `eve.json` is written); the default path (nDPI 4.14 and Suricata 9.0.0-dev from source with the nDPI plugin, the events `dns`, `tls`, `http`); a repeated `install` changes nothing; `status`, one pass of `dpistack-watch`, `uninstall --purge`.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R23 | high | a minimal image has no `ip`, and preflight called it before the packages were installed | 5.1 step 4a0 |
| R24 | high | `IFACES=enp2s0` by default, with another interface name `install -y` failed | auto detection, section 3 |
| R25 | high | the default build did not build: the nDPI plugin in Suricata master compiles only with nDPI 4.12 and 4.14, while by default nDPI master was taken (the document promised "a compatible version") | `NDPI_COMPAT_REF=4.14` |
| R26 | high | the nDPI plugin was installed into `/usr/local/lib/suricata`, while `suricata.yaml` points to `/usr/lib/suricata/ndpi.so`: "Bad plugin path" | `--libdir`, 5.5 |
| R27 | high | after `make install` there is no `classification.config`, `reference.config`, `threshold.config`: `suricata-update` and the start failed | `make install-conf`, 5.5 |
| R28 | medium | the pinned `NDPI_VERSION` and `SURICATA_VERSION` were compared with the SHA in the state as text and rebuilt at every run | a comparison of commits |
| R29 | medium | no `sudo`, `visudo` not found, the `panel` step failed | `sudo` in the base packages |
| R30 | low | `suricatasc` with a not yet running Suricata gave a false `ERROR` | reload only with a live socket |
| R31 | medium | on Debian 12 (Rust 1.63) the default did not build | a fall back to the package without nDPI, 5.5 |

Known limits:

- the whole dnf layer (section 5.1) was checked only by mocks in `tests/families.bats`: package paths, EPEL and CRB, `firewalld`, SELinux, the ntop.org repository. For `SURICATA_SOURCE=distro` on dnf it is unknown how the unit of the package picks the interface (in Fedora and EPEL it is `OPTIONS` in `/etc/sysconfig/suricata`), so on dnf the path `source` with an own unit is the reliable one;
- Debian 12 and 13, ntopng and EveBox on Debian: unavailable from the environment;
- an empty `SURICATA_VERSION` meant master (now `9.0.0-dev`, unreleased code); the decision about the latest release tag is the owner's (closed in 18.5, R32);
- the families `zypper`, `pacman` and `generic` (v0.22.0, section 18.23) work with the components in Docker only; a system without systemd is refused with code 3;
- after `uninstall --purge` the system user `dpistack` stays (closed in 18.5, R39).

### 18.5 The platforms Ubuntu, Debian, RHEL and stable versions (v11)

The approach changed: the project is a full one, not an MVP (section 1, item 11). The required platforms and the order of acceptance: section 2 and section 11 (in v12 by the owner's answers: Ubuntu LTS from 22.04, Debian from 12, Rocky and AlmaLinux from 8). The research (the documentation of OISF, ntop.org, EveBox, the packaging of Debian and Fedora) and builds on Ubuntu 24.04:

| No | Severity | Finding | Fix |
|---|---|---|---|
| R32 | high | by default Suricata `master` (9.0.0-dev) was built, unreleased code in a security system | `SURICATA_STABLE_REF=suricata-8.0.7`, checked by a build with nDPI 4.14 and the plugin on the stock Rust 1.75 |
| R33 | high | ntop.org was taken from the `apt` channel (nightly builds of `master`) | `apt-stable`, no fall back to `apt` |
| R34 | high | on Debian the ntop.org packages were not found without the `contrib` component | `apt_enable_component` |
| R35 | high | the RHEL family: the `oisf` path led to the Ubuntu PPA, the RPM unit took the interface from `-i eth0` | the COPR `@oisf/suricata-8.0` and `/etc/sysconfig/suricata` |
| R36 | medium | EveBox on the RHEL family: the repository was not added | `evebox-release.noarch.rpm` (source: the OISF tracker) |
| R37 | medium | `preflight` checked the Ubuntu PPA on any system and did not check ntop.org and EveBox | repository probes by the family and the chosen steps |
| R38 | medium | EOL releases and unknown systems started silently | `os_support_level`, `DPISTACK_ALLOW_UNSUPPORTED=1` |
| R39 | low | `uninstall --purge` left the panel user | `userdel` |
| R40 | high | a set of rules built for another version of Suricata (after changing master to 8.0.7) did not pass `suricata -T` ("Loading signatures failed"), and the `rules` step did not notice | the version of Suricata in the state (`rules.suricata_version`), on a change the step is applied again with `suricata-update --force` |
| R41 | medium | there was no way to quickly collect the output of a stand for analysis | the `diag` command (4.4) |

The actual behavior of the packaging that the code relies on (checked by the packages and the documentation): the unit of the Debian family runs `suricata -D --af-packet -c /etc/suricata/suricata.yaml`, the interfaces come from `suricata.yaml` (versions 6.0.4, 7.0.3 and 7.0.10); the RPM unit takes `$OPTIONS` from `/etc/sysconfig/suricata` and runs as the user `suricata`.

Known limits:

- Debian 12 and 13, Rocky and AlmaLinux 8, 9, 10: all the paths, `contrib` included, ntop.org `apt-stable/trixie` (the directory exists, the file `apt-ntop-stable.deb` is not confirmed), the OISF COPR, the EveBox rpm, `firewalld`, SELinux;
- Debian 12: Rust 1.63, so the package of Suricata 6.0 of the distribution without nDPI is chosen; a newer one can be had only from a backports package, and the installer does not connect backports;
- ntopng and EveBox from their repositories have no fall back to a build from source: with an unavailable repository the step stops, it can be skipped with `--skip`;
- `SURICATA_STABLE_REF` is raised by hand, but new releases are found and checked by a build by automation (12.4).

### 18.6 Slice 16: the panel server (v13)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R42 | high | a password hash with `-m 16` is 64 MiB, while the panel has `MemoryMax=64M`: signing in would kill the process by the cgroup limit | `-m 14` in the installer and `ctl panel-passwd`, a ceiling of 32 MiB in the panel with a clear error, checks one at a time |
| R43 | medium | the pattern `GET /` conflicts with `/api/` in the Go 1.22 mux | the static files are registered as `/` with a method check inside |
| R44 | medium | `x/crypto` v0.33.0 was pinned because of the Go 1.22 minimum, but it is not the latest version | the minimum raised to Go 1.26, `x/crypto` v0.58.0, `x/sys` v0.49.0; `actions/setup-go` (pinned by SHA) added to `gate`, because Go on the runners may be older |
| R45 | low | a review of all 27 test files (300 bats tests and the Go tests of the panel): three tests checked nothing (`security.sh` on the repository itself, the first line of usage, the version format of `ctl version`), one looked for the URL `ntop.org` in the text of the sources although the same addresses are already checked through behavior, one panel test could not fail, and the Suricata choice test would break at every shift of the pin (it compared the literal `suricata-8.0.7`) | four tests removed, `ctl version` is compared with `lib/common.sh`, the Suricata choice test checks the format of the reference and the pair "pin and COPR series" with no literal. There are no tests with no checks and with `\|\| true` instead of a check |

Slice 17 closed the unit (its budget check was removed in v0.28.0); gzip compression of the static files stays for the moment it becomes noticeable in size (9 KB now). `govulncheck` (12.2) is added as a separate step in `security.yml`, because it needs access to `vuln.go.dev`.

### 18.7 Slice 17: installing the panel (v14)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R46 | high | the generated panel password was printed nowhere (criterion 1 of slice 17): the flag `PANEL_PASSWORD_JUST_GENERATED` was set and not read, a person would not learn the password | printing next to `METRICS_TOKEN`, a test: shown once, lies nowhere in plain text, your own password is not printed |
| R47 | medium | the release archive did not contain `panel/`, so `PANEL_SOURCE=build` from the archive could not build the panel | `panel/` added to the archive in `release.yml` |
| R48 | high | in `nginx` mode nginx listened on the public port on all addresses, and ntopng, EveBox and the panel wanted the same port on `127.0.0.1`: the second `bind` fails with `EADDRINUSE`, the `nginx` mode could not work | the variant "the service on `PORT+10000` on loopback, nginx on `PORT`": needs no new key and does not depend on the IP of the host; the rule `access_backend_port`, the config check (a port no more than 55535), `preflight` checks both ports, the watchdog looks at the port of the service, tests. Rejected: `listen` on a specific address (the IP of the host changes, several interfaces) and new keys for the ports of backends (they bloat the schema) |
| R49 | medium | `PANEL_SOURCE=prebuilt` from the archive had nothing to rely on: the archive held no ready binary, and `build` needs Go 1.26, which is not in the packages of LTS distributions | the release archive carries binaries for amd64 and arm64; `PANEL_SOURCE=auto` (the default) takes a ready one, else builds: from the archive it works without Go, from a clone with Go it builds |

**Open questions:**

1. The `nginx` mode with the new ports was checked only by tests on mocks and `nginx -t`; a live run of nginx with real services on a stand is ahead.
2. The build of the release with binaries is checked only on a real tag `vX.Y.Z`; before a tag the step does not run.

### 18.8 Slice 18: components and logs (v16)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R50 | high | `ctl logs --follow` cannot be closed by a signal: the panel is not root, and `sudo` keeps the process as root, `kill` gives `EPERM`, `journalctl` would keep running after the browser left (criterion 4) | closing stdin: the key `--until-stdin-closed`, the test is confirmed by a mutation (without closing stdin it fails) |
| R51 | medium | a background command in a non-interactive bash gets stdin from `/dev/null`: `cat` saw the end of input at once and cut the stream | an explicit `<&0`, a test on `ctl` |
| R52 | medium | stopping the panel from the panel would kill the process before the answer is sent | the command after the answer (202), a second confirmation is required for `restart` too |

Open: SSE behind `nginx` is checked only by the header `X-Accel-Buffering: no` and tests, there is no live run.

### 18.9 Slice 19: the config editor (v17)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R53 | medium | `ctl` had no "check only" mode, and the button "Check" needs a check with no write | `config-write --check`, a test on `ctl` |
| R54 | medium | a refusal of `ctl` lost the words of the checker: they go to stdout, while `ExitError` kept only stderr | `ExitError.Output`, `output` in the answer |
| R55 | low | saving with `suricata -T` takes longer than the common timeout of 15 seconds and longer than the `WriteTimeout` of the server | a separate write timeout of 3 minutes and extending the deadline of writing the answer |
| R56 | low | some of my first Go tests checked the behavior of the fake `ctl`, not the code of the panel | removed: the guarantees "the file is not changed" and "a rollback restores the backup" are checked by the bats tests of `ctl` |

Open: "Roll back" without a backup gives a `ctl` error with code 1, and the panel shows it as 500 with a clear text; there is no separate code for "no backup" in the `ctl` contract.

### 18.10 Slice 20: rules in the panel (v18)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R57 | medium | `rules-sources list` does not show which source is enabled, and the screen needs the buttons "Enable" and "Disable" by state | `rules-sources list --enabled` (`list-enabled-sources`), a test on `ctl` |
| R58 | medium | `suricata-update list-sources` prints color codes into a pipe too: a source name with them can be neither shown nor sent back | the codes are stripped at parsing, a test with real codes |
| R59 | medium | the reason of a failure of `rules-update` was lost: `suricata-update` writes to stderr, while `ExitError.Message` keeps only the line that `ctl` itself printed | the output of the tools is collected into a temporary file and goes to stdout (the last 40 lines), tests of both failures (`suricata-update` and `suricata -T`) |
| R60 | medium | killing `ctl` when the browser leaves would skip the rollback of the set of rules | the update is started with no binding to the request, the result stays in the memory of the panel |
| R61 | low | `nginx` cuts an answer longer than 60 seconds, an update may take longer | the screen polls the state after a break and shows the result |
| R62 | low | the time of the file of the set is not the time of the update: with no changes `suricata-update` does not touch the file | the time and the result are kept in the panel |
| R63 | low | a screen error found in jsdom: after a failed search the query was remembered and repeated after every edit, wiping the message | only a successful search is remembered, the fields are cleared by the result of the edit, not by the text of the error |

Open: after a restart of the panel "the last update" is empty until the button is pressed (the panel does not see the updates of the timer; to see them a `ctl` command or writing the time into `state` is needed, this is a decision for the next slice or a question to the owner). The list of groups shows only those written into `enable.conf`: `ctl` has no list of all the groups of the set, a new group is entered by name. The parsing of `list-sources` was checked against the sources of `suricata-update` 1.3.3, it was not run on a real stand.

### 18.11 Slice 21: EVE events (v19)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R64 | medium | one common ring would push the rare `alert` out with a stream of `flow`, and "the last 50 alerts" would be empty | a ring per type (500), no more than ten types, 5000 together |
| R65 | medium | a file renamed at rotation loses its tail if one goes to the new one at once | reading the old file to the end through the open descriptor, then the switch (a test with a new file whose size is larger than the old offset) |
| R66 | medium | a reader that stood idle for long would read gigabytes, violating "the file is not parsed whole" | catching up no more than 4 MiB from the end, a test on 8 MiB appended |
| R67 | medium | `EVE_FILE` in the schema did not affect the `panel` step: `reconfigure` would not render the unit again, and the panel would go on reading the file (or not reading it) the old way | the `panel` step added to the key, a bats test on `reconfigure` |
| R68 | low | with `EVE_FILE=no` an empty list would look like "no events" | the answer `available: false` with a reason, the screen writes it and turns the buttons off |
| R69 | low | a screen error found in jsdom: a stream event was inserted into the table twice | one insertion |

Open: event types beyond ten are not stored (the panel does not show them; the full parsing stays with EveBox); the `+0000` format of the Suricata `timestamp` was checked against the known form of `eve.json`, not checked on a real stand; `eve.json` under load (tens of thousands of events per second) and after a real `logrotate`, SSE behind `nginx` and the rights of the user `dpistack` on the file were not checked.

### 18.12 Slice 22: metrics and charts (v20)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R70 | medium | a point taken in the same second as the request stuck into the last bucket of the grid together with the previous one and got a double weight (found by the recovery test: the grid after a restart did not match the old one) | the grid covers `(now-period, now]`, a point at the end goes into its own bucket, nothing extra is glued |
| R71 | medium | the cumulative Suricata counters after a restart would give a negative rate | a reset skips the interval and redefines the base, a test on five cases (drops alone included) |
| R72 | high | the panel cannot write `metrics.json`: the state directory belongs to root, and giving it write access means letting it replace `health.json` and `state` | the installer creates one file for the panel user, nothing else is handed over (a bats test checks that the owner of the other files does not change); an in-place write |
| R73 | low | "zero CPU with no tabs" and a ring for a day are incompatible literally | the decision is recorded above: one tick per 30 seconds, no polls |
| R74 | low | an unreadable RSS would be drawn as zero | an unknown value is `null`, a test |
| R75 | low | an unavailable series looked like a flat line near zero | `available: false` with a reason in the answer, words instead of a chart on the screen (jsdom) |

Open: `cpu` and `rss` belong to the panel, not to Suricata (the panel has no right to read the Suricata process, section 3); the charts of drops and rate by a real `stats` were seen by no test on a stand; a power loss in the middle of writing `metrics.json` costs an hour of history; on the 24-hour grid a bucket of 8 minutes smooths short peaks. The Prometheus metrics (slice 23) are built from the same data.

### 18.13 Slice 23: the `/metrics` export (v21)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R76 | high | `install.sh install --dry-run` printed `METRICS_TOKEN` in plain text: the line went before the `DRY_RUN` check, while the token did not exist on disk | the print is removed from the summary, the report shows the token only after a real install, a bats test on dry-run (neither the value, nor `credentials:`, nor a token file) |
| R77 | high | a bare token without the word `Bearer` was accepted: `CutPrefix` without a prefix returns the whole string (found by a test) | the scheme is required, the comparison ignores the case of the word `Bearer`, a test on seven wrong headers |
| R78 | medium | a `reconfigure` that turned `METRICS_EXPORT` on created a token and showed it nowhere | the report is called after `reconfigure` too, a bats test |
| R79 | medium | the token cannot be given to the panel by a flag (visible in `ps` and in the unit) and cannot be read from `secrets.conf` (it holds other secrets, `0600 root`) | a separate token file `0640 root:dpistack`; `METRICS_TOKEN` now affects the `panel` step, so that the file and the unit are updated on a change |
| R80 | low | a panel with an unreadable token file would silently serve `/metrics` unprotected or not serve it | the panel does not start while the requested token file is unreadable or empty |
| R81 | low | `install --dry-run` wrote `/etc/dpistack/panel.auth` and printed the generated panel password (so it was before slice 23 too; `panel_password_apply` was called before the `DRY_RUN` check) | **fixed in v23**: with `--dry-run` `panel_password_apply` exits at once, the password is not generated, the file is not written, `argon2` is not installed; the bats test (neither `panel.auth`, nor the line "Panel password created", nor the given `DPISTACK_PANEL_PASSWORD` in the output) fails without the fix |

Open: the data of the metrics backend in `dpistack_disk_free_ratio` (slice 26); `promtool check metrics` is not run in CI (the check is by an own strict parser of the format in `metrics_export_test.go`; if `promtool` is in `PATH` the test runs it too); a real Prometheus or VictoriaMetrics scrape was not checked on a stand; `dpistack_eve_events_total` undercounts events for the periods when the panel did not read the file (more than 4 MiB at a time).

### 18.14 Slice 24: tests, alerts, interfaces (v22)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R82 | high | `-tests-file` was passed by the unit only together with the `/metrics` token (slice 23): with `METRICS_EXPORT=no` the Tests screen would not find the file and "the last result" would always be empty | `-tests-file` and the new `-events-file` are now always passed, a bats test checks them with `METRICS_EXPORT=no` |
| R83 | medium | `ctl test` returns code `1` when a test failed: the ordinary error parsing would give 500 instead of a line with `fail` and a reason | code `1` with an array in the output is an answer 200, a test with a failed test (the mutation "count `1` as an error" breaks it) |
| R84 | medium | a test or a `reconfigure` killed in the middle by closing the browser could leave a test rule or a half applied config | a start with no binding to the request, one at a time (409) |
| R85 | low | found by jsdom: after a request the "Remove" button of the only interface turned on again (`setBusy(false)` turned on all buttons) | the "last" mark is kept in the button and survives the blocking |
| R86 | low | found by jsdom: after a failed change of an interface, re-reading the list at once erased the error message | after a failure the list is re-read keeping the error |
| R87 | low | the Tests screen appended buttons to the container at every opening, they doubled | the container is filled anew |

Open: a real `ctl test all` and a real `iface add` with `reconfigure` from the panel were not run on a stand (the tests go against a fake `ctl`); the interfaces block is on the Components screen, not a separate screen; `events.jsonl` grows with no limit (its rotation is not in the section, only the tail is read).

### 18.15 Slice 25: README, LICENSE, the example config and R81 (v23)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R88 | medium | `dpistack.conf.example` lacked `SURICATA_VERSION`, `NDPI_VERSION`, `NTOPNG_VERSION`, `EVEBOX_VERSION`, and `NTOPNG_IFACES` had `enp2s0` instead of "as `IFACES`" (empty): the example diverged from table 4.3 and the schema (found by the new check script) | the keys added, the default fixed, `scripts/check-conf-example.sh` in the gate and in `tests/ci_config.bats` (mutations: a missing key, another default) |
| R89 | low | the description of the "quick install" in the README draft did not match the menu (no Suricata source and password, the install starts by a separate item) | fixed by section 5.0; the README does not promise what the menu does not do |
| R90 | low | an example `scrape_config` with `credentials` pushes toward a token in a config file | in the README `credentials_file`, in the report of the installer the former form (the token is shown there once) |

Open: criterion 2 (the commands of the README by hand on a clean Ubuntu LTS) and criterion 3 for external links were not run on a stand; `vmagent` and a single VictoriaMetrics with this `scrape_configs` block were not started; A11 (the license) without an answer from the owner, stays MIT.

### 18.16 Slice 26: SELinux, firewalld, COPR by OS version (v24)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R91 | high | with `Enforcing` nginx could not listen on `NTOPNG_PORT` (3000 is `ntop_port_t`), `EVEBOX_PORT` and `PANEL_PORT`: `httpd_t` may use only `http_port_t`; `setsebool httpd_can_network_connect` does not solve this | `semanage port` for the three ports in `nginx` mode, a test on the calls and on a repeat with no extra `-a` |
| R92 | high | in `nginx` mode ntopng listens on `PORT+10000`, while the policy lets `ntop_t` use only 3000 and 3001 | `ntop_port_t` for the service port if it is neither 3000 nor 3001 |
| R93 | medium | `FIREWALL_MANAGE=auto` with a stopped `firewalld` tried `--permanent` and `--reload`, and the `access` step failed in the middle of the install | the check `firewall-cmd --state`, a message and a skip, a test (the mutation of the check breaks it) |
| R94 | medium | a file moved by `mv` from another directory keeps a foreign label (this is how `ctl config-write` writes from the `staging` directory), and Suricata would not read it | `restorecon -F` after the replace in `atomic_write`, a pass `restorecon -RF` at the end of `install` and `reconfigure`, tests (the mutation of `atomic_write` breaks a test) |
| R95 | medium | `preflight` checked the page of the COPR project, not the build for the OS version: a new Rocky release with no chroot failed already at `dnf copr enable` in the middle of the install | a probe of the repo file of its own chroot, code 3 and a reason with the name of the chroot before the first step, three tests |
| R96 | low | the stub `curl` could not fail selectively, so no test checked a refusal of one repository | `MOCK_CURL_FAIL_MATCH`; the stub `firewall-cmd --state` is driven by `MOCK_FIREWALLD_STATE_EXIT` |

Open: criterion 1 (slices 2-7 on Fedora and a RHEL-compatible host) is not done; AVC denials on a real `Enforcing` were not seen once, the names of the types `http_port_t` and `ntop_port_t` and the package `policycoreutils-python-utils` are taken from the knowledge of the policy, not from the output of `seinfo` on a stand; the address of the COPR repo file was not opened; services started before the final `restorecon` pass could have started with a wrong label; the probes of `ntop.org` and EveBox do not check by OS version (their repo files do not depend on the chroot).

### 18.17 Slice 27: the Docker runtime (v25)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R97 | high | `suricata_check_set` in `dpistack-ctl` checked `suricata.yaml` and the rules with the host binary: with Suricata in a container there is none, and every edit from the panel answered "suricata is not installed" (code 4) | the check in the container with the check directory on `/dpistack-check`, a test on the call |
| R98 | high | `rules-update` and the `rules` step reloaded the rules with the host `suricatasc`: with a docker Suricata there is none, and the socket is in the container | `suricata_reload_now` and `docker_suricata_reload` (`exec -T`), a test |
| R99 | medium | the BitTorrent replay ran the host `suricata` and with a docker Suricata said "not installed" instead of a reason | a skip with a reason and a test |
| R100 | medium | by default `NDPI_ENABLE=yes`, while the nDPI plugin does not get into the container: a Suricata in docker would silently work without it | `preflight` with code 3 and the text `set NDPI_ENABLE=no` |
| R101 | medium | docker without the `compose` plugin would find the error only at `up -d` in the middle of the install | `docker compose version` in `preflight`, code 3 |
| R102 | low | `docker` creates missing volume directories as root, and a host service could not write there | the directories are created before `up -d` |

Open: no container was started; the images, tags, entry points (`--af-packet` of `jasonish/suricata`, `server -c` of `jasonish/evebox`) and volumes were not checked (A6, criterion 4); the rights on `eve.json` for the process in the EveBox container were not checked (on the host it is `0640` with the group `suricata`); a move of docker to native and back was closed in v0.20.2 (R139); the metrics backend in docker waits for slice 28.

### 18.18 Slice 28: the metrics backend (v26)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R103 | high | `METRICS_RETENTION=6m` and a bare number mean different things: VictoriaMetrics reads them as months, Prometheus `m` as minutes; "6m" would give a retention of six minutes | with a backend only `h`, `d`, `w`, `y` are accepted, a test |
| R104 | high | the data of the backend in `/var/lib/dpistack` would disappear at `uninstall` without `--purge`: it removes the state directory whole, against the requirement "`none` does not delete data without `--purge`" | the data in `/var/lib/dpistack-metrics`, `--purge` removes it separately, a test |
| R105 | high | the token file appears at the `panel` step, while the `metrics` step goes earlier: Prometheus does not start with a missing `credentials_file` | the user `dpistack` and the token file are prepared by the `metrics` step, a test on the content and the owner of the calls |
| R106 | medium | `install -d -o dpistack-metrics` fails while the user does not exist (in tests `useradd` is a stub); a common trick of the `panel` step | `install -d` and a separate `chown` |
| R107 | medium | `scrape.yaml` lies in the state directory: without the traverse right the backend user would not read it | `chmod o+x` on the directory (the listing stays closed), the file `0644` with no secrets |
| R108 | medium | in `lan` the backend port would listen on 0.0.0.0 but would not be opened in the firewall | the port added to the `LAN_CIDR` rules, a test |
| R109 | low | `shfmt` rewrites the key `[vm-amd64]` of an array as arithmetic, a key in the reference of checksums broke | keys `vm_amd64` and the like |

Open: a real backend was not started; the scrape target in the state `up` and the series `dpistack_*` (criterion 1) were not observed; `NoNewPrivileges` and `ProtectSystem=full` in the units of the backend were not checked under a real systemd; the rights of the state directory (`o+x`) need to be checked on a stand; VictoriaMetrics and Prometheus have no update through `upgrade` (the version is pinned in the code); with `ACCESS_MODE=nginx` the backend is reachable locally only, TLS and access to it from outside through nginx are not set up.

### 18.19 Slice 29: IPS mode (v27)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R110 | high | the `suricata` step did `enable --now`, and a repeated run with a changed config or unit did not restart Suricata: a change from `IDS` to `IPS` would not take effect | a restart when the config already existed (`was_configured`); the first install stays with one `enable --now` |
| R111 | high | NFQUEUE rules without `--queue-bypass` would cut the network when Suricata stops (criterion 3) | the only rule of the `DPISTACK` chain goes with the flag, a test checks every NFQUEUE rule in v4 and v6 |
| R112 | high | the unit of the package starts Suricata with `-D` and `--af-packet` in `ExecStart`, for `-q` it cannot just be complemented | a drop-in with an empty `ExecStart=`, `Type=simple`, `PIDFile=` and `-q 0`; for `ids` and `afpacket` the drop-in is removed |
| R113 | high | an unconfirmed switch survived a reboot: the transient timer disappears, while the mode stays `ips` | `fw restore` at boot sees `mode.pending` and rolls back |
| R114 | high | if the timer could not be started, the host would stay in `ips` with no rollback | an immediate return to `ids` and code 1, a test |
| R115 | medium | a confirmation after the time would race with the rollback | `mode-confirm` after the time refuses with code 3 |
| R116 | medium | `IPS_NFQ_CHAINS` was checked only by a pattern: `FOO` would reach `iptables` | a membership check of `INPUT`, `OUTPUT`, `FORWARD` in `config.sh`, a test |
| R117 | medium | the panel API switched to IPS without a confirmation, the browser dialog could be bypassed by a direct request | `acknowledged: true` is required, a test |
| R118 | low | `ips` with Suricata in docker would configure nothing (NFQUEUE and `copy-mode` are not set in a container) | a refusal at the config check |

Open: a real NFQUEUE, a reboot, the `systemd-run` timer and `iptables` rules were not checked (only stubs with state); Suricata under NFQ starts without `--user`, that is, as root; the order of `dpistack-fw.service` and `reconfigure` at a rollback at boot (the network and Suricata may not be up yet) was not checked; on systems without `iptables` (only `nft`) the mode is unavailable; the `drop` rules are written by the user (`drop.conf`), IPS without them behaves like IDS; the countdown in the panel and `confirm()` in a browser were not looked at by hand, the JS had no tests of its own.

### 18.20 Slice 30: the single file (v28)

| No | Severity | Finding | Fix |
|---|---|---|---|
| R119 | high | after unpacking `SCRIPT_DIR` points to a temporary directory, and the search for the panel (`dpistack-panel-linux-<arch>`, `panel/`) in `step_panel.sh` and `preflight` would stop seeing the files next to the downloaded `dpistack-install.sh` | `ORIGIN_DIR` (`SCRIPT_DIR` by default, for the built file the directory of the file itself), a test on finding the panel next to it |
| R120 | high | a heredoc with a terminator inside a source or with no final line break would silently change the embedded file | the build refuses, both cases in a test |
| R121 | medium | `tests/data/bittorrent.pcap` is binary: in a heredoc it would be spoiled | base64, a test compares the file after an install with the original |
| R122 | medium | `selfinstall` takes the copy from `SCRIPT_DIR`: without `tests/data` in the build the `verify` step would not find the pcap | `tests/data` is part of the content (as in the payload of `selfinstall`) |
| R123 | low | the temporary directory would stay after an exit or an error | `trap ... EXIT`, a test |
| R124 | low | the output of the file could depend on the build time and the path | the order `LC_ALL=C sort`, no times and no paths: two builds match byte for byte |

Open: the built file was not run on a real system; `release.yml` does not put `dpistack-install.sh` out as a release asset; a run from a pipe gets no menu input; the size of the file is about 400 KB and grows with every slice, it must be updated after any change of `install.sh`, `lib/`, `templates/`, `bin/` and `tests/data/` (the gate will remind).

### 18.21 The full review after slice 30 (v29)

Checked in a sandbox: a real Ubuntu 24.04, a kernel with NFQUEUE, Suricata 7.0.3 from the package, two network namespaces, the real `ips_fw_apply` and `ips_fw_remove` of `lib/ips.sh`. There is no systemd in the sandbox, so the `systemd-run` timer and a reboot were not checked. Go 1.26 from `go.mod` cannot be downloaded in the sandbox: `go vet` and `go test ./...` passed in a temporary copy with Go 1.22 and `golang.org/x/crypto` from the Ubuntu packages.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R125 | high | `install.sh install --set` (and `--config`, `--only`, `--skip`) without a value hung forever: `shift 2` with one argument left shifts nothing | `require_value`: code 2 and a hint; a test with `timeout` (fails on the old code) |
| R126 | high | `uninstall --dry-run` really deleted `dpistack.conf`, the secrets, the state and the copies of the program (`rm` without `run`) and printed "done" | in dry-run only the list of actions, nothing changes; a test |
| R127 | medium | `--dry-run` wrote the hash of a file it did not write: the next real run counted the existing file as hand-edited and did not update it | the hash is not written with `DRY_RUN=1`; a test |
| R128 | medium | the steps of `reconfigure` went in the order of an associative array, not of the pipeline (`access` could run before `suricata`) | `CONFIG_AFFECTED_STEPS` in the order of `STEPS_ORDER`; a test |
| R129 | high | `curl \| bash install` on a live terminal answered "no terminal for the menu": `have_input_source` looked only at `-t 0`, though the menu reads `/dev/tty` | a check of an openable `/dev/tty` (`DPISTACK_TTY_DEV` for tests); three tests, checked on a pseudo-terminal |
| R130 | medium | after a failed switch of the mode the screen re-read the mode at once and erased the error message (the same class as R86) | `load(keepError)`; 12 tests of the screen on `node --test`, a test fails on the old code |
| R131 | medium | a failed rollback service stayed loaded under the same name, and the next `systemd-run --unit=...` refused | `systemctl reset-failed` in `mode_cancel_timer`; a test on the order of calls |
| R132 | low | `tests/ctl_basic.bats` depended on the packages of the host: a real `suricata` package overrode the fake binary | a stub `dpkg-query` in the test |
| R133 | high | the unit of the periodic rules update ran only `suricata-update`: the file was updated, while the running Suricata held the old rules until a restart | `ExecStartPost=-.../dpistack-ctl reload suricata` (the same for native and docker), `step_rules_check` sees an old unit without this line; a test |
| R134 | high | a rebuild of Suricata from source (a new release) ran `make install-conf`, and the stock `suricata.yaml` wiped the rendered one; the protection against hand edits took the stock file for a hand edit and left it | `install-conf` only at the first build, when `suricata.yaml` does not exist yet; a test |
| R135 | medium | `PANEL_SOURCE=prebuilt`: `dpistack reconfigure` from the installed copy did not find the ready binary next to the script, `panel_bin_current` said "outdated", the install failed | without a ready file next to it the installed panel counts as current; a test |
| R136 | medium | a non-numeric choice in the menu (`zz`, `1 2`) reached the arithmetic `$((10#...))` before the check and broke the whole menu with a bash error | the number is checked by a regular expression before the arithmetic; two tests (fail on the old code) |
| R137 | medium | a new pinned version of the metrics backend was written into the state, while the binary was not downloaded again (only `-x` was checked): the old version ran as the new one | on a change of the marker (version or runtime) the binary is downloaded again; a test fails on the old code |
| R138 | high (for tests) | 51 checks of the form `! command` stood not as the last line of a test, and bats silently ignores such a negation: among others "the token and the password are shown nowhere" (alerts, ctl_config, metrics, panel), "nothing was downloaded", "other people's chains are not touched" were not checked | all turned into `if command; then false; fi`; a test in `ci_config.bats` does not let new ones appear; the checks `^curl ` in the metrics tests were narrowed to downloading the backend (before, the broken check itself rescued them, real `curl`s of repository checks fell under the pattern) |
| R139 | high | a change of the runtime (native <-> docker) for suricata, evebox, ntopng, redis did not stop the previous instance: a container survived the move to native (compose no longer describes it, `restart: unless-stopped`), a package unit survived the move to docker, and the new instance could not take the port | `runtime_release_docker` (`compose rm -fsv`, only if the container runs) and `runtime_release_native` (`systemctl disable --now`, only if the unit is active) before the new instance starts; three tests, two fail on the old code |
| R140 | low | the name of a rules source, group or interface that starts with `-` went to `suricata-update` and `ip` as an argument and would be read as an option (a trust border: the panel user calls `dpistack-ctl` through sudo as root) | the first character of a name is a letter or a digit only; a test |
| R141 | low | the log stream of the panel replaced only `\n` in a log line: a lone `\r` also breaks a line in an event stream, and a log line (text from the network gets into the journal) could start its own field `event:` or `id:`; the text of the error in an `error` event was not cleaned at all; the name regular expressions in the panel allowed a leading `-`, while `dpistack-ctl` after R140 refuses | `sseOneLine` for data and for the text of the error; the names in the panel with the same first-character rule; a Go test on five lines with `\r` and `\n` (fails on the old code) |
| R142 | medium | numbers with a leading zero in the menu (`08`, `09`) gave a bash arithmetic error "value too great for base", and `010` chose item 8 (an octal number): the section screen, the quick install (interfaces), the components screen | `10#` in all the places that parse a number; a test fails on the old code |
| R143 | medium | the value of an integer key with a leading zero (`WATCH_DISK_WARN_PCT=08`) passed the check (an arithmetic error in `(( ))` gave "false", that is, "in range"), was saved as `08` and broke later calculations (`dpistack-watch`), and `010` was checked as 8 | an integer with no leading zeros, otherwise a refusal with a clear phrase; a test |

**"Choose yourself" decisions:** Suricata in NFQ mode gets `--user suricata --group suricata` only when the user exists and owns the log directory (the RPM layout, where the unit starts with `--user` anyway); otherwise it stays root, like in the Debian and Ubuntu package where this user does not exist. The queue is bound before dropping privileges: checked with a real NFQUEUE (the process runs as an ordinary user, the queue is alive). `mode ips` warns when there is neither a `drop` or `reject` rule in `local.rules` nor a line in `drop.conf`: it was checked that an `alert` rule does not block traffic. `dpistack-install.sh` and the panel binaries are put into the release with SHA-256 sums and an attestation of the origin. The tests of the panel screens go through `node --test` with no dependencies (fake timers, plain objects instead of elements), in the gate when `node` is there.

**Checked with a real NFQUEUE:** a `drop` rule blocks, a rule without `drop` lets through, with a stopped Suricata `--queue-bypass` lets traffic through, `ips_fw_remove` leaves clean chains.

**Open:** the `systemd-run` timer, a reboot and the order of `dpistack-fw.service` with `reconfigure` at a rollback at boot (the unit stands after `network-pre.target`, not before it, so the rules come up after the network starts) were not checked on a real systemd; on systems without `iptables` (only `nft`) the mode is still unavailable; the `ufw` and `firewalld` rules that `access` added are not removed at a change of the access mode and at `uninstall`; after `uninstall` a running Suricata stays in NFQ mode until a restart; the panel screens were checked without a browser only; a full install on a real system with systemd was not run. (The items about `nft`, the firewall rules, and the NFQ mode after `uninstall` and the unit order were closed in 18.22.)

### 18.22 The review continued and closing the open items (v30)

Checked in a sandbox: a real Ubuntu 24.04, Suricata 7.0.3 from the package (a real NFQUEUE and a real `suricatasc`), a real logrotate, `nft`, `systemd-analyze verify`, Go 1.27.3 (from conda-forge, fits `go 1.26.0` in `go.mod`, the dependencies `x/crypto` v0.58.0 and `x/sys` v0.49.0 from GitHub). There is no systemd as PID 1 in the sandbox.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R144 | high | `logrotate.tpl`: `create 0640 root root` made the new `eve.json` `root:root 0640` after the first rotation: the panel and EveBox lost read access, and Suricata running as `suricata` (RPM) could not open the file again. Reproduced with a real logrotate | `create` with no parameters: the owner and permissions of the former file; a test |
| R145 | high | on Debian and Ubuntu there is no group `suricata`, while the panel and EveBox read `eve.json` through it (sections 4.2 and 9); the installer made `eve.json` `root:root 0640`, so only root could read it | `suricata_log_access`: the group is created (`groupadd --system`), the log directory, if it belongs to root, gets the group `suricata` and `2750` (setgid: files after rotation inherit the group), `eve-log` writes `filemode: 0640` (checked with a real Suricata); a directory of a user (RPM) is not touched; two tests |
| R146 | high | the command socket: the stock `suricata.yaml` creates `/var/run/suricata-command.socket`, while `dpistack-ctl reload` and the rules step waited for `/run/suricata/suricata-command.socket`: reloading the rules on the fly silently did not work (checked: a real Suricata created only the first socket). `postrotate` called a hard-wired `/usr/bin/suricatasc` and swallowed the error (a build from source installs into `/usr/local`), in docker there was no reopening at all, and Suricata kept writing into the renamed file | `unix-command.filename` is taken from `COMMAND_SOCKET` (native `/run/suricata-command.socket`, docker the path in the container); `postrotate`: `command -v suricatasc` with an explicit socket, in docker `compose exec -T suricata suricatasc`; three tests; checked with real `suricatasc -c uptime` and `reopen-log-files` |
| R147 | medium | in NFQ mode the `stats` event has no `capture` block (checked with a real queue: `decoder.pkts` and `ips.accepted` grow): the packets per second chart and `/metrics` showed zeros | `DecodeStats` takes packets from `decoder.pkts` and marks `NoKernel`; the drops are unknown (not zero), `/metrics` does not give the kernel counters and the drop share in NFQ; Go tests on the real form of the event |
| R148 | low | `firstLine` and the output of checks cut Russian text by bytes in the middle of a letter | `cutUTF8`; a test |
| R149 | low | `Save` into `metrics.json` refused forever with `+Inf` in a series (only NaN was filtered) | `Inf` is skipped too; a test fails on the old code |
| R150 | medium | the `ufw` and `firewalld` rules added by the `access` step were not removed at a change of `ACCESS_MODE`, `LAN_CIDR`, `FIREWALL_MANAGE` and at `uninstall` | the added rules are written into the state (`access.fw.rules`, pairs `network,port`); `access_firewall_sync` removes only them, the extra and the outdated; a rule that the administrator already had (`ufw show added`, `--query-rich-rule`) is neither recorded nor deleted; `uninstall` calls `access_firewall_forget`; 4 tests for ufw and 1 for firewalld on stubs with state |
| R151 | medium | after `uninstall` a running Suricata stayed in NFQ mode (`-q 0`) | if the drop-in of the mode existed, after its removal and `daemon-reload` the unit is restarted (except `SURICATA_SOURCE=source`, where the unit is stopped anyway); a test on the order of calls |
| R152 | medium | `dpistack-fw.service` stood after `network-pre.target`: the rules appeared after the network started | `DefaultDependencies=no`, `After=local-fs.target`, `Before=network-pre.target`, `Wants=network-pre.target`, `Conflicts` and `Before=shutdown.target` (as in `systemd.special(7)` for a firewall); `systemd-analyze verify` with no remarks (a static check, the real boot order was not looked at) |
| R154 | low | the panel screens with polling (Overview, Components, Metrics, Alerts): a request in flight at the moment of a click on a range, a change of a check or the return of the tab was not cancelled; an answer to an old request could lie on top of a new one (in Metrics: 24 h was chosen, then the answer for 1 h came), and every such request started its own polling loop, so the screen asked the server twice as often until it was closed | `tickets()` in `modules/poll.js`: only the last request may show the answer, the error and set the next poll; two JS tests fail on the old code |
| R153 | medium | IPS was unavailable on systems without `iptables` | `ips_backend`: `iptables` if there, otherwise `nft`. The table `inet dpistack` with a base chain per hook of `IPS_NFQ_CHAINS` (`priority -10`, `queue num 0 bypass`), created in one transaction (`add`/`delete`/the table), `fw remove` and `uninstall` remove only it; with `iptables` present a leftover `nft` table is removed so that a packet is not queued twice; four tests |

**"Choose yourself" decisions:** the native socket path was chosen to match the stock config and the default of `suricatasc` (not a new directory with `tmpfiles.d`): fewer parts. The priority of the `nft` chain is -10: after connection tracking, before the `filter` rules of the host, like a jump at position 1 with `iptables`. Firewall rules that the administrator already has are counted as theirs and are not deleted, even if they match ours.

**Really checked:** `filemode: 0640` and the socket `/run/suricata-command.socket` were accepted by Suricata 7.0.3 (`suricatasc` answers, `reopen-log-files` works); logrotate with `create` keeps the permissions, with `create 0640 root root` changes them; the syntax of the `nft` table was parsed by a real `nft` 1.0; `go vet` and `go test ./...` on Go 1.27.3; `shellcheck`, `shfmt`.

**Open:** (1) the kernel of the sandbox has no module `nft_queue`, so the `queue` rule in `nft` was parsed, but real queueing of packets through `nft` was not seen (through `iptables` it was seen, section 18.21); (2) a real systemd (the rollback timer, the order of `dpistack-fw.service` at boot, `reconfigure` at a rollback at boot): only a static check of the unit; (3) real containers, a browser and a full install on a live system with systemd were not run; (4) a real `ufw` and `firewalld` were not run, only stubs with state; (5) the keys of `evebox.yaml.tpl` were checked against the official `examples/evebox.yaml` of EveBox (all there), the Redis port 6379 in `ntopng.conf.tpl` matches the Redis unit and docker (`network_mode: host`), this is not a defect; what remains is that `suricata.yaml.tpl` was taken from 7.0 while a build from source takes 8.0 (`suricata -T` insures this); (6) the front end: `app.js`, four screens with polling, `events.js` (the start) and `mode.js` were read, in the other modules (`rules.js`, `configs.js`, `logs.js`, `tests.js`, `ifaces.js`, the end of `events.js`) dangerous XSS sinks, timer and listener leaks were searched for, but they were not read line by line.

### 18.23 One command, root, ports, the version of `suricata.yaml` (v0.21.0)

| No | Severity | What was | What was done |
| --- | --- | --- | --- |
| R155 | medium | `suricata.yaml.tpl` declared `suricata-version: "7.0"`, while a build from source gives 8.0 | the value is taken at render time (`suricata_conf_version`): the series of the installed binary, else the series of `SURICATA_VERSION`, else the series of `SURICATA_STABLE_REF`. The `suricata` step checks the rendered file through `suricata -T` before writing; a refusal stops the step and keeps the previous file |
| R156 | medium | a busy port was only a reason for the preflight to stop | preflight names the owner process and a free port for `--set`; the install and reconfigure menu warns and asks for another port (Enter takes the offered one, `q` keeps). The offered port is free both in the configuration and (with nginx) behind nginx |
| R157 | large | two files: `dpistack` and `dpistack-ctl` | one command `dpistack`; the ctl code is in `lib/ctl.sh`; `dpistack-ctl` stays as a link; sudoers names `dpistack`; the panel user does not get the installer commands through `SUDO_USER` |
| R158 | medium | the command could be run without root | `require_root` at the start of `main` |
| R159 | large | the panel edited `dpistack.conf` only as text, the schema of keys was unavailable | the verbs `settings list/check/set/secret/job`: the schema and values in JSON, a check with the weight of the change (`light` or `heavy`) and busy ports, applying a light change through `reconfigure --light`, a heavy one through the transient unit `dpistack-apply` (`reconfigure -y --force`), secrets from stdin into `secrets.conf` (0600); the `KEY=VALUE` pairs go on stdin (BPF and URL values contain characters that the argument check refuses) |
| R160 | large | no settings screen | the Settings screen: every key of the schema by groups, hints for every key (a test compares them with the schema), advanced keys behind a switch, a check before applying, a busy port with a "Use N" button, a confirmation of widening the access and of a heavy change, the progress of applying by `settings job`; a new stylesheet (side navigation, cards, a light and a dark theme) |
| R161 | medium | the panel has only one mode | `PANEL_MODE=limited` (a unit with `MemoryMax=64M`, `CPUQuota=20%`, 4 log streams) or `unlimited` (no unit budget, 32 streams, the flag `-max-streams`). **Replaced in v0.23.0 by `PANEL_EDITION=full\|lite` and the limits removed** |
| R162 | large | the panel only as a systemd unit | `PANEL_RUNTIME=docker`: the service `panel` in the compose project, the image is built on the host from the binary (`dpistack-panel:<hash>`), `network_mode: host`, `pid: host`, `privileged`, commands to the host through `nsenter` and `DPISTACK_CALLER=panel`; independent of the other `*_RUNTIME`, a test goes through all the 32 combinations |
| R163 | large | only `apt` and `dnf` were supported, other distributions were refused | the families `zypper`, `pacman` (the base tools are installed, the components only in Docker) and `generic` (any Linux with systemd: tools are checked, not installed); a system without systemd is refused with code 3; preflight names the `*_RUNTIME` keys that must be set |
| R164 | medium | documentation: the README and two reports of slice 0 with caveats | `docs/`: install, platforms, deployment, the panel, operations, troubleshooting and the settings reference that `scripts/gen-config-doc.sh` builds from the schema (checked in the gate and in `tests/docs.bats`); the reports `prototype.md` and `real-test-guide.md` removed, the caveats about missing checks removed from the README, `docs/` and this file |
| R165 | small | no files for contributors | `AGENTS.md` (the map of the repository, the rules for agents) and `CONTRIBUTING.md` (the environment, branches, the gate, what a change contains) |

**Checking R155 with real binaries.** The template rendered by `suricata_render_yaml` was run through `suricata -T` on Suricata 7.0.3 (the Ubuntu 24.04 package, the series was detected as `7.0`) and on Suricata 8.0.7 built from the tag `suricata-8.0.7` (the series `8.0`): both accept the configuration ("Configuration provided was successfully loaded"), there are no remarks about outdated keys. Only environment-dependent messages remained: no `ndpi.so` plugin (this build has no nDPI), no `threshold.config` and no rules file. A side finding: Suricata does not compare the value of `suricata-version` with its own version (7.0.3 accepted both `8.0` and `6.0`), so `-T` catches incompatible keys, not the label; the label is set by the installed series for a human reader of the file and for tools.

**"Choose yourself" decisions:** instead of two binaries with common code one command with a restriction by `SUDO_USER` was chosen (the threat model is the same as before: a panel session must not install and remove, and full root on the host it would have anyway through the `sudo` rule on ctl). The panel in a container reaches the host through `nsenter` and names itself in `DPISTACK_CALLER`: this is a restriction for the mistakes of the panel, not a trust border (a process with the right to `nsenter` into the namespaces of the host is root anyway). The panel image is built locally from `alpine` (it has `nsenter` from busybox), so as not to depend on a registry with a project image. A heavy change from the panel is started with `--force`: hand-edited files are overwritten with a backup. The families without project packages (`zypper`, `pacman`, `generic`) get the components in Docker, not guessed package names: this path is the same on any distribution, and the source of truth about the images is one. The settings reference is generated from the schema, so as not to diverge from the program. The old name was left as a link, so as not to break the installed units `dpistack-fw.service` and `dpistack-watch` at `upgrade` (removed in v0.24.0, the `selfinstall` step deletes the leftover link). A free port is searched upward from the busy one, not random: predictable and repeatable.

### 18.24 The listen address, the metrics stack, one command only, the English release (v0.23.0 and v0.24.0)

| No | Severity | What was | What was done |
| --- | --- | --- | --- |
| R166 | medium | `PANEL_MODE=limited\|unlimited` was a way to a lighter panel by limits, which hurt (a killed process at the cgroup limit) or did nothing | `PANEL_EDITION=full\|lite`: the same features and API, a different look; the unit limits and `-max-streams` removed; the edition is chosen by the server by serving `full.css`/`fx.js` or `lite.css`/`nofx.js` (`edition_test.go`); an old `PANEL_MODE` in `dpistack.conf` is dropped at load (a bats test that fails without the drop) |
| R167 | medium | the panel and the program texts were Russian | the program is English only (the strings of the shell, Go and the interface); the tests were updated with the same phrase maps so that a message and its assertion cannot drift; the README and the guides come in two languages (`tests/docs.bats`) |
| R168 | medium | a user could not put the panels on one address of the host: only `127.0.0.1` or every address | `BIND_ADDR` (4.3): one `access_effective_bind_host` decides the bind of every web service, `access_policy` makes a non-loopback address count as `lan` for the panel, `config.sh` requires the access confirmation, `preflight` refuses an address that is not the host's (code 3), the quick install lists the host addresses from `ip -o -4 addr`; seven tests in `tests/access_step.bats` |
| R169 | medium | the metrics stack was only a storage | node_exporter and Grafana as separate optional components (`NODE_EXPORTER_*`, `GRAFANA_*`, steps `nodeexp` and `grafana`, native or docker); the storage scrapes node_exporter (`node` job), Grafana gets the storage as the default data source; binaries are checked with a sha256 (node_exporter pinned in the code, Grafana by the vendor `.sha256` file at install time); ten tests in `tests/monitoring_step.bats` |
| R170 | low | a part that was turned off kept running: the step compared only the marker | `nodeexp` and `grafana` stop an installed part when its `*_ENABLE` is `no` (a test fails without it) |
| R171 | low | the test hook that makes every argument a verb leaked into the child installer that `reconfigure` starts, which then refused its arguments | `DPISTACK_VERBS_ONLY` is read once and unset in `install.sh` |
| R172 | low | the old second command name `dpistack-ctl` stayed as a link | removed from the code, the tests, the guides and the sudoers rule; the `selfinstall` step deletes a link left by an earlier version (a test) |

Open (v0.24.0): the `full` design was not rendered in a browser (there is none in the sandbox), so the look is unchecked; the Grafana tarball version (12.2.0) and its download from `dl.grafana.com` could not be verified from the sandbox (the host is not reachable there), and the sha256 comes from the vendor file at install time, not from a pin; node_exporter and the docker images of the new components were not run; a real systemd, a real `ip addr` with several addresses and a listen address on a live LAN were not exercised (stubs only).

### 18.25 Choosing parts and asking more (v0.25.0)

The owner asked for four things: every part (nDPI, Suricata and so on) selectable on its own, an exit in every item and sub-item, a confirmation before every action, and `sudo ./install.sh install` asking about everything that can be asked, not only the important keys. "Choose yourself" decisions:

| id | decision |
| --- | --- |
| C1 | One `*_ENABLE` key per part (`SURICATA_ENABLE`, `RULES_ENABLE`, `EVEBOX_ENABLE`, `NTOPNG_ENABLE`, `PANEL_ENABLE`), default `yes`, so an existing config and `install -y` behave as before. The steps of a switched-off part are wrapped in `install.sh` (`step_component_enabled`): `check` returns 0, `apply` does nothing, the plan prints `no changes`. No step file was edited. |
| C2 | Switching a part off does not remove it: removal of installed software stays with `uninstall`, so a mistaken keypress cannot delete data. The menu says so. |
| C3 | `SURICATA_ENABLE=no` with `NDPI_ENABLE=yes` or `RULES_ENABLE=yes` is a validation error with code 2 (nDPI is a plugin of Suricata, the rules are loaded by it); the menu switches both off by itself. |
| C4 | The questions of "install" are the guided setup, offered first on a fresh install and available as `w`; "Quick install" stays as the short path. Keys that cannot matter (a part is off, a mode is not chosen) are not asked, so nobody answers questions with no effect. |
| C5 | Confirmations are in the menu only; `-y`, `--set` and the verbs ask nothing. The test hook `DPISTACK_MENU_ASSUME_YES=1` keeps the older tests, which feed fixed input lines, valid; the new behavior has its own file. |
| C7 | The guided setup asks the `components` group too (runtime, source, version, edition, `PIN_VERSIONS`); only the on/off switches are left to the component screen. A test checks that every group is reached (`tests/menu_confirm.bats`). |
| C8 | A part that is off leaves no trace in the rest of the system: `access` (nginx server blocks, self-signed certificates, SELinux ports, firewall rules) covers only the parts that are on (`access_services`), the preflight does not check their ports, `status`/`health` do not list them (`component_listed`) unless the unit is installed anyway, so the watchdog and the panel stay green. |
| C9 | `METRICS_BACKEND` other than `none` needs `PANEL_ENABLE=yes` (the backend scrapes the panel): validation error with code 2, the scrape file keeps its single panel job. |
| C6 | The first key of the `components` section is now `SURICATA_ENABLE`: two old menu tests that picked key 1 or key 9 by number were updated (the allowed list and a larger key count). |

### 18.26 Starting the installer and naming Suricata with nDPI (v0.25.1)

| id | decision |
| --- | --- |
| D1 | `sudo ./install.sh` with no command already opened the install menu on a terminal (the usage is printed only when there is no terminal, so that nothing is installed by accident). It stays; the `install` command stays for scripts and `curl \| bash -s -- install -y`. |
| D2 | An option may be the first argument: `install.sh --fast` means `install.sh install --fast`; `-h` and `--help` are still the help. |
| D3 | `--fast` is the short questionnaire (`menu_quick_install`: interfaces, Suricata source, access, metrics, panel) instead of the guided setup that asks every setting. Three ways in: the guided setup (default), `--fast`, `-y` (no questions). `--advanced` stays: it controls which keys the section screens list. |
| D5 | Issue 45 (the weekly check of the pinned Suricata failed): the build was fine, but `suricata -T` of Suricata 8.0.7 exits with 1 when the rule file does not exist yet, and `suricata_validate_render` ran without `-S /dev/null` while the rules step comes after the suricata step. A fresh install would have failed the same way, not only the CI check. Reproduced by building 8.0.7 with the installer, fixed by `-S /dev/null` (only the configuration is tested, the same as the last line of `scripts/suricata-build-check.sh`), test `issue 45` in `tests/suricata_step.bats` (it fails without the fix). |
| D4 | nDPI is a plugin of Suricata, so the menu shows it as a sub-item "with the nDPI plugin" of Suricata, the summary says "Suricata: source, with the nDPI plugin: yes". The keys `SURICATA_ENABLE` and `NDPI_ENABLE` and the step names `suricata` and `ndpi` are unchanged: a config, a script or the build check keeps working. nDPI cannot be on while Suricata is off (18.25 C3). |

### 18.27 The first real install on Debian 13 (v0.25.2)

The owner ran `sudo ./install.sh` on a real Debian 13 host (Go 1.24.4, Docker already running, a container on port 3000) with every component on the docker runtime and reported: there is no `dpistack` command, \"Configure\" in the control menu ends with \"configuration finished with code 1\", the screen says \"with the nDPI plugin: yes\" while the preflight says the plugin is missing, and the panel at `http://192.168.1.156:9800/` refuses the connection. The causes were found in the code and each has a test.

| id | finding and decision |
| --- | --- |
| D6 | **No `dpistack` command, no panel on 9800: one cause.** The install stopped in the preflight (exit 3: Go 1.24.4 is older than 1.26.0 and there is no ready panel binary; the docker runtime of Suricata cannot carry the nDPI plugin). The `selfinstall` step came after the preflight, so nothing was installed: no command, no panel, nothing listening on 9800. `ERR_CONNECTION_REFUSED` was correct. Fix: `install_command_early` runs `selfinstall` before the preflight (it depends on no component; a failure is only a warning), and a failed preflight prints that the answers are saved and the next command (`sudo dpistack install`). |
| D7 | **\"another dpistack instance is running\" in the control menu.** `install.sh install` takes the lock with `flock` and keeps it for the whole run; the control menu runs `cmd_reconfigure` in a subshell of that same process, which called `lock_acquire` again: a new open file description, so `flock -n` refused the process that owned the lock. Fix: the plain variable `DPISTACK_LOCK_HELD` (inherited by a subshell, never by another process) makes the second call a no-op. A real second instance is still refused, and the message now names its pid (the pid is written into the lock file as a hint; the `flock` decides). The path \"Installation found -> 1) Configure\" never hit this, only \"3) Control menu -> 1) Configure\". |
| D8 | **A config is not an installation.** `dpistack.conf` is written before the preflight, so after a failed preflight the next run said \"Installation found\" and the control menu showed \"no data\". Now `state_install_finished` (the marker `install.finished=yes`, written at the end of `install`; an install of an older version counts by a done `verify`, `suricata` or `panel` step) decides: without it the screen says \"Saved config found, the install did not finish\" and offers \"Install with the saved config\" in place of \"Apply the current config again\". |
| D9 | **The panel needs no Go on the host when Docker runs.** The Go of Debian 13 is 1.24, the panel asks for 1.26, and the owner had chosen `PANEL_RUNTIME=docker`. Decision: when the host Go is missing or too old and `docker info` answers, the panel is built by `docker run golang:<major.minor of go.mod> go build ...` (sources mounted read-only, caches and result in one scratch directory), then installed and put into the panel image as before. Without a usable Docker the preflight still stops with code 3 and names both ways (a Go of the needed version, or Docker, or a ready binary). Alternatives not taken: a ready binary downloaded from a release (no release carries one yet for a clone), a Go downloaded by `GOTOOLCHAIN` (needs the same network and runs unverified code on the host). |
| D10 | **nDPI with the docker runtime of Suricata.** The image has no plugin (5.1, 18.17), and the preflight said so only at the end. Decision: the conflict is settled where the key is set: choosing `SURICATA_RUNTIME=docker` in the menu or the guided setup switches `NDPI_ENABLE` to `no` and prints why; switching the plugin on while the runtime is `docker` is refused with the way out (`SURICATA_RUNTIME=native`). `install -y --set SURICATA_RUNTIME=docker` with `NDPI_ENABLE=yes` stays an error with code 3: a script that asks for both gets told, nothing is changed silently. Building a Suricata image with the plugin is not done: it would need the image build of Suricata from source on every host. |
| D11 | **The busy port 3000** (a container on the host) was handled correctly: the install asked for another port and took 3001. No change. |

Checked by tests: `tests/dpistack_cmd.bats` (the control menu opened from the install menu can Configure; the saved-config screen), `tests/panel_step.bats` (a failed preflight leaves the command and the saved config and names the next command; a Go older than `go.mod` passes with Docker and builds in `golang:1.26`; a failing container build installs no panel), `tests/menu_confirm.bats` (the docker runtime switches the plugin off). The mock `docker` answers `info` and the build container.

Not checked in a sandbox: a real `docker run golang:1.26` build (the sandbox has no Docker), the panel container on a real host, the reachability of port 9800 from another machine. These are for the owner's next run on the stand (section 11, the platform matrix); the result goes back here.

### 18.28 Uninstall, the version in the panel, updates from the panel (v0.26.0)

Requests of the owner: remove the whole program from the menu with every leftover and without touching anything else; show the version in the corner of the panel, make it glow when an update exists and ask on a click; change the same settings in the panel as in the menu and the terminal.

| id | decision |
| --- | --- |
| D12 | **Uninstall.** The removal already existed; the audit found what it left: every container of the docker runtime except the panel (the compose project was never taken down), the compose file, the images, the Grafana and EveBox data on `--purge`, the apt/dnf repository files, the nDPI plugin and the source builds, `metrics.token`, the Grafana files that kept `/etc/dpistack` from being removed, and the logs. All of it is removed now and the list of what is never touched is written in 5.7. The first screen of an existing installation got \"4) Uninstall\". Tested: the compose `down` call, the image `rm` of only `dpistack-panel:*`, no `prune`/`volume rm`/`network rm`/`docker rm`, a foreign file next to ours survives, a plain uninstall keeps data and logs. |
| D13 | **Where the update is checked.** In the panel (Go, `internal/update`), not by root: it reads the public \"latest release\" document of `FlexEbat/dpistack`, caches it for 6 hours, never fails a request (a failed check is a tooltip), and can be switched off with the flag `-update-url off`. A repository without a published release shows no update, so a version is published as a GitHub release with the tag `vX.Y.Z`. |
| D14 | **How the update is installed, and the price.** The panel threat model of 4.5 said that a stolen panel session cannot install anything. The Update button needs one exception, which is as narrow as it can be made: `self-update run` takes no argument, asks the release server itself, accepts only a tag that is higher than the running version, downloads the archive GitHub builds for that tag over https, refuses an archive with an absolute or `..` path or whose `lib/common.sh` does not carry that version, and then runs the NEW installer on the saved config (`install -y`, values kept) as the transient unit `dpistack-selfupdate`, because the panel restarts in the middle of it. `self-update apply` is refused to the panel user. What remains: a session that is signed in can start an update to a newer official release (the person confirms in the dialog; the request also needs the CSRF token), and the trust is in the repository owner and TLS, there is no signature check. Alternatives not taken: a signed archive (nothing signs the releases yet), an update only from the terminal (the owner asked for the button). |
| D15 | **The badge.** A pill in the top right corner of every screen: the version, quiet. With an update it glows (a slow box-shadow pulse; the lite edition and `prefers-reduced-motion` get a plain bold outline instead). A click opens a dialog with the two versions and \"Update\" / \"Not now\"; \"Not now\" only closes it, the badge keeps glowing. After \"Update\" the dialog follows the unit and reloads the page when the panel is back with the new version. |
| D16 | **Settings in the panel.** Already there since v0.22.0 (the Settings screen is built from the schema that `dpistack settings list --json` serves, 85 keys with the secrets as write-only fields), so nothing new was built for it; the one gap found is closed: `settings check` now refuses `SURICATA_RUNTIME=docker` with `NDPI_ENABLE=yes` at the check (the menu already switched the plugin off, D10), where the panel used to find out at the end of a heavy apply. |

Checked by tests: `panel/internal/update` (versions, cache, failures, a foreign release page dropped, off), `panel/internal/api/version_test.go` (sign-in, CSRF, 409 when current, the verb is called only when newer, the job), `panel/web/test/version.test.mjs`, `tests/self_update.bats` (check, no download when current, apply keeps the saved values and installs the new copy, a wrong version and an unsafe path are refused), `tests/uninstall.bats`, `tests/ctl_settings.bats`.

Not checked in a sandbox: the real GitHub release document and archive, a real update of a running panel (the restart in the middle), the glow in a browser, uninstall of a real docker stack. These are for the next run on the stand.

### 18.29 Which confirmations stay (v0.26.1)

The owner asked in v0.25.0 for a confirmation before every action and now asked to re-examine them, since some are unnecessary: in a real run one setting cost two prompts (the value, then \"Set X = Y?\"), the guided setup asked \"Go through this group?\" eight times, and a read-only check asked \"nothing is changed, continue?\".

**Scope (the owner's correction).** Only the installer's menu and the control menu were reviewed. The panel's own confirmations (stop and restart, Save and apply, IPS and back to IDS, rules update, test run, reload, and the rest) are unchanged.

**Rule (decision, \"choose yourself\").** A question is asked only when the action (a) loses work that cannot be recovered, (b) interrupts a running service or traffic, (c) changes who can reach the host or what runs as root, or (d) removes or overwrites something that was there before. It is never asked when the person has just stated the intent (typed the value, pressed the button named for the action), when the action only reads, or when the change is a draft that is shown and confirmed once at Apply. One confirmation per commit, not one per keystroke.

| place | before | now |
| --- | --- | --- |
| menu: set a key, a secret, reset to default (two editors) | asked | not asked: a draft edit; `d` shows the diff, `r` drops it, Apply confirms |
| menu: switch a part on/off | asked | not asked; the side effect (\"nDPI and the rules go off with it\") is printed as a note |
| menu: panel password typed twice | asked \"use this password?\" | not asked, two equal entries are the confirmation; a mismatch is refused |
| menu: check the system, show the plan | asked \"nothing is changed\" | run at once |
| menu: load values from a file | asked | not asked: they become edits of the draft |
| menu: save the config to a file | asked | asked only when the file exists (`[y/N]`, overwrite) |
| guided setup: each group, and leaving with `x` | asked | not asked: `s` skips a group, `x` keeps the answers so far |
| control menu: run the check tests, change the panel password | asked | not asked: the item was chosen by number |
| **kept** | | install/apply summary, `q` with edits, `r` discard, uninstall (`remove`), upgrade, the first-screen question, continue the draft; the panel's confirmations, all unchanged |

The test hook `DPISTACK_MENU_ASSUME_YES` is unchanged. Tests: `tests/menu_confirm.bats` (the new behavior, 23 tests).

### 18.30 The install report on Debian 13 (v0.26.2)

The owner sent a report of an install on Debian 13 (x86_64, 2 CPUs, v0.26.1). Three defects were confirmed in the code and are fixed, each with a test.

| id | finding and decision |
| --- | --- |
| D17 | **nDPI silently off on Debian 13.** `pkg_rust_obtainable` counted only an installed Rust or versioned `rustc-1.N` packages; Debian 13 has neither on a fresh host but offers `rustc` 1.85 as the ordinary package. The source build was dropped for the distribution Suricata and `NDPI_ENABLE` went to `no`. Decision: for apt the candidate of `rustc` (`apt-cache policy`, an epoch is allowed) counts when it is at least 1.75, and `pkg_select_rust` installs `rustc cargo` then (the default package is preferred to a `rustc-1.N`). Tests: `families.bats`, `hardening.bats`. |
| D18 | **Suricata started before any rules existed.** The Debian package ships no `suricata.rules`, `suricata.yaml` lists it, so the service exited and systemd stopped retrying; the `rules` step comes after the `suricata` step and needs the installed Suricata, so the order stays. Decision: before `enable --now` the step creates a placeholder rules file (a comment line) when there is none; a real file is never touched; `step_rules_check` treats the placeholder as "no rules yet", so `suricata-update` always replaces it. The mock `systemctl` can now fail a start while a file is missing (`MOCK_SYSTEMCTL_NEED_FILE`). Tests: `suricata_step.bats`, `rules_step.bats`. |
| D19 | **The BitTorrent self-test could not pass without nDPI.** The sample pcap is a flow between two private hosts; the ET P2P rules are `$HOME_NET -> $EXTERNAL_NET`, so with the default (or the real) `HOME_NET` they cannot match. Decision (the production ruleset stays under test, no private fallback rule): the offline replay config sets `HOME_NET` and `EXTERNAL_NET` to `any`. Checked with a real Suricata 7.0.3: the same rule gives 0 alerts with the default networks and 2 with `any`. Test: `test_cmd.bats`. |

Not done, open for the next slice: the HTTPS self-test with empty `tls` events (the report's hypothesis about a post-quantum ClientHello is not confirmed; it needs the real host and the curl check from the report), a busy `NTOPNG_PORT` that only warns, the non-interactive saved-config option 2 (`ACCESS_CONFIRM`), the installed copy of `dpistack` that has no `panel/` for a re-run, and a wait for the dpkg lock (a flag on every `apt-get` call changes the commands the tests match, so it needs its own change).

Not checked in a sandbox: the real Debian 13 package candidates and the ET P2P ruleset replay (the sandbox cannot reach the rules server).

### 18.31 The remaining items of the Debian 13 report and the design (v0.27.0)

| id | finding and decision |
| --- | --- |
| D20 | **A busy `NTOPNG_PORT` was only a warning**: pressing `q` ("keep") let the menu start an install that the preflight stopped on anyway. Decision: a kept busy port does not start the install; the menu says so and returns to the main screen. Test: `menu.bats` |
| D21 | **Saved config, option 2, failed on `ACCESS_MODE=lan`** until `--set ACCESS_CONFIRM=yes` was added. Decision: the menu asks once ("reachable from more than this machine"); declining changes nothing; an access that was already applied is not asked again. Test: `menu.bats` |
| D22 | **The dpkg lock** (another apt process) failed the ntopng step. Decision: `apt-get install` and `update` wait up to 5 minutes through a temporary `APT_CONFIG` with `DPkg::Lock::Timeout "300"` (the command lines stay as they were); an `APT_CONFIG` of the owner is not touched; the file is removed after the call. Tests: `hardening.bats` |
| D23 | **A re-run from the installed copy** (`/usr/local/sbin/dpistack`) had no `panel/` next to it. Decision: the message now says to run `install.sh` from the clone or to set `DPISTACK_ORIGIN_DIR`. The installed copy stays a controller; `/usr/local/sbin` is not in a user's PATH on Debian, so `sudo dpistack` is the documented way |
| D24 | **The design** follows the owner's `SKILL.md` (9.1). Tests: `design.test.mjs` (the rules), `chrome.test.mjs` (the menu and the reveal), `static_test.go` (the fonts) |

The first push of v0.27.0 failed the gate at `scripts/panel-budget.sh` (212 KB against 150 KB): the script counted everything under `panel/web`, fonts and tests included. Decision: it now counts what the panel serves (no tests) and checks the fonts against their own 64 KB limit; the code is about 127 KB. `go vet` and `go test ./...` were run locally (Go 1.27.3) and pass.

Still open: the HTTPS self-test with empty `tls` events (the hypothesis about a post-quantum ClientHello is not confirmed; it needs the real host and the curl check from the report), a branded 404, and the look itself: **the design was not rendered in a browser** (there is none in the sandbox), only the rules were checked by tests, so the first look at the panel is the owner's.

Tests to run for v0.27.0: `bats tests` (or `scripts/gate.sh`: shfmt, shellcheck, the security checks, the bundle check, the bats suite, `go vet` and `go test ./...` in `panel/`, `node --test panel/web/test/*.test.mjs`); the focused ones are `tests/menu.bats`, `tests/hardening.bats`, `tests/families.bats`, `tests/rules_step.bats`, `tests/suricata_step.bats`, `tests/test_cmd.bats`, `panel/internal/api` (`static_test.go`, `edition_test.go`) and the three `.mjs` design and chrome tests. By hand on the host: the panel in both editions at 1440 and 390 px wide (the floating bar, the menu, the reveals, the focus ring by keyboard), with `prefers-reduced-motion` on, and a font load check (`/fonts/geist.woff2` answers `font/woff2`).

### 18.32 The install log and CI/CD review of 2026-11-02 (v0.30.1)

The owner asked to read the whole log of a real Debian 13 install and to review all CI/CD, fix every error first, check on the stand, and only then continue development.

| id | finding and decision |
| --- | --- |
| D25 | **The log is of v0.29.1, not of the current code.** The directory `dpistack` already existed (`git clone` said so), so the run used an old copy. Its three failures (Suricata printing its usage and exiting with 1, EveBox `unable to open database file` (code 14), `TEST_BT_LIVE=yes, but tcpreplay is not installed`) are exactly the causes fixed in v0.29.2 and are present in the tree (`--af-packet` in `templates/suricata.service.tpl`, `evebox_prepare_data_dir`, the `tcpreplay` install in `step_verify.sh`). The HTTPS self-test failure (no `tls` event) followed from Suricata not running; it is not counted as a separate bug until it repeats on v0.30.1 with Suricata up. The old EveBox lines `Failed to load configuration ... /etc/evebox/evebox.yaml` and `Failed to write bookmark` in the journal come from boots of earlier installs and do not occur in the run of 2026-11-02 |
| D26 | **A dropped connection stopped the whole install.** `git clone https://github.com/ntop/nDPI.git` failed with `curl 92 HTTP/2 stream ... CANCEL` after 4 minutes and the `ndpi` step failed. Decision ("choose yourself"): `git_clone_retry` in `lib/common.sh`: `git -c http.version=HTTP/1.1 clone`, 3 tries, a pause of 5/10 s (`DPISTACK_RETRY_DELAY`), the half-made directory removed between tries; used for nDPI and Suricata. Tests: `tests/ndpi_step.bats` (a clone that fails once and then works, a clone that never works returns the git status after exactly 3 tries) |
| D27 | **Pins.** The weekly check built `suricata-8.0.8` and opened issue 60 ("verified: raise SURICATA_STABLE_REF"). Decision: raised to `suricata-8.0.8`, the nDPI pin is unchanged (4.14) |
| D28 | **Messages left as they are** (not errors): `Bindings changed` from `cbindgen --verify` during the Suricata build (the make rule ends with `|| true`, the build and `suricata -T` pass); `Source index does not exist, will use bundled one` from `suricata-update` before `update-sources`; `FIREWALL_MANAGE=auto, but neither ufw nor firewalld was found` (Debian 13 has neither; with `ACCESS_MODE=lan` the ports are then limited by the bind address only) |

CI/CD review (all runs through the GitHub API, 2026-11-02): the last runs of `ci`, `security`, `release` and `suricata-watch` on `main` (`a25cf00`) are green; code scanning has no open alerts; `main` is protected. The only red runs in the recent history are `ci` on `dev` for `77604ba` (v0.29.1, 2026-10-31) and `7ca3217` (v0.29.0), both fixed by the next commit and green since; cancelled runs are the ones replaced by a newer run of the same branch (concurrency) and one `release` of v0.29.2 that was re-run green. Open: issue 60 (done here) and Dependabot PR 54 (`upload-sarif` 4.39.0 -> 4.39.1).

Still open: the HTTPS self-test and the whole install have to be repeated on the real Debian 13 stand with v0.30.1 (the owner tests).

### 18.33 `LAN_CIDR` as a list (v0.31.0)

The owner connected from a mobile network through a WireGuard server that runs in Docker on the dpistack host and got `{"error":"access from this address is forbidden"}` from the panel, while another panel on a neighbouring port opened. The cause is by design: the panel checks the client address itself (section 8) and the client was the WireGuard container (a Docker bridge address such as `172.x.x.x`, or the tunnel address), outside the single network `LAN_CIDR` held. The other panel has no address check of its own, and this host had no firewall tool (`FIREWALL_MANAGE=auto` found neither ufw nor firewalld).

| id | decision |
| --- | --- |
| D29 | **A list, not a second key.** `LAN_CIDR` is `auto`, one CIDR, or a comma-separated list (`auto,172.18.0.0/16`); the schema pattern `^(auto\|cidr)(,(auto\|cidr))*$` refuses an empty or bad element (code 2). Everything that used the one network follows the list: `-lan-cidr` of the panel (`auth.NewPolicy` parses every element, `Allowed` is true for any of them, spaces around a comma are ignored), one `allow` line per network in the nginx blocks, one ufw/firewalld rule per network and port (the state keeps `cidr,port` pairs, so dropping a network from the list takes its rules out), the access plan line |
| D30 | **`auto` inside the list** is the network of the default-route interface, so the usual setup stays `auto,<the Docker or tunnel network>`. A list where `auto` cannot be resolved keeps the other elements; with nothing left the closed fallback of 4.8 applies (the panel lets in `127.0.0.1` only) |
| D31 | **Which network to add.** The one the panel sees as the client: for WireGuard in Docker the bridge network of the container (`docker network inspect` of its network) or, when the container does not translate addresses, the tunnel subnet. A wide range such as `0.0.0.0/0` is not recommended: the panel then accepts every address and, without a firewall, so do ntopng and EveBox |

Tests: `panel/internal/auth/auth_test.go` (a list, spaces, outside every network, a list in nginx mode, an empty or bad element), `tests/access_step.bats` (one `allow` per network, bad list code 2), `tests/panel_step.bats` (the unit gets the list, `auto` resolved), `tests/firewall_rules.bats` (a rule per network and port, a dropped network is taken out).

### 18.34 The Update button on a `lan` installation (v0.31.1)

The audit log of 2026-11-03 showed `POST /api/update` and then `cli self-update apply` ending with `error` (exit 2), after which the owner restarted every component by hand. The watchdog had also reported `ntopng.process: inactive` and `ntopng.port: port 3001 is not listening` about half a minute before the update; the update never reached any step, so it did not stop ntopng (the cause of that stop is not in the files sent: the journal of `ntopng` is needed).

| id | decision |
| --- | --- |
| D32 | **Cause.** `selfupdate_apply` ran the new installer as `install.sh install -y`. In non-interactive mode `config_validate` refuses `ACCESS_MODE` other than `localhost` (or a non-loopback `BIND_ADDR`) without `--set ACCESS_CONFIRM=yes` and the installer exits with 2 before the preflight. `reconfigure` already handled this (`ctl_cmd_reconfigure` passes the confirmation when the mode is the applied one); `self-update` did not, and its test ran only on `localhost`, so it passed |
| D33 | **Fix.** `selfupdate_access_unchanged` compares `ACCESS_MODE` and `BIND_ADDR` of the saved config with `applied.ACCESS_MODE` and `applied.BIND_ADDR` in the state; equal means already confirmed and `--set ACCESS_CONFIRM=yes` is added. A mode that was edited by hand after the last apply (or a state without a record) is not confirmed: the update still stops with exit 2 and the message, because an update must not widen access |

Tests: `tests/self_update.bats` (an update on a `lan` installation passes; a mode edited after the last apply stops with 2). The new test fails on v0.31.0 and passes now.

### 18.35 Slice 37 (first part): the corner, Build info and the look (v0.32.0, v0.32.1)

**Status:** a part of slice 37, done. The rest of slice 37 is in 18.37.

The owner sent screenshots of the panel (nine, all reviewed), mockups of the corner (`NEED.png`) and of the Build info window (`NEED2.png`), and asked to follow the unslop rules (github.com/heydamir/unslop) and to write only in English.

What the review found, and what was done:

| id | finding | decision |
| --- | --- | --- |
| D34 | The menu labels were centered, so the icons stood in different columns (the shared `button` rule centers, the menu rule did not override `justify-content`) | `justify-content: flex-start` and the 8px radius in the menu; a test pins it |
| D35 | Pills everywhere (inputs, buttons, menu), gradient heading, a drifting point field behind the content | Controls and menu use the 8px radius, the heading is a solid colour, the canvas is removed from the page. `fx.js` and `nofx.js` stay because the edition switch (`api.go`) and its test serve them; with no canvas `fx.js` does nothing. The old rule "a gradient fills the heading" (9.1) is replaced by "no gradient anywhere" in `design.test.mjs` |
| D36 | The same sentence under every page title | Removed: the title is enough |
| D37 | The Rules screen showed `file missing: disable.conf` on an installation that never disabled a rule | A list file that does not exist is an empty list (`rules.js`) |
| D38 | Dates used the `ru-RU` locale | `en-GB` |
| D39 | The corner clipped "Sign out" at a medium width | The header wraps and the corner may wrap; on a narrow screen only the icons of the chips remain |
| D40 | **The corner.** Choose yourself: Translation (a placeholder: a button that says "Translation is not available yet"), the version chip (lit with a coloured border when an update exists, no glow), GitHub (a link to the repository, no star count: the panel does not call out), Exit (an icon button). Telegram, the crown, the heart and the sparkles of the mockup are not in dpistack and are not added |
| D41 | **Build info.** A click on the version always opens the window: the update banner (with Update and Not now, the confirmation of before) only when a newer release exists, then Version, Build time, Commit (12 characters, copy button), Runtime, Latest release, and the links to GitHub and the releases. The backend and frontend commits of the mockup are one commit here (one repository, one binary). `GET /api/version` returns a `build` object (`commit`, `time`, `go`, `platform`; empty fields are left out) |
| D42 | **Where the commit comes from.** `BUILD_INFO` (`commit=`, `date=`) is substituted by git in `git archive` tarballs (`.gitattributes`: `export-subst`), written by the release workflow into the archive, and read from the checkout when there is a `.git`. `panel_ldflags` (`lib/step_panel.sh`) turns it into `-X main.buildCommit` and `-X main.buildTime` for the host build and the container build; the release workflow stamps the ready binaries. A missing or unsubstituted file stamps nothing and the window shows fewer rows |
| D43 | **No external address in the page.** `tests/settings_ui.bats` forbids `href="https://..."` in `index.html`; the GitHub and Releases links carry `data-repo` and `app.js` sets the address from the constant `REPO_URL` (the first v0.32.0 commit put the addresses in the HTML and the gate failed) |
| D44 | **Audit in words.** `describe` (`modules/audit.js`) turns the recorded action (a route template such as `POST /api/components/{id}/{action}`) and the target path into "Restart ntopng", "Stop suricata", "Sign in", "Sign out", "Update the panel", "Change password"; an entry it does not know keeps the recorded action. The filter "action contains" still searches the recorded text |
| D45 | **Forms.** A form used as a toolbar (Account, Audit) has its own padding, and its text and password fields grow (`flex: 1 1 12rem`), so a placeholder is no longer cut |

Not done yet, on purpose: the audit screen shows route templates (`/api/components/{id}/{action}`) as the action, the Account and Audit forms still sit in one rounded toolbar each, and the Overview has no chart. They are the next pass (the owner has not seen the first one). The look of the new corner was not checked in a browser (there is none in CI, 9.1); it is checked by the stylesheet rules and the unit tests.

Tests: `panel/web/test/version.test.mjs` (the rows, the time), `panel/web/test/design.test.mjs` (no gradient, controls not pills, menu left aligned), `panel/internal/api/version_test.go` (the `build` object), `tests/panel_step.bats` (`panel_ldflags`).

Summary of 2026-11-03 (v0.31.1, v0.32.0, v0.32.1): the Update button works on `lan` installations (D32, D33); the corner has Translation (placeholder), the version chip, GitHub and Exit, and the Build info window shows the build and the update banner (D40 to D42); the look follows the unslop rules (D34 to D39); the Rules screen works on a fresh install; the Audit screen is readable (D44). Not done: a chart on the Overview, the review of the look in a real browser, the cause of the ntopng stop seen in the log (the journal of `ntopng` is needed).

### 18.36 Slice 36: backup and restore (v0.33.0)

**Status:** done.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R173 | high | `suricata -T` would have checked the restored `suricata.yaml` and `local.rules` one at a time, so two files that are valid alone and wrong together could pass | `suricata_check_set` takes the candidate `local.rules` as a third argument and a restore checks the pair; a test (`restore that fails suricata -T leaves every old file`) |
| R174 | high | a hand-made archive could carry an absolute path, `..`, a link or a name outside the list and write elsewhere when unpacked | the entries are listed and refused (exit 3) before anything is unpacked, only `manifest.json` and `files/<known name>` as plain files are accepted, the manifest is checked against the sums; tests |
| R175 | high | the panel could name any path and so make root read or write it | for the panel `--out` and any argument that is not a bare `*.tar.gz` name give exit 5; tests in `backup.bats` |
| R176 | medium | the dry run diff of `users.json` would show password hashes in the panel | it is shown as `changed: users.json (not shown)`; a test |
| R177 | medium | a bare `POST .../restore` would replace the configs without a preview or a confirmation | the body must say `dry_run` or `acknowledged`, otherwise 400, ctl is not called; a test |
| R178 | medium | the download could follow a symlink out of the archives directory | `Lstat` and a regular file only; a test with a link to a secret |
| R179 | low | a failed write in the middle of a restore would leave a mix of old and new files | the previous files are copied first and put back on a failure; a test of the refusal path |

Open: the look of the Backups screen was not checked in a browser; a restore onto another host was not tried (`IFACES` may name an interface that is not there, `users.json` carries the old accounts); the panel cannot upload an archive; `reconfigure` after a restore is a manual step; the archives live in the state directory that `uninstall` removes (copy one away with `--out` or Download); a restore replaces several files one after another under one lock, it is not one atomic step.

Decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D46 | **What is in the archive.** `dpistack.conf`, `suricata.yaml`, `evebox.yaml`, `ntopng.conf`, `local.rules`, `enable.conf`, `disable.conf`, `modify.conf`, `drop.conf`, `users.json`: the files that exist. `secrets.conf` is not in it (the tokens are the owner's own and should not travel in an archive that the panel can download); enter them again after a restore on a new host. Exceptions and panel state of the slice text do not exist yet |
| D47 | **Format.** `manifest.json` (`format 1`, `program`, `created`, `files[{name, sha256, mode, size}]`) and `files/<name>`; owner 0, no extended attributes. Only these names are accepted on read; an entry that is not a plain file, an absolute path, `..` or a name outside the list gives exit 3 before anything is unpacked into place |
| D48 | **Where.** `/var/lib/dpistack/archives/` (0750 `root:dpistack`, archives 0640), apart from `backups/` which holds the single copies made before a file is replaced. `uninstall` removes the state directory, so the documentation says to copy an archive away (`--out`, Download) |
| D49 | **Restore.** Verify the archive, then check what would be left: the schema for `dpistack.conf`, `suricata -T` on the restored `suricata.yaml` and `local.rules` together (`suricata_check_set` takes the second candidate), a non-empty `evebox.yaml` and `ntopng.conf`. Suricata not installed: the check is skipped with a line saying so (a restore onto a bare host is a normal case). Then under the installer lock each file is copied to `backups/`, replaced atomically; a failed write puts every replaced file back. A restore leaves the render hash alone (as `config-write` does), so the installer treats the files as hand-edited; it applies nothing, the next step is `dpistack reconfigure` |
| D50 | **Dry run** prints `new:`, `same:` or `changed:` per file and a unified diff; `users.json` is shown as changed without a diff because it holds password hashes |
| D51 | **The panel cannot choose a path.** For the panel (`sudo` as `dpistack` or `DPISTACK_CALLER=panel`) `--out` and any argument that is not a bare `*.tar.gz` name give exit 5, so a stolen session cannot make root read or write elsewhere. Download is read by the panel itself from `-backups-dir` (the archive group is `dpistack`), refuses a link and a name that is not a bare file name. A real restore from the panel needs `acknowledged:true`; the screen always runs the dry run first and asks |

Tests: `tests/backup.bats` (20), `panel/internal/api/backups_test.go` (9) and the Backups rows of the route table in `users_test.go`, `panel/web/test/backups.test.mjs`, `-backups-dir` in `tests/panel_step.bats`.

### 18.37 Slice 37 (second part): the shell of the panel (v0.34.0)

**Status:** slice 37 is done except the alert bell (slice 43); the top bar is in 18.49. **Done here:** the menu in groups, routes by hash, the folded menu, the permission-aware hiding of groups and entries; the corner, Build info and the look are in 18.35.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R180 | medium | the rule `#overview[data-collapsed]` (an id and an attribute) beats the narrow layout, so a user who folded the menu on a desktop and then narrowed the window got a broken grid | the folded rules are inside `min-width` media in both stylesheets and the fold button is hidden on a narrow screen |
| R181 | medium | reading `window.localStorage` can itself throw in some browsers, and a first load would stop | the read is inside `try` and the menu starts expanded |
| R182 | low | an address naming a screen the user has no permission for would show an empty screen | it opens Overview, by the same rule that hides the entry; `hashchange` is ignored while signed out |
| R183 | low | a group heading would stay when every entry under it is hidden | `syncGroups` hides the group; a test |

Open: the top bar; the look of the folded menu and of the group headings was not checked in a browser (the rules of `design.test.mjs` pass for both stylesheets); Traffic, IPS, Exceptions, Health and Security join the menu with their slices.

Decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D52 | **Only screens that exist are in the menu.** Rule 1 of the slices 38-45 (nothing is shown that the program cannot do) applies to the menu too, so there are no greyed entries for later slices. Groups: Monitoring (Overview, Events, Metrics, Alerts), Protection (Rules), System (Components, Logs, Tests, Backups, Configs), Admin (Settings, Audit, Account). `app.js` and a test keep every screen in exactly one group |
| D53 | **Routes are `#<screen>`.** `showView` sets the hash, `hashchange` shows the screen (back and forward work), the first load opens the screen of the address. A name that is not a screen, or a screen the user has no permission for (the same rule that hides its entry), opens Overview. The hash holds nothing else, so no value reaches the history |
| D54 | **The folded menu** is an attribute on the signed-in page and the choice is kept in `localStorage` (`dpistack.nav.collapsed`), read and written inside `try`, because some browsers refuse storage. It applies only on wide screens: the narrow layout has its own menu |

Tests: `panel/web/test/shell.test.mjs` (5).

### 18.38 Slice 38: Overview v2, system health and topology (v0.35.0 to v0.37.0)

**Status:** done; the last part (the Network screen) is in 18.50. **Done here:** `GET /api/system`; on the Overview the host cards and the interfaces table, four state cards, warnings, alerts by severity, the latest alerts, the traffic graph and the watchdog warnings.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R184 | medium | `/` and `/var/log` on one filesystem were reported as two disks | the disks are deduplicated by filesystem id, the first path is shown; a test |
| R185 | medium | the first CPU sample has no rate and would have shown 0 % | `percent` is `null` on the first answer and the screen says "measuring"; a test |
| R186 | medium | a failing extra source (a 404 of `/api/system`, a 503 of the metrics) would have been shown as an error of the whole Overview, or have signed the user out | an extra part that fails is left out; only a 401 signs the user out; tests for each source |
| R187 | low | the existing poll test counted the new extra requests as status polls and failed | it counts only the status polls |
| R188 | low | D60 said the stale rules update warning needed a new endpoint, but the watchdog already has `rules.age` | the Overview repeats `rules.age` and `suricata.eve_fresh` when they are warn or crit (D62) |
| R189 | medium | the state and host cards had no layout: no padding, and the label, value, badge and note ran together in one line (seen in a screenshot from the user, then reproduced in headless Firefox). The look had been reported as "not checked in a browser" three times | `.stat` is a grid with padding in both stylesheets, `#glance-box` and the `Latest` heading have spacing; the page was rendered in headless Firefox against a mock API and looked at |

Open: the look of the cards, the warnings and the traffic charts was not checked in a browser; the interface counters are totals since boot (no rate); `docker_socket` and `systemd_present` only say that a file or a directory exists, not that the daemon is healthy; "Alerts, 24 h" counts the latest 200 alerts only.

Decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D55 | **Nothing is run for `/api/system`.** It reads `/proc/uptime`, `loadavg`, `stat`, `meminfo`, `/sys/class/net/*` and statfs. The CPU share needs two samples, so the first answer has `percent: null` and the screen says "measuring"; the reader keeps the previous sample, so the share is the average since the last call (the Overview calls every 10 s) |
| D56 | **Honest names for what is only a hint.** `systemd_present` is the directory `/run/systemd/system`, `docker_socket` is the file `/var/run/docker.sock`. They do not say that the daemon is healthy; the state of the parts stays in `/api/status`. In the docker panel the numbers are those of the host (`pid: host`), the disks are those of the container's mounts |
| D57 | **The host part is extra.** When `/api/system` fails (switched off, not readable) the Host section hides and the Overview shows the rest; only a 401 signs the user out. A card for data the host did not give is left out, not shown as 0 |

Tests: `panel/internal/system/system_test.go` (5), `panel/internal/api/system_test.go` (3) and the `/api/system` row of the route table, `panel/web/test/system.test.mjs` (5), two cases in `panel/web/test/poll.test.mjs`.

Second part (v0.36.0), decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D58 | **No new endpoint: the cards are made in the browser from answers that exist.** The Overview asks `/api/status`, `/api/system`, `/api/mode` and `/api/eve?type=alert&limit=200` together every 10 s. A part whose source fails (the viewer off, `ctl` unavailable) is left out, never shown as zero; only a 401 signs the user out. The model is `panel/web/modules/overview-model.js`, pure functions |
| D59 | **Honest windows.** "Alerts, 24 h" counts the alerts of the latest 200 whose time is within 24 hours; when 200 were read the screen says "of the latest 200 alerts". Alerts without a time are not counted. Severity is the EVE number: 1 high, 2 medium, 3 low, anything else unknown |
| D60 | **What counts as a warning:** a component that failed; one that is stopped but set to start on boot; Suricata running with no interface set to capture; packets dropped on the capture interfaces since boot; a disk at least 90 % full. Each is a sentence about a fact the screen has. The stale rules update warning needs the date of the last update, which no endpoint gives yet |

Tests: `panel/web/test/overview-model.test.mjs` (8), three cases in `poll.test.mjs`.

Third part (v0.37.0), decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D61 | **The traffic graph reuses the Metrics screen.** The Overview draws the `pps` and `drops` cards of the last hour with the same `seriesCard` as `/metrics`, from `GET /api/metrics?range=1h` (the server samples every 30 s). Without metrics (503) the block hides; a series that cannot exist stays a note with its reason, never a flat line |
| D62 | **The stale rules update warning is the watchdog's own check, not a new one.** `rules.age` (`WATCH_RULES_WARN_DAYS`, `WATCH_RULES_CRIT_DAYS`, mtime of `suricata.rules`, off with `RULES_UPDATE=off`) and `suricata.eve_fresh` are repeated in the warnings of the Overview when they are `warn` or `crit`, with the check's own detail line as the sentence. The process, port, drop and disk checks are not repeated: the screen says those from its own data. So there is no "last rules update" endpoint; this supersedes the remark in D60 |

Tests: three more cases in `overview-model.test.mjs` and `poll.test.mjs`.

### 18.39 Slice 39: Traffic Explorer (v0.40.0)

**Status:** done. The screen is called Traffic (menu group Monitoring, between Network and Events, the permission `view`). It only reads.

**What it does:** four tabs over the newest events. Devices: one row per address with connections, sent, received, application names, the number of other addresses and the last time seen; a click on a row opens that device (its totals, its applications, its domains) and switches to its connections. Applications: connections and traffic per `app_proto`, a connection with none is counted as `unknown` and not hidden. Domains: what DNS queries asked for and what TLS handshakes named (the SNI), with the hosts that asked. Connections: the flow events as rows. One text filter works on every tab (address, port, protocol, application, domain). A link opens ntopng for per host history. Where the data is not there the page says exactly that: the event view is off, no `eve.json` yet, no `flow` in `EVE_TYPES`, no flow ended yet, no `app_proto`, no DNS events, no TLS events, and that MAC addresses are not in the events.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R213 | medium | the ntopng link fell back to port 3000 when `/api/settings` did not answer or had no `NTOPNG_PORT`, so the link could point at a port nothing listens on; found by the test of `ntopngUrl` written for the slice | `ntopngUrl` returns no link unless `NTOPNG_PORT` is in the answer and valid; `NTOPNG_ENABLE=no` gives none either |
| R214 | low | a screen that adds listeners to elements that stay in the page (the tabs, the filter, the switch) stacks them every time the user comes back to it | the stop function of the screen removes the three listeners, and the filter and the switch start empty |

Decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D74 | **No new endpoint.** The screen reads `GET /api/eve?type=flow|dns|tls&limit=500` and `GET /api/settings` (for the ntopng port), polls every 10 s while it is open, and builds every table in `panel/web/modules/traffic-model.js`. The server keeps 500 events per type (4.8), so every figure means "in the newest events", never "all time"; the screen does not claim more |
| D75 | **A device is a private address.** The panel does not read `HOME_NET`, so private, link local and loopback addresses are devices and a switch ("External addresses") adds the rest. Traffic is counted from each end's own side: in a flow event `src_ip` started the flow, so `bytes_toserver` is what it sent and `bytes_toclient` what it received, and the other end gets the opposite |
| D76 | **No MAC addresses.** Suricata writes them only with the `ethernet` option of `eve-log`, which the installer does not set; turning it on changes the rendered `suricata.yaml` and is a decision for the owner, not part of this slice. The page says that devices are told apart by IP address only. If the option is switched on later the model can read `ether.src_mac` and `ether.dest_mac` |
| D77 | **Application names come only from `app_proto`.** There are no separate nDPI fields in EVE (A2, 4.7); a flow whose `app_proto` is empty or `failed` is `unknown`. nDPI categories and risks are not shown on this screen |

Tests: `panel/web/test/traffic.test.mjs` (15): the local address ranges, the flow rows (a flow without both addresses, a failed `app_proto`, bad byte counts), the direction of the bytes at both ends and the external switch, the order of the devices, applications and peers without repeats, the `unknown` application, domains (DNS answers do not count, TLS joins the same name, case and the trailing dot), the filters, the detail of one device, every message of `availability`, `ntopngUrl` (host, https, IPv6, disabled, bad port, no settings), the view with text, device and switch, and the page (view, menu entry in Monitoring, route, element ids). The menu test "every screen is in exactly one group" covers the new entry.

Open: nothing was rendered in a browser (none is available in the build environment), so the look of the tabs, the clickable rows and the narrow layout is checked only by the design rules; it was not run against a real `eve.json` from a stand, only against events built from the documented fields; a flow event is written when the flow ends, so a long connection shows up late; the tables show 100 rows and ask for the filter beyond that; with Suricata in a container or the events view off the screen shows the reason and nothing else; the link to ntopng uses the host name of the address bar and `NTOPNG_PORT`, which was not opened on a stand.

### 18.40 Slice 40: the Events workspace and exceptions (v0.41.0)

**Status:** done. Two screens and one command, and the command is the only writer, so the CLI and the dashboard cannot differ.

**Events workspace (Events screen):** filters by address, rule number, category, protocol, severity, domain and time (15 minutes to 7 days, sent to the server as `since`); grouping by rule, source, destination or category (a click on a group filters by it); for one event, the events of the same flow (`flow_id`), the history of its rule (how often, first and last time, the most frequent addresses) and Create exception (for an alert); export of what is shown as JSON or CSV. The line above the list says how many of the loaded events pass; the filters other than type, text and time work on the loaded events (at most 500), and the screen says so.

**Exceptions (Exceptions screen, group Protection; `dpistack exceptions list|add|remove|prune`):** an entry is a line of Suricata's own `threshold.config`, with one comment line before it that holds when, by whom, until when and why:

```
# dpistack: added=2026-11-08 expires=2026-12-08 by=admin note=printer scans
suppress gen_id 1, sig_id 2001219, track by_src, ip 10.0.0.5
```

Kinds: `suppress` for one address (`--track src|dst --ip ADDR`) or, with no address, for every address; `limit` (at most N alerts per S seconds for each address of one side). A change is checked with `suricata -T` on the candidate file before anything is written, backed up, and a running Suricata is reloaded. The file is created by the Suricata step (a header only), named in `suricata.yaml` (`threshold-file`), part of backups and an editable name in Configs (ten files now). Lines that are not entries (hand written) are kept as they are and listed as `not managed`.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R215 | **high** | the CSV export carries text an attacker controls (the rule name, a DNS name, an SNI): a value that starts with `=`, `+`, `-` or `@` is run as a formula when the file is opened in a spreadsheet | `cell()` of `events-model.js` puts an apostrophe before such a value (and before a tab or a carriage return) and quotes commas, quotes and line breaks; the test feeds `=cmd|' /C calc'!A0` and `=HYPERLINK(...)` |
| R216 | low | a `flow_id` above 2^53 loses digits in the browser, so the server's text search for it can find nothing | Related events adds the events already on the screen to the answer of the search, and the limit is stated in Open |
| R217 | low | `tests/exceptions.bats` used a bare `! command` before its last line, which bats ignores; the repository test R138 caught it in CI (Ubuntu 22.04) and the check of `config-write` piped into `run`, so its status was never asserted | each negation is `run` plus a status check; the `config-write` check asserts exit 3 |

Decisions (\"choose yourself\", and the owner's answers of 2026-11-08):

| id | decision |
| --- | --- |
| D78 | **One writer, Suricata's own format.** Exceptions live in `threshold.config` in Suricata's syntax; nothing is rendered, so there is nothing to drift. The CLI, the panel (through `/api/exceptions`) and the watchdog all call `dpistack exceptions`. Settings parity: the one setting, `EXCEPTIONS_DEFAULT_DAYS`, is in the schema, so Settings, `dpistack settings` and the install menu all have it |
| D79 | **Expiry is optional.** `--never` (the screen: Expiry, never) or `EXCEPTIONS_DEFAULT_DAYS=0` make an entry that stays until removed; `--days N` is 1 to 3650; with neither the key decides (30 out of the box). An expiry is a UTC date and that day is the last one in force. Suricata does not know dates, so the watchdog runs `exceptions prune` on every tick; until then an expired entry still works. An entry whose comment is missing or damaged never expires: it is not dpistack's to drop. `prune` writes one audit line, only when it removed something |
| D80 | **A bare SID is allowed.** `suppress` with no `--ip` silences the rule for every address; the CLI prints a warning and the screen asks for a confirmation. The narrowest scope is what Create exception offers first: the rule and the source address of the alert |
| D81 | **No new endpoint for the workspace.** Events are read with `GET /api/eve` (type, text, `since`, limit up to 500); everything else is the browser's. The exceptions routes are in 4.8; reading needs `view`, changing needs `rules.edit`, and `--by` is the signed in user, never a field of the body |
| D82 | **No interactive menu entry for exceptions.** The install menu builds its sections from the schema, so the key is there; the entries are managed with the verb, as `rules-sid` is. The audit log records `add` and `remove` (and a `prune` that removed something) |
| D83 | **Hand written lines stay.** A line of `threshold.config` that is not a suppress or limit entry of the form above is listed as `not managed`, never removed by `remove` or `prune`, and kept by every rewrite |

Tests: `tests/exceptions.bats` (19): the file and the yaml line after install, a second install keeps edits, the syntax and data of suppress, a bare SID, a limit, `--never`, `EXCEPTIONS_DEFAULT_DAYS` 0 and 7 and the default 30, list as text and JSON, prune (only the expired, hand lines kept, the last day still in force), remove, a duplicate, every refused argument with its exit code (5 for a value, 2 for a combination), a file that fails `suricata -T` is never written (3), the check sees the candidate file, a running Suricata is reloaded and a stopped one is left alone, backup and `config-read`/`config-write` of the file, the usage text and the audit log, the watchdog pruning on its run and logging only then. `panel/internal/api/exceptions_test.go` (5): the list, the exact arguments the verb receives (the user from the session, never from the body), every value checked before ctl, every exit code mapped (400, 500, 422 with the output, 409), permissions (401, 403 for a viewer and an analyst, 200 for operator, admin and a custom role with `rules.edit`). `panel/web/test/exceptions.test.mjs` (12) and `events-workspace.test.mjs` (13): the words for scope and expiry, the order, the summary, the form checks and warnings, the defaults taken from an alert, every filter, grouping, related events, the history of a rule, CSV quoting and the formula guard, the export names, the page and its element ids, no `innerHTML` and no browser storage. `devnote.test.mjs` (4): the under development sentence is the same everywhere (rule 12).

Open: nothing ran against a real Suricata: the tests use a fake `suricata -T` that rejects a line with `INVALID`, so it is not confirmed that Suricata accepts a bare `suppress gen_id 1, sig_id N` line, that a live reload (`ruleset-reload-nonblocking`) re-reads `threshold.config`, or that a container Suricata sees the file at `/etc/suricata/threshold.config`; nothing was rendered in a browser, so the layout of the two screens, the show and hide of the form fields and the file download are checked by tests of the code only; the filters work on the newest 500 events, not on the whole file, and a `flow_id` above 2^53 can lose digits (R216); the history of a rule reads the newest 500 alerts that contain the number; a threshold entry written by hand with `type threshold` or `both` is kept but shown as `not managed`; the interactive CLI shows no list of exceptions (the verb does).

### 18.41 Slice 41: Rules v2 (v0.42.0)

**Status:** done. It is a part of the Rules screen (same view, its own module `rules2.js`); every number is the answer of a `dpistack` verb, so the CLI shows the same.

**What it does:** the rule sets with their counts (the rules in use, `local.rules`, every enabled source: total, enabled, disabled, not loaded, when downloaded); the history of the last 10 updates (time, updated or failed and restored, the numbers); a rule search by category (`classtype`), source, state and text, with disabled rules included; an editor for `local.rules` with Check (a line that is no rule, a rule with no sid, a sid used twice, a sid the rule set already uses, what `suricata -T` says) and Save or Save and apply through the same `/api/config/local.rules` as Configs; the saved versions of the file with a comparison against the editor and a way to put one back in the editor.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R218 | medium | the description of a rule was cut at the first `"` inside `msg`, but a rule writes a quote in its text as `\"` and a semicolon as `\;`; found by the test of `rules-find` with such a rule | the extraction in `rules-describe`, `rules-find` and the conflict message of `rules-local check` reads escapes and shows the text unescaped; `rules-search` (older, documented in 4.5) has the same limit and is left as it is, see Open |
| R219 | low | `rules-search` skips every rule that is commented out, so a rule disabled by default or by `disable.conf` can never be found from the screen, and that is exactly the rule one looks for to turn on | `rules-find` searches disabled rules too and says the state of each |

Decisions (\"choose yourself\"):

| id | decision |
| --- | --- |
| D84 | **Counts per source come from what suricata-update itself keeps.** It stores each source in `<data dir>/update/cache` as `<md5 of the URL>-<file name of the URL>` and writes the merged set with a disabled rule as `# alert ...`; the URL comes from the source index (`cache/index.yaml`) or from the `url` of a custom source file, and the newest cache file with that file name is counted. The state of each rule is read from the merged set by sid, so a rule turned off in `disable.conf` counts as disabled. A source that was never downloaded has no numbers and says so (not zero). All of this was checked by running suricata-update 1.3.3 offline on a built cache |
| D85 | **The history is written by `rules-update`.** One JSON line per update in `/var/lib/dpistack/rules-updates.jsonl`, the last 100 kept, with the numbers of the line `Writing rules to ...: total: N; enabled: N; added: N; removed N; modified: N` and `parsed:false` when the tool did not print it; a failed update (rolled back) is recorded as `failed`. The history starts with the first update after the upgrade; nothing is invented for the past. A history that cannot be written never makes an update fail |
| D86 | **The check of `local.rules` is strict on the screen and the CLI keeps the old rule.** `rules-local check` reports problems (no rule, no sid, duplicate, conflict with the rule set, `suricata -T` refusing) and warnings (a sid outside 9000000 to 9999999, Suricata not installed). The screen enables Save only after a check with no problems of the exact text in the editor; `config-write` itself still needs only `suricata -T` to pass, so a script can save what the screen would stop. The verb never writes |
| D87 | **The history of changes is the backups that already exist.** Every change of a config file makes `backups/<file>.<time>`; `config-history` lists them and prints one, and the screen compares a version with the editor in the browser (up to 2000 lines, a longer file is said not to be compared). Nothing new is stored |
| D88 | **`rules-find` is a new verb; `rules-search` is not changed.** The text of 4.5 for `rules-search` and its tests stay true. Category is the `classtype` of the rule, provider is the source |
| D89 | **One screen, two modules.** The Rules view starts `rules.js` (sources, groups, one rule) and `rules2.js` (the rest) and stops both when it is left |

Tests: `tests/rules_v2.bats` (24): the counts of the merged set, `local.rules` and each source by the state in the merged set (a tar.gz and a plain cache file named as suricata-update names them), a source never downloaded, a custom source with its own url and a rule the set lacks, the newest cache file and a checksum file ignored, text output; `rules-describe` from both files, JSON safe messages, every refused argument; `rules-local check` for a sound file, each kind of problem with its line, the warning for the sid range, what `suricata -T` says, nothing written, the size limit and bad arguments; the history after an update with the numbers, a failed update, the cap of 100 lines and the text form; `config-history` newest first, one version, refusals; `rules-find` by category (case, disabled rules), source (and an unknown one), the combination of filters, the cap of 50, every refusal; `rules-facets`; the usage text and that none of these reads is audited. `panel/internal/api/rules_v2_test.go` (10): the JSON of each verb passed on unchanged, an answer that is not JSON is a 500, the arguments built from the filters, every value checked before ctl, the body of the check on stdin, the 1 MiB limit, the refusal mapped, the permissions (401, 403 for a viewer, an analyst and an operator on config history). `panel/web/test/rules2-model.test.mjs` (12) and `rules2-page.test.mjs` (4): the rows and words, no numbers for a source never downloaded, the query of the search, the report of the check and when Save is allowed, the line comparison and its limit, the page wiring, no `innerHTML`, the save request identical to Configs.

Open: nothing ran against a real, running Suricata or a real download: the cache naming and the merged set format were checked with suricata-update 1.3.3 offline on a built cache, not with the real et/open source, whose file layout inside the archive is assumed to hold plain `.rules` files; a source whose URL has a file name shared with another enabled source can be counted from the wrong cache file; `rules-search` still stops a description at the first `\"` (R218) and still skips disabled rules (R219) and the screens use `rules-find` instead; the history of updates starts empty after the upgrade; nothing was rendered in a browser; the comparison is line by line, so a moved block shows as removed and added.

### 18.42 Slice 42: the IPS page (v0.43.0)

**Status:** done. It is a screen of its own (menu group Protection); every number is the answer of `dpistack ips status` or `dpistack ips test`, so the CLI shows the same. Switching between IDS and IPS stays on Components, where it is confirmed and counted down.

**What it does:** the readiness of IPS as a list of checks (the mode, `suricata.service`, the queue rules in iptables or nft, whether a process listens on the queue, the confirmation timer), the packet counters of the newest stats event (accepted, blocked, rejected, replaced), the number of active and disabled drop rules in the rule set and in `local.rules`, the latest blocked events, and the **rule test**: it replays a shipped pcap through Suricata offline with the chosen rules and says which would drop. It never touches live traffic: the replay writes into a private temporary directory and the main `eve.json` is not opened for writing.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R220 | medium | nothing said whether IPS was really inspecting: `mode status` showed the mode, the method and the countdown, and with `--queue-bypass` a Suricata that is not bound to the queue lets all traffic through while the page says IPS | `ips status` checks that the queue rules exist and that a process listens on queue 0, and `ready` is false when a check fails |
| R221 | low | the first version of `ips test --sid` built a jq expression that does not compile (`elif` with a binding in its condition), so the verb printed an error instead of JSON for every named sid; found by the test of named sids before the commit | the expression is rewritten with `//` and a binding after it; the test asserts every state |

Decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D90 | **One verb `ips` with two sub-verbs.** `ips status` and `ips test`, both read only, so neither is audited by the CLI (4.5: only verbs that change something are); the code lives in `lib/ips.sh` next to the firewall helpers, no new file |
| D91 | **The queue is checked in `/proc/net/netfilter/nfnetlink_queue`.** A line whose first field is the queue number (0) means a process listens; the path comes from `paths.sh` (`path_proc_nfqueue`). With `IPS_METHOD=afpacket` the firewall and the queue checks are `na`, and in IDS mode they are `na` too: a failing check is reported only where IPS needs it |
| D92 | **Counters and blocked events are read from `eve.json`.** The counters are `stats.ips.{accepted,blocked,rejected,replaced}` of the newest stats event in the last 4 MiB (`null` when there is none); a blocked event is an `alert` event with `alert.action` `blocked` in the last 8 MiB, the newest 20 first. The watchdog reads the file the same way |
| D93 | **The rule test replays a shipped pcap with `--simulate-ips`.** Only a pcap by name from `tests/data` (a short word, never a path; now `bittorrent`) is accepted, so the page cannot be made to read a file. Without `--sid` the active drop-type rules (`drop`, `reject*`) are replayed, with `--sid` up to 20 sids from `local.rules` and the rule set, as written: an `alert` rule is reported as `alert_only`, it is not turned into a drop. A rule that needs the nDPI plugin when it is not installed is `needs_ndpi`. `HOME_NET` is `any` in the replay, as in the BitTorrent test. A Suricata in a container or none is `ran:false` with a reason, not an error |
| D94 | **The routes are `GET /api/ips` and `POST /api/ips/test`.** The page needs the permission `view`, the test `tests.run` (an analyst has it, a viewer has not). One test runs at a time (409), because loading the rule set is heavy; the bodies are checked in the panel with the same patterns as the verb (numbers only, 20 at most, a short lowercase pcap name) before the verb is called, and the panel does not audit the test (it changes nothing) |
| D95 | **The screen polls every 5 s and keeps the test apart.** `ips.js` reads `/api/ips` like the mode block does; a failing read shows its message and leaves the rest, a 401 signs out; the test button is disabled while a test runs and says that loading the rules can take a minute |

Tests: `tests/ips_page.bats` (17: 16 at v0.43.0 and the cut line of R222; the audit check was corrected in v0.44.0, R223), `panel/internal/api/ips_test.go` (6: the JSON passes through unchanged, a verb that printed text is a server error, the arguments reach the verb, every bad body is refused before the verb, exit code 5 is a 400, the permissions), `panel/web/test/ips.test.mjs` (12: the headline, the levels, the counters, the rule numbers, the test summary, drawing, a failing read and a 401, the test refusing a bad number before any request, an empty field testing all drop rules, a failing test freeing the button, the page and the route). The full gate (shfmt, shellcheck, security, bundle, bats, gofmt, vet, go test, the panel scripts) was run on the final tree.

Open: nothing ran against a real, running Suricata or a real NFQUEUE. The names `stats.ips.*`, the action `blocked`, the flag `--simulate-ips` and the format of `nfnetlink_queue` come from the Suricata and kernel documentation, not from a run on a host; the tests use a stub that writes what the code expects, so a difference in a real version would show only on a host (the first thing to check on a test machine is `dpistack ips status` in IPS mode and `dpistack ips test` on a host with Suricata). The only shipped pcap is the BitTorrent one, so most drop rules answer `no_match`: the test shows that a rule loads and would drop when it matches, not that it matches the traffic of this network; a pcap of the person's own cannot be given (D93). The screen was not rendered in a browser (none is available in the build environment). The counters and the blocked events depend on `EVE_TYPES` having `stats` and `alert`; with `EVE_FILE=no` the page says there are none. Whether the queue is really bound is read, not tested with a packet.

### 18.43 Slice 43: the Alert Center (v0.44.0)

**Status:** done. It is the top of the Alerts screen; the feed of status changes that the screen had stays below it, unchanged. The bell of the top bar, the one piece of slice 37 that waited (D66), is done here.

**What it does:** every alert of the watchdog and of Suricata, with a state a person gives it: **new**, **acknowledged**, **snoozed** until a time, **resolved**; who decided and why; a list of the decisions; filters by state, source and level. The same through `dpistack alerts` on the command line.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R222 | medium | the `ips status` readers of slice 42 (`ips_last_stats`, `ips_last_blocked`) piped the tail of `eve.json` straight into `jq`, which stops at the first line that is not JSON, and `tail -c` cuts the first line: one cut line could hide every counter and every blocked event; found while writing the same reader for alerts | both read with `jq -cR 'fromjson? ...'`, which skips a line that is not JSON; a test with broken lines in the middle of the file |
| R223 | low | the test of slice 42 "ips test and ips status are not audited" looked at `var/lib/dpistack/audit.jsonl`, but the audit file is `audit/audit.jsonl`, so it passed whatever the verbs did | the right path, and a control: an audited verb must write to that file before the empty check means anything; the alert test checks the same way |
| R224 | medium | the first draft of the panel route took `/api/alerts` and overwrote `internal/api/alerts.go`, which already served the feed of status changes to the Alerts screen; `go vet` found it (an existing test named something the draft no longer had) before anything was committed | the file is restored; the Alert Center has its own file and its own routes, `/api/alert-center`; a test that `GET /api/alerts` still answers |
| R225 | low | a query with a `;` (`?state=new;rm`) is dropped silently by Go's parser, so a bad filter was ignored and the full list came back with 200 | the query is parsed with `url.ParseQuery` and a query that does not parse is 400 |
| R226 | low | after a refused change the screen read the list again and that wiped the server's message from the page; the node test found it | the message is put back after the read |

Decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D96 | **One verb `alerts` with six sub-verbs** (`list`, `history`, `ack`, `snooze`, `resolve`, `reopen`) in a new file `lib/alerts.sh`, sourced by `install.sh`; the path comes from `paths.sh` (`path_alerts_state`). The four that change a state are audited (`audit_wanted`), reading is not. The panel is only a layer over the verb, as on the IPS page, so the CLI and the page cannot disagree |
| D97 | **What an alert is, and what is stored.** A watchdog alert is a check of `health.json` that is `warn` or `crit` (key `watch:<id>`, the level is the status). A Suricata alert is the alert events of the last 8 MiB of `eve.json` grouped by rule (key `sid:<number>`; severity 1 is `crit`, 2 `warn`, 3 and more `info`; the count, the first and the last time). **Nothing about an alert is stored, only what people decided**, in `/var/lib/dpistack/alerts-state.json`: the decision, the time, who, the note, the time of a snooze, and the title and level the alert had, so a decided alert can still be shown after it cleared |
| D98 | **The states.** No decision is **new**. **Acknowledged** stays until it is reopened, resolved or cleared. **Snoozed** (1 h, 4 h, 24 h or 7 d, nothing else) turns to new at the second it ends. **Resolved** stays until the alert is newer than the decision: a Suricata event with a later time, or a status change of the check after it (compared on the first 19 characters of the UTC time, so the two formats of Suricata and of the watchdog compare). An alert with a decision whose condition is gone is listed as resolved with `cleared:true` (its button is "Dismiss"); an alert nobody touched that cleared on its own is not listed, it is in the history as a status change of the watchdog |
| D99 | **Retention.** On the next change, decisions of resolved or cleared alerts older than 30 days are dropped and the history is cut to the last 500 entries. They are constants in the code, not config keys: the schema of 4.3 is not extended |
| D100 | **One writer, a lock, an atomic file.** Only the verb writes the file, as root; `flock` on `alerts-state.lock`, a temporary file in the same directory and `mv`, mode 0644. A damaged file counts as empty and the next change rewrites it. The panel passes `--by` with the panel user (the account that runs the verb through sudo is the panel's, not a person). The panel needs `events.ack` for a change (it existed in the roles, analysts and operators have it, and no route used it until now) and `view` for reading |
| D101 | **The routes are `/api/alert-center`, beside `GET /api/alerts`.** The old route is the feed of status changes of `events.jsonl` and the Alerts screen uses it; it is not touched. The screen shows the Alert Center first, then the Decisions, then the feed under "Status changes". The **bell** is a link chip `N new alerts` (or `No new alerts`) in the top bar, red with a critical new alert, yellow with others, green with none, to `#alerts`; it is read with the other chips every 15 s from `/api/alert-center?state=new` and is hidden while that read fails |
| D102 | **Notes use the pattern of the exceptions** (80 characters of letters, digits and `. _ : / @ + , = -`), checked by the screen, the panel and the verb. A decision changes only what the page shows: the page says so, and sends a person who wants Suricata to stop alerting to Exceptions |

Tests: `tests/alerts.bats` (18), `panel/internal/api/alertcenter_test.go` (8: the JSON passes through, the filters reach the verb as arguments, bad filters and bodies are refused before the verb, the history limit, the user goes to `--by`, exit code 5 is a 400, the permissions, the old feed still answers), the five new routes in the table of `users_test.go` (checked against every role), `panel/web/test/alertcenter.test.mjs` (17: the actions per state, the words, the query, the body and its note, the screen drawing, no buttons without `events.ack`, a click posting the note and reading again, the snooze time, a bad note refused before a request, a failing read, a refused change and a 401, the filters and the removed listeners, the bell and its failure, the page and the wiring). The full gate (shfmt, shellcheck, security, bundle, bats, gofmt, vet, go test, the panel scripts) was run on the final tree.

Open: nothing ran against a real watchdog or a real Suricata: `health.json` and `eve.json` are fixtures written to the format of 4.6 and 4.7, so a difference in a real file shows only on a host. A Suricata alert exists only as far as the last 8 MiB of `eve.json` goes: on a busy sensor an old rule falls out of the window and its count is the count of the window, not of all time; an alert nobody decided on that falls out simply vanishes. Acknowledging or snoozing does not silence Suricata and does not stop any notification (there is none: no mail or webhook, the spec had none). The bell and the screen poll, so a change by someone else shows after up to 10 or 15 s. The screen and the bell were not rendered in a browser (none is available in the build environment). The permission to change a state is `events.ack`, which every operator and analyst has: a finer split (who may snooze for 7 days) was not asked for.

### 18.44 Slice 44: Settings v2 (v0.45.0)

**Status:** done. The Settings screen of 18.22 keeps its checks, its apply, its heavy job and its secrets; what is new is how it is laid out and what it tells you.

**What it does:** three columns: **categories** with a **search** and the standard or advanced level; the **keys** of the category (or the search results); and the **details** of the key in focus with the **staged change** and the **profiles**. For every key it shows the default, the allowed values, what it depends on and what a change touches. A key that does not apply with the values as they are (for example `LAN_CIDR` while `ACCESS_MODE` is not `lan`) is dimmed with the reason, and that follows each edit at once. The staged change is a diff, old to new, with the weight; **Apply opens only after a check of exactly these values has passed**. A profile is a named set of keys saved and loaded into the staged change.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R227 | medium | nothing told a person which settings mean anything now: the rules existed only as code of the guided setup (`menu_key_skipped`), so the screen showed `NGINX_CERT` to someone on `localhost` as a thing to fill in | the rules are data in the schema (`SCHEMA_DEPENDS`) that `settings list --json` serves and the screen evaluates live; a test compares the table with `menu_key_skipped` over every value of every switch, alone and in pairs, and was checked to fail when a rule is broken |
| R228 | low | the screen let you press Apply at once after an edit; the check ran inside the apply, so the person never saw the diff or what restarts before it started | Apply opens only after a check of exactly the staged values passed; any later edit closes it again; the staged change is a table of old and new values with the weight and the components touched |
| R229 | low | the first wording of the search note said "1 more matches"; the node test found it | the plural is right, and both forms are asserted |
| R230 | low | the `gate` jobs ran close to their 30 minute limit: in slice 43 the PR run was cancelled at the limit (the same commit passed on the push in 24 to 26 minutes, no test failed) and only a re-run got it through | the limit is 45 minutes, as `release.yml` already has (D103) |

Decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D103 | **The gate may run 45 minutes.** `timeout-minutes` of the `gate` job is 45 (it was 30); the gate grows with every slice and a slow runner must not cancel a green commit; with the 24.04 job gone (D109) the slow one is gone too, the limit stays as a margin. The other jobs keep their limits |
| D104 | **When a key applies is data in the schema.** `SCHEMA_DEPENDS[KEY]` holds conditions, all of which must hold: `OTHER=a\|b` (one of), `OTHER!=a\|b` (none of), `OTHER~item` (a comma list that has it). They are exactly the rules of `menu_key_skipped` and nothing more: for example `EVE_MAX_SIZE_MB` is not tied to `EVE_ROTATE=size`, although 4.3 says it is needed there, because the guided setup would then change what it asks. `schema_depends_ok` evaluates a key against a getter of values. The generated config reference (EN and RU) is not changed by this (see Open) |
| D105 | **What a change touches is the steps that the schema already had**, given a label (`SCHEMA_STEP_LABEL`: Suricata, the nDPI plugin, the rules and their updater, the test checks, EveBox, nginx and the firewall and the listen addresses, Redis, ntopng, this panel, the watchdog, the metrics storage and export, node_exporter, Grafana). The words "light" and "heavy" are those of 5.3 |
| D106 | **Profiles are `profiles.json` and one verb.** `/var/lib/dpistack/profiles.json` (`path_profiles_json`), written only by `dpistack settings profile` as root, under `flock` on `profiles.lock`, replaced atomically, mode 0644; a damaged file counts as empty. A profile has a name (1 to 32 of `a-z 0-9 - _`), who saved it and when, and up to 100 `KEY=VALUE`; at most 50 profiles. A secret never goes in. A save is checked with `settings check` against the config as it is now, so a profile that would be refused is not stored; that check can pass here and fail on another host, where the usual check of an apply stops it. `apply` is `settings set` with the pairs of the profile, so the checks, the weight and the confirmation of a wider access are not bypassed. `save`, `delete` and `apply` are audited. The code is `lib/profiles.sh`, sourced by `install.sh` |
| D107 | **The routes only pass the verbs on, and nothing applies a profile.** `GET /api/settings/profiles` and `/{name}` need `view`; `PUT` and `DELETE` need `settings.edit`; the body of a save is `{values}` like the other settings routes, the pairs go on stdin and the panel user on `--by`. Loading a profile on the screen puts its values into the staged change (after asking, when something is already staged), so a profile goes through the same diff, check and apply as a hand edit |
| D108 | **The screen.** Three columns that become one below 70 rem; the standard and advanced levels are the existing level of the schema behind the switch "Show advanced settings"; the search matches a key name, a description or a group title and reports the advanced matches it hides; a key that does not apply is dimmed, not hidden, so it can still be set; the details follow the focus; "Save staged changes" and "Save all values" are two buttons because they are two different things to want. The check, apply, job and secret code of 18.22 is kept |
| D109 | **The CI gate runs on Ubuntu 22.04 only** (the owner's decision, 2026-11-11; replaced by D110 the same day). `ci.yml` has `os: [ubuntu-22.04]`, so the check is `gate (ubuntu-22.04)`; the required checks of `main` no longer name `gate (ubuntu-24.04)` (changed on GitHub before this was merged, because a required check that no longer exists would block every merge). The matrix stays a list of one, so the name of the check does not change and a second system is one line. What this gives up: the tools of the 24.04 runner (shellcheck, shfmt, bats, Go) are no longer run against the code; Ubuntu 24.04 stays a supported platform, confirmed by a run on a stand as section 11 asks, not by the CI. The other jobs (`lint workflows`, the security jobs, the release and the Suricata watch) still use the `ubuntu-24.04` runner image |
| D110 | **The CI gate moves to Ubuntu 24.04** (the owner's decision, 2026-11-11, replacing D109). `ci.yml` has `os: [ubuntu-24.04]`, so the check is `gate (ubuntu-24.04)`; the required checks of `main` name it instead of `gate (ubuntu-22.04)` (changed on GitHub before the workflow, so no merge was ever left waiting for a check that does not exist). It is still a list of one. What it gives up is the mirror of D109: the tools of the 22.04 runner are no longer run against the code, and Ubuntu 22.04 stays a supported platform, confirmed by a run on a stand (section 11). The other jobs already use the `ubuntu-24.04` runner image, so after this every job of the CI runs on one image |

Tests: `tests/settings_v2.bats` (14), `panel/internal/api/profiles_test.go` (6: the JSON passes through, the pairs go on stdin sorted with the user on `--by`, every bad name and body is refused before the verb, delete, the exit codes, the permissions against every role), the four routes in the permission table of `users_test.go`, `panel/web/test/settings2.test.mjs` (22). The full gate (shfmt, shellcheck, security, bundle, bats, gofmt, vet, go test, the panel scripts) was run on the final tree.

Open: the screen was not rendered in a browser (none is available in the build environment), so the layout, the dimming and the narrow view are tested as DOM behaviour and CSS text, not as pixels. Nothing ran against a real host: the checks use the stubs of the other settings tests. The config reference generated from the schema (`docs`, EN and RU) does not yet list dependencies or what a key touches; they are in `settings list --json` and on the screen. The rules are the guided setup's, so a dependency that 4.3 states but the guided setup never had is not on the screen (`EVE_MAX_SIZE_MB` and `EVE_ROTATE`). "Save all values" stores machine specific keys such as `IFACES` and `HOME_NET`, and a profile is checked only against the config of the host that saves it. There is no way to rename a profile (save under the new name and delete the old) and no export or import of a profile between hosts. Search looks at names, descriptions and group titles, not at values.

### 18.45 Slice 45: security of the panel (v0.46.0)

**Status:** done. The last of the slices of 18.0.

**What it does:** the list of your own sessions with a button to end one; API tokens that are read only or hold a role; a way to make every session worthless at once (the owner asked for "rotation of the session secret", and there is none: see R231); the history of sign ins; and a security check of the access mode, TLS, default ports, accounts that do not sign in, and the permissions of the rule files, shown as a list with a hint for each fix.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R231 | medium | the spec asks for "rotation of the session secret", but **there is no session secret**: a session is a random 256 bit token that lives in the memory of the panel (a restart ends all of them), and a cookie is not signed, so there is nothing to rotate and a key would add a thing to lose | the same protection another way: an administrator can **sign everyone out**, which ends every session and so every cookie ever given out; the page says there is no key and why. Nothing was invented to match the word |
| R232 | medium | a person could not see or end their own sessions: a stolen cookie lives until it expires (12 hours) and was invisible | sessions keep where they were opened from (the address the panel saw and the client string, cut to 120 characters, control characters dropped); the page lists them, marks the current one, ends one or all the others; a session is named by a handle (a hash of its id), so the id never reaches the page |
| R233 | low | `tokens create --days 08` would have been an octal error in the bash arithmetic (shellcheck pointed at the condition, the cause was one line away) | the value is read with `10#`; a test makes a token for `08` days |
| R234 | low | after a refused token the screen read its lists again and that wiped the server's explanation, the same fault as R226 in the Alert Center; the node test found it | a refused request returns before it reads anything again |

Decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D111 | **Sign everyone out takes the place of rotating a secret** (R231). `POST /api/security/sessions/revoke-all`, `users.manage`, a session only, asks for a confirmation on the page, clears the cookies of the browser that sent it, and is audited with the number of sessions ended. API tokens are not touched by it (they are revoked one by one), and the page says so |
| D112 | **A token is a secret that is shown once and kept as a hash.** `dpt_` and 43 characters of base64url from 32 random bytes; `api-tokens.json` holds its SHA-256, an id of 8 hex digits, a name, the owner, the scope, and the times of making and expiry. A plain SHA-256 is enough because there is nothing to guess; the panel compares every entry in constant time. The file is beside `users.json` (0640 root:dpistack), so the panel finds it without a new flag or a change to the unit (the path is the directory of `-users-file` and `api-tokens.json`); it is written only by `dpistack tokens`, under a lock, replaced atomically; a damaged file counts as no tokens and lets nobody in. The secret goes to the standard output of `tokens create` and nowhere else: a test searches the whole tree for it |
| D113 | **A scope is `read` or a role, and a token never holds more than its owner.** `read` keeps what the owner may read and the API refuses every method that is not GET, HEAD or OPTIONS; `viewer`, `analyst`, `operator`, `admin` hold that preset role's permissions, and only those the owner also holds **at the time of each request** (so a user who loses a permission takes it from the tokens at once, and a disabled account kills them). `tokens create` refuses a scope that holds more than the owner may do. Every token expires: 1 to 365 days, 90 by default, and there is no "never". Any signed in user may make tokens for themselves (least privilege is in the cap, not in a new permission); at most 10 an account and 100 in all |
| D114 | **Tokens do not manage tokens or sessions.** The routes `/api/security/sessions*` and `/api/security/tokens*` refuse a request that came with a token (403), so a leaked token cannot make another one that outlives its own revoking, and cannot end the sessions of its owner |
| D115 | **Only wrong tokens are counted.** An address that sends 30 wrong tokens in the 5 minutes of the sign in window gets 429 for every token, a right one included, until the window passes; a right token is not counted, so a busy script is never locked out by its own traffic. The cap and the window are not config keys. A token also never falls back to a cookie: a request with an `Authorization` header is judged by it alone. The `Bearer` word is case-insensitive, as in the metrics export |
| D116 | **The sign in history is the audit log.** Every sign in, right or wrong, already has a line (`POST /api/login`, the name typed, the address, `ok`, `denied` or `error`); nothing new is stored. One's own history is for any user; another user's or everyone's needs `audit.view`; 1 to 200 entries. As before, the name typed for a failed sign in is recorded as typed |
| D117 | **The security check is six items with a level and a fix.** `access-mode` (a LAN or nginx exposure is named; localhost is fine), `tls` (plain HTTP over a network is a warning), `default-ports` (the `*_PORT` keys of components that are on, at their defaults, **only when the network can reach them**; it uses the same rules as the Settings screen to know that a component is on), `stale-users` (accounts, not disabled, with no right sign in in the audit log and its rotated files for 90 days, an account newer than that is not stale; with no audit log the item is `na`, not ok), `rules-files` (the rule set, `local.rules` and its directory: writable by everyone is critical, owned by someone other than root is a warning), `secret-files` (`secrets.conf`, `users.json`, `api-tokens.json` open to everyone is critical). 90 days is a constant. It runs as root, changes nothing, and is shown to users with `audit.view` |
| D118 | **The screen.** A Security entry in the Admin group; the lists refresh every 30 seconds and the check only when asked, because it runs a command on the machine; the controls that need a permission are hidden without it and their requests are not made; the form offers all five scopes and shows the server's words when one is refused; the secret box is cleared by its button and when the screen is left; the confirmations are plain `confirm` questions as elsewhere |

Tests: `tests/panel_security.bats` (20), `panel/internal/auth/security_test.go` (9), `panel/internal/api/security_test.go` (24), the nine routes in the permission table of `users_test.go` (against every role), `panel/web/test/security.test.mjs` (16). The full gate (shfmt, shellcheck, security, bundle, bats, gofmt, vet, go test, the panel scripts) was run on the final tree.

Open: the screen was not rendered in a browser (none is available in the build environment). Nothing ran against a real host: the panel's tests use stub verbs and the verbs' tests use stub systems. `last_used` of a token is only since the panel started, because the panel writes no file; a restart forgets it. A session is in memory, so the list is what this process knows, and a restart ends them all (as before). The "client" of a session is the string the browser sent, shown as it is. Access to the API is by address: behind nginx the address is the one that `X-Forwarded-For` gives, as in 18.16, so the 30 wrong tokens are counted for that address. The security check does not look at the strength of passwords, at the TLS certificate (its age or issuer), at sudoers, or at who can read the audit log; the spec named five things and a few more were added (secret files), nothing else. A token stops working at once when its owner is disabled, but is not deleted from the file until someone revokes it. `tokens` and `security` have no sudo rule of their own: the panel runs them as every other verb (`sudoers` names `dpistack`, which checks its own arguments).

### 18.46 Field report of 2026-11-05: EveBox "code 14" and a panel that stayed on v0.32.1 (v0.37.3)

**Status:** closed by 18.47 (the cause was an AppArmor profile). This entry records what was known, what was ruled out and what was added so the next run finds it. Source: `dpistack_log.txt` and two screenshots from a Debian 13 host (`debian-home`).

| No | Severity | Finding | Fix |
|---|---|---|---|
| R190 | high | After an update at about 17:00 EveBox exits at every start with `ExecuteMigration(... code 14 "unable to open database file", 3)` (`src/sqlite/connection.rs:212`, the events database) and keeps failing after a reboot. Before that it ran for days (last good start 12:48, bookmark found). The unit runs as `User=evebox` (the package unit). Ruled out in the lab: a fresh database does go through migrations 1 to 3 as an unprivileged user, also with an unusable temp directory; the installer never runs `evebox` itself as root; there is no hardening drop-in for EveBox; the data directory fix of v0.29.1 (`evebox_prepare_data_dir`) is in the code. Code 14 is the answer to any failed `open()` (owner, a directory the user cannot write, a full file system or no inodes, a file system without the locking SQLite's WAL needs), and the journal does not say which | `diagnose evebox` prints the environment after the journal: unit user and group, owner and mode of the directory and of every file in it, whether the service user can create a file there (the probe is made with `runuser`), file system type, free space and inodes, whether the user can write to `/tmp`, and ends with `found:` lines for each cause it can name, or says that the environment looks fine. Six bats cases. **Still open:** the output of that command on the host |
| R191 | high | Any failed step stops the installer (`step <id> failed`), and `panel`, `watch` and `verify` come after `evebox` in `STEPS_ORDER`. If the EveBox step fails during an update, the panel is neither rebuilt nor given its new `-version`, which is one way to see "v0.32.1, latest v0.37.0". It does not explain why the screenshot of the Overview shows the new design while Build info says v0.32.1 | not changed: the owner asked for the cause to be fixed, not hidden by letting later steps run past a failure. To decide once the cause of R190 is known |
| R192 | low | the panel takes its version from the installer that wrote its unit (`-version`), so a stale value means the unit was not re-rendered by a newer installer | none; noted for the next report |
| R193 | low | the setup prompts show nine optional settings as `<empty>` (`BPF_FILTER`, `NTOPNG_IFACES`, `SURICATA_VERSION`, `NDPI_VERSION`, `NTOPNG_VERSION`, `EVEBOX_VERSION`, `EVE_REDIS`, `EVE_MAX_SIZE_MB`, `RULES_URLS`); it means "not set" and the prompt does not say what that does | closed in 18.48: `schema_empty_meaning`, shown under the prompt as `empty means: ...` |
| R194 | medium | the write probe of `diagnose evebox` used a file named with `$$`; the shell security check of the push (`scripts/security.sh`, no `$$`-named temp files) failed on it. Found by the CI, not by the gate that was run before the push, because that run was cut short | the probe is made with `mktemp` run as the service user (`runuser -u <user> -- mktemp`), so the name is not predictable and the file belongs to the user it tests; `scripts/security.sh` is clean and the six bats cases pass |

Open: ask the owner for `sudo dpistack diagnose evebox` (or, with the old version, the commands in the answer of 2026-11-05) and for the text of the update error; the slow disk is a second suspect (EveBox needed 25 s to open its databases at the boot of 07:26, a commit took 6 s at 16:07, and the first start after the boot of 10:14 ended with `pool timed out`).

### 18.47 Field report of 2026-11-06 and 07: the cause of EveBox "code 14", the empty `tls` event, a log review (v0.37.5)

**Status:** done (R202 closed in 18.48). Source: `dpistack_log.txt` of a Debian 13 host (`debian-home`, btrfs on `md0`) and the output of the commands run on it one by one. Every cause below was proven on the host, not guessed.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R195 | high | EveBox exits at start with `ExecuteMigration(... code 14, 3)`. `strace` showed `open("/var/tmp/etilqs_...", O_CREAT\|O_EXCL) = -1 EACCES` and the kernel log `apparmor="DENIED" operation="mknod" profile="evebox" name="/var/tmp/etilqs_..."`. SQLite writes a temp file there when a transaction is big (the migration of a fresh events database is). A shell probe as the same user succeeded because it ran under another profile. After a reboot with AppArmor off EveBox started | the profile on that host did not come from this installer (no file in `/etc/apparmor.d`), so the installer is not changed for it. A host that keeps the profile can set `SQLITE_TMPDIR=/var/lib/evebox` in a drop-in of `evebox.service` (not tested on the host). `diagnose` should show the denial: R202 |
| R196 | medium | `diagnose evebox` said "almost no free inodes" on btrfs. btrfs has no fixed inode table; `df -i` shows 0 | the inode count is judged only where the file system reports a total; otherwise the line says `no fixed number of inodes` |
| R197 | medium | the temp directory check tested `/tmp` only, while SQLite tries `$TMPDIR`, `/var/tmp`, `/usr/tmp`, `/tmp` in this order | the first directory the service user can use is shown with its file system and free space; none usable, or less than 50 MiB free, is a finding |
| R198 | high | the HTTPS self-test failed on a host where Suricata saw the traffic (319370 packets, no drops, no checksum errors, offloading off). The `tls` events had `"tls":{}` or only the certificate: no `sni`, no version. Replaying one capture: without the nDPI plugin the same; with `extended: yes` under `- tls:` the event has `sni`, `version`, `ja3` | `suricata_render_eve_types_block` renders `tls` as `- tls:` with `extended: yes` (bats cases added) |
| R199 | medium | every `suricata-update` call warned `Source index does not exist`, and three times `does not exist` for `disable.conf`, `modify.conf`, `drop.conf`, which the update command names. D28 of 18.32 had left these as they are | `update-sources` runs before the sources are enabled (a failed download is a warning, the bundled index is used); the three list files are created empty with one comment line when missing and never touched when they exist; `rules check` is not up to date while one is missing |
| R200 | low | the lock message said "wait for it to finish" for a holder suspended with Ctrl+Z (a build stopped at 242 of 243), which never ends | a holder in state `T` is named as suspended, with `fg` and `kill` |
| R201 | low | the HTTPS failure said only "check that Suricata sees the interface" | it counts the other events that appeared in `eve.json` meanwhile: none points to the capture, some point to the parsing and the offloading |
| R202 | low | `diagnose evebox` does not read the kernel log for AppArmor denials | closed in 18.48 |

Messages left as they are, with the reason: `ERROR: Bindings changed` (cbindgen `--verify` in the Suricata Makefile ends in `|| true`), the JSON-C note of the nDPI configure (unit tests only), the libtool note on a static library, `libunwind not found` (stack traces on a crash only; the package name on the RHEL family is not verified).

### 18.48 R202, R193 and two keys that were never read (v0.37.6)

**Status:** done. The first items of the open list of 18.46 and 18.47, taken before the remaining parts of slices 37 and 38. Decisions on the two unread keys were left to the assistant ("choose yourself") and are recorded here.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R202 | low | `diagnose evebox` did not read the kernel log, so an AppArmor denial like R195 stayed invisible | `evebox_kernel_denials` takes the last five lines of `journalctl -k` (or `dmesg`) that hold `apparmor="DENIED"` or `avc: denied` and name evebox; they are printed and a `found:` line names the cause, with the `SQLITE_TMPDIR` drop-in as the way out for a SQLite temp file. The `SQLITE_TMPDIR` advice is still not tested on a host. Two bats cases (a denial of evebox is shown, a denial of another program is not blamed on it) |
| R193 | low | the prompts showed `<empty>` for nine optional keys and not what it means | `schema_empty_meaning` (lib/schema.sh) gives one line per key, shown by both prompts as `empty means: ...`. Two bats cases (the text, and that every one of the nine has it) |
| R203 | medium | `EVE_SYSLOG` was offered in the menu, the panel and the docs and nothing read it (known since 18.1, left open); checking R193 showed `EVE_REDIS` was the same. A setting that does nothing breaks the rule of 18.0 that nothing is shown that the program cannot do | `EVE_SYSLOG=yes` renders a second `eve-log` output (`filetype: syslog`, facility `local5`, level `Info`, identity `suricata`) with the same `EVE_TYPES`; the file output stays, EveBox and the panel read it. Two bats cases. Decision for `EVE_REDIS`: the Redis output needs a Suricata built with hiredis, which neither the build step (`libhiredis` is not among the build dependencies) nor the packages of every platform are known to have, and no host was available to check it, so a value was refused with exit code 2 (superseded in 18.51: a value is now ignored with a warning, because the refusal stopped an update) |
| R204 | low | in `step_suricata.sh` the size rotation had a fallback of 100 MB that could never run, because the config check already refuses `EVE_ROTATE=size` without `EVE_MAX_SIZE_MB` | not changed (surgical edit); the prompt hint says what really happens |

Open: the real Suricata check of the syslog output (`suricata -T` on a rendered config with `EVE_SYSLOG=yes`) was not run, only the rendering is tested; the facility is not configurable; the Redis output (needs hiredis in the build and in the package check). The Go and interface tests were not run in this session (no Go 1.26 here); the CI runs them.

### 18.49 Slice 37 (third part): the top bar (v0.38.0)

**Status:** slice 37 is done except the alert bell, which waits for slice 43 (rule 1: nothing is shown that the program cannot do, D52).

What is in the corner of every screen, left to right: the host name, the overall state of the watchdog, the mode (IDS or IPS), the translation note, the version pill, the GitHub link and the user menu. The three chips only show what the server says and have no controls (the switches stay on their screens). The user menu holds Account (hidden for a user without permission, the same rule as the menu), Theme (only where the page has both palettes) and Sign out; the `logout` element kept its id.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R205 | medium | `GET /api/system` had no host name, so a top bar could not name the host | `Info.Hostname`, read from `proc/sys/kernel/hostname` under the configurable proc root like every other field, empty when unreadable; Go tests for the name and for a missing file (run in a throwaway module here, the CI runs them in the real one) |
| R206 | medium | the theme override would have hidden the switch by itself: a chosen theme changes the `color-scheme` the page reports, and the check "does the page have both palettes" reads it | the check runs once, before any theme is applied |
| R207 | low | a failing source (404 of `/api/system`, 503 of the mode) must not sign the user out or blank the other chips | each chip is painted from its own answer; only a 401 is passed on; tests for a failing source and for a 401 |

Decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D65 | **The theme switch exists only in the lite edition.** The full edition is dark by design (a short list of flat dark backgrounds, 9.1), so offering "light" there would need a second palette outside the design rules; the item stays hidden (`color-scheme` of the page is `dark` only). In lite the choice is system, light or dark, kept in `localStorage` (`dpistack.theme`, read and written inside `try`), applied as `data-theme` on the root; two rules in `lite.css`, placed after the media block, win over the system colours |
| D66 | **No bell yet.** It waits for the alert store of slice 43 (done there, D101) |
| D67 | **The chips poll on their own every 15 s** (`/api/status`, `/api/system`, `/api/mode`), independent of the screen shown, and stop when the user signs out |

Tests: `panel/web/test/topbar.test.mjs` (13), `TestReadHostState` and `TestMissingHostnameIsEmptyNotFailure` in `panel/internal/system`.

Open: nothing was rendered in a browser (none is available in the build environment); the look of the chips, the menu popover and the narrow layout is checked only by the design rules; the first request of the chips duplicates the Overview's own polls while the Overview is open.

### 18.50 Slice 38 (last part): the Network screen (v0.39.0)

**Status:** slice 38 is done. What was left was the interfaces page and the topology; the docker and systemd state is decided in D70 and needs no new code.

What the screen shows (menu group Monitoring, next to Overview, the permission `view`): the capture chain as boxes in order (host, capture interfaces, Suricata with the mode, eve.json with the freshness the watchdog already measures, EveBox), then the other installed parts with their own state and no arrow, then the table of the interfaces (the same rows as the Overview: state, speed, received, sent, dropped, errors, capturing). It reads only; adding or removing a capture interface stays on Components, where it is confirmed and applied. The Overview keeps its own interfaces table.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R208 | medium | a topology can lie by drawing a line that does not exist: ntopng captures on its own and the panel does not know on which interfaces, so a line from the interfaces to ntopng would be a guess | the chain holds only what the stack guarantees (capture feeds Suricata, Suricata writes `eve.json`, EveBox reads it); every other installed part is listed with its state and no arrow (D68) |
| R209 | low | a stage built from a source that failed would look healthy if drawn with defaults | `topology` leaves a stage out when its source did not answer (no host name, no capture flag, no Suricata, no freshness check); with nothing left the screen says so; tests for each omission |

Decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D68 | **The chain is the guaranteed path only** (R208). The stages come from `/api/status` (components, the check `suricata.eve_fresh`), `/api/system` (host name, interfaces with `capture`) and `/api/mode`; no new endpoint, in the pattern of D58. A component that is not installed is not drawn; a stopped one that starts on boot is a warning, one that does not is shown without a level |
| D69 | **The screen is read only and polls on its own** every 10 s while it is open; a failing source is left out and only a 401 signs the user out; when both `/api/status` and `/api/system` fail the screen says that the host state could not be read |
| D70 | **No new docker or systemd probe.** `systemd_present` and `docker_socket` stay what D56 says they are (a directory and a file). Whether a part is healthy is the state of the part in `/api/status`, which the chain and the Overview already show, so a second, weaker probe would only add a way to disagree with it. The panel never runs `docker` or `systemctl` itself |

Tests: `panel/web/test/network.test.mjs` (14): the order of the chain, the capture stage, no capture interface, an unknown capture flag, IDS and IPS wording, the freshness check, a part that is not installed, a missing source, the levels, the other parts, a failing source, a 401, both sources failing, the page and the route. The menu test "every screen is in exactly one group" covers the new entry.

Open: nothing was rendered in a browser (none is available in the build environment), so the look of the boxes, the arrows and the narrow layout (where the arrows turn down) is checked only by the design rules; the interface counters are totals since boot, no rate; the Overview and this screen both read `/api/system` while each is open; ntopng's own interfaces (`NTOPNG_IFACES`) are not shown on the screen.


### 18.51 R210: the update stopped by `EVE_REDIS` (v0.39.1)

**Status:** done. A field report of 2026-11-07: the Update button of the panel failed, the audit said `self-update apply error (exit 2)`, and `sudo dpistack self-update apply` printed `The config failed validation: EVE_REDIS is not supported yet`.

| No | Severity | Finding | Fix |
|---|---|---|---|
| R210 | **high** | v0.37.6 (18.48, R203) made a non-empty `EVE_REDIS` a validation error. The key had been in the menu, the panel and the docs since slice 1 and did nothing, so a saved config could hold a value; the update runs the new installer with `-y` on that saved config, so every such stand was stopped at validation (exit 2) and could not take any later release, the update button included. My test only checked that a fresh `--set EVE_REDIS=...` was refused and never asked what an old config would do | the refusal is removed from `config_validate`. `suricata_warn_redis_unused` (step_suricata.sh) logs `EVE_REDIS=<value> is ignored: ...` as a warning when the value is not empty, `no`, `off`, `none` or `false`, and the value changes nothing in `suricata.yaml`. Hints (panel and Russian), the prompt text and the generated docs say "ignored with a warning". Bats cases: a value does not fail validation (`install --dry-run -y --set EVE_REDIS=...`), the warning and the silent off values, and the rendered `eve-log` is the same with and without a value |

Decision (D71): **a setting that does nothing is a warning, never a validation error, when it can already be in a saved config.** A new refusal is allowed only for a key that is new or for a value the program could not have accepted before; anything else must not be able to stop an update or a reconfigure. This applies to the next time a dead key is retired.

Until the fix is installed, a stand in this state can empty the key by hand (`EVE_REDIS=` in `/etc/dpistack/dpistack.conf`) and run `sudo dpistack self-update apply` again.

Open: no other validation added in 18.46 to 18.50 was re-checked against the configs of older releases; a test that feeds the validation a config written by an old release (the example file of an earlier tag) is not there yet. The panel's update dialog and the audit line still show only the exit code, not the refusal line.

### 18.52 The live BitTorrent check and a drop-in on the panel unit (v0.39.2)

**Status:** done. From a field report of 2026-11-07 (Debian 13, clean reinstall of v0.39.1). Two findings; the stand itself was healthy (13 of 13 health checks ok, the HTTPS test passed).

| No | Severity | Finding | Fix |
|---|---|---|---|
| R211 | **high** (a test that fails on a healthy stand) | `dpistack test bittorrent` with `TEST_BT_LIVE=yes` failed: "the offline check passed, but the live eve.json has no event after tcpreplay". Measured on the stand: the replay sent 53 of 53 packets, the capture counter of `enp2s0` rose by 523 packets with no drops, 15 BitTorrent rules were loaded, and the same pcap run through the live config and live rules gave 0 alerts. The offline check passes only because, with the nDPI plugin, the test adds a rule of its own (`any any`, sid 9000001) to a temporary config; the live Suricata never had it, and the Emerging Threats rules do not match a pcap whose two hosts are both private (`10.10.10.22` and `.23`, both inside `HOME_NET`). The live part had been written as "the same test, live" and was never able to pass without luck | the live Suricata gets its own rule: `dpistack-test.rules` (one rule, sid 9000100, `any any -> any any`, on `|13|BitTorrent protocol`), written by the Suricata step before `suricata -T` and listed in `suricata.yaml` (`@@RULE_FILES_EXTRA@@`) only while `TEST_BT_LIVE=yes` and Suricata is native; the check on the step also compares the file. The key's step in the schema is now `suricata` (it was `verify`), so changing it re-renders the yaml and restarts Suricata, which a rule file needs. The failure text names the interface, the file and `dpistack reconfigure`. Bats cases: the yaml lists the file for `yes` and not for `no` or for a container, the rule text matches the handshake that is in the pcap (read from the file), the file is written only for `yes` |
| R212 | medium | a hand-written drop-in `dpistack-panel.service.d/10-bind-lan.conf` replaced the `ExecStart` of the unit with an old command line (`-version 0.32.1`, no `-backups-dir`). After a clean reinstall of 0.39.1 the corner and the update notice said 0.32.1, the Update button said "no newer release than 0.39.1", and the Backups download was off; the installer never said that its unit was not the one that ran | `panel_warn_unit_overrides` (step_panel.sh) logs a warning that names the file when a drop-in sets a non-empty `ExecStart=`; the file is never touched; a drop-in that only resets `ExecStart=` or sets other things says nothing. Two bats cases |

Decisions ("choose yourself"):

| id | decision |
| --- | --- |
| D72 | **The live check proves capture, rules and `eve.json`, not nDPI.** It uses a content rule, so a stand where the nDPI plugin is broken still passes the live part; the plugin is covered by the offline check (the plugin rule) and by `ndpi_plugin: loaded`. A live check that relied on `ndpi-protocol` would need the plugin on every stand, and one that relied on Emerging Threats would depend on addresses |
| D73 | **A foreign drop-in is warned about, not removed or merged.** The file belongs to the owner. The warning says what to use instead (`BIND_ADDR`, `LAN_CIDR`); `LAN_CIDR` takes a comma list, so the extra Docker network of the report fits |

Open: the warning for a foreign `ExecStart` is only for the panel unit (the other units were not checked); `diagnose` does not report it, only the installer run does; with Suricata in a container the live check is still skipped; the real run of `test bittorrent` on a stand with the new rule is for the owner to confirm; the rule also alerts on a real BitTorrent client, which is stated in section 10.
