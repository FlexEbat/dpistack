// The Backups screen (slice 36): archives of the configuration made by
// `dpistack backup`. The panel decides who may use it (backup.manage). A
// restore always shows the difference first and asks before it replaces
// anything; the checks (the manifest, suricata -T) are done by dpistack.

// humanSize turns a number of bytes into "2.0 KiB".
export function humanSize(bytes) {
  const n = Number(bytes);
  if (!Number.isFinite(n) || n < 0) return "";
  if (n < 1024) return n + " B";
  const units = ["KiB", "MiB", "GiB"];
  let v = n / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return v.toFixed(1) + " " + units[i];
}

// madeAt shows the time of the manifest the way the other screens do.
export function madeAt(iso) {
  return iso ? String(iso).replace("T", " ").replace("Z", "") : "";
}

// requestUrl is the address of an action on one archive; the name goes
// through encodeURIComponent so it can never add a path or a parameter.
export function requestUrl(name, action) {
  return "/api/backups/" + encodeURIComponent(name) + (action ? "/" + action : "");
}

// restoreBody: dryRun asks for the difference, otherwise the restore is
// confirmed. The panel refuses a body with neither.
export function restoreBody(dryRun) {
  return JSON.stringify(dryRun ? { dry_run: true } : { acknowledged: true });
}

// nothingToChange says whether a dry run found every file the same.
export function nothingToChange(output) {
  const lines = String(output || "")
    .split("\n")
    .filter((l) => /^(new|same|changed):/.test(l));
  return lines.length > 0 && lines.every((l) => l.startsWith("same:"));
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

export function start(api, els, onError) {
  let running = true;
  let busy = false;

  function say(text, isError) {
    els.error.textContent = isError ? text : "";
    els.message.textContent = isError ? "" : text;
  }

  function show(text, isError) {
    els.result.textContent = text || "";
    els.result.className = "result" + (isError ? " error" : "");
  }

  // run keeps one action at a time and shows what failed with the words of
  // the checker, which the panel sends in body.output.
  async function run(fn) {
    if (busy) return false;
    busy = true;
    say("", false);
    try {
      await fn();
      return true;
    } catch (err) {
      if (err.status === 401) {
        onError(err);
        return false;
      }
      say(err.message, true);
      if (err.body && err.body.output) show(err.body.output, true);
      return false;
    } finally {
      busy = false;
    }
  }

  async function restore(name) {
    await run(async () => {
      const dry = await api(requestUrl(name, "restore"), { method: "POST", headers: { "Content-Type": "application/json" }, body: restoreBody(true) });
      show(dry.output);
      if (!running) return;
      if (nothingToChange(dry.output)) {
        say("Every file is the same as in " + name + ": there is nothing to restore.", false);
        return;
      }
      if (!confirm("Restore the configuration from " + name + "? The files marked changed or new are replaced; the previous ones are kept in the backups folder of dpistack.")) {
        say("Restore cancelled, nothing was changed.", false);
        return;
      }
      const res = await api(requestUrl(name, "restore"), { method: "POST", headers: { "Content-Type": "application/json" }, body: restoreBody(false) });
      show(res.output);
      say("Restored from " + name + ". Run dpistack reconfigure to apply it.", false);
    });
  }

  async function verify(name) {
    await run(async () => {
      const res = await api(requestUrl(name, "verify"), { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
      show(res.output);
      say(name + " is a sound backup.", false);
    });
  }

  async function create() {
    await run(async () => {
      const res = await api("/api/backups", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
      show(res.output);
      say("Backup made: " + res.name, false);
      await load(true);
    });
  }

  function row(b, canDownload) {
    const tr = el("tr");
    tr.append(el("td", "", b.name), el("td", "", madeAt(b.created)), el("td", "", b.program ? "v" + b.program : ""), el("td", "", String(b.files ?? "")), el("td", "", humanSize(b.size)));
    const actions = el("td", "actions");
    if (canDownload) {
      const a = el("a", "", "Download");
      a.href = requestUrl(b.name);
      a.download = b.name;
      actions.append(a);
    }
    const v = el("button", "", "Verify");
    v.type = "button";
    v.onclick = () => verify(b.name);
    const r = el("button", "", "Restore…");
    r.type = "button";
    r.onclick = () => restore(b.name);
    actions.append(v, r);
    tr.append(actions);
    return tr;
  }

  async function load(keepMessage) {
    let res;
    try {
      res = await api("/api/backups");
    } catch (err) {
      if (err.status === 401) return onError(err);
      els.error.textContent = err.message;
      return;
    }
    if (!running) return;
    if (!keepMessage) say("", false);
    if (!res.backups.length) {
      els.list.textContent = "No backups yet. Make one with the button above, or run dpistack backup create.";
      return;
    }
    const t = document.createElement("table");
    const head = el("tr");
    for (const h of ["Archive", "Made", "Program", "Files", "Size", ""]) head.append(el("th", "", h));
    t.append(head);
    for (const b of res.backups) t.append(row(b, res.download));
    els.list.replaceChildren(t);
  }

  els.create.onclick = () => create();
  load();
  return () => (running = false);
}
