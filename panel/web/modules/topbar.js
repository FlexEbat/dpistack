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

// Theme: "system" follows the colour scheme of the system, "light" and "dark"
// override it. Only the lite stylesheet has both palettes; the full edition is
// dark by design, so the switch is not offered there (see themeSwitchable).
export const THEMES = ["system", "light", "dark"];
const THEME_KEY = "dpistack.theme";
const THEME_LABEL = { system: "Theme: system", light: "Theme: light", dark: "Theme: dark" };

export function nextTheme(theme) {
  return THEMES[(THEMES.indexOf(theme) + 1) % THEMES.length];
}

export function themeLabel(theme) {
  return THEME_LABEL[theme] || THEME_LABEL.system;
}

export function readTheme(storage) {
  try {
    const v = storage.getItem(THEME_KEY);
    return THEMES.includes(v) ? v : "system";
  } catch {
    return "system";
  }
}

export function saveTheme(storage, theme) {
  try {
    storage.setItem(THEME_KEY, theme);
  } catch {
    // a browser that refuses storage just forgets the choice
  }
}

// applyTheme puts the choice on the root element; "system" removes it, so the
// stylesheet follows the system again.
export function applyTheme(root, theme) {
  if (theme === "light" || theme === "dark") root.setAttribute("data-theme", theme);
  else root.removeAttribute("data-theme");
}

// themeSwitchable: the page offers both a light and a dark palette when its
// colour-scheme names both (lite.css); the full edition says "dark" only.
export function themeSwitchable(colorScheme) {
  return /\blight\b/.test(colorScheme || "") && /\bdark\b/.test(colorScheme || "");
}

function paintChip(node, chip) {
  if (!node) return;
  node.hidden = !chip || !chip.text;
  if (!chip) return;
  node.textContent = chip.text;
  node.dataset.level = chip.level || "";
}

// start polls the three sources and paints the chips. An answer that fails
// leaves its chip as it was, or hidden when it never had one; only a 401 is
// passed on (the session ended).
export function start(api, els, onError) {
  let running = true;
  let timer = null;
  let busy = false;

  async function once() {
    if (busy) return;
    busy = true;
    const [status, system, mode] = await Promise.allSettled([api("/api/status"), api("/api/system"), api("/api/mode")]);
    busy = false;
    if (!running) return;
    for (const r of [status, system, mode]) {
      if (r.status === "rejected" && r.reason && r.reason.status === 401) return onError(r.reason);
    }
    if (status.status === "fulfilled") paintChip(els.state, stateChip(status.value));
    if (system.status === "fulfilled") {
      const host = hostText(system.value);
      paintChip(els.host, host ? { text: host, level: "" } : null);
    }
    if (mode.status === "fulfilled") paintChip(els.mode, modeChip(mode.value));
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
