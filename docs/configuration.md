# Settings reference

English | [Русский](configuration.ru.md)

The file `/etc/dpistack/dpistack.conf` (`KEY=VALUE` format, one line per key). Secrets live apart, in `/etc/dpistack/secrets.conf` (mode 0600), and are shown nowhere: the panel and `dpistack settings list` print only "set" or "not set".

You can change settings in three ways: the Settings screen of the panel, `dpistack settings set` and `dpistack reconfigure`. The "Change" column says what a change costs: a **light** one applies at once (the config is rendered again and the affected service restarts), a **heavy** one starts an install or a rebuild of a component and runs as a separate job.

The file is made by `scripts/gen-config-doc.sh` from the key schema; do not edit it by hand.

## Traffic capture

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `SURICATA_MODE` | ids \| ips | `ids` | light | ids only watches, ips can block. Switching is best done on the Components screen. (advanced) |
| `IFACES` | string | `enp2s0` | light | Interfaces Suricata captures from, comma separated. |
| `BPF_FILTER` | string | empty | light | BPF filter: which traffic to skip or to analyze. (advanced) |
| `HOME_NET` | string | `auto` | light | Your networks (CIDR, comma separated) or auto: detect from the interfaces. (advanced) |
| `IPS_METHOD` | nfq \| afpacket | `nfq` | light | How IPS gets packets: the NFQUEUE queue or AF_PACKET. (advanced) |
| `IPS_NFQ_CHAINS` | string | `INPUT,OUTPUT,FORWARD` | light | iptables chains that send packets to the queue. (advanced) |
| `NTOPNG_IFACES` | string | empty | light | ntopng interfaces. Empty: the same as Suricata's. (advanced) |

## Components and installation

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `SURICATA_RUNTIME` | native \| docker | `native` | heavy | Where Suricata runs: on the host or in a Docker container. |
| `EVEBOX_RUNTIME` | native \| docker | `native` | heavy | Where EveBox runs: on the host or in a Docker container. |
| `NTOPNG_RUNTIME` | native \| docker | `native` | heavy | Where ntopng runs: on the host or in a Docker container. |
| `SURICATA_SOURCE` | distro \| oisf \| source | `source` | heavy | Where Suricata comes from: the distribution package, the OISF package or a build from source. |
| `SURICATA_VERSION` | string | empty | heavy | Pinned Suricata version. Empty: the latest stable. (advanced) |
| `NDPI_ENABLE` | yes \| no | `yes` | heavy | Application detection with nDPI in Suricata. |
| `NDPI_SOURCE` | pkg \| source | `source` | heavy | nDPI from a package or built from source. (advanced) |
| `NDPI_VERSION` | string | empty | heavy | Pinned nDPI version. Empty: the latest stable. (advanced) |
| `NTOPNG_VERSION` | string | empty | heavy | Pinned ntopng version. (advanced) |
| `EVEBOX_VERSION` | string | empty | heavy | Pinned EveBox version. (advanced) |
| `PIN_VERSIONS` | yes \| no | `no` | heavy | Pin the installed versions so a system update does not change them. |
| `PANEL_SOURCE` | auto \| build \| prebuilt | `auto` | heavy | How to get the panel program: build it, take a ready one or choose automatically. (advanced) |
| `PANEL_RUNTIME` | native \| docker | `native` | heavy | Where the panel runs: as a service on the host or as a Docker container (host commands go through nsenter). |
| `PANEL_EDITION` | full \| lite | `full` | light | Which panel to install: full (rich design, background effects) or lite (the same features on a plain, light page). |

## Events and storage

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `EVE_FILE` | yes \| no | `yes` | light | Write events to eve.json (needed by the panel and the watchdog). (advanced) |
| `EVE_TYPES` | string | `alert,flow,dns,tls,http,stats` | light | Which event types to write to eve.json. |
| `EVE_SYSLOG` | yes \| no | `no` | light | Duplicate events to syslog. (advanced) |
| `EVE_REDIS` | string | empty | light | Send events to Redis (an address like host:port/list). (advanced) |
| `EVE_ROTATE` | daily \| weekly \| size | `daily` | light | How to rotate eve.json: daily, weekly or by size. (advanced) |
| `EVE_KEEP` | integer 0..3650 | `14` | light | How many rotated files to keep. (advanced) |
| `EVE_MAX_SIZE_MB` | integer 1..1000000 | empty | light | File size in MB that triggers rotation (the by-size mode). (advanced) |
| `STATS_INTERVAL_SEC` | integer 5..300 | `30` | light | How often Suricata writes statistics (seconds). (advanced) |
| `EVEBOX_DB` | sqlite \| elasticsearch | `sqlite` | heavy | Where EveBox stores events. (advanced) |
| `EVEBOX_ES_URL` | string | empty | light | Elasticsearch address for the elasticsearch mode. (advanced) |
| `EVEBOX_RETENTION_DAYS` | integer 0..36500 | `30` | light | How many days EveBox keeps events (0: no limit). (advanced) |

## Rules

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `RULES_SOURCES` | string | `et/open` | light | suricata-update rule sources, space separated. (advanced) |
| `RULES_URLS` | string | empty | light | Your own rule set addresses, space separated. (advanced) |
| `RULES_GROUPS` | string | `emerging-p2p,emerging-policy` | light | Enabled rule groups, comma separated. (advanced) |
| `RULES_UPDATE` | on \| off | `on` | light | Update the rules on a schedule. (advanced) |
| `RULES_UPDATE_CALENDAR` | string | `weekly` | light | When to update: daily, weekly or a systemd expression. (advanced) |

