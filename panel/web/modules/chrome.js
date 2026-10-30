// The page's own behaviour that is not a screen: the menu of the narrow
// layout, the skip link and the one time reveal of blocks that scroll into
// view. No DOM work at import time, so node --test can load it.

// Which elements rise into view. Dynamic content inside them is not
// watched: only the static blocks of the page are.
export const REVEAL_SELECTOR = "#login > *, #overview > header, #overview > div[id^='view-'] > *";

// revealOnce adds "in" to an element the first time it enters the viewport
// and stops watching it, so scrolling back up does not replay it. Without
// IntersectionObserver nothing is hidden at all.
export function revealOnce(root, Observer = globalThis.IntersectionObserver) {
  if (typeof Observer !== "function") return () => {};
  const seen = new Observer(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        entry.target.classList.add("in");
        seen.unobserve(entry.target);
      }
    },
    { threshold: 0.05 },
  );
  for (const node of root.querySelectorAll(REVEAL_SELECTOR)) {
    node.classList.add("js-reveal");
    seen.observe(node);
  }
  return () => seen.disconnect();
}

// menu wires the toggle of the narrow layout: the button, the open state on
// the nav, the closing on a choice and on Escape.
export function menu(doc = document) {
  const nav = doc.getElementById("nav");
  const toggle = doc.getElementById("menu-toggle");
  if (!nav || !toggle) return { close() {} };
  const set = (open) => {
    nav.toggleAttribute("data-open", open);
    toggle.setAttribute("aria-expanded", String(open));
    doc.documentElement.classList.toggle("menu-open", open);
  };
  toggle.addEventListener("click", () => set(!nav.hasAttribute("data-open")));
  doc.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && nav.hasAttribute("data-open")) {
      set(false);
      toggle.focus();
    }
  });
  return { close: () => set(false) };
}

// skipLink moves the focus past the navigation to the title of the page.
export function skipLink(doc = document) {
  const skip = doc.getElementById("skip");
  if (!skip) return;
  skip.addEventListener("click", () => doc.getElementById("page-title")?.focus());
}
