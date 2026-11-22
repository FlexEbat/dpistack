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
| `BPF_FILTER` | string | empty | light | BPF filter: which traffic to skip or to analyze. Examples: not port 22, host 10.0.0.5, net 192.168.0.0/16 and not port 53. Empty: all the traffic. (advanced) |
| `CAPTURE_THREADS` | string | `auto` | light | Capture threads per interface: auto (one per receive queue) or a number. Raise it when the drop rate is high and CPUs are idle. (advanced) |
| `CAPTURE_TPACKET` | auto \| v2 \| v3 | `auto` | light | AF_PACKET ring version: auto (Suricata decides), v2 or v3. v3 is faster on busy links; IPS over AF_PACKET needs v2. (advanced) |
| `CAPTURE_RING_SIZE` | integer 0..1048576 | `0` | light | Frames in the capture ring of each thread. 0: Suricata default. Raise it (for example 8192) when packets are dropped in bursts. (advanced) |
| `CAPTURE_BLOCK_SIZE` | integer 0..67108864 | `0` | light | Block size of the v3 ring in bytes. 0: Suricata default; otherwise a multiple of 4096 from 32768. (advanced) |
| `CAPTURE_CPUS` | string | empty | light | CPUs for the detection worker threads, for example 2-5,8. Empty: the system decides. (advanced) |
| `NIC_OFFLOADS_OFF` | yes \| no | `no` | light | Switch off GRO, LRO, GSO and TSO on the capture interfaces before each start of Suricata. They merge packets and hurt reassembly and detection. Needs the native runtime. (advanced) |
| `PCAP_MAX_MB` | integer 1..2048 | `100` | light | Largest capture file, in megabytes, that dpistack pcap analyze accepts. (advanced) |
| `FLOW_MEMCAP` | string | `128mb` | light | Memory for the flow table, for example 512mb or 1gb. Raise it when stats show flow memcap hits. (advanced) |
| `STREAM_MEMCAP` | string | `64mb` | light | Memory for TCP stream tracking, for example 256mb. Raise it when stats show stream memcap hits. (advanced) |
| `STREAM_REASSEMBLY_MEMCAP` | string | `256mb` | light | Memory for TCP stream reassembly, for example 512mb. Raise it when stats show reassembly memcap hits. (advanced) |
| `HOME_NET` | string | `auto` | light | Your networks (CIDR, comma separated) or auto: detect from the interfaces. (advanced) |
| `IPS_METHOD` | nfq \| afpacket | `nfq` | light | How IPS gets packets: the NFQUEUE queue or AF_PACKET. (advanced) |
| `IPS_NFQ_CHAINS` | string | `INPUT,OUTPUT,FORWARD` | light | iptables chains that send packets to the queue. (advanced) |
| `NTOPNG_IFACES` | string | empty | light | ntopng interfaces. Empty: the same as Suricata's. (advanced) |

## Components and installation

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `SURICATA_ENABLE` | yes \| no | `yes` | heavy | Install and run Suricata (the IDS/IPS engine). |
| `RULES_ENABLE` | yes \| no | `yes` | heavy | Install the rules and their automatic update (needs Suricata). |
| `EVEBOX_ENABLE` | yes \| no | `yes` | heavy | Install EveBox, the alert viewer. |
| `NTOPNG_ENABLE` | yes \| no | `yes` | heavy | Install ntopng, the traffic monitor, with its Redis. |
| `PANEL_ENABLE` | yes \| no | `yes` | heavy | Install this control panel. |
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

## Events and storage

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `EVE_FILE` | yes \| no | `yes` | light | Write events to eve.json (needed by the panel and the watchdog). (advanced) |
| `EVE_TYPES` | string | `alert,flow,dns,tls,http,stats` | light | Which event types to write to eve.json. |
| `EVE_SYSLOG` | yes \| no | `no` | light | Duplicate events to syslog (facility local5). (advanced) |
| `EVE_REDIS` | string | empty | light | Send the events to Redis as well: yes (Redis of this host), or host[:port][/key], for example 127.0.0.1:6379/suricata. Empty or no: eve.json only. Needs a Suricata built with Redis support (a source build has it). (advanced) |
| `EVE_REDIS_MAXLEN` | integer 1000..100000000 | `100000` | light | How many events the Redis stream keeps (EVE_REDIS). Redis trims it to about this length, so a stream that nobody reads cannot fill the memory. 100000 by default. (advanced) |
| `EVE_ROTATE` | daily \| weekly \| size | `daily` | light | How to rotate eve.json: daily, weekly or by size. (advanced) |
| `EVE_KEEP` | integer 0..3650 | `14` | light | How many rotated files to keep. (advanced) |
| `EVE_MAX_SIZE_MB` | integer 1..1000000 | `100` | light | File size in MB that triggers rotation (the size mode). 100 by default. (advanced) |
| `STATS_INTERVAL_SEC` | integer 5..300 | `30` | light | How often Suricata writes statistics (seconds). (advanced) |
| `EVEBOX_DB` | sqlite \| elasticsearch | `sqlite` | heavy | Where EveBox stores events. (advanced) |
| `EVEBOX_ES_URL` | string | empty | light | Elasticsearch address for the elasticsearch mode. (advanced) |
| `EVEBOX_RETENTION_DAYS` | integer 0..36500 | `30` | light | How many days EveBox keeps events (0: no limit). (advanced) |

