// The model of the Network screen (slice 38): a simple topology of what the
// panel knows, made in the browser from answers that exist (/api/status,
// /api/system, /api/mode). Pure functions, no DOM, so node --test can load it.
//
// The chain is the one fact the stack guarantees: the capture interfaces feed
// Suricata, Suricata writes eve.json, EveBox reads it. Other parts (ntopng,
// the metrics backend, Redis) are listed with their state and with no arrow:
// ntopng captures on its own and the panel does not know which interfaces, so
// drawing a line to it would be a guess.

const CHAIN = ["suricata", "evebox"];

// levelOf maps the state of a component to the level of a badge. A stopped
// component that starts on boot is a warning; one that does not is just off.
export function levelOf(component) {
  if (!component) return "na";
  if (component.state === "active") return "ok";
  if (component.state === "failed") return "crit";
  if (component.state === "inactive") return component.enabled ? "warn" : "na";
  return "na";
}

const STATE_TEXT = { active: "running", inactive: "stopped", failed: "failed", absent: "not installed" };

function part(component) {
  return { id: component.id, state: STATE_TEXT[component.state] || component.state, level: levelOf(component) };
}

function find(status, id) {
  return ((status && status.components) || []).find((c) => c.id === id);
}

// freshness reads the watchdog check that says whether eve.json is written.
function freshness(status) {
  const checks = (status && status.health && status.health.checks) || [];
  const c = checks.find((x) => x.id === "suricata.eve_fresh");
  if (!c) return null;
  const level = c.status === "ok" || c.status === "warn" || c.status === "crit" ? c.status : "na";
  return { level, detail: c.detail || "" };
}

// topology returns the stages of the chain in order. A stage whose source did
// not answer is left out, never shown as healthy. Each stage: id, title, level,
// lines (short facts) and, for the capture stage, items (the interfaces).
export function topology({ status, system, mode }) {
  const stages = [];
  const host = system && typeof system.hostname === "string" ? system.hostname.trim() : "";
  if (host) stages.push({ id: "host", title: "Host", level: "na", lines: [host] });

  const ifaces = (system && system.interfaces) || [];
  if (ifaces.some((i) => i.capture !== undefined)) {
    const capturing = ifaces.filter((i) => i.capture === true);
    stages.push({
      id: "capture",
      title: "Capture",
      level: capturing.length ? (capturing.every((i) => i.state === "up" || i.state === "unknown") ? "ok" : "warn") : "warn",
      lines: capturing.length ? [] : ["no interface is captured"],
      items: capturing.map((i) => ({ name: i.name, state: i.state || "unknown" })),
    });
  }

  const suricata = find(status, "suricata");
  if (suricata && suricata.state !== "absent") {
    const lines = [STATE_TEXT[suricata.state] || suricata.state];
    if (mode && (mode.mode === "ids" || mode.mode === "ips")) lines.push(mode.mode === "ips" ? "IPS, can drop traffic" : "IDS, watching only");
    stages.push({ id: "suricata", title: "Suricata", level: levelOf(suricata), lines });
    const fresh = freshness(status);
    if (fresh) stages.push({ id: "eve", title: "eve.json", level: fresh.level, lines: fresh.detail ? [fresh.detail] : [] });
  }

  const evebox = find(status, "evebox");
  if (evebox && evebox.state !== "absent") stages.push({ id: "evebox", title: "EveBox", level: levelOf(evebox), lines: [STATE_TEXT[evebox.state] || evebox.state] });
  return stages;
}

// others are the installed parts that are not in the chain, with their state.
export function others(status) {
  return ((status && status.components) || []).filter((c) => !CHAIN.includes(c.id) && c.state !== "absent").map(part);
}
