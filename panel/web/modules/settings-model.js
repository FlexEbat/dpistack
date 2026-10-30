// The pure part of the settings screen: grouping, labels, hints and the
// computation of what changed. No DOM here, so node --test can run it.

export const GROUPS = [
  ["capture", "Traffic capture"],
  ["components", "Components and installation"],
  ["eve", "Events and storage"],
  ["rules", "Rules"],
  ["access", "Access and ports"],
  ["metrics", "Metrics"],
  ["watch", "Watch and alerts"],
  ["tests", "Test checks"],
];

// What each key does, in a sentence. A key without a line shows its name only.
export const HINTS = {
  SURICATA_RUNTIME: "Where Suricata runs: on the host or in a Docker container.",
  SURICATA_ENABLE: "Install and run Suricata (the IDS/IPS engine).",
  RULES_ENABLE: "Install the rules and their automatic update (needs Suricata).",
  EVEBOX_ENABLE: "Install EveBox, the alert viewer.",
  NTOPNG_ENABLE: "Install ntopng, the traffic monitor, with its Redis.",
  PANEL_ENABLE: "Install this control panel.",
  EVEBOX_RUNTIME: "Where EveBox runs: on the host or in a Docker container.",
  NTOPNG_RUNTIME: "Where ntopng runs: on the host or in a Docker container.",
  SURICATA_SOURCE: "Where Suricata comes from: the distribution package, the OISF package or a build from source.",
  SURICATA_VERSION: "Pinned Suricata version. Empty: the latest stable.",
  NDPI_ENABLE: "Application detection with nDPI in Suricata.",
  NDPI_SOURCE: "nDPI from a package or built from source.",
  NDPI_VERSION: "Pinned nDPI version. Empty: the latest stable.",
  NTOPNG_VERSION: "Pinned ntopng version.",
  EVEBOX_VERSION: "Pinned EveBox version.",
  PIN_VERSIONS: "Pin the installed versions so a system update does not change them.",
  SURICATA_MODE: "ids only watches, ips can block. Switching is best done on the Components screen.",
  IFACES: "Interfaces Suricata captures from, comma separated.",
  BPF_FILTER: "BPF filter: which traffic to skip or to analyze.",
  HOME_NET: "Your networks (CIDR, comma separated) or auto: detect from the interfaces.",
  IPS_METHOD: "How IPS gets packets: the NFQUEUE queue or AF_PACKET.",
  IPS_NFQ_CHAINS: "iptables chains that send packets to the queue.",
  NTOPNG_IFACES: "ntopng interfaces. Empty: the same as Suricata's.",
  EVE_FILE: "Write events to eve.json (needed by the panel and the watchdog).",
  EVE_TYPES: "Which event types to write to eve.json.",
  EVE_SYSLOG: "Duplicate events to syslog.",
  EVE_REDIS: "Send events to Redis (an address like host:port/list).",
  EVE_ROTATE: "How to rotate eve.json: daily, weekly or by size.",
  EVE_KEEP: "How many rotated files to keep.",
  EVE_MAX_SIZE_MB: "File size in MB that triggers rotation (the size mode).",
  STATS_INTERVAL_SEC: "How often Suricata writes statistics (seconds).",
  RULES_SOURCES: "Rule sources for the rules updater, space separated.",
  RULES_URLS: "Your own rule set addresses, space separated.",
  RULES_GROUPS: "Enabled rule groups, comma separated.",
  RULES_UPDATE: "Update the rules on a schedule.",
  RULES_UPDATE_CALENDAR: "When to update: daily, weekly or a systemd expression.",
  EVEBOX_DB: "Where EveBox stores events.",
  EVEBOX_ES_URL: "Elasticsearch address for the elasticsearch mode.",
  EVEBOX_PORT: "EveBox port.",
  EVEBOX_RETENTION_DAYS: "How many days EveBox keeps events (0: no limit).",
  ACCESS_MODE: "Who can open the panels: localhost, the local network or through nginx.",
  BIND_ADDR: "Address the web services listen on: auto (127.0.0.1, or every address in lan mode) or one IPv4 address of this host, for example 192.168.1.156. An address that is not loopback opens the panels to LAN_CIDR.",
  LAN_CIDR: "The network allowed in lan mode, or auto.",
  PANEL_PORT: "Port of this panel.",
  NTOPNG_PORT: "ntopng port.",
  PANEL_RUNTIME: "Where the panel runs: as a service on the host or as a Docker container (host commands go through nsenter).",
  PANEL_EDITION: "Which panel to install: full (rich design, background effects) or lite (the same features on a plain, light page).",
  PANEL_SOURCE: "How to get the panel program: build it, take a ready one or choose automatically.",
  NGINX_MANAGE: "How to manage nginx: replace the configuration or only drop in a fragment.",
  NGINX_TLS: "TLS on nginx: none, self signed or your own certificate.",
  NGINX_CERT: "Path to the certificate for the existing mode.",
  NGINX_KEY: "Path to the key for the existing mode.",
  FIREWALL_MANAGE: "Open the needed ports in the firewall by itself.",
  METRICS_EXPORT: "Serve the panel metrics at /metrics with a token.",
  METRICS_BACKEND: "Metrics storage: none, VictoriaMetrics or Prometheus.",
  METRICS_BACKEND_RUNTIME: "Metrics storage on the host or in Docker.",
  METRICS_BACKEND_PORT: "Metrics storage port.",
  METRICS_RETENTION: "How long to keep metrics, for example 30d.",
  NODE_EXPORTER_ENABLE: "Install node_exporter (CPU, memory, disk and network of the host); the metrics storage scrapes it.",
  NODE_EXPORTER_RUNTIME: "Where node_exporter runs: on the host or in a Docker container.",
  NODE_EXPORTER_PORT: "node_exporter port.",
  GRAFANA_ENABLE: "Install Grafana for dashboards; the metrics storage becomes its default data source.",
  GRAFANA_RUNTIME: "Where Grafana runs: on the host or in a Docker container.",
  GRAFANA_PORT: "Grafana port. The first login is admin/admin and Grafana asks for a new password.",
  WATCH_ENABLE: "Background watch over the components.",
  WATCH_INTERVAL_SEC: "How often the watchdog checks the state (seconds).",
  WATCH_EVE_STALE_SEC: "After how many seconds of silence eve.json counts as stuck.",
  WATCH_DROP_WARN_PCT: "Percent of dropped packets for a warning.",
  WATCH_DROP_CRIT_PCT: "Percent of dropped packets for an alarm.",
  WATCH_DISK_WARN_PCT: "Free disk space (%) for a warning.",
  WATCH_DISK_CRIT_PCT: "Free disk space (%) for an alarm.",
  WATCH_RULES_WARN_DAYS: "Age of the rules (days) for a warning.",
  WATCH_RULES_CRIT_DAYS: "Age of the rules (days) for an alarm.",
  WATCH_REPEAT_MIN: "After how many minutes to repeat the same alert.",
  WATCH_AUTORESTART: "Restart a failed component automatically (at most three times an hour).",
  ALERT_CHANNELS: "Where to send alerts: panel, log, telegram, mail (comma separated).",
  ALERT_TG_CHAT_ID: "Telegram chat for alerts.",
  ALERT_MAIL_TO: "Mail recipients, comma separated.",
  ALERT_MAIL_FROM: "Sender address.",
  TEST_HTTPS_URL: "Address for the HTTPS check on the Tests screen.",
  TEST_BT_LIVE: "Check BitTorrent on live traffic instead of a file.",
  TEST_ON_INSTALL: "Run the checks after installation.",
  ALERT_TG_TOKEN: "Telegram bot token. Stored apart from the main configuration.",
  ALERT_SMTP_URL: "SMTP address, for example smtps://user:pass@host:465. Stored apart.",
  METRICS_TOKEN: "Access token for /metrics. Stored apart.",
};

