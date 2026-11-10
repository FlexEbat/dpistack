// The model of the IPS screen (slice 42): what the page says about the
// answers of /api/ips and /api/ips/test. Pure functions, no DOM, so
// node --test can load it. The numbers are the verbs' (`dpistack ips status`,
// `dpistack ips test`); nothing is computed here but wording and levels.

const LEVEL = { ok: "ok", warn: "warn", fail: "crit", na: "na" };

// levelOf maps the state of a check to the level of a badge.
export function levelOf(state) {
  return LEVEL[state] || "na";
}

// headline is the one sentence and the level at the top of the page.
export function headline(st) {
  if (!st) return { level: "na", text: "The panel could not read the IPS state." };
  if (st.mode !== "ips") return { level: "na", text: "IDS mode: Suricata only reports, nothing is dropped." };
  if (st.pending) return { level: "warn", text: `IPS is on and waits for confirmation: ${st.remaining_sec} s until the rollback to IDS.` };
  if (!st.ready) return { level: "crit", text: "IPS is set, but a readiness check fails: traffic may pass unchecked." };
  return { level: "ok", text: `IPS is on (${st.method}) and ready.` };
}

const CHECK_TITLE = {
  mode: "Mode",
  suricata: "Suricata",
  firewall: "Queue rules",
  queue: "Queue",
  confirm: "Confirmation",
};

export function checkRows(st) {
  return ((st && st.checks) || []).map((c) => ({ id: c.id, title: CHECK_TITLE[c.id] || c.id, level: levelOf(c.state), state: c.state, text: c.text }));
}

// counterRows: the packet counters of the newest stats event, or none.
export function counterRows(st) {
  const c = st && st.counters;
  if (!c) return [];
  return [
    { id: "accepted", title: "Accepted", value: c.accepted },
    { id: "blocked", title: "Blocked", value: c.blocked },
    { id: "rejected", title: "Rejected", value: c.rejected },
    { id: "replaced", title: "Replaced", value: c.replaced },
  ];
}

export const NO_COUNTERS = "No IPS counters in eve.json yet: they appear with the next stats event once Suricata runs in IPS mode.";

export function ruleLines(st) {
  const d = st && st.drop_rules;
  if (!d) return [];
  return [
    `Rule set: ${d.enabled} drop rules active, ${d.disabled} disabled.`,
    `Local rules: ${d.local_enabled} active, ${d.local_disabled} disabled.`,
  ];
}

// parseSids reads the rule numbers a person typed: whole numbers separated by
// commas or spaces, at most 20. An empty field means "all drop rules".
export function parseSids(text) {
  const parts = String(text || "").split(/[\s,]+/).filter(Boolean);
  if (parts.length > 20) return { error: "At most 20 rule numbers at a time." };
  const sids = [];
  for (const p of parts) {
    if (!/^[0-9]{1,10}$/.test(p)) return { error: `"${p}" is not a rule number.` };
    sids.push(Number(p));
  }
  return { sids };
}

const STATE_TEXT = {
  would_drop: "would drop",
  alert_only: "alerts only (not a drop rule)",
  no_match: "did not match the sample",
  disabled: "is disabled",
  not_found: "was not found",
  needs_ndpi: "needs the nDPI plugin, which is not installed",
};

export function requestedText(r) {
  return STATE_TEXT[r.state] || r.state;
}

// testSummary is the sentence above the result of a rule test.
export function testSummary(res) {
  if (!res) return "";
  if (!res.ran) return `The test did not run: ${res.reason || "unknown reason"}.`;
  return `Replayed ${res.pcap}.pcap offline with ${res.loaded} rule${res.loaded === 1 ? "" : "s"}: ${res.would_drop} would drop, ${(res.matched || []).length} matched.`;
}
