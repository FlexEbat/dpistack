import { start as startOverview } from "./modules/overview.js";

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
    throw err;
  }
  return body;
}

function show(id) {
  $("login").hidden = id !== "login";
  $("overview").hidden = id !== "overview";
}

let stopOverview = null;

function showOverview() {
  show("overview");
  stopOverview?.();
  stopOverview = startOverview(
    api,
    {
      overall: $("overall"),
      components: $("components"),
      checks: $("checks"),
      error: $("overview-error"),
    },
    showLogin,
  );
}

function showLogin() {
  stopOverview?.();
  stopOverview = null;
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

$("logout").addEventListener("click", async () => {
  await api("/api/logout", { method: "POST" }).catch(() => {});
  showLogin();
});

boot();
