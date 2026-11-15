// Tabs for a screen that holds several groups of controls: the buttons carry
// data-tab, the panels carry data-pane. Only the selected panel is visible,
// the arrow keys, Home and End move between the tabs, and a panel keeps its
// elements (and their handlers) while it is hidden.

// nextIndex is the tab a key moves to, or -1 when the key does nothing.
export function nextIndex(count, current, key) {
  if (count < 1) return -1;
  if (key === "ArrowRight" || key === "ArrowDown") return (current + 1) % count;
  if (key === "ArrowLeft" || key === "ArrowUp") return (current - 1 + count) % count;
  if (key === "Home") return 0;
  if (key === "End") return count - 1;
  return -1;
}

export function start(root, scope) {
  if (!root || !scope) return () => {};
  const tabs = [...root.querySelectorAll("[data-tab]")];
  const panes = [...scope.querySelectorAll("[data-pane]")];
  function select(name, focus) {
    for (const t of tabs) {
      const on = t.dataset.tab === name;
      t.setAttribute("aria-selected", on ? "true" : "false");
      t.tabIndex = on ? 0 : -1;
      if (on && focus) t.focus();
    }
    for (const p of panes) p.hidden = p.dataset.pane !== name;
  }
  const onClick = (e) => {
    const t = e.target.closest("[data-tab]");
    if (t && root.contains(t)) select(t.dataset.tab, false);
  };
  const onKey = (e) => {
    const t = e.target.closest("[data-tab]");
    if (!t) return;
    const at = nextIndex(tabs.length, tabs.indexOf(t), e.key);
    if (at < 0) return;
    e.preventDefault();
    select(tabs[at].dataset.tab, true);
  };
  root.addEventListener("click", onClick);
  root.addEventListener("keydown", onKey);
  return () => {
    root.removeEventListener("click", onClick);
    root.removeEventListener("keydown", onKey);
  };
}
