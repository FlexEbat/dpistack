// The Components screen: state of every component and its control buttons.

const POLL_MS = 10000;
const STATE = { active: "работает", inactive: "остановлен", failed: "сбой", absent: "не установлен" };
const VERB = { start: "Запустить", stop: "Остановить", restart: "Перезапустить" };
const VERB_ASK = { start: "Запустить", stop: "Остановить", restart: "Перезапустить" };

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
  if (!confirm(`${VERB_ASK[action]} компонент «${id}»?`)) return null;
  const path = `/api/components/${encodeURIComponent(id)}/${action}`;
  try {
    const res = await api(path, { method: "POST" });
    return res.output || "Готово";
  } catch (err) {
    if (err.status !== 409) throw err;
    if (!confirm("Это затронет саму панель, связь прервётся. Точно продолжить?")) return null;
    const res = await api(path + "?confirm=yes", { method: "POST" });
    return res.output || "Готово";
  }
}

async function reload(api) {
  if (!confirm("Перечитать правила Suricata без остановки?")) return null;
  const res = await api("/api/suricata/reload", { method: "POST" });
  return res.output || "Правила перечитаны";
}

export function render(status, areas, run) {
  const t = el("table");
  const head = el("tr");
  for (const h of ["Компонент", "Состояние", "Версия", "Действия"]) head.append(el("th", "", h));
  t.append(head);

  for (const c of status.components) {
    const tr = el("tr");
    tr.append(el("td", "", c.id), el("td", "", STATE[c.state] || c.state), el("td", "", c.version || ""));
    const actions = el("td", "actions");
    const verbs = c.state === "absent" ? [] : c.state === "active" ? ["restart", "stop"] : ["start"];
    for (const verb of verbs) {
      const b = el("button", "", VERB[verb]);
      b.type = "button";
      b.addEventListener("click", () => run(() => act(areas.api, c.id, verb)));
      actions.append(b);
    }
    if (c.id === "suricata" && c.state === "active") {
      const b = el("button", "", "Перечитать правила");
      b.type = "button";
      b.addEventListener("click", () => run(() => reload(areas.api)));
      actions.append(b);
    }
    tr.append(actions);
    t.append(tr);
  }
  areas.list.replaceChildren(t);
}

// start polls while the tab is visible, refreshes at once after an action,
// and returns stop().
export function start(api, areas, onError) {
  let timer = null;
  let running = true;
  areas = { ...areas, api };

  async function refresh() {
    clearTimeout(timer);
    timer = null;
    if (!running || document.hidden) return;
    try {
      render(await api("/api/status"), areas, run);
    } catch (err) {
      if (err.status === 401) return onError(err);
      areas.error.textContent = err.message;
    }
    if (running) timer = setTimeout(refresh, POLL_MS);
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
