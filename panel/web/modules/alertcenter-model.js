// The model of the Alert Center (slice 43), the top of the Alerts screen:
// wording, levels and the actions that make sense for an alert. Pure
// functions, no DOM, so node --test can load it. The alerts, the states and
// the counts are those of `dpistack alerts list`; nothing is computed here.

const STATE_WORD = { new: "New", acknowledged: "Acknowledged", snoozed: "Snoozed", resolved: "Resolved" };
const SEVERITY_WORD = { crit: "Critical", warn: "Warning", info: "Info" };
const SEVERITY_LEVEL = { crit: "crit", warn: "warn", info: "na" };
const STATE_LEVEL = { new: "warn", acknowledged: "na", snoozed: "na", resolved: "ok" };

export const SNOOZE_CHOICES = ["1h", "4h", "24h", "7d"];
export const NOTE_RE = /^[A-Za-z0-9 ._:/@+,=-]{0,80}$/;

export const stateWord = (s) => STATE_WORD[s] || s;
export const severityWord = (s) => SEVERITY_WORD[s] || s;
export const severityLevel = (s) => SEVERITY_LEVEL[s] || "na";
export const stateLevel = (s) => STATE_LEVEL[s] || "na";

// actionsFor lists what a person can do with an alert in its state. A cleared
// alert only has a decision left, so "reopen" is "dismiss" there.
export function actionsFor(alert) {
  switch (alert && alert.state) {
    case "new":
      return [{ action: "ack", label: "Acknowledge" }, { action: "snooze", label: "Snooze" }, { action: "resolve", label: "Resolve" }];
    case "acknowledged":
      return [{ action: "snooze", label: "Snooze" }, { action: "resolve", label: "Resolve" }, { action: "reopen", label: "Reopen" }];
    case "snoozed":
      return [{ action: "ack", label: "Acknowledge" }, { action: "resolve", label: "Resolve" }, { action: "reopen", label: "Reopen" }];
    case "resolved":
      return [{ action: "reopen", label: alert.cleared ? "Dismiss" : "Reopen" }];
    default:
      return [];
  }
}

// query is the query string of the filters; an empty choice is left out.
export function query(filters) {
  const q = new URLSearchParams();
  for (const k of ["state", "source", "severity"]) if (filters && filters[k]) q.set(k, filters[k]);
  const s = q.toString();
  return s ? "?" + s : "";
}

export function summaryLine(counts) {
  if (!counts) return "";
  return `${counts.new} new (${counts.new_crit} critical), ${counts.acknowledged} acknowledged, ${counts.snoozed} snoozed, ${counts.resolved} resolved`;
}

// stateDetail is the small text under the state: until when, by whom.
export function stateDetail(alert) {
  const parts = [];
  if (alert.state === "snoozed" && alert.until) parts.push("until " + new Date(alert.until * 1000).toLocaleString("en-GB"));
  if (alert.by) parts.push("by " + alert.by);
  if (alert.state === "resolved" && alert.cleared) parts.push("cleared on its own");
  if (alert.note) parts.push(alert.note);
  return parts.join(", ");
}

export function sourceWord(alert) {
  return alert.source === "suricata" ? "Suricata" : "Watchdog";
}

// seenText: how many times (Suricata) and the last time.
export function seenText(alert) {
  const when = alert.last_seen ? new Date(alert.last_seen.replace(/([+-]\d\d)(\d\d)$/, "$1:$2")) : null;
  const t = when && !Number.isNaN(when.getTime()) ? when.toLocaleString("en-GB") : alert.last_seen || "";
  return alert.count ? `${alert.count} time${alert.count === 1 ? "" : "s"}, last ${t}` : t;
}

// decisions are the rows of the history that people made (not the status
// changes of the watchdog, which the feed below shows).
export function decisions(history) {
  return ((history && history.history) || []).filter((h) => h.kind === "action");
}

const ACTION_WORD = { ack: "acknowledged", snooze: "snoozed", resolve: "resolved", reopen: "reopened" };
export const actionWord = (a) => ACTION_WORD[a] || a;

// bodyFor builds the POST body; the note is checked here and by the server.
export function bodyFor(action, key, dur, note) {
  if (!NOTE_RE.test(note || "")) return { error: "The note is at most 80 characters: letters, digits and . _ : / @ + , = -" };
  const body = { action, key };
  if (action === "snooze") body.for = dur;
  if (note) body.note = note;
  return { body };
}
