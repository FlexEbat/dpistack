// The model of the Security screen (slice 45): wording, levels and the
// request bodies. Pure functions, no DOM, so node --test can load it. What
// the lists hold is what `dpistack security check`, the sessions of the panel,
// `dpistack tokens` and the audit log say; nothing is computed here but words.

const LEVEL = { ok: "ok", warn: "warn", crit: "crit", na: "na" };
const LEVEL_WORD = { ok: "ok", warn: "warning", crit: "critical", na: "not known" };

export const levelOf = (l) => LEVEL[l] || "na";
export const levelWord = (l) => LEVEL_WORD[l] || l;

export function checkSummary(counts) {
  if (!counts) return "";
  return `${counts.ok} ok, ${counts.warn} warning${counts.warn === 1 ? "" : "s"}, ${counts.crit} critical, ${counts.na} not known`;
}

export const SCOPES = ["read", "viewer", "analyst", "operator", "admin"];

export function scopeText(scope) {
  if (scope === "read") return "read only: what its owner may read, nothing else";
  return "the role " + scope + ", never more than its owner may do";
}

export const TOKEN_NAME_RE = /^[a-z0-9][a-z0-9 ._-]{0,31}$/;

// tokenBody builds the POST body of a new token and checks it first.
export function tokenBody(name, scope, days) {
  if (!TOKEN_NAME_RE.test(name)) return { error: "The name is 1 to 32 characters: lowercase letters, digits, space and . _ -, starting with a letter or digit." };
  if (!SCOPES.includes(scope)) return { error: "Choose a scope." };
  const n = Number(days);
  if (!Number.isInteger(n) || n < 1 || n > 365) return { error: "Days is a whole number from 1 to 365." };
  return { body: { name, scope, days: n } };
}

const time = (iso) => {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? String(iso || "") : d.toLocaleString("en-GB");
};
export { time };

export function sessionRows(list) {
  return (list || []).map((s) => ({
    handle: s.handle,
    user: s.user,
    where: s.ip || "unknown",
    client: s.user_agent || "unknown",
    started: time(s.created),
    expires: time(s.expires),
    current: !!s.current,
  }));
}

export function tokenRows(list) {
  return (list || []).map((t) => ({
    id: t.id,
    name: t.name,
    user: t.user,
    scope: t.scope,
    created: time(t.created),
    expires: time(t.expires),
    status: t.expired ? "expired" : "active",
    lastUsed: t.last_used ? time(t.last_used) : "not since the panel started",
  }));
}

const RESULT_WORD = { ok: "signed in", denied: "refused: wrong user or password", error: "refused: too many tries" };
const RESULT_LEVEL = { ok: "ok", denied: "warn", error: "warn" };
export const resultWord = (r) => RESULT_WORD[r] || r;
export const resultLevel = (r) => RESULT_LEVEL[r] || "na";

export function loginRows(list) {
  return (list || []).map((l) => ({ when: time(l.ts), user: l.user, ip: l.ip || "", result: l.result, word: resultWord(l.result), level: resultLevel(l.result) }));
}

export const SIGN_OUT_ALL_QUESTION =
  "Sign everyone out? Every session of every user ends, yours too, and everybody has to sign in again. API tokens are not affected.";

export const TOKEN_SHOWN_ONCE = "Copy the token now. It is shown only once; the panel keeps only a hash of it and cannot show it again.";
