// The Logs screen: the last N lines of a component, or a live tail (SSE).

const MAX_SHOWN = 2000; // lines kept on screen while following

function option(value, text) {
  const o = document.createElement("option");
  o.value = value;
  o.textContent = text;
  return o;
}

export function start(api, els, onError) {
  let source = null;

  function stopFollow() {
    source?.close();
    source = null;
    els.follow.textContent = "Follow";
  }

  function show(lines) {
    els.output.textContent = lines.join("\n");
    els.output.scrollTop = els.output.scrollHeight;
  }

  function append(line) {
    const lines = els.output.textContent ? els.output.textContent.split("\n") : [];
    lines.push(line);
    show(lines.slice(-MAX_SHOWN));
  }

  async function load() {
    stopFollow();
    els.error.textContent = "";
    const n = encodeURIComponent(els.lines.value);
    try {
      const res = await api(`/api/logs/${encodeURIComponent(els.component.value)}?lines=${n}`);
      show(res.lines);
    } catch (err) {
      if (err.status === 401) return onError(err);
      els.error.textContent = err.message;
    }
  }

  function follow() {
    if (source) return stopFollow();
    els.error.textContent = "";
    els.output.textContent = "";
    const n = encodeURIComponent(els.lines.value);
    source = new EventSource(`/api/logs/${encodeURIComponent(els.component.value)}/stream?lines=${n}`);
    els.follow.textContent = "Stop following";
    source.onmessage = (event) => append(event.data);
    source.addEventListener("error", (event) => {
      // An error event sent by the server carries text; a dropped
      // connection does not.
      els.error.textContent = event.data || "The log stream connection was lost";
      stopFollow();
    });
    source.addEventListener("end", () => stopFollow());
  }

  els.show.onclick = load;
  els.follow.onclick = follow;
  els.component.onchange = stopFollow;

  // The component list comes from the same status the other screens use.
  api("/api/status")
    .then((st) => {
      els.component.replaceChildren(
        ...st.components.filter((c) => c.state !== "absent").map((c) => option(c.id, c.id)),
      );
      return load();
    })
    .catch((err) => (err.status === 401 ? onError(err) : (els.error.textContent = err.message)));

  return stopFollow;
}
