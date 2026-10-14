import { start as startOverview } from "./modules/overview.js";
import { start as startComponents } from "./modules/components.js";
import { start as startConfigs } from "./modules/configs.js";
import { start as startLogs } from "./modules/logs.js";

const $ = (id) => document.getElementById(id);

function cookie(name) {
  const hit = document.cookie.split("; ").find((c) => c.startsWith(name + "="));
  return hit ? decodeURIComponent(hit.slice(name.length + 1)) : "";
}

async function api(path, options = {}) {
  const headers = { ...options.headers };
  if (options.method && options.method !== "GET") {
    headers["X-CSRF-Token"] = cookie("dpistack_csrf");
  }
  const res = await fetch(path, { ...options, headers });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(body.error || "Ошибка " + res.status);
    err.status = res.status;
    err.body = body; // a refusal carries the checker's words in body.output
    throw err;
  }
  return body;
}

function show(id) {
  $("login").hidden = id !== "login";
  $("overview").hidden = id !== "overview";
}

const VIEWS = ["overview", "components", "configs", "logs"];
let stopView = null;

// Every screen starts when shown and returns a stop function, so a hidden
// screen polls nothing and holds no stream.
const SCREENS = {
  overview: () =>
    startOverview(
      api,
      { overall: $("overall"), components: $("components"), checks: $("checks"), error: $("overview-error") },
      showLogin,
    ),
  components: () =>
    startComponents(
      api,
      { list: $("components-list"), error: $("components-error"), message: $("components-message") },
      showLogin,
    ),
  configs: () =>
    startConfigs(
      api,
      {
        name: $("cfg-name"),
        editor: $("cfg-editor"),
        check: $("cfg-check"),
        save: $("cfg-save"),
        apply: $("cfg-apply"),
        revert: $("cfg-revert"),
        result: $("cfg-result"),
      },
      showLogin,
    ),
  logs: () =>
    startLogs(
      api,
      {
        component: $("log-component"),
        lines: $("log-lines"),
        show: $("log-show"),
        follow: $("log-follow"),
        output: $("log-output"),
        error: $("logs-error"),
      },
      showLogin,
    ),
};

function showView(name) {
  show("overview"); // the signed-in page
  stopView?.();
  for (const v of VIEWS) $("view-" + v).hidden = v !== name;
  for (const b of document.querySelectorAll("#nav button")) {
    if (b.dataset.view === name) b.setAttribute("aria-current", "page");
    else b.removeAttribute("aria-current");
  }
  stopView = SCREENS[name]();
}

function showOverview() {
  showView("overview");
}

function showLogin() {
  stopView?.();
  stopView = null;
  show("login");
  $("password").focus();
}

async function boot() {
  try {
    await api("/api/status");
    showOverview();
  } catch (err) {
    if (err.status === 401) {
      showLogin();
    } else {
      showOverview(); // the screen shows the error text itself
    }
  }
}

$("login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  $("login-error").textContent = "";
  try {
    await api("/api/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ password: $("password").value }),
    });
    $("password").value = "";
    await boot();
  } catch (err) {
    $("login-error").textContent = err.message;
  }
});

for (const b of document.querySelectorAll("#nav button")) {
  b.addEventListener("click", () => showView(b.dataset.view));
}

$("logout").addEventListener("click", async () => {
  await api("/api/logout", { method: "POST" }).catch(() => {});
  showLogin();
});

boot();
