// The Overview screen: overall health, components and watchdog checks.
import { tickets } from "./poll.js";

const POLL_MS = 10000;

const OVERALL = { ok: "Всё в порядке", warn: "Есть предупреждения", crit: "Есть неисправности", na: "Нет данных" };
const STATE = { active: "работает", inactive: "остановлен", failed: "сбой", absent: "не установлен" };

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function badge(status) {
  return el("span", "badge " + (status || "na"), status || "na");
}

function table(headers, rows) {
  const t = el("table");
  const head = el("tr");
  for (const h of headers) head.append(el("th", "", h));
  t.append(head);
  for (const cells of rows) {
    const tr = el("tr");
    for (const c of cells) {
      const td = el("td");
      if (c instanceof Node) td.append(c);
      else td.textContent = c;
      tr.append(td);
    }
    t.append(tr);
  }
  return t;
}

function fmtTime(ts) {
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? ts || "" : d.toLocaleString();
}

// render fills the three overview areas from one /api/status answer.
export function render(status, areas) {
  const health = status.health;
  const overall = health ? health.overall : "na";
  areas.overall.replaceChildren(
    badge(overall),
    el("span", "overall-text", OVERALL[overall] || overall),
    el("span", "muted", health ? "проверено " + fmtTime(health.ts) : "сторож ещё не записал отчёт"),
  );

  const rows = status.components.map((c) => [
    c.id,
    c.runtime,
    STATE[c.state] || c.state,
    c.enabled ? "да" : "нет",
    c.version || "",
  ]);
  const comps = [table(["Компонент", "Запуск", "Состояние", "Автозапуск", "Версия"], rows)];
  if (status.ndpi_plugin) comps.push(el("p", "muted", "Плагин nDPI: " + status.ndpi_plugin));
  areas.components.replaceChildren(...comps);

  const checks = health ? health.checks : [];
  areas.checks.replaceChildren(
    checks.length
      ? table(
          ["Проверка", "Статус", "Подробности", "С какого момента"],
          checks.map((c) => [c.id, badge(c.status), c.detail || c.value || "", fmtTime(c.since)]),
        )
      : el("p", "muted", "Проверок пока нет."),
  );
}

// start polls while the tab is visible and the screen is shown, and stops
// otherwise, so a closed or hidden panel costs no work. It returns stop().
export function start(api, areas, onError) {
  let timer = null;
  let running = true;
  const seq = tickets();

  async function tick() {
    timer = null;
    const ticket = seq.next();
    if (!running || document.hidden) return;
    try {
      const status = await api("/api/status");
      if (!running || !seq.current(ticket)) return;
      render(status, areas);
      areas.error.textContent = "";
    } catch (err) {
      if (!running || !seq.current(ticket)) return;
      if (err.status === 401) return onError(err);
      areas.error.textContent = err.message;
    }
    if (running && seq.current(ticket)) timer = setTimeout(tick, POLL_MS);
  }

  function onVisible() {
    if (!document.hidden && running && timer === null) tick();
  }

  document.addEventListener("visibilitychange", onVisible);
  tick();
  return () => {
    running = false;
    clearTimeout(timer);
    document.removeEventListener("visibilitychange", onVisible);
  };
}