## Access and ports

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `EVEBOX_PORT` | integer 1..65535 | `5636` | light | EveBox port. (advanced) |
| `ACCESS_MODE` | localhost \| lan \| nginx | `localhost` | light | Who can open the panels: localhost, the local network or through nginx. |
| `BIND_ADDR` | string | `auto` | light | Address the web services listen on: auto (127.0.0.1, or every address in lan mode) or one IPv4 address of this host, for example 192.168.1.156. A non-loopback address opens the panels to LAN_CIDR. |
| `LAN_CIDR` | string | `auto` | light | The network allowed in lan mode, or auto. (advanced) |
| `PANEL_PORT` | integer 1..65535 | `9800` | light | Port of this panel. (advanced) |
| `NTOPNG_PORT` | integer 1..65535 | `3000` | light | ntopng port. (advanced) |
| `NGINX_MANAGE` | yes \| snippet | `snippet` | light | How to manage nginx: replace the configuration or only drop in a fragment. (advanced) |
| `NGINX_TLS` | none \| selfsigned \| existing | `none` | light | TLS on nginx: none, self-signed or your own certificate. (advanced) |
| `NGINX_CERT` | string | empty | light | Path to the certificate for the existing mode. (advanced) |
| `NGINX_KEY` | string | empty | light | Path to the key for the existing mode. (advanced) |
| `FIREWALL_MANAGE` | no \| auto | `no` | light | Open the needed ports in the firewall by itself. (advanced) |

## Metrics

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `METRICS_EXPORT` | yes \| no | `yes` | light | Serve the panel metrics at /metrics with a token. (advanced) |
| `METRICS_BACKEND` | none \| victoriametrics \| prometheus | `none` | heavy | Metrics storage: none, VictoriaMetrics or Prometheus. |
| `METRICS_BACKEND_RUNTIME` | native \| docker | `native` | heavy | Metrics storage on the host or in Docker. (advanced) |
| `METRICS_BACKEND_PORT` | integer 1..65535 | empty | light | Metrics storage port. (advanced) |
| `METRICS_RETENTION` | string | `30d` | light | How long to keep metrics, for example 30d. (advanced) |
| `NODE_EXPORTER_ENABLE` | yes \| no | `no` | heavy | Install node_exporter (CPU, memory, disk and network of the host); the metrics storage scrapes it. |
| `NODE_EXPORTER_RUNTIME` | native \| docker | `native` | heavy | Where node_exporter runs: on the host or in a Docker container. (advanced) |
| `NODE_EXPORTER_PORT` | integer 1..65535 | `9100` | light | node_exporter port. (advanced) |
| `GRAFANA_ENABLE` | yes \| no | `no` | heavy | Install Grafana for dashboards; the metrics storage becomes its default data source. |
| `GRAFANA_RUNTIME` | native \| docker | `native` | heavy | Where Grafana runs: on the host or in a Docker container. (advanced) |
| `GRAFANA_PORT` | integer 1..65535 | `3030` | light | Grafana port. The first login is admin/admin and Grafana asks for a new password. (advanced) |
| `METRICS_TOKEN` | secret | empty | heavy | Access token for /metrics. Stored apart. (advanced) |

## Watch and alerts

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `WATCH_ENABLE` | yes \| no | `yes` | light | Background watch over the components. (advanced) |
| `WATCH_INTERVAL_SEC` | integer 10..3600 | `60` | light | How often the watchdog checks the state (seconds). (advanced) |
| `WATCH_EVE_STALE_SEC` | integer 10..86400 | `300` | light | After how many seconds of silence eve.json counts as stuck. (advanced) |
| `WATCH_DROP_WARN_PCT` | integer 0..100 | `1` | light | Percent of dropped packets for a warning. (advanced) |
| `WATCH_DROP_CRIT_PCT` | integer 0..100 | `5` | light | Percent of dropped packets for an alarm. (advanced) |
| `WATCH_DISK_WARN_PCT` | integer 0..100 | `15` | light | Free disk space (%) for a warning. (advanced) |
| `WATCH_DISK_CRIT_PCT` | integer 0..100 | `5` | light | Free disk space (%) for an alarm. (advanced) |
| `WATCH_RULES_WARN_DAYS` | integer 0..3650 | `10` | light | Age of the rules (days) for a warning. (advanced) |
| `WATCH_RULES_CRIT_DAYS` | integer 0..3650 | `30` | light | Age of the rules (days) for an alarm. (advanced) |
| `WATCH_REPEAT_MIN` | integer 0..1440 | `60` | light | After how many minutes to repeat the same alert. (advanced) |
| `WATCH_AUTORESTART` | yes \| no | `no` | light | Restart a failed component automatically (at most three times an hour). (advanced) |
| `ALERT_CHANNELS` | string | `panel,log` | light | Where to send alerts: panel, log, telegram, mail (comma separated). |
| `ALERT_TG_CHAT_ID` | string | empty | light | Telegram chat for alerts. (advanced) |
| `ALERT_MAIL_TO` | string | empty | light | Mail recipients, comma separated. (advanced) |
| `ALERT_MAIL_FROM` | string | empty | light | Sender address. (advanced) |
| `ALERT_TG_TOKEN` | secret | empty | light | Telegram bot token. Stored apart from the main configuration. (advanced) |
| `ALERT_SMTP_URL` | secret | empty | light | SMTP address, for example smtps://user:pass@host:465. Stored apart. (advanced) |

## Test checks

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `TEST_HTTPS_URL` | string | `https://example.com` | light | Address for the HTTPS check on the Tests screen. (advanced) |
| `TEST_BT_LIVE` | yes \| no | `no` | light | Check BitTorrent on live traffic instead of a file. (advanced) |
| `TEST_ON_INSTALL` | yes \| no | `yes` | light | Run the checks after installation. (advanced) |