// groupSettings -> [{id, title, items}] in the order of GROUPS. Advanced keys
// are left out unless asked for; a group that ends up empty is left out too.
export function groupSettings(keys, showAdvanced) {
  const out = [];
  for (const [id, title] of GROUPS) {
    const items = keys.filter((k) => k.group === id && (showAdvanced || k.level === "basic"));
    if (items.length) out.push({ id, title, items });
  }
  return out;
}

// changedValues -> {KEY: value} of the non-secret keys whose edited value
// differs from the saved one.
export function changedValues(keys, edits) {
  const out = {};
  for (const k of keys) {
    if (k.secret) continue;
    if (!(k.key in edits)) continue;
    if (edits[k.key] !== k.value) out[k.key] = edits[k.key];
  }
  return out;
}

// localProblem -> a sentence for a value that cannot be right, or "". The
// server decides in the end; this only saves a round trip for the obvious.
export function localProblem(k, value) {
  if (k.type === "int") {
    if (value === "") return k.default === "" ? "" : "a number is required";
    if (!/^[0-9]+$/.test(value)) return "an integer is required";
    const n = Number(value);
    if (k.min !== null && n < k.min) return "not less than " + k.min;
    if (k.max !== null && n > k.max) return "not more than " + k.max;
  }
  if (k.type === "enum" && !k.options.includes(value)) return "value is not in the list";
  if (k.type === "free" && value.length > 1024) return "value is too long";
  if (/[\r\n]/.test(value)) return "no line breaks";
  return "";
}

export const ACCESS_KEYS = ["ACCESS_MODE"];

// needsAccessConfirm: widening who can reach the panels is confirmed by the
// person, never implied.
export function needsAccessConfirm(changed, keys) {
  const k = keys.find((x) => x.key === "ACCESS_MODE");
  return Boolean(k && "ACCESS_MODE" in changed && changed.ACCESS_MODE !== "localhost");
}
