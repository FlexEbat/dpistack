// The top bar (slice 37): the host name, the overall state, the mode (IDS or
// IPS), the user menu and the theme. The chips only show what the server
// says; they have no controls, because the switches live on their screens.
// No DOM work at import time, so node --test can load it.

const OVERALL = { ok: "All good", warn: "Warnings", crit: "Faults", na: "No data" };
const POLL_MS = 15000;

// hostText is the name of the host, or "" when the server could not read it.
export function hostText(info) {
  return info && typeof info.hostname === "string" ? info.hostname.trim() : "";
}

// stateChip is the overall state of the watchdog; level is the class of the chip.
export function stateChip(status) {
  const overall = status && status.health ? status.health.overall : "na";
  return { text: OVERALL[overall] || OVERALL.na, level: OVERALL[overall] ? overall : "na" };
}

// modeChip is IDS or IPS; IPS is a warning level, because it can drop traffic.
export function modeChip(mode) {
  if (!mode || (mode.mode !== "ids" && mode.mode !== "ips")) return null;
  const ips = mode.mode === "ips";
  return { text: ips ? (mode.pending ? "IPS, waiting for confirmation" : "IPS") : "IDS", level: ips ? "warn" : "ok" };
}

// bellChip is the count of new alerts of the Alert Center; critical ones make
// it red, others yellow, none green. It is a link to the Alerts screen.
export function bellChip(list) {
  const c = list && list.counts;
  if (!c || typeof c.new !== "number") return null;
  const text = c.new === 0 ? "No new alerts" : `${c.new} new alert${c.new === 1 ? "" : "s"}`;
  return { text, level: c.new_crit > 0 ? "crit" : c.new > 0 ? "warn" : "ok" };
}

function paintChip(node, chip) {
  if (!node) return;
  node.hidden = !chip || !chip.text;
  if (!chip) return;
  node.textContent = chip.text;
  node.dataset.level = chip.level || "";
}

// start polls the four sources and paints the chips. An answer that fails
// leaves its chip as it was, or hidden when it never had one; only a 401 is
// passed on (the session ended).
export function start(api, els, onError) {
  let running = true;
  let timer = null;
  let busy = false;

  async function once() {
    if (busy) return;
    busy = true;
    const [status, system, mode, bell] = await Promise.allSettled([api("/api/status"), api("/api/system"), api("/api/mode"), api("/api/alert-center?state=new")]);
    busy = false;
    if (!running) return;
    for (const r of [status, system, mode, bell]) {
      if (r.status === "rejected" && r.reason && r.reason.status === 401) return onError(r.reason);
    }
    if (status.status === "fulfilled") paintChip(els.state, stateChip(status.value));
    if (system.status === "fulfilled") {
      const host = hostText(system.value);
      paintChip(els.host, host ? { text: host, level: "" } : null);
    }
    if (mode.status === "fulfilled") paintChip(els.mode, modeChip(mode.value));
    if (bell.status === "fulfilled") paintChip(els.bell, bellChip(bell.value));
  }

  once();
  timer = setInterval(once, POLL_MS);
  return () => {
    running = false;
    if (timer !== null) clearInterval(timer);
  };
}

// userMenu wires the button of the user menu: open and close, Escape and a
// click outside close it and give the focus back to the button.
export function userMenu(doc = document) {
  const btn = doc.getElementById("user-btn");
  const menu = doc.getElementById("user-menu");
  if (!btn || !menu) return { close() {} };
  const set = (open) => {
    menu.hidden = !open;
    btn.setAttribute("aria-expanded", String(open));
  };
  btn.addEventListener("click", () => set(menu.hidden));
  doc.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && !menu.hidden) {
      set(false);
      btn.focus();
    }
  });
  doc.addEventListener("click", (event) => {
    if (!menu.hidden && !menu.contains(event.target) && !btn.contains(event.target)) set(false);
  });
  return { close: () => set(false) };
}
