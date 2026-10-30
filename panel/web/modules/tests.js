// The Tests screen: run the verification tests and show every result as a
// row with its status and the reason. "Last result" is read from the server,
// so it is still there after the panel or the page is restarted.

const WAIT_MS = 3000;
const WAIT_TRIES = 80; // about four minutes: the server gives a run three
const STATUS = { pass: "passed", fail: "failed", skip: "skipped" };
const BUTTONS = [
  ["bittorrent", "Run BitTorrent"],
  ["https", "Run HTTPS"],
  ["all", "Run all"],
];

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function when(iso) {
  if (!iso) return "";
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString("ru-RU");
}

// rows draws the results. The status is a word as well as a style, so it
// reads without colour.
export function rows(results) {
  const t = el("table");
  const head = el("tr");
  for (const h of ["Test", "Status", "Time, ms", "Reason", "When"]) head.append(el("th", "", h));
  t.append(head);
  for (const r of results) {
    const tr = el("tr");
    const st = el("td", `status-${STATUS[r.status] ? r.status : "unknown"}`, STATUS[r.status] || r.status);
    tr.append(el("td", "", r.name), st, el("td", "", r.duration_ms === undefined ? "" : String(r.duration_ms)), el("td", "", r.detail || ""), el("td", "", when(r.timestamp)));
    t.append(tr);
  }
  return t;
}

export function start(api, els, onError) {
  let running = true;

  function setBusy(on) {
    for (const b of els.buttons.querySelectorAll("button")) b.disabled = on;
  }

  function fail(err) {
    if (err.status === 401) return onError(err);
    els.error.textContent = err.message;
  }

  function show(results, note) {
    els.note.textContent = note || "";
    els.result.replaceChildren(results.length ? rows(results) : el("p", "muted empty", "No tests have run yet."));
  }

  async function loadLast() {
    try {
      const res = await api("/api/tests/last");
      if (!running) return null;
      els.error.textContent = "";
      show(res.results, res.running ? "Tests are running…" : "");
      return res;
    } catch (err) {
      fail(err);
      return null;
    }
  }

  // waitIdle follows a run that outlived the browser's request (a proxy may
  // cut a long answer; the panel still finishes the run and keeps the result).
  async function waitIdle() {
    for (let i = 0; i < WAIT_TRIES && running; i++) {
      await pause(WAIT_MS);
      if (!running) return;
      const res = await loadLast();
      if (res && !res.running) return;
    }
  }

  async function run(which) {
    if (!confirm("Run the test? The HTTPS test makes a network request and may take up to a minute.")) return;
    els.error.textContent = "";
    setBusy(true);
    els.note.textContent = "The test is running, please wait…";
    try {
      const results = await api(`/api/tests/${which}`, { method: "POST" });
      show(results, "Done.");
      await loadLast(); // the file has the times
      els.note.textContent = "Done.";
    } catch (err) {
      if (err.status === 401) return onError(err);
      if (err.status === 409 || err.status === 502 || err.status === 504 || err instanceof TypeError) {
        await waitIdle();
      } else {
        fail(err);
        await loadLast();
      }
    } finally {
      setBusy(false);
    }
  }

  // replaceChildren, not append: the screen is started again every time it
  // is opened, and the container stays in the page.
  els.buttons.replaceChildren(
    ...BUTTONS.map(([which, text]) => {
      const b = el("button", "", text);
      b.type = "button";
      b.addEventListener("click", () => run(which));
      return b;
    }),
  );

  loadLast().then((res) => {
    if (res && res.running) waitIdle();
  });
  return () => {
    running = false;
  };
}