## Rules

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `RULES_SOURCES` | string | `et/open` | light | Rule sources for the rules updater, space separated. (advanced) |
| `RULES_URLS` | string | empty | light | Your own rule set addresses, space separated. Empty: only the rule sources above are used. (advanced) |
| `RULES_GROUPS` | string | `emerging-p2p,emerging-policy` | light | Enabled rule groups, comma separated. (advanced) |
| `RULES_UPDATE` | on \| off | `on` | light | Update the rules on a schedule. (advanced) |
| `RULES_UPDATE_CALENDAR` | string | `weekly` | light | When to update: daily, weekly or a systemd expression. (advanced) |
| `EXCEPTIONS_DEFAULT_DAYS` | integer 0..3650 | `30` | light | Days a new exception lasts when none is given; 0 means it never expires. (advanced) |

## Access and ports

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `EVEBOX_PORT` | integer 1..65535 | `5636` | light | EveBox port. (advanced) |
| `ACCESS_MODE` | localhost \| lan \| nginx | `localhost` | light | Who can open the panels: localhost, the local network or through nginx. |
| `BIND_ADDR` | string | `auto` | light | Address the web services listen on: auto (127.0.0.1, or every address in lan mode) or one IPv4 address of this host, for example 192.168.1.156. An address that is not loopback opens the panels to LAN_CIDR. |
| `LAN_CIDR` | string | `auto` | light | The network allowed in lan mode, or auto; several networks may be given separated by commas (auto stands for the network of the default route), for example auto,172.18.0.0/16. (advanced) |
| `PANEL_PORT` | integer 1..65535 | `9800` | light | Port of this panel. (advanced) |
| `NTOPNG_PORT` | integer 1..65535 | `3000` | light | ntopng port. (advanced) |
| `NGINX_MANAGE` | yes \| snippet | `snippet` | light | How to manage nginx: replace the configuration or only drop in a fragment. (advanced) |
| `NGINX_TLS` | none \| selfsigned \| existing | `none` | light | TLS on nginx: none, self signed or your own certificate. (advanced) |
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
| `ALERT_CHANNELS` | string | `panel,log` | light | Where to send alerts: panel, log, tg (Telegram), mail, webhook, syslog (comma separated). |
| `ALERT_TG_CHAT_ID` | string | empty | light | Telegram chat for alerts. (advanced) |
| `ALERT_MAIL_TO` | string | empty | light | Mail recipients, comma separated. (advanced) |
| `ALERT_MAIL_FROM` | string | empty | light | Sender address. (advanced) |
| `ALERT_WEBHOOK_FORMAT` | json \| slack \| discord \| ntfy | `json` | light | Body of the webhook message: json (own shape), slack, discord or ntfy. (advanced) |
| `ALERT_SYSLOG_TARGET` | string | empty | light | Syslog server for the syslog channel: host, host:port or [ipv6]:port (port 514 by default). (advanced) |
| `ALERT_SYSLOG_PROTO` | udp \| tcp | `udp` | light | Transport to the syslog server: udp or tcp. (advanced) |
| `DETECT_NOTIFY` | yes \| no | `no` | light | Send Suricata detections (alerts) to the delivery channels, not only the health of the stack. (advanced) |
| `DETECT_NOTIFY_SEVERITY` | high \| medium \| low | `high` | light | Weakest severity to send: high, medium (also high) or low (all). (advanced) |
| `DETECT_NOTIFY_CHANNELS` | string | empty | light | Channels for detections, comma separated, from ALERT_CHANNELS. Empty: the channels of ALERT_CHANNELS except panel. (advanced) |
| `DETECT_NOTIFY_MAX_PER_HOUR` | integer 1..1000 | `20` | light | Most detection messages in an hour. The rest are counted and one summary is sent. (advanced) |
| `DETECT_NOTIFY_DEDUP_MIN` | integer 0..1440 | `60` | light | The same signature between the same two addresses is sent once in this many minutes (0: every alert). (advanced) |
| `ALERT_TG_TOKEN` | secret | empty | light | Telegram bot token. Stored apart from the main configuration. (advanced) |
| `ALERT_SMTP_URL` | secret | empty | light | SMTP address, for example smtps://user:pass@host:465. Stored apart. (advanced) |
| `ALERT_WEBHOOK_URL` | secret | empty | light | Address of the webhook (Slack, Discord, ntfy topic or your own). It is the credential, so it is stored apart. (advanced) |

## Test checks

| Key | Values | Default | Change | Description |
| --- | --- | --- | --- | --- |
| `TEST_HTTPS_URL` | string | `https://example.com` | light | Address for the HTTPS check on the Tests screen. (advanced) |
| `TEST_BT_LIVE` | yes \| no | `no` | light | Also replay the BitTorrent file out of the capture interface and look for an alert in the live log. Adds one small test rule (sid 9000100) to Suricata. (advanced) |
| `TEST_ON_INSTALL` | yes \| no | `yes` | light | Run the checks after installation. (advanced) |

