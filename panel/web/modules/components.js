// The Components screen: state of every component and its control buttons.
import { tickets } from "./poll.js";

const POLL_MS = 10000;
const STATE = { active: "running", inactive: "stopped", failed: "failed", absent: "not installed" };
const VERB = { start: "Start", stop: "Stop", restart: "Restart" };
const VERB_ASK = { start: "Start", stop: "Stop", restart: "Restart" };

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// act asks for confirmation, runs the action and returns the message to
// show, or null when the person said no. The panel's own stop and restart
// need a second, separate confirmation that the server demands (409 with
// confirm_required).
async function act(api, id, action) {
  if (!confirm(`${VERB_ASK[action]} component "${id}"?`)) return null;
  const path = `/api/components/${encodeURIComponent(id)}/${action}`;
  try {
    const res = await api(path, { method: "POST" });
    return res.output || "Done";
  } catch (err) {
    if (err.status !== 409) throw err;
    if (!confirm("This affects the panel itself and the connection will drop. Continue?")) return null;
    const res = await api(path + "?confirm=yes", { method: "POST" });
    return res.output || "Done";
  }
}

async function reload(api) {
  if (!confirm("Reload Suricata rules without stopping it?")) return null;
  const res = await api("/api/suricata/reload", { method: "POST" });
  return res.output || "Rules reloaded";
}

// What each component is for, in a few words, so a name like "watch" says
// something to a person who did not read the manual.
export const ABOUT = {
  suricata: "Traffic inspection engine",
  evebox: "Alert and event browser",
  ntopng: "Traffic analytics",
  redis: "Store for ntopng and the event queue",
  victoriametrics: "Metrics storage",
  prometheus: "Metrics storage",
  node_exporter: "Host metrics",
  grafana: "Metric dashboards",
  panel: "This control panel",
  watch: "Service watcher",
  rules: "Rule updates",
};

// toneOf maps the state of a unit to the colour of its dot and its left edge.
export function toneOf(state) {
  if (state === "active") return "ok";
  if (state === "failed") return "crit";
  if (state === "inactive") return "warn";
  return "na";
}

export function render(status, areas, run) {
  const grid = el("div", "comp-grid");
  for (const c of status.components) {
    const card = el("article", `comp tone-${toneOf(c.state)}`);
    card.dataset.component = c.id;
    const top = el("div", "comp-top");
    top.append(el("i", "dot"), el("h3", "", c.id), el("span", "comp-state", STATE[c.state] || c.state));
    card.append(top);
    if (ABOUT[c.id]) card.append(el("p", "comp-about", ABOUT[c.id]));
    card.append(el("p", "comp-version", c.version ? `Version ${c.version}` : "No version reported"));
    const actions = el("div", "actions");
    const verbs = c.state === "absent" ? [] : c.state === "active" ? ["restart", "stop"] : ["start"];
    for (const verb of verbs) {
      const b = el("button", "", VERB[verb]);
      b.type = "button";
      b.addEventListener("click", () => run(() => act(areas.api, c.id, verb)));
      actions.append(b);
    }
    if (c.id === "suricata" && c.state === "active") {
      const b = el("button", "", "Reload rules");
      b.type = "button";
      b.addEventListener("click", () => run(() => reload(areas.api)));
      actions.append(b);
    }
    card.append(actions);
    grid.append(card);
  }
  areas.list.replaceChildren(grid);
}

// start polls while the tab is visible, refreshes at once after an action,
// and returns stop().
export function start(api, areas, onError) {
  let timer = null;
  let running = true;
  const seq = tickets();
  areas = { ...areas, api };

  async function refresh() {
    clearTimeout(timer);
    timer = null;
    const ticket = seq.next();
    if (!running || document.hidden) return;
    try {
      const status = await api("/api/status");
      if (!running || !seq.current(ticket)) return;
      render(status, areas, run);
    } catch (err) {
      if (!running || !seq.current(ticket)) return;
      if (err.status === 401) return onError(err);
      areas.error.textContent = err.message;
    }
    if (running && seq.current(ticket)) timer = setTimeout(refresh, POLL_MS);
  }

  async function run(action) {
    areas.error.textContent = "";
    areas.message.textContent = "";
    try {
      const text = await action();
      if (text) areas.message.textContent = text;
    } catch (err) {
      if (err.status === 401) return onError(err);
      areas.error.textContent = err.message;
    }
    refresh();
  }

  function onVisible() {
    if (!document.hidden && running && timer === null) refresh();
  }

  document.addEventListener("visibilitychange", onVisible);
  refresh();
  return () => {
    running = false;
    clearTimeout(timer);
    document.removeEventListener("visibilitychange", onVisible);
  };
}
