// The shell of the page (slice 37): which screen the address names, the
// groups of the menu that disappear when none of their entries is allowed,
// and the collapsed menu that is remembered. No DOM work at import time.

// viewFromHash returns the screen named by "#events" (or "#/events"), or ""
// when it is not one of the screens.
export function viewFromHash(hash, views) {
  const name = String(hash || "").replace(/^#\/?/, "");
  return views.includes(name) ? name : "";
}

export function hashOf(view) {
  return "#" + view;
}

// syncGroups hides a group of the menu when all of its entries are hidden,
// so a user is not shown a heading with nothing under it.
export function syncGroups(root) {
  for (const g of root.querySelectorAll(".nav-group")) {
    g.hidden = [...g.querySelectorAll("button[data-view]")].every((b) => b.hidden);
  }
}

const KEY = "dpistack.nav.collapsed";

export function readCollapsed(storage) {
  try {
    return storage.getItem(KEY) === "1";
  } catch {
    return false;
  }
}

export function saveCollapsed(storage, on) {
  try {
    storage.setItem(KEY, on ? "1" : "0");
  } catch {
    // a browser that refuses storage just forgets the choice
  }
}

// collapse wires the button that folds the menu to its icons. The state is
// an attribute on the signed-in page, so the stylesheets decide how it looks.
export function collapse(doc, storage) {
  const page = doc.getElementById("overview");
  const button = doc.getElementById("nav-collapse");
  if (!page || !button) return { set() {} };
  const set = (on) => {
    page.toggleAttribute("data-collapsed", on);
    button.setAttribute("aria-expanded", String(!on));
    button.setAttribute("aria-label", on ? "Expand the menu" : "Collapse the menu");
    button.setAttribute("title", on ? "Expand the menu" : "Collapse the menu");
  };
  set(readCollapsed(storage));
  button.addEventListener("click", () => {
    const on = !page.hasAttribute("data-collapsed");
    set(on);
    saveCollapsed(storage, on);
  });
  return { set };
}
