// The version in the corner. Without an update it is a quiet label; with one
// it glows, and a click opens a dialog that asks before anything happens.

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
    els.badge.textContent = b.text;
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

  function openDialog() {
    if (!info || !info.update_available) return;
    els.text.textContent = question(info);
    els.status.textContent = "";
    els.log.textContent = "";
    els.yes.disabled = false;
    els.no.disabled = false;
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
  els.badge.addEventListener("click", onBadge);
  els.yes.addEventListener("click", onYes);
  els.no.addEventListener("click", onNo);
  load();

  return () => {
    stopped = true;
    clearTimeout(timer);
    clearTimeout(polling);
    els.badge.removeEventListener("click", onBadge);
    els.yes.removeEventListener("click", onYes);
    els.no.removeEventListener("click", onNo);
  };
}
