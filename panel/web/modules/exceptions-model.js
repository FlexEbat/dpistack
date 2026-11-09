// The model of the Exceptions screen (slice 40): what an entry says in words,
// how the form becomes the body POST /api/exceptions takes, and the defaults
// "Create exception" takes from an alert. Pure functions, no DOM. The checks
// here only keep a value from being sent that `dpistack exceptions` would
// refuse; the verb checks everything again, so the screen and the CLI cannot
// differ.

export const LIMITS = { daysMax: 3650, countMax: 1000000, secondsMax: 86400, noteMax: 80 };

const NOTE = /^[A-Za-z0-9 ._:/@+,=-]{0,80}$/;
const ADDRESS = /^[0-9A-Fa-f.:/]{1,60}$/;

// The alert the user clicked "Create exception" on travels to the other
// screen through this one place; it is read once.
let draft = null;
export function setDraft(d) {
  draft = d;
}
export function takeDraft() {
  const d = draft;
  draft = null;
  return d;
}

const sideWord = (side) => (side === "dst" ? "destination" : "source");

// scopeText is who an entry applies to.
export function scopeText(e) {
  if (e.kind === "limit") {
    return `at most ${e.count} alerts per ${e.seconds} seconds for each ${sideWord(e.track)} address`;
  }
  if (e.track === "any" || !e.ip || e.ip === "any") return "every address";
  return `${sideWord(e.track)} ${e.ip}`;
}

// expiryText is when an entry ends, in words.
export function expiryText(e) {
  if (e.expired) return `expired on ${e.expires}, removed at the next cleanup`;
  if (e.expires === "never" || e.days_left === null || e.days_left === undefined) return "never expires";
  if (e.days_left === 0) return `last day is today (${e.expires})`;
  return `until ${e.expires}, ${e.days_left} ${e.days_left === 1 ? "day" : "days"} left`;
}

// ordered puts what needs attention first: expired entries, then the ones
// that end soonest, then the ones that never end.
export function ordered(entries) {
  const rank = (e) => (e.expired ? -1 : e.days_left === null || e.days_left === undefined ? 1e9 : e.days_left);
  return [...entries].sort((a, b) => rank(a) - rank(b) || (a.id < b.id ? -1 : 1));
}

// summary is the one line above the table.
export function summary(list) {
  const entries = (list && list.entries) || [];
  const managed = entries.filter((e) => e.kind !== "other");
  if (!entries.length) return "No exceptions. Every rule alerts as written.";
  const soon = managed.filter((e) => !e.expired && e.days_left !== null && e.days_left !== undefined && e.days_left <= 7).length;
  const expired = managed.filter((e) => e.expired).length;
  const parts = [`${managed.length} ${managed.length === 1 ? "exception" : "exceptions"}`];
  if (soon) parts.push(`${soon} ending within 7 days`);
  if (expired) parts.push(`${expired} expired`);
  const other = entries.length - managed.length;
  if (other) parts.push(`${other} written by hand, not managed here`);
  return parts.join(", ") + ".";
}

// defaultText says what an entry gets when no expiry is chosen.
export function defaultText(list) {
  const d = list && Number.isInteger(list.default_days) ? list.default_days : 30;
  return d === 0
    ? "With no choice, a new exception never expires (setting EXCEPTIONS_DEFAULT_DAYS is 0)."
    : `With no choice, a new exception lasts ${d} ${d === 1 ? "day" : "days"} (setting EXCEPTIONS_DEFAULT_DAYS).`;
}

const whole = (v) => (/^[0-9]{1,9}$/.test(String(v).trim()) ? Number(String(v).trim()) : NaN);

// formToBody checks the form and builds the body of POST /api/exceptions.
// It returns { body, warnings } or { problem } with a sentence for the user.
// A warning is not a refusal: the screen asks for a confirmation first.
export function formToBody(f) {
  const kind = f.kind === "limit" ? "limit" : "suppress";
  const sid = whole(f.sid);
  if (!Number.isInteger(sid) || sid < 1 || sid > 2147483647) return { problem: "Enter the rule number (sid) of the alert, for example 2001219." };
  const body = { kind, sid };
  const warnings = [];

  if (kind === "suppress") {
    if (f.scope === "everyone") {
      warnings.push(`Rule ${sid} will stay silent for every address, also for attacks you have not seen yet.`);
    } else {
      const ip = String(f.ip || "").trim();
      if (!ip) return { problem: "Enter the address this applies to, or choose every address." };
      if (!ADDRESS.test(ip)) return { problem: "An address has digits, letters a to f, dots, colons and a slash, for example 10.0.0.5 or 10.0.0.0/24." };
      body.track = f.side === "dst" ? "dst" : "src";
      body.ip = ip;
    }
  } else {
    const count = whole(f.count);
    const seconds = whole(f.seconds);
    if (!Number.isInteger(count) || count < 1 || count > LIMITS.countMax) return { problem: `How many alerts are allowed is a number from 1 to ${LIMITS.countMax}.` };
    if (!Number.isInteger(seconds) || seconds < 1 || seconds > LIMITS.secondsMax) return { problem: `The time window is a number of seconds from 1 to ${LIMITS.secondsMax}.` };
    body.track = f.side === "dst" ? "dst" : "src";
    body.count = count;
    body.seconds = seconds;
  }

  if (f.expiry === "never") {
    body.never = true;
    warnings.push("This exception never expires. It stays until someone removes it.");
  } else if (f.expiry === "days") {
    const days = whole(f.days);
    if (!Number.isInteger(days) || days < 1 || days > LIMITS.daysMax) return { problem: `Days is a number from 1 to ${LIMITS.daysMax}.` };
    body.days = days;
  }

  const note = String(f.note || "").trim();
  if (!NOTE.test(note)) return { problem: `The note is up to ${LIMITS.noteMax} characters: Latin letters, digits, space and . _ : / @ + , = -` };
  if (note) body.note = note;
  return { body, warnings };
}

// fromEvent gives the form the values of an alert: the rule number and, as
// the narrowest scope, its source address. Anything that is not an alert has
// no rule number, so nothing is offered for it.
export function fromEvent(ev) {
  const e = ev && ev.event;
  const a = e && e.alert;
  if (!ev || ev.type !== "alert" || !a || !Number.isInteger(a.signature_id)) return null;
  return {
    kind: "suppress",
    sid: String(a.signature_id),
    scope: e.src_ip ? "one" : "everyone",
    side: "src",
    ip: e.src_ip || "",
    expiry: "default",
    note: "",
    signature: a.signature || "",
    dest_ip: e.dest_ip || "",
  };
}
