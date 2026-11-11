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
  EVE_SYSLOG: "Duplicate events to syslog (facility local5).",
  EVE_REDIS: "Redis output. Not supported yet: leave it empty, a value is ignored with a warning.",
  EVE_ROTATE: "How to rotate eve.json: daily, weekly or by size.",
  EVE_KEEP: "How many rotated files to keep.",
  EVE_MAX_SIZE_MB: "File size in MB that triggers rotation (the size mode).",
  STATS_INTERVAL_SEC: "How often Suricata writes statistics (seconds).",
  RULES_SOURCES: "Rule sources for the rules updater, space separated.",
  RULES_URLS: "Your own rule set addresses, space separated.",
  RULES_GROUPS: "Enabled rule groups, comma separated.",
  RULES_UPDATE: "Update the rules on a schedule.",
  RULES_UPDATE_CALENDAR: "When to update: daily, weekly or a systemd expression.",
  EXCEPTIONS_DEFAULT_DAYS: "Days a new exception lasts when none is given; 0 means it never expires.",
  EVEBOX_DB: "Where EveBox stores events.",
  EVEBOX_ES_URL: "Elasticsearch address for the elasticsearch mode.",
  EVEBOX_PORT: "EveBox port.",
  EVEBOX_RETENTION_DAYS: "How many days EveBox keeps events (0: no limit).",
  ACCESS_MODE: "Who can open the panels: localhost, the local network or through nginx.",
  BIND_ADDR: "Address the web services listen on: auto (127.0.0.1, or every address in lan mode) or one IPv4 address of this host, for example 192.168.1.156. An address that is not loopback opens the panels to LAN_CIDR.",
  LAN_CIDR: "The network allowed in lan mode, or auto; several networks may be given separated by commas (auto stands for the network of the default route), for example auto,172.18.0.0/16.",
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
  TEST_BT_LIVE: "Also replay the BitTorrent file out of the capture interface and look for an alert in the live log. Adds one small test rule (sid 9000100) to Suricata.",
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

// ---- Settings v2 (slice 44): search, when a key applies, the staged change,
// profiles. Pure functions again: the screen only draws what they return.

const lower = (s) => String(s || "").toLowerCase();

// searchKeys finds keys by name, hint or group title. Advanced keys are left
// out unless asked for, and their number is reported so the screen can say so.
export function searchKeys(keys, query, showAdvanced) {
  const q = lower(query).trim();
  if (!q) return { items: [], hiddenAdvanced: 0 };
  const title = Object.fromEntries(GROUPS);
  const hit = (k) => lower(k.key).includes(q) || lower(HINTS[k.key]).includes(q) || lower(title[k.group]).includes(q);
  const all = keys.filter(hit);
  const items = all.filter((k) => showAdvanced || k.level === "basic");
  return { items, hiddenAdvanced: all.length - items.length };
}

// categories lists the groups for the left column: how many keys each shows,
// and how many of them have an unsaved edit.
export function categories(keys, showAdvanced, edits) {
  const changed = changedValues(keys, edits);
  return GROUPS.map(([id, title]) => {
    const items = keys.filter((k) => k.group === id && (showAdvanced || k.level === "basic"));
    return { id, title, count: items.length, changed: items.filter((k) => k.key in changed).length };
  }).filter((c) => c.count > 0);
}

// applies tells whether a key means anything with the values as they are now.
// valueOf(key) gives the saved or the edited value. The rules come from the
// schema (`depends`), the same as those of the guided setup.
export function applies(k, valueOf) {
  for (const c of k.depends || []) {
    const v = valueOf(c.key);
    if (c.op === "=" && !c.values.includes(v)) return false;
    if (c.op === "!=" && c.values.includes(v)) return false;
    if (c.op === "~" && !String(v).split(",").includes(c.values[0])) return false;
  }
  return true;
}

// dependencyText says it in words: "Used when ACCESS_MODE is lan".
export function dependencyText(k) {
  const parts = (k.depends || []).map((c) => {
    if (c.op === "=") return `${c.key} is ${c.values.join(" or ")}`;
    if (c.op === "!=") return `${c.key} is not ${c.values.join(" or ")}`;
    return `${c.key} has ${c.values[0]}`;
  });
  return parts.length ? "Used when " + parts.join(" and ") : "";
}

export const shown = (v) => (v === "" ? "(empty)" : v);

// diffRows is the staged change: every edited non secret key as old to new,
// with its weight and what it touches.
export function diffRows(keys, edits) {
  const changed = changedValues(keys, edits);
  return keys
    .filter((k) => k.key in changed)
    .map((k) => ({ key: k.key, from: k.value, to: changed[k.key], weight: k.weight, touches: k.touches || [] }));
}

// stageSummary: the weight of the whole change and the components it touches.
export function stageSummary(rows) {
  const touches = [...new Set(rows.flatMap((r) => r.touches))].sort();
  return { weight: rows.some((r) => r.weight === "heavy") ? "heavy" : "light", touches, count: rows.length };
}

export function stageText(sum) {
  if (!sum.count) return "No changes are staged.";
  const what = sum.touches.length ? " It touches " + sum.touches.join(", ") + "." : "";
  const how = sum.weight === "heavy" ? "A heavy change: it starts a reinstall or a rebuild." : "A light change: files are written again and the components restart.";
  return how + what;
}

// stageSig identifies the staged values, so a passed check belongs to exactly
// these and an edit afterwards takes the Apply button away again.
export function stageSig(values) {
  return JSON.stringify(Object.keys(values).sort().map((k) => [k, values[k]]));
}

// profileAll is every non secret key with the value it has on the screen now.
export function profileAll(keys, edits) {
  const out = {};
  for (const k of keys) if (!k.secret) out[k.key] = k.key in edits ? edits[k.key] : k.value;
  return out;
}

export const PROFILE_NAME_RE = /^[a-z0-9][a-z0-9_-]{0,31}$/;

// loadProfile turns a saved profile into edits: only the keys whose value
// differs from the saved config become changes; keys this version does not
// know, or that are secrets, are reported and left out.
export function loadProfile(keys, profileKeys) {
  const byKey = new Map(keys.map((k) => [k.key, k]));
  const edits = {};
  const skipped = [];
  for (const [key, value] of Object.entries(profileKeys || {})) {
    const k = byKey.get(key);
    if (!k || k.secret) {
      skipped.push(key);
      continue;
    }
    if (value !== k.value) edits[key] = value;
  }
  return { edits, skipped };
}
