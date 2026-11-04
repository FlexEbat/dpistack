// The version in the corner. Without an update it is a quiet chip; with one
// it is lit. A click opens the Build info window: the build facts always, and
// the update banner (which asks before anything happens) when there is one.

// when shows an ISO time the way a person reads it.
export function when(iso) {
  const m = /^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}:\d{2})(Z|[+-]00:00)$/.exec(String(iso || ""));
  return m ? m[1] + " " + m[2] + " UTC" : String(iso || "");
}

// facts lists what the Build info window shows; a row without data is left
// out. A row with a third value can be copied (the full commit).
export function facts(info) {
  if (!info || !info.version) return [];
  const b = info.build || {};
  const rows = [["Version", "v" + info.version]];
  if (b.time) rows.push(["Build time", when(b.time)]);
  if (b.commit) rows.push(["Commit", String(b.commit).slice(0, 12), String(b.commit)]);
  if (b.go) rows.push(["Runtime", b.platform ? b.go + " on " + b.platform : b.go]);
  if (info.latest) rows.push(["Latest release", "v" + info.latest]);
  return rows;
}

// badge turns the answer of GET /api/version into what the corner shows.
export function badge(info) {
  const version = info && info.version ? "v" + info.version : "";
  if (!version) return { text: "", title: "", update: false, visible: false };
  if (info.update_available && info.latest) {
    return {
      text: version,
      title: "Update available: v" + info.latest + ". Click to update.",
      update: true,
      visible: true,
    };
  }
  const title = info.check_error ? "dpistack " + version + " (update check: " + info.check_error + ")" : "dpistack " + version;
  return { text: version, title, update: false, visible: true };
}

// question is the text of the dialog.
export function question(info) {
  return (
    "Update dpistack from v" +
    info.version +
    " to v" +
    info.latest +
    "? Your settings are kept. The panel restarts for a moment, then this page reloads."
  );
}

// progress turns the answer of GET /api/update/job into one line.
export function progress(job) {
  if (!job || !job.state) return "Starting…";
  if (job.state === "active" || job.state === "activating") return "Updating…";
  if (job.result === "success") return "Updated. Reloading…";
  if (job.state === "failed" || (job.result && job.result !== "success")) return "The update failed. See the last lines below.";
  return "Waiting for the update to start…";
}

const CHECK_EVERY_MS = 30 * 60 * 1000;
const POLL_MS = 3000;

export function start(api, els) {
  let info = null;
  let timer = null;
  let polling = null;
  let stopped = false;

  function paint() {
    const b = badge(info);
    els.badge.hidden = !b.visible;
    (els.badgeText || els.badge).textContent = b.text;
    els.badge.title = b.title;
    els.badge.classList.toggle("has-update", b.update);
  }

  async function load() {
    try {
      info = await api("/api/version");
    } catch {
      return; // a signed-out or restarting panel: keep what is shown
    } finally {
      if (!stopped) timer = setTimeout(load, CHECK_EVERY_MS);
    }
    if (!stopped) paint();
  }

  function renderFacts() {
    if (!els.facts) return;
    els.facts.replaceChildren();
    for (const [label, value, full] of facts(info)) {
      const row = document.createElement("div");
      row.className = "fact";
      const dt = document.createElement("dt");
      dt.textContent = label;
      const dd = document.createElement("dd");
      dd.textContent = value;
      if (full) {
        const copy = document.createElement("button");
        copy.type = "button";
        copy.className = "icon-btn small";
        copy.setAttribute("aria-label", "Copy " + label);
        copy.textContent = "Copy";
        copy.addEventListener("click", async () => {
          try {
            await navigator.clipboard.writeText(full);
            copy.textContent = "Copied";
          } catch {
            copy.textContent = "Not copied";
          }
          setTimeout(() => (copy.textContent = "Copy"), 1500);
        });
        dd.append(copy);
      }
      row.append(dt, dd);
      els.facts.append(row);
    }
  }

  function openDialog() {
    if (!info) return;
    const update = !!info.update_available;
    if (els.banner) els.banner.hidden = !update;
    if (update) els.text.textContent = question(info);
    els.status.textContent = update ? "" : info.check_error ? "Update check: " + info.check_error : "No newer release.";
    els.log.textContent = "";
    els.yes.disabled = false;
    els.no.disabled = false;
    renderFacts();
    els.dialog.showModal();
  }

  async function poll() {
    try {
      const job = await api("/api/update/job");
      els.status.textContent = progress(job);
      els.log.textContent = (job.log || []).slice(-6).join("\n");
      if (job.result === "success") return finish();
    } catch {
      // The panel restarts while it updates: no answer is not an error.
      els.status.textContent = "Restarting…";
      try {
        const now = await api("/api/version");
        if (info && now.version !== info.version) return finish();
      } catch {
        /* still down */
      }
    }
    if (!stopped) polling = setTimeout(poll, POLL_MS);
  }

  function finish() {
    location.reload();
  }

  async function confirm() {
    els.yes.disabled = true;
    els.no.disabled = true;
    els.status.textContent = "Starting…";
    try {
      await api("/api/update", { method: "POST" });
    } catch (err) {
      els.status.textContent = err.message;
      els.yes.disabled = false;
      els.no.disabled = false;
      return;
    }
    poll();
  }

  const onBadge = () => openDialog();
  const onYes = () => confirm();
  const onNo = () => els.dialog.close();
  const onClose = () => els.dialog.close();
  els.badge.addEventListener("click", onBadge);
  if (els.close) els.close.addEventListener("click", onClose);
  els.yes.addEventListener("click", onYes);
  els.no.addEventListener("click", onNo);
  load();

  return () => {
    stopped = true;
    clearTimeout(timer);
    clearTimeout(polling);
    els.badge.removeEventListener("click", onBadge);
    if (els.close) els.close.removeEventListener("click", onClose);
    els.yes.removeEventListener("click", onYes);
    els.no.removeEventListener("click", onNo);
  };
}
