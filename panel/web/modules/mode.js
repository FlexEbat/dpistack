// The mode block of the Components screen: IDS or IPS. Switching to IPS can
// cut the host off the network when the rules are wrong, so it is confirmed
// first, and then a countdown runs: unless "Подтвердить IPS" is pressed
// before it ends, the server takes the mode back to IDS by itself.

const POLL_MS = 5000;

export function start(api, els, onError) {
  let running = true;
  let remaining = 0;
  let pending = false;
  let ticker = null;
  let poller = null;
  let busy = false;
  let last = { mode: "ids", method: "", pending: false, remaining_sec: 0 };

  function fail(err) {
    if (err.status === 401) return onError(err);
    els.error.textContent = err.message;
  }

  function stopTicker() {
    if (ticker !== null) clearInterval(ticker);
    ticker = null;
  }

  function paint(st) {
    last = st;
    const name = st.mode === "ips" ? "IPS" : "IDS";
    els.status.textContent = `Режим: ${name}` + (st.mode === "ips" ? ` (метод ${st.method})` : "");
    els.ips.disabled = busy || (st.mode === "ips" && !st.pending);
    els.ids.disabled = busy || st.mode === "ids";
    els.confirm.hidden = !st.pending;
    els.confirm.disabled = busy;
    if (st.pending) {
      els.message.textContent = `Подтвердите IPS: через ${remaining} с режим вернётся в IDS.`;
    } else if (!els.message.dataset.keep) {
      els.message.textContent = "";
    }
  }

  // render takes the state from the server and starts or stops the countdown.
  function render(st) {
    stopTicker();
    pending = st.pending;
    remaining = st.remaining_sec;
    paint(st);
    if (!st.pending) return;
    ticker = setInterval(() => {
      remaining = Math.max(0, remaining - 1);
      paint({ ...st, pending: true });
      // at zero the server decides: ask it what became of the switch
      if (remaining === 0) {
        stopTicker();
        setTimeout(load, 3000);
      }
    }, 1000);
  }

  async function load() {
    try {
      const st = await api("/api/mode");
      if (!running) return;
      els.error.textContent = "";
      render(st);
    } catch (err) {
      fail(err);
    }
  }

  function setBusy(on) {
    busy = on;
    paint(last);
  }

  async function post(path, body) {
    els.error.textContent = "";
    els.message.dataset.keep = "";
    els.message.textContent = "Применяю, это может занять минуту…";
    setBusy(true);
    try {
      const res = await api(path, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body || {}),
      });
      els.message.textContent = res.output || "Готово";
      els.message.dataset.keep = "1";
      if (res.mode) render(res.mode);
      else await load();
    } catch (err) {
      els.message.textContent = "";
      fail(err);
      await load(); // the mode as the server has it
    } finally {
      setBusy(false);
    }
  }

  els.ips.onclick = () => {
    const ok = confirm(
      "Включить IPS? Suricata будет перезапущена, а трафик хоста пойдёт через неё и может блокироваться правилами drop. " +
        "После включения у вас будет время нажать «Подтвердить IPS»; если не успеть, режим сам вернётся в IDS.",
    );
    if (ok) post("/api/mode", { mode: "ips", acknowledged: true });
  };
  els.ids.onclick = () => {
    if (confirm("Вернуть режим IDS? Suricata будет перезапущена.")) post("/api/mode", { mode: "ids" });
  };
  els.confirm.onclick = () => post("/api/mode/confirm");

  load();
  poller = setInterval(() => {
    if (!pending) load();
  }, POLL_MS);
  return () => {
    running = false;
    stopTicker();
    if (poller !== null) clearInterval(poller);
  };
}
