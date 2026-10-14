// The Configs screen: pick a file, edit it, check, save, save and apply, revert.

function option(value) {
  const o = document.createElement("option");
  o.value = value;
  o.textContent = value;
  return o;
}

export function start(api, els, onError) {
  let loaded = ""; // the text as the server gave it, to tell an edit from none
  let busy = false;

  const dirty = () => els.editor.value !== loaded;
  const path = () => `/api/config/${encodeURIComponent(els.name.value)}`;

  function report(ok, text, output) {
    els.result.className = ok ? "result" : "result error";
    els.result.textContent = [text, output].filter(Boolean).join("\n");
  }

  function setBusy(on) {
    busy = on;
    for (const b of [els.check, els.save, els.apply, els.revert]) b.disabled = on;
  }

  async function load(keepResult = false) {
    try {
      const res = await api(path());
      loaded = res.content;
      els.editor.value = res.content;
      if (!keepResult) els.result.textContent = "";
    } catch (err) {
      if (err.status === 401) return onError(err);
      report(false, err.message);
    }
  }

  // run sends one request and shows what came back. A refusal (422) carries
  // the checker's own words next to the sentence.
  async function run(request, okText) {
    if (busy) return false;
    setBusy(true);
    try {
      const res = await request();
      report(true, okText, res.output);
      return true;
    } catch (err) {
      if (err.status === 401) onError(err);
      else report(false, err.message, err.body?.output);
      return false;
    } finally {
      setBusy(false);
    }
  }

  const send = (query) => () =>
    api(path() + query, { method: "PUT", headers: { "Content-Type": "text/plain" }, body: els.editor.value });

  els.check.onclick = () =>
    run(
      () => api(path() + "/check", { method: "POST", headers: { "Content-Type": "text/plain" }, body: els.editor.value }),
      "Проверка пройдена, файл не изменён.",
    );

  els.save.onclick = async () => {
    if (await run(send("?apply=0"), "Сохранено.")) loaded = els.editor.value;
  };

  els.apply.onclick = async () => {
    if (!confirm(`Сохранить ${els.name.value} и применить? Компонент будет перезагружен.`)) return;
    if (await run(send("?apply=1"), "Сохранено и применено.")) loaded = els.editor.value;
  };

  els.revert.onclick = async () => {
    if (!confirm(`Вернуть предыдущую сохранённую версию ${els.name.value}? Несохранённые правки пропадут.`)) return;
    if (await run(() => api(path() + "/revert", { method: "POST" }), "Возвращена предыдущая версия.")) await load(true);
  };

  els.name.onchange = async () => {
    if (dirty() && !confirm("Есть несохранённые правки. Открыть другой файл?")) {
      els.name.value = els.name.dataset.current;
      return;
    }
    els.name.dataset.current = els.name.value;
    await load();
  };

  api("/api/config")
    .then((res) => {
      els.name.replaceChildren(...res.names.map(option));
      els.name.dataset.current = els.name.value;
      return load();
    })
    .catch((err) => (err.status === 401 ? onError(err) : report(false, err.message)));

  return () => {};
}
